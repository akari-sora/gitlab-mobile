import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/projects/project_controller.dart';
import 'support/fake_adapter.dart';

Matcher failure(FailureKind kind) =>
    isA<ApiFailure>().having((e) => e.kind, 'kind', kind);

void main() {
  test('an admitted UI file read completes HEAD and GET after its cache '
      'admission predicate becomes false', () async {
    final enteredHead = Completer<void>();
    final heldHead = Completer<ResponseBody>();
    final adapter = FakeAdapter((request) {
      if (request.method == 'HEAD') {
        enteredHead.complete();
        return heldHead.future;
      }
      return ResponseBody.fromString('synthetic file', 200);
    });
    final api = testApi(adapter);
    api.bindReadCache('${api.instance.key}#7', 1);
    addTearDown(api.close);
    var current = true;
    final result = CachedRead.run(
      () => api.textFile(8, 'b' * 40, 'README.md'),
      mayStart: () => current,
    );
    await enteredHead.future.timeout(const Duration(seconds: 5));
    current = false;
    heldHead.complete(
      ResponseBody.fromString(
        '',
        200,
        headers: {
          'x-gitlab-size': ['14'],
        },
      ),
    );
    expect(await result, 'synthetic file');
    expect(adapter.requests.map((request) => request.method), ['HEAD', 'GET']);
    expect(
      adapter.requests.every(
        (request) => request.headers['PRIVATE-TOKEN'] == 'synthetic-test-token',
      ),
      isTrue,
    );
  });

  for (final pauseAt in ['401 response', 'token response']) {
    test('an admitted UI read refreshes and replays when its cache predicate '
        'changes at $pauseAt', () async {
      final issueEntered = Completer<void>();
      final held401 = Completer<ResponseBody>();
      final tokenEntered = Completer<void>();
      final heldToken = Completer<ResponseBody>();
      var issueRequests = 0;
      var treeNetworkReads = 0;
      var diskReads = 0;
      final now = DateTime.utc(2026, 10, 23, 8);
      final fetchedAt = now.subtract(const Duration(hours: 2));
      const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final apiAdapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/issues/2')) {
          issueRequests++;
          if (issueRequests == 1) {
            expect(request.headers['Authorization'], 'Bearer old-access');
            issueEntered.complete();
            return held401.future;
          }
          expect(request.headers['Authorization'], 'Bearer new-access');
          return jsonResponse({'id': 2, 'title': 'after refresh'});
        }
        if (path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': sha},
          });
        }
        if (path.endsWith('/repository/tree')) {
          treeNetworkReads++;
          return jsonResponse(const <Object?>[]);
        }
        fail('unexpected API request ${request.uri}');
      });
      final tokenAdapter = FakeAdapter((request) {
        expect(request.method, 'POST');
        expect(request.headers['Authorization'], isNull);
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        final data = request.data;
        final body = data is Map
            ? data.map((key, value) => MapEntry('$key', '$value'))
            : Uri.splitQueryString(data as String);
        expect(body['grant_type'], 'refresh_token');
        expect(body['refresh_token'], 'old-refresh');
        tokenEntered.complete();
        return heldToken.future;
      });
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      OAuthCredential? persisted;
      final api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          clientId: 'synthetic-client',
        ),
        dio: Dio()..httpClientAdapter = apiAdapter,
        oauth: OAuthTokenClient(
          instance: instance,
          clientId: 'synthetic-client',
          dio: Dio()..httpClientAdapter = tokenAdapter,
        ),
        onOAuthRotated: (rotated) async => persisted = rotated,
        readCacheClock: () => now,
        readCacheSource: (uri, _) async {
          if (!uri.path.endsWith('/repository/tree')) return null;
          diskReads++;
          return CacheDiskEntry(
            value: ApiPage<Json>(const <Json>[
              {
                'id': sha,
                'name': 'README.md',
                'type': 'blob',
                'path': 'README.md',
              },
            ]),
            fetchedAt: fetchedAt,
            responseBytes: 64,
          );
        },
      );
      api.bindReadCache('${instance.key}#7', 1);
      addTearDown(api.close);
      var current = true;
      final result = CachedRead.run(
        () => api.cachedRecord(<String>['projects', '1', 'issues', '2']),
        mayStart: () => current,
      );
      await issueEntered.future.timeout(const Duration(seconds: 5));
      if (pauseAt == '401 response') current = false;
      held401.complete(jsonResponse({'message': 'expired'}, status: 401));
      await tokenEntered.future.timeout(const Duration(seconds: 5));
      if (pauseAt == 'token response') current = false;
      heldToken.complete(
        jsonResponse({
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'token_type': 'bearer',
        }),
      );
      final read = await result;
      expect(read.value['title'], 'after refresh');
      expect(issueRequests, 2);
      expect(tokenAdapter.requests, hasLength(1));
      expect(persisted?.accessToken, 'new-access');
      expect(persisted?.refreshToken, 'new-refresh');

      await api.cachedRecord(<String>[
        'projects',
        '1',
        'repository',
        'branches',
        'main',
      ]);
      final tree = await api.cachedRecords(
        <String>['projects', '1', 'repository', 'tree'],
        query: const <String, String>{'ref': sha, 'path': '', 'per_page': '50'},
      );
      expect(tree.lineage, CacheLineage.disk);
      expect(tree.fetchedAt, fetchedAt);
      expect(tree.value.items.single['name'], 'README.md');
      expect(diskReads, 1);
      expect(treeNetworkReads, 0);
    });
  }

  test(
    'A04 GET /user validates identity and sends token only in header',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final user = await api.currentUser();
      expect(user.id, 7);
      final request = adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.toString(), 'https://example.com/gitlab/api/v4/user');
      expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
      expect(request.headers['Authorization'], isNull);
      expect(request.uri.toString(), isNot(contains('synthetic-test-token')));
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
    },
  );
  test(
    'OAuth access token is sent as Bearer and never as PRIVATE-TOKEN or query',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final api = GitLabApi(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        credential: const OAuthCredential(
          accessToken: 'oauth-access-token',
          refreshToken: 'oauth-refresh-token',
          clientId: 'synthetic-app-id',
        ),
        dio: dio,
      );
      addTearDown(api.close);
      await api.currentUser();
      final request = adapter.requests.single;
      expect(request.headers['Authorization'], 'Bearer oauth-access-token');
      expect(request.headers['PRIVATE-TOKEN'], isNull);
      expect(request.uri.toString(), isNot(contains('oauth-access-token')));
      expect(request.followRedirects, isFalse);
    },
  );
  for (final pair in [
    (401, FailureKind.unauthenticated),
    (403, FailureKind.forbidden),
    (404, FailureKind.invisible),
    (429, FailureKind.rateLimited),
    (503, FailureKind.server),
    (302, FailureKind.redirectBlocked),
  ]) {
    test(
      'HTTP ${pair.$1} has distinct semantics; never exposes response body',
      () async {
        final adapter = FakeAdapter(
          (_) => jsonResponse({
            'message': 'private-server-content',
          }, status: pair.$1),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(api.currentUser(), throwsA(failure(pair.$2)));
        expect(adapter.requests.length, 1); // No hidden automatic retry.
      },
    );
  }
  test('P01 accessible search omits membership and starred filters', () async {
    final adapter = FakeAdapter((_) => jsonResponse([projectJson(8)]));
    final api = testApi(adapter);
    addTearDown(api.close);
    await api.projects(scope: ProjectScope.accessibleSearch, search: 'repo');
    expect(
      adapter.requests.single.uri.queryParameters.containsKey('membership'),
      isFalse,
    );
    expect(
      adapter.requests.single.uri.queryParameters.containsKey('starred'),
      isFalse,
    );
  });
  test('P01 membership filter is explicit', () async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final api = testApi(adapter);
    addTearDown(api.close);
    await api.projects(scope: ProjectScope.member);
    expect(adapter.requests.single.uri.queryParameters['membership'], 'true');
  });
  test(
    'P01 rejects off-origin continuation before issuing any request',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse([]));
      final api = testApi(adapter);
      addTearDown(api.close);
      expect(
        () => api.projects(
          scope: ProjectScope.member,
          next: Uri.parse('https://evil.example/api/v4/projects'),
        ),
        throwsA(failure(FailureKind.unsupported)),
      );
      expect(adapter.requests, isEmpty);
    },
  );
  test('P02 full namespace resolves to a numeric canonical project', () async {
    final adapter = FakeAdapter((_) => jsonResponse(projectJson(8)));
    final api = testApi(adapter);
    addTearDown(api.close);
    final project = await api.project('team/sub/project');
    expect(project.id, 8);
    expect(adapter.requests.single.uri.pathSegments.last, 'team/sub/project');
  });
  test('R01 tree preserves SHA and path and accepts an empty tree', () async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final api = testApi(adapter);
    addTearDown(api.close);
    final page = await api.tree(8, 'd' * 40, path: 'lib/nested');
    expect(page.items, isEmpty);
    expect(adapter.requests.single.uri.queryParameters['ref'], 'd' * 40);
    expect(adapter.requests.single.uri.queryParameters['path'], 'lib/nested');
  });
  test(
    '429 Retry-After blocks early manual retry without another network call',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(
          {},
          status: 429,
          headers: {
            'retry-after': ['60'],
          },
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.currentUser(),
        throwsA(failure(FailureKind.rateLimited)),
      );
      await expectLater(
        api.currentUser(),
        throwsA(failure(FailureKind.rateLimited)),
      );
      expect(adapter.requests.length, 1);
    },
  );
  test('R06 branch with slash resolves to a fixed SHA', () async {
    final sha = 'a' * 40;
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'commit': {'id': sha},
      }),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final project = Project.fromJson(projectJson(8, branch: 'feature/session'));
    expect(await api.defaultBranchSha(project), sha);
    expect(adapter.requests.single.uri.pathSegments.last, 'feature/session');
    expect(
      adapter.requests.single.uri.toString(),
      contains('feature%2Fsession'),
    );
  });
  test(
    'R02/R04 metadata then exactly one raw fetch, both at same SHA',
    () async {
      final sha = 'b' * 40;
      final adapter = FakeAdapter(
        (r) => r.method == 'HEAD'
            ? ResponseBody.fromString(
                '',
                200,
                headers: {
                  'x-gitlab-size': ['12'],
                },
              )
            : ResponseBody.fromString('hello\nworld', 200),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      expect(await api.textFile(8, sha, 'lib/nested.dart'), 'hello\nworld');
      expect(adapter.requests.map((r) => r.method), ['HEAD', 'GET']);
      expect(
        adapter.requests.every((r) => r.uri.queryParameters['ref'] == sha),
        isTrue,
      );
      expect(adapter.requests.last.uri.pathSegments.last, 'raw');
      expect(
        adapter.requests.last.uri.toString(),
        contains('lib%2Fnested.dart'),
      );
    },
  );
  test('R02 refuses excessive size without raw-content request', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString(
        '',
        200,
        headers: {
          'x-gitlab-size': ['999999999'],
        },
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.textFile(8, 'c' * 40, 'large.bin'),
      throwsA(failure(FailureKind.tooLarge)),
    );
    expect(adapter.requests.length, 1);
  });
  test('R04 binary file does not become an invalid text preview', () async {
    final adapter = FakeAdapter(
      (r) => ResponseBody.fromString(r.method == 'HEAD' ? '' : 'a\u0000b', 200),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.textFile(8, 'c' * 40, 'file.bin'),
      throwsA(failure(FailureKind.unsupported)),
    );
  });
  test('P01 page-two error preserves existing rows and retry cursor', () async {
    final adapter = FakeAdapter(
      (r) => r.uri.queryParameters['page'] == '2'
          ? jsonResponse({}, status: 503)
          : jsonResponse(
              [projectJson(8)],
              headers: {
                'x-next-page': ['2'],
              },
            ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final controller = ProjectController(api);
    addTearDown(controller.dispose);
    await controller.refresh();
    await controller.loadMore();
    expect(controller.items.single.id, 8);
    expect(controller.pageError?.kind, FailureKind.server);
    expect(controller.next?.queryParameters['page'], '2');
  });
  test('P01 stale search response cannot replace a newer scope', () async {
    final slow = Completer<ResponseBody>();
    final adapter = FakeAdapter(
      (r) => r.uri.queryParameters['search'] == 'old'
          ? slow.future
          : jsonResponse([projectJson(9)]),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final controller = ProjectController(api);
    addTearDown(controller.dispose);
    final older = controller.search(ProjectScope.member, 'old');
    await Future<void>.delayed(Duration.zero);
    await controller.search(ProjectScope.accessibleSearch, 'new');
    slow.complete(jsonResponse([projectJson(8)]));
    await older;
    expect(controller.items.single.id, 9);
  });
  test('closed session never sends a new authenticated request', () async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final api = testApi(adapter);
    api.close();
    await expectLater(
      api.currentUser(),
      throwsA(failure(FailureKind.cancelled)),
    );
    expect(adapter.requests, isEmpty);
  });
}
