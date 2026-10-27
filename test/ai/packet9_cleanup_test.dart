import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_account_cleanup.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import '../session_test.dart' show MemoryAccountStore;

final digest = List.filled(64, 'a').join();

Account _account(int id, String username) => Account(
  instance: GitLabInstance.parse('https://synthetic.example/gitlab'),
  user: GitLabUser(id: id, username: username, name: 'Synthetic $username'),
  token: 'synthetic-test-token-$id',
);

/// The journal reads the same durable tombstone that history writes.
class SharedTombstoneKeys extends MemoryAiJournalKeyStore {
  SharedTombstoneKeys(this.ai);
  final AiStore ai;

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) async {
    if (unavailable) return super.readTombstone(accountKey);
    return ai.readTombstone(accountKey);
  }

  @override
  Future<Set<String>> inventoryAccounts() async => {
    ...await super.inventoryAccounts(),
    ...await ai.listTombstones(),
  };
}

/// History store with injectable failures for the steps `_clearAccount` uses.
class FaultAiStore implements AiStore {
  FaultAiStore(this.memory);
  final MemoryAiStore memory;
  bool throwAfterTombstone = false;
  bool failDeleteAccount = false;
  final List<String> steps = [];
  bool Function()? journalPresentAtHistoryStep;
  bool? journalPresentWhenHistoryStarted;

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      memory.readTombstone(accountKey);

  @override
  Future<void> setTombstone(String accountKey) async {
    steps.add('setTombstone');
    await memory.setTombstone(accountKey);
    if (throwAfterTombstone) {
      throwAfterTombstone = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'setTombstone'),
      );
    }
  }

  @override
  Future<List<String>> listTombstones() => memory.listTombstones();

  @override
  Future<void> clearTombstone(String accountKey) async {
    steps.add('clearTombstone');
    await memory.clearTombstone(accountKey);
  }

  @override
  Future<void> deleteHistoryKey(String accountKey) async {
    steps.add('deleteHistoryKey');
    journalPresentWhenHistoryStarted = journalPresentAtHistoryStep?.call();
    await memory.deleteHistoryKey(accountKey);
  }

  @override
  Future<void> deleteAccount(String accountKey) async {
    steps.add('deleteAccount');
    if (failDeleteAccount) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'deleteAccount'),
      );
    }
    await memory.deleteAccount(accountKey);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MemoryAiStore memory;
  late FaultAiStore store;
  late SharedTombstoneKeys keys;
  late AiJournalFiles files;
  late AiWriteJournal journal;
  late AiHistoryCoordinator history;
  late Account account;
  late Account orphan;
  late DateTime clock;
  var serial = 0;

  AiConflictKey target(String key, int iid) =>
      AiConflictKey([key, 'project:1', 'mergeRequest', '$iid']);

  AiJournalDraft draft(String key, {int iid = 12}) {
    final execution = 'p9-cleanup-${serial++}';
    return AiJournalDraft(
      executionId: execution,
      accountKey: key,
      conversationId: 'conversation-$execution',
      runId: 'run-$execution',
      operationId: 'createNote',
      writeKeys: {target(key, iid)},
      payloadSha256: digest,
      releaseName: '!$iid',
      instance: 'https://synthetic.example/gitlab',
      sessionGeneration: 2,
      normalizedTarget: '!$iid',
      policyRevision: 3,
      summary: 'synthetic metadata',
    );
  }

  Future<String> uncertain(String key, {int iid = 12}) async {
    final value = draft(key, iid: iid);
    await journal.prepare(draft: value);
    await journal.markDispatching(executionId: value.executionId);
    await journal.finish(
      executionId: value.executionId,
      terminal: AiJournalState.writeUncertain,
    );
    return value.executionId;
  }

  /// A removal job that got as far as the removal-start mark.
  Future<void> markRemovalStarted(String key) async {
    final job = journal.beginRemoval(key)..confirmFinal();
    await journal.markRemovalStarted(job);
    job.release(job.token);
  }

  void useJournal(AiStore ai) {
    keys = SharedTombstoneKeys(ai);
    files = AiJournalFiles(root);
    journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'packet9-cleanup',
    )..now = () => clock;
    debugWriteJournalForCleanup = journal;
  }

  Future<void> initialize(Iterable<String> accounts) async {
    await journal.recoverAfterAccountsLoaded(accounts);
    for (final key in accounts) {
      await journal.ensureInitialized(key);
    }
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    AiAccountRemoval.debugReset();
    clock = DateTime.utc(2026, 10, 22, 12);
    root = Directory.systemTemp.createTempSync('packet9-cleanup-');
    memory = MemoryAiStore();
    store = FaultAiStore(memory);
    account = _account(7, 'tester');
    orphan = _account(9, 'gone');
    useJournal(store);
    history = AiHistoryCoordinator.debugReset(
      store: store,
      files: AiHistoryFileStore(
        root: () async => Directory('${root.path}/history')..createSync(),
      ),
    );
  });

  tearDown(() {
    debugWriteJournalForCleanup = null;
    AiAccountRemoval.debugReset();
    AiHistoryCoordinator.debugReset();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('the journal step runs before history and deletes journal, key and reset marker', () async {
    await initialize([account.key]);
    final settled = draft(account.key);
    await journal.prepare(draft: settled);
    await journal.markDispatching(executionId: settled.executionId);
    await journal.finish(
      executionId: settled.executionId,
      terminal: AiJournalState.succeeded,
    );
    store.journalPresentAtHistoryStep = () =>
        File(files.pathFor(account.key)).existsSync() ||
        keys.keys.containsKey(account.key);
    expect(await files.exists(account.key), isTrue);

    await history.clearAccount(account.key);

    expect(store.journalPresentWhenHistoryStarted, isFalse);
    expect(store.steps.first, 'setTombstone');
    expect(store.steps.last, 'clearTombstone');
    expect(await files.exists(account.key), isFalse);
    expect(keys.keys[account.key], isNull);
    expect(keys.resetPending[account.key], isNull);
    expect((await memory.readTombstone(account.key)).value, isNot(true));
    expect(journal.tombstoneFlag(account.key), isFalse);
    expect(history.journalCleanupBlock(account.key), isNull);
    expect(history.state(account.key), AiHistoryState.disabled);
    // Cleared: the journal is uninitialized again.
    expect(
      await journal.keyStatus(account.key),
      AiJournalKeyStatus.uninitialized,
    );
  });

  testWidgets('AI settings sends a journal-held cleanup back to the account list', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await initialize([account.key]);
      await uncertain(account.key, iid: 12);
      await markRemovalStarted(account.key);
      await uncertain(account.key, iid: 13);
      try {
        await history.clearAccount(account.key);
      } on ApiFailure {
        // Held by the uncertain write, as the test below checks in detail.
      }
    });
    expect(history.journalCleanupBlock(account.key), 'retryAccountRemoval');
    final settings = AiSettingsController(memory);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AiSettingsPage(
          settings: settings,
          history: history,
          accountKey: account.key,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A retry here would fail again: the page points to the named removal.
    expect(find.text(l10n.aiRemoveRetryFromAccountList), findsOneWidget);
    expect(find.text(l10n.aiHistoryRetryCleanup), findsNothing);
  });

  test('isolation after the removal-start mark keeps journal and tombstone; settings retry points to the account list; the retry asks for the name', () async {
    await initialize([account.key]);
    await uncertain(account.key, iid: 12);
    await markRemovalStarted(account.key);
    // A row that appeared after the mark (the hold was already released).
    await uncertain(account.key, iid: 13);

    await expectLater(
      history.clearAccount(account.key),
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.aiHistoryCleanup,
        ),
      ),
    );
    expect(history.journalCleanupBlock(account.key), 'retryAccountRemoval');
    expect(await files.exists(account.key), isTrue);
    expect(keys.keys[account.key], isNotNull);
    expect((await memory.readTombstone(account.key)).value, isTrue);
    expect(journal.tombstoneFlag(account.key), isTrue);
    expect(history.state(account.key), AiHistoryState.cleaning);
    expect(store.steps, isNot(contains('deleteHistoryKey')));
    // No new rows while the tombstone stands.
    await expectLater(
      journal.prepare(draft: draft(account.key, iid: 14)),
      throwsA(isA<AiJournalException>()),
    );
    expect(journal.entries(account.key), hasLength(2));

    // The AI settings retry calls clearAccount directly: same refusal.
    await expectLater(
      history.retryCleanup(account.key, isRetained: () => true),
      throwsA(isA<ApiFailure>()),
    );
    expect(history.journalCleanupBlock(account.key), 'retryAccountRemoval');
    expect(await files.exists(account.key), isTrue);

    // Retrying from the account list rereads the journal and asks for @username.
    final accounts = MemoryAccountStore()..accounts = [account];
    final session = SessionController(accounts, readCache: accounts.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    final job = AiAccountRemoval.begin(account.key, journal: journal)!;
    AiRemovalPrompt? shown;
    final result = await AiAccountRemoval.run(
      account: account,
      job: job,
      session: session,
      confirm: (prompt) async {
        shown = prompt;
        return false;
      },
      waitForInFlightWrites: () async {},
      requestCancelOnDispose: () {},
      journal: journal,
      consultJournal: true,
    );
    expect(shown!.kind, AiRemovalPromptKind.typeUsername);
    expect(shown!.count, 2);
    expect(result.reason, 'finalCancelled');
    // Cancelling the removal does not lift the earlier tombstone.
    expect(journal.tombstoneFlag(account.key), isTrue);
    expect((await memory.readTombstone(account.key)).value, isTrue);
  });

  test('the wall clock moving back does not hide rows written after the mark', () async {
    await initialize([account.key]);
    await markRemovalStarted(account.key);
    clock = clock.subtract(const Duration(days: 3));
    await uncertain(account.key);
    await expectLater(history.clearAccount(account.key), throwsA(anything));
    expect(history.journalCleanupBlock(account.key), 'retryAccountRemoval');
    expect(await files.exists(account.key), isTrue);
  });

  test('start-up recovery keeps a listed account\'s journal and clears an unlisted tombstone without a retry notice', () async {
    // Start-up recovery reads the full secure inventory, so it uses the
    // plain memory store.
    useJournal(memory);
    history = AiHistoryCoordinator.debugReset(
      store: memory,
      files: AiHistoryFileStore(
        root: () async => Directory('${root.path}/history')..createSync(),
      ),
    );
    await initialize([account.key, orphan.key]);
    await markRemovalStarted(account.key);
    await uncertain(account.key);
    await uncertain(orphan.key);
    await memory.setTombstone(account.key);
    await memory.setTombstone(orphan.key);

    // Restart with the same secure storage and files. History recovery may
    // run before the journal's own inventory cleanup.
    journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'packet9-restarted',
    )..now = () => clock;
    debugWriteJournalForCleanup = journal;
    final accounts = MemoryAccountStore()..accounts = [account];
    final session = SessionController(accounts, readCache: accounts.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    await history.startRecovery(session);

    expect((await memory.readTombstone(account.key)).value, isTrue);
    expect(await files.exists(account.key), isTrue);
    expect(history.journalCleanupBlock(account.key), 'retryAccountRemoval');
    expect(journal.tombstoneFlag(account.key), isTrue);

    expect((await memory.readTombstone(orphan.key)).value, isNot(true));
    expect(history.journalCleanupBlock(orphan.key), isNull);
    expect(history.state(orphan.key), isNot(AiHistoryState.cleaning));
    // The unlisted journal is left to the journal's inventory and orphan
    // cleanup, which deletes it at the next start.
    await journal.recoverAfterAccountsLoaded([account.key]);
    expect(await files.exists(orphan.key), isFalse);
    expect(await files.exists(account.key), isTrue);
  });

  test('setTombstone throwing after it wrote keeps the in-memory flag; step 4.4 refuses', () async {
    await initialize([account.key]);
    final value = draft(account.key);
    await journal.prepare(draft: value);
    store.throwAfterTombstone = true;
    await expectLater(history.clearAccount(account.key), throwsA(anything));
    expect(journal.tombstoneFlag(account.key), isTrue);
    expect((await memory.readTombstone(account.key)).value, isTrue);
    await expectLater(
      journal.markDispatching(executionId: value.executionId),
      throwsA(isA<AiJournalException>()),
    );
    expect(
      journal.entries(account.key).single.state,
      AiJournalState.prepared,
    );
  });

  test('a history failure after the journal is gone keeps refusing; nothing recreates the journal; a retry finishes', () async {
    await initialize([account.key]);
    final value = draft(account.key);
    await journal.prepare(draft: value);
    store.failDeleteAccount = true;
    await expectLater(history.clearAccount(account.key), throwsA(anything));
    expect(await files.exists(account.key), isFalse);
    expect(keys.keys[account.key], isNull);
    expect((await memory.readTombstone(account.key)).value, isTrue);
    expect(journal.tombstoneFlag(account.key), isTrue);
    // A late transition from the old owner and a new write both fail.
    await expectLater(
      journal.markDispatching(executionId: value.executionId),
      throwsA(isA<AiJournalException>()),
    );
    await expectLater(
      journal.prepare(draft: draft(account.key, iid: 13)),
      throwsA(isA<AiJournalException>()),
    );
    expect(await files.exists(account.key), isFalse);
    expect(keys.keys[account.key], isNull);
    expect(
      await journal.keyStatus(account.key),
      AiJournalKeyStatus.removed,
    );

    // Retrying the removal: no name for the journal, no mark, no new journal.
    store.failDeleteAccount = false;
    final accounts = MemoryAccountStore()..accounts = [account];
    final session = SessionController(accounts, readCache: accounts.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    final job = AiAccountRemoval.begin(account.key, journal: journal)!;
    AiRemovalPrompt? shown;
    final result = await AiAccountRemoval.run(
      account: account,
      job: job,
      session: session,
      confirm: (prompt) async {
        shown = prompt;
        return true;
      },
      waitForInFlightWrites: () async {},
      requestCancelOnDispose: () {},
      journal: journal,
      consultJournal: true,
      clearDrafts: (_) async {},
      clearArtifacts: (_) async {},
      clearRecent: (_) async {},
      clearAi: (saved) => history.clearAccount(saved.key),
    );
    expect(shown!.kind, AiRemovalPromptKind.plainConfirm);
    expect(result.status, AiRemovalStatus.removed);
    expect(await files.exists(account.key), isFalse);
    expect(keys.keys[account.key], isNull);
    expect((await memory.readTombstone(account.key)).value, isNot(true));
    expect(journal.tombstoneFlag(account.key), isFalse);
  });

  test('an unavailable journal key stops the tombstone flow before anything is deleted', () async {
    await initialize([account.key]);
    keys.unavailable = true;
    await expectLater(history.clearAccount(account.key), throwsA(anything));
    keys.unavailable = false;
    expect(history.journalCleanupBlock(account.key), 'unavailable');
    expect(store.steps, isNot(contains('deleteHistoryKey')));
    expect(await files.exists(account.key), isTrue);
    expect(keys.keys[account.key], isNotNull);
    expect((await memory.readTombstone(account.key)).value, isTrue);
  });

  test('a keyMissing journal is deleted as usual', () async {
    await initialize([account.key]);
    await uncertain(account.key);
    keys.keys.remove(account.key);
    await history.clearAccount(account.key);
    expect(await files.exists(account.key), isFalse);
    expect((await memory.readTombstone(account.key)).value, isNot(true));
    expect(history.journalCleanupBlock(account.key), isNull);
  });
}
