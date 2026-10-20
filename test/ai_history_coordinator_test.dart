import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import 'session_test.dart' show MemoryAccountStore;

const account = 'https://synthetic.example/gitlab#7';
final stamp = DateTime.utc(2026, 10, 20);
final key = Uint8List.fromList(List<int>.filled(32, 7));
AiSavedConversation conversation([
  String id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
]) => AiSavedConversation(
  id: id,
  updatedAt: stamp,
  conversation: AiConversation(
    items: [AiUserItem(text: 'redacted synthetic prompt')],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _FaultStore store;
  late AiHistoryCoordinator coordinator;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ai-coordinator-test-');
    store = _FaultStore();
    coordinator = AiHistoryCoordinator.debugReset(
      store: store,
      files: AiHistoryFileStore(root: () async => root, clock: () => stamp),
      clock: () => stamp,
    );
  });
  tearDown(() {
    coordinator.dispose();
    removeAiHistoryDirectory = (directory) =>
        directory.deleteSync(recursive: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> enabled() async {
    await store.memory.writeHistoryKey(account, key);
    await store.memory.saveAccount(
      account,
      AiAccountRecord(historyEnabled: true),
    );
  }

  test(
    'unknown to disabled; enabling writes key before opt-in record',
    () async {
      expect(coordinator.state(account), AiHistoryState.unknown);
      expect(await coordinator.load(account), AiHistoryState.disabled);
      store.calls.clear();
      expect(await coordinator.enable(account), AiHistoryState.ready);
      expect(
        store.calls.indexOf('writeHistoryKey'),
        lessThan(store.calls.indexOf('saveAccount')),
      );
      expect(
        (await store.memory.loadAccount(account)).value!.historyEnabled,
        isTrue,
      );
      expect((await store.memory.readHistoryKey(account)).value, hasLength(32));
    },
  );

  test(
    'crash after key write leaves disabled record and reuses the same key',
    () async {
      store.failAt = 'saveAccount';
      expect(await coordinator.enable(account), AiHistoryState.unavailable);
      final retained = (await store.memory.readHistoryKey(account)).value!;
      expect(
        (await store.memory.loadAccount(account)).status,
        AiStoreReadStatus.absent,
      );
      coordinator.dispose();
      store.failAt = null;
      coordinator = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
      expect(await coordinator.enable(account), AiHistoryState.ready);
      expect((await store.memory.readHistoryKey(account)).value, retained);
      expect(store.calls.where((v) => v == 'writeHistoryKey'), hasLength(1));
    },
  );

  test(
    'absent key is keyMissing; never creates key or deletes files',
    () async {
      await store.memory.saveAccount(
        account,
        AiAccountRecord(historyEnabled: true),
      );
      final dir = await coordinator.files.directory(account)
        ..createSync(recursive: true);
      final file = File('${dir.path}/retained.bin')
        ..writeAsStringSync('encrypted fixture');
      expect(await coordinator.load(account), AiHistoryState.keyMissing);
      expect(await coordinator.enable(account), AiHistoryState.keyMissing);
      expect(await coordinator.read(account), isNull);
      expect(
        await coordinator.save(account, conversation()),
        AiHistorySaveResult.cancelled,
      );
      expect(file.existsSync(), isTrue);
      expect(store.calls, isNot(contains('writeHistoryKey')));
      expect(coordinator.notice(account), isNotNull);
    },
  );

  test(
    'unavailable key leaves files untouched; resume retries to ready',
    () async {
      await enabled();
      final dir = await coordinator.files.directory(account)
        ..createSync(recursive: true);
      final file = File('${dir.path}/retained.bin')
        ..writeAsStringSync('encrypted fixture');
      store.unavailableKey = true;
      expect(await coordinator.load(account), AiHistoryState.unavailable);
      expect(await coordinator.read(account), isNull);
      expect(file.existsSync(), isTrue);
      expect(store.calls, isNot(contains('deleteHistoryKey')));
      store.unavailableKey = false;
      await coordinator.onResume();
      expect(coordinator.state(account), AiHistoryState.ready);
      expect(file.existsSync(), isTrue);
    },
  );

  testWidgets(
    'unavailable retries after 1, 5, 30 seconds, then waits for resume',
    (tester) async {
      await enabled();
      store.unavailableKey = true;
      await coordinator.load(account);
      expect(store.calls.where((v) => v == 'readHistoryKey').length, 1);
      await tester.pump(const Duration(milliseconds: 999));
      expect(store.calls.where((v) => v == 'readHistoryKey').length, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(store.calls.where((v) => v == 'readHistoryKey').length, 2);
      await tester.pump(const Duration(seconds: 5));
      expect(store.calls.where((v) => v == 'readHistoryKey').length, 3);
      await tester.pump(const Duration(seconds: 30));
      expect(store.calls.where((v) => v == 'readHistoryKey').length, 4);
      await tester.pump(const Duration(minutes: 3));
      expect(store.calls.where((v) => v == 'readHistoryKey').length, 4);
      store.unavailableKey = false;
      await coordinator.onResume();
      expect(coordinator.state(account), AiHistoryState.ready);
    },
  );

  test(
    'cleanup invalidates a late key callback and queued saves, then drains before deletion',
    () async {
      await enabled();
      final hold = Completer<void>();
      store.holdKey = hold;
      final transitions = <AiHistoryState>[];
      coordinator.addListener(
        () => transitions.add(coordinator.state(account)),
      );
      final write = coordinator.save(account, conversation());
      await store.keyReadStarted.future;
      final clear = coordinator.clearAccount(account);
      expect(coordinator.state(account), AiHistoryState.cleaning);
      final lateWrite = coordinator.save(
        account,
        conversation('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      );
      expect(await lateWrite, AiHistorySaveResult.cancelled);
      hold.complete();
      expect(await write, AiHistorySaveResult.cancelled);
      await clear;
      expect(
        (await coordinator.files.directory(account)).existsSync(),
        isFalse,
      );
      expect(
        (await store.memory.readHistoryKey(account)).status,
        AiStoreReadStatus.absent,
      );
      expect(
        (await store.memory.loadAccount(account)).status,
        AiStoreReadStatus.absent,
      );
      expect(coordinator.state(account), AiHistoryState.disabled);
      expect(transitions, [AiHistoryState.cleaning, AiHistoryState.disabled]);
      expect(
        store.calls.indexOf('deleteHistoryKey'),
        greaterThan(store.calls.indexOf('readHistoryKey')),
      );
    },
  );

  for (final step in [
    'setTombstone',
    'deleteHistoryKey',
    'directory',
    'deleteAccount',
    'clearTombstone',
  ]) {
    test(
      'cleanup $step failure is typed, keeps tombstone and allows restart continuation',
      () async {
        await enabled();
        final dir = await coordinator.files.directory(account)
          ..createSync(recursive: true);
        File(
          '${dir.path}/encrypted.bin',
        ).writeAsStringSync('synthetic encrypted file');
        if (step == 'directory') {
          removeAiHistoryDirectory = (_) =>
              throw StateError('synthetic non-filesystem failure');
        } else {
          store.failAt = step;
        }
        await expectLater(
          coordinator.clearAccount(account),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.aiHistoryCleanup,
            ),
          ),
        );
        expect(coordinator.state(account), AiHistoryState.cleaning);
        if (step != 'setTombstone') {
          expect((await store.memory.readTombstone(account)).value, isTrue);
        }
        expect(
          await coordinator.save(account, conversation()),
          AiHistorySaveResult.cancelled,
        );
        store.failAt = null;
        removeAiHistoryDirectory = (directory) =>
            directory.deleteSync(recursive: true);
        if (step == 'setTombstone') {
          // A failed first marker write cannot persist a marker; retry is explicit.
          await coordinator.clearAccount(account);
        } else {
          coordinator.dispose();
          coordinator = AiHistoryCoordinator.debugReset(
            store: store,
            files: AiHistoryFileStore(root: () async => root),
          );
          final session = SessionController(MemoryAccountStore());
          await session.initialize();
          await coordinator.startRecovery(session);
          expect(session.accounts, isEmpty);
          session.dispose();
        }
        expect(dir.existsSync(), isFalse);
        expect(
          (await store.memory.readTombstone(account)).status,
          AiStoreReadStatus.absent,
        );
        expect(
          (await store.memory.loadAccount(account)).status,
          AiStoreReadStatus.absent,
        );
      },
    );
  }

  test('root lookup errors are typed and leave the marker', () async {
    coordinator.dispose();
    coordinator = AiHistoryCoordinator.debugReset(
      store: store,
      files: AiHistoryFileStore(
        root: () async => throw PlatformException(code: 'synthetic-root'),
      ),
    );
    await expectLater(
      coordinator.clearAccount(account),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.kind,
          'kind',
          FailureKind.aiHistoryCleanup,
        ),
      ),
    );
    expect((await store.memory.readTombstone(account)).value, isTrue);
  });

  test('orphan cleanup waits for successful delayed account load', () async {
    final dir = await coordinator.files.directory(account)
      ..createSync(recursive: true);
    final accounts = _DelayedAccountStore();
    final session = SessionController(accounts);
    final initialize = session.initialize();
    final recovery = coordinator.startRecovery(session);
    await Future<void>.delayed(Duration.zero);
    expect(session.accountsLoaded, isFalse);
    expect(dir.existsSync(), isTrue);
    accounts.release.complete();
    await initialize;
    await recovery;
    expect(session.accountsLoaded, isTrue);
    expect(dir.existsSync(), isFalse);
    session.dispose();
  });

  test(
    'failed account load cannot authorize orphan cleanup, even if prior accounts existed',
    () async {
      final dir = await coordinator.files.directory(account)
        ..createSync(recursive: true);
      final accounts = _DelayedAccountStore()..failure = true;
      accounts.release.complete();
      final session = SessionController(accounts);
      await session.initialize();
      final recovery = coordinator.startRecovery(session);
      await Future<void>.delayed(Duration.zero);
      expect(session.accountsLoaded, isFalse);
      expect(dir.existsSync(), isTrue);
      coordinator.dispose();
      await recovery;
      session.dispose();
    },
  );

  test(
    'malformed account record stays unavailable and never creates a key',
    () async {
      store.malformedAccount = true;
      expect(await coordinator.load(account), AiHistoryState.unavailable);
      expect(await coordinator.enable(account), AiHistoryState.unavailable);
      expect(store.calls, isNot(contains('writeHistoryKey')));
      expect(coordinator.failure(account)?.kind, AiStoreFailureKind.malformed);
      expect(coordinator.notice(account), l10n.aiHistoryInvalidData);
    },
  );
  test(
    'ready coordinator round trips display and exposes the unsaved state',
    () async {
      await enabled();
      expect(
        await coordinator.save(account, conversation()),
        AiHistorySaveResult.saved,
      );
      final restored = await coordinator.read(account);
      expect(
        (restored!.conversations.single.conversation.items.single as AiUserItem)
            .text,
        'redacted synthetic prompt',
      );
      final oversized = AiSavedConversation(
        id: conversation().id,
        updatedAt: stamp,
        conversation: AiConversation(
          items: List.generate(40, (_) => AiUserItem(text: 'u' * 16000)),
        ),
      );
      expect(
        await coordinator.save(account, oversized),
        AiHistorySaveResult.storageLimit,
      );
      expect(coordinator.storageLimitReached(account, oversized.id), isTrue);
      expect(
        coordinator.notice(account, conversationId: oversized.id),
        isNotNull,
      );
      expect(
        await coordinator.save(account, conversation()),
        AiHistorySaveResult.storageLimit,
      );
      final unchanged = await coordinator.read(account);
      expect(
        (unchanged!.conversations.single.conversation.items.single
                as AiUserItem)
            .text,
        'redacted synthetic prompt',
      );
    },
  );

  test(
    'cleanup drains a real file transaction and coalesces duplicate removals',
    () async {
      await enabled();
      final started = Completer<void>();
      final release = Completer<void>();
      coordinator.dispose();
      coordinator = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(
          root: () async {
            if (!started.isCompleted) started.complete();
            await release.future;
            return root;
          },
          clock: () => stamp,
        ),
      );
      final write = coordinator.save(account, conversation());
      await started.future;
      final first = coordinator.clearAccount(account);
      final second = coordinator.clearAccount(account);
      expect(identical(first, second), isTrue);
      expect(store.calls, isNot(contains('deleteHistoryKey')));
      release.complete();
      expect(await write, AiHistorySaveResult.cancelled);
      await first;
      await second;
      expect(
        (await coordinator.files.directory(account)).existsSync(),
        isFalse,
      );
      expect(store.calls.where((v) => v == 'deleteHistoryKey'), hasLength(1));
      expect(coordinator.state(account), AiHistoryState.disabled);
    },
  );
  test(
    'failed tombstone enumeration cannot authorize orphan cleanup',
    () async {
      final dir = await coordinator.files.directory(account)
        ..createSync(recursive: true);
      store.failAt = 'listTombstones';
      final session = SessionController(MemoryAccountStore());
      await session.initialize();
      await coordinator.startRecovery(session);
      expect(session.accountsLoaded, isTrue);
      expect(dir.existsSync(), isTrue);
      session.dispose();
    },
  );

  test(
    'restart continues a tombstone for an account still present without removing it',
    () async {
      final saved = Account(
        instance: GitLabInstance.parse('https://synthetic.example/gitlab'),
        user: const GitLabUser(id: 7, username: 'synthetic', name: 'Synthetic'),
        token: 'synthetic-token',
      );
      final accounts = MemoryAccountStore()..accounts = [saved];
      await store.memory.setTombstone(saved.key);
      await store.memory.saveAccount(
        saved.key,
        AiAccountRecord(historyEnabled: true),
      );
      await store.memory.writeHistoryKey(saved.key, key);
      final dir = await coordinator.files.directory(saved.key)
        ..createSync(recursive: true);
      final session = SessionController(accounts);
      await session.initialize();
      await coordinator.startRecovery(session);
      expect(accounts.accounts, [saved]);
      expect(session.accounts, [saved]);
      expect(dir.existsSync(), isFalse);
      expect(
        (await store.memory.loadAccount(saved.key)).status,
        AiStoreReadStatus.absent,
      );
      expect(
        (await store.memory.readTombstone(saved.key)).status,
        AiStoreReadStatus.absent,
      );
      session.dispose();
    },
  );

  test(
    'coordinator exposes temporary file read failure without deleting history',
    () async {
      await enabled();
      expect(
        await coordinator.save(account, conversation()),
        AiHistorySaveResult.saved,
      );
      final dir = await coordinator.files.directory(account);
      coordinator.dispose();
      coordinator = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(
          root: () async => root,
          clock: () => stamp,
          readFile: (_, _) =>
              throw const FileSystemException('synthetic temporary read error'),
        ),
      );
      expect(await coordinator.read(account), isNull);
      expect(coordinator.state(account), AiHistoryState.readFailed);
      expect(
        coordinator.failure(account)?.kind,
        AiStoreFailureKind.unavailable,
      );
      expect(
        File('${dir.path}/c_${conversation().id}.v1.bin').existsSync(),
        isTrue,
      );
    },
  );
}

class _DelayedAccountStore extends MemoryAccountStore {
  final release = Completer<void>();
  bool failure = false;
  @override
  Future<List<Account>> load() async {
    await release.future;
    if (failure) throw StateError('synthetic account load failure');
    return [];
  }
}

class _FaultStore implements AiStore {
  final memory = MemoryAiStore();
  final calls = <String>[];
  String? failAt;
  bool unavailableKey = false;
  bool malformedAccount = false;
  Completer<void>? holdKey;
  final keyReadStarted = Completer<void>();
  void check(String step) {
    calls.add(step);
    if (failAt == step) {
      throw PlatformException(code: 'synthetic-storage');
    }
  }

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) async {
    check('loadAccount');
    if (malformedAccount) {
      return const AiStoreRead.absent(
        AiStoreFailure(AiStoreFailureKind.malformed, 'loadAccount'),
      );
    }
    return memory.loadAccount(accountKey);
  }

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord value) async {
    check('saveAccount');
    return memory.saveAccount(accountKey, value);
  }

  @override
  Future<List<String>> listAccountKeys() async {
    check('listAccountKeys');
    return memory.listAccountKeys();
  }

  @override
  Future<void> deleteAccount(String accountKey) async {
    check('deleteAccount');
    return memory.deleteAccount(accountKey);
  }

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) async {
    check('readHistoryKey');
    if (!keyReadStarted.isCompleted) keyReadStarted.complete();
    if (holdKey != null) await holdKey!.future;
    if (unavailableKey) {
      return const AiStoreRead.unavailable(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'readHistoryKey'),
      );
    }
    return memory.readHistoryKey(accountKey);
  }

  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List value) async {
    check('writeHistoryKey');
    return memory.writeHistoryKey(accountKey, value);
  }

  @override
  Future<void> deleteHistoryKey(String accountKey) async {
    check('deleteHistoryKey');
    return memory.deleteHistoryKey(accountKey);
  }

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) async {
    check('readTombstone');
    return memory.readTombstone(accountKey);
  }

  @override
  Future<void> setTombstone(String accountKey) async {
    check('setTombstone');
    return memory.setTombstone(accountKey);
  }

  @override
  Future<void> clearTombstone(String accountKey) async {
    check('clearTombstone');
    return memory.clearTombstone(accountKey);
  }

  @override
  Future<List<String>> listTombstones() async {
    check('listTombstones');
    return memory.listTombstones();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
