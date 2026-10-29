import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';

import '../../tool/mr7/advanced_scenarios.dart';
import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart';

const _sha = '0123456789abcdef0123456789abcdef01234567';
final _cases = mr7AdvancedCases();

List<Map<String, Object?>> _rows(Map<String, Object?> receipt) =>
    (receipt['scenarios']! as List).cast<Map<String, Object?>>();
Map<String, Object?> _part(Map<String, Object?> receipt, String name) =>
    (receipt[name]! as Map).cast<String, Object?>();
Mr7AdvancedCase _case(String op, String variant) =>
    _cases.singleWhere((c) => c.operation == op && c.variant == variant);

// Negative probes keep exercising production refusal/stop behavior while the
// catalog's project edits are closed. Their observer cannot claim success.
Mr7Scenario _projectRefusalProbe(String variant) => Mr7Scenario(
  id: 'b3-editProject-refusal-$variant',
  suite: 'advanced',
  operation: 'editProject',
  variant: 'refusal-$variant',
  tier: 'hardLine',
  utterance: (p) => 'Edit only the synthetic project ${p.path}.',
  call: (p) => AiToolCall(
    id: 'b3-editProject-refusal-$variant',
    name: 'editProject',
    arguments: {
      'projectId': p.projectId,
      if (variant == 'name')
        'name': 'Synthetic renamed display'
      else
        'description': 'Synthetic project description',
    },
  ),
  paths: (p) => {'PUT projects/${p.projectId}'},
  observe: (_, _) async => false,
);

// These deliberately unverified probes test the production confirmation and
// quarantine mechanics. They do not reopen a closed catalog variant.
Mr7Scenario _mrRefusalProbe(String operation) => Mr7Scenario(
  id: 'b3-$operation-refusal',
  suite: 'advanced',
  operation: operation,
  variant: 'refusal',
  tier: operation == 'approveMergeRequest' ? 'T4' : 'T3',
  targetKind: AiTargetKind.mergeRequest,
  utterance: (p) => 'Perform $operation only on synthetic !3 in ${p.path}.',
  resource: (_) =>
      const AiResourceRef(kind: AiResourceKind.mergeRequest, id: 3),
  call: (p) => AiToolCall(
    id: 'b3-$operation-refusal',
    name: operation,
    arguments: {'projectId': p.projectId, 'iid': 3},
  ),
  paths: (p) => {
    'POST projects/${p.projectId}/merge_requests/3/'
        '${operation == 'approveMergeRequest' ? 'approve' : 'cancel_auto_merge'}',
  },
  readbackPaths: (p, _) => {'projects/${p.projectId}/merge_requests/3'},
  observe: (observer, p) async {
    await observer.read('projects/${p.projectId}/merge_requests/3');
    return false;
  },
);

Mr7Scenario _variant(
  Mr7Scenario base,
  String suffix, {
  AiToolCall Function(Mr7Identity)? call,
  Set<String> Function(Mr7Identity)? paths,
  Future<bool> Function(Mr7Readback, Mr7Identity)? observe,
}) => Mr7Scenario(
  id: '${base.id}-$suffix',
  suite: base.suite,
  operation: base.operation,
  variant: suffix,
  tier: base.tier,
  targetKind: base.targetKind,
  utterance: base.utterance,
  resource: base.resource,
  call: call ?? base.call,
  paths: paths ?? base.paths,
  readbackPaths: base.readbackPaths,
  observe: observe ?? base.observe,
  expectedMutations: base.expectedMutations,
);

Mr7Scenario _draftScenario(String variant) => Mr7Scenario(
  id: 'b3-publishDraftNotes-$variant',
  suite: 'advanced',
  operation: 'publishDraftNotes',
  variant: variant,
  tier: 'T3',
  targetKind: AiTargetKind.mergeRequest,
  utterance: (p) => 'Publish all synthetic drafts on !3 in ${p.path}.',
  resource: (_) =>
      const AiResourceRef(kind: AiResourceKind.mergeRequest, id: 3),
  call: (p) => AiToolCall(
    id: 'b3-publishDraftNotes-$variant',
    name: 'publishDraftNotes',
    arguments: {'projectId': p.projectId, 'iid': 3},
  ),
  paths: (p) => {
    'POST projects/${p.projectId}/merge_requests/3/draft_notes/bulk_publish',
  },
  readbackPaths: (p, _) => {
    'projects/${p.projectId}/merge_requests/3/draft_notes',
  },
  observe: (observer, p) async {
    // This deliberately exercises the documented observer seam: a 204 has
    // no numeric returned resource ID, and a complete list is not a record.
    await observer.read('projects/${p.projectId}/merge_requests/3/draft_notes');
    return true;
  },
);

Future<Map<String, Object?>> _run(
  List<Mr7Scenario> scenarios, {
  Mr7SyntheticGitLab? server,
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
  Mr7Policy policy = Mr7Policy.candidate,
  Mr7Confirm? confirm,
  Mr7TypedConfirm? typedConfirm,
}) => runMr7Sandbox(
  releaseSha: _sha,
  policy: policy,
  suite: 'advanced',
  scenarios: scenarios,
  session: Mr7SandboxSession(
    server: server ?? Mr7SyntheticGitLab(),
    nonce: 'advancednonce',
    requestCap: 400,
    eventDelay: () async {},
  ),
  level: level,
  confirm: confirm ?? (_) async => true,
  // This is an explicit synthetic-only input adapter, not a runner default.
  typedConfirm: typedConfirm ?? (proposal) async => proposal.requiredTypedName,
);

void _expectBoundary(Map<String, Object?> receipt, {bool cleanup = true}) {
  expect(receipt['transport'], 'synthetic');
  expect(receipt['live'], 'NOT_RUN');
  expect(receipt['finalEligible'], isFalse);
  expect(receipt['releaseSha'], _sha);
  expect(receipt['secretLeakScan'], 'PASS');
  expect(_part(receipt, 'events')['status'], 'PASS');
  expect(_part(receipt, 'events')['complete'], isTrue);
  expect(_part(receipt, 'events')['passes'], 2);
  final events = _part(receipt, 'events')['items']! as List;
  expect(events, isNotEmpty);
  expect(events.every((e) => (e as Map)['projectId'] == 909), isTrue);
  final writes = (receipt['requestLedger']! as List)
      .cast<Map<String, Object?>>();
  expect(writes.every((w) => w['projectId'] == 909), isTrue);
  expect(
    writes.every(
      (w) =>
          w['operation'] == 'harnessSetup' ||
          (w['path']! as String).startsWith('projects/909'),
    ),
    isTrue,
  );
  if (cleanup) {
    expect(receipt['quarantined'], isFalse);
    expect(_part(receipt, 'cleanup')['status'], 'PASS');
    expect(_part(receipt, 'cleanup')['accepted'], isTrue);
    expect(_part(receipt, 'cleanup')['deletionVerified'], isTrue);
    expect(_part(receipt, 'cleanup')['parentChecked'], isTrue);
  }
}

void main() {
  test(
    'production tier gates cover advanced escalation and retry exceptions',
    () {
      // Gate-only evidence: none of these decisions is an operation receipt or
      // substitutes for an unavailable target/observer seam.
      const vectors =
          <
            ({
              String op,
              AiTierFacts facts,
              Map<String, Object?> args,
              AiWriteTier tier,
              bool confirmOnly,
            })
          >[
            (
              op: 'updateSnippetMetadata',
              facts: AiTierFacts(),
              args: {},
              tier: AiWriteTier.t2,
              confirmOnly: false,
            ),
            (
              op: 'updateSnippetMetadata',
              facts: AiTierFacts(visibilityRaised: true),
              args: {},
              tier: AiWriteTier.hardLine,
              confirmOnly: false,
            ),
            (
              op: 'createSnippet',
              facts: AiTierFacts(newSnippetNotPrivate: true),
              args: {},
              tier: AiWriteTier.hardLine,
              confirmOnly: false,
            ),
            (
              op: 'edit_file',
              facts: AiTierFacts(),
              args: {},
              tier: AiWriteTier.t3,
              confirmOnly: false,
            ),
            (
              op: 'edit_file',
              facts: AiTierFacts(protectedOrDefaultBranch: true),
              args: {},
              tier: AiWriteTier.t4,
              confirmOnly: false,
            ),
            (
              op: 'edit_file',
              facts: AiTierFacts(touchesCiConfig: true),
              args: {},
              tier: AiWriteTier.hardLine,
              confirmOnly: false,
            ),
            (
              op: 'mergeRequest',
              facts: AiTierFacts(squash: true, triggersPipeline: true),
              args: {},
              tier: AiWriteTier.t3,
              confirmOnly: false,
            ),
            (
              op: 'mergeRequest',
              facts: AiTierFacts(protectedOrDefaultBranch: true),
              args: {},
              tier: AiWriteTier.t4,
              confirmOnly: false,
            ),
            (
              op: 'mergeRequest',
              facts: AiTierFacts(removeSourceBranch: true),
              args: {},
              tier: AiWriteTier.t4,
              confirmOnly: false,
            ),
            (
              op: 'mergeRequest',
              facts: AiTierFacts(touchesCiConfig: true),
              args: {},
              tier: AiWriteTier.hardLine,
              confirmOnly: false,
            ),
            (
              op: 'createTag',
              facts: AiTierFacts(),
              args: {},
              tier: AiWriteTier.t4,
              confirmOnly: false,
            ),
            (
              op: 'pipelineAction',
              facts: AiTierFacts(),
              args: {'action': 'cancel'},
              tier: AiWriteTier.t3,
              confirmOnly: false,
            ),
            (
              op: 'pipelineAction',
              facts: AiTierFacts(),
              args: {'action': 'retry'},
              tier: AiWriteTier.t4,
              confirmOnly: true,
            ),
            (
              op: 'jobAction',
              facts: AiTierFacts(),
              args: {'action': 'retry'},
              tier: AiWriteTier.t4,
              confirmOnly: true,
            ),
            (
              op: 'jobAction',
              facts: AiTierFacts(),
              args: {'action': 'play'},
              tier: AiWriteTier.t4,
              confirmOnly: true,
            ),
            (
              op: 'createPipeline',
              facts: AiTierFacts(),
              args: {},
              tier: AiWriteTier.t4,
              confirmOnly: false,
            ),
            (
              op: 'createPipeline',
              facts: AiTierFacts(pipelineVariables: true),
              args: {},
              tier: AiWriteTier.hardLine,
              confirmOnly: false,
            ),
            (
              op: 'playPipelineSchedule',
              facts: AiTierFacts(),
              args: {},
              tier: AiWriteTier.t4,
              confirmOnly: false,
            ),
            (
              op: 'playPipelineSchedule',
              facts: AiTierFacts(scheduleParamsUnsafe: true),
              args: {},
              tier: AiWriteTier.hardLine,
              confirmOnly: false,
            ),
            (
              op: 'editProject',
              facts: AiTierFacts(),
              args: {},
              tier: AiWriteTier.hardLine,
              confirmOnly: false,
            ),
            (
              op: 'deleteProject',
              facts: AiTierFacts(),
              args: {},
              tier: AiWriteTier.hardLine,
              confirmOnly: false,
            ),
          ];
      const expectedByTier = {
        AiWriteTier.t2: [
          AiGateDecision.deny,
          AiGateDecision.requireApproval,
          AiGateDecision.requireApproval,
          AiGateDecision.execute,
          AiGateDecision.execute,
        ],
        AiWriteTier.t3: [
          AiGateDecision.deny,
          AiGateDecision.requireApproval,
          AiGateDecision.requireApproval,
          AiGateDecision.execute,
          AiGateDecision.execute,
        ],
        AiWriteTier.t4: [
          AiGateDecision.deny,
          AiGateDecision.requireApproval,
          AiGateDecision.requireApproval,
          AiGateDecision.requireApproval,
          AiGateDecision.execute,
        ],
        AiWriteTier.hardLine: [
          AiGateDecision.deny,
          AiGateDecision.requireApproval,
          AiGateDecision.requireApproval,
          AiGateDecision.requireApproval,
          AiGateDecision.requireApproval,
        ],
      };
      for (final vector in vectors) {
        for (final level in AiAutonomyLevel.values) {
          final capability = productionAiLedger.find(vector.op)!;
          final decision = decideTier(
            AiTierInput(
              level: level,
              capability: capability,
              scope: const AiWriteScope(
                accountKey: 'https://gitlab.invalid/install#7',
                grants: [
                  AiScopeGrant(
                    kind: AiScopeKind.project,
                    projectId: 909,
                    projectPath: 'synthetic-owner/mr7-advancednonce',
                  ),
                ],
              ),
              binding: const AiBindingResult(
                userMessage: 'Synthetic fixture request',
                allBound: true,
                intentAuthorizesLowRisk: true,
              ),
              target: AiTargetRef(
                kind: aiWriteProposalTargetKind(capability),
                origin: AiTargetOrigin.currentResource,
                projectId: 909,
                iid: 3,
              ),
              facts: vector.facts,
              arguments: vector.args,
              typedName: 'synthetic target',
            ),
          );
          final label =
              '${vector.op} ${vector.tier} ${level.name} ${vector.args}';
          expect(decision.tier, vector.tier, reason: label);
          expect(
            decision.decision,
            expectedByTier[vector.tier]![level.index],
            reason: label,
          );
          expect(
            decision.requiresTypedName,
            decision.decision == AiGateDecision.requireApproval &&
                (vector.tier == AiWriteTier.hardLine ||
                    vector.tier == AiWriteTier.t4 && !vector.confirmOnly),
            reason: label,
          );
          if (vector.confirmOnly && level != AiAutonomyLevel.readOnly) {
            expect(decision.reusesStoredVariables, isTrue, reason: label);
          }
        }
      }
    },
  );

  test('enumerates the seven 7B3 ledger families and exclusions', () {
    final expected = {
      for (final row in [
        ...aiFileRows,
        ...aiRefRows,
        ...aiMergeRows,
        ...aiCiRows,
        ...aiSnippetRows,
        ...aiProjectRows,
        ...aiDeleteRows,
      ])
        row.operationId,
    };
    expect(_cases.map((c) => c.operation).toSet(), expected);
    expect(_cases.map((c) => c.id).toSet().length, _cases.length);
    expect(mr7AdvancedOwnedRows, {8, 9, 18, 20, 26, 30, 31, 32});
    for (final c in _cases) {
      expect(c.preconditions, contains('synthetic'), reason: c.id);
      expect(c.chain, hasLength(4), reason: c.id);
      expect(c.chain.every((s) => s.isNotEmpty), isTrue, reason: c.id);
      expect(c.confirmation, contains('host confirmation'), reason: c.id);
      expect(c.isolation, contains('two-pass'), reason: c.id);
      expect(c.cleanup, isNotEmpty, reason: c.id);
      expect(c.notRun, contains('Live NOT_RUN'), reason: c.id);
      expect(
        (c.scenario == null) != (c.closedReason == null),
        isTrue,
        reason: c.id,
      );
      if (c.scenario case final scenario?) {
        expect(scenario.id, c.id);
        expect(scenario.operation, c.operation);
        expect(scenario.tier, c.tier);
        expect(scenario.maxMutations, 1);
        expect(scenario.expectedMutations, 1);
      }
    }
    expect(
      mr7AdvancedScenarios().length,
      _cases.where((c) => c.scenario != null).length,
    );
  });

  test('binding plan variants remain explicit even without observer seams', () {
    final required = <String, Set<String>>{
      'mergeRequest': {
        'default-target',
        'protected-target',
        'squash',
        'auto-merge',
        'ci-default',
        'ci-custom',
        'closing-issues',
        'source-branch-removal',
        'head-drift',
        'diff-snapshot-drift',
        'ci-config-drift',
        'fork-source',
      },
      'approveMergeRequest': {
        'sha-bound',
        'head-drift',
        'approval-unavailable',
        'protected-approval-escalation',
      },
      'publishDraftNotes': {
        'whole-batch',
        'external-drafts',
        'batch-20',
        'batch-21-refused',
        'unsafe-last-draft',
        'batch-cas-drift',
      },
      'playPipelineSchedule': {
        'empty-parameters',
        'stored-variables',
        'stored-inputs',
        'unreadable-parameters',
        'hmac-drift',
        'schedule-unavailable',
      },
      'createSnippet': {
        'private-project',
        'new-nonprivate',
        'personal-excluded',
        'cross-nonce-provenance',
      },
      'updateSnippetFiles': {
        'exact-edit',
        'file-set-cas-drift',
        'provenance',
        'create-file',
        'move-file',
        'update-file',
        'personal-excluded',
      },
      'editProject': {
        'name',
        'description',
        'omitted-field-cas-drift',
        'protection-refused',
        'transfer-refused',
      },
      'deleteProject': {
        'terminal-deleted',
        'retention-pending',
        'ambiguous-404',
      },
    };
    for (final entry in required.entries) {
      expect(
        _cases.where((c) => c.operation == entry.key).map((c) => c.variant),
        containsAll(entry.value),
        reason: entry.key,
      );
    }
    for (final op in [
      'edit_file',
      'createFile',
      'deleteFile',
      'applySuggestion',
    ]) {
      expect(
        _cases.where((c) => c.operation == op).map((c) => c.variant),
        containsAll([
          'ordinary-ref',
          'default-ref',
          'protected-ref',
          'cas-drift',
          'ci-config',
          'same-field-upload-roundtrip',
          'cross-nonce-provenance',
        ]),
      );
    }
  });

  test(
    'production receipts keep every advanced variant closed with zero writes',
    () async {
      final server = Mr7SyntheticGitLab();
      var confirms = 0;
      final receipt = await _run(
        [for (final c in _cases) c.scenario ?? c.closedReceiptScenario],
        server: server,
        policy: Mr7Policy.production,
        confirm: (_) async {
          confirms++;
          return true;
        },
      );
      expect(receipt['status'], 'PASS');
      expect(_rows(receipt), hasLength(_cases.length));
      for (final row in _rows(receipt)) {
        expect(row['status'], 'NOT_RUN', reason: '${row['id']}');
        expect(row['reason'], 'releaseClosed');
        expect(row['mutationCount'], 0);
        expect(row['live'], 'NOT_RUN');
      }
      expect(server.scenarioWrites, 0);
      expect(confirms, 0);
      _expectBoundary(receipt);
    },
  );

  test('closed candidate refuses before provider creation', () async {
    final server = Mr7SyntheticGitLab();
    final fixture = Mr7AdvancedFixture(server);
    var confirmations = 0;
    final receipt = await _run(
      [_case('createBranch', 'ordinary-ref').closedReceiptScenario],
      server: server,
      confirm: (_) async {
        confirmations++;
        return true;
      },
    );
    final row = _rows(receipt).single;
    expect(row['status'], 'NOT_RUN');
    expect(row['mutationCount'], 0);
    expect(row.containsKey('provider'), isFalse);
    expect(row.containsKey('fixtureDigest'), isFalse);
    expect(confirmations, 0);
    expect(fixture.mutations, isEmpty);
    expect(server.scenarioWrites, 0);
    expect(server.cleanupWrites, 0);
    expect(receipt['quarantined'], isTrue);
    expect(receipt['stopReason'], 'runUnverified');
  });

  for (final variant in ['name', 'description']) {
    for (final level in AiAutonomyLevel.values) {
      test(
        'editProject $variant stays NOT_RUN at ${level.name} without a snapshot seam',
        () async {
          final c = _case('editProject', variant);
          expect(c.scenario, isNull);
          expect(c.closedReason, contains('pre-write name/description'));
          expect(c.closedReason, contains('preread receipt metadata'));
          final server = Mr7SyntheticGitLab();
          final fixture = Mr7AdvancedFixture(server);
          var confirmations = 0;
          final receipt = await _run(
            [c.closedReceiptScenario],
            server: server,
            level: level,
            confirm: (_) async {
              confirmations++;
              return true;
            },
          );
          expect(_rows(receipt).single['status'], 'NOT_RUN');
          expect(_rows(receipt).single['mutationCount'], 0);
          expect(_rows(receipt).single.containsKey('provider'), isFalse);
          expect(confirmations, 0);
          expect(fixture.mutations, isEmpty);
          expect(server.scenarioWrites, 0);
          expect(server.cleanupWrites, 0);
          expect(receipt['quarantined'], isTrue);
        },
      );
    }
  }

  for (final c in _cases.where((c) => c.scenario != null)) {
    test(
      '${c.id} proves API confirm write independent readback receipt',
      () async {
        final server = Mr7SyntheticGitLab();
        final fixture = Mr7AdvancedFixture(server, variant: c.variant);
        final proposals = <Mr7HostProposal>[];
        final receipt = await _run(
          [c.scenario!],
          server: server,
          confirm: (p) async {
            expect(fixture.mutations, isEmpty);
            expect(server.requests, contains('GET projects/909'));
            expect(
              server.requests,
              contains('GET projects/synthetic-owner/mr7-advancednonce'),
            );
            proposals.add(p);
            return true;
          },
        );
        final row = _rows(receipt).single;
        expect(row['status'], 'PASS', reason: jsonEncode(receipt));
        expect(receipt['status'], 'PASS');
        expect(row['outcome'], 'succeeded');
        expect(row['mutationCount'], 1);
        expect(row['readback'], 'PASS');
        expect(row['observerRequests'], greaterThan(0));
        expect(row['fixtureDigest'], matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(row['payloadDigest'], matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(row['preread'], isA<Map<String, Object?>>());
        expect(
          DateTime.parse(
            row['confirmAt']! as String,
          ).isBefore(DateTime.parse(row['proposalAt']! as String)),
          isFalse,
        );
        expect(_part(row, 'provider')['protocol'], 'responses');
        expect(_part(row, 'provider')['secretLeakScan'], 'PASS');
        expect(proposals, hasLength(1));
        final typed =
            c.tier == 'hardLine' ||
            (c.tier == 'T4' && !['retry', 'play'].contains(c.variant));
        expect(proposals.single.requiredTypedName != null, typed);
        if (typed) expect(row['typedInputMatches'], isTrue);
        expect(fixture.mutations, hasLength(1));
        expect(server.scenarioWrites, 1);
        if (['pipelineAction', 'jobAction'].contains(c.operation)) {
          expect(fixture.mutations.single.data, isEmpty);
          expect(
            server.requests.any(
              (p) => p.contains('/variables') || p.contains('/inputs'),
            ),
            isFalse,
          );
        }
        if (c.operation == 'mergeRequest' ||
            c.operation == 'approveMergeRequest') {
          expect(
            (fixture.mutations.single.data as Map)['sha'],
            mr7AdvancedHead,
          );
        }
        _expectBoundary(receipt);
      },
    );
  }

  for (final c in _cases.where((c) => c.blockedScenario != null)) {
    test('${c.id} stays closed without a multi-kind release seam', () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server, variant: c.variant);
      var confirmations = 0;
      final receipt = await _run(
        [c.blockedScenario!],
        server: server,
        confirm: (_) async {
          confirmations++;
          return true;
        },
      );
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(confirmations, 0);
      expect(fixture.mutations, isEmpty);
      expect(c.closedReason, contains('per-scenario target-kind set'));
      _expectBoundary(receipt);
    });
  }

  test(
    'exported advanced list stays closed instead of passing an empty suite',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      final scenarios = mr7AdvancedScenarios();
      expect(scenarios, isEmpty);
      final receipt = await _run(scenarios, server: server);
      expect(_rows(receipt), isEmpty);
      expect(receipt['status'], 'FAIL');
      expect(receipt['reason'], 'noScenarios');
      expect(_part(receipt, 'coverage')['advanced'], 'NOT_RUN');
      expect(fixture.mutations, isEmpty);
      expect(server.scenarioWrites, 0);
    },
  );

  for (final pair in [
    ('approveMergeRequest', 'sha-bound'),
    ('cancelAutoMerge', 'current-endpoint'),
  ]) {
    for (final fault in [
      'iid',
      'missing-iid',
      'project_id',
      'original-id',
      'permission',
      'pre-existing-approval',
      'actor',
    ]) {
      test('${pair.$1} stays NOT_RUN for unproved $fault', () async {
        final server = Mr7SyntheticGitLab(userId: fault == 'actor' ? 8 : 7);
        final fixture = Mr7AdvancedFixture(server);
        if (fault == 'permission') {
          fixture.mr['user'] = {'can_merge': false};
        }
        if (fault == 'pre-existing-approval') {
          fixture.mr['approved_by'] = [
            {
              'user': {'id': 7},
            },
          ];
        }
        server.routes['GET projects/909/merge_requests/3'] = (_) {
          final row = {...fixture.mr};
          if (fault == 'original-id' && fixture.mutations.isEmpty) {
            row['id'] = 34;
          }
          if (fixture.mutations.isNotEmpty) {
            if (fault == 'iid') row['iid'] = 4;
            if (fault == 'missing-iid') row.remove('iid');
            if (fault == 'project_id') row['project_id'] = 777;
          }
          return mr7Json(row);
        };
        final c = _case(pair.$1, pair.$2);
        expect(c.scenario, isNull);
        expect(c.closedReason, contains('original pre-read MR numeric ID'));
        expect(c.closedReason, contains('preread receipt metadata'));
        var confirmations = 0;
        final receipt = await runMr7Sandbox(
          releaseSha: _sha,
          policy: Mr7Policy.candidate,
          suite: 'advanced',
          scenarios: [c.scenario ?? c.closedReceiptScenario],
          session: Mr7SandboxSession(
            server: server,
            expectedUserId: server.userId,
            nonce: 'advancednonce',
            requestCap: 400,
            eventDelay: () async {},
          ),
          confirm: (_) async {
            confirmations++;
            return true;
          },
          typedConfirm: (p) async => p.requiredTypedName,
        );
        expect(_rows(receipt).single['status'], 'NOT_RUN');
        expect(_rows(receipt).single['mutationCount'], 0);
        expect(_rows(receipt).single.containsKey('provider'), isFalse);
        expect(confirmations, 0);
        expect(fixture.mutations, isEmpty);
        expect(server.scenarioWrites, 0);
        expect(server.cleanupWrites, 0);
      });
    }
  }

  test(
    'negative MR probe reads independently and never reports operation PASS',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      final receipt = await _run([
        _mrRefusalProbe('cancelAutoMerge'),
      ], server: server);
      final row = _rows(receipt).single;
      expect(row['outcome'], 'succeeded');
      expect(row['status'], 'NOT_VERIFIED');
      expect(row['readback'], 'NOT_VERIFIED');
      expect(row['observerRequests'], 1);
      expect(row['preread'], isA<Map<String, Object?>>());
      expect(fixture.mutations, hasLength(1));
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
      _expectBoundary(receipt, cleanup: false);
    },
  );

  test(
    '409 no-change stays closed when independent observation is unavailable',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      const path = 'POST projects/909/merge_requests/3/cancel_auto_merge';
      server.routes[path] = (_) => mr7Json(const {}, status: 409);
      final receipt = await _run([
        _mrRefusalProbe('cancelAutoMerge'),
        _mrRefusalProbe('approveMergeRequest'),
      ], server: server);
      expect(_rows(receipt).first['outcome'], 'succeeded');
      expect(_rows(receipt).first['status'], 'NOT_VERIFIED');
      expect(_rows(receipt).first['mutationCount'], 1);
      expect(_rows(receipt).last['reason'], 'sessionStopped');
      expect(server.requests.where((r) => r == path), hasLength(1));
      expect(fixture.mutations, isEmpty);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  for (final level in AiAutonomyLevel.values) {
    for (final pair in [
      ('approveMergeRequest', 'sha-bound'),
      ('cancelAutoMerge', 'current-endpoint'),
    ]) {
      test(
        'negative probe autonomy ${level.name} ${pair.$1} keeps product confirmation',
        () async {
          final c = _case(pair.$1, pair.$2);
          final server = Mr7SyntheticGitLab();
          final fixture = Mr7AdvancedFixture(server);
          final proposals = <Mr7HostProposal>[];
          final receipt = await _run(
            [_mrRefusalProbe(c.operation)],
            server: server,
            level: level,
            confirm: (p) async {
              proposals.add(p);
              return true;
            },
          );
          final row = _rows(receipt).single;
          if (level == AiAutonomyLevel.readOnly) {
            expect(row['status'], 'NOT_RUN');
            expect(row['mutationCount'], 0);
            expect(proposals, isEmpty);
          } else {
            expect(row['status'], 'NOT_VERIFIED', reason: jsonEncode(receipt));
            expect(row['mutationCount'], 1);
            expect(proposals, hasLength(1));
            final productTyped =
                c.tier == 'hardLine' ||
                (c.tier == 'T4' &&
                    c.variant != 'retry' &&
                    c.variant != 'play' &&
                    level != AiAutonomyLevel.bypass);
            expect(proposals.single.requiredTypedName != null, productTyped);
            expect(fixture.mutations, hasLength(1));
          }
          _expectBoundary(receipt, cleanup: level == AiAutonomyLevel.readOnly);
        },
      );
    }
  }

  test('host refusal keeps advanced writes zero even in bypass', () async {
    final server = Mr7SyntheticGitLab();
    final fixture = Mr7AdvancedFixture(server);
    final receipt = await _run(
      [_mrRefusalProbe('cancelAutoMerge')],
      server: server,
      level: AiAutonomyLevel.bypass,
      confirm: (_) async => false,
    );
    // The guard prevented the send, but production conservatively retains
    // uncertainty after its automatic execution entered the commit path.
    expect(_rows(receipt).single['status'], 'writeUncertain');
    expect(_rows(receipt).single['mutationCount'], 0);
    expect(fixture.mutations, isEmpty);
    expect(receipt['quarantined'], isTrue);
    expect(server.cleanupWrites, 0);
    _expectBoundary(receipt, cleanup: false);
  });

  test(
    'observer returning true without an independent GET cannot pass',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      final receipt = await _run([
        _variant(
          _mrRefusalProbe('cancelAutoMerge'),
          'empty-observer',
          observe: (_, _) async => true,
        ),
        _projectRefusalProbe('description'),
      ], server: server);
      expect(_rows(receipt).first['status'], 'NOT_VERIFIED');
      expect(_rows(receipt).first['observerRequests'], 0);
      expect(_rows(receipt).last['reason'], 'sessionStopped');
      expect(fixture.mutations, hasLength(1));
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  for (final drift in ['approval-head', 'omitted-project-name']) {
    test('$drift CAS change at confirmation refuses before dispatch', () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      final receipt = await _run(
        [
          drift == 'approval-head'
              ? _mrRefusalProbe('approveMergeRequest')
              : _projectRefusalProbe('description'),
        ],
        server: server,
        confirm: (_) async {
          if (drift == 'approval-head') {
            fixture.mr['sha'] = 'dddddddddddddddddddddddddddddddddddddddd';
          } else {
            server.project!['name'] = 'Concurrent synthetic name';
          }
          return true;
        },
      );
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(fixture.mutations, isEmpty);
      _expectBoundary(receipt);
    });
  }

  for (final size in [20, 21]) {
    test('whole draft batch $size uses production scan and cap', () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      fixture.drafts
        ..clear()
        ..addAll([
          for (var id = 1; id <= size; id++)
            {'id': id, 'note': 'Synthetic review $id'},
        ]);
      var confirms = 0;
      final receipt = await _run(
        [_draftScenario('batch-$size')],
        server: server,
        confirm: (p) async {
          confirms++;
          expect(p.requiredTypedName, isNull);
          return true;
        },
      );
      final row = _rows(receipt).single;
      expect(
        server.requests,
        contains('GET projects/909/merge_requests/3/draft_notes'),
      );
      if (size == 20) {
        expect(row['outcome'], 'succeeded', reason: jsonEncode(receipt));
        expect(row['mutationCount'], 1);
        expect(confirms, 1);
        expect(row['status'], 'NOT_VERIFIED');
        expect(row['readback'], 'NOT_VERIFIED');
        expect(server.cleanupWrites, 0);
        expect(receipt['quarantined'], isTrue);
      } else {
        expect(row['mutationCount'], 0);
        expect(row['status'], isNot('PASS'));
        expect(confirms, 0);
        expect(fixture.mutations, isEmpty);
        _expectBoundary(receipt);
      }
    });
  }

  for (final failure in ['last-draft-command', 'last-draft-cas-drift']) {
    test('whole batch $failure cannot write', () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      fixture.drafts
        ..clear()
        ..addAll([
          for (var id = 1; id <= 20; id++)
            {'id': id, 'note': 'Synthetic review $id'},
        ]);
      if (failure == 'last-draft-command') {
        fixture.drafts.last['note'] = '/close';
      }
      var confirms = 0;
      final receipt = await _run(
        [_draftScenario(failure)],
        server: server,
        confirm: (_) async {
          confirms++;
          if (failure == 'last-draft-cas-drift') {
            fixture.drafts.last['note'] = 'Concurrent synthetic review';
          }
          return true;
        },
      );
      final draftReads = server.requests.where(
        (r) => r == 'GET projects/909/merge_requests/3/draft_notes',
      );
      expect(
        draftReads.length,
        failure == 'last-draft-cas-drift'
            ? greaterThanOrEqualTo(2)
            : greaterThanOrEqualTo(1),
      );
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(confirms, failure == 'last-draft-command' ? 0 : 1);
      expect(fixture.mutations, isEmpty);
      _expectBoundary(receipt);
    });
  }

  test('wrong hardLine typed target causes zero writes', () async {
    final server = Mr7SyntheticGitLab();
    final fixture = Mr7AdvancedFixture(server);
    final receipt = await _run(
      [_projectRefusalProbe('description')],
      server: server,
      typedConfirm: (_) async => 'wrong-project',
    );
    expect(_rows(receipt).single['typedInputMatches'], isFalse);
    expect(_rows(receipt).single['mutationCount'], 0);
    expect(_rows(receipt).single['status'], isNot('PASS'));
    expect(fixture.mutations, isEmpty);
  });

  test(
    'lost advanced reply quarantines and stops all subsequent mutations',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server)..loseReply = true;
      final receipt = await _run([
        _mrRefusalProbe('cancelAutoMerge'),
        _projectRefusalProbe('description'),
      ], server: server);
      expect(_rows(receipt).first['status'], 'writeUncertain');
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(_rows(receipt).last['reason'], 'sessionStopped');
      expect(receipt['stopReason'], 'writeUncertain');
      expect(receipt['stoppedCount'], 1);
      expect(fixture.mutations, hasLength(1));
      expect(server.cleanupWrites, 0);
      expect(_part(receipt, 'cleanup')['status'], 'NOT_RUN');
      expect(receipt['quarantined'], isTrue);
      _expectBoundary(receipt, cleanup: false);
    },
  );

  test(
    'unverified independent observer stops subsequent writes without retry',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      var postWriteReads = 0;
      server.routes['GET projects/909/merge_requests/3'] = (_) {
        if (fixture.mutations.isNotEmpty && ++postWriteReads > 1) {
          return mr7Json({...fixture.mr, 'auto_merge_enabled': true});
        }
        return mr7Json(fixture.mr);
      };
      final receipt = await _run([
        _mrRefusalProbe('cancelAutoMerge'),
        _projectRefusalProbe('name'),
      ], server: server);
      expect(_rows(receipt).first['status'], 'NOT_VERIFIED');
      expect(_rows(receipt).first['readback'], 'NOT_VERIFIED');
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(fixture.mutations, hasLength(1));
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  test(
    'foreign event after an advanced write prevents next write and cleanup',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      const path = 'POST projects/909/merge_requests/3/cancel_auto_merge';
      final original = server.routes[path]!;
      server.routes[path] = (r) async {
        final reply = await original(r);
        server.addEvent(target: 777);
        return reply;
      };
      final receipt = await _run([
        _mrRefusalProbe('cancelAutoMerge'),
        _projectRefusalProbe('name'),
      ], server: server);
      expect(receipt['status'], 'FAIL');
      expect(_part(receipt, 'events')['status'], 'NOT_VERIFIED');
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(fixture.mutations, hasLength(1));
      expect(server.cleanupWrites, 0);
    },
  );

  test(
    'foreign target cannot be dispatched even with a sealed mutation path',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      final scenario = Mr7Scenario(
        id: 'b3-outside-sandbox',
        suite: 'advanced',
        operation: 'editProject',
        variant: 'foreign-project',
        tier: 'hardLine',
        targetKind: AiTargetKind.project,
        call: (_) => AiToolCall(
          id: 'b3-outside-sandbox',
          name: 'editProject',
          arguments: {
            'projectId': 777,
            'description': 'Synthetic foreign target',
          },
        ),
        paths: (_) => {'PUT projects/777'},
        observe: (_, _) async => false,
      );
      final receipt = await _run([scenario], server: server);
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(fixture.mutations, isEmpty);
      expect(server.requests.any((r) => r.contains('projects/777')), isFalse);
    },
  );

  test(
    'a foreign permit path cannot authorize a valid project write',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = Mr7AdvancedFixture(server);
      final receipt = await _run([
        _variant(
          _projectRefusalProbe('description'),
          'foreign-permit',
          paths: (_) => {'PUT projects/777'},
        ),
        _mrRefusalProbe('approveMergeRequest'),
      ], server: server);
      expect(_rows(receipt).first['status'], isNot('PASS'));
      expect(_rows(receipt).first['mutationCount'], 0);
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(_rows(receipt).last['reason'], 'sessionStopped');
      expect(fixture.mutations, isEmpty);
      expect(server.requests.any((r) => r.contains('projects/777')), isFalse);
    },
  );

  for (final field in ['protected_branches', 'namespaceId', 'visibility']) {
    test(
      'editProject refuses out-of-scope $field before confirmation',
      () async {
        final server = Mr7SyntheticGitLab();
        final fixture = Mr7AdvancedFixture(server);
        var confirmations = 0;
        final receipt = await _run(
          [
            _variant(
              _projectRefusalProbe('description'),
              'forbidden-$field',
              call: (p) => AiToolCall(
                id: 'forbidden-$field',
                name: 'editProject',
                arguments: {
                  'projectId': p.projectId,
                  'description': 'Synthetic project description',
                  field: 'forbidden synthetic value',
                },
              ),
            ),
          ],
          server: server,
          confirm: (_) async {
            confirmations++;
            return true;
          },
        );
        expect(_rows(receipt).single['status'], isNot('PASS'));
        expect(_rows(receipt).single['mutationCount'], 0);
        expect(confirmations, 0);
        expect(fixture.mutations, isEmpty);
        _expectBoundary(receipt);
      },
    );
  }
}
