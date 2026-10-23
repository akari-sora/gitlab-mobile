import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b2_support.dart';

void main() {
  late Mr6b2Harness harness;

  setUp(() async {
    harness = await Mr6b2Harness.create();
  });

  tearDown(() => harness.dispose());

  Future<AiWriteOutcome> makeUncertain(
    String operation,
    Map<String, Object?> arguments,
  ) async {
    harness.beginRun();
    harness.server.mutationStatus = 500;
    final proposal = await harness.propose(operation, arguments);
    expect(proposal, isNotNull, reason: operation);
    final outcome = await harness.approve(proposal!);
    expect(outcome.state, AiJournalState.writeUncertain, reason: operation);
    expect(outcome.mutationCount, 1, reason: operation);
    harness.server.mutationStatus = null;
    return outcome;
  }

  Future<void> expectSharedJournalBlocks(String first, String second) async {
    await makeUncertain(first, mr6b2Args(first));
    final peerBudget = AiToolBudget(maxGitLabRequests: 40);
    final peer = harness.newCoordinator(
      conversationId: 'peer-$first-$second',
      budget: () => peerBudget,
    );
    peer.beginRun(
      'Merge !3 from `work` to `main`, edit `src/a.txt`, apply suggestion '
      '42, retry Pipeline 12 and Job 21, and delete !3 in team/example-9.',
    );
    peer.beginTurn();
    final before = harness.server.mutationCount();
    final call = harness.call(second, mr6b2Args(second));
    final proposal = await peer.propose(call).timeout(mr6b2Timeout);
    expect(proposal, isNull, reason: '$first must isolate $second');
    expect(peer.outcomeFor(call.id)?.reasonCode, 'isolated');
    expect(harness.server.mutationCount(), before);
    peer.stop('testEnd');
  }

  test('§15 row 5 REST delete and merge isolate in both directions', () async {
    await expectSharedJournalBlocks('deleteMergeRequest', 'mergeRequest');
    await harness.dispose();
    harness = await Mr6b2Harness.create();
    await expectSharedJournalBlocks('mergeRequest', 'deleteMergeRequest');
  });

  test('§15 row 5 Job and Pipeline isolate in both directions', () async {
    await expectSharedJournalBlocks('jobAction', 'pipelineAction');
    await harness.dispose();
    harness = await Mr6b2Harness.create();
    await expectSharedJournalBlocks('pipelineAction', 'jobAction');
  });

  test('§15 row 5 file and suggestion isolate in both directions', () async {
    await expectSharedJournalBlocks('edit_file', 'applySuggestion');
    await harness.dispose();
    harness = await Mr6b2Harness.create();
    await expectSharedJournalBlocks('applySuggestion', 'edit_file');
  });
}
