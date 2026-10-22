// C8: write tool rows carry their target, are marked as writes, and link to
// a GitLab page built from the verified instance and ids (§7.7).

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart';

final _project = Project.fromJson({
  'id': 42,
  'name': 'Mobile Workspace',
  'path_with_namespace': 'studio/mobile-workspace',
  'visibility': 'private',
  'default_branch': 'main',
  'archived': false,
  'last_activity_at': '2026-09-19T08:30:00Z',
});

Future<StackHarness> _issueChat({
  AiAutonomyLevel level = AiAutonomyLevel.lowRiskAuto,
}) => StackHarness.create(
  level: level,
  origin: AiWorkItemOrigin(
    project: _project,
    kind: AiWorkItemKind.issue,
    iid: 5,
    title: 'Synthetic five',
  ),
);

AiToolRunItem _row(StackHarness h, String name) => h.controller.items
    .whereType<AiToolRunItem>()
    .singleWhere((item) => item.name == name);

void main() {
  test('C8 a waiting write row is a write, names its target, and links to '
      'the note once it settles', () async {
    final h = await _issueChat();
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn('createNote', {
        'projectId': 42,
        'resource': 'issues',
        'iid': 5,
        'body': 'Synthetic note',
        'reason': 'The user asked for a note.',
      }),
    );

    final sending = h.controller.send('Comment on this issue');
    await waitFor(() => h.controller.proposals.isNotEmpty);
    final waiting = _row(h, 'createNote');
    expect(AiChatController.isWriteTool(waiting.name), isTrue);
    expect(waiting.argsPreview, '#5');
    final pendingRow = h.controller.writeRowFor(waiting)!;
    expect(pendingRow.operationId, 'createNote');
    expect(pendingRow.target, '#5');
    expect(pendingRow.outcome, isNull);

    final outcome = await h.controller.approveWrite(
      h.controller.proposals.single,
    );
    await sending;
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);

    final settled = _row(h, 'createNote');
    expect(settled.argsPreview, '#5');
    final row = h.controller.writeRowFor(settled)!;
    expect(row.target, '#5');
    expect(row.outcome?.state, AiJournalState.succeeded);
    expect(row.settledAt, isNotNull);
    final noteId = h.server.workspace.notes.keys.last;
    expect(
      row.link,
      Uri.parse(
        'https://example.com/gitlab/studio/mobile-workspace/-/issues/5'
        '#note_$noteId',
      ),
    );
    expect(outcome.webLink, row.link);
    expect(outcome.targetName, '#5');
  });

  test('C8 a read row is not a write row', () async {
    final h = await _issueChat();
    addTearDown(h.dispose);
    h.provider.script.add((_) => toolTurn('get_issue', {'iid': 5}));
    await h.controller.send('Read this issue');
    final read = _row(h, 'get_issue');
    expect(AiChatController.isWriteTool(read.name), isFalse);
    expect(h.controller.writeRowFor(read), isNull);
  });

  test('C8 a refused write row still says it is a write', () async {
    final h = await _issueChat(level: AiAutonomyLevel.bypass);
    addTearDown(h.dispose);
    // Issue 6 is outside the conversation's scope.
    h.provider.script.add(
      (_) => toolTurn('createNote', {
        'projectId': 42,
        'resource': 'issues',
        'iid': 6,
        'body': 'Synthetic note',
        'reason': 'Asked.',
      }),
    );
    await h.controller.send('Comment on #6');
    final refused = _row(h, 'createNote');
    final row = h.controller.writeRowFor(refused)!;
    expect(row.operationId, 'createNote');
    expect(row.outcome?.state, AiJournalState.notExecuted);
    expect(row.link, isNull, reason: 'the target was never read');
    expect(h.server.mutations, isEmpty);
  });

  test('C8 project writes link to the project and to a new issue', () async {
    final h = await StackHarness.create(level: AiAutonomyLevel.bypass);
    addTearDown(h.dispose);
    h.provider.script
      ..add(
        (_) => toolTurn('setStar', {
          'projectId': 42,
          'starred': true,
          'reason': 'Asked.',
        }),
      )
      ..add((_) => answerTurn)
      ..add(
        (_) => toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic bug'},
          'reason': 'Asked.',
        }),
      );

    await h.sendAndApprove('Star this project');
    final star = h.controller.writeRowFor(_row(h, 'setStar'))!;
    expect(star.target, 'studio/mobile-workspace');
    expect(
      star.link,
      Uri.parse('https://example.com/gitlab/studio/mobile-workspace'),
    );

    await h.sendAndApprove('Create an issue for the bug');
    final created = h.controller.writeRowFor(_row(h, 'createIssue'))!;
    expect(created.outcome?.state, AiJournalState.succeeded);
    final iid = h.server.workspace.issues.keys.reduce((a, b) => a > b ? a : b);
    expect(
      created.link,
      Uri.parse(
        'https://example.com/gitlab/studio/mobile-workspace/-/issues/$iid',
      ),
    );
  });
}
