import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/main.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/memory_appearance_store.dart';

void main() {
  test('an unset store keeps the system appearance without writing', () async {
    final store = MemoryAppearanceStore();
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    expect(controller.mode, ThemeMode.system);
    expect(controller.loaded, isFalse);
    await controller.load();
    expect(controller.mode, ThemeMode.system);
    expect(controller.loaded, isTrue);
    expect(store.writes, isEmpty);
  });

  for (final value in ['light', 'dark']) {
    test('stored $value appearance is restored', () async {
      final controller = AppearanceController(MemoryAppearanceStore(value));
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.mode, themeModeFrom(value));
      expect(controller.mode, isNot(ThemeMode.system));
    });
  }

  for (final value in ['', ' ', 'Dark', 'DARK', 'system', 'blue', '{"a":1}']) {
    test('invalid stored appearance "$value" falls back to system', () async {
      final controller = AppearanceController(MemoryAppearanceStore(value));
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.load();
      expect(controller.mode, ThemeMode.system);
      expect(controller.loaded, isTrue);
      expect(notifications, 1, reason: 'loaded still notifies when the choice matches the default');
    });
  }

  test('an unreadable store loads silently as system', () async {
    final store = MemoryAppearanceStore('dark')..rejectRead = true;
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.mode, ThemeMode.system);
    expect(controller.loaded, isTrue);
  });

  test('selecting writes the mode name and notifies once', () async {
    final store = MemoryAppearanceStore();
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.select(ThemeMode.dark);
    expect(store.value, encodeAppearance(ThemeMode.dark, dynamicColorDefault()));
    expect(controller.mode, ThemeMode.dark);
    expect(notifications, 1);
    await controller.select(ThemeMode.dark);
    expect(notifications, 1, reason: 'Re-selecting the same mode is not a change');
  });

  test('a rejected write keeps the chosen mode for this run', () async {
    final store = MemoryAppearanceStore()..rejectWrite = true;
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    await controller.select(ThemeMode.light);
    expect(controller.mode, ThemeMode.light);
    expect(store.value, isNull);
    expect(store.writes, [encodeAppearance(ThemeMode.light, dynamicColorDefault())]);
  });

  test('dynamic colour flag round-trips and legacy values keep the default', () async {
    final store = MemoryAppearanceStore(encodeAppearance(ThemeMode.light, false));
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.mode, ThemeMode.light);
    expect(controller.useDynamicColor, isFalse);
    await controller.setUseDynamicColor(true);
    expect(store.value, encodeAppearance(ThemeMode.light, true));
    await controller.select(ThemeMode.dark);
    expect(controller.useDynamicColor, isTrue);
    expect(store.value, encodeAppearance(ThemeMode.dark, true));

    final legacy = AppearanceController(MemoryAppearanceStore('dark'));
    addTearDown(legacy.dispose);
    await legacy.load();
    expect(legacy.mode, ThemeMode.dark);
    expect(legacy.useDynamicColor, dynamicColorDefault());
  });

  test('a choice made during load is not overwritten', () async {
    final original = encodeAppearance(ThemeMode.light, false);
    final store = MemoryAppearanceStore(original);
    final gate = Completer<void>();
    store.readDelay = gate.future;
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    final loading = controller.load();
    await Future<void>.delayed(Duration.zero);
    // Overwrite the store before the read resumes. The in-flight read must
    // still return [original] so the generation check is what keeps dark.
    await controller.select(ThemeMode.dark);
    gate.complete();
    await loading;
    expect(store.reads, [original]);
    expect(controller.mode, ThemeMode.dark);
    expect(store.value, encodeAppearance(ThemeMode.dark, dynamicColorDefault()));
  });

  test('only the latest appearance write is stored', () async {
    final store = MemoryAppearanceStore();
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    final toggled = !controller.useDynamicColor;
    final first = controller.select(ThemeMode.dark);
    final second = controller.setUseDynamicColor(toggled);
    await Future.wait([first, second]);
    expect(controller.mode, ThemeMode.dark);
    expect(controller.useDynamicColor, toggled);
    expect(store.writes, [encodeAppearance(ThemeMode.dark, toggled)]);
  });

  test('an in-flight appearance write does not land after a newer choice', () async {
    final store = MemoryAppearanceStore();
    final gate = Completer<void>();
    store.writeDelay = gate.future;
    final controller = AppearanceController(store);
    addTearDown(controller.dispose);
    final firstFlag = controller.useDynamicColor;
    final first = controller.select(ThemeMode.dark);
    await Future<void>.delayed(Duration.zero);
    final toggled = !controller.useDynamicColor;
    store.writeDelay = null;
    final second = controller.setUseDynamicColor(toggled);
    gate.complete();
    await first;
    await second;
    expect(controller.mode, ThemeMode.dark);
    expect(controller.useDynamicColor, toggled);
    expect(store.writes, [
      encodeAppearance(ThemeMode.dark, firstFlag),
      encodeAppearance(ThemeMode.dark, toggled),
    ]);
    expect(store.value, encodeAppearance(ThemeMode.dark, toggled));
  });

  testWidgets('a fresh app with a stored dark appearance boots dark', (tester) async {
    FlutterSecureStorage.setMockInitialValues({SecureAppearanceStore.key: 'dark'});
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final session = controllerFor(MemoryAccountStore(), adapter);
    addTearDown(session.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: const GitLabMobileApp(),
    ));
    // The stored value is read asynchronously, so the first frame is still the
    // system default: reading the key store must never gate app start.
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.system);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('instanceField')), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('a fresh app without a stored appearance boots on system', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final session = controllerFor(MemoryAccountStore(), adapter);
    addTearDown(session.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: const GitLabMobileApp(),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.system);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
