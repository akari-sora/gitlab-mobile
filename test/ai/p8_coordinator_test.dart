import 'release_policy_support.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_preview.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show UploadPlaceholderTable;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b2_merge_port_test.dart' as merge;

void main() {
  late _Harness h;
  setUp(() async => h = await _Harness.create());
  tearDown(() => h.close());

  test('coordinator CI hard line requires CI path even at bypass', () async {
    h.level = AiAutonomyLevel.bypass;
    h.server.diffs = [merge.change('lib/a.dart', old: '.gitlab-ci.yml')];
    final proposal = (await h.propose())!;
    expect(proposal.tier.tier, AiWriteTier.hardLine);
    expect(proposal.tier.requiresTypedName, true);
    expect(proposal.tier.typedName, '.gitlab-ci.yml');
    expect(
      (await h.coordinator.approve(proposal, typedName: '!3')).mutationCount,
      0,
    );
    expect(h.server.writes, isEmpty);
  });

  for (final changed in ['head', 'closing', 'config', 'protection']) {
    test('coordinator invalidates approval after $changed changes', () async {
      final proposal = (await h.propose())!;
      switch (changed) {
        case 'head':
          h.server.sha = 'e' * 40;
        case 'closing':
          h.server.closes = [
            {'project_id': 9, 'iid': 7},
          ];
        case 'config':
          h.server.config = 'ci/new.yml';
        case 'protection':
          h.server.protected = true;
      }
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, anyOf('headMoved', 'targetChanged'));
      expect(outcome.mutationCount, 0);
      expect(h.server.writes, isEmpty);
    });
  }

  test(
    'coordinator merge binding needs MR and both explicit branches',
    () async {
      h.level = AiAutonomyLevel.conversationGrant;
      final missing = (await h.propose(message: 'merge !3'))!;
      expect(missing.tier.decision, AiGateDecision.requireApproval);
      await h.coordinator.reject(missing);
      final bound = (await h.propose())!;
      expect(bound.tier.decision, AiGateDecision.execute);
      expect(h.server.writes, isEmpty);
    },
  );

  test('unknown merge isolates MR and ref; one !iid releases both', () async {
    final proposal = (await h.propose())!;
    h.server.status = 500;
    final outcome = await h.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.writeUncertain);
    expect(h.server.writes, hasLength(1));
    final mr = AiConflictKey([merge.account, 'project:9', 'mergeRequest', '3']);
    final ref = AiConflictKey([
      merge.account,
      'project:9',
      'ref',
      'feature-target',
    ]);
    expect(h.journal.isolated(merge.account, {mr, ref}), true);
    h.server.status = 200;
    expect(await h.propose(op: 'approveMergeRequest'), isNull);
    expect(
      h.coordinator.recordedOutcomeFor(h.lastCall)!.reasonCode,
      'isolated',
    );
    expect(h.server.writes, hasLength(1));
    await expectLater(
      h.journal.releaseByUser(
        executionId: proposal.executionId,
        typedName: 'feature-target',
      ),
      throwsA(isA<AiJournalException>()),
    );
    await h.journal.releaseByUser(
      executionId: proposal.executionId,
      typedName: '!3',
    );
    expect(h.journal.isolated(merge.account, {mr}), false);
    expect(h.journal.isolated(merge.account, {ref}), false);
    expect(h.journal.requiresConfirmation(merge.account, {mr, ref}), true);
  });

  test('server draft class A secret blocks proposal and mutation', () async {
    h.server.drafts = [
      {'id': 8, 'note': 'glpat-ABCDEFGHIJKLMNOPQRST'},
    ];
    expect(await h.propose(op: 'publishDraftNotes'), isNull);
    expect(
      h.coordinator.recordedOutcomeFor(h.lastCall)!.state,
      AiJournalState.notExecuted,
    );
    expect(
      h.coordinator.recordedOutcomeFor(h.lastCall)!.reasonCode,
      'policyBlocked',
    );
    expect(h.server.writes, isEmpty);
  });

  for (final body in [
    'Review with @alice',
    '@all review',
    '@team/reviewers review',
    '@one @two @three @four @five @six review',
  ]) {
    test('issue13 server draft mentions require approval: $body', () async {
      h.level = AiAutonomyLevel.bypass;
      h.server.drafts = [{'id': 8, 'note': body}];
      final proposal = await h.propose(op: 'publishDraftNotes');
      expect(proposal, isNotNull);
      expect(proposal!.tier.decision, AiGateDecision.requireApproval);
      expect(proposal.tier.reasons, contains(AiFixedConfirmReason.massMention));
      expect(h.server.drafts.single['note'], body);
      expect(h.server.writes, isEmpty);
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.mutationCount, 1);
      expect(h.server.writes.single.uri.path, endsWith('/draft_notes/bulk_publish'));
    });
  }

  for (final body in [
    '@alice\nglpat-ABCDEFGHIJKLMNOPQRST',
    '@alice\n[REDACTED]',
    '@alice\n/merge',
    '@alice\n![image](https://outside.example/a.png)',
  ]) {
    test('issue13 draft mentions do not relax class A safety: $body', () async {
      h.server.drafts = [{'id': 8, 'note': body}];
      expect(await h.propose(op: 'publishDraftNotes'), isNull);
      expect(h.coordinator.recordedOutcomeFor(h.lastCall)!.reasonCode,
          'policyBlocked');
      expect(h.server.writes, isEmpty);
    });
  }

  for (final failedOp in ['mergeRequest', 'approveMergeRequest']) {
    for (final nextOp in ['mergeRequest', 'approveMergeRequest']) {
      test('issue13 local $failedOp head movement marks later $nextOp preview',
          () async {
        final first = (await h.propose(op: failedOp))!;
        h.server.sha = 'e' * 40;
        final outcome = await h.coordinator.approve(first,
            typedName: first.tier.typedName);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'headMoved');
        expect(h.server.writes, isEmpty);
        h.level = AiAutonomyLevel.conversationGrant;
        final next = (await h.propose(op: nextOp))!;
        expect(next.tier.decision, AiGateDecision.requireApproval);
        expect(next.tier.reasons,
            contains(AiFixedConfirmReason.headMovedSincePreview));
        expect((next.preview as AiMergePreview).headMovedCommits, [h.server.sha]);
        final compare = h.server.adapter.requests.singleWhere(
            (r) => r.uri.path.endsWith('/compare'));
        expect(compare.uri.queryParameters['from'], merge.head);
        expect(compare.uri.queryParameters['to'], h.server.sha);
        expect(h.server.writes, isEmpty);
      });
    }
  }

  test('incomplete merge cannot produce a coordinator proposal', () async {
    h.server.changesCount = '1+';
    expect(await h.propose(), isNull);
    expect(
      h.coordinator.recordedOutcomeFor(h.lastCall)!.reasonCode,
      'mergeCheckIncomplete',
    );
    expect(h.server.writes, isEmpty);
  });
}

final class _Harness {
  _Harness(this.root, this.journal);
  final Directory root;
  final AiWriteJournal journal;
  final server = merge.Server();
  final budget = AiToolBudget(maxGitLabRequests: 400);
  late final PolicyAiWriteCoordinator coordinator;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  var calls = 0;
  String lastCall = '';

  static Future<_Harness> create() async {
    final root = Directory.systemTemp.createTempSync('p8-coordinator-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'p8-test',
    );
    await journal.recoverAfterAccountsLoaded([merge.account]);
    await journal.ensureInitialized(merge.account);
    final h = _Harness(root, journal);
    h.coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        scope: merge.scope,
        level: h.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p8',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 1,
        appInForeground: true,
      ),
      createPort: () => h.server.port,
      journal: journal,
      conversationId: 'p8',
      budget: () => h.budget,
      readFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      placeholders: UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {'glpat-ABCDEFGHIJKLMNOPQRST'},
      safeDisplay: (v) => v,
      ledger: const _VisibleRows(),
    );
    return h;
  }

  Future<AiWriteProposal?> propose({
    String op = 'mergeRequest',
    String message = 'merge !3 `topic/a` `feature-target`',
  }) {
    coordinator.beginRun(message);
    coordinator.beginTurn();
    lastCall = 'p8-${++calls}';
    return coordinator.propose(
      AiToolCall(
        id: lastCall,
        name: op,
        arguments: {'projectId': 9, 'iid': 3, 'reason': 'review'},
      ),
    );
  }

  void close() {
    coordinator.stop('done');
    server.close();
    root.deleteSync(recursive: true);
  }
}

// Visibility is injected only here; production rows remain hidden.
final class _VisibleRows implements AiCapabilityLedger {
  const _VisibleRows();
  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || !aiMergeRows.contains(row)) return null;
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
  ];
}
