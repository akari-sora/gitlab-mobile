import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import '../../tool/mr7/advanced_scenarios.dart';
import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart';

const _sha = '0123456789abcdef0123456789abcdef01234567';
final _cases = mr7AdvancedCases();
final _executable = _cases.where((c) => c.scenario != null).toList();
List<Map<String, Object?>> _rows(Map<String, Object?> receipt) =>
    (receipt['scenarios']! as List).cast<Map<String, Object?>>();
Map<String, Object?> _part(Map<String, Object?> receipt, String name) =>
    (receipt[name]! as Map).cast<String, Object?>();
Mr7AdvancedCase _case(String op, String variant) =>
    _cases.singleWhere((c) => c.operation == op && c.variant == variant);
Mr7Scenario _scenario(String op, String variant) =>
    _case(op, variant).scenario!;

Mr7Scenario _copy(
  Mr7Scenario b, {
  AiToolCall Function(Mr7Identity)? call,
  Set<String> Function(Mr7Identity)? paths,
  Future<bool> Function(Mr7Readback, Mr7Identity)? observe,
  Future<Mr7ScenarioFixtures> Function(Mr7SandboxSession, Mr7Identity)? fixture,
  bool withoutNoChange = false,
}) => Mr7Scenario(
  id: b.id,
  suite: b.suite,
  operation: b.operation,
  variant: b.variant,
  tier: b.tier,
  targetKind: b.targetKind,
  targetKinds: b.targetKinds,
  call: call ?? b.call,
  paths: paths ?? b.paths,
  observe: observe ?? b.observe,
  fixture: fixture ?? b.fixture,
  preRead: b.preRead,
  utterance: b.utterance,
  resource: b.resource,
  freshness: b.freshness,
  readNames: b.readNames,
  readbackPaths: b.readbackPaths,
  maxMutations: b.maxMutations,
  expectedMutations: b.expectedMutations,
  noChangeObservation: withoutNoChange ? null : b.noChangeObservation,
);

Future<Map<String, Object?>> _run(
  List<Mr7Scenario> scenarios, {
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
  Mr7Confirm? confirm,
  Mr7TypedConfirm? typedConfirm,
  Mr7Edit? editConfirm,
  List<Mr7ClosedVariant> closed = const [],
  String? fixtureVariant,
  void Function(Mr7SandboxSession, Mr7AdvancedFixture)? configure,
}) async {
  final server = Mr7SyntheticGitLab();
  final fixture = Mr7AdvancedFixture(
    server,
    operation: scenarios.isEmpty ? '' : scenarios.first.operation,
    variant:
        fixtureVariant ??
        (scenarios.isEmpty ? 'ordinary' : scenarios.first.variant),
  );
  final session = Mr7SandboxSession(
    server: server,
    nonce: 'advancednonce',
    requestCap: 400,
    eventDelay: () async {},
  );
  configure?.call(session, fixture);
  return runMr7Sandbox(
    releaseSha: _sha,
    policy: Mr7Policy.candidate,
    suite: 'advanced',
    session: session,
    scenarios: scenarios,
    closedVariants: closed,
    level: level,
    confirm: confirm ?? (_) async => true,
    typedConfirm: typedConfirm ?? (p) async => p.requiredTypedName,
    editConfirm:
        editConfirm ??
        (p) async => p.editableField == null ? null : mr7AdvancedEditedText,
  );
}

void _boundary(
  Map<String, Object?> receipt, {
  bool cleanup = true,
  bool terminal = false,
}) {
  expect(receipt['transport'], 'synthetic');
  expect(receipt['policy'], 'candidate');
  expect(receipt['evidenceClass'], 'CANDIDATE_ONLY');
  expect(receipt['live'], 'NOT_RUN');
  expect(receipt['finalEligible'], isFalse);
  expect(receipt['secretLeakScan'], 'PASS');
  expect(_part(receipt, 'events')['status'], 'PASS');
  expect(_part(receipt, 'events')['complete'], isTrue);
  expect(_part(receipt, 'events')['passes'], 2);
  expect(
    (_part(receipt, 'events')['items']! as List).every(
      (e) => (e as Map)['projectId'] == 909,
    ),
    isTrue,
  );
  expect(
    (receipt['requestLedger']! as List).every(
      (w) => (w as Map)['projectId'] == 909,
    ),
    isTrue,
  );
  expect(receipt['quarantined'], !cleanup);
  if (terminal) {
    // The AI deletion was the terminal case: the finalizer never re-deletes
    // and never supplies deletion evidence.
    expect(_part(receipt, 'cleanup'), {
      'status': 'NOT_RUN',
      'accepted': false,
      'deletionVerified': false,
      'reason': 'terminalScenario',
    });
    return;
  }
  expect(_part(receipt, 'cleanup')['status'], cleanup ? 'PASS' : 'NOT_RUN');
  if (cleanup) {
    expect(_part(receipt, 'cleanup')['deletionVerified'], isTrue);
    expect(_part(receipt, 'cleanup')['parentChecked'], isTrue);
  }
}

void _notVerified(Map<String, Object?> receipt) {
  expect(
    _rows(receipt).first['status'],
    isNot('PASS'),
    reason: jsonEncode(receipt),
  );
  expect(receipt['status'], 'FAIL');
  expect(receipt['quarantined'], isTrue);
  expect(_part(receipt, 'cleanup')['status'], 'NOT_RUN');
}

bool _afterWrite(Response<dynamic> r, Mr7AdvancedFixture fixture) =>
    fixture.mutations.isNotEmpty &&
    r.requestOptions.uri.path.contains('/projects/909');

// A negative probe exercises the production bulk scan without promoting draft
// absence into evidence that the corresponding public notes were published.
Mr7Scenario _draftProbe(String variant) => Mr7Scenario(
  id: 'b3-publishDraftNotes-probe-$variant',
  suite: 'advanced',
  operation: 'publishDraftNotes',
  variant: variant,
  tier: 'T3',
  targetKind: AiTargetKind.mergeRequest,
  utterance: (p) => 'Publish all synthetic drafts on !3 in ${p.path}.',
  resource: (_) =>
      const AiResourceRef(kind: AiResourceKind.mergeRequest, id: 3),
  call: (p) => AiToolCall(
    id: 'b3-publishDraftNotes-probe-$variant',
    name: 'publishDraftNotes',
    arguments: {'projectId': p.projectId, 'iid': 3},
  ),
  paths: (p) => {
    'POST projects/${p.projectId}/merge_requests/3/draft_notes/bulk_publish',
  },
  readbackPaths: (p, _) => {
    'projects/${p.projectId}/merge_requests/3',
    'projects/${p.projectId}/merge_requests/3/draft_notes',
  },
  observe: (observer, _) async {
    await observer.observe(
      Mr7ListObservation(
        parent: const Mr7Parent.mergeRequest(id: 33, iid: 3),
        kind: Mr7ListKind.draftNotes,
        expectedIds: {},
      ),
    );
    return false;
  },
);

Future<AiTierDecision> _preparedDecision(
  Mr7AdvancedCase c,
  Mr7SandboxSession session,
  AiAutonomyLevel level,
) async {
  final p = session.identity!;
  final scope = AiWriteScope(
    accountKey: '${session.instance}#7',
    grants: [
      AiScopeGrant(
        kind: AiScopeKind.project,
        projectId: p.projectId,
        projectPath: p.path,
      ),
    ],
  );
  final port = GitLabAiWritePort(
    GitLabApi(
      instance: GitLabInstance.parse(session.instance.toString()),
      token: 'synthetic-gitlab-pat',
      dio: session.writer,
      cdnAdapter: session.writerAdapter,
    ),
    accountKey: scope.accountKey,
  );
  final call = c.scenario!.call(p);
  final arguments = Map<String, Object?>.from(call.arguments! as Map);
  final prepared = await port.prepare(
    AiWriteRequest(
      operationId: c.operation,
      executionId: c.id,
      scope: scope,
      arguments: arguments,
    ),
  );
  return decideTier(
    AiTierInput(
      level: level,
      capability: productionAiLedger.find(c.operation)!,
      scope: scope,
      binding: const AiBindingResult(
        userMessage: 'Explicit synthetic fixture binding',
        allBound: true,
        intentAuthorizesLowRisk: true,
      ),
      target: prepared.bindingTargets.first,
      facts: prepared.facts,
      arguments: arguments,
      typedName: prepared.confirmName,
    ),
  );
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

  test('catalogue preserves all 185 variants and typed closed identity', () {
    expect(_cases, hasLength(185));
    expect(_cases.map((c) => c.id).toSet(), hasLength(_cases.length));
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
    expect(mr7AdvancedOwnedRows, {8, 9, 18, 20, 26, 30, 31, 32});
    expect(mr7AdvancedScenarios(), hasLength(_executable.length));
    for (final c in _cases) {
      expect(c.chain, hasLength(4), reason: c.id);
      expect(c.notRun, contains('Live NOT_RUN'), reason: c.id);
      expect((c.scenario == null) != (c.refusal == null), isTrue, reason: c.id);
      if (c.scenario case final scenario?) {
        expect(scenario.allowedTargetKinds, contains(scenario.targetKind));
        expect(
          scenario.allowedTargetKinds,
          contains(
            aiWriteProposalTargetKind(productionAiLedger.find(c.operation)!),
          ),
        );
      } else {
        expect(
          c.closedVariant.refusal.code,
          matches(RegExp(r'^[A-Za-z][A-Za-z0-9]{0,63}$')),
        );
        expect(c.closedReason, isNotEmpty);
      }
    }
  });

  test('wave 3c opens 15 variants: 44 executable and 141 closed', () {
    expect(_executable, hasLength(44));
    expect(_cases.length - _executable.length, 141);
    final reopened = {
      for (final variant in [
        'ordinary-ref',
        'default-ref',
        'protected-ref',
        'ci-config',
      ]) ...{'b3-deleteFile-$variant', 'b3-applySuggestion-$variant'},
      'b3-deleteBoardList-owned-fixture',
      'b3-publishDraftNotes-whole-batch',
      'b3-publishDraftNotes-external-drafts',
      'b3-publishDraftNotes-batch-20',
      'b3-cancelAutoMerge-deprecated-fallback',
      'b3-deleteProject-terminal-deleted',
      'b3-createSnippet-new-nonprivate',
    };
    expect(reopened, hasLength(15));
    for (final id in reopened) {
      final c = _cases.singleWhere((c) => c.id == id);
      expect(c.scenario?.captureEffects, isTrue, reason: id);
      expect(c.tier, isIn(['T3', 'T4', 'hardLine']), reason: id);
    }
    // Variants a wave 3c witness cannot honestly cover keep a typed reason.
    const closed = {
      'b3-playPipelineSchedule-empty-parameters': (
        Mr7ClosureCause.observerUnavailable,
        'scheduleParametersUnproven',
      ),
      'b3-deleteProject-retention-pending': (
        Mr7ClosureCause.observerUnavailable,
        'retentionRenameUnbound',
      ),
      'b3-applySuggestion-suggestion-version': (
        Mr7ClosureCause.releasePolicy,
        'suggestionVersionRefused',
      ),
      'b3-deleteFile-same-field-upload-roundtrip': (
        Mr7ClosureCause.releasePolicy,
        'uploadFieldNotApplicable',
      ),
      'b3-applySuggestion-same-field-upload-roundtrip': (
        Mr7ClosureCause.releasePolicy,
        'uploadFieldNotApplicable',
      ),
      'b3-cancelAutoMerge-409-no-change': (
        Mr7ClosureCause.fixtureUnavailable,
        'noChangeFixtureUnproven',
      ),
      'b3-deletePackage-owned-registry-fixture': (
        Mr7ClosureCause.fixtureUnavailable,
        'registryFixtureUnavailable',
      ),
    };
    for (final entry in closed.entries) {
      final c = _cases.singleWhere((c) => c.id == entry.key);
      expect(c.scenario, isNull, reason: entry.key);
      expect(c.refusal!.cause, entry.value.$1, reason: entry.key);
      expect(c.refusal!.code, entry.value.$2, reason: entry.key);
    }
    // No closure still claims a seam that wave 3a or 3c delivered.
    for (final c in _cases.where((c) => c.scenario == null)) {
      expect(
        c.refusal!.code,
        isNot(
          isIn([
            'secondaryEffectObserverMissing',
            'publishedNotesUnbound',
            'legacyCancelObserverMissing',
            'terminalParentObserverMissing',
            'nonprivateContentObserverMissing',
            'schedulePipelineUnbound',
            'fileHeadReadNotSupported',
            'fragmentCheckerNotWired',
          ]),
        ),
        reason: c.id,
      );
    }
  });

  for (final c in _executable) {
    test('${c.id} proves API confirm write independent readback', () async {
      final proposals = <Mr7HostProposal>[];
      Mr7AdvancedFixture? fixture;
      final receipt = await _run(
        [c.scenario!],
        configure: (_, f) => fixture = f,
        confirm: (p) async {
          expect(fixture!.mutations, isEmpty);
          proposals.add(p);
          return true;
        },
      );
      final row = _rows(receipt).single;
      expect(
        row['status'],
        'PASS',
        reason: jsonEncode({
          'row': row,
          'requests': fixture!.server.requests,
          'stopReason': receipt['stopReason'],
        }),
      );
      expect(receipt['status'], 'PASS');
      expect(row['mutationCount'], c.scenario!.expectedMutations);
      expect(row['readback'], 'PASS');
      expect(row['observerRequests'], greaterThan(0));
      expect(row['fixtureDigest'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(row['payloadDigest'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(row['preread'], isA<Map<String, Object?>>());
      final editable =
          productionAiLedger.find(c.operation)!.editableField != null;
      expect(proposals, hasLength(editable ? 2 : 1));
      if (editable) {
        expect(
          proposals.last.payloadDigest,
          isNot(proposals.first.payloadDigest),
        );
        expect(_part(row, 'edit')['reason'], 'approvalRequired');
      }
      final typed =
          c.tier == 'hardLine' ||
          (c.tier == 'T4' && !['retry', 'play'].contains(c.variant));
      if (typed) expect(proposals.first.requiredTypedName, isNotNull);
      if (['retry', 'play'].contains(c.variant)) {
        expect(proposals.first.requiredTypedName, isNull);
      }
      if (typed) expect(row['typedInputMatches'], isTrue);
      expect(fixture!.mutations, hasLength(c.scenario!.expectedMutations));
      if (c.operation == 'mergeRequest') {
        expect(
          (fixture!.mutations.single.data! as Map)['squash'],
          c.variant == 'squash',
        );
        if (c.variant == 'squash') {
          expect(fixture!.mr['merge_commit_sha'], mr7AdvancedMergeCommit);
          expect(fixture!.mr['squash_commit_sha'], mr7AdvancedSquashCommit);
          expect(mr7AdvancedSquashCommit, isNot(mr7AdvancedMergeCommit));
        }
      }
      if (['pipelineAction', 'jobAction'].contains(c.operation)) {
        expect(fixture!.mutations.single.data, isEmpty);
      }
      if (c.operation == 'publishDraftNotes') {
        // The sandbox creates no draft in the conversation segment, so every
        // publication carries the production foreign-draft confirmation.
        expect(row['confirmationReasons'], ['foreignDraftsInPublish']);
        expect(fixture!.drafts, isEmpty);
      }
      expect(row['outcome'], 'succeeded');
      expect(
        fixture!.server.requests.any(
          (r) => r.contains('/variables') || r.contains('/inputs'),
        ),
        isFalse,
      );
      _boundary(receipt, terminal: c.operation == 'deleteProject');
    });

    test('${c.id} rejects an outside-sandbox observer', () async {
      final receipt = await _run(
        [c.scenario!],
        configure: (s, f) {
          s.observer.interceptors.add(
            InterceptorsWrapper(
              onResponse: (r, h) {
                final root = r.requestOptions.uri.path.endsWith(
                  '/projects/909',
                );
                final inventory = r.requestOptions.uri.path.endsWith(
                  '/users/7/projects',
                );
                if ((_afterWrite(r, f) &&
                        (!root || c.operation == 'editProject')) ||
                    (f.mutations.isNotEmpty && inventory)) {
                  if (r.data is Map) {
                    r.data = {...r.data as Map, 'project_id': 777};
                  } else if (r.data is List) {
                    r.data = [
                      {'id': 999, 'project_id': 777},
                    ];
                  }
                }
                h.next(r);
              },
            ),
          );
        },
      );
      _notVerified(receipt);
      expect(
        _rows(receipt).single['mutationCount'],
        c.scenario!.expectedMutations,
      );
    });
  }

  for (final c in _executable.where((c) => c.operation == 'mergeRequest')) {
    for (final field
        in c.variant == 'auto-merge'
            ? ['auto_merge_enabled']
            : [
                'state',
                'merge_commit_sha',
                if (c.variant == 'squash') 'squash_commit_sha',
              ]) {
      test(
        '${c.id} rejects incorrect $field with original identity and head',
        () async {
          var effectReads = 0;
          final receipt = await _run(
            [c.scenario!],
            configure: (s, f) {
              s.observer.interceptors.add(
                InterceptorsWrapper(
                  onResponse: (r, h) {
                    if (_afterWrite(r, f) &&
                        r.requestOptions.uri.path.endsWith(
                          '/merge_requests/3',
                        )) {
                      final original = r.data! as Map;
                      expect(original['project_id'], 909);
                      expect(original['id'], 33);
                      expect(original['iid'], 3);
                      expect(original['sha'], mr7AdvancedHead);
                      r.data = {
                        ...original,
                        field: field == 'state'
                            ? 'opened'
                            : field == 'auto_merge_enabled'
                            ? false
                            : mr7AdvancedNextHead,
                      };
                      effectReads++;
                    }
                    h.next(r);
                  },
                ),
              );
            },
          );
          final row = _rows(receipt).single;
          expect(effectReads, greaterThan(0));
          expect(row['coreOutcome'], 'succeeded');
          expect(row['mutationCount'], 1);
          expect(row['status'], 'NOT_VERIFIED');
          _notVerified(receipt);
        },
      );
    }
  }

  test(
    'auto-merge proves a readable false to true transition after dispatch',
    () async {
      late Mr7SandboxSession session;
      late Mr7AdvancedFixture fixture;
      var preWriteReads = 0;
      final receipt = await _run(
        [_scenario('mergeRequest', 'auto-merge')],
        configure: (s, f) {
          session = s;
          fixture = f;
        },
        confirm: (_) async {
          expect(fixture.mutations, isEmpty);
          final before = await session.read('projects/909/merge_requests/3');
          expect(before['id'], 33);
          expect(before['iid'], 3);
          expect(before['project_id'], 909);
          expect(before['sha'], mr7AdvancedHead);
          expect(before['state'], 'opened');
          expect(before['auto_merge_enabled'], isFalse);
          preWriteReads++;
          return true;
        },
      );
      expect(preWriteReads, 1);
      expect(fixture.mutations, hasLength(1));
      expect((fixture.mutations.single.data! as Map)['auto_merge'], isTrue);
      expect(fixture.mr['auto_merge_enabled'], isTrue);
      expect(fixture.mr['state'], 'opened');
      final row = _rows(receipt).single;
      final saved = (_part(row, 'preread')['resources'] as List).single as Map;
      expect(
        (saved['fieldDigests'] as Map)['auto_merge_enabled'],
        mr7Digest({'present': true, 'value': false}),
      );
      expect(row['status'], 'PASS');
      _boundary(receipt);
    },
  );

  for (final initial in [true, null, 'false']) {
    test(
      'auto-merge refuses unreadable or already enabled precondition $initial',
      () async {
        var confirms = 0;
        final receipt = await _run(
          [_scenario('mergeRequest', 'auto-merge')],
          configure: (_, f) => f.mr['auto_merge_enabled'] = initial,
          confirm: (_) async {
            confirms++;
            return true;
          },
        );
        expect(confirms, 0);
        expect(_rows(receipt).single['mutationCount'], 0);
        expect(_rows(receipt).single.containsKey('provider'), isFalse);
        expect(receipt['stopReason'], 'runUnverified');
        _notVerified(receipt);
      },
    );
  }

  for (final enabledBeforeSnapshot in [false, true]) {
    test(
      enabledBeforeSnapshot
          ? 'auto-merge enabled between fixture and snapshot cannot prove a new effect'
          : 'auto-merge accepted without scheduling remains NOT_VERIFIED',
      () async {
        late Mr7AdvancedFixture fixture;
        final receipt = await _run(
          [_scenario('mergeRequest', 'auto-merge')],
          configure: (_, f) {
            fixture = f;
            if (enabledBeforeSnapshot) {
              final path = 'GET projects/909/merge_requests/3';
              final original = f.server.routes[path]!;
              var reads = 0;
              f.server.routes[path] = (r) async {
                if (++reads == 2) f.mr['auto_merge_enabled'] = true;
                return original(r);
              };
            }
            final route = 'PUT projects/909/merge_requests/3/merge';
            f.server.routes[route] = (r) {
              expect((r.data! as Map)['auto_merge'], isTrue);
              expect(f.mr['auto_merge_enabled'], enabledBeforeSnapshot);
              f.mutations.add(r);
              f.server.scenarioWrites++;
              f.server.addEvent(target: f.server.projectId);
              return mr7Json(f.mr);
            };
          },
        );
        expect(fixture.mutations, hasLength(1));
        expect(fixture.mr['auto_merge_enabled'], enabledBeforeSnapshot);
        final row = _rows(receipt).single;
        final saved =
            (_part(row, 'preread')['resources'] as List).single as Map;
        expect(
          (saved['fieldDigests'] as Map)['auto_merge_enabled'],
          mr7Digest({'present': true, 'value': enabledBeforeSnapshot}),
        );
        expect(row['coreOutcome'], 'succeeded');
        expect(row['status'], 'NOT_VERIFIED');
        _notVerified(receipt);
        _boundary(receipt, cleanup: false);
      },
    );
  }

  for (final squash in [null, false]) {
    test(
      'squash rejects HTTP dispatch with ${squash == null ? 'omitted' : 'false'} squash',
      () async {
        late Mr7AdvancedFixture fixture;
        var changedDispatches = 0;
        final receipt = await _run(
          [_scenario('mergeRequest', 'squash')],
          configure: (s, f) {
            fixture = f;
            s.writer.interceptors.add(
              InterceptorsWrapper(
                onRequest: (r, h) {
                  if (r.method == 'PUT' &&
                      r.uri.path.endsWith('/merge_requests/3/merge')) {
                    final body = Map<String, Object?>.from(r.data! as Map);
                    expect(body['squash'], isTrue);
                    if (squash == null) {
                      body.remove('squash');
                    } else {
                      body['squash'] = squash;
                    }
                    r.data = body;
                    changedDispatches++;
                  }
                  h.next(r);
                },
              ),
            );
          },
        );
        expect(changedDispatches, 1);
        expect(fixture.mutations, hasLength(1));
        final sent = fixture.mutations.single.data! as Map;
        expect(sent['squash'], squash);
        expect(sent.containsKey('squash'), squash != null);
        expect(fixture.mr['state'], 'merged');
        expect(fixture.mr['sha'], mr7AdvancedHead);
        expect(fixture.mr['merge_commit_sha'], mr7AdvancedMergeCommit);
        expect(fixture.mr['squash_commit_sha'], isNull);
        expect(_rows(receipt).single['coreOutcome'], 'succeeded');
        expect(_rows(receipt).single['status'], 'NOT_VERIFIED');
        _notVerified(receipt);
      },
    );
  }

  test(
    'observer returning true without an independent GET cannot pass',
    () async {
      final receipt = await _run([
        _copy(
          _scenario('createBranch', 'ordinary-ref'),
          observe: (_, _) async => true,
        ),
        _scenario('editProject', 'description'),
      ]);
      expect(_rows(receipt).first['status'], 'NOT_VERIFIED');
      expect(_rows(receipt).first['mutationCount'], 1);
      expect(_rows(receipt).first['observerRequests'], 0);
      expect(_rows(receipt).last['reason'], 'sessionStopped');
      _notVerified(receipt);
      _boundary(receipt, cleanup: false);
    },
  );

  test('candidate receipt contains every typed closed variant', () async {
    final receipt = await _run([
      _scenario('editProject', 'description'),
    ], closed: mr7AdvancedClosedVariants());
    expect(
      _rows(
        receipt,
      ).singleWhere((r) => r['classification'] != 'closedVariant')['status'],
      'PASS',
      reason: jsonEncode(receipt),
    );
    final closedRows = _rows(
      receipt,
    ).where((r) => r['classification'] == 'closedVariant').toList();
    expect(closedRows, hasLength(_cases.length - _executable.length));
    for (final row in closedRows) {
      final c = _cases.singleWhere((c) => c.id == row['id']);
      expect(row['suite'], 'advanced');
      expect(row['operation'], c.operation);
      expect(row['variant'], c.variant);
      expect(row['tier'], c.tier);
      expect(row['releaseSha'], _sha);
      expect(row['live'], 'NOT_RUN');
      expect(row['status'], 'NOT_RUN');
      expect(row['mutationCount'], 0);
      expect(row['providerCalls'], 0);
      expect(row['reason'], (row['refusal'] as Map)['code']);
      for (final field in ['outcome', 'coreOutcome']) {
        expect(!row.containsKey(field) || row[field] == 'notExecuted', isTrue);
      }
    }
    final inventory = Platform.environment['MR7_ADVANCED_INVENTORY'];
    if (inventory != null) {
      File(inventory).writeAsStringSync(
        jsonEncode([
          for (final c in _cases)
            {
              'id': c.id,
              'operation': c.operation,
              'variant': c.variant,
              'tier': c.tier,
              'executable': c.scenario != null,
              if (c.refusal != null) 'refusal': c.refusal!.metadata,
              if (c.closedReason != null) 'reason': c.closedReason,
            },
        ]),
      );
    }
    final path = Platform.environment['MR7_ADVANCED_RECEIPT'];
    if (path != null) File(path).writeAsStringSync(jsonEncode(receipt));
    _boundary(receipt);
  });

  test(
    'approval mismatch cannot be replaced by snapshot identity reads',
    () async {
      final receipt = await _run(
        [_scenario('approveMergeRequest', 'sha-bound')],
        configure: (s, f) {
          s.observer.interceptors.add(
            InterceptorsWrapper(
              onResponse: (r, h) {
                if (_afterWrite(r, f) &&
                    r.requestOptions.uri.path.endsWith('/approvals')) {
                  r.data = {
                    ...r.data as Map,
                    'approved': false,
                    'approved_by': <Object?>[],
                  };
                }
                h.next(r);
              },
            ),
          );
        },
      );
      _notVerified(receipt);
    },
  );

  test('approval witness from another project is refused', () async {
    final receipt = await _run(
      [_scenario('approveMergeRequest', 'sha-bound')],
      configure: (s, f) {
        s.observer.interceptors.add(
          InterceptorsWrapper(
            onResponse: (r, h) {
              if (_afterWrite(r, f) &&
                  r.requestOptions.uri.path.endsWith('/approvals')) {
                r.data = {...r.data as Map, 'project_id': 777};
              }
              h.next(r);
            },
          ),
        );
      },
    );
    _notVerified(receipt);
  });

  for (final field in ['name', 'description']) {
    test(
      'editProject $field detects an omitted field changed only in independent readback',
      () async {
        final omitted = field == 'name' ? 'description' : 'name';
        final receipt = await _run(
          [_scenario('editProject', field)],
          configure: (s, f) {
            s.observer.interceptors.add(
              InterceptorsWrapper(
                onResponse: (r, h) {
                  if (_afterWrite(r, f) &&
                      r.requestOptions.uri.path.endsWith('/projects/909')) {
                    r.data = {
                      ...r.data as Map,
                      omitted: 'Unexpected observer-only change',
                    };
                  }
                  h.next(r);
                },
              ),
            );
          },
        );
        expect(_rows(receipt).single['coreOutcome'], 'succeeded');
        expect(_rows(receipt).single['mutationCount'], 1);
        _notVerified(receipt);
      },
    );

    test(
      'editProject $field captures original field digests and identity',
      () async {
        final receipt = await _run([_scenario('editProject', field)]);
        final row = _rows(receipt).single;
        final snapshot = _part(row, 'preread');
        expect(snapshot['actorId'], 7);
        expect(snapshot['projectId'], 909);
        final resource = (snapshot['resources'] as List).single as Map;
        expect(resource['id'], 909);
        expect((resource['fieldDigests'] as Map).keys.toSet(), {
          'name',
          'description',
        });
        expect(resource['unchangedFields'], [
          field == 'name' ? 'description' : 'name',
        ]);
        expect(row['snapshotVerified'], isTrue);
        expect(jsonEncode(snapshot), isNot(contains('Original description')));
      },
    );
  }

  for (final op in ['approveMergeRequest', 'cancelAutoMerge']) {
    final variant = op == 'approveMergeRequest'
        ? 'sha-bound'
        : 'current-endpoint';
    test('$op binds the original global ID independently of iid', () async {
      final receipt = await _run(
        [_scenario(op, variant)],
        configure: (s, f) {
          s.observer.interceptors.add(
            InterceptorsWrapper(
              onResponse: (r, h) {
                if (_afterWrite(r, f) &&
                    r.requestOptions.uri.path.endsWith('/merge_requests/3')) {
                  r.data = {...r.data as Map, 'id': 34};
                }
                h.next(r);
              },
            ),
          );
        },
      );
      _notVerified(receipt);
    });
    test(
      '$op refuses an unproved precondition before provider dispatch',
      () async {
        final receipt = await _run(
          [_scenario(op, variant)],
          configure: (_, f) {
            if (op == 'approveMergeRequest') {
              f.mr['approved_by'] = [
                {
                  'user': {'id': 7},
                },
              ];
            } else {
              f.mr['user'] = {'can_merge': false};
            }
          },
        );
        expect(_rows(receipt).single['mutationCount'], 0);
        expect(_rows(receipt).single.containsKey('provider'), isFalse);
        _notVerified(receipt);
      },
    );
  }

  for (final variant in ['default-ref', 'protected-ref']) {
    test('deleteBranch refuses $variant before confirmation', () async {
      var confirms = 0;
      final receipt = await _run(
        [_scenario('deleteBranch', 'ordinary-ref')],
        fixtureVariant: variant,
        confirm: (_) async {
          confirms++;
          return true;
        },
      );
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(confirms, 0);
    });
  }

  for (final c in _executable.where(
    (c) =>
        c.tier == 'hardLine' ||
        c.tier == 'T4' && !['retry', 'play'].contains(c.variant),
  )) {
    test('${c.id} requires the exact typed target', () async {
      final receipt = await _run([
        c.scenario!,
      ], typedConfirm: (_) async => 'wrong-target');
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(_rows(receipt).single['typedInputMatches'], isFalse);
    });
  }

  for (final c in [
    _case('createTag', 'ordinary-ref'),
    _case('mergeRequest', 'ordinary'),
    _case('mergeRequest', 'ci-default'),
    _case('mergeRequest', 'ci-custom'),
    _case('mergeRequest', 'default-target'),
    _case('mergeRequest', 'protected-target'),
    _case('pipelineAction', 'cancel'),
    _case('jobAction', 'cancel'),
    _case('jobAction', 'retry'),
    _case('jobAction', 'play'),
    _case('pipelineAction', 'retry'),
    _case('editProject', 'description'),
  ]) {
    for (final level in AiAutonomyLevel.values) {
      test('${c.id} keeps product and host gates at ${level.name}', () async {
        final proposals = <Mr7HostProposal>[];
        final receipt = await _run(
          [c.scenario!],
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
          expect(row['status'], 'PASS', reason: jsonEncode(receipt));
          expect(proposals, hasLength(1));
          final typed =
              c.tier == 'hardLine' ||
              c.tier == 'T4' &&
                  !['retry', 'play'].contains(c.variant) &&
                  level != AiAutonomyLevel.bypass;
          if (typed) expect(proposals.single.requiredTypedName, isNotNull);
          if (['retry', 'play'].contains(c.variant)) {
            expect(proposals.single.requiredTypedName, isNull);
          }
        }
        _boundary(receipt);
      });
    }
  }

  for (final c in [
    _case('mergeRequest', 'ordinary'),
    _case('mergeRequest', 'default-target'),
    _case('mergeRequest', 'protected-target'),
    _case('mergeRequest', 'squash'),
    _case('mergeRequest', 'ci-default'),
    _case('mergeRequest', 'ci-custom'),
    _case('pipelineAction', 'cancel'),
    _case('pipelineAction', 'retry'),
    _case('jobAction', 'retry'),
    _case('jobAction', 'play'),
    _case('editProject', 'description'),
    for (final variant in [
      'ordinary-ref',
      'default-ref',
      'protected-ref',
      'ci-config',
    ]) ...[_case('deleteFile', variant), _case('applySuggestion', variant)],
    _case('deleteBoardList', 'owned-fixture'),
    _case('cancelAutoMerge', 'deprecated-fallback'),
    _case('deleteProject', 'terminal-deleted'),
    _case('createSnippet', 'new-nonprivate'),
  ]) {
    test('${c.id} computes its tier from production prepared facts', () async {
      final server = Mr7SyntheticGitLab();
      Mr7AdvancedFixture(server, operation: c.operation, variant: c.variant);
      final session = Mr7SandboxSession(
        server: server,
        nonce: 'advancednonce',
        requestCap: 400,
        eventDelay: () async {},
      );
      await session.initialize();
      try {
        final p = session.identity!;
        await c.scenario!.fixture!(session, p);
        for (final level in AiAutonomyLevel.values) {
          final decision = await _preparedDecision(c, session, level);
          expect(decision.tier.name.toLowerCase(), c.tier.toLowerCase());
          final approval =
              level == AiAutonomyLevel.confirmEach ||
              level == AiAutonomyLevel.lowRiskAuto ||
              c.tier == 'hardLine' ||
              c.tier == 'T4' && level == AiAutonomyLevel.conversationGrant;
          expect(
            decision.decision,
            level == AiAutonomyLevel.readOnly
                ? AiGateDecision.deny
                : approval
                ? AiGateDecision.requireApproval
                : AiGateDecision.execute,
          );
          expect(
            decision.requiresTypedName,
            level != AiAutonomyLevel.readOnly &&
                approval &&
                (c.tier == 'hardLine' ||
                    c.tier == 'T4' && !['retry', 'play'].contains(c.variant)),
          );
        }
        expect(server.scenarioWrites, 0);
      } finally {
        await session.finish();
      }
    });
  }

  test('serial fixtures reset settings and retain production tiers', () async {
    final selected = [
      _case('mergeRequest', 'default-target'),
      _case('mergeRequest', 'ci-custom'),
      _case('mergeRequest', 'squash'),
      _case('mergeRequest', 'ordinary'),
      _case('mergeRequest', 'protected-target'),
    ];
    final receipt = await _run([
      for (final c in selected)
        _copy(
          c.scenario!,
          fixture: (session, p) async {
            final fixtures = await c.scenario!.fixture!(session, p);
            final decision = await _preparedDecision(
              c,
              session,
              AiAutonomyLevel.conversationGrant,
            );
            expect(decision.tier.name.toLowerCase(), c.tier.toLowerCase());
            return fixtures;
          },
        ),
    ]);
    expect(_rows(receipt), hasLength(selected.length));
    for (final row in _rows(receipt)) {
      expect(row['status'], 'PASS', reason: jsonEncode(receipt));
    }
    _boundary(receipt);
  });

  for (final pair in [
    ('jobAction', 'play', 'manual'),
    ('jobAction', 'retry', 'failed'),
    ('pipelineAction', 'retry', 'failed'),
  ]) {
    test('${pair.$1} ${pair.$2} uses an eligible initial state', () async {
      final receipt = await _run(
        [_scenario(pair.$1, pair.$2)],
        confirm: (_) async => true,
        configure: (_, f) {
          final initial = pair.$1 == 'jobAction' ? f.job : f.pipeline;
          expect(initial['status'], pair.$3);
        },
      );
      expect(_rows(receipt).single['status'], 'PASS');
    });
    test('${pair.$1} ${pair.$2} rejects an ineligible initial state', () async {
      final receipt = await _run(
        [_scenario(pair.$1, pair.$2)],
        configure: (_, f) {
          (pair.$1 == 'jobAction' ? f.job : f.pipeline)['status'] = 'running';
        },
      );
      expect(_rows(receipt).single['status'], isNot('PASS'));
    });
  }

  for (final drift in ['approval-head', 'omitted-project-name']) {
    test('$drift CAS change at confirmation refuses before dispatch', () async {
      Mr7AdvancedFixture? fixture;
      final receipt = await _run(
        [
          drift == 'approval-head'
              ? _scenario('approveMergeRequest', 'sha-bound')
              : _scenario('editProject', 'description'),
        ],
        configure: (_, f) => fixture = f,
        confirm: (_) async {
          if (drift == 'approval-head') {
            fixture!.mr['sha'] = mr7AdvancedNextHead;
          } else {
            fixture!.server.project!['name'] = 'Concurrent synthetic name';
          }
          return true;
        },
      );
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(fixture!.mutations, isEmpty);
      _boundary(receipt);
    });
  }

  for (final size in [20, 21]) {
    test('whole draft batch $size uses production scan and cap', () async {
      var confirms = 0;
      final receipt = await _run(
        [_draftProbe('batch-$size')],
        configure: (_, f) {
          f.drafts
            ..clear()
            ..addAll([
              for (var id = 1; id <= size; id++)
                {'id': id, 'note': 'Synthetic review $id'},
            ]);
        },
        confirm: (p) async {
          confirms++;
          expect(p.requiredTypedName, isNull);
          return true;
        },
      );
      final row = _rows(receipt).single;
      if (size == 20) {
        expect(row['coreOutcome'], 'succeeded', reason: jsonEncode(receipt));
        expect(row['mutationCount'], 1);
        expect(confirms, 1);
        expect(row['observerRequests'], greaterThan(0));
        _notVerified(receipt);
      } else {
        expect(row['mutationCount'], 0);
        expect(row['status'], isNot('PASS'));
        expect(confirms, 0);
        _boundary(receipt);
      }
    });
  }

  for (final failure in ['last-draft-command', 'last-draft-cas-drift']) {
    test('whole batch $failure cannot write', () async {
      Mr7AdvancedFixture? fixture;
      var confirms = 0;
      final receipt = await _run(
        [_draftProbe(failure)],
        configure: (_, f) {
          fixture = f;
          f.drafts
            ..clear()
            ..addAll([
              for (var id = 1; id <= 20; id++)
                {'id': id, 'note': 'Synthetic review $id'},
            ]);
          if (failure == 'last-draft-command') {
            f.drafts.last['note'] = '/close';
          }
        },
        confirm: (_) async {
          confirms++;
          if (failure == 'last-draft-cas-drift') {
            fixture!.drafts.last['note'] = 'Concurrent synthetic review';
          }
          return true;
        },
      );
      final reads = fixture!.server.requests.where(
        (r) => r == 'GET projects/909/merge_requests/3/draft_notes',
      );
      expect(reads.length, greaterThanOrEqualTo(confirms == 0 ? 1 : 2));
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(confirms, failure == 'last-draft-command' ? 0 : 1);
      expect(fixture!.mutations, isEmpty);
      _boundary(receipt);
    });
  }

  test('edited release reconfirmation rejection sends nothing', () async {
    var confirms = 0;
    final receipt = await _run([
      _scenario('createRelease', 'ordinary-ref'),
    ], confirm: (_) async => ++confirms == 1);
    expect(confirms, 2);
    expect(_rows(receipt).single['mutationCount'], 0);
    expect(_rows(receipt).single['status'], isNot('PASS'));
  });

  test(
    '409 no-op without a bound state witness cannot pass or continue',
    () async {
      final receipt = await _run([
        _copy(
          _scenario('cancelAutoMerge', 'current-endpoint'),
          withoutNoChange: true,
        ),
        _scenario('editProject', 'name'),
      ], fixtureVariant: '409-no-change');
      _notVerified(receipt);
      expect(_rows(receipt).last['reason'], 'sessionStopped');
    },
  );

  test(
    '409 acknowledgement with contradictory enabled flags stays unverified',
    () async {
      final receipt = await _run(
        [_scenario('cancelAutoMerge', 'current-endpoint')],
        fixtureVariant: '409-no-change',
        configure: (s, f) {
          s.observer.interceptors.add(
            InterceptorsWrapper(
              onResponse: (r, h) {
                if (_afterWrite(r, f) &&
                    r.requestOptions.uri.path.endsWith('/merge_requests/3')) {
                  r.data = {
                    ...r.data as Map,
                    'merge_when_pipeline_succeeds': true,
                  };
                }
                h.next(r);
              },
            ),
          );
        },
      );
      _notVerified(receipt);
    },
  );

  test(
    'rebase accepted without a changed head never proves completion',
    () async {
      final receipt = await _run(
        [_scenario('rebaseMergeRequest', 'accepted')],
        configure: (s, f) {
          s.observer.interceptors.add(
            InterceptorsWrapper(
              onResponse: (r, h) {
                if (_afterWrite(r, f) &&
                    r
                            .requestOptions
                            .queryParameters['include_rebase_in_progress'] ==
                        true) {
                  r.data = {
                    ...r.data as Map,
                    'sha': mr7AdvancedHead,
                    'rebase_in_progress': false,
                  };
                }
                h.next(r);
              },
            ),
          );
        },
      );
      _notVerified(receipt);
      expect(_rows(receipt).single['mutationCount'], 1);
    },
  );

  for (final op in [
    'deleteBranch',
    'deleteTag',
    'deleteRelease',
    'deletePipeline',
    'deleteSnippet',
    'deleteDraftNote',
  ]) {
    final variant = switch (op) {
      'deletePipeline' => 'owned-pipeline',
      'deleteSnippet' => 'owned-project',
      'deleteDraftNote' => 'owned-draft',
      _ => 'ordinary-ref',
    };
    test('$op cannot infer absence without complete pagination', () async {
      final receipt = await _run(
        [_scenario(op, variant)],
        configure: (s, f) {
          s.observer.interceptors.add(
            InterceptorsWrapper(
              onResponse: (r, h) {
                if (_afterWrite(r, f) && r.data is List) {
                  r.headers.removeAll('x-total');
                }
                h.next(r);
              },
            ),
          );
        },
      );
      _notVerified(receipt);
    });
  }

  test(
    'lost reply remains uncertain and stops the next write and cleanup',
    () async {
      Mr7AdvancedFixture? fixture;
      final receipt = await _run(
        [
          _scenario('cancelAutoMerge', 'current-endpoint'),
          _scenario('editProject', 'name'),
        ],
        configure: (_, f) {
          fixture = f;
          f.loseReply = true;
        },
      );
      expect(_rows(receipt).first['status'], 'writeUncertain');
      expect(_rows(receipt).last['reason'], 'sessionStopped');
      expect(fixture!.mutations, hasLength(1));
      _notVerified(receipt);
      _boundary(receipt, cleanup: false);
    },
  );

  test(
    'foreign event after one write stops the next write and cleanup',
    () async {
      final receipt = await _run(
        [
          _scenario('cancelAutoMerge', 'current-endpoint'),
          _scenario('editProject', 'name'),
        ],
        configure: (_, f) {
          final key = 'POST projects/909/merge_requests/3/cancel_auto_merge';
          final original = f.server.routes[key]!;
          f.server.routes[key] = (r) async {
            final reply = await original(r);
            f.server.addEvent(target: 777);
            return reply;
          };
        },
      );
      expect(_part(receipt, 'events')['status'], 'NOT_VERIFIED');
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(_part(receipt, 'cleanup')['status'], 'NOT_RUN');
    },
  );

  test('foreign project cannot be dispatched with a sealed path', () async {
    final b = _scenario('editProject', 'description');
    final receipt = await _run([
      _copy(
        b,
        call: (_) => AiToolCall(
          id: b.id,
          name: b.operation,
          arguments: {'projectId': 777, 'description': 'Foreign synthetic'},
        ),
        paths: (_) => {'PUT projects/777'},
      ),
    ]);
    expect(_rows(receipt).single['mutationCount'], 0);
    expect(_rows(receipt).single['status'], isNot('PASS'));
  });

  for (final field in ['protected_branches', 'namespaceId', 'visibility']) {
    test(
      'editProject refuses out-of-scope $field before confirmation',
      () async {
        var confirms = 0;
        final b = _scenario('editProject', 'description');
        final receipt = await _run(
          [
            _copy(
              b,
              call: (p) => AiToolCall(
                id: b.id,
                name: b.operation,
                arguments: {
                  ...b.call(p).arguments! as Map<String, Object?>,
                  field: 'forbidden synthetic',
                },
              ),
            ),
          ],
          confirm: (_) async {
            confirms++;
            return true;
          },
        );
        expect(_rows(receipt).single['mutationCount'], 0);
        expect(confirms, 0);
      },
    );
  }

  // Wave 3c family regressions: the acknowledgement and production readback
  // succeed, but the sealed witness sees no matching effect.
  Future<void> wrongEffect(
    String op,
    String variant,
    String reason,
    void Function(Mr7SandboxSession, Mr7AdvancedFixture) configure,
  ) async {
    late Mr7AdvancedFixture fixture;
    final receipt = await _run(
      [_scenario(op, variant)],
      configure: (s, f) {
        fixture = f;
        configure(s, f);
      },
    );
    final row = _rows(receipt).single;
    expect(row['coreOutcome'], 'succeeded', reason: jsonEncode(receipt));
    expect(row['mutationCount'], _scenario(op, variant).expectedMutations);
    expect(row['status'], 'NOT_VERIFIED');
    expect(row['readback'], 'NOT_VERIFIED');
    expect(row['reason'], reason);
    expect(fixture.mutations, isNotEmpty);
    _notVerified(receipt);
  }

  void observed(
    Mr7SandboxSession s,
    Mr7AdvancedFixture f,
    String suffix,
    Map<String, Object?> change, {
    int after = 1,
  }) => s.observer.interceptors.add(
    InterceptorsWrapper(
      onResponse: (r, h) {
        if (f.mutations.length >= after &&
            r.requestOptions.uri.path.endsWith(suffix) &&
            r.data is Map) {
          r.data = {...r.data as Map, ...change};
        }
        h.next(r);
      },
    ),
  );

  test('deleteFile cannot pass while the tree still lists the path', () async {
    await wrongEffect('deleteFile', 'ordinary-ref', 'observerAbsence', (_, f) {
      f.server.routes['DELETE projects/909/repository/files/synthetic.txt'] =
          (r) {
            // A new topic commit that keeps the file.
            f.repository[mr7AdvancedNextHead] = {...f.repository[f.topicHead]!};
            f.topicHead = mr7AdvancedNextHead;
            f.mutations.add(r);
            f.server.addEvent(target: 909);
            return mr7Json({}, status: 204);
          };
    });
  });

  test(
    'applySuggestion cannot pass when the branch holds other bytes',
    () async {
      await wrongEffect('applySuggestion', 'ordinary-ref', 'observerContent', (
        _,
        f,
      ) {
        final key = 'PUT suggestions/5/apply';
        final original = f.server.routes[key]!;
        f.server.routes[key] = (r) async {
          final reply = await original(r);
          // The suggestion is marked applied, but the commit holds other text.
          f.repository[mr7AdvancedNextHead]!['synthetic.txt'] = (
            text: 'line one\nother\nline three\n',
            last: mr7AdvancedNextHead,
          );
          return reply;
        };
      });
    },
  );

  test(
    'applySuggestion on an older MR version refuses before dispatch',
    () async {
      late Mr7AdvancedFixture fixture;
      var confirms = 0;
      final receipt = await _run(
        [_scenario('applySuggestion', 'ordinary-ref')],
        configure: (_, f) {
          fixture = f;
          // The note was written against an earlier diff head.
          f.suggestionHead = '9999999999999999999999999999999999999999';
        },
        confirm: (_) async {
          confirms++;
          return true;
        },
      );
      final row = _rows(receipt).single;
      expect(confirms, 0);
      expect(row['mutationCount'], 0);
      expect(row['status'], isNot('PASS'));
      expect(fixture.mutations, isEmpty);
      expect(
        fixture.server.requests,
        isNot(contains('PUT suggestions/5/apply')),
      );
      expect(fixture.suggestion['applied'], isFalse);
    },
  );

  test('deleteBoardList cannot pass while the list remains', () async {
    await wrongEffect('deleteBoardList', 'owned-fixture', 'observerAbsence', (
      _,
      f,
    ) {
      f.server.routes['DELETE projects/909/boards/12/lists/52'] = (r) {
        f.mutations.add(r);
        f.server.addEvent(target: 909);
        return mr7Json({}, status: 204);
      };
    });
  });

  test(
    'publishDraftNotes cannot pass with one draft left unpublished',
    () async {
      await wrongEffect(
        'publishDraftNotes',
        'whole-batch',
        'observerPublishedNote',
        (_, f) {
          final key =
              'POST projects/909/merge_requests/3/draft_notes/bulk_publish';
          final original = f.server.routes[key]!;
          f.server.routes[key] = (r) async {
            // The positioned draft disappears without becoming a public note.
            f.drafts.removeLast();
            return original(r);
          };
        },
      );
    },
  );

  test(
    'legacy cancellation cannot pass while the documented flag stays true',
    () async {
      await wrongEffect(
        'cancelAutoMerge',
        'deprecated-fallback',
        'observerState',
        (s, f) => observed(s, f, '/merge_requests/3', {
          'merge_when_pipeline_succeeds': true,
        }, after: 2),
      );
    },
  );

  test(
    'createSnippet cannot pass when the snippet is stored private',
    () async {
      await wrongEffect(
        'createSnippet',
        'new-nonprivate',
        'observerSnippet',
        (s, f) => observed(s, f, '/snippets/60', {'visibility': 'private'}),
      );
    },
  );

  test(
    'deleteProject cannot pass while the inventory still lists it',
    () async {
      await wrongEffect(
        'deleteProject',
        'terminal-deleted',
        'observerTerminalDeletion',
        (_, f) {
          Map<String, Object?>? listed;
          f.server.routes['GET users/7/projects'] = (_) {
            listed ??= Map.of(f.server.project!);
            return mr7Json(
              [listed],
              headers: {
                'x-page': ['1'],
                'x-per-page': ['100'],
                'x-total': ['1'],
                'x-total-pages': ['1'],
                'x-next-page': [''],
              },
            );
          };
        },
      );
    },
  );

  test(
    'deleteProject retention in the GitLab.com rename shape stays unproven',
    () async {
      late Mr7AdvancedFixture fixture;
      final receipt = await _run(
        [_scenario('deleteProject', 'terminal-deleted')],
        configure: (_, f) {
          fixture = f;
          // The synthetic server's GitLab.com shape: DELETE renames the project
          // to <path>-deletion_scheduled-<id>, and the original path answers 301.
          f.server.routes.remove('DELETE projects/909');
          f.server.scheduledDeletion = true;
        },
      );
      final row = _rows(receipt).single;
      expect(fixture.server.project!['marked_for_deletion_on'], isA<String>());
      expect(row['mutationCount'], 1);
      expect(row['coreOutcome'], 'succeeded');
      expect(row['status'], 'NOT_VERIFIED');
      expect(row['readback'], 'NOT_VERIFIED');
      expect(row['reason'], 'observerTerminalDeletion');
      expect(receipt['quarantined'], isTrue);
      expect(_part(receipt, 'cleanup')['reason'], 'terminalScenario');
    },
  );
}
