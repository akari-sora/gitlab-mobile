import 'release_policy_support.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show UploadPlaceholderTable;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';
import 'fx_coord_support.dart';
import 'mr6b2_merge_port_test.dart' as merge;

void main() {
  late _Harness harness;

  setUp(() async => harness = await _Harness.create());
  tearDown(() => harness.close());

  test('merge mutation success without readback is not confirmed', () async {
    final proposal = (await harness.propose('mergeRequest'))!;
    harness.server.readbackStatus = 500;

    final outcome = await harness.coordinator.approve(proposal);

    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.reasonCode, 'mergeAccepted');
    expect(outcome.readbackConfirmed, isFalse);
    expect(harness.server.writes, hasLength(1));
  });

  test(
    'merge result codes and readback confirmation remain distinct',
    () async {
      for (final entry in <(String, bool, String)>[
        ('merged', false, 'merged'),
        ('opened', true, 'autoMergeScheduled'),
        ('opened', false, 'mergeAccepted'),
      ]) {
        harness.server.resultState = entry.$1;
        final proposal = (await harness.propose(
          'mergeRequest',
          autoMerge: entry.$2,
        ))!;

        final outcome = await harness.coordinator.approve(proposal);

        expect(outcome.reasonCode, entry.$3);
        expect(outcome.readbackConfirmed, isTrue);
        harness.server.sent = false;
        harness.server.resultState = null;
      }
    },
  );

  test('accepted asynchronous rebase is never readback-confirmed', () async {
    final proposal = (await harness.propose('rebaseMergeRequest'))!;

    final outcome = await harness.coordinator.approve(proposal);

    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.reasonCode, 'succeeded');
    expect(outcome.readbackConfirmed, isFalse);
    expect(harness.server.writes, hasLength(1));
  });

  test(
    'bypass draft-note delete stays unbound when only its parent is named',
    () async {
      harness.level = AiAutonomyLevel.bypass;
      harness.coordinator.beginRun('Delete the draft note on !3');
      harness.coordinator.beginTurn();

      final proposal = await harness.coordinator.propose(
        AiToolCall(
          id: 'fix1-delete-draft-note',
          name: 'deleteDraftNote',
          arguments: {
            'projectId': 9,
            'iid': 3,
            'noteId': 8,
            'reason': 'synthetic test',
          },
        ),
      );

      expect(proposal, isNotNull);
      expect(proposal!.tier.decision, AiGateDecision.requireApproval);
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.targetUnbound),
      );
      expect(harness.server.writes, isEmpty);
    },
  );

  for (final status in [405, 406, 409, 422]) {
    test('unapprove certain failures do not isolate later MR writes: $status', () async {
      harness.server.status = status;
      final failed = await harness.propose('unapproveMergeRequest');
      expect(failed, isNotNull);
      final failure = await harness.coordinator.approve(failed!);
      expect(failure.state, AiJournalState.failedCertain);
      expect(harness.server.writes, hasLength(1));

      harness.server.status = 200;
      harness.server.sent = false;
      final later = await harness.propose('rebaseMergeRequest');
      expect(later, isNotNull, reason: 'status $status must not isolate the MR');
      final outcome = await harness.coordinator.approve(later!);
      expect(outcome.state, AiJournalState.succeeded);
      expect(harness.server.writes, hasLength(2));
    });
  }

  for (final status in [405, 406]) {
    test('a $status outside unapprove keeps the unknown-result mapping', () async {
      final server = merge.Server();
      addTearDown(server.close);
      server.status = status;
      final prepared = await server.prepare(
        'createTodo',
        args: {'resource': 'merge_requests'},
      );

      final result = await server.commit(prepared);

      expect(result.state, AiJournalState.writeUncertain);
      expect(result.resultCode, 'invalidResponse');
      expect(server.writes, hasLength(1));
    });
  }

  test(
    'cancel auto-merge 500 does not fall back to the legacy endpoint',
    () async {
      harness.server.newCancelStatus = 500;
      final proposal = (await harness.propose('cancelAutoMerge'))!;

      final outcome = await harness.coordinator.approve(proposal);

      expect(outcome.state, AiJournalState.writeUncertain);
      expect(harness.server.writes, hasLength(1));
      expect(
        harness.server.writes.single.uri.path,
        endsWith('/cancel_auto_merge'),
      );
    },
  );

  test(
    'merge origin binds production rows and preserves result/readback states',
    () async {
      for (final scenario
          in <
            ({
              String state,
              bool autoMerge,
              bool readbackFails,
              String reasonCode,
              bool confirmed,
            })
          >[
            (
              state: 'merged',
              autoMerge: false,
              readbackFails: false,
              reasonCode: 'merged',
              confirmed: true,
            ),
            (
              state: 'opened',
              autoMerge: true,
              readbackFails: false,
              reasonCode: 'autoMergeScheduled',
              confirmed: true,
            ),
            (
              state: 'opened',
              autoMerge: false,
              readbackFails: false,
              reasonCode: 'mergeAccepted',
              confirmed: true,
            ),
            (
              state: 'opened',
              autoMerge: false,
              readbackFails: true,
              reasonCode: 'mergeAccepted',
              confirmed: false,
            ),
          ]) {
        var mutated = false;
        final stack = await StackHarness.create(
          level: AiAutonomyLevel.confirmEach,
          origin: AiWorkItemOrigin(
            project: StackServer().workspace.project,
            kind: AiWorkItemKind.mergeRequest,
            iid: 12,
            title: 'Synthetic merge request',
          ),
          configure: (server) {
            Map<String, Object?> mergeRequest({required bool afterMutation}) =>
                {
                  ...server.workspace.mergeRequest,
                  'state': afterMutation ? scenario.state : 'opened',
                  'changes_count': '0',
                  'diff_refs': {
                    'base_sha': WorkspaceFixture.sha,
                    'start_sha': WorkspaceFixture.sha,
                    'head_sha': WorkspaceFixture.sha,
                  },
                  if (afterMutation && scenario.autoMerge)
                    'auto_merge_enabled': true,
                  if (afterMutation && scenario.autoMerge)
                    'merge_when_pipeline_succeeds': true,
                };

            server.overrides['GET projects/42'] = (_) => jsonResponse({
              ...server.workspace.projectRecord,
              'ci_config_path': null,
            });
            server.overrides['GET projects/42/merge_requests/12'] = (_) {
              if (mutated && scenario.readbackFails) {
                return jsonResponse(<String, Object?>{}, status: 500);
              }
              return jsonResponse(mergeRequest(afterMutation: mutated));
            };
            server.overrides['GET projects/42/merge_requests/12/notes'] = (_) =>
                jsonResponse(<Object?>[]);
            server.overrides['GET projects/42/merge_requests/12/diffs'] = (_) =>
                jsonResponse(<Object?>[]);
            server.overrides['GET projects/42/repository/branches/main'] =
                (_) => jsonResponse({
                  'name': 'main',
                  'protected': false,
                  'commit': {'id': WorkspaceFixture.sha},
                });
            server.overrides['PUT projects/42/merge_requests/12/merge'] = (_) {
              mutated = true;
              return jsonResponse(mergeRequest(afterMutation: true));
            };
          },
        );
        addTearDown(stack.dispose);
        stack.provider.script.add(
          (_) => toolTurn('mergeRequest', {
            'projectId': 42,
            'iid': 12,
            'autoMerge': scenario.autoMerge,
            'squash': false,
            'reason': 'Synthetic test',
          }),
        );

        final sending = stack.controller.send(
          'Merge this merge request from `feature/navigation` to `main`',
        );
        await waitFor(
          () =>
              stack.controller.proposals.isNotEmpty ||
              stack.controller.phase == AiChatPhase.idle,
        );
        expect(
          stack.controller.proposals,
          isNotEmpty,
          reason: scenario.reasonCode,
        );
        final proposal = stack.controller.proposals.single;
        expect(
          proposal.tier.reasons,
          isNot(contains(AiFixedConfirmReason.targetUnbound)),
        );

        final outcome = await stack.controller.approveWrite(
          proposal,
          typedName: proposal.tier.typedName,
        );
        await sending.timeout(const Duration(seconds: 20));
        final item = stack.controller.items
            .whereType<AiToolRunItem>()
            .singleWhere((value) => value.name == 'mergeRequest');
        final row = stack.controller.writeRowFor(item)!;
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.reasonCode, scenario.reasonCode);
        expect(outcome.readbackConfirmed, scenario.confirmed);
        expect(row.outcome?.reasonCode, scenario.reasonCode);
        expect(row.outcome?.readbackConfirmed, scenario.confirmed);
      }
    },
  );
}

final class _Harness {
  _Harness(this.root, this.journal);

  final Directory root;
  final AiWriteJournal journal;
  final server = merge.Server();
  final budget = AiToolBudget(maxGitLabRequests: 400);
  late final PolicyAiWriteCoordinator coordinator;
  var calls = 0;
  var level = AiAutonomyLevel.confirmEach;

  static Future<_Harness> create() async {
    final root = Directory.systemTemp.createTempSync('fix1-merge-coordinator-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'fix1-merge-test',
    );
    await journal.recoverAfterAccountsLoaded([merge.account]);
    await journal.ensureInitialized(merge.account);
    final harness = _Harness(root, journal);
    harness.coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        scope: merge.scope,
        level: harness.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'fix1-merge',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 1,
        appInForeground: true,
      ),
      createPort: () => harness.server.port,
      journal: journal,
      conversationId: 'fix1-merge',
      budget: () => harness.budget,
      readFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      placeholders: UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const <String>{},
      safeDisplay: (value) => value,
      ledger: const _VisibleMergeRows(),
    );
    return harness;
  }

  Future<AiWriteProposal?> propose(String operation, {bool autoMerge = false}) {
    final message = switch (operation) {
      'mergeRequest' => 'merge !3 `topic/a` `feature-target`',
      'approveMergeRequest' => 'approve !3',
      'unapproveMergeRequest' => 'unapprove !3',
      'cancelAutoMerge' => 'cancel auto-merge for !3',
      _ => 'rebase !3',
    };
    coordinator.beginRun(message);
    coordinator.beginTurn();
    return coordinator.propose(
      AiToolCall(
        id: 'fix1-${++calls}',
        name: operation,
        arguments: {
          'projectId': 9,
          'iid': 3,
          if (operation == 'mergeRequest') 'autoMerge': autoMerge,
          'reason': 'synthetic test',
        },
      ),
    );
  }

  void close() {
    coordinator.stop('done');
    server.close();
    root.deleteSync(recursive: true);
  }
}

final class _VisibleMergeRows implements AiCapabilityLedger {
  const _VisibleMergeRows();

  static const extraOperations = {'unapproveMergeRequest'};

  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null ||
        (!aiMergeRows.contains(row) &&
            !extraOperations.contains(operationId))) {
      return null;
    }
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      modelVisible: true,
      httpCap: row.httpCap,
      readback: row.readback,
      arguments: row.arguments,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final row in aiMergeRows) find(row.operationId)!,
    for (final operationId in extraOperations) find(operationId)!,
  ];
}
