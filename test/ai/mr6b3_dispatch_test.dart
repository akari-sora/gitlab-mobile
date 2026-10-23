import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/graphql_write_hooks.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b3_support.dart';

void main() {
  group('graph hook protocol', () {
    GraphHooks acceptedSpan() =>
        GraphHooks(beforeMutation: () async {}, mayStart: () => true);

    test('all five span states remain distinguishable', () async {
      final notHooked = GraphHooks(
        beforeMutation: () async {},
        mayStart: () => true,
      );
      expect(notHooked.state, GraphWriteSpanState.notHooked);
      expect(
        classifyGraphWrite(
          'updateWorkItemState',
          notHooked,
          result: const GraphWriteResult(noChange: true),
        ),
        GraphWriteDisposition.noChange,
      );

      final hookFailed = GraphHooks(
        beforeMutation: () async => throw StateError('mark failed'),
        mayStart: () => true,
      );
      await expectLater(hookFailed.beforeMutation(), throwsStateError);
      expect(hookFailed.state, GraphWriteSpanState.hookFailed);

      final hookReturned = GraphHooks(
        beforeMutation: () async {},
        mayStart: () => true,
      );
      await hookReturned.beforeMutation();
      expect(hookReturned.state, GraphWriteSpanState.hookReturned);

      final mayStartFalse = GraphHooks(
        beforeMutation: () async {},
        mayStart: () => false,
      );
      await mayStartFalse.beforeMutation();
      expect(mayStartFalse.mayStart(), isFalse);
      expect(mayStartFalse.state, GraphWriteSpanState.mayStartFalse);

      final accepted = GraphHooks(
        beforeMutation: () async {},
        mayStart: () => true,
      );
      await accepted.beforeMutation();
      expect(accepted.mayStart(), isTrue);
      expect(accepted.state, GraphWriteSpanState.pastAcceptance);
      expect(
        classifyGraphWrite(
          'updateWorkItemState',
          accepted,
          result: const GraphWriteResult(
            mutationSent: true,
            acknowledged: true,
            readbackVerified: true,
          ),
        ),
        GraphWriteDisposition.succeeded,
      );
    });

    test('duplicate and out-of-order calls fail closed', () async {
      final beforeTwice = GraphHooks(
        beforeMutation: () async {},
        mayStart: () => true,
      );
      await beforeTwice.beforeMutation();
      await expectLater(
        beforeTwice.beforeMutation(),
        throwsA(isA<GraphHookContractException>()),
      );
      expect(beforeTwice.contractViolated, isTrue);

      final startFirst = GraphHooks(
        beforeMutation: () async {},
        mayStart: () => true,
      );
      expect(startFirst.mayStart, throwsA(isA<GraphHookContractException>()));
      expect(startFirst.contractViolated, isTrue);

      final startTwice = GraphHooks(
        beforeMutation: () async {},
        mayStart: () => true,
      );
      await startTwice.beforeMutation();
      expect(startTwice.mayStart(), isTrue);
      expect(startTwice.mayStart, throwsA(isA<GraphHookContractException>()));
      expect(startTwice.accepted, isTrue);
      expect(
        classifyGraphWrite(
          'updateWorkItemState',
          startTwice,
          result: const GraphWriteResult(
            mutationSent: true,
            acknowledged: true,
            readbackVerified: true,
          ),
        ),
        GraphWriteDisposition.writeUncertain,
      );
    });

    test('all 15 classifier rules enforce their exact noop contract', () {
      expect(graphWriteRules, hasLength(15));
      expect(
        graphWriteRules.values.where((rule) => rule.allowsNoop),
        hasLength(10),
      );
      for (final entry in graphWriteRules.entries) {
        final span = GraphHooks(
          beforeMutation: () async {},
          mayStart: () => true,
        );
        expect(
          classifyGraphWrite(
            entry.key,
            span,
            result: const GraphWriteResult(noChange: true),
          ),
          entry.value.allowsNoop
              ? GraphWriteDisposition.noChange
              : GraphWriteDisposition.notExecuted,
          reason: entry.key,
        );
      }
    });

    test('all 15 accepted rules require positive mutation evidence', () async {
      for (final entry in graphWriteRules.entries) {
        final valid = acceptedSpan();
        await valid.beforeMutation();
        expect(valid.mayStart(), isTrue);
        expect(
          classifyGraphWrite(
            entry.key,
            valid,
            result: const GraphWriteResult(
              mutationSent: true,
              acknowledged: true,
              readbackVerified: true,
            ),
          ),
          GraphWriteDisposition.succeeded,
          reason: entry.key,
        );

        final falseSend = acceptedSpan();
        await falseSend.beforeMutation();
        expect(falseSend.mayStart(), isTrue);
        expect(
          classifyGraphWrite(
            entry.key,
            falseSend,
            result: const GraphWriteResult(
              noChange: true,
              mutationSent: false,
              acknowledged: true,
              readbackVerified: true,
            ),
          ),
          GraphWriteDisposition.writeUncertain,
          reason: '${entry.key} mutationSent',
        );

        final missingAck = acceptedSpan();
        await missingAck.beforeMutation();
        expect(missingAck.mayStart(), isTrue);
        expect(
          classifyGraphWrite(
            entry.key,
            missingAck,
            result: const GraphWriteResult(
              mutationSent: true,
              readbackVerified: true,
            ),
          ),
          GraphWriteDisposition.writeUncertain,
          reason: '${entry.key} acknowledged',
        );

        final missingReadback = acceptedSpan();
        await missingReadback.beforeMutation();
        expect(missingReadback.mayStart(), isTrue);
        expect(
          classifyGraphWrite(
            entry.key,
            missingReadback,
            result: const GraphWriteResult(
              mutationSent: true,
              acknowledged: true,
            ),
          ),
          entry.value.readback
              ? GraphWriteDisposition.writeUncertain
              : GraphWriteDisposition.succeeded,
          reason: '${entry.key} readback',
        );
      }
    });

    test('unsupported and hookReturned results fail closed', () async {
      final unsupportedNoop = GraphHooks(
        beforeMutation: () async {},
        mayStart: () => true,
      );
      expect(
        classifyGraphWrite(
          'unsupportedGraphOperation',
          unsupportedNoop,
          result: const GraphWriteResult(noChange: true),
        ),
        GraphWriteDisposition.notExecuted,
      );

      final unsupportedAccepted = acceptedSpan();
      await unsupportedAccepted.beforeMutation();
      expect(unsupportedAccepted.mayStart(), isTrue);
      expect(
        classifyGraphWrite(
          'unsupportedGraphOperation',
          unsupportedAccepted,
          result: const GraphWriteResult(
            mutationSent: true,
            acknowledged: true,
            readbackVerified: true,
          ),
        ),
        GraphWriteDisposition.writeUncertain,
      );

      for (final error in <Object?>[null, StateError('after hook')]) {
        final returned = GraphHooks(
          beforeMutation: () async {},
          mayStart: () => true,
        );
        await returned.beforeMutation();
        expect(
          classifyGraphWrite(
            'updateWorkItemState',
            returned,
            result: error == null ? const GraphWriteResult() : null,
            error: error,
          ),
          GraphWriteDisposition.notExecuted,
        );
      }
    });
  });

  group('graph coordinator dispatch', () {
    late Mr6b3Harness harness;

    setUp(() async => harness = await Mr6b3Harness.create());
    tearDown(() => harness.dispose());

    test('ledger defaults REST and fake rows opt into graph', () {
      const rest = AiCapability(
        operationId: 'syntheticRest',
        baseTier: AiWriteTier.t2,
        scopeClass: AiScopeClass.workItem,
      );
      expect(rest.boundary, AiWriteBoundary.rest);
      expect(Mr6b3Ledger.state.boundary, AiWriteBoundary.graph);
    });

    test(
      'stringList has a closed string array schema and scalar validation',
      () async {
        final spec = harness.coordinator.specs.singleWhere(
          (value) => value.name == 'updateWorkItemAssignees',
        );
        final properties = spec.parameters['properties']! as Map;
        expect(properties['assigneeUsernames'], {
          'type': 'array',
          'items': {'type': 'string'},
        });

        expect(await harness.proposeAssignees('alice'), isNull);
        expect(harness.port.prepareCount, 0);
        harness.beginRun();
        expect(await harness.proposeAssignees(<Object?>['alice', 7]), isNull);
        expect(harness.port.prepareCount, 0);
        harness.beginRun();
        final valid = await harness.proposeAssignees(<Object?>['alice', 'bob']);
        expect(valid, isNotNull);
        expect(harness.port.prepareCount, 1);
      },
    );

    test(
      'notHooked noop is externally noChange and durably notExecuted',
      () async {
        harness.port.mode = Mr6b3MutationMode.noop;
        final proposal = await harness.proposeState();
        final outcome = await harness.approve(proposal!);
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.reasonCode, 'noChange');
        expect(outcome.noChange, isTrue);
        expect(outcome.mutationCount, 0);
        expect(harness.port.sends, 0);
        expect(
          harness.journal.entries(mr6b3Account).last.state,
          AiJournalState.notExecuted,
        );
        expect(
          harness.journal.conversationWriteCount(
            mr6b3Account,
            mr6b3Conversation,
          ),
          0,
        );
      },
    );

    test('preflight refusal remains prepared to notExecuted', () async {
      harness.port.mode = Mr6b3MutationMode.preflightRefused;
      final outcome = await harness.approve((await harness.proposeState())!);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'syntheticPreflight');
      expect(outcome.mutationCount, 0);
      expect(harness.port.sends, 0);
      expect(
        harness.journal.entries(mr6b3Account).last.state,
        AiJournalState.notExecuted,
      );
    });

    test(
      'definite mark invalidTransition finishes notExecuted without fail-stop',
      () async {
        harness.port.beforeBoundary = () {
          harness.keys.onReadTombstone = () {
            harness.journal.bumpProposalEpoch(mr6b3Account);
          };
        };
        final outcome = await harness.approve((await harness.proposeState())!);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(
          outcome.reasonCode,
          anyOf('proposalInvalidated', 'invalidTransition'),
        );
        expect(outcome.reasonCode, isNot('journalUnavailable'));
        expect(outcome.mutationCount, 0);
        expect(harness.port.sends, 0);
        expect(
          harness.journal.entries(mr6b3Account).last.state,
          AiJournalState.notExecuted,
        );
        final durable = await harness.readDurableJournal();
        final entries = durable['entries']! as List<Object?>;
        expect((entries.last! as Map<String, Object?>)['state'], 'notExecuted');

        harness.port.beforeBoundary = null;
        harness.keys.onReadTombstone = null;
        harness.beginRun();
        expect(await harness.proposeState(), isNotNull);
      },
    );

    test(
      'one-shot tombstone unavailability finishes notExecuted without fail-stop',
      () async {
        harness.port.beforeBoundary = () {
          harness.keys.failNextTombstone = true;
        };
        final outcome = await harness.approve((await harness.proposeState())!);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, anyOf('unavailable', 'recoveryPending'));
        expect(outcome.reasonCode, isNot('journalUnavailable'));
        expect(outcome.mutationCount, 0);
        expect(harness.port.sends, 0);
        expect(
          harness.journal.entries(mr6b3Account).last.state,
          AiJournalState.notExecuted,
        );
        final durable = await harness.readDurableJournal();
        final entries = durable['entries']! as List<Object?>;
        expect((entries.last! as Map<String, Object?>)['state'], 'notExecuted');

        harness.port.beforeBoundary = null;
        harness.beginRun();
        final next = await harness.approve((await harness.proposeState())!);
        expect(next.state, AiJournalState.succeeded);
        expect(next.mutationCount, 1);
        expect(harness.port.sends, 1);
      },
    );

    test(
      'unawaited beforeMutation is retained before rollback settlement',
      () async {
        harness.port.mode = Mr6b3MutationMode.unawaitedBefore;
        final proposal = await harness.proposeState();
        final markEntered = harness.files.armBarrier(
          writesBeforeBarrier: 1,
          afterPersist: true,
        );
        var settled = false;
        final pending = harness.approve(proposal!);
        unawaited(pending.then((_) => settled = true));
        await markEntered;
        expect(settled, isFalse);
        expect(harness.port.sends, 0);
        final durable = await harness.readDurableJournal();
        final entries = durable['entries']! as List<Object?>;
        expect((entries.last! as Map<String, Object?>)['state'], 'dispatching');

        harness.files.releaseBarrier();
        final outcome = await pending;
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'graphContractViolation');
        expect(outcome.mutationCount, 0);
        expect(
          harness.journal.entries(mr6b3Account).last.state,
          AiJournalState.notExecuted,
        );
      },
    );

    for (final mode in [
      Mr6b3MutationMode.hookReturnedResult,
      Mr6b3MutationMode.hookReturnedError,
    ]) {
      test('$mode reverts dispatching without claiming a send', () async {
        harness.port.mode = mode;
        final outcome = await harness.approve((await harness.proposeState())!);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.mutationCount, 0);
        expect(harness.port.sends, 0);
        expect(
          harness.journal.entries(mr6b3Account).last.state,
          AiJournalState.notExecuted,
        );
        expect(
          harness.journal.conversationWriteCount(
            mr6b3Account,
            mr6b3Conversation,
          ),
          0,
        );
      });
    }

    test(
      'mayStart false sends nothing and restores a consumed confirm mark',
      () async {
        await harness.seedConfirmMark();
        expect(
          harness.journal.requiresConfirmation(mr6b3Account, {mr6b3WriteKey}),
          isTrue,
        );
        harness.port.afterBeforeMutation = () {
          expect(
            harness.journal.requiresConfirmation(mr6b3Account, {mr6b3WriteKey}),
            isFalse,
          );
          harness.policy.clientMayStart = false;
        };
        final outcome = await harness.approve((await harness.proposeState())!);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.mutationCount, 0);
        expect(harness.port.sends, 0);
        expect(
          harness.journal.entries(mr6b3Account).last.state,
          AiJournalState.notExecuted,
        );
        expect(
          harness.journal.requiresConfirmation(mr6b3Account, {mr6b3WriteKey}),
          isTrue,
        );
      },
    );

    test('markDispatching flush completes before acceptance or send', () async {
      final proposal = await harness.proposeState();
      final markEntered = harness.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = harness.approve(proposal!);
      await markEntered;
      expect(harness.port.sends, 0);
      expect(harness.port.events, isNot(contains('accepted')));
      final durable = await harness.readDurableJournal();
      final entries = durable['entries']! as List<Object?>;
      expect((entries.last! as Map<String, Object?>)['state'], 'dispatching');
      harness.files.releaseBarrier();
      final outcome = await pending;
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.mutationCount, 1);
      expect(harness.port.sends, 1);
    });

    test('accepted verified result succeeds with one mutation', () async {
      final outcome = await harness.approve((await harness.proposeState())!);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.mutationCount, 1);
      expect(outcome.readbackConfirmed, isTrue);
      expect(harness.port.sends, 1);
      expect(
        harness.journal.entries(mr6b3Account).last.state,
        AiJournalState.succeeded,
      );
    });

    for (final mode in [
      Mr6b3MutationMode.noop,
      Mr6b3MutationMode.preflightRefused,
      Mr6b3MutationMode.hookReturnedResult,
      Mr6b3MutationMode.accepted,
    ]) {
      test('$mode display failure after durable settlement is not a journal failure', () async {
        harness.port.mode = mode;
        var failed = false;
        harness.safeDisplay = (value) {
          final entries = harness.journal.entries(mr6b3Account);
          if (!failed && entries.isNotEmpty &&
              const {AiJournalState.notExecuted, AiJournalState.succeeded}
                  .contains(entries.last.state)) {
            failed = true;
            throw StateError('syntheticPostSettlementDisplayFailure');
          }
          return value;
        };
        final proposal = (await harness.proposeState())!;
        final writesBefore = harness.files.writeCount;
        final outcome = await harness.approve(proposal);
        expect(failed, isTrue);
        expect(outcome.reasonCode, isNot('journalUnavailable'));
        final sent = mode == Mr6b3MutationMode.accepted;
        expect(outcome.mutationCount, sent ? 1 : 0);
        expect(harness.port.sends, sent ? 1 : 0);
        final marked = sent || mode == Mr6b3MutationMode.hookReturnedResult;
        expect(harness.files.writeCount - writesBefore, marked ? 3 : 2);
        expect(harness.journal.entries(mr6b3Account).last.state,
            sent ? AiJournalState.succeeded : AiJournalState.notExecuted);
        final durable = await harness.readDurableJournal();
        expect(((durable['entries']! as List).last as Map)['state'],
            sent ? 'succeeded' : 'notExecuted');
        expect(harness.journal.isolated(mr6b3Account, {mr6b3WriteKey}), isFalse);
        harness.beginRun();
        expect(await harness.proposeState(), isNotNull);
      });
    }

    for (final scenario in <({String name, Object? value, Object? error})>[
      (
        name: 'payload errors',
        value: const GraphWriteResult(
          mutationSent: true,
          acknowledged: false,
          readbackVerified: true,
          projection: {
            'errors': <Object?>['synthetic'],
          },
        ),
        error: null,
      ),
      (name: 'API 401', value: null, error: api401()),
      (
        name: 'ordinary exception',
        value: null,
        error: StateError('synthetic accepted error'),
      ),
      (
        name: 'false evidence flags',
        value: const GraphWriteResult(mutationSent: false),
        error: null,
      ),
      (name: 'unknown return type', value: 'synthetic', error: null),
    ]) {
      test('accepted ${scenario.name} is always writeUncertain', () async {
        harness.port.acceptedValue = scenario.value;
        harness.port.acceptedError = scenario.error;
        final outcome = await harness.approve((await harness.proposeState())!);
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(outcome.mutationCount, 1);
        expect(harness.port.sends, 1);
        expect(
          harness.journal.entries(mr6b3Account).last.state,
          AiJournalState.writeUncertain,
        );
        expect(harness.journal.isolated(mr6b3Account, {mr6b3WriteKey}), isTrue);
      });
    }

    test(
      'mark flush failure reports journalUnavailable and never sends',
      () async {
        final proposal = await harness.proposeState();
        harness.files.failWriteNumber = harness.files.writeCount + 2;
        final outcome = await harness.approve(proposal!);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'journalUnavailable');
        expect(outcome.mutationCount, 0);
        expect(harness.port.sends, 0);
        expect(
          harness.journal.entries(mr6b3Account).last.state,
          isNot(AiJournalState.succeeded),
        );
        final prepares = harness.port.prepareCount;
        harness.beginRun();
        expect(await harness.proposeState(), isNull);
        expect(harness.port.prepareCount, prepares);
      },
    );

    test(
      'terminal flush failure stays isolated and journalUnavailable',
      () async {
        final proposal = await harness.proposeState();
        harness.files.failWriteNumber = harness.files.writeCount + 3;
        final outcome = await harness.approve(proposal!);
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(outcome.reasonCode, 'journalUnavailable');
        expect(outcome.mutationCount, 1);
        expect(harness.port.sends, 1);
        expect(harness.journal.isolated(mr6b3Account, {mr6b3WriteKey}), isTrue);
        final prepares = harness.port.prepareCount;
        harness.beginRun();
        expect(await harness.proposeState(), isNull);
        expect(harness.port.prepareCount, prepares);
      },
    );

    test(
      'revert flush failure stays isolated and journalUnavailable',
      () async {
        final proposal = await harness.proposeState();
        harness.port.afterBeforeMutation = () {
          harness.policy.clientMayStart = false;
        };
        harness.files.failWriteNumber = harness.files.writeCount + 3;
        final outcome = await harness.approve(proposal!);
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(outcome.reasonCode, 'journalUnavailable');
        expect(outcome.mutationCount, 0);
        expect(harness.port.sends, 0);
        expect(harness.journal.isolated(mr6b3Account, {mr6b3WriteKey}), isTrue);
        final prepares = harness.port.prepareCount;
        harness.beginRun();
        expect(await harness.proposeState(), isNull);
        expect(harness.port.prepareCount, prepares);
      },
    );
  });
}
