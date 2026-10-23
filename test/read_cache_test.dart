import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'support/fake_adapter.dart';

void main() {
  for (final policy in [
    'no-store',
    'no-cache',
    'max-age=0',
    'private, must-revalidate',
  ]) {
    test('project and raw-file cache respect $policy', () async {
      final adapter = FakeAdapter((request) {
        final headers = {
          'cache-control': [policy],
        };
        if (request.uri.path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': 'c' * 40},
          });
        }
        if (request.uri.path.endsWith('/projects/8')) {
          return jsonResponse(projectJson(8), headers: headers);
        }
        return ResponseBody.fromString(
          request.method == 'HEAD' ? '' : 'hello',
          200,
          headers: {
            ...headers,
            'x-gitlab-size': ['5'],
          },
        );
      });
      final api = _boundTestApi(adapter);
      addTearDown(api.close);
      final project = await api.project('8');
      await api.defaultBranchSha(project);
      await api.project('8');
      await api.textFile(8, 'c' * 40, 'README.md');
      await api.textFile(8, 'c' * 40, 'README.md');
      expect(adapter.requests, hasLength(policy == 'no-store' ? 7 : 4));
    });
  }

  test('server TTL and response age do not shorten application TTL', () async {
    var now = DateTime.utc(2026);
    final adapter = FakeAdapter(
      (_) => jsonResponse(
        projectJson(8),
        headers: {
          'cache-control': ['private, max-age=10'],
          'age': ['8'],
        },
      ),
    );
    final api = _boundApi(adapter, clock: () => now);
    addTearDown(api.close);
    await api.project('8');
    now = now.add(const Duration(seconds: 1));
    await api.project('8');
    expect(adapter.requests, hasLength(1));
    now = now.add(const Duration(seconds: 1));
    await api.project('8');
    expect(adapter.requests, hasLength(1));
  });

  test(
    'must-revalidate is ignored but explicit refresh still uses network',
    () async {
      var now = DateTime.utc(2026);
      var reads = 0;
      final adapter = FakeAdapter((_) {
        reads++;
        return jsonResponse(
          projectJson(8),
          status: reads > 1 ? 503 : 200,
          headers: {
            'cache-control': ['private, max-age=10, must-revalidate'],
          },
        );
      });
      final api = _boundApi(adapter, clock: () => now);
      addTearDown(api.close);
      await api.project('8');
      now = now.add(const Duration(seconds: 9));
      await api.project('8');
      expect(reads, 1);
      now = now.add(const Duration(seconds: 1));
      await api.project('8');
      expect(reads, 1);
      await expectLater(
        api.project('8', refresh: true),
        throwsA(isA<ApiFailure>()),
      );
      expect(reads, 2);
    },
  );

  test(
    'metadata TTL expires and explicit refresh bypasses a warm cache',
    () async {
      var now = DateTime.utc(2026);
      var reads = 0;
      final adapter = FakeAdapter(
        (_) => jsonResponse({...projectJson(8), 'name': 'Read ${++reads}'}),
      );
      final api = _boundApi(adapter, clock: () => now);
      addTearDown(api.close);
      expect((await api.project('8')).name, 'Read 1');
      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect((await api.project('8')).name, 'Read 1');
      now = now.add(const Duration(seconds: 1));
      expect((await api.project('8')).name, 'Read 2');
      expect((await api.project('8', refresh: true)).name, 'Read 3');
    },
  );

  test(
    'cache evicts least recently used projects at the entry bound',
    () async {
      final adapter = FakeAdapter(
        (request) =>
            jsonResponse(projectJson(int.parse(request.uri.pathSegments.last))),
      );
      final api = _boundTestApi(adapter);
      addTearDown(api.close);
      for (var id = 1; id <= GitLabApi.maxCachedReads; id++) {
        await api.project('$id');
      }
      await api.project('1'); // Touch the oldest entry.
      await api.project('${GitLabApi.maxCachedReads + 1}');
      await api.project('1');
      expect(adapter.requests, hasLength(GitLabApi.maxCachedReads + 1));
      await api.project('2');
      expect(adapter.requests, hasLength(GitLabApi.maxCachedReads + 2));
    },
  );

  test(
    'text entries over 1 MiB are not retained and refresh reads the server',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': 'c' * 40},
          });
        }
        return request.method == 'HEAD'
            ? ResponseBody.fromString(
                '',
                200,
                headers: {
                  'x-gitlab-size': ['1100000'],
                },
              )
            : ResponseBody.fromString('a' * 1100000, 200);
      });
      final api = _boundTestApi(adapter);
      addTearDown(api.close);
      await api.cachedRecord([
        'projects',
        '8',
        'repository',
        'branches',
        'main',
      ]);
      for (var file = 1; file <= 3; file++) {
        await api.textFile(8, 'c' * 40, '$file.txt');
      }
      await api.textFile(8, 'c' * 40, '2.txt');
      expect(adapter.requests, hasLength(9));
      await api.textFile(8, 'c' * 40, '1.txt');
      expect(adapter.requests, hasLength(11));
      await api.textFile(8, 'c' * 40, '1.txt', refresh: true);
      expect(adapter.requests, hasLength(13));
    },
  );

  test('unrelated 403 does not invalidate cached project metadata', () async {
    final adapter = FakeAdapter(
      (request) => request.uri.path.endsWith('/user')
          ? jsonResponse({}, status: 403)
          : jsonResponse(projectJson(8)),
    );
    final api = _boundTestApi(adapter);
    addTearDown(api.close);
    await api.project('8');
    await expectLater(api.currentUser(), throwsA(isA<ApiFailure>()));
    await api.project('8');
    expect(adapter.requests, hasLength(2));
  });

  test('reopening a project reuses account-local metadata', () async {
    final adapter = FakeAdapter((_) => jsonResponse(projectJson(8)));
    final api = _boundTestApi(adapter);
    addTearDown(api.close);
    await api.project('8');
    await api.project('8');
    expect(adapter.requests, hasLength(1));
  });

  test('concurrent project resolution shares one request', () async {
    final gate = Completer<void>();
    final adapter = FakeAdapter((_) async {
      await gate.future;
      return jsonResponse(projectJson(8));
    });
    final api = _boundTestApi(adapter);
    addTearDown(api.close);
    final first = api.project('8');
    final second = api.project('8');
    await _waitForRequests(adapter, 1);
    gate.complete();
    expect((await first).id, 8);
    expect((await second).id, 8);
    expect(adapter.requests, hasLength(1));
  });

  test('failed resolution remains retryable and is never cached', () async {
    var count = 0;
    final adapter = FakeAdapter(
      (_) => ++count == 1
          ? jsonResponse({}, status: 404)
          : jsonResponse(projectJson(8)),
    );
    final api = _boundTestApi(adapter);
    addTearDown(api.close);
    await expectLater(api.project('8'), throwsA(isA<ApiFailure>()));
    expect((await api.project('8')).id, 8);
    expect(adapter.requests, hasLength(2));
  });

  test(
    'writes invalidate reads even when their outcome is uncertain',
    () async {
      var reads = 0;
      final adapter = FakeAdapter(
        (request) => request.method == 'GET'
            ? jsonResponse({...projectJson(8), 'name': 'Revision ${++reads}'})
            : jsonResponse({}, status: 503),
      );
      final api = _boundTestApi(adapter);
      addTearDown(api.close);
      expect((await api.project('8')).name, 'Revision 1');
      await expectLater(
        api.updateIssue(8, 1, {'title': 'Synthetic'}),
        throwsA(isA<ApiFailure>()),
      );
      expect((await api.project('8')).name, 'Revision 2');
    },
  );

  test('a pre-write response cannot repopulate the cache', () async {
    final old = Completer<ResponseBody>();
    var reads = 0;
    final adapter = FakeAdapter((request) {
      if (request.method != 'GET') return jsonResponse({'id': 1});
      if (++reads == 1) return old.future;
      return jsonResponse({...projectJson(8), 'name': 'New'});
    });
    final api = _boundTestApi(adapter);
    addTearDown(api.close);
    final pending = api.project('8');
    await _waitForRequests(adapter, 1);
    await api.updateIssue(8, 1, {'title': 'Synthetic'});
    old.complete(jsonResponse({...projectJson(8), 'name': 'Old'}));
    expect((await pending).name, 'New');
    expect((await api.project('8')).name, 'New');
  });

  test(
    'immutable SHA files reuse bounded text reads; moving refs stay fresh',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': 'c' * 40},
          });
        }
        return request.method == 'HEAD'
            ? ResponseBody.fromString(
                '',
                200,
                headers: {
                  'x-gitlab-size': ['5'],
                },
              )
            : ResponseBody.fromString('hello', 200);
      });
      final api = _boundTestApi(adapter);
      addTearDown(api.close);
      await api.cachedRecord([
        'projects',
        '8',
        'repository',
        'branches',
        'main',
      ]);
      for (var i = 0; i < 2; i++) {
        expect(await api.textFile(8, 'c' * 40, 'README.md'), 'hello');
      }
      expect(adapter.requests, hasLength(3));
      for (var i = 0; i < 2; i++) {
        await api.textFile(8, 'main', 'README.md');
      }
      expect(adapter.requests, hasLength(7));
    },
  );

  test('client close cannot serve cached private data', () async {
    final adapter = FakeAdapter((_) => jsonResponse(projectJson(8)));
    final api = _boundTestApi(adapter);
    await api.project('8');
    api.close();
    await expectLater(
      api.project('8'),
      throwsA(
        isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.cancelled),
      ),
    );
  });

  test('separate account clients never share cached data', () async {
    final first = FakeAdapter(
      (_) => jsonResponse({...projectJson(8), 'name': 'First account'}),
    );
    final second = FakeAdapter(
      (_) => jsonResponse({...projectJson(8), 'name': 'Second account'}),
    );
    final a = _boundTestApi(first), b = _boundTestApi(second, userId: 8);
    addTearDown(a.close);
    addTearDown(b.close);
    expect((await a.project('8')).name, 'First account');
    expect((await b.project('8')).name, 'Second account');
    expect(second.requests, hasLength(1));
  });

  test('no-body mutations accept 204 and remain single writes', () async {
    final adapter = FakeAdapter((_) => ResponseBody.fromString('', 204));
    final api = _boundTestApi(adapter);
    addTearDown(api.close);
    await api.writeEmpty('POST', [
      'projects',
      '8',
      'merge_requests',
      '1',
      'draft_notes',
      'bulk_publish',
    ]);
    expect(adapter.requests.single.method, 'POST');
  });
}

GitLabApi _boundTestApi(FakeAdapter adapter, {int userId = 7}) {
  final api = testApi(adapter);
  api.bindReadCache('${api.instance.key}#$userId', 1);
  return api;
}

GitLabApi _boundApi(FakeAdapter adapter, {DateTime Function()? clock}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com'),
    token: 'synthetic-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheClock: clock,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

Future<void> _waitForRequests(FakeAdapter adapter, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (adapter.requests.length < count) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'Expected $count requests, saw ${adapter.requests.length}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
