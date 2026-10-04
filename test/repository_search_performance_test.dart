import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

/// Abstract counter hook that observes exposed ListView element count
/// without coupling to private implementation state or field names.
int visibleMatchCount(WidgetTester tester) {
  final listViewFinder = find.byType(ListView);
  if (listViewFinder.evaluate().isEmpty) return 0;
  final listView = tester.widget<ListView>(listViewFinder);
  return listView.childrenDelegate.estimatedChildCount ?? 0;
}

bool lineIsSelected(WidgetTester tester, int line) {
  final semantics = tester.widget<Semantics>(
    find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == '第 $line 行',
    ),
  );
  return semantics.properties.selected ?? false;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final account = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'coder', name: 'Coder'),
    token: 'synthetic-token',
  );
  final project = Project.fromJson({
    'id': 42,
    'name': 'Project',
    'path': 'project',
    'path_with_namespace': 'group/project',
    'description': '',
    'visibility': 'private',
    'default_branch': 'main',
    'archived': false,
    'last_activity_at': '2026-09-20T10:00:00Z',
  });

  const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  Widget buildTestApp({
    required GitLabApi api,
    required String filePath,
    Account? customAccount,
    Project? customProject,
    String customBranch = 'main',
    String? customSha,
    int? targetLine,
  }) {
    return MaterialApp(
      home: RepositoryFilePage(
        account: customAccount ?? account,
        api: api,
        project: customProject ?? project,
        branch: customBranch,
        sha: customSha ?? sha,
        filePath: filePath,
        targetLine: targetLine,
      ),
    );
  }

  FakeAdapter createFakeAdapter(String fileContent) {
    return FakeAdapter((request) {
      final reqPath = request.uri.path;
      if (request.method == 'HEAD' && reqPath.contains('/repository/files/')) {
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'x-gitlab-size': ['${fileContent.length}'],
            'x-gitlab-last-commit-id': [sha],
          },
        );
      }
      if (reqPath.endsWith('/raw')) {
        return ResponseBody.fromString(fileContent, 200);
      }
      return jsonResponse([]);
    });
  }

  group('RepositoryFilePage search debounce & lifecycle safety (AUTHORED_NOT_RUN)', () {
    const multiLineCode = '''alpha
alphabet
alpine
beta
gamma''';

    testWidgets(
      'rapid typing debounces and evaluates only latest query after 250ms',
      (tester) async {
        final adapter = createFakeAdapter(multiLineCode);
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart'),
        );
        await settleNetworkWidgets(tester);

        expect(visibleMatchCount(tester), 5);

        // Rapid keystroke 1: 'b' at t = 0
        await tester.enterText(find.byType(TextField), 'b');
        await tester.pump(const Duration(milliseconds: 100));
        // At 100ms, debounce has NOT expired; line count must remain 5
        expect(visibleMatchCount(tester), 5);
        expect(
          find.byKey(const ValueKey('repository-file-search-pending')),
          findsOneWidget,
        );

        // Rapid keystroke 2: 'be' at t = 100
        await tester.enterText(find.byType(TextField), 'be');
        await tester.pump(const Duration(milliseconds: 100));
        // At 200ms, debounce was reset; line count must remain 5
        expect(visibleMatchCount(tester), 5);

        // Rapid keystroke 3: 'bet' at t = 200
        await tester.enterText(find.byType(TextField), 'bet');
        await tester.pump(const Duration(milliseconds: 100));
        // At 300ms (100ms after 'bet'), still debouncing
        expect(visibleMatchCount(tester), 5);

        // Advance remaining 150ms to cross 250ms debounce threshold
        await tester.pump(const Duration(milliseconds: 150));

        // Now evaluated: 'alphabet' and 'beta' contain 'bet' -> 2 lines
        expect(visibleMatchCount(tester), 2);
        expect(
          find.byKey(const ValueKey('repository-file-search-pending')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'empty query flushes immediately without clearing intentional selection',
      (tester) async {
        final adapter = createFakeAdapter(multiLineCode);
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart'),
        );
        await settleNetworkWidgets(tester);

        // Tap line 4 to select/highlight it
        await tester.tap(find.text('4'));
        await tester.pump();
        expect(lineIsSelected(tester, 4), isTrue);

        // 1. Enter query and clear while debounce timer is still pending
        await tester.enterText(find.byType(TextField), 'beta');
        await tester.pump(const Duration(milliseconds: 50));
        expect(visibleMatchCount(tester), 5);

        // Clear query while timer is active -> must flush immediately without 250ms delay
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        expect(visibleMatchCount(tester), 5);

        // Advance clock past 250ms of original search -> old timer must cause 0 later mutation
        await tester.pump(const Duration(milliseconds: 300));
        expect(visibleMatchCount(tester), 5);

        // 2. Filter, wait for evaluation, then clear with whitespace
        await tester.enterText(find.byType(TextField), 'beta');
        await tester.pump(const Duration(milliseconds: 250));
        expect(visibleMatchCount(tester), 1);

        // Whitespace-only clear flushes immediately
        await tester.enterText(find.byType(TextField), '   ');
        await tester.pump();
        expect(visibleMatchCount(tester), 5);
        expect(lineIsSelected(tester, 4), isTrue);
      },
    );

    testWidgets('onSubmitted flushes search immediately without duplicate scan', (
      tester,
    ) async {
      final adapter = createFakeAdapter(multiLineCode);
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        buildTestApp(api: api, filePath: 'lib/code.dart'),
      );
      await settleNetworkWidgets(tester);

      expect(visibleMatchCount(tester), 5);

      // Enter text and immediately submit via onSubmitted callback
      await tester.enterText(find.byType(TextField), 'alp');
      final textField = tester.widget<TextField>(find.byType(TextField));
      textField.onSubmitted?.call('alp');
      await tester.pump();

      // Immediately evaluated without 250ms delay: 'alpha', 'alphabet', 'alpine'
      expect(visibleMatchCount(tester), 3);

      // Advancing clock past 250ms must not cause a second filter scan or state churn
      await tester.pump(const Duration(milliseconds: 300));
      expect(visibleMatchCount(tester), 3);
    });

    testWidgets(
      'navigating match before timer flushes pending search or is truthfully disabled',
      (tester) async {
        final adapter = createFakeAdapter(multiLineCode);
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart'),
        );
        await settleNetworkWidgets(tester);

        expect(visibleMatchCount(tester), 5);

        // 1. Enter search 'beta' without waiting for 250ms timer
        await tester.enterText(find.byType(TextField), 'beta');
        await tester.pump(const Duration(milliseconds: 50));
        // Timer still pending; line count remains 5
        expect(visibleMatchCount(tester), 5);

        // Navigate to line 4 ('beta') via targetLine update before debounce expires
        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart', targetLine: 4),
        );
        await tester.pump();

        // Navigation flushed pending search immediately; only 'beta' (line 4) is visible
        expect(visibleMatchCount(tester), 1);
        expect(
          find.descendant(
            of: find.byType(ListView),
            matching: find.text('beta'),
          ),
          findsOneWidget,
        );
        expect(find.text('alpha'), findsNothing);

        // 2. Truthfully disabled navigation to a non-matching line:
        // Clear search, restore 5 lines
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        expect(visibleMatchCount(tester), 5);

        // Type 'beta' again (timer pending)
        await tester.enterText(find.byType(TextField), 'beta');
        await tester.pump(const Duration(milliseconds: 50));

        // Trigger navigation to line 1 ('alpha'), which does NOT contain 'beta'
        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart', targetLine: 1),
        );
        await tester.pump();

        // Flushing 'beta' makes line 1 absent (_visibleIndices does not contain index 0)
        expect(visibleMatchCount(tester), 1);
        expect(find.text('alpha'), findsNothing);
      },
    );

    testWidgets(
      'same refresh preserves query while resource owner and API reset it',
      (tester) async {
        final adapter = createFakeAdapter(multiLineCode);
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart'),
        );
        await settleNetworkWidgets(tester);

        // 1. A same-owner/same-resource refresh flushes and preserves the
        // visible query rather than presenting text that is not applied.
        await tester.enterText(find.byType(TextField), 'alpha');
        await tester.pump(const Duration(milliseconds: 50));

        // Trigger reload via popup menu before debounce expires
        await tester.tap(find.byTooltip('檔案操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新載入'));
        await settleNetworkWidgets(tester);

        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'alpha',
        );
        expect(visibleMatchCount(tester), 2);

        // Advancing time past 250ms from the original timer causes no later
        // mutation.
        await tester.pump(const Duration(milliseconds: 300));
        expect(visibleMatchCount(tester), 2);

        // 2. Resource change clears visible and applied query together.
        await tester.enterText(find.byType(TextField), 'beta');
        await tester.pump(const Duration(milliseconds: 50));

        // Widget updated with new filePath (resource scope reset)
        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/other.dart'),
        );
        await settleNetworkWidgets(tester);

        // Advancing time must not evaluate old query
        await tester.pump(const Duration(milliseconds: 300));
        expect(visibleMatchCount(tester), 5);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );

        // 3. Account scope change cancels pending search
        await tester.enterText(find.byType(TextField), 'gamma');
        await tester.pump(const Duration(milliseconds: 50));

        final otherAccount = Account(
          instance: instance,
          user: const GitLabUser(id: 99, username: 'other', name: 'Other'),
          token: 'other-token',
        );
        await tester.pumpWidget(
          buildTestApp(
            api: api,
            filePath: 'lib/other.dart',
            customAccount: otherAccount,
          ),
        );
        await settleNetworkWidgets(tester);

        // Advancing time must not evaluate old query on new account scope
        await tester.pump(const Duration(milliseconds: 300));
        expect(visibleMatchCount(tester), 5);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );

        // 4. API replacement within the same account scope cancels pending search
        await tester.enterText(find.byType(TextField), 'alpha');
        await tester.pump(const Duration(milliseconds: 50));

        final replacementAdapter = createFakeAdapter(multiLineCode);
        final replacementApi = testApi(replacementAdapter);
        addTearDown(replacementApi.close);
        await tester.pumpWidget(
          buildTestApp(
            api: replacementApi,
            filePath: 'lib/other.dart',
            customAccount: otherAccount,
          ),
        );
        await settleNetworkWidgets(tester);

        await tester.pump(const Duration(milliseconds: 300));
        expect(visibleMatchCount(tester), 5);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
      },
    );

    testWidgets(
      'same-key newly constructed account preserves the active search without reloading',
      (tester) async {
        var rawReads = 0;
        final adapter = FakeAdapter((request) {
          if (request.method == 'HEAD') {
            return ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['${multiLineCode.length}'],
                'x-gitlab-last-commit-id': [sha],
              },
            );
          }
          if (request.uri.path.endsWith('/raw')) {
            rawReads++;
            return ResponseBody.fromString(multiLineCode, 200);
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart'),
        );
        await settleNetworkWidgets(tester);

        await tester.enterText(find.byType(TextField), 'beta');
        await tester.pump(const Duration(milliseconds: 250));
        expect(visibleMatchCount(tester), 1);
        expect(rawReads, 1);

        final sameKeyAccount = Account(
          instance: instance,
          user: const GitLabUser(id: 7, username: 'coder', name: 'Coder'),
          token: 'replacement-synthetic-token',
        );
        expect(sameKeyAccount.key, account.key);

        await tester.pumpWidget(
          buildTestApp(
            api: api,
            filePath: 'lib/code.dart',
            customAccount: sameKeyAccount,
          ),
        );
        await settleNetworkWidgets(tester);

        expect(
          visibleMatchCount(tester),
          1,
          reason: 'A same-key Account rebuild must preserve the active query.',
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'beta',
        );
        expect(
          rawReads,
          1,
          reason: 'A same-key Account rebuild must not reload the file.',
        );
      },
    );

    testWidgets(
      'replacement owner clears old private bytes before held failure and late old response',
      (tester) async {
        const oldPrivate = 'OLD_PRIVATE_ACCOUNT_SECRET';
        const lateOldPrivate = 'LATE_OLD_PRIVATE_ACCOUNT_SECRET';
        final lateOldLoad = Completer<ResponseBody>();
        var oldRawReads = 0;
        final oldAdapter = FakeAdapter((request) {
          if (request.method == 'HEAD') {
            return ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['100'],
                'x-gitlab-last-commit-id': [sha],
              },
            );
          }
          if (request.uri.path.endsWith('/raw')) {
            oldRawReads++;
            if (oldRawReads == 1) {
              return ResponseBody.fromString(oldPrivate, 200);
            }
            return lateOldLoad.future;
          }
          return jsonResponse([]);
        });
        final oldApi = testApi(oldAdapter);
        addTearDown(oldApi.close);

        final heldReplacement = Completer<ResponseBody>();
        final replacementAdapter = FakeAdapter((request) {
          if (request.method == 'HEAD') {
            return ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['100'],
                'x-gitlab-last-commit-id': [sha],
              },
            );
          }
          if (request.uri.path.endsWith('/raw')) {
            return heldReplacement.future;
          }
          return jsonResponse([]);
        });
        final replacementApi = testApi(replacementAdapter);
        addTearDown(replacementApi.close);
        final replacementAccount = Account(
          instance: instance,
          user: const GitLabUser(id: 99, username: 'other', name: 'Other'),
          token: 'replacement-synthetic-token',
        );

        await tester.pumpWidget(
          buildTestApp(api: oldApi, filePath: 'lib/private.dart'),
        );
        await settleNetworkWidgets(tester);
        expect(find.text(oldPrivate), findsOneWidget);

        await tester.tap(find.byTooltip('檔案操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新載入'));
        await pumpUntil(
          tester,
          () => oldRawReads == 2,
          description: 'held old-owner refresh request',
        );
        expect(oldRawReads, 2);
        expect(find.text(oldPrivate), findsOneWidget);

        await tester.pumpWidget(
          buildTestApp(
            api: replacementApi,
            filePath: 'lib/private.dart',
            customAccount: replacementAccount,
          ),
        );
        await pumpUntil(
          tester,
          () => replacementAdapter.requests.any(
            (request) => request.uri.path.endsWith('/raw'),
          ),
          description: 'held replacement-owner file request',
        );

        expect(find.text(oldPrivate), findsNothing);
        expect(find.text(lateOldPrivate), findsNothing);
        expect(find.byType(TextField), findsNothing);

        heldReplacement.completeError(
          DioException(
            requestOptions: RequestOptions(path: '/replacement/raw'),
            type: DioExceptionType.receiveTimeout,
          ),
        );
        await settleNetworkWidgets(tester);
        expect(find.text(oldPrivate), findsNothing);
        expect(find.text(lateOldPrivate), findsNothing);

        lateOldLoad.complete(ResponseBody.fromString(lateOldPrivate, 200));
        await settleNetworkWidgets(tester);
        expect(find.text(oldPrivate), findsNothing);
        expect(find.text(lateOldPrivate), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('dart to markdown replacement recomputes preview behavior', (
      tester,
    ) async {
      var rawReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.method == 'HEAD') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'x-gitlab-size': ['100'],
              'x-gitlab-last-commit-id': [sha],
            },
          );
        }
        if (request.uri.path.endsWith('/raw')) {
          rawReads++;
          return ResponseBody.fromString(
            rawReads == 1 ? 'void main() {}' : '# Markdown replacement title',
            200,
          );
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        buildTestApp(api: api, filePath: 'lib/source.dart'),
      );
      await settleNetworkWidgets(tester);
      expect(find.byTooltip('Markdown 預覽'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);

      await tester.pumpWidget(
        buildTestApp(api: api, filePath: 'docs/README.md'),
      );
      await settleNetworkWidgets(tester);

      expect(rawReads, 2);
      expect(find.byTooltip('顯示原始文字'), findsOneWidget);
      expect(find.text('Markdown replacement title'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets(
      'same resource refresh preserves query selection and scroll position',
      (tester) async {
        final content = List<String>.generate(
          240,
          (index) => 'needle-line-${index + 1}',
        ).join('\n');
        final adapter = createFakeAdapter(content);
        final api = testApi(adapter);
        addTearDown(api.close);
        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/large.dart', targetLine: 180),
        );
        await settleNetworkWidgets(tester);
        await tester.enterText(find.byType(TextField), 'needle');
        await tester.pump(const Duration(milliseconds: 250));
        expect(lineIsSelected(tester, 180), isTrue);
        final beforeList = tester.widget<ListView>(find.byType(ListView));
        final beforeOffset = beforeList.controller!.offset;
        expect(beforeOffset, greaterThan(0));

        await tester.tap(find.byTooltip('檔案操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新載入'));
        await settleNetworkWidgets(tester);

        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'needle',
        );
        expect(lineIsSelected(tester, 180), isTrue);
        final afterList = tester.widget<ListView>(find.byType(ListView));
        expect(afterList.controller!.offset, closeTo(beforeOffset, 1));
      },
    );

    testWidgets(
      'same-owner credential revocation clears retained private source',
      (tester) async {
        const privateSource = 'SAME_OWNER_PRIVATE_SOURCE';
        var revoked = false;
        final adapter = FakeAdapter((request) {
          if (revoked) {
            return jsonResponse({}, status: 401);
          }
          if (request.method == 'HEAD') {
            return ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['${privateSource.length}'],
                'x-gitlab-last-commit-id': [sha],
              },
            );
          }
          if (request.uri.path.endsWith('/raw')) {
            return ResponseBody.fromString(privateSource, 200);
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/private.dart'),
        );
        await settleNetworkWidgets(tester);
        expect(find.text(privateSource), findsOneWidget);

        revoked = true;
        await tester.tap(find.byTooltip('檔案操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新載入'));
        await settleNetworkWidgets(tester);

        expect(find.byType(FailureNotice), findsOneWidget);
        expect(find.text(privateSource), findsNothing);
        expect(find.byType(TextField), findsNothing);
      },
    );

    testWidgets(
      'held same-owner refresh applies the latest visible query to new source',
      (tester) async {
        const initialSource = 'old-alpha\nold-beta';
        const refreshedSource = 'new-alpha\nnew-beta-one\nnew-beta-two';
        final heldRefresh = Completer<ResponseBody>();
        var rawReads = 0;
        final adapter = FakeAdapter((request) {
          if (request.method == 'HEAD') {
            return ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['${refreshedSource.length}'],
                'x-gitlab-last-commit-id': [sha],
              },
            );
          }
          if (request.uri.path.endsWith('/raw')) {
            rawReads++;
            if (rawReads == 1) {
              return ResponseBody.fromString(initialSource, 200);
            }
            return heldRefresh.future;
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/query_refresh.dart'),
        );
        await settleNetworkWidgets(tester);

        await tester.enterText(find.byType(TextField), 'alpha');
        await tester.pump(const Duration(milliseconds: 250));
        expect(visibleMatchCount(tester), 1);

        await tester.tap(find.byTooltip('檔案操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新載入'));
        await pumpUntil(
          tester,
          () => rawReads == 2,
          description: 'held same-owner refresh request',
        );

        await tester.enterText(find.byType(TextField), 'beta');
        await tester.pump(const Duration(milliseconds: 250));
        expect(visibleMatchCount(tester), 1);
        expect(
          find.byKey(const ValueKey('repository-file-search-pending')),
          findsNothing,
        );

        heldRefresh.complete(ResponseBody.fromString(refreshedSource, 200));
        await settleNetworkWidgets(tester);

        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          'beta',
        );
        expect(visibleMatchCount(tester), 2);
        expect(find.text('new-beta-one'), findsOneWidget);
        expect(find.text('new-beta-two'), findsOneWidget);
        expect(find.text('new-alpha'), findsNothing);
      },
    );

    testWidgets(
      'project ref and path replacements load only their exact resource',
      (tester) async {
        const otherSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final otherProject = Project.fromJson({
          'id': 99,
          'name': 'Other project',
          'path': 'other',
          'path_with_namespace': 'group/other',
          'description': '',
          'visibility': 'private',
          'default_branch': 'main',
          'archived': false,
          'last_activity_at': '2026-09-20T10:00:00Z',
        });
        final adapter = FakeAdapter((request) {
          if (request.method == 'HEAD') {
            return ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['100'],
                'x-gitlab-last-commit-id': [sha],
              },
            );
          }
          if (request.uri.path.endsWith('/raw')) {
            final uri = request.uri.toString();
            if (uri.contains('/projects/99/')) {
              return ResponseBody.fromString('OTHER_PROJECT_PRIVATE', 200);
            }
            if (uri.contains(otherSha)) {
              return ResponseBody.fromString('OTHER_REF_PRIVATE', 200);
            }
            if (uri.contains('other.dart')) {
              return ResponseBody.fromString('OTHER_PATH_PRIVATE', 200);
            }
            return ResponseBody.fromString('BASE_RESOURCE_PRIVATE', 200);
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/base.dart'),
        );
        await settleNetworkWidgets(tester);
        expect(find.text('BASE_RESOURCE_PRIVATE'), findsOneWidget);

        await tester.pumpWidget(
          buildTestApp(
            api: api,
            filePath: 'lib/base.dart',
            customProject: otherProject,
          ),
        );
        await settleNetworkWidgets(tester);
        expect(find.text('OTHER_PROJECT_PRIVATE'), findsOneWidget);
        expect(find.text('BASE_RESOURCE_PRIVATE'), findsNothing);

        await tester.pumpWidget(
          buildTestApp(
            api: api,
            filePath: 'lib/base.dart',
            customSha: otherSha,
          ),
        );
        await settleNetworkWidgets(tester);
        expect(find.text('OTHER_REF_PRIVATE'), findsOneWidget);
        expect(find.text('OTHER_PROJECT_PRIVATE'), findsNothing);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/other.dart'),
        );
        await settleNetworkWidgets(tester);
        expect(find.text('OTHER_PATH_PRIVATE'), findsOneWidget);
        expect(find.text('OTHER_REF_PRIVATE'), findsNothing);
      },
    );

    testWidgets(
      'disposed widget with active timer does not throw or call setState',
      (tester) async {
        final adapter = createFakeAdapter(multiLineCode);
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart'),
        );
        await settleNetworkWidgets(tester);

        // Start search
        await tester.enterText(find.byType(TextField), 'alpha');
        await tester.pump(const Duration(milliseconds: 50));

        // Unmount widget while timer is active
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('Unmounted'))),
        );

        // Let timer fire in background
        await tester.pump(const Duration(milliseconds: 300));

        // Must not throw FlutterError (e.g. setState() called after dispose())
        expect(tester.takeException(), isNull);
        expect(find.text('Unmounted'), findsOneWidget);
      },
    );

    testWidgets(
      'visible matches, intentional selection, focus, wrap, and scroll remain distinct',
      (tester) async {
        const testCode = '''GitLab 行動端專案
Flutter 效能優化
MixedCaseSearchTarget
line 4 with extra long content for horizontal scrolling verification in wrap toggle mode
line 5 final''';

        final adapter = createFakeAdapter(testCode);
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/code.dart'),
        );
        await settleNetworkWidgets(tester);

        // 1. Initial count & CJK / case-insensitive search matching
        expect(visibleMatchCount(tester), 5);

        await tester.enterText(find.byType(TextField), '效能');
        await tester.pump(const Duration(milliseconds: 250));
        expect(visibleMatchCount(tester), 1);
        expect(find.textContaining('Flutter 效能優化'), findsOneWidget);

        // Query matching does not manufacture line selection.
        expect(lineIsSelected(tester, 2), isFalse);
        expect(
          tester
              .widget<Container>(
                find.byKey(const ValueKey('repository-file-line-2')),
              )
              .color,
          isNull,
        );

        await tester.enterText(find.byType(TextField), 'mixedcasesearch');
        await tester.pump(const Duration(milliseconds: 250));
        expect(visibleMatchCount(tester), 1);
        expect(find.textContaining('MixedCaseSearchTarget'), findsOneWidget);

        // Clear search
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        expect(visibleMatchCount(tester), 5);

        // 2. Line selection & highlight
        await tester.tap(find.text('2'));
        await tester.pump();
        expect(lineIsSelected(tester, 2), isTrue);
        final selectedRow = find.byKey(
          const ValueKey('repository-file-line-2'),
        );
        expect(selectedRow, findsOneWidget);
        final selectedContainer = tester.widget<Container>(selectedRow);
        final expectedSelectionColor = Theme.of(
          tester.element(selectedRow),
        ).colorScheme.primaryContainer.withValues(alpha: 0.35);
        expect(selectedContainer.color, expectedSelectionColor);

        // Query changes and clearing preserve the intentional permalink
        // selection; it is not a transient query-match highlight.
        await tester.enterText(find.byType(TextField), '效能');
        await tester.pump(const Duration(milliseconds: 250));
        expect(lineIsSelected(tester, 2), isTrue);
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        expect(lineIsSelected(tester, 2), isTrue);

        // 3. Focus preservation: search TextField focusNode
        final textField = tester.widget<TextField>(find.byType(TextField));
        expect(textField.focusNode, isNotNull);
        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(textField.focusNode!.hasFocus, isTrue);

        // 4. Wrap mode toggle preserved
        await tester.tap(find.byTooltip('檔案操作'));
        await tester.pumpAndSettle();
        expect(find.text('關閉自動換行'), findsOneWidget);
        await tester.tap(find.text('關閉自動換行'));
        await tester.pumpAndSettle();

        final horizontalScrolls = find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        );
        expect(horizontalScrolls, findsOneWidget);

        // 5. Scroll controller functional
        final scrollable = find.byType(SingleChildScrollView);
        await tester.drag(scrollable, const Offset(-50, 0));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      '20,000-line synthetic fixture proves observable debounce yield using virtual time',
      (tester) async {
        // Build 20,000-line fixture
        final lines = List<String>.generate(20000, (i) {
          if (i == 500) return 'const uniqueSearchTargetAlpha = 1;';
          if (i == 15000) return 'const uniqueSearchTargetBeta = 2;';
          return 'void functionNumber$i() { print($i); }';
        });
        final largeContent = lines.join('\n');

        final adapter = createFakeAdapter(largeContent);
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          buildTestApp(api: api, filePath: 'lib/large_code.dart'),
        );
        await settleNetworkWidgets(tester);

        // All 20,000 lines indexed initially
        expect(visibleMatchCount(tester), 20000);

        // Rapid typing keystroke 1: 'unique'
        await tester.enterText(find.byType(TextField), 'unique');
        await tester.pump(const Duration(milliseconds: 100));

        // Yield proof: At 100ms, filter did NOT scan 20,000 lines; count remains 20,000
        expect(visibleMatchCount(tester), 20000);

        // Keystroke 2: 'uniqueSearchTarget'
        await tester.enterText(find.byType(TextField), 'uniqueSearchTarget');
        await tester.pump(const Duration(milliseconds: 100));

        // Still yields: count remains 20,000
        expect(visibleMatchCount(tester), 20000);

        // Advance 150ms to cross 250ms threshold
        await tester.pump(const Duration(milliseconds: 150));

        // Evaluated once: exactly 2 matches in 20,000 lines
        expect(visibleMatchCount(tester), 2);

        // Immediate reset back to 20,000 on clear
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        expect(visibleMatchCount(tester), 20000);
      },
    );
  });
}
