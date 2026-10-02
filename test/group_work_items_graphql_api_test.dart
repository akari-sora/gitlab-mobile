import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import 'support/fake_adapter.dart';

const _path = 'gitlab-org';
const _groupId = 'gid://gitlab/Group/server-group';

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _summary({
  String id = 'gid://gitlab/WorkItem/server-item-a',
  Object iid = '7',
  Object? project,
  String namespaceId = _groupId,
  String namespacePath = _path,
}) => {
  'id': id,
  'iid': iid,
  'title': 'Synthetic group work item',
  'state': 'OPEN',
  'createdAt': '2026-09-01T01:02:03Z',
  'updatedAt': '2026-09-02T03:04:05Z',
  'project': project,
  'namespace': {'id': namespaceId, 'fullPath': namespacePath},
  'workItemType': {
    'id': 'gid://gitlab/WorkItems/Type/server-type',
    'name': 'Epic',
  },
};

Map<String, Object?> _connection(
  List<Object?> nodes, {
  bool hasNext = false,
  Object? cursor,
}) => {
  'nodes': nodes,
  'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
};

Map<String, Object?> _envelope({
  Object? workItems,
  String id = _groupId,
  String path = _path,
}) => {
  'data': {
    'group': {'id': id, 'fullPath': path, 'workItems': workItems},
  },
};

void main() {
  test('group page uses the fixed bounded non-descendant query', () async {
    RequestOptions? captured;
    final adapter = FakeAdapter((request) {
      captured = request;
      return jsonResponse(
        _envelope(
          workItems: _connection(
            [_summary()],
            hasNext: true,
            cursor: 'server-cursor+/=',
          ),
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    final page = await api.groupWorkItems(_path);
    final request = captured!;
    expect(request.uri.path, '/gitlab/api/graphql');
    expect(request.followRedirects, isFalse);
    final body = request.data as Map;
    final query = body['query'] as String;
    expect(query, contains('group(fullPath: \$path)'));
    expect(query, contains('sort: CREATED_DESC'));
    expect(query, contains('includeDescendants: false'));
    expect(query, isNot(contains('webUrl')));
    expect(body['variables'], {'path': _path, 'first': 20, 'after': null});

    expect(page.group.id, _groupId);
    expect(page.group.fullPath, _path);
    expect(page.items.single.iid, 7);
    expect(page.items.single.project, isNull);
    expect(page.items.single.namespace?.id, _groupId);
    expect(page.nextCursor, 'server-cursor+/=');
    expect(page.isPartial, isTrue);
    expect(() => page.items.add(page.items.single), throwsUnsupportedError);
  });

  test(
    'continuation is bound to the first page opaque group identity',
    () async {
      final adapter = FakeAdapter((request) {
        expect((request.data as Map)['variables'], {
          'path': _path,
          'first': 20,
          'after': 'issued-cursor',
        });
        return jsonResponse(_envelope(workItems: _connection([_summary()])));
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final page = await api.groupWorkItems(
        _path,
        expectedGroupId: _groupId,
        after: 'issued-cursor',
      );

      expect(page.group.id, _groupId);
      expect(page.nextCursor, isNull);
    },
  );

  test(
    'rejects unbound continuation and invalid input before a request',
    () async {
      final adapter = FakeAdapter((_) => fail('must reject before request'));
      final api = testApi(adapter);
      addTearDown(api.close);

      await expectLater(
        api.groupWorkItems(_path, after: 'issued-cursor'),
        throwsA(_failure(FailureKind.validation)),
      );
      await expectLater(
        api.groupWorkItems('bad path'),
        throwsA(_failure(FailureKind.validation)),
      );
      await expectLater(
        api.groupWorkItems(_path, expectedGroupId: '42'),
        throwsA(_failure(FailureKind.validation)),
      );
      await expectLater(
        api.groupWorkItems(_path, after: '', expectedGroupId: _groupId),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  test('rejects a response for a different group path or opaque ID', () async {
    for (final response in [
      _envelope(path: 'other/group', workItems: _connection([])),
      _envelope(id: 'gid://gitlab/Group/replaced', workItems: _connection([])),
    ]) {
      final api = testApi(FakeAdapter((_) => jsonResponse(response)));
      await expectLater(
        api.groupWorkItems(_path, expectedGroupId: _groupId),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test('rejects project-owned and descendant namespace rows', () async {
    for (final item in [
      _summary(
        project: {
          'id': 'gid://gitlab/Project/server-project',
          'fullPath': 'gitlab-org/descendant',
        },
      ),
      _summary(
        namespaceId: 'gid://gitlab/Group/descendant',
        namespacePath: 'gitlab-org/descendant',
      ),
    ]) {
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse(_envelope(workItems: _connection([item]))),
        ),
      );
      await expectLater(
        api.groupWorkItems(_path),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test('rejects duplicate IDs and duplicate group-scoped IIDs', () async {
    for (final nodes in [
      [_summary(), _summary(iid: '8')],
      [_summary(), _summary(id: 'gid://gitlab/WorkItem/server-item-b')],
    ]) {
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse(_envelope(workItems: _connection(nodes))),
        ),
      );
      await expectLater(
        api.groupWorkItems(_path),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test('rejects oversized pages and malformed or repeated cursors', () async {
    final responses = <Map<String, Object?>>[
      _envelope(
        workItems: _connection(
          List<Object?>.generate(
            21,
            (index) => _summary(
              id: 'gid://gitlab/WorkItem/server-$index',
              iid: '${index + 1}',
            ),
          ),
        ),
      ),
      _envelope(
        workItems: _connection([_summary()], hasNext: true, cursor: null),
      ),
      _envelope(
        workItems: _connection(
          [_summary()],
          hasNext: true,
          cursor: 'issued-cursor',
        ),
      ),
    ];
    for (var index = 0; index < responses.length; index++) {
      final api = testApi(FakeAdapter((_) => jsonResponse(responses[index])));
      await expectLater(
        api.groupWorkItems(
          _path,
          expectedGroupId: index == 2 ? _groupId : null,
          after: index == 2 ? 'issued-cursor' : null,
        ),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test('maps schema, visibility, and connection failures explicitly', () async {
    final cases = <(Map<String, Object?>, FailureKind)>[
      (
        {
          'errors': [
            {
              'extensions': {'code': 'undefinedField'},
            },
          ],
        },
        FailureKind.unsupported,
      ),
      (
        {
          'data': {'group': null},
        },
        FailureKind.invisible,
      ),
      (_envelope(workItems: null), FailureKind.forbidden),
    ];
    for (final (response, expected) in cases) {
      final api = testApi(FakeAdapter((_) => jsonResponse(response)));
      await expectLater(api.groupWorkItems(_path), throwsA(_failure(expected)));
      api.close();
    }
  });

  test(
    'rejects malformed nullable fields and transport response budget',
    () async {
      final malformed = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _envelope(
              workItems: _connection([
                {..._summary(), 'namespace': null},
              ]),
            ),
          ),
        ),
      );
      await expectLater(
        malformed.groupWorkItems(_path),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      malformed.close();

      final oversized = testApi(
        FakeAdapter(
          (_) => ResponseBody.fromString('x' * (4 * 1024 * 1024 + 1), 200),
        ),
      );
      await expectLater(
        oversized.groupWorkItems(_path),
        throwsA(_failure(FailureKind.tooLarge)),
      );
      oversized.close();
    },
  );

  test('account generation and close fences reject stale responses', () async {
    final before = FakeAdapter((_) => fail('must reject before request'));
    final stale = testApi(before);
    await expectLater(
      stale.groupWorkItems(_path, isCurrent: () => false),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(before.requests, isEmpty);
    stale.close();

    var current = true;
    final lateResponse = Completer<ResponseBody>();
    final late = testApi(FakeAdapter((_) => lateResponse.future));
    final operation = late.groupWorkItems(_path, isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    lateResponse.complete(
      jsonResponse(_envelope(workItems: _connection([_summary()]))),
    );
    await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
    late.close();

    final closed = testApi(
      FakeAdapter((_) => jsonResponse(_envelope(workItems: _connection([])))),
    );
    closed.close();
    await expectLater(
      closed.groupWorkItems(_path),
      throwsA(_failure(FailureKind.cancelled)),
    );
  });
}
