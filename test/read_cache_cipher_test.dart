import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';

const _cipher = ReadCacheCipher();
final _key = List<int>.generate(32, (index) => index);

ProjectedDiskEntry _entry({
  String accountKey = 'https://example.invalid/gitlab|user:7',
  String canonicalKey = 'canonical-key',
  ReadCacheBodyKind bodyKind = ReadCacheBodyKind.json,
  Object body = const {'id': 3, 'name': 'synthetic'},
}) => ProjectedDiskEntry(
  accountKey: accountKey,
  canonicalKey: canonicalKey,
  cacheClass: ReadCacheDiskClass.detail,
  bodyKind: bodyKind,
  fetchedAt: DateTime.utc(2026, 10, 23, 1, 2, 3),
  body: body,
  privacyEpoch: 4,
  issueIdentities: {const ReadCacheIssueIdentity(3, 9)},
  scopeVersions: const {'project:3': 2},
  scopeTags: const {'issue:3:9', 'project:3'},
);

Matcher _codecError(ReadCacheCodecError error) => throwsA(
  isA<ReadCacheCodecException>().having((value) => value.error, 'error', error),
);

void main() {
  group('names', () {
    test('account directory is the first 32 lowercase SHA-256 hex digits', () {
      expect(
        ReadCacheCipher.accountDirectoryName('synthetic-account'),
        '50a5ee17cb005388e7f31e1ed28043dd',
      );
      expect(
        ReadCacheCipher.accountDirectoryName('synthetic-account'),
        matches(RegExp(r'^[0-9a-f]{32}$')),
      );
    });

    test(
      'entry name is deterministic, key-bound, and canonical-key-bound',
      () async {
        final first = await _cipher.entryFileName(_key, 'canonical-a');
        expect(first, 'e_4af99fb95561c5f28f4328df878f51ca.v1.bin');
        expect(first, matches(RegExp(r'^e_[0-9a-f]{32}\.v1\.bin$')));
        expect(await _cipher.entryFileName(_key, 'canonical-a'), first);
        expect(await _cipher.entryFileName(_key, 'canonical-b'), isNot(first));
        expect(
          await _cipher.entryFileName(List<int>.filled(32, 7), 'canonical-a'),
          isNot(first),
        );
      },
    );
  });

  group('AES-256-GCM envelope', () {
    test('uses 1 + 12 + plaintext + 16 bytes and a fresh nonce', () async {
      final first = await _cipher.encrypt(
        key: _key,
        accountKey: 'account',
        fileName: 'index.v1.bin',
        plaintext: const [1, 2, 3],
        plaintextLimit: 3,
      );
      final second = await _cipher.encrypt(
        key: _key,
        accountKey: 'account',
        fileName: 'index.v1.bin',
        plaintext: const [1, 2, 3],
        plaintextLimit: 3,
      );
      expect(readCacheEnvelopeOverhead, 29);
      expect(first.length, 32);
      expect(first.first, 1);
      expect(first.sublist(1, 13), isNot(second.sublist(1, 13)));
      expect(
        await _cipher.decrypt(
          key: _key,
          accountKey: 'account',
          fileName: 'index.v1.bin',
          envelope: first,
          plaintextLimit: 3,
        ),
        [1, 2, 3],
      );
    });

    test('AAD binds exact domain, version, account, and file name', () async {
      final encrypted = await _cipher.encrypt(
        key: _key,
        accountKey: 'account-a',
        fileName: 'entry-a',
        plaintext: const [8],
        plaintextLimit: 1,
      );
      for (final binding in [
        ('account-b', 'entry-a'),
        ('account-a', 'entry-b'),
      ]) {
        expect(
          () => _cipher.decrypt(
            key: _key,
            accountKey: binding.$1,
            fileName: binding.$2,
            envelope: encrypted,
            plaintextLimit: 1,
          ),
          _codecError(ReadCacheCodecError.authenticationFailed),
        );
      }
      expect(
        () => _cipher.decrypt(
          key: List<int>.filled(32, 9),
          accountKey: 'account-a',
          fileName: 'entry-a',
          envelope: encrypted,
          plaintextLimit: 1,
        ),
        _codecError(ReadCacheCodecError.authenticationFailed),
      );

      final aiStyle = await DartAesGcm(secretKeyLength: 32).encrypt(
        const [8],
        secretKey: SecretKey(_key),
        nonce: List<int>.filled(12, 1),
        aad: utf8.encode(jsonEncode([1, 'account-a', 'entry-a'])),
      );
      expect(
        () => _cipher.decrypt(
          key: _key,
          accountKey: 'account-a',
          fileName: 'entry-a',
          envelope: [1, ...aiStyle.concatenation()],
          plaintextLimit: 1,
        ),
        _codecError(ReadCacheCodecError.authenticationFailed),
      );
    });

    test('matches the exact AAD bytes in both directions', () async {
      const account = 'synthetic-世界';
      const file = 'index.v1.bin';
      final aad = utf8.encode(jsonEncode(['read_cache', 1, account, file]));
      final external = await DartAesGcm(secretKeyLength: 32).encrypt(
        const [7, 8],
        secretKey: SecretKey(_key),
        nonce: List<int>.filled(12, 2),
        aad: aad,
      );
      expect(
        await _cipher.decrypt(
          key: _key,
          accountKey: account,
          fileName: file,
          envelope: [1, ...external.concatenation()],
          plaintextLimit: 2,
        ),
        [7, 8],
      );
      final encoded = await _cipher.encrypt(
        key: _key,
        accountKey: account,
        fileName: file,
        plaintext: const [7, 8],
        plaintextLimit: 2,
      );
      expect(
        await DartAesGcm(secretKeyLength: 32).decrypt(
          SecretBox.fromConcatenation(
            encoded.sublist(1),
            nonceLength: 12,
            macLength: 16,
          ),
          secretKey: SecretKey(_key),
          aad: aad,
        ),
        [7, 8],
      );
      for (final foreignAad in [
        [1, account, file],
        ['ai_history', 1, account, file],
        ['read_cache', 2, account, file],
      ]) {
        final box = await DartAesGcm(secretKeyLength: 32).encrypt(
          const [7, 8],
          secretKey: SecretKey(_key),
          nonce: List<int>.filled(12, 3),
          aad: utf8.encode(jsonEncode(foreignAad)),
        );
        await expectLater(
          _cipher.decrypt(
            key: _key,
            accountKey: account,
            fileName: file,
            envelope: [1, ...box.concatenation()],
            plaintextLimit: 2,
          ),
          _codecError(ReadCacheCodecError.authenticationFailed),
        );
      }
      await expectLater(
        DartAesGcm(secretKeyLength: 32).decrypt(
          SecretBox.fromConcatenation(
            encoded.sublist(1),
            nonceLength: 12,
            macLength: 16,
          ),
          secretKey: SecretKey(_key),
          aad: utf8.encode(jsonEncode([1, account, file])),
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test(
      'accepts an empty 29-byte envelope and rejects invalid keys',
      () async {
        final encoded = await _cipher.encrypt(
          key: _key,
          accountKey: 'account',
          fileName: 'index.v1.bin',
          plaintext: const [],
          plaintextLimit: 0,
        );
        expect(encoded, hasLength(29));
        expect(
          await _cipher.decrypt(
            key: _key,
            accountKey: 'account',
            fileName: 'index.v1.bin',
            envelope: encoded,
            plaintextLimit: 0,
          ),
          isEmpty,
        );
        for (final key in [
          <int>[],
          List<int>.filled(31, 0),
          List<int>.filled(33, 0),
          [..._key.take(31), -1],
          [..._key.take(31), 256],
        ]) {
          await expectLater(
            _cipher.encrypt(
              key: key,
              accountKey: 'account',
              fileName: 'index.v1.bin',
              plaintext: const [],
              plaintextLimit: 0,
            ),
            _codecError(ReadCacheCodecError.malformed),
          );
        }
      },
    );

    test('rejects tamper, truncation, unknown version, and oversize', () async {
      final encrypted = await _cipher.encrypt(
        key: _key,
        accountKey: 'account',
        fileName: 'entry',
        plaintext: const [1, 2],
        plaintextLimit: 2,
      );
      final tampered = Uint8List.fromList(encrypted)..[15] ^= 1;
      expect(
        () => _cipher.decrypt(
          key: _key,
          accountKey: 'account',
          fileName: 'entry',
          envelope: tampered,
          plaintextLimit: 2,
        ),
        _codecError(ReadCacheCodecError.authenticationFailed),
      );
      expect(
        () => _cipher.decrypt(
          key: _key,
          accountKey: 'account',
          fileName: 'entry',
          envelope: encrypted.sublist(0, 28),
          plaintextLimit: 2,
        ),
        _codecError(ReadCacheCodecError.malformed),
      );
      final unknown = Uint8List.fromList(encrypted)..[0] = 2;
      expect(
        () => _cipher.decrypt(
          key: _key,
          accountKey: 'account',
          fileName: 'entry',
          envelope: unknown,
          plaintextLimit: 2,
        ),
        _codecError(ReadCacheCodecError.unsupportedVersion),
      );
      expect(
        () => _cipher.decrypt(
          key: _key,
          accountKey: 'account',
          fileName: 'entry',
          envelope: encrypted,
          plaintextLimit: 1,
        ),
        _codecError(ReadCacheCodecError.tooLarge),
      );
      expect(
        () => _cipher.encrypt(
          key: _key,
          accountKey: 'account',
          fileName: 'entry',
          plaintext: const [1, 2],
          plaintextLimit: 1,
        ),
        _codecError(ReadCacheCodecError.tooLarge),
      );
    });
  });

  group('entry codec', () {
    test('round trips every body shape and exact bindings', () {
      final entries = <ProjectedDiskEntry>[
        _entry(),
        _entry(bodyKind: ReadCacheBodyKind.page, body: const [1, 2, 3]),
        _entry(bodyKind: ReadCacheBodyKind.text, body: 'hello 世界'),
        _entry(
          bodyKind: ReadCacheBodyKind.terminalLog,
          body: ReadCacheTerminalLog(
            projectId: 3,
            jobId: 5,
            finishedAt: DateTime.utc(2026, 10, 23),
            startOffset: 4,
            nextOffset: 7,
            totalBytes: 7,
            isEof: true,
            truncated: true,
            bytes: const [1, 2, 3],
          ),
        ),
      ];
      for (final entry in entries) {
        final encoded = _cipher.encodeEntry(entry);
        expect(
          ByteData.sublistView(encoded).getUint32(0, Endian.big),
          greaterThan(0),
        );
        final decoded = _cipher.decodeEntry(
          encoded,
          accountKey: entry.accountKey,
          canonicalKey: entry.canonicalKey,
        );
        expect(decoded.metadata, entry.metadata);
        expect(decoded.bodyBytes, entry.bodyBytes);
      }
    });

    test('requires exact canonical key and account key', () {
      final encoded = _cipher.encodeEntry(_entry());
      expect(
        () => _cipher.decodeEntry(
          encoded,
          accountKey: 'other-account',
          canonicalKey: 'canonical-key',
        ),
        _codecError(ReadCacheCodecError.bindingMismatch),
      );
      expect(
        () => _cipher.decodeEntry(
          encoded,
          accountKey: 'https://example.invalid/gitlab|user:7',
          canonicalKey: 'canonical-key/',
        ),
        _codecError(ReadCacheCodecError.bindingMismatch),
      );
    });

    test(
      'rejects schema changes, unknown fields, malformed framing and body',
      () {
        final entry = _entry();
        final metadata = {...entry.metadata, 'schema': 2};
        expect(
          () => _cipher.decodeEntry(
            _frame(metadata, entry.bodyBytes),
            accountKey: entry.accountKey,
            canonicalKey: entry.canonicalKey,
          ),
          _codecError(ReadCacheCodecError.unsupportedVersion),
        );
        expect(
          () => _cipher.decodeEntry(
            _frame({...entry.metadata, 'extra': true}, entry.bodyBytes),
            accountKey: entry.accountKey,
            canonicalKey: entry.canonicalKey,
          ),
          _codecError(ReadCacheCodecError.malformed),
        );
        expect(
          () => _cipher.decodeEntry(
            const [0, 0, 0, 9, 1],
            accountKey: entry.accountKey,
            canonicalKey: entry.canonicalKey,
          ),
          _codecError(ReadCacheCodecError.malformed),
        );
        expect(
          () => _cipher.decodeEntry(
            _frame(entry.metadata, utf8.encode('{')),
            accountKey: entry.accountKey,
            canonicalKey: entry.canonicalKey,
          ),
          _codecError(ReadCacheCodecError.malformed),
        );
      },
    );

    test('enforces total size and bounded JSON structure', () {
      final text = _entry(bodyKind: ReadCacheBodyKind.text, body: '');
      final metadataBytes = utf8.encode(jsonEncode(text.metadata)).length;
      final exact = _entry(
        bodyKind: ReadCacheBodyKind.text,
        body: 'a' * (readCacheEntryLimit - 4 - metadataBytes),
      );
      expect(_cipher.encodeEntry(exact).length, readCacheEntryLimit);
      expect(
        () => _cipher.encodeEntry(
          _entry(
            bodyKind: ReadCacheBodyKind.text,
            body: 'a' * (readCacheEntryLimit - 3 - metadataBytes),
          ),
        ),
        _codecError(ReadCacheCodecError.tooLarge),
      );

      Object deep = 0;
      for (var i = 0; i <= readCacheMaxDepth; i++) {
        deep = [deep];
      }
      expect(
        () => _cipher.encodeEntry(_entry(body: deep)),
        _codecError(ReadCacheCodecError.malformed),
      );
      expect(
        () => _cipher.encodeEntry(
          _entry(body: List<int>.filled(readCacheMaxArrayLength + 1, 0)),
        ),
        _codecError(ReadCacheCodecError.malformed),
      );
    });
  });

  group('terminal and entry validation', () {
    test('terminal budget includes metadata and preserves UTF-8 tail', () {
      for (final canonicalKey in ['key', 'a' * 1000]) {
        final empty = _terminalEntry(canonicalKey: canonicalKey);
        final overhead = empty.serializedLength;
        var length = readCacheTerminalLogLimit - overhead;
        // Offset digit counts are part of the metadata budget.
        while (true) {
          final candidate = _terminalEntry(
            canonicalKey: canonicalKey,
            bytes: List<int>.filled(length, 0x61),
          );
          final excess = candidate.serializedLength - readCacheTerminalLogLimit;
          if (excess == 0) {
            final encoded = _cipher.encodeEntry(candidate);
            expect(encoded, hasLength(readCacheTerminalLogLimit));
            expect(
              _cipher
                  .decodeEntry(
                    encoded,
                    accountKey: candidate.accountKey,
                    canonicalKey: candidate.canonicalKey,
                  )
                  .bodyBytes,
              candidate.bodyBytes,
            );
            expect(
              () => _cipher.encodeEntry(
                _terminalEntry(
                  canonicalKey: canonicalKey,
                  bytes: List<int>.filled(length + 1, 0x61),
                ),
              ),
              _codecError(ReadCacheCodecError.tooLarge),
            );
            break;
          }
          length -= excess;
        }
      }
      final valid = _terminalEntry(bytes: utf8.encode('世界'));
      expect(_cipher.encodeEntry(valid).length, valid.serializedLength);
      for (final bytes in [
        <int>[0x80],
        <int>[0xe4, 0xb8],
      ]) {
        expect(
          () => _cipher.encodeEntry(_terminalEntry(bytes: bytes)),
          _codecError(ReadCacheCodecError.malformed),
        );
      }
    });

    test('terminal schema rejects inconsistent offsets and flags', () {
      final entry = _terminalEntry(bytes: const [0x61]);
      final terminal = (entry.body as ReadCacheTerminalLog).metadata;
      for (final replacement in [
        {'startOffset': -1},
        {'nextOffset': 2},
        {'totalBytes': 2},
        {'isEof': false},
        {'truncated': true},
        {'jobId': 0},
        {'finishedAt': '2026-02-31T00:00:00.000Z'},
      ]) {
        expect(
          () => _cipher.decodeEntry(
            _frame({
              ...entry.metadata,
              'terminalLog': {...terminal, ...replacement},
            }, entry.bodyBytes),
            accountKey: entry.accountKey,
            canonicalKey: entry.canonicalKey,
          ),
          _codecError(ReadCacheCodecError.malformed),
        );
      }
    });

    test('decode rejects non-terminal buffers above their own 1MiB cap', () {
      final entry = _entry(bodyKind: ReadCacheBodyKind.text, body: '');
      final encoded = _frame(
        entry.metadata,
        List<int>.filled(readCacheEntryLimit, 0x61),
      );
      expect(
        () => _cipher.decodeEntry(
          encoded,
          accountKey: entry.accountKey,
          canonicalKey: entry.canonicalKey,
        ),
        _codecError(ReadCacheCodecError.tooLarge),
      );
    });
  });

  group('index codec', () {
    test('round trips immutable closed-schema entries', () {
      final index = ReadCacheIndex(entries: [_indexEntry()]);
      final decoded = _cipher.decodeIndex(_cipher.encodeIndex(index));
      expect(decoded.entries, hasLength(1));
      final entry = decoded.entries.single;
      expect(entry.fileName, _indexEntry().fileName);
      expect(entry.sizeBytes, 99);
      expect(entry.cacheClass, ReadCacheDiskClass.thread);
      expect(entry.scopeTags, {'project:3'});
      expect(entry.issueIdentities, {const ReadCacheIssueIdentity(3, 9)});
      expect(() => decoded.entries.add(_indexEntry()), throwsUnsupportedError);
      expect(() => entry.scopeTags.add('x'), throwsUnsupportedError);
    });

    test('enforces 2048 entries and 256 KiB independently', () {
      expect(readCacheIndexLimit, 256 * 1024);
      expect(readCacheIndexEntriesLimit, 2048);
      expect(
        () => _cipher.encodeIndex(
          ReadCacheIndex(
            entries: List<ReadCacheIndexEntry>.generate(
              readCacheIndexEntriesLimit + 1,
              (_) => _indexEntry(),
            ),
          ),
        ),
        _codecError(ReadCacheCodecError.tooLarge),
      );
      final minimal = utf8.encode(
        jsonEncode({
          'schema': readCacheDiskSchemaVersion,
          'entries': <Object?>[],
        }),
      );
      final exact = [
        ...minimal,
        ...List<int>.filled(readCacheIndexLimit - minimal.length, 0x20),
      ];
      expect(_cipher.decodeIndex(exact).entries, isEmpty);
      expect(
        () => _cipher.decodeIndex([...exact, 0x20]),
        _codecError(ReadCacheCodecError.tooLarge),
      );
    });

    test('isolates the 2048/2049 count guard from the byte limit', () {
      // Valid verbose records hit 256KiB before 2048. Compact malformed
      // records isolate count validation: 2048 reaches schema validation,
      // whereas 2049 must fail the earlier count guard.
      for (final count in [2048, 2049]) {
        final encoded = utf8.encode(
          jsonEncode({
            'schema': readCacheDiskSchemaVersion,
            'entries': List<Object?>.filled(count, null),
          }),
        );
        expect(encoded.length, lessThan(readCacheIndexLimit));
        expect(
          () => _cipher.decodeIndex(encoded),
          _codecError(
            count == 2048
                ? ReadCacheCodecError.malformed
                : ReadCacheCodecError.tooLarge,
          ),
        );
      }
    });

    test('encode enforces exact 256KiB and +1 bytes', () {
      ReadCacheIndex indexWithTag(String tag) => ReadCacheIndex(
        entries: [
          ReadCacheIndexEntry(
            fileName: _indexEntry().fileName,
            sizeBytes: 99,
            fetchedAt: DateTime.utc(2026),
            lastUsedAt: DateTime.utc(2026),
            cacheClass: ReadCacheDiskClass.detail,
            scopeTags: {tag},
            issueIdentities: {},
          ),
        ],
      );
      final base = _cipher.encodeIndex(indexWithTag('x')).length;
      final tag = 'a' * (readCacheIndexLimit - base + 1);
      final encoded = _cipher.encodeIndex(indexWithTag(tag));
      expect(encoded, hasLength(readCacheIndexLimit));
      expect(_cipher.decodeIndex(encoded).entries.single.scopeTags, {tag});
      expect(
        () => _cipher.encodeIndex(indexWithTag('${tag}a')),
        _codecError(ReadCacheCodecError.tooLarge),
      );
    });

    test('rejects duplicate references and encode/decode schema asymmetry', () {
      expect(
        () => _cipher.encodeIndex(
          ReadCacheIndex(entries: [_indexEntry(), _indexEntry()]),
        ),
        _codecError(ReadCacheCodecError.malformed),
      );
      final invalid = ReadCacheIndexEntry(
        fileName: _indexEntry().fileName,
        sizeBytes: 99,
        fetchedAt: DateTime.utc(2026),
        lastUsedAt: DateTime.utc(2026),
        cacheClass: ReadCacheDiskClass.detail,
        scopeTags: {''},
        issueIdentities: {},
      );
      expect(
        () => _cipher.encodeIndex(ReadCacheIndex(entries: [invalid])),
        _codecError(ReadCacheCodecError.malformed),
      );
    });

    test('rejects unknown schema, fields, unsafe names and sizes', () {
      expect(
        () => _cipher.decodeIndex(
          utf8.encode(jsonEncode({'schema': 2, 'entries': <Object?>[]})),
        ),
        _codecError(ReadCacheCodecError.unsupportedVersion),
      );
      expect(
        () => _cipher.decodeIndex(
          utf8.encode(
            jsonEncode({'schema': 1, 'entries': <Object?>[], 'extra': 1}),
          ),
        ),
        _codecError(ReadCacheCodecError.malformed),
      );
      for (final bad in [
        ReadCacheIndexEntry(
          fileName: '../entry',
          sizeBytes: 99,
          fetchedAt: DateTime.utc(2026),
          lastUsedAt: DateTime.utc(2026),
          cacheClass: ReadCacheDiskClass.detail,
          scopeTags: const {},
          issueIdentities: const {},
        ),
        ReadCacheIndexEntry(
          fileName: _indexEntry().fileName,
          sizeBytes: readCacheEnvelopeOverhead - 1,
          fetchedAt: DateTime.utc(2026),
          lastUsedAt: DateTime.utc(2026),
          cacheClass: ReadCacheDiskClass.detail,
          scopeTags: const {},
          issueIdentities: const {},
        ),
      ]) {
        expect(
          () => _cipher.encodeIndex(ReadCacheIndex(entries: [bad])),
          _codecError(ReadCacheCodecError.malformed),
        );
      }
    });
  });

  test('errors are typed and never retain untrusted values', () {
    const secret = 'synthetic-private-value';
    try {
      _cipher.decodeIndex(utf8.encode(secret));
      fail('decode should fail');
    } on ReadCacheCodecException catch (error) {
      expect(error.toString(), isNot(contains(secret)));
      expect(error.toString(), 'ReadCacheCodecException: malformed');
    }
  });
}

ReadCacheIndexEntry _indexEntry() => ReadCacheIndexEntry(
  fileName: 'e_${'a' * 32}.v1.bin',
  sizeBytes: 99,
  fetchedAt: DateTime.utc(2026, 10, 23),
  lastUsedAt: DateTime.utc(2026, 10, 23, 1),
  cacheClass: ReadCacheDiskClass.thread,
  scopeTags: const {'project:3'},
  issueIdentities: {const ReadCacheIssueIdentity(3, 9)},
);

Uint8List _frame(Map<String, Object> metadata, List<int> body) {
  final metadataBytes = utf8.encode(jsonEncode(metadata));
  final result = Uint8List(4 + metadataBytes.length + body.length);
  ByteData.sublistView(result).setUint32(0, metadataBytes.length, Endian.big);
  result.setRange(4, 4 + metadataBytes.length, metadataBytes);
  result.setRange(4 + metadataBytes.length, result.length, body);
  return result;
}

ProjectedDiskEntry _terminalEntry({
  String canonicalKey = 'terminal-key',
  List<int> bytes = const [],
}) => _entry(
  canonicalKey: canonicalKey,
  bodyKind: ReadCacheBodyKind.terminalLog,
  body: ReadCacheTerminalLog(
    projectId: 3,
    jobId: 5,
    finishedAt: DateTime.utc(2026, 10, 23),
    startOffset: 0,
    nextOffset: bytes.length,
    totalBytes: bytes.length,
    isEof: true,
    truncated: false,
    bytes: bytes,
  ),
);
