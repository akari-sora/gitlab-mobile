import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_history_files.dart';

void main() {
  group('AiHistoryCipher', () {
    test('matches the NIST AES-256-GCM known-answer vector', () async {
      final box = await AiHistoryCipher.seal(
        List<int>.filled(16, 0),
        List<int>.filled(32, 0),
        List<int>.filled(12, 0),
        const <int>[],
      );

      expect(_hex(box.cipherText), 'cea7403d4d606b6e074ec5d3baf39d18');
      expect(_hex(box.mac.bytes), 'd0d1c8a799996bf0265b98b5d48ab919');
      final empty = await AiHistoryCipher.seal(
        const <int>[],
        List<int>.filled(32, 0),
        List<int>.filled(12, 0),
        const <int>[],
      );
      expect(empty.cipherText, isEmpty);
      expect(_hex(empty.mac.bytes), '530f8afbc74536b9a963b4f1c4cb738b');
    });

    test('the persisted envelope binds fixed account and file AAD', () async {
      const account = 'account';
      const file = 'c_00000000000000000000000000000000.v1.bin';
      final encrypted = await AiHistoryCipher.encryptBytes(
        List<int>.filled(16, 0),
        List<int>.filled(32, 0),
        account,
        file,
        nonce: List<int>.filled(12, 0),
      );

      expect(
        _hex(encrypted),
        '01000000000000000000000000'
        'cea7403d4d606b6e074ec5d3baf39d18'
        '5b90c743ce6b30cecd0b97c10c66993b',
      );
      expect(
        await AiHistoryCipher.decryptBytes(
          encrypted,
          List<int>.filled(32, 0),
          account,
          file,
        ),
        everyElement(0),
      );
    });

    test('uses a fresh nonce for every write', () async {
      final key = List<int>.generate(32, (index) => index);
      final first = await AiHistoryCipher.encryptBytes(
        const <int>[1, 2, 3],
        key,
        'account',
        'file',
      );
      final second = await AiHistoryCipher.encryptBytes(
        const <int>[1, 2, 3],
        key,
        'account',
        'file',
      );

      expect(first.sublist(1, 13), isNot(orderedEquals(second.sublist(1, 13))));
      expect(
        await AiHistoryCipher.decryptBytes(first, key, 'account', 'file'),
        <int>[1, 2, 3],
      );
      expect(
        await AiHistoryCipher.decryptBytes(second, key, 'account', 'file'),
        <int>[1, 2, 3],
      );
    });

    test('rejects another account, renamed file, and bit flips', () async {
      final key = List<int>.generate(32, (index) => index);
      final encrypted = await AiHistoryCipher.encryptBytes(
        utf8.encode('synthetic history'),
        key,
        'account-a',
        'original.bin',
      );

      await expectLater(
        AiHistoryCipher.decryptBytes(
          encrypted,
          key,
          'account-b',
          'original.bin',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        AiHistoryCipher.decryptBytes(
          encrypted,
          key,
          'account-a',
          'renamed.bin',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      final flipped = encrypted.toList()..[20] ^= 1;
      await expectLater(
        AiHistoryCipher.decryptBytes(flipped, key, 'account-a', 'original.bin'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('AiHistoryFileStore recovery', () {
    late Directory root;
    late List<int> key;
    const account = 'https://gitlab.example.test#7';
    final now = DateTime.utc(2026, 10, 20, 12);

    setUp(() {
      root = Directory.systemTemp.createTempSync('ai_history_files_test_');
      key = List<int>.generate(32, (index) => 255 - index);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    AiHistoryFileStore store({
      DateTime Function()? clock,
      void Function(AiHistoryCheckpoint, String)? checkpoint,
      List<int> Function(File, int)? readFile,
    }) => AiHistoryFileStore(
      root: () async => root,
      clock: clock ?? () => now,
      checkpoint: checkpoint,
      readFile: readFile,
    );

    test('rebuilds a missing index from conversation files', () async {
      await _writeConversation(root, account, key, _saved(1, now));

      final result = await store().recover(account, key, 30);

      expect(result.conversations.map((value) => value.id), <String>[_id(1)]);
      expect(result.removedUnreadable, isFalse);
      expect(await _index(root, account, key), hasLength(1));
    });

    test('rebuilds an undecryptable index and reports damage', () async {
      await _writeConversation(root, account, key, _saved(1, now));
      final dir = await store().directory(account);
      File(
        '${dir.path}/index.v1.bin',
      ).writeAsBytesSync(List<int>.filled(64, 9));

      final result = await store().recover(account, key, 30);

      expect(result.conversations, hasLength(1));
      expect(result.removedUnreadable, isFalse);
      expect(result.repairedIndex, isTrue);
      expect(await _index(root, account, key), hasLength(1));
    });

    test('rebuilds an oversized index and reports damage', () async {
      await _writeConversation(root, account, key, _saved(1, now));
      final dir = await store().directory(account);
      final index = File('${dir.path}/index.v1.bin');
      final handle = index.openSync(mode: FileMode.write);
      handle.truncateSync(AiHistoryFileStore.indexFileLimit + 1);
      handle.closeSync();

      var indexRead = false;
      final result = await store(
        readFile: (file, cap) {
          if (file.path == index.path) indexRead = true;
          return file.readAsBytesSync();
        },
      ).recover(account, key, 30);
      expect(indexRead, isFalse);

      expect(result.conversations.map((value) => value.id), <String>[_id(1)]);
      expect(result.removedUnreadable, isFalse);
      expect(result.repairedIndex, isTrue);
      expect(
        index.lengthSync(),
        lessThanOrEqualTo(AiHistoryFileStore.indexFileLimit),
      );
      expect(await _index(root, account, key), hasLength(1));
    });

    test('retains an authenticated index with unsupported entries', () async {
      await _writeConversation(root, account, key, _saved(1, now));
      final dir = await store().directory(account);
      await _writeRawIndex(dir, account, key, <Object?>[
        <String, Object?>{
          'id': '../outside',
          'updatedAt': now.toIso8601String(),
        },
      ]);

      final result = await store().recover(account, key, 30);

      expect(result.conversations.map((value) => value.id), <String>[_id(1)]);
      expect(result.removedUnreadable, isFalse);
      expect(result.repairedIndex, isFalse);
      expect(result.unsupported, isTrue);
      expect(await _index(root, account, key), hasLength(1));
    });

    test('drops a missing file from an otherwise readable index', () async {
      final dir = await store().directory(account)
        ..createSync(recursive: true);
      await _writeIndex(dir, account, key, <AiSavedConversation>[
        _saved(1, now),
      ]);

      final result = await store().recover(account, key, 30);

      expect(result.conversations, isEmpty);
      expect(result.removedUnreadable, isFalse);
      expect(await _index(root, account, key), isEmpty);
    });

    test(
      'restores an orphan after a crash following conversation rename',
      () async {
        final crashing = store(
          checkpoint: (checkpoint, _) {
            if (checkpoint == AiHistoryCheckpoint.conversationRenamed) {
              throw StateError('synthetic crash after conversation rename');
            }
          },
        );

        await expectLater(
          crashing.save(account, key, _saved(1, now), 30),
          throwsStateError,
        );
        final dir = await crashing.directory(account);
        expect(File('${dir.path}/index.v1.bin').existsSync(), isFalse);

        final result = await store().recover(account, key, 30);
        expect(result.conversations.map((value) => value.id), <String>[_id(1)]);
      },
    );

    test('adds an orphan omitted by an otherwise valid index', () async {
      final indexed = _saved(1, now);
      final orphan = _saved(2, now.add(const Duration(minutes: 1)));
      expect(
        await store().save(account, key, indexed, 30),
        AiHistorySaveResult.saved,
      );
      await _writeConversation(root, account, key, orphan);
      expect(await _index(root, account, key), hasLength(1));

      final result = await store().recover(account, key, 30);

      expect(result.conversations.map((value) => value.id), <String>[
        _id(1),
        _id(2),
      ]);
      expect(await _index(root, account, key), hasLength(2));
    });

    test('removes stale temporary files but keeps fresh ones', () async {
      final dir = await store().directory(account)
        ..createSync(recursive: true);
      final stale = File('${dir.path}/stale.tmp')..writeAsStringSync('stale');
      final fresh = File('${dir.path}/fresh.tmp')..writeAsStringSync('fresh');
      stale.setLastModifiedSync(now.subtract(const Duration(hours: 2)));
      fresh.setLastModifiedSync(now.subtract(const Duration(minutes: 59)));

      await store().recover(account, key, 30);

      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    test('removes oversized conversation files before reading them', () async {
      final dir = await store().directory(account)
        ..createSync(recursive: true);
      final file = File('${dir.path}/c_${_id(1)}.v1.bin');
      final handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(AiHistoryFileStore.conversationFileLimit + 1);
      handle.closeSync();

      var readCalled = false;
      final result = await store(
        readFile: (file, cap) {
          readCalled = true;
          return file.readAsBytesSync();
        },
      ).recover(account, key, 30);
      expect(readCalled, isFalse);

      expect(result.removedUnreadable, isTrue);
      expect(result.conversations, isEmpty);
      expect(file.existsSync(), isFalse);
    });

    test('removes a bit-flipped file and retains healthy history', () async {
      final damaged = await _writeConversation(
        root,
        account,
        key,
        _saved(1, now),
      );
      final healthy = await _writeConversation(
        root,
        account,
        key,
        _saved(2, now.add(const Duration(minutes: 1))),
      );
      final bytes = damaged.readAsBytesSync()..[30] ^= 1;
      damaged.writeAsBytesSync(bytes);

      final result = await store().recover(account, key, 30);

      expect(result.removedUnreadable, isTrue);
      expect(result.conversations.map((value) => value.id), <String>[_id(2)]);
      expect(damaged.existsSync(), isFalse);
      expect(healthy.existsSync(), isTrue);
    });

    test(
      'transient read failure preserves the conversation and index',
      () async {
        final saved = _saved(1, now);
        expect(
          await store().save(account, key, saved, 30),
          AiHistorySaveResult.saved,
        );
        final dir = await store().directory(account);
        final conversation = File('${dir.path}/c_${saved.id}.v1.bin');
        final index = File('${dir.path}/index.v1.bin');
        final originalIndex = index.readAsBytesSync();
        final failing = store(
          readFile: (file, cap) {
            if (file.path == conversation.path) {
              throw const FileSystemException(
                'synthetic transient read failure',
              );
            }
            return file.readAsBytesSync();
          },
        );

        await expectLater(
          failing.recover(account, key, 30),
          throwsA(isA<FileSystemException>()),
        );

        expect(conversation.existsSync(), isTrue);
        expect(index.readAsBytesSync(), originalIndex);
      },
    );

    test('rejects an invalid id before resolving the storage root', () async {
      var rootRequested = false;
      final invalid = AiHistoryFileStore(
        root: () async {
          rootRequested = true;
          return root;
        },
        clock: () => now,
      );

      await expectLater(
        invalid.save(
          account,
          key,
          AiSavedConversation(
            id: '../not-a-conversation',
            updatedAt: now,
            conversation: AiConversation(
              items: <AiChatItem>[AiUserItem(text: 'synthetic')],
            ),
          ),
          30,
        ),
        throwsArgumentError,
      );

      expect(rootRequested, isFalse);
      expect(root.listSync(), isEmpty);
    });

    test('does not restore an expired orphan', () async {
      final expired = _saved(1, now.subtract(const Duration(days: 30)));
      final file = await _writeConversation(root, account, key, expired);

      final result = await store().recover(account, key, 30);

      expect(result.conversations, isEmpty);
      expect(file.existsSync(), isFalse);
    });

    test(
      'recovers deletion-before-index crash and retains the newest 50',
      () async {
        final indexed = <AiSavedConversation>[];
        for (var index = 0; index < 51; index++) {
          final saved = _saved(index, now.add(Duration(minutes: index)));
          indexed.add(saved);
          await _writeConversation(root, account, key, saved);
        }
        final dir = await store().directory(account);
        await _writeIndex(dir, account, key, indexed);
        expect(await _index(root, account, key), hasLength(51));
        final crashing = store(
          clock: () => now.add(const Duration(days: 1)),
          checkpoint: (checkpoint, _) {
            if (checkpoint == AiHistoryCheckpoint.conversationDeleted) {
              throw StateError('synthetic crash after conversation deletion');
            }
          },
        );

        await expectLater(crashing.recover(account, key, 30), throwsStateError);
        expect(File('${dir.path}/c_${_id(0)}.v1.bin').existsSync(), isFalse);
        expect(await _index(root, account, key), hasLength(51));

        final recovered = await store(
          clock: () => now.add(const Duration(days: 1)),
        ).recover(account, key, 30);
        expect(recovered.conversations, hasLength(50));
        expect(
          recovered.conversations.map((value) => value.id),
          isNot(contains(_id(0))),
        );
        expect(await _index(root, account, key), hasLength(50));
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });

  group('AiHistoryFileStore limits', () {
    late Directory root;
    late List<int> key;
    const account = 'https://gitlab.example.test#9';
    final now = DateTime.utc(2026, 10, 20, 12);

    setUp(() {
      root = Directory.systemTemp.createTempSync('ai_history_limits_test_');
      key = List<int>.generate(32, (index) => index);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    AiHistoryFileStore store() =>
        AiHistoryFileStore(root: () async => root, clock: () => now);

    test('caps every persisted display field', () async {
      final conversation = AiConversation(
        items: <AiChatItem>[
          AiUserItem(
            text: 'u' * 17000,
            chips: <AiContextChip>[
              AiContextChip(
                source: 's' * 1100,
                preview: '界' * 4000,
                sizeChars: 12000,
                type: 't' * 140,
                resource: 'r' * 2100,
                pinnedSha: 'p' * 140,
              ),
            ],
          ),
          AiAssistantItem(text: 'a' * 65000, state: AiAssistantState.done),
          AiToolRunItem(
            name: 'n' * 300,
            argsPreview: '界' * 4000,
            status: AiToolRunStatus.completed,
            sizeChars: 12000,
            provenance: 'p' * 2100,
            resultExcerpt: '界' * 4000,
          ),
        ],
      );

      expect(
        await store().save(
          account,
          key,
          AiSavedConversation(
            id: _id(1),
            updatedAt: now,
            conversation: conversation,
          ),
          30,
        ),
        AiHistorySaveResult.saved,
      );
      final recovered = (await store().recover(
        account,
        key,
        30,
      )).conversations.single.conversation;
      final user = recovered.items[0] as AiUserItem;
      final assistant = recovered.items[1] as AiAssistantItem;
      final tool = recovered.items[2] as AiToolRunItem;

      expect(user.text, hasLength(16000));
      expect(user.chips.single.source, hasLength(1024));
      expect(
        utf8.encode(user.chips.single.preview).length,
        lessThanOrEqualTo(8192),
      );
      expect(user.chips.single.type, hasLength(128));
      expect(user.chips.single.resource, hasLength(2048));
      expect(user.chips.single.pinnedSha, hasLength(128));
      expect(assistant.text, hasLength(64000));
      expect(tool.name, hasLength(256));
      expect(utf8.encode(tool.argsPreview).length, lessThanOrEqualTo(8192));
      expect(tool.provenance, hasLength(2048));
      expect(utf8.encode(tool.resultExcerpt).length, lessThanOrEqualTo(8192));
    });

    test('degrades oldest tool excerpts before saving', () async {
      final tools = List<AiChatItem>.generate(
        40,
        (index) => AiToolRunItem(
          name: 'tool-$index',
          argsPreview: 'a' * 8192,
          status: AiToolRunStatus.completed,
          sizeChars: 16384,
          provenance: 'synthetic',
          resultExcerpt: 'r' * 8192,
        ),
      );

      final result = await store().save(
        account,
        key,
        AiSavedConversation(
          id: _id(1),
          updatedAt: now,
          conversation: AiConversation(items: tools),
        ),
        30,
      );

      expect(result, AiHistorySaveResult.saved);
      final recovered = (await store().recover(
        account,
        key,
        30,
      )).conversations.single.conversation.items.cast<AiToolRunItem>();
      expect(recovered.first.argsPreview, isEmpty);
      expect(recovered.first.resultExcerpt, isEmpty);
      expect(recovered.first.truncated, isTrue);
      expect(recovered.last.resultExcerpt, isNotEmpty);
    });

    test('reports storageLimit when non-tool content cannot fit', () async {
      var capacityLimited = false;
      final result = await store().save(
        account,
        key,
        AiSavedConversation(
          id: _id(1),
          updatedAt: now,
          conversation: AiConversation(
            items: List<AiChatItem>.generate(
              40,
              (_) => AiUserItem(text: 'u' * 16000),
            ),
          ),
        ),
        30,
        onCapacityLimit: () => capacityLimited = true,
      );

      expect(result, AiHistorySaveResult.storageLimit);
      expect(capacityLimited, isFalse);
      expect((await store().directory(account)).existsSync(), isFalse);
    });

    test(
      'evicts oldest conversations above the 16 MiB account limit',
      () async {
        for (var index = 0; index < 34; index++) {
          await _writeConversation(
            root,
            account,
            key,
            _saved(
              index,
              now.add(Duration(minutes: index)),
              conversation: _largeConversation(500000),
            ),
          );
        }

        final result = await store().recover(account, key, 30);
        final dir = await store().directory(account);
        final bytes = result.conversations.fold<int>(0, (total, value) {
          return total + File('${dir.path}/c_${value.id}.v1.bin').lengthSync();
        });

        expect(bytes, lessThanOrEqualTo(AiHistoryFileStore.accountByteLimit));
        expect(
          result.conversations.map((value) => value.id),
          isNot(contains(_id(0))),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('evicts oldest files above the 64 MiB device limit', () async {
      final active = await store().directory(account)
        ..createSync(recursive: true);
      final foreign = Directory(
        '${root.path}/ai_history/${aiHistoryAccountSegment('foreign')}',
      )..createSync(recursive: true);
      final foreignIndex = File('${foreign.path}/index.v1.bin')
        ..writeAsBytesSync(List<int>.filled(64, 7));
      final files = <File>[];
      for (var index = 0; index < 104; index++) {
        final file = File('${foreign.path}/c_${_id(index)}.v1.bin');
        final handle = file.openSync(mode: FileMode.write);
        handle.truncateSync(AiHistoryFileStore.conversationFileLimit);
        handle.closeSync();
        file.setLastModifiedSync(now.subtract(Duration(minutes: 200 - index)));
        files.add(file);
      }

      await store().recover(account, key, 30);

      final remaining = Directory('${root.path}/ai_history')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('.v1.bin') &&
                file.path != '${active.path}/index.v1.bin',
          );
      final bytes = remaining.fold<int>(
        0,
        (sum, file) => sum + file.lengthSync(),
      );
      expect(bytes, lessThanOrEqualTo(64 * 1024 * 1024));
      expect(files.first.existsSync(), isFalse);
      expect(files.last.existsSync(), isTrue);
      expect(foreignIndex.existsSync(), isFalse);
    });

    test(
      'protects unavailable accounts and refuses a new save at the limit',
      () async {
        const foreignAccount = 'protected-foreign';
        final foreignSegment = aiHistoryAccountSegment(foreignAccount);
        final foreign = Directory('${root.path}/ai_history/$foreignSegment')
          ..createSync(recursive: true);
        final foreignIndex = File('${foreign.path}/index.v1.bin')
          ..writeAsBytesSync(List<int>.filled(64, 7));
        final originalIndex = foreignIndex.readAsBytesSync();
        final protectedFiles = <File>[];
        for (var index = 0; index < 104; index++) {
          final file = File('${foreign.path}/c_${_id(index)}.v1.bin');
          final handle = file.openSync(mode: FileMode.write);
          handle.truncateSync(AiHistoryFileStore.conversationFileLimit);
          handle.closeSync();
          file.setLastModifiedSync(
            now.subtract(Duration(minutes: 200 - index)),
          );
          protectedFiles.add(file);
        }
        final protectedStore = store()
          ..canEvictAccount = (segment) => segment != foreignSegment;
        final saved = _saved(999, now);

        final result = await protectedStore.save(account, key, saved, 30);

        expect(result, AiHistorySaveResult.storageLimit);
        expect(
          protectedFiles,
          everyElement(predicate<File>((f) => f.existsSync())),
        );
        expect(foreignIndex.readAsBytesSync(), originalIndex);
        final active = await protectedStore.directory(account);
        expect(
          File('${active.path}/c_${saved.id}.v1.bin').existsSync(),
          isFalse,
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });
}

String _hex(Iterable<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

String _id(int value) => value.toRadixString(16).padLeft(32, '0');

AiSavedConversation _saved(
  int id,
  DateTime updatedAt, {
  AiConversation? conversation,
}) => AiSavedConversation(
  id: _id(id),
  updatedAt: updatedAt,
  conversation:
      conversation ??
      AiConversation(items: <AiChatItem>[AiUserItem(text: 'message-$id')]),
);

AiConversation _largeConversation(int characters) {
  final items = <AiChatItem>[];
  var remaining = characters;
  while (remaining > 0) {
    final length = remaining > 64000 ? 64000 : remaining;
    items.add(
      AiAssistantItem(text: 'a' * length, state: AiAssistantState.done),
    );
    remaining -= length;
  }
  return AiConversation(items: items);
}

Future<File> _writeConversation(
  Directory root,
  String account,
  List<int> key,
  AiSavedConversation saved,
) async {
  final dir = Directory(
    '${root.path}/ai_history/${aiHistoryAccountSegment(account)}',
  )..createSync(recursive: true);
  final name = 'c_${saved.id}.v1.bin';
  final bytes = await AiHistoryCipher.encryptJson(
    <String, Object?>{
      'version': 1,
      'id': saved.id,
      'updatedAt': saved.updatedAt.toUtc().toIso8601String(),
      'stopReason': saved.stopReason,
      'display': aiDisplayJson(saved.conversation),
    },
    key,
    account,
    name,
  );
  return File('${dir.path}/$name')..writeAsBytesSync(bytes);
}

Future<void> _writeIndex(
  Directory dir,
  String account,
  List<int> key,
  List<AiSavedConversation> values,
) => _writeRawIndex(
  dir,
  account,
  key,
  values
      .map(
        (value) => <String, Object?>{
          'id': value.id,
          'updatedAt': value.updatedAt.toUtc().toIso8601String(),
        },
      )
      .toList(),
);

Future<void> _writeRawIndex(
  Directory dir,
  String account,
  List<int> key,
  List<Object?> entries,
) async {
  final bytes = await AiHistoryCipher.encryptJson(
    <String, Object?>{'version': 1, 'entries': entries},
    key,
    account,
    'index.v1.bin',
  );
  File('${dir.path}/index.v1.bin').writeAsBytesSync(bytes);
}

Future<List<Object?>> _index(
  Directory root,
  String account,
  List<int> key,
) async {
  final file = File(
    '${root.path}/ai_history/${aiHistoryAccountSegment(account)}/index.v1.bin',
  );
  final value = await AiHistoryCipher.decryptJson(
    file.readAsBytesSync(),
    key,
    account,
    'index.v1.bin',
  );
  return value['entries']! as List<Object?>;
}
