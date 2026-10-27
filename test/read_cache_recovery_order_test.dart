import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/main.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';

import 'session_test.dart' show MemoryAccountStore;

final class _CacheStorage implements ReadCacheSecureStorage {
  _CacheStorage(this.events, {this.hold = false, this.fail = false, this.logEach = false});
  final List<String> events;
  final bool hold, fail, logEach;
  final entered = Completer<void>();
  final release = Completer<void>();
  final values = <String, String>{};
  bool first = true;
  int reads = 0;

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<Map<String, String>> readAll() async {
    reads++;
    final scan = reads;
    if (logEach) events.add('cache-scan-$scan');
    if (first) {
      first = false;
      events.add('cache-start');
      entered.complete();
      if (hold) await release.future;
      events.add('cache-end');
      if (fail) throw StateError('synthetic inventory failure');
    }
    if (logEach) events.add('cache-scan-end-$scan');
    return Map.of(values);
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

final class _BlockedMarkerStore extends MemoryAccountStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> loadSignOutPending() async {
    entered.complete();
    await release.future;
    return false;
  }
}

final class _RepeatBlockedMarkerStore extends MemoryAccountStore {
  int reads = 0;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> loadSignOutPending() async {
    reads++;
    if (reads == 2) {
      entered.complete();
      await release.future;
    }
    return false;
  }
}

final class _FailingCacheStorage extends _CacheStorage {
  _FailingCacheStorage(super.events);
  int attempts = 0;

  @override
  Future<Map<String, String>> readAll() async {
    attempts++;
    events.add('cache-failed-$attempts');
    throw StateError('synthetic inventory failure');
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this.callback);
  final void Function() callback;
  bool active = true;
  @override
  void cancel() => active = false;
  @override
  bool get isActive => active;
  @override
  int get tick => active ? 0 : 1;
  void fire() {
    if (!active) return;
    active = false;
    callback();
  }
}

Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

final class _HistoryStore implements AiStore, AiStoreSecureInventory {
  _HistoryStore(this.events, {this.hold = false, this.fail = false});
  final List<String> events;
  final bool hold, fail;
  final entered = Completer<void>();
  final release = Completer<void>();
  final memory = MemoryAiStore();

  @override
  Future<AiTombstoneInventory> readTombstoneInventory() async {
    events.add('history-start');
    if (!entered.isCompleted) entered.complete();
    if (hold) await release.future;
    events.add('history-end');
    if (fail) throw StateError('synthetic history failure');
    return memory.readTombstoneInventory();
  }

  @override
  Future<AiSecureInventory> readSecureInventory() =>
      memory.readSecureInventory();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _JournalStore extends MemoryAiJournalKeyStore {
  _JournalStore(this.events);
  final List<String> events;
  final entered = Completer<void>();
  @override
  Future<Set<String>> inventoryAccounts() async {
    events.add('journal-start');
    if (!entered.isCompleted) entered.complete();
    return super.inventoryAccounts();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'timeout retains gate until cache acknowledges; AI scans stay serial',
    () async {
      final root = Directory.systemTemp.createTempSync('read-cache-order-');
      final events = <String>[];
      final storage = _CacheStorage(events, hold: true);
      final cache = ReadCacheDiskCoordinator(
        keys: ReadCacheKeyStore(storage),
        files: ReadCacheFileStore(root: () async => root),
        settings: ReadCacheSettingsStore(storage),
        coordinationScope: Object(),
      );
      final session = SessionController(MemoryAccountStore(), readCache: cache);
      final historyStore = _HistoryStore(events, hold: true);
      final history = AiHistoryCoordinator.debugReset(
        store: historyStore,
        files: AiHistoryFileStore(root: () async => root),
      );
      final journalStore = _JournalStore(events);
      final journal = AiWriteJournal(
        keys: journalStore,
        applicationSupport: root,
        processId: 'synthetic-order',
      );
      addTearDown(() async {
        if (!storage.release.isCompleted) storage.release.complete();
        if (!historyStore.release.isCompleted) historyStore.release.complete();
        session.dispose();
        history.dispose();
        await cache.quiesced;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      await initializeSessionWithAiRecovery(
        session,
        journal: journal,
        recoveryTimeout: const Duration(milliseconds: 50),
      );
      await storage.entered.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final notice = cache.notice(
        const DiskBinding(accountKey: '', generation: 0),
      );
      expect(
        notice?.failure.cleanup?.code,
        ReadCacheCleanupCode.barrierTimedOut,
      );
      expect(
        notice?.failure.cleanup?.disposition,
        ReadCacheCleanupDisposition.diskClosed,
      );
      expect(cache.startupRecovered, isFalse);
      expect(historyStore.entered.isCompleted, isFalse);
      expect(journalStore.entered.isCompleted, isFalse);

      storage.release.complete();
      await historyStore.entered.future.timeout(const Duration(seconds: 5));
      expect(journalStore.entered.isCompleted, isFalse);
      expect(events, ['cache-start', 'cache-end', 'history-start']);
      historyStore.release.complete();
      await journalStore.entered.future.timeout(const Duration(seconds: 5));
      expect(events, [
        'cache-start',
        'cache-end',
        'history-start',
        'history-end',
        'journal-start',
      ]);
    },
  );

  test('successful recovery runs cache, history, then journal', () async {
    final root = Directory.systemTemp.createTempSync('read-cache-success-');
    final events = <String>[];
    final storage = _CacheStorage(events);
    final cache = ReadCacheDiskCoordinator(
      keys: ReadCacheKeyStore(storage),
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
    );
    final session = SessionController(MemoryAccountStore(), readCache: cache);
    final history = AiHistoryCoordinator.debugReset(
      store: _HistoryStore(events),
      files: AiHistoryFileStore(root: () async => root),
    );
    final journalStore = _JournalStore(events);
    final journal = AiWriteJournal(
      keys: journalStore,
      applicationSupport: root,
      processId: 'synthetic-success',
    );
    addTearDown(() async {
      session.dispose();
      history.dispose();
      await cache.quiesced;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await initializeSessionWithAiRecovery(session, journal: journal);
    await journalStore.entered.future.timeout(const Duration(seconds: 5));
    expect(events, [
      'cache-start',
      'cache-end',
      'history-start',
      'history-end',
      'journal-start',
    ]);
    expect(cache.startupRecovered, isTrue);
  });

  test('failed scans retry at 1, 5, and 30 seconds outside the gate', () async {
    final root = Directory.systemTemp.createTempSync('read-cache-retry-');
    final events = <String>[];
    final storage = _FailingCacheStorage(events);
    final cache = ReadCacheDiskCoordinator(
      keys: ReadCacheKeyStore(storage),
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
    );
    final session = SessionController(MemoryAccountStore(), readCache: cache);
    final history = AiHistoryCoordinator.debugReset(
      store: _HistoryStore(events),
      files: AiHistoryFileStore(root: () async => root),
    );
    final journalStore = _JournalStore(events);
    final journal = AiWriteJournal(
      keys: journalStore,
      applicationSupport: root,
      processId: 'synthetic-retry',
    );
    final timers = <Duration, List<_ManualTimer>>{};
    addTearDown(() async {
      if (!session.isDisposed) session.dispose();
      history.dispose();
      await cache.quiesced;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await runZoned(
      () async {
        await initializeSessionWithAiRecovery(session, journal: journal);
        await _eventually(
          () =>
              journalStore.entered.isCompleted &&
              (timers[const Duration(seconds: 1)]?.any((t) => t.isActive) ??
                  false),
        );
        expect(storage.attempts, 1);
        for (final seconds in [1, 5, 30]) {
          final duration = Duration(seconds: seconds);
          await _eventually(
            () => timers[duration]?.any((t) => t.isActive) ?? false,
          );
          timers[duration]!.firstWhere((t) => t.isActive).fire();
          final expected = seconds == 1
              ? 2
              : seconds == 5
              ? 3
              : 4;
          await _eventually(() => storage.attempts >= expected);
          // Let the failed recovery complete and schedule the next retry.
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(storage.attempts, 4);
        await _eventually(
          () =>
              timers[const Duration(seconds: 30)]?.any((t) => t.isActive) ??
              false,
        );
        session.dispose();
        await pumpEventQueue();
        expect(
          timers.values
              .expand((timers) => timers)
              .any((timer) => timer.isActive),
          isFalse,
        );
        expect(
          events.indexOf('journal-start'),
          lessThan(events.indexOf('cache-failed-2')),
        );
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(seconds: 1) ||
              duration == const Duration(seconds: 5) ||
              duration == const Duration(seconds: 30)) {
            final timer = _ManualTimer(() => zone.runGuarded(callback));
            timers.putIfAbsent(duration, () => []).add(timer);
            return timer;
          }
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
  });

  test('a changed membership is rescanned after the blocked scan', () async {
    final root = Directory.systemTemp.createTempSync('read-cache-members-');
    final events = <String>[];
    final storage = _CacheStorage(events, hold: true, logEach: true);
    final cache = ReadCacheDiskCoordinator(
      keys: ReadCacheKeyStore(storage),
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
    );
    final accountStore = MemoryAccountStore();
    final session = SessionController(accountStore, readCache: cache);
    final history = AiHistoryCoordinator.debugReset(
      store: _HistoryStore(events),
      files: AiHistoryFileStore(root: () async => root),
    );
    final journalStore = _JournalStore(events);
    final journal = AiWriteJournal(
      keys: journalStore,
      applicationSupport: root,
      processId: 'synthetic-members',
    );
    addTearDown(() async {
      if (!storage.release.isCompleted) storage.release.complete();
      session.dispose();
      history.dispose();
      await cache.quiesced;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await initializeSessionWithAiRecovery(session, journal: journal);
    await storage.entered.future.timeout(const Duration(seconds: 5));
    final previous = session.readCacheStartupDecision;
    final account = Account(
      instance: GitLabInstance.parse('https://synthetic.example'),
      user: const GitLabUser(id: 7, username: 'synthetic', name: 'Synthetic'),
      token: 'synthetic-token',
    );
    accountStore.accounts = [account];
    await session.initialize();
    expect(session.accounts.map((a) => a.key), [account.key]);
    expect(session.isReadCacheDecisionCurrent(previous!), isFalse);
    storage.release.complete();
    await _eventually(() => storage.reads >= 2 && cache.startupRecovered);
    await journalStore.entered.future.timeout(const Duration(seconds: 5));
    expect(events.indexOf('cache-scan-end-2'), lessThan(events.indexOf('history-start')));
    expect(events.indexOf('cache-scan-end-2'), lessThan(events.indexOf('journal-start')));
    expect(
      session.isReadCacheDecisionCurrent(session.readCacheStartupDecision!),
      isTrue,
    );
  });

  test('repeat initialization waits for its marker and cache scan before AI', () async {
    final root = Directory.systemTemp.createTempSync('read-cache-repeat-');
    final events = <String>[];
    final storage = _CacheStorage(events, logEach: true);
    final cache = ReadCacheDiskCoordinator(
      keys: ReadCacheKeyStore(storage),
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
    );
    final accountStore = _RepeatBlockedMarkerStore();
    final session = SessionController(accountStore, readCache: cache);
    final history = AiHistoryCoordinator.debugReset(
      store: _HistoryStore(events),
      files: AiHistoryFileStore(root: () async => root),
    );
    final firstJournalStore = _JournalStore(events);
    final firstJournal = AiWriteJournal(
      keys: firstJournalStore, applicationSupport: root, processId: 'repeat-first',
    );
    final secondJournalStore = _JournalStore(events);
    final secondJournal = AiWriteJournal(
      keys: secondJournalStore, applicationSupport: root, processId: 'repeat-second',
    );
    addTearDown(() async {
      if (!accountStore.release.isCompleted) accountStore.release.complete();
      session.dispose();
      history.dispose();
      await cache.quiesced;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await initializeSessionWithAiRecovery(session, journal: firstJournal);
    await firstJournalStore.entered.future.timeout(const Duration(seconds: 5));
    events.clear();
    final repeat = initializeSessionWithAiRecovery(session, journal: secondJournal);
    await accountStore.entered.future.timeout(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(events, isEmpty);
    expect(secondJournalStore.entered.isCompleted, isFalse);
    accountStore.release.complete();
    await repeat;
    await secondJournalStore.entered.future.timeout(const Duration(seconds: 5));
    final scans = events.where((event) => event.startsWith('cache-scan-end-')).toList();
    expect(scans, isNotEmpty);
    final lastScan = events.indexOf(scans.last);
    expect(lastScan, lessThan(events.indexOf('history-start')));
    expect(lastScan, lessThan(events.indexOf('journal-start')));
  });

  test(
    'disposing while the startup decision is pending prevents recovery',
    () async {
      final root = Directory.systemTemp.createTempSync('read-cache-dispose-');
      final events = <String>[];
      final storage = _CacheStorage(events);
      final cache = ReadCacheDiskCoordinator(
        keys: ReadCacheKeyStore(storage),
        files: ReadCacheFileStore(root: () async => root),
        settings: ReadCacheSettingsStore(storage),
        coordinationScope: Object(),
      );
      final accountStore = _BlockedMarkerStore();
      final session = SessionController(accountStore, readCache: cache);
      final history = AiHistoryCoordinator.debugReset(
        store: _HistoryStore(events),
        files: AiHistoryFileStore(root: () async => root),
      );
      final journalStore = _JournalStore(events);
      final journal = AiWriteJournal(
        keys: journalStore,
        applicationSupport: root,
        processId: 'synthetic-dispose',
      );
      addTearDown(() async {
        if (!accountStore.release.isCompleted) accountStore.release.complete();
        if (!session.isDisposed) session.dispose();
        history.dispose();
        await cache.quiesced;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final initialization = initializeSessionWithAiRecovery(
        session,
        journal: journal,
      );
      await accountStore.entered.future;
      session.dispose();
      accountStore.release.complete();
      await initialization;
      await pumpEventQueue();
      expect(events, isEmpty);
    },
  );

  test(
    'failed removal restores membership and reopens the history fence',
    () async {
      final root = Directory.systemTemp.createTempSync('read-cache-restore-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      final events = <String>[];
      final storage = _CacheStorage(events);
      final cache = ReadCacheDiskCoordinator(
        keys: ReadCacheKeyStore(storage),
        files: ReadCacheFileStore(root: () async => root),
        settings: ReadCacheSettingsStore(storage),
        coordinationScope: Object(),
      );
      final account = Account(
        instance: GitLabInstance.parse('https://synthetic.example'),
        user: const GitLabUser(id: 7, username: 'synthetic', name: 'Synthetic'),
        token: 'synthetic-token',
      );
      final accountStore = MemoryAccountStore()..accounts = [account];
      final session = SessionController(accountStore, readCache: cache);
      final historyStore = MemoryAiStore();
      final history = AiHistoryCoordinator.debugReset(
        store: historyStore,
        files: AiHistoryFileStore(root: () async => root),
      );
      final journalStore = _JournalStore(events);
      final journal = AiWriteJournal(
        keys: journalStore,
        applicationSupport: root,
        processId: 'synthetic-restore',
      );
      addTearDown(() async {
        artifactStorageRoot = previousRoot;
        session.dispose();
        history.dispose();
        await cache.quiesced;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      await initializeSessionWithAiRecovery(session, journal: journal);
      await journalStore.entered.future.timeout(const Duration(seconds: 5));
      await history.load(account.key);
      final mutations = AiAccountMutationCoordinator.forStore(historyStore);
      mutations.beginCleaning(account.key);
      expect(mutations.isCleaning(account.key), isTrue);
      accountStore.rejectWrite = true;
      await session.remove(account);
      expect(session.accounts.map((a) => a.key), [account.key]);
      expect(session.message, isNotNull);
      expect(mutations.isCleaning(account.key), isFalse);
    },
  );

  test('cache and history failures do not skip the journal', () async {
    final root = Directory.systemTemp.createTempSync('read-cache-errors-');
    final events = <String>[];
    final storage = _CacheStorage(events, fail: true);
    final cache = ReadCacheDiskCoordinator(
      keys: ReadCacheKeyStore(storage),
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
    );
    final session = SessionController(MemoryAccountStore(), readCache: cache);
    final historyStore = _HistoryStore(events, fail: true);
    final history = AiHistoryCoordinator.debugReset(
      store: historyStore,
      files: AiHistoryFileStore(root: () async => root),
    );
    final journalStore = _JournalStore(events);
    final journal = AiWriteJournal(
      keys: journalStore,
      applicationSupport: root,
      processId: 'synthetic-errors',
    );
    addTearDown(() async {
      session.dispose();
      history.dispose();
      await cache.quiesced;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await initializeSessionWithAiRecovery(session, journal: journal);
    await journalStore.entered.future.timeout(const Duration(seconds: 5));
    expect(events, [
      'cache-start',
      'cache-end',
      'history-start',
      'history-end',
      'journal-start',
    ]);
    expect(cache.startupRecovered, isFalse);
    final notice = cache.notice(
      const DiskBinding(accountKey: '', generation: 0),
    );
    expect(notice?.failure.cleanup?.code, ReadCacheCleanupCode.cleanupFailed);
    expect(cache.controlsInstalled, isFalse);
  });
  testWidgets('unmount cancels startup timeout while retaining native recovery fence', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('read-cache-unmount-');
    final events = <String>[];
    final storage = _CacheStorage(events, hold: true);
    final cache = ReadCacheDiskCoordinator(
      keys: ReadCacheKeyStore(storage),
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
    );
    final session = SessionController(MemoryAccountStore(), readCache: cache);
    final history = AiHistoryCoordinator.debugReset(
      store: MemoryAiStore(),
      files: AiHistoryFileStore(root: () async => root),
    );
    addTearDown(() {
      if (!storage.release.isCompleted) storage.release.complete();
      session.dispose();
      history.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    Widget app() => ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: const GitLabMobileApp(),
    );
    await tester.pumpWidget(app());
    for (var i = 0; i < 100 && !storage.entered.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(storage.entered.isCompleted, isTrue);
    final oldDecision = session.readCacheStartupDecision;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    expect(session.isDisposed, isFalse);
    expect(cache.notice(const DiskBinding(accountKey: '', generation: 0)), isNull);
    expect(cache.startupRecovered, isFalse);

    await tester.pumpWidget(app());
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(session.isReadCacheDecisionCurrent(oldDecision!), isFalse);
    expect(storage.reads, 1, reason: 'the replacement scan waits for native acknowledgment');
    storage.release.complete();
    for (var i = 0; i < 100 && !cache.startupRecovered; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(storage.reads, greaterThanOrEqualTo(2));
    expect(cache.startupRecovered, isTrue);
    await tester.pumpWidget(const SizedBox());
    // A synthetic follower proves the shared FIFO has drained in this widget
    // test's clock before another test creates work in a different clock.
    final probeRoot = Directory.systemTemp.createTempSync('read-cache-drain-');
    final probeStorage = _CacheStorage(<String>[]);
    final probeCache = ReadCacheDiskCoordinator(
      keys: ReadCacheKeyStore(probeStorage),
      files: ReadCacheFileStore(root: () async => probeRoot),
      settings: ReadCacheSettingsStore(probeStorage),
      coordinationScope: Object(),
    );
    final probeAccount = Account(
      instance: GitLabInstance.parse('https://synthetic.example'),
      user: const GitLabUser(id: 42, username: 'probe', name: 'Probe'),
      token: 'synthetic-token',
    );
    final probe = SessionController(
      MemoryAccountStore()..accounts = [probeAccount], readCache: probeCache,
    );
    final probeStore = _JournalStore(<String>[]);
    final probeJournal = AiWriteJournal(
      keys: probeStore, applicationSupport: probeRoot, processId: 'fifo-drain',
    );
    unawaited(initializeSessionWithAiRecovery(probe, journal: probeJournal));
    for (var i = 0; i < 200 && !probeJournal.recovered(probeAccount.key); i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(probeJournal.recovered(probeAccount.key), isTrue);
    for (var i = 0; i < 10; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    probe.dispose();
    await tester.pump();
    if (probeRoot.existsSync()) probeRoot.deleteSync(recursive: true);
    expect(tester.takeException(), isNull);
  
    Future<void> checkLifecycle() async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('read-cache-lifecycle-');
    final events = <String>[];
    final storage = _CacheStorage(events);
    final cache = ReadCacheDiskCoordinator(
      keys: ReadCacheKeyStore(storage),
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
      controlsInstalled: true,
    );
    final session = SessionController(MemoryAccountStore(), readCache: cache);
    final history = AiHistoryCoordinator.debugReset(
      store: MemoryAiStore(),
      files: AiHistoryFileStore(root: () async => root),
    );
    addTearDown(() async {
      session.dispose();
      history.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: const GitLabMobileApp(),
      ),
    );
    for (var i = 0; i < 100 && !cache.startupRecovered; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(cache.startupRecovered, isTrue);
    const binding = DiskBinding(accountKey: 'synthetic', generation: 1);
    Future<bool> activate() async {
      bool? result;
      unawaited(cache.activate(binding).then((value) => result = value));
      for (var i = 0; i < 100 && result == null; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(result, isNotNull);
      return result!;
    }

    expect(await activate(), isTrue);
    expect(cache.state(binding.accountKey), ReadCacheDiskState.ready);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(cache.state(binding.accountKey), ReadCacheDiskState.closed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(await activate(), isTrue);
    expect(cache.state(binding.accountKey), ReadCacheDiskState.ready);
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(cache.state(binding.accountKey), ReadCacheDiskState.ready);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var quiesced = false;
    unawaited(cache.quiesced.then((_) => quiesced = true));
    for (var i = 0; i < 100 && !quiesced; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(quiesced, isTrue);
    expect(tester.takeException(), isNull);

    }
    await checkLifecycle();
  });

}
