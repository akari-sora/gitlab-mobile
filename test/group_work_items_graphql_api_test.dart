import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';

const _path = 'gitlab-org';
const _groupId = 'gid://gitlab/Group/server-group';
const _groupRef = GraphResourceRef(id: _groupId, fullPath: _path);
const _typeId = 'gid://gitlab/WorkItems::Type/server-type';
final _testProject = Project.fromJson(projectJson(42));

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
  test(
    'group page uses bounded variables and legacy filter defaults',
    () async {
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
      expect(query, contains('sort: \$sort'));
      expect(query, contains('includeDescendants: \$includeDescendants'));
      expect(query, contains('state: \$state'));
      expect(query, contains('search: \$search'));
      expect(query, isNot(contains('workItemTypeIds:')));
      expect(query, isNot(contains('webUrl')));
      expect(query, isNot(contains('widgets')));
      expect(body['variables'], {
        'path': _path,
        'first': 20,
        'after': null,
        'includeDescendants': false,
        'state': 'all',
        'search': '',
        'sort': 'CREATED_DESC',
      });

      expect(page.group.id, _groupId);
      expect(page.group.fullPath, _path);
      expect(page.items.single.iid, 7);
      expect(page.items.single.project, isNull);
      expect(page.items.single.namespace?.id, _groupId);
      expect(page.nextCursor, 'server-cursor+/=');
      expect(page.isPartial, isTrue);
      expect(page.filter, const GroupWorkItemListFilter());
      expect(() => page.items.add(page.items.single), throwsUnsupportedError);
    },
  );

  test(
    'continuation is bound to the first page opaque group identity',
    () async {
      final adapter = FakeAdapter((request) {
        expect((request.data as Map)['variables'], {
          'path': _path,
          'first': 20,
          'after': 'issued-cursor',
          'includeDescendants': false,
          'state': 'all',
          'search': '',
          'sort': 'CREATED_DESC',
        });
        return jsonResponse(_envelope(workItems: _connection([_summary()])));
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final page = await api.groupWorkItems(
        _path,
        expectedGroupId: _groupId,
        after: 'issued-cursor',
        previousFilter: const GroupWorkItemListFilter(),
      );

      expect(page.group.id, _groupId);
      expect(page.nextCursor, isNull);
    },
  );

  test(
    'sends normalized state, search, sort, type and descendant controls',
    () async {
      RequestOptions? captured;
      final api = testApi(
        FakeAdapter((request) {
          captured = request;
          return jsonResponse(
            _envelope(
              workItems: _connection([
                _summary(
                  id: 'gid://gitlab/WorkItem/project-item',
                  namespaceId: 'gid://gitlab/Namespaces::ProjectNamespace/123',
                  namespacePath: 'gitlab-org/subgroup/project',
                  project: {
                    'id': 'gid://gitlab/Project/123',
                    'fullPath': 'gitlab-org/subgroup/project',
                  },
                ),
              ]),
            ),
          );
        }),
      );
      addTearDown(api.close);

      const filter = GroupWorkItemListFilter(
        includeDescendants: true,
        state: GroupWorkItemState.opened,
        search: '  roadmap  ',
        sort: GroupWorkItemSort.updatedAsc,
        typeId: _typeId,
        typeNamespace: _groupRef,
      );
      final page = await api.groupWorkItems(_path, filter: filter);
      final body = captured!.data as Map;
      final query = body['query'] as String;
      expect(query, contains('\$typeIds: [WorkItemsTypeID!]'));
      expect(query, contains('workItemTypeIds: \$typeIds'));
      expect(body['variables'], {
        'path': _path,
        'first': 20,
        'after': null,
        'includeDescendants': true,
        'state': 'opened',
        'search': 'roadmap',
        'sort': 'UPDATED_ASC',
        'typeIds': [_typeId],
      });
      expect(page.filter.search, 'roadmap');
      expect(page.filter, isNot(same(filter)));
      expect(page.filter.typeNamespace?.id, _groupId);
      expect(
        page.items.single.project?.fullPath,
        'gitlab-org/subgroup/project',
      );
    },
  );

  test('allows same IID in distinct descendant namespaces', () async {
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse(
          _envelope(
            workItems: _connection([
              _summary(
                id: 'gid://gitlab/WorkItem/a',
                namespaceId: 'gid://gitlab/Group/a',
                namespacePath: 'gitlab-org/a',
              ),
              _summary(
                id: 'gid://gitlab/WorkItem/b',
                namespaceId: 'gid://gitlab/Group/b',
                namespacePath: 'gitlab-org/b',
              ),
            ]),
          ),
        ),
      ),
    );
    addTearDown(api.close);

    final page = await api.groupWorkItems(
      _path,
      filter: const GroupWorkItemListFilter(includeDescendants: true),
    );
    expect(page.items, hasLength(2));
  });

  test('rejects changed continuation filter before network', () async {
    final adapter = FakeAdapter((_) => fail('must reject before request'));
    final api = testApi(adapter);
    addTearDown(api.close);

    await expectLater(
      api.groupWorkItems(
        _path,
        expectedGroupId: _groupId,
        after: 'issued-cursor',
        filter: const GroupWorkItemListFilter(search: 'new'),
        previousFilter: const GroupWorkItemListFilter(search: 'old'),
      ),
      throwsA(_failure(FailureKind.validation)),
    );
    await expectLater(
      api.groupWorkItems(
        _path,
        expectedGroupId: _groupId,
        after: 'issued-cursor',
      ),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests, isEmpty);
  });

  test('rejects malformed filter values before network', () async {
    final adapter = FakeAdapter((_) => fail('must reject before request'));
    final api = testApi(adapter);
    addTearDown(api.close);

    for (final filter in [
      GroupWorkItemListFilter(search: 'x' * 257),
      const GroupWorkItemListFilter(typeId: ''),
      const GroupWorkItemListFilter(typeId: 'https://example.test/type'),
      const GroupWorkItemListFilter(typeId: 'gid://gitlab/Type/a?cursor=x'),
      const GroupWorkItemListFilter(
        typeId: 'gid://gitlab/WorkItems/Type/server-type',
        typeNamespace: _groupRef,
      ),
      const GroupWorkItemListFilter(typeId: _typeId),
      const GroupWorkItemListFilter(
        typeId: _typeId,
        typeNamespace: GraphResourceRef(
          id: 'gid://gitlab/Project/123',
          fullPath: _path,
        ),
      ),
      const GroupWorkItemListFilter(
        typeId: _typeId,
        typeNamespace: GraphResourceRef(id: _groupId, fullPath: 'other/group'),
      ),
    ]) {
      await expectLater(
        api.groupWorkItems(_path, filter: filter),
        throwsA(_failure(FailureKind.validation)),
      );
    }
    await expectLater(
      api.groupWorkItems(
        _path,
        expectedGroupId: _groupId,
        filter: const GroupWorkItemListFilter(
          typeId: _typeId,
          typeNamespace: GraphResourceRef(
            id: 'gid://gitlab/Group/other',
            fullPath: _path,
          ),
        ),
      ),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests, isEmpty);
  });

  test('type namespace binds the first response group identity', () async {
    final valid = testApi(
      FakeAdapter(
        (_) => jsonResponse(_envelope(workItems: _connection([_summary()]))),
      ),
    );
    addTearDown(valid.close);
    final page = await valid.groupWorkItems(
      _path,
      filter: const GroupWorkItemListFilter(
        typeId: _typeId,
        typeNamespace: _groupRef,
      ),
    );
    expect(page.group.id, _groupId);

    final replaced = testApi(
      FakeAdapter(
        (_) => jsonResponse(
          _envelope(
            id: 'gid://gitlab/Group/replaced',
            workItems: _connection([]),
          ),
        ),
      ),
    );
    addTearDown(replaced.close);
    await expectLater(
      replaced.groupWorkItems(
        _path,
        filter: const GroupWorkItemListFilter(
          typeId: _typeId,
          typeNamespace: _groupRef,
        ),
      ),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test('clears an unused type namespace from the normalized filter', () async {
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse(_envelope(workItems: _connection([_summary()]))),
      ),
    );
    addTearDown(api.close);

    final page = await api.groupWorkItems(
      _path,
      filter: const GroupWorkItemListFilter(typeNamespace: _groupRef),
    );
    expect(page.filter.typeId, isNull);
    expect(page.filter.typeNamespace, isNull);
  });

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
        api.groupWorkItems(_path, expectedGroupId: 'gid://gitlab/Project/42'),
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
      _envelope(
        id: 'gid://gitlab/Project/server-group',
        workItems: _connection([]),
      ),
    ]) {
      final api = testApi(FakeAdapter((_) => jsonResponse(response)));
      await expectLater(
        api.groupWorkItems(_path, expectedGroupId: _groupId),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test(
    'rejects descendants unless requested and rejects identity mismatch',
    () async {
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

      for (final item in [
        _summary(
          namespaceId: 'gid://gitlab/Group/sibling',
          namespacePath: 'gitlab-org-other/subgroup',
        ),
        _summary(
          namespaceId: 'gid://gitlab/Group/subgroup',
          namespacePath: 'gitlab-org/subgroup',
          project: {
            'id': 'gid://gitlab/Project/123',
            'fullPath': 'gitlab-org/other/project',
          },
        ),
        _summary(
          namespaceId: 'gid://gitlab/Group/not-a-project-namespace',
          namespacePath: 'gitlab-org/subgroup/project',
          project: {
            'id': 'gid://gitlab/Project/123',
            'fullPath': 'gitlab-org/subgroup/project',
          },
        ),
        {..._summary(), 'namespace': null},
      ]) {
        final api = testApi(
          FakeAdapter(
            (_) => jsonResponse(_envelope(workItems: _connection([item]))),
          ),
        );
        await expectLater(
          api.groupWorkItems(
            _path,
            filter: const GroupWorkItemListFilter(includeDescendants: true),
          ),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }
    },
  );

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
          previousFilter: index == 2 ? const GroupWorkItemListFilter() : null,
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

    current = true;
    final lateError = Completer<ResponseBody>();
    final errorStarted = Completer<void>();
    final errored = testApi(
      FakeAdapter((_) {
        errorStarted.complete();
        return lateError.future;
      }),
    );
    final errorOperation = errored.groupWorkItems(
      _path,
      isCurrent: () => current,
    );
    final errorExpectation = expectLater(
      errorOperation,
      throwsA(_failure(FailureKind.cancelled)),
    );
    await errorStarted.future;
    current = false;
    lateError.completeError(StateError('synthetic transport failure'));
    await errorExpectation;
    errored.close();

    current = true;
    final lateHttp = Completer<ResponseBody>();
    final httpStarted = Completer<void>();
    final http = testApi(
      FakeAdapter((_) {
        httpStarted.complete();
        return lateHttp.future;
      }),
    );
    final httpOperation = http.groupWorkItems(_path, isCurrent: () => current);
    final httpExpectation = expectLater(
      httpOperation,
      throwsA(_failure(FailureKind.cancelled)),
    );
    await httpStarted.future;
    current = false;
    lateHttp.complete(jsonResponse(const {}, status: 500));
    await httpExpectation;
    http.close();

    final closed = testApi(
      FakeAdapter((_) => jsonResponse(_envelope(workItems: _connection([])))),
    );
    closed.close();
    await expectLater(
      closed.groupWorkItems(_path),
      throwsA(_failure(FailureKind.cancelled)),
    );
  });

  test(
    'T09: Project cursor with altered filter or tier mismatch throws validation with zero network calls',
    () async {
      final adapter = FakeAdapter((_) => fail('must not send request'));
      final api = testApi(adapter);
      addTearDown(api.close);

      const filter1 = GroupWorkItemListFilter(state: GroupWorkItemState.opened);
      const filter2 = GroupWorkItemListFilter(state: GroupWorkItemState.closed);

      await expectLater(
        api.groupWorkItems(
          _path,
          expectedGroupId: _groupId,
          after: 'cursor-1',
          filter: filter1,
          previousFilter: filter2,
        ),
        throwsA(_failure(FailureKind.validation)),
      );

      await expectLater(
        api.groupWorkItems(
          _path,
          expectedGroupId: _groupId,
          after: 'cursor-1',
          filter: filter1,
          previousFilter: null,
        ),
        throwsA(_failure(FailureKind.validation)),
      );

      await expectLater(
        api.groupWorkItems(
          _path,
          expectedGroupId: _groupId,
          after: null,
          summaries: true,
          previousTier: 2,
        ),
        throwsA(_failure(FailureKind.validation)),
      );

      await expectLater(
        api.groupWorkItems(
          _path,
          expectedGroupId: _groupId,
          after: 'cursor-1',
          filter: filter1,
          previousFilter: filter1,
          summaries: true,
          previousTier: null,
        ),
        throwsA(_failure(FailureKind.validation)),
      );

      await expectLater(
        api.projectWorkItems(
          _testProject,
          after: 'cursor-1',
          filter: filter1,
          previousFilter: filter2,
        ),
        throwsA(_failure(FailureKind.validation)),
      );

      await expectLater(
        api.projectWorkItems(
          _testProject,
          after: 'cursor-1',
          filter: filter1,
          previousFilter: null,
        ),
        throwsA(_failure(FailureKind.validation)),
      );

      await expectLater(
        api.projectWorkItems(
          _testProject,
          after: 'cursor-1',
          filter: null,
          previousFilter: filter1,
        ),
        throwsA(_failure(FailureKind.validation)),
      );

      await expectLater(
        api.projectWorkItems(
          _testProject,
          after: 'cursor-1',
          summaries: true,
          previousTier: null,
        ),
        throwsA(_failure(FailureKind.validation)),
      );

      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'T10: isCurrent returning false before fallback re-POST cancels without second POST',
    () async {
      var callCount = 0;
      var activeCurrent = true;
      final adapter = FakeAdapter((request) {
        callCount++;
        activeCurrent = false;
        return jsonResponse({
          'data': null,
          'errors': [
            {
              'message': 'Type WorkItemWidgetStatus is unknown',
              'extensions': {
                'code': 'undefinedType',
                'typeName': 'WorkItemWidgetStatus',
              },
            },
          ],
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await expectLater(
        api.groupWorkItems(
          _path,
          summaries: true,
          isCurrent: () => activeCurrent,
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(callCount, 1);
    },
  );
}
