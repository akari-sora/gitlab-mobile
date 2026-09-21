import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/main.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';

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
    await store.write('account-a', const RecentProject(id: 1, name: 'Alpha'));
    shortcuts.bind('account-a');
    host.emit(ShortcutTypes.recent);
    expect(shortcuts.takeFor('account-b'), isNull);
    expect(shortcuts.pending, isNull);

    shortcuts.bind('account-a');
    host.emit(ShortcutTypes.recent);
    final own = shortcuts.takeFor('account-a');
    expect(own?.kind, ShortcutKind.recent);
    expect(own?.accountKey, 'account-a');
  });

  test('publish registers inbox, search, and the last project', () async {
    final host = FakeAppShortcutHost();
    final store = MemoryRecentProjectStore();
    final shortcuts = LauncherShortcuts(host, store);
    addTearDown(shortcuts.dispose);
    await store.write('account-a', const RecentProject(id: 9, name: 'Alpha'));
    await shortcuts.publish('account-a');
    final items = host.published.single;
    expect(items.map((item) => item.type), [
      ShortcutTypes.inbox,
      ShortcutTypes.search,
      ShortcutTypes.recent,
    ]);
    expect(items.map((item) => item.title), ['收件匣', '搜尋專案', '上次的專案']);
    expect(items.last.subtitle, 'Alpha');
    await shortcuts.rememberOpened(accountKey: 'account-a', id: 11, name: 'Beta');
    expect(await store.read('account-a'), const RecentProject(id: 11, name: 'Beta'));
    expect(host.published.last.last.subtitle, 'Beta');
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
}
