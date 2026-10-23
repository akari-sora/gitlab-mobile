import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_work_item_write_registry.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart' as coord;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as write_text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';

import '../support/fake_adapter.dart';
import '../support/work_item_health_fixture.dart';
import 'mr6b3_support.dart';

const _account = 'https://example.com/gitlab#7';
const _projectPath = 'studio/mobile-workspace';
const _operation = 'updateWorkItemHealthStatus';
const _gid = 'gid://gitlab/WorkItem/31';

const _scope = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.workItem,
      projectId: 42,
      projectPath: _projectPath,
      iid: 31,
    ),
  ],
);

AiWriteRequest _request(
  String healthStatus, {
  AiWriteScope scope = _scope,
  String executionId = 'health-execution',
  Map<String, Object?> extra = const {},
}) => AiWriteRequest(
  operationId: _operation,
  executionId: executionId,
  scope: scope,
  arguments: {
    'projectId': 42,
    'iid': 31,
    'healthStatus': healthStatus,
    ...extra,
  },
);

final class _Lease implements AiWorkItemWriteLease {
  const _Lease(this.gid, this.kind);

  @override
  final String gid;
  @override
  final AiWorkItemWriteKind kind;
}

final class _Registry implements AiWorkItemWriteRegistry {
  bool active = false;
  bool refuse = false;
  int starts = 0;
  int settles = 0;
  AiWorkItemWriteResult? settledResult;
  DateTime? settledRevision;

  @override
  bool isActive(String gid) => active;

  @override
  AiWorkItemWriteLease? tryStart(String gid, AiWorkItemWriteKind kind) {
    starts++;
    if (refuse || active) return null;
    active = true;
    return _Lease(gid, kind);
  }

  @override
  void settle(
    AiWorkItemWriteLease lease,
    AiWorkItemWriteResult result,
    DateTime? revision,
  ) {
    settles++;
    active = false;
    settledResult = result;
    settledRevision = revision;
  }
}

final class _HealthServer {
  _HealthServer({
    this.value = WorkItemHealthEditValue.needsAttention,
    this.oauthReplayReads = false,
  }) {
    adapter = FakeAdapter(_respond);
    if (oauthReplayReads) {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      tokenAdapter = FakeAdapter((_) {
        tokenRefreshes++;
        return jsonResponse({
          'access_token': 'health-access-$tokenRefreshes',
          'refresh_token': 'health-refresh-$tokenRefreshes',
          'token_type': 'bearer',
        });
      });
      api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'health-access-0',
          refreshToken: 'health-refresh-0',
          clientId: 'health-client',
        ),
        dio: Dio()..httpClientAdapter = adapter,
        oauth: OAuthTokenClient(
          instance: instance,
          clientId: 'health-client',
          dio: Dio()..httpClientAdapter = tokenAdapter!,
        ),
      );
    } else {
      api = testApi(adapter);
    }
  }

  late final FakeAdapter adapter;
  FakeAdapter? tokenAdapter;
  late final GitLabApi api;
  final bool oauthReplayReads;
  WorkItemHealthEditValue? value;
  DateTime revision = healthRevision;
  bool canRead = true;
  bool canWrite = true;
  bool widgetPresent = true;
  bool mutationErrors = false;
  bool mutation401 = false;
  bool mutationNotApplied = false;
  bool mismatchReadback = false;
  bool driftBeforePreflight = false;
  bool actorMismatch = false;
  int? failHealthReadStatus;
  bool malformedHealthRead = false;
  int rollupCount = 99;
  int detailReads = 0;
  int healthReads = 0;
  int mutations = 0;
  int tokenRefreshes = 0;
  int _oauthReadSends = 0;
  final List<Map<String, Object?>> inputs = [];

  Future<ResponseBody> _respond(RequestOptions request) async {
    final requestData = request.data;
    final requestQuery = requestData is Map ? requestData['query'] : null;
    final isMutation =
        requestQuery is String &&
        requestQuery.startsWith('mutation MobileSetWorkItemHealthStatus');
    if (oauthReplayReads && !isMutation) {
      _oauthReadSends++;
      if (_oauthReadSends.isOdd) {
        return jsonResponse({'message': 'expired'}, status: 401);
      }
    }
    if (request.method == 'GET' && request.uri.path.endsWith('/api/v4/user')) {
      return jsonResponse({
        'id': 7,
        'username': 'health-owner',
        'name': 'Health Owner',
      });
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/api/v4/projects/42')) {
      return jsonResponse({
        'id': 42,
        'name': 'mobile-workspace',
        'path_with_namespace': _projectPath,
        'visibility': 'private',
        'default_branch': 'main',
        'archived': false,
      });
    }
    final data = requestData;
    final query = data is Map ? data['query'] : null;
    if (request.method != 'POST' || query is! String) {
      return jsonResponse({'message': 'unexpected request'}, status: 404);
    }
    if (query.startsWith('query MobileProjectWorkItem(')) {
      detailReads++;
      return jsonResponse({
        'data': {
          'project': {
            'id': 'gid://gitlab/Project/42',
            'fullPath': _projectPath,
            'workItems': {
              'nodes': [_detailNode()],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
            },
          },
        },
      });
    }
    if (query.startsWith('query MobileWorkItemHealthEdit')) {
      healthReads++;
      final failureStatus = failHealthReadStatus;
      if (healthReads == 2 && failureStatus != null) {
        return jsonResponse({
          'message': 'synthetic preflight failure',
        }, status: failureStatus);
      }
      if (healthReads == 2 && malformedHealthRead) {
        return jsonResponse({'data': const <String, Object?>{}});
      }
      if (driftBeforePreflight && healthReads == 2) {
        revision = revision.add(const Duration(seconds: 1));
      }
      final actor = actorMismatch && healthReads > 1 ? 8 : 7;
      final node = _healthNode(
        value: mismatchReadback && healthReads >= 3
            ? WorkItemHealthEditValue.needsAttention
            : value,
        includePermissions: true,
      );
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/$actor'},
          'workItem': node,
        },
      });
    }
    if (query.startsWith('mutation MobileSetWorkItemHealthStatus')) {
      mutations++;
      final variables = (data as Map)['variables'] as Map;
      final input = Map<String, Object?>.from(variables['input'] as Map);
      inputs.add(jsonDecode(jsonEncode(input)) as Map<String, Object?>);
      if (mutation401) {
        return jsonResponse({'message': '401 Unauthorized'}, status: 401);
      }
      final widget = input['healthStatusWidget'] as Map;
      final desired = WorkItemHealthEditValue.parse(widget['healthStatus']);
      if (!mutationErrors && !mutationNotApplied) {
        value = desired;
        revision = revision.add(const Duration(seconds: 1));
      }
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': mutationErrors ? ['synthetic rejection'] : <String>[],
            'workItem': _healthNode(value: value, includePermissions: false),
          },
        },
      });
    }
    return jsonResponse({
      'message': 'unexpected GraphQL document',
    }, status: 404);
  }

  Map<String, Object?> _detailNode() => {
    ..._identity(),
    'description': null,
    'widgets': widgetPresent
        ? [
            {'type': 'HEALTH_STATUS'},
          ]
        : <Object?>[],
  };

  Map<String, Object?> _healthNode({
    required WorkItemHealthEditValue? value,
    required bool includePermissions,
  }) => {
    ..._identity(),
    if (includePermissions)
      'userPermissions': {'readWorkItem': canRead, 'adminWorkItem': canWrite},
    'widgets': widgetPresent
        ? [
            {
              'type': 'HEALTH_STATUS',
              'healthStatus': value?.graphValue,
              'rolledUpHealthStatus': [
                {'healthStatus': 'atRisk', 'count': rollupCount},
              ],
            },
          ]
        : <Object?>[],
  };

  Map<String, Object?> _identity() => {
    'id': _gid,
    'iid': '31',
    'title': 'Synthetic health item',
    'state': 'OPEN',
    'createdAt': healthCreatedAt.toIso8601String(),
    'updatedAt': revision.toIso8601String(),
    'project': {'id': 'gid://gitlab/Project/42', 'fullPath': _projectPath},
    'namespace': {
      'id': 'gid://gitlab/Namespaces::ProjectNamespace/42',
      'fullPath': _projectPath,
    },
    'workItemType': {
      'id': 'gid://gitlab/WorkItems::Type/9',
      'name': 'Objective',
    },
  };

  void close() => api.close();
}

GitLabAiWritePort _port(_HealthServer server, _Registry registry) =>
    GitLabAiWritePort(
      server.api,
      accountKey: _account,
      workItemWriteRegistry: registry,
    );

Future<AiWriteOutcome> _commit(
  GitLabAiWritePort port,
  AiWritePrepared prepared, {
  bool Function()? mayStart,
  Future<void> Function()? beforeMutation,
}) async {
  prepared.bindGraphBeforeMutation(beforeMutation ?? () async {});
  return port.commit(prepared, mayStart: mayStart ?? () => true);
}

Matcher _notSent(String reason) => isA<AiWriteNotSent>().having(
  (value) => value.reasonCode,
  'reasonCode',
  reason,
);

Matcher _uncertain() => isA<AiWriteSettled>()
    .having((value) => value.state, 'state', AiJournalState.writeUncertain)
    .having((value) => value.mutationCount, 'mutationCount', 1);

final class _P5CoordinatorLedger implements AiCapabilityLedger {
  const _P5CoordinatorLedger();

  static const row = AiCapability(
    operationId: _operation,
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    httpCap: 21,
    readback: true,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'iid': AiArgSpec(AiArgType.integer, required: true),
      'healthStatus': AiArgSpec(
        AiArgType.string,
        required: true,
        enumValues: ['onTrack', 'needsAttention', 'atRisk', 'none'],
      ),
    },
  );

  @override
  AiCapability? find(String operationId) =>
      operationId == _operation ? row : null;

  @override
  List<AiCapability> get modelVisible => const [row];
}

final class _P5CoordinatorHarness {
  _P5CoordinatorHarness._({
    required this.root,
    required this.files,
    required this.journal,
    required this.port,
  });

  static Future<_P5CoordinatorHarness> create({int maxHttp = 40}) async {
    final root = Directory.systemTemp.createTempSync('mr6b3-health-');
    final files = Mr6b3JournalFiles(root);
    final keys = Mr6b3JournalKeyStore();
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'mr6b3-health',
    );
    await journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await journal.ensureInitialized(mr6b3Account);
    final harness = _P5CoordinatorHarness._(
      root: root,
      files: files,
      journal: journal,
      port: Mr6b3GraphPort(),
    );
    harness.budget = AiToolBudget(maxGitLabRequests: maxHttp);
    harness.coordinator = coord.PolicyAiWriteCoordinator(
      snapshot: () => coord.AiWritePolicySnapshot(
        scope: mr6b3Scope,
        level: harness.policy.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p5-consent',
        writePolicyRevision: harness.policy.revision,
        scopeRevision: 1,
        sessionGeneration: 7,
        alive: harness.policy.alive,
        consentValid: harness.policy.consentValid,
        clientMayStart: harness.policy.clientMayStart,
      ),
      createPort: () => harness.port,
      journal: journal,
      conversationId: mr6b3Conversation,
      budget: () => harness.budget,
      readFreshness: (_) async => const coord.AiWriteFreshness(
        updatedAt: '2026-10-23T00:00:00Z',
        visibilityUnreadable: false,
      ),
      placeholders: write_text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const _P5CoordinatorLedger(),
      checkFragments:
          (
            scan, {
            required knownSecrets,
            required instance,
            required visibility,
          }) {
            final result = exact.checkFragments(
              scan,
              knownSecrets: knownSecrets,
              instance: instance,
              visibility: visibility,
            );
            return (
              blockCode: result.blockCode,
              confirmReasons: result.confirmReasons,
            );
          },
      now: () => DateTime.utc(2026, 10, 23, 12),
    );
    harness.coordinator.beginRun('Set health on issue #3.');
    harness.coordinator.beginTurn();
    return harness;
  }

  final Directory root;
  final Mr6b3JournalFiles files;
  final AiWriteJournal journal;
  final Mr6b3GraphPort port;
  final Mr6b3Policy policy = Mr6b3Policy();
  late AiToolBudget budget;
  late coord.PolicyAiWriteCoordinator coordinator;
  int calls = 0;

  Future<coord.AiWriteProposal?> propose([String healthStatus = 'atRisk']) =>
      coordinator.propose(
        AiToolCall(
          id: 'p5-health-${calls++}',
          name: _operation,
          arguments: {
            'projectId': 9,
            'iid': 3,
            'healthStatus': healthStatus,
            'reason': 'synthetic health request',
          },
        ),
      );

  Future<coord.AiWriteOutcome> approve(coord.AiWriteProposal proposal) =>
      coordinator.approve(proposal, typedName: proposal.tier.typedName);

  Future<void> seedConfirmMark() async {
    const execution = 'p5-health-seed-mark';
    await journal.prepare(
      draft: AiJournalDraft(
        executionId: execution,
        accountKey: mr6b3Account,
        conversationId: 'p5-health-seed',
        runId: 'p5-health-seed-run',
        operationId: _operation,
        writeKeys: {mr6b3WriteKey},
        payloadSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        releaseName: '#3',
      ),
    );
    await journal.markDispatching(executionId: execution);
    await journal.finish(
      executionId: execution,
      terminal: AiJournalState.writeUncertain,
    );
    await journal.releaseByUser(executionId: execution, typedName: '#3');
  }

  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _RealP5CoordinatorHarness {
  _RealP5CoordinatorHarness._({
    required this.root,
    required this.journal,
    required this.server,
    required this.port,
  });

  static Future<_RealP5CoordinatorHarness> create({bool oauth = false}) async {
    final root = Directory.systemTemp.createTempSync('mr6b3-real-health-');
    final keys = Mr6b3JournalKeyStore();
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      processId: 'mr6b3-real-health',
    );
    await journal.recoverAfterAccountsLoaded([_account]);
    await journal.ensureInitialized(_account);
    final server = _HealthServer(
      value: WorkItemHealthEditValue.onTrack,
      oauthReplayReads: oauth,
    );
    final port = _port(server, _Registry());
    final harness = _RealP5CoordinatorHarness._(
      root: root,
      journal: journal,
      server: server,
      port: port,
    );
    harness.coordinator = coord.PolicyAiWriteCoordinator(
      snapshot: () => const coord.AiWritePolicySnapshot(
        scope: _scope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p5-real-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 0,
        alive: true,
        consentValid: true,
        clientMayStart: true,
      ),
      createPort: () => port,
      journal: journal,
      conversationId: 'p5-real-conversation',
      budget: () => harness.budget,
      readFreshness: (_) async {
        await server.api.project('42', allowDisk: false);
        return coord.AiWriteFreshness(
          updatedAt: server.revision.toIso8601String(),
          visibilityUnreadable: false,
        );
      },
      placeholders: write_text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const _P5CoordinatorLedger(),
      checkFragments:
          (
            scan, {
            required knownSecrets,
            required instance,
            required visibility,
          }) {
            final result = exact.checkFragments(
              scan,
              knownSecrets: knownSecrets,
              instance: instance,
              visibility: visibility,
            );
            return (
              blockCode: result.blockCode,
              confirmReasons: result.confirmReasons,
            );
          },
      now: () => DateTime.utc(2026, 10, 23, 12),
    );
    harness.coordinator.beginRun('Set issue #31 health to at risk.');
    harness.coordinator.beginTurn();
    return harness;
  }

  final Directory root;
  final AiWriteJournal journal;
  final _HealthServer server;
  final GitLabAiWritePort port;
  final AiToolBudget budget = AiToolBudget(maxGitLabRequests: 21);
  late coord.PolicyAiWriteCoordinator coordinator;

  Future<coord.AiWriteProposal?> propose() => coordinator.propose(
    AiToolCall(
      id: 'p5-real',
      name: _operation,
      arguments: const {
        'projectId': 42,
        'iid': 31,
        'healthStatus': 'atRisk',
        'reason': 'set own health',
      },
    ),
  );

  Future<void> dispose() async {
    coordinator.stop('disposed');
    server.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  test('P5 ledger row is hidden T2 graph with the fixed cap and enum', () {
    final row = productionAiLedger.find(_operation)!;
    expect(row.baseTier, AiWriteTier.t2);
    expect(row.scopeClass, AiScopeClass.workItem);
    expect(row.boundary, AiWriteBoundary.graph);
    expect(row.httpCap, 21);
    expect(row.readback, isTrue);
    expect(row.modelVisible, isFalse);
    expect(productionAiLedger.modelVisible, isNot(contains(row)));
    expect(row.arguments.keys, {'projectId', 'iid', 'healthStatus'});
    expect(row.arguments['healthStatus']!.enumValues, [
      'onTrack',
      'needsAttention',
      'atRisk',
      'none',
    ]);
  });

  for (final testCase in <(String, WorkItemHealthEditValue?, Object?)>[
    ('onTrack', WorkItemHealthEditValue.onTrack, 'onTrack'),
    (
      'needsAttention',
      WorkItemHealthEditValue.needsAttention,
      'needsAttention',
    ),
    ('atRisk', WorkItemHealthEditValue.atRisk, 'atRisk'),
    ('none', null, null),
  ]) {
    test('P5 sends exact own-health payload for ${testCase.$1}', () async {
      final server = _HealthServer(
        value: testCase.$2 == WorkItemHealthEditValue.onTrack
            ? WorkItemHealthEditValue.atRisk
            : WorkItemHealthEditValue.onTrack,
      );
      addTearDown(server.close);
      final registry = _Registry();
      final port = _port(server, registry);
      final prepared = await port.prepare(_request(testCase.$1));

      expect(prepared.releaseName, '#31');
      expect(prepared.writeKeys.single.parts, [
        _account,
        'project:42',
        'workItem',
        '31',
      ]);
      expect(prepared.bindingTargets.single.kind, AiTargetKind.issue);
      expect(
        prepared.bindingTargets.single.origin,
        AiTargetOrigin.currentResource,
      );
      expect((prepared.preview as AiFieldsPreview).fields, {
        'healthStatus': testCase.$3,
      });
      expect(prepared.bindingDigest, isNotEmpty);

      final outcome = await _commit(port, prepared);
      expect(
        outcome,
        isA<AiWriteSettled>()
            .having((value) => value.state, 'state', AiJournalState.succeeded)
            .having((value) => value.readbackVerified, 'readback', isTrue),
      );
      expect(server.mutations, 1);
      expect(server.inputs.single, {
        'id': _gid,
        'healthStatusWidget': {'healthStatus': testCase.$3},
      });
      expect(registry.settledResult, AiWorkItemWriteResult.confirmed);
      expect(registry.settledRevision, server.revision);
    });
  }

  test('P5 legal noop skips B and settles the lease as notSent', () async {
    final server = _HealthServer(value: WorkItemHealthEditValue.onTrack);
    addTearDown(server.close);
    final registry = _Registry();
    final port = _port(server, registry);
    final prepared = await port.prepare(_request('onTrack'));
    var boundaryCalls = 0;

    final outcome = await _commit(
      port,
      prepared,
      beforeMutation: () async => boundaryCalls++,
    );

    expect(outcome, isA<AiGraphNoChange>());
    expect(boundaryCalls, 0);
    expect(server.mutations, 0);
    expect(registry.starts, 1);
    expect(registry.settledResult, AiWorkItemWriteResult.notSent);
  });

  test(
    'P5 registry refusal is notExecuted before B and API preflight',
    () async {
      final server = _HealthServer();
      addTearDown(server.close);
      final registry = _Registry()..refuse = true;
      final port = _port(server, registry);
      final prepared = await port.prepare(_request('atRisk'));
      var boundaryCalls = 0;

      final outcome = await _commit(
        port,
        prepared,
        beforeMutation: () async => boundaryCalls++,
      );

      expect(outcome, _notSent('healthConflict'));
      expect(boundaryCalls, 0);
      expect(server.healthReads, 1);
      expect(server.mutations, 0);
      expect(registry.settles, 0);
    },
  );

  test(
    'P5 mayStart false never sends and releases its registry lease',
    () async {
      final server = _HealthServer();
      addTearDown(server.close);
      final registry = _Registry();
      final port = _port(server, registry);
      final prepared = await port.prepare(_request('atRisk'));
      var boundaryCalls = 0;

      final outcome = await _commit(
        port,
        prepared,
        beforeMutation: () async => boundaryCalls++,
        mayStart: () => false,
      );

      expect(outcome, _notSent('cancelled'));
      expect(boundaryCalls, 1);
      expect(server.mutations, 0);
      expect(registry.settledResult, AiWorkItemWriteResult.notSent);
      expect(registry.active, isFalse);
    },
  );

  test('P5 callback throwing after B remains before acceptance', () async {
    final server = _HealthServer();
    addTearDown(server.close);
    final access = await server.api.workItemHealthEdit(
      healthDetail(),
      expectedUserId: 7,
      generation: 0,
      isCurrent: () => true,
    );
    final prepared = AiWritePrepared.graph(
      request: _request('atRisk'),
      releaseName: '#31',
      writeKeys: {
        const AiConflictKey([_account, 'project:42', 'workItem', '31']),
      },
      mutation: (hooks) async {
        await server.api.updateWorkItemHealthStatus(
          access.target!,
          desired: WorkItemHealthEditValue.atRisk,
          generation: 0,
          isCurrent: () => true,
          beforeMutation: hooks.beforeMutation,
          mayStart: hooks.mayStart,
          onMutationSent: () => throw StateError('synthetic callback failure'),
        );
        return null;
      },
    );
    var boundaryCalls = 0;
    prepared.bindGraphBeforeMutation(() async => boundaryCalls++);

    final outcome = await prepared.commitGraph(mayStart: () => true);

    expect(outcome, _notSent('graphContractViolation'));
    expect(boundaryCalls, 1);
    expect(server.mutations, 0);
  });

  test('P5 accepted typed failure remains uncertain', () async {
    final prepared = AiWritePrepared.graph(
      request: _request('atRisk'),
      releaseName: '#31',
      writeKeys: {
        const AiConflictKey([_account, 'project:42', 'workItem', '31']),
      },
      mutation: (hooks) async {
        await hooks.beforeMutation();
        expect(hooks.mayStart(), isTrue);
        throw const WorkItemHealthEditFailure(
          ApiFailure(FailureKind.unsupported),
          false,
        );
      },
    );
    var boundaryCalls = 0;
    prepared.bindGraphBeforeMutation(() async => boundaryCalls++);

    final outcome = await prepared.commitGraph(mayStart: () => true);

    expect(outcome, _uncertain());
    expect(boundaryCalls, 1);
    // The frozen shared graph normalizer deliberately collapses accepted
    // family-specific refusals to this common uncertainty reason code.
    expect((outcome as AiWriteSettled).resultCode, 'writeUncertain');
  });

  for (final mode in ['errors', '401', 'notApplied', 'readbackMismatch']) {
    test('P5 accepted $mode is uncertain after exactly one mutation', () async {
      final server = _HealthServer();
      addTearDown(server.close);
      switch (mode) {
        case 'errors':
          server.mutationErrors = true;
        case '401':
          server.mutation401 = true;
        case 'notApplied':
          server.mutationNotApplied = true;
        case 'readbackMismatch':
          server.mismatchReadback = true;
      }
      final registry = _Registry();
      final port = _port(server, registry);
      final prepared = await port.prepare(_request('atRisk'));

      expect(await _commit(port, prepared), _uncertain());
      expect(server.mutations, 1);
      expect(registry.settledResult, AiWorkItemWriteResult.uncertain);
    });
  }

  for (final testCase in <(String, void Function(_HealthServer), String)>[
    ('5xx', (server) => server.failHealthReadStatus = 503, 'server'),
    (
      'malformed',
      (server) => server.malformedHealthRead = true,
      'invalidResponse',
    ),
  ]) {
    test('P5 ${testCase.$1} preflight fails before B and mutation', () async {
      final server = _HealthServer();
      addTearDown(server.close);
      testCase.$2(server);
      final registry = _Registry();
      final port = _port(server, registry);
      final prepared = await port.prepare(_request('atRisk'));
      var boundaryCalls = 0;

      final outcome = await _commit(
        port,
        prepared,
        beforeMutation: () async => boundaryCalls++,
      );

      expect(outcome, _notSent(testCase.$3));
      expect(boundaryCalls, 0);
      expect(server.mutations, 0);
      expect(registry.settledResult, AiWorkItemWriteResult.notSent);
    });
  }

  test(
    'P5 maps unsupported, forbidden, conflict, and actor drift before B',
    () async {
      Future<void> verifyPrepare(
        void Function(_HealthServer server) arrange,
        String reason,
      ) async {
        final server = _HealthServer();
        addTearDown(server.close);
        arrange(server);
        await expectLater(
          _port(server, _Registry()).prepare(_request('atRisk')),
          throwsA(
            isA<AiWriteRefused>().having(
              (error) => error.reason,
              'reason',
              reason,
            ),
          ),
        );
        expect(server.mutations, 0);
      }

      Future<void> verify(
        void Function(_HealthServer server) arrange,
        String reason,
      ) async {
        final server = _HealthServer();
        addTearDown(server.close);
        arrange(server);
        final registry = _Registry();
        final port = _port(server, registry);
        final prepared = await port.prepare(_request('atRisk'));
        var boundaryCalls = 0;
        final outcome = await _commit(
          port,
          prepared,
          beforeMutation: () async => boundaryCalls++,
        );
        expect(outcome, _notSent(reason));
        expect(boundaryCalls, 0);
        expect(server.mutations, 0);
        expect(registry.settledResult, AiWorkItemWriteResult.notSent);
      }

      await verifyPrepare(
        (server) => server.widgetPresent = false,
        'healthUnsupported',
      );
      await verifyPrepare(
        (server) => server.canWrite = false,
        'healthForbidden',
      );
      await verify(
        (server) => server.driftBeforePreflight = true,
        'healthConflict',
      );
      await verify((server) => server.actorMismatch = true, 'cancelled');
    },
  );

  test(
    'P5 rejects unknown, malformed, foreign, stale, and missing registry',
    () async {
      final cases = <Future<void> Function()>[
        () async {
          final server = _HealthServer();
          addTearDown(server.close);
          await expectLater(
            _port(server, _Registry()).prepare(
              _request('atRisk', extra: {'rolledUpHealthStatus': 'atRisk'}),
            ),
            throwsA(
              isA<ApiFailure>().having(
                (error) => error.kind,
                'kind',
                FailureKind.validation,
              ),
            ),
          );
        },
        () async {
          final server = _HealthServer();
          addTearDown(server.close);
          await expectLater(
            _port(server, _Registry()).prepare(_request('critical')),
            throwsA(isA<ApiFailure>()),
          );
        },
        () async {
          final server = _HealthServer();
          addTearDown(server.close);
          const foreign = AiWriteScope(
            accountKey: _account,
            grants: [
              AiScopeGrant(
                kind: AiScopeKind.workItem,
                projectId: 99,
                projectPath: 'foreign/project',
                iid: 31,
              ),
            ],
          );
          await expectLater(
            _port(
              server,
              _Registry(),
            ).prepare(_request('atRisk', scope: foreign)),
            throwsA(isA<AiWriteRefused>()),
          );
        },
        () async {
          final server = _HealthServer();
          addTearDown(server.close);
          await expectLater(
            GitLabAiWritePort(
              server.api,
              accountKey: _account,
            ).prepare(_request('atRisk')),
            throwsA(
              isA<AiWriteRefused>().having(
                (error) => error.reason,
                'reason',
                'registryUnavailable',
              ),
            ),
          );
        },
      ];
      for (final run in cases) {
        await run();
      }
    },
  );

  test(
    'P5 broader project grant remains proposed binding provenance',
    () async {
      final server = _HealthServer();
      addTearDown(server.close);
      const projectScope = AiWriteScope(
        accountKey: _account,
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: 42,
            projectPath: _projectPath,
          ),
        ],
      );
      final prepared = await _port(
        server,
        _Registry(),
      ).prepare(_request('atRisk', scope: projectScope));
      expect(prepared.bindingTargets.single.origin, AiTargetOrigin.proposed);
    },
  );

  test(
    'P5 digest tracks own revision/value/desired but ignores roll-up',
    () async {
      Future<String> digest(_HealthServer server, String desired) async {
        final prepared = await _port(
          server,
          _Registry(),
        ).prepare(_request(desired));
        return prepared.bindingDigest;
      }

      final base = _HealthServer();
      final rollup = _HealthServer()..rollupCount = 1;
      final revision = _HealthServer()
        ..revision = healthRevision.add(const Duration(seconds: 1));
      final value = _HealthServer(value: WorkItemHealthEditValue.atRisk);
      final desired = _HealthServer();
      addTearDown(base.close);
      addTearDown(rollup.close);
      addTearDown(revision.close);
      addTearDown(value.close);
      addTearDown(desired.close);

      expect(await digest(base, 'atRisk'), await digest(rollup, 'atRisk'));
      expect(
        await digest(base, 'atRisk'),
        isNot(await digest(revision, 'atRisk')),
      );
      expect(
        await digest(base, 'atRisk'),
        isNot(await digest(value, 'atRisk')),
      );
      expect(
        await digest(base, 'atRisk'),
        isNot(await digest(desired, 'onTrack')),
      );
    },
  );

  test('P5 registry lease excludes peers on one API and isolates APIs', () {
    final first = _HealthServer();
    final second = _HealthServer();
    addTearDown(first.close);
    addTearDown(second.close);
    final a = createAiWorkspaceWorkItemWriteRegistry(
      api: first.api,
      accountKey: _account,
      instanceKey: first.api.instance.key,
      generation: 0,
      isCurrent: () => true,
    );
    final peer = createAiWorkspaceWorkItemWriteRegistry(
      api: first.api,
      accountKey: _account,
      instanceKey: first.api.instance.key,
      generation: 0,
      isCurrent: () => true,
    );
    final isolated = createAiWorkspaceWorkItemWriteRegistry(
      api: second.api,
      accountKey: _account,
      instanceKey: second.api.instance.key,
      generation: 0,
      isCurrent: () => true,
    );

    final held = a.tryStart(_gid, AiWorkItemWriteKind.health);
    expect(held, isNotNull);
    expect(peer.tryStart(_gid, AiWorkItemWriteKind.health), isNull);
    final separate = isolated.tryStart(_gid, AiWorkItemWriteKind.health);
    expect(separate, isNotNull);
    a.settle(held!, AiWorkItemWriteResult.notSent, null);
    isolated.settle(separate!, AiWorkItemWriteResult.notSent, null);
  });

  test('P5 coordinator reserves cap 21 before any port pre-read', () async {
    final refused = await _P5CoordinatorHarness.create(maxHttp: 20);
    addTearDown(refused.dispose);
    expect(await refused.propose(), isNull);
    expect(refused.port.prepareCount, 0);
    expect(
      refused.coordinator.outcomeFor('p5-health-0')?.reasonCode,
      'httpBudgetExceeded',
    );

    for (final cap in [21, 39, 40, 41]) {
      final allowed = await _P5CoordinatorHarness.create(maxHttp: cap);
      addTearDown(allowed.dispose);
      expect(await allowed.propose(), isNotNull, reason: 'cap $cap');
      expect(allowed.port.prepareCount, 1, reason: 'cap $cap');
      expect(await allowed.propose(), isNull, reason: 'second at cap $cap');
      expect(
        allowed.coordinator.outcomeFor('p5-health-1')?.reasonCode,
        'httpBudgetExceeded',
      );
    }
  });

  test('P5 real coordinator PAT path uses 11 calls and one mutation', () async {
    final harness = await _RealP5CoordinatorHarness.create();
    addTearDown(harness.dispose);
    final proposal = (await harness.propose())!;

    final outcome = await harness.coordinator.approve(
      proposal,
      typedName: proposal.tier.typedName,
    );

    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.mutationCount, 1);
    expect(outcome.readbackConfirmed, isTrue);
    expect(harness.server.adapter.requests, hasLength(11));
    expect(harness.server.detailReads, 2);
    expect(harness.server.healthReads, 4);
    expect(harness.server.mutations, 1);
    expect(
      harness.journal.entries(_account).last.state,
      AiJournalState.succeeded,
    );
  });

  test(
    'P5 real coordinator OAuth path charges 21 API sends without mutation replay',
    () async {
      final harness = await _RealP5CoordinatorHarness.create(oauth: true);
      addTearDown(harness.dispose);
      final proposal = (await harness.propose())!;

      final outcome = await harness.coordinator.approve(
        proposal,
        typedName: proposal.tier.typedName,
      );

      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.mutationCount, 1);
      expect(outcome.readbackConfirmed, isTrue);
      expect(harness.server.adapter.requests, hasLength(21));
      expect(harness.server.tokenAdapter!.requests, hasLength(10));
      expect(harness.server.tokenRefreshes, 10);
      expect(harness.server.detailReads, 2);
      expect(harness.server.healthReads, 4);
      expect(harness.server.mutations, 1);
    },
  );

  test(
    'P5 OAuth mutation 401 refreshes but never replays the mutation',
    () async {
      final harness = await _RealP5CoordinatorHarness.create(oauth: true);
      addTearDown(harness.dispose);
      harness.server.mutation401 = true;
      final proposal = (await harness.propose())!;

      final outcome = await harness.coordinator.approve(
        proposal,
        typedName: proposal.tier.typedName,
      );

      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.mutationCount, 1);
      expect(outcome.readbackConfirmed, isFalse);
      expect(harness.server.adapter.requests, hasLength(19));
      expect(harness.server.tokenAdapter!.requests, hasLength(10));
      expect(harness.server.tokenRefreshes, 10);
      expect(harness.server.mutations, 1);
      expect(
        harness.server.adapter.requests.where((request) {
          final data = request.data;
          final query = data is Map ? data['query'] : null;
          return query is String &&
              query.startsWith('mutation MobileSetWorkItemHealthStatus');
        }),
        hasLength(1),
      );
    },
  );

  test('P5 coordinator reverts callback-shaped post-B failure', () async {
    final harness = await _P5CoordinatorHarness.create();
    addTearDown(harness.dispose);
    await harness.seedConfirmMark();
    expect(
      harness.journal.requiresConfirmation(mr6b3Account, {mr6b3WriteKey}),
      isTrue,
    );
    harness.port.mode = Mr6b3MutationMode.hookReturnedError;
    harness.port.beforeBoundary = () {
      expect(
        harness.journal.requiresConfirmation(mr6b3Account, {mr6b3WriteKey}),
        isTrue,
      );
    };

    final outcome = await harness.approve((await harness.propose())!);

    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.mutationCount, 0);
    expect(harness.port.sends, 0);
    expect(
      harness.journal.entries(mr6b3Account).last.state,
      AiJournalState.notExecuted,
    );
    expect(
      harness.journal.conversationWriteCount(mr6b3Account, mr6b3Conversation),
      0,
    );
    expect(
      harness.journal.requiresConfirmation(mr6b3Account, {mr6b3WriteKey}),
      isTrue,
    );
  });

  for (final testCase in <(String, void Function(_P5CoordinatorHarness))>[
    ('policy revision', (harness) => harness.policy.revision++),
    ('session death', (harness) => harness.policy.alive = false),
    ('consent revoke', (harness) => harness.policy.consentValid = false),
    ('client fence', (harness) => harness.policy.clientMayStart = false),
    ('coordinator stop', (harness) => harness.coordinator.stop('revoked')),
  ]) {
    test('P5 flush barrier blocks ${testCase.$1} before acceptance', () async {
      final harness = await _P5CoordinatorHarness.create();
      addTearDown(harness.dispose);
      await harness.seedConfirmMark();
      final proposal = (await harness.propose())!;
      final entered = harness.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = harness.approve(proposal);
      await entered;
      expect(harness.port.sends, 0);
      testCase.$2(harness);
      harness.files.releaseBarrier();

      final outcome = await pending;

      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.mutationCount, 0);
      expect(harness.port.sends, 0);
      expect(
        harness.journal.entries(mr6b3Account).last.state,
        AiJournalState.notExecuted,
      );
      expect(
        harness.journal.requiresConfirmation(mr6b3Account, {mr6b3WriteKey}),
        isTrue,
      );
    });
  }

  test('P5 coordinator duplicate approval dispatches once', () async {
    final harness = await _P5CoordinatorHarness.create();
    addTearDown(harness.dispose);
    final proposal = (await harness.propose())!;
    final entered = harness.files.armBarrier(
      writesBeforeBarrier: 1,
      afterPersist: true,
    );
    final first = harness.approve(proposal);
    final second = harness.approve(proposal);
    await entered;
    harness.files.releaseBarrier();
    final outcomes = await Future.wait([first, second]);

    expect(harness.port.sends, 1);
    expect(
      outcomes.where((outcome) => outcome.state == AiJournalState.succeeded),
      hasLength(2),
    );
  });

  test('P5 coordinator noop continues while uncertain fail-stops', () async {
    final harness = await _P5CoordinatorHarness.create(maxHttp: 42);
    addTearDown(harness.dispose);
    harness.port.mode = Mr6b3MutationMode.noop;
    final noop = await harness.approve((await harness.propose())!);
    expect(noop.noChange, isTrue);
    harness.port.mode = Mr6b3MutationMode.accepted;
    expect(await harness.propose('onTrack'), isNotNull);

    final failed = await _P5CoordinatorHarness.create();
    addTearDown(failed.dispose);
    failed.port.acceptedError = api401();
    final uncertain = await failed.approve((await failed.propose())!);
    expect(uncertain.state, AiJournalState.writeUncertain);
    expect(await failed.propose(), isNull);
    expect(
      failed.coordinator.outcomeFor('p5-health-1')?.reasonCode,
      'previousWriteIncomplete',
    );
  });

  test(
    'P5 source guard keeps A outside send try and exact own-only payload',
    () {
      final source = File(
        'lib/core/work_item_health_api.dart',
      ).readAsStringSync();
      final method = source.substring(
        source.indexOf(
          'Future<WorkItemHealthEditSaveResult> updateWorkItemHealthStatus',
        ),
        source.indexOf('Future<WorkItemHealthEditAccess> _readWorkItemHealth'),
      );
      final before = method.indexOf(
        'if (beforeMutation != null) await beforeMutation();',
      );
      final callback = method.indexOf('onMutationSent?.call();');
      final mayStart = method.indexOf('if (mayStart != null && !mayStart())');
      final send = method.indexOf("final response = await _send(");
      final sendTry = method.lastIndexOf('try {', send);
      expect(before, greaterThan(0));
      expect(callback, greaterThan(before));
      expect(mayStart, greaterThan(callback));
      expect(send, greaterThan(mayStart));
      expect(sendTry, greaterThan(mayStart));
      expect(method, contains("'healthStatusWidget': <String, Object?>{"));
      expect(method, contains("'healthStatus': desired?.graphValue"));
      expect(method, isNot(contains("'rolledUpHealthStatus':")));
    },
  );
}
