import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/ai/ai_endpoint.dart';
import '../../core/ai/ai_failure.dart';
import '../../core/ai/ai_provider.dart';

enum AiStoreReadStatus { found, absent, unavailable }

enum AiStoreFailureKind {
  malformed,
  unavailable,
  invalidValue,
  confirmationRequired,
  cleaning,
}

final class AiStoreFailure {
  const AiStoreFailure(this.kind, this.operation, [this.cause]);

  final AiStoreFailureKind kind;
  final String operation;
  final Object? cause;
}

final class AiStoreRead<T> {
  const AiStoreRead.found(T this.value)
    : status = AiStoreReadStatus.found,
      failure = null;

  const AiStoreRead.absent([this.failure])
    : status = AiStoreReadStatus.absent,
      value = null;

  const AiStoreRead.unavailable(AiStoreFailure this.failure)
    : status = AiStoreReadStatus.unavailable,
      value = null;

  final AiStoreReadStatus status;
  final T? value;
  final AiStoreFailure? failure;

  bool get isFound => status == AiStoreReadStatus.found;
}

final class AiStoreException implements Exception {
  const AiStoreException(this.failure);

  final AiStoreFailure failure;

  @override
  String toString() =>
      'AiStoreException(${failure.kind.name}, ${failure.operation})';
}

enum AiProviderKeyWarning { shortOrWord }

final class AiProviderKeyAssessment {
  const AiProviderKeyAssessment({required this.accepted, this.warning});

  final bool accepted;
  final AiProviderKeyWarning? warning;
}

AiProviderKeyAssessment assessAiProviderKey(String key) {
  if (key.length < 4) {
    return const AiProviderKeyAssessment(accepted: false);
  }
  final warning = key.length < 16 || RegExp(r'^[A-Za-z]+$').hasMatch(key);
  return AiProviderKeyAssessment(
    accepted: true,
    warning: warning ? AiProviderKeyWarning.shortOrWord : null,
  );
}

final class AiConsentRecord {
  AiConsentRecord({
    required this.hash,
    required Map<String, Object?> summary,
    required this.grantedAt,
  }) : summary = Map.unmodifiable(summary);

  final String hash;
  final Map<String, Object?> summary;
  final DateTime grantedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'hash': hash,
    'summary': summary,
    'grantedAt': grantedAt.toUtc().toIso8601String(),
  };

  static AiConsentRecord decode(Object? raw) {
    final json = _strictObject(raw, 'consent');
    _requireKeys(json, const <String>{'hash', 'summary', 'grantedAt'});
    final hash = _nonEmptyString(json['hash'], 'consent.hash');
    final summary = _strictObject(json['summary'], 'consent.summary');
    _validateJson(summary, 'consent.summary');
    final grantedAt = DateTime.tryParse(
      _nonEmptyString(json['grantedAt'], 'consent.grantedAt'),
    );
    if (grantedAt == null) {
      throw const FormatException('Invalid consent.grantedAt');
    }
    return AiConsentRecord(
      hash: hash,
      summary: summary,
      grantedAt: grantedAt.toUtc(),
    );
  }
}

final class AiAccountRecord {
  AiAccountRecord({
    Map<String, AiConsentRecord> consents = const <String, AiConsentRecord>{},
    this.historyEnabled = false,
    this.retentionDays = 30,
    this.conversationTokenCap = 500000,
  }) : consents = Map.unmodifiable(consents) {
    _validateRetention(retentionDays);
    if (conversationTokenCap <= 0) {
      throw ArgumentError.value(conversationTokenCap, 'conversationTokenCap');
    }
  }

  final Map<String, AiConsentRecord> consents;
  final bool historyEnabled;
  final int retentionDays;
  final int conversationTokenCap;

  AiAccountRecord copyWith({
    Map<String, AiConsentRecord>? consents,
    bool? historyEnabled,
    int? retentionDays,
    int? conversationTokenCap,
  }) => AiAccountRecord(
    consents: consents ?? this.consents,
    historyEnabled: historyEnabled ?? this.historyEnabled,
    retentionDays: retentionDays ?? this.retentionDays,
    conversationTokenCap: conversationTokenCap ?? this.conversationTokenCap,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'consents': <String, Object?>{
      for (final entry in consents.entries) entry.key: entry.value.toJson(),
    },
    'history': <String, Object?>{
      'enabled': historyEnabled,
      'retentionDays': retentionDays,
    },
    'conversationTokenCap': conversationTokenCap,
  };

  static AiAccountRecord decode(String raw) {
    final json = _strictObject(jsonDecode(raw), 'account');
    _requireKeys(json, const <String>{
      'version',
      'consents',
      'history',
      'conversationTokenCap',
    });
    if (json['version'] != 1) {
      throw const FormatException('Unsupported AI account version');
    }
    final rawConsents = _strictObject(json['consents'], 'account.consents');
    final consents = <String, AiConsentRecord>{};
    for (final entry in rawConsents.entries) {
      if (entry.key.isEmpty) {
        throw const FormatException('Empty consent provider id');
      }
      consents[entry.key] = AiConsentRecord.decode(entry.value);
    }
    final history = _strictObject(json['history'], 'account.history');
    _requireKeys(history, const <String>{'enabled', 'retentionDays'});
    final enabled = history['enabled'];
    final retention = history['retentionDays'];
    final tokenCap = json['conversationTokenCap'];
    if (enabled is! bool || retention is! int || tokenCap is! int) {
      throw const FormatException('Invalid AI account field type');
    }
    _validateRetention(retention);
    if (tokenCap <= 0) {
      throw const FormatException('Invalid conversationTokenCap');
    }
    return AiAccountRecord(
      consents: consents,
      historyEnabled: enabled,
      retentionDays: retention,
      conversationTokenCap: tokenCap,
    );
  }
}

abstract interface class AiStore {
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders();
  Future<void> saveProviders(List<AiProviderConfig> providers);

  Future<AiStoreRead<String>> readProviderKey(String providerId);
  Future<Map<String, String>> readAllProviderKeys(Iterable<String> providerIds);
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  });
  Future<void> deleteProviderKey(String providerId);

  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey);
  Future<void> saveAccount(String accountKey, AiAccountRecord account);
  Future<List<String>> listAccountKeys();
  Future<void> deleteAccount(String accountKey);

  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey);
  Future<void> writeHistoryKey(String accountKey, Uint8List key);
  Future<void> deleteHistoryKey(String accountKey);

  Future<AiStoreRead<bool>> readTombstone(String accountKey);
  Future<void> setTombstone(String accountKey);
  Future<List<String>> listTombstones();
  Future<void> clearTombstone(String accountKey);
}

abstract interface class AiStoreSecureInventory {
  Future<List<String>> listProviderKeyIds();
  Future<List<String>> listHistoryKeyAccountKeys();
  Future<AiTombstoneInventory> readTombstoneInventory();
  Future<AiSecureInventory> readSecureInventory();
}

/// Separate durable marker for history-only deletion. This must never share
/// the account-removal tombstone because history clearing preserves the AI
/// account record, preferences, and consents.
abstract interface class AiHistoryClearMarkerStore {
  Future<AiStoreRead<bool>> readHistoryClearMarker(String accountKey);
  Future<void> setHistoryClearMarker(String accountKey);
  Future<void> clearHistoryClearMarker(String accountKey);
}

abstract interface class AiProviderKeyBindingStore {
  Future<AiStoreRead<String>> readProviderKeyBinding(String providerId);
  Future<void> saveProviderKeyBinding(String providerId, String binding);
  Future<void> deleteProviderKeyBinding(String providerId);
}

final class AiSecureInventory {
  const AiSecureInventory({
    required this.providerKeyIds,
    required this.accountKeys,
    required this.historyKeyAccountKeys,
    required this.malformedProviderKeyCount,
    required this.malformedAccountKeyCount,
    required this.malformedHistoryKeyCount,
    required this.malformedProviderKeys,
    required this.malformedAccountKeys,
    required this.malformedHistoryKeys,
  });

  final List<String> providerKeyIds;
  final List<String> accountKeys;
  final List<String> historyKeyAccountKeys;
  final int malformedProviderKeyCount;
  final int malformedAccountKeyCount;
  final int malformedHistoryKeyCount;
  final Set<String> malformedProviderKeys;
  final Set<String> malformedAccountKeys;
  final Set<String> malformedHistoryKeys;
}

final class AiTombstoneInventory {
  const AiTombstoneInventory({
    required this.accountKeys,
    required this.malformedCount,
  });

  final List<String> accountKeys;
  final int malformedCount;
}

final class AiSecureCleanupResult {
  const AiSecureCleanupResult({
    required this.deletedAccountRecords,
    required this.deletedHistoryKeys,
    required this.failedAccounts,
    required this.malformedAccountKeyCount,
    required this.malformedHistoryKeyCount,
  });

  final List<String> deletedAccountRecords;
  final List<String> deletedHistoryKeys;
  final List<String> failedAccounts;
  final int malformedAccountKeyCount;
  final int malformedHistoryKeyCount;

  int get malformedCount => malformedAccountKeyCount + malformedHistoryKeyCount;
}

final Object _secureAccountMutationScope = Object();
final Expando<AiAccountMutationCoordinator> _accountMutationOwners =
    Expando<AiAccountMutationCoordinator>('aiAccountMutationOwner');

final class AiAccountMutationCoordinator {
  AiAccountMutationCoordinator._(this.store);

  factory AiAccountMutationCoordinator.forStore(AiStore store) {
    final scope = store is SecureAiStore ? _secureAccountMutationScope : store;
    return _accountMutationOwners[scope] ??= AiAccountMutationCoordinator._(
      store,
    );
  }

  final AiStore store;
  final Map<String, _AiAccountMutationEntry> _entries =
      <String, _AiAccountMutationEntry>{};
  final Set<void Function(String, AiAccountRecord?)> _listeners =
      <void Function(String, AiAccountRecord?)>{};

  void addListener(void Function(String, AiAccountRecord?) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(String, AiAccountRecord?) listener) {
    _listeners.remove(listener);
  }

  Future<AiAccountRecord?> mutate(
    String accountKey,
    AiAccountRecord Function(AiAccountRecord current) update,
  ) {
    final entry = _entries.putIfAbsent(accountKey, _AiAccountMutationEntry.new);
    final epoch = entry.epoch;
    return _enqueue(entry, () async {
      if (entry.cleaning || entry.epoch != epoch) return null;
      final tombstone = await store.readTombstone(accountKey);
      if (tombstone.failure != null) throw AiStoreException(tombstone.failure!);
      if (tombstone.isFound) return null;
      final read = await store.loadAccount(accountKey);
      if (read.failure != null) throw AiStoreException(read.failure!);
      if (entry.cleaning || entry.epoch != epoch) return null;
      final current = read.value ?? AiAccountRecord();
      final updated = update(current);
      if (identical(current, updated)) return current;
      await store.saveAccount(accountKey, updated);
      if (entry.cleaning || entry.epoch != epoch) return null;
      _emit(accountKey, updated);
      return updated;
    });
  }

  Future<AiAccountRecord?> read(String accountKey) {
    final entry = _entries.putIfAbsent(accountKey, _AiAccountMutationEntry.new);
    final epoch = entry.epoch;
    return _enqueue(entry, () async {
      if (entry.cleaning || entry.epoch != epoch) return null;
      final tombstone = await store.readTombstone(accountKey);
      if (tombstone.failure != null) throw AiStoreException(tombstone.failure!);
      if (tombstone.isFound) return null;
      final read = await store.loadAccount(accountKey);
      if (read.failure != null) throw AiStoreException(read.failure!);
      if (entry.cleaning || entry.epoch != epoch) return null;
      final account = read.value ?? AiAccountRecord();
      _emit(accountKey, account);
      return account;
    });
  }

  AiAccountCleaningLease beginCleaning(String accountKey) {
    final entry = _entries.putIfAbsent(accountKey, _AiAccountMutationEntry.new);
    entry
      ..epoch += 1
      ..cleaning = true;
    _emit(accountKey, null);
    return AiAccountCleaningLease._(this, accountKey, entry, entry.epoch);
  }

  void reopen(String accountKey) {
    final entry = _entries.putIfAbsent(accountKey, _AiAccountMutationEntry.new);
    entry
      ..epoch += 1
      ..cleaning = false;
  }

  void invalidate(String accountKey) => _emit(accountKey, null);

  bool isCleaning(String accountKey) => _entries[accountKey]?.cleaning ?? false;

  int epochFor(String accountKey) => _entries[accountKey]?.epoch ?? 0;

  bool isCurrent(String accountKey, int epoch) {
    final entry = _entries[accountKey];
    return (entry?.epoch ?? 0) == epoch && entry?.cleaning != true;
  }

  Future<T> _runCleaning<T>(
    String accountKey,
    _AiAccountMutationEntry entry,
    int epoch,
    Future<T> Function() action,
  ) => _enqueue(entry, () async {
    if (!entry.cleaning || entry.epoch != epoch) {
      throw StateError('Stale AI account cleaning lease');
    }
    final result = await action();
    _emit(accountKey, null);
    return result;
  });

  void _releaseCleaning(_AiAccountMutationEntry entry, int epoch) {
    if (!entry.cleaning || entry.epoch != epoch) return;
    entry
      ..epoch += 1
      ..cleaning = false;
  }

  Future<T> _enqueue<T>(
    _AiAccountMutationEntry entry,
    Future<T> Function() action,
  ) {
    final previous = entry.tail;
    final run = previous == null ? action() : previous.then((_) => action());
    final tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    entry.tail = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(entry.tail, tail)) entry.tail = null;
      }),
    );
    return run;
  }

  void _emit(String accountKey, AiAccountRecord? account) {
    for (final listener in List.of(_listeners)) {
      listener(accountKey, account);
    }
  }
}

final class AiAccountCleaningLease {
  AiAccountCleaningLease._(
    this._owner,
    this.accountKey,
    this._entry,
    this._epoch,
  );

  final AiAccountMutationCoordinator _owner;
  final String accountKey;
  final _AiAccountMutationEntry _entry;
  final int _epoch;

  Future<T> run<T>(Future<T> Function() action) =>
      _owner._runCleaning(accountKey, _entry, _epoch, action);

  void release() => _owner._releaseCleaning(_entry, _epoch);
}

final class _AiAccountMutationEntry {
  Future<void>? tail;
  int epoch = 0;
  bool cleaning = false;
}

Future<AiTombstoneInventory> readAiTombstoneInventory(AiStore store) async {
  if (store case final AiStoreSecureInventory inventory) {
    return inventory.readTombstoneInventory();
  }
  return AiTombstoneInventory(
    accountKeys: await store.listTombstones(),
    malformedCount: 0,
  );
}

Future<AiSecureInventory> readAiSecureInventory(AiStore store) async {
  if (store case final AiStoreSecureInventory inventory) {
    return inventory.readSecureInventory();
  }
  return AiSecureInventory(
    providerKeyIds: const <String>[],
    accountKeys: await store.listAccountKeys(),
    historyKeyAccountKeys: const <String>[],
    malformedProviderKeyCount: 0,
    malformedAccountKeyCount: 0,
    malformedHistoryKeyCount: 0,
    malformedProviderKeys: const <String>{},
    malformedAccountKeys: const <String>{},
    malformedHistoryKeys: const <String>{},
  );
}

Future<AiSecureCleanupResult> cleanupOrphanAiSecureData(
  AiStore store,
  Set<String> liveAccountKeys, {
  bool Function()? isCurrent,
}) async {
  final inventory = await readAiSecureInventory(store);
  final accountKeys = inventory.accountKeys;
  final historyKeys = inventory.historyKeyAccountKeys;
  final deletedAccounts = <String>[];
  final deletedHistoryKeys = <String>[];
  final failedAccounts = <String>[];
  final owner = AiAccountMutationCoordinator.forStore(store);
  final orphanAccounts = accountKeys
      .where((accountKey) => !liveAccountKeys.contains(accountKey))
      .toSet();
  final orphanHistoryKeys = historyKeys
      .where((accountKey) => !liveAccountKeys.contains(accountKey))
      .toSet();
  final orphanKeys = <String>{...orphanAccounts, ...orphanHistoryKeys}.toList()
    ..sort();
  for (final accountKey in orphanKeys) {
    if (isCurrent?.call() == false) break;
    final lease = owner.beginCleaning(accountKey);
    try {
      await lease.run(() async {
        if (isCurrent?.call() == false) return;
        if (orphanAccounts.contains(accountKey)) {
          await store.deleteAccount(accountKey);
        }
        if (orphanHistoryKeys.contains(accountKey)) {
          await store.deleteHistoryKey(accountKey);
        }
      });
    } on Object {
      failedAccounts.add(accountKey);
      continue;
    } finally {
      lease.release();
    }
    if (isCurrent?.call() == false) break;
    if (orphanAccounts.contains(accountKey)) deletedAccounts.add(accountKey);
    if (orphanHistoryKeys.contains(accountKey)) {
      deletedHistoryKeys.add(accountKey);
    }
  }
  deletedAccounts.sort();
  deletedHistoryKeys.sort();
  failedAccounts.sort();
  return AiSecureCleanupResult(
    deletedAccountRecords: List.unmodifiable(deletedAccounts),
    deletedHistoryKeys: List.unmodifiable(deletedHistoryKeys),
    failedAccounts: List.unmodifiable(failedAccounts),
    malformedAccountKeyCount: inventory.malformedAccountKeyCount,
    malformedHistoryKeyCount: inventory.malformedHistoryKeyCount,
  );
}

final class SecureAiStore
    implements
        AiStore,
        AiStoreSecureInventory,
        AiHistoryClearMarkerStore,
        AiProviderKeyBindingStore {
  SecureAiStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );

  static const providersStorageKey = 'gitlab_mobile_ai_providers_v1';
  static const providerKeyPrefix = 'ai_key.v1.';
  static const accountPrefix = 'ai_account.v1.';
  static const historyKeyPrefix = 'ai_history_key.v1.';
  static const tombstonePrefix = 'ai_history_tombstone.v1.';
  static const historyClearMarkerPrefix = 'ai_history_clear_pending.v1.';
  static const providerKeyBindingPrefix = 'ai_key_binding.v1.';

  final FlutterSecureStorage _storage;

  static String providerKey(String providerId) =>
      '$providerKeyPrefix${_encodeId(providerId)}';

  static String accountKey(String accountKey) =>
      '$accountPrefix${_encodeId(accountKey)}';

  static String historyKey(String accountKey) =>
      '$historyKeyPrefix${_encodeId(accountKey)}';

  static String tombstoneKey(String accountKey) =>
      '$tombstonePrefix${_encodeId(accountKey)}';

  static String historyClearMarkerKey(String accountKey) =>
      '$historyClearMarkerPrefix${_encodeId(accountKey)}';

  static String providerKeyBindingKey(String providerId) =>
      '$providerKeyBindingPrefix${_encodeId(providerId)}';

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() async {
    final raw = await _read(providersStorageKey, 'loadProviders');
    if (!raw.isFound) {
      return _copyRead<List<AiProviderConfig>>(raw);
    }
    try {
      return AiStoreRead<List<AiProviderConfig>>.found(
        _decodeProviders(raw.value!),
      );
    } on Object catch (error) {
      return AiStoreRead<List<AiProviderConfig>>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'loadProviders', error),
      );
    }
  }

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) => _write(
    providersStorageKey,
    jsonEncode(<String, Object?>{
      'version': 1,
      'providers': providers.map(_providerToJson).toList(growable: false),
    }),
    'saveProviders',
  );

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) async {
    final result = await _read(providerKey(providerId), 'readProviderKey');
    if (!result.isFound) return result;
    final assessment = assessAiProviderKey(result.value!);
    if (!assessment.accepted) {
      return const AiStoreRead<String>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'readProviderKey'),
      );
    }
    return result;
  }

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) async {
    final result = <String, String>{};
    for (final providerId in providerIds.toSet()) {
      final read = await readProviderKey(providerId);
      if (read.status == AiStoreReadStatus.unavailable) {
        throw AiStoreException(read.failure!);
      }
      if (read.isFound) result[providerId] = read.value!;
    }
    return Map.unmodifiable(result);
  }

  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) async {
    final assessment = assessAiProviderKey(key);
    if (!assessment.accepted) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProviderKey'),
      );
    }
    if (assessment.warning != null && !acknowledgeWarning) {
      throw const AiStoreException(
        AiStoreFailure(
          AiStoreFailureKind.confirmationRequired,
          'saveProviderKey',
        ),
      );
    }
    await _write(providerKey(providerId), key, 'saveProviderKey');
  }

  @override
  Future<void> deleteProviderKey(String providerId) =>
      _delete(providerKey(providerId), 'deleteProviderKey');

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) async {
    final raw = await _read(
      SecureAiStore.accountKey(accountKey),
      'loadAccount',
    );
    if (!raw.isFound) return _copyRead<AiAccountRecord>(raw);
    try {
      return AiStoreRead<AiAccountRecord>.found(
        AiAccountRecord.decode(raw.value!),
      );
    } on Object catch (error) {
      return AiStoreRead<AiAccountRecord>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'loadAccount', error),
      );
    }
  }

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) =>
      _write(
        SecureAiStore.accountKey(accountKey),
        jsonEncode(account.toJson()),
        'saveAccount',
      );

  @override
  Future<List<String>> listProviderKeyIds() =>
      _listEncodedKeys(providerKeyPrefix, 'listProviderKeyIds');

  @override
  Future<List<String>> listAccountKeys() =>
      _listEncodedKeys(accountPrefix, 'listAccountKeys');

  @override
  Future<List<String>> listHistoryKeyAccountKeys() =>
      _listEncodedKeys(historyKeyPrefix, 'listHistoryKeyAccountKeys');

  @override
  Future<void> deleteAccount(String accountKey) =>
      _delete(SecureAiStore.accountKey(accountKey), 'deleteAccount');

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) async {
    final raw = await _read(historyKey(accountKey), 'readHistoryKey');
    if (!raw.isFound) return _copyRead<Uint8List>(raw);
    try {
      final bytes = base64Url.decode(base64Url.normalize(raw.value!));
      if (bytes.length != 32) throw const FormatException('Invalid key length');
      return AiStoreRead<Uint8List>.found(Uint8List.fromList(bytes));
    } on Object catch (error) {
      return AiStoreRead<Uint8List>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'readHistoryKey', error),
      );
    }
  }

  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) {
    if (key.length != 32) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'writeHistoryKey'),
      );
    }
    return _write(
      historyKey(accountKey),
      base64Url.encode(key),
      'writeHistoryKey',
    );
  }

  @override
  Future<void> deleteHistoryKey(String accountKey) =>
      _delete(historyKey(accountKey), 'deleteHistoryKey');

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) async {
    final raw = await _read(tombstoneKey(accountKey), 'readTombstone');
    if (!raw.isFound) return _copyRead<bool>(raw);
    if (raw.value != '1') {
      return const AiStoreRead<bool>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'readTombstone'),
      );
    }
    return const AiStoreRead<bool>.found(true);
  }

  @override
  Future<void> setTombstone(String accountKey) =>
      _write(tombstoneKey(accountKey), '1', 'setTombstone');

  @override
  Future<List<String>> listTombstones() async {
    return _listEncodedKeys(tombstonePrefix, 'listTombstones', value: '1');
  }

  @override
  Future<AiTombstoneInventory> readTombstoneInventory() async {
    try {
      final all = await _storage.readAll();
      final result = <String>[];
      var malformedCount = 0;
      for (final entry in all.entries) {
        if (!entry.key.startsWith(tombstonePrefix)) continue;
        if (entry.value != '1') {
          malformedCount += 1;
          continue;
        }
        try {
          result.add(
            _decodeStoredId(
              entry.key.substring(tombstonePrefix.length),
              'readTombstoneInventory',
            ),
          );
        } on AiStoreException {
          malformedCount += 1;
        }
      }
      result.sort();
      return AiTombstoneInventory(
        accountKeys: List.unmodifiable(result),
        malformedCount: malformedCount,
      );
    } on Object catch (error) {
      throw AiStoreException(
        AiStoreFailure(
          AiStoreFailureKind.unavailable,
          'readTombstoneInventory',
          error,
        ),
      );
    }
  }

  @override
  Future<AiSecureInventory> readSecureInventory() async {
    try {
      final all = await _storage.readAll();
      return _decodeSecureInventory(all.keys);
    } on AiStoreException {
      rethrow;
    } on Object catch (error) {
      throw AiStoreException(
        AiStoreFailure(
          AiStoreFailureKind.unavailable,
          'readSecureInventory',
          error,
        ),
      );
    }
  }

  Future<List<String>> _listEncodedKeys(
    String prefix,
    String operation, {
    String? value,
  }) async {
    try {
      final all = await _storage.readAll();
      final result = <String>[];
      for (final entry in all.entries) {
        if (!entry.key.startsWith(prefix)) continue;
        if (value != null && entry.value != value) {
          throw AiStoreException(
            AiStoreFailure(AiStoreFailureKind.malformed, operation),
          );
        }
        final encoded = entry.key.substring(prefix.length);
        result.add(_decodeStoredId(encoded, operation));
      }
      result.sort();
      return List.unmodifiable(result);
    } on AiStoreException {
      rethrow;
    } on Object catch (error) {
      throw AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, operation, error),
      );
    }
  }

  @override
  Future<void> clearTombstone(String accountKey) =>
      _delete(tombstoneKey(accountKey), 'clearTombstone');

  @override
  Future<AiStoreRead<bool>> readHistoryClearMarker(String accountKey) async {
    final raw = await _read(
      historyClearMarkerKey(accountKey),
      'readHistoryClearMarker',
    );
    if (!raw.isFound) return _copyRead<bool>(raw);
    if (raw.value != '1') {
      return const AiStoreRead<bool>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'readHistoryClearMarker'),
      );
    }
    return const AiStoreRead<bool>.found(true);
  }

  @override
  Future<void> setHistoryClearMarker(String accountKey) =>
      _write(historyClearMarkerKey(accountKey), '1', 'setHistoryClearMarker');

  @override
  Future<void> clearHistoryClearMarker(String accountKey) =>
      _delete(historyClearMarkerKey(accountKey), 'clearHistoryClearMarker');

  @override
  Future<AiStoreRead<String>> readProviderKeyBinding(String providerId) =>
      _read(providerKeyBindingKey(providerId), 'readProviderKeyBinding');

  @override
  Future<void> saveProviderKeyBinding(String providerId, String binding) =>
      _write(
        providerKeyBindingKey(providerId),
        binding,
        'saveProviderKeyBinding',
      );

  @override
  Future<void> deleteProviderKeyBinding(String providerId) =>
      _delete(providerKeyBindingKey(providerId), 'deleteProviderKeyBinding');

  Future<AiStoreRead<String>> _read(String key, String operation) async {
    try {
      final value = await _storage.read(key: key);
      return value == null
          ? const AiStoreRead<String>.absent()
          : AiStoreRead<String>.found(value);
    } on Object catch (error) {
      return AiStoreRead<String>.unavailable(
        AiStoreFailure(AiStoreFailureKind.unavailable, operation, error),
      );
    }
  }

  Future<void> _write(String key, String value, String operation) async {
    try {
      await _storage.write(key: key, value: value);
    } on Object catch (error) {
      throw AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, operation, error),
      );
    }
  }

  Future<void> _delete(String key, String operation) async {
    try {
      await _storage.delete(key: key);
    } on Object catch (error) {
      throw AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, operation, error),
      );
    }
  }
}

final class MemoryAiStore
    implements
        AiStore,
        AiStoreSecureInventory,
        AiHistoryClearMarkerStore,
        AiProviderKeyBindingStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() async {
    final raw = _values[SecureAiStore.providersStorageKey];
    if (raw == null) return const AiStoreRead<List<AiProviderConfig>>.absent();
    try {
      return AiStoreRead<List<AiProviderConfig>>.found(_decodeProviders(raw));
    } on Object catch (error) {
      return AiStoreRead<List<AiProviderConfig>>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'loadProviders', error),
      );
    }
  }

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) async {
    _values[SecureAiStore.providersStorageKey] = jsonEncode(<String, Object?>{
      'version': 1,
      'providers': providers.map(_providerToJson).toList(growable: false),
    });
  }

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) async {
    final value = _values[SecureAiStore.providerKey(providerId)];
    if (value == null) return const AiStoreRead<String>.absent();
    if (!assessAiProviderKey(value).accepted) {
      return const AiStoreRead<String>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'readProviderKey'),
      );
    }
    return AiStoreRead<String>.found(value);
  }

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) async {
    final result = <String, String>{};
    for (final providerId in providerIds.toSet()) {
      final read = await readProviderKey(providerId);
      if (read.status == AiStoreReadStatus.unavailable) {
        throw AiStoreException(read.failure!);
      }
      if (read.isFound) result[providerId] = read.value!;
    }
    return Map.unmodifiable(result);
  }

  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) async {
    final assessment = assessAiProviderKey(key);
    if (!assessment.accepted) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProviderKey'),
      );
    }
    if (assessment.warning != null && !acknowledgeWarning) {
      throw const AiStoreException(
        AiStoreFailure(
          AiStoreFailureKind.confirmationRequired,
          'saveProviderKey',
        ),
      );
    }
    _values[SecureAiStore.providerKey(providerId)] = key;
  }

  @override
  Future<void> deleteProviderKey(String providerId) async {
    _values.remove(SecureAiStore.providerKey(providerId));
  }

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) async {
    final raw = _values[SecureAiStore.accountKey(accountKey)];
    if (raw == null) return const AiStoreRead<AiAccountRecord>.absent();
    try {
      return AiStoreRead<AiAccountRecord>.found(AiAccountRecord.decode(raw));
    } on Object catch (error) {
      return AiStoreRead<AiAccountRecord>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'loadAccount', error),
      );
    }
  }

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) async {
    _values[SecureAiStore.accountKey(accountKey)] = jsonEncode(
      account.toJson(),
    );
  }

  @override
  Future<List<String>> listProviderKeyIds() async {
    final result = <String>[];
    for (final key in _values.keys) {
      if (!key.startsWith(SecureAiStore.providerKeyPrefix)) continue;
      final encoded = key.substring(SecureAiStore.providerKeyPrefix.length);
      result.add(_decodeStoredId(encoded, 'listProviderKeyIds'));
    }
    result.sort();
    return List.unmodifiable(result);
  }

  @override
  Future<List<String>> listAccountKeys() async {
    final result = <String>[];
    for (final key in _values.keys) {
      if (!key.startsWith(SecureAiStore.accountPrefix)) continue;
      final encoded = key.substring(SecureAiStore.accountPrefix.length);
      result.add(_decodeStoredId(encoded, 'listAccountKeys'));
    }
    result.sort();
    return List.unmodifiable(result);
  }

  @override
  Future<List<String>> listHistoryKeyAccountKeys() async {
    final result = <String>[];
    for (final key in _values.keys) {
      if (!key.startsWith(SecureAiStore.historyKeyPrefix)) continue;
      final encoded = key.substring(SecureAiStore.historyKeyPrefix.length);
      result.add(_decodeStoredId(encoded, 'listHistoryKeyAccountKeys'));
    }
    result.sort();
    return List.unmodifiable(result);
  }

  @override
  Future<void> deleteAccount(String accountKey) async {
    _values.remove(SecureAiStore.accountKey(accountKey));
  }

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) async {
    final raw = _values[SecureAiStore.historyKey(accountKey)];
    if (raw == null) return const AiStoreRead<Uint8List>.absent();
    try {
      final bytes = base64Url.decode(base64Url.normalize(raw));
      if (bytes.length != 32) throw const FormatException('Invalid key length');
      return AiStoreRead<Uint8List>.found(Uint8List.fromList(bytes));
    } on Object catch (error) {
      return AiStoreRead<Uint8List>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'readHistoryKey', error),
      );
    }
  }

  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) async {
    if (key.length != 32) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'writeHistoryKey'),
      );
    }
    _values[SecureAiStore.historyKey(accountKey)] = base64Url.encode(key);
  }

  @override
  Future<void> deleteHistoryKey(String accountKey) async {
    _values.remove(SecureAiStore.historyKey(accountKey));
  }

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) async {
    final value = _values[SecureAiStore.tombstoneKey(accountKey)];
    if (value == null) return const AiStoreRead<bool>.absent();
    if (value != '1') {
      return const AiStoreRead<bool>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'readTombstone'),
      );
    }
    return const AiStoreRead<bool>.found(true);
  }

  @override
  Future<void> setTombstone(String accountKey) async {
    _values[SecureAiStore.tombstoneKey(accountKey)] = '1';
  }

  @override
  Future<List<String>> listTombstones() async {
    final result = <String>[];
    for (final entry in _values.entries) {
      if (!entry.key.startsWith(SecureAiStore.tombstonePrefix)) continue;
      if (entry.value != '1') {
        throw const AiStoreException(
          AiStoreFailure(AiStoreFailureKind.malformed, 'listTombstones'),
        );
      }
      final encoded = entry.key.substring(SecureAiStore.tombstonePrefix.length);
      result.add(_decodeStoredId(encoded, 'listTombstones'));
    }
    result.sort();
    return List.unmodifiable(result);
  }

  @override
  Future<AiTombstoneInventory> readTombstoneInventory() async {
    final result = <String>[];
    var malformedCount = 0;
    for (final entry in _values.entries) {
      if (!entry.key.startsWith(SecureAiStore.tombstonePrefix)) continue;
      if (entry.value != '1') {
        malformedCount += 1;
        continue;
      }
      try {
        result.add(
          _decodeStoredId(
            entry.key.substring(SecureAiStore.tombstonePrefix.length),
            'readTombstoneInventory',
          ),
        );
      } on AiStoreException {
        malformedCount += 1;
      }
    }
    result.sort();
    return AiTombstoneInventory(
      accountKeys: List.unmodifiable(result),
      malformedCount: malformedCount,
    );
  }

  @override
  Future<AiSecureInventory> readSecureInventory() async =>
      _decodeSecureInventory(_values.keys);

  @override
  Future<void> clearTombstone(String accountKey) async {
    _values.remove(SecureAiStore.tombstoneKey(accountKey));
  }

  @override
  Future<AiStoreRead<bool>> readHistoryClearMarker(String accountKey) async {
    final value = _values[SecureAiStore.historyClearMarkerKey(accountKey)];
    if (value == null) return const AiStoreRead<bool>.absent();
    if (value != '1') {
      return const AiStoreRead<bool>.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'readHistoryClearMarker'),
      );
    }
    return const AiStoreRead<bool>.found(true);
  }

  @override
  Future<void> setHistoryClearMarker(String accountKey) async {
    _values[SecureAiStore.historyClearMarkerKey(accountKey)] = '1';
  }

  @override
  Future<void> clearHistoryClearMarker(String accountKey) async {
    _values.remove(SecureAiStore.historyClearMarkerKey(accountKey));
  }

  @override
  Future<AiStoreRead<String>> readProviderKeyBinding(String providerId) async {
    final value = _values[SecureAiStore.providerKeyBindingKey(providerId)];
    return value == null
        ? const AiStoreRead<String>.absent()
        : AiStoreRead<String>.found(value);
  }

  @override
  Future<void> saveProviderKeyBinding(String providerId, String binding) async {
    _values[SecureAiStore.providerKeyBindingKey(providerId)] = binding;
  }

  @override
  Future<void> deleteProviderKeyBinding(String providerId) async {
    _values.remove(SecureAiStore.providerKeyBindingKey(providerId));
  }

  void debugPut(String key, String value) => _values[key] = value;
}

final Object _secureSettingsScope = Object();
final Expando<AiSettingsController> _settingsOwners =
    Expando<AiSettingsController>('aiSettingsOwner');

// aiSettingsProvider is an app-level single owner. It must not
// be autoDispose or live under an account-keyed provider tree. While the secure
// device owner exists, this factory returns it regardless of the storage
// instance passed through a SecureAiStore wrapper.

final class AiSettingsController extends ChangeNotifier {
  factory AiSettingsController(AiStore store) {
    final scope = store is SecureAiStore ? _secureSettingsScope : store;
    final existing = _settingsOwners[scope];
    if (existing != null) {
      if (!existing._disposed) return existing;
      if (existing._providerMutationTail != null) {
        throw StateError('AiSettingsController disposal is pending');
      }
    }
    return _settingsOwners[scope] = AiSettingsController._(store, scope);
  }

  AiSettingsController._(this.store, this._settingsScope)
    : _accountMutations = AiAccountMutationCoordinator.forStore(store) {
    _accountMutations.addListener(_accountRecordChanged);
  }

  final AiStore store;
  final Object _settingsScope;
  final AiAccountMutationCoordinator _accountMutations;
  List<AiProviderConfig> _providers = const <AiProviderConfig>[];
  final Map<String, AiProviderConfig> _deletingProviders =
      <String, AiProviderConfig>{};
  final Map<String, String> _providerKeys = <String, String>{};
  final Map<String, AiAccountRecord> _accounts = <String, AiAccountRecord>{};
  final Map<String, int> _consentRevisions = <String, int>{};
  var _secretSetId = 0;
  final Set<String> _malformedAccountRecords = <String>{};
  final Set<String> _malformedSecureInventoryEntries = <String>{};
  Future<void>? _providerMutationTail;
  var _disposed = false;
  var _initialized = false;
  var _initializing = false;
  AiStoreFailure? _initializationFailure;

  List<AiProviderConfig> get providers => _providers;
  Map<String, String> get knownProviderKeys => Map.unmodifiable(_providerKeys);
  int get secretSetId => _secretSetId;
  int get malformedAccountRecordCount => _malformedAccountRecords.length;
  int get malformedSecureInventoryCount =>
      _malformedSecureInventoryEntries.length;
  bool get initialized => _initialized;
  bool get initializing => _initializing;
  AiStoreFailure? get initializationFailure => _initializationFailure;

  int? recipientRevision(String providerId) =>
      _provider(providerId)?.recipientRevision;

  int consentRevision(String accountKey) => _consentRevisions[accountKey] ?? 0;

  AiAccountRecord? accountRecord(String accountKey) => _accounts[accountKey];

  Future<void> initialize() => _enqueue(() async {
    _initializing = true;
    _initializationFailure = null;
    _notify();
    try {
      await _initialize();
      _markInitialized();
    } on AiStoreException catch (error) {
      _initializationFailure = error.failure;
      rethrow;
    } on Object catch (error) {
      _initializationFailure = AiStoreFailure(
        AiStoreFailureKind.unavailable,
        'initialize',
        error,
      );
      rethrow;
    } finally {
      _initializing = false;
      _notify();
    }
  });

  Future<void> _initialize() async {
    final result = await store.loadProviders();
    if (result.failure != null) throw AiStoreException(result.failure!);
    final loaded = result.value ?? const <AiProviderConfig>[];
    final active = <AiProviderConfig>[];
    final deleting = <AiProviderConfig>[];
    final localDeleting = <String, AiProviderConfig>{..._deletingProviders};
    for (final provider in loaded) {
      final local = localDeleting.remove(provider.id);
      if (local != null) {
        deleting.add(local);
      } else {
        (_isDeletingProvider(provider) ? deleting : active).add(provider);
      }
    }
    deleting.addAll(localDeleting.values);
    final keys = <String, String>{};
    for (final provider in active) {
      final key = await store.readProviderKey(provider.id);
      if (key.failure != null) throw AiStoreException(key.failure!);
      if (key.isFound && await _keyBindingMatches(provider, key.value!)) {
        keys[provider.id] = key.value!;
      }
    }
    _providers = List.unmodifiable(active);
    _deletingProviders
      ..clear()
      ..addEntries(deleting.map((provider) => MapEntry(provider.id, provider)));
    for (final provider in deleting) {
      _markProviderDeleting(provider);
    }
    if (!mapEquals(_providerKeys, keys)) _secretSetId += 1;
    _providerKeys
      ..clear()
      ..addAll(keys);
    if (store is AiStoreSecureInventory) {
      final retainedIds = <String>{
        ...active.map((provider) => provider.id),
        ...deleting.map((provider) => provider.id),
      };
      for (final providerId in await _readProviderKeyIds()) {
        if (!retainedIds.contains(providerId)) {
          await store.deleteProviderKey(providerId);
          await _deleteProviderKeyBinding(providerId);
        }
      }
    }
    _notify();
    for (final provider in deleting) {
      await _persistProviderDeletionMarker(provider);
      await _resumeProviderDeletion(provider);
    }
  }

  Future<AiAccountRecord> loadAccount(String accountKey) =>
      _enqueue(() => _loadAccountFresh(accountKey));

  Future<AiAccountRecord> _loadAccountFresh(String accountKey) async {
    return await _accountMutations.read(accountKey) ?? AiAccountRecord();
  }

  Future<AiProviderConfig> saveProvider(AiProviderConfig provider) =>
      _enqueue(() => _saveProvider(provider));

  Future<AiProviderConfig> _saveProvider(AiProviderConfig provider) async {
    if (_isDeletingProvider(provider)) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProvider'),
      );
    }
    _validateProviderEndpoints(provider);
    _validateProviderCaps(provider.caps);
    final pending = _deletingProviders[provider.id];
    if (pending != null) {
      await _persistProviderDeletionMarker(pending);
      await _resumeProviderDeletion(pending);
    }
    final persisted = await store.loadProviders();
    if (persisted.failure != null) throw AiStoreException(persisted.failure!);
    final deleting = persisted.value
        ?.where(
          (candidate) =>
              candidate.id == provider.id && _isDeletingProvider(candidate),
        )
        .firstOrNull;
    if (deleting != null) await _resumeProviderDeletion(deleting);
    final existing = _provider(provider.id);
    final removesKey =
        existing != null &&
        (!provider.caps.requiresKey || !_sameKeyRecipient(existing, provider));
    final revision = existing == null
        ? 1
        : _sameRecipient(existing, provider) && !removesKey
        ? existing.recipientRevision
        : existing.recipientRevision + 1;
    final saved = _copyProvider(provider, recipientRevision: revision);
    final updated = <AiProviderConfig>[
      for (final current in _providers)
        current.id == saved.id ? saved : current,
      if (existing == null) saved,
    ];
    if (removesKey) {
      await store.deleteProviderKey(provider.id);
      if (_providerKeys.remove(provider.id) != null) {
        _secretSetId += 1;
        _notify();
      }
      await _deleteProviderKeyBinding(provider.id);
    }
    await _writeProviderList(updated);
    _providers = List.unmodifiable(updated);
    _markInitialized();
    _notify();
    return saved;
  }

  /// Saves a provider and its credential as one publication operation.
  ///
  /// A null [key] may retain a stored credential only while the provider ID,
  /// normalized origin/base path, and authentication header style are
  /// unchanged. A replacement credential is persisted before the recipient is
  /// published, so a failed credential write leaves the prior recipient
  /// usable both in memory and after restart.
  Future<AiProviderConfig> saveProviderWithKey(
    AiProviderConfig provider, {
    String? key,
    bool acknowledgeWarning = false,
  }) => _enqueue(
    () => _saveProviderWithKey(
      provider,
      key: key,
      acknowledgeWarning: acknowledgeWarning,
    ),
  );

  Future<AiProviderConfig> _saveProviderWithKey(
    AiProviderConfig provider, {
    required String? key,
    required bool acknowledgeWarning,
  }) async {
    if (_isDeletingProvider(provider)) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProvider'),
      );
    }
    _validateProviderEndpoints(provider);
    _validateProviderCaps(provider.caps);
    final pending = _deletingProviders[provider.id];
    if (pending != null) {
      await _persistProviderDeletionMarker(pending);
      await _resumeProviderDeletion(pending);
    }
    final persisted = await store.loadProviders();
    if (persisted.failure != null) throw AiStoreException(persisted.failure!);
    final deleting = persisted.value
        ?.where(
          (candidate) =>
              candidate.id == provider.id && _isDeletingProvider(candidate),
        )
        .firstOrNull;
    if (deleting != null) await _resumeProviderDeletion(deleting);
    final existing = _provider(provider.id);
    final previousKey = existing == null ? null : _providerKeys[provider.id];
    final replacementKey = key?.trim();
    if (key != null && replacementKey != key) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProviderKey'),
      );
    }
    if (provider.caps.requiresKey && replacementKey == null) {
      if (existing == null ||
          previousKey == null ||
          !_sameKeyRecipient(existing, provider)) {
        throw const AiStoreException(
          AiStoreFailure(
            AiStoreFailureKind.invalidValue,
            'providerKeyRequired',
          ),
        );
      }
    }
    if (replacementKey != null) {
      final assessment = assessAiProviderKey(replacementKey);
      if (!assessment.accepted) {
        throw const AiStoreException(
          AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProviderKey'),
        );
      }
      if (assessment.warning != null && !acknowledgeWarning) {
        throw const AiStoreException(
          AiStoreFailure(
            AiStoreFailureKind.confirmationRequired,
            'saveProviderKey',
          ),
        );
      }
    }

    final keyChanged =
        replacementKey != null &&
        (replacementKey != previousKey ||
            existing == null ||
            !_sameKeyRecipient(existing, provider));
    if (keyChanged) {
      try {
        if (existing != null && previousKey != null) {
          await _saveProviderKeyBinding(existing, previousKey);
        }
        await _persistProviderKey(
          provider,
          replacementKey,
          acknowledgeWarning: acknowledgeWarning,
        );
      } catch (_) {
        await _restoreProviderKey(
          existing,
          provider.id,
          previousKey,
          acknowledgeWarning: true,
        );
        rethrow;
      }
    }

    final revision = existing == null
        ? 1
        : _sameRecipient(existing, provider) && !keyChanged
        ? existing.recipientRevision
        : existing.recipientRevision + 1;
    final saved = _copyProvider(provider, recipientRevision: revision);
    final updated = <AiProviderConfig>[
      for (final current in _providers)
        current.id == saved.id ? saved : current,
      if (existing == null) saved,
    ];
    try {
      await _writeProviderList(updated);
    } catch (_) {
      if (keyChanged) {
        await _restoreProviderKey(
          existing,
          provider.id,
          previousKey,
          acknowledgeWarning: true,
        );
      }
      rethrow;
    }

    if (provider.caps.requiresKey) {
      final activeKey = replacementKey ?? previousKey!;
      if (_providerKeys[provider.id] != activeKey) _secretSetId += 1;
      _providerKeys[provider.id] = activeKey;
    } else {
      await store.deleteProviderKey(provider.id);
      await _deleteProviderKeyBinding(provider.id);
      if (_providerKeys.remove(provider.id) != null) _secretSetId += 1;
    }
    _providers = List.unmodifiable(updated);
    _markInitialized();
    _notify();
    return saved;
  }

  Future<void> _restoreProviderKey(
    AiProviderConfig? provider,
    String providerId,
    String? key, {
    required bool acknowledgeWarning,
  }) async {
    if (key == null) {
      await store.deleteProviderKey(providerId);
      await _deleteProviderKeyBinding(providerId);
    } else {
      await _persistProviderKey(
        provider!,
        key,
        acknowledgeWarning: acknowledgeWarning,
      );
    }
  }

  Future<bool> _keyBindingMatches(AiProviderConfig provider, String key) async {
    if (store case final AiProviderKeyBindingStore bindings) {
      final stored = await bindings.readProviderKeyBinding(provider.id);
      if (stored.failure != null) throw AiStoreException(stored.failure!);
      final expected = _providerKeyBinding(provider, key);
      if (!stored.isFound) {
        // One-time migration of a pre-binding key. This runs before any
        // coordinated replacement can alter the key slot.
        await bindings.saveProviderKeyBinding(provider.id, expected);
        return true;
      }
      return stored.value == expected;
    }
    return true;
  }

  Future<void> _persistProviderKey(
    AiProviderConfig provider,
    String key, {
    required bool acknowledgeWarning,
  }) async {
    await _saveProviderKeyBinding(provider, key);
    await store.saveProviderKey(
      provider.id,
      key,
      acknowledgeWarning: acknowledgeWarning,
    );
  }

  Future<void> _saveProviderKeyBinding(
    AiProviderConfig provider,
    String key,
  ) async {
    if (store case final AiProviderKeyBindingStore bindings) {
      await bindings.saveProviderKeyBinding(
        provider.id,
        _providerKeyBinding(provider, key),
      );
    }
  }

  Future<void> _deleteProviderKeyBinding(String providerId) async {
    if (store case final AiProviderKeyBindingStore bindings) {
      await bindings.deleteProviderKeyBinding(providerId);
    }
  }

  /// Returns a credential only when it is still bound to the candidate's
  /// normalized recipient and authentication style.
  String? providerKeyFor(AiProviderConfig candidate) {
    if (!candidate.caps.requiresKey) return null;
    final existing = _provider(candidate.id);
    if (existing == null) return null;
    try {
      if (!_sameKeyRecipient(existing, candidate)) return null;
    } on AiFailure {
      return null;
    }
    return _providerKeys[candidate.id];
  }

  /// The first persisted provider is the device default. Reordering avoids a
  /// second preference that could point at a deleted provider.
  Future<void> setDefaultProvider(String providerId) => _enqueue(() async {
    final selected = _requireProvider(providerId);
    final updated = <AiProviderConfig>[
      selected,
      for (final provider in _providers)
        if (provider.id != providerId) provider,
    ];
    await _writeProviderList(updated, reset: true);
    _providers = List.unmodifiable(updated);
    _notify();
  });

  Future<void> setConversationTokenCap(String accountKey, int cap) async {
    if (cap < 50000 || cap > 5000000) {
      throw ArgumentError.value(cap, 'conversationTokenCap');
    }
    final updated = await _accountMutations.mutate(
      accountKey,
      (current) => current.copyWith(conversationTokenCap: cap),
    );
    if (updated == null) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.cleaning, 'setConversationTokenCap'),
      );
    }
  }

  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) => _enqueue(
    () => _saveProviderKey(
      providerId,
      key,
      acknowledgeWarning: acknowledgeWarning,
    ),
  );

  Future<void> _saveProviderKey(
    String providerId,
    String key, {
    required bool acknowledgeWarning,
  }) async {
    final provider = _requireProvider(providerId);
    if (!provider.caps.requiresKey) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProviderKey'),
      );
    }
    final assessment = assessAiProviderKey(key);
    if (!assessment.accepted) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProviderKey'),
      );
    }
    if (assessment.warning != null && !acknowledgeWarning) {
      throw const AiStoreException(
        AiStoreFailure(
          AiStoreFailureKind.confirmationRequired,
          'saveProviderKey',
        ),
      );
    }
    if (_providerKeys[providerId] == key) return;
    final revised = _copyProvider(
      provider,
      recipientRevision: provider.recipientRevision + 1,
    );
    await _replaceProvider(revised);
    _notify();
    await _persistProviderKey(
      provider,
      key,
      acknowledgeWarning: acknowledgeWarning,
    );
    _providerKeys[providerId] = key;
    _secretSetId += 1;
    _notify();
  }

  Future<void> deleteProviderKey(String providerId) =>
      _enqueue(() => _deleteProviderKey(providerId));

  Future<void> _deleteProviderKey(String providerId) async {
    final provider = _requireProvider(providerId);
    final read = await store.readProviderKey(providerId);
    if (read.status == AiStoreReadStatus.unavailable) {
      throw AiStoreException(read.failure!);
    }
    final existed = read.isFound || read.failure != null;
    if (!existed) return;
    final revised = _copyProvider(
      provider,
      recipientRevision: provider.recipientRevision + 1,
    );
    await _replaceProvider(revised);
    _notify();
    await store.deleteProviderKey(providerId);
    await _deleteProviderKeyBinding(providerId);
    _providerKeys.remove(providerId);
    _secretSetId += 1;
    _notify();
  }

  Future<void> deleteProvider(String providerId) =>
      _enqueue(() => _deleteProvider(providerId));

  Future<void> _deleteProvider(String providerId) async {
    final provider =
        _deletingProviders[providerId] ?? _requireProvider(providerId);
    final deleting = _copyProviderWithPreset(
      provider,
      presetId: _deletingProviderPreset,
    );
    _markProviderDeleting(deleting);
    await _writeProviderList(_providers);
    await _resumeProviderDeletion(deleting);
  }

  Future<void> _persistProviderDeletionMarker(AiProviderConfig deleting) async {
    _markProviderDeleting(deleting);
    await _writeProviderList(_providers);
  }

  Future<void> _resumeProviderDeletion(AiProviderConfig deleting) async {
    final providerId = deleting.id;
    for (final accountKey in await _readAccountKeys()) {
      final before = await store.loadAccount(accountKey);
      if (before.failure case final failure?) {
        if (failure.kind == AiStoreFailureKind.malformed) {
          _malformedAccountRecords.add(accountKey);
          _notify();
          continue;
        }
        throw AiStoreException(failure);
      }
      if (before.value?.consents.containsKey(providerId) != true) continue;
      AiAccountRecord? updated;
      try {
        updated = await _accountMutations.mutate(accountKey, (account) {
          final consents = Map<String, AiConsentRecord>.of(account.consents)
            ..remove(providerId);
          return account.copyWith(consents: consents);
        });
      } on AiStoreException catch (error) {
        if (error.failure.kind != AiStoreFailureKind.malformed) rethrow;
        _malformedAccountRecords.add(accountKey);
        _notify();
        continue;
      }
      if (updated != null) {
        _accounts[accountKey] = updated;
        _consentRevisions[accountKey] = consentRevision(accountKey) + 1;
        _notify();
      } else {
        await _requireTombstoneForSkippedMutation(accountKey, 'deleteProvider');
      }
    }
    final key = await store.readProviderKey(providerId);
    if (key.status == AiStoreReadStatus.unavailable) {
      throw AiStoreException(key.failure!);
    }
    await store.deleteProviderKey(providerId);
    await _deleteProviderKeyBinding(providerId);
    _providerKeys.remove(providerId);
    _notify();
    await _writeProviderList(
      _providers,
      removeDeletingIds: <String>{providerId},
    );
    _deletingProviders.remove(providerId);
    _finishProviderDeletion(providerId);
  }

  Future<void> grantConsent(
    String accountKey,
    AiConsentContract contract,
    Map<String, Object?> summary, {
    DateTime? grantedAt,
    int? expectedRecipientRevision,
  }) {
    final epoch = _accountMutations.epochFor(accountKey);
    final revision =
        expectedRecipientRevision ??
        _provider(contract.providerId)?.recipientRevision ??
        -1;
    return _enqueue(
      () => _grantConsent(
        accountKey,
        contract,
        summary,
        epoch: epoch,
        grantedAt: grantedAt,
        expectedRecipientRevision: revision,
      ),
    );
  }

  Future<void> _grantConsent(
    String accountKey,
    AiConsentContract contract,
    Map<String, Object?> summary, {
    required int epoch,
    required int expectedRecipientRevision,
    DateTime? grantedAt,
  }) async {
    if (!_accountMutations.isCurrent(accountKey, epoch)) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.cleaning, 'grantConsent'),
      );
    }
    if (_requireProvider(contract.providerId).recipientRevision !=
        expectedRecipientRevision) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.invalidValue, 'recipientChanged'),
      );
    }
    final updated = await _accountMutations.mutate(accountKey, (account) {
      final consents = Map<String, AiConsentRecord>.of(account.consents);
      consents[contract.providerId] = AiConsentRecord(
        hash: contract.hash,
        summary: summary,
        grantedAt: (grantedAt ?? DateTime.now()).toUtc(),
      );
      return account.copyWith(consents: consents);
    });
    if (updated == null) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.cleaning, 'grantConsent'),
      );
    }
    _accounts[accountKey] = updated;
    _consentRevisions[accountKey] = consentRevision(accountKey) + 1;
    _notify();
  }

  Future<void> revokeConsent(
    String accountKey,
    String providerId, {
    AiConsentRecord? onlyIf,
  }) {
    final epoch = _accountMutations.epochFor(accountKey);
    return _enqueue(
      () => _revokeConsent(accountKey, providerId, epoch, onlyIf),
    );
  }

  Future<void> _revokeConsent(
    String accountKey,
    String providerId,
    int epoch,
    AiConsentRecord? onlyIf,
  ) async {
    if (!_accountMutations.isCurrent(accountKey, epoch)) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.cleaning, 'revokeConsent'),
      );
    }
    var removed = false;
    final updated = await _accountMutations.mutate(accountKey, (account) {
      final current = account.consents[providerId];
      if (current == null) return account;
      if (onlyIf != null &&
          (current.hash != onlyIf.hash ||
              current.grantedAt != onlyIf.grantedAt)) {
        return account;
      }
      removed = true;
      final consents = Map<String, AiConsentRecord>.of(account.consents)
        ..remove(providerId);
      return account.copyWith(consents: consents);
    });
    if (updated == null) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.cleaning, 'revokeConsent'),
      );
    }
    if (!removed) return;
    _accounts[accountKey] = updated;
    _consentRevisions[accountKey] = consentRevision(accountKey) + 1;
    _notify();
  }

  bool isValid(String accountKey, AiConsentContract contract) =>
      _provider(contract.providerId) != null &&
      _accounts[accountKey]?.consents[contract.providerId]?.hash ==
          contract.hash;

  AiProviderConfig? _provider(String providerId) {
    for (final provider in _providers) {
      if (provider.id == providerId) return provider;
    }
    return null;
  }

  AiProviderConfig _requireProvider(String providerId) =>
      _provider(providerId) ??
      (throw AiStoreException(
        const AiStoreFailure(
          AiStoreFailureKind.invalidValue,
          'providerNotFound',
        ),
      ));

  Future<void> resetProviders() => _enqueue(() async {
    final deletingIds = _deletingProviders.keys.toSet();
    final providerIds = <String>{};
    if (store is AiStoreSecureInventory) {
      providerIds.addAll(await _readProviderKeyIds());
    }
    final accounts = <String, AiAccountRecord?>{};
    for (final accountKey in await _readAccountKeys()) {
      final before = await store.loadAccount(accountKey);
      if (before.failure case final failure?) {
        if (failure.kind == AiStoreFailureKind.malformed) {
          _malformedAccountRecords.add(accountKey);
          continue;
        }
        throw AiStoreException(failure);
      }
      accounts[accountKey] = before.value;
      if (before.value?.consents.isNotEmpty == true &&
          _accountMutations.isCleaning(accountKey)) {
        await _requireTombstoneForSkippedMutation(accountKey, 'resetProviders');
      }
    }
    for (final entry in accounts.entries) {
      final accountKey = entry.key;
      AiAccountRecord? updated;
      try {
        updated = await _accountMutations.mutate(accountKey, (account) {
          providerIds.addAll(account.consents.keys);
          return account.copyWith(consents: const <String, AiConsentRecord>{});
        });
      } on AiStoreException catch (error) {
        if (error.failure.kind != AiStoreFailureKind.malformed) rethrow;
        _malformedAccountRecords.add(accountKey);
        continue;
      }
      if (updated != null) {
        _accounts[accountKey] = updated;
        _consentRevisions[accountKey] = consentRevision(accountKey) + 1;
      } else if (entry.value?.consents.isNotEmpty == true) {
        await _requireTombstoneForSkippedMutation(accountKey, 'resetProviders');
      }
    }
    try {
      for (final providerId in providerIds) {
        await store.deleteProviderKey(providerId);
        await _deleteProviderKeyBinding(providerId);
        // Keep the cache equal to the store if a later step fails, so the
        // same key saved again is written instead of seen as unchanged.
        if (_providerKeys.remove(providerId) != null) _secretSetId += 1;
      }
      await _writeProviderList(
        const <AiProviderConfig>[],
        removeDeletingIds: deletingIds,
        reset: true,
      );
    } finally {
      _notify();
    }
    _providers = const <AiProviderConfig>[];
    _deletingProviders.clear();
    _providerKeys.clear();
    for (final providerId in deletingIds) {
      _finishProviderDeletion(providerId);
    }
    _secretSetId += 1;
    _markInitialized();
    _notify();
  });

  Future<void> repairProviderKey(String providerId) => _enqueue(() async {
    final provider = _provider(providerId);
    if (provider != null) {
      final revised = _copyProvider(
        provider,
        recipientRevision: provider.recipientRevision + 1,
      );
      await _replaceProvider(revised);
      _notify();
    }
    await store.deleteProviderKey(providerId);
    await _deleteProviderKeyBinding(providerId);
    if (_providerKeys.remove(providerId) != null) _secretSetId += 1;
    _notify();
  });

  void _accountRecordChanged(String accountKey, AiAccountRecord? account) {
    if (account == null) {
      _accounts.remove(accountKey);
    } else {
      _accounts[accountKey] = account;
    }
    _notify();
  }

  Future<List<String>> _readAccountKeys() async {
    final inventory = await readAiSecureInventory(store);
    final countBefore = _malformedSecureInventoryEntries.length;
    _malformedSecureInventoryEntries.addAll(inventory.malformedAccountKeys);
    if (_malformedSecureInventoryEntries.length != countBefore) {
      _notify();
    }
    return inventory.accountKeys;
  }

  Future<List<String>> _readProviderKeyIds() async {
    final inventory = await readAiSecureInventory(store);
    final countBefore = _malformedSecureInventoryEntries.length;
    _malformedSecureInventoryEntries.addAll(inventory.malformedProviderKeys);
    if (_malformedSecureInventoryEntries.length != countBefore) {
      _notify();
    }
    return inventory.providerKeyIds;
  }

  Future<void> _requireTombstoneForSkippedMutation(
    String accountKey,
    String operation,
  ) async {
    final tombstone = await store.readTombstone(accountKey);
    if (tombstone.failure != null) {
      throw AiStoreException(tombstone.failure!);
    }
    if (!tombstone.isFound) {
      throw AiStoreException(
        AiStoreFailure(AiStoreFailureKind.cleaning, operation),
      );
    }
  }

  void _markProviderDeleting(AiProviderConfig provider) {
    _deletingProviders[provider.id] = provider;
    _providers = List.unmodifiable(<AiProviderConfig>[
      for (final current in _providers)
        if (current.id != provider.id) current,
    ]);
    if (_providerKeys.remove(provider.id) != null) _secretSetId += 1;
    for (final entry in _accounts.entries.toList()) {
      if (!entry.value.consents.containsKey(provider.id)) continue;
      final consents = Map<String, AiConsentRecord>.of(entry.value.consents)
        ..remove(provider.id);
      _accounts[entry.key] = entry.value.copyWith(consents: consents);
    }
    _notify();
  }

  void _finishProviderDeletion(String providerId) {
    _deletingProviders.remove(providerId);
  }

  Future<void> _replaceProvider(AiProviderConfig replacement) async {
    final updated = <AiProviderConfig>[
      for (final provider in _providers)
        provider.id == replacement.id ? replacement : provider,
    ];
    await _writeProviderList(updated);
    _providers = List.unmodifiable(updated);
  }

  Future<void> _writeProviderList(
    List<AiProviderConfig> active, {
    Set<String> removeDeletingIds = const <String>{},
    bool reset = false,
  }) async {
    final deleting = <String, AiProviderConfig>{
      for (final entry in _deletingProviders.entries)
        if (!removeDeletingIds.contains(entry.key)) entry.key: entry.value,
    };
    final mergedActive = <String, AiProviderConfig>{};
    if (!reset) {
      final persisted = await store.loadProviders();
      if (persisted.failure != null) {
        throw AiStoreException(persisted.failure!);
      }
      for (final provider in persisted.value ?? const <AiProviderConfig>[]) {
        if (_isDeletingProvider(provider) &&
            !removeDeletingIds.contains(provider.id)) {
          deleting.putIfAbsent(provider.id, () => provider);
        } else if (!_isDeletingProvider(provider)) {
          mergedActive[provider.id] = provider;
        }
      }
    }
    for (final provider in active) {
      mergedActive[provider.id] = provider;
    }
    await store.saveProviders(<AiProviderConfig>[
      for (final provider in mergedActive.values)
        if (!deleting.containsKey(provider.id)) provider,
      ...deleting.values,
    ]);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (_disposed) {
      return Future<T>.error(StateError('AiSettingsController is disposed'));
    }
    final previous = _providerMutationTail;
    final run = (previous ?? Future<void>.value()).then((_) => action());
    final tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _providerMutationTail = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_providerMutationTail, tail)) {
          _providerMutationTail = null;
        }
      }),
    );
    return run;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _markInitialized() {
    _initialized = true;
    _initializationFailure = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final pending = _providerMutationTail;
    if (pending == null) {
      _releaseSettingsOwner();
    } else {
      unawaited(pending.whenComplete(_releaseSettingsOwner));
    }
    _accountMutations.removeListener(_accountRecordChanged);
    super.dispose();
  }

  void _releaseSettingsOwner() {
    if (identical(_settingsOwners[_settingsScope], this)) {
      _settingsOwners[_settingsScope] = null;
    }
  }
}

AiStoreRead<R> _copyRead<R>(AiStoreRead<Object?> source) =>
    source.status == AiStoreReadStatus.unavailable
    ? AiStoreRead<R>.unavailable(source.failure!)
    : AiStoreRead<R>.absent(source.failure);

AiSecureInventory _decodeSecureInventory(Iterable<String> storedKeys) {
  final providerKeys = <String>[];
  final accountKeys = <String>[];
  final historyKeys = <String>[];
  final malformedProviderKeyEntries = <String>{};
  final malformedAccountKeyEntries = <String>{};
  final malformedHistoryKeyEntries = <String>{};
  var malformedProviderKeys = 0;
  var malformedAccountKeys = 0;
  var malformedHistoryKeys = 0;
  for (final key in storedKeys) {
    if (key.startsWith(SecureAiStore.providerKeyPrefix)) {
      try {
        providerKeys.add(
          _decodeStoredId(
            key.substring(SecureAiStore.providerKeyPrefix.length),
            'readSecureInventory',
          ),
        );
      } on AiStoreException {
        malformedProviderKeys += 1;
        malformedProviderKeyEntries.add(key);
      }
    } else if (key.startsWith(SecureAiStore.accountPrefix)) {
      try {
        accountKeys.add(
          _decodeStoredId(
            key.substring(SecureAiStore.accountPrefix.length),
            'readSecureInventory',
          ),
        );
      } on AiStoreException {
        malformedAccountKeys += 1;
        malformedAccountKeyEntries.add(key);
      }
    } else if (key.startsWith(SecureAiStore.historyKeyPrefix)) {
      try {
        historyKeys.add(
          _decodeStoredId(
            key.substring(SecureAiStore.historyKeyPrefix.length),
            'readSecureInventory',
          ),
        );
      } on AiStoreException {
        malformedHistoryKeys += 1;
        malformedHistoryKeyEntries.add(key);
      }
    }
  }
  providerKeys.sort();
  accountKeys.sort();
  historyKeys.sort();
  return AiSecureInventory(
    providerKeyIds: List.unmodifiable(providerKeys),
    accountKeys: List.unmodifiable(accountKeys),
    historyKeyAccountKeys: List.unmodifiable(historyKeys),
    malformedProviderKeyCount: malformedProviderKeys,
    malformedAccountKeyCount: malformedAccountKeys,
    malformedHistoryKeyCount: malformedHistoryKeys,
    malformedProviderKeys: Set.unmodifiable(malformedProviderKeyEntries),
    malformedAccountKeys: Set.unmodifiable(malformedAccountKeyEntries),
    malformedHistoryKeys: Set.unmodifiable(malformedHistoryKeyEntries),
  );
}

bool _sameRecipient(AiProviderConfig left, AiProviderConfig right) =>
    left.baseUrl == right.baseUrl &&
    left.format == right.format &&
    left.model == right.model &&
    left.authStyle == right.authStyle &&
    left.allowLanCleartext == right.allowLanCleartext &&
    left.toolsEnabled == right.toolsEnabled &&
    left.caps == right.caps;

bool _sameKeyRecipient(AiProviderConfig left, AiProviderConfig right) =>
    left.authStyle == right.authStyle &&
    _providerRecipient(left) == _providerRecipient(right);

String _providerRecipient(AiProviderConfig provider) => AiEndpoint.parse(
  provider.baseUrl,
  allowLanCleartext: provider.allowLanCleartext,
).key;

String _providerKeyBinding(AiProviderConfig provider, String key) => sha256
    .convert(
      utf8.encode(
        jsonEncode(<String, String>{
          'recipient': _providerRecipient(provider),
          'authStyle': provider.authStyle.name,
          'keyDigest': sha256.convert(utf8.encode(key)).toString(),
        }),
      ),
    )
    .toString();

const _deletingProviderPreset = 'gitlab-mobile:deleting-provider';

bool _isDeletingProvider(AiProviderConfig provider) =>
    provider.presetId == _deletingProviderPreset;

void _validateProviderEndpoints(AiProviderConfig provider) {
  try {
    AiEndpoint.parse(
      provider.baseUrl,
      allowLanCleartext: provider.allowLanCleartext,
    );
    final modelsUrl = provider.modelsUrl;
    if (modelsUrl != null && modelsUrl.trim().isNotEmpty) {
      AiEndpoint.parse(
        modelsUrl,
        allowLanCleartext: provider.allowLanCleartext,
      );
    }
  } on Object catch (error) {
    throw AiStoreException(
      AiStoreFailure(
        AiStoreFailureKind.invalidValue,
        'saveProviderEndpoint',
        error,
      ),
    );
  }
}

void _validateProviderCaps(AiCaps caps) {
  if (caps.maxRequestChars <= 0 ||
      caps.maxOutputTokens < 512 ||
      caps.maxOutputTokens > 65536) {
    throw const AiStoreException(
      AiStoreFailure(AiStoreFailureKind.invalidValue, 'saveProviderCaps'),
    );
  }
}

AiProviderConfig _copyProviderWithPreset(
  AiProviderConfig provider, {
  required String presetId,
}) => AiProviderConfig(
  id: provider.id,
  name: provider.name,
  presetId: presetId,
  baseUrl: provider.baseUrl,
  modelsUrl: provider.modelsUrl,
  format: provider.format,
  model: provider.model,
  authStyle: provider.authStyle,
  caps: provider.caps,
  allowLanCleartext: provider.allowLanCleartext,
  toolsEnabled: provider.toolsEnabled,
  recipientRevision: provider.recipientRevision,
);

AiProviderConfig _copyProvider(
  AiProviderConfig provider, {
  required int recipientRevision,
}) => AiProviderConfig(
  id: provider.id,
  name: provider.name,
  presetId: provider.presetId,
  baseUrl: provider.baseUrl,
  modelsUrl: provider.modelsUrl,
  format: provider.format,
  model: provider.model,
  authStyle: provider.authStyle,
  caps: provider.caps,
  allowLanCleartext: provider.allowLanCleartext,
  toolsEnabled: provider.toolsEnabled,
  recipientRevision: recipientRevision,
);

String _encodeId(String value) => base64Url.encode(utf8.encode(value));

String _decodeStoredId(String encoded, String operation) {
  try {
    final decoded = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    if (decoded.isEmpty || _encodeId(decoded) != encoded) {
      throw const FormatException('Non-canonical storage key');
    }
    return decoded;
  } on Object catch (error) {
    throw AiStoreException(
      AiStoreFailure(AiStoreFailureKind.malformed, operation, error),
    );
  }
}

List<AiProviderConfig> _decodeProviders(String raw) {
  final json = _strictObject(jsonDecode(raw), 'providers');
  _requireKeys(json, const <String>{'version', 'providers'});
  if (json['version'] != 1 || json['providers'] is! List<Object?>) {
    throw const FormatException('Unsupported AI providers payload');
  }
  final result = <AiProviderConfig>[];
  final ids = <String>{};
  for (final rawProvider in json['providers']! as List<Object?>) {
    final provider = _decodeProvider(rawProvider);
    if (!ids.add(provider.id)) {
      throw const FormatException('Duplicate provider id');
    }
    result.add(provider);
  }
  return List.unmodifiable(result);
}

Map<String, Object?> _providerToJson(AiProviderConfig provider) =>
    <String, Object?>{
      'id': provider.id,
      'name': provider.name,
      'presetId': provider.presetId,
      'baseUrl': provider.baseUrl,
      'modelsUrl': provider.modelsUrl,
      'format': provider.format.name,
      'model': provider.model,
      'authStyle': provider.authStyle.name,
      'caps': <String, Object?>{
        'tokenLimitField': provider.caps.tokenLimitField.name,
        'streamUsage': provider.caps.streamUsage,
        'toolChoice': provider.caps.toolChoice,
        'replayChatExtras': provider.caps.replayChatExtras,
        'includeEncryptedReasoning': provider.caps.includeEncryptedReasoning,
        'promptCaching': provider.caps.promptCaching,
        'requiresKey': provider.caps.requiresKey,
        'maxRequestChars': provider.caps.maxRequestChars,
        'maxOutputTokens': provider.caps.maxOutputTokens,
      },
      'allowLanCleartext': provider.allowLanCleartext,
      'toolsEnabled': provider.toolsEnabled,
      'revision': provider.recipientRevision,
    };

AiProviderConfig _decodeProvider(Object? raw) {
  final json = _strictObject(raw, 'provider');
  _requireKeys(json, const <String>{
    'id',
    'name',
    'presetId',
    'baseUrl',
    'modelsUrl',
    'format',
    'model',
    'authStyle',
    'caps',
    'allowLanCleartext',
    'toolsEnabled',
    'revision',
  });
  final modelsUrl = json['modelsUrl'];
  if (modelsUrl != null && modelsUrl is! String) {
    throw const FormatException('Invalid provider.modelsUrl');
  }
  final allowLanCleartext = json['allowLanCleartext'];
  final toolsEnabled = json['toolsEnabled'];
  final revision = json['revision'];
  if (allowLanCleartext is! bool ||
      toolsEnabled is! bool ||
      revision is! int ||
      revision < 0) {
    throw const FormatException('Invalid provider field type');
  }
  return AiProviderConfig(
    id: _nonEmptyString(json['id'], 'provider.id'),
    name: _nonEmptyString(json['name'], 'provider.name'),
    presetId: _nonEmptyString(json['presetId'], 'provider.presetId'),
    baseUrl: _nonEmptyString(json['baseUrl'], 'provider.baseUrl'),
    modelsUrl: modelsUrl as String?,
    format: _enumValue(AiFormat.values, json['format'], 'provider.format'),
    model: _nonEmptyString(json['model'], 'provider.model'),
    authStyle: _enumValue(
      AiAuthStyle.values,
      json['authStyle'],
      'provider.authStyle',
    ),
    caps: _decodeCaps(json['caps']),
    allowLanCleartext: allowLanCleartext,
    toolsEnabled: toolsEnabled,
    recipientRevision: revision,
  );
}

AiCaps _decodeCaps(Object? raw) {
  final json = _strictObject(raw, 'provider.caps');
  _requireKeys(json, <String>{
    'tokenLimitField',
    'streamUsage',
    'toolChoice',
    'replayChatExtras',
    'includeEncryptedReasoning',
    'promptCaching',
    'requiresKey',
    'maxRequestChars',
    if (json.containsKey('maxOutputTokens')) 'maxOutputTokens',
  });
  final booleans = <String>[
    'streamUsage',
    'toolChoice',
    'replayChatExtras',
    'includeEncryptedReasoning',
    'promptCaching',
    'requiresKey',
  ];
  if (booleans.any((key) => json[key] is! bool) ||
      json['maxRequestChars'] is! int ||
      (json['maxRequestChars']! as int) <= 0) {
    throw const FormatException('Invalid provider caps');
  }
  final maxOutputTokens = json['maxOutputTokens'] ?? 4096;
  if (maxOutputTokens is! int ||
      maxOutputTokens < 512 ||
      maxOutputTokens > 65536) {
    throw const FormatException('Invalid output token limit');
  }
  return AiCaps(
    tokenLimitField: _enumValue(
      AiTokenLimitField.values,
      json['tokenLimitField'],
      'provider.caps.tokenLimitField',
    ),
    streamUsage: json['streamUsage']! as bool,
    toolChoice: json['toolChoice']! as bool,
    replayChatExtras: json['replayChatExtras']! as bool,
    includeEncryptedReasoning: json['includeEncryptedReasoning']! as bool,
    promptCaching: json['promptCaching']! as bool,
    requiresKey: json['requiresKey']! as bool,
    maxRequestChars: json['maxRequestChars']! as int,
    maxOutputTokens: maxOutputTokens,
  );
}

T _enumValue<T extends Enum>(List<T> values, Object? raw, String field) {
  if (raw is! String) throw FormatException('Invalid $field');
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw FormatException('Invalid $field');
}

Map<String, Object?> _strictObject(Object? raw, String field) {
  if (raw is! Map<String, Object?>) throw FormatException('Invalid $field');
  return raw;
}

void _requireKeys(Map<String, Object?> json, Set<String> expected) {
  if (json.length != expected.length || !json.keys.every(expected.contains)) {
    throw const FormatException('Unexpected JSON fields');
  }
}

String _nonEmptyString(Object? raw, String field) {
  if (raw is! String || raw.isEmpty) throw FormatException('Invalid $field');
  return raw;
}

void _validateRetention(int days) {
  if (days != 7 && days != 30 && days != 90) {
    throw ArgumentError.value(days, 'retentionDays');
  }
}

void _validateJson(Object? value, String field) {
  if (value == null || value is bool || value is num || value is String) return;
  if (value is List<Object?>) {
    for (final item in value) {
      _validateJson(item, field);
    }
    return;
  }
  if (value is Map<String, Object?>) {
    for (final item in value.values) {
      _validateJson(item, field);
    }
    return;
  }
  throw FormatException('Invalid $field');
}
