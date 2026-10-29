import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import '../../tool/mr7/graphql_scenarios.dart';
import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart' as sandbox;

const _sha = '0123456789abcdef0123456789abcdef01234567';
const _id = Mr7Identity(
  projectId: 909,
  path: 'synthetic-owner/mr7-b2testnonce',
  userId: 7,
  namespaceId: 70,
  namespace: 'synthetic-owner',
  nonce: 'b2testnonce',
);

Mr7SandboxSession _session(
  Mr7SyntheticGitLab server, {
  bool Function()? current,
}) => Mr7SandboxSession(
  server: server,
  nonce: _id.nonce,
  boundaryValid: current,
  eventDelay: () async {},
);

List<Map<String, Object?>> _rows(Map<String, Object?> receipt) =>
    (receipt['scenarios']! as List).cast<Map<String, Object?>>();

Map<String, Object?> _part(Map<String, Object?> receipt, String key) =>
    (receipt[key]! as Map).cast<String, Object?>();

Future<Map<String, Object?>> _run(
  Mr7SyntheticGitLab server,
  List<sandbox.Mr7Scenario> scenarios, {
  Mr7Policy policy = Mr7Policy.candidate,
  Mr7SandboxSession? session,
  sandbox.Mr7Confirm? confirm,
  List<sandbox.Mr7ClosedVariant> closedVariants = const [],
}) => sandbox.runMr7Sandbox(
  releaseSha: _sha,
  policy: policy,
  server: server,
  session: session ?? _session(server),
  suite: 'graphql',
  scenarios: [
    for (final s in scenarios)
      if (s.closed == null) s,
  ],
  closedVariants: [
    ...closedVariants,
    for (final s in scenarios)
      if (s.closed case final refusal?)
        sandbox.Mr7ClosedVariant(
          id: s.id,
          suite: s.suite,
          operation: s.operation,
          variant: s.variant,
          tier: s.tier,
          refusal: refusal,
        ),
  ],
  confirm: confirm ?? (_) async => true,
);

void _syntheticOnly(Map<String, Object?> receipt) {
  expect(receipt['transport'], 'synthetic');
  expect(receipt['live'], 'NOT_RUN');
  expect(receipt['finalEligible'], false);
  expect(receipt['foreground'], true);
  expect(receipt['background'], false);
  expect(receipt['secretLeakScan'], 'PASS');
  expect(jsonEncode(receipt), isNot(contains('synthetic-gitlab-pat')));
  expect(jsonEncode(receipt), isNot(contains('synthetic-provider-key')));
}

const _workItem = 'gid://gitlab/WorkItem/31';
const _observerDocument = r'''
query B2Observer($id: ID!) {
  currentUser { id username }
  node(id: $id) {
    id project { id fullPath }
    notes(first: 100) {
      nodes { id }
      totalCount
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

// Contract probes exercise real guarded dispatch and sealed observer refusal.
// They do not run a production AI chain or contribute executable coverage.
Future<({Mr7SandboxSession session, Mr7Readback observer})> _observerProbe({
  bool activity = false,
}) async {
  final server = Mr7SyntheticGitLab();
  configureMr7GraphqlFixtures(server);
  final session = _session(server);
  await session.initialize();
  await session.bindWorkItemGraphResource(
    _workItem,
    path: 'projects/909/issues/3',
  );
  const parentMutation = r'''
mutation B2Parent($input: WorkItemUpdateInput!) {
  workItemUpdate(input: $input) { workItem { id } errors }
}
''';
  const activityMutation = r'''
mutation B2Activity($input: CreateNoteInput!) {
  createNote(input: $input) { note { id } errors }
}
''';
  final mutation = activity ? activityMutation : parentMutation;
  final variables = {
    'input': activity
        ? {'noteableId': _workItem, 'body': 'Synthetic comment'}
        : {'id': _workItem, 'stateEvent': 'CLOSE'},
  };
  final resultField = activity ? 'createNote' : 'workItemUpdate';
  final resourceField = activity ? 'note' : 'workItem';
  server.routes['POST /install/api/graphql'] = (_) {
    server.scenarioWrites++;
    server.addEvent(target: server.projectId);
    return mr7Json({
      'data': {
        resultField: {
          resourceField: {'id': activity ? 'gid://gitlab/Note/51' : _workItem},
          'errors': <Object?>[],
        },
      },
    });
  };
  final permit = Mr7MutationPermit(
    operation: activity
        ? 'createWorkItemActivityComment'
        : 'updateWorkItemState',
    paths: {'POST graphql'},
    resourceProjectId: 909,
    graphDocuments: {mutation},
    graphVariablesDigests: {mr7Digest(variables)},
    resultPath: ['data', resultField, resourceField],
  )..confirmed = true;
  session.permit = permit;
  await session.writer.post<Object?>(
    '${session.instance}/api/graphql',
    data: {'query': mutation, 'variables': variables},
  );
  expect(permit.sent, 1);
  expect(server.scenarioWrites, 1);
  final queries = {
    _observerDocument: {
      mr7Digest({'id': _workItem}),
    },
  };
  session.observerAdapter.graphReadDocuments = queries;
  return (
    session: session,
    observer: Mr7Readback(
      session,
      session.identity!,
      permit,
      paths: {'projects/909/issues/3'},
      graphQueries: queries,
    ),
  );
}

void main() {
  test(
    'inventory exactly covers production project GraphQL and group aliases',
    () {
      final project = mr7GraphqlOperations.map((row) => row.operation).toSet();
      expect(project, {
        'updateWorkItemState',
        'updateWorkItemStatus',
        'updateWorkItemDates',
        'updateWorkItemHealthStatus',
        'updateWorkItemAssignees',
        'updateWorkItemMilestone',
        'updateWorkItemWeight',
        'updateWorkItemContent',
        'updateWorkItemLabels',
        'createWorkItemActivityComment',
        'createWorkItemActivityReply',
        'editWorkItemActivityNote',
        'deleteWorkItemActivityNote',
        'setWorkItemActivityNoteReaction',
        'setWorkItemNotifications',
        'setIncidentStatus',
        'snoozeTodo',
        'unsnoozeTodo',
      });
      final groups = mr7GraphqlGroupRefusals()
          .map((row) => row.operation)
          .toSet();
      expect(groups, hasLength(15));
      expect(
        {...project, ...groups},
        {
          for (final row in ProductionAiLedger.rows)
            if (row.boundary == AiWriteBoundary.graph) row.operationId,
        },
      );
      for (final row in mr7GraphqlOperations) {
        final capability = productionAiLedger.find(row.operation)!;
        expect(row.tier.toLowerCase(), capability.baseTier.name);
        expect(row.preconditions, isNotEmpty);
        expect(row.readback, isNotEmpty);
        expect(
          row.confirmation,
          contains('explicit sandbox host confirmation'),
        );
        expect(row.chain, hasLength(7));
        expect(row.isolation, contains('429'));
        expect(row.cleanup, contains('quarantine'));
        expect(row.live, startsWith('NOT_RUN'));
        for (final variant in row.variants) {
          expect(variant.precondition, isNotEmpty);
          if (variant.noChange) {
            expect(
              variant.precondition,
              isNot(contains('fields differ')),
              reason: row.scenarioId(variant),
            );
          }
        }
      }
      expect(
        mr7GraphqlOperations.singleWhere((r) => r.tier == 'T4').confirmation,
        contains('typed #3'),
      );
    },
  );

  test(
    'every ledger enum and both boolean directions have explicit variants',
    () {
      for (final row in mr7GraphqlOperations) {
        final capability = productionAiLedger.find(row.operation)!;
        for (final argument in capability.arguments.entries) {
          final values = argument.value.enumValues;
          if (values == null || values.isEmpty) continue;
          expect(
            {
              for (final variant in row.variants)
                variant.arguments[argument.key],
            },
            containsAll(values),
            reason: row.operation,
          );
        }
      }
      for (final entry in {
        'setWorkItemNotifications': 'enabled',
        'setWorkItemActivityNoteReaction': 'add',
      }.entries) {
        final row = mr7GraphqlOperations.singleWhere(
          (r) => r.operation == entry.key,
        );
        expect({
          for (final v in row.variants) v.arguments[entry.value],
        }, containsAll([false, true]));
      }
      for (final row in mr7GraphqlOperations.where(
        (r) => r.operation.endsWith('Todo'),
      )) {
        expect(row.variants.map((v) => v.name).toSet(), {
          'project',
          'group',
          'account-global',
        });
        expect(row.closedReason, contains('7-D5'));
        expect(
          productionAiLedger.find(row.operation)!.readback,
          false,
          reason: 'D30 ack-only core semantics must remain unchanged.',
        );
      }
    },
  );

  test('every variant stays bound to the run sandbox target', () {
    final scenarios = mr7GraphqlScenarios();
    expect(scenarios.map((s) => s.id).toSet(), hasLength(scenarios.length));
    for (final scenario in scenarios) {
      final call = scenario.call(_id);
      final arguments = call.arguments! as Map<String, Object?>;
      expect(call.name, scenario.operation);
      if (!scenario.operation.endsWith('Todo')) {
        expect(arguments['projectId'], _id.projectId, reason: scenario.id);
        expect(arguments['iid'], 3, reason: scenario.id);
        expect(scenario.targetKind, AiTargetKind.issue);
      }
      expect(arguments.containsKey('groupFullPath'), false);
      expect(scenario.paths(_id), {'POST graphql'});
      expect(scenario.closed, isNotNull, reason: scenario.id);
      expect(
        scenario.graphDocuments,
        isEmpty,
        reason: 'No executable chain until its sealed observer is supported.',
      );
      expect(scenario.graphVariablesDigests, isEmpty);
      expect(
        scenario.createRegistry,
        isNotNull,
        reason: 'Use the real API-bound workspace registry.',
      );
    }
  });

  test(
    'coverage dispositions never promote synthetic refusals to live success',
    () {
      final coverage = mr7GraphqlCoverage();
      expect(coverage, hasLength(mr7GraphqlScenarios().length));
      expect(
        coverage.map((row) => row['id']).toSet(),
        mr7GraphqlScenarios().map((row) => row.id).toSet(),
      );
      for (final row in coverage) {
        expect(row['status'], 'NOT_RUN');
        expect(row['capability'], 'closed');
        expect(row['closureCause'], isNotEmpty);
        expect(row['closureDetail'], isNotEmpty);
        expect(row['live'], startsWith('NOT_RUN:'));
        expect(row['preconditions'], isNotEmpty);
        expect(row['closesOnlyWhen'], contains('independent-readback'));
      }
      expect(
        coverage.singleWhere(
          (r) => r['variant'] == 'multiple',
        )['closureDetail'],
        contains('7-D8'),
      );
      expect(mr7GraphqlSeamRequests.keys, {'B2-O1', 'B2-O2', 'B2-O3'});
      final counts = <String, int>{};
      for (final row in coverage) {
        final code = row['reason']! as String;
        counts.update(code, (value) => value + 1, ifAbsent: () => 1);
      }
      expect(counts, {
        'workItemParentObserverUnavailable': 26,
        'workItemActivityObserverUnavailable': 6,
        'workItemNoOpObserverUnavailable': 11,
        'healthWidgetNotModeled': 4,
        'weightWidgetNotModeled': 4,
        'otherMembersExcluded': 1,
        'sharedTodoScopesUnproven': 6,
      });
    },
  );

  test(
    'production receipt lists every project and todo variant as NOT_RUN',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7GraphqlFixtures(server);
      var confirmations = 0;
      final scenarios = mr7GraphqlScenarios();
      final receipt = await _run(
        server,
        scenarios,
        policy: Mr7Policy.production,
        confirm: (_) async {
          confirmations++;
          return true;
        },
      );
      _syntheticOnly(receipt);
      expect(receipt['policy'], 'production');
      expect(_rows(receipt), hasLength(scenarios.length));
      for (var i = 0; i < scenarios.length; i++) {
        final row = _rows(receipt)[i];
        expect(row['id'], scenarios[i].id);
        expect(row['operation'], scenarios[i].operation);
        expect(row['variant'], scenarios[i].variant);
        expect(row['tier'], scenarios[i].tier);
        expect(row.containsKey('scope'), false);
        expect(row['status'], 'NOT_RUN');
        expect(row['reason'], scenarios[i].closed!.code);
        expect(row['refusal'], scenarios[i].closed!.metadata);
        expect(row['mutationCount'], 0);
        expect(row['readback'], 'NOT_RUN');
        expect(row['live'], 'NOT_RUN');
        expect(row['releaseSha'], _sha);
      }
      expect(confirmations, 0);
      expect(server.scenarioWrites, 0);
      expect(server.setupWrites, 1);
      expect(server.cleanupWrites, 1);
      expect(_part(receipt, 'events')['complete'], true);
      expect(_part(receipt, 'cleanup')['deletionVerified'], true);
      expect(_part(receipt, 'coverage')['graphql'], 'NOT_RUN');
    },
  );

  test('candidate receipt preserves all typed closed identities', () async {
    final server = Mr7SyntheticGitLab();
    var confirmations = 0;
    final scenarios = [...mr7GraphqlScenarios(), ...mr7GraphqlGroupRefusals()];
    final receipt = await _run(
      server,
      [],
      closedVariants: mr7GraphqlClosedVariants(),
      confirm: (_) async {
        confirmations++;
        return true;
      },
    );
    _syntheticOnly(receipt);
    expect(receipt['status'], 'PASS');
    expect(receipt['evidenceClass'], 'CANDIDATE_ONLY');
    expect(_rows(receipt), hasLength(118));
    expect(confirmations, 0);
    expect(server.scenarioWrites, 0);
    expect(server.cleanupWrites, 1);
    expect(_part(receipt, 'events')['complete'], true);
    expect(_part(receipt, 'cleanup')['deletionVerified'], true);
    expect(_part(receipt, 'coverage')['graphql'], 'NOT_RUN');
    for (var i = 0; i < scenarios.length; i++) {
      final scenario = scenarios[i];
      final row = _rows(receipt)[i];
      expect(row['id'], scenario.id);
      expect(row['suite'], scenario.suite);
      expect(row['operation'], scenario.operation);
      expect(row['variant'], scenario.variant);
      expect(row['tier'], scenario.tier);
      expect(row['releaseSha'], _sha);
      expect(row['live'], 'NOT_RUN');
      expect(row['status'], 'NOT_RUN');
      expect(row['classification'], 'closedVariant');
      expect(row.containsKey('scope'), false);
      expect(row['reason'], scenario.closed!.code);
      expect(row['refusal'], scenario.closed!.metadata);
      expect(row['providerCalls'], 0);
      expect(row['mutationCount'], 0);
      expect(row['readback'], 'NOT_RUN');
      expect(row.containsKey('outcome'), false);
      expect(row.containsKey('coreOutcome'), false);
    }
    final output = Platform.environment['MR7_B2I_RECEIPT'];
    if (output != null) await File(output).writeAsString(jsonEncode(receipt));
  });

  for (final scenario in mr7GraphqlScenarios()) {
    test(
      '${scenario.id} candidate emits its typed zero-dispatch disposition',
      () async {
        final server = Mr7SyntheticGitLab();
        configureMr7GraphqlFixtures(server);
        final receipt = await _run(server, [scenario]);
        _syntheticOnly(receipt);
        expect(receipt['evidenceClass'], 'CANDIDATE_ONLY');
        final row = _rows(receipt).single;
        expect(row['id'], scenario.id);
        expect(row['status'], 'NOT_RUN', reason: jsonEncode(receipt));
        expect(row['classification'], 'closedVariant');
        expect(row['reason'], scenario.closed!.code);
        expect(row['refusal'], scenario.closed!.metadata);
        expect(row['suite'], 'graphql');
        expect(row['operation'], scenario.operation);
        expect(row['variant'], scenario.variant);
        expect(row['tier'], scenario.tier);
        expect(row['releaseSha'], _sha);
        expect(row['live'], 'NOT_RUN');
        expect(row['mutationCount'], 0);
        expect(row['providerCalls'], 0);
        expect(row.containsKey('outcome'), false);
        expect(row.containsKey('coreOutcome'), false);
        expect(row['readback'], 'NOT_RUN');
        expect(server.scenarioWrites, 0);
        expect(
          server.requests.where((r) => r.contains('/api/graphql')),
          isEmpty,
        );
        expect(
          (receipt['requestLedger']! as List).every(
            (r) =>
                (r as Map<Object?, Object?>)['operation'] == 'harnessSetup' ||
                r['operation'] == 'harnessCleanup',
          ),
          true,
        );
        expect(receipt['quarantined'], false, reason: jsonEncode(receipt));
        expect(server.cleanupWrites, 1);
        expect(_part(receipt, 'cleanup')['deletionVerified'], true);
      },
    );
  }

  test(
    'all 15 group aliases and rename/foreign/descendant fixtures are refusal-only',
    () async {
      final server = Mr7SyntheticGitLab();
      final scenarios = mr7GraphqlGroupRefusals();
      final receipt = await _run(server, scenarios);
      _syntheticOnly(receipt);
      expect(scenarios, hasLength(60));
      for (final scenario in scenarios) {
        expect(scenario.targetKind, AiTargetKind.groupWorkItem);
        expect(scenario.expectedMutations, 0);
        expect(
          (scenario.call(_id).arguments! as Map<String, Object?>).containsKey(
            'projectId',
          ),
          false,
        );
        final row = _rows(receipt).singleWhere((r) => r['id'] == scenario.id);
        expect(row['status'], 'NOT_RUN');
        expect(row['reason'], 'groupAliasesExcluded');
        expect(
          row['refusal'],
          const sandbox.Mr7ClosedRefusal(
            sandbox.Mr7ClosureCause.scopeExcluded,
            'groupAliasesExcluded',
          ).metadata,
        );
        expect(row['providerCalls'], 0);
        expect(row['mutationCount'], 0);
      }
      expect(server.requests.any((r) => r.contains('groups/')), false);
      expect(server.scenarioWrites, 0);
      expect(server.cleanupWrites, 1);
    },
  );

  test(
    'missing independent readback can never be reported as success',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      final p = session.identity!;
      final permit = Mr7MutationPermit(
        operation: 'updateWorkItemState',
        paths: const {'POST graphql'},
        resourceProjectId: p.projectId,
      )..returnedGlobalId = 'gid://gitlab/WorkItem/31';
      final observer = Mr7Readback(session, p, permit);
      for (final scenario in [
        ...mr7GraphqlScenarios(),
        ...mr7GraphqlGroupRefusals(),
      ]) {
        await expectLater(
          scenario.observe(observer, p),
          throwsA(
            isA<Mr7Refused>().having(
              (r) => r.code,
              'code',
              'graphqlIndependentReadbackUnavailable',
            ),
          ),
          reason: scenario.id,
        );
      }
      expect(observer.verifiedRequests, 0);
      await session.finish();
    },
  );

  test(
    'real workspace registry uses the fresh run identity and boundary',
    () async {
      // Exercise a non-default synthetic owner and the current-session fence.
      final server = Mr7SyntheticGitLab(userId: 17);
      configureMr7GraphqlFixtures(server);
      var current = true;
      final session = Mr7SandboxSession(
        server: server,
        expectedUserId: 17,
        nonce: _id.nonce,
        boundaryValid: () => current,
        eventDelay: () async {},
      );
      await session.initialize();
      final api = GitLabApi(
        instance: GitLabInstance.parse(session.instance.toString()),
        token: 'synthetic-gitlab-pat',
        dio: session.writer,
        cdnAdapter: session.writerAdapter,
      );
      final operation = mr7GraphqlOperations.singleWhere(
        (r) => r.operation == 'updateWorkItemStatus',
      );
      final scenario = operation.scenario(operation.variants.first);
      expect(() => scenario.createRegistry!(api), throwsA(isA<Mr7Refused>()));
      await scenario.freshness!(
        session,
        port.AiWriteRequest(
          operationId: scenario.operation,
          executionId: scenario.id,
          scope: AiWriteScope(
            accountKey: '${api.instance.key}#17',
            grants: [
              AiScopeGrant(
                kind: AiScopeKind.project,
                projectId: 909,
                projectPath: session.identity!.path,
              ),
            ],
          ),
          arguments: const {'projectId': 909, 'iid': 3},
        ),
      );
      final registry = scenario.createRegistry!(api);
      expect(registry.isActive('gid://gitlab/WorkItem/31'), false);
      current = false;
      expect(registry.isActive('gid://gitlab/WorkItem/31'), true);
      await session.finish();
      api.close();
      expect(server.scenarioWrites, 0);
      expect(server.cleanupWrites, 0);
    },
  );

  test('production WorkItem GID cannot be rebound as an Issue', () async {
    final server = Mr7SyntheticGitLab();
    configureMr7GraphqlFixtures(server);
    final session = _session(server);
    await session.initialize();
    await expectLater(
      session.bindGraphResource(
        'gid://gitlab/WorkItem/31',
        path: 'projects/909/issues/3',
      ),
      throwsA(
        isA<Mr7Refused>().having((r) => r.code, 'code', 'foreignResource'),
      ),
    );
    expect(session.quarantined, true);
    expect(server.scenarioWrites, 0);
    await session.finish();
    expect(server.cleanupWrites, 0);
  });

  test('delivered B2-S1 binds the exact fresh WorkItem GID', () async {
    final server = Mr7SyntheticGitLab();
    configureMr7GraphqlFixtures(server);
    final session = _session(server);
    await session.initialize();
    await session.bindWorkItemGraphResource(
      _workItem,
      path: 'projects/909/issues/3',
    );
    expect(session.quarantined, false);
    expect(server.scenarioWrites, 0);
    await session.finish();
    expect(server.cleanupWrites, 1);
  });

  test('sealed WorkItem parent effect observer is still unavailable', () async {
    final probe = await _observerProbe();
    try {
      await expectLater(
        probe.observer.observe(
          Mr7GraphObservation(
            document: _observerDocument,
            variables: {'id': _workItem},
            recordPath: ['data', 'node'],
            parentId: _workItem,
          ),
        ),
        throwsA(
          isA<Mr7Refused>().having((e) => e.code, 'code', 'observerConnection'),
        ),
      );
      expect(probe.observer.verifiedRequests, 0);
    } finally {
      probe.session.stop('unverifiedContractProbe');
      await probe.session.finish();
      expect(probe.session.server.cleanupWrites, 0);
    }
  });

  test('sealed observer refuses an outside-sandbox WorkItem parent', () async {
    final probe = await _observerProbe();
    try {
      await expectLater(
        probe.observer.observe(
          Mr7GraphObservation(
            document: _observerDocument,
            variables: {'id': 'gid://gitlab/WorkItem/777'},
            recordPath: ['data', 'node'],
            parentId: 'gid://gitlab/WorkItem/777',
          ),
        ),
        throwsA(
          isA<Mr7Refused>().having((e) => e.code, 'code', 'observerParent'),
        ),
      );
      expect(probe.observer.verifiedRequests, 0);
    } finally {
      probe.session.stop('unverifiedContractProbe');
      await probe.session.finish();
      expect(probe.session.server.cleanupWrites, 0);
    }
  });

  test('activity tool ID has no sealed complete-note mapping', () async {
    final probe = await _observerProbe(activity: true);
    try {
      await expectLater(
        probe.observer.observe(
          Mr7GraphObservation(
            document: _observerDocument,
            variables: {'id': _workItem},
            recordPath: ['data', 'node'],
            parentId: _workItem,
            connectionPath: ['notes'],
            expectedIds: {'gid://gitlab/Note/51'},
          ),
        ),
        throwsA(
          isA<Mr7Refused>().having(
            (e) => e.code,
            'code',
            'observerMutationTarget',
          ),
        ),
      );
      expect(probe.observer.verifiedRequests, 0);
    } finally {
      probe.session.stop('unverifiedContractProbe');
      await probe.session.finish();
      expect(probe.session.server.cleanupWrites, 0);
    }
  });

  test('WorkItem no-ops cannot borrow a REST subscription witness', () {
    const witness = Mr7ParentStateObservation(
      parent: Mr7Parent.issue(id: 31, iid: 3),
      state: Mr7ParentState.subscribed,
      expected: true,
    );
    for (final scenario in mr7GraphqlScenarios().where(
      (s) => s.closed!.code == 'workItemNoOpObserverUnavailable',
    )) {
      expect(
        witness.matchesCall(
          scenario.operation,
          scenario.call(_id).arguments,
          _id.projectId,
        ),
        false,
        reason: scenario.id,
      );
    }
  });

  test(
    'a registered production-style inline fragment read is admitted (7B0 seam B2-S2)',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      const document =
          r'''query MobileProjectWorkItem($path: ID!, $iid: String!) {
      project(fullPath: $path) { id fullPath workItems(first: 2, iid: $iid) {
        nodes { id widgets { type ... on WorkItemWidgetDescription { description } } }
        pageInfo { hasNextPage endCursor }
      } }
    }''';
      final variables = {'path': session.identity!.path, 'iid': '3'};
      session.observerAdapter.graphReadDocuments = {
        document: {mr7Digest(variables)},
      };
      var sends = 0;
      server.routes['POST /install/api/graphql'] = (_) {
        sends++;
        return mr7Json({'data': <String, Object?>{}});
      };
      // Named fragments and foreign/namespace selectors stay refused; see
      // mr7_sandbox_wave2_contract_test.dart.
      await session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': document, 'variables': variables},
      );
      expect(sends, 1);
      expect(session.quarantined, false);
      expect(server.scenarioWrites, 0);
      await session.finish();
      // This read's custom route returns before the generic POST write counter.
      // The admitted, unquarantined session deletes its own sandbox once.
      expect(server.cleanupWrites, 1);
    },
  );

  test(
    'unverified GraphQL scope stops subsequent scenarios and cleanup',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7GraphqlFixtures(server);
      // Deliberately drop the typed closure only in this refusal probe. These
      // are never exported as executable variants or positive chain evidence.
      final cases = mr7GraphqlScenarios()
          .take(2)
          .map(
            (s) => sandbox.Mr7Scenario(
              id: s.id,
              suite: s.suite,
              operation: s.operation,
              variant: s.variant,
              tier: s.tier,
              targetKind: s.targetKind,
              call: s.call,
              paths: s.paths,
              resource: s.resource,
              freshness: s.freshness,
              createRegistry: s.createRegistry,
              observe: s.observe,
            ),
          )
          .toList();
      final receipt = await _run(server, [cases[0], cases[1]]);
      final rows = _rows(receipt);
      expect(rows.first['status'], isNot('PASS'));
      expect(rows.last['status'], 'NOT_RUN');
      expect(rows.last['reason'], 'sessionStopped');
      expect(rows.last['mutationCount'], 0);
      expect(receipt['quarantined'], true);
      expect(server.cleanupWrites, 0);
    },
  );

  test(
    'B0 uncertainty canary stops later GraphQL scenarios with zero retries',
    () async {
      // Reuse the B0 fixture solely for uncertainty propagation. Closed GraphQL
      // rows retain their dispositions; none is attempted after uncertainty.
      final server = Mr7SyntheticGitLab()..lostWriteReply = true;
      final receipt = await sandbox.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        confirm: (_) async => true,
        scenarios: sandbox.mr7ContractScenarios(),
        closedVariants: mr7GraphqlClosedVariants(),
      );
      _syntheticOnly(receipt);
      final rows = _rows(receipt);
      final canary = rows.singleWhere((r) => r['id'] == 'b0-star');
      expect(canary['status'], 'writeUncertain');
      expect(canary['mutationCount'], 1);
      for (final row in rows.where((r) => r['id'] != 'b0-star')) {
        expect(row['status'], 'NOT_RUN');
        expect(row['classification'], 'closedVariant');
        expect(row['providerCalls'], 0);
        expect(row['mutationCount'], 0);
      }
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['stopReason'], 'writeUncertain');
      expect(receipt['quarantined'], true);
    },
  );

  for (final variant in [
    'foreign-project',
    'group',
    'account-global',
    'numeric-id',
  ]) {
    test('sealed GraphQL $variant target is refused before dispatch', () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      const document = r'''mutation B2Bound($input: WorkItemUpdateInput!) {
        workItemUpdate(input: $input) { workItem { id } errors }
      }''';
      final variables = {
        'input': switch (variant) {
          'foreign-project' => {'projectId': 777},
          'group' => {'groupId': 'gid://gitlab/Group/44'},
          'account-global' => {'id': 'gid://gitlab/Todo/63'},
          _ => {'id': 31},
        },
      };
      session.permit = Mr7MutationPermit(
        operation: 'updateWorkItemState',
        paths: const {'POST graphql'},
        resourceProjectId: 909,
        graphDocuments: const {document},
        graphVariablesDigests: {mr7Digest(variables)},
      )..confirmed = true;
      await expectLater(
        session.writer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {'query': document, 'variables': variables},
        ),
        throwsA(isA<DioException>()),
      );
      expect(server.requests, isNot(contains('POST /install/api/graphql')));
      expect(server.scenarioWrites, 0);
      await session.finish();
      expect(server.cleanupWrites, 0);
    });
  }
}
