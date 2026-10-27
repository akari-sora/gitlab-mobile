import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

/// docs/plans/ai-writes-plan-v6.md §4.4: 40 GitLab HTTP requests are the shared
/// per-send budget. The allowance through readback is reserved when the
/// proposal is created; a reservation that does not fit produces no proposal.
///
/// §15 coverage (test paths below are relative to test/ai):
/// Row 19 here: fifteen independently counted document distributions, PAT and
/// OAuth caps including mutation/readback, 39/40/41 HTTP boundaries, up-front
/// reservation/refusal and no second charge at approval.
/// Row 19 sub-items outside this file:
/// - Three conversations share the account's rolling 60-minute cap:
///   ai_write_journal_test.dart row 19; mr6b2_budget_test.dart REST/T4 drives.
/// - Conversation counters survive segment changes and restart:
///   ai_write_journal_test.dart row 19 conversation-cap test.
/// - Zero-write conversations create no counter; manual notExecuted/refund:
///   ai_write_journal_test.dart row 19 prepared/zero-write test. Cause-specific
///   prepared downgrade on isolation/budget refusal without a count: NOT_RUN
///   (mr6b3_boundary_test.dart instead covers flush/gate refunds).
/// - 2,000 counter rows / 1 MiB ciphertext boundaries: ai_write_journal_test.dart
///   row 19 tests prove reservation/prepare refusal. End-to-end zero mutations
///   at either saturation boundary: NOT_RUN.
/// - History disabled keeps counters process-local: ai_write_journal_test.dart
///   row 19 disabled-history test.
/// - Run and batch limits: ai_write_journal_test.dart row 19 8/3/20 test;
///   p6_suggestions_test.dart batch limit test.
/// Row 25 here also checks OAuth mutation-401 uncertainty without replay.
/// Row 25 sub-items outside this file:
/// - Final pre-read 5xx/transport, hook flush/gate refusal, noops and unchanged
///   snapshots, no lock/count/mark use, same-round continuation, date
///   notApplied without send/fail-stop, accepted typed failures/fail-stop,
///   peer-429 fast refusal, dispatching at adapter, PAT readback 401/cancel,
///   incident expectedUpdatedAt and snooze acknowledgement without inbox
///   readback: mr6b3_boundary_test.dart row 25 groups.
/// - Screen writes exclude AI on the same Work Item: mr6b3_status_port_test.dart,
///   mr6b3_dates_port_test.dart and mr6b3_health_port_test.dart registry tests.
/// - Status hook before onMutationSent(started): mr6b3_core_hooks_test.dart and
///   mr6b3_status_port_test.dart; exact AI callback-only assertion: NOT_RUN.
/// - Explicit assertion that all three typed failures bypass safeFailure:
///   NOT_RUN (family tests cover their outcomes and mutationSent instead).
/// - Labels/content/activity-edit noops: deferred MR6b-3t, NOT_RUN.
/// Row 29 sub-items outside this file:
/// - Policy/consent/stop/generation during flush; prepared vs dispatching vs
///   sent-terminal-flush failure and restart; atomic refund/mark restoration;
///   rollback flush failure; ticket reuse; no-await source order; peer 429,
///   closed client, removal, background and released-reservation tombstone:
///   mr6b3_boundary_test.dart row 29 groups (double proves hook propagation).
/// - Removal wait limit/final confirmation/cancel epoch and resumed flush:
///   packet9_removal_test.dart row 29; ai_write_journal_test.dart removal tests.
/// - Every §7.3 step 2-4.3 checkpoint at step 4.4: NOT_RUN beyond boundary
///   tests' prepared/dispatching barriers.
/// P15-B scenario rows live in the injection/isolation/races/matrix/guard/
/// binding files. Citing another file is a coverage pointer, not a claim that
/// this budget file executes it.

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

  test('snooze drive shares a future timestamp after June 2027', () async {
    final actualNow = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
      isUtc: true,
    );
    final afterTimeBomb = DateTime.utc(2028, 6, 2);
    final injectedNow = actualNow.isAfter(afterTimeBomb)
        ? actualNow
        : afterTimeBomb;
    await _drive(
      'snoozeTodo',
      independentlyCounted['snoozeTodo']!,
      oauth: false,
      now: injectedNow,
    );
  });

  test(
    'snooze retains caller-supplied future argument compatibility',
    () async {
      final harness = await Mr6b3ApiHarness.create(oauth: false);
      addTearDown(harness.dispose);
      final until = DateTime.parse(
        harness.snoozeUntil,
      ).add(const Duration(days: 1)).toIso8601String();
      final proposal = await harness.propose(
        'snoozeTodo',
        arguments: {'until': until},
      );
      expect(proposal, isNotNull);
      final outcome = await harness.approve(proposal!);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.mutationCount, 1);
      expect(outcome.readbackConfirmed, isFalse);
      final mutation = harness.server.adapter.requests.last;
      expect(((mutation.data as Map)['variables'] as Map)['until'], until);
      expect(harness.server.mutations, 1);
    },
  );

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
              before + (operation == 'updateWorkItemAssignees' ? 28 : 37),
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
            expect(harness.budget.gitLabRequests, boundary - cap);
          }
        },
      );
    }
  }

  test(
    'OAuth mutation 401 refreshes credentials without replay within the cap',
    () async {
      final harness = await Mr6b3ApiHarness.create(oauth: true);
      addTearDown(harness.dispose);
      harness.server.applyMutations = false;
      var faults = 0;
      int? refreshesAtMutation;
      harness.server.onRequest = (name, mutation, request, payload) {
        if (mutation) {
          faults++;
          refreshesAtMutation = harness.server.refreshes;
          return jsonResponse({
            'message': 'synthetic mutation 401',
          }, status: 401);
        }
        return null;
      };
      final proposal = (await harness.propose('updateWorkItemState'))!;
      final outcome = await harness.approve(proposal);
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.reasonCode, 'writeUncertain');
      expect(outcome.mutationCount, 1);
      expect(outcome.readbackConfirmed, isFalse);
      expect(
        harness.journal.entries(mr6b3Account).single.state,
        AiJournalState.writeUncertain,
      );
      expect(faults, 1);
      expect(harness.server.mutations, 1);
      expect(harness.server.reads['MobileUpdateWorkItemState'], 1);
      // Two prepare sets of four reads and one final preflight; no readback.
      expect(harness.server.logicalReads, 9);
      expect(refreshesAtMutation, 9);
      // Core may refresh credentials after the refusal, but never replays a
      // mutation. That token request uses the separate refresh adapter.
      expect(harness.server.refreshes, refreshesAtMutation! + 1);
      expect(harness.server.refreshAdapter.requests, hasLength(10));
      expect(harness.server.adapter.requests, hasLength(2 * 9 + 1));
      expect(harness.budget.gitLabRequests, 21);
      expect(
        harness.server.adapter.requests.length,
        lessThanOrEqualTo(
          productionAiLedger.find('updateWorkItemState')!.httpCap,
        ),
      );
    },
  );

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
  DateTime? now,
}) async {
  final harness = await Mr6b3ApiHarness.create(oauth: oauth, now: now);
  addTearDown(harness.dispose);
  if (now != null) {
    expect(
      harness.snoozeUntil,
      now.toUtc().add(const Duration(days: 1)).toIso8601String(),
    );
  }
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
  if (operation == 'snoozeTodo') {
    final request = harness.server.adapter.requests.singleWhere(
      (request) =>
          request.method == 'POST' &&
          ((request.data as Map)['query'] as String).startsWith('mutation '),
    );
    expect(
      ((request.data as Map)['variables'] as Map)['until'],
      harness.snoozeUntil,
    );
  }
  final skips = oauth ? _oauthSkips(operation) : 0;
  expect(
    outcome.state,
    AiJournalState.succeeded,
    reason: '$operation ${outcome.reasonCode} ${harness.server.reads}',
  );
  expect(harness.server.logicalReads, counted.logicalReads, reason: operation);
  expect(harness.server.mutations, counted.mutations, reason: operation);
  // Count the documents from the scenario's prepare/re-prepare, preflight and
  // readback phases, independently of the measured trace and ledger cap.
  expect(harness.server.reads, _countedDocuments(operation), reason: operation);
  expect(
    harness.server.reactionStages,
    operation == 'setWorkItemActivityNoteReaction'
        ? [2, 2, 2, 2] // Three core stages, plus coordinator re-prepare.
        : isEmpty,
    reason: operation,
  );
  if (operation == 'updateWorkItemAssignees') {
    final searches = harness.server.adapter.requests
        .where(
          (request) =>
              request.method == 'POST' &&
              ((request.data as Map)['query'] as String).startsWith(
                'query MobileProjectAssigneeCandidates(',
              ),
        )
        .map(
          (request) => ((request.data as Map)['variables'] as Map)['search'],
        );
    expect(
      searches,
      unorderedEquals([
        for (var prepare = 0; prepare < 2; prepare++) ...[
          'alice',
          'bob',
          'carol',
          'dave',
        ],
      ]),
    );
    final mutation = harness.server.adapter.requests.singleWhere(
      (request) =>
          request.method == 'POST' &&
          ((request.data as Map)['query'] as String).startsWith('mutation '),
    );
    final input = ((mutation.data as Map)['variables'] as Map)['input'] as Map;
    expect(
      (input['assigneesWidget'] as Map)['assigneeIds'],
      unorderedEquals([
        for (final id in [11, 21, 22, 23, 24]) 'gid://gitlab/User/$id',
      ]),
    );
  }
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

Map<String, int> _countedDocuments(String operation) => {
  // Both prepares resolve the actor and, except todos, freshness and item.
  'user': 2,
  if (operation != 'snoozeTodo' && operation != 'unsnoozeTodo') ...{
    'freshness': 2,
    'MobileProjectWorkItem': 2,
  },
  ...switch (operation) {
    'createWorkItemActivityComment' => {
      'MobileWorkItemActivityWriteAccess': 3,
      'MobileWorkItemActivityNoteReadback': 1,
      'MobileCreateWorkItemActivityNote': 1,
    },
    'createWorkItemActivityReply' => {
      'MobileWorkItemActivity': 2 * 2, // Two locator pages per prepare.
      'MobileWorkItemActivityWriteAccess': 2,
      'MobileWorkItemActivityReplyPreflight': 1,
      'MobileWorkItemActivityNoteReadback': 1,
      'MobileCreateWorkItemActivityNote': 1,
    },
    'deleteWorkItemActivityNote' => {
      'MobileWorkItemActivity': 2 * 2,
      'MobileWorkItemActivityEditAccess': 3,
      'MobileWorkItemActivityDeleteReadback': 1,
      'MobileDestroyWorkItemActivityNote': 1,
    },
    'updateWorkItemDates' => {
      'MobileWorkItemDatesBase': 4,
      'MobileWorkItemDatesProbe': 4,
      'MobileSetWorkItemDatesEe': 1,
    },
    'updateWorkItemAssignees' => {
      'MobileWorkItemAssignees': 4,
      'MobileProjectAssigneeCandidates': 2 * 4,
      'MobileSetWorkItemAssignees': 1,
    },
    'updateWorkItemHealthStatus' => {
      'MobileWorkItemHealthEdit': 4,
      'MobileSetWorkItemHealthStatus': 1,
    },
    'setWorkItemNotifications' => {
      'MobileWorkItemNotifications': 4,
      'MobileSetWorkItemNotifications': 1,
    },
    'setIncidentStatus' => {
      'MobileIncidentStatus': 4,
      'MobileSetIncidentStatus': 1,
    },
    'updateWorkItemMilestone' => {
      'MobileWorkItemMilestone': 4,
      'MobileProjectWorkItemMilestones': 2,
      'MobileSetWorkItemMilestone': 1,
    },
    'setWorkItemActivityNoteReaction' => {
      'MobileWorkItemActivity': 2 * 2,
      'MobileWorkItemActivityReactionAccess': 4 * 2,
      'MobileAddWorkItemActivityNoteReaction': 1,
    },
    'updateWorkItemStatus' => {
      'MobileWorkItemStatus': 4,
      'MobileUpdateWorkItemStatus': 1,
    },
    'snoozeTodo' => {
      'MobilePendingTodosForSnooze': 2 * 4,
      'MobileTodoSnooze': 1,
    },
    'unsnoozeTodo' => {
      'MobileSnoozedTodosForUnsnooze': 2 * 4,
      'MobileTodoUnsnooze': 1,
    },
    'updateWorkItemState' => {
      'MobileWorkItemState': 4,
      'MobileUpdateWorkItemState': 1,
    },
    'updateWorkItemWeight' => {
      'MobileWorkItemWeight': 4,
      'MobileSetWorkItemWeight': 1,
    },
    _ => throw ArgumentError.value(operation, 'operation'),
  },
};
