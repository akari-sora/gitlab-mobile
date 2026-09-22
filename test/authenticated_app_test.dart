import 'dart:async';

import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/workspace_fixture.dart';
import 'support/widget_settle.dart';

Future<BuildInfo> _shellBuildInfo() async => const BuildInfo(
  version: '0.3.0',
  buildNumber: '3',
  commit: 'shell',
);

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

  testWidgets('AuthenticatedApp navigates between shell destinations', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
    });

    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);

    // Default destination is Projects (index 1)
    expect(find.text('專案'), findsWidgets);

    // Switch to Inbox (index 0)
    await tester.tap(find.text('收件匣'));
    await settleNetworkWidgets(tester);
    expect(find.text('待辦'), findsOneWidget);

    // Switch to CI (index 2)
    await tester.tap(find.text('CI'));
    await settleNetworkWidgets(tester);
    expect(find.text('選擇專案，查看流程與工作紀錄'), findsOneWidget);

    // Switch to My (index 3)
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    expect(find.text('Developer'), findsOneWidget);
    expect(find.text('@developer'), findsWidgets);
    expect(find.text('外觀'), findsOneWidget);
    expect(find.text('帳號'), findsOneWidget);
    expect(find.text('此裝置沒有動態配色'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.onChanged, isNull);
    expect(tile.value, isFalse);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).maintainBottomViewPadding, isTrue);
  });

  testWidgets('AuthenticatedApp persists the theme mode chosen in My tab', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
    });

    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);

    // Navigate to My tab
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);

    // Select dark theme
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(appearanceStore.value, encodeAppearance(ThemeMode.dark, dynamicColorDefault()));

    // Select light theme
    await tester.tap(find.text('淺色'));
    await tester.pumpAndSettle();

    final MaterialApp appLight = tester.widget(find.byType(MaterialApp));
    expect(appLight.themeMode, ThemeMode.light);
    expect(appearanceStore.value, encodeAppearance(ThemeMode.light, dynamicColorDefault()));
    expect(appearanceStore.writes, [
      encodeAppearance(ThemeMode.dark, dynamicColorDefault()),
      encodeAppearance(ThemeMode.light, dynamicColorDefault()),
    ]);
  });

  testWidgets('AuthenticatedApp starts from the stored appearance', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    appearanceStore.value = 'dark';

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
      await appearance.load();
    });

    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);

    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    // No dynamic scheme: the Android default of on is stored back as off.
    expect(appearance.useDynamicColor, isFalse);
    expect(appearanceStore.writes, [encodeAppearance(ThemeMode.dark, false)]);
  });

  testWidgets('AuthenticatedApp keeps the appearance across an account switch', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
    });

    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    // main.dart re-keys AuthenticatedApp on session.generation, so an account
    // switch throws the whole authenticated tree away and builds a new one.
    await tester.pumpWidget(
      AuthenticatedApp(
        key: const ValueKey(1),
        session: session,
        appearance: appearance,
        shortcuts: shortcuts,
        buildInfoLoader: _shellBuildInfo,
      ),
    );
    await settleNetworkWidgets(tester);

    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
  });

  testWidgets('AuthenticatedApp removes secondary account from My tab', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final secondaryAccount = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(
        id: 8,
        username: 'secondary',
        name: 'Secondary User',
      ),
      token: 'synthetic-token-2',
    );
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
      // Add secondary account to store and reload
      await store.save([...store.accounts, secondaryAccount]);
      await session.initialize();
    });

    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);

    // Navigate to My tab
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);

    expect(find.text('@secondary'), findsOneWidget);

    // Tap remove on secondary user
    final removeButtons = find.byTooltip('從此裝置移除帳號');
    expect(removeButtons, findsNWidgets(2));
    await tester.tap(removeButtons.last);
    await tester.pumpAndSettle();

    // Confirm dialog
    expect(find.text('移除此帳號？'), findsOneWidget);
    await tester.tap(find.text('確認'));
    await tester.pumpAndSettle();

    expect(store.accounts.any((a) => a.key == secondaryAccount.key), isFalse);
    expect(find.text('@secondary'), findsNothing);
    expect(session.active?.user.username, 'developer');
  });

  testWidgets('AuthenticatedApp removes active account and ends session', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
    });

    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);

    // Navigate to My tab
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);

    final removeButton = find.byTooltip('從此裝置移除帳號');
    await tester.tap(removeButton);
    await tester.pumpAndSettle();

    await tester.tap(find.text('確認'));
    await tester.pumpAndSettle();

    expect(store.accounts, isEmpty);
    expect(session.active, isNull);
  });

  testWidgets('AuthenticatedApp endSession button ends current session', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
    });

    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);

    // Navigate to My tab
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('新增或重新連接帳號'));
    await tester.pumpAndSettle();

    expect(session.active, isNull);
  });

  testWidgets('shell PopScope canPop only on the Projects tab', (tester) async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);

    bool canPop() {
      final scopes = tester.widgetList<PopScope<Object?>>(find.byType(PopScope<Object?>));
      expect(scopes, hasLength(1), reason: 'The shell root is the only PopScope');
      return scopes.single.canPop;
    }
    expect(canPop(), isTrue);

    await tester.tap(find.text('收件匣'));
    await settleNetworkWidgets(tester);
    expect(canPop(), isFalse);

    await tester.tap(find.text('CI'));
    await settleNetworkWidgets(tester);
    expect(canPop(), isFalse);

    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    expect(canPop(), isFalse);

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('專案'),
    ));
    await settleNetworkWidgets(tester);
    expect(canPop(), isTrue);

    await tester.tap(find.text('收件匣'));
    await settleNetworkWidgets(tester);
    expect(canPop(), isFalse);
    tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).onPopInvokedWithResult?.call(false, null);
    await tester.pump();
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
    expect(canPop(), isTrue);
    expect(find.byKey(const Key('projectSearch')), findsOneWidget);
  });

  testWidgets('a probe that finishes before load still clears an unsupported dynamic colour', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final store = MemoryAppearanceStore();
      final gate = Completer<void>();
      store.readDelay = gate.future;
      final local = AppearanceController(store);
      addTearDown(local.dispose);
      final loading = local.load();
      final fixture = WorkspaceFixture();
      final session = controllerFor(MemoryAccountStore(), fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);
      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });
      final localShortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
      addTearDown(localShortcuts.dispose);
      await tester.pumpWidget(AuthenticatedApp(
        session: session,
        appearance: local,
        shortcuts: localShortcuts,
        buildInfoLoader: _shellBuildInfo,
      ));
      await settleNetworkWidgets(tester);
      expect(local.loaded, isFalse);
      expect(local.useDynamicColor, isTrue);
      expect(store.writes, isEmpty);
      gate.complete();
      store.readDelay = null;
      await tester.runAsync(() => loading);
      expect(local.loaded, isTrue);
      await settleNetworkWidgets(tester);
      expect(local.useDynamicColor, isFalse);
      expect(store.value, encodeAppearance(ThemeMode.system, false));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a device without a dynamic scheme stores the flag off', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
    final store = MemoryAppearanceStore();
    final local = AppearanceController(store);
    addTearDown(local.dispose);
    await local.load();
    expect(local.useDynamicColor, isTrue);
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    final localShortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
    addTearDown(localShortcuts.dispose);
    await tester.pumpWidget(AuthenticatedApp(
      session: session,
      appearance: local,
      shortcuts: localShortcuts,
      buildInfoLoader: _shellBuildInfo,
    ));
    await settleNetworkWidgets(tester);
    expect(local.useDynamicColor, isFalse);
    expect(store.value, encodeAppearance(ThemeMode.system, false));
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    expect(find.text('此裝置沒有動態配色'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('dynamic colour switch writes through the controller', (tester) async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    final dynamicLight = ColorScheme.fromSeed(seedColor: const Color(0xFF006E1C));
    final dynamicDark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF006E1C),
      brightness: Brightness.dark,
    );
    await tester.pumpWidget(AuthenticatedApp(
      session: session,
      appearance: appearance,
      shortcuts: shortcuts,
      dynamicLight: dynamicLight,
      dynamicDark: dynamicDark,
      buildInfoLoader: _shellBuildInfo,
    ));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);

    expect(find.text('使用系統配色（Material You）'), findsOneWidget);
    expect(find.text('Android 12 以上會依桌布色調產生配色'), findsOneWidget);
    final enabled = dynamicColorDefault();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, enabled);
    final seeded = appTheme(Brightness.light).colorScheme.primary;
    Color primary() => tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!.colorScheme.primary;
    expect(primary(), enabled ? dynamicLight.primary : seeded);

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(appearance.useDynamicColor, !enabled);
    expect(appearanceStore.value, encodeAppearance(ThemeMode.system, !enabled));
    expect(primary(), !enabled ? dynamicLight.primary : seeded);
  });

  testWidgets('removing an account deletes its downloaded artifacts', (tester) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    Directory? root;
    final previous = artifactStorageRoot;
    addTearDown(() {
      artifactStorageRoot = previous;
      final created = root;
      if (created != null && created.existsSync()) created.deleteSync(recursive: true);
    });

    late final Directory directory;
    await tester.runAsync(() async {
      final created = await Directory.systemTemp.createTemp('gitlab-mobile-remove-artifacts-');
      root = created;
      artifactStorageRoot = () async => created;
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      directory = await jobArtifactDirectory(session.active!, 42, 7);
      await File('${directory.path}/job.zip').writeAsBytes([9]);
    });

    await tester.pumpWidget(AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('從此裝置移除帳號'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('確認'));
    await settleNetworkWidgets(tester);

    expect(session.accounts, isEmpty);
    expect(directory.existsSync(), isFalse);
  });

  testWidgets('artifact cleanup failure keeps the account and its archives', (tester) async {
    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    Directory? root;
    final previous = artifactStorageRoot;
    addTearDown(() {
      artifactStorageRoot = previous;
      final created = root;
      if (created != null && created.existsSync()) created.deleteSync(recursive: true);
    });

    late final File archive;
    await tester.runAsync(() async {
      final created = await Directory.systemTemp.createTemp('gitlab-mobile-remove-fail-');
      root = created;
      artifactStorageRoot = () async => created;
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      final directory = await jobArtifactDirectory(session.active!, 42, 7);
      archive = File('${directory.path}/job.zip');
      await archive.writeAsBytes([9]);
      artifactStorageRoot = () async => throw const FileSystemException('unreadable');
    });

    await tester.pumpWidget(AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('從此裝置移除帳號'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('確認'));
    await settleNetworkWidgets(tester);

    expect(session.accounts, isNotEmpty);
    expect(session.active, isNotNull);
    expect(store.accounts, isNotEmpty);
    expect(archive.existsSync(), isTrue);
    expect(find.textContaining('無法清除產物'), findsOneWidget);
    expect(find.textContaining('帳號仍保留'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
