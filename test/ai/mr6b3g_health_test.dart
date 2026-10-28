import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_work_item_write_registry.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart' as coord;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart'
    show
        createAiWorkspaceWorkItemWriteRegistry,
        aiWorkspaceWriteFreshnessForTesting;
import 'package:gitlab_mobile/features/workspace/work_item_status.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import '../support/work_item_health_fixture.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart';

// Fixed independently of production rows and the shared inventory map.
const groupHealthStageOperations = <String>{'updateGroupWorkItemHealthStatus'};
const _operation = 'updateGroupWorkItemHealthStatus';
const _account = g0eAccount;
const _gid = 'gid://gitlab/WorkItem/91';
const _key = AiConflictKey([_account, 'group:7', 'workItem', '5']);

AiWriteRequest _request({
  String health = 'atRisk',
  AiWriteScope scope = g0eScope,
  String execution = 'group-health',
  Map<String, Object?> extra = const {},
}) => AiWriteRequest(
  operationId: _operation,
  executionId: execution,
  scope: scope,
  arguments: {'groupId': 7, 'iid': 5, 'healthStatus': health, ...extra},
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
    expect(gid, _gid);
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
    bool oauth = false,
    this.replayReadNumbers = const {},
  }) {
    adapter = FakeAdapter(_respond);
    if (oauth || oauthReplayReads) {
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
  final Set<int> replayReadNumbers;
  bool current = true;
  int generation = 7;
  WorkItemHealthEditValue? value;
  DateTime revision = healthRevision;
  bool canRead = true;
  bool canWrite = true;
  bool widgetPresent = true;
  bool healthFieldPresent = true;
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
  int _logicalReads = 0;
  bool _replayPending = false;
  final List<Map<String, Object?>> inputs = [];

  Future<ResponseBody> _respond(RequestOptions request) async {
    final requestData = request.data;
    final requestQuery = requestData is Map ? requestData['query'] : null;
    final isMutation =
        requestQuery is String &&
        requestQuery.startsWith('mutation MobileSetWorkItemHealthStatus');
    if (!isMutation) {
      if (_replayPending) {
        _replayPending = false;
      } else {
        _logicalReads++;
        if (oauthReplayReads || replayReadNumbers.contains(_logicalReads)) {
          _replayPending = true;
          return jsonResponse({'message': 'expired'}, status: 401);
        }
      }
    }
    if (request.method == 'GET' && request.uri.path.endsWith('/api/v4/user')) {
      afterRead?.call('actor');
      return jsonResponse({
        'id': 7,
        'username': 'health-owner',
        'name': 'Health Owner',
      });
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/api/v4/groups/7')) {
      afterRead?.call('freshness');
      return jsonResponse({
        'id': 7,
        'name': 'Subgroup',
        'full_path': g0ePath,
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
    if (query == namespaceWorkItemQuery) {
      detailReads++;
      expect((data as Map)['variables'], {'path': g0ePath, 'iid': '5'});
      final namespace = <String, Object?>{
        'id': 'gid://gitlab/Group/7',
        'fullPath': g0ePath,
        'workItem': _detailNode(),
      };
      alterNamespace?.call(namespace);
      afterRead?.call('namespace');
      return jsonResponse({
        'data': {'namespace': namespace},
      });
    }
    if (query.startsWith('query MobileWorkItemHealthEdit')) {
      expect((data as Map)['variables'], {'id': _gid});
      healthReads++;
      final failureStatus = failHealthReadStatus;
      if (healthReads == failReadNumber && failureStatus != null) {
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
      alterHealthNode?.call(node, healthReads);
      afterRead?.call('health$healthReads');
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/$actor'},
          'workItem': node,
        },
      });
    }
    if (query.startsWith('mutation MobileSetWorkItemHealthStatus')) {
      expect(
        query,
        contains(
          '      id\n      iid\n      updatedAt\n'
          '      project { id fullPath }\n'
          '      namespace { id fullPath }',
        ),
      );
      mutations++;
      onMutation?.call();
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
      final node = _healthNode(value: value, includePermissions: false);
      alterAcknowledgement?.call(node);
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': mutationErrors ? ['synthetic rejection'] : <String>[],
            'workItem': node,
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
              if (healthFieldPresent) 'healthStatus': value?.graphValue,
              'rolledUpHealthStatus': [
                {'healthStatus': 'atRisk', 'count': rollupCount},
              ],
            },
          ]
        : <Object?>[],
  };

  Map<String, Object?> _identity() => {
    'id': _gid,
    'iid': '5',
    'title': 'Synthetic health item',
    'state': 'OPEN',
    'createdAt': healthCreatedAt.toIso8601String(),
    'updatedAt': revision.toIso8601String(),
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath},
    'workItemType': {
      'id': 'gid://gitlab/WorkItems::Type/9',
      'name': 'Objective',
    },
  };

  int failReadNumber = 2;
  void Function(Map<String, Object?>)? alterNamespace;
  void Function(Map<String, Object?> node, int read)? alterHealthNode;
  void Function(Map<String, Object?>)? alterAcknowledgement;
  void Function(String phase)? afterRead;
  void Function()? onMutation;

  void close() => api.close();
}

GitLabAiWritePort _port(
  _HealthServer server, [
  AiWorkItemWriteRegistry? registry,
]) => GitLabAiWritePort(
  server.api,
  accountKey: _account,
  workItemWriteRegistry: registry,
  sessionGeneration: 7,
  isCurrent: () => server.current && server.generation == 7,
);

AiWorkItemWriteRegistry _workspaceRegistry(_HealthServer server) =>
    createAiWorkspaceWorkItemWriteRegistry(
      api: server.api,
      accountKey: _account,
      instanceKey: server.api.instance.key,
      generation: 7,
      isCurrent: () => true,
    );

// Exercise the production dispatcher and its app-owned context accessor.
Future<AiWritePrepared> _open(
  GitLabAiWritePort port, {
  AiWriteRequest? request,
}) => port.prepare(request ?? _request());

Future<AiWriteOutcome> _commit(
  GitLabAiWritePort port,
  AiWritePrepared prepared, {
  Future<void> Function()? before,
  bool Function()? mayStart,
}) {
  prepared.bindGraphBeforeMutation(before ?? () async {});
  return port.commit(prepared, mayStart: mayStart ?? () => true);
}

Matcher _refused(String reason) =>
    throwsA(isA<AiWriteRefused>().having((e) => e.reason, 'reason', reason));

Matcher _notSent(String reason) =>
    isA<AiWriteNotSent>().having((e) => e.reasonCode, 'reasonCode', reason);

final class _VisibleLedger implements AiCapabilityLedger {
  @override
  AiCapability? find(String operationId) {
    if (operationId != _operation) return null;
    final row = productionAiLedger.find(operationId)!;
    return AiCapability(
      operationId: row.operationId,
      namedMethod: row.namedMethod,
      baseTier: row.baseTier,
      boundary: row.boundary,
      scopeClass: row.scopeClass,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
      modelVisible: true,
    );
  }

  @override
  List<AiCapability> get modelVisible => [find(_operation)!];
}

final class _Harness {
  _Harness(this.base, this.server, this.registry, this.budget);

  static Future<_Harness> create({
    bool oauth = false,
    bool replayAllReads = false,
    Set<int> replayReadNumbers = const {},
    int maxHttp = 40,
  }) async {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
    final base = await Mr6b3Harness.create();
    final server = _HealthServer(
      oauth: oauth,
      oauthReplayReads: replayAllReads,
      replayReadNumbers: replayReadNumbers,
    );
    final registry = _Registry();
    final p = _port(server, registry);
    final h = _Harness(
      base,
      server,
      registry,
      AiToolBudget(maxGitLabRequests: maxHttp),
    );
    h.coordinator = coord.PolicyAiWriteCoordinator(
      snapshot: () => coord.AiWritePolicySnapshot(
        scope: g0eScope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'group-health-test',
        writePolicyRevision: 1,
        sessionGeneration: h.generation,
        ownerApi: server.api,
        appInForeground: true,
        currentResource: AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          side: AiResourceSide.group,
          groupId: 7,
          groupFullPath: g0ePath,
          iid: 5,
        ),
      ),
      createPort: () => p,
      journal: base.journal,
      conversationId: 'group-health-test',
      budget: () => h.budget,
      readFreshness: (_) async {
        await server.api.group(7);
        return const coord.AiWriteFreshness(
          targetVisibility: 'private',
          sourceVisibilityUnreadable: false,
          visibilityUnreadable: true,
        );
      },
      placeholders: text.UploadPlaceholderTable(instance: server.api.instance),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: _VisibleLedger(),
    );
    h.coordinator.beginRun('Update this group work item health.');
    h.coordinator.beginTurn();
    return h;
  }

  final Mr6b3Harness base;
  final _HealthServer server;
  final _Registry registry;
  final AiToolBudget budget;
  late coord.PolicyAiWriteCoordinator coordinator;
  int get generation => server.generation;
  set generation(int value) => server.generation = value;
  int calls = 0;

  Future<coord.AiWriteProposal?> propose({
    String health = 'atRisk',
    Map<String, Object?> extra = const {},
  }) => coordinator.propose(
    AiToolCall(
      id: 'health-${calls++}',
      name: _operation,
      arguments: {
        'groupId': 7,
        'iid': 5,
        'healthStatus': health,
        'reason': 'Requested health update.',
        ...extra,
      },
    ),
  );

  Future<coord.AiWriteOutcome> approve(coord.AiWriteProposal proposal) =>
      coordinator.approve(proposal, typedName: proposal.tier.typedName);

  Future<void> dispose() async {
    base.files.releaseBarrier();
    coordinator.stop();
    server.close();
    await base.dispose();
  }
}

void main() {
  test('G-P5 pins complete alias, visible graph row, allowlist and cap 21', () {
    expect(groupHealthStageOperations, {_operation});
    expect(
      aiGroupHealthRows.map((row) => row.operationId).toSet(),
      groupHealthStageOperations,
    );
    final row = productionAiLedger.find(_operation)!;
    expect(row.namedMethod, 'updateWorkItemHealthStatus');
    expect(row.baseTier, AiWriteTier.t2);
    expect(row.scopeClass, AiScopeClass.groupWorkItem);
    expect(row.boundary, AiWriteBoundary.graph);
    expect(row.httpCap, 21);
    expect(row.readback, isTrue);
    expect(row.arguments.keys, {'groupId', 'iid', 'healthStatus'});
    expect(row.arguments.values.every((arg) => arg.required), isTrue);
    expect(row.arguments['healthStatus']!.enumValues, [
      'onTrack',
      'needsAttention',
      'atRisk',
      'none',
    ]);
    expect(row.modelVisible, isTrue);
    expect(productionAiLedger.modelVisible, contains(row));
    expect(aiGroupWorkItemWritesAreEnabled, isTrue);
    expect(toolsForScope(g0eScope), contains(row));
  });

  test(
    'G-P5 production prepare refuses missing trusted context, mutation0',
    () async {
      final s = _HealthServer();
      addTearDown(s.close);
      await expectLater(
        GitLabAiWritePort(
          s.api,
          accountKey: _account,
          workItemWriteRegistry: _Registry(),
        ).prepare(_request()),
        _refused('workItemUnverifiable'),
      );
      expect(s.adapter.requests, isEmpty);
    },
  );

  test('G-P5 requires the shared registry before any read', () async {
    final s = _HealthServer();
    addTearDown(s.close);
    await expectLater(_open(_port(s)), _refused('registryUnavailable'));
    expect(s.adapter.requests, isEmpty);
  });

  for (final mode in ['revoked', 'generation', 'closed API']) {
    test('G-P5 production context $mode refuses before HTTP', () async {
      final s = _HealthServer();
      addTearDown(s.close);
      if (mode == 'revoked') s.current = false;
      if (mode == 'generation') s.generation++;
      if (mode == 'closed API') s.close();
      await expectLater(
        _open(_port(s, _Registry())),
        _refused('workItemUnverifiable'),
      );
      expect(s.adapter.requests, isEmpty);
    });
  }

  for (final phase in ['actor', 'namespace', 'health1']) {
    for (final mode in ['session', 'epoch']) {
      test('G-P5 $mode revoked during $phase opening refuses', () async {
        final s = _HealthServer();
        addTearDown(s.close);
        final r = _Registry();
        s.afterRead = (readPhase) {
          if (readPhase != phase) return;
          if (mode == 'session') s.current = false;
          if (mode == 'epoch') s.api.clearReadCache();
        };
        await expectLater(
          _open(_port(s, r)),
          phase == 'health1'
              ? _refused('cancelled')
              : phase == 'actor' && mode == 'session'
              ? _refused('workItemUnverifiable')
              : throwsA(
                  isA<ApiFailure>().having(
                    (failure) => failure.kind,
                    'kind',
                    FailureKind.cancelled,
                  ),
                ),
        );
        expect(s.mutations, 0);
        expect(r.starts, 0);
        expect(s.detailReads, phase == 'actor' ? 0 : 1);
        expect(s.healthReads, phase == 'health1' ? 1 : 0);
      });
    }
  }

  for (final own in ['onTrack', 'needsAttention', 'atRisk', 'none']) {
    test('G-P5 production own health $own sends exact payload once', () async {
      final s = _HealthServer(
        value: own == 'onTrack'
            ? WorkItemHealthEditValue.atRisk
            : WorkItemHealthEditValue.onTrack,
      );
      addTearDown(s.close);
      final r = _Registry();
      final p = _port(s, r);
      final prepared = await _open(p, request: _request(health: own));
      final desired = own == 'none' ? null : own;
      expect(prepared.releaseName, '$g0ePath#5');
      expect(prepared.confirmName, '$g0ePath#5');
      expect(prepared.projectPath, isNull);
      expect(prepared.groupIdentity!.groupId, 7);
      expect(prepared.groupIdentity!.generation, 7);
      expect(
        prepared.groupIdentity!.readEpoch,
        s.api.captureGroupReadEpoch().readEpoch,
      );
      expect(prepared.groupIdentity!.apiOwner, same(s.api));
      expect(prepared.hasCurrentGroupIdentity, isTrue);
      expect(prepared.targetConfidential, isNull);
      expect(prepared.writeKeys, {_key});
      expect(prepared.dependencyKeys, isEmpty);
      expect(prepared.bindingTargets.single.kind, AiTargetKind.groupWorkItem);
      expect(prepared.bindingTargets.single.origin, AiTargetOrigin.proposed);
      expect(prepared.bindingTargets.single.side, AiResourceSide.group);
      expect(prepared.bindingTargets.single.groupId, 7);
      expect(prepared.bindingTargets.single.workItemGid, _gid);
      expect(prepared.journal.updatedAt, healthRevision.toIso8601String());
      expect((prepared.preview as AiFieldsPreview).fields, {
        'healthStatus': desired,
      });
      final outcome = await _commit(
        p,
        prepared,
        before: () async {
          expect(r.active, isTrue);
          expect(s.healthReads, 2);
          expect(s.mutations, 0);
        },
      );
      expect(
        outcome,
        isA<AiWriteSettled>()
            .having((o) => o.state, 'state', AiJournalState.succeeded)
            .having((o) => o.readbackVerified, 'readback', isTrue),
      );
      expect(s.inputs, [
        {
          'id': _gid,
          'healthStatusWidget': {'healthStatus': desired},
        },
      ]);
      expect(s.healthReads, 3);
      expect(s.mutations, 1);
      expect(r.starts, 1);
      expect(r.settles, 1);
      expect(r.settledResult, AiWorkItemWriteResult.confirmed);
      expect(r.settledRevision, s.revision);
      expect(
        await p.commit(prepared, mayStart: () => true),
        isA<AiWriteNotSent>(),
      );
      expect(s.mutations, 1);
    });
  }

  for (final own in ['onTrack', 'none']) {
    test('G-P5 own $own noop skips hook despite rolled-up atRisk', () async {
      final s = _HealthServer(
        value: own == 'none' ? null : WorkItemHealthEditValue.onTrack,
      );
      addTearDown(s.close);
      final r = _Registry();
      final p = _port(s, r);
      final prepared = await _open(p, request: _request(health: own));
      s.rollupCount++;
      var hooks = 0;
      expect(
        await _commit(p, prepared, before: () async => hooks++),
        isA<AiGraphNoChange>(),
      );
      expect(hooks, 0);
      expect(s.mutations, 0);
      expect(s.healthReads, 2);
      expect(r.settledResult, AiWorkItemWriteResult.notSent);
      expect(r.settles, 1);
      expect(r.settledRevision, isNull);
    });
  }

  test(
    'G-P5 roll-up changes do not change own-health binding digest',
    () async {
      final s = _HealthServer();
      addTearDown(s.close);
      final p = _port(s, _Registry());
      final first = await _open(p);
      s.rollupCount++;
      expect((await _open(p)).bindingDigest, first.bindingDigest);
      s.value = WorkItemHealthEditValue.onTrack;
      expect((await _open(p)).bindingDigest, isNot(first.bindingDigest));
    },
  );

  test(
    'G-P5 shared UI lease blocks AI prepare before health opening',
    () async {
      final s = _HealthServer();
      addTearDown(s.close);
      final r = _Registry()..active = true;
      await expectLater(_open(_port(s, r)), _refused('healthConflict'));
      expect(s.healthReads, 0);
      expect(r.starts, 0);
      expect(s.mutations, 0);
    },
  );

  test('G-P5 real UI status reservation blocks health opening', () async {
    final s = _HealthServer();
    addTearDown(s.close);
    final status = WorkItemStatusWriteRegistry.instance;
    final token = Object();
    expect(status.tryStartExternal(s.api, _gid, token), isTrue);
    addTearDown(
      () =>
          status.settleExternal(s.api, _gid, token: token, mutationSent: false),
    );
    final registry = _workspaceRegistry(s);
    await expectLater(_open(_port(s, registry)), _refused('healthConflict'));
    expect(s.healthReads, 0);
    expect(s.mutations, 0);
  });

  for (final mode in ['confirmed', 'uncertain', 'notSent']) {
    test('G-P5 real shared adapter excludes peers and settles $mode', () async {
      final s = _HealthServer();
      addTearDown(s.close);
      final registry = _workspaceRegistry(s);
      final peer = _workspaceRegistry(s);
      final p = _port(s, registry);
      final prepared = await _open(p);
      s.mutationNotApplied = mode == 'uncertain';
      s.widgetPresent = mode != 'notSent';
      var hooks = 0;
      final outcome = await _commit(
        p,
        prepared,
        before: () async {
          hooks++;
          expect(peer.isActive(_gid), isTrue);
          for (final kind in AiWorkItemWriteKind.values) {
            expect(peer.tryStart(_gid, kind), isNull);
          }
          const otherGid = 'gid://gitlab/WorkItem/92';
          final other = peer.tryStart(otherGid, AiWorkItemWriteKind.health)!;
          peer.settle(other, AiWorkItemWriteResult.notSent, null);
        },
      );
      expect(peer.isActive(_gid), isFalse);
      final freshness = aiWorkspaceWriteFreshnessForTesting(
        s.api,
        _gid,
        AiWorkItemWriteKind.health,
      );
      if (mode == 'notSent') {
        expect(outcome, _notSent('healthUnsupported'));
        expect(hooks, 0);
        expect(s.mutations, 0);
        expect(freshness, isNull);
      } else {
        expect(
          outcome,
          isA<AiWriteSettled>().having(
            (value) => value.state,
            'state',
            mode == 'confirmed'
                ? AiJournalState.succeeded
                : AiJournalState.writeUncertain,
          ),
        );
        expect(hooks, 1);
        expect(s.mutations, 1);
        expect(freshness!.confirmed, mode == 'confirmed');
        expect(freshness.revision, mode == 'confirmed' ? s.revision : null);
      }
      final reopened = peer.tryStart(_gid, AiWorkItemWriteKind.health)!;
      peer.settle(reopened, AiWorkItemWriteResult.notSent, null);
    });
  }

  for (final mode in ['refuse', 'UI active']) {
    test(
      'G-P5 registry $mode at dispatch precedes preflight and hook',
      () async {
        final s = _HealthServer();
        addTearDown(s.close);
        final r = _Registry();
        final p = _port(s, r);
        final prepared = await _open(p);
        r.refuse = mode == 'refuse';
        r.active = mode == 'UI active';
        var hooks = 0;
        expect(
          await _commit(p, prepared, before: () async => hooks++),
          _notSent('healthConflict'),
        );
        expect(hooks, 0);
        expect(s.healthReads, 1);
        expect(r.settles, 0);
        expect(s.mutations, 0);
      },
    );
  }

  for (final mode in [
    'widget',
    'health field',
    'write permission',
    'read permission',
  ]) {
    for (final phase in ['opening', 'preflight']) {
      test('G-P5 $mode absent at $phase refuses before hook', () async {
        final s = _HealthServer();
        addTearDown(s.close);
        final r = _Registry();
        final p = _port(s, r);
        void revoke() {
          switch (mode) {
            case 'widget':
              s.widgetPresent = false;
            case 'health field':
              s.healthFieldPresent = false;
            case 'write permission':
              s.canWrite = false;
            case 'read permission':
              s.canRead = false;
          }
        }

        final reason = mode == 'health field'
            ? 'invalidResponse'
            : mode == 'widget'
            ? 'healthUnsupported'
            : 'healthForbidden';
        if (phase == 'opening') {
          revoke();
          await expectLater(_open(p), _refused(reason));
          expect(r.starts, 0);
        } else {
          final prepared = await _open(p);
          revoke();
          var hooks = 0;
          expect(
            await _commit(p, prepared, before: () async => hooks++),
            _notSent(reason),
          );
          expect(hooks, 0);
          expect(r.settledResult, AiWorkItemWriteResult.notSent);
          expect(r.settles, 1);
        }
        expect(s.mutations, 0);
      });
    }
  }

  for (final mode in [
    'outer group',
    'owner group',
    'iid',
    'project descendant',
    'missing project',
    'missing namespace',
    'GID type',
    'path',
  ]) {
    test('G-P5 strict namespace rejects $mode with mutation0', () async {
      final s = _HealthServer();
      addTearDown(s.close);
      s.alterNamespace = (node) {
        final item = node['workItem']! as Map;
        switch (mode) {
          case 'outer group':
            node['id'] = 'gid://gitlab/Group/8';
          case 'owner group':
            item['namespace'] = {
              'id': 'gid://gitlab/Group/8',
              'fullPath': g0ePath,
            };
          case 'iid':
            item['iid'] = '6';
          case 'project descendant':
            item['project'] = {
              'id': 'gid://gitlab/Project/7',
              'fullPath': 'team/sub/project',
            };
          case 'missing project':
            item.remove('project');
          case 'missing namespace':
            item.remove('namespace');
          case 'GID type':
            item['id'] = 'gid://gitlab/Group/7';
          case 'path':
            node['fullPath'] = 'team/other';
        }
      };
      await expectLater(
        _open(_port(s, _Registry())),
        throwsA(anyOf(isA<ApiFailure>(), isA<AiWriteRefused>())),
      );
      expect(s.detailReads, 1);
      expect(s.healthReads, 0);
      expect(s.mutations, 0);
    });
  }

  for (final args in <Map<String, Object?>>[
    {'groupId': 8},
    {'iid': 6},
  ]) {
    test('G-P5 exact grant refuses foreign coordinates $args', () async {
      final s = _HealthServer();
      addTearDown(s.close);
      await expectLater(
        _open(_port(s, _Registry()), request: _request(extra: args)),
        _refused('workItemUnverifiable'),
      );
      expect(s.detailReads, 0);
      expect(s.mutations, 0);
    });
  }

  for (final phase in ['opening', 'preflight', 'acknowledgement', 'readback']) {
    for (final mismatch in [
      'missing project',
      'missing namespace',
      'project descendant',
      'owner group',
      'path',
      'gid',
      'iid',
    ]) {
      test('G-P5 strict health $phase rejects $mismatch', () async {
        final s = _HealthServer();
        addTearDown(s.close);
        final r = _Registry();
        final p = _port(s, r);
        void tamper(Map<String, Object?> node) {
          switch (mismatch) {
            case 'missing project':
              node.remove('project');
            case 'missing namespace':
              node.remove('namespace');
            case 'project descendant':
              node['project'] = {
                'id': 'gid://gitlab/Project/7',
                'fullPath': 'team/sub/project',
              };
            case 'owner group':
              node['namespace'] = {
                'id': 'gid://gitlab/Group/8',
                'fullPath': g0ePath,
              };
            case 'path':
              node['namespace'] = {
                'id': 'gid://gitlab/Group/7',
                'fullPath': 'team/other',
              };
            case 'gid':
              node['id'] = 'gid://gitlab/WorkItem/92';
            case 'iid':
              node['iid'] = '6';
          }
        }

        if (phase == 'acknowledgement') {
          s.alterAcknowledgement = tamper;
        } else {
          final read = switch (phase) {
            'opening' => 1,
            'preflight' => 2,
            _ => 3,
          };
          s.alterHealthNode = (node, number) {
            if (number == read) tamper(node);
          };
        }
        if (phase == 'opening') {
          await expectLater(_open(p), _refused('invalidResponse'));
          expect(r.starts, 0);
          expect(s.mutations, 0);
          return;
        }
        final prepared = await _open(p);
        var hooks = 0;
        final outcome = await _commit(p, prepared, before: () async => hooks++);
        if (phase == 'preflight') {
          expect(outcome, _notSent('invalidResponse'));
          expect(s.mutations, 0);
          expect(hooks, 0);
          expect(r.settledResult, AiWorkItemWriteResult.notSent);
        } else {
          expect(
            outcome,
            isA<AiWriteSettled>()
                .having((o) => o.state, 'state', AiJournalState.writeUncertain)
                .having((o) => o.readbackVerified, 'readback', isFalse),
          );
          expect(s.mutations, 1);
          expect(hooks, 1);
          expect(r.settledResult, AiWorkItemWriteResult.uncertain);
        }
        expect(r.settles, 1);
        expect(r.active, isFalse);
      });
    }
  }

  for (final extra in <Map<String, Object?>>[
    {'projectId': 7},
    {'groupId': '7'},
    {'groupId': 0},
    {'iid': -1},
    {'healthStatus': null},
    {'healthStatus': 'critical'},
    {'rolledUpHealthStatus': 'atRisk'},
    {'id': _gid},
    {'generation': 7},
    {'readEpoch': 11},
    {'expectedUpdatedAt': 'now'},
    {'query': 'mutation'},
    {'confirmName': 'team/sub#5'},
  ]) {
    test(
      'G-P5 rejects model identity or non-allowlisted field $extra',
      () async {
        final s = _HealthServer();
        addTearDown(s.close);
        await expectLater(
          _open(_port(s, _Registry()), request: _request(extra: extra)),
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
        expect(s.adapter.requests, isEmpty);
      },
    );
  }

  for (final mode in [
    'revision',
    'own health',
    'actor',
    'server',
    'malformed',
  ]) {
    test('G-P5 preflight $mode drift never reaches hook', () async {
      final s = _HealthServer();
      addTearDown(s.close);
      final r = _Registry();
      final p = _port(s, r);
      final prepared = await _open(p);
      switch (mode) {
        case 'revision':
          s.driftBeforePreflight = true;
        case 'own health':
          s.value = WorkItemHealthEditValue.onTrack;
        case 'actor':
          s.actorMismatch = true;
        case 'server':
          s.failHealthReadStatus = 503;
        case 'malformed':
          s.malformedHealthRead = true;
      }
      var hooks = 0;
      final outcome = await _commit(p, prepared, before: () async => hooks++);
      expect(
        outcome,
        _notSent(
          mode == 'actor'
              ? 'cancelled'
              : mode == 'server'
              ? 'server'
              : mode == 'malformed'
              ? 'invalidResponse'
              : 'healthConflict',
        ),
      );
      expect(hooks, 0);
      expect(s.mutations, 0);
      expect(r.settledResult, AiWorkItemWriteResult.notSent);
      expect(r.settles, 1);
    });
  }

  for (final mode in ['flush throws', 'mayStart false', 'stale context']) {
    test('G-P5 $mode releases lease as notSent', () async {
      final s = _HealthServer();
      addTearDown(s.close);
      final r = _Registry();
      final p = _port(s, r);
      final prepared = await _open(p);
      if (mode == 'stale context') s.current = false;
      final pending = _commit(
        p,
        prepared,
        before: () async {
          if (mode == 'flush throws') {
            throw StateError('synthetic flush failure');
          }
        },
        mayStart: () => mode != 'mayStart false',
      );
      if (mode == 'flush throws') {
        await expectLater(pending, throwsA(isA<StateError>()));
      } else {
        expect(await pending, isA<AiWriteNotSent>());
      }
      expect(s.mutations, 0);
      expect(r.active, isFalse);
      expect(r.settles, mode == 'stale context' ? 0 : 1);
      if (mode != 'stale context') {
        expect(r.settledResult, AiWorkItemWriteResult.notSent);
      }
      expect(prepared.hasCurrentGroupIdentity, mode != 'stale context');
    });
  }

  for (final mode in [
    'errors',
    '401',
    'notApplied',
    'readback mismatch',
    'readback 401',
    'readback cancelled',
  ]) {
    test('G-P5 accepted $mode stays uncertain and settles once', () async {
      final s = _HealthServer();
      addTearDown(s.close);
      final r = _Registry();
      final p = _port(s, r);
      final prepared = await _open(p);
      switch (mode) {
        case 'errors':
          s.mutationErrors = true;
        case '401':
          s.mutation401 = true;
        case 'notApplied':
          s.mutationNotApplied = true;
        case 'readback mismatch':
          s.mismatchReadback = true;
        case 'readback 401':
          s.failReadNumber = 3;
          s.failHealthReadStatus = 401;
        case 'readback cancelled':
          s.onMutation = s.close;
      }
      final outcome = await _commit(p, prepared);
      expect(
        outcome,
        isA<AiWriteSettled>()
            .having((o) => o.state, 'state', AiJournalState.writeUncertain)
            .having((o) => o.readbackVerified, 'readback', isFalse),
      );
      expect(s.mutations, 1);
      expect(r.settledResult, AiWorkItemWriteResult.uncertain);
      expect(r.settledRevision, isNull);
      expect(r.settles, 1);
      expect(r.active, isFalse);
    });
  }

  for (final oauth in [false, true]) {
    test(
      'G-P5 production coordinator ${oauth ? 'OAuth' : 'PAT'} cap and durable send',
      () async {
        final h = await _Harness.create(oauth: oauth, maxHttp: 21);
        addTearDown(h.dispose);
        h.server.onMutation = () {
          expect(
            h.base.journal.entries(_account).single.state,
            AiJournalState.dispatching,
          );
          expect(h.registry.active, isTrue);
        };
        final outcome = await h.approve((await h.propose())!);
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.readbackConfirmed, isTrue);
        expect(h.server.adapter.requests, hasLength(11));
        expect(h.server.tokenAdapter?.requests.length ?? 0, 0);
        expect(h.server.detailReads, 2);
        expect(h.server.healthReads, 4);
        expect(h.server.mutations, 1);
        expect(h.registry.settles, 1);
        expect(
          h.base.journal.entries(_account).single.releaseName,
          '$g0ePath#5',
        );
      },
    );
  }

  test('G-P5 all-read OAuth replay revokes context before mutation', () async {
    final h = await _Harness.create(replayAllReads: true, maxHttp: 21);
    addTearDown(h.dispose);
    expect(await h.propose(), isNull);
    expect(
      h.coordinator.outcomeFor('health-0')!.reasonCode,
      'workItemUnverifiable',
    );
    expect(h.server.adapter.requests, hasLength(4));
    expect(h.server.tokenRefreshes, 2);
    expect(h.server.detailReads, 0);
    expect(h.server.mutations, 0);
    expect(h.registry.starts, 0);
  });

  for (final read in [2, 3, 4, 5, 6, 7, 8, 9]) {
    test('G-P5 OAuth replay at pre-send read $read refuses mutation', () async {
      final h = await _Harness.create(
        oauth: true,
        replayReadNumbers: {read},
        maxHttp: 21,
      );
      addTearDown(h.dispose);
      final proposal = await h.propose();
      if (read <= 4) {
        expect(proposal, isNull);
        expect(h.registry.starts, 0);
      } else {
        expect((await h.approve(proposal!)).state, AiJournalState.notExecuted);
        expect(h.registry.starts, read == 9 ? 1 : 0);
        expect(h.registry.settles, read == 9 ? 1 : 0);
      }
      expect(h.server.adapter.requests, hasLength(read + 1));
      expect(h.server.tokenRefreshes, 1);
      expect(h.server.mutations, 0);
    });
  }

  test(
    'G-P5 OAuth replay before capture and after acceptance is safe',
    () async {
      final h = await _Harness.create(
        oauth: true,
        replayReadNumbers: {1, 10},
        maxHttp: 21,
      );
      addTearDown(h.dispose);
      final outcome = await h.approve((await h.propose())!);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.readbackConfirmed, isTrue);
      expect(h.server.adapter.requests, hasLength(13));
      expect(h.server.tokenRefreshes, 2);
      expect(h.server.detailReads, 2);
      expect(h.server.healthReads, 4);
      expect(h.server.mutations, 1);
      expect(h.registry.settledResult, AiWorkItemWriteResult.confirmed);
      expect(h.registry.settles, 1);
    },
  );

  for (final phase in ['before freshness', 'during freshness']) {
    test('G-P5 stale proposal $phase cannot be revived by dispatch', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      if (phase == 'before freshness') {
        h.server.api.clearReadCache();
      } else {
        h.server.afterRead = (readPhase) {
          if (readPhase == 'freshness') h.server.api.clearReadCache();
        };
      }
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(h.server.detailReads, 1);
      expect(h.server.mutations, 0);
      expect(h.registry.starts, 0);
    });
  }

  test('G-P5 post-send session loss stays uncertain', () async {
    final s = _HealthServer();
    addTearDown(s.close);
    final r = _Registry();
    final p = _port(s, r);
    final prepared = await _open(p);
    s.onMutation = () => s.current = false;
    expect(
      await _commit(p, prepared),
      isA<AiWriteSettled>().having(
        (o) => o.state,
        'state',
        AiJournalState.writeUncertain,
      ),
    );
    expect(s.mutations, 1);
    expect(s.healthReads, 2);
    expect(r.settles, 1);
    expect(r.settledResult, AiWorkItemWriteResult.uncertain);
  });

  test('G-P5 cap-minus-one refuses before any HTTP', () async {
    final h = await _Harness.create(maxHttp: 20);
    addTearDown(h.dispose);
    expect(await h.propose(), isNull);
    expect(
      h.coordinator.outcomeFor('health-0')!.reasonCode,
      'httpBudgetExceeded',
    );
    expect(h.server.adapter.requests, isEmpty);
  });

  test('G-P5 coordinator rejects unknown field before any HTTP', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    expect(await h.propose(extra: {'rolledUpHealthStatus': []}), isNull);
    expect(h.server.adapter.requests, isEmpty);
  });

  for (final mode in ['generation', 'context']) {
    test('G-P5 dispatching flush revokes $mode with mutation0', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      final entered = h.base.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = h.approve(proposal);
      await entered;
      if (mode == 'generation') h.generation++;
      if (mode == 'context') h.server.current = false;
      h.base.files.releaseBarrier();
      final outcome = await pending;
      expect(outcome.state, AiJournalState.notExecuted);
      expect(h.server.mutations, 0);
      expect(h.registry.settledResult, AiWorkItemWriteResult.notSent);
      expect(h.registry.settles, 1);
      expect(
        h.base.journal.entries(_account).single.state,
        AiJournalState.notExecuted,
      );
    });
  }

  test(
    'G-P5 coordinator uncertain outcome fail-stops a second write',
    () async {
      final h = await _Harness.create(maxHttp: 42);
      addTearDown(h.dispose);
      h.server.mutationNotApplied = true;
      expect(
        (await h.approve((await h.propose())!)).state,
        AiJournalState.writeUncertain,
      );
      final requests = h.server.adapter.requests.length;
      expect(await h.propose(health: 'onTrack'), isNull);
      expect(
        h.coordinator.outcomeFor('health-1')!.reasonCode,
        'previousWriteIncomplete',
      );
      expect(h.server.adapter.requests, hasLength(requests));
      expect(h.server.mutations, 1);
    },
  );
}
