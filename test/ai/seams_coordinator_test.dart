import 'release_policy_support.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' show UploadPlaceholderTable;
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';
import 'mr6b2_deletes_port_test.dart' show DeleteServer, deleteCases;

const _timeout = Duration(seconds: 20);

// Only tests expose the integrated hidden rows; production visibility is intact.
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
      editableField: row.editableField,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final row in [...aiCiRows, ...aiDeleteRows]) find(row.operationId)!,
  ];
}

final class _Server {
  final deletes = DeleteServer();
  int? mutationStatus;
  int? readbackStatus;
  bool refMissing = false;
  Map<String, List<String>> listHeaders = {};
  Object? listBody;
  int scheduleDetailStatus = 200;
  int pipelineWrites = 0;
  final listRequests = <RequestOptions>[];

  ResponseBody respond(RequestOptions r) {
    final path = r.uri.path.split('/api/v4/').last;
    if (path == 'projects/9/merge_requests/3/draft_notes' &&
        r.method == 'POST') {
      return jsonResponse({'id': 31, 'note': 'synthetic draft'}, status: 201);
    }
    if (path == 'projects/9/pipeline' && r.method == 'POST') {
      pipelineWrites++;
      return jsonResponse({'id': 13}, status: mutationStatus ?? 201);
    }
    if (path == 'projects/9/pipelines/13') {
      return jsonResponse({
        'id': 13,
        'project_id': 9,
        'ref': 'work',
        'status': 'success',
      }, status: readbackStatus ?? 200);
    }
    if (path == 'projects/9/jobs/21') {
      return jsonResponse({
        'id': 21,
        'ref': 'work',
        'name': 'build',
        'stage': 'test',
        'pipeline': {'id': 13},
      });
    }
    if (path.contains('/repository/branches/') ||
        path.contains('/repository/tags/')) {
      return jsonResponse({'name': 'work'}, status: refMissing ? 404 : 200);
    }
    if (path == 'projects/9/pipeline_schedules/4') {
      return jsonResponse({
        'id': 4,
        'ref': 'work',
        'variables': <Object?>[],
        'inputs': <String, Object?>{},
      }, status: scheduleDetailStatus);
    }
    if (path == 'projects/9/pipeline_schedules') {
      listRequests.add(r);
      final second = r.uri.queryParameters['page'] == '2';
      return jsonResponse(
        listBody ??
            (second
                ? []
                : [
                    // List parameter fields must never be treated as a complete snapshot.
                    {
                      'id': 4,
                      'ref': 'work',
                      'variables': <Object?>[],
                      'inputs': <String, Object?>{},
                    },
                  ]),
        headers: second ? {} : listHeaders,
      );
    }
    return deletes.respond(r);
  }
}

final class _CapturedPort implements port.AiGitLabWritePort {
  _CapturedPort(this.delegate);
  final port.AiGitLabWritePort delegate;
  final requests = <port.AiWriteRequest>[];
  Object? prepareError;
  AiJournalState? overrideState;
  Future<void> Function()? afterCommit;
  port.AiWritePrepared? committed;
  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    requests.add(request);
    if (prepareError case final error?) throw error;
    return delegate.prepare(request);
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) async {
    committed = prepared;
    final result = await delegate.commit(prepared, mayStart: mayStart);
    await afterCommit?.call();
    if (overrideState case final state? when result is port.AiWriteSettled) {
      return port.AiWriteSettled(
        state: state,
        resultCode: 'synthetic',
        releaseName: result.releaseName,
        writeKeys: result.writeKeys,
        dependencyKeys: result.dependencyKeys,
      );
    }
    return result;
  }
}

final class _Fixture {
  _Fixture(this.server, this.h, this.writePort);
  final _Server server;
  final CoordHarness h;
  final _CapturedPort writePort;
  AiWriteScope scope = coordScope;
  int calls = 0;

  static Future<_Fixture> create() async {
    final server = _Server();
    final h = await CoordHarness.create(responder: server.respond);
    final captured = _CapturedPort(
      port.GitLabAiWritePort(h.api, accountKey: coordAccount),
    );
    final f = _Fixture(server, h, captured);
    h.coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        scope: f.scope,
        level: h.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        appInForeground: true,
        clientMayStart: true,
      ),
      createPort: () => captured,
      journal: h.journal,
      conversationId: 'seams',
      budget: () => h.budget,
      readFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      placeholders: UploadPlaceholderTable(instance: h.api.instance),
      knownSecrets: () => {},
      safeDisplay: (v) => v,
      ledger: const _Rows(),
    );
    return f;
  }

  Future<AiWriteProposal?> propose(String op, Map<String, Object?> args) {
    h.newRun('Apply the requested change');
    return h.coordinator
        .propose(
          AiToolCall(
            id: '${++calls}',
            name: op,
            arguments: {...args, 'reason': 'synthetic request'},
          ),
        )
        .timeout(_timeout);
  }

  Future<AiWriteOutcome> approve(AiWriteProposal p) =>
      h.coordinator.approve(p, typedName: p.tier.typedName).timeout(_timeout);

  AiWriteOutcome get outcome => h.coordinator.outcomeFor('$calls')!;
}

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() => f.h.dispose());

  test(
    'server-created pipeline becomes conversation-created and binds its job',
    () async {
      final p = (await f.propose('createPipeline', {
        'projectId': 9,
        'ref': 'work',
      }))!;
      expect(f.writePort.requests.last.segmentCreated, isEmpty);
      expect((await f.approve(p)).state, AiJournalState.succeeded);
      f.h.level = AiAutonomyLevel.bypass;
      final job = (await f.propose('jobAction', {
        'projectId': 9,
        'jobId': 21,
        'action': 'cancel',
      }))!;
      expect(f.writePort.requests.last.segmentCreated, {
        const port.AiCreatedRef(
          accountKey: coordAccount,
          kind: AiTargetKind.pipeline,
          projectId: 9,
          id: 13,
        ),
      });
      expect(job.tier.decision, AiGateDecision.execute);
      expect(f.server.pipelineWrites, 1);
    },
  );

  for (final (mutation, readback, state) in [
    (400, null, AiJournalState.failedCertain),
    (500, null, AiJournalState.writeUncertain),
    (null, 401, AiJournalState.writeUncertain),
  ]) {
    test(
      'failed/uncertain pipeline $mutation/$readback never creates a ref',
      () async {
        f.server.mutationStatus = mutation;
        f.server.readbackStatus = readback;
        final p = (await f.propose('createPipeline', {
          'projectId': 9,
          'ref': 'work',
        }))!;
        expect((await f.approve(p)).state, state);
        final unrelated = await f.propose(
          'deleteIssue',
          deleteCases['deleteIssue']!.args,
        );
        expect(unrelated, isNotNull);
        expect(f.writePort.requests.last.segmentCreated, isEmpty);
        expect(f.server.pipelineWrites, 1);
      },
    );
  }

  test(
    'server-created draft note is recorded for later batch publication',
    () async {
      final p = (await f.propose('createDraftNote', {
        'projectId': 9,
        'iid': 3,
        'body': 'synthetic draft',
      }))!;
      expect((await f.approve(p)).state, AiJournalState.succeeded);
      await f.propose('deleteIssue', deleteCases['deleteIssue']!.args);
      expect(f.writePort.requests.last.segmentCreated, {
        const port.AiCreatedRef(
          accountKey: coordAccount,
          kind: AiTargetKind.note,
          projectId: 9,
          id: 31,
          parentIid: 3,
        ),
      });
    },
  );

  test('issue13 created resources survive sends and clear at a new segment',
      () async {
    final p = (await f.propose('createPipeline', {
      'projectId': 9,
      'ref': 'work',
    }))!;
    expect((await f.approve(p)).state, AiJournalState.succeeded);
    f.h.level = AiAutonomyLevel.bypass;
    final firstJob = (await f.propose('jobAction', {
      'projectId': 9, 'jobId': 21, 'action': 'cancel',
    }))!;
    expect(firstJob.tier.decision, AiGateDecision.execute);
    expect(f.writePort.requests.last.segmentCreated, hasLength(1));
    await f.h.coordinator.reject(firstJob);
    f.h.coordinator.beginSegment();
    final nextJob = (await f.propose('jobAction', {
      'projectId': 9, 'jobId': 21, 'action': 'cancel',
    }))!;
    expect(f.writePort.requests.last.segmentCreated, isEmpty);
    expect(nextJob.tier.decision, AiGateDecision.requireApproval);
    expect(nextJob.tier.reasons, contains(AiFixedConfirmReason.targetUnbound));
    expect(f.server.pipelineWrites, 1);
  });

  test('issue13 late creation cannot populate a newer segment', () async {
    final p = (await f.propose('createPipeline', {
      'projectId': 9, 'ref': 'work',
    }))!;
    final settled = Completer<void>();
    final release = Completer<void>();
    f.writePort.afterCommit = () async {
      settled.complete();
      await release.future;
    };
    final result = f.approve(p);
    await settled.future.timeout(_timeout);
    f.h.coordinator.beginSegment();
    release.complete();
    expect((await result).state, AiJournalState.succeeded);
    f.writePort.afterCommit = null;
    f.h.level = AiAutonomyLevel.bypass;
    final job = (await f.propose('jobAction', {
      'projectId': 9, 'jobId': 21, 'action': 'cancel',
    }))!;
    expect(f.writePort.requests.last.segmentCreated, isEmpty);
    expect(job.tier.decision, AiGateDecision.requireApproval);
    expect(job.tier.reasons, contains(AiFixedConfirmReason.targetUnbound));
    expect(f.server.pipelineWrites, 1);
  });

  for (final state in [
    AiJournalState.failedCertain,
    AiJournalState.writeUncertain,
  ]) {
    test(
      'resolved pipeline ID is not registered for final $state settlement',
      () async {
        f.writePort.overrideState = state;
        final p = (await f.propose('createPipeline', {
          'projectId': 9,
          'ref': 'work',
        }))!;
        expect((await f.approve(p)).state, state);
        expect(f.writePort.committed!.createdOnSuccess?.id, 13);
        await f.propose('deleteIssue', deleteCases['deleteIssue']!.args);
        expect(f.writePort.requests.last.segmentCreated, isEmpty);
      },
    );
  }

  test('family refusal retains its exact code', () async {
    f.server.refMissing = true;
    expect(
      await f.propose('createPipeline', {'projectId': 9, 'ref': 'work'}),
      isNull,
    );
    expect(f.outcome.reasonCode, 'refMissing');
    expect(f.server.pipelineWrites, 0);
  });

  test('unrelated exceptions stay preflightFailed', () async {
    f.writePort.prepareError = StateError('synthetic-unrelated');
    expect(
      await f.propose('createPipeline', {'projectId': 9, 'ref': 'work'}),
      isNull,
    );
    expect(f.outcome.reasonCode, 'preflightFailed');
  });

  test('genuine journal failure keeps its journal reason', () async {
    f.writePort.prepareError = const AiJournalException('journalUnavailable');
    expect(
      await f.propose('createPipeline', {'projectId': 9, 'ref': 'work'}),
      isNull,
    );
    expect(f.outcome.reasonCode, 'journalUnavailable');
  });

  const links = {
    'deleteIssue': 'issues',
    'deleteMergeRequest': 'merge_requests',
    'deleteLabel': 'labels',
    'deleteMilestone': 'milestones',
    'deleteBoard': 'boards',
    'deleteBoardList': 'boards/8',
    'deleteNote': 'issues/3',
    'deleteDiscussionNote': 'merge_requests/3',
  };
  for (final entry in links.entries) {
    test('${entry.key} result links to the nearest surviving parent', () async {
      final p = (await f.propose(entry.key, deleteCases[entry.key]!.args))!;
      final outcome = await f.approve(p);
      expect(outcome.state, AiJournalState.succeeded);
      expect(
        outcome.webLink.toString(),
        'https://example.com/gitlab/team/example-9/-/${entry.value}',
      );
      expect(outcome.webLink!.fragment, isEmpty);
    });
  }

  test(
    'mark-all todos has no project link even with a project grant',
    () async {
      f.scope = AiWriteScope(
        accountKey: coordAccount,
        grants: [
          ...coordScope.grants,
          const AiScopeGrant(kind: AiScopeKind.accountGlobal),
        ],
      );
      final p = (await f.propose('markAllTodosDone', {}))!;
      expect((await f.approve(p)).webLink, isNull);
    },
  );

  test(
    'schedule fallback follows Link continuation and never infers empty',
    () async {
      f.server.scheduleDetailStatus = 403;
      f.server.listHeaders = {
        'link': [
          '<https://example.com/gitlab/api/v4/projects/9/pipeline_schedules?per_page=100&page=2>; rel="next"',
        ],
      };
      final p = (await f.propose('playPipelineSchedule', {
        'projectId': 9,
        'scheduleId': 4,
      }))!;
      expect(p.tier.tier, AiWriteTier.hardLine);
      final preview = p.preview as port.AiPipelinePreview;
      expect(preview.ref, 'work');
      expect(preview.scheduleParamsUnreadable, isTrue);
      expect(preview.scheduleVariableNames, isEmpty);
      expect(f.server.listRequests, hasLength(2));
      expect(f.server.listRequests.last.uri.queryParameters, {
        'per_page': '100',
        'page': '2',
      });
      expect(f.h.mutations, 0);
    },
  );

  for (final row in [
    {'id': 4},
    {'id': 4, 'ref': 7},
    {'id': 4, 'ref': ''},
    {'id': 4, 'ref': '   '},
  ]) {
    test(
      'schedule fallback unreadable ref maps to scheduleParamsUnreadable $row',
      () async {
        f.server.scheduleDetailStatus = 403;
        f.server.listBody = [row];
        expect(
          await f.propose('playPipelineSchedule', {
            'projectId': 9,
            'scheduleId': 4,
          }),
          isNull,
        );
        expect(f.outcome.reasonCode, 'scheduleParamsUnreadable');
        expect(f.h.mutations, 0);
      },
    );
  }

  for (final headers in [
    {
      'link': [
        '<https://other.example/api/v4/projects/9/pipeline_schedules?per_page=100&page=2>; rel="next"',
      ],
    },
    {
      'x-next-page': ['1'],
    },
  ]) {
    test(
      'schedule unreadable continuation maps to scheduleParamsUnreadable $headers',
      () async {
        f.server.scheduleDetailStatus = 403;
        f.server.listHeaders = headers;
        expect(
          await f.propose('playPipelineSchedule', {
            'projectId': 9,
            'scheduleId': 4,
          }),
          isNull,
        );
        expect(f.outcome.reasonCode, 'scheduleParamsUnreadable');
        expect(f.h.mutations, 0);
      },
    );
  }
}
