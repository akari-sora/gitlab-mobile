import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';

const _noteId = 3571942820;

Project _project(String visibility) => Project.fromJson({
  'id': 42,
  'name': 'Mobile Workspace',
  'path_with_namespace': 'studio/mobile-workspace',
  'visibility': visibility,
  'default_branch': 'main',
  'archived': false,
  'last_activity_at': '2026-09-19T08:30:00Z',
});

const _realIssueNote = <String, Object?>{
  'id': _noteId,
  'type': null,
  'body':
      '第一行：真實公開議題留言\n'
      '\n'
      '## 重現步驟：這是一段超過一百六十個字元的中文 Markdown 內容，'
      '用來確認刪除預覽會先在中央顯示遮蔽邊界完整處理多行文字，'
      '不會因為換行、中英文混合、標點或長度而把正常的公開留言誤判成機密資料。'
      '同時保留原始語意與 Markdown 結構，讓使用者在確認卡上可以辨識正在刪除的留言，'
      '並確認超過二百個 Unicode 碼點時會安全截斷，而不會切壞一個字元或在多行邊界拋出例外。\n'
      '- 點擊刪除\n'
      '- 確認後應只寫入一次',
  'author': <String, Object?>{
    'id': 190001,
    'username': 'public-reviewer',
    'public_email': '',
    'name': '公開審查者',
    'state': 'active',
    'locked': false,
    'avatar_url': 'https://example.com/uploads/avatar.png',
    'web_url': 'https://example.com/public-reviewer',
  },
  'created_at': '2026-10-23T01:02:03.000Z',
  'updated_at': '2026-10-23T01:02:04.000Z',
  'system': false,
  'noteable_id': 42005,
  'noteable_type': 'Issue',
  'project_id': 42,
  'resolvable': false,
  'confidential': false,
  'internal': false,
  'imported': false,
  'imported_from': 'none',
  'noteable_iid': 5,
  'commands_changes': <String, Object?>{},
};

void main() {
  for (final visibility in ['private', 'public']) {
    test('FIX2 deleteNote accepts a real $visibility issue-note shape through '
        'the production controller', () async {
      final h = await StackHarness.create(
        level: AiAutonomyLevel.confirmEach,
        origin: AiWorkItemOrigin(
          project: _project(visibility),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Synthetic five',
        ),
        configure: (server) => server.visibility = visibility,
      );
      addTearDown(h.dispose);
      h.server.overrides['GET projects/42/issues/5/notes/$_noteId'] = (_) =>
          jsonResponse(_realIssueNote);
      h.server.overrides['DELETE projects/42/issues/5/notes/$_noteId'] = (_) =>
          jsonResponse(<String, Object?>{}, status: 204);
      h.provider.script.add(
        (_) => toolTurn('deleteNote', {
          'projectId': 42,
          'resource': 'issues',
          'iid': 5,
          'noteId': _noteId,
          'reason': 'The user explicitly requested deletion.',
        }),
      );
      h.server.adapter.requests.clear();

      final sending = h.controller.send('Delete #note_$_noteId');
      await waitFor(
        () =>
            h.controller.proposals.isNotEmpty ||
            h.controller.phase == AiChatPhase.idle,
      );
      expect(
        h.controller.proposals,
        isNotEmpty,
        reason: h.controller.items
            .whereType<AiToolRunItem>()
            .map((item) => '${item.name}: ${item.resultExcerpt}')
            .join(', '),
      );
      final proposal = h.controller.proposals.single;
      expect(proposal.tier.decision, AiGateDecision.requireApproval);
      expect(
        proposal.tier.reasons.map((reason) => reason.name),
        isNot(contains('targetUnbound')),
      );
      final preview = proposal.preview as AiDeletePreview;
      expect(preview.parentName, '#5');
      expect(preview.author, '@public-reviewer');
      expect(
        preview.excerpt,
        String.fromCharCodes(
          (_realIssueNote['body']! as String)
              .split('\n')
              .take(3)
              .join('\n')
              .runes
              .take(200),
        ),
      );
      expect(preview.excerpt!.runes, hasLength(200));

      final outcome = await h.controller
          .approveWrite(proposal, typedName: proposal.tier.typedName)
          .timeout(const Duration(seconds: 20));
      await sending.timeout(const Duration(seconds: 20));
      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(
        h.server.adapter.requests.map((request) => request.uri.path),
        containsAll(<String>[
          '/gitlab/api/v4/projects/42',
          '/gitlab/api/v4/projects/42/issues/5',
          '/gitlab/api/v4/projects/42/issues/5/notes/$_noteId',
        ]),
      );
      expect(
        h.server.mutations.where(
          (request) =>
              request.uri.path.endsWith('/projects/42/issues/5/notes/$_noteId'),
        ),
        hasLength(1),
      );
    });
  }
}
