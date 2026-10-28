import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';

const _account = 'https://synthetic.example/subpath#17';
const _other = 'https://synthetic.example/subpath#18';
const _orphan = 'https://synthetic.example/subpath#19';
const _binding = DiskBinding(accountKey: _account, generation: 1);

final class _Storage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  final preferenceWrites = <String>[];
  final deletions = <String>[];
  bool failInventory = false, failMarkerWrite = false;
  bool failSettingWrite = false;
  int inventoryReads = 0;
  int? failInventoryAt;
  Future<void> Function(String value)? beforeSettingWrite;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == ReadCacheSettingsStore.key) {
      preferenceWrites.add(value);
      await beforeSettingWrite?.call(value);
      if (failSettingWrite) throw StateError('synthetic setting failure');
    }
    if (key.startsWith(ReadCacheKeyStore.markerPrefix) && failMarkerWrite) {
      throw StateError('synthetic marker failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletions.add(key);
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    inventoryReads++;
    if (failInventory || inventoryReads == failInventoryAt) {
      throw StateError('synthetic inventory failure');
    }
    return Map.of(values);
  }
}

final class _Lease implements DiskCommitLease {
  @override
  bool isCurrent = true;
  @override
  void revoke() => isCurrent = false;
}

final class _Harness {
  _Harness() {
    files = ReadCacheFileStore(
      root: () async {
        fileCalls++;
        if (failFiles) throw StateError('synthetic file access failure');
        return root;
      },
    );
    coordinator = wrapper();
  }

  final root = Directory.systemTemp.createTempSync('read-cache-device-off-');
  final storage = _Storage();
  final scope = Object();
  late final ReadCacheFileStore files;
  late final ReadCacheDiskCoordinator coordinator;
  bool failFiles = false;
  int fileCalls = 0;
  ReadCacheKeyStore get keys => ReadCacheKeyStore(storage);

  ReadCacheDiskCoordinator wrapper({bool freshProcess = false}) =>
      ReadCacheDiskCoordinator(
        keys: keys,
        files: files,
        settings: ReadCacheSettingsStore(storage),
        coordinationScope: freshProcess ? Object() : scope,
        controlsInstalled: true,
        // These tests release controlled I/O explicitly; no native keychain.
        schedule: (_, _) => () {},
      );

  Directory directory(String account) => Directory(
    '${root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(account)}',
  );

  Future<void> seed(String account, {bool key = true}) async {
    directory(account).createSync(recursive: true);
    File('${directory(account).path}/residue.tmp').writeAsBytesSync([1, 2, 3]);
    if (key) await keys.writeKey(account, Uint8List(32));
  }

  Future<bool> recover([ReadCacheDiskCoordinator? owner]) =>
      (owner ?? coordinator).recover(
        const ReadCacheStartupDecision(
          operationTicket: 1,
          accountListRevision: 1,
          accountsReadable: true,
          signOutMarkerReadable: true,
          lastActiveReadable: true,
          signOutPending: false,
          resumeAccountKey: _account,
        ),
        accountKeys: {_account, _other},
      );

  ProjectedDiskEntry get entry => ProjectedDiskEntry(
    accountKey: _account,
    canonicalKey: jsonEncode([
      _account,
      'GET',
      '/api/v4/projects/1',
      <Object>[],
      'text/plain',
    ]),
    cacheClass: ReadCacheDiskClass.detail,
    bodyKind: ReadCacheBodyKind.text,
    fetchedAt: DateTime.now().toUtc(),
    body: 'synthetic retained body',
    privacyEpoch: 0,
    issueIdentities: const {},
    scopeTags: const {'project:1'},
  );

  Future<void> save() async {
    expect(await recover(), isTrue);
    expect(await coordinator.activate(_binding), isTrue);
    final value = entry;
    coordinator.accept(
      DiskWriteCandidate(
        binding: _binding,
        uri: Uri.parse('https://synthetic.example/subpath/api/v4/projects/1'),
        logicalAccept: 'text/plain',
        bodyKind: value.bodyKind,
        fetchedAt: value.fetchedAt,
        responseBytes: value.serializedLength,
        lease: _Lease(),
        cacheable: true,
        noStore: false,
        firstPage: true,
        scopeTags: value.scopeTags,
      ),
      value,
    );
    await coordinator.flush(_binding);
    await coordinator.quiesced;
    expect(coordinator.stats.retainedEntries, 1);
  }

  Future<void> expectEmpty() async {
    final inventory = await keys.readInventory();
    expect(inventory.status, ReadCacheStoreReadStatus.found);
    expect(inventory.keys, isEmpty);
    expect(inventory.markers, isEmpty);
    expect(inventory.malformedNames, isEmpty);
    expect(await files.accountDirectoryNames(), isEmpty);
  }

  void dispose() => root.deleteSync(recursive: true);
}

void main() {
  test(
    'unproven off refuses on without a write and cannot revive after restart',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.save();
      h.storage.failInventory = true;
      h.storage.failMarkerWrite = true;
      expect(await h.coordinator.setEnabled(false), isFalse);
      expect(h.storage.values[ReadCacheSettingsStore.key], '0');
      expect((await h.keys.readMarker(_account)).isFound, isFalse);
      expect(h.directory(_account).existsSync(), isTrue);
      expect(h.coordinator.settingsSnapshot.deviceOffPending, isTrue);
      expect(h.coordinator.settingsSnapshot.deviceOffInFlight, isFalse);
      final writes = List.of(h.storage.preferenceWrites);
      expect(
        await h.coordinator.setEnabledResult(true),
        ReadCacheSettingChangeResult.cleanupPending,
      );
      expect(await h.coordinator.setEnabled(true), isFalse);
      expect(
        await h.wrapper().setEnabledResult(true),
        ReadCacheSettingChangeResult.cleanupPending,
      );
      expect(h.storage.preferenceWrites, writes);

      h.storage.failInventory = false;
      h.storage.failMarkerWrite = false;
      final restarted = h.wrapper(freshProcess: true);
      expect(await h.recover(restarted), isTrue);
      expect(await restarted.activate(_binding), isFalse);
      await h.expectEmpty();
      expect(restarted.deviceOffPending, isFalse);
      expect(await restarted.setEnabled(true), isTrue);
      expect(await h.recover(restarted), isTrue);
      const next = DiskBinding(accountKey: _account, generation: 2);
      expect(await restarted.activate(next), isTrue);
      expect(
        await restarted.lookup(
          DiskLookup(
            binding: next,
            canonicalKey: h.entry.canonicalKey,
            bodyKind: ReadCacheBodyKind.text,
            lease: _Lease(),
          ),
        ),
        isNull,
      );
    },
  );

  test(
    'retry sweeps every account and orphan; unavailable inventory deletes nothing',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.save();
      await h.seed(_other);
      await h.seed(_orphan, key: false);
      h.storage.failInventory = true;
      expect(await h.coordinator.setEnabled(false), isFalse);
      final fileCalls = h.fileCalls;
      final deletions = List.of(h.storage.deletions);
      final writes = List.of(h.storage.preferenceWrites);
      expect((await h.coordinator.retryDeviceOff()).complete, isFalse);
      expect(h.coordinator.deviceOffPending, isTrue);
      expect(h.fileCalls, fileCalls);
      expect(h.storage.deletions, deletions);
      expect(h.storage.preferenceWrites, writes);
      for (final account in [_account, _other, _orphan]) {
        expect(h.directory(account).existsSync(), isTrue);
      }

      h.storage.failInventory = false;
      expect((await h.coordinator.retryDeviceOff()).complete, isTrue);
      await h.expectEmpty();
      expect(h.storage.preferenceWrites, writes);
      expect(h.coordinator.settingsSnapshot.deviceOffPending, isFalse);
      expect(h.coordinator.notice(_binding), isNull);
      expect(h.coordinator.stats.diskUsageBytes, 0);
    },
  );

  test('single-account clear cannot discharge a device-off latch', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.save();
    await h.seed(_other);
    await h.seed(_orphan, key: false);
    h.storage.failInventory = true;
    expect(await h.coordinator.setEnabled(false), isFalse);
    h.storage.failInventory = false;
    expect(
      (await h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.settingsClear,
      )).complete,
      isTrue,
    );
    expect(h.directory(_other).existsSync(), isTrue);
    expect(h.directory(_orphan).existsSync(), isTrue);
    expect(
      await h.coordinator.setEnabledResult(true),
      ReadCacheSettingChangeResult.cleanupPending,
    );
    expect((await h.coordinator.retryDeviceOff()).complete, isTrue);
    await h.expectEmpty();
  });

  test(
    'device-off waits for final inventory confirmation after account deletion',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.seed(_account);
      // Sweep inventory, account inventory, then the device-wide confirmation.
      h.storage.failInventoryAt = 3;
      expect(await h.coordinator.setEnabled(false), isFalse);
      expect(h.storage.inventoryReads, 3);
      expect(h.directory(_account).existsSync(), isFalse);
      expect(
        (await h.keys.readKey(_account)).status,
        ReadCacheStoreReadStatus.absent,
      );
      expect(h.coordinator.deviceOffPending, isTrue);
      expect(h.coordinator.stats.diskUsageBytes, isNull);
      expect(
        await h.coordinator.setEnabledResult(true),
        ReadCacheSettingChangeResult.cleanupPending,
      );
      h.storage.failInventoryAt = null;
      expect((await h.coordinator.retryDeviceOff()).complete, isTrue);
      await h.expectEmpty();
      expect(h.coordinator.deviceOffPending, isFalse);
      expect(h.coordinator.stats.diskUsageBytes, 0);
    },
  );

  test('off exposes its latch before the preference write finishes', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.save();
    final entered = Completer<void>(), release = Completer<void>();
    h.storage.beforeSettingWrite = (_) async {
      entered.complete();
      await release.future;
    };
    final off = h.coordinator.setEnabled(false);
    expect(h.coordinator.settingsSnapshot.deviceOffPending, isTrue);
    expect(h.coordinator.settingsSnapshot.deviceOffInFlight, isTrue);
    await entered.future;
    expect(
      await h.coordinator.setEnabledResult(true),
      ReadCacheSettingChangeResult.cleanupPending,
    );
    expect(h.storage.preferenceWrites, ['0']);
    release.complete();
    expect(await off, isTrue);
    expect(h.coordinator.settingsSnapshot.deviceOffPending, isFalse);
    expect(h.coordinator.settingsSnapshot.deviceOffInFlight, isFalse);
  });

  test(
    'a fresh coordinator cannot bypass stored off before recovery',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.save();
      h.storage.values[ReadCacheSettingsStore.key] = '0';
      final restarted = h.wrapper(freshProcess: true);
      expect(
        await restarted.setEnabledResult(true),
        ReadCacheSettingChangeResult.cleanupPending,
      );
      expect(h.storage.preferenceWrites, isEmpty);
      expect(h.directory(_account).existsSync(), isTrue);
      expect((await restarted.retryDeviceOff()).complete, isTrue);
      await h.expectEmpty();
      expect(
        await restarted.setEnabledResult(true),
        ReadCacheSettingChangeResult.complete,
      );
    },
  );

  test('startup remembers off when its inventory is unavailable', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.seed(_account);
    h.storage.values[ReadCacheSettingsStore.key] = '0';
    h.storage.failInventory = true;
    expect(await h.recover(), isFalse);
    expect(h.coordinator.settingsSnapshot.deviceOffPending, isTrue);
    expect(h.fileCalls, 0);
    expect(h.storage.deletions, isEmpty);
    expect(await h.coordinator.setEnabled(true), isFalse);
    expect(h.storage.preferenceWrites, isEmpty);
  });

  test(
    'failed directory deletion leaves usage unknown while files remain',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.save();
      expect(h.coordinator.stats.retainedBytes, greaterThan(0));
      h.failFiles = true;
      final result = await h.coordinator.clear(
        _binding,
        ReadCacheCleanupOperation.settingsClear,
      );
      expect(result.complete, isFalse);
      expect(result.directoryGoneConfirmed, isFalse);
      expect(h.coordinator.stats.retainedEntries, 0);
      final files = h.directory(_account).listSync().whereType<File>();
      expect(
        files.fold<int>(0, (bytes, file) => bytes + file.lengthSync()),
        greaterThan(0),
      );
      expect(h.coordinator.stats.diskUsageBytes, isNull);
    },
  );

  test(
    'a failed device retry never confirms empty usage or permits enable',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.save();
      h.failFiles = true;
      expect(await h.coordinator.setEnabled(false), isFalse);
      expect((await h.coordinator.retryDeviceOff()).complete, isFalse);
      expect(h.coordinator.deviceOffPending, isTrue);
      expect(h.coordinator.stats.diskUsageBytes, isNull);
      expect(h.directory(_account).existsSync(), isTrue);
      expect(await h.coordinator.setEnabled(true), isFalse);
      h.failFiles = false;
      expect((await h.coordinator.retryDeviceOff()).complete, isTrue);
      await h.expectEmpty();
      expect(h.coordinator.stats.diskUsageBytes, 0);
    },
  );

  test(
    'orphan-only failed off remains pending without an account notice',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.seed(_orphan, key: false);
      h.failFiles = true;
      expect(await h.coordinator.setEnabled(false), isFalse);
      expect(h.coordinator.deviceOffPending, isTrue);
      expect(h.coordinator.notice(_binding), isNull);
      expect(
        await h.coordinator.setEnabledResult(true),
        ReadCacheSettingChangeResult.cleanupPending,
      );
      h.failFiles = false;
      expect((await h.coordinator.retryDeviceOff()).complete, isTrue);
      await h.expectEmpty();
    },
  );

  test(
    'failed off preference write has a distinct typed storage result',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.save();
      h.storage.failSettingWrite = true;
      expect(
        await h.coordinator.setEnabledResult(false),
        ReadCacheSettingChangeResult.storageUnavailable,
      );
      await h.expectEmpty();
      expect(h.coordinator.deviceOffPending, isFalse);
      expect(h.coordinator.setting, ReadCacheSettingsState.unavailable);
      expect(await h.coordinator.activate(_binding), isFalse);
    },
  );

  test(
    'preference serialization leaves off durable after an older enable',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.save();
      final entered = Completer<void>(), release = Completer<void>();
      h.storage.beforeSettingWrite = (value) async {
        if (value == '1') {
          entered.complete();
          await release.future;
        }
      };
      final on = h.coordinator.setEnabled(true);
      await entered.future;
      final off = h.coordinator.setEnabled(false);
      expect(
        await h.coordinator.setEnabledResult(true),
        ReadCacheSettingChangeResult.cleanupPending,
      );
      release.complete();
      expect(await on, isTrue);
      expect(await off, isTrue);
      expect(h.storage.preferenceWrites, ['1', '0']);
      expect(h.storage.values[ReadCacheSettingsStore.key], '0');
      await h.expectEmpty();
    },
  );
}
