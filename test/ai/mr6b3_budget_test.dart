import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

/// docs/plans/ai-writes-plan-v6.md §4.4: 40 GitLab HTTP requests are the shared
/// per-send budget. The allowance through readback is reserved when the
/// proposal is created; a reservation that does not fit produces no proposal.
///
/// §15 row 19: 預算：mutation 加 readback 在 39／40／41 次 HTTP 的邊界；核准後的新鮮讀取與合併前檢查在提議時已保留，保留不到就不產生提議；三段對話共用帳號 60 分鐘上限；對話計數跨換段與重啟；大量零寫入的對話不建立計數項；計數項 2,000 列與 ciphertext 1 MiB 的邊界，飽和時 mutation 為 0；`prepared` 因隔離或預算不足改 `notExecuted` 時不消耗計數；紀錄關閉時計數只在本程序內有效；批次上限。

void main() {
  const independentlyCounted = <String, ({int logicalReads, int mutations})>{
    // Freshness, user, work item and write access, twice, plus preflight and
    // readback. A comment does not page activity.
    'createWorkItemActivityComment': (logicalReads: 10, mutations: 1),
    // The same reads, with a two-page locator on each prepare.
    'createWorkItemActivityReply': (logicalReads: 14, mutations: 1),
    // Freshness, user, work item, two activity pages and edit access, twice,
    // plus one more edit-access preflight and the delete readback.
    'deleteWorkItemActivityNote': (logicalReads: 14, mutations: 1),
    // Freshness, user, work item, dates base and dates probe, twice, plus
    // preflight and readback of both date documents.
    'updateWorkItemDates': (logicalReads: 14, mutations: 1),
    // Freshness, actor, item, opening and four new-name searches, twice,
    // plus the assignee preflight and readback. Five usernames, four new.
    'updateWorkItemAssignees': (logicalReads: 18, mutations: 1),
    // Freshness, user, item and health, twice, plus preflight and readback.
    'updateWorkItemHealthStatus': (logicalReads: 10, mutations: 1),
    'setWorkItemNotifications': (logicalReads: 10, mutations: 1),
    'setIncidentStatus': (logicalReads: 10, mutations: 1),
    // Milestone adds one choices page inside each prepare.
    'updateWorkItemMilestone': (logicalReads: 12, mutations: 1),
    // Two activity pages on each prepare, and two reaction pages on prepare,
    // re-prepare, preflight and readback.
    'setWorkItemActivityNoteReaction': (logicalReads: 18, mutations: 1),
    'updateWorkItemStatus': (logicalReads: 10, mutations: 1),
    // No project freshness. User plus four ownership pages, twice.
    'snoozeTodo': (logicalReads: 10, mutations: 1),
    'unsnoozeTodo': (logicalReads: 10, mutations: 1),
    'updateWorkItemState': (logicalReads: 10, mutations: 1),
    'updateWorkItemWeight': (logicalReads: 10, mutations: 1),
  };

  test('fifteen HTTP caps match the counted family scenarios', () {
    expect(independentlyCounted, hasLength(15));
    for (final entry in independentlyCounted.entries) {
      final counted = 2 * entry.value.logicalReads + entry.value.mutations;
      expect(
        productionAiLedger.find(entry.key)?.httpCap,
        counted,
        reason: entry.key,
      );
      expect(aiWriteRequestAllowance(entry.key), counted, reason: entry.key);
      expect(
        aiWriteRequestAllowance(entry.key, oauthReplay: false),
        entry.value.logicalReads + entry.value.mutations,
        reason: entry.key,
      );
    }
  });

  for (final entry in independentlyCounted.entries) {
    test(
      '${entry.key} measured worst case stays inside its counted cap',
      () async {
        await _drive(entry.key, entry.value, oauth: true);
        await _drive(entry.key, entry.value, oauth: false);
      },
    );
  }

  test('state OAuth replay keeps refresh off the API allowance', () async {
    final harness = await Mr6b3ApiHarness.create(oauth: true);
    addTearDown(harness.dispose);
    final proposal = await harness.propose('updateWorkItemState');
    expect(proposal, isNotNull);
    expect(harness.budget.gitLabRequests, 21);
    final outcome = await harness.approve(proposal!);
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(harness.server.logicalReads, 10);
    expect(harness.server.mutations, 1);
    expect(harness.server.refreshes, 10);
    expect(harness.server.adapter.requests, hasLength(21));
    expect(harness.server.refreshAdapter.requests, hasLength(10));
    expect(harness.budget.gitLabRequests, 21);
  });

  test('proposal reservation is not charged again at approval', () async {
    final harness = await Mr6b3ApiHarness.create(oauth: true);
    addTearDown(harness.dispose);
    final proposal = await harness.propose('updateWorkItemState');
    expect(proposal, isNotNull);
    final reserved = harness.budget.gitLabRequests;
    expect(reserved, 21);
    final outcome = await harness.approve(proposal!);
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(harness.budget.gitLabRequests, reserved);
    expect(harness.server.adapter.requests.length, lessThanOrEqualTo(reserved));
  });

  for (final boundary in [39, 40, 41]) {
    for (final operation in [
      'updateWorkItemAssignees',
      'setWorkItemActivityNoteReaction',
    ]) {
      test(
        '$operation reservation total $boundary on the 40-request budget',
        () async {
          const cap = 37;
          final harness = await Mr6b3ApiHarness.create(maxGitLabRequests: 40);
          addTearDown(harness.dispose);
          expect(
            harness.budget.reserve(requests: boundary - cap, search: false),
            isNull,
          );
          final before = harness.server.adapter.requests.length;
          final proposal = await harness.propose(
            operation,
            id: 'boundary-$operation-$boundary',
          );
          if (boundary <= 40) {
            expect(proposal, isNotNull);
            expect(harness.budget.gitLabRequests, boundary);
            final outcome = await harness.approve(proposal!);
            expect(
              outcome.state,
              AiJournalState.succeeded,
              reason: outcome.reasonCode,
            );
            expect(harness.budget.gitLabRequests, boundary);
            expect(harness.server.mutations, 1);
            expect(
              harness.server.adapter.requests.length,
              lessThanOrEqualTo(before + cap),
            );
          } else {
            expect(proposal, isNull);
            expect(
              harness.coordinator
                  .outcomeFor('boundary-$operation-$boundary')
                  ?.reasonCode,
              'httpBudgetExceeded',
            );
            expect(harness.server.adapter.requests, hasLength(before));
            expect(harness.server.mutations, 0);
          }
        },
      );
    }
  }

  // Unlike the success drives above, these challenge every logical read,
  // including candidate lookup and the in-method target-epoch fence.
  for (final scenario in <({String operation, String reason, int reads})>[
    (
      operation: 'updateWorkItemAssignees',
      reason: 'assigneeConflict',
      reads: 5,
    ),
    (operation: 'updateWorkItemStatus', reason: 'statusNotStarted', reads: 9),
    (operation: 'updateWorkItemWeight', reason: 'weightConflict', reads: 9),
  ]) {
    test(
      '${scenario.operation} every-read OAuth replay fails closed',
      () async {
        final harness = await Mr6b3ApiHarness.create(challengeEveryRead: true);
        addTearDown(harness.dispose);
        final callId = 'all-replays-${scenario.operation}';
        final proposal = await harness.propose(scenario.operation, id: callId);
        if (scenario.operation == 'updateWorkItemAssignees') {
          // The first new-name lookup refreshes the bound opening target out of
          // its epoch, so this operation is refused before a proposal exists.
          expect(proposal, isNull);
          expect(harness.journal.entries(mr6b3Account), isEmpty);
        } else {
          expect(proposal, isNotNull);
          final outcome = await harness.approve(proposal!);
          expect(outcome.state, AiJournalState.notExecuted);
          expect(outcome.reasonCode, scenario.reason);
          expect(outcome.mutationCount, 0);
          expect(harness.coordinator.outcomeFor(callId), same(outcome));
          expect(
            harness.journal.entries(mr6b3Account).single.state,
            AiJournalState.notExecuted,
          );
        }
        final recorded = harness.coordinator.outcomeFor(callId)!;
        expect(recorded.state, AiJournalState.notExecuted);
        expect(recorded.reasonCode, scenario.reason);
        expect(recorded.mutationCount, 0);
        _expectEveryReadReplayed(harness, scenario.operation, scenario.reads);
      },
    );
  }

  test('assignee every-read replay also refuses the final preflight', () async {
    final harness = await Mr6b3ApiHarness.create(challengeEveryRead: true);
    addTearDown(harness.dispose);
    const callId = 'all-replays-assignee-clear';
    final proposal = await harness.propose(
      'updateWorkItemAssignees',
      id: callId,
      arguments: {'assigneeUsernames': <String>[]},
    );
    expect(proposal, isNotNull);
    final outcome = await harness.approve(proposal!);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.reasonCode, 'assigneeConflict');
    expect(outcome.mutationCount, 0);
    expect(harness.coordinator.outcomeFor(callId), same(outcome));
    expect(
      harness.journal.entries(mr6b3Account).single.state,
      AiJournalState.notExecuted,
    );
    _expectEveryReadReplayed(harness, 'updateWorkItemAssignees', 9);
  });

  for (final operation in [
    'updateWorkItemAssignees',
    'updateWorkItemStatus',
    'updateWorkItemWeight',
  ]) {
    test('$operation permits OAuth replay of the post-mutation read', () async {
      final harness = await Mr6b3ApiHarness.create();
      addTearDown(harness.dispose);
      int? refreshesAtMutation;
      harness.server.onRequest = (name, mutation, request, payload) {
        if (mutation) refreshesAtMutation = harness.server.refreshes;
        return null;
      };
      final callId = 'post-mutation-replay-$operation';
      final proposal = (await harness.propose(operation, id: callId))!;
      final outcome = await harness.approve(proposal);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.reasonCode, 'succeeded');
      expect(outcome.mutationCount, 1);
      expect(outcome.readbackConfirmed, isTrue);
      expect(harness.coordinator.outcomeFor(callId), same(outcome));
      expect(
        harness.journal.entries(mr6b3Account).single.state,
        AiJournalState.succeeded,
      );
      expect(refreshesAtMutation, isNotNull);
      expect(harness.server.refreshes, refreshesAtMutation! + 1);
      expect(harness.server.mutations, 1);
      expect(
        harness.server.refreshAdapter.requests,
        hasLength(harness.server.refreshes),
      );
      expect(
        harness.server.adapter.requests,
        hasLength(harness.server.logicalReads + 1 + harness.server.refreshes),
      );
      expect(
        harness.server.adapter.requests.length,
        lessThanOrEqualTo(productionAiLedger.find(operation)!.httpCap),
      );
    });
  }
}

void _expectEveryReadReplayed(
  Mr6b3ApiHarness harness,
  String operation,
  int logicalReads,
) {
  expect(harness.server.mutations, 0);
  expect(harness.server.logicalReads, logicalReads);
  expect(harness.server.refreshes, logicalReads);
  expect(harness.server.refreshAdapter.requests, hasLength(logicalReads));
  expect(harness.server.adapter.requests, hasLength(2 * logicalReads));
  expect(
    harness.server.adapter.requests.where(
      (request) => request.uri.path.endsWith('/oauth/token'),
    ),
    isEmpty,
  );
  expect(
    harness.server.adapter.requests.length,
    lessThanOrEqualTo(productionAiLedger.find(operation)!.httpCap),
  );
}

/// Family success paths withhold these OAuth challenges. The counted cap in
/// [independentlyCounted] still includes them.
int _oauthSkips(String operation) => switch (operation) {
  'updateWorkItemAssignees' => 9,
  'updateWorkItemStatus' => 1,
  'updateWorkItemWeight' => 1,
  _ => 0,
};

Future<void> _drive(
  String operation,
  ({int logicalReads, int mutations}) counted, {
  required bool oauth,
}) async {
  final harness = await Mr6b3ApiHarness.create(oauth: oauth);
  addTearDown(harness.dispose);
  final callId = 'drive-$operation-${oauth ? 'oauth' : 'pat'}';
  final proposal = await harness.propose(operation, id: callId);
  expect(
    proposal,
    isNotNull,
    reason:
        '$operation ${harness.coordinator.outcomeFor(callId)?.reasonCode} '
        '${harness.server.reads}',
  );
  final outcome = await harness.approve(proposal!);
  final skips = oauth ? _oauthSkips(operation) : 0;
  expect(
    outcome.state,
    AiJournalState.succeeded,
    reason: '$operation ${outcome.reasonCode} ${harness.server.reads}',
  );
  expect(harness.server.logicalReads, counted.logicalReads, reason: operation);
  expect(harness.server.mutations, counted.mutations, reason: operation);
  expect(
    harness.server.refreshes,
    oauth ? counted.logicalReads - skips : 0,
    reason: operation,
  );
  expect(
    harness.server.adapter.requests,
    hasLength(
      harness.server.logicalReads +
          harness.server.mutations +
          harness.server.refreshes,
    ),
    reason: '$operation ${harness.server.reads}',
  );
  expect(
    harness.server.refreshAdapter.requests,
    hasLength(harness.server.refreshes),
    reason: operation,
  );
  final cap = productionAiLedger.find(operation)!.httpCap;
  expect(harness.budget.gitLabRequests, oauth ? cap : counted.logicalReads + 1);
  expect(
    harness.server.adapter.requests.length,
    lessThanOrEqualTo(cap),
    reason: operation,
  );
}
