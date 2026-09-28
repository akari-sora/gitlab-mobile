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

    // Verify collapsible toggle starts expanded by default
    expect(find.byTooltip('收合 README'), findsOneWidget);
    expect(find.text('Welcome to Project'), findsOneWidget);
    expect(find.text('This is native README preview in GitLab Mobile.'), findsOneWidget);

    // Collapse README
    await tester.tap(find.byTooltip('收合 README'));
    await tester.pumpAndSettle();

    // After collapsing, content is hidden
    expect(find.text('Welcome to Project'), findsNothing);
    expect(find.byTooltip('展開 README'), findsOneWidget);

    // Expand again
    await tester.tap(find.byTooltip('展開 README'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Project'), findsOneWidget);
    expect(find.byTooltip('收合 README'), findsOneWidget);
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

    // README card is expanded by default, showing failure notice with retry
    expect(find.byTooltip('收合 README'), findsOneWidget);
    expect(find.byType(FailureNotice), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);

    // Collapse hides failure notice
    await tester.tap(find.byTooltip('收合 README'));
    await tester.pumpAndSettle();
    expect(find.byType(FailureNotice), findsNothing);
    expect(find.byTooltip('展開 README'), findsOneWidget);
  });

  testWidgets('Expanded README allows vertical scrolling by dragging inside markdown content without gesture conflict', (tester) async {
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
          for (int i = 0; i < 2; i++)
            {
              'id': 'blob-$i',
              'name': 'item_$i.txt',
              'type': 'blob',
              'path': 'item_$i.txt',
              'mode': '100644',
            },
          {
            'id': 'blob-readme',
            'name': 'README.md',
            'type': 'blob',
            'path': 'README.md',
            'mode': '100644',
          },
        ]);
      }
      if (path.endsWith('/repository/files/README.md/raw')) {
        return ResponseBody.fromString(
          '# Project Details\n\n'
          '```dart\nvoid main() => print("codeblock");\n```\n\n'
          '${List.generate(30, (i) => 'Paragraph $i: Multi-line description content for scrolling.\n\n').join()}',
          200,
        );
      }
      if (path.endsWith('/repository/files/README.md') && request.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['200']});
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

    // Initial state: tree items and expanded README are visible
    expect(find.text('item_0.txt'), findsOneWidget);
    expect(find.text('Project Details'), findsOneWidget);
    expect(find.byTooltip('收合 README'), findsOneWidget);
    // SelectionArea wraps MarkdownBody to enable text selection while delegating scroll gestures
    expect(find.byType(SelectionArea), findsOneWidget);

    final scrollableFinder = find.byType(Scrollable).first;
    final initialOffset = tester.state<ScrollableState>(scrollableFinder).position.pixels;

    // 1. Drag directly on the markdown heading
    await tester.drag(find.text('Project Details'), const Offset(0, -100));
    await tester.pumpAndSettle();

    final offsetAfterHeadingDrag = tester.state<ScrollableState>(scrollableFinder).position.pixels;
    expect(offsetAfterHeadingDrag, greaterThan(initialOffset));

    // 2. Drag directly on codeblock inside markdown content
    await tester.drag(find.textContaining('codeblock'), const Offset(0, -100));
    await tester.pumpAndSettle();
    final offsetAfterCodeDrag = tester.state<ScrollableState>(scrollableFinder).position.pixels;
    expect(offsetAfterCodeDrag, greaterThan(offsetAfterHeadingDrag));

    // 3. Drag directly on paragraph body text inside markdown content
    await tester.drag(find.textContaining('Paragraph 0:'), const Offset(0, -100));
    await tester.pumpAndSettle();
    final offsetAfterParagraphDrag = tester.state<ScrollableState>(scrollableFinder).position.pixels;
    expect(offsetAfterParagraphDrag, greaterThan(offsetAfterCodeDrag));

    // 4. Reverse drag upward within markdown content scrolls back up smoothly
    await tester.drag(find.textContaining('Paragraph 0:'), const Offset(0, 150));
    await tester.pumpAndSettle();
    final offsetAfterReverseDrag = tester.state<ScrollableState>(scrollableFinder).position.pixels;
    expect(offsetAfterReverseDrag, lessThan(offsetAfterParagraphDrag));
  });

  testWidgets('Switching branch re-defaults README to expanded even if collapsed on previous branch', (tester) async {
    const featSha = '2222222222222222222222222222222222222222';
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
      if (path.endsWith('/repository/branches/feature/new-branch')) {
        return jsonResponse({
          'name': 'feature/new-branch',
          'protected': false,
          'default': false,
          'commit': {'id': featSha},
        });
      }
      if (path.endsWith('/repository/branches')) {
        return jsonResponse([
          {
            'name': 'main',
            'protected': true,
            'default': true,
            'commit': {'id': sha},
          },
          {
            'name': 'feature/new-branch',
            'protected': false,
            'default': false,
            'commit': {'id': featSha},
          },
        ]);
      }
      if (path.endsWith('/repository/tags')) {
        return jsonResponse([]);
      }
      if (path.endsWith('/repository/tree')) {
        return jsonResponse([
          {
            'id': 'blob-readme',
            'name': 'README.md',
            'type': 'blob',
            'path': 'README.md',
            'mode': '100644',
          },
        ]);
      }
      if (path.endsWith('/repository/files/README.md/raw')) {
        final ref = request.uri.queryParameters['ref'];
        if (ref == featSha) {
          return ResponseBody.fromString('# Feature Branch README\nContent on new branch.', 200);
        }
        return ResponseBody.fromString('# Main Branch README\nContent on main.', 200);
      }
      if (path.endsWith('/repository/files/README.md') && request.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['50']});
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

    // Initial state: main branch README is expanded
    expect(find.text('Main Branch README'), findsOneWidget);
    expect(find.byTooltip('收合 README'), findsOneWidget);

    // User collapses the README on main
    await tester.tap(find.byTooltip('收合 README'));
    await tester.pumpAndSettle();
    expect(find.text('Main Branch README'), findsNothing);
    expect(find.byTooltip('展開 README'), findsOneWidget);

    // Tap branch selector button to pick feature/new-branch
    await tester.tap(find.text('main'));
    await settleNetworkWidgets(tester);

    expect(find.text('feature/new-branch'), findsOneWidget);
    await tester.tap(find.text('feature/new-branch'));
    await settleNetworkWidgets(tester);

    // After switching branches, README is re-expanded by default
    expect(find.text('Feature Branch README'), findsOneWidget);
    expect(find.byTooltip('收合 README'), findsOneWidget);
  });
}
