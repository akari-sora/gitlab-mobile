// C2: markTodoDone in an issue conversation. The port's pre-read of the todo
// decides its issue; the conversation's own issue's todo is marked done, any
// other is refused with zero mutations.

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart'
    show AiGateDecision;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';

Map<String, Object?> _todo(int id, int iid, {String type = 'Issue'}) => {
  'id': id,
  'state': 'pending',
  'action_name': 'assigned',
  'target_type': type,
  'project': {'id': 42, 'path_with_namespace': 'studio/mobile-workspace'},
  'target': {'id': 1000 + iid, 'iid': iid, 'project_id': 42},
};

Future<StackHarness> _issueChat({
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
}) => StackHarness.create(
  level: level,
  origin: AiWorkItemOrigin(
    project: Project.fromJson({
      'id': 42,
      'name': 'Mobile Workspace',
      'path_with_namespace': 'studio/mobile-workspace',
      'visibility': 'private',
      'default_branch': 'main',
      'archived': false,
      'last_activity_at': '2026-09-19T08:30:00Z',
    }),
    kind: AiWorkItemKind.issue,
    iid: 5,
    title: 'Synthetic five',
  ),
  configure: (server) {
    server.overrides['GET todos'] = (_) =>
        jsonResponse([_todo(900, 5), _todo(901, 6)]);
    for (final id in [900, 901]) {
      server.overrides['POST todos/$id/mark_as_done'] = (_) => jsonResponse({
        ..._todo(id, id == 900 ? 5 : 6),
        'state': 'done',
      }, status: 201);
    }
  },
);

void main() {
  test('C2 an issue conversation marks its own issue\'s todo done', () async {
    final h = await _issueChat();
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn('markTodoDone', {
        'todoId': 900,
        'reason': 'The user asked to mark this todo done.',
      }),
    );

    final sending = h.controller.send('Mark this todo done');
    await waitFor(() => h.controller.proposals.isNotEmpty);
    final proposal = h.controller.proposals.single;
    expect(proposal.operationId, 'markTodoDone');
    expect(proposal.tier.tier, AiWriteTier.t1);
    expect(proposal.tier.decision, AiGateDecision.requireApproval);
    expect(
      proposal.tier.reasons,
      isNot(contains(AiFixedConfirmReason.targetUnbound)),
    );
    expect(proposal.releaseName, '@developer');
    final outcome = await h.controller.approveWrite(proposal);
    await sending;

    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(h.server.mutations, hasLength(1));
    expect(
      h.server.mutations.single.uri.path,
      endsWith('/todos/900/mark_as_done'),
    );
  });

  test(
    'C2 bypass marks the conversation\'s own todo done without a card',
    () async {
      final h = await _issueChat(level: AiAutonomyLevel.bypass);
      addTearDown(h.dispose);
      h.provider.script.add(
        (_) => toolTurn('markTodoDone', {'todoId': 900, 'reason': 'Asked.'}),
      );
      final waited = await h.sendAndApprove('Mark this todo done');
      expect(waited, isNull);
      expect(h.server.mutations, hasLength(1));
      expect(
        h.server.mutations.single.uri.path,
        endsWith('/todos/900/mark_as_done'),
      );
    },
  );

  test('C2 another issue\'s todo is refused with zero mutations', () async {
    for (final level in [AiAutonomyLevel.confirmEach, AiAutonomyLevel.bypass]) {
      final h = await _issueChat(level: level);
      h.provider.script.add(
        (_) => toolTurn('markTodoDone', {'todoId': 901, 'reason': 'Asked.'}),
      );
      final waited = await h.sendAndApprove('Mark this todo done');
      expect(waited, isNull, reason: 'no card for a foreign todo ($level)');
      expect(h.controller.proposals, isEmpty);
      expect(h.server.mutations, isEmpty, reason: '$level');
      // The model was told the write did not run.
      expect(h.provider.bodies.last, contains('write markTodoDone'));
      expect(h.provider.bodies.last, contains('notExecuted'));
      h.dispose();
    }
  });

  test('C2 a todo the account does not have is refused', () async {
    final h = await _issueChat(level: AiAutonomyLevel.bypass);
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn('markTodoDone', {'todoId': 999, 'reason': 'Asked.'}),
    );
    await h.sendAndApprove('Mark this todo done');
    expect(h.server.mutations, isEmpty);
  });
}
