import 'dart:async';
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

final class _Lease implements DiskCommitLease {
  bool _current = true;
  @override
  bool get isCurrent => _current;
  @override
  void revoke() => _current = false;
}

void Function(ReadCacheFileCheckpoint) _pauseBeforeCommit(
  ReadCacheFileCheckpoint boundary,
  _Lease lease,
  SendPort events,
  String releasePath,
) => (step) {
  if (step != boundary) return;
  events.send('beforeCommit');
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!File(releasePath).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('commit probe');
    }
    sleep(const Duration(milliseconds: 1));
  }
  events.send(lease.isCurrent);
};

Future<ReadCacheStagedWrite> _roundTrip(ReadCacheStagedWrite staged) =>
    Isolate.run(() => staged);

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

ProjectedDiskEntry _bodyEntry(
  ReadCacheBodyKind kind, {
  List<int>? terminalBytes,
}) {
  final logBytes = terminalBytes ?? utf8.encode('synthetic log 世界\n');
  return ProjectedDiskEntry(
    accountKey: _account,
    canonicalKey: jsonEncode([
      _account,
      'GET',
      switch (kind) {
        ReadCacheBodyKind.json => '/api/v4/projects/1',
        ReadCacheBodyKind.page => '/api/v4/projects/1/issues',
        ReadCacheBodyKind.text => '/api/v4/projects/1/repository/files/README',
        ReadCacheBodyKind.terminalLog => '/api/v4/projects/1/jobs/7/trace',
      },
      <Object?>[],
      kind == ReadCacheBodyKind.text || kind == ReadCacheBodyKind.terminalLog
          ? 'text/plain'
          : 'application/json',
    ]),
    cacheClass: switch (kind) {
      ReadCacheBodyKind.json => ReadCacheDiskClass.projectMeta,
      ReadCacheBodyKind.page => ReadCacheDiskClass.list,
      _ => ReadCacheDiskClass.pinned,
    },
    bodyKind: kind,
    fetchedAt: _now,
    body: switch (kind) {
      ReadCacheBodyKind.json => const {'id': 1, 'name': 'Synthetic project'},
      ReadCacheBodyKind.page => const {
        'items': [
          {'id': 10, 'iid': 7, 'title': 'Synthetic issue 世界'},
        ],
        'next':
            'https://synthetic.example.test/subpath/api/v4/projects/1/'
            'issues?page=2',
      },
      ReadCacheBodyKind.text => ' \n# Synthetic 世界\n \n',
      ReadCacheBodyKind.terminalLog => ReadCacheTerminalLog(
        projectId: 1,
        jobId: 7,
        finishedAt: _now.subtract(const Duration(minutes: 1)),
        startOffset: 128,
        nextOffset: 128 + logBytes.length,
        totalBytes: 128 + logBytes.length,
        isEof: true,
        truncated: true,
        bytes: logBytes,
      ),
    },
    privacyEpoch: 3,
    issueIdentities: {const ReadCacheIssueIdentity(1, 7)},
    scopeTags: const {'project:1'},
    scopeVersions: const {'project:1': 4},
  );
}

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

  List<FileSystemEntity> temporaries() => accountDirectory().existsSync()
      ? accountDirectory()
            .listSync()
            .where((file) => file.path.endsWith('.tmp'))
            .toList()
      : [];

  Future<ReadCacheStagedWrite?> stageWrite(
    ReadCacheFileStore files,
    bool indexWrite,
    bool Function() mayCommit, {
    ReadCacheIndex? index,
  }) => indexWrite
      ? files.stageIndex(
          _account,
          _key,
          index ?? ReadCacheIndex(entries: []),
          mayCommit: mayCommit,
        )
      : files.stageEntry(_entry(), _key, mayCommit: mayCommit);

  Future<Object?> readWrite(bool indexWrite) => indexWrite
      ? store().readIndex(_account, _key)
      : store().readEntry(_account, _key, _entry().canonicalKey);

  setUp(() {
    root = Directory.systemTemp.createTempSync('read_cache_files_');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  for (final indexWrite in [false, true]) {
    final kind = indexWrite ? 'index' : 'entry';

    test(
      '$kind staging stays private until a synchronous current commit',
      () async {
        final lease = _Lease();
        final index = indexWrite
            ? ReadCacheIndex(
                entries: [
                  await indexEntry(await store().writeEntry(_entry(), _key)),
                ],
              )
            : null;
        final staged = (await stageWrite(
          store(),
          indexWrite,
          () => lease.isCurrent,
          index: index,
        ))!;
        expect(await readWrite(indexWrite), isNull);
        expect(temporaries(), hasLength(1));
        expect(
          staged.ciphertextBytes,
          staged.plaintextBytes + readCacheEnvelopeOverhead,
        );
        expect(
          File(temporaries().single.path).lengthSync(),
          staged.ciphertextBytes,
        );
        expect(staged.commit(), ReadCacheCommitResult.committed);
        expect(temporaries(), isEmpty);
        final fresh = await readWrite(indexWrite);
        if (indexWrite) {
          expect(
            (fresh! as ReadCacheIndex).entries.single.fileName,
            index!.entries.single.fileName,
          );
        } else {
          expect((fresh! as ProjectedDiskEntry).body, _entry().body);
        }
        final destination = File(
          '${accountDirectory().path}/${staged.fileName}',
        );
        final committed = destination.readAsBytesSync();
        lease.revoke();
        expect(staged.commit(), ReadCacheCommitResult.alreadyConsumed);
        staged.discard();
        expect(destination.readAsBytesSync(), committed);
      },
    );

    test('$kind revocation after stage returns prevents commit', () async {
      final lease = _Lease();
      final staged = (await stageWrite(
        store(),
        indexWrite,
        () => lease.isCurrent,
      ))!;
      expect(temporaries(), hasLength(1));
      lease.revoke();
      expect(staged.commit(), ReadCacheCommitResult.notPermitted);
      expect(temporaries(), isEmpty);
      expect(
        File('${accountDirectory().path}/${staged.fileName}').existsSync(),
        isFalse,
      );
      expect(await readWrite(indexWrite), isNull);
      expect(staged.commit(), ReadCacheCommitResult.alreadyConsumed);
    });

    test(
      '$kind refused replacement preserves the previous committed bytes',
      () async {
        final files = store();
        final name = await files.writeEntry(_entry(body: 'previous'), _key);
        if (indexWrite) {
          await files.writeIndex(
            _account,
            _key,
            ReadCacheIndex(entries: [await indexEntry(name)]),
          );
        }
        final target = File(
          '${accountDirectory().path}/${indexWrite ? 'index.v1.bin' : name}',
        );
        final previous = target.readAsBytesSync();
        final lease = _Lease();
        final staged = (await stageWrite(
          files,
          indexWrite,
          () => lease.isCurrent,
        ))!;
        lease.revoke();
        expect(staged.commit(), ReadCacheCommitResult.notPermitted);
        expect(target.readAsBytesSync(), previous);
        expect(temporaries(), isEmpty);
        final fresh = await readWrite(indexWrite);
        if (indexWrite) {
          expect((fresh! as ReadCacheIndex).entries.single.fileName, name);
        } else {
          expect(
            (fresh! as ProjectedDiskEntry).body,
            _entry(body: 'previous').body,
          );
        }
      },
    );

    for (final throwAfterRename in [false, true]) {
      test('$kind committed rename skips cleanup after an ancestor replacement '
          '(checkpoint throws: $throwAfterRename)', () async {
        final path = accountDirectory().path;
        final saved = '$path.saved';
        const original = ReadCacheCodecException(
          ReadCacheCodecError.bindingMismatch,
        );
        final files = store(
          checkpoint: (step) {
            final boundary = indexWrite
                ? ReadCacheFileCheckpoint.indexRenamed
                : ReadCacheFileCheckpoint.entryRenamed;
            if (step != boundary) return;
            Directory(path).renameSync(saved);
            File(path).writeAsStringSync('synthetic replacement');
            if (throwAfterRename) throw original;
          },
        );
        final staged = (await stageWrite(files, indexWrite, () => true))!;
        try {
          if (throwAfterRename) {
            expect(staged.commit, throwsA(same(original)));
          } else {
            expect(staged.commit(), ReadCacheCommitResult.committed);
          }
          expect(File(path).readAsStringSync(), 'synthetic replacement');
          expect(File('$saved/${staged.fileName}').existsSync(), isTrue);
          expect(
            Directory(
              saved,
            ).listSync().where((file) => file.path.endsWith('.tmp')),
            isEmpty,
          );
          expect(staged.commit(), ReadCacheCommitResult.alreadyConsumed);
          staged.discard();
        } finally {
          if (File(path).existsSync()) File(path).deleteSync();
          if (Directory(saved).existsSync()) {
            Directory(saved).renameSync(path);
          }
        }
        expect(await readWrite(indexWrite), isNotNull);
      });
    }

    test(
      '$kind revocation and completed clear refuse an outstanding stage',
      () async {
        final lease = _Lease();
        final files = store();
        final staged = (await stageWrite(
          files,
          indexWrite,
          () => lease.isCurrent,
        ))!;
        lease.revoke();
        await files.clearAccount(_account);
        expect(staged.commit(), ReadCacheCommitResult.notPermitted);
        expect(accountDirectory().existsSync(), isFalse);
        expect(await readWrite(indexWrite), isNull);
      },
    );

    test('$kind permission is rechecked immediately before rename', () async {
      var calls = 0;
      final staged = (await stageWrite(
        store(),
        indexWrite,
        () => ++calls < 5,
      ))!;
      expect(calls, 3);
      expect(staged.commit(), ReadCacheCommitResult.notPermitted);
      expect(calls, 5);
      expect(temporaries(), isEmpty);
      expect(await readWrite(indexWrite), isNull);
    });

    test('$kind paused worker cannot commit after caller revocation', () async {
      final index = indexWrite
          ? ReadCacheIndex(
              entries: [
                await indexEntry(await store().writeEntry(_entry(), _key)),
              ],
            )
          : null;
      final lease = _Lease();
      final events = ReceivePort();
      final stream = StreamIterator<Object?>(events);
      final release = File('${root.path}/release');
      addTearDown(events.close);
      final files = store(
        checkpoint: _pauseBeforeCommit(
          indexWrite
              ? ReadCacheFileCheckpoint.beforeIndexRename
              : ReadCacheFileCheckpoint.beforeEntryRename,
          lease,
          events.sendPort,
          release.path,
        ),
      );
      final operation = stageWrite(
        files,
        indexWrite,
        () => lease.isCurrent,
        index: index,
      );
      try {
        expect(
          await stream.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        expect(stream.current, 'beforeCommit');
        expect(temporaries(), hasLength(1));
        expect(await readWrite(indexWrite), isNull);
        lease.revoke();
      } finally {
        release.createSync();
      }
      expect(
        await stream.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(
        stream.current,
        isTrue,
        reason: 'the worker still has an obsolete lease copy',
      );
      expect(await operation, isNull);
      expect(lease.isCurrent, isFalse);
      expect(temporaries(), isEmpty);
      expect(
        await readWrite(indexWrite),
        isNull,
        reason: 'a fresh store must not observe a late rename',
      );
      await stream.cancel();
    });

    test(
      '$kind discard removes the temporary and consumes the handle',
      () async {
        final staged = (await stageWrite(store(), indexWrite, () => true))!;
        expect(temporaries(), hasLength(1));
        staged.discard();
        staged.discard();
        expect(temporaries(), isEmpty);
        expect(staged.commit(), ReadCacheCommitResult.alreadyConsumed);
        expect(await readWrite(indexWrite), isNull);
      },
    );

    test(
      '$kind closed stage gate performs no root call or temporary creation',
      () async {
        var rootCalls = 0;
        final files = ReadCacheFileStore(
          root: () async {
            rootCalls++;
            return root;
          },
        );
        expect(await stageWrite(files, indexWrite, () => false), isNull);
        for (final key in <List<int>?>[
          null,
          [1],
        ]) {
          final operation = indexWrite
              ? files.stageIndex(
                  _account,
                  key,
                  ReadCacheIndex(entries: []),
                  mayCommit: () => false,
                )
              : files.stageEntry(_entry(), key, mayCommit: () => false);
          expect(await operation, isNull);
        }
        expect(rootCalls, 0);
        expect(root.listSync(), isEmpty);
      },
    );

    test(
      '$kind gate is rechecked after asynchronous root resolution',
      () async {
        final pendingRoot = Completer<Directory>();
        final files = ReadCacheFileStore(root: () => pendingRoot.future);
        final lease = _Lease();
        final operation = stageWrite(files, indexWrite, () => lease.isCurrent);
        lease.revoke();
        pendingRoot.complete(root);
        expect(await operation, isNull);
        expect(root.listSync(), isEmpty);
      },
    );

    test(
      '$kind live gate stays on the owner and is checked when staging returns',
      () async {
        final owner = Isolate.current.controlPort;
        final unsendable = ReceivePort();
        addTearDown(unsendable.close);
        var calls = 0;
        bool gate() {
          expect(Isolate.current.controlPort, owner);
          expect(unsendable.sendPort, isA<SendPort>());
          return ++calls < 3;
        }

        expect(await stageWrite(store(), indexWrite, gate), isNull);
        expect(calls, 3);
        expect(temporaries(), isEmpty);
        expect(await readWrite(indexWrite), isNull);
      },
    );

    test(
      '$kind gate errors at stage return and commit clean the temporary',
      () async {
        for (final failAt in [3, 4, 5]) {
          var calls = 0;
          bool gate() {
            if (++calls == failAt) {
              throw StateError('synthetic private gate error');
            }
            return true;
          }

          if (failAt == 3) {
            await expectLater(
              stageWrite(store(), indexWrite, gate),
              fileFailure(ReadCacheFileFailure.io),
            );
          } else {
            final staged = (await stageWrite(store(), indexWrite, gate))!;
            expect(staged.commit, fileFailure(ReadCacheFileFailure.io));
            expect(staged.commit(), ReadCacheCommitResult.alreadyConsumed);
          }
          expect(calls, failAt);
          expect(temporaries(), isEmpty);
          expect(await readWrite(indexWrite), isNull);
        }
      },
    );

    test('$kind handle cannot be copied through another isolate', () async {
      final staged = (await stageWrite(store(), indexWrite, () => true))!;
      await expectLater(
        _roundTrip(staged),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('ReadCacheStagedWrite'),
          ),
        ),
      );
      expect(temporaries(), hasLength(1));
      expect(await readWrite(indexWrite), isNull);
      expect(staged.commit(), ReadCacheCommitResult.committed);
      expect(await readWrite(indexWrite), isNotNull);
    });

    for (final changed in [
      'temporary link',
      'destination link',
      'destination directory',
    ]) {
      test(
        '$kind commit refuses a replaced $changed and cleans its temporary',
        () async {
          final staged = (await stageWrite(store(), indexWrite, () => true))!;
          final sentinel = File('${root.path}/outside')
            ..writeAsStringSync('synthetic outside');
          final path = changed == 'temporary link'
              ? temporaries().single.path
              : '${accountDirectory().path}/${staged.fileName}';
          if (changed == 'temporary link') File(path).deleteSync();
          if (changed == 'destination directory') {
            Directory(path).createSync();
          } else {
            Link(path).createSync(sentinel.path);
          }
          expect(
            staged.commit,
            fileFailure(ReadCacheFileFailure.untrustedPath),
          );
          expect(staged.commit(), ReadCacheCommitResult.alreadyConsumed);
          expect(sentinel.readAsStringSync(), 'synthetic outside');
          expect(temporaries(), isEmpty);
        },
      );
    }

    for (final change in ['truncate', 'extend']) {
      test('$kind commit rejects a $change of its staged temporary', () async {
        final initial = (await stageWrite(store(), indexWrite, () => true))!;
        expect(initial.commit(), ReadCacheCommitResult.committed);
        final destination = File(
          '${accountDirectory().path}/${initial.fileName}',
        );
        final oldBytes = destination.readAsBytesSync();
        final staged = (await stageWrite(store(), indexWrite, () => true))!;
        final temporary = File(
          temporaries().single.path,
        ).openSync(mode: FileMode.writeOnlyAppend);
        try {
          temporary.truncateSync(
            staged.ciphertextBytes + (change == 'truncate' ? -1 : 1),
          );
        } finally {
          temporary.closeSync();
        }
        expect(staged.commit, fileFailure(ReadCacheFileFailure.io));
        expect(staged.commit(), ReadCacheCommitResult.alreadyConsumed);
        expect(temporaries(), isEmpty);
        expect(destination.readAsBytesSync(), oldBytes);
        expect(await readWrite(indexWrite), isNotNull);
      });
    }

    for (final level in ['root', 'base', 'account']) {
      for (final operation in ['commit', 'discard']) {
        test(
          '$kind $operation rechecks a replaced $level directory without following links',
          () async {
            final staged = (await stageWrite(store(), indexWrite, () => true))!;
            final accountPath = accountDirectory().path;
            final temporary = temporaries().single;
            final oldBytes = File(temporary.path).readAsBytesSync();
            final path = switch (level) {
              'root' => root.path,
              'base' => '${root.path}/read_cache',
              _ => accountPath,
            };
            final saved = '$path.saved';
            final movedTemporary = File(
              '$saved${temporary.path.substring(path.length)}',
            );
            final movedDestination =
                '$saved${accountPath.substring(path.length)}/${staged.fileName}';
            Directory(path).renameSync(saved);
            try {
              // Keep the real temporary visible through the replaced ancestor:
              // only the ancestor check can prevent access to the moved tree.
              Link(path).createSync(saved);
              expect(File(temporary.path).existsSync(), isTrue);
              expect(() {
                if (operation == 'commit') {
                  staged.commit();
                } else {
                  staged.discard();
                }
              }, fileFailure(ReadCacheFileFailure.untrustedPath));
              expect(movedTemporary.existsSync(), isTrue);
              expect(movedTemporary.readAsBytesSync(), oldBytes);
              expect(
                FileSystemEntity.typeSync(movedDestination, followLinks: false),
                FileSystemEntityType.notFound,
              );
            } finally {
              if (FileSystemEntity.typeSync(path, followLinks: false) ==
                  FileSystemEntityType.link) {
                Link(path).deleteSync();
              }
              Directory(saved).renameSync(path);
            }
            expect(staged.commit(), ReadCacheCommitResult.alreadyConsumed);
            staged.discard();
            expect(await readWrite(indexWrite), isNull);
            // Leave the ciphertext for stale-temp recovery; cleanup must not
            // traverse the replaced ancestor either.
            expect(temporaries(), hasLength(1));
          },
        );
      }
    }
  }

  for (final change in ['remove', 'resize', 'same-size link']) {
    test(
      'staged index rechecks referenced files after stage returns: $change',
      () async {
        final first = await store().writeEntry(_entry(), _key);
        final firstRecord = await indexEntry(first);
        await store().writeIndex(
          _account,
          _key,
          ReadCacheIndex(entries: [firstRecord]),
        );
        final indexFile = File('${accountDirectory().path}/index.v1.bin');
        final oldBytes = indexFile.readAsBytesSync();
        final second = await store().writeEntry(_entry(id: 2), _key);
        final staged = (await store().stageIndex(
          _account,
          _key,
          ReadCacheIndex(entries: [firstRecord, await indexEntry(second)]),
          mayCommit: () => true,
        ))!;
        final file = File('${accountDirectory().path}/$second');
        final referenceBytes = file.readAsBytesSync();
        final outside = File('${root.path}/outside-reference');
        if (change == 'remove') {
          file.deleteSync();
        } else if (change == 'resize') {
          file.writeAsBytesSync([1]);
        } else {
          outside.writeAsBytesSync(referenceBytes);
          file.deleteSync();
          Link(file.path).createSync(outside.path);
          expect(file.lengthSync(), referenceBytes.length);
        }
        expect(
          staged.commit,
          fileFailure(
            change == 'same-size link'
                ? ReadCacheFileFailure.untrustedPath
                : ReadCacheFileFailure.io,
          ),
        );
        expect(temporaries(), isEmpty);
        expect(indexFile.readAsBytesSync(), oldBytes);
        if (change == 'same-size link') {
          expect(
            FileSystemEntity.typeSync(file.path, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(outside.readAsBytesSync(), referenceBytes);
        }
        expect(
          (await store().readIndex(_account, _key))!.entries.single.fileName,
          first,
        );
      },
    );
  }

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

  test('missing root ancestors remain absent until a write', () async {
    final nestedRoot = Directory('${root.path}/missing/nested');
    final files = ReadCacheFileStore(root: () async => nestedRoot);
    expect(
      await files.accountDirectoryState(_account),
      ReadCacheDirectoryState.absent,
    );
    expect(root.listSync(), isEmpty);
    await files.writeEntry(_entry(), _key);
    expect(
      await files.accountDirectoryState(_account),
      ReadCacheDirectoryState.hasFiles,
    );
  });

  test(
    'accountDirectoryState rejects an unreadable read_cache directory',
    () async {
      accountDirectory().createSync(recursive: true);
      final base = accountDirectory().parent;
      File('${accountDirectory().path}/sentinel').writeAsBytesSync([1]);
      addTearDown(() {
        expect(Process.runSync('chmod', ['700', base.path]).exitCode, 0);
      });
      expect(Process.runSync('chmod', ['000', base.path]).exitCode, 0);
      try {
        base.listSync(followLinks: false);
        markTestSkipped(
          'Mode 000 does not prevent directory listing on this platform or '
          'for this user.',
        );
        return;
      } on FileSystemException {
        // Permission denial must not be mistaken for an absent account.
      }
      await expectLater(
        store().accountDirectoryState(_account),
        fileFailure(ReadCacheFileFailure.io),
      );
    },
    skip: Platform.isWindows
        ? 'chmod permissions do not apply on Windows.'
        : false,
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

  for (final kind in ReadCacheBodyKind.values) {
    test('${kind.name} DTO round-trips through background file I/O', () async {
      final value = _bodyEntry(kind);
      final caller = Isolate.current.controlPort;
      final files = store(
        checkpoint: (step) {
          if (step == ReadCacheFileCheckpoint.temporaryCreated ||
              step == ReadCacheFileCheckpoint.beforeRead) {
            if (Isolate.current.controlPort == caller) throw const _Crash();
          }
        },
      );
      final name = await files.writeEntry(value, _key);
      for (final actual in [
        await files.readEntry(
          _account,
          _key,
          value.canonicalKey,
          expectedBodyKind: kind,
        ),
        await store().readEntryFile(
          _account,
          _key,
          name,
          expectedBodyKind: kind,
        ),
      ]) {
        expect(actual, isNotNull);
        expect(actual!.metadata, value.metadata);
        expect(actual.bodyBytes, value.bodyBytes);
        if (kind == ReadCacheBodyKind.terminalLog) {
          final log = actual.body as ReadCacheTerminalLog;
          expect(log.metadata, (value.body as ReadCacheTerminalLog).metadata);
          expect(() => log.bytes[0] = 0, throwsUnsupportedError);
        } else {
          expect(actual.body, value.body);
        }
      }
    });
  }

  test(
    'terminal log above 1 MiB survives default and explicit reads',
    () async {
      final bytes = Uint8List(readCacheEntryLimit + 1)
        ..fillRange(0, readCacheEntryLimit + 1, 0x61);
      final value = _bodyEntry(
        ReadCacheBodyKind.terminalLog,
        terminalBytes: bytes,
      );
      expect(value.serializedLength, greaterThan(readCacheEntryLimit));
      expect(value.serializedLength, lessThan(readCacheTerminalLogLimit));
      final name = await store().writeEntry(value, _key);
      for (final kind in [null, ReadCacheBodyKind.terminalLog]) {
        for (final actual in [
          await store().readEntry(
            _account,
            _key,
            value.canonicalKey,
            expectedBodyKind: kind,
          ),
          await store().readEntryFile(
            _account,
            _key,
            name,
            expectedBodyKind: kind,
          ),
        ]) {
          expect(actual!.metadata, value.metadata);
          expect((actual.body as ReadCacheTerminalLog).bytes, bytes);
        }
      }
    },
  );

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

  for (final sizeChange in [-1, 1]) {
    test(
      'readIndex drops a size-mismatched entry ($sizeChange byte)',
      () async {
        final first = await store().writeEntry(_entry(), _key);
        final second = await store().writeEntry(_entry(id: 2), _key);
        await store().writeIndex(
          _account,
          _key,
          ReadCacheIndex(
            entries: [await indexEntry(first), await indexEntry(second)],
          ),
        );
        final indexFile = File('${accountDirectory().path}/index.v1.bin');
        final originalIndex = indexFile.readAsBytesSync();
        final changed = File('${accountDirectory().path}/$second');
        final newSize = changed.lengthSync() + sizeChange;
        final handle = changed.openSync(mode: FileMode.append);
        try {
          handle.truncateSync(newSize);
        } finally {
          handle.closeSync();
        }
        final index = (await store().readIndex(_account, _key))!;
        expect(index.entries.map((entry) => entry.fileName), [first]);
        expect(indexFile.readAsBytesSync(), originalIndex);
        expect(changed.lengthSync(), newSize);
      },
    );
  }

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

  test('only rename checkpoints execute on the caller isolate', () async {
    final caller = Isolate.current.controlPort;
    final background = store(
      checkpoint: (step) {
        final renamed =
            step == ReadCacheFileCheckpoint.entryRenamed ||
            step == ReadCacheFileCheckpoint.indexRenamed;
        if ((Isolate.current.controlPort == caller) != renamed) {
          throw const _Crash();
        }
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

  for (final byFileName in [false, true]) {
    for (final kind in <ReadCacheBodyKind?>[
      null,
      ...ReadCacheBodyKind.values,
    ]) {
      test('per-body read ceiling: ${kind?.name ?? 'default'} '
          'via ${byFileName ? 'file name' : 'canonical key'}', () async {
        final value = _entry();
        final name = await store().writeEntry(value, _key);
        final file = File('${accountDirectory().path}/$name');
        final files = store(
          checkpoint: (step) {
            if (step == ReadCacheFileCheckpoint.beforeRead) {
              throw const ReadCacheFileException(
                ReadCacheFileFailure.invalidName,
              );
            }
          },
        );
        Future<ProjectedDiskEntry?> read() => byFileName
            ? files.readEntryFile(_account, _key, name, expectedBodyKind: kind)
            : files.readEntry(
                _account,
                _key,
                value.canonicalKey,
                expectedBodyKind: kind,
              );
        final limit = kind == null || kind == ReadCacheBodyKind.terminalLog
            ? readCacheTerminalLogLimit
            : readCacheEntryLimit;
        for (final size in {
          readCacheEntryLimit + readCacheEnvelopeOverhead,
          readCacheEntryLimit + readCacheEnvelopeOverhead + 1,
          limit + readCacheEnvelopeOverhead,
          limit + readCacheEnvelopeOverhead + 1,
        }) {
          final handle = file.openSync(mode: FileMode.append);
          try {
            handle.truncateSync(size);
          } finally {
            handle.closeSync();
          }
          await expectLater(
            read(),
            fileFailure(
              size > limit + readCacheEnvelopeOverhead
                  ? ReadCacheFileFailure.tooLarge
                  : ReadCacheFileFailure.invalidName,
            ),
            reason: 'only an in-budget file may reach beforeRead ($size bytes)',
          );
        }
      });
    }
  }

  test(
    'expected body kind is checked against authenticated metadata',
    () async {
      final value = _entry();
      final name = await store().writeEntry(value, _key);
      for (final kind in ReadCacheBodyKind.values.where(
        (kind) => kind != ReadCacheBodyKind.json,
      )) {
        await expectLater(
          store().readEntry(
            _account,
            _key,
            value.canonicalKey,
            expectedBodyKind: kind,
          ),
          codecFailure(ReadCacheCodecError.bindingMismatch),
        );
        await expectLater(
          store().readEntryFile(_account, _key, name, expectedBodyKind: kind),
          codecFailure(ReadCacheCodecError.bindingMismatch),
        );
      }
    },
  );

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

  test(
    'offline inventory and selective cleanup handle nested trees safely',
    () async {
      final files = store();
      final hash = ReadCacheCipher.accountDirectoryName(_account);
      final otherHash = ReadCacheCipher.accountDirectoryName(_otherAccount);
      final first = Directory('${root.path}/offline_repo/$hash');
      final other = Directory('${root.path}/offline_repo/$otherHash');
      final blob = File('${first.path}/b/blob.v99.bin');
      blob.parent.createSync(recursive: true);
      blob.writeAsBytesSync([1, 2, 3]);
      final temporary = File('${other.path}/tmp/part');
      temporary.parent.createSync(recursive: true);
      temporary.writeAsBytesSync([4]);
      final outside = Directory('${root.path}/outside')..createSync();
      final sentinel = File('${outside.path}/sentinel')..writeAsBytesSync([5]);
      Link('${other.path}/tmp/link').createSync(outside.path);

      expect(
        await files.offlineAccountDirectoryNames(),
        unorderedEquals([hash, otherHash]),
      );
      expect(
        await files.offlineAccountDirectoryState(_account),
        ReadCacheDirectoryState.hasFiles,
      );
      await files.clearOfflineAccountDirectoriesExcept({_account});
      expect(blob.readAsBytesSync(), [1, 2, 3]);
      expect(other.existsSync(), isFalse);
      expect(sentinel.readAsBytesSync(), [5]);
      await files.clearOfflineAccount(_account);
      expect(
        await files.offlineAccountDirectoryState(_account),
        ReadCacheDirectoryState.absent,
      );
      expect(await files.offlineAccountDirectoryNames(), isEmpty);
      await files.clearOfflineRoot();
      expect(Directory('${root.path}/offline_repo').existsSync(), isFalse);
      expect(sentinel.readAsBytesSync(), [5]);
    },
  );

  test(
    'offline bytes do not count toward C2 capacity or mutate C2 files',
    () async {
      final files = store();
      final c2Name = await files.writeEntry(_entry(), _key);
      final c2File = File('${accountDirectory().path}/$c2Name');
      final c2Bytes = c2File.readAsBytesSync();
      final before = await files.usage(_account, _key);
      final hash = ReadCacheCipher.accountDirectoryName(_account);
      final offline = File('${root.path}/offline_repo/$hash/b/snapshot.v1.bin');
      offline.parent.createSync(recursive: true);
      offline.writeAsBytesSync(List<int>.filled(1024 * 1024, 42));
      final after = await files.usage(_account, _key);
      expect(after.accountBytes, before.accountBytes);
      expect(after.deviceBytes, before.deviceBytes);
      await files.clearOfflineAccount(_account);
      expect(c2File.readAsBytesSync(), c2Bytes);
      expect(
        (await files.readEntry(_account, _key, _entry().canonicalKey))!.body,
        _entry().body,
      );
    },
  );

  test('offline sweep refuses foreign account names before deleting', () async {
    final files = store();
    final hash = ReadCacheCipher.accountDirectoryName(_account);
    final valid = File('${root.path}/offline_repo/$hash/index.v99.bin');
    valid.parent.createSync(recursive: true);
    valid.writeAsBytesSync([7]);
    Directory('${root.path}/offline_repo/not-an-account').createSync();
    await expectLater(
      files.offlineAccountDirectoryNames(),
      fileFailure(ReadCacheFileFailure.untrustedPath),
    );
    await expectLater(
      files.clearOfflineAccountDirectoriesExcept({}),
      fileFailure(ReadCacheFileFailure.untrustedPath),
    );
    expect(valid.readAsBytesSync(), [7]);
    await files.clearOfflineRoot();
    expect(Directory('${root.path}/offline_repo').existsSync(), isFalse);
  });

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

  test('stray root file closes usage and entry/index staging', () async {
    final files = store();
    final name = await files.writeEntry(_entry(), _key);
    final original = File('${accountDirectory().path}/$name').readAsBytesSync();
    final stray = File('${root.path}/read_cache/stray')..writeAsBytesSync([1]);
    await expectLater(
      files.usage(_account, _key),
      fileFailure(ReadCacheFileFailure.untrustedPath),
    );
    for (final indexWrite in [false, true]) {
      await expectLater(
        stageWrite(files, indexWrite, () => true),
        fileFailure(ReadCacheFileFailure.untrustedPath),
      );
    }
    expect(temporaries(), isEmpty);
    expect(
      File('${accountDirectory().path}/$name').readAsBytesSync(),
      original,
    );
    expect(
      File('${accountDirectory().path}/index.v1.bin').existsSync(),
      isFalse,
    );
    expect(stray.readAsBytesSync(), [1]);
    await files.clearRoot();
    expect(Directory('${root.path}/read_cache').existsSync(), isFalse);
  });

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
