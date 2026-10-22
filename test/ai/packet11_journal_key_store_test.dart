import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

const account = 'https://synthetic.example/gitlab#7';
const other = 'https://synthetic.example/gitlab#8';
const orphan = 'https://removed.example#9';

// Synthetic key material only. Comparisons go through [sameBytes] so a
// failing expectation never prints key bytes.
Uint8List syntheticKey(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed * 7 + i) & 0xff));
bool sameBytes(List<int>? left, List<int> right) =>
    left != null && listEquals(left, right);

Matcher storeFailure(AiStoreFailureKind kind) => throwsA(
  isA<AiStoreException>().having((error) => error.failure.kind, 'kind', kind),
);

/// The platform-interface mock the existing secure-store tests use, with a
/// keychain that fails every call.
class _LockedStorage extends TestFlutterSecureStoragePlatform {
  _LockedStorage(super.data);
  var reads = 0;
  var writes = 0;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    reads++;
    throw StateError('synthetic keychain locked');
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    reads++;
    throw StateError('synthetic keychain locked');
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    writes++;
    throw StateError('synthetic keychain locked');
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    writes++;
    throw StateError('synthetic keychain locked');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  const storage = FlutterSecureStorage();

  test('journal key round trips under the seam key name', () async {
    final store = SecureAiJournalKeyStore();
    final name = AiJournalKeyStore.keyName(account);
    expect(name, startsWith('ai_write_journal_key.v1.'));
    expect(name, endsWith(base64Url.encode(utf8.encode(account))));

    final absent = await store.readKey(account);
    expect(absent.status, AiStoreReadStatus.absent);
    expect(absent.failure, isNull);

    final key = syntheticKey(3);
    await store.writeKey(account, key);
    expect(
      await storage.read(key: name) == base64Url.encode(key),
      isTrue,
      reason: 'stored as base64url of the 32 bytes',
    );
    final found = await store.readKey(account);
    expect(found.status, AiStoreReadStatus.found);
    expect(found.failure, isNull);
    expect(sameBytes(found.value, key), isTrue);

    await expectLater(
      store.writeKey(account, Uint8List(31)),
      storeFailure(AiStoreFailureKind.invalidValue),
    );
    expect(sameBytes((await store.readKey(account)).value, key), isTrue);

    await store.deleteKey(account);
    final deleted = await store.readKey(account);
    expect(deleted.status, AiStoreReadStatus.absent);
    expect(deleted.failure, isNull);
    expect(await storage.containsKey(key: name), isFalse);
  });

  test('an undecodable journal key is malformed, never found', () async {
    final store = SecureAiJournalKeyStore();
    final name = AiJournalKeyStore.keyName(account);
    for (final stored in <String>[
      base64Url.encode(<int>[1, 2, 3]),
      base64Url.encode(List<int>.filled(33, 1)),
      '%%%not-base64%%%',
    ]) {
      await storage.write(key: name, value: stored);
      final read = await store.readKey(account);
      expect(read.status, AiStoreReadStatus.absent);
      expect(read.value, isNull);
      expect(read.failure?.kind, AiStoreFailureKind.malformed);
      // The decoder's error quotes the stored value; it is not kept.
      expect(read.failure?.cause, isNull);
    }
  });

  test('reset marker round trips as an ISO-8601 UTC time', () async {
    final store = SecureAiJournalKeyStore();
    final name = AiJournalKeyStore.resetName(account);
    expect(name, startsWith('ai_write_journal_reset_pending.v1.'));
    expect(name, endsWith(base64Url.encode(utf8.encode(account))));
    expect(
      (await store.readResetPending(account)).status,
      AiStoreReadStatus.absent,
    );

    final confirmedAt = DateTime(2026, 10, 22, 9, 30, 15, 123);
    await store.writeResetPending(account, confirmedAt);
    final stored = await storage.read(key: name);
    expect(stored, confirmedAt.toUtc().toIso8601String());
    expect(stored, endsWith('Z'));
    final read = await store.readResetPending(account);
    expect(read.status, AiStoreReadStatus.found);
    expect(read.value, confirmedAt.toUtc());
    expect(read.value!.isUtc, isTrue);

    for (final malformed in <String>['not-a-time', '2026-10-22T09:30:15']) {
      await storage.write(key: name, value: malformed);
      final bad = await store.readResetPending(account);
      expect(bad.status, AiStoreReadStatus.absent, reason: malformed);
      expect(bad.failure?.kind, AiStoreFailureKind.malformed);
    }

    await store.deleteResetPending(account);
    final deleted = await store.readResetPending(account);
    expect(deleted.status, AiStoreReadStatus.absent);
    expect(deleted.failure, isNull);
  });

  test('tombstone is the AI history removal tombstone', () async {
    final store = SecureAiJournalKeyStore();
    expect(
      SecureAiStore.tombstoneKey(account),
      startsWith(SecureAiStore.tombstonePrefix),
    );
    final absent = await store.readTombstone(account);
    expect(absent.status, AiStoreReadStatus.absent);
    expect(absent.failure, isNull);

    await SecureAiStore().setTombstone(account);
    final found = await store.readTombstone(account);
    expect(found.status, AiStoreReadStatus.found);
    expect(found.value, isTrue);
    expect((await store.readTombstone(other)).status, AiStoreReadStatus.absent);

    await storage.write(key: SecureAiStore.tombstoneKey(account), value: '0');
    final malformed = await store.readTombstone(account);
    expect(malformed.status, AiStoreReadStatus.absent);
    expect(malformed.failure?.kind, AiStoreFailureKind.malformed);
  });

  test(
    'inventory lists journal keys and reset markers, orphans included',
    () async {
      const tombstoneOnly = 'https://synthetic.example/gitlab#10';
      const historyOnly = 'https://synthetic.example/gitlab#11';
      final store = SecureAiJournalKeyStore();
      await store.writeKey(account, syntheticKey(1));
      // The orphan's account is no longer stored anywhere else.
      await store.writeKey(orphan, syntheticKey(2));
      await store.writeResetPending(orphan, DateTime.utc(2026, 10, 1));
      await store.writeResetPending(other, DateTime.utc(2026, 10, 2));
      await SecureAiStore().setTombstone(tombstoneOnly);
      await SecureAiStore().writeHistoryKey(historyOnly, syntheticKey(3));
      final badKey = '${AiJournalKeyStore.keyPrefix}%%%';
      final badReset =
          '${AiJournalKeyStore.resetPrefix}'
          '${base64Url.encode(utf8.encode('x')).replaceAll('=', '')}';
      await storage.write(key: badKey, value: 'unused');
      await storage.write(key: badReset, value: 'unused');

      expect(await store.inventoryAccounts(), <String>{account, orphan, other});

      final inventory = await SecureAiStore().readSecureInventory();
      expect(inventory.journalKeyAccountKeys, [account, orphan]..sort());
      expect(inventory.journalResetAccountKeys, [orphan, other]..sort());
      expect(inventory.malformedJournalKeys, <String>{badKey, badReset});
      // Journal entries never leak into the history categories.
      expect(inventory.historyKeyAccountKeys, <String>[historyOnly]);
      expect(inventory.accountKeys, isEmpty);
      expect(inventory.malformedHistoryKeyCount, 0);
      expect(inventory.malformedAccountKeyCount, 0);
      expect(inventory.malformedProviderKeyCount, 0);

      // MemoryAiStore shares the decoder.
      final memory = MemoryAiStore()
        ..debugPut(AiJournalKeyStore.keyName(orphan), 'unused')
        ..debugPut(AiJournalKeyStore.resetName(other), 'unused');
      final fromMemory = await memory.readSecureInventory();
      expect(fromMemory.journalKeyAccountKeys, <String>[orphan]);
      expect(fromMemory.journalResetAccountKeys, <String>[other]);
    },
  );

  test(
    'an unavailable keychain is unavailable, never absent, and writes throw',
    () async {
      final locked = _LockedStorage(<String, String>{});
      FlutterSecureStoragePlatform.instance = locked;
      final store = SecureAiJournalKeyStore();

      final key = await store.readKey(account);
      expect(key.status, AiStoreReadStatus.unavailable);
      expect(key.value, isNull);
      expect(key.failure?.kind, AiStoreFailureKind.unavailable);
      final marker = await store.readResetPending(account);
      expect(marker.status, AiStoreReadStatus.unavailable);
      expect(marker.failure?.kind, AiStoreFailureKind.unavailable);
      final tombstone = await store.readTombstone(account);
      expect(tombstone.status, AiStoreReadStatus.unavailable);
      expect(tombstone.failure?.kind, AiStoreFailureKind.unavailable);
      await expectLater(
        store.inventoryAccounts(),
        storeFailure(AiStoreFailureKind.unavailable),
      );

      await expectLater(
        store.writeKey(account, syntheticKey(4)),
        storeFailure(AiStoreFailureKind.unavailable),
      );
      await expectLater(
        store.deleteKey(account),
        storeFailure(AiStoreFailureKind.unavailable),
      );
      await expectLater(
        store.writeResetPending(account, DateTime.utc(2026)),
        storeFailure(AiStoreFailureKind.unavailable),
      );
      await expectLater(
        store.deleteResetPending(account),
        storeFailure(AiStoreFailureKind.unavailable),
      );
      expect(locked.reads, 4);
      expect(locked.writes, 4);
      expect(locked.data, isEmpty);
    },
  );

  group('with the write journal', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('packet11-journal-');
    });
    tearDown(() => root.deleteSync(recursive: true));

    test(
      'startup recovery keeps loaded accounts and sweeps orphan keys',
      () async {
        final keys = SecureAiJournalKeyStore();
        await keys.writeKey(orphan, syntheticKey(9));
        await keys.writeResetPending(orphan, DateTime.utc(2026, 10, 1));
        final journal = AiWriteJournal(
          keys: keys,
          applicationSupport: root,
          processId: 'packet11-process',
        );

        await journal.recoverAfterAccountsLoaded(<String>[account]);
        expect(journal.recovered(account), isTrue);
        expect((await keys.readKey(orphan)).status, AiStoreReadStatus.absent);
        expect(
          (await keys.readResetPending(orphan)).status,
          AiStoreReadStatus.absent,
        );

        await journal.ensureInitialized(account);
        expect(await journal.keyStatus(account), AiJournalKeyStatus.found);
        expect(await keys.inventoryAccounts(), <String>{account});
        final journalFile = File(
          '${root.resolveSymbolicLinksSync()}/ai_write_journal/'
          '${AiJournalFiles.accountHash(account)}/journal.v1.enc',
        );
        expect(journalFile.existsSync(), isTrue);
        expect(AiJournalFiles(root).pathFor(account), journalFile.path);

        // A second owner (a restart) reads the same key back.
        final restarted = AiWriteJournal(
          keys: SecureAiJournalKeyStore(),
          applicationSupport: root,
          processId: 'packet11-restart',
        );
        await restarted.recoverAfterAccountsLoaded(<String>[account]);
        expect(restarted.recovered(account), isTrue);
        expect(restarted.recoveryStatus(account), AiJournalKeyStatus.found);
      },
    );

    test(
      'a locked keychain never initializes a key or sweeps orphans',
      () async {
        final keys = SecureAiJournalKeyStore();
        await keys.writeKey(orphan, syntheticKey(5));
        final data = Map<String, String>.of(
          (FlutterSecureStoragePlatform.instance
                  as TestFlutterSecureStoragePlatform)
              .data,
        );
        final locked = _LockedStorage(data);
        FlutterSecureStoragePlatform.instance = locked;
        final journal = AiWriteJournal(
          keys: keys,
          applicationSupport: root,
          processId: 'packet11-locked',
        );

        await expectLater(
          journal.recoverAfterAccountsLoaded(<String>[account]),
          storeFailure(AiStoreFailureKind.unavailable),
        );
        expect(journal.recovered(account), isFalse);
        expect(
          await journal.keyStatus(account),
          AiJournalKeyStatus.unavailable,
        );
        await expectLater(
          journal.ensureInitialized(account),
          throwsA(isA<AiJournalException>()),
        );
        expect(locked.writes, 0);
        expect(
          locked.data.containsKey(AiJournalKeyStore.keyName(orphan)),
          isTrue,
        );
        expect(
          locked.data.containsKey(AiJournalKeyStore.keyName(account)),
          isFalse,
        );
      },
    );
  });
}
