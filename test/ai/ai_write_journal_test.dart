import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

const account = 'https://synthetic.example/gitlab#7';
const otherAccount = 'https://synthetic.example/gitlab#8';
const parent = AiConflictKey([account, 'project:1', 'mergeRequest', '12']);
const child = AiConflictKey([
  account,
  'project:1',
  'mergeRequest',
  '12',
  'note',
]);
final digest = List.filled(64, 'a').join();

class FaultFiles extends AiJournalFiles {
  FaultFiles(super.root);
  bool failWrite = false;
  bool failDelete = false;
  Completer<void>? entered;
  Completer<void>? resume;
  @override
  Future<void> write(
    String account,
    Uint8List bytes, {
    required bool Function() mayCommit,
  }) async {
    if (entered != null && !entered!.isCompleted) entered!.complete();
    if (resume != null) await resume!.future;
    if (failWrite) throw const FileSystemException('syntheticWriteFailure');
    await super.write(account, bytes, mayCommit: mayCommit);
  }

  @override
  Future<void> delete(String account) async {
    if (failDelete) throw const FileSystemException('syntheticDeleteFailure');
    await super.delete(account);
  }
}

class StepKeys extends MemoryAiJournalKeyStore {
  String? failStep;
  final List<String> steps = [];
  void step(String name) {
    steps.add(name);
    if (failStep == name) throw StateError('synthetic interruption: $name');
  }

  @override
  Future<void> writeResetPending(String account, DateTime at) async {
    step('marker');
    await super.writeResetPending(account, at);
  }

  @override
  Future<void> deleteKey(String account) async {
    step('deleteKey');
    await super.deleteKey(account);
  }

  @override
  Future<void> writeKey(String account, Uint8List key) async {
    step('writeKey');
    await super.writeKey(account, key);
  }

  @override
  Future<AiStoreRead<Uint8List>> readKey(String account) async {
    step('readKey');
    return super.readKey(account);
  }

  @override
  Future<void> deleteResetPending(String account) async {
    step('deleteMarker');
    await super.deleteResetPending(account);
  }
}

class TestFence implements AiJournalAccountFence {
  bool cleaning = false;
  @override
  bool isCleaning(String account) => cleaning;
  @override
  Future<T> run<T>(String account, Future<T> Function() action) => action();
}

void main() {
  late Directory root;
  late StepKeys keys;
  late FaultFiles files;
  late AiWriteJournal journal;
  late DateTime clock;
  var serial = 0;

  AiWriteJournal owner(String process, {TestFence? fence}) => AiWriteJournal(
    keys: keys,
    applicationSupport: root,
    files: files,
    processId: process,
    fence: fence,
  )..now = () => clock;

  AiJournalDraft draft({
    String? id,
    String accountKey = account,
    String? conversation,
    String? run,
    Set<AiConflictKey>? writes,
    Set<AiConflictKey> dependencies = const {},
    bool confirmed = false,
    bool bypass = false,
    bool tier4 = false,
    bool persistent = true,
    AiBudgetHold? hold,
    String releaseName = '!12',
  }) {
    final execution = id ?? 'execution-${serial++}';
    return AiJournalDraft(
      executionId: execution,
      accountKey: accountKey,
      conversationId: conversation ?? 'conversation-$execution',
      runId: run ?? 'run-$execution',
      operationId: 'createNote',
      writeKeys: writes ?? {parent},
      dependencyKeys: dependencies,
      payloadSha256: digest,
      releaseName: releaseName,
      instance: 'https://synthetic.example/gitlab',
      sessionGeneration: 2,
      normalizedTarget: '!12',
      lastCommitId: 'commit',
      headSha: 'head',
      updatedAt: 'revision',
      mergeCheckSummary: 'redacted',
      policyRevision: 3,
      summary: 'synthetic metadata',
      confirmed: confirmed,
      bypass: bypass,
      tier4: tier4,
      persistConversation: persistent,
      budgetHold: hold,
    );
  }

  Future<String> dispatch({
    String? conversation,
    String? run,
    bool tier4 = false,
    bool persistent = true,
    bool confirmed = false,
    Set<AiConflictKey>? writes,
  }) async {
    final value = draft(
      conversation: conversation,
      run: run,
      tier4: tier4,
      persistent: persistent,
      confirmed: confirmed,
      writes: writes,
    );
    await journal.prepare(draft: value);
    await journal.markDispatching(executionId: value.executionId);
    return value.executionId;
  }

  Future<void> succeed(String id) async {
    await journal.finish(executionId: id, terminal: AiJournalState.succeeded);
  }

  Future<void> initialize() async {
    await journal.recoverAfterAccountsLoaded([account, otherAccount]);
    await journal.ensureInitialized(account);
  }

  Future<Map<String, Object?>> readJson() async => AiHistoryCipher.decryptJson(
    (await files.read(account))!,
    keys.keys[account]!,
    account,
    AiJournalFiles.fileName,
  );
  Future<void> writeJson(Map<String, Object?> value) async {
    final bytes = await AiHistoryCipher.encryptJson(
      value,
      keys.keys[account]!,
      account,
      AiJournalFiles.fileName,
    );
    await files.write(account, bytes, mayCommit: () => true);
  }

  Future<void> uncertainAndRelease() async {
    final id = await dispatch();
    await journal.finish(
      executionId: id,
      terminal: AiJournalState.writeUncertain,
    );
    await journal.releaseByUser(executionId: id, typedName: '!12');
  }

  setUp(() {
    root = Directory(
      Directory.systemTemp.resolveSymbolicLinksSync(),
    ).createTempSync('journal-p2-');
    clock = DateTime.utc(2026, 10, 22, 12);
    keys = StepKeys();
    files = FaultFiles(root);
    journal = owner('process-one');
    serial = 0;
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('§15 row 3 prefix conflict identity and immutable snapshots', () async {
    expect(parent.intersects(child), isTrue);
    expect(child.intersects(parent), isTrue);
    expect(
      parent.intersects(const AiConflictKey([otherAccount, 'project:1'])),
      isFalse,
    );
    final parts = [account, 'project:1'];
    final value = draft(writes: {AiConflictKey(parts)});
    parts.add('changed');
    await initialize();
    final entry = (await journal.prepare(draft: value)).entry;
    expect(entry.writeKeys.single.parts, [account, 'project:1']);
    expect(() => entry.writeKeys.single.parts.add('x'), throwsUnsupportedError);
  });

  test(
    '§15 row 3 recovery blocks writes, first actual write retries failed consent initialization',
    () async {
      await expectLater(
        journal.prepare(draft: draft()),
        throwsA(isA<AiJournalException>()),
      );
      keys.failWrites = true;
      await expectLater(
        journal.ensureInitialized(account),
        throwsA(isA<AiStoreException>()),
      );
      keys.failWrites = false;
      await journal.recoverAfterAccountsLoaded([account]);
      await journal.prepare(draft: draft());
      expect(keys.keys[account]?.length, 32);
      expect(await journal.keyStatus(account), AiJournalKeyStatus.found);
    },
  );

  test(
    '§15 row 3 death before and after dispatch, inactive accounts and same process recovery',
    () async {
      await initialize();
      final prepared = draft();
      await journal.prepare(draft: prepared);
      final sent = await dispatch(
        writes: {
          AiConflictKey([account, 'project:2']),
        },
      );
      await journal.ensureInitialized(otherAccount);
      final other = draft(
        accountKey: otherAccount,
        writes: {
          AiConflictKey([otherAccount, 'project:9']),
        },
      );
      await journal.prepare(draft: other);
      await journal.markDispatching(executionId: other.executionId);
      await journal.recoverAfterAccountsLoaded([account, otherAccount]);
      expect(journal.entries(account).first.state, AiJournalState.prepared);
      expect(journal.entries(account).last.state, AiJournalState.dispatching);
      final restarted = owner('process-two');
      await restarted.recoverAfterAccountsLoaded([account, otherAccount]);
      expect(
        restarted.entries(account).first.state,
        AiJournalState.notExecuted,
      );
      expect(
        restarted.entries(account).last.state,
        AiJournalState.writeUncertain,
      );
      expect(
        restarted.entries(otherAccount).single.state,
        AiJournalState.writeUncertain,
      );
      expect(restarted.isolated(account, {child}), isFalse);
      expect(
        restarted.isolated(account, {
          const AiConflictKey([account, 'project:2']),
        }),
        isTrue,
      );
      expect(
        restarted.conversationWriteCount(account, 'conversation-$sent'),
        1,
      );
    },
  );

  for (final failure in [
    'unavailable',
    'keyMissing',
    'unknownFormat',
    'overSize',
  ]) {
    test('§15 row 3 $failure preserves data and keys, zero mutation', () async {
      await initialize();
      await dispatch();
      final original = File(files.pathFor(account)).readAsBytesSync();
      final oldKey = Uint8List.fromList(keys.keys[account]!);
      if (failure == 'unavailable') keys.unavailable = true;
      if (failure == 'keyMissing') keys.keys.remove(account);
      if (failure == 'unknownFormat') {
        File(files.pathFor(account)).writeAsBytesSync([1, 2, 3]);
      }
      if (failure == 'overSize') {
        File(
          files.pathFor(account),
        ).writeAsBytesSync(Uint8List(AiWriteJournal.ciphertextLimit + 1));
      }
      final before = File(files.pathFor(account)).readAsBytesSync();
      expect((await journal.keyStatus(account)).name, failure);
      var mutations = 0;
      try {
        await journal.prepare(draft: draft());
        mutations++;
      } on Object {
        /* denied */
      }
      expect(mutations, 0);
      expect(File(files.pathFor(account)).readAsBytesSync(), before);
      await expectLater(
        journal.ensureInitialized(account),
        throwsA(isA<AiJournalException>()),
      );
      if (failure != 'keyMissing') expect(keys.keys[account], oldKey);
      expect(original, isNotEmpty);
    });
  }

  test(
    '§15 row 3 unknown authenticated schemas and AAD mismatches are retained',
    () async {
      await initialize();
      final snapshot = await readJson();
      snapshot['future'] = true;
      await writeJson(snapshot);
      expect(
        await journal.keyStatus(account),
        AiJournalKeyStatus.unknownFormat,
      );
      final bytes = await AiHistoryCipher.encryptJson(
        snapshot..remove('future'),
        keys.keys[account]!,
        otherAccount,
        AiJournalFiles.fileName,
      );
      File(files.pathFor(account)).writeAsBytesSync(bytes);
      expect(
        await journal.keyStatus(account),
        AiJournalKeyStatus.unknownFormat,
      );
      expect(File(files.pathFor(account)).readAsBytesSync(), bytes);
    },
  );

  test(
    '§15 row 3 fresh nonce, encrypted metadata only, history-only cleanup is independent',
    () async {
      await initialize();
      final id = await dispatch();
      await journal.finish(
        executionId: id,
        terminal: AiJournalState.writeUncertain,
      );
      final before = await files.read(account);
      await journal.recordObservation(
        executionId: id,
        summary: 'currently visible',
      );
      final after = await files.read(account);
      expect(before!.sublist(1, 13), isNot(after!.sublist(1, 13)));
      expect(
        utf8.decode(after, allowMalformed: true),
        isNot(contains('currently visible')),
      );
      final history = AiHistoryFileStore(
        root: () async => Directory('${root.path}/ai_history'),
      );
      await history.deleteAccount(account);
      expect(journal.isolated(account, {child}), isTrue);
      expect(journal.conversationWriteCount(account, 'conversation-$id'), 1);
      final json = await readJson();
      expect(jsonEncode(json), isNot(contains('replay')));
      expect(jsonEncode(json), isNot(contains('markdown')));
      expect(jsonEncode(json), isNot(contains('attachmentBytes')));
    },
  );

  test(
    '§15 row 3 history toggles, stuck clear marker and provider reset preserve journal state',
    () async {
      await initialize();
      final unresolved = await dispatch(conversation: 'persistent-count');
      await journal.finish(
        executionId: unresolved,
        terminal: AiJournalState.writeUncertain,
      );
      const releasedKey = AiConflictKey([account, 'project:2']);
      final released = await dispatch(writes: {releasedKey});
      await journal.finish(
        executionId: released,
        terminal: AiJournalState.writeUncertain,
      );
      await journal.releaseByUser(executionId: released, typedName: '!12');
      final encrypted = await files.read(account);
      final journalKey = Uint8List.fromList(keys.keys[account]!);
      final historyStore = MemoryAiStore();
      final historyFiles = AiHistoryFileStore(root: () async => root);
      final history = AiHistoryCoordinator(
        store: historyStore,
        files: historyFiles,
      );
      final settings = AiSettingsController(historyStore);
      addTearDown(history.dispose);
      addTearDown(settings.dispose);

      Future<void> expectPreserved() async {
        expect(await files.read(account), encrypted);
        expect(keys.keys[account], journalKey);
        expect(journal.isolated(account, {child}), isTrue);
        expect(journal.requiresConfirmation(account, {releasedKey}), isTrue);
        expect(journal.conversationWriteCount(account, 'persistent-count'), 1);
      }

      expect(await history.enable(account), AiHistoryState.ready);
      await expectPreserved();
      Directory(
        '${root.path}/ai_history/${aiHistoryAccountSegment(account)}',
      ).createSync(recursive: true);
      final originalDelete = removeAiHistoryDirectory;
      try {
        removeAiHistoryDirectory = (_) =>
            throw const FileSystemException('syntheticHistoryClearFailure');
        await expectLater(
          history.clearHistory(account),
          throwsA(isA<Object>()),
        );
        expect(
          (await historyStore.readHistoryClearMarker(account)).value,
          true,
        );
        expect(await history.enable(account), AiHistoryState.readFailed);
        await expectPreserved();
      } finally {
        removeAiHistoryDirectory = originalDelete;
      }
      await history.clearHistory(account);
      expect(
        (await historyStore.readHistoryClearMarker(account)).value,
        isNull,
      );
      await expectPreserved();
      expect(await history.enable(account), AiHistoryState.ready);
      await history.disable(account);
      expect(await history.enable(account), AiHistoryState.ready);
      await expectPreserved();
      await settings.initialize();
      await settings.resetProviders();
      await expectPreserved();
      journal = owner('process-after-history-settings');
      await journal.recoverAfterAccountsLoaded([account, otherAccount]);
      await expectPreserved();
    },
  );

  test(
    '§15 rows 3,29 pre-dispatch flush failure is zero mutation and no counter',
    () async {
      await initialize();
      final value = draft();
      await journal.prepare(draft: value);
      files.failWrite = true;
      var mutations = 0;
      try {
        await journal.markDispatching(executionId: value.executionId);
        mutations++;
      } on Object {
        /* denied */
      }
      expect(mutations, 0);
      expect(journal.entries(account).single.state, AiJournalState.prepared);
      expect(journal.getConversationCount(account), 0);
      files.failWrite = false;
      await journal.finish(
        executionId: value.executionId,
        terminal: AiJournalState.notExecuted,
      );
    },
  );

  test(
    '§15 rows 3,29 terminal flush failure is uncertain now, dispatching on disk, release must persist',
    () async {
      await initialize();
      final id = await dispatch();
      files.failWrite = true;
      await expectLater(succeed(id), throwsA(isA<FileSystemException>()));
      expect(
        journal.entries(account).single.state,
        AiJournalState.writeUncertain,
      );
      expect(
        (await readJson())['entries'],
        contains(isA<Map<String, Object?>>()),
      );
      expect(
        ((await readJson())['entries']! as List<Object?>).single,
        containsPair('state', 'dispatching'),
      );
      expect(journal.isolated(account, {child}), isTrue);
      await expectLater(
        journal.releaseByUser(executionId: id, typedName: '!12'),
        throwsA(isA<FileSystemException>()),
      );
      expect(journal.isolated(account, {child}), isTrue);
      files.failWrite = false;
      await journal.releaseByUser(executionId: id, typedName: '!12');
      expect(
        journal.entries(account).single.state,
        AiJournalState.resolvedByUser,
      );
      expect(journal.requiresConfirmation(account, {child}), isTrue);
    },
  );

  test(
    '§15 rows 3,29 only explicit revert restores marks and budgets atomically',
    () async {
      await initialize();
      await uncertainAndRelease();
      final id = await dispatch(confirmed: true);
      expect(journal.requiresConfirmation(account, {child}), isFalse);
      await expectLater(
        journal.finish(executionId: id, terminal: AiJournalState.notExecuted),
        throwsA(isA<AiJournalException>()),
      );
      files.failWrite = true;
      await expectLater(
        journal.revertDispatchingToNotExecuted(executionId: id),
        throwsA(isA<FileSystemException>()),
      );
      expect(journal.entries(account).last.state, AiJournalState.dispatching);
      expect(journal.requiresConfirmation(account, {child}), isFalse);
      expect(journal.conversationWriteCount(account, 'conversation-$id'), 1);
      files.failWrite = false;
      final mutation = await journal.revertDispatchingToNotExecuted(
        executionId: id,
      );
      expect(mutation.budgetRefunded, isTrue);
      expect(mutation.confirmMarkRestored, isTrue);
      expect(journal.requiresConfirmation(account, {child}), isTrue);
      expect(journal.conversationWriteCount(account, 'conversation-$id'), 0);
    },
  );

  test(
    '§15 row 3 observation never releases; original Unicode name survives restart',
    () async {
      await initialize();
      final value = draft(releaseName: 'ملف🙂.txt');
      await journal.prepare(draft: value);
      await journal.markDispatching(executionId: value.executionId);
      journal = owner('process-two');
      await journal.recoverAfterAccountsLoaded([account]);
      await journal.recordObservation(
        executionId: value.executionId,
        summary: 'not found or inaccessible',
      );
      expect(journal.isolated(account, {child}), isTrue);
      await expectLater(
        journal.releaseByUser(
          executionId: value.executionId,
          typedName: '\u2068ملف🙂.txt\u2069',
        ),
        throwsA(isA<AiJournalException>()),
      );
      await journal.releaseByUser(
        executionId: value.executionId,
        typedName: 'ملف🙂.txt',
      );
      expect(journal.requiresConfirmation(account, {child}), isTrue);
    },
  );

  test(
    '§15 row 3 marks and conversation counts outlive 7 days and 200 evicted details',
    () async {
      await initialize();
      await uncertainAndRelease();
      clock = clock.add(const Duration(days: 8));
      final touch = draft(
        writes: {
          AiConflictKey([account, 'project:3']),
        },
      );
      await journal.prepare(draft: touch);
      await journal.finish(
        executionId: touch.executionId,
        terminal: AiJournalState.notExecuted,
      );
      expect(journal.requiresConfirmation(account, {child}), isTrue);
      final snapshot = await readJson();
      final template =
          (snapshot['entries']! as List<Object?>).last! as Map<String, Object?>;
      snapshot['entries'] = List.generate(
        200,
        (i) => <String, Object?>{
          ...template,
          'execution': 'evict-$i',
          'sequence': i + 2,
          'createdAt': clock
              .subtract(const Duration(hours: 2))
              .toIso8601String(),
        },
      );
      snapshot['sequence'] = 201;
      await writeJson(snapshot);
      journal = owner('process-two');
      await journal.recoverAfterAccountsLoaded([account]);
      final next = draft(
        writes: {
          AiConflictKey([account, 'project:4']),
        },
      );
      await journal.prepare(draft: next);
      expect(journal.entries(account).length, 200);
      expect(journal.requiresConfirmation(account, {child}), isTrue);
      expect(
        journal.conversationWriteCount(account, 'conversation-execution-0'),
        1,
      );
      await expectLater(
        journal.prepare(draft: draft()),
        throwsA(isA<AiJournalException>()),
      );
      final confirmed = draft(confirmed: true);
      await journal.prepare(draft: confirmed);
      await journal.finish(
        executionId: confirmed.executionId,
        terminal: AiJournalState.notExecuted,
      );
      expect(journal.requiresConfirmation(account, {child}), isTrue);
    },
  );

  test(
    '§15 row 19 prepared and zero-write conversations create no counts, holds refund',
    () async {
      await initialize();
      for (var i = 0; i < 12; i++) {
        final value = draft();
        await journal.prepare(draft: value);
        await journal.finish(
          executionId: value.executionId,
          terminal: AiJournalState.notExecuted,
        );
      }
      final hold = await journal.tryReserve(
        const AiBudgetRequest(
          accountKey: account,
          conversationId: 'held',
          runId: 'held',
        ),
      );
      expect(hold, isNotNull);
      await journal.refund(hold!);
      await journal.refund(hold);
      expect(journal.getConversationCount(account), 0);
      await expectLater(
        journal.prepare(
          draft: draft(conversation: 'held', run: 'held', hold: hold),
        ),
        throwsA(isA<AiJournalException>()),
      );
    },
  );

  test(
    '§15 row 19 run 8/3 and batch 20 boundaries include concurrent reservations',
    () async {
      await initialize();
      final holds = <AiBudgetHold>[];
      for (var i = 0; i < 8; i++) {
        final hold = await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'c',
            runId: 'r',
          ),
        );
        expect(hold, isNotNull);
        holds.add(hold!);
      }
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'c',
            runId: 'r',
          ),
        ),
        isNull,
      );
      for (final hold in holds) {
        await journal.refund(hold);
      }
      for (var i = 0; i < 3; i++) {
        expect(
          await journal.tryReserve(
            const AiBudgetRequest(
              accountKey: account,
              conversationId: 't4',
              runId: 't4',
              tier4: true,
            ),
          ),
          isNotNull,
        );
      }
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 't4',
            runId: 't4',
            tier4: true,
          ),
        ),
        isNull,
      );
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'batch',
            runId: 'batch',
            affectedResources: 21,
          ),
        ),
        isNull,
      );
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'batch',
            runId: 'batch',
            affectedResources: 20,
          ),
        ),
        isNotNull,
      );
    },
  );

  test(
    '§15 row 19 three conversations share rolling hour 60; exact hour stays protected',
    () async {
      await initialize();
      for (var i = 0; i < 60; i++) {
        final id = await dispatch(conversation: 'c${i % 3}');
        await succeed(id);
      }
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'c0',
            runId: 'new',
          ),
        ),
        isNull,
      );
      clock = clock.add(const Duration(hours: 1));
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'c0',
            runId: 'new',
          ),
        ),
        isNull,
      );
      clock = clock.add(const Duration(microseconds: 1));
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'c0',
            runId: 'new',
          ),
        ),
        isNotNull,
      );
    },
  );

  test(
    '§15 row 19 conversation 40 survives restart and segment/run changes',
    () async {
      await initialize();
      for (var i = 0; i < 40; i++) {
        await succeed(await dispatch(conversation: 'persistent'));
      }
      clock = clock.add(const Duration(days: 8));
      journal = owner('process-two');
      await journal.recoverAfterAccountsLoaded([account]);
      expect(journal.conversationWriteCount(account, 'persistent'), 40);
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'persistent',
            runId: 'new-segment',
          ),
        ),
        isNull,
      );
      await journal.touchConversation(account, 'persistent');
      clock = clock.add(const Duration(days: 89));
      final value = draft();
      await journal.prepare(draft: value);
      expect(journal.conversationWriteCount(account, 'persistent'), 40);
    },
  );

  test(
    '§15 row 19 history disabled counters stay process local across restart',
    () async {
      await initialize();
      await succeed(
        await dispatch(conversation: 'no-history', persistent: false),
      );
      expect(journal.conversationWriteCount(account, 'no-history'), 1);
      expect((await readJson())['counts'], isEmpty);
      journal = owner('process-two');
      await journal.recoverAfterAccountsLoaded([account]);
      expect(journal.conversationWriteCount(account, 'no-history'), 0);
    },
  );

  test(
    '§15 row 19 T4 account and conversation ceilings use controlled clock',
    () async {
      await initialize();
      for (var i = 0; i < 10; i++) {
        await succeed(await dispatch(conversation: 't4', tier4: true));
      }
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'another',
            runId: 'new',
            tier4: true,
          ),
        ),
        isNull,
      );
      clock = clock.add(const Duration(hours: 2));
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 't4',
            runId: 'new',
            tier4: true,
          ),
        ),
        isNull,
      );
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'another',
            runId: 'new',
            tier4: true,
          ),
        ),
        isNotNull,
      );
    },
  );

  test(
    '§15 row 19 2000 counters retained; existing conversation works, 2001st denied',
    () async {
      await initialize();
      final snapshot = await readJson();
      snapshot['counts'] = <String, Object?>{
        for (var i = 0; i < 2000; i++)
          'conversation-$i': [1, 0, clock.toIso8601String()],
      };
      await writeJson(snapshot);
      journal = owner('process-two');
      await journal.recoverAfterAccountsLoaded([account]);
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'new',
            runId: 'new',
          ),
        ),
        isNull,
      );
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'conversation-1999',
            runId: 'new',
          ),
        ),
        isNotNull,
      );
      expect(journal.getConversationCount(account), 2000);
    },
  );

  test(
    '§15 row 19 exact 1 MiB ciphertext accepted, next save refuses growth',
    () async {
      await initialize();
      final id = await dispatch();
      await succeed(id);
      final snapshot = await readJson();
      final entry =
          (snapshot['entries']! as List<Object?>).single!
              as Map<String, Object?>;
      final length = utf8.encode(jsonEncode(snapshot)).length + 29;
      entry['summary'] =
          'x' *
          ((entry['summary']! as String).length +
              AiWriteJournal.ciphertextLimit -
              length);
      await writeJson(snapshot);
      expect(
        File(files.pathFor(account)).lengthSync(),
        AiWriteJournal.ciphertextLimit,
      );
      expect(await journal.keyStatus(account), AiJournalKeyStatus.found);
      await expectLater(
        journal.prepare(draft: draft()),
        throwsA(
          isA<AiJournalException>().having(
            (e) => e.reason,
            'reason',
            'storageLimit',
          ),
        ),
      );
      expect(
        File(files.pathFor(account)).lengthSync(),
        AiWriteJournal.ciphertextLimit,
      );
    },
  );

  test(
    '§15 row 3 unresolved isolation never evicts at 200 details or 7 days',
    () async {
      await initialize();
      await dispatch();
      final snapshot = await readJson();
      final template =
          (snapshot['entries']! as List<Object?>).single!
              as Map<String, Object?>;
      snapshot['entries'] = List.generate(
        200,
        (i) => <String, Object?>{
          ...template,
          'execution': 'isolation-$i',
          'sequence': i + 1,
          'writes': [
            [account, 'project:$i'],
          ],
        },
      );
      snapshot['sequence'] = 200;
      await writeJson(snapshot);
      clock = clock.add(const Duration(days: 8));
      journal = owner('process-two');
      await journal.recoverAfterAccountsLoaded([account]);
      expect(journal.entries(account).length, 200);
      expect(
        journal
            .entries(account)
            .every((e) => e.state == AiJournalState.writeUncertain),
        isTrue,
      );
      await expectLater(
        journal.prepare(
          draft: draft(
            writes: {
              AiConflictKey([account, 'project:999']),
            },
          ),
        ),
        throwsA(isA<AiJournalException>()),
      );
    },
  );

  for (final step in [
    'marker',
    'deleteFile',
    'deleteKey',
    'writeKey',
    'readBack',
    'initialFile',
    'deleteMarker',
  ]) {
    test(
      '§15 rows 3,31 reset interrupted at $step resumes with durable 24h mark',
      () async {
        await initialize();
        final id = await dispatch();
        final original = (await files.read(account))!;
        final originalKey = Uint8List.fromList(keys.keys[account]!);
        final reset = await journal.beginReset(
          account,
          verifiedUsername: '@synthetic',
        );
        if (step == 'deleteFile') files.failDelete = true;
        if (step == 'initialFile') files.failWrite = true;
        if (step == 'readBack') {
          // The reset path reads tombstone, then writes its marker, deletes key,
          // writes a fresh key, then reads it. Fail only this new-key readback.
          keys.failStep = null;
        } else if (!['deleteFile', 'initialFile'].contains(step)) {
          keys.failStep = step;
        }
        if (step == 'readBack') {
          // A malformed new-key read is injected via the store's read step; no
          // pre-reset key reads occur in completeReset.
          keys.failStep = 'readKey';
        }
        await expectLater(
          journal.completeReset(reset, typedUsername: '@synthetic'),
          throwsA(isA<Object>()),
        );
        if (step == 'marker') {
          expect(keys.resetPending, isEmpty);
          expect(await files.read(account), original);
          expect(keys.keys[account], originalKey);
        } else {
          expect(keys.resetPending.containsKey(account), isTrue);
        }
        keys.failStep = null;
        files.failDelete = false;
        files.failWrite = false;
        journal = owner('process-restart');
        clock = clock.add(const Duration(days: 2));
        await journal.recoverAfterAccountsLoaded([account]);
        if (step == 'marker') {
          expect(
            journal.entries(account).single.state,
            AiJournalState.writeUncertain,
          );
        } else {
          expect(keys.resetPending, isEmpty);
          expect(journal.entries(account), isEmpty);
          expect(journal.recentlyReset(account), isTrue);
          expect(journal.requiresConfirmation(account, {child}), isTrue);
          await expectLater(
            journal.finish(executionId: id, terminal: AiJournalState.succeeded),
            throwsA(isA<AiJournalException>()),
          );
          final value = draft(bypass: true);
          await journal.prepare(draft: value);
          await journal.finish(
            executionId: value.executionId,
            terminal: AiJournalState.notExecuted,
          );
          clock = clock.add(const Duration(hours: 24));
          expect(journal.recentlyReset(account), isFalse);
        }
      },
    );
  }

  test(
    '§15 row 31 wrong name and changed approval epoch never write reset marker',
    () async {
      await initialize();
      final before = await files.read(account);
      final reset = await journal.beginReset(
        account,
        verifiedUsername: '@synthetic',
      );
      await expectLater(
        journal.completeReset(reset, typedUsername: '@wrong'),
        throwsA(isA<AiJournalException>()),
      );
      journal.bumpProposalEpoch(account);
      await expectLater(
        journal.completeReset(reset, typedUsername: '@synthetic'),
        throwsA(isA<AiJournalException>()),
      );
      expect(keys.resetPending, isEmpty);
      expect(await files.read(account), before);
      journal.cancelReset(reset);
    },
  );

  test(
    '§15 rows 3,29 reset during dispatch flush invalidates old commit and late callback',
    () async {
      await initialize();
      final value = draft();
      await journal.prepare(draft: value);
      files.entered = Completer<void>();
      files.resume = Completer<void>();
      final pending = journal.markDispatching(executionId: value.executionId);
      final failure = expectLater(pending, throwsA(isA<AiJournalException>()));
      await files.entered!.future;
      final reset = await journal.beginReset(
        account,
        verifiedUsername: '@synthetic',
      );
      files.resume!.complete();
      await failure;
      files.entered = null;
      files.resume = null;
      await journal.completeReset(reset, typedUsername: '@synthetic');
      await expectLater(
        journal.finish(
          executionId: value.executionId,
          terminal: AiJournalState.succeeded,
        ),
        throwsA(isA<AiJournalException>()),
      );
      expect(journal.entries(account), isEmpty);
    },
  );

  test(
    '§15 row 31 removal hold is process-owned, independent of cleaning, token safe',
    () async {
      final fence = TestFence();
      journal = owner('process-one', fence: fence);
      await initialize();
      final id = await dispatch();
      final epoch = journal.proposalEpoch(account);
      final job = journal.beginRemoval(account);
      expect(journal.proposalEpoch(account), epoch);
      expect(fence.cleaning, isFalse);
      expect(
        () => journal.beginRemoval(account),
        throwsA(isA<AiJournalException>()),
      );
      expect(journal.beginReset(account), throwsA(isA<AiJournalException>()));
      await expectLater(
        journal.prepare(draft: draft()),
        throwsA(isA<AiJournalException>()),
      );
      await journal.finish(
        executionId: id,
        terminal: AiJournalState.writeUncertain,
      );
      job.requestCancel();
      expect(job.cancelRequestedBeforeFinalConfirm, isTrue);
      expect(job.holds(job.token), isTrue);
      job.release(job.token);
      expect(journal.proposalEpoch(account), epoch);
      final retry = journal.beginRemoval(account);
      job.release(job.token);
      expect(retry.holds(retry.token), isTrue);
      retry.confirmFinal();
      final confirmedEpoch = journal.proposalEpoch(account);
      retry.requestCancel();
      expect(retry.cancelRequestedBeforeFinalConfirm, isFalse);
      expect(journal.proposalEpoch(account), confirmedEpoch);
      retry.release(retry.token);
      expect(journal.isolated(account, {child}), isTrue);
    },
  );

  test(
    '§15 row 31 final cancellation bumps epoch synchronously, keeps isolation and tombstone',
    () async {
      await initialize();
      await dispatch();
      journal.noteTombstoneSet(account);
      final job = journal.beginRemoval(account);
      final epoch = journal.proposalEpoch(account);
      job.cancelFinal();
      expect(journal.proposalEpoch(account), epoch + 1);
      expect(journal.removalHeld(account), isFalse);
      expect(journal.tombstoneFlag(account), isTrue);
      expect(journal.entries(account).single.state, AiJournalState.dispatching);
    },
  );

  test(
    '§15 row 31 removal watermark uses sequence, late uncertain write prevents cleanup',
    () async {
      await initialize();
      final id = await dispatch();
      await journal.finish(
        executionId: id,
        terminal: AiJournalState.writeUncertain,
      );
      final job = journal.beginRemoval(account)..confirmFinal();
      await journal.markRemovalStarted(job);
      expect(await journal.mayCleanupTombstone(account), isTrue);
      final snapshot = await readJson();
      final entry = Map<String, Object?>.from(
        (snapshot['entries']! as List<Object?>).single! as Map<String, Object?>,
      );
      entry['execution'] = 'late';
      entry['sequence'] = 2;
      entry['createdAt'] = clock
          .subtract(const Duration(days: 1))
          .toIso8601String();
      snapshot['sequence'] = 2;
      (snapshot['entries']! as List<Object?>).add(entry);
      await writeJson(snapshot);
      keys.tombstones.add(account);
      journal.noteTombstoneSet(account);
      job.release(job.token);
      clock = clock.subtract(const Duration(days: 3));
      journal = owner('restarted');
      await journal.recoverAfterAccountsLoaded([account]);
      expect(await journal.mayCleanupTombstone(account), isFalse);
      await expectLater(
        journal.clearForRemoval(account),
        throwsA(
          isA<AiJournalException>().having(
            (e) => e.reason,
            'reason',
            'retryAccountRemoval',
          ),
        ),
      );
      expect(await files.exists(account), isTrue);
      expect(keys.tombstones, contains(account));
    },
  );

  test(
    '§15 row 31 unavailable removal marker fails; removed keys/files never recreated by late finish',
    () async {
      await initialize();
      final value = draft();
      await journal.prepare(draft: value);
      final job = journal.beginRemoval(account)..confirmFinal();
      files.failWrite = true;
      await expectLater(
        journal.markRemovalStarted(job),
        throwsA(isA<FileSystemException>()),
      );
      files.failWrite = false;
      await journal.markRemovalStarted(job);
      keys.tombstones.add(account);
      journal.noteTombstoneSet(account);
      job.release(job.token);
      await expectLater(
        journal.markDispatching(executionId: value.executionId),
        throwsA(isA<AiJournalException>()),
      );
      await journal.clearForRemoval(account);
      expect(await journal.keyStatus(account), AiJournalKeyStatus.removed);
      final retry = journal.beginRemoval(account)..confirmFinal();
      await journal.markRemovalStarted(retry);
      retry.release(retry.token);
      await expectLater(
        journal.finish(
          executionId: value.executionId,
          terminal: AiJournalState.notExecuted,
        ),
        throwsA(isA<AiJournalException>()),
      );
      expect(await files.exists(account), isFalse);
      expect(keys.keys[account], isNull);
    },
  );

  test(
    '§15 row 3 orphan cleanup only after successful accounts inventory; symlinks refused',
    () async {
      await initialize();
      await dispatch();
      keys.unavailable = true;
      await expectLater(
        journal.recoverAfterAccountsLoaded([]),
        throwsA(isA<AiStoreException>()),
      );
      expect(await files.exists(account), isTrue);
      keys.unavailable = false;
      await journal.recoverAfterAccountsLoaded([]);
      expect(await files.exists(account), isFalse);
      expect(keys.keys, isEmpty);
      final outside = Directory('${root.path}/outside')..createSync();
      final accountDirectory = File(files.pathFor(account)).parent;
      accountDirectory.parent.createSync(recursive: true);
      Link(accountDirectory.path).createSync(outside.path);
      expect(await journal.keyStatus(account), AiJournalKeyStatus.unavailable);
      expect(outside.listSync(), isEmpty);
    },
  );
  test(
    '§15 rows 3,31 transient tombstone read failure retries without clearing a real tombstone',
    () async {
      await initialize();
      keys.unavailable = true;
      expect(await journal.keyStatus(account), AiJournalKeyStatus.unavailable);
      expect(journal.tombstoneFlag(account), isTrue);
      keys.unavailable = false;
      expect(await journal.keyStatus(account), AiJournalKeyStatus.found);
      expect(journal.tombstoneFlag(account), isFalse);
      await journal.prepare(draft: draft());
      journal.noteTombstoneSet(account);
      expect(await journal.keyStatus(account), AiJournalKeyStatus.found);
      expect(journal.tombstoneFlag(account), isTrue);
      await expectLater(
        journal.prepare(draft: draft()),
        throwsA(isA<AiJournalException>()),
      );
    },
  );

  test(
    '§15 row 19 invalidating proposals refunds unattached holds without losing committed budgets',
    () async {
      await initialize();
      for (var i = 0; i < 8; i++) {
        expect(
          await journal.tryReserve(
            const AiBudgetRequest(
              accountKey: account,
              conversationId: 'c',
              runId: 'r',
            ),
          ),
          isNotNull,
        );
      }
      journal.bumpProposalEpoch(account);
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'c',
            runId: 'r',
          ),
        ),
        isNotNull,
      );
      expect(journal.getConversationCount(account), 0);
    },
  );

  test(
    '§15 row 19 last counter slot may be shared by multiple pending writes in one conversation',
    () async {
      await initialize();
      final snapshot = await readJson();
      snapshot['counts'] = <String, Object?>{
        for (var i = 0; i < 1999; i++)
          'old-$i': [1, 0, clock.toIso8601String()],
      };
      await writeJson(snapshot);
      for (var i = 0; i < 2; i++) {
        expect(
          await journal.tryReserve(
            const AiBudgetRequest(
              accountKey: account,
              conversationId: 'last',
              runId: 'new',
            ),
          ),
          isNotNull,
        );
      }
      expect(
        await journal.tryReserve(
          const AiBudgetRequest(
            accountKey: account,
            conversationId: 'overflow',
            runId: 'new',
          ),
        ),
        isNull,
      );
    },
  );

  test(
    '§15 row 3 schema field substitution is unknown, not silently normalized',
    () async {
      await initialize();
      await dispatch();
      final snapshot = await readJson();
      final entry =
          (snapshot['entries']! as List<Object?>).single!
              as Map<String, Object?>;
      entry.remove('observation');
      entry['futureObservation'] = null;
      await writeJson(snapshot);
      expect(
        await journal.keyStatus(account),
        AiJournalKeyStatus.unknownFormat,
      );
    },
  );

  test(
    '§15 rows 3,29 proposal epoch or removal during flush denies mutation and permits atomic revert',
    () async {
      await initialize();
      await uncertainAndRelease();
      final value = draft(confirmed: true);
      await journal.prepare(draft: value);
      files.entered = Completer<void>();
      files.resume = Completer<void>();
      final pending = journal.markDispatching(executionId: value.executionId);
      final failure = expectLater(pending, throwsA(isA<AiJournalException>()));
      await files.entered!.future;
      final removal = journal.beginRemoval(account);
      removal.cancelFinal();
      files.resume!.complete();
      await failure;
      files.entered = null;
      files.resume = null;
      expect(journal.entries(account).last.state, AiJournalState.prepared);
      await journal.finish(
        executionId: value.executionId,
        terminal: AiJournalState.notExecuted,
      );
      expect(journal.requiresConfirmation(account, {child}), isTrue);
      expect(journal.conversationWriteCount(account, value.conversationId), 0);
    },
  );
  test(
    '§15 row 3 trusted support alias works, journal descendant links still refuse reads',
    () async {
      final alias = Link('${root.path}/support-alias')..createSync(root.path);
      final aliased = AiWriteJournal(
        keys: keys,
        applicationSupport: Directory(alias.path),
      );
      await aliased.recoverAfterAccountsLoaded([account]);
      await aliased.ensureInitialized(account);
      expect(await aliased.keyStatus(account), AiJournalKeyStatus.found);
      final directory = File(files.pathFor(account)).parent;
      directory.deleteSync(recursive: true);
      final target = Directory('${root.path}/foreign')..createSync();
      Link(directory.path).createSync(target.path);
      expect(await aliased.keyStatus(account), AiJournalKeyStatus.unavailable);
      alias.deleteSync();
    },
  );

  test(
    '§15 row 3 crash-left journal temporaries are pruned without touching other files',
    () async {
      await initialize();
      final temp = File('${files.pathFor(account)}.${'a' * 32}.tmp')
        ..writeAsBytesSync([1, 2, 3]);
      final unknown = File('${files.pathFor(account)}.future')
        ..writeAsBytesSync([4]);
      await journal.recoverAfterAccountsLoaded([account]);
      expect(temp.existsSync(), isFalse);
      expect(unknown.readAsBytesSync(), [4]);
      expect(await journal.keyStatus(account), AiJournalKeyStatus.found);
    },
  );

  test(
    '§15 rows 3,31 canceled reset preserves unknown isolation and allows typed release',
    () async {
      await initialize();
      final id = await dispatch();
      final before = await files.read(account);
      final reset = await journal.beginReset(
        account,
        verifiedUsername: '@synthetic',
      );
      journal.cancelReset(reset);
      await expectLater(succeed(id), throwsA(isA<AiJournalException>()));
      expect(await files.read(account), before);
      expect(journal.lateAudit.single.state, AiJournalState.writeUncertain);
      expect(journal.isolated(account, {child}), isTrue);
      await journal.releaseByUser(executionId: id, typedName: '!12');
      expect(journal.isolated(account, {child}), isFalse);
      expect(journal.requiresConfirmation(account, {child}), isTrue);
    },
  );

  test(
    '§15 rows 3,31 reset completion keeps late terminal audit in memory without rebuilding old journal',
    () async {
      await initialize();
      final id = await dispatch();
      final reset = await journal.beginReset(
        account,
        verifiedUsername: '@synthetic',
      );
      await journal.completeReset(reset, typedUsername: '@synthetic');
      final before = await files.read(account);
      await expectLater(succeed(id), throwsA(isA<AiJournalException>()));
      expect(await files.read(account), before);
      expect(journal.entries(account), isEmpty);
      expect(journal.lateAudit.single.executionId, id);
    },
  );
  test(
    '§15 row 31 pessimistic tombstone flag alone never authorizes journal deletion',
    () async {
      await initialize();
      journal.noteTombstoneSet(account);
      await expectLater(
        journal.clearForRemoval(account),
        throwsA(
          isA<AiJournalException>().having(
            (e) => e.reason,
            'reason',
            'tombstoneRequired',
          ),
        ),
      );
      expect(await files.exists(account), isTrue);
      expect(keys.keys[account], isNotNull);
    },
  );
}
