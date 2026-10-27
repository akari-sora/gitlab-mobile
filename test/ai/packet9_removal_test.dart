import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import '../session_test.dart' show MemoryAccountStore;

final digest = List.filled(64, 'a').join();

Account _account(int id, String username) => Account(
  instance: GitLabInstance.parse('https://synthetic.example/gitlab'),
  user: GitLabUser(id: id, username: username, name: 'Synthetic $username'),
  token: 'synthetic-test-token-$id',
);

/// Holds a journal flush (the barrier) or fails it.
class BarrierFiles extends AiJournalFiles {
  BarrierFiles(super.root);
  bool failWrite = false;
  Completer<void>? entered;
  Completer<void>? resume;

  @override
  Future<void> write(
    String account,
    Uint8List bytes, {
    required bool Function() mayCommit,
  }) async {
    if (entered != null && !entered!.isCompleted) entered!.complete();
    final gate = resume;
    if (gate != null) await gate.future;
    if (failWrite) throw const FileSystemException('syntheticWriteFailure');
    await super.write(account, bytes, mayCommit: mayCommit);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MemoryAiJournalKeyStore keys;
  late BarrierFiles files;
  late AiWriteJournal journal;
  late MemoryAccountStore accountStore;
  late SessionController session;
  late Account account;
  late Account other;
  late List<String> calls;
  var serial = 0;

  AiConflictKey target(String key) =>
      AiConflictKey([key, 'project:1', 'mergeRequest', '12']);

  AiJournalDraft draft(String key) {
    final execution = 'p9-execution-${serial++}';
    return AiJournalDraft(
      executionId: execution,
      accountKey: key,
      conversationId: 'conversation-$execution',
      runId: 'run-$execution',
      operationId: 'createNote',
      writeKeys: {target(key)},
      payloadSha256: digest,
      releaseName: '!12',
      instance: 'https://synthetic.example/gitlab',
      sessionGeneration: 2,
      normalizedTarget: '!12',
      policyRevision: 3,
      summary: 'synthetic metadata',
    );
  }

  Future<String> dispatch(String key) async {
    final value = draft(key);
    await journal.prepare(draft: value);
    await journal.markDispatching(executionId: value.executionId);
    return value.executionId;
  }

  Future<void> initialize() async {
    await journal.recoverAfterAccountsLoaded([account.key, other.key]);
    await journal.ensureInitialized(account.key);
  }

  Future<void> step(String name) async {
    calls.add(name);
  }

  Future<AiRemovalResult> remove({
    required AiRemovalJob job,
    required Future<bool> Function(AiRemovalPrompt prompt) confirm,
    Future<void> Function()? wait,
    int runningOrPending = 0,
    void Function(bool waiting)? onWaiting,
    Duration waitLimit = AiAccountRemoval.writeWaitLimit,
    Duration journalLimit = AiAccountRemoval.journalWaitLimit,
    Future<void> Function(Account)? clearDrafts,
    Future<void> Function(Account)? clearArtifacts,
    Future<void> Function(Account)? clearRecent,
    Future<void> Function(Account)? clearAi,
  }) => AiAccountRemoval.run(
    account: account,
    job: job,
    session: session,
    confirm: confirm,
    waitForInFlightWrites: wait ?? () async {},
    requestCancelOnDispose: () => calls.add('armDispose'),
    runningOrPending: runningOrPending,
    onWaiting: onWaiting,
    journal: journal,
    consultJournal: true,
    waitLimit: waitLimit,
    journalLimit: journalLimit,
    clearDrafts: clearDrafts ?? (_) => step('clearSecureDrafts'),
    clearArtifacts: clearArtifacts ?? (_) => step('clearAccountArtifacts'),
    clearRecent: clearRecent ?? (_) => step('clearRecentProject'),
    clearAi: clearAi ?? (_) => step('clearAiAccountData'),
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AiAccountRemoval.debugReset();
    root = Directory.systemTemp.createTempSync('packet9-removal-');
    keys = MemoryAiJournalKeyStore();
    files = BarrierFiles(root);
    journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'packet9',
    );
    account = _account(7, 'tester');
    other = _account(8, 'other');
    accountStore = MemoryAccountStore()..accounts = [account, other];
    session = SessionController(accountStore, readCache: accountStore.readCache);
    await session.initialize();
    calls = [];
  });

  tearDown(() {
    AiAccountRemoval.debugReset();
    session.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('§15 row 31 account removal job', () {
    test('takes the hold before any dialog and removes in the fixed order', () async {
      await initialize();
      final settled = await dispatch(account.key);
      await journal.finish(
        executionId: settled,
        terminal: AiJournalState.succeeded,
      );
      final epoch = journal.proposalEpoch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      // Synchronous: held, epoch unchanged, no cleaning involved.
      expect(journal.removalHeld(account.key), isTrue);
      expect(journal.proposalEpoch(account.key), epoch);
      final prompts = <AiRemovalPromptKind>[];
      final result = await remove(
        job: job,
        confirm: (prompt) async {
          prompts.add(prompt.kind);
          expect(journal.removalHeld(account.key), isTrue);
          expect(AiAccountRemoval.isRunning(account.key), isTrue);
          expect(AiAccountRemoval.anyRunning, isTrue);
          await expectLater(
            journal.prepare(draft: draft(account.key)),
            throwsA(isA<AiJournalException>()),
          );
          return true;
        },
      );
      expect(result.status, AiRemovalStatus.removed);
      expect(result.dataState, AiRemovalDataState.cleared);
      expect(prompts, [AiRemovalPromptKind.plainConfirm]);
      expect(calls, [
        'armDispose',
        'clearSecureDrafts',
        'clearAccountArtifacts',
        'clearRecentProject',
        'clearAiAccountData',
      ]);
      expect(session.accounts.map((saved) => saved.key), [other.key]);
      expect(journal.removalHeld(account.key), isFalse);
      expect(AiAccountRemoval.isRunning(account.key), isFalse);
      expect(AiAccountRemoval.takeResult(account.key), isNull);
      // Accepting the final dialog invalidated old proposals and approvals.
      expect(journal.proposalEpoch(account.key), greaterThan(epoch));
    });

    test('a second entry point is refused while the token is valid; old tokens cannot touch a new job', () async {
      final first = AiAccountRemoval.begin(account.key, journal: journal)!;
      expect(AiAccountRemoval.begin(account.key, journal: journal), isNull);
      expect(journal.removalHeld(account.key), isTrue);
      // A job for another account is refused without touching this one.
      final mismatched = await AiAccountRemoval.run(
        account: other,
        job: first,
        session: session,
        confirm: (_) async => true,
        waitForInFlightWrites: () async {},
        requestCancelOnDispose: () {},
        journal: journal,
      );
      expect(mismatched.reason, 'refused');
      expect(first.holds(first.token), isTrue);
      first.cancelFinal();
      expect(journal.removalHeld(account.key), isFalse);
      final second = AiAccountRemoval.begin(account.key, journal: journal)!;
      first.release(first.token);
      expect(journal.removalHeld(account.key), isTrue);
      expect(second.holds(second.token), isTrue);
      final result = await remove(job: second, confirm: (_) async => false);
      expect(result.reason, 'finalCancelled');
      expect(journal.removalHeld(account.key), isFalse);
    });

    test('stop dialog cancel keeps the epoch, does not stop or wait, clears nothing', () async {
      final epoch = journal.proposalEpoch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      var waited = false;
      AiRemovalPrompt? shown;
      final result = await remove(
        job: job,
        runningOrPending: 2,
        wait: () async => waited = true,
        confirm: (prompt) async {
          shown = prompt;
          return false;
        },
      );
      expect(shown!.kind, AiRemovalPromptKind.stopRuns);
      expect(shown!.count, 2);
      expect(result.reason, 'stopCancelled');
      expect(waited, isFalse);
      expect(journal.proposalEpoch(account.key), epoch);
      expect(journal.removalHeld(account.key), isFalse);
      expect(calls, ['armDispose']);
      expect(session.accounts, hasLength(2));
    });

    test('stop accepted bumps the epoch, waits with a waiting state; final cancel bumps again', () async {
      final epoch = journal.proposalEpoch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final waiting = <bool>[];
      var stoppedAt = -1;
      final result = await remove(
        job: job,
        runningOrPending: 1,
        onWaiting: waiting.add,
        wait: () async => stoppedAt = journal.proposalEpoch(account.key),
        confirm: (prompt) async => prompt.kind == AiRemovalPromptKind.stopRuns,
      );
      expect(stoppedAt, epoch + 1);
      expect(waiting, [true, false]);
      expect(result.reason, 'finalCancelled');
      expect(journal.proposalEpoch(account.key), epoch + 2);
      expect(journal.removalHeld(account.key), isFalse);
      expect(calls, ['armDispose']);
    });

    test('uncertain writes that appear while waiting require @username and are counted', () async {
      await initialize();
      final id = await dispatch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      AiRemovalPrompt? last;
      final result = await remove(
        job: job,
        // The stopped write settles as uncertain while the job waits.
        wait: () => journal
            .finish(executionId: id, terminal: AiJournalState.writeUncertain)
            .then((_) {}),
        confirm: (prompt) async {
          last = prompt;
          return false;
        },
      );
      expect(last!.kind, AiRemovalPromptKind.typeUsername);
      expect(last!.count, 1);
      expect(last!.unreadable, isFalse);
      expect(result.reason, 'finalCancelled');
      // Cancelling never releases the isolation.
      expect(journal.isolated(account.key, {target(account.key)}), isTrue);
      expect(await files.exists(account.key), isTrue);
    });

    test('dispatching rows, key-level marks and the reset window each require @username', () async {
      await initialize();
      final first = await dispatch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final kinds = <(AiRemovalPromptKind, int)>[];
      await remove(
        job: job,
        confirm: (prompt) async {
          kinds.add((prompt.kind, prompt.count));
          return false;
        },
      );
      await journal.finish(
        executionId: first,
        terminal: AiJournalState.writeUncertain,
      );
      await journal.releaseByUser(executionId: first, typedName: '!12');
      final again = AiAccountRemoval.begin(account.key, journal: journal)!;
      await remove(
        job: again,
        confirm: (prompt) async {
          kinds.add((prompt.kind, prompt.count));
          return false;
        },
      );
      final reset = await journal.beginReset(account.key);
      await journal.completeReset(reset, typedUsername: '@tester');
      final third = AiAccountRemoval.begin(account.key, journal: journal)!;
      await remove(
        job: third,
        confirm: (prompt) async {
          kinds.add((prompt.kind, prompt.count));
          return false;
        },
      );
      expect(journal.recentlyReset(account.key), isTrue);
      expect(kinds, [
        (AiRemovalPromptKind.typeUsername, 1),
        // Released by the user: no isolation left, but the mark is unconsumed.
        (AiRemovalPromptKind.typeUsername, 0),
        // A fresh journal inside its 24 h "reset, confirm" window.
        (AiRemovalPromptKind.typeUsername, 0),
      ]);
    });

    test('an unreadable journal requires @username; an unavailable key stops before AI cleanup', () async {
      await initialize();
      keys.unavailable = true;
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      AiRemovalPrompt? shown;
      final result = await remove(
        job: job,
        confirm: (prompt) async {
          shown = prompt;
          return true;
        },
      );
      expect(shown!.kind, AiRemovalPromptKind.typeUsername);
      expect(shown!.unreadable, isTrue);
      expect(result.status, AiRemovalStatus.notRemoved);
      expect(result.reason, 'retryRemovalLater');
      expect(result.dataState, AiRemovalDataState.untouched);
      expect(calls, isNot(contains('clearAiAccountData')));
      expect(session.accounts, hasLength(2));
      expect(journal.removalHeld(account.key), isFalse);
      expect(AiAccountRemoval.takeResult(account.key)?.reason,
          'retryRemovalLater');
      keys.unavailable = false;
      expect(await files.exists(account.key), isTrue);
    });

    test('a readable journal that cannot take the removal-start mark keeps the account', () async {
      await initialize();
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final result = await remove(
        job: job,
        confirm: (_) async {
          files.failWrite = true;
          return true;
        },
      );
      files.failWrite = false;
      expect(result.reason, 'retryRemovalLater');
      expect(calls, isNot(contains('clearAiAccountData')));
      expect(session.accounts, hasLength(2));
      expect(journal.removalHeld(account.key), isFalse);
    });

    test('keyMissing asks for the name, writes no mark and removal completes', () async {
      await initialize();
      keys.keys.remove(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      AiRemovalPrompt? shown;
      final result = await remove(
        job: job,
        confirm: (prompt) async {
          shown = prompt;
          return true;
        },
      );
      expect(shown!.kind, AiRemovalPromptKind.typeUsername);
      expect(shown!.unreadable, isTrue);
      expect(result.status, AiRemovalStatus.removed);
      expect(calls, contains('clearAiAccountData'));
      expect(keys.keys[account.key], isNull);
    });

    test('a journal read that never answers requires @username and keeps journal and session', () async {
      await initialize();
      final value = draft(account.key);
      await journal.prepare(draft: value);
      files.resume = Completer<void>();
      files.entered = Completer<void>();
      final blocked = journal.markDispatching(executionId: value.executionId);
      await files.entered!.future;
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      AiRemovalPrompt? shown;
      final result = await remove(
        job: job,
        journalLimit: const Duration(milliseconds: 50),
        confirm: (prompt) async {
          shown = prompt;
          return false;
        },
      );
      expect(shown!.kind, AiRemovalPromptKind.typeUsername);
      expect(shown!.unreadable, isTrue);
      expect(result.reason, 'finalCancelled');
      expect(session.accounts, hasLength(2));
      files.resume!.complete();
      files.resume = null;
      await expectLater(blocked, throwsA(anything));
    });

    test('row 29: a stuck dispatching flush hits the wait limit, final cancel bumps the epoch, the resumed flush sends nothing', () async {
      await initialize();
      final value = draft(account.key);
      await journal.prepare(draft: value);
      files.resume = Completer<void>();
      files.entered = Completer<void>();
      var mutations = 0;
      // The coordinator's dispatch: flush `dispatching`, then the mutation.
      final flight = journal
          .markDispatching(executionId: value.executionId)
          .then((_) => mutations++);
      await files.entered!.future;
      final epoch = journal.proposalEpoch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      AiRemovalPrompt? shown;
      final result = await remove(
        job: job,
        runningOrPending: 1,
        wait: () => flight.then((_) {}),
        waitLimit: const Duration(milliseconds: 50),
        journalLimit: const Duration(milliseconds: 50),
        confirm: (prompt) async {
          if (prompt.kind == AiRemovalPromptKind.stopRuns) return true;
          shown = prompt;
          return false;
        },
      );
      expect(shown!.kind, AiRemovalPromptKind.typeUsername);
      expect(result.status, AiRemovalStatus.cancelled);
      expect(result.reason, 'waitTimedOut');
      expect(result.presentable, isTrue);
      expect(journal.proposalEpoch(account.key), greaterThan(epoch));
      expect(journal.removalHeld(account.key), isFalse);
      files.resume!.complete();
      files.resume = null;
      await expectLater(flight, throwsA(isA<AiJournalException>()));
      expect(mutations, 0);
      final refunded = await journal.finish(
        executionId: value.executionId,
        terminal: AiJournalState.notExecuted,
      );
      expect(refunded.entry.state, AiJournalState.notExecuted);
      expect(refunded.budgetRefunded, isTrue);
      expect(calls, ['armDispose']);
    });

    test('cancellation during the wait ends the job after that await; the write still settles', () async {
      await initialize();
      final id = await dispatch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final settle = Completer<void>();
      var prompts = 0;
      final running = remove(
        job: job,
        wait: () => settle.future,
        confirm: (_) async {
          prompts++;
          return true;
        },
      );
      await Future<void>.delayed(Duration.zero);
      job.requestCancel();
      expect(journal.removalHeld(account.key), isTrue);
      await journal.finish(executionId: id, terminal: AiJournalState.succeeded);
      settle.complete();
      final result = await running;
      expect(result.reason, 'removalCancelled');
      expect(prompts, 0);
      expect(journal.removalHeld(account.key), isFalse);
      expect(
        journal.entries(account.key).single.state,
        AiJournalState.succeeded,
      );
      expect(calls, ['armDispose']);
    });

    test('a Navigator released at the stop dialog ends the wait by cancellation, epoch unchanged', () async {
      final epoch = journal.proposalEpoch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final shown = Completer<void>();
      final running = remove(
        job: job,
        runningOrPending: 1,
        // showDialog never completes once its Navigator is gone.
        confirm: (_) {
          shown.complete();
          return Completer<bool>().future;
        },
      );
      await shown.future;
      job.requestCancel();
      final result = await running;
      expect(result.reason, 'stopCancelled');
      expect(journal.proposalEpoch(account.key), epoch);
      expect(journal.removalHeld(account.key), isFalse);
      expect(calls, ['armDispose']);
      expect(AiAccountRemoval.begin(account.key, journal: journal), isNotNull);
    });

    test('a Navigator released at the final dialog bumps the epoch, releases, removes nothing', () async {
      final epoch = journal.proposalEpoch(account.key);
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final shown = Completer<void>();
      final running = remove(
        job: job,
        confirm: (_) {
          shown.complete();
          return Completer<bool>().future;
        },
      );
      await shown.future;
      job.requestCancel();
      final result = await running;
      expect(result.reason, 'finalCancelled');
      expect(journal.proposalEpoch(account.key), epoch + 1);
      expect(journal.removalHeld(account.key), isFalse);
      expect(calls, ['armDispose']);
      expect(session.accounts, hasLength(2));
      final retry = AiAccountRemoval.begin(account.key, journal: journal)!;
      expect(
        (await remove(job: retry, confirm: (_) async => true)).status,
        AiRemovalStatus.removed,
      );
    });

    test('after the final confirmation, cancel requests during every cleanup await are ignored', () async {
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final gate = Completer<void>();
      final entered = Completer<void>();
      final running = remove(
        job: job,
        confirm: (_) async => true,
        clearArtifacts: (_) async {
          calls.add('clearAccountArtifacts');
          entered.complete();
          await gate.future;
        },
      );
      await entered.future;
      job.requestCancel();
      expect(job.cancelRequestedBeforeFinalConfirm, isFalse);
      expect(journal.removalHeld(account.key), isTrue);
      await expectLater(
        journal.prepare(draft: draft(account.key)),
        throwsA(isA<AiJournalException>()),
      );
      gate.complete();
      final result = await running;
      expect(result.status, AiRemovalStatus.removed);
      expect(journal.removalHeld(account.key), isFalse);
    });

    test('clearAccountArtifacts failure keeps the account, releases the hold; writes work again', () async {
      await initialize();
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final result = await remove(
        job: job,
        confirm: (_) async => true,
        clearArtifacts: (_) async => throw _SyntheticCleanupFailure(),
      );
      expect(result.status, AiRemovalStatus.notRemoved);
      expect(result.reason, 'beforeAiCleanupFailed');
      expect(result.error, isA<_SyntheticCleanupFailure>());
      expect(calls, isNot(contains('clearAiAccountData')));
      expect(session.accounts, hasLength(2));
      expect(journal.removalHeld(account.key), isFalse);
      expect(journal.tombstoneFlag(account.key), isFalse);
      // Re-proposed writes can be prepared again.
      final again = await journal.prepare(draft: draft(account.key));
      expect(again.entry.state, AiJournalState.prepared);
    });

    test('clearAiAccountData failure keeps the account; the retry is a new job with a new hold', () async {
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final result = await remove(
        job: job,
        confirm: (_) async => true,
        clearAi: (_) async => throw _SyntheticCleanupFailure(),
      );
      expect(result.reason, 'aiCleanupFailed');
      expect(result.dataState, AiRemovalDataState.cleanupStarted);
      expect(journal.removalHeld(account.key), isFalse);
      expect(session.accounts, hasLength(2));
      final retry = AiAccountRemoval.begin(account.key, journal: journal)!;
      job.release(job.token);
      expect(retry.holds(retry.token), isTrue);
      expect(
        (await remove(job: retry, confirm: (_) async => true)).status,
        AiRemovalStatus.removed,
      );
    });

    test('session.remove returning while busy is judged by the account list', () async {
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final hold = Completer<void>();
      accountStore.holdAccountSave = hold;
      final busy = session.remove(other);
      expect(session.busy, isTrue);
      final result = await remove(job: job, confirm: (_) async => true);
      expect(result.status, AiRemovalStatus.notRemoved);
      expect(result.reason, 'accountRetained');
      expect(result.dataState, AiRemovalDataState.cleared);
      expect(session.accounts.map((saved) => saved.key), contains(account.key));
      expect(journal.removalHeld(account.key), isFalse);
      hold.complete();
      await busy;
    });

    test('session.remove restoring the list after a save failure is "not removed"', () async {
      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      accountStore.rejectWrite = true;
      final result = await remove(job: job, confirm: (_) async => true);
      accountStore.rejectWrite = false;
      expect(result.reason, 'accountRetained');
      expect(session.accounts.map((saved) => saved.key), contains(account.key));
      expect(journal.removalHeld(account.key), isFalse);
      expect(AiAccountRemoval.takeResult(account.key)?.reason, 'accountRetained');
    });

    test('history disabled: session notifications during dialogs and cleanup never release the hold or enter cleaning', () async {
      final store = MemoryAiStore();
      final history = AiHistoryCoordinator.debugReset(store: store);
      addTearDown(AiHistoryCoordinator.debugReset);
      await history.startRecovery(session);
      await history.load(account.key);
      expect(history.state(account.key), AiHistoryState.disabled);
      final cleaning = AiAccountMutationCoordinator.forStore(store);
      Future<void> notify(String name) async {
        calls.add(name);
        // A SessionController notification with busy false.
        await session.endSession();
        expect(session.busy, isFalse);
        expect(journal.removalHeld(account.key), isTrue);
        expect(cleaning.isCleaning(account.key), isFalse);
        await expectLater(
          journal.prepare(draft: draft(account.key)),
          throwsA(isA<AiJournalException>()),
        );
      }

      final job = AiAccountRemoval.begin(account.key, journal: journal)!;
      final cancelled = await remove(
        job: job,
        confirm: (_) async {
          await notify('dialog');
          return false;
        },
      );
      expect(cancelled.reason, 'finalCancelled');
      expect(cleaning.isCleaning(account.key), isFalse);
      expect(history.state(account.key), AiHistoryState.disabled);

      final again = AiAccountRemoval.begin(account.key, journal: journal)!;
      final result = await remove(
        job: again,
        confirm: (_) async => true,
        clearDrafts: (_) => notify('drafts'),
        clearArtifacts: (_) => notify('artifacts'),
        clearRecent: (_) => notify('recent'),
      );
      expect(result.status, AiRemovalStatus.removed);
      expect(calls, [
        'armDispose',
        'dialog',
        'armDispose',
        'drafts',
        'artifacts',
        'recent',
        'clearAiAccountData',
      ]);
    });
  });

  group('§15 row 4 switching and signing out', () {
    test('no dialog without runs or proposals; cancel never stops anything', () async {
      var asked = 0;
      expect(
        await AiSwitchGuard.confirmSwitch(
          runningOrPending: 0,
          confirm: (_) async {
            asked++;
            return AiSwitchChoice.cancel;
          },
        ),
        AiSwitchChoice.proceedAndWait,
      );
      expect(asked, 0);
      var stopped = 0;
      expect(
        await AiSwitchGuard.settle(
          choice: AiSwitchChoice.cancel,
          stopAndSnapshotWrites: () {
            stopped++;
            return const [];
          },
        ),
        isFalse,
      );
      expect(stopped, 0);
    });

    test('proceedAndWait stops runs and waits for writes in flight before switching', () async {
      final write = Completer<AiWriteOutcome>();
      var stopped = 0;
      var finished = false;
      final settling = AiSwitchGuard.settle(
        choice: AiSwitchChoice.proceedAndWait,
        stopAndSnapshotWrites: () {
          stopped++;
          return [write.future];
        },
      ).then((value) {
        finished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(stopped, 1);
      expect(finished, isFalse);
      write.completeError(StateError('synthetic settled failure'));
      expect(await settling, isTrue);
    });

    test('A→B→A after switch now: the uncertain key stays isolated, nothing dispatches', () async {
      await initialize();
      final value = draft(account.key);
      await journal.prepare(draft: value);
      await journal.markDispatching(executionId: value.executionId);
      final write = Completer<AiWriteOutcome>();
      var stopped = 0;
      // A → B: switch now does not wait for the write in flight.
      expect(
        await AiSwitchGuard.settle(
          choice: AiSwitchChoice.switchNow,
          stopAndSnapshotWrites: () {
            stopped++;
            return [write.future];
          },
        ),
        isTrue,
      );
      expect(stopped, 1);
      expect(write.isCompleted, isFalse);
      // The closed client reports `cancelled`; past the acceptance point the
      // coordinator records it as uncertain (§7.5).
      await journal.finish(
        executionId: value.executionId,
        terminal: AiJournalState.writeUncertain,
      );
      // B → A: a new conversation proposes the same key.
      expect(journal.isolated(account.key, {target(account.key)}), isTrue);
      await expectLater(
        journal.prepare(draft: draft(account.key)),
        throwsA(
          isA<AiJournalException>().having(
            (error) => error.reason,
            'reason',
            'isolated',
          ),
        ),
      );
      expect(
        journal.entries(account.key).single.state,
        AiJournalState.writeUncertain,
      );
    });

    test('a wait that hits its limit switches like switch now', () async {
      expect(
        await AiSwitchGuard.settle(
          choice: AiSwitchChoice.proceedAndWait,
          stopAndSnapshotWrites: () => [Completer<AiWriteOutcome>().future],
          waitLimit: const Duration(milliseconds: 20),
        ),
        isTrue,
      );
    });
  });
}

/// A synthetic failure from a cleanup step.
final class _SyntheticCleanupFailure implements Exception {}
