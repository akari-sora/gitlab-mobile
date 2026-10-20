import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const account = 'https://synthetic.example#7';
  final stamp = DateTime.utc(2026, 10, 20);
  late Directory root;
  late MemoryAiStore store;
  late AiHistoryCoordinator coordinator;
  var failWrites = false;
  AiSavedConversation value(String char) => AiSavedConversation(
    id: char * 32,
    updatedAt: stamp,
    conversation: AiConversation(items: [AiUserItem(text: 'synthetic')]),
  );
  setUp(() {
    root = Directory.systemTemp.createTempSync('ai-fix1-coordinator-');
    store = MemoryAiStore();
    failWrites = false;
    coordinator = AiHistoryCoordinator(
      store: store,
      clock: () => stamp,
      files: AiHistoryFileStore(
        root: () async => root,
        clock: () => stamp,
        checkpoint: (_, _) {
          if (failWrites) throw const FileSystemException('synthetic I/O');
        },
      ),
    );
  });
  tearDown(() {
    coordinator.dispose();
    root.deleteSync(recursive: true);
  });

  test('malformed disabled key remains invalid-data across resume', () async {
    store.debugPut(SecureAiStore.historyKey(account), 'broken');
    expect(await coordinator.enable(account), AiHistoryState.unavailable);
    expect(coordinator.failure(account)?.kind, AiStoreFailureKind.malformed);
    expect(coordinator.notice(account), l10n.aiHistoryInvalidData);
    await coordinator.onResume();
    expect(coordinator.state(account), AiHistoryState.unavailable);
    expect(coordinator.failure(account)?.kind, AiStoreFailureKind.malformed);
  });

  test('save I/O is failed and does not enter key retry state', () async {
    await coordinator.enable(account);
    failWrites = true;
    final result = await coordinator.save(account, value('a'));
    expect(result.name, 'failed');
    expect(coordinator.state(account), AiHistoryState.ready);
    expect(coordinator.notice(account, conversationId: 'a' * 32), isNotNull);
    failWrites = false;
    expect(
      await coordinator.save(account, value('a')),
      AiHistorySaveResult.saved,
    );
    expect(coordinator.notice(account, conversationId: 'a' * 32), isNull);
  });

  test(
    'save recovery notice persists across reads until acknowledged',
    () async {
      await coordinator.enable(account);
      await coordinator.save(account, value('a'));
      final dir = await coordinator.files.directory(account);
      final file = File('${dir.path}/c_${'a' * 32}.v1.bin');
      final bytes = file.readAsBytesSync();
      bytes[15] ^= 1;
      file.writeAsBytesSync(bytes);
      expect(
        await coordinator.save(account, value('b')),
        AiHistorySaveResult.saved,
      );
      expect(coordinator.removedUnreadable(account), isTrue);
      await coordinator.read(account);
      expect(coordinator.removedUnreadable(account), isTrue);
      (coordinator as dynamic).acknowledgeNotices(account);
      expect(coordinator.removedUnreadable(account), isFalse);
      expect(coordinator.notice(account), isNull);
    },
  );

  test('damaged index alone has a distinct sticky notice', () async {
    await coordinator.enable(account);
    await coordinator.save(account, value('a'));
    final dir = await coordinator.files.directory(account);
    File('${dir.path}/index.v1.bin').writeAsBytesSync(Uint8List(40));
    final recovered = await coordinator.read(account);
    expect(recovered!.conversations, hasLength(1));
    expect(coordinator.removedUnreadable(account), isFalse);
    expect(coordinator.notice(account), isNotNull);
    expect(coordinator.notice(account), isNot(l10n.aiHistoryRemovedUnreadable));
    await coordinator.read(account);
    expect(coordinator.notice(account), isNotNull);
  });

  test(
    'startup clears orphan records and keys including key-only entries',
    () async {
      await store.saveAccount('orphan-record', AiAccountRecord());
      await store.writeHistoryKey('orphan-key', Uint8List(32));
      final session = SessionController(MemoryAccountStore());
      addTearDown(session.dispose);
      await session.initialize();
      await coordinator.startRecovery(session);
      expect(
        (await store.loadAccount('orphan-record')).status,
        AiStoreReadStatus.absent,
      );
      expect(
        (await store.readHistoryKey('orphan-key')).status,
        AiStoreReadStatus.absent,
      );
    },
  );

  test(
    'malformed tombstone is reported without blocking valid cleanup',
    () async {
      store.debugPut(SecureAiStore.tombstoneKey('bad'), 'invalid');
      await store.setTombstone('good');
      await store.saveAccount('good', AiAccountRecord());
      final session = SessionController(MemoryAccountStore());
      addTearDown(session.dispose);
      await session.initialize();
      await coordinator.startRecovery(session);
      expect(
        (await store.loadAccount('good')).status,
        AiStoreReadStatus.absent,
      );
      expect((coordinator as dynamic).recoveryInvalidData, isTrue);
      (coordinator as dynamic).acknowledgeRecoveryNotice();
      expect((coordinator as dynamic).recoveryInvalidData, isFalse);
    },
  );

  test('startup applies retention without opening a conversation', () async {
    final saved = Account(
      instance: GitLabInstance.parse('https://synthetic.example'),
      user: const GitLabUser(id: 7, username: 'synthetic', name: 'Synthetic'),
      token: 'synthetic-token',
    );
    final savedKey = Uint8List(32);
    await store.saveAccount(
      saved.key,
      AiAccountRecord(historyEnabled: true, retentionDays: 7),
    );
    await store.writeHistoryKey(saved.key, savedKey);
    final old = AiSavedConversation(
      id: 'e' * 32,
      updatedAt: stamp.subtract(const Duration(days: 8)),
      conversation: AiConversation(items: [AiUserItem(text: 'synthetic old')]),
    );
    final oldFiles = AiHistoryFileStore(
      root: () async => root,
      clock: () => old.updatedAt,
    );
    expect(
      await oldFiles.save(saved.key, savedKey, old, 7),
      AiHistorySaveResult.saved,
    );
    final dir = await oldFiles.directory(saved.key);
    final file = File('${dir.path}/c_${old.id}.v1.bin');
    expect(file.existsSync(), isTrue);
    final session = SessionController(MemoryAccountStore()..accounts = [saved]);
    addTearDown(session.dispose);
    await session.initialize();
    await coordinator.startRecovery(session);
    expect(file.existsSync(), isFalse);
  });

  test(
    'same account re-add reopens only after fresh live membership',
    () async {
      final fixture = WorkspaceFixture();
      final accounts = MemoryAccountStore();
      final session = controllerFor(accounts, fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
      final saved = session.active!;
      await coordinator.startRecovery(session);
      expect(await coordinator.enable(saved.key), AiHistoryState.ready);
      await coordinator.clearAccount(saved.key);
      expect(await coordinator.enable(saved.key), AiHistoryState.disabled);
      expect(
        (await store.readHistoryKey(saved.key)).status,
        AiStoreReadStatus.absent,
      );
      await session.remove(saved);
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
      expect(await coordinator.enable(saved.key), AiHistoryState.ready);
      expect(
        (await store.loadAccount(saved.key)).value!.historyEnabled,
        isTrue,
      );
    },
  );

  test(
    'fresh login can reopen a successfully removed startup orphan',
    () async {
      final fixture = WorkspaceFixture();
      final session = controllerFor(MemoryAccountStore(), fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);
      final orphan = Account(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        user: const GitLabUser(id: 7, username: 'synthetic', name: 'Synthetic'),
        token: 'synthetic-token',
      );
      // WorkspaceFixture reports user 7 for this same instance.
      await store.saveAccount(
        orphan.key,
        AiAccountRecord(historyEnabled: true),
      );
      await store.writeHistoryKey(orphan.key, Uint8List(32));
      await session.initialize();
      await coordinator.startRecovery(session);
      expect(
        (await store.loadAccount(orphan.key)).status,
        AiStoreReadStatus.absent,
      );
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
      expect(session.active!.key, orphan.key);
      expect(await coordinator.enable(orphan.key), AiHistoryState.ready);
    },
  );

  test('capacity refusal can be saved again after capacity frees', () async {
    await coordinator.enable(account);
    final foreign = await coordinator.files.directory('protected-other');
    foreign.createSync(recursive: true);
    final file = File('${foreign.path}/c_${'f' * 32}.v1.bin');
    final handle = file.openSync(mode: FileMode.write);
    handle.truncateSync(AiHistoryFileStore.deviceByteLimit);
    handle.closeSync();
    coordinator.files.canEvictAccount = (segment) =>
        segment == aiHistoryAccountSegment(account);
    final result = await coordinator.save(account, value('a'));
    expect(result, AiHistorySaveResult.storageLimit);
    expect(coordinator.storageLimitReached(account, 'a' * 32), isTrue);
    expect(coordinator.evicted(account, 'a' * 32), isFalse);
    foreign.deleteSync(recursive: true);
    expect(
      await coordinator.save(account, value('a')),
      AiHistorySaveResult.saved,
    );
    expect(coordinator.storageLimitReached(account, 'a' * 32), isFalse);
    expect(coordinator.notice(account, conversationId: 'a' * 32), isNull);
  });
}
