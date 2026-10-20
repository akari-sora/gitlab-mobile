import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('successful save clears a prior read failure immediately', () async {
    final root = Directory.systemTemp.createTempSync('ai-fix3-read-');
    addTearDown(() => root.deleteSync(recursive: true));
    final stamp = DateTime.utc(2026, 10, 20);
    var failRead = false;
    final history = AiHistoryCoordinator(
      store: MemoryAiStore(),
      files: AiHistoryFileStore(
        root: () async => root,
        clock: () => stamp,
        readFile: (file, limit) {
          if (failRead) throw const FileSystemException('synthetic read');
          return file.readAsBytesSync();
        },
      ),
    );
    addTearDown(history.dispose);
    const account = 'synthetic-account';
    AiSavedConversation conversation(String id) => AiSavedConversation(
      id: id * 32,
      updatedAt: stamp,
      conversation: AiConversation(items: [AiUserItem(text: 'synthetic')]),
    );
    await history.enable(account);
    expect(
      await history.save(account, conversation('a')),
      AiHistorySaveResult.saved,
    );
    failRead = true;
    expect(await history.read(account), isNull);
    expect(history.state(account), AiHistoryState.readFailed);
    expect(history.notice(account), l10n.aiHistoryReadFailed);
    failRead = false;
    expect(
      await history.save(account, conversation('b')),
      AiHistorySaveResult.saved,
    );
    expect(history.state(account), AiHistoryState.ready);
    expect(history.failure(account), isNull);
    expect(history.notice(account), isNull);
    expect((await history.read(account))!.conversations, hasLength(2));
  });

  test(
    'capacity refusal permits retry after protected space is freed',
    () async {
      final root = Directory.systemTemp.createTempSync('ai-fix3-capacity-');
      addTearDown(() => root.deleteSync(recursive: true));
      final stamp = DateTime.utc(2026, 10, 20);
      final history = AiHistoryCoordinator(
        store: MemoryAiStore(),
        files: AiHistoryFileStore(root: () async => root, clock: () => stamp),
      );
      addTearDown(history.dispose);
      const account = 'synthetic-account';
      await history.enable(account);
      final foreign = await history.files.directory('protected-other')
        ..createSync(recursive: true);
      final file = File('${foreign.path}/c_${'f' * 32}.v1.bin');
      final handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(AiHistoryFileStore.deviceByteLimit);
      handle.closeSync();
      history.files.canEvictAccount = (_) => false;
      final saved = AiSavedConversation(
        id: 'a' * 32,
        updatedAt: stamp,
        conversation: AiConversation(items: [AiUserItem(text: 'synthetic')]),
      );
      expect(
        await history.save(account, saved),
        AiHistorySaveResult.storageLimit,
      );
      expect(history.storageLimitReached(account, saved.id), isTrue);
      expect(history.evicted(account, saved.id), isFalse);
      foreign.deleteSync(recursive: true);
      expect(await history.save(account, saved), AiHistorySaveResult.saved);
      expect(history.storageLimitReached(account, saved.id), isFalse);
      expect(history.notice(account, conversationId: saved.id), isNull);
    },
  );
}
