import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

// Plan v6 §15 row 6: 「卡片雙擊、兩個對話同時對同一資源、soft-timeout
// 讀取後立刻要求寫入、修改內容後按舊核准、兩段對話同時核准而改寫同一份
// 日誌；最多一次 dispatch，日誌只有單一寫入者。」
// §15 row 7: 「29／31 分鐘、等待期間 head／revision／權限／等級／範圍
// 變更、輸入名稱不符、重啟後過期卡片、逾時後的通知點擊；零未授權寫入；
// 等級被調低時執行前重判；拒絕、失敗、狀態未知後卡片保留使用者改過的內容。」

void main() {
  group('§15 rows 6–7 graph approval races', () {
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

    for (final change in ['revision', 'head', 'level', 'scope', 'permission']) {
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
            case 'head':
              policy.head = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
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
    test(
      'substantive graph edit is refused by the old target digest and kept',
      () async {
        final h = await _harness();
        final proposal = (await h.propose('createWorkItemActivityComment'))!;
        const edited = 'A substantive user correction to the comment.';
        expect(
          (await h.coordinator.approve(
            proposal,
            editedText: edited,
          )).reasonCode,
          'approvalRequired',
        );
        final outcome = await h.approve(proposal);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'targetChanged');
        expect(h.server.mutations, 0);
        expect(proposal.editedText, edited);
        expect(h.coordinator.settledEdits, contains(same(proposal)));
      },
    );

    for (final terminal in ['refused', 'failed', 'uncertain']) {
      test('$terminal keeps the edited comment card', () async {
        final h = await _harness();
        final proposal = (await h.propose(
          'createWorkItemActivityComment',
          id: 'edited',
        ))!;
        // Substantive body edits change the graph target digest (tested below).
        // A whitespace edit preserves the port's trimmed-body digest and lets
        // the real uncertain path prove exact user-text retention.
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
        if (terminal == 'refused') {
          await h.coordinator.reject(proposal);
          expect(proposal.outcome?.reasonCode, 'userRejected');
        } else if (terminal == 'failed') {
          h.policy.level = AiAutonomyLevel.readOnly;
          final failed = await h.approve(proposal);
          expect(failed.state, AiJournalState.notExecuted);
          expect(failed.reasonCode, 'policyDenied');
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
      });
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
  String head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
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
      headSha: policy.head,
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
