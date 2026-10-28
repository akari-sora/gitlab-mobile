import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_reader.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/repository_reader.dart';

const binding = DiskBinding(
  accountKey: 'https://example.test#1',
  generation: 1,
);
const jobId = '0123456789abcdef0123456789abcdef';
const otherId = 'abcdef0123456789abcdef0123456789';
const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

SnapshotRecord completeRecord(int projectId, String id, DateTime now) =>
    SnapshotRecord(
      id: id,
      projectId: projectId,
      projectPath: 'group/project',
      projectName: 'project',
      defaultBranch: 'main',
      refKind: SnapshotRefKind.branch,
      refName: 'main',
      sha: sha,
      objectFormat: SnapshotObjectFormat.sha1,
      subPath: '',
      commitTitle: 'title',
      committedAt: now,
      status: SnapshotStatus.complete,
      createdAt: now,
      savedAt: now,
    );

final class MemoryKeys implements OfflineRepositoryKeys {
  Uint8List? value = Uint8List(32);
  bool marker = false;
  bool unavailable = false;
  Completer<void>? readGate, readStarted;
  bool readDelayed = false;
  @override
  Future<OfflineKeyRead> read(String accountKey) async {
    if (readGate != null && !readDelayed) {
      readDelayed = true;
      readStarted!.complete();
      await readGate!.future;
    }
    return unavailable
        ? const OfflineKeyRead(OfflineKeyStatus.unavailable)
        : value == null
        ? const OfflineKeyRead(OfflineKeyStatus.absent)
        : OfflineKeyRead(OfflineKeyStatus.found, value);
  }

  @override
  Future<void> write(String accountKey, Uint8List bytes) async {
    value = bytes;
  }

  @override
  Future<void> delete(String accountKey) async {
    value = null;
  }

  @override
  Future<bool> hasMarker(String accountKey) async => marker;
  @override
  Future<void> writeMarker(String accountKey, String operationId) async {
    marker = true;
  }

  @override
  Future<void> deleteMarker(String accountKey) async {
    marker = false;
  }
}

void main() {
  late Directory root;
  late MemoryKeys keys;
  late OfflineRepositoryCoordinator coordinator;
  setUp(() {
    root = Directory.systemTemp.createTempSync('c3-coordinator-');
    keys = MemoryKeys();
    coordinator = OfflineRepositoryCoordinator();
    coordinator.configure(
      keys: keys,
      supportRoot: () async => root,
      deleteDirectory: (_) async {
        final namespace = Directory('${root.path}/offline_repo');
        if (namespace.existsSync()) namespace.deleteSync(recursive: true);
      },
    );
    coordinator.open(binding);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('job admission waits for in-progress account maintenance', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final permit = coordinator.capture(binding, 0);
    final maintenance = coordinator.maintain<void>(permit, (_, _) async {
      started.complete();
      await release.future;
    });
    await started.future;
    var admitted = false;
    final pending = coordinator
        .registerJob(binding, 1, jobId, cancel: () {}, stop: () async {})
        .then((p) {
          admitted = true;
          return p;
        });
    await Future<void>.delayed(Duration.zero);
    expect(admitted, isFalse);
    release.complete();
    await maintenance;
    final job = await pending;
    expect(admitted, isTrue);
    coordinator.finishJob(job);
  });

  test('invalidated job completion releases its own registration', () async {
    final first = await coordinator.registerJob(
      binding,
      1,
      jobId,
      cancel: () {},
      stop: () async {},
    );
    coordinator.invalidateJob(first);
    coordinator.finishJob(first);
    final second = await coordinator.registerJob(
      binding,
      1,
      jobId,
      cancel: () {},
      stop: () async {},
    );
    coordinator.finishJob(first);
    expect(second.isCurrent, isTrue);
    coordinator.finishJob(second);
  });

  test('validation waits for removal of the same project', () async {
    final stopped = Completer<void>();
    final first = await coordinator.registerJob(
      binding,
      1,
      jobId,
      cancel: () {},
      stop: () => stopped.future,
    );
    final one = coordinator.permissionRemoval(binding, 1);
    final two = coordinator.permissionRemoval(binding, 2);
    await two;
    final validation = coordinator.projectValidated(binding, 1);
    await Future<void>.delayed(Duration.zero);
    expect(
      () => coordinator.capture(binding, 1),
      throwsA(
        isA<SnapshotOperationException>().having(
          (e) => e.failure,
          'failure',
          SnapshotFailure.accessLost,
        ),
      ),
    );
    stopped.complete();
    await one;
    await validation;
    coordinator.finishJob(first);
    expect(coordinator.capture(binding, 1).isCurrent, isTrue);
  });

  test('unavailable secure storage closes a previously cached key', () async {
    final now = DateTime.utc(2026, 10, 28);
    final permit = coordinator.capture(binding, 0);
    await coordinator.maintain<void>(permit, (store, index) async {
      await store.writeIndex(
        SnapshotIndex(
          accountKey: binding.accountKey,
          lastValidatedAt: now,
          consentAt: now,
          snapshots: [],
        ),
        expectedRevision: store.revision,
        mayCommit: () => permit.isCurrent,
      );
    });
    final before = root.listSync(recursive: true).map((e) => e.path).toSet();
    keys.unavailable = true;
    await expectLater(
      coordinator.snapshots(binding),
      throwsA(
        isA<SnapshotOperationException>().having(
          (e) => e.failure,
          'failure',
          SnapshotFailure.keyUnavailable,
        ),
      ),
    );
    expect(
      coordinator.state(binding.accountKey),
      OfflineRepositoryState.unavailable,
    );
    expect(root.listSync(recursive: true).map((e) => e.path).toSet(), before);
    expect(keys.value, isNotNull);
  });

  test('explicit clear removes a newer schema without parsing it', () async {
    final now = DateTime.utc(2026, 10, 28);
    final permit = coordinator.capture(binding, 0);
    late String path;
    await coordinator.maintain<void>(permit, (store, index) async {
      await store.writeIndex(
        SnapshotIndex(
          accountKey: binding.accountKey,
          lastValidatedAt: now,
          consentAt: now,
          snapshots: [],
        ),
        expectedRevision: store.revision,
        mayCommit: () => permit.isCurrent,
      );
      path = '${store.accountDirectory}/index.v1.bin';
    });
    final data = File(path).readAsBytesSync()..[0] = 2;
    File(path).writeAsBytesSync(data);
    await expectLater(
      coordinator.snapshots(binding),
      throwsA(
        isA<SnapshotStoreException>().having(
          (e) => e.code,
          'code',
          SnapshotStoreError.newerSchema,
        ),
      ),
    );
    expect(
      coordinator.state(binding.accountKey),
      OfflineRepositoryState.needsNewerApp,
    );
    await coordinator.clearAll(binding);
    expect(File(path).existsSync(), isFalse);
    expect(keys.value, isNull);
    expect(keys.marker, isFalse);
    expect(coordinator.state(binding.accountKey), OfflineRepositoryState.ready);
  });

  test(
    'key failure still deletes directory and retains cleanup marker',
    () async {
      final now = DateTime.utc(2026, 10, 28);
      final permit = coordinator.capture(binding, 0);
      late String directory;
      await coordinator.maintain<void>(permit, (store, index) async {
        await store.writeIndex(
          SnapshotIndex(
            accountKey: binding.accountKey,
            lastValidatedAt: now,
            consentAt: now,
            snapshots: [],
          ),
          expectedRevision: store.revision,
          mayCommit: () => permit.isCurrent,
        );
        directory = store.accountDirectory;
      });
      keys.unavailable = true;
      await expectLater(
        coordinator.clearAll(binding),
        throwsA(isA<SnapshotOperationException>()),
      );
      expect(Directory(directory).existsSync(), isFalse);
      expect(keys.marker, isTrue);
      expect(
        coordinator.state(binding.accountKey),
        OfflineRepositoryState.cleaning,
      );
      keys.unavailable = false;
      await coordinator.clearAll(binding);
      expect(keys.marker, isFalse);
      expect(
        coordinator.state(binding.accountKey),
        OfflineRepositoryState.ready,
      );
    },
  );

  test('failed permission removal leaves a durable namespace clear', () async {
    final now = DateTime.utc(2026, 10, 28);
    final permit = coordinator.capture(binding, 0);
    late String directory;
    await coordinator.maintain<void>(permit, (store, index) async {
      await store.writeIndex(
        SnapshotIndex(
          accountKey: binding.accountKey,
          lastValidatedAt: now,
          consentAt: now,
          snapshots: [],
        ),
        expectedRevision: store.revision,
        mayCommit: () => permit.isCurrent,
      );
      directory = store.accountDirectory;
    });
    keys.unavailable = true;
    await expectLater(
      coordinator.permissionRemoval(binding, 1),
      throwsA(isA<SnapshotOperationException>()),
    );
    expect(keys.marker, isTrue);
    expect(Directory(directory).existsSync(), isFalse);
    expect(
      coordinator.state(binding.accountKey),
      OfflineRepositoryState.cleaning,
    );
  });

  test(
    'permission loss fences readers and removes only that project',
    () async {
      final now = DateTime.utc(2026, 10, 28);
      final permit = coordinator.capture(binding, 0);
      late String removedTree;
      await coordinator.maintain<void>(permit, (store, index) async {
        for (final id in [jobId, otherId]) {
          await store.writeTree(
            SnapshotTree(snapshotId: id, sha: sha, subPath: '', entries: []),
            format: SnapshotObjectFormat.sha1,
            complete: true,
            mayCommit: () => permit.isCurrent,
          );
        }
        await store.writeIndex(
          SnapshotIndex(
            accountKey: binding.accountKey,
            lastValidatedAt: now,
            consentAt: now,
            snapshots: [
              completeRecord(1, jobId, now),
              completeRecord(2, otherId, now),
            ],
          ),
          expectedRevision: store.revision,
          mayCommit: () => permit.isCurrent,
        );
        removedTree =
            '${store.accountDirectory}/${SnapshotStore.treeFileName(jobId)}';
      });
      final reader = SnapshotRepositoryReader(
        coordinator: coordinator,
        owner: const ReaderOwner(
          accountKey: 'https://example.test#1',
          generation: 1,
          instanceKey: 'https://example.test',
          projectId: 1,
          sha: sha,
          subPath: '',
          snapshotId: jobId,
        ),
      );
      final removal = coordinator.permissionRemoval(binding, 1);
      expect(
        reader.checkCurrent,
        throwsA(
          isA<SnapshotOperationException>().having(
            (e) => e.failure,
            'failure',
            SnapshotFailure.accessLost,
          ),
        ),
      );
      await removal;
      expect(File(removedTree).existsSync(), isFalse);
      final remaining = await coordinator.snapshots(binding);
      expect(remaining.map((s) => s.id), [otherId]);
      final index = await coordinator.maintain<SnapshotIndex>(
        coordinator.capture(binding, 0),
        (_, index) async => index!,
      );
      expect(index!.removedNotice!.count, 1);
      expect(index.gcPending, isTrue);
    },
  );

  test('backup exclusion is retried after the namespace is created', () async {
    var sawAccountDirectory = false;
    coordinator.configure(
      keys: keys,
      supportRoot: () async => root,
      deleteDirectory: (_) async {},
      excludeBackup: (support, account) async {
        final base = Directory('${support.path}/offline_repo');
        sawAccountDirectory = base.existsSync() && base.listSync().isNotEmpty;
      },
    );
    final now = DateTime.utc(2026, 10, 28);
    final permit = coordinator.capture(binding, 0);
    await coordinator.maintain<void>(permit, (store, index) async {
      await store.writeIndex(
        SnapshotIndex(
          accountKey: binding.accountKey,
          lastValidatedAt: now,
          consentAt: now,
          snapshots: [],
        ),
        expectedRevision: store.revision,
        mayCommit: () => permit.isCurrent,
      );
    });
    expect(sawAccountDirectory, isTrue);
  });

  test(
    'new generation completes activation after a stale activation',
    () async {
      final separateRoot = Directory.systemTemp.createTempSync(
        'c3-activation-',
      );
      addTearDown(() => separateRoot.deleteSync(recursive: true));
      final old = DateTime.utc(2020);
      final now = DateTime.utc(2026, 10, 28);
      final stored = SnapshotStore(
        supportRoot: separateRoot,
        accountKey: binding.accountKey,
        rootKey: Uint8List(32),
      );
      await stored.writeIndex(
        SnapshotIndex(
          accountKey: binding.accountKey,
          lastValidatedAt: old,
          consentAt: old,
          snapshots: [],
        ),
        expectedRevision: 0,
        mayCommit: () => true,
      );
      final gatedKeys = MemoryKeys()
        ..readGate = Completer<void>()
        ..readStarted = Completer<void>();
      final owner = OfflineRepositoryCoordinator(clock: () => now);
      owner.configure(
        keys: gatedKeys,
        supportRoot: () async => separateRoot,
        deleteDirectory: (_) async {},
      );
      owner.open(binding);
      await gatedKeys.readStarted!.future;
      const newer = DiskBinding(
        accountKey: 'https://example.test#1',
        generation: 2,
      );
      owner.open(newer);
      gatedKeys.readGate!.complete();
      await owner.snapshots(newer);
      final index = await owner.maintain<SnapshotIndex>(
        owner.capture(newer, 0),
        (_, index) async => index!,
      );
      expect(index!.lastValidatedAt, now);
    },
  );

  test('offline read does not initiate cleanup of a corrupt index', () async {
    final separateRoot = Directory.systemTemp.createTempSync('c3-read-only-');
    addTearDown(() => separateRoot.deleteSync(recursive: true));
    final stored = SnapshotStore(
      supportRoot: separateRoot,
      accountKey: binding.accountKey,
      rootKey: Uint8List(32),
    );
    final now = DateTime.utc(2026, 10, 28);
    await stored.writeIndex(
      SnapshotIndex(
        accountKey: binding.accountKey,
        lastValidatedAt: now,
        consentAt: now,
        snapshots: [],
      ),
      expectedRevision: 0,
      mayCommit: () => true,
    );
    final file = File('${stored.accountDirectory}/index.v1.bin');
    final bytes = file.readAsBytesSync()..[30] ^= 1;
    file.writeAsBytesSync(bytes);
    final localKeys = MemoryKeys();
    final owner = OfflineRepositoryCoordinator();
    owner.configure(
      keys: localKeys,
      supportRoot: () async => separateRoot,
      deleteDirectory: (_) async =>
          Directory(stored.accountDirectory).deleteSync(recursive: true),
    );
    owner.open(binding, readOnly: true);
    await expectLater(
      owner.snapshots(binding),
      throwsA(isA<SnapshotStoreException>()),
    );
    expect(file.existsSync(), isTrue);
    expect(localKeys.value, isNotNull);
    expect(localKeys.marker, isFalse);
    expect(
      owner.state(binding.accountKey),
      OfflineRepositoryState.offlineReadOnly,
    );
  });
}
