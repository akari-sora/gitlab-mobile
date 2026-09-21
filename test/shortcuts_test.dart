import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/main.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

void main() {
  test('SecureRecentProjectStore round-trips and clears one account', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = SecureRecentProjectStore();
    const first = RecentProject(id: 3, name: 'Mobile');
    const second = RecentProject(id: 4, name: 'Other');
    await store.write('https://example.com#7', first);
    await store.write('https://example.com#8', second);
    expect(await store.read('https://example.com#7'), first);
    expect(await store.read('https://example.com#8'), second);
    await store.clear('https://example.com#7');
    expect(await store.read('https://example.com#7'), isNull);
    expect(await store.read('https://example.com#8'), second);
    expect(await store.read('missing'), isNull);
  });

  test('a corrupt recent-project record is ignored', () async {
    FlutterSecureStorage.setMockInitialValues({
      SecureRecentProjectStore.storageKey('acct'): '{',
    });
    expect(await SecureRecentProjectStore().read('acct'), isNull);
  });

  test('a recent shortcut bound to another account is ignored', () async {
    final host = FakeAppShortcutHost();
    final store = MemoryRecentProjectStore();
    final shortcuts = LauncherShortcuts(host, store);
    addTearDown(shortcuts.dispose);
    await shortcuts.start();
    shortcuts.bind('account-a');
    await store.write('account-a', const RecentProject(id: 1, name: 'Alpha'));
    await shortcuts.publish('account-a');
    final type = host.published.single.last.type;
    expect(type, recentShortcutType('account-a', 1));

    host.emit(ShortcutTypes.recent);
    expect(shortcuts.pending, isNull, reason: 'A recent shortcut without a token is rejected');
    expect(shortcuts.takeFor('account-a'), isNull);

    host.emit(type);
    expect(shortcuts.takeFor('account-b'), isNull);
    expect(shortcuts.pending, isNull);

    host.emit(type);
    final own = shortcuts.takeFor('account-a');
    expect(own?.kind, ShortcutKind.recent);
    expect(own?.projectId, 1);
    expect(own?.accountKey, isNull);
  });

  test('publish registers inbox, search, and the last project', () async {
    final host = FakeAppShortcutHost();
    final store = MemoryRecentProjectStore();
    final shortcuts = LauncherShortcuts(host, store);
    addTearDown(shortcuts.dispose);
    shortcuts.bind('account-a');
    await store.write('account-a', const RecentProject(id: 9, name: 'Alpha'));
    await shortcuts.publish('account-a');
    final items = host.published.single;
    expect(items.map((item) => item.type), [
      ShortcutTypes.inbox,
      ShortcutTypes.search,
      recentShortcutType('account-a', 9),
    ]);
    expect(items.map((item) => item.title), ['收件匣', '搜尋專案', '上次的專案']);
    expect(items.last.subtitle, 'Alpha');
    await shortcuts.rememberOpened(accountKey: 'account-a', id: 11, name: 'Beta');
    expect(await store.read('account-a'), const RecentProject(id: 11, name: 'Beta'));
    expect(host.published.last.last.subtitle, 'Beta');
    expect(host.published.last.last.type, recentShortcutType('account-a', 11));
  });

  test('a delayed read does not publish a previous account', () async {
    final host = FakeAppShortcutHost();
    final store = MemoryRecentProjectStore();
    final readGate = Completer<void>();
    store.readDelay = readGate.future;
    await store.write('account-a', const RecentProject(id: 1, name: 'Alpha'));
    await store.write('account-b', const RecentProject(id: 2, name: 'Beta'));
    final shortcuts = LauncherShortcuts(host, store);
    addTearDown(shortcuts.dispose);
    shortcuts.bind('account-a');
    final first = shortcuts.publish('account-a');
    await Future<void>.delayed(Duration.zero);
    shortcuts.bind('account-b');
    final second = shortcuts.publish('account-b');
    readGate.complete();
    store.readDelay = null;
    await first;
    await second;
    expect(host.published, hasLength(1));
    expect(host.published.single.last.subtitle, 'Beta');
    expect(host.published.single.last.type, recentShortcutType('account-b', 2));
  });

  test('a delayed rememberOpened does not republish after an account switch', () async {
    final host = FakeAppShortcutHost();
    final store = MemoryRecentProjectStore();
    final writeGate = Completer<void>();
    store.writeDelay = writeGate.future;
    final shortcuts = LauncherShortcuts(host, store);
    addTearDown(shortcuts.dispose);
    shortcuts.bind('account-a');
    final remembered = shortcuts.rememberOpened(accountKey: 'account-a', id: 5, name: 'Late');
    await Future<void>.delayed(Duration.zero);
    shortcuts.bind('account-b');
    writeGate.complete();
    await remembered;
    expect(await store.read('account-a'), const RecentProject(id: 5, name: 'Late'));
    expect(host.published, isEmpty);
  });

  test('sign-out wins over an in-flight setItems', () async {
    final host = FakeAppShortcutHost();
    final store = MemoryRecentProjectStore();
    final gate = Completer<void>();
    host.setItemsDelay = gate.future;
    await store.write('account-a', const RecentProject(id: 1, name: 'Alpha'));
    final shortcuts = LauncherShortcuts(host, store);
    addTearDown(shortcuts.dispose);
    await shortcuts.start();
    shortcuts.bind('account-a');
    host.emit(ShortcutTypes.inbox);
    expect(shortcuts.pending?.kind, ShortcutKind.inbox);
    final publishing = shortcuts.publish('account-a');
    await Future<void>.delayed(Duration.zero);
    shortcuts.bind(null);
    expect(shortcuts.pending, isNull);
    final clearing = shortcuts.clearPublished();
    gate.complete();
    await publishing;
    await clearing;
    expect(host.clears, 1);
    expect(host.published.last, isEmpty);
    shortcuts.bind('account-b');
    expect(shortcuts.takeFor('account-b'), isNull);
  });

  test('a cold-start pinned recent shortcut keeps its published account', () async {
    final host = FakeAppShortcutHost();
    final store = MemoryRecentProjectStore();
    final first = LauncherShortcuts(host, store);
    first.bind('account-a');
    await store.write('account-a', const RecentProject(id: 9, name: 'Alpha'));
    await first.publish('account-a');
    final type = host.published.single.last.type;
    await first.clearPublished();
    first.dispose();

    final cold = LauncherShortcuts(host, store);
    addTearDown(cold.dispose);
    await cold.start();
    cold.bind(null);
    host.emit(type);
    expect(cold.takeFor('account-b'), isNull);
    host.emit(type);
    cold.bind('account-a');
    final own = cold.takeFor('account-a');
    expect(own?.kind, ShortcutKind.recent);
    expect(own?.projectId, 9);
  });

  test('an inbox shortcut tapped while signed out is kept for the next sign-in', () async {
    final host = FakeAppShortcutHost();
    final shortcuts = LauncherShortcuts(host, MemoryRecentProjectStore());
    addTearDown(shortcuts.dispose);
    await shortcuts.start();
    shortcuts.bind(null);
    host.emit(ShortcutTypes.inbox);
    shortcuts.bind('account-a');
    expect(shortcuts.takeFor('account-a')?.kind, ShortcutKind.inbox);
  });

  testWidgets('a pending inbox shortcut selects the Inbox tab after sign-in', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final host = FakeAppShortcutHost();
    final shortcuts = LauncherShortcuts(host, MemoryRecentProjectStore());
    addTearDown(shortcuts.dispose);
    final adapter = FakeAdapter((request) => request.uri.path.endsWith('/user')
        ? jsonResponse({'id': 7, 'username': 'tester', 'name': 'Tester'})
        : jsonResponse([]));
    final session = controllerFor(MemoryAccountStore(), adapter);
    addTearDown(session.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(session),
        launcherShortcutsProvider.overrideWithValue(shortcuts),
      ],
      child: const GitLabMobileApp(),
    ));
    await tester.pumpAndSettle();
    host.emit(ShortcutTypes.inbox);
    await tester.runAsync(() => session.connect('https://example.com', 'synthetic-test-token'));
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
    expect(find.text('待辦'), findsOneWidget);
    expect(host.published, isNotEmpty);
    expect(host.published.last.map((item) => item.title), ['收件匣', '搜尋專案', '上次的專案']);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('search shortcut pops a covered route and focuses project search', (tester) async {
    final harness = await _signedInShell(tester);
    addTearDown(harness.dispose);
    await tester.tap(find.text('Mobile Workspace'));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsOneWidget);

    harness.host.emit(ShortcutTypes.search);
    await settleNetworkWidgets(tester);

    expect(find.byType(ProjectPage), findsNothing);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
    expect(tester.widget<TextField>(find.byKey(const Key('projectSearch'))).focusNode?.hasFocus, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('a guarded route stays up and does not focus covered search', (tester) async {
    final harness = await _signedInShell(tester);
    addTearDown(harness.dispose);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const PopScope<void>(
      canPop: false,
      child: Scaffold(body: Text('guarded-editor')),
    ))));
    await tester.pumpAndSettle();
    expect(find.text('guarded-editor'), findsOneWidget);

    harness.host.emit(ShortcutTypes.search);
    await settleNetworkWidgets(tester);

    expect(find.text('guarded-editor'), findsOneWidget);
    final search = find.byKey(const Key('projectSearch'), skipOffstage: false);
    expect(search, findsOneWidget);
    expect(tester.widget<TextField>(search).focusNode?.hasFocus, isFalse);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('recent shortcut requests that project and offers 404 recovery', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = await _signedInShell(tester, recentId: 9, recentName: 'Hidden');
    addTearDown(harness.dispose);
    await settleNetworkWidgets(tester);
    final type = harness.host.published.last.last.type;
    expect(type, recentShortcutType(harness.session.active!.key, 9));

    await tester.tap(find.text('Mobile Workspace'));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsOneWidget);

    harness.host.emit(type);
    await settleNetworkWidgets(tester);

    expect(find.byType(ProjectPage), findsNothing);
    final gets = harness.fixture.adapter.requests.where(
      (request) => request.method == 'GET' && request.uri.path.endsWith('/projects/9'),
    );
    expect(gets, isNotEmpty);
    expect(find.text('目標：9'), findsOneWidget);
    expect(find.text('實例：https://example.com/gitlab'), findsOneWidget);
    expect(find.text('App 帳號：@developer'), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    final before = gets.length;
    await tester.tap(find.text('重新整理'));
    await settleNetworkWidgets(tester);
    expect(harness.fixture.adapter.requests.where(
      (request) => request.method == 'GET' && request.uri.path.endsWith('/projects/9'),
    ).length, greaterThan(before));
    expect(find.text('目標：9'), findsOneWidget);

    await tester.tap(find.text('切換帳號'));
    await tester.pumpAndSettle();
    expect(harness.session.active, isNull);
    expect(find.text('目標：9'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

final class _ShellHarness {
  _ShellHarness(this.fixture, this.session, this.host, this.shortcuts, this.appearance);
  final WorkspaceFixture fixture;
  final SessionController session;
  final FakeAppShortcutHost host;
  final LauncherShortcuts shortcuts;
  final AppearanceController appearance;
  Future<void> dispose() async {
    appearance.dispose();
    shortcuts.dispose();
    session.dispose();
    fixture.api.close();
  }
}

Future<_ShellHarness> _signedInShell(WidgetTester tester, {int? recentId, String? recentName}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final fixture = WorkspaceFixture();
  final session = controllerFor(MemoryAccountStore(), fixture.adapter);
  await tester.runAsync(() async {
    await session.initialize();
    await session.connect('https://example.com/gitlab', 'synthetic-test-token');
  });
  final store = MemoryRecentProjectStore();
  if (recentId != null) {
    await store.write(session.active!.key, RecentProject(id: recentId, name: recentName ?? 'Recent'));
  }
  final host = FakeAppShortcutHost();
  final shortcuts = LauncherShortcuts(host, store);
  await shortcuts.start();
  shortcuts.bind(session.active!.key);
  final appearance = AppearanceController(MemoryAppearanceStore());
  await tester.pumpWidget(AuthenticatedApp(
    session: session,
    appearance: appearance,
    shortcuts: shortcuts,
  ));
  await settleNetworkWidgets(tester);
  return _ShellHarness(fixture, session, host, shortcuts, appearance);
}
