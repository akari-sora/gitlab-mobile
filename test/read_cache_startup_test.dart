import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_backend.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/main.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';

import 'session_test.dart' show EmptyReadCacheStorage, MemoryAccountStore;
import 'support/fake_adapter.dart';

Account _account(int id) => Account(
  instance: GitLabInstance.parse('https://synthetic.example/gitlab'),
  user: GitLabUser(id: id, username: 'user$id', name: 'User $id'),
  token: 'synthetic-pat-$id',
);

final class _Lease implements DiskCommitLease {
  bool _current = true;
  @override
  bool get isCurrent => _current;
  @override
  void revoke() => _current = false;
}

void Function(ReadCacheFileCheckpoint) _holdFileStage(
  ReadCacheFileCheckpoint boundary,
  SendPort events,
  String releasePath,
) => (step) {
  if (step != boundary) return;
  events.send(step.name);
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!File(releasePath).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('synthetic file-stage pause expired');
    }
    sleep(const Duration(milliseconds: 1));
  }
};

Future<void> _until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(
    condition(),
    isTrue,
    reason: 'controlled operation did not reach checkpoint',
  );
}

class _Accounts extends MemoryAccountStore {
  Completer<void>? accountsGate, markerGate, lastGate;
  bool failAccounts = false, failMarker = false, failLast = false;
  int accountsReads = 0, markerReads = 0, lastReads = 0;
  @override
  Future<List<Account>> load() async {
    accountsReads++;
    await accountsGate?.future;
    if (failAccounts) throw StateError('synthetic account read');
    return super.load();
  }

  @override
  Future<bool> loadSignOutPending() async {
    markerReads++;
    await markerGate?.future;
    if (failMarker) throw StateError('synthetic marker read');
    return super.loadSignOutPending();
  }

  @override
  Future<String?> loadLastActive() async {
    lastReads++;
    await lastGate?.future;
    if (failLast) throw StateError('synthetic last-active read');
    return super.loadLastActive();
  }
}

class _Storage extends EmptyReadCacheStorage {
  Completer<void>? settingsGate, inventoryGate, markerWriteGate;
  bool failInventory = false, failSettings = false, failDeletes = false;
  int settingsReads = 0, inventoryReads = 0, keyWrites = 0, markerWrites = 0;
  final operations = <String>[];
  @override
  Future<String?> read(String key) async {
    if (key == ReadCacheSettingsStore.key) {
      settingsReads++;
      await settingsGate?.future;
      if (failSettings) throw StateError('synthetic settings read');
    }
    return super.read(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    inventoryReads++;
    await inventoryGate?.future;
    if (failInventory) throw StateError('synthetic inventory read');
    return super.readAll();
  }

  @override
  Future<void> write(String key, String value) async {
    if (key.startsWith(ReadCacheKeyStore.keyPrefix)) keyWrites++;
    if (key.startsWith(ReadCacheKeyStore.markerPrefix)) {
      markerWrites++;
      operations.add('marker');
      await markerWriteGate?.future;
    }
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    operations.add(
      key.startsWith(ReadCacheKeyStore.keyPrefix)
          ? 'key delete'
          : 'marker delete',
    );
    if (failDeletes) throw StateError('synthetic key delete');
    await super.delete(key);
  }
}

class _Harness {
  _Harness({
    bool controls = false,
    bool configured = true,
    ReadCacheScheduler? schedule,
  }) {
    files = ReadCacheFileStore(
      root: () async {
        roots++;
        await fileGate?.future;
        if (failFiles) throw StateError('synthetic file failure');
        return root;
      },
    );
    cache = ReadCacheDiskCoordinator(
      coordinationScope: Object(),
      keys: configured ? keys : null,
      files: configured ? files : null,
      settings: configured ? ReadCacheSettingsStore(storage) : null,
      controlsInstalled: controls,
      schedule: schedule,
    );
    session = SessionController(
      accounts,
      readCache: cache,
      createApi: (instance, credential, oauth, rotated) {
        final client = GitLabApi(
          instance: instance,
          credential: credential,
          dio: Dio()
            ..httpClientAdapter = FakeAdapter((request) async {
              requests.add(request.uri.path);
              if (request.uri.path.endsWith('/user')) {
                userCalls++;
                await userGate?.future;
                if (rejectUser) {
                  return jsonResponse({
                    'message': 'synthetic 401',
                  }, status: 401);
                }
                final id =
                    responseId ??
                    switch (credential) {
                      PatCredential(:final token) =>
                        int.tryParse(token.split('-').last) ?? 1,
                      _ => 1,
                    };
                return jsonResponse({'id': id, 'username': 'user$id'});
              }
              if (lateNetwork != null) await lateNetwork!.future;
              return jsonResponse({
                'id': 7,
                'name': 'Synthetic',
                'path_with_namespace': 'synthetic/project',
              });
            }),
          oauth: oauth,
          onOAuthRotated: rotated,
        );
        clients.add(client);
        return client;
      },
    );
    addTearDown(() async {
      for (final gate in [
        accounts.accountsGate,
        accounts.markerGate,
        accounts.lastGate,
        storage.settingsGate,
        storage.inventoryGate,
        storage.markerWriteGate,
        fileGate,
        userGate,
        lateNetwork,
      ]) {
        if (gate != null && !gate.isCompleted) gate.complete();
      }
      if (!session.isDisposed) session.dispose();
      history?.dispose();
      await cache.quiesced;
      await pumpEventQueue();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  }

  final root = Directory.systemTemp.createTempSync('read-cache-startup-');
  final accounts = _Accounts();
  final storage = _Storage();
  late final keys = ReadCacheKeyStore(storage);
  late final ReadCacheFileStore files;
  late final ReadCacheDiskCoordinator cache;
  late final SessionController session;
  AiHistoryCoordinator? history;
  Completer<void>? userGate, fileGate, lateNetwork;
  bool rejectUser = false, failFiles = false;
  int? responseId;
  int roots = 0, userCalls = 0;
  final requests = <String>[];
  final clients = <GitLabApi>[];

  Future<void> start() {
    history = AiHistoryCoordinator.debugReset(
      store: MemoryAiStore(),
      files: AiHistoryFileStore(root: () async => root),
    );
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'synthetic-c2d2',
    );
    return initializeSessionWithAiRecovery(session, journal: journal);
  }

  Future<void> seed(Account account, {bool marker = false}) async {
    final key = Uint8List.fromList(List.filled(32, 17));
    await keys.writeKey(account.key, key);
    await files.writeEntry(
      ProjectedDiskEntry(
        accountKey: account.key,
        canonicalKey: 'synthetic-seed',
        cacheClass: ReadCacheDiskClass.projectMeta,
        bodyKind: ReadCacheBodyKind.json,
        fetchedAt: DateTime.now(),
        body: const {'id': 7, 'name': 'Synthetic'},
        privacyEpoch: 0,
        issueIdentities: const {},
      ),
      key,
    );
    if (marker) {
      await keys.writeMarker(
        account.key,
        ReadCacheClearMarker(
          intentId: '0123456789abcdef0123456789abcdef',
          reason: ReadCacheClearReason.scopeInvalidation,
          requestedAt: DateTime.utc(2026, 10, 27),
        ),
      );
    }
  }

  Directory directory(Account account) => Directory(
    '${root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(account.key)}',
  );

  Future<void> recovered() async {
    await _until(() => cache.startupRecovered);
    await cache.quiesced;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('issue 36 m-1 settings clear joins a completed barrier clear', () async {
    final h = _Harness(controls: true);
    final saved = _account(1);
    h.accounts.accounts = [saved];
    h.accounts.lastActive = saved.key;
    await h.start();
    await h.recovered();
    await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
    final binding = DiskBinding(
      accountKey: saved.key,
      generation: h.session.generation,
    );
    await h.session.api!.cachedRecord(['projects', '7']);
    await h.cache.flush(binding);
    final barrier = h.cache
        .invalidate(
          DiskInvalidation(
            binding: binding,
            kind: DiskInvalidationKind.mutation,
            scopeTags: {'project:7'},
          ),
        )
        .barrier;
    final clearing = h.cache.clear(
      binding,
      ReadCacheCleanupOperation.settingsClear,
    );

    expect((await barrier).complete, isTrue);
    final result = await clearing;
    expect(result.keyGoneConfirmed, isTrue);
    expect(result.directoryGoneConfirmed, isTrue);
    expect(result.complete, isTrue);
    await h.cache.quiesced;
    await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
    expect(h.cache.notice(binding), isNull);
    expect((await h.keys.readMarker(saved.key)).isFound, isFalse);
  });

  test('issue 36 m-3 expired scoped barrier does not revoke a clear', () async {
    final timers = <void Function()>[];
    void Function() schedule(Duration delay, void Function() callback) {
      var active = true;
      if (delay == ReadCacheDiskCoordinator.barrierLimit) {
        timers.add(() {
          if (active) {
            active = false;
            callback();
          }
        });
      }
      return () {
        active = false;
      };
    }

    final h = _Harness(controls: true, schedule: schedule);
    final saved = _account(1);
    h.accounts.accounts = [saved];
    h.accounts.lastActive = saved.key;
    await h.start();
    await h.recovered();
    await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
    final binding = DiskBinding(
      accountKey: saved.key,
      generation: h.session.generation,
    );
    await h.session.api!.cachedRecord(['projects', '7']);
    final roots = h.roots;
    final gate = h.fileGate = Completer<void>();
    final flushing = h.cache.flush(binding);
    await _until(() => h.roots > roots);
    final timerCount = timers.length;
    final fence = h.cache.invalidate(
      DiskInvalidation(
        binding: binding,
        kind: DiskInvalidationKind.mutation,
        scopeTags: {'project:7'},
      ),
    );
    expect(timers.length, timerCount + 1);
    final expired = expectLater(
      fence.barrier,
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.cleanup?.code,
          'cleanup code',
          ReadCacheCleanupCode.barrierTimedOut,
        ),
      ),
    );
    final clearing = h.cache.clear(
      binding,
      ReadCacheCleanupOperation.settingsClear,
    );
    timers[timerCount]();
    await expired;
    gate.complete();
    await flushing;
    final result = await clearing;
    await h.cache.quiesced;
    expect(result.complete, isTrue);
    expect(result.keyGoneConfirmed, isTrue);
    expect(result.directoryGoneConfirmed, isTrue);
    expect((await h.keys.readMarker(saved.key)).isFound, isFalse);
    expect(h.directory(saved).existsSync(), isFalse);
  });

  for (final stage in ['accounts', 'marker', 'lastActive']) {
    test('startup decision waits for $stage, not accountsLoaded', () async {
      final h = _Harness();
      final saved = _account(1);
      h.accounts.accounts = [saved];
      h.accounts.lastActive = saved.key;
      final gate = Completer<void>();
      switch (stage) {
        case 'accounts':
          h.accounts.accountsGate = gate;
        case 'marker':
          h.accounts.markerGate = gate;
        case 'lastActive':
          h.accounts.lastGate = gate;
      }
      final initialization = h.start();
      await _until(
        () => switch (stage) {
          'accounts' => h.accounts.accountsReads > 0,
          'marker' => h.accounts.markerReads > 0,
          _ => h.accounts.lastReads > 0,
        },
      );
      expect(h.session.readCacheStartupDecision, isNull);
      expect(h.cache.startupRecovered, isFalse);
      expect(h.storage.inventoryReads, 0);
      expect(h.roots, 0);
      expect(h.storage.keyWrites, 0);
      gate.complete();
      await initialization;
      await h.recovered();
      expect(h.session.readCacheStartupDecision!.readable, isTrue);
      expect(h.cache.controlsInstalled, isFalse);
      expect(h.storage.keyWrites, 0);
    });
  }

  for (final stage in ['settings', 'inventory', 'currentUser', 'D1']) {
    test('startup keeps business disk closed while $stage waits', () async {
      final h = _Harness();
      final saved = _account(1);
      h.accounts.accounts = [saved];
      h.accounts.lastActive = saved.key;
      final gate = Completer<void>();
      switch (stage) {
        case 'settings':
          h.storage.settingsGate = gate;
        case 'inventory':
          h.storage.inventoryGate = gate;
        case 'currentUser':
          h.userGate = gate;
        case 'D1':
          h.fileGate = gate;
      }
      final initialization = h.start();
      await _until(
        () => switch (stage) {
          'settings' => h.storage.settingsReads > 0,
          'inventory' => h.storage.inventoryReads > 0,
          'currentUser' => h.userCalls > 0,
          _ => h.roots > 0,
        },
      );
      expect(h.storage.keyWrites, 0);
      expect(h.cache.state(saved.key), isNot(ReadCacheDiskState.ready));
      if (stage == 'currentUser') {
        expect(h.session.api, isNull);
        expect(h.clients.single.isReadCacheBound, isFalse);
        await h.recovered(); // scan may finish before network verification
      } else {
        expect(h.cache.startupRecovered, isFalse);
      }
      gate.complete();
      await initialization;
      await h.recovered();
      expect(h.session.api!.isReadCacheBound, isTrue);
      expect(h.session.api!.readCacheGeneration, h.session.generation);
      expect(h.storage.keyWrites, 0);
    });
  }

  for (final stage in [
    'accounts',
    'marker',
    'lastActive',
    'settings',
    'inventory',
  ]) {
    test(
      'unreadable $stage stays closed without deleting retained data',
      () async {
        final h = _Harness();
        final saved = _account(1);
        h.accounts.accounts = [saved];
        h.accounts.lastActive = saved.key;
        await h.seed(saved);
        final roots = h.roots;
        switch (stage) {
          case 'accounts':
            h.accounts.failAccounts = true;
          case 'marker':
            h.accounts.failMarker = true;
          case 'lastActive':
            h.accounts.failLast = true;
          case 'settings':
            h.storage.failSettings = true;
          case 'inventory':
            h.storage.failInventory = true;
        }
        await h.start();
        await pumpEventQueue();
        expect(h.cache.startupRecovered, isFalse);
        expect(h.directory(saved).existsSync(), isTrue);
        expect((await h.keys.readKey(saved.key)).isFound, isTrue);
        expect(h.roots, roots);
        expect(h.cache.state(saved.key), isNot(ReadCacheDiskState.ready));
      },
    );
  }

  test(
    'D1 processes outside pending marker before retaining only resume account',
    () async {
      final h = _Harness();
      final saved = _account(1), other = _account(2), outside = _account(3);
      h.accounts.accounts = [saved, other];
      h.accounts.lastActive = saved.key;
      await h.seed(saved);
      await h.seed(other);
      await h.seed(outside, marker: true);
      await h.start();
      await h.recovered();
      expect(h.directory(saved).existsSync(), isTrue);
      expect(h.directory(other).existsSync(), isFalse);
      expect(h.directory(outside).existsSync(), isFalse);
      final inventory = await h.keys.readInventory();
      expect(inventory.keys.keys, [saved.key]);
      expect(inventory.markers, isEmpty);
      expect(h.storage.keyWrites, 3);
    },
  );

  test(
    'pending-clear marker acknowledgment precedes D1 and cache readiness',
    () async {
      final h = _Harness();
      final saved = _account(1), outside = _account(3);
      h.accounts.accounts = [saved];
      h.accounts.lastActive = saved.key;
      await h.seed(outside, marker: true);
      final count = h.storage.markerWrites;
      final gate = h.storage.markerWriteGate = Completer<void>();
      await h.start();
      await _until(() => h.storage.markerWrites > count);
      expect(h.cache.startupRecovered, isFalse);
      expect(h.directory(outside).existsSync(), isTrue);
      expect(h.cache.state(saved.key), isNot(ReadCacheDiskState.ready));
      gate.complete();
      await h.recovered();
      expect(h.directory(outside).existsSync(), isFalse);
      expect(h.storage.keyWrites, 1);
    },
  );

  for (final signedOut in [false, true]) {
    test(
      'D1 deletes all for ${signedOut ? 'sign-out pending' : 'setting 0'}',
      () async {
        final h = _Harness();
        final saved = _account(1);
        h.accounts.accounts = [saved];
        h.accounts.lastActive = saved.key;
        h.accounts.signOutPending = signedOut;
        if (!signedOut) h.storage.values[ReadCacheSettingsStore.key] = '0';
        await h.seed(saved);
        await h.start();
        await h.recovered();
        expect(h.directory(saved).existsSync(), isFalse);
        expect((await h.keys.readInventory()).keys, isEmpty);
        if (signedOut) expect(h.userCalls, 0);
      },
    );
  }

  for (final mismatch in [false, true]) {
    for (final resume in [false, true]) {
      test(
        'known candidate ${mismatch ? 'mismatch' : '401'} clears on ${resume ? 'initialize' : 'select'}',
        () async {
          final h = _Harness();
          final saved = _account(1);
          h.accounts.accounts = [saved];
          if (resume) h.accounts.lastActive = saved.key;
          await h.seed(saved);
          h.rejectUser = !mismatch;
          if (mismatch) h.responseId = 2;
          await h.session.initialize();
          if (!resume) await h.session.select(saved);
          await h.cache.quiesced;
          expect(h.session.active, isNull);
          expect(h.session.accounts, [saved]);
          expect(
            (await h.keys.readKey(saved.key)).status,
            ReadCacheStoreReadStatus.absent,
          );
          expect(h.directory(saved).existsSync(), isFalse);
          expect(h.requests.every((path) => path.endsWith('/user')), isTrue);
        },
      );
    }
  }

  test('unrecognized PAT 401 never guesses a saved account key', () async {
    final h = _Harness();
    final saved = _account(1);
    h.accounts.accounts = [saved];
    await h.seed(saved);
    await h.session.initialize();
    final before = Map.of(h.storage.values);
    final roots = h.roots;
    h.rejectUser = true;
    await h.session.connect(
      'https://synthetic.example/gitlab',
      'synthetic-pat-9',
    );
    await h.cache.quiesced;
    expect(h.storage.values, before);
    expect(h.roots, roots);
    expect(h.directory(saved).existsSync(), isTrue);
    expect(h.session.active, isNull);
  });

  test(
    'factory client attaches after generation and bind and really writes disk',
    () async {
      final h = _Harness(controls: true);
      await h.start();
      await h.recovered();
      await h.session.connect(
        'https://synthetic.example/gitlab',
        'synthetic-pat-1',
      );
      await h.recovered();
      final api = h.session.api!;
      final binding = DiskBinding(
        accountKey: h.session.active!.key,
        generation: h.session.generation,
      );
      await _until(
        () => h.cache.state(binding.accountKey) == ReadCacheDiskState.ready,
      );
      final result = await api.cachedRecord(['projects', '7']);
      expect(result.value['id'], 7);
      await h.cache.flush(binding);
      expect((await h.keys.readKey(binding.accountKey)).isFound, isTrue);
      expect(
        (await h.files.entryFiles(
          binding.accountKey,
          (await h.keys.readKey(binding.accountKey)).value,
        )).length,
        1,
      );
      expect(h.userCalls, 1);
    },
  );

  for (final route in ['A to B', 'A to B to A', 'same account new session']) {
    test('late network cannot publish across $route', () async {
      final h = _Harness(controls: true);
      final first = _account(1), second = _account(2);
      h.accounts.accounts = [first, second];
      h.accounts.lastActive = first.key;
      await h.start();
      await h.recovered();
      final oldApi = h.session.api!;
      final oldGeneration = h.session.generation;
      h.lateNetwork = Completer<void>();
      final pending = oldApi.cachedRecord(['projects', '7']);
      final rejected = expectLater(
        pending,
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      await _until(
        () => h.requests.any((path) => path.endsWith('/projects/7')),
      );
      if (route == 'same account new session') {
        await h.session.endSession();
        await h.session.select(first);
      } else {
        await h.session.select(second);
        if (route == 'A to B to A') await h.session.select(first);
      }
      h.lateNetwork!.complete();
      await rejected;
      await h.recovered();
      await h.cache.quiesced;
      expect(h.session.generation, greaterThan(oldGeneration));
      expect(h.session.active!.key, route == 'A to B' ? second.key : first.key);
      expect(h.session.api!.readCacheGeneration, h.session.generation);
      final key = await h.keys.readKey(first.key);
      if (key.isFound) {
        expect(await h.files.entryFiles(first.key, key.value), isEmpty);
      } else {
        expect(h.directory(first).existsSync(), isFalse);
      }
    });
  }

  test(
    'same-account activation stays closed until the old clear acknowledges',
    () async {
      final h = _Harness(controls: true);
      final saved = _account(1);
      h.accounts.accounts = [saved];
      h.accounts.lastActive = saved.key;
      await h.start();
      await h.recovered();
      await h.seed(saved);
      final gate = h.fileGate = Completer<void>();
      await h.session.endSession();
      await h.session.select(saved);
      expect(h.session.active!.key, saved.key);
      expect(h.cache.state(saved.key), isNot(ReadCacheDiskState.ready));
      final writes = h.storage.keyWrites;
      await pumpEventQueue();
      expect(h.storage.keyWrites, writes);
      gate.complete();
      await h.recovered();
      await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
    },
  );

  test('session fence revokes a flush waiting at the file stage', () async {
    final h = _Harness(controls: true);
    final saved = _account(1);
    h.accounts.accounts = [saved];
    h.accounts.lastActive = saved.key;
    await h.start();
    await h.recovered();
    await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
    await h.session.api!.cachedRecord(['projects', '7']);
    final gate = h.fileGate = Completer<void>();
    final roots = h.roots;
    final flushing = h.cache.flush(
      DiskBinding(accountKey: saved.key, generation: h.session.generation),
    );
    await _until(() => h.roots > roots);
    await h.session.endSession();
    expect(h.cache.state(saved.key), ReadCacheDiskState.cleaning);
    gate.complete();
    await flushing;
    await h.recovered();
    expect(h.directory(saved).existsSync(), isFalse);
    expect(
      (await h.keys.readKey(saved.key)).status,
      ReadCacheStoreReadStatus.absent,
    );
  });

  test(
    'sign-out fences synchronously and UI advances before cleanup I/O',
    () async {
      final h = _Harness(controls: true);
      await h.session.initialize();
      await h.session.connect(
        'https://synthetic.example/gitlab',
        'synthetic-pat-1',
      );
      final saved = h.session.active!;
      await h.seed(saved);
      final before = h.session.generation;
      final gate = h.storage.markerWriteGate = Completer<void>();
      final authGate = h.accounts.holdLastActiveWrite = Completer<void>();
      addTearDown(() {
        if (!authGate.isCompleted) authGate.complete();
      });
      final ending = h.session.endSession();
      expect(h.cache.state(saved.key), ReadCacheDiskState.cleaning);
      expect(h.session.active, isNull);
      expect(h.session.api, isNull);
      expect(h.session.generation, before + 1);
      expect(h.session.pendingSignOutCleanup, isTrue);
      gate.complete();
      authGate.complete();
      await ending;
      await h.cache.quiesced;
      expect(h.directory(saved).existsSync(), isFalse);
    },
  );

  test(
    'failed switch waits for auth cleanup before publishing empty retention',
    () async {
      final h = _Harness();
      final target = _account(2);
      h.accounts.accounts = [target];
      await h.start();
      await h.recovered();
      await h.seed(target);
      final gate = h.accounts.holdLastActiveWrite = Completer<void>();
      h.accounts.failSignOutMarker = true;
      final selecting = h.session.select(target);
      await _until(() => h.accounts.lastActiveWrites > 0);
      expect(h.session.readCacheStartupDecision, isNull);
      expect(h.session.pendingSignOutCleanup, isTrue);
      expect(h.directory(target).existsSync(), isTrue);
      gate.complete();
      await selecting;
      final decision = h.session.readCacheStartupDecision!;
      expect(decision.signOutPending, isTrue);
      expect(decision.resumeAccountKey, isNull);
      await h.recovered();
      expect(h.directory(target).existsSync(), isFalse);
      expect((await h.keys.readKey(target.key)).isFound, isFalse);
      expect(h.session.active, isNull);
    },
  );

  test('replacement controller uses a fresh process generation', () async {
    final h = _Harness(controls: true);
    final saved = _account(1);
    h.accounts.accounts = [saved];
    h.accounts.lastActive = saved.key;
    await h.start();
    await h.recovered();
    await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
    final old = DiskBinding(
      accountKey: saved.key,
      generation: h.session.generation,
    );
    h.session.dispose();
    final replacement = SessionController(
      h.accounts,
      readCache: h.cache,
      createApi: (instance, credential, oauth, rotated) => GitLabApi(
        instance: instance,
        credential: credential,
        dio: Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => jsonResponse({'id': 1, 'username': 'user1'}),
          ),
      ),
    );
    addTearDown(replacement.dispose);
    await initializeSessionWithAiRecovery(
      replacement,
      journal: AiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: h.root,
        processId: 'synthetic-replacement',
      ),
    );
    expect(replacement.generation, greaterThan(old.generation));
    await _until(
      () =>
          h.cache.startupRecovered &&
          h.cache.state(saved.key) == ReadCacheDiskState.ready,
    );
    expect(await h.cache.activate(old), isFalse);
    expect(h.cache.state(saved.key), ReadCacheDiskState.ready);
  });

  test(
    'disposing old controller preserves completed replacement recovery',
    () async {
      final h = _Harness(controls: true);
      final saved = _account(1);
      h.accounts.accounts = [saved];
      h.accounts.lastActive = saved.key;
      await h.start();
      await h.recovered();
      await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
      final oldDecision = h.session.readCacheStartupDecision!;
      final oldBinding = DiskBinding(
        accountKey: saved.key,
        generation: h.session.generation,
      );
      final replacement = SessionController(
        h.accounts,
        readCache: h.cache,
        createApi: (instance, credential, oauth, rotated) => GitLabApi(
          instance: instance,
          credential: credential,
          dio: Dio()
            ..httpClientAdapter = FakeAdapter(
              (request) => jsonResponse(
                request.uri.path.endsWith('/user')
                    ? {'id': 1, 'username': 'user1'}
                    : {
                        'id': 7,
                        'name': 'Synthetic',
                        'path_with_namespace': 'synthetic/project',
                      },
              ),
            ),
        ),
      );
      addTearDown(replacement.dispose);
      await initializeSessionWithAiRecovery(
        replacement,
        journal: AiWriteJournal(
          keys: MemoryAiJournalKeyStore(),
          applicationSupport: h.root,
          processId: 'replacement-before-dispose',
        ),
      );
      await startupRecoveryQuiescedForTesting(replacement);
      await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
      h.session.dispose();
      await pumpEventQueue();
      expect(h.cache.startupRecovered, isTrue);
      expect(h.cache.state(saved.key), ReadCacheDiskState.ready);
      expect(h.session.isReadCacheDecisionCurrent(oldDecision), isFalse);
      expect(await h.cache.activate(oldBinding), isFalse);
      final binding = DiskBinding(
        accountKey: saved.key,
        generation: replacement.generation,
      );
      expect(
        (await replacement.api!.cachedRecord(['projects', '7'])).value['id'],
        7,
      );
      await h.cache.flush(binding);
      final key = await h.keys.readKey(saved.key);
      expect(key.isFound, isTrue);
      final files = await h.files.entryFiles(saved.key, key.value);
      expect(files, hasLength(1));
      final entry = (await h.files.readEntryFile(
        saved.key,
        key.value,
        files.single,
      ))!;
      final oldBackend = CoordinatedReadCacheDiskBackend(
        coordinator: h.cache,
        binding: oldBinding,
      );
      final keyWrites = h.storage.keyWrites;
      expect(
        await oldBackend.lookup(
          DiskLookup(
            binding: oldBinding,
            canonicalKey: entry.canonicalKey,
            bodyKind: entry.bodyKind,
            lease: _Lease(),
          ),
        ),
        isNull,
      );
      oldBackend.accept(
        DiskWriteCandidate(
          binding: oldBinding,
          uri: saved.instance.api(['projects', '7']),
          logicalAccept: 'application/json',
          bodyKind: entry.bodyKind,
          fetchedAt: entry.fetchedAt,
          responseBytes: entry.bodyBytes.length,
          lease: _Lease(),
          cacheable: true,
          noStore: false,
          firstPage: true,
        ),
        entry,
      );
      expect(h.cache.stats.queuedEntries, 0);
      await h.cache.flush(oldBinding);
      expect(h.storage.keyWrites, keyWrites);
      expect(await h.files.entryFiles(saved.key, key.value), files);
      var networkReads = 0;
      final reader = GitLabApi(
        instance: saved.instance,
        credential: saved.credential,
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((_) {
            networkReads++;
            return jsonResponse({'message': 'unexpected network'}, status: 500);
          }),
      );
      addTearDown(reader.close);
      reader.bindReadCache(saved.key, replacement.generation);
      reader.attachReadCacheDiskBackend(
        CoordinatedReadCacheDiskBackend(coordinator: h.cache, binding: binding),
      );
      expect((await reader.cachedRecord(['projects', '7'])).value['id'], 7);
      expect(networkReads, 0);
      expect(await h.cache.activate(oldBinding), isFalse);
    },
  );

  test(
    'failed sign-out cleanup preserves auth bool and exact pending notice',
    () async {
      final h = _Harness();
      await h.session.initialize();
      await h.session.connect(
        'https://synthetic.example/gitlab',
        'synthetic-pat-1',
      );
      final account = h.session.active!;
      await h.seed(account);
      h.storage.failDeletes = true;
      h.failFiles = true;
      await h.session.endSession();
      await h.cache.quiesced;
      await _until(() => h.cache.signedOutNotices.isNotEmpty);
      expect(h.session.active, isNull);
      expect(h.session.pendingSignOutCleanup, isFalse);
      final failure = h.cache.signedOutNotices.single.failure;
      expect(failure.kind, FailureKind.readCacheCleanup);
      expect(failure.cleanup!.operation, ReadCacheCleanupOperation.signOut);
      expect(
        failure.cleanup!.disposition,
        ReadCacheCleanupDisposition.signedOutCleanupPending,
      );
      expect(failure.cleanup!.clearResult.complete, isFalse);
    },
  );

  for (final failure in ['both', 'key', 'directory', 'unknown', 'none']) {
    test(
      'remove commit clear retains only when neither deletion confirmed: $failure',
      () async {
        final h = _Harness(configured: failure != 'unknown');
        final saved = _account(1);
        h.accounts.accounts = [saved];
        await h.session.initialize();
        if (failure != 'unknown') await h.seed(saved);
        h.storage.failDeletes = failure == 'both' || failure == 'key';
        h.failFiles = failure == 'both' || failure == 'directory';
        final oldRoot = artifactStorageRoot;
        artifactStorageRoot = () async => h.root;
        addTearDown(() => artifactStorageRoot = oldRoot);
        await h.session.remove(saved);
        final retained = failure == 'both' || failure == 'unknown';
        expect(h.session.accounts.contains(saved), retained);
        if (retained) {
          final failure = h.cache
              .notice(DiskBinding(accountKey: saved.key, generation: 0))!
              .failure;
          expect(failure.kind, FailureKind.readCacheCleanup);
          expect(
            failure.cleanup!.operation,
            ReadCacheCleanupOperation.accountRemoval,
          );
          expect(
            failure.cleanup!.disposition,
            ReadCacheCleanupDisposition.accountRetained,
          );
        } else if (failure != 'none') {
          final cleanup = h.cache
              .notice(DiskBinding(accountKey: saved.key, generation: 0))!
              .failure
              .cleanup!;
          expect(cleanup.operation, ReadCacheCleanupOperation.accountRemoval);
          expect(cleanup.disposition, ReadCacheCleanupDisposition.diskClosed);
          expect(cleanup.code, ReadCacheCleanupCode.cleanupFailed);
          expect(cleanup.clearResult.keyGoneConfirmed, failure != 'key');
          expect(
            cleanup.clearResult.directoryGoneConfirmed,
            failure != 'directory',
          );
          expect(cleanup.clearResult.complete, isFalse);
          expect(cleanup.clearResult.markerDurable, isTrue);
          expect((await h.keys.readMarker(saved.key)).isFound, isTrue);
          expect(h.cache.state(saved.key), ReadCacheDiskState.cleaning);
        } else {
          expect(
            h.cache.notice(DiskBinding(accountKey: saved.key, generation: 0)),
            isNull,
          );
        }
      },
    );
  }

  for (final timedOut in [false, true]) {
    for (final stage in ['first clear', 'commit clear']) {
      test(
        'AAR preserves typed clear result when notice moves: $stage timeout=$timedOut',
        () async {
          final timers = <Object, void Function()>{};
          final h = _Harness(
            schedule: (delay, callback) {
              expect(delay, ReadCacheDiskCoordinator.barrierLimit);
              final key = Object();
              timers[key] = callback;
              return () => timers.remove(key);
            },
          );
          final saved = _account(1);
          h.accounts.accounts = [saved];
          await h.session.initialize();
          await h.seed(saved);
          final binding = DiskBinding(accountKey: saved.key, generation: 0);
          const moved = DiskBinding(
            accountKey: 'another-binding',
            generation: 999,
          );
          var moving = false;
          var noticesMoved = 0;
          final cancel = h.cache.subscribe((notice) {
            if (moving ||
                notice.failure.cleanup!.operation !=
                    ReadCacheCleanupOperation.accountRemoval) {
              return;
            }
            noticesMoved++;
            moving = true;
            h.cache.supersedeNotice(binding);
            h.cache.reportCleanup(moved, notice.failure.cleanup!);
            moving = false;
          });
          addTearDown(cancel);
          final oldRoot = artifactStorageRoot;
          artifactStorageRoot = () async => h.root;
          addTearDown(() => artifactStorageRoot = oldRoot);
          Completer<void>? gate;
          var blockedAfter = 0;
          void block() {
            blockedAfter = h.storage.inventoryReads;
            gate = h.storage.inventoryGate = Completer<void>();
          }

          if (stage == 'first clear' && timedOut) {
            block();
          } else if (stage == 'first clear') {
            h.storage.failDeletes = true;
            h.failFiles = true;
          }
          final journal = AiWriteJournal(
            keys: MemoryAiJournalKeyStore(),
            applicationSupport: h.root,
            processId: 'moved-removal-notice',
          );
          final job = AiAccountRemoval.begin(saved.key, journal: journal)!;
          final removal = AiAccountRemoval.run(
            account: saved,
            job: job,
            session: h.session,
            journal: journal,
            consultJournal: false,
            confirm: (_) async => true,
            waitForInFlightWrites: () async {},
            requestCancelOnDispose: () {},
            clearDrafts: (_) async {},
            clearArtifacts: (_) async {},
            clearRecent: (_) async {},
            clearAi: (_) async {
              if (timedOut) {
                block();
              } else {
                h.storage.failDeletes = true;
                h.failFiles = true;
              }
            },
          );
          if (timedOut) {
            await _until(
              () => gate != null && h.storage.inventoryReads > blockedAfter,
            );
            expect(timers, hasLength(1));
            timers.values.single();
          }
          final result = await removal;
          expect(noticesMoved, 1);
          expect(h.cache.notice(binding), isNull);
          expect(h.cache.notice(moved), isNotNull);
          expect(result.status, AiRemovalStatus.notRemoved);
          expect(
            result.reason,
            stage == 'first clear'
                ? 'beforeAiCleanupFailed'
                : 'accountRetained',
          );
          expect(result.error, isA<ApiFailure>());
          final failure = result.error! as ApiFailure;
          expect(failure.kind, FailureKind.readCacheCleanup);
          expect(
            failure.cleanup!.operation,
            ReadCacheCleanupOperation.accountRemoval,
          );
          expect(
            failure.cleanup!.disposition,
            ReadCacheCleanupDisposition.accountRetained,
          );
          expect(
            failure.cleanup!.code,
            timedOut
                ? ReadCacheCleanupCode.barrierTimedOut
                : ReadCacheCleanupCode.cleanupFailed,
          );
          expect(failure.cleanup!.clearResult.keyGoneConfirmed, isFalse);
          expect(failure.cleanup!.clearResult.directoryGoneConfirmed, isFalse);
          expect(failure.cleanup!.clearResult.markerDurable, !timedOut);
          expect(h.session.accounts, [saved]);
          expect(h.accounts.accounts, [saved]);
          if (timedOut) {
            gate!.complete();
            await h.cache.quiesced;
          }
        },
      );
    }
  }

  for (final outcome in [
    'removed',
    'AI failure',
    'save failure',
    'superseded save failure',
  ]) {
    test(
      'partial AAR removal reports final account outcome: $outcome',
      () async {
        final h = _Harness();
        final saved = _account(1);
        h.accounts.accounts = [saved];
        await h.session.initialize();
        await h.seed(saved);
        h.storage.failDeletes = true;
        final oldRoot = artifactStorageRoot;
        artifactStorageRoot = () async => h.root;
        addTearDown(() => artifactStorageRoot = oldRoot);
        final dispositions = <ReadCacheCleanupDisposition>[];
        addTearDown(
          h.cache.subscribe((notice) {
            if (notice.failure.cleanup!.operation ==
                ReadCacheCleanupOperation.accountRemoval) {
              dispositions.add(notice.failure.cleanup!.disposition);
            }
          }),
        );
        final journal = AiWriteJournal(
          keys: MemoryAiJournalKeyStore(),
          applicationSupport: h.root,
          processId: 'partial-removal-outcome',
        );
        final gate = Completer<void>();
        final saves = h.accounts.accountSaves;
        final removal = AiAccountRemoval.run(
          account: saved,
          job: AiAccountRemoval.begin(saved.key, journal: journal)!,
          session: h.session,
          journal: journal,
          consultJournal: false,
          confirm: (_) async => true,
          waitForInFlightWrites: () async {},
          requestCancelOnDispose: () {},
          clearDrafts: (_) async {},
          clearArtifacts: (_) async {},
          clearRecent: (_) async {},
          clearAi: (_) async {
            if (outcome == 'AI failure') {
              throw StateError('synthetic AI cleanup failure');
            }
            if (outcome == 'save failure') h.accounts.rejectWrite = true;
            if (outcome == 'superseded save failure') {
              h.accounts.holdAccountSave = gate;
            }
          },
        );
        if (outcome == 'superseded save failure') {
          await _until(() => h.accounts.accountSaves > saves);
          await h.session.endSession();
          h.accounts.rejectWrite = true;
          gate.complete();
        }
        final result = await removal;
        final removed = outcome == 'removed';
        expect(
          result.status,
          removed ? AiRemovalStatus.removed : AiRemovalStatus.notRemoved,
        );
        if (outcome != 'superseded save failure') {
          expect(h.session.accounts, removed ? isEmpty : [saved]);
        }
        expect(h.accounts.accounts, removed ? isEmpty : [saved]);
        final notice = h.cache.notice(
          DiskBinding(accountKey: saved.key, generation: 0),
        )!;
        expect(
          notice.failure.cleanup!.disposition,
          removed
              ? ReadCacheCleanupDisposition.diskClosed
              : ReadCacheCleanupDisposition.accountRetained,
        );
        expect(notice.failure.cleanup!.clearResult.keyGoneConfirmed, isFalse);
        expect(
          notice.failure.cleanup!.clearResult.directoryGoneConfirmed,
          isTrue,
        );
        expect(notice.failure.cleanup!.clearResult.complete, isFalse);
        expect((await h.keys.readMarker(saved.key)).isFound, isTrue);
        expect(h.cache.state(saved.key), ReadCacheDiskState.cleaning);
        if (removed) {
          expect(
            dispositions,
            isNot(contains(ReadCacheCleanupDisposition.accountRetained)),
          );
        } else {
          expect(
            dispositions.last,
            ReadCacheCleanupDisposition.accountRetained,
          );
        }
      },
    );
  }

  for (final stage in [
    'unconfigured',
    'unknown',
    'first clear',
    'commit clear',
  ]) {
    test(
      'AAR real read-cache failure retains account and typed error: $stage',
      () async {
        final h = _Harness(configured: stage != 'unconfigured');
        final saved = _account(1);
        h.accounts.accounts = [saved];
        await h.session.initialize();
        if (stage != 'unconfigured') await h.seed(saved);
        if (stage == 'unknown') h.storage.failInventory = true;
        if (stage == 'first clear' || stage == 'unknown') {
          h.storage.failDeletes = true;
          h.failFiles = true;
        }
        final oldRoot = artifactStorageRoot;
        artifactStorageRoot = () async => h.root;
        addTearDown(() => artifactStorageRoot = oldRoot);
        final journal = AiWriteJournal(
          keys: MemoryAiJournalKeyStore(),
          applicationSupport: h.root,
          processId: 'synthetic-removal',
        );
        final job = AiAccountRemoval.begin(saved.key, journal: journal)!;
        final calls = <String>[];
        final result = await AiAccountRemoval.run(
          account: saved,
          job: job,
          session: h.session,
          journal: journal,
          consultJournal: false,
          confirm: (_) async => true,
          waitForInFlightWrites: () async {},
          requestCancelOnDispose: () {},
          clearDrafts: (_) async {},
          clearArtifacts: (_) async {},
          clearRecent: (_) async {},
          clearAi: (_) async {
            calls.add('AI cleanup');
            h.storage.failDeletes = true;
            h.failFiles = true;
          },
        );
        expect(result.status, AiRemovalStatus.notRemoved);
        expect(
          result.reason,
          stage == 'commit clear' ? 'accountRetained' : 'beforeAiCleanupFailed',
        );
        expect(
          result.dataState,
          stage == 'commit clear'
              ? AiRemovalDataState.cleared
              : AiRemovalDataState.untouched,
        );
        expect(calls, stage == 'commit clear' ? ['AI cleanup'] : isEmpty);
        expect(h.session.accounts, [saved]);
        expect(h.accounts.accounts, [saved]);
        final error = result.error! as ApiFailure;
        expect(error.kind, FailureKind.readCacheCleanup);
        expect(
          error.cleanup!.operation,
          ReadCacheCleanupOperation.accountRemoval,
        );
        expect(
          error.cleanup!.disposition,
          ReadCacheCleanupDisposition.accountRetained,
        );
        expect(error.cleanup!.clearResult.keyGoneConfirmed, isFalse);
        expect(error.cleanup!.clearResult.directoryGoneConfirmed, isFalse);
      },
    );
  }

  test(
    'disposing sign-out cancels its deadline but keeps native cleanup owned',
    () async {
      final timers = <Object, void Function()>{};
      void Function() schedule(Duration delay, void Function() callback) {
        final key = Object();
        timers[key] = callback;
        return () => timers.remove(key);
      }

      final h = _Harness(controls: true, schedule: schedule);
      final saved = _account(1);
      h.accounts.accounts = [saved];
      h.accounts.lastActive = saved.key;
      await h.start();
      await h.recovered();
      await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
      await h.seed(saved);
      final binding = DiskBinding(
        accountKey: saved.key,
        generation: h.session.generation,
      );
      final roots = h.roots;
      final gate = h.fileGate = Completer<void>();
      await h.session.endSession();
      await _until(() => h.roots > roots);
      expect(h.session.active, isNull);
      expect(timers, hasLength(1));
      var quiesced = false;
      unawaited(h.cache.quiesced.then((_) => quiesced = true));
      // An accepted removal's deadline is process-owned, even for this binding.
      final removal = h.cache.clear(
        binding,
        ReadCacheCleanupOperation.accountRemoval,
      );
      expect(timers, hasLength(2));
      final transport = h.cache.invalidate(
        DiskInvalidation(binding: binding, kind: DiskInvalidationKind.account),
      );
      expect(timers, hasLength(3));
      // Even identical candidate bindings (including generation 0) can belong to
      // different controllers. Releasing one must leave the other's timer live.
      final otherOwner = Object();
      final otherClear = h.cache.clear(
        binding,
        ReadCacheCleanupOperation.signOut,
        sessionOwner: otherOwner,
      );
      expect(timers, hasLength(4));
      h.session.dispose();
      expect(timers, hasLength(3));
      await pumpEventQueue();
      expect(quiesced, isFalse);
      final failure = h.cache.signedOutNotices.single.failure;
      expect(failure.kind, FailureKind.readCacheCleanup);
      expect(failure.cleanup!.operation, ReadCacheCleanupOperation.signOut);
      expect(
        failure.cleanup!.disposition,
        ReadCacheCleanupDisposition.signedOutCleanupPending,
      );
      expect(failure.cleanup!.code, ReadCacheCleanupCode.cleanupFailed);
      expect(failure.cleanup!.clearResult.complete, isFalse);
      expect(h.cache.state(saved.key), ReadCacheDiskState.cleaning);
      gate.complete();
      await h.cache.quiesced;
      await removal;
      await transport.barrier;
      await otherClear;
      await pumpEventQueue();
      expect(timers, isEmpty);
      expect(quiesced, isTrue);
      expect(h.directory(saved).existsSync(), isFalse);
      expect((await h.keys.readKey(saved.key)).isFound, isFalse);
      expect(await h.cache.activate(binding), isFalse);
    },
  );

  test('provably empty removal does not create a marker', () async {
    final h = _Harness();
    final saved = _account(1);
    h.accounts.accounts = [saved];
    await h.session.initialize();
    final oldRoot = artifactStorageRoot;
    artifactStorageRoot = () async => h.root;
    addTearDown(() => artifactStorageRoot = oldRoot);
    await h.session.remove(saved);
    expect(h.session.accounts, isEmpty);
    expect(h.storage.markerWrites, 0);
    expect(h.storage.keyWrites, 0);
  });

  test(
    'a new PAT for a known account verifies identity before rebinding',
    () async {
      final h = _Harness(controls: true);
      final saved = _account(1);
      h.accounts.accounts = [saved];
      h.accounts.lastActive = saved.key;
      await h.start();
      await h.recovered();
      await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
      await h.seed(saved);
      final generation = h.session.generation;
      await h.session.connect(
        'https://synthetic.example/gitlab',
        'replacement-pat-1',
      );
      await h.recovered();
      await _until(() => h.cache.state(saved.key) == ReadCacheDiskState.ready);
      expect(h.userCalls, 2);
      expect(h.session.accounts, hasLength(1));
      expect(h.session.active!.key, saved.key);
      expect(h.session.generation, greaterThan(generation));
      expect(h.session.api!.readCacheGeneration, h.session.generation);
      expect(h.directory(saved).existsSync(), isFalse);
      final replacementKey = await h.keys.readKey(saved.key);
      expect(replacementKey.isFound, isTrue);
      expect(
        replacementKey.value,
        isNot(orderedEquals(List<int>.filled(32, 17))),
      );
      await h.session.api!.cachedRecord(['projects', '7']);
      await h.cache.flush(
        DiskBinding(accountKey: saved.key, generation: h.session.generation),
      );
      final key = await h.keys.readKey(saved.key);
      expect(key.isFound, isTrue);
      expect(await h.files.entryFiles(saved.key, key.value), hasLength(1));
    },
  );

  for (final route in ['A to B', 'A to B to A', 'same account new session']) {
    for (final boundary in [
      ReadCacheFileCheckpoint.beforeRead,
      ReadCacheFileCheckpoint.temporaryFlushed,
      ReadCacheFileCheckpoint.beforeEntryRename,
      ReadCacheFileCheckpoint.beforeIndexRename,
    ]) {
      test('late ${boundary.name} cannot publish across $route', () async {
        final h = _Harness(controls: true);
        final first = _account(1), second = _account(2);
        h.accounts.accounts = [first, second];
        h.accounts.lastActive = first.key;
        await h.start();
        await h.recovered();
        await _until(
          () => h.cache.state(first.key) == ReadCacheDiskState.ready,
        );
        final oldApi = h.session.api!;
        final oldBinding = DiskBinding(
          accountKey: first.key,
          generation: h.session.generation,
        );
        await oldApi.cachedRecord(['projects', '7']);
        final reading = boundary == ReadCacheFileCheckpoint.beforeRead;
        if (reading) {
          await h.cache.flush(oldBinding);
          oldApi.clearReadCache();
        }
        final events = ReceivePort();
        final messages = StreamIterator<Object?>(events);
        final release = File('${h.root.path}/release');
        addTearDown(() async {
          if (!release.existsSync()) release.createSync();
          await messages.cancel();
          events.close();
        });
        h.cache.configure(
          keys: h.keys,
          files: ReadCacheFileStore(
            root: () async => h.root,
            checkpoint: _holdFileStage(boundary, events.sendPort, release.path),
          ),
          settings: ReadCacheSettingsStore(h.storage),
        );
        final Future<void> pending;
        if (reading) {
          pending = expectLater(
            oldApi.cachedRecord(['projects', '7']),
            throwsA(
              isA<ApiFailure>().having(
                (error) => error.kind,
                'kind',
                FailureKind.cancelled,
              ),
            ),
          );
        } else {
          pending = h.cache.flush(oldBinding);
        }
        expect(
          await messages.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        expect(messages.current, boundary.name);
        if (route == 'same account new session') {
          await h.session.endSession();
          await h.session.select(first);
        } else {
          await h.session.select(second);
          if (route == 'A to B to A') await h.session.select(first);
        }
        expect(h.session.generation, greaterThan(oldBinding.generation));
        expect(
          h.session.active!.key,
          route == 'A to B' ? second.key : first.key,
        );
        expect(h.session.api!.readCacheGeneration, h.session.generation);
        release.createSync();
        await pending;
        await h.cache.quiesced;
        await h.recovered();
        final key = await h.keys.readKey(first.key);
        if (key.isFound) {
          expect(await h.files.entryFiles(first.key, key.value), isEmpty);
        } else {
          expect(h.directory(first).existsSync(), isFalse);
        }
      });
    }
  }
}
