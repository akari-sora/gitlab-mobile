import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';

const _noteId = 'gid://gitlab/Note/401';
const _discussionId = 'gid://gitlab/Discussion/synthetic-discussion';
const _actorId = 'gid://gitlab/User/7';
const _authorId = 'gid://gitlab/User/9';
const _body = 'Delete **this** note';
final _createdAt = DateTime.utc(2026, 10, 1, 1, 2, 3);
final _updatedAt = DateTime.utc(2026, 10, 1, 1, 3, 4);
final _discussionCreatedAt = DateTime.utc(2026, 10, 1, 1);

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
    id: 'gid://gitlab/WorkItems::Type/synthetic-type',
    name: 'Task',
  ),
);

WorkItemActivityNote _displayedNote({
  String id = _noteId,
  bool system = false,
  String body = _body,
}) => WorkItemActivityNote(
  id: id,
  system: system,
  systemNoteIconName: null,
  body: body,
  createdAt: _createdAt,
  updatedAt: _updatedAt,
  author: const WorkItemActivityAuthor(
    id: _authorId,
    name: 'Synthetic author',
    username: 'synthetic-author',
  ),
);

WorkItemActivityDiscussion _discussion({String id = _discussionId}) =>
    WorkItemActivityDiscussion(
      id: id,
      replyId: 'gid://gitlab/IndividualNoteDiscussion/synthetic-discussion',
      createdAt: _discussionCreatedAt,
      notes: WorkItemActivityConnection(
        availability: WorkItemActivityConnectionAvailability.present,
        items: [_displayedNote()],
      ),
    );

Map<String, Object?> _identity(WorkItemGraphSummary value) => {
  'id': value.id,
  'iid': '${value.iid}',
  'project': value.project == null
      ? null
      : {'id': value.project!.id, 'fullPath': value.project!.fullPath},
  'namespace': {
    'id': value.namespace!.id,
    'fullPath': value.namespace!.fullPath,
  },
};

Map<String, Object?> _note({
  bool group = false,
  Map<String, Object?> changes = const {},
}) => {
  'id': _noteId,
  'system': false,
  'systemNoteIconName': null,
  'body': _body,
  'createdAt': _createdAt.toIso8601String(),
  'updatedAt': _updatedAt.toIso8601String(),
  'author': {
    'id': _authorId,
    'name': 'Synthetic author',
    'username': 'synthetic-author',
  },
  'internal': false,
  'noteableType': 'Issue',
  'noteableId': group ? 41 : 31,
  'project': group
      ? null
      : {'id': 'gid://gitlab/Project/42', 'fullPath': 'team/example-42'},
  'discussion': {
    'id': _discussionId,
    'createdAt': _discussionCreatedAt.toIso8601String(),
  },
  'userPermissions': {'adminNote': true},
  ...changes,
};

Map<String, Object?> _access({
  bool group = false,
  Object? actor = const {'id': _actorId},
  Map<String, Object?> workItemChanges = const {},
  Map<String, Object?> noteChanges = const {},
}) => {
  'data': {
    'currentUser': actor,
    'workItem': {..._identity(_summary(group: group)), ...workItemChanges},
    'note': _note(group: group, changes: noteChanges),
  },
};

Map<String, Object?> _ack({Object? errors = const <Object?>[]}) => {
  'data': {
    'destroyNote': {'errors': errors},
  },
};

Map<String, Object?> _readback({
  bool group = false,
  Object? actor = const {'id': _actorId},
  Object? workItem = _sentinel,
  Object? note,
  bool includeNote = true,
}) {
  final data = <String, Object?>{
    'currentUser': actor,
    'workItem': identical(workItem, _sentinel)
        ? _identity(_summary(group: group))
        : workItem,
  };
  if (includeNote) data['note'] = note;
  return {'data': data};
}

const _sentinel = Object();

String _query(RequestOptions request) =>
    (request.data as Map)['query'] as String;
bool _mutation(RequestOptions request) =>
    _query(request).startsWith('mutation ');
Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

Future<WorkItemActivityDeleteTarget> _target(
  GitLabApi api, {
  bool group = false,
}) async => (await api.workItemActivityDeleteAccess(
  _summary(group: group),
  _discussion(),
  _displayedNote(),
)).target!;

void main() {
  for (final group in [false, true]) {
    test('${group ? 'group' : 'project'} delete sends the exact opaque note ID '
        'and independently confirms absence', () async {
      final adapter = FakeAdapter((request) {
        expect(request.followRedirects, isFalse);
        expect(request.uri.path, '/gitlab/api/graphql');
        final query = _query(request);
        final variables = (request.data as Map)['variables'];
        if (query.startsWith('query MobileWorkItemActivityEditAccess')) {
          expect(query, contains('adminNote'));
          expect(variables, {
            'workItemId': _summary(group: group).id,
            'noteId': _noteId,
          });
          return jsonResponse(_access(group: group));
        }
        if (_mutation(request)) {
          expect(
            query,
            startsWith('mutation MobileDestroyWorkItemActivityNote'),
          );
          expect(query, isNot(contains('body')));
          expect(variables, {
            'input': {'id': _noteId},
          });
          return jsonResponse(_ack());
        }
        expect(query, startsWith('query MobileWorkItemActivityDeleteReadback'));
        expect(query, contains('currentUser { id }'));
        expect(variables, {
          'workItemId': _summary(group: group).id,
          'noteId': _noteId,
        });
        return jsonResponse(_readback(group: group));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api, group: group);
      expect(target.note.id, _noteId);
      await api.deleteWorkItemActivityNote(target);
      expect(adapter.requests, hasLength(4));
      expect(adapter.requests.where(_mutation), hasLength(1));
      await expectLater(
        api.deleteWorkItemActivityNote(target),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests, hasLength(4));
    });
  }

  final denied = <String, Map<String, Object?>>{
    'server denies adminNote': _access(
      noteChanges: const {
        'userPermissions': {'adminNote': false},
      },
    ),
    'anonymous actor': _access(actor: null),
    'internal note': _access(noteChanges: const {'internal': true}),
  };
  for (final entry in denied.entries) {
    test('${entry.key} cannot mint a delete target', () async {
      final adapter = FakeAdapter((_) => jsonResponse(entry.value));
      final api = testApi(adapter);
      addTearDown(api.close);
      final access = await api.workItemActivityDeleteAccess(
        _summary(),
        _discussion(),
        _displayedNote(),
      );
      expect(access.canDeleteNote, isFalse);
      expect(access.target, isNull);
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  for (final value in <(WorkItemActivityDiscussion, WorkItemActivityNote)>[
    (_discussion(), _displayedNote(system: true)),
    (_discussion(), _displayedNote(id: 'gid://gitlab/Issue/401')),
    (_discussion(), _displayedNote(id: 'gid://gitlab/Note/0')),
    (_discussion(), _displayedNote(id: 'gid://gitlab/Note/401/other')),
    (_discussion(id: 'gid://gitlab/Issue/1'), _displayedNote()),
  ]) {
    test('invalid local delete identity makes no request', () async {
      final adapter = FakeAdapter((_) => fail('must reject before I/O'));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.workItemActivityDeleteAccess(_summary(), value.$1, value.$2),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests, isEmpty);
    });
  }

  final malformedAccess = <String, Map<String, Object?>>{
    'missing permission': _access(
      noteChanges: const {'userPermissions': <String, Object?>{}},
    ),
    'malformed permission': _access(
      noteChanges: const {
        'userPermissions': {'adminNote': 'true'},
      },
    ),
    'wrong work item id': _access(
      workItemChanges: const {'id': 'gid://gitlab/WorkItem/32'},
    ),
    'wrong iid': _access(workItemChanges: const {'iid': '8'}),
    'wrong namespace': _access(
      workItemChanges: const {
        'namespace': {
          'id': 'gid://gitlab/Namespaces::ProjectNamespace/43',
          'fullPath': 'team/other',
        },
      },
    ),
    'wrong note id': _access(
      noteChanges: const {'id': 'gid://gitlab/Note/402'},
    ),
    'wrong noteable': _access(noteChanges: const {'noteableId': 32}),
    'wrong project': _access(
      noteChanges: const {
        'project': {'id': 'gid://gitlab/Project/43', 'fullPath': 'team/other'},
      },
    ),
    'wrong discussion': _access(
      noteChanges: {
        'discussion': {
          'id': 'gid://gitlab/Discussion/other',
          'createdAt': _discussionCreatedAt.toIso8601String(),
        },
      },
    ),
  };
  for (final entry in malformedAccess.entries) {
    test('${entry.key} fails closed before minting delete target', () async {
      final adapter = FakeAdapter((_) => jsonResponse(entry.value));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        _target(api),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  for (final changes in [
    {'body': 'A concurrent edit'},
    {'updatedAt': '2026-10-01T01:03:05Z'},
    {'createdAt': '2026-10-01T01:02:04Z'},
    {
      'author': {'id': _actorId, 'name': 'Other', 'username': 'other'},
    },
    {'system': true},
  ]) {
    test('displayed revision mismatch $changes requires refresh', () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(_access(noteChanges: changes)),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(_target(api), throwsA(_failure(FailureKind.conflict)));
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  final changedPreflight = <String, (Map<String, Object?>, FailureKind)>{
    'permission revoked': (
      _access(
        noteChanges: const {
          'userPermissions': {'adminNote': false},
        },
      ),
      FailureKind.forbidden,
    ),
    'actor changed': (
      _access(actor: const {'id': 'gid://gitlab/User/8'}),
      FailureKind.cancelled,
    ),
    'note became internal': (
      _access(noteChanges: const {'internal': true}),
      FailureKind.forbidden,
    ),
    'body changed': (
      _access(noteChanges: const {'body': 'Concurrent edit'}),
      FailureKind.conflict,
    ),
    'revision changed': (
      _access(noteChanges: const {'updatedAt': '2026-10-01T01:03:05Z'}),
      FailureKind.conflict,
    ),
  };
  for (final entry in changedPreflight.entries) {
    test('${entry.key} is detected before destroyNote', () async {
      var reads = 0;
      final adapter = FakeAdapter(
        (_) => jsonResponse(++reads == 1 ? _access() : entry.value.$1),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.deleteWorkItemActivityNote(target),
        throwsA(_failure(entry.value.$2)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  test('target is API-owner-bound and closed owners cannot send', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_access()));
    final api = testApi(adapter);
    final otherAdapter = FakeAdapter((_) => fail('must reject before I/O'));
    final other = testApi(otherAdapter);
    addTearDown(other.close);
    final target = await _target(api);
    await expectLater(
      other.deleteWorkItemActivityNote(target),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(otherAdapter.requests, isEmpty);
    api.close();
    await expectLater(
      api.deleteWorkItemActivityNote(target),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests, hasLength(1));
  });

  test(
    'owner generation invalidation during preflight prevents deletion',
    () async {
      var current = true;
      var reads = 0;
      final adapter = FakeAdapter((_) {
        if (++reads == 2) current = false;
        return jsonResponse(_access());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.deleteWorkItemActivityNote(target, isCurrent: () => current),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    },
  );

  test('concurrent deletes consume one target and send once', () async {
    final secondRead = Completer<ResponseBody>();
    final thirdRead = Completer<ResponseBody>();
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (_mutation(request)) return jsonResponse(_ack());
      if (_query(request).contains('DeleteReadback')) {
        return jsonResponse(_readback());
      }
      return switch (++reads) {
        1 => jsonResponse(_access()),
        2 => secondRead.future,
        _ => thirdRead.future,
      };
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);
    final first = api.deleteWorkItemActivityNote(target);
    final second = api.deleteWorkItemActivityNote(target);
    final secondExpectation = expectLater(
      second,
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    secondRead.complete(jsonResponse(_access()));
    await first;
    thirdRead.complete(jsonResponse(_access()));
    await secondExpectation;
    expect(adapter.requests.where(_mutation), hasLength(1));
  });

  final badReadbacks = <String, Map<String, Object?>>{
    'actor absent': _readback(actor: null),
    'actor changed': _readback(actor: const {'id': 'gid://gitlab/User/8'}),
    'actor malformed': _readback(actor: const {'id': 'User/7'}),
    'parent absent': _readback(workItem: null),
    'parent changed': _readback(
      workItem: {..._identity(_summary()), 'iid': '8'},
    ),
    'note key absent': _readback(includeNote: false),
    'note still present': _readback(note: _note()),
    'GraphQL error': {
      'errors': [
        {
          'message': 'Synthetic denial',
          'extensions': {'code': 'authorization'},
        },
      ],
    },
  };
  for (final entry in badReadbacks.entries) {
    test(
      '${entry.key} after acknowledgement is uncertain and cannot replay',
      () async {
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) return jsonResponse(_ack());
          if (_query(request).contains('DeleteReadback')) {
            return jsonResponse(entry.value);
          }
          return jsonResponse(_access());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.deleteWorkItemActivityNote(target),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        final count = adapter.requests.length;
        await expectLater(
          api.deleteWorkItemActivityNote(target),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests, hasLength(count));
        expect(adapter.requests.where(_mutation), hasLength(1));
      },
    );
  }

  for (final stage in [
    'mutation timeout',
    'payload errors',
    'malformed errors',
    'missing payload',
    'mutation schema error',
    'readback timeout',
  ]) {
    test('$stage is uncertain after one send and cannot replay', () async {
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          if (stage == 'mutation timeout') {
            throw DioException(
              requestOptions: request,
              type: DioExceptionType.receiveTimeout,
            );
          }
          if (stage == 'payload errors') {
            return jsonResponse(_ack(errors: const ['Synthetic refusal']));
          }
          if (stage == 'malformed errors') {
            return jsonResponse(_ack(errors: 'none'));
          }
          if (stage == 'missing payload') {
            return jsonResponse({
              'data': {'destroyNote': null},
            });
          }
          if (stage == 'mutation schema error') {
            return jsonResponse({
              'errors': [
                {
                  'message': 'Synthetic schema failure',
                  'extensions': {'code': 'undefinedField'},
                },
              ],
            });
          }
          return jsonResponse(_ack());
        }
        if (_query(request).contains('DeleteReadback') &&
            stage == 'readback timeout') {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        }
        return _query(request).contains('DeleteReadback')
            ? jsonResponse(_readback())
            : jsonResponse(_access());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.deleteWorkItemActivityNote(target),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      final count = adapter.requests.length;
      await expectLater(
        api.deleteWorkItemActivityNote(target),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests, hasLength(count));
      expect(adapter.requests.where(_mutation), hasLength(1));
    });
  }

  for (final stage in ['after acknowledgement', 'during readback']) {
    test('owner invalidation $stage is uncertain and cannot replay', () async {
      var current = true;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) {
          if (stage == 'after acknowledgement') current = false;
          return jsonResponse(_ack());
        }
        if (_query(request).contains('DeleteReadback')) {
          current = false;
          return jsonResponse(_readback());
        }
        return jsonResponse(_access());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.deleteWorkItemActivityNote(target, isCurrent: () => current),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      await expectLater(
        api.deleteWorkItemActivityNote(target),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests.where(_mutation), hasLength(1));
    });
  }
}
