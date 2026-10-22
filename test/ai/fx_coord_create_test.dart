// C3 and C5: a create is not a write back. `confidential: false` on a new
// issue does not lower confidentiality, and the project record a create is
// read against is neither its current field value nor its revision.

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart'
    show AiGateDecision;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart';

const _hex = 'abcdefabcdefabcdefabcdefabcdef01';

void main() {
  test('C3 createIssue with confidential: false is the normal T2 tier, '
      'not a hard line', () async {
    final h = await StackHarness.create();
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn('createIssue', {
        'projectId': 42,
        'fields': {'title': 'Synthetic bug', 'confidential': false},
        'reason': 'The user asked for an issue.',
      }),
    );

    final sending = h.controller.send('Create an issue for the bug');
    await waitFor(() => h.controller.proposals.isNotEmpty);
    final proposal = h.controller.proposals.single;
    expect(proposal.operationId, 'createIssue');
    expect(proposal.tier.tier, AiWriteTier.t2);
    expect(proposal.tier.requiresTypedName, isFalse);
    expect(proposal.tier.decision, AiGateDecision.requireApproval);

    final outcome = await h.controller.approveWrite(proposal);
    await sending;
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    final post = h.server.mutations.single;
    expect(post.method, 'POST');
    expect(post.uri.path, endsWith('/projects/42/issues'));
    expect((post.data as Map)['confidential'], isFalse);
  });

  test(
    'C3 updateIssue confidential true -> false is still a hard line',
    () async {
      final h = await StackHarness.create(
        configure: (server) => server.workspace.issues[6] = server.workspace
            .issue(6, 'Secret six', confidential: true),
      );
      addTearDown(h.dispose);
      h.provider.script.add(
        (_) => toolTurn('updateIssue', {
          'projectId': 42,
          'iid': 6,
          'fields': {'confidential': false},
          'reason': 'The user asked.',
        }),
      );

      final sending = h.controller.send('Make #6 public');
      await waitFor(() => h.controller.proposals.isNotEmpty);
      final proposal = h.controller.proposals.single;
      expect(proposal.tier.tier, AiWriteTier.hardLine);
      expect(proposal.tier.requiresTypedName, isTrue);
      await h.controller.rejectWrite(proposal);
      await sending;
      expect(h.server.mutations, isEmpty);
    },
  );

  test('C5 a project description with an upload link does not make '
      'createIssue "remove hidden content"', () async {
    final h = await StackHarness.create(
      level: AiAutonomyLevel.conversationGrant,
      configure: (server) => server.workspace.projectRecord['description'] =
          'Overview ![shot](/uploads/$_hex/shot.png)',
    );
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn('createIssue', {
        'projectId': 42,
        'fields': {
          'title': 'Synthetic bug',
          'description': 'Steps to reproduce: open the app.',
        },
        'reason': 'The user asked for an issue.',
      }),
    );

    // Conversation grant runs T2 without a card unless a fixed reason asks
    // for one; "removes N hidden segments" would be such a reason.
    final waited = await h.sendAndApprove('Create an issue for the bug');
    expect(waited, isNull, reason: 'no card: nothing hidden is removed');
    final post = h.server.mutations.single;
    expect(post.uri.path, endsWith('/projects/42/issues'));
    expect(
      (post.data as Map)['description'],
      'Steps to reproduce: open the app.',
    );
  });

  test('C5 the reasons of a waiting createIssue have no hidden-content '
      'reason', () async {
    final h = await StackHarness.create(
      configure: (server) => server.workspace.projectRecord['description'] =
          'Overview ![shot](/uploads/$_hex/shot.png)',
    );
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn('createIssue', {
        'projectId': 42,
        'fields': {'title': 'Synthetic bug', 'description': 'Body text.'},
        'reason': 'The user asked for an issue.',
      }),
    );
    final sending = h.controller.send('Create an issue for the bug');
    await waitFor(() => h.controller.proposals.isNotEmpty);
    final proposal = h.controller.proposals.single;
    expect(
      proposal.tier.reasons,
      isNot(contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans)),
    );
    await h.controller.rejectWrite(proposal);
    await sending;
  });

  test('C5 a project update between proposal and approval does not stop a '
      'createIssue', () async {
    final h = await StackHarness.create(
      configure: (server) =>
          server.workspace.projectRecord['updated_at'] = '2026-10-23T01:00:00Z',
    );
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn('createIssue', {
        'projectId': 42,
        'fields': {'title': 'Synthetic bug'},
        'reason': 'The user asked for an issue.',
      }),
    );
    final sending = h.controller.send('Create an issue for the bug');
    await waitFor(() => h.controller.proposals.isNotEmpty);
    // Someone pushes; the project record moves on.
    h.server.workspace.projectRecord['updated_at'] = '2026-10-23T02:00:00Z';
    final outcome = await h.controller.approveWrite(
      h.controller.proposals.single,
    );
    await sending;
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(h.server.mutations, hasLength(1));
  });

  test('C5 an update still compares its own revision', () async {
    final h = await StackHarness.create();
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn('updateIssue', {
        'projectId': 42,
        'iid': 5,
        'fields': {'title': 'Renamed'},
        'reason': 'The user asked.',
      }),
    );
    final sending = h.controller.send('Rename #5');
    await waitFor(() => h.controller.proposals.isNotEmpty);
    h.server.workspace.issues[5]!['updated_at'] = 'someone-else-edited';
    final outcome = await h.controller.approveWrite(
      h.controller.proposals.single,
    );
    await sending;
    expect(outcome.reasonCode, 'targetChanged');
    expect(h.server.mutations, isEmpty);
  });
}
