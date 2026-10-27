import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import '../support/strict_group_owner.dart';

const _path = 'team/sub';
const _group = 'gid://gitlab/Group/7';
const _item = 'gid://gitlab/WorkItem/91';

Map<String, Object?> _node() => {
  'id': _item,
  'iid': '3',
  'title': 'Group work item',
  'state': 'OPEN',
  'createdAt': '2026-10-01T00:00:00Z',
  'updatedAt': '2026-10-02T00:00:00Z',
  'project': null,
  'namespace': {'id': _group, 'fullPath': _path},
  'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Task'},
  'description': 'Synthetic group content',
  'widgets': <Object?>[],
};

Map<String, Object?> _envelope(
  Map<String, Object?> node, {
  String namespaceId = _group,
  String path = _path,
}) => {
  'data': <String, Object?>{
    'namespace': <String, Object?>{'id': namespaceId, 'fullPath': path, 'workItem': node},
  },
};

({GitLabApi api, FakeAdapter adapter}) _reader(
  Object envelope, {
  int expectedReads = 1,
  String path = _path,
}) {
  var mutations = 0;
  final adapter = FakeAdapter((request) {
    final body = request.data as Map;
    final query = body['query'] as String;
    if (query.trimLeft().startsWith('mutation ')) mutations++;
    expect(request.method, 'POST');
    expect(request.uri.toString(), 'https://example.com/gitlab/api/graphql');
    expect(query, namespaceWorkItemQuery);
    expect(body['variables'], {'path': path, 'iid': '3'});
    return jsonResponse(envelope);
  });
  final api = testApi(adapter);
  addTearDown(() {
    expect(mutations, 0);
    expect(adapter.requests, hasLength(expectedReads));
    api.close();
  });
  return (api: api, adapter: adapter);
}

Matcher get _invalid => throwsA(
  isA<ApiFailure>().having(
    (failure) => failure.kind,
    'kind',
    FailureKind.invalidResponse,
  ),
);

Matcher get _invisible => throwsA(
  isA<ApiFailure>().having(
    (failure) => failure.kind,
    'kind',
    FailureKind.invisible,
  ),
);

WorkItemGraphSummary _groupSummary() => WorkItemGraphSummary(
  id: _item,
  iid: 3,
  title: 'Group work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  project: null,
  namespace: const GraphResourceRef(id: _group, fullPath: _path),
  type: const WorkItemGraphType(id: 'gid://gitlab/WorkItems::Type/1', name: 'Task'),
);

WorkItemGraphDetail _detailFor(WorkItemGraphSummary summary) => WorkItemGraphDetail(
  summary: summary, description: null, widgetsAvailable: false,
  widgetTypes: const {}, descriptionWidget: null, assignees: null,
  labels: null, hierarchy: null, dates: null,
);

Map<String, Object?> _groupTodo({bool snoozed = false}) => {
  'id': 'gid://gitlab/Todo/19',
  'targetType': 'WORKITEM',
  'snoozedUntil': snoozed ? '2030-01-01T00:00:00Z' : null,
  'project': null,
  'group': {'id': _group, 'fullPath': _path},
  'targetEntity': <String, Object?>{
    '__typename': 'WorkItem',
    'workItemId': _item,
    'iid': '3',
    'workItemProject': null,
    'namespace': {'id': _group, 'fullPath': _path},
  },
};

void _corruptTodo(Map<String, Object?> todo, String problem) {
  final target = todo['targetEntity']! as Map<String, Object?>;
  switch (problem) {
    case 'missingOuterProject':
      todo.remove('project');
    case 'missingProject':
      target.remove('workItemProject');
    case 'project':
      target['workItemProject'] = {'id': 'gid://gitlab/Project/7', 'fullPath': _path};
    case 'namespace':
      target['namespace'] = {'id': 'gid://gitlab/Group/8', 'fullPath': _path};
      todo['group'] = {'id': 'gid://gitlab/Group/8', 'fullPath': _path};
    case 'path':
      target['namespace'] = {'id': _group, 'fullPath': 'team/foreign'};
      todo['group'] = {'id': _group, 'fullPath': 'team/foreign'};
    case 'missingNamespace':
      target.remove('namespace');
    case 'issueAlias':
      todo['targetType'] = 'ISSUE';
      todo['targetEntity'] = <String, Object?>{
        '__typename': 'Issue', 'issueId': 'gid://gitlab/Issue/91',
        'iid': '3', 'projectId': null,
      };
    case 'exact':
      break;
  }
}

void main() {
  final openers = <String, Future<Object?> Function(GitLabApi, WorkItemGraphSummary)>{
    'state': (api, summary) => api.workItemState(summary),
    'attribute': (api, summary) => api.workItemAttribute(summary, WorkItemAttributeKind.health),
    'status': (api, summary) => api.workItemStatus(_detailFor(summary), expectedUserId: 7, generation: 1),
    'dates': (api, summary) => api.workItemDates(_detailFor(summary), expectedUserId: 7, generation: 1),
    'health': (api, summary) => api.workItemHealthEdit(_detailFor(summary), expectedUserId: 7, generation: 1, isCurrent: () => true),
    'assignees': (api, summary) => api.workItemAssignees(_detailFor(summary), expectedUserId: 7),
    'milestone': (api, summary) => api.workItemMilestone(_detailFor(summary), expectedUserId: 7),
    'weight': (api, summary) => api.workItemWeight(_detailFor(summary), expectedUserId: 7),
    'content': (api, summary) => api.workItemContent(_detailFor(summary), expectedUserId: 7),
    'labels': (api, summary) => api.workItemLabels(_detailFor(summary), expectedUserId: 7, generation: 1),
    'notifications': (api, summary) => api.workItemNotifications(summary, expectedUserId: 7),
    'activity': (api, summary) => api.workItemActivity(summary),
    'activityWriteAccess': (api, summary) => api.workItemActivityWriteAccess(summary),
  };
  for (final entry in openers.entries) {
    test('strict ${entry.key} rejects evidence from a different API before reading', () async {
      final adapter = FakeAdapter((_) => throw StateError('no requests'));
      final other = testApi(FakeAdapter((_) => throw StateError('no requests')));
      final api = testApi(adapter);
      addTearDown(api.close);
      addTearDown(other.close);
      final summary = _groupSummary();
      final expected = summary.withStrictGroupOwner(strictGroupOwner(other, summary));
      await expectLater(Future<Object?>.sync(() => entry.value(api, expected)), throwsA(
        isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.cancelled)));
      expect(adapter.requests, isEmpty);
    });
  }

  for (final kind in WorkItemAttributeKind.values) {
    for (final problem in ['missing', 'project', 'namespace', 'exact']) {
      test('strict shared attribute ${kind.name} owner $problem', () async {
        final node = _node();
        corruptGroupOwner(node, problem);
        final adapter = FakeAdapter((_) => jsonResponse({'data': {'workItem': node}}));
        final api = testApi(adapter);
        addTearDown(api.close);
        final summary = _groupSummary();
        final expected = summary.withStrictGroupOwner(strictGroupOwner(api, summary));
        final future = api.workItemAttribute(expected, kind);
        if (problem == 'exact') {
          final value = await future;
          expect(value.namespace!.id, _group);
        } else {
          await expectLater(future, _invalid);
        }
        expect(adapter.requests, hasLength(1));
        expect((adapter.requests.single.data as Map)['query'], startsWith('query '));
      });
    }
    test('default shared attribute ${kind.name} accepts omitted project', () async {
      final node = _node()..remove('project');
      final adapter = FakeAdapter((_) => jsonResponse({'data': {'workItem': node}}));
      final api = testApi(adapter);
      addTearDown(api.close);
      final value = await api.workItemAttribute(_groupSummary(), kind);
      expect(value.project, isNull);
      expect(adapter.requests, hasLength(1));
    });
  }

  test('strict binding preserves fields and refuses mismatched summary', () {
    final api = testApi(FakeAdapter((_) => throw StateError('no requests')));
    addTearDown(api.close);
    final summary = _groupSummary();
    final owner = strictGroupOwner(api, summary);
    final strict = summary.withStrictGroupOwner(owner);
    expect(strict.strictGroupOwner, same(owner));
    expect(strict.title, summary.title);
    expect(strict.createdAt, summary.createdAt);
    expect(strict.updatedAt, summary.updatedAt);
    expect(strict.namespace, same(summary.namespace));
    final detail = _detailFor(summary);
    final strictDetail = detail.withStrictGroupOwner(owner);
    expect(strictDetail.summary.strictGroupOwner, same(owner));
    expect(strictDetail.widgetTypes, same(detail.widgetTypes));
    expect(strictDetail.descriptionWidget, same(detail.descriptionWidget));
    final foreign = WorkItemGraphSummary(
      id: summary.id, iid: summary.iid, title: summary.title, state: summary.state,
      createdAt: summary.createdAt, updatedAt: summary.updatedAt, project: null,
      namespace: const GraphResourceRef(id: 'gid://gitlab/Group/8', fullPath: _path),
      type: summary.type,
    );
    expect(() => foreign.withStrictGroupOwner(owner), throwsArgumentError);
  });

  test('strict owner cannot be replaced by a different displayed namespace', () async {
    final node = _node()..['namespace'] = {'id': 'gid://gitlab/Group/8', 'fullPath': _path};
    final adapter = FakeAdapter((_) => jsonResponse({'data': {'workItem': node}}));
    final api = testApi(adapter);
    addTearDown(api.close);
    final summary = _groupSummary();
    final expected = WorkItemGraphSummary(
      id: summary.id, iid: summary.iid, title: summary.title, state: summary.state,
      createdAt: summary.createdAt, updatedAt: summary.updatedAt, project: null,
      namespace: const GraphResourceRef(id: 'gid://gitlab/Group/8', fullPath: _path),
      type: summary.type, strictGroupOwner: strictGroupOwner(api, summary),
    );
    await expectLater(api.workItemAttribute(expected, WorkItemAttributeKind.health), _invalid);
    expect(adapter.requests, hasLength(1));
  });

  for (final snoozed in [false, true]) {
    for (final problem in [
      'missingOuterProject', 'missingProject', 'project', 'namespace',
      'path', 'missingNamespace', 'issueAlias', 'exact',
    ]) {
      test('strict ${snoozed ? 'snoozed' : 'pending'} todo target $problem', () async {
        final todo = _groupTodo(snoozed: snoozed);
        _corruptTodo(todo, problem);
        var reads = 0;
        final adapter = FakeAdapter((_) {
          reads++;
          return jsonResponse({'data': {'currentUser': {
            'id': 'gid://gitlab/User/7',
            'todos': {
              'nodes': reads == 1 ? <Object?>[] : [todo],
              'pageInfo': {'hasNextPage': reads == 1, 'endCursor': reads == 1 ? 'next' : null},
            },
          }}});
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final owner = strictGroupOwner(api, _groupSummary());
        final future = snoozed
            ? api.snoozedTodosForUnsnooze(allowGroupTargets: true,
                strictGroupOwner: owner, strictGroupTodoId: 19)
            : api.pendingTodosForSnooze(allowGroupTargets: true,
                strictGroupOwner: owner, strictGroupTodoId: 19);
        if (problem == 'exact') {
          final result = await future;
          expect(result.items.single['namespace']['id'], _group);
        } else {
          await expectLater(future, _invalid);
        }
        expect(adapter.requests, hasLength(2));
        expect(adapter.requests.every((r) => ((r.data as Map)['query'] as String).startsWith('query ')), isTrue);
      });
    }
  }

  test('strict todo expectations are paired and enabled before any read', () async {
    final adapter = FakeAdapter((_) => throw StateError('no requests'));
    final api = testApi(adapter);
    addTearDown(api.close);
    final owner = strictGroupOwner(api, _groupSummary());
    for (final call in [
      () => api.pendingTodosForSnooze(strictGroupOwner: owner),
      () => api.pendingTodosForSnooze(strictGroupTodoId: 19),
      () => api.snoozedTodosForUnsnooze(strictGroupOwner: owner, strictGroupTodoId: 19),
    ]) {
      await expectLater(call(), throwsA(isA<ApiFailure>().having(
        (f) => f.kind, 'kind', FailureKind.validation)));
    }
    expect(adapter.requests, isEmpty);
  });

  test('strict namespace accepts explicit null project and exact Group', () async {
    final h = _reader(_envelope(_node()));
    final detail = await h.api.namespaceWorkItem(
      _path,
      3,
      expectedNamespaceId: _group,
      strictIdentity: true,
    );
    expect(detail.summary.id, _item);
    expect(detail.summary.iid, 3);
    expect(detail.summary.project, isNull);
    expect(detail.summary.namespace!.id, _group);
    expect(detail.summary.namespace!.fullPath, _path);
  });

  for (final missing in ['project', 'namespace']) {
    test('strict namespace refuses missing $missing key', () async {
      final h = _reader(_envelope(_node()..remove(missing)));
      await expectLater(
        h.api.namespaceWorkItem(
          _path,
          3,
          expectedNamespaceId: _group,
          strictIdentity: true,
        ),
        _invalid,
      );
    });
  }

  test('namespace UI default retains missing-project behavior', () async {
    final h = _reader(_envelope(_node()..remove('project')));
    final detail = await h.api.namespaceWorkItem(
      _path,
      3,
      expectedNamespaceId: _group,
    );
    expect(detail.summary.project, isNull);
    expect(detail.summary.namespace!.id, _group);
  });

  for (final field in ['namespace', 'workItem']) {
    for (final missing in [true, false]) {
      test('strict namespace distinguishes ${missing ? 'missing' : 'null'} $field', () async {
        final envelope = _envelope(_node());
        final data = envelope['data']! as Map<String, Object?>;
        final parent = field == 'namespace'
            ? data
            : data['namespace']! as Map<String, Object?>;
        if (missing) {
          parent.remove(field);
        } else {
          parent[field] = null;
        }
        final h = _reader(envelope);
        await expectLater(
          h.api.namespaceWorkItem(
            _path,
            3,
            expectedNamespaceId: _group,
            strictIdentity: true,
          ),
          missing ? _invalid : _invisible,
        );
      });
    }
    test('namespace UI default keeps missing $field invisible', () async {
      final envelope = _envelope(_node());
      final data = envelope['data']! as Map<String, Object?>;
      final parent = field == 'namespace'
          ? data
          : data['namespace']! as Map<String, Object?>;
      parent.remove(field);
      final h = _reader(envelope);
      await expectLater(
        h.api.namespaceWorkItem(_path, 3, expectedNamespaceId: _group),
        _invisible,
      );
    });
  }

  for (final segment in ['.', '..']) {
    test('strict namespace refuses Group path segment $segment', () async {
      final path = 'team/$segment/sub';
      final node = _node()..['namespace'] = {'id': _group, 'fullPath': path};
      final h = _reader(_envelope(node, path: path), path: path);
      await expectLater(
        h.api.namespaceWorkItem(
          path,
          3,
          expectedNamespaceId: _group,
          strictIdentity: true,
        ),
        _invalid,
      );
    });
    test('namespace UI default keeps Group path segment $segment', () async {
      final path = 'team/$segment/sub';
      final node = _node()..['namespace'] = {'id': _group, 'fullPath': path};
      final h = _reader(_envelope(node, path: path), path: path);
      final detail = await h.api.namespaceWorkItem(
        path,
        3,
        expectedNamespaceId: _group,
      );
      expect(detail.summary.namespace!.fullPath, path);
    });
  }

  test('strict namespace requires expected namespace before any read', () async {
    final h = _reader(_envelope(_node()), expectedReads: 0);
    await expectLater(
      h.api.namespaceWorkItem(_path, 3, strictIdentity: true),
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.validation,
        ),
      ),
    );
  });

  test('strict namespace keeps valid project ownership distinct', () async {
    const namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/17';
    final node = _node()
      ..['project'] = {'id': 'gid://gitlab/Project/7', 'fullPath': _path}
      ..['namespace'] = {'id': namespaceId, 'fullPath': _path};
    final h = _reader(_envelope(node, namespaceId: namespaceId));
    final detail = await h.api.namespaceWorkItem(
      _path,
      3,
      expectedNamespaceId: namespaceId,
      strictIdentity: true,
    );
    expect(detail.summary.project!.id, 'gid://gitlab/Project/7');
    expect(detail.summary.namespace!.id, namespaceId);
    expect(detail.summary.namespace!.id, isNot(_group));
  });

  for (final problem in [
    'projectObject',
    'projectWrongType',
    'projectGroupNamespace',
    'namespaceNull',
    'namespaceObject',
    'namespaceWrongPath',
    'namespaceForeignGroup',
    'namespaceOuterForeignGroup',
    'namespaceOuterWrongPath',
    'workItemGroupGid',
    'workItemLeadingZero',
    'workItemOverflow',
    'workItemEncodedId',
    'wrongIid',
  ]) {
    test('strict namespace refuses $problem', () async {
      final node = _node();
      final envelope = _envelope(node);
      final outer = (envelope['data']! as Map)['namespace'] as Map;
      switch (problem) {
        case 'projectObject':
          node['project'] = <String, Object?>{};
        case 'projectWrongType':
          node['project'] = {'id': _group, 'fullPath': _path};
        case 'projectGroupNamespace':
          node['project'] = {'id': 'gid://gitlab/Project/7', 'fullPath': _path};
        case 'namespaceNull':
          node['namespace'] = null;
        case 'namespaceObject':
          node['namespace'] = <String, Object?>{};
        case 'namespaceWrongPath':
          node['namespace'] = {'id': _group, 'fullPath': 'team/other'};
        case 'namespaceForeignGroup':
          node['namespace'] = {'id': 'gid://gitlab/Group/8', 'fullPath': _path};
        case 'namespaceOuterForeignGroup':
          outer['id'] = 'gid://gitlab/Group/8';
        case 'namespaceOuterWrongPath':
          outer['fullPath'] = 'team/other';
        case 'workItemGroupGid':
          node['id'] = _group;
        case 'workItemLeadingZero':
          node['id'] = 'gid://gitlab/WorkItem/091';
        case 'workItemOverflow':
          node['id'] = 'gid://gitlab/WorkItem/99999999999999999999999999';
        case 'workItemEncodedId':
          node['id'] = 'gid://gitlab/WorkItem/%39%31';
        case 'wrongIid':
          node['iid'] = '4';
      }
      final h = _reader(envelope);
      await expectLater(
        h.api.namespaceWorkItem(
          _path,
          3,
          expectedNamespaceId: _group,
          strictIdentity: true,
        ),
        _invalid,
      );
    });
  }

  for (final groupId in [
    'gid://gitlab/Group/07',
    'gid://gitlab/Group/0',
    'gid://gitlab/Group/7/extra',
    'gid://gitlab/Group/999999999999999999999999999',
    'gid://gitlab/WorkItem/7',
    'gid://gitlab/Project/7',
  ]) {
    test('strict namespace refuses forged Group $groupId', () async {
      final node = _node()
        ..['namespace'] = {'id': groupId, 'fullPath': _path};
      final h = _reader(_envelope(node, namespaceId: groupId));
      await expectLater(
        h.api.namespaceWorkItem(
          _path,
          3,
          expectedNamespaceId: groupId,
          strictIdentity: true,
        ),
        _invalid,
      );
    });
  }

  for (final problem in ['path', 'projectGid', 'namespaceGid', 'projectNull']) {
    test('strict project namespace refuses $problem', () async {
      var namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/17';
      final project = <String, Object?>{
        'id': 'gid://gitlab/Project/7',
        'fullPath': _path,
      };
      final node = _node()..['project'] = project;
      switch (problem) {
        case 'path':
          project['fullPath'] = 'team/other';
        case 'projectGid':
          project['id'] = 'gid://gitlab/Project/07';
        case 'namespaceGid':
          namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/017';
        case 'projectNull':
          node['project'] = null;
      }
      node['namespace'] = {'id': namespaceId, 'fullPath': _path};
      final h = _reader(_envelope(node, namespaceId: namespaceId));
      await expectLater(
        h.api.namespaceWorkItem(
          _path,
          3,
          expectedNamespaceId: namespaceId,
          strictIdentity: true,
        ),
        _invalid,
      );
    });
  }
}
