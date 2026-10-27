import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';
import 'support/strict_group_owner.dart';

const _group = 'gid://gitlab/Group/2';
const _groupPath = 'team/sub';
const _target = 'gid://gitlab/WorkItem/91';
const _actor = 'gid://gitlab/User/7';
const _untilText = '2030-01-01T00:00:00Z';

WorkItemGraphSummary _summary() => WorkItemGraphSummary(
  id: _target,
  iid: 7,
  title: 'Group item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  project: null,
  namespace: const GraphResourceRef(id: _group, fullPath: _groupPath),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/1',
    name: 'Task',
  ),
);

Map<String, Object?> _todo({required bool snoozed, String problem = 'exact'}) {
  final target = <String, Object?>{
    '__typename': 'WorkItem',
    'workItemId': _target,
    'iid': '7',
    'workItemProject': null,
    'namespace': {'id': _group, 'fullPath': _groupPath},
  };
  final todo = <String, Object?>{
    'id': 'gid://gitlab/Todo/19',
    'targetType': 'WORKITEM',
    'snoozedUntil': snoozed ? _untilText : null,
    'project': null,
    'group': {'id': _group, 'fullPath': _groupPath},
    'targetEntity': target,
  };
  switch (problem) {
    case 'missingTodoProject':
      todo.remove('project');
    case 'missingTargetProject':
      target.remove('workItemProject');
    case 'todoProject':
      todo['project'] = {
        'id': 'gid://gitlab/Project/2',
        'fullPath': 'team/sub',
      };
    case 'targetProject':
      target['workItemProject'] = {
        'id': 'gid://gitlab/Project/2',
        'fullPath': 'team/sub',
      };
    case 'foreignNamespace':
      target['namespace'] = {
        'id': 'gid://gitlab/Group/3',
        'fullPath': 'team/foreign',
      };
      todo['group'] = {
        'id': 'gid://gitlab/Group/3',
        'fullPath': 'team/foreign',
      };
    case 'foreignPath':
      target['namespace'] = {'id': _group, 'fullPath': 'team/foreign'};
      todo['group'] = {'id': _group, 'fullPath': 'team/foreign'};
    case 'foreignItem':
      target['workItemId'] = 'gid://gitlab/WorkItem/92';
    case 'foreignIid':
      target['iid'] = '8';
    case 'wrongState':
      todo['snoozedUntil'] = snoozed ? '2031-01-01T00:00:00Z' : _untilText;
  }
  return todo;
}

Object _page(
  Map<String, Object?> todo, {
  bool missing = false,
  String actor = _actor,
}) => {
  'data': {
    'currentUser': {
      'id': actor,
      'todos': {
        'nodes': missing ? <Object?>[] : [todo],
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      },
    },
  },
};

enum _Outcome { refused, uncertain, success }

// This is a contract harness for future G-P13, not the production family.
// The mutation API must remain a single request: this caller explicitly owns
// the preflight and the budgeted independent readback.
Future<_Outcome> _groupWrite(
  GitLabApi api, {
  required bool snooze,
  required bool hasReadback,
}) async {
  if (!hasReadback) return _Outcome.refused;
  final owner = strictGroupOwner(api, _summary());
  final expected = DateTime.parse(_untilText);
  Future<bool> read(bool isSnoozed) async {
    final page = await (isSnoozed
        ? api.snoozedTodosForUnsnooze(
            allowGroupTargets: true,
            strictGroupOwner: owner,
            strictGroupTodoId: 19,
          )
        : api.pendingTodosForSnooze(
            allowGroupTargets: true,
            strictGroupOwner: owner,
            strictGroupTodoId: 19,
          ));
    final matching = page.items.where((item) => item['id'] == 19).toList();
    if (page.actorId != _actor || matching.length != 1) {
      return false;
    }
    final value = matching.single['snoozed_until'];
    return isSnoozed
        ? value is String && DateTime.parse(value).isAtSameMomentAs(expected)
        : value == null;
  }

  try {
    if (!await read(!snooze)) return _Outcome.refused;
  } catch (_) {
    return _Outcome.refused;
  }
  try {
    if (snooze) {
      final ack = await api.snoozeTodo(19, expected);
      if (!ack.isAtSameMomentAs(expected)) return _Outcome.uncertain;
    } else {
      await api.unsnoozeTodo(19);
    }
    return await read(snooze) ? _Outcome.success : _Outcome.uncertain;
  } catch (_) {
    return _Outcome.uncertain;
  }
}

void main() {
  for (final snooze in [true, false]) {
    final operation = snooze ? 'snooze' : 'unsnooze';
    for (final problem in [
      'exact',
      'missingTodoProject',
      'missingTargetProject',
      'todoProject',
      'targetProject',
      'foreignNamespace',
      'foreignPath',
      'foreignItem',
      'foreignIid',
      'wrongState',
      'missingTodo',
      'foreignActor',
      'throws',
      'cancelled',
    ]) {
      test('group $operation D29 caller readback $problem', () async {
        var reads = 0;
        var mutations = 0;
        final adapter = FakeAdapter((request) {
          final query = (request.data as Map)['query'] as String;
          if (query.trimLeft().startsWith('mutation ')) {
            mutations++;
            final field = snooze ? 'todoSnooze' : 'todoUnSnooze';
            return jsonResponse({
              'data': {
                field: {
                  'todo': {
                    'id': 'gid://gitlab/Todo/19',
                    'snoozedUntil': snooze ? _untilText : null,
                  },
                  'errors': <Object>[],
                },
              },
            });
          }
          reads++;
          final postSend = reads == 2;
          expect(query, contains('isSnoozed: ${postSend ? snooze : !snooze}'));
          if (postSend && problem == 'throws') {
            throw StateError('readback failed');
          }
          if (postSend && problem == 'cancelled') {
            throw DioException(
              requestOptions: request,
              type: DioExceptionType.cancel,
            );
          }
          return jsonResponse(
            _page(
              _todo(
                snoozed: postSend ? snooze : !snooze,
                problem: postSend ? problem : 'exact',
              ),
              missing: postSend && problem == 'missingTodo',
              actor: postSend && problem == 'foreignActor'
                  ? 'gid://gitlab/User/8'
                  : _actor,
            ),
          );
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final result = await _groupWrite(
          api,
          snooze: snooze,
          hasReadback: true,
        );
        expect(
          result,
          problem == 'exact' ? _Outcome.success : _Outcome.uncertain,
        );
        expect(mutations, 1, reason: 'never replay a post-send failure');
        expect(reads, 2, reason: 'one preflight and one explicit readback');
        expect(adapter.requests, hasLength(3));
      });
    }

    for (final problem in ['wrongId', 'wrongTime', 'missingTime']) {
      test(
        'group $operation bad acknowledgement $problem is uncertain',
        () async {
          var reads = 0;
          var mutations = 0;
          final adapter = FakeAdapter((request) {
            final query = (request.data as Map)['query'] as String;
            if (query.trimLeft().startsWith('mutation ')) {
              mutations++;
              final field = snooze ? 'todoSnooze' : 'todoUnSnooze';
              return jsonResponse({
                'data': {
                  field: {
                    'todo': {
                      'id': problem == 'wrongId'
                          ? 'gid://gitlab/Todo/20'
                          : 'gid://gitlab/Todo/19',
                      if (problem != 'missingTime')
                        'snoozedUntil': problem == 'wrongTime'
                            ? '2031-01-01T00:00:00Z'
                            : snooze
                            ? _untilText
                            : null,
                    },
                    'errors': <Object>[],
                  },
                },
              });
            }
            reads++;
            return jsonResponse(_page(_todo(snoozed: !snooze)));
          });
          final api = testApi(adapter);
          addTearDown(api.close);
          expect(
            await _groupWrite(api, snooze: snooze, hasReadback: true),
            _Outcome.uncertain,
          );
          expect(reads, 1);
          expect(mutations, 1);
          expect(adapter.requests, hasLength(2));
        },
      );
    }

    test('group $operation refuses before send without readback', () async {
      final adapter = FakeAdapter((_) => throw StateError('no requests'));
      final api = testApi(adapter);
      addTearDown(api.close);
      expect(
        await _groupWrite(api, snooze: snooze, hasReadback: false),
        _Outcome.refused,
      );
      expect(adapter.requests, isEmpty);
    });

    test(
      'group $operation refuses malformed strict preflight before send',
      () async {
        final adapter = FakeAdapter(
          (_) => jsonResponse(
            _page(_todo(snoozed: !snooze, problem: 'missingTargetProject')),
          ),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        expect(
          await _groupWrite(api, snooze: snooze, hasReadback: true),
          _Outcome.refused,
        );
        expect(adapter.requests, hasLength(1));
        expect(
          ((adapter.requests.single.data as Map)['query'] as String),
          startsWith('query '),
        );
      },
    );
  }

  for (final (name, fields, succeeds) in <(String, Json, bool)>[
    ('key present with null succeeds', {'snoozedUntil': null}, true),
    ('key omitted is invalid', {}, false),
    (
      'key present with timestamp is invalid',
      {'snoozedUntil': '2030-01-01T00:00:00Z'},
      false,
    ),
  ]) {
    test('unsnoozeTodo acknowledgement: $name', () async {
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        expect(request.method, 'POST');
        expect(request.uri.path, '/gitlab/api/graphql');
        expect(body['query'], contains('todoUnSnooze(input: {id: \$id})'));
        expect(body['query'], contains('todo { id snoozedUntil }'));
        expect(body['variables'], {'id': 'gid://gitlab/Todo/7'});
        return jsonResponse({
          'data': {
            'todoUnSnooze': {
              'todo': {'id': 'gid://gitlab/Todo/7', ...fields},
              'errors': <Object>[],
            },
          },
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      if (succeeds) {
        await expectLater(api.unsnoozeTodo(7), completes);
      } else {
        await expectLater(
          api.unsnoozeTodo(7),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.invalidResponse,
            ),
          ),
        );
      }
      expect(adapter.requests, hasLength(1), reason: 'never replay a mutation');
    });
  }
}
