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

void _boundary(Map<String, Object?> receipt, {bool cleanup = true}) {
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
      target: prepared.bindingTargets.single,
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
      expect(row['mutationCount'], 1);
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
      expect(fixture!.mutations, hasLength(1));
      if (['pipelineAction', 'jobAction'].contains(c.operation)) {
        expect(fixture!.mutations.single.data, isEmpty);
      }
      expect(row['outcome'], 'succeeded');
      expect(
        fixture!.server.requests.any(
          (r) => r.contains('/variables') || r.contains('/inputs'),
        ),
        isFalse,
      );
      _boundary(receipt);
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
                if (_afterWrite(r, f) &&
                    (!root || c.operation == 'editProject')) {
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
      expect(_rows(receipt).single['mutationCount'], 1);
    });
  }

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
}
