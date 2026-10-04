import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
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
    expect(find.descendant(of: find.byKey(const ValueKey('recent-project-102')), matching: find.text('Repo Two')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('recent-project-101')), matching: find.text('Repo One')), findsOneWidget);

    // Click on Repo Two chip
    await tester.tap(find.byKey(const ValueKey('recent-project-102')));
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
    expect(find.byKey(const ValueKey('recent-project-101')), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-project-202')), findsNothing);

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
    expect(find.byKey(const ValueKey('recent-project-202')), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-project-101')), findsNothing);
  });

  testWidgets(
    'opening a project writes one full recent record and updates chips and launcher',
    (tester) async {
      final accountStore = MemoryAccountStore();
      final session = SessionController(accountStore)..active = account;
      final store = _CountingRecentProjectStore();
      final host = FakeAppShortcutHost();
      final shortcuts = LauncherShortcuts(host, store)..bind(account.key);
      addTearDown(shortcuts.dispose);
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          return jsonResponse([_project(303, 'Performance', 'team/performance')]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      session.api = api;
      addTearDown(api.close);
      addTearDown(session.dispose);

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(840, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        workspaceHost(ProjectsPage(session: session, shortcuts: shortcuts)),
      );
      await settleWorkspace(tester);
      await tester.tap(find.text('Performance').first);
      await settleWorkspace(tester);

      expect(store.mutations, 1);
      expect(
        await store.read(account.key),
        const RecentProject(
          id: 303,
          name: 'Performance',
          path: 'team/performance',
        ),
      );
      expect(
        find.byKey(const ValueKey('recent-project-303'), skipOffstage: false),
        findsOneWidget,
      );
      expect(host.published, isNotEmpty);
      expect(host.published.last.last.subtitle, 'Performance');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'distinct injected recent stores keep their roles without duplicate writes',
    (tester) async {
      final session = SessionController(MemoryAccountStore())..active = account;
      final chipStore = _CountingRecentProjectStore();
      final launcherStore = _CountingRecentProjectStore();
      final host = FakeAppShortcutHost();
      final shortcuts = LauncherShortcuts(host, launcherStore)
        ..bind(account.key);
      addTearDown(shortcuts.dispose);
      final adapter = FakeAdapter((request) => request.uri.path.endsWith('/projects')
          ? jsonResponse([_project(404, 'Injected', 'team/injected')])
          : jsonResponse([]));
      final api = testApi(adapter);
      session.api = api;
      addTearDown(api.close);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        workspaceHost(
          ProjectsPage(
            session: session,
            shortcuts: shortcuts,
            recentStore: chipStore,
          ),
        ),
      );
      await settleWorkspace(tester);
      await tester.tap(find.text('Injected'));
      await settleWorkspace(tester);

      expect(chipStore.mutations, 1);
      expect(launcherStore.mutations, 1);
      expect((await chipStore.read(account.key))?.path, 'team/injected');
      expect((await launcherStore.read(account.key))?.path, 'team/injected');
      expect(host.published.last.last.subtitle, 'Injected');
    },
  );

  testWidgets(
    'delayed recent write cannot publish or paint into a replacement owner',
    (tester) async {
      final session = SessionController(MemoryAccountStore())..active = account;
      final oldStore = _CountingRecentProjectStore();
      final oldHost = FakeAppShortcutHost();
      final oldShortcuts = LauncherShortcuts(oldHost, oldStore)
        ..bind(account.key);
      final gate = Completer<void>();
      oldStore.writeDelay = gate.future;
      addTearDown(oldShortcuts.dispose);
      final adapter = FakeAdapter((request) => request.uri.path.endsWith('/projects')
          ? jsonResponse([_project(505, 'Delayed', 'team/delayed')])
          : jsonResponse([]));
      final api = testApi(adapter);
      session.api = api;
      addTearDown(api.close);
      addTearDown(session.dispose);

      await tester.pumpWidget(
        workspaceHost(
          ProjectsPage(session: session, shortcuts: oldShortcuts),
        ),
      );
      await settleWorkspace(tester);
      await tester.tap(find.text('Delayed'));
      await tester.pump();

      final newStore = _CountingRecentProjectStore();
      final newHost = FakeAppShortcutHost();
      final newShortcuts = LauncherShortcuts(newHost, newStore)
        ..bind(account.key);
      addTearDown(newShortcuts.dispose);
      session.generation++;
      await tester.pumpWidget(
        workspaceHost(
          ProjectsPage(session: session, shortcuts: newShortcuts),
        ),
      );
      await tester.pump();

      gate.complete();
      oldStore.writeDelay = null;
      await settleWorkspace(tester);

      expect(oldHost.published, isEmpty);
      expect(newHost.published, isEmpty);
      expect(await newStore.read(account.key), isNull);
      expect(
        find.byKey(const ValueKey('recent-project-505'), skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Json _project(int id, String name, String path) => {
  'id': id,
  'name': name,
  'path': path.split('/').last,
  'path_with_namespace': path,
  'description': '',
  'visibility': 'private',
  'default_branch': 'main',
  'archived': false,
  'last_activity_at': '2026-10-04T00:00:00Z',
};

final class _CountingRecentProjectStore extends MemoryRecentProjectStore {
  int mutations = 0;

  @override
  Future<void> touch(String accountKey, RecentProject project) {
    mutations++;
    return super.touch(accountKey, project);
  }
}
