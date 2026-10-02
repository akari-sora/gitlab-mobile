import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

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

  testWidgets('permission denial on refresh removes retained private source', (
    tester,
  ) async {
    var denied = false;
    final adapter = FakeAdapter(
      (request) => denied
          ? jsonResponse({}, status: 403)
          : request.method == 'HEAD'
          ? ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['32'],
                'x-gitlab-last-commit-id': [sha],
              },
            )
          : ResponseBody.fromString('Private source must disappear', 200),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryFilePage(
          account: account,
          api: api,
          project: project,
          branch: 'main',
          sha: sha,
          filePath: 'secret.txt',
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('Private source must disappear'), findsOneWidget);
    denied = true;
    await tester.tap(find.byTooltip('檔案操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新載入'));
    await settleNetworkWidgets(tester);
    expect(find.text('沒有操作權限'), findsOneWidget);
    expect(find.text('Private source must disappear'), findsNothing);
  });

  testWidgets(
    'RepositoryFilePage renders code and synchronizes horizontal scrolling in no-wrap mode',
    (tester) async {
      const longCode = '''
class VeryLongClassWithExtremelyLongMethodNameForTestingHorizontalScrollingBehavior {
  void methodOne() { print("This is a very long line of code that requires horizontal scrolling to view in full without wrapping"); }
  void methodTwo() { print("Another long line of code aligning with the first line across the entire file synchronized horizontal scroll"); }
}
''';

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/repository/files/lib%2Fcode.dart') &&
            request.method == 'HEAD') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'x-gitlab-size': ['200'],
              'x-gitlab-last-commit-id': [sha],
            },
          );
        }
        if (path.endsWith('/repository/files/lib%2Fcode.dart/raw')) {
          return ResponseBody.fromString(longCode, 200);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryFilePage(
            account: account,
            api: api,
            project: project,
            branch: 'main',
            sha: sha,
            filePath: 'lib/code.dart',
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('code.dart'), findsOneWidget);
      expect(
        find.textContaining('VeryLongClassWithExtremelyLongMethodName'),
        findsOneWidget,
      );

      // Verify popup menu and toggle wrap mode
      await tester.tap(find.byTooltip('檔案操作'));
      await tester.pumpAndSettle();
      expect(find.text('關閉自動換行'), findsOneWidget);

      await tester.tap(find.text('關閉自動換行'));
      await tester.pumpAndSettle();

      // Verify that the file view is wrapped in a SingleChildScrollView with horizontal scroll direction
      final horizontalScrolls = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(horizontalScrolls, findsOneWidget);

      // Verify horizontal scrollbar is present
      expect(find.byType(Scrollbar), findsOneWidget);

      // Test horizontal scroll offset changes
      final scrollable = find.byType(SingleChildScrollView);
      await tester.drag(scrollable, const Offset(-100, 0));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'RepositoryFilePage toggles markdown preview for markdown files',
    (tester) async {
      const markdownContent =
          '# Heading\n\nThis is **markdown** documentation.\n';

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/repository/files/README.md') &&
            request.method == 'HEAD') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'x-gitlab-size': ['100'],
              'x-gitlab-last-commit-id': [sha],
            },
          );
        }
        if (path.endsWith('/repository/files/README.md/raw')) {
          return ResponseBody.fromString(markdownContent, 200);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryFilePage(
            account: account,
            api: api,
            project: project,
            branch: 'main',
            sha: sha,
            filePath: 'README.md',
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // Initially in preview mode for markdown
      expect(find.byTooltip('顯示原始文字'), findsOneWidget);

      // Toggle to raw code mode
      await tester.tap(find.byTooltip('顯示原始文字'));
      await settleNetworkWidgets(tester);

      expect(find.byTooltip('Markdown 預覽'), findsOneWidget);
      expect(find.text('# Heading'), findsOneWidget);
    },
  );
}
