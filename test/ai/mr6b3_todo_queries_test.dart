import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import '../support/fake_adapter.dart';

Map<String, Object?> _project() => {
  'id': 'gid://gitlab/Project/10', 'fullPath': 'team/core',
};

Map<String, Object?> _todo(int id, {String type = 'WorkItem'}) => {
  'id': 'gid://gitlab/Todo/$id',
  'targetType': {'WorkItem': 'WORKITEM', 'Issue': 'ISSUE', 'MergeRequest': 'MERGEREQUEST'}[type],
  // An expired snooze belongs to the false filter, not just a null value.
  'snoozedUntil': '2020-01-01T00:00:00Z',
  'project': _project(),
  'targetEntity': <String, Object?>{
    '__typename': type, 'id': 'gid://gitlab/$type/91', 'iid': '7',
    'project': _project(),
    if (type == 'WorkItem') 'namespace': {
      'id': 'gid://gitlab/Group/2', 'fullPath': 'team',
    },
  },
};

Object _page(List<Object?> nodes, {bool more = false, String? cursor, int actor = 3}) => {
  'data': {'currentUser': {
    'id': 'gid://gitlab/User/$actor',
    'todos': {
      'nodes': nodes,
      'pageInfo': {'hasNextPage': more, 'endCursor': cursor},
    },
  }},
};

Matcher get _invalid => throwsA(isA<ApiFailure>().having(
  (failure) => failure.kind, 'kind', FailureKind.invalidResponse,
));

void main() {
  for (final snoozed in [false, true]) {
    test('fixed ownership filter $snoozed pages with after and complete identity', () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        final variables = body['variables'] as Map;
        expect(query, contains('state: pending, isSnoozed: $snoozed'));
        expect(query, contains('namespace { id fullPath }'));
        expect(query, contains('project { id fullPath }'));
        expect(variables['first'], 100);
        expect(variables['after'], reads == 0 ? null : 'page-1');
        reads++;
        return jsonResponse(_page([_todo(reads)], more: reads == 1, cursor: reads == 1 ? 'page-1' : null));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final result = await (snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze());
      expect(result.actorId, 'gid://gitlab/User/3');
      expect(result.items.map((item) => item['id']), [1, 2]);
      expect(result.items.first['snoozed_until'], '2020-01-01T00:00:00Z');
      expect(result.items.first['target'], {'id': 'gid://gitlab/WorkItem/91', 'iid': 7});
      expect(reads, 2);
    });
  }

  test('four full pages still requiring continuation refuse without a fifth read', () async {
    var reads = 0;
    final api = testApi(FakeAdapter((_) {
      reads++;
      return jsonResponse(_page(List.generate(100, (index) => _todo((reads - 1) * 100 + index + 1)),
        more: true, cursor: 'page-$reads'));
    }));
    addTearDown(api.close);
    await expectLater(api.pendingTodosForSnooze(), _invalid);
    expect(reads, 4);
  });

  test('actor changes and duplicate todo IDs never produce partial ownership', () async {
    for (final drift in ['actor', 'duplicate', 'cursor', 'missingCursor']) {
      var reads = 0;
      final api = testApi(FakeAdapter((_) {
        reads++;
        return jsonResponse(_page([_todo(drift == 'duplicate' ? 1 : reads)],
          actor: drift == 'actor' && reads == 2 ? 4 : 3,
          more: reads == 1 || drift == 'cursor',
          cursor: drift == 'missingCursor' ? null : 'same'));
      }));
      await expectLater(api.pendingTodosForSnooze(), _invalid, reason: drift);
      expect(reads, lessThanOrEqualTo(2));
      api.close();
    }
  });

  test('ownership accepts project Issue, MergeRequest and WorkItem coordinates', () async {
    final api = testApi(FakeAdapter((_) => jsonResponse(_page([
      _todo(1, type: 'Issue'), _todo(2, type: 'MergeRequest'), _todo(3),
    ]))));
    addTearDown(api.close);
    expect((await api.pendingTodosForSnooze()).items.map((item) => item['target_type']),
      ['Issue', 'MergeRequest', 'WorkItem']);
  });

  test('foreign project, projectless or group work item and malformed identity refuse', () async {
    for (final malformed in ['outerProject', 'innerProject', 'projectless', 'outerProjectless', 'namespace', 'targetType', 'todoId', 'iid', 'commit']) {
      final node = _todo(1);
      final entity = node['targetEntity'] as Map<String, Object?>;
      switch (malformed) {
        case 'outerProject': node['project'] = {'id': 'gid://gitlab/Project/11', 'fullPath': 'other/repo'};
        case 'innerProject': entity['project'] = _project()..['id'] = 'gid://gitlab/Project/11';
        case 'projectless': entity['project'] = null;
        case 'outerProjectless': node['project'] = null; entity['project'] = null;
        case 'namespace': entity['namespace'] = {'id': 'gid://gitlab/Group/5', 'fullPath': 'foreign'};
        case 'targetType': node['targetType'] = 'ISSUE';
        case 'todoId': node['id'] = 'gid://gitlab/Issue/1';
        case 'iid': entity['iid'] = 0;
        case 'commit': node['targetType'] = 'COMMIT'; entity['__typename'] = 'Commit';
      }
      final api = testApi(FakeAdapter((_) => jsonResponse(_page([node]))));
      await expectLater(api.pendingTodosForSnooze(), _invalid, reason: malformed);
      api.close();
    }
  });

  test('bad maxPages rejects before a read; missing schema fails closed', () async {
    var reads = 0;
    final api = testApi(FakeAdapter((_) {
      reads++;
      return jsonResponse({'errors': [{'extensions': {'code': 'undefinedField'}}]});
    }));
    addTearDown(api.close);
    for (final cap in [0, 5]) {
      await expectLater(api.pendingTodosForSnooze(maxPages: cap),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.validation)));
    }
    expect(reads, 0);
    await expectLater(api.snoozedTodosForUnsnooze(),
      throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.unsupported)));
    expect(reads, 1);
  });
}
