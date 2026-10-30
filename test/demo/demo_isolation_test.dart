// Entering and leaving the demo from the real sign-in screen leaves the
// device's session, account store, secure storage, recent projects, launcher,
// appearance and read-cache coordinator exactly as they were.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/demo/demo_runtime.dart';
import 'package:gitlab_mobile/features/demo/demo_scope.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/main.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/fake_shortcuts.dart';
import '../support/memory_appearance_store.dart';
import '../support/shell_nav.dart';
import '../support/widget_settle.dart';
import 'demo_test_support.dart';

final class _CountingRecentStore extends MemoryRecentProjectStore {
  int changes = 0;

  @override
  Future<void> touch(String accountKey, RecentProject project) {
    changes++;
    return super.touch(accountKey, project);
  }

  @override
  Future<void> clear(String accountKey) {
    changes++;
    return super.clear(accountKey);
  }
}

void main() {
  late RecordingSecureValues secure;

  setUp(() async {
    secure = recordSecureStorage();
    AiHistoryCoordinator.debugReset(store: MemoryAiStore());
    // As in app_smoke_test: configure the journal singleton outside a
    // widget's disposable fake zone.
    final sessionStore = MemoryAccountStore();
    final session = SessionController(
      sessionStore,
      readCache: sessionStore.readCache,
    );
    await session.initialize();
    await startAiWriteJournal(session);
    session.dispose();
  });

  testWidgets('entering and leaving the demo changes nothing on the device', (
    tester,
  ) async {
    phoneView(tester);
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final store = MemoryAccountStore();
    final session = controllerFor(store, adapter);
    addTearDown(session.dispose);
    final host = FakeAppShortcutHost();
    final recent = _CountingRecentStore();
    final shortcuts = LauncherShortcuts(host, recent);
    addTearDown(shortcuts.dispose);
    final appearanceStore = MemoryAppearanceStore('dark|0');
    final appearance = AppearanceController(appearanceStore);
    addTearDown(appearance.dispose);
    // Whoever holds the process-wide read cache's startup session keeps it.
    final startupOwner = Object();
    ReadCacheDiskCoordinator.instance.claimStartupSession(startupOwner);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(session),
          launcherShortcutsProvider.overrideWithValue(shortcuts),
          appearanceProvider.overrideWithValue(appearance),
        ],
        child: const GitLabMobileApp(),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.byKey(const Key('instanceField')), findsOneWidget);
    final generation = session.generation;
    final secureBefore = List.of(secure.changes);
    final appearanceWrites = appearanceStore.writes.length;
    final published = host.published.length;

    await tester.tap(find.byKey(const Key('tryDemoButton')));
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('demo-banner')).evaluate().isNotEmpty,
      description: 'the demo shell',
    );
    await settleNetworkWidgets(tester);

    // The demo is a session of its own on the demo host.
    final scope = tester.element(find.byKey(const ValueKey('demo-banner')));
    expect(DemoScope.maybeOf(scope), isNotNull);
    expect(find.text('Pocket Planner'), findsWidgets);

    // Open a project, which a real account would record as recent.
    await tester.tap(find.text('Pocket Planner').first);
    await settleNetworkWidgets(tester, maxCycles: 30);
    expect(
      find.textContaining('This repository is sample data'),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await settleNetworkWidgets(tester);

    // 我的 has no accounts, AI settings or storage rows, only the way out.
    await tapDestination(tester, '我的');
    expect(find.text(l10n.removeAccountFromDevice), findsNothing);
    expect(find.text(l10n.addOrReconnectAccount), findsNothing);
    expect(find.text(l10n.storageAndCacheLabel), findsNothing);
    expect(find.byKey(const ValueKey('ai-settings-row')), findsNothing);
    expect(find.byKey(const ValueKey('language-row')), findsNothing);
    expect(find.byKey(const ValueKey('app-lock-switch')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('demo-exit-row')));
    await pumpUntil(
      tester,
      () => find.byKey(const Key('instanceField')).evaluate().isNotEmpty,
      description: 'back on the sign-in screen',
    );
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('demo-banner')), findsNothing);

    // Nothing about the device changed.
    expect(secure.changes, secureBefore, reason: 'no secure-storage write');
    expect(store.accounts, isEmpty);
    expect(store.accountSaves, 0);
    expect(store.lastActiveWrites, 0);
    expect(store.signOutPending, isFalse);
    expect(session.active, isNull);
    expect(session.api, isNull);
    expect(session.accounts, isEmpty);
    expect(session.generation, generation);
    expect(session.readCache.ownsStartupSession(session), isTrue);
    expect(
      ReadCacheDiskCoordinator.instance.ownsStartupSession(startupOwner),
      isTrue,
    );
    expect(recent.changes, 0);
    expect(recent.values, isEmpty);
    expect(host.published.length, published);
    expect(appearanceStore.writes.length, appearanceWrites);
    expect(
      adapter.requests,
      isEmpty,
      reason: 'the demo never used the real client',
    );
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a demo session owns a private, unconfigured read cache', () async {
    final startupOwner = Object();
    ReadCacheDiskCoordinator.instance.claimStartupSession(startupOwner);
    final demo = await DemoRuntime.start(ai: false);
    addTearDown(demo.dispose);
    final cache = demo.session.readCache;
    expect(identical(cache, ReadCacheDiskCoordinator.instance), isFalse);
    expect(cache.configured, isFalse);
    expect(
      cache.offlineRepository,
      isNull,
      reason: 'offline saving is unavailable',
    );
    expect(cache.ownsStartupSession(demo.session), isTrue);
    expect(
      ReadCacheDiskCoordinator.instance.ownsStartupSession(startupOwner),
      isTrue,
    );
    expect(demo.offline.configured, isFalse);
    expect(isDemoAccount(demo.account), isTrue);
    expect(demo.session.active, same(demo.account));
  });
}
