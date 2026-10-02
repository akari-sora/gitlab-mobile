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
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';

Future<BuildInfo> _shellBuildInfo() async => const BuildInfo(
  version: '0.4.0',
  buildNumber: '4',
  commit: 'adversarial',
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

Account _accountC() => Account(
  instance: GitLabInstance.parse('https://different-gitlab.org'),
  user: const GitLabUser(id: 3, username: 'user_c', name: 'User C'),
  token: 'token-c',
);

class _AdversarialTestApp extends StatelessWidget {
  const _AdversarialTestApp({
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
                          onPressed: () => unawaited(session.select(_accountA())),
                          child: const Text('登入 Account A'),
                        ),
                        ElevatedButton(
                          onPressed: () => unawaited(session.select(_accountB())),
                          child: const Text('登入 Account B'),
                        ),
                        ElevatedButton(
                          onPressed: () => unawaited(session.select(_accountC())),
                          child: const Text('登入 Account C'),
                        ),
                        ElevatedButton(
                          onPressed: () => unawaited(session.endSession(switching: false)),
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

  group('Adversarial Challenge: ResumeTarget Edge Cases', () {
    testWidgets('Empty projectPath and null projectId gracefully ignores resume without crashing', (tester) async {
      final accountA = _accountA();
      final accountB = _accountB();
      final store = MemoryAccountStore()..accounts = [accountA, accountB];

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/user')) {
          return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
        }
        if (path.endsWith('/projects')) {
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

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: _AdversarialTestApp(
            session: session,
            appearance: appearance,
            shortcuts: shortcuts,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // Target with empty projectPath and null projectId
      const invalidTarget = ResumeTarget(
        projectPath: '',
        resource: 'issues',
        iid: 1,
      );

      session.setPendingResumeTarget(invalidTarget);
      await tester.runAsync(() async {
        await session.endSession(switching: true);
      });
      await settleNetworkWidgets(tester);

      // Select Account B
      await tester.tap(find.text('登入 Account B'));
      await settleNetworkWidgets(tester);

      // Shell should mount normally, no crash, no FailureNotice
      expect(session.active?.key, accountB.key);
      expect(session.pendingResumeTarget, isNull);
      expect(find.byType(FailureNotice), findsNothing);
      expect(find.text('專案'), findsWidgets);
    });

    testWidgets('Unknown resource string falls back to ProjectPage safely', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);

      final accountA = _accountA();
      final accountB = _accountB();
      final store = MemoryAccountStore()..accounts = [accountA, accountB];

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/user')) {
          return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
        }
        if (path.contains('/projects/group%2Frepo')) {
          return jsonResponse({
            'id': 77,
            'name': 'Repo',
            'path': 'repo',
            'path_with_namespace': 'group/repo',
            'default_branch': 'main',
            'visibility': 'private',
          });
        }
        if (path.endsWith('/projects')) {
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

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: _AdversarialTestApp(
            session: session,
            appearance: appearance,
            shortcuts: shortcuts,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // ResumeTarget with totally unknown resource
      const unknownResourceTarget = ResumeTarget(
        projectPath: 'group/repo',
        resource: 'unexpected_alien_resource',
        iid: 999,
      );

      session.setPendingResumeTarget(unknownResourceTarget);
      await tester.runAsync(() async {
        await session.endSession(switching: true);
      });
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('登入 Account B'));
      await settleNetworkWidgets(tester);

      // Should safely navigate to ProjectPage fallback without unhandled exceptions
      expect(find.byType(ProjectPage), findsOneWidget);
      expect(find.text('group/repo'), findsWidgets);
    });

    testWidgets('Rapid consecutive account switching consumes target exactly once without cross-account pollution', (tester) async {
      final accountA = _accountA();
      final accountB = _accountB();
      final accountC = _accountC();
      final store = MemoryAccountStore()..accounts = [accountA, accountB, accountC];

      final adapter = FakeAdapter((request) {
        final token = request.headers['private-token'];
        final path = request.uri.path;

        if (path.endsWith('/user')) {
          if (token == 'token-a') return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
          if (token == 'token-b') return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
          if (token == 'token-c') return jsonResponse({'id': 3, 'username': 'user_c', 'name': 'User C'});
        }
        if (path.contains('/projects/group%2Ftarget-repo')) {
          if (token == 'token-b') {
            return jsonResponse({
              'id': 102,
              'name': 'Target Repo',
              'path': 'target-repo',
              'path_with_namespace': 'group/target-repo',
              'default_branch': 'main',
              'visibility': 'private',
            });
          }
          return jsonResponse({'message': '404 Not Found'}, status: 404);
        }
        if (path.endsWith('/projects/102/issues/5')) {
          return jsonResponse({
            'id': 888,
            'iid': 5,
            'project_id': 102,
            'title': 'Issue 5 Resumed',
            'state': 'opened',
            'author': {'id': 2, 'username': 'user_b', 'name': 'User B'},
          });
        }
        if (path.endsWith('/projects')) {
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

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: _AdversarialTestApp(
            session: session,
            appearance: appearance,
            shortcuts: shortcuts,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      const target = ResumeTarget(
        projectPath: 'group/target-repo',
        resource: 'issues',
        iid: 5,
      );

      // Start switch with target
      session.setPendingResumeTarget(target);
      await tester.runAsync(() async {
        await session.endSession(switching: true);
      });
      await settleNetworkWidgets(tester);

      expect(session.pendingResumeTarget, target);

      // Switch to B
      await tester.tap(find.text('登入 Account B'));
      await settleNetworkWidgets(tester);

      expect(session.active?.key, accountB.key);
      expect(session.pendingResumeTarget, isNull);
      expect(find.text('Issue 5 Resumed'), findsOneWidget);

      // Now switch from B to C without switching: true (normal sign-out)
      await tester.runAsync(() async {
        await session.endSession(switching: false);
      });
      await settleNetworkWidgets(tester);

      expect(session.pendingResumeTarget, isNull);

      // Log in Account C
      await tester.tap(find.text('登入 Account C'));
      await settleNetworkWidgets(tester);

      expect(session.active?.key, accountC.key);
      expect(session.pendingResumeTarget, isNull);
      // Account C must not attempt to resume Account B's issue
      expect(find.text('Issue 5 Resumed'), findsNothing);
      expect(find.byType(FailureNotice), findsNothing);
    });

    testWidgets('Cross-instance switch to Account C queries instance C and isolates failure notice', (tester) async {
      final accountA = _accountA();
      final accountC = _accountC(); // different instance: https://different-gitlab.org
      final store = MemoryAccountStore()..accounts = [accountA, accountC];

      final adapter = FakeAdapter((request) {
        final host = request.uri.host;
        final token = request.headers['private-token'];
        final path = request.uri.path;

        if (path.endsWith('/user')) {
          if (host == 'different-gitlab.org' && token == 'token-c') {
            return jsonResponse({'id': 3, 'username': 'user_c', 'name': 'User C'});
          }
          if (token == 'token-a') {
            return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
          }
        }
        if (path.contains('/projects/group%2Fprivate-project')) {
          // Both 404
          return jsonResponse({'message': '404 Not Found'}, status: 404);
        }
        if (path.endsWith('/projects')) return jsonResponse([]);
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
          child: _AdversarialTestApp(
            session: session,
            appearance: appearance,
            shortcuts: shortcuts,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      const target = ResumeTarget(
        projectPath: 'group/private-project',
        resource: 'merge_requests',
        iid: 12,
      );

      session.setPendingResumeTarget(target);
      await tester.runAsync(() async {
        await session.endSession(switching: true);
      });
      await settleNetworkWidgets(tester);

      // Switch to Account C on different instance
      await tester.tap(find.text('登入 Account C'));
      await settleNetworkWidgets(tester);

      // Should display FailureNotice bound to Account C
      expect(find.byType(FailureNotice), findsOneWidget);
      expect(find.text('App 帳號：@user_c'), findsOneWidget);
      expect(find.text('目標：group/private-project'), findsOneWidget);
      expect(find.text('重新整理'), findsOneWidget);
      expect(find.text('切換帳號'), findsOneWidget);
    });

    testWidgets('Malformed target path handled safely by FailureNotice without crashing', (tester) async {
      final accountA = _accountA();
      final accountB = _accountB();
      final store = MemoryAccountStore()..accounts = [accountA, accountB];

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/user')) {
          return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
        }
        if (path.endsWith('/projects')) {
          return jsonResponse([]);
        }
        // GitLab API returns 404 for invalid/malformed path
        return jsonResponse({'message': '404 Project Not Found'}, status: 404);
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
          child: _AdversarialTestApp(
            session: session,
            appearance: appearance,
            shortcuts: shortcuts,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // Weird malformed path
      const malformedTarget = ResumeTarget(
        projectPath: 'group/../../etc/passwd%20#invalid',
        resource: 'issues',
        iid: 1,
      );

      session.setPendingResumeTarget(malformedTarget);
      await tester.runAsync(() async {
        await session.endSession(switching: true);
      });
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('登入 Account B'));
      await settleNetworkWidgets(tester);

      // FailureNotice safely catches and shows Account B identity and the target
      expect(find.byType(FailureNotice), findsOneWidget);
      expect(find.text('App 帳號：@user_b'), findsOneWidget);
      expect(find.text('目標：group/../../etc/passwd%20#invalid'), findsOneWidget);
    });

    test('SessionController unit stress: rapid set/take and disposal safety', () async {
      final adapter = FakeAdapter((_) => jsonResponse({'id': 9, 'username': 'tester'}));
      final store = MemoryAccountStore();
      final controller = controllerFor(store, adapter);

      const target1 = ResumeTarget(projectPath: 'p1', resource: 'issues', iid: 1);
      const target2 = ResumeTarget(projectPath: 'p2', resource: 'merge_requests', iid: 2);

      // Rapid overwrite
      controller.setPendingResumeTarget(target1);
      expect(controller.pendingResumeTarget, target1);
      controller.setPendingResumeTarget(target2);
      expect(controller.pendingResumeTarget, target2);

      // Take once
      final taken = controller.takeResumeTarget();
      expect(taken, target2);
      expect(controller.pendingResumeTarget, isNull);

      // Take second time returns null
      expect(controller.takeResumeTarget(), isNull);

      // Disposal cleans up
      controller.setPendingResumeTarget(target1);
      controller.dispose();
      expect(controller.pendingResumeTarget, isNull);
    });
  });
}
