import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

// Independent whole documents: GitLab v19.5.0-ee Issue exposes projectId;
// aliases separate the fragments' different ID scalars/project nullability.
const _pendingOwnershipQuery = r'''
query MobilePendingTodosForSnooze($first: Int!, $after: String) {
  currentUser {
    id
    todos(state: pending, isSnoozed: false, first: $first, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id targetType snoozedUntil
        project { id fullPath }
        group { id fullPath }
        targetEntity {
          __typename
          ... on Issue { issueId: id iid projectId }
          ... on MergeRequest { mergeRequestId: id iid mergeRequestProject: project { id fullPath } }
          ... on WorkItem {
            workItemId: id iid workItemProject: project { id fullPath } namespace { id fullPath }
          }
        }
      }
    }
  }
}''';

const _snoozedOwnershipQuery = r'''
query MobileSnoozedTodosForUnsnooze($first: Int!, $after: String) {
  currentUser {
    id
    todos(state: pending, isSnoozed: true, first: $first, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id targetType snoozedUntil
        project { id fullPath }
        group { id fullPath }
        targetEntity {
          __typename
          ... on Issue { issueId: id iid projectId }
          ... on MergeRequest { mergeRequestId: id iid mergeRequestProject: project { id fullPath } }
          ... on WorkItem {
            workItemId: id iid workItemProject: project { id fullPath } namespace { id fullPath }
          }
        }
      }
    }
  }
}''';

Map<String, Object?> _body(RequestOptions request) => (request.data as Map).cast<String, Object?>();
Map<String, Object?> _variables(RequestOptions request) =>
    (_body(request)['variables']! as Map).cast<String, Object?>();
bool _graph(RequestOptions request) => request.uri.path == '/gitlab/api/graphql';

Json _restTodo(int id, String title) => {
  'id': id, 'action_name': 'assigned', 'target_type': 'Issue', 'state': 'pending',
  'target': {'iid': id, 'title': title}, 'project': {'id': 10, 'path_with_namespace': 'team/core'},
  'author': {'username': 'lead'}, 'updated_at': '2026-09-20T10:00:00Z',
};

Map<String, Object?> _snoozedNode(int id, String title, String until) => {
  'id': 'gid://gitlab/Todo/$id', 'action': 'review_requested', 'body': title, 'createdAt': '2026-09-20T10:00:00Z',
  'snoozedUntil': until, 'targetType': 'MERGEREQUEST', 'targetUrl': 'https://example.com/gitlab/team/core/-/merge_requests/$id',
  'author': {'username': 'lead'}, 'project': {'id': 'gid://gitlab/Project/10', 'fullPath': 'team/core'},
  'targetEntity': {'iid': '$id', 'title': title},
};

Map<String, Object?> _groupOwnershipTodo(int id) => {
  'id': 'gid://gitlab/Todo/$id',
  'targetType': 'WORKITEM',
  'snoozedUntil': null,
  'project': null,
  'group': <String, Object?>{'id': 'gid://gitlab/Group/2', 'fullPath': 'team/sub'},
  'targetEntity': <String, Object?>{
    '__typename': 'WorkItem', 'workItemId': 'gid://gitlab/WorkItem/91', 'iid': '7',
    'workItemProject': null,
    'namespace': <String, Object?>{'id': 'gid://gitlab/Group/2', 'fullPath': 'team/sub'},
  },
};

Map<String, Object?> _issueOwnershipTodo(int id) => {
  'id': 'gid://gitlab/Todo/$id',
  'targetType': 'ISSUE',
  'snoozedUntil': null,
  'project': {'id': 'gid://gitlab/Project/10', 'fullPath': 'team/core'},
  'group': null,
  'targetEntity': <String, Object?>{
    '__typename': 'Issue', 'issueId': 'gid://gitlab/Issue/91', 'iid': '7',
    'projectId': 10,
  },
};

// v19.5.0-ee TodoService#attributes_for_target stores a group WorkItem's
// polymorphic name (Issue), project:nil and group:namespace; TodoType then
// loads Issue. This is the ordinary creation/read path, with query aliases.
Map<String, Object?> _groupIssueOwnershipTodo(int id) {
  final node = _issueOwnershipTodo(id)..['project'] = null;
  node['group'] = <String, Object?>{'id': 'gid://gitlab/Group/2', 'fullPath': 'team/sub'};
  (node['targetEntity']! as Map<String, Object?>)['projectId'] = null;
  return node;
}

Object _ownershipPage(List<Object?> nodes, {bool more = false, String? cursor}) => {
  'data': {'currentUser': {
    'id': 'gid://gitlab/User/3',
    'todos': {'nodes': nodes, 'pageInfo': {'hasNextPage': more, 'endCursor': cursor}},
  }},
};

void _assertOwnershipRead(RequestOptions request, bool snoozed) {
  expect(request.method, 'POST');
  expect(_graph(request), isTrue);
  final query = _body(request)['query']! as String;
  expect(query.trimLeft(), startsWith('query '));
  expect(query, isNot(contains('mutation ')), reason: 'ownership readers never mutate');
  expect(query, contains('isSnoozed: $snoozed'));
}

void main() {
  for (final snoozed in [false, true]) {
    test('fixed ownership document for snoozed=$snoozed', () async {
      final adapter = FakeAdapter((_) => jsonResponse(_ownershipPage([])));
      final api = testApi(adapter);
      addTearDown(api.close);
      final result = await (snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze());
      expect(result.actorId, 'gid://gitlab/User/3');
      expect(result.items, isEmpty);
      expect(result.unsupportedIds, isEmpty);
      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      _assertOwnershipRead(request, snoozed);
      // Assert outside the adapter so mismatches remain assertion failures.
      expect(_body(request)['query'], snoozed ? _snoozedOwnershipQuery : _pendingOwnershipQuery);
      expect(_variables(request), {'first': 100, 'after': null});
    });

    test('Issue todo ownership uses numeric projectId for snoozed=$snoozed', () async {
      final adapter = FakeAdapter((request) {
        _assertOwnershipRead(request, snoozed);
        return jsonResponse(_ownershipPage([_issueOwnershipTodo(1)]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final result = await (snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze());
      expect(result.unsupportedIds, isEmpty);
      expect(result.items.single, {
        'id': 1, 'target_type': 'Issue', 'snoozed_until': null,
        'project': {'id': 10, 'path_with_namespace': 'team/core'},
        'target': {'id': 'gid://gitlab/Issue/91', 'iid': 7},
      });
      expect(adapter.requests, hasLength(1));
    });

    for (final problem in <String, Object?>{
      'missing': null, 'null': null, 'mismatched': 11, 'string': '10',
      'float': 10.0, 'fractional': 10.5, 'boolean': true,
      'zero': 0, 'negative': -10, 'object': {'id': 10},
    }.entries) {
      test('Issue todo ownership refuses ${problem.key} projectId for snoozed=$snoozed', () async {
        final node = _issueOwnershipTodo(1);
        final target = node['targetEntity']! as Map<String, Object?>;
        if (problem.key == 'missing') {
          target.remove('projectId');
        } else {
          target['projectId'] = problem.value;
        }
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          return jsonResponse(_ownershipPage([node, _issueOwnershipTodo(2)]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final result = await (snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze());
        expect(result.items.map((item) => item['id']), [2]);
        expect(result.unsupportedIds, {1});
        expect(adapter.requests, hasLength(1));
      });
    }

    test('Issue todo ownership requires a canonical outer Project GID for snoozed=$snoozed', () async {
      for (final gid in [
        'gid://gitlab/Group/10', 'gid://gitlab/Project/010', 'gid://gitlab/Project/0',
        'gid://gitlab/Project/-10', 'gid://gitlab/Project/10\n',
        'gid://gitlab/Project/999999999999999999999999999999999',
      ]) {
        final node = _issueOwnershipTodo(1);
        (node['project']! as Map<String, Object?>)['id'] = gid;
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          return jsonResponse(_ownershipPage([node]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze(),
          throwsA(isA<ApiFailure>().having((failure) => failure.kind, 'kind', FailureKind.invalidResponse)),
          reason: gid,
        );
        expect(adapter.requests, hasLength(1));
      }
    });

    test('Issue todo without group evidence stays unsupported for snoozed=$snoozed', () async {
      for (final allowGroup in [false, true]) {
        for (final projectId in [null, 10]) {
          final node = _issueOwnershipTodo(1)..['project'] = null;
          (node['targetEntity']! as Map<String, Object?>)['projectId'] = projectId;
          final adapter = FakeAdapter((request) {
            _assertOwnershipRead(request, snoozed);
            return jsonResponse(_ownershipPage([node]));
          });
          final api = testApi(adapter);
          addTearDown(api.close);
          final result = await (snoozed
              ? api.snoozedTodosForUnsnooze(allowGroupTargets: allowGroup)
              : api.pendingTodosForSnooze(allowGroupTargets: allowGroup));
          expect(result.items, isEmpty);
          expect(result.unsupportedIds, {1});
          expect(adapter.requests, hasLength(1));
        }
      }
    });

    test('upstream Issue group todo ownership is opt-in for snoozed=$snoozed', () async {
      final node = _groupIssueOwnershipTodo(1);
      node['snoozedUntil'] = snoozed ? '2030-01-02T09:00:00Z' : null;
      final adapter = FakeAdapter((request) {
        _assertOwnershipRead(request, snoozed);
        return jsonResponse(_ownershipPage([node]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final normal = await (snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze());
      expect(normal.items, isEmpty);
      expect(normal.unsupportedIds, {1});
      final opted = await (snoozed
          ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
          : api.pendingTodosForSnooze(allowGroupTargets: true));
      expect(opted.unsupportedIds, isEmpty);
      expect(opted.items.single, {
        'id': 1, 'target_type': 'WorkItem', 'snoozed_until': node['snoozedUntil'],
        'project': null,
        'namespace': {'id': 'gid://gitlab/Group/2', 'group_id': 2, 'full_path': 'team/sub'},
        'target': {'id': 'gid://gitlab/WorkItem/91', 'iid': 7},
      });
      expect(adapter.requests, hasLength(2), reason: 'one fixed document per complete read');
    });

    test('Issue group todo requires the Todo group for snoozed=$snoozed', () async {
      for (final missing in [false, true]) {
        final node = _groupIssueOwnershipTodo(1);
        if (missing) {
          node.remove('group');
        } else {
          node['group'] = null;
        }
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          return jsonResponse(_ownershipPage([node]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final read = snoozed
            ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
            : api.pendingTodosForSnooze(allowGroupTargets: true);
        if (missing) {
          await expectLater(read, throwsA(isA<ApiFailure>().having(
            (failure) => failure.kind, 'kind', FailureKind.invalidResponse)));
        } else {
          final result = await read;
          expect(result.items, isEmpty);
          expect(result.unsupportedIds, {1});
        }
        expect(adapter.requests, hasLength(1));
      }
    });

    test('Issue group todo refuses forged ownership and coordinates for snoozed=$snoozed', () async {
      for (final problem in [
        'outerProjectMissing', 'foreignGroupType', 'groupLeadingZero', 'groupZero', 'groupOverflow',
        'groupIdMissing', 'groupPathMissing', 'groupPathInvalid', 'groupDot', 'groupDotDot',
        'issueWrongType', 'issueLeadingZero', 'issueZero', 'issueOverflow', 'issueTrailingData',
        'iidLeadingZero', 'iidZero', 'iidOverflow', 'iidTrailingData', 'iidMissing',
      ]) {
        final node = _groupIssueOwnershipTodo(1);
        final target = node['targetEntity']! as Map<String, Object?>;
        final group = node['group']! as Map<String, Object?>;
        switch (problem) {
          case 'outerProjectMissing': node.remove('project');
          case 'foreignGroupType': group['id'] = 'gid://gitlab/Project/2';
          case 'groupLeadingZero': group['id'] = 'gid://gitlab/Group/02';
          case 'groupZero': group['id'] = 'gid://gitlab/Group/0';
          case 'groupOverflow': group['id'] = 'gid://gitlab/Group/999999999999999999999999999999999';
          case 'groupIdMissing': group.remove('id');
          case 'groupPathMissing': group.remove('fullPath');
          case 'groupPathInvalid': group['fullPath'] = 'team//sub';
          case 'groupDot': group['fullPath'] = 'team/./sub';
          case 'groupDotDot': group['fullPath'] = 'team/../sub';
          case 'issueWrongType': target['issueId'] = 'gid://gitlab/WorkItem/91';
          case 'issueLeadingZero': target['issueId'] = 'gid://gitlab/Issue/091';
          case 'issueZero': target['issueId'] = 'gid://gitlab/Issue/0';
          case 'issueOverflow': target['issueId'] = 'gid://gitlab/Issue/999999999999999999999999999999999';
          case 'issueTrailingData': target['issueId'] = 'gid://gitlab/Issue/91\n';
          case 'iidLeadingZero': target['iid'] = '07';
          case 'iidZero': target['iid'] = '0';
          case 'iidOverflow': target['iid'] = '999999999999999999999999999999999';
          case 'iidTrailingData': target['iid'] = '7\n';
          case 'iidMissing': target.remove('iid');
        }
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          return jsonResponse(_ownershipPage([node]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
              : api.pendingTodosForSnooze(allowGroupTargets: true),
          throwsA(isA<ApiFailure>().having((failure) => failure.kind, 'kind', FailureKind.invalidResponse)),
          reason: problem,
        );
        expect(adapter.requests, hasLength(1), reason: problem);
      }
    });

    test('Issue group todo refuses project and type mismatches for snoozed=$snoozed', () async {
      for (final problem in ['missingProjectId', 'projectBacked', 'outerProject', 'targetType', 'unknownType']) {
        final node = _groupIssueOwnershipTodo(1);
        final target = node['targetEntity']! as Map<String, Object?>;
        switch (problem) {
          case 'missingProjectId': target.remove('projectId');
          case 'projectBacked': target['projectId'] = 10;
          case 'outerProject': node['project'] = {'id': 'gid://gitlab/Project/10', 'fullPath': 'team/core'};
          case 'targetType': node['targetType'] = 'WORKITEM';
          case 'unknownType': node['targetType'] = 'OTHER';
        }
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          return jsonResponse(_ownershipPage([node, _issueOwnershipTodo(2)]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final result = await (snoozed
            ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
            : api.pendingTodosForSnooze(allowGroupTargets: true));
        expect(result.items.map((item) => item['id']), [2], reason: problem);
        expect(result.items.single['target_type'], 'Issue');
        expect(result.items.single.containsKey('namespace'), isFalse);
        expect(result.unsupportedIds, {1}, reason: problem);
        expect(adapter.requests, hasLength(1));
      }
    });

    test('group todo ownership is opt-in for snoozed=$snoozed', () async {
      final adapter = FakeAdapter((request) {
        _assertOwnershipRead(request, snoozed);
        return jsonResponse(_ownershipPage([_groupOwnershipTodo(1)]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final normal = await (snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze());
      expect(normal.items, isEmpty);
      expect(normal.unsupportedIds, {1});
      final opted = await (snoozed
          ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
          : api.pendingTodosForSnooze(allowGroupTargets: true));
      expect(opted.unsupportedIds, isEmpty);
      expect(opted.items.single, {
        'id': 1, 'target_type': 'WorkItem', 'snoozed_until': null,
        'project': null,
        'namespace': {'id': 'gid://gitlab/Group/2', 'group_id': 2, 'full_path': 'team/sub'},
        'target': {'id': 'gid://gitlab/WorkItem/91', 'iid': 7},
      });
      expect(adapter.requests, hasLength(2));
    });

    test('WorkItem group todo retains its namespace evidence for snoozed=$snoozed', () async {
      for (final missing in [false, true]) {
        final node = _groupOwnershipTodo(1);
        if (missing) {
          node.remove('group');
        } else {
          node['group'] = null;
        }
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          return jsonResponse(_ownershipPage([node]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final read = snoozed
            ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
            : api.pendingTodosForSnooze(allowGroupTargets: true);
        if (missing) {
          await expectLater(read, throwsA(isA<ApiFailure>().having(
            (failure) => failure.kind, 'kind', FailureKind.invalidResponse)));
        } else {
          final result = await read;
          expect(result.items.single['target'], {'id': 'gid://gitlab/WorkItem/91', 'iid': 7});
          expect(result.items.single['namespace'],
              {'id': 'gid://gitlab/Group/2', 'group_id': 2, 'full_path': 'team/sub'});
          expect(result.unsupportedIds, isEmpty);
        }
        expect(adapter.requests, hasLength(1));
      }
    });

    test('WorkItem group todo refuses a foreign Todo group for snoozed=$snoozed', () async {
      for (final field in ['id', 'fullPath']) {
        final node = _groupOwnershipTodo(1);
        (node['group']! as Map<String, Object?>)[field] =
            field == 'id' ? 'gid://gitlab/Group/9' : 'other/sub';
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          return jsonResponse(_ownershipPage([node]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final result = await (snoozed
            ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
            : api.pendingTodosForSnooze(allowGroupTargets: true));
        expect(result.items, isEmpty, reason: field);
        expect(result.unsupportedIds, {1});
        expect(adapter.requests, hasLength(1));
      }
    });

    test('group todo rejects missing and forged ownership evidence for snoozed=$snoozed', () async {
      for (final problem in [
        'outerProjectMissing', 'targetProjectMissing', 'namespaceMissing', 'namespaceNull',
        'groupGidForged', 'groupGidLeadingZero', 'groupGidOverflow', 'groupPathMissing',
        'groupPathInvalid', 'groupDot', 'groupDotDot', 'workItemGidForged', 'workItemGidOverflow',
        'workItemGidTrailingData', 'iidTrailingData', 'iidMissing',
      ]) {
        final node = _groupOwnershipTodo(1);
        final target = node['targetEntity']! as Map<String, Object?>;
        final namespace = target['namespace']! as Map<String, Object?>;
        switch (problem) {
          case 'outerProjectMissing': node.remove('project');
          case 'targetProjectMissing': target.remove('workItemProject');
          case 'namespaceMissing': target.remove('namespace');
          case 'namespaceNull': target['namespace'] = null;
          case 'groupGidForged': namespace['id'] = 'gid://gitlab/WorkItem/2';
          case 'groupGidLeadingZero': namespace['id'] = 'gid://gitlab/Group/02';
          case 'groupGidOverflow': namespace['id'] = 'gid://gitlab/Group/999999999999999999999999999999999';
          case 'groupPathMissing': namespace.remove('fullPath');
          case 'groupPathInvalid': namespace['fullPath'] = 'team//sub';
          case 'groupDot':
            namespace['fullPath'] = 'team/./sub';
            (node['group']! as Map<String, Object?>)['fullPath'] = 'team/./sub';
          case 'groupDotDot':
            namespace['fullPath'] = 'team/../sub';
            (node['group']! as Map<String, Object?>)['fullPath'] = 'team/../sub';
          case 'workItemGidForged': target['workItemId'] = 'gid://gitlab/Group/91';
          case 'workItemGidOverflow': target['workItemId'] = 'gid://gitlab/WorkItem/999999999999999999999999999999999';
          case 'workItemGidTrailingData': target['workItemId'] = 'gid://gitlab/WorkItem/91\n';
          case 'iidTrailingData': target['iid'] = '7\n';
          case 'iidMissing': target.remove('iid');
        }
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          return jsonResponse(_ownershipPage([node]));
        });
        final api = testApi(adapter);
        await expectLater(
          snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
              : api.pendingTodosForSnooze(allowGroupTargets: true),
          throwsA(isA<ApiFailure>().having((failure) => failure.kind, 'kind', FailureKind.invalidResponse)),
          reason: problem,
        );
        expect(adapter.requests, hasLength(1), reason: problem);
        api.close();
      }
    });

    test('project-backed WorkItem requires ProjectNamespace for snoozed=$snoozed', () async {
      final project = {'id': 'gid://gitlab/Project/10', 'fullPath': 'team/sub/repo'};
      final descendant = _groupOwnershipTodo(1)..['project'] = project;
      (descendant['targetEntity']! as Map<String, Object?>)['workItemProject'] = project;
      final forgedOuter = _groupOwnershipTodo(2)..['project'] = project;
      final forgedInner = _groupOwnershipTodo(3);
      (forgedInner['targetEntity']! as Map<String, Object?>)['workItemProject'] = project;
      final unknown = _groupOwnershipTodo(4)..['targetType'] = 'OTHER';
      final validProject = _groupOwnershipTodo(5)..['project'] = project;
      final target = validProject['targetEntity']! as Map<String, Object?>;
      target['workItemProject'] = project;
      target['namespace'] = {'id': 'gid://gitlab/Namespaces::ProjectNamespace/10', 'fullPath': 'team/sub/repo'};
      validProject['group'] = null;
      final adapter = FakeAdapter((request) {
        _assertOwnershipRead(request, snoozed);
        return jsonResponse(_ownershipPage([descendant, forgedOuter, forgedInner, unknown, validProject]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final result = await (snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
          : api.pendingTodosForSnooze(allowGroupTargets: true));
      expect(result.items.single['project'], {'id': 10, 'path_with_namespace': 'team/sub/repo'});
      expect(result.items.single['id'], 5);
      expect(result.items.single.containsKey('namespace'), isFalse);
      expect(result.unsupportedIds, {1, 2, 3, 4});
      expect(adapter.requests, hasLength(1));
    });

    for (final type in ['Issue', 'WorkItem']) {
      for (final allowGroup in [false, true]) {
        for (final problem in [
          'missingGroup', 'notObject', 'missingId', 'missingPath', 'nonStringId',
          'nonStringPath', 'foreignType', 'invalidPath', 'invalidDotPath',
        ]) {
          test('group schema $type $problem allowGroup=$allowGroup snoozed=$snoozed', () async {
            final node = type == 'Issue' ? _groupIssueOwnershipTodo(1) : _groupOwnershipTodo(1);
            final group = node['group']! as Map<String, Object?>;
            switch (problem) {
              case 'missingGroup': node.remove('group');
              case 'notObject': node['group'] = 'team/sub';
              case 'missingId': group.remove('id');
              case 'missingPath': group.remove('fullPath');
              case 'nonStringId': group['id'] = 2;
              case 'nonStringPath': group['fullPath'] = 2;
              case 'foreignType': group['id'] = 'gid://gitlab/Project/2';
              case 'invalidPath': group['fullPath'] = 'team//sub';
              case 'invalidDotPath': group['fullPath'] = 'team//../sub';
            }
            final adapter = FakeAdapter((request) {
              _assertOwnershipRead(request, snoozed);
              return jsonResponse(_ownershipPage([node, _issueOwnershipTodo(2)]));
            });
            final api = testApi(adapter);
            addTearDown(api.close);
            await expectLater(
              snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: allowGroup)
                  : api.pendingTodosForSnooze(allowGroupTargets: allowGroup),
              throwsA(isA<ApiFailure>().having(
                (failure) => failure.kind, 'kind', FailureKind.invalidResponse)),
            );
            expect(adapter.requests, hasLength(1));
          });
        }

        for (final evidence in type == 'Issue' ? ['group'] : ['group', 'namespace']) {
          for (final problem in [
            'leadingZero', 'zero', 'negative', 'overflow', 'trailingData', 'dot', 'dotDot',
          ]) {
            test('disabled group evidence $type $evidence $problem allowGroup=$allowGroup snoozed=$snoozed', () async {
              final node = type == 'Issue' ? _groupIssueOwnershipTodo(1) : _groupOwnershipTodo(1);
              final owner = (evidence == 'group' ? node['group']
                  : (node['targetEntity']! as Map<String, Object?>)['namespace'])! as Map<String, Object?>;
              switch (problem) {
                case 'leadingZero': owner['id'] = 'gid://gitlab/Group/02';
                case 'zero': owner['id'] = 'gid://gitlab/Group/0';
                case 'negative': owner['id'] = 'gid://gitlab/Group/-2';
                case 'overflow': owner['id'] = 'gid://gitlab/Group/999999999999999999999999999999999';
                case 'trailingData': owner['id'] = 'gid://gitlab/Group/2\n';
                case 'dot': owner['fullPath'] = 'team/./sub';
                case 'dotDot': owner['fullPath'] = 'team/../sub';
              }
              final adapter = FakeAdapter((request) {
                _assertOwnershipRead(request, snoozed);
                return jsonResponse(_ownershipPage([node, _issueOwnershipTodo(2)]));
              });
              final api = testApi(adapter);
              addTearDown(api.close);
              final read = snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: allowGroup)
                  : api.pendingTodosForSnooze(allowGroupTargets: allowGroup);
              if (allowGroup) {
                await expectLater(read, throwsA(isA<ApiFailure>().having(
                  (failure) => failure.kind, 'kind', FailureKind.invalidResponse)));
              } else {
                final result = await read;
                expect(result.actorId, 'gid://gitlab/User/3');
                expect(result.items.map((item) => item['id']), [2]);
                expect(result.unsupportedIds, {1});
              }
              expect(adapter.requests, hasLength(1));
            });
          }
        }
      }
    }

    for (final projectOwner in ['outer', 'inner', 'both']) {
      for (final problem in ['leadingZero', 'dot']) {
        for (final allowGroup in [false, true]) {
          test('disabled group namespace with $projectOwner project $problem allowGroup=$allowGroup snoozed=$snoozed', () async {
            final node = _groupOwnershipTodo(1)..['group'] = null;
            final target = node['targetEntity']! as Map<String, Object?>;
            final project = {'id': 'gid://gitlab/Project/10', 'fullPath': 'team/core'};
            if (projectOwner != 'inner') node['project'] = project;
            if (projectOwner != 'outer') target['workItemProject'] = project;
            final namespace = target['namespace']! as Map<String, Object?>;
            if (problem == 'leadingZero') {
              namespace['id'] = 'gid://gitlab/Group/02';
            } else {
              namespace['fullPath'] = 'team/../sub';
            }
            final adapter = FakeAdapter((request) {
              _assertOwnershipRead(request, snoozed);
              return jsonResponse(_ownershipPage([node, _issueOwnershipTodo(2)]));
            });
            final api = testApi(adapter);
            addTearDown(api.close);
            final read = snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: allowGroup)
                : api.pendingTodosForSnooze(allowGroupTargets: allowGroup);
            if (allowGroup) {
              await expectLater(read, throwsA(isA<ApiFailure>().having(
                (failure) => failure.kind, 'kind', FailureKind.invalidResponse)));
            } else {
              final result = await read;
              expect(result.items.map((item) => item['id']), [2]);
              expect(result.unsupportedIds, {1});
            }
            expect(adapter.requests, hasLength(1));
          });
        }
      }
    }

    for (final type in ['Issue', 'MergeRequest', 'WorkItem']) {
      for (final allowGroup in [false, true]) {
        test('project todo refuses non-null group $type allowGroup=$allowGroup snoozed=$snoozed', () async {
          final node = _issueOwnershipTodo(1);
          node['group'] = {'id': 'gid://gitlab/Group/2', 'fullPath': 'team'};
          if (type != 'Issue') {
            node['targetType'] = type == 'MergeRequest' ? 'MERGEREQUEST' : 'WORKITEM';
            node['targetEntity'] = {
              '__typename': type, 'iid': '7',
              if (type == 'MergeRequest') 'mergeRequestId': 'gid://gitlab/MergeRequest/91'
              else 'workItemId': 'gid://gitlab/WorkItem/91',
              if (type == 'MergeRequest') 'mergeRequestProject': node['project']
              else 'workItemProject': node['project'],
              if (type == 'WorkItem') 'namespace': {
                'id': 'gid://gitlab/Namespaces::ProjectNamespace/10', 'fullPath': 'team/core',
              },
            };
          }
          final adapter = FakeAdapter((request) {
            _assertOwnershipRead(request, snoozed);
            return jsonResponse(_ownershipPage([node, _issueOwnershipTodo(2)]));
          });
          final api = testApi(adapter);
          addTearDown(api.close);
          final result = await (snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: allowGroup)
              : api.pendingTodosForSnooze(allowGroupTargets: allowGroup));
          expect(result.items.map((item) => item['id']), [2]);
          expect(result.unsupportedIds, {1});
          expect(adapter.requests, hasLength(1));
        });
      }
    }

    test('group ownership requires a complete fourth page for snoozed=$snoozed', () async {
      for (final complete in [true, false]) {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          expect(_variables(request)['first'], 100);
          expect(_variables(request)['after'], reads == 0 ? null : 'cursor-$reads');
          reads++;
          return jsonResponse(_ownershipPage(
            List.generate(100, (index) => _groupIssueOwnershipTodo((reads - 1) * 100 + index + 1)),
            more: reads < 4 || !complete,
            cursor: 'cursor-$reads',
          ));
        });
        final api = testApi(adapter);
        final result = snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
            : api.pendingTodosForSnooze(allowGroupTargets: true);
        if (complete) {
          expect((await result).items, hasLength(400));
        } else {
          await expectLater(result, throwsA(isA<ApiFailure>().having(
            (failure) => failure.kind, 'kind', FailureKind.invalidResponse)));
        }
        expect(reads, 4);
        expect(adapter.requests, hasLength(4));
        api.close();
      }
    });

    test('group ownership rejects duplicate IDs and invalid cursors for snoozed=$snoozed', () async {
      for (final problem in ['duplicate', 'repeatedCursor', 'missingCursor']) {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          _assertOwnershipRead(request, snoozed);
          reads++;
          return jsonResponse(_ownershipPage(
            [_groupOwnershipTodo(problem == 'duplicate' ? 1 : reads)],
            more: reads == 1 || problem == 'repeatedCursor',
            cursor: problem == 'missingCursor' ? null : 'same',
          ));
        });
        final api = testApi(adapter);
        await expectLater(
          snoozed ? api.snoozedTodosForUnsnooze(allowGroupTargets: true)
              : api.pendingTodosForSnooze(allowGroupTargets: true),
          throwsA(isA<ApiFailure>().having((failure) => failure.kind, 'kind', FailureKind.invalidResponse)),
          reason: problem,
        );
        expect(reads, lessThanOrEqualTo(2), reason: problem);
        api.close();
      }
    });
  }

  group('api', () {
    test('snoozing sends the todo and time and returns what GitLab acknowledged', () async {
      late RequestOptions sent;
      final api = testApi(FakeAdapter((request) {
        sent = request;
        return jsonResponse({'data': {'todoSnooze': {
          'todo': {'id': 'gid://gitlab/Todo/7', 'snoozedUntil': '2030-01-02T09:00:00Z'}, 'errors': <Object>[]}}});
      }));
      addTearDown(api.close);
      final until = DateTime.utc(2030, 1, 2, 9);
      expect(await api.snoozeTodo(7, until), DateTime.utc(2030, 1, 2, 9));
      expect(_graph(sent), isTrue);
      expect(sent.method, 'POST');
      expect(_body(sent)['query'], contains('todoSnooze'));
      expect(_variables(sent), {'id': 'gid://gitlab/Todo/7', 'until': '2030-01-02T09:00:00.000Z'});
    });

    test('a refusal, another todo or an old GitLab fail clearly', () async {
      var reply = <String, Object?>{};
      final api = testApi(FakeAdapter((_) => jsonResponse(reply)));
      addTearDown(api.close);
      final later = DateTime.now().add(const Duration(hours: 1));

      reply = {'data': {'todoSnooze': {'todo': null, 'errors': ['Not allowed']}}};
      await expectLater(api.snoozeTodo(7, later),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.validation)));

      reply = {'data': {'todoSnooze': {'todo': {'id': 'gid://gitlab/Todo/8', 'snoozedUntil': '2030-01-01T00:00:00Z'}, 'errors': <Object>[]}}};
      await expectLater(api.snoozeTodo(7, later),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.invalidResponse)));

      reply = {'errors': [{'message': "Field 'todoSnooze' doesn't exist on type 'Mutation'", 'extensions': {'code': 'undefinedField'}}]};
      await expectLater(api.snoozeTodo(7, later),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.unsupported)));

      await expectLater(api.snoozeTodo(7, DateTime.now().subtract(const Duration(minutes: 1))),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.validation)), reason: 'a past time');
    });

    test('unsnoozing checks the todo came back', () async {
      Object? until;
      final api = testApi(FakeAdapter((_) => jsonResponse({'data': {'todoUnSnooze': {
        'todo': {'id': 'gid://gitlab/Todo/7', 'snoozedUntil': until}, 'errors': <Object>[]}}})));
      addTearDown(api.close);
      await api.unsnoozeTodo(7);
      until = '2030-01-01T00:00:00Z';
      await expectLater(api.unsnoozeTodo(7), throwsA(isA<ApiFailure>()));
    });

    test('snoozed todos come back in the REST shape the inbox renders', () async {
      final api = testApi(FakeAdapter((request) => jsonResponse({'data': {'currentUser': {'todos': {
        'pageInfo': {'hasNextPage': false},
        'nodes': [_snoozedNode(31, 'Review the parser', '2030-01-02T09:00:00Z')],
      }}}})));
      addTearDown(api.close);
      final page = await api.snoozedTodos();
      expect(page.truncated, isFalse);
      expect(page.items.single, {
        'id': 31, 'action_name': 'review_requested', 'target_type': 'MergeRequest',
        'target_url': 'https://example.com/gitlab/team/core/-/merge_requests/31', 'body': 'Review the parser',
        'created_at': '2026-09-20T10:00:00Z', 'updated_at': '2026-09-20T10:00:00Z',
        'snoozed_until': '2030-01-02T09:00:00Z', 'author': {'username': 'lead'},
        'project': {'id': 10, 'path_with_namespace': 'team/core'},
        'target': {'iid': 31, 'title': 'Review the parser'},
      });
    });
  });

  test('presets land in the future at the times they name', () {
    final wednesday = DateTime(2026, 10, 21, 22, 30);
    final presets = {for (final (label, at) in todoSnoozePresets(wednesday)) label: at};
    expect(presets['1 小時後'], DateTime(2026, 10, 21, 23, 30));
    expect(presets['明天上午 9:00'], DateTime(2026, 10, 22, 9));
    expect(presets['下週一上午 9:00'], DateTime(2026, 10, 26, 9));
    final monday = DateTime(2026, 10, 26, 8);
    expect({for (final (label, at) in todoSnoozePresets(monday)) label: at}['下週一上午 9:00'], DateTime(2026, 11, 2, 9),
      reason: 'on a Monday it is the following one');
    expect(todoUntilLabel(DateTime(2026, 10, 21, 23, 5), wednesday), '今天 23:05');
    expect(todoUntilLabel(DateTime(2026, 10, 22, 9), wednesday), '明天 09:00');
    expect(todoUntilLabel(DateTime(2026, 10, 26, 9), wednesday), '10/26 09:00');
  });

  testWidgets('a todo snoozes from its row, can be undone, and the 已延後 list brings one back', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 860);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = [_restTodo(1, 'Crash on start')];
    final snoozed = <Map<String, Object?>>[_snoozedNode(31, 'Review the parser', '2030-01-02T09:00:00Z')];
    final mutations = <(String, Map<String, Object?>)>[];
    final api = testApi(FakeAdapter((request) {
      if (_graph(request)) {
        final query = _body(request)['query']! as String;
        if (query.contains('todoSnooze')) {
          mutations.add(('snooze', _variables(request)));
          pending.clear();
          return jsonResponse({'data': {'todoSnooze': {
            'todo': {'id': _variables(request)['id'], 'snoozedUntil': _variables(request)['until']}, 'errors': <Object>[]}}});
        }
        if (query.contains('todoUnSnooze')) {
          mutations.add(('unsnooze', _variables(request)));
          if (_variables(request)['id'] == 'gid://gitlab/Todo/1') pending.add(_restTodo(1, 'Crash on start'));
          snoozed.removeWhere((node) => node['id'] == _variables(request)['id']);
          return jsonResponse({'data': {'todoUnSnooze': {
            'todo': {'id': _variables(request)['id'], 'snoozedUntil': null}, 'errors': <Object>[]}}});
        }
        return jsonResponse({'data': {'currentUser': {'todos': {'pageInfo': {'hasNextPage': false}, 'nodes': snoozed}}}});
      }
      if (request.uri.path.endsWith('/todos')) return jsonResponse(pending);
      return jsonResponse(<Object>[]);
    }));
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(InboxPage(account: fixture.account, api: api)));
    await settleNetworkWidgets(tester);
    expect(find.text('Crash on start'), findsOneWidget);

    final before = DateTime.now();
    await tester.tap(find.byTooltip('延後此待辦'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('todo-snooze-1 小時後')));
    await settleNetworkWidgets(tester);
    expect(mutations.single.$1, 'snooze');
    expect(mutations.single.$2['id'], 'gid://gitlab/Todo/1');
    final until = DateTime.parse(mutations.single.$2['until']! as String);
    expect(until.difference(before).inMinutes, inInclusiveRange(59, 61));
    expect(find.text('Crash on start'), findsNothing);
    expect(find.textContaining('已延後至'), findsOneWidget);

    await tester.tap(find.text('復原'));
    await settleNetworkWidgets(tester);
    expect(mutations.last.$1, 'unsnooze');
    expect(mutations.last.$2['id'], 'gid://gitlab/Todo/1');
    expect(find.text('Crash on start'), findsOneWidget, reason: '復原 brings it back');

    final chip = find.byKey(const ValueKey('todo-filter-snoozed'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await settleNetworkWidgets(tester);
    expect(find.text('Review the parser'), findsOneWidget);
    expect(find.textContaining('延後至'), findsOneWidget);
    expect(find.byTooltip('延後此待辦'), findsNothing);
    await tester.tap(find.byTooltip('取消延後'));
    await settleNetworkWidgets(tester);
    expect(mutations.last.$1, 'unsnooze');
    expect(mutations.last.$2['id'], 'gid://gitlab/Todo/31');
    expect(find.text('Review the parser'), findsNothing);
    expect(find.text('已移回收件匣'), findsOneWidget);
  });
}
