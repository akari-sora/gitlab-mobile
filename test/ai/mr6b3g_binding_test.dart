import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'mr6b3g_support.dart';
import 'mr6b3g_ui_add_test.dart' as ui_add;
import 'mr6b3_snooze_port_test.dart' as snooze;

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
  // Integrate the existing real UI-add and snooze FakeAdapter fixtures; these
  // are run here rather than treating their historical runs as new evidence.
  group('G15 UI-add ownership integration', ui_add.main);
  group('G15 selected group todo integration', snooze.main);

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
          await expectLater(future, throwsA(anything));
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
      aiGroupWorkItemWritesEnabledForTesting = true;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      final api = Object();
      final row = const G0eLedger().find('updateGroupWorkItemState')!;
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
