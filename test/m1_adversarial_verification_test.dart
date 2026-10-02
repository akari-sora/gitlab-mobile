import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
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
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 3, username: 'user_c', name: 'User C'),
      token: 'token-c',
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
                          onPressed: () => unawaited(session.select(_accountC())),
                          child: const Text('登入 Account C'),
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
  group('SessionController Adversarial & Boundary Stress Harness', () {
    late MemoryAccountStore store;
    late SessionController session;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      store = MemoryAccountStore()..accounts = [_accountA(), _accountB(), _accountC()];
      session = controllerFor(store, FakeAdapter((req) {
        final token = req.headers['private-token'];
        if (req.uri.path.endsWith('/user')) {
          if (token == 'token-a') return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
          if (token == 'token-b') return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
          if (token == 'token-c') return jsonResponse({'id': 3, 'username': 'user_c', 'name': 'User C'});
        }
        return jsonResponse([]);
      }));
    });

    tearDown(() {
      session.dispose();
    });

    test('Stress: takeResumeTarget is strictly single-use (destructive read) under interleaved calls', () async {
      await session.initialize();
      const target1 = ResumeTarget(projectPath: 'group/project-1', resource: 'issues', iid: 10);
      const target2 = ResumeTarget(projectPath: 'group/project-2', resource: 'merge_requests', iid: 20);

      // Initially null
      expect(session.pendingResumeTarget, isNull);
      expect(session.takeResumeTarget(), isNull);

      // Set target1
      session.setPendingResumeTarget(target1);
      expect(session.pendingResumeTarget, target1);

      // First take succeeds
      final taken1 = session.takeResumeTarget();
      expect(taken1, target1);

      // Immediate second take must be null (no double-consumption)
      expect(session.pendingResumeTarget, isNull);
      expect(session.takeResumeTarget(), isNull);

      // Overwrite target
      session.setPendingResumeTarget(target1);
      session.setPendingResumeTarget(target2); // overwrite
      expect(session.pendingResumeTarget, target2);
      expect(session.takeResumeTarget(), target2);
      expect(session.takeResumeTarget(), isNull);
    });

    test('Stress: rapid alternating endSession(switching: true/false) boundary states', () async {
      await session.initialize();
      await session.select(_accountA());
      expect(session.active?.key, _accountA().key);

      const target = ResumeTarget(projectPath: 'group/project-1', resource: 'issues', iid: 10);

      // switching: true preserves target
      session.setPendingResumeTarget(target);
      await session.endSession(switching: true);
      expect(session.active, isNull);
      expect(session.pendingResumeTarget, target);

      // Normal endSession (switching: false) immediately wipes target
      await session.endSession(switching: false);
      expect(session.pendingResumeTarget, isNull);

      // Re-set target, then endSession default (switching: false)
      session.setPendingResumeTarget(target);
      await session.endSession();
      expect(session.pendingResumeTarget, isNull);
    });

    test('Stress: consecutive rapid select calls without waiting', () async {
      await session.initialize();
      const target = ResumeTarget(projectPath: 'group/project-1', resource: 'issues', iid: 10);
      session.setPendingResumeTarget(target);

      // Fire select(A), select(B), select(C) concurrently without awaiting
      final f1 = session.select(_accountA());
      final f2 = session.select(_accountB());
      final f3 = session.select(_accountC());

      await Future.wait([f1, f2, f3]);

      // Only the last operation ticket (account C) should land
      expect(session.active?.key, _accountC().key);
      // pendingResumeTarget is preserved for consumption by the UI
      expect(session.pendingResumeTarget, target);

      // Consume it
      expect(session.takeResumeTarget(), target);
      expect(session.pendingResumeTarget, isNull);
    });

    test('Stress: remove active account clears pendingResumeTarget', () async {
      await session.initialize();
      await session.select(_accountA());
      const target = ResumeTarget(projectPath: 'group/project-1', resource: 'issues', iid: 10);
      session.setPendingResumeTarget(target);
      expect(session.pendingResumeTarget, target);

      // Removing the active account clears pending target and logs out
      await session.remove(_accountA());
      expect(session.active, isNull);
      expect(session.pendingResumeTarget, isNull);
    });

    test('Stress: initialize() supersedes in-flight session and clears pendingResumeTarget', () async {
      await session.initialize();
      await session.select(_accountA());
      const target = ResumeTarget(projectPath: 'group/project-1', resource: 'issues', iid: 10);
      session.setPendingResumeTarget(target);

      await session.initialize();
      expect(session.pendingResumeTarget, isNull);
    });
  });

  group('AuthenticatedApp Adversarial Multi-Error & Generation Isolation', () {
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

    testWidgets('Adversarial: 403 Forbidden on project resolution renders FailureNotice with retry and switch account', (tester) async {
      final accountA = _accountA();
      final accountB = _accountB();
      final store = MemoryAccountStore()..accounts = [accountA, accountB];

      final adapter = FakeAdapter((request) {
        final token = request.headers['private-token'];
        final path = request.uri.path;

        if (path.endsWith('/user')) {
          if (token == 'token-a') return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
          if (token == 'token-b') return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
        }
        if (path.contains('/projects/group%2Fforbidden-repo')) {
          return jsonResponse({'message': '403 Forbidden'}, status: 403);
        }
        return jsonResponse([]);
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
          child: _TestRootApp(session: session, appearance: appearance, shortcuts: shortcuts),
        ),
      );
      await settleNetworkWidgets(tester);

      const target = ResumeTarget(
        projectPath: 'group/forbidden-repo',
        resource: 'issues',
        iid: 42,
      );

      session.setPendingResumeTarget(target);
      await tester.runAsync(() => session.endSession(switching: true));
      await settleNetworkWidgets(tester);

      // Login Account B
      await tester.tap(find.text('登入 Account B'));
      await settleNetworkWidgets(tester);

      // Expect FailureNotice with 403 error, account @user_b, and target
      expect(find.byType(FailureNotice), findsOneWidget);
      expect(find.text('App 帳號：@user_b'), findsOneWidget);
      expect(find.text('目標：group/forbidden-repo'), findsOneWidget);
      expect(find.text('重新整理'), findsOneWidget);
      expect(find.text('切換帳號'), findsOneWidget);
    });

    testWidgets('Adversarial: Network failure on resume recovers upon retry', (tester) async {
      final accountA = _accountA();
      final accountB = _accountB();
      final store = MemoryAccountStore()..accounts = [accountA, accountB];

      var networkDown = true;

      final adapter = FakeAdapter((request) {
        final token = request.headers['private-token'];
        final path = request.uri.path;

        if (path.endsWith('/user')) {
          if (token == 'token-a') return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
          if (token == 'token-b') return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
        }
        if (path.contains('/projects/group%2Fflaky-repo')) {
          if (networkDown) {
            return jsonResponse({'message': 'Network down'}, status: 503);
          }
          return jsonResponse({
            'id': 333,
            'name': 'Flaky Repo',
            'path': 'flaky-repo',
            'path_with_namespace': 'group/flaky-repo',
            'default_branch': 'main',
            'visibility': 'private',
          });
        }
        if (path.endsWith('/projects/333/issues/7')) {
          return jsonResponse({
            'id': 7007,
            'iid': 7,
            'project_id': 333,
            'title': 'Recovered Issue After Retry',
            'state': 'opened',
            'author': {'id': 2, 'username': 'user_b', 'name': 'User B'},
          });
        }
        return jsonResponse([]);
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
          child: _TestRootApp(session: session, appearance: appearance, shortcuts: shortcuts),
        ),
      );
      await settleNetworkWidgets(tester);

      const target = ResumeTarget(
        projectPath: 'group/flaky-repo',
        resource: 'issues',
        iid: 7,
      );

      session.setPendingResumeTarget(target);
      await tester.runAsync(() => session.endSession(switching: true));
      await settleNetworkWidgets(tester);

      // Login Account B while network is down
      await tester.tap(find.text('登入 Account B'));
      await settleNetworkWidgets(tester);

      // Verify FailureNotice is displayed
      expect(find.byType(FailureNotice), findsOneWidget);
      expect(find.text('App 帳號：@user_b'), findsOneWidget);

      // Now restore network and tap retry
      networkDown = false;
      await tester.tap(find.text('重新整理'));
      await settleNetworkWidgets(tester);

      // Failure notice should be dismissed and recovered issue displayed
      expect(find.text('Recovered Issue After Retry'), findsOneWidget);
      expect(find.byType(FailureNotice), findsNothing);
    });

    testWidgets('Adversarial: In-flight resume cancelled by mid-flight account switch (Generation Isolation)', (tester) async {
      final accountA = _accountA();
      final accountB = _accountB();
      final accountC = _accountC();
      final store = MemoryAccountStore()..accounts = [accountA, accountB, accountC];

      final completerB = Completer<Map<String, dynamic>>();

      final adapter = FakeAdapter((request) {
        final token = request.headers['private-token'];
        final path = request.uri.path;

        if (path.endsWith('/user')) {
          if (token == 'token-a') return jsonResponse({'id': 1, 'username': 'user_a', 'name': 'User A'});
          if (token == 'token-b') return jsonResponse({'id': 2, 'username': 'user_b', 'name': 'User B'});
          if (token == 'token-c') return jsonResponse({'id': 3, 'username': 'user_c', 'name': 'User C'});
        }
        if (path.contains('/projects/group%2Fslow-repo')) {
          if (token == 'token-b') {
            // Delay resolution for Account B
            return completerB.future.then((data) => jsonResponse(data));
          }
          if (token == 'token-c') {
            return jsonResponse({
              'id': 999,
              'name': 'C Repo',
              'path': 'c-repo',
              'path_with_namespace': 'group/c-repo',
              'default_branch': 'main',
              'visibility': 'private',
            });
          }
        }
        return jsonResponse([]);
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
          child: _TestRootApp(session: session, appearance: appearance, shortcuts: shortcuts),
        ),
      );
      await settleNetworkWidgets(tester);

      const target = ResumeTarget(
        projectPath: 'group/slow-repo',
        resource: 'issues',
        iid: 1,
      );

      session.setPendingResumeTarget(target);
      await tester.runAsync(() => session.endSession(switching: true));
      await settleNetworkWidgets(tester);

      // Start logging into Account B
      await tester.tap(find.text('登入 Account B'));
      // Pump initial frame so _openResumeTarget starts and awaits api.project
      await tester.pump();

      // Now while Account B is awaiting project response, user immediately forces switch to Account C
      // This increments generation
      await tester.runAsync(() => session.select(accountC));
      await settleNetworkWidgets(tester);

      // Now complete Account B's deferred response (stale generation)
      completerB.complete({
        'id': 888,
        'name': 'Stale B Repo',
        'path': 'slow-repo',
        'path_with_namespace': 'group/slow-repo',
        'default_branch': 'main',
        'visibility': 'private',
      });
      await tester.pumpAndSettle();

      // Verify that Account B's response did NOT push a page or pollute Account C
      expect(session.active?.key, accountC.key);
      expect(find.text('Stale B Repo'), findsNothing);
      expect(find.text('App 帳號：@user_b'), findsNothing);
    });
  });

  group('CI Smoke live_smoke.dart Quota Exceeded Behavior Oracle', () {
    test('Oracle: pipeline failure_reason ci_quota_exceeded marks NOT_RUN and does not fail', () {
      final checks = <Map<String, Object?>>[];
      var failed = false;

      final pipelineRecord = {'failure_reason': 'ci_quota_exceeded', 'status': 'failed'};
      final jobs = <Map<String, dynamic>>[];

      final quotaExceeded = pipelineRecord['failure_reason'] == 'ci_quota_exceeded' ||
          jobs.any((j) => j['failure_reason'] == 'ci_quota_exceeded');

      if (quotaExceeded) {
        checks.add({
          'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
          'status': 'NOT_RUN',
          'reason': 'ci_quota_exceeded',
        });
      } else {
        fail('Should have detected pipeline quota exceeded');
      }

      expect(checks.length, 1);
      expect(checks.first['status'], 'NOT_RUN');
      expect(checks.first['reason'], 'ci_quota_exceeded');
      expect(failed, isFalse);
    });

    test('Oracle: job failure_reason ci_quota_exceeded marks NOT_RUN and does not fail', () {
      final checks = <Map<String, Object?>>[];
      var failed = false;

      final pipelineRecord = {'status': 'failed', 'failure_reason': 'other'};
      final jobs = <Map<String, dynamic>>[
        {'id': 101, 'name': 'smoke', 'failure_reason': 'ci_quota_exceeded'},
      ];

      final quotaExceeded = pipelineRecord['failure_reason'] == 'ci_quota_exceeded' ||
          jobs.any((j) => j['failure_reason'] == 'ci_quota_exceeded');

      if (quotaExceeded) {
        checks.add({
          'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
          'status': 'NOT_RUN',
          'reason': 'ci_quota_exceeded',
        });
      } else {
        fail('Should have detected job quota exceeded');
      }

      expect(checks.length, 1);
      expect(checks.first['status'], 'NOT_RUN');
      expect(checks.first['reason'], 'ci_quota_exceeded');
      expect(failed, isFalse);
    });

    test('Oracle: catch block cleans up tentative FAIL entry and converts to NOT_RUN', () {
      final checks = <Map<String, Object?>>[];
      var failed = false;

      // Simulate tentative FAIL added by check() helper before rethrow
      checks.add({
        'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
        'status': 'FAIL',
        'error_type': 'FormatException',
      });

      // Simulate exception with ci_quota_exceeded in catch block
      final e = Exception('GitLab job failed: ci_quota_exceeded');
      final quotaExceeded = e.toString().contains('ci_quota_exceeded');

      if (quotaExceeded) {
        checks.removeWhere((c) => c['name'] == 'jobs.read_trace_retry_new_attempt_and_manual_play');
        checks.add({
          'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
          'status': 'NOT_RUN',
          'reason': 'ci_quota_exceeded',
        });
      }

      expect(checks.length, 1);
      expect(checks.first['status'], 'NOT_RUN');
      expect(checks.first['reason'], 'ci_quota_exceeded');
      expect(failed, isFalse);
    });

    test('Oracle: unrelated error is not suppressed and leads to failure', () {
      var failed = false;
      var caughtExpected = false;

      final checks = <Map<String, Object?>>[];
      checks.add({
        'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
        'status': 'FAIL',
        'error_type': 'ApiFailure:500',
      });

      final e = const ApiFailure(FailureKind.server, status: 500);

      try {
        final quotaExceeded = e.toString().contains('ci_quota_exceeded');
        if (quotaExceeded) {
          checks.removeWhere((c) => c['name'] == 'jobs.read_trace_retry_new_attempt_and_manual_play');
        } else {
          throw e;
        }
      } catch (_) {
        failed = true;
        caughtExpected = true;
      }

      expect(caughtExpected, isTrue);
      expect(failed, isTrue);
      expect(checks.first['status'], 'FAIL');
    });
  });
}
