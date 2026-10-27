import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';

const _account = 'https://synthetic.example/subpath#17';
const _binding = DiskBinding(accountKey: _account, generation: 1);
const _decision = ReadCacheStartupDecision(
  operationTicket: 1,
  accountListRevision: 1,
  accountsReadable: true,
  signOutMarkerReadable: true,
  lastActiveReadable: true,
  signOutPending: false,
  resumeAccountKey: _account,
);

void Function(ReadCacheFileCheckpoint) _recordRead(String path) => (step) {
  if (step == ReadCacheFileCheckpoint.beforeRead) {
    File(path).writeAsStringSync('read');
  }
};

final class _Storage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

final class _Lease implements DiskCommitLease {
  bool current = true;
  @override
  bool get isCurrent => current;
  @override
  void revoke() => current = false;
}

final class _Harness {
  _Harness() {
    root = Directory.systemTemp.createTempSync('lookup-kind-');
    keys = ReadCacheKeyStore(storage);
    files = ReadCacheFileStore(root: () async => root, clock: () => now);
    settings = ReadCacheSettingsStore(storage);
    coordinator = fresh();
  }
  late final Directory root;
  final storage = _Storage();
  late final ReadCacheKeyStore keys;
  late final ReadCacheFileStore files;
  late final ReadCacheSettingsStore settings;
  late final ReadCacheDiskCoordinator coordinator;
  DateTime now = DateTime.utc(2026, 10, 27);

  ReadCacheDiskCoordinator fresh() => ReadCacheDiskCoordinator(
    keys: keys,
    files: files,
    settings: settings,
    coordinationScope: Object(),
    controlsInstalled: true,
    clock: () => now,
    schedule: (delay, callback) => () {},
  );
  Future<void> start(ReadCacheDiskCoordinator c) async {
    expect(await c.recover(_decision, accountKeys: {_account}), isTrue);
    expect(await c.activate(_binding), isTrue);
  }

  Future<void> save(ProjectedDiskEntry entry) async {
    coordinator.accept(
      DiskWriteCandidate(
        binding: _binding,
        uri: Uri.parse('https://synthetic.example/subpath/api/v4/projects/1'),
        logicalAccept: 'text/plain',
        bodyKind: entry.bodyKind,
        fetchedAt: entry.fetchedAt,
        responseBytes: entry.serializedLength,
        lease: _Lease(),
        cacheable: true,
        noStore: false,
        firstPage: true,
      ),
      entry,
    );
    await coordinator.flush(_binding);
  }

  Future<ProjectedDiskEntry?> lookup(
    ReadCacheDiskCoordinator c,
    ProjectedDiskEntry entry,
    ReadCacheBodyKind kind,
  ) => c.lookup(
    DiskLookup(
      binding: _binding,
      canonicalKey: entry.canonicalKey,
      bodyKind: kind,
      lease: _Lease(),
    ),
  );
  ProjectedDiskEntry entry(ReadCacheBodyKind kind, Object body) =>
      ProjectedDiskEntry(
        accountKey: _account,
        canonicalKey: jsonEncode([
          _account,
          'GET',
          '/api/v4/projects/1/items/1',
          <Object>[],
          'text/plain',
        ]),
        cacheClass: kind == ReadCacheBodyKind.terminalLog
            ? ReadCacheDiskClass.pinned
            : ReadCacheDiskClass.detail,
        bodyKind: kind,
        fetchedAt: now,
        body: body,
        privacyEpoch: 0,
        issueIdentities: const {},
      );
  ReadCacheTerminalLog log(int size) => ReadCacheTerminalLog(
    projectId: 1,
    jobId: 1,
    finishedAt: now,
    startOffset: 0,
    nextOffset: size,
    totalBytes: size,
    isEof: true,
    truncated: false,
    bytes: List.filled(size, 65),
  );
  Future<void> expectEvicted(ProjectedDiskEntry entry) async {
    final key = (await keys.readKey(_account)).value!;
    expect(await files.readEntry(_account, key, entry.canonicalKey), isNull);
    await coordinator.flush(_binding);
    expect((await files.readIndex(_account, key))!.entries, isEmpty);
  }

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  for (final requested in ReadCacheBodyKind.values.where(
    (kind) => kind != ReadCacheBodyKind.text,
  )) {
    test(
      'lookup evicts authenticated text mismatch for ${requested.name}',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.start(h.coordinator);
        final entry = h.entry(ReadCacheBodyKind.text, 'synthetic');
        await h.save(entry);
        expect(await h.lookup(h.coordinator, entry, requested), isNull);
        await h.expectEvicted(entry);
      },
    );
  }

  test('lookup evicts terminal log above the requested text ceiling', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.start(h.coordinator);
    final entry = h.entry(
      ReadCacheBodyKind.terminalLog,
      h.log(readCacheEntryLimit + 100),
    );
    await h.save(entry);
    final readMarker = '${h.root.path}/before-read';
    h.coordinator.configure(
      keys: h.keys,
      settings: h.settings,
      files: ReadCacheFileStore(
        root: () async => h.root,
        clock: () => h.now,
        checkpoint: _recordRead(readMarker),
      ),
    );
    expect(
      await h.lookup(h.coordinator, entry, ReadCacheBodyKind.text),
      isNull,
    );
    expect(File(readMarker).existsSync(), isFalse);
    await h.expectEvicted(entry);
  });

  test(
    'expired entry remains a miss and is evicted from disk and index',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.start(h.coordinator);
      final entry = h.entry(ReadCacheBodyKind.text, 'synthetic');
      await h.save(entry);
      h.now = h.now.add(readCacheRetention + const Duration(seconds: 1));
      expect(
        await h.lookup(h.coordinator, entry, ReadCacheBodyKind.text),
        isNull,
      );
      await h.expectEvicted(entry);
    },
  );

  test('recovery scans opaque names with terminal-log ceiling', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.start(h.coordinator);
    final entry = h.entry(
      ReadCacheBodyKind.terminalLog,
      h.log(readCacheEntryLimit + 100),
    );
    await h.save(entry);
    final fresh = h.fresh();
    await h.start(fresh);
    final actual = await h.lookup(fresh, entry, ReadCacheBodyKind.terminalLog);
    expect(actual, isNotNull);
    expect(
      (actual!.body as ReadCacheTerminalLog).bytes.length,
      readCacheEntryLimit + 100,
    );
  });
}
