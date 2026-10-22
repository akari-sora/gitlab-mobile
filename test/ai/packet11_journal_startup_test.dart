import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/main.dart';

import '../session_test.dart' show MemoryAccountStore;

Account syntheticAccount(int id) => Account(
  instance: GitLabInstance.parse('https://synthetic.example/gitlab'),
  user: GitLabUser(id: id, username: 'user$id', name: 'User $id'),
  token: 'synthetic-test-token-$id',
);

Uint8List syntheticKey(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

/// Holds the stored account list until the test releases it.
class _HeldAccounts extends MemoryAccountStore {
  final release = Completer<void>();
  final loading = Completer<void>();
  @override
  Future<List<Account>> load() async {
    if (!loading.isCompleted) loading.complete();
    await release.future;
    return accounts;
  }
}

class _NoFence implements AiJournalAccountFence {
  @override
  bool isCleaning(String accountKey) => false;
  @override
  Future<T> run<T>(String accountKey, Future<T> Function() action) => action();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('packet11-startup-'));
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'recovery waits for the stored accounts and receives every one of them',
    () async {
      final first = syntheticAccount(7);
      final second = syntheticAccount(8);
      const orphan = 'https://synthetic.example/gitlab#99';
      final accounts = _HeldAccounts()..accounts = [first, second];
      final session = SessionController(accounts);
      addTearDown(session.dispose);
      final keys = MemoryAiJournalKeyStore()..keys[orphan] = syntheticKey(1);
      final journal = AiWriteJournal(
        keys: keys,
        applicationSupport: root,
        processId: 'packet11-startup',
      );

      final initialization = session.initialize();
      final recovery = recoverAiWriteJournalAfterAccountsLoaded(
        session,
        journal,
      );
      await accounts.loading.future;
      await pumpEventQueue();
      expect(session.accountsLoaded, isFalse);
      expect(journal.recovered(first.key), isFalse);
      expect(keys.keys.containsKey(orphan), isTrue);

      accounts.release.complete();
      await recovery.timeout(const Duration(seconds: 5));
      expect(session.accountsLoaded, isTrue);
      expect(journal.recovered(first.key), isTrue);
      expect(journal.recovered(second.key), isTrue);
      // The orphan sweep saw exactly the loaded accounts.
      expect(keys.keys.containsKey(orphan), isFalse);
      await initialization;
    },
  );

  test('accounts already loaded are recovered at once', () async {
    final only = syntheticAccount(7);
    final session = SessionController(MemoryAccountStore()..accounts = [only]);
    addTearDown(session.dispose);
    await session.initialize();
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'packet11-loaded',
    );
    await recoverAiWriteJournalAfterAccountsLoaded(session, journal);
    expect(journal.recovered(only.key), isTrue);
  });

  test('membership that changes during recovery is recovered again', () async {
    final first = syntheticAccount(7);
    final added = syntheticAccount(8);
    final store = MemoryAccountStore()..accounts = [first];
    final session = SessionController(store);
    addTearDown(session.dispose);
    await session.initialize();
    final keys = _GatedInventory();
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      processId: 'packet11-membership',
    );

    final recovery = recoverAiWriteJournalAfterAccountsLoaded(session, journal);
    await keys.entered.future;
    expect(keys.inventoryReads, 1);
    // A second account is stored while the first recovery is running.
    store.accounts = [first, added];
    await session.initialize();
    expect(session.accountsLoaded, isTrue);
    keys.release.complete();
    await recovery.timeout(const Duration(seconds: 5));
    expect(keys.inventoryReads, 2);
    expect(journal.recovered(first.key), isTrue);
    expect(journal.recovered(added.key), isTrue);
  });

  test('an unavailable keychain is swallowed and nothing recovers', () async {
    final only = syntheticAccount(7);
    final session = SessionController(MemoryAccountStore()..accounts = [only]);
    addTearDown(session.dispose);
    await session.initialize();
    final keys = MemoryAiJournalKeyStore()..unavailable = true;
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      processId: 'packet11-unavailable',
    );
    await recoverAiWriteJournalAfterAccountsLoaded(session, journal);
    expect(journal.recovered(only.key), isFalse);
  });

  test(
    'a failed configuration never throws; the first success is kept',
    () async {
      final failed = await configureAiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: () async =>
            throw const FileSystemException('synthetic unavailable path'),
        fence: _NoFence(),
      );
      expect(failed, isFalse);

      final keys = MemoryAiJournalKeyStore();
      expect(
        await configureAiWriteJournal(
          keys: keys,
          applicationSupport: () async => root,
          fence: _NoFence(),
        ),
        isTrue,
      );
      // A later call keeps the first configuration.
      final ignored = MemoryAiJournalKeyStore();
      expect(
        await configureAiWriteJournal(
          keys: ignored,
          applicationSupport: () async => root,
          fence: _NoFence(),
        ),
        isTrue,
      );

      final only = syntheticAccount(7);
      final session = SessionController(
        MemoryAccountStore()..accounts = [only],
      );
      addTearDown(session.dispose);
      await session.initialize();
      await recoverAiWriteJournalAfterAccountsLoaded(
        session,
        AiWriteJournal.instance,
      );
      expect(AiWriteJournal.instance.recovered(only.key), isTrue);
      await AiWriteJournal.instance.ensureInitialized(only.key);
      expect(keys.keys.containsKey(only.key), isTrue);
      expect(ignored.keys, isEmpty);
    },
  );
}

/// Blocks the first inventory read until released.
class _GatedInventory extends MemoryAiJournalKeyStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  var inventoryReads = 0;
  @override
  Future<Set<String>> inventoryAccounts() async {
    inventoryReads++;
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.inventoryAccounts();
  }
}
