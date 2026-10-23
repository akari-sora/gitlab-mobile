import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b2_support.dart';

void main() {
  for (final scenario
      in <
        ({
          String operation,
          Map<String, Object?> arguments,
          String prompt,
          String mutationPath,
        })
      >[
        (
          operation: 'mergeRequest',
          arguments: mr6b2Args('mergeRequest'),
          prompt: 'Merge team/example-9!3 from `work` to `main`.',
          mutationPath: '/merge_requests/3/merge',
        ),
        (
          operation: 'deleteBranch',
          arguments: {'projectId': 9, 'branch': 'work'},
          prompt: 'Delete branch `work` in team/example-9.',
          mutationPath: '/repository/branches/work',
        ),
        (
          operation: 'pipelineAction',
          arguments: mr6b2Args('pipelineAction'),
          prompt: 'Retry Pipeline 12 in team/example-9.',
          mutationPath: '/pipelines/12/retry',
        ),
        (
          operation: 'edit_file',
          arguments: mr6b2Args('edit_file'),
          prompt: 'Replace alpha with beta in `src/a.txt` on `work`.',
          mutationPath: '/repository/files/',
        ),
      ]) {
    test(
      '${scenario.operation} has one approval, execution id, and mutation',
      () async {
        final h = await Mr6b2Harness.create();
        addTearDown(h.dispose);
        h.beginRun(scenario.prompt);

        final proposal = await h.propose(
          scenario.operation,
          scenario.arguments,
          id: 'guard-${scenario.operation}',
        );
        expect(proposal, isNotNull);
        expect(proposal!.tier.decision, AiGateDecision.requireApproval);
        expect(proposal.executionId, isNotEmpty);
        expect(h.server.mutationCount(), 0);

        h.server.armMutationBarrier();
        final approval = h.approve(proposal);
        await h.server.mutationEntered!.future.timeout(mr6b2Timeout);
        final dispatching = h.journal
            .entries(mr6b2Account)
            .where((entry) => entry.executionId == proposal.executionId)
            .toList();
        expect(dispatching, hasLength(1));
        expect(dispatching.single.operationId, proposal.operationId);
        expect(dispatching.single.state, AiJournalState.dispatching);
        h.server.releaseMutationBarrier();
        final outcome = await approval;
        expect(outcome.executionId, proposal.executionId);
        expect(outcome.operationId, proposal.operationId);
        expect(outcome.mutationCount, 1);
        expect(h.server.mutationCount(pathContains: scenario.mutationPath), 1);
        final matchingEntries = h.journal
            .entries(mr6b2Account)
            .where((entry) => entry.executionId == proposal.executionId)
            .toList();
        expect(matchingEntries, hasLength(1));
        expect(matchingEntries.single.operationId, proposal.operationId);

        await h.approve(proposal);
        expect(
          h.server.mutationCount(pathContains: scenario.mutationPath),
          1,
          reason: 'the same approved execution must never dispatch twice',
        );
      },
    );
  }

  test('automatic bypass still carries one proposal execution id', () async {
    final h = await Mr6b2Harness.create(level: AiAutonomyLevel.bypass);
    addTearDown(h.dispose);
    h.beginRun('Star team/example-9.');
    final call = h.call('setStar', {
      'projectId': 9,
      'starred': true,
    }, id: 'auto-star');
    h.server.armMutationBarrier();
    final execution = h.coordinator.execute(call);
    await h.server.mutationEntered!.future.timeout(mr6b2Timeout);
    final executionId = h.coordinator.executionIdFor(call.id);
    expect(executionId, isNotNull);
    final dispatching = h.journal
        .entries(mr6b2Account)
        .where((entry) => entry.executionId == executionId)
        .toList();
    expect(dispatching, hasLength(1));
    expect(dispatching.single.operationId, 'setStar');
    expect(dispatching.single.state, AiJournalState.dispatching);
    h.server.releaseMutationBarrier();
    final outcome = await execution;
    expect(outcome.executionId, isNotNull);
    expect(outcome.mutationCount, 1);
    expect(h.server.mutationCount(), 1);
    final entry = h.journal
        .entries(mr6b2Account)
        .singleWhere((value) => value.executionId == outcome.executionId);
    expect(entry.operationId, 'setStar');
  });
}
