import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';

Future<BuildInfo> _shellBuildInfo() async => const BuildInfo(
  version: '0.4.0',
  buildNumber: '4',
  commit: 'resume',
);

Account _accountA() => Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: const GitLabUser(id: 1, username: 'user_a', name: 'User A'),
  token: 'token-a',
);

Account _accountB() => Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: const GitLabUser(id: 2, username: 'user_b', name: 'User B'),
  token: 'token-b',
);

class _TestRootApp extends StatelessWidget {
  const _TestRootApp({
    required this.session,
    required this.appearance,
    required this.shortcuts,
  });

  final SessionController session;
  final AppearanceController appearance;
  final LauncherShortcuts shortcuts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final active = session.active;
        return MaterialApp(
          home: active != null
              ? AuthenticatedApp(
                  key: ValueKey(session.generation),
                  session: session,
                  appearance: appearance,
                  shortcuts: shortcuts,
                  buildInfoLoader: _shellBuildInfo,
                )
              : Scaffold(
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('帳號選擇'),
                        ElevatedButton(
                          onPressed: () => unawaited(session.select(_accountB())),
                          child: const Text('登入 Account B'),
                        ),
                        ElevatedButton(
                          onPressed: () => unawaited(session.endSession()),
                          child: const Text('確定登出'),
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

void main() {
  late MemoryAppearanceStore appearanceStore;
  late AppearanceController appearance;
  late LauncherShortcuts shortcuts;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    appearanceStore = MemoryAppearanceStore();
    appearance = AppearanceController(appearanceStore);
    shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
  });

  tearDown(() {
    appearance.dispose();
    shortcuts.dispose();
  });

  testWidgets('Scenario 1: 404 -> switch account -> success with path resolution', (tester) async {
    final accountA = _accountA();
    final accountB = _accountB();
    final store = MemoryAccountStore()..accounts = [accountA, accountB];

    final adapter = FakeAdapter((request) {
      final token = request.headers['private-token'];
      final path = request.uri.path;

      if (path.endsWith('/user')) {
        if (token == 'token-a') {
          return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
        } else if (token == 'token-b') {
          return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
        }
      }

      // Default projects list
      if (path.endsWith('/projects') && request.queryParameters['membership'] == 'true') {
        return jsonResponse([]);
      }

      // Project resolution by path: group%2Fprivate-repo
      if (path.contains('/projects/group%2Fprivate-repo')) {
        if (token == 'token-a') {
          return jsonResponse({'message': '404 Project Not Found'}, status: 404);
        } else if (token == 'token-b') {
          return jsonResponse({
            'id': 200,
            'name': 'Private Repo',
            'path': 'private-repo',
            'path_with_namespace': 'group/private-repo',
            'default_branch': 'main',
            'visibility': 'private',
          });
        }
      }

      // WorkItem issue details for project 200 issue 101
      if (path.endsWith('/projects/200/issues/101')) {
        return jsonResponse({
          'id': 501,
          'iid': 101,
          'project_id': 200,
          'title': 'Secret Resume Issue',
          'state': 'opened',
          'author': {'id': 2, 'username': 'user_b', 'name': 'User B'},
          'description': 'Resumed successfully after account switch',
        });
      }
      if (path.contains('/projects/200/issues/101/notes')) {
        return jsonResponse([]);
      }
      if (path.contains('/projects/200/issues/101/award_emoji')) {
        return jsonResponse([]);
      }

      return jsonResponse({'message': '404 Not Found'}, status: 404);
    });

    final session = controllerFor(store, adapter);
    addTearDown(session.dispose);

    await tester.runAsync(() async {
      await session.initialize();
      await session.select(accountA);
    });
    expect(session.active?.key, accountA.key);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _TestRootApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    // Simulate 404 on a private resource and tap switch account
    const target = ResumeTarget(
      projectId: 100,
      projectPath: 'group/private-repo',
      resource: 'issues',
      iid: 101,
    );

    // Trigger switch account with target
    session.setPendingResumeTarget(target);
    await tester.runAsync(() async {
      await session.endSession(switching: true);
    });
    await settleNetworkWidgets(tester);

    expect(session.active, isNull);
    expect(session.pendingResumeTarget, target);
    expect(find.text('帳號選擇'), findsOneWidget);

    // Switch to Account B
    await tester.tap(find.text('登入 Account B'));
    await settleNetworkWidgets(tester);

    expect(session.active?.key, accountB.key);
    expect(session.pendingResumeTarget, isNull);

    // Verify issue was resumed and rendered on screen
    expect(find.text('Secret Resume Issue'), findsOneWidget);
    expect(find.text('group/private-repo'), findsOneWidget);
    await pumpUntilComplete(tester, session.readCache.quiesced);
  });

  testWidgets('Scenario 2: switch account still 404 shows Account B identity without crashing', (tester) async {
    final accountA = _accountA();
    final accountB = _accountB();
    final store = MemoryAccountStore()..accounts = [accountA, accountB];

    final adapter = FakeAdapter((request) {
      final token = request.headers['private-token'];
      final path = request.uri.path;

      if (path.endsWith('/user')) {
        if (token == 'token-a') {
          return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
        } else if (token == 'token-b') {
          return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
        }
      }

      if (path.endsWith('/projects') && (request.queryParameters['membership'] == 'true' || request.uri.queryParameters['membership'] == 'true')) {
        return jsonResponse([]);
      }

      // Both Account A and Account B get 404 for this private repo
      if (path.contains('/projects/group%2Fprivate-repo')) {
        return jsonResponse({'message': '404 Not Found'}, status: 404);
      }

      return jsonResponse({'message': '404 Not Found'}, status: 404);
    });

    final session = controllerFor(store, adapter);
    addTearDown(session.dispose);

    await tester.runAsync(() async {
      await session.initialize();
      await session.select(accountA);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _TestRootApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    const target = ResumeTarget(
      projectPath: 'group/private-repo',
      resource: 'issues',
      iid: 99,
    );

    session.setPendingResumeTarget(target);
    await tester.runAsync(() async {
      await session.endSession(switching: true);
    });
    await settleNetworkWidgets(tester);

    expect(find.text('帳號選擇'), findsOneWidget);

    // Switch to Account B, which still has 404
    await tester.tap(find.text('登入 Account B'));
    await settleNetworkWidgets(tester);

    // Verify FailureNotice is displayed for Account B
    expect(find.byType(FailureNotice), findsOneWidget);
    expect(find.text('App 帳號：@user_b'), findsOneWidget);
    expect(find.text('目標：group/private-repo'), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);

    // Tapping switch account again retains target and returns to account picker
    await tester.tap(find.text('切換帳號'));
    await settleNetworkWidgets(tester);

    expect(session.active, isNull);
    expect(session.pendingResumeTarget, target);
    expect(find.text('帳號選擇'), findsOneWidget);
    await pumpUntilComplete(tester, session.readCache.quiesced);
  });

  testWidgets('Scenario 3: switch account logout midway clears pending target', (tester) async {
    final accountA = _accountA();
    final accountB = _accountB();
    final store = MemoryAccountStore()..accounts = [accountA, accountB];

    final adapter = FakeAdapter((request) {
      final token = request.headers['private-token'];
      final path = request.uri.path;

      if (path.endsWith('/user')) {
        if (token == 'token-a') {
          return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
        } else if (token == 'token-b') {
          return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
        }
      }

      if (path.contains('/projects')) {
        return jsonResponse(<Map<String, dynamic>>[]);
      }

      return jsonResponse({'message': '404 Not Found'}, status: 404);
    });

    final session = controllerFor(store, adapter);
    addTearDown(session.dispose);

    await tester.runAsync(() async {
      await session.initialize();
      await session.select(accountA);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _TestRootApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    const target = ResumeTarget(
      projectPath: 'group/private-repo',
      resource: 'issues',
      iid: 88,
    );

    // 404 occurs -> start switching
    session.setPendingResumeTarget(target);
    await tester.runAsync(() async {
      await session.endSession(switching: true);
    });
    await settleNetworkWidgets(tester);

    expect(session.pendingResumeTarget, target);
    expect(find.text('帳號選擇'), findsOneWidget);

    // User opts to logout midway / cancel switch instead of selecting an account
    await tester.tap(find.text('確定登出'));
    await settleNetworkWidgets(tester);

    expect(session.pendingResumeTarget, isNull);

    // Now when Account B logs in subsequently, no resume target is pursued
    await tester.tap(find.text('登入 Account B'));
    await settleNetworkWidgets(tester);

    expect(session.active?.key, accountB.key);
    expect(session.pendingResumeTarget, isNull);
    // Stays on main shell without pushing any sub-page or showing failure notice
    expect(find.text('專案'), findsWidgets);
    expect(find.byType(FailureNotice), findsNothing);
    await pumpUntilComplete(tester, session.readCache.quiesced);
  });
}
