import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/features/cache/offline_repository_namespace.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';

import '../read_cache_c3_prereq_test.dart' as c2;
import 'coordinator_regression_test.dart' show completeRecord, jobId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late c2.Harness h;
  late OfflineRepositoryCoordinator offline;
  late File c2Sentinel;
  setUp(() async {
    h = c2.Harness();
    offline = OfflineRepositoryCoordinator();
    h.cache.register(
      OfflineRepositoryNamespace(
        coordinator: offline,
        keys: h.keys,
        files: h.files,
      ),
    );
    expect(await h.recover(), isTrue);
    expect(await h.cache.activate(c2.binding), isTrue);
    await h.keys.writeKey(c2.account, Uint8List(32));
    c2Sentinel = File('${h.directory('read_cache', c2.account).path}/sentinel')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final now = DateTime.now().toUtc();
    final record = completeRecord(1, jobId, now);
    final permit = offline.capture(c2.binding, 1);
    await offline.maintain<void>(permit, (store, _) async {
      await store.writeTree(
        SnapshotTree(
          snapshotId: record.id,
          sha: record.sha,
          subPath: '',
          entries: [],
        ),
        format: record.objectFormat,
        complete: true,
        mayCommit: () => permit.isCurrent,
      );
      await store.writeIndex(
        SnapshotIndex(
          accountKey: c2.account,
          lastValidatedAt: now,
          consentAt: now,
          snapshots: [record],
        ),
        expectedRevision: store.revision,
        mayCommit: () => permit.isCurrent,
      );
    }, consentAt: now);
    expect((await h.keys.readOfflineKey(c2.account)).isFound, isTrue);
    expect(h.directory('offline_repo', c2.account).existsSync(), isTrue);
  });
  tearDown(() => h.dispose());

  test(
    'real namespace joins C2 clear and fences before asynchronous cleanup',
    () async {
      final permit = offline.capture(c2.binding, 1);
      final operation = h.cache.clear(
        c2.binding,
        ReadCacheCleanupOperation.settingsClear,
      );
      expect(permit.isCurrent, isFalse);
      expect(offline.state(c2.account), OfflineRepositoryState.cleaning);
      expect((await operation).complete, isTrue);
      h.assertGone(c2.account);
    },
  );

  test(
    'C3-only clear preserves C2 bytes, C2 key and offline refusal',
    () async {
      final before = h.storage.values[ReadCacheKeyStore.keyName(c2.account)];
      final refusal = ReadCacheKeyStore.offlineRefusalName(c2.account);
      h.storage.values[refusal] = 'retained refusal';
      await offline.clearAll(c2.binding);
      expect(h.storage.values[ReadCacheKeyStore.keyName(c2.account)], before);
      expect(c2Sentinel.readAsBytesSync(), [1, 2, 3]);
      expect(h.storage.values[refusal], 'retained refusal');
      expect((await h.keys.readOfflineKey(c2.account)).isFound, isFalse);
      expect(h.directory('offline_repo', c2.account).existsSync(), isFalse);
      expect(await offline.snapshots(c2.binding), isEmpty);
    },
  );
}
