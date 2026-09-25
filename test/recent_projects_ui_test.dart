import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

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

  testWidgets('ProjectsPage renders recent projects chips when query is empty and opens on click', (tester) async {
    final accountStore = MemoryAccountStore();
    final session = SessionController(accountStore);
    session.active = account;

    // Seed recent projects
    final store = SecureRecentProjectStore();
    await store.touch(account.key, const RecentProject(id: 101, name: 'Repo One', path: 'group/repo-one'));
    await store.touch(account.key, const RecentProject(id: 102, name: 'Repo Two', path: 'group/repo-two'));

    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/projects') && !path.contains('/projects/')) {
        return jsonResponse([]);
      }
      if (path.endsWith('/projects/102')) {
        return jsonResponse({
          'id': 102,
          'name': 'Repo Two',
          'path': 'repo-two',
          'path_with_namespace': 'group/repo-two',
          'description': 'Second repo',
          'visibility': 'private',
          'default_branch': 'main',
          'last_activity_at': '2026-09-20T10:00:00Z',
        });
      }
      return jsonResponse([]);
    });

    final api = testApi(adapter);
    session.api = api;
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      workspaceHost(
        ProjectsPage(
          session: session,
        ),
      ),
    );

    await settleWorkspace(tester);

    // Verify recent projects section header and chips
    expect(find.text('最近開啟'), findsOneWidget);
    expect(find.text('最近：Repo Two'), findsOneWidget);
    expect(find.text('最近：Repo One'), findsOneWidget);

    // Click on Repo Two chip
    await tester.tap(find.text('最近：Repo Two'));
    await settleWorkspace(tester);

    // Repo Two project page should be open (showing project path and tabs)
    expect(find.text('group/repo-two'), findsOneWidget);
    expect(find.text('檔案'), findsOneWidget);
  });

  testWidgets('ProjectsPage clears recent projects and resets selection upon account switch', (tester) async {
    final accountStore = MemoryAccountStore();
    final session = SessionController(accountStore);
    session.active = account;

    final account2 = Account(
      instance: instance,
      user: const GitLabUser(id: 8, username: 'other', name: 'Other User'),
      token: 'synthetic-token-2',
    );

    final store = SecureRecentProjectStore();
    await store.touch(account.key, const RecentProject(id: 101, name: 'Repo One', path: 'group/repo-one'));
    await store.touch(account2.key, const RecentProject(id: 202, name: 'Other Repo', path: 'group/other-repo'));

    final adapter = FakeAdapter((request) => jsonResponse([]));
    final api = testApi(adapter);
    session.api = api;
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      workspaceHost(
        ProjectsPage(session: session),
      ),
    );
    await settleWorkspace(tester);

    // Initial account shows Repo One
    expect(find.text('最近：Repo One'), findsOneWidget);
    expect(find.text('最近：Other Repo'), findsNothing);

    // Switch account
    session.active = account2;
    session.generation = 2;
    await tester.pumpWidget(
      workspaceHost(
        ProjectsPage(session: session),
      ),
    );
    await settleWorkspace(tester);

    // Now shows Other Repo, Repo One is gone
    expect(find.text('最近：Other Repo'), findsOneWidget);
    expect(find.text('最近：Repo One'), findsNothing);
  });
}
