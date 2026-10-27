import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/graphql_write_hooks.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

// §15 row 25. **GraphQL 接縫：** 方法內前置讀取回 5xx 或傳輸錯誤時不上鎖、mutation 次數為 0、日誌為 `notExecuted`；`beforeMutation` flush 失敗或 `mayStart` 回 false 時不送 mutation；日期 `applied`＋`mutationSent: false`、健康度、狀態與標籤的 `noop`，以及指派、里程碑、權重、通知、內容、事件單、活動留言編輯在送出前返回的相同快照，逐一記「無變更」且同輪繼續；日期 `notApplied`＋`mutationSent: false`（驗證或權限失敗）記 `notExecuted` 並適用 fail-stop；以上都不上鎖、不消耗預算與待確認標記；過了接受點之後，日期返回 `writeUncertain` 或 `notApplied` 且 `mutationSent` 為 true、健康度 `notApplied`、狀態 `notApplied` 且 `mutationSent` 為 true 時，日誌不得是 `succeeded`，同輪後續寫入次數為 0；三個失敗型別依 `mutationSent` 分類，不經 `safeFailure`；狀態方法的 `onMutationSent(started)` 由 AI 傳入時只呼叫 `started`，新掛鉤在它之前；429 之後的本機快速失敗在預檢被攔下，不上鎖；以 FakeAdapter 斷言每個 `graphMutation` 請求抵達 adapter 時，日誌已是 `dispatching`；mutation 成功後 readback `cancelled` 或 401 記為狀態未知；畫面正在寫同一 Work Item 的狀態、日期或健康度時 AI 不 dispatch；`setIncidentStatus` 一律帶 `expectedUpdatedAt`；待辦延後以 mutation 回應的 `snoozedUntil` 記成功，`snoozedTodos` 查不到或 truncated 只是不升為「已 readback 確認」；方法內 HTTP 次數以 ledger 上限計入預算。
// §15 row 29. **送出邊界（§7.3 第 4 步）：** 用 barrier 卡住 flush，期間分別撤銷 policy 或 consent、停止 run、切換 generation，恢復後 mutation 為 0；分開斷言「掛鉤未落盤」（`prepared` → `notExecuted`）、「已落盤但同步重驗不通過」（`dispatching` → `notExecuted`，退回預算、恢復待確認標記，這次落盤失敗則維持 `dispatching`）與「已送出但終態落盤失敗」（記憶體中為狀態未知、隔離維持、重啟後為 `writeUncertain`）；送出票不能重用；同步重驗與 mutation 呼叫之間沒有 await（以測試替身斷言呼叫順序）；flush 期間另一段對話的讀取收到 429、client 被關閉、帳號進入「移除中」、沒有許可的 run 被切到背景時，同步重驗不通過，記 `notExecuted` 而不是狀態未知。以 barrier 卡住 `dispatching` 的 flush，移除流程等待達上限後顯示最後確認、使用者取消，epoch 遞增並釋放保留；flush 恢復後舊綁定因 epoch 不符不能送出，mutation 為 0，`notExecuted` 與退回預算、恢復待確認標記在同一次原子更新完成；停在 §7.3 第 2–4.3 步的寫入同樣在第 4.4 步轉為 `notExecuted`；帳號有移除 tombstone 而保留已釋放時，同步重驗同樣不通過。
//
// Cross-family rerun through PolicyAiWriteCoordinator -> GitLabAiWritePort ->
// the real core methods -> Mr6b3ApiServer. All fifteen operations exercise the
// adapter boundary and single-use ticket; all ten noop-capable operations
// exercise their real same-snapshot return. Comment/reply creation, deletion,
// snooze and unsnooze have no noop contract and must send even if reads repeat.
//
// State represents scalar T2 writes; assignees the list argument; dates the
// compound result; incident its expectedUpdatedAt fence; snooze the todo path;
// reaction and notifications the directional T1 writes; deletion typed T4.
// Their shared coordinator flush/rollback cases stand for the other families.
// Only the explicitly named call-order test uses a port double; actual core
// source-order checks accompany it because Dio may yield before adapter.fetch.

const _conversation = 'mr6b3-p15-budget';
const _operations = [
  'createWorkItemActivityComment',
  'createWorkItemActivityReply',
  'deleteWorkItemActivityNote',
  'updateWorkItemDates',
  'updateWorkItemAssignees',
  'updateWorkItemHealthStatus',
  'setWorkItemNotifications',
  'setIncidentStatus',
  'updateWorkItemMilestone',
  'setWorkItemActivityNoteReaction',
  'updateWorkItemStatus',
  'snoozeTodo',
  'unsnoozeTodo',
  'updateWorkItemState',
  'updateWorkItemWeight',
];

typedef _Preflight = ({
  String operation,
  String query,
  int ordinal,
  String serverReason,
  String transportReason,
});

const _preflights = <_Preflight>[
  (
    operation: 'updateWorkItemState',
    query: 'MobileWorkItemState',
    ordinal: 3,
    serverReason: 'server',
    transportReason: 'network',
  ),
  (
    operation: 'updateWorkItemAssignees',
    query: 'MobileWorkItemAssignees',
    ordinal: 3,
    serverReason: 'assigneeConflict',
    transportReason: 'assigneeConflict',
  ),
  (
    operation: 'updateWorkItemDates',
    query: 'MobileWorkItemDatesBase',
    ordinal: 3,
    serverReason: 'datesConflict',
    transportReason: 'datesConflict',
  ),
  (
    operation: 'setIncidentStatus',
    query: 'MobileIncidentStatus',
    ordinal: 3,
    serverReason: 'incidentRejected',
    transportReason: 'incidentRejected',
  ),
  (
    // Snooze has no in-method HTTP pre-read: final ownership verification is
    // in re-prepare. Its fifth page request starts that second ownership read.
    operation: 'snoozeTodo',
    query: 'MobilePendingTodosForSnooze',
    ordinal: 5,
    serverReason: 'todoUnverifiable',
    transportReason: 'network',
  ),
  (
    operation: 'setWorkItemActivityNoteReaction',
    query: 'MobileWorkItemActivityReactionAccess',
    ordinal: 5,
    serverReason: 'server',
    transportReason: 'network',
  ),
  (
    operation: 'setWorkItemNotifications',
    query: 'MobileWorkItemNotifications',
    ordinal: 3,
    serverReason: 'server',
    transportReason: 'network',
  ),
  (
    operation: 'deleteWorkItemActivityNote',
    query: 'MobileWorkItemActivityEditAccess',
    ordinal: 3,
    serverReason: 'server',
    transportReason: 'network',
  ),
];

void main() {
  group('row 25 real adapter acceptance and row 29 one-shot ticket', () {
    for (final operation in _operations) {
      test(
        '$operation arrives dispatching and its ticket cannot be reused',
        () async {
          late _RetainedTicketPort wrapper;
          final h = await _harness(
            portFactory: (real) => wrapper = _RetainedTicketPort(real),
          );
          var observedMutations = 0;
          h.server.onRequest = (name, mutation, request, payload) {
            if (mutation) {
              observedMutations++;
              final entry = h.journal.entries(mr6b3Account).single;
              expect(entry.state, AiJournalState.dispatching);
              expect(entry.operationId, operation);
              expect(h.journal.isolated(mr6b3Account, entry.writeKeys), isTrue);
              expect(h.coordinator.outcomeFor('accepted'), isNull);
            }
            return null;
          };
          final proposal = await _proposal(h, operation, 'accepted');
          if (operation == 'deleteWorkItemActivityNote') {
            expect(proposal.tier.tier, AiWriteTier.t4);
            expect(proposal.tier.requiresTypedName, isTrue);
            expect(proposal.tier.typedName, '#3');
          }
          final outcome = await h.approve(proposal);
          await _expectResult(
            h,
            'accepted',
            outcome,
            state: AiJournalState.succeeded,
            reason: 'succeeded',
            mutations: 1,
            readback: operation != 'snoozeTodo' && operation != 'unsnoozeTodo',
          );
          expect(observedMutations, 1);
          expect(h.server.mutations, 1);
          _expectWriteCount(h, 1);
          _expectUnlocked(h, outcome);
          final requests = h.server.adapter.requests.length;
          final reused = await wrapper.commit(
            wrapper.ticket!,
            mayStart: () => fail('a used ticket must not recheck or send'),
          );
          expect(
            reused,
            isA<port.AiWriteNotSent>().having(
              (value) => value.reasonCode,
              'reason',
              'notAccepted',
            ),
          );
          final reusedGraph = await wrapper.ticket!.commitGraph(
            mayStart: () => fail('the graph ticket itself is also single-use'),
          );
          expect(
            reusedGraph,
            isA<port.AiWriteNotSent>().having(
              (value) => value.reasonCode,
              'reason',
              'graphBoundaryUnavailable',
            ),
          );
          expect(await h.approve(proposal), same(outcome));
          expect(h.coordinator.outcomeFor('accepted'), same(outcome));
          expect(h.server.adapter.requests, hasLength(requests));
          expect(h.server.mutations, 1);
        },
      );
    }

    for (final operation in [
      'setWorkItemActivityNoteReaction',
      'setWorkItemNotifications',
    ]) {
      test(
        '$operation opposite T1 direction also arrives dispatching',
        () async {
          final h = await _harness();
          h.server.reactionAwarded = true;
          h.server.notificationsOn = true;
          var observed = 0;
          h.server.onRequest = (name, mutation, request, payload) {
            if (mutation) {
              observed++;
              expect(
                h.journal.entries(mr6b3Account).single.state,
                AiJournalState.dispatching,
              );
            }
            return null;
          };
          final proposal = await _proposal(
            h,
            operation,
            'opposite',
            arguments: {
              if (operation == 'setWorkItemActivityNoteReaction') 'add': false,
              if (operation == 'setWorkItemNotifications') 'enabled': false,
            },
          );
          final outcome = await h.approve(proposal);
          await _expectResult(
            h,
            'opposite',
            outcome,
            state: AiJournalState.succeeded,
            reason: 'succeeded',
            mutations: 1,
            readback: true,
          );
          expect(observed, 1);
          expect(h.server.mutations, 1);
        },
      );
    }

    test(
      'T4 deletion refuses a wrong typed name without consuming approval',
      () async {
        final h = await _harness();
        final proposal = await _proposal(
          h,
          'deleteWorkItemActivityNote',
          'typed',
        );
        final requests = h.server.adapter.requests.length;
        final refused = await h.coordinator.approve(proposal, typedName: '#4');
        expect(refused.state, AiJournalState.notExecuted);
        expect(refused.reasonCode, 'typedNameMismatch');
        expect(refused.mutationCount, 0);
        // A wrong name is a retryable approval input, not a recorded terminal.
        expect(h.coordinator.outcomeFor('typed'), isNull);
        expect(h.journal.entries(mr6b3Account), isEmpty);
        expect(h.server.adapter.requests, hasLength(requests));
        expect(h.server.mutations, 0);
        expect(proposal.valid, isTrue);
        final outcome = await h.approve(proposal);
        await _expectResult(
          h,
          'typed',
          outcome,
          state: AiJournalState.succeeded,
          reason: 'succeeded',
          mutations: 1,
          readback: true,
        );
      },
    );
  });

  group('row 25 all real noop and same-snapshot returns', () {
    for (final operation in [
      'updateWorkItemState',
      'updateWorkItemStatus',
      'updateWorkItemDates',
      'updateWorkItemHealthStatus',
      'updateWorkItemAssignees',
      'updateWorkItemMilestone',
      'updateWorkItemWeight',
      'setWorkItemNotifications',
      'setWorkItemActivityNoteReaction',
      'setIncidentStatus',
    ]) {
      test(
        '$operation no change preserves marks and permits the same round',
        () async {
          final h = await _harness();
          await h.seedConfirmMark();
          _configureNoop(h.server, operation);
          final proposal = await _proposal(h, operation, 'noop');
          final writes = h.files.writeCount;
          final outcome = await h.approve(proposal);
          await _expectResult(
            h,
            'noop',
            outcome,
            state: AiJournalState.succeeded,
            reason: 'noChange',
            mutations: 0,
            journalState: AiJournalState.notExecuted,
            noChange: true,
          );
          expect(outcome.summary, contains('noChange'));
          expect(h.server.mutations, 0);
          // prepared + notExecuted only; the durable hook was never invoked.
          expect(h.files.writeCount - writes, 2);
          _expectWriteCount(h, 0);
          _expectMark(h, true);
          _expectUnlocked(h, outcome);
          final next = await _proposal(
            h,
            'updateWorkItemState',
            'after-noop',
            arguments: {
              'stateEvent': h.server.workItemState == 'CLOSED'
                  ? 'reopen'
                  : 'close',
            },
          );
          final continued = await h.approve(next);
          await _expectResult(
            h,
            'after-noop',
            continued,
            state: AiJournalState.succeeded,
            reason: 'succeeded',
            mutations: 1,
            readback: true,
          );
          expect(h.server.mutations, 1);
          _expectWriteCount(h, 1);
        },
      );
    }
  });

  group('row 25 pre-acceptance failures', () {
    for (final scenario in _preflights) {
      for (final transport in [false, true]) {
        test(
          '${scenario.operation} final pre-read ${transport ? 'transport' : '5xx'} is notExecuted',
          () async {
            final h = await _harness();
            await h.seedConfirmMark();
            final proposal = await _proposal(
              h,
              scenario.operation,
              'preflight',
            );
            var faults = 0;
            h.server.onRequest = (name, mutation, request, payload) {
              if (name == scenario.query &&
                  h.server.reads[name] == scenario.ordinal) {
                expect(mutation, isFalse);
                expect(
                  _entry(h, proposal.executionId).state,
                  AiJournalState.prepared,
                );
                faults++;
                if (transport) {
                  throw DioException(
                    requestOptions: request,
                    type: DioExceptionType.connectionError,
                  );
                }
                return jsonResponse({
                  'message': 'synthetic pre-read',
                }, status: 503);
              }
              return null;
            };
            final writes = h.files.writeCount;
            final outcome = await h.approve(proposal);
            await _expectResult(
              h,
              'preflight',
              outcome,
              state: AiJournalState.notExecuted,
              reason: transport
                  ? scenario.transportReason
                  : scenario.serverReason,
              mutations: 0,
            );
            expect(faults, 1);
            expect(h.server.mutations, 0);
            expect(h.files.writeCount - writes, 2);
            _expectWriteCount(h, 0);
            _expectMark(h, true);
            _expectUnlocked(h, outcome);
            await _expectFailStop(h);
          },
        );
      }
    }

    test(
      'dates notApplied without send on lost permission is notExecuted',
      () async {
        final h = await _harness();
        await h.seedConfirmMark();
        final proposal = await _proposal(
          h,
          'updateWorkItemDates',
          'dates-permission',
        );
        var denied = 0;
        h.server.onRequest = (name, mutation, request, payload) {
          if ((name == 'MobileWorkItemDatesBase' ||
                  name == 'MobileWorkItemDatesProbe') &&
              h.server.reads[name] == 3) {
            final item = (payload['data']! as Map)['workItem']! as Map;
            (item['userPermissions']! as Map)['setWorkItemMetadata'] = false;
            denied++;
          }
          return null;
        };
        final outcome = await h.approve(proposal);
        await _expectResult(
          h,
          'dates-permission',
          outcome,
          state: AiJournalState.notExecuted,
          reason: 'datesForbidden',
          mutations: 0,
        );
        expect(denied, 2);
        expect(h.server.mutations, 0);
        _expectWriteCount(h, 0);
        _expectMark(h, true);
        _expectUnlocked(h, outcome);
        await _expectFailStop(h);
      },
    );

    test(
      '429 cooldown rejects the next proposal at the local pre-check',
      () async {
        final h = await _harness();
        h.server.onRequest = (name, mutation, request, payload) => jsonResponse(
          {'message': 'peer conversation cooldown'},
          status: 429,
          headers: {
            'retry-after': ['60'],
          },
        );
        await expectLater(
          h.server.api.record(['projects', '9']),
          throwsA(
            isA<ApiFailure>().having(
              (value) => value.kind,
              'kind',
              FailureKind.rateLimited,
            ),
          ),
        );
        expect(h.server.api.mayStartRequest, isFalse);
        final requests = h.server.adapter.requests.length;
        expect(await h.propose('updateWorkItemState', id: 'cooldown'), isNull);
        final outcome = h.coordinator.outcomeFor('cooldown')!;
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'clientUnavailable');
        expect(outcome.mutationCount, 0);
        expect(h.server.adapter.requests, hasLength(requests));
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
        expect(h.journal.isolated(mr6b3Account, {mr6b3WriteKey}), isFalse);
        _expectWriteCount(h, 0);
      },
    );
  });

  group('row 25 typed results after acceptance', () {
    for (final operation in [
      'updateWorkItemDates',
      'updateWorkItemHealthStatus',
      'updateWorkItemStatus',
    ]) {
      test(
        '$operation notApplied after send is uncertain and fail-stops',
        () async {
          final h = await _harness();
          h.server.applyMutations = false;
          final proposal = await _proposal(h, operation, 'not-applied');
          // A valid unchanged acknowledgement and independent unchanged readback
          // cause the core's typed notApplied + mutationSent:true result.
          final outcome = await h.approve(proposal);
          await _expectResult(
            h,
            'not-applied',
            outcome,
            state: AiJournalState.writeUncertain,
            reason: 'writeUncertain',
            mutations: 1,
          );
          expect(h.server.mutations, 1);
          expect(h.server.revision, mr6b3Revision);
          _expectWriteCount(h, 1);
          _expectIsolated(h, outcome);
          await _expectFailStop(h);
        },
      );
    }

    test(
      'dates writeUncertain + mutationSent:true never becomes succeeded',
      () async {
        final h = await _harness();
        final proposal = await _proposal(
          h,
          'updateWorkItemDates',
          'dates-uncertain',
        );
        h.server.onRequest = (name, mutation, request, payload) =>
            mutation ? jsonResponse({'data': <String, Object?>{}}) : null;
        final outcome = await h.approve(proposal);
        await _expectResult(
          h,
          'dates-uncertain',
          outcome,
          state: AiJournalState.writeUncertain,
          reason: 'writeUncertain',
          mutations: 1,
        );
        expect(h.server.mutations, 1);
        _expectIsolated(h, outcome);
        await _expectFailStop(h);
      },
    );

    // State represents ordinary return/exception families; dates, health and
    // status cover all three typed failure/result families. Assignees, incident,
    // reaction, notifications and deletion cover the remaining readback shapes.
    for (final operation in [
      'updateWorkItemState',
      'updateWorkItemDates',
      'updateWorkItemHealthStatus',
      'updateWorkItemStatus',
      'updateWorkItemAssignees',
      'setIncidentStatus',
      'setWorkItemActivityNoteReaction',
      'setWorkItemNotifications',
      'deleteWorkItemActivityNote',
    ]) {
      for (final cancelled in [false, true]) {
        test(
          '$operation successful mutation then ${cancelled ? 'cancelled' : '401'} readback is uncertain',
          () async {
            final h = await _harness();
            final proposal = await _proposal(h, operation, 'readback');
            var failures = 0;
            h.server.onRequest = (name, mutation, request, payload) {
              if (!mutation && h.server.mutations > 0) {
                failures++;
                if (cancelled) {
                  throw DioException(
                    requestOptions: request,
                    type: DioExceptionType.cancel,
                  );
                }
                return jsonResponse({
                  'message': 'readback unauthorized',
                }, status: 401);
              }
              return null;
            };
            final outcome = await h.approve(proposal);
            await _expectResult(
              h,
              'readback',
              outcome,
              state: AiJournalState.writeUncertain,
              reason: 'writeUncertain',
              mutations: 1,
            );
            expect(failures, 1);
            expect(h.server.mutations, 1);
            expect(h.server.refreshAdapter.requests, isEmpty);
            _expectIsolated(h, outcome);
            await _expectFailStop(h);
          },
        );
      }
    }

    test(
      'incident revision drift proves expectedUpdatedAt reached the core',
      () async {
        final h = await _harness();
        final proposal = await _proposal(
          h,
          'setIncidentStatus',
          'incident-fence',
        );
        h.server.onRequest = (name, mutation, request, payload) {
          if (name == 'MobileIncidentStatus' && h.server.reads[name] == 3) {
            final project = (payload['data']! as Map)['project']! as Map;
            final nodes = ((project['issues']! as Map)['nodes']! as List);
            (nodes.single as Map)['updatedAt'] = mr6b3BumpedRevision;
          }
          return null;
        };
        final outcome = await h.approve(proposal);
        await _expectResult(
          h,
          'incident-fence',
          outcome,
          state: AiJournalState.notExecuted,
          reason: 'incidentConflict',
          mutations: 0,
        );
        expect(h.server.reads['MobileIncidentStatus'], 3);
        expect(h.server.mutations, 0);
        _expectUnlocked(h, outcome);
        await _expectFailStop(h);
      },
    );

    for (final truncated in [false, true]) {
      test(
        'snooze acknowledgement succeeds with ${truncated ? 'truncated' : 'missing'} lookup',
        () async {
          final h = await _harness();
          var lookups = 0;
          h.server.onRequest = (name, mutation, request, payload) {
            if (name == 'MobileSnoozedTodos') {
              lookups++;
              final user = (payload['data']! as Map)['currentUser']! as Map;
              final todos = user['todos']! as Map;
              (todos['pageInfo']! as Map)['hasNextPage'] = truncated;
            }
            return null;
          };
          final proposal = await _proposal(h, 'snoozeTodo', 'snooze-ack');
          final outcome = await h.approve(proposal);
          await _expectResult(
            h,
            'snooze-ack',
            outcome,
            state: AiJournalState.succeeded,
            reason: 'succeeded',
            mutations: 1,
          );
          expect(
            lookups,
            0,
          ); // The write port does not depend on the inbox list.
          final acknowledgement = h.server.adapter.requests.singleWhere(
            _isMutation,
          );
          expect(
            ((acknowledgement.data as Map)['variables'] as Map)['until'],
            mr6b3SnoozeUntil,
          );
          final lookup = await h.server.api.snoozedTodos();
          expect(lookup.items, isEmpty);
          expect(lookup.truncated, truncated);
          expect(lookups, 1);
          expect(h.coordinator.outcomeFor('snooze-ack'), same(outcome));
          expect(outcome.readbackConfirmed, isFalse);
          expect(h.server.mutations, 1);
          _expectUnlocked(h, outcome);
        },
      );
    }
  });

  group('rows 25 and 29 durable flush failures', () {
    for (final operation in _operations) {
      test('$operation beforeMutation flush failure sends nothing', () async {
        final h = await _harness();
        await h.seedConfirmMark();
        final proposal = await _proposal(h, operation, 'hook-failure');
        h.files.failWriteNumber = h.files.writeCount + 2;
        final outcome = await h.approve(proposal);
        // The failed flush has unknown durability. Production deliberately
        // keeps prepared and fences the journal; it does not claim rollback.
        await _expectResult(
          h,
          'hook-failure',
          outcome,
          state: AiJournalState.notExecuted,
          reason: 'journalUnavailable',
          mutations: 0,
          journalState: AiJournalState.prepared,
        );
        expect(h.server.mutations, 0);
        _expectWriteCount(h, 0);
        _expectMark(h, true);
        await _expectFailStop(h);
        final recovered = await h.recoverInNewProcess();
        expect(
          _journalEntry(recovered, proposal.executionId).state,
          AiJournalState.notExecuted,
        );
        expect(
          recovered.conversationWriteCount(mr6b3Account, _conversation),
          0,
        );
      });
    }

    test(
      'persisted dispatching rollback flush failure retains its count and isolation',
      () async {
        final h = await _harness();
        await h.seedConfirmMark();
        final proposal = await _proposal(
          h,
          'updateWorkItemState',
          'rollback-failure',
        );
        final entered = h.files.armBarrier(
          writesBeforeBarrier: 1,
          afterPersist: true,
        );
        final pending = h.approve(proposal);
        await entered;
        await _expectDurable(
          h,
          proposal.executionId,
          AiJournalState.dispatching,
        );
        h.policy.clientMayStart = false;
        h.files.failWriteNumber = h.files.writeCount + 1;
        h.files.releaseBarrier();
        final outcome = await pending;
        await _expectResult(
          h,
          'rollback-failure',
          outcome,
          state: AiJournalState.writeUncertain,
          reason: 'journalUnavailable',
          mutations: 0,
          journalState: AiJournalState.dispatching,
        );
        expect(h.server.mutations, 0);
        _expectWriteCount(h, 1);
        _expectMark(h, false);
        _expectIsolated(h, outcome);
        await _expectFailStop(h);
        final recovered = await h.recoverInNewProcess();
        expect(
          _journalEntry(recovered, proposal.executionId).state,
          AiJournalState.writeUncertain,
        );
        expect(recovered.isolated(mr6b3Account, {mr6b3WriteKey}), isTrue);
        expect(
          recovered.conversationWriteCount(mr6b3Account, _conversation),
          1,
        );
        await _expectDurable(
          h,
          proposal.executionId,
          AiJournalState.writeUncertain,
        );
      },
    );

    for (final scenario in _preflights) {
      test(
        '${scenario.operation} sent then terminal flush failure recovers uncertain',
        () async {
          final h = await _harness();
          final proposal = await _proposal(
            h,
            scenario.operation,
            'terminal-failure',
          );
          h.files.failWriteNumber = h.files.writeCount + 3;
          final outcome = await h.approve(proposal);
          await _expectResult(
            h,
            'terminal-failure',
            outcome,
            state: AiJournalState.writeUncertain,
            reason: 'journalUnavailable',
            mutations: 1,
            durableState: AiJournalState.dispatching,
          );
          expect(h.server.mutations, 1);
          _expectWriteCount(h, 1);
          _expectIsolated(h, outcome);
          await _expectFailStop(h);
          final recovered = await h.recoverInNewProcess();
          final entry = _journalEntry(recovered, proposal.executionId);
          expect(entry.state, AiJournalState.writeUncertain);
          expect(recovered.isolated(mr6b3Account, entry.writeKeys), isTrue);
          expect(
            recovered.conversationWriteCount(mr6b3Account, _conversation),
            1,
          );
          await _expectDurable(
            h,
            proposal.executionId,
            AiJournalState.writeUncertain,
          );
          expect(h.server.mutations, 1);
          expect(h.coordinator.outcomeFor('terminal-failure'), same(outcome));
        },
      );
    }
  });

  group('row 29 flush barrier invalidations', () {
    final guards =
        <({String name, String reason, void Function(Mr6b3ApiHarness) flip})>[
          (
            name: 'policy',
            reason: 'policyDenied',
            flip: (h) => h.policy.level = AiAutonomyLevel.readOnly,
          ),
          (
            name: 'consent',
            reason: 'policyDenied',
            flip: (h) => h.policy.consentValid = false,
          ),
          (name: 'stop', reason: 'stopped', flip: (h) => h.coordinator.stop()),
          (
            name: 'generation',
            reason: 'settingsChanged',
            flip: (h) => h.sessionGeneration++,
          ),
        ];
    for (final scenario in _preflights) {
      for (final guard in guards) {
        test(
          '${scenario.operation} persisted flush then ${guard.name} refunds atomically',
          () async {
            final h = await _harness();
            await h.seedConfirmMark();
            final proposal = await _proposal(h, scenario.operation, 'barrier');
            final writes = h.files.writeCount;
            final entered = h.files.armBarrier(
              writesBeforeBarrier: 1,
              afterPersist: true,
            );
            final pending = h.approve(proposal);
            await entered;
            final durable = await _expectDurable(
              h,
              proposal.executionId,
              AiJournalState.dispatching,
            );
            expect((durable['consumedMarks']! as List), isNotEmpty);
            expect(h.server.mutations, 0);
            guard.flip(h);
            h.files.releaseBarrier();
            final outcome = await pending;
            await _expectResult(
              h,
              'barrier',
              outcome,
              state: AiJournalState.notExecuted,
              reason: guard.reason,
              mutations: 0,
            );
            expect(h.server.mutations, 0);
            expect(h.files.writeCount - writes, 3);
            _expectWriteCount(h, 0);
            _expectMark(h, true);
            _expectUnlocked(h, outcome);
            final disk = await h.readDurableJournal();
            expect((disk['marks']! as List), isNotEmpty);
            final count = (disk['counts']! as Map)[_conversation] as List?;
            expect(count == null ? 0 : count.first, 0);
            await _expectFailStop(h);
          },
        );
      }
    }

    for (final guard in [
      'peer 429',
      'client closed',
      'removing',
      'background',
      'cancel removal',
      'tombstone',
    ]) {
      test('state persisted flush then $guard is notExecuted', () async {
        final h = await _harness();
        await h.seedConfirmMark();
        final proposal = await _proposal(
          h,
          'updateWorkItemState',
          'sync-guard',
        );
        final entered = h.files.armBarrier(
          writesBeforeBarrier: 1,
          afterPersist: true,
        );
        final pending = h.approve(proposal);
        await entered;
        await _expectDurable(
          h,
          proposal.executionId,
          AiJournalState.dispatching,
        );
        AiRemovalJob? removal;
        final String reason;
        switch (guard) {
          case 'peer 429':
            h.server.onRequest = (name, mutation, request, payload) =>
                jsonResponse(
                  {'message': 'peer cooldown'},
                  status: 429,
                  headers: {
                    'retry-after': ['60'],
                  },
                );
            await expectLater(
              h.server.api.record(['projects', '9']),
              throwsA(
                isA<ApiFailure>().having(
                  (value) => value.kind,
                  'kind',
                  FailureKind.rateLimited,
                ),
              ),
            );
            expect(h.server.api.mayStartRequest, isFalse);
            reason = 'clientUnavailable';
          case 'client closed':
            h.server.api.close();
            reason = 'clientUnavailable';
          case 'removing':
            removal = h.journal.beginRemoval(mr6b3Account);
            reason = 'accountBlocked';
          case 'background':
            h.appInForeground = false;
            reason = 'backgrounded';
          case 'cancel removal':
            removal = h.journal.beginRemoval(mr6b3Account)..cancelFinal();
            expect(h.journal.removalHeld(mr6b3Account), isFalse);
            reason = 'proposalInvalidated';
          case 'tombstone':
            h.journal.noteTombstoneSet(mr6b3Account);
            reason = 'accountBlocked';
          default:
            throw StateError(guard);
        }
        final requests = h.server.adapter.requests.length;
        h.files.releaseBarrier();
        final outcome = await pending;
        await _expectResult(
          h,
          'sync-guard',
          outcome,
          state: AiJournalState.notExecuted,
          reason: reason,
          mutations: 0,
        );
        expect(h.server.adapter.requests, hasLength(requests));
        expect(h.server.mutations, 0);
        _expectWriteCount(h, 0);
        _expectMark(h, true);
        removal?.release(removal.token);
        h.journal.noteTombstoneCleared(mr6b3Account);
        _expectUnlocked(h, outcome);
        await _expectFailStop(h);
      });
    }

    test(
      'cancelled removal during prepared flush never reaches the hook',
      () async {
        final h = await _harness();
        await h.seedConfirmMark();
        final proposal = await _proposal(
          h,
          'updateWorkItemState',
          'early-epoch',
        );
        final entered = h.files.armBarrier(afterPersist: true);
        final pending = h.approve(proposal);
        await entered;
        await _expectDurable(h, proposal.executionId, AiJournalState.prepared);
        h.journal.beginRemoval(mr6b3Account).cancelFinal();
        final requests = h.server.adapter.requests.length;
        h.files.releaseBarrier();
        final outcome = await pending;
        await _expectResult(
          h,
          'early-epoch',
          outcome,
          state: AiJournalState.notExecuted,
          reason: 'proposalInvalidated',
          mutations: 0,
        );
        expect(h.server.adapter.requests, hasLength(requests));
        expect(h.server.mutations, 0);
        _expectWriteCount(h, 0);
        _expectMark(h, true);
        _expectUnlocked(h, outcome);
        await _expectFailStop(h);
      },
    );
  });

  test(
    'row 29 call-order double sends before the sync gate microtask',
    () async {
      final double = _CallOrderPort();
      final h = await _harness(portFactory: (_) => double);
      final proposal = await _proposal(h, 'updateWorkItemState', 'order');
      final entered = h.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = h.approve(proposal);
      await entered;
      expect(double.events, ['hook']);
      await _expectDurable(h, proposal.executionId, AiJournalState.dispatching);
      h.files.releaseBarrier();
      final outcome = await pending;
      await _expectResult(
        h,
        'order',
        outcome,
        state: AiJournalState.succeeded,
        reason: 'succeeded',
        mutations: 1,
        readback: true,
      );
      expect(double.events, [
        'hook',
        'flushed',
        'gate',
        'mutation-call',
        'microtask',
      ]);
      expect(double.sends, 1);
      expect(h.server.mutations, 0); // This single, explicit protocol double.
    },
  );

  test('row 29 real family methods have no await between gate and send', () {
    const methods = <(String, String)>[
      ('work_item_state_api.dart', 'updateWorkItemState'),
      ('work_item_status_api.dart', 'updateWorkItemStatus'),
      ('work_item_dates_api.dart', 'updateWorkItemDates'),
      ('work_item_health_api.dart', 'updateWorkItemHealthStatus'),
      ('work_item_assignee_api.dart', 'updateWorkItemAssignees'),
      ('work_item_milestone_api.dart', 'updateWorkItemMilestone'),
      ('work_item_weight_api.dart', 'updateWorkItemWeight'),
      ('work_item_notifications_api.dart', 'setWorkItemNotifications'),
      ('work_item_note_reactions_api.dart', 'setWorkItemActivityNoteReaction'),
      ('work_item_note_delete_api.dart', 'deleteWorkItemActivityNote'),
      ('work_item_activity_api.dart', '_createWorkItemActivityNote'),
      ('incident_api.dart', 'setIncidentStatus'),
      ('todo_snooze_api.dart', 'snoozeTodo'),
      ('todo_snooze_api.dart', 'unsnoozeTodo'),
    ];
    for (final (file, method) in methods) {
      final source = File('lib/core/$file').readAsStringSync();
      final declaration = RegExp(
        'Future<[^\\n]+>\\s+${RegExp.escape(method)}\\(',
      ).firstMatch(source);
      expect(declaration, isNotNull, reason: method);
      final end = source.indexOf('\n  Future<', declaration!.end);
      final body = source.substring(
        declaration.start,
        end < 0 ? source.length : end,
      );
      final hook = body.indexOf('await beforeMutation');
      final gate = body.indexOf('mayStart', hook + 1);
      final send = body.indexOf('_send(', gate);
      expect(hook, isNonNegative, reason: method);
      expect(gate, greaterThan(hook), reason: method);
      expect(send, greaterThan(gate), reason: method);
      expect(
        body.substring(body.indexOf(';', hook) + 1, gate),
        isNot(contains('await ')),
        reason: method,
      );
      expect(
        body.substring(gate, send).replaceFirst(RegExp(r'await\s*$'), ''),
        isNot(contains('await ')),
        reason: method,
      );
    }
  });
}

Future<Mr6b3ApiHarness> _harness({
  port.AiGitLabWritePort Function(port.GitLabAiWritePort)? portFactory,
}) async {
  final h = await Mr6b3ApiHarness.create(
    oauth: false,
    portFactory: portFactory,
  );
  addTearDown(h.dispose);
  return h;
}

Future<AiWriteProposal> _proposal(
  Mr6b3ApiHarness h,
  String operation,
  String id, {
  Map<String, Object?> arguments = const {},
}) async {
  final proposal = await h.propose(operation, id: id, arguments: arguments);
  expect(
    proposal,
    isNotNull,
    reason: '$operation ${h.coordinator.outcomeFor(id)?.reasonCode}',
  );
  return proposal!;
}

AiJournalEntry _journalEntry(AiWriteJournal journal, String execution) =>
    journal
        .entries(mr6b3Account)
        .singleWhere((entry) => entry.executionId == execution);

AiJournalEntry _entry(Mr6b3ApiHarness h, String execution) =>
    _journalEntry(h.journal, execution);

Future<Map<String, Object?>> _expectDurable(
  Mr6b3ApiHarness h,
  String execution,
  AiJournalState state,
) async {
  final disk = await h.readDurableJournal();
  final entry = (disk['entries']! as List)
      .cast<Map<String, Object?>>()
      .singleWhere((entry) => entry['execution'] == execution);
  expect(entry['state'], state.name);
  return entry;
}

Future<void> _expectResult(
  Mr6b3ApiHarness h,
  String id,
  AiWriteOutcome outcome, {
  required AiJournalState state,
  required String reason,
  required int mutations,
  AiJournalState? journalState,
  AiJournalState? durableState,
  bool noChange = false,
  bool readback = false,
}) async {
  expect(outcome.state, state, reason: '$id ${outcome.reasonCode}');
  expect(outcome.reasonCode, reason);
  expect(outcome.mutationCount, mutations);
  expect(outcome.noChange, noChange);
  expect(outcome.readbackConfirmed, readback);
  expect(h.coordinator.outcomeFor(id), same(outcome));
  final expected = journalState ?? state;
  expect(_entry(h, outcome.executionId!).state, expected);
  await _expectDurable(h, outcome.executionId!, durableState ?? expected);
}

void _expectWriteCount(Mr6b3ApiHarness h, int count) => expect(
  h.journal.conversationWriteCount(mr6b3Account, _conversation),
  count,
);

void _expectMark(Mr6b3ApiHarness h, bool marked) => expect(
  h.journal.requiresConfirmation(mr6b3Account, {mr6b3WriteKey}),
  marked,
);

void _expectUnlocked(Mr6b3ApiHarness h, AiWriteOutcome outcome) => expect(
  h.journal.isolated(mr6b3Account, _entry(h, outcome.executionId!).writeKeys),
  isFalse,
);

void _expectIsolated(Mr6b3ApiHarness h, AiWriteOutcome outcome) => expect(
  h.journal.isolated(mr6b3Account, _entry(h, outcome.executionId!).writeKeys),
  isTrue,
);

Future<void> _expectFailStop(Mr6b3ApiHarness h) async {
  final requests = h.server.adapter.requests.length;
  final mutations = h.server.mutations;
  final entries = h.journal.entries(mr6b3Account).length;
  expect(await h.propose('updateWorkItemState', id: 'later'), isNull);
  final later = h.coordinator.outcomeFor('later')!;
  expect(later.state, AiJournalState.notExecuted);
  expect(later.reasonCode, 'previousWriteIncomplete');
  expect(later.mutationCount, 0);
  expect(h.server.adapter.requests, hasLength(requests));
  expect(h.server.mutations, mutations);
  expect(h.journal.entries(mr6b3Account), hasLength(entries));
}

bool _isMutation(RequestOptions request) =>
    request.data is Map &&
    ((request.data as Map)['query'] as String).startsWith('mutation ');

void _configureNoop(Mr6b3ApiServer server, String operation) {
  switch (operation) {
    case 'updateWorkItemState':
      server.workItemState = 'CLOSED';
    case 'updateWorkItemStatus':
      server.statusId = mr6b3StatusDoing;
    case 'updateWorkItemDates':
      server.startDate = '2026-10-06';
    case 'updateWorkItemHealthStatus':
      server.healthStatus = 'atRisk';
    case 'updateWorkItemAssignees':
      server.users = [11, 21, 22, 23, 24];
    case 'updateWorkItemMilestone':
      server.milestoneId = 'gid://gitlab/Milestone/6';
    case 'updateWorkItemWeight':
      server.weight = 4;
    case 'setWorkItemNotifications':
      server.notificationsOn = true;
    case 'setWorkItemActivityNoteReaction':
      server.reactionAwarded = true;
    case 'setIncidentStatus':
      server.incidentStatus = 'ACKNOWLEDGED';
    default:
      throw ArgumentError.value(operation);
  }
}

final class _RetainedTicketPort implements port.AiGitLabWritePort {
  _RetainedTicketPort(this.real);
  final port.GitLabAiWritePort real;
  port.AiWritePrepared? ticket;

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) =>
      real.prepare(request);

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) {
    ticket = prepared;
    return real.commit(prepared, mayStart: mayStart);
  }
}

final class _CallOrderPort implements port.AiGitLabWritePort {
  final events = <String>[];
  int sends = 0;

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async =>
      port.AiWritePrepared.graph(
        request: request,
        owner: this,
        releaseName: '#3',
        writeKeys: {mr6b3WriteKey},
        bindingDigest: 'call-order-only',
        mutation: (GraphHooks hooks) async {
          events.add('hook');
          await hooks.beforeMutation();
          events.add('flushed');
          if (!hooks.mayStart()) throw const port.AiWriteRefused('notAccepted');
          _mutationCall();
          return const GraphWriteResult(
            mutationSent: true,
            acknowledged: true,
            readbackVerified: true,
          );
        },
      );

  void _mutationCall() {
    sends++;
    events.add('mutation-call');
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => prepared.commitGraph(
    mayStart: () {
      events.add('gate');
      final accepted = mayStart();
      scheduleMicrotask(() => events.add('microtask'));
      return accepted;
    },
  );
}
