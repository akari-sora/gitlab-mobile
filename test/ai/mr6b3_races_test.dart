import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';
import 'runner_test.dart' as runner_helpers;

// Plan v6 §15 row 6: 「卡片雙擊、兩個對話同時對同一資源、soft-timeout
// 讀取後立刻要求寫入、修改內容後按舊核准、兩段對話同時核准而改寫同一份
// 日誌；最多一次 dispatch，日誌只有單一寫入者。」
// §15 row 7: 「29／31 分鐘、等待期間 head／revision／權限／等級／範圍
// 變更、輸入名稱不符、重啟後過期卡片、逾時後的通知點擊；零未授權寫入；
// 等級被調低時執行前重判；拒絕、失敗、狀態未知後卡片保留使用者改過的內容。」
// NOT_RUN: row 7 notification click after expiry and typed-name mismatch
// (the latter is covered in mr6b3_matrix_test.dart); graph Work Items have no
// head SHA, so the former synthetic head-change case has been removed.
// NOT_RUN: rows 6–7 substantive edited-body delivery/readback (issue #23),
// and failedCertain after graph acceptance (not a graph outcome). The 403 case
// below proves server refusal during the fresh read, before any mutation.

void main() {
  group('§15 rows 6–7 graph approval races', () {
    test(
      'soft-timeout read refuses the next graph write without reviving it',
      () async {
        final h = await _harness();
        // If the pending-read guard regresses, this bound write can execute
        // immediately through the real coordinator and GraphQL port.
        h.policy.level = AiAutonomyLevel.bypass;
        final provider = runner_helpers.Harness();
        final readStarted = Completer<void>();
        final pendingRead = Completer<AiToolResult>();
        final results = <AiToolResult>[];
        final write = _call('updateWorkItemState', 'after-soft-timeout');
        var reads = 0;
        var turns = 0;
        provider.respond = (_, _) async {
          switch (++turns) {
            case 1:
              return provider.turn(calls: [runner_helpers.call('slow-read')]);
            case 2:
              expect(pendingRead.isCompleted, isFalse);
              expect(results.single.callId, 'slow-read');
              expect(results.single.content, contains('timeout'));
              return provider.turn(calls: [write]);
            default:
              return provider.turn(text: 'done');
          }
        };
        final runner = AiRunner(
          config: provider.config(),
          wire: provider.wire,
          complete: provider.complete,
          secrets: provider.secrets,
          refreshSecrets: () async {},
          guard: AiRunGuard(
            expectedGeneration: 1,
            ownerApi: provider.owner,
            generation: () => provider.generation,
            api: () => provider.api,
            recipientRevision: () => provider.revision,
            consentValid: () => provider.consent,
          ),
          system: 'Synthetic runner race',
          tools: [runner_helpers.spec, ...h.coordinator.specs],
          writeCoordinator: h.coordinator,
          close: () {},
          cancelActive: () {},
          executeTool: (call) {
            expect(call.name, 'read_file');
            reads++;
            readStarted.complete();
            return pendingRead.future;
          },
          onToolResult: results.add,
          toolDeadline: const Duration(milliseconds: 5),
        );
        addTearDown(runner.stop);

        final running = runner.run('Close #3 in team/example-9.');
        await readStarted.future;
        expect(pendingRead.isCompleted, isFalse);
        expect((await running).reason, AiRunEnd.done);
        expect(reads, 1);
        expect(turns, 3);
        final refused = results.singleWhere((r) => r.callId == write.id);
        expect(refused.name, 'updateWorkItemState');
        expect(refused.notExecuted, isTrue);
        expect(refused.content, contains('read_pending'));
        expect(h.coordinator.proposals, isEmpty);
        expect(h.coordinator.recordedOutcomeFor(write.id), isNull);
        expect(h.journal.entries(mr6b3Account), isEmpty);
        expect(h.server.adapter.requests, isEmpty);
        expect(h.server.mutations, 0);

        final frozen = List<String>.of(runner.segment!.frozenWireJson);
        final pairedResults = List<AiToolResult>.of(results);
        pendingRead.complete(
          AiToolResult(
            callId: 'slow-read',
            name: 'read_file',
            content: 'late read result',
          ),
        );
        await pendingRead.future;
        // Drain the underlying Future's settlement, without a timing guess.
        await Future<void>.delayed(Duration.zero);
        expect(runner.segment!.frozenWireJson, frozen);
        expect(results, pairedResults);
        expect(h.coordinator.proposals, isEmpty);
        expect(h.coordinator.recordedOutcomeFor(write.id), isNull);
        expect(h.journal.entries(mr6b3Account), isEmpty);
        expect(h.server.mutations, 0);
        expect(
          (await runner.run('Continue with an answer.')).reason,
          AiRunEnd.done,
        );
        expect(h.coordinator.proposals, isEmpty);
        expect(h.journal.entries(mr6b3Account), isEmpty);
        expect(h.server.adapter.requests, isEmpty);
        expect(h.server.mutations, 0);
      },
    );

    for (final operation in [
      'updateWorkItemState',
      'createWorkItemActivityReply',
      'snoozeTodo',
    ]) {
      test('$operation double-tap dispatches one execution', () async {
        final h = await _harness();
        final proposal = (await h.propose(operation))!;
        final entered = h.files.armBarrier(
          writesBeforeBarrier: 1,
          afterPersist: true,
        );
        final first = h.approve(proposal);
        await entered;
        final second = h.approve(proposal);
        final durable = await h.readDurableJournal();
        expect(
          ((durable['entries']! as List).single as Map)['state'],
          'dispatching',
        );
        expect(h.server.mutations, 0);
        h.files.releaseBarrier();
        final outcomes = await Future.wait([first, second]);
        expect(
          outcomes.every((o) => o.executionId == proposal.executionId),
          isTrue,
        );
        expect(outcomes.every((o) => o.successful), isTrue);
        expect(h.server.mutations, 1);
        expect(h.journal.entries(mr6b3Account), hasLength(1));
        expect(
          h.journal.conversationWriteCount(mr6b3Account, 'mr6b3-p15-budget'),
          1,
        );
      });
    }

    test('two conversations share one writer and one dispatch', () async {
      final h = await _harness();
      final first = (await h.propose('updateWorkItemState', id: 'first'))!;
      final policy = _Policy();
      final peer = _coordinator(h, policy, 'second-conversation');
      final second = (await peer.propose(
        _call('updateWorkItemState', 'second'),
      ))!;
      final entered = h.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final firstApproval = h.approve(first);
      await entered;
      final secondApproval = peer.approve(second);
      final durable = await h.readDurableJournal();
      final entries = durable['entries']! as List;
      expect(entries, hasLength(1));
      expect((entries.single as Map)['execution'], first.executionId);
      expect((entries.single as Map)['state'], 'dispatching');
      h.files.releaseBarrier();
      final outcomes = await Future.wait([firstApproval, secondApproval]);
      expect(outcomes.where((o) => o.successful), hasLength(1));
      final refused = outcomes.singleWhere((o) => !o.successful);
      expect(refused.state, AiJournalState.notExecuted);
      expect(refused.reasonCode, 'isolated');
      expect(h.server.mutations, 1);
      expect(h.journal.entries(mr6b3Account), hasLength(1));
      expect(
        h.journal.conversationWriteCount(mr6b3Account, 'mr6b3-p15-budget'),
        1,
      );
      expect(
        h.journal.conversationWriteCount(mr6b3Account, 'second-conversation'),
        0,
      );
    });

    test(
      'note content changed after preview refuses its stale binding digest',
      () async {
        final h = await _harness();
        final proposal = (await h.propose('createWorkItemActivityReply'))!;
        var changedPages = 0;
        h.server.onRequest = (name, mutation, request, payload) {
          if (name == 'MobileWorkItemActivity') {
            final item = (payload['data']! as Map)['workItem']! as Map;
            final widget = (item['widgets']! as List).single as Map;
            final discussions =
                (widget['discussions']! as Map)['nodes']! as List;
            for (final raw in discussions) {
              final notes = ((raw as Map)['notes']! as Map)['nodes']! as List;
              for (final note in notes) {
                (note as Map)['body'] = 'Changed after the user saw the card';
                changedPages++;
              }
            }
          }
          return null;
        };
        final outcome = await h.approve(proposal);
        expect(changedPages, 1);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'targetChanged');
        expect(h.server.mutations, 0);
        expect(
          h.journal.entries(mr6b3Account).single.state,
          AiJournalState.notExecuted,
        );
      },
    );
  });

  group('§15 row 7 graph waiting and expiry', () {
    for (final minutes in [29, 31]) {
      test(
        '$minutes minutes ${minutes == 29 ? 'remains valid' : 'expires'}',
        () async {
          final h = await _harness();
          final policy = _Policy();
          final coordinator = _coordinator(h, policy, 'wait-$minutes');
          final proposal = (await coordinator.propose(
            _call('updateWorkItemState', 'wait'),
          ))!;
          policy.clock = policy.clock.add(Duration(minutes: minutes));
          coordinator.checkNow();
          final outcome = await coordinator.approve(proposal);
          expect(
            outcome.state,
            minutes == 29
                ? AiJournalState.succeeded
                : AiJournalState.notExecuted,
          );
          expect(
            outcome.reasonCode,
            minutes == 29 ? 'succeeded' : 'approvalExpired',
          );
          expect(h.server.mutations, minutes == 29 ? 1 : 0);
        },
      );
    }

    for (final change in ['revision', 'level', 'scope', 'permission']) {
      test(
        '$change changed while waiting is re-judged before dispatch',
        () async {
          final h = await _harness();
          final policy = _Policy();
          final coordinator = _coordinator(h, policy, 'change-$change');
          final proposal = (await coordinator.propose(
            _call('updateWorkItemState', 'waiting'),
          ))!;
          switch (change) {
            case 'revision':
              policy.revision = mr6b3BumpedRevision;
            case 'level':
              policy.level = AiAutonomyLevel.readOnly;
            case 'scope':
              policy.scope = const AiWriteScope(
                accountKey: mr6b3Account,
                grants: [
                  AiScopeGrant(
                    kind: AiScopeKind.workItem,
                    projectId: 10,
                    projectPath: 'team/example-10',
                    iid: 3,
                  ),
                ],
              );
            case 'permission':
              h.server.onRequest = (name, mutation, request, payload) {
                if (name == 'MobileWorkItemState') {
                  final item = (payload['data']! as Map)['workItem']! as Map;
                  (item['userPermissions']! as Map)['updateWorkItem'] = false;
                }
                return null;
              };
          }
          final outcome = await coordinator.approve(proposal);
          expect(outcome.state, AiJournalState.notExecuted);
          expect(outcome.reasonCode, switch (change) {
            'level' => 'policyDenied',
            'scope' => 'settingsChanged',
            'permission' => 'stateForbidden',
            _ => 'targetChanged',
          });
          expect(outcome.mutationCount, 0);
          expect(h.server.mutations, 0);
        },
      );
    }

    test(
      'changed graph revision invalidates the real re-prepared target',
      () async {
        final h = await _harness();
        final proposal = (await h.propose('updateWorkItemState'))!;
        h.server.revision = mr6b3BumpedRevision;
        final outcome = await h.approve(proposal);
        expect(outcome.reasonCode, 'targetChanged');
        expect(outcome.state, AiJournalState.notExecuted);
        expect(h.server.mutations, 0);
      },
    );

    test('restart never revives an expired process-local card', () async {
      final h = await _harness();
      final policy = _Policy();
      final old = _coordinator(h, policy, 'before-restart');
      final proposal = (await old.propose(
        _call('updateWorkItemState', 'old'),
      ))!;
      expect(h.journal.entries(mr6b3Account), isEmpty);
      policy.clock = policy.clock.add(const Duration(minutes: 31));
      final recovered = await h.recoverInNewProcess();
      final restarted = _coordinator(
        h,
        policy,
        'after-restart',
        journal: recovered,
      );
      final unowned = await restarted.approve(proposal);
      expect(unowned.reasonCode, 'invalidProposal');
      expect(unowned.state, AiJournalState.notExecuted);
      final expired = await old.approve(proposal);
      expect(expired.reasonCode, 'approvalExpired');
      expect(expired.state, AiJournalState.notExecuted);
      expect(h.server.mutations, 0);
      expect(recovered.entries(mr6b3Account), isEmpty);
    });
  });

  group('§15 row 7 edited graph cards retain user text', () {
    for (final operation in [
      'createWorkItemActivityComment',
      'createWorkItemActivityReply',
    ]) {
      test('$operation edit invalidates the pre-edit approval', () async {
        final h = await _harness();
        final proposal = (await h.propose(operation))!;
        const edited = 'A substantive user correction to the comment.';
        // Approving while replacing the card text cannot use the old approval
        // to send: it only rebuilds the preview and asks for a fresh approval.
        final result = await h.coordinator.approve(
          proposal,
          editedText: edited,
        );
        expect(result.state, AiJournalState.notExecuted);
        expect(result.reasonCode, 'approvalRequired');
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
        expect(proposal.editedText, edited);
        expect(proposal.previewText, contains(edited));
        expect(proposal.valid, isTrue);
      });
    }

    test(
      'substantive graph edit is sent once after a new approval (#23)',
      () async {
        // Plan v6 §7.1: an edit re-processes the text and invalidates the old
        // approval; a new explicit approval sends exactly the shown text once.
        for (final operation in [
          'createWorkItemActivityComment',
          'createWorkItemActivityReply',
        ]) {
          final h = await _harness();
          final proposal = (await h.propose(operation))!;
          const edited = 'A substantive user correction to the comment.';
          final pending = await h.coordinator.approve(
            proposal,
            editedText: edited,
          );
          expect(pending.reasonCode, 'approvalRequired', reason: operation);
          expect(h.server.mutations, 0);
          final again = await h.coordinator.approve(
            proposal,
            editedText: edited,
          );
          expect(again.reasonCode, 'approvalRequired', reason: operation);
          expect(h.server.mutations, 0);
          final shown =
              (proposal.preview as port.AiFieldsPreview).fields['body'];
          final outcome = await h.approve(proposal);
          expect(outcome.state, AiJournalState.succeeded, reason: operation);
          expect(outcome.readbackConfirmed, isTrue);
          expect(h.server.mutations, 1);
          expect(h.server.createdBody, shown);
          expect(proposal.editedText, isNull);
        }
      },
    );

    for (final terminal in [
      'user refusal',
      'fresh-read 403 refusal',
      'uncertain',
    ]) {
      test(
        '$terminal keeps the ${terminal == 'uncertain' ? 'whitespace-only ' : ''}edited comment card',
        () async {
          final h = await _harness();
          final proposal = (await h.propose(
            'createWorkItemActivityComment',
            id: 'edited',
          ))!;
          // The uncertain case uses only whitespace (trimmed by the port) to
          // test retention; delivery of a substantive edit is covered above.
          final edited = terminal == 'uncertain'
              ? ' \n$mr6b3ActivityBody\n '
              : 'User corrected the Markdown.\nKeep **this exact** text.';
          final editedResult = await h.coordinator.approve(
            proposal,
            editedText: edited,
          );
          expect(editedResult.reasonCode, 'approvalRequired');
          expect(proposal.editedText, edited);
          expect(h.server.mutations, 0);
          if (terminal == 'user refusal') {
            await h.coordinator.reject(proposal);
            expect(proposal.outcome?.reasonCode, 'userRejected');
          } else if (terminal == 'fresh-read 403 refusal') {
            var refusals = 0;
            h.server.onRequest = (name, mutation, request, payload) {
              if (name == 'MobileWorkItemActivityWriteAccess') {
                expect(mutation, isFalse);
                refusals++;
                return jsonResponse({
                  'message': 'synthetic forbidden',
                }, status: 403);
              }
              return null;
            };
            final refused = await h.approve(proposal);
            expect(refusals, 1);
            expect(refused.state, AiJournalState.notExecuted);
            expect(refused.reasonCode, 'activityForbidden');
            expect(h.server.mutations, 0);
          } else {
            h.server.onRequest = (name, mutation, request, payload) => mutation
                ? jsonResponse({
                    'message': 'synthetic lost acknowledgement',
                  }, status: 503)
                : null;
            final unknown = await h.approve(proposal);
            expect(unknown.state, AiJournalState.writeUncertain);
            expect(unknown.mutationCount, 1);
          }
          expect(proposal.editedText, edited);
          expect(h.coordinator.settledEdits, contains(same(proposal)));
          expect(proposal.valid, isFalse);
        },
      );
    }
  });
}

Future<Mr6b3ApiHarness> _harness() async {
  final h = await Mr6b3ApiHarness.create(oauth: false);
  addTearDown(h.dispose);
  return h;
}

AiToolCall _call(String operation, String id) => AiToolCall(
  id: id,
  name: operation,
  arguments: {
    ...mr6b3ApiArguments(operation),
    'reason': 'synthetic race request',
  },
);

final class _Policy {
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  AiWriteScope scope = mr6b3Scope;
  String revision = mr6b3Revision;
}

PolicyAiWriteCoordinator _coordinator(
  Mr6b3ApiHarness h,
  _Policy policy,
  String conversation, {
  AiWriteJournal? journal,
}) {
  final budget = AiToolBudget(maxGitLabRequests: 40);
  final coordinator = PolicyAiWriteCoordinator(
    snapshot: () => AiWritePolicySnapshot(
      scope: policy.scope,
      level: policy.level,
      ceiling: AiAutonomyLevel.bypass,
      consentHash: 'mr6b3-consent',
      writePolicyRevision: 1,
      scopeRevision: 1,
      sessionGeneration: 7,
    ),
    createPort: () => h.server.writePort,
    journal: journal ?? h.journal,
    conversationId: conversation,
    budget: () => budget,
    readFreshness: (_) async => AiWriteFreshness(
      updatedAt: policy.revision,
      visibilityUnreadable: false,
    ),
    placeholders: text.UploadPlaceholderTable(instance: h.server.api.instance),
    knownSecrets: () => const {},
    safeDisplay: (v) => v,
    now: () => policy.clock,
    httpCost: (op) => aiWriteRequestAllowance(op, oauthReplay: false),
  );
  coordinator.beginRun('Update #3 in team/example-9.');
  coordinator.beginTurn();
  addTearDown(() => coordinator.stop('testEnd'));
  return coordinator;
}
