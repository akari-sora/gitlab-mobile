import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/main.dart';

import '../session_test.dart' show MemoryAccountStore;

const _first = 'https://synthetic.example/gitlab#7';
const _second = 'https://synthetic.example/gitlab#8';
final _digest = List.filled(64, 'b').join();

/// Tombstone reads and reset-marker writes or key deletions that fail on
/// demand, for one account at a time.
class _Keys extends MemoryAiJournalKeyStore {
  String? tombstoneUnavailableFor;
  bool failMarkerWrite = false;
  bool failKeyDelete = false;

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) async {
    if (accountKey == tombstoneUnavailableFor) {
      return const AiStoreRead.unavailable(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'syntheticTombstone'),
      );
    }
    return super.readTombstone(accountKey);
  }

  @override
  Future<void> writeResetPending(String accountKey, DateTime at) async {
    if (failMarkerWrite) throw StateError('synthetic marker write failure');
    await super.writeResetPending(accountKey, at);
  }

  @override
  Future<void> deleteKey(String accountKey) async {
    if (failKeyDelete) throw StateError('synthetic key delete failure');
    await super.deleteKey(accountKey);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _Keys keys;
  var serial = 0;

  setUp(() {
    root = Directory(
      Directory.systemTemp.resolveSymbolicLinksSync(),
    ).createTempSync('fx-journal-recovery-');
    keys = _Keys();
    serial = 0;
  });
  tearDown(() => root.deleteSync(recursive: true));

  AiWriteJournal owner(String process) =>
      AiWriteJournal(keys: keys, applicationSupport: root, processId: process);

  AiBudgetRequest request(String account) => AiBudgetRequest(
    accountKey: account,
    conversationId: 'conversation-${serial++}',
    runId: 'run-$serial',
  );

  AiJournalDraft draft(String account, {String project = 'project:1'}) {
    final id = 'execution-${serial++}';
    return AiJournalDraft(
      executionId: id,
      accountKey: account,
      conversationId: 'conversation-$id',
      runId: 'run-$id',
      operationId: 'createNote',
      writeKeys: {
        AiConflictKey([account, project, 'mergeRequest', '12']),
      },
      payloadSha256: _digest,
      releaseName: '!12',
      instance: 'https://synthetic.example/gitlab',
    );
  }

  Future<String> dispatch(AiWriteJournal journal, String account) async {
    final value = draft(account);
    await journal.prepare(draft: value);
    await journal.markDispatching(executionId: value.executionId);
    return value.executionId;
  }

  group('J1 accounts that join after start-up', () {
    test('first sign-in after an empty start can reserve and write', () async {
      // The start-up wiring with an empty stored account list (new install).
      final session = SessionController(MemoryAccountStore());
      addTearDown(session.dispose);
      await session.initialize();
      final journal = owner('fx-first');
      await recoverAiWriteJournalAfterAccountsLoaded(session, journal);
      expect(journal.recovered(_first), isFalse);

      // Opus probe 2: this reserve used to throw recoveryPending.
      final hold = await journal.tryReserve(request(_first));
      expect(hold, isNotNull);
      expect(journal.recovered(_first), isTrue);
      await journal.refund(hold!);
      final id = await dispatch(journal, _first);
      await journal.finish(executionId: id, terminal: AiJournalState.succeeded);
      expect(keys.keys[_first]?.length, 32);
      expect(journal.entries(_first).single.state, AiJournalState.succeeded);
    });

    test('a second account added later can reserve too', () async {
      final journal = owner('fx-second');
      await journal.recoverAfterAccountsLoaded(const <String>[]);
      final first = await dispatch(journal, _first);
      await journal.finish(
        executionId: first,
        terminal: AiJournalState.succeeded,
      );

      expect(await journal.tryReserve(request(_second)), isNotNull);
      expect(journal.recovered(_second), isTrue);
      final second = await dispatch(journal, _second);
      await journal.finish(
        executionId: second,
        terminal: AiJournalState.writeUncertain,
      );
      expect(
        journal.isolated(_second, {
          const AiConflictKey([_second, 'project:1', 'mergeRequest', '12']),
        }),
        isTrue,
      );
    });

    test(
      'a recovery rerun with a list read before the join never sweeps a joined account',
      () async {
        final journal = owner('fx-sweep');
        await journal.recoverAfterAccountsLoaded(const <String>[]);
        final id = await dispatch(journal, _second);
        // Membership changed during start-up recovery; the rerun's list was
        // read before the second account was stored.
        await journal.recoverAfterAccountsLoaded(const <String>[_first]);
        expect(keys.keys.containsKey(_second), isTrue);
        expect(await journal.keyStatus(_second), AiJournalKeyStatus.found);
        await journal.finish(
          executionId: id,
          terminal: AiJournalState.succeeded,
        );
        expect(journal.entries(_second).single.state, AiJournalState.succeeded);
      },
    );

    test('before the start-up recovery has run, nothing writes', () async {
      final journal = owner('fx-early');
      await expectLater(
        journal.tryReserve(request(_first)),
        throwsA(
          isA<AiJournalException>().having(
            (error) => error.reason,
            'reason',
            'recoveryPending',
          ),
        ),
      );
      expect(keys.keys, isEmpty);
    });

    test(
      'an account with an existing journal still goes through recovery',
      () async {
        final before = owner('fx-process-one');
        await before.recoverAfterAccountsLoaded(const <String>[_first]);
        final prepared = draft(_first, project: 'project:3');
        await before.prepare(draft: prepared);
        final sent = await dispatch(before, _first);

        // Next start: this account's recovery fails (tombstone unreadable),
        // so it is not part of the start-up recovery result.
        keys.tombstoneUnavailableFor = _first;
        final journal = owner('fx-process-two');
        await journal.recoverAfterAccountsLoaded(const <String>[_first]);
        expect(journal.recovered(_first), isFalse);
        await expectLater(
          journal.tryReserve(request(_first)),
          throwsA(isA<AiJournalException>()),
        );

        // Once readable, the first write runs the same recovery first: the
        // other process's entries are converted before anything is reserved.
        keys.tombstoneUnavailableFor = null;
        expect(await journal.tryReserve(request(_first)), isNotNull);
        final states = {
          for (final entry in journal.entries(_first))
            entry.executionId: entry.state,
        };
        expect(states[prepared.executionId], AiJournalState.notExecuted);
        expect(states[sent], AiJournalState.writeUncertain);
        expect(
          journal.isolated(_first, {
            const AiConflictKey([_first, 'project:1', 'mergeRequest', '12']),
          }),
          isTrue,
        );
        await expectLater(
          journal.prepare(draft: draft(_first)),
          throwsA(
            isA<AiJournalException>().having(
              (error) => error.reason,
              'reason',
              'isolated',
            ),
          ),
        );
        // The conversion is durable.
        final restarted = owner('fx-process-three');
        await restarted.recoverAfterAccountsLoaded(const <String>[_first]);
        expect(restarted.entries(_first).map((entry) => entry.state).toSet(), {
          AiJournalState.notExecuted,
          AiJournalState.writeUncertain,
        });
      },
    );
  });

  group('J2 a cancelled or failed reset restores the owner', () {
    test(
      'a reset whose marker write failed lets the in-flight write record success',
      () async {
        final journal = owner('fx-reset');
        await journal.recoverAfterAccountsLoaded(const <String>[_first]);
        final id = await dispatch(journal, _first);
        final reset = await journal.beginReset(
          _first,
          verifiedUsername: '@user7',
        );
        keys.failMarkerWrite = true;
        await expectLater(
          journal.completeReset(reset, typedUsername: '@user7'),
          throwsA(isA<StateError>()),
        );
        keys.failMarkerWrite = false;
        journal.cancelReset(reset);
        expect(keys.resetPending, isEmpty);

        await journal.finish(
          executionId: id,
          terminal: AiJournalState.succeeded,
        );
        expect(journal.lateAudit, isEmpty);
        expect(journal.entries(_first).single.state, AiJournalState.succeeded);
        expect(
          journal.isolated(_first, {
            const AiConflictKey([_first, 'project:1', 'mergeRequest', '12']),
          }),
          isFalse,
        );
        // Old approvals stay invalidated, but new writes work again.
        expect(await journal.tryReserve(request(_first)), isNotNull);
        final restarted = owner('fx-reset-two');
        await restarted.recoverAfterAccountsLoaded(const <String>[_first]);
        expect(
          restarted.entries(_first).single.state,
          AiJournalState.succeeded,
        );
      },
    );

    test(
      'a finish refused while the reset was pending stays unknown after cancel',
      () async {
        final journal = owner('fx-refused');
        await journal.recoverAfterAccountsLoaded(const <String>[_first]);
        final id = await dispatch(journal, _first);
        final reset = await journal.beginReset(
          _first,
          verifiedUsername: '@user7',
        );
        await expectLater(
          journal.finish(executionId: id, terminal: AiJournalState.succeeded),
          throwsA(isA<AiJournalException>()),
        );
        journal.cancelReset(reset);
        // The request ended but its result is lost: unknown, still locked,
        // released only by the typed name.
        expect(journal.lateAudit.single.executionId, id);
        expect(await journal.keyStatus(_first), AiJournalKeyStatus.found);
        expect(
          journal.entries(_first).single.state,
          AiJournalState.writeUncertain,
        );
        expect(journal.rereadableEntry(_first, id).executionId, id);
        await journal.releaseByUser(executionId: id, typedName: '!12');
        expect(
          journal.entries(_first).single.state,
          AiJournalState.resolvedByUser,
        );
      },
    );

    test(
      'a reset that already started deleting stays durable when cancelled and finishes before any new write',
      () async {
        final journal = owner('fx-durable');
        await journal.recoverAfterAccountsLoaded(const <String>[_first]);
        final id = await dispatch(journal, _first);
        final reset = await journal.beginReset(
          _first,
          verifiedUsername: '@user7',
        );
        keys.failKeyDelete = true;
        await expectLater(
          journal.completeReset(reset, typedUsername: '@user7'),
          throwsA(isA<StateError>()),
        );
        keys.failKeyDelete = false;
        journal.cancelReset(reset);
        expect(keys.resetPending.containsKey(_first), isTrue);
        // The old journal is gone: a late finish is an audit row only.
        await expectLater(
          journal.finish(executionId: id, terminal: AiJournalState.succeeded),
          throwsA(isA<AiJournalException>()),
        );
        expect(journal.lateAudit.single.executionId, id);
        expect(
          await journal.keyStatus(_first),
          isNot(AiJournalKeyStatus.found),
        );
        // The next write first runs the account's recovery, which resumes the
        // durable reset (§8: the marker is never skipped); the old entry is
        // gone and the 24-hour confirmation window is in force.
        expect(await journal.tryReserve(request(_first)), isNotNull);
        expect(keys.resetPending, isEmpty);
        expect(journal.entries(_first), isEmpty);
        expect(journal.recentlyReset(_first), isTrue);
        final restarted = owner('fx-durable-two');
        await restarted.recoverAfterAccountsLoaded(const <String>[_first]);
        expect(restarted.entries(_first), isEmpty);
        expect(restarted.recentlyReset(_first), isTrue);
      },
    );
  });
}
