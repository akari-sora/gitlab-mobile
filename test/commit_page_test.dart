import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/commit_page.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  const commitSha = '610490b5d140e254476f97a37399eed21bc6e814';
  const parentSha = 'ae1d9fb46aa2b07ee7f73d49608290bb1eaae32d';

  const validDiff = '''
@@ -1,3 +1,4 @@
 line1
-old_line2
+new_line2
+new_line3
 line4
''';

  final sampleCommitJson = {
    'id': commitSha,
    'short_id': '610490b5',
    'title': 'Sanitize input to prevent script injection',
    'message': 'Sanitize input to prevent script injection\n\nDetailed explanation of the security fix.',
    'author_name': 'John Smith',
    'author_email': 'john@example.com',
    'authored_date': '2026-09-24T11:50:22Z',
    'committer_name': 'Jack Smith',
    'committer_email': 'jack@example.com',
    'committed_date': '2026-09-24T12:00:00Z',
    'parent_ids': [parentSha],
    'web_url': 'https://example.com/gitlab/group/project/-/commit/$commitSha',
    'stats': {
      'additions': 2,
      'deletions': 1,
      'total': 3,
    },
  };

  testWidgets('CommitDetailPage displays commit metadata, stats, parents and diff content', (tester) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/commits/$commitSha')) {
        return jsonResponse(sampleCommitJson);
      }
      if (request.uri.path.endsWith('/commits/$commitSha/diff')) {
        return jsonResponse([
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
        ]);
      }
      return jsonResponse({});
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: CommitDetailPage(
          account: account,
          api: api,
          project: project,
          sha: commitSha,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byTooltip('分享連結'), findsOneWidget);
    expect(find.byTooltip('在瀏覽器開啟'), findsOneWidget);

    // Verify Title and message
    expect(find.text('Sanitize input to prevent script injection'), findsOneWidget);
    expect(find.text('Detailed explanation of the security fix.'), findsOneWidget);

    // Verify Author & SHA
    expect(find.text('John Smith <john@example.com>'), findsOneWidget);
    expect(find.text(commitSha), findsOneWidget);

    // Verify Stats chips
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('-1'), findsOneWidget);
    expect(find.text('共 3 行變更'), findsOneWidget);

    // Verify Parent chip
    expect(find.text('父提交：'), findsOneWidget);
    expect(find.text('ae1d9fb4'), findsOneWidget);

    // Verify Diff file header & content
    expect(find.text('lib/sample.dart'), findsOneWidget);
    expect(find.text('line1'), findsOneWidget);
    expect(find.text('old_line2'), findsOneWidget);
    expect(find.text('new_line2'), findsOneWidget);
    expect(find.text('new_line3'), findsOneWidget);
    expect(find.text('line4'), findsOneWidget);

    // Mock clipboard
    String? copied;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        final Object? arguments = call.arguments;
        if (arguments is Map<String, dynamic>) {
          final Object? text = arguments['text'];
          if (text is String) copied = text;
        }
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    // Verify Copy button functionality
    final copyButton = find.byTooltip('複製 Commit SHA');
    expect(copyButton, findsOneWidget);
    await tester.tap(copyButton);
    await tester.pump();
    await tester.pump();
    expect(copied, commitSha);
    expect(find.text('已複製 Commit SHA'), findsOneWidget);
  });

  testWidgets('CommitDetailPage handles binary, collapsed, too_large, and malformed diffs', (tester) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/commits/$commitSha')) {
        return jsonResponse(sampleCommitJson);
      }
      if (request.uri.path.endsWith('/commits/$commitSha/diff')) {
        return jsonResponse([
          {
            'old_path': 'assets/image.png',
            'new_path': 'assets/image.png',
            'a_mode': '100644',
            'b_mode': '100644',
            'new_file': false,
            'renamed_file': false,
            'deleted_file': false,
            'diff': '', // binary
          },
          {
            'old_path': 'large_file.json',
            'new_path': 'large_file.json',
            'a_mode': '100644',
            'b_mode': '100644',
            'too_large': true,
            'diff': '',
          },
          {
            'old_path': 'broken.txt',
            'new_path': 'broken.txt',
            'a_mode': '100644',
            'b_mode': '100644',
            'diff': 'not a unified diff hunk',
          },
        ]);
      }
      return jsonResponse({});
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: CommitDetailPage(
          account: account,
          api: api,
          project: project,
          sha: commitSha,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('assets/image.png'), findsOneWidget);
    expect(find.text('二進位檔案或無文字差異。'), findsOneWidget);

    expect(find.text('large_file.json'), findsOneWidget);
    expect(find.text('GitLab 限制了此差異（檔案過大或已折疊）。'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('broken.txt'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('broken.txt'), findsOneWidget);
    expect(find.text('此差異不完整或超過排版上限。'), findsOneWidget);
  });

  testWidgets('CommitDetailPage expands and collapses files with toolbar actions', (tester) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/commits/$commitSha')) {
        return jsonResponse(sampleCommitJson);
      }
      if (request.uri.path.endsWith('/commits/$commitSha/diff')) {
        return jsonResponse([
          {
            'old_path': 'lib/sample.dart',
            'new_path': 'lib/sample.dart',
            'new_file': false,
            'renamed_file': false,
            'deleted_file': false,
            'diff': validDiff,
          },
        ]);
      }
      return jsonResponse({});
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: CommitDetailPage(
          account: account,
          api: api,
          project: project,
          sha: commitSha,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Initially expanded
    expect(find.text('line1'), findsOneWidget);

    // Collapse All
    await tester.tap(find.text('全部折疊'));
    await tester.pumpAndSettle();
    expect(find.text('line1'), findsNothing);

    // Expand All
    await tester.tap(find.text('全部展開'));
    await tester.pumpAndSettle();
    expect(find.text('line1'), findsOneWidget);

    // Toggle specific file
    await tester.tap(find.text('lib/sample.dart'));
    await tester.pumpAndSettle();
    expect(find.text('line1'), findsNothing);
  });

  testWidgets('CommitDetailPage handles renamed files and mode changes', (tester) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/commits/$commitSha')) {
        return jsonResponse(sampleCommitJson);
      }
      if (request.uri.path.endsWith('/commits/$commitSha/diff')) {
        return jsonResponse([
          {
            'old_path': 'old_name.dart',
            'new_path': 'new_name.dart',
            'a_mode': '100644',
            'b_mode': '100755',
            'new_file': false,
            'renamed_file': true,
            'deleted_file': false,
            'diff': validDiff,
          },
        ]);
      }
      return jsonResponse({});
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: CommitDetailPage(
          account: account,
          api: api,
          project: project,
          sha: commitSha,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('old_name.dart → new_name.dart'), findsOneWidget);
    expect(find.text('模式變更：100644 → 100755'), findsOneWidget);
  });

  testWidgets('CommitDetailPage displays FailureNotice on error and allows retry', (tester) async {
    var failed = true;
    final adapter = FakeAdapter((request) {
      if (failed) {
        throw const ApiFailure(FailureKind.invisible);
      }
      if (request.uri.path.endsWith('/commits/$commitSha')) {
        return jsonResponse(sampleCommitJson);
      }
      if (request.uri.path.endsWith('/commits/$commitSha/diff')) {
        return jsonResponse([]);
      }
      return jsonResponse({});
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: CommitDetailPage(
          account: account,
          api: api,
          project: project,
          sha: commitSha,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify FailureNotice with ambiguous 404 context
    expect(find.byType(FailureNotice), findsOneWidget);
    expect(find.textContaining('group/project · 提交 610490b5'), findsOneWidget);

    // Retry
    failed = false;
    await tester.tap(find.text('重新整理'));
    await tester.pumpAndSettle();

    expect(find.byType(FailureNotice), findsNothing);
    expect(find.text('Sanitize input to prevent script injection'), findsOneWidget);
  });

  testWidgets('CommitDetailPage navigates to parent commit on chip tap', (tester) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/commits/$commitSha')) {
        return jsonResponse(sampleCommitJson);
      }
      if (request.uri.path.endsWith('/commits/$parentSha')) {
        return jsonResponse({
          'id': parentSha,
          'short_id': 'ae1d9fb4',
          'title': 'Initial base commit',
          'message': 'Initial base commit',
          'author_name': 'Parent Author',
          'authored_date': '2026-09-20T10:00:00Z',
          'parent_ids': <String>[],
          'stats': {'additions': 10, 'deletions': 0, 'total': 10},
        });
      }
      if (request.uri.path.endsWith('/diff')) {
        return jsonResponse([]);
      }
      return jsonResponse({});
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: CommitDetailPage(
          account: account,
          api: api,
          project: project,
          sha: commitSha,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Tap parent commit chip
    await tester.tap(find.text('ae1d9fb4'));
    await tester.pumpAndSettle();

    // New CommitDetailPage is pushed for the parent commit
    expect(find.text('Initial base commit'), findsOneWidget);
    expect(find.text(parentSha), findsOneWidget);
  });

  testWidgets('Interactive elements satisfy >= 48dp touch targets', (tester) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/commits/$commitSha')) {
        return jsonResponse(sampleCommitJson);
      }
      if (request.uri.path.endsWith('/commits/$commitSha/diff')) {
        return jsonResponse([
          {
            'old_path': 'lib/sample.dart',
            'new_path': 'lib/sample.dart',
            'diff': validDiff,
          },
        ]);
      }
      return jsonResponse({});
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: CommitDetailPage(
          account: account,
          api: api,
          project: project,
          sha: commitSha,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Copy SHA button size
    final copyFinder = find.byTooltip('複製 Commit SHA');
    final copySize = tester.getSize(copyFinder);
    expect(copySize.width, greaterThanOrEqualTo(48.0));
    expect(copySize.height, greaterThanOrEqualTo(48.0));

    // File header InkWell size
    final fileCardFinder = find.text('lib/sample.dart');
    final fileHeaderAncestor = find.ancestor(
      of: fileCardFinder,
      matching: find.byType(ConstrainedBox),
    ).first;
    final fileHeaderSize = tester.getSize(fileHeaderAncestor);
    expect(fileHeaderSize.height, greaterThanOrEqualTo(48.0));
  });

  testWidgets('ProjectMoreTab opens CommitDetailPage when tapping commit entry', (tester) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/repository/commits')) {
        return jsonResponse([
          {
            'id': commitSha,
            'short_id': '610490b5',
            'title': 'Commit in list',
            'message': 'Commit in list',
            'author_name': 'Author',
            'committed_date': '2026-09-24T12:00:00Z',
          }
        ]);
      }
      if (request.uri.path.endsWith('/commits/$commitSha')) {
        return jsonResponse(sampleCommitJson);
      }
      if (request.uri.path.endsWith('/commits/$commitSha/diff')) {
        return jsonResponse([]);
      }
      return jsonResponse({});
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectMoreTab(
            account: account,
            api: api,
            project: project,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Tap 提交紀錄 tile
    await tester.tap(find.text('提交紀錄'));
    await tester.pumpAndSettle();

    // Tap the commit item in feed
    expect(find.text('Commit in list'), findsOneWidget);
    await tester.tap(find.text('Commit in list'));
    await tester.pumpAndSettle();

    // Expect CommitDetailPage opened
    expect(find.byType(CommitDetailPage), findsOneWidget);
    expect(find.text('SHA: '), findsOneWidget);
  });
}
