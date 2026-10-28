import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';

import '../read_cache_c3_prereq_test.dart' as c2;
import 'coordinator_regression_test.dart' show completeRecord, jobId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late c2.Harness h;
  late Object owner;
  final now = DateTime.utc(2026, 10, 28);

  setUp(() async {
    h = c2.Harness();
    owner = Object();
    h.cache.claimStartupSession(owner);
    await h.keys.writeOfflineKey(c2.account, Uint8List(32));
    final store = SnapshotStore(
      supportRoot: h.root,
      accountKey: c2.account,
      rootKey: Uint8List(32),
    );
    final record = completeRecord(1, jobId, now);
    await store.writeTree(
      SnapshotTree(
        snapshotId: record.id,
        sha: record.sha,
        subPath: '',
        entries: [],
      ),
      format: record.objectFormat,
      complete: true,
      mayCommit: () => true,
    );
    await store.writeIndex(
      SnapshotIndex(
        accountKey: c2.account,
        lastValidatedAt: now,
        consentAt: now,
        snapshots: [record],
      ),
      expectedRevision: store.revision,
      mayCommit: () => true,
    );
    expect(await h.recover(owner: owner), isTrue);
    h.storage.events.clear();
  });
  tearDown(() => h.dispose());

  test('retained refusal survives restart until explicit deletion', () async {
    await h.cache.writeOfflineRefused(c2.account, now);
    final name = ReadCacheKeyStore.offlineRefusalName(c2.account);
    expect(h.storage.values[name], now.toIso8601String());
    expect(await h.cache.readOfflineRefused(c2.account), isTrue);
    expect(await h.recover(owner: owner), isTrue);
    expect(await h.cache.readOfflineRefused(c2.account), isTrue);
    expect(await h.cache.offlineEligibilityIndex(c2.account), isNull);
    await h.cache.deleteOfflineRefused(c2.account);
    expect(await h.cache.readOfflineRefused(c2.account), isFalse);
    expect(await h.cache.offlineEligibilityIndex(c2.account), isNotNull);
  });

  test(
    'qualification decrypts complete snapshots without storage writes',
    () async {
      final result = await h.cache.offlineEligibilityIndex(c2.account);
      expect(result?.lastValidatedAt, now);
      expect(
        h.storage.events.where(
          (e) => e.startsWith('write:') || e.startsWith('delete:'),
        ),
        isEmpty,
      );
      final index = File(
        '${h.directory('offline_repo', c2.account).path}/index.v1.bin',
      );
      final bytes = index.readAsBytesSync();
      bytes[bytes.length - 1] ^= 1;
      index.writeAsBytesSync(bytes);
      expect(await h.cache.offlineEligibilityIndex(c2.account), isNull);
      expect(index.existsSync(), isTrue);
    },
  );

  test(
    'offline admission binds a reader and refuses key-creating maintenance',
    () async {
      const binding = DiskBinding(accountKey: c2.account, generation: 0);
      expect(
        await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
        isTrue,
      );
      final coordinator = h.cache.offlineRepository!;
      expect(
        coordinator.state(c2.account),
        OfflineRepositoryState.offlineReadOnly,
      );
      expect((await coordinator.snapshots(binding)).length, 1);
      final permit = coordinator.capture(binding, 1);
      await expectLater(
        coordinator.maintain<void>(
          permit,
          (_, _) async {},
          consentAt: now,
          allowReadOnly: true,
        ),
        throwsA(isA<SnapshotOperationException>()),
      );
      h.cache.closeOfflineReadOnly(binding, sessionOwner: owner);
      expect(coordinator.state(c2.account), OfflineRepositoryState.closed);
      expect(permit.isCurrent, isFalse);
      expect(h.directory('offline_repo', c2.account).existsSync(), isTrue);
    },
  );
  test(
    'read-only stores reject mutations while explicit deletion works',
    () async {
      const binding = DiskBinding(accountKey: c2.account, generation: 0);
      expect(
        await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
        isTrue,
      );
      final coordinator = h.cache.offlineRepository!;
      final permit = coordinator.capture(binding, 0);
      late SnapshotStore held;
      late SnapshotIndex index;
      await coordinator.maintain<void>(permit, (store, current) async {
        held = store;
        index = current!;
        expect(await store.readTree(index.snapshots.single), isNotNull);
      }, allowReadOnly: true);
      await expectLater(
        held.workerKeys,
        throwsA(isA<SnapshotStoreException>()),
      );
      final record = index.snapshots.single;
      final tree = (await held.readTree(record))!;
      final revoked = throwsA(
        isA<SnapshotStoreException>().having(
          (e) => e.code,
          'code',
          SnapshotStoreError.revoked,
        ),
      );
      await expectLater(
        held.writeIndex(
          index,
          expectedRevision: held.revision,
          mayCommit: () => true,
        ),
        revoked,
      );
      await expectLater(
        held.writeTree(
          tree,
          format: record.objectFormat,
          complete: true,
          mayCommit: () => true,
        ),
        revoked,
      );
      await expectLater(
        held.writeBlob(
          SnapshotObjectFormat.sha1,
          'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391',
          [],
          mayCommit: () => true,
        ),
        revoked,
      );
      expect(() => held.deleteTree(record.id, mayCommit: () => true), revoked);
      await expectLater(
        held.recover(now: now, workersRunning: false, mayCommit: () => true),
        revoked,
      );
      await expectLater(
        held.collectGarbage(index, mayCommit: () => true),
        revoked,
      );
      await coordinator.deleteSnapshot(binding, record.id);
      expect(await coordinator.snapshots(binding), isEmpty);
      await coordinator.clearAll(binding);
      expect(h.directory('offline_repo', c2.account).existsSync(), isFalse);
      h.cache.closeOfflineReadOnly(binding, sessionOwner: owner);
      await expectLater(
        held.writeIndex(
          index,
          expectedRevision: held.revision,
          mayCommit: () => true,
        ),
        revoked,
      );
    },
  );
  test('a store retained from ready is fenced by a new epoch', () async {
    const binding = DiskBinding(accountKey: c2.account, generation: 8);
    final coordinator = h.cache.offlineRepository!;
    coordinator.open(binding);
    final permit = coordinator.capture(binding, 0);
    late SnapshotStore held;
    late SnapshotIndex index;
    await coordinator.maintain<void>(permit, (store, current) async {
      held = store;
      index = current!;
    });
    coordinator.open(binding, readOnly: true);
    await expectLater(
      held.writeIndex(
        index,
        expectedRevision: held.revision,
        mayCommit: () => true,
      ),
      throwsA(
        isA<SnapshotStoreException>().having(
          (e) => e.code,
          'code',
          SnapshotStoreError.revoked,
        ),
      ),
    );
  });
}
