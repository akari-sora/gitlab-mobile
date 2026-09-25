import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

void main() {
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

  const sha = '1111111111111111111111111111111111111111';

  testWidgets('RepositoryTab discovers root README.md and renders collapsible preview card', (tester) async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/branches/main')) {
        return jsonResponse({
          'name': 'main',
          'protected': true,
          'default': true,
          'commit': {'id': sha},
        });
      }
      if (path.endsWith('/repository/tree') && request.uri.queryParameters['path'] == '') {
        return jsonResponse([
          {
            'id': 'tree-1',
            'name': 'src',
            'type': 'tree',
            'path': 'src',
            'mode': '040000',
          },
          {
            'id': 'blob-1',
            'name': 'README.md',
            'type': 'blob',
            'path': 'README.md',
            'mode': '100644',
          },
        ]);
      }
      if (path.endsWith('/repository/files/README.md/raw')) {
        return ResponseBody.fromString(
          '# Welcome to Project\n\nThis is native README preview in GitLab Mobile.\n',
          200,
        );
      }
      if (path.endsWith('/repository/files/README.md') && request.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['80']});
      }
      return jsonResponse([]);
    });

    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepositoryTab(
            account: account,
            api: api,
            project: project,
          ),
        ),
      ),
    );

    await settleNetworkWidgets(tester);

    // Verify tree items are visible
    expect(find.text('src'), findsOneWidget);
    expect(find.text('README.md'), findsAtLeastNWidgets(1));

    // Verify collapsible toggle starts collapsed
    expect(find.byTooltip('展開 README'), findsOneWidget);
    expect(find.text('Welcome to Project'), findsNothing);

    // Expand README
    await tester.tap(find.byTooltip('展開 README'));
    await settleNetworkWidgets(tester);

    // After expanding, content is visible
    expect(find.text('Welcome to Project'), findsOneWidget);
    expect(find.text('This is native README preview in GitLab Mobile.'), findsOneWidget);
    expect(find.byTooltip('收合 README'), findsOneWidget);

    // Collapse again
    await tester.tap(find.byTooltip('收合 README'));
    await tester.pumpAndSettle();

    // After collapsing, content is hidden
    expect(find.text('Welcome to Project'), findsNothing);
    expect(find.byTooltip('展開 README'), findsOneWidget);
  });

  testWidgets('README 404 shows failure in card without hiding or corrupting tree list', (tester) async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/branches/main')) {
        return jsonResponse({
          'name': 'main',
          'protected': false,
          'default': true,
          'commit': {'id': sha},
        });
      }
      if (path.endsWith('/repository/tree')) {
        return jsonResponse([
          {
            'id': 'blob-1',
            'name': 'README.md',
            'type': 'blob',
            'path': 'README.md',
            'mode': '100644',
          },
          {
            'id': 'blob-2',
            'name': 'file.txt',
            'type': 'blob',
            'path': 'file.txt',
            'mode': '100644',
          },
        ]);
      }
      if (path.endsWith('/repository/files/README.md/raw') ||
          (path.endsWith('/repository/files/README.md') && request.method == 'HEAD')) {
        return ResponseBody.fromString('{"message":"404 Not Found"}', 404);
      }
      return jsonResponse([]);
    });

    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepositoryTab(
            account: account,
            api: api,
            project: project,
          ),
        ),
      ),
    );

    await settleNetworkWidgets(tester);

    // Tree list is still fully functional and visible
    expect(find.text('file.txt'), findsOneWidget);

    // Expand README card to see failure notice
    expect(find.byTooltip('展開 README'), findsOneWidget);
    await tester.tap(find.byTooltip('展開 README'));
    await settleNetworkWidgets(tester);

    // README card shows failure notice with retry
    expect(find.byType(FailureNotice), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);
  });
}
