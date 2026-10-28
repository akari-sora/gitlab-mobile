import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/request_meter.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_scope_add.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'fx_coord_support.dart';

const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final class _Secrets implements KnownSecretsSource {
  const _Secrets([this.current = const []]);

  @override
  final Iterable<String> current;
}

const _project = Project(
  id: 42,
  name: 'Synthetic',
  path: 'team/synthetic',
  defaultBranch: 'main',
);

const _groupOrigin = AiGroupWorkItemOrigin(
  group: GraphResourceRef(id: 'gid://gitlab/Group/7', fullPath: 'team/sub'),
  iid: 3,
  title: 'Untrusted entry title',
);

Map<String, Object?> _groupNode([String path = 'team/sub']) => {
  'id': 'gid://gitlab/WorkItem/91',
  'iid': '3',
  'title': 'Fresh group title',
  'state': 'OPEN',
  'createdAt': '2026-10-01T00:00:00Z',
  'updatedAt': '2026-10-02T00:00:00Z',
  'project': null,
  'namespace': {'id': 'gid://gitlab/Group/7', 'fullPath': path},
  'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Task'},
  'description': 'Fresh group description',
  'widgets': <Object?>[],
};

Map<String, Object?> _groupEnvelope(Map<String, Object?> node, [String path = 'team/sub']) => {
  'data': {
    'namespace': {
      'id': 'gid://gitlab/Group/7',
      'fullPath': path,
      'workItem': node,
    },
  },
};

FakeAdapter _groupAdapter({
  Map<String, Object?>? node,
  Map<String, Object?>? envelope,
  Map<String, Object?>? metadata,
  String path = 'team/sub',
  void Function(int)? afterRead,
}) => FakeAdapter((request) {
  final isNamespace = request.uri.path == '/gitlab/api/graphql';
  if (isNamespace) {
    expect(request.method, 'POST');
    final body = request.data! as Map<String, Object?>;
    expect(body['query'], namespaceWorkItemQuery);
    expect(body['variables'], {'path': path, 'iid': '3'});
    afterRead?.call(2);
    return jsonResponse(envelope ?? _groupEnvelope(node ?? _groupNode(path), path));
  }
  expect(request.method, 'GET');
  expect(request.uri.path, '/gitlab/api/v4/groups/7');
  expect(request.uri.queryParameters, {'with_projects': 'false'});
  afterRead?.call(1);
  return jsonResponse(
    metadata ?? {'id': 7, 'full_path': path, 'visibility': 'private'},
  );
});

void main() {
  group('user-added group item', _uiAddedContext);

  test(
    'group unavailable description is explicitly marked as unread',
    () async {
      final node = _groupNode()..remove('description');
      final result = await _load(_groupOrigin, _groupAdapter(node: node));
      expect(
        result.built.blocks.single.text,
        contains('"description_status":"unavailable"'),
      );
      expect(result.groupMetadata!.confidential, isNull);
    },
  );

  test(
    'initial group load has its own bounded meter without an admission callback',
    () async {
      final adapter = _groupAdapter();
      final api = testApi(adapter);
      addTearDown(api.close);
      expect(RequestMeter.current, isNull);
      await loadAiChatContext(
        origin: _groupOrigin,
        api: api,
        redactor: Redactor(secrets: const _Secrets()),
        accountKey: 'https://example.com/gitlab#7',
        refreshSecrets: () async {
          expect(RequestMeter.current, isNotNull);
          expect(RequestMeter.current!.count, 2);
        },
        isCurrent: () => true,
      );
      expect(RequestMeter.current, isNull);
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'initial group context refuses a read exceeding its own allowance',
    () async {
      final adapter = _groupAdapter(
        afterRead: (read) {
          if (read == 1) {
            // Account for nested work in the same context operation. A caller
            // without beforeRead must still be unable to exceed the allowance.
            RequestMeter.current!
              ..increment()
              ..increment();
          }
        },
      );
      await expectLater(
        _load(_groupOrigin, adapter),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.rateLimited,
          ),
        ),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'group context has a distinct scope and fresh source metadata',
    () async {
      final adapter = _groupAdapter();
      final result = await _load(_groupOrigin, adapter);
      expect(projectForAiChatOrigin(_groupOrigin), isNull);
      expect(result.scope, isNull);
      expect(result.field, isNull);
      final scope = result.groupScope!;
      expect(scope.accountKey, 'https://example.com/gitlab#7');
      expect(scope.instanceKey, 'https://example.com/gitlab');
      expect(scope.groupId, 7);
      expect(scope.groupFullPath, 'team/sub');
      expect(scope.iid, 3);
      expect(scope.workItemGid, 'gid://gitlab/WorkItem/91');
      expect(result.groupMetadata!.visibility, 'private');
      expect(result.groupMetadata!.confidential, isNull);
      expect(result.fetchedAt, isNotNull);
      expect(result.built.pinnedSha, isNull);
      expect(result.built.blocks.single.text, contains('Fresh group title'));
      expect(
        result.built.blocks.single.text,
        contains('"description_status":"loaded"'),
      );
      expect(
        result.built.blocks.single.text,
        contains('"labels_status":"incomplete"'),
      );
      expect(
        result.built.blocks.single.text,
        contains('"notes_status":"not_loaded"'),
      );
      expect(
        result.built.blocks.single.text,
        contains('Fresh group description'),
      );
      expect(
        result.built.blocks.single.text,
        isNot(contains('Untrusted entry')),
      );
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests
            .where((r) => r.method == 'POST')
            .every(
              (r) =>
                  ((r.data! as Map)['query']! as String).startsWith('query '),
            ),
        isTrue,
      );
    },
  );

  for (final visibility in <Object?>[
    'private',
    'internal',
    'public',
    null,
    '',
    'unknown',
    false,
    0,
  ]) {
    test('group source visibility preserves $visibility evidence', () async {
      final adapter = _groupAdapter(
        metadata: {'id': 7, 'full_path': 'team/sub', 'visibility': ?visibility},
      );
      final result = await _load(_groupOrigin, adapter);
      expect(
        result.groupMetadata!.visibility,
        const ['private', 'internal', 'public'].contains(visibility)
            ? visibility
            : isNull,
      );
      expect(result.groupMetadata!.confidential, isNull);
      expect(adapter.requests, hasLength(2));
    });
  }

  final refusals = <String, void Function(Map<String, Object?>)>{
    'missing project key': (node) => node.remove('project'),
    'missing namespace key': (node) => node.remove('namespace'),
    'explicit project': (node) => node['project'] = {
      'id': 'gid://gitlab/Project/7',
      'fullPath': 'team/sub',
    },
    'invalid project object': (node) => node['project'] = <String, Object?>{},
    'foreign Group with same path': (node) => node['namespace'] = {
      'id': 'gid://gitlab/Group/8',
      'fullPath': 'team/sub',
    },
    'ancestor instead of direct owner': (node) =>
        node['namespace'] = {'id': 'gid://gitlab/Group/6', 'fullPath': 'team'},
    'wrong iid': (node) => node['iid'] = '4',
    'Group GID instead of WorkItem GID': (node) =>
        node['id'] = 'gid://gitlab/Group/91',
    'same numeric Project namespace': (node) => node['namespace'] = {
      'id': 'gid://gitlab/Namespaces::ProjectNamespace/7',
      'fullPath': 'team/sub',
    },
    'dot segment in direct owner': (node) => node['namespace'] = {
      'id': 'gid://gitlab/Group/7',
      'fullPath': 'team/./sub',
    },
  };
  for (final refusal in refusals.entries) {
    test('group strict context refuses ${refusal.key}', () async {
      final node = _groupNode();
      refusal.value(node);
      final adapter = _groupAdapter(node: node);
      await expectLater(
        _load(_groupOrigin, adapter),
        throwsA(isA<ApiFailure>()),
      );
      // Only the owner read and the strict query run; there is no mutation.
      expect(adapter.requests.map((r) => r.method), ['GET', 'POST']);
    });
  }

  for (final missing in ['namespace', 'workItem']) {
    test('group strict context refuses missing root $missing', () async {
      final envelope = _groupEnvelope(_groupNode());
      final data = envelope['data']! as Map<String, Object?>;
      final parent = missing == 'namespace'
          ? data
          : data['namespace']! as Map<String, Object?>;
      parent.remove(missing);
      final adapter = _groupAdapter(envelope: envelope);
      await expectLater(
        _load(_groupOrigin, adapter),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests.map((r) => r.method), ['GET', 'POST']);
    });
  }

  test(
    'group strict context refuses foreign root even with matching item',
    () async {
      final envelope = _groupEnvelope(_groupNode());
      final data = envelope['data']! as Map<String, Object?>;
      (data['namespace']! as Map<String, Object?>)['id'] =
          'gid://gitlab/Group/8';
      final adapter = _groupAdapter(envelope: envelope);
      await expectLater(
        _load(_groupOrigin, adapter),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests.map((r) => r.method), ['GET', 'POST']);
    },
  );

  for (final path in ['team/./sub', 'team/../sub', ' team/sub', 'team//sub']) {
    test('group origin refuses noncanonical path $path before I/O', () async {
      final adapter = _groupAdapter();
      await expectLater(
        _load(
          AiGroupWorkItemOrigin(
            group: GraphResourceRef(id: 'gid://gitlab/Group/7', fullPath: path),
            iid: 3,
            title: 'Synthetic',
          ),
          adapter,
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests, isEmpty);
    });
  }

  for (final metadata in [
    <String, Object?>{'id': 8, 'full_path': 'team/sub', 'visibility': 'public'},
    <String, Object?>{'full_path': 'team/sub', 'visibility': 'public'},
    <String, Object?>{
      'id': '7',
      'full_path': 'team/sub',
      'visibility': 'public',
    },
    <String, Object?>{'id': 7, 'visibility': 'public'},
  ]) {
    test(
      'group metadata requires matching numeric owner and path $metadata',
      () async {
        final adapter = _groupAdapter(metadata: metadata);
        await expectLater(
          _load(_groupOrigin, adapter),
          throwsA(isA<ApiFailure>()),
        );
        expect(adapter.requests.map((r) => r.method), ['GET']);
      },
    );
  }

  test('group metadata supplies a renamed path to the strict reader', () async {
    final adapter = _groupAdapter(path: 'renamed/sub');
    final result = await _load(_groupOrigin, adapter);
    expect(result.groupScope!.groupId, 7);
    expect(result.groupScope!.groupFullPath, 'renamed/sub');
    expect(result.groupScope!.workItemGid, 'gid://gitlab/WorkItem/91');
    expect(adapter.requests.map((r) => r.method), ['GET', 'POST']);
  });

  test('renamed owner rejects a strict response carrying the old path', () async {
    final adapter = _groupAdapter(
      path: 'renamed/sub',
      envelope: _groupEnvelope(_groupNode()),
    );
    await expectLater(_load(_groupOrigin, adapter), throwsA(isA<ApiFailure>()));
    expect(adapter.requests.map((r) => r.method), ['GET', 'POST']);
  });

  for (final staleAfter in [1, 2, 3]) {
    test(
      'group context discards stale ownership after await $staleAfter',
      () async {
        var current = true;
        var secretsRefreshed = false;
        final adapter = _groupAdapter(
          afterRead: (read) {
            if (read == staleAfter) current = false;
          },
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          loadAiChatContext(
            origin: _groupOrigin,
            api: api,
            redactor: Redactor(secrets: const _Secrets()),
            accountKey: 'https://example.com/gitlab#7',
            refreshSecrets: () async {
              secretsRefreshed = true;
              if (staleAfter == 3) current = false;
            },
            isCurrent: () => current,
          ),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        expect(adapter.requests, hasLength(staleAfter == 1 ? 1 : 2));
        expect(secretsRefreshed, staleAfter == 3);
      },
    );
  }

  for (final account in [
    'https://example.com/other#7',
    'https://example.com/gitlab#07',
    'https://example.com/gitlab#0',
    'https://elsewhere.example/gitlab#7',
  ]) {
    test(
      'group context rejects foreign or invalid account $account before I/O',
      () async {
        final adapter = _groupAdapter();
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          loadAiChatContext(
            origin: _groupOrigin,
            api: api,
            redactor: Redactor(secrets: const _Secrets()),
            accountKey: account,
            refreshSecrets: () async {},
            isCurrent: () => true,
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(adapter.requests, isEmpty);
      },
    );
  }

  test(
    'group reads reserve context allowance and measure both HTTP sends',
    () async {
      final adapter = _groupAdapter();
      final api = testApi(adapter);
      addTearDown(api.close);
      final meter = RequestMeter();
      final allowances = <int>[];
      final result = await meter.runAsync(
        () => loadAiChatContext(
          origin: _groupOrigin,
          api: api,
          redactor: Redactor(secrets: const _Secrets()),
          accountKey: 'https://example.com/gitlab#7',
          refreshSecrets: () async {},
          isCurrent: () => true,
          beforeRead: (maximum) {
            expect(adapter.requests, hasLength(allowances.length));
            allowances.add(maximum);
          },
        ),
      );
      expect(allowances, [2, 2]);
      expect(meter.count, 2);
      expect(result.groupMetadata!.visibility, 'private');
    },
  );

  for (final admittedReads in [0, 1]) {
    test(
      'group context budget stops before read ${admittedReads + 1}',
      () async {
        final adapter = _groupAdapter();
        final api = testApi(adapter);
        addTearDown(api.close);
        var reservations = 0;
        await expectLater(
          loadAiChatContext(
            origin: _groupOrigin,
            api: api,
            redactor: Redactor(secrets: const _Secrets()),
            accountKey: 'https://example.com/gitlab#7',
            refreshSecrets: () async {},
            isCurrent: () => true,
            beforeRead: (_) {
              if (reservations++ == admittedReads) {
                throw StateError('context budget');
              }
            },
          ),
          throwsStateError,
        );
        expect(adapter.requests, hasLength(admittedReads));
      },
    );
  }

  test(
    'group context rereads namespace and metadata on the same API',
    () async {
      final adapter = _groupAdapter();
      final api = testApi(adapter);
      addTearDown(api.close);
      for (var i = 0; i < 2; i++) {
        await loadAiChatContext(
          origin: _groupOrigin,
          api: api,
          redactor: Redactor(secrets: const _Secrets()),
          accountKey: 'https://example.com/gitlab#7',
          refreshSecrets: () async {},
          isCurrent: () => true,
        );
      }
      expect(adapter.requests, hasLength(4));
    },
  );

  test('group context redacts secrets with the existing builder', () async {
    final node = _groupNode()
      ..['description'] = 'secret: synthetic-group-secret';
    final result = await _load(
      _groupOrigin,
      _groupAdapter(node: node),
      secrets: const ['synthetic-group-secret'],
    );
    expect(
      result.built.blocks.single.text,
      isNot(contains('synthetic-group-secret')),
    );
    expect(result.groupMetadata!.confidential, isNull);
  });

  test('general context performs no GitLab reads', () async {
    final adapter = FakeAdapter((_) => throw StateError('unexpected request'));
    final result = await _load(const AiGeneralOrigin(), adapter);
    expect(result.scope, isNull);
    expect(result.built.blocks, isEmpty);
    expect(result.built.readInternal, isFalse);
    expect(adapter.requests, isEmpty);
  });

  test('job loads metadata and trace and pins the job commit', () async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/projects/42/jobs/9/trace')) {
        return ResponseBody.fromString('synthetic trace', 200);
      }
      if (path.endsWith('/projects/42/jobs/9')) {
        return jsonResponse({
          'name': 'verify',
          'stage': 'test',
          'status': 'failed',
          'failure_reason': 'script_failure',
          'ref': 'main',
          'commit': {'id': _head},
          'pipeline': {'id': 77, 'sha': _base},
        });
      }
      return jsonResponse({'error': 'not found'}, status: 404);
    });
    final result = await _load(
      const AiJobOrigin(project: _project, jobId: 9, jobName: 'verify'),
      adapter,
    );
    expect(result.scope!.headSha, _head);
    expect(result.scope!.pipelineId, 77);
    expect(result.built.blocks.single.text, contains('synthetic trace'));
    expect(adapter.requests.map((r) => r.method), everyElement('GET'));
  });

  test('issue loads notes and pins the fresh default branch commit', () async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/projects/42/issues/3/notes')) {
        return jsonResponse([
          {
            'body': 'newest note',
            'created_at': '2026-10-20T12:00:00Z',
            'author': {'username': 'reviewer'},
            'system': false,
            'internal': true,
          },
        ]);
      }
      if (path.endsWith('/projects/42/issues/3')) {
        return jsonResponse({
          'title': 'Issue title',
          'description': 'Issue body',
          'state': 'opened',
          'labels': ['bug'],
        });
      }
      if (path.endsWith('/projects/42/repository/branches/main')) {
        return jsonResponse({
          'name': 'main',
          'commit': {'id': _head},
        });
      }
      if (path.endsWith('/projects/42')) {
        return jsonResponse({
          'id': 42,
          'name': 'Synthetic',
          'path_with_namespace': 'team/synthetic',
          'default_branch': 'main',
        });
      }
      return jsonResponse({'error': 'not found'}, status: 404);
    });
    final result = await _load(
      const AiWorkItemOrigin(
        project: _project,
        kind: AiWorkItemKind.issue,
        iid: 3,
        title: 'Issue title',
      ),
      adapter,
    );
    expect(result.scope!.headSha, _head);
    expect(result.scope!.defaultBranch, 'main');
    expect(result.built.blocks.single.text, contains('newest note'));
    expect(result.built.blocks.single.text, contains('"internal":true'));
    expect(result.built.readInternal, isTrue);
    expect(result.built.pinnedSha, _head);
  });

  for (final branchResult in const ['missing', 'forbidden', 'invisible']) {
    test(
      'issue remains available when its revision is $branchResult',
      () async {
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/projects/42/issues/3/notes')) {
            return jsonResponse([
              {
                'body': 'issue survives without repository access',
                'created_at': '2026-10-20T12:00:00Z',
                'system': false,
                'confidential': false,
              },
            ]);
          }
          if (path.endsWith('/projects/42/issues/3')) {
            return jsonResponse({
              'title': 'Issue title',
              'description': 'Issue body',
              'state': 'opened',
              'labels': ['bug'],
            });
          }
          if (path.endsWith('/projects/42/repository/branches/main')) {
            return jsonResponse({
              'message': branchResult,
            }, status: branchResult == 'forbidden' ? 403 : 404);
          }
          if (path.endsWith('/projects/42')) {
            return jsonResponse({
              'id': 42,
              'name': 'Synthetic',
              'path_with_namespace': 'team/synthetic',
              if (branchResult != 'missing') 'default_branch': 'main',
            });
          }
          return jsonResponse({'error': 'not found'}, status: 404);
        });
        final result = await _load(
          const AiWorkItemOrigin(
            project: _project,
            kind: AiWorkItemKind.issue,
            iid: 3,
            title: 'Issue title',
          ),
          adapter,
        );

        expect(result.scope!.headSha, isNull);
        expect(
          result.scope!.defaultBranch,
          branchResult == 'missing' ? isNull : 'main',
        );
        expect(result.built.pinnedSha, isNull);
        expect(
          result.built.blocks.single.text,
          contains('issue survives without repository access'),
        );

        final requestCount = adapter.requests.length;
        final toolResult =
            await AiToolCatalogue(
              port: GitLabAiReadPort(testApi(adapter), _project.id),
              scope: result.scope!,
              redactor: Redactor(secrets: const _Secrets()),
            ).executeResult(
              AiToolCall(
                id: 'revision-unavailable',
                name: 'read_file',
                arguments: const {'path': 'README.md', 'revision': 'head'},
              ),
              budget: AiToolBudget(),
            );
        expect(toolResult.isError, isTrue);
        expect(toolResult.content, contains('no pinned commit'));
        expect(adapter.requests, hasLength(requestCount));
      },
    );
  }

  test(
    'merge request pins item refs and loads that exact diff version',
    () async {
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/merge_requests/7/versions/5')) {
          return jsonResponse({
            'id': 5,
            'head_commit_sha': _head,
            'base_commit_sha': _base,
            'diffs': [
              {
                'old_path': 'lib/a.dart',
                'new_path': 'lib/a.dart',
                'diff': '@@ -1 +1 @@\n-old\n+new',
              },
            ],
          });
        }
        if (path.endsWith('/projects/42/merge_requests/7/versions')) {
          return jsonResponse([
            {'id': 5, 'head_commit_sha': _head, 'base_commit_sha': _base},
          ]);
        }
        if (path.endsWith('/projects/42/merge_requests/7/notes')) {
          expect(request.uri.queryParameters, containsPair('sort', 'desc'));
          expect(
            request.uri.queryParameters,
            containsPair('order_by', 'created_at'),
          );
          return jsonResponse([
            {
              'body': 'visible MR note',
              'created_at': '2026-10-20T12:00:00Z',
              'system': false,
              'confidential': true,
            },
            {
              'body': 'system MR note',
              'created_at': '2026-10-20T13:00:00Z',
              'system': true,
              'internal': false,
            },
          ]);
        }
        if (path.endsWith('/projects/42/merge_requests/7')) {
          return jsonResponse({
            'title': 'MR title',
            'description': 'MR body',
            'state': 'opened',
            'labels': ['review'],
            'diff_refs': {'head_sha': _head, 'base_sha': _base},
          });
        }
        return jsonResponse({'error': 'not found'}, status: 404);
      });
      final result = await _load(
        const AiWorkItemOrigin(
          project: _project,
          kind: AiWorkItemKind.mergeRequest,
          iid: 7,
          title: 'MR title',
        ),
        adapter,
      );
      expect(result.scope!.headSha, _head);
      expect(result.scope!.baseSha, _base);
      expect(result.built.blocks.single.text, contains('+new'));
      expect(result.built.blocks.single.text, contains('visible MR note'));
      expect(
        result.built.blocks.single.text,
        isNot(contains('system MR note')),
      );
      expect(result.built.blocks.single.text, contains('"internal":true'));
      expect(result.built.readInternal, isTrue);
    },
  );

  test('merge request notes are read past a page of system notes', () async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/projects/42/merge_requests/7/versions/5')) {
        return jsonResponse({
          'id': 5,
          'head_commit_sha': _head,
          'base_commit_sha': _base,
          'diffs': <Object?>[],
        });
      }
      if (path.endsWith('/projects/42/merge_requests/7/versions')) {
        return jsonResponse([
          {'id': 5, 'head_commit_sha': _head, 'base_commit_sha': _base},
        ]);
      }
      if (path.endsWith('/projects/42/merge_requests/7/notes')) {
        if (request.uri.queryParameters['page'] == '2') {
          return jsonResponse([
            // Shifted onto this page by a note added between the two reads.
            {
              'id': 100,
              'body': 'newest human note',
              'created_at': '2026-10-20T13:00:00Z',
              'system': false,
            },
            {
              'id': 101,
              'body': 'older human note',
              'created_at': '2026-10-19T12:00:00Z',
              'system': false,
            },
          ]);
        }
        return jsonResponse(
          [
            for (var i = 0; i < 29; i++)
              {
                'id': i,
                'body': 'system note $i',
                'created_at': '2026-10-20T12:00:00Z',
                'system': true,
              },
            {
              'id': 100,
              'body': 'newest human note',
              'created_at': '2026-10-20T13:00:00Z',
              'system': false,
            },
          ],
          headers: {
            'x-next-page': ['2'],
          },
        );
      }
      if (path.endsWith('/projects/42/merge_requests/7')) {
        return jsonResponse({
          'title': 'MR title',
          'description': 'MR body',
          'state': 'opened',
          'diff_refs': {'head_sha': _head, 'base_sha': _base},
        });
      }
      return jsonResponse({'error': 'not found'}, status: 404);
    });
    final result = await _load(
      const AiWorkItemOrigin(
        project: _project,
        kind: AiWorkItemKind.mergeRequest,
        iid: 7,
        title: 'MR title',
      ),
      adapter,
    );
    expect(result.built.blocks.single.text, contains('older human note'));
    expect(
      'newest human note'.allMatches(result.built.blocks.single.text),
      hasLength(1),
    );
    expect(
      adapter.requests.where((r) => r.uri.path.endsWith('/notes')),
      hasLength(2),
    );
  });

  test('file reads the requested immutable SHA and redacts content', () async {
    final adapter = FakeAdapter((request) {
      expect(request.uri.queryParameters['ref'], _head);
      if (request.method == 'HEAD') {
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'x-gitlab-size': ['30'],
          },
        );
      }
      return ResponseBody.fromString('token=synthetic-secret-value', 200);
    });
    final result = await _load(
      const AiFileOrigin(
        project: _project,
        path: 'lib/config.dart',
        sha: _head,
      ),
      adapter,
      secrets: const ['synthetic-secret-value'],
    );
    expect(result.scope!.headSha, _head);
    expect(result.built.blocks.single.text, contains('[REDACTED]'));
    expect(
      result.built.blocks.single.text,
      isNot(contains('synthetic-secret')),
    );
    expect(adapter.requests.map((r) => r.method), ['HEAD', 'GET']);
  });

  test('refreshes rotated secrets after reads and before redaction', () async {
    const rotated = 'rotated-synthetic-secret';
    final secrets = <String>[];
    final adapter = FakeAdapter((request) {
      if (request.method == 'HEAD') {
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'x-gitlab-size': ['24'],
          },
        );
      }
      return ResponseBody.fromString(rotated, 200);
    });
    final result = await loadAiChatContext(
      origin: const AiFileOrigin(
        project: _project,
        path: 'lib/rotated.dart',
        sha: _head,
      ),
      api: testApi(adapter),
      redactor: Redactor(secrets: _Secrets(secrets)),
      accountKey: 'https://example.com/gitlab#7',
      refreshSecrets: () async => secrets.add(rotated),
      isCurrent: () => true,
    );
    expect(result.built.blocks.single.text, contains('[REDACTED]'));
    expect(result.built.blocks.single.text, isNot(contains(rotated)));
  });

  test('sensitive file is blocked before any network request', () async {
    final adapter = FakeAdapter((_) => throw StateError('unexpected request'));
    final result = await _load(
      const AiFileOrigin(project: _project, path: '.env', sha: _head),
      adapter,
    );
    expect(result.built.blocks, isEmpty);
    expect(result.built.blockedSensitivePaths, ['.env']);
    expect(adapter.requests, isEmpty);
  });

  test('file rejects branch and malformed SHA before any request', () async {
    for (final sha in const ['main', 'not-a-commit-sha']) {
      final adapter = FakeAdapter(
        (_) => throw StateError('unexpected request'),
      );
      await expectLater(
        _load(
          AiFileOrigin(project: _project, path: 'README.md', sha: sha),
          adapter,
        ),
        throwsFormatException,
      );
      expect(adapter.requests, isEmpty);
    }
  });

  test('private key material is withheld by the existing builder', () async {
    final adapter = FakeAdapter((request) {
      if (request.method == 'HEAD') {
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'x-gitlab-size': ['100'],
          },
        );
      }
      return ResponseBody.fromString(
        '-----BEGIN PRIVATE KEY-----\nSYNTHETIC-WITHHELD-CONTEXT',
        200,
      );
    });
    final result = await _load(
      const AiFileOrigin(
        project: _project,
        path: 'docs/example.txt',
        sha: _head,
      ),
      adapter,
    );
    expect(result.built.withheldPrivateKeyContext, isTrue);
    expect(result.built.blocks.single.text, isNot(contains('SYNTHETIC')));
  });

  test('stale epoch cancels before the next async read', () async {
    var current = true;
    final adapter = FakeAdapter((request) {
      current = false;
      return jsonResponse({
        'name': 'verify',
        'stage': 'test',
        'status': 'failed',
      });
    });
    await expectLater(
      loadAiChatContext(
        origin: const AiJobOrigin(
          project: _project,
          jobId: 9,
          jobName: 'verify',
        ),
        api: testApi(adapter),
        redactor: Redactor(secrets: const _Secrets()),
        accountKey: 'https://example.com/gitlab#7',
        refreshSecrets: () async {},
        isCurrent: () => current,
      ),
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.cancelled,
        ),
      ),
    );
    expect(adapter.requests, hasLength(1));
  });
}

/// U-add regressions: the context loader is the strict read a user-added
/// group item goes through, and the added item never becomes page context.
void _uiAddedContext() {
  test(
    'a user-added check reserves each context read through the caller budget',
    () async {
      final reserved = <int>[];
      final adapter = _groupAdapter();
      final api = testApi(adapter);
      addTearDown(api.close);
      await loadAiChatContext(
        origin: _groupOrigin,
        api: api,
        redactor: Redactor(secrets: const _Secrets()),
        accountKey: 'https://example.com/gitlab#7',
        refreshSecrets: () async {},
        isCurrent: () => true,
        beforeRead: reserved.add,
      );
      // The numeric owner lookup and the strict read, each with one replay.
      expect(reserved, [2, 2]);

      final refused = _groupAdapter();
      final refusedApi = testApi(refused);
      addTearDown(refusedApi.close);
      await expectLater(
        loadAiChatContext(
          origin: _groupOrigin,
          api: refusedApi,
          redactor: Redactor(secrets: const _Secrets()),
          accountKey: 'https://example.com/gitlab#7',
          refreshSecrets: () async {},
          isCurrent: () => true,
          beforeRead: (maximum) {
            if (refused.requests.isNotEmpty) {
              throw const AiFailure(
                AiFailureKind.rateLimited,
                notSent: true,
                gitLabBudget: true,
              );
            }
          },
        ),
        throwsA(isA<AiFailure>()),
      );
      // The exhausted budget stops the strict read before it is sent.
      expect(refused.requests.map((r) => r.method), ['GET']);
    },
  );

  test('a user-added group item never becomes the page context', () async {
    final h = await StackHarness.create(
      configure: (server) {
        server.overrides['GET groups/team/sub'] = (_) => jsonResponse({
          'id': 7,
          'name': 'Sub',
          'full_path': 'team/sub',
          'visibility': 'private',
        });
        server.overrides['GET groups/7'] = (_) => jsonResponse({
          'id': 7,
          'full_path': 'team/sub',
          'visibility': 'private',
        });
        server.overrides['POST '] = (request) {
          expect(
            (request.data! as Map<String, Object?>)['query'],
            namespaceWorkItemQuery,
          );
          final node = _groupNode()
            ..['iid'] = '5'
            ..['title'] = 'Added group title'
            ..['description'] = 'Added group description';
          return jsonResponse(_groupEnvelope(node));
        };
      },
    );
    addTearDown(h.dispose);
    await h.controller.send('First question');
    final before = h.controller.contextForTesting!;
    expect(before.scope?.projectId, 42);
    expect(before.groupScope, isNull);

    final check = await h.controller.checkGroupWorkItem(
      'https://example.com/gitlab/groups/team/sub/-/work_items/5',
    );
    expect(
      await h.controller.addGroupWorkItem(check as AiGroupWorkItemCandidate),
      isNull,
    );
    expect(identical(h.controller.contextForTesting, before), isTrue);
    await h.controller.send('Second question');
    final after = h.controller.contextForTesting!;
    expect(after.scope?.projectId, 42);
    expect(after.groupScope, isNull);
    expect(after.groupMetadata, isNull);
    for (final body in h.provider.bodies) {
      expect(body, isNot(contains('Added group description')));
      expect(body, isNot(contains('Added group title')));
    }
  });
}

Future<AiChatContext> _load(
  AiChatOrigin origin,
  FakeAdapter adapter, {
  Iterable<String> secrets = const [],
}) => loadAiChatContext(
  origin: origin,
  api: testApi(adapter),
  redactor: Redactor(secrets: _Secrets(secrets)),
  accountKey: 'https://example.com/gitlab#7',
  refreshSecrets: () async {},
  isCurrent: () => true,
);
