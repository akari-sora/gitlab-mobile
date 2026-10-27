import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';

const _account = 'https://synthetic.example.test/subpath#17';
const _otherAccount = 'https://synthetic.example.test/subpath#18';
final _key = List<int>.generate(32, (index) => index);
final _now = DateTime.utc(2026, 10, 23, 12);

final class _Crash implements Exception {
  const _Crash();
}

ProjectedDiskEntry _entry({
  int id = 1,
  DateTime? fetchedAt,
  String account = _account,
  String? body,
}) => ProjectedDiskEntry(
  accountKey: account,
  canonicalKey: jsonEncode([
    account,
    'GET',
    '/api/v4/projects/$id',
    <Object?>[],
    'application/json',
  ]),
  cacheClass: ReadCacheDiskClass.projectMeta,
  bodyKind: ReadCacheBodyKind.json,
  fetchedAt: fetchedAt ?? _now,
  body: {'id': id, 'name': body ?? 'Synthetic project $id'},
  privacyEpoch: 0,
  issueIdentities: {},
  scopeTags: {'project:$id'},
  scopeVersions: {'project:$id': 0},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  ReadCacheFileStore store({
    DateTime? now,
    void Function(ReadCacheFileCheckpoint)? checkpoint,
  }) => ReadCacheFileStore(
    root: () async => root,
    clock: () => now ?? _now,
    checkpoint: checkpoint,
  );

  Directory accountDirectory([String account = _account]) => Directory(
    '${root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(account)}',
  );

  Future<ReadCacheIndexEntry> indexEntry(
    String name, {
    String account = _account,
  }) async => ReadCacheIndexEntry(
    fileName: name,
    sizeBytes: File('${accountDirectory(account).path}/$name').lengthSync(),
    fetchedAt: _now,
    lastUsedAt: _now,
    cacheClass: ReadCacheDiskClass.projectMeta,
    scopeTags: const {'project:1'},
    issueIdentities: const {},
  );

  Matcher fileFailure(ReadCacheFileFailure code) => throwsA(
    isA<ReadCacheFileException>().having((error) => error.code, 'code', code),
  );

  Matcher codecFailure(ReadCacheCodecError code) => throwsA(
    isA<ReadCacheCodecException>().having(
      (error) => error.error,
      'error',
      code,
    ),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('read_cache_files_');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'construction, missing reads and scans do not create directories',
    () async {
      final files = store();
      expect(root.listSync(), isEmpty);
      expect(
        await files.readEntry(_account, _key, _entry().canonicalKey),
        isNull,
      );
      expect(await files.readIndex(_account, _key), isNull);
      expect(await files.entryFiles(_account, _key), isEmpty);
      expect(await files.removeStaleTemporaryFiles(_account, _key), 0);
      expect(await files.accountDirectoryNames(), isEmpty);
      expect(
        await files.accountDirectoryState(_account),
        ReadCacheDirectoryState.absent,
      );
      await files.clearAccountDirectoriesExcept({});
      expect(root.listSync(), isEmpty);
    },
  );

  test('entry then encrypted index survive a completely new store', () async {
    final value = _entry();
    final name = await store().writeEntry(value, _key);
    expect(name, matches(RegExp(r'^e_[0-9a-f]{32}\.v1\.bin$')));
    final file = File('${accountDirectory().path}/$name');
    expect(
      file.lengthSync(),
      value.serializedLength + readCacheEnvelopeOverhead,
    );
    expect(
      file.readAsBytesSync(),
      isNot(containsAllInOrder(utf8.encode('Synthetic project'))),
    );
    final record = await indexEntry(name);
    await store().writeIndex(_account, _key, ReadCacheIndex(entries: [record]));
    final fresh = store();
    final actual = await fresh.readEntry(_account, _key, value.canonicalKey);
    expect(actual!.body, value.body);
    expect(actual.fetchedAt, value.fetchedAt);
    expect(await fresh.entryFiles(_account, _key), [name]);
    expect((await fresh.readEntryFile(_account, _key, name))!.body, value.body);
    expect(
      (await fresh.readIndex(_account, _key))!.entries.single.fileName,
      name,
    );
    final usage = await fresh.usage(_account, _key);
    expect(
      usage.accountBytes,
      accountDirectory().listSync().cast<File>().fold<int>(
        0,
        (sum, file) => sum + file.lengthSync(),
      ),
    );
    expect(usage.deviceBytes, usage.accountBytes);
  });

  test('index never publishes a phantom file or an incorrect size', () async {
    final name = await store().writeEntry(_entry(), _key);
    final record = await indexEntry(name);
    await store().clearAccount(_account);
    await expectLater(
      store().writeIndex(_account, _key, ReadCacheIndex(entries: [record])),
      fileFailure(ReadCacheFileFailure.io),
    );
    expect(await store().readIndex(_account, _key), isNull);
    await store().writeEntry(_entry(body: 'different serialized length'), _key);
    await expectLater(
      store().writeIndex(_account, _key, ReadCacheIndex(entries: [record])),
      fileFailure(ReadCacheFileFailure.io),
    );
  });

  for (final change in ['remove', 'resize']) {
    test('index rechecks $change at the final rename boundary', () async {
      final first = await store().writeEntry(_entry(), _key);
      final firstRecord = await indexEntry(first);
      await store().writeIndex(
        _account,
        _key,
        ReadCacheIndex(entries: [firstRecord]),
      );
      final indexFile = File('${accountDirectory().path}/index.v1.bin');
      final oldIndex = indexFile.readAsBytesSync();
      final second = await store().writeEntry(_entry(id: 2), _key);
      final secondRecord = await indexEntry(second);
      final secondPath = '${accountDirectory().path}/$second';
      final changing = store(
        checkpoint: (step) {
          if (step != ReadCacheFileCheckpoint.beforeIndexRename) return;
          final file = File(secondPath);
          if (change == 'remove') {
            file.deleteSync();
          } else {
            file.writeAsBytesSync([1]);
          }
        },
      );
      await expectLater(
        changing.writeIndex(
          _account,
          _key,
          ReadCacheIndex(entries: [firstRecord, secondRecord]),
        ),
        fileFailure(ReadCacheFileFailure.io),
      );
      expect(indexFile.readAsBytesSync(), oldIndex);
      expect(
        accountDirectory().listSync().where(
          (file) => file.path.endsWith('.tmp'),
        ),
        isEmpty,
        reason: 'beforeRename rejection must remove its temporary file',
      );
      expect(
        (await store().readIndex(_account, _key))!.entries.single.fileName,
        first,
      );
    });
  }

  test(
    'root-provider native failures are sanitized for reads and explicit clear',
    () async {
      for (final error in <Object>[
        const FileSystemException(
          'synthetic private detail',
          '/synthetic/private',
        ),
        StateError('synthetic native detail'),
        Exception('synthetic plugin detail'),
      ]) {
        final files = ReadCacheFileStore(root: () async => throw error);
        await expectLater(
          files.readIndex(_account, _key),
          fileFailure(ReadCacheFileFailure.io),
        );
        await expectLater(
          files.clearAccount(_account),
          fileFailure(ReadCacheFileFailure.io),
        );
        await expectLater(
          files.clearRoot(),
          fileFailure(ReadCacheFileFailure.io),
        );
      }
      expect(root.listSync(), isEmpty);
    },
  );

  test('transaction checkpoints execute outside the caller isolate', () async {
    final caller = Isolate.current.controlPort;
    final background = store(
      checkpoint: (step) {
        if (Isolate.current.controlPort == caller) throw const _Crash();
      },
    );
    final name = await background.writeEntry(_entry(), _key);
    expect(await background.readEntryFile(_account, _key, name), isNotNull);
    await background.writeIndex(
      _account,
      _key,
      ReadCacheIndex(entries: [await indexEntry(name)]),
    );
    await background.evict(_account, _key, name);
    expect((await background.readIndex(_account, _key))!.entries, isEmpty);
  });

  test(
    'background errors outside the typed exceptions are sanitized',
    () async {
      final name = await store().writeEntry(_entry(), _key);
      for (final error in <Object>[
        StateError('synthetic private background detail'),
        Exception('synthetic plugin detail'),
        const FileSystemException(
          'synthetic private detail',
          '/synthetic/private',
        ),
      ]) {
        final files = store(
          checkpoint: (step) {
            if (step == ReadCacheFileCheckpoint.beforeRead) throw error;
          },
        );
        await expectLater(
          files.readEntryFile(_account, _key, name),
          fileFailure(ReadCacheFileFailure.io),
        );
      }
    },
  );

  test(
    'wrong account/key/file and altered ciphertext cannot be read',
    () async {
      final value = _entry();
      final name = await store().writeEntry(value, _key);
      final original = File('${accountDirectory().path}/$name');
      accountDirectory(_otherAccount).createSync(recursive: true);
      original.copySync('${accountDirectory(_otherAccount).path}/$name');
      final authenticationFailure = throwsA(
        isA<ReadCacheCodecException>().having(
          (error) => error.error,
          'error',
          ReadCacheCodecError.authenticationFailed,
        ),
      );
      await expectLater(
        store().readEntryFile(_otherAccount, _key, name),
        authenticationFailure,
      );
      await expectLater(
        store().readEntryFile(_account, List<int>.filled(32, 7), name),
        authenticationFailure,
      );
      final renamed = 'e_${'a' * 32}.v1.bin';
      original.copySync('${accountDirectory().path}/$renamed');
      await expectLater(
        store().readEntryFile(_account, _key, renamed),
        authenticationFailure,
      );
      final bytes = original.readAsBytesSync()..[20] ^= 1;
      original.writeAsBytesSync(bytes);
      await expectLater(
        store().readEntry(_account, _key, value.canonicalKey),
        authenticationFailure,
      );
    },
  );

  test('file reads reject truncated and unknown envelope versions', () async {
    final value = _entry();
    final name = await store().writeEntry(value, _key);
    final file = File('${accountDirectory().path}/$name');
    final original = file.readAsBytesSync();
    for (final length in [
      0,
      readCacheEnvelopeOverhead - 1,
      original.length - 1,
    ]) {
      file.writeAsBytesSync(original.sublist(0, length));
      await expectLater(
        store().readEntry(_account, _key, value.canonicalKey),
        codecFailure(
          length < readCacheEnvelopeOverhead
              ? ReadCacheCodecError.malformed
              : ReadCacheCodecError.authenticationFailed,
        ),
      );
    }
    file.writeAsBytesSync(Uint8List.fromList(original)..[0] = 2);
    await expectLater(
      store().readEntry(_account, _key, value.canonicalKey),
      codecFailure(ReadCacheCodecError.unsupportedVersion),
    );
  });

  test(
    'authenticated schemas and canonical bindings are checked through disk',
    () async {
      const cipher = ReadCacheCipher();
      final value = _entry();
      final name = await store().writeEntry(value, _key);
      final file = File('${accountDirectory().path}/$name');
      final plain = cipher.encodeEntry(value);
      final metadataLength = ByteData.sublistView(plain).getUint32(0);
      final metadata =
          jsonDecode(utf8.decode(plain.sublist(4, 4 + metadataLength)))
              as Map<String, Object?>;
      metadata['schema'] = 2;
      final replacement = utf8.encode(jsonEncode(metadata));
      expect(replacement.length, metadataLength);
      plain.setRange(4, 4 + metadataLength, replacement);
      file.writeAsBytesSync(
        await cipher.encrypt(
          key: _key,
          accountKey: _account,
          fileName: name,
          plaintext: plain,
          plaintextLimit: readCacheEntryLimit,
        ),
      );
      await expectLater(
        store().readEntry(_account, _key, value.canonicalKey),
        codecFailure(ReadCacheCodecError.unsupportedVersion),
      );
      file.writeAsBytesSync(
        await cipher.encrypt(
          key: _key,
          accountKey: _account,
          fileName: name,
          plaintext: cipher.encodeEntry(_entry(id: 2)),
          plaintextLimit: readCacheEntryLimit,
        ),
      );
      await expectLater(
        store().readEntry(_account, _key, value.canonicalKey),
        codecFailure(ReadCacheCodecError.bindingMismatch),
      );
      await expectLater(
        store().readEntryFile(_account, _key, name),
        fileFailure(ReadCacheFileFailure.invalidName),
      );
      file.writeAsBytesSync(
        await cipher.encrypt(
          key: _key,
          accountKey: _account,
          fileName: name,
          plaintext: [0, 0, 0, 1, 0],
          plaintextLimit: readCacheEntryLimit,
        ),
      );
      await Future.wait(
        [
          store().readEntry(_account, _key, value.canonicalKey),
          store().readEntryFile(_account, _key, name),
        ].map(
          (operation) => expectLater(
            operation,
            codecFailure(ReadCacheCodecError.malformed),
          ),
        ),
      );
    },
  );

  test(
    'oversized plaintext is rejected without creating a cache directory',
    () async {
      await expectLater(
        store().writeEntry(_entry(body: 'x' * readCacheEntryLimit), _key),
        codecFailure(ReadCacheCodecError.tooLarge),
      );
      expect(root.listSync(), isEmpty);
    },
  );

  test('oversized ciphertext is rejected before any read callback', () async {
    final value = _entry();
    final name = await store().writeEntry(value, _key);
    final file = File('${accountDirectory().path}/$name');
    final handle = file.openSync(mode: FileMode.append);
    handle.truncateSync(
      readCacheTerminalLogLimit + readCacheEnvelopeOverhead + 1,
    );
    handle.closeSync();
    final files = store(
      checkpoint: (step) {
        if (step == ReadCacheFileCheckpoint.beforeRead) throw const _Crash();
      },
    );
    await expectLater(
      files.readEntry(_account, _key, value.canonicalKey),
      fileFailure(ReadCacheFileFailure.tooLarge),
    );
    final index = File('${accountDirectory().path}/index.v1.bin')
      ..writeAsBytesSync([1]);
    final indexHandle = index.openSync(mode: FileMode.append);
    indexHandle.truncateSync(
      readCacheIndexLimit + readCacheEnvelopeOverhead + 1,
    );
    indexHandle.closeSync();
    await expectLater(
      files.readIndex(_account, _key),
      fileFailure(ReadCacheFileFailure.tooLarge),
    );
  });

  test('growth between stat and open remains bounded', () async {
    final value = _entry();
    final name = await store().writeEntry(value, _key);
    final path = '${accountDirectory().path}/$name';
    final files = store(
      checkpoint: (step) {
        if (step == ReadCacheFileCheckpoint.beforeRead) {
          final handle = File(path).openSync(mode: FileMode.append);
          handle.truncateSync(
            readCacheTerminalLogLimit + readCacheEnvelopeOverhead + 1,
          );
          handle.closeSync();
        }
      },
    );
    await expectLater(
      files.readEntry(_account, _key, value.canonicalKey),
      fileFailure(ReadCacheFileFailure.tooLarge),
    );
  });

  test('unavailable key performs zero root calls and zero file I/O', () async {
    final name = await store().writeEntry(_entry(), _key);
    var rootCalls = 0;
    final files = ReadCacheFileStore(
      root: () async {
        rootCalls++;
        return root;
      },
    );
    final operations = <Future<Object?>>[
      files.writeEntry(_entry(), null),
      files.readEntry(_account, null, _entry().canonicalKey),
      files.readEntryFile(_account, null, name),
      files.entryFiles(_account, null),
      files.readIndex(_account, null),
      files.writeIndex(_account, null, ReadCacheIndex(entries: [])),
      files.evict(_account, null, name),
      files.removeStaleTemporaryFiles(_account, null),
      files.usage(_account, null),
    ];
    await Future.wait(
      operations.map(
        (operation) => expectLater(
          operation,
          fileFailure(ReadCacheFileFailure.keyUnavailable),
        ),
      ),
    );
    expect(rootCalls, 0);
    expect(
      (await store().readEntry(_account, _key, _entry().canonicalKey))!.body,
      _entry().body,
    );
    await files.clearAccount(_account);
    expect(rootCalls, 1);
    expect(accountDirectory().existsSync(), isFalse);
  });

  test(
    'invalid key and names fail closed without exposing supplied values',
    () async {
      await expectLater(
        store().writeEntry(_entry(), [1]),
        fileFailure(ReadCacheFileFailure.invalidKey),
      );
      for (final name in [
        '../outside',
        '/tmp/outside',
        'index.v1.bin',
        'e_${'A' * 32}.v1.bin',
        'e_${'0' * 32}.v1.bin/child',
      ]) {
        await expectLater(
          store().readEntryFile(_account, _key, name),
          fileFailure(ReadCacheFileFailure.invalidName),
        );
        await expectLater(
          store().evict(_account, _key, name),
          fileFailure(ReadCacheFileFailure.invalidName),
        );
      }
      expect(root.listSync(), isEmpty);
      expect(
        const ReadCacheFileException(ReadCacheFileFailure.io).toString(),
        'ReadCacheFileException(io)',
      );
    },
  );

  for (final offset in [-1, 0, 1]) {
    test(
      'authenticated seven-day expiry at ${offset}us from boundary',
      () async {
        final fetched = _now
            .subtract(readCacheRetention)
            .add(Duration(microseconds: offset));
        final value = _entry(fetchedAt: fetched);
        final name = await store().writeEntry(value, _key);
        File('${accountDirectory().path}/$name').setLastModifiedSync(_now);
        final result = await store().readEntry(
          _account,
          _key,
          value.canonicalKey,
        );
        expect(result == null, offset <= 0);
        expect(File('${accountDirectory().path}/$name').existsSync(), isTrue);
      },
    );
  }

  test(
    'future fetchedAt expires; old mtime never expires fresh authenticated data',
    () async {
      final future = _entry(
        fetchedAt: _now.add(const Duration(microseconds: 1)),
      );
      await store().writeEntry(future, _key);
      expect(
        await store().readEntry(_account, _key, future.canonicalKey),
        isNull,
      );
      final value = _entry();
      final name = await store().writeEntry(value, _key);
      File(
        '${accountDirectory().path}/$name',
      ).setLastModifiedSync(_now.subtract(const Duration(days: 100)));
      expect(
        await store().readEntry(_account, _key, value.canonicalKey),
        isNotNull,
      );
    },
  );

  test(
    'temporary age must exceed one hour, with microsecond boundaries',
    () async {
      final name = await store().writeEntry(_entry(), _key);
      final temp = File('${accountDirectory().path}/$name.${'1' * 32}.tmp')
        ..writeAsBytesSync([1, 2, 3]);
      temp.setLastModifiedSync(_now);
      final timestamp = temp.lastModifiedSync().toUtc();
      expect(
        await store(
          now: timestamp
              .add(readCacheTemporaryRetention)
              .subtract(const Duration(microseconds: 1)),
        ).removeStaleTemporaryFiles(_account, _key),
        0,
      );
      expect(
        await store(
          now: timestamp.add(readCacheTemporaryRetention),
        ).removeStaleTemporaryFiles(_account, _key),
        0,
      );
      expect(
        await store(
          now: timestamp
              .add(readCacheTemporaryRetention)
              .add(const Duration(microseconds: 1)),
        ).removeStaleTemporaryFiles(_account, _key),
        1,
      );
      expect(
        await store().readEntry(_account, _key, _entry().canonicalKey),
        isNotNull,
      );
    },
  );

  for (final step in [
    ReadCacheFileCheckpoint.temporaryCreated,
    ReadCacheFileCheckpoint.temporaryWritten,
    ReadCacheFileCheckpoint.temporaryFlushed,
    ReadCacheFileCheckpoint.beforeEntryRename,
    ReadCacheFileCheckpoint.entryRenamed,
  ]) {
    test(
      'fresh store after entry interruption at ${step.name} has no phantom',
      () async {
        final old = _entry(body: 'old');
        final name = await store().writeEntry(old, _key);
        final crashing = store(
          checkpoint: (current) {
            if (current == step) throw const _Crash();
          },
        );
        await expectLater(
          crashing.writeEntry(_entry(body: 'new'), _key),
          fileFailure(ReadCacheFileFailure.io),
        );
        final fresh = store();
        expect(
          (await fresh.readEntry(_account, _key, old.canonicalKey))!.body,
          _entry(
            body: step == ReadCacheFileCheckpoint.entryRenamed ? 'new' : 'old',
          ).body,
        );
        expect(await fresh.entryFiles(_account, _key), [name]);
        expect(await fresh.readIndex(_account, _key), isNull);
        expect(
          accountDirectory().listSync().where(
            (file) => file.path.endsWith('.tmp'),
          ),
          hasLength(step == ReadCacheFileCheckpoint.entryRenamed ? 0 : 1),
        );
        for (final file in accountDirectory().listSync().cast<File>()) {
          expect(
            file.readAsBytesSync(),
            isNot(containsAllInOrder(utf8.encode('Synthetic project'))),
          );
        }
      },
    );
  }

  for (final step in [
    ReadCacheFileCheckpoint.temporaryCreated,
    ReadCacheFileCheckpoint.temporaryWritten,
    ReadCacheFileCheckpoint.temporaryFlushed,
    ReadCacheFileCheckpoint.beforeIndexRename,
    ReadCacheFileCheckpoint.indexRenamed,
  ]) {
    test(
      'fresh store after index interruption at ${step.name} sees committed files only',
      () async {
        final first = await store().writeEntry(_entry(), _key);
        final firstRecord = await indexEntry(first);
        await store().writeIndex(
          _account,
          _key,
          ReadCacheIndex(entries: [firstRecord]),
        );
        final second = await store().writeEntry(_entry(id: 2), _key);
        final secondRecord = await indexEntry(second);
        final crashing = store(
          checkpoint: (current) {
            if (current == step) throw const _Crash();
          },
        );
        await expectLater(
          crashing.writeIndex(
            _account,
            _key,
            ReadCacheIndex(entries: [firstRecord, secondRecord]),
          ),
          fileFailure(ReadCacheFileFailure.io),
        );
        final fresh = store();
        expect(
          accountDirectory().listSync().where(
            (file) => file.path.endsWith('.tmp'),
          ),
          hasLength(step == ReadCacheFileCheckpoint.indexRenamed ? 0 : 1),
        );
        final index = (await fresh.readIndex(_account, _key))!;
        expect(
          index.entries.length,
          step == ReadCacheFileCheckpoint.indexRenamed ? 2 : 1,
        );
        final names = await fresh.entryFiles(_account, _key);
        expect(names, containsAll([first, second]));
        expect(
          index.entries.map((entry) => entry.fileName),
          everyElement(isIn(names)),
        );
      },
    );
  }

  test(
    'file-before-index eviction interruption never exposes a phantom',
    () async {
      final name = await store().writeEntry(_entry(), _key);
      await store().writeIndex(
        _account,
        _key,
        ReadCacheIndex(entries: [await indexEntry(name)]),
      );
      final crashing = store(
        checkpoint: (step) {
          if (step == ReadCacheFileCheckpoint.evictionFileDeleted) {
            throw const _Crash();
          }
        },
      );
      await expectLater(
        crashing.evict(_account, _key, name),
        fileFailure(ReadCacheFileFailure.io),
      );
      expect((await store().readIndex(_account, _key))!.entries, isEmpty);
      expect(
        await store().readEntry(_account, _key, _entry().canonicalKey),
        isNull,
      );
    },
  );

  test(
    'capacity includes ciphertext, index, foreign accounts and temporary files',
    () async {
      final name = await store().writeEntry(_entry(), _key);
      await store().writeIndex(
        _account,
        _key,
        ReadCacheIndex(entries: [await indexEntry(name)]),
      );
      final temp = File('${accountDirectory().path}/$name.${'2' * 32}.tmp')
        ..writeAsBytesSync(List.filled(37, 0));
      await store().writeEntry(_entry(id: 2, account: _otherAccount), _key);
      final usage = await store().usage(_account, _key);
      expect(
        usage.accountBytes,
        accountDirectory().listSync().cast<File>().fold<int>(
          0,
          (sum, file) => sum + file.lengthSync(),
        ),
      );
      expect(usage.deviceBytes, greaterThan(usage.accountBytes));
      expect(temp.lengthSync(), 37);
      final newSize =
          _entry(id: 3).serializedLength + readCacheEnvelopeOverhead;
      final filler = File('${accountDirectory().path}/$name.${'3' * 32}.tmp')
        ..createSync();
      final handle = filler.openSync(mode: FileMode.writeOnly);
      handle.truncateSync(
        readCacheAccountByteLimit - usage.accountBytes - newSize + 1,
      );
      handle.closeSync();
      await expectLater(
        store().writeEntry(_entry(id: 3), _key),
        fileFailure(ReadCacheFileFailure.capacity),
      );
      expect(
        (await store().usage(_account, _key)).accountBytes,
        readCacheAccountByteLimit - newSize + 1,
      );
    },
  );

  test('capacity refusal leaves no empty account directory', () async {
    for (var id = 0; id < 3; id++) {
      final dir = accountDirectory('synthetic-full-$id')
        ..createSync(recursive: true);
      final file = File('${dir.path}/reserve.tmp')..createSync();
      final handle = file.openSync(mode: FileMode.writeOnly);
      handle.truncateSync(readCacheAccountByteLimit);
      handle.closeSync();
    }
    final before = await store().accountDirectoryNames();
    await expectLater(
      store().writeEntry(_entry(), _key),
      fileFailure(ReadCacheFileFailure.capacity),
    );
    expect(accountDirectory().existsSync(), isFalse);
    expect(
      await store().accountDirectoryState(_account),
      ReadCacheDirectoryState.absent,
    );
    expect(await store().accountDirectoryNames(), before);
  });

  test(
    'account and device peak byte caps accept equality and refuse one more byte',
    () async {
      final value = _entry();
      final size = value.serializedLength + readCacheEnvelopeOverhead;
      accountDirectory().createSync(recursive: true);
      final filler = File('${accountDirectory().path}/reserve.tmp')
        ..createSync();
      final handle = filler.openSync(mode: FileMode.writeOnly);
      handle.truncateSync(readCacheAccountByteLimit - size);
      handle.closeSync();
      final name = await store().writeEntry(value, _key);
      expect(
        (await store().usage(_account, _key)).accountBytes,
        readCacheAccountByteLimit,
      );
      await expectLater(
        store().writeEntry(value, _key),
        fileFailure(ReadCacheFileFailure.capacity),
      );
      await store().clearAccount(_account);
      for (var id = 0; id < 3; id++) {
        final dir = accountDirectory('synthetic-other-$id')
          ..createSync(recursive: true);
        final file = File('${dir.path}/reserve.tmp')..createSync();
        final handle = file.openSync(mode: FileMode.writeOnly);
        handle.truncateSync(readCacheAccountByteLimit - (id == 0 ? size : 0));
        handle.closeSync();
      }
      expect(await store().writeEntry(value, _key), name);
      expect(
        (await store().usage(_account, _key)).deviceBytes,
        readCacheDeviceByteLimit,
      );
      await expectLater(
        store().writeEntry(_entry(id: 2), _key),
        fileFailure(ReadCacheFileFailure.capacity),
      );
    },
  );

  for (final level in ['root', 'base', 'account']) {
    test(
      'rejects symlink at $level on reads, writes and scans; deletion stays inside boundary',
      () async {
        final outside = Directory('${root.path}/outside')..createSync();
        final sentinel = File('${outside.path}/sentinel')
          ..writeAsStringSync('synthetic outside');
        final originalRoot = root;
        final path = switch (level) {
          'root' => '${root.path}/linked-root',
          'base' => '${root.path}/read_cache',
          _ => accountDirectory().path,
        };
        Directory(path).parent.createSync(recursive: true);
        Link(path).createSync(outside.path);
        final files = level == 'root'
            ? ReadCacheFileStore(
                root: () async => Directory(path),
                clock: () => _now,
              )
            : store();
        await expectLater(
          files.readEntry(_account, _key, _entry().canonicalKey),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          files.writeEntry(_entry(), _key),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          files.entryFiles(_account, _key),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          files.usage(_account, _key),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          files.removeStaleTemporaryFiles(_account, _key),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          files.accountDirectoryNames(),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          files.accountDirectoryState(_account),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          files.clearAccountDirectoriesExcept({}),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        expect(Link(path).existsSync(), isTrue);
        if (level == 'root') {
          await expectLater(
            files.clearAccount(_account),
            fileFailure(ReadCacheFileFailure.untrustedPath),
          );
        } else {
          await files.clearAccount(_account);
          expect(Link(path).existsSync(), isFalse);
        }
        expect(sentinel.readAsStringSync(), 'synthetic outside');
        expect(root, originalRoot);
      },
    );
  }

  test(
    'entry and index symlinks are refused; explicit deletes unlink only links',
    () async {
      final name = await store().writeEntry(_entry(), _key);
      final outside = File('${root.path}/outside.txt')
        ..writeAsStringSync('synthetic outside');
      final path = '${accountDirectory().path}/$name';
      File(path).deleteSync();
      Link(path).createSync(outside.path);
      await expectLater(
        store().readEntry(_account, _key, _entry().canonicalKey),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        store().writeEntry(_entry(), _key),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        store().entryFiles(_account, _key),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await store().evict(_account, _key, name);
      expect(Link(path).existsSync(), isFalse);
      Link('${accountDirectory().path}/index.v1.bin').createSync(outside.path);
      await expectLater(
        store().readIndex(_account, _key),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        store().writeIndex(_account, _key, ReadCacheIndex(entries: [])),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      Link(
        '${accountDirectory().path}/$name.${'4' * 32}.tmp',
      ).createSync(outside.path);
      await expectLater(
        store().removeStaleTemporaryFiles(_account, _key),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        store().accountDirectoryState(_account),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await store().clearAccount(_account);
      expect(outside.readAsStringSync(), 'synthetic outside');
    },
  );

  for (final step in [
    ReadCacheFileCheckpoint.temporaryCreated,
    ReadCacheFileCheckpoint.beforeEntryRename,
  ]) {
    test('rechecks replaced paths at ${step.name}', () async {
      final name = await store().writeEntry(_entry(), _key);
      final dir = accountDirectory().path;
      final outside = File('${root.path}/outside.txt')
        ..writeAsStringSync('synthetic outside');
      final outsidePath = outside.path;
      final files = store(
        checkpoint: (current) {
          if (current != step) return;
          final path = step == ReadCacheFileCheckpoint.temporaryCreated
              ? Directory(dir)
                    .listSync()
                    .firstWhere((entry) => entry.path.endsWith('.tmp'))
                    .path
              : '$dir/$name';
          File(path).deleteSync();
          Link(path).createSync(outsidePath);
        },
      );
      await expectLater(
        files.writeEntry(_entry(body: 'replacement'), _key),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      expect(outside.readAsStringSync(), 'synthetic outside');
      await store().clearRoot();
      expect(outside.readAsStringSync(), 'synthetic outside');
    });
  }

  for (final level in ['root', 'base', 'account']) {
    test('non-directory at $level is refused', () async {
      final path = switch (level) {
        'root' => '${root.path}/file-root',
        'base' => '${root.path}/read_cache',
        _ => accountDirectory().path,
      };
      File(path).parent.createSync(recursive: true);
      final file = File(path)..writeAsStringSync('synthetic');
      final files = level == 'root'
          ? ReadCacheFileStore(root: () async => Directory(path))
          : store();
      await expectLater(
        files.writeEntry(_entry(), _key),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        files.readIndex(_account, _key),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        files.entryFiles(_account, _key),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        files.accountDirectoryNames(),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        files.accountDirectoryState(_account),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      await expectLater(
        files.clearAccountDirectoriesExcept({}),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
      expect(file.readAsStringSync(), 'synthetic');
      if (level == 'root') {
        await expectLater(
          files.clearRoot(),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
      } else {
        await files.clearRoot();
        expect(file.existsSync(), isFalse);
      }
    });
  }

  test(
    'keyless directory primitives never involve secure storage and preserve AI data',
    () async {
      var secureCalls = 0;
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        secureCalls++;
        throw StateError('synthetic secure store unavailable');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final files = store();
      await root.delete();
      expect(await files.accountDirectoryNames(), isEmpty);
      expect(
        await files.accountDirectoryState(_account),
        ReadCacheDirectoryState.absent,
      );
      await files.clearAccountDirectoriesExcept({});
      expect(root.existsSync(), isFalse);

      accountDirectory().createSync(recursive: true);
      expect(
        await files.accountDirectoryState(_account),
        ReadCacheDirectoryState.emptyDirectory,
      );
      final temp = File(
        '${accountDirectory().path}/index.v1.bin.${'1' * 32}.tmp',
      )..writeAsBytesSync([1]);
      expect(
        await files.accountDirectoryState(_account),
        ReadCacheDirectoryState.hasFiles,
      );
      final other = File(
        '${accountDirectory(_otherAccount).path}/index.v1.bin',
      );
      other.parent.createSync(recursive: true);
      other.writeAsBytesSync([2, 3]);
      final aiFiles = [
        File('${root.path}/ai_history/synthetic/index.v1.bin'),
        File('${root.path}/ai_write_journal/synthetic/journal.v1.enc'),
      ];
      for (final file in aiFiles) {
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync([4, 5]);
      }
      expect(
        await files.accountDirectoryNames(),
        unorderedEquals([
          ReadCacheCipher.accountDirectoryName(_account),
          ReadCacheCipher.accountDirectoryName(_otherAccount),
        ]),
      );
      await files.clearAccountDirectoriesExcept({_account});
      expect(temp.readAsBytesSync(), [1]);
      expect(other.existsSync(), isFalse);
      expect(await files.accountDirectoryNames(), [
        ReadCacheCipher.accountDirectoryName(_account),
      ]);
      await files.clearAccountDirectoriesExcept({});
      expect(await files.accountDirectoryNames(), isEmpty);
      expect(
        await files.accountDirectoryState(_account),
        ReadCacheDirectoryState.absent,
      );
      expect(Directory('${root.path}/read_cache').existsSync(), isTrue);
      for (final file in aiFiles) {
        expect(file.readAsBytesSync(), [4, 5]);
      }
      expect(secureCalls, 0);
    },
  );

  for (final name in [
    'foreign',
    'a' * 31,
    'a' * 33,
    'A' * 32,
    'g' * 32,
    '${'a' * 32}\n',
  ]) {
    test(
      'foreign account directory name ${jsonEncode(name)} fails closed before deletion',
      () async {
        final foreign = Directory('${root.path}/read_cache/$name')
          ..createSync(recursive: true);
        final retained = File('${accountDirectory().path}/sentinel');
        retained.parent.createSync(recursive: true);
        retained.writeAsBytesSync([1]);
        await expectLater(
          store().accountDirectoryNames(),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          store().clearAccountDirectoriesExcept({}),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          store().usage(_account, _key),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await expectLater(
          store().writeEntry(_entry(), _key),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        expect(foreign.existsSync(), isTrue);
        expect(retained.readAsBytesSync(), [1]);
      },
    );
  }

  for (final node in ['directory', 'link']) {
    test(
      'keyless state refuses a $node child and selective clear stays link-safe',
      () async {
        final outside = Directory('${root.path}/outside')..createSync();
        final sentinel = File('${outside.path}/sentinel')
          ..writeAsBytesSync([1]);
        accountDirectory().createSync(recursive: true);
        File('${accountDirectory().path}/regular.tmp').writeAsBytesSync([2]);
        final path = '${accountDirectory().path}/nested';
        if (node == 'directory') {
          Directory(path).createSync();
          Link('$path/link').createSync(outside.path);
        } else {
          Link(path).createSync(outside.path);
        }
        await expectLater(
          store().accountDirectoryState(_account),
          fileFailure(ReadCacheFileFailure.untrustedPath),
        );
        await store().clearAccountDirectoriesExcept({});
        expect(accountDirectory().existsSync(), isFalse);
        expect(sentinel.readAsBytesSync(), [1]);
      },
    );
  }

  test(
    'explicit clear isolates accounts and preserves AI history and journal files',
    () async {
      final first = _entry();
      await store().writeEntry(first, _key);
      final other = _entry(account: _otherAccount);
      final otherName = await store().writeEntry(other, _key);
      final otherFile = File(
        '${accountDirectory(_otherAccount).path}/$otherName',
      );
      final otherBytes = otherFile.readAsBytesSync();
      final aiFiles = [
        File('${root.path}/ai_history/synthetic/index.v1.bin'),
        File('${root.path}/ai_write_journal/synthetic/journal.v1.enc'),
      ];
      for (final file in aiFiles) {
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync([1, 2, 3]);
      }
      await store().clearAccount(_account);
      await store().clearAccount(_account);
      expect(accountDirectory().existsSync(), isFalse);
      expect(otherFile.readAsBytesSync(), otherBytes);
      expect(
        (await store().readEntry(
          _otherAccount,
          _key,
          other.canonicalKey,
        ))!.body,
        other.body,
      );
      await store().clearRoot();
      await store().clearRoot();
      expect(Directory('${root.path}/read_cache').existsSync(), isFalse);
      for (final file in aiFiles) {
        expect(file.readAsBytesSync(), [1, 2, 3]);
      }
    },
  );
}
