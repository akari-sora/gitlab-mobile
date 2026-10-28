import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';

import 'session_test.dart' show EmptyReadCacheStorage, MemoryAccountStore;
import 'support/fake_adapter.dart';

const account = 'https://synthetic.example/subpath#17';
const other = 'https://synthetic.example/subpath#18';
const binding = DiskBinding(accountKey: account, generation: 1);

final class MemoryStorage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  final events = <String>[];
  bool failInventory = false, failMarker = false, failOfflineKeyRead = false;
  bool failOfflineKeyDelete = false;
  Completer<void>? offlineReadGate, offlineReadStarted;
  Completer<void>? markerReadGate, markerReadStarted;
  Completer<void>? keyReadGate, keyReadStarted;

  @override
  Future<String?> read(String key) async {
    events.add('read:$key');
    if (key.startsWith(ReadCacheKeyStore.keyPrefix) &&
        keyReadGate != null &&
        keyReadStarted?.isCompleted == false) {
      final gate = keyReadGate!;
      keyReadStarted?.complete();
      await gate.future;
    }
    if (key.startsWith(ReadCacheKeyStore.markerPrefix) &&
        markerReadGate != null) {
      final started = markerReadStarted;
      if (started != null && !started.isCompleted) started.complete();
      await markerReadGate!.future;
    }
    if (key.startsWith(ReadCacheKeyStore.offlineKeyPrefix) &&
        offlineReadGate != null) {
      final started = offlineReadStarted;
      if (started != null && !started.isCompleted) started.complete();
      await offlineReadGate!.future;
    }
    if (failOfflineKeyRead &&
        key.startsWith(ReadCacheKeyStore.offlineKeyPrefix)) {
      throw StateError('synthetic unavailable');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    events.add('write:$key');
    if (failMarker && key.startsWith(ReadCacheKeyStore.markerPrefix)) {
      throw StateError('synthetic marker failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    events.add('delete:$key');
    if (failOfflineKeyDelete &&
        key.startsWith(ReadCacheKeyStore.offlineKeyPrefix)) {
      throw StateError('synthetic offline key failure');
    }
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (failInventory) throw StateError('synthetic inventory failure');
    return Map.of(values);
  }
}

class Namespace implements ReadCacheNamespace {
  Namespace(this.events);
  final List<String> events;
  Completer<void>? stopGate;
  bool marker = false, failStop = false;

  @override
  String get name => 'offline_repo';
  @override
  void fence(String accountKey) => events.add('fence:$accountKey');
  @override
  Future<void> stopAndWait(String accountKey) async {
    events.add('stop:$accountKey');
    await stopGate?.future;
    if (failStop) throw StateError('synthetic stop failure');
    events.add('stopped:$accountKey');
  }

  @override
  Future<void> deleteKey(String accountKey) async =>
      events.add('namespace-key:$accountKey');
  @override
  Future<void> deleteDirectory(String accountKey) async =>
      events.add('namespace-directory:$accountKey');
  @override
  void open(DiskBinding binding, ReadCacheDiskState mode) =>
      events.add('open:${binding.accountKey}:${mode.name}');
  @override
  Future<bool> hasMarker(String accountKey) async => marker;
}

final class SecurityNamespace extends Namespace
    implements ReadCacheNamespaceSecurity {
  SecurityNamespace(super.events);
  final calls = <(DiskBinding, int)>[];

  @override
  DiskInvalidationFence invalidatePermission(
    DiskBinding binding,
    int projectId,
  ) {
    calls.add((binding, projectId));
    return SecurityFence();
  }
}

final class SecurityFence implements DiskInvalidationFence {
  @override
  bool isCurrent = true;
  @override
  Future<DiskClearResult> get barrier => Future.value(
    const DiskClearResult(
      keyGoneConfirmed: false,
      directoryGoneConfirmed: false,
      markerDurable: false,
      complete: false,
    ),
  );
  @override
  Future<void> get quiesced => Future.value();
  @override
  void revoke() => isCurrent = false;
}

final class Harness {
  Harness() {
    keys = ReadCacheKeyStore(storage);
    files = ReadCacheFileStore(
      root: () async {
        final started = rootReadStarted;
        if (rootGate != null && started != null && !started.isCompleted) {
          started.complete();
        }
        await rootGate?.future;
        return root;
      },
    );
    cache = ReadCacheDiskCoordinator(
      coordinationScope: Object(),
      keys: keys,
      files: files,
      settings: ReadCacheSettingsStore(storage),
      controlsInstalled: true,
      schedule: (_, _) => () {},
    );
  }
  final root = Directory.systemTemp.createTempSync('c3-prereq-');
  final storage = MemoryStorage();
  late final ReadCacheKeyStore keys;
  late final ReadCacheFileStore files;
  late final ReadCacheDiskCoordinator cache;
  late final Namespace namespace = Namespace(storage.events);
  Completer<void>? rootGate, rootReadStarted;

  Directory directory(String name, String key) => Directory(
    '${root.path}/$name/${ReadCacheCipher.accountDirectoryName(key)}',
  );
  Future<void> seed(
    String key, {
    bool c2 = true,
    bool offline = true,
    bool refusal = false,
    bool marker = false,
  }) async {
    if (c2) {
      final dir = directory('read_cache', key)..createSync(recursive: true);
      File('${dir.path}/index.v1.bin').writeAsBytesSync([1, 2, 3]);
      await keys.writeKey(key, Uint8List(32));
    }
    if (offline) {
      final dir = directory('offline_repo', key)..createSync(recursive: true);
      File('${dir.path}/index.v99.bin').writeAsBytesSync([9, 8, 7]);
      storage.values[ReadCacheKeyStore.offlineKeyName(key)] = base64Url.encode(
        Uint8List(32),
      );
    }
    if (refusal) {
      storage.values[ReadCacheKeyStore.offlineRefusalName(key)] =
          'unknown refusal version';
    }
    if (marker) {
      storage.values[ReadCacheKeyStore.offlineMarkerName(key)] =
          '{"version":99}';
    }
  }

  Future<bool> recover({
    String? retained = account,
    bool signedOut = false,
    Object? owner,
  }) => cache.recover(
    ReadCacheStartupDecision(
      operationTicket: 1,
      accountListRevision: 1,
      accountsReadable: true,
      signOutMarkerReadable: true,
      lastActiveReadable: true,
      signOutPending: signedOut,
      resumeAccountKey: retained,
    ),
    accountKeys: {account, other},
    sessionOwner: owner,
  );

  void assertGone(String key) {
    expect(storage.values.containsKey(ReadCacheKeyStore.keyName(key)), isFalse);
    expect(
      storage.values.containsKey(ReadCacheKeyStore.offlineKeyName(key)),
      isFalse,
    );
    expect(
      storage.values.containsKey(ReadCacheKeyStore.offlineMarkerName(key)),
      isFalse,
    );
    expect(
      storage.values.containsKey(ReadCacheKeyStore.offlineRefusalName(key)),
      isFalse,
    );
    expect(directory('read_cache', key).existsSync(), isFalse);
    expect(directory('offline_repo', key).existsSync(), isFalse);
  }

  Future<void> dispose() async {
    final keyGate = storage.keyReadGate;
    if (keyGate != null && !keyGate.isCompleted) keyGate.complete();
    final offlineGate = storage.offlineReadGate;
    if (offlineGate != null && !offlineGate.isCompleted) offlineGate.complete();
    final markerGate = storage.markerReadGate;
    if (markerGate != null && !markerGate.isCompleted) markerGate.complete();
    final pendingRoot = rootGate;
    if (pendingRoot != null && !pendingRoot.isCompleted) pendingRoot.complete();
    if (namespace.stopGate != null && !namespace.stopGate!.isCompleted) {
      namespace.stopGate!.complete();
    }
    await cache.quiesced;
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(
    condition(),
    isTrue,
    reason: 'controlled operation failed to reach checkpoint',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('namespace prerequisites', () {
    late Harness h;
    setUp(() => h = Harness());
    tearDown(() => h.dispose());

    test(
      'B1 startup retains chosen account and refusal, clears other namespace orphans',
      () async {
        await h.seed(account, refusal: true);
        await h.seed(other, refusal: true);
        expect(await h.recover(), isTrue);
        expect(h.directory('read_cache', account).existsSync(), isTrue);
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
        expect(
          h.storage.values[ReadCacheKeyStore.offlineRefusalName(account)],
          isNotNull,
        );
        h.assertGone(other);
      },
    );

    test('B1 offline-only pending cleanup preserves retained C2', () async {
      await h.seed(account, marker: true);
      expect(await h.recover(), isTrue);
      expect(h.directory('read_cache', account).existsSync(), isTrue);
      expect((await h.keys.readKey(account)).isFound, isTrue);
      expect(h.directory('offline_repo', account).existsSync(), isFalse);
      expect(
        h.storage.values.containsKey(
          ReadCacheKeyStore.offlineMarkerName(account),
        ),
        isFalse,
      );
      expect(
        h.storage.values.containsKey(ReadCacheKeyStore.offlineKeyName(account)),
        isFalse,
      );
    });

    test(
      'B1 offline-only pending cleanup preserves retained refusal',
      () async {
        await h.seed(account, marker: true, refusal: true);
        expect(await h.recover(), isTrue);
        expect(h.directory('read_cache', account).existsSync(), isTrue);
        expect((await h.keys.readKey(account)).isFound, isTrue);
        expect(h.directory('offline_repo', account).existsSync(), isFalse);
        expect(
          h.storage.values.containsKey(
            ReadCacheKeyStore.offlineMarkerName(account),
          ),
          isFalse,
        );
        expect(
          h.storage.values.containsKey(
            ReadCacheKeyStore.offlineKeyName(account),
          ),
          isFalse,
        );
        expect(
          h.storage.values[ReadCacheKeyStore.offlineRefusalName(account)],
          'unknown refusal version',
        );
      },
    );

    test(
      'B5 v2 namespace repair marker survives restart without clearing offline data',
      () async {
        await h.seed(account, refusal: true);
        final marker = ReadCacheClearMarker(
          intentId: 'a' * 32,
          reason: ReadCacheClearReason.keyRepair,
          requestedAt: DateTime.utc(2026, 10, 28),
          namespaceOnly: true,
        );
        await h.keys.writeMarker(account, marker);
        final wire =
            jsonDecode(h.storage.values[ReadCacheKeyStore.markerName(account)]!)
                as Map<String, dynamic>;
        expect(wire['version'], 2);
        expect(wire['namespace'], 'read_cache');
        expect(await h.recover(), isTrue);
        expect(
          (await h.keys.readKey(account)).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(h.directory('read_cache', account).existsSync(), isFalse);
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
        expect(
          h.storage.values.containsKey(
            ReadCacheKeyStore.offlineKeyName(account),
          ),
          isTrue,
        );
        expect(
          h.storage.values[ReadCacheKeyStore.offlineRefusalName(account)],
          'unknown refusal version',
        );
        expect(
          (await h.keys.readMarker(account)).status,
          ReadCacheStoreReadStatus.absent,
        );
      },
    );

    for (final raw in [null, '{"version":99,"namespace":"read_cache"}']) {
      test(
        'B5 ${raw == null ? 'legacy v1' : 'unknown'} marker causes full account cleanup',
        () async {
          await h.seed(account, refusal: true);
          if (raw == null) {
            final marker = ReadCacheClearMarker(
              intentId: 'b' * 32,
              reason: ReadCacheClearReason.scopeInvalidation,
              requestedAt: DateTime.utc(2026, 10, 28),
            );
            await h.keys.writeMarker(account, marker);
            final wire =
                jsonDecode(
                      h.storage.values[ReadCacheKeyStore.markerName(account)]!,
                    )
                    as Map<String, dynamic>;
            expect(wire['version'], 1);
            expect(wire.containsKey('namespace'), isFalse);
          } else {
            h.storage.values[ReadCacheKeyStore.markerName(account)] = raw;
          }
          expect(await h.recover(), isTrue);
          h.assertGone(account);
        },
      );
    }

    test(
      'B1 malformed C2 inventory name preserves retained offline data and refusal',
      () async {
        await h.seed(account, refusal: true);
        final malformed = '${ReadCacheKeyStore.keyPrefix}%%%';
        h.storage.values[malformed] = 'invalid';
        expect(await h.recover(), isTrue);
        expect(h.storage.values.containsKey(malformed), isFalse);
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
        expect(
          h.storage.values.containsKey(
            ReadCacheKeyStore.offlineKeyName(account),
          ),
          isTrue,
        );
        expect(
          h.storage.values[ReadCacheKeyStore.offlineRefusalName(account)],
          'unknown refusal version',
        );
      },
    );

    test(
      'B1 corrupt offline root blocks recovery without deleting retained C2',
      () async {
        await h.seed(account);
        Directory(
          '${h.root.path}/offline_repo/invalid-account-name',
        ).createSync();
        expect(await h.recover(), isFalse);
        expect(h.directory('read_cache', account).existsSync(), isTrue);
        expect((await h.keys.readKey(account)).isFound, isTrue);
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
      },
    );

    test('B1 signed-out startup clears both namespaces', () async {
      await h.seed(account, marker: true, refusal: true);
      expect(await h.recover(signedOut: true, retained: null), isTrue);
      h.assertGone(account);
    });

    test(
      'B1 startup deletes keyless orphan directories in both namespaces',
      () async {
        await h.seed(account);
        const orphan = 'https://synthetic.example/subpath#99';
        for (final name in ['read_cache', 'offline_repo']) {
          final dir = h.directory(name, orphan)..createSync(recursive: true);
          File('${dir.path}/unknown.v99.bin').writeAsBytesSync([99]);
        }
        expect(await h.recover(), isTrue);
        expect(h.directory('read_cache', account).existsSync(), isTrue);
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
        h.assertGone(orphan);
      },
    );

    test(
      'B3 settings clear removes unknown offline content and markers',
      () async {
        await h.seed(account, marker: true, refusal: true);
        final result = await h.cache.clear(
          binding,
          ReadCacheCleanupOperation.settingsClear,
        );
        expect(result.complete, isTrue);
        h.assertGone(account);
      },
    );

    test('B3 off clears both namespaces across accounts', () async {
      await h.seed(account, marker: true, refusal: true);
      await h.seed(other, refusal: true);
      expect(await h.cache.setEnabled(false), isTrue);
      h.assertGone(account);
      h.assertGone(other);
    });

    test(
      'B3 marker and offline key failures still attempt both directories',
      () async {
        await h.seed(account, marker: true);
        h.storage.failMarker = true;
        h.storage.failOfflineKeyDelete = true;
        final result = await h.cache.clear(
          binding,
          ReadCacheCleanupOperation.settingsClear,
        );
        expect(result.complete, isFalse);
        expect(h.directory('read_cache', account).existsSync(), isFalse);
        expect(h.directory('offline_repo', account).existsSync(), isFalse);
        expect(
          h.storage.values.containsKey(
            ReadCacheKeyStore.offlineKeyName(account),
          ),
          isTrue,
        );
        expect(
          h.storage.values.containsKey(
            ReadCacheKeyStore.offlineMarkerName(account),
          ),
          isTrue,
        );
      },
    );

    test(
      'B3 unavailable inventory does not authorize device-off deletion',
      () async {
        await h.seed(account);
        h.storage.failInventory = true;
        expect(await h.cache.setEnabled(false), isFalse);
        expect(h.directory('read_cache', account).existsSync(), isTrue);
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
      },
    );

    test(
      'B4 fence before marker, drain before both keys, markers last',
      () async {
        await h.seed(account, marker: true, refusal: true);
        h.cache.register(h.namespace);
        h.storage.events.clear();
        h.namespace.stopGate = Completer<void>();
        final future = h.cache.clear(
          binding,
          ReadCacheCleanupOperation.settingsClear,
        );
        expect(h.storage.events, isNotEmpty);
        expect(h.storage.events.first, 'fence:$account');
        await until(() => h.storage.events.contains('stop:$account'));
        expect(
          h.storage.events.contains(
            'write:${ReadCacheKeyStore.markerName(account)}',
          ),
          isTrue,
        );
        expect(h.storage.events.where((e) => e.startsWith('delete:')), isEmpty);
        h.namespace.stopGate!.complete();
        expect((await future).complete, isTrue);
        final events = h.storage.events;
        final c2Key = events.indexOf(
          'delete:${ReadCacheKeyStore.keyName(account)}',
        );
        final offlineKey = events.indexOf('namespace-key:$account');
        final offlineDir = events.indexOf('namespace-directory:$account');
        final c2Marker = events.lastIndexOf(
          'delete:${ReadCacheKeyStore.markerName(account)}',
        );
        expect(
          events.indexOf('fence:$account'),
          lessThan(
            events.indexOf('write:${ReadCacheKeyStore.markerName(account)}'),
          ),
        );
        expect(events.indexOf('stopped:$account'), lessThan(c2Key));
        expect(events.indexOf('stopped:$account'), lessThan(offlineKey));
        expect(c2Key, lessThan(offlineDir));
        expect(offlineKey, lessThan(offlineDir));
        expect(offlineDir, lessThan(c2Marker));
        expect(
          events.lastIndexOf(
            'delete:${ReadCacheKeyStore.offlineMarkerName(account)}',
          ),
          lessThan(c2Marker),
        );
        h.assertGone(account);
      },
    );

    test('B4 failed stop never deletes keys or directories', () async {
      await h.seed(account);
      h.cache.register(h.namespace);
      h.namespace.failStop = true;
      h.storage.events.clear();
      expect(
        (await h.cache.clear(
          binding,
          ReadCacheCleanupOperation.settingsClear,
        )).complete,
        isFalse,
      );
      expect(h.directory('read_cache', account).existsSync(), isTrue);
      expect(h.directory('offline_repo', account).existsSync(), isTrue);
      expect(
        h.storage.values.containsKey(ReadCacheKeyStore.keyName(account)),
        isTrue,
      );
      expect(
        h.storage.values.containsKey(ReadCacheKeyStore.offlineKeyName(account)),
        isTrue,
      );
    });

    test(
      'B4 marker is durable while old C2 file I/O is still blocked',
      () async {
        await h.seed(account);
        expect(await h.recover(), isTrue);
        h.cache.register(h.namespace);
        h.storage.events.clear();
        h.rootGate = Completer<void>();
        h.rootReadStarted = Completer<void>();
        final activating = h.cache.activate(binding);
        await h.rootReadStarted!.future.timeout(const Duration(seconds: 5));
        final clearing = h.cache.clear(
          binding,
          ReadCacheCleanupOperation.signOut,
        );
        expect(h.storage.events, contains('fence:$account'));
        await until(
          () => h.storage.values.containsKey(
            ReadCacheKeyStore.markerName(account),
          ),
        );
        expect(h.storage.events.where((e) => e.startsWith('delete:')), isEmpty);
        h.rootGate!.complete();
        expect(await activating, isFalse);
        expect((await clearing).complete, isTrue);
        h.assertGone(account);
      },
    );

    test(
      'B5 empty C2 mutation succeeds without offline cleanup or marker writes',
      () async {
        await h.seed(account, c2: false);
        h.cache.register(h.namespace);
        expect(await h.recover(), isTrue);
        h.storage.events.clear();
        h.storage.failMarker = true;

        final fence = h.cache.invalidate(
          DiskInvalidation(
            binding: binding,
            kind: DiskInvalidationKind.mutation,
            scopeTags: {'project:1'},
          ),
        );

        expect((await fence.barrier).complete, isTrue);
        expect(
          h.storage.events.where((event) => !event.startsWith('read:')),
          isEmpty,
          reason:
              'an empty C2 scope must leave the offline namespace untouched',
        );
        expect(h.directory('read_cache', account).existsSync(), isFalse);
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
        expect(
          (await h.keys.readOfflineKey(account)).status,
          ReadCacheStoreReadStatus.found,
        );
      },
    );

    test('B5 missing C2 key repair leaves offline namespace intact', () async {
      await h.seed(account);
      await h.keys.deleteKey(account);
      expect(await h.recover(), isTrue);
      expect(await h.cache.activate(binding), isTrue);
      expect(h.directory('offline_repo', account).existsSync(), isTrue);
      expect(
        h.storage.values.containsKey(ReadCacheKeyStore.offlineKeyName(account)),
        isTrue,
      );
    });

    test(
      'B5 interrupted ordinary scoped invalidation recovers C2 only',
      () async {
        await h.seed(account, refusal: true);
        await h.files.writeIndex(
          account,
          Uint8List(32),
          ReadCacheIndex(entries: const []),
        );
        expect(await h.recover(), isTrue);
        expect(await h.cache.activate(binding), isTrue);
        h.storage.keyReadGate = Completer<void>();
        h.storage.keyReadStarted = Completer<void>();
        final fence = h.cache.invalidate(
          DiskInvalidation(
            binding: binding,
            kind: DiskInvalidationKind.mutation,
            scopeTags: {'project:1'},
          ),
        );
        await h.storage.keyReadStarted!.future.timeout(
          const Duration(seconds: 5),
        );
        final wire =
            jsonDecode(h.storage.values[ReadCacheKeyStore.markerName(account)]!)
                as Map<String, dynamic>;
        expect(wire['version'], 2);
        expect(wire['namespace'], 'read_cache');
        expect(wire['reason'], 'scopeInvalidation');

        final restarted = Harness();
        try {
          await restarted.seed(account, refusal: true);
          restarted.storage.values
            ..clear()
            ..addAll(h.storage.values);
          expect(await restarted.recover(), isTrue);
          expect(
            (await restarted.keys.readKey(account)).status,
            ReadCacheStoreReadStatus.absent,
          );
          expect(
            restarted.directory('read_cache', account).existsSync(),
            isFalse,
          );
          expect(
            restarted.directory('offline_repo', account).existsSync(),
            isTrue,
          );
          expect(
            restarted.storage.values.containsKey(
              ReadCacheKeyStore.offlineKeyName(account),
            ),
            isTrue,
          );
          expect(
            restarted.storage.values[ReadCacheKeyStore.offlineRefusalName(
              account,
            )],
            'unknown refusal version',
          );
          expect(
            (await restarted.keys.readMarker(account)).status,
            ReadCacheStoreReadStatus.absent,
          );
        } finally {
          await restarted.dispose();
          h.storage.keyReadGate!.complete();
          await fence.barrier;
        }
      },
    );

    test(
      'B5 unreadable C2 index scoped invalidation leaves offline namespace intact',
      () async {
        await h.seed(account);
        expect(await h.recover(), isTrue);
        expect(await h.cache.activate(binding), isTrue);
        final fence = h.cache.invalidate(
          DiskInvalidation(
            binding: binding,
            kind: DiskInvalidationKind.mutation,
            scopeTags: {'project:1'},
          ),
        );
        expect((await fence.barrier).complete, isTrue);
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
        expect(
          h.storage.values.containsKey(
            ReadCacheKeyStore.offlineKeyName(account),
          ),
          isTrue,
        );
      },
    );

    test(
      'B6 account invalidation clears both without UI subscribers',
      () async {
        await h.seed(account, refusal: true);
        final fence = h.cache.invalidate(
          DiskInvalidation(
            binding: binding,
            kind: DiskInvalidationKind.account,
          ),
        );
        expect((await fence.barrier).complete, isTrue);
        h.assertGone(account);
      },
    );

    for (final offline in [false, true]) {
      test(
        'B6 typed permission event forwards current ${offline ? 'offline' : 'online'} binding without UI',
        () async {
          await h.seed(account, c2: false);
          final owner = Object();
          h.cache.claimStartupSession(owner);
          expect(await h.recover(owner: owner), isTrue);
          final namespace = SecurityNamespace(h.storage.events);
          h.cache.register(namespace);
          if (offline) {
            expect(
              await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
              isTrue,
            );
          } else {
            expect(await h.cache.activate(binding), isTrue);
          }
          final fence = h.cache.invalidateProjectPermission(binding, 123);
          expect(fence.isCurrent, isTrue);
          expect(namespace.calls, [(binding, 123)]);
          const stale = DiskBinding(accountKey: account, generation: 0);
          final staleFence = h.cache.invalidateProjectPermission(stale, 321);
          expect(staleFence.isCurrent, isFalse);
          expect(namespace.calls, [(binding, 123)]);
          expect(
            () => h.cache.invalidateProjectPermission(binding, 0),
            throwsArgumentError,
          );
          expect(
            () => h.cache.invalidateProjectPermission(binding, -1),
            throwsArgumentError,
          );
          expect(namespace.calls, [(binding, 123)]);
        },
      );
    }

    test(
      'B6 missing project security handler fences then rejects event',
      () async {
        await h.seed(account, c2: false);
        expect(await h.recover(), isTrue);
        h.cache.register(h.namespace);
        expect(await h.cache.activate(binding), isTrue);
        h.storage.events.clear();
        expect(
          () => h.cache.invalidateProjectPermission(binding, 123),
          throwsStateError,
        );
        expect(h.storage.events, ['fence:$account']);
      },
    );

    test(
      'B7 closed qualification is read-only on absent or unavailable key',
      () async {
        await h.seed(account, offline: false);
        final owner = Object();
        h.cache.claimStartupSession(owner);
        expect(await h.recover(owner: owner), isTrue);
        h.storage.events.clear();
        expect(
          (await h.cache.readOfflineEligibilityKey(account)).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(
          h.storage.events.where(
            (e) => e.startsWith('write:') || e.startsWith('delete:'),
          ),
          isEmpty,
        );
        expect(h.directory('read_cache', account).existsSync(), isTrue);
        h.storage.failOfflineKeyRead = true;
        expect(
          (await h.cache.readOfflineEligibilityKey(account)).status,
          ReadCacheStoreReadStatus.unavailable,
        );
        expect(
          h.storage.events.where(
            (e) => e.startsWith('write:') || e.startsWith('delete:'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'B7 refusal and namespace marker block eligibility without deletion',
      () async {
        await h.seed(account, c2: false, refusal: true);
        final owner = Object();
        h.cache.claimStartupSession(owner);
        expect(await h.recover(owner: owner), isTrue);
        h.cache.register(h.namespace);
        h.storage.events.clear();
        expect(
          (await h.cache.readOfflineEligibilityKey(account)).status,
          ReadCacheStoreReadStatus.unavailable,
        );
        expect(
          await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
          isFalse,
        );
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
        expect(
          h.storage.events.where(
            (e) => e.startsWith('write:') || e.startsWith('delete:'),
          ),
          isEmpty,
        );
        h.storage.values.remove(ReadCacheKeyStore.offlineRefusalName(account));
        h.namespace.marker = true;
        expect(
          (await h.cache.readOfflineEligibilityKey(account)).status,
          ReadCacheStoreReadStatus.unavailable,
        );
        expect(
          await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
          isFalse,
        );
        expect(h.directory('offline_repo', account).existsSync(), isTrue);
      },
    );

    for (final off in [false, true]) {
      test(
        'B7 ${off ? 'device off' : 'account clear'} fences pending offline admission',
        () async {
          await h.seed(account, c2: false);
          final owner = Object();
          h.cache.claimStartupSession(owner);
          expect(await h.recover(owner: owner), isTrue);
          h.cache.register(h.namespace);
          h.storage.events.clear();
          final gate = Completer<void>();
          h.storage.offlineReadGate = gate;
          h.storage.offlineReadStarted = Completer<void>();
          final entering = h.cache.enterOfflineReadOnly(
            binding,
            sessionOwner: owner,
          );
          await h.storage.offlineReadStarted!.future.timeout(
            const Duration(seconds: 5),
          );
          final clearing = off
              ? h.cache.setEnabled(false).then((value) => value)
              : h.cache
                    .clear(binding, ReadCacheCleanupOperation.signOut)
                    .then((value) => value.complete);
          expect(
            h.cache.state(account),
            isNot(ReadCacheDiskState.offlineReadOnly),
          );
          expect(h.storage.events, contains('fence:$account'));
          h.storage.offlineReadGate = null;
          gate.complete();
          expect(await entering, isFalse);
          expect(
            h.storage.events.where((event) => event.startsWith('open:')),
            isEmpty,
          );
          expect(await clearing, isTrue);
          expect(
            h.cache.state(account),
            isNot(ReadCacheDiskState.offlineReadOnly),
          );
          h.assertGone(account);
        },
      );
    }

    test('B7 offline admission is fenced and closes synchronously', () async {
      await h.seed(account, c2: false);
      final owner = Object();
      h.cache.claimStartupSession(owner);
      expect(await h.recover(owner: owner), isTrue);
      h.cache.register(h.namespace);
      expect(
        await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
        isTrue,
      );
      expect(h.cache.state(account), ReadCacheDiskState.offlineReadOnly);
      expect(h.storage.events, contains('open:$account:offlineReadOnly'));
      h.cache.closeOfflineReadOnly(binding, sessionOwner: owner);
      expect(h.cache.state(account), ReadCacheDiskState.closed);
      expect(h.storage.events.last, 'fence:$account');
      expect(h.directory('offline_repo', account).existsSync(), isTrue);
    });

    test('B7 verified activation moves offline read-only to ready', () async {
      await h.seed(account, c2: false);
      final owner = Object();
      h.cache.claimStartupSession(owner);
      expect(await h.recover(owner: owner), isTrue);
      h.cache.register(h.namespace);
      expect(
        await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
        isTrue,
      );
      const online = DiskBinding(accountKey: account, generation: 2);
      expect(await h.cache.activate(online), isTrue);
      expect(h.cache.state(account), ReadCacheDiskState.ready);
      expect(h.storage.events, contains('open:$account:ready'));
      expect(h.directory('offline_repo', account).existsSync(), isTrue);
    });

    test(
      'B7 activation fences old offline binding before waiting for marker I/O',
      () async {
        await h.seed(account, c2: false);
        final owner = Object();
        h.cache.claimStartupSession(owner);
        expect(await h.recover(owner: owner), isTrue);
        h.cache.register(h.namespace);
        expect(
          await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
          isTrue,
        );
        h.storage.events.clear();
        final gate = Completer<void>();
        h.storage.markerReadGate = gate;
        h.storage.markerReadStarted = Completer<void>();
        const online = DiskBinding(accountKey: account, generation: 2);
        final activating = h.cache.activate(online);
        expect(h.storage.events.first, 'fence:$account');
        expect(h.cache.state(account), ReadCacheDiskState.closed);
        await h.storage.markerReadStarted!.future.timeout(
          const Duration(seconds: 5),
        );
        expect(
          h.storage.events.where((event) => event.startsWith('open:')),
          isEmpty,
        );
        h.storage.markerReadGate = null;
        gate.complete();
        expect(await activating, isTrue);
        expect(h.storage.events, contains('open:$account:ready'));
      },
    );

    test(
      'B7 clear synchronously moves offline read-only to cleaning',
      () async {
        await h.seed(account, c2: false);
        final owner = Object();
        h.cache.claimStartupSession(owner);
        expect(await h.recover(owner: owner), isTrue);
        h.cache.register(h.namespace);
        expect(
          await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
          isTrue,
        );
        h.namespace.stopGate = Completer<void>();
        final clear = h.cache.clear(binding, ReadCacheCleanupOperation.signOut);
        expect(h.cache.state(account), ReadCacheDiskState.cleaning);
        expect(h.storage.events, contains('fence:$account'));
        await until(() => h.storage.events.contains('stop:$account'));
        h.namespace.stopGate!.complete();
        expect((await clear).complete, isTrue);
        h.assertGone(account);
      },
    );

    test(
      'B4 late namespace registration cannot open over a pending marker',
      () async {
        await h.seed(account, c2: false);
        expect(await h.recover(), isTrue);
        expect(await h.cache.activate(binding), isTrue);
        h.storage.values[ReadCacheKeyStore.offlineMarkerName(account)] =
            'pending';
        h.storage.events.clear();
        h.cache.register(h.namespace);
        await Future<void>.delayed(Duration.zero);
        expect(h.storage.events, contains('fence:$account'));
        expect(
          h.storage.events.where((event) => event.startsWith('open:')),
          isEmpty,
        );
      },
    );

    test(
      'B9 background suspension never fences or stops offline worker',
      () async {
        await h.seed(account, c2: false);
        final owner = Object();
        h.cache.claimStartupSession(owner);
        expect(await h.recover(owner: owner), isTrue);
        h.cache.register(h.namespace);
        expect(
          await h.cache.enterOfflineReadOnly(binding, sessionOwner: owner),
          isTrue,
        );
        h.storage.events.clear();
        h.cache.background();
        expect(h.cache.state(account), ReadCacheDiskState.offlineReadOnly);
        expect(
          h.storage.events.where(
            (e) => e.startsWith('fence:') || e.startsWith('stop:'),
          ),
          isEmpty,
        );
      },
    );
  });
  group('session prerequisites', _sessionPrerequisiteTests);
}

Account _account(int id) => Account(
  instance: GitLabInstance.parse('https://synthetic.example/gitlab'),
  user: GitLabUser(id: id, username: 'user$id', name: 'User $id'),
  token: 'synthetic-$id',
);

final class _Storage extends EmptyReadCacheStorage {
  Completer<void>? deletionGate;
  Completer<void>? deleteStarted;

  @override
  Future<void> delete(String key) async {
    if (key.startsWith(ReadCacheKeyStore.keyPrefix) && deletionGate != null) {
      if (!(deleteStarted?.isCompleted ?? true)) deleteStarted!.complete();
      await deletionGate!.future;
    }
    await super.delete(key);
  }
}

final class _AccountStore extends MemoryAccountStore {
  final markerWrites = <bool>[];
  Completer<void>? saveGate, saveStarted;
  @override
  Future<void> save(List<Account> value) async {
    if (!(saveStarted?.isCompleted ?? true)) saveStarted!.complete();
    await saveGate?.future;
    await super.save(value);
  }

  @override
  Future<void> saveSignOutPending(bool pending) async {
    markerWrites.add(pending);
    await super.saveSignOutPending(pending);
  }
}

final class _Browser implements AuthorizationBrowser {
  @override
  Future<Uri> authenticate({
    required Uri authorizationUrl,
    required Uri callbackUrl,
  }) async => Uri.parse(
    '$callbackUrl?code=synthetic-code&state=${authorizationUrl.queryParameters['state']}',
  );
}

final class _Harness {
  _Harness() {
    cache = ReadCacheDiskCoordinator(
      coordinationScope: Object(),
      keys: keys,
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
    );
    addTearDown(() async {
      final gate = storage.deletionGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      final accountGate = store.saveGate;
      if (accountGate != null && !accountGate.isCompleted) {
        accountGate.complete();
      }
      for (final session in sessions) {
        if (!session.isDisposed) session.dispose();
      }
      await cache.quiesced;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  }

  final root = Directory.systemTemp.createTempSync('read-cache-c3-session-');
  final store = _AccountStore();
  final storage = _Storage();
  late final keys = ReadCacheKeyStore(storage);
  late final ReadCacheDiskCoordinator cache;
  final sessions = <SessionController>[];
  bool failUser = true;
  bool rejectUser = false;
  int userId = 2;
  Completer<void>? userGate;
  Completer<void>? userStarted;

  SessionController controller() {
    final session = SessionController(
      store,
      readCache: cache,
      browser: _Browser(),
      applicationIdFor: (_) => 'synthetic-client',
      createOAuth: (instance, clientId) => OAuthTokenClient(
        instance: instance,
        clientId: clientId,
        dio: Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => jsonResponse({
              'access_token': 'synthetic-access',
              'refresh_token': 'synthetic-refresh',
              'token_type': 'bearer',
            }),
          ),
      ),
      createApi: (instance, credential, oauth, rotated) => GitLabApi(
        instance: instance,
        credential: credential,
        oauth: oauth,
        onOAuthRotated: rotated,
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((_) async {
            if (!(userStarted?.isCompleted ?? true)) userStarted!.complete();
            await userGate?.future;
            if (rejectUser) {
              return jsonResponse({
                'message': 'synthetic unauthorized',
              }, status: 401);
            }
            if (failUser) {
              return jsonResponse({'message': 'synthetic outage'}, status: 503);
            }
            return jsonResponse({'id': userId, 'username': 'user$userId'});
          }),
      ),
    );
    sessions.add(session);
    return session;
  }

  Future<SessionController> recoverRemembered(Account account) async {
    store.accounts = [account];
    store.lastActive = account.key;
    await keys.writeKey(account.key, Uint8List.fromList(List.filled(32, 17)));
    final session = controller();
    await session.initialize();
    final decision = session.readCacheStartupDecision!;
    expect(
      await cache.recover(
        decision,
        accountKeys: {account.key},
        sessionOwner: session,
      ),
      isTrue,
    );
    expect(cache.diskRetainedAccountKey, account.key);
    return session;
  }
}

void _sessionPrerequisiteTests() {
  test(
    'superseded removal restores its staged account after artifact cleanup',
    () async {
      final h = _Harness();
      final saved = _account(1);
      h.store.accounts = [saved];
      final session = h.controller();
      await session.initialize();
      final entered = Completer<void>();
      final release = Completer<void>();
      final oldRoot = artifactStorageRoot;
      artifactStorageRoot = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return h.root;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        artifactStorageRoot = oldRoot;
      });
      final removing = session.remove(saved);
      await entered.future;
      expect(session.accounts, isEmpty);
      await session.endSession();
      release.complete();

      final result = await removing;
      expect(result.removed, isFalse);
      expect(session.accounts.map((account) => account.key), [saved.key]);
      expect(h.store.accounts.map((account) => account.key), [saved.key]);
      final decision = session.readCacheStartupDecision;
      expect(decision, isNotNull);
      expect(session.isReadCacheDecisionCurrent(decision!), isTrue);
      expect(decision.signOutPending, isTrue);
    },
  );

  test(
    'B8 failed same-account retry keeps last-active and cache on restart',
    () async {
      final h = _Harness();
      final saved = _account(1);
      final session = await h.recoverRemembered(saved);
      final writes = h.store.lastActiveWrites;
      h.store.markerWrites.clear();

      await session.select(saved);

      expect(session.active, isNull);
      expect(h.store.lastActive, saved.key);
      expect(h.store.lastActiveWrites, writes);
      expect(h.store.markerWrites, isEmpty);
      expect(session.readCacheStartupDecision!.resumeAccountKey, saved.key);
      expect((await h.keys.readKey(saved.key)).isFound, isTrue);

      session.dispose();
      final restarted = h.controller();
      await restarted.initialize();
      final decision = restarted.readCacheStartupDecision!;
      expect(
        await h.cache.recover(
          decision,
          accountKeys: {saved.key},
          sessionOwner: restarted,
        ),
        isTrue,
      );
      expect(h.cache.diskRetainedAccountKey, saved.key);
      expect((await h.keys.readKey(saved.key)).isFound, isTrue);
    },
  );

  test('B8 retry during startup scan preserves the resume decision', () async {
    final h = _Harness();
    final saved = _account(1);
    h.store.accounts = [saved];
    h.store.lastActive = saved.key;
    final session = h.controller();
    await session.initialize();
    h.store.markerWrites.clear();
    await session.select(saved);
    expect(h.store.lastActive, saved.key);
    expect(h.store.markerWrites, isEmpty);
    expect(session.readCacheStartupDecision!.resumeAccountKey, saved.key);
  });

  test('B8 terminal rejection still clears the remembered account', () async {
    final h = _Harness();
    final saved = _account(1);
    final session = await h.recoverRemembered(saved);
    h.rejectUser = true;
    await session.select(saved);
    await h.cache.quiesced;
    expect(h.store.lastActive, isNull);
    expect(session.readCacheStartupDecision!.resumeAccountKey, isNull);
    expect((await h.keys.readKey(saved.key)).isFound, isFalse);
  });

  test('explicit sign-out fences the resume account before its scan', () async {
    final h = _Harness();
    final saved = _account(1);
    h.store.accounts = [saved];
    h.store.lastActive = saved.key;
    await h.keys.writeKey(saved.key, Uint8List.fromList(List.filled(32, 17)));
    final session = h.controller();
    await session.initialize();

    await session.endSession();
    await h.cache.quiesced;

    expect(h.store.lastActive, isNull);
    expect((await h.keys.readKey(saved.key)).isFound, isFalse);
  });

  test(
    'B11 connect fences a saved account before startup inventory runs',
    () async {
      final h = _Harness();
      final saved = _account(1);
      h.store.accounts = [saved];
      h.store.lastActive = saved.key;
      await h.keys.writeKey(saved.key, Uint8List.fromList(List.filled(32, 17)));
      final session = h.controller();
      await session.initialize();
      h.failUser = false;
      h.storage.deletionGate = Completer<void>();
      h.storage.deleteStarted = Completer<void>();

      await session.connect(
        'https://synthetic.example/gitlab',
        'synthetic-new',
      );
      expect(h.cache.state(saved.key), ReadCacheDiskState.cleaning);
      await h.storage.deleteStarted!.future.timeout(const Duration(seconds: 5));
      expect(session.active!.user.id, 2);
      h.storage.deletionGate!.complete();
      await h.cache.quiesced;
      expect((await h.keys.readKey(saved.key)).isFound, isFalse);
    },
  );

  for (final oauth in [false, true]) {
    test(
      'B11 ${oauth ? 'OAuth' : 'PAT'} fences retained account before new binding without waiting for delete',
      () async {
        final h = _Harness();
        final saved = _account(1);
        final session = await h.recoverRemembered(saved);
        h.failUser = false;
        h.storage.deletionGate = Completer<void>();
        h.storage.deleteStarted = Completer<void>();

        if (oauth) {
          await session.connectOAuth('https://synthetic.example/gitlab');
        } else {
          await session.connect(
            'https://synthetic.example/gitlab',
            'synthetic-new',
          );
        }
        expect(h.cache.state(saved.key), ReadCacheDiskState.cleaning);
        await h.storage.deleteStarted!.future.timeout(
          const Duration(seconds: 5),
        );

        expect(session.active!.user.id, 2);
        expect(session.api!.isReadCacheBound, isTrue);
        expect(h.cache.diskRetainedAccountKey, session.active!.key);
        expect((await h.keys.readKey(saved.key)).isFound, isTrue);
        h.storage.deletionGate!.complete();
        await h.cache.quiesced;
        expect((await h.keys.readKey(saved.key)).isFound, isFalse);
      },
    );
  }

  test('B10 replaced controller cannot publish a delayed activation', () async {
    final h = _Harness();
    final saved = _account(1);
    h.store.accounts = [saved];
    h.store.lastActive = saved.key;
    h.failUser = false;
    h.userId = 1;
    h.userGate = Completer<void>();
    h.userStarted = Completer<void>();
    final old = h.controller();
    final initialization = old.initialize();
    await h.userStarted!.future;
    final replacement = h.controller();
    h.cache.retainDiskAccount('replacement', sessionOwner: replacement);
    h.userGate!.complete();
    await initialization;

    expect(old.active, isNull);
    expect(h.cache.diskRetainedAccountKey, 'replacement');
  });

  test('B10 settings clear preserves the current retained selection', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.seed(account);
    final owner = Object();
    h.cache.claimStartupSession(owner);
    expect(await h.recover(owner: owner), isTrue);
    expect(await h.cache.activate(binding), isTrue);
    expect(h.cache.diskRetainedAccountKey, account);

    expect(
      (await h.cache.clear(
        binding,
        ReadCacheCleanupOperation.settingsClear,
      )).complete,
      isTrue,
    );
    await h.cache.quiesced;
    expect(h.cache.diskRetainedAccountKey, account);
  });

  test('B10 old clear cannot erase a new same-account activation', () async {
    final h = _Harness();
    final saved = _account(1);
    final session = await h.recoverRemembered(saved);
    h.failUser = false;
    h.userId = 1;
    await session.select(saved);
    await h.cache.quiesced;
    expect(session.active!.key, saved.key);

    h.storage.deletionGate = Completer<void>();
    h.storage.deleteStarted = Completer<void>();
    await session.select(saved);
    expect(session.active!.key, saved.key);
    expect(h.cache.diskRetainedAccountKey, saved.key);
    await h.storage.deleteStarted!.future.timeout(const Duration(seconds: 5));
    h.storage.deletionGate!.complete();
    await h.cache.quiesced;
    expect(h.cache.diskRetainedAccountKey, saved.key);
  });

  test('B10 confirmed removal clears an inactive retained selection', () async {
    final h = _Harness();
    final saved = _account(1);
    final session = await h.recoverRemembered(saved);
    expect(session.active, isNull);
    expect((await session.remove(saved)).removed, isTrue);
    expect(h.cache.diskRetainedAccountKey, isNull);
    expect(h.store.accounts, isEmpty);
  });

  test('B10 stale removal save cannot overwrite a newer owner', () async {
    final h = _Harness();
    final saved = _account(1);
    final session = await h.recoverRemembered(saved);
    h.store.saveGate = Completer<void>();
    h.store.saveStarted = Completer<void>();
    final removal = session.remove(saved);
    await h.store.saveStarted!.future.timeout(const Duration(seconds: 5));
    final replacement = h.controller();
    h.cache.retainDiskAccount(saved.key, sessionOwner: replacement);
    h.store.saveGate!.complete();
    expect((await removal).removed, isTrue);
    expect(h.cache.diskRetainedAccountKey, saved.key);
  });
}
