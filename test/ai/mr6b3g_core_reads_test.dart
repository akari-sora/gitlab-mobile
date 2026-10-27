import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';

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

void main() {
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
