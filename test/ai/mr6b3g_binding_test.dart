import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_scope_add.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'mr6b3g_support.dart';
import 'fx_coord_support.dart';

Map<String, Object?> _namespace({int group = 7, int itemGroup = 7}) => {
  'id': 'gid://gitlab/Group/$group',
  'fullPath': g0ePath,
  'workItem': {
    'id': 'gid://gitlab/WorkItem/91',
    'iid': '5',
    'title': 'Synthetic group item',
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': '2026-10-02T00:00:00Z',
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/$itemGroup', 'fullPath': g0ePath},
    'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Task'},
    'widgets': <Object?>[],
  },
};

AiTargetRef _target({
  int group = 7,
  int iid = 5,
  String path = g0ePath,
  String gid = 'gid://gitlab/WorkItem/91',
  AiTargetOrigin origin = AiTargetOrigin.uiAdded,
  int? project,
}) => AiTargetRef(
  kind: AiTargetKind.groupWorkItem,
  groupId: group,
  groupFullPath: path,
  iid: iid,
  workItemGid: gid,
  origin: origin,
  projectId: project,
);

void main() {
  for (final scenario in ['verified', 'drift', 'foreign', 'project']) {
    test('UI-add $scenario uses fresh identity and production gate', () async {
      expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
      expect(aiGroupWorkItemWritesAreEnabled, isTrue);
      var reads = 0;
      final h = await StackHarness.create(
        configure: (server) {
          server.overrides['GET groups/team/sub'] = (_) => jsonResponse({
            'id': 7,
            'name': 'Sub',
            'full_path': g0ePath,
            'visibility': 'private',
          });
          server.overrides['GET groups/7'] = (_) => jsonResponse({
            'id': 7,
            'full_path': g0ePath,
            'visibility': 'private',
          });
          server.overrides['POST '] = (request) {
            final body = request.data! as Map;
            expect(body['query'], namespaceWorkItemQuery);
            expect(body['variables'], {'path': g0ePath, 'iid': '5'});
            reads++;
            final value = _namespace(
              group: scenario == 'foreign' ? 8 : 7,
              itemGroup: scenario == 'foreign' ? 8 : 7,
            );
            final item = value['workItem']! as Map<String, Object?>;
            if (scenario == 'drift' && reads == 2) {
              item['id'] = 'gid://gitlab/WorkItem/92';
            }
            if (scenario == 'project') {
              item['project'] = {
                'id': 'gid://gitlab/Project/7',
                'fullPath': '$g0ePath/app',
              };
              item['namespace'] = {
                'id': 'gid://gitlab/Namespaces::ProjectNamespace/7',
                'fullPath': '$g0ePath/app',
              };
            }
            return jsonResponse({
              'data': {'namespace': value},
            });
          };
        },
      );
      addTearDown(h.dispose);
      const link = 'https://example.com/gitlab/groups/team/sub/-/work_items/5';
      if (scenario == 'verified') await h.controller.send('First question');
      final before = h.server.adapter.requests.length;
      final check = await h.controller.checkGroupWorkItem(link);
      if (scenario != 'verified') {
        expect(check, isA<AiGroupWorkItemRefused>());
        expect(
          (check as AiGroupWorkItemRefused).reason,
          AiGroupWorkItemRefusal.notGroupOwned,
        );
        expect(h.controller.addedGroupWorkItems, isEmpty);
        expect(
          h.controller.writePolicySnapshot!.scope.uiAddedGroupWorkItems,
          isEmpty,
        );
        expect(
          h.server.adapter.requests
              .skip(before)
              .every(
                (request) =>
                    request.method == 'GET' ||
                    !((request.data as Map)['query'] as String).startsWith(
                      'mutation ',
                    ),
              ),
          isTrue,
        );
        return;
      }
      expect(check, isA<AiGroupWorkItemCandidate>());
      expect(h.controller.addedGroupWorkItems, isEmpty);
      expect(
        await h.controller.addGroupWorkItem(check as AiGroupWorkItemCandidate),
        isNull,
      );
      expect(
        h
            .controller
            .writePolicySnapshot!
            .scope
            .uiAddedGroupWorkItems
            .single
            .workItemGid,
        'gid://gitlab/WorkItem/91',
      );
      await h.controller.send('Second question');
      expect(h.provider.bodies, hasLength(2));
      expect(h.provider.bodies.last, contains('conversation_summary'));
      expect(h.provider.bodies.last, contains('updateGroupWorkItemState'));
      expect(
        h.controller.items.whereType<AiNoticeItem>().where(
          (item) => item.kind == AiNoticeKind.segmentSummary,
        ),
        hasLength(1),
      );
      h.controller.removeGroupWorkItem(h.controller.addedGroupWorkItems.single);
      final next =
          await h.controller.checkGroupWorkItem(link)
              as AiGroupWorkItemCandidate;
      await h.settings.revokeConsent(h.account, stackProviderConfig.id);
      expect(await h.controller.addGroupWorkItem(next), isNotNull);
      expect(h.controller.blocker, AiChatBlocker.consentRequired);
      expect(
        h.controller.writePolicySnapshot!.scope.uiAddedGroupWorkItems,
        isEmpty,
      );
    });
  }

  for (final operation in ['snoozeTodo', 'unsnoozeTodo']) {
    for (final scenario in ['group', 'projectless', 'fakeOuter', 'foreign']) {
      test('$operation production group ownership: $scenario', () async {
        expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
        expect(aiGroupWorkItemWritesAreEnabled, isTrue);
        final group = {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath};
        final entity = <String, Object?>{
          '__typename': 'WorkItem',
          'workItemId': 'gid://gitlab/WorkItem/91',
          'iid': '5',
          'workItemProject': null,
          'namespace': group,
        };
        final node = <String, Object?>{
          'id': 'gid://gitlab/Todo/400',
          'targetType': 'WORKITEM',
          'snoozedUntil': operation == 'unsnoozeTodo'
              ? '2099-01-01T00:00:00Z'
              : null,
          'project': null,
          'group': group,
          'targetEntity': entity,
        };
        if (scenario == 'projectless') {
          node['group'] = null;
          node['targetEntity'] = null;
        } else if (scenario == 'fakeOuter') {
          node['project'] = {
            'id': 'gid://gitlab/Project/7',
            'fullPath': g0ePath,
          };
          node['group'] = null;
        } else if (scenario == 'foreign') {
          final foreign = {'id': 'gid://gitlab/Group/8', 'fullPath': g0ePath};
          node['group'] = foreign;
          entity['namespace'] = foreign;
        }
        var mutations = 0;
        final adapter = FakeAdapter((request) {
          if (request.method == 'GET') {
            return jsonResponse({'id': 7, 'username': 'tester'});
          }
          final body = request.data as Map;
          final query = body['query'] as String;
          final variables = body['variables'] as Map;
          if (query.startsWith('query ')) {
            expect(
              query,
              startsWith(
                operation == 'snoozeTodo'
                    ? 'query MobilePendingTodosForSnooze('
                    : 'query MobileSnoozedTodosForUnsnooze(',
              ),
            );
            expect(variables['first'], 100);
            return jsonResponse({
              'data': {
                'currentUser': {
                  'id': 'gid://gitlab/User/7',
                  'todos': {
                    'nodes': [node],
                    'pageInfo': {'hasNextPage': false, 'endCursor': null},
                  },
                },
              },
            });
          }
          expect(query, startsWith('mutation MobileTodo'));
          mutations++;
          return jsonResponse({
            'data': {
              operation == 'snoozeTodo' ? 'todoSnooze' : 'todoUnSnooze': {
                'todo': {
                  'id': variables['id'],
                  'snoozedUntil': operation == 'snoozeTodo'
                      ? '2099-01-01T00:00:00Z'
                      : null,
                },
                'errors': <String>[],
              },
            },
          });
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final writer = port.GitLabAiWritePort(
          api,
          accountKey: g0eAccount,
          sessionGeneration: 7,
          isCurrent: () => true,
        );
        const global = AiWriteScope(
          accountKey: g0eAccount,
          grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
        );
        final request = port.AiWriteRequest(
          operationId: operation,
          executionId: 'g15-todo-$scenario',
          scope: scenario == 'projectless' || scenario == 'fakeOuter'
              ? global
              : g0eScope,
          arguments: {
            'todoId': 400,
            if (operation == 'snoozeTodo') 'until': '2099-01-01T00:00:00Z',
          },
        );
        if (scenario == 'group') {
          final prepared = await writer.prepare(request);
          expect(prepared.projectPath, isNull);
          expect(prepared.groupTodoTarget?.groupId, 7);
          expect(prepared.releaseName, '@tester');
          prepared.bindGraphBeforeMutation(() async {});
          final outcome = await writer.commit(prepared, mayStart: () => true);
          expect(outcome, isA<port.AiWriteSettled>());
          expect((outcome as port.AiWriteSettled).mutationCount, 1);
          expect(outcome.readbackVerified, isFalse);
          expect(mutations, 1);
          expect(adapter.requests, hasLength(3));
        } else {
          await expectLater(
            writer.prepare(request),
            throwsA(
              isA<port.AiWriteRefused>().having(
                (error) => error.reason,
                'reason',
                scenario == 'foreign'
                    ? 'todoUnverifiable'
                    : 'todoUnsupportedTarget',
              ),
            ),
          );
          expect(mutations, 0);
          expect(adapter.requests, hasLength(2));
        }
      });
    }
  }

  for (final (outer, inner) in [(7, 7), (8, 8), (7, 8)]) {
    test(
      'exact URL cannot replace numeric Group proof $outer/$inner',
      () async {
        final adapter = FakeAdapter((request) {
          if (request.method == 'GET') {
            return jsonResponse({'id': 7, 'username': 'tester'});
          }
          return jsonResponse({
            'data': {'namespace': _namespace(group: outer, itemGroup: inner)},
          });
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final writePort = port.GitLabAiWritePort(api, accountKey: g0eAccount);
        final future = writePort.resolveGroupWorkItemForTesting(
          port.AiWriteRequest(
            operationId: 'updateGroupWorkItemState',
            executionId: 'g15-url-proof',
            scope: g0eScope,
            arguments: const {'groupId': 7, 'iid': 5, 'stateEvent': 'close'},
          ),
          generation: 7,
          readEpoch: 1,
          isCurrent: () => true,
          resolvedUrl: Uri.parse(
            'https://example.com/gitlab/groups/team/sub/-/work_items/5',
          ),
        );
        if (outer == 7 && inner == 7) {
          final result = await future;
          expect(result.identity.groupId, 7);
          expect(result.identity.workItemGid, 'gid://gitlab/WorkItem/91');
        } else {
          await expectLater(
            future,
            throwsA(
              isA<ApiFailure>().having(
                (failure) => failure.kind,
                'kind',
                FailureKind.invalidResponse,
              ),
            ),
          );
        }
        expect(adapter.requests, hasLength(2));
        expect(adapter.requests.first.method, 'GET');
        final query = adapter.requests.last.data as Map;
        expect(query['query'], namespaceWorkItemQuery);
        expect(query['variables'], {'path': g0ePath, 'iid': '5'});
        expect(
          (query['query'] as String).trimLeft().startsWith('mutation'),
          isFalse,
        );
      },
    );
  }

  test(
    'UI-added authority requires exact verified owner and item; no siblings or descendants',
    () {
      expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
      expect(aiGroupWorkItemWritesAreEnabled, isTrue);
      final api = Object();
      final row = productionAiLedger.find('updateGroupWorkItemState')!;
      final scope = AiWriteScope(
        accountKey: g0eAccount,
        grants: g0eScope.grants,
        uiAddedGroupWorkItems: [g0eIdentity(api)],
      );
      expect(scopeAdmits(scope, row, _target()), isTrue);
      for (final forged in [
        _target(group: 8),
        _target(iid: 6),
        _target(path: 'team/renamed'),
        _target(gid: 'gid://gitlab/WorkItem/92'),
        _target(project: 7),
      ]) {
        expect(scopeAdmits(scope, row, forged), isFalse);
      }
      final assertedWithoutEvidence = AiWriteScope(
        accountKey: g0eAccount,
        grants: g0eScope.grants,
      );
      expect(scopeAdmits(assertedWithoutEvidence, row, _target()), isFalse);
    },
  );

  test('group-page descendant grants just one project issue and its note', () {
    final grant = projectIssueFromGroupPage(
      projectId: 7,
      projectPath: 'team/sub/project',
      iid: 5,
    );
    final scope = AiWriteScope(accountKey: g0eAccount, grants: [grant]);
    final row = productionAiLedger.find('updateWorkItemState')!;
    final noteRow = productionAiLedger.find('deleteWorkItemActivityNote')!;
    expect(
      scopeAdmits(
        scope,
        row,
        AiTargetRef(kind: AiTargetKind.issue, projectId: 7, iid: 5),
      ),
      isTrue,
    );
    expect(
      scopeAdmits(
        scope,
        noteRow,
        AiTargetRef(
          kind: AiTargetKind.note,
          projectId: 7,
          parentIid: 5,
          noteId: 10,
        ),
      ),
      isTrue,
    );
    expect(
      scopeAdmits(
        scope,
        row,
        AiTargetRef(kind: AiTargetKind.issue, projectId: 7, iid: 6),
      ),
      isFalse,
    );
    expect(
      scopeAdmits(
        scope,
        row,
        AiTargetRef(kind: AiTargetKind.issue, projectId: 8, iid: 5),
      ),
      isFalse,
    );
    expect(
      scopeAdmits(scope, row, _target(origin: AiTargetOrigin.currentResource)),
      isFalse,
    );
    expect(
      aiWriteScopeKey(g0eAccount, grant),
      '($g0eAccount, project:7, workItem, 5)',
    );
  });
}
