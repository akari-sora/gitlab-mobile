// C9 (§7.2): text the user edited on a card stays after a rejection, a
// certain failure, an unknown result or expiry, with the outcome; it is
// cleared only by a success confirmed by readback, the conversation's end,
// or a dismissal.

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart';

void main() {
  late CoordHarness h;

  setUp(() async {
    h = await CoordHarness.create();
    h.coordinator.beginRun('Comment on #3 in team/example-9');
    h.coordinator.beginTurn();
  });

  tearDown(() async {
    await h.dispose();
  });

  Future<AiWriteProposal> editedProposal(String id) async {
    final proposal = (await h.coordinator.propose(coordNoteCall(id)))!;
    final edit = await h.coordinator.approve(
      proposal,
      editedText: 'my own words for $id',
    );
    expect(edit.reasonCode, 'approvalRequired');
    expect(proposal.editedText, 'my own words for $id');
    return proposal;
  }

  test('C9 a rejected edited card stays with its outcome', () async {
    final proposal = await editedProposal('rejected');
    await h.coordinator.reject(proposal);

    expect(h.coordinator.proposals, isEmpty);
    expect(h.coordinator.settledEdits, [proposal]);
    expect(proposal.editedText, 'my own words for rejected');
    expect(proposal.outcome?.reasonCode, 'rejected');
    expect(proposal.outcome?.state, AiJournalState.notExecuted);
  });

  test('C9 an edited card stays after a certain failure', () async {
    final proposal = await editedProposal('failed');
    h.failWritesWith = 422;
    final outcome = await h.coordinator.approve(proposal);

    expect(outcome.state, AiJournalState.failedCertain);
    expect(h.coordinator.settledEdits, [proposal]);
    expect(proposal.editedText, 'my own words for failed');
    expect(proposal.outcome?.state, AiJournalState.failedCertain);
  });

  test('C9 an edited card stays after an unknown result', () async {
    final proposal = await editedProposal('unknown');
    h.failWritesWith = 500;
    final outcome = await h.coordinator.approve(proposal);

    expect(outcome.state, AiJournalState.writeUncertain);
    expect(h.coordinator.settledEdits, [proposal]);
    expect(proposal.outcome?.state, AiJournalState.writeUncertain);
  });

  test('C9 an edited card stays after expiry', () async {
    final proposal = await editedProposal('expired');
    h.clock = h.clock.add(const Duration(minutes: 31));
    h.coordinator.checkNow();

    expect(h.coordinator.proposals, isEmpty);
    expect(h.coordinator.settledEdits, [proposal]);
    expect(proposal.outcome?.reasonCode, 'approvalExpired');
    expect(proposal.editedText, 'my own words for expired');
  });

  test('C9 a success confirmed by readback clears the text', () async {
    final proposal = await editedProposal('success');
    final outcome = await h.coordinator.approve(proposal);

    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.readbackConfirmed, isTrue);
    expect(proposal.editedText, isNull);
    expect(h.coordinator.settledEdits, isEmpty);
    final body = h.adapter.requests
        .where((request) => request.method == 'POST')
        .single
        .data;
    expect((body as Map)['body'], 'my own words for success');
  });

  test('C9 an unedited card does not stay', () async {
    final proposal = (await h.coordinator.propose(coordNoteCall('plain')))!;
    await h.coordinator.reject(proposal);
    expect(h.coordinator.settledEdits, isEmpty);
  });

  test('C9 dismissing drops the card; the next run keeps it', () async {
    final first = await editedProposal('first');
    await h.coordinator.reject(first);
    h.newRun('Comment again');
    expect(h.coordinator.settledEdits, [first]);

    final second = await editedProposal('second');
    await h.coordinator.reject(second);
    expect(h.coordinator.settledEdits, [first, second]);

    expect(h.coordinator.dismissSettled(first), isTrue);
    expect(h.coordinator.dismissSettled(first), isFalse);
    expect(h.coordinator.settledEdits, [second]);
  });

  test('C9 a new conversation has no settled cards', () async {
    final proposal = await editedProposal('old');
    await h.coordinator.reject(proposal);
    expect(h.coordinator.settledEdits, hasLength(1));
    // The chat controller drops the coordinator with the conversation.
    h.coordinator = h.newCoordinator();
    expect(h.coordinator.settledEdits, isEmpty);
  });
}
