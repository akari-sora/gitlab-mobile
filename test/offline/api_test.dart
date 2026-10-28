import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/request_meter.dart';

import '../support/fake_adapter.dart';

const sha = 'ce013625030ba8dba906f756967f9e9ca394464a';
const binding = DiskBinding(
  accountKey: 'https://example.com/gitlab#1',
  generation: 1,
);

Map<String, Object> entry(
  String path, {
  String type = 'blob',
  String mode = '100644',
  String? id,
}) => {
  'path': path,
  'name': path.split('/').last,
  'type': type,
  'mode': mode,
  'id': id ?? sha,
};

void main() {
  test(
    'branch resolves through fresh confirmed read and keyset link is rebuilt',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': sha, 'title': 'x'},
          });
        }
        if (request.uri.queryParameters['page_token'] == null) {
          final next = request.uri.replace(
            queryParameters: {
              ...request.uri.queryParameters,
              'id': '42',
              'page': '1',
              'page_token': 'abc',
              'with_last_commit': 'false',
            },
          );
          return jsonResponse(
            [entry('docs', type: 'tree', mode: '040000')],
            headers: {
              'link': ['<$next>; rel="next"'],
            },
          );
        }
        return jsonResponse([entry('docs/readme')]);
      });
      final api = testApi(adapter)
        ..bindReadCache(binding.accountKey, binding.generation);
      final meter = RequestMeter();
      await meter.runAsync(() async {
        final ref = await api.resolveOfflineRef(
          projectId: 42,
          kind: OfflineRefKind.branch,
          name: 'main',
        );
        expect(ref.sha, sha);
        final validator = OfflineTreeValidator(sha: ref.sha);
        final first = await api.repositoryTreePage(projectId: 42, sha: ref.sha);
        validator.add(first);
        final second = await api.repositoryTreePage(
          projectId: 42,
          sha: ref.sha,
          cursor: first.next,
        );
        validator.add(second);
        validator.finish();
      });
      expect(meter.count, 3);
      final query = adapter.requests.last.uri.queryParameters;
      expect(query['page_token'], 'abc');
      expect(query.containsKey('page'), isFalse);
      expect(query.containsKey('id'), isFalse);
      expect(query.containsKey('with_last_commit'), isFalse);
      api.close();
    },
  );

  test('tag requires an additional confirming commit request', () async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.contains('/tags/')) {
        return jsonResponse({
          'commit': {'id': sha},
        });
      }
      return jsonResponse({'id': sha, 'title': 'commit'});
    });
    final api = testApi(adapter)
      ..bindReadCache(binding.accountKey, binding.generation);
    final ref = await api.resolveOfflineRef(
      projectId: 42,
      kind: OfflineRefKind.tag,
      name: 'v1',
    );
    expect(ref.sha, sha);
    expect(adapter.requests.length, 2);
    expect(adapter.requests.last.uri.path, endsWith('/commits/$sha'));
    api.close();
  });

  test(
    'tree rejects no-store, unsafe continuation, malformed and missing parent',
    () async {
      var treeMode = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': sha},
          });
        }
        if (treeMode == 0) {
          return jsonResponse(
            [entry('readme')],
            headers: {
              'cache-control': ['private, no-store'],
            },
          );
        }
        if (treeMode == 1) {
          final next = request.uri.replace(
            host: 'other.example',
            queryParameters: {
              ...request.uri.queryParameters,
              'page_token': 'x',
            },
          );
          return jsonResponse(
            [entry('readme')],
            headers: {
              'link': ['<$next>; rel="next"'],
            },
          );
        }
        return jsonResponse([entry('docs/readme')]);
      });
      final api = testApi(adapter)
        ..bindReadCache(binding.accountKey, binding.generation);
      await api.resolveOfflineRef(
        projectId: 42,
        kind: OfflineRefKind.branch,
        name: 'main',
      );
      await expectLater(
        api.repositoryTreePage(projectId: 42, sha: sha),
        throwsA(
          isA<OfflineRequestFailure>().having(
            (e) => e.kind,
            'kind',
            OfflineRequestFailureKind.serverForbidsStorage,
          ),
        ),
      );
      treeMode = 1;
      await expectLater(
        api.repositoryTreePage(projectId: 42, sha: sha),
        throwsA(
          isA<OfflineRequestFailure>().having(
            (e) => e.kind,
            'kind',
            OfflineRequestFailureKind.invalidTree,
          ),
        ),
      );
      treeMode = 2;
      final page = await api.repositoryTreePage(projectId: 42, sha: sha);
      final validator = OfflineTreeValidator(sha: sha)..add(page);
      expect(
        validator.finish,
        throwsA(
          isA<OfflineRequestFailure>().having(
            (e) => e.kind,
            'kind',
            OfflineRequestFailureKind.invalidTree,
          ),
        ),
      );
      api.close();
    },
  );

  test(
    'archive disables inherited receive timeout, blocks no-store and redirects',
    () async {
      var mode = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': sha},
          });
        }
        if (mode == 1) {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://other.example'],
            },
          );
        }
        if (mode == 2) {
          return ResponseBody.fromString(
            'a',
            200,
            headers: {
              'cache-control': ['no-store'],
            },
          );
        }
        return ResponseBody.fromBytes(Uint8List.fromList([1, 2, 3]), 200);
      });
      final api = testApi(adapter)
        ..bindReadCache(binding.accountKey, binding.generation);
      await api.resolveOfflineRef(
        projectId: 42,
        kind: OfflineRefKind.branch,
        name: 'main',
      );
      final archive = await api.repositoryArchive(projectId: 42, sha: sha);
      expect(await archive.stream.expand((chunk) => chunk).toList(), [1, 2, 3]);
      expect(adapter.requests.last.receiveTimeout, Duration.zero);
      expect(adapter.requests.last.followRedirects, isFalse);
      expect(
        adapter.requests.last.uri.queryParameters['include_lfs_blobs'],
        'false',
      );
      mode = 1;
      await expectLater(
        api.repositoryArchive(projectId: 42, sha: sha),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.redirectBlocked,
          ),
        ),
      );
      mode = 2;
      await expectLater(
        api.repositoryArchive(projectId: 42, sha: sha),
        throwsA(
          isA<OfflineRequestFailure>().having(
            (e) => e.kind,
            'kind',
            OfflineRequestFailureKind.serverForbidsStorage,
          ),
        ),
      );
      api.close();
    },
  );

  test(
    'only bounded GitLab JSON numeric access-loss reaches the sink',
    () async {
      var response = ResponseBody.fromString(
        '<html/>',
        403,
        headers: {
          'content-type': ['text/html'],
        },
      );
      final adapter = FakeAdapter((_) => response);
      final api = testApi(adapter)
        ..bindReadCache(binding.accountKey, binding.generation);
      final losses = <OfflineAccessLoss>[];
      api.bindOfflineAccess(
        binding: binding,
        onAccessLoss: losses.add,
        onValidatedJson: (_) {},
      );
      Future<void> denied(List<String> path) async {
        await expectLater(api.record(path), throwsA(isA<ApiFailure>()));
      }

      await denied(['projects', '42']);
      expect(losses, isEmpty);
      response = jsonResponse({'message': 'forbidden'}, status: 403);
      await denied(['projects', '42']);
      expect(losses, hasLength(1));
      expect(losses.single.projectId, 42);
      expect(losses.single.scope, OfflineAccessScope.project);
      response = jsonResponse({'message': 'forbidden'}, status: 403);
      await denied(['projects', '42', 'repository', 'files', 'private']);
      expect(losses, hasLength(2));
      expect(losses.last.scope, OfflineAccessScope.repository);
      response = jsonResponse({'message': 'forbidden'}, status: 403);
      await denied(['projects', 'named/path']);
      expect(losses, hasLength(2));
      response = ResponseBody.fromString(
        jsonEncode({'message': 'x' * 4096}),
        403,
        headers: {
          'content-type': ['application/json'],
        },
      );
      await denied(['projects', '42']);
      expect(losses, hasLength(2));
      api.close();
    },
  );

  test(
    'validation hook accepts JSON 2xx once a day, not captive portal HTML',
    () async {
      var html = true;
      final adapter = FakeAdapter(
        (_) => html
            ? ResponseBody.fromString(
                '<html/>',
                200,
                headers: {
                  'content-type': ['text/html'],
                },
              )
            : jsonResponse({'id': 42}),
      );
      final api = testApi(adapter)
        ..bindReadCache(binding.accountKey, binding.generation);
      var validations = 0;
      api.bindOfflineAccess(
        binding: binding,
        onAccessLoss: (_) {},
        onValidatedJson: (_) => validations++,
      );
      await expectLater(
        api.record(['projects', '42']),
        throwsA(isA<ApiFailure>()),
      );
      expect(validations, 0);
      html = false;
      await api.record(['projects', '42']);
      await api.record(['projects', '42']);
      expect(validations, 1);
      api.close();
    },
  );

  test(
    'recoverable OAuth 401 replays archive and admits each physical send',
    () async {
      var archiveRequests = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': sha},
          });
        }
        if (request.uri.path.endsWith('/oauth/token')) {
          return jsonResponse({
            'access_token': 'new-access',
            'refresh_token': 'new-refresh',
            'token_type': 'bearer',
          });
        }
        archiveRequests++;
        if (archiveRequests == 1) {
          return jsonResponse({'message': 'expired'}, status: 401);
        }
        return ResponseBody.fromBytes(Uint8List.fromList([3]), 200);
      });
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final dio = Dio()..httpClientAdapter = adapter;
      final api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          clientId: 'app',
        ),
        dio: dio,
        oauth: OAuthTokenClient(instance: instance, clientId: 'app', dio: dio),
      )..bindReadCache(binding.accountKey, binding.generation);
      final losses = <OfflineAccessLoss>[];
      api.bindOfflineAccess(
        binding: binding,
        onAccessLoss: losses.add,
        onValidatedJson: (_) {},
      );
      await api.resolveOfflineRef(
        projectId: 42,
        kind: OfflineRefKind.branch,
        name: 'main',
      );
      var admitted = 0;
      final meter = RequestMeter(
        includeOAuthTokens: true,
        beforeRequest: () async {
          admitted++;
        },
      );
      await meter.runAsync(() async {
        final archive = await api.repositoryArchive(projectId: 42, sha: sha);
        expect(await archive.stream.expand((chunk) => chunk).toList(), [3]);
      });
      expect(archiveRequests, 2);
      expect(meter.count, 3);
      expect(admitted, 3);
      expect(losses, isEmpty);
      expect(
        adapter.requests.last.headers['Authorization'],
        'Bearer new-access',
      );
      api.close();
    },
  );

  test('caller cancellation fences a tree request before sending', () async {
    final adapter = FakeAdapter(
      (request) => jsonResponse({
        'commit': {'id': sha},
      }),
    );
    final api = testApi(adapter)
      ..bindReadCache(binding.accountKey, binding.generation);
    await api.resolveOfflineRef(
      projectId: 42,
      kind: OfflineRefKind.branch,
      name: 'main',
    );
    final cancelled = CancelToken()..cancel();
    await expectLater(
      api.repositoryTreePage(projectId: 42, sha: sha, cancelToken: cancelled),
      throwsA(
        isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.cancelled),
      ),
    );
    expect(adapter.requests, hasLength(1));
    api.close();
  });

  test(
    'keyset links reject changed revision, project, recursion and subpath',
    () async {
      var tamper = 'ref';
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': sha},
          });
        }
        final params = <String, String>{
          ...request.uri.queryParameters,
          'page_token': 'cursor',
        };
        switch (tamper) {
          case 'ref':
            params['ref'] = '0000000000000000000000000000000000000000';
          case 'id':
            params['id'] = '43';
          case 'recursive':
            params['recursive'] = 'false';
          case 'path':
            params['path'] = 'other';
        }
        final link = request.uri.replace(queryParameters: params);
        return jsonResponse(
          [entry('docs/file')],
          headers: {
            'link': ['<$link>; rel="next"'],
          },
        );
      });
      final api = testApi(adapter)
        ..bindReadCache(binding.accountKey, binding.generation);
      await api.resolveOfflineRef(
        projectId: 42,
        kind: OfflineRefKind.branch,
        name: 'main',
      );
      for (final value in ['ref', 'id', 'recursive', 'path']) {
        tamper = value;
        await expectLater(
          api.repositoryTreePage(projectId: 42, sha: sha, subPath: 'docs'),
          throwsA(
            isA<OfflineRequestFailure>().having(
              (e) => e.kind,
              'kind',
              OfflineRequestFailureKind.invalidTree,
            ),
          ),
        );
      }
      api.close();
    },
  );

  test(
    'tree validates malformed entries and refuses implicit offset fallback',
    () async {
      var responseMode = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': sha},
          });
        }
        switch (responseMode) {
          case 0:
            return jsonResponse([entry('../bad')]);
          case 1:
            return jsonResponse([entry('a', type: 'blob', mode: '040000')]);
          case 2:
            return jsonResponse([entry('a', id: 'F' * 40)]);
          case 3:
            return jsonResponse([entry('a'), entry('a')]);
          default:
            return jsonResponse({'message': 'bad request'}, status: 400);
        }
      });
      final api = testApi(adapter)
        ..bindReadCache(binding.accountKey, binding.generation);
      await api.resolveOfflineRef(
        projectId: 42,
        kind: OfflineRefKind.branch,
        name: 'main',
      );
      for (responseMode = 0; responseMode < 3; responseMode++) {
        await expectLater(
          api.repositoryTreePage(projectId: 42, sha: sha),
          throwsA(
            isA<OfflineRequestFailure>().having(
              (e) => e.kind,
              'kind',
              OfflineRequestFailureKind.invalidTree,
            ),
          ),
        );
      }
      final duplicates = await api.repositoryTreePage(projectId: 42, sha: sha);
      expect(
        () => OfflineTreeValidator(sha: sha).add(duplicates),
        throwsA(
          isA<OfflineRequestFailure>().having(
            (e) => e.kind,
            'kind',
            OfflineRequestFailureKind.invalidTree,
          ),
        ),
      );
      responseMode = 4;
      final before = adapter.requests.length;
      await expectLater(
        api.repositoryTreePage(projectId: 42, sha: sha),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 400)),
      );
      expect(adapter.requests.length, before + 1);
      api.close();
    },
  );

  test(
    'raw file GET detects GitLab JSON access loss before releasing error body',
    () async {
      var html = false;
      final adapter = FakeAdapter(
        (_) => html
            ? ResponseBody.fromString(
                '<html/>',
                403,
                headers: {
                  'content-type': ['text/html'],
                },
              )
            : jsonResponse({'message': 'forbidden'}, status: 403),
      );
      final api = testApi(adapter)
        ..bindReadCache(binding.accountKey, binding.generation);
      final losses = <OfflineAccessLoss>[];
      api.bindOfflineAccess(
        binding: binding,
        onAccessLoss: losses.add,
        onValidatedJson: (_) {},
      );
      await expectLater(
        api.rawFileBytes('42', sha, 'README.md'),
        throwsA(isA<ApiFailure>()),
      );
      expect(losses, hasLength(1));
      expect(losses.single.scope, OfflineAccessScope.repository);
      html = true;
      await expectLater(
        api.rawFileBytes('42', sha, 'README.md'),
        throwsA(isA<ApiFailure>()),
      );
      expect(losses, hasLength(1));
      api.close();
    },
  );
}
