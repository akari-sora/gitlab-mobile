import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';

import 'support/fake_adapter.dart';

const _workItemId = 'gid://gitlab/WorkItem/31';
const _typeId = 'gid://gitlab/WorkItems::Type/9';
const _projectRef = GraphResourceRef(
  id: 'gid://gitlab/Project/42',
  fullPath: 'studio/mobile-workspace',
);
const _projectNamespaceRef = GraphResourceRef(
  id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
  fullPath: 'studio/mobile-workspace',
);
const _groupRef = GraphResourceRef(
  id: 'gid://gitlab/Group/84',
  fullPath: 'qa/synthetic-group',
);
final _updated = DateTime.utc(2026, 10, 3, 10);
final _changed = DateTime.utc(2026, 10, 3, 11);

WorkItemGraphSummary _summary({bool group = false, String state = 'OPEN'}) =>
    WorkItemGraphSummary(
      id: group ? 'gid://gitlab/WorkItem/41' : _workItemId,
      iid: group ? 41 : 31,
      title: group ? 'Synthetic group item' : 'Synthetic project item',
      state: state,
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: _updated,
      project: group ? null : _projectRef,
      namespace: group ? _groupRef : _projectNamespaceRef,
      type: const WorkItemGraphType(id: _typeId, name: 'Task'),
    );

Map<String, Object?> _node(
  WorkItemGraphSummary expected, {
  String state = 'OPEN',
  DateTime? updatedAt,
  bool includePermission = true,
  Object? permission = true,
}) => {
  'id': expected.id,
  'iid': '${expected.iid}',
  'state': state,
  'updatedAt': (updatedAt ?? _updated).toIso8601String(),
  'project': expected.project == null
      ? null
      : {'id': expected.project!.id, 'fullPath': expected.project!.fullPath},
  'namespace': expected.namespace == null
      ? null
      : {
          'id': expected.namespace!.id,
          'fullPath': expected.namespace!.fullPath,
        },
  'workItemType': {'id': expected.type.id},
  if (includePermission) 'userPermissions': {'updateWorkItem': permission},
};

Map<String, Object?> _read(
  WorkItemGraphSummary expected, {
  String state = 'OPEN',
  DateTime? updatedAt,
  Object? permission = true,
}) => {
  'data': {
    'workItem': _node(
      expected,
      state: state,
      updatedAt: updatedAt,
      permission: permission,
    ),
  },
};

Map<String, Object?> _write(
  WorkItemGraphSummary expected, {
  String state = 'CLOSED',
  List<Object?> errors = const [],
  Object? workItem,
}) => {
  'data': {
    'workItemUpdate': {
      'errors': errors,
      'workItem':
          workItem ??
          _node(
            expected,
            state: state,
            updatedAt: _changed,
            includePermission: false,
          ),
    },
  },
};

bool _mutation(RequestOptions request) {
  final data = request.data;
  return data is Map &&
      data['query'] is String &&
      (data['query'] as String).startsWith('mutation ');
}

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

void main() {
  for (final group in [false, true]) {
    test(
      '${group ? 'group' : 'project'} preflight uses opaque identity and exact owner',
      () async {
        final expected = _summary(group: group);
        final adapter = FakeAdapter((_) => jsonResponse(_read(expected)));
        final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
        addTearDown(api.close);

        final snapshot = await api.workItemState(expected);
        expect(snapshot.id, expected.id);
        expect(snapshot.project?.id, expected.project?.id);
        expect(snapshot.namespace?.id, expected.namespace?.id);
        expect(snapshot.canUpdate, isTrue);

        final request = adapter.requests.single;
        expect(request.uri, api.instance.graphQL);
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(request.headers['Authorization'], 'Bearer synthetic-test-token');
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        expect((request.data as Map)['variables'], {'id': expected.id});
        final query = (request.data as Map)['query'] as String;
        expect(query, startsWith('query MobileWorkItemState'));
        expect(query, contains('userPermissions { updateWorkItem }'));
      },
    );
  }

  test(
    'preflight, one CLOSE mutation and independent readback succeed',
    () async {
      final expected = _summary();
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(_write(expected));
        reads++;
        return jsonResponse(
          _read(
            expected,
            state: reads == 1 ? 'OPEN' : 'CLOSED',
            updatedAt: reads == 1 ? _updated : _changed,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final result = await api.updateWorkItemState(
        expected,
        WorkItemStateEvent.close,
        expectedUpdatedAt: _updated,
      );

      expect(result.state, WorkItemState.closed);
      expect(adapter.requests.map(_mutation), [false, true, false]);
      expect((adapter.requests[1].data as Map)['variables'], {
        'input': {'id': expected.id, 'stateEvent': 'CLOSE'},
      });
      expect(
        (adapter.requests[1].data as Map)['query'],
        startsWith('mutation MobileUpdateWorkItemState'),
      );
    },
  );

  test(
    'REOPEN supports group items with the same opaque-ID contract',
    () async {
      final expected = _summary(group: true, state: 'CLOSED');
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          return jsonResponse(_write(expected, state: 'OPEN'));
        }
        reads++;
        return jsonResponse(
          _read(
            expected,
            state: reads == 1 ? 'CLOSED' : 'OPEN',
            updatedAt: reads == 1 ? _updated : _changed,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final result = await api.updateWorkItemState(
        expected,
        WorkItemStateEvent.reopen,
        expectedUpdatedAt: _updated,
      );

      expect(result.state, WorkItemState.open);
      expect(adapter.requests.where(_mutation), hasLength(1));
      expect((adapter.requests[1].data as Map)['variables'], {
        'input': {'id': expected.id, 'stateEvent': 'REOPEN'},
      });
    },
  );

  test('no-op still checks fresh permission and exact identity', () async {
    final expected = _summary(state: 'CLOSED');
    final adapter = FakeAdapter(
      (_) => jsonResponse(_read(expected, state: 'CLOSED')),
    );
    final api = testApi(adapter);
    addTearDown(api.close);

    final result = await api.updateWorkItemState(
      expected,
      WorkItemStateEvent.close,
      expectedUpdatedAt: _updated,
    );

    expect(result.state, WorkItemState.closed);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.where(_mutation), isEmpty);
  });

  test('permission denial and stale state or timestamp never write', () async {
    final expected = _summary();
    for (final fixture in [
      _read(expected, permission: false),
      _read(expected, state: 'CLOSED'),
      _read(expected, updatedAt: _changed),
    ]) {
      final adapter = FakeAdapter((_) => jsonResponse(fixture));
      final api = testApi(adapter);
      await expectLater(
        api.updateWorkItemState(
          expected,
          WorkItemStateEvent.close,
          expectedUpdatedAt: _updated,
        ),
        throwsA(
          _failure(
            identical(fixture, fixture) &&
                    ((fixture['data'] as Map)['workItem']
                            as Map)['userPermissions']
                        is Map &&
                    (((fixture['data'] as Map)['workItem']
                                as Map)['userPermissions']
                            as Map)['updateWorkItem'] ==
                        false
                ? FailureKind.forbidden
                : FailureKind.conflict,
          ),
        ),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
      api.close();
    }
  });

  test('owner replacement during preflight cancels before mutation', () async {
    final expected = _summary();
    var current = true;
    final requested = Completer<void>();
    final response = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) {
      requested.complete();
      return response.future;
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final operation = api.updateWorkItemState(
      expected,
      WorkItemStateEvent.close,
      expectedUpdatedAt: _updated,
      isCurrent: () => current,
    );
    final assertion = expectLater(
      operation,
      throwsA(_failure(FailureKind.cancelled)),
    );
    await requested.future;
    current = false;
    response.complete(jsonResponse(_read(expected)));
    await assertion;
    expect(adapter.requests.where(_mutation), isEmpty);
  });

  test('schema rejection is unsupported without mutation fallback', () async {
    final expected = _summary();
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'errors': [
          {
            'message': 'private schema detail',
            'extensions': {'code': 'undefinedField'},
          },
        ],
        'data': {'workItem': _node(expected)},
      }),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.workItemState(expected),
      throwsA(_failure(FailureKind.unsupported)),
    );
    expect(adapter.requests, hasLength(1));
  });

  test(
    '404 preflight is an inaccessible resource, not a pending read',
    () async {
      final api = testApi(FakeAdapter((_) => jsonResponse({}, status: 404)));
      addTearDown(api.close);
      await expectLater(
        api.workItemState(_summary()),
        throwsA(_failure(FailureKind.invisible)),
      );
    },
  );

  test(
    'unknown state, missing permission, and foreign scope fail closed',
    () async {
      final expected = _summary();
      final invalid = <Map<String, Object?>>[
        _read(expected, state: 'FUTURE'),
        _read(expected, permission: null),
        {
          'data': {
            'workItem': {
              ..._node(expected),
              'namespace': {
                'id': 'gid://gitlab/Namespaces::ProjectNamespace/99',
                'fullPath': 'other/project',
              },
            },
          },
        },
      ];
      for (final fixture in invalid) {
        final api = testApi(FakeAdapter((_) => jsonResponse(fixture)));
        await expectLater(
          api.workItemState(expected),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }
    },
  );

  test(
    'malformed acknowledgement and mismatched readback are uncertain',
    () async {
      final expected = _summary();
      for (final malformedAck in [true, false]) {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            return jsonResponse(
              malformedAck
                  ? {
                      'data': {
                        'workItemUpdate': {
                          'errors': <Object?>[],
                          'workItem': null,
                        },
                      },
                    }
                  : _write(expected),
            );
          }
          reads++;
          return jsonResponse(
            _read(
              expected,
              state: reads == 1 ? 'OPEN' : 'CLOSED',
              updatedAt: reads == 1 ? _updated : _changed,
            )..addAll(
              !malformedAck && reads == 2
                  ? {
                      'data': {
                        'workItem': _node(
                          expected,
                          state: 'OPEN',
                          updatedAt: _changed,
                        ),
                      },
                    }
                  : const {},
            ),
          );
        });
        final api = testApi(adapter);
        await expectLater(
          api.updateWorkItemState(
            expected,
            WorkItemStateEvent.close,
            expectedUpdatedAt: _updated,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests.where(_mutation), hasLength(1));
        api.close();
      }
    },
  );

  test('mutation redirect and timeout never follow or replay', () async {
    final expected = _summary();
    for (final timeout in [false, true]) {
      final adapter = FakeAdapter((request) {
        if (!_mutation(request)) return jsonResponse(_read(expected));
        if (timeout) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return jsonResponse(
          {},
          status: 307,
          headers: {
            'location': ['https://third-party.example/graphql'],
          },
        );
      });
      final api = testApi(adapter);
      await expectLater(
        api.updateWorkItemState(
          expected,
          WorkItemStateEvent.close,
          expectedUpdatedAt: _updated,
        ),
        throwsA(
          _failure(
            timeout ? FailureKind.writeUncertain : FailureKind.redirectBlocked,
          ),
        ),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
      expect(
        adapter.requests.every((request) => !request.followRedirects),
        isTrue,
      );
      api.close();
    }
  });

  test('OAuth mutation 401 refreshes credential but never replays', () async {
    final expected = _summary();
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/oauth/token')) {
        return jsonResponse({
          'access_token': 'rotated-access',
          'refresh_token': 'rotated-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      }
      return _mutation(request)
          ? jsonResponse({}, status: 401)
          : jsonResponse(_read(expected));
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

    await expectLater(
      api.updateWorkItemState(
        expected,
        WorkItemStateEvent.close,
        expectedUpdatedAt: _updated,
      ),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
    expect(adapter.requests.map((request) => request.uri.path), [
      '/gitlab/api/graphql',
      '/gitlab/api/graphql',
      '/gitlab/oauth/token',
    ]);
  });
}
