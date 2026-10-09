import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';
import 'package:gitlab_mobile/core/work_item_status_models.dart';

import 'support/fake_adapter.dart';

const _actorId = 'gid://gitlab/User/7';
const _typeId = 'gid://gitlab/WorkItems::Type/91';
const _oldStatusId = 'gid://gitlab/WorkItems::Statuses::SystemDefined::Status/1';
const _newStatusId = 'gid://gitlab/WorkItems::Statuses::Custom::Status/37';
const _thirdStatusId = 'gid://gitlab/WorkItems::Statuses::Custom::Status/38';
final _createdAt = DateTime.utc(2026, 10, 1);
final _openedAt = DateTime.utc(2026, 10, 4, 4);
final _savedAt = DateTime.utc(2026, 10, 4, 4, 0, 1);

WorkItemGraphSummary _summary({
  bool group = false,
  String state = 'OPEN',
  DateTime? updatedAt,
  String typeName = 'Customer-defined objective',
}) => WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/${group ? 401 : 301}',
  iid: 17,
  title: group ? 'Group item' : 'Project item',
  state: state,
  createdAt: _createdAt,
  updatedAt: updatedAt ?? _openedAt,
  project: group
      ? null
      : const GraphResourceRef(
          id: 'gid://gitlab/Project/42',
          fullPath: 'studio/mobile',
        ),
  namespace: group
      ? const GraphResourceRef(
          id: 'gid://gitlab/Group/84',
          fullPath: 'studio/group',
        )
      : const GraphResourceRef(
          id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
          fullPath: 'studio/mobile',
        ),
  type: WorkItemGraphType(id: _typeId, name: typeName),
);

WorkItemGraphDetail _detail({
  bool group = false,
  String state = 'OPEN',
  String typeName = 'Customer-defined objective',
}) => WorkItemGraphDetail(
  summary: _summary(group: group, state: state, typeName: typeName),
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'STATUS'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Map<String, Object?> _status(
  String? id, {
  Object? name = 'Ready',
  Object? iconName = 'status_ready',
  Object? color = '#123ABC',
  Object? position = 1,
  Object? description = 'Server text',
  Object? category = 'READY_FOR_ACTION',
  bool includeId = true,
}) => {
  if (includeId) 'id': id,
  'name': name,
  'iconName': iconName,
  'color': color,
  'position': position,
  'description': description,
  'category': category,
};

Map<String, Object?> _node({
  bool group = false,
  String state = 'OPEN',
  DateTime? updatedAt,
  Object? lockVersion = 8,
  Object? assignment = const _DefaultAssignment(),
  Object? allowedStatuses = const _DefaultCandidates(),
  Object? permissions = const {
    'readWorkItem': true,
    'setWorkItemMetadata': true,
  },
  Object? widgets = const _DefaultWidgets(),
  Object? definitions = const _DefaultDefinitions(),
  String typeName = 'Customer-defined objective',
  Map<String, Object?> changes = const {},
}) {
  final expected = _summary(
    group: group,
    state: state,
    updatedAt: updatedAt,
    typeName: typeName,
  );
  final resolvedAssignment = assignment is _DefaultAssignment
      ? _status(_oldStatusId)
      : assignment;
  final resolvedCandidates = allowedStatuses is _DefaultCandidates
      ? [_status(_oldStatusId), _status(_newStatusId), _status(_thirdStatusId)]
      : allowedStatuses;
  final resolvedWidgets = widgets is _DefaultWidgets
      ? [
          {'type': 'STATUS', 'status': resolvedAssignment},
        ]
      : widgets;
  final resolvedDefinitions = definitions is _DefaultDefinitions
      ? [
          {'type': 'STATUS', 'allowedStatuses': resolvedCandidates},
        ]
      : definitions;
  return {
    'id': expected.id,
    'iid': '${expected.iid}',
    'title': expected.title,
    'state': expected.state,
    'createdAt': expected.createdAt.toIso8601String(),
    'updatedAt': expected.updatedAt.toIso8601String(),
    'lockVersion': lockVersion,
    'project': expected.project == null
        ? null
        : {'id': expected.project!.id, 'fullPath': expected.project!.fullPath},
    'namespace': expected.namespace == null
        ? null
        : {
            'id': expected.namespace!.id,
            'fullPath': expected.namespace!.fullPath,
          },
    'workItemType': {
      'id': expected.type.id,
      'name': expected.type.name,
      'widgetDefinitions': resolvedDefinitions,
    },
    'userPermissions': permissions,
    'widgets': resolvedWidgets,
    ...changes,
  };
}

Map<String, Object?> _read({
  bool group = false,
  Object? actor = const {'id': _actorId},
  Object? workItem = const _DefaultNode(),
  String state = 'OPEN',
  DateTime? updatedAt,
  Object? lockVersion = 8,
  Object? assignment = const _DefaultAssignment(),
  Object? allowedStatuses = const _DefaultCandidates(),
  Object? permissions = const {
    'readWorkItem': true,
    'setWorkItemMetadata': true,
  },
  Object? widgets = const _DefaultWidgets(),
  Object? definitions = const _DefaultDefinitions(),
  String typeName = 'Customer-defined objective',
}) => {
  'data': {
    'currentUser': actor,
    'workItem': workItem is _DefaultNode
        ? _node(
            group: group,
            state: state,
            updatedAt: updatedAt,
            lockVersion: lockVersion,
            assignment: assignment,
            allowedStatuses: allowedStatuses,
            permissions: permissions,
            widgets: widgets,
            definitions: definitions,
            typeName: typeName,
          )
        : workItem,
  },
};

Map<String, Object?> _ack({
  bool group = false,
  String state = 'OPEN',
  DateTime? updatedAt,
  Object? assignment = const _DefaultAssignment(),
  List<Object?> errors = const [],
  Object? workItem = const _DefaultNode(),
  Object? topErrors,
}) {
  final resolvedAssignment = assignment is _DefaultAssignment
      ? _status(_newStatusId)
      : assignment;
  final item = _node(
    group: group,
    state: state,
    updatedAt: updatedAt ?? _savedAt,
    assignment: resolvedAssignment,
  )..remove('userPermissions');
  (item['workItemType']! as Map).remove('widgetDefinitions');
  return {
    'errors': ?topErrors,
    'data': {
      'workItemUpdate': {
        'errors': errors,
        'workItem': workItem is _DefaultNode ? item : workItem,
      },
    },
  };
}

final class _DefaultAssignment {
  const _DefaultAssignment();
}

final class _DefaultCandidates {
  const _DefaultCandidates();
}

final class _DefaultWidgets {
  const _DefaultWidgets();
}

final class _DefaultDefinitions {
  const _DefaultDefinitions();
}

final class _DefaultNode {
  const _DefaultNode();
}

Map<String, Object?> _body(RequestOptions request) =>
    (request.data as Map).cast<String, Object?>();

String _query(RequestOptions request) => _body(request)['query']! as String;

Map<String, Object?> _variables(RequestOptions request) =>
    (_body(request)['variables']! as Map).cast<String, Object?>();

bool _isMutation(RequestOptions request) =>
    _query(request).contains('mutation MobileUpdateWorkItemStatus');

Matcher _failure(
  FailureKind kind, {
  required bool mutationSent,
  required WorkItemStatusHandoff handoff,
}) => isA<WorkItemStatusWriteFailure>()
    .having((value) => value.failure.kind, 'kind', kind)
    .having((value) => value.mutationSent, 'mutationSent', mutationSent)
    .having((value) => value.handoff, 'handoff', handoff);

Future<WorkItemStatusTarget> _open(
  GitLabApi api, {
  bool group = false,
  int generation = 12,
}) async {
  final access = await api.workItemStatus(
    _detail(group: group),
    expectedUserId: 7,
    generation: generation,
    isCurrent: () => true,
  );
  return access.target!;
}

WorkItemStatusMutationSent _handoff(List<Object> tokens) => (started) {
  final token = Object();
  tokens.add(token);
  started(token);
};

void main() {
  test(
    'project and group exact identities with equal IID preserve ordered opaque candidates',
    () async {
      for (final group in [false, true]) {
        final adapter = FakeAdapter((request) {
          final query = _query(request);
          expect(query, contains('currentUser { id }'));
          expect(query, contains('lockVersion'));
          expect(query, contains('readWorkItem setWorkItemMetadata'));
          expect(query, contains('widgets(onlyTypes: [STATUS])'));
          expect(query, contains('widgetDefinitions'));
          expect(query, contains('allowedStatuses'));
          expect(query, isNot(contains('first:')));
          expect(query, isNot(contains('after:')));
          expect(query, isNot(contains('statuses(')));
          expect(_variables(request), {'id': _summary(group: group).id});
          return jsonResponse(_read(group: group));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final access = await api.workItemStatus(
          _detail(group: group),
          expectedUserId: 7,
          generation: 12,
          isCurrent: () => true,
        );
        expect(access.snapshot.iid, 17);
        expect(access.snapshot.project, group ? isNull : isNotNull);
        expect(access.snapshot.namespace, isNotNull);
        expect(access.snapshot.typeId, _typeId);
        expect(access.snapshot.accountKey, '${api.instance.key}#7');
        expect(access.snapshot.generation, 12);
        expect(access.snapshot.lockVersion, 8);
        expect(access.snapshot.allowedStatuses.map((item) => item.id), [
          _oldStatusId,
          _newStatusId,
          _thirdStatusId,
        ]);
        expect(access.snapshot.assignment.kind, WorkItemStatusAssignmentKind.identified);
        expect(access.canWrite, isTrue);
        expect(access.target, isNotNull);
      }
    },
  );

  test(
    'type names grant nothing and missing STATUS stays an editor-only unsupported result',
    () async {
      for (final typeName in ['Task', 'Incident', 'Epic']) {
        final adapter = FakeAdapter(
          (request) => jsonResponse(
            _read(
              typeName: typeName,
              widgets: const <Object?>[],
              definitions: const <Object?>[],
            ),
          ),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          api.workItemStatus(
            _detail(typeName: typeName),
            expectedUserId: 7,
            generation: 12,
            isCurrent: () => true,
          ),
          throwsA(isA<ApiFailure>().having(
            (value) => value.kind,
            'kind',
            FailureKind.unsupported,
          )),
        );
      }
    },
  );

  test(
    'explicit null is writable, unidentified assignment is neutral read-only, malformed differs',
    () async {
      final responses = <Map<String, Object?>>[
        _read(assignment: null),
        _read(assignment: _status(null, name: null, category: 'FUTURE_CATEGORY')),
        _read(assignment: {'id': _oldStatusId, 'name': 4}),
        _read(widgets: [
          {'type': 'STATUS'},
        ]),
      ];
      for (var index = 0; index < responses.length; index++) {
        final api = testApi(FakeAdapter((request) => jsonResponse(responses[index])));
        addTearDown(api.close);
        final future = api.workItemStatus(
          _detail(),
          expectedUserId: 7,
          generation: 12,
          isCurrent: () => true,
        );
        if (index == 0) {
          final access = await future;
          expect(
            access.snapshot.assignment.kind,
            WorkItemStatusAssignmentKind.unassigned,
          );
          expect(access.target, isNotNull);
        } else if (index == 1) {
          final access = await future;
          expect(
            access.snapshot.assignment.kind,
            WorkItemStatusAssignmentKind.unidentified,
          );
          expect(access.snapshot.assignment.record!.category, 'FUTURE_CATEGORY');
          expect(access.canWrite, isFalse);
          expect(access.target, isNull);
        } else {
          await expectLater(
            future,
            throwsA(isA<ApiFailure>().having(
              (value) => value.kind,
              'kind',
              FailureKind.unsupported,
            )),
          );
        }
      }
    },
  );

  test(
    'strict readWorkItem and setWorkItemMetadata booleans fail closed without substitutes',
    () async {
      for (final permissions in <Object?>[
        null,
        const <String, Object?>{},
        const {'readWorkItem': null, 'setWorkItemMetadata': true},
        const {'readWorkItem': 'true', 'setWorkItemMetadata': true},
        const {'readWorkItem': true, 'setWorkItemMetadata': 1},
        const {
          'readWorkItem': true,
          'adminWorkItem': true,
          'updateWorkItem': true,
        },
      ]) {
        final api = testApi(
          FakeAdapter((request) => jsonResponse(_read(permissions: permissions))),
        );
        addTearDown(api.close);
        await expectLater(
          api.workItemStatus(
            _detail(),
            expectedUserId: 7,
            generation: 12,
            isCurrent: () => true,
          ),
          throwsA(isA<ApiFailure>()),
        );
      }

      final deniedApi = testApi(
        FakeAdapter(
          (request) => jsonResponse(
            _read(
              permissions: const {
                'readWorkItem': true,
                'setWorkItemMetadata': false,
                'adminWorkItem': true,
                'updateWorkItem': true,
              },
            ),
          ),
        ),
      );
      addTearDown(deniedApi.close);
      final denied = await deniedApi.workItemStatus(
        _detail(),
        expectedUserId: 7,
        generation: 12,
        isCurrent: () => true,
      );
      expect(denied.canWrite, isFalse);
      expect(denied.target, isNull);

      final unreadableApi = testApi(
        FakeAdapter(
          (request) => jsonResponse(
            _read(
              permissions: const {
                'readWorkItem': false,
                'setWorkItemMetadata': true,
              },
            ),
          ),
        ),
      );
      addTearDown(unreadableApi.close);
      await expectLater(
        unreadableApi.workItemStatus(
          _detail(),
          expectedUserId: 7,
          generation: 12,
          isCurrent: () => true,
        ),
        throwsA(isA<ApiFailure>().having(
          (value) => value.kind,
          'kind',
          FailureKind.forbidden,
        )),
      );
    },
  );

  test(
    'missing duplicate null and malformed definitions never expose a partial writer',
    () async {
      final malformed = <Map<String, Object?>>[
        _read(definitions: const <Object?>[]),
        _read(definitions: [
          {'type': 'STATUS', 'allowedStatuses': <Object?>[]},
          {'type': 'STATUS', 'allowedStatuses': <Object?>[]},
        ]),
        _read(definitions: [
          {'type': 'STATUS'},
        ]),
        _read(allowedStatuses: null),
        _read(allowedStatuses: 'not-a-list'),
        _read(allowedStatuses: [
          _status(null),
        ]),
        _read(allowedStatuses: [
          _status(_newStatusId),
          _status(_newStatusId),
        ]),
        _read(allowedStatuses: [
          _status(_newStatusId, includeId: false),
        ]),
        _read(allowedStatuses: [
          _status(_newStatusId, description: 9),
        ]),
        _read(widgets: [
          {'type': 'STATUS', 'status': _status(_oldStatusId)},
          {'type': 'STATUS', 'status': _status(_oldStatusId)},
        ]),
      ];
      for (final response in malformed) {
        final adapter = FakeAdapter((request) => jsonResponse(response));
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          api.workItemStatus(
            _detail(),
            expectedUserId: 7,
            generation: 12,
            isCurrent: () => true,
          ),
          throwsA(isA<ApiFailure>().having(
            (value) => value.kind,
            'kind',
            FailureKind.unsupported,
          )),
        );
        expect(adapter.requests.where(_isMutation), isEmpty);
      }
    },
  );

  test(
    'unknown nullable display metadata stays neutral and a large allowed list has no count cap',
    () async {
      final candidates = <Map<String, Object?>>[
        for (var index = 1; index <= 5000; index++)
          _status(
            'gid://gitlab/WorkItems::Statuses::Custom::Status/$index',
            name: index.isEven ? null : 'Status $index',
            iconName: index == 2 ? 'future icon value' : null,
            color: index == 3 ? 'not-a-color' : null,
            position: index,
            description: index == 4 ? null : 'Description $index',
            category: index == 5 ? 'UNKNOWN_FUTURE_CATEGORY' : null,
          ),
      ];
      final adapter = FakeAdapter(
        (request) => jsonResponse(
          _read(
            assignment: null,
            allowedStatuses: candidates,
          ),
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final access = await api.workItemStatus(
        _detail(),
        expectedUserId: 7,
        generation: 12,
        isCurrent: () => true,
      );
      expect(access.snapshot.allowedStatuses, hasLength(5000));
      expect(access.snapshot.allowedStatuses.first.position, 1);
      expect(access.snapshot.allowedStatuses[4].category, 'UNKNOWN_FUTURE_CATEGORY');
      expect(access.snapshot.allowedStatuses.last.id, endsWith('/5000'));
      expect(access.target, isNotNull);
    },
  );

  test('empty complete allowed list has no writable candidate', () async {
    final adapter = FakeAdapter(
      (request) => jsonResponse(
        _read(assignment: null, allowedStatuses: const <Object?>[]),
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _open(api);
    await expectLater(
      api.updateWorkItemStatus(
        target,
        candidateId: _newStatusId,
        isCurrent: () => true,
        onMutationSent: _handoff(<Object>[]),
      ),
      throwsA(_failure(
        FailureKind.validation,
        mutationSent: false,
        handoff: WorkItemStatusHandoff.none,
      )),
    );
    expect(target.consumed, isTrue);
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  test('consumed no-op has zero handoff phases and zero mutation', () async {
    final tokens = <Object>[];
    final adapter = FakeAdapter((request) => jsonResponse(_read()));
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _open(api);
    final result = await api.updateWorkItemStatus(
      target,
      candidateId: _oldStatusId,
      isCurrent: () => true,
      onMutationSent: _handoff(tokens),
    );
    expect(result.status, WorkItemStatusSaveStatus.noop);
    expect(result.mutationSent, isFalse);
    expect(result.handoff, WorkItemStatusHandoff.none);
    expect(result.snapshot.assignment.id, _oldStatusId);
    expect(tokens, isEmpty);
    expect(target.consumed, isTrue);
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  test(
    'one status-only mutation replays the opaque ID and same-second ACK succeeds',
    () async {
      var writes = 0;
      final tokens = <Object>[];
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          writes++;
          final input = (_variables(request)['input']! as Map)
              .cast<String, Object?>();
          expect(input.keys.toSet(), {'id', 'statusWidget'});
          expect(input['id'], _summary().id);
          final widget = (input['statusWidget']! as Map).cast<String, Object?>();
          expect(widget, {'status': _newStatusId});
          final encoded = jsonEncode(input);
          expect(encoded, isNot(contains('"name"')));
          expect(encoded, isNot(contains('stateEvent')));
          expect(encoded, isNot(contains('updatedAt')));
          expect(encoded, isNot(contains('lockVersion')));
          return jsonResponse(
            _ack(updatedAt: _openedAt, assignment: _status(_newStatusId)),
          );
        }
        return jsonResponse(
          writes == 0
              ? _read()
              : _read(updatedAt: _openedAt, assignment: _status(_newStatusId)),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _open(api);
      final result = await api.updateWorkItemStatus(
        target,
        candidateId: _newStatusId,
        isCurrent: () => true,
        onMutationSent: _handoff(tokens),
      );
      expect(result.status, WorkItemStatusSaveStatus.success);
      expect(result.mutationSent, isTrue);
      expect(result.handoff, WorkItemStatusHandoff.started);
      expect(result.snapshot.updatedAt, _openedAt);
      expect(result.snapshot.assignment.id, _newStatusId);
      expect(result.acknowledgement!.updatedAt, _openedAt);
      expect(writes, 1);
      expect(tokens, hasLength(1));
    },
  );

  test('status settlement accepts authoritative OPEN to CLOSED and CLOSED to OPEN', () async {
    for (final transition in [
      (before: 'OPEN', after: 'CLOSED'),
      (before: 'CLOSED', after: 'OPEN'),
    ]) {
      var writes = 0;
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          writes++;
          return jsonResponse(
            _ack(
              state: transition.after,
              assignment: _status(_newStatusId),
            ),
          );
        }
        return jsonResponse(
          _read(
            state: writes == 0 ? transition.before : transition.after,
            updatedAt: writes == 0 ? _openedAt : _savedAt,
            assignment: writes == 0
                ? _status(_oldStatusId)
                : _status(_newStatusId),
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final access = await api.workItemStatus(
        _detail(state: transition.before),
        expectedUserId: 7,
        generation: 12,
        isCurrent: () => true,
      );
      final result = await api.updateWorkItemStatus(
        access.target!,
        candidateId: _newStatusId,
        isCurrent: () => true,
        onMutationSent: _handoff(<Object>[]),
      );
      expect(
        result.snapshot.state,
        transition.after == 'OPEN' ? WorkItemState.open : WorkItemState.closed,
      );
      expect(result.status, WorkItemStatusSaveStatus.success);
    }
  });

  test('only exact full old ACK and exact old independent read is notApplied', () async {
    var writes = 0;
    final adapter = FakeAdapter((request) {
      if (_isMutation(request)) {
        writes++;
        return jsonResponse(
          _ack(updatedAt: _openedAt, assignment: _status(_oldStatusId)),
        );
      }
      return jsonResponse(_read());
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _open(api);
    final result = await api.updateWorkItemStatus(
      target,
      candidateId: _newStatusId,
      isCurrent: () => true,
      onMutationSent: _handoff(<Object>[]),
    );
    expect(result.status, WorkItemStatusSaveStatus.notApplied);
    expect(result.mutationSent, isTrue);
    expect(result.handoff, WorkItemStatusHandoff.started);
    expect(result.snapshot.assignment.id, _oldStatusId);
    expect(result.snapshot.updatedAt, _openedAt);
    expect(writes, 1);
  });

  test(
    'explicit null opening saves a non-null candidate through one mutation and independent confirm',
    () async {
      var writes = 0;
      var reads = 0;
      final tokens = <Object>[];
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          writes++;
          final input = (_variables(request)['input']! as Map)
              .cast<String, Object?>();
          expect(input, {
            'id': _summary().id,
            'statusWidget': {'status': _newStatusId},
          });
          return jsonResponse(_ack(assignment: _status(_newStatusId)));
        }
        reads++;
        return jsonResponse(
          writes == 0
              ? _read(assignment: null)
              : _read(updatedAt: _savedAt, assignment: _status(_newStatusId)),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _open(api);
      expect(
        target.opening.assignment.kind,
        WorkItemStatusAssignmentKind.unassigned,
      );
      expect(target.opening.assignment.id, isNull);
      final result = await api.updateWorkItemStatus(
        target,
        candidateId: _newStatusId,
        isCurrent: () => true,
        onMutationSent: _handoff(tokens),
      );
      expect(result.status, WorkItemStatusSaveStatus.success);
      expect(result.mutationSent, isTrue);
      expect(result.handoff, WorkItemStatusHandoff.started);
      expect(
        result.acknowledgement!.assignment.kind,
        WorkItemStatusAssignmentKind.identified,
      );
      expect(result.acknowledgement!.assignment.id, _newStatusId);
      expect(
        result.snapshot.assignment.kind,
        WorkItemStatusAssignmentKind.identified,
      );
      expect(result.snapshot.assignment.id, _newStatusId);
      expect(result.snapshot.updatedAt, _savedAt);
      expect(writes, 1);
      expect(reads, 3);
      expect(tokens, hasLength(1));
      expect(target.consumed, isTrue);
    },
  );

  test(
    'explicit null opening with exact unassigned ACK and read is notApplied',
    () async {
      var writes = 0;
      final tokens = <Object>[];
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          writes++;
          return jsonResponse(_ack(updatedAt: _openedAt, assignment: null));
        }
        return jsonResponse(_read(assignment: null));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _open(api);
      final result = await api.updateWorkItemStatus(
        target,
        candidateId: _newStatusId,
        isCurrent: () => true,
        onMutationSent: _handoff(tokens),
      );
      expect(result.status, WorkItemStatusSaveStatus.notApplied);
      expect(result.mutationSent, isTrue);
      expect(result.handoff, WorkItemStatusHandoff.started);
      expect(
        result.snapshot.assignment.kind,
        WorkItemStatusAssignmentKind.unassigned,
      );
      expect(result.snapshot.updatedAt, _openedAt);
      expect(writes, 1);
      expect(tokens, hasLength(1));
    },
  );

  test(
    'exact original ACK with a non-exact independent read is uncertain without replay',
    () async {
      final reads = <String, Map<String, Object?> Function()>{
        'desired status at old revision': () =>
            _read(assignment: _status(_newStatusId)),
        'desired status at newer revision': () =>
            _read(updatedAt: _savedAt, assignment: _status(_newStatusId)),
        'newer revision': () => _read(updatedAt: _savedAt),
        'lockVersion change': () => _read(lockVersion: 9),
        'reordered members': () => _read(
          allowedStatuses: [
            _status(_oldStatusId),
            _status(_thirdStatusId),
            _status(_newStatusId),
          ],
        ),
        'changed members': () => _read(
          allowedStatuses: [
            _status(_oldStatusId),
            _status(_newStatusId),
            _status('gid://gitlab/WorkItems::Statuses::Custom::Status/39'),
          ],
        ),
      };
      for (final entry in reads.entries) {
        var writes = 0;
        var readCount = 0;
        final tokens = <Object>[];
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            writes++;
            return jsonResponse(
              _ack(updatedAt: _openedAt, assignment: _status(_oldStatusId)),
            );
          }
          readCount++;
          return jsonResponse(writes == 0 ? _read() : entry.value());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _open(api);
        await expectLater(
          api.updateWorkItemStatus(
            target,
            candidateId: _newStatusId,
            isCurrent: () => true,
            onMutationSent: _handoff(tokens),
          ),
          throwsA(
            _failure(
              FailureKind.writeUncertain,
              mutationSent: true,
              handoff: WorkItemStatusHandoff.started,
            ),
          ),
          reason: entry.key,
        );
        expect(writes, 1, reason: entry.key);
        expect(
          adapter.requests.where(_isMutation),
          hasLength(1),
          reason: entry.key,
        );
        expect(readCount, 3, reason: entry.key);
        expect(tokens, hasLength(1), reason: entry.key);
      }
    },
  );

  test(
    'inventory search name constructed and malformed candidates outside the exact list send zero',
    () async {
      for (final candidateId in [
        'gid://gitlab/WorkItems::Statuses::Custom::Status/999',
        'gid://gitlab/WorkItems::Statuses::SystemDefined::Status/2',
        'Ready',
        '',
        '$_newStatusId ',
      ]) {
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) fail('outside candidate must send zero');
          return jsonResponse(_read());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _open(api);
        final tokens = <Object>[];
        await expectLater(
          api.updateWorkItemStatus(
            target,
            candidateId: candidateId,
            isCurrent: () => true,
            onMutationSent: _handoff(tokens),
          ),
          throwsA(_failure(
            FailureKind.validation,
            mutationSent: false,
            handoff: WorkItemStatusHandoff.none,
          )),
        );
        expect(tokens, isEmpty);
        expect(target.consumed, isTrue);
        expect(adapter.requests.where(_isMutation), isEmpty);
      }
    },
  );

  test('START is reported synchronously immediately before the only send', () async {
    var writes = 0;
    final adapter = FakeAdapter((request) {
      if (_isMutation(request)) {
        writes++;
        return jsonResponse(_ack());
      }
      return jsonResponse(
        writes == 0
            ? _read()
            : _read(updatedAt: _savedAt, assignment: _status(_newStatusId)),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _open(api);
    var requestsAtStart = -1;
    final result = await api.updateWorkItemStatus(
      target,
      candidateId: _newStatusId,
      isCurrent: () => true,
      onMutationSent: (started) {
        expect(adapter.requests.where(_isMutation), isEmpty);
        requestsAtStart = adapter.requests.length;
        started(Object());
      },
    );
    expect(requestsAtStart, 2);
    expect(_isMutation(adapter.requests[requestsAtStart]), isTrue);
    expect(adapter.requests.where(_isMutation), hasLength(1));
    expect(result.status, WorkItemStatusSaveStatus.success);
    expect(result.mutationSent, isTrue);
    expect(result.handoff, WorkItemStatusHandoff.started);
  });

  test('callback exception before or after START sends zero transport and records handoff', () async {
    for (final afterStart in [false, true]) {
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) fail('transport must not be invoked');
        return jsonResponse(_read());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _open(api);
      await expectLater(
        api.updateWorkItemStatus(
          target,
          candidateId: _newStatusId,
          isCurrent: () => true,
          onMutationSent: (started) {
            if (afterStart) started(Object());
            throw StateError('terminal rejected');
          },
        ),
        throwsA(_failure(
          FailureKind.cancelled,
          mutationSent: false,
          handoff: afterStart
              ? WorkItemStatusHandoff.started
              : WorkItemStatusHandoff.none,
        )),
      );
      expect(adapter.requests.where(_isMutation), isEmpty);
      expect(target.consumed, isTrue);
    }
  });

  test('target is consumed synchronously and a second concurrent use never sends', () async {
    final preflight = Completer<void>();
    var reads = 0;
    final adapter = FakeAdapter((request) async {
      if (_isMutation(request)) {
        return jsonResponse(_ack());
      }
      reads++;
      if (reads == 2) await preflight.future;
      return jsonResponse(
        reads > 2
            ? _read(updatedAt: _savedAt, assignment: _status(_newStatusId))
            : _read(),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _open(api);
    final first = api.updateWorkItemStatus(
      target,
      candidateId: _newStatusId,
      isCurrent: () => true,
      onMutationSent: _handoff(<Object>[]),
    );
    expect(target.consumed, isTrue);
    await expectLater(
      api.updateWorkItemStatus(
        target,
        candidateId: _newStatusId,
        isCurrent: () => true,
        onMutationSent: _handoff(<Object>[]),
      ),
      throwsA(_failure(
        FailureKind.writeUncertain,
        mutationSent: false,
        handoff: WorkItemStatusHandoff.none,
      )),
    );
    preflight.complete();
    expect((await first).status, WorkItemStatusSaveStatus.success);
    expect(adapter.requests.where(_isMutation), hasLength(1));
  });

  test(
    'preflight rejects candidate list revision lock lifecycle assignment actor scope and type drift',
    () async {
      final drifts = <Map<String, Object?> Function()>[
        () => _read(allowedStatuses: [
          _status(_oldStatusId),
          _status(_thirdStatusId),
          _status(_newStatusId),
        ]),
        () => _read(updatedAt: _savedAt),
        () => _read(lockVersion: 9),
        () => _read(state: 'CLOSED'),
        () => _read(assignment: _status(_thirdStatusId)),
        () => _read(actor: const {'id': 'gid://gitlab/User/8'}),
        () {
          final node = _node();
          node['namespace'] = {
            'id': 'gid://gitlab/Namespaces::ProjectNamespace/99',
            'fullPath': 'other/project',
          };
          return _read(workItem: node);
        },
        () {
          final node = _node();
          (node['workItemType']! as Map)['id'] =
              'gid://gitlab/WorkItems::Type/99';
          return _read(workItem: node);
        },
        () => _read(allowedStatuses: [
          _status(_oldStatusId),
          _status(_thirdStatusId),
        ]),
      ];
      for (final drift in drifts) {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) fail('drift must send zero');
          reads++;
          return jsonResponse(reads == 1 ? _read() : drift());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _open(api);
        await expectLater(
          api.updateWorkItemStatus(
            target,
            candidateId: _newStatusId,
            isCurrent: () => true,
            onMutationSent: _handoff(<Object>[]),
          ),
          throwsA(isA<WorkItemStatusWriteFailure>()
              .having((value) => value.mutationSent, 'mutationSent', isFalse)
              .having(
                (value) => value.handoff,
                'handoff',
                WorkItemStatusHandoff.none,
              )),
        );
        expect(adapter.requests.where(_isMutation), isEmpty);
      }
    },
  );

  test('API owner, read epoch, closed owner and current-session drift send zero', () async {
    final owner = testApi(FakeAdapter((request) => jsonResponse(_read())));
    addTearDown(owner.close);
    final target = await _open(owner);
    final other = testApi(FakeAdapter((request) => jsonResponse(_read())));
    addTearDown(other.close);
    await expectLater(
      other.updateWorkItemStatus(
        target,
        candidateId: _newStatusId,
        isCurrent: () => true,
        onMutationSent: _handoff(<Object>[]),
      ),
      throwsA(_failure(
        FailureKind.validation,
        mutationSent: false,
        handoff: WorkItemStatusHandoff.none,
      )),
    );

    for (final invalidate in <void Function(GitLabApi)>[
      (api) => api.clearReadCache(),
      (api) => api.close(),
    ]) {
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) fail('owner drift must not write');
        return jsonResponse(_read());
      });
      final api = testApi(adapter);
      final owned = await _open(api);
      invalidate(api);
      await expectLater(
        api.updateWorkItemStatus(
          owned,
          candidateId: _newStatusId,
          isCurrent: () => true,
          onMutationSent: _handoff(<Object>[]),
        ),
        throwsA(isA<WorkItemStatusWriteFailure>()
            .having((value) => value.mutationSent, 'mutationSent', isFalse)),
      );
      expect(adapter.requests.where(_isMutation), isEmpty);
    }

    final sessionAdapter = FakeAdapter((request) {
      if (_isMutation(request)) fail('session drift must not write');
      return jsonResponse(_read());
    });
    final sessionApi = testApi(sessionAdapter);
    addTearDown(sessionApi.close);
    final sessionTarget = await _open(sessionApi);
    await expectLater(
      sessionApi.updateWorkItemStatus(
        sessionTarget,
        candidateId: _newStatusId,
        isCurrent: () => false,
        onMutationSent: _handoff(<Object>[]),
      ),
      throwsA(_failure(
        FailureKind.cancelled,
        mutationSent: false,
        handoff: WorkItemStatusHandoff.none,
      )),
    );
  });

  test(
    'transport HTTP cancellation top-level errors and malformed ACK are uncertain after one send',
    () async {
      final mutationResponses = <FutureOr<ResponseBody> Function()>[
        () => jsonResponse({'message': 'bad'}, status: 500),
        () => throw DioException(
          requestOptions: RequestOptions(path: '/api/graphql'),
          type: DioExceptionType.cancel,
        ),
        () => throw DioException(
          requestOptions: RequestOptions(path: '/api/graphql'),
          type: DioExceptionType.receiveTimeout,
        ),
        () => jsonResponse({
          'errors': [
            {'message': 'unknown'},
          ],
          'data': null,
        }),
        () => jsonResponse({
          'data': {
            'workItemUpdate': {'errors': 'bad', 'workItem': null},
          },
        }),
        () => jsonResponse({
          'data': {
            'workItemUpdate': {'errors': <Object?>[], 'workItem': null},
          },
        }),
      ];
      for (final response in mutationResponses) {
        var writes = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            writes++;
            return response();
          }
          return jsonResponse(_read());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _open(api);
        await expectLater(
          api.updateWorkItemStatus(
            target,
            candidateId: _newStatusId,
            isCurrent: () => true,
            onMutationSent: _handoff(<Object>[]),
          ),
          throwsA(_failure(
            FailureKind.writeUncertain,
            mutationSent: true,
            handoff: WorkItemStatusHandoff.started,
          )),
        );
        expect(writes, 1);
      }
    },
  );

  test('well-formed server rejection is typed validation and never confirms', () async {
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_isMutation(request)) {
        return jsonResponse(_ack(errors: const ['not allowed']));
      }
      reads++;
      return jsonResponse(_read());
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _open(api);
    await expectLater(
      api.updateWorkItemStatus(
        target,
        candidateId: _newStatusId,
        isCurrent: () => true,
        onMutationSent: _handoff(<Object>[]),
      ),
      throwsA(_failure(
        FailureKind.validation,
        mutationSent: true,
        handoff: WorkItemStatusHandoff.started,
      )),
    );
    expect(reads, 2);
  });

  test(
    'older wrong-identity wrong-status wrong-state and newer-original ACKs are uncertain',
    () async {
      final badAcks = <Map<String, Object?> Function()>[
        () => _ack(
          updatedAt: _openedAt.subtract(const Duration(seconds: 1)),
          assignment: _status(_newStatusId),
        ),
        () {
          final node = _node(updatedAt: _savedAt, assignment: _status(_newStatusId));
          node['id'] = 'gid://gitlab/WorkItem/999';
          node.remove('userPermissions');
          (node['workItemType']! as Map).remove('widgetDefinitions');
          return _ack(workItem: node);
        },
        () => _ack(assignment: _status(_thirdStatusId)),
        () => _ack(state: 'BROKEN', assignment: _status(_newStatusId)),
        () => _ack(updatedAt: _savedAt, assignment: _status(_oldStatusId)),
      ];
      for (final badAck in badAcks) {
        var writes = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            writes++;
            return jsonResponse(badAck());
          }
          return jsonResponse(_read());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _open(api);
        await expectLater(
          api.updateWorkItemStatus(
            target,
            candidateId: _newStatusId,
            isCurrent: () => true,
            onMutationSent: _handoff(<Object>[]),
          ),
          throwsA(_failure(
            FailureKind.writeUncertain,
            mutationSent: true,
            handoff: WorkItemStatusHandoff.started,
          )),
        );
        expect(writes, 1);
      }
    },
  );

  test('confirm failure mixed fields and revision or lifecycle drift are uncertain', () async {
    final confirms = <Map<String, Object?> Function()>[
      () => {
        'errors': [
          {'message': 'read failed'},
        ],
      },
      () => _read(
        updatedAt: _savedAt,
        assignment: _status(_oldStatusId),
      ),
      () => _read(
        updatedAt: _openedAt,
        assignment: _status(_newStatusId),
      ),
      () => _read(
        state: 'CLOSED',
        updatedAt: _savedAt,
        assignment: _status(_newStatusId),
      ),
      () => _read(
        updatedAt: _savedAt.add(const Duration(seconds: 1)),
        assignment: _status(_newStatusId),
      ),
    ];
    for (final confirm in confirms) {
      var writes = 0;
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          writes++;
          return jsonResponse(_ack(assignment: _status(_newStatusId)));
        }
        return jsonResponse(
          writes == 0 ? _read() : confirm(),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _open(api);
      await expectLater(
        api.updateWorkItemStatus(
          target,
          candidateId: _newStatusId,
          isCurrent: () => true,
          onMutationSent: _handoff(<Object>[]),
        ),
        throwsA(_failure(
          FailureKind.writeUncertain,
          mutationSent: true,
          handoff: WorkItemStatusHandoff.started,
        )),
      );
      expect(writes, 1);
    }
  });

  test('response budget failure cannot expose a partial target', () async {
    final oversized = utf8.encode(jsonEncode(_read()) + (' ' * (4 * 1024 * 1024)));
    final adapter = FakeAdapter(
      (request) => ResponseBody.fromBytes(
        oversized,
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.workItemStatus(
        _detail(),
        expectedUserId: 7,
        generation: 12,
        isCurrent: () => true,
      ),
      throwsA(isA<ApiFailure>().having(
        (value) => value.kind,
        'kind',
        FailureKind.tooLarge,
      )),
    );
    expect(adapter.requests.where(_isMutation), isEmpty);
  });
}
