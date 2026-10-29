import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_history_files.dart';

void main() {
  const account = 'https://gitlab.example.test#fix1';
  final now = DateTime.utc(2026, 10, 20, 12);
  late Directory root;
  late List<int> key;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ai_history_fix1_');
    key = List<int>.generate(32, (index) => index);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AiHistoryFileStore store({
    DateTime Function()? clock,
    List<int> Function(File, int)? readFile,
  }) => AiHistoryFileStore(
    root: () async => root,
    clock: clock ?? () => now,
    readFile: readFile,
  );

  test(
    'rejects an intermediate history symlink for writes and deletion',
    () async {
      final outside = Directory.systemTemp.createTempSync(
        'ai_history_outside_',
      );
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      final segment = aiHistoryAccountSegment(account);
      final outsideAccount = Directory('${outside.path}/$segment')
        ..createSync();
      final sentinel = File('${outsideAccount.path}/sentinel.txt')
        ..writeAsStringSync('outside-sentinel');
      Link('${root.path}/ai_history').createSync(outside.path);

      expect(
        await store().save(account, key, _saved(1, now), 30),
        AiHistorySaveResult.failed,
      );
      await expectLater(
        store().deleteOrphans(const <String>{}),
        throwsA(isA<FileSystemException>()),
      );

      expect(sentinel.readAsStringSync(), 'outside-sentinel');
      expect(outsideAccount.existsSync(), isTrue);
    },
  );

  test(
    'legacy conversation temp link is rejected without following it',
    () async {
      final history = store();
      final dir = await history.directory(account)
        ..createSync(recursive: true);
      final target = File('${root.path}/outside-conversation.txt')
        ..writeAsStringSync('sentinel');
      final saved = _saved(1, now);
      Link('${dir.path}/c_${saved.id}.v1.bin.tmp').createSync(target.path);

      expect(
        await history.save(account, key, saved, 30),
        AiHistorySaveResult.failed,
      );
      expect(target.readAsStringSync(), 'sentinel');
      expect(
        FileSystemEntity.typeSync(
          '${dir.path}/c_${saved.id}.v1.bin',
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
    },
  );

  test('cleanup is a no-op when the storage root is absent', () async {
    final absent = Directory('${root.path}/not-created');
    final history = AiHistoryFileStore(root: () async => absent);

    await history.deleteAccount(account);
    await history.deleteOrphans(const <String>{});

    expect(absent.existsSync(), isFalse);
  });

  test(
    'legacy index temp link fails visibly and final data is regular',
    () async {
      final history = store();
      final dir = await history.directory(account)
        ..createSync(recursive: true);
      final target = File('${root.path}/outside-index.txt')
        ..writeAsStringSync('sentinel');
      Link('${dir.path}/index.v1.bin.tmp').createSync(target.path);
      final saved = _saved(1, now);

      expect(
        await history.save(account, key, saved, 30),
        AiHistorySaveResult.failed,
      );

      expect(target.readAsStringSync(), 'sentinel');
      expect(
        FileSystemEntity.typeSync(
          '${dir.path}/c_${saved.id}.v1.bin',
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
    },
  );

  test(
    'small save reads index metadata without decrypting conversations',
    () async {
      var reads = 0;
      List<int> countedRead(File file, int cap) {
        reads++;
        return file.readAsBytesSync();
      }

      final largeRoot = Directory.systemTemp.createTempSync('ai_history_fix1_');
      addTearDown(() {
        if (largeRoot.existsSync()) largeRoot.deleteSync(recursive: true);
      });
      final one = store(readFile: countedRead);
      final history = AiHistoryFileStore(
        root: () async => largeRoot,
        clock: () => now,
        readFile: countedRead,
      );
      Future<Duration> timedSmallSave(AiHistoryFileStore target) async {
        reads = 0;
        final stopwatch = Stopwatch()..start();
        expect(
          await target.save(
            account,
            key,
            _saved(30, now.add(const Duration(hours: 1))),
            30,
          ),
          AiHistorySaveResult.saved,
        );
        stopwatch.stop();
        expect(reads, 1, reason: 'only index.v1.bin should be decrypted');
        return stopwatch.elapsed;
      }

      // Warm the isolate/crypto path, then compare small saves with one versus
      // 26 stored conversations (about 7.5 MiB). The read-count assertion is
      // deterministic. Each save spawns isolates and syncs files, so its time
      // follows the host's load: alternate the two stores and compare the
      // fastest sample of each, so a burst on a shared CI host lands on both
      // rather than on the larger store alone.
      await one.save(account, key, _saved(30, now), 30);
      await history.save(account, key, _saved(30, now), 30);
      for (var index = 0; index < 25; index++) {
        final large = AiSavedConversation(
          id: _id(index),
          updatedAt: now.add(Duration(minutes: index)),
          conversation: AiConversation(
            items: List.generate(
              5,
              (_) => AiAssistantItem(
                text: 'x' * 60000,
                state: AiAssistantState.done,
              ),
            ),
          ),
        );
        expect(
          await history.save(account, key, large, 30),
          AiHistorySaveResult.saved,
        );
      }
      final smallSamples = <Duration>[];
      final largeSamples = <Duration>[];
      for (var sample = 0; sample < 5; sample++) {
        smallSamples.add(await timedSmallSave(one));
        largeSamples.add(await timedSmallSave(history));
      }
      smallSamples.sort();
      largeSamples.sort();
      final low = smallSamples.first;
      final high = largeSamples.first;
      expect(high, lessThan(low * 4 + const Duration(milliseconds: 150)));
      final dir = await history.directory(account);
      expect(
        FileSystemEntity.typeSync(
          '${dir.path}/c_${_id(30)}.v1.bin',
          followLinks: false,
        ),
        FileSystemEntityType.file,
      );
      // Kept in foreground test output as the requested cost evidence.
      // ignore: avoid_print
      print(
        'FIX1 incremental save: reads=$reads one=$low conversations26=$high',
      );
    },
  );

  test(
    'changed indexed ciphertext is rechecked and removal is reported',
    () async {
      var reads = 0;
      final history = store(
        readFile: (file, cap) {
          reads++;
          return file.readAsBytesSync();
        },
      );
      final first = _saved(1, now);
      expect(
        await history.save(account, key, first, 30),
        AiHistorySaveResult.saved,
      );
      final dir = await history.directory(account);
      final file = File('${dir.path}/c_${first.id}.v1.bin');
      final bytes = file.readAsBytesSync()..[30] ^= 1;
      file.writeAsBytesSync(bytes, flush: true);
      file.setLastModifiedSync(now.add(const Duration(minutes: 1)));
      reads = 0;
      AiHistoryRecovery? notice;

      final result = await history.save(
        account,
        key,
        _saved(2, now.add(const Duration(minutes: 2))),
        30,
        onRecovery: (value) => notice = value,
      );

      expect(result, AiHistorySaveResult.saved);
      expect(notice?.removedUnreadable, isTrue);
      expect(file.existsSync(), isFalse);
      expect(reads, 2, reason: 'index plus only the changed conversation');
    },
  );

  test(
    'authenticated unsupported conversation is retained and reported',
    () async {
      final history = store();
      final dir = await history.directory(account)
        ..createSync(recursive: true);
      final saved = _saved(1, now);
      final name = 'c_${saved.id}.v1.bin';
      final bytes = await AiHistoryCipher.encryptJson(
        <String, Object?>{
          'version': 2,
          'id': saved.id,
          'updatedAt': now.toIso8601String(),
          'stopReason': null,
          'display': aiDisplayJson(saved.conversation),
        },
        key,
        account,
        name,
      );
      final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);

      final result = await history.recover(account, key, 30);

      expect(result.unsupported, isTrue);
      expect(result.removedUnreadable, isFalse);
      expect(result.conversations, isEmpty);
      expect(file.existsSync(), isTrue);
    },
  );

  test('index carries size metadata and startup maintenance uses it', () async {
    var reads = 0;
    final history = store(
      readFile: (file, cap) {
        reads++;
        return file.readAsBytesSync();
      },
    );
    final saved = _saved(1, now);
    expect(
      await history.save(account, key, saved, 30),
      AiHistorySaveResult.saved,
    );
    final dir = await history.directory(account);
    final indexFile = File('${dir.path}/index.v1.bin');
    final index = await AiHistoryCipher.decryptJson(
      indexFile.readAsBytesSync(),
      key,
      account,
      'index.v1.bin',
    );
    final entry =
        (index['entries']! as List<Object?>).single as Map<String, Object?>;
    expect(entry['updatedAt'], now.toIso8601String());
    expect(entry['size'], greaterThan(0));
    expect(entry['formatVersion'], 1);

    reads = 0;
    final later = store(
      clock: () => now.add(const Duration(days: 31)),
      readFile: (file, cap) {
        reads++;
        return file.readAsBytesSync();
      },
    );
    await later.maintain(account, key, 30);

    expect(reads, 1, reason: 'maintenance decrypts only the index');
    expect(File('${dir.path}/c_${saved.id}.v1.bin').existsSync(), isFalse);
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
