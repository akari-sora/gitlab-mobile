import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';

import 'mr6b2_support.dart';

void main() {
  group('§15 row 8 real-row matrix', () {
    const rows = <(String, AiWriteTier, AiTargetKind)>[
      ('setStar', AiWriteTier.t1, AiTargetKind.project),
      ('createNote', AiWriteTier.t2, AiTargetKind.issue),
      ('edit_file', AiWriteTier.t3, AiTargetKind.file),
      ('approveMergeRequest', AiWriteTier.t4, AiTargetKind.mergeRequest),
      ('createProject', AiWriteTier.hardLine, AiTargetKind.project),
    ];

    test('all five autonomy levels use delivered production rows', () {
      for (final level in AiAutonomyLevel.values) {
        for (final row in rows) {
          final decision = _decision(
            operation: row.$1,
            level: level,
            targetKind: row.$3,
          );
          expect(decision.tier, row.$2, reason: '${level.name} ${row.$1}');
          expect(
            decision.decision,
            _expected(level, row.$2),
            reason: '${level.name} ${row.$1}',
          );
          expect(
            decision.requiresTypedName,
            decision.decision == AiGateDecision.requireApproval &&
                (row.$2 == AiWriteTier.t4 || row.$2 == AiWriteTier.hardLine),
            reason: '${level.name} ${row.$1}',
          );
        }
      }
    });

    test('retry exception, hard floors, and fixed confirms survive bypass', () {
      final retry = _decision(
        operation: 'pipelineAction',
        level: AiAutonomyLevel.confirmEach,
        targetKind: AiTargetKind.pipeline,
        arguments: const {'action': 'retry'},
      );
      expect(retry.tier, AiWriteTier.t4);
      expect(retry.decision, AiGateDecision.requireApproval);
      expect(retry.requiresTypedName, isFalse);
      expect(retry.reusesStoredVariables, isTrue);
      expect(
        _decision(
          operation: 'pipelineAction',
          level: AiAutonomyLevel.bypass,
          targetKind: AiTargetKind.pipeline,
          arguments: const {'action': 'retry'},
        ).decision,
        AiGateDecision.execute,
      );

      final protectedFile = _decision(
        operation: 'edit_file',
        level: AiAutonomyLevel.conversationGrant,
        targetKind: AiTargetKind.file,
        facts: const AiTierFacts(protectedOrDefaultBranch: true),
      );
      expect(protectedFile.tier, AiWriteTier.t4);
      expect(protectedFile.requiresTypedName, isTrue);

      final variables = _decision(
        operation: 'createPipeline',
        level: AiAutonomyLevel.bypass,
        targetKind: AiTargetKind.pipeline,
        facts: const AiTierFacts(pipelineVariables: true),
      );
      expect(variables.tier, AiWriteTier.hardLine);
      expect(variables.decision, AiGateDecision.requireApproval);
      expect(variables.requiresTypedName, isTrue);

      final fixed = _decision(
        operation: 'markAllTodosDone',
        level: AiAutonomyLevel.bypass,
        targetKind: AiTargetKind.todo,
        scope: const AiWriteScope(
          accountKey: mr6b2Account,
          grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
        ),
      );
      expect(fixed.decision, AiGateDecision.requireApproval);
      expect(fixed.reasons, contains(AiFixedConfirmReason.markAllTodosDone));
    });

    test('real retry tool distinguishes gate from dispatch', () async {
      final h = await Mr6b2Harness.create(level: AiAutonomyLevel.confirmEach);
      addTearDown(h.dispose);
      h.beginRun('Retry Pipeline 12 in team/example-9.');
      final waiting = (await h.propose(
        'pipelineAction',
        mr6b2Args('pipelineAction'),
      ))!;
      expect(waiting.tier.decision, AiGateDecision.requireApproval);
      expect(waiting.tier.requiresTypedName, isFalse);
      expect(h.server.mutationCount(), 0);
      expect((await h.approve(waiting)).successful, isTrue);
      expect(h.server.mutationCount(pathContains: '/pipelines/12/retry'), 1);

      final bypass = await Mr6b2Harness.create(level: AiAutonomyLevel.bypass);
      addTearDown(bypass.dispose);
      bypass.beginRun(
        'Retry '
        'https://example.com/gitlab/team/example-9/-/pipelines/12.',
      );
      final call = bypass.call('pipelineAction', mr6b2Args('pipelineAction'));
      final automatic = (await bypass.coordinator.propose(call))!;
      expect(automatic.tier.decision, AiGateDecision.execute);
      final outcome = await bypass.coordinator.execute(call);
      expect(outcome.successful, isTrue);
      expect(
        bypass.server.mutationCount(pathContains: '/pipelines/12/retry'),
        1,
      );
    });

    test(
      'server-derived protected branch raises a real file tool to T4',
      () async {
        final h = await Mr6b2Harness.create(
          level: AiAutonomyLevel.conversationGrant,
        );
        addTearDown(h.dispose);
        h.server.branchProtected = true;
        h.beginRun('Edit `src/a.txt` on `work` in team/example-9.');
        final proposal = (await h.propose(
          'edit_file',
          mr6b2Args('edit_file'),
        ))!;
        expect(proposal.tier.tier, AiWriteTier.t4);
        expect(proposal.tier.decision, AiGateDecision.requireApproval);
        expect(proposal.tier.typedName, 'work');
        expect(h.server.mutationCount(), 0);
      },
    );
  });
}

AiTierDecision _decision({
  required String operation,
  required AiAutonomyLevel level,
  required AiTargetKind targetKind,
  AiTierFacts facts = const AiTierFacts(),
  Map<String, Object?> arguments = const {},
  AiWriteScope scope = mr6b2Scope,
}) {
  return decideListed(
    ledger: const VisibleProductionLedger(),
    operationId: operation,
    build: (capability) => AiTierInput(
      level: level,
      capability: capability,
      scope: scope,
      binding: const AiBindingResult(
        userMessage: 'synthetic user request',
        allBound: true,
        intentAuthorizesLowRisk: true,
      ),
      target: AiTargetRef(
        kind: targetKind,
        origin: AiTargetOrigin.currentResource,
        projectId: 9,
        iid: 3,
        pipelineId: 12,
      ),
      facts: facts,
      typedName: operation == 'createProject' ? 'tester/new-project' : 'target',
      arguments: arguments,
    ),
  );
}

AiGateDecision _expected(AiAutonomyLevel level, AiWriteTier tier) {
  return switch (level) {
    AiAutonomyLevel.readOnly => AiGateDecision.deny,
    AiAutonomyLevel.confirmEach => AiGateDecision.requireApproval,
    AiAutonomyLevel.lowRiskAuto =>
      tier == AiWriteTier.t1
          ? AiGateDecision.execute
          : AiGateDecision.requireApproval,
    AiAutonomyLevel.conversationGrant =>
      tier.index < AiWriteTier.t4.index
          ? AiGateDecision.execute
          : AiGateDecision.requireApproval,
    AiAutonomyLevel.bypass =>
      tier == AiWriteTier.hardLine
          ? AiGateDecision.requireApproval
          : AiGateDecision.execute,
  };
}
