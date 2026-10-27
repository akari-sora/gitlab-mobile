import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/brand.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/ai_run_notification_shell.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

final class _Store implements AppLockStore {
  _Store([this.value = false]);
  bool value;
  int writes = 0;
  @override
  Future<bool> read() async => value;
  @override
  Future<void> write(bool enabled) async {
    writes++;
    value = enabled;
  }
}

final class _Auth implements AppLockAuthenticator {
  _Auth({this.supported = true});
  bool supported;
  final reasons = <String>[];
  Completer<bool>? pending;
  bool answer = true;
  @override
  Future<bool> available() async => supported;
  @override
  Future<bool> authenticate(String reason) {
    reasons.add(reason);
    final gate = pending;
    return gate == null ? Future.value(answer) : gate.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppLockController lock(
    _Store store,
    _Auth auth, {
    DateTime Function()? clock,
  }) {
    final controller = AppLockController(
      store: store,
      authenticator: auth,
      clock: clock,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('off by default: nothing is covered once the choice is known', () async {
    final controller = lock(_Store(), _Auth());
    expect(
      controller.covering,
      isTrue,
      reason: 'covered until the stored choice is read',
    );
    await controller.start();
    expect(controller.covering, isFalse);
    expect(controller.available, isTrue);
    expect(await controller.didPopRoute(), isFalse);
  });

  test(
    'on: the app starts locked and opens only after a passing check',
    () async {
      final auth = _Auth()..answer = false;
      final controller = lock(_Store(true), auth);
      await controller.start();
      expect(controller.locked, isTrue);
      expect(
        await controller.didPopRoute(),
        isTrue,
        reason: 'back is held behind the lock',
      );
      expect(await controller.unlock(), isFalse);
      expect(controller.locked, isTrue);
      auth.answer = true;
      expect(await controller.unlock(), isTrue);
      expect(controller.locked, isFalse);
      expect(auth.reasons, ['解鎖 $appName', '解鎖 $appName']);
    },
  );

  test(
    'turning it on needs a passing check; turning it off does not',
    () async {
      final store = _Store();
      final auth = _Auth()..answer = false;
      final controller = lock(store, auth);
      await controller.start();
      expect(await controller.setEnabled(true), isFalse);
      expect(controller.enabled, isFalse);
      expect(store.writes, 0);

      auth.answer = true;
      expect(await controller.setEnabled(true), isTrue);
      expect(store.value, isTrue);
      expect(
        controller.locked,
        isFalse,
        reason: 'turning it on does not lock the open app',
      );

      auth.answer = false;
      expect(await controller.setEnabled(false), isTrue);
      expect(store.value, isFalse);
      expect(auth.reasons, hasLength(2));
    },
  );

  test('it locks again only after a long enough time away', () async {
    var now = DateTime.utc(2026, 10, 19, 12);
    final controller = lock(_Store(true), _Auth(), clock: () => now);
    await controller.start();
    await controller.unlock();

    controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
    now = now.add(const Duration(seconds: 30));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.locked, isFalse, reason: 'a quick look elsewhere');

    controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 1));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.locked, isTrue);
  });

  test(
    'the time spent on the check itself never locks the app again',
    () async {
      var now = DateTime.utc(2026, 10, 19, 12);
      final auth = _Auth();
      final controller = lock(_Store(true), auth, clock: () => now);
      await controller.start();
      auth.pending = Completer<bool>();
      final unlocking = controller.unlock();
      expect(controller.authenticating, isTrue);
      // The system credential screen sends the app away for a long while.
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 5));
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      auth.pending!.complete(true);
      expect(await unlocking, isTrue);
      expect(controller.locked, isFalse);
    },
  );

  test('a device without a screen lock cannot turn it on', () async {
    final controller = lock(_Store(), _Auth(supported: false));
    await controller.start();
    expect(controller.available, isFalse);
  });

  testWidgets(
    'the gate covers the app, prompts once and opens after the check',
    (tester) async {
      final auth = _Auth()..answer = false;
      final controller = AppLockController(
        store: _Store(true),
        authenticator: auth,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AppLockGate(controller: controller, child: child!),
          home: const Scaffold(body: Text('secret')),
        ),
      );
      expect(
        find.text('secret').hitTestable(),
        findsNothing,
        reason: 'covered before the choice is known',
      );
      expect(find.text('解鎖'), findsNothing);

      await tester.runAsync(controller.start);
      await tester.pump();
      await tester.pump();
      expect(find.text('$appName 已鎖定'), findsOneWidget);
      expect(find.text('secret').hitTestable(), findsNothing);
      expect(
        auth.reasons,
        hasLength(1),
        reason: 'the lock asks once by itself',
      );

      auth.answer = true;
      await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
      await tester.pump();
      await tester.pump();
      expect(find.text('$appName 已鎖定'), findsNothing);
      expect(find.text('secret').hitTestable(), findsOneWidget);
      expect(auth.reasons, hasLength(2));
    },
  );

  testWidgets('我的 › 安全性 turns the lock on only after a passing check', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
    });
    final store = _Store();
    final auth = _Auth()..answer = false;
    final controller = AppLockController(store: store, authenticator: auth);
    final appearance = AppearanceController(MemoryAppearanceStore());
    final shortcuts = LauncherShortcuts(
      FakeAppShortcutHost(),
      MemoryRecentProjectStore(),
    );
    addTearDown(() {
      controller.dispose();
      appearance.dispose();
      shortcuts.dispose();
      session.dispose();
      fixture.api.close();
    });
    await tester.runAsync(controller.start);
    await tester.pumpWidget(
      AuthenticatedApp(
        session: session,
        appearance: appearance,
        shortcuts: shortcuts,
        lock: controller,
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    final toggle = find.byKey(const ValueKey('app-lock-switch'));
    await tester.scrollUntilVisible(toggle, 200);

    await tester.tap(toggle);
    await settleNetworkWidgets(tester);
    expect(controller.enabled, isFalse);
    expect(find.text('沒有通過驗證，App 鎖定維持關閉'), findsOneWidget);

    auth.answer = true;
    await tester.tap(toggle);
    await settleNetworkWidgets(tester);
    expect(controller.enabled, isTrue);
    expect(store.value, isTrue);
    expect(
      find.text('$appName 已鎖定'),
      findsNothing,
      reason: 'turning it on keeps the app open',
    );
  });

  group('a tapped AI run notification behind the lock', () {
    late FakeNotificationPlatform platform;
    late _Auth auth;
    late AppLockController controller;
    late NotificationShell shell;
    late NotificationChat chat;

    /// The app is locked and asking; the tap arrives during the check.
    Future<void> tapWhileLocked(WidgetTester tester) async {
      platform = FakeNotificationPlatform()..install();
      addTearDown(platform.uninstall);
      auth = _Auth()..pending = Completer<bool>();
      controller = lock(_Store(true), auth);
      await tester.runAsync(controller.start);
      shell = await NotificationShell.start(
        tester,
        platform: platform,
        lock: controller,
      );
      expect(controller.authenticating, isTrue);
      chat = shell.openChat(tester);
      await platform.tap(notificationPayload(chat.id, shell.generation));
      await settleNetworkWidgets(tester);
      expect(shell.gate.waiting, isTrue);
      expect(find.byType(AiChatPage), findsNothing);
      expect(find.text('$appName 已鎖定'), findsOneWidget);
    }

    testWidgets(
      'a cancelled unlock never navigates, not even after a later unlock',
      (tester) async {
        await tapWhileLocked(tester);
        auth.pending!.complete(false);
        await settleNetworkWidgets(tester);
        expect(controller.locked, isTrue);
        expect(shell.gate.waiting, isFalse, reason: 'the tap is dropped');
        expect(find.byType(AiChatPage), findsNothing);

        auth
          ..pending = null
          ..answer = true;
        await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
        await settleNetworkWidgets(tester);
        expect(controller.locked, isFalse);
        expect(find.byType(AiChatPage), findsNothing);
        expect(selectedDestination(tester), 0);
        expect(chat.approved, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('a passing unlock opens the conversation at its waiting card', (
      tester,
    ) async {
      await tapWhileLocked(tester);
      auth.pending!.complete(true);
      await settleNetworkWidgets(tester);
      expect(controller.locked, isFalse);
      final page = tester.widget<AiChatPage>(find.byType(AiChatPage));
      expect(page.session, same(chat));
      expect(
        find.byKey(const ValueKey('ai-proposal-card-exec-1')).hitTestable(),
        findsOneWidget,
      );
      expect(chat.approved, isEmpty, reason: 'shown, never approved');
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('a warm tap that arrives while the app is away', () {
    late FakeNotificationPlatform platform;
    late _Auth auth;
    late AppLockController controller;
    late NotificationShell shell;
    late NotificationChat chat;
    late DateTime now;

    Future<void> tapWhileAway(WidgetTester tester, Duration away) async {
      platform = FakeNotificationPlatform()..install();
      addTearDown(platform.uninstall);
      now = DateTime.utc(2026, 10, 28, 12);
      auth = _Auth();
      controller = lock(_Store(true), auth, clock: () => now);
      await tester.runAsync(controller.start);
      shell = await NotificationShell.start(
        tester,
        platform: platform,
        lock: controller,
      );
      expect(controller.locked, isFalse, reason: 'unlocked at start');
      chat = shell.openChat(tester);
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(away);
      // Android delivers the tap before the app reports it is back.
      await platform.tap(notificationPayload(chat.id, shell.generation));
      await settleNetworkWidgets(tester);
      expect(shell.gate.waiting, isTrue);
      expect(find.byType(AiChatPage), findsNothing);
    }

    testWidgets(
      'long enough away: the lock comes back first and the card opens only '
      'after unlock',
      (tester) async {
        await tapWhileAway(tester, const Duration(minutes: 2));
        auth.pending = Completer<bool>();
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await settleNetworkWidgets(tester);
        expect(controller.locked, isTrue);
        expect(find.byType(AiChatPage), findsNothing);

        auth.pending!.complete(true);
        await settleNetworkWidgets(tester);
        expect(
          tester.widget<AiChatPage>(find.byType(AiChatPage)).session,
          same(chat),
        );
        expect(
          find.byKey(const ValueKey('ai-proposal-card-exec-1')).hitTestable(),
          findsOneWidget,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('a short look away: the card opens once the app is back', (
      tester,
    ) async {
      await tapWhileAway(tester, const Duration(seconds: 10));
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settleNetworkWidgets(tester);
      expect(controller.locked, isFalse);
      expect(
        tester.widget<AiChatPage>(find.byType(AiChatPage)).session,
        same(chat),
      );
      expect(chat.approved, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  testWidgets('without a controller the gate is transparent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppLockGate(controller: null, child: child!),
        home: const Scaffold(body: Text('open')),
      ),
    );
    expect(find.text('open').hitTestable(), findsOneWidget);
  });
}
