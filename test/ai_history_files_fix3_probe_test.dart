import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_history_files.dart';

void main() {
  const protectedAccount = 'https://protected.example.test#1';
  const savingAccount = 'https://saving.example.test#2';
  final now = DateTime.utc(2026, 10, 20);
  final key = List<int>.generate(32, (index) => index);
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('ai-history-fix3-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AiHistoryFileStore store() =>
      AiHistoryFileStore(root: () async => root, clock: () => now);

  test(
    'unsupported index protects its entire account from device eviction',
    () async {
      final history = store();
      final protectedDir = await history.directory(protectedAccount)
        ..createSync(recursive: true);
      final protectedConversation = _sparseConversation(
        protectedDir,
        0,
        now.subtract(const Duration(days: 2)),
      );
      final protectedIndex = await _writeUnsupportedIndex(
        protectedDir,
        protectedAccount,
        key,
      );
      final recovery = await history.maintain(protectedAccount, key, 30);
      expect(recovery.unsupportedIndex, isTrue);

      final evictable = Directory(
        '${root.path}/ai_history/${aiHistoryAccountSegment('evictable')}',
      )..createSync(recursive: true);
      for (var index = 1; index <= 104; index++) {
        _sparseConversation(
          evictable,
          index,
          now.subtract(Duration(minutes: 200 - index)),
        );
      }
      (await history.directory(savingAccount)).createSync(recursive: true);

      await store().maintain(savingAccount, key, 30);

      expect(protectedConversation.existsSync(), isTrue);
      expect(protectedIndex.existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'save reports storageLimit when only protected bytes can be freed',
    () async {
      final history = store();
      final protectedDir = await history.directory(protectedAccount)
        ..createSync(recursive: true);
      final protectedIndex = await _writeUnsupportedIndex(
        protectedDir,
        protectedAccount,
        key,
      );
      expect(
        (await history.maintain(protectedAccount, key, 30)).unsupportedIndex,
        isTrue,
      );
      for (var index = 0; index < 104; index++) {
        _sparseConversation(
          protectedDir,
          index,
          now.subtract(Duration(minutes: 200 - index)),
        );
      }
      final saved = AiSavedConversation(
        id: 'f' * 32,
        updatedAt: now,
        conversation: AiConversation(
          items: <AiChatItem>[AiUserItem(text: 'synthetic')],
        ),
      );
      var capacityLimited = false;

      final result = await store().save(
        savingAccount,
        key,
        saved,
        30,
        onCapacityLimit: () => capacityLimited = true,
      );

      expect(result, AiHistorySaveResult.storageLimit);
      expect(capacityLimited, isTrue);
      final savingDir = await history.directory(savingAccount);
      expect(
        File('${savingDir.path}/c_${saved.id}.v1.bin').existsSync(),
        isFalse,
      );
      expect(protectedIndex.existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'unsupported catch quarantines the account before a later scan error',
    () async {
      final history = store();
      final protectedDir = await history.directory(protectedAccount)
        ..createSync(recursive: true);
      final unsupported = await _writeUnsupportedConversation(
        protectedDir,
        protectedAccount,
        key,
        0,
        now,
      );
      final protectedIndex = await _writeSupportedIndex(
        protectedDir,
        protectedAccount,
        key,
      );
      await expectLater(
        history.maintain(
          protectedAccount,
          key,
          30,
          onRecovery: (_) {
            throw const FileSystemException('synthetic later recovery failure');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      final ordinary = _sparseConversation(
        protectedDir,
        1,
        now.subtract(const Duration(days: 3)),
      );
      final evictable = Directory(
        '${root.path}/ai_history/${aiHistoryAccountSegment('later-error')}',
      )..createSync(recursive: true);
      for (var index = 2; index < 106; index++) {
        _sparseConversation(
          evictable,
          index,
          now.subtract(Duration(minutes: 200 - index)),
        );
      }
      (await history.directory(savingAccount)).createSync(recursive: true);

      await store().maintain(savingAccount, key, 30);

      expect(unsupported.existsSync(), isTrue);
      expect(ordinary.existsSync(), isTrue);
      expect(protectedIndex.existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('replacement preflight cannot evict its size-delta target', () async {
    final history = store();
    final original = AiSavedConversation(
      id: 'e' * 32,
      updatedAt: now.subtract(const Duration(days: 1)),
      conversation: AiConversation(
        items: <AiChatItem>[AiUserItem(text: 'small')],
      ),
    );
    expect(
      await history.save(savingAccount, key, original, 30),
      AiHistorySaveResult.saved,
    );
    final savingDir = await history.directory(savingAccount);
    final target = File('${savingDir.path}/c_${original.id}.v1.bin');
    final activeIndex = File('${savingDir.path}/index.v1.bin');
    final protectedDir = await history.directory(protectedAccount)
      ..createSync(recursive: true);
    final protectedIndex = await _writeUnsupportedIndex(
      protectedDir,
      protectedAccount,
      key,
    );
    expect(
      (await history.maintain(protectedAccount, key, 30)).unsupportedIndex,
      isTrue,
    );
    final padding = File('${protectedDir.path}/c_${'d' * 32}.v1.bin');
    final paddingBytes =
        AiHistoryFileStore.deviceByteLimit -
        AiHistoryFileStore.indexFileLimit -
        activeIndex.lengthSync() -
        protectedIndex.lengthSync() -
        target.lengthSync();
    final handle = padding.openSync(mode: FileMode.write);
    handle.truncateSync(paddingBytes);
    handle.closeSync();
    target.setLastModifiedSync(now.subtract(const Duration(days: 2)));
    final replacement = AiSavedConversation(
      id: original.id,
      updatedAt: now,
      conversation: AiConversation(
        items: <AiChatItem>[AiUserItem(text: 'larger replacement')],
      ),
    );

    final result = await history.save(savingAccount, key, replacement, 30);

    expect(result, AiHistorySaveResult.storageLimit);
    expect(target.existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

File _sparseConversation(Directory dir, int value, DateTime modifiedAt) {
  final id = value.toRadixString(16).padLeft(32, '0');
  final file = File('${dir.path}/c_$id.v1.bin');
  final handle = file.openSync(mode: FileMode.write);
  handle.truncateSync(AiHistoryFileStore.conversationFileLimit);
  handle.closeSync();
  file.setLastModifiedSync(modifiedAt);
  return file;
}

Future<File> _writeUnsupportedIndex(
  Directory dir,
  String account,
  List<int> key,
) async {
  final bytes = await AiHistoryCipher.encryptJson(
    <String, Object?>{'version': 2, 'entries': const <Object?>[]},
    key,
    account,
    'index.v1.bin',
  );
  return File('${dir.path}/index.v1.bin')..writeAsBytesSync(bytes, flush: true);
}

Future<File> _writeSupportedIndex(
  Directory dir,
  String account,
  List<int> key,
) async {
  final bytes = await AiHistoryCipher.encryptJson(
    <String, Object?>{'version': 1, 'entries': const <Object?>[]},
    key,
    account,
    'index.v1.bin',
  );
  return File('${dir.path}/index.v1.bin')..writeAsBytesSync(bytes, flush: true);
}

Future<File> _writeUnsupportedConversation(
  Directory dir,
  String account,
  List<int> key,
  int value,
  DateTime updatedAt,
) async {
  final id = value.toRadixString(16).padLeft(32, '0');
  final name = 'c_$id.v1.bin';
  final bytes = await AiHistoryCipher.encryptJson(
    <String, Object?>{
      'version': 2,
      'id': id,
      'updatedAt': updatedAt.toIso8601String(),
      'stopReason': null,
      'display': aiDisplayJson(
        AiConversation(items: <AiChatItem>[AiUserItem(text: 'future')]),
      ),
    },
    key,
    account,
    name,
  );
  return File('${dir.path}/$name')..writeAsBytesSync(bytes, flush: true);
}
