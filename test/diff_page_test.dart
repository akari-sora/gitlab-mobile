import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
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

  final validDiff = '''
@@ -1,3 +1,4 @@
 line1
-old_line2
+new_line2
+new_line3
 line4
''';

  final sampleVersion = {
    'id': 1,
    'head_commit_sha': headSha,
    'base_commit_sha': baseSha,
    'start_commit_sha': startSha,
    'diffs': [
      {
        'old_path': 'lib/sample.dart',
        'new_path': 'lib/sample.dart',
        'a_mode': '100644',
        'b_mode': '100644',
        'new_file': false,
        'renamed_file': false,
        'deleted_file': false,
        'diff': validDiff,
      },
    ],
  };

  testWidgets('DiffPage shows empty state when no diffs available', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/versions')) {
        return jsonResponse([
          {'id': 1, 'head_commit_sha': headSha},
        ]);
      }
      if (request.uri.path.endsWith('/versions/1')) {
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

    expect(find.text('沒有可顯示的文字差異'), findsOneWidget);
  });

  testWidgets('ReviewDiffPage shows error notice on network failure', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({'message': 'not found'}, status: 404),
    );
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

    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('App 帳號：@reviewer'), findsOneWidget);
  });

  testWidgets(
    'ReviewDiffPage lists diff files and opens file with >= 48 dp line tap target',
    (tester) async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 1, 'head_commit_sha': headSha},
          ]);
        }
        if (request.uri.path.endsWith('/versions/1')) {
          return jsonResponse(sampleVersion);
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

      expect(find.text('lib/sample.dart'), findsOneWidget);
      await tester.tap(find.text('lib/sample.dart'));
      await settleNetworkWidgets(tester);

      // Verify file diff screen is presented
      expect(find.text('點選程式碼行新增留言 · 33333333'), findsOneWidget);
      expect(find.text('line1'), findsOneWidget);
      expect(find.text('old_line2'), findsOneWidget);
      expect(find.text('new_line2'), findsOneWidget);

      // Verify tap target height satisfies the 48 dp minimum requirement
      for (var i = 0; i < 4; i++) {
        final lineFinder = find.byKey(ValueKey('diff-line-$i'));
        expect(lineFinder, findsOneWidget);
        final size = tester.getSize(lineFinder);
        expect(
          size.height,
          greaterThanOrEqualTo(48.0),
          reason: 'Line $i tap target height must be at least 48 dp',
        );
      }
    },
  );

  testWidgets('DiffFileScreen shows empty state for collapsed/too_large diff', (
    tester,
  ) async {
    final collapsedVersion = {
      'id': 1,
      'head_commit_sha': headSha,
      'base_commit_sha': baseSha,
      'start_commit_sha': startSha,
      'diffs': [
        {
          'old_path': 'assets/big.bin',
          'new_path': 'assets/big.bin',
          'too_large': true,
          'diff': '',
        },
      ],
    };

    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/versions')) {
        return jsonResponse([
          {'id': 1, 'head_commit_sha': headSha},
        ]);
      }
      if (request.uri.path.endsWith('/versions/1')) {
        return jsonResponse(collapsedVersion);
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

    await tester.tap(find.text('assets/big.bin'));
    await settleNetworkWidgets(tester);

    expect(find.text('無法顯示差異'), findsOneWidget);
    expect(find.text('GitLab 未提供這份文字差異，或內容為二進位檔案。'), findsOneWidget);
  });

  testWidgets(
    'tapping commentable line opens editor and posts discussion with position',
    (tester) async {
      Map<String, dynamic>? postedDiscussion;

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 1, 'head_commit_sha': headSha},
          ]);
        }
        if (path.endsWith('/versions/1')) {
          return jsonResponse(sampleVersion);
        }
        if (path.endsWith('/projects/42/merge_requests/10') &&
            request.method == 'GET') {
          return jsonResponse({'sha': headSha});
        }
        if (path.endsWith('/projects/42/merge_requests/10/discussions') &&
            request.method == 'POST') {
          postedDiscussion = request.data is Map<String, dynamic>
              ? request.data as Map<String, dynamic>
              : null;
          return jsonResponse({
            'id': 'new-disc',
            'notes': <dynamic>[],
          }, status: 201);
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

      // Open file
      await tester.tap(find.text('lib/sample.dart'));
      await settleNetworkWidgets(tester);

      // Tap on line "new_line2"
      await tester.tap(find.text('new_line2'));
      await settleNetworkWidgets(tester);

      // Editor should be open
      expect(find.text('對這一行留言'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'Looks good to me!');
      await tester.tap(find.text('儲存'));
      await settleNetworkWidgets(tester);

      expect(postedDiscussion, isNotNull);
      expect(postedDiscussion!['body'], 'Looks good to me!');
      final position = postedDiscussion!['position'] as Map<String, dynamic>;
      expect(position['position_type'], 'text');
      expect(position['base_sha'], baseSha);
      expect(position['head_sha'], headSha);
      expect(position['start_sha'], startSha);
      expect(position['new_path'], 'lib/sample.dart');
      expect(position['new_line'], 2);
    },
  );

  testWidgets(
    'Diff lines satisfy >= 48 dp tap target and top-aligned layout on 320 dp screen with 2.0x scale',
    (tester) async {
      const largeLineDiff = '''
@@ -1024,3 +1024,4 @@
 line1024
-old_line1025_with_very_long_content_that_will_wrap_to_multiple_lines_on_narrow_mobile_screen
+new_line1025_with_very_long_content_that_will_wrap_to_multiple_lines_on_narrow_mobile_screen
+new_line1026
 line1027
''';
      final largeVersion = {
        'id': 2,
        'head_commit_sha': headSha,
        'base_commit_sha': baseSha,
        'start_commit_sha': startSha,
        'diffs': [
          {
            'old_path': 'lib/sample_large.dart',
            'new_path': 'lib/sample_large.dart',
            'a_mode': '100644',
            'b_mode': '100644',
            'new_file': false,
            'renamed_file': false,
            'deleted_file': false,
            'diff': largeLineDiff,
          },
        ],
      };

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 2, 'head_commit_sha': headSha},
          ]);
        }
        if (path.endsWith('/versions/2')) {
          return jsonResponse(largeVersion);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.0)),
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

      await tester.tap(find.text('lib/sample_large.dart'));
      await settleNetworkWidgets(tester);

      expect(tester.takeException(), isNull);
      for (var i = 0; i < 4; i++) {
        final lineFinder = find.byKey(ValueKey('diff-line-$i'));
        expect(lineFinder, findsOneWidget);
        final size = tester.getSize(lineFinder);
        expect(size.height, greaterThanOrEqualTo(48.0));
      }
    },
  );
}
