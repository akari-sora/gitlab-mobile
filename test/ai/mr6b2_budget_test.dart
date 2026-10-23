import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b2_support.dart';

void main() {
  test('relevant HTTP caps match an independently counted packet table', () {
    const independentlyCounted = <String, ({int logicalReads, int mutations})>{
      // Each logical GET reserves one OAuth replay. Mutations never replay.
      'mergeRequest': (logicalReads: 18, mutations: 1),
      'cancelAutoMerge': (logicalReads: 9, mutations: 2),
      'deleteBranch': (logicalReads: 8, mutations: 1),
      'pipelineAction': (logicalReads: 7, mutations: 1),
      'jobAction': (logicalReads: 7, mutations: 1),
      'edit_file': (logicalReads: 17, mutations: 1),
      'applySuggestion': (logicalReads: 13, mutations: 1),
    };
    for (final entry in independentlyCounted.entries) {
      final countedCap = 2 * entry.value.logicalReads + entry.value.mutations;
      expect(
        productionAiLedger.find(entry.key)?.httpCap,
        countedCap,
        reason: '${entry.key} changed without updating the independent count',
      );
      expect(aiWriteRequestAllowance(entry.key), countedCap);
      expect(aiWriteRequestAllowance(entry.key, oauthReplay: false),
          entry.value.logicalReads + entry.value.mutations);
    }
  });

  for (final boundary in [39, 40, 41]) {
    test(
      'production 40-request budget handles merge reservation total $boundary',
      () async {
        final h = await Mr6b2Harness.create(maxGitLabRequests: 40);
        addTearDown(h.dispose);
        final mergeCap = productionAiLedger.find('mergeRequest')!.httpCap;
        expect(
          h.budget.reserve(requests: boundary - mergeCap, search: false),
          isNull,
        );
        final before = h.server.adapter.requests.length;
        final proposal = await h.propose(
          'mergeRequest',
          mr6b2Args('mergeRequest'),
          id: 'merge-$boundary',
        );
        if (boundary <= 40) {
          expect(proposal, isNotNull);
          expect(h.budget.gitLabRequests, boundary);
          final outcome = await h.approve(proposal!);
          expect(outcome.state, AiJournalState.succeeded);
          expect(outcome.mutationCount, 1);
          expect(h.server.mutationCount(), 1);
          expect(
            h.server.adapter.requests.any(
              (request) =>
                  request.method == 'GET' &&
                  request.uri.path.endsWith('/merge_requests/3'),
            ),
            isTrue,
            reason: 'the allowed merge must complete its independent readback',
          );
        } else {
          expect(proposal, isNull);
          expect(
            h.coordinator.outcomeFor('merge-$boundary')?.reasonCode,
            'httpBudgetExceeded',
          );
          expect(h.server.adapter.requests, hasLength(before));
          expect(h.server.mutationCount(), 0);
        }
      },
    );
  }

  test(
    'three conversations share the account rolling-hour write cap',
    () async {
      var journalClock = DateTime.utc(2026, 10, 23, 12);
      final root = Directory.systemTemp.createTempSync('mr6b2-budget-');
      final files = Mr6b2JournalFiles(root);
      final journal = AiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root,
        files: files,
        processId: 'mr6b2-budget',
      )..now = () => journalClock;
      await journal.recoverAfterAccountsLoaded([mr6b2Account]);
      await journal.ensureInitialized(mr6b2Account);
      final h = await Mr6b2Harness.create(
        root: root,
        files: files,
        journal: journal,
        maxGitLabRequests: 40,
      );
      addTearDown(h.dispose);
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final coordinators = [
        h.coordinator,
        h.newCoordinator(conversationId: 'conversation-b'),
        h.newCoordinator(conversationId: 'conversation-c'),
      ];
      for (
        var conversation = 0;
        conversation < coordinators.length;
        conversation++
      ) {
        final coordinator = coordinators[conversation];
        for (var write = 0; write < 20; write++) {
          h.budget = AiToolBudget(maxGitLabRequests: 40);
          coordinator.beginRun(
            '${write.isEven ? 'Star' : 'Unstar'} team/example-9.',
          );
          coordinator.beginTurn();
          final call = AiToolCall(
            id: 'c$conversation-w$write',
            name: 'setStar',
            arguments: {
              'projectId': 9,
              'starred': write.isEven,
              'reason': 'synthetic rolling-window count',
            },
          );
          final proposal = await coordinator.propose(call);
          expect(proposal, isNotNull, reason: call.id);
          final outcome = await coordinator.approve(proposal!);
          expect(outcome.state, AiJournalState.succeeded, reason: call.id);
          expect(outcome.mutationCount, 1, reason: call.id);
        }
      }
      expect(h.server.mutationCount(), 60);
      expect(
        h.journal.conversationWriteCount(mr6b2Account, h.conversationId),
        20,
      );
      expect(
        h.journal.conversationWriteCount(mr6b2Account, 'conversation-b'),
        20,
      );
      expect(
        h.journal.conversationWriteCount(mr6b2Account, 'conversation-c'),
        20,
      );

      final fourth = h.newCoordinator(conversationId: 'conversation-d');
      h.budget = AiToolBudget(maxGitLabRequests: 40);
      fourth.beginRun('Star team/example-9.');
      fourth.beginTurn();
      const blockedId = 'account-61';
      final blocked = await fourth.propose(
        AiToolCall(
          id: blockedId,
          name: 'setStar',
          arguments: {
            'projectId': 9,
            'starred': true,
            'reason': 'synthetic cap probe',
          },
        ),
      );
      expect(blocked, isNull);
      expect(fourth.outcomeFor(blockedId)?.reasonCode, 'writeBudgetExceeded');
      expect(h.server.mutationCount(), 60);

      journalClock = journalClock.add(const Duration(hours: 1));
      h.budget = AiToolBudget(maxGitLabRequests: 40);
      fourth.beginRun('Star team/example-9.');
      fourth.beginTurn();
      final exactHour = await fourth.propose(
        h.call('setStar', {'projectId': 9, 'starred': true}, id: 'exact-hour'),
      );
      expect(exactHour, isNull);
      expect(
        fourth.outcomeFor('exact-hour')?.reasonCode,
        'writeBudgetExceeded',
      );

      journalClock = journalClock.add(const Duration(microseconds: 1));
      h.budget = AiToolBudget(maxGitLabRequests: 40);
      fourth.beginRun('Unstar team/example-9.');
      fourth.beginTurn();
      final reopened = await fourth.propose(
        h.call('setStar', {'projectId': 9, 'starred': false}, id: 'reopened'),
      );
      expect(reopened, isNotNull);
      final reopenedOutcome = await fourth.approve(reopened!);
      expect(reopenedOutcome.state, AiJournalState.succeeded);
      expect(reopenedOutcome.mutationCount, 1);
      expect(h.server.mutationCount(), 61);
    },
  );

  test('three conversations share the account rolling-hour T4 cap', () async {
    final h = await Mr6b2Harness.create(maxGitLabRequests: 40);
    addTearDown(h.dispose);
    h.server.overrides['DELETE projects/9/repository/branches/work'] = (_) =>
        ResponseBody.fromString('', 204);
    final coordinators = [
      h.coordinator,
      h.newCoordinator(conversationId: 't4-b'),
      h.newCoordinator(conversationId: 't4-c'),
    ];
    for (var write = 0; write < 10; write++) {
      final coordinator = coordinators[write % coordinators.length];
      h.budget = AiToolBudget(maxGitLabRequests: 40);
      coordinator.beginRun('Delete branch `work` in team/example-9.');
      coordinator.beginTurn();
      final call = h.call('deleteBranch', {
        'projectId': 9,
        'branch': 'work',
      }, id: 't4-$write');
      final proposal = await coordinator.propose(call);
      expect(proposal, isNotNull, reason: call.id);
      final outcome = await coordinator.approve(
        proposal!,
        typedName: proposal.tier.typedName,
      );
      expect(outcome.state, AiJournalState.succeeded, reason: call.id);
      expect(outcome.mutationCount, 1, reason: call.id);
    }
    expect(h.server.mutationCount(), 10);

    final blockedCoordinator = h.newCoordinator(conversationId: 't4-d');
    h.budget = AiToolBudget(maxGitLabRequests: 40);
    blockedCoordinator.beginRun('Delete branch `work` in team/example-9.');
    blockedCoordinator.beginTurn();
    const blockedId = 't4-11';
    final blocked = await blockedCoordinator.propose(
      h.call('deleteBranch', {'projectId': 9, 'branch': 'work'}, id: blockedId),
    );
    expect(blocked, isNull);
    expect(
      blockedCoordinator.outcomeFor(blockedId)?.reasonCode,
      'writeBudgetExceeded',
    );
    expect(h.server.mutationCount(), 10);
  });
}
