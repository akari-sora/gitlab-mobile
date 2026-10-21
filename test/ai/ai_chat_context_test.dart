import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';

import '../support/fake_adapter.dart';

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

void main() {
  test('general context performs no GitLab reads', () async {
    final adapter = FakeAdapter((_) => throw StateError('unexpected request'));
    final result = await _load(const AiGeneralOrigin(), adapter);
    expect(result.scope, isNull);
    expect(result.built.blocks, isEmpty);
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
