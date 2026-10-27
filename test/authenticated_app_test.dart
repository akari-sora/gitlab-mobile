import 'dart:async';

import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_page.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
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

  testWidgets('switching destinations fades the new one in over the old one', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    // The shell's own layers, not the stacks nested inside a destination.
    final shell = find.byKey(const ValueKey('shell-indexed-stack'));
    // Looked up afresh each time: every rebuild makes new layer widgets.
    Finder layer(int index) => find.byWidget(skipOffstage: false,
      (tester.widget<Stack>(find.descendant(of: shell, matching: find.byType(Stack, skipOffstage: false),
        skipOffstage: false).first).children.firstWhere((child) => child.key == ValueKey<int>(index))
        as KeyedSubtree).child);
    const home = 0, explore = 2;
    double opacity(int pane) => tester.widget<FadeTransition>(find.descendant(
      of: layer(pane), matching: find.byType(FadeTransition, skipOffstage: false), skipOffstage: false).first).opacity.value;
    bool painted(int pane) => !tester.widget<Offstage>(layer(pane)).offstage;
    expect(painted(explore), isFalse);

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('探索')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(opacity(explore), inExclusiveRange(0, 1));
    expect(painted(home), isTrue, reason: 'Home stays painted underneath, so the background never shows');
    expect(opacity(home), 1);
    await settleNetworkWidgets(tester);
    expect(opacity(explore), 1);
    expect(painted(home), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AuthenticatedApp navigates between shell destinations', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    // Default destination is Home (index 0) with the My Work hub.
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    expect(find.text('首頁'), findsWidgets);
    expect(find.text('我的工作'), findsOneWidget);
    expect(find.text('Mobile Workspace'), findsOneWidget, reason: 'starred projects come from the account');

    // Home › CI/CD opens the CI overview as a pushed page.
    await tester.tap(find.text('CI/CD'));
    await settleNetworkWidgets(tester);
    expect(find.text('選擇專案，查看流程與工作紀錄'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await settleNetworkWidgets(tester);

    // Switch to Inbox (index 1)
    await tester.tap(find.text('收件匣'));
    await settleNetworkWidgets(tester);
    expect(find.text('待辦'), findsOneWidget);

    // Switch to Explore (index 2)
    await tester.tap(find.text('探索'));
    await settleNetworkWidgets(tester);
    expect(find.byKey(const Key('projectSearch')), findsOneWidget);

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
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).maintainBottomViewPadding, isFalse,
      reason: 'the shell reserves the gesture inset below the bar itself');
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
    // The app palette is the default, so a legacy record has nothing to clear.
    expect(appearance.useDynamicColor, isFalse);
    expect(appearanceStore.writes, isEmpty);
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
    await pumpUntil(tester, () => !AiAccountRemoval.anyRunning,
        description: 'shell removal finishes acknowledged storage cleanup');
    await pumpUntilComplete(tester, session.readCache.quiesced);
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
    await pumpUntil(tester, () => !AiAccountRemoval.anyRunning,
        description: 'shell removal finishes acknowledged storage cleanup');
    await pumpUntilComplete(tester, session.readCache.quiesced);
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
    await pumpUntil(tester, () => session.active == null,
        description: 'sign-out advances the visible session');
    await pumpUntilComplete(tester, session.readCache.quiesced);
    await tester.pumpAndSettle();

    expect(session.active, isNull);
  });

  testWidgets('shell PopScope canPop only on the Projects tab', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    await tester.tap(find.text('探索'));
    await settleNetworkWidgets(tester);
    expect(canPop(), isFalse);

    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    expect(canPop(), isFalse);

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('首頁'),
    ));
    await settleNetworkWidgets(tester);
    expect(canPop(), isTrue);

    await tester.tap(find.text('收件匣'));
    await settleNetworkWidgets(tester);
    expect(canPop(), isFalse);
    tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).onPopInvokedWithResult?.call(false, null);
    await tester.pump();
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    expect(canPop(), isTrue);
    expect(find.text('我的工作'), findsOneWidget);
  });

  testWidgets('a probe that finishes before load still clears an unsupported dynamic colour', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      // The user opted into Material You on a device that cannot provide it.
      final store = MemoryAppearanceStore()..value = encodeAppearance(ThemeMode.system, true);
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
      expect(local.useDynamicColor, isFalse, reason: 'the app palette is the default until the record loads');
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
    // A stored opt-in from a device that cannot build a dynamic scheme.
    final store = MemoryAppearanceStore()..value = encodeAppearance(ThemeMode.system, true);
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
    await tester.pump();
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
    await pumpUntil(tester, () => !AiAccountRemoval.anyRunning,
        description: 'shell removal finishes acknowledged storage cleanup');
    await pumpUntilComplete(tester, session.readCache.quiesced);
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
    await pumpUntil(tester, () => !AiAccountRemoval.anyRunning,
        description: 'shell removal finishes acknowledged storage cleanup');
    await pumpUntilComplete(tester, session.readCache.quiesced);
    await settleNetworkWidgets(tester);

    expect(session.accounts, isNotEmpty);
    expect(session.active, isNotNull);
    expect(store.accounts, isNotEmpty);
    expect(archive.existsSync(), isTrue);
    expect(find.textContaining('無法清除產物'), findsOneWidget);
    expect(find.textContaining('帳號仍保留'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders NavigationRail at >= 600 dp width and hides NavigationBar', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
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

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('smooth transition between NavigationBar and NavigationRail preserves tab index', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = WorkspaceFixture();
    final store = MemoryAccountStore();
    final session = controllerFor(store, fixture.adapter);
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

    // In 412 dp, NavigationBar is visible. Switch to Inbox (0)
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('收件匣'));
    await settleNetworkWidgets(tester);
    expect(find.text('待辦'), findsOneWidget);

    // Dynamic resize to 840 dp
    tester.view.physicalSize = const Size(840, 900);
    await tester.pump();
    await settleNetworkWidgets(tester);

    // Assert: NavigationRail is visible, NavigationBar is gone, tab 0 (Inbox) is still active!
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('待辦'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<SessionController> connectedSession(WidgetTester tester, WorkspaceFixture fixture) async {
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    return session;
  }

  for (final (topInset, bottomInset, keyboardInset) in [
    (36.0, 24.0, 0.0),
    (48.0, 48.0, 0.0),
    (36.0, 24.0, 300.0),
  ]) {
    testWidgets('bottom navigation has no status inset and reserves $bottomInset dp once with keyboard $keyboardInset', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      tester.view.padding = FakeViewPadding(top: topInset, bottom: keyboardInset > 0 ? 0 : bottomInset);
      tester.view.viewPadding = FakeViewPadding(top: topInset, bottom: bottomInset);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
      addTearDown(tester.view.reset);
      final session = await connectedSession(tester, WorkspaceFixture());
      await tester.pumpWidget(
        AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
      );
      await settleNetworkWidgets(tester);
      final bar = tester.getRect(find.byType(NavigationBar));
      final height = Theme.of(tester.element(find.byType(NavigationBar))).navigationBarTheme.height ?? 80;
      expect(bar.bottom, 900 - bottomInset, reason: 'the system inset stays below the bar, including with a keyboard');
      expect(bar.height, height, reason: 'the status-bar inset must not enlarge the navigation');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('every destination fits a 320 dp phone at double text size', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(320, 700);
    tester.view.padding = const FakeViewPadding(top: 36, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 36, bottom: 24);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = await connectedSession(tester, WorkspaceFixture());
    await tester.pumpWidget(
      AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
    );
    await settleNetworkWidgets(tester);
    expect(tester.takeException(), isNull, reason: 'home');
    for (final destination in ['收件匣', '探索', '我的']) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(destination)));
      await settleNetworkWidgets(tester);
      expect(tester.takeException(), isNull, reason: destination);
    }
    await tester.dragUntilVisible(find.text('我的動態'), find.text('帳號'), const Offset(0, -120));
    await tester.pumpAndSettle();
    for (final label in ['我的動態', '我的群組', '全域搜尋']) {
      expect(tester.renderObject<RenderParagraph>(find.text(label)).didExceedMaxLines, isFalse,
        reason: '$label wraps instead of truncating to 我的…');
    }
    expect(tester.takeException(), isNull);
  });

  group('C2e read cache in the authenticated shell', () {
    ReadCacheCleanupState state(
      ReadCacheCleanupOperation operation,
      ReadCacheCleanupDisposition disposition,
    ) => ReadCacheCleanupState(
      operation: operation,
      disposition: disposition,
      code: ReadCacheCleanupCode.cleanupFailed,
      clearResult: const DiskClearResult(
        keyGoneConfirmed: false,
        directoryGoneConfirmed: false,
        markerDurable: false,
        complete: false,
      ),
    );
    final preserved = state(
      ReadCacheCleanupOperation.mutation,
      ReadCacheCleanupDisposition.originalOutcomePreserved,
    );
    const preservedText = '離線快取待清除。操作的結果不受影響。離線快取已暫停使用，清除完成後才會恢復。';
    Finder snack(String text) =>
        find.descendant(of: find.byType(SnackBar), matching: find.text(text));

    Future<(SessionController, MemoryAccountStore)> signIn(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = WorkspaceFixture();
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);
      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });
      return (session, store);
    }

    testWidgets('我的 › 儲存與快取 exists and the shell installs the user controls', (tester) async {
      final (session, store) = await signIn(tester);
      expect(store.readCache.controlsInstalled, isFalse, reason: 'nothing opens the gate before the shell');
      await tester.pumpWidget(
        AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
      );
      await settleNetworkWidgets(tester);
      expect(store.readCache.controlsInstalled, isTrue);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('我的')));
      await settleNetworkWidgets(tester);
      final row = find.byKey(const ValueKey('read-cache-row'));
      await tester.scrollUntilVisible(row, 200);
      expect(find.text('儲存與快取'), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('離線快取')), findsOneWidget);
      await tester.tap(row);
      await settleNetworkWidgets(tester);
      expect(find.byType(ReadCacheSettingsPage), findsOneWidget);
      expect(find.byKey(const ValueKey('read-cache-switch')), findsOneWidget);
      expect(find.byKey(const ValueKey('read-cache-clear')), findsOneWidget);
    });

    testWidgets('notices reach only this account and generation, merge, and mark the 我的 row', (tester) async {
      final (session, store) = await signIn(tester);
      final cache = store.readCache;
      final key = session.active!.key;
      final binding = DiskBinding(accountKey: key, generation: session.generation);
      // Raised before the shell exists (start-up): shown once it mounts.
      cache.reportCleanup(binding, state(
        ReadCacheCleanupOperation.startup, ReadCacheCleanupDisposition.diskClosed));
      await tester.pumpWidget(
        AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts, buildInfoLoader: _shellBuildInfo),
      );
      await settleNetworkWidgets(tester);
      expect(snack('無法清除離線快取。離線快取已暫停使用，重試清除完成後才會恢復。'), findsOneWidget);
      ScaffoldMessenger.of(tester.element(find.byType(NavigationBar))).hideCurrentSnackBar();
      await tester.pumpAndSettle();

      // An earlier generation of this account, or another account: never shown.
      cache.reportCleanup(DiskBinding(accountKey: key, generation: session.generation - 1), preserved);
      cache.reportCleanup(DiskBinding(accountKey: 'synthetic-other#9', generation: session.generation), preserved);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(snack(preservedText), findsNothing);

      // A blocked request is presented by the operation that failed.
      cache.reportCleanup(binding, state(
        ReadCacheCleanupOperation.mutation, ReadCacheCleanupDisposition.requestBlockedBeforeSend));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SnackBar), findsNothing);

      // This account and generation: shown once, repeats merge.
      cache.reportCleanup(binding, preserved);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(snack(preservedText), findsOneWidget);
      expect(find.descendant(of: find.byType(SnackBar), matching: find.text('重試清除')), findsOneWidget);
      cache.reportCleanup(binding, preserved);
      await tester.pump();
      ScaffoldMessenger.of(tester.element(find.byType(NavigationBar))).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing, reason: 'a repeated notice is not queued again');

      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('我的')));
      await settleNetworkWidgets(tester);
      final row = find.byKey(const ValueKey('read-cache-row'));
      await tester.scrollUntilVisible(row, 200);
      expect(find.descendant(of: row, matching: find.text('清除未完成，暫停使用')), findsOneWidget);
    });
  });
}
