import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';

import 'support/fake_adapter.dart';
import 'support/strict_group_owner.dart';

const _actorId = 'gid://gitlab/User/7';
const _generation = 12;
const _absent = Object();
final _createdAt = DateTime.utc(2026, 10, 1);
final _revision = DateTime.utc(2026, 10, 3, 9);
final _newerRevision = DateTime.utc(2026, 10, 3, 10);
final _olderRevision = DateTime.utc(2026, 10, 3, 8);

WorkItemGraphSummary _summary({
  bool group = false,
  String state = 'OPEN',
  String typeName = 'Renamed objective',
  DateTime? updatedAt,
}) => WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/${group ? 41 : 31}',
  iid: group ? 41 : 31,
  title: 'Fresh title',
  state: state,
  createdAt: _createdAt,
  updatedAt: updatedAt ?? _revision,
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
  type: WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/${group ? 10 : 9}',
    name: typeName,
  ),
);

WorkItemGraphDetail _detail({
  bool group = false,
  String state = 'OPEN',
  Set<String> widgetTypes = const {'HEALTH_STATUS'},
}) => WorkItemGraphDetail(
  summary: _summary(group: group, state: state),
  description: null,
  widgetsAvailable: true,
  widgetTypes: widgetTypes,
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Map<String, Object?> _healthWidget({
  Object? value,
  bool includeValue = true,
  String type = 'HEALTH_STATUS',
  Object? rollup = const <Object?>[],
}) => {
  'type': type,
  if (includeValue) 'healthStatus': value,
  'rolledUpHealthStatus': rollup,
};

Map<String, Object?> _node({
  bool group = false,
  String state = 'OPEN',
  String typeName = 'Renamed objective',
  DateTime? updatedAt,
  Object? widgets = _absent,
  Object? value,
  bool includeValue = true,
  Map<String, Object?>? permissions,
  bool includePermissions = true,
  Map<String, Object?> changes = const {},
}) {
  final summary = _summary(
    group: group,
    state: state,
    typeName: typeName,
    updatedAt: updatedAt,
  );
  return {
    'id': summary.id,
    'iid': '${summary.iid}',
    'title': summary.title,
    'state': summary.state,
    'createdAt': summary.createdAt.toIso8601String(),
    'updatedAt': summary.updatedAt.toIso8601String(),
    'project': summary.project == null
        ? null
        : {'id': summary.project!.id, 'fullPath': summary.project!.fullPath},
    'namespace': summary.namespace == null
        ? null
        : {
            'id': summary.namespace!.id,
            'fullPath': summary.namespace!.fullPath,
          },
    'workItemType': {'id': summary.type.id, 'name': summary.type.name},
    if (includePermissions)
      'userPermissions':
          permissions ?? {'readWorkItem': true, 'adminWorkItem': true},
    'widgets': identical(widgets, _absent)
        ? [_healthWidget(value: value, includeValue: includeValue)]
        : widgets,
    ...changes,
  };
}

Map<String, Object?> _read({
  bool group = false,
  String state = 'OPEN',
  String typeName = 'Renamed objective',
  DateTime? updatedAt,
  Object? actor = const {'id': _actorId},
  bool includeActor = true,
  Object? workItem = _absent,
  Object? widgets = _absent,
  Object? value,
  bool includeValue = true,
  Map<String, Object?>? permissions,
  bool includePermissions = true,
  Map<String, Object?> changes = const {},
}) => {
  'data': {
    if (includeActor) 'currentUser': actor,
    'workItem': identical(workItem, _absent)
        ? _node(
            group: group,
            state: state,
            typeName: typeName,
            updatedAt: updatedAt,
            widgets: widgets,
            value: value,
            includeValue: includeValue,
            permissions: permissions,
            includePermissions: includePermissions,
            changes: changes,
          )
        : workItem,
  },
};

Map<String, Object?> _ack({
  bool group = false,
  String state = 'OPEN',
  String typeName = 'Renamed objective',
  DateTime? updatedAt,
  Object? value,
  bool includeValue = true,
  Object? widgets = _absent,
  Object? workItem = _absent,
  Object? errors = const <Object?>[],
  bool includeErrors = true,
  Map<String, Object?> changes = const {},
}) => {
  'data': {
    'workItemUpdate': {
      if (includeErrors) 'errors': errors,
      'workItem': identical(workItem, _absent)
          ? _node(
              group: group,
              state: state,
              typeName: typeName,
              updatedAt: updatedAt,
              widgets: widgets,
              value: value,
              includeValue: includeValue,
              includePermissions: false,
              changes: changes,
            )
          : workItem,
    },
  },
};

Map<String, Object?> _body(RequestOptions request) =>
    (request.data as Map).cast<String, Object?>();

String _query(RequestOptions request) => _body(request)['query']! as String;

Map<String, Object?> _variables(RequestOptions request) =>
    (_body(request)['variables']! as Map).cast<String, Object?>();

bool _isMutation(RequestOptions request) =>
    _query(request).startsWith('mutation ');

final class _OrderedTransport {
  _OrderedTransport(List<FutureOr<ResponseBody> Function(RequestOptions)> steps)
    : _steps = [...steps] {
    adapter = FakeAdapter((request) {
      if (_steps.isEmpty) {
        fail('unexpected request: ${_query(request)}');
      }
      if (_isMutation(request)) _mutationNonce++;
      return _steps.removeAt(0)(request);
    });
  }

  final List<FutureOr<ResponseBody> Function(RequestOptions)> _steps;
  late final FakeAdapter adapter;
  var _mutationNonce = 0;

  int get sends => _mutationNonce;

  void verifyConsumed() {
    expect(_steps, isEmpty, reason: 'all synthetic responses must be consumed');
    expect(_mutationNonce, lessThanOrEqualTo(1), reason: 'no mutation replay');
  }
}

final class _StatefulHealthTransport {
  _StatefulHealthTransport({
    WorkItemHealthEditValue? initial = WorkItemHealthEditValue.needsAttention,
  }) : _value = initial {
    adapter = FakeAdapter(_respond);
  }

  late final FakeAdapter adapter;
  WorkItemHealthEditValue? _value;
  var _requestNonce = 0;
  var _mutationNonce = 0;
  var _stateRevision = 0;
  final List<String> operations = [];
  final List<int> readRequestNonces = [];
  final List<int> mutationRequestNonces = [];
  final List<int> mutationNonces = [];
  final List<WorkItemHealthEditValue?> readValues = [];
  final List<WorkItemHealthEditValue?> appliedValues = [];
  final List<Object?> mutationGraphValues = [];

  WorkItemHealthEditValue? get value => _value;
  int get requests => _requestNonce;
  int get reads => readRequestNonces.length;
  int get mutations => mutationNonces.length;
  int get stateChanges => _stateRevision;

  ResponseBody _respond(RequestOptions request) {
    final requestNonce = ++_requestNonce;
    expect(request.uri.path, '/gitlab/api/graphql');
    expect(request.headers['Authorization'], 'Bearer synthetic-test-token');
    expect(request.followRedirects, isFalse);
    expect(request.maxRedirects, 0);
    final query = _query(request);
    if (query.startsWith('query MobileWorkItemHealthEdit')) {
      operations.add('read');
      readRequestNonces.add(requestNonce);
      readValues.add(_value);
      _expectReadContract(request);
      expect(_variables(request), {'id': _summary().id});
      return jsonResponse(
        _read(value: _value?.graphValue, updatedAt: _revision),
      );
    }
    if (query.startsWith('mutation MobileSetWorkItemHealthStatus')) {
      operations.add('mutation');
      mutationRequestNonces.add(requestNonce);
      final input = (_variables(request)['input']! as Map)
          .cast<String, Object?>();
      final widget = (input['healthStatusWidget']! as Map)
          .cast<String, Object?>();
      final rawDesired = widget['healthStatus'];
      final desired = WorkItemHealthEditValue.parse(rawDesired);
      _expectMutationInput(request, _summary().id, desired?.graphValue);
      expect(desired, isNot(_value), reason: 'each mutation changes state');
      mutationGraphValues.add(rawDesired);
      _value = desired;
      _stateRevision++;
      appliedValues.add(_value);
      mutationNonces.add(++_mutationNonce);
      return jsonResponse(
        _ack(value: _value?.graphValue, updatedAt: _revision),
      );
    }
    fail('unknown Health GraphQL route: $query');
  }
}

FutureOr<ResponseBody> Function(RequestOptions) _jsonStep(
  Object? body, {
  bool? mutation,
  int status = 200,
  void Function(RequestOptions)? inspect,
}) => (request) {
  if (mutation != null) expect(_isMutation(request), mutation);
  inspect?.call(request);
  return jsonResponse(body, status: status);
};

void _expectReadContract(RequestOptions request) {
  expect(request.uri.path, endsWith('/api/graphql'));
  expect(request.followRedirects, isFalse);
  expect(request.maxRedirects, 0);
  final query = _query(request);
  expect(query, startsWith('query MobileWorkItemHealthEdit'));
  expect(query, contains('currentUser { id }'));
  expect(query, contains('userPermissions { readWorkItem adminWorkItem }'));
  expect(query, contains('widgets(onlyTypes: [HEALTH_STATUS])'));
  expect(query, contains('rolledUpHealthStatus'));
  expect(query, isNot(contains('COLOR')));
  expect(_variables(request).keys.toList(), ['id']);
}

void _expectMutationInput(RequestOptions request, String id, String? desired) {
  final query = _query(request);
  expect(query, startsWith('mutation MobileSetWorkItemHealthStatus'));
  expect('workItemUpdate'.allMatches(query).length, 1);
  expect(query, isNot(contains('currentUser')));
  expect(query, isNot(contains('userPermissions')));
  expect(query, isNot(contains('project { id fullPath }')));
  expect(query, isNot(contains('namespace { id fullPath }')));
  expect(request.followRedirects, isFalse);
  expect(request.maxRedirects, 0);
  expect(_variables(request).keys.toList(), ['input']);
  final input = (_variables(request)['input']! as Map).cast<String, Object?>();
  expect(input.keys.toList(), ['id', 'healthStatusWidget']);
  expect(input['id'], id);
  final widget = (input['healthStatusWidget']! as Map).cast<String, Object?>();
  expect(widget.keys.toList(), ['healthStatus']);
  expect(widget['healthStatus'], desired);
  final encoded = jsonEncode(input);
  expect(encoded, isNot(contains('lockVersion')));
  expect(encoded, isNot(contains('COLOR')));
  expect(encoded, isNot(contains('rolledUp')));
  if (desired == null) {
    expect(jsonEncode(widget), contains('"healthStatus":null'));
  }
}

Matcher _apiFailure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

Matcher _editFailure(FailureKind kind, bool sent) =>
    isA<WorkItemHealthEditFailure>()
        .having((error) => error.failure.kind, 'kind', kind)
        .having((error) => error.mutationSent, 'mutationSent', sent);

Future<WorkItemHealthEditTarget> _target(
  GitLabApi api, {
  bool group = false,
  String state = 'OPEN',
  bool Function()? current,
}) async {
  final access = await api.workItemHealthEdit(
    _detail(group: group, state: state),
    expectedUserId: 7,
    generation: _generation,
    isCurrent: current ?? () => true,
  );
  expect(access.target, isNotNull);
  return access.target!;
}

Future<void> _expectConsumed(
  GitLabApi api,
  WorkItemHealthEditTarget target, {
  WorkItemHealthEditValue? desired = WorkItemHealthEditValue.atRisk,
}) async {
  await expectLater(
    api.updateWorkItemHealthStatus(
      target,
      desired: desired,
      generation: _generation,
      isCurrent: () => true,
    ),
    throwsA(_editFailure(FailureKind.writeUncertain, false)),
  );
}

void main() {
  for (final problem in ['exact', 'missing', 'project', 'namespace', 'payloadErrors', 'cancelled', 'schemaErrors']) {
    for (final phase in ['opening', 'preflight', 'noop', 'ack', 'readback']) {
      if (['payloadErrors', 'cancelled', 'schemaErrors'].contains(problem) && phase != 'ack') continue;
      test('strict health $phase $problem validates raw group owner', () async {
        var reads = 0;
        var writes = 0;
        var current = true;
        final adapter = FakeAdapter((request) {
          late Map<String, Object?> response;
          late Map<String, Object?> item;
          if (_isMutation(request)) {
            writes++;
            expect(_query(request), contains('project { id fullPath }'));
            expect(_query(request), contains('namespace { id fullPath }'));
            response = _ack(
              group: true,
              value: 'atRisk',
              updatedAt: _newerRevision,
            );
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
              value: reads < 3 ? 'needsAttention' : 'atRisk',
              updatedAt: reads < 3 ? _revision : _newerRevision,
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
        final detail = strictGroupDetail(api, _detail(group: true));
        final opening = api.workItemHealthEdit(
          detail,
          expectedUserId: 7,
          generation: _generation,
          isCurrent: () => current,
        );
        if (phase == 'opening' && problem != 'exact') {
          await expectLater(opening, throwsA(isA<ApiFailure>()));
          expect(writes, 0);
          return;
        }
        final access = await opening;
        if (phase == 'opening') {
          expect(writes, 0);
          return;
        }
        final save = api.updateWorkItemHealthStatus(
          access.target!,
          desired: phase == 'noop'
              ? WorkItemHealthEditValue.needsAttention
              : WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => current,
        );
        if (problem == 'exact') {
          expect(
            (await save).status,
            phase == 'noop'
                ? WorkItemHealthEditSaveStatus.noop
                : WorkItemHealthEditSaveStatus.success,
          );
        } else {
          final post = phase == 'ack' || phase == 'readback';
          await expectLater(
            save,
            throwsA(
              isA<WorkItemHealthEditFailure>()
                  .having((e) => e.mutationSent, 'sent', post)
                  .having(
                    (e) => post
                        ? e.failure.kind == FailureKind.writeUncertain
                        : e.failure.kind != FailureKind.writeUncertain,
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
    'default health accepts omitted project for group compatibility',
    () async {
      final item = _node(group: true)..remove('project');
      final api = testApi(
        FakeAdapter((_) => jsonResponse(_read(group: true, workItem: item))),
      );
      addTearDown(api.close);
      expect(
        (await api.workItemHealthEdit(
          _detail(group: true),
          expectedUserId: 7,
          generation: _generation,
          isCurrent: () => true,
        )).target,
        isNotNull,
      );
    },
  );

  test('pure edit models preserve strict values and immutable rollups', () {
    expect(WorkItemHealthEditValue.onTrack.graphValue, 'onTrack');
    expect(WorkItemHealthEditValue.needsAttention.graphValue, 'needsAttention');
    expect(WorkItemHealthEditValue.atRisk.graphValue, 'atRisk');
    expect(
      WorkItemHealthEditValue.parse('onTrack'),
      WorkItemHealthEditValue.onTrack,
    );
    expect(WorkItemHealthEditValue.parse(null), isNull);
    expect(
      () => WorkItemHealthEditValue.parse('unknown'),
      throwsFormatException,
    );

    final rollups = [
      WorkItemHealthEditRollup(
        value: WorkItemHealthEditValue.onTrack,
        count: 2,
      ),
    ];
    final snapshot = WorkItemHealthEditSnapshot(
      summary: _summary(),
      availability: WorkItemHealthEditAvailability.present,
      healthStatusFieldPresent: true,
      value: null,
      rolledUp: rollups,
    );
    rollups.clear();
    expect(snapshot.rolledUp, hasLength(1));
    expect(
      () => WorkItemHealthEditSnapshot(
        summary: _summary(),
        availability: WorkItemHealthEditAvailability.absent,
        healthStatusFieldPresent: true,
        value: null,
        rolledUp: null,
      ),
      throwsArgumentError,
    );
    expect(
      () => WorkItemHealthEditRollup(
        value: WorkItemHealthEditValue.atRisk,
        count: -1,
      ),
      throwsArgumentError,
    );
  });

  for (final state in ['OPEN', 'CLOSED']) {
    test(
      '$state custom type is writable by fresh widget presence and COLOR is orthogonal',
      () async {
        final transport = _OrderedTransport([
          _jsonStep(
            _read(
              state: state,
              value: 'needsAttention',
              widgets: [
                _healthWidget(
                  value: 'needsAttention',
                  rollup: const [
                    {'healthStatus': 'onTrack', 'count': 2},
                    {'healthStatus': 'atRisk', 'count': 1},
                  ],
                ),
              ],
            ),
            mutation: false,
            inspect: _expectReadContract,
          ),
          _jsonStep(
            _read(state: state, value: 'needsAttention'),
            mutation: false,
          ),
          _jsonStep(_ack(state: state, value: 'atRisk'), mutation: true),
          _jsonStep(_read(state: state, value: 'atRisk'), mutation: false),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final access = await api.workItemHealthEdit(
          _detail(state: state, widgetTypes: const {'COLOR'}),
          expectedUserId: 7,
          generation: _generation,
          isCurrent: () => true,
        );
        expect(access.actorId, _actorId);
        expect(access.canWrite, isTrue);
        expect(access.target, isNotNull);
        expect(
          access.snapshot.availability,
          WorkItemHealthEditAvailability.present,
        );
        expect(access.snapshot.healthStatusFieldPresent, isTrue);
        expect(access.snapshot.value, WorkItemHealthEditValue.needsAttention);
        expect(access.snapshot.rolledUp, hasLength(2));
        final saved = await api.updateWorkItemHealthStatus(
          access.target!,
          desired: WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => true,
        );
        expect(saved.status, WorkItemHealthEditSaveStatus.success);
        expect(saved.snapshot.value, WorkItemHealthEditValue.atRisk);
        expect(transport.sends, 1);
        await _expectConsumed(api, access.target!);
        transport.verifyConsumed();
      },
    );
  }

  test(
    'absent and unavailable widgets remain distinct read-only results',
    () async {
      for (final entry in <Object?, WorkItemHealthEditAvailability>{
        const <Object?>[]: WorkItemHealthEditAvailability.absent,
        null: WorkItemHealthEditAvailability.widgetsUnavailable,
      }.entries) {
        final transport = _OrderedTransport([
          _jsonStep(_read(widgets: entry.key), mutation: false),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final access = await api.workItemHealthEdit(
          _detail(),
          expectedUserId: 7,
          generation: _generation,
          isCurrent: () => true,
        );
        expect(access.snapshot.availability, entry.value);
        expect(access.snapshot.healthStatusFieldPresent, isFalse);
        expect(access.snapshot.value, isNull);
        expect(access.canWrite, isFalse);
        expect(access.target, isNull);
        transport.verifyConsumed();
      }
    },
  );

  test(
    'strict permissions distinguish forbidden, read-only, and malformed',
    () async {
      final cases = <(Map<String, Object?>?, FailureKind?, bool?)>[
        (
          {'readWorkItem': false, 'adminWorkItem': true},
          FailureKind.forbidden,
          null,
        ),
        ({'readWorkItem': true, 'adminWorkItem': false}, null, false),
        ({'adminWorkItem': true}, FailureKind.invalidResponse, null),
        ({'readWorkItem': true}, FailureKind.invalidResponse, null),
        (
          {'readWorkItem': 'true', 'adminWorkItem': true},
          FailureKind.invalidResponse,
          null,
        ),
        (
          {'readWorkItem': true, 'adminWorkItem': 1},
          FailureKind.invalidResponse,
          null,
        ),
        (null, FailureKind.invalidResponse, null),
      ];
      for (final (permissions, failure, canWrite) in cases) {
        final transport = _OrderedTransport([
          _jsonStep(
            permissions == null
                ? _read(changes: const {'userPermissions': null})
                : _read(permissions: permissions),
            mutation: false,
          ),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final future = api.workItemHealthEdit(
          _detail(),
          expectedUserId: 7,
          generation: _generation,
          isCurrent: () => true,
        );
        if (failure != null) {
          await expectLater(future, throwsA(_apiFailure(failure)));
        } else {
          final access = await future;
          expect(access.canWrite, canWrite);
          expect(access.target, isNull);
        }
        transport.verifyConsumed();
      }
    },
  );

  test(
    'widget cardinality, field presence, enum, and rollups fail closed',
    () async {
      final malformed = <Object?>[
        [_healthWidget(value: 'onTrack'), _healthWidget(value: 'atRisk')],
        [
          _healthWidget(value: 'onTrack'),
          _healthWidget(type: 'COLOR', value: null),
        ],
        [_healthWidget(value: 'onTrack', includeValue: false)],
        [_healthWidget(value: 'unknown')],
        [_healthWidget(value: 1)],
        [
          _healthWidget(
            value: 'onTrack',
            rollup: const [
              {'healthStatus': 'onTrack', 'count': 1},
              {'healthStatus': 'onTrack', 'count': 2},
            ],
          ),
        ],
        [
          _healthWidget(
            value: 'onTrack',
            rollup: const [
              {'healthStatus': 'unknown', 'count': 1},
            ],
          ),
        ],
      ];
      malformed.add([
        for (var index = 0; index < 33; index++)
          _healthWidget(value: 'onTrack'),
      ]);
      for (final widgets in malformed) {
        final transport = _OrderedTransport([
          _jsonStep(_read(widgets: widgets), mutation: false),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        await expectLater(
          api.workItemHealthEdit(
            _detail(),
            expectedUserId: 7,
            generation: _generation,
            isCurrent: () => true,
          ),
          throwsA(_apiFailure(FailureKind.invalidResponse)),
        );
        transport.verifyConsumed();
      }
    },
  );

  test(
    'unknown CE read envelopes are invalidResponse, never broad unsupported',
    () async {
      for (final body in [
        {
          'errors': [
            {
              'message': 'Field healthStatus is not available',
              'extensions': {'code': 'undefinedField'},
            },
          ],
        },
        {
          'errors': [
            {
              'message': 'Unknown health enum',
              'extensions': {'code': 'argumentLiteralsIncompatible'},
            },
          ],
        },
        {'errors': 'malformed'},
        {
          'errors': [
            {'message': 'health'},
          ],
          'data': _read()['data'],
        },
      ]) {
        final transport = _OrderedTransport([_jsonStep(body, mutation: false)]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        await expectLater(
          api.workItemHealthEdit(
            _detail(),
            expectedUserId: 7,
            generation: _generation,
            isCurrent: () => true,
          ),
          throwsA(_apiFailure(FailureKind.invalidResponse)),
        );
        transport.verifyConsumed();
      }
    },
  );

  test('invalid update generation burns the target before transport', () async {
    final transport = _OrderedTransport([
      _jsonStep(_read(value: 'onTrack'), mutation: false),
    ]);
    final api = testApi(transport.adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemHealthStatus(
        target,
        desired: WorkItemHealthEditValue.atRisk,
        generation: -1,
        isCurrent: () => true,
      ),
      throwsA(_editFailure(FailureKind.validation, false)),
    );
    await _expectConsumed(api, target);
    expect(transport.sends, 0);
    transport.verifyConsumed();
  });

  test(
    'no-op set and explicit clear consume the target without handoff',
    () async {
      for (final desired in <WorkItemHealthEditValue?>[
        WorkItemHealthEditValue.onTrack,
        null,
      ]) {
        var callbacks = 0;
        final graph = desired?.graphValue;
        final transport = _OrderedTransport([
          _jsonStep(_read(value: graph), mutation: false),
          _jsonStep(_read(value: graph), mutation: false),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        final saved = await api.updateWorkItemHealthStatus(
          target,
          desired: desired,
          generation: _generation,
          isCurrent: () => true,
          onMutationSent: () => callbacks++,
        );
        expect(saved.status, WorkItemHealthEditSaveStatus.noop);
        expect(saved.snapshot.value, desired);
        expect(saved.acknowledgedUpdatedAt, isNull);
        expect(saved.mutationSent, isFalse);
        expect(callbacks, 0);
        expect(transport.sends, 0);
        await _expectConsumed(api, target, desired: desired);
        transport.verifyConsumed();
      }
    },
  );

  test(
    'permission, actor, identity, state, and revision drift are typed before send',
    () async {
      final cases = <(String, Object?, FailureKind)>[
        (
          'permission',
          _read(
            value: 'onTrack',
            permissions: const {'readWorkItem': true, 'adminWorkItem': false},
          ),
          FailureKind.forbidden,
        ),
        (
          'actor',
          _read(value: 'onTrack', actor: const {'id': 'gid://gitlab/User/8'}),
          FailureKind.cancelled,
        ),
        (
          'id',
          _read(
            value: 'onTrack',
            changes: const {'id': 'gid://gitlab/WorkItem/99'},
          ),
          FailureKind.conflict,
        ),
        ('invisible item', _read(workItem: null), FailureKind.conflict),
        (
          'iid',
          _read(value: 'onTrack', changes: const {'iid': '99'}),
          FailureKind.conflict,
        ),
        (
          'project',
          _read(
            value: 'onTrack',
            changes: const {
              'project': {
                'id': 'gid://gitlab/Project/99',
                'fullPath': 'other/project',
              },
            },
          ),
          FailureKind.conflict,
        ),
        (
          'namespace null placement',
          _read(value: 'onTrack', changes: const {'namespace': null}),
          FailureKind.conflict,
        ),
        (
          'type',
          _read(
            value: 'onTrack',
            changes: const {
              'workItemType': {
                'id': 'gid://gitlab/WorkItems::Type/99',
                'name': 'Other',
              },
            },
          ),
          FailureKind.conflict,
        ),
        (
          'state',
          _read(value: 'onTrack', changes: const {'state': 'CLOSED'}),
          FailureKind.conflict,
        ),
        (
          'revision',
          _read(value: 'onTrack', updatedAt: _newerRevision),
          FailureKind.conflict,
        ),
        ('old value', _read(value: 'atRisk'), FailureKind.conflict),
        (
          'widget unavailable',
          _read(value: 'onTrack', widgets: const <Object?>[]),
          FailureKind.unsupported,
        ),
        (
          'malformed widget',
          _read(value: 'onTrack', includeValue: false),
          FailureKind.invalidResponse,
        ),
      ];
      for (final (label, preflight, kind) in cases) {
        var callbacks = 0;
        final transport = _OrderedTransport([
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(preflight, mutation: false),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemHealthStatus(
            target,
            desired: WorkItemHealthEditValue.atRisk,
            generation: _generation,
            isCurrent: () => true,
            onMutationSent: () => callbacks++,
          ),
          throwsA(_editFailure(kind, false)),
          reason: label,
        );
        expect(callbacks, 0, reason: label);
        expect(transport.sends, 0, reason: label);
        await _expectConsumed(api, target);
        transport.verifyConsumed();
      }
    },
  );

  test(
    'current owner loss after the preflight await burns without sending',
    () async {
      var current = true;
      var callbacks = 0;
      final transport = _OrderedTransport([
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        (request) {
          expect(_isMutation(request), isFalse);
          current = false;
          return jsonResponse(_read(value: 'onTrack'));
        },
      ]);
      final api = testApi(transport.adapter);
      addTearDown(api.close);
      final target = await _target(api, current: () => current);
      await expectLater(
        api.updateWorkItemHealthStatus(
          target,
          desired: WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => current,
          onMutationSent: () => callbacks++,
        ),
        throwsA(_editFailure(FailureKind.cancelled, false)),
      );
      expect(callbacks, 0);
      expect(transport.sends, 0);
      await _expectConsumed(api, target);
      transport.verifyConsumed();
    },
  );

  test(
    'owner, generation, current, and closed API deny before callback and burn',
    () async {
      final ownerTransport = _OrderedTransport([
        _jsonStep(_read(value: 'onTrack'), mutation: false),
      ]);
      final owner = testApi(ownerTransport.adapter);
      addTearDown(owner.close);
      final target = await _target(owner);
      final other = testApi(FakeAdapter((_) => fail('other API transport')));
      addTearDown(other.close);
      await expectLater(
        other.updateWorkItemHealthStatus(
          target,
          desired: WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => true,
        ),
        throwsA(_editFailure(FailureKind.cancelled, false)),
      );
      await _expectConsumed(owner, target);
      ownerTransport.verifyConsumed();

      for (final mode in ['generation', 'current', 'closed']) {
        final transport = _OrderedTransport([
          _jsonStep(_read(value: 'onTrack'), mutation: false),
        ]);
        final api = testApi(transport.adapter);
        final localTarget = await _target(api);
        if (mode == 'closed') api.close();
        await expectLater(
          api.updateWorkItemHealthStatus(
            localTarget,
            desired: WorkItemHealthEditValue.atRisk,
            generation: mode == 'generation' ? _generation + 1 : _generation,
            isCurrent: () => mode != 'current',
          ),
          throwsA(_editFailure(FailureKind.cancelled, false)),
        );
        expect(transport.sends, 0);
        await _expectConsumed(api, localTarget);
        transport.verifyConsumed();
        if (mode != 'closed') {
          api.close();
        }
      }
    },
  );

  test(
    'callback failure is cancelled false with one callback and zero sends',
    () async {
      var callbacks = 0;
      final transport = _OrderedTransport([
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_read(value: 'onTrack'), mutation: false),
      ]);
      final api = testApi(transport.adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemHealthStatus(
          target,
          desired: WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => true,
          onMutationSent: () {
            callbacks++;
            throw StateError('synthetic callback failure');
          },
        ),
        throwsA(_editFailure(FailureKind.cancelled, false)),
      );
      expect(callbacks, 1);
      expect(transport.sends, 0);
      await _expectConsumed(api, target);
      transport.verifyConsumed();
    },
  );

  test(
    'every throwing callback is cancelled false without leaking or sending',
    () async {
      const leakTitle = 'synthetic callback title leak';
      const leakDetail = 'synthetic callback detail leak';
      final thrownByCallback = <Object>[
        const ApiFailure(FailureKind.cancelled),
        const ApiFailure(FailureKind.forbidden, status: 403),
        const ApiFailure(FailureKind.writeUncertain),
        const ApiFailure(FailureKind.network),
        const ApiFailure(FailureKind.validation),
        const ApiFailure(
          FailureKind.invalidResponse,
          status: 418,
          title: leakTitle,
          detail: leakDetail,
        ),
        const WorkItemHealthEditFailure(
          ApiFailure(
            FailureKind.writeUncertain,
            title: leakTitle,
            detail: leakDetail,
          ),
          true,
        ),
      ];
      for (final thrown in thrownByCallback) {
        final requests = <String>[];
        var callbacks = 0;
        final transport = _OrderedTransport([
          _jsonStep(
            _read(value: 'onTrack'),
            mutation: false,
            inspect: (_) => requests.add('target-read'),
          ),
          _jsonStep(
            _read(value: 'onTrack'),
            mutation: false,
            inspect: (_) => requests.add('preflight-read'),
          ),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        Object? caught;
        try {
          await api.updateWorkItemHealthStatus(
            target,
            desired: WorkItemHealthEditValue.atRisk,
            generation: _generation,
            isCurrent: () => true,
            onMutationSent: () {
              callbacks++;
              throw thrown;
            },
          );
        } on Object catch (error) {
          caught = error;
        }
        final reason = 'callback threw $thrown';
        expect(
          caught,
          _editFailure(FailureKind.cancelled, false),
          reason: reason,
        );
        final failure = (caught! as WorkItemHealthEditFailure).failure;
        expect(identical(caught, thrown), isFalse, reason: reason);
        expect(identical(failure, thrown), isFalse, reason: reason);
        expect(failure.status, isNull, reason: reason);
        expect(failure.title, isNot(leakTitle), reason: reason);
        expect(failure.detail, isNot(leakDetail), reason: reason);
        expect(callbacks, 1, reason: reason);
        expect(transport.sends, 0, reason: reason);
        expect(requests, ['target-read', 'preflight-read'], reason: reason);
        await _expectConsumed(api, target);
        expect(callbacks, 1, reason: '$reason: never retried');
        expect(transport.sends, 0, reason: reason);
        expect(requests, hasLength(2), reason: reason);
        transport.verifyConsumed();
      }
    },
  );

  for (final denial in ['false', 'throw']) {
    test(
      'final pre-callback owner denial ($denial) is unsent with zero sends',
      () async {
        final outcomes =
            <
              ({
                int denyAt,
                Object? error,
                WorkItemHealthEditSaveResult? result,
                int callbacks,
                int reads,
                int sends,
              })
            >[];
        for (var denyAt = 1; ; denyAt++) {
          expect(denyAt, lessThan(40), reason: 'denial sweep must terminate');
          final transport = _StatefulHealthTransport(
            initial: WorkItemHealthEditValue.onTrack,
          );
          final api = testApi(transport.adapter);
          addTearDown(api.close);
          final target = await _target(api);
          expect(transport.reads, 1);
          var probes = 0;
          var callbacks = 0;
          Object? error;
          WorkItemHealthEditSaveResult? result;
          try {
            result = await api.updateWorkItemHealthStatus(
              target,
              desired: WorkItemHealthEditValue.atRisk,
              generation: _generation,
              isCurrent: () {
                if (++probes != denyAt) return true;
                if (denial == 'throw') {
                  throw StateError('synthetic owner probe failure');
                }
                return false;
              },
              onMutationSent: () => callbacks++,
            );
          } on Object catch (caught) {
            error = caught;
          }
          outcomes.add((
            denyAt: denyAt,
            error: error,
            result: result,
            callbacks: callbacks,
            reads: transport.reads,
            sends: transport.mutations,
          ));
          if (callbacks == 0) {
            final requestsBefore = transport.requests;
            await _expectConsumed(api, target);
            expect(transport.requests, requestsBefore);
          }
          if (probes < denyAt) break;
        }

        final control = outcomes.last;
        expect(control.error, isNull, reason: 'affirmative control');
        expect(control.result?.status, WorkItemHealthEditSaveStatus.success);
        expect(control.result?.mutationSent, isTrue);
        expect(control.callbacks, 1);
        expect(control.sends, 1);
        expect(control.reads, 3);

        final denied = outcomes.sublist(0, outcomes.length - 1);
        final unsent = denied.where((o) => o.callbacks == 0).toList();
        final handedOff = denied.where((o) => o.callbacks != 0).toList();
        expect(unsent, isNotEmpty);
        expect(handedOff, isNotEmpty);
        expect(
          denied.indexWhere((o) => o.callbacks != 0),
          unsent.length,
          reason: 'every pre-callback denial precedes every handoff',
        );
        final preCallbackKind = denial == 'throw'
            ? FailureKind.invalidResponse
            : FailureKind.cancelled;
        for (final outcome in unsent) {
          final reason = 'denial at probe ${outcome.denyAt}';
          expect(
            outcome.error,
            _editFailure(preCallbackKind, false),
            reason: reason,
          );
          expect(outcome.sends, 0, reason: reason);
        }
        final finalPreCallback = unsent.last;
        expect(
          finalPreCallback.reads,
          2,
          reason: 'the last pre-callback check follows target and preflight',
        );
        expect(
          unsent.where((o) => o.reads == 2).length,
          greaterThanOrEqualTo(2),
          reason: 'a post-preflight check precedes the final owner check',
        );
        for (final outcome in handedOff) {
          final reason = 'denial at probe ${outcome.denyAt}';
          expect(outcome.callbacks, 1, reason: reason);
          expect(
            outcome.error,
            _editFailure(FailureKind.writeUncertain, true),
            reason: reason,
          );
          expect(outcome.sends, 1, reason: reason);
        }
      },
    );
  }

  test(
    'a callback that closes the API stays cancelled before send',
    () async {
      var callbacks = 0;
      final transport = _OrderedTransport([
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_read(value: 'onTrack'), mutation: false),
      ]);
      final api = testApi(transport.adapter);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemHealthStatus(
          target,
          desired: WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => true,
          onMutationSent: () {
            callbacks++;
            api.close();
          },
        ),
        throwsA(_editFailure(FailureKind.cancelled, false)),
      );
      expect(callbacks, 1);
      expect(transport.sends, 0);
      await _expectConsumed(api, target);
      transport.verifyConsumed();
    },
  );

  for (final entry in <(String, WorkItemHealthEditValue?, String?)>[
    ('same-second set', WorkItemHealthEditValue.atRisk, 'atRisk'),
    ('same-second clear', null, null),
  ]) {
    test(
      '${entry.$1} sends once and requires exact independent read',
      () async {
        final (label, desired, graphValue) = entry;
        var callbacks = 0;
        var mutationNonce = 0;
        final oldValue = desired == null ? 'onTrack' : null;
        final transport = _OrderedTransport([
          _jsonStep(_read(value: oldValue), mutation: false),
          _jsonStep(_read(value: oldValue), mutation: false),
          _jsonStep(
            _ack(value: graphValue, updatedAt: _revision),
            mutation: true,
            inspect: (request) {
              mutationNonce++;
              expect(mutationNonce, 1);
              _expectMutationInput(request, _summary().id, graphValue);
            },
          ),
          _jsonStep(
            _read(value: graphValue, updatedAt: _revision),
            mutation: false,
          ),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        final saved = await api.updateWorkItemHealthStatus(
          target,
          desired: desired,
          generation: _generation,
          isCurrent: () => true,
          onMutationSent: () => callbacks++,
        );
        expect(
          saved.status,
          WorkItemHealthEditSaveStatus.success,
          reason: label,
        );
        expect(saved.snapshot.value, desired);
        expect(saved.acknowledgedUpdatedAt, _revision);
        expect(saved.mutationSent, isTrue);
        expect(callbacks, 1);
        expect(transport.sends, 1);
        await _expectConsumed(api, target, desired: desired);
        transport.verifyConsumed();
      },
    );
  }

  test(
    'group scope keeps null project and exact group namespace through readback',
    () async {
      final transport = _OrderedTransport([
        _jsonStep(_read(group: true, value: 'onTrack'), mutation: false),
        _jsonStep(_read(group: true, value: 'onTrack'), mutation: false),
        _jsonStep(
          _ack(group: true, value: 'atRisk'),
          mutation: true,
          inspect: (request) =>
              _expectMutationInput(request, _summary(group: true).id, 'atRisk'),
        ),
        _jsonStep(_read(group: true, value: 'atRisk'), mutation: false),
      ]);
      final api = testApi(transport.adapter);
      addTearDown(api.close);
      final target = await _target(api, group: true);
      final saved = await api.updateWorkItemHealthStatus(
        target,
        desired: WorkItemHealthEditValue.atRisk,
        generation: _generation,
        isCurrent: () => true,
      );
      expect(saved.status, WorkItemHealthEditSaveStatus.success);
      expect(saved.snapshot.summary.project, isNull);
      expect(saved.snapshot.summary.namespace?.id, 'gid://gitlab/Group/84');
      expect(transport.sends, 1);
      await _expectConsumed(api, target);
      transport.verifyConsumed();
    },
  );

  test(
    'unchanged ACK and read at the preflight revision is notApplied',
    () async {
      var callbacks = 0;
      final transport = _OrderedTransport([
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_ack(value: 'onTrack', updatedAt: _revision), mutation: true),
        _jsonStep(
          _read(value: 'onTrack', updatedAt: _revision),
          mutation: false,
        ),
      ]);
      final api = testApi(transport.adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final saved = await api.updateWorkItemHealthStatus(
        target,
        desired: WorkItemHealthEditValue.atRisk,
        generation: _generation,
        isCurrent: () => true,
        onMutationSent: () => callbacks++,
      );
      expect(saved.status, WorkItemHealthEditSaveStatus.notApplied);
      expect(saved.snapshot.value, WorkItemHealthEditValue.onTrack);
      expect(saved.acknowledgedUpdatedAt, _revision);
      expect(saved.mutationSent, isTrue);
      expect(callbacks, 1);
      expect(transport.sends, 1);
      await _expectConsumed(api, target);
      transport.verifyConsumed();
    },
  );

  test(
    'older, wrong-value, and revision-drift outcomes are uncertain',
    () async {
      final cases = <(String, Map<String, Object?>, Map<String, Object?>)>[
        (
          'older ACK',
          _ack(value: 'atRisk', updatedAt: _olderRevision),
          _read(value: 'atRisk', updatedAt: _olderRevision),
        ),
        (
          'equal wrong value',
          _ack(value: 'needsAttention', updatedAt: _revision),
          _read(value: 'needsAttention', updatedAt: _revision),
        ),
        (
          'newer old value',
          _ack(value: 'onTrack', updatedAt: _newerRevision),
          _read(value: 'onTrack', updatedAt: _newerRevision),
        ),
        (
          'read revision drift',
          _ack(value: 'atRisk', updatedAt: _revision),
          _read(value: 'atRisk', updatedAt: _newerRevision),
        ),
        (
          'desired acknowledgement with old readback',
          _ack(value: 'atRisk', updatedAt: _revision),
          _read(value: 'onTrack', updatedAt: _revision),
        ),
      ];
      for (final (label, ack, readback) in cases) {
        var callbacks = 0;
        final transport = _OrderedTransport([
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(ack, mutation: true),
          _jsonStep(readback, mutation: false),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemHealthStatus(
            target,
            desired: WorkItemHealthEditValue.atRisk,
            generation: _generation,
            isCurrent: () => true,
            onMutationSent: () => callbacks++,
          ),
          throwsA(_editFailure(FailureKind.writeUncertain, true)),
          reason: label,
        );
        expect(callbacks, 1, reason: label);
        expect(transport.sends, 1, reason: label);
        await _expectConsumed(api, target);
        transport.verifyConsumed();
      }
    },
  );

  test('well-formed nonempty payload errors are validation true', () async {
    var callbacks = 0;
    final transport = _OrderedTransport([
      _jsonStep(_read(value: 'onTrack'), mutation: false),
      _jsonStep(_read(value: 'onTrack'), mutation: false),
      _jsonStep(
        _ack(value: 'onTrack', errors: const ['health is invalid']),
        mutation: true,
      ),
    ]);
    final api = testApi(transport.adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemHealthStatus(
        target,
        desired: WorkItemHealthEditValue.atRisk,
        generation: _generation,
        isCurrent: () => true,
        onMutationSent: () => callbacks++,
      ),
      throwsA(_editFailure(FailureKind.validation, true)),
    );
    expect(callbacks, 1);
    expect(transport.sends, 1);
    await _expectConsumed(api, target);
    transport.verifyConsumed();
  });

  test(
    'malformed payload errors and mixed top-level errors are uncertain true',
    () async {
      for (final body in [
        _ack(value: 'atRisk', includeErrors: false),
        _ack(value: 'atRisk', errors: 'invalid'),
        _ack(value: 'atRisk', errors: const [1]),
        {
          'errors': [
            {
              'message': 'Unknown health input field',
              'extensions': {'code': 'argumentLiteralsIncompatible'},
            },
          ],
        },
        {
          'errors': [
            {
              'message': 'health failed',
              'extensions': {'code': 'undefinedField'},
            },
          ],
          'data': _ack(value: 'atRisk')['data'],
        },
      ]) {
        var callbacks = 0;
        final transport = _OrderedTransport([
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(body, mutation: true),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemHealthStatus(
            target,
            desired: WorkItemHealthEditValue.atRisk,
            generation: _generation,
            isCurrent: () => true,
            onMutationSent: () => callbacks++,
          ),
          throwsA(_editFailure(FailureKind.writeUncertain, true)),
        );
        expect(callbacks, 1);
        expect(transport.sends, 1);
        await _expectConsumed(api, target);
        transport.verifyConsumed();
      }
    },
  );

  test(
    'transport, HTTP, cancellation, and post-handoff owner drift are uncertain',
    () async {
      final mutationSteps = <FutureOr<ResponseBody> Function(RequestOptions)>[
        (request) => throw DioException(
          requestOptions: request,
          type: DioExceptionType.receiveTimeout,
        ),
        _jsonStep(const {}, mutation: true, status: 500),
        (request) => throw DioException(
          requestOptions: request,
          type: DioExceptionType.cancel,
        ),
      ];
      for (final mutationStep in mutationSteps) {
        var callbacks = 0;
        final transport = _OrderedTransport([
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          mutationStep,
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemHealthStatus(
            target,
            desired: WorkItemHealthEditValue.atRisk,
            generation: _generation,
            isCurrent: () => true,
            onMutationSent: () => callbacks++,
          ),
          throwsA(_editFailure(FailureKind.writeUncertain, true)),
        );
        expect(callbacks, 1);
        expect(transport.sends, 1);
        await _expectConsumed(api, target);
        transport.verifyConsumed();
      }

      var current = true;
      var callbacks = 0;
      final driftTransport = _OrderedTransport([
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        (request) {
          expect(_isMutation(request), isTrue);
          current = false;
          return jsonResponse(_ack(value: 'atRisk'));
        },
      ]);
      final driftApi = testApi(driftTransport.adapter);
      addTearDown(driftApi.close);
      final driftTarget = await _target(driftApi, current: () => current);
      await expectLater(
        driftApi.updateWorkItemHealthStatus(
          driftTarget,
          desired: WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => current,
          onMutationSent: () => callbacks++,
        ),
        throwsA(_editFailure(FailureKind.writeUncertain, true)),
      );
      expect(callbacks, 1);
      expect(driftTransport.sends, 1);
      driftTransport.verifyConsumed();
    },
  );

  test(
    'malformed acknowledgements are uncertain with one send and no readback',
    () async {
      final malformed = <Object?>[
        _ack(workItem: null),
        _ack(
          value: 'atRisk',
          changes: const {'id': 'gid://gitlab/WorkItem/99'},
        ),
        _ack(value: 'atRisk', changes: const {'updatedAt': 'not-a-time'}),
        _ack(widgets: const <Object?>[]),
        _ack(
          widgets: [
            _healthWidget(value: 'atRisk'),
            _healthWidget(value: 'atRisk'),
          ],
        ),
        _ack(value: 'atRisk', includeValue: false),
        _ack(value: 'unknown'),
      ];
      for (final body in malformed) {
        var callbacks = 0;
        final transport = _OrderedTransport([
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(body, mutation: true),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemHealthStatus(
            target,
            desired: WorkItemHealthEditValue.atRisk,
            generation: _generation,
            isCurrent: () => true,
            onMutationSent: () => callbacks++,
          ),
          throwsA(_editFailure(FailureKind.writeUncertain, true)),
        );
        expect(callbacks, 1);
        expect(transport.sends, 1);
        await _expectConsumed(api, target);
        transport.verifyConsumed();
      }
    },
  );

  test(
    'readback actor, scope, type, state, permission, and shape drift are uncertain',
    () async {
      final readbacks = <Object?>[
        _read(value: 'atRisk', actor: const {'id': 'gid://gitlab/User/8'}),
        _read(value: 'atRisk', changes: const {'iid': '99'}),
        _read(
          value: 'atRisk',
          changes: const {
            'namespace': {
              'id': 'gid://gitlab/Namespaces::ProjectNamespace/99',
              'fullPath': 'other/project',
            },
          },
        ),
        _read(
          value: 'atRisk',
          changes: const {
            'workItemType': {
              'id': 'gid://gitlab/WorkItems::Type/99',
              'name': 'Other',
            },
          },
        ),
        _read(value: 'atRisk', changes: const {'state': 'CLOSED'}),
        _read(
          value: 'atRisk',
          permissions: const {'readWorkItem': true, 'adminWorkItem': false},
        ),
        _read(value: 'atRisk', includeValue: false),
      ];
      for (final readback in readbacks) {
        var callbacks = 0;
        final transport = _OrderedTransport([
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(_read(value: 'onTrack'), mutation: false),
          _jsonStep(_ack(value: 'atRisk'), mutation: true),
          _jsonStep(readback, mutation: false),
        ]);
        final api = testApi(transport.adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemHealthStatus(
            target,
            desired: WorkItemHealthEditValue.atRisk,
            generation: _generation,
            isCurrent: () => true,
            onMutationSent: () => callbacks++,
          ),
          throwsA(_editFailure(FailureKind.writeUncertain, true)),
        );
        expect(callbacks, 1);
        expect(transport.sends, 1);
        await _expectConsumed(api, target);
        transport.verifyConsumed();
      }
    },
  );

  test(
    'clearReadCache is not an owner generation and does not invalidate a target',
    () async {
      final transport = _OrderedTransport([
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_ack(value: 'atRisk'), mutation: true),
        _jsonStep(_read(value: 'atRisk'), mutation: false),
      ]);
      final api = testApi(transport.adapter);
      addTearDown(api.close);
      final target = await _target(api);
      api.clearReadCache();
      final saved = await api.updateWorkItemHealthStatus(
        target,
        desired: WorkItemHealthEditValue.atRisk,
        generation: _generation,
        isCurrent: () => true,
      );
      expect(saved.status, WorkItemHealthEditSaveStatus.success);
      expect(transport.sends, 1);
      await _expectConsumed(api, target);
      transport.verifyConsumed();
    },
  );

  test(
    'readback malformed JSON after handoff never leaks a raw failure',
    () async {
      var callbacks = 0;
      final transport = _OrderedTransport([
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_read(value: 'onTrack'), mutation: false),
        _jsonStep(_ack(value: 'atRisk'), mutation: true),
        (request) {
          expect(_isMutation(request), isFalse);
          return ResponseBody.fromString('not-json', 200);
        },
      ]);
      final api = testApi(transport.adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemHealthStatus(
          target,
          desired: WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => true,
          onMutationSent: () => callbacks++,
        ),
        throwsA(_editFailure(FailureKind.writeUncertain, true)),
      );
      expect(callbacks, 1);
      expect(transport.sends, 1);
      await _expectConsumed(api, target);
      transport.verifyConsumed();
    },
  );

  group('stateful public API health mutation', () {
    test(
      'same-second set then explicit-null clear use authoritative fresh readback',
      () async {
        final transport = _StatefulHealthTransport();
        final api = testApi(transport.adapter);
        addTearDown(api.close);

        final setAccess = await api.workItemHealthEdit(
          _detail(),
          expectedUserId: 7,
          generation: _generation,
          isCurrent: () => true,
        );
        expect(setAccess.actorId, _actorId);
        expect(setAccess.canWrite, isTrue);
        expect(setAccess.target, isNotNull);
        expect(
          setAccess.snapshot.availability,
          WorkItemHealthEditAvailability.present,
        );
        expect(setAccess.snapshot.healthStatusFieldPresent, isTrue);
        expect(
          setAccess.snapshot.value,
          WorkItemHealthEditValue.needsAttention,
        );
        expect(setAccess.snapshot.rolledUp, isEmpty);
        final opening = setAccess.snapshot.summary;
        expect(opening.id, 'gid://gitlab/WorkItem/31');
        expect(opening.iid, 31);
        expect(opening.title, 'Fresh title');
        expect(opening.state, 'OPEN');
        expect(opening.createdAt, _createdAt);
        expect(opening.updatedAt, _revision);
        expect(opening.project?.id, 'gid://gitlab/Project/42');
        expect(opening.project?.fullPath, 'studio/mobile-workspace');
        expect(
          opening.namespace?.id,
          'gid://gitlab/Namespaces::ProjectNamespace/42',
        );
        expect(opening.namespace?.fullPath, 'studio/mobile-workspace');
        expect(opening.type.id, 'gid://gitlab/WorkItems::Type/9');
        expect(opening.type.name, 'Renamed objective');
        expect(transport.requests, 1);
        expect(transport.reads, 1);
        expect(transport.mutations, 0);

        var setCallbacks = 0;
        final setTarget = setAccess.target!;
        final setResult = await api.updateWorkItemHealthStatus(
          setTarget,
          desired: WorkItemHealthEditValue.atRisk,
          generation: _generation,
          isCurrent: () => true,
          onMutationSent: () => setCallbacks++,
        );
        expect(setResult.status, WorkItemHealthEditSaveStatus.success);
        expect(setResult.snapshot.value, WorkItemHealthEditValue.atRisk);
        expect(setResult.snapshot.summary.updatedAt, _revision);
        expect(setResult.acknowledgedUpdatedAt, _revision);
        expect(setResult.mutationSent, isTrue);
        expect(identical(setResult.snapshot, setAccess.snapshot), isFalse);
        expect(transport.value, WorkItemHealthEditValue.atRisk);
        expect(transport.stateChanges, 1);
        expect(setCallbacks, 1);
        expect(transport.requests, 4);
        expect(transport.reads, 3);
        expect(transport.mutations, 1);

        await expectLater(
          api.updateWorkItemHealthStatus(
            setTarget,
            desired: WorkItemHealthEditValue.needsAttention,
            generation: _generation,
            isCurrent: () => true,
          ),
          throwsA(_editFailure(FailureKind.writeUncertain, false)),
        );
        expect(transport.requests, 4);
        expect(transport.mutations, 1);
        expect(transport.stateChanges, 1);

        final clearAccess = await api.workItemHealthEdit(
          _detail(),
          expectedUserId: 7,
          generation: _generation,
          isCurrent: () => true,
        );
        expect(clearAccess.actorId, _actorId);
        expect(clearAccess.canWrite, isTrue);
        expect(clearAccess.snapshot.value, WorkItemHealthEditValue.atRisk);
        expect(clearAccess.snapshot.summary.updatedAt, _revision);
        expect(clearAccess.target, isNotNull);
        expect(transport.requests, 5);
        expect(transport.reads, 4);

        var clearCallbacks = 0;
        final clearTarget = clearAccess.target!;
        final clearResult = await api.updateWorkItemHealthStatus(
          clearTarget,
          desired: null,
          generation: _generation,
          isCurrent: () => true,
          onMutationSent: () => clearCallbacks++,
        );
        expect(clearResult.status, WorkItemHealthEditSaveStatus.success);
        expect(clearResult.snapshot.value, isNull);
        expect(clearResult.snapshot.summary.updatedAt, _revision);
        expect(clearResult.acknowledgedUpdatedAt, _revision);
        expect(clearResult.mutationSent, isTrue);
        expect(identical(clearResult.snapshot, clearAccess.snapshot), isFalse);
        expect(transport.value, isNull);
        expect(transport.stateChanges, 2);
        expect(clearCallbacks, 1);

        await expectLater(
          api.updateWorkItemHealthStatus(
            clearTarget,
            desired: WorkItemHealthEditValue.onTrack,
            generation: _generation,
            isCurrent: () => true,
          ),
          throwsA(_editFailure(FailureKind.writeUncertain, false)),
        );

        expect(transport.operations, [
          'read',
          'read',
          'mutation',
          'read',
          'read',
          'read',
          'mutation',
          'read',
        ]);
        expect(transport.requests, 8);
        expect(transport.reads, 6);
        expect(transport.mutations, 2);
        expect(transport.readRequestNonces, [1, 2, 4, 5, 6, 8]);
        expect(transport.mutationRequestNonces, [3, 7]);
        expect(transport.mutationNonces, [1, 2]);
        expect(transport.readValues, [
          WorkItemHealthEditValue.needsAttention,
          WorkItemHealthEditValue.needsAttention,
          WorkItemHealthEditValue.atRisk,
          WorkItemHealthEditValue.atRisk,
          WorkItemHealthEditValue.atRisk,
          null,
        ]);
        expect(transport.appliedValues, [WorkItemHealthEditValue.atRisk, null]);
        expect(transport.mutationGraphValues, ['atRisk', null]);
        expect(setCallbacks + clearCallbacks, 2);
        expect(transport.stateChanges, transport.mutations);
      },
    );
  });
}
