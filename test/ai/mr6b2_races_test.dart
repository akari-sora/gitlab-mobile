import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b2_support.dart';

void main() {
  group('§15 rows 6 and 7 approval races', () {
    test('double-clicking one card dispatches at most once', () async {
      final h = await Mr6b2Harness.create();
      addTearDown(h.dispose);
      h.beginRun('Retry Pipeline 12 in team/example-9.');
      final proposal = (await h.propose(
        'pipelineAction',
        mr6b2Args('pipelineAction'),
      ))!;
      h.server.armMutationBarrier();

      final first = h.approve(proposal);
      await h.server.mutationEntered!.future.timeout(mr6b2Timeout);
      final second = h.approve(proposal);
      expect(h.server.mutationCount(pathContains: '/pipelines/12/retry'), 1);
      h.server.releaseMutationBarrier();

      final outcomes = await Future.wait([first, second]);
      expect(outcomes[0].executionId, proposal.executionId);
      expect(outcomes[1].executionId, proposal.executionId);
      expect(h.server.mutationCount(pathContains: '/pipelines/12/retry'), 1);
    });

    test(
      'two conversations approving one merge dispatch at most once',
      () async {
        final h = await Mr6b2Harness.create();
        addTearDown(h.dispose);
        h.server.targetBranch = 'release';
        h.policy.level = AiAutonomyLevel.confirmEach;
        h.beginRun('Merge team/example-9!3 from `work` to `release`.');
        final firstProposal = (await h.propose(
          'mergeRequest',
          mr6b2Args('mergeRequest'),
        ))!;

        final secondPolicy = Mr6b2Policy()..level = AiAutonomyLevel.confirmEach;
        final secondBudget = AiToolBudget(maxGitLabRequests: 40);
        final second = h.newCoordinator(
          conversationId: 'second-conversation',
          policy: secondPolicy,
          budget: () => secondBudget,
        );
        second.beginRun('Merge team/example-9!3 from `work` to `release`.');
        second.beginTurn();
        final secondProposal = (await second
            .propose(
              h.call(
                'mergeRequest',
                mr6b2Args('mergeRequest'),
                id: 'second-merge',
              ),
            )
            .timeout(mr6b2Timeout))!;

        h.server.armMutationBarrier();
        final firstApproval = h.approve(firstProposal);
        await h.server.mutationEntered!.future.timeout(mr6b2Timeout);
        final secondApproval = second
            .approve(secondProposal, typedName: secondProposal.tier.typedName)
            .timeout(mr6b2Timeout);
        expect(h.server.mutationCount(pathContains: '/merge'), 1);
        h.server.releaseMutationBarrier();

        final outcomes = await Future.wait([firstApproval, secondApproval]);
        expect(outcomes.where((outcome) => outcome.successful), hasLength(1));
        final refused = outcomes.singleWhere((outcome) => !outcome.successful);
        expect(refused.state, AiJournalState.notExecuted);
        expect(refused.reasonCode, 'isolated');
        expect(h.server.mutationCount(pathContains: '/merge'), 1);
        second.stop('disposed');
      },
    );

    test('29 minutes remains valid and 31 minutes expires', () async {
      final at29 = await Mr6b2Harness.create();
      addTearDown(at29.dispose);
      at29.beginRun('Retry Pipeline 12 in team/example-9.');
      final valid = (await at29.propose(
        'pipelineAction',
        mr6b2Args('pipelineAction'),
      ))!;
      at29.clock = at29.clock.add(const Duration(minutes: 29));
      expect((await at29.approve(valid)).successful, isTrue);
      expect(at29.server.mutationCount(), 1);

      final at31 = await Mr6b2Harness.create();
      addTearDown(at31.dispose);
      at31.beginRun('Retry Pipeline 12 in team/example-9.');
      final expired = (await at31.propose(
        'pipelineAction',
        mr6b2Args('pipelineAction'),
      ))!;
      at31.clock = at31.clock.add(const Duration(minutes: 31));
      at31.coordinator.checkNow();
      final outcome = await at31.approve(expired);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'approvalExpired');
      expect(at31.server.mutationCount(), 0);
    });

    test('lowering autonomy while pending rechecks before dispatch', () async {
      final h = await Mr6b2Harness.create();
      addTearDown(h.dispose);
      h.beginRun('Retry Pipeline 12 in team/example-9.');
      final proposal = (await h.propose(
        'pipelineAction',
        mr6b2Args('pipelineAction'),
      ))!;
      h.policy.level = AiAutonomyLevel.readOnly;
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'policyDenied');
      expect(h.server.mutationCount(), 0);
    });
  });
}
