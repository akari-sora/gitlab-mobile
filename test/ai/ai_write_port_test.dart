import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';

import '../support/fake_adapter.dart';

const account = 'https://example.com/gitlab#7';
const scope = AiWriteScope(
  accountKey: account,
  grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 9)],
);

AiWriteRequest request(
  String op,
  Map<String, Object?> args, {
  AiWriteScope granted = scope,
}) => AiWriteRequest(
  operationId: op,
  executionId: 'execution-1',
  scope: granted,
  arguments: args,
);

ResponseBody preflight(RequestOptions r) {
  final path = r.uri.path;
  if (path.endsWith('/user')) {
    return jsonResponse({'id': 7, 'username': 'tester'});
  }
  if (path.endsWith('/projects/9')) return jsonResponse(projectJson(9));
  if (path.endsWith('/issues/3') || path.endsWith('/merge_requests/3')) {
    return jsonResponse({'id': 33, 'iid': 3, 'project_id': 9});
  }
  if (path.endsWith('/notes/8')) {
    return jsonResponse({
      'id': 8,
      'author': {'id': 7},
    });
  }
  return jsonResponse({'id': 8, 'iid': 3});
}

// Observe entry into the real synchronous request boundary; the adapter itself
// runs later inside Dio and would incorrectly detect Dio's internal microtasks.
final class _ObservedDio extends DioForNative {
  _ObservedDio(this.events);
  final List<String> events;

  @override
  Future<Response<T>> requestUri<T>(
    Uri uri, {
    Object? data,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) {
    if (options?.method != 'GET') events.add('mutation');
    return super.requestUri<T>(
      uri,
      data: data,
      cancelToken: cancelToken,
      options: options,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
    );
  }
}

void main() {
  test('accountGlobal markTodoDone retains null owner compatibility', () async {
    final adapter = FakeAdapter((r) {
      if (r.uri.path.endsWith('/todos') && r.method == 'GET') {
        return jsonResponse([
          {'id': 18, 'project': null, 'target_type': 'Unknown', 'target': null},
        ]);
      }
      if (r.method != 'GET') return jsonResponse({'id': 18});
      return preflight(r);
    });
    final api = testApi(adapter);
    final writePort = GitLabAiWritePort(api, accountKey: account);
    final prepared = await writePort.prepare(
      request(
        'markTodoDone',
        {'todoId': 18},
        granted: const AiWriteScope(
          accountKey: account,
          grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
        ),
      ),
    );
    expect(prepared.todoTarget, isNull);
    expect(prepared.groupTodoTarget, isNull);
    expect(
      (await writePort.commit(prepared, mayStart: () => true)).mutationCount,
      1,
    );
    api.close();
  });

  test('graph todo cannot bind two owners', () {
    final writeRequest = request('snoozeTodo', {
      'todoId': 18,
      'until': '2030-01-01T00:00:00Z',
    });
    expect(
      () => AiWritePrepared.graph(
        request: writeRequest,
        releaseName: '@tester',
        writeKeys: {},
        todoTarget: (projectId: 9, resource: 'issues', iid: 3),
        groupTodoTarget: (
          groupId: 5,
          groupFullPath: 'team',
          iid: 3,
          workItemGid: 'gid://gitlab/WorkItem/33',
        ),
        mutation: (_) async => null,
      ),
      throwsA(isA<AiWriteRefused>()),
    );
  });
  test(
    '§15 row29 mayStart immediately precedes mutation; one-shot permit',
    () async {
      final events = <String>[];
      final adapter = FakeAdapter(preflight);
      final dio = _ObservedDio(events)..httpClientAdapter = adapter;
      final api = GitLabApi(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        token: 'synthetic-test-token',
        dio: dio,
      );
      final port = GitLabAiWritePort(api, accountKey: account);
      final p = await port.prepare(
        request('createNote', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'body': 'synthetic',
        }),
      );
      scheduleMicrotask(() => events.add('microtask'));
      final result = await port.commit(
        p,
        mayStart: () {
          events.add('mayStart');
          return true;
        },
      );
      expect(events.take(2), ['mayStart', 'mutation']);
      expect(
        result,
        isA<AiWriteSettled>().having(
          (v) => v.state,
          'state',
          AiJournalState.succeeded,
        ),
      );
      expect(await port.commit(p, mayStart: () => true), isA<AiWriteNotSent>());
      expect(adapter.requests.where((r) => r.method != 'GET'), hasLength(1));
      api.close();
    },
  );

  test('§15 row29 false or foreign permit gives zero mutations', () async {
    final adapter = FakeAdapter(preflight);
    final api = testApi(adapter);
    final port = GitLabAiWritePort(api, accountKey: account);
    final p = await port.prepare(
      request('setStar', {'projectId': 9, 'starred': true}),
    );
    final foreign = GitLabAiWritePort(api, accountKey: account);
    expect(
      await foreign.commit(p, mayStart: () => true),
      isA<AiWriteNotSent>(),
    );
    expect(await port.commit(p, mayStart: () => false), isA<AiWriteNotSent>());
    expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
    api.close();
  });

  for (final status in [
    400,
    401,
    403,
    404,
    409,
    412,
    422,
    429,
    500,
    503,
    302,
  ]) {
    test('§15 row5 REST mutation status $status classification', () async {
      final adapter = FakeAdapter(
        (r) =>
            r.method == 'GET' ? preflight(r) : jsonResponse({}, status: status),
      );
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final p = await port.prepare(
        request('createNote', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'body': 'synthetic',
        }),
      );
      final result =
          await port.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(
        result.state,
        status < 300 || status >= 500 || status == 302
            ? AiJournalState.writeUncertain
            : AiJournalState.failedCertain,
      );
      expect(result.httpStatus, status);
      expect(result.mutationCount, 1);
      expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
      api.close();
    });
  }

  for (final mode in ['empty', 'malformed', 'cancelled', 'transport']) {
    test('§15 row5 $mode acknowledgement is uncertain', () async {
      final adapter = FakeAdapter((r) {
        if (r.method == 'GET') return preflight(r);
        if (mode == 'empty') return ResponseBody.fromString('', 201);
        if (mode == 'malformed') {
          return ResponseBody.fromString('bad-json', 201);
        }
        throw DioException(
          requestOptions: r,
          type: mode == 'cancelled'
              ? DioExceptionType.cancel
              : DioExceptionType.sendTimeout,
        );
      });
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final p = await port.prepare(
        request('createNote', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'body': 'synthetic',
        }),
      );
      final result =
          await port.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(result.state, AiJournalState.writeUncertain);
      api.close();
    });
  }

  test(
    '§15 row5 mutation 201 followed by readback 401 stays uncertain',
    () async {
      var mutated = false;
      final adapter = FakeAdapter((r) {
        if (r.method == 'POST') {
          mutated = true;
          return jsonResponse({'id': 8}, status: 201);
        }
        if (mutated) return jsonResponse({}, status: 401);
        return preflight(r);
      });
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final p = await port.prepare(
        request('createNote', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'body': 'synthetic',
        }),
      );
      final result =
          await port.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(result.state, AiJournalState.writeUncertain);
      expect(result.httpStatus, isNull);
      expect(result.resultCode, 'readbackFailed');
      expect(await port.commit(p, mayStart: () => true), isA<AiWriteNotSent>());
      expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
      api.close();
    },
  );

  test(
    '§15 row10 unknown operations/keys, escaped scope and foreign author rejected',
    () async {
      final adapter = FakeAdapter(
        (r) => r.uri.path.endsWith('/notes/8')
            ? jsonResponse({
                'id': 8,
                'author': {'id': 999},
              })
            : preflight(r),
      );
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final invalid = [
        request('writeRecord', {'projectId': 9}),
        request('setStar', {
          'projectId': 9,
          'starred': true,
          'url': 'https://elsewhere.invalid',
        }),
        request('createNote', {
          'projectId': 9,
          'resource': '../projects',
          'iid': 3,
          'body': 'x',
        }),
        request('updateNote', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'noteId': 8,
          'body': 'x',
        }),
        request('updateIssue', {
          'projectId': 9,
          'iid': 3,
          'fields': {'due_date': '2026-01-01'},
        }),
        request('updateIssue', {
          'projectId': 9,
          'iid': 3,
          'fields': {'issue_type': 'task'},
        }),
        request('createMergeRequest', {
          'projectId': 9,
          'fields': {'title': 'x', 'target_project_id': 10},
        }),
        request('setStar', {
          'projectId': 9,
          'starred': true,
        }, granted: const AiWriteScope(accountKey: account, grants: [])),
        request(
          'createIssue',
          {
            'projectId': 9,
            'fields': {'title': 'x'},
          },
          granted: const AiWriteScope(
            accountKey: account,
            grants: [
              AiScopeGrant(kind: AiScopeKind.workItem, projectId: 9, iid: 3),
            ],
          ),
        ),
        request(
          'updateIssue',
          {
            'projectId': 9,
            'iid': 4,
            'fields': {'title': 'x'},
          },
          granted: const AiWriteScope(
            accountKey: account,
            grants: [
              AiScopeGrant(kind: AiScopeKind.workItem, projectId: 9, iid: 3),
            ],
          ),
        ),
      ];
      for (final r in invalid) {
        await expectLater(port.prepare(r), throwsA(isA<ApiFailure>()));
      }
      expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
      api.close();
    },
  );

  test('§15 row10 frozen nested fields survive caller mutation', () async {
    final original = <String, Object?>{
      'title': 'before',
      'assignee_ids': <int>[7],
    };
    final r = request('updateIssue', {
      'projectId': 9,
      'iid': 3,
      'fields': original,
    });
    original['title'] = 'after';
    (original['assignee_ids']! as List<int>).add(999);
    final adapter = FakeAdapter(preflight);
    final api = testApi(adapter);
    final port = GitLabAiWritePort(api, accountKey: account);
    final p = await port.prepare(r);
    await port.commit(p, mayStart: () => true);
    final body =
        adapter.requests.singleWhere((r) => r.method == 'PUT').data! as Map;
    expect(body['title'], 'before');
    expect(body['assignee_ids'], [7]);
    api.close();
  });

  test(
    '§15 row5 creation locks ignore payload; board card shares issue key',
    () async {
      final adapter = FakeAdapter(preflight);
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final one = await port.prepare(
        request('createNote', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'body': 'one',
        }),
      );
      final two = await port.prepare(
        request('createNote', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'body': 'two',
        }),
      );
      expect(one.writeKeys, two.writeKeys);
      final issue = await port.prepare(
        request('updateIssue', {
          'projectId': 9,
          'iid': 3,
          'fields': {'labels': 'a'},
        }),
      );
      final card = await port.prepare(
        request('moveBoardCard', {
          'projectId': 9,
          'iid': 3,
          'fields': {'labels': 'b'},
        }),
      );
      expect(issue.writeKeys, card.writeKeys);
      expect(issue.writeKeys.single.intersects(one.writeKeys.single), isTrue);
      api.close();
    },
  );

  test(
    '§15 row29 separately prepared duplicate execution cannot dispatch twice',
    () async {
      final adapter = FakeAdapter(preflight);
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final r = request('setStar', {'projectId': 9, 'starred': true});
      final one = await port.prepare(r);
      final two = await port.prepare(r);
      await port.commit(one, mayStart: () => true);
      expect(
        await port.commit(two, mayStart: () => true),
        isA<AiWriteNotSent>(),
      );
      expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
      api.close();
    },
  );

  test(
    '§15 row5 unrelated project writes retain separate isolation keys',
    () async {
      final adapter = FakeAdapter(preflight);
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final star = await port.prepare(
        request('setStar', {'projectId': 9, 'starred': true}),
      );
      final label = await port.prepare(
        request('createLabel', {
          'projectId': 9,
          'fields': {'name': 'x', 'color': '#ffffff'},
        }),
      );
      final note = await port.prepare(
        request('createNote', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'body': 'x',
        }),
      );
      final sibling = await port.prepare(
        request('setSubscribed', {
          'projectId': 9,
          'resource': 'issues',
          'iid': 3,
          'subscribed': true,
        }),
      );
      bool intersects(AiWritePrepared a, AiWritePrepared b) => {
        ...a.writeKeys,
        ...a.dependencyKeys,
      }.any((key) => {...b.writeKeys, ...b.dependencyKeys}.any(key.intersects));
      expect(intersects(star, label), isFalse);
      expect(intersects(note, sibling), isFalse);
      api.close();
    },
  );

  test('§15 row23 upload filename must satisfy canonical validation', () async {
    final adapter = FakeAdapter(preflight);
    final api = testApi(adapter);
    final port = GitLabAiWritePort(api, accountKey: account);
    await expectLater(
      port.prepare(
        AiWriteRequest(
          operationId: 'upload_attachment',
          executionId: 'bad-name',
          scope: scope,
          arguments: {'projectId': 9, 'filename': 'bad%name.txt'},
          uploadBytes: [1],
        ),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
    api.close();
  });

  for (final refreshThrows in [false, true]) {
    test(
      '§15 row5 port retains OAuth refresh provenance (throws=$refreshThrows)',
      () async {
        final adapter = FakeAdapter((r) {
          if (r.uri.path.endsWith('/oauth/token')) {
            return jsonResponse({
              'access_token': 'new-access',
              'refresh_token': 'new-refresh',
              'token_type': 'bearer',
              'expires_in': 7200,
            });
          }
          if (r.method == 'POST') return jsonResponse({}, status: 401);
          return preflight(r);
        });
        final dio = Dio()..httpClientAdapter = adapter;
        final instance = GitLabInstance.parse('https://example.com/gitlab');
        final api = GitLabApi(
          instance: instance,
          dio: dio,
          credential: const OAuthCredential(
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            clientId: 'synthetic-app',
          ),
          oauth: OAuthTokenClient(
            instance: instance,
            clientId: 'synthetic-app',
            dio: dio,
          ),
          onOAuthRotated: (_) async {
            if (refreshThrows) throw StateError('synthetic store unavailable');
          },
        );
        final port = GitLabAiWritePort(api, accountKey: account);
        final p = await port.prepare(
          request('createNote', {
            'projectId': 9,
            'resource': 'issues',
            'iid': 3,
            'body': 'synthetic',
          }),
        );
        final result =
            await port.commit(p, mayStart: () => true) as AiWriteSettled;
        expect(result.state, AiJournalState.failedCertain);
        expect(result.httpStatus, 401);
        expect(
          result.resultCode,
          refreshThrows ? 'sessionExpired' : 'refreshSucceeded',
        );
        expect(
          adapter.requests.where(
            (r) => r.method == 'POST' && r.uri.path.endsWith('/notes'),
          ),
          hasLength(1),
        );
        api.close();
      },
    );
  }

  // §15 rows10/21: every production REST row reaches exactly one named write.
  final cases = <String, Map<String, Object?>>{
    'setStar': {'starred': true},
    'setSubscribed': {'resource': 'issues', 'iid': 3, 'subscribed': true},
    'markTodoDone': {'todoId': 18},
    'addAwardEmoji': {'resource': 'issues', 'iid': 3, 'name': 'thumbsup'},
    'removeAwardEmoji': {'resource': 'issues', 'iid': 3, 'awardId': 8},
    'createNote': {'resource': 'issues', 'iid': 3, 'body': 'synthetic'},
    'updateNote': {
      'resource': 'issues',
      'iid': 3,
      'noteId': 8,
      'body': 'synthetic',
    },
    'createIssue': {
      'fields': {'title': 'synthetic'},
    },
    'updateIssue': {
      'iid': 3,
      'fields': {'title': 'synthetic'},
    },
    'createMergeRequest': {
      'fields': {
        'title': 'synthetic',
        'source_branch': 'feature',
        'target_branch': 'main',
      },
    },
    'updateMergeRequest': {
      'iid': 3,
      'fields': {'title': 'synthetic'},
    },
    'unapproveMergeRequest': {'iid': 3},
    'createTodo': {'resource': 'issues', 'iid': 3},
    'createDiscussion': {
      'resource': 'merge_requests',
      'iid': 3,
      'body': 'synthetic',
    },
    'createDiscussionNote': {
      'resource': 'merge_requests',
      'iid': 3,
      'discussionId': 'abc',
      'body': 'synthetic',
    },
    'updateDiscussionNote': {
      'resource': 'merge_requests',
      'iid': 3,
      'discussionId': 'abc',
      'noteId': 8,
      'body': 'synthetic',
    },
    'setDiscussionResolved': {
      'resource': 'merge_requests',
      'iid': 3,
      'discussionId': 'abc',
      'resolved': true,
    },
    'createDraftNote': {'iid': 3, 'body': 'synthetic'},
    'updateDraftNote': {'iid': 3, 'noteId': 8, 'body': 'synthetic'},
    'createLabel': {
      'fields': {'name': 'synthetic', 'color': '#ffffff'},
    },
    'updateLabel': {
      'labelId': 8,
      'fields': {'color': '#000000'},
    },
    'createMilestone': {
      'fields': {'title': 'synthetic'},
    },
    'updateMilestone': {
      'milestoneId': 8,
      'fields': {'title': 'synthetic'},
    },
    'setMilestoneState': {'milestoneId': 8, 'stateEvent': 'close'},
    'createBoard': {'name': 'synthetic'},
    'renameBoard': {'boardId': 8, 'name': 'synthetic'},
    'setBoardSystemListHidden': {
      'boardId': 8,
      'list': 'closed',
      'hidden': true,
    },
    'createBoardList': {'boardId': 8, 'labelId': 8},
    'moveBoardList': {'boardId': 8, 'listId': 8, 'position': 0},
    'moveBoardCard': {
      'iid': 3,
      'fields': {'labels': 'synthetic'},
    },
  };
  for (final entry in cases.entries) {
    test('§15 row21 port dispatches ${entry.key} once', () async {
      final adapter = FakeAdapter((r) {
        if (r.method != 'GET') {
          return jsonResponse({'id': 8, 'iid': 3}, status: 201);
        }
        if (r.uri.path.endsWith('/todos')) {
          return jsonResponse([
            {
              'id': 18,
              'project': {'id': 9},
              'target_type': 'Issue',
              'target': {'iid': 3},
            },
          ]);
        }
        if (r.uri.path.endsWith('/discussions/abc')) {
          return jsonResponse({
            'id': 'abc',
            'notes': [
              {
                'id': 8,
                'author': {'id': 7},
              },
            ],
          });
        }
        if (r.uri.path.contains('/award_emoji/')) {
          return jsonResponse({
            'id': 8,
            'name': 'thumbsup',
            'user': {'id': 7},
          });
        }
        return preflight(r);
      });
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final p = await port.prepare(
        request(entry.key, {
          if (entry.key != 'markTodoDone') 'projectId': 9,
          ...entry.value,
        }),
      );
      final result =
          await port.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(result.state, AiJournalState.succeeded);
      expect(adapter.requests.where((r) => r.method != 'GET'), hasLength(1));
      api.close();
    });
  }

  test(
    '§15 row23 upload timeout bounds and projection excludes URL/Markdown',
    () async {
      expect(
        GitLabAiWritePort.uploadSendTimeout(1),
        const Duration(seconds: 15),
      );
      expect(
        GitLabAiWritePort.uploadSendTimeout(20 * 1024 * 1024),
        const Duration(seconds: 160),
      );
      expect(
        GitLabAiWritePort.uploadSendTimeout(100 * 1024 * 1024),
        const Duration(minutes: 4),
      );
      final adapter = FakeAdapter(
        (r) => r.method == 'GET'
            ? preflight(r)
            : jsonResponse({
                'id': 8,
                'url': '/uploads/secret/file',
                'markdown': 'secret markdown',
                'body': 'private',
              }, status: 201),
      );
      final api = testApi(adapter);
      final port = GitLabAiWritePort(api, accountKey: account);
      final p = await port.prepare(
        AiWriteRequest(
          operationId: 'upload_attachment',
          executionId: 'upload-1',
          scope: scope,
          arguments: {'projectId': 9, 'filename': 'file.txt'},
          uploadBytes: [1, 2, 3],
        ),
      );
      final result =
          await port.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(result.projection, {'id': 8});
      expect(result.releaseName, 'file.txt');
      expect(
        adapter.requests.singleWhere((r) => r.method == 'POST').sendTimeout,
        const Duration(seconds: 15),
      );
      api.close();
    },
  );
}
