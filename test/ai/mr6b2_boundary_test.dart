import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b2_support.dart';

import '../support/fake_adapter.dart';

typedef _Invalidate = FutureOr<void> Function(Mr6b2Harness harness);

void main() {
  late Mr6b2Harness harness;

  setUp(() async {
    harness = await Mr6b2Harness.create();
  });

  tearDown(() => harness.dispose());

  Future<AiWriteOutcome> invalidateAtDispatchFlush(
    String operation,
    _Invalidate invalidate,
  ) async {
    harness.beginRun();
    final proposal = await harness.propose(operation, mr6b2Args(operation));
    expect(proposal, isNotNull, reason: operation);
    final entered = harness.files.armBarrier(
      writesBeforeBarrier: 1,
      afterPersist: true,
    );
    final pending = harness.approve(proposal!);
    await entered;
    final durable = await harness.readDurableJournal();
    final entries = durable['entries']! as List<Object?>;
    expect((entries.last! as Map<String, Object?>)['state'], 'dispatching');
    await invalidate(harness);
    harness.files.releaseBarrier();
    return pending;
  }

  for (final entry
      in <({String operation, String invalidation, _Invalidate invalidate})>[
        (
          operation: 'mergeRequest',
          invalidation: 'policy revision',
          invalidate: (h) => h.policy.writePolicyRevision++,
        ),
        (
          operation: 'edit_file',
          invalidation: 'consent',
          invalidate: (h) => h.policy.consentValid = false,
        ),
        (
          operation: 'pipelineAction',
          invalidation: 'stop',
          invalidate: (h) => h.coordinator.stop('syntheticStop'),
        ),
        (
          operation: 'mergeRequest',
          invalidation: 'generation',
          invalidate: (h) => h.policy.sessionGeneration++,
        ),
        (
          operation: 'edit_file',
          invalidation: 'closed client',
          invalidate: (h) => h.policy.clientMayStart = false,
        ),
        (
          operation: 'jobAction',
          invalidation: 'background without permit',
          invalidate: (h) => h.policy.appInForeground = false,
        ),
        (
          operation: 'mergeRequest',
          invalidation: 'cancelled removal epoch',
          invalidate: (h) => h.journal.beginRemoval(mr6b2Account).cancelFinal(),
        ),
        (
          operation: 'edit_file',
          invalidation: 'removal tombstone',
          invalidate: (h) => h.journal.noteTombstoneSet(mr6b2Account),
        ),
        (
          operation: 'pipelineAction',
          invalidation: 'actual closed API client',
          invalidate: (h) => h.server.api.close(),
        ),
        (
          operation: 'jobAction',
          invalidation: 'Retry-After learned by another read',
          invalidate: (h) async {
            h.server.overrides['GET projects/9'] = (_) => jsonResponse(
              {'message': 'slow down'},
              status: 429,
              headers: {
                'retry-after': ['60'],
              },
            );
            try {
              await h.server.api.project('9', refresh: true);
            } on Object {
              // The point is the client's remembered Retry-After gate.
            }
            expect(h.server.api.mayStartRequest, isFalse);
          },
        ),
      ]) {
    test(
      '§15 row 29 ${entry.operation} ${entry.invalidation} during dispatch flush sends zero mutations',
      () async {
        final outcome = await invalidateAtDispatchFlush(
          entry.operation,
          entry.invalidate,
        );
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.mutationCount, 0);
        expect(harness.server.mutationCount(), 0);
        expect(
          harness.journal.entries(mr6b2Account).last.state,
          AiJournalState.notExecuted,
        );
        expect(
          harness.journal.conversationWriteCount(
            mr6b2Account,
            harness.conversationId,
          ),
          0,
        );
      },
    );
  }

  test('§15 row 29 prepared flush failure stays zero mutation', () async {
    harness.beginRun();
    final proposal = await harness.propose(
      'mergeRequest',
      mr6b2Args('mergeRequest'),
    );
    harness.files.failWriteNumber = harness.files.writeCount + 1;
    final outcome = await harness.approve(proposal!);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.mutationCount, 0);
    expect(harness.server.mutationCount(), 0);
    expect(
      harness.journal.conversationWriteCount(
        mr6b2Account,
        harness.conversationId,
      ),
      0,
    );
  });

  test(
    '§15 row 29 rollback flush failure remains isolated without mutation',
    () async {
      harness.beginRun();
      final proposal = await harness.propose(
        'edit_file',
        mr6b2Args('edit_file'),
      );
      final entered = harness.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = harness.approve(proposal!);
      await entered;
      harness.policy.consentValid = false;
      harness.files.failAfterWriteNumber = harness.files.writeCount;
      harness.files.releaseBarrier();
      final outcome = await pending;
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.mutationCount, 0);
      expect(harness.server.mutationCount(), 0);
      expect(
        harness.journal.entries(mr6b2Account).last.state,
        AiJournalState.dispatching,
      );
      expect(
        harness.journal.isolated(
          mr6b2Account,
          harness.journal.entries(mr6b2Account).last.writeKeys,
        ),
        isTrue,
      );
    },
  );

  test(
    '§15 row 29 terminal flush failure becomes uncertain after one mutation',
    () async {
      harness.beginRun();
      final proposal = await harness.propose(
        'pipelineAction',
        mr6b2Args('pipelineAction'),
      );
      harness.files.failAfterWriteNumber = harness.files.writeCount + 2;
      final outcome = await harness.approve(proposal!);
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.mutationCount, 1);
      expect(harness.server.mutationCount(), 1);
      expect(
        harness.journal.entries(mr6b2Account).last.state,
        AiJournalState.writeUncertain,
      );
      final durable = await harness.readDurableJournal();
      final durableEntries = durable['entries']! as List<Object?>;
      expect(
        (durableEntries.last! as Map<String, Object?>)['state'],
        'dispatching',
      );
      harness.files.failAfterWriteNumber = null;
      final restarted = AiWriteJournal(
        keys: harness.keyStore!,
        applicationSupport: harness.root,
        files: harness.files,
        processId: 'mr6b2-restarted',
      );
      await restarted.recoverAfterAccountsLoaded([mr6b2Account]);
      expect(
        restarted.entries(mr6b2Account).last.state,
        AiJournalState.writeUncertain,
      );
    },
  );
}
