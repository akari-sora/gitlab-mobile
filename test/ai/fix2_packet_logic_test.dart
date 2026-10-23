import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_ui.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';
import 'fx_coord_support.dart';
import 'mr6b2_support.dart';

void main() {
  test('N1 source MR binds only the MR under bypass', () async {
    final workspace = WorkspaceFixture();
    final h = await StackHarness.create(
      level: AiAutonomyLevel.bypass,
      origin: AiWorkItemOrigin(
        project: workspace.project,
        kind: AiWorkItemKind.mergeRequest,
        iid: 12,
        title: 'Synthetic MR',
      ),
      configure: (server) {
        server.overrides['GET projects/42'] = (_) => jsonResponse({
          ...server.workspace.projectRecord,
          'ci_config_path': null,
        });
        server.overrides['GET projects/42/merge_requests/12'] = (_) =>
            jsonResponse({
              ...server.workspace.mergeRequest,
              'changes_count': '0',
              'diff_refs': {
                'base_sha': WorkspaceFixture.sha,
                'start_sha': WorkspaceFixture.sha,
                'head_sha': WorkspaceFixture.sha,
              },
            });
        server.overrides['GET projects/42/merge_requests/12/diffs'] = (_) =>
            jsonResponse(<Object?>[]);
        server.overrides['GET projects/42/merge_requests/12/notes'] = (_) =>
            jsonResponse(<Object?>[]);
        server.overrides['GET projects/42/repository/branches/main'] = (_) =>
            jsonResponse({
              'name': 'main',
              'protected': false,
              'commit': {'id': WorkspaceFixture.sha},
            });
      },
    );
    addTearDown(h.dispose);
    h.provider.script.add((_) => toolTurn('mergeRequest', {
      'projectId': 42, 'iid': 12, 'reason': 'Synthetic merge',
    }));
    final sending = h.controller.send('Describe this merge request');
    await waitFor(() => h.controller.proposals.isNotEmpty ||
        h.server.mutations.isNotEmpty || h.controller.phase == AiChatPhase.idle);
    expect(h.server.mutations, isEmpty);
    expect(h.controller.proposals, hasLength(1));
    final proposal = h.controller.proposals.single;
    expect(proposal.tier.decision, AiGateDecision.requireApproval);
    expect(proposal.tier.reasons, contains(AiFixedConfirmReason.targetUnbound));
    await h.controller.rejectWrite(proposal);
    await sending.timeout(mr6b2Timeout);
  });

  test('N1 plain main and README.md require approval with zero mutations', () async {
    final h = await Mr6b2Harness.create(level: AiAutonomyLevel.bypass);
    addTearDown(h.dispose);
    h.beginRun('Edit README.md on main.');
    final proposal = await h.propose('edit_file', {
      ...mr6b2Args('edit_file'), 'branch': 'main', 'path': 'README.md',
    });
    expect(h.server.mutationCount(), 0);
    expect(proposal, isNotNull);
    expect(proposal!.tier.decision, AiGateDecision.requireApproval);
    expect(proposal.tier.reasons.map((r) => r.name),
        contains('targetNamedNotMarked'));
    expect(proposal.tier.reasons, isNot(contains(AiFixedConfirmReason.targetUnbound)));
    final reason = proposal.tier.reasons.single;
    expect(aiConfirmReasonText(reason), l10n.aiConfirmTargetNamedNotMarked);
  });

  test('N1 mentioned warning requires every missing component', () {
    final targets = [
      AiTargetRef(kind: AiTargetKind.file, projectId: 9,
          refName: 'main', path: 'README.md'),
      AiTargetRef(kind: AiTargetKind.tag, projectId: 9, name: 'v1.2'),
    ];
    AiBindingResult bind(String message, {bool restored = false}) => bindTargets(
      userMessage: message, restoredFromHistory: restored, scope: mr6b2Scope,
      targets: targets, interfaceLanguage: 'en', deviceLanguages: const ['en'],
    );
    expect(bind('main README.md v1.2').allBound, isFalse);
    expect(bind('main README.md v1.2').reasons.map((r) => r.name),
        ['targetNamedNotMarked']);
    for (final message in ['main README.md', 'mainly README.md v1.2',
      '> main README.md v1.2', '```\nmain README.md v1.2\n```']) {
      expect(bind(message).reasons, [AiFixedConfirmReason.targetUnbound]);
    }
    expect(bind('main README.md v1.2', restored: true).reasons,
        [AiFixedConfirmReason.targetUnbound]);
    expect(bind('`main` `README.md` `v1.2`').allBound, isTrue);
  });

  test('N1 backtick branch still binds and automatically edits', () async {
    final h = await Mr6b2Harness.create(level: AiAutonomyLevel.bypass);
    addTearDown(h.dispose);
    h.beginRun('Edit `src/a.txt` on `work`.');
    final call = h.call('edit_file', mr6b2Args('edit_file'));
    final outcome = await h.coordinator.execute(call).timeout(mr6b2Timeout);
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(h.server.mutationCount(), 1);
  });

  for (final entry in [
    (AiTargetKind.branch, 'main'),
    (AiTargetKind.path, 'README.md'),
    (AiTargetKind.tag, 'v1.2'),
  ]) {
    test('N1 ${entry.$1.name} plain mention never authorizes', () {
      final result = bindTargets(
        userMessage: entry.$2, restoredFromHistory: false, scope: mr6b2Scope,
        targets: [AiTargetRef(kind: entry.$1, projectId: 9, name: entry.$2,
          refName: entry.$2, path: entry.$2)],
        interfaceLanguage: 'en', deviceLanguages: const ['en'],
      );
      expect(result.allBound, isFalse);
      expect(result.reasons, [AiFixedConfirmReason.targetNamedNotMarked]);
    });
  }

  for (final kind in FailureKind.values) {
    test('prepare ApiFailure ${kind.name} preserves explicit allowed codes', () async {
      final h = await Mr6b2Harness.create(level: AiAutonomyLevel.bypass);
      addTearDown(h.dispose);
      final coordinator = PolicyAiWriteCoordinator(
        snapshot: () => const AiWritePolicySnapshot(
          scope: mr6b2Scope, level: AiAutonomyLevel.bypass,
          ceiling: AiAutonomyLevel.bypass, consentHash: 'synthetic',
          writePolicyRevision: 1, scopeRevision: 1, sessionGeneration: 7,
        ),
        createPort: () => _FailPreparePort(kind), journal: h.journal,
        conversationId: h.conversationId, budget: () => h.budget,
        readFreshness: (_) async => const AiWriteFreshness(),
        placeholders: text.UploadPlaceholderTable(instance: h.scope.resolvedInstance!),
        knownSecrets: () => const {},
        safeDisplay: (value) => value,
      );
      addTearDown(() => coordinator.stop('disposed'));
      coordinator.beginRun('Star this project');
      coordinator.beginTurn();
      final call = h.call('setStar', mr6b2Args('setStar'));
      final outcome = await coordinator.execute(call).timeout(mr6b2Timeout);
      final explicit = const {'forbidden', 'invisible', 'validation',
        'unsupported', 'invalidResponse', 'rateLimited', 'network'};
      final expected = explicit.contains(kind.name) ? kind.name : 'preflightFailed';
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, expected);
      expect(outcome.toToolResult(call).content, contains('; $expected'));
      expect(h.server.mutationCount(), 0);
    });
  }

  test('existing UI refusal mapping and generic fallbacks remain unchanged', () {
    expect(aiRefusalText('forbidden'), l10n.aiRefusedPermission);
    expect(aiRefusalText('invisible'), l10n.aiRefusedGone);
    for (final code in ['validation', 'unsupported']) {
      expect(aiRefusalText(code), l10n.aiRefusedNotAllowed);
    }
    for (final code in ['invalidResponse', 'rateLimited', 'network']) {
      expect(aiRefusalText(code), isNull);
    }
  });

  test('Inbox mark-all target binds but always requires its fixed card', () async {
    final h = await StackHarness.create(
      origin: const AiInboxOrigin(), level: AiAutonomyLevel.bypass,
    );
    addTearDown(h.dispose);
    h.provider.script.add((_) => toolTurn('markAllTodosDone', {
      'reason': 'Synthetic inbox request',
    }));
    final sending = h.controller.send('Complete all my todos');
    await waitFor(() => h.controller.proposals.isNotEmpty ||
        h.controller.phase == AiChatPhase.idle);
    expect(h.server.mutations, isEmpty);
    expect(h.controller.proposals, hasLength(1));
    final proposal = h.controller.proposals.single;
    expect(proposal.tier.decision, AiGateDecision.requireApproval);
    expect(proposal.tier.reasons, [AiFixedConfirmReason.markAllTodosDone]);
    await h.controller.rejectWrite(proposal);
    await sending.timeout(mr6b2Timeout);
    expect(h.server.mutations, isEmpty);
  });

  for (final status in [200, 422, 500]) {
    test('stored variable audit notice follows automatic terminal HTTP $status', () async {
      final h = await Mr6b2Harness.create(level: AiAutonomyLevel.bypass);
      addTearDown(h.dispose);
      h.server.mutationStatus = status == 200 ? null : status;
      h.beginRun('Retry https://example.com/gitlab/team/example-9/-/pipelines/12');
      final call = h.call('pipelineAction', mr6b2Args('pipelineAction'));
      final outcome = await h.coordinator.execute(call).timeout(mr6b2Timeout);
      expect(outcome.state, switch (status) {
        200 => AiJournalState.succeeded,
        422 => AiJournalState.failedCertain,
        _ => AiJournalState.writeUncertain,
      });
      expect(outcome.auditNotice, status == 422 ? isNull : 'storedVariablesMayApply');
      expect(h.server.mutationCount(), 1);
    });
  }

  test('stored variable notice absent when automatic retry was not sent', () async {
    final h = await Mr6b2Harness.create(level: AiAutonomyLevel.bypass);
    addTearDown(h.dispose);
    h.beginRun('Retry https://example.com/gitlab/team/example-9/-/pipelines/12');
    var freshnessReads = 0;
    h.coordinator = h.newCoordinator(readFreshness: (_) async {
      if (++freshnessReads == 2) throw const ApiFailure(FailureKind.forbidden);
      return const AiWriteFreshness();
    });
    h.beginRun('Retry https://example.com/gitlab/team/example-9/-/pipelines/12');
    final outcome = await h.coordinator.execute(
      h.call('pipelineAction', mr6b2Args('pipelineAction')),
    ).timeout(mr6b2Timeout);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.auditNotice, isNull);
    expect(h.server.mutationCount(), 0);
  });
}

final class _FailPreparePort implements port.AiGitLabWritePort {
  const _FailPreparePort(this.kind);
  final FailureKind kind;

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async =>
      throw ApiFailure(kind);

  @override
  Future<port.AiWriteOutcome> commit(port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => throw StateError('prepare failed; commit must not run');
}
