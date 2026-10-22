import 'dart:convert';
import 'dart:typed_data';

import 'ai_stores.dart';

/// Integration seam for the secure inventory. Production must supply a secure
/// implementation; the memory implementation is deliberately never a default.
abstract interface class AiJournalKeyStore {
  static const keyPrefix = 'ai_write_journal_key.v1.';
  static const resetPrefix = 'ai_write_journal_reset_pending.v1.';

  static String keyName(String accountKey) =>
      '$keyPrefix${base64Url.encode(utf8.encode(accountKey))}';
  static String resetName(String accountKey) =>
      '$resetPrefix${base64Url.encode(utf8.encode(accountKey))}';

  Future<AiStoreRead<Uint8List>> readKey(String accountKey);
  Future<void> writeKey(String accountKey, Uint8List key);
  Future<void> deleteKey(String accountKey);
  Future<AiStoreRead<DateTime>> readResetPending(String accountKey);
  Future<void> writeResetPending(String accountKey, DateTime confirmedAt);
  Future<void> deleteResetPending(String accountKey);
  Future<AiStoreRead<bool>> readTombstone(String accountKey);
  Future<Set<String>> inventoryAccounts();
}

/// Synthetic store, including independently controllable unavailable reads and
/// failed writes. Reads and writes copy keys so callers cannot mutate storage.
class MemoryAiJournalKeyStore implements AiJournalKeyStore {
  final Map<String, Uint8List> keys = {};
  final Map<String, DateTime> resetPending = {};
  final Set<String> tombstones = {};
  bool unavailable = false;
  bool failWrites = false;

  AiStoreRead<T> _read<T>(T? value) => unavailable
      ? const AiStoreRead.unavailable(
          AiStoreFailure(AiStoreFailureKind.unavailable, 'journalRead'),
        )
      : value == null
      ? AiStoreRead<T>.absent()
      : AiStoreRead<T>.found(value);

  void _checkWrite() {
    if (unavailable || failWrites) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'journalWrite'),
      );
    }
  }

  @override
  Future<AiStoreRead<Uint8List>> readKey(String accountKey) async => _read(
    keys[accountKey] == null ? null : Uint8List.fromList(keys[accountKey]!),
  );

  @override
  Future<void> writeKey(String accountKey, Uint8List key) async {
    _checkWrite();
    if (key.length != 32) throw const FormatException();
    keys[accountKey] = Uint8List.fromList(key);
  }

  @override
  Future<void> deleteKey(String accountKey) async {
    _checkWrite();
    keys.remove(accountKey);
  }

  @override
  Future<AiStoreRead<DateTime>> readResetPending(String accountKey) async =>
      _read(resetPending[accountKey]);

  @override
  Future<void> writeResetPending(
    String accountKey,
    DateTime confirmedAt,
  ) async {
    _checkWrite();
    resetPending[accountKey] = confirmedAt.toUtc();
  }

  @override
  Future<void> deleteResetPending(String accountKey) async {
    _checkWrite();
    resetPending.remove(accountKey);
  }

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) async =>
      _read(tombstones.contains(accountKey) ? true : null);

  @override
  Future<Set<String>> inventoryAccounts() async {
    if (unavailable) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'journalInventory'),
      );
    }
    return {...keys.keys, ...resetPending.keys, ...tombstones};
  }
}
