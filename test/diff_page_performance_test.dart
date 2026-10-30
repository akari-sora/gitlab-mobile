import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/unified_diff.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final account = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'reviewer', name: 'Reviewer'),
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

  const baseSha = '1111111111111111111111111111111111111111';
  const startSha = '2222222222222222222222222222222222222222';
  const headSha = '3333333333333333333333333333333333333333';

  group('ReviewDiffPage changed files virtualization (SliverList.builder)', () {
    testWidgets(
      'large 100+ files list does not eager build last tile until scrolled',
      (tester) async {
        final diffs = List<Map<String, dynamic>>.generate(
          120,
          (i) => {
            'old_path': 'lib/file_$i.dart',
            'new_path': 'lib/file_$i.dart',
            'a_mode': '100644',
            'b_mode': '100644',
            'new_file': i % 10 == 0,
            'renamed_file': false,
            'deleted_file': false,
            'diff': '@@ -1,2 +1,2 @@\n-old $i\n+new $i',
          },
        );

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': diffs,
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        // First item is immediately visible
        expect(find.text('lib/file_0.dart'), findsOneWidget);

        // Tile 119 is offscreen and NOT yet instantiated in the element tree
        expect(
          find.text('lib/file_119.dart'),
          findsNothing,
          reason: 'SliverList.builder must not eagerly build offscreen items',
        );

        // Scroll down to the bottom
        final scrollable = find.byType(CustomScrollView);
        expect(scrollable, findsOneWidget);
        await tester.drag(scrollable, const Offset(0, -6000));
        await tester.pump();
        await tester.drag(scrollable, const Offset(0, -6000));
        await tester.pump();

        // Now tile 119 is scrolled into viewport and built
        expect(find.text('lib/file_119.dart'), findsOneWidget);

        // Offscreen top tile 0 is recycled and no longer mounted
        expect(
          find.text('lib/file_0.dart'),
          findsNothing,
          reason:
              'SliverList.builder must recycle offscreen items above viewport',
        );
      },
    );

    testWidgets(
      'header, review progress card, empty state, and actions remain accessible',
      (tester) async {
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/a.dart',
                  'new_path': 'lib/a.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': '@@ -1,1 +1,1 @@\n-a\n+b',
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        // Header
        expect(find.textContaining('固定版本 33333333'), findsOneWidget);
        // Review progress card
        expect(find.text('審查進度 (0/1)'), findsOneWidget);

        // Toggle all viewed button
        final toggleBtn = find.byKey(const ValueKey('toggle-all-viewed'));
        expect(toggleBtn, findsOneWidget);
        await tester.tap(toggleBtn);
        await tester.pump();
        expect(find.text('審查進度 (1/1)'), findsOneWidget);

        // Untoggle all viewed
        await tester.tap(toggleBtn);
        await tester.pump();
        expect(find.text('審查進度 (0/1)'), findsOneWidget);

        // Test empty diffs state
        final emptyAdapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': <Map<String, dynamic>>[],
            });
          }
          return jsonResponse([]);
        });
        final emptyApi = testApi(emptyAdapter);
        addTearDown(emptyApi.close);

        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey('empty-diff-host'),
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: emptyApi,
                project: project,
                iid: 10,
                expectedSha: headSha,
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        expect(find.text('沒有可顯示的文字差異'), findsOneWidget);
        expect(find.text('可能沒有變更，或差異未由伺服器提供。'), findsOneWidget);
      },
    );

    testWidgets('changed-file header and actions fit 320dp at 2x text scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 1, 'head_commit_sha': headSha},
          ]);
        }
        if (path.endsWith('/versions/1')) {
          return jsonResponse({
            'id': 1,
            'head_commit_sha': headSha,
            'base_commit_sha': baseSha,
            'start_commit_sha': startSha,
            'diffs': [
              {
                'old_path': 'lib/very_long_previous_filename_for_mobile.dart',
                'new_path': 'lib/very_long_changed_filename_for_mobile.dart',
                'new_file': false,
                'renamed_file': true,
                'deleted_file': false,
                'diff': '@@ -1,1 +1,1 @@\n-old\n+new',
              },
            ],
          });
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('審查進度'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('toggle-all-viewed'))).height,
        greaterThanOrEqualTo(48),
      );
      final rowAction = find.byKey(
        const ValueKey(
          'viewed-toggle-lib/very_long_changed_filename_for_mobile.dart',
        ),
      );
      expect(rowAction, findsOneWidget);
      expect(tester.getSize(rowAction).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(rowAction).width, greaterThanOrEqualTo(48));
    });
  });

  group('_DiffFileScreen asynchronous diff parsing & lifecycle', () {
    testWidgets(
      'held injected parser paints loading before lifecycle completion',
      (tester) async {
        final buffer = StringBuffer('@@ -1,2000 +1,2000 @@\n');
        for (var i = 1; i <= 2000; i++) {
          buffer.write(' line$i\n');
        }
        final largeDiff = buffer.toString();

        final completer = Completer<List<DiffLine>>();
        var parserCalls = 0;

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/large.dart',
                  'new_path': 'lib/large.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': largeDiff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                diffParser: (source) {
                  parserCalls++;
                  return completer.future;
                },
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        // Tap file to navigate to _DiffFileScreen
        await tester.tap(find.text('lib/large.dart'));
        await tester.pump(const Duration(milliseconds: 400));

        // Verify that the screen immediately displays an honest loading state without blocking
        expect(parserCalls, 1);
        expect(find.byType(DiffSkeleton, skipOffstage: false), findsOneWidget);
        expect(
          find.byType(CircularProgressIndicator, skipOffstage: false),
          findsNothing,
        );
        // Verify it does NOT render fake empty state while loading
        expect(find.text('無法顯示差異'), findsNothing);

        // Complete the async parse in the background
        completer.complete(parseUnifiedDiff(largeDiff));
        await settleNetworkWidgets(tester);

        // Loading indicator is gone, lines are rendered
        expect(find.byType(DiffSkeleton), findsNothing);
        expect(find.text('line1'), findsOneWidget);
      },
    );

    testWidgets(
      'default parser over 64KiB UTF-8 paints loading then parsed rows',
      (tester) async {
        final buffer = StringBuffer('@@ -1,3000 +1,3000 @@\n');
        for (var i = 1; i <= 3000; i++) {
          buffer.writeln(' 中文差異內容-$i-abcdefghijklmnop');
        }
        final source = buffer.toString();
        expect(utf8.encode(source).length, greaterThan(64 * 1024));

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/production_compute.dart',
                  'new_path': 'lib/production_compute.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': source,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        await tester.tap(find.text('lib/production_compute.dart'));
        await tester.pump();
        expect(find.byType(DiffSkeleton, skipOffstage: false), findsOneWidget);

        await pumpUntil(
          tester,
          () => find.textContaining('中文差異內容-1-').evaluate().isNotEmpty,
          description: 'default production parser completion',
        );
        expect(find.byType(DiffSkeleton), findsNothing);
        expect(find.textContaining('中文差異內容-1-'), findsOneWidget);
      },
    );

    testWidgets(
      'correct target line anchor reveals after async compute and first layout',
      (tester) async {
        final buffer = StringBuffer('@@ -1,50 +1,50 @@\n');
        for (var i = 1; i <= 50; i++) {
          if (i == 30) {
            buffer.write('-old30\n+new30\n');
          } else {
            buffer.write(' line$i\n');
          }
        }
        final targetDiff = buffer.toString();

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/target.dart',
                  'new_path': 'lib/target.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': targetDiff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        final target = DiffTarget(
          path: 'lib/target.dart',
          newPath: 'lib/target.dart',
          newLine: 30,
          baseSha: baseSha,
          startSha: startSha,
          headSha: headSha,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                initialTarget: target,
                diffParser: (source) async => parseUnifiedDiff(source),
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        // Automatic opening of targeted file
        await settleNetworkWidgets(tester);

        // The exact added target row is index 31; index 30 is the adjacent
        // removed line and cannot establish target placement.
        expect(find.text('new30'), findsOneWidget);
        final targetRow = find.byKey(const ValueKey('diff-line-31'));
        expect(targetRow, findsOneWidget);
        expect(find.byKey(const ValueKey('built-line-31')), findsOneWidget);
        final targetRect = tester.getRect(targetRow);
        final logicalHeight =
            tester.view.physicalSize.height / tester.view.devicePixelRatio;
        expect(targetRect.top, greaterThanOrEqualTo(0));
        expect(targetRect.bottom, lessThanOrEqualTo(logicalHeight));
        final lineList = tester.widget<ListView>(find.byType(ListView));
        expect(
          lineList.controller!.offset,
          greaterThan(0),
          reason: 'The exact target row must be revealed by scrolling.',
        );
      },
    );

    testWidgets(
      'wrong, missing, or truncated target anchor reveals truthful fallback reason in footer',
      (tester) async {
        const diff = '@@ -1,3 +1,3 @@\n line1\n-line2\n+line2_mod\n line3\n';

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/file.dart',
                  'new_path': 'lib/file.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': diff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        // Case A: Target references line 999 which does not exist in the diff (matching SHAs)
        final targetMissingLine = DiffTarget(
          path: 'lib/file.dart',
          newPath: 'lib/file.dart',
          newLine: 999,
          baseSha: baseSha,
          startSha: startSha,
          headSha: headSha,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                initialTarget: targetMissingLine,
                diffParser: (source) async => parseUnifiedDiff(source),
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        await settleNetworkWidgets(tester);

        // Truthful fallback reason when SHAs match: line was omitted/truncated from current diff
        expect(find.textContaining('目前差異未提供此行（可能已折疊或超出大小上限）'), findsOneWidget);

        // Case B: Target references older version commit SHAs
        final targetOlderSha = DiffTarget(
          path: 'lib/file.dart',
          newPath: 'lib/file.dart',
          newLine: 2,
          baseSha: '0000000000000000000000000000000000000000',
          startSha: startSha,
          headSha: '0000000000000000000000000000000000000000',
        );

        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey('older-target-host'),
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                initialTarget: targetOlderSha,
                diffParser: (source) async => parseUnifiedDiff(source),
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        await settleNetworkWidgets(tester);

        // Truthful fallback reason when SHAs do not match: based on older version
        expect(find.textContaining('以較舊版本為準，無法對應目前差異'), findsOneWidget);
      },
    );

    testWidgets(
      'back/dispose during pending parse drops result cleanly without framework errors',
      (tester) async {
        final completer = Completer<List<DiffLine>>();
        var parserCalls = 0;

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/dispose_test.dart',
                  'new_path': 'lib/dispose_test.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': '@@ -1,1 +1,1 @@\n-old\n+new',
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                diffParser: (source) {
                  parserCalls++;
                  return completer.future;
                },
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        // Open file screen
        await tester.tap(find.text('lib/dispose_test.dart'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(parserCalls, 1);

        // Pop the file screen while parse is pending
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();

        // Now complete the pending isolate parse after unmount
        completer.complete(parseUnifiedDiff('@@ -1,1 +1,1 @@\n-old\n+new'));
        await tester.pump(const Duration(milliseconds: 50));

        // Zero framework errors / no setState() called on unmounted state
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'closing the API during a pending parse rejects late rows before display',
      (tester) async {
        final completer = Completer<List<DiffLine>>();
        var parserCalls = 0;
        const diff = '@@ -1,1 +1,1 @@\n-before_close\n+after_close';

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/closed.dart',
                  'new_path': 'lib/closed.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': diff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                diffParser: (_) {
                  parserCalls++;
                  return completer.future;
                },
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        await tester.tap(find.text('lib/closed.dart'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(parserCalls, 1);

        api.close();
        completer.complete(parseUnifiedDiff(diff));
        await tester.pump();

        expect(
          find.text('after_close'),
          findsNothing,
          reason:
              'A closed account API must never display a late parse result.',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'identical source through two injected parsers never cross-reuses rows',
      (tester) async {
        const diff = '@@ -1,1 +1,1 @@\n-old\n+new';
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/parser_identity.dart',
                  'new_path': 'lib/parser_identity.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': diff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        var firstCalls = 0;
        var secondCalls = 0;

        Widget host(DiffParser parser) => MaterialApp(
          home: ReviewDiffPage(
            account: account,
            api: api,
            project: project,
            iid: 10,
            expectedSha: headSha,
            diffParser: parser,
          ),
        );

        await tester.pumpWidget(
          host((_) async {
            firstCalls++;
            return const [
              DiffLine('from-parser-a', 'context', oldLine: 1, newLine: 1),
            ];
          }),
        );
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/parser_identity.dart'));
        await settleNetworkWidgets(tester);
        expect(find.text('from-parser-a'), findsOneWidget);
        await tester.pageBack();
        await settleNetworkWidgets(tester);

        await tester.pumpWidget(
          host((_) async {
            secondCalls++;
            return const [
              DiffLine('from-parser-b', 'context', oldLine: 1, newLine: 1),
            ];
          }),
        );
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/parser_identity.dart'));
        await settleNetworkWidgets(tester);

        expect(firstCalls, 1);
        expect(secondCalls, 1);
        expect(find.text('from-parser-b'), findsOneWidget);
        expect(find.text('from-parser-a'), findsNothing);
      },
    );

    testWidgets('parser replacement route rejects old pending completion', (
      tester,
    ) async {
      const diff = '@@ -1,1 +1,1 @@\n-old\n+new';
      final pending = Completer<List<DiffLine>>();
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 1, 'head_commit_sha': headSha},
          ]);
        }
        if (path.endsWith('/versions/1')) {
          return jsonResponse({
            'id': 1,
            'head_commit_sha': headSha,
            'base_commit_sha': baseSha,
            'start_commit_sha': startSha,
            'diffs': [
              {
                'old_path': 'lib/parser_pending.dart',
                'new_path': 'lib/parser_pending.dart',
                'new_file': false,
                'renamed_file': false,
                'deleted_file': false,
                'diff': diff,
              },
            ],
          });
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      Widget host({required Key key, required DiffParser parser}) =>
          MaterialApp(
            key: key,
            home: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
              diffParser: parser,
            ),
          );

      await tester.pumpWidget(
        host(
          key: const ValueKey('pending-parser-host'),
          parser: (_) => pending.future,
        ),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('lib/parser_pending.dart'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DiffSkeleton, skipOffstage: false), findsOneWidget);

      await tester.pumpWidget(
        host(
          key: const ValueKey('replacement-parser-host'),
          parser: (_) async => const [
            DiffLine(
              'replacement-parser-row',
              'context',
              oldLine: 1,
              newLine: 1,
            ),
          ],
        ),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('lib/parser_pending.dart'));
      await settleNetworkWidgets(tester);
      expect(find.text('replacement-parser-row'), findsOneWidget);

      pending.complete(const [
        DiffLine('stale-parser-row', 'context', oldLine: 1, newLine: 1),
      ]);
      await tester.pump();
      expect(find.text('stale-parser-row'), findsNothing);
      expect(find.text('replacement-parser-row'), findsOneWidget);
    });

    testWidgets(
      'UTF-8 source budget rejects multibyte diff before parser invocation',
      (tester) async {
        final source =
            '@@ -1,1 +1,1 @@\n ${List<String>.filled(700000, '界').join()}\n';
        expect(source.length, lessThan(2 * 1024 * 1024));
        expect(utf8.encode(source).length, greaterThan(2 * 1024 * 1024));
        var parserCalls = 0;
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/multibyte.dart',
                  'new_path': 'lib/multibyte.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': source,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
              diffParser: (_) async {
                parserCalls++;
                return const [];
              },
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/multibyte.dart'));
        await settleNetworkWidgets(tester);

        expect(parserCalls, 0);
        expect(find.textContaining('這份差異不完整或超過排版上限'), findsOneWidget);
      },
    );

    testWidgets(
      'character count above UTF-8 budget rejects before parser invocation',
      (tester) async {
        final source =
            '@@ -1,1 +1,1 @@\n ${List<String>.filled(2 * 1024 * 1024, 'a').join()}\n';
        expect(source.length, greaterThan(2 * 1024 * 1024));
        var parserCalls = 0;
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/over_character_budget.dart',
                  'new_path': 'lib/over_character_budget.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': source,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
              diffParser: (_) async {
                parserCalls++;
                return const [];
              },
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/over_character_budget.dart'));
        await settleNetworkWidgets(tester);

        expect(parserCalls, 0);
        expect(find.textContaining('這份差異不完整或超過排版上限'), findsOneWidget);
      },
    );

    testWidgets(
      'injected parser output above line budget is rejected before render',
      (tester) async {
        const diff = '@@ -1,1 +1,1 @@\n-old\n+new';
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/excessive_lines.dart',
                  'new_path': 'lib/excessive_lines.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': diff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
              diffParser: (_) async => List<DiffLine>.unmodifiable(
                List<DiffLine>.generate(
                  20001,
                  (index) => DiffLine(
                    'row-$index',
                    'context',
                    oldLine: index + 1,
                    newLine: index + 1,
                  ),
                ),
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/excessive_lines.dart'));
        await settleNetworkWidgets(tester);

        expect(find.text('row-0'), findsNothing);
        expect(find.textContaining('這份差異不完整或超過排版上限'), findsOneWidget);
      },
    );

    testWidgets('same file rebuild does not reparse injected parser rows', (
      tester,
    ) async {
      var parseCount = 0;
      const diff = '@@ -1,1 +1,1 @@\n-alpha\n+beta';

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 1, 'head_commit_sha': headSha},
          ]);
        }
        if (path.endsWith('/versions/1')) {
          return jsonResponse({
            'id': 1,
            'head_commit_sha': headSha,
            'base_commit_sha': baseSha,
            'start_commit_sha': startSha,
            'diffs': [
              {
                'old_path': 'lib/cached.dart',
                'new_path': 'lib/cached.dart',
                'new_file': false,
                'renamed_file': false,
                'deleted_file': false,
                'diff': diff,
              },
            ],
          });
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
              diffParser: (source) async {
                parseCount++;
                return parseUnifiedDiff(source);
              },
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // Open file
      await tester.tap(find.text('lib/cached.dart'));
      await settleNetworkWidgets(tester);

      expect(parseCount, 1);
      expect(find.text('beta'), findsOneWidget);

      // Rebuild file screen (e.g. toggle viewed in AppBar)
      final viewedToggle = find.byKey(
        const ValueKey('diff-file-viewed-toggle'),
      );
      expect(viewedToggle, findsOneWidget);
      await tester.tap(viewedToggle);
      await tester.pump();

      // parseCount must not increase
      expect(
        parseCount,
        1,
        reason: 'Rebuilding the same file screen must not reparse',
      );

      await tester.pageBack();
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('lib/cached.dart'));
      await settleNetworkWidgets(tester);

      expect(
        parseCount,
        2,
        reason:
            'Injected parsers are screen-local and must not share production cache rows.',
      );
    });

    testWidgets(
      'real resource/diff change immediately invalidates rows and re-parses',
      (tester) async {
        var parseCount = 0;
        const diffA = '@@ -1,1 +1,1 @@\n-old_a\n+new_alpha';
        const diffB = '@@ -1,1 +1,1 @@\n-old_b\n+new_beta';

        var activeDiff = diffA;

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/dynamic.dart',
                  'new_path': 'lib/dynamic.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': activeDiff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                diffParser: (source) async {
                  parseCount++;
                  return parseUnifiedDiff(source);
                },
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        // Open file screen with diff A
        await tester.tap(find.text('lib/dynamic.dart'));
        await settleNetworkWidgets(tester);

        expect(parseCount, 1);
        expect(find.text('new_alpha'), findsOneWidget);

        // Replace the active route tree with the same resource carrying new content.
        activeDiff = diffB;
        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey('changed-diff-host'),
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                diffParser: (source) async {
                  parseCount++;
                  return parseUnifiedDiff(source);
                },
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        // Re-open file screen with diff B
        await tester.tap(find.text('lib/dynamic.dart'));
        await settleNetworkWidgets(tester);

        // parseCount must have incremented and new diff displayed
        expect(
          parseCount,
          2,
          reason: 'Changed diff content must trigger re-parse',
        );
        expect(find.text('new_beta'), findsOneWidget);
        expect(
          find.text('new_alpha'),
          findsNothing,
          reason: 'Stale rows must not be painted',
        );
      },
    );

    testWidgets(
      'shared production cache verifies exact source despite hash collision',
      (tester) async {
        String? first;
        String? second;
        final byHash = <int, String>{};
        for (var i = 0; i < 200000 && second == null; i++) {
          final marker = i.toRadixString(36).padLeft(8, '0');
          final candidate = '@@ -1,1 +1,1 @@\n collision-$marker\n';
          final prior = byHash[candidate.hashCode];
          if (prior != null &&
              prior != candidate &&
              prior.length == candidate.length) {
            first = prior;
            second = candidate;
          } else {
            byHash[candidate.hashCode] = candidate;
          }
        }
        expect(
          first,
          isNotNull,
          reason: 'Expected a controlled hash collision',
        );
        expect(second, isNotNull);
        final collisionA = first!;
        final collisionB = second!;
        expect(collisionA, isNot(collisionB));
        expect(collisionA.length, collisionB.length);
        expect(collisionA.hashCode, collisionB.hashCode);

        var activeDiff = collisionA;
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/collision.dart',
                  'new_path': 'lib/collision.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': activeDiff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/collision.dart'));
        await settleNetworkWidgets(tester);
        final firstMarker = collisionA
            .split('\n')
            .firstWhere((line) => line.startsWith(' collision-'))
            .substring(1);
        expect(find.text(firstMarker), findsOneWidget);
        await tester.pageBack();
        await settleNetworkWidgets(tester);

        activeDiff = collisionB;
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/collision.dart'));
        await settleNetworkWidgets(tester);

        final secondMarker = collisionB
            .split('\n')
            .firstWhere((line) => line.startsWith(' collision-'))
            .substring(1);
        expect(find.text(secondMarker), findsOneWidget);
        expect(find.text(firstMarker), findsNothing);
      },
    );

    testWidgets(
      'aggregate production cache byte budget evicts oldest exact source',
      (tester) async {
        String largeDiff(String marker) {
          final payload = List<String>.filled(900, marker).join();
          final buffer = StringBuffer('@@ -1,1500 +1,1500 @@\n');
          for (var i = 0; i < 1500; i++) {
            buffer.writeln(' $i-$payload');
          }
          return buffer.toString();
        }

        final sources = [largeDiff('a'), largeDiff('b'), largeDiff('c')];
        for (final source in sources) {
          expect(utf8.encode(source).length, lessThan(2 * 1024 * 1024));
          expect(utf8.encode(source).length, greaterThan(1024 * 1024));
        }

        final diffs = [
          for (var i = 0; i < sources.length; i++)
            {
              'old_path': 'lib/cache_$i.dart',
              'new_path': 'lib/cache_$i.dart',
              'new_file': false,
              'renamed_file': false,
              'deleted_file': false,
              'diff': sources[i],
            },
        ];
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': diffs,
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        for (var i = 0; i < sources.length; i++) {
          await tester.tap(find.text('lib/cache_$i.dart'));
          await settleNetworkWidgets(tester);
          expect(find.textContaining('0-${'abc'[i]}'), findsWidgets);
          await tester.pageBack();
          await settleNetworkWidgets(tester);
        }

        await tester.tap(find.text('lib/cache_0.dart'));
        await tester.pump();
        expect(
          find.byType(DiffSkeleton, skipOffstage: false),
          findsOneWidget,
          reason:
              'Three retained source+parsed payloads exceed the 8 MiB estimate, so the oldest must reparse.',
        );
        await settleNetworkWidgets(tester);
        expect(find.textContaining('0-a'), findsWidgets);
      },
    );

    testWidgets(
      'diff parser failure displays truthful FailureNotice and onRetry re-triggers parse',
      (tester) async {
        var parseCount = 0;
        var shouldFail = true;
        const diff = '@@ -1,1 +1,1 @@\n-err_old\n+err_new';

        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/error_test.dart',
                  'new_path': 'lib/error_test.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': diff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReviewDiffPage(
                account: account,
                api: api,
                project: project,
                iid: 10,
                expectedSha: headSha,
                diffParser: (source) async {
                  parseCount++;
                  if (shouldFail) {
                    throw Exception('Simulated parser crash');
                  }
                  return parseUnifiedDiff(source);
                },
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);

        // Open file screen
        await tester.tap(find.text('lib/error_test.dart'));
        await settleNetworkWidgets(tester);

        expect(parseCount, 1);
        // FailureNotice is displayed (not fake empty)
        expect(find.byType(FailureNotice), findsOneWidget);
        expect(find.text('lib/error_test.dart'), findsOneWidget);
        expect(find.text('重新整理'), findsOneWidget);

        // Recover and tap retry
        shouldFail = false;
        await tester.tap(find.text('重新整理'));
        await settleNetworkWidgets(tester);

        expect(parseCount, 2);
        expect(find.byType(FailureNotice), findsNothing);
        expect(find.text('err_new'), findsOneWidget);
      },
    );

    testWidgets(
      'production cache reuses exact same owner resource and isolates replacement API',
      (tester) async {
        final buffer = StringBuffer('@@ -1,3000 +1,3000 @@\n');
        for (var i = 1; i <= 3000; i++) {
          buffer.writeln(' account-cache-$i-abcdefghijklmnop');
        }
        final diff = buffer.toString();
        expect(utf8.encode(diff).length, greaterThan(64 * 1024));

        FakeAdapter adapterForAccountTest() => FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': 'lib/account_test.dart',
                  'new_path': 'lib/account_test.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': diff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapterForAccountTest());
        addTearDown(api.close);

        Widget buildHost(Account act, GitLabApi client) => MaterialApp(
          home: Scaffold(
            body: ReviewDiffPage(
              account: act,
              api: client,
              project: project,
              iid: 10,
              expectedSha: headSha,
            ),
          ),
        );

        await tester.pumpWidget(buildHost(account, api));
        await settleNetworkWidgets(tester);

        await tester.tap(find.text('lib/account_test.dart'));
        await settleNetworkWidgets(tester);

        expect(find.textContaining('account-cache-1-'), findsOneWidget);

        // Rebuild with a fresh Account instance but identical key (same user id 7)
        final sameKeyAccount = Account(
          instance: instance,
          user: const GitLabUser(id: 7, username: 'reviewer', name: 'Reviewer'),
          token: 'another-synthetic-token',
        );
        expect(sameKeyAccount.key, account.key);

        await tester.pageBack();
        await settleNetworkWidgets(tester);
        await tester.pumpWidget(buildHost(sameKeyAccount, api));
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/account_test.dart'));
        await tester.pump();
        expect(
          find.byType(DiffSkeleton, skipOffstage: false),
          findsNothing,
          reason:
              'The exact same production source should be an immediate hit.',
        );
        expect(
          find.textContaining('account-cache-1-', skipOffstage: false),
          findsOneWidget,
        );

        await settleNetworkWidgets(tester);
        await tester.pageBack();
        await settleNetworkWidgets(tester);
        final changedAccount = Account(
          instance: instance,
          user: const GitLabUser(id: 99, username: 'other', name: 'Other'),
          token: 'other-synthetic-token',
        );
        final changedApi = testApi(adapterForAccountTest());
        addTearDown(changedApi.close);

        await tester.pumpWidget(buildHost(changedAccount, changedApi));
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('lib/account_test.dart'));
        await tester.pump();
        expect(
          find.byType(DiffSkeleton, skipOffstage: false),
          findsOneWidget,
          reason: 'A replacement API owner must not reuse another API cache.',
        );
        await settleNetworkWidgets(tester);
        expect(find.textContaining('account-cache-1-'), findsOneWidget);
      },
    );

    testWidgets(
      'production cache isolates account project MR head and path replacements',
      (tester) async {
        final buffer = StringBuffer('@@ -1,3000 +1,3000 @@\n');
        for (var i = 1; i <= 3000; i++) {
          buffer.writeln(' scoped-cache-$i-abcdefghijklmnop');
        }
        final diff = buffer.toString();
        expect(utf8.encode(diff).length, greaterThan(64 * 1024));

        var activeHead = headSha;
        var activePath = 'lib/scoped.dart';
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': activeHead},
            ]);
          }
          if (path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': activeHead,
              'base_commit_sha': baseSha,
              'start_commit_sha': startSha,
              'diffs': [
                {
                  'old_path': activePath,
                  'new_path': activePath,
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': diff,
                },
              ],
            });
          }
          return jsonResponse([]);
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final otherAccount = Account(
          instance: instance,
          user: const GitLabUser(id: 99, username: 'other', name: 'Other'),
          token: 'other-synthetic-token',
        );
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

        Widget host({
          required String scope,
          required Account owner,
          required Project targetProject,
          required int iid,
          required String expectedHead,
        }) => MaterialApp(
          home: ReviewDiffPage(
            key: ValueKey(scope),
            account: owner,
            api: api,
            project: targetProject,
            iid: iid,
            expectedSha: expectedHead,
          ),
        );

        Future<void> openAndPopulate({
          required String scope,
          required Account owner,
          required Project targetProject,
          required int iid,
          required String expectedHead,
          required String path,
          bool expectLoading = true,
        }) async {
          activeHead = expectedHead;
          activePath = path;
          await tester.pumpWidget(
            host(
              scope: scope,
              owner: owner,
              targetProject: targetProject,
              iid: iid,
              expectedHead: expectedHead,
            ),
          );
          await settleNetworkWidgets(tester);
          await tester.tap(find.text(path));
          await tester.pump();
          expect(
            find.byType(DiffSkeleton, skipOffstage: false),
            expectLoading ? findsOneWidget : findsNothing,
          );
          await settleNetworkWidgets(tester);
          await tester.pageBack();
          await settleNetworkWidgets(tester);
        }

        await openAndPopulate(
          scope: 'base',
          owner: account,
          targetProject: project,
          iid: 10,
          expectedHead: headSha,
          path: 'lib/scoped.dart',
        );
        await openAndPopulate(
          scope: 'same-exact',
          owner: account,
          targetProject: project,
          iid: 10,
          expectedHead: headSha,
          path: 'lib/scoped.dart',
          expectLoading: false,
        );
        await openAndPopulate(
          scope: 'account',
          owner: otherAccount,
          targetProject: project,
          iid: 10,
          expectedHead: headSha,
          path: 'lib/scoped.dart',
        );
        await openAndPopulate(
          scope: 'project',
          owner: account,
          targetProject: otherProject,
          iid: 10,
          expectedHead: headSha,
          path: 'lib/scoped.dart',
        );
        await openAndPopulate(
          scope: 'mr',
          owner: account,
          targetProject: project,
          iid: 11,
          expectedHead: headSha,
          path: 'lib/scoped.dart',
        );
        await openAndPopulate(
          scope: 'head',
          owner: account,
          targetProject: project,
          iid: 10,
          expectedHead: '4444444444444444444444444444444444444444',
          path: 'lib/scoped.dart',
        );
        await openAndPopulate(
          scope: 'path',
          owner: account,
          targetProject: project,
          iid: 10,
          expectedHead: headSha,
          path: 'lib/other_scoped.dart',
        );
      },
    );
  });
}
