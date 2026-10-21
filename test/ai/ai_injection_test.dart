import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/shell/incoming_links.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_shortcuts.dart';
import '../support/memory_appearance_store.dart';
import '../support/workspace_fixture.dart';
import '../support/widget_settle.dart';

Future<BuildInfo> _buildInfo() async => const BuildInfo(
  version: '0.6.0',
  buildNumber: '6',
  commit: 'ai-injection',
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('buildAiControllers follows its injected decision', () {
    expect(buildAiControllers(enabled: false), isNull);

    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);

    final controllers = buildAiControllers(
      enabled: true,
      settings: settings,
      history: history,
    );
    expect(controllers?.settings, same(settings));
    expect(controllers?.history, same(history));
  });

  testWidgets('injected shell shows and opens AI settings; omitted shell hides it', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    final appearance = AppearanceController(MemoryAppearanceStore());
    final shortcuts = LauncherShortcuts(
      FakeAppShortcutHost(),
      MemoryRecentProjectStore(),
    );
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    final ai = AiControllers(settings: settings, history: history);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    addTearDown(appearance.dispose);
    addTearDown(shortcuts.dispose);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
      await settings.initialize();
    });

    Widget shell({AiControllers? controllers, Key? key}) => AuthenticatedApp(
      key: key,
      session: session,
      appearance: appearance,
      shortcuts: shortcuts,
      dynamicLight: const ColorScheme.light(),
      dynamicDark: const ColorScheme.dark(),
      buildInfoLoader: _buildInfo,
      ai: controllers,
    );

    await tester.pumpWidget(shell(key: const ValueKey('without-ai')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('ai-settings-row')), findsNothing);

    await tester.pumpWidget(
      shell(controllers: ai, key: const ValueKey('with-ai')),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('ai-settings-row')), findsOneWidget);
    expect(find.text('尚未設定'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-settings-row')));
    await settleNetworkWidgets(tester);
    expect(find.byType(AiSettingsPage), findsOneWidget);
  });

  testWidgets('account switch rebuilds AiScope and incoming links do not mutate providers', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final accountStore = MemoryAccountStore();
    final session = controllerFor(accountStore, fixture.adapter);
    final appearance = AppearanceController(MemoryAppearanceStore());
    final shortcuts = LauncherShortcuts(
      FakeAppShortcutHost(),
      MemoryRecentProjectStore(),
    );
    final incoming = IncomingLinks(null);
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    final ai = AiControllers(settings: settings, history: history);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    addTearDown(appearance.dispose);
    addTearDown(shortcuts.dispose);
    addTearDown(incoming.dispose);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);

    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://first.example/gitlab', 'synthetic-one');
      await session.connect('https://second.example/gitlab', 'synthetic-two');
      await settings.initialize();
    });
    final first = accountStore.accounts.first;
    final second = accountStore.accounts.last;

    await tester.pumpWidget(
      ListenableBuilder(
        listenable: session,
        builder: (context, _) => AuthenticatedApp(
          key: ValueKey(session.generation),
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          dynamicLight: const ColorScheme.light(),
          dynamicDark: const ColorScheme.dark(),
          buildInfoLoader: _buildInfo,
          incoming: incoming,
          ai: ai,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(tester.widget<AiScope>(find.byType(AiScope)).accountKey, second.key);

    incoming.offer(Uri.parse('https://second.example/gitlab/group/project'));
    await settleNetworkWidgets(tester);
    expect(settings.providers, isEmpty);

    await tester.runAsync(() => session.select(first));
    await settleNetworkWidgets(tester);
    expect(tester.widget<AiScope>(find.byType(AiScope)).accountKey, first.key);
    expect(settings.providers, isEmpty);
  });
}
