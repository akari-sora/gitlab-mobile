import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_page.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart' show formatByteCount;

import 'support/widget_settle.dart';

// P-C2e settings page (§6e): every state comes from the real coordinator over
// a temporary root and a synthetic secure store; nothing touches the keychain.
final _instance = GitLabInstance.parse('https://cache.example/subpath');
final _account = '${_instance.key}#7';
final _binding = DiskBinding(accountKey: _account, generation: 1);
// Another account's leftovers on the device (not signed in now).
final _other = '${_instance.key}#8';

final class _Storage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  bool failSettingWrite = false, failInventory = false, failKeyDelete = false;
  final failDeleteNames = <String>{};
  int settingWrites = 0;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (key == ReadCacheSettingsStore.key) settingWrites++;
    if (failSettingWrite && key == ReadCacheSettingsStore.key) {
      throw StateError('synthetic setting write failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if ((failKeyDelete && key == ReadCacheKeyStore.keyName(_account)) ||
        failDeleteNames.contains(key)) {
      throw StateError('synthetic key delete failure');
    }
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (failInventory) throw StateError('synthetic inventory failure');
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
  _Harness({_Storage? storage, Directory? root})
    : storage = storage ?? _Storage(),
      root = root ?? Directory.systemTemp.createTempSync('c2e-settings-') {
    files = ReadCacheFileStore(root: () async {
      if (failRoot) throw StateError('synthetic root failure');
      return this.root;
    });
    keys = ReadCacheKeyStore(this.storage);
    coordinator = ReadCacheDiskCoordinator(
      keys: keys,
      files: files,
      settings: ReadCacheSettingsStore(this.storage),
      coordinationScope: Object(),
      controlsInstalled: true,
      // Barrier deadlines never fire on the widget clock in these tests.
      schedule: (_, _) => () {},
    );
  }

  final _Storage storage;
  final Directory root;
  late final ReadCacheFileStore files;
  late final ReadCacheKeyStore keys;
  late final ReadCacheDiskCoordinator coordinator;
  bool failRoot = false;

  Directory get accountDirectory => Directory(
    '${root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(_account)}',
  );

  List<File> entryFiles() => accountDirectory.existsSync()
      ? accountDirectory
            .listSync()
            .whereType<File>()
            .where((file) => file.uri.pathSegments.last.startsWith('e_'))
            .toList()
      : const [];

  Future<bool> recover() => coordinator.recover(
    ReadCacheStartupDecision(
      operationTicket: 1,
      accountListRevision: 1,
      accountsReadable: true,
      signOutMarkerReadable: true,
      lastActiveReadable: true,
      signOutPending: false,
      resumeAccountKey: _account,
    ),
    accountKeys: {_account},
  );

  ProjectedDiskEntry entry(int id) => ProjectedDiskEntry(
    accountKey: _account,
    canonicalKey: jsonEncode([
      _account,
      'GET',
      '/subpath/api/v4/projects/1/items/$id',
      <Object>[],
      'text/plain',
    ]),
    cacheClass: ReadCacheDiskClass.detail,
    bodyKind: ReadCacheBodyKind.text,
    fetchedAt: DateTime.now().toUtc(),
    body: 'synthetic body $id ${'x' * (id * 300)}',
    privacyEpoch: 0,
    issueIdentities: const {},
    scopeTags: const {'project:1'},
  );

  Future<void> ready({int entries = 2}) async {
    // No expect() here: this runs while the widget clock is being pumped.
    if (!await recover() || !await coordinator.activate(_binding)) {
      throw StateError('synthetic cache did not open');
    }
    for (var id = 1; id <= entries; id++) {
      final value = entry(id);
      coordinator.accept(
        DiskWriteCandidate(
          binding: _binding,
          uri: _instance.api(['projects', '1', 'items', '$id']),
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
    }
    await coordinator.flush(_binding);
    await coordinator.quiesced;
    if (entryFiles().length != entries) throw StateError('entries not stored');
  }

  Future<ProjectedDiskEntry?> lookup(DiskBinding binding, int id) =>
      coordinator.lookup(DiskLookup(
        binding: binding,
        canonicalKey: entry(id).canonicalKey,
        bodyKind: ReadCacheBodyKind.text,
        lease: _Lease(),
      ));

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

/// The coordinator lives on the widget clock, while its native I/O finishes
/// on the real loop: keep both moving until the work completes.
Future<T> _run<T>(WidgetTester tester, Future<T> Function() work) async {
  late T value;
  await pumpUntilComplete(tester, work().then((result) => value = result));
  return value;
}

Widget _page(_Harness h, [DiskBinding? binding]) => MaterialApp(
  home: ReadCacheSettingsPage(cache: h.coordinator, binding: binding ?? _binding),
);

bool _switchValue(WidgetTester tester) => tester
    .widget<SwitchListTile>(find.byKey(const ValueKey('read-cache-switch')))
    .value;

Finder _status(String label) => find.descendant(
  of: find.byKey(const ValueKey('read-cache-status')),
  matching: find.text(label),
);

void main() {
  testWidgets('size aggregates the encrypted entry files; status is icon and label', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    await tester.pumpWidget(_page(h));
    final onDisk = h.entryFiles().fold<int>(0, (n, file) => n + file.lengthSync());
    expect(onDisk, greaterThan(0));
    expect(h.coordinator.stats.retainedBytes, onDisk);
    // No confirmed device total yet: the indexed bytes are an estimate.
    expect(find.text('已使用約 ${formatByteCount(onDisk)}'), findsOneWidget);
    expect(find.text('已使用 ${formatByteCount(onDisk)}'), findsNothing);
    expect(_status('使用中'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('read-cache-status')),
      matching: find.byIcon(Icons.check_circle_outline)), findsOneWidget);
    expect(_switchValue(tester), isTrue);
  });

  testWidgets('turning off saves 0 with readback, clears key and directory, and says so', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    await tester.pumpWidget(_page(h));
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    await pumpUntil(tester, () => find.text('已關閉離線快取並清除資料').evaluate().isNotEmpty);
    expect(h.storage.values[ReadCacheSettingsStore.key], '0');
    expect(h.accountDirectory.existsSync(), isFalse);
    expect(h.storage.values.containsKey(ReadCacheKeyStore.keyName(_account)), isFalse);
    expect(_switchValue(tester), isFalse);
    expect(_status('已關閉'), findsOneWidget);
    // The confirmed empty device sweep is the only source of a plain zero.
    expect(h.coordinator.stats.diskUsageBytes, 0);
    expect(find.text('已使用 ${formatByteCount(0)}'), findsOneWidget);
  });

  testWidgets('a failed preference write still clears, stays closed and never claims off was saved', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    h.storage.failSettingWrite = true;
    await tester.pumpWidget(_page(h));
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    // The device sweep completed, the preference did not: say exactly that.
    await pumpUntil(tester, () => find.text('無法儲存設定。離線快取已清除，這次使用期間保持關閉。').evaluate().isNotEmpty);
    expect(find.text('已關閉離線快取並清除資料'), findsNothing);
    expect(h.storage.values[ReadCacheSettingsStore.key], isNull, reason: 'nothing claims a stored 0');
    expect(h.accountDirectory.existsSync(), isFalse, reason: 'storage failure still clears');
    expect(h.coordinator.state(_account), isNot(ReadCacheDiskState.ready));
    expect(await _run(tester, () => h.lookup(_binding, 1)), isNull);
    expect(_switchValue(tester), isFalse);
    expect(_status('無法讀取設定，這次使用期間不保存'), findsOneWidget);
  });

  testWidgets('unavailable inventory deletes nothing, shows the pending clear and its retry', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    h.storage.failInventory = true;
    await tester.pumpWidget(_page(h));
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    await pumpUntil(tester, () => find.text('無法確認離線快取已關閉並清除。這次使用期間保持關閉，請重試清除。').evaluate().isNotEmpty);
    await pumpUntil(tester, () => find.byKey(const ValueKey('read-cache-retry-cleanup')).evaluate().isNotEmpty);
    expect(find.text('已關閉離線快取並清除資料'), findsNothing);
    expect(find.text('已清除離線快取'), findsNothing);
    expect(h.entryFiles(), hasLength(2), reason: 'unavailable is never permission to delete');
    expect(h.coordinator.notice(_binding)?.failure.cleanup?.operation,
      ReadCacheCleanupOperation.settingsClear);
    expect(_status('清除未完成，暫停使用'), findsOneWidget);
    expect(find.text('無法清除離線快取'), findsOneWidget);
    expect(find.text('離線快取已暫停使用，重試清除完成後才會恢復。'), findsOneWidget);
    expect(await _run(tester, () => h.lookup(_binding, 1)), isNull);

    h.storage.failInventory = false;
    ScaffoldMessenger.of(tester.element(find.byType(ListView))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('read-cache-retry-cleanup')));
    await pumpUntil(tester, () => find.text('已清除離線快取').evaluate().isNotEmpty);
    expect(h.entryFiles(), isEmpty);
    expect(h.coordinator.notice(_binding), isNull);
    await tester.pump();
    expect(find.byKey(const ValueKey('read-cache-retry-cleanup')), findsNothing);
    expect(_status('已關閉'), findsOneWidget, reason: 'the stored 0 still applies');
  });

  // FIX1 (review P1-1): turning on is refused, without writing the preference,
  // until the last turn-off's device sweep is confirmed.
  testWidgets('turning on is refused without a preference write while the device clear is pending', (tester) async {
    final seeded = _Harness();
    addTearDown(seeded.dispose);
    await _run(tester, seeded.ready);
    // A stored 0 seen by a fresh process before its start-up sweep ran.
    seeded.storage.values[ReadCacheSettingsStore.key] = '0';
    final h = _Harness(storage: seeded.storage, root: seeded.root);
    final writes = h.storage.settingWrites;
    await tester.pumpWidget(_page(h));
    expect(_switchValue(tester), isFalse);
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    await pumpUntil(tester, () => find.text('無法清除離線快取。離線快取已暫停使用，重試清除完成後才會恢復。').evaluate().isNotEmpty);
    expect(h.storage.settingWrites, writes, reason: 'refused before anything was written');
    expect(h.storage.values[ReadCacheSettingsStore.key], '0');
    expect(find.text('下次開啟 App 或切換帳號後開始保存'), findsNothing);
    await tester.pump();
    final tile = tester.widget<SwitchListTile>(find.byKey(const ValueKey('read-cache-switch')));
    expect(tile.onChanged, isNull, reason: 'the switch cannot be turned on while pending');
    expect(find.text('上次的清除完成後，才能重新開啟離線快取。'), findsOneWidget);
    expect(find.text('已使用：無法確認'), findsOneWidget);
    expect(seeded.entryFiles(), hasLength(2), reason: 'a refused enable deletes nothing by itself');

    // The retry is the whole device sweep; once confirmed, turning on works.
    ScaffoldMessenger.of(tester.element(find.byType(ListView))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('read-cache-retry-device-off')));
    await pumpUntil(tester, () => find.text('已清除離線快取').evaluate().isNotEmpty);
    expect(seeded.entryFiles(), isEmpty);
    expect(find.byKey(const ValueKey('read-cache-on-blocked')), findsNothing);
    expect(find.text('已使用 ${formatByteCount(0)}'), findsOneWidget, reason: 'confirmed empty device');
    ScaffoldMessenger.of(tester.element(find.byType(ListView))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    await pumpUntil(tester, () => find.descendant(of: find.byType(SnackBar),
      matching: find.text('下次開啟 App 或切換帳號後開始保存')).evaluate().isNotEmpty);
    expect(h.storage.values[ReadCacheSettingsStore.key], '1');
  });

  // FIX1 (review P1-2): the retry after a failed turn-off repeats the device
  // sweep. Another account's residue keeps it pending; a single-account clear
  // must never report this as cleared.
  testWidgets('retry after a failed turn-off sweeps the device; residue keeps it pending', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    await _run(tester, () => h.keys.writeKey(_other, Uint8List.fromList(List.generate(32, (i) => 31 - i))));
    final orphan = Directory('${h.root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(_other)}')
      ..createSync(recursive: true);
    File('${orphan.path}/index.v1.bin').writeAsBytesSync(List.filled(40, 7));
    h.storage.failInventory = true;
    await tester.pumpWidget(_page(h));
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    await pumpUntil(tester, () => find.text('無法確認離線快取已關閉並清除。這次使用期間保持關閉，請重試清除。').evaluate().isNotEmpty);
    ScaffoldMessenger.of(tester.element(find.byType(ListView))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('read-cache-on-blocked')), findsOneWidget);

    // Inventory is back, but the other account's key cannot be deleted yet.
    h.storage.failInventory = false;
    h.storage.failDeleteNames.add(ReadCacheKeyStore.keyName(_other));
    await tester.tap(find.byKey(const ValueKey('read-cache-retry-device-off')));
    await pumpUntil(tester, () => find.text('無法清除離線快取。離線快取已暫停使用，重試清除完成後才會恢復。').evaluate().isNotEmpty);
    expect(find.text('已清除離線快取'), findsNothing, reason: 'this account alone is not the device');
    expect(h.storage.values.containsKey(ReadCacheKeyStore.keyName(_other)), isTrue);
    expect(h.coordinator.deviceOffPending, isTrue);
    await tester.pump();
    expect(find.byKey(const ValueKey('read-cache-on-blocked')), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('read-cache-switch'))).onChanged, isNull);
    expect(find.text('已使用：無法確認'), findsOneWidget);

    h.storage.failDeleteNames.clear();
    ScaffoldMessenger.of(tester.element(find.byType(ListView))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('read-cache-retry-device-off')));
    await pumpUntil(tester, () => find.text('已清除離線快取').evaluate().isNotEmpty);
    expect(h.storage.values.containsKey(ReadCacheKeyStore.keyName(_other)), isFalse);
    expect(orphan.existsSync(), isFalse, reason: 'unknown leftovers are swept too');
    expect(h.entryFiles(), isEmpty);
    expect(h.coordinator.deviceOffPending, isFalse);
    await tester.pump();
    expect(find.byKey(const ValueKey('read-cache-on-blocked')), findsNothing);
    expect(find.byKey(const ValueKey('read-cache-retry-cleanup')), findsNothing);
  });

  testWidgets('clear asks first, deletes, and reopens the same session (m-10)', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    final before = h.entryFiles().map((file) => file.path).toSet();
    await tester.pumpWidget(_page(h));
    await tester.tap(find.byKey(const ValueKey('read-cache-clear')));
    await tester.pumpAndSettle();
    expect(find.text('清除離線快取？'), findsOneWidget);
    expect(find.text('會刪除這台裝置上此帳號的離線快取。GitLab 上的資料不受影響。'), findsOneWidget);
    await tester.tap(find.text('確認'));
    await pumpUntil(tester, () => find.text('已清除離線快取').evaluate().isNotEmpty);
    expect(h.entryFiles().where((file) => before.contains(file.path)), isEmpty);
    await pumpUntil(tester, () => h.coordinator.state(_account) == ReadCacheDiskState.ready,
      description: 'a completed settings clear reopens this session');
    expect(await _run(tester, () => h.lookup(_binding, 1)), isNull);
    await tester.pumpWidget(_page(h, DiskBinding(accountKey: _account, generation: 1)));
    expect(find.text('已使用約 ${formatByteCount(0)}'), findsOneWidget,
      reason: 'reopened: an estimate again, never a confirmed plain zero');
  });

  testWidgets('cancelled confirmation clears nothing', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    await tester.pumpWidget(_page(h));
    await tester.tap(find.byKey(const ValueKey('read-cache-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _run(tester, () => h.coordinator.quiesced);
    expect(h.entryFiles(), hasLength(2));
    expect(h.coordinator.state(_account), ReadCacheDiskState.ready);
  });

  testWidgets('a failed clear reports the central notice and does not reopen', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    h.storage.failKeyDelete = true;
    h.failRoot = true;
    await tester.pumpWidget(_page(h));
    await tester.tap(find.byKey(const ValueKey('read-cache-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確認'));
    await pumpUntil(tester, () => find.text('無法清除離線快取。離線快取已暫停使用，重試清除完成後才會恢復。').evaluate().isNotEmpty);
    expect(find.text('已清除離線快取'), findsNothing);
    expect(h.coordinator.state(_account), isNot(ReadCacheDiskState.ready));
    await tester.pump();
    expect(find.byKey(const ValueKey('read-cache-retry-cleanup')), findsOneWidget);
    expect(_status('清除未完成，暫停使用'), findsOneWidget);
    expect(find.text('已使用：無法確認'), findsOneWidget, reason: 'a failed clear leaves the size unknown');
    expect(find.textContaining('已使用約'), findsNothing);
    expect(await _run(tester, () => h.lookup(_binding, 1)), isNull);
    await tester.pump(const Duration(milliseconds: 500)); // confirm dialog cleanup
  });

  testWidgets('off then on never revives old files and waits for the next verified activation', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    await _run(tester, h.ready);
    await tester.pumpWidget(_page(h));
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    await pumpUntil(tester, () => find.text('已關閉離線快取並清除資料').evaluate().isNotEmpty);
    ScaffoldMessenger.of(tester.element(find.byType(ListView))).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    await pumpUntil(tester, () => find.descendant(of: find.byType(SnackBar),
      matching: find.text('下次開啟 App 或切換帳號後開始保存')).evaluate().isNotEmpty);
    expect(h.storage.values[ReadCacheSettingsStore.key], '1');
    expect(_switchValue(tester), isTrue);
    expect(_status('下次開啟 App 或切換帳號後開始保存'), findsOneWidget);
    expect(h.coordinator.state(_account), isNot(ReadCacheDiskState.ready),
      reason: 'the same session does not reopen without a fresh decision');
    expect(await _run(tester, () => h.lookup(_binding, 1)), isNull);
    expect(h.entryFiles(), isEmpty);
    // The next _activate: a fresh start-up decision and a verified binding.
    final next = DiskBinding(accountKey: _account, generation: 2);
    expect(await _run(tester, () async =>
        [await h.recover(), await h.coordinator.activate(next)]), [true, true]);
    expect(await _run(tester, () => h.lookup(next, 1)), isNull, reason: 'rebuilt, not revived');
    expect(h.coordinator.stats.retainedBytes, 0);
  });

  testWidgets('turning on without a confirmed write keeps the cache off', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.storage.values[ReadCacheSettingsStore.key] = '0';
    expect(await _run(tester, h.recover), isTrue);
    await _run(tester, () => h.coordinator.activate(_binding));
    h.storage.failSettingWrite = true;
    await tester.pumpWidget(_page(h));
    expect(_switchValue(tester), isFalse);
    expect(_status('已關閉'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('read-cache-switch')));
    await pumpUntil(tester, () => find.text('無法儲存設定。離線快取保持關閉。').evaluate().isNotEmpty);
    expect(_switchValue(tester), isFalse);
    expect(_status('無法讀取設定，這次使用期間不保存'), findsOneWidget);
    expect(h.coordinator.state(_account), isNot(ReadCacheDiskState.ready));
  });

  testWidgets('start-up 0 shows off; absent shows on; unreadable is off and deletes nothing', (tester) async {
    final seeded = _Harness();
    addTearDown(seeded.dispose);
    await _run(tester, seeded.ready);
    expect(seeded.entryFiles(), hasLength(2));

    // Unreadable value: recovery refuses, the disk stays off, nothing deleted.
    seeded.storage.values[ReadCacheSettingsStore.key] = 'garbage';
    final unreadable = _Harness(storage: seeded.storage, root: seeded.root);
    final recovered = await _run(tester, unreadable.recover);
    expect(recovered, isFalse);
    expect(await _run(tester, () => unreadable.coordinator.activate(_binding)), isFalse);
    await tester.pumpWidget(_page(unreadable));
    expect(_switchValue(tester), isFalse);
    expect(_status('無法讀取設定，這次使用期間不保存'), findsOneWidget);
    expect(seeded.entryFiles(), hasLength(2));

    // Absent value: the default is on.
    seeded.storage.values.remove(ReadCacheSettingsStore.key);
    final absent = _Harness(storage: seeded.storage, root: seeded.root);
    expect(await _run(tester, () async =>
        [await absent.recover(), await absent.coordinator.activate(_binding)]), [true, true]);
    await tester.pumpWidget(_page(absent));
    expect(_switchValue(tester), isTrue);
    expect(_status('使用中'), findsOneWidget);

    // Stored 0: start-up keeps nothing and shows off.
    seeded.storage.values[ReadCacheSettingsStore.key] = '0';
    final off = _Harness(storage: seeded.storage, root: seeded.root);
    expect(await _run(tester, () async =>
        [await off.recover(), await off.coordinator.activate(_binding)]), [true, false]);
    expect(seeded.entryFiles(), isEmpty, reason: 'start-up with 0 keeps an empty set');
    await tester.pumpWidget(_page(off));
    expect(_switchValue(tester), isFalse);
    expect(_status('已關閉'), findsOneWidget);
  });
}
