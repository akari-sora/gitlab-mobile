import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b3g_support.dart';
import 'mr6b3g_budget_test.dart' as actual;

// The coordinator and encrypted journal are real; G0eGraphPort is a synthetic
// send seam. The counters here are therefore NOT FakeAdapter HTTP counts.
const _operations = <String, Map<String, Object?>>{
  'updateGroupWorkItemState': {'stateEvent': 'close'},
  'updateGroupWorkItemContent': {'description': 'Safe replacement'},
  'editGroupWorkItemActivityNote': {'noteId': 31, 'body': 'Safe note'},
  'updateGroupWorkItemLabels': {
    'labels': <String>['ready'],
  },
  'setGroupWorkItemActivityNoteReaction': {
    'noteId': 31,
    'name': 'thumbsup',
    'add': true,
  },
  'setGroupWorkItemNotifications': {'enabled': true},
};
const _groupKey = AiConflictKey([g0eAccount, 'group:7', 'workItem', '5']);
const _conversation = 'g0e-seams';
const _actualConversation = 'g15-real-group';

void main() {
  setUp(() => aiGroupWorkItemWritesEnabledForTesting = true);
  tearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);

  for (final operation in _operations.entries) {
    test(
      '${operation.key} hook flush failure fails closed and recovers prepared',
      () async {
        final h = await _harness();
        await _seedMark(h);
        final proposal = await _proposal(h, operation.key, operation.value);
        h.base.files.failWriteNumber = h.base.files.writeCount + 2;
        final outcome = await h.coordinator.approve(proposal);
        expect(
          outcome.state,
          AiJournalState.notExecuted,
          reason: outcome.reasonCode,
        );
        expect(outcome.reasonCode, 'journalUnavailable');
        expect(outcome.mutationCount, 0);
        expect(h.graph.mutations, 0);
        expect(
          _entry(h.base.journal, proposal.executionId).state,
          AiJournalState.prepared,
        );
        expect(
          h.base.journal.conversationWriteCount(g0eAccount, _conversation),
          0,
        );
        expect(
          h.base.journal.requiresConfirmation(g0eAccount, {_groupKey}),
          isTrue,
        );
        await _expectFailStop(h);
        final recovered = await _recover(h);
        expect(
          _entry(recovered, proposal.executionId).state,
          AiJournalState.notExecuted,
        );
        expect(recovered.conversationWriteCount(g0eAccount, _conversation), 0);
        expect(recovered.requiresConfirmation(g0eAccount, {_groupKey}), isTrue);
      },
    );

    test(
      '${operation.key} terminal flush failure recovers sent write as uncertain',
      () async {
        final h = await _harness();
        final proposal = await _proposal(h, operation.key, operation.value);
        h.base.files.failWriteNumber = h.base.files.writeCount + 3;
        final outcome = await h.coordinator.approve(proposal);
        expect(
          outcome.state,
          AiJournalState.writeUncertain,
          reason: outcome.reasonCode,
        );
        expect(outcome.reasonCode, 'journalUnavailable');
        expect(outcome.mutationCount, 1);
        expect(h.graph.mutations, 1);
        expect(h.base.journal.isolated(g0eAccount, {_groupKey}), isTrue);
        final durable = await h.base.readDurableJournal();
        final entry = (durable['entries']! as List)
            .cast<Map<String, Object?>>()
            .singleWhere((e) => e['execution'] == proposal.executionId);
        expect(entry['state'], 'dispatching');
        await _expectFailStop(h);
        final recovered = await _recover(h);
        expect(
          _entry(recovered, proposal.executionId).state,
          AiJournalState.writeUncertain,
        );
        expect(recovered.isolated(g0eAccount, {_groupKey}), isTrue);
        expect(recovered.conversationWriteCount(g0eAccount, _conversation), 1);
        expect(h.graph.mutations, 1);
      },
    );

    test(
      '${operation.key} mayStart refusal refunds and restores pending confirmation',
      () async {
        final h = await _harness();
        await _seedMark(h);
        final proposal = await _proposal(h, operation.key, operation.value);
        h.graph.afterBeforeMutation = () => h.graph.live = false;
        final outcome = await h.coordinator.approve(proposal);
        expect(
          outcome.state,
          AiJournalState.notExecuted,
          reason: outcome.reasonCode,
        );
        expect(outcome.mutationCount, 0);
        expect(h.graph.mutations, 0);
        expect(
          _entry(h.base.journal, proposal.executionId).state,
          AiJournalState.notExecuted,
        );
        expect(h.base.journal.isolated(g0eAccount, {_groupKey}), isFalse);
        expect(
          h.base.journal.conversationWriteCount(g0eAccount, _conversation),
          0,
        );
        expect(
          h.base.journal.requiresConfirmation(g0eAccount, {_groupKey}),
          isTrue,
        );
        await _expectFailStop(h);
        final recovered = await _recover(h);
        expect(
          _entry(recovered, proposal.executionId).state,
          AiJournalState.notExecuted,
        );
        expect(recovered.requiresConfirmation(g0eAccount, {_groupKey}), isTrue);
      },
    );
  }

  test(
    'failed rollback flush preserves dispatching, count and isolation on restart',
    () async {
      final h = await _harness();
      await _seedMark(h);
      final proposal = await _proposal(h, 'updateGroupWorkItemState', {
        'stateEvent': 'close',
      });
      final entered = h.base.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = h.coordinator.approve(proposal);
      await entered;
      final disk = await h.base.readDurableJournal();
      final entry = (disk['entries']! as List)
          .cast<Map<String, Object?>>()
          .singleWhere((e) => e['execution'] == proposal.executionId);
      expect(entry['state'], 'dispatching');
      expect(entry['consumedMarks'], isNotEmpty);
      h.graph.live = false;
      h.base.files.failWriteNumber = h.base.files.writeCount + 1;
      h.base.files.releaseBarrier();
      final outcome = await pending;
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.reasonCode, 'journalUnavailable');
      expect(outcome.mutationCount, 0);
      expect(h.graph.mutations, 0);
      expect(h.base.journal.isolated(g0eAccount, {_groupKey}), isTrue);
      await _expectFailStop(h);
      final recovered = await _recover(h);
      expect(
        _entry(recovered, proposal.executionId).state,
        AiJournalState.writeUncertain,
      );
      expect(recovered.isolated(g0eAccount, {_groupKey}), isTrue);
      expect(recovered.conversationWriteCount(g0eAccount, _conversation), 1);
    },
  );

  // Actual group port and core API, with a synthetic adapter/oracle.
  for (final operation in actual.g15LogicalReads.keys) {
    for (final failRollback in [false, true]) {
      test(
        '$operation actual revocation rollback flush failure=$failRollback',
        () async {
          final h = await actual.G15Harness.create();
          addTearDown(h.dispose);
          await _seedJournalMark(h.base.journal);
          final proposal = (await h.propose(operation))!;
          final entered = h.base.files.armBarrier(
            writesBeforeBarrier: 1,
            afterPersist: true,
          );
          final pending = h.approve(proposal);
          await entered.timeout(const Duration(seconds: 30));
          final disk = await h.base.readDurableJournal();
          final dispatching = (disk['entries']! as List)
              .cast<Map<String, Object?>>()
              .singleWhere(
                (entry) => entry['execution'] == proposal.executionId,
              );
          expect(dispatching['state'], 'dispatching');
          expect(dispatching['consumedMarks'], isNotEmpty);
          h.generation++;
          if (failRollback) {
            h.base.files.failWriteNumber = h.base.files.writeCount + 1;
          }
          h.base.files.releaseBarrier();
          final outcome = await pending.timeout(const Duration(seconds: 30));
          expect(
            outcome.state,
            failRollback
                ? AiJournalState.writeUncertain
                : AiJournalState.notExecuted,
            reason: outcome.reasonCode,
          );
          expect(outcome.mutationCount, 0);
          expect(h.server.mutations, 0);
          final entry = _entry(h.base.journal, proposal.executionId);
          expect(
            h.base.journal.isolated(g0eAccount, entry.writeKeys),
            failRollback,
          );
          expect(
            h.base.journal.conversationWriteCount(g0eAccount, 'g15-real-group'),
            failRollback ? 1 : 0,
          );
          final recovered = await _recoverActual(h);
          expect(
            _entry(recovered, proposal.executionId).state,
            failRollback
                ? AiJournalState.writeUncertain
                : AiJournalState.notExecuted,
          );
          expect(recovered.isolated(g0eAccount, entry.writeKeys), failRollback);
          if (!failRollback) {
            expect(
              recovered.requiresConfirmation(g0eAccount, {_groupKey}),
              isTrue,
            );
          } else {
            expect(outcome.reasonCode, 'journalUnavailable');
          }
        },
      );
    }
    test('$operation actual adapter observes durable dispatching', () async {
      final h = await actual.G15Harness.create();
      final entered = Completer<void>();
      final release = Completer<void>();
      h.server.mutationEntered = entered;
      h.server.releaseMutation = release;
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await h.dispose();
      });
      final proposal = (await h.propose(operation))!;
      final pending = h.approve(proposal);
      await entered.future.timeout(const Duration(seconds: 30));
      final durable = await h.base.readDurableJournal();
      final entry = (durable['entries']! as List)
          .cast<Map<String, Object?>>()
          .singleWhere((e) => e['execution'] == proposal.executionId);
      expect(entry['state'], 'dispatching');
      final inMemory = _entry(h.base.journal, proposal.executionId);
      expect(inMemory.state, AiJournalState.dispatching);
      expect(h.base.journal.isolated(g0eAccount, inMemory.writeKeys), isTrue);
      expect(h.server.mutations, 1);
      release.complete();
      final outcome = await pending.timeout(const Duration(seconds: 30));
      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(h.server.mutations, 1);
    });

    test('$operation actual dispatch flush failure prevents send', () async {
      final h = await actual.G15Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose(operation))!;
      h.base.files.failWriteNumber = h.base.files.writeCount + 2;
      final outcome = await h
          .approve(proposal)
          .timeout(const Duration(seconds: 30));
      expect(
        outcome.state,
        AiJournalState.notExecuted,
        reason: outcome.reasonCode,
      );
      expect(outcome.reasonCode, 'journalUnavailable');
      expect(h.server.mutations, 0);
      expect(
        _entry(h.base.journal, proposal.executionId).state,
        AiJournalState.prepared,
      );
      expect(await h.propose(operation), isNull);
      expect(
        h.coordinator.recordedOutcomeFor('g15-1')!.reasonCode,
        'previousWriteIncomplete',
      );
      final recovered = await _recoverActual(h);
      expect(
        _entry(recovered, proposal.executionId).state,
        AiJournalState.notExecuted,
      );
    });

    test(
      '$operation actual terminal flush failure isolates and recovers',
      () async {
        final h = await actual.G15Harness.create();
        addTearDown(h.dispose);
        final proposal = (await h.propose(operation))!;
        h.base.files.failWriteNumber = h.base.files.writeCount + 3;
        final outcome = await h
            .approve(proposal)
            .timeout(const Duration(seconds: 30));
        expect(
          outcome.state,
          AiJournalState.writeUncertain,
          reason: outcome.reasonCode,
        );
        expect(outcome.reasonCode, 'journalUnavailable');
        expect(h.server.mutations, 1);
        final entry = _entry(h.base.journal, proposal.executionId);
        expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isTrue);
        final durable = await h.base.readDurableJournal();
        expect(
          (durable['entries']! as List)
              .cast<Map<String, Object?>>()
              .singleWhere(
                (e) => e['execution'] == proposal.executionId,
              )['state'],
          'dispatching',
        );
        expect(await h.propose(operation), isNull);
        expect(
          h.coordinator.recordedOutcomeFor('g15-1')!.reasonCode,
          'previousWriteIncomplete',
        );
        final recovered = await _recoverActual(h);
        final recoveredEntry = _entry(recovered, proposal.executionId);
        expect(recoveredEntry.state, AiJournalState.writeUncertain);
        expect(
          recovered.isolated(g0eAccount, recoveredEntry.writeKeys),
          isTrue,
        );
        expect(h.server.mutations, 1);
      },
    );
  }

  for (final operation in actual.g15LogicalReads.keys) {
    test(
      '$operation actual stopped send settles its late acknowledgement',
      () async {
        final h = await actual.G15Harness.create();
        addTearDown(h.dispose);
        final proposal = (await h.propose(operation))!;
        final entered = h.server.mutationEntered = Completer<void>();
        final release = h.server.releaseMutation = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final pending = h.approve(proposal);
        await entered.future.timeout(const Duration(seconds: 30));
        final entry = _entry(h.base.journal, proposal.executionId);
        expect(entry.state, AiJournalState.dispatching);
        h.coordinator.stop();
        expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isTrue);
        expect(h.server.mutations, 1);
        release.complete();
        final outcome = await pending.timeout(const Duration(seconds: 30));
        expect(
          outcome.state,
          AiJournalState.succeeded,
          reason: outcome.reasonCode,
        );
        expect(outcome.readbackConfirmed, !operation.endsWith('Todo'));
        expect(
          _entry(h.base.journal, proposal.executionId).state,
          AiJournalState.succeeded,
        );
        expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isFalse);
        expect(h.server.mutations, 1);
      },
    );
    // Independently specified readback sizes; todos have only an ack (D30).
    final readbacks = switch (operation) {
      'snoozeTodo' || 'unsnoozeTodo' => 0,
      'updateGroupWorkItemDates' || 'setGroupWorkItemActivityNoteReaction' => 2,
      _ => 1,
    };
    for (var read = 1; read <= actual.g15LogicalReads[operation]!; read++) {
      test('$operation actual failure at logical read $read', () async {
        final h = await actual.G15Harness.create();
        addTearDown(h.dispose);
        h.server.failLogicalRead = read;
        final proposal = await h.propose(operation);
        final outcome = proposal == null
            ? h.coordinator.recordedOutcomeFor('g15-0')!
            : await h.approve(proposal);
        final sent = read > actual.g15LogicalReads[operation]! - readbacks;
        expect(h.server.injectedReadFailures, 1);
        expect(h.server.mutations, sent ? 1 : 0);
        expect(
          outcome.state,
          sent ? AiJournalState.writeUncertain : AiJournalState.notExecuted,
          reason: outcome.reasonCode,
        );
        if (sent) {
          final entry = _entry(h.base.journal, proposal!.executionId);
          expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isTrue);
        }
        expect(
          h.server.adapter.requests.length,
          lessThanOrEqualTo(actual.g15LogicalReads[operation]! + 1),
        );
      });
    }
    test(
      '$operation actual preflight failure sends zero and stops turn',
      () async {
        final h = await actual.G15Harness.create();
        addTearDown(h.dispose);
        final proposal = (await h.propose(operation))!;
        final read = operation.endsWith('Todo')
            ? h.server.reads.keys.first
            : 'freshness';
        h.server.failReadName = read;
        h.server.failReadOccurrence = (h.server.reads[read] ?? 0) + 1;
        final outcome = await h
            .approve(proposal)
            .timeout(const Duration(seconds: 30));
        expect(
          outcome.state,
          AiJournalState.notExecuted,
          reason: outcome.reasonCode,
        );
        expect(h.server.mutations, 0);
        expect(h.server.reads[read], h.server.failReadOccurrence);
        expect(await h.propose(operation), isNull);
        expect(
          h.coordinator.recordedOutcomeFor('g15-1')!.reasonCode,
          'previousWriteIncomplete',
        );
        expect(h.server.mutations, 0);
      },
    );
  }

  for (final operation in [
    'createGroupWorkItemActivityComment',
    'createGroupWorkItemActivityReply',
    'deleteGroupWorkItemActivityNote',
    'editGroupWorkItemActivityNote',
    'setGroupWorkItemActivityNoteReaction',
  ]) {
    test('$operation actual failed readback remains uncertain', () async {
      final h = await actual.G15Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose(operation))!;
      h.server.readbackStatus = 500;
      final outcome = await h
          .approve(proposal)
          .timeout(const Duration(seconds: 30));
      expect(
        outcome.state,
        AiJournalState.writeUncertain,
        reason: outcome.reasonCode,
      );
      expect(h.server.mutations, 1);
      final entry = _entry(h.base.journal, proposal.executionId);
      expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isTrue);
    });
  }

  for (final operation in ['snoozeTodo', 'unsnoozeTodo']) {
    test('$operation actual acknowledgement does not need readback', () async {
      final h = await actual.G15Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose(operation))!;
      h.server.readbackStatus = 500;
      final outcome = await h
          .approve(proposal)
          .timeout(const Duration(seconds: 30));
      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(h.server.mutations, 1);
    });
  }

  for (final operation in [
    'createGroupWorkItemActivityComment',
    'createGroupWorkItemActivityReply',
    'deleteGroupWorkItemActivityNote',
    'editGroupWorkItemActivityNote',
    'setGroupWorkItemActivityNoteReaction',
  ]) {
    test('$operation actual wrong readback owner remains uncertain', () async {
      final h = await actual.G15Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose(operation))!;
      h.server.corruptReadbackOwner = true;
      final outcome = await h
          .approve(proposal)
          .timeout(const Duration(seconds: 30));
      expect(
        outcome.state,
        AiJournalState.writeUncertain,
        reason: outcome.reasonCode,
      );
      expect(h.server.mutations, 1);
      expect(h.server.ownerCorruptions, greaterThan(0));
    });
  }

  for (final operation in [
    'updateGroupWorkItemState',
    'updateGroupWorkItemStatus',
    'updateGroupWorkItemDates',
    'updateGroupWorkItemHealthStatus',
    'updateGroupWorkItemAssignees',
    'updateGroupWorkItemMilestone',
    'updateGroupWorkItemWeight',
    'setGroupWorkItemNotifications',
    'setGroupWorkItemActivityNoteReaction',
    'updateGroupWorkItemContent',
    'updateGroupWorkItemLabels',
    'editGroupWorkItemActivityNote',
  ]) {
    test('$operation actual no-change boundary', () async {
      final h = await actual.G15Harness.create();
      addTearDown(h.dispose);
      await _seedJournalMark(h.base.journal);
      final opening = _GroupOpening.capture(h.server);
      switch (operation) {
        case 'updateGroupWorkItemState':
          h.server.oracle.workItemState = 'CLOSED';
        case 'updateGroupWorkItemStatus':
          h.server.oracle.statusId =
              'gid://gitlab/WorkItems::Statuses::Custom::Status/37';
        case 'updateGroupWorkItemDates':
          h.server.oracle.startDate = '2026-10-06';
        case 'updateGroupWorkItemHealthStatus':
          h.server.oracle.healthStatus = 'atRisk';
        case 'updateGroupWorkItemAssignees':
          h.server.oracle.users = [11, 21, 22, 23, 24];
        case 'updateGroupWorkItemMilestone':
          h.server.oracle.milestoneId = 'gid://gitlab/Milestone/6';
        case 'updateGroupWorkItemWeight':
          h.server.oracle.weight = 4;
        case 'setGroupWorkItemNotifications':
          h.server.oracle.notificationsOn = true;
        case 'setGroupWorkItemActivityNoteReaction':
          h.server.oracle.reactionAwarded = true;
        case 'updateGroupWorkItemContent':
          h.server.title = 'Changed title';
          h.server.description = 'Changed description';
        case 'updateGroupWorkItemLabels':
          h.server.labels = ['gid://gitlab/GroupLabel/2'];
        case 'editGroupWorkItemActivityNote':
          h.server.noteBody = 'Changed note';
      }
      final maybeProposal = await h.propose(operation);
      expect(
        maybeProposal,
        isNotNull,
        reason: h.coordinator.recordedOutcomeFor('g15-0')?.reasonCode,
      );
      final proposal = maybeProposal!;
      final reserved = h.budget.gitLabRequests;
      expect(reserved, aiWriteRequestAllowance(operation, oauthReplay: false));
      final outcome = await h
          .approve(proposal)
          .timeout(const Duration(seconds: 30));
      expect(h.server.mutations, 0);
      final entry = _entry(h.base.journal, proposal.executionId);
      expect(entry.state, AiJournalState.notExecuted);
      // No-change and the dates same-value refusal both finish before
      // dispatch, so the journal reservation and confirmation mark return.
      expect(
        h.base.journal.conversationWriteCount(g0eAccount, _actualConversation),
        0,
      );
      expect(
        h.base.journal.requiresConfirmation(g0eAccount, entry.writeKeys),
        isTrue,
      );
      expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isFalse);
      expect(h.budget.gitLabRequests, reserved);
      if (operation == 'updateGroupWorkItemDates') {
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'unsupported');
        expect(outcome.noChange, isFalse);
        await _expectActualFailStop(h, call: 1);
        expect(h.budget.gitLabRequests, reserved);
      } else {
        expect(
          outcome.state,
          AiJournalState.succeeded,
          reason: outcome.reasonCode,
        );
        expect(outcome.reasonCode, 'noChange');
        expect(outcome.noChange, isTrue);
        expect(outcome.mutationCount, 0);
        opening.restore(h.server);
        final continuedProposal = await h.propose(operation);
        expect(
          continuedProposal,
          isNotNull,
          reason: h.coordinator.recordedOutcomeFor('g15-1')?.reasonCode,
        );
        expect(
          h.budget.gitLabRequests,
          reserved + aiWriteRequestAllowance(operation, oauthReplay: false),
        );
        final continued = await h
            .approve(continuedProposal!)
            .timeout(const Duration(seconds: 30));
        expect(
          continued.state,
          AiJournalState.succeeded,
          reason: continued.reasonCode,
        );
        expect(continued.reasonCode, 'succeeded');
        expect(continued.noChange, isFalse);
        expect(continued.mutationCount, 1);
        expect(h.server.mutations, 1);
        expect(
          _entry(h.base.journal, continuedProposal.executionId).state,
          AiJournalState.succeeded,
        );
        expect(
          h.base.journal.conversationWriteCount(
            g0eAccount,
            _actualConversation,
          ),
          1,
        );
        expect(
          h.base.journal.requiresConfirmation(g0eAccount, entry.writeKeys),
          isFalse,
        );
        expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isFalse);
      }
    });
  }

  for (final operation in [
    'updateGroupWorkItemDates',
    'updateGroupWorkItemHealthStatus',
    'updateGroupWorkItemStatus',
    'updateGroupWorkItemState',
  ]) {
    test(
      '$operation post-send unchanged acknowledgement is uncertain',
      () async {
        final h = await actual.G15Harness.create();
        addTearDown(h.dispose);
        final opening = _GroupOpening.capture(h.server);
        final proposal = (await h.propose(operation))!;
        // HTTP 200 with the opening value and revision on both the
        // acknowledgement and the independent readback.
        h.server.oracle.applyMutations = false;
        final outcome = await h
            .approve(proposal)
            .timeout(const Duration(seconds: 30));
        expect(
          outcome.state,
          AiJournalState.writeUncertain,
          reason: outcome.reasonCode,
        );
        expect(outcome.reasonCode, 'writeUncertain');
        expect(outcome.noChange, isFalse);
        expect(outcome.mutationCount, 1);
        expect(h.server.mutations, 1);
        opening.expectHeld(h.server, operation);
        expect(
          _entry(h.base.journal, proposal.executionId).state,
          AiJournalState.writeUncertain,
        );
        expect(
          (await _durableEntry(h, proposal.executionId))['state'],
          'writeUncertain',
        );
        expect(
          h.base.journal.isolated(
            g0eAccount,
            _entry(h.base.journal, proposal.executionId).writeKeys,
          ),
          isTrue,
        );
        await _expectActualFailStop(h, call: 1);
      },
    );
  }

  test(
    'updateGroupWorkItemStatus acknowledgement mismatch is uncertain',
    () async {
      final h = await actual.G15Harness.create();
      addTearDown(h.dispose);
      final opening = _GroupOpening.capture(h.server);
      final proposal = (await h.propose('updateGroupWorkItemStatus'))!;
      h.server.restoreOpeningOnReadback = true;
      final outcome = await h
          .approve(proposal)
          .timeout(const Duration(seconds: 30));
      expect(
        outcome.state,
        AiJournalState.writeUncertain,
        reason: outcome.reasonCode,
      );
      expect(outcome.reasonCode, 'writeUncertain');
      expect(outcome.mutationCount, 1);
      expect(h.server.mutations, 1);
      expect(h.server.acknowledgedStatusId, isNot(opening.statusId));
      expect(h.server.acknowledgedRevision, isNot(opening.revision));
      expect(h.server.oracle.statusId, opening.statusId);
      expect(h.server.oracle.revision, opening.revision);
      expect(
        _entry(h.base.journal, proposal.executionId).state,
        AiJournalState.writeUncertain,
      );
      expect(
        (await _durableEntry(h, proposal.executionId))['state'],
        'writeUncertain',
      );
      expect(
        h.base.journal.isolated(
          g0eAccount,
          _entry(h.base.journal, proposal.executionId).writeKeys,
        ),
        isTrue,
      );
      await _expectActualFailStop(h, call: 1);
    },
  );
}

Future<G0eHarness> _harness() async {
  final h = await G0eHarness.create();
  addTearDown(h.dispose);
  return h;
}

Future<AiWriteProposal> _proposal(
  G0eHarness h,
  String operation,
  Map<String, Object?> args,
) async {
  final call = h.call(operation, args);
  final proposal = await h.coordinator.propose(call);
  expect(
    proposal,
    isNotNull,
    reason:
        '$operation ${h.coordinator.recordedOutcomeFor(call.id)?.reasonCode}',
  );
  return proposal!;
}

Future<void> _seedMark(G0eHarness h) => _seedJournalMark(h.base.journal);

Future<void> _seedJournalMark(AiWriteJournal journal) async {
  const execution = 'g15-seed-mark';
  await journal.prepare(
    draft: AiJournalDraft(
      executionId: execution,
      accountKey: g0eAccount,
      conversationId: 'seed',
      runId: 'seed',
      operationId: 'updateGroupWorkItemState',
      writeKeys: {_groupKey},
      payloadSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      releaseName: '$g0ePath#5',
    ),
  );
  await journal.markDispatching(executionId: execution);
  await journal.finish(
    executionId: execution,
    terminal: AiJournalState.writeUncertain,
  );
  await journal.releaseByUser(executionId: execution, typedName: '$g0ePath#5');
  expect(journal.requiresConfirmation(g0eAccount, {_groupKey}), isTrue);
}

AiJournalEntry _entry(AiWriteJournal journal, String execution) => journal
    .entries(g0eAccount)
    .singleWhere((entry) => entry.executionId == execution);

Future<AiWriteJournal> _recover(G0eHarness h) async {
  final journal = AiWriteJournal(
    keys: h.base.keys,
    applicationSupport: h.base.root,
    files: h.base.files,
    processId: 'g15-restarted',
  );
  await journal.recoverAfterAccountsLoaded([g0eAccount]);
  return journal;
}

Future<void> _expectFailStop(G0eHarness h) async {
  final call = h.call('updateGroupWorkItemState', {'stateEvent': 'close'});
  final before = h.graph.mutations;
  expect(await h.coordinator.propose(call), isNull);
  final outcome = h.coordinator.recordedOutcomeFor(call.id)!;
  expect(outcome.state, AiJournalState.notExecuted);
  expect(outcome.reasonCode, 'previousWriteIncomplete');
  expect(outcome.mutationCount, 0);
  expect(h.graph.mutations, before);
}

Future<void> _expectActualFailStop(
  actual.G15Harness h, {
  required int call,
}) async {
  final requests = h.server.adapter.requests.length;
  final mutations = h.server.mutations;
  expect(await h.propose('updateGroupWorkItemWeight'), isNull);
  final outcome = h.coordinator.recordedOutcomeFor('g15-$call')!;
  expect(outcome.state, AiJournalState.notExecuted);
  expect(outcome.reasonCode, 'previousWriteIncomplete');
  expect(outcome.mutationCount, 0);
  expect(h.server.adapter.requests, hasLength(requests));
  expect(h.server.mutations, mutations);
}

Future<Map<String, Object?>> _durableEntry(
  actual.G15Harness h,
  String execution,
) async {
  final durable = await h.base.readDurableJournal();
  return (durable['entries']! as List).cast<Map<String, Object?>>().singleWhere(
    (entry) => entry['execution'] == execution,
  );
}

final class _GroupOpening {
  _GroupOpening._(actual.G15Server server)
    : revision = server.oracle.revision,
      state = server.oracle.workItemState,
      statusId = server.oracle.statusId,
      startDate = server.oracle.startDate,
      dueDate = server.oracle.dueDate,
      health = server.oracle.healthStatus,
      users = List<int>.of(server.oracle.users),
      milestoneId = server.oracle.milestoneId,
      weight = server.oracle.weight,
      notificationsOn = server.oracle.notificationsOn,
      reactionAwarded = server.oracle.reactionAwarded,
      title = server.title,
      description = server.description,
      labels = List<String>.of(server.labels),
      noteBody = server.noteBody;

  factory _GroupOpening.capture(actual.G15Server server) =>
      _GroupOpening._(server);

  final String revision;
  final String state;
  final String statusId;
  final String startDate;
  final String dueDate;
  final String health;
  final List<int> users;
  final String? milestoneId;
  final int? weight;
  final bool notificationsOn;
  final bool reactionAwarded;
  final String title;
  final String description;
  final List<String> labels;
  final String noteBody;

  void restore(actual.G15Server server) {
    server.oracle.workItemState = state;
    server.oracle.statusId = statusId;
    server.oracle.startDate = startDate;
    server.oracle.dueDate = dueDate;
    server.oracle.healthStatus = health;
    server.oracle.users = users;
    server.oracle.milestoneId = milestoneId;
    server.oracle.weight = weight;
    server.oracle.notificationsOn = notificationsOn;
    server.oracle.reactionAwarded = reactionAwarded;
    server.title = title;
    server.description = description;
    server.labels = labels;
    server.noteBody = noteBody;
    server.oracle.revision = revision;
  }

  void expectHeld(actual.G15Server server, String operation) {
    expect(server.oracle.revision, revision, reason: operation);
    switch (operation) {
      case 'updateGroupWorkItemDates':
        expect(server.oracle.startDate, startDate);
        expect(server.oracle.dueDate, dueDate);
      case 'updateGroupWorkItemHealthStatus':
        expect(server.oracle.healthStatus, health);
      case 'updateGroupWorkItemStatus':
        expect(server.oracle.statusId, statusId);
      case 'updateGroupWorkItemState':
        expect(server.oracle.workItemState, state);
    }
  }
}

Future<AiWriteJournal> _recoverActual(actual.G15Harness h) async {
  final journal = AiWriteJournal(
    keys: h.base.keys,
    applicationSupport: h.base.root,
    files: h.base.files,
    processId: 'g15-actual-restarted',
  );
  await journal.recoverAfterAccountsLoaded([g0eAccount]);
  return journal;
}
