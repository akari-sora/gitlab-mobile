import 'release_policy_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show UploadPlaceholderTable;
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart';

const _issueScope = AiWriteScope(
  accountKey: coordAccount,
  grants: [AiScopeGrant(kind: AiScopeKind.workItem, projectId: 9, iid: 3)],
);

void main() {
  test('todo defers only scope denials, never a read-only level denial', () {
    final capability = productionAiLedger.find('markTodoDone')!;
    AiTierDecision decide(AiAutonomyLevel level) => decideTier(
      AiTierInput(
        level: level,
        capability: capability,
        scope: _issueScope,
        target: AiTargetRef(kind: AiTargetKind.todo),
        binding: bindTargets(
          userMessage: 'Mark this todo done',
          restoredFromHistory: false,
          scope: _issueScope,
          targets: const [],
          interfaceLanguage: 'en',
          deviceLanguages: const ['en'],
        ),
      ),
    );
    final readOnly = decide(AiAutonomyLevel.readOnly);
    expect(readOnly.decision, AiGateDecision.deny);
    expect(readOnly.scopeDenied, isFalse);
    final unresolvedOwner = decide(AiAutonomyLevel.bypass);
    expect(unresolvedOwner.decision, AiGateDecision.deny);
    expect(unresolvedOwner.scopeDenied, isTrue);
  });

  for (final denied in [
    'level',
    'ceiling',
    'tools',
    'consent',
    'foreground',
    'client',
    'account',
  ]) {
    test('todo denied by $denied makes no freshness or port reads', () async {
      final h = await CoordHarness.create();
      addTearDown(h.dispose);
      var reads = 0;
      var ports = 0;
      h.coordinator = PolicyAiWriteCoordinator(
        releasePolicy: fixtureReleasePolicy,
        snapshot: () => AiWritePolicySnapshot(
          scope: _issueScope,
          level: denied == 'level'
              ? AiAutonomyLevel.readOnly
              : AiAutonomyLevel.bypass,
          ceiling: denied == 'ceiling'
              ? AiAutonomyLevel.readOnly
              : AiAutonomyLevel.bypass,
          consentHash: 'synthetic',
          writePolicyRevision: 1,
          toolsEnabled: denied != 'tools',
          consentValid: denied != 'consent',
          appInForeground: denied != 'foreground',
          clientMayStart: denied != 'client',
          alive: denied != 'account',
        ),
        createPort: () {
          ports++;
          throw StateError('denied before port');
        },
        journal: h.journal,
        conversationId: 'denied-todo',
        budget: () => h.budget,
        readFreshness: (_) async {
          reads++;
          return const AiWriteFreshness();
        },
        placeholders: UploadPlaceholderTable(instance: h.api.instance),
        knownSecrets: () => const {},
        safeDisplay: (value) => value,
      );
      h.newRun('Mark this todo done');
      final call = AiToolCall(
        id: 'todo',
        name: 'markTodoDone',
        arguments: {'todoId': 900, 'reason': 'Requested'},
      );
      expect(await h.coordinator.propose(call), isNull);
      expect(
        h.coordinator.outcomeFor('todo')?.state,
        AiJournalState.notExecuted,
      );
      expect(reads, 0);
      expect(ports, 0);
      expect(h.adapter.requests, isEmpty);
      expect(h.budget.gitLabRequests, 0);
    });
  }

  Future<CoordHarness> settled({int? failure}) async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    h.level = AiAutonomyLevel.bypass;
    h.failWritesWith = failure;
    h.newRun('Star this project');
    final first = (await h.coordinator.propose(starCall('first')))!;
    final result = await h.coordinator.approve(first);
    expect(
      result.state,
      failure == null ? AiJournalState.succeeded : AiJournalState.failedCertain,
    );
    h.failWritesWith = null;
    return h;
  }

  test(
    'a same-run success is always a duplicate, resumed or not',
    () async {
      final h = await settled();
      final ordinary = (await h.coordinator.propose(starCall('ordinary')))!;
      expect(ordinary.tier.decision, AiGateDecision.requireApproval);
      expect(
        ordinary.tier.reasons,
        contains(AiFixedConfirmReason.duplicateOfSettledWrite),
      );
      final duplicate = (await h.coordinator.propose(starCall('resumed')))!;
      expect(duplicate.tier.decision, AiGateDecision.requireApproval);
      expect(
        duplicate.tier.reasons,
        contains(AiFixedConfirmReason.duplicateOfSettledWrite),
      );
      final before = h.adapter.requests.length;
      final replay = await h.coordinator.execute(starCall('first'));
      expect(replay.state, AiJournalState.succeeded);
      expect(h.adapter.requests.length, before);
      expect(h.mutations, 1);
    },
  );

  for (final otherConversation in [false, true]) {
    test(
      'a success in another ${otherConversation ? 'conversation' : 'run'} is not a resume duplicate',
      () async {
        final h = await settled();
        if (otherConversation) {
          h.coordinator = h.newCoordinator(
            conversationId: 'another-conversation',
          );
        }
        h.newRun('Star this project again');
        h.coordinator.resumeRun();
        final next = (await h.coordinator.propose(starCall('next')))!;
        expect(next.tier.decision, AiGateDecision.execute);
        expect(
          next.tier.reasons,
          isNot(contains(AiFixedConfirmReason.duplicateOfSettledWrite)),
        );
        expect(h.mutations, 1);
      },
    );
  }

  test('a failed-certain write is not a settled resume duplicate', () async {
    final h = await settled(failure: 403);
    h.coordinator.resumeRun();
    final next = (await h.coordinator.propose(starCall('retry')))!;
    expect(next.tier.decision, AiGateDecision.execute);
    expect(
      next.tier.reasons,
      isNot(contains(AiFixedConfirmReason.duplicateOfSettledWrite)),
    );
    expect(h.mutations, 1);
  });

  test(
    'uncertain results stay isolated even on explicit continuation',
    () async {
      final h = await CoordHarness.create();
      addTearDown(h.dispose);
      h.level = AiAutonomyLevel.bypass;
      h.failWritesWith = 500;
      h.newRun('Star this project');
      final first = (await h.coordinator.propose(starCall('first')))!;
      expect(
        (await h.coordinator.approve(first)).state,
        AiJournalState.writeUncertain,
      );
      h.coordinator.resumeRun();
      expect(await h.coordinator.propose(starCall('again')), isNull);
      expect(h.coordinator.outcomeFor('again')?.reasonCode, 'isolated');
      expect(h.mutations, 1);
    },
  );

  test(
    'successful identical uploads keep their independent cross-run confirmation',
    () async {
      final h = await CoordHarness.create();
      addTearDown(h.dispose);
      h.level = AiAutonomyLevel.bypass;
      final attached = await h.attach('shot.png', [1, 2, 3]);
      AiToolCall upload(String id) => AiToolCall(
        id: id,
        name: 'upload_attachment',
        arguments: {
          'attachmentId': attached.id,
          'projectId': 9,
          'reason': 'Requested',
        },
      );
      h.newRun('Upload this attachment');
      final first = (await h.coordinator.propose(upload('upload-one')))!;
      expect(
        (await h.coordinator.approve(first)).state,
        AiJournalState.succeeded,
      );
      h.newRun('Upload it again');
      final again = (await h.coordinator.propose(upload('upload-two')))!;
      expect(again.tier.decision, AiGateDecision.requireApproval);
      expect(
        again.tier.reasons,
        contains(AiFixedConfirmReason.duplicateUpload),
      );
      expect(
        again.tier.reasons,
        isNot(contains(AiFixedConfirmReason.duplicateOfSettledWrite)),
      );
      expect(h.mutations, 1);
    },
  );
}
