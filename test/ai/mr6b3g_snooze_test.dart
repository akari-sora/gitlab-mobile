import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import '../support/fake_adapter.dart';
import 'mr6b3g_support.dart';

// These existing accountTodo operations gain owner variants, not new aliases.
const groupSnoozeStageOperations = <String>{'snoozeTodo', 'unsnoozeTodo'};

const _global = AiWriteScope(
  accountKey: g0eAccount,
  grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
);

AiTargetRef _target({int groupId = 7, int iid = 5, String path = g0ePath}) =>
    AiTargetRef(
      kind: AiTargetKind.todo,
      side: AiResourceSide.group,
      groupId: groupId,
      groupFullPath: path,
      workItemGid: 'gid://gitlab/WorkItem/91',
      parentIid: iid,
      origin: AiTargetOrigin.currentResource,
    );

void main() {
  test(
    'G-P13 pins existing aliases, accountTodo schemas and unchanged caps',
    () {
      expect(groupSnoozeStageOperations, {'snoozeTodo', 'unsnoozeTodo'});
      expect(
        aiGraphqlSnoozeRows.map((row) => row.operationId).toSet(),
        groupSnoozeStageOperations,
      );
      for (final operation in groupSnoozeStageOperations) {
        final row = productionAiLedger.find(operation)!;
        expect(row.namedMethod, operation);
        expect(row.scopeClass, AiScopeClass.accountTodo);
        expect(row.boundary, AiWriteBoundary.graph);
        expect(row.baseTier, AiWriteTier.t1);
        expect(row.modelVisible, isTrue);
        expect(row.readback, isFalse);
        expect(
          row.arguments.keys.toSet(),
          operation == 'snoozeTodo' ? {'todoId', 'until'} : {'todoId'},
        );
        expect(row.arguments.values.every((spec) => spec.required), isTrue);
        expect(row.arguments['todoId']!.type, AiArgType.integer);
        if (operation == 'snoozeTodo') {
          expect(row.arguments['until']!.type, AiArgType.string);
        }
        const logicalReads = 2 * (0 + 1 + 4) + 0 + 0;
        expect(row.httpCap, 2 * logicalReads + 1);
        expect(aiWriteRequestAllowance(operation, oauthReplay: false), 11);
        expect(aiWriteRequestAllowance(operation), 21);
      }
    },
  );

  for (final operation in groupSnoozeStageOperations) {
    test('$operation rejects model-supplied group proof before HTTP', () async {
      final adapter = FakeAdapter((_) => throw StateError('unexpected HTTP'));
      final api = testApi(adapter);
      addTearDown(api.close);
      final writePort = port.GitLabAiWritePort(api, accountKey: g0eAccount);
      for (final field in [
        'groupId',
        'groupFullPath',
        'iid',
        'workItemGid',
        'generation',
        'readEpoch',
        'isCurrent',
      ]) {
        await expectLater(
          writePort.prepare(
            port.AiWriteRequest(
              operationId: operation,
              executionId: 'forged-$field',
              scope: g0eScope,
              arguments: {
                'todoId': 19,
                if (operation == 'snoozeTodo') 'until': '2099-01-01T00:00:00Z',
                field: 7,
              },
            ),
          ),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
      }
      expect(adapter.requests, isEmpty);
    });

    test('$operation gate-off refuses group scope and accountGlobal', () {
      aiGroupWorkItemWritesEnabledForTesting = false;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      final row = productionAiLedger.find(operation)!;
      expect(scopeAdmits(g0eScope, row, _target()), isFalse);
      expect(scopeAdmits(_global, row, _target()), isFalse);
    });

    test(
      '$operation group binding requires exact owner, path and parent iid',
      () {
        aiGroupWorkItemWritesEnabledForTesting = true;
        addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
        final row = productionAiLedger.find(operation)!;
        expect(scopeAdmits(g0eScope, row, _target()), isTrue);
        expect(scopeAdmits(g0eScope, row, _target(groupId: 8)), isFalse);
        expect(scopeAdmits(g0eScope, row, _target(iid: 6)), isFalse);
        expect(
          scopeAdmits(g0eScope, row, _target(path: 'team/other')),
          isFalse,
        );
        expect(
          scopeAdmits(
            g0eScope,
            row,
            AiTargetRef(
              kind: AiTargetKind.todo,
              side: AiResourceSide.issue,
              projectId: 7,
              projectPath: '$g0ePath/project',
              parentIid: 5,
              origin: AiTargetOrigin.currentResource,
            ),
          ),
          isFalse,
        );
      },
    );

    test(
      '$operation accountGlobal structurally admits group todos without widening WI grant',
      () {
        aiGroupWorkItemWritesEnabledForTesting = true;
        addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
        final row = productionAiLedger.find(operation)!;
        expect(scopeAdmits(_global, row, _target()), isTrue);
        expect(
          scopeAdmits(_global, row, _target(groupId: 8, path: 'another/group')),
          isTrue,
        );
        expect(
          scopeAdmits(
            _global,
            const G0eLedger().find('updateGroupWorkItemState')!,
            AiTargetRef(
              kind: AiTargetKind.groupWorkItem,
              groupId: 7,
              groupFullPath: g0ePath,
              workItemGid: 'gid://gitlab/WorkItem/91',
              iid: 5,
              origin: AiTargetOrigin.currentResource,
            ),
          ),
          isFalse,
        );
        expect(
          scopeAdmits(
            _global,
            productionAiLedger.find('markTodoDone')!,
            _target(),
          ),
          isFalse,
        );
      },
    );

    test(
      '$operation normalized Issue alias cannot stand in for strict raw proof',
      () async {
        final adapter = FakeAdapter((request) {
          final query = (request.data as Map)['query'] as String;
          expect(query, startsWith('query '));
          expect(
            query,
            contains(
              'state: pending, isSnoozed: ${operation == 'unsnoozeTodo'}',
            ),
          );
          return jsonResponse({
            'data': {
              'currentUser': {
                'id': 'gid://gitlab/User/7',
                'todos': {
                  'pageInfo': {'hasNextPage': false, 'endCursor': null},
                  'nodes': [
                    {
                      'id': 'gid://gitlab/Todo/19',
                      'targetType': 'ISSUE',
                      'snoozedUntil': operation == 'unsnoozeTodo'
                          ? '2099-01-01T00:00:00Z'
                          : null,
                      'project': null,
                      'group': {
                        'id': 'gid://gitlab/Group/7',
                        'fullPath': g0ePath,
                      },
                      'targetEntity': {
                        '__typename': 'Issue',
                        'issueId': 'gid://gitlab/Issue/91',
                        'iid': '5',
                        'projectId': null,
                      },
                    },
                  ],
                },
              },
            },
          });
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final snooze = operation == 'snoozeTodo';
        final discovery = await (snooze
            ? api.pendingTodosForSnooze(allowGroupTargets: true)
            : api.snoozedTodosForUnsnooze(allowGroupTargets: true));
        expect(discovery.items.single['target_type'], 'WorkItem');
        expect(
          discovery.items.single['target']['id'],
          'gid://gitlab/WorkItem/91',
        );
        // Synthetic prior evidence proves why normalized discovery is not a
        // replacement for G0h's selected-todo raw-owner check.
        final owner = g0eIdentity(api);
        await expectLater(
          snooze
              ? api.pendingTodosForSnooze(
                  allowGroupTargets: true,
                  strictGroupOwner: owner,
                  strictGroupTodoId: 19,
                )
              : api.snoozedTodosForUnsnooze(
                  allowGroupTargets: true,
                  strictGroupOwner: owner,
                  strictGroupTodoId: 19,
                ),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.invalidResponse,
            ),
          ),
        );
        final selected = await (snooze
            ? api.selectedTodoForSnooze(
                19,
                expectedUserId: 7,
                generation: 7,
                readEpoch: api.captureGroupReadEpoch().readEpoch,
                isCurrent: () => true,
              )
            : api.selectedTodoForUnsnooze(
                19,
                expectedUserId: 7,
                generation: 7,
                readEpoch: api.captureGroupReadEpoch().readEpoch,
                isCurrent: () => true,
              ));
        expect(selected.selectedGroupTodo, isNull);
        expect(selected.unsupportedIds, contains(19));
        expect(adapter.requests, hasLength(3));
      },
    );
  }
}
