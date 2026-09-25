import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/repository_ref.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final instance = GitLabInstance.parse('https://gitlab.example.com/subpath');
  final account = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'coder', name: 'Coder'),
    token: 'synthetic-token',
  );
  final project = Project.fromJson({
    'id': 42,
    'name': 'Project',
    'path': 'group/project',
    'path_with_namespace': 'group/project',
    'description': '',
    'visibility': 'private',
    'default_branch': 'main',
    'archived': false,
    'last_activity_at': '2026-09-20T10:00:00Z',
  });

  const sha = '11223344556677889900aabbccddeeff00112233';

  const sampleCode = '''line 1: import flutter
line 2: void main() {
line 3:   runApp(MyApp());
line 4: }
line 5: class MyApp extends StatelessWidget {}
''';

  testWidgets('line numbers have >=48dp hit target, copy permalink to clipboard, and show SnackBar', (tester) async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/files/lib%2Fmain.dart') && request.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['120'], 'x-gitlab-last-commit-id': [sha]});
      }
      if (path.endsWith('/repository/files/lib%2Fmain.dart/raw')) {
        return ResponseBody.fromString(sampleCode, 200);
      }
      return jsonResponse([]);
    });

    final api = testApi(adapter);
    addTearDown(api.close);

    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (methodCall) async {
        if (methodCall.method == 'Clipboard.setData') {
          clipboardText = (methodCall.arguments as Map)['text'] as String?;
          return null;
        }
        return null;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryFilePage(
          account: account,
          api: api,
          project: project,
          ref: const RepositoryRef(
            kind: RepositoryRefKind.branch,
            name: 'main',
            sha: sha,
            protected: true,
          ),
          filePath: 'lib/main.dart',
        ),
      ),
    );

    await settleNetworkWidgets(tester);

    // Verify line numbers exist
    expect(find.text('3'), findsOneWidget);

    // Verify touch target size of the line number container is at least 48x48
    final line3Finder = find.ancestor(
      of: find.text('3'),
      matching: find.byType(ConstrainedBox),
    );
    expect(line3Finder, findsWidgets);
    final size = tester.getSize(line3Finder.first);
    expect(size.width, greaterThanOrEqualTo(48.0));
    expect(size.height, greaterThanOrEqualTo(48.0));

    // Tap line 3
    await tester.tap(find.text('3'));
    await tester.pump();

    // Verify SnackBar was shown
    expect(find.text('已複製第 3 行永久連結'), findsOneWidget);

    // Verify clipboard content
    expect(clipboardText, 'https://gitlab.example.com/subpath/group/project/-/blob/$sha/lib/main.dart#L3');
  });

  testWidgets('targetLine scrolls to target and highlights the line', (tester) async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/files/lib%2Fmain.dart') && request.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['120'], 'x-gitlab-last-commit-id': [sha]});
      }
      if (path.endsWith('/repository/files/lib%2Fmain.dart/raw')) {
        return ResponseBody.fromString(sampleCode, 200);
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
          ref: const RepositoryRef(
            kind: RepositoryRefKind.branch,
            name: 'main',
            sha: sha,
            protected: true,
          ),
          filePath: 'lib/main.dart',
          targetLine: 4,
        ),
      ),
    );

    await settleNetworkWidgets(tester);

    // Check that line 4 is present
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('tag ref hides Edit and Delete actions (read-only)', (tester) async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/files/lib%2Fmain.dart/raw')) {
        return ResponseBody.fromString(sampleCode, 200);
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
          ref: const RepositoryRef(
            kind: RepositoryRefKind.tag,
            name: 'v1.0.0',
            sha: sha,
            protected: true,
          ),
          filePath: 'lib/main.dart',
        ),
      ),
    );

    await settleNetworkWidgets(tester);

    // Open popup menu
    await tester.tap(find.byTooltip('檔案操作'));
    await tester.pumpAndSettle();

    // Edit and Delete must not be present in tag mode
    expect(find.text('編輯檔案'), findsNothing);
    expect(find.text('刪除檔案'), findsNothing);
    expect(find.text('關閉自動換行'), findsOneWidget);
  });

  testWidgets('markdown file with targetLine starts in code view and highlights the line', (tester) async {
    const mdContent = '''# Title
Line 2
Line 3
Line 4 with content
Line 5
''';
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/files/README.md') && request.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['100'], 'x-gitlab-last-commit-id': [sha]});
      }
      if (path.endsWith('/repository/files/README.md/raw')) {
        return ResponseBody.fromString(mdContent, 200);
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
          ref: const RepositoryRef(
            kind: RepositoryRefKind.branch,
            name: 'main',
            sha: sha,
            protected: true,
          ),
          filePath: 'README.md',
          targetLine: 4,
        ),
      ),
    );

    await settleNetworkWidgets(tester);

    // Because targetLine was provided, it must NOT start in Markdown preview mode.
    // Line numbers must be visible.
    expect(find.text('4'), findsOneWidget);
    expect(find.text('Line 4 with content'), findsOneWidget);

    // Semantics button for line 4 should be marked selected
    final semanticsWidget = tester.widget<Semantics>(find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == '第 4 行',
    ));
    expect(semanticsWidget.properties.selected, isTrue);
  });

  testWidgets('long file with targetLine: 50 auto-scrolls to the target line', (tester) async {
    final longCode = List.generate(80, (i) => 'line ${i + 1}: println($i);').join('\n');
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/files/lib%2Fbig.dart') && request.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['2000'], 'x-gitlab-last-commit-id': [sha]});
      }
      if (path.endsWith('/repository/files/lib%2Fbig.dart/raw')) {
        return ResponseBody.fromString(longCode, 200);
      }
      return jsonResponse([]);
    });

    final api = testApi(adapter);
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryFilePage(
          account: account,
          api: api,
          project: project,
          ref: const RepositoryRef(
            kind: RepositoryRefKind.branch,
            name: 'main',
            sha: sha,
            protected: true,
          ),
          filePath: 'lib/big.dart',
          targetLine: 50,
        ),
      ),
    );

    await settleNetworkWidgets(tester);
    await tester.pumpAndSettle();

    // Line 50 should be visible
    expect(find.text('50'), findsOneWidget);
    // Line 1 should be scrolled off
    expect(find.text('1'), findsNothing);
  });
}
