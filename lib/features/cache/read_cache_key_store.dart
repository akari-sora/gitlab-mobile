import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum ReadCacheStoreReadStatus { found, absent, unavailable }

enum ReadCacheStoreFailureKind {
  unavailable,
  malformed,
  invalidValue,
  readbackMismatch,
}

/// A deliberately small diagnostic which never retains native errors or
/// account-derived values.
final class ReadCacheStoreFailure {
  const ReadCacheStoreFailure(this.kind, this.operation);

  final ReadCacheStoreFailureKind kind;
  final String operation;

  @override
  String toString() => 'ReadCacheStoreFailure($kind, $operation)';
}

final class ReadCacheStoreException implements Exception {
  const ReadCacheStoreException(this.failure);

  final ReadCacheStoreFailure failure;

  @override
  String toString() => 'ReadCacheStoreException($failure)';
}

final class ReadCacheStoreRead<T> {
  const ReadCacheStoreRead.found(this.value)
    : status = ReadCacheStoreReadStatus.found,
      failure = null;

  const ReadCacheStoreRead.absent([this.failure])
    : status = ReadCacheStoreReadStatus.absent,
      value = null;

  const ReadCacheStoreRead.unavailable(this.failure)
    : status = ReadCacheStoreReadStatus.unavailable,
      value = null;

  final ReadCacheStoreReadStatus status;
  final T? value;
  final ReadCacheStoreFailure? failure;

  bool get isFound => status == ReadCacheStoreReadStatus.found;
}

enum ReadCacheClearReason {
  scopeInvalidation,
  accountClear,
  keyRepair,
  startup,
}

sealed class ReadCachePendingClear {
  const ReadCachePendingClear();

  /// Both a valid marker and an unknown marker conservatively require a full
  /// clear at startup. Policy and marker ownership belong to the coordinator.
  bool get requiresFullClear => true;
}

final class ReadCacheClearMarker extends ReadCachePendingClear {
  ReadCacheClearMarker({
    required this.intentId,
    required this.reason,
    required DateTime requestedAt,
    this.namespaceOnly = false,
  }) : requestedAt = requestedAt.toUtc() {
    if (!_intentIdPattern.hasMatch(intentId) ||
        (namespaceOnly &&
            reason != ReadCacheClearReason.scopeInvalidation &&
            reason != ReadCacheClearReason.keyRepair)) {
      throw const ReadCacheStoreException(
        ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.invalidValue,
          'createClearMarker',
        ),
      );
    }
  }

  static final _intentIdPattern = RegExp(r'^[0-9a-f]{32}$');

  /// An opaque 16-byte operation identifier encoded as lowercase hex.
  final String intentId;
  final ReadCacheClearReason reason;
  final DateTime requestedAt;
  final bool namespaceOnly;

  Map<String, Object> toJson() => <String, Object>{
    'version': namespaceOnly ? 2 : 1,
    if (namespaceOnly) 'namespace': 'read_cache',
    'intentId': intentId,
    'reason': reason.name,
    'requestedAt': requestedAt.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is ReadCacheClearMarker &&
      other.intentId == intentId &&
      other.reason == reason &&
      other.namespaceOnly == namespaceOnly &&
      other.requestedAt == requestedAt;

  @override
  int get hashCode => Object.hash(intentId, reason, requestedAt, namespaceOnly);
}

/// A present marker whose schema or value is unknown. Its raw value is not
/// retained; its presence alone requires a conservative full clear.
final class MalformedReadCacheClearMarker extends ReadCachePendingClear {
  const MalformedReadCacheClearMarker._();
}

final class ReadCacheSecureInventory {
  const ReadCacheSecureInventory({
    required this.status,
    this.keys = const <String, ReadCacheStoreRead<Uint8List>>{},
    this.markers = const <String, ReadCacheStoreRead<ReadCachePendingClear>>{},
    this.offlineKeys = const <String, ReadCacheStoreRead<Uint8List>>{},
    this.offlineMarkers = const <String, ReadCacheStoreRead<String>>{},
    this.offlineRefusals = const <String, ReadCacheStoreRead<String>>{},
    this.malformedNames = const <String>{},
    this.malformedValues = const <String>{},
    this.failure,
  });

  final ReadCacheStoreReadStatus status;

  /// Canonically decoded account keys and their independently decoded values.
  final Map<String, ReadCacheStoreRead<Uint8List>> keys;
  final Map<String, ReadCacheStoreRead<ReadCachePendingClear>> markers;
  // C3 marker schemas belong to their namespace; inventory tracks presence
  // without interpreting unknown versions as C2 marker values.
  final Map<String, ReadCacheStoreRead<Uint8List>> offlineKeys;
  final Map<String, ReadCacheStoreRead<String>> offlineMarkers;
  final Map<String, ReadCacheStoreRead<String>> offlineRefusals;

  Iterable<String> get accountKeys => <String>{
    ...keys.keys,
    ...markers.keys,
    ...offlineKeys.keys,
    ...offlineMarkers.keys,
    ...offlineRefusals.keys,
  };
  Iterable<String> get pendingAccountKeys => <String>{
    ...markers.keys,
    ...offlineMarkers.keys,
  };
  bool get isEmpty =>
      status == ReadCacheStoreReadStatus.found &&
      accountKeys.isEmpty &&
      malformedNames.isEmpty;
  bool containsAccount(String accountKey) =>
      keys.containsKey(accountKey) ||
      markers.containsKey(accountKey) ||
      offlineKeys.containsKey(accountKey) ||
      offlineMarkers.containsKey(accountKey) ||
      offlineRefusals.containsKey(accountKey);

  /// Exact secure-storage names. These are suitable only for explicit secure
  /// storage deletion and must never be used to construct filesystem paths.
  final Set<String> malformedNames;
  final Set<String> malformedValues;
  final ReadCacheStoreFailure? failure;
}

abstract interface class ReadCacheSecureStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

final class FlutterReadCacheSecureStorage implements ReadCacheSecureStorage {
  FlutterReadCacheSecureStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? _readCacheSecureStorage;

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

const FlutterSecureStorage _readCacheSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(),
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  ),
);

/// Secure key, clear-marker, and inventory primitives. This type intentionally
/// contains no key generation, queuing, cleanup, or open/closed state policy.
final class ReadCacheKeyStore {
  ReadCacheKeyStore([ReadCacheSecureStorage? storage])
    : _storage = storage ?? FlutterReadCacheSecureStorage();

  static const keyPrefix = 'read_cache_key.v1.';
  static const markerPrefix = 'read_cache_clear_pending.v1.';
  static const offlineKeyPrefix = 'offline_repo_key.v1.';
  static const offlineMarkerPrefix = 'offline_repo_clear_pending.v1.';
  static const offlineRefusalPrefix = 'offline_refused.v1.';

  final ReadCacheSecureStorage _storage;

  static String keyName(String accountKey) =>
      '$keyPrefix${base64Url.encode(utf8.encode(accountKey))}';

  static String markerName(String accountKey) =>
      '$markerPrefix${base64Url.encode(utf8.encode(accountKey))}';

  static String offlineKeyName(String accountKey) =>
      '$offlineKeyPrefix${base64Url.encode(utf8.encode(accountKey))}';
  static String offlineMarkerName(String accountKey) =>
      '$offlineMarkerPrefix${base64Url.encode(utf8.encode(accountKey))}';
  static String offlineRefusalName(String accountKey) =>
      '$offlineRefusalPrefix${base64Url.encode(utf8.encode(accountKey))}';

  Future<ReadCacheStoreRead<Uint8List>> readOfflineKey(
    String accountKey,
  ) async => _decodeKey(
    await _readRaw(offlineKeyName(accountKey), 'readOfflineKey'),
    'readOfflineKey',
  );

  Future<void> deleteOfflineKey(String accountKey) =>
      _deleteExact(offlineKeyName(accountKey), 'deleteOfflineKey');

  Future<void> writeOfflineKey(String accountKey, Uint8List key) async {
    if (key.length != 32) {
      throw const ReadCacheStoreException(
        ReadCacheStoreFailure(ReadCacheStoreFailureKind.invalidValue,
          'writeOfflineKey'),
      );
    }
    await _writeExact(offlineKeyName(accountKey), base64Url.encode(key),
      'writeOfflineKey');
  }

  Future<void> writeOfflineMarker(String accountKey, String value) =>
      _writeExact(offlineMarkerName(accountKey), value, 'writeOfflineMarker');

  Future<ReadCacheStoreRead<String>> readOfflineMarker(String accountKey) =>
      _readRaw(offlineMarkerName(accountKey), 'readOfflineMarker');

  Future<void> deleteOfflineMarker(String accountKey) =>
      _deleteExact(offlineMarkerName(accountKey), 'deleteOfflineMarker');

  Future<ReadCacheStoreRead<String>> readOfflineRefusal(String accountKey) =>
      _readRaw(offlineRefusalName(accountKey), 'readOfflineRefusal');

  Future<void> deleteOfflineRefusal(String accountKey) =>
      _deleteExact(offlineRefusalName(accountKey), 'deleteOfflineRefusal');

  Future<ReadCacheStoreRead<Uint8List>> readKey(String accountKey) async {
    final raw = await _readRaw(keyName(accountKey), 'readKey');
    return _decodeKey(raw, 'readKey');
  }

  Future<void> writeKey(String accountKey, Uint8List key) async {
    if (key.length != 32) {
      throw const ReadCacheStoreException(
        ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.invalidValue,
          'writeKey',
        ),
      );
    }
    await _writeExact(keyName(accountKey), base64Url.encode(key), 'writeKey');
  }

  Future<void> deleteKey(String accountKey) =>
      _deleteExact(keyName(accountKey), 'deleteKey');

  Future<ReadCacheStoreRead<ReadCachePendingClear>> readMarker(
    String accountKey,
  ) async {
    final raw = await _readRaw(markerName(accountKey), 'readMarker');
    return _decodeMarker(raw, 'readMarker');
  }

  Future<void> writeMarker(String accountKey, ReadCacheClearMarker marker) =>
      _writeExact(
        markerName(accountKey),
        jsonEncode(marker.toJson()),
        'writeMarker',
      );

  Future<void> deleteMarker(String accountKey) =>
      _deleteExact(markerName(accountKey), 'deleteMarker');

  /// Deletes one exact malformed inventory name. Only cache prefixes are
  /// accepted, and names that canonically decode to an account are refused.
  /// No path is constructed.
  Future<void> deleteInventoryName(String exactName) {
    final prefix = exactName.startsWith(keyPrefix)
        ? keyPrefix
        : exactName.startsWith(markerPrefix)
        ? markerPrefix
        : exactName.startsWith(offlineKeyPrefix)
        ? offlineKeyPrefix
        : exactName.startsWith(offlineMarkerPrefix)
        ? offlineMarkerPrefix
        : exactName.startsWith(offlineRefusalPrefix)
        ? offlineRefusalPrefix
        : null;
    if (prefix == null || _decodeCanonicalAccount(exactName, prefix) != null) {
      throw const ReadCacheStoreException(
        ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.invalidValue,
          'deleteInventoryName',
        ),
      );
    }
    return _deleteExact(exactName, 'deleteInventoryName');
  }

  Future<ReadCacheSecureInventory> readInventory() async {
    final Map<String, String> all;
    try {
      all = await _storage.readAll();
    } on Object {
      return const ReadCacheSecureInventory(
        status: ReadCacheStoreReadStatus.unavailable,
        failure: ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.unavailable,
          'readInventory',
        ),
      );
    }

    final keys = <String, ReadCacheStoreRead<Uint8List>>{};
    final markers = <String, ReadCacheStoreRead<ReadCachePendingClear>>{};
    final offlineKeys = <String, ReadCacheStoreRead<Uint8List>>{};
    final offlineMarkers = <String, ReadCacheStoreRead<String>>{};
    final offlineRefusals = <String, ReadCacheStoreRead<String>>{};
    final malformedNames = <String>{};
    final malformedValues = <String>{};
    for (final entry in all.entries) {
      final prefix = entry.key.startsWith(keyPrefix)
          ? keyPrefix
          : entry.key.startsWith(markerPrefix)
          ? markerPrefix
          : entry.key.startsWith(offlineKeyPrefix)
          ? offlineKeyPrefix
          : entry.key.startsWith(offlineMarkerPrefix)
          ? offlineMarkerPrefix
          : entry.key.startsWith(offlineRefusalPrefix)
          ? offlineRefusalPrefix
          : null;
      if (prefix == null) continue;
      final accountKey = _decodeCanonicalAccount(entry.key, prefix);
      if (accountKey == null) {
        malformedNames.add(entry.key);
        continue;
      }
      final raw = ReadCacheStoreRead<String>.found(entry.value);
      if (prefix == keyPrefix) {
        final decoded = _decodeKey(raw, 'readInventoryKey');
        keys[accountKey] = decoded;
        if (!decoded.isFound) malformedValues.add(entry.key);
      } else if (prefix == markerPrefix) {
        final decoded = _decodeMarker(raw, 'readInventoryMarker');
        markers[accountKey] = decoded;
        if (decoded.value is MalformedReadCacheClearMarker) {
          malformedValues.add(entry.key);
        }
      } else if (prefix == offlineKeyPrefix) {
        final decoded = _decodeKey(raw, 'readInventoryOfflineKey');
        offlineKeys[accountKey] = decoded;
        if (!decoded.isFound) malformedValues.add(entry.key);
      } else if (prefix == offlineMarkerPrefix) {
        offlineMarkers[accountKey] = raw;
      } else {
        offlineRefusals[accountKey] = raw;
      }
    }
    return ReadCacheSecureInventory(
      status: ReadCacheStoreReadStatus.found,
      keys: Map.unmodifiable(keys),
      markers: Map.unmodifiable(markers),
      offlineKeys: Map.unmodifiable(offlineKeys),
      offlineMarkers: Map.unmodifiable(offlineMarkers),
      offlineRefusals: Map.unmodifiable(offlineRefusals),
      malformedNames: Set.unmodifiable(malformedNames),
      malformedValues: Set.unmodifiable(malformedValues),
    );
  }

  Future<ReadCacheStoreRead<String>> _readRaw(
    String name,
    String operation,
  ) async {
    try {
      final value = await _storage.read(name);
      return value == null
          ? const ReadCacheStoreRead<String>.absent()
          : ReadCacheStoreRead<String>.found(value);
    } on Object {
      return ReadCacheStoreRead<String>.unavailable(
        ReadCacheStoreFailure(ReadCacheStoreFailureKind.unavailable, operation),
      );
    }
  }

  ReadCacheStoreRead<Uint8List> _decodeKey(
    ReadCacheStoreRead<String> raw,
    String operation,
  ) {
    if (raw.status == ReadCacheStoreReadStatus.absent) {
      return const ReadCacheStoreRead<Uint8List>.absent();
    }
    if (raw.status == ReadCacheStoreReadStatus.unavailable) {
      return ReadCacheStoreRead<Uint8List>.unavailable(raw.failure!);
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(raw.value!));
      if (bytes.length == 32 && base64Url.encode(bytes) == raw.value) {
        return ReadCacheStoreRead<Uint8List>.found(Uint8List.fromList(bytes));
      }
    } on Object {
      // Decoder exceptions may contain their input; do not retain them.
    }
    return ReadCacheStoreRead<Uint8List>.absent(
      ReadCacheStoreFailure(ReadCacheStoreFailureKind.malformed, operation),
    );
  }

  ReadCacheStoreRead<ReadCachePendingClear> _decodeMarker(
    ReadCacheStoreRead<String> raw,
    String operation,
  ) {
    if (raw.status == ReadCacheStoreReadStatus.absent) {
      return const ReadCacheStoreRead<ReadCachePendingClear>.absent();
    }
    if (raw.status == ReadCacheStoreReadStatus.unavailable) {
      return ReadCacheStoreRead<ReadCachePendingClear>.unavailable(
        raw.failure!,
      );
    }
    final encoded = raw.value!;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map<String, Object?> &&
          ((decoded.length == 4 && decoded['version'] == 1) ||
              (decoded.length == 5 &&
                  decoded['version'] == 2 &&
                  decoded['namespace'] == 'read_cache' &&
                  (decoded['reason'] == 'scopeInvalidation' ||
                      decoded['reason'] == 'keyRepair'))) &&
          decoded['version'] is int &&
          decoded['intentId'] is String &&
          decoded['reason'] is String &&
          decoded['requestedAt'] is String) {
        final reason = ReadCacheClearReason.values
            .where((value) => value.name == decoded['reason'])
            .firstOrNull;
        final requestedAtText = decoded['requestedAt']! as String;
        final requestedAt = DateTime.tryParse(requestedAtText);
        if (reason != null &&
            requestedAt != null &&
            requestedAt.isUtc &&
            requestedAt.toIso8601String() == requestedAtText) {
          return ReadCacheStoreRead<ReadCachePendingClear>.found(
            ReadCacheClearMarker(
              intentId: decoded['intentId']! as String,
              reason: reason,
              requestedAt: requestedAt,
              namespaceOnly: decoded['version'] == 2,
            ),
          );
        }
      }
    } on Object {
      // Parsing errors may contain content; do not retain them or their input.
    }
    return ReadCacheStoreRead<ReadCachePendingClear>.found(
      const MalformedReadCacheClearMarker._(),
    );
  }

  Future<void> _writeExact(String name, String value, String operation) async {
    final String? readback;
    try {
      await _storage.write(name, value);
      readback = await _storage.read(name);
    } on Object {
      throw ReadCacheStoreException(
        ReadCacheStoreFailure(ReadCacheStoreFailureKind.unavailable, operation),
      );
    }
    if (readback != value) {
      throw ReadCacheStoreException(
        ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.readbackMismatch,
          operation,
        ),
      );
    }
  }

  Future<void> _deleteExact(String name, String operation) async {
    final String? readback;
    try {
      await _storage.delete(name);
      readback = await _storage.read(name);
    } on Object {
      throw ReadCacheStoreException(
        ReadCacheStoreFailure(ReadCacheStoreFailureKind.unavailable, operation),
      );
    }
    if (readback != null) {
      throw ReadCacheStoreException(
        ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.readbackMismatch,
          operation,
        ),
      );
    }
  }

  static String? _decodeCanonicalAccount(String name, String prefix) {
    final encoded = name.substring(prefix.length);
    try {
      final account = utf8.decode(
        base64Url.decode(base64Url.normalize(encoded)),
      );
      if (account.isNotEmpty &&
          base64Url.encode(utf8.encode(account)) == encoded) {
        return account;
      }
    } on Object {
      // The exact malformed secure-storage name is retained by inventory.
    }
    return null;
  }
}
