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

List<Map<String, Object?>> _mixedTodos() => [
  _todo(1),
  _todo(2)..['project'] = null
    ..['targetEntity'] = {
      '__typename': 'WorkItem', 'id': 'gid://gitlab/WorkItem/92', 'iid': '8',
      'project': null,
      'namespace': {'id': 'gid://gitlab/Group/2', 'fullPath': 'team'},
    },
  _todo(3)..['targetType'] = 'COMMIT'
    ..['targetEntity'] = {'__typename': 'Commit'},
  _todo(4)..['targetType'] = 'EPIC'
    ..['targetEntity'] = {'__typename': 'Epic'},
  _todo(5, type: 'Issue')..['project'] = null
    ..['targetEntity'] = {
      '__typename': 'Issue', 'id': 'gid://gitlab/Issue/93', 'iid': '9', 'project': null,
    },
  _todo(6)..['project'] = {'id': 'gid://gitlab/Project/11', 'fullPath': 'other/repo'},
  _todo(7)..['targetEntity'] = {
    '__typename': 'WorkItem', 'id': 'gid://gitlab/WorkItem/94', 'iid': '10',
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/2', 'fullPath': 'team'},
  },
  _todo(8)..['targetType'] = 'DESIGN'
    ..['targetEntity'] = {'__typename': 'Design'},
  _todo(9, type: 'Issue'),
];

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
      expect(result.unsupportedIds, isEmpty);
      expect(reads, 2);
    });

    for (final pages in [1, 2]) {
      test('mixed ownership page set $snoozed over $pages pages classifies each ID', () async {
        final nodes = _mixedTodos();
        var reads = 0;
        final api = testApi(FakeAdapter((request) {
          final variables = (request.data as Map)['variables'] as Map;
          expect(variables['after'], reads == 0 ? null : 'mixed-1');
          final first = reads++ == 0;
          return jsonResponse(_page(
            pages == 1 ? nodes : first ? nodes.sublist(0, 3) : nodes.sublist(3),
            more: pages == 2 && first,
            cursor: pages == 2 && first ? 'mixed-1' : null,
          ));
        }));
        addTearDown(api.close);
        final result = await (snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze());
        expect(result.actorId, 'gid://gitlab/User/3');
        expect(result.items.map((item) => item['id']), [1, 9]);
        expect(result.items.first['project'], {'id': 10, 'path_with_namespace': 'team/core'});
        expect(result.items.first['target'], {'id': 'gid://gitlab/WorkItem/91', 'iid': 7});
        expect(result.unsupportedIds, {2, 3, 4, 5, 6, 7, 8});
        // P13 can reject known unsupported IDs separately from absent/foreign IDs.
        expect(result.unsupportedIds.contains(2), isTrue);
        expect(result.unsupportedIds.contains(99), isFalse);
        expect(result.items.any((item) => item['id'] == 99), isFalse);
        expect(result.items.length + result.unsupportedIds.length, nodes.length);
        expect(() => result.unsupportedIds.add(99), throwsUnsupportedError);
        expect(reads, pages);
      });
    }
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

  test('well-formed unsupported targets remain known without usable ownership', () async {
    // These used to fail the whole set; they now carry an explicit per-ID refusal.
    for (final unsupported in ['outerProject', 'innerProject', 'projectless', 'outerProjectless', 'namespace', 'targetType', 'commit', 'missingEntity']) {
      final node = _todo(1);
      final entity = node['targetEntity'] as Map<String, Object?>;
      switch (unsupported) {
        case 'outerProject': node['project'] = {'id': 'gid://gitlab/Project/11', 'fullPath': 'other/repo'};
        case 'innerProject': entity['project'] = _project()..['id'] = 'gid://gitlab/Project/11';
        case 'projectless': entity['project'] = null;
        case 'outerProjectless': node['project'] = null; entity['project'] = null;
        case 'namespace': entity['namespace'] = {'id': 'gid://gitlab/Group/5', 'fullPath': 'foreign'};
        case 'targetType': node['targetType'] = 'ISSUE';
        case 'commit': node['targetType'] = 'COMMIT'; node['targetEntity'] = {'__typename': 'Commit'};
        case 'missingEntity': node['targetEntity'] = null;
      }
      final api = testApi(FakeAdapter((_) => jsonResponse(_page([node]))));
      final result = await api.pendingTodosForSnooze();
      expect(result.items, isEmpty, reason: unsupported);
      expect(result.unsupportedIds, {1}, reason: unsupported);
      api.close();
    }
  });

  test('malformed nodes still invalidate a mixed ownership set', () async {
    for (final malformed in ['todoId', 'iid', 'entityId', 'projectShape', 'projectId', 'projectPath',
      'innerProjectShape', 'innerProjectId', 'innerProjectPath', 'entityShape', 'entityType',
      'targetType', 'namespaceShape', 'snoozeTime', 'missingProject', 'missingEntity', 'missingTime']) {
      final node = _todo(10);
      final entity = node['targetEntity'] as Map<String, Object?>;
      switch (malformed) {
        case 'todoId': node['id'] = 'gid://gitlab/Issue/10';
        case 'iid': entity['iid'] = 0;
        case 'entityId': entity['id'] = 'gid://gitlab/Issue/91';
        case 'projectShape': node['project'] = 'invalid';
        case 'projectId': (node['project'] as Map)['id'] = 'gid://gitlab/Group/10';
        case 'projectPath': (node['project'] as Map)['fullPath'] = 'team//invalid';
        case 'innerProjectShape': entity['project'] = 10;
        case 'innerProjectId': (entity['project'] as Map)['id'] = 'gid://gitlab/Group/10';
        case 'innerProjectPath': (entity['project'] as Map)['fullPath'] = 'team//invalid';
        case 'entityShape': node['targetEntity'] = 'invalid';
        case 'entityType': entity.remove('__typename');
        case 'targetType': node['targetType'] = null;
        case 'namespaceShape': entity['namespace'] = 'invalid';
        case 'snoozeTime': node['snoozedUntil'] = 'invalid';
        case 'missingProject': node.remove('project');
        case 'missingEntity': node.remove('targetEntity');
        case 'missingTime': node.remove('snoozedUntil');
      }
      final api = testApi(FakeAdapter((_) => jsonResponse(_page([..._mixedTodos(), node]))));
      await expectLater(api.pendingTodosForSnooze(), _invalid, reason: malformed);
      api.close();
    }
  });

  for (final snoozed in [false, true]) {
    test('unsupported IDs still participate in envelope validation $snoozed', () async {
      for (final drift in ['actor', 'duplicateUnsupported', 'duplicateSupported', 'cursor', 'missingCursor', 'oversized']) {
        var reads = 0;
        final api = testApi(FakeAdapter((_) {
          final first = reads++ == 0;
          final unsupported = _mixedTodos()[2];
          if (drift == 'duplicateSupported') unsupported['id'] = 'gid://gitlab/Todo/1';
          return jsonResponse(_page(
            drift == 'oversized' ? List.generate(101, (i) => _todo(i + 1)) :
              first ? [_todo(1), unsupported] : [unsupported],
            actor: drift == 'actor' && !first ? 4 : 3,
            more: first || drift == 'cursor',
            cursor: drift == 'missingCursor' ? null : 'same',
          ));
        }));
        await expectLater(snoozed ? api.snoozedTodosForUnsnooze() : api.pendingTodosForSnooze(),
          _invalid, reason: drift);
        expect(reads, lessThanOrEqualTo(2));
        api.close();
      }
    });
  }

  test('400 unsupported IDs still require a terminal page within the cap', () async {
    var reads = 0;
    final api = testApi(FakeAdapter((_) {
      final offset = reads++ * 100;
      return jsonResponse(_page(List.generate(100, (i) => {
        ..._mixedTodos()[2], 'id': 'gid://gitlab/Todo/${offset + i + 1}',
      }), more: true, cursor: 'page-$reads'));
    }));
    addTearDown(api.close);
    await expectLater(api.snoozedTodosForUnsnooze(), _invalid);
    expect(reads, 4);
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
