import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';

void main() {
  group('read-cache key primitives', () {
    test(
      'uses padded base64url names and never creates a key on read',
      () async {
        final storage = _MemorySecureStorage();
        final store = ReadCacheKeyStore(storage);

        expect(ReadCacheKeyStore.keyName('a'), 'read_cache_key.v1.YQ==');
        expect(
          ReadCacheKeyStore.markerName('a'),
          'read_cache_clear_pending.v1.YQ==',
        );
        expect(
          (await store.readKey('a')).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(storage.values, isEmpty);
        expect(storage.writeCount, 0);
      },
    );

    test('round trips exactly 32 bytes and returns defensive copies', () async {
      final storage = _MemorySecureStorage();
      final store = ReadCacheKeyStore(storage);
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));

      await store.writeKey('account', key);
      key[0] = 255;

      final found = await store.readKey('account');
      expect(found.status, ReadCacheStoreReadStatus.found);
      expect(found.value, orderedEquals(List<int>.generate(32, (i) => i)));
      expect(
        storage.values[ReadCacheKeyStore.keyName('account')],
        base64Url.encode(List<int>.generate(32, (i) => i)),
      );
      found.value![0] = 254;
      expect((await store.readKey('account')).value![0], 0);
    });

    test('malformed keys are absent with a typed safe diagnostic', () async {
      final storage = _MemorySecureStorage()
        ..values[ReadCacheKeyStore.keyName('private-account')] = 'secret%raw';
      final result = await ReadCacheKeyStore(
        storage,
      ).readKey('private-account');

      expect(result.status, ReadCacheStoreReadStatus.absent);
      expect(result.failure?.kind, ReadCacheStoreFailureKind.malformed);
      expect('$result ${result.failure}', isNot(contains('secret%raw')));
      expect('$result ${result.failure}', isNot(contains('private-account')));
    });

    test(
      'read unavailable is distinct from absence and keeps no raw error',
      () async {
        final storage = _MemorySecureStorage()..failRead = true;
        final result = await ReadCacheKeyStore(storage).readKey('account');

        expect(result.status, ReadCacheStoreReadStatus.unavailable);
        expect(result.failure?.kind, ReadCacheStoreFailureKind.unavailable);
        expect(
          '${result.failure}',
          isNot(contains(_MemorySecureStorage.rawError)),
        );
      },
    );

    test('rejects non-32-byte values before storage', () async {
      final storage = _MemorySecureStorage();

      for (final size in <int>[0, 31, 33]) {
        await expectLater(
          ReadCacheKeyStore(storage).writeKey('account', Uint8List(size)),
          throwsA(_failure(ReadCacheStoreFailureKind.invalidValue)),
        );
      }
      expect(storage.writeCount, 0);
      expect(storage.readCount, 0);
      expect(storage.values, isEmpty);
    });

    test(
      'malformed length or noncanonical encoding never repairs a key',
      () async {
        final valid = base64Url.encode(Uint8List(32));
        for (final raw in <String>[
          '',
          base64Url.encode(Uint8List(31)),
          base64Url.encode(Uint8List(33)),
          valid.replaceAll('=', ''),
          '${valid.substring(0, valid.length - 2)}B=',
        ]) {
          final name = ReadCacheKeyStore.keyName('a');
          final storage = _MemorySecureStorage()..values[name] = raw;
          final read = await ReadCacheKeyStore(storage).readKey('a');
          expect(read.status, ReadCacheStoreReadStatus.absent, reason: raw);
          expect(read.value, isNull);
          expect(read.failure?.kind, ReadCacheStoreFailureKind.malformed);
          expect(storage.values[name], raw);
          expect(storage.writeCount, 0);
          expect(storage.deleteCount, 0);
        }
      },
    );

    test(
      'successful delete is idempotent and confirms absence each time',
      () async {
        final storage = _MemorySecureStorage();
        final store = ReadCacheKeyStore(storage);
        await store.writeKey('a', Uint8List(32));
        await store.deleteKey('a');
        await store.deleteKey('a');
        expect(storage.values, isEmpty);
        expect(storage.deleteCount, 2);
        expect(storage.readCount, 3);
        expect(
          (await store.readKey('a')).status,
          ReadCacheStoreReadStatus.absent,
        );
      },
    );

    test('write and delete require exact successful readback', () async {
      final key = Uint8List(32);

      final writeFailure = _MemorySecureStorage()..failWrite = true;
      await expectLater(
        ReadCacheKeyStore(writeFailure).writeKey('a', key),
        throwsA(_failure(ReadCacheStoreFailureKind.unavailable)),
      );

      final writeMismatch = _MemorySecureStorage()..replaceAfterWrite = true;
      await expectLater(
        ReadCacheKeyStore(writeMismatch).writeKey('a', key),
        throwsA(_failure(ReadCacheStoreFailureKind.readbackMismatch)),
      );

      final deleteFailure = _MemorySecureStorage()
        ..values[ReadCacheKeyStore.keyName('a')] = base64Url.encode(key)
        ..failDelete = true;
      await expectLater(
        ReadCacheKeyStore(deleteFailure).deleteKey('a'),
        throwsA(_failure(ReadCacheStoreFailureKind.unavailable)),
      );

      final deleteMismatch = _MemorySecureStorage()
        ..values[ReadCacheKeyStore.keyName('a')] = base64Url.encode(key)
        ..retainAfterDelete = true;
      await expectLater(
        ReadCacheKeyStore(deleteMismatch).deleteKey('a'),
        throwsA(_failure(ReadCacheStoreFailureKind.readbackMismatch)),
      );
    });
  });

  group('pending-clear marker primitives', () {
    test(
      'writes the exact versioned UTC JSON and reads every reason',
      () async {
        final requestedAt = DateTime.parse('2026-10-23T01:02:03.004Z');
        for (final reason in ReadCacheClearReason.values) {
          final storage = _MemorySecureStorage();
          final store = ReadCacheKeyStore(storage);
          final intentId = reason.index.toRadixString(16).padLeft(32, '0');
          final marker = ReadCacheClearMarker(
            intentId: intentId,
            reason: reason,
            requestedAt: requestedAt,
          );

          await store.writeMarker('a', marker);

          expect(
            storage.values[ReadCacheKeyStore.markerName('a')],
            '{"version":1,"intentId":"$intentId",'
            '"reason":"${reason.name}",'
            '"requestedAt":"2026-10-23T01:02:03.004Z"}',
          );
          final read = await store.readMarker('a');
          expect(read.status, ReadCacheStoreReadStatus.found);
          expect(read.value, marker);
          expect(read.value!.requiresFullClear, isTrue);
        }
      },
    );

    test(
      'normalizes constructor time to UTC and restricts opaque intent IDs',
      () {
        final instant = DateTime.parse('2026-10-23T09:02:03.004+08:00');
        final marker = ReadCacheClearMarker(
          intentId: '0123456789abcdef0123456789abcdef',
          reason: ReadCacheClearReason.startup,
          requestedAt: instant,
        );
        expect(marker.requestedAt.isUtc, isTrue);
        expect(marker.toJson()['requestedAt'], '2026-10-23T01:02:03.004Z');
        for (final intentId in [
          '',
          'a' * 31,
          'a' * 33,
          'A' * 32,
          'g' * 32,
          'private-account-operation',
          '${'a' * 32}\n',
        ]) {
          expect(
            () => ReadCacheClearMarker(
              intentId: intentId,
              reason: ReadCacheClearReason.startup,
              requestedAt: instant,
            ),
            throwsA(_failure(ReadCacheStoreFailureKind.invalidValue)),
          );
        }
      },
    );

    test('absence and unavailable markers never write or delete', () async {
      final storage = _MemorySecureStorage();
      final store = ReadCacheKeyStore(storage);
      final absent = await store.readMarker('a');
      expect(absent.status, ReadCacheStoreReadStatus.absent);
      expect(absent.value, isNull);
      expect(absent.failure, isNull);
      storage.failRead = true;
      final unavailable = await store.readMarker('a');
      expect(unavailable.status, ReadCacheStoreReadStatus.unavailable);
      expect(unavailable.value, isNull);
      expect(unavailable.failure?.kind, ReadCacheStoreFailureKind.unavailable);
      expect(storage.writeCount, 0);
      expect(storage.deleteCount, 0);
    });

    test(
      'every malformed marker shape stays pending without repairs',
      () async {
        final valid = <String, Object?>{
          'version': 1,
          'intentId': '0123456789abcdef0123456789abcdef',
          'reason': 'startup',
          'requestedAt': '2026-10-23T01:02:03.004Z',
        };
        final malformed = <Object?>[
          null,
          <Object?>[],
          'marker',
          <String, Object?>{},
          {...valid, 'version': 1.0},
          {...valid, 'version': '1'},
          {...valid, 'intentId': ''},
          {...valid, 'intentId': 1},
          for (final intentId in [
            'a' * 31,
            'a' * 33,
            'A' * 32,
            'g' * 32,
            'private-account-operation',
            '${'a' * 32}\n',
          ])
            {...valid, 'intentId': intentId},
          {...valid, 'reason': null},
          {...valid, 'requestedAt': 0},
          {...valid, 'requestedAt': '2026-02-30T01:02:03.004Z'},
          {...valid, 'requestedAt': '2026-10-23T01:02:03.004+00:00'},
          {...valid, 'extra': 'unexpected'},
          {...valid}..remove('reason'),
        ];
        for (final value in malformed) {
          final raw = jsonEncode(value);
          final name = ReadCacheKeyStore.markerName('a');
          final storage = _MemorySecureStorage()..values[name] = raw;
          final read = await ReadCacheKeyStore(storage).readMarker('a');
          expect(read.status, ReadCacheStoreReadStatus.found, reason: raw);
          expect(read.value, isA<MalformedReadCacheClearMarker>(), reason: raw);
          expect(read.value!.requiresFullClear, isTrue);
          expect('${read.value}', isNot(contains(raw)));
          expect(storage.values[name], raw);
          expect(storage.writeCount, 0);
          expect(storage.deleteCount, 0);
        }
      },
    );

    test(
      'unknown or malformed marker stays present and pending full clear',
      () async {
        for (final raw in <String>[
          'not-json-private-content',
          '{"version":2,"intentId":"0123456789abcdef0123456789abcdef","reason":"startup","requestedAt":"2026-10-23T01:02:03.004Z"}',
          '{"version":1,"intentId":"0123456789abcdef0123456789abcdef","reason":"unknown","requestedAt":"2026-10-23T01:02:03.004Z"}',
          '{"version":1,"intentId":"0123456789abcdef0123456789abcdef","reason":"startup","requestedAt":"2026-10-23 01:02:03"}',
        ]) {
          final storage = _MemorySecureStorage()
            ..values[ReadCacheKeyStore.markerName('a')] = raw;
          final read = await ReadCacheKeyStore(storage).readMarker('a');

          expect(read.status, ReadCacheStoreReadStatus.found);
          expect(read.value, isA<MalformedReadCacheClearMarker>());
          expect(read.value!.requiresFullClear, isTrue);
          expect('$read ${read.failure}', isNot(contains(raw)));
        }
      },
    );

    test(
      'marker write and delete use the same exact readback contract',
      () async {
        final marker = ReadCacheClearMarker(
          intentId: '0123456789abcdef0123456789abcdef',
          reason: ReadCacheClearReason.accountClear,
          requestedAt: DateTime.utc(2026, 10, 23),
        );
        final mismatch = _MemorySecureStorage()..replaceAfterWrite = true;
        await expectLater(
          ReadCacheKeyStore(mismatch).writeMarker('a', marker),
          throwsA(_failure(ReadCacheStoreFailureKind.readbackMismatch)),
        );

        final retained = _MemorySecureStorage()
          ..values[ReadCacheKeyStore.markerName('a')] = jsonEncode(
            marker.toJson(),
          )
          ..retainAfterDelete = true;
        await expectLater(
          ReadCacheKeyStore(retained).deleteMarker('a'),
          throwsA(_failure(ReadCacheStoreFailureKind.readbackMismatch)),
        );
      },
    );

    test(
      'semantic-equivalent marker readback still must match exact bytes',
      () async {
        final marker = ReadCacheClearMarker(
          intentId: '0123456789abcdef0123456789abcdef',
          reason: ReadCacheClearReason.startup,
          requestedAt: DateTime.utc(2026, 10, 23),
        );
        final storage = _MemorySecureStorage()
          ..rewriteAfterWrite = (value) => ' $value';
        await expectLater(
          ReadCacheKeyStore(storage).writeMarker('a', marker),
          throwsA(_failure(ReadCacheStoreFailureKind.readbackMismatch)),
        );
        final read = await ReadCacheKeyStore(storage).readMarker('a');
        expect(read.value, marker);
      },
    );

    test('successful marker deletion is confirmed and idempotent', () async {
      final storage = _MemorySecureStorage();
      final store = ReadCacheKeyStore(storage);
      await store.writeMarker(
        'a',
        ReadCacheClearMarker(
          intentId: '0123456789abcdef0123456789abcdef',
          reason: ReadCacheClearReason.startup,
          requestedAt: DateTime.utc(2026, 10, 23),
        ),
      );
      await store.deleteMarker('a');
      await store.deleteMarker('a');
      expect(
        (await store.readMarker('a')).status,
        ReadCacheStoreReadStatus.absent,
      );
      expect(storage.values, isEmpty);
      expect(storage.deleteCount, 2);
    });
  });

  group('all mutations fail closed on storage and readback faults', () {
    final marker = ReadCacheClearMarker(
      intentId: '0123456789abcdef0123456789abcdef',
      reason: ReadCacheClearReason.accountClear,
      requestedAt: DateTime.utc(2026, 10, 23),
    );
    final mutations = <String, Future<void> Function(ReadCacheKeyStore)>{
      'writeKey': (store) => store.writeKey('a', Uint8List(32)),
      'writeMarker': (store) => store.writeMarker('a', marker),
      'deleteKey': (store) => store.deleteKey('a'),
      'deleteMarker': (store) => store.deleteMarker('a'),
      'deleteInventoryName': (store) =>
          store.deleteInventoryName('${ReadCacheKeyStore.keyPrefix}%%%'),
    };
    for (final mutation in mutations.entries) {
      test(
        '${mutation.key}: native and readback failures are sanitized',
        () async {
          for (final failReadback in <bool>[false, true]) {
            for (final typedNativeError in <bool>[false, true]) {
              final storage = _MemorySecureStorage()
                ..failRead = failReadback
                ..failWrite = !failReadback
                ..failDelete = !failReadback
                ..typedNativeError = typedNativeError;
              try {
                await mutation.value(ReadCacheKeyStore(storage));
                fail('Mutation must not succeed without confirmed readback');
              } on ReadCacheStoreException catch (error) {
                expect(
                  error.failure.kind,
                  ReadCacheStoreFailureKind.unavailable,
                );
                expect(error.failure.operation, mutation.key);
                expect(
                  '$error',
                  isNot(contains(_MemorySecureStorage.rawError)),
                );
              }
              expect(storage.readCount, failReadback ? 1 : 0);
            }
          }
        },
      );
    }
  });

  group('independent inventory', () {
    test(
      'includes offline namespace without interpreting its markers',
      () async {
        final storage = _MemorySecureStorage()
          ..values.addAll({
            ReadCacheKeyStore.offlineKeyName('key-only'): base64Url.encode(
              Uint8List(32),
            ),
            ReadCacheKeyStore.offlineKeyName('bad-key'): 'broken',
            ReadCacheKeyStore.offlineMarkerName('pending'): '{"version":99}',
            ReadCacheKeyStore.offlineRefusalName('refused'): 'unknown-version',
            'ai_history_key.v1.YQ==': 'untouched',
          });
        final store = ReadCacheKeyStore(storage);
        final inventory = await store.readInventory();

        expect(
          ReadCacheKeyStore.offlineKeyName('a'),
          'offline_repo_key.v1.YQ==',
        );
        expect(
          ReadCacheKeyStore.offlineMarkerName('a'),
          'offline_repo_clear_pending.v1.YQ==',
        );
        expect(
          ReadCacheKeyStore.offlineRefusalName('a'),
          'offline_refused.v1.YQ==',
        );
        expect(
          inventory.accountKeys,
          unorderedEquals(['key-only', 'bad-key', 'pending', 'refused']),
        );
        expect(inventory.pendingAccountKeys, ['pending']);
        expect(inventory.containsAccount('bad-key'), isTrue);
        expect(inventory.containsAccount('missing'), isFalse);
        expect(inventory.isEmpty, isFalse);
        expect(inventory.offlineKeys['key-only']!.value, Uint8List(32));
        expect(
          inventory.offlineKeys['bad-key']!.failure!.kind,
          ReadCacheStoreFailureKind.malformed,
        );
        expect(inventory.malformedValues, {
          ReadCacheKeyStore.offlineKeyName('bad-key'),
        });
        expect(inventory.offlineMarkers['pending']!.value, '{"version":99}');
        expect(inventory.offlineRefusals['refused']!.value, 'unknown-version');
        expect(storage.values['ai_history_key.v1.YQ=='], 'untouched');
        expect(storage.writeCount, 0);
        expect(storage.deleteCount, 0);
      },
    );

    test(
      'offline primitives distinguish unavailable and verify each deletion',
      () async {
        final storage = _MemorySecureStorage()
          ..values.addAll({
            ReadCacheKeyStore.offlineKeyName('a'): base64Url.encode(
              Uint8List(32),
            ),
            ReadCacheKeyStore.offlineMarkerName('a'): 'pending',
            ReadCacheKeyStore.offlineRefusalName('a'): 'refused',
          });
        final store = ReadCacheKeyStore(storage);
        storage.failRead = true;
        expect(
          (await store.readOfflineKey('a')).status,
          ReadCacheStoreReadStatus.unavailable,
        );
        expect(
          (await store.readOfflineMarker('a')).status,
          ReadCacheStoreReadStatus.unavailable,
        );
        expect(
          (await store.readOfflineRefusal('a')).status,
          ReadCacheStoreReadStatus.unavailable,
        );
        storage.failRead = false;
        storage.retainAfterDelete = true;
        for (final operation in <Future<void> Function()>[
          () => store.deleteOfflineKey('a'),
          () => store.deleteOfflineMarker('a'),
          () => store.deleteOfflineRefusal('a'),
        ]) {
          await expectLater(
            operation(),
            throwsA(_failure(ReadCacheStoreFailureKind.readbackMismatch)),
          );
        }
        storage.retainAfterDelete = false;
        await store.deleteOfflineKey('a');
        await store.deleteOfflineMarker('a');
        await store.deleteOfflineRefusal('a');
        expect(
          (await store.readOfflineKey('a')).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(
          (await store.readOfflineMarker('a')).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(
          (await store.readOfflineRefusal('a')).status,
          ReadCacheStoreReadStatus.absent,
        );
        expect((await store.readInventory()).isEmpty, isTrue);
        storage.failReadAll = true;
        expect((await store.readInventory()).isEmpty, isFalse);
      },
    );

    test(
      'malformed offline names are exact and cannot address another namespace',
      () async {
        final names = [
          '${ReadCacheKeyStore.offlineKeyPrefix}%%%',
          '${ReadCacheKeyStore.offlineMarkerPrefix}YQ',
          ReadCacheKeyStore.offlineRefusalPrefix,
        ];
        final canonical = [
          ReadCacheKeyStore.offlineKeyName('a'),
          ReadCacheKeyStore.offlineMarkerName('a'),
          ReadCacheKeyStore.offlineRefusalName('a'),
        ];
        final storage = _MemorySecureStorage()
          ..values.addEntries(
            [...names, ...canonical].map((name) => MapEntry(name, 'value')),
          )
          ..values['ai_history_key.v1.YQ=='] = 'untouched';
        final store = ReadCacheKeyStore(storage);
        expect((await store.readInventory()).malformedNames, names.toSet());
        for (final name in canonical) {
          expect(
            () => store.deleteInventoryName(name),
            throwsA(_failure(ReadCacheStoreFailureKind.invalidValue)),
          );
        }
        for (final name in names) {
          await store.deleteInventoryName(name);
        }
        for (final name in canonical) {
          expect(storage.values[name], 'value');
        }
        expect(storage.values['ai_history_key.v1.YQ=='], 'untouched');
      },
    );

    test(
      'lists only two prefixes and classifies malformed names and values',
      () async {
        final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
        final validMarker = ReadCacheClearMarker(
          intentId: '0123456789abcdef0123456789abcdef',
          reason: ReadCacheClearReason.startup,
          requestedAt: DateTime.utc(2026, 10, 23),
        );
        final badKeyName = '${ReadCacheKeyStore.keyPrefix}YQ';
        final badMarkerName = '${ReadCacheKeyStore.markerPrefix}%%%';
        final badValueName = ReadCacheKeyStore.keyName('bad-key');
        final badMarkerValueName = ReadCacheKeyStore.markerName('bad-marker');
        final storage = _MemorySecureStorage()
          ..values.addAll(<String, String>{
            ReadCacheKeyStore.keyName('a'): base64Url.encode(key),
            ReadCacheKeyStore.markerName('a'): jsonEncode(validMarker.toJson()),
            badKeyName: base64Url.encode(key),
            badMarkerName: '{}',
            badValueName: 'bad-value',
            badMarkerValueName: '{"version":99}',
            'ai_write_journal_key.v1.YQ==': 'unrelated-ai-key',
            'other': 'unrelated',
          });

        final inventory = await ReadCacheKeyStore(storage).readInventory();

        expect(inventory.status, ReadCacheStoreReadStatus.found);
        expect(inventory.keys.keys, unorderedEquals(<String>['a', 'bad-key']));
        expect(inventory.keys['a']!.value, orderedEquals(key));
        expect(
          inventory.keys['bad-key']!.status,
          ReadCacheStoreReadStatus.absent,
        );
        expect(
          inventory.markers.keys,
          unorderedEquals(<String>['a', 'bad-marker']),
        );
        expect(
          inventory.markers['bad-marker']!.value,
          isA<MalformedReadCacheClearMarker>(),
        );
        expect(inventory.malformedNames, <String>{badKeyName, badMarkerName});
        expect(inventory.malformedValues, <String>{
          badValueName,
          badMarkerValueName,
        });
      },
    );

    test(
      'rejects empty, invalid UTF-8 and noncanonical names independently',
      () async {
        final malformedNames = <String>{
          ReadCacheKeyStore.keyPrefix,
          ReadCacheKeyStore.markerPrefix,
          '${ReadCacheKeyStore.keyPrefix}${base64Url.encode(<int>[255])}',
          '${ReadCacheKeyStore.markerPrefix}YQ',
          '${ReadCacheKeyStore.keyPrefix}YR==',
        };
        final storage = _MemorySecureStorage()
          ..values.addEntries(
            malformedNames.map((name) => MapEntry(name, 'bad')),
          )
          ..values['ai_history_key.v1.YQ=='] = 'history'
          ..values['ai_history_tombstone.v1.YQ=='] = 'tombstone'
          ..values['read_cache_key.v10.YQ=='] = 'other-version';
        final snapshot = Map<String, String>.from(storage.values);
        final inventory = await ReadCacheKeyStore(storage).readInventory();
        expect(inventory.status, ReadCacheStoreReadStatus.found);
        expect(inventory.keys, isEmpty);
        expect(inventory.markers, isEmpty);
        expect(inventory.malformedNames, malformedNames);
        expect(inventory.malformedValues, isEmpty);
        expect(storage.values, snapshot);
        expect(storage.readAllCount, 1);
        expect(storage.readCount, 0);
        expect(storage.writeCount, 0);
        expect(storage.deleteCount, 0);
      },
    );

    test(
      'readable empty inventory differs from unavailable inventory',
      () async {
        final inventory = await ReadCacheKeyStore(
          _MemorySecureStorage(),
        ).readInventory();
        expect(inventory.status, ReadCacheStoreReadStatus.found);
        expect(inventory.failure, isNull);
        expect(inventory.keys, isEmpty);
        expect(inventory.markers, isEmpty);
        expect(inventory.malformedNames, isEmpty);
        expect(inventory.malformedValues, isEmpty);
      },
    );

    test(
      'readAll failure is unavailable and cannot be mistaken for empty',
      () async {
        final inventory = await ReadCacheKeyStore(
          _MemorySecureStorage()..failReadAll = true,
        ).readInventory();

        expect(inventory.status, ReadCacheStoreReadStatus.unavailable);
        expect(inventory.failure?.kind, ReadCacheStoreFailureKind.unavailable);
        expect(inventory.keys, isEmpty);
        expect(inventory.markers, isEmpty);
      },
    );

    test(
      'canonical inventory names require account deletion even with malformed values',
      () {
        final names = [
          ReadCacheKeyStore.keyName('synthetic-account'),
          ReadCacheKeyStore.markerName('synthetic-account'),
        ];
        for (final value in ['malformed', '']) {
          final storage = _MemorySecureStorage()
            ..values.addEntries(names.map((name) => MapEntry(name, value)));
          final store = ReadCacheKeyStore(storage);
          for (final name in names) {
            expect(
              () => store.deleteInventoryName(name),
              throwsA(_failure(ReadCacheStoreFailureKind.invalidValue)),
            );
            expect(storage.values[name], value);
          }
          expect(storage.deleteCount, 0);
          expect(storage.readCount, 0);
          expect(storage.readAllCount, 0);
          expect(storage.writeCount, 0);
        }
      },
    );

    test(
      'deletes malformed exact prefix names without touching AI entries',
      () async {
        final badName = '${ReadCacheKeyStore.keyPrefix}%%%';
        final aiName = 'ai_write_journal_key.v1.YQ==';
        final storage = _MemorySecureStorage()
          ..values[badName] = 'bad'
          ..values[aiName] = 'ai-value';
        final store = ReadCacheKeyStore(storage);

        await store.deleteInventoryName(badName);

        expect(storage.values.containsKey(badName), isFalse);
        expect(storage.values[aiName], 'ai-value');
        expect(
          () => store.deleteInventoryName(aiName),
          throwsA(_failure(ReadCacheStoreFailureKind.invalidValue)),
        );
        expect(storage.values[aiName], 'ai-value');
      },
    );
  });
}

Matcher _failure(ReadCacheStoreFailureKind kind) =>
    isA<ReadCacheStoreException>().having(
      (error) => error.failure.kind,
      'kind',
      kind,
    );

final class _MemorySecureStorage implements ReadCacheSecureStorage {
  static const rawError = 'native failure with private/account/content';

  final Map<String, String> values = <String, String>{};
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  bool failReadAll = false;
  bool replaceAfterWrite = false;
  bool retainAfterDelete = false;
  bool typedNativeError = false;
  String Function(String)? rewriteAfterWrite;
  int writeCount = 0;
  int readCount = 0;
  int deleteCount = 0;
  int readAllCount = 0;

  Never _fail() {
    if (typedNativeError) {
      throw const ReadCacheStoreException(
        ReadCacheStoreFailure(ReadCacheStoreFailureKind.malformed, rawError),
      );
    }
    throw StateError(rawError);
  }

  @override
  Future<String?> read(String key) async {
    readCount++;
    if (failRead) _fail();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    if (failWrite) _fail();
    values[key] = replaceAfterWrite
        ? '$value-corrupt'
        : rewriteAfterWrite?.call(value) ?? value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCount++;
    if (failDelete) _fail();
    if (!retainAfterDelete) values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    readAllCount++;
    if (failReadAll) _fail();
    return Map<String, String>.from(values);
  }
}
