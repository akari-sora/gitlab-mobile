import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

/// Plan v6 §15 row 8: 「分級矩陣：五等級 × 各層級；參數升級
/// （…`confidential` 由 true 改 false、可見度…）；複合效果取最高；
/// 固定確認清單在 bypass 下仍需確認。」
///
/// The delivered graph rows expose no confidentiality/visibility, branch or CI
/// parameter. Their exact argument sets below make a future addition require a
/// new escalation test. Plan v6 §4.1: bypass executes a bound T4 deletion
/// without the typed name; every level below bypass requires it.
/// NOT_RUN row 8: non-graph operation matrices, protected/default branch,
/// pipeline/job/schedule, file/tag and composite-effect-specific behavior.
/// NOT_RUN row 8: actual confidentiality/visibility argument escalation (only
/// synthetic tier facts are exercised; graph has no such argument), and an
/// independent archived/protected policy fence.

const _t2 = <String>[
  'updateWorkItemState',
  'updateWorkItemStatus',
  'updateWorkItemDates',
  'updateWorkItemHealthStatus',
  'updateWorkItemWeight',
  'updateWorkItemMilestone',
  'updateWorkItemAssignees',
  'createWorkItemActivityComment',
  'createWorkItemActivityReply',
  'setIncidentStatus',
];

const _t1 = <({String operation, String prompt, Map<String, Object?> args})>[
  (operation: 'snoozeTodo', prompt: 'Snooze this todo.', args: {}),
  (operation: 'unsnoozeTodo', prompt: 'Unsnooze this todo.', args: {}),
  (
    operation: 'setWorkItemNotifications',
    prompt: 'Turn notifications on.',
    args: {'enabled': true},
  ),
  (
    operation: 'setWorkItemNotifications',
    prompt: 'Turn notifications off.',
    args: {'enabled': false},
  ),
  (
    operation: 'setWorkItemActivityNoteReaction',
    prompt: 'React to the comment note #401.',
    args: {'add': true},
  ),
  (
    operation: 'setWorkItemActivityNoteReaction',
    prompt: 'Remove the comment reaction note #401.',
    args: {'add': false},
  ),
];

void main() {
  group('§15 row 8 five autonomy levels and real graph dispatch', () {
    for (final level in AiAutonomyLevel.values) {
      for (final scenario in _t1) {
        test(
          '${level.name} T1 ${scenario.operation} ${scenario.args}',
          () async {
            final h = await _harness(level);
            h.server.notificationsOn = scenario.args['enabled'] == false;
            h.server.reactionAwarded = scenario.args['add'] == false;
            h.coordinator.beginRun('${scenario.prompt} Work item #3.');
            h.coordinator.beginTurn();
            final call = _call(scenario.operation, scenario.args);
            final proposal = await h.coordinator.propose(call);
            if (level == AiAutonomyLevel.readOnly) {
              expect(proposal, isNull);
              expect(
                h.coordinator.outcomeFor(call.id)?.reasonCode,
                'policyDenied',
              );
              expect(h.server.adapter.requests, isEmpty);
            } else {
              expect(proposal, isNotNull);
              expect(proposal!.tier.tier, AiWriteTier.t1);
              final automatic =
                  level.index >= AiAutonomyLevel.lowRiskAuto.index;
              expect(
                proposal.tier.decision,
                automatic
                    ? AiGateDecision.execute
                    : AiGateDecision.requireApproval,
              );
              expect(h.server.mutations, 0);
              final outcome = automatic
                  ? await h.coordinator.execute(call)
                  : await h.approve(proposal);
              expect(
                outcome.state,
                AiJournalState.succeeded,
                reason: outcome.reasonCode,
              );
              expect(outcome.mutationCount, 1);
              expect(h.server.mutations, 1);
            }
          },
        );
      }
      for (final operation in _t2) {
        test('${level.name} T2 $operation', () async {
          final h = await _harness(level);
          h.coordinator.beginRun('Update work item #3 and note #401.');
          h.coordinator.beginTurn();
          final call = _call(operation, const {});
          final proposal = await h.coordinator.propose(call);
          if (level == AiAutonomyLevel.readOnly) {
            expect(proposal, isNull);
            expect(
              h.coordinator.outcomeFor(call.id)?.reasonCode,
              'policyDenied',
            );
            expect(h.server.adapter.requests, isEmpty);
          } else {
            expect(proposal, isNotNull, reason: operation);
            expect(proposal!.tier.tier, AiWriteTier.t2);
            final automatic =
                level.index >= AiAutonomyLevel.conversationGrant.index;
            expect(
              proposal.tier.decision,
              automatic
                  ? AiGateDecision.execute
                  : AiGateDecision.requireApproval,
            );
            expect(h.server.mutations, 0);
            final outcome = automatic
                ? await h.coordinator.execute(call)
                : await h.approve(proposal);
            expect(
              outcome.state,
              AiJournalState.succeeded,
              reason: '$operation ${outcome.reasonCode}',
            );
            expect(outcome.mutationCount, 1);
            expect(h.server.mutations, 1);
          }
        });
      }
      test(
        '${level.name} T4 own-note deletion gate and typed-name boundary',
        () async {
          final h = await _harness(level);
          h.coordinator.beginRun('Delete note #401 from work item #3.');
          h.coordinator.beginTurn();
          final call = _call('deleteWorkItemActivityNote', const {});
          final proposal = await h.coordinator.propose(call);
          if (level == AiAutonomyLevel.readOnly) {
            expect(proposal, isNull);
            expect(h.server.adapter.requests, isEmpty);
            expect(h.server.mutations, 0);
            return;
          }
          expect(proposal, isNotNull);
          expect(proposal!.tier.tier, AiWriteTier.t4);
          expect(proposal.tier.typedName, '#3');
          expect(h.server.mutations, 0);
          if (level == AiAutonomyLevel.bypass) {
            // Plan v6 §4.1: bypass executes T4 automatically once the §2
            // target binding holds; the typed name applies below bypass.
            // Actual automatic deletion and journal/dispatch correspondence
            // are exercised in mr6b3_guard_test.dart.
            expect(proposal.tier.decision, AiGateDecision.execute);
            expect(proposal.tier.requiresTypedName, isFalse);
            expect(proposal.tier.reasons, isEmpty);
            await h.coordinator.reject(proposal);
            expect(h.server.mutations, 0);
            return;
          }
          expect(proposal.tier.decision, AiGateDecision.requireApproval);
          expect(proposal.tier.requiresTypedName, isTrue);
          final wrong = await h.coordinator.approve(proposal, typedName: '#4');
          expect(wrong.state, AiJournalState.notExecuted);
          expect(wrong.reasonCode, 'typedNameMismatch');
          expect(h.server.mutations, 0);
          final outcome = await h.approve(proposal);
          expect(outcome.state, AiJournalState.succeeded);
          expect(h.server.mutations, 1);
        },
      );
    }
  });

  test('§15 row 8 bypass unbound T4 deletion requires a card', () async {
    final h = await _harness(AiAutonomyLevel.bypass);
    h.coordinator.beginRun('Delete a note.');
    h.coordinator.beginTurn();
    final proposal = await h.coordinator.propose(
      _call('deleteWorkItemActivityNote', const {}),
    );
    expect(proposal, isNotNull);
    expect(proposal!.tier.tier, AiWriteTier.t4);
    expect(proposal.tier.decision, AiGateDecision.requireApproval);
    expect(proposal.tier.reasons, contains(AiFixedConfirmReason.targetUnbound));
    expect(h.server.mutations, 0);
    expect(h.journal.entries(mr6b3Account), isEmpty);
  });

  test(
    '§15 row 8 bypass same-run repeated graph comment needs confirmation',
    () async {
      final h = await _harness(AiAutonomyLevel.bypass);
      h.coordinator.beginRun('Comment on work item #3.');
      h.coordinator.beginTurn();
      final first = _call('createWorkItemActivityComment', const {});
      final proposed = await h.coordinator.propose(first);
      expect(proposed, isNotNull);
      expect(proposed!.tier.decision, AiGateDecision.execute);
      final result = await h.coordinator.execute(first);
      expect(result.state, AiJournalState.succeeded, reason: result.reasonCode);
      expect(h.server.mutations, 1);
      final repeated = await h.coordinator.propose(
        AiToolCall(
          id: 'matrix-repeated-comment',
          name: first.name,
          arguments: first.arguments,
        ),
      );
      expect(repeated, isNotNull);
      expect(repeated!.tier.decision, AiGateDecision.requireApproval);
      expect(
        repeated.tier.reasons,
        contains(AiFixedConfirmReason.duplicateOfSettledWrite),
      );
      expect(h.server.mutations, 1);
    },
  );

  test(
    '§15 row 8 graph argument sets have no parameter-driven tier upgrades',
    () {
      const arguments = <String, Set<String>>{
        'updateWorkItemState': {'projectId', 'iid', 'stateEvent'},
        'updateWorkItemStatus': {'projectId', 'iid', 'candidateId'},
        'updateWorkItemDates': {
          'projectId',
          'iid',
          'mode',
          'startDate',
          'dueDate',
          'clearStart',
          'clearDue',
        },
        'updateWorkItemHealthStatus': {'projectId', 'iid', 'healthStatus'},
        'updateWorkItemWeight': {'projectId', 'iid', 'weight', 'clearWeight'},
        'updateWorkItemMilestone': {
          'projectId',
          'iid',
          'milestoneTitle',
          'clearMilestone',
        },
        'updateWorkItemAssignees': {'projectId', 'iid', 'assigneeUsernames'},
        'createWorkItemActivityComment': {'projectId', 'iid', 'body'},
        'createWorkItemActivityReply': {
          'projectId',
          'iid',
          'anchorNoteId',
          'body',
        },
        'deleteWorkItemActivityNote': {'projectId', 'iid', 'noteId'},
        'setWorkItemNotifications': {'projectId', 'iid', 'enabled'},
        'setWorkItemActivityNoteReaction': {
          'projectId',
          'iid',
          'noteId',
          'name',
          'add',
        },
        'setIncidentStatus': {'projectId', 'iid', 'status'},
        'snoozeTodo': {'todoId', 'until'},
        'unsnoozeTodo': {'todoId'},
      };
      expect(arguments, hasLength(15));
      for (final entry in arguments.entries) {
        final row = productionAiLedger.find(entry.key)!;
        expect(row.boundary, AiWriteBoundary.graph);
        expect(row.arguments.keys.toSet(), entry.value, reason: entry.key);
        expect(
          _decision(entry.key, AiAutonomyLevel.conversationGrant).tier,
          row.baseTier,
          reason: entry.key,
        );
      }
    },
  );

  for (final field in [
    'confidential',
    'visibility',
    'protected',
    'removeSourceBranch',
    'variables',
  ]) {
    test(
      '§15 row 8 graph state rejects undeclared escalation parameter $field',
      () async {
        final h = await _harness(AiAutonomyLevel.bypass);
        final proposal = await h.propose(
          'updateWorkItemState',
          id: 'unknown',
          arguments: {field: false},
        );
        expect(proposal, isNull);
        expect(
          h.coordinator.outcomeFor('unknown')?.reasonCode,
          'invalidArguments',
        );
        expect(h.server.adapter.requests, isEmpty);
        expect(h.server.mutations, 0);
      },
    );
  }

  test(
    '§15 row 8 trusted confidentiality escalation stays hard-line in bypass',
    () {
      final decision = _decision(
        'updateWorkItemState',
        AiAutonomyLevel.bypass,
        facts: const AiTierFacts(confidentialLowered: true),
      );
      expect(decision.tier, AiWriteTier.hardLine);
      expect(decision.decision, AiGateDecision.requireApproval);
      expect(decision.requiresTypedName, isTrue);
    },
  );

  test(
    '§15 row 8 fixed confirmation survives bypass for a real graph comment',
    () async {
      final h = await _harness(AiAutonomyLevel.bypass);
      final proposal = await h.propose(
        'createWorkItemActivityComment',
        arguments: {'body': '@all\nCloses team/foreign#99'},
      );
      expect(proposal, isNotNull);
      expect(proposal!.tier.decision, AiGateDecision.requireApproval);
      expect(
        proposal.tier.reasons,
        containsAll({
          AiFixedConfirmReason.massMention,
          AiFixedConfirmReason.foreignClosingOrCrossProject,
        }),
      );
      expect(h.server.mutations, 0);
    },
  );

  test(
    '§15 row 8 manual-release mark forces graph state confirmation below bypass',
    () async {
      final h = await _harness(AiAutonomyLevel.conversationGrant);
      await h.seedConfirmMark();
      final proposal = await h.propose('updateWorkItemState');
      expect(proposal, isNotNull);
      expect(proposal!.tier.decision, AiGateDecision.requireApproval);
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.confirmMarkAfterManualRelease),
      );
      expect(h.server.mutations, 0);
    },
  );

  test(
    '§15 row 8 server work-item permission denial refuses graph state',
    () async {
      final h = await _harness(AiAutonomyLevel.bypass);
      var projectReads = 0;
      h.server.onRequest = (name, mutation, request, payload) {
        if (name == 'freshness') {
          payload['archived'] = true;
          projectReads++;
        }
        if (name == 'MobileWorkItemState') {
          final item = (payload['data']! as Map)['workItem']! as Map;
          (item['userPermissions']! as Map)['updateWorkItem'] = false;
        }
        return null;
      };
      final proposal = await h.propose('updateWorkItemState', id: 'archived');
      expect(projectReads, 1);
      expect(proposal, isNull);
      expect(
        h.coordinator.outcomeFor('archived')?.reasonCode,
        'stateForbidden',
      );
      expect(h.server.mutations, 0);
      // These methods write no branch. The server's work-item permission is the
      // observable denial fence; no dedicated archived/protected fact is exposed.
    },
  );
}

Future<Mr6b3ApiHarness> _harness(AiAutonomyLevel level) async {
  final h = await Mr6b3ApiHarness.create(oauth: false);
  h.policy.level = level;
  addTearDown(h.dispose);
  return h;
}

AiToolCall _call(String operation, Map<String, Object?> arguments) =>
    AiToolCall(
      id: 'matrix-$operation',
      name: operation,
      arguments: {
        ...mr6b3ApiArguments(operation),
        ...arguments,
        'reason': 'synthetic graph matrix request',
      },
    );

AiTierDecision _decision(
  String operation,
  AiAutonomyLevel level, {
  AiTierFacts facts = const AiTierFacts(),
}) => decideListed(
  ledger: productionAiLedger,
  operationId: operation,
  build: (capability) => AiTierInput(
    level: level,
    capability: capability,
    scope: mr6b3Scope,
    binding: const AiBindingResult(
      userMessage: 'synthetic trusted request',
      allBound: true,
      intentAuthorizesLowRisk: true,
    ),
    target: AiTargetRef(
      kind: operation.endsWith('Todo') ? AiTargetKind.todo : AiTargetKind.issue,
      projectId: 9,
      iid: 3,
      parentIid: 3,
    ),
    typedName: '#3',
    facts: facts,
    arguments: mr6b3ApiArguments(operation),
  ),
);
