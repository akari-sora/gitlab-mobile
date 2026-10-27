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
  ReadCacheFileCheckpoint boundary, [
  SendPort? events,
]) => (step) {
  if (step == boundary) {
    events?.send(step.name);
    throw StateError('synthetic crash');
  }
};

void Function(ReadCacheFileCheckpoint) _untrustedAt(
  ReadCacheFileCheckpoint boundary,
  String signal,
) => (step) {
  if (step != boundary) return;
  File(signal).writeAsBytesSync([1]);
  throw const ReadCacheFileException(ReadCacheFileFailure.untrustedPath);
};

void Function(ReadCacheFileCheckpoint) _untrustedAfterPause(
  SendPort events,
  String release,
) {
  final pause = _pauseAt(ReadCacheFileCheckpoint.beforeRead, events, release);
  return (step) {
    if (step != ReadCacheFileCheckpoint.beforeRead) return;
    pause(step);
    throw const ReadCacheFileException(ReadCacheFileFailure.untrustedPath);
  };
}

final class _PathFault {
  _PathFault(this.h, {this.atRoot, this.checkpoint, this.failClear = false});
  final _Harness h;
  final int? atRoot;
  final ReadCacheFileCheckpoint? checkpoint;
  final bool failClear;
  int calls = 0, clearAttempts = 0;
  bool injected = false, fencedBeforeClear = false;
  String get signal => '${h.root.path}/path-fault';

  ReadCacheFileStore get files => ReadCacheFileStore(
    root: () async {
      calls++;
      if (calls == atRoot) {
        final base = Directory('${h.root.path}/read_cache');
        if (base.existsSync()) base.deleteSync(recursive: true);
        File(base.path).writeAsBytesSync([1]);
        injected = true;
      } else if (injected || File(signal).existsSync()) {
        injected = true;
        clearAttempts++;
        fencedBeforeClear =
            !h.coordinator.startupRecovered &&
            h.coordinator.stats.queuedEntries == 0 &&
            [_account, _other].every(
              (key) => h.coordinator.state(key) == ReadCacheDiskState.cleaning,
            );
        if (failClear) throw StateError('synthetic root clear failure');
      }
      return h.root;
    },
    clock: () => h.clock.now,
    checkpoint: checkpoint == null ? null : _untrustedAt(checkpoint!, signal),
  );
}

void _pathFailureTests() {
  // Root ordinals select distinct store calls without mocking the final store.
  // A wrong base type makes the selected operation return untrustedPath. Its
  // disappearance proves clearRoot ran; clearAccount cannot remove that node.
  const cases = <(String, int)>[
    ('prepare state', 1),
    ('prepare names', 2),
    ('load index', 1),
    ('load names', 2),
    ('load entry', 3),
    ('load temporary cleanup', 4),
    ('lookup read', 1),
    ('lookup eviction', 2),
    ('flush usage', 1),
    ('flush stage entry', 2),
    ('flush index usage', 3),
    ('flush stage index', 4),
    ('makeRoom eviction', 2),
    ('invalidate eviction', 1),
    ('clear account', 1),
    ('clear state proof', 2),
    ('clear names proof', 3),
    ('recover sweep', 4),
    ('recover names', 5),
    ('disable sweep', 7),
    ('disable names', 8),
  ];
  for (final (site, ordinal) in cases) {
    test('C2FU H2 fences every account and clears root: $site', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final victim = _entry(h, 1);
      await _save(h, victim);
      h.coordinator.state(_other);
      await h.seedKey(_other);
      h.seedFile(_other);
      if (site.startsWith('prepare')) await h.keys.deleteKey(_account);
      if (site == 'lookup eviction') {
        h.clock.now = h.clock.now.add(readCacheRetention);
      }
      if (site == 'makeRoom eviction') {
        final key = (await h.keys.readKey(_account)).value!;
        final usage = await h.files.usage(_account, key);
        final reserve =
            _entry(h, 2).serializedLength +
            readCacheEnvelopeOverhead +
            readCacheIndexLimit +
            readCacheEnvelopeOverhead;
        _capacitySparseFile(
          File('${h.dir().path}/padding.bin'),
          readCacheAccountByteLimit - usage.accountBytes - reserve + 1,
        );
      }
      final fault = _PathFault(h, atRoot: ordinal);
      h.coordinator.configure(
        keys: h.keys,
        files: fault.files,
        settings: h.settings,
      );
      final next = _entry(h, 2, scopes: {'project:2'});
      h.coordinator.accept(_candidate(next), next);
      if (site.startsWith('prepare') || site.startsWith('load')) {
        expect(await h.coordinator.activate(_binding), isFalse);
      } else if (site.startsWith('lookup')) {
        expect(
          await h.coordinator.lookup(
            DiskLookup(
              binding: _binding,
              canonicalKey: victim.canonicalKey,
              bodyKind: ReadCacheBodyKind.text,
              lease: _Lease(),
            ),
          ),
          isNull,
        );
      } else if (site.startsWith('flush') || site.startsWith('makeRoom')) {
        await h.coordinator.flush(_binding);
      } else if (site.startsWith('invalidate')) {
        await expectLater(
          h.coordinator
              .invalidate(
                DiskInvalidation(
                  binding: _binding,
                  kind: DiskInvalidationKind.mutation,
                  scopeTags: {'project:1'},
                ),
              )
              .barrier,
          throwsA(isA<ApiFailure>()),
        );
      } else if (site.startsWith('clear')) {
        expect(
          (await h.coordinator.clear(
            _binding,
            ReadCacheCleanupOperation.settingsClear,
          )).complete,
          isFalse,
        );
      } else if (site.startsWith('recover')) {
        expect(await h.recover(), isFalse);
      } else {
        expect(await h.coordinator.setEnabled(false), isFalse);
      }
      expect(fault.injected, isTrue, reason: site);
      expect(fault.clearAttempts, 1, reason: site);
      expect(fault.fencedBeforeClear, isTrue, reason: site);
      expect(
        FileSystemEntity.typeSync('${h.root.path}/read_cache'),
        FileSystemEntityType.notFound,
      );
      for (final key in [_account, _other]) {
        expect(h.coordinator.state(key), ReadCacheDiskState.cleaning);
        final marker = await h.keys.readMarker(key);
        expect(marker.isFound, isTrue, reason: key);
        expect(
          (marker.value! as ReadCacheClearMarker).reason,
          ReadCacheClearReason.accountClear,
        );
      }
      expect(h.coordinator.stats.queuedEntries, 0);
      expect(await h.coordinator.activate(_binding), isFalse);
      final calls = fault.calls;
      h.clock.advance(const Duration(hours: 1));
      await h.coordinator.quiesced;
      expect(fault.calls, calls, reason: 'no automatic root-clear retry');
    });
  }
  for (final checkpoint in [
    ReadCacheFileCheckpoint.temporaryCreated,
    ReadCacheFileCheckpoint.beforeEntryRename,
    ReadCacheFileCheckpoint.entryRenamed,
    ReadCacheFileCheckpoint.beforeIndexRename,
    ReadCacheFileCheckpoint.indexRenamed,
    ReadCacheFileCheckpoint.evictionFileDeleted,
  ]) {
    test(
      'C2FU H2 fences staged or synchronous failures: $checkpoint',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        await _save(h, _entry(h, 1));
        h.coordinator.state(_other);
        await h.seedKey(_other);
        h.seedFile(_other);
        final fault = _PathFault(h, checkpoint: checkpoint);
        h.coordinator.configure(
          keys: h.keys,
          files: fault.files,
          settings: h.settings,
        );
        if (checkpoint == ReadCacheFileCheckpoint.evictionFileDeleted) {
          await expectLater(
            h.coordinator
                .invalidate(
                  DiskInvalidation(
                    binding: _binding,
                    kind: DiskInvalidationKind.mutation,
                    scopeTags: {'project:1'},
                  ),
                )
                .barrier,
            throwsA(isA<ApiFailure>()),
          );
        } else {
          await _save(h, _entry(h, 2));
        }
        expect(fault.clearAttempts, 1);
        expect(fault.fencedBeforeClear, isTrue);
        expect(Directory('${h.root.path}/read_cache').existsSync(), isFalse);
        for (final key in [_account, _other]) {
          expect(h.coordinator.state(key), ReadCacheDiskState.cleaning);
          expect(
            ((await h.keys.readMarker(key)).value! as ReadCacheClearMarker)
                .reason,
            ReadCacheClearReason.accountClear,
          );
        }
        expect(await h.coordinator.activate(_binding), isFalse);
      },
    );
  }
  for (final phase in ['settings', 'inventory']) {
    test(
      'C2FU H2 stale recovery cannot consume a new path fence: $phase',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        final entry = _entry(h, 1);
        await _save(h, entry);
        h.coordinator.state(_other);
        final events = ReceivePort();
        final messages = StreamIterator<Object?>(events);
        addTearDown(events.close);
        final release = File('${h.root.path}/release');
        h.coordinator.configure(
          keys: h.keys,
          settings: h.settings,
          files: ReadCacheFileStore(
            root: () async => h.root,
            clock: () => h.clock.now,
            checkpoint: _untrustedAfterPause(events.sendPort, release.path),
          ),
        );
        final reading = h.coordinator.lookup(
          DiskLookup(
            binding: _binding,
            canonicalKey: entry.canonicalKey,
            bodyKind: ReadCacheBodyKind.text,
            lease: _Lease(),
          ),
        );
        expect(
          await messages.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        final reached = Completer<void>(), resume = Completer<void>();
        h.storage.intercept = (operation, name) async {
          if ((phase == 'settings' &&
                  operation == 'read' &&
                  name == ReadCacheSettingsStore.key) ||
              (phase == 'inventory' && operation == 'inventory')) {
            reached.complete();
            await resume.future;
          }
        };
        final recovering = h.recover();
        await reached.future;
        release.createSync();
        expect(await reading, isNull);
        final writes = h.storage.markerWrites;
        resume.complete();
        expect(await recovering, isFalse);
        await messages.cancel();
        expect(h.storage.markerWrites, writes);
        for (final key in [_account, _other]) {
          expect(h.coordinator.state(key), ReadCacheDiskState.cleaning);
          expect((await h.keys.readMarker(key)).isFound, isTrue);
        }
        expect(await h.coordinator.activate(_binding), isFalse);
      },
    );
  }
  for (final disable in [false, true]) {
    test(
      'C2FU H2 direct root-clear failure is not retried: disable=$disable',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        await _save(h, _entry(h, 1));
        h.coordinator.state(_other);
        await h.seedKey(_other);
        await h.seedKey(_outside); // Known only through secure inventory.
        h.storage.values['${ReadCacheKeyStore.keyPrefix}not-canonical!'] =
            'synthetic';
        final fifo = '${h.root.path}/read_cache/unremovable-pipe';
        expect(Process.runSync('mkfifo', [fifo]).exitCode, 0);
        final fault = _PathFault(h);
        h.coordinator.configure(
          keys: h.keys,
          files: fault.files,
          settings: h.settings,
        );
        expect(
          await (disable ? h.coordinator.setEnabled(false) : h.recover()),
          isFalse,
        );
        expect(
          fault.calls,
          1,
          reason: 'a failed clearRoot is already the last resort',
        );
        for (final binding in [
          _binding,
          const DiskBinding(accountKey: _other, generation: 0),
          const DiskBinding(accountKey: _outside, generation: 0),
        ]) {
          expect(
            h.coordinator.state(binding.accountKey),
            ReadCacheDiskState.cleaning,
          );
          expect((await h.keys.readMarker(binding.accountKey)).isFound, isTrue);
          expect(
            h.coordinator.notice(binding)!.failure.cleanup!.code,
            ReadCacheCleanupCode.cleanupFailed,
          );
        }
        expect(await h.coordinator.activate(_binding), isFalse);
      },
    );
  }
  test('C2FU H2 stuck marker cannot prevent the root-clear attempt', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _readyHarness(h);
    final entry = _entry(h, 1);
    await _save(h, entry);
    h.coordinator.state(_other);
    final reached = Completer<void>(), release = Completer<void>();
    h.storage.intercept = (operation, name) async {
      if (operation == 'write' &&
          name == ReadCacheKeyStore.markerName(_account)) {
        reached.complete();
        await release.future;
      }
    };
    final fault = _PathFault(h, atRoot: 1);
    h.coordinator.configure(
      keys: h.keys,
      files: fault.files,
      settings: h.settings,
    );
    final reading = h.coordinator.lookup(
      DiskLookup(
        binding: _binding,
        canonicalKey: entry.canonicalKey,
        bodyKind: ReadCacheBodyKind.text,
        lease: _Lease(),
      ),
    );
    await reached.future;
    expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
    expect(h.coordinator.state(_other), ReadCacheDiskState.cleaning);
    h.clock.advance(ReadCacheDiskCoordinator.barrierLimit);
    expect(await reading, isNull);
    expect(fault.clearAttempts, 1);
    expect(fault.fencedBeforeClear, isTrue);
    expect(Directory('${h.root.path}/read_cache').existsSync(), isFalse);
    release.complete();
    await h.coordinator.quiesced;
    // Drain the deliberately delayed marker, which still belongs to the fence.
    await Future<void>.delayed(Duration.zero);
    expect((await h.keys.readMarker(_account)).isFound, isTrue);
    expect(await h.coordinator.activate(_binding), isFalse);
  });
  test(
    'C2FU H2 root-clear failure stays closed with notice and never spins',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final entry = _entry(h, 1);
      await _save(h, entry);
      h.coordinator.state(_other);
      await h.seedKey(_other);
      final fault = _PathFault(h, atRoot: 1, failClear: true);
      h.coordinator.configure(
        keys: h.keys,
        files: fault.files,
        settings: h.settings,
      );
      expect(
        await h.coordinator.lookup(
          DiskLookup(
            binding: _binding,
            canonicalKey: entry.canonicalKey,
            bodyKind: ReadCacheBodyKind.text,
            lease: _Lease(),
          ),
        ),
        isNull,
      );
      expect(fault.clearAttempts, 1);
      expect(fault.fencedBeforeClear, isTrue);
      for (final binding in [
        _binding,
        const DiskBinding(accountKey: _other, generation: 0),
      ]) {
        expect(
          h.coordinator.state(binding.accountKey),
          ReadCacheDiskState.cleaning,
        );
        expect((await h.keys.readMarker(binding.accountKey)).isFound, isTrue);
        final notice = h.coordinator.notice(binding)!.failure;
        expect(notice.kind, FailureKind.readCacheCleanup);
        expect(notice.cleanup!.code, ReadCacheCleanupCode.cleanupFailed);
        expect(notice.cleanup!.clearResult.complete, isFalse);
      }
      expect(await h.coordinator.resume(_binding), isFalse);
      final calls = fault.calls;
      h.clock.advance(const Duration(hours: 1));
      await h.coordinator.quiesced;
      expect(fault.calls, calls);
    },
  );
}

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
      final events = ReceivePort();
      addTearDown(events.close);
      final hit = events.first.timeout(const Duration(seconds: 10));
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _crashAt(step, events.sendPort),
        ),
      );
      final e = _entry(h, 1);
      await _save(h, e);
      expect(await hit, step.name);
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
      final index = await h.files.readIndex(_account, key);
      expect(index != null, step == ReadCacheFileCheckpoint.indexRenamed);
      if (index != null) expect(index.entries, hasLength(1));
      final temporary = h
          .dir()
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.tmp'))
          .toList();
      final hasTemporary = ![
        ReadCacheFileCheckpoint.entryRenamed,
        ReadCacheFileCheckpoint.indexRenamed,
      ].contains(step);
      expect(temporary, hasLength(hasTemporary ? 1 : 0));
      if (hasTemporary) {
        expect(
          temporary.single.lengthSync(),
          step == ReadCacheFileCheckpoint.temporaryCreated ? 0 : greaterThan(0),
        );
      }
      // Native files use wall-clock mtimes; align the fixture with our fake clock.
      for (final file in h.dir().listSync().whereType<File>()) {
        file.setLastModifiedSync(h.clock.now);
      }
      h.clock.advance(const Duration(hours: 2));
      final fresh = _fresh(h);
      expect(await fresh.recover(_decision, accountKeys: {_account}), isTrue);
      expect(await fresh.activate(_binding), isTrue);
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
        // A path incident closes this recovery pass even when root cleanup
        // succeeds. Only a new inventory/decision may reconcile the full fence.
        expect(await h.recover(), isFalse);
        if (!special) expect(await h.recover(), isTrue);
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
            bodyKind: ReadCacheBodyKind.text,
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
            bodyKind: ReadCacheBodyKind.text,
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

void Function() _snapshotAi(_Harness h) {
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
  Map<String, String> secure() =>
      Map.of(h.storage.values)
        ..removeWhere((key, _) => key.startsWith('read_cache_'));
  final before = secure();
  return () {
    expect(ai.readAsBytesSync(), [3, 1, 4]);
    expect(journal.readAsBytesSync(), [1, 5, 9]);
    expect(secure(), before);
  };
}

int _keyReads(_Harness h) => h.storage.calls
    .where((s) => s == 'read:${ReadCacheKeyStore.keyName(_account)}')
    .length;

DiskInvalidation _mutation([String scope = 'project:1']) => DiskInvalidation(
  binding: _binding,
  kind: DiskInvalidationKind.mutation,
  scopeTags: {scope},
);

void Function(ReadCacheFileCheckpoint) _notifyCheckpoints(SendPort events) =>
    (step) => events.send(step.name);

void _fix1Tests() {
  test('FIX1 Codex I1 disable drains an unpublished first key write', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    expect(await h.recover(), isTrue);
    final at = Completer<void>();
    final release = Completer<void>();
    h.storage.intercept = (operation, name) async {
      if (operation == 'write' && name == ReadCacheKeyStore.keyName(_account)) {
        at.complete();
        await release.future;
      }
    };
    final activation = h.coordinator.activate(_binding);
    await at.future;
    var finished = false;
    final disabled = h.coordinator.setEnabled(false).then((result) {
      finished = true;
      return result;
    });
    // Let the settings/inventory lanes finish while the key is still absent.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final finishedBeforeDrain = finished;
    release.complete();
    expect(await activation, isFalse);
    expect(await disabled, isTrue);
    await h.coordinator.quiesced;
    expect(finishedBeforeDrain, isFalse);
    final inventory = await h.keys.readInventory();
    expect(inventory.status, ReadCacheStoreReadStatus.found);
    expect(inventory.keys, isEmpty);
    expect(inventory.markers, isEmpty);
    expect(inventory.malformedNames, isEmpty);
    expect(await h.files.accountDirectoryNames(), isEmpty);
    expect(h.storage.keyWrites, 1);
  });

  for (final accountClear in [false, true]) {
    test(
      'FIX1 Codex I1 settings sweep fences new marker writes; accountClear=$accountClear',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        final at = Completer<void>(), release = Completer<void>();
        final releaseMarker = Completer<void>();
        var held = false, markerStarted = false;
        h.storage.intercept = (operation, name) async {
          if (operation == 'inventory' && !held) {
            held = true;
            at.complete();
            await release.future;
          }
          if (operation == 'write' &&
              name == ReadCacheKeyStore.markerName(_outside)) {
            markerStarted = true;
            await releaseMarker.future;
          }
        };
        final disabled = h.coordinator.setEnabled(false);
        await at.future;
        final barrier = accountClear
            ? h.coordinator.clear(
                const DiskBinding(accountKey: _outside, generation: 1),
                ReadCacheCleanupOperation.mutation,
              )
            : h.coordinator
                  .invalidate(
                    DiskInvalidation(
                      binding: const DiskBinding(
                        accountKey: _outside,
                        generation: 1,
                      ),
                      kind: DiskInvalidationKind.mutation,
                      scopeTags: {'project:1'},
                    ),
                  )
                  .barrier;
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        final markerInFlightAtSuccess = markerStarted;
        release.complete();
        expect(await disabled, isTrue);
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        final lateMarkerStarted = markerStarted;
        releaseMarker.complete();
        expect((await barrier).complete, isTrue);
        expect(markerInFlightAtSuccess, isFalse);
        expect(lateMarkerStarted, isFalse);
        expect((await h.keys.readInventory()).markers, isEmpty);
      },
    );
  }

  for (final disable in [false, true]) {
    test(
      'FIX1 Codex I1 clear drains an abandoned marker lane; disable=$disable',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        await h.keys.deleteKey(_account);
        final keyAt = Completer<void>(), keyRelease = Completer<void>();
        final markerAt = Completer<void>(), markerRelease = Completer<void>();
        var held = false;
        h.storage.intercept = (operation, name) async {
          if (operation == 'read' &&
              name == ReadCacheKeyStore.keyName(_other) &&
              !held) {
            held = true;
            keyAt.complete();
            await keyRelease.future;
          }
          if (operation == 'write' &&
              name == ReadCacheKeyStore.markerName(_account) &&
              !markerAt.isCompleted) {
            markerAt.complete();
            await markerRelease.future;
          }
        };
        final activation = h.coordinator.activate(
          const DiskBinding(accountKey: _other, generation: 2),
        );
        await keyAt.future;
        final fence = h.coordinator.invalidate(_mutation());
        final failure = expectLater(fence.barrier, throwsA(isA<ApiFailure>()));
        await markerAt.future;
        fence.revoke();
        keyRelease.complete();
        await activation;
        await failure;
        await h.coordinator.quiesced;
        var finished = false;
        final clearing =
            (disable
                    ? h.coordinator.setEnabled(false)
                    : h.coordinator
                          .clear(_binding, ReadCacheCleanupOperation.mutation)
                          .then((result) => result.complete))
                .then((result) {
                  finished = true;
                  return result;
                });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final finishedBeforeMarkerDrain = finished;
        markerRelease.complete();
        expect(await clearing, isTrue);
        expect(finishedBeforeMarkerDrain, isFalse);
        await h.coordinator.quiesced;
        expect((await h.keys.readInventory()).markers, isEmpty);
      },
    );
  }

  for (final revoked in [0, 1]) {
    test('FIX1 Codex I2 candidate $revoked lease gates staged index', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final events = ReceivePort();
      final messages = StreamIterator<Object?>(events);
      final release = File('${h.root.path}/release');
      addTearDown(events.close);
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
      final leases = [_Lease(), _Lease()];
      final entries = [_entry(h, 1), _entry(h, 2)];
      for (var i = 0; i < entries.length; i++) {
        h.coordinator.accept(_candidate(entries[i], leases[i]), entries[i]);
      }
      final writing = h.coordinator.flush(_binding);
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(messages.current, ReadCacheFileCheckpoint.beforeIndexRename.name);
      leases[revoked].revoke();
      release.createSync();
      await writing;
      await messages.cancel();
      final key = (await h.keys.readKey(_account)).value!;
      expect(
        await h.files.readEntry(_account, key, entries[revoked].canonicalKey),
        isNull,
      );
      expect((await h.files.readIndex(_account, key))!.entries, hasLength(1));
      expect(
        await h.files.readEntry(
          _account,
          key,
          entries[1 - revoked].canonicalKey,
        ),
        isNotNull,
      );
      expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
      expect(h.dir().listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
      expect(
        await h.coordinator.lookup(
          DiskLookup(
            bodyKind: ReadCacheBodyKind.text,
            binding: _binding,
            canonicalKey: entries[revoked].canonicalKey,
            lease: _Lease(),
          ),
        ),
        isNull,
      );
      h.coordinator.configure(
        keys: h.keys,
        files: h.files,
        settings: h.settings,
      );
      await _save(h, _entry(h, 3));
      final nextIndex = (await h.files.readIndex(_account, key))!;
      expect(nextIndex.entries, hasLength(2));
      final revokedName = await const ReadCacheCipher().entryFileName(
        key,
        entries[revoked].canonicalKey,
      );
      expect(
        nextIndex.entries.map((entry) => entry.fileName),
        isNot(contains(revokedName)),
      );
      expect(
        await h.files.readEntry(_account, key, entries[revoked].canonicalKey),
        isNull,
      );
    });
  }

  for (final readback in [false, true]) {
    test(
      'FIX1 Codex I3 first key ${readback ? 'readback' : 'write'} retries without rekey',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        expect(await h.recover(), isTrue);
        var unavailable = true;
        h.storage.intercept = (operation, name) async {
          if (name == ReadCacheKeyStore.keyName(_account) &&
              unavailable &&
              (readback
                  ? operation == 'read' && h.storage.keyWrites > 0
                  : operation == 'write')) {
            throw StateError('synthetic unavailable');
          }
        };
        expect(await h.coordinator.activate(_binding), isFalse);
        expect(h.dir().existsSync(), isFalse);
        final roots = h.rootCalls;
        final existing = h.storage.values[ReadCacheKeyStore.keyName(_account)];
        for (final seconds in [1, 5, 30]) {
          final timers = h.clock.pending.where((timer) => !timer.cancelled);
          expect(timers, hasLength(1));
          final scheduled = timers.single;
          expect(
            scheduled.at.difference(h.clock.now),
            Duration(seconds: seconds),
          );
          h.clock.advance(Duration(milliseconds: seconds * 1000 - 1));
          await h.coordinator.quiesced;
          if (readback) expect(h.rootCalls, roots);
          expect(h.dir().existsSync(), isFalse);
          expect(h.storage.keyWrites, readback ? 1 : 0);
          if (seconds == 30) unavailable = false;
          h.clock.advance(const Duration(milliseconds: 1));
          await h.coordinator.quiesced;
        }
        expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
        expect(h.storage.keyWrites, 1);
        if (readback) {
          expect(
            h.storage.values[ReadCacheKeyStore.keyName(_account)],
            existing,
          );
        }
        expect(h.clock.pending.where((timer) => !timer.cancelled), isEmpty);
      },
    );
  }

  test(
    'FIX1 Codex I4 burst of 65 has one flush and bounded index/key work',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      var indexRenames = 0;
      final events = ReceivePort();
      final subscription = events.listen((step) {
        if (step == ReadCacheFileCheckpoint.indexRenamed.name) indexRenames++;
      });
      addTearDown(() async {
        await subscription.cancel();
        events.close();
      });
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _notifyCheckpoints(events.sendPort),
        ),
      );
      final reads = _keyReads(h);
      for (var i = 0; i < 65; i++) {
        final e = _entry(h, i);
        h.coordinator.accept(_candidate(e), e);
      }
      await h.coordinator.quiesced;
      await Future<void>.delayed(Duration.zero);
      expect(indexRenames, 2);
      expect(_keyReads(h) - reads, 2);
      expect(h.coordinator.stats.queuedEntries, 1);
      h.clock.advance(const Duration(milliseconds: 1999));
      await h.coordinator.quiesced;
      expect(indexRenames, 2);
      h.clock.advance(const Duration(milliseconds: 1));
      await h.coordinator.quiesced;
      await Future<void>.delayed(Duration.zero);
      expect(indexRenames, 3);
      expect(_keyReads(h) - reads, 3);
      final key = (await h.keys.readKey(_account)).value!;
      expect((await h.files.readIndex(_account, key))!.entries, hasLength(65));
    },
  );

  test(
    'FIX1 Codex I4 empty non-dirty flush does no key or index work',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final reads = _keyReads(h);
      final roots = h.rootCalls;
      await Future.wait([
        h.coordinator.flush(_binding),
        h.wrapper().flush(_binding),
      ]);
      expect(_keyReads(h), reads);
      expect(h.rootCalls, roots);
      expect(h.dir().existsSync(), isFalse);
    },
  );

  test(
    'FIX1 Codex I4 sustained traffic commits at the two second deadline',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final events = ReceivePort();
      var produced = 32, entriesSinceIndex = 0;
      final batches = <int>[];
      final subscription = events.listen((step) {
        if (step == ReadCacheFileCheckpoint.entryRenamed.name) {
          entriesSinceIndex++;
          if (produced < 80) {
            final e = _entry(h, produced++);
            h.coordinator.accept(_candidate(e), e);
          }
          h.clock.advance(const Duration(milliseconds: 800));
        } else if (step == ReadCacheFileCheckpoint.indexRenamed.name) {
          batches.add(entriesSinceIndex);
          entriesSinceIndex = 0;
        }
      });
      addTearDown(() async {
        await subscription.cancel();
        events.close();
      });
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _notifyCheckpoints(events.sendPort),
        ),
      );
      for (var i = 0; i < 32; i++) {
        final e = _entry(h, i);
        h.coordinator.accept(_candidate(e), e);
      }
      await h.coordinator.quiesced;
      h.clock.advance(const Duration(seconds: 2));
      await h.coordinator.quiesced;
      await h.coordinator.flush(_binding);
      await Future<void>.delayed(Duration.zero);
      expect(produced, 80);
      expect(batches, isNotEmpty);
      expect(batches, everyElement(inInclusiveRange(1, 3)));
      expect(batches.fold(0, (int a, b) => a + b), 80);
    },
  );

  test(
    'FIX1 Opus I1 interrupted reload cannot leave invalidated files readable',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final entries = [
        for (var i = 0; i < 4; i++) _entry(h, i, scopes: {'project:$i'}),
      ];
      for (final e in entries) {
        h.coordinator.accept(_candidate(e), e);
      }
      await h.coordinator.flush(_binding);
      final key = (await h.keys.readKey(_account)).value!;
      final names = {
        for (final e in entries)
          e.canonicalKey: await const ReadCacheCipher().entryFileName(
            key,
            e.canonicalKey,
          ),
      };
      final sorted = names.values.toList()..sort();
      final target = entries.firstWhere(
        (e) => names[e.canonicalKey] == sorted.last,
      );
      final at = Completer<void>(), release = Completer<void>();
      var calls = 0;
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async {
            if (++calls == 4) {
              at.complete();
              await release.future;
            }
            return h.root;
          },
          clock: () => h.clock.now,
        ),
      );
      h.coordinator.background();
      final resuming = h.coordinator.resume(_binding);
      await at.future.timeout(const Duration(seconds: 10));
      h.coordinator.background();
      release.complete();
      expect(await resuming, isFalse);
      final result = await h.coordinator
          .invalidate(_mutation(target.scopeTags.single))
          .barrier;
      expect(
        await h.files.readEntry(_account, key, target.canonicalKey),
        isNull,
      );
      expect(result.complete, isTrue);
      expect(await h.coordinator.resume(_binding), isTrue);
      expect(
        await h.coordinator.lookup(
          DiskLookup(
            bodyKind: ReadCacheBodyKind.text,
            binding: _binding,
            canonicalKey: target.canonicalKey,
            lease: _Lease(),
          ),
        ),
        isNull,
      );
    },
  );

  test(
    'FIX1 Opus I2 barriers after full escalation succeed without new markers',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      File('${h.dir().path}/index.v1.bin').writeAsBytesSync([0]);
      h.coordinator.background();
      expect(await h.coordinator.resume(_binding), isTrue);
      final first = h.coordinator.invalidate(_mutation());
      final overlapping = h.coordinator.invalidate(_mutation('project:2'));
      expect((await first.barrier).complete, isTrue);
      expect((await overlapping.barrier).complete, isTrue);
      final writes = h.storage.markerWrites;
      expect(
        (await h.coordinator.invalidate(_mutation('project:3')).barrier)
            .complete,
        isTrue,
      );
      expect(h.storage.markerWrites, writes);
      expect(
        (await h.keys.readMarker(_account)).status,
        ReadCacheStoreReadStatus.absent,
      );
      expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
    },
  );

  test(
    'FIX1 Opus I2 fresh empty account barrier retains its first key',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final key = (await h.keys.readKey(_account)).value!;
      final writes = h.storage.markerWrites;
      final result = await h.coordinator.invalidate(_mutation()).barrier;
      expect(result.complete, isFalse);
      expect((await h.keys.readKey(_account)).value, key);
      expect(h.storage.markerWrites - writes, 1);
      expect(
        (await h.keys.readMarker(_account)).status,
        ReadCacheStoreReadStatus.absent,
      );
      expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
    },
  );

  test(
    'FIX1 Opus I2 fresh account without controls proves empty before escalation',
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
      expect(await c.recover(_decision, accountKeys: {_account}), isTrue);
      expect(await c.activate(_binding), isFalse);
      expect((await c.invalidate(_mutation()).barrier).complete, isTrue);
      expect(h.storage.markerWrites, 0);
      expect(h.storage.keyWrites, 0);
      expect((await h.keys.readInventory()).markers, isEmpty);
    },
  );

  test(
    'FIX1 Opus I3 concurrent prepare recognises its owned scope marker',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      h.coordinator.background();
      final at = Completer<void>(),
          release = Completer<void>(),
          durable = Completer<void>();
      var held = false;
      h.storage.intercept = (operation, name) async {
        if (operation != 'read' ||
            name != ReadCacheKeyStore.markerName(_account)) {
          return;
        }
        if (!held) {
          held = true;
          at.complete();
          await release.future;
        } else if (h.storage.values.containsKey(name) && !durable.isCompleted) {
          durable.complete();
        }
      };
      final resuming = h.coordinator.resume(_binding);
      await at.future;
      final fence = h.coordinator.invalidate(_mutation());
      // Attach a handler before releasing either competing operation.
      final barrier = expectLater(fence.barrier, completes);
      await durable.future.timeout(const Duration(seconds: 10));
      release.complete();
      expect(await resuming, isTrue);
      await barrier;
      await h.coordinator.quiesced;
      expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
      expect(
        (await h.keys.readMarker(_account)).status,
        ReadCacheStoreReadStatus.absent,
      );
    },
  );

  for (final background in [false, true]) {
    test(
      'FIX1 Opus I4 re-enable preserves ${background ? 'background' : 'foreground'} lifecycle',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        if (background) h.coordinator.background();
        expect(await h.coordinator.setEnabled(false), isTrue);
        expect(await h.coordinator.setEnabled(true), isTrue);
        expect(await h.recover(), isTrue);
        const next = DiskBinding(accountKey: _account, generation: 2);
        expect(await h.coordinator.activate(next), !background);
        if (background) expect(await h.coordinator.resume(next), isTrue);
      },
    );
  }
  test(
    'FIX1 Opus m2 expired queued intent cannot persist a late marker',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final keyAt = Completer<void>(), keyRelease = Completer<void>();
      final markerAt = Completer<void>(), markerRelease = Completer<void>();
      var heldKey = false, heldMarker = false;
      h.storage.intercept = (operation, name) async {
        if (operation == 'read' &&
            name == ReadCacheKeyStore.keyName(_account) &&
            !heldKey) {
          heldKey = true;
          keyAt.complete();
          await keyRelease.future;
        }
        if (operation == 'write' &&
            name == ReadCacheKeyStore.markerName(_account) &&
            !heldMarker) {
          heldMarker = true;
          markerAt.complete();
          await markerRelease.future;
        }
      };
      final activation = h.coordinator.activate(_binding);
      await keyAt.future;
      final first = h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.mutation,
      );
      await markerAt.future;
      final second = h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.mutation,
      );
      h.clock.advance(const Duration(seconds: 5));
      expect((await first).complete, isFalse);
      expect((await second).complete, isFalse);
      markerRelease.complete();
      keyRelease.complete();
      await activation;
      await h.coordinator.quiesced;
      expect(h.storage.markerWrites, 1);
    },
  );

  test(
    'FIX1 Opus m3 timed-out empty clear cannot reopen on new activation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await h.recover(), isTrue);
      final at = Completer<void>(), release = Completer<void>();
      var held = false;
      h.storage.intercept = (operation, name) async {
        if (operation == 'inventory' && !held) {
          held = true;
          at.complete();
          await release.future;
        }
      };
      final clearing = h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.mutation,
      );
      await at.future;
      h.clock.advance(const Duration(seconds: 5));
      expect((await clearing).complete, isFalse);
      release.complete();
      await h.coordinator.quiesced;
      expect(
        await h.coordinator.activate(
          const DiskBinding(accountKey: _account, generation: 2),
        ),
        isFalse,
      );
      expect(
        h.coordinator.notice(_binding)!.failure.cleanup!.code,
        ReadCacheCleanupCode.barrierTimedOut,
      );
    },
  );

  test(
    'FIX1 Opus m5 settings clear preserves a failed-removal session fence',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      expect(
        (await h.coordinator.clear(
          _binding,
          ReadCacheCleanupOperation.accountRemoval,
        )).complete,
        isTrue,
      );
      expect(
        (await h.coordinator.clear(
          const DiskBinding(accountKey: _account, generation: 0),
          ReadCacheCleanupOperation.settingsClear,
        )).complete,
        isTrue,
      );
      expect(await h.coordinator.activate(_binding), isFalse);
    },
  );
}

void _fix2Tests() {
  for (var count = 2; count < ReadCacheDiskCoordinator.batchEntries; count++) {
    test('FIX2 N1 timer indexes $count entries in one batch', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final events = ReceivePort();
      var indexRenames = 0;
      final subscription = events.listen((step) {
        if (step == ReadCacheFileCheckpoint.indexRenamed.name) indexRenames++;
      });
      addTearDown(() async {
        await subscription.cancel();
        events.close();
      });
      h.coordinator.configure(
        keys: h.keys,
        settings: h.settings,
        files: ReadCacheFileStore(
          root: () async => h.root,
          clock: () => h.clock.now,
          checkpoint: _notifyCheckpoints(events.sendPort),
        ),
      );
      for (var i = 0; i < count; i++) {
        final entry = _entry(h, i);
        h.coordinator.accept(_candidate(entry), entry);
      }
      h.clock.advance(ReadCacheDiskCoordinator.batchDelay);
      await h.coordinator.quiesced;
      await Future<void>.delayed(Duration.zero);
      final key = (await h.keys.readKey(_account)).value!;
      expect(
        (await h.files.readIndex(_account, key))!.entries,
        hasLength(count),
      );
      expect(indexRenames, 1);
      expect(h.coordinator.stats.queuedEntries, 0);
      expect(h.clock.pending.where((timer) => !timer.cancelled), isEmpty);
    });
  }

  test('FIX2 N1 forced overdue flush drains full 32-entry batches', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _readyHarness(h);
    final events = ReceivePort();
    final batches = <int>[];
    var entriesSinceIndex = 0;
    final subscription = events.listen((step) {
      if (step == ReadCacheFileCheckpoint.entryRenamed.name) {
        entriesSinceIndex++;
      } else if (step == ReadCacheFileCheckpoint.indexRenamed.name) {
        batches.add(entriesSinceIndex);
        entriesSinceIndex = 0;
      }
    });
    addTearDown(() async {
      await subscription.cancel();
      events.close();
    });
    h.coordinator.configure(
      keys: h.keys,
      settings: h.settings,
      files: ReadCacheFileStore(
        root: () async => h.root,
        clock: () => h.clock.now,
        checkpoint: _notifyCheckpoints(events.sendPort),
      ),
    );
    final at = Completer<void>(), release = Completer<void>();
    var held = false;
    h.storage.intercept = (operation, name) async {
      if (operation == 'read' &&
          name == ReadCacheKeyStore.keyName(_account) &&
          !held) {
        held = true;
        at.complete();
        await release.future;
      }
    };
    final reading = h.coordinator.lookup(
      DiskLookup(
        bodyKind: ReadCacheBodyKind.text,
        binding: _binding,
        canonicalKey: _entry(h, 99).canonicalKey,
        lease: _Lease(),
      ),
    );
    await at.future;
    for (var i = 0; i < 65; i++) {
      final entry = _entry(h, i);
      h.coordinator.accept(_candidate(entry), entry);
    }
    h.clock.advance(ReadCacheDiskCoordinator.batchDelay);
    final writing = h.coordinator.flush(_binding);
    release.complete();
    await reading;
    await writing;
    await Future<void>.delayed(Duration.zero);
    expect(batches, [32, 32, 1]);
    expect(h.coordinator.stats.queuedEntries, 0);
    final key = (await h.keys.readKey(_account)).value!;
    expect((await h.files.readIndex(_account, key))!.entries, hasLength(65));
  });

  for (final background in [false, true]) {
    test(
      'FIX2 N2 unrelated barriers preserve cache after revoked index; background=$background',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        final retained = _entry(h, 0, scopes: {'project:0'});
        await _save(h, retained);
        final keyBefore = (await h.keys.readKey(_account)).value!;
        final events = ReceivePort();
        final messages = StreamIterator<Object?>(events);
        addTearDown(events.close);
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
        final leases = [_Lease(), _Lease()];
        final entries = [
          _entry(h, 1, scopes: {'project:1'}),
          _entry(h, 2, scopes: {'project:2'}),
        ];
        for (var i = 0; i < entries.length; i++) {
          h.coordinator.accept(_candidate(entries[i], leases[i]), entries[i]);
        }
        final writing = h.coordinator.flush(_binding);
        expect(
          await messages.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        expect(
          messages.current,
          ReadCacheFileCheckpoint.beforeIndexRename.name,
        );
        if (background) {
          h.coordinator.background();
        } else {
          leases[1].revoke();
        }
        release.createSync();
        await writing;
        await messages.cancel();
        h.coordinator.configure(
          keys: h.keys,
          files: h.files,
          settings: h.settings,
        );
        // No new accept/save/flush may mask the stale unindexed publication.
        for (final scope in ['project:99', 'project:98']) {
          final result = await h.coordinator
              .invalidate(
                DiskInvalidation(
                  binding: _binding,
                  kind: DiskInvalidationKind.mutation,
                  scopeTags: {scope},
                ),
              )
              .barrier;
          expect(result.complete, isFalse); // Scoped success retains the key.
          expect(h.coordinator.notice(_binding), isNull);
        }
        final key = (await h.keys.readKey(_account)).value!;
        expect(key, orderedEquals(keyBefore));
        expect(
          await h.files.readEntry(_account, key, retained.canonicalKey),
          isNotNull,
        );
        expect(
          await h.files.readEntry(_account, key, entries[1].canonicalKey),
          isNull,
        );
        expect(
          await h.files.readEntry(_account, key, entries[0].canonicalKey),
          background ? isNull : isNotNull,
        );
        expect(
          (await h.files.readIndex(_account, key))!.entries,
          hasLength(background ? 1 : 2),
        );
        expect((await h.keys.readMarker(_account)).isFound, isFalse);
      },
    );
  }

  test(
    'FIX2 N2 flush evicts and retries a revoked publication without new work',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final events = ReceivePort();
      final messages = StreamIterator<Object?>(events);
      addTearDown(events.close);
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
      final lease = _Lease();
      final retained = _entry(h, 1), revoked = _entry(h, 2);
      h.coordinator.accept(_candidate(retained), retained);
      h.coordinator.accept(_candidate(revoked, lease), revoked);
      final writing = h.coordinator.flush(_binding);
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      lease.revoke();
      release.createSync();
      await writing;
      await messages.cancel();
      final key = (await h.keys.readKey(_account)).value!;
      expect((await h.files.readIndex(_account, key))?.entries, hasLength(1));
      expect(
        await h.files.readEntry(_account, key, revoked.canonicalKey),
        isNull,
      );
      expect(
        await h.files.readEntry(_account, key, retained.canonicalKey),
        isNotNull,
      );
      expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
    },
  );

  test('FIX2 N2 refused dirty index retains a timer without queued work', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _readyHarness(h);
    final events = ReceivePort();
    final messages = StreamIterator<Object?>(events);
    addTearDown(events.close);
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
    final entry = _entry(h, 1);
    h.coordinator.accept(_candidate(entry), entry);
    final writing = h.coordinator.flush(_binding);
    expect(
      await messages.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    // A barrier changes indexRevision while the first index is staged. Hold its
    // marker so its serial section cannot repair the dirty index before inspection.
    final markerAt = Completer<void>(), markerRelease = Completer<void>();
    h.storage.intercept = (operation, name) async {
      if (operation == 'write' &&
          name == ReadCacheKeyStore.markerName(_account)) {
        markerAt.complete();
        await markerRelease.future;
      }
    };
    final barrier = h.coordinator
        .invalidate(
          DiskInvalidation(
            binding: _binding,
            kind: DiskInvalidationKind.mutation,
            scopeTags: {'project:99'},
          ),
        )
        .barrier;
    await markerAt.future;
    release.createSync();
    await writing;
    final hasTimer = h.clock.pending.any(
      (timer) =>
          !timer.cancelled &&
          timer.at == h.clock.now.add(ReadCacheDiskCoordinator.batchDelay),
    );
    markerRelease.complete();
    await barrier;
    await messages.cancel();
    expect(hasTimer, isTrue);
    expect(h.coordinator.stats.queuedEntries, 0);
  });

  for (final variant in [
    'secondBarrierMatchesUnindexed',
    'background',
    'newPublicationRevokes',
    'controlStaleBeforeBarrierCommit',
  ]) {
    test('C2FU R3A scoped commit retries stale leases: $variant', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final retained = _entry(h, 0, scopes: {'project:0'});
      await _save(h, retained);
      final keyBefore = (await h.keys.readKey(_account)).value!;
      final events = ReceivePort();
      final messages = StreamIterator<Object?>(events);
      addTearDown(events.close);
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
      final leases = [_Lease(), _Lease()];
      final staged = [
        _entry(h, 1, scopes: {'project:1'}),
        _entry(h, 2, scopes: {'project:2'}),
      ];
      for (var i = 0; i < staged.length; i++) {
        h.coordinator.accept(_candidate(staged[i], leases[i]), staged[i]);
      }
      final writing = h.coordinator.flush(_binding);
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      final keyAt = Completer<void>(), keyRelease = Completer<void>();
      var held = false;
      h.storage.intercept = (operation, name) async {
        if (operation == 'read' &&
            name == ReadCacheKeyStore.keyName(_account) &&
            !held) {
          held = true;
          keyAt.complete();
          await keyRelease.future;
        }
      };
      final first = h.coordinator
          .invalidate(
            DiskInvalidation(
              binding: _binding,
              kind: DiskInvalidationKind.mutation,
              scopeTags: {'project:99'},
            ),
          )
          .barrier;
      release.createSync();
      await writing;
      await keyAt.future;
      release.deleteSync();
      if (variant == 'controlStaleBeforeBarrierCommit') leases[1].revoke();
      keyRelease.complete();
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(messages.current, ReadCacheFileCheckpoint.beforeIndexRename.name);
      Future<DiskClearResult>? second;
      switch (variant) {
        case 'secondBarrierMatchesUnindexed':
          second = h.coordinator
              .invalidate(
                DiskInvalidation(
                  binding: _binding,
                  kind: DiskInvalidationKind.mutation,
                  scopeTags: {'project:1'},
                ),
              )
              .barrier;
        case 'background':
          h.coordinator.background();
        case 'newPublicationRevokes':
          leases[1].revoke();
      }
      release.createSync();
      final result = await first;
      if (second != null) await second;
      await messages.cancel();
      expect(result.complete, isFalse);
      expect(result.keyGoneConfirmed, isFalse);
      expect((await h.keys.readKey(_account)).value, orderedEquals(keyBefore));
      expect((await h.keys.readMarker(_account)).isFound, isFalse);
      expect(
        await h.files.readEntry(_account, keyBefore, retained.canonicalKey),
        isNotNull,
      );
      for (var i = 0; i < staged.length; i++) {
        final revoked =
            variant == 'background' ||
            (variant == 'secondBarrierMatchesUnindexed' ? i == 0 : i == 1);
        expect(
          await h.files.readEntry(_account, keyBefore, staged[i].canonicalKey),
          revoked ? isNull : isNotNull,
        );
      }
      final index = (await h.files.readIndex(_account, keyBefore))!;
      expect(index.entries.length, variant == 'background' ? 1 : 2);
      expect(h.coordinator.notice(_binding), isNull);
      h.coordinator.configure(
        keys: h.keys,
        files: h.files,
        settings: h.settings,
      );
      if (variant == 'background') {
        expect(await h.coordinator.resume(_binding), isTrue);
      }
      expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
      await _save(h, _entry(h, 7, scopes: {'project:7'}));
      expect(
        (await h.files.readIndex(_account, keyBefore))!.entries.length,
        index.entries.length + 1,
      );
    });
  }

  test(
    'FIX2 N2 expired scoped commit cannot dispatch a late full clear',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      await _save(h, _entry(h, 1));
      final keyBefore = (await h.keys.readKey(_account)).value!;
      final events = ReceivePort();
      final messages = StreamIterator<Object?>(events);
      addTearDown(events.close);
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
      final outcome = h.coordinator
          .invalidate(
            DiskInvalidation(
              binding: _binding,
              kind: DiskInvalidationKind.mutation,
              scopeTags: {'project:99'},
            ),
          )
          .barrier
          .then<Object>((result) => result, onError: (Object error) => error);
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      final markers = h.storage.markerWrites;
      h.clock.advance(ReadCacheDiskCoordinator.barrierLimit);
      expect(
        await outcome,
        isA<ApiFailure>().having(
          (e) => e.cleanup?.code,
          'code',
          ReadCacheCleanupCode.barrierTimedOut,
        ),
      );
      release.createSync();
      await h.coordinator.quiesced;
      await messages.cancel();
      expect(h.storage.markerWrites, markers);
      expect((await h.keys.readKey(_account)).value, orderedEquals(keyBefore));
      expect(h.dir().existsSync(), isTrue);
      expect(
        h.coordinator.notice(_binding)!.failure.cleanup!.code,
        ReadCacheCleanupCode.barrierTimedOut,
      );
      // The timeout's valid full intent is still owned by a subsequent caller.
      expect(
        (await h.coordinator
                .invalidate(
                  DiskInvalidation(
                    binding: _binding,
                    kind: DiskInvalidationKind.mutation,
                    scopeTags: {'project:98'},
                  ),
                )
                .barrier)
            .complete,
        isTrue,
      );
    },
  );

  test('FIX2 N3 settings clear reopens a newer verified generation', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _readyHarness(h);
    expect(
      (await h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.signOut,
      )).complete,
      isTrue,
    );
    const next = DiskBinding(accountKey: _account, generation: 2);
    expect(await h.coordinator.activate(next), isTrue);
    expect(
      (await h.coordinator.clear(
        next,
        ReadCacheCleanupOperation.settingsClear,
      )).complete,
      isTrue,
    );
    await h.coordinator.quiesced;
    await Future<void>.delayed(Duration.zero);
    await h.coordinator.quiesced;
    expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
    final entry = _entry(h, 5);
    h.coordinator.accept(
      DiskWriteCandidate(
        binding: next,
        uri: Uri.parse('https://synthetic.example/subpath/api/v4/projects/1'),
        logicalAccept: 'text/plain',
        bodyKind: entry.bodyKind,
        fetchedAt: entry.fetchedAt,
        responseBytes: entry.serializedLength,
        lease: _Lease(),
        cacheable: true,
        noStore: false,
        firstPage: true,
        scopeTags: entry.scopeTags,
      ),
      entry,
    );
    await h.coordinator.flush(next);
    final key = (await h.keys.readKey(_account)).value!;
    expect((await h.files.readIndex(_account, key))!.entries, hasLength(1));
    expect(await h.coordinator.setEnabled(false), isTrue);
    expect(await h.coordinator.setEnabled(true), isTrue);
    expect(await h.recover(), isTrue);
    expect(await h.coordinator.activate(next), isTrue);
  });

  for (final markerFailure in [false, true]) {
    test(
      'FIX2 N4 failed inventory sweep reports cleanup and recovers its intents; markerFailure=$markerFailure',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await _readyHarness(h);
        await _save(h, _entry(h, 1));
        h.storage.failInventory = true;
        h.storage.failMarkerWrite = markerFailure;
        expect(await h.coordinator.setEnabled(false), isFalse);
        final notice = h.coordinator.notice(_binding)?.failure.cleanup;
        final markerAfterFailure = (await h.keys.readMarker(_account)).isFound;
        h.storage.failInventory = false;
        h.storage.failMarkerWrite = false;
        expect(await h.coordinator.setEnabled(true), isTrue);
        expect(await h.recover(), isTrue);
        const next = DiskBinding(accountKey: _account, generation: 2);
        final activated = await h.coordinator.activate(next);
        final resumed = await h.coordinator.resume(next);
        expect(
          {
            'activated': activated,
            'resumed': resumed,
            'notice': notice?.code,
            'operation': notice?.operation,
            'markerAfterFailure': markerAfterFailure,
          },
          {
            'activated': true,
            'resumed': true,
            'notice': ReadCacheCleanupCode.cleanupFailed,
            'operation': ReadCacheCleanupOperation.settingsClear,
            'markerAfterFailure': !markerFailure,
          },
        );
        expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
        expect((await h.keys.readMarker(_account)).isFound, isFalse);
      },
    );
  }

  test(
    'FIX2 N5 barrier completes the disable sweep intent before its owner',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _readyHarness(h);
      final entry = _entry(h, 1);
      await _save(h, entry);
      final keyAt = Completer<void>(), keyRelease = Completer<void>();
      final settingAt = Completer<void>(), settingRelease = Completer<void>();
      var heldKey = false, heldSetting = false;
      h.storage.intercept = (operation, name) async {
        if (operation == 'read' &&
            name == ReadCacheKeyStore.keyName(_account) &&
            !heldKey) {
          heldKey = true;
          keyAt.complete();
          await keyRelease.future;
        }
        if (operation == 'write' &&
            name == ReadCacheSettingsStore.key &&
            !heldSetting) {
          heldSetting = true;
          settingAt.complete();
          await settingRelease.future;
        }
      };
      final reading = h.coordinator.lookup(
        DiskLookup(
          bodyKind: ReadCacheBodyKind.text,
          binding: _binding,
          canonicalKey: entry.canonicalKey,
          lease: _Lease(),
        ),
      );
      await keyAt.future;
      final disabling = h.coordinator.setEnabled(false);
      await settingAt.future;
      final barrier = h.coordinator
          .invalidate(
            DiskInvalidation(
              binding: _binding,
              kind: DiskInvalidationKind.mutation,
              scopeTags: {'project:1'},
            ),
          )
          .barrier;
      settingRelease.complete();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      keyRelease.complete();
      await reading;
      final result = await barrier;
      final disabled = await disabling;
      expect(result.complete, isTrue);
      expect(disabled, isTrue);
      expect(h.coordinator.state(_account), ReadCacheDiskState.disabled);
      final inventory = await h.keys.readInventory();
      expect(inventory.keys, isEmpty);
      expect(inventory.markers, isEmpty);
      expect(await h.files.accountDirectoryNames(), isEmpty);
    },
  );
}

void main() {
  _pathFailureTests();
  TestWidgetsFlutterBinding.ensureInitialized();
  _fix1Tests();
  _fix2Tests();
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

  for (final doubleFailure in [false, true]) {
    test(
      'real removal hook preserves AI snapshot; doubleFailure=$doubleFailure',
      () async {
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
        await _save(h, _entry(h, 1));
        final assertAi = _snapshotAi(h);
        var hookReached = false, aiClearCalls = 0;
        accountStore.rejectWrite = !doubleFailure;
        h.storage.failKeyDelete = doubleFailure;
        h.failRoot = doubleFailure;
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
          clearReadCacheDisk: (saved) async {
            hookReached = true;
            assertAi();
            try {
              await h.coordinator.clearReadCacheDisk(saved.key);
            } finally {
              assertAi();
            }
          },
          clearAi: (_) async {
            assertAi();
            aiClearCalls++;
          },
        );
        expect(hookReached, isTrue);
        assertAi();
        expect(aiClearCalls, doubleFailure ? 0 : 1);
        expect(result.status, AiRemovalStatus.notRemoved);
        expect(
          result.reason,
          doubleFailure ? 'beforeAiCleanupFailed' : 'accountRetained',
        );
        if (doubleFailure) {
          expect(result.error, same(h.coordinator.notice(_binding)!.failure));
          expect(accountStore.accounts, [account]);
          expect((await h.keys.readMarker(_account)).isFound, isTrue);
        }
        expect(session.accounts, [account]);
        expect(h.coordinator.state(_account), ReadCacheDiskState.cleaning);
        expect(await h.coordinator.activate(_binding), isFalse);
        expect(
          (await h.keys.readKey(_account)).status,
          doubleFailure
              ? ReadCacheStoreReadStatus.found
              : ReadCacheStoreReadStatus.absent,
        );
      },
    );
  }

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
