import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/memory_appearance_store.dart';
import 'support/workspace_fixture.dart';
import 'support/widget_settle.dart';

void main() {
  late MemoryAppearanceStore appearanceStore;
  late AppearanceController appearance;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    appearanceStore = MemoryAppearanceStore();
    appearance = AppearanceController(appearanceStore);
  });

  tearDown(() => appearance.dispose());

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
      AuthenticatedApp(session: session, appearance: appearance),
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
      AuthenticatedApp(session: session, appearance: appearance),
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
    expect(appearanceStore.value, 'dark');

    // Select light theme
    await tester.tap(find.text('淺色'));
    await tester.pumpAndSettle();

    final MaterialApp appLight = tester.widget(find.byType(MaterialApp));
    expect(appLight.themeMode, ThemeMode.light);
    expect(appearanceStore.value, 'light');
    expect(appearanceStore.writes, ['dark', 'light']);
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
      AuthenticatedApp(session: session, appearance: appearance),
    );
    await settleNetworkWidgets(tester);

    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
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
      AuthenticatedApp(session: session, appearance: appearance),
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
      AuthenticatedApp(session: session, appearance: appearance),
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
      AuthenticatedApp(session: session, appearance: appearance),
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
      AuthenticatedApp(session: session, appearance: appearance),
    );
    await settleNetworkWidgets(tester);

    // Navigate to My tab
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('新增或重新連接帳號'));
    await tester.pumpAndSettle();

    expect(session.active, isNull);
  });
}
