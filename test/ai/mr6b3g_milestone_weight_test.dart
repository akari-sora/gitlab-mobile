import 'release_policy_support.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_support.dart'
    show Mr6b3JournalFiles, Mr6b3JournalKeyStore, mr6b3Account;
import 'mr6b3g_support.dart' show g0eScope, g0ePath;
import '../support/namespace_work_item_query.dart';

const _milestone = 'updateGroupWorkItemMilestone';
const _weight = 'updateGroupWorkItemWeight';
const groupMilestoneWeightStageOperations = <String>{
  'updateGroupWorkItemMilestone',
  'updateGroupWorkItemWeight',
};
const _operations = [_milestone, _weight];
const _itemId = 'gid://gitlab/WorkItem/91';
const _project = {'id': 'gid://gitlab/Project/9', 'fullPath': 'team/example-9'};
const _namespace = {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath};
const _writeKey = AiConflictKey([mr6b3Account, 'group:7', 'workItem', '5']);

Map<String, Object?> _args(String op) => {
  'groupId': 7,
  'iid': 5,
  if (op == _milestone) 'milestoneTitle': 'November' else 'weight': 4,
};

port.AiWriteRequest _request(
  String op, {
  Map<String, Object?>? args,
  AiWriteScope scope = g0eScope,
  String? executionId,
}) => port.AiWriteRequest(
  operationId: op,
  executionId: executionId ?? 'p8-$op',
  scope: scope,
  arguments: args ?? _args(op),
);

Matcher _refused(String reason) => isA<port.AiWriteRefused>().having(
  (failure) => failure.reason,
  'reason',
  reason,
);

Map<String, Object?> _milestoneNode(int id, String title) => {
  'id': 'gid://gitlab/Milestone/$id',
  'iid': '$id',
  'title': title,
  'state': 'ACTIVE',
  'expired': false,
  'webPath': '/groups/team/sub/-/milestones/$id',
  'dueDate': '2026-11-30',
  'startDate': '2026-11-01',
  'project': null,
  'group': _namespace,
};

// All HTTP, including OAuth refresh, terminates at this synthetic adapter.
final class _Server {
  _Server(this.op, {this.oauth = false, bool withContext = true}) {
    adapter = FakeAdapter(_respond);
    final dio = Dio()..httpClientAdapter = adapter;
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    api = oauth
        ? GitLabApi(
            instance: instance,
            dio: dio,
            credential: const OAuthCredential(
              accessToken: 'synthetic-access',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-app',
            ),
            oauth: OAuthTokenClient(
              instance: instance,
              clientId: 'synthetic-app',
              dio: dio,
            ),
            onOAuthRotated: (_) async {},
          )
        : testApi(adapter);
    writer = port.GitLabAiWritePort(
      api,
      accountKey: mr6b3Account,
      sessionGeneration: withContext ? 7 : null,
      isCurrent: withContext ? () => live : null,
    );
  }

  final String op;
  final bool oauth;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writer;
  final catalog = [_milestoneNode(5, 'October'), _milestoneNode(6, 'November')];
  final reads = <String, int>{};
  final inputs = <Map<String, Object?>>[];
  String revision = '2026-10-23T00:00:00Z';
  String createdAt = '2026-10-01T00:00:00Z';
  String title = 'P8 synthetic item';
  String typeName = 'Task';
  int user = 7;
  int actor = 7;
  int? weight = 3;
  int rolledUp = 99;
  String? milestoneId = 'gid://gitlab/Milestone/5';
  bool permission = true;
  bool widgetPresent = true;
  bool hasNextPage = false;
  bool payloadErrors = false;
  bool invalidAck = false;
  bool readbackMismatch = false;
  int? mutationStatus;
  int readAttempts = 0;
  int readRetries = 0;
  bool live = true;
  String? challengeRead;
  int challengeOccurrence = 1;
  final attempts = <String, int>{};
  void Function(String operation, int count)? afterRead;
  final phaseChanges = <String, Map<String, Object?>>{};
  String? omitProjectPhase;
  int _openings = 0;
  String _phase = 'opening';
  bool _replayingRead = false;
  int mutations = 0;
  Map<String, Object?> detailChanges = {};
  Map<String, Object?> namespaceRef = _namespace;
  ResponseBody? Function(String operation, int count)? onRead;
  Future<void> Function()? onMutation;

  String get opening =>
      op == _milestone ? 'MobileWorkItemMilestone' : 'MobileWorkItemWeight';

  Map<String, Object?> _node({bool ack = false, bool detail = false}) {
    final mismatch = !ack && readbackMismatch && mutations > 0;
    final selectedId = mismatch ? 'gid://gitlab/Milestone/5' : milestoneId;
    final selected = catalog.where((node) => node['id'] == selectedId);
    final node = <String, Object?>{
      'id': _itemId,
      'iid': '5',
      'title': title,
      'state': 'OPEN',
      'createdAt': createdAt,
      'updatedAt': revision,
      'project': null,
      'namespace': namespaceRef,
      'workItemType': {
        'id': 'gid://gitlab/WorkItems::Type/9',
        'name': typeName,
      },
      'description': null,
      'userPermissions': {
        'readWorkItem': true,
        'adminWorkItem': permission,
        'setWorkItemMetadata': permission,
      },
      'widgets': [
        if (widgetPresent)
          if (op == _milestone)
            {
              'type': 'MILESTONE',
              'milestone': selected.isEmpty ? null : selected.single,
            }
          else
            {
              'type': 'WEIGHT',
              'weight': mismatch ? 3 : weight,
              'rolledUpWeight': rolledUp,
              'rolledUpCompletedWeight': 17,
            },
      ],
      ...?phaseChanges[detail
          ? 'namespace'
          : ack
          ? 'ack'
          : _phase],
      if (detail) ...detailChanges,
    };
    final phase = detail
        ? 'namespace'
        : ack
        ? 'ack'
        : _phase;
    if (omitProjectPhase == phase) node.remove('project');
    return node;
  }

  Future<ResponseBody> _respond(RequestOptions request) async {
    if (request.uri.path.endsWith('/oauth/token')) {
      return jsonResponse({
        'access_token': 'synthetic-access-$readAttempts',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
        'expires_in': 7200,
      });
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/projects/9/star')) {
      return jsonResponse(projectJson(9));
    }
    final data = request.data;
    final query = data is Map ? data['query'] as String? : null;
    final mutation = query?.startsWith('mutation ') ?? false;
    final operation = request.method == 'GET'
        ? request.uri.path.endsWith('/user')
              ? 'user'
              : 'freshness'
        : RegExp(r'^(?:query|mutation) (\w+)').firstMatch(query!)!.group(1)!;
    if (!mutation && oauth) {
      final attempt = attempts.update(
        operation,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      if (!_replayingRead &&
          (challengeRead == '*' ||
              (challengeRead == operation && attempt == challengeOccurrence))) {
        _replayingRead = true;
        readRetries++;
        return jsonResponse({}, status: 401);
      }
      _replayingRead = false;
    }
    if (mutation) {
      expect(request.uri, api.instance.graphQL);
      expect(
        query,
        startsWith(
          op == _milestone
              ? 'mutation MobileSetWorkItemMilestone('
              : 'mutation MobileSetWorkItemWeight(',
        ),
      );
      mutations++;
      final input = ((data as Map)['variables'] as Map)['input'] as Map;
      inputs.add(input.cast<String, Object?>());
      await onMutation?.call();
      if (mutationStatus != null) {
        return jsonResponse({}, status: mutationStatus!);
      }
      if (!payloadErrors) {
        if (op == _milestone) {
          milestoneId =
              (input['milestoneWidget'] as Map)['milestoneId'] as String?;
        } else {
          weight = (input['weightWidget'] as Map)['weight'] as int?;
        }
        revision = '2026-10-23T00:01:00Z';
      }
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': payloadErrors ? ['synthetic rejection'] : <String>[],
            'workItem': invalidAck ? null : _node(ack: true),
          },
        },
      });
    }
    expect(
      request.uri,
      request.method == 'GET'
          ? Uri.parse(
              operation == 'user'
                  ? 'https://example.com/gitlab/api/v4/user'
                  : 'https://example.com/gitlab/api/v4/groups/7?with_projects=false',
            )
          : api.instance.graphQL,
    );
    final count = reads.update(
      operation,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    final override = onRead?.call(operation, count);
    if (override != null) return override;
    afterRead?.call(operation, count);
    switch (operation) {
      case 'user':
        expect(request.uri.path, '/gitlab/api/v4/user');
        return jsonResponse({
          'id': user,
          'username': 'p8-user',
          'name': 'P8 User',
        });
      case 'freshness':
        expect(request.uri.path, '/gitlab/api/v4/groups/7');
        expect(request.uri.queryParameters, {'with_projects': 'false'});
        return jsonResponse({
          'id': 7,
          'full_path': g0ePath,
          'visibility': 'private',
        });
      case 'MobileNamespaceWorkItem':
        expect((data as Map)['query'], namespaceWorkItemQuery);
        expect(data['variables'], {'path': g0ePath, 'iid': '5'});
        return jsonResponse({
          'data': {
            'namespace': {..._namespace, 'workItem': _node(detail: true)},
          },
        });
      case 'MobileWorkItemWeight':
      case 'MobileWorkItemMilestone':
        _phase = mutations > 0
            ? 'readback'
            : (reads['MobileNamespaceWorkItem'] ?? 0) > _openings
            ? 'opening'
            : 'preflight';
        if (_phase == 'opening') _openings++;
        expect((data as Map)['variables'], {'id': _itemId});
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/$actor'},
            'workItem': _node(),
          },
        });
      case 'MobileGroupWorkItemMilestones':
        expect((data as Map)['variables'] is Map, isTrue);
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/$actor'},
            'group': {
              ..._namespace,
              'milestones': {
                // Return the server's filtered page verbatim. The port must
                // still prove an exact, unique name, regardless of search.
                'nodes': catalog,
                'pageInfo': {
                  'hasNextPage': hasNextPage,
                  'endCursor': hasNextPage ? 'next-page' : null,
                },
              },
            },
          },
        });
      default:
        throw StateError('Unexpected synthetic endpoint: $operation');
    }
  }

  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) {
    prepared.bindGraphBeforeMutation(beforeMutation ?? () async {});
    return writer.commit(prepared, mayStart: mayStart ?? () => true);
  }

  int get resourceRequests => adapter.requests
      .where((request) => !request.uri.path.endsWith('/oauth/token'))
      .length;
}

// Isolate the milestone and weight aliases in this test ledger.
final class _P8Ledger implements AiCapabilityLedger {
  const _P8Ledger();

  @override
  AiCapability? find(String operationId) {
    if (!_operations.contains(operationId)) return null;
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
  List<AiCapability> get modelVisible => [
    for (final op in _operations) find(op)!,
  ];
}

final class _Harness {
  _Harness(this.server);

  final _Server server;
  late final Directory root;
  late final Mr6b3JournalFiles files;
  late final Mr6b3JournalKeyStore keys;
  late final AiWriteJournal journal;
  late final PolicyAiWriteCoordinator coordinator;
  late AiToolBudget budget;
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  AiWriteScope scope = g0eScope;
  bool consentValid = true;
  bool alive = true;
  bool clientMayStart = true;
  int generation = 7;
  int policyRevision = 1;
  int scopeRevision = 1;
  int callId = 0;

  static Future<_Harness> create(String op, {int requests = 40}) async {
    final h = _Harness(_Server(op));
    h.root = Directory.systemTemp.createTempSync('p8-journal-');
    h.files = Mr6b3JournalFiles(h.root);
    h.keys = Mr6b3JournalKeyStore();
    h.journal = AiWriteJournal(
      keys: h.keys,
      applicationSupport: h.root,
      files: h.files,
      processId: 'p8-family',
    );
    await h.journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await h.journal.ensureInitialized(mr6b3Account);
    h.budget = AiToolBudget(maxGitLabRequests: requests);
    h.coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        appInForeground: true,
        scope: h.scope,
        level: h.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p8-consent',
        writePolicyRevision: h.policyRevision,
        scopeRevision: h.scopeRevision,
        sessionGeneration: h.generation,
        alive: h.alive,
        consentValid: h.consentValid,
        clientMayStart: h.clientMayStart,
        ownerApi: h.server.api,
        currentResource: AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: 7,
          groupFullPath: g0ePath,
          iid: 5,
        ),
      ),
      createPort: () => h.server.writer,
      journal: h.journal,
      conversationId: 'p8-conversation',
      budget: () => h.budget,
      readFreshness: (_) async {
        await h.server.api.group(7);
        return const AiWriteFreshness(
          targetVisibility: 'private',
          visibilityUnreadable: true,
          updatedAt: 'p8-stable-freshness',
        );
      },
      placeholders: text.UploadPlaceholderTable(
        instance: h.server.api.instance,
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const _P8Ledger(),
      now: () => h.clock,
    );
    h.beginRun();
    addTearDown(h.dispose);
    return h;
  }

  void beginRun([String utterance = 'Update this group work item.']) {
    coordinator.beginRun(utterance);
    coordinator.beginTurn();
  }

  Future<AiWriteProposal?> propose({Map<String, Object?>? args}) =>
      coordinator.propose(
        AiToolCall(
          id: 'p8-call-${callId++}',
          name: server.op,
          arguments: {
            ...(args ?? _args(server.op)),
            'reason': 'synthetic P8 request',
          },
        ),
      );

  Future<AiWriteOutcome> approve(AiWriteProposal proposal) =>
      coordinator.approve(proposal);

  Future<Map<String, Object?>> durable() => AiHistoryCipher.decryptJson(
    File(files.pathFor(mr6b3Account)).readAsBytesSync(),
    keys.keys[mr6b3Account]!,
    mr6b3Account,
    AiJournalFiles.fileName,
  );

  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    server.api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  setUp(() {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  });

  test(
    'fixed complete alias set, visible T2 graph rows, schemas and static caps',
    () {
      expect(groupMilestoneWeightStageOperations, {_milestone, _weight});
      for (final op in _operations) {
        final row = productionAiLedger.find(op)!;
        expect(row.namedMethod, op.replaceFirst('Group', ''));
        expect(row.baseTier, AiWriteTier.t2);
        expect(row.scopeClass, AiScopeClass.groupWorkItem);
        expect(row.boundary, AiWriteBoundary.graph);
        expect(row.modelVisible, isTrue);
        expect(row.readback, isTrue);
        expect(
          fixtureAiLedger.modelVisible.map((r) => r.operationId),
          contains(op),
        );
        expect(
          row.arguments.keys,
          unorderedEquals([
            'groupId',
            'iid',
            if (op == _milestone) ...[
              'milestoneTitle',
              'clearMilestone',
            ] else ...[
              'weight',
              'clearWeight',
            ],
          ]),
        );
        expect(row.arguments['groupId']!.required, isTrue);
        expect(row.arguments['iid']!.required, isTrue);
        expect(row.httpCap, op == _milestone ? 25 : 21);
        expect(aiWriteRequestAllowance(op), op == _milestone ? 25 : 21);
        expect(
          aiWriteRequestAllowance(op, oauthReplay: false),
          op == _milestone ? 13 : 11,
        );
      }
      expect(aiGroupWorkItemWritesEnabled, isTrue);
    },
  );

  for (final op in _operations) {
    final prefix = op == _milestone ? 'milestone' : 'weight';
    final valueKey = op == _milestone ? 'milestoneTitle' : 'weight';
    final clearKey = op == _milestone ? 'clearMilestone' : 'clearWeight';
    final field = op == _milestone ? 'milestone_id' : 'weight';
    final desired = op == _milestone ? 'gid://gitlab/Milestone/6' : 4;

    test(
      '$op real prepare binds numeric group identity and verifies one pure widget mutation',
      () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        final prepared = await s.writer.prepare(_request(op));
        expect(prepared.groupIdentity!.apiOwner, same(s.api));
        expect(prepared.groupIdentity!.generation, 7);
        expect(prepared.hasCurrentGroupIdentity, isTrue);
        expect(prepared.writeKeys, {_writeKey});
        expect(prepared.dependencyKeys, isEmpty);
        expect(prepared.releaseName, '$g0ePath#5');
        expect(prepared.projectPath, isNull);
        final target = prepared.bindingTargets.single;
        expect(target.kind, AiTargetKind.groupWorkItem);
        expect(target.side, AiResourceSide.group);
        expect(target.groupId, 7);
        expect(target.groupFullPath, g0ePath);
        expect(target.workItemGid, _itemId);
        expect(target.iid, 5);
        expect(target.projectId, isNull);
        expect(prepared.bindingDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
        expect((prepared.preview as port.AiFieldsPreview).fields, {
          field: desired,
          if (op == _milestone) 'title': 'November',
        });
        var hooks = 0;
        final result =
            await s.commit(
                  prepared,
                  beforeMutation: () async {
                    hooks++;
                  },
                )
                as port.AiWriteSettled;
        expect(result.state, AiJournalState.succeeded);
        expect(result.readbackVerified, isTrue);
        expect(result.mutationCount, 1);
        expect(result.projection, {field: desired});
        expect(hooks, 1);
        expect(s.reads[s.opening], 3);
        expect(s.mutations, 1);
        expect(s.inputs.single, {
          'id': _itemId,
          if (op == _milestone)
            'milestoneWidget': {'milestoneId': desired}
          else
            'weightWidget': {'weight': desired},
        });
        expect(
          await s.writer.commit(prepared, mayStart: () => true),
          isA<port.AiWriteNotSent>(),
        );
        expect(s.mutations, 1);
      },
    );

    test(
      '$op clear stays explicit and never reads milestone candidates',
      () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        s.onRead = (name, _) => name == 'MobileGroupWorkItemMilestones'
            ? jsonResponse({}, status: 500)
            : null;
        final prepared = await s.writer.prepare(
          _request(op, args: {'groupId': 7, 'iid': 5, clearKey: true}),
        );
        final result = await s.commit(prepared) as port.AiWriteSettled;
        expect(result.state, AiJournalState.succeeded);
        expect(result.projection, {field: null});
        expect(s.inputs.single, {
          'id': _itemId,
          if (op == _milestone)
            'milestoneWidget': {'milestoneId': null}
          else
            'weightWidget': {'weight': null},
        });
        expect(s.reads['MobileGroupWorkItemMilestones'], isNull);
      },
    );

    for (final optional in <Map<String, Object?>>[
      {},
      {clearKey: false},
      {clearKey: null},
      {clearKey: 'true'},
      {valueKey: null},
      {valueKey: op == _milestone ? 'November' : 4, clearKey: true},
      {valueKey: op == _milestone ? 'November' : 4, clearKey: false},
    ]) {
      test('$op invalid set/clear $optional refuses before HTTP', () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        await expectLater(
          s.writer.prepare(
            _request(op, args: {'groupId': 7, 'iid': 5, ...optional}),
          ),
          throwsA(_refused('${prefix}Rejected')),
        );
        expect(s.adapter.requests, isEmpty);
      });
    }

    for (final extra in [
      'projectId',
      'query',
      'variables',
      'url',
      'workItemGid',
      'expectedUpdatedAt',
      'rolledUpWeight',
      'generation',
    ]) {
      test('$op undeclared $extra refuses before HTTP', () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        await expectLater(
          s.writer.prepare(
            _request(op, args: {..._args(op), extra: 'injected'}),
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(s.adapter.requests, isEmpty);
      });
    }

    test(
      '$op missing or revoked trusted context refuses before HTTP',
      () async {
        for (final withContext in [false, true]) {
          final s = _Server(op, withContext: withContext)..live = false;
          addTearDown(s.api.close);
          await expectLater(
            s.writer.prepare(_request(op)),
            throwsA(_refused('workItemUnverifiable')),
          );
          expect(s.adapter.requests, isEmpty);
        }
      },
    );

    for (final grant in [
      const AiScopeGrant(kind: AiScopeKind.accountGlobal),
      const AiScopeGrant(
        kind: AiScopeKind.project,
        projectId: 7,
        projectPath: g0ePath,
      ),
      const AiScopeGrant(
        kind: AiScopeKind.groupWorkItem,
        groupId: 8,
        groupFullPath: g0ePath,
        iid: 5,
      ),
      const AiScopeGrant(
        kind: AiScopeKind.groupWorkItem,
        groupId: 7,
        groupFullPath: g0ePath,
        iid: 6,
      ),
    ]) {
      test(
        '$op exact group grant refuses ${grant.kind}/${grant.groupId}/${grant.iid}',
        () async {
          final s = _Server(op);
          addTearDown(s.api.close);
          await expectLater(
            s.writer.prepare(
              _request(
                op,
                scope: AiWriteScope(accountKey: mr6b3Account, grants: [grant]),
              ),
            ),
            throwsA(_refused('workItemUnverifiable')),
          );
          expect(s.reads, {'user': 1});
          expect(s.mutations, 0);
        },
      );
    }

    for (final phase in [
      'namespace',
      'opening',
      'preflight',
      'ack',
      'readback',
    ]) {
      for (final fault in [
        'missingProject',
        'project',
        'foreignGroup',
        'path',
        'iid',
        'gid',
      ]) {
        test(
          '$op strict owner $phase $fault ${phase == 'ack' || phase == 'readback' ? 'is uncertain' : 'refuses'}',
          () async {
            final s = _Server(op);
            addTearDown(s.api.close);
            if (fault == 'missingProject') {
              s.omitProjectPhase = phase;
            } else {
              s.phaseChanges[phase] = switch (fault) {
                'project' => {'project': _project},
                'foreignGroup' => {
                  'namespace': {
                    'id': 'gid://gitlab/Group/8',
                    'fullPath': g0ePath,
                  },
                },
                'path' => {
                  'namespace': {
                    'id': 'gid://gitlab/Group/7',
                    'fullPath': 'team/other',
                  },
                },
                'iid' => {'iid': '6'},
                _ => {'id': 'gid://gitlab/Issue/91'},
              };
            }
            if (phase == 'namespace' || phase == 'opening') {
              await expectLater(
                s.writer.prepare(_request(op)),
                throwsA(isA<port.AiWriteRefused>()),
              );
              expect(s.mutations, 0);
            } else {
              final result = await s.commit(
                await s.writer.prepare(_request(op)),
              );
              if (phase == 'preflight') {
                expect(result, isA<port.AiWriteNotSent>());
                expect(s.mutations, 0);
              } else {
                final settled = result as port.AiWriteSettled;
                expect(settled.state, AiJournalState.writeUncertain);
                expect(settled.readbackVerified, isFalse);
                expect(settled.projection, isEmpty);
                expect(s.mutations, 1);
              }
            }
          },
        );
      }
    }

    for (final fault in ['permission', 'widget', 'actor', 'revision']) {
      test('$op opening $fault refuses', () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        s.permission = fault != 'permission';
        s.widgetPresent = fault != 'widget';
        if (fault == 'actor') s.actor = 8;
        if (fault == 'revision') {
          s.onRead = (name, _) {
            if (name == s.opening) s.revision = '2026-10-23T00:00:02Z';
            return null;
          };
        }
        await expectLater(
          s.writer.prepare(_request(op)),
          throwsA(isA<port.AiWriteRefused>()),
        );
        expect(s.mutations, 0);
      });
    }

    for (final fault in ['permission', 'actor', 'revision', 'value', '500']) {
      test('$op preflight $fault never hooks or sends', () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        final prepared = await s.writer.prepare(_request(op));
        switch (fault) {
          case 'permission':
            s.permission = false;
          case 'actor':
            s.actor = 8;
          case 'revision':
            s.revision = '2026-10-23T00:00:02Z';
          case 'value':
            if (op == _milestone) {
              s.milestoneId = null;
            } else {
              s.weight = 2;
            }
          case '500':
            s.onRead = (name, _) =>
                name == s.opening ? jsonResponse({}, status: 500) : null;
        }
        var hooks = 0;
        expect(
          await s.commit(
            prepared,
            beforeMutation: () async {
              hooks++;
            },
          ),
          isA<port.AiWriteNotSent>(),
        );
        expect(hooks, 0);
        expect(s.mutations, 0);
      });
    }

    for (final fault in [
      'errors',
      '401',
      '500',
      'invalidAck',
      'readbackValue',
      'readback401',
      'readback500',
      'readbackActor',
      'session',
    ]) {
      test('$op accepted $fault is uncertain and never replayed', () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        s.payloadErrors = fault == 'errors';
        s.mutationStatus = int.tryParse(fault);
        s.invalidAck = fault == 'invalidAck';
        s.readbackMismatch = fault == 'readbackValue';
        if (fault == 'session') {
          s.onMutation = () async {
            s.live = false;
          };
        }
        s.onRead = (name, _) {
          if (name == s.opening && s.mutations > 0) {
            if (fault == 'readback401') return jsonResponse({}, status: 401);
            if (fault == 'readback500') return jsonResponse({}, status: 500);
            if (fault == 'readbackActor') s.actor = 8;
          }
          return null;
        };
        final prepared = await s.writer.prepare(_request(op));
        final result = await s.commit(prepared) as port.AiWriteSettled;
        expect(result.state, AiJournalState.writeUncertain);
        expect(result.readbackVerified, isFalse);
        expect(result.projection, isEmpty);
        expect(s.mutations, 1);
        expect(
          await s.writer.commit(prepared, mayStart: () => true),
          isA<port.AiWriteNotSent>(),
        );
        expect(s.mutations, 1);
      });
    }

    test(
      '$op noop validates preflight without hooks, mutation or readback',
      () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        final prepared = await s.writer.prepare(
          _request(
            op,
            args: {
              'groupId': 7,
              'iid': 5,
              valueKey: op == _milestone ? 'October' : 3,
            },
          ),
        );
        expect(
          await s.commit(
            prepared,
            beforeMutation: () async {
              fail('noop hooked');
            },
            mayStart: () => throw StateError('noop START'),
          ),
          isA<port.AiGraphNoChange>(),
        );
        expect(s.reads[s.opening], 2);
        expect(s.mutations, 0);
      },
    );

    test(
      '$op false final gate and journal hook failure send nothing',
      () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        expect(
          await s.commit(
            await s.writer.prepare(_request(op)),
            mayStart: () => false,
          ),
          isA<port.AiWriteNotSent>(),
        );
        expect(s.mutations, 0);
        await expectLater(
          s.commit(
            await s.writer.prepare(_request(op, executionId: 'hook-failure')),
            beforeMutation: () async {
              throw StateError('flush');
            },
          ),
          throwsStateError,
        );
        expect(s.mutations, 0);
      },
    );

    for (final read in [
      'user',
      'MobileNamespaceWorkItem',
      op == _milestone ? 'MobileWorkItemMilestone' : 'MobileWorkItemWeight',
      if (op == _milestone) 'MobileGroupWorkItemMilestones',
    ]) {
      test('$op epoch revoked after $read refuses opening', () async {
        final s = _Server(op);
        addTearDown(s.api.close);
        s.afterRead = (name, _) {
          if (name == read) s.api.clearReadCache();
        };
        await expectLater(
          s.writer.prepare(_request(op)),
          throwsA(isA<port.AiWriteRefused>()),
        );
        expect(s.mutations, 0);
      });
    }

    for (final oauth in [false, true]) {
      test(
        '$op independent ${oauth ? 'OAuth' : 'PAT'} HTTP count includes both group rounds and readback',
        () async {
          final s = _Server(op, oauth: oauth);
          addTearDown(s.api.close);
          for (var round = 0; round < 2; round++) {
            await s.api.group(7);
            final prepared = await s.writer.prepare(_request(op));
            if (round == 1) {
              expect(
                (await s.commit(prepared) as port.AiWriteSettled).state,
                AiJournalState.succeeded,
              );
            }
          }
          expect(s.resourceRequests, op == _milestone ? 13 : 11);
          expect(s.reads, {
            'freshness': 2,
            'user': 2,
            'MobileNamespaceWorkItem': 2,
            s.opening: 4,
            if (op == _milestone) 'MobileGroupWorkItemMilestones': 2,
          });
          expect(s.mutations, 1);
          expect(s.readRetries, 0);
        },
      );
    }

    for (final read in [
      'user',
      'MobileNamespaceWorkItem',
      op == _milestone ? 'MobileWorkItemMilestone' : 'MobileWorkItemWeight',
      if (op == _milestone) 'MobileGroupWorkItemMilestones',
    ]) {
      test(
        '$op OAuth replay of $read refuses captured group epoch without mutations',
        () async {
          final s = _Server(op, oauth: true)..challengeRead = read;
          addTearDown(s.api.close);
          await expectLater(
            s.writer.prepare(_request(op)),
            throwsA(
              _refused(
                read == 'user' ? 'workItemUnverifiable' : '${prefix}Conflict',
              ),
            ),
          );
          expect(s.resourceRequests, switch (read) {
            'user' => 2,
            'MobileNamespaceWorkItem' => 3,
            'MobileGroupWorkItemMilestones' => 5,
            _ => 4,
          });
          expect(s.readRetries, 1);
          expect(
            s.adapter.requests.where(
              (r) => r.uri.path.endsWith('/oauth/token'),
            ),
            hasLength(1),
          );
          expect(s.mutations, 0);
        },
      );
    }

    test(
      '$op OAuth replay at preflight refuses, post-send replay permits strict readback',
      () async {
        for (final afterSend in [false, true]) {
          final s = _Server(op, oauth: true);
          addTearDown(s.api.close);
          final prepared = await s.writer.prepare(_request(op));
          s.challengeRead = s.opening;
          s.challengeOccurrence = afterSend ? 3 : 2;
          final result = await s.commit(prepared);
          if (afterSend) {
            expect(
              (result as port.AiWriteSettled).state,
              AiJournalState.succeeded,
            );
            expect(result.readbackVerified, isTrue);
            expect(s.mutations, 1);
          } else {
            expect(result, isA<port.AiWriteNotSent>());
            expect(
              (result as port.AiWriteNotSent).reasonCode,
              '${prefix}Conflict',
            );
            expect(s.mutations, 0);
          }
          expect(s.readRetries, 1);
        }
      },
    );

    test(
      '$op every-read OAuth replay keeps exact early refusal within static cap',
      () async {
        final s = _Server(op, oauth: true)..challengeRead = '*';
        addTearDown(s.api.close);
        await s.api.group(7);
        await expectLater(
          s.writer.prepare(_request(op)),
          throwsA(_refused('workItemUnverifiable')),
        );
        expect(s.resourceRequests, 4);
        expect(s.readRetries, 2);
        expect(s.mutations, 0);
        expect(s.resourceRequests, lessThan(op == _milestone ? 25 : 21));
      },
    );

    test(
      '$op real coordinator flushes dispatching before a single mutation',
      () async {
        final h = await _Harness.create(op);
        final proposal = (await h.propose())!;
        h.server.onMutation = () async {
          expect(
            h.journal.entries(mr6b3Account).single.state,
            AiJournalState.dispatching,
          );
          expect(
            ((await h.durable())['entries']! as List).single,
            containsPair('state', 'dispatching'),
          );
        };
        final outcomes = await Future.wait([
          h.approve(proposal),
          h.approve(proposal),
        ]);
        for (final result in outcomes) {
          expect(
            result.state,
            AiJournalState.succeeded,
            reason: result.reasonCode,
          );
          expect(result.readbackConfirmed, isTrue);
        }
        expect(h.server.resourceRequests, op == _milestone ? 13 : 11);
        expect(h.server.mutations, 1);
        expect(h.journal.entries(mr6b3Account).single.writeKeys, {_writeKey});
      },
    );

    test(
      '$op coordinator noop is durably notExecuted and refunds write hold',
      () async {
        final h = await _Harness.create(op);
        final result = await h.approve(
          (await h.propose(
            args: {
              'groupId': 7,
              'iid': 5,
              valueKey: op == _milestone ? 'October' : 3,
            },
          ))!,
        );
        expect(result.state, AiJournalState.succeeded);
        expect(result.noChange, isTrue);
        expect(
          h.journal.entries(mr6b3Account).single.state,
          AiJournalState.notExecuted,
        );
        expect(
          h.journal.conversationWriteCount(mr6b3Account, 'p8-conversation'),
          0,
        );
        expect(h.server.mutations, 0);
        h.budget = AiToolBudget(maxGitLabRequests: 40);
        h.beginRun();
        expect(await h.propose(), isNotNull);
      },
    );

    for (final fault in [
      'revision',
      'value',
      'type',
      'permission',
      if (op == _milestone) 'choices',
    ]) {
      test('$op dispatch reprepare detects changed $fault', () async {
        final h = await _Harness.create(op);
        final proposal = (await h.propose())!;
        switch (fault) {
          case 'revision':
            h.server.revision = '2026-10-23T00:00:02Z';
          case 'value':
            if (op == _milestone) {
              h.server.milestoneId = null;
            } else {
              h.server.weight = 2;
            }
          case 'type':
            h.server.typeName = 'Issue';
          case 'permission':
            h.server.permission = false;
          case 'choices':
            h.server.catalog[1] = _milestoneNode(8, 'November');
        }
        expect((await h.approve(proposal)).state, AiJournalState.notExecuted);
        expect(h.server.mutations, 0);
      });
    }

    for (final change in [
      'expired',
      'consent',
      'generation',
      'policy',
      'scope',
      'stopped',
      'epoch',
      'session',
    ]) {
      test('$op changed approval $change never sends', () async {
        final h = await _Harness.create(op);
        final proposal = (await h.propose())!;
        switch (change) {
          case 'expired':
            h.clock = proposal.expiresAt.add(const Duration(seconds: 1));
          case 'consent':
            h.consentValid = false;
          case 'generation':
            h.generation++;
          case 'policy':
            h.policyRevision++;
          case 'scope':
            h.scopeRevision++;
          case 'stopped':
            h.coordinator.stop();
          case 'epoch':
            h.server.api.clearReadCache();
          case 'session':
            h.server.live = false;
        }
        expect((await h.approve(proposal)).state, AiJournalState.notExecuted);
        expect(h.server.mutations, 0);
      });
    }

    for (final total in [39, 40, 41]) {
      test('$op independent 40-request boundary $total', () async {
        final h = await _Harness.create(op);
        final cap = op == _milestone ? 25 : 21;
        expect(h.budget.reserve(requests: total - cap, search: false), isNull);
        final proposal = await h.propose();
        if (total <= 40) {
          expect(proposal, isNotNull);
          expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
          expect(h.budget.gitLabRequests, total);
        } else {
          expect(proposal, isNull);
          expect(h.server.resourceRequests, 0);
        }
      });
    }

    for (final delta in [0, -1]) {
      test(
        '$op fixed cap${delta == -1 ? ' minus one' : ''} reservation precedes reads',
        () async {
          final h = await _Harness.create(
            op,
            requests: (op == _milestone ? 25 : 21) + delta,
          );
          final proposal = await h.propose();
          if (delta < 0) {
            expect(proposal, isNull);
            expect(
              h.coordinator.outcomeFor('p8-call-0')!.reasonCode,
              'httpBudgetExceeded',
            );
            expect(h.server.resourceRequests, 0);
          } else {
            expect(
              (await h.approve(proposal!)).state,
              AiJournalState.succeeded,
            );
          }
        },
      );
    }

    test(
      '$op uncertain journal remains isolated until exact group release name',
      () async {
        final h = await _Harness.create(op);
        h.server.payloadErrors = true;
        expect(
          (await h.approve((await h.propose())!)).state,
          AiJournalState.writeUncertain,
        );
        h.budget = AiToolBudget(maxGitLabRequests: 40);
        h.beginRun();
        expect(await h.propose(), isNull);
        expect(h.server.mutations, 1);
        final entry = h.journal.entries(mr6b3Account).single;
        await expectLater(
          h.journal.releaseByUser(
            executionId: entry.executionId,
            typedName: '#5',
          ),
          throwsA(isA<AiJournalException>()),
        );
        await h.journal.releaseByUser(
          executionId: entry.executionId,
          typedName: '$g0ePath#5',
        );
        expect(
          h.journal.requiresConfirmation(mr6b3Account, {_writeKey}),
          isTrue,
        );
      },
    );

    for (final change in [
      'consent',
      'generation',
      'policy',
      'stop',
      'session',
      'epoch',
    ]) {
      test(
        '$op $change during dispatching flush prevents mutation and refunds',
        () async {
          final h = await _Harness.create(op);
          final proposal = (await h.propose())!;
          final entered = h.files.armBarrier(
            writesBeforeBarrier: 1,
            afterPersist: true,
          );
          final approving = h.approve(proposal);
          await entered;
          switch (change) {
            case 'consent':
              h.consentValid = false;
            case 'generation':
              h.generation++;
            case 'policy':
              h.policyRevision++;
            case 'stop':
              h.coordinator.stop();
            case 'session':
              h.server.live = false;
            case 'epoch':
              h.server.api.clearReadCache();
          }
          h.files.releaseBarrier();
          expect((await approving).state, AiJournalState.notExecuted);
          expect(h.server.mutations, 0);
          expect(
            h.journal.conversationWriteCount(mr6b3Account, 'p8-conversation'),
            0,
          );
          expect(
            h.journal.entries(mr6b3Account).single.state,
            AiJournalState.notExecuted,
          );
        },
      );
    }

    test('$op journal flush failure sends zero mutations', () async {
      final h = await _Harness.create(op);
      final proposal = (await h.propose())!;
      h.files.failWriteNumber = h.files.writeCount + 2;
      expect((await h.approve(proposal)).state, AiJournalState.notExecuted);
      expect(h.server.mutations, 0);
    });
  }

  for (final value in [0, 2147483647]) {
    test(
      'weight own int32 $value stays distinct from null and rollups',
      () async {
        final s = _Server(_weight);
        addTearDown(s.api.close);
        final prepared = await s.writer.prepare(
          _request(_weight, args: {'groupId': 7, 'iid': 5, 'weight': value}),
        );
        s.rolledUp = 999;
        expect(
          (await s.commit(prepared) as port.AiWriteSettled).state,
          AiJournalState.succeeded,
        );
        expect(s.inputs.single, {
          'id': _itemId,
          'weightWidget': {'weight': value},
        });
      },
    );
  }
  for (final value in [-1, 2147483648, 0.0, '0', false]) {
    test(
      'weight invalid int32 $value (${value.runtimeType}) refuses before HTTP',
      () async {
        final s = _Server(_weight);
        addTearDown(s.api.close);
        await expectLater(
          s.writer.prepare(
            _request(_weight, args: {'groupId': 7, 'iid': 5, 'weight': value}),
          ),
          throwsA(_refused('weightRejected')),
        );
        expect(s.adapter.requests, isEmpty);
      },
    );
  }
  for (final title in ['', ' ', 'bad\u0000title']) {
    test(
      'milestone invalid title ${title.length} refuses before HTTP',
      () async {
        final s = _Server(_milestone);
        addTearDown(s.api.close);
        await expectLater(
          s.writer.prepare(
            _request(
              _milestone,
              args: {'groupId': 7, 'iid': 5, 'milestoneTitle': title},
            ),
          ),
          throwsA(_refused('milestoneRejected')),
        );
        expect(s.adapter.requests, isEmpty);
      },
    );
  }
  for (final ancestor in [false, true]) {
    test(
      'milestone ${ancestor ? 'ancestor' : 'direct group'} selection uses the fixed scoped connection',
      () async {
        final s = _Server(_milestone);
        addTearDown(s.api.close);
        if (ancestor) {
          s.catalog[1]['group'] = {
            'id': 'gid://gitlab/Group/2',
            'fullPath': 'team',
          };
        }
        final result =
            await s.commit(await s.writer.prepare(_request(_milestone)))
                as port.AiWriteSettled;
        expect(result.state, AiJournalState.succeeded);
        final choice = s.adapter.requests.singleWhere(
          (r) =>
              r.data is Map &&
              ((r.data as Map)['query'] as String).startsWith(
                'query MobileGroupWorkItemMilestones(',
              ),
        );
        expect((choice.data as Map)['query'], _groupCandidatesQuery);
        expect((choice.data as Map)['variables'], {
          'fullPath': g0ePath,
          'after': null,
          'search': 'November',
        });
      },
    );
  }
  for (final fault in [
    'partial',
    'duplicate',
    'missing',
    'nearMatch',
    'project',
    'tooMany',
    'duplicateId',
    'inactive',
  ]) {
    test(
      'milestone candidate $fault refuses without continuation or mutation',
      () async {
        final s = _Server(_milestone);
        addTearDown(s.api.close);
        switch (fault) {
          case 'partial':
            s.hasNextPage = true;
          case 'duplicate':
            s.catalog.add(_milestoneNode(8, 'November'));
          case 'missing':
            s.catalog.removeAt(1);
          case 'nearMatch':
            s.catalog[1]['title'] = 'November extra';
          case 'project':
            s.catalog[1]['project'] = _project;
            s.catalog[1]['group'] = null;
          case 'tooMany':
            s.catalog.addAll([
              for (var id = 10; id < 60; id++) _milestoneNode(id, 'Other $id'),
            ]);
          case 'duplicateId':
            s.catalog.add(_milestoneNode(6, 'Other'));
          case 'inactive':
            s.catalog[1]['state'] = 'CLOSED';
        }
        await expectLater(
          s.writer.prepare(_request(_milestone)),
          throwsA(_refused('milestoneRejected')),
        );
        expect(s.reads['MobileGroupWorkItemMilestones'], 1);
        expect(s.mutations, 0);
      },
    );
  }
  test(
    'milestone complete 50-item page and long literal title preserve uniqueness',
    () async {
      final s = _Server(_milestone);
      addTearDown(s.api.close);
      final title = List.filled(257, 'x').join();
      s.catalog[1]['title'] = title;
      s.catalog.addAll([
        for (var id = 10; id < 58; id++) _milestoneNode(id, 'Other $id'),
      ]);
      expect(
        (await s.commit(
              await s.writer.prepare(
                _request(
                  _milestone,
                  args: {'groupId': 7, 'iid': 5, 'milestoneTitle': title},
                ),
              ),
            ))
            as port.AiWriteSettled,
        isA<port.AiWriteSettled>().having(
          (r) => r.state,
          'state',
          AiJournalState.succeeded,
        ),
      );
      final choice = s.adapter.requests.singleWhere(
        (r) =>
            r.data is Map &&
            ((r.data as Map)['query'] as String).startsWith(
              'query MobileGroupWorkItemMilestones(',
            ),
      );
      expect((choice.data as Map)['variables'], {
        'fullPath': g0ePath,
        'after': null,
        'search': null,
      });
    },
  );
}

// Independent literal: no descendant/project connection, one page of 50.
// GitLab 18.11 source scopes this exact connection to self_and_ancestors.
const _groupCandidatesQuery = r'''
query MobileGroupWorkItemMilestones(
  $fullPath: ID!
  $after: String
  $search: String
) {
  currentUser { id }
  group(fullPath: $fullPath) {
    id
    fullPath
    milestones(
      first: 50
      after: $after
      state: active
      searchTitle: $search
      includeAncestors: true
      sort: EXPIRED_LAST_DUE_DATE_ASC
    ) {
      nodes {
        id iid title state expired dueDate startDate webPath
        project { id fullPath }
        group { id fullPath }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';
