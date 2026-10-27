import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';

const _actorId = 'gid://gitlab/User/7';
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
  createdAt: DateTime.utc(2026, 10, 1),
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
  widgetTypes: const {'DESCRIPTION'},
  descriptionWidget: const WorkItemDescriptionWidget(
    description: 'possibly stale',
    edited: false,
    lastEditedAt: null,
  ),
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Map<String, Object?> _node({
  bool group = false,
  String title = 'Fresh title',
  String state = 'OPEN',
  DateTime? updatedAt,
  String typeId = 'gid://gitlab/WorkItems::Type/9',
  String typeName = 'Task',
  Object? widgets = const [
    {
      'type': 'DESCRIPTION',
      'description': 'Original markdown',
      'edited': false,
      'lastEditedAt': null,
    },
  ],
  bool permissionIncluded = true,
  Object? permission = true,
  Map<String, Object?> changes = const {},
}) {
  final expected = _summary(group: group);
  return {
    'id': expected.id,
    'iid': '${expected.iid}',
    'title': title,
    'state': state,
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
    'workItemType': {'id': typeId, 'name': typeName},
    if (permissionIncluded) 'userPermissions': {'updateWorkItem': permission},
    'widgets': widgets,
    ...changes,
  };
}

Map<String, Object?> _read({
  bool group = false,
  Object? actor = const {'id': _actorId},
  String title = 'Fresh title',
  DateTime? updatedAt,
  Object? widgets = const [
    {
      'type': 'DESCRIPTION',
      'description': 'Original markdown',
      'edited': false,
      'lastEditedAt': null,
    },
  ],
  Object? permission = true,
  Map<String, Object?> changes = const {},
}) => {
  'data': {
    'currentUser': actor,
    'workItem': _node(
      group: group,
      title: title,
      updatedAt: updatedAt,
      widgets: widgets,
      permission: permission,
      changes: changes,
    ),
  },
};

Map<String, Object?> _ack({
  bool group = false,
  String title = 'Changed title',
  Object? widgets = const [
    {
      'type': 'DESCRIPTION',
      'description': '  changed markdown  ',
      'edited': true,
      'lastEditedAt': '2026-10-03T10:00:00.000Z',
    },
  ],
  Object? errors = const <Object?>[],
  Object? workItem = _sentinel,
}) => {
  'data': {
    'workItemUpdate': {
      'errors': errors,
      'workItem': identical(workItem, _sentinel)
          ? _node(
              group: group,
              title: title,
              updatedAt: _savedAt,
              widgets: widgets,
              permissionIncluded: false,
            )
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

Future<WorkItemContentTarget> _target(
  GitLabApi api, {
  bool group = false,
}) async => (await api.workItemContent(
  _detail(group: group),
  expectedUserId: 7,
)).target!;

void main() {
  for (final group in [false, true]) {
    test(
      '${group ? 'group' : 'project'} read returns fresh raw content and exact actor-bound target',
      () async {
        final adapter = FakeAdapter(
          (_) => jsonResponse(
            _read(
              group: group,
              widgets: const [
                {
                  'type': 'DESCRIPTION',
                  'description': '  fresh markdown  ',
                  'edited': true,
                  'lastEditedAt': '2026-10-03T08:30:00.000Z',
                },
              ],
            ),
          ),
        );
        final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
        addTearDown(api.close);

        final access = await api.workItemContent(
          _detail(group: group),
          expectedUserId: 7,
        );
        expect(access.snapshot.summary.title, 'Fresh title');
        expect(access.snapshot.summary.updatedAt, _freshAt);
        expect(access.snapshot.rawDescription, '  fresh markdown  ');
        expect(access.snapshot.edited, isTrue);
        expect(access.snapshot.lastEditedAt, DateTime.utc(2026, 10, 3, 8, 30));
        expect(
          access.snapshot.descriptionAvailability,
          WorkItemDescriptionAvailability.present,
        );
        expect(access.actorId, _actorId);
        expect(access.canUpdate, isTrue);
        expect(access.target, isNotNull);

        final request = adapter.requests.single;
        expect(request.uri, api.instance.graphQL);
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(_variables(request), {'id': _summary(group: group).id});
        expect(_query(request), startsWith('query MobileWorkItemContent'));
        expect(_query(request), contains('currentUser { id }'));
        expect(_query(request), contains('userPermissions { updateWorkItem }'));
        expect(_query(request), contains('widgets(onlyTypes: [DESCRIPTION])'));
        expect(_query(request), isNot(contains('lockVersion')));
      },
    );
  }

  test(
    'present null description is canonical empty while absent and unavailable stay distinct',
    () async {
      final fixtures = [
        _read(
          widgets: const [
            {
              'type': 'DESCRIPTION',
              'description': null,
              'edited': false,
              'lastEditedAt': null,
            },
          ],
        ),
        _read(widgets: const []),
        _read(widgets: null),
      ];
      var index = 0;
      final adapter = FakeAdapter((_) => jsonResponse(fixtures[index++]));
      final api = testApi(adapter);
      addTearDown(api.close);
      final present = await api.workItemContent(_detail(), expectedUserId: 7);
      final absent = await api.workItemContent(_detail(), expectedUserId: 7);
      final unavailable = await api.workItemContent(
        _detail(),
        expectedUserId: 7,
      );
      expect(present.snapshot.rawDescription, '');
      expect(
        present.snapshot.descriptionAvailability,
        WorkItemDescriptionAvailability.present,
      );
      expect(absent.snapshot.rawDescription, isNull);
      expect(
        absent.snapshot.descriptionAvailability,
        WorkItemDescriptionAvailability.absent,
      );
      expect(unavailable.snapshot.rawDescription, isNull);
      expect(
        unavailable.snapshot.descriptionAvailability,
        WorkItemDescriptionAvailability.widgetsUnavailable,
      );
    },
  );

  test(
    'permission denial remains readable without minting an update target',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(_read(permission: false)),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final access = await api.workItemContent(_detail(), expectedUserId: 7);
      expect(access.snapshot.summary.title, 'Fresh title');
      expect(access.canUpdate, isFalse);
      expect(access.target, isNull);
    },
  );

  test(
    'anonymous and mismatched actors cannot open an editor target',
    () async {
      for (final fixture in [
        _read(actor: null),
        _read(actor: const {'id': 'gid://gitlab/User/8'}),
      ]) {
        final adapter = FakeAdapter((_) => jsonResponse(fixture));
        final api = testApi(adapter);
        await expectLater(
          api.workItemContent(_detail(), expectedUserId: 7),
          throwsA(
            anyOf(
              _failure(FailureKind.unauthenticated),
              _failure(FailureKind.cancelled),
            ),
          ),
        );
        expect(adapter.requests.where(_mutation), isEmpty);
        api.close();
      }
    },
  );

  test(
    'invalid local account or identity is rejected before transport',
    () async {
      final invalidSummary = WorkItemGraphSummary(
        id: 'bad',
        iid: 31,
        title: 'title',
        state: 'OPEN',
        createdAt: _openedAt,
        updatedAt: _openedAt,
        project: _summary().project,
        namespace: _summary().namespace,
        type: _summary().type,
      );
      final invalid = WorkItemGraphDetail(
        summary: invalidSummary,
        description: null,
        widgetsAvailable: false,
        widgetTypes: const {},
        descriptionWidget: null,
        assignees: null,
        labels: null,
        hierarchy: null,
        dates: null,
      );
      final adapter = FakeAdapter((_) => fail('must reject before I/O'));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemContent(invalid, expectedUserId: 7),
        throwsA(_failure(FailureKind.validation)),
      );
      await expectLater(
        api.workItemContent(_detail(), expectedUserId: 0),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  final malformedReads = <String, Map<String, Object?>>{
    'missing actor key': {
      'data': {'workItem': _node()},
    },
    'wrong scope': _read(
      changes: const {
        'project': {
          'id': 'gid://gitlab/Project/99',
          'fullPath': 'other/project',
        },
      },
    ),
    'wrong type id': _read(
      changes: const {
        'workItemType': {
          'id': 'gid://gitlab/WorkItems::Type/10',
          'name': 'Task',
        },
      },
    ),
    'wrong type name': _read(
      changes: const {
        'workItemType': {
          'id': 'gid://gitlab/WorkItems::Type/9',
          'name': 'Incident',
        },
      },
    ),
    'missing permission': _read(permission: null),
    'unexpected filtered widget': _read(
      widgets: const [
        {'type': 'STATUS'},
      ],
    ),
    'duplicate description widget': _read(
      widgets: const [
        {
          'type': 'DESCRIPTION',
          'description': 'one',
          'edited': false,
          'lastEditedAt': null,
        },
        {
          'type': 'DESCRIPTION',
          'description': 'two',
          'edited': false,
          'lastEditedAt': null,
        },
      ],
    ),
  };
  for (final entry in malformedReads.entries) {
    test('${entry.key} is invalid and cannot mint a target', () async {
      final adapter = FakeAdapter((_) => jsonResponse(entry.value));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemContent(_detail(), expectedUserId: 7),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  test(
    'schema rejection is an explicit read-only unsupported result',
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
        api.workItemContent(_detail(), expectedUserId: 7),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  for (final group in [false, true]) {
    test(
      '${group ? 'group' : 'project'} title and description update preserves whitespace and confirms readback',
      () async {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) return jsonResponse(_ack(group: group));
          reads++;
          return jsonResponse(
            reads < 3
                ? _read(group: group)
                : _read(
                    group: group,
                    title: 'Changed title',
                    updatedAt: _savedAt,
                    widgets: const [
                      {
                        'type': 'DESCRIPTION',
                        'description': '  changed markdown  ',
                        'edited': true,
                        'lastEditedAt': '2026-10-03T10:00:00.000Z',
                      },
                    ],
                  ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api, group: group);
        final result = await api.updateWorkItemContent(
          target,
          title: 'Changed title',
          description: '  changed markdown  ',
        );
        expect(result.snapshot.summary.title, 'Changed title');
        expect(result.snapshot.rawDescription, '  changed markdown  ');
        expect(adapter.requests.where(_mutation), hasLength(1));
        final mutation = adapter.requests.singleWhere(_mutation);
        expect(
          _query(mutation),
          startsWith('mutation MobileUpdateWorkItemContent'),
        );
        expect(_query(mutation), isNot(contains('lockVersion')));
        expect(_variables(mutation), {
          'input': {
            'id': _summary(group: group).id,
            'title': 'Changed title',
            'descriptionWidget': {'description': '  changed markdown  '},
          },
        });
      },
    );
  }

  test(
    'title-only update is permitted when DESCRIPTION widget is absent',
    () async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          return jsonResponse(_ack(title: 'Title only', widgets: const []));
        }
        reads++;
        return jsonResponse(
          _read(
            title: reads < 3 ? 'Fresh title' : 'Title only',
            updatedAt: reads < 3 ? _freshAt : _savedAt,
            widgets: const [],
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final result = await api.updateWorkItemContent(
        target,
        title: 'Title only',
      );
      expect(result.snapshot.summary.title, 'Title only');
      expect(
        result.snapshot.descriptionAvailability,
        WorkItemDescriptionAvailability.absent,
      );
      final input =
          _variables(adapter.requests.singleWhere(_mutation))['input'] as Map;
      expect(input, {'id': _summary().id, 'title': 'Title only'});
      expect(input, isNot(contains('descriptionWidget')));
    },
  );

  test(
    'title change with unchanged Markdown omits description widget',
    () async {
      var reads = 0;
      final originalWidget = const [
        {
          'type': 'DESCRIPTION',
          'description': 'Original markdown',
          'edited': false,
          'lastEditedAt': null,
        },
      ];
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          return jsonResponse(
            _ack(title: 'Changed title', widgets: originalWidget),
          );
        }
        reads++;
        return jsonResponse(
          _read(
            title: reads < 3 ? 'Fresh title' : 'Changed title',
            updatedAt: reads < 3 ? _freshAt : _savedAt,
            widgets: originalWidget,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final result = await api.updateWorkItemContent(
        target,
        title: 'Changed title',
        description: 'Original markdown',
      );
      expect(result.snapshot.summary.title, 'Changed title');
      expect(result.snapshot.rawDescription, 'Original markdown');
      expect(_variables(adapter.requests.singleWhere(_mutation)), {
        'input': {'id': _summary().id, 'title': 'Changed title'},
      });
    },
  );

  test('Markdown change with unchanged title omits title input', () async {
    var reads = 0;
    final changedWidget = const [
      {
        'type': 'DESCRIPTION',
        'description': 'Changed markdown',
        'edited': true,
        'lastEditedAt': '2026-10-03T10:00:00.000Z',
      },
    ];
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) {
        return jsonResponse(_ack(title: 'Fresh title', widgets: changedWidget));
      }
      reads++;
      return jsonResponse(
        reads < 3
            ? _read()
            : _read(
                title: 'Fresh title',
                updatedAt: _savedAt,
                widgets: changedWidget,
              ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    final result = await api.updateWorkItemContent(
      target,
      title: 'Fresh title',
      description: 'Changed markdown',
    );
    expect(result.snapshot.summary.title, 'Fresh title');
    expect(result.snapshot.rawDescription, 'Changed markdown');
    expect(_variables(adapter.requests.singleWhere(_mutation)), {
      'input': {
        'id': _summary().id,
        'descriptionWidget': {'description': 'Changed markdown'},
      },
    });
  });

  test(
    'description update is refused when widget is absent and consumes target',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(_read(widgets: const [])),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemContent(
          target,
          title: 'Fresh title',
          description: 'new',
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
      await expectLater(
        api.updateWorkItemContent(target, title: 'Title only'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
    },
  );

  test('present null description supports canonical empty no-op', () async {
    final fixture = _read(
      widgets: const [
        {
          'type': 'DESCRIPTION',
          'description': null,
          'edited': false,
          'lastEditedAt': null,
        },
      ],
    );
    final adapter = FakeAdapter((_) => jsonResponse(fixture));
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    final result = await api.updateWorkItemContent(
      target,
      title: 'Fresh title',
      description: '',
    );
    expect(result.snapshot.rawDescription, '');
    expect(adapter.requests.where(_mutation), isEmpty);
  });

  test(
    'no-op consumes target after fresh exact permission preflight',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read()));
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final result = await api.updateWorkItemContent(
        target,
        title: 'Fresh title',
        description: 'Original markdown',
      );
      expect(result.snapshot.summary.title, 'Fresh title');
      expect(adapter.requests.where(_mutation), isEmpty);
      await expectLater(
        api.updateWorkItemContent(target, title: 'changed'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
    },
  );

  test('invalid input is rejected before consumption and transport', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_read()));
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    final requestCount = adapter.requests.length;
    for (final title in ['', '   ', 'bad\u0000title', 'x' * 256, '😀' * 256]) {
      await expectLater(
        api.updateWorkItemContent(target, title: title),
        throwsA(_failure(FailureKind.validation)),
      );
    }
    await expectLater(
      api.updateWorkItemContent(
        target,
        title: 'Fresh title',
        description: 'bad\u0000description',
      ),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests, hasLength(requestCount));
    final result = await api.updateWorkItemContent(
      target,
      title: 'Fresh title',
    );
    expect(result.snapshot.summary.title, 'Fresh title');
  });

  test(
    'pure content precheck matches title code points and description bounds',
    () {
      expect(isValidWorkItemContentInput(), isFalse);
      expect(isValidWorkItemContentInput(title: ''), isFalse);
      expect(isValidWorkItemContentInput(title: ' \t '), isFalse);
      expect(isValidWorkItemContentInput(title: 'x' * 255), isTrue);
      expect(isValidWorkItemContentInput(title: 'x' * 256), isFalse);
      expect(isValidWorkItemContentInput(title: '😀' * 255), isTrue);
      expect(isValidWorkItemContentInput(title: '😀' * 256), isFalse);
      expect(isValidWorkItemContentInput(title: 'e\u0301' * 128), isFalse);
      expect(isValidWorkItemContentInput(description: ''), isTrue);
      expect(
        isValidWorkItemContentInput(description: 'bad\u0000description'),
        isFalse,
      );
      expect(
        isValidWorkItemContentInput(description: 'x' * GitLabApi.maxTextBytes),
        isTrue,
      );
      expect(
        isValidWorkItemContentInput(
          description: 'x' * (GitLabApi.maxTextBytes + 1),
        ),
        isFalse,
      );
      expect(
        isValidWorkItemContentInput(
          description: '😀' * (GitLabApi.maxTextBytes ~/ 4 + 1),
        ),
        isFalse,
      );
      expect(
        isValidWorkItemContentInput(
          description: '\n' * (GitLabApi.maxTextLines - 1),
        ),
        isTrue,
      );
      expect(
        isValidWorkItemContentInput(description: '\n' * GitLabApi.maxTextLines),
        isFalse,
      );
    },
  );

  test(
    'expectedUpdatedAt remains a client-side fresh preflight comparison',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_read()));
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemContent(
          target,
          title: 'changed',
          expectedUpdatedAt: _openedAt,
        ),
        throwsA(_failure(FailureKind.conflict)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
      expect(adapter.requests, hasLength(2));
    },
  );

  final changedPreflight = <String, Map<String, Object?>>{
    'actor': _read(actor: const {'id': 'gid://gitlab/User/8'}),
    'revision': _read(updatedAt: _savedAt),
    'title': _read(title: 'Someone else changed title'),
    'scope': _read(
      changes: const {
        'project': {
          'id': 'gid://gitlab/Project/99',
          'fullPath': 'other/project',
        },
      },
    ),
    'type': _read(
      changes: const {
        'workItemType': {
          'id': 'gid://gitlab/WorkItems::Type/10',
          'name': 'Task',
        },
      },
    ),
    'widget availability': _read(widgets: const []),
    'markdown': _read(
      widgets: const [
        {
          'type': 'DESCRIPTION',
          'description': 'changed elsewhere',
          'edited': true,
          'lastEditedAt': '2026-10-03T10:00:00.000Z',
        },
      ],
    ),
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
        api.updateWorkItemContent(target, title: 'new'),
        throwsA(
          anyOf(
            _failure(FailureKind.cancelled),
            _failure(FailureKind.invalidResponse),
            _failure(FailureKind.conflict),
          ),
        ),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
      final count = adapter.requests.length;
      await expectLater(
        api.updateWorkItemContent(target, title: 'again'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests, hasLength(count));
    });
  }

  test(
    'revoked permission blocks mutation with a clear forbidden result',
    () async {
      var reads = 0;
      final adapter = FakeAdapter(
        (_) => jsonResponse(_read(permission: reads++ == 0 ? true : false)),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemContent(target, title: 'new'),
        throwsA(
          isA<ApiFailure>()
              .having((value) => value.kind, 'kind', FailureKind.forbidden)
              .having((value) => value.title, 'title', '無法編輯工作項目'),
        ),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    },
  );

  test('target is owner-bound and closed owner cannot preflight', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_read()));
    final api = testApi(adapter);
    final target = await _target(api);
    final otherAdapter = FakeAdapter((_) => fail('must reject before I/O'));
    final other = testApi(otherAdapter);
    addTearDown(other.close);
    await expectLater(
      other.updateWorkItemContent(target, title: 'new'),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(otherAdapter.requests, isEmpty);
    api.close();
    await expectLater(
      api.updateWorkItemContent(target, title: 'new'),
      throwsA(_failure(FailureKind.cancelled)),
    );
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
            title: 'Changed title',
            updatedAt: _savedAt,
            widgets: const [
              {
                'type': 'DESCRIPTION',
                'description': '  changed markdown  ',
                'edited': true,
                'lastEditedAt': '2026-10-03T10:00:00.000Z',
              },
            ],
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final first = api.updateWorkItemContent(
        target,
        title: 'Changed title',
        description: '  changed markdown  ',
      );
      await expectLater(
        api.updateWorkItemContent(target, title: 'again'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      preflight.complete(jsonResponse(_read()));
      await first;
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

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
      api.updateWorkItemContent(target, title: 'new', isCurrent: () => current),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests.where(_mutation), isEmpty);
  });

  test(
    'payload validation rejection is definitive and target is not replayable',
    () async {
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          return jsonResponse(
            _ack(errors: const ['Title is invalid'], workItem: null),
          );
        }
        return jsonResponse(_read());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemContent(target, title: 'new'),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
      await expectLater(
        api.updateWorkItemContent(target, title: 'again'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test(
    'definite mutation schema rejection is unsupported without replay',
    () async {
      final adapter = FakeAdapter((request) {
        if (!_mutation(request)) return jsonResponse(_read());
        return jsonResponse({
          'errors': [
            {
              'message': 'Unknown input field descriptionWidget',
              'extensions': {'code': 'argumentLiteralsIncompatible'},
            },
          ],
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemContent(target, title: 'new'),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test(
    'malformed acknowledgement and mismatched readback are write uncertain',
    () async {
      for (final malformedAck in [true, false]) {
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            return jsonResponse(
              malformedAck
                  ? _ack(workItem: null)
                  : _ack(title: 'Changed title'),
            );
          }
          reads++;
          return jsonResponse(
            reads < 3
                ? _read()
                : _read(
                    title: malformedAck ? 'Changed title' : 'Wrong readback',
                    updatedAt: _savedAt,
                  ),
          );
        });
        final api = testApi(adapter);
        final target = await _target(api);
        await expectLater(
          api.updateWorkItemContent(target, title: 'Changed title'),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests.where(_mutation), hasLength(1));
        api.close();
      }
    },
  );

  test('network failure after send is uncertain and never replayed', () async {
    final adapter = FakeAdapter((request) {
      if (!_mutation(request)) return jsonResponse(_read());
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.receiveTimeout,
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    await expectLater(
      api.updateWorkItemContent(target, title: 'new'),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
    await expectLater(
      api.updateWorkItemContent(target, title: 'again'),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  test(
    'account generation change after send is uncertain and cannot replay',
    () async {
      var current = true;
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          current = false;
          return jsonResponse(_ack(title: 'Changed title'));
        }
        reads++;
        return jsonResponse(_read());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.updateWorkItemContent(
          target,
          title: 'Changed title',
          isCurrent: () => current,
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(reads, 2);
      expect(adapter.requests.where(_mutation), hasLength(1));
      await expectLater(
        api.updateWorkItemContent(target, title: 'again'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );
}
