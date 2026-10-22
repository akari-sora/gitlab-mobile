import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show UploadPlaceholderTable;
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';

const _timeout = Duration(seconds: 20);
const _pipelineUrl = 'https://example.com/gitlab/team/example-9/-/pipelines/12';

final class _Server {
  Map<String, Object?> schedule = {
    'id': 4,
    'ref': 'feature/test',
    'variables': <Object?>[],
    'inputs': <String, Object?>{},
  };
  Map<String, Object?> job = {
    'id': 21,
    'ref': 'feature/test',
    'name': 'build',
    'stage': 'test',
    'pipeline': {'id': 12},
  };
  Map<String, Object?> pipeline = {
    'id': 12,
    'ref': 'feature/test',
    'status': 'success',
  };
  int? mutationStatus;
  int? detailStatus;
  int? readbackStatus;
  bool wrongReadback = false;
  int userId = 7;
  bool branchMissing = false;
  bool tagMissing = false;
  bool deleted = false;
  bool listIncomplete = false;
  int listPages = 0;
  int writes = 0;
  final requested = <String>[];

  ResponseBody respond(RequestOptions r) {
    final path = r.uri.path.split('/api/v4/').last;
    requested.add('${r.method} $path');
    if (r.method != 'GET') {
      writes++;
      if (mutationStatus != null) {
        return jsonResponse({'message': 'synthetic'}, status: mutationStatus!);
      }
      if (r.method == 'DELETE') {
        deleted = true;
        return ResponseBody.fromString('', 204);
      }
      if (path.endsWith('pipeline_schedules/4/play')) {
        return jsonResponse({'message': '201 Created'}, status: 201);
      }
      if (path.contains('/jobs/')) {
        return jsonResponse({...job, 'id': path.endsWith('/retry') ? 22 : 21});
      }
      if (path.endsWith('/pipeline')) {
        return jsonResponse({...pipeline, 'id': 13});
      }
      return jsonResponse(pipeline);
    }
    if (writes > 0 && readbackStatus != null) {
      return jsonResponse({'message': 'synthetic'}, status: readbackStatus!);
    }
    if (path == 'user') {
      return jsonResponse({'id': userId, 'username': 'tester'});
    }
    if (path == 'projects/9') {
      return jsonResponse(projectJson(9));
    }
    if (path.contains('/repository/branches/')) {
      return jsonResponse({
        'name': 'feature/test',
      }, status: branchMissing ? 404 : 200);
    }
    if (path.contains('/repository/tags/')) {
      return jsonResponse({
        'name': 'feature/test',
      }, status: tagMissing ? 404 : 200);
    }
    if (path == 'projects/9/pipeline_schedules/4') {
      return jsonResponse(
        schedule,
        status: writes == 0 ? detailStatus ?? 200 : 200,
      );
    }
    if (path == 'projects/9/pipeline_schedules') {
      listPages++;
      final page = int.parse(r.uri.queryParameters['page'] ?? '1');
      return jsonResponse(
        page == 1
            ? [
                {'id': 4, 'ref': 'feature/test'},
              ]
            : [],
        headers: (listIncomplete || page == 1)
            ? {
                'x-next-page': ['${page + 1}'],
              }
            : {},
      );
    }
    if (path.startsWith('projects/9/jobs/')) {
      final id = int.parse(path.split('/').last);
      return jsonResponse({
        ...job,
        'id': id,
        if (writes > 0 && wrongReadback) 'pipeline': {'id': 999},
      });
    }
    if (path.startsWith('projects/9/pipelines/')) {
      final id = int.parse(path.split('/').last);
      return jsonResponse({
        ...pipeline,
        'id': writes > 0 && wrongReadback ? 999 : id,
      }, status: deleted ? 404 : 200);
    }
    throw StateError('Unexpected fake request: ${r.method} $path');
  }
}

final class _Rows implements AiCapabilityLedger {
  const _Rows();
  @override
  AiCapability? find(String id) {
    final row = productionAiLedger.find(id);
    if (row == null) return null;
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      namedMethod: row.namedMethod,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final row in aiCiRows) find(row.operationId)!,
  ];
}

final class _Fixture {
  _Fixture(this.server, this.h, this.journal, this.files, this.keys);
  final _Server server;
  final CoordHarness h;
  final AiWriteJournal journal;
  final AiJournalFiles files;
  final MemoryAiJournalKeyStore keys;
  AiToolCall? currentCall;
  var callId = 0;
  Set<String> secrets = {};

  static Future<_Fixture> create() async {
    final server = _Server();
    final h = await CoordHarness.create(responder: server.respond);
    final keys = MemoryAiJournalKeyStore();
    final files = AiJournalFiles(Directory('${h.root.path}/p9')..createSync());
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: files.applicationSupport,
      files: files,
    );
    await journal.recoverAfterAccountsLoaded([coordAccount]);
    await journal.ensureInitialized(coordAccount);
    final f = _Fixture(server, h, journal, files, keys);
    h.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: coordScope,
        level: h.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-v3',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        appInForeground: true,
        clientMayStart: true,
      ),
      createPort: () => port.GitLabAiWritePort(h.api, accountKey: coordAccount),
      journal: journal,
      conversationId: 'p9-ci',
      budget: () => h.budget,
      readFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      placeholders: UploadPlaceholderTable(instance: h.api.instance),
      knownSecrets: () => f.secrets,
      safeDisplay: (value) => value,
      ledger: const _Rows(),
      now: () => h.clock,
    );
    return f;
  }

  Future<AiWriteProposal?> propose(
    String op,
    Map<String, Object?> args, {
    String user = '',
  }) {
    h.newRun(user);
    currentCall = AiToolCall(
      id: 'p9-${++callId}',
      name: op,
      arguments: {'projectId': 9, ...args, 'reason': 'synthetic request'},
    );
    return h.coordinator.propose(currentCall!);
  }

  Future<AiWriteOutcome> automatic(AiWriteProposal proposal) =>
      h.coordinator.execute(currentCall!);

  Future<String> journalJson() async => jsonEncode(
    await AiHistoryCipher.decryptJson(
      (await files.read(coordAccount))!,
      keys.keys[coordAccount]!,
      coordAccount,
      AiJournalFiles.fileName,
    ),
  );

  AiWriteOutcome? get outcome => h.coordinator.outcomeFor('p9-$callId');

  port.AiWriteRequest request(
    String op,
    Map<String, Object?> args, {
    String id = 'direct',
    List<int>? key,
    AiWriteScope scope = coordScope,
  }) => port.AiWriteRequest(
    operationId: op,
    executionId: id,
    scope: scope,
    scheduleHmacKey: key ?? journal.scheduleHmacKey,
    arguments: {'projectId': 9, ...args},
  );
}

Map<String, Object?> _actionArgs(String op, String action) => {
  if (op == 'pipelineAction') 'pipelineId': 12 else 'jobId': 21,
  'action': action,
};

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async => f.h.dispose());

  test('CI ledger is closed, hidden and independently HTTP-counted', () {
    expect(aiCiRows.map((r) => r.operationId).toSet(), {
      'createPipeline',
      'pipelineAction',
      'jobAction',
      'playPipelineSchedule',
      'deletePipeline',
    });
    const expected = {
      'createPipeline': 19,
      'pipelineAction': 15,
      'jobAction': 15,
      'playPipelineSchedule': 23,
      'deletePipeline': 15,
    };
    for (final row in aiCiRows) {
      expect(row.modelVisible, isFalse);
      expect(row.httpCap, expected[row.operationId]);
      expect(row.readback, isTrue);
      expect(row.namedMethod, row.operationId);
      expect(row.scopeClass, AiScopeClass.project);
    }
    for (final op in ['pipelineAction', 'jobAction']) {
      expect(
        productionAiLedger.find(op)!.arguments.keys,
        unorderedEquals([
          'projectId',
          op == 'jobAction' ? 'jobId' : 'pipelineId',
          'action',
        ]),
      );
    }
    expect(f.h.coordinator.specs, hasLength(5));
    for (final spec in f.h.coordinator.specs) {
      expect(spec.parameters['additionalProperties'], isFalse);
      if (spec.name == 'pipelineAction' || spec.name == 'jobAction') {
        expect(
          (spec.parameters['properties']! as Map).keys,
          isNot(contains('variables')),
        );
      }
    }
  });

  for (final (op, action) in [
    ('pipelineAction', 'retry'),
    ('jobAction', 'retry'),
    ('jobAction', 'play'),
  ]) {
    for (final level in [
      AiAutonomyLevel.confirmEach,
      AiAutonomyLevel.lowRiskAuto,
      AiAutonomyLevel.conversationGrant,
    ]) {
      test(
        '$op $action $level confirms without a name or pre-confirm POST',
        () async {
          f.h.level = level;
          final proposal = await f.propose(
            op,
            _actionArgs(op, action),
            user: _pipelineUrl,
          );
          expect(proposal, isNotNull);
          expect(proposal!.tier.tier, AiWriteTier.t4);
          expect(proposal.tier.decision, AiGateDecision.requireApproval);
          expect(proposal.tier.requiresTypedName, isFalse);
          expect(proposal.tier.typedName, isNull);
          expect(proposal.tier.reusesStoredVariables, isTrue);
          expect(f.server.writes, 0);
          final preview = proposal.preview as port.AiPipelinePreview;
          expect(preview.ref, 'feature/test');
          expect(preview.pipelineId, 12);
          if (op == 'jobAction') {
            expect(preview.jobId, 21);
            expect(preview.jobName, 'build');
            expect(preview.stage, 'test');
          }
          final result = await f.h.coordinator.approve(proposal);
          expect(result.state, AiJournalState.succeeded);
          expect(f.server.writes, 1);
          final write = f.h.adapter.requests.singleWhere(
            (r) => r.method == 'POST',
          );
          expect(write.data, <String, Object?>{});
          expect(
            f.server.requested.any(
              (r) =>
                  r.contains('variables') ||
                  r.contains('manualJob') ||
                  r.contains('/source'),
            ),
            isFalse,
          );
          expect(f.h.adapter.requests, hasLength(8));
        },
      );
    }

    test('$op $action bypass binds only user URLs', () async {
      f.h.level = AiAutonomyLevel.bypass;
      final unbound = await f.propose(op, _actionArgs(op, action));
      expect(unbound!.tier.decision, AiGateDecision.requireApproval);
      expect(unbound.tier.requiresTypedName, isFalse);
      expect(f.server.writes, 0);
      await f.h.coordinator.reject(unbound);
      final bound = await f.propose(
        op,
        _actionArgs(op, action),
        user: _pipelineUrl,
      );
      expect(bound!.tier.decision, AiGateDecision.execute);
      final result = await f.automatic(bound);
      expect(result.state, AiJournalState.succeeded);
      expect(f.server.writes, 1);
    });

    for (final extra in ['variables', 'inputs', 'job_variables_attributes']) {
      test('$op $action rejects extra $extra at both boundaries', () async {
        final args = {..._actionArgs(op, action), extra: <Object?>[]};
        expect(await f.propose(op, args), isNull);
        expect(f.outcome!.reasonCode, 'invalidArguments');
        final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
        await expectLater(p.prepare(f.request(op, args)), throwsA(anything));
        expect(f.h.adapter.requests, isEmpty);
      });
    }
  }

  for (final op in ['pipelineAction', 'jobAction']) {
    test('$op cancel remains T3 with after_script disclosure', () async {
      f.h.level = AiAutonomyLevel.conversationGrant;
      final proposal = await f.propose(
        op,
        _actionArgs(op, 'cancel'),
        user: _pipelineUrl,
      );
      expect(proposal!.tier.tier, AiWriteTier.t3);
      expect(proposal.tier.decision, AiGateDecision.execute);
      expect(proposal.tier.cancelMayRunAfterScript, isTrue);
      expect(proposal.tier.reusesStoredVariables, isFalse);
    });
  }

  test(
    'bypass fixed confirmation still applies to retry without a name',
    () async {
      f.h.level = AiAutonomyLevel.bypass;
      final first = await f.propose(
        'pipelineAction',
        _actionArgs('pipelineAction', 'retry'),
        user: _pipelineUrl,
      );
      await f.automatic(first!);
      final again = await f.propose(
        'pipelineAction',
        _actionArgs('pipelineAction', 'retry'),
        user: _pipelineUrl,
      );
      expect(again!.tier.decision, AiGateDecision.requireApproval);
      expect(
        again.tier.reasons,
        contains(AiFixedConfirmReason.duplicateOfSettledWrite),
      );
      expect(again.tier.requiresTypedName, isFalse);
      expect(f.server.writes, 1);
    },
  );

  for (final withVariables in [false, true]) {
    for (final level in [
      AiAutonomyLevel.confirmEach,
      AiAutonomyLevel.lowRiskAuto,
      AiAutonomyLevel.conversationGrant,
      AiAutonomyLevel.bypass,
    ]) {
      test(
        'createPipeline variables=$withVariables $level uses verified ref',
        () async {
          f.h.level = level;
          final proposal = await f.propose('createPipeline', {
            'ref': 'feature/test',
            if (withVariables)
              'variables': [
                {'key': 'DEPLOY_REGION', 'value': 'synthetic'},
              ],
          }, user: '`feature/test`');
          expect(proposal, isNotNull);
          expect(
            proposal!.tier.tier,
            withVariables ? AiWriteTier.hardLine : AiWriteTier.t4,
          );
          expect(
            proposal.tier.requiresTypedName,
            withVariables || level != AiAutonomyLevel.bypass,
          );
          expect(proposal.tier.typedName, 'feature/test');
          expect(f.server.writes, 0);
          final result = proposal.tier.decision == AiGateDecision.execute
              ? await f.automatic(proposal)
              : await f.h.coordinator.approve(
                  proposal,
                  typedName: 'feature/test',
                );
          expect(result.state, AiJournalState.succeeded);
          final entry = f.journal.entries(coordAccount).single;
          expect(entry.releaseName, 'team/example-9');
          expect(entry.writeKeys.single.parts, [
            coordAccount,
            'project:9',
            'pipeline',
          ]);
        },
      );
    }
  }

  for (final action in ['retry', 'play']) {
    for (final status in ['manual', 'running', 'success', 'canceled']) {
      test(
        'job $action is confirmation-only even with status $status',
        () async {
          f.h.level = AiAutonomyLevel.conversationGrant;
          f.server.job['status'] = status;
          final proposal = await f.propose('jobAction', {
            'jobId': 21,
            'action': action,
          });
          expect(proposal!.tier.tier, AiWriteTier.t4);
          expect(proposal.tier.decision, AiGateDecision.requireApproval);
          expect(proposal.tier.requiresTypedName, isFalse);
          expect(f.server.writes, 0);
        },
      );
    }
  }

  test(
    'empty schedule under a conversation grant requires its verified ref',
    () async {
      f.h.level = AiAutonomyLevel.conversationGrant;
      final proposal = await f.propose('playPipelineSchedule', {
        'scheduleId': 4,
      }, user: '`feature/test`');
      expect(proposal!.tier.tier, AiWriteTier.t4);
      expect(proposal.tier.requiresTypedName, isTrue);
      expect(proposal.tier.typedName, 'feature/test');
      expect(f.server.writes, 0);
    },
  );

  test(
    'create result binds new pipeline and its jobs in the segment',
    () async {
      f.h.level = AiAutonomyLevel.bypass;
      final create = await f.propose('createPipeline', {
        'ref': 'feature/test',
      }, user: '`feature/test`');
      expect((await f.automatic(create!)).state, AiJournalState.succeeded);
      f.server.job = {
        ...f.server.job,
        'pipeline': {'id': 13},
      };
      final job = await f.propose('jobAction', {
        'jobId': 21,
        'action': 'retry',
      });
      expect(job!.tier.decision, AiGateDecision.execute);
      final pipeline = await f.propose('pipelineAction', {
        'pipelineId': 13,
        'action': 'retry',
      });
      expect(pipeline!.tier.decision, AiGateDecision.execute);
    },
  );

  for (final variables in [
    [
      {'key': 'CI_DEBUG_TRACE', 'value': 'true'},
    ],
    [
      {'key': 'GITLAB_TOKEN', 'value': 'safe'},
    ],
    [
      {'key': 'FOO_DEBUG_BAR', 'value': 'true'},
    ],
    [
      {'key': 'A', 'value': 'safe', 'masked': true},
    ],
  ]) {
    test('create refuses forbidden variables $variables', () async {
      final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
      await expectLater(
        p.prepare(
          f.request('createPipeline', {
            'ref': 'feature/test',
            'variables': variables,
          }),
        ),
        throwsA(
          isA<port.AiWriteRefused>().having(
            (e) => e.reason,
            'code',
            'pipelineVariableForbidden',
          ),
        ),
      );
      expect(f.server.writes, 0);
    });
  }

  test(
    'pipeline variable secrets rejected by port patterns and coordinator live union',
    () async {
      final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
      await expectLater(
        p.prepare(
          f.request('createPipeline', {
            'ref': 'feature/test',
            'variables': [
              {'key': 'REGION', 'value': 'glpat-ABCDEFGHIJKLMNOPQRST'},
            ],
          }),
        ),
        throwsA(
          isA<port.AiWriteRefused>().having(
            (e) => e.reason,
            'code',
            'pipelineVariableSecret',
          ),
        ),
      );
      f.secrets = {'unique-synthetic-credential'};
      expect(
        await f.propose('createPipeline', {
          'ref': 'feature/test',
          'variables': [
            {'key': 'REGION', 'value': 'unique-synthetic-credential'},
          ],
        }),
        isNull,
      );
      expect(f.server.writes, 0);
    },
  );

  test(
    'ref read is encoded and missing branch/tag never produces a proposal',
    () async {
      f.server.branchMissing = true;
      f.server.tagMissing = true;
      final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
      await expectLater(
        p.prepare(f.request('createPipeline', {'ref': 'feature/test'})),
        throwsA(
          isA<port.AiWriteRefused>().having(
            (e) => e.reason,
            'code',
            'refMissing',
          ),
        ),
      );
      final branch = f.h.adapter.requests.firstWhere(
        (r) => r.uri.path.contains('/branches/'),
      );
      expect(branch.uri.pathSegments.last, 'feature/test');
      expect(f.server.writes, 0);
    },
  );

  test(
    'job parent membership verified, sibling keys remain independent',
    () async {
      final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
      final job = await p.prepare(
        f.request('jobAction', {'jobId': 21, 'action': 'play'}),
      );
      final sibling = await p.prepare(
        f.request('jobAction', {'jobId': 23, 'action': 'retry'}),
      );
      final pipeline = await p.prepare(
        f.request('pipelineAction', {'pipelineId': 12, 'action': 'retry'}),
      );
      expect(job.writeKeys.single.parts, [
        coordAccount,
        'project:9',
        'pipeline',
        '12',
        'job',
        '21',
      ]);
      expect(
        job.writeKeys.single.intersects(sibling.writeKeys.single),
        isFalse,
      );
      expect(
        job.writeKeys.single.intersects(pipeline.writeKeys.single),
        isTrue,
      );
      expect(job.releaseName, '21');
      f.server.job = {
        ...f.server.job,
        'pipeline': {'id': 12, 'project_id': 99},
      };
      await expectLater(
        p.prepare(f.request('jobAction', {'jobId': 21, 'action': 'retry'})),
        throwsA(
          isA<port.AiWriteRefused>().having(
            (e) => e.reason,
            'code',
            'jobNotInPipeline',
          ),
        ),
      );
    },
  );

  for (final params in <Map<String, Object?>>[
    {'variables': <Object?>[], 'inputs': <Object?>[]},
    {'variables': <Object?>[], 'inputs': <String, Object?>{}},
    {
      'variables': [
        {'key': 'REGION', 'value': 'hidden-value', 'variable_type': 'env_var'},
      ],
      'inputs': [],
    },
    {
      'variables': [],
      'inputs': {'region': 'hidden-input'},
    },
    {'variables': []},
    {'variables': null, 'inputs': null},
  ]) {
    test(
      'schedule parameters ${jsonEncode(params)} have conservative tier and private preview',
      () async {
        f.h.level = AiAutonomyLevel.bypass;
        f.server.schedule = {'id': 4, 'ref': 'feature/test', ...params};
        final proposal = await f.propose('playPipelineSchedule', {
          'scheduleId': 4,
        }, user: '`feature/test`');
        final empty =
            params['variables'] is List &&
            (params['variables']! as List).isEmpty &&
            ((params['inputs'] is List &&
                    (params['inputs']! as List).isEmpty) ||
                (params['inputs'] is Map &&
                    (params['inputs']! as Map).isEmpty));
        expect(
          proposal!.tier.tier,
          empty ? AiWriteTier.t4 : AiWriteTier.hardLine,
        );
        expect(proposal.tier.requiresTypedName, !empty);
        final preview = proposal.preview as port.AiPipelinePreview;
        expect(preview.scheduleVariableNames, isNot(contains('hidden-value')));
        expect(proposal.previewText, isNot(contains('hidden-value')));
        expect(proposal.previewText, isNot(contains('hidden-input')));
        expect(f.server.writes, 0);
        final outcome = empty
            ? await f.automatic(proposal)
            : await f.h.coordinator.approve(
                proposal,
                typedName: 'feature/test',
              );
        expect(outcome.state, AiJournalState.succeeded);
        expect(await f.journalJson(), isNot(contains('hidden-value')));
        expect(await f.journalJson(), isNot(contains('hidden-input')));
      },
    );
  }

  for (final change in [
    'variableValue',
    'inputValue',
    'inputType',
    'readability',
    'ref',
  ]) {
    test('schedule $change invalidates old approval without POST', () async {
      f.h.level = AiAutonomyLevel.bypass;
      f.server.schedule = {
        'id': 4,
        'ref': 'feature/test',
        'variables': [
          {'key': 'REGION', 'value': 'one', 'variable_type': 'env_var'},
        ],
        'inputs': {'count': 1},
      };
      final proposal = await f.propose('playPipelineSchedule', {
        'scheduleId': 4,
      });
      switch (change) {
        case 'variableValue':
          f.server.schedule['variables'] = [
            {'key': 'REGION', 'value': 'two', 'variable_type': 'env_var'},
          ];
        case 'inputValue':
          f.server.schedule['inputs'] = {'count': 2};
        case 'inputType':
          f.server.schedule['inputs'] = {'count': '1'};
        case 'readability':
          f.server.schedule.remove('inputs');
        case 'ref':
          f.server.schedule['ref'] = 'other';
      }
      final result = await f.h.coordinator.approve(
        proposal!,
        typedName: 'feature/test',
      );
      expect(result.state, AiJournalState.notExecuted);
      expect(result.reasonCode, 'targetChanged');
      expect(f.server.writes, 0);
    });
  }

  test(
    'schedule read failure verifies ref via bounded complete list, never empty parameters',
    () async {
      f.h.level = AiAutonomyLevel.bypass;
      f.server.detailStatus = 403;
      final proposal = await f.propose('playPipelineSchedule', {
        'scheduleId': 4,
      });
      expect(proposal!.tier.tier, AiWriteTier.hardLine);
      expect(
        (proposal.preview as port.AiPipelinePreview).scheduleParamsUnreadable,
        isTrue,
      );
      expect(f.server.listPages, 2);
      expect(f.server.writes, 0);
    },
  );

  for (final status in [401, 429, 500]) {
    test(
      'schedule detail $status preserves failure without fallback reads',
      () async {
        f.server.detailStatus = status;
        expect(
          await f.propose('playPipelineSchedule', {'scheduleId': 4}),
          isNull,
        );
        expect(f.server.listPages, 0);
        expect(f.server.writes, 0);
      },
    );
  }

  test(
    'schedule partial list is refused, missing detail gives scheduleMissing',
    () async {
      f.server.detailStatus = 403;
      f.server.listIncomplete = true;
      expect(
        await f.propose('playPipelineSchedule', {'scheduleId': 4}),
        isNull,
      );
      expect(f.outcome!.reasonCode, 'scheduleParamsUnreadable');
      expect(f.server.listPages, 2);
      f.server.detailStatus = 404;
      expect(
        await f.propose('playPipelineSchedule', {'scheduleId': 4}),
        isNull,
      );
      expect(f.outcome!.reasonCode, 'scheduleMissing');
      expect(f.server.writes, 0);
    },
  );

  test(
    'schedule HMAC is keyed, private and invalid without its process key',
    () async {
      final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
      final a = await p.prepare(
        f.request('playPipelineSchedule', {
          'scheduleId': 4,
        }, key: List.filled(32, 1)),
      );
      final b = await p.prepare(
        f.request('playPipelineSchedule', {
          'scheduleId': 4,
        }, key: List.filled(32, 2)),
      );
      expect(a.bindingDigest, isNot(b.bindingDigest));
      expect(a.journal.headSha, isNull);
      expect(a.journal.lastCommitId, isNull);
      expect(a.journal.updatedAt, isNull);
      expect(a.journal.mergeCheckSummary, isNull);
      final bad = port.AiWriteRequest(
        operationId: 'playPipelineSchedule',
        executionId: 'bad',
        scope: coordScope,
        arguments: {'projectId': 9, 'scheduleId': 4},
      );
      await expectLater(p.prepare(bad), throwsA(isA<port.AiWriteRefused>()));
    },
  );

  for (final (op, args) in [
    ('createPipeline', <String, Object?>{'ref': 'feature/test'}),
    ('pipelineAction', <String, Object?>{'pipelineId': 12, 'action': 'retry'}),
    ('jobAction', <String, Object?>{'jobId': 21, 'action': 'retry'}),
    ('playPipelineSchedule', <String, Object?>{'scheduleId': 4}),
    ('deletePipeline', <String, Object?>{'pipelineId': 12}),
  ]) {
    test('$op counts worst-case logical reads against its HTTP cap', () async {
      final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
      if (op == 'createPipeline') f.server.branchMissing = true;
      if (op == 'playPipelineSchedule') f.server.detailStatus = 403;
      await p.prepare(f.request(op, args, id: 'preview'));
      final prepared = await p.prepare(f.request(op, args, id: 'dispatch'));
      final result = await p.commit(prepared, mayStart: () => true);
      expect((result as port.AiWriteSettled).state, AiJournalState.succeeded);
      final reads = f.h.adapter.requests.where((r) => r.method == 'GET').length;
      final writes = f.h.adapter.requests
          .where((r) => r.method != 'GET')
          .length;
      expect(writes, 1);
      expect(reads * 2 + writes, productionAiLedger.find(op)!.httpCap);
      expect(
        await p.commit(prepared, mayStart: () => true),
        isA<port.AiWriteNotSent>(),
      );
    });
  }

  for (final heldOp in ['pipelineAction', 'jobAction']) {
    test(
      'unknown $heldOp blocks parent/child but siblings stay independent; release needs ID',
      () async {
        f.h.level = AiAutonomyLevel.bypass;
        f.server.mutationStatus = 500;
        final proposal = await f.propose(
          heldOp,
          _actionArgs(heldOp, 'retry'),
          user: _pipelineUrl,
        );
        final result = await f.automatic(proposal!);
        expect(result.state, AiJournalState.writeUncertain);
        final other = heldOp == 'jobAction' ? 'pipelineAction' : 'jobAction';
        expect(
          await f.propose(
            other,
            _actionArgs(other, 'retry'),
            user: _pipelineUrl,
          ),
          isNull,
        );
        expect(f.outcome!.reasonCode, 'isolated');
        final entry = f.journal.entries(coordAccount).single;
        for (final typed in [
          '',
          'wrong',
          heldOp == 'jobAction' ? '12' : '21',
        ]) {
          await expectLater(
            f.journal.releaseByUser(
              executionId: entry.executionId,
              typedName: typed,
            ),
            throwsA(isA<AiJournalException>()),
          );
        }
        expect(f.journal.isolated(coordAccount, entry.writeKeys), isTrue);
        if (heldOp == 'jobAction') {
          final sibling = await f.propose('jobAction', {
            'jobId': 23,
            'action': 'retry',
          }, user: _pipelineUrl);
          expect(sibling, isNotNull);
        }
        expect(f.server.writes, 1);
        await f.journal.releaseByUser(
          executionId: entry.executionId,
          typedName: entry.releaseName,
        );
        expect(f.journal.isolated(coordAccount, entry.writeKeys), isFalse);
      },
    );
  }

  test(
    'unknown create/schedule collection key intersects every pipeline and job',
    () async {
      final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
      final created = await p.prepare(
        f.request('createPipeline', {'ref': 'feature/test'}),
      );
      final schedule = await p.prepare(
        f.request('playPipelineSchedule', {'scheduleId': 4}),
      );
      final job = await p.prepare(
        f.request('jobAction', {'jobId': 21, 'action': 'play'}),
      );
      expect(created.writeKeys.single, schedule.writeKeys.single);
      expect(created.writeKeys.single.intersects(job.writeKeys.single), isTrue);
    },
  );

  test(
    'delete uses pipeline ID confirmation/release and independently verifies absence',
    () async {
      final proposal = await f.propose('deletePipeline', {'pipelineId': 12});
      expect(proposal!.tier.typedName, '12');
      expect(proposal.tier.requiresTypedName, isTrue);
      final result = await f.h.coordinator.approve(proposal, typedName: '12');
      expect(result.state, AiJournalState.succeeded);
      expect(result.readbackConfirmed, isTrue);
      expect(f.journal.entries(coordAccount).single.releaseName, '12');
    },
  );

  test('foreign accounts and non-project grants fail before writes', () async {
    final p = port.GitLabAiWritePort(f.h.api, accountKey: coordAccount);
    const itemOnly = AiWriteScope(
      accountKey: coordAccount,
      grants: [AiScopeGrant(kind: AiScopeKind.workItem, projectId: 9, iid: 3)],
    );
    await expectLater(
      p.prepare(
        f.request('createPipeline', {'ref': 'feature/test'}, scope: itemOnly),
      ),
      throwsA(anything),
    );
    expect(f.h.adapter.requests, isEmpty);
    f.server.userId = 8;
    await expectLater(
      p.prepare(f.request('createPipeline', {'ref': 'feature/test'})),
      throwsA(anything),
    );
    expect(f.server.writes, 0);
  });

  for (final op in ['createPipeline', 'pipelineAction', 'jobAction']) {
    test('$op rejects a successful readback for another target', () async {
      f.server.wrongReadback = true;
      final proposal = await f.propose(
        op,
        op == 'createPipeline'
            ? {'ref': 'feature/test'}
            : _actionArgs(op, 'retry'),
      );
      final result = await f.h.coordinator.approve(
        proposal!,
        typedName: op == 'createPipeline' ? 'feature/test' : null,
      );
      expect(result.state, AiJournalState.writeUncertain);
      expect(f.server.writes, 1);
    });
  }

  test(
    'readback 401 after accepted retry stays unknown and blocks a second mutation',
    () async {
      f.server.readbackStatus = 401;
      final proposal = await f.propose('jobAction', {
        'jobId': 21,
        'action': 'retry',
      });
      final result = await f.h.coordinator.approve(proposal!);
      expect(result.state, AiJournalState.writeUncertain);
      expect(f.server.writes, 1);
      expect(
        await f.propose('pipelineAction', {
          'pipelineId': 12,
          'action': 'retry',
        }),
        isNull,
      );
      expect(f.server.writes, 1);
    },
    timeout: const Timeout(_timeout),
  );
}
