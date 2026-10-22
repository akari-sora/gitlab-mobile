// C7: an upload proposal carries the file's size and the target project's
// full path and visibility from the fresh project read; an upload into a
// public or internal project that ran without a card carries the audit
// row's warning.

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart';

AiToolCall _upload(String id) => AiToolCall(
  id: id,
  name: 'upload_attachment',
  arguments: const {
    'projectId': 9,
    'attachmentId': 'att-1',
    'reason': 'The user asked to upload the screenshot.',
  },
);

void main() {
  late CoordHarness h;

  setUp(() async {
    h = await CoordHarness.create();
  });

  tearDown(() async {
    await h.dispose();
  });

  for (final visibility in ['public', 'internal', 'private']) {
    test('C7 the card shows size, type, project path and $visibility '
        'visibility', () async {
      h.projectVisibility = visibility;
      final file = await h.attach('shot.png', List<int>.filled(1234, 7));
      h.coordinator.beginRun('Upload my screenshot to team/example-9');
      h.coordinator.beginTurn();
      final proposal = (await h.coordinator.propose(_upload('u-$visibility')))!;

      final upload = proposal.upload!;
      expect(upload.attachmentId, 'att-1');
      expect(upload.filename, 'shot.png');
      expect(upload.sizeBytes, 1234);
      expect(upload.contentType, 'image/png');
      expect(upload.sha256Prefix, file.sha256Prefix);
      expect(upload.projectId, 9);
      expect(upload.projectPath, 'team/example-9');
      expect(upload.projectVisibility, visibility);
      expect(upload.readersCanFetch, visibility != 'private');
      expect(
        upload.noticeAt(AiAutonomyLevel.confirmEach).surface,
        visibility == 'private'
            ? AiUploadNoticeSurface.none
            : AiUploadNoticeSurface.card,
      );
      expect(
        upload.noticeAt(AiAutonomyLevel.bypass).surface,
        visibility == 'private'
            ? AiUploadNoticeSurface.none
            : AiUploadNoticeSurface.audit,
      );

      // A card approval shows the warning on the card, not the audit row.
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.upload?.projectVisibility, visibility);
      expect(outcome.auditNotice, isNull);
    });
  }

  test(
    'C7 an automatic upload into a public project warns on the audit row',
    () async {
      h.projectVisibility = 'public';
      h.level = AiAutonomyLevel.bypass;
      await h.attach('shot.png', List<int>.filled(64, 1));
      h.coordinator.beginRun('Upload my screenshot to team/example-9');
      h.coordinator.beginTurn();

      final outcome = await h.coordinator.execute(_upload('auto'));

      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(outcome.upload?.projectVisibility, 'public');
      expect(outcome.upload?.sizeBytes, 64);
      expect(outcome.upload?.projectPath, 'team/example-9');
      expect(outcome.auditNotice, uploadReadersCanFetch);
      expect(h.mutations, 1);
    },
  );

  test(
    'C7 an automatic upload into a private project has no warning',
    () async {
      h.level = AiAutonomyLevel.bypass;
      await h.attach('shot.png', List<int>.filled(64, 1));
      h.coordinator.beginRun('Upload my screenshot to team/example-9');
      h.coordinator.beginTurn();

      final outcome = await h.coordinator.execute(_upload('private'));

      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(outcome.upload?.projectVisibility, 'private');
      expect(outcome.auditNotice, isNull);
    },
  );

  test('C7 a write other than an upload carries no upload data', () async {
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final proposal = (await h.coordinator.propose(starCall('star')))!;
    expect(proposal.upload, isNull);
    final outcome = await h.coordinator.approve(proposal);
    expect(outcome.upload, isNull);
    expect(outcome.auditNotice, isNull);
  });
}
