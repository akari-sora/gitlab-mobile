import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import '../support/fake_adapter.dart';

const _actorId = 'gid://gitlab/User/7';
const _workItemId = 'gid://gitlab/WorkItem/31';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/42';
const _path = 'studio/mobile-workspace';
const _discussionId = 'gid://gitlab/Discussion/301';
const _replyId = 'gid://gitlab/IndividualNoteDiscussion/301';
const _noteId = 'gid://gitlab/Note/401';

final _createdAt = DateTime.utc(2026, 10, 1);
final _updatedAt = DateTime.utc(2026, 10, 3, 9);

final _summary = WorkItemGraphSummary(
  id: _workItemId,
  iid: 31,
  title: 'Synthetic item',
  state: 'OPEN',
  createdAt: _createdAt,
  updatedAt: _updatedAt,
  project: const GraphResourceRef(id: _projectId, fullPath: _path),
  namespace: const GraphResourceRef(id: _namespaceId, fullPath: _path),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/9',
    name: 'Task',
  ),
);

final _detail = WorkItemGraphDetail(
  summary: _summary,
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'ASSIGNEES'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

final _note = WorkItemActivityNote(
  id: _noteId,
  system: false,
  systemNoteIconName: null,
  body: 'Synthetic note',
  createdAt: DateTime.utc(2026, 10, 1, 1, 2, 3),
  updatedAt: DateTime.utc(2026, 10, 1, 1, 3, 4),
  author: const WorkItemActivityAuthor(
    id: _actorId,
    name: 'Synthetic User',
    username: 'synthetic-user',
  ),
);

final _discussion = WorkItemActivityDiscussion(
  id: _discussionId,
  replyId: _replyId,
  createdAt: DateTime.utc(2026, 10, 1, 1),
  notes: WorkItemActivityConnection(
    availability: WorkItemActivityConnectionAvailability.present,
    items: [_note],
  ),
);

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

Map<String, Object?> _assigneeUser(int id) => {
  'id': 'gid://gitlab/User/$id',
  'name': 'Person $id',
  'username': 'person$id',
};

Map<String, Object?> _assigneeNode({
  required List<int> users,
  bool hasNext = false,
  String? cursor,
  bool includePermissions = true,
}) => {
  'id': _summary.id,
  'iid': '${_summary.iid}',
  'title': _summary.title,
  'state': _summary.state,
  'createdAt': _summary.createdAt.toIso8601String(),
  'updatedAt': _summary.updatedAt.toIso8601String(),
  'project': {'id': _projectId, 'fullPath': _path},
  'namespace': {'id': _namespaceId, 'fullPath': _path},
  'workItemType': {'id': _summary.type.id, 'name': _summary.type.name},
  if (includePermissions)
    'userPermissions': {'readWorkItem': true, 'setWorkItemMetadata': true},
  'widgets': [
    {
      'type': 'ASSIGNEES',
      'allowsMultipleAssignees': true,
      'assignees': {
        'nodes': [for (final id in users) _assigneeUser(id)],
        'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
      },
    },
  ],
};

Map<String, Object?> _assigneeRead({
  required List<int> users,
  bool hasNext = false,
  String? cursor,
}) => {
  'data': {
    'currentUser': {'id': _actorId},
    'workItem': _assigneeNode(users: users, hasNext: hasNext, cursor: cursor),
  },
};

Map<String, Object?> _assigneeAck({
  required List<int> users,
  bool hasNext = false,
  String? cursor,
}) => {
  'data': {
    'workItemUpdate': {
      'errors': <Object?>[],
      'workItem': _assigneeNode(
        users: users,
        hasNext: hasNext,
        cursor: cursor,
        includePermissions: false,
      ),
    },
  },
};

Map<String, Object?> _reactionNode(String name) => {
  'name': name,
  'unicode': null,
  'user': {'id': _actorId},
};

Map<String, Object?> _reactionAccess({
  List<String> reactions = const [],
  bool hasNext = false,
  String? cursor,
}) => {
  'data': {
    'currentUser': {'id': _actorId},
    'workItem': {
      'id': _summary.id,
      'iid': '${_summary.iid}',
      'project': {'id': _projectId, 'fullPath': _path},
      'namespace': {'id': _namespaceId, 'fullPath': _path},
    },
    'note': {
      'id': _note.id,
      'system': false,
      'systemNoteIconName': null,
      'body': _note.body,
      'createdAt': _note.createdAt.toIso8601String(),
      'updatedAt': _note.updatedAt.toIso8601String(),
      'author': {
        'id': _actorId,
        'name': 'Synthetic User',
        'username': 'synthetic-user',
      },
      'internal': false,
      'noteableType': 'Issue',
      'noteableId': 31,
      'project': {'id': _projectId, 'fullPath': _path},
      'discussion': {
        'id': _discussionId,
        'createdAt': _discussion.createdAt.toIso8601String(),
      },
      'userPermissions': {'awardEmoji': true},
      'awardEmoji': {
        'nodes': [for (final name in reactions) _reactionNode(name)],
        'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
      },
    },
  },
};

Map<String, Object?> _reactionAck() => {
  'data': {
    'awardEmojiAdd': {
      'errors': <Object?>[],
      'awardEmoji': _reactionNode('thumbsup'),
    },
  },
};

bool _isMutation(RequestOptions request) =>
    ((request.data as Map)['query'] as String).startsWith('mutation ');

Future<Object> _capture(Future<Object> future) =>
    future.then<Object>((value) => value, onError: (Object error) => error);

void main() {
  group('assignee maxPages', () {
    test('rejects malformed caps before any request', () async {
      final adapter = FakeAdapter((_) => fail('must not request'));
      final api = testApi(adapter);
      addTearDown(api.close);

      for (final maxPages in [0, 21]) {
        expect(
          () => api.workItemAssignees(
            _detail,
            expectedUserId: 7,
            maxPages: maxPages,
          ),
          throwsArgumentError,
        );
      }
      expect(adapter.requests, isEmpty);
    });

    test('opening stops at its cap without requesting another page', () async {
      var calls = 0;
      final adapter = FakeAdapter((_) {
        calls++;
        return jsonResponse(
          _assigneeRead(users: [calls], hasNext: true, cursor: 'page-$calls'),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await expectLater(
        api.workItemAssignees(_detail, expectedUserId: 7, maxPages: 1),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(calls, 1);
    });

    test('stored cap bounds update preflight', () async {
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        expect(_isMutation(request), isFalse);
        return jsonResponse(
          calls == 1
              ? _assigneeRead(users: [1])
              : _assigneeRead(
                  users: [1],
                  hasNext: true,
                  cursor: 'preflight-next',
                ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail,
        expectedUserId: 7,
        maxPages: 1,
      )).target!;

      await expectLater(
        api.updateWorkItemAssignees(
          target,
          assigneeIds: const ['gid://gitlab/User/2'],
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(calls, 2);
    });

    test('stored cap bounds acknowledgement continuation', () async {
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        if (_isMutation(request)) {
          return jsonResponse(
            _assigneeAck(users: [2], hasNext: true, cursor: 'ack-next'),
          );
        }
        if (calls <= 2) return jsonResponse(_assigneeRead(users: [1]));
        return fail('ack cap must prevent a continuation or readback');
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail,
        expectedUserId: 7,
        maxPages: 1,
      )).target!;

      await expectLater(
        api.updateWorkItemAssignees(
          target,
          assigneeIds: const ['gid://gitlab/User/2'],
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(calls, 3);
    });

    test('stored cap independently bounds readback', () async {
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        if (_isMutation(request)) {
          return jsonResponse(_assigneeAck(users: [2]));
        }
        if (calls <= 2) return jsonResponse(_assigneeRead(users: [1]));
        if (calls == 4) {
          return jsonResponse(
            _assigneeRead(users: [2], hasNext: true, cursor: 'readback-next'),
          );
        }
        return fail('readback cap must prevent another request');
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail,
        expectedUserId: 7,
        maxPages: 1,
      )).target!;

      await expectLater(
        api.updateWorkItemAssignees(
          target,
          assigneeIds: const ['gid://gitlab/User/2'],
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(calls, 4);
    });
  });

  group('assignee mutation boundary', () {
    test(
      'pair mismatch preserves the target and noop skips both hooks',
      () async {
        var calls = 0;
        final adapter = FakeAdapter((_) {
          calls++;
          return jsonResponse(_assigneeRead(users: [1]));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemAssignees(
          _detail,
          expectedUserId: 7,
          maxPages: 1,
        )).target!;

        await expectLater(
          api.updateWorkItemAssignees(
            target,
            assigneeIds: const ['gid://gitlab/User/1'],
            beforeMutation: () async {},
          ),
          throwsArgumentError,
        );
        await expectLater(
          api.updateWorkItemAssignees(
            target,
            assigneeIds: const ['gid://gitlab/User/1'],
            mayStart: () => true,
          ),
          throwsArgumentError,
        );
        expect(calls, 1);
        expect(target.consumed, isFalse);

        var hookCalls = 0;
        var gateCalls = 0;
        var reports = 0;
        await api.updateWorkItemAssignees(
          target,
          assigneeIds: const ['gid://gitlab/User/1'],
          beforeMutation: () async => hookCalls++,
          mayStart: () {
            gateCalls++;
            return true;
          },
          onMutationSent: () => reports++,
        );
        expect(calls, 2);
        expect(target.consumed, isTrue);
        expect((hookCalls, reports, gateCalls), (0, 0, 0));
        expect(adapter.requests.where(_isMutation), isEmpty);
      },
    );

    test('awaits hook before callback, gate, and send', () async {
      final release = Completer<void>();
      final events = <String>[];
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        if (_isMutation(request)) {
          events.add('send');
          return jsonResponse(_assigneeAck(users: [2]));
        }
        return jsonResponse(_assigneeRead(users: calls <= 2 ? [1] : [2]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemAssignees(
        _detail,
        expectedUserId: 7,
        maxPages: 1,
      )).target!;

      final operation = api.updateWorkItemAssignees(
        target,
        assigneeIds: const ['gid://gitlab/User/2'],
        beforeMutation: () async {
          events.add('hook');
          await release.future;
          events.add('hook-done');
        },
        onMutationSent: () => events.add('reported'),
        mayStart: () {
          events.add('gate');
          return true;
        },
      );
      while (!events.contains('hook')) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(events, ['hook']);
      expect(adapter.requests.where(_isMutation), isEmpty);
      release.complete();
      await operation;
      expect(events, ['hook', 'hook-done', 'reported', 'gate', 'send']);
      expect(adapter.requests.where(_isMutation), hasLength(1));
    });

    test('false gate and throwing hook send no mutation', () async {
      for (final throwFromHook in [false, true]) {
        final events = <String>[];
        var calls = 0;
        final adapter = FakeAdapter((request) {
          calls++;
          expect(_isMutation(request), isFalse);
          return jsonResponse(_assigneeRead(users: [1]));
        });
        final api = testApi(adapter);
        final target = (await api.workItemAssignees(
          _detail,
          expectedUserId: 7,
          maxPages: 1,
        )).target!;

        final operation = api.updateWorkItemAssignees(
          target,
          assigneeIds: const ['gid://gitlab/User/2'],
          beforeMutation: () async {
            events.add('hook');
            if (throwFromHook) throw StateError('synthetic hook refusal');
          },
          onMutationSent: () => events.add('reported'),
          mayStart: () {
            events.add('gate');
            return false;
          },
        );
        await expectLater(
          operation,
          throwsA(
            throwFromHook ? isA<StateError>() : _failure(FailureKind.cancelled),
          ),
        );
        expect(events, throwFromHook ? ['hook'] : ['hook', 'reported', 'gate']);
        expect(calls, 2);
        expect(adapter.requests.where(_isMutation), isEmpty);
        api.close();
      }
    });
  });

  group('reaction maxPages', () {
    test('rejects malformed caps before any request', () async {
      final adapter = FakeAdapter((_) => fail('must not request'));
      final api = testApi(adapter);
      addTearDown(api.close);

      for (final maxPages in [0, 21]) {
        await expectLater(
          api.workItemActivityReactionAccess(
            _summary,
            _discussion,
            _note,
            maxPages: maxPages,
          ),
          throwsArgumentError,
        );
      }
      expect(adapter.requests, isEmpty);
    });

    test('opening stops at its cap without requesting another page', () async {
      var calls = 0;
      final adapter = FakeAdapter((_) {
        calls++;
        return jsonResponse(
          _reactionAccess(hasNext: true, cursor: 'page-$calls'),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await expectLater(
        api.workItemActivityReactionAccess(
          _summary,
          _discussion,
          _note,
          maxPages: 2,
        ),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(calls, 2);
    });

    test('stored cap bounds update preflight', () async {
      var calls = 0;
      final adapter = FakeAdapter((_) {
        calls++;
        if (calls == 1) return jsonResponse(_reactionAccess());
        return jsonResponse(
          _reactionAccess(hasNext: true, cursor: 'preflight-$calls'),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemActivityReactionAccess(
        _summary,
        _discussion,
        _note,
        maxPages: 2,
      )).target!;

      await expectLater(
        api.setWorkItemActivityNoteReaction(target, 'thumbsup', awarded: true),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(calls, 3);
    });

    test(
      'mutation acknowledgement does not consume a paging request',
      () async {
        var calls = 0;
        final adapter = FakeAdapter((request) {
          calls++;
          if (calls <= 2) return jsonResponse(_reactionAccess());
          if (_isMutation(request)) {
            return jsonResponse({
              'data': {
                'awardEmojiAdd': {
                  'errors': <Object?>[],
                  'awardEmoji': _reactionNode('eyes'),
                },
              },
            });
          }
          return fail('invalid acknowledgement must stop before readback');
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemActivityReactionAccess(
          _summary,
          _discussion,
          _note,
          maxPages: 2,
        )).target!;

        await expectLater(
          api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: true,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(calls, 3);
      },
    );

    test('stored cap independently bounds readback', () async {
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        if (calls <= 2) return jsonResponse(_reactionAccess());
        if (_isMutation(request)) return jsonResponse(_reactionAck());
        if (calls <= 5) {
          return jsonResponse(
            _reactionAccess(
              reactions: calls == 4 ? const ['thumbsup'] : const [],
              hasNext: true,
              cursor: 'readback-$calls',
            ),
          );
        }
        return fail('readback cap must prevent another request');
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemActivityReactionAccess(
        _summary,
        _discussion,
        _note,
        maxPages: 2,
      )).target!;

      final outcome = await _capture(
        api.setWorkItemActivityNoteReaction(target, 'thumbsup', awarded: true),
      );
      expect(outcome, _failure(FailureKind.writeUncertain));
      expect(calls, 5);
    });
  });

  group('reaction mutation boundary', () {
    test(
      'pair mismatch preserves the target and noop skips both hooks',
      () async {
        var calls = 0;
        final adapter = FakeAdapter((_) {
          calls++;
          return jsonResponse(_reactionAccess(reactions: const ['thumbsup']));
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final target = (await api.workItemActivityReactionAccess(
          _summary,
          _discussion,
          _note,
          maxPages: 2,
        )).target!;

        await expectLater(
          api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: true,
            beforeMutation: () async {},
          ),
          throwsArgumentError,
        );
        await expectLater(
          api.setWorkItemActivityNoteReaction(
            target,
            'thumbsup',
            awarded: true,
            mayStart: () => true,
          ),
          throwsArgumentError,
        );
        expect(calls, 1);

        var hookCalls = 0;
        var gateCalls = 0;
        await api.setWorkItemActivityNoteReaction(
          target,
          'thumbsup',
          awarded: true,
          beforeMutation: () async => hookCalls++,
          mayStart: () {
            gateCalls++;
            return true;
          },
        );
        expect(calls, 2);
        expect((hookCalls, gateCalls), (0, 0));
        expect(adapter.requests.where(_isMutation), isEmpty);
      },
    );

    test('awaits hook before gate and send', () async {
      final release = Completer<void>();
      final events = <String>[];
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        if (_isMutation(request)) {
          events.add('send');
          return jsonResponse(_reactionAck());
        }
        return jsonResponse(
          _reactionAccess(
            reactions: calls >= 4 ? const ['thumbsup'] : const [],
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemActivityReactionAccess(
        _summary,
        _discussion,
        _note,
        maxPages: 2,
      )).target!;

      final operation = api.setWorkItemActivityNoteReaction(
        target,
        'thumbsup',
        awarded: true,
        beforeMutation: () async {
          events.add('hook');
          await release.future;
          events.add('hook-done');
        },
        mayStart: () {
          events.add('gate');
          return true;
        },
      );
      while (!events.contains('hook')) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(events, ['hook']);
      expect(adapter.requests.where(_isMutation), isEmpty);
      release.complete();
      await operation;
      expect(events, ['hook', 'hook-done', 'gate', 'send']);
      expect(adapter.requests.where(_isMutation), hasLength(1));
    });

    test('false gate and throwing hook send no mutation', () async {
      for (final throwFromHook in [false, true]) {
        final events = <String>[];
        var calls = 0;
        final adapter = FakeAdapter((request) {
          calls++;
          expect(_isMutation(request), isFalse);
          return jsonResponse(_reactionAccess());
        });
        final api = testApi(adapter);
        final target = (await api.workItemActivityReactionAccess(
          _summary,
          _discussion,
          _note,
          maxPages: 2,
        )).target!;

        final operation = api.setWorkItemActivityNoteReaction(
          target,
          'thumbsup',
          awarded: true,
          beforeMutation: () async {
            events.add('hook');
            if (throwFromHook) throw StateError('synthetic hook refusal');
          },
          mayStart: () {
            events.add('gate');
            return false;
          },
        );
        await expectLater(
          operation,
          throwsA(
            throwFromHook ? isA<StateError>() : _failure(FailureKind.cancelled),
          ),
        );
        expect(events, throwFromHook ? ['hook'] : ['hook', 'gate']);
        expect(calls, 2);
        expect(adapter.requests.where(_isMutation), isEmpty);
        api.close();
      }
    });
  });
}
