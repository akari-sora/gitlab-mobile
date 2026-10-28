import 'dart:io';
import 'package:flutter/services.dart';

import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/offline/snapshot_schema.dart';
import '../../core/read_cache_cipher.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../core/read_cache_files.dart';
import 'read_cache_disk_coordinator.dart';
import 'read_cache_key_store.dart';

/// The platform adapter participates in C2's existing account-wide protocol;
/// the pure Dart owner controls workers, epochs and its maintenance lock.
final class OfflineRepositoryNamespace
    implements ReadCacheNamespace, ReadCacheNamespaceSecurity {
  OfflineRepositoryNamespace({required this.coordinator,
      required ReadCacheKeyStore keys, required ReadCacheFileStore files}) {
    coordinator.configure(keys: _OfflineKeys(keys),
      supportRoot: files.offlineSupportDirectory,
      deleteDirectory: files.clearOfflineAccount,
      excludeBackup: _excludeBackup);
  }
  final OfflineRepositoryCoordinator coordinator;
  int backupExclusionFailures = 0;
  @override
  String get name => 'offline_repo';
  @override
  void fence(String accountKey) => coordinator.fence(accountKey);
  @override
  Future<void> stopAndWait(String accountKey) => coordinator.stopAndWait(accountKey);
  @override
  Future<void> deleteKey(String accountKey) => coordinator.deleteKey(accountKey);
  @override
  Future<void> deleteDirectory(String accountKey) => coordinator.deleteDirectory(accountKey);
  @override
  Future<bool> hasMarker(String accountKey) => coordinator.hasMarker(accountKey);
  @override
  void open(DiskBinding binding, ReadCacheDiskState mode) => coordinator.open(binding,
    readOnly: mode == ReadCacheDiskState.offlineReadOnly);
  @override
  DiskInvalidationFence invalidatePermission(DiskBinding binding, int projectId) =>
    _OfflineFence(coordinator.permissionRemoval(binding, projectId));

  Future<void> _excludeBackup(Directory root, String key) async {
    if (!Platform.isIOS) return;
    for (final path in ['${root.path}/offline_repo',
        '${root.path}/offline_repo/${ReadCacheCipher.accountDirectoryName(key)}']) {
      try {
        await const MethodChannel('mergeline/backup')
          .invokeMethod<void>('excludeFromBackup', <String, Object>{'path': path});
      } on Object { backupExclusionFailures++; }
    }
  }
}

final class _OfflineKeys implements OfflineRepositoryKeys {
  _OfflineKeys(this.keys);
  final ReadCacheKeyStore keys;
  @override
  Future<OfflineKeyRead> read(String key) async {
    final read = await keys.readOfflineKey(key);
    return OfflineKeyRead(switch (read.status) {
      ReadCacheStoreReadStatus.found => OfflineKeyStatus.found,
      ReadCacheStoreReadStatus.absent => OfflineKeyStatus.absent,
      ReadCacheStoreReadStatus.unavailable => OfflineKeyStatus.unavailable,
    }, read.value);
  }
  @override
  Future<void> write(String key, Uint8List bytes) => keys.writeOfflineKey(key, bytes);
  @override
  Future<void> delete(String key) => keys.deleteOfflineKey(key);
  @override
  Future<bool> hasMarker(String key) async {
    final read = await keys.readOfflineMarker(key);
    if (read.status == ReadCacheStoreReadStatus.unavailable) {
      throw const SnapshotOperationException(SnapshotFailure.keyUnavailable);
    }
    return read.status != ReadCacheStoreReadStatus.absent;
  }
  @override
  Future<void> writeMarker(String key, String id) => keys.writeOfflineMarker(key, id);
  @override
  Future<void> deleteMarker(String key) => keys.deleteOfflineMarker(key);
}

final class _OfflineFence implements DiskInvalidationFence {
  _OfflineFence(this.quiesced);
  @override
  bool get isCurrent => false;
  @override
  final Future<void> quiesced;
  @override
  Future<DiskClearResult> get barrier async {
    await quiesced;
    return const DiskClearResult(complete: true, keyGoneConfirmed: true,
      directoryGoneConfirmed: true, markerDurable: false);
  }
  @override
  void revoke() {}
}
