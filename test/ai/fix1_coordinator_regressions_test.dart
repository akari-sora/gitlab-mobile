import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';
import 'fx_coord_support.dart';
import 'mr6b2_support.dart';

AiBindingResult _bind(String message, AiTargetRef target) => bindTargets(
  userMessage: message, restoredFromHistory: false, scope: mr6b2Scope,
  targets: [target], interfaceLanguage: 'en', deviceLanguages: const ['en'],
);

void main() {
  test('Emulator 1 verbatim bare and quoted branch tag and paths bind whole tokens', () {
    for (final kind in [AiTargetKind.branch, AiTargetKind.tag, AiTargetKind.path]) {
      final name = kind == AiTargetKind.path ? 'src/a.txt' : 'ci/mobile-workbench';
      final target = AiTargetRef(kind: kind, projectId: 9, name: name,
          path: name, refName: name);
      for (final text in ['delete $name', 'delete "$name"', 'delete `$name`']) {
        expect(_bind(text, target).allBound, isTrue, reason: '$kind $text');
      }
      for (final text in ['delete prefix/$name', 'delete ${name}more',
          '> delete $name', '```\ndelete $name\n```',
          'delete https://foreign.example/$name']) {
        expect(_bind(text, target).allBound, isFalse, reason: '$kind $text');
      }
    }
    final main = AiTargetRef(kind: AiTargetKind.branch, projectId: 9, refName: 'main');
    expect(_bind('delete mainly', main).allBound, isFalse);
    expect(_bind('delete main.', main).allBound, isTrue);
    final label = AiTargetRef(kind: AiTargetKind.label, projectId: 9, name: 'bug');
    expect(_bind('delete bug', label).allBound, isFalse);
    expect(_bind('delete `bug`', label).allBound, isTrue);
  });

  test('C1 parent resource never binds one chosen note without explicit note reference', () {
    final target = AiTargetRef(kind: AiTargetKind.note, projectId: 9,
        parentIid: 3, noteId: 31, side: AiResourceSide.mergeRequest);
    expect(_bind('delete !3', target).allBound, isFalse);
    for (final text in ['delete note:31', 'delete note #31',
        'delete #note_31', 'delete `note:31`',
        'delete https://example.com/gitlab/team/example-9/-/merge_requests/3#note_31']) {
      expect(_bind(text, target).allBound, isTrue, reason: text);
    }
    expect(_bind('delete note:310', target).allBound, isFalse);
    expect(_bind('delete https://foreign.example/team/example-9/-/merge_requests/3#note_31', target).allBound, isFalse);
  });

  test('new preview metadata is redacted before publication and counts survive', () {
    String safe(String value) => value.replaceAll('secret', '[REDACTED]');
    final note = redactAiWritePreview(const port.AiDeletePreview(
      targetName: '', parentName: '#secret', author: '@secret', excerpt: 'secret body',
    ), safe) as port.AiDeletePreview;
    expect(note.targetName, '');
    expect(note.parentName, '#[REDACTED]');
    expect(note.author, '@[REDACTED]');
    expect(note.excerpt, '[REDACTED] body');
    final merge = redactAiWritePreview(port.AiMergePreview(sourceBranch: 'a',
      targetBranch: 'b', shortSha: 'a', pathCount: 0, closingIssues: const [
        port.AiClosingIssue(projectId: 9, iid: 7, outOfScope: false,
            fullReference: 'secret/project#7'),
        port.AiClosingIssue(projectId: 10, iid: 7, outOfScope: true,
            fullReference: 'other/project#7'),
      ]), safe) as port.AiMergePreview;
    expect(merge.closingIssues.first.fullReference, '[REDACTED]/project#7');
    expect(merge.closingIssues.last.fullReference, 'other/project#7');
    final diff = redactAiWritePreview(port.AiDiffPreview(path: 'secret', ref: 'a',
      lines: const [], moreFiles: 2, ciPath: true), safe) as port.AiDiffPreview;
    expect(diff.moreFiles, 2);
    expect(diff.ciPath, isTrue);
  });

  for (final action in ['retry', 'play', 'cancel']) {
    test('I4 automatic job $action audit notice matches stored variable reuse', () async {
      final h = await Mr6b2Harness.create();
      addTearDown(h.dispose);
      h.policy.level = AiAutonomyLevel.bypass;
      h.policy.currentJobId = 21;
      h.server.overrides['POST projects/9/jobs/21/$action'] = (_) => jsonResponse({'id': 21});
      h.beginRun('Run this job');
      final outcome = await h.coordinator.execute(h.call('jobAction', {
        'projectId': 9, 'jobId': 21, 'action': action,
      })).timeout(mr6b2Timeout);
      expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
      expect(outcome.auditNotice, action == 'cancel' ? null : 'storedVariablesMayApply');
    });
  }

  test('I4 automatic pipeline retry emits stored variables notice', () async {
    final h = await Mr6b2Harness.create();
    addTearDown(h.dispose);
    h.policy.level = AiAutonomyLevel.bypass;
    h.beginRun('Retry https://example.com/gitlab/team/example-9/-/pipelines/12');
    final outcome = await h.coordinator.execute(h.call('pipelineAction', {
      'projectId': 9, 'pipelineId': 12, 'action': 'retry',
    })).timeout(mr6b2Timeout);
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(outcome.auditNotice, 'storedVariablesMayApply');
  });

  test('Emulator 1 production file origin binds this file without spelling its path or ref', () async {
    final h = await StackHarness.create(level: AiAutonomyLevel.confirmEach,
      configure: (server) {
        server.overrides['GET projects/42'] = (_) => jsonResponse({
          ...server.workspace.projectRecord, 'ci_config_path': null,
        });
        server.overrides['GET projects/42/repository/branches/work'] = (_) => jsonResponse({
          'name': 'work', 'default': false, 'protected': false,
          'commit': {'id': WorkspaceFixture.sha},
        });
      });
    addTearDown(h.dispose);
    h.provider.script.add((_) => toolTurn('edit_file', {
      'projectId': 42, 'path': 'README.md', 'branch': 'work',
      'commitMessage': 'synthetic', 'edits': [{'old': 'Workspace', 'new': 'Updated'}],
      'reason': 'Requested',
    }));
    final sending = h.controller.send('Edit this file');
    await waitFor(() => h.controller.proposals.isNotEmpty || h.controller.phase == AiChatPhase.idle);
    expect(h.controller.proposals, isNotEmpty,
        reason: h.controller.items.map((i) => i.toString()).join(' '));
    expect(h.controller.proposals.single.tier.reasons,
        isNot(contains(AiFixedConfirmReason.targetUnbound)));
    await h.controller.rejectWrite(h.controller.proposals.single);
    await sending.timeout(const Duration(seconds: 20));
    expect(h.server.mutations, isEmpty);
  });

  test('Emulator 2 rejection explicitly reaches the provider as a user decision', () async {
    final h = await StackHarness.create(level: AiAutonomyLevel.confirmEach);
    addTearDown(h.dispose);
    h.provider.script.add((_) => toolTurn('setStar', {
      'projectId': 42, 'starred': true, 'reason': 'Requested',
    }));
    final sending = h.controller.send('Star this project');
    await waitFor(() => h.controller.proposals.isNotEmpty);
    await h.controller.rejectWrite(h.controller.proposals.single);
    await sending.timeout(const Duration(seconds: 20));
    final item = h.controller.items.whereType<AiToolRunItem>().singleWhere((i) => i.name == 'setStar');
    final outcome = h.controller.writeRowFor(item)!.outcome!;
    expect(outcome.reasonCode, 'userRejected');
    expect(outcome.summary, contains('the user rejected the proposal'));
    expect(h.provider.bodies.last, contains('the user rejected the proposal'));
    expect(h.server.mutations, isEmpty);
  });
}
