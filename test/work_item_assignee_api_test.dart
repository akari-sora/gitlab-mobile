import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_assignee_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';

const _actorId = 'gid://gitlab/User/7';
final _createdAt = DateTime.utc(2026, 10, 1);
final _openedAt = DateTime.utc(2026, 10, 3, 8);
final _freshAt = DateTime.utc(2026, 10, 3, 9);
final _savedAt = DateTime.utc(2026, 10, 3, 10);

WorkItemGraphSummary _summary({bool group = false, DateTime? updatedAt}) =>
    WorkItemGraphSummary(
      id: 'gid://gitlab/WorkItem/${group ? 41 : 31}',
      iid: group ? 41 : 31,
      title: 'Fresh title',
      state: 'OPEN',
      createdAt: _createdAt,
      updatedAt: updatedAt ?? _freshAt,
      project: group
          ? null
          : const GraphResourceRef(
              id: 'gid://gitlab/Project/42',
              fullPath: 'studio/mobile-workspace',
            ),
      namespace: group
          ? const GraphResourceRef(
              id: 'gid://gitlab/Group/84',
              fullPath: 'qa/synthetic-group',
            )
          : const GraphResourceRef(
              id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
              fullPath: 'studio/mobile-workspace',
            ),
      type: const WorkItemGraphType(
        id: 'gid://gitlab/WorkItems::Type/9',
        name: 'Task',
      ),
    );

WorkItemGraphDetail _detail({
  bool group = false,
  List<WorkItemGraphAssignee>? stale,
}) => WorkItemGraphDetail(
  summary: _summary(group: group, updatedAt: _openedAt),
  description: 'possibly stale',
  widgetsAvailable: true,
  widgetTypes: const {'ASSIGNEES'},
  descriptionWidget: null,
  assignees: stale == null
      ? null
      : WorkItemAssigneesWidget(
          assignees: BoundedGraphConnection(
            items: stale,
            isPartial: true,
            nextCursor: 'detail-cursor',
          ),
        ),
  labels: null,
  hierarchy: null,
  dates: null,
);

Map<String, Object?> _user(int id) => {
  'id': 'gid://gitlab/User/$id',
  'name': 'Person $id',
  'username': 'person$id',
};

Map<String, Object?> _node({
  bool group = false,
  DateTime? updatedAt,
  required List<Map<String, Object?>> users,
  bool hasNext = false,
  String? cursor,
  Object? allowsMultiple = true,
  Map<String, Object?>? permissions,
  bool includePermissions = true,
  bool includeWidget = true,
  String widgetType = 'ASSIGNEES',
  Map<String, Object?> changes = const {},
}) {
  final expected = _summary(group: group, updatedAt: updatedAt);
  return {
    'id': expected.id,
    'iid': '${expected.iid}',
    'title': expected.title,
    'state': expected.state,
    'createdAt': expected.createdAt.toIso8601String(),
    'updatedAt': expected.updatedAt.toIso8601String(),
    'project': expected.project == null
        ? null
        : {'id': expected.project!.id, 'fullPath': expected.project!.fullPath},
    'namespace': expected.namespace == null
        ? null
        : {
            'id': expected.namespace!.id,
            'fullPath': expected.namespace!.fullPath,
          },
    'workItemType': {'id': expected.type.id, 'name': expected.type.name},
    if (includePermissions)
      'userPermissions':
          permissions ?? {'readWorkItem': true, 'setWorkItemMetadata': true},
    if (includeWidget)
      'widgets': [
        {
          'type': widgetType,
          'allowsMultipleAssignees': allowsMultiple,
          'assignees': {
            'nodes': users,
            'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
          },
        },
      ],
    ...changes,
  };
}

Map<String, Object?> _read({
  bool group = false,
  Object? actor = const {'id': _actorId},
  bool includeActor = true,
  Object? workItem,
  DateTime? updatedAt,
  List<Map<String, Object?>> users = const [],
  bool hasNext = false,
  String? cursor,
  Object? allowsMultiple = true,
  Map<String, Object?>? permissions,
  bool includePermissions = true,
  bool includeWidget = true,
}) => {
  'data': {
    if (includeActor) 'currentUser': actor,
    'workItem':
        workItem ??
        _node(
          group: group,
          updatedAt: updatedAt,
          users: users,
          hasNext: hasNext,
          cursor: cursor,
          allowsMultiple: allowsMultiple,
          permissions: permissions,
          includePermissions: includePermissions,
          includeWidget: includeWidget,
        ),
  },
};

Map<String, Object?> _mutationBody({
  bool group = false,
  List<Map<String, Object?>> users = const [],
  bool hasNext = false,
  String? cursor,
  DateTime? updatedAt,
  List<Object?> errors = const [],
  bool includeActor = false,
  Object? actor,
  Object? allowsMultiple = true,
}) => {
  'data': {
    if (includeActor) 'currentUser': actor,
    'workItemUpdate': {
      'errors': errors,
      'workItem': _node(
        group: group,
        updatedAt: updatedAt ?? _savedAt,
        users: users,
        hasNext: hasNext,
        cursor: cursor,
        allowsMultiple: allowsMultiple,
        includePermissions: false,
      ),
    },
  },
};

Map<String, Object?> _candidates({
  required bool project,
  required String id,
  required String fullPath,
  required List<Map<String, Object?>> users,
  Object? actor = const {'id': _actorId},
}) => {
  'data': {
    'currentUser': actor,
    project ? 'project' : 'group': {
      'id': id,
      'fullPath': fullPath,
      'autocompleteUsers': users,
    },
  },
};

Map<String, Object?> _body(RequestOptions request) =>
    (request.data as Map).cast<String, Object?>();

String _query(RequestOptions request) => _body(request)['query']! as String;

Map<String, Object?> _variables(RequestOptions request) =>
    (_body(request)['variables']! as Map).cast<String, Object?>();

bool _isMutation(RequestOptions request) =>
    _query(request).contains('workItemUpdate');

bool _isSearch(RequestOptions request) =>
    _query(request).contains('autocompleteUsers');

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

List<Map<String, Object?>> _users(int from, int count) => [
  for (var id = from; id < from + count; id++) _user(id),
];

void main() {
  test(
    'project and group reads repeat actor and full identity on every page',
    () async {
      for (final group in [false, true]) {
        final seen = <Map<String, Object?>>[];
        final adapter = FakeAdapter((request) {
          expect(_isMutation(request), isFalse);
          final variables = _variables(request);
          expect(variables['id'], _summary(group: group).id);
          final query = _query(request);
          expect(query, contains('currentUser'));
          expect(query, contains('iid'));
          expect(query, contains('project { id fullPath }'));
          expect(query, contains('namespace { id fullPath }'));
          expect(query, contains('setWorkItemMetadata'));
          expect(query, contains('assignees(first: 100, after: \$after)'));
          seen.add(variables);
          final after = variables['after'];
          if (after == null) {
            return jsonResponse(
              _read(
                group: group,
                users: _users(10, 100),
                hasNext: true,
                cursor: 'page-2',
              ),
            );
          }
          expect(after, 'page-2');
          return jsonResponse(
            _read(group: group, users: [_user(200)], cursor: 'done'),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final stale = [
          for (var id = 1; id <= 20; id++)
            WorkItemGraphAssignee(
              id: 'gid://gitlab/User/$id',
              name: 'Stale $id',
              username: 'stale$id',
            ),
        ];
        final access = await api.workItemAssignees(
          _detail(group: group, stale: stale),
          expectedUserId: 7,
          isCurrent: () => true,
        );
        expect(access.snapshot.users, hasLength(101));
        expect(
          access.snapshot.assigneeIds,
          isNot(contains('gid://gitlab/User/1')),
        );
        expect(access.snapshot.assigneeIds.first, 'gid://gitlab/User/10');
        expect(access.snapshot.allowsMultiple, isTrue);
        expect(access.snapshot.actorId, _actorId);
        expect(access.snapshot.updatedAt, _freshAt);
        expect(access.canWrite, isTrue);
        expect(access.target, isNotNull);
        expect(access.target!.consumed, isFalse);
        expect(access.target!.setWorkItemMetadata, isTrue);
        expect(access.target!.assigneesWidgetPresent, isTrue);
        expect(seen, hasLength(2));
      }
    },
  );

  test(
    '2000 assignees on the last page are complete and a 20th next page is not',
    () async {
      Future<void> run({required bool overflow}) async {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          expect(_isMutation(request), isFalse);
          final after = _variables(request)['after'];
          final page = after == null ? 0 : int.parse('$after');
          reads++;
          final last = page == 19;
          return jsonResponse(
            _read(
              users: _users(page * 100 + 1, 100),
              hasNext: !last || overflow,
              cursor: last ? 'stuck' : '${page + 1}',
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final future = api.workItemAssignees(
          _detail(),
          expectedUserId: 7,
          isCurrent: () => true,
        );
        if (!overflow) {
          final access = await future;
          expect(access.snapshot.users, hasLength(2000));
          expect(access.target, isNotNull);
          expect(reads, 20);
        } else {
          await expectLater(future, throwsA(_failure(FailureKind.unsupported)));
          expect(reads, 20);
        }
      }

      await run(overflow: false);
      await run(overflow: true);
    },
  );

  test(
    'malformed ids, repeated cursors and a moved revision do not return a target',
    () async {
      Future<void> expectRejected(
        ResponseBody Function(int page) respond,
      ) async {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          expect(_isMutation(request), isFalse);
          reads++;
          return respond(reads);
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          api.workItemAssignees(
            _detail(),
            expectedUserId: 7,
            isCurrent: () => true,
          ),
          throwsA(_failure(FailureKind.unsupported)),
        );
        expect(adapter.requests.where(_isMutation), isEmpty);
      }

      await expectRejected((page) {
        if (page == 1) {
          return jsonResponse(
            _read(users: _users(1, 1), hasNext: true, cursor: 'next'),
          );
        }
        return jsonResponse(
          _read(
            users: [
              {
                'id': 'gid://gitlab/Project/4',
                'name': 'Not a user',
                'username': 'nope',
              },
            ],
          ),
        );
      });
      await expectRejected((page) {
        if (page == 1) {
          return jsonResponse(
            _read(users: [_user(1)], hasNext: true, cursor: 'same'),
          );
        }
        return jsonResponse(
          _read(users: [_user(2)], hasNext: true, cursor: 'same'),
        );
      });
      await expectRejected((page) {
        if (page == 1) {
          return jsonResponse(
            _read(users: [_user(1)], hasNext: true, cursor: 'next'),
          );
        }
        return jsonResponse(_read(users: [_user(1)]));
      });
      await expectRejected((page) {
        if (page == 1) {
          return jsonResponse(
            _read(users: [_user(1)], hasNext: true, cursor: 'next'),
          );
        }
        return jsonResponse(_read(users: [_user(2)], updatedAt: _savedAt));
      });
    },
  );

  test(
    'candidates are one array of at most 20 and stay inside the target container',
    () async {
      for (final group in [false, true]) {
        final adapter = FakeAdapter((request) {
          if (!_isSearch(request)) {
            return jsonResponse(_read(group: group, users: [_user(2)]));
          }
          final query = _query(request);
          expect(query.contains('first'), isFalse);
          expect(query.contains('after'), isFalse);
          if (group) {
            expect(query, contains('group(fullPath:'));
            expect(query.contains('project('), isFalse);
          } else {
            expect(query, contains('project(fullPath:'));
            expect(query.contains('group('), isFalse);
          }
          final summary = _summary(group: group);
          final ref = group ? summary.namespace! : summary.project!;
          expect(_variables(request)['fullPath'], ref.fullPath);
          expect(_variables(request)['search'], 'ada');
          return jsonResponse(
            _candidates(
              project: !group,
              id: ref.id,
              fullPath: ref.fullPath,
              users: _users(30, 20),
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemAssignees(
          _detail(group: group),
          expectedUserId: 7,
          isCurrent: () => true,
        )).target!;
        final found = await api.searchWorkItemAssigneeCandidates(
          target,
          search: ' ada ',
          isCurrent: () => true,
        );
        expect(found, hasLength(20));
        expect(target.consumed, isFalse);
        await api.searchWorkItemAssigneeCandidates(
          target,
          search: 'ada',
          isCurrent: () => true,
        );
        expect(target.consumed, isFalse);
      }
    },
  );

  test(
    'a 21st candidate, the wrong container, and a missing widget or bool are unsupported',
    () async {
      final summary = _summary();
      final tooMany = FakeAdapter((request) {
        if (_isSearch(request)) {
          return jsonResponse(
            _candidates(
              project: true,
              id: summary.project!.id,
              fullPath: summary.project!.fullPath,
              users: _users(1, 21),
            ),
          );
        }
        return jsonResponse(_read(users: [_user(1)]));
      });
      final api = testApi(tooMany);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        api.searchWorkItemAssigneeCandidates(
          target,
          search: 'ada',
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(target.consumed, isFalse);

      final wrong = FakeAdapter((request) {
        if (_isSearch(request)) {
          return jsonResponse(
            _candidates(
              project: true,
              id: 'gid://gitlab/Project/99',
              fullPath: summary.project!.fullPath,
              users: [_user(3)],
            ),
          );
        }
        return jsonResponse(_read(users: [_user(1)]));
      });
      final wrongApi = testApi(wrong);
      addTearDown(wrongApi.close);
      final wrongTarget = (await wrongApi.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        wrongApi.searchWorkItemAssigneeCandidates(
          wrongTarget,
          search: 'ada',
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );

      for (final respond in [
        () => jsonResponse(_read(includeWidget: false, users: const [])),
        () => jsonResponse(_read(allowsMultiple: null, users: [_user(1)])),
      ]) {
        final adapter = FakeAdapter((request) => respond());
        final reading = testApi(adapter);
        addTearDown(reading.close);
        await expectLater(
          reading.workItemAssignees(
            _detail(),
            expectedUserId: 7,
            isCurrent: () => true,
          ),
          throwsA(_failure(FailureKind.unsupported)),
        );
      }
    },
  );

  test(
    'metadata permission is required and admin or update permission is not a substitute',
    () async {
      Future<WorkItemAssigneeAccess?> read(
        Map<String, Object?> permissions,
      ) async {
        final adapter = FakeAdapter(
          (request) =>
              jsonResponse(_read(users: [_user(4)], permissions: permissions)),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        return api.workItemAssignees(
          _detail(),
          expectedUserId: 7,
          isCurrent: () => true,
        );
      }

      final denied = await read({
        'readWorkItem': true,
        'setWorkItemMetadata': false,
        'adminWorkItem': true,
        'updateWorkItem': true,
      });
      expect(denied!.canWrite, isFalse);
      expect(denied.target, isNull);
      expect(denied.snapshot.users.single.id, 'gid://gitlab/User/4');

      final adapter = FakeAdapter(
        (request) => jsonResponse(
          _read(
            users: [_user(4)],
            permissions: {'readWorkItem': true, 'adminWorkItem': true},
          ),
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemAssignees(
          _detail(),
          expectedUserId: 7,
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );
    },
  );

  test(
    'no-op, clear, one user and many users each consume the target once',
    () async {
      Future<void> run({
        required List<int> current,
        required List<int> desired,
        required bool writes,
      }) async {
        var mutations = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            mutations++;
            final input = _variables(request)['input']! as Map;
            expect(input.keys.toSet(), {'id', 'assigneesWidget'});
            expect(input['id'], _summary().id);
            final widget = input['assigneesWidget']! as Map;
            expect(widget.keys.toSet(), {'assigneeIds'});
            expect(widget['assigneeIds'], [
              for (final id in desired) 'gid://gitlab/User/$id',
            ]);
            return jsonResponse(
              _mutationBody(
                users: [for (final id in desired) _user(id)],
                updatedAt: _savedAt,
              ),
            );
          }
          final phase = _variables(request)['after'];
          expect(phase, isNull);
          final fresh = mutations == 0;
          final ids = fresh ? current : desired;
          return jsonResponse(
            _read(
              users: [for (final id in ids) _user(id)],
              updatedAt: fresh ? _freshAt : _savedAt,
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemAssignees(
          _detail(),
          expectedUserId: 7,
          isCurrent: () => true,
        )).target!;
        final saved = await api.updateWorkItemAssignees(
          target,
          assigneeIds: [for (final id in desired) 'gid://gitlab/User/$id'],
          isCurrent: () => true,
        );
        expect(target.consumed, isTrue);
        expect(saved.assigneeIds.toSet(), {
          for (final id in desired) 'gid://gitlab/User/$id',
        });
        expect(mutations, writes ? 1 : 0);
        if (writes) expect(saved.updatedAt, _savedAt);
        await expectLater(
          api.updateWorkItemAssignees(
            target,
            assigneeIds: [for (final id in desired) 'gid://gitlab/User/$id'],
            isCurrent: () => true,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(mutations, writes ? 1 : 0);
      }

      await run(current: [], desired: [], writes: false);
      await run(current: [5], desired: [5], writes: false);
      await run(current: [5, 6], desired: [6, 5], writes: false);
      await run(current: [5, 6], desired: [], writes: true);
      await run(current: [], desired: [8], writes: true);
      await run(current: [8], desired: [9, 10], writes: true);
    },
  );

  test(
    'a second concurrent update and a filtered acknowledgement send one mutation',
    () async {
      var gate = 0;
      final adapter = FakeAdapter((request) async {
        if (_isMutation(request)) {
          return jsonResponse(_mutationBody(users: [_user(9)]));
        }
        gate++;
        if (gate == 2) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final ids = gate <= 2 ? [5] : [9];
        return jsonResponse(_read(users: [for (final id in ids) _user(id)]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      final first = api.updateWorkItemAssignees(
        target,
        assigneeIds: const ['gid://gitlab/User/9'],
        isCurrent: () => true,
      );
      final second = api.updateWorkItemAssignees(
        target,
        assigneeIds: const ['gid://gitlab/User/9'],
        isCurrent: () => true,
      );
      await expectLater(second, throwsA(_failure(FailureKind.writeUncertain)));
      expect(await first, isA<WorkItemAssigneeSnapshot>());
      expect(adapter.requests.where(_isMutation), hasLength(1));

      var writes = 0;
      final filtered = FakeAdapter((request) {
        if (_isMutation(request)) {
          writes++;
          final input = _variables(request)['input']! as Map;
          expect((input['assigneesWidget']! as Map)['assigneeIds'], [
            'gid://gitlab/User/9',
            'gid://gitlab/User/10',
          ]);
          return jsonResponse(_mutationBody(users: [_user(9)]));
        }
        return jsonResponse(_read(users: [_user(2)]));
      });
      final filteredApi = testApi(filtered);
      addTearDown(filteredApi.close);
      final filteredTarget = (await filteredApi.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        filteredApi.updateWorkItemAssignees(
          filteredTarget,
          assigneeIds: const ['gid://gitlab/User/9', 'gid://gitlab/User/10'],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(writes, 1);
      expect(filteredTarget.consumed, isTrue);
    },
  );

  test('readback that drops a user is uncertain after one write', () async {
    var writes = 0;
    late final FakeAdapter adapter;
    adapter = FakeAdapter((request) {
      if (_isMutation(request)) {
        writes++;
        return jsonResponse(_mutationBody(users: [_user(9), _user(10)]));
      }
      final reads = adapter.requests.where((item) => !_isMutation(item)).length;
      final ids = reads <= 2 ? [2] : [9];
      return jsonResponse(_read(users: [for (final id in ids) _user(id)]));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = (await api.workItemAssignees(
      _detail(),
      expectedUserId: 7,
      isCurrent: () => true,
    )).target!;
    await expectLater(
      api.updateWorkItemAssignees(
        target,
        assigneeIds: const ['gid://gitlab/User/9', 'gid://gitlab/User/10'],
        isCurrent: () => true,
      ),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(writes, 1);
  });

  test(
    'the fresh preflight rejects a changed actor, scope, revision, epoch or owner before writing',
    () async {
      var actorReads = 0;
      final actorAdapter = FakeAdapter((request) {
        if (_isMutation(request)) fail('wrote');
        actorReads++;
        return jsonResponse(
          _read(
            users: [_user(2)],
            actor: actorReads < 2
                ? const {'id': _actorId}
                : const {'id': 'gid://gitlab/User/8'},
          ),
        );
      });
      final actorApi = testApi(actorAdapter);
      addTearDown(actorApi.close);
      final actorTarget = (await actorApi.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        actorApi.updateWorkItemAssignees(
          actorTarget,
          assigneeIds: const ['gid://gitlab/User/3'],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );

      var scopeReads = 0;
      final scopeAdapter = FakeAdapter((request) {
        if (_isMutation(request)) fail('wrote');
        scopeReads++;
        if (scopeReads < 2) return jsonResponse(_read(users: [_user(2)]));
        final node = _node(users: [_user(2)]);
        node['namespace'] = {
          'id': 'gid://gitlab/Namespaces::ProjectNamespace/99',
          'fullPath': 'other/place',
        };
        return jsonResponse({
          'data': {
            'currentUser': {'id': _actorId},
            'workItem': node,
          },
        });
      });
      final scopeApi = testApi(scopeAdapter);
      addTearDown(scopeApi.close);
      final scopeTarget = (await scopeApi.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        scopeApi.updateWorkItemAssignees(
          scopeTarget,
          assigneeIds: const ['gid://gitlab/User/3'],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );

      var revisionReads = 0;
      final revisionAdapter = FakeAdapter((request) {
        if (_isMutation(request)) fail('wrote');
        revisionReads++;
        return jsonResponse(
          _read(
            users: [_user(2)],
            updatedAt: revisionReads < 2 ? _freshAt : _savedAt,
          ),
        );
      });
      final revisionApi = testApi(revisionAdapter);
      addTearDown(revisionApi.close);
      final revisionTarget = (await revisionApi.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        revisionApi.updateWorkItemAssignees(
          revisionTarget,
          assigneeIds: const ['gid://gitlab/User/3'],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.conflict)),
      );

      final epochAdapter = FakeAdapter((request) {
        if (_isMutation(request)) fail('wrote');
        return jsonResponse(_read(users: [_user(2)]));
      });
      final epochApi = testApi(epochAdapter);
      addTearDown(epochApi.close);
      final epochTarget = (await epochApi.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      epochApi.clearReadCache();
      await expectLater(
        epochApi.updateWorkItemAssignees(
          epochTarget,
          assigneeIds: const ['gid://gitlab/User/3'],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(epochAdapter.requests.where(_isMutation), isEmpty);

      final ownerAdapter = FakeAdapter(
        (request) => jsonResponse(_read(users: [_user(2)])),
      );
      final ownerApi = testApi(ownerAdapter);
      addTearDown(ownerApi.close);
      final ownerTarget = (await ownerApi.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      final other = testApi(FakeAdapter((request) => jsonResponse(_read())));
      addTearDown(other.close);
      await expectLater(
        other.updateWorkItemAssignees(
          ownerTarget,
          assigneeIds: const ['gid://gitlab/User/3'],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(ownerTarget.consumed, isFalse);
    },
  );

  test(
    'invalid and duplicate ids and a second person in single mode send nothing',
    () async {
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) fail('wrote');
        return jsonResponse(_read(users: [_user(2)], allowsMultiple: false));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      for (final ids in [
        const ['user-2'],
        const ['gid://gitlab/User/2', 'gid://gitlab/User/2'],
        const ['gid://gitlab/User/2', 'gid://gitlab/User/3'],
      ]) {
        await expectLater(
          api.updateWorkItemAssignees(
            target,
            assigneeIds: ids,
            isCurrent: () => true,
          ),
          throwsA(_failure(FailureKind.validation)),
        );
      }
      expect(target.consumed, isFalse);
      expect(adapter.requests.where(_isMutation), isEmpty);
      final saved = await api.updateWorkItemAssignees(
        target,
        assigneeIds: const ['gid://gitlab/User/2'],
        isCurrent: () => true,
      );
      expect(saved.assigneeIds, ['gid://gitlab/User/2']);
    },
  );

  test(
    'fresh metadata denial sends nothing and still consumes the target',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) fail('wrote');
        reads++;
        return jsonResponse(
          _read(
            users: [_user(2)],
            permissions: {
              'readWorkItem': true,
              'setWorkItemMetadata': reads > 1 ? false : true,
              'adminWorkItem': true,
            },
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        api.updateWorkItemAssignees(
          target,
          assigneeIds: const <String>[],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.forbidden)),
      );
      expect(target.consumed, isTrue);
      expect(adapter.requests.where(_isMutation), isEmpty);
    },
  );

  test(
    'HTTP 400, 422 and cancellation after the request are uncertain and are not retried',
    () async {
      Future<void> run(ResponseBody Function() respond) async {
        var writes = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            writes++;
            return respond();
          }
          return jsonResponse(_read(users: [_user(2)]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemAssignees(
          _detail(),
          expectedUserId: 7,
          isCurrent: () => true,
        )).target!;
        await expectLater(
          api.updateWorkItemAssignees(
            target,
            assigneeIds: const ['gid://gitlab/User/9'],
            isCurrent: () => true,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(writes, 1);
      }

      await run(() => jsonResponse({'errors': 'nope'}, status: 400));
      await run(() => jsonResponse({'message': 'no'}, status: 422));
      await run(() {
        throw DioException(
          requestOptions: RequestOptions(path: '/api/graphql'),
          type: DioExceptionType.cancel,
        );
      });
    },
  );

  test('HTTP 200 string errors are validation and do not read back', () async {
    var writes = 0;
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_isMutation(request)) {
        writes++;
        return jsonResponse(
          _mutationBody(users: [_user(9)], errors: const ['taken']),
        );
      }
      reads++;
      return jsonResponse(_read(users: [_user(2)]));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = (await api.workItemAssignees(
      _detail(),
      expectedUserId: 7,
      isCurrent: () => true,
    )).target!;
    await expectLater(
      api.updateWorkItemAssignees(
        target,
        assigneeIds: const ['gid://gitlab/User/9'],
        isCurrent: () => true,
      ),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(writes, 1);
    expect(reads, 2);
  });

  test(
    'an inactive current assignee can be kept when search does not list them',
    () async {
      final summary = _summary();
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_isSearch(request)) {
          return jsonResponse(
            _candidates(
              project: true,
              id: summary.project!.id,
              fullPath: summary.project!.fullPath,
              users: [_user(30)],
            ),
          );
        }
        if (_isMutation(request)) {
          final ids = (_variables(request)['input']! as Map)['assigneesWidget'];
          expect((ids! as Map)['assigneeIds'], [
            'gid://gitlab/User/2',
            'gid://gitlab/User/30',
          ]);
          return jsonResponse(_mutationBody(users: [_user(2), _user(30)]));
        }
        reads++;
        final users = reads <= 2 ? [_user(2)] : [_user(2), _user(30)];
        return jsonResponse(_read(users: users));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      final found = await api.searchWorkItemAssigneeCandidates(
        target,
        search: 'new',
        isCurrent: () => true,
      );
      expect(found.single.id, 'gid://gitlab/User/30');
      expect(target.assigneeIds, ['gid://gitlab/User/2']);
      final saved = await api.updateWorkItemAssignees(
        target,
        assigneeIds: const ['gid://gitlab/User/2', 'gid://gitlab/User/30'],
        isCurrent: () => true,
      );
      expect(saved.assigneeIds.toSet(), {
        'gid://gitlab/User/2',
        'gid://gitlab/User/30',
      });
    },
  );

  test(
    'selected mutation fields publish through one write and a complete read',
    () async {
      for (final group in [false, true]) {
        var writes = 0;
        final adapter = FakeAdapter((request) {
          final query = _query(request);
          if (_isMutation(request)) {
            writes++;
            expect(query, isNot(contains('currentUser')));
            expect(query, isNot(contains('author')));
            expect(query, contains('workItemUpdate'));
            return jsonResponse(
              _mutationBody(
                group: group,
                users: [_user(9)],
                updatedAt: _savedAt,
              ),
            );
          }
          expect(query, contains('currentUser'));
          final fresh = writes == 0;
          return jsonResponse(
            _read(
              group: group,
              users: [_user(fresh ? 2 : 9)],
              updatedAt: fresh ? _freshAt : _savedAt,
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemAssignees(
          _detail(group: group),
          expectedUserId: 7,
          isCurrent: () => true,
        )).target!;
        final saved = await api.updateWorkItemAssignees(
          target,
          assigneeIds: const ['gid://gitlab/User/9'],
          isCurrent: () => true,
        );
        expect(writes, 1);
        expect(saved.assigneeIds, ['gid://gitlab/User/9']);
        expect(saved.actorId, _actorId);
      }
    },
  );

  test(
    'HTTP 200 string errors without an actor are validation and do not read back',
    () async {
      var writes = 0;
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          writes++;
          return jsonResponse({
            'data': {
              'workItemUpdate': {
                'errors': ['no'],
              },
            },
          });
        }
        reads++;
        return jsonResponse(_read(users: [_user(2)]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        api.updateWorkItemAssignees(
          target,
          assigneeIds: const ['gid://gitlab/User/9'],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(writes, 1);
      expect(reads, 2);
    },
  );

  test(
    'an extra mutation actor is ignored and a wrong readback actor fails',
    () async {
      var writes = 0;
      final accepted = FakeAdapter((request) {
        if (_isMutation(request)) {
          writes++;
          return jsonResponse(
            _mutationBody(
              users: [_user(9)],
              includeActor: true,
              actor: const {'id': 'gid://gitlab/User/8'},
              updatedAt: _savedAt,
            ),
          );
        }
        final fresh = writes == 0;
        return jsonResponse(
          _read(
            users: [_user(fresh ? 2 : 9)],
            updatedAt: fresh ? _freshAt : _savedAt,
          ),
        );
      });
      final api = testApi(accepted);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      final saved = await api.updateWorkItemAssignees(
        target,
        assigneeIds: const ['gid://gitlab/User/9'],
        isCurrent: () => true,
      );
      expect(writes, 1);
      expect(saved.actorId, _actorId);

      var rejectedWrites = 0;
      final rejected = FakeAdapter((request) {
        if (_isMutation(request)) {
          rejectedWrites++;
          return jsonResponse(
            _mutationBody(
              users: [_user(9)],
              includeActor: true,
              actor: const {'id': 'gid://gitlab/User/8'},
            ),
          );
        }
        final fresh = rejectedWrites == 0;
        return jsonResponse(
          _read(
            users: [_user(fresh ? 2 : 9)],
            actor: fresh
                ? const {'id': _actorId}
                : const {'id': 'gid://gitlab/User/8'},
          ),
        );
      });
      final rejectedApi = testApi(rejected);
      addTearDown(rejectedApi.close);
      final rejectedTarget = (await rejectedApi.workItemAssignees(
        _detail(),
        expectedUserId: 7,
        isCurrent: () => true,
      )).target!;
      await expectLater(
        rejectedApi.updateWorkItemAssignees(
          rejectedTarget,
          assigneeIds: const ['gid://gitlab/User/9'],
          isCurrent: () => true,
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(rejectedWrites, 1);
    },
  );

  test(
    'acknowledgement pages must keep the mutation revision before readback',
    () async {
      Future<void> run({required bool changed}) async {
        var writes = 0;
        var continuations = 0;
        var readbacks = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            writes++;
            return jsonResponse(
              _mutationBody(
                users: [_user(9)],
                hasNext: true,
                cursor: 'ack-2',
                updatedAt: _savedAt,
              ),
            );
          }
          final after = _variables(request)['after'];
          if (writes == 0) {
            return jsonResponse(_read(users: [_user(2)], updatedAt: _freshAt));
          }
          if (after == 'ack-2') {
            continuations++;
            return jsonResponse(
              _read(
                users: [_user(10)],
                updatedAt: changed ? _freshAt : _savedAt,
              ),
            );
          }
          readbacks++;
          return jsonResponse(
            _read(users: [_user(9), _user(10)], updatedAt: _savedAt),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemAssignees(
          _detail(),
          expectedUserId: 7,
          isCurrent: () => true,
        )).target!;
        final future = api.updateWorkItemAssignees(
          target,
          assigneeIds: const ['gid://gitlab/User/9', 'gid://gitlab/User/10'],
          isCurrent: () => true,
        );
        if (changed) {
          await expectLater(
            future,
            throwsA(_failure(FailureKind.writeUncertain)),
          );
          expect(readbacks, 0);
        } else {
          final saved = await future;
          expect(saved.assigneeIds.toSet(), {
            'gid://gitlab/User/9',
            'gid://gitlab/User/10',
          });
          expect(readbacks, 1);
        }
        expect(writes, 1);
        expect(continuations, 1);
      }

      await run(changed: true);
      await run(changed: false);
    },
  );

  test(
    'malformed selected mutation fields are uncertain and are not replayed',
    () async {
      Future<void> run(Map<String, Object?> body) async {
        var writes = 0;
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            writes++;
            return jsonResponse(body);
          }
          reads++;
          return jsonResponse(_read(users: [_user(2)]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemAssignees(
          _detail(),
          expectedUserId: 7,
          isCurrent: () => true,
        )).target!;
        await expectLater(
          api.updateWorkItemAssignees(
            target,
            assigneeIds: const ['gid://gitlab/User/9'],
            isCurrent: () => true,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(writes, 1);
        expect(reads, 2);
      }

      await run({
        'data': {
          'workItemUpdate': {'errors': 'no', 'workItem': null},
        },
      });
      await run({
        'data': {
          'workItemUpdate': {'errors': <Object?>[], 'workItem': null},
        },
      });
    },
  );
}
