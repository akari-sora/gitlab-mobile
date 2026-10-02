import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';

const _workItemId = 'gid://gitlab/FutureWorkItem/server-owned';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/server-owned';
const _path = 'team/example-42';

final _expected = WorkItemGraphSummary(
  id: _workItemId,
  iid: 7,
  title: 'Synthetic work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 2),
  project: GraphResourceRef(id: _projectId, fullPath: _path),
  namespace: GraphResourceRef(id: _namespaceId, fullPath: _path),
  type: WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/server-owned',
    name: 'Task',
  ),
);

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _node({
  Object? widgets = const <Object?>[],
  String id = _workItemId,
  Object iid = '7',
  Object? project = const {'id': _projectId, 'fullPath': _path},
  Object? namespace = const {'id': _namespaceId, 'fullPath': _path},
}) => {
  'id': id,
  'iid': iid,
  'project': project,
  'namespace': namespace,
  'widgets': widgets,
};

Map<String, Object?> _envelope({
  Object? widgets = const <Object?>[],
  String id = _workItemId,
  Object iid = '7',
  Object? project = const {'id': _projectId, 'fullPath': _path},
  Object? namespace = const {'id': _namespaceId, 'fullPath': _path},
}) => {
  'data': {
    'workItem': _node(
      widgets: widgets,
      id: id,
      iid: iid,
      project: project,
      namespace: namespace,
    ),
  },
};

void main() {
  test('each kind sends one fixed isolated query with opaque ID', () async {
    const contracts =
        <
          WorkItemAttributeKind,
          ({String operation, String fragment, String widget})
        >{
          WorkItemAttributeKind.status: (
            operation: 'MobileWorkItemStatusAttribute',
            fragment: 'WorkItemWidgetStatus',
            widget: 'STATUS',
          ),
          WorkItemAttributeKind.milestone: (
            operation: 'MobileWorkItemMilestoneAttribute',
            fragment: 'WorkItemWidgetMilestone',
            widget: 'MILESTONE',
          ),
          WorkItemAttributeKind.weight: (
            operation: 'MobileWorkItemWeightAttribute',
            fragment: 'WorkItemWidgetWeight',
            widget: 'WEIGHT',
          ),
          WorkItemAttributeKind.iteration: (
            operation: 'MobileWorkItemIterationAttribute',
            fragment: 'WorkItemWidgetIteration',
            widget: 'ITERATION',
          ),
          WorkItemAttributeKind.health: (
            operation: 'MobileWorkItemHealthAttribute',
            fragment: 'WorkItemWidgetHealthStatus',
            widget: 'HEALTH_STATUS',
          ),
          WorkItemAttributeKind.timeTracking: (
            operation: 'MobileWorkItemTimeTrackingAttribute',
            fragment: 'WorkItemWidgetTimeTracking',
            widget: 'TIME_TRACKING',
          ),
          WorkItemAttributeKind.development: (
            operation: 'MobileWorkItemDevelopmentAttribute',
            fragment: 'WorkItemWidgetDevelopment',
            widget: 'DEVELOPMENT',
          ),
        };
    final allFragments = contracts.values.map((value) => value.fragment);

    for (final entry in contracts.entries) {
      final adapter = FakeAdapter((request) {
        expect(request.uri.path, '/gitlab/api/graphql');
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer synthetic-test-token');
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        final body = request.data as Map;
        final query = body['query'] as String;
        expect(query, contains('query ${entry.value.operation}'));
        expect(query, contains(r'workItem(id: $id)'));
        expect(query, contains(entry.value.fragment));
        expect(query, contains('project { id fullPath }'));
        expect(query, contains('namespace { id fullPath }'));
        for (final other in allFragments.where(
          (f) => f != entry.value.fragment,
        )) {
          expect(query, isNot(contains(other)));
        }
        expect(body['variables'], {'id': _workItemId});
        return jsonResponse(_envelope());
      });
      final api = testApi(adapter);

      final result = await api.workItemAttribute(_expected, entry.key);

      expect(result.kind, entry.key);
      expect(result.availability, WorkItemAttributeAvailability.absent);
      expect(result.value, isNull);
      api.close();
    }
  });

  test(
    'parses all seven attribute value shapes without fabricating values',
    () async {
      final widgets = <WorkItemAttributeKind, Map<String, Object?>>{
        WorkItemAttributeKind.status: {
          'type': 'STATUS',
          'status': {
            'id': null,
            'name': null,
            'iconName': null,
            'color': null,
            'category': null,
          },
        },
        WorkItemAttributeKind.milestone: {
          'type': 'MILESTONE',
          'milestone': {
            'id': 'gid://gitlab/Milestone/server-owned',
            'iid': '4',
            'title': 'M4',
            'state': 'active',
            'webPath': '/team/example-42/-/milestones/4',
            'dueDate': '2026-09-03',
            'startDate': null,
            'project': null,
            'group': {'id': null, 'fullPath': 'team'},
          },
        },
        WorkItemAttributeKind.weight: {
          'type': 'WEIGHT',
          'weight': 0,
          'rolledUpWeight': null,
          'rolledUpCompletedWeight': 2,
        },
        WorkItemAttributeKind.iteration: {
          'type': 'ITERATION',
          'iteration': {
            'id': 'gid://gitlab/Iteration/server-owned',
            'iid': '5',
            'title': null,
            'state': 'opened',
            'webUrl': 'https://example.com/gitlab/groups/team/-/iterations/5',
            'startDate': '2026-09-04',
            'dueDate': null,
            'group': {'id': null, 'fullPath': 'team'},
            'iterationCadence': {
              'id': 'gid://gitlab/Iterations::Cadence/server-owned',
              'title': null,
            },
          },
        },
        WorkItemAttributeKind.health: {
          'type': 'HEALTH_STATUS',
          'healthStatus': null,
          'rolledUpHealthStatus': [
            {'healthStatus': 'onTrack', 'count': 0},
            {'healthStatus': 'atRisk', 'count': 2},
          ],
        },
        WorkItemAttributeKind.timeTracking: {
          'type': 'TIME_TRACKING',
          'timeEstimate': null,
          'totalTimeSpent': 0,
          'humanReadableAttributes': {
            'timeEstimate': null,
            'totalTimeSpent': '0m',
          },
        },
        WorkItemAttributeKind.development: {
          'type': 'DEVELOPMENT',
          'closingMergeRequestsCount': 0,
          'willAutoCloseByMergeRequest': false,
        },
      };

      Future<WorkItemAttributeValue> read(WorkItemAttributeKind kind) async {
        final api = testApi(
          FakeAdapter(
            (_) => jsonResponse(_envelope(widgets: [widgets[kind]!])),
          ),
        );
        final result = await api.workItemAttribute(_expected, kind);
        api.close();
        expect(result.availability, WorkItemAttributeAvailability.present);
        return result.value!;
      }

      final status = await read(WorkItemAttributeKind.status);
      expect((status as WorkItemStatusAttribute).status!.name, isNull);

      final milestone = await read(WorkItemAttributeKind.milestone);
      final milestoneValue =
          (milestone as WorkItemMilestoneAttribute).milestone!;
      expect(milestoneValue.dueDate, DateTime.utc(2026, 9, 3));
      expect(milestoneValue.dueDate!.isUtc, isTrue);
      expect(milestoneValue.startDate, isNull);
      expect(milestoneValue.group!.id, isNull);

      final weight = await read(WorkItemAttributeKind.weight);
      expect((weight as WorkItemWeightAttribute).weight, 0);
      expect(weight.rolledUpWeight, isNull);

      final iteration = await read(WorkItemAttributeKind.iteration);
      final iterationValue =
          (iteration as WorkItemIterationAttribute).iteration!;
      expect(iterationValue.title, isNull);
      expect(iterationValue.startDate, DateTime.utc(2026, 9, 4));
      expect(iterationValue.cadence.title, isNull);

      final health = await read(WorkItemAttributeKind.health);
      expect((health as WorkItemHealthAttribute).healthStatus, isNull);
      expect(health.rolledUpHealthStatus, hasLength(2));
      expect(health.rolledUpHealthStatus!.first.count, 0);

      final time = await read(WorkItemAttributeKind.timeTracking);
      expect((time as WorkItemTimeTrackingAttribute).timeEstimate, isNull);
      expect(time.totalTimeSpent, 0);
      expect(time.humanReadable!.totalTimeSpent, '0m');

      final development = await read(WorkItemAttributeKind.development);
      expect(
        (development as WorkItemDevelopmentAttribute).closingMergeRequestsCount,
        0,
      );
      expect(development.willAutoCloseByMergeRequest, isFalse);
    },
  );

  test(
    'distinguishes widgets unavailable, widget absent, and null value',
    () async {
      final replies = <Object?>[
        _envelope(widgets: null),
        _envelope(widgets: const []),
        _envelope(
          widgets: const [
            {'type': 'STATUS', 'status': null},
          ],
        ),
      ];
      var call = 0;
      final api = testApi(FakeAdapter((_) => jsonResponse(replies[call++])));
      addTearDown(api.close);

      final unavailable = await api.workItemAttribute(
        _expected,
        WorkItemAttributeKind.status,
      );
      final absent = await api.workItemAttribute(
        _expected,
        WorkItemAttributeKind.status,
      );
      final present = await api.workItemAttribute(
        _expected,
        WorkItemAttributeKind.status,
      );

      expect(
        unavailable.availability,
        WorkItemAttributeAvailability.widgetsUnavailable,
      );
      expect(absent.availability, WorkItemAttributeAvailability.absent);
      expect(present.availability, WorkItemAttributeAvailability.present);
      expect((present.value as WorkItemStatusAttribute).status, isNull);
    },
  );

  test(
    'binds returned work item, project, and namespace identity exactly',
    () async {
      final responses = <Object?>[
        _envelope(id: 'gid://gitlab/WorkItem/wrong'),
        _envelope(iid: '8'),
        _envelope(
          project: const {'id': 'gid://gitlab/Project/41', 'fullPath': _path},
        ),
        _envelope(project: const {'id': _projectId, 'fullPath': 'team/wrong'}),
        _envelope(
          namespace: const {
            'id': 'gid://gitlab/Namespace/wrong',
            'fullPath': _path,
          },
        ),
        _envelope(
          namespace: const {'id': _namespaceId, 'fullPath': 'team/wrong'},
        ),
        _envelope(namespace: null),
      ];

      for (final response in responses) {
        final api = testApi(FakeAdapter((_) => jsonResponse(response)));
        await expectLater(
          api.workItemAttribute(_expected, WorkItemAttributeKind.weight),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }
    },
  );

  test('invalid expected identity is rejected before any request', () async {
    final invalid = WorkItemGraphSummary(
      id: 'not-a-gid',
      iid: 7,
      title: 'Synthetic',
      state: 'OPEN',
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
      project: GraphResourceRef(id: _projectId, fullPath: _path),
      namespace: GraphResourceRef(id: _namespaceId, fullPath: _path),
      type: WorkItemGraphType(
        id: 'gid://gitlab/WorkItems::Type/server-owned',
        name: 'Task',
      ),
    );
    final adapter = FakeAdapter((_) => fail('must reject before request'));
    final api = testApi(adapter);

    await expectLater(
      api.workItemAttribute(invalid, WorkItemAttributeKind.status),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests, isEmpty);
    api.close();
  });

  test(
    'schema unsupported is isolated to the selected attribute kind',
    () async {
      var call = 0;
      final api = testApi(
        FakeAdapter((request) {
          call++;
          final query = (request.data as Map)['query'] as String;
          if (call == 1) {
            expect(query, contains('WorkItemWidgetStatus'));
            return jsonResponse({
              'errors': [
                {
                  'extensions': {'code': 'undefinedField'},
                },
              ],
            });
          }
          expect(query, contains('WorkItemWidgetWeight'));
          expect(query, isNot(contains('WorkItemWidgetStatus')));
          return jsonResponse(
            _envelope(
              widgets: const [
                {
                  'type': 'WEIGHT',
                  'weight': 3,
                  'rolledUpWeight': null,
                  'rolledUpCompletedWeight': null,
                },
              ],
            ),
          );
        }),
      );
      addTearDown(api.close);

      await expectLater(
        api.workItemAttribute(_expected, WorkItemAttributeKind.status),
        throwsA(_failure(FailureKind.unsupported)),
      );
      final weight = await api.workItemAttribute(
        _expected,
        WorkItemAttributeKind.weight,
      );
      expect((weight.value as WorkItemWeightAttribute).weight, 3);
    },
  );

  test(
    'rejects duplicate widgets, malformed dates, counts, and unsafe URLs',
    () async {
      final invalidWidgets = <Object?>[
        const [
          {'type': 'STATUS', 'status': null},
          {'type': 'STATUS', 'status': null},
        ],
        const [
          {
            'type': 'MILESTONE',
            'milestone': {
              'id': 'gid://gitlab/Milestone/server-owned',
              'iid': '4',
              'title': 'M4',
              'state': 'active',
              'webPath': '/team/example/-/milestones/4',
              'dueDate': '2026-02-30',
              'startDate': null,
              'project': null,
              'group': null,
            },
          },
        ],
        const [
          {
            'type': 'ITERATION',
            'iteration': {
              'id': 'gid://gitlab/Iteration/server-owned',
              'iid': '5',
              'title': null,
              'state': 'opened',
              'webUrl':
                  'https://third-party.example/groups/team/-/iterations/5',
              'startDate': null,
              'dueDate': null,
              'group': {'id': null, 'fullPath': 'team'},
              'iterationCadence': {
                'id': 'gid://gitlab/Iterations::Cadence/server-owned',
                'title': null,
              },
            },
          },
        ],
        const [
          {
            'type': 'HEALTH_STATUS',
            'healthStatus': null,
            'rolledUpHealthStatus': [
              {'healthStatus': 'onTrack', 'count': 1},
              {'healthStatus': 'onTrack', 'count': 2},
            ],
          },
        ],
        const [
          {
            'type': 'DEVELOPMENT',
            'closingMergeRequestsCount': -1,
            'willAutoCloseByMergeRequest': false,
          },
        ],
      ];
      final kinds = [
        WorkItemAttributeKind.status,
        WorkItemAttributeKind.milestone,
        WorkItemAttributeKind.iteration,
        WorkItemAttributeKind.health,
        WorkItemAttributeKind.development,
      ];

      for (var index = 0; index < invalidWidgets.length; index++) {
        final api = testApi(
          FakeAdapter(
            (_) => jsonResponse(_envelope(widgets: invalidWidgets[index])),
          ),
        );
        await expectLater(
          api.workItemAttribute(_expected, kinds[index]),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }
    },
  );

  test(
    'response budget and redirects are enforced by the shared reader',
    () async {
      final oversized = testApi(
        FakeAdapter(
          (_) => ResponseBody.fromString('x' * (4 * 1024 * 1024 + 1), 200),
        ),
      );
      await expectLater(
        oversized.workItemAttribute(_expected, WorkItemAttributeKind.status),
        throwsA(_failure(FailureKind.tooLarge)),
      );
      oversized.close();

      final redirected = testApi(
        FakeAdapter(
          (_) => ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://third-party.example/graphql'],
            },
          ),
        ),
      );
      await expectLater(
        redirected.workItemAttribute(_expected, WorkItemAttributeKind.status),
        throwsA(_failure(FailureKind.redirectBlocked)),
      );
      redirected.close();
    },
  );

  test(
    'OAuth rotates once and keeps the attribute request bearer-only',
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
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer rotated-access');
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        return jsonResponse(_envelope());
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

      await api.workItemAttribute(_expected, WorkItemAttributeKind.weight);
      expect(graphCalls, 2);
    },
  );

  test(
    'isCurrent and close reject old account data before and after I/O',
    () async {
      final before = FakeAdapter((_) => fail('must reject before request'));
      final stale = testApi(before);
      await expectLater(
        stale.workItemAttribute(
          _expected,
          WorkItemAttributeKind.status,
          isCurrent: () => false,
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(before.requests, isEmpty);
      stale.close();

      final closePending = Completer<ResponseBody>();
      final closed = testApi(FakeAdapter((_) => closePending.future));
      final closedOperation = closed.workItemAttribute(
        _expected,
        WorkItemAttributeKind.status,
      );
      await Future<void>.delayed(Duration.zero);
      closed.close();
      closePending.complete(jsonResponse(_envelope()));
      await expectLater(
        closedOperation,
        throwsA(_failure(FailureKind.cancelled)),
      );

      var current = true;
      final latePending = Completer<ResponseBody>();
      final late = testApi(FakeAdapter((_) => latePending.future));
      final lateOperation = late.workItemAttribute(
        _expected,
        WorkItemAttributeKind.status,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      latePending.complete(jsonResponse(_envelope()));
      await expectLater(
        lateOperation,
        throwsA(_failure(FailureKind.cancelled)),
      );
      late.close();
    },
  );
}
