import 'dart:convert';

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
}) => sandbox.runMr7Sandbox(
  releaseSha: _sha,
  policy: policy,
  server: server,
  session: session ?? _session(server),
  suite: 'graphql',
  scenarios: scenarios,
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
      expect(
        scenario.graphDocuments,
        isEmpty,
        reason: 'Missing seals must remain closed, never guessed.',
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
        expect(row['reason'], startsWith('NOT_RUN/closed:'));
        expect(row['live'], startsWith('NOT_RUN:'));
        expect(row['preconditions'], isNotEmpty);
        expect(row['closesOnlyWhen'], contains('independent-readback'));
      }
      expect(
        coverage.singleWhere((r) => r['variant'] == 'multiple')['reason'],
        contains('7-D8'),
      );
      expect(mr7GraphqlSeamRequests.keys, {'B2-S1', 'B2-S2', 'B2-S3'});
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
        expect(row['scope'], 'project');
        expect(row['status'], 'NOT_RUN');
        expect(row['reason'], 'releaseClosed');
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

  for (final scenario in mr7GraphqlScenarios()) {
    test(
      '${scenario.id} candidate never bypasses the missing GraphQL seams',
      () async {
        final server = Mr7SyntheticGitLab();
        configureMr7GraphqlFixtures(server);
        final receipt = await _run(server, [scenario]);
        _syntheticOnly(receipt);
        expect(receipt['evidenceClass'], 'CANDIDATE_ONLY');
        final row = _rows(receipt).single;
        expect(row['id'], scenario.id);
        expect(row['status'], isNot('PASS'), reason: jsonEncode(receipt));
        expect(row['mutationCount'], 0);
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
        if (scenario.operation.endsWith('Todo')) {
          expect(row['status'], 'NOT_RUN');
          expect(row['reason'], 'releaseClosed');
        } else {
          // These are raw refusal receipts, not positive operation evidence.
          expect(row['provider'], isA<Map<String, Object?>>());
          expect(row['outcome'], 'notExecuted', reason: jsonEncode(receipt));
          expect(
            receipt['stopReason'],
            'unsealedGraph',
            reason: jsonEncode(receipt),
          );
          expect(receipt['quarantined'], true, reason: jsonEncode(receipt));
          expect(server.cleanupWrites, 0);
        }
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
        expect(row['reason'], 'releaseClosed');
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

  test('a registered production-style inline fragment read is admitted (7B0 seam B2-S2)', () async {
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
    await session.finish();
    // The synthetic server counts every POST to /api/graphql as a scenario
    // write. A session that was not quarantined deletes its own sandbox once.
    expect(server.cleanupWrites, 1);
  });

  test(
    'unverified GraphQL scope stops subsequent scenarios and cleanup',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7GraphqlFixtures(server);
      final cases = mr7GraphqlScenarios();
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
      // The scoped GraphQL chain cannot reach a send. Reuse the B0 production
      // star fixture solely to test fail-stop propagation into these definitions.
      // This is not a positive GraphQL operation or independent GraphQL readback.
      final server = Mr7SyntheticGitLab()..lostWriteReply = true;
      final receipt = await sandbox.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        confirm: (_) async => true,
        scenarios: [
          ...sandbox.mr7ContractScenarios(),
          ...mr7GraphqlScenarios(),
        ],
      );
      _syntheticOnly(receipt);
      final rows = _rows(receipt);
      expect(rows.first['status'], 'writeUncertain');
      expect(rows.first['mutationCount'], 1);
      for (final row in rows.skip(1)) {
        expect(row['status'], 'NOT_RUN');
        expect(row['reason'], 'sessionStopped');
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
