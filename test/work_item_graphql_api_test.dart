import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';

import 'support/fake_adapter.dart';

final _project = Project.fromJson(projectJson(42));

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _summary({
  String id = 'gid://gitlab/FutureWorkItem/server-owned-a',
  Object iid = '7',
  int projectId = 42,
  String? projectPath,
  String? namespaceId,
  String? namespacePath,
  String typeId = 'gid://gitlab/FutureType/server-owned-type',
  String typeName = 'Task',
  String createdAt = '2026-09-01T01:02:03Z',
  String updatedAt = '2026-09-02T03:04:05+00:00',
}) => {
  'id': id,
  'iid': iid,
  'title': 'Synthetic work item',
  'state': 'OPEN',
  'createdAt': createdAt,
  'updatedAt': updatedAt,
  'project': {
    'id': 'gid://gitlab/Project/$projectId',
    'fullPath': projectPath ?? 'team/example-$projectId',
  },
  'namespace': {
    'id': namespaceId ?? 'gid://gitlab/FutureNamespace/server-owned-ns',
    'fullPath': namespacePath ?? projectPath ?? 'team/example-$projectId',
  },
  'workItemType': {'id': typeId, 'name': typeName},
};

Map<String, Object?> _detail({
  List<Object?>? widgets,
  String? namespaceId,
  String? namespacePath,
}) => {
  ..._summary(namespaceId: namespaceId, namespacePath: namespacePath),
  'description': 'Raw **Markdown** only',
  'widgets':
      widgets ??
      [
        {
          'type': 'DESCRIPTION',
          'description': 'Raw **Markdown** only',
          'edited': true,
          'lastEditedAt': '2026-09-02T03:00:00Z',
        },
        {
          'type': 'ASSIGNEES',
          'assignees': {
            'nodes': [
              {
                'id': 'gid://gitlab/FutureUser/server-user',
                'name': 'Synthetic User',
                'username': 'synthetic',
                'avatarUrl': null,
              },
            ],
            'pageInfo': {'hasNextPage': true, 'endCursor': 'assignees-next'},
          },
        },
        {
          'type': 'LABELS',
          'labels': {
            'nodes': [
              {
                'id': 'gid://gitlab/FutureLabel/server-label',
                'title': 'mobile',
                'color': '#123456',
                'description': null,
                'textColor': '#ffffff',
              },
            ],
            'pageInfo': {'hasNextPage': false, 'endCursor': 'last-label'},
          },
        },
        {
          'type': 'HIERARCHY',
          'hasParent': false,
          'hasChildren': true,
          'parent': null,
          'children': {
            'nodes': [
              _summary(
                id: 'gid://gitlab/FutureWorkItem/server-child',
                iid: '8',
              ),
            ],
            'pageInfo': {'hasNextPage': true, 'endCursor': 'children-next'},
          },
        },
        {
          'type': 'START_AND_DUE_DATE',
          'startDate': '2026-09-03',
          'dueDate': null,
          'rollUp': false,
        },
        {'type': 'FUTURE_WIDGET'},
      ],
};

Map<String, Object?> _projectEnvelope({
  required Object? workItems,
  int projectId = 42,
  String? projectPath,
}) => {
  'data': {
    'project': {
      'id': 'gid://gitlab/Project/$projectId',
      'fullPath': projectPath ?? 'team/example-$projectId',
      'workItems': workItems,
    },
  },
};

Map<String, Object?> _namespaceEnvelope({
  required String namespaceId,
  required String namespacePath,
  required Map<String, Object?> detail,
}) => {
  'data': {
    'namespace': {
      'id': namespaceId,
      'fullPath': namespacePath,
      'workItem': detail,
    },
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

void main() {
  test(
    'project list uses fixed bounded pagination and server project binding',
    () async {
      final adapter = FakeAdapter((request) {
        expect(request.uri.path, '/gitlab/api/graphql');
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer synthetic-test-token');
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        final body = request.data as Map;
        expect(body['query'], isNot(contains('webUrl')));
        expect(body['variables'], {
          'path': _project.path,
          'first': 20,
          'after': null,
        });
        return jsonResponse(
          _projectEnvelope(
            workItems: _connection(
              [_summary()],
              hasNext: true,
              cursor: 'opaque+/=',
            ),
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final page = await api.projectWorkItems(_project);

      expect(page.items.single.iid, 7);
      expect(page.items.single.type.name, 'Task');
      expect(page.nextCursor, 'opaque+/=');
      expect(page.isPartial, isTrue);
    },
  );

  test(
    'project root numeric ID and child opaque project ID are both bound',
    () async {
      Future<void> expectInvalid(Object response) async {
        final api = testApi(FakeAdapter((_) => jsonResponse(response)));
        await expectLater(
          api.projectWorkItems(_project),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }

      await expectInvalid(
        _projectEnvelope(
          projectId: 41,
          projectPath: _project.path,
          workItems: _connection([_summary()]),
        ),
      );
      await expectInvalid(
        _projectEnvelope(workItems: _connection([_summary(projectId: 41)])),
      );
      await expectInvalid(
        _projectEnvelope(
          workItems: _connection([_summary(typeId: 'gid://gitlab/Project/42')]),
        ),
      );
    },
  );

  test(
    'timestamps preserve valid offsets and reject normalized dates',
    () async {
      final valid = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _projectEnvelope(
              workItems: _connection([
                _summary(createdAt: '2026-09-01T09:02:03.123456+08:00'),
              ]),
            ),
          ),
        ),
      );
      expect(
        (await valid.projectWorkItems(_project)).items.single.createdAt,
        DateTime.utc(2026, 9, 1, 1, 2, 3, 123, 456),
      );
      valid.close();

      for (final timestamp in [
        '2026-02-30T01:02:03Z',
        '2026-01-01T24:00:00Z',
        '2026-13-01T01:02:03Z',
        '2026-01-01T01:02:03+24:00',
      ]) {
        final invalid = testApi(
          FakeAdapter(
            (_) => jsonResponse(
              _projectEnvelope(
                workItems: _connection([_summary(createdAt: timestamp)]),
              ),
            ),
          ),
        );
        await expectLater(
          invalid.projectWorkItems(_project),
          throwsA(_failure(FailureKind.invalidResponse)),
          reason: timestamp,
        );
        invalid.close();
      }
    },
  );

  test(
    'detail exposes only raw description and explicit partial widgets',
    () async {
      final responseDetail = _detail();
      final api = testApi(
        FakeAdapter((request) {
          expect((request.data as Map)['query'], isNot(contains('webUrl')));
          return jsonResponse(
            _projectEnvelope(workItems: _connection([responseDetail])),
          );
        }),
      );
      addTearDown(api.close);

      final detail = await api.projectWorkItem(_project, 7);

      expect(detail.description, 'Raw **Markdown** only');
      expect(detail.descriptionWidget!.edited, isTrue);
      expect(detail.assignees!.assignees!.isPartial, isTrue);
      expect(detail.assignees!.assignees!.items.single.username, 'synthetic');
      expect(detail.labels!.labels!.isPartial, isFalse);
      expect(detail.hierarchy!.children!.isPartial, isTrue);
      expect(detail.hierarchy!.hasChildren, isTrue);
      expect(detail.dates!.startDate, DateTime.utc(2026, 9, 3));
      expect(detail.widgetTypes, contains('FUTURE_WIDGET'));
    },
  );

  test(
    'null widgets and null widget connection remain explicit unknowns',
    () async {
      var call = 0;
      final api = testApi(
        FakeAdapter((_) {
          call++;
          return jsonResponse(
            _projectEnvelope(
              workItems: _connection([
                call == 1
                    ? {..._detail(), 'widgets': null}
                    : _detail(
                        widgets: [
                          {'type': 'ASSIGNEES', 'assignees': null},
                        ],
                      ),
              ]),
            ),
          );
        }),
      );
      addTearDown(api.close);

      expect(
        (await api.projectWorkItem(_project, 7)).widgetsAvailable,
        isFalse,
      );
      final second = await api.projectWorkItem(_project, 7);
      expect(second.widgetsAvailable, isTrue);
      expect(second.assignees!.assignees, isNull);
    },
  );

  for (final avatarPath in [
    '/uploads/-/system/user/avatar/7/example.png',
    '/gitlab/uploads/-/system/user/avatar/7/example.png',
  ]) {
    test(
      'unused relative assignee avatar $avatarPath cannot block detail',
      () async {
        final adapter = FakeAdapter(
          (_) => jsonResponse(
            _projectEnvelope(
              workItems: _connection([
                _detail(
                  widgets: [
                    {
                      'type': 'ASSIGNEES',
                      'assignees': _connection([
                        {
                          'id': 'gid://gitlab/FutureUser/server-user',
                          'name': 'Synthetic User',
                          'username': 'synthetic',
                          'avatarUrl': avatarPath,
                        },
                      ]),
                    },
                  ],
                ),
              ]),
            ),
          ),
        );
        final api = testApi(adapter);
        addTearDown(api.close);

        final detail = await api.projectWorkItem(_project, 7);

        expect(detail.assignees!.assignees!.items.single.username, 'synthetic');
        expect(adapter.requests, hasLength(1));
        expect(
          (adapter.requests.single.data as Map)['query'],
          isNot(contains('avatarUrl')),
        );
      },
    );
  }

  test(
    'nested widget connections reject duplicate server identities',
    () async {
      Future<void> expectInvalidWidget(Map<String, Object?> widget) async {
        final api = testApi(
          FakeAdapter(
            (_) => jsonResponse(
              _projectEnvelope(
                workItems: _connection([
                  _detail(widgets: [widget]),
                ]),
              ),
            ),
          ),
        );
        await expectLater(
          api.projectWorkItem(_project, 7),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }

      final assignee = {
        'id': 'gid://gitlab/FutureUser/repeated',
        'name': 'Synthetic User',
        'username': 'synthetic',
        'avatarUrl': null,
      };
      await expectInvalidWidget({
        'type': 'ASSIGNEES',
        'assignees': _connection([
          assignee,
          {...assignee},
        ]),
      });

      final label = {
        'id': 'gid://gitlab/FutureLabel/repeated',
        'title': 'mobile',
        'color': '#123456',
        'description': null,
        'textColor': '#ffffff',
      };
      await expectInvalidWidget({
        'type': 'LABELS',
        'labels': _connection([
          label,
          {...label},
        ]),
      });

      await expectInvalidWidget({
        'type': 'HIERARCHY',
        'hasParent': false,
        'hasChildren': true,
        'parent': null,
        'children': _connection([
          _summary(id: 'gid://gitlab/FutureWorkItem/repeated', iid: '8'),
          _summary(id: 'gid://gitlab/FutureWorkItem/repeated', iid: '9'),
        ]),
      });

      await expectInvalidWidget({
        'type': 'HIERARCHY',
        'hasParent': false,
        'hasChildren': true,
        'parent': null,
        'children': _connection([
          _summary(id: 'gid://gitlab/FutureWorkItem/first', iid: '8'),
          _summary(id: 'gid://gitlab/FutureWorkItem/second', iid: '8'),
        ]),
      });
    },
  );

  test('hierarchy allows the same IID in distinct namespaces', () async {
    final widgets = [
      {
        'type': 'HIERARCHY',
        'hasParent': false,
        'hasChildren': true,
        'parent': null,
        'children': _connection([
          _summary(
            id: 'gid://gitlab/FutureWorkItem/first',
            iid: '8',
            namespaceId: 'gid://gitlab/FutureNamespace/first',
          ),
          _summary(
            id: 'gid://gitlab/FutureWorkItem/second',
            iid: '8',
            projectId: 43,
            namespaceId: 'gid://gitlab/FutureNamespace/second',
          ),
        ]),
      },
    ];
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse(
          _projectEnvelope(workItems: _connection([_detail(widgets: widgets)])),
        ),
      ),
    );
    addTearDown(api.close);

    final children = (await api.projectWorkItem(
      _project,
      7,
    )).hierarchy!.children!.items;
    expect(children.map((child) => child.iid), [8, 8]);
  });

  test(
    'namespace detail binds returned namespace and supports group identity',
    () async {
      const groupPath = 'team/group';
      const groupId = 'gid://gitlab/Group/server-owned-group';
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        expect(body['variables'], {'path': groupPath, 'iid': '7'});
        final detail = _detail(namespaceId: groupId, namespacePath: groupPath)
          ..['project'] = null;
        return jsonResponse({
          'data': {
            'namespace': {
              'id': groupId,
              'fullPath': groupPath,
              'workItem': detail,
            },
          },
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final detail = await api.namespaceWorkItem(
        groupPath,
        7,
        expectedNamespaceId: groupId,
      );

      expect(detail.summary.project, isNull);
      expect(detail.summary.namespace!.id, groupId);
    },
  );

  test('namespace detail accepts a bound project namespace identity', () async {
    const path = 'team/project';
    const namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/142';
    final detail = _detail(namespaceId: namespaceId, namespacePath: path)
      ..['project'] = {'id': 'gid://gitlab/Project/42', 'fullPath': path};
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse(
          _namespaceEnvelope(
            namespaceId: namespaceId,
            namespacePath: path,
            detail: detail,
          ),
        ),
      ),
    );
    addTearDown(api.close);

    final loaded = await api.namespaceWorkItem(
      path,
      7,
      expectedNamespaceId: namespaceId,
    );

    expect(loaded.summary.project!.fullPath, path);
    expect(loaded.summary.namespace!.id, namespaceId);
  });

  test(
    'namespace detail rejects confused project and namespace scope',
    () async {
      const path = 'team/project';
      const namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/142';

      Future<void> expectInvalid(Map<String, Object?> detail) async {
        final api = testApi(
          FakeAdapter(
            (_) => jsonResponse(
              _namespaceEnvelope(
                namespaceId: namespaceId,
                namespacePath: path,
                detail: detail,
              ),
            ),
          ),
        );
        addTearDown(api.close);
        await expectLater(
          api.namespaceWorkItem(path, 7, expectedNamespaceId: namespaceId),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
      }

      await expectInvalid(
        _detail(namespaceId: namespaceId, namespacePath: path)
          ..['project'] = {
            'id': 'gid://gitlab/Project/42',
            'fullPath': 'foreign/project',
          },
      );
      await expectInvalid(
        _detail(namespaceId: namespaceId, namespacePath: path)
          ..['project'] = {'id': 'gid://gitlab/Group/42', 'fullPath': path},
      );
      await expectInvalid(
        _detail(namespaceId: namespaceId, namespacePath: path)
          ..['project'] = null,
      );

      const groupPath = 'team/group';
      const wrongGroupId = 'gid://gitlab/Namespaces::Namespace/9';
      final wrongGroupDetail = _detail(
        namespaceId: wrongGroupId,
        namespacePath: groupPath,
      )..['project'] = null;
      final wrongGroup = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _namespaceEnvelope(
              namespaceId: wrongGroupId,
              namespacePath: groupPath,
              detail: wrongGroupDetail,
            ),
          ),
        ),
      );
      addTearDown(wrongGroup.close);

      await expectLater(
        wrongGroup.namespaceWorkItem(
          groupPath,
          7,
          expectedNamespaceId: wrongGroupId,
        ),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
    },
  );

  test('namespace type capability keeps future names and cursor', () async {
    final adapter = FakeAdapter((request) {
      final variables = (request.data as Map)['variables'] as Map;
      expect(variables, {
        'path': _project.path,
        'first': 20,
        'after': 'previous',
      });
      return jsonResponse({
        'data': {
          'namespace': {
            'id': 'gid://gitlab/FutureNamespace/server-ns',
            'fullPath': _project.path,
            'workItemTypes': _connection(
              [
                {
                  'id': 'gid://gitlab/FutureType/server-type',
                  'name': 'Unknown future type',
                  'enabled': true,
                  'isGroupWorkItemType': false,
                  'widgetDefinitions': [
                    {'type': 'FUTURE_WIDGET'},
                  ],
                },
              ],
              hasNext: true,
              cursor: 'next',
            ),
          },
        },
      });
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    final page = await api.namespaceWorkItemTypes(
      _project.path,
      after: 'previous',
    );

    expect(page.items.single.type.name, 'Unknown future type');
    expect(page.items.single.widgetTypes, {'FUTURE_WIDGET'});
    expect(page.nextCursor, 'next');
  });

  test(
    'schema errors, missing resources, and inaccessible connections map explicitly',
    () async {
      final unsupported = testApi(
        FakeAdapter(
          (_) => jsonResponse({
            'errors': [
              {
                'extensions': {'code': 'undefinedField'},
              },
            ],
          }),
        ),
      );
      await expectLater(
        unsupported.projectWorkItems(_project),
        throwsA(_failure(FailureKind.unsupported)),
      );
      unsupported.close();

      final invisible = testApi(
        FakeAdapter(
          (_) => jsonResponse({
            'data': {'project': null},
          }),
        ),
      );
      await expectLater(
        invisible.projectWorkItems(_project),
        throwsA(_failure(FailureKind.invisible)),
      );
      invisible.close();

      final forbidden = testApi(
        FakeAdapter((_) => jsonResponse(_projectEnvelope(workItems: null))),
      );
      await expectLater(
        forbidden.projectWorkItems(_project),
        throwsA(_failure(FailureKind.forbidden)),
      );
      forbidden.close();
    },
  );

  test(
    'rejects invalid cursors, duplicate detail rows, and response budgets',
    () async {
      final noRequest = FakeAdapter((_) => fail('must reject before request'));
      final invalidCursor = testApi(noRequest);
      await expectLater(
        invalidCursor.projectWorkItems(_project, after: ''),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(noRequest.requests, isEmpty);
      invalidCursor.close();

      final repeated = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _projectEnvelope(
              workItems: _connection(
                [_summary()],
                hasNext: true,
                cursor: 'same',
              ),
            ),
          ),
        ),
      );
      await expectLater(
        repeated.projectWorkItems(_project, after: 'same'),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      repeated.close();

      final duplicate = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _projectEnvelope(workItems: _connection([_detail(), _detail()])),
          ),
        ),
      );
      await expectLater(
        duplicate.projectWorkItem(_project, 7),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      duplicate.close();

      final oversized = testApi(
        FakeAdapter(
          (_) => ResponseBody.fromString('x' * (4 * 1024 * 1024 + 1), 200),
        ),
      );
      await expectLater(
        oversized.projectWorkItems(_project),
        throwsA(_failure(FailureKind.tooLarge)),
      );
      oversized.close();
    },
  );

  test(
    'OAuth rotates once for the fixed read and keeps bearer-only auth',
    () async {
      var graphCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/oauth/token')) {
          return jsonResponse({
            'access_token': 'rotated-access',
            'refresh_token': 'rotated-refresh',
            'token_type': 'bearer',
            'expires_in': 7200,
          });
        }
        graphCalls++;
        if (graphCalls == 1) return jsonResponse({}, status: 401);
        expect(request.headers['Authorization'], 'Bearer rotated-access');
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        return jsonResponse(
          _projectEnvelope(workItems: _connection([_summary()])),
        );
      });
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final dio = Dio()..httpClientAdapter = adapter;
      final api = GitLabApi(
        instance: instance,
        dio: dio,
        credential: const OAuthCredential(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          clientId: 'app',
        ),
        oauth: OAuthTokenClient(instance: instance, clientId: 'app', dio: dio),
      );
      addTearDown(api.close);

      expect((await api.projectWorkItems(_project)).items, hasLength(1));
      expect(graphCalls, 2);
    },
  );

  test(
    'isCurrent and close reject late data from an old account generation',
    () async {
      final before = FakeAdapter((_) => fail('must reject before request'));
      final stale = testApi(before);
      await expectLater(
        stale.projectWorkItems(_project, isCurrent: () => false),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(before.requests, isEmpty);
      stale.close();

      final pending = Completer<ResponseBody>();
      final closed = testApi(FakeAdapter((_) => pending.future));
      final operation = closed.projectWorkItems(_project);
      await Future<void>.delayed(Duration.zero);
      closed.close();
      pending.complete(
        jsonResponse(_projectEnvelope(workItems: _connection([_summary()]))),
      );
      await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));

      var current = true;
      final latePending = Completer<ResponseBody>();
      final late = testApi(FakeAdapter((_) => latePending.future));
      final lateOperation = late.projectWorkItems(
        _project,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      latePending.complete(
        jsonResponse(_projectEnvelope(workItems: _connection([_summary()]))),
      );
      await expectLater(
        lateOperation,
        throwsA(_failure(FailureKind.cancelled)),
      );
      late.close();
    },
  );

  test(
    'N1_default: Default project call produces byte-identical GraphQL body with exactly 3 variables',
    () async {
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        expect(
          query,
          r'''
query MobileProjectWorkItems($path: ID!, $first: Int!, $after: String) {
  project(fullPath: $path) {
    id
    fullPath
    workItems(first: $first, after: $after) {
      nodes { id
iid
title
state
createdAt
updatedAt
project { id fullPath }
namespace { id fullPath }
workItemType { id name }
 }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''',
        );
        expect(query.contains('widgets'), isFalse);
        expect(body['variables'], {
          'path': _project.path,
          'first': 20,
          'after': null,
        });
        return jsonResponse(
          _projectEnvelope(workItems: _connection([_summary()])),
        );
      });
      final api = testApi(adapter);
      final page = await api.projectWorkItems(_project);
      expect(page.items, hasLength(1));
      expect(page.summaryTier, isNull);
      expect(adapter.requests, hasLength(1));

      await expectLater(
        api.projectWorkItems(_project, previousTier: 1),
        throwsA(_failure(FailureKind.validation)),
      );
      api.close();
    },
  );

  test(
    'T01: T1 list query sends 1 POST with 6 widget fragments and NO rollUp',
    () async {
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        expect(query.contains('... on WorkItemWidgetLabels'), isTrue);
        expect(query.contains('... on WorkItemWidgetAssignees'), isTrue);
        expect(query.contains('... on WorkItemWidgetMilestone'), isTrue);
        expect(query.contains('... on WorkItemWidgetStartAndDueDate'), isTrue);
        expect(query.contains('... on WorkItemWidgetHierarchy'), isTrue);
        expect(query.contains('... on WorkItemWidgetStatus'), isTrue);
        expect(query.contains('rollUp'), isFalse);
        return jsonResponse(
          _projectEnvelope(
            workItems: _connection([
              {
                ..._summary(),
                'widgets': <Object?>[],
              },
            ]),
          ),
        );
      });
      final api = testApi(adapter);
      final page = await api.projectWorkItems(_project, summaries: true);
      expect(page.items, hasLength(1));
      expect(page.summaryTier, 1);
      expect(adapter.requests, hasLength(1));
      api.close();
    },
  );

  test(
    'T02: CE undefinedType(typeName WorkItemWidgetStatus) triggers clean 2-POST fallback to T2 with tier binding on continuation',
    () async {
      var callCount = 0;
      final adapter = FakeAdapter((request) {
        callCount++;
        final body = request.data as Map;
        final query = body['query'] as String;
        if (callCount == 1) {
          expect(query.contains('... on WorkItemWidgetStatus'), isTrue);
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
        }
        expect(query.contains('... on WorkItemWidgetStatus'), isFalse);
        return jsonResponse(
          _projectEnvelope(
            workItems: _connection(
              [
                {
                  ..._summary(),
                  'widgets': <Object?>[],
                },
              ],
              hasNext: true,
              cursor: callCount == 2 ? 'cursor-t2-next' : 'cursor-t2-end',
            ),
          ),
        );
      });
      final api = testApi(adapter);
      final page = await api.projectWorkItems(_project, summaries: true);
      expect(page.items, hasLength(1));
      expect(page.summaryTier, 2);
      expect(callCount, 2);

      final continuation = await api.projectWorkItems(
        _project,
        after: page.nextCursor,
        summaries: true,
        previousTier: 2,
      );
      expect(continuation.summaryTier, 2);
      expect(callCount, 3);

      await expectLater(
        api.projectWorkItems(
          _project,
          after: page.nextCursor,
          summaries: true,
          previousTier: 1,
        ),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(callCount, 3);
      api.close();
    },
  );

  test(
    'T03: undefinedType combined with uncoded error, 401, or 403 fails closed without fallback',
    () async {
      final uncodedAdapter = FakeAdapter((_) => jsonResponse({
        'data': null,
        'errors': [
          {
            'message': 'Type WorkItemWidgetStatus is unknown',
            'extensions': {
              'code': 'undefinedType',
              'typeName': 'WorkItemWidgetStatus',
            },
          },
          {
            'message': 'General uncoded error',
          },
        ],
      }));
      final api1 = testApi(uncodedAdapter);
      await expectLater(
        api1.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(uncodedAdapter.requests, hasLength(1));
      api1.close();

      final forbiddenAdapter = FakeAdapter((_) => ResponseBody.fromString(
        'Forbidden',
        403,
        headers: {Headers.contentTypeHeader: [Headers.textPlainContentType]},
      ));
      final api2 = testApi(forbiddenAdapter);
      await expectLater(
        api2.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.forbidden)),
      );
      expect(forbiddenAdapter.requests, hasLength(1));
      api2.close();

      final unauthAdapter = FakeAdapter((_) => ResponseBody.fromString(
        'Unauthorized',
        401,
        headers: {Headers.contentTypeHeader: [Headers.textPlainContentType]},
      ));
      final api3 = testApi(unauthAdapter);
      await expectLater(
        api3.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.unauthenticated)),
      );
      expect(unauthAdapter.requests, hasLength(1));
      api3.close();

      final mixedCodedAdapter = FakeAdapter((_) => jsonResponse({
        'data': null,
        'errors': [
          {
            'message': 'Type WorkItemWidgetStatus is unknown',
            'extensions': {
              'code': 'undefinedType',
              'typeName': 'WorkItemWidgetStatus',
            },
          },
          {
            'message': 'Field unrelatedField is unknown',
            'extensions': {
              'code': 'undefinedField',
              'field': 'unrelatedField',
            },
          },
        ],
      }));
      final api4 = testApi(mixedCodedAdapter);
      await expectLater(
        api4.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(mixedCodedAdapter.requests, hasLength(1));
      api4.close();
    },
  );

  test(
    'T04: data.project or group null yields invisible/404 with zero fallback re-POST',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse({
        'data': {'project': null},
      }));
      final api = testApi(adapter);
      await expectLater(
        api.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.invisible)),
      );
      expect(adapter.requests, hasLength(1));
      api.close();

      final groupAdapter = FakeAdapter((_) => jsonResponse({
        'data': {'group': null},
      }));
      final apiGroup = testApi(groupAdapter);
      await expectLater(
        apiGroup.groupWorkItems('team/example', summaries: true),
        throwsA(_failure(FailureKind.invisible)),
      );
      expect(groupAdapter.requests, hasLength(1));
      apiGroup.close();
    },
  );

  test(
    'T05: Schema error code alongside partial data yields zero fallback',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse({
        'data': {
          'project': {
            'id': 'gid://gitlab/Project/42',
            'fullPath': 'team/example-42',
            'workItems': _connection([]),
          },
        },
        'errors': [
          {
            'message': 'Type WorkItemWidgetStatus is unknown',
            'extensions': {
              'code': 'undefinedType',
              'typeName': 'WorkItemWidgetStatus',
            },
          },
        ],
      }));
      final api = testApi(adapter);
      await expectLater(
        api.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(adapter.requests, hasLength(1));
      api.close();
    },
  );

  test(
    'T06: Unrelated undefinedField (e.g. on labels) does not degrade to T2',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse({
        'data': null,
        'errors': [
          {
            'message': 'Field labels is unknown',
            'extensions': {
              'code': 'undefinedField',
              'field': 'labels',
            },
          },
        ],
      }));
      final api = testApi(adapter);
      await expectLater(
        api.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(adapter.requests, hasLength(1));
      api.close();
    },
  );

  test(
    'T07: EE status null, milestone null, and parent null with hasParent true parse gracefully',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(
        _projectEnvelope(
          workItems: _connection([
            {
              ..._summary(),
              'widgets': [
                {'type': 'STATUS', 'status': null},
                {'type': 'MILESTONE', 'milestone': null},
                {'type': 'HIERARCHY', 'hasParent': true, 'parent': null},
                {'type': 'START_AND_DUE_DATE', 'startDate': null, 'dueDate': null},
              ],
            },
          ]),
        ),
      ));
      final api = testApi(adapter);
      final page = await api.projectWorkItems(_project, summaries: true);
      expect(page.items, hasLength(1));
      final item = page.items.single;
      expect(item.summary, isNotNull);
      expect(item.summary!.status, isNull);
      expect(item.summary!.milestone, isNull);
      expect(item.summary!.hierarchy, isNotNull);
      expect(item.summary!.hierarchy!.hasParent, isTrue);
      expect(item.summary!.hierarchy!.parent, isNull);
      expect(item.summary!.dates, isNotNull);
      expect(item.summary!.dates!.startDate, isNull);
      expect(item.summary!.dates!.dueDate, isNull);
      api.close();
    },
  );

  test(
    'T08: Malformed widget, duplicate widget type, or over-cap connection throws invalidResponse',
    () async {
      final missingWidgetsAdapter = FakeAdapter((_) => jsonResponse(
        _projectEnvelope(
          workItems: _connection([
            _summary(),
          ]),
        ),
      ));
      final api1 = testApi(missingWidgetsAdapter);
      await expectLater(
        api1.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api1.close();

      final dupWidgetAdapter = FakeAdapter((_) => jsonResponse(
        _projectEnvelope(
          workItems: _connection([
            {
              ..._summary(),
              'widgets': [
                {
                  'type': 'LABELS',
                  'labels': {
                    'nodes': <Object?>[],
                    'pageInfo': {'hasNextPage': false},
                  },
                },
                {
                  'type': 'LABELS',
                  'labels': {
                    'nodes': <Object?>[],
                    'pageInfo': {'hasNextPage': false},
                  },
                },
              ],
            },
          ]),
        ),
      ));
      final api2 = testApi(dupWidgetAdapter);
      await expectLater(
        api2.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api2.close();

      final overCapAdapter = FakeAdapter((_) => jsonResponse(
        _projectEnvelope(
          workItems: _connection([
            {
              ..._summary(),
              'widgets': [
                {
                  'type': 'LABELS',
                  'labels': {
                    'nodes': List.generate(
                      6,
                      (i) => {
                        'id': 'gid://gitlab/FutureLabel/$i',
                        'title': 'label-$i',
                        'color': '#123456',
                      },
                    ),
                    'pageInfo': {'hasNextPage': false},
                  },
                },
              ],
            },
          ]),
        ),
      ));
      final api3 = testApi(overCapAdapter);
      await expectLater(
        api3.projectWorkItems(_project, summaries: true),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api3.close();
    },
  );
}
