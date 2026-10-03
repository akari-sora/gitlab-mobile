import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';

const _actorId = 'gid://gitlab/User/7';

WorkItemGraphSummary _summary({bool group = false}) => WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/${group ? 41 : 31}',
  iid: group ? 8 : 7,
  title: 'Synthetic item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  project: group
      ? null
      : const GraphResourceRef(
          id: 'gid://gitlab/Project/42',
          fullPath: 'team/example-42',
        ),
  namespace: group
      ? const GraphResourceRef(id: 'gid://gitlab/Group/7', fullPath: 'team')
      : const GraphResourceRef(
          id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
          fullPath: 'team/example-42',
        ),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/5',
    name: 'Task',
  ),
);

Map<String, Object?> _identity(WorkItemGraphSummary value) => {
  'id': value.id,
  'iid': '${value.iid}',
  'project': value.project == null
      ? null
      : {'id': value.project!.id, 'fullPath': value.project!.fullPath},
  'namespace': value.namespace == null
      ? null
      : {'id': value.namespace!.id, 'fullPath': value.namespace!.fullPath},
  'workItemType': {'id': value.type.id},
};

Map<String, Object?> _read({
  bool group = false,
  Object? actor = const {'id': _actorId},
  Object? widgets = const [
    {'type': 'NOTIFICATIONS', 'subscribed': false},
  ],
  Map<String, Object?> changes = const {},
}) => {
  'data': {
    'currentUser': actor,
    'workItem': {
      ..._identity(_summary(group: group)),
      'widgets': widgets,
      ...changes,
    },
  },
};

Map<String, Object?> _ack({
  bool group = false,
  Object? errors = const <Object?>[],
  Object? widgets = const [
    {'type': 'NOTIFICATIONS', 'subscribed': true},
  ],
  Object? workItem = _sentinel,
}) => {
  'data': {
    'workItemSubscribe': {
      'errors': errors,
      'workItem': identical(workItem, _sentinel)
          ? {..._identity(_summary(group: group)), 'widgets': widgets}
          : workItem,
    },
  },
};

const _sentinel = Object();
String _query(RequestOptions request) =>
    (request.data as Map)['query'] as String;
Map<Object?, Object?> _variables(RequestOptions request) =>
    (request.data as Map)['variables'] as Map<Object?, Object?>;
bool _mutation(RequestOptions request) =>
    _query(request).startsWith('mutation ');
Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

Future<WorkItemNotificationTarget> _target(
  GitLabApi api, {
  bool group = false,
}) async => (await api.workItemNotifications(
  _summary(group: group),
  expectedUserId: 7,
)).target!;

void main() {
  for (final group in [false, true]) {
    test('${group ? 'group' : 'project'} subscription uses exact desired state '
        'and confirms an independent same-actor readback', () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        expect(request.followRedirects, isFalse);
        expect(request.uri.path, '/gitlab/api/graphql');
        final query = _query(request);
        expect(query, isNot(contains('updateWorkItem')));
        expect(query, isNot(contains('updateSubscription')));
        if (_mutation(request)) {
          expect(query, startsWith('mutation MobileSetWorkItemNotifications'));
          expect(_variables(request), {
            'input': {'id': _summary(group: group).id, 'subscribed': true},
          });
          return jsonResponse(_ack(group: group));
        }
        expect(query, startsWith('query MobileWorkItemNotifications'));
        expect(query, contains('widgets(onlyTypes: [NOTIFICATIONS])'));
        expect(query, contains('currentUser { id }'));
        expect(_variables(request), {'id': _summary(group: group).id});
        return jsonResponse(
          _read(
            group: group,
            widgets: [
              {'type': 'NOTIFICATIONS', 'subscribed': reads++ >= 2},
            ],
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api, group: group);
      final result = await api.setWorkItemNotifications(
        target,
        subscribed: true,
      );
      expect(result.subscribed, isTrue);
      expect(result.actorId, _actorId);
      expect(result.canAttemptSubscription, isTrue);
      expect(result.target, isNotNull);
      expect(adapter.requests.where(_mutation), hasLength(1));
    });
  }

  test('present, absent and unavailable widgets remain distinct', () async {
    final responses = <Map<String, Object?>>[
      _read(),
      _read(widgets: const []),
      _read(widgets: null),
    ];
    var index = 0;
    final adapter = FakeAdapter((_) => jsonResponse(responses[index++]));
    final api = testApi(adapter);
    addTearDown(api.close);
    final present = await api.workItemNotifications(_summary());
    final absent = await api.workItemNotifications(_summary());
    final unavailable = await api.workItemNotifications(_summary());
    expect(present.availability, WorkItemNotificationAvailability.present);
    expect(present.subscribed, isFalse);
    expect(absent.availability, WorkItemNotificationAvailability.absent);
    expect(absent.subscribed, isNull);
    expect(absent.canAttemptSubscription, isFalse);
    expect(
      unavailable.availability,
      WorkItemNotificationAvailability.widgetsUnavailable,
    );
    expect(unavailable.subscribed, isNull);
  });

  test(
    'anonymous present widget is readable but cannot mint a target',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read(actor: null)));
      final api = testApi(adapter);
      addTearDown(api.close);
      final access = await api.workItemNotifications(_summary());
      expect(access.availability, WorkItemNotificationAvailability.present);
      expect(access.subscribed, isFalse);
      expect(access.actorId, isNull);
      expect(access.canAttemptSubscription, isFalse);
      expect(access.target, isNull);
    },
  );

  test(
    'explicit anonymous actor is unauthenticated for an expected account',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read(actor: null)));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemNotifications(_summary(), expectedUserId: 7),
        throwsA(
          isA<ApiFailure>()
              .having(
                (value) => value.kind,
                'kind',
                FailureKind.unauthenticated,
              )
              .having((value) => value.title, 'title', '登入已失效')
              .having((value) => value.detail, 'detail', contains('重新連接目前帳號')),
        ),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    },
  );

  test('omitted currentUser key is malformed rather than anonymous', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': {
          'workItem': {
            ..._identity(_summary()),
            'widgets': const <Object?>[],
          },
        },
      }),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.workItemNotifications(_summary()),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test('subscription does not depend on general edit permission', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse(
        _read(
          changes: const {
            'userPermissions': {'updateWorkItem': false},
          },
        ),
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final access = await api.workItemNotifications(_summary());
    expect(access.canAttemptSubscription, isTrue);
    expect(access.target, isNotNull);
    expect(_query(adapter.requests.single), isNot(contains('userPermissions')));
  });

  final invalidLocal = <WorkItemGraphSummary>[
    WorkItemGraphSummary(
      id: 'bad',
      iid: _summary().iid,
      title: _summary().title,
      state: _summary().state,
      createdAt: _summary().createdAt,
      updatedAt: _summary().updatedAt,
      project: _summary().project,
      namespace: _summary().namespace,
      type: _summary().type,
    ),
    WorkItemGraphSummary(
      id: _summary().id,
      iid: _summary().iid,
      title: _summary().title,
      state: _summary().state,
      createdAt: _summary().createdAt,
      updatedAt: _summary().updatedAt,
      project: _summary().project,
      namespace: _summary().namespace,
      type: const WorkItemGraphType(id: 'bad', name: 'Task'),
    ),
  ];
  for (final summary in invalidLocal) {
    test('invalid local identity is rejected before transport', () async {
      final adapter = FakeAdapter((_) => fail('must reject before I/O'));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemNotifications(summary),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests, isEmpty);
    });
  }

  test(
    'invalid expected user and mismatched authenticated actor fail closed',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read()));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemNotifications(_summary(), expectedUserId: 0),
        throwsA(_failure(FailureKind.validation)),
      );
      await expectLater(
        api.workItemNotifications(_summary(), expectedUserId: 8),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  final malformed = <String, Map<String, Object?>>{
    'wrong id': _read(changes: const {'id': 'gid://gitlab/WorkItem/32'}),
    'wrong iid': _read(changes: const {'iid': '8'}),
    'wrong namespace': _read(
      changes: const {
        'namespace': {'id': 'gid://gitlab/Group/8', 'fullPath': 'other'},
      },
    ),
    'wrong type': _read(
      changes: const {
        'workItemType': {'id': 'gid://gitlab/WorkItems::Type/6'},
      },
    ),
    'malformed actor': _read(actor: const {'id': 'User/7'}),
    'malformed widget state': _read(
      widgets: const [
        {'type': 'NOTIFICATIONS', 'subscribed': 'false'},
      ],
    ),
    'duplicate widgets': _read(
      widgets: const [
        {'type': 'NOTIFICATIONS', 'subscribed': false},
        {'type': 'NOTIFICATIONS', 'subscribed': false},
      ],
    ),
    'unexpected filtered widget': _read(
      widgets: const [
        {'type': 'STATUS'},
      ],
    ),
  };
  for (final entry in malformed.entries) {
    test('${entry.key} is invalid and cannot mint a target', () async {
      final adapter = FakeAdapter((_) => jsonResponse(entry.value));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemNotifications(_summary()),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  test('missing work item stays ambiguous invisible', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': {
          'currentUser': const {'id': _actorId},
          'workItem': null,
        },
      }),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.workItemNotifications(_summary()),
      throwsA(_failure(FailureKind.invisible)),
    );
  });

  test(
    'schema rejection is unsupported while base detail stays independent',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'errors': [
            {
              'message': 'Unknown argument onlyTypes',
              'extensions': {'code': 'undefinedField'},
            },
          ],
        }),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemNotifications(_summary()),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test('unchanged desired state is a consumed zero-mutation no-op', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_read()));
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    final result = await api.setWorkItemNotifications(
      target,
      subscribed: false,
    );
    expect(result.subscribed, isFalse);
    expect(adapter.requests.where(_mutation), isEmpty);
    await expectLater(
      api.setWorkItemNotifications(target, subscribed: true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
  });

  final changedPreflight = <String, Map<String, Object?>>{
    'expired actor': _read(actor: null),
    'actor': _read(actor: const {'id': 'gid://gitlab/User/8'}),
    'identity': _read(changes: const {'iid': '9'}),
    'type': _read(
      changes: const {
        'workItemType': {'id': 'gid://gitlab/WorkItems::Type/6'},
      },
    ),
    'state': _read(
      widgets: const [
        {'type': 'NOTIFICATIONS', 'subscribed': true},
      ],
    ),
    'absent widget': _read(widgets: const []),
  };
  for (final entry in changedPreflight.entries) {
    test('changed ${entry.key} blocks mutation and consumes target', () async {
      var reads = 0;
      final adapter = FakeAdapter(
        (_) => jsonResponse(reads++ == 0 ? _read() : entry.value),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.setWorkItemNotifications(target, subscribed: true),
        throwsA(
          anyOf(
            _failure(FailureKind.cancelled),
            _failure(FailureKind.unauthenticated),
            _failure(FailureKind.invalidResponse),
            _failure(FailureKind.conflict),
          ),
        ),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
      final count = adapter.requests.length;
      await expectLater(
        api.setWorkItemNotifications(target, subscribed: true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests, hasLength(count));
    });
  }

  test('target is owner-bound and closed owner cannot preflight', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_read()));
    final api = testApi(adapter);
    final target = await _target(api);
    final otherAdapter = FakeAdapter((_) => fail('must reject before I/O'));
    final other = testApi(otherAdapter);
    addTearDown(other.close);
    await expectLater(
      other.setWorkItemNotifications(target, subscribed: true),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(otherAdapter.requests, isEmpty);
    api.close();
    await expectLater(
      api.setWorkItemNotifications(target, subscribed: true),
      throwsA(_failure(FailureKind.cancelled)),
    );
  });

  test('generation invalidation during preflight prevents mutation', () async {
    var current = true;
    var reads = 0;
    final adapter = FakeAdapter((_) {
      if (++reads == 2) current = false;
      return jsonResponse(_read());
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.setWorkItemNotifications(
        target,
        subscribed: true,
        isCurrent: () => current,
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests.where(_mutation), isEmpty);
  });

  test(
    'concurrent use reserves target before asynchronous preflight',
    () async {
      final preflight = Completer<ResponseBody>();
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(_ack());
        if (++reads == 1) return jsonResponse(_read());
        if (reads == 2) return preflight.future;
        return jsonResponse(
          _read(
            widgets: const [
              {'type': 'NOTIFICATIONS', 'subscribed': true},
            ],
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final first = api.setWorkItemNotifications(target, subscribed: true);
      await expectLater(
        api.setWorkItemNotifications(target, subscribed: true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      preflight.complete(jsonResponse(_read()));
      await first;
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test('explicit mutation errors are validation and cannot replay', () async {
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) {
        return jsonResponse(_ack(errors: const ['Not authorized']));
      }
      return jsonResponse(_read());
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.setWorkItemNotifications(target, subscribed: true),
      throwsA(_failure(FailureKind.validation)),
    );
    await expectLater(
      api.setWorkItemNotifications(target, subscribed: true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  test('provable mutation schema rejection is unsupported', () async {
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) {
        return jsonResponse({
          'errors': [
            {
              'message': 'Unknown mutation',
              'extensions': {'code': 'undefinedField'},
            },
          ],
        });
      }
      return jsonResponse(_read());
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.setWorkItemNotifications(target, subscribed: true),
      throwsA(_failure(FailureKind.unsupported)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  final uncertain = <String>[
    'transport 500',
    'malformed errors',
    'missing work item',
    'ack state mismatch',
    'readback state mismatch',
    'readback actor mismatch',
    'readback identity mismatch',
    'readback 500',
    'cancel after send',
  ];
  for (final stage in uncertain) {
    test(
      '$stage is write-uncertain after one send and cannot replay',
      () async {
        var reads = 0;
        var current = true;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            if (stage == 'transport 500') {
              return jsonResponse(const {}, status: 500);
            }
            if (stage == 'malformed errors') {
              return jsonResponse(_ack(errors: 'none'));
            }
            if (stage == 'missing work item') {
              return jsonResponse(_ack(workItem: null));
            }
            if (stage == 'ack state mismatch') {
              return jsonResponse(
                _ack(
                  widgets: const [
                    {'type': 'NOTIFICATIONS', 'subscribed': false},
                  ],
                ),
              );
            }
            if (stage == 'cancel after send') current = false;
            return jsonResponse(_ack());
          }
          final readIndex = reads++;
          if (readIndex >= 2 && stage == 'readback 500') {
            return jsonResponse(const {}, status: 500);
          }
          final read = readIndex < 2 || stage == 'readback state mismatch'
              ? _read()
              : stage == 'readback actor mismatch'
              ? _read(
                  actor: const {'id': 'gid://gitlab/User/8'},
                  widgets: const [
                    {'type': 'NOTIFICATIONS', 'subscribed': true},
                  ],
                )
              : stage == 'readback identity mismatch'
              ? _read(
                  widgets: const [
                    {'type': 'NOTIFICATIONS', 'subscribed': true},
                  ],
                  changes: const {'iid': '9'},
                )
              : _read(
                  widgets: const [
                    {'type': 'NOTIFICATIONS', 'subscribed': true},
                  ],
                );
          return jsonResponse(read);
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.setWorkItemNotifications(
            target,
            subscribed: true,
            isCurrent: () => current,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        final count = adapter.requests.length;
        await expectLater(
          api.setWorkItemNotifications(target, subscribed: true),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests, hasLength(count));
        expect(adapter.requests.where(_mutation), hasLength(1));
      },
    );
  }
}
