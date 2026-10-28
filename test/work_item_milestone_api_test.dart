import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_milestone_models.dart';

import 'support/fake_adapter.dart';
import 'support/strict_group_owner.dart';

const _actorId = 'gid://gitlab/User/7';
final _createdAt = DateTime.utc(2026, 10, 1);
final _freshAt = DateTime.utc(2026, 10, 3, 9);
final _savedAt = DateTime.utc(2026, 10, 3, 10);

WorkItemGraphSummary _summary({bool group = false}) => WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/${group ? 41 : 31}',
  iid: group ? 41 : 31,
  title: 'Displayed stale title',
  state: 'OPEN',
  createdAt: _createdAt,
  updatedAt: DateTime.utc(2026, 10, 2),
  project: group
      ? null
      : const GraphResourceRef(
          id: 'gid://gitlab/Project/42',
          fullPath: 'studio/mobile-workspace',
        ),
  namespace: group
      ? const GraphResourceRef(
          id: 'gid://gitlab/Group/84',
          fullPath: 'studio/platform',
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

WorkItemGraphDetail _detail({bool group = false}) => WorkItemGraphDetail(
  summary: _summary(group: group),
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'MILESTONE'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Map<String, Object?> _milestone({
  int id = 5,
  String title = 'October',
  String state = 'ACTIVE',
  bool expired = false,
  bool groupOwner = false,
  String? ownerPath,
}) => {
  'id': 'gid://gitlab/Milestone/$id',
  'iid': '$id',
  'title': title,
  'state': state,
  'expired': expired,
  'dueDate': '2026-10-31',
  'startDate': '2026-10-01',
  'webPath': '/groups/studio/-/milestones/$id',
  'project': groupOwner
      ? null
      : {
          'id': 'gid://gitlab/Project/42',
          'fullPath': ownerPath ?? 'studio/mobile-workspace',
        },
  'group': groupOwner
      ? {
          'id': 'gid://gitlab/Group/84',
          'fullPath': ownerPath ?? 'studio/platform',
        }
      : null,
};

Map<String, Object?> _node({
  bool group = false,
  DateTime? updatedAt,
  Object? milestone = _sentinel,
  Object? widgets = _sentinel,
  bool includePermissions = true,
  Object? readPermission = true,
  Object? metadataPermission = true,
  Map<String, Object?> changes = const {},
}) {
  final expected = _summary(group: group);
  final effectiveMilestone = identical(milestone, _sentinel)
      ? _milestone(groupOwner: group)
      : milestone;
  final effectiveWidgets = identical(widgets, _sentinel)
      ? [
          {'type': 'MILESTONE', 'milestone': effectiveMilestone},
        ]
      : widgets;
  return {
    'id': expected.id,
    'iid': '${expected.iid}',
    'title': 'Fresh title',
    'state': 'OPEN',
    'createdAt': _createdAt.toIso8601String(),
    'updatedAt': (updatedAt ?? _freshAt).toIso8601String(),
    'project': expected.project == null
        ? null
        : {'id': expected.project!.id, 'fullPath': expected.project!.fullPath},
    'namespace': {
      'id': expected.namespace!.id,
      'fullPath': expected.namespace!.fullPath,
    },
    'workItemType': {'id': expected.type.id, 'name': expected.type.name},
    if (includePermissions)
      'userPermissions': {
        'readWorkItem': readPermission,
        'setWorkItemMetadata': metadataPermission,
      },
    'widgets': effectiveWidgets,
    ...changes,
  };
}

Map<String, Object?> _read({
  bool group = false,
  Object? actor = const {'id': _actorId},
  DateTime? updatedAt,
  Object? milestone = _sentinel,
  Object? widgets = _sentinel,
  Object? readPermission = true,
  Object? metadataPermission = true,
  Map<String, Object?> changes = const {},
}) => {
  'data': {
    'currentUser': actor,
    'workItem': _node(
      group: group,
      updatedAt: updatedAt,
      milestone: milestone,
      widgets: widgets,
      readPermission: readPermission,
      metadataPermission: metadataPermission,
      changes: changes,
    ),
  },
};

Map<String, Object?> _ack({
  bool group = false,
  Object? errors = const <Object?>[],
  Object? milestone = _sentinel,
  Object? workItem = _sentinel,
}) => {
  'data': {
    'workItemUpdate': {
      'errors': errors,
      'workItem': identical(workItem, _sentinel)
          ? _node(
              group: group,
              updatedAt: _savedAt,
              milestone: milestone,
              includePermissions: false,
            )
          : workItem,
    },
  },
};

Map<String, Object?> _picker({
  bool group = false,
  required List<Map<String, Object?>> nodes,
  bool hasNext = false,
  String? endCursor,
  Object? actor = const {'id': _actorId},
}) {
  final summary = _summary(group: group);
  final key = group ? 'group' : 'project';
  final ref = group ? summary.namespace! : summary.project!;
  return {
    'data': {
      'currentUser': actor,
      key: {
        'id': ref.id,
        'fullPath': ref.fullPath,
        'milestones': {
          'nodes': nodes,
          'pageInfo': {'hasNextPage': hasNext, 'endCursor': endCursor},
        },
      },
    },
  };
}

const _sentinel = Object();
String _query(RequestOptions request) =>
    (request.data as Map)['query'] as String;
Map<Object?, Object?> _variables(RequestOptions request) =>
    (request.data as Map)['variables'] as Map<Object?, Object?>;
bool _mutation(RequestOptions request) =>
    _query(request).startsWith('mutation ');
Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

Future<WorkItemMilestoneTarget> _target(
  GitLabApi api, {
  bool group = false,
}) async => (await api.workItemMilestone(
  _detail(group: group),
  expectedUserId: 7,
)).target!;

void main() {
  for (final problem in ['exact', 'missing', 'project', 'namespace', 'payloadErrors', 'cancelled', 'schemaErrors']) {
    for (final phase in ['opening', 'preflight', 'noop', 'ack', 'readback']) {
      if (['payloadErrors', 'cancelled', 'schemaErrors'].contains(problem) && phase != 'ack') continue;
      test(
        'strict milestone $phase $problem validates raw group owner',
        () async {
          var reads = 0;
          var writes = 0;
        var current = true;
          final adapter = FakeAdapter((request) {
            late Map<String, Object?> response;
            late Map<String, Object?> item;
            if (_query(request).startsWith('mutation ')) {
              writes++;
              response = _ack(group: true, milestone: null);
              item =
                  ((response['data'] as Map)['workItemUpdate']
                          as Map)['workItem']
                      as Map<String, Object?>;
              if (phase == 'ack') {
              if (problem == 'payloadErrors') {
                final payload = (response['data'] as Map)['workItemUpdate'] as Map;
                payload['errors'] = ['rejected'];
                payload.remove('workItem');
              } else if (problem == 'cancelled') {
                current = false;
              } else if (problem == 'schemaErrors') {
                response = {'errors': [{'message': 'unknown field', 'extensions': {'code': 'undefinedField'}}]};
              } else {
                corruptGroupOwner(item, problem);
              }
            }
            } else {
              reads++;
              response = _read(
                group: true,
                milestone: reads < 3 ? _milestone(groupOwner: true) : null,
                updatedAt: reads < 3 ? _freshAt : _savedAt,
              );
              item =
                  (response['data'] as Map)['workItem'] as Map<String, Object?>;
              if ((phase == 'opening' && reads == 1) ||
                  ((phase == 'preflight' || phase == 'noop') && reads == 2) ||
                  (phase == 'readback' && reads == 3)) {
                corruptGroupOwner(item, problem);
              }
            }
            return jsonResponse(response);
          });
          final api = testApi(adapter);
          addTearDown(api.close);
          final opening = api.workItemMilestone(
            strictGroupDetail(api, _detail(group: true)),
            expectedUserId: 7,
          );
          if (phase == 'opening' && problem != 'exact') {
            await expectLater(opening, throwsA(isA<ApiFailure>()));
            expect(writes, 0);
            return;
          }
          final access = await opening;
          if (phase == 'opening') return;
          final save = api.updateWorkItemMilestone(
            access.target!,
            isCurrent: () => current,
            selection: phase == 'noop'
                ? access.target!.currentSelection
                : access.target!.clearSelection,
          );
          if (problem == 'exact') {
            expect(
              (await save).snapshot.milestone,
              phase == 'noop' ? isNotNull : isNull,
            );
          } else {
            final post = phase == 'ack' || phase == 'readback';
            await expectLater(
              save,
              throwsA(
                isA<ApiFailure>().having(
                  (e) => post
                      ? e.kind == FailureKind.writeUncertain
                      : e.kind != FailureKind.writeUncertain,
                  'classification',
                  isTrue,
                ),
              ),
            );
          }
          expect(
            writes,
            phase == 'noop' || (phase == 'preflight' && problem != 'exact')
                ? 0
                : 1,
          );
        },
      );
    }
  }

  test(
    'default milestone accepts omitted project for group compatibility',
    () async {
      final response = _read(group: true);
      ((response['data'] as Map)['workItem'] as Map).remove('project');
      final api = testApi(FakeAdapter((_) => jsonResponse(response)));
      addTearDown(api.close);
      expect(
        (await api.workItemMilestone(
          _detail(group: true),
          expectedUserId: 7,
        )).target,
        isNotNull,
      );
    },
  );

  for (final group in [false, true]) {
    test(
      '${group ? 'group' : 'project'} read uses metadata permissions and exposes server expiry',
      () async {
        final adapter = FakeAdapter(
          (_) => jsonResponse(
            _read(
              group: group,
              milestone: _milestone(
                groupOwner: group,
                expired: true,
                state: 'CLOSED',
              ),
            ),
          ),
        );
        final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
        addTearDown(api.close);
        final access = await api.workItemMilestone(
          _detail(group: group),
          expectedUserId: 7,
        );
        expect(access.actorId, _actorId);
        expect(access.snapshot.summary.title, 'Fresh title');
        expect(access.snapshot.milestone!.title, 'October');
        expect(access.snapshot.milestoneExpired, isTrue);
        expect(access.canSetMilestone, isTrue);
        expect(access.target, isNotNull);
        expect(access.target!.currentSelection.milestone!.id, endsWith('/5'));
        final query = _query(adapter.requests.single);
        expect(query, contains('readWorkItem setWorkItemMetadata'));
        expect(query, isNot(contains('updateWorkItem')));
        expect(query, contains('widgets(onlyTypes: [MILESTONE])'));
        expect(query, isNot(contains('lockVersion')));
      },
    );
  }

  test(
    'permission denial and missing widget stay readable without target',
    () async {
      final fixtures = [
        _read(readPermission: false),
        _read(metadataPermission: false),
        _read(widgets: const []),
        _read(widgets: null),
      ];
      var index = 0;
      final adapter = FakeAdapter((_) => jsonResponse(fixtures[index++]));
      final api = testApi(adapter);
      addTearDown(api.close);
      final noRead = await api.workItemMilestone(_detail(), expectedUserId: 7);
      final noMetadata = await api.workItemMilestone(
        _detail(),
        expectedUserId: 7,
      );
      final absent = await api.workItemMilestone(_detail(), expectedUserId: 7);
      final unavailable = await api.workItemMilestone(
        _detail(),
        expectedUserId: 7,
      );
      expect(noRead.canSetMilestone, isFalse);
      expect(noMetadata.canSetMilestone, isFalse);
      expect(
        absent.snapshot.availability,
        WorkItemMilestoneAvailability.absent,
      );
      expect(
        unavailable.snapshot.availability,
        WorkItemMilestoneAvailability.widgetsUnavailable,
      );
      expect([
        noRead.target,
        noMetadata.target,
        absent.target,
        unavailable.target,
      ], everyElement(isNull));
    },
  );

  test(
    'current assigned milestone remains readable when owner branches are null',
    () async {
      final current = {..._milestone(), 'project': null, 'group': null};
      final adapter = FakeAdapter(
        (_) => jsonResponse(_read(milestone: current)),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final access = await api.workItemMilestone(_detail(), expectedUserId: 7);
      expect(access.snapshot.milestone!.id, 'gid://gitlab/Milestone/5');
      expect(access.snapshot.milestone!.project, isNull);
      expect(access.snapshot.milestone!.group, isNull);
      expect(access.target, isNotNull);
    },
  );

  test(
    'project picker is actor/scope bound and returns active choices plus clear',
    () async {
      var requests = 0;
      final adapter = FakeAdapter((request) {
        requests++;
        if (requests == 1) return jsonResponse(_read());
        return jsonResponse(
          _picker(
            nodes: [
              _milestone(id: 6, title: 'Next', expired: true),
              _milestone(
                id: 7,
                title: 'Ancestor',
                groupOwner: true,
                ownerPath: 'studio',
              ),
            ],
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final page = await api.workItemMilestoneChoices(
        target,
        search: '  oct  ',
      );
      expect(page.items.map((item) => item.milestone.title), [
        'Next',
        'Ancestor',
      ]);
      expect(page.items.first.expired, isTrue);
      expect(page.clearSelection.milestone, isNull);
      expect(page.isPartial, isFalse);
      final picker = adapter.requests.last;
      expect(
        _query(picker),
        startsWith('query MobileProjectWorkItemMilestones'),
      );
      expect(_query(picker), contains('first: 50'));
      expect(_query(picker), contains('includeAncestors: true'));
      expect(_query(picker), isNot(contains('includeDescendants')));
      expect(_variables(picker), {
        'fullPath': 'studio/mobile-workspace',
        'after': null,
        'search': 'oct',
      });
    },
  );

  test(
    'group picker trusts fresh resolver ancestry without path-prefix inference',
    () async {
      var requests = 0;
      final adapter = FakeAdapter((_) {
        requests++;
        return jsonResponse(
          requests == 1
              ? _read(group: true)
              : _picker(
                  group: true,
                  nodes: [
                    _milestone(
                      id: 9,
                      groupOwner: true,
                      ownerPath: 'renamed-ancestor',
                    ),
                  ],
                ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final page = await api.workItemMilestoneChoices(
        await _target(api, group: true),
      );
      expect(page.items.single.milestone.group!.fullPath, 'renamed-ancestor');
    },
  );

  test(
    'opaque continuation preserves search/cursor and rejects transplantation',
    () async {
      var requests = 0;
      final adapter = FakeAdapter((_) {
        requests++;
        if (requests == 1) return jsonResponse(_read());
        return jsonResponse(
          _picker(
            nodes: [_milestone(id: requests + 4)],
            hasNext: requests == 2,
            endCursor: requests == 2 ? 'cursor-1' : null,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final first = await api.workItemMilestoneChoices(target, search: 'next');
      expect(first.continuation, isNotNull);
      final second = await api.workItemMilestoneChoices(
        target,
        search: 'next',
        continuation: first.continuation,
      );
      expect(second.continuation, isNull);
      expect(_variables(adapter.requests.last)['after'], 'cursor-1');
      await expectLater(
        api.workItemMilestoneChoices(
          target,
          search: 'changed',
          continuation: first.continuation,
        ),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests, hasLength(3));
    },
  );

  test(
    'picker rejects a milestone repeated on a later unstable-sort page',
    () async {
      var requests = 0;
      final adapter = FakeAdapter((_) {
        requests++;
        if (requests == 1) return jsonResponse(_read());
        return jsonResponse(
          _picker(
            nodes: [_milestone(id: 6)],
            hasNext: requests == 2,
            endCursor: requests == 2 ? 'cursor-1' : null,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final first = await api.workItemMilestoneChoices(target);
      await expectLater(
        api.workItemMilestoneChoices(target, continuation: first.continuation),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
    },
  );

  test(
    'picker caps four server pages at 200 unique choices and reports truncation',
    () async {
      var requests = 0;
      final adapter = FakeAdapter((_) {
        requests++;
        if (requests == 1) return jsonResponse(_read());
        final page = requests - 2;
        return jsonResponse(
          _picker(
            nodes: List.generate(
              50,
              (index) => _milestone(id: 1000 + page * 50 + index),
            ),
            hasNext: true,
            endCursor: 'cursor-${page + 1}',
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      var page = await api.workItemMilestoneChoices(target);
      var count = page.items.length;
      while (page.continuation != null) {
        page = await api.workItemMilestoneChoices(
          target,
          continuation: page.continuation,
        );
        count += page.items.length;
      }
      expect(count, 200);
      expect(page.isTruncated, isTrue);
      expect(page.isPartial, isTrue);
      expect(adapter.requests, hasLength(5));
    },
  );

  for (final group in [false, true]) {
    test(
      '${group ? 'group' : 'project'} update sends exact widget input once and confirms readback',
      () async {
        var reads = 0;
        late WorkItemMilestoneSelection selected;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            return jsonResponse(
              _ack(
                group: group,
                milestone: _milestone(id: 6, groupOwner: group),
              ),
            );
          }
          if (_query(request).contains('WorkItemMilestones')) {
            return jsonResponse(
              _picker(
                group: group,
                nodes: [_milestone(id: 6, groupOwner: group)],
              ),
            );
          }
          reads++;
          return jsonResponse(
            reads < 3
                ? _read(group: group)
                : _read(
                    group: group,
                    updatedAt: _savedAt,
                    milestone: _milestone(id: 6, groupOwner: group),
                  ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api, group: group);
        selected = (await api.workItemMilestoneChoices(
          target,
        )).items.single.selection;
        final result = await api.updateWorkItemMilestone(
          target,
          selection: selected,
        );
        expect(result.snapshot.milestone!.id, endsWith('/6'));
        final writes = adapter.requests.where(_mutation).toList();
        expect(writes, hasLength(1));
        expect(_variables(writes.single), {
          'input': {
            'id': _summary(group: group).id,
            'milestoneWidget': {'milestoneId': 'gid://gitlab/Milestone/6'},
          },
        });
        expect(_query(writes.single), isNot(contains('updateWorkItem')));
        expect(_query(writes.single), isNot(contains('lockVersion')));
      },
    );
  }

  test(
    'clear sends inner null while current choice no-op consumes with zero writes',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(_ack(milestone: null));
        if (_query(request).contains('ProjectWorkItemMilestones')) {
          return jsonResponse(_picker(nodes: const []));
        }
        reads++;
        return jsonResponse(
          reads < 5 ? _read() : _read(updatedAt: _savedAt, milestone: null),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final noOp = await _target(api);
      await api.updateWorkItemMilestone(noOp, selection: noOp.currentSelection);
      expect(adapter.requests.where(_mutation), isEmpty);
      await expectLater(
        api.updateWorkItemMilestone(noOp, selection: noOp.currentSelection),
        throwsA(_failure(FailureKind.writeUncertain)),
      );

      final clearTarget = await _target(api);
      final clear = (await api.workItemMilestoneChoices(
        clearTarget,
      )).clearSelection;
      final result = await api.updateWorkItemMilestone(
        clearTarget,
        selection: clear,
      );
      expect(result.snapshot.milestone, isNull);
      final input = _variables(
        adapter.requests.singleWhere(_mutation),
      )['input'];
      expect(input, {
        'id': _summary().id,
        'milestoneWidget': {'milestoneId': null},
      });
    },
  );

  test(
    'changed original revision conflicts before mutation and consumes target',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((_) {
        reads++;
        return jsonResponse(_read(updatedAt: reads == 1 ? _freshAt : _savedAt));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemMilestone(target, selection: target.currentSelection),
        throwsA(_failure(FailureKind.conflict)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
      await expectLater(
        api.updateWorkItemMilestone(target, selection: target.currentSelection),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
    },
  );

  test(
    'concurrent use reserves target before asynchronous preflight',
    () async {
      final preflight = Completer<ResponseBody>();
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(_ack(milestone: null));
        reads++;
        if (reads == 1) return jsonResponse(_read());
        if (reads == 2) return preflight.future;
        return jsonResponse(_read(updatedAt: _savedAt, milestone: null));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final first = api.updateWorkItemMilestone(
        target,
        selection: target.clearSelection,
      );
      await expectLater(
        api.updateWorkItemMilestone(target, selection: target.currentSelection),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      preflight.complete(jsonResponse(_read()));
      await first;
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test(
    'foreign selection is rejected and consumes target before I/O',
    () async {
      final adapter = FakeAdapter((request) {
        if (_query(request).contains('WorkItemMilestones')) {
          return jsonResponse(_picker(nodes: [_milestone(id: 6)]));
        }
        return jsonResponse(_read());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final first = await _target(api);
      final foreign = (await api.workItemMilestoneChoices(
        first,
      )).items.single.selection;
      final second = await _target(api);
      final before = adapter.requests.length;
      await expectLater(
        api.updateWorkItemMilestone(second, selection: foreign),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests, hasLength(before));
      await expectLater(
        api.updateWorkItemMilestone(second, selection: second.currentSelection),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
    },
  );

  test(
    'wrong acknowledgement is uncertain and cannot replay the write',
    () async {
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(_ack());
        if (_query(request).contains('ProjectWorkItemMilestones')) {
          return jsonResponse(_picker(nodes: [_milestone(id: 6)]));
        }
        return jsonResponse(_read());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final selected = (await api.workItemMilestoneChoices(
        target,
      )).items.single.selection;
      await expectLater(
        api.updateWorkItemMilestone(target, selection: selected),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
      await expectLater(
        api.updateWorkItemMilestone(target, selection: selected),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test(
    'explicit mutation errors are definitive validation with no replay',
    () async {
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          return jsonResponse(_ack(errors: const ['Milestone is invalid']));
        }
        return jsonResponse(_read());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemMilestone(target, selection: target.clearSelection),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
      await expectLater(
        api.updateWorkItemMilestone(target, selection: target.clearSelection),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test(
    'unsupported schema remains explicit and never falls back to another write',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'errors': [
            {
              'message': 'Unknown field setWorkItemMetadata',
              'extensions': {'code': 'undefinedField'},
            },
          ],
        }),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemMilestone(_detail(), expectedUserId: 7),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.where(_mutation), isEmpty);
    },
  );

  test(
    'malformed picker owner, duplicate IDs and repeated cursor fail closed',
    () async {
      final malformed = [
        _picker(nodes: [_milestone(id: 6, ownerPath: 'other/project')]),
        _picker(nodes: [_milestone(id: 6), _milestone(id: 6)]),
        _picker(nodes: [_milestone(id: 6)], hasNext: true, endCursor: ''),
        _picker(
          nodes: [
            {..._milestone(id: 6), 'webPath': 'https://evil.invalid/milestone'},
          ],
        ),
      ];
      for (final response in malformed) {
        var requests = 0;
        final adapter = FakeAdapter((_) {
          requests++;
          return jsonResponse(requests == 1 ? _read() : response);
        });
        final api = testApi(adapter);
        final target = await _target(api);
        await expectLater(
          api.workItemMilestoneChoices(target),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }
    },
  );

  test(
    'account generation callback cancels before any picker or mutation write',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read()));
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.workItemMilestoneChoices(target, isCurrent: () => false),
        throwsA(_failure(FailureKind.cancelled)),
      );
      await expectLater(
        api.updateWorkItemMilestone(
          target,
          selection: target.currentSelection,
          isCurrent: () => false,
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'milestone START callback runs once before transport',
    () async {
      Future<void> changed({required bool callbackThrows}) async {
        var callbacks = 0;
        var writes = 0;
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            writes++;
            return jsonResponse(_ack(milestone: null));
          }
          reads++;
          return jsonResponse(
            _read(
              milestone: reads < 3 ? _sentinel : null,
              updatedAt: reads < 3 ? _freshAt : _savedAt,
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        final future = api.updateWorkItemMilestone(
          target,
          selection: target.clearSelection,
          isCurrent: () => true,
          onMutationSent: () {
            callbacks++;
            if (callbackThrows) throw StateError('synthetic callback failure');
          },
        );
        if (callbackThrows) {
          await expectLater(future, throwsA(_failure(FailureKind.cancelled)));
        } else {
          expect((await future).snapshot.milestone, isNull);
        }
        expect(callbacks, 1);
        expect(writes, callbackThrows ? 0 : 1);
      }

      await changed(callbackThrows: false);
      await changed(callbackThrows: true);

      var noOpCallbacks = 0;
      final noOpAdapter = FakeAdapter((request) {
        if (_mutation(request)) fail('no-op sent a mutation');
        return jsonResponse(_read());
      });
      final noOpApi = testApi(noOpAdapter);
      addTearDown(noOpApi.close);
      final noOpTarget = await _target(noOpApi);
      await noOpApi.updateWorkItemMilestone(
        noOpTarget,
        selection: noOpTarget.currentSelection,
        isCurrent: () => true,
        onMutationSent: () => noOpCallbacks++,
      );
      expect(noOpCallbacks, 0);
      expect(noOpAdapter.requests.where(_mutation), isEmpty);

      for (final cancelled in [false, true]) {
        var callbacks = 0;
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) fail('preflight failure sent a mutation');
          reads++;
          return jsonResponse(
            _read(
              actor: cancelled && reads > 1
                  ? const {'id': 'gid://gitlab/User/8'}
                  : const {'id': _actorId},
              metadataPermission: cancelled || reads == 1,
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemMilestone(
            target,
            selection: target.clearSelection,
            isCurrent: () => true,
            onMutationSent: () => callbacks++,
          ),
          throwsA(
            _failure(
              cancelled ? FailureKind.cancelled : FailureKind.forbidden,
            ),
          ),
        );
        expect(callbacks, 0);
        expect(adapter.requests.where(_mutation), isEmpty);
      }
    },
  );
}
