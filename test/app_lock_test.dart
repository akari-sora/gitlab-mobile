import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/brand.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
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
