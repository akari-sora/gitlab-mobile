import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/ai/ai_provider.dart';

enum AiStoreReadStatus { found, absent, unavailable }

enum AiStoreFailureKind {
  malformed,
  unavailable,
  invalidValue,
  confirmationRequired,
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

final class SecureAiStore implements AiStore {
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

  final FlutterSecureStorage _storage;

  static String providerKey(String providerId) =>
      '$providerKeyPrefix${_encodeId(providerId)}';

  static String accountKey(String accountKey) =>
      '$accountPrefix${_encodeId(accountKey)}';

  static String historyKey(String accountKey) =>
      '$historyKeyPrefix${_encodeId(accountKey)}';

  static String tombstoneKey(String accountKey) =>
      '$tombstonePrefix${_encodeId(accountKey)}';

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
  Future<List<String>> listAccountKeys() =>
      _listEncodedKeys(accountPrefix, 'listAccountKeys');

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

final class MemoryAiStore implements AiStore {
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
    return value == null
        ? const AiStoreRead<String>.absent()
        : AiStoreRead<String>.found(value);
  }

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) async => Map.unmodifiable(<String, String>{
    for (final providerId in providerIds.toSet())
      providerId: ?_values[SecureAiStore.providerKey(providerId)],
  });

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
  Future<AiStoreRead<bool>> readTombstone(String accountKey) async =>
      _values[SecureAiStore.tombstoneKey(accountKey)] == '1'
      ? const AiStoreRead<bool>.found(true)
      : const AiStoreRead<bool>.absent();

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
  Future<void> clearTombstone(String accountKey) async {
    _values.remove(SecureAiStore.tombstoneKey(accountKey));
  }

  void debugPut(String key, String value) => _values[key] = value;
}

final class AiSettingsController extends ChangeNotifier {
  AiSettingsController(this.store);

  final AiStore store;
  List<AiProviderConfig> _providers = const <AiProviderConfig>[];
  final Map<String, String> _providerKeys = <String, String>{};
  final Map<String, AiAccountRecord> _accounts = <String, AiAccountRecord>{};
  final Map<String, int> _consentRevisions = <String, int>{};
  Future<void> _tail = Future<void>.value();
  var _secretSetId = 0;
  var _disposed = false;

  List<AiProviderConfig> get providers => _providers;
  Map<String, String> get knownProviderKeys => Map.unmodifiable(_providerKeys);
  int get secretSetId => _secretSetId;

  int? recipientRevision(String providerId) =>
      _provider(providerId)?.recipientRevision;

  int consentRevision(String accountKey) => _consentRevisions[accountKey] ?? 0;

  AiAccountRecord? accountRecord(String accountKey) => _accounts[accountKey];

  Future<void> initialize() => _enqueue(_initialize);

  Future<void> _initialize() async {
    final result = await store.loadProviders();
    if (result.failure != null) throw AiStoreException(result.failure!);
    final loaded = result.value ?? const <AiProviderConfig>[];
    final keys = <String, String>{};
    for (final provider in loaded) {
      final key = await store.readProviderKey(provider.id);
      if (key.failure != null) throw AiStoreException(key.failure!);
      if (key.isFound) keys[provider.id] = key.value!;
    }
    _providers = List.unmodifiable(loaded);
    _providerKeys
      ..clear()
      ..addAll(keys);
    _notify();
  }

  Future<AiAccountRecord> loadAccount(String accountKey) =>
      _enqueue(() => _loadAccountFresh(accountKey));

  Future<AiAccountRecord> _loadAccountFresh(String accountKey) async {
    final result = await store.loadAccount(accountKey);
    if (result.failure != null) throw AiStoreException(result.failure!);
    final account = result.value ?? AiAccountRecord();
    _accounts[accountKey] = account;
    return account;
  }

  Future<AiProviderConfig> saveProvider(AiProviderConfig provider) =>
      _enqueue(() => _saveProvider(provider));

  Future<AiProviderConfig> _saveProvider(AiProviderConfig provider) async {
    final existing = _provider(provider.id);
    final removesKey =
        existing != null &&
        !provider.caps.requiresKey &&
        _providerKeys.containsKey(provider.id);
    final revision = existing == null
        ? 1
        : _sameRecipient(existing, provider) && !removesKey
        ? existing.recipientRevision
        : existing.recipientRevision + 1;
    final saved = _copyProvider(provider, recipientRevision: revision);
    final updated = <AiProviderConfig>[
      for (final current in _providers)
        if (current.id != saved.id) current,
      saved,
    ];
    await store.saveProviders(updated);
    _providers = List.unmodifiable(updated);
    _notify();
    if (removesKey) {
      await store.deleteProviderKey(provider.id);
      _providerKeys.remove(provider.id);
      _secretSetId += 1;
      _notify();
    }
    return saved;
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
    await store.saveProviderKey(
      providerId,
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
    _providerKeys.remove(providerId);
    _secretSetId += 1;
    _notify();
  }

  Future<void> deleteProvider(String providerId) =>
      _enqueue(() => _deleteProvider(providerId));

  Future<void> _deleteProvider(String providerId) async {
    final key = await store.readProviderKey(providerId);
    if (key.status == AiStoreReadStatus.unavailable) {
      throw AiStoreException(key.failure!);
    }
    final accountUpdates = <String, AiAccountRecord>{};
    for (final accountKey in await store.listAccountKeys()) {
      final account = await _readAccount(accountKey);
      if (!account.consents.containsKey(providerId)) continue;
      final consents = Map<String, AiConsentRecord>.of(account.consents)
        ..remove(providerId);
      accountUpdates[accountKey] = account.copyWith(consents: consents);
    }

    final updatedProviders = <AiProviderConfig>[
      for (final provider in _providers)
        if (provider.id != providerId) provider,
    ];
    await store.saveProviders(updatedProviders);
    _providers = List.unmodifiable(updatedProviders);
    _notify();
    await store.deleteProviderKey(providerId);
    final keyExisted = key.isFound || key.failure != null;
    _providerKeys.remove(providerId);
    if (keyExisted) _secretSetId += 1;
    _notify();
    for (final entry in accountUpdates.entries) {
      await store.saveAccount(entry.key, entry.value);
    }

    for (final entry in accountUpdates.entries) {
      _accounts[entry.key] = entry.value;
      _consentRevisions[entry.key] = consentRevision(entry.key) + 1;
    }
    _notify();
  }

  Future<void> grantConsent(
    String accountKey,
    AiConsentContract contract,
    Map<String, Object?> summary, {
    DateTime? grantedAt,
  }) => _enqueue(
    () => _grantConsent(accountKey, contract, summary, grantedAt: grantedAt),
  );

  Future<void> _grantConsent(
    String accountKey,
    AiConsentContract contract,
    Map<String, Object?> summary, {
    DateTime? grantedAt,
  }) async {
    _requireProvider(contract.providerId);
    final account = await _readAccount(accountKey);
    final consents = Map<String, AiConsentRecord>.of(account.consents);
    consents[contract.providerId] = AiConsentRecord(
      hash: contract.hash,
      summary: summary,
      grantedAt: (grantedAt ?? DateTime.now()).toUtc(),
    );
    final updated = account.copyWith(consents: consents);
    await store.saveAccount(accountKey, updated);
    _accounts[accountKey] = updated;
    _consentRevisions[accountKey] = consentRevision(accountKey) + 1;
    _notify();
  }

  Future<void> revokeConsent(String accountKey, String providerId) =>
      _enqueue(() => _revokeConsent(accountKey, providerId));

  Future<void> _revokeConsent(String accountKey, String providerId) async {
    final account = await _readAccount(accountKey);
    if (!account.consents.containsKey(providerId)) return;
    final consents = Map<String, AiConsentRecord>.of(account.consents)
      ..remove(providerId);
    final updated = account.copyWith(consents: consents);
    await store.saveAccount(accountKey, updated);
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

  Future<AiAccountRecord> _readAccount(String accountKey) =>
      _loadAccountFresh(accountKey);

  Future<void> _replaceProvider(AiProviderConfig replacement) async {
    final updated = <AiProviderConfig>[
      for (final provider in _providers)
        provider.id == replacement.id ? replacement : provider,
    ];
    await store.saveProviders(updated);
    _providers = List.unmodifiable(updated);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (_disposed) {
      return Future<T>.error(StateError('AiSettingsController is disposed'));
    }
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

AiStoreRead<R> _copyRead<R>(AiStoreRead<Object?> source) =>
    source.status == AiStoreReadStatus.unavailable
    ? AiStoreRead<R>.unavailable(source.failure!)
    : AiStoreRead<R>.absent(source.failure);

bool _sameRecipient(AiProviderConfig left, AiProviderConfig right) =>
    left.baseUrl == right.baseUrl &&
    left.format == right.format &&
    left.model == right.model &&
    left.authStyle == right.authStyle &&
    left.allowLanCleartext == right.allowLanCleartext &&
    left.toolsEnabled == right.toolsEnabled;

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
  _requireKeys(json, const <String>{
    'tokenLimitField',
    'streamUsage',
    'toolChoice',
    'replayChatExtras',
    'includeEncryptedReasoning',
    'promptCaching',
    'requiresKey',
    'maxRequestChars',
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
