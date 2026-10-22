// MR6b-1 review round 1: the lead's wiring between the text checks, the
// coordinator, the runner and the conversation's placeholder table.

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show AiFieldProvenance, UploadPlaceholderTable;
import 'package:gitlab_mobile/core/instance.dart';

import 'fx_coord_support.dart';

AiToolCall _newMergeRequest(String id, String description) => AiToolCall(
  id: id,
  name: 'createMergeRequest',
  arguments: {
    'projectId': 9,
    'fields': {
      'title': 'Synthetic change',
      'source_branch': 'feature',
      'target_branch': 'main',
      'description': description,
    },
    'reason': 'The user asked for a merge request.',
  },
);

void main() {
  group('closing keywords reach the card', () {
    late CoordHarness h;

    setUp(() async => h = await CoordHarness.create());
    tearDown(() async => h.dispose());

    test('in-scope issues a new merge request closes are listed', () async {
      h.newRun('Open a merge request for the fix');
      final proposal = (await h.coordinator.propose(
        _newMergeRequest('mr-1', 'Closes #3 and fixes #8.'),
      ))!;
      expect(proposal.closingRefs, ['team/example-9#3', 'team/example-9#8']);
      expect(
        proposal.tier.reasons,
        isNot(contains(AiFixedConfirmReason.foreignClosingOrCrossProject)),
      );
    });

    test('an out-of-scope closing reference needs confirmation', () async {
      h.newRun('Open a merge request for the fix');
      final proposal = (await h.coordinator.propose(
        _newMergeRequest('mr-2', 'Resolves other/project#4'),
      ))!;
      expect(proposal.closingRefs, isEmpty);
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.foreignClosingOrCrossProject),
      );
    });
  });

  group('a result the runner cut later', () {
    final field = AiFieldProvenance.gitLab(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      projectId: 9,
      projectPath: 'team/example-9',
      resource: 'issues',
      iid: 3,
    );

    test('marks every field seen whole as cut until read whole again', () {
      final table = UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      );
      table.recordFieldDelivery(field, whole: true);
      expect(table.seenOnlyCut(field), isFalse);
      table.markWholeFieldsCut();
      expect(table.seenOnlyCut(field), isTrue);
      table.recordFieldDelivery(field, whole: true);
      expect(table.seenOnlyCut(field), isFalse);
    });

    test('the tail clip says whether it cut a restorable result', () {
      AiSegment segmentWith({required bool restorable}) {
        final segment = AiSegment(
          providerId: 'provider',
          recipientRevision: 1,
          format: AiFormat.chatCompletions,
          model: 'model',
          secretSetAtStart: SecretSetId.fromSecrets(const []),
        );
        segment.setTail(
          AppToolResultsEntry([
            AiToolResult(
              callId: 'call-1',
              name: 'get_issue',
              content: 'x' * 400,
              uploadPlaceholders: restorable,
            ),
          ]),
        );
        return segment;
      }

      expect(segmentWith(restorable: true).clipTailToolResults(100), isTrue);
      expect(segmentWith(restorable: false).clipTailToolResults(100), isFalse);
      expect(segmentWith(restorable: true).clipTailToolResults(1000), isFalse);
    });
  });
}
