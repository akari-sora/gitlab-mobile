import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';

import '../../tool/mr7/rest_scenarios.dart';
import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart';

const _sha = 'c33d6dee99eb97afc1c87c755708e033afe0d2ed';
const _fixtureIdentity = Mr7Identity(
  projectId: 909,
  path: 'synthetic-owner/synthetic-project',
  userId: 7,
  namespaceId: 70,
  namespace: 'synthetic-owner',
  nonce: 'b1syntheticnonce123',
);

List<Map<String, Object?>> _rows(Map<String, Object?> receipt) =>
    (receipt['scenarios']! as List).cast<Map<String, Object?>>();
Map<String, Object?> _part(Map<String, Object?> receipt, String name) =>
    (receipt[name]! as Map).cast<String, Object?>();
Mr7Scenario _case(String operation, String variant) => mr7RestCases()
    .singleWhere((c) => c.operation == operation && c.variant == variant)
    .scenario!;

List<String> _updateFields(Mr7Scenario scenario) {
  final arguments = scenario.call(_fixtureIdentity).arguments! as Map;
  return arguments['fields'] is Map
      ? (arguments['fields']! as Map).keys.cast<String>().toList()
      : switch (scenario.operation) {
          'renameBoard' => ['name'],
          'setBoardSystemListHidden' => ['hide_${arguments['list']}_list'],
          'setMilestoneState' => ['state_event'],
          'updateDraftNote' => ['note'],
          _ => [
            for (final field in ['body', 'position', 'resolved'])
              if (arguments.containsKey(field)) field,
          ],
        };
}

Mr7SandboxSession _session(Mr7SyntheticGitLab server, {int requestCap = 200}) =>
    Mr7SandboxSession(
      server: server,
      nonce: 'b1syntheticnonce123',
      requestCap: requestCap,
      eventDelay: () async {},
    );

Future<Map<String, Object?>> _run(
  List<Mr7Scenario> scenarios, {
  Mr7SyntheticGitLab? server,
  Mr7Confirm? confirm,
  Mr7TypedConfirm? typedConfirm,
  Mr7Edit? editConfirm,
  List<Mr7ClosedVariant> closedVariants = const [],
  AiToolBudget? sharedBudget,
  AiWriteJournal? journal,
  String? conversationId,
  DateTime Function()? now,
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
  Mr7Policy policy = Mr7Policy.candidate,
  int requestCap = 200,
}) async {
  final synthetic = server ?? Mr7SyntheticGitLab();
  if (server == null) {
    configureMr7RestFixtures(
      synthetic,
      scenario: scenarios.length == 1 ? scenarios.single : null,
    );
  }
  return runMr7Sandbox(
    policy: policy,
    releaseSha: _sha,
    suite: 'rest',
    scenarios: scenarios,
    session: _session(synthetic, requestCap: requestCap),
    level: level,
    confirm: confirm ?? (_) async => true,
    typedConfirm: typedConfirm ?? (_) async => '#1',
    editConfirm:
        editConfirm ??
        (p) async => p.previewText?.contains(mr7RestEditOriginal) == true
            ? mr7RestEditText
            : null,
    closedVariants: closedVariants,
    sharedBudget: sharedBudget,
    journal: journal,
    conversationId: conversationId,
    now: now,
  );
}

/// Change one proposed input while keeping the actual runner and boundaries.
Mr7Scenario _callWith(
  Mr7Scenario source,
  Map<String, Object?> arguments, {
  String? id,
  String Function(Mr7Identity)? utterance,
  Future<Mr7ScenarioFixtures> Function(Mr7SandboxSession, Mr7Identity)? setup,
  Future<bool> Function(Mr7Readback, Mr7Identity)? observe,
}) => Mr7Scenario(
  id: id ?? source.id,
  suite: source.suite,
  operation: source.operation,
  variant: source.variant,
  tier: source.tier,
  call: (p) {
    final call = source.call(p);
    return AiToolCall(
      id: id ?? call.id,
      name: call.name,
      arguments: {...call.arguments! as Map<String, Object?>, ...arguments},
    );
  },
  targetKind: source.targetKind,
  targetKinds: source.targetKinds,
  fixture: setup ?? source.fixture,
  preRead: source.preRead,
  noChangeObservation: source.noChangeObservation,
  expectedMutations: source.expectedMutations,
  maxMutations: source.maxMutations,
  paths: source.paths,
  observe: observe ?? source.observe,
  freshness: source.freshness,
  utterance: utterance ?? source.utterance,
  resource: source.resource,
  readbackPaths: source.readbackPaths,
  readNames: source.readNames,
);

/// Corrupt a fresh serialized read after the acknowledged synthetic write.
/// The production request and captured pre-write snapshot remain intact.
void _driftAfterWrite(
  Mr7SyntheticGitLab server,
  Mr7Scenario source,
  String field,
  Object? value, {
  String? readPath,
}) {
  final writePath = source.paths(_fixtureIdentity).single;
  final path = readPath ?? source.preRead!(_fixtureIdentity).single.path;
  final write = server.routes[writePath]!;
  final read = server.routes['GET $path']!;
  var sent = false;
  server.routes[writePath] = (request) async {
    final response = await write(request);
    sent = true;
    return response;
  };
  server.routes['GET $path'] = (request) async {
    final response = await read(request);
    if (!sent) return response;
    final current = jsonDecode(await utf8.decoder.bind(response.stream).join());
    return mr7Json({...current as Map, field: value});
  };
}

Mr7Scenario _provenanceCase(
  String id, {
  required String description,
  required bool readFirst,
  required List<Map<String, Object?>> requests,
}) {
  AiToolCall call(Mr7Identity p) => AiToolCall(
    id: id,
    name: 'updateIssue',
    arguments: {
      'projectId': p.projectId,
      'iid': 1,
      'fields': {'description': description},
      'reason': 'Explicit synthetic same-field edit.',
    },
  );
  return Mr7Scenario(
    id: id,
    suite: 'rest',
    operation: 'updateIssue',
    variant: 'provenance-supporting-evidence',
    tier: 'T2',
    targetKind: AiTargetKind.issue,
    readNames: readFirst ? const {'get_issue'} : const {},
    resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 1),
    utterance: (p) => 'Read and edit issue #1 description in ${p.path}.',
    call: call,
    paths: (p) => {'PUT projects/${p.projectId}/issues/1'},
    preRead: (p) => [
      Mr7SnapshotSpec(
        path: 'projects/${p.projectId}/issues/1',
        fields: {'title', 'description', 'state', 'updated_at'},
        unchangedFields: {'title', 'state'},
      ),
    ],
    readbackPaths: (p, _) => {'projects/${p.projectId}/issues/1'},
    observe: (observer, p) async =>
        (await observer.read(
          'projects/${p.projectId}/issues/1',
        ))['description'] ==
        description.replaceAll('[[upload:u-1]]', _provenanceLink),
    freshness: (session, _) async {
      final p = session.identity!;
      final current = await session.read('projects/${p.projectId}/issues/1');
      return AiWriteFreshness(
        updatedAt: current['updated_at'] as String?,
        visibilityUnreadable: false,
        sourceVisibilityUnreadable: false,
        targetVisibility: 'private',
        currentFields: {'description': current['description']! as String},
        provenance: {
          'description': text.AiFieldProvenance.gitLab(
            instance: GitLabInstance.parse(session.instance.toString()),
            projectId: p.projectId,
            projectPath: p.path,
            resource: 'issues',
            iid: 1,
          ),
        },
      );
    },
    fixture: (_, p) async => Mr7ScenarioFixtures(
      providerScript: [
        if (readFirst)
          [
            AiToolCall(
              id: '$id-read',
              name: 'get_issue',
              arguments: {'iid': 1},
            ),
          ],
        [call(p)],
      ],
      onProviderRequest: requests.add,
    ),
  );
}

const _provenanceSecret = '0123456789abcdef0123456789abcdef';
const _provenanceLink = '/uploads/$_provenanceSecret/screen.png';

void _provenanceFixture(Mr7SyntheticGitLab server, String description) {
  final issue = <String, Object?>{
    'id': 1001,
    'iid': 1,
    'project_id': server.projectId,
    'title': 'Synthetic provenance original.',
    'description': description,
    'confidential': false,
    'state': 'opened',
    'updated_at': '2026-10-29T00:00:00.000Z',
  };
  server.routes['GET projects/909/issues/1'] = (_) => mr7Json(issue);
  server.routes['GET projects/909/issues/1/notes'] = (_) => mr7Json([]);
  server.routes['PUT projects/909/issues/1'] = (request) {
    issue['description'] = (request.data as Map)['description'];
    issue['updated_at'] = server.serverTime.toIso8601String();
    server.scenarioWrites++;
    server.addEvent(target: server.projectId);
    return mr7Json(issue);
  };
}

void main() {
  final cases = mr7RestCases();
  final executable = cases.where((c) => c.scenario != null).toList();

  test('REST inventory equals all 31 production T1/T2 rows', () {
    expect(
      cases.map((c) => c.operation).toSet(),
      aiT12Rows.map((r) => r.operationId).toSet(),
    );
    expect(cases.map((c) => c.operation).toSet(), hasLength(31));
    expect(cases.map((c) => c.id).toSet(), hasLength(cases.length));
    expect(mr7RestScenarios().map((s) => s.id), executable.map((c) => c.id));
    expect(mr7RestPlanRows, [8, 9, 14, 19, 20, 23, 32]);
    expect(mr7RestEvidenceGaps.keys, unorderedEquals(mr7RestPlanRows));
    for (final row in aiT12Rows.where((r) => r.editableField != null)) {
      expect(
        cases.any(
          (c) =>
              c.operation == row.operationId &&
              c.variant == 'confirmation-edited-text' &&
              c.scenario != null,
        ),
        isTrue,
        reason: row.operationId,
      );
    }
    for (final c in cases) {
      expect(c.fixture, isNotEmpty);
      expect(c.confirmation, contains('confirmation'));
      expect(c.chain, contains('uncached observer'));
      expect(c.events, contains('cleanup'));
      expect(c.cleanup, contains('quarantine'));
      expect(c.live, 'NOT_RUN');
      if (c.scenario == null) {
        expect(c.closedReason, isNotEmpty, reason: c.id);
      } else {
        expect(c.scenario!.id, c.id);
        expect(c.scenario!.operation, c.operation);
        expect(c.scenario!.variant, c.variant);
        expect(c.scenario!.tier, c.tier);
        if (c.scenario!.paths(_fixtureIdentity).single.startsWith('PUT ')) {
          expect(_updateFields(c.scenario!), isNotEmpty, reason: c.id);
        }
      }
    }
    expect(executable, hasLength(92));
    expect(mr7RestClosedVariants(), hasLength(14));
    for (final c in cases.where(
      (c) => const {
        'renameBoard',
        'setBoardSystemListHidden',
        'updateDraftNote',
      }.contains(c.operation),
    )) {
      expect(c.scenario, isNotNull, reason: c.id);
      expect(c.scenario!.preRead!(_fixtureIdentity), isNotEmpty);
    }
    for (final c in cases.where((c) => c.scenario == null)) {
      expect(c.refusal, isNotNull, reason: c.id);
      expect(c.closedVariant!.id, c.id);
      expect(c.refusal!.metadata['type'], 'closedVariant');
    }
    expect(
      cases
          .where((c) => c.operation == 'markTodoDone')
          .every((c) => c.refusal?.cause == Mr7ClosureCause.scopeExcluded),
      isTrue,
    );
    expect(
      cases
          .where((c) => c.operation == 'createTodo')
          .every((c) => c.scenario != null),
      isTrue,
    );
    expect(
      cases.where((c) => c.refusal?.code == 'provenanceScenarioPending'),
      isEmpty,
    );
    expect(
      cases
          .where((c) => c.operation == 'upload_attachment' && c.refusal != null)
          .map((c) => c.refusal!.code),
      containsAll([
        'provenanceCompositeWriteUnavailable',
        'provenanceConversationStepUnavailable',
        'provenanceHistoryRestoreUnavailable',
        'provenanceHiddenSpanWriteUnavailable',
      ]),
    );
    expect(
      cases
          .where((c) => c.operation == 'upload_attachment')
          .map((c) => c.variant),
      containsAll([
        'multipart-memory',
        'slow-timeout',
        'metadata-only-provider',
        'same-field-roundtrip',
        'crossnonce',
        'restored-history',
        'hiddenSpan',
        'picker-process-cleanup',
      ]),
    );
    final output = Platform.environment['MR7_REST_RECEIPT'];
    if (output != null) {
      File('$output.inventory.json').writeAsStringSync(
        jsonEncode([
          for (final c in cases)
            {
              'id': c.id,
              'operation': c.operation,
              'variant': c.variant,
              'executable': c.scenario != null,
              if (c.refusal != null) 'refusal': c.refusal!.metadata,
            },
        ]),
      );
    }
  });

  for (final c in executable) {
    test(
      'REST receipt ${c.id} confirms one write and independent fields',
      () async {
        final noOp = c.variant.endsWith('already-matching-304');
        final server = Mr7SyntheticGitLab();
        configureMr7RestFixtures(server, scenario: c.scenario);
        final receipt = await _run([c.scenario!], server: server);
        final row = _rows(receipt).single;
        expect(row['status'], 'PASS', reason: jsonEncode(row));
        expect(receipt['status'], 'PASS', reason: jsonEncode(receipt));
        expect(row['readback'], 'PASS');
        expect(row['observerRequests'], greaterThan(0));
        expect(row['outcome'], noOp ? 'noChange' : 'succeeded');
        expect(row['coreOutcome'], 'succeeded');
        if (c.scenario!.preRead?.call(_fixtureIdentity).isNotEmpty == true) {
          expect(row['snapshotVerified'], isTrue);
        }
        if (noOp) {
          expect(row['classification'], 'verifiedNoOp');
          expect(row['parentStateVerified'], isTrue);
          expect(row['responseStatus'], 304);
        }
        if (c.variant == 'confirmation-edited-text') {
          final confirmations = (row['confirmations']! as List)
              .cast<Map<Object?, Object?>>();
          expect(confirmations, hasLength(2));
          expect(confirmations.every((v) => v['accepted'] == true), isTrue);
          expect(
            confirmations.first['payloadDigest'],
            isNot(confirmations.last['payloadDigest']),
          );
          expect(_part(row, 'edit')['reason'], 'approvalRequired');
          expect(row['payloadDigest'], confirmations.last['payloadDigest']);
        }
        expect(row['mutationCount'], 1);
        expect(row['operation'], c.operation);
        expect(row['variant'], c.variant);
        expect(row['tier'], c.tier);
        expect(row['declaredTier'], row['tier']);
        expect(row['decisionProjection'], 'observed');
        expect(row['decision'], 'requireApproval');
        expect(row['confirmationReasons'], isA<List<Object?>>());
        expect(row.containsKey('decisionUnavailable'), isFalse);
        expect(row['fixtureDigest'], matches(r'^[0-9a-f]{64}$'));
        expect(row['payloadDigest'], matches(r'^[0-9a-f]{64}$'));
        expect(row['confirmation'], 'explicitSyntheticTestHook');
        expect(
          DateTime.parse(
            row['confirmAt']! as String,
          ).isBefore(DateTime.parse(row['proposalAt']! as String)),
          isFalse,
        );
        expect(row['live'], 'NOT_RUN');
        expect(receipt['transport'], 'synthetic');
        expect(receipt['evidenceClass'], 'CANDIDATE_ONLY');
        expect(receipt['finalEligible'], isFalse);
        expect(receipt['secretLeakScan'], 'PASS');
        expect(_part(row, 'provider')['calls'], greaterThanOrEqualTo(1));
        expect(_part(row, 'provider')['secretLeakScan'], 'PASS');
        expect(_part(receipt, 'coverage')['rest'], 'SYNTHETIC');
        expect(_part(receipt, 'coverage')['graphql'], 'NOT_RUN');
        expect(_part(receipt, 'events')['status'], 'PASS');
        final events = (_part(receipt, 'events')['items']! as List)
            .cast<Map<String, Object?>>();
        expect(events, hasLength(noOp ? 2 : 3));
        expect(events.every((e) => e['projectId'] == server.projectId), isTrue);
        expect(_part(receipt, 'cleanup')['deletionVerified'], isTrue);
        expect(receipt['quarantined'], isFalse);
        expect(server.scenarioWrites, noOp ? 0 : 1);
        expect(server.setupWrites, 1);
        expect(server.cleanupWrites, 1);
        final ledger = (receipt['requestLedger']! as List)
            .cast<Map<String, Object?>>();
        expect(ledger.map((r) => r['operation']), [
          'harnessSetup',
          c.operation,
          'harnessCleanup',
        ]);
        expect(ledger.every((r) => r['projectId'] == server.projectId), isTrue);
        expect(server.requests.last, startsWith('GET users/7/events'));
        expect(
          server.requests.where((r) => r.startsWith('GET projects/909')).length,
          greaterThan(3),
        );
        expect(jsonEncode(receipt), isNot(contains('synthetic-gitlab-pat')));
        expect(jsonEncode(receipt), isNot(contains('Synthetic note.')));
      },
    );
    test('REST outside-sandbox ${c.id} cannot pass', () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server, scenario: c.scenario);
      final receipt = await _run([
        _callWith(c.scenario!, {'projectId': mr7ProtectedProjectId}),
      ], server: server);
      expect(_rows(receipt).single['status'], isNot('PASS'), reason: c.id);
      expect(_rows(receipt).single['mutationCount'], 0, reason: c.id);
      expect(server.scenarioWrites, 0);
      expect(
        server.requests.any((r) => r.contains('$mr7ProtectedProjectId')),
        isFalse,
      );
    });
  }

  for (final level in AiAutonomyLevel.values) {
    for (final source in [
      _case('setStar', 'star'),
      _case('createNote', 'issue'),
    ]) {
      test(
        'REST ${source.operation} autonomy ${level.name} keeps sandbox confirm',
        () async {
          var confirmations = 0;
          final receipt = await _run(
            [source],
            level: level,
            confirm: (_) async {
              confirmations++;
              return true;
            },
          );
          final row = _rows(receipt).single;
          expect(
            row['mutationCount'],
            level == AiAutonomyLevel.readOnly ? 0 : 1,
          );
          expect(
            row['status'],
            level == AiAutonomyLevel.readOnly ? 'NOT_RUN' : 'PASS',
          );
          expect(
            confirmations,
            level == AiAutonomyLevel.readOnly ? 0 : greaterThan(0),
          );
          final rejected = await _run(
            [source],
            level: level,
            confirm: (_) async => false,
          );
          expect(_rows(rejected).single['mutationCount'], 0);
          expect(_rows(rejected).single['status'], isNot('PASS'));
          if (_rows(rejected).single['status'] == 'writeUncertain') {
            expect(rejected['quarantined'], isTrue);
          }
        },
      );
    }
  }

  test(
    'REST confidential lowering still requires exact typed target in bypass',
    () async {
      final source = _case('updateIssue', 'confidential-lowered');
      for (final typed in <String?>[null, 'wrong', '#1']) {
        final required = <String?>[];
        final receipt = await _run(
          [source],
          level: AiAutonomyLevel.bypass,
          typedConfirm: (proposal) async {
            required.add(proposal.requiredTypedName);
            return typed;
          },
        );
        expect(required, ['#1']);
        final row = _rows(receipt).single;
        expect(row['mutationCount'], typed == '#1' ? 1 : 0);
        expect(row['typedInputMatches'], typed == '#1');
        expect(row['status'], typed == '#1' ? 'PASS' : isNot('PASS'));
      }
    },
  );

  test(
    'REST production receipts keep every candidate operation releaseClosed',
    () async {
      var confirmations = 0;
      final receipt = await _run(
        mr7RestScenarios(),
        policy: Mr7Policy.production,
        confirm: (_) async {
          confirmations++;
          return true;
        },
      );
      expect(confirmations, 0);
      expect(_rows(receipt), hasLength(executable.length));
      for (final row in _rows(receipt)) {
        expect(row['status'], 'NOT_RUN');
        expect(row['reason'], 'releaseClosed');
        expect(row['mutationCount'], 0);
        expect(row['readback'], 'NOT_RUN');
      }
      expect(_part(receipt, 'coverage')['rest'], 'NOT_RUN');
      expect(receipt['finalEligible'], isFalse);
    },
  );

  test(
    'REST whole-operation batches compose serially with one sandbox and finalizer each',
    () async {
      // Each synthetic invocation has its own recovered journal. Keep whole
      // operations together and below the unchanged 60-write account window.
      final batches = <List<Mr7Scenario>>[[]];
      for (final operation in executable.map((c) => c.operation).toSet()) {
        final group = executable
            .where((c) => c.operation == operation)
            .map((c) => c.scenario!)
            .toList();
        if (batches.last.length + group.length > 50) batches.add([]);
        batches.last.addAll(group);
      }
      final observed = <String>{};
      for (var batch = 0; batch < batches.length; batch++) {
        final selected = mr7RestScenarios()
            .where((c) => batches[batch].any((s) => s.id == c.id))
            .toList();
        final server = Mr7SyntheticGitLab()..eventPageSize = 100;
        configureMr7RestFixtures(server);
        final receipt = await _run(
          selected,
          server: server,
          requestCap: 5000,
          closedVariants: mr7RestClosedVariants(),
        );
        expect(receipt['status'], 'PASS', reason: jsonEncode(receipt));
        expect(
          _rows(receipt),
          hasLength(selected.length + mr7RestClosedVariants().length),
        );
        for (final row in _rows(
          receipt,
        ).where((r) => r['classification'] != 'closedVariant')) {
          expect(row['status'], 'PASS', reason: jsonEncode(row));
          expect(row['readback'], 'PASS');
          expect(row['mutationCount'], 1);
          expect(observed.add(row['id']! as String), isTrue);
        }
        expect(
          server.scenarioWrites,
          selected
              .where((c) => !c.variant.endsWith('already-matching-304'))
              .length,
        );
        expect(server.setupWrites, 1);
        expect(server.cleanupWrites, 1);
        expect(_part(receipt, 'cleanup')['deletionVerified'], isTrue);
        expect(_part(receipt, 'events')['status'], 'PASS');
        expect(receipt['requestCount'], lessThanOrEqualTo(5000));
        for (final row in _rows(
          receipt,
        ).where((r) => r['classification'] == 'closedVariant')) {
          expect(row['status'], 'NOT_RUN');
          expect(row['suite'], 'rest');
          expect(row['operation'], isNotEmpty);
          expect(row['variant'], isNotEmpty);
          expect(row['tier'], isNotEmpty);
          expect(row['releaseSha'], _sha);
          expect(row['live'], 'NOT_RUN');
          expect(row['reason'], _part(row, 'refusal')['code']);
          expect(row['mutationCount'], 0);
          expect(row['providerCalls'], 0);
          expect(row['readback'], 'NOT_RUN');
          expect(row.containsKey('outcome'), isFalse);
          expect(row.containsKey('coreOutcome'), isFalse);
        }
        final output = Platform.environment['MR7_REST_RECEIPT'];
        if (output != null) {
          await File(
            batch == 0 ? output : '$output.batch${batch + 1}.json',
          ).writeAsString(jsonEncode(receipt), flush: true);
        }
      }
      expect(observed, executable.map((c) => c.id).toSet());
    },
  );

  for (final variant in ['issue', 'issue-note', 'mr', 'mr-note']) {
    test('REST duplicate award $variant is rejected with 404', () async {
      final source = _case('addAwardEmoji', variant);
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server, scenario: source);
      final resource = variant.startsWith('issue')
          ? 'issues'
          : 'merge_requests';
      final note = variant.endsWith('-note')
          ? 'notes/${resource == 'issues' ? 301 : 302}/'
          : '';
      final path = 'POST projects/909/$resource/1/${note}award_emoji';
      final route = server.routes[path]!;
      final statuses = <int>[];
      server.routes[path] = (request) async {
        final response = await route(request);
        statuses.add(response.statusCode);
        return response;
      };
      final receipt = await _run([
        source,
        _callWith(source, const {}, id: '${source.id}-duplicate'),
      ], server: server);
      final rows = _rows(receipt);
      expect(rows.first['status'], 'PASS', reason: jsonEncode(rows.first));
      expect(statuses, [201, 404]);
      expect(rows.last['status'], isNot('PASS'));
      expect(rows.last['outcome'], isNot('succeeded'));
      expect(rows.last['readback'], 'NOT_RUN');
      expect(server.scenarioWrites, 1);
      expect(_part(receipt, 'events')['items'], hasLength(3));
    });
  }

  test('REST existing board label list is rejected with 400', () async {
    final server = Mr7SyntheticGitLab();
    configureMr7RestFixtures(server);
    const path = 'POST projects/909/boards/801/lists';
    final route = server.routes[path]!;
    final statuses = <int>[];
    server.routes[path] = (request) async {
      final response = await route(request);
      statuses.add(response.statusCode);
      return response;
    };
    final receipt = await _run([
      _callWith(_case('createBoardList', 'label'), {'labelId': 701}),
    ], server: server);
    expect(statuses, [400]);
    expect(_rows(receipt).single['status'], isNot('PASS'));
    expect(_rows(receipt).single['readback'], 'NOT_RUN');
    expect(server.scenarioWrites, 0);
    expect(_part(receipt, 'events')['items'], hasLength(2));
  });

  test('REST duplicate newly created board label list is rejected', () async {
    final source = _case('createBoardList', 'label');
    final server = Mr7SyntheticGitLab();
    configureMr7RestFixtures(server);
    final receipt = await _run([
      source,
      _callWith(source, const {}, id: '${source.id}-duplicate'),
    ], server: server);
    final rows = _rows(receipt);
    expect(rows.first['status'], 'PASS', reason: jsonEncode(rows.first));
    expect(rows.last['status'], isNot('PASS'));
    expect(rows.last['outcome'], isNot('succeeded'));
    expect(rows.last['readback'], 'NOT_RUN');
    expect(server.scenarioWrites, 1);
    expect(_part(receipt, 'events')['items'], hasLength(3));
  });

  test(
    'REST transition variants refuse already-matching fixture states',
    () async {
      for (final source in [
        _case('setStar', 'unstar'),
        _case('setSubscribed', 'issue-off'),
        _case('setSubscribed', 'mr-off'),
        _case('updateIssue', 'reopen'),
        _case('updateMergeRequest', 'reopen'),
        _case('moveBoardCard', 'reopen'),
      ]) {
        final server = Mr7SyntheticGitLab();
        // Deliberately omit the isolated variant selector: all these seeds
        // already match the requested final state and must not count as changes.
        configureMr7RestFixtures(server);
        final receipt = await _run([source], server: server);
        expect(
          _rows(receipt).single['status'],
          isNot('PASS'),
          reason: source.id,
        );
        expect(_rows(receipt).single['mutationCount'], 0, reason: source.id);
        expect(server.scenarioWrites, 0, reason: source.id);
      }
    },
  );

  test(
    'REST field mismatch stops later cases despite successful core outcome',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      // Core REST readback checks transport success; this observer must check fields.
      final update = _case('updateNote', 'issue');
      server.routes['GET projects/909/issues/1/notes/301'] = (_) => mr7Json({
        'id': 301,
        'project_id': 909,
        'body': 'Synthetic original.',
        'updated_at': '2026-10-29T00:00:00.000Z',
        'author': {'id': 7},
      });
      final receipt = await _run([
        update,
        _case('setStar', 'star'),
      ], server: server);
      final rows = _rows(receipt);
      expect(rows.first['outcome'], 'succeeded');
      expect(rows.first['readback'], 'NOT_VERIFIED');
      expect(rows.first['status'], 'NOT_VERIFIED');
      expect(rows.last['status'], 'NOT_RUN');
      expect(rows.last['reason'], 'sessionStopped');
      expect(rows.last['mutationCount'], 0);
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  for (final operation in ['setStar', 'createNote', 'createDraftNote']) {
    test('REST $operation lost reply stops without retry or cleanup', () async {
      final server = Mr7SyntheticGitLab()..lostWriteReply = true;
      configureMr7RestFixtures(server);
      final source = executable
          .firstWhere((c) => c.operation == operation)
          .scenario!;
      final receipt = await _run([
        source,
        _case('setStar', 'unstar'),
      ], server: server);
      final rows = _rows(receipt);
      expect(rows.first['status'], 'writeUncertain');
      expect(rows.first['mutationCount'], 1);
      expect(rows.first['readback'], 'NOT_RUN');
      expect(rows.last['status'], 'NOT_RUN');
      expect(rows.last['mutationCount'], 0);
      expect(rows.last['reason'], 'sessionStopped');
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    });
  }

  test('REST no observer request cannot close a successful write', () async {
    final source = _case('setStar', 'star');
    final skip = Mr7Scenario(
      id: source.id,
      suite: 'rest',
      operation: source.operation,
      variant: 'unverified',
      tier: source.tier,
      call: source.call,
      paths: source.paths,
      observe: (_, _) async => true,
    );
    final receipt = await _run([skip, _case('setStar', 'unstar')]);
    expect(_rows(receipt).first['observerRequests'], 0);
    expect(_rows(receipt).first['status'], 'NOT_VERIFIED');
    expect(_rows(receipt).last['status'], 'NOT_RUN');
    expect(receipt['quarantined'], isTrue);
  });

  test(
    'REST foreign project proposal never reaches synthetic server',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      final forged = _callWith(_case('setStar', 'star'), {
        'projectId': mr7ProtectedProjectId,
      });
      final receipt = await _run([forged], server: server);
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(server.scenarioWrites, 0);
      expect(
        server.requests.any((r) => r.contains('$mr7ProtectedProjectId')),
        isFalse,
      );
    },
  );

  test(
    'REST stale API version after confirmation blocks exact update',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      final receipt = await _run(
        [_case('updateNote', 'issue')],
        server: server,
        confirm: (_) async {
          server.routes['GET projects/909/issues/1/notes/301'] = (_) =>
              mr7Json({
                'id': 301,
                'project_id': 909,
                'body': 'Concurrent synthetic edit.',
                'updated_at': '2026-10-29T00:01:00.000Z',
                'author': {'id': 7},
              });
          return true;
        },
      );
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_rows(receipt).single['reason'], 'targetChanged');
      expect(server.scenarioWrites, 0);
    },
  );

  for (final body in [
    'synthetic-provider-key',
    '![image](https://foreign.invalid/x.png)',
    '[[attachment:att-1]]',
    '[[upload:foreignnonce-1]]',
  ]) {
    test(
      'REST unsafe text ${body.split(':').first} is refused before mutation',
      () async {
        final server = Mr7SyntheticGitLab();
        configureMr7RestFixtures(server);
        final receipt = await _run([
          _callWith(_case('createNote', 'issue'), {'body': body}),
        ], server: server);
        expect(_rows(receipt).single['status'], isNot('PASS'));
        expect(_rows(receipt).single['mutationCount'], 0);
        expect(server.scenarioWrites, 0);
        expect(jsonEncode(receipt), isNot(contains(body)));
      },
    );
  }

  test(
    'REST foreign event quarantines the session and all later cases',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      final receipt = await _run(
        [_case('createNote', 'issue'), _case('setStar', 'star')],
        server: server,
        confirm: (_) async {
          server.addEvent(target: 123456);
          return true;
        },
      );
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(_rows(receipt).last['mutationCount'], 0);
      expect(_part(receipt, 'events')['status'], 'NOT_VERIFIED');
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  test('REST measured transport cap stops subsequent cases', () async {
    final receipt = await _run([
      _case('setStar', 'star'),
      _case('createNote', 'issue'),
    ], requestCap: 20);
    expect(receipt['requestCount'], lessThanOrEqualTo(20));
    expect(receipt['quarantined'], isTrue);
    expect(_rows(receipt).last['status'], 'NOT_RUN');
    expect(_rows(receipt).last['mutationCount'], 0);
  });

  for (final c in executable.where(
    (c) => c.variant == 'confirmation-edited-text',
  )) {
    test('REST edited cancellation ${c.id} sends nothing', () async {
      var confirmations = 0;
      final receipt = await _run([
        c.scenario!,
      ], confirm: (_) async => ++confirmations == 1);
      expect(confirmations, 2);
      expect(
        _rows(receipt).single['status'],
        'NOT_RUN',
        reason: jsonEncode(receipt),
      );
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_part(receipt, 'cleanup')['deletionVerified'], isTrue);
    });
  }

  for (final c in executable.where(
    (c) => c.scenario!.paths(_fixtureIdentity).single.startsWith('PUT '),
  )) {
    final source = c.scenario!;
    for (final field in _updateFields(source)) {
      test(
        'REST ${c.id} omitted request $field stops and quarantines',
        () async {
          final server = Mr7SyntheticGitLab();
          configureMr7RestFixtures(server, scenario: source);
          final path = source.paths(_fixtureIdentity).single;
          final update = server.routes[path]!;
          var omitted = false;
          server.routes[path] = (request) {
            final input = Map<String, Object?>.from(request.data as Map);
            final wireField = c.operation == 'updateLabel' && field == 'name'
                ? 'new_name'
                : field;
            expect(input.containsKey(wireField), isTrue);
            input.remove(wireField);
            omitted = true;
            request.data = input;
            return update(request);
          };
          final receipt = await _run([
            source,
            _case('setStar', 'star'),
          ], server: server);
          final rows = _rows(receipt);
          expect(omitted, isTrue);
          expect(
            rows.first['coreOutcome'],
            'succeeded',
            reason: jsonEncode(rows),
          );
          expect(rows.first['readback'], 'NOT_VERIFIED');
          expect(rows.first['status'], 'NOT_VERIFIED');
          expect(rows.first['mutationCount'], 1);
          expect(rows.last['status'], 'NOT_RUN');
          expect(rows.last['reason'], 'sessionStopped');
          expect(rows.last['mutationCount'], 0);
          expect(server.scenarioWrites, 1);
          expect(server.cleanupWrites, 0);
          expect(receipt['quarantined'], isTrue);
        },
      );
    }
  }

  final childCases = executable.where(
    (c) => const {
      'renameBoard',
      'setBoardSystemListHidden',
      'updateMilestone',
      'setMilestoneState',
      'updateLabel',
      'updateDraftNote',
    }.contains(c.operation),
  );
  for (final variant in ['name', 'confirmation-edited-text']) {
    for (final flag in ['hide_backlog_list', 'hide_closed_list']) {
      test('REST renameBoard $variant snapshot rejects $flag drift', () async {
        final source = _case('renameBoard', variant);
        final server = Mr7SyntheticGitLab();
        configureMr7RestFixtures(server, scenario: source);
        _driftAfterWrite(
          server,
          source,
          flag,
          true,
          readPath: 'projects/909/boards/801',
        );
        final receipt = await _run([source], server: server);
        final row = _rows(receipt).single;
        expect(row['coreOutcome'], 'succeeded');
        expect(row['status'], 'NOT_VERIFIED');
        expect(row['readback'], 'NOT_VERIFIED');
        expect(server.scenarioWrites, 1);
        expect(server.cleanupWrites, 0);
        expect(receipt['quarantined'], isTrue);
      });
    }
  }
  for (final c in childCases) {
    final source = c.scenario!;
    final spec = source.preRead!(_fixtureIdentity).single;
    final changed = _updateFields(
      source,
    ).map((f) => f == 'state_event' ? 'state' : f).toSet();
    final omitted = spec.fields.difference(changed);
    final identityField = switch (spec.kind) {
      Mr7SnapshotKind.board => 'project',
      Mr7SnapshotKind.label => 'is_project_label',
      Mr7SnapshotKind.draftNote => 'merge_request_id',
      _ => 'project_id',
    };
    for (final field in {...omitted, identityField}) {
      test('REST ${c.id} preserves omitted $field or quarantines', () async {
        final server = Mr7SyntheticGitLab();
        configureMr7RestFixtures(server, scenario: source);
        final drift = switch (field) {
          'hide_backlog_list' || 'hide_closed_list' => true,
          'position' => null,
          'commit_id' => '2' * 40,
          'author_id' => 8,
          'merge_request_id' => 2002,
          'is_project_label' => false,
          'project' => {'id': mr7ProtectedProjectId},
          'project_id' => mr7ProtectedProjectId,
          'state' => 'closed',
          'start_date' || 'due_date' => '2027-01-15',
          'color' => '#aabbcc',
          _ => 'Unrequested synthetic drift.',
        };
        _driftAfterWrite(server, source, field, drift);
        final receipt = await _run([
          source,
          _case('setStar', 'star'),
        ], server: server);
        final rows = _rows(receipt);
        expect(
          rows.first['coreOutcome'],
          'succeeded',
          reason: jsonEncode(rows),
        );
        expect(rows.first['readback'], 'NOT_VERIFIED');
        expect(rows.first['status'], 'NOT_VERIFIED');
        expect(rows.last['status'], 'NOT_RUN');
        expect(rows.last['reason'], 'sessionStopped');
        expect(rows.last['mutationCount'], 0);
        expect(server.scenarioWrites, 1);
        expect(server.cleanupWrites, 0);
        expect(receipt['quarantined'], isTrue);
      });
    }
  }

  for (final side in ['issue', 'mr']) {
    for (final fault in [
      'reused',
      'missing',
      'incomplete',
      'actor',
      'author',
      'parent',
      'iid',
      'type',
      'done',
    ]) {
      test('REST createTodo $side rejects $fault observation', () async {
        final source = _case('createTodo', side);
        final server = Mr7SyntheticGitLab();
        configureMr7RestFixtures(server, scenario: source);
        final resource = side == 'issue' ? 'issues' : 'merge_requests';
        final writePath = 'POST projects/909/$resource/1/todo';
        final write = server.routes[writePath]!;
        var sent = false;
        server.routes[writePath] = (request) async {
          final result = await write(request);
          sent = true;
          return result;
        };
        final todo = <String, Object?>{
          'id': 10000,
          'project_id': 909,
          'actor_id': fault == 'actor' ? 8 : 7,
          'author': {'id': fault == 'author' ? 8 : 7},
          'target_type': fault == 'type'
              ? side == 'issue'
                    ? 'MergeRequest'
                    : 'Issue'
              : side == 'issue'
              ? 'Issue'
              : 'MergeRequest',
          'target_id': fault == 'parent'
              ? 999
              : side == 'issue'
              ? 1001
              : 2001,
          'target_iid': fault == 'iid' ? 2 : 1,
          'state': fault == 'done' ? 'done' : 'pending',
        };
        server.routes['GET projects/909/todos/mr7-observation'] = (_) {
          final rows = [
            if (fault == 'reused' || sent && fault != 'missing') todo,
          ];
          return mr7Json(
            rows,
            headers: {
              'x-page': ['1'],
              'x-next-page': [''],
              'x-total': [
                sent && fault == 'incomplete' ? '2' : '${rows.length}',
              ],
              'x-total-pages': ['1'],
              'x-per-page': ['100'],
            },
          );
        };
        final receipt = await _run([
          source,
          _case('setStar', 'star'),
        ], server: server);
        final rows = _rows(receipt);
        expect(
          rows.first['coreOutcome'],
          'succeeded',
          reason: jsonEncode(rows),
        );
        expect(rows.first['status'], 'NOT_VERIFIED');
        expect(rows.first['mutationCount'], 1);
        expect(rows.last['status'], 'NOT_RUN');
        expect(rows.last['reason'], 'sessionStopped');
        expect(rows.last['mutationCount'], 0);
        expect(receipt['quarantined'], isTrue);
        expect(server.scenarioWrites, 1);
        expect(server.cleanupWrites, 0);
      });
    }
  }

  test(
    'REST milestone update preserves omitted state or stops and quarantines',
    () async {
      final source = _case('updateMilestone', 'title-description-dates');
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server, scenario: source);
      final update = server.routes['PUT projects/909/milestones/501']!;
      server.routes['PUT projects/909/milestones/501'] = (request) {
        request.data = {
          ...Map<String, Object?>.from(request.data as Map),
          'state_event': 'close',
        };
        return update(request);
      };
      final receipt = await _run([
        source,
        _case('setStar', 'star'),
      ], server: server);
      final rows = _rows(receipt);
      expect(rows.first['coreOutcome'], 'succeeded');
      expect(rows.first['readback'], 'NOT_VERIFIED');
      expect(rows.first['status'], 'NOT_VERIFIED');
      expect(rows.last['status'], 'NOT_RUN');
      expect(rows.last['reason'], 'sessionStopped');
      expect(rows.last['mutationCount'], 0);
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  test(
    'REST milestone observer rejects a foreign project result and stops',
    () async {
      final source = _case('createMilestone', 'title-description-dates');
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server, scenario: source);
      final create = server.routes['POST projects/909/milestones']!;
      server.routes['POST projects/909/milestones'] = (request) async {
        final response = await create(request);
        server.routes['GET projects/909/milestones/10000'] = (_) => mr7Json({
          'id': 10000,
          'iid': 10,
          'project_id': mr7ProtectedProjectId,
          'title': 'Synthetic milestone.',
          'description': 'Synthetic milestone description.',
          'start_date': '2026-10-28',
          'due_date': '2026-11-30',
        });
        return response;
      };
      final receipt = await _run([
        source,
        _case('setStar', 'star'),
      ], server: server);
      expect(
        _rows(receipt).first['status'],
        'NOT_VERIFIED',
        reason: jsonEncode(receipt),
      );
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  test('REST award removal needs complete absence, not its 204', () async {
    final source = _case('removeAwardEmoji', 'issue');
    final server = Mr7SyntheticGitLab();
    configureMr7RestFixtures(server, scenario: source);
    server.routes['DELETE projects/909/issues/1/award_emoji/601'] = (_) {
      server.scenarioWrites++;
      server.addEvent(target: 909);
      return mr7Json({}, status: 204);
    };
    final receipt = await _run([
      source,
      _case('setStar', 'star'),
    ], server: server);
    expect(
      _rows(receipt).first['status'],
      'NOT_VERIFIED',
      reason: jsonEncode(receipt),
    );
    expect(_rows(receipt).last['mutationCount'], 0);
    expect(receipt['quarantined'], isTrue);
    expect(server.cleanupWrites, 0);
  });

  test(
    'REST discussion membership mismatch defeats an acknowledgement',
    () async {
      final source = _case('createDiscussion', 'issue-unpositioned');
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server, scenario: source);
      final create = server.routes['POST projects/909/issues/1/discussions']!;
      server
          .routes['POST projects/909/issues/1/discussions'] = (request) async {
        final response = await create(request);
        server.routes['GET projects/909/issues/1/discussions/synthetic-created-12001'] =
            (_) => mr7Json({
              'id': 'synthetic-created-12001',
              'project_id': 909,
              'notes': [
                {
                  'id': 777,
                  'noteable_id': 1001,
                  'resolved': false,
                  'body': 'Synthetic discussion issue-unpositioned.',
                  'author': {'id': 7},
                },
              ],
            });
        return response;
      };
      final receipt = await _run([source], server: server);
      expect(_rows(receipt).single['status'], 'NOT_VERIFIED');
      expect(receipt['quarantined'], isTrue);
    },
  );

  for (final c in executable.where(
    (c) => const {
      'createDiscussionNote',
      'updateDiscussionNote',
    }.contains(c.operation),
  )) {
    test('REST discussion note ${c.id} rejects reused or new identity', () async {
      final source = c.scenario!;
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server, scenario: source);
      final create = c.operation == 'createDiscussionNote';
      final mr = c.variant == 'mr';
      final parent = 'projects/909/${mr ? 'merge_requests' : 'issues'}/1';
      final path = '$parent/discussions/synthetic-thread';
      final read = server.routes['GET $path']!;
      final seed = mr ? 312 : 311;
      server.routes['${create ? 'POST' : 'PUT'} $path/notes${create ? '' : '/$seed'}'] =
          (request) async {
            final before = await read(request);
            final thread = Map<String, Object?>.from(
              jsonDecode(await utf8.decoder.bind(before.stream).join()) as Map,
            );
            final notes = thread['notes']! as List;
            final note = Map<String, Object?>.from(notes.first as Map);
            note['body'] = (request.data! as Map)['body'];
            if (create) {
              notes[0] = note;
            } else {
              note['id'] = 48001;
              notes.add(note);
            }
            server.routes['GET $path'] = (_) => mr7Json(thread);
            server.scenarioWrites++;
            server.addEvent(target: 909);
            return mr7Json(note, status: create ? 201 : 200);
          };
      final receipt = await _run([
        source,
        _case('setStar', 'star'),
      ], server: server);
      expect(_rows(receipt).first['coreOutcome'], 'succeeded');
      expect(_rows(receipt).first['status'], 'NOT_VERIFIED');
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    });
  }

  for (final check in [
    ('updateIssue', 'issues', 'title', 'Unexpected server-side change.'),
    ('updateIssue', 'issues', 'confidential', false),
    ('updateIssue', 'issues', 'severity', 'critical'),
    (
      'updateMergeRequest',
      'merge_requests',
      'reviewers',
      [
        {'id': 7},
      ],
    ),
  ]) {
    test(
      'REST omitted ${check.$2} ${check.$3} is independently preserved',
      () async {
        final source = _case(check.$1, 'confirmation-edited-text');
        final server = Mr7SyntheticGitLab();
        configureMr7RestFixtures(server, scenario: source);
        final path = 'projects/909/${check.$2}/1';
        final update = server.routes['PUT $path']!;
        final read = server.routes['GET $path']!;
        server.routes['PUT $path'] = (request) async {
          final response = await update(request);
          server.routes['GET $path'] = (request) async {
            final observed = await read(request);
            final value = Map<String, Object?>.from(
              jsonDecode(await utf8.decoder.bind(observed.stream).join())
                  as Map,
            );
            value[check.$3] = check.$4;
            return mr7Json(value);
          };
          return response;
        };
        final receipt = await _run([
          source,
          _case('setStar', 'star'),
        ], server: server);
        expect(_rows(receipt).first['status'], 'NOT_VERIFIED');
        expect(_rows(receipt).first['snapshotVerified'], isFalse);
        expect(_rows(receipt).last['status'], 'NOT_RUN');
        expect(server.scenarioWrites, 1);
        expect(server.cleanupWrites, 0);
        expect(receipt['quarantined'], isTrue);
      },
    );
  }

  test('REST no-op wrong parent state cannot certify a 304', () async {
    final source = _case('setSubscribed', 'issue-already-matching-304');
    final server = Mr7SyntheticGitLab();
    configureMr7RestFixtures(server, scenario: source);
    server.routes['POST projects/909/issues/1/unsubscribe'] = (_) {
      server.routes['GET projects/909/issues/1'] = (_) => mr7Json({
        'id': 1001,
        'iid': 1,
        'project_id': 909,
        'subscribed': true,
      });
      return mr7Json({}, status: 304);
    };
    final receipt = await _run([source], server: server);
    expect(_rows(receipt).single['status'], isNot('PASS'));
    expect(receipt['quarantined'], isTrue);
  });

  test(
    'REST unapprove observer requires actor absence from approved_by',
    () async {
      final source = _case('unapproveMergeRequest', 'approved');
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server, scenario: source);
      server.routes['GET projects/909/merge_requests/1/approvals'] = (_) =>
          mr7Json({
            'id': 2001,
            'iid': 1,
            'project_id': 909,
            'approved_by': [
              {
                'user': {'id': 7},
              },
            ],
          });
      final receipt = await _run([source], server: server);
      expect(_rows(receipt).single['status'], 'NOT_VERIFIED');
      expect(server.cleanupWrites, 0);
    },
  );

  test('REST already-unapproved 409 remains failedCertain', () async {
    final source = _case('unapproveMergeRequest', 'approved');
    final server = Mr7SyntheticGitLab();
    configureMr7RestFixtures(server, scenario: source);
    server.routes['POST projects/909/merge_requests/1/unapprove'] = (_) =>
        mr7Json({}, status: 409);
    final receipt = await _run([source], server: server);
    expect(_rows(receipt).single['coreOutcome'], 'failedCertain');
    expect(_rows(receipt).single['readback'], 'NOT_RUN');
    expect(_rows(receipt).single['status'], isNot('PASS'));
    expect(_rows(receipt).single['classification'], isNot('verifiedNoOp'));
    expect(server.scenarioWrites, 0);
  });

  for (final sharedConversation in [true, false]) {
    test(
      sharedConversation
          ? 'REST provenance scripted same-field roundtrip preserves the upload'
          : 'REST provenance crossnonce refuses a token from another conversation',
      () async {
        final server = Mr7SyntheticGitLab();
        _provenanceFixture(server, 'Original ![shot]($_provenanceLink)');
        final requests = <Map<String, Object?>>[];
        final receipt = await _run(
          [
            _provenanceCase(
              'provenance-first',
              description: 'First ![shot]([[upload:u-1]])',
              readFirst: true,
              requests: requests,
            ),
            _provenanceCase(
              'provenance-second',
              description: 'Second ![shot]([[upload:u-1]])',
              readFirst: false,
              requests: requests,
            ),
          ],
          server: server,
          conversationId: sharedConversation ? 'rest-provenance-shared' : null,
        );
        final rows = _rows(receipt);
        expect(rows.first['status'], 'PASS', reason: jsonEncode(receipt));
        expect(rows.first['readback'], 'PASS');
        expect(rows.first['snapshotVerified'], isTrue);
        expect(
          rows.first['confirmationReasons'],
          isNot(contains('wholeFieldDropsHiddenSpans')),
        );
        expect(requests.length, greaterThanOrEqualTo(4));
        expect(jsonEncode(requests[1]), contains('[[upload:u-1]]'));
        expect(jsonEncode(requests), isNot(contains(_provenanceSecret)));
        expect(jsonEncode(receipt), isNot(contains(_provenanceSecret)));
        if (sharedConversation) {
          expect(rows.last['status'], 'PASS', reason: jsonEncode(receipt));
          expect(rows.last['readback'], 'PASS');
          expect(rows.last['snapshotVerified'], isTrue);
          expect(server.scenarioWrites, 2);
        } else {
          expect(rows.last['coreOutcome'], 'notExecuted');
          expect(rows.last['reason'], text.AiTextBlockCode.rereadField);
          expect(rows.last['status'], 'FAIL');
          expect(rows.last['mutationCount'], 0);
          expect(server.scenarioWrites, 1);
        }
      },
    );
  }

  test('REST restored-display token requires a fresh field read', () {
    final instance = GitLabInstance.parse('https://gitlab.invalid/install');
    final field = text.AiFieldProvenance.gitLab(
      instance: instance,
      projectId: 909,
      projectPath: _fixtureIdentity.path,
      resource: 'issues',
      iid: 1,
    );
    final original = text.UploadPlaceholderTable(
      instance: instance,
      accountKey: '${instance.key}#7',
      conversationId: 'before-history-restore',
    );
    final display = original.redactOutgoing(
      'Original ![shot]($_provenanceLink)',
      field: field,
    );
    expect(display, 'Original ![shot]([[upload:u-1]])');
    final restored = text.UploadPlaceholderTable(
      instance: instance,
      accountKey: '${instance.key}#7',
      conversationId: 'after-history-restore',
    );
    final refused = restored.restoreIntoSameField(display, field);
    expect(refused.policyBlocked, isTrue);
    expect(refused.blockedReasonCode, text.AiTextBlockCode.rereadField);
    expect(restored.length, 0);
    restored.redactOutgoing('Original ![shot]($_provenanceLink)', field: field);
    final reread = restored.restoreIntoSameField(display, field);
    expect(reread.policyBlocked, isFalse);
    expect(reread.finalText, 'Original ![shot]($_provenanceLink)');
  });

  for (final accepted in [true, false]) {
    test(
      'REST hiddenSpan drop requires approval in bypass: $accepted',
      () async {
        final server = Mr7SyntheticGitLab();
        _provenanceFixture(server, 'Original ![shot]($_provenanceLink)');
        final requests = <Map<String, Object?>>[];
        var confirmations = 0;
        final receipt = await _run(
          [
            _provenanceCase(
              'provenance-hidden-span',
              description: 'Updated without the upload link.',
              readFirst: true,
              requests: requests,
            ),
          ],
          server: server,
          level: AiAutonomyLevel.bypass,
          confirm: (_) async {
            confirmations++;
            return accepted;
          },
        );
        final row = _rows(receipt).single;
        expect(row['decisionProjection'], 'observed');
        expect(row['declaredTier'], row['tier']);
        expect(row['tier'], 'T2');
        expect(row['decision'], 'requireApproval');
        expect(
          row['confirmationReasons'],
          contains('wholeFieldDropsHiddenSpans'),
        );
        expect(confirmations, greaterThan(0));
        expect(row['status'], accepted ? 'PASS' : 'NOT_RUN');
        expect(row['readback'], accepted ? 'PASS' : 'NOT_RUN');
        expect(row['mutationCount'], accepted ? 1 : 0);
        expect(server.scenarioWrites, accepted ? 1 : 0);
        expect(server.cleanupWrites, 1);
        expect(jsonEncode(requests), isNot(contains(_provenanceSecret)));
        expect(jsonEncode(receipt), isNot(contains(_provenanceSecret)));
      },
    );
  }

  test(
    'REST upload attachment content in provider turn is structurally refused',
    () async {
      final source = _case('upload_attachment', 'metadata-only-provider');
      final receipt = await _run([
        _callWith(
          source,
          const {},
          utterance: (p) => 'Upload in ${p.path}: $mr7RestUploadText',
        ),
      ]);
      final row = _rows(receipt).single;
      expect(row['status'], isNot('PASS'));
      expect(row['mutationCount'], 0);
      expect(_part(row, 'provider')['attachmentLeakScan'], 'FAIL');
      expect(_part(row, 'provider')['calls'], 0);
    },
  );

  test(
    'REST upload verifies multipart bytes and sends only provider metadata',
    () async {
      final source = _case('upload_attachment', 'multipart-memory');
      final bodies = <String>[];
      final attachments = <AiAttachmentSession>[];
      final receipt = await _run([
        _callWith(
          source,
          const {},
          setup: (session, p) async {
            final fixture = await source.fixture!(session, p);
            attachments.add(fixture.attachments!);
            return Mr7ScenarioFixtures(
              attachments: fixture.attachments,
              onProviderRequest: (body) => bodies.add(jsonEncode(body)),
            );
          },
        ),
      ]);
      expect(
        _rows(receipt).single['status'],
        'PASS',
        reason: jsonEncode(receipt),
      );
      final upload = _part(_rows(receipt).single, 'upload');
      expect(upload['byteCount'], utf8.encode(mr7RestUploadText).length);
      expect(bodies, isNotEmpty);
      expect(bodies.first, contains('attachment_metadata'));
      for (final body in bodies) {
        expect(body, isNot(contains(mr7RestUploadText)));
        expect(
          body,
          isNot(contains(base64Encode(utf8.encode(mr7RestUploadText)))),
        );
        expect(
          body,
          isNot(contains(jsonEncode(utf8.encode(mr7RestUploadText)))),
        );
      }
      expect(attachments.single.lookup('att-1'), isNull);
      expect(jsonEncode(receipt), isNot(contains(mr7RestUploadText)));
    },
  );

  test(
    'REST timed-out upload remains uncertain without retry or cleanup',
    () async {
      final source = _case('upload_attachment', 'multipart-memory');
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server, scenario: source);
      server.routes['POST projects/909/uploads'] = (request) {
        server.scenarioWrites++;
        server.addEvent(target: 909);
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.sendTimeout,
        );
      };
      final receipt = await _run([
        source,
        _case('setStar', 'star'),
      ], server: server);
      expect(_rows(receipt).first['status'], 'writeUncertain');
      expect(_rows(receipt).first['mutationCount'], 1);
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  test(
    'REST shared request meter enforces 39/40/41 without widening limits',
    () async {
      final budget = AiToolBudget();
      expect(
        budget.reserve(requests: 39, search: false, countCall: false),
        isNull,
      );
      expect(budget.gitLabRequests, 39);
      expect(
        budget.reserve(requests: 1, search: false, countCall: false),
        isNull,
      );
      expect(budget.gitLabRequests, 40);
      expect(
        budget.reserve(requests: 1, search: false, countCall: false),
        isNotNull,
      );
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      final receipt = await _run(
        [_case('setStar', 'star'), _case('createNote', 'issue')],
        server: server,
        sharedBudget: budget,
      );
      expect(_rows(receipt).every((r) => r['mutationCount'] == 0), isTrue);
      expect(server.scenarioWrites, 0);
      expect(budget.gitLabRequests, 40);
    },
  );

  test(
    'REST shared journal preserves conversation cap and account window across restart',
    () async {
      final scratchRoot = await Directory(
        '.dart_tool/mr7-rest',
      ).create(recursive: true);
      final scratch = await scratchRoot.createTemp('journal-');
      addTearDown(() => scratch.delete(recursive: true));
      final keys = MemoryAiJournalKeyStore();
      var clock = DateTime.utc(2026, 10, 29, 12);
      const account = 'https://gitlab.invalid/install#7';
      AiWriteJournal open(String process) => AiWriteJournal(
        keys: keys,
        applicationSupport: scratch,
        processId: process,
      )..now = () => clock;
      final initial = open('before-restart');
      await initial.recoverAfterAccountsLoaded([account]);
      await initial.ensureInitialized(account);
      Future<void> seed(
        AiWriteJournal journal,
        int index,
        String conversation,
      ) async {
        final draft = AiJournalDraft(
          executionId: 'rest-seed-$index',
          accountKey: account,
          conversationId: conversation,
          runId: 'rest-seed-run-$index',
          operationId: 'setStar',
          writeKeys: {
            AiConflictKey([account, 'project:909', 'seed:$index']),
          },
          payloadSha256: 'a' * 64,
          releaseName: 'synthetic',
          instance: 'https://gitlab.invalid/install',
          confirmed: true,
        );
        await journal.prepare(draft: draft);
        await journal.markDispatching(executionId: draft.executionId);
        await journal.finish(
          executionId: draft.executionId,
          terminal: AiJournalState.succeeded,
        );
      }

      for (var i = 0; i < 39; i++) {
        await seed(initial, i, 'shared');
      }
      final fortieth = await _run(
        [_case('setStar', 'star')],
        journal: initial,
        conversationId: 'shared',
        now: () => clock,
      );
      expect(
        _rows(fortieth).single['status'],
        'PASS',
        reason: jsonEncode(fortieth),
      );
      expect(
        initial.entries(account).where((e) => e.conversationId == 'shared'),
        hasLength(40),
      );
      final restarted = open('after-restart');
      await restarted.recoverAfterAccountsLoaded([account]);
      final fortyFirst = await _run(
        [_case('setStar', 'star')],
        journal: restarted,
        conversationId: 'shared',
        now: () => clock,
      );
      expect(_rows(fortyFirst).single['mutationCount'], 0);
      expect(_rows(fortyFirst).single['status'], isNot('PASS'));
      for (var i = 39; i < 59; i++) {
        await seed(restarted, i, 'other-$i');
      }
      final accountCapped = await _run(
        [_case('setStar', 'star')],
        journal: restarted,
        conversationId: 'fresh',
        now: () => clock,
      );
      expect(_rows(accountCapped).single['mutationCount'], 0);
      expect(_rows(accountCapped).single['status'], isNot('PASS'));
      clock = clock.add(const Duration(minutes: 61));
      final expired = await _run(
        [_case('setStar', 'star')],
        journal: restarted,
        conversationId: 'fresh',
        now: () => clock,
      );
      expect(
        _rows(expired).single['status'],
        'PASS',
        reason: jsonEncode(expired),
      );
    },
  );

  test(
    'REST ledger allowances fit production request budget without changing it',
    () {
      for (final operation in cases.map((c) => c.operation).toSet()) {
        final row = productionAiLedger.find(operation)!;
        expect(row.httpCap, inInclusiveRange(1, 40));
        expect(aiWriteRequestAllowance(operation), row.httpCap);
        expect(AiToolBudget().maxGitLabRequests, 40);
      }
    },
  );
}
