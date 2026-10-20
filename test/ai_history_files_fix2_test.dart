import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_history_files.dart';

void main() {
  const account = 'https://gitlab.example.test#fix2';
  final now = DateTime.utc(2026, 10, 20, 12);
  late Directory root;
  late List<int> key;
  late void Function(Directory) originalRemoveDirectory;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ai_history_fix2_');
    key = List<int>.generate(32, (index) => 31 - index);
    originalRemoveDirectory = removeAiHistoryDirectory;
  });

  tearDown(() {
    removeAiHistoryDirectory = originalRemoveDirectory;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AiHistoryFileStore store({
    DateTime Function()? clock,
    void Function(AiHistoryCheckpoint, String)? checkpoint,
  }) => AiHistoryFileStore(
    root: () async => root,
    clock: clock ?? () => now,
    checkpoint: checkpoint,
  );

  test(
    'unsupported conversation refuses same-id save and stale metadata cannot remove it',
    () async {
      final stale = _saved(1, now.subtract(const Duration(days: 31)));
      final history = store(
        clock: () => now.subtract(const Duration(days: 31)),
      );
      expect(
        await history.save(account, key, stale, 30),
        AiHistorySaveResult.saved,
      );
      final file = await _writeUnsupported(root, account, key, stale.id, now);
      final original = file.readAsBytesSync();

      expect(
        await history.save(account, key, _saved(1, now), 30),
        AiHistorySaveResult.unsupported,
      );
      expect(file.readAsBytesSync(), original);
    },
  );

  test(
    'fresh maintenance quarantines unsupported bytes from stale index expiry',
    () async {
      final stale = _saved(1, now.subtract(const Duration(days: 31)));
      final writer = store(clock: () => now.subtract(const Duration(days: 31)));
      expect(
        await writer.save(account, key, stale, 30),
        AiHistorySaveResult.saved,
      );
      final file = await _writeUnsupported(root, account, key, stale.id, now);
      final original = file.readAsBytesSync();

      final recovery = await store().maintain(account, key, 30);

      expect(recovery.unsupported, isTrue);
      expect(file.readAsBytesSync(), original);
    },
  );

  test('unsupported conversations count toward account capacity', () async {
    for (var id = 0; id < AiHistoryFileStore.accountConversationLimit; id++) {
      await _writeUnsupported(root, account, key, _id(id), now);
    }
    final history = store();
    var capacityLimited = false;

    expect(
      await history.save(
        account,
        key,
        _saved(100, now),
        30,
        onCapacityLimit: () => capacityLimited = true,
      ),
      AiHistorySaveResult.storageLimit,
    );
    expect(capacityLimited, isTrue);
    final dir = await history.directory(account);
    expect(File('${dir.path}/c_${_id(100)}.v1.bin').existsSync(), isFalse);
    expect(
      dir.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.v1.bin'),
      ),
      hasLength(AiHistoryFileStore.accountConversationLimit),
    );
  });

  test(
    'device eviction in another store instance preserves quarantined bytes',
    () async {
      final unsupported = await _writeUnsupported(
        root,
        account,
        key,
        _id(1),
        now,
      );
      unsupported.setLastModifiedSync(now.subtract(const Duration(days: 2)));
      await store().maintain(account, key, 30);

      final foreign = Directory(
        '${root.path}/ai_history/${aiHistoryAccountSegment('foreign')}',
      )..createSync(recursive: true);
      for (var id = 0; id < 104; id++) {
        final file = File('${foreign.path}/c_${_id(id)}.v1.bin');
        final handle = file.openSync(mode: FileMode.write);
        handle.truncateSync(AiHistoryFileStore.conversationFileLimit);
        handle.closeSync();
        file.setLastModifiedSync(now.subtract(Duration(minutes: 200 - id)));
      }

      final evicting = store();
      (await evicting.directory('another-account')).createSync(recursive: true);
      await evicting.maintain('another-account', key, 30);

      expect(unsupported.existsSync(), isTrue);
      expect(unsupported.lengthSync(), greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('failed account clear keeps unsupported bytes quarantined', () async {
    final unsupported = await _writeUnsupported(
      root,
      account,
      key,
      _id(1),
      now,
    );
    unsupported.setLastModifiedSync(now.subtract(const Duration(days: 2)));
    final history = store();
    await history.maintain(account, key, 30);
    removeAiHistoryDirectory = (_) {
      throw const FileSystemException('synthetic cleanup failure');
    };
    await expectLater(
      history.deleteAccount(account),
      throwsA(isA<FileSystemException>()),
    );
    removeAiHistoryDirectory = originalRemoveDirectory;

    final foreign = Directory(
      '${root.path}/ai_history/${aiHistoryAccountSegment('foreign-after-failure')}',
    )..createSync(recursive: true);
    for (var id = 0; id < 104; id++) {
      final file = File('${foreign.path}/c_${_id(id)}.v1.bin');
      final handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(AiHistoryFileStore.conversationFileLimit);
      handle.closeSync();
      file.setLastModifiedSync(now.subtract(Duration(minutes: 200 - id)));
    }
    final evicting = store();
    (await evicting.directory('another-account')).createSync(recursive: true);

    await evicting.maintain('another-account', key, 30);

    expect(unsupported.existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('authenticated unsupported index has an explicit clear API', () async {
    final history = store();
    final saved = _saved(1, now);
    await _writeConversation(root, account, key, saved);
    final dir = await history.directory(account);
    await _writeUnsupportedIndex(dir, account, key);

    final recovery = await history.recover(account, key, 30);
    expect(recovery.unsupportedIndex, isTrue);
    expect(
      await history.clearUnsupportedIndex(account, key),
      AiHistoryClearUnsupportedIndexResult.cleared,
    );
    expect(File('${dir.path}/index.v1.bin').existsSync(), isFalse);

    final rebuilt = await history.recover(account, key, 30);
    expect(rebuilt.conversations.map((value) => value.id), [saved.id]);
  });

  test(
    'removed-file recovery reaches the caller before a later I/O failure',
    () async {
      final history = store();
      final damaged = _saved(1, now);
      expect(
        await history.save(account, key, damaged, 30),
        AiHistorySaveResult.saved,
      );
      final dir = await history.directory(account);
      final damagedFile = File('${dir.path}/c_${damaged.id}.v1.bin');
      final damagedBytes = damagedFile.readAsBytesSync()..[30] ^= 1;
      damagedFile.writeAsBytesSync(damagedBytes, flush: true);
      File(
        '${dir.path}/index.v1.bin',
      ).writeAsBytesSync(List<int>.filled(64, 7));
      AiHistoryRecovery? notice;
      var repairedBeforeFailure = false;
      final failing = store(
        checkpoint: (checkpoint, _) {
          if (checkpoint == AiHistoryCheckpoint.beforeIndexWrite) {
            throw const FileSystemException('synthetic index failure');
          }
        },
      );

      expect(
        await failing.save(
          account,
          key,
          _saved(2, now),
          30,
          onRecovery: (value) {
            notice = value;
            repairedBeforeFailure |= value.repairedIndex;
          },
        ),
        AiHistorySaveResult.failed,
      );
      expect(notice?.removedUnreadable, isTrue);
      expect(repairedBeforeFailure, isFalse);
      expect(damagedFile.existsSync(), isFalse);
    },
  );

  test('read recovery publishes removal before index repair fails', () async {
    final history = store();
    final damaged = _saved(1, now);
    expect(
      await history.save(account, key, damaged, 30),
      AiHistorySaveResult.saved,
    );
    final dir = await history.directory(account);
    final damagedFile = File('${dir.path}/c_${damaged.id}.v1.bin');
    final damagedBytes = damagedFile.readAsBytesSync()..[30] ^= 1;
    damagedFile.writeAsBytesSync(damagedBytes, flush: true);
    File('${dir.path}/index.v1.bin').writeAsBytesSync(List<int>.filled(64, 7));
    final notices = <AiHistoryRecovery>[];
    final failing = store(
      checkpoint: (checkpoint, _) {
        if (checkpoint == AiHistoryCheckpoint.beforeIndexWrite) {
          throw const FileSystemException('synthetic index failure');
        }
      },
    );

    await expectLater(
      failing.recover(account, key, 30, onRecovery: notices.add),
      throwsA(isA<FileSystemException>()),
    );

    expect(notices.any((notice) => notice.removedUnreadable), isTrue);
    expect(notices.any((notice) => notice.repairedIndex), isFalse);
    expect(damagedFile.existsSync(), isFalse);
  });

  test(
    'an unsupported conversation cannot claim a skipped index repair',
    () async {
      final history = store();
      final dir = await history.directory(account)
        ..createSync(recursive: true);
      File(
        '${dir.path}/index.v1.bin',
      ).writeAsBytesSync(List<int>.filled(64, 7));
      await _writeUnsupported(root, account, key, _id(1), now);
      final notices = <AiHistoryRecovery>[];

      final recovery = await history.recover(
        account,
        key,
        30,
        onRecovery: notices.add,
      );

      expect(recovery.unsupported, isTrue);
      expect(recovery.repairedIndex, isFalse);
      expect(notices.any((value) => value.repairedIndex), isFalse);
    },
  );

  test('stale temporary cleanup has a distinct recovery signal', () async {
    final history = store();
    final dir = await history.directory(account)
      ..createSync(recursive: true);
    final stale = File('${dir.path}/abandoned.tmp')..writeAsStringSync('stale');
    stale.setLastModifiedSync(now.subtract(const Duration(hours: 2)));

    final recovery = await history.recover(account, key, 30);

    expect(recovery.removedStaleTemporary, isTrue);
    expect(recovery.removedUnreadable, isFalse);
    expect(stale.existsSync(), isFalse);
  });
}

String _id(int value) => value.toRadixString(16).padLeft(32, '0');

AiSavedConversation _saved(int id, DateTime updatedAt) => AiSavedConversation(
  id: _id(id),
  updatedAt: updatedAt,
  conversation: AiConversation(
    items: <AiChatItem>[AiUserItem(text: 'message-$id')],
  ),
);

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

Future<File> _writeUnsupported(
  Directory root,
  String account,
  List<int> key,
  String id,
  DateTime updatedAt,
) async {
  final dir = Directory(
    '${root.path}/ai_history/${aiHistoryAccountSegment(account)}',
  )..createSync(recursive: true);
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

Future<void> _writeUnsupportedIndex(
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
  File('${dir.path}/index.v1.bin').writeAsBytesSync(bytes, flush: true);
}
