import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'read_cache_disk_contract.dart';

const int readCacheEnvelopeOverhead = 29;
const int readCacheIndexLimit = 256 * 1024;
const int readCacheIndexEntriesLimit = 2048;

enum ReadCacheCodecError {
  malformed,
  unsupportedVersion,
  tooLarge,
  authenticationFailed,
  bindingMismatch,
}

/// A deliberately detail-free error for untrusted persistent bytes.
final class ReadCacheCodecException implements Exception {
  const ReadCacheCodecException(this.error);

  final ReadCacheCodecError error;

  @override
  String toString() => 'ReadCacheCodecException: ${error.name}';
}

final class ReadCacheIndex {
  ReadCacheIndex({required List<ReadCacheIndexEntry> entries})
    : entries = List.unmodifiable(entries);

  final List<ReadCacheIndexEntry> entries;
}

final class ReadCacheIndexEntry {
  ReadCacheIndexEntry({
    required this.fileName,
    required this.sizeBytes,
    required this.fetchedAt,
    required this.lastUsedAt,
    required this.cacheClass,
    required Set<String> scopeTags,
    required Set<ReadCacheIssueIdentity> issueIdentities,
  }) : scopeTags = Set.unmodifiable(scopeTags),
       issueIdentities = Set.unmodifiable(issueIdentities);

  final String fileName;
  final int sizeBytes;
  final DateTime fetchedAt, lastUsedAt;
  final ReadCacheDiskClass cacheClass;
  final Set<String> scopeTags;
  final Set<ReadCacheIssueIdentity> issueIdentities;
}

final class ReadCacheCipher {
  const ReadCacheCipher();

  static const _version = 1;
  static final _entryFilePattern = RegExp(r'^e_[0-9a-f]{32}\.v1\.bin$');

  static String accountDirectoryName(String accountKey) => crypto.sha256
      .convert(utf8.encode(accountKey))
      .toString()
      .substring(0, 32);

  Future<String> entryFileName(List<int> key, String canonicalKey) async {
    _checkKey(key);
    final namingKey = await DartHkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
          secretKey: SecretKey(key),
          info: utf8.encode('read-cache-names'),
        );
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(canonicalKey),
      secretKey: namingKey,
    );
    return 'e_${_hex(mac.bytes).substring(0, 32)}.v1.bin';
  }

  Future<Uint8List> encrypt({
    required List<int> key,
    required String accountKey,
    required String fileName,
    required List<int> plaintext,
    required int plaintextLimit,
  }) async {
    _checkKey(key);
    _checkLimit(plaintext.length, plaintextLimit);
    final random = Random.secure();
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => random.nextInt(256)),
    );
    try {
      final box = await DartAesGcm(secretKeyLength: 32).encrypt(
        plaintext,
        secretKey: SecretKey(key),
        nonce: nonce,
        aad: _aad(accountKey, fileName),
      );
      return Uint8List.fromList([_version, ...box.concatenation()]);
    } catch (_) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
  }

  Future<Uint8List> decrypt({
    required List<int> key,
    required String accountKey,
    required String fileName,
    required List<int> envelope,
    required int plaintextLimit,
  }) async {
    _checkKey(key);
    if (plaintextLimit < 0) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    if (envelope.length < readCacheEnvelopeOverhead) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    if (envelope.length > plaintextLimit + readCacheEnvelopeOverhead) {
      throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
    }
    if (envelope.first != _version) {
      throw const ReadCacheCodecException(
        ReadCacheCodecError.unsupportedVersion,
      );
    }
    try {
      final box = SecretBox.fromConcatenation(
        envelope.sublist(1),
        nonceLength: 12,
        macLength: 16,
      );
      final plaintext = await DartAesGcm(secretKeyLength: 32).decrypt(
        box,
        secretKey: SecretKey(key),
        aad: _aad(accountKey, fileName),
      );
      if (plaintext.length > plaintextLimit) {
        throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
      }
      return Uint8List.fromList(plaintext);
    } on ReadCacheCodecException {
      rethrow;
    } catch (_) {
      throw const ReadCacheCodecException(
        ReadCacheCodecError.authenticationFailed,
      );
    }
  }

  Uint8List encodeEntry(ProjectedDiskEntry entry) {
    try {
      final metadata = utf8.encode(jsonEncode(entry.metadata));
      final body = entry.bodyBytes;
      final length =
          readCacheMetadataLengthBytes + metadata.length + body.length;
      if (length > entry.plaintextLimit) {
        throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
      }
      final result = Uint8List(length);
      ByteData.sublistView(result).setUint32(0, metadata.length, Endian.big);
      result.setRange(4, 4 + metadata.length, metadata);
      result.setRange(4 + metadata.length, length, body);
      decodeEntry(
        result,
        accountKey: entry.accountKey,
        canonicalKey: entry.canonicalKey,
      );
      return result;
    } on ReadCacheCodecException {
      rethrow;
    } catch (_) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
  }

  ProjectedDiskEntry decodeEntry(
    List<int> plaintext, {
    required String accountKey,
    required String canonicalKey,
  }) {
    if (plaintext.length < readCacheMetadataLengthBytes ||
        plaintext.length > readCacheTerminalLogLimit) {
      throw ReadCacheCodecException(
        plaintext.length > readCacheTerminalLogLimit
            ? ReadCacheCodecError.tooLarge
            : ReadCacheCodecError.malformed,
      );
    }
    try {
      final bytes = Uint8List.fromList(plaintext);
      final metadataLength = ByteData.sublistView(
        bytes,
      ).getUint32(0, Endian.big);
      if (metadataLength == 0 || metadataLength > bytes.length - 4) {
        throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
      }
      final rawMetadata = jsonDecode(
        utf8.decode(bytes.sublist(4, 4 + metadataLength)),
      );
      final metadata = _object(rawMetadata);
      final bodyKind = _enumValue(
        ReadCacheBodyKind.values,
        metadata['bodyKind'],
      );
      final expectedKeys = <String>{
        'schema',
        'accountKey',
        'canonicalKey',
        'cacheClass',
        'bodyKind',
        'fetchedAt',
        'privacyEpoch',
        'scopeTags',
        'scopeVersions',
        'issueIdentities',
        if (bodyKind == ReadCacheBodyKind.terminalLog) 'terminalLog',
      };
      _exactKeys(metadata, expectedKeys);
      if (_integer(metadata['schema']) != readCacheDiskSchemaVersion) {
        throw const ReadCacheCodecException(
          ReadCacheCodecError.unsupportedVersion,
        );
      }
      if (_string(metadata['accountKey']) != accountKey ||
          _string(metadata['canonicalKey']) != canonicalKey) {
        throw const ReadCacheCodecException(
          ReadCacheCodecError.bindingMismatch,
        );
      }
      final limit = bodyKind == ReadCacheBodyKind.terminalLog
          ? readCacheTerminalLogLimit
          : readCacheEntryLimit;
      if (bytes.length > limit) {
        throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
      }
      final bodyBytes = bytes.sublist(4 + metadataLength);
      final body = _decodeBody(bodyKind, bodyBytes, metadata['terminalLog']);
      return ProjectedDiskEntry(
        accountKey: accountKey,
        canonicalKey: canonicalKey,
        cacheClass: _enumValue(
          ReadCacheDiskClass.values,
          metadata['cacheClass'],
        ),
        bodyKind: bodyKind,
        fetchedAt: _date(metadata['fetchedAt']),
        body: body,
        privacyEpoch: _nonNegativeInteger(metadata['privacyEpoch']),
        scopeTags: _stringSet(metadata['scopeTags']),
        scopeVersions: _versions(metadata['scopeVersions']),
        issueIdentities: _identities(metadata['issueIdentities']),
      );
    } on ReadCacheCodecException {
      rethrow;
    } catch (_) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
  }

  Uint8List encodeIndex(ReadCacheIndex index) {
    if (index.entries.length > readCacheIndexEntriesLimit) {
      throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
    }
    try {
      final value = <String, Object>{
        'schema': readCacheDiskSchemaVersion,
        'entries': [for (final entry in index.entries) _indexEntryJson(entry)],
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
      if (bytes.length > readCacheIndexLimit) {
        throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
      }
      // Encode and decode enforce the same schema. In particular, never emit
      // an index that a fresh store would reject after a restart.
      decodeIndex(bytes);
      return bytes;
    } on ReadCacheCodecException {
      rethrow;
    } catch (_) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
  }

  ReadCacheIndex decodeIndex(List<int> plaintext) {
    if (plaintext.length > readCacheIndexLimit) {
      throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
    }
    try {
      final root = _object(jsonDecode(utf8.decode(plaintext)));
      _exactKeys(root, const {'schema', 'entries'});
      if (_integer(root['schema']) != readCacheDiskSchemaVersion) {
        throw const ReadCacheCodecException(
          ReadCacheCodecError.unsupportedVersion,
        );
      }
      final rawEntries = _array(root['entries']);
      if (rawEntries.length > readCacheIndexEntriesLimit) {
        throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
      }
      final entries = <ReadCacheIndexEntry>[];
      final names = <String>{};
      for (final raw in rawEntries) {
        final entry = _decodeIndexEntry(raw);
        if (!names.add(entry.fileName)) {
          throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
        }
        entries.add(entry);
      }
      return ReadCacheIndex(entries: entries);
    } on ReadCacheCodecException {
      rethrow;
    } catch (_) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
  }

  static List<int> _aad(String accountKey, String fileName) =>
      utf8.encode(jsonEncode(['read_cache', _version, accountKey, fileName]));

  static void _checkKey(List<int> key) {
    if (key.length != 32 || key.any((byte) => byte < 0 || byte > 255)) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
  }

  static void _checkLimit(int length, int limit) {
    if (limit < 0) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    if (length > limit) {
      throw const ReadCacheCodecException(ReadCacheCodecError.tooLarge);
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Map<String, Object?> _indexEntryJson(ReadCacheIndexEntry entry) {
    if (!_entryFilePattern.hasMatch(entry.fileName) ||
        entry.sizeBytes < readCacheEnvelopeOverhead ||
        entry.sizeBytes >
            readCacheTerminalLogLimit + readCacheEnvelopeOverhead) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    final tags = entry.scopeTags.toList()..sort();
    final identities = entry.issueIdentities.toList()
      ..sort((a, b) {
        final project = a.projectId.compareTo(b.projectId);
        return project == 0 ? a.iid.compareTo(b.iid) : project;
      });
    return {
      'fileName': entry.fileName,
      'sizeBytes': entry.sizeBytes,
      'fetchedAt': entry.fetchedAt.toUtc().toIso8601String(),
      'lastUsedAt': entry.lastUsedAt.toUtc().toIso8601String(),
      'cacheClass': entry.cacheClass.name,
      'scopeTags': tags,
      'issueIdentities': [
        for (final identity in identities) [identity.projectId, identity.iid],
      ],
    };
  }

  static ReadCacheIndexEntry _decodeIndexEntry(Object? raw) {
    final value = _object(raw);
    _exactKeys(value, const {
      'fileName',
      'sizeBytes',
      'fetchedAt',
      'lastUsedAt',
      'cacheClass',
      'scopeTags',
      'issueIdentities',
    });
    final fileName = _string(value['fileName']);
    if (!_entryFilePattern.hasMatch(fileName)) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return ReadCacheIndexEntry(
      fileName: fileName,
      sizeBytes: _envelopeSize(value['sizeBytes']),
      fetchedAt: _date(value['fetchedAt']),
      lastUsedAt: _date(value['lastUsedAt']),
      cacheClass: _enumValue(ReadCacheDiskClass.values, value['cacheClass']),
      scopeTags: _stringSet(value['scopeTags']),
      issueIdentities: _identities(value['issueIdentities']),
    );
  }

  static Object _decodeBody(
    ReadCacheBodyKind kind,
    Uint8List bytes,
    Object? terminalMetadata,
  ) => switch (kind) {
    ReadCacheBodyKind.text => utf8.decode(bytes),
    ReadCacheBodyKind.json || ReadCacheBodyKind.page => _boundedJson(bytes),
    ReadCacheBodyKind.terminalLog => _terminalLog(bytes, terminalMetadata),
  };

  static Object _boundedJson(List<int> bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    var nodes = 0;
    void visit(Object? current, int depth) {
      if (++nodes > readCacheMaxValueNodes || depth > readCacheMaxDepth) {
        throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
      }
      if (current is List) {
        if (current.length > readCacheMaxArrayLength) {
          throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
        }
        for (final child in current) {
          visit(child, depth + 1);
        }
      } else if (current is Map) {
        if (current.keys.any((key) => key is! String)) {
          throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
        }
        for (final child in current.values) {
          visit(child, depth + 1);
        }
      } else if (current is! String &&
          current is! num &&
          current is! bool &&
          current != null) {
        throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
      }
    }

    visit(value, 1);
    return value as Object;
  }

  static ReadCacheTerminalLog _terminalLog(List<int> bytes, Object? raw) {
    final value = _object(raw);
    _exactKeys(value, const {
      'projectId',
      'jobId',
      'finishedAt',
      'startOffset',
      'nextOffset',
      'totalBytes',
      'isEof',
      'truncated',
    });
    final start = _nonNegativeInteger(value['startOffset']);
    final next = _nonNegativeInteger(value['nextOffset']);
    final total = _nonNegativeInteger(value['totalBytes']);
    final isEof = _boolean(value['isEof']);
    final truncated = _boolean(value['truncated']);
    if (next < start ||
        next - start != bytes.length ||
        next != total ||
        !isEof ||
        truncated != (start > 0)) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    // A tail starts at a complete UTF-8 code point; replacement decoding
    // would conceal a cut multibyte sequence or corrupt persistent bytes.
    utf8.decode(bytes);
    return ReadCacheTerminalLog(
      projectId: _positiveInteger(value['projectId']),
      jobId: _positiveInteger(value['jobId']),
      finishedAt: _date(value['finishedAt']),
      startOffset: start,
      nextOffset: next,
      totalBytes: total,
      isEof: isEof,
      truncated: truncated,
      bytes: bytes,
    );
  }

  static Map<String, int> _versions(Object? raw) {
    final value = _object(raw);
    if (value.length > readCacheMaxArrayLength) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    final result = <String, int>{};
    for (final entry in value.entries) {
      if (entry.key.isEmpty) {
        throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
      }
      result[entry.key] = _nonNegativeInteger(entry.value);
    }
    return result;
  }

  static Set<String> _stringSet(Object? raw) {
    final values = _array(raw);
    if (values.length > readCacheMaxArrayLength) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    final result = <String>{};
    for (final rawValue in values) {
      final value = _string(rawValue);
      if (value.isEmpty || !result.add(value)) {
        throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
      }
    }
    return result;
  }

  static Set<ReadCacheIssueIdentity> _identities(Object? raw) {
    final values = _array(raw);
    if (values.length > readCacheMaxArrayLength) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    final result = <ReadCacheIssueIdentity>{};
    for (final rawValue in values) {
      final pair = _array(rawValue);
      if (pair.length != 2 ||
          !result.add(
            ReadCacheIssueIdentity(
              _positiveInteger(pair[0]),
              _positiveInteger(pair[1]),
            ),
          )) {
        throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
      }
    }
    return result;
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return value;
  }

  static List<Object?> _array(Object? value) {
    if (value is! List<Object?>) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return value;
  }

  static void _exactKeys(Map<String, Object?> value, Set<String> keys) {
    if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
  }

  static String _string(Object? value) {
    if (value is! String) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return value;
  }

  static bool _boolean(Object? value) {
    if (value is! bool) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return value;
  }

  static int _integer(Object? value) {
    if (value is! int) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return value;
  }

  static int _nonNegativeInteger(Object? value) {
    final result = _integer(value);
    if (result < 0) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return result;
  }

  static int _positiveInteger(Object? value) {
    final result = _integer(value);
    if (result <= 0) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return result;
  }

  static int _envelopeSize(Object? value) {
    final result = _integer(value);
    if (result < readCacheEnvelopeOverhead ||
        result > readCacheTerminalLogLimit + readCacheEnvelopeOverhead) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return result;
  }

  static DateTime _date(Object? value) {
    final parsed = DateTime.tryParse(_string(value));
    if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != value) {
      throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
    }
    return parsed;
  }

  static T _enumValue<T extends Enum>(List<T> values, Object? raw) {
    final name = _string(raw);
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
  }
}
