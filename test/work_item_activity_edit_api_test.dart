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
const _originalBody = 'Original **Markdown**  \n\n';
const _replacement = '  Edited **Markdown**  \n\n';
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
  String body = _originalBody,
  bool deletedAuthor = false,
}) => WorkItemActivityNote(
  id: id,
  system: system,
  systemNoteIconName: null,
  body: body,
  createdAt: _createdAt,
  updatedAt: _updatedAt,
  author: deletedAuthor
      ? null
      : const WorkItemActivityAuthor(
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
  bool edited = false,
  bool deletedAuthor = false,
  Map<String, Object?> changes = const {},
}) => {
  'id': _noteId,
  'system': false,
  'systemNoteIconName': null,
  'body': edited ? _replacement : _originalBody,
  'createdAt': _createdAt.toIso8601String(),
  'updatedAt':
      (edited ? _updatedAt.add(const Duration(seconds: 1)) : _updatedAt)
          .toIso8601String(),
  'author': deletedAuthor
      ? null
      : {
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
  Map<String, Object?> changes = const {},
  bool deletedAuthor = false,
}) => {
  'data': {
    'currentUser': actor,
    'workItem': _identity(_summary(group: group)),
    'note': _note(group: group, deletedAuthor: deletedAuthor, changes: changes),
  },
};

Map<String, Object?> _ack({
  bool group = false,
  bool deletedAuthor = false,
  Map<String, Object?> changes = const {},
}) => {
  'data': {
    'updateNote': {
      'errors': <Object?>[],
      'note': _note(
        group: group,
        edited: true,
        deletedAuthor: deletedAuthor,
        changes: changes,
      ),
    },
  },
};

Map<String, Object?> _readback({
  bool group = false,
  bool deletedAuthor = false,
  Map<String, Object?> changes = const {},
}) => {
  'data': {
    'workItem': _identity(_summary(group: group)),
    'note': _note(
      group: group,
      edited: true,
      deletedAuthor: deletedAuthor,
      changes: changes,
    ),
  },
};

String _query(RequestOptions request) =>
    (request.data as Map)['query'] as String;
bool _mutation(RequestOptions request) =>
    _query(request).startsWith('mutation ');
Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

Future<WorkItemActivityEditTarget> _target(
  GitLabApi api, {
  bool group = false,
  bool deletedAuthor = false,
}) async => (await api.workItemActivityEditAccess(
  _summary(group: group),
  _discussion(),
  _displayedNote(deletedAuthor: deletedAuthor),
)).target!;

void main() {
  for (final group in [false, true]) {
    test('${group ? 'group' : 'project'} edit preserves Markdown and verifies '
        'exact note without assuming author permission', () async {
      final adapter = FakeAdapter((request) {
        expect(request.followRedirects, isFalse);
        expect(request.uri.path, '/gitlab/api/graphql');
        final query = _query(request);
        final variables = (request.data as Map)['variables'];
        if (query.startsWith('query MobileWorkItemActivityEditAccess')) {
          expect(query, contains('adminNote'));
          expect(query, isNot(contains('createNote')));
          expect(query, isNot(contains('discussionLocked')));
          expect(variables, {
            'workItemId': _summary(group: group).id,
            'noteId': _noteId,
          });
          return jsonResponse(_access(group: group));
        }
        if (_mutation(request)) {
          expect(
            query,
            startsWith('mutation MobileUpdateWorkItemActivityNote'),
          );
          expect(variables, {
            'input': {'id': _noteId, 'body': _replacement},
          });
          return jsonResponse(_ack(group: group));
        }
        expect(query, startsWith('query MobileWorkItemActivityNoteReadback'));
        expect(variables, {
          'workItemId': _summary(group: group).id,
          'noteId': _noteId,
        });
        return jsonResponse(_readback(group: group));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api, group: group);
      expect(target.note.body, _originalBody);
      final edited = await api.editWorkItemActivityNote(target, _replacement);
      expect(edited.body, _replacement);
      expect(edited.author!.id, _authorId);
      expect(edited.updatedAt, _updatedAt.add(const Duration(seconds: 1)));
      expect(adapter.requests, hasLength(4));
      expect(adapter.requests.where(_mutation), hasLength(1));
      await expectLater(
        api.editWorkItemActivityNote(target, 'Repeat'),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(adapter.requests, hasLength(4));
    });
  }

  test(
    'deleted author remains editable when current actor has adminNote',
    () async {
      final adapter = FakeAdapter(
        (request) => jsonResponse(
          _mutation(request)
              ? _ack(deletedAuthor: true)
              : _query(request).contains('EditAccess')
              ? _access(deletedAuthor: true)
              : _readback(deletedAuthor: true),
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api, deletedAuthor: true);
      expect(
        (await api.editWorkItemActivityNote(target, _replacement)).author,
        isNull,
      );
    },
  );

  final denied = <String, Map<String, Object?>>{
    'same author without permission': _access(
      actor: const {'id': _authorId},
      changes: const {
        'userPermissions': {'adminNote': false},
      },
    ),
    'anonymous with permission': _access(actor: null),
    'internal note with permission': _access(changes: const {'internal': true}),
  };
  for (final entry in denied.entries) {
    test('${entry.key} cannot mint an edit target', () async {
      final adapter = FakeAdapter((_) => jsonResponse(entry.value));
      final api = testApi(adapter);
      addTearDown(api.close);
      final access = await api.workItemActivityEditAccess(
        _summary(),
        _discussion(),
        _displayedNote(),
      );
      expect(access.canEditNote, isFalse);
      expect(access.target, isNull);
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  for (final note in [
    _displayedNote(system: true),
    _displayedNote(id: 'gid://gitlab/Issue/401'),
    _displayedNote(id: 'gid://gitlab/Note/0'),
    _displayedNote(id: 'gid://gitlab/Note/401/other'),
  ]) {
    test(
      'invalid edit target ${note.id}, system=${note.system} makes no request',
      () async {
        final adapter = FakeAdapter(
          (_) => throw StateError('Unexpected request'),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          api.workItemActivityEditAccess(_summary(), _discussion(), note),
          throwsA(_failure(FailureKind.validation)),
        );
        expect(adapter.requests, isEmpty);
      },
    );
  }

  final malformed = <String, Map<String, Object?>>{
    'permission missing': {'userPermissions': <String, Object?>{}},
    'permission malformed': {
      'userPermissions': {'adminNote': 'true'},
    },
    'internal missing': {'internal': null},
    'foreign note': {'id': 'gid://gitlab/Note/402'},
    'wrong noteable type': {'noteableType': 'MergeRequest'},
    'foreign noteable': {'noteableId': 32},
    'foreign project': {
      'project': {'id': 'gid://gitlab/Project/43', 'fullPath': 'team/other'},
    },
    'foreign discussion': {
      'discussion': {
        'id': 'gid://gitlab/Discussion/other',
        'createdAt': _discussionCreatedAt.toIso8601String(),
      },
    },
    'changed discussion creation': {
      'discussion': {'id': _discussionId, 'createdAt': '2026-10-02T01:00:00Z'},
    },
  };
  for (final entry in malformed.entries) {
    test('${entry.key} fails closed before minting a target', () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(_access(changes: entry.value)),
      );
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
    {'body': 'Someone else edited this'},
    {'updatedAt': '2026-10-01T01:03:05Z'},
    {'createdAt': '2026-10-01T01:02:04Z'},
    {
      'author': {'id': _actorId, 'name': 'Other', 'username': 'other'},
    },
    {'system': true},
  ]) {
    test('displayed revision mismatch $changes requires refresh', () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(_access(changes: changes)),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(_target(api), throwsA(_failure(FailureKind.conflict)));
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  test('missing edit schema fails only the optional access lookup', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'errors': [
          {
            'message': 'Synthetic unsupported field',
            'extensions': {'code': 'undefinedField'},
          },
        ],
      }),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(_target(api), throwsA(_failure(FailureKind.unsupported)));
    expect(adapter.requests, hasLength(1));
  });

  final changedPreflight = <String, (Map<String, Object?>, FailureKind)>{
    'permission revoked': (
      _access(
        changes: const {
          'userPermissions': {'adminNote': false},
        },
      ),
      FailureKind.forbidden,
    ),
    'actor changed': (
      _access(actor: const {'id': 'gid://gitlab/User/8'}),
      FailureKind.cancelled,
    ),
    'note edited since opening': (
      _access(changes: const {'body': 'New concurrent edit'}),
      FailureKind.conflict,
    ),
    'revision changed since opening': (
      _access(changes: const {'updatedAt': '2026-10-01T01:03:05Z'}),
      FailureKind.conflict,
    ),
  };
  for (final entry in changedPreflight.entries) {
    test('${entry.key} is detected before updateNote', () async {
      var reads = 0;
      final adapter = FakeAdapter(
        (_) => jsonResponse(++reads == 1 ? _access() : entry.value.$1),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      await expectLater(
        api.editWorkItemActivityNote(target, _replacement),
        throwsA(_failure(entry.value.$2)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    });
  }

  test(
    'unchanged save still checks permission and consumes capability without a mutation',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_access()));
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      expect(
        (await api.editWorkItemActivityNote(target, _originalBody)).body,
        _originalBody,
      );
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.where(_mutation), isEmpty);
      await expectLater(
        api.editWorkItemActivityNote(target, _replacement),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
    },
  );

  test(
    'concurrent saves use one attempt after asynchronous preflight',
    () async {
      final secondRead = Completer<ResponseBody>();
      final thirdRead = Completer<ResponseBody>();
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (_mutation(request)) return jsonResponse(_ack());
        if (_query(request).contains('NoteReadback')) {
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
      final first = api.editWorkItemActivityNote(target, _replacement);
      final second = api.editWorkItemActivityNote(target, _replacement);
      final secondExpectation = expectLater(
        second,
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      secondRead.complete(jsonResponse(_access()));
      expect((await first).body, _replacement);
      thirdRead.complete(jsonResponse(_access()));
      await secondExpectation;
      expect(adapter.requests.where(_mutation), hasLength(1));
    },
  );

  test('target is bound to the API owner and its lifetime', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_access()));
    final api = testApi(adapter);
    final otherAdapter = FakeAdapter(
      (_) => throw StateError('Unexpected request'),
    );
    final other = testApi(otherAdapter);
    addTearDown(other.close);
    final target = await _target(api);
    await expectLater(
      other.editWorkItemActivityNote(target, _replacement),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(otherAdapter.requests, isEmpty);
    api.close();
    await expectLater(
      api.editWorkItemActivityNote(target, _replacement),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests, hasLength(1));
  });

  test(
    'owner generation invalidation during preflight prevents mutation',
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
        api.editWorkItemActivityNote(
          target,
          _replacement,
          isCurrent: () => current,
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(adapter.requests.where(_mutation), isEmpty);
    },
  );

  for (final stage in ['ack', 'readback']) {
    test(
      'owner invalidation after $stage leaves write uncertain and cannot replay',
      () async {
        var current = true;
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            if (stage == 'ack') current = false;
            return jsonResponse(_ack());
          }
          if (_query(request).contains('NoteReadback')) {
            current = false;
            return jsonResponse(_readback());
          }
          return jsonResponse(_access());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.editWorkItemActivityNote(
            target,
            _replacement,
            isCurrent: () => current,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        await expectLater(
          api.editWorkItemActivityNote(target, _replacement),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests.where(_mutation), hasLength(1));
      },
    );
  }

  final unconfirmed = <String, Map<String, Object?>>{
    'wrong id': {'id': 'gid://gitlab/Note/402'},
    'wrong body': {'body': 'Unexpected server text'},
    'wrong scope': {'noteableId': 32},
    'internal': {'internal': true},
    'system': {'system': true},
    'changed author': {
      'author': {'id': _actorId, 'name': 'Other', 'username': 'other'},
    },
    'changed creation': {'createdAt': '2026-10-01T01:02:04Z'},
    'older update': {'updatedAt': '2026-10-01T01:03:03Z'},
    'wrong discussion': {
      'discussion': {
        'id': 'gid://gitlab/Discussion/other',
        'createdAt': _discussionCreatedAt.toIso8601String(),
      },
    },
  };
  for (final stage in ['ack', 'readback']) {
    for (final entry in unconfirmed.entries) {
      test(
        '$stage ${entry.key} is uncertain with no automatic replay',
        () async {
          final adapter = FakeAdapter((request) {
            if (_mutation(request)) {
              return jsonResponse(
                _ack(changes: stage == 'ack' ? entry.value : const {}),
              );
            }
            if (_query(request).contains('NoteReadback')) {
              return jsonResponse(_readback(changes: entry.value));
            }
            return jsonResponse(_access());
          });
          final api = testApi(adapter);
          addTearDown(api.close);
          final target = await _target(api);
          await expectLater(
            api.editWorkItemActivityNote(target, _replacement),
            throwsA(_failure(FailureKind.writeUncertain)),
          );
          final requestCount = adapter.requests.length;
          await expectLater(
            api.editWorkItemActivityNote(target, _replacement),
            throwsA(_failure(FailureKind.writeUncertain)),
          );
          expect(adapter.requests, hasLength(requestCount));
          expect(adapter.requests.where(_mutation), hasLength(1));
        },
      );
    }
  }

  test(
    'same readback body with different update timestamp is still uncertain',
    () async {
      final adapter = FakeAdapter(
        (request) => jsonResponse(
          _mutation(request)
              ? _ack()
              : _query(request).contains('NoteReadback')
              ? _readback(changes: const {'updatedAt': '2026-10-01T01:03:06Z'})
              : _access(),
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.editWorkItemActivityNote(await _target(api), _replacement),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
    },
  );

  for (final stage in [
    'mutation timeout',
    'readback timeout',
    'payload errors',
    'schema errors',
    'missing ack',
  ]) {
    test(
      '$stage preserves uncertain attempt rather than retrying a mutation',
      () async {
        final adapter = FakeAdapter((request) {
          if (_mutation(request)) {
            if (stage == 'mutation timeout') {
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.receiveTimeout,
              );
            }
            if (stage == 'payload errors') {
              return jsonResponse({
                'data': {
                  'updateNote': {
                    'errors': ['Synthetic refusal'],
                    'note': null,
                  },
                },
              });
            }
            if (stage == 'schema errors') {
              return jsonResponse({
                'errors': [
                  {
                    'message': 'Synthetic schema failure',
                    'extensions': {'code': 'undefinedField'},
                  },
                ],
              });
            }
            if (stage == 'missing ack') {
              return jsonResponse({
                'data': {'updateNote': null},
              });
            }
            return jsonResponse(_ack());
          }
          if (_query(request).contains('NoteReadback')) {
            throw DioException(
              requestOptions: request,
              type: DioExceptionType.receiveTimeout,
            );
          }
          return jsonResponse(_access());
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.editWorkItemActivityNote(target, _replacement),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        await expectLater(
          api.editWorkItemActivityNote(target, _replacement),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests.where(_mutation), hasLength(1));
      },
    );
  }

  for (final body in [
    '',
    '  \n',
    'Text\u0000',
    '/close',
    'Text\n/assign @someone',
    ' /close',
    'x' * (2 * 1024 * 1024 + 1),
    'x\n' * GitLabApi.maxTextLines,
  ]) {
    test(
      'invalid ordinary Markdown input is rejected before edit preflight',
      () async {
        expect(isValidWorkItemActivityEditBody(body), isFalse);
        final adapter = FakeAdapter((_) => jsonResponse(_access()));
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = await _target(api);
        await expectLater(
          api.editWorkItemActivityNote(target, body),
          throwsA(_failure(FailureKind.validation)),
        );
        expect(adapter.requests, hasLength(1));
      },
    );
  }

  test('pure note edit precheck accepts the exact byte and line bounds', () {
    expect(isValidWorkItemActivityEditBody('é' * (1024 * 1024)), isTrue);
    expect(isValidWorkItemActivityEditBody('é' * (1024 * 1024 + 1)), isFalse);
    expect(
      isValidWorkItemActivityEditBody(
        '${'x\n' * (GitLabApi.maxTextLines - 1)}x',
      ),
      isTrue,
    );
    expect(isValidWorkItemActivityEditBody('    /close'), isTrue);
    expect(isValidWorkItemActivityEditBody('```\n/close\n```'), isTrue);
  });
}
