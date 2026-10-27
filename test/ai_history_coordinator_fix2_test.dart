import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/workspace_fixture.dart';

final _stamp = DateTime.utc(2026, 10, 20);
Account _account([int id = 7]) => Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: GitLabUser(id: id, username: 'synthetic', name: 'Synthetic'),
  token: 'synthetic-token',
);
AiSavedConversation _conversation(String char) => AiSavedConversation(
  id: char * 32,
  updatedAt: _stamp,
  conversation: AiConversation(items: [AiUserItem(text: 'synthetic')]),
);

class _Store implements AiStore {
  final memory = MemoryAiStore();
  bool failDelete = false;
  Completer<void>? hold;
  final reached = Completer<void>();
  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String account) async {
    if (hold != null) {
      final wait = hold!;
      hold = null;
      reached.complete();
      await wait.future;
    }
    return memory.loadAccount(account);
  }

  @override
  Future<void> saveAccount(String account, AiAccountRecord record) =>
      memory.saveAccount(account, record);
  @override
  Future<List<String>> listAccountKeys() => memory.listAccountKeys();
  @override
  Future<void> deleteAccount(String account) async {
    if (failDelete) throw const FileSystemException('synthetic delete');
    await memory.deleteAccount(account);
  }

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String account) =>
      memory.readHistoryKey(account);
  @override
  Future<void> writeHistoryKey(String account, Uint8List key) =>
      memory.writeHistoryKey(account, key);
  @override
  Future<void> deleteHistoryKey(String account) =>
      memory.deleteHistoryKey(account);
  @override
  Future<AiStoreRead<bool>> readTombstone(String account) =>
      memory.readTombstone(account);
  @override
  Future<void> setTombstone(String account) => memory.setTombstone(account);
  @override
  Future<void> clearTombstone(String account) => memory.clearTombstone(account);
  @override
  Future<List<String>> listTombstones() => memory.listTombstones();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Store store;
  late AiHistoryCoordinator history;
  setUp(() {
    root = Directory.systemTemp.createTempSync('ai-fix2-coordinator-');
    store = _Store();
    history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
    );
  });
  tearDown(() {
    history.dispose();
    root.deleteSync(recursive: true);
  });
  Future<SessionController> emptySession() async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    await session.initialize();
    return session;
  }

  test('failed orphan cleanup releases lease before later sign-in', () async {
    final saved = _account();
    await store.saveAccount(saved.key, AiAccountRecord());
    final session = await emptySession();
    store.failDelete = true;
    await history.startRecovery(session);
    store.failDelete = false;
    await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    await history.startRecovery(session);
    expect(
      AiAccountMutationCoordinator.forStore(store).isCleaning(saved.key),
      isFalse,
    );
    expect(await history.enable(saved.key), AiHistoryState.ready);
  });

  test('cancelled queued orphan lease releases after sign-in', () async {
    final saved = _account();
    await store.saveAccount(saved.key, AiAccountRecord());
    final session = await emptySession();
    final release = Completer<void>();
    store.hold = release;
    final owner = AiAccountMutationCoordinator.forStore(store);
    final pending = owner.mutate(
      saved.key,
      (record) => record.copyWith(retentionDays: 90),
    );
    await store.reached.future;
    final recovery = history.startRecovery(session);
    for (var i = 0; i < 30 && !owner.isCleaning(saved.key); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(owner.isCleaning(saved.key), isTrue);
    await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    release.complete();
    expect(await pending, isNull);
    await recovery;
    expect(owner.isCleaning(saved.key), isFalse);
    expect(await history.enable(saved.key), AiHistoryState.ready);
  });

  test('startup tombstone cleanup reopens a retained account', () async {
    final saved = _account();
    await store.setTombstone(saved.key);
    final accounts = MemoryAccountStore()..accounts = [saved];
    final session = SessionController(accounts, readCache: accounts.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    await history.startRecovery(session);
    expect((await store.readTombstone(saved.key)).isFound, isFalse);
    expect(await history.enable(saved.key), AiHistoryState.ready);
  });

  test('failed session removal reopens successful AI cleanup', () async {
    final saved = _account();
    final accounts = MemoryAccountStore()..accounts = [saved];
    final session = SessionController(accounts, readCache: accounts.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    await history.startRecovery(session);
    await history.clearAccount(saved.key);
    accounts.rejectWrite = true;
    await session.remove(saved);
    expect(session.accounts, [saved]);
    expect(await history.enable(saved.key), AiHistoryState.ready);
  });

  test(
    'read I/O failure keeps the key and permits immediate save retry',
    () async {
      final account = _account().key;
      await history.enable(account);
      await history.save(account, _conversation('a'));
      history.dispose();
      var fail = true;
      history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(
          root: () async => root,
          clock: () => _stamp,
          readFile: (file, limit) {
            if (fail) throw const FileSystemException('synthetic read');
            return file.readAsBytesSync();
          },
        ),
      );
      expect(await history.read(account), isNull);
      expect(history.state(account).name, 'readFailed');
      fail = false;
      expect(
        await history.save(account, _conversation('b')),
        AiHistorySaveResult.saved,
      );
      expect((await history.read(account))!.conversations, hasLength(2));
      expect(history.state(account), AiHistoryState.ready);
    },
  );

  test(
    'removed conversation notice survives a later index write failure',
    () async {
      final account = _account().key;
      await history.enable(account);
      await history.save(account, _conversation('a'));
      final dir = await history.files.directory(account);
      File('${dir.path}/c_${'a' * 32}.v1.bin').writeAsBytesSync(Uint8List(40));
      File('${dir.path}/index.v1.bin').writeAsBytesSync(Uint8List(40));
      history.dispose();
      history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(
          root: () async => root,
          clock: () => _stamp,
          checkpoint: (point, _) {
            if (point == AiHistoryCheckpoint.beforeIndexWrite) {
              throw const FileSystemException('synthetic index write');
            }
          },
        ),
      );
      expect(
        await history.save(account, _conversation('b')),
        AiHistorySaveResult.failed,
      );
      expect(File('${dir.path}/c_${'a' * 32}.v1.bin').existsSync(), isFalse);
      expect(history.removedUnreadable(account), isTrue);
    },
  );

  test(
    'unsupported index exposes a clear action and a typed save refusal',
    () async {
      final account = _account().key;
      await history.enable(account);
      final key = (await store.readHistoryKey(account)).value!;
      final dir = await history.files.directory(account)
        ..createSync(recursive: true);
      File('${dir.path}/index.v1.bin').writeAsBytesSync(
        await AiHistoryCipher.encryptJson(
          {'version': 2, 'entries': <Object?>[]},
          key,
          account,
          'index.v1.bin',
        ),
      );
      expect(
        await history.save(account, _conversation('a')),
        AiHistorySaveResult.unsupported,
      );
      expect(history.canClearUnsupportedIndex(account), isTrue);
      history.acknowledgeNotices(account);
      expect(history.canClearUnsupportedIndex(account), isTrue);
      expect(
        await history.clearUnsupportedIndex(account),
        AiHistoryClearUnsupportedIndexResult.cleared,
      );
      expect(history.canClearUnsupportedIndex(account), isFalse);
      expect(
        await history.save(account, _conversation('a')),
        AiHistorySaveResult.saved,
      );
    },
  );

  test(
    'clearing an unsupported index preserves conversation notices',
    () async {
      final account = _account().key;
      await history.enable(account);
      final key = (await store.readHistoryKey(account)).value!;
      final dir = await history.files.directory(account)
        ..createSync(recursive: true);
      for (final name in ['index.v1.bin', 'c_${'a' * 32}.v1.bin']) {
        File('${dir.path}/$name').writeAsBytesSync(
          await AiHistoryCipher.encryptJson({'version': 2}, key, account, name),
        );
      }
      await history.read(account);
      expect(history.notice(account), l10n.aiHistoryUnsupported);
      expect(
        await history.clearUnsupportedIndex(account),
        AiHistoryClearUnsupportedIndexResult.cleared,
      );
      expect(history.notice(account), l10n.aiHistoryUnsupported);
    },
  );

  test('unsupported index clear has a typed root I/O failure', () async {
    final account = _account().key;
    history.dispose();
    var failRoot = false;
    history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(
        root: () async {
          if (failRoot) throw const FileSystemException('synthetic root');
          return root;
        },
      ),
    );
    await history.enable(account);
    failRoot = true;
    expect(
      await history.clearUnsupportedIndex(account),
      AiHistoryClearUnsupportedIndexResult.failed,
    );
  });

  test('stale temporary cleanup uses its own sticky notice', () async {
    final account = _account().key;
    await history.enable(account);
    final dir = await history.files.directory(account)
      ..createSync(recursive: true);
    final stale = File('${dir.path}/abandoned.tmp')
      ..writeAsStringSync('temporary');
    stale.setLastModifiedSync(_stamp.subtract(const Duration(hours: 2)));
    await history.read(account);
    expect(history.notice(account), l10n.aiHistoryTemporaryFilesRemoved);
    expect(history.removedUnreadable(account), isFalse);
    history.acknowledgeNotices(account);
    expect(history.notice(account), isNull);
  });

  test('startup maintenance isolates one account I/O failure', () async {
    final first = _account();
    final second = _account(8);
    final key = Uint8List(32);
    for (final account in [first, second]) {
      await store.saveAccount(
        account.key,
        AiAccountRecord(historyEnabled: true),
      );
      await store.writeHistoryKey(account.key, key);
      await history.files.save(account.key, key, _conversation('a'), 30);
    }
    final visited = <String>[];
    history.dispose();
    history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(
        root: () async => root,
        clock: () => _stamp,
        readFile: (file, limit) {
          visited.add(file.path);
          if (file.path.contains(aiHistoryAccountSegment(first.key))) {
            throw const FileSystemException('synthetic first account read');
          }
          return file.readAsBytesSync();
        },
      ),
    );
    final accounts = MemoryAccountStore()..accounts = [first, second];
    final session = SessionController(accounts, readCache: accounts.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    await history.startRecovery(session);
    expect(
      visited.any((path) => path.contains(aiHistoryAccountSegment(second.key))),
      isTrue,
    );
  });
}
