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
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart';

const groupLabelsStageOperations = <String>{'updateGroupWorkItemLabels'};

const _op = 'updateGroupWorkItemLabels';
const _item = 'gid://gitlab/WorkItem/91';
int _execution = 0;
const _group = {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath};
Map<String, Object?> _args([List<String> labels = const ['next']]) => {
  'groupId': 7,
  'iid': 5,
  'labels': labels,
};
port.AiWriteRequest _request([List<String> labels = const ['next']]) =>
    port.AiWriteRequest(
      operationId: _op,
      executionId: 'labels-${_execution++}',
      scope: g0eScope,
      arguments: _args(labels),
    );
Matcher _refused(String code) =>
    isA<port.AiWriteRefused>().having((value) => value.reason, 'reason', code);
Map<String, Object?> _label(int id, String title) => {
  'id': 'gid://gitlab/GroupLabel/$id',
  'title': title,
  'color': '#000000',
  'textColor': '#ffffff',
};

final class _Server {
  _Server({this.oauth = false}) {
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
              clientId: 'synthetic-client',
            ),
            oauth: OAuthTokenClient(
              instance: instance,
              clientId: 'synthetic-client',
              dio: dio,
            ),
            onOAuthRotated: (_) async {},
          )
        : testApi(adapter);
    writer = port.GitLabAiWritePort(
      api,
      accountKey: g0eAccount,
      sessionGeneration: 7,
      isCurrent: () => live,
    );
  }
  final bool oauth;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writer;
  final catalog = [_label(1, 'old'), _label(2, 'next')];
  final currentOnly = <Map<String, Object?>>[];
  List<String> selected = ['gid://gitlab/GroupLabel/1'];
  final inputs = <Map<String, Object?>>[];
  final reads = <String, int>{};
  String revision = '2026-10-23T00:00:00Z';
  int actor = 7;
  bool permission = true;
  bool live = true;
  bool replayAllReads = false;
  bool replayReadback = false;
  bool widgetPresent = true;
  Object? scoped = true;
  int refreshRequests = 0;
  String candidateGroup = 'gid://gitlab/Group/7';
  String candidatePath = g0ePath;
  void Function(String operation, Map<String, Object?> node)? alterNode;
  void Function(String operation)? afterRead;
  int? labelReadStatus;
  bool labelReadTransportFailure = false;
  final payloadErrors = <String>[];
  bool partialCandidates = false;
  bool partialCurrent = false;
  bool mismatchReadback = false;
  int? mutationStatus;
  int mutations = 0;
  int replayedReads = 0;
  bool _replaying = false;
  Future<void> Function()? onMutation;

  Map<String, Object?> _node({bool detail = false}) => {
    'id': _item,
    'iid': '5',
    'title': 'Synthetic labels',
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': revision,
    'project': null,
    'namespace': _group,
    'workItemType': {
      'id': 'gid://gitlab/WorkItems::Type/9',
      'name': 'Task',
      'widgetDefinitions': [
        {'type': 'LABELS', 'allowsScopedLabels': scoped},
      ],
    },
    'description': null,
    'userPermissions': {
      'readWorkItem': true,
      'setWorkItemMetadata': permission,
    },
    'widgets': [
      if (!detail && widgetPresent)
        {
          'type': 'LABELS',
          'labels': {
            'nodes': [
              for (final id in selected)
                [
                  ...catalog,
                  ...currentOnly,
                ].firstWhere((node) => node['id'] == id),
            ],
            'pageInfo': {
              'hasNextPage': partialCurrent,
              'endCursor': partialCurrent ? 'next' : null,
            },
          },
        },
    ],
  };

  Future<ResponseBody> _respond(RequestOptions request) async {
    if (request.uri.path.endsWith('/oauth/token')) {
      refreshRequests++;
      return jsonResponse({
        'access_token': 'synthetic-rotated-$replayedReads',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
        'expires_in': 7200,
      });
    }
    final data = request.data;
    final query = data is Map ? data['query'] as String? : null;
    final mutation = query?.startsWith('mutation ') ?? false;
    if (!mutation &&
        oauth &&
        (replayAllReads || (replayReadback && mutations > 0))) {
      if (!_replaying) {
        _replaying = true;
        replayedReads++;
        return jsonResponse({}, status: 401);
      }
      _replaying = false;
    }
    if (mutation) {
      expect(query, startsWith('mutation MobileUpdateWorkItemLabels('));
      expect(
        query,
        contains(
          'id iid updatedAt project { id fullPath } namespace { id fullPath }',
        ),
      );
      mutations++;
      final input = ((data as Map)['variables'] as Map)['input'] as Map;
      inputs.add(input.cast<String, Object?>());
      await onMutation?.call();
      if (mutationStatus != null) {
        return jsonResponse({}, status: mutationStatus!);
      }
      if (!mismatchReadback) {
        final widget = input['labelsWidget'] as Map;
        final removed = (widget['removeLabelIds'] as List?) ?? [];
        final added = (widget['addLabelIds'] as List?) ?? [];
        selected = [
          ...selected.where((id) => !removed.contains(id)),
          ...added.cast<String>(),
        ];
      }
      revision = '2026-10-23T00:01:00Z';
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': payloadErrors,
            'workItem': _responseNode('ack'),
          },
        },
      });
    }
    final operation = request.method == 'GET'
        ? request.uri.path.endsWith('/user')
              ? 'user'
              : 'freshness'
        : RegExp(r'^query (\w+)').firstMatch(query!)!.group(1)!;
    reads.update(operation, (value) => value + 1, ifAbsent: () => 1);
    afterRead?.call(operation);
    switch (operation) {
      case 'user':
        return jsonResponse({
          'id': actor,
          'username': 'synthetic',
          'name': 'Synthetic',
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
        expect(query, namespaceWorkItemQuery);
        expect((data as Map)['variables'], {'path': g0ePath, 'iid': '5'});
        return jsonResponse({
          'data': {
            'namespace': {
              ..._group,
              'workItem': _responseNode(operation, detail: true),
            },
          },
        });
      case 'MobileWorkItemLabels':
        if (labelReadTransportFailure) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
            error: const SocketException('synthetic label read failure'),
          );
        }
        if (labelReadStatus != null) {
          return jsonResponse({}, status: labelReadStatus!);
        }
        expect((data as Map)['variables'], {'id': _item, 'after': null});
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/$actor'},
            'workItem': _responseNode(operation),
          },
        });
      case 'MobileGroupWorkItemLabelCandidates':
        expect(query, isNot(contains('search')));
        expect(query, contains('first: 100'));
        expect(query, contains('onlyGroupLabels: true'));
        expect(query, contains('includeAncestorGroups: false'));
        expect(query, contains('includeDescendantGroups: false'));
        expect(query, contains('archived: false'));
        expect((data as Map)['variables'], {'fullPath': g0ePath});
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/$actor'},
            'group': {
              'id': candidateGroup,
              'fullPath': candidatePath,
              'labels': {
                'nodes': catalog,
                'pageInfo': {
                  'hasNextPage': partialCandidates,
                  'endCursor': partialCandidates ? 'next' : null,
                },
              },
            },
          },
        });
      default:
        throw StateError('Unexpected request: $operation');
    }
  }

  Map<String, Object?> _responseNode(String operation, {bool detail = false}) {
    final node = _node(detail: detail);
    alterNode?.call(operation, node);
    return node;
  }

  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    Future<void> Function()? before,
    bool Function()? mayStart,
  }) {
    prepared.bindGraphBeforeMutation(before ?? () async {});
    return writer.commit(prepared, mayStart: mayStart ?? () => true);
  }

  int get resourceRequests => adapter.requests
      .where((request) => !request.uri.path.endsWith('/oauth/token'))
      .length;
}

final class _Harness {
  _Harness(this.server);
  final _Server server;
  late final Directory root;
  late final Mr6b3JournalFiles files;
  late final Mr6b3JournalKeyStore keys;
  late final AiWriteJournal journal;
  late final PolicyAiWriteCoordinator coordinator;
  late final AiToolBudget budget;
  bool alive = true;
  int calls = 0;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;

  static Future<_Harness> create({bool oauth = false}) async {
    final h = _Harness(_Server(oauth: oauth));
    h.root = Directory.systemTemp.createTempSync('mr6b3g-labels-');
    h.files = Mr6b3JournalFiles(h.root);
    h.keys = Mr6b3JournalKeyStore();
    h.journal = AiWriteJournal(
      keys: h.keys,
      applicationSupport: h.root,
      files: h.files,
      processId: 'labels-family',
    );
    await h.journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await h.journal.ensureInitialized(mr6b3Account);
    h.budget = AiToolBudget(maxGitLabRequests: 40);
    h.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        appInForeground: true,
        scope: g0eScope,
        level: h.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'labels-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        ownerApi: h.server.api,
        currentResource: AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: 7,
          groupFullPath: g0ePath,
          iid: 5,
        ),
        alive: h.alive,
        consentValid: true,
        clientMayStart: true,
      ),
      createPort: () => h.server.writer,
      journal: h.journal,
      conversationId: 'labels-conversation',
      budget: () => h.budget,
      readFreshness: (_) async {
        await h.server.api.record(
          ['groups', '7'],
          query: {'with_projects': 'false'},
        );
        return const AiWriteFreshness(visibilityUnreadable: false);
      },
      placeholders: text.UploadPlaceholderTable(
        instance: h.server.api.instance,
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const _VisibleLedger(),
    );
    h.coordinator.beginRun('Update labels on this group work item.');
    h.coordinator.beginTurn();
    addTearDown(h.dispose);
    return h;
  }

  Future<AiWriteProposal?> propose([List<String> labels = const ['next']]) =>
      coordinator.propose(
        AiToolCall(
          id: 'labels-call-${calls++}',
          name: _op,
          arguments: {..._args(labels), 'reason': 'synthetic labels update'},
        ),
      );
  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    server.api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _VisibleLedger implements AiCapabilityLedger {
  const _VisibleLedger();

  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || operationId != _op) return row;
    return AiCapability(
      operationId: row.operationId,
      namedMethod: row.namedMethod,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      boundary: row.boundary,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
    );
  }

  @override
  List<AiCapability> get modelVisible => [find(_op)!];
}

void main() {
  setUp(() {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  });
  test(
    'fixed alias row is hidden T2 group graph with bounded exact-title schema',
    () {
      final row = productionAiLedger.find(_op)!;
      expect(groupLabelsStageOperations, {_op});
      expect(
        aiGroupLabelsRows.map((row) => row.operationId).toSet(),
        groupLabelsStageOperations,
      );
      expect(row.modelVisible, isFalse);
      expect(row.scopeClass, AiScopeClass.groupWorkItem);
      expect(row.namedMethod, 'updateWorkItemLabels');
      expect(row.readback, isTrue);
      expect(aiGroupWorkItemWritesEnabled, isFalse);
      expect(
        productionAiLedger.modelVisible.any((row) => row.operationId == _op),
        isFalse,
      );
      expect(
        toolsForScope(g0eScope).any((row) => row.operationId == _op),
        isFalse,
      );
      expect(row.baseTier, AiWriteTier.t2);
      expect(row.boundary, AiWriteBoundary.graph);
      expect(row.httpCap, 25);
      expect(row.arguments.keys, unorderedEquals(['groupId', 'iid', 'labels']));
      expect(aiWriteRequestAllowance(_op), 25);
      expect(aiWriteRequestAllowance(_op, oauthReplay: false), 13);
    },
  );

  test(
    'complete search-free catalog registers selection and verifies mutation',
    () async {
      final s = _Server();
      addTearDown(s.api.close);
      final prepared = await s.writer.prepare(_request());
      expect(prepared.bindingTargets.single.kind, AiTargetKind.groupWorkItem);
      expect(prepared.bindingTargets.single.groupId, 7);
      expect(prepared.groupIdentity!.workItemGid, _item);
      expect(prepared.groupIdentity!.generation, 7);
      expect(prepared.hasCurrentGroupIdentity, isTrue);
      expect(prepared.currentFields, {'labels': '["old"]'});
      expect(prepared.releaseName, '$g0ePath#5');
      expect(prepared.writeKeys, {
        const AiConflictKey([g0eAccount, 'group:7', 'workItem', '5']),
      });
      expect(prepared.dependencyKeys, isEmpty);
      expect((prepared.preview as port.AiFieldsPreview).fields, {
        'labels': ['next'],
      });
      var hooks = 0;
      final outcome =
          await s.commit(
                prepared,
                before: () async {
                  hooks++;
                },
              )
              as port.AiWriteSettled;
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.readbackVerified, isTrue);
      expect(hooks, 1);
      expect(s.reads['MobileGroupWorkItemLabelCandidates'], 1);
      expect(s.reads['MobileWorkItemLabels'], 3);
      expect(s.inputs.single, {
        'id': _item,
        'labelsWidget': {
          'addLabelIds': ['gid://gitlab/GroupLabel/2'],
          'removeLabelIds': ['gid://gitlab/GroupLabel/1'],
        },
      });
    },
  );

  test('explicit empty selection clears labels', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final prepared = await s.writer.prepare(_request([]));
    expect(
      (await s.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(s.inputs.single['labelsWidget'], {
      'removeLabelIds': ['gid://gitlab/GroupLabel/1'],
    });
  });

  for (final fault in ['unknown', 'partial', 'ambiguous', 'currentAmbiguous']) {
    test('$fault candidates refuse before mutation', () async {
      final s = _Server();
      addTearDown(s.api.close);
      var labels = ['next'];
      if (fault == 'unknown') labels = ['unseen'];
      if (fault == 'partial') {
        s.catalog.addAll([for (var i = 3; i <= 21; i++) _label(i, 'label$i')]);
        s.partialCandidates = true;
      }
      if (fault == 'ambiguous') s.catalog.add(_label(3, 'next'));
      if (fault == 'currentAmbiguous') {
        s.currentOnly.add(s.catalog.removeAt(0));
        s.catalog.add(_label(3, 'old'));
        labels = ['old'];
      }
      await expectLater(
        s.writer.prepare(_request(labels)),
        throwsA(_refused(fault == 'partial' ? 'unsupported' : 'labelUnknown')),
      );
      expect(s.mutations, 0);
      expect(s.reads['MobileGroupWorkItemLabelCandidates'], 1);
    });
  }

  test(
    'current label absent from candidates can be kept while adding',
    () async {
      final s = _Server();
      addTearDown(s.api.close);
      s.currentOnly.add(s.catalog.removeAt(0));
      final prepared = await s.writer.prepare(_request(['old', 'next']));
      expect(
        (await s.commit(prepared) as port.AiWriteSettled).state,
        AiJournalState.succeeded,
      );
      expect(s.inputs.single['labelsWidget'], {
        'addLabelIds': ['gid://gitlab/GroupLabel/2'],
      });
      expect(s.selected, contains('gid://gitlab/GroupLabel/1'));
      expect(s.reads['MobileGroupWorkItemLabelCandidates'], 1);
    },
  );

  for (final count in [21, 100]) {
    test(
      'complete catalog of $count candidates succeeds in one read',
      () async {
        final s = _Server();
        addTearDown(s.api.close);
        s.catalog.addAll([
          for (var i = 3; i <= count; i++) _label(i, 'label$i'),
        ]);
        final prepared = await s.writer.prepare(_request(['label$count']));
        expect(
          (await s.commit(prepared) as port.AiWriteSettled).state,
          AiJournalState.succeeded,
        );
        expect(s.selected, ['gid://gitlab/GroupLabel/$count']);
        expect(s.reads['MobileGroupWorkItemLabelCandidates'], 1);
      },
    );
  }

  test('catalog over 100 candidates is refused before mutation', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([for (var i = 3; i <= 101; i++) _label(i, 'label$i')]);
    await expectLater(
      s.writer.prepare(_request()),
      throwsA(_refused('unsupported')),
    );
    expect(s.reads['MobileGroupWorkItemLabelCandidates'], 1);
    expect(s.mutations, 0);
  });

  test('clearing succeeds with 21 complete candidates in one read', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([for (var i = 3; i <= 21; i++) _label(i, 'label$i')]);
    final prepared = await s.writer.prepare(_request([]));
    expect(
      (await s.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(s.selected, isEmpty);
    expect(s.reads['MobileGroupWorkItemLabelCandidates'], 1);
  });

  for (final labels in [
    List.generate(11, (i) => 'label$i'),
    ['next', 'next'],
    [''],
    ['bad\u0000'],
  ]) {
    test(
      'invalid label proposal ${labels.length} refuses before HTTP',
      () async {
        final s = _Server();
        addTearDown(s.api.close);
        if (labels.length == 11) {
          s.catalog.addAll([
            for (var index = 0; index < labels.length; index++)
              _label(100 + index, labels[index]),
          ]);
        }
        await expectLater(
          s.writer.prepare(_request(labels)),
          throwsA(_refused('validation')),
        );
        expect(s.adapter.requests, isEmpty);
      },
    );
  }

  test('ten labels are allowed and resolve in one catalog read', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([for (var i = 3; i <= 10; i++) _label(i, 'label$i')]);
    final names = s.catalog.map((label) => label['title']! as String).toList();
    final prepared = await s.writer.prepare(_request(names));
    expect(
      (await s.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(s.selected, hasLength(10));
    expect(s.reads['MobileGroupWorkItemLabelCandidates'], 1);
  });

  test(
    'partial current-label page refuses without following continuation',
    () async {
      final s = _Server()..partialCurrent = true;
      addTearDown(s.api.close);
      await expectLater(
        s.writer.prepare(_request()),
        throwsA(_refused('unsupported')),
      );
      expect(s.reads['MobileWorkItemLabels'], 1);
      expect(s.reads['MobileGroupWorkItemLabelCandidates'], isNull);
    },
  );

  test('scoped labels cannot conflict within a proposal', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([_label(3, 'priority::one'), _label(4, 'priority::two')]);
    await expectLater(
      s.writer.prepare(_request(['priority::one', 'priority::two'])),
      throwsA(_refused('validation')),
    );
    expect(s.mutations, 0);
  });

  test('revision and catalog identity changes alter binding digest', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final first = await s.writer.prepare(_request());
    s.revision = '2026-10-23T00:00:01Z';
    final second = await s.writer.prepare(_request());
    expect(second.bindingDigest, isNot(first.bindingDigest));
    s.catalog[1] = _label(3, 'next');
    final third = await s.writer.prepare(_request());
    expect(third.bindingDigest, isNot(second.bindingDigest));
  });

  for (final fault in ['revision', 'permission', 'actor', 'value']) {
    test('preflight $fault refuses before hook', () async {
      final s = _Server();
      addTearDown(s.api.close);
      final prepared = await s.writer.prepare(_request());
      if (fault == 'revision') s.revision = '2026-10-23T00:00:01Z';
      if (fault == 'permission') s.permission = false;
      if (fault == 'actor') s.actor = 8;
      if (fault == 'value') s.selected = [];
      var hooks = 0;
      final outcome =
          await s.commit(
                prepared,
                before: () async {
                  hooks++;
                },
              )
              as port.AiWriteNotSent;
      expect(
        outcome.reasonCode,
        fault == 'permission'
            ? 'forbidden'
            : fault == 'actor'
            ? 'cancelled'
            : 'targetChanged',
      );
      expect(hooks, 0);
      expect(s.mutations, 0);
    });
  }

  test('noop does not invoke hooks', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final prepared = await s.writer.prepare(_request(['old']));
    expect(
      await s.commit(
        prepared,
        before: () async {
          fail('noop hook');
        },
      ),
      isA<port.AiGraphNoChange>(),
    );
    expect(s.mutations, 0);
  });

  test('failed final gate is not sent and hook failure propagates', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final prepared = await s.writer.prepare(_request());
    expect(
      await s.commit(prepared, mayStart: () => false),
      isA<port.AiWriteNotSent>(),
    );
    final second = await s.writer.prepare(_request());
    await expectLater(
      s.commit(
        second,
        before: () async {
          throw StateError('hook failed');
        },
      ),
      throwsStateError,
    );
    expect(s.mutations, 0);
  });

  for (final fault in ['401', '500', 'readback']) {
    test(
      'accepted $fault is uncertain and mutation is never replayed',
      () async {
        final s = _Server();
        addTearDown(s.api.close);
        s.mutationStatus = int.tryParse(fault);
        s.mismatchReadback = fault == 'readback';
        final prepared = await s.writer.prepare(_request());
        final outcome = await s.commit(prepared) as port.AiWriteSettled;
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(outcome.readbackVerified, isFalse);
        expect(s.mutations, 1);
      },
    );
  }

  for (final oauth in [false, true]) {
    test(
      'coordinator measured ${oauth ? 'OAuth' : 'PAT'} cap includes both preparation passes',
      () async {
        final h = await _Harness.create(oauth: oauth);
        final proposal = await h.propose();
        expect(
          proposal,
          isNotNull,
          reason: h.coordinator.outcomeFor('labels-call-0')?.reasonCode,
        );
        final outcome = await h.coordinator.approve(proposal!);
        expect(outcome.state, AiJournalState.succeeded);
        // F=1, P=4 each pass, then one preflight and readback: L=12.
        expect(h.server.resourceRequests, 13);
        expect(h.server.replayedReads, 0);
        expect(h.server.reads, {
          'freshness': 2,
          'user': 2,
          'MobileNamespaceWorkItem': 2,
          'MobileWorkItemLabels': 4,
          'MobileGroupWorkItemLabelCandidates': 2,
        });
        expect(h.server.resourceRequests, lessThanOrEqualTo(25));
        expect(h.server.mutations, 1);
      },
    );
  }

  test(
    'journal records prepared, dispatching and succeeded at the real boundary',
    () async {
      final h = await _Harness.create();
      final proposal = (await h.propose())!;
      // Proposal itself does not claim a durable write yet.
      h.server.onMutation = () async {
        expect(
          h.journal.entries(mr6b3Account).single.state,
          AiJournalState.dispatching,
        );
      };
      final entered = h.files.armBarrier(writesBeforeBarrier: 1);
      final approving = h.coordinator.approve(proposal);
      await entered;
      expect(
        h.journal.entries(mr6b3Account).single.state,
        AiJournalState.prepared,
      );
      expect(h.server.mutations, 0);
      h.files.releaseBarrier();
      final outcome = await approving;
      expect(outcome.state, AiJournalState.succeeded);
      expect(
        h.journal.entries(mr6b3Account).single.state,
        AiJournalState.succeeded,
      );
    },
  );

  test('coordinator noop ends notExecuted without dispatching', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose(['old']))!;
    final outcome = await h.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.noChange, isTrue);
    expect(
      h.journal.entries(mr6b3Account).single.state,
      AiJournalState.notExecuted,
    );
    expect(h.server.mutations, 0);
  });

  test(
    'coordinator catalog drift refuses target before journal dispatch',
    () async {
      final h = await _Harness.create();
      final proposal = (await h.propose())!;
      h.server.catalog[1] = _label(3, 'next');
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'targetChanged');
      expect(h.server.mutations, 0);
    },
  );

  test('journal settles accepted failure as writeUncertain', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.server.mutationStatus = 500;
    final outcome = await h.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.writeUncertain);
    expect(
      h.journal.entries(mr6b3Account).single.state,
      AiJournalState.writeUncertain,
    );
    expect(h.server.mutations, 1);
  });

  test('journal flush failure prevents mutation', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.files.failWriteNumber = h.files.writeCount + 2;
    final outcome = await h.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(h.server.mutations, 0);
  });

  for (final fault in ['missing', 'revoked', 'closed']) {
    test('trusted context $fault refuses before HTTP', () async {
      final s = _Server();
      addTearDown(s.api.close);
      final writer = fault == 'missing'
          ? port.GitLabAiWritePort(s.api, accountKey: g0eAccount)
          : s.writer;
      if (fault == 'revoked') s.live = false;
      if (fault == 'closed') s.api.close();
      await expectLater(
        writer.prepare(_request()),
        throwsA(_refused('workItemUnverifiable')),
      );
      expect(s.adapter.requests, isEmpty);
    });
  }

  for (final field in [
    'projectId',
    'fullPath',
    'workItemId',
    'generation',
    'confirmName',
  ]) {
    test('unlisted field $field refuses before HTTP', () async {
      final s = _Server();
      addTearDown(s.api.close);
      await expectLater(
        s.writer.prepare(
          port.AiWriteRequest(
            operationId: _op,
            executionId: 'extra-$field',
            scope: g0eScope,
            arguments: {..._args(), field: 7},
          ),
        ),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.validation,
          ),
        ),
      );
      expect(s.adapter.requests, isEmpty);
    });
  }

  for (final coordinates in [
    {'groupId': 8, 'iid': 5},
    {'groupId': 7, 'iid': 6},
  ]) {
    test('exact grant refuses foreign group or sibling $coordinates', () async {
      final s = _Server();
      addTearDown(s.api.close);
      await expectLater(
        s.writer.prepare(
          port.AiWriteRequest(
            operationId: _op,
            executionId: 'foreign-$coordinates',
            scope: g0eScope,
            arguments: {..._args(), ...coordinates},
          ),
        ),
        throwsA(_refused('workItemUnverifiable')),
      );
      expect(s.reads, {'user': 1});
      expect(s.mutations, 0);
    });
  }

  final ownerFaults = <String, void Function(Map<String, Object?>)>{
    'project omitted': (node) => node.remove('project'),
    'project descendant': (node) => node['project'] = {
      'id': 'gid://gitlab/Project/7',
      'fullPath': 'team/sub/project',
    },
    'namespace omitted': (node) => node.remove('namespace'),
    'foreign same-path group': (node) =>
        node['namespace'] = {..._group, 'id': 'gid://gitlab/Group/8'},
    'renamed owner': (node) =>
        node['namespace'] = {..._group, 'fullPath': 'team/renamed'},
    'ancestor owner': (node) =>
        node['namespace'] = {'id': 'gid://gitlab/Group/1', 'fullPath': 'team'},
    'wrong GID type': (node) => node['namespace'] = {..._group, 'id': _item},
    'wrong iid': (node) => node['iid'] = '6',
    'wrong item': (node) => node['id'] = 'gid://gitlab/WorkItem/92',
  };
  for (final phase in [
    'namespace',
    'opening',
    'preflight',
    'ack',
    'readback',
  ]) {
    for (final fault in ownerFaults.entries) {
      // A namespace locator discovers the GID. Only subsequent reads must
      // preserve that exact discovered alias.
      if (phase == 'namespace' && fault.key == 'wrong item') continue;
      test('strict $phase ${fault.key} cannot become success', () async {
        final s = _Server();
        addTearDown(s.api.close);
        s.alterNode = (operation, node) {
          final reads = s.reads['MobileWorkItemLabels'] ?? 0;
          final applies = switch (phase) {
            'namespace' => operation == 'MobileNamespaceWorkItem',
            'opening' => operation == 'MobileWorkItemLabels' && reads == 1,
            'preflight' => operation == 'MobileWorkItemLabels' && reads == 2,
            'ack' => operation == 'ack',
            'readback' => operation == 'MobileWorkItemLabels' && reads == 3,
            _ => false,
          };
          if (applies) fault.value(node);
        };
        if (phase == 'namespace' || phase == 'opening') {
          await expectLater(
            s.writer.prepare(_request()),
            throwsA(isA<port.AiWriteRefused>()),
          );
          expect(s.mutations, 0);
        } else {
          final prepared = await s.writer.prepare(_request());
          final result = await s.commit(prepared);
          if (phase == 'preflight') {
            expect(result, isA<port.AiWriteNotSent>());
            expect(s.mutations, 0);
          } else {
            expect(
              (result as port.AiWriteSettled).state,
              AiJournalState.writeUncertain,
            );
            expect(result.readbackVerified, isFalse);
            expect(s.mutations, 1);
          }
        }
      });
    }
  }

  for (final operation in [
    'user',
    'MobileNamespaceWorkItem',
    'MobileWorkItemLabels',
    'MobileGroupWorkItemLabelCandidates',
  ]) {
    for (final epoch in [false, true]) {
      test(
        '${epoch ? 'epoch' : 'session'} loss after $operation refuses opening',
        () async {
          final s = _Server();
          addTearDown(s.api.close);
          s.afterRead = (read) {
            if (read != operation) return;
            if (epoch) {
              s.api.clearReadCache();
            } else {
              s.live = false;
            }
          };
          await expectLater(
            s.writer.prepare(_request()),
            throwsA(isA<port.AiWriteRefused>()),
          );
          expect(s.mutations, 0);
        },
      );
    }
  }

  for (final fault in [
    'foreignGroup',
    'renamedGroup',
    'projectLabel',
    'genericLabel',
  ]) {
    test('fixed catalog $fault is refused including for clear', () async {
      final s = _Server();
      addTearDown(s.api.close);
      if (fault == 'foreignGroup') s.candidateGroup = 'gid://gitlab/Group/8';
      if (fault == 'renamedGroup') s.candidatePath = 'team/renamed';
      if (fault == 'projectLabel') {
        s.catalog[1]['id'] = 'gid://gitlab/ProjectLabel/2';
      }
      if (fault == 'genericLabel') s.catalog[1]['id'] = 'gid://gitlab/Label/2';
      await expectLater(
        s.writer.prepare(_request([])),
        throwsA(_refused('unsupported')),
      );
      expect(s.mutations, 0);
    });
  }

  test('scoped replacement sends the exact set delta', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([_label(3, 'priority::one'), _label(4, 'priority::two')]);
    s.selected = ['gid://gitlab/GroupLabel/3'];
    final prepared = await s.writer.prepare(_request(['priority::two']));
    expect(
      (await s.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(s.inputs.single['labelsWidget'], {
      'addLabelIds': ['gid://gitlab/GroupLabel/4'],
      'removeLabelIds': ['gid://gitlab/GroupLabel/3'],
    });
  });

  test(
    'nested scoped labels use the scope before the last separator',
    () async {
      final s = _Server();
      addTearDown(s.api.close);
      s.catalog.addAll([
        _label(3, 'workflow::backend::review'),
        _label(4, 'workflow::backend::development'),
      ]);
      await expectLater(
        s.writer.prepare(
          _request([
            'workflow::backend::review',
            'workflow::backend::development',
          ]),
        ),
        throwsA(_refused('validation')),
      );
      expect(s.mutations, 0);
    },
  );

  for (final fault in ['permission', 'widget', 'current']) {
    test('opening $fault refuses even when clearing', () async {
      final s = _Server();
      addTearDown(s.api.close);
      if (fault == 'permission') s.permission = false;
      if (fault == 'widget') s.widgetPresent = false;
      if (fault == 'current') s.partialCurrent = true;
      await expectLater(
        s.writer.prepare(_request([])),
        throwsA(isA<port.AiWriteRefused>()),
      );
      expect(s.mutations, 0);
    });
  }

  for (final fault in ['session', 'epoch']) {
    test('$fault loss during durable hook prevents START', () async {
      final s = _Server();
      addTearDown(s.api.close);
      final prepared = await s.writer.prepare(_request());
      final result = await s.commit(
        prepared,
        before: () async {
          if (fault == 'session') {
            s.live = false;
          } else {
            s.api.clearReadCache();
          }
        },
      );
      expect(result, isA<port.AiWriteNotSent>());
      expect(s.mutations, 0);
    });
  }

  test('accepted session loss stays uncertain', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final prepared = await s.writer.prepare(_request());
    s.onMutation = () async {
      s.live = false;
    };
    final result = await s.commit(prepared) as port.AiWriteSettled;
    expect(result.state, AiJournalState.writeUncertain);
    expect(s.mutations, 1);
  });

  test('accepted payload errors stay uncertain', () async {
    final s = _Server()..payloadErrors.add('synthetic rejected update');
    addTearDown(s.api.close);
    final result =
        await s.commit(await s.writer.prepare(_request()))
            as port.AiWriteSettled;
    expect(result.state, AiJournalState.writeUncertain);
    expect(s.mutations, 1);
  });

  for (final oauth in [false, true]) {
    test(
      'readback 401 is uncertain without mutation replay (oauth=$oauth)',
      () async {
        final s = _Server(oauth: oauth);
        addTearDown(s.api.close);
        final prepared = await s.writer.prepare(_request());
        s.onMutation = () async {
          s.labelReadStatus = 401;
        };
        final result = await s.commit(prepared) as port.AiWriteSettled;
        expect(result.state, AiJournalState.writeUncertain);
        expect(result.readbackVerified, isFalse);
        expect(s.mutations, 1);
      },
    );
  }

  test(
    'OAuth readback replay preserves accepted session and stays below cap',
    () async {
      final h = await _Harness.create(oauth: true);
      h.server.replayReadback = true;
      final result = await h.coordinator.approve((await h.propose())!);
      expect(result.state, AiJournalState.succeeded);
      expect(h.server.resourceRequests, 14);
      expect(h.server.refreshRequests, 1);
      expect(h.server.replayedReads, 1);
      expect(h.server.mutations, 1);
    },
  );

  test(
    'OAuth replay on every read refuses stale context before mutation',
    () async {
      final h = await _Harness.create(oauth: true);
      h.server.replayAllReads = true;
      final proposal = await h.propose();
      expect(proposal, isNull);
      expect(h.server.mutations, 0);
      expect(h.server.resourceRequests, 4);
      expect(h.server.refreshRequests, 2);
      expect(h.server.resourceRequests, lessThanOrEqualTo(25));
    },
  );

  for (final available in [24, 25]) {
    test('static allowance requires full 25 at budget $available', () async {
      final h = await _Harness.create();
      expect(
        h.budget.reserve(
          requests: 40 - available,
          search: false,
          countCall: false,
        ),
        isNull,
      );
      final proposal = await h.propose();
      expect(proposal != null, available == 25);
      expect(h.server.mutations, 0);
      if (available == 24) expect(h.server.adapter.requests, isEmpty);
    });
  }

  test('coordinator uncertain failure stops the rest of the turn', () async {
    final h = await _Harness.create();
    h.server.mismatchReadback = true;
    final result = await h.coordinator.approve((await h.propose())!);
    expect(result.state, AiJournalState.writeUncertain);
    final requests = h.server.resourceRequests;
    expect(await h.propose(), isNull);
    expect(h.server.resourceRequests, requests);
    expect(h.server.mutations, 1);
  });

  test('coordinator noop reaches the next HTTP budget gate', () async {
    final h = await _Harness.create();
    final first = await h.coordinator.approve((await h.propose(['old']))!);
    expect(first.noChange, isTrue);
    expect(await h.propose(), isNull);
    expect(
      h.coordinator.outcomeFor('labels-call-1')?.reasonCode,
      'httpBudgetExceeded',
    );
    expect(h.server.mutations, 0);
  });

  for (final scoped in [null, 'true', false]) {
    test(
      'scoped conflicts fail closed unless explicitly disabled ($scoped)',
      () async {
        final s = _Server()..scoped = scoped;
        addTearDown(s.api.close);
        s.catalog.addAll([
          _label(3, 'priority::one'),
          _label(4, 'priority::two'),
        ]);
        final opening = s.writer.prepare(
          _request(['priority::one', 'priority::two']),
        );
        if (scoped == false) {
          final result = await s.commit(await opening) as port.AiWriteSettled;
          expect(result.state, AiJournalState.succeeded);
          expect(s.selected, [
            'gid://gitlab/GroupLabel/3',
            'gid://gitlab/GroupLabel/4',
          ]);
        } else {
          await expectLater(opening, throwsA(_refused('validation')));
          expect(s.mutations, 0);
        }
      },
    );
  }

  for (final fault in ['500', 'transport']) {
    test('method preflight $fault refuses before journal hook', () async {
      final s = _Server();
      addTearDown(s.api.close);
      final prepared = await s.writer.prepare(_request());
      if (fault == '500') {
        s.labelReadStatus = 500;
      } else {
        s.labelReadTransportFailure = true;
      }
      var hooks = 0;
      final result = await s.commit(
        prepared,
        before: () async {
          hooks++;
        },
      );
      expect(result, isA<port.AiWriteNotSent>());
      expect(hooks, 0);
      expect(s.mutations, 0);
    });

    test(
      'coordinator method preflight $fault settles notExecuted without isolation',
      () async {
        final h = await _Harness.create();
        final proposal = (await h.propose())!;
        h.server.afterRead = (operation) {
          if (operation == 'MobileWorkItemLabels' &&
              h.server.reads[operation] == 3) {
            if (fault == '500') {
              h.server.labelReadStatus = 500;
            } else {
              h.server.labelReadTransportFailure = true;
            }
          }
        };
        final result = await h.coordinator.approve(proposal);
        expect(result.state, AiJournalState.notExecuted);
        expect(
          h.journal.entries(g0eAccount).single.state,
          AiJournalState.notExecuted,
        );
        expect(
          h.journal.isolated(g0eAccount, {
            const AiConflictKey([g0eAccount, 'group:7', 'workItem', '5']),
          }),
          isFalse,
        );
        expect(h.server.mutations, 0);
        final reads = h.server.resourceRequests;
        expect(await h.propose(), isNull);
        expect(
          h.coordinator.outcomeFor('labels-call-1')?.reasonCode,
          'previousWriteIncomplete',
        );
        expect(h.server.resourceRequests, reads);
      },
    );
  }

  for (final fault in ['epoch', 'session']) {
    test('proposal $fault loss cannot be revived at approval', () async {
      final h = await _Harness.create();
      final proposal = (await h.propose())!;
      if (fault == 'epoch') {
        h.server.api.clearReadCache();
      } else {
        h.server.live = false;
      }
      final result = await h.coordinator.approve(proposal);
      expect(result.state, AiJournalState.notExecuted);
      expect(h.server.mutations, 0);
    });
  }

  test('one complete current page of 100 can be cleared', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([
      for (var id = 3; id <= 100; id++) _label(id, 'label$id'),
    ]);
    s.selected = [for (final label in s.catalog) label['id']! as String];
    final prepared = await s.writer.prepare(_request([]));
    expect(
      (await s.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(
      (s.inputs.single['labelsWidget']! as Map)['removeLabelIds'],
      hasLength(100),
    );
    expect(s.reads['MobileWorkItemLabels'], 3);
  });

  test('101 current labels refuse without candidate lookup', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.currentOnly.addAll([
      for (var id = 3; id <= 101; id++) _label(id, 'label$id'),
    ]);
    s.selected = [
      for (final label in [...s.catalog, ...s.currentOnly])
        label['id']! as String,
    ];
    await expectLater(
      s.writer.prepare(_request([])),
      throwsA(_refused('unsupported')),
    );
    expect(s.reads['MobileGroupWorkItemLabelCandidates'], isNull);
    expect(s.mutations, 0);
  });
}
