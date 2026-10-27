import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';
import 'support/strict_group_owner.dart';

const _workItemId = 'gid://gitlab/WorkItem/31';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/42';
const _path = 'team/example-42';
const _discussionId = 'gid://gitlab/Discussion/server-owned';
const _replyId = 'gid://gitlab/IndividualNoteDiscussion/server-owned';
const _noteId = 'gid://gitlab/Note/401';
const _actorId = 'gid://gitlab/User/9';
const _otherActorId = 'gid://gitlab/User/10';

final _expected = WorkItemGraphSummary(
  id: _workItemId,
  iid: 7,
  title: 'Synthetic work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  project: const GraphResourceRef(id: _projectId, fullPath: _path),
  namespace: const GraphResourceRef(id: _namespaceId, fullPath: _path),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/server-owned',
    name: 'Task',
  ),
);

final _groupExpected = WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/41',
  iid: 8,
  title: 'Synthetic group work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  project: null,
  namespace: const GraphResourceRef(
    id: 'gid://gitlab/Group/7',
    fullPath: 'team',
  ),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/group-owned',
    name: 'Epic',
  ),
);

final _displayedNote = WorkItemActivityNote(
  id: _noteId,
  system: false,
  systemNoteIconName: null,
  body: 'Synthetic note',
  createdAt: DateTime.parse('2026-10-01T01:02:03Z'),
  updatedAt: DateTime.parse('2026-10-01T01:03:04Z'),
  author: const WorkItemActivityAuthor(
    id: _actorId,
    name: 'Synthetic User',
    username: 'synthetic-user',
  ),
);

final _discussion = WorkItemActivityDiscussion(
  id: _discussionId,
  replyId: _replyId,
  createdAt: DateTime.parse('2026-10-01T01:00:00Z'),
  notes: WorkItemActivityConnection(
    availability: WorkItemActivityConnectionAvailability.present,
    items: [_displayedNote],
  ),
);

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _identity(WorkItemGraphSummary expected) => {
  'id': expected.id,
  'iid': '${expected.iid}',
  'project': expected.project == null
      ? null
      : {'id': expected.project!.id, 'fullPath': expected.project!.fullPath},
  'namespace': expected.namespace == null
      ? null
      : {
          'id': expected.namespace!.id,
          'fullPath': expected.namespace!.fullPath,
        },
};

Map<String, Object?> _reaction(
  String name, {
  String actorId = _actorId,
  String? unicode = '👍',
}) => {
  'name': name,
  'unicode': unicode,
  'user': {'id': actorId},
};

Map<String, Object?> _note({
  WorkItemGraphSummary? expected,
  String id = _noteId,
  String body = 'Synthetic note',
  String updatedAt = '2026-10-01T01:03:04Z',
  String authorId = _actorId,
  bool system = false,
  bool internal = false,
  bool canAward = true,
  Object? awards = const <Object?>[],
  bool next = false,
  String? cursor,
}) {
  final value = expected ?? _expected;
  return {
    'id': id,
    'system': system,
    'systemNoteIconName': null,
    'body': body,
    'createdAt': '2026-10-01T01:02:03Z',
    'updatedAt': updatedAt,
    'author': {
      'id': authorId,
      'name': 'Synthetic User',
      'username': 'synthetic-user',
    },
    'internal': internal,
    'noteableType': 'Issue',
    'noteableId': int.parse(value.id.split('/').last),
    'project': value.project == null
        ? null
        : {'id': value.project!.id, 'fullPath': value.project!.fullPath},
    'discussion': {'id': _discussionId, 'createdAt': '2026-10-01T01:00:00Z'},
    'userPermissions': {'awardEmoji': canAward},
    'awardEmoji': {
      'nodes': awards,
      'pageInfo': {'hasNextPage': next, 'endCursor': cursor},
    },
  };
}

Map<String, Object?> _access({
  WorkItemGraphSummary? expected,
  String? actorId = _actorId,
  Object? note,
}) {
  final value = expected ?? _expected;
  return {
    'data': {
      'currentUser': actorId == null ? null : {'id': actorId},
      'workItem': _identity(value),
      'note': note ?? _note(expected: value),
    },
  };
}

Map<String, Object?> _mutationAck({
  required bool awarded,
  String name = 'thumbsup',
  Object? errors = const <Object?>[],
  Object? award,
}) => {
  'data': {
    awarded ? 'awardEmojiAdd' : 'awardEmojiRemove': {
      'errors': errors,
      if (awarded) 'awardEmoji': award ?? _reaction(name),
    },
  },
};

bool _isMutation(RequestOptions request) =>
    ((request.data as Map)['query'] as String).startsWith('mutation ');

Future<WorkItemActivityReactionTarget> _target(
  GitLabApi api, {
  WorkItemGraphSummary? expected,
}) async => (await api.workItemActivityReactionAccess(
  expected ?? _expected,
  _discussion,
  _displayedNote,
)).target!;

void main() {
  test(
    'strict group reactions reject another API before any request',
    () async {
      final first = testApi(FakeAdapter((_) => fail('unexpected request')));
      final adapter = FakeAdapter((_) => fail('unexpected request'));
      final second = testApi(adapter);
      addTearDown(first.close);
      addTearDown(second.close);
      final strict = _groupExpected.withStrictGroupOwner(
        strictGroupOwner(first, _groupExpected),
      );
      await expectLater(
        second.workItemActivityReactionAccess(
          strict,
          _discussion,
          _displayedNote,
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests, isEmpty);
    },
  );
  for (final awarded in [true, false]) {
    test(
      'strict group reaction ${awarded ? 'add' : 'remove'} verifies its readback',
      () async {
        var hooks = 0;
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            return jsonResponse(_mutationAck(awarded: awarded));
          }
          reads++;
          final after = reads == 3;
          return jsonResponse(
            _access(
              expected: _groupExpected,
              note: _note(
                expected: _groupExpected,
                updatedAt: after
                    ? '2026-10-01T01:04:04Z'
                    : '2026-10-01T01:03:04Z',
                awards: (after ? awarded : !awarded)
                    ? [_reaction('thumbsup')]
                    : const [],
              ),
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final strict = _groupExpected.withStrictGroupOwner(
          strictGroupOwner(api, _groupExpected),
        );
        final target = (await api.workItemActivityReactionAccess(
          strict,
          _discussion,
          _displayedNote,
        )).target!;
        final result = await api.setWorkItemActivityNoteReaction(
          target,
          'thumbsup',
          awarded: awarded,
          beforeMutation: () async {
            hooks++;
          },
          mayStart: () {
            hooks++;
            return true;
          },
        );
        expect(
          result.reactions.any(
            (r) => r.name == 'thumbsup' && r.actorId == _actorId,
          ),
          awarded,
        );
        expect(hooks, 2);
        expect(adapter.requests.where(_isMutation), hasLength(1));
        expect(adapter.requests, hasLength(4));
        await expectLater(
          api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: awarded,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests, hasLength(4));
      },
    );
  }

  for (final awarded in [true, false]) {
    for (final problem in [
      'missing',
      'project',
      'namespace',
      'namespace path',
      'workItemId',
      'iid',
      'note missing',
      'note project',
      'wrong state',
      'throw',
      'cancel',
    ]) {
      test(
        'strict reaction ${awarded ? 'add' : 'remove'} readback $problem is uncertain',
        () async {
          var reads = 0;
          var current = true;
          final adapter = FakeAdapter((request) {
            if (_isMutation(request)) {
              return jsonResponse(_mutationAck(awarded: awarded));
            }
            reads++;
            final after = reads == 3;
            if (after && problem == 'throw') {
              throw StateError('synthetic readback failure');
            }
            if (after && problem == 'cancel') current = false;
            final note = _note(
              expected: _groupExpected,
              updatedAt: after
                  ? '2026-10-01T01:04:04Z'
                  : '2026-10-01T01:03:04Z',
              awards: (after && problem != 'wrong state' ? awarded : !awarded)
                  ? [_reaction('thumbsup')]
                  : const [],
            );
            if (after && problem == 'note project') note.remove('project');
            final response = _access(expected: _groupExpected, note: note);
            if (after) {
              final data = response['data']! as Map<String, Object?>;
              final item = data['workItem']! as Map<String, Object?>;
              if (['missing', 'project', 'namespace'].contains(problem)) {
                corruptGroupOwner(item, problem);
              }
              if (problem == 'namespace path') {
                item['namespace'] = {
                  'id': 'gid://gitlab/Group/7',
                  'fullPath': 'foreign',
                };
              }
              if (problem == 'workItemId') {
                item['id'] = 'gid://gitlab/WorkItem/42';
              }
              if (problem == 'iid') item['iid'] = '9';
              if (problem == 'note missing') data['note'] = null;
            }
            return jsonResponse(response);
          });
          final api = testApi(adapter);
          addTearDown(api.close);
          final strict = _groupExpected.withStrictGroupOwner(
            strictGroupOwner(api, _groupExpected),
          );
          final target = (await api.workItemActivityReactionAccess(
            strict,
            _discussion,
            _displayedNote,
          )).target!;
          await expectLater(
            api.setWorkItemActivityNoteReaction(
              target,
              'thumbsup',
              awarded: awarded,
              isCurrent: () => current,
            ),
            throwsA(_failure(FailureKind.writeUncertain)),
          );
          expect(adapter.requests.where(_isMutation), hasLength(1));
          expect(adapter.requests, hasLength(4));
          await expectLater(
            api.setWorkItemActivityNoteReaction(
              target,
              'thumbsup',
              awarded: awarded,
            ),
            throwsA(_failure(FailureKind.writeUncertain)),
          );
          expect(adapter.requests, hasLength(4));
        },
      );
    }
  }

  test('strict group reaction exact noop remains available', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse(_access(expected: _groupExpected)),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final strict = _groupExpected.withStrictGroupOwner(
      strictGroupOwner(api, _groupExpected),
    );
    final target = (await api.workItemActivityReactionAccess(
      strict,
      _discussion,
      _displayedNote,
    )).target!;
    expect(
      (await api.setWorkItemActivityNoteReaction(
        target,
        'thumbsup',
        awarded: false,
      )).reactions,
      isEmpty,
    );
    expect(adapter.requests.where(_isMutation), isEmpty);
  });
  test('strict group reactions reject omitted project before noop', () async {
    var reads = 0;
    final adapter = FakeAdapter((_) {
      reads++;
      final response = _access(expected: _groupExpected);
      if (reads == 2) {
        ((response['data']! as Map)['workItem'] as Map).remove('project');
      }
      return jsonResponse(response);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final strict = _groupExpected.withStrictGroupOwner(
      strictGroupOwner(api, _groupExpected),
    );
    final target = (await api.workItemActivityReactionAccess(
      strict,
      _discussion,
      _displayedNote,
    )).target!;
    await expectLater(
      api.setWorkItemActivityNoteReaction(target, 'thumbsup', awarded: false),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
    expect(adapter.requests.where(_isMutation), isEmpty);
  });
  for (final problem in ['exact', 'missing', 'project', 'namespace']) {
    for (final phase in ['opening', 'preflight']) {
      test('strict group reactions $problem at $phase', () async {
        var reads = 0;
        var sent = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            sent++;
            return jsonResponse(_mutationAck(awarded: true));
          }
          reads++;
          final response = _access(
            expected: _groupExpected,
            note: _note(
              expected: _groupExpected,
              updatedAt: reads < 3
                  ? '2026-10-01T01:03:04Z'
                  : '2026-10-01T01:04:04Z',
              awards: reads < 3 ? const [] : [_reaction('thumbsup')],
            ),
          );
          final item =
              (response['data']! as Map)['workItem'] as Map<String, Object?>;
          if ((phase == 'opening' && reads == 1) ||
              (phase == 'preflight' && reads == 2) ||
              (phase == 'readback' && reads == 3)) {
            corruptGroupOwner(item, problem);
          }
          return jsonResponse(response);
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final strict = _groupExpected.withStrictGroupOwner(
          strictGroupOwner(api, _groupExpected),
        );
        final opening = api.workItemActivityReactionAccess(
          strict,
          _discussion,
          _displayedNote,
        );
        if (problem != 'exact' && phase == 'opening') {
          await expectLater(
            opening,
            throwsA(_failure(FailureKind.invalidResponse)),
          );
        } else {
          final target = (await opening).target!;
          final result = api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: true,
          );
          if (problem == 'exact') {
            await result;
          } else {
            await expectLater(
              result,
              throwsA(_failure(FailureKind.invalidResponse)),
            );
          }
        }
        expect(sent, problem == 'exact' ? 1 : 0);
      });
    }
  }

  for (final problem in ['exact', 'missing', 'project', 'namespace']) {
    test('strict group reactions $problem on continuation page', () async {
      var page = 0;
      final adapter = FakeAdapter((_) {
        page++;
        final response = _access(
          expected: _groupExpected,
          note: _note(
            expected: _groupExpected,
            next: page == 1,
            cursor: page == 1 ? 'next' : null,
          ),
        );
        final item =
            (response['data']! as Map)['workItem'] as Map<String, Object?>;
        if (page == 2) corruptGroupOwner(item, problem);
        return jsonResponse(response);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final strict = _groupExpected.withStrictGroupOwner(
        strictGroupOwner(api, _groupExpected),
      );
      final opening = api.workItemActivityReactionAccess(
        strict,
        _discussion,
        _displayedNote,
      );
      if (problem == 'exact') {
        expect((await opening).target, isNotNull);
      } else {
        await expectLater(
          opening,
          throwsA(_failure(FailureKind.invalidResponse)),
        );
      }
      expect(page, 2);
      expect(adapter.requests.where(_isMutation), isEmpty);
    });
  }

  test('strict group reactions require explicit null note project', () async {
    final note = _note(expected: _groupExpected)..remove('project');
    final adapter = FakeAdapter(
      (_) => jsonResponse(_access(expected: _groupExpected, note: note)),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final strict = _groupExpected.withStrictGroupOwner(
      strictGroupOwner(api, _groupExpected),
    );
    await expectLater(
      api.workItemActivityReactionAccess(strict, _discussion, _displayedNote),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  for (final phase in ['preflight', 'readback']) {
    test(
      'strict group reactions reject missing note project at $phase',
      () async {
        var reads = 0;
        var sent = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            sent++;
            return jsonResponse(_mutationAck(awarded: true));
          }
          reads++;
          final note = _note(
            expected: _groupExpected,
            updatedAt: reads < 3
                ? '2026-10-01T01:03:04Z'
                : '2026-10-01T01:04:04Z',
            awards: reads < 3 ? const [] : [_reaction('thumbsup')],
          );
          if ((phase == 'preflight' && reads == 2) ||
              (phase == 'readback' && reads == 3)) {
            note.remove('project');
          }
          return jsonResponse(_access(expected: _groupExpected, note: note));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final strict = _groupExpected.withStrictGroupOwner(
          strictGroupOwner(api, _groupExpected),
        );
        final target = (await api.workItemActivityReactionAccess(
          strict,
          _discussion,
          _displayedNote,
        )).target!;
        await expectLater(
          api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: true,
          ),
          throwsA(
            _failure(
              phase == 'preflight'
                  ? FailureKind.invalidResponse
                  : FailureKind.writeUncertain,
            ),
          ),
        );
        expect(sent, phase == 'preflight' ? 0 : 1);
      },
    );
  }

  test(
    'default group reactions accept omitted parent and note project',
    () async {
      final note = _note(expected: _groupExpected)..remove('project');
      final response = _access(expected: _groupExpected, note: note);
      final item =
          (response['data']! as Map)['workItem'] as Map<String, Object?>;
      item.remove('project');
      final adapter = FakeAdapter((_) => jsonResponse(response));
      final api = testApi(adapter);
      addTearDown(api.close);
      expect(
        (await api.workItemActivityReactionAccess(
          _groupExpected,
          _discussion,
          _displayedNote,
        )).target,
        isNotNull,
      );
      expect(adapter.requests.where(_isMutation), isEmpty);
    },
  );
  test('pages complete project reactions before minting a target', () async {
    var page = 0;
    final adapter = FakeAdapter((request) {
      final data = request.data as Map;
      final query = data['query'] as String;
      expect(query, startsWith('query MobileWorkItemActivityReactionAccess'));
      expect(query, contains('userPermissions { awardEmoji }'));
      expect(query, contains('awardEmoji(first: 50, after: \$after)'));
      expect(query, isNot(contains('avatarUrl')));
      expect(data['variables'], {
        'workItemId': _workItemId,
        'noteId': _noteId,
        'after': page == 0 ? null : 'page-a',
      });
      page++;
      return jsonResponse(
        _access(
          note: _note(
            awards: [
              page == 1
                  ? _reaction('thumbsup')
                  : _reaction('eyes', actorId: _otherActorId),
            ],
            next: page == 1,
            cursor: page == 1 ? 'page-a' : null,
          ),
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    final access = await api.workItemActivityReactionAccess(
      _expected,
      _discussion,
      _displayedNote,
    );

    expect(page, 2);
    expect(access.actorId, _actorId);
    expect(access.canAward, isTrue);
    expect(access.target?.note.id, _noteId);
    expect(access.reactions.map((reaction) => reaction.name), [
      'thumbsup',
      'eyes',
    ]);
    expect(access.reactions.last.actorId, _otherActorId);
    expect(
      () => access.reactions.add(
        const WorkItemActivityReaction(
          name: 'heart',
          unicode: null,
          actorId: _actorId,
        ),
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'group Work Item access validates namespace without a project',
    () async {
      final api = testApi(
        FakeAdapter((request) {
          expect((request.data as Map)['variables'], {
            'workItemId': _groupExpected.id,
            'noteId': _noteId,
            'after': null,
          });
          return jsonResponse(
            _access(
              expected: _groupExpected,
              note: _note(
                expected: _groupExpected,
                awards: [_reaction('tada')],
              ),
            ),
          );
        }),
      );
      addTearDown(api.close);

      final access = await api.workItemActivityReactionAccess(
        _groupExpected,
        _discussion,
        _displayedNote,
      );
      expect(access.canAward, isTrue);
      expect(access.target, isNotNull);
      expect(access.reactions.single.name, 'tada');
    },
  );

  test(
    'permission, actor, and ordinary-note checks independently gate writes',
    () async {
      for (final response in [
        _access(note: _note(canAward: false)),
        _access(actorId: null),
        _access(note: _note(internal: true)),
      ]) {
        final api = testApi(FakeAdapter((_) => jsonResponse(response)));
        final access = await api.workItemActivityReactionAccess(
          _expected,
          _discussion,
          _displayedNote,
        );
        expect(access.canAward, isFalse);
        expect(access.target, isNull);
        api.close();
      }
    },
  );

  test(
    'adds a project note reaction when updatedAt advances in readback',
    () async {
      var call = 0;
      var updatedAt = '2026-10-01T01:03:04Z';
      final adapter = FakeAdapter((request) {
        call++;
        final data = request.data as Map;
        if (call <= 2) return jsonResponse(_access());
        if (_isMutation(request)) {
          expect(
            data['query'],
            startsWith('mutation MobileAddWorkItemActivityNoteReaction'),
          );
          expect(data['variables'], {
            'input': {'awardableId': _noteId, 'name': 'thumbsup'},
          });
          updatedAt = '2026-10-01T01:04:04Z';
          return jsonResponse(_mutationAck(awarded: true));
        }
        return jsonResponse(
          _access(
            note: _note(updatedAt: updatedAt, awards: [_reaction('thumbsup')]),
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);

      final access = await api.setWorkItemActivityNoteReaction(
        target,
        'thumbsup',
        awarded: true,
      );

      expect(access.reactions.single.name, 'thumbsup');
      expect(access.target, isNotNull);
      expect(access.target!.note.updatedAt, DateTime.parse(updatedAt));
      expect(
        access.target!.note.updatedAt.isAfter(target.note.updatedAt),
        isTrue,
      );
      expect(adapter.requests.where(_isMutation), hasLength(1));
    },
  );

  test(
    'removes a group note reaction when updatedAt advances in readback',
    () async {
      var call = 0;
      var updatedAt = '2026-10-01T01:03:04Z';
      final awardedAccess = _access(
        expected: _groupExpected,
        note: _note(
          expected: _groupExpected,
          awards: [_reaction('heart', unicode: '❤️')],
        ),
      );
      final adapter = FakeAdapter((request) {
        call++;
        final data = request.data as Map;
        if (call <= 2) return jsonResponse(awardedAccess);
        if (_isMutation(request)) {
          expect(
            data['query'],
            startsWith('mutation MobileRemoveWorkItemActivityNoteReaction'),
          );
          expect(data['variables'], {
            'input': {'awardableId': _noteId, 'name': 'heart'},
          });
          updatedAt = '2026-10-01T01:04:04Z';
          return jsonResponse(_mutationAck(awarded: false));
        }
        return jsonResponse(
          _access(
            expected: _groupExpected,
            note: _note(expected: _groupExpected, updatedAt: updatedAt),
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api, expected: _groupExpected);

      final access = await api.setWorkItemActivityNoteReaction(
        target,
        'heart',
        awarded: false,
      );

      expect(access.reactions, isEmpty);
      expect(access.target!.note.updatedAt, DateTime.parse(updatedAt));
      expect(
        access.target!.note.updatedAt.isAfter(target.note.updatedAt),
        isTrue,
      );
      expect(adapter.requests.where(_isMutation), hasLength(1));
    },
  );

  for (final awarded in [true, false]) {
    for (final changedField in ['body', 'author']) {
      test(
        'changed $changedField in reaction readback is uncertain, awarded=$awarded',
        () async {
          var mutated = false;
          final adapter = FakeAdapter((request) {
            if (_isMutation(request)) {
              mutated = true;
              return jsonResponse(_mutationAck(awarded: awarded));
            }
            return jsonResponse(
              _access(
                note: _note(
                  updatedAt: mutated
                      ? '2026-10-01T01:04:04Z'
                      : '2026-10-01T01:03:04Z',
                  body: mutated && changedField == 'body'
                      ? 'Changed note'
                      : 'Synthetic note',
                  authorId: mutated && changedField == 'author'
                      ? _otherActorId
                      : _actorId,
                  awards: (mutated ? awarded : !awarded)
                      ? [_reaction('thumbsup')]
                      : const [],
                ),
              ),
            );
          });
          final api = testApi(adapter);
          addTearDown(api.close);
          final target = await _target(api);

          await expectLater(
            api.setWorkItemActivityNoteReaction(
              target,
              'thumbsup',
              awarded: awarded,
            ),
            throwsA(_failure(FailureKind.writeUncertain)),
          );
          expect(adapter.requests.where(_isMutation), hasLength(1));
          await expectLater(
            api.setWorkItemActivityNoteReaction(
              target,
              'thumbsup',
              awarded: awarded,
            ),
            throwsA(_failure(FailureKind.writeUncertain)),
          );
          expect(adapter.requests.where(_isMutation), hasLength(1));
        },
      );
    }
  }

  test('an already-satisfied explicit state is a consumed no-op', () async {
    final adapter = FakeAdapter(
      (_) =>
          jsonResponse(_access(note: _note(awards: [_reaction('thumbsup')]))),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = await _target(api);

    final access = await api.setWorkItemActivityNoteReaction(
      target,
      'thumbsup',
      awarded: true,
    );
    expect(access.reactions.single.name, 'thumbsup');
    expect(adapter.requests.where(_isMutation), isEmpty);
    await expectLater(
      api.setWorkItemActivityNoteReaction(target, 'thumbsup', awarded: true),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
  });

  test(
    'changed own state or note revision conflicts before mutation',
    () async {
      for (final freshNote in [
        _note(awards: [_reaction('thumbsup')]),
        _note(updatedAt: '2026-10-01T01:04:04Z'),
      ]) {
        var call = 0;
        final adapter = FakeAdapter((_) {
          call++;
          return jsonResponse(_access(note: call == 1 ? _note() : freshNote));
        });
        final api = testApi(adapter);
        final target = await _target(api);
        await expectLater(
          api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: true,
          ),
          throwsA(_failure(FailureKind.conflict)),
        );
        expect(adapter.requests.where(_isMutation), isEmpty);
        api.close();
      }
    },
  );

  test('fresh permission and actor changes stop before mutation', () async {
    for (final fresh in [
      _access(note: _note(canAward: false)),
      _access(actorId: _otherActorId),
    ]) {
      var call = 0;
      final adapter = FakeAdapter((_) {
        call++;
        return jsonResponse(call == 1 ? _access() : fresh);
      });
      final api = testApi(adapter);
      final target = await _target(api);
      await expectLater(
        api.setWorkItemActivityNoteReaction(target, 'thumbsup', awarded: true),
        throwsA(
          _failure(
            fresh['data'] is Map &&
                    ((fresh['data'] as Map)['currentUser'] as Map?)?['id'] ==
                        _otherActorId
                ? FailureKind.cancelled
                : FailureKind.forbidden,
          ),
        ),
      );
      expect(adapter.requests.where(_isMutation), isEmpty);
      api.close();
    }
  });

  test('invalid requested names and stale request send no mutation', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_access()));
    final api = testApi(adapter);
    addTearDown(api.close);
    for (final name in ['', 'bad name', ':thumbsup:', 'x' * 81]) {
      final target = await _target(api);
      final before = adapter.requests.length;
      await expectLater(
        api.setWorkItemActivityNoteReaction(target, name, awarded: true),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(adapter.requests.length, before);
    }
    final stale = await _target(api);
    await expectLater(
      api.setWorkItemActivityNoteReaction(
        stale,
        'thumbsup',
        awarded: true,
        isCurrent: () => false,
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  test(
    'pagination rejects duplicate awards, cursors, and a partial page cap',
    () async {
      Future<void> expectInvalid(FakeAdapter adapter) async {
        final api = testApi(adapter);
        await expectLater(
          api.workItemActivityReactionAccess(
            _expected,
            _discussion,
            _displayedNote,
          ),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }

      var duplicatePage = 0;
      await expectInvalid(
        FakeAdapter((_) {
          duplicatePage++;
          return jsonResponse(
            _access(
              note: _note(
                awards: [_reaction('thumbsup')],
                next: duplicatePage == 1,
                cursor: duplicatePage == 1 ? 'page-a' : null,
              ),
            ),
          );
        }),
      );

      await expectInvalid(
        FakeAdapter(
          (_) => jsonResponse(
            _access(note: _note(next: true, cursor: 'same-cursor')),
          ),
        ),
      );

      var capCalls = 0;
      final capped = FakeAdapter((_) {
        capCalls++;
        return jsonResponse(
          _access(note: _note(next: true, cursor: 'cursor-$capCalls')),
        );
      });
      await expectInvalid(capped);
      expect(capCalls, 20);
    },
  );

  test(
    'malformed reactions, permission, actor, scope, and revision are refused',
    () async {
      final invalidResponses = <Map<String, Object?>>[
        _access(note: _note(awards: [_reaction('bad name')])),
        _access(
          note: _note(awards: [_reaction('thumbsup', actorId: _projectId)]),
        ),
        _access(actorId: _projectId),
        _access(
          note: {
            ..._note(),
            'userPermissions': {'awardEmoji': 'yes'},
          },
        ),
        _access(note: _note(id: 'gid://gitlab/Project/401')),
        {
          'data': {
            'currentUser': {'id': _actorId},
            'workItem': _identity(_groupExpected),
            'note': _note(),
          },
        },
      ];
      for (final response in invalidResponses) {
        final api = testApi(FakeAdapter((_) => jsonResponse(response)));
        await expectLater(
          api.workItemActivityReactionAccess(
            _expected,
            _discussion,
            _displayedNote,
          ),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }

      final changedAcrossPages = testApi(
        FakeAdapter((request) {
          final after = ((request.data as Map)['variables'] as Map)['after'];
          return jsonResponse(
            _access(
              note: _note(
                body: after == null ? 'Synthetic note' : 'changed',
                next: after == null,
                cursor: after == null ? 'next' : null,
              ),
            ),
          );
        }),
      );
      await expectLater(
        changedAcrossPages.workItemActivityReactionAccess(
          _expected,
          _discussion,
          _displayedNote,
        ),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      changedAcrossPages.close();
    },
  );

  test('updatedAt changes across reaction pages are refused', () async {
    final adapter = FakeAdapter((request) {
      final after = ((request.data as Map)['variables'] as Map)['after'];
      return jsonResponse(
        _access(
          note: _note(
            updatedAt: after == null
                ? '2026-10-01T01:03:04Z'
                : '2026-10-01T01:04:04Z',
            next: after == null,
            cursor: after == null ? 'next' : null,
          ),
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await expectLater(
      _target(api),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  test(
    'target is owner-bound and concurrent dispatch sends at most once',
    () async {
      final mutation = Completer<ResponseBody>();
      var mutationSent = false;
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          mutationSent = true;
          return mutation.future;
        }
        if (mutationSent) {
          return jsonResponse(
            _access(note: _note(awards: [_reaction('thumbsup')])),
          );
        }
        return jsonResponse(_access());
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = await _target(api);
      final other = testApi(
        FakeAdapter((_) => fail('wrong owner must not send')),
      );
      await expectLater(
        other.setWorkItemActivityNoteReaction(
          target,
          'thumbsup',
          awarded: true,
        ),
        throwsA(_failure(FailureKind.validation)),
      );
      other.close();

      final first = api.setWorkItemActivityNoteReaction(
        target,
        'thumbsup',
        awarded: true,
      );
      final second = api.setWorkItemActivityNoteReaction(
        target,
        'thumbsup',
        awarded: true,
      );
      await Future<void>.delayed(Duration.zero);
      mutation.complete(jsonResponse(_mutationAck(awarded: true)));
      final outcomes = await Future.wait<Object>([
        first.then<Object>((value) => value, onError: (Object error) => error),
        second.then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(
        outcomes.whereType<WorkItemActivityReactionAccess>(),
        hasLength(1),
      );
      expect(
        outcomes.whereType<ApiFailure>().single.kind,
        FailureKind.writeUncertain,
      );
      expect(adapter.requests.where(_isMutation), hasLength(1));
    },
  );

  test(
    'mutation and readback failures are uncertain and never replay',
    () async {
      for (final mode in ['errors', 'timeout', 'ack', 'readback']) {
        var call = 0;
        final adapter = FakeAdapter((request) {
          call++;
          if (call <= 2) return jsonResponse(_access());
          if (_isMutation(request)) {
            if (mode == 'timeout') {
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.receiveTimeout,
              );
            }
            if (mode == 'errors') {
              return jsonResponse(
                _mutationAck(awarded: true, errors: ['synthetic']),
              );
            }
            if (mode == 'ack') {
              return jsonResponse(
                _mutationAck(awarded: true, award: _reaction('eyes')),
              );
            }
            return jsonResponse(_mutationAck(awarded: true));
          }
          return jsonResponse(
            _access(
              note: _note(
                awards: mode == 'readback' ? const [] : [_reaction('thumbsup')],
              ),
            ),
          );
        });
        final api = testApi(adapter);
        final target = await _target(api);
        await expectLater(
          api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: true,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        await expectLater(
          api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: true,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests.where(_isMutation), hasLength(1));
        api.close();
      }
    },
  );
}
