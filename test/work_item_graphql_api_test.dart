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
}
