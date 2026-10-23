import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';

import '../support/fake_adapter.dart';

const deleteAccount = 'https://example.com/gitlab#7';
const deleteScope = AiWriteScope(
  accountKey: deleteAccount,
  grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 9)],
);
const deleteGlobalScope = AiWriteScope(
  accountKey: deleteAccount,
  grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
);

typedef DeleteCase = ({
  Map<String, Object?> args,
  String path,
  String name,
  String release,
  List<String> key,
  int prepareGets,
  int cap,
});

const deleteCases = <String, DeleteCase>{
  'deleteNote': (
    args: {'projectId': 9, 'resource': 'issues', 'iid': 3, 'noteId': 8},
    path: 'projects/9/issues/3/notes/8',
    name: '#3',
    release: '#3',
    key: ['project:9', 'workItem', '3', 'notes', '8'],
    prepareGets: 4,
    cap: 21,
  ),
  'deleteDiscussionNote': (
    args: {
      'projectId': 9,
      'resource': 'merge_requests',
      'iid': 3,
      'discussionId': 'abc',
      'noteId': 8,
    },
    path: 'projects/9/merge_requests/3/discussions/abc/notes/8',
    name: '!3',
    release: '!3',
    key: ['project:9', 'mergeRequest', '3', 'notes', '8'],
    prepareGets: 4,
    cap: 21,
  ),
  'deleteIssue': (
    args: {'projectId': 9, 'iid': 3},
    path: 'projects/9/issues/3',
    name: '#3',
    release: '#3',
    key: ['project:9', 'workItem', '3'],
    prepareGets: 3,
    cap: 17,
  ),
  'deleteMergeRequest': (
    args: {'projectId': 9, 'iid': 3},
    path: 'projects/9/merge_requests/3',
    name: '!3',
    release: '!3',
    key: ['project:9', 'mergeRequest', '3'],
    prepareGets: 3,
    cap: 17,
  ),
  'deleteLabel': (
    args: {'projectId': 9, 'labelId': 8},
    path: 'projects/9/labels/8',
    name: 'priority::high',
    release: 'team/example-9',
    key: ['project:9', 'labels', '8'],
    prepareGets: 3,
    cap: 17,
  ),
  'deleteMilestone': (
    args: {'projectId': 9, 'milestoneId': 8},
    path: 'projects/9/milestones/8',
    name: 'Release 1',
    release: 'team/example-9',
    key: ['project:9', 'milestones', '8'],
    prepareGets: 3,
    cap: 17,
  ),
  'deleteBoard': (
    args: {'projectId': 9, 'boardId': 8},
    path: 'projects/9/boards/8',
    name: 'Sprint board',
    release: 'team/example-9',
    key: ['project:9', 'boards', '8'],
    prepareGets: 3,
    cap: 17,
  ),
  'deleteBoardList': (
    args: {'projectId': 9, 'boardId': 8, 'listId': 6},
    path: 'projects/9/boards/8/lists/6',
    name: 'workflow::ready',
    release: 'team/example-9',
    key: ['project:9', 'boards', '8'],
    prepareGets: 4,
    cap: 21,
  ),
  'markAllTodosDone': (
    args: {},
    path: 'todos/mark_as_done',
    name: '@tester',
    release: '@tester',
    key: ['todos'],
    prepareGets: 2,
    cap: 9,
  ),
};

final class DeleteServer {
  final overrides = <String, Object?>{};
  bool hasMore = false;
  int? failureStatus;
  String updatedAt = '2026-10-23T00:00:00Z';
  late final adapter = FakeAdapter(respond);
  late final api = testApi(adapter);
  late final port = GitLabAiWritePort(api, accountKey: deleteAccount);

  ResponseBody respond(RequestOptions request) {
    final path = request.uri.path.split('/api/v4/').last;
    if (request.method != 'GET') {
      if (failureStatus case final status?) {
        return jsonResponse({}, status: status);
      }
      return ResponseBody.fromString('', 204);
    }
    if (overrides.containsKey(path)) return jsonResponse(overrides[path]);
    if (path == 'user') return jsonResponse({'id': 7, 'username': 'tester'});
    if (path == 'projects/9') return jsonResponse(projectJson(9));
    if (path == 'todos') {
      return jsonResponse(
        [
          {'id': 18},
          {'id': 19},
        ],
        headers: {
          if (hasMore) 'x-next-page': ['2'],
        },
      );
    }
    if (path == 'projects/9/issues/3' ||
        path == 'projects/9/merge_requests/3') {
      return jsonResponse({
        'id': 33,
        'iid': 3,
        'project_id': 9,
        'updated_at': updatedAt,
      });
    }
    if (path.endsWith('/discussions/abc')) {
      return jsonResponse({
        'id': 'abc',
        'notes': [
          {
            'id': 8,
            'updated_at': updatedAt,
            'author': {'id': 7, 'username': 'reviewer'},
            'body': 'First line\nSecond line\nThird line\nFourth line',
          },
        ],
      });
    }
    if (path.endsWith('/notes/8')) {
      return jsonResponse({
        'id': 8,
        'author': {'id': 7, 'username': 'reviewer'},
        'body': 'First line\nSecond line\nThird line\nFourth line',
        'updated_at': updatedAt,
      });
    }
    if (path == 'projects/9/labels/8') {
      return jsonResponse({'id': 8, 'name': 'priority::high'});
    }
    if (path == 'projects/9/milestones/8') {
      return jsonResponse({
        'id': 8,
        'project_id': 9,
        'title': 'Release 1',
        'updated_at': updatedAt,
      });
    }
    if (path == 'projects/9/boards/8') {
      return jsonResponse({'id': 8, 'name': 'Sprint board'});
    }
    if (path == 'projects/9/boards/8/lists/6') {
      return jsonResponse({
        'id': 6,
        'label': {'id': 22, 'name': 'workflow::ready'},
      });
    }
    if (path.endsWith('/mark_as_done')) return jsonResponse({'id': 18});
    return jsonResponse({}, status: 404);
  }

  AiWriteRequest request(
    String operation, {
    Map<String, Object?>? args,
    AiWriteScope? scope,
    String execution = 'p11-execution',
  }) => AiWriteRequest(
    operationId: operation,
    executionId: execution,
    scope:
        scope ??
        (operation == 'markAllTodosDone' ? deleteGlobalScope : deleteScope),
    arguments: args ?? deleteCases[operation]!.args,
  );

  int get mutations => adapter.requests.where((r) => r.method != 'GET').length;
}

void main() {
  late DeleteServer server;
  setUp(() => server = DeleteServer());
  tearDown(() => server.api.close());

  test(
    'p11 ledger has nine closed model-visible T4 rows and independent HTTP caps',
    () {
      expect(
        aiDeleteRows.map((r) => r.operationId).toSet(),
        deleteCases.keys.toSet(),
      );
      for (final entry in deleteCases.entries) {
        final row = productionAiLedger.find(entry.key)!;
        expect(row.baseTier, AiWriteTier.t4);
        expect(row.modelVisible, isTrue);
        expect(row.namedMethod, entry.key);
        expect(row.readback, isFalse);
        expect(row.editableField, isNull);
        expect(row.arguments.keys.toSet(), entry.value.args.keys.toSet());
        expect(row.arguments.values.every((a) => a.required), isTrue);
        expect(row.httpCap, entry.value.cap);
        expect(row.scopeClass, switch (entry.key) {
          'deleteIssue' => AiScopeClass.workItem,
          'deleteMergeRequest' => AiScopeClass.mergeRequest,
          'deleteNote' || 'deleteDiscussionNote' => AiScopeClass.resource,
          'markAllTodosDone' => AiScopeClass.accountGlobalOnly,
          _ => AiScopeClass.project,
        });
      }
      for (final row in aiDeleteRows) {
        expect(productionAiLedger.modelVisible, contains(row));
      }
    },
  );

  for (final entry in deleteCases.entries) {
    final operation = entry.key;
    final value = entry.value;
    test(
      'p11 $operation verifies names keys preview and one fixed mutation',
      () async {
        final prepared = await server.port.prepare(server.request(operation));
        expect(server.mutations, 0);
        expect(server.adapter.requests.length, value.prepareGets);
        expect(prepared.confirmName, value.name);
        expect(prepared.releaseName, value.release);
        expect(prepared.writeKeys.single.parts, [deleteAccount, ...value.key]);
        expect(prepared.dependencyKeys, isEmpty);
        expect(prepared.bindingDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
        final preview = prepared.preview as AiDeletePreview;
        expect(
          preview.targetName,
          operation == 'deleteNote' || operation == 'deleteDiscussionNote'
              ? ''
              : value.name,
        );
        final result =
            await server.port.commit(prepared, mayStart: () => true)
                as AiWriteSettled;
        expect(result.state, AiJournalState.succeeded);
        expect(result.projection, isEmpty);
        expect(server.mutations, 1);
        final sent = server.adapter.requests.last;
        expect(
          sent.method,
          operation == 'markAllTodosDone' ? 'POST' : 'DELETE',
        );
        expect(sent.uri.path, '/gitlab/api/v4/${value.path}');
        expect(sent.uri.queryParameters, isEmpty);
        expect(sent.data, isNull);
        expect(sent.followRedirects, isFalse);
        expect(
          await server.port.commit(prepared, mayStart: () => true),
          isA<AiWriteNotSent>(),
        );
        expect(server.mutations, 1);
      },
    );

    test(
      'p11 $operation rejects extra or missing arguments without mutation',
      () async {
        await expectLater(
          server.port.prepare(
            server.request(
              operation,
              args: {...value.args, 'url': 'https://other.example/delete'},
            ),
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(server.adapter.requests, isEmpty);
        for (final field in value.args.keys) {
          final args = {...value.args}..remove(field);
          await expectLater(
            server.port.prepare(server.request(operation, args: args)),
            throwsA(isA<ApiFailure>()),
          );
        }
        expect(server.mutations, 0);
      },
    );

    test(
      'p11 $operation refuses mayStart and foreign prepared capabilities',
      () async {
        final prepared = await server.port.prepare(server.request(operation));
        final other = GitLabAiWritePort(server.api, accountKey: deleteAccount);
        expect(
          await other.commit(prepared, mayStart: () => true),
          isA<AiWriteNotSent>(),
        );
        expect(
          await server.port.commit(prepared, mayStart: () => false),
          isA<AiWriteNotSent>(),
        );
        expect(server.mutations, 0);
      },
    );

    for (final status in [401, 403, 404, 500]) {
      test(
        'p11 $operation mutation $status classified without retry',
        () async {
          server.failureStatus = status;
          final prepared = await server.port.prepare(server.request(operation));
          final result =
              await server.port.commit(prepared, mayStart: () => true)
                  as AiWriteSettled;
          expect(
            result.state,
            status == 500
                ? AiJournalState.writeUncertain
                : AiJournalState.failedCertain,
          );
          expect(result.httpStatus, status);
          expect(server.mutations, 1);
        },
      );
    }
  }

  for (final operation in ['deleteNote', 'deleteDiscussionNote']) {
    for (final resource in ['issues', 'merge_requests']) {
      test('p11 $operation accepts exactly resource $resource', () async {
        final args = {...deleteCases[operation]!.args, 'resource': resource};
        final prepared = await server.port.prepare(
          server.request(operation, args: args),
        );
        expect(prepared.confirmName, resource == 'issues' ? '#3' : '!3');
      });
    }
    for (final resource in [
      'projects',
      '../issues',
      'issues/3/notes',
      '',
      42,
      null,
    ]) {
      test('p11 $operation rejects resource $resource before HTTP', () async {
        await expectLater(
          server.port.prepare(
            server.request(
              operation,
              args: {...deleteCases[operation]!.args, 'resource': resource},
            ),
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(server.adapter.requests, isEmpty);
      });
    }
  }

  for (final entry in <String, Object?>{
    'user': {'id': 99, 'username': 'tester'},
    'projects/9': {...projectJson(9), 'id': 10},
    'projects/9/issues/3': {'id': 33, 'iid': 3, 'project_id': 10},
    'projects/9/issues/3/notes/8': {'id': 99},
  }.entries) {
    test('p11 deleteNote refuses mismatched ${entry.key}', () async {
      server.overrides[entry.key] = entry.value;
      await expectLater(
        server.port.prepare(server.request('deleteNote')),
        throwsA(isA<ApiFailure>()),
      );
      expect(server.mutations, 0);
    });
  }

  for (final entry in <String, Object?>{
    'wrongDiscussion': {
      'id': 'other',
      'notes': [
        {'id': 8},
      ],
    },
    'missingNote': {
      'id': 'abc',
      'notes': [
        {'id': 99},
      ],
    },
    'duplicateNote': {
      'id': 'abc',
      'notes': [
        {'id': 8},
        {'id': 8},
      ],
    },
    'unreadableNotes': {'id': 'abc', 'notes': null},
  }.entries) {
    test('p11 deleteDiscussionNote rejects ${entry.key}', () async {
      server.overrides['projects/9/merge_requests/3/discussions/abc'] =
          entry.value;
      await expectLater(
        server.port.prepare(server.request('deleteDiscussionNote')),
        throwsA(isA<ApiFailure>()),
      );
      expect(server.mutations, 0);
    });
  }

  for (final operation in [
    'deleteLabel',
    'deleteMilestone',
    'deleteBoard',
    'deleteBoardList',
  ]) {
    test(
      'p11 $operation rejects wrong id and absent confirmation name',
      () async {
        final value = deleteCases[operation]!;
        server.overrides[value.path] = {
          'id': 999,
          'name': 'wrong',
          'title': 'wrong',
        };
        await expectLater(
          server.port.prepare(server.request(operation)),
          throwsA(isA<ApiFailure>()),
        );
        for (final name in [null, '', '   ', 7]) {
          server.overrides[value.path] = {
            'id': operation == 'deleteBoardList' ? 6 : 8,
            'name': name,
            'title': name,
            'label': {'id': 22, 'name': name},
          };
          await expectLater(
            server.port.prepare(server.request(operation)),
            throwsA(isA<ApiFailure>()),
          );
        }
        expect(server.mutations, 0);
      },
    );
  }

  test('p11 first todo page is bounded and exposes count and more', () async {
    server.hasMore = true;
    final prepared = await server.port.prepare(
      server.request('markAllTodosDone'),
    );
    final preview = prepared.preview as AiDeletePreview;
    expect(preview.count, 2);
    expect(preview.hasMore, isTrue);
    final reads = server.adapter.requests
        .where((r) => r.uri.path.endsWith('/todos'))
        .toList();
    expect(reads, hasLength(1));
    expect(reads.single.uri.queryParameters, {
      'per_page': '100',
      'state': 'pending',
    });
  });

  test('p11 empty todo page is accurately previewed', () async {
    server.overrides['todos'] = <Object?>[];
    final prepared = await server.port.prepare(
      server.request('markAllTodosDone'),
    );
    final preview = prepared.preview as AiDeletePreview;
    expect(preview.count, 0);
    expect(preview.hasMore, isFalse);
  });

  test('p11 global and resource grants cannot expand scope', () async {
    for (final operation in deleteCases.keys) {
      final global = operation == 'markAllTodosDone';
      await expectLater(
        server.port.prepare(
          server.request(
            operation,
            scope: global ? deleteScope : deleteGlobalScope,
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
    }
    expect(server.mutations, 0);
  });

  test(
    'p11 issue origin can delete its parent and notes but no metadata',
    () async {
      const scope = AiWriteScope(
        accountKey: deleteAccount,
        grants: [
          AiScopeGrant(kind: AiScopeKind.workItem, projectId: 9, iid: 3),
        ],
      );
      for (final operation in ['deleteIssue', 'deleteNote']) {
        await server.port.prepare(server.request(operation, scope: scope));
      }
      for (final operation in [
        'deleteMergeRequest',
        'deleteLabel',
        'deleteBoard',
      ]) {
        await expectLater(
          server.port.prepare(server.request(operation, scope: scope)),
          throwsA(isA<ApiFailure>()),
        );
      }
    },
  );

  test('p11 changed target revision changes memory-only binding', () async {
    final first = await server.port.prepare(server.request('deleteIssue'));
    server.updatedAt = '2026-10-23T01:00:00Z';
    final second = await server.port.prepare(server.request('deleteIssue'));
    expect(first.bindingDigest, isNot(second.bindingDigest));
    expect(first.journal.updatedAt, '2026-10-23T00:00:00Z');
    expect(second.journal.updatedAt, server.updatedAt);
  });

  test('p11 root and discussion aliases share the numeric note key', () async {
    final root = await server.port.prepare(server.request('deleteNote'));
    final reply = await server.port.prepare(
      server.request(
        'deleteDiscussionNote',
        args: {
          ...deleteCases['deleteDiscussionNote']!.args,
          'resource': 'issues',
        },
      ),
    );
    expect(root.writeKeys, reply.writeKeys);
  });

  for (final operation in deleteCases.keys) {
    test('p11 $operation rejects stale account identity', () async {
      server.overrides['user'] = {'id': 99, 'username': 'tester'};
      await expectLater(
        server.port.prepare(server.request(operation)),
        throwsA(isA<ApiFailure>()),
      );
      expect(server.mutations, 0);
    });

    for (final field in deleteCases[operation]!.args.keys.where(
      (k) => k != 'discussionId' && (k.endsWith('Id') || k == 'iid'),
    )) {
      test(
        'p11 $operation validates positive integer $field before HTTP',
        () async {
          for (final value in [0, -1, 1.5, '8', true, null]) {
            await expectLater(
              server.port.prepare(
                server.request(
                  operation,
                  args: {...deleteCases[operation]!.args, field: value},
                ),
              ),
              throwsA(isA<ApiFailure>()),
            );
          }
          expect(server.adapter.requests, isEmpty);
        },
      );
    }
  }

  for (final operation in [
    'deleteIssue',
    'deleteMergeRequest',
    'deleteNote',
    'deleteDiscussionNote',
  ]) {
    test('p11 $operation checks both parent project and iid', () async {
      final resource =
          operation == 'deleteMergeRequest' ||
              operation == 'deleteDiscussionNote'
          ? 'merge_requests'
          : 'issues';
      for (final parent in [
        {'id': 33, 'iid': 99, 'project_id': 9},
        {'id': 33, 'iid': 3, 'project_id': 99},
      ]) {
        server.overrides['projects/9/$resource/3'] = parent;
        await expectLater(
          server.port.prepare(server.request(operation)),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(server.mutations, 0);
    });
  }

  for (final operation in [
    'deleteLabel',
    'deleteMilestone',
    'deleteBoard',
    'deleteBoardList',
  ]) {
    test(
      'p11 $operation rejects contradictory target project ownership',
      () async {
        final path = deleteCases[operation]!.path;
        server.overrides[path] = {
          'id': operation == 'deleteBoardList' ? 6 : 8,
          'project_id': 99,
          'name': 'synthetic',
          'title': 'synthetic',
          'label': {'id': 22, 'name': 'synthetic'},
        };
        await expectLater(
          server.port.prepare(server.request(operation)),
          throwsA(isA<ApiFailure>()),
        );
        expect(server.mutations, 0);
      },
    );
  }

  test('p11 board list checks the board and a named label list', () async {
    for (final value in [
      {
        'id': 6,
        'board_id': 99,
        'label': {'id': 22, 'name': 'ready'},
      },
      {'id': 6, 'label': null},
      {
        'id': 6,
        'label': {'id': 0, 'name': 'ready'},
      },
    ]) {
      server.overrides['projects/9/boards/8/lists/6'] = value;
      await expectLater(
        server.port.prepare(server.request('deleteBoardList')),
        throwsA(isA<ApiFailure>()),
      );
    }
    server.overrides.remove('projects/9/boards/8/lists/6');
    server.overrides['projects/9/boards/8'] = {'id': 99};
    await expectLater(
      server.port.prepare(server.request('deleteBoardList')),
      throwsA(isA<ApiFailure>()),
    );
    expect(server.mutations, 0);
  });

  for (final discussion in ['', '../abc', 'abc/notes/8', 'abc?x=1']) {
    test(
      'p11 rejects malformed discussion segment $discussion before HTTP',
      () async {
        await expectLater(
          server.port.prepare(
            server.request(
              'deleteDiscussionNote',
              args: {
                ...deleteCases['deleteDiscussionNote']!.args,
                'discussionId': discussion,
              },
            ),
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(server.adapter.requests, isEmpty);
      },
    );
  }

  test('p11 no username means no account-wide confirmation', () async {
    server.overrides['user'] = {'id': 7, 'username': '   '};
    await expectLater(
      server.port.prepare(server.request('markAllTodosDone')),
      throwsA(isA<ApiFailure>()),
    );
    expect(server.mutations, 0);
  });

  for (final operation in deleteCases.keys) {
    for (final status in [403, 404, 500]) {
      test(
        'p11 $operation target read failure $status never mutates',
        () async {
          final adapter = FakeAdapter(
            (request) => jsonResponse({}, status: status),
          );
          final api = testApi(adapter);
          try {
            final port = GitLabAiWritePort(api, accountKey: deleteAccount);
            await expectLater(
              port.prepare(server.request(operation)),
              throwsA(isA<ApiFailure>()),
            );
            expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
          } finally {
            api.close();
          }
        },
      );
    }
  }
}
