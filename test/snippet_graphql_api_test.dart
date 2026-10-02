import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/snippet_models.dart';

import 'support/fake_adapter.dart';

const _snippetId = 6030720;
final _project = Project.fromJson(projectJson(42));

Map<String, dynamic> _restSnippet({
  String updatedAt = '2026-08-13T15:25:58.905Z',
  List<String> paths = const ['README.md', 'script.sh'],
}) => {
  'id': _snippetId,
  'project_id': 42,
  'title': 'Example',
  'description': 'Notes',
  'file_name': 'README.md',
  'updated_at': updatedAt,
  'visibility': 'public',
  'author': {'name': 'Synthetic User'},
  'files': [
    for (final path in paths) {'path': path},
  ],
};

Map<String, dynamic> _identityNode({
  int snippetId = _snippetId,
  int projectId = 42,
  String? graphId,
  String? projectPath,
  String updatedAt = '2026-08-13T15:25:58Z',
  Object? blobs,
}) => {
  'id': graphId ?? 'gid://gitlab/ProjectSnippet/$snippetId',
  'project': {
    'id': 'gid://gitlab/Project/$projectId',
    'fullPath': projectPath ?? _project.path,
  },
  'updatedAt': updatedAt,
  'blobs': ?blobs,
};

Map<String, dynamic> _listEnvelope({
  required List<Object?> nodes,
  bool hasNext = false,
  String? cursor,
}) => {
  'data': {
    'snippets': {
      'nodes': nodes,
      'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
    },
  },
};

Map<String, dynamic> _blobEnvelope({
  Object? blob,
  bool unretrievable = false,
  String updatedAt = '2026-08-13T15:25:58Z',
  int projectId = 42,
  String? projectPath,
}) => {
  'data': {
    'snippets': {
      'nodes': [
        _identityNode(
          projectId: projectId,
          projectPath: projectPath,
          updatedAt: updatedAt,
          blobs: {
            'hasUnretrievableBlobs': unretrievable,
            'nodes': [?blob],
          },
        ),
      ],
    },
  },
};

Map<String, dynamic> _blob({
  String path = 'README.md',
  Object? content = '# Hello',
  bool binary = false,
  bool renderedAsText = true,
  Object? tooLarge = false,
  Object? renderError,
}) => {
  'binary': binary,
  'name': path.split('/').last,
  'path': path,
  'rawPath': 'https://example.com/raw/$path',
  'size': content is String ? content.length : 10,
  'rawPlainData': content,
  'renderedAsText': renderedAsText,
  'simpleViewer': {'tooLarge': tooLarge, 'renderError': renderError},
};

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

ProjectSnippet get _snippet => ProjectSnippet.fromJson(_restSnippet());

void main() {
  test(
    'discovers the server opaque ID with bounded project pagination and separate timestamps',
    () async {
      var graphPages = 0;
      final adapter = FakeAdapter((request) {
        if (!request.uri.path.endsWith('/graphql')) {
          return jsonResponse(_restSnippet());
        }
        graphPages++;
        final variables = (request.data as Map)['variables'] as Map;
        expect(variables['projectId'], 'gid://gitlab/Project/42');
        expect(variables['first'], 100);
        if (graphPages == 1) {
          expect(variables['after'], isNull);
          return jsonResponse(
            _listEnvelope(
              nodes: [_identityNode(snippetId: 1)],
              hasNext: true,
              cursor: 'next+/=',
            ),
          );
        }
        expect(variables['after'], 'next+/=');
        return jsonResponse(_listEnvelope(nodes: [_identityNode()]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final snapshot = await api.projectSnippetSnapshot(_project, _snippet);

      expect(snapshot.graphId, 'gid://gitlab/ProjectSnippet/6030720');
      expect(snapshot.graphUpdatedAt, DateTime.utc(2026, 8, 13, 15, 25, 58));
      expect(snapshot.restUpdatedAt, '2026-08-13T15:25:58.905Z');
      expect(snapshot.filePaths, ['README.md', 'script.sh']);
      expect(graphPages, 2);
      expect(
        adapter.requests
            .where((request) => request.uri.path.endsWith('/graphql'))
            .every(
              (request) =>
                  request.headers['Authorization'] ==
                      'Bearer synthetic-test-token' &&
                  request.headers['PRIVATE-TOKEN'] == null &&
                  !request.followRedirects,
            ),
        isTrue,
      );
    },
  );

  test(
    'stale REST input and a mid-lookup REST change fail as conflict',
    () async {
      final stale = testApi(
        FakeAdapter((request) {
          if (request.uri.path.endsWith('/graphql')) {
            fail('A stale REST version must stop before GraphQL');
          }
          return jsonResponse(_restSnippet(updatedAt: '2026-08-14T00:00:00Z'));
        }),
      );
      await expectLater(
        stale.projectSnippetSnapshot(_project, _snippet),
        throwsA(_failure(FailureKind.conflict)),
      );
      stale.close();

      var restReads = 0;
      final changed = testApi(
        FakeAdapter((request) {
          if (request.uri.path.endsWith('/graphql')) {
            return jsonResponse(_listEnvelope(nodes: [_identityNode()]));
          }
          restReads++;
          return jsonResponse(
            _restSnippet(
              updatedAt: restReads == 1
                  ? '2026-08-13T15:25:58.905Z'
                  : '2026-08-14T00:00:00Z',
            ),
          );
        }),
      );
      await expectLater(
        changed.projectSnippetSnapshot(_project, _snippet),
        throwsA(_failure(FailureKind.conflict)),
      );
      changed.close();
    },
  );

  test(
    'reads one known path as bounded raw source with fresh REST fences',
    () async {
      var graphCalls = 0;
      final adapter = FakeAdapter((request) {
        if (!request.uri.path.endsWith('/graphql')) {
          return jsonResponse(_restSnippet());
        }
        graphCalls++;
        if (graphCalls == 1) {
          return jsonResponse(_listEnvelope(nodes: [_identityNode()]));
        }
        final body = request.data as Map;
        expect(
          (body['query'] as String),
          startsWith('query MobileSnippetBlob'),
        );
        expect(body['variables'], {
          'ids': ['gid://gitlab/ProjectSnippet/6030720'],
          'paths': ['README.md'],
        });
        return jsonResponse(_blobEnvelope(blob: _blob()));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final snapshot = await api.projectSnippetSnapshot(_project, _snippet);

      final blob = await api.snippetBlob(_project, snapshot, path: 'README.md');

      expect(blob.availability, SnippetBlobAvailability.text);
      expect(blob.content, '# Hello');
      expect(blob.path, 'README.md');
      expect(blob.rawPath, 'https://example.com/raw/README.md');
      expect(blob.renderedAsText, isTrue);
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/snippets/6030720'),
        ),
        hasLength(4),
      );
    },
  );

  test('discovery rejects a stale Graph version at shared precision', () async {
    final api = testApi(
      FakeAdapter(
        (request) => request.uri.path.endsWith('/graphql')
            ? jsonResponse(
                _listEnvelope(
                  nodes: [_identityNode(updatedAt: '2026-08-13T15:25:57.999Z')],
                ),
              )
            : jsonResponse(_restSnippet()),
      ),
    );
    await expectLater(
      api.projectSnippetSnapshot(_project, _snippet),
      throwsA(_failure(FailureKind.conflict)),
    );
    api.close();
  });

  test(
    'blob unavailable states remain explicit and never become empty text',
    () async {
      final cases = <({Object response, SnippetBlobAvailability expected})>[
        (
          response: _blob(content: null),
          expected: SnippetBlobAvailability.nullContent,
        ),
        (
          response: _blob(content: null, binary: true),
          expected: SnippetBlobAvailability.binary,
        ),
        (
          response: _blob(content: null, tooLarge: true),
          expected: SnippetBlobAvailability.tooLarge,
        ),
        (
          response: _blob(content: List.filled(20001, 'x').join('\n')),
          expected: SnippetBlobAvailability.tooLarge,
        ),
        (
          response: _blob(content: null, renderError: 'cannot render'),
          expected: SnippetBlobAvailability.renderError,
        ),
      ];
      for (final value in cases) {
        var graphCalls = 0;
        final api = testApi(
          FakeAdapter((request) {
            if (!request.uri.path.endsWith('/graphql')) {
              return jsonResponse(_restSnippet());
            }
            graphCalls++;
            return jsonResponse(
              graphCalls == 1
                  ? _listEnvelope(nodes: [_identityNode()])
                  : _blobEnvelope(blob: value.response),
            );
          }),
        );
        final snapshot = await api.projectSnippetSnapshot(_project, _snippet);
        final blob = await api.snippetBlob(
          _project,
          snapshot,
          path: 'README.md',
        );
        expect(blob.availability, value.expected);
        expect(blob.content, isNull);
        api.close();
      }

      var graphCalls = 0;
      final unavailable = testApi(
        FakeAdapter((request) {
          if (!request.uri.path.endsWith('/graphql')) {
            return jsonResponse(_restSnippet());
          }
          graphCalls++;
          return jsonResponse(
            graphCalls == 1
                ? _listEnvelope(nodes: [_identityNode()])
                : _blobEnvelope(unretrievable: true),
          );
        }),
      );
      final snapshot = await unavailable.projectSnippetSnapshot(
        _project,
        _snippet,
      );
      final blob = await unavailable.snippetBlob(
        _project,
        snapshot,
        path: 'README.md',
      );
      expect(blob.availability, SnippetBlobAvailability.unretrievable);
      expect(blob.content, isNull);
      expect(blob.unretrievable, isTrue);
      expect(blob.hasUnretrievableBlobs, isTrue);
      unavailable.close();
    },
  );

  test(
    'aggregate unretrievable flag does not hide a valid text node',
    () async {
      var graphCalls = 0;
      final api = testApi(
        FakeAdapter((request) {
          if (!request.uri.path.endsWith('/graphql')) {
            return jsonResponse(_restSnippet());
          }
          graphCalls++;
          return jsonResponse(
            graphCalls == 1
                ? _listEnvelope(nodes: [_identityNode()])
                : _blobEnvelope(blob: _blob(), unretrievable: true),
          );
        }),
      );
      final snapshot = await api.projectSnippetSnapshot(_project, _snippet);
      final blob = await api.snippetBlob(_project, snapshot, path: 'README.md');
      expect(blob.availability, SnippetBlobAvailability.text);
      expect(blob.content, '# Hello');
      expect(blob.unretrievable, isFalse);
      expect(blob.hasUnretrievableBlobs, isTrue);
      api.close();
    },
  );

  test('missing non-null simpleViewer contract is invalid', () async {
    var graphCalls = 0;
    final invalidBlob = _blob()..['simpleViewer'] = null;
    final api = testApi(
      FakeAdapter((request) {
        if (!request.uri.path.endsWith('/graphql')) {
          return jsonResponse(_restSnippet());
        }
        graphCalls++;
        return jsonResponse(
          graphCalls == 1
              ? _listEnvelope(nodes: [_identityNode()])
              : _blobEnvelope(blob: invalidBlob),
        );
      }),
    );
    final snapshot = await api.projectSnippetSnapshot(_project, _snippet);
    await expectLater(
      api.snippetBlob(_project, snapshot, path: 'README.md'),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
    api.close();
  });

  test('unknown paths and identity/version mismatches fail closed', () async {
    var graphCalls = 0;
    final api = testApi(
      FakeAdapter((request) {
        if (!request.uri.path.endsWith('/graphql')) {
          return jsonResponse(_restSnippet());
        }
        graphCalls++;
        return jsonResponse(
          graphCalls == 1
              ? _listEnvelope(nodes: [_identityNode()])
              : _blobEnvelope(
                  blob: _blob(content: 'stale content'),
                  updatedAt: '2026-08-13T15:25:57Z',
                ),
        );
      }),
    );
    final snapshot = await api.projectSnippetSnapshot(_project, _snippet);
    await expectLater(
      api.snippetBlob(_project, snapshot, path: 'missing.txt'),
      throwsA(_failure(FailureKind.validation)),
    );
    await expectLater(
      api.snippetBlob(_project, snapshot, path: 'README.md'),
      throwsA(_failure(FailureKind.conflict)),
    );
    api.close();
  });

  test(
    'repeated cursors and project mismatches are invalid responses',
    () async {
      var page = 0;
      final cursorApi = testApi(
        FakeAdapter((request) {
          if (!request.uri.path.endsWith('/graphql')) {
            return jsonResponse(_restSnippet());
          }
          page++;
          return jsonResponse(
            _listEnvelope(
              nodes: [_identityNode(snippetId: page)],
              hasNext: true,
              cursor: 'same',
            ),
          );
        }),
      );
      await expectLater(
        cursorApi.projectSnippetSnapshot(_project, _snippet),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      cursorApi.close();

      final mismatch = testApi(
        FakeAdapter((request) {
          if (!request.uri.path.endsWith('/graphql')) {
            return jsonResponse(_restSnippet());
          }
          return jsonResponse(
            _listEnvelope(nodes: [_identityNode(projectId: 99)]),
          );
        }),
      );
      await expectLater(
        mismatch.projectSnippetSnapshot(_project, _snippet),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      mismatch.close();
    },
  );

  test(
    'schema errors are unsupported; unknown errors reveal no message',
    () async {
      for (final entry in <({Object payload, FailureKind kind})>[
        (
          payload: {
            'data': _listEnvelope(nodes: [_identityNode()])['data'],
            'errors': [
              {
                'message': 'private schema',
                'extensions': {'code': 'undefinedField'},
              },
            ],
          },
          kind: FailureKind.unsupported,
        ),
        (
          payload: {
            'data': _listEnvelope(nodes: [_identityNode()])['data'],
            'errors': [
              {'message': 'private unknown'},
            ],
          },
          kind: FailureKind.invalidResponse,
        ),
      ]) {
        final api = testApi(
          FakeAdapter(
            (request) => request.uri.path.endsWith('/graphql')
                ? jsonResponse(entry.payload)
                : jsonResponse(_restSnippet()),
          ),
        );
        try {
          await api.projectSnippetSnapshot(_project, _snippet);
          fail('GraphQL error must fail');
        } on ApiFailure catch (error) {
          expect(error.kind, entry.kind);
          expect('${error.title} ${error.detail}', isNot(contains('private')));
        } finally {
          api.close();
        }
      }
    },
  );

  test('null connections and oversized GraphQL bodies fail closed', () async {
    final missing = testApi(
      FakeAdapter(
        (request) => request.uri.path.endsWith('/graphql')
            ? jsonResponse({
                'data': {'snippets': null},
              })
            : jsonResponse(_restSnippet()),
      ),
    );
    await expectLater(
      missing.projectSnippetSnapshot(_project, _snippet),
      throwsA(_failure(FailureKind.forbidden)),
    );
    missing.close();

    final oversized = testApi(
      FakeAdapter(
        (request) => request.uri.path.endsWith('/graphql')
            ? ResponseBody.fromString('x' * (4 * 1024 * 1024 + 1), 200)
            : jsonResponse(_restSnippet()),
      ),
    );
    await expectLater(
      oversized.projectSnippetSnapshot(_project, _snippet),
      throwsA(_failure(FailureKind.tooLarge)),
    );
    oversized.close();
  });

  test(
    'OAuth rotates for fixed reads and a closed client rejects old data',
    () async {
      var graphQueries = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/oauth/token')) {
          return jsonResponse({
            'access_token': 'rotated-access',
            'refresh_token': 'rotated-refresh',
            'token_type': 'bearer',
            'expires_in': 7200,
          });
        }
        if (!request.uri.path.endsWith('/graphql')) {
          return jsonResponse(_restSnippet());
        }
        graphQueries++;
        if (graphQueries == 1) return jsonResponse({}, status: 401);
        expect(request.headers['Authorization'], 'Bearer rotated-access');
        return jsonResponse(_listEnvelope(nodes: [_identityNode()]));
      });
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final dio = Dio()..httpClientAdapter = adapter;
      final api = GitLabApi(
        instance: instance,
        dio: dio,
        credential: const OAuthCredential(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          clientId: 'app',
        ),
        oauth: OAuthTokenClient(instance: instance, clientId: 'app', dio: dio),
      );
      expect(
        (await api.projectSnippetSnapshot(_project, _snippet)).graphId,
        'gid://gitlab/ProjectSnippet/6030720',
      );
      expect(graphQueries, 2);
      api.close();

      final pending = Completer<ResponseBody>();
      final closed = testApi(
        FakeAdapter((request) {
          if (!request.uri.path.endsWith('/graphql')) {
            return jsonResponse(_restSnippet());
          }
          return pending.future;
        }),
      );
      final operation = closed.projectSnippetSnapshot(_project, _snippet);
      await Future<void>.delayed(Duration.zero);
      closed.close();
      pending.complete(jsonResponse(_listEnvelope(nodes: [_identityNode()])));
      await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
    },
  );
}
