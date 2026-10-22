// C6 (account removal hold) and C10 (backgrounding): a hold pauses a waiting
// proposal; it never ends it. Dispatch still refuses while the hold lasts.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart';

void main() {
  late CoordHarness h;

  setUp(() async {
    h = await CoordHarness.create();
  });

  tearDown(() async {
    await h.dispose();
  });

  test('C6 a removal hold pauses a waiting proposal; cancelling the stop '
      'dialog keeps it and approve dispatches', () async {
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final proposal = (await h.coordinator.propose(starCall('hold')))!;
    expect(proposal.tier.decision, AiGateDecision.requireApproval);

    final job = h.journal.beginRemoval(coordAccount);
    h.coordinator.checkNow();

    // ignore: avoid_print
    print(
      'PROBE duringHold valid=${proposal.valid} '
      'waiting=${h.coordinator.proposals.length} '
      'held=${proposal.accountRemovalHeld}',
    );
    expect(proposal.valid, isTrue);
    expect(h.coordinator.proposals, contains(proposal));
    expect(proposal.accountRemovalHeld, isTrue);
    expect(proposal.pausedReason, AiWritePause.accountRemovalHeld);
    expect(h.coordinator.outcomeFor('hold'), isNull);

    // §8 step 1: approval is refused while held, and nothing is sent.
    final refused = await h.coordinator.approve(proposal);
    expect(refused.state, AiJournalState.notExecuted);
    expect(refused.reasonCode, 'accountBlocked');
    expect(refused.mutationCount, 0);
    expect(h.mutations, 0);
    expect(h.journal.entries(coordAccount), isEmpty);
    expect(proposal.valid, isTrue);
    expect(h.coordinator.proposals, contains(proposal));

    // §8 step 2: cancelling the stop dialog releases the hold without
    // bumping the epoch; the proposal carries on.
    job.release(job.token);
    h.coordinator.checkNow();
    final outcome = h.coordinator.outcomeFor('hold');
    // ignore: avoid_print
    print(
      'PROBE afterCancel valid=${proposal.valid} '
      'waiting=${h.coordinator.proposals.length} '
      'outcome=${outcome?.reasonCode}',
    );
    expect(proposal.valid, isTrue);
    expect(h.coordinator.proposals, contains(proposal));
    expect(proposal.accountRemovalHeld, isFalse);
    expect(outcome, isNull);

    final done = await h.coordinator.approve(proposal);
    expect(done.state, AiJournalState.succeeded, reason: done.reasonCode);
    expect(h.mutations, 1);
  });

  test(
    'C6 the one-second check keeps a held proposal across many ticks',
    () async {
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      final proposal = (await h.coordinator.propose(starCall('ticks')))!;
      final job = h.journal.beginRemoval(coordAccount);
      for (var i = 0; i < 5; i++) {
        h.clock = h.clock.add(const Duration(seconds: 1));
        h.coordinator.checkNow();
      }
      expect(proposal.valid, isTrue);
      expect(proposal.accountRemovalHeld, isTrue);
      job.release(job.token);
      h.coordinator.checkNow();
      expect(proposal.accountRemovalHeld, isFalse);
      expect(proposal.valid, isTrue);
    },
  );

  test('C6 a proposal made during the hold is refused', () async {
    final job = h.journal.beginRemoval(coordAccount);
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    expect(await h.coordinator.propose(starCall('during')), isNull);
    expect(h.coordinator.outcomeFor('during')?.reasonCode, 'accountBlocked');
    expect(h.adapter.requests, isEmpty);
    job.release(job.token);
  });

  test('C6 the removal tombstone still ends a waiting proposal', () async {
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final proposal = (await h.coordinator.propose(starCall('tombstone')))!;
    h.journal.noteTombstoneSet(coordAccount);
    h.coordinator.checkNow();
    expect(proposal.valid, isFalse);
    expect(h.coordinator.outcomeFor('tombstone')?.reasonCode, 'accountBlocked');
    expect(h.mutations, 0);
  });

  test(
    'C6 cancelling the final removal dialog ends the proposal (epoch)',
    () async {
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      final proposal = (await h.coordinator.propose(starCall('final')))!;
      h.journal.beginRemoval(coordAccount).cancelFinal();
      h.coordinator.checkNow();
      expect(proposal.valid, isFalse);
      expect(
        h.coordinator.outcomeFor('final')?.reasonCode,
        'proposalInvalidated',
      );
    },
  );

  test('C10 backgrounding holds a waiting proposal; approval in the '
      'background sends nothing, and back on screen it dispatches', () async {
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final proposal = (await h.coordinator.propose(starCall('away')))!;

    h.foreground = false;
    await h.coordinator.onAppBackground();
    h.coordinator.checkNow();
    expect(proposal.valid, isTrue);
    expect(proposal.pausedReason, AiWritePause.backgrounded);
    expect(h.coordinator.proposals, contains(proposal));

    final refused = await h.coordinator.approve(proposal);
    expect(refused.reasonCode, 'backgrounded');
    expect(refused.mutationCount, 0);
    expect(h.mutations, 0);
    expect(h.journal.entries(coordAccount), isEmpty);

    h.foreground = true;
    h.coordinator.checkNow();
    expect(proposal.pausedReason, isNull);
    final done = await h.coordinator.approve(proposal);
    expect(done.state, AiJournalState.succeeded, reason: done.reasonCode);
    expect(h.mutations, 1);
  });

  test('C10 a dispatch attempted while backgrounded is refused', () async {
    // Bypass executes setStar without a card; the app leaves the screen
    // during the dispatch's fresh read.
    h.level = AiAutonomyLevel.bypass;
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    h.barrierRead = 2;
    h.freshnessEntered = Completer<void>();
    h.releaseFreshness = Completer<void>();

    final running = h.coordinator.execute(starCall('auto'));
    await h.freshnessEntered!.future;
    final proposal = h.coordinator.proposals.single;
    expect(proposal.tier.decision, AiGateDecision.execute);
    h.foreground = false;
    h.releaseFreshness!.complete();
    final outcome = await running;

    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.reasonCode, 'backgrounded');
    expect(outcome.mutationCount, 0);
    expect(h.mutations, 0);
    expect(
      h.journal
          .entries(coordAccount)
          .where((entry) => entry.executionId == proposal.executionId)
          .single
          .state,
      AiJournalState.notExecuted,
    );
  });

  test('C10 a proposal made while backgrounded is refused', () async {
    h.foreground = false;
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    expect(await h.coordinator.propose(starCall('bg')), isNull);
    expect(h.coordinator.outcomeFor('bg')?.reasonCode, 'backgrounded');
    expect(h.adapter.requests, isEmpty);
  });
}
