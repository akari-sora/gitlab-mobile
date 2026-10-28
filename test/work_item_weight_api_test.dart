import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';
import 'support/strict_group_owner.dart';

const _actorId = 'gid://gitlab/User/7';
const _sentinel = Object();
final _createdAt = DateTime.utc(2026, 10, 1);
final _openedAt = DateTime.utc(2026, 10, 3, 8);
final _freshAt = DateTime.utc(2026, 10, 3, 9);
final _savedAt = DateTime.utc(2026, 10, 3, 10);

WorkItemGraphSummary _summary({
  bool group = false,
  String title = 'Displayed stale title',
  DateTime? updatedAt,
}) => WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/${group ? 41 : 31}',
  iid: group ? 41 : 31,
  title: title,
  state: 'OPEN',
  createdAt: _createdAt,
  updatedAt: updatedAt ?? _openedAt,
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

WorkItemGraphDetail _detail({bool group = false}) => WorkItemGraphDetail(
  summary: _summary(group: group),
  description: 'possibly stale',
  widgetsAvailable: true,
  widgetTypes: const {'WEIGHT'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Map<String, Object?> _widget({
  Object? weight = 3,
  Object? rolledUpWeight = 4,
  Object? rolledUpCompletedWeight = 1,
  Set<String> omit = const {},
  String type = 'WEIGHT',
}) => {
  'type': type,
  if (!omit.contains('weight')) 'weight': weight,
  if (!omit.contains('rolledUpWeight')) 'rolledUpWeight': rolledUpWeight,
  if (!omit.contains('rolledUpCompletedWeight'))
    'rolledUpCompletedWeight': rolledUpCompletedWeight,
};

Map<String, Object?> _node({
  bool group = false,
  String title = 'Fresh title',
  DateTime? updatedAt,
  Object? widgets = _sentinel,
  Object? weight = 3,
  Object? rolledUpWeight = 4,
  Object? rolledUpCompletedWeight = 1,
  Set<String> omit = const {},
  Map<String, Object?>? permissions,
  bool includePermissions = true,
  Map<String, Object?> changes = const {},
  List<String> remove = const [],
}) {
  final expected = _summary(group: group);
  final node = <String, Object?>{
    'id': expected.id,
    'iid': '${expected.iid}',
    'title': title,
    'state': 'OPEN',
    'createdAt': expected.createdAt.toIso8601String(),
    'updatedAt': (updatedAt ?? _freshAt).toIso8601String(),
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
          permissions ?? {'readWorkItem': true, 'adminWorkItem': true},
    'widgets': identical(widgets, _sentinel)
        ? [
            _widget(
              weight: weight,
              rolledUpWeight: rolledUpWeight,
              rolledUpCompletedWeight: rolledUpCompletedWeight,
              omit: omit,
            ),
          ]
        : widgets,
    ...changes,
  };
  for (final key in remove) {
    node.remove(key);
  }
  return node;
}

Map<String, Object?> _read({
  bool group = false,
  Object? actor = const {'id': _actorId},
  bool includeActor = true,
  Object? workItem = _sentinel,
  String title = 'Fresh title',
  DateTime? updatedAt,
  Object? widgets = _sentinel,
  Object? weight = 3,
  Object? rolledUpWeight = 4,
  Object? rolledUpCompletedWeight = 1,
  Set<String> omit = const {},
  Map<String, Object?>? permissions,
  bool includePermissions = true,
  Map<String, Object?> changes = const {},
  List<String> remove = const [],
}) => {
  'data': {
    if (includeActor) 'currentUser': actor,
    'workItem': identical(workItem, _sentinel)
        ? _node(
            group: group,
            title: title,
            updatedAt: updatedAt,
            widgets: widgets,
            weight: weight,
            rolledUpWeight: rolledUpWeight,
            rolledUpCompletedWeight: rolledUpCompletedWeight,
            omit: omit,
            permissions: permissions,
            includePermissions: includePermissions,
            changes: changes,
            remove: remove,
          )
        : workItem,
  },
};

Map<String, Object?> _ack({
  bool group = false,
  Object? weight = 8,
  Object? rolledUpWeight = 2,
  Object? rolledUpCompletedWeight = 1,
  DateTime? updatedAt,
  String title = 'Fresh title',
  List<Object?>? errors = const <Object?>[],
  bool includeErrors = true,
  Object? workItem = _sentinel,
  Set<String> omit = const {},
  Map<String, Object?> changes = const {},
}) => {
  'data': {
    'workItemUpdate': {
      if (includeErrors) 'errors': errors,
      'workItem': identical(workItem, _sentinel)
          ? _node(
              group: group,
              title: title,
              updatedAt: updatedAt ?? _savedAt,
              includePermissions: false,
              weight: weight,
              rolledUpWeight: rolledUpWeight,
              rolledUpCompletedWeight: rolledUpCompletedWeight,
              omit: omit,
              changes: changes,
            )
          : workItem,
    },
  },
};

String _query(RequestOptions request) =>
    (request.data as Map)['query'] as String;

Map<dynamic, dynamic> _variables(RequestOptions request) =>
    (request.data as Map)['variables'] as Map;

bool _mutation(RequestOptions request) =>
    _query(request).startsWith('mutation ');

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

void _expectReadContract(RequestOptions request) {
  expect(request.uri.path, endsWith('/api/graphql'));
  expect(request.followRedirects, isFalse);
  expect(request.maxRedirects, 0);
  final query = _query(request);
  expect(query, startsWith('query MobileWorkItemWeight'));
  expect(query, contains('userPermissions { readWorkItem adminWorkItem }'));
  expect(query, contains('onlyTypes: [WEIGHT]'));
  expect(query, isNot(contains('updateWorkItem')));
  expect(query, isNot(contains('setWorkItemMetadata')));
  expect(query, isNot(contains('MobileWorkItemWeightAttribute')));
  expect(_variables(request).keys.toList(), ['id']);
}

void _expectInput(RequestOptions request, int iid, int? weight) {
  final query = _query(request);
  expect(query, startsWith('mutation MobileSetWorkItemWeight'));
  expect('workItemUpdate'.allMatches(query).length, 1);
  expect(query, isNot(contains('userPermissions')));
  expect(query, isNot(contains('lockVersion')));
  expect(request.followRedirects, isFalse);
  expect(request.maxRedirects, 0);
  expect(_variables(request).keys.toList(), ['input']);
  final input = _variables(request)['input'] as Map;
  expect(input.keys.toList(), ['id', 'weightWidget']);
  expect(input['id'], 'gid://gitlab/WorkItem/$iid');
  final widget = input['weightWidget'] as Map;
  expect(widget.keys.toList(), ['weight']);
  expect(widget['weight'], weight);
  final encoded = jsonEncode(input);
  expect(encoded, isNot(contains('rolledUp')));
  expect(encoded, isNot(contains('lockVersion')));
  expect(encoded, isNot(contains('milestone')));
  expect(encoded, isNot(contains('description')));
  if (weight == null) expect(jsonEncode(widget), contains('"weight":null'));
}

Future<WorkItemWeightTarget> _target(
  GitLabApi api, {
  bool group = false,
  bool Function()? isCurrent,
}) async {
  final access = await api.workItemWeight(
    _detail(group: group),
    expectedUserId: 7,
    isCurrent: isCurrent,
  );
  final target = access.target;
  expect(target, isNotNull);
  return target!;
}

void main() {
  for (final problem in ['exact', 'missing', 'project', 'namespace', 'payloadErrors', 'cancelled', 'schemaErrors']) {
    for (final phase in ['opening', 'preflight', 'noop', 'ack', 'readback']) {
      if (['payloadErrors', 'cancelled', 'schemaErrors'].contains(problem) && phase != 'ack') continue;
      test('strict weight $phase $problem validates raw group owner', () async {
        var reads = 0;
        var writes = 0;
        var current = true;
        final adapter = FakeAdapter((request) {
          late Map<String, Object?> response;
          late Map<String, Object?> item;
          if (_mutation(request)) {
            writes++;
            response = _ack(group: true, weight: 8);
            item =
                ((response['data'] as Map)['workItemUpdate'] as Map)['workItem']
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
              weight: reads < 3 ? 3 : 8,
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
        final opening = api.workItemWeight(
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
        final save = api.updateWorkItemWeight(
          access.target!,
          weight: phase == 'noop' ? 3 : 8,
          isCurrent: () => current,
        );
        if (problem == 'exact') {
          expect((await save).value!.weight, phase == 'noop' ? 3 : 8);
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
      });
    }
  }

  test(
    'default weight accepts omitted project for group compatibility',
    () async {
      final item = _node(group: true)..remove('project');
      final api = testApi(
        FakeAdapter((_) => jsonResponse(_read(group: true, workItem: item))),
      );
      addTearDown(api.close);
      expect(
        (await api.workItemWeight(
          _detail(group: true),
          expectedUserId: 7,
        )).target,
        isNotNull,
      );
    },
  );

  for (final group in [false, true]) {
    for (final desired in <int?>[21, 0, 2147483647, null]) {
      final scope = group ? 'group' : 'project';
      final label = switch (desired) {
        null => 'clear',
        0 => 'zero',
        21 => 'above 20',
        _ => 'maxInt',
      };
      test('$scope $label sends one weightWidget and keeps readback '
          'aggregates', () async {
        final initial = switch (desired) {
          null => 5,
          0 => null,
          _ => 1,
        };
        final readbackRolled = desired == null ? null : 40;
        final readbackCompleted = desired == null ? 0 : 6;
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            _expectInput(request, group ? 41 : 31, desired);
            return jsonResponse(
              _ack(
                group: group,
                weight: desired,
                rolledUpWeight: 2,
                rolledUpCompletedWeight: 1,
              ),
            );
          }
          _expectReadContract(request);
          reads++;
          if (reads <= 2) {
            return jsonResponse(
              _read(
                group: group,
                weight: initial,
                rolledUpWeight: 4,
                rolledUpCompletedWeight: 1,
              ),
            );
          }
          return jsonResponse(
            _read(
              group: group,
              weight: desired,
              rolledUpWeight: readbackRolled,
              rolledUpCompletedWeight: readbackCompleted,
              updatedAt: _savedAt,
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final detail = _detail(group: group);
        final access = await api.workItemWeight(
          detail,
          expectedUserId: 7,
          isCurrent: () => true,
        );
        expect(detail.summary.updatedAt, _openedAt);
        expect(access.snapshot.summary.updatedAt, _freshAt);
        expect(access.actorId, _actorId);
        expect(access.canSetWeight, isTrue);
        expect(
          access.snapshot.availability,
          WorkItemAttributeAvailability.present,
        );
        expect(access.snapshot.value, isNotNull);
        expect(access.snapshot.value!.weight, initial);
        final saved = await api.updateWorkItemWeight(
          access.target!,
          weight: desired,
          isCurrent: () => true,
        );
        expect(saved.availability, WorkItemAttributeAvailability.present);
        expect(saved.value, isNotNull);
        expect(saved.value!.weight, desired);
        expect(saved.value!.rolledUpWeight, readbackRolled);
        expect(saved.value!.rolledUpCompletedWeight, readbackCompleted);
        expect(saved.summary.updatedAt, _savedAt);
        expect(saved.summary.id, detail.summary.id);
        expect(saved.summary.iid, detail.summary.iid);
        expect(saved.summary.project?.id, detail.summary.project?.id);
        expect(saved.summary.namespace?.id, detail.summary.namespace?.id);
        expect(reads, 3);
        expect(adapter.requests.where(_mutation), hasLength(1));
      });
    }
  }

  test(
    'unchanged zero still checks the fresh read and sends nothing',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) fail('zero writes');
        reads++;
        return jsonResponse(
          _read(
            weight: 0,
            rolledUpWeight: reads == 1 ? 1 : 9,
            rolledUpCompletedWeight: reads == 1 ? 0 : 4,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final saved = await api.updateWorkItemWeight(
        target,
        weight: 0,
        isCurrent: () => true,
      );
      expect(saved.value!.weight, 0);
      expect(saved.value!.rolledUpWeight, 9);
      expect(saved.value!.rolledUpCompletedWeight, 4);
      expect(adapter.requests.where(_mutation), isEmpty);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 0, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(reads, 2);
    },
  );

  test('unchanged null clear sends nothing and keeps fresh totals', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) fail('zero writes');
      reads++;
      return jsonResponse(
        _read(weight: null, rolledUpWeight: reads == 1 ? null : 6),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    final saved = await api.updateWorkItemWeight(
      target,
      weight: null,
      isCurrent: () => true,
    );
    expect(saved.value, isNotNull);
    expect(saved.value!.weight, isNull);
    expect(saved.value!.rolledUpWeight, 6);
    expect(adapter.requests.where(_mutation), isEmpty);
  });

  test('rolled totals alone do not conflict or get written', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) {
        _expectInput(request, 31, 8);
        return jsonResponse(
          _ack(weight: 8, rolledUpWeight: 2, rolledUpCompletedWeight: 1),
        );
      }
      reads++;
      return jsonResponse(
        _read(
          weight: reads < 3 ? 3 : 8,
          rolledUpWeight: reads == 1 ? 4 : 15,
          rolledUpCompletedWeight: reads == 1 ? 1 : 7,
          updatedAt: reads < 3 ? _freshAt : _savedAt,
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final saved = await api.updateWorkItemWeight(
      await _target(api),
      weight: 8,
      isCurrent: () => true,
    );
    expect(saved.value!.weight, 8);
    expect(saved.value!.rolledUpWeight, 15);
    expect(saved.value!.rolledUpCompletedWeight, 7);
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  test('a title change with the same revision is not a conflict', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) return jsonResponse(_ack(weight: 8));
      reads++;
      return jsonResponse(
        _read(
          title: reads == 1 ? 'Fresh title' : 'Renamed',
          weight: reads < 3 ? 3 : 8,
          updatedAt: reads < 3 ? _freshAt : _savedAt,
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final saved = await api.updateWorkItemWeight(
      await _target(api),
      weight: 8,
      isCurrent: () => true,
    );
    expect(saved.summary.title, 'Renamed');
    expect(saved.value!.weight, 8);
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  test('matching only the fresh own value still conflicts', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) fail('mutation');
      reads++;
      return jsonResponse(_read(weight: reads == 1 ? 3 : 4));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 4, isCurrent: () => true),
      throwsA(_failure(FailureKind.conflict)),
    );
    expect(adapter.requests.where(_mutation), isEmpty);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 4, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
  });

  test('admin remains sufficient when update and metadata are false', () async {
    const permissions = {
      'readWorkItem': true,
      'adminWorkItem': true,
      'updateWorkItem': false,
      'setWorkItemMetadata': false,
    };
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) {
        _expectInput(request, 31, 8);
        return jsonResponse(_ack(weight: 8));
      }
      reads++;
      return jsonResponse(
        _read(
          permissions: permissions,
          weight: reads < 3 ? 3 : 8,
          updatedAt: reads < 3 ? _freshAt : _savedAt,
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final access = await api.workItemWeight(_detail(), expectedUserId: 7);
    expect(access.canSetWeight, isTrue);
    final saved = await api.updateWorkItemWeight(
      access.target!,
      weight: 8,
      isCurrent: () => true,
    );
    expect(saved.value!.weight, 8);
  });

  test(
    'admin false is read-only even when update and metadata are true',
    () async {
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _read(
              permissions: const {
                'readWorkItem': true,
                'adminWorkItem': false,
                'updateWorkItem': true,
                'setWorkItemMetadata': true,
              },
            ),
          ),
        ),
      );
      addTearDown(api.close);
      final access = await api.workItemWeight(_detail(), expectedUserId: 7);
      expect(access.canSetWeight, isFalse);
      expect(access.target, isNull);
      expect(access.snapshot.value!.weight, 3);
    },
  );

  test('read false is forbidden even when admin is true', () async {
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse(
          _read(
            permissions: const {
              'readWorkItem': false,
              'adminWorkItem': true,
              'updateWorkItem': true,
              'setWorkItemMetadata': true,
            },
          ),
        ),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.workItemWeight(_detail(), expectedUserId: 7),
      throwsA(_failure(FailureKind.forbidden)),
    );
  });

  test('present null own weight is unset and can be set', () async {
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse(
          _read(
            weight: null,
            rolledUpWeight: null,
            rolledUpCompletedWeight: null,
          ),
        ),
      ),
    );
    addTearDown(api.close);
    final access = await api.workItemWeight(_detail(), expectedUserId: 7);
    expect(access.snapshot.availability, WorkItemAttributeAvailability.present);
    expect(access.snapshot.value, isNotNull);
    expect(access.snapshot.value!.weight, isNull);
    expect(access.snapshot.value!.rolledUpWeight, isNull);
    expect(access.snapshot.value!.rolledUpCompletedWeight, isNull);
    expect(access.canSetWeight, isTrue);
    expect(access.target, isNotNull);
  });

  test('an absent weight field is malformed', () async {
    final api = testApi(
      FakeAdapter((_) => jsonResponse(_read(omit: const {'weight'}))),
    );
    addTearDown(api.close);
    await expectLater(
      api.workItemWeight(_detail(), expectedUserId: 7),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test('an absent rolled-up field is malformed', () async {
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse(_read(omit: const {'rolledUpCompletedWeight'})),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.workItemWeight(_detail(), expectedUserId: 7),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test('an absent widget gives no target', () async {
    final api = testApi(
      FakeAdapter((_) => jsonResponse(_read(widgets: const []))),
    );
    addTearDown(api.close);
    final access = await api.workItemWeight(_detail(), expectedUserId: 7);
    expect(access.snapshot.availability, WorkItemAttributeAvailability.absent);
    expect(access.snapshot.value, isNull);
    expect(access.canSetWeight, isFalse);
    expect(access.target, isNull);
  });

  test('null or omitted widgets are unavailable and give no target', () async {
    for (final body in [
      _read(widgets: null),
      _read(remove: const ['widgets']),
    ]) {
      final api = testApi(FakeAdapter((_) => jsonResponse(body)));
      addTearDown(api.close);
      final access = await api.workItemWeight(_detail(), expectedUserId: 7);
      expect(
        access.snapshot.availability,
        WorkItemAttributeAvailability.widgetsUnavailable,
      );
      expect(access.snapshot.value, isNull);
      expect(access.target, isNull);
    }
  });

  for (final raw in <Object>[2147483648, -1, 1.5, true, '5']) {
    test('rejects out-of-Int32 server own weight $raw', () async {
      final api = testApi(FakeAdapter((_) => jsonResponse(_read(weight: raw))));
      addTearDown(api.close);
      await expectLater(
        api.workItemWeight(_detail(), expectedUserId: 7),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
    });
  }

  test('rejects an out-of-Int32 rolled-up total', () async {
    final api = testApi(
      FakeAdapter((_) => jsonResponse(_read(rolledUpWeight: 2147483648))),
    );
    addTearDown(api.close);
    await expectLater(
      api.workItemWeight(_detail(), expectedUserId: 7),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test('max Int32 own weight is a stored value', () async {
    final api = testApi(
      FakeAdapter((_) => jsonResponse(_read(weight: 2147483647))),
    );
    addTearDown(api.close);
    final access = await api.workItemWeight(_detail(), expectedUserId: 7);
    expect(access.snapshot.value!.weight, 2147483647);
    expect(access.canSetWeight, isTrue);
  });

  test('duplicate or unexpected widgets are malformed', () async {
    for (final widgets in [
      [_widget(), _widget()],
      [_widget(type: 'DESCRIPTION')],
    ]) {
      final api = testApi(
        FakeAdapter((_) => jsonResponse(_read(widgets: widgets))),
      );
      addTearDown(api.close);
      await expectLater(
        api.workItemWeight(_detail(), expectedUserId: 7),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
    }
  });

  for (final entry in <String, Map<String, Object?>>{
    'ID': {'id': 'gid://gitlab/WorkItem/99'},
    'IID': {'iid': '99'},
    'type': {
      'workItemType': {'id': 'gid://gitlab/WorkItems::Type/8', 'name': 'Issue'},
    },
    'project': {
      'project': {'id': 'gid://gitlab/Project/99', 'fullPath': 'other/project'},
    },
    'group': {
      'project': null,
      'namespace': {'id': 'gid://gitlab/Group/99', 'fullPath': 'other'},
    },
  }.entries) {
    test('read rejects wrong ${entry.key}', () async {
      final api = testApi(
        FakeAdapter((_) => jsonResponse(_read(changes: entry.value))),
      );
      addTearDown(api.close);
      await expectLater(
        api.workItemWeight(_detail(), expectedUserId: 7),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
    });

    test('preflight rejects wrong ${entry.key} without a mutation', () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) fail('mutation');
        reads++;
        return jsonResponse(reads == 1 ? _read() : _read(changes: entry.value));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
    });
  }

  test(
    'preflight rejects a wrong group namespace without a mutation',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) fail('mutation');
        reads++;
        return jsonResponse(
          reads == 1
              ? _read(group: true)
              : _read(
                  group: true,
                  changes: const {
                    'namespace': {
                      'id': 'gid://gitlab/Group/99',
                      'fullPath': 'other',
                    },
                  },
                ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api, group: true);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    },
  );

  test('a changed revision conflicts and is not replayed', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) fail('mutation');
      reads++;
      return jsonResponse(_read(updatedAt: reads == 1 ? _freshAt : _savedAt));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.conflict)),
    );
    expect(adapter.requests.where(_mutation), isEmpty);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
  });

  test(
    'a changed own value conflicts even when the desired weight matches it',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) fail('mutation');
        reads++;
        return jsonResponse(_read(weight: reads == 1 ? 3 : 8));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.conflict)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    },
  );

  test('an unchanged weight still rejects a changed actor', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) fail('mutation');
      reads++;
      return jsonResponse(
        _read(actor: {'id': reads == 1 ? _actorId : 'gid://gitlab/User/8'}),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 3, isCurrent: () => true),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests.where(_mutation), isEmpty);
  });

  test('an unchanged weight still rejects lost admin permission', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) fail('mutation');
      reads++;
      return jsonResponse(
        _read(
          permissions: {
            'readWorkItem': true,
            'adminWorkItem': reads == 1,
            'updateWorkItem': true,
            'setWorkItemMetadata': true,
          },
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 3, isCurrent: () => true),
      throwsA(_failure(FailureKind.forbidden)),
    );
    expect(adapter.requests.where(_mutation), isEmpty);
  });

  test('wrong actor, missing actor, and invisible item are distinct', () async {
    final cases = <Object?, FailureKind>{
      const {'id': 'gid://gitlab/User/8'}: FailureKind.cancelled,
      null: FailureKind.unauthenticated,
      _sentinel: FailureKind.invalidResponse,
    };
    for (final entry in cases.entries) {
      final missing = identical(entry.key, _sentinel);
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _read(includeActor: !missing, actor: missing ? null : entry.key),
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.workItemWeight(_detail(), expectedUserId: 7),
        throwsA(_failure(entry.value)),
      );
    }
    final invisible = testApi(
      FakeAdapter((_) => jsonResponse(_read(workItem: null))),
    );
    addTearDown(invisible.close);
    await expectLater(
      invisible.workItemWeight(_detail(), expectedUserId: 7),
      throwsA(_failure(FailureKind.invisible)),
    );
  });

  test('strict permission booleans reject null and non-bool values', () async {
    for (final permissions in <Map<String, Object?>?>[
      null,
      {'adminWorkItem': true},
      {'readWorkItem': true},
      {'readWorkItem': null, 'adminWorkItem': true},
      {'readWorkItem': 'true', 'adminWorkItem': true},
      {'readWorkItem': true, 'adminWorkItem': 1},
    ]) {
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            permissions == null
                ? _read(changes: const {'userPermissions': null})
                : _read(permissions: permissions),
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.workItemWeight(_detail(), expectedUserId: 7),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
    }
  });

  test(
    'old weight schema fails explicitly and stays off the basic read',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'errors': [
            {
              'message': 'Field adminWorkItem does not exist',
              'extensions': {'code': 'undefinedField'},
            },
          ],
        }),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemWeight(_detail(), expectedUserId: 7),
        throwsA(
          isA<ApiFailure>()
              .having((error) => error.kind, 'kind', FailureKind.unsupported)
              .having((error) => error.detail, 'detail', contains('仍可查看')),
        ),
      );
      expect(adapter.requests, hasLength(1));
      _expectReadContract(adapter.requests.single);
    },
  );

  for (final weight in [-1, 2147483648]) {
    test(
      'rejects input $weight before transport and keeps the target',
      () async {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            _expectInput(request, 31, 3);
            return jsonResponse(
              _ack(weight: 3, rolledUpWeight: 11, rolledUpCompletedWeight: 2),
            );
          }
          reads++;
          if (reads <= 2) return jsonResponse(_read(weight: 1));
          return jsonResponse(
            _read(
              weight: 3,
              rolledUpWeight: 11,
              rolledUpCompletedWeight: 2,
              updatedAt: _savedAt,
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemWeight(
            target,
            weight: weight,
            isCurrent: () => true,
          ),
          throwsA(_failure(FailureKind.validation)),
        );
        expect(adapter.requests, hasLength(1));
        final saved = await api.updateWorkItemWeight(
          target,
          weight: 3,
          isCurrent: () => true,
        );
        expect(saved.value!.weight, 3);
        expect(saved.value!.rolledUpWeight, 11);
        expect(adapter.requests.where(_mutation), hasLength(1));
      },
    );
  }

  test('target is owner-bound and a closed owner does not preflight', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) {
        _expectInput(request, 31, 3);
        return jsonResponse(_ack(weight: 3));
      }
      reads++;
      if (reads <= 2) return jsonResponse(_read(weight: 1));
      return jsonResponse(_read(weight: 3, updatedAt: _savedAt));
    });
    final api = testApi(adapter);
    final target = await _target(api);
    final other = testApi(FakeAdapter((_) => fail('other api')));
    addTearDown(other.close);
    await expectLater(
      other.updateWorkItemWeight(target, weight: 3, isCurrent: () => true),
      throwsA(_failure(FailureKind.validation)),
    );
    final saved = await api.updateWorkItemWeight(
      target,
      weight: 3,
      isCurrent: () => true,
    );
    expect(saved.value!.weight, 3);
    api.close();
    await expectLater(
      api.updateWorkItemWeight(target, weight: 9, isCurrent: () => true),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  test(
    'concurrent use reserves the target before asynchronous preflight',
    () async {
      final preflight = Completer<ResponseBody>();
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(_ack(weight: 8));
        if (++reads == 1) return jsonResponse(_read());
        if (reads == 2) return preflight.future;
        return jsonResponse(_read(weight: 8, updatedAt: _savedAt));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final first = api.updateWorkItemWeight(
        target,
        weight: 8,
        isCurrent: () => true,
      );
      await expectLater(
        api.updateWorkItemWeight(target, weight: 9, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      preflight.complete(jsonResponse(_read()));
      await first;
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test('stale generation during preflight prevents the mutation', () async {
    var current = true;
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) fail('mutation');
      if (++reads == 2) current = false;
      return jsonResponse(_read());
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api, isCurrent: () => current);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => current),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests.where(_mutation), isEmpty);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
  });

  test('stale read epoch before send is cancelled and not replayed', () async {
    late GitLabApi api;
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) fail('mutation');
      if (++reads == 2) api.clearReadCache();
      return jsonResponse(_read());
    });
    api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests.where(_mutation), isEmpty);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
  });

  test('GraphQL payload rejection is validation and is not replayed', () async {
    final adapter = FakeAdapter((request) {
      if (!_mutation(request)) return jsonResponse(_read());
      return jsonResponse(_ack(errors: const ['weight is invalid']));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  test(
    'mutation schema rejection stays unsupported and is not replayed',
    () async {
      final adapter = FakeAdapter((request) {
        if (!_mutation(request)) return jsonResponse(_read());
        return jsonResponse({
          'errors': [
            {
              'message': 'Unknown input field weightWidget',
              'extensions': {'code': 'argumentLiteralsIncompatible'},
            },
          ],
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.unsupported)),
      );
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test('non-schema GraphQL errors after send are uncertain', () async {
    final adapter = FakeAdapter((request) {
      if (!_mutation(request)) return jsonResponse(_read());
      return jsonResponse({
        'errors': [
          {
            'message': 'boom',
            'extensions': {'code': 'INTERNAL'},
          },
        ],
      });
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  for (final entry in <String, Map<String, Object?>>{
    'missing errors': _ack(includeErrors: false),
    'non-string errors': _ack(errors: const [1]),
    'lost work item': _ack(workItem: null),
    'wrong own weight': _ack(weight: 1),
    'missing weight field': _ack(omit: const {'weight'}),
    'wrong IID': _ack(changes: const {'iid': '99'}),
  }.entries) {
    test('${entry.key} acknowledgement is uncertain', () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(entry.value);
        reads++;
        return jsonResponse(_read());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(reads, 2);
      expect(adapter.requests.where(_mutation), hasLength(1));
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    });
  }

  test(
    'a mismatched readback is uncertain and its aggregate is not invented',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          return jsonResponse(
            _ack(weight: 8, rolledUpWeight: 2, rolledUpCompletedWeight: 1),
          );
        }
        reads++;
        return jsonResponse(
          reads < 3
              ? _read()
              : _read(weight: 7, rolledUpWeight: 99, updatedAt: _savedAt),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(reads, 3);
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  for (final status in <int>[400, 422]) {
    test(
      'HTTP $status after the mutation is uncertain and is not replayed',
      () async {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            return jsonResponse(
              _ack(errors: const ['weight is invalid']),
              status: status,
            );
          }
          reads++;
          return jsonResponse(_read());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        expect(reads, 1);
        await expectLater(
          api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(reads, 2);
        expect(adapter.requests.where(_mutation), hasLength(1));
        final afterSend = adapter.requests.length;
        await expectLater(
          api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(reads, 2);
        expect(adapter.requests.length, afterSend);
        expect(adapter.requests.where(_mutation), hasLength(1));
      },
    );
  }

  test('network failure and HTTP 500 after send are uncertain', () async {
    for (final failMutation in [true, false]) {
      final adapter = FakeAdapter((request) {
        if (!_mutation(request)) return jsonResponse(_read());
        if (failMutation) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return jsonResponse(const {}, status: 500);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
      await expectLater(
        api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    }
  });

  test('malformed mutation JSON is uncertain and is not replayed', () async {
    final adapter = FakeAdapter((request) {
      if (!_mutation(request)) return jsonResponse(_read());
      return ResponseBody.fromString('not-json', 200);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  test('account generation change after send is uncertain', () async {
    var current = true;
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) {
        current = false;
        return jsonResponse(_ack(weight: 8));
      }
      reads++;
      return jsonResponse(_read());
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api, isCurrent: () => current);
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => current),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(reads, 2);
    expect(adapter.requests.where(_mutation), hasLength(1));
    await expectLater(
      api.updateWorkItemWeight(target, weight: 8, isCurrent: () => true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  test('weight START callback runs once before transport', () async {
    Future<void> changed({required bool callbackThrows}) async {
      var callbacks = 0;
      var writes = 0;
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          writes++;
          return jsonResponse(_ack(weight: 8));
        }
        reads++;
        return jsonResponse(
          _read(
            weight: reads < 3 ? 3 : 8,
            updatedAt: reads < 3 ? _freshAt : _savedAt,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final future = api.updateWorkItemWeight(
        await _target(api),
        weight: 8,
        isCurrent: () => true,
        onMutationSent: () {
          callbacks++;
          if (callbackThrows) throw StateError('synthetic callback failure');
        },
      );
      if (callbackThrows) {
        await expectLater(future, throwsA(_failure(FailureKind.cancelled)));
      } else {
        expect((await future).value!.weight, 8);
      }
      expect(callbacks, 1);
      expect(writes, callbackThrows ? 0 : 1);
    }

    await changed(callbackThrows: false);
    await changed(callbackThrows: true);

    var noOpCallbacks = 0;
    final noOpAdapter = FakeAdapter((request) {
      if (_mutation(request)) fail('no-op sent a mutation');
      return jsonResponse(_read(weight: 3));
    });
    final noOpApi = testApi(noOpAdapter);
    addTearDown(noOpApi.close);
    await noOpApi.updateWorkItemWeight(
      await _target(noOpApi),
      weight: 3,
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
            permissions: {
              'readWorkItem': true,
              'adminWorkItem': cancelled || reads == 1,
            },
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.updateWorkItemWeight(
          await _target(api),
          weight: 8,
          isCurrent: () => true,
          onMutationSent: () => callbacks++,
        ),
        throwsA(
          _failure(cancelled ? FailureKind.cancelled : FailureKind.forbidden),
        ),
      );
      expect(callbacks, 0);
      expect(adapter.requests.where(_mutation), isEmpty);
    }
  });
}
