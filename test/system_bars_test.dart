import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/main.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/workspace_fixture.dart';

void main() {
  testWidgets('signed-in bars follow light and dark themes in both navigation insets', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    final appearance = AppearanceController(MemoryAppearanceStore());
    addTearDown(appearance.dispose);
    final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
    addTearDown(shortcuts.dispose);

    Future<void> expectIcons(ThemeMode mode, double bottomInset, Brightness icons) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      final padding = FakeViewPadding(top: 24, bottom: bottomInset);
      tester.view.padding = padding;
      tester.view.viewPadding = padding;
      await appearance.select(mode);
      await tester.pumpWidget(AuthenticatedApp(
        session: session,
        appearance: appearance,
        shortcuts: shortcuts,
      ));
      // Theme changes animate; a spinner on the project list never settles.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final style = SystemChrome.latestStyle;
      expect(style, isNotNull);
      expect(style!.statusBarIconBrightness, icons, reason: '$mode bottom $bottomInset');
      expect(style.systemNavigationBarIconBrightness, icons, reason: '$mode bottom $bottomInset');
      expect(style.statusBarColor, Colors.transparent);
      expect(style.systemNavigationBarColor, Colors.transparent);
      expect(style.systemNavigationBarDividerColor, Colors.transparent);
      expect(style.systemStatusBarContrastEnforced, isFalse);
      expect(style.systemNavigationBarContrastEnforced, isFalse);
    }

    try {
      await expectIcons(ThemeMode.light, 48, Brightness.dark);
      await expectIcons(ThemeMode.dark, 16, Brightness.light);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('login bars follow platform brightness without an app bar', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    FlutterSecureStorage.setMockInitialValues({});
    final session = controllerFor(MemoryAccountStore(), FakeAdapter((_) => jsonResponse([])));
    addTearDown(session.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    try {
      await tester.pumpWidget(ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: const GitLabMobileApp(),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);
      expect(SystemChrome.latestStyle?.systemNavigationBarIconBrightness, Brightness.dark);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.light);
      expect(SystemChrome.latestStyle?.systemNavigationBarIconBrightness, Brightness.light);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
