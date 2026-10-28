import 'release_policy_support.dart';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_work_item_write_registry.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as writes;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_status.dart';

import '../support/fake_adapter.dart';
import '../support/work_item_status_fixture.dart';
import 'mr6b3_support.dart'
    show Mr6b3JournalFiles, Mr6b3JournalKeyStore, Mr6b3Policy;
import 'mr6b3g_support.dart' show g0eIdentity;

const groupStatusStageOperations = <String>{'updateGroupWorkItemStatus'};
const _operation = 'updateGroupWorkItemStatus';
const _gid = WorkItemStatusFixture.groupItemId;
const _candidate = WorkItemStatusFixture.statusDoing;
const _account = 'https://example.com/gitlab#7';
const _conversation = 'gp3-status';
const _key = AiConflictKey([_account, 'group:84', 'workItem', '17']);
const _scope = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.groupWorkItem,
      groupId: 84,
      groupFullPath: 'studio/group',
      iid: 17,
    ),
  ],
);
const _args = <String, Object?>{
  'groupId': 84,
  'iid': 17,
  'candidateId': _candidate,
};

// Isolate the status row in the test coordinator, retaining its contract.
final class _StatusLedger implements AiCapabilityLedger {
  @override
  AiCapability? find(String operationId) {
    if (operationId != _operation) return null;
    final row = productionAiLedger.find(operationId)!;
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      namedMethod: row.namedMethod,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
      boundary: row.boundary,
    );
  }

  @override
  List<AiCapability> get modelVisible => [find(_operation)!];
}

/// Counts actual adapter arrivals independently of ledger/http allowances.
final class _StatusServer {
  _StatusServer({this.oauth = false}) {
    api = GitLabApi(
      instance: fixture.account.instance,
      credential: oauth
          ? const OAuthCredential(
              accessToken: 'synthetic-status-access',
              refreshToken: 'synthetic-status-refresh',
              clientId: 'synthetic-status-app',
            )
          : const PatCredential('synthetic-status-pat'),
      dio: Dio()..httpClientAdapter = adapter,
      cdnAdapter: adapter,
      oauth: oauth
          ? OAuthTokenClient(
              instance: fixture.account.instance,
              clientId: 'synthetic-status-app',
              dio: Dio()..httpClientAdapter = refreshAdapter,
            )
          : null,
    );
  }

  final bool oauth;
  final fixture = WorkItemStatusFixture()..serveParent = true;
  late final FakeAdapter adapter = FakeAdapter(_respond);
  late final FakeAdapter refreshAdapter = FakeAdapter((_) {
    refreshes++;
    return jsonResponse({
      'access_token': 'synthetic-status-access-$refreshes',
      'refresh_token': 'synthetic-status-refresh-$refreshes',
      'token_type': 'Bearer',
    });
  });
  late final GitLabApi api;
  final events = <String>[];
  int readAttempts = 0;
  int logicalReads = 0;
  int statusReads = 0;
  int mutations = 0;
  int refreshes = 0;
  bool _retry = false;
  int? failReadAt;
  int readFailureStatus = 503;
  int? mutationStatus;
  bool notApplied = false;
  bool mismatchReadback = false;
  bool malformedAck = false;
  bool challengeEveryRead = false;
  int? challengeReadAt;
  int? corruptStatusAt;
  bool corruptNamespace = false;
  String? ownerFault;
  String? corruptPhase;
  void Function(String)? afterRead;
  void Function(int)? beforeStatusRead;
  Future<void> Function()? onMutation;

  Future<ResponseBody> _respond(RequestOptions request) async {
    final body = request.data;
    final query = body is Map ? body['query'] : null;
    final mutation = query is String && query.startsWith('mutation ');
    final operation = query is String
        ? RegExp(r'^(?:query|mutation) (\w+)').firstMatch(query)!.group(1)!
        : '${request.method} ${request.uri.path}';
    events.add(operation);
    if (mutation) {
      mutations++;
      await onMutation?.call();
      if (mutationStatus != null) {
        return jsonResponse({
          'message': 'synthetic mutation failure',
        }, status: mutationStatus!);
      }
      if (malformedAck) return jsonResponse({'data': <String, Object?>{}});
      if (notApplied) {
        final item = fixture.item(group: true);
        return jsonResponse({
          'data': {
            'workItemUpdate': {
              'errors': <String>[],
              'workItem': {
                'id': item.id,
                'iid': '${item.iid}',
                'state': item.state,
                'updatedAt': statusFixtureTimestamp(item.updatedAt),
                'project': null,
                'namespace': {
                  'id': item.namespace!.id,
                  'fullPath': item.namespace!.fullPath,
                },
                'workItemType': {'id': item.typeId},
                'widgets': [
                  {'type': 'STATUS', 'status': item.assignment?.toJson()},
                ],
              },
            },
          },
        });
      }
      var response = await fixture.adapter.respond(request);
      if (corruptPhase == 'ack') {
        final chunks = await response.stream.toList();
        final data =
            jsonDecode(utf8.decode(chunks.expand((chunk) => chunk).toList()))
                as Map<String, dynamic>;
        corruptOwner(
          ((data['data'] as Map<String, dynamic>)['workItemUpdate']
                  as Map<String, dynamic>)['workItem']
              as Map<String, dynamic>,
        );
        response = jsonResponse(data);
      }
      if (mismatchReadback) {
        fixture.item(group: true).assignment =
            WorkItemStatusFixture.defaultMembers.first;
      }
      return response;
    }
    readAttempts++;
    if (oauth &&
        !_retry &&
        (challengeEveryRead || logicalReads + 1 == challengeReadAt)) {
      _retry = true;
      return jsonResponse({'message': 'synthetic read challenge'}, status: 401);
    }
    _retry = false;
    logicalReads++;
    if (operation == 'MobileWorkItemStatus') {
      statusReads++;
      beforeStatusRead?.call(statusReads);
      if (statusReads == failReadAt) {
        return jsonResponse({
          'message': 'synthetic read failure',
        }, status: readFailureStatus);
      }
    }
    ResponseBody response;
    if (request.method == 'GET' && request.uri.path.endsWith('/groups/84')) {
      expect(request.uri.queryParameters, {'with_projects': 'false'});
      response = jsonResponse({
        'id': 84,
        'name': 'Group',
        'full_path': 'studio/group',
        'visibility': 'private',
      });
    } else {
      response = await fixture.adapter.respond(request);
    }
    if ((operation == 'MobileWorkItemStatus' &&
            statusReads == corruptStatusAt) ||
        (operation == 'MobileNamespaceWorkItem' && corruptNamespace)) {
      response = await corrupt(
        response,
        namespace: operation == 'MobileNamespaceWorkItem',
      );
    }
    afterRead?.call(operation);
    return response;
  }

  Future<ResponseBody> corrupt(
    ResponseBody response, {
    bool namespace = false,
  }) async {
    final chunks = await response.stream.toList();
    final data =
        jsonDecode(utf8.decode(chunks.expand((chunk) => chunk).toList()))
            as Map<String, dynamic>;
    final result = data['data'] as Map<String, dynamic>;
    final item =
        (namespace
                ? (result['namespace'] as Map<String, dynamic>)['workItem']
                : result['workItem'])
            as Map<String, dynamic>;
    corruptOwner(item);
    return jsonResponse(data);
  }

  void corruptOwner(Map<String, dynamic> item) {
    switch (ownerFault) {
      case 'missingProject':
        item.remove('project');
      case 'project':
        item['project'] = {
          'id': 'gid://gitlab/Project/84',
          'fullPath': 'studio/group',
        };
      case 'foreignGroup':
        item['namespace'] = {
          'id': 'gid://gitlab/Group/85',
          'fullPath': 'studio/group',
        };
      case 'path':
        item['namespace'] = {
          'id': 'gid://gitlab/Group/84',
          'fullPath': 'studio/other',
        };
      case 'missingNamespace':
        item.remove('namespace');
      case 'iid':
        item['iid'] = '18';
      case 'gid':
        item['id'] = 'gid://gitlab/WorkItem/402';
    }
  }

  void close() {
    fixture.releaseHolds();
    api.close();
    fixture.closeAll();
  }
}

final class _RecordingRegistry implements AiWorkItemWriteRegistry {
  _RecordingRegistry(this.inner);
  final AiWorkItemWriteRegistry inner;
  int starts = 0;
  final settlements = <AiWorkItemWriteResult>[];

  @override
  bool isActive(String gid) => inner.isActive(gid);
  @override
  AiWorkItemWriteLease? tryStart(String gid, AiWorkItemWriteKind kind) {
    starts++;
    return inner.tryStart(gid, kind);
  }

  @override
  void settle(
    AiWorkItemWriteLease lease,
    AiWorkItemWriteResult result,
    DateTime? revision,
  ) {
    settlements.add(result);
    inner.settle(lease, result, revision);
  }
}

final class _StatusHarness {
  _StatusHarness._(this.server, this.root) {
    files = Mr6b3JournalFiles(root);
    journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'p3-status-test',
    )..now = () => clock;
    registry = _RecordingRegistry(
      createAiWorkspaceWorkItemWriteRegistry(
        api: server.api,
        accountKey: _account,
        instanceKey: server.api.instance.key,
        generation: 12,
        isCurrent: () => policy.alive && generation == 12,
      ),
    );
    currentApi = server.api;
    port = makePort();
  }

  static Future<_StatusHarness> create({
    bool oauth = false,
    int maxRequests = 40,
    bool missingStart = false,
  }) async {
    final h = _StatusHarness._(
      _StatusServer(oauth: oauth),
      Directory.systemTemp.createTempSync('p3-status-'),
    );
    await h.journal.recoverAfterAccountsLoaded([_account]);
    await h.journal.ensureInitialized(_account);
    h.activePort = missingStart ? _MissingStartPort(h) : h.port;
    h.budget = AiToolBudget(maxGitLabRequests: maxRequests);
    h.coordinator = h.newCoordinator(_conversation);
    h.beginRun();
    return h;
  }

  final _StatusServer server;
  final Directory root;
  final policy = Mr6b3Policy();
  final keys = Mr6b3JournalKeyStore();
  int generation = 12;
  Object? currentApi;
  String currentAccount = _account;
  bool contextLive = true;
  bool get isCurrent =>
      policy.alive &&
      contextLive &&
      generation == 12 &&
      identical(currentApi, server.api) &&
      currentAccount == _account;
  writes.GitLabAiWritePort makePort({
    bool context = true,
    bool registryAvailable = true,
  }) => writes.GitLabAiWritePort(
    server.api,
    accountKey: _account,
    workItemWriteRegistry: registryAvailable ? registry : null,
    sessionGeneration: context ? 12 : null,
    isCurrent: context ? () => isCurrent : null,
  );
  AiWriteScope scope = _scope;
  AiTargetRef? currentResource = AiTargetRef(
    kind: AiTargetKind.groupWorkItem,
    groupId: 84,
    groupFullPath: 'studio/group',
    iid: 17,
  );
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  late final Mr6b3JournalFiles files;
  late final AiWriteJournal journal;
  late final _RecordingRegistry registry;
  late final writes.GitLabAiWritePort port;
  late final writes.AiGitLabWritePort activePort;
  late AiToolBudget budget;
  late final PolicyAiWriteCoordinator coordinator;
  final startEvents = <String>[];
  int _id = 0;

  PolicyAiWriteCoordinator newCoordinator(String conversation) =>
      PolicyAiWriteCoordinator(
        releasePolicy: fixtureReleasePolicy,
        snapshot: () => AiWritePolicySnapshot(
          appInForeground: true,
          scope: scope,
          level: policy.level,
          ceiling: AiAutonomyLevel.bypass,
          consentHash: 'p3-synthetic-consent',
          writePolicyRevision: policy.revision,
          scopeRevision: 1,
          sessionGeneration: generation,
          ownerApi: server.api,
          currentResource: currentResource,
          alive: policy.alive,
          consentValid: policy.consentValid,
          clientMayStart: policy.clientMayStart,
        ),
        createPort: () => activePort,
        journal: journal,
        conversationId: conversation,
        budget: () => budget,
        readFreshness: (_) async {
          final group = await server.api.group(84);
          expect(group['id'], 84);
          expect(group['full_path'], 'studio/group');
          return const AiWriteFreshness(
            targetVisibility: 'private',
            visibilityUnreadable: true,
          );
        },
        placeholders: text.UploadPlaceholderTable(
          instance: server.api.instance,
        ),
        knownSecrets: () => const {},
        safeDisplay: (value) => value,
        ledger: _StatusLedger(),
        now: () => clock,
      );

  void beginRun([String message = 'Set status of studio/group#17.']) {
    coordinator.beginRun(message);
    coordinator.beginTurn();
  }

  AiToolCall call([Map<String, Object?> args = _args]) => AiToolCall(
    id: 'p3-${_id++}',
    name: _operation,
    arguments: {...args, 'reason': 'synthetic untrusted status proposal'},
  );
  Future<AiWriteProposal?> propose([Map<String, Object?> args = _args]) =>
      coordinator.propose(call(args));
  Future<AiWriteOutcome> approve(AiWriteProposal p) =>
      coordinator.approve(p).timeout(const Duration(seconds: 20));
  writes.AiWriteRequest request([Map<String, Object?> args = _args]) =>
      writes.AiWriteRequest(
        operationId: _operation,
        executionId: 'direct-${_id++}',
        scope: scope,
        arguments: args,
      );
  Future<void> seedMark() async {
    await journal.prepare(
      draft: AiJournalDraft(
        executionId: 'p3-seed',
        accountKey: _account,
        conversationId: 'seed',
        runId: 'seed',
        operationId: _operation,
        writeKeys: {_key},
        payloadSha256: 'a' * 64,
        releaseName: 'studio/group#17',
      ),
    );
    await journal.markDispatching(executionId: 'p3-seed');
    await journal.finish(
      executionId: 'p3-seed',
      terminal: AiJournalState.writeUncertain,
    );
    await journal.releaseByUser(
      executionId: 'p3-seed',
      typedName: 'studio/group#17',
    );
  }

  Future<Map<String, Object?>> readDurableJournal() =>
      AiHistoryCipher.decryptJson(
        File(files.pathFor(_account)).readAsBytesSync(),
        keys.keys[_account]!,
        _account,
        AiJournalFiles.fileName,
      );

  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    server.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

// Fault injection exercises the real STATUS method without changing its API
// or the production callback, which always reports START with its own lease.
final class _MissingStartPort implements writes.AiGitLabWritePort {
  _MissingStartPort(this.h);
  final _StatusHarness h;
  @override
  Future<writes.AiWritePrepared> prepare(writes.AiWriteRequest request) async {
    final prepared = await h.port.prepare(request);
    final access = await h.server.api.workItemStatus(
      h.server.fixture
          .detail(group: true)
          .withStrictGroupOwner(prepared.groupIdentity!),
      expectedUserId: 7,
      generation: 12,
    );
    return writes.AiWritePrepared.graph(
      request: request,
      releaseName: prepared.releaseName,
      groupIdentity: prepared.groupIdentity,
      groupIdentityIsCurrent: () => prepared.hasCurrentGroupIdentity,
      bindingTargets: prepared.bindingTargets,
      writeKeys: prepared.writeKeys,
      bindingDigest: prepared.bindingDigest,
      preview: prepared.preview,
      mutation: (hooks) async {
        final lease = h.registry.tryStart(_gid, AiWorkItemWriteKind.status);
        if (lease == null) {
          throw const writes.AiWriteRefused('statusNotStarted');
        }
        try {
          return await h.server.api.updateWorkItemStatus(
            access.target!,
            candidateId: request.arguments['candidateId']! as String,
            onMutationSent: (_) {
              h.startEvents.add('START');
              expect(
                h.journal.entries(_account).last.state,
                AiJournalState.dispatching,
              );
              expect(h.journal.requiresConfirmation(_account, {_key}), isFalse);
            },
            beforeMutation: () async {
              await hooks.beforeMutation();
              h.startEvents.add('B');
            },
            mayStart: () {
              h.startEvents.add('A');
              return hooks.mayStart();
            },
          );
        } finally {
          h.registry.settle(lease, AiWorkItemWriteResult.notSent, null);
        }
      },
    );
  }

  @override
  Future<writes.AiWriteOutcome> commit(
    writes.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => prepared.commitGraph(mayStart: mayStart);
}

Matcher _refused(String reason) => isA<writes.AiWriteRefused>().having(
  (error) => error.reason,
  'reason',
  reason,
);

void main() {
  setUp(() {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  });

  test('explicit gate-off override refuses before freshness', () async {
    aiGroupWorkItemWritesEnabledForTesting = false;
    final h = await _StatusHarness.create();
    addTearDown(h.dispose);
    expect(aiGroupWorkItemWritesAreEnabled, isFalse);
    expect(toolsForScope(_scope, releasePolicy: fixtureReleasePolicy), isEmpty);
    expect(await h.propose(), isNull);
    expect(h.server.adapter.requests, isEmpty);
  });

  for (final missing in ['context', 'registry']) {
    test('missing $missing refuses with zero HTTP', () async {
      final h = await _StatusHarness.create();
      addTearDown(h.dispose);
      final port = h.makePort(
        context: missing != 'context',
        registryAvailable: missing != 'registry',
      );
      await expectLater(
        port.prepare(h.request()),
        throwsA(
          _refused(
            missing == 'context'
                ? 'workItemUnverifiable'
                : 'registryUnavailable',
          ),
        ),
      );
      expect(h.server.adapter.requests, isEmpty);
    });
  }

  for (final change in ['generation', 'API', 'account', 'conversation']) {
    test('revoked $change context refuses before HTTP', () async {
      final h = await _StatusHarness.create();
      addTearDown(h.dispose);
      switch (change) {
        case 'generation':
          h.generation++;
        case 'API':
          h.currentApi = Object();
        case 'account':
          h.currentAccount = 'https://example.com/gitlab#8';
        case 'conversation':
          h.contextLive = false;
      }
      await expectLater(
        h.port.prepare(h.request()),
        throwsA(_refused('workItemUnverifiable')),
      );
      expect(h.server.adapter.requests, isEmpty);
    });
  }

  for (final read in [
    'GET /gitlab/api/v4/user',
    'MobileNamespaceWorkItem',
    'MobileWorkItemStatus',
  ]) {
    for (final invalidation in ['session', 'epoch']) {
      test('$invalidation lost during $read refuses the opening', () async {
        final h = await _StatusHarness.create();
        addTearDown(h.dispose);
        h.server.afterRead = (operation) {
          if (operation != read) return;
          if (invalidation == 'session') {
            h.contextLive = false;
          } else {
            h.server.api.clearReadCache();
          }
        };
        await expectLater(
          h.port.prepare(h.request()),
          throwsA(anyOf(isA<ApiFailure>(), isA<writes.AiWriteRefused>())),
        );
        expect(h.server.mutations, 0);
        expect(h.registry.starts, 0);
      });
    }
  }

  test(
    'prepared identity is bound to generation 12 and the live read epoch',
    () async {
      final h = await _StatusHarness.create();
      addTearDown(h.dispose);
      final prepared = await h.port.prepare(h.request());
      expect(prepared.groupIdentity!.generation, 12);
      expect(prepared.groupIdentity!.apiOwner, same(h.server.api));
      expect(prepared.hasCurrentGroupIdentity, isTrue);
      h.server.api.clearReadCache();
      expect(prepared.hasCurrentGroupIdentity, isFalse);
      expect(h.server.mutations, 0);
    },
  );

  for (final current in ['absent', 'different']) {
    test(
      'verified UI-added GID binds with $current current resource',
      () async {
        final h = await _StatusHarness.create();
        addTearDown(h.dispose);
        final prepared = await h.port.prepare(h.request());
        final identity = prepared.groupIdentity!;
        expect(
          prepared.bindingTargets.single.workItemGid,
          identity.workItemGid,
        );
        h.scope = AiWriteScope(
          accountKey: _account,
          grants: _scope.grants,
          uiAddedGroupWorkItems: [identity],
        );
        h.currentResource = current == 'absent'
            ? null
            : AiTargetRef(
                kind: AiTargetKind.groupWorkItem,
                groupId: 85,
                groupFullPath: 'studio/other',
                iid: 17,
              );
        h.beginRun('Apply status.');
        final proposal = (await h.propose())!;
        expect(
          proposal.tier.reasons,
          isNot(contains(AiFixedConfirmReason.targetUnbound)),
        );
        expect(
          proposal.tier.reasons,
          isNot(contains(AiFixedConfirmReason.targetNamedNotMarked)),
        );
        expect((await h.approve(proposal)).state, AiJournalState.succeeded);
        expect(h.server.mutations, 1);
      },
    );
  }

  test('mismatched UI-added GID refuses instead of binding by iid', () async {
    final h = await _StatusHarness.create();
    addTearDown(h.dispose);
    final prepared = await h.port.prepare(h.request());
    h.scope = AiWriteScope(
      accountKey: _account,
      grants: _scope.grants,
      uiAddedGroupWorkItems: [
        g0eIdentity(
          h.server.api,
          groupId: 84,
          fullPath: 'studio/group',
          iid: 17,
          workItemGid: 'gid://gitlab/WorkItem/402',
          generation: 12,
          readEpoch: prepared.groupIdentity!.readEpoch,
        ),
      ],
    );
    h.currentResource = null;
    h.beginRun('Apply status.');
    final call = h.call();
    expect(await h.coordinator.propose(call), isNull);
    expect(
      h.coordinator.outcomeFor(call.id)!.reasonCode,
      'workItemUnverifiable',
    );
    expect(h.server.mutations, 0);
  });

  test(
    'new epoch invalidates approval; a new proposal captures fresh evidence',
    () async {
      final h = await _StatusHarness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      h.server.api.clearReadCache();
      final result = await h.approve(proposal);
      expect(result.state, AiJournalState.notExecuted);
      expect(result.reasonCode, 'workItemUnverifiable');
      expect(h.server.mutations, 0);
      h.budget = AiToolBudget();
      h.beginRun();
      expect(
        (await h.approve((await h.propose())!)).state,
        AiJournalState.succeeded,
      );
      expect(h.server.mutations, 1);
    },
  );

  test(
    'epoch loss during dispatch flush refunds and preserves the marker',
    () async {
      final h = await _StatusHarness.create();
      addTearDown(h.dispose);
      await h.seedMark();
      final proposal = (await h.propose())!;
      final entered = h.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = h.approve(proposal);
      await entered;
      h.server.api.clearReadCache();
      h.files.releaseBarrier();
      final result = await pending;
      expect(result.state, AiJournalState.notExecuted);
      expect(result.mutationCount, 0);
      expect(h.server.mutations, 0);
      expect(h.journal.requiresConfirmation(_account, {_key}), isTrue);
      expect(h.journal.conversationWriteCount(_account, _conversation), 0);
      expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
    },
  );

  test(
    'session loss after send remains uncertain and holds the group key',
    () async {
      final h = await _StatusHarness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      h.server.onMutation = () async => h.contextLive = false;
      final result = await h.approve(proposal);
      expect(result.state, AiJournalState.writeUncertain);
      expect(result.readbackConfirmed, isFalse);
      expect(h.server.mutations, 1);
      expect(h.journal.isolated(_account, {_key}), isTrue);
      expect(h.registry.settlements, [AiWorkItemWriteResult.uncertain]);
    },
  );

  for (final phase in [
    'namespace',
    'opening',
    'dispatch',
    'preflight',
    'noop',
    'ack',
    'readback',
  ]) {
    for (final fault in [
      'missingProject',
      'project',
      'foreignGroup',
      'path',
      'missingNamespace',
      'iid',
      'gid',
    ]) {
      test(
        'strict owner $phase refuses $fault without false success',
        () async {
          final h = await _StatusHarness.create();
          addTearDown(h.dispose);
          h.server.ownerFault = fault;
          h.server.corruptNamespace = phase == 'namespace';
          h.server.corruptStatusAt = switch (phase) {
            'opening' => 1,
            'dispatch' => 2,
            'preflight' || 'noop' => 3,
            'readback' => 4,
            _ => null,
          };
          h.server.corruptPhase = phase;
          if (phase == 'namespace' || phase == 'opening') {
            await expectLater(
              h.port.prepare(h.request()),
              throwsA(anyOf(isA<ApiFailure>(), isA<writes.AiWriteRefused>())),
            );
            expect(h.server.mutations, 0);
            expect(h.registry.starts, 0);
            return;
          }
          final proposal = (await h.propose(
            phase == 'noop'
                ? {..._args, 'candidateId': WorkItemStatusFixture.statusTodo}
                : _args,
          ))!;
          final result = await h.approve(proposal);
          final sent = phase == 'ack' || phase == 'readback';
          expect(
            result.state,
            sent ? AiJournalState.writeUncertain : AiJournalState.notExecuted,
          );
          expect(result.mutationCount, sent ? 1 : 0);
          expect(result.readbackConfirmed, isFalse);
          expect(h.server.mutations, sent ? 1 : 0);
          expect(h.journal.isolated(_account, {_key}), sent);
          if (phase != 'dispatch') {
            expect(h.registry.settlements, [
              sent
                  ? AiWorkItemWriteResult.uncertain
                  : AiWorkItemWriteResult.notSent,
            ]);
          }
        },
      );
    }
  }

  for (final oauth in [false, true]) {
    test(
      'independent full group path L=10 ${oauth ? 'OAuth' : 'PAT'} within cap 21',
      () async {
        final h = await _StatusHarness.create(oauth: oauth);
        addTearDown(h.dispose);
        // A refresh before capture is safe; a readback refresh after acceptance
        // is safe. Refreshes while holding opening evidence are refusal paths.
        if (oauth) h.server.challengeReadAt = 1;
        final proposal = (await h.propose())!;
        if (oauth) h.server.challengeReadAt = 10;
        final result = await h.approve(proposal);
        expect(result.state, AiJournalState.succeeded);
        expect(result.readbackConfirmed, isTrue);
        expect(h.server.logicalReads, 10);
        expect(h.server.readAttempts, oauth ? 12 : 10);
        expect(h.server.mutations, 1);
        expect(h.server.adapter.requests, hasLength(oauth ? 13 : 11));
        expect(h.server.refreshes, oauth ? 2 : 0);
        expect(h.server.statusReads, 4);
        expect(
          h.server.events.where(
            (event) => event == 'GET /gitlab/api/v4/groups/84',
          ),
          hasLength(oauth ? 3 : 2),
        );
        expect(h.server.fixture.unhandled, isEmpty);
      },
    );
  }

  for (final challenged in [2, 3, 4, 5, 6, 7, 8, 9]) {
    test(
      'OAuth read $challenged replay refuses the captured epoch without a mutation',
      () async {
        final h = await _StatusHarness.create(oauth: true);
        addTearDown(h.dispose);
        h.server.challengeReadAt = challenged;
        final call = h.call();
        final proposal = await h.coordinator.propose(call);
        final result = proposal == null
            ? h.coordinator.outcomeFor(call.id)!
            : await h.approve(proposal);
        expect(result.state, AiJournalState.notExecuted);
        expect(result.reasonCode, switch (challenged) {
          9 => 'statusNotStarted',
          3 || 4 || 7 || 8 => 'preflightFailed',
          _ => 'workItemUnverifiable',
        });
        expect(h.server.mutations, 0);
        expect(h.server.refreshes, 1);
        expect(h.server.adapter.requests.length, lessThanOrEqualTo(21));
        expect(h.journal.isolated(_account, {_key}), isFalse);
      },
    );
  }

  test(
    'OAuth every read challenge fails closed without replaying a mutation',
    () async {
      final h = await _StatusHarness.create(oauth: true);
      addTearDown(h.dispose);
      h.server.challengeEveryRead = true;
      final call = h.call();
      expect(await h.coordinator.propose(call), isNull);
      expect(
        h.coordinator.outcomeFor(call.id)!.reasonCode,
        'workItemUnverifiable',
      );
      expect(h.server.logicalReads, 2);
      expect(h.server.readAttempts, 4);
      expect(h.server.refreshes, 2);
      expect(h.server.mutations, 0);
    },
  );

  test(
    'OAuth mutation 401 refreshes once without replay and stays uncertain',
    () async {
      final h = await _StatusHarness.create(oauth: true);
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      h.server.mutationStatus = 401;
      final result = await h.approve(proposal);
      expect(result.state, AiJournalState.writeUncertain);
      expect(h.server.mutations, 1);
      expect(h.server.refreshes, 1);
      expect(h.registry.settlements, [AiWorkItemWriteResult.uncertain]);
    },
  );

  for (final remaining in [20, 21]) {
    test(
      'cap ${remaining == 20 ? 'minus one refuses' : 'fits'} before freshness',
      () async {
        final h = await _StatusHarness.create(maxRequests: remaining);
        addTearDown(h.dispose);
        final call = h.call();
        final proposal = await h.coordinator.propose(call);
        if (remaining == 20) {
          expect(proposal, isNull);
          expect(
            h.coordinator.outcomeFor(call.id)!.reasonCode,
            'httpBudgetExceeded',
          );
          expect(h.server.adapter.requests, isEmpty);
        } else {
          expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
        }
      },
    );
  }

  for (final total in [39, 40, 41]) {
    test('shared 40-request reservation boundary $total', () async {
      final h = await _StatusHarness.create();
      addTearDown(h.dispose);
      expect(h.budget.reserve(requests: total - 21, search: false), isNull);
      final proposal = await h.propose();
      if (total <= 40) {
        expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
        expect(h.budget.gitLabRequests, total);
      } else {
        expect(proposal, isNull);
        expect(h.server.adapter.requests, isEmpty);
      }
    });
  }

  test('G-P3 row is visible with exact graph args, T2 and fixed cap 21', () {
    final row = productionAiLedger.find(_operation)!;
    expect(row.boundary, AiWriteBoundary.graph);
    expect(row.baseTier, AiWriteTier.t2);
    expect(row.scopeClass, AiScopeClass.groupWorkItem);
    expect(row.modelVisible, isTrue);
    expect(groupStatusStageOperations, {'updateGroupWorkItemStatus'});
    expect(
      aiGroupStatusRows.map((row) => row.operationId),
      unorderedEquals(groupStatusStageOperations),
    );
    expect(
      fixtureAiLedger.modelVisible.map((row) => row.operationId),
      contains(_operation),
    );
    expect(row.namedMethod, 'updateWorkItemStatus');
    expect(row.readback, isTrue);
    expect(
      row.arguments.keys,
      unorderedEquals(['groupId', 'iid', 'candidateId']),
    );
    expect(row.arguments.values.every((arg) => arg.required), isTrue);
    expect(row.arguments['groupId']!.type, AiArgType.integer);
    expect(row.arguments['iid']!.type, AiArgType.integer);
    expect(row.arguments['candidateId']!.type, AiArgType.string);
    expect(row.httpCap, 21);
    expect(aiWriteRequestAllowance(_operation), 21);
    expect(aiWriteRequestAllowance(_operation, oauthReplay: false), 11);
  });

  group('G-P3 production port and coordinator', () {
    late _StatusHarness h;
    setUp(() async => h = await _StatusHarness.create());
    tearDown(() => h.dispose());

    test(
      'valid candidate succeeds only after independent readback and durable dispatching',
      () async {
        final call = h.call();
        final proposal = await h.coordinator.propose(call);
        expect(
          proposal,
          isNotNull,
          reason:
              '${h.coordinator.outcomeFor(call.id)?.reasonCode}; ${h.server.events}',
        );
        final p = proposal!;
        expect(h.server.mutations, 0);
        expect(p.preview, isA<writes.AiFieldsPreview>());
        expect((p.preview as writes.AiFieldsPreview).fields, {
          'candidateId': _candidate,
        });
        h.server.onMutation = () async {
          expect(
            h.journal.entries(_account).last.state,
            AiJournalState.dispatching,
          );
          expect(
            WorkItemStatusWriteRegistry.instance.isActive(h.server.api, _gid),
            isTrue,
          );
          expect(h.registry.tryStart(_gid, AiWorkItemWriteKind.status), isNull);
        };
        final result = await h.approve(p);
        expect(result.state, AiJournalState.succeeded);
        expect(result.mutationCount, 1);
        expect(result.readbackConfirmed, isTrue);
        expect(h.server.mutations, 1);
        expect(
          h.server.statusReads,
          4,
        ); // proposal, dispatch, preflight, readback
        expect(h.server.events.last, 'MobileWorkItemStatus');
        expect(h.registry.settlements, [AiWorkItemWriteResult.confirmed]);
        expect(
          WorkItemStatusWriteRegistry.instance.isActive(h.server.api, _gid),
          isFalse,
        );
        final terminal = WorkItemStatusWriteRegistry.instance.terminal(
          h.server.api,
          _gid,
        )!;
        expect(terminal.confirmed, isTrue);
        expect(terminal.revision, h.server.fixture.item(group: true).updatedAt);
        expect(h.server.fixture.mutationInputs.single, {
          'id': _gid,
          'statusWidget': {'status': _candidate},
        });
      },
    );

    test(
      'noop has no START or graph hook, refunds writes and preserves marker',
      () async {
        await h.seedMark();
        final filesBefore = h.files.writeCount;
        final p = (await h.propose({
          ..._args,
          'candidateId': WorkItemStatusFixture.statusTodo,
        }))!;
        final result = await h.approve(p);
        expect(result.state, AiJournalState.succeeded);
        expect(result.noChange, isTrue);
        expect(result.mutationCount, 0);
        expect(h.server.mutations, 0);
        expect(h.files.writeCount - filesBefore, 2); // prepared and notExecuted
        expect(
          h.journal.entries(_account).last.state,
          AiJournalState.notExecuted,
        );
        expect(h.journal.conversationWriteCount(_account, _conversation), 0);
        expect(h.journal.requiresConfirmation(_account, {_key}), isTrue);
        expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
        h.budget = AiToolBudget();
        h.beginRun();
        expect(await h.propose(), isNotNull);
      },
    );

    test(
      'port refuses arbitrary candidate before creating a capability',
      () async {
        await expectLater(
          h.port.prepare(
            h.request({..._args, 'candidateId': 'gid://gitlab/WorkItem/999'}),
          ),
          throwsA(_refused('statusInvalidCandidate')),
        );
        expect(h.server.mutations, 0);
        expect(h.registry.starts, 0);
      },
    );

    test(
      'candidate drift at dispatch is refused with zero mutations',
      () async {
        final p = (await h.propose())!;
        h.server.fixture
            .item(group: true)
            .members!
            .removeWhere((member) => member.id == _candidate);
        final result = await h.approve(p);
        expect(result.state, AiJournalState.notExecuted);
        expect(result.reasonCode, 'statusInvalidCandidate');
        expect(result.mutationCount, 0);
        expect(h.server.mutations, 0);
        expect(h.registry.starts, 0);
      },
    );

    test('candidate drift in method preflight is a stale fence', () async {
      final p = (await h.propose())!;
      h.server.beforeStatusRead = (number) {
        if (number == 3) {
          h.server.fixture
              .item(group: true)
              .members!
              .removeWhere((member) => member.id == _candidate);
        }
      };
      final result = await h.approve(p);
      expect(result.state, AiJournalState.notExecuted);
      expect(result.reasonCode, 'statusStaleFence');
      expect(h.server.mutations, 0);
      expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
    });

    for (final fence in ['revision', 'lockVersion', 'state', 'permission']) {
      test('dispatch $fence drift invalidates approval', () async {
        final p = (await h.propose())!;
        final item = h.server.fixture.item(group: true);
        switch (fence) {
          case 'revision':
            item.updatedAt = item.updatedAt.add(const Duration(seconds: 1));
          case 'lockVersion':
            item.lockVersion++;
          case 'state':
            item.state = 'CLOSED';
          case 'permission':
            item.setWorkItemMetadata = false;
        }
        final result = await h.approve(p);
        expect(result.state, AiJournalState.notExecuted);
        expect(result.mutationCount, 0);
        expect(h.server.mutations, 0);
      });
    }

    test('detail/opening revision disagreement is statusStaleFence', () async {
      h.server.beforeStatusRead = (_) {
        final item = h.server.fixture.item(group: true);
        item.updatedAt = item.updatedAt.add(const Duration(seconds: 1));
      };
      await expectLater(
        h.port.prepare(h.request()),
        throwsA(_refused('statusStaleFence')),
      );
      expect(h.server.mutations, 0);
    });

    for (final fault in [
      'notApplied',
      'payloadErrors',
      '401',
      '503',
      'transport',
      'cancelled',
      'malformed',
      'mismatch',
      'readback401',
      'readback503',
      'readbackCancelled',
    ]) {
      test(
        'accepted $fault is uncertain and isolated without replay',
        () async {
          final p = (await h.propose())!;
          switch (fault) {
            case 'notApplied':
              h.server.notApplied = true;
            case 'payloadErrors':
              h.server.fixture.rejectNextMutation = ['synthetic rejection'];
            case '401':
              h.server.mutationStatus = 401;
            case '503':
              h.server.mutationStatus = 503;
            case 'transport':
              h.server.onMutation = () async =>
                  throw const SocketException('synthetic');
            case 'cancelled':
              h.server.onMutation = () async =>
                  throw const ApiFailure(FailureKind.cancelled);
            case 'malformed':
              h.server.malformedAck = true;
            case 'mismatch':
              h.server.mismatchReadback = true;
            case 'readback401':
              h.server.failReadAt = 4;
              h.server.readFailureStatus = 401;
            case 'readback503':
              h.server.failReadAt = 4;
            case 'readbackCancelled':
              h.server.beforeStatusRead = (number) {
                if (number == 4) throw const ApiFailure(FailureKind.cancelled);
              };
          }
          final result = await h.approve(p);
          expect(result.state, AiJournalState.writeUncertain);
          expect(result.mutationCount, 1);
          expect(result.readbackConfirmed, isFalse);
          expect(h.server.mutations, 1);
          expect(h.registry.settlements, [AiWorkItemWriteResult.uncertain]);
          expect(h.journal.isolated(_account, {_key}), isTrue);
          if (fault == 'notApplied' || fault == 'mismatch') {
            expect(h.server.statusReads, 4);
          }
          final before = h.server.adapter.requests.length;
          expect(await h.propose(), isNull);
          expect(h.server.adapter.requests, hasLength(before));
          h.budget = AiToolBudget();
          h.beginRun();
          expect(
            await h.propose({
              ..._args,
              'candidateId': WorkItemStatusFixture.statusDone,
            }),
            isNull,
          );
          expect(h.server.mutations, 1);
        },
      );
    }

    test(
      'method preflight HTTP failure never marks dispatching or isolates',
      () async {
        final p = (await h.propose())!;
        h.server.failReadAt = 3;
        final result = await h.approve(p);
        expect(result.state, AiJournalState.notExecuted);
        expect(result.mutationCount, 0);
        expect(h.server.mutations, 0);
        expect(
          h.journal.entries(_account).last.state,
          AiJournalState.notExecuted,
        );
        expect(h.journal.isolated(_account, {_key}), isFalse);
        expect(h.journal.conversationWriteCount(_account, _conversation), 0);
        expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
        expect(
          WorkItemStatusWriteRegistry.instance.isActive(h.server.api, _gid),
          isFalse,
        );
      },
    );

    test(
      'UI in-flight status refuses prepare and a post-prepare race refuses commit',
      () async {
        final ui = WorkItemStatusWriteRegistry.instance;
        final token = Object();
        expect(ui.tryStartExternal(h.server.api, _gid, token), isTrue);
        await expectLater(
          h.port.prepare(h.request()),
          throwsA(_refused('statusNotStarted')),
        );
        ui.settleExternal(
          h.server.api,
          _gid,
          token: token,
          mutationSent: false,
        );
        final prepared = await h.port.prepare(h.request());
        prepared.bindGraphBeforeMutation(
          () async => fail('occupied registry must not hook'),
        );
        expect(ui.tryStartExternal(h.server.api, _gid, token), isTrue);
        final result = await h.port.commit(prepared, mayStart: () => true);
        expect(result, isA<writes.AiWriteNotSent>());
        expect(h.server.mutations, 0);
        ui.settleExternal(
          h.server.api,
          _gid,
          token: token,
          mutationSent: false,
        );
      },
    );

    test('registry lease is visible throughout method preflight', () async {
      final p = (await h.propose())!;
      h.server.beforeStatusRead = (number) {
        if (number == 3) {
          expect(
            WorkItemStatusWriteRegistry.instance.isActive(h.server.api, _gid),
            isTrue,
          );
        }
      };
      expect((await h.approve(p)).state, AiJournalState.succeeded);
    });

    test(
      'mayStart false reverts dispatching and refunds the consumed marker',
      () async {
        await h.seedMark();
        final p = (await h.propose())!;
        final dispatched = h.files.armBarrier(
          writesBeforeBarrier: 1,
          afterPersist: true,
        );
        final pending = h.approve(p);
        await dispatched;
        final durable = await h.readDurableJournal();
        final entries = durable['entries']! as List<Object?>;
        expect((entries.last! as Map<String, Object?>)['state'], 'dispatching');
        expect(h.server.mutations, 0);
        h.policy.clientMayStart = false;
        h.files.releaseBarrier();
        final result = await pending;
        expect(result.state, AiJournalState.notExecuted);
        expect(result.mutationCount, 0);
        expect(h.server.mutations, 0);
        expect(h.journal.requiresConfirmation(_account, {_key}), isTrue);
        expect(h.journal.conversationWriteCount(_account, _conversation), 0);
        expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
        expect(
          WorkItemStatusWriteRegistry.instance.isActive(h.server.api, _gid),
          isFalse,
        );
      },
    );

    test(
      'double approval and single-use prepared capability send at most once',
      () async {
        final p = (await h.propose())!;
        final results = await Future.wait([h.approve(p), h.approve(p)]);
        expect(
          results.where((result) => result.state == AiJournalState.succeeded),
          isNotEmpty,
        );
        expect(h.server.mutations, 1);
        final prepared = await h.port.prepare(h.request());
        prepared.bindGraphBeforeMutation(() async {});
        await h.port.commit(prepared, mayStart: () => true);
        final count = h.server.mutations;
        expect(
          await h.port.commit(prepared, mayStart: () => true),
          isA<writes.AiWriteNotSent>(),
        );
        expect(h.server.mutations, count);
      },
    );

    for (final invalid in [
      'workItemGid',
      'expectedUpdatedAt',
      'confirmName',
      'query',
      'projectId',
    ]) {
      test(
        'unknown model argument $invalid is refused before network',
        () async {
          final before = h.server.adapter.requests.length;
          await expectLater(
            h.port.prepare(h.request({..._args, invalid: 'synthetic'})),
            throwsA(anyOf(isA<ApiFailure>(), isA<writes.AiWriteRefused>())),
          );
          expect(h.server.adapter.requests, hasLength(before));
        },
      );
    }

    for (final args in [
      {..._args, 'groupId': 0},
      {..._args, 'iid': -1},
      {..._args, 'groupId': 99},
      {..._args, 'iid': 18},
      {..._args, 'candidateId': ''},
      {..._args, 'candidateId': 1},
    ]) {
      test(
        'invalid/ungranted coordinates or candidate $args refuse without mutation',
        () async {
          await expectLater(
            h.port.prepare(h.request(args)),
            throwsA(anyOf(isA<ApiFailure>(), isA<writes.AiWriteRefused>())),
          );
          expect(h.server.adapter.requests.length, lessThanOrEqualTo(1));
        },
      );
    }

    test(
      'project and accountGlobal grants cannot authorize a group status write',
      () async {
        for (final grant in [
          const AiScopeGrant(
            kind: AiScopeKind.workItem,
            projectId: 84,
            projectPath: 'studio/group',
            iid: 17,
          ),
          const AiScopeGrant(kind: AiScopeKind.accountGlobal),
        ]) {
          h.scope = AiWriteScope(accountKey: _account, grants: [grant]);
          await expectLater(
            h.port.prepare(h.request()),
            throwsA(anyOf(isA<ApiFailure>(), isA<writes.AiWriteRefused>())),
          );
        }
        expect(h.server.mutations, 0);
        expect(h.server.statusReads, 0);
      },
    );

    test(
      'foreign actor and project descendant cannot create a capability',
      () async {
        h.server.fixture.actorUserId = 99;
        await expectLater(
          h.port.prepare(h.request()),
          throwsA(anyOf(isA<ApiFailure>(), isA<writes.AiWriteRefused>())),
        );
        h.server.fixture.actorUserId = 7;
        h.server.fixture.item(group: true).project = const GraphResourceRef(
          id: 'gid://gitlab/Project/99',
          fullPath: 'studio/mobile',
        );
        await expectLater(
          h.port.prepare(h.request()),
          throwsA(anyOf(isA<ApiFailure>(), isA<writes.AiWriteRefused>())),
        );
        expect(h.server.mutations, 0);
      },
    );

    test(
      'numeric group key is isolated from project keys and holds uncertainty',
      () async {
        final prepared = await h.port.prepare(h.request());
        expect(prepared.writeKeys, {_key});
        expect(prepared.bindingTargets.single.projectId, isNull);
        expect(prepared.bindingTargets.single.groupId, 84);
        expect(prepared.releaseName, 'studio/group#17');
        expect(
          prepared.writeKeys,
          isNot(
            contains(
              const AiConflictKey([_account, 'project:84', 'workItem', '17']),
            ),
          ),
        );
        expect(prepared.bindingTargets.single.iid, 17);
        await h.journal.prepare(
          draft: AiJournalDraft(
            executionId: 'rest-uncertain',
            accountKey: _account,
            conversationId: 'rest',
            runId: 'rest',
            operationId: _operation,
            writeKeys: {_key},
            payloadSha256: 'b' * 64,
            releaseName: 'studio/group#17',
          ),
        );
        await h.journal.markDispatching(executionId: 'rest-uncertain');
        await h.journal.finish(
          executionId: 'rest-uncertain',
          terminal: AiJournalState.writeUncertain,
        );
        expect(await h.propose(), isNull);
        expect(h.server.mutations, 0);
      },
    );

    for (final change in ['consent', 'generation', 'expiry', 'level']) {
      test('$change while awaiting approval prevents dispatch', () async {
        final p = (await h.propose())!;
        switch (change) {
          case 'consent':
            h.policy.consentValid = false;
          case 'generation':
            h.generation++;
          case 'expiry':
            h.clock = h.clock.add(const Duration(minutes: 31));
          case 'level':
            h.policy.level = AiAutonomyLevel.readOnly;
        }
        expect((await h.approve(p)).state, AiJournalState.notExecuted);
        expect(h.server.mutations, 0);
      });
    }

    test('29-minute approval remains valid', () async {
      final p = (await h.propose())!;
      h.clock = h.clock.add(const Duration(minutes: 29));
      expect((await h.approve(p)).state, AiJournalState.succeeded);
    });

    test(
      'mark flush failure never sends; terminal flush failure stays isolated',
      () async {
        final p = (await h.propose())!;
        h.files.failWriteNumber = h.files.writeCount + 2;
        final result = await h.approve(p);
        expect(result.reasonCode, 'journalUnavailable');
        expect(h.server.mutations, 0);
        expect(result.mutationCount, 0);
        expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
        expect(
          WorkItemStatusWriteRegistry.instance.isActive(h.server.api, _gid),
          isFalse,
        );
      },
    );

    test(
      'terminal flush failure never reports success or clears isolation',
      () async {
        final p = (await h.propose())!;
        h.files.failWriteNumber = h.files.writeCount + 3;
        final result = await h.approve(p);
        expect(result.reasonCode, 'journalUnavailable');
        expect(result.state, AiJournalState.writeUncertain);
        expect(h.server.mutations, 1);
        expect(h.journal.isolated(_account, {_key}), isTrue);
      },
    );

    for (final persisted in [false, true]) {
      for (final change in ['consent', 'generation', 'policy', 'stop']) {
        test(
          'blocked dispatch flush ($persisted) observes $change and refunds',
          () async {
            await h.seedMark();
            final p = (await h.propose())!;
            final entered = h.files.armBarrier(
              writesBeforeBarrier: 1,
              afterPersist: persisted,
            );
            final pending = h.approve(p);
            await entered;
            expect(h.server.mutations, 0);
            final durable = await h.readDurableJournal();
            final entries = durable['entries']! as List<Object?>;
            expect(
              (entries.last! as Map<String, Object?>)['state'],
              persisted ? 'dispatching' : 'prepared',
            );
            switch (change) {
              case 'consent':
                h.policy.consentValid = false;
              case 'generation':
                h.generation++;
              case 'policy':
                h.policy.level = AiAutonomyLevel.readOnly;
                h.policy.revision++;
              case 'stop':
                h.coordinator.stop('syntheticStop');
            }
            h.files.releaseBarrier();
            final result = await pending;
            expect(result.state, AiJournalState.notExecuted);
            expect(result.mutationCount, 0);
            expect(h.server.mutations, 0);
            expect(
              h.journal.entries(_account).last.state,
              AiJournalState.notExecuted,
            );
            expect(
              h.journal.conversationWriteCount(_account, _conversation),
              0,
            );
            expect(h.journal.requiresConfirmation(_account, {_key}), isTrue);
            expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
            expect(
              WorkItemStatusWriteRegistry.instance.isActive(h.server.api, _gid),
              isFalse,
            );
          },
        );
      }
    }

    test(
      'rollback flush failure preserves dispatch isolation without a send',
      () async {
        await h.seedMark();
        final p = (await h.propose())!;
        final entered = h.files.armBarrier(
          writesBeforeBarrier: 1,
          afterPersist: true,
        );
        final pending = h.approve(p);
        await entered;
        h.policy.clientMayStart = false;
        h.files.failWriteNumber = h.files.writeCount + 1;
        h.files.releaseBarrier();
        final result = await pending;
        expect(result.state, AiJournalState.writeUncertain);
        expect(result.reasonCode, 'journalUnavailable');
        expect(h.server.mutations, 0);
        expect(h.journal.isolated(_account, {_key}), isTrue);
        expect(
          h.journal.entries(_account).last.state,
          AiJournalState.dispatching,
        );
        expect(h.journal.conversationWriteCount(_account, _conversation), 1);
        expect(h.journal.requiresConfirmation(_account, {_key}), isFalse);
        expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
      },
    );

    test(
      'two conversations approving the same status dispatch at most once',
      () async {
        final first = (await h.propose())!;
        final second = h.newCoordinator('p3-other');
        addTearDown(() => second.stop('disposed'));
        second.beginRun('Set status of studio/group#17.');
        second.beginTurn();
        h.budget = AiToolBudget();
        final other = (await second.propose(h.call()))!;
        final outcomes = await Future.wait([
          h.approve(first),
          second.approve(other),
        ]);
        expect(h.server.mutations, 1);
        expect(
          outcomes.where(
            (outcome) => outcome.state == AiJournalState.succeeded,
          ),
          hasLength(1),
        );
        expect(h.registry.settlements, [AiWorkItemWriteResult.confirmed]);
        expect(
          h.journal
              .entries(_account)
              .where((entry) => entry.state == AiJournalState.succeeded),
          hasLength(1),
        );
      },
    );

    for (final identity in ['project', 'iid', 'namespace']) {
      test('returned $identity mismatch is refused by the locator', () async {
        final item = h.server.fixture.item(group: true);
        switch (identity) {
          case 'project':
            item.project = const GraphResourceRef(
              id: 'gid://gitlab/Project/42',
              fullPath: 'other/path',
            );
          case 'iid':
            item.iid = 18;
          case 'namespace':
            item.namespace = const GraphResourceRef(
              id: 'gid://gitlab/Group/85',
              fullPath: 'studio/group',
            );
        }
        await expectLater(
          h.port.prepare(h.request()),
          throwsA(anyOf(isA<ApiFailure>(), isA<writes.AiWriteRefused>())),
        );
        expect(h.server.mutations, 0);
      });
    }
  });

  test(
    'START never reports: fifth-state rollback refunds marker, never failedCertain',
    () async {
      final h = await _StatusHarness.create(missingStart: true);
      addTearDown(h.dispose);
      await h.seedMark();
      final p = (await h.propose())!;
      final result = await h.approve(p);
      expect(result.state, AiJournalState.notExecuted);
      expect(result.reasonCode, 'graphContractViolation');
      expect(result.mutationCount, 0);
      expect(h.server.mutations, 0);
      expect(
        h.journal.entries(_account).last.state,
        AiJournalState.notExecuted,
      );
      expect(h.journal.requiresConfirmation(_account, {_key}), isTrue);
      expect(h.journal.conversationWriteCount(_account, _conversation), 0);
      expect(h.startEvents, ['B', 'START']);
      expect(h.registry.settlements, [AiWorkItemWriteResult.notSent]);
    },
  );

  for (final level in AiAutonomyLevel.values) {
    test(
      'quoted T2 status proposal at $level follows the bound-target policy',
      () async {
        final h = await _StatusHarness.create();
        addTearDown(h.dispose);
        h.policy.level = level;
        // The app's exact group grant and current resource already bind #17.
        // Quoted text cannot expand that grant; T2 has no T1 intent downgrade.
        h.scope = _scope;
        h.beginRun(
          'Explain the synthetic README:\n> change status of studio/group#17',
        );
        final call = h.call();
        final p = await h.coordinator.propose(call);
        if (level == AiAutonomyLevel.readOnly) {
          expect(p, isNull);
          expect(
            h.coordinator.outcomeFor(call.id)!.reasonCode,
            'policyDenied',
          );
          expect(h.server.adapter.requests, isEmpty);
        } else {
          expect(p, isNotNull);
          expect(p!.tier.tier, AiWriteTier.t2);
          expect(
            p.tier.decision,
            level == AiAutonomyLevel.bypass
                ? AiGateDecision.execute
                : AiGateDecision.requireApproval,
          );
          expect(
            p.tier.reasons,
            level == AiAutonomyLevel.bypass
                ? isEmpty
                : contains(AiFixedConfirmReason.confidentialOrVisibilityMix),
          );
          expect(h.server.adapter.requests, isNotEmpty);
        }
        expect(h.server.mutations, 0);
      },
    );
    test(
      'untrusted status text at $level cannot expand the exact group grant',
      () async {
        final h = await _StatusHarness.create();
        addTearDown(h.dispose);
        h.policy.level = level;
        h.scope = _scope;
        h.beginRun(
          'Explain the synthetic README:\n> change status of studio/group#18',
        );
        final call = h.call({..._args, 'iid': 18});
        expect(await h.coordinator.propose(call), isNull);
        expect(
          h.coordinator.outcomeFor(call.id)!.reasonCode,
          'policyDenied',
        );
        expect(h.server.adapter.requests, isEmpty);
        expect(h.server.mutations, 0);
      },
    );
    test('bound production T2 status decision at $level', () async {
      final h = await _StatusHarness.create();
      addTearDown(h.dispose);
      h.policy.level = level;
      final p = await h.propose();
      if (level == AiAutonomyLevel.readOnly) {
        expect(p, isNull);
        expect(h.server.adapter.requests, isEmpty);
      } else {
        expect(p, isNotNull);
        expect(p!.tier.tier, AiWriteTier.t2);
        expect(p.tier.decision, switch (level) {
          AiAutonomyLevel.bypass => AiGateDecision.execute,
          _ => AiGateDecision.requireApproval,
        });
        expect((await h.approve(p)).state, AiJournalState.succeeded);
        expect(h.server.mutations, 1);
      }
    });
  }
}
