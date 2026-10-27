import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';

import 'session_test.dart' show MemoryAccountStore;

const _account = 'https://synthetic.example/subpath#17';
const _other = 'https://synthetic.example/subpath#18';
const _outside = 'https://synthetic.example/subpath#19';
const _binding = DiskBinding(accountKey: _account, generation: 1);

final class _MemoryStorage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  final calls = <String>[];
  Future<void> Function(String operation, String name)? intercept;
  bool failInventory = false;
  bool failMarkerWrite = false;
  bool failMarkerRead = false;
  bool mismatchMarkerRead = false;
  bool failMarkerDelete = false;
  bool failKeyDelete = false;
  bool failKeyRead = false;
  int keyWrites = 0;
  int markerWrites = 0;

  @override
  Future<String?> read(String key) async {
    calls.add('read:$key');
    await intercept?.call('read', key);
    if (key.startsWith(ReadCacheKeyStore.keyPrefix) && failKeyRead) {
      throw StateError('synthetic storage failure');
    }
    if (key.startsWith(ReadCacheKeyStore.markerPrefix)) {
      if (failMarkerRead) throw StateError('synthetic storage failure');
      if (mismatchMarkerRead && values.containsKey(key)) return 'mismatch';
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    calls.add('write:$key');
    await intercept?.call('write', key);
    if (key.startsWith(ReadCacheKeyStore.keyPrefix)) keyWrites++;
    if (key.startsWith(ReadCacheKeyStore.markerPrefix)) {
      markerWrites++;
      if (failMarkerWrite) throw StateError('synthetic storage failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    calls.add('delete:$key');
    await intercept?.call('delete', key);
    if (key.startsWith(ReadCacheKeyStore.keyPrefix) && failKeyDelete) {
      throw StateError('synthetic storage failure');
    }
    if (key.startsWith(ReadCacheKeyStore.markerPrefix) && failMarkerDelete) {
      throw StateError('synthetic storage failure');
    }
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    calls.add('readAll');
    await intercept?.call('inventory', '');
    if (failInventory) throw StateError('synthetic storage failure');
    return Map.of(values);
  }
}

final class _Scheduled {
  _Scheduled(this.at, this.callback);
  final DateTime at;
  final void Function() callback;
  bool cancelled = false;
}

final class _FakeClock {
  DateTime now = DateTime.utc(2026, 10, 27);
  final pending = <_Scheduled>[];
  void Function() schedule(Duration delay, void Function() callback) {
    final item = _Scheduled(now.add(delay), callback);
    pending.add(item);
    return () => item.cancelled = true;
  }

  void advance(Duration duration) {
    now = now.add(duration);
    for (final item in List<_Scheduled>.of(pending)) {
      if (!item.cancelled && !item.at.isAfter(now)) {
        item.cancelled = true;
        item.callback();
      }
    }
    pending.removeWhere((item) => item.cancelled);
  }
}

final class _Harness {
  _Harness() {
    root = Directory.systemTemp.createTempSync('read-cache-coordinator-');
    keys = ReadCacheKeyStore(storage);
    files = ReadCacheFileStore(
      root: () async {
        rootCalls++;
        if (failRoot) throw StateError('synthetic root failure');
        return root;
      },
      clock: () => clock.now,
    );
    settings = ReadCacheSettingsStore(storage);
    coordinator = wrapper();
  }

  late final Directory root;
  final scope = Object();
  final storage = _MemoryStorage();
  final clock = _FakeClock();
  late final ReadCacheKeyStore keys;
  late final ReadCacheFileStore files;
  late final ReadCacheSettingsStore settings;
  late final ReadCacheDiskCoordinator coordinator;
  bool failRoot = false;
  int rootCalls = 0;

  ReadCacheDiskCoordinator wrapper() => ReadCacheDiskCoordinator(
    keys: ReadCacheKeyStore(storage),
    files: files,
    settings: ReadCacheSettingsStore(storage),
    coordinationScope: scope,
    controlsInstalled: true,
    clock: () => clock.now,
    schedule: clock.schedule,
  );

  Directory dir([String account = _account]) => Directory(
    '${root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(account)}',
  );

  void seedFile([String account = _account]) {
    final directory = dir(account)..createSync(recursive: true);
    File('${directory.path}/synthetic.bin').writeAsBytesSync([1, 2, 3]);
  }

  Future<void> seedKey([String account = _account]) =>
      keys.writeKey(account, Uint8List.fromList(List.generate(32, (i) => i)));

  Future<bool> recover({
    bool readable = true,
    bool signedOut = false,
    String? resume = _account,
    Set<String> accounts = const {_account, _other},
  }) => coordinator.recover(
    ReadCacheStartupDecision(
      operationTicket: 1,
      accountListRevision: 1,
      accountsReadable: readable,
      signOutMarkerReadable: true,
      lastActiveReadable: true,
      signOutPending: signedOut,
      resumeAccountKey: resume,
    ),
    accountKeys: accounts,
  );

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _Lease implements DiskCommitLease {
  bool current = true;
  @override
  bool get isCurrent => current;
  @override
  void revoke() => current = false;
}

ProjectedDiskEntry _entry(
  _Harness h,
  int id, {
  int? serializedBytes,
  Set<String> scopes = const {'project:1'},
  Set<ReadCacheIssueIdentity> issues = const {},
  bool pinned = false,
  String? path,
}) {
  ProjectedDiskEntry make(String body) => ProjectedDiskEntry(
    accountKey: _account,
    canonicalKey: jsonEncode([
      _account,
      'GET',
      path ?? '/api/v4/projects/1/items/$id',
      <Object>[],
      'text/plain',
    ]),
    cacheClass: pinned ? ReadCacheDiskClass.pinned : ReadCacheDiskClass.detail,
    bodyKind: ReadCacheBodyKind.text,
    fetchedAt: h.clock.now,
    body: body,
    privacyEpoch: 0,
    issueIdentities: issues,
    scopeTags: scopes,
  );
  final base = make('');
  return serializedBytes == null
      ? make('synthetic-$id')
      : make('x' * (serializedBytes - base.serializedLength));
}

DiskWriteCandidate _candidate(ProjectedDiskEntry entry, [_Lease? lease]) =>
    DiskWriteCandidate(
      binding: _binding,
      uri: Uri.parse('https://synthetic.example/subpath/api/v4/projects/1'),
      logicalAccept: 'text/plain',
      bodyKind: entry.bodyKind,
      fetchedAt: entry.fetchedAt,
      responseBytes: entry.serializedLength,
      lease: lease ?? _Lease(),
      cacheable: true,
      noStore: false,
      firstPage: true,
      scopeTags: entry.scopeTags,
    );

Future<void> _readyHarness(_Harness h) async {
  expect(await h.recover(), isTrue);
  expect(await h.coordinator.activate(_binding), isTrue);
}

Future<void> _save(_Harness h, ProjectedDiskEntry entry) async {
  h.coordinator.accept(_candidate(entry), entry);
  await h.coordinator.flush(_binding);
}

ReadCacheDiskCoordinator _fresh(_Harness h) => ReadCacheDiskCoordinator(
  keys: h.keys,
  files: h.files,
  settings: h.settings,
  coordinationScope: Object(),
  controlsInstalled: true,
  clock: () => h.clock.now,
  schedule: h.clock.schedule,
);

const _decision = ReadCacheStartupDecision(
  operationTicket: 1,
  accountListRevision: 1,
  accountsReadable: true,
  signOutMarkerReadable: true,
  lastActiveReadable: true,
  signOutPending: false,
  resumeAccountKey: _account,
);

void Function(ReadCacheFileCheckpoint) _pauseAt(
  ReadCacheFileCheckpoint boundary,
  SendPort events,
  String release,
) => (step) {
  if (step != boundary) return;
  events.send(step.name);
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!File(release).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('synthetic pause expired');
    }
    sleep(const Duration(milliseconds: 1));
  }
};

void Function(ReadCacheFileCheckpoint) _crashAt(
  ReadCacheFileCheckpoint boundary,
) => (step) {
  if (step == boundary) throw StateError('synthetic crash');
};

void _transactionTests() {
  _markerOrderTests();
  test(
    'production gates require controls, recovery, verified activation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final c = ReadCacheDiskCoordinator(
        keys: h.keys,
        files: h.files,
        settings: h.settings,
        coordinationScope: Object(),
        clock: () => h.clock.now,
        schedule: h.clock.schedule,
      );
      expect(await c.activate(_binding), isFalse);
      expect(await c.recover(_decision, accountKeys: {_account}), isTrue);
      expect(h.storage.keyWrites, 0);
      final entry = _entry(h, 1);
      c.accept(_candidate(entry), entry);
      await c.flush(_binding);
      expect(h.storage.keyWrites, 0);
      expect(h.dir().existsSync(), isFalse);
      c.installUserControls();
      expect(await c.activate(_binding), isTrue);
      expect(h.storage.keyWrites, 1);
    },
  );

  test(
    'unavailable settings does not sweep or treat unknown as disabled',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.seedFile();
      h.storage.values[ReadCacheSettingsStore.key] = 'invalid';
      expect(await h.recover(), isFalse);
      expect(await h.coordinator.activate(_binding), isFalse);
      expect(h.rootCalls, 0);
      expect(h.dir().existsSync(), isTrue);
    },
  );

  test(
    'queue commits at 32 entries or 2 seconds, never at 31 or 1999ms',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      for (var i = 0; i < 31; i++) {
        final e = _entry(h, i);
        h.coordinator.accept(_candidate(e), e);
      }
      await h.coordinator.quiesced;
      expect(h.coordinator.stats.queuedEntries, 31);
      expect(h.dir().existsSync(), isFalse);
      h.clock.advance(const Duration(milliseconds: 1999));
      await h.coordinator.quiesced;
      expect(h.dir().existsSync(), isFalse);
      final e = _entry(h, 31);
      h.coordinator.accept(_candidate(e), e);
      await h.coordinator.quiesced;
      final key = (await h.keys.readKey(_account)).value!;
      expect((await h.files.readIndex(_account, key))!.entries, hasLength(32));
      final next = _entry(h, 32);
      h.coordinator.accept(_candidate(next), next);
      h.clock.advance(const Duration(milliseconds: 1999));
      await h.coordinator.quiesced;
      expect((await h.files.readIndex(_account, key))!.entries, hasLength(32));
      h.clock.advance(const Duration(milliseconds: 1));
      await h.coordinator.quiesced;
      expect((await h.files.readIndex(_account, key))!.entries, hasLength(33));
    },
  );

  test(
    'queue exact 2MiB uses serialized metadata and drops oldest FIFO over limit',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final a = _entry(h, 1, serializedBytes: 1024 * 1024);
      final b = _entry(h, 2, serializedBytes: 1024 * 1024);
      expect(a.serializedLength + b.serializedLength, 2 * 1024 * 1024);
      h.coordinator.accept(_candidate(a), a);
      h.coordinator.accept(_candidate(b), b);
      expect(h.coordinator.stats.queuedBytes, 2 * 1024 * 1024);
      expect(h.coordinator.stats.dropped, 0);
      final c = _entry(h, 3);
      h.coordinator.accept(_candidate(c), c);
      expect(h.coordinator.stats.queuedEntries, 2);
      expect(h.coordinator.stats.dropped, 1);
      await h.coordinator.flush(_binding);
      final key = (await h.keys.readKey(_account)).value!;
      expect(await h.files.readEntry(_account, key, a.canonicalKey), isNull);
      expect(await h.files.readEntry(_account, key, b.canonicalKey), isNotNull);
      expect(await h.files.readEntry(_account, key, c.canonicalKey), isNotNull);
      final tooLarge = _entry(h, 4, serializedBytes: 1024 * 1024 + 1);
      h.coordinator.accept(_candidate(tooLarge), tooLarge);
      expect(h.coordinator.stats.dropped, 2);
      expect(h.coordinator.stats.queuedBytes, 0);
    },
  );

  test(
    'background drops without flush; resume revalidates settings and key',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final e = _entry(h, 1);
      h.coordinator.accept(_candidate(e), e);
      h.coordinator.background();
      h.clock.advance(const Duration(seconds: 3));
      await h.coordinator.quiesced;
      expect(h.coordinator.stats.queuedEntries, 0);
      expect(h.dir().existsSync(), isFalse);
      h.storage.failKeyRead = true;
      final roots = h.rootCalls;
      expect(await h.coordinator.resume(_binding), isFalse);
      expect(h.rootCalls, roots);
      h.storage.failKeyRead = false;
      expect(await h.coordinator.resume(_binding), isTrue);
      await _save(h, _entry(h, 2));
      expect(h.dir().existsSync(), isTrue);
    },
  );

  test(
    'unavailable key retries at 1, 5, 30 seconds without file actions',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await h.recover(), isTrue);
      h.storage.failKeyRead = true;
      final roots = h.rootCalls;
      expect(await h.coordinator.activate(_binding), isFalse);
      int reads() => h.storage.calls
          .where((s) => s == 'read:${ReadCacheKeyStore.keyName(_account)}')
          .length;
      expect(reads(), 1);
      for (final seconds in [1, 5, 30]) {
        h.clock.advance(Duration(seconds: seconds));
        await h.coordinator.quiesced;
      }
      expect(reads(), 4);
      expect(h.rootCalls, roots);
      expect(h.storage.keyWrites, 0);
      h.clock.advance(const Duration(seconds: 60));
      await h.coordinator.quiesced;
      expect(reads(), 4);
      h.storage.failKeyRead = false;
      expect(await h.coordinator.resume(_binding), isTrue);
    },
  );

  for (final index in [false, true]) {
    test(
      'coordinator lease forbids late ${index ? 'index' : 'entry'} rename',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        final events = ReceivePort();
        final messages = StreamIterator<Object?>(events);
        final release = File('${h.root.path}/release');
        addTearDown(events.close);
        final boundary = index
            ? ReadCacheFileCheckpoint.beforeIndexRename
            : ReadCacheFileCheckpoint.beforeEntryRename;
        final paused = ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _pauseAt(boundary, events.sendPort, release.path),
        );
        h.coordinator.configure(
          keys: h.keys,
          files: paused,
          settings: h.settings,
        );
        final e = _entry(h, 1);
        h.coordinator.accept(_candidate(e), e);
        final write = h.coordinator.flush(_binding);
        expect(
          await messages.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        expect(messages.current, boundary.name);
        h.coordinator.revoke(_binding);
        release.createSync();
        await write;
        await messages.cancel();
        final key = (await h.keys.readKey(_account)).value!;
        final name = await const ReadCacheCipher().entryFileName(
          key,
          e.canonicalKey,
        );
        expect(
          File('${h.dir().path}/${index ? 'index.v1.bin' : name}').existsSync(),
          isFalse,
        );
        expect(
          h.dir().listSync().where((f) => f.path.endsWith('.tmp')),
          isEmpty,
        );
        final newFiles = ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
        );
        expect(
          index
              ? await newFiles.readIndex(_account, key)
              : await newFiles.readEntry(_account, key, e.canonicalKey),
          isNull,
        );
      },
    );
  }

  test(
    'scope invalidation removes queued and in-flight matches but preserves pinned',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final original = _entry(h, 0);
      final pinned = _entry(h, 5, pinned: true);
      await _save(h, original);
      await _save(h, pinned);
      final pending = _entry(h, 2);
      h.coordinator.accept(_candidate(pending), pending);
      final events = ReceivePort();
      addTearDown(events.close);
      final stream = StreamIterator<Object?>(events);
      final release = File('${h.root.path}/release');
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _pauseAt(
            ReadCacheFileCheckpoint.beforeEntryRename,
            events.sendPort,
            release.path,
          ),
        ),
      );
      final write = h.coordinator.flush(_binding);
      expect(
        await stream.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      final queued = _entry(h, 3);
      h.coordinator.accept(_candidate(queued), queued);
      final fence = h.coordinator.invalidate(
        DiskInvalidation(
          binding: _binding,
          kind: DiskInvalidationKind.mutation,
          scopeTags: {'project:1'},
        ),
      );
      release.createSync();
      await write;
      final proof = await fence.barrier;
      await fence.quiesced;
      await stream.cancel();
      expect(
        proof.complete,
        isFalse,
      ); // Scoped success truthfully retains a key.
      expect(h.coordinator.notice(_binding), isNull);
      final key = (await h.keys.readKey(_account)).value!;
      for (final e in [original, pending, queued]) {
        expect(await h.files.readEntry(_account, key, e.canonicalKey), isNull);
      }
      expect(
        await h.files.readEntry(_account, key, pinned.canonicalKey),
        isNotNull,
      );
    },
  );

  test(
    'privacy after entry rename revokes old index and deletes cross-scope identities',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      const issue = ReadCacheIssueIdentity(1, 7);
      final linked = _entry(h, 0, scopes: {'userLists'}, issues: {issue});
      final group = _entry(h, 1, scopes: {'group:4'}, issues: {issue});
      final list = _entry(h, 2, path: '/api/v4/projects/1/issues');
      final unrelated = _entry(h, 3, scopes: {'project:9'});
      for (final e in [linked, group, list, unrelated]) {
        await _save(h, e);
      }
      final events = ReceivePort();
      addTearDown(events.close);
      final stream = StreamIterator<Object?>(events);
      final release = File('${h.root.path}/release');
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _pauseAt(
            ReadCacheFileCheckpoint.beforeIndexRename,
            events.sendPort,
            release.path,
          ),
        ),
      );
      final renamed = _entry(h, 4, issues: {issue});
      h.coordinator.accept(_candidate(renamed), renamed);
      final write = h.coordinator.flush(_binding);
      expect(
        await stream.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      final fence = h.coordinator.invalidate(
        DiskInvalidation(
          binding: _binding,
          kind: DiskInvalidationKind.privacy,
          issueIdentities: {issue},
        ),
      );
      release.createSync();
      await write;
      await fence.barrier;
      await fence.quiesced;
      await stream.cancel();
      final key = (await h.keys.readKey(_account)).value!;
      for (final e in [linked, group, list, renamed]) {
        expect(await h.files.readEntry(_account, key, e.canonicalKey), isNull);
      }
      expect(
        await h.files.readEntry(_account, key, unrelated.canonicalKey),
        isNotNull,
      );
      expect((await h.files.readIndex(_account, key))!.entries, hasLength(1));
    },
  );

  test('concurrent scope barriers reuse one durable marker', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _readyHarness(h);
    await _save(h, _entry(h, 1));
    await _save(h, _entry(h, 2, scopes: {'project:2'}));
    final a = h.coordinator.invalidate(
      DiskInvalidation(
        binding: _binding,
        kind: DiskInvalidationKind.mutation,
        scopeTags: {'project:1'},
      ),
    );
    final b = h.coordinator.invalidate(
      DiskInvalidation(
        binding: _binding,
        kind: DiskInvalidationKind.mutation,
        scopeTags: {'project:2'},
      ),
    );
    await Future.wait([a.barrier, b.barrier]);
    expect(h.storage.markerWrites, 1);
    expect(
      (await h.keys.readMarker(_account)).status,
      ReadCacheStoreReadStatus.absent,
    );
  });

  test(
    'scope completion cannot delete a superseding account-clear marker',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      final atRead = Completer<void>();
      final release = Completer<void>();
      var reads = 0;
      h.storage.intercept = (operation, name) async {
        if (operation == 'read' &&
            name == ReadCacheKeyStore.markerName(_account) &&
            ++reads == 3) {
          atRead.complete();
          await release.future;
        }
      };
      final scope = h.coordinator.invalidate(
        DiskInvalidation(
          binding: _binding,
          kind: DiskInvalidationKind.mutation,
          scopeTags: {'project:1'},
        ),
      );
      final scopeFailure = expectLater(
        scope.barrier,
        throwsA(
          isA<ApiFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.readCacheCleanup,
          ),
        ),
      );
      await atRead.future.timeout(const Duration(seconds: 10));
      h.storage.failKeyDelete = true;
      h.failRoot = true;
      final full = h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.signOut,
      );
      release.complete();
      await scopeFailure;
      final result = await full;
      expect(result.complete, isFalse);
      expect(result.markerDurable, isTrue);
      h.storage.intercept = null;
      final marker =
          (await h.keys.readMarker(_account)).value! as ReadCacheClearMarker;
      expect(marker.reason, ReadCacheClearReason.accountClear);
      expect(h.storage.markerWrites, 2);
      expect(marker.intentId, matches(RegExp(r'^[0-9a-f]{32}$')));
    },
  );

  for (final atDelete in [false, true]) {
    test(
      'timeout keeps gate until quiescence and retains marker; delete=$atDelete',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        await _save(h, _entry(h, 1));
        final at = Completer<void>();
        final release = Completer<void>();
        var held = false;
        h.storage.intercept = (operation, name) async {
          if (!held &&
              operation == (atDelete ? 'delete' : 'write') &&
              name == ReadCacheKeyStore.markerName(_account)) {
            held = true;
            at.complete();
            await release.future;
          }
        };
        final clear = h.coordinator.clear(
          _binding,
          ReadCacheCleanupOperation.settingsClear,
        );
        await at.future.timeout(const Duration(seconds: 10));
        h.clock.advance(const Duration(milliseconds: 4999));
        var completed = false;
        unawaited(clear.then((_) => completed = true));
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        h.clock.advance(const Duration(milliseconds: 1));
        final result = await clear;
        expect(result.complete, isFalse);
        expect(
          h.coordinator.notice(_binding)!.failure.cleanup!.code,
          ReadCacheCleanupCode.barrierTimedOut,
        );
        var quiescent = false;
        unawaited(h.coordinator.quiesced.then((_) => quiescent = true));
        expect(quiescent, isFalse);
        expect(await h.coordinator.activate(_binding), isFalse);
        release.complete();
        await h.coordinator.quiesced;
        expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
        expect(
          h.coordinator.notice(_binding)!.failure.cleanup!.code,
          ReadCacheCleanupCode.barrierTimedOut,
        );
        h.storage.intercept = null;
        expect((await h.keys.readMarker(_account)).isFound, isTrue);
        final fresh = _fresh(h);
        expect(await fresh.recover(_decision, accountKeys: {_account}), isTrue);
        expect(h.dir().existsSync(), isFalse);
        expect(
          (await h.keys.readKey(_account)).status,
          ReadCacheStoreReadStatus.absent,
        );
      },
    );
  }

  test(
    'clear drains late key readback before deletion and never rebuilds key',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await h.recover(), isTrue);
      final at = Completer<void>();
      final release = Completer<void>();
      var writes = false;
      h.storage.intercept = (operation, name) async {
        if (operation == 'write' &&
            name == ReadCacheKeyStore.keyName(_account) &&
            !writes) {
          writes = true;
          at.complete();
          await release.future;
        }
      };
      final activation = h.coordinator.activate(_binding);
      await at.future;
      final clear = h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.accountRemoval,
      );
      release.complete();
      expect(await activation, isFalse);
      expect((await clear).complete, isTrue);
      expect(h.storage.keyWrites, 1);
      expect(
        (await h.keys.readKey(_account)).status,
        ReadCacheStoreReadStatus.absent,
      );
      expect(await h.coordinator.resume(_binding), isFalse);
    },
  );

  for (final step in ReadCacheFileCheckpoint.values.where(
    (s) =>
        s != ReadCacheFileCheckpoint.beforeRead &&
        s != ReadCacheFileCheckpoint.evictionFileDeleted,
  )) {
    test('new coordinator recovers file crash at ${step.name}', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _crashAt(step),
        ),
      );
      final e = _entry(h, 1);
      await _save(h, e);
      // Native files use wall-clock mtimes; align the fixture with our fake clock.
      for (final file in h.dir().listSync().whereType<File>()) {
        file.setLastModifiedSync(h.clock.now);
      }
      h.clock.advance(const Duration(hours: 2));
      final fresh = _fresh(h);
      expect(await fresh.recover(_decision, accountKeys: {_account}), isTrue);
      expect(await fresh.activate(_binding), isTrue);
      final key = (await h.keys.readKey(_account)).value!;
      final committed = [
        ReadCacheFileCheckpoint.entryRenamed,
        ReadCacheFileCheckpoint.beforeIndexRename,
        ReadCacheFileCheckpoint.indexRenamed,
      ].contains(step);
      expect(
        await h.files.readEntry(_account, key, e.canonicalKey),
        committed ? isNotNull : isNull,
      );
      expect(h.dir().listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
      expect(
        (await fresh.clear(
          _binding,
          ReadCacheCleanupOperation.accountRemoval,
        )).complete,
        isTrue,
      );
      final restarted = _fresh(h);
      expect(
        await restarted.recover(_decision, accountKeys: {_account}),
        isTrue,
      );
      expect(h.dir().existsSync(), isFalse);
      expect(
        (await h.keys.readKey(_account)).status,
        ReadCacheStoreReadStatus.absent,
      );
    });
  }

  test(
    'malformed inventory names and markers trigger full recovery without AI changes',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.seedFile();
      await h.seedKey();
      h.storage.values['${ReadCacheKeyStore.keyPrefix}not-canonical!'] =
          'synthetic';
      h.storage.values[ReadCacheKeyStore.markerName(_account)] = '{unknown';
      h.storage.values[AiJournalKeyStore.keyName(_account)] = 'synthetic';
      final ai = File('${h.root.path}/ai_write_journal/synthetic')
        ..createSync(recursive: true)
        ..writeAsBytesSync([7, 8, 9]);
      expect(await h.recover(), isTrue);
      expect(h.dir().existsSync(), isFalse);
      expect((await h.keys.readInventory()).malformedNames, isEmpty);
      expect(ai.readAsBytesSync(), [7, 8, 9]);
      expect(
        h.storage.values[AiJournalKeyStore.keyName(_account)],
        'synthetic',
      );
    },
  );

  for (final special in [false, true]) {
    test(
      'D1 untrusted path escalates once and stays closed on failure: special=$special',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        if (special) {
          final directory = h.dir(_other)..createSync(recursive: true);
          final result = Process.runSync('mkfifo', [
            '${directory.path}/synthetic-pipe',
          ]);
          expect(result.exitCode, 0);
        } else {
          Directory(
            '${h.root.path}/read_cache/foreign',
          ).createSync(recursive: true);
        }
        expect(await h.recover(), !special);
        expect(h.rootCalls, lessThan(12));
        if (special) expect(await h.coordinator.activate(_binding), isFalse);
      },
    );
  }
}

void _markerOrderTests() {
  for (final signedOut in [false, true]) {
    test(
      'early activation cannot override startup resume target; signout=$signedOut',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        expect(await h.coordinator.activate(_binding), isFalse);
        expect(await h.recover(resume: _other, signedOut: signedOut), isTrue);
        expect(h.storage.keyWrites, 0);
        expect(await h.coordinator.activate(_binding), isFalse);
        final e = _entry(h, 1);
        h.coordinator.accept(_candidate(e), e);
        await h.coordinator.flush(_binding);
        expect(h.dir().existsSync(), isFalse);
        expect(h.storage.keyWrites, 0);
        expect(
          await h.coordinator.activate(
            const DiskBinding(accountKey: _account, generation: 2),
          ),
          isTrue,
        );
      },
    );
  }

  test('older generation activation cannot reopen after A to B to A', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _readyHarness(h);
    expect(
      await h.coordinator.activate(
        const DiskBinding(accountKey: _other, generation: 2),
      ),
      isTrue,
    );
    expect(
      await h.coordinator.activate(
        const DiskBinding(accountKey: _account, generation: 3),
      ),
      isTrue,
    );
    expect(await h.coordinator.activate(_binding), isFalse);
    expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
  });

  test(
    'scope marker removal failure closes disk and restart clears retained files',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      final kept = _entry(h, 2, scopes: {'project:2'});
      await _save(h, kept);
      h.storage.failMarkerDelete = true;
      final fence = h.coordinator.invalidate(
        DiskInvalidation(
          binding: _binding,
          kind: DiskInvalidationKind.mutation,
          scopeTags: {'project:1'},
        ),
      );
      await expectLater(
        fence.barrier,
        throwsA(
          isA<ApiFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.readCacheCleanup,
          ),
        ),
      );
      expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
      expect(
        await h.coordinator.lookup(
          DiskLookup(
            binding: _binding,
            canonicalKey: kept.canonicalKey,
            lease: _Lease(),
          ),
        ),
        isNull,
      );
      expect(await h.coordinator.activate(_binding), isFalse);
      h.storage.failMarkerDelete = false;
      final fresh = _fresh(h);
      expect(await fresh.recover(_decision, accountKeys: {_account}), isTrue);
      expect(h.dir().existsSync(), isFalse);
    },
  );

  test(
    'settings clear reopens only the same verified session after full completion',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      final oldKey = h.storage.values[ReadCacheKeyStore.keyName(_account)];
      final result = await h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.settingsClear,
      );
      expect(result.complete, isTrue);
      await h.coordinator.quiesced;
      expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
      expect(
        h.storage.values[ReadCacheKeyStore.keyName(_account)],
        isNot(oldKey),
      );
      expect(h.dir().existsSync(), isFalse);
    },
  );

  test(
    'removal fence survives recovery until a new verified generation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      expect(
        (await h.coordinator.clear(
          _binding,
          ReadCacheCleanupOperation.accountRemoval,
        )).complete,
        isTrue,
      );
      expect(await h.recover(), isTrue);
      expect(await h.coordinator.activate(_binding), isFalse);
      expect(h.storage.keyWrites, 1);
      expect(
        await h.coordinator.activate(
          const DiskBinding(accountKey: _account, generation: 2),
        ),
        isTrue,
      );
      expect(h.storage.keyWrites, 2);
    },
  );

  test(
    'failed settings persistence still clears but never reports disabled',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      h.storage.intercept = (operation, name) async {
        if (operation == 'write' && name == ReadCacheSettingsStore.key) {
          throw StateError('synthetic write failure');
        }
      };
      expect(await h.coordinator.setEnabled(false), isFalse);
      expect(h.dir().existsSync(), isFalse);
      expect(
        (await h.keys.readKey(_account)).status,
        ReadCacheStoreReadStatus.absent,
      );
      expect(h.coordinator.state(_account), ReadCacheDiskState.unavailable);
      expect(await h.coordinator.activate(_binding), isFalse);
    },
  );

  for (final rootFailure in [false, true]) {
    test(
      'settings off handles malformed inventory; rootFailure=$rootFailure',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        await _save(h, _entry(h, 1));
        const malformed = '${ReadCacheKeyStore.keyPrefix}not-canonical!';
        h.storage.values[malformed] = 'synthetic';
        h.storage.values[AiJournalKeyStore.keyName(_account)] = 'synthetic';
        final ai = File('${h.root.path}/ai_write_journal/synthetic')
          ..createSync(recursive: true)
          ..writeAsBytesSync([7, 8, 9]);
        h.failRoot = rootFailure;
        expect(await h.coordinator.setEnabled(false), !rootFailure);
        expect(await h.coordinator.activate(_binding), isFalse);
        expect(h.storage.values.containsKey(malformed), rootFailure);
        expect(ai.readAsBytesSync(), [7, 8, 9]);
        expect(
          h.storage.values[AiJournalKeyStore.keyName(_account)],
          'synthetic',
        );
        if (!rootFailure) {
          final inventory = await h.keys.readInventory();
          expect(inventory.keys, isEmpty);
          expect(inventory.markers, isEmpty);
          expect(inventory.malformedNames, isEmpty);
          expect(h.dir().existsSync(), isFalse);
          expect(h.coordinator.state(_account), ReadCacheDiskState.disabled);
        }
      },
    );
  }

  test(
    'pending preference write blocks recovery and resume activation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final blocked = Completer<void>();
      final release = Completer<void>();
      h.storage.intercept = (operation, name) async {
        if (operation == 'write' && name == ReadCacheSettingsStore.key) {
          blocked.complete();
          await release.future;
        }
      };
      final setting = h.coordinator.setEnabled(false);
      await blocked.future;
      final roots = h.rootCalls;
      final writes = h.storage.keyWrites;
      expect(await h.coordinator.resume(_binding), isFalse);
      expect(await h.recover(), isFalse);
      expect(await h.coordinator.activate(_binding), isFalse);
      expect(h.rootCalls, roots);
      expect(h.storage.keyWrites, writes);
      release.complete();
      expect(await setting, isTrue);
      expect(h.coordinator.startupRecovered, isFalse);
      expect(h.coordinator.state(_account), ReadCacheDiskState.disabled);
    },
  );

  test(
    'unavailable key write or mismatched readback never opens the cache',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await h.recover(), isTrue);
      h.storage.intercept = (operation, name) async {
        if (operation == 'write' &&
            name == ReadCacheKeyStore.keyName(_account)) {
          throw StateError('synthetic write failure');
        }
      };
      expect(await h.coordinator.activate(_binding), isFalse);
      expect(h.dir().existsSync(), isFalse);
      h.storage.intercept = (operation, name) async {
        if (operation == 'read' &&
            name == ReadCacheKeyStore.keyName(_account)) {
          h.storage.values.remove(name);
        }
      };
      expect(await h.coordinator.activate(_binding), isFalse);
      expect(h.dir().existsSync(), isFalse);
    },
  );

  test(
    'revocation during capacity check prevents subsequent eviction',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final victim = _entry(h, 1);
      await _save(h, victim);
      final key = (await h.keys.readKey(_account)).value!;
      final e = _entry(h, 2);
      final lease = _Lease();
      final usage = await h.files.usage(_account, key);
      final reserve =
          e.serializedLength +
          readCacheEnvelopeOverhead +
          readCacheIndexLimit +
          readCacheEnvelopeOverhead;
      _capacitySparseFile(
        File('${h.dir().path}/padding.bin'),
        readCacheAccountByteLimit - usage.accountBytes - reserve + 1,
      );
      final at = Completer<void>();
      final release = Completer<void>();
      var first = true;
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async {
            if (first) {
              first = false;
              at.complete();
              await release.future;
            }
            return h.root;
          },
          clock: () => h.clock.now,
        ),
      );
      h.coordinator.accept(_candidate(e, lease), e);
      final write = h.coordinator.flush(_binding);
      await at.future;
      lease.revoke();
      release.complete();
      await write;
      expect(
        await h.files.readEntry(_account, key, victim.canonicalKey),
        isNotNull,
      );
      expect(await h.files.readEntry(_account, key, e.canonicalKey), isNull);
    },
  );

  test(
    'file-before-index eviction crash is reconciled by a new coordinator',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final victim = _entry(h, 1);
      await _save(h, victim);
      final key = (await h.keys.readKey(_account)).value!;
      final e = _entry(h, 2);
      final usage = await h.files.usage(_account, key);
      final reserve =
          e.serializedLength +
          readCacheEnvelopeOverhead +
          readCacheIndexLimit +
          readCacheEnvelopeOverhead;
      final padding = File('${h.dir().path}/padding.bin');
      _capacitySparseFile(
        padding,
        readCacheAccountByteLimit - usage.accountBytes - reserve + 1,
      );
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _crashAt(ReadCacheFileCheckpoint.evictionFileDeleted),
        ),
      );
      await _save(h, e);
      padding.deleteSync();
      final fresh = _fresh(h);
      expect(await fresh.recover(_decision, accountKeys: {_account}), isTrue);
      expect(await fresh.activate(_binding), isTrue);
      expect(
        await fresh.lookup(
          DiskLookup(
            binding: _binding,
            canonicalKey: victim.canonicalKey,
            lease: _Lease(),
          ),
        ),
        isNull,
      );
      expect((await h.files.readIndex(_account, key))!.entries, isEmpty);
    },
  );

  for (final phase in ['marker', 'key', 'directory', 'markerRemoved']) {
    test(
      'restart snapshot at clear phase $phase cannot regrow old cache',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        await _save(h, _entry(h, 1));
        final at = Completer<void>();
        final release = Completer<void>();
        var held = false, markerDeleted = false;
        h.storage.intercept = (operation, name) async {
          if (operation == 'delete' &&
              name == ReadCacheKeyStore.markerName(_account)) {
            markerDeleted = true;
          }
          final boundary = switch (phase) {
            'marker' =>
              operation == 'delete' &&
                  name == ReadCacheKeyStore.keyName(_account),
            'key' =>
              operation == 'read' &&
                  name == ReadCacheKeyStore.keyName(_account) &&
                  !h.storage.values.containsKey(name),
            'directory' =>
              operation == 'read' &&
                  name == ReadCacheKeyStore.markerName(_account) &&
                  !h.dir().existsSync(),
            _ =>
              operation == 'read' &&
                  name == ReadCacheKeyStore.markerName(_account) &&
                  markerDeleted,
          };
          if (!held && boundary) {
            held = true;
            at.complete();
            await release.future;
          }
        };
        final clear = h.coordinator.clear(
          _binding,
          ReadCacheCleanupOperation.accountRemoval,
        );
        await at.future.timeout(const Duration(seconds: 10));
        final snapshot = _Harness();
        addTearDown(snapshot.dispose);
        snapshot.storage.values.addAll(h.storage.values);
        final base = Directory('${h.root.path}/read_cache');
        if (base.existsSync()) {
          for (final file in base.listSync(recursive: true).whereType<File>()) {
            final relative = file.path.substring(h.root.path.length);
            final copy = File('${snapshot.root.path}$relative');
            copy.parent.createSync(recursive: true);
            file.copySync(copy.path);
          }
        }
        expect(await snapshot.recover(), isTrue);
        expect(snapshot.dir().existsSync(), isFalse);
        expect(
          (await snapshot.keys.readKey(_account)).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(
          (await snapshot.keys.readMarker(_account)).status,
          ReadCacheStoreReadStatus.absent,
        );
        h.storage.intercept = null;
        release.complete();
        await clear;
      },
    );
  }

  for (final otherAccount in [false, true]) {
    test(
      'clear marker is durable before draining blocked work; other=$otherAccount',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        await _save(h, _entry(h, 1));
        final blocked = Completer<void>();
        final release = Completer<void>();
        final markerWritten = Completer<void>();
        var held = false;
        final target = otherAccount ? _other : _account;
        h.storage.intercept = (operation, name) async {
          if (operation == 'write' &&
              name == ReadCacheKeyStore.markerName(_account) &&
              !markerWritten.isCompleted) {
            markerWritten.complete();
          }
          if (!held &&
              operation == 'read' &&
              name == ReadCacheKeyStore.keyName(target)) {
            held = true;
            blocked.complete();
            await release.future;
          }
        };
        final active = h.coordinator.activate(
          otherAccount
              ? const DiskBinding(accountKey: _other, generation: 2)
              : _binding,
        );
        await blocked.future;
        final clear = h.coordinator.clear(
          _binding,
          ReadCacheCleanupOperation.accountRemoval,
        );
        await markerWritten.future.timeout(const Duration(seconds: 10));
        expect((await h.keys.readMarker(_account)).isFound, isTrue);
        var drained = false;
        unawaited(clear.then((_) => drained = true));
        await Future<void>.delayed(Duration.zero);
        expect(drained, isFalse);
        release.complete();
        await active;
        expect((await clear).complete, isTrue);
        expect(h.dir().existsSync(), isFalse);
      },
    );
  }

  test(
    'timed-out scope marker delete with failed readback reasserts current full intent',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      final at = Completer<void>();
      final release = Completer<void>();
      var deletion = false;
      var failOneRead = false;
      h.storage.intercept = (operation, name) async {
        if (name != ReadCacheKeyStore.markerName(_account)) return;
        if (operation == 'delete' && !deletion) {
          deletion = true;
          at.complete();
          await release.future;
          failOneRead = true;
        } else if (operation == 'read' && failOneRead) {
          failOneRead = false;
          throw StateError('synthetic readback failure');
        }
      };
      final fence = h.coordinator.invalidate(
        DiskInvalidation(
          binding: _binding,
          kind: DiskInvalidationKind.mutation,
          scopeTags: {'project:1'},
        ),
      );
      final failure = expectLater(
        fence.barrier,
        throwsA(
          isA<ApiFailure>().having(
            (f) => f.cleanup!.code,
            'code',
            ReadCacheCleanupCode.barrierTimedOut,
          ),
        ),
      );
      await at.future.timeout(const Duration(seconds: 10));
      h.clock.advance(const Duration(seconds: 5));
      await failure;
      release.complete();
      await fence.quiesced;
      h.storage.intercept = null;
      final marker =
          (await h.keys.readMarker(_account)).value! as ReadCacheClearMarker;
      expect(marker.reason, ReadCacheClearReason.accountClear);
      expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
      final fresh = _fresh(h);
      expect(await fresh.recover(_decision, accountKeys: {_account}), isTrue);
      expect(h.dir().existsSync(), isFalse);
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _capacityTests();
  _transactionTests();
  late _Harness h;
  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  test('unconfigured and unreadable inventory cannot prove empty', () async {
    final unconfigured = ReadCacheDiskCoordinator(coordinationScope: Object());
    final unknown = await unconfigured.clear(
      _binding,
      ReadCacheCleanupOperation.accountRemoval,
    );
    expect(unknown.complete, isFalse);
    expect(unknown.keyGoneConfirmed, isFalse);
    expect(unknown.directoryGoneConfirmed, isFalse);
    h.storage.failInventory = true;
    expect(await h.recover(), isFalse);
    final result = await h.coordinator.clear(
      _binding,
      ReadCacheCleanupOperation.accountRemoval,
    );
    expect(result.complete, isFalse);
  });

  test('provably empty clear does not create a marker', () async {
    final result = await h.coordinator.clear(
      _binding,
      ReadCacheCleanupOperation.accountRemoval,
    );
    expect(result.keyGoneConfirmed, isTrue);
    expect(result.directoryGoneConfirmed, isTrue);
    expect(result.complete, isTrue);
    expect(result.markerDurable, isFalse);
    expect(h.storage.markerWrites, 0);
  });

  test('concurrent wrappers create exactly one key', () async {
    expect(await h.recover(), isTrue);
    final otherWrapper = h.wrapper();
    final results = await Future.wait([
      h.coordinator.activate(_binding),
      otherWrapper.activate(_binding),
      h.coordinator.activate(_binding),
    ]);
    expect(results, everyElement(isTrue));
    expect(h.storage.keyWrites, 1);
    expect((await h.keys.readKey(_account)).isFound, isTrue);
  });

  test('existing key is reused without writing a replacement', () async {
    await h.seedKey();
    final old = (await h.keys.readKey(_account)).value!;
    expect(await h.recover(), isTrue);
    expect(await h.coordinator.activate(_binding), isTrue);
    expect(h.storage.keyWrites, 1);
    expect((await h.keys.readKey(_account)).value, old);
  });

  test('failed session save after cache clear keeps cache fenced', () async {
    final account = Account(
      instance: GitLabInstance.parse('https://synthetic.example/subpath'),
      user: const GitLabUser(id: 17, username: 'tester', name: 'Test'),
      token: 'synthetic-test-token',
    );
    expect(account.key, _account);
    final accountStore = MemoryAccountStore()..accounts = [account];
    final session = SessionController(accountStore);
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: h.root,
      processId: 'synthetic',
    );
    final previousRoot = artifactStorageRoot;
    artifactStorageRoot = () async => h.root;
    addTearDown(() {
      artifactStorageRoot = previousRoot;
      session.dispose();
      AiAccountRemoval.debugReset();
    });
    await session.initialize();
    expect(await h.recover(), isTrue);
    expect(await h.coordinator.activate(_binding), isTrue);
    accountStore.rejectWrite = true;
    final job = AiAccountRemoval.begin(account.key, journal: journal)!;
    final result = await AiAccountRemoval.run(
      account: account,
      job: job,
      session: session,
      journal: journal,
      consultJournal: false,
      confirm: (_) async => true,
      waitForInFlightWrites: () async {},
      requestCancelOnDispose: () {},
      clearDrafts: (_) async {},
      clearArtifacts: (_) async {},
      clearRecent: (_) async {},
      clearReadCacheDisk: (saved) =>
          h.coordinator.clearReadCacheDisk(saved.key),
      clearAi: (_) async {},
    );
    expect(result.status, AiRemovalStatus.notRemoved);
    expect(result.reason, 'accountRetained');
    expect(session.accounts, [account]);
    expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
    expect(await h.coordinator.activate(_binding), isFalse);
    expect(
      (await h.keys.readKey(_account)).status,
      ReadCacheStoreReadStatus.absent,
    );
  });

  for (final malformed in [false, true]) {
    test(
      'absent or malformed key with files uses repair transaction, malformed=$malformed',
      () async {
        expect(await h.recover(), isTrue);
        h.seedFile();
        if (malformed) {
          h.storage.values[ReadCacheKeyStore.keyName(_account)] = 'broken';
        }
        expect(await h.coordinator.activate(_binding), isTrue);
        expect(h.storage.markerWrites, 1);
        expect(h.storage.keyWrites, 1);
        expect(h.dir().existsSync(), isFalse);
        expect(
          (await h.keys.readMarker(_account)).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect((await h.keys.readKey(_account)).isFound, isTrue);
        final writeMarker = h.storage.calls.indexWhere(
          (c) => c.startsWith('write:${ReadCacheKeyStore.markerPrefix}'),
        );
        final deleteKey = h.storage.calls.indexWhere(
          (c) => c.startsWith('delete:${ReadCacheKeyStore.keyPrefix}'),
        );
        final writeKey = h.storage.calls.indexWhere(
          (c) => c.startsWith('write:${ReadCacheKeyStore.keyPrefix}'),
        );
        expect(writeMarker, lessThan(deleteKey));
        expect(deleteKey, lessThan(writeKey));
      },
    );
  }

  test(
    'unavailable key performs no file access; explicit clear can remove directory',
    () async {
      expect(await h.recover(), isTrue);
      h.seedFile();
      h.storage.failKeyRead = true;
      final calls = h.rootCalls;
      expect(await h.coordinator.activate(_binding), isFalse);
      expect(h.rootCalls, calls);
      expect(h.dir().existsSync(), isTrue);
      expect(h.coordinator.state(_account), ReadCacheDiskState.unavailable);
      final result = await h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.accountRemoval,
      );
      expect(result.directoryGoneConfirmed, isTrue);
      expect(h.dir().existsSync(), isFalse);
      expect(result.keyGoneConfirmed, isFalse);
      expect(result.complete, isFalse);
    },
  );

  for (final fault in [
    'marker-write',
    'marker-read',
    'marker-mismatch',
    'marker-remove',
    'key-delete',
    'directory',
    'both',
    'triple',
  ]) {
    test('independent clear failure: $fault', () async {
      await h.seedKey();
      h.seedFile();
      h.storage.failMarkerWrite = fault == 'marker-write' || fault == 'triple';
      h.storage.failMarkerRead = fault == 'marker-read';
      h.storage.mismatchMarkerRead = fault == 'marker-mismatch';
      h.storage.failMarkerDelete = fault == 'marker-remove';
      h.storage.failKeyDelete =
          fault == 'key-delete' || fault == 'both' || fault == 'triple';
      h.failRoot = fault == 'directory' || fault == 'both' || fault == 'triple';
      final result = await h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.accountRemoval,
      );
      expect(result.complete, isFalse);
      expect(result.keyGoneConfirmed, !h.storage.failKeyDelete);
      expect(result.directoryGoneConfirmed, !h.failRoot);
      if (fault == 'marker-write' ||
          fault == 'marker-read' ||
          fault == 'marker-mismatch' ||
          fault == 'triple') {
        expect(result.markerDurable, isFalse);
      } else {
        expect(result.markerDurable, isTrue);
      }
      if (fault == 'triple') {
        expect(result.keyGoneConfirmed, isFalse);
        expect(result.directoryGoneConfirmed, isFalse);
        expect(result.markerDurable, isFalse);
      }
      expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
    });
  }

  for (final failure in ['key', 'directory', 'both']) {
    test('account removal threshold accepts either proof: $failure', () async {
      await h.seedKey();
      h.seedFile();
      h.storage.failKeyDelete = failure == 'key' || failure == 'both';
      h.failRoot = failure == 'directory' || failure == 'both';
      final action = h.coordinator.clearReadCacheDisk(_account);
      if (failure == 'both') {
        await expectLater(
          action,
          throwsA(
            isA<ApiFailure>()
                .having((f) => f.kind, 'kind', FailureKind.readCacheCleanup)
                .having(
                  (f) => f.cleanup!.disposition,
                  'disposition',
                  ReadCacheCleanupDisposition.accountRetained,
                ),
          ),
        );
      } else {
        await expectLater(action, completes);
      }
      expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
    });
  }

  test('notice survives without subscriber and subscriber failure', () async {
    const result = DiskClearResult(
      keyGoneConfirmed: false,
      directoryGoneConfirmed: false,
      markerDurable: false,
      complete: false,
    );
    const state = ReadCacheCleanupState(
      operation: ReadCacheCleanupOperation.signOut,
      disposition: ReadCacheCleanupDisposition.signedOutCleanupPending,
      code: ReadCacheCleanupCode.cleanupFailed,
      clearResult: result,
    );
    h.coordinator.reportCleanup(_binding, state);
    expect(h.coordinator.notice(_binding)!.failure.cleanup, same(state));
    h.coordinator.subscribe(
      (_) => throw StateError('synthetic listener failure'),
    );
    var called = false;
    h.coordinator.subscribe((_) => called = true);
    h.coordinator.reportCleanup(_binding, state);
    expect(called, isTrue);
    expect(h.coordinator.signedOutNotices, hasLength(1));
    expect(
      h.coordinator.notice(_binding)!.failure.kind,
      FailureKind.readCacheCleanup,
    );
  });

  for (final mode in ['retain', 'signout', 'disabled']) {
    test(
      'D1 recovery retention $mode preserves AI bytes and secure entries',
      () async {
        await h.seedKey(_account);
        await h.seedKey(_other);
        await h.seedKey(_outside);
        h.seedFile(_account);
        h.seedFile(_other);
        h.seedFile(_outside);
        final marker = ReadCacheClearMarker(
          intentId: '0123456789abcdef0123456789abcdef',
          reason: ReadCacheClearReason.accountClear,
          requestedAt: h.clock.now,
        );
        await h.keys.writeMarker(_outside, marker);
        final ai = File('${h.root.path}/ai_history/synthetic')
          ..createSync(recursive: true)
          ..writeAsBytesSync([3, 1, 4]);
        final journal = File('${h.root.path}/ai_write_journal/synthetic')
          ..createSync(recursive: true)
          ..writeAsBytesSync([1, 5, 9]);
        final syntheticKey = base64Url.encode(List<int>.filled(32, 7));
        h.storage.values[SecureAiStore.historyKey(_account)] = syntheticKey;
        h.storage.values[AiJournalKeyStore.keyName(_account)] = syntheticKey;
        h.storage.values[SecureAiStore.tombstoneKey(_account)] = '1';
        h.storage.values[SecureAiStore.historyClearMarkerKey(_account)] = '1';
        h.storage.values[AiJournalKeyStore.resetName(_account)] = h.clock.now
            .toIso8601String();
        final secureBefore = Map.of(h.storage.values)
          ..removeWhere((key, _) => key.startsWith('read_cache_'));
        if (mode == 'disabled') {
          h.storage.values[ReadCacheSettingsStore.key] = '0';
        }
        expect(await h.recover(signedOut: mode == 'signout'), isTrue);
        expect(h.dir(_account).existsSync(), mode == 'retain');
        expect(h.dir(_other).existsSync(), isFalse);
        expect(h.dir(_outside).existsSync(), isFalse);
        expect((await h.keys.readKey(_account)).isFound, mode == 'retain');
        expect(
          (await h.keys.readKey(_other)).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(
          (await h.keys.readMarker(_outside)).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(ai.readAsBytesSync(), [3, 1, 4]);
        expect(journal.readAsBytesSync(), [1, 5, 9]);
        for (final entry in secureBefore.entries) {
          expect(h.storage.values[entry.key], entry.value);
        }
      },
    );
  }

  test(
    'unreadable startup decision does not scan or remove anything',
    () async {
      await h.seedKey();
      h.seedFile();
      final before = Map.of(h.storage.values);
      final calls = h.rootCalls;
      expect(await h.recover(readable: false), isFalse);
      expect(h.rootCalls, calls);
      expect(h.storage.values, before);
      expect(h.dir().existsSync(), isTrue);
    },
  );
}

final class _CapacityLease implements DiskCommitLease {
  bool _current = true;
  @override
  bool get isCurrent => _current;
  @override
  void revoke() => _current = false;
}

ProjectedDiskEntry _capacityEntry(
  int id,
  DateTime timestamp, {
  int bodySize = 0,
  int tagSize = 0,
}) => ProjectedDiskEntry(
  accountKey: _account,
  canonicalKey: 'capacity-$id',
  cacheClass: ReadCacheDiskClass.projectMeta,
  bodyKind: ReadCacheBodyKind.json,
  fetchedAt: timestamp,
  body: {'id': id, 'name': 'x' * bodySize},
  privacyEpoch: 0,
  issueIdentities: const {},
  scopeTags: tagSize == 0 ? const {} : {'scope-$id-${'x' * tagSize}'},
);

DiskWriteCandidate _capacityCandidate(ProjectedDiskEntry entry) =>
    DiskWriteCandidate(
      binding: _binding,
      uri: Uri.parse('https://synthetic.example/projects/1'),
      logicalAccept: 'application/json',
      bodyKind: entry.bodyKind,
      fetchedAt: entry.fetchedAt,
      responseBytes: entry.serializedLength,
      lease: _CapacityLease(),
      cacheable: true,
      noStore: false,
      firstPage: true,
    );

void _capacitySparseFile(File file, int size) {
  file.parent.createSync(recursive: true);
  final handle = file.openSync(mode: FileMode.write);
  try {
    handle.truncateSync(size);
  } finally {
    handle.closeSync();
  }
}

Future<void> _capacityWriteRaw(
  _Harness h,
  List<int> key,
  ProjectedDiskEntry entry,
) async {
  const cipher = ReadCacheCipher();
  final name = await cipher.entryFileName(key, entry.canonicalKey);
  final bytes = await cipher.encrypt(
    key: key,
    accountKey: entry.accountKey,
    fileName: name,
    plaintext: cipher.encodeEntry(entry),
    plaintextLimit: entry.plaintextLimit,
  );
  await File('${h.dir().path}/$name').writeAsBytes(bytes);
}

void _capacityTests() {
  for (final device in [false, true]) {
    test(
      'capacity ${device ? 'device 96 MiB' : 'account 32 MiB'} evicts oldest authenticated entry',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        expect(await h.recover(), isTrue);
        await h.seedKey();
        final key = (await h.keys.readKey(_account)).value!;
        final oldest = _capacityEntry(
          1,
          h.clock.now.subtract(const Duration(seconds: 2)),
          bodySize: 400000,
        );
        final newer = _capacityEntry(
          2,
          h.clock.now.subtract(const Duration(seconds: 1)),
          bodySize: 400000,
        );
        await h.files.writeEntry(oldest, key);
        await h.files.writeEntry(newer, key);
        expect(await h.coordinator.activate(_binding), isTrue);
        final incoming = _capacityEntry(3, h.clock.now);
        final usage = await h.files.usage(_account, key);
        final reserve =
            const ReadCacheCipher().encodeEntry(incoming).length +
            readCacheEnvelopeOverhead +
            readCacheIndexLimit +
            readCacheEnvelopeOverhead;
        final limit = device
            ? readCacheDeviceByteLimit
            : readCacheAccountByteLimit;
        final current = device ? usage.deviceBytes : usage.accountBytes;
        final padding = limit - current - reserve + 1;
        expect(padding, greaterThan(0));
        if (device) {
          var remaining = padding;
          for (var i = 0; i < 3; i++) {
            final amount = i == 2 ? remaining : padding ~/ 3;
            final account = 'https://synthetic.example/padding#$i';
            _capacitySparseFile(
              File('${h.dir(account).path}/padding.bin'),
              amount,
            );
            remaining -= amount;
          }
        } else {
          _capacitySparseFile(File('${h.dir().path}/padding.bin'), padding);
        }
        h.coordinator.accept(_capacityCandidate(incoming), incoming);
        await h.coordinator.flush(_binding);
        expect(
          await h.files.readEntry(_account, key, oldest.canonicalKey),
          isNull,
        );
        expect(
          await h.files.readEntry(_account, key, newer.canonicalKey),
          isNotNull,
        );
        expect(
          await h.files.readEntry(_account, key, incoming.canonicalKey),
          isNotNull,
        );
        final after = await h.files.usage(_account, key);
        expect(
          device ? after.deviceBytes : after.accountBytes,
          lessThanOrEqualTo(limit),
        );
      },
    );
  }

  test(
    'capacity index 256 KiB evicts least recently used authenticated entries',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await h.recover(), isTrue);
      await h.seedKey();
      final key = (await h.keys.readKey(_account)).value!;
      final older = _capacityEntry(
        10,
        h.clock.now.subtract(const Duration(seconds: 2)),
        tagSize: 100000,
      );
      final middle = _capacityEntry(
        11,
        h.clock.now.subtract(const Duration(seconds: 1)),
        tagSize: 100000,
      );
      final newer = _capacityEntry(12, h.clock.now, tagSize: 100000);
      await h.files.writeEntry(older, key);
      await h.files.writeEntry(middle, key);
      await h.files.writeEntry(newer, key);
      expect(await h.coordinator.activate(_binding), isTrue);
      await h.coordinator.flush(_binding);
      final index = await h.files.readIndex(_account, key);
      expect(index, isNotNull);
      expect(
        const ReadCacheCipher().encodeIndex(index!).length,
        lessThanOrEqualTo(readCacheIndexLimit),
      );
      expect(index.entries.length, lessThan(3));
      expect(
        await h.files.readEntry(_account, key, older.canonicalKey),
        isNull,
      );
      expect(
        await h.files.readEntry(_account, key, newer.canonicalKey),
        isNotNull,
      );
    },
  );

  test(
    'capacity index retains at most 2048 entries after reconstruction',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await h.recover(), isTrue);
      await h.seedKey();
      final key = (await h.keys.readKey(_account)).value!;
      h.dir().createSync(recursive: true);
      for (var start = 0; start < readCacheIndexEntriesLimit + 1; start += 32) {
        await Future.wait([
          for (
            var id = start;
            id < start + 32 && id <= readCacheIndexEntriesLimit;
            id++
          )
            _capacityWriteRaw(
              h,
              key,
              _capacityEntry(
                id,
                h.clock.now.subtract(
                  Duration(seconds: readCacheIndexEntriesLimit - id),
                ),
              ),
            ),
        ]);
      }
      expect(await h.coordinator.activate(_binding), isTrue);
      await h.coordinator.flush(_binding);
      final index = await h.files.readIndex(_account, key);
      expect(index, isNotNull);
      expect(
        index!.entries.length,
        lessThanOrEqualTo(readCacheIndexEntriesLimit),
      );
      expect(
        const ReadCacheCipher().encodeIndex(index).length,
        lessThanOrEqualTo(readCacheIndexLimit),
      );
      expect(
        await h.files.readEntry(
          _account,
          key,
          _capacityEntry(
            0,
            h.clock.now.subtract(Duration(seconds: readCacheIndexEntriesLimit)),
          ).canonicalKey,
        ),
        isNull,
      );
      expect(
        await h.files.readEntry(
          _account,
          key,
          _capacityEntry(readCacheIndexEntriesLimit, h.clock.now).canonicalKey,
        ),
        isNotNull,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
