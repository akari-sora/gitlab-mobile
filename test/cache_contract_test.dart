import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

void main() {
  group('cached read contract', () {
    test(
      'cache is opt-in and unbound clients always use the network',
      () async {
        final adapter = FakeAdapter((_) => jsonResponse({'id': 1}));
        final api = _api(adapter);
        addTearDown(api.close);

        await api.cachedRecord(['projects', '1', 'issues', '1']);
        await api.cachedRecord(['projects', '1', 'issues', '1']);
        await api.record(['projects', '1', 'issues', '1']);
        await api.record(['projects', '1', 'issues', '1']);

        expect(adapter.requests, hasLength(4));
      },
    );

    test('record never joins a cached in-flight request', () async {
      final gate = Completer<void>();
      var calls = 0;
      final adapter = FakeAdapter((_) async {
        calls++;
        if (calls == 1) await gate.future;
        return jsonResponse({'id': calls});
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      final cached = api.cachedRecord(['projects', '1', 'issues', '1']);
      await _waitForRequests(adapter, 1);
      final direct = api.record(['projects', '1', 'issues', '1']);
      await _waitForRequests(adapter, 2);
      gate.complete();

      expect((await cached).value['id'], 2);
      expect((await direct)['id'], 2);
      expect(adapter.requests, hasLength(2));
    });

    test('canonical project JSON is shared with typed project reads', () async {
      final adapter = FakeAdapter((request) {
        expect(request.uri.queryParameters['license'], 'true');
        return jsonResponse({...projectJson(8), 'license': null});
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      expect((await api.project('8')).id, 8);
      final raw = await api.cachedRecord(
        ['projects', '8'],
        query: {'license': 'true'},
      );

      expect(raw.value['id'], 8);
      expect(raw.lineage, CacheLineage.memory);
      expect(adapter.requests, hasLength(1));
    });

    test(
      'equivalent query order shares one cached response',
      () async {
        final adapter = FakeAdapter(
          (request) => jsonResponse({'accept': request.headers['Accept']}),
        );
        final api = _boundApi(adapter);
        addTearDown(api.close);

        await api.cachedRecord(
          ['projects', '8', 'issues', '1'],
          query: {'b': '2', 'a': '1'},
        );
        await api.cachedRecord(
          ['projects', '8', 'issues', '1'],
          query: {'a': '1', 'b': '2'},
        );

        expect(adapter.requests, hasLength(1));
      },
    );

    test(
      'continuation pages never cache and poisoned next is rejected',
      () async {
        final adapter = FakeAdapter((request) {
          final next = request.uri.queryParameters.containsKey('page')
              ? null
              : request.uri.replace(
                  queryParameters: {
                    ...request.uri.queryParameters,
                    'page': '2',
                  },
                );
          return jsonResponse(
            [
              {'id': 1},
            ],
            headers: next == null
                ? const {}
                : {
                    'link': ['<$next>; rel="next"'],
                  },
          );
        });
        final api = _boundApi(adapter);
        addTearDown(api.close);

        final first = await api.cachedRecords(['projects', '8', 'issues']);
        expect(first.value.next, isNotNull);
        await api.cachedRecords([
          'projects',
          '8',
          'issues',
        ], next: first.value.next);
        await api.cachedRecords([
          'projects',
          '8',
          'issues',
        ], next: first.value.next);
        expect(adapter.requests, hasLength(3));

        final poisoned = first.value.next!.replace(
          queryParameters: {
            ...first.value.next!.queryParameters,
            'state': 'closed',
          },
        );
        expect(
          () => api.cachedRecords(['projects', '8', 'issues'], next: poisoned),
          throwsA(isA<ApiFailure>()),
        );
        expect(adapter.requests, hasLength(3));
      },
    );

    test('every pagination key bypasses memory caching', () async {
      final adapter = FakeAdapter((_) => jsonResponse(const <Object>[]));
      final api = _boundApi(adapter);
      addTearDown(api.close);

      for (final key in const [
        'page',
        'id_after',
        'page_token',
        'pagination',
        'cursor',
      ]) {
        await api.cachedRecords(
          ['projects', '8', 'issues'],
          query: {key: 'next'},
        );
        await api.cachedRecords(
          ['projects', '8', 'issues'],
          query: {key: 'next'},
        );
      }

      expect(adapter.requests, hasLength(10));
    });

    test('cached values are deeply frozen', () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'nested': {
            'items': [
              {'id': 1},
            ],
          },
        }),
      );
      final api = _boundApi(adapter);
      addTearDown(api.close);

      final value = (await api.cachedRecord([
        'projects',
        '8',
        'issues',
        '1',
      ])).value;
      final nested = value['nested']! as Map<String, dynamic>;
      final items = nested['items']! as List<dynamic>;

      expect(() => value['new'] = true, throwsUnsupportedError);
      expect(() => nested['new'] = true, throwsUnsupportedError);
      expect(() => items.add({'id': 2}), throwsUnsupportedError);
      expect(
        () => (items.single as Map<String, dynamic>)['id'] = 2,
        throwsUnsupportedError,
      );
    });

    test('no-store forbids caching while server max-age is ignored', () async {
      var calls = 0;
      final adapter = FakeAdapter((_) {
        calls++;
        return jsonResponse(
          {'id': calls},
          headers: {
            'cache-control': [calls <= 2 ? 'no-store' : 'private, max-age=0'],
          },
        );
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.cachedRecord(['projects', '8', 'issues', '1']);
      await api.cachedRecord(['projects', '8', 'issues', '1']);
      expect(calls, 2);

      final first = await api.cachedRecord(['projects', '8', 'issues', '2']);
      final second = await api.cachedRecord(['projects', '8', 'issues', '2']);
      expect(first.value['id'], 3);
      expect(second.value['id'], 3);
      expect(calls, 3);
    });

    test(
      'class freshness marks stale and maxAge is a hard upper bound',
      () async {
        var now = DateTime.utc(2026);
        var calls = 0;
        final adapter = FakeAdapter((_) => jsonResponse({'id': ++calls}));
        final api = _boundApi(adapter, clock: () => now);
        addTearDown(api.close);

        final first = await api.cachedRecord(['projects', '8', 'issues', '1']);
        expect(first.stale, isFalse);
        now = now.add(const Duration(seconds: 31));
        final classStale = await api.cachedRecord([
          'projects',
          '8',
          'issues',
          '1',
        ]);
        expect(classStale.value['id'], 1);
        expect(classStale.stale, isTrue);
        expect(calls, 1);

        final bounded = await api.cachedRecord([
          'projects',
          '8',
          'issues',
          '2',
        ], maxAge: const Duration(seconds: 5));
        expect(bounded.value['id'], 2);
        now = now.add(const Duration(seconds: 6));
        final refreshed = await api.cachedRecord([
          'projects',
          '8',
          'issues',
          '2',
        ], maxAge: const Duration(seconds: 5));
        expect(refreshed.value['id'], 3);
        expect(calls, 3);
      },
    );

    test('unknown paths always use network', () async {
      final adapter = FakeAdapter((_) => jsonResponse({'ok': true}));
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.cachedRecord(['synthetic', 'unknown']);
      await api.cachedRecord(['synthetic', 'unknown']);

      expect(adapter.requests, hasLength(2));
    });

    test('issue writes invalidate every declared scope', () async {
      final counts = <String, int>{};
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        counts[path] = (counts[path] ?? 0) + 1;
        if (request.method != 'GET') return jsonResponse({'id': 1});
        if (path.endsWith('/issues') || path.endsWith('/search')) {
          return jsonResponse(const <Object>[]);
        }
        if (path.endsWith('/merge_requests')) {
          return jsonResponse(const <Object>[]);
        }
        return jsonResponse({'id': 1});
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      List<Future<Object>> reads() => [
        api.cachedRecord(['projects', '8', 'issues', '1']),
        api.cachedRecords(['issues']),
        api.cachedRecords(['groups', '3', 'issues']),
        api.cachedRecords(['search'], query: {'scope': 'issues'}),
      ];
      await Future.wait(reads());
      await api.updateIssue(8, 1, {'title': 'Synthetic'});
      await Future.wait(reads());

      expect(counts[_path('/projects/8/issues/1')], 3);
      expect(counts[_path('/issues')], 2);
      expect(counts[_path('/groups/3/issues')], 2);
      expect(counts[_path('/search')], 2);
    });

    for (final scenario in <String, _ScopeScenario>{
      'ordinary project write invalidates project and default': _ScopeScenario(
        mutation: (api) => api.writeRecord(
          'POST',
          ['projects', '8', 'repository', 'branches'],
          {'branch': 'new', 'ref': 'main'},
        ),
        invalidated: {_Scope.project, _Scope.defaultScope},
      ),
      'project creation invalidates project lists and default': _ScopeScenario(
        mutation: (api) =>
            api.writeRecord('POST', ['projects'], {'name': 'Synthetic'}),
        invalidated: {_Scope.projectLists, _Scope.defaultScope},
      ),
      'todo write invalidates user lists and default': _ScopeScenario(
        mutation: (api) => api.markTodoDone(3),
        invalidated: {_Scope.userLists, _Scope.defaultScope},
      ),
      'star invalidates project, project lists, and default': _ScopeScenario(
        mutation: (api) => api.setStar(8, true),
        invalidated: {_Scope.project, _Scope.projectLists, _Scope.defaultScope},
      ),
      'merge invalidates every scope': _ScopeScenario(
        mutation: (api) => api.mergeRequest(8, 1, _sha),
        invalidated: _Scope.values.toSet(),
      ),
      'quick action invalidates every scope': _ScopeScenario(
        mutation: (api) => api.createNote(8, 'issues', 1, '/close'),
        invalidated: _Scope.values.toSet(),
      ),
    }.entries) {
      test(scenario.key, () async {
        final getCounts = <String, int>{};
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (request.method != 'GET') return jsonResponse({'id': 1});
          getCounts[path] = (getCounts[path] ?? 0) + 1;
          if (path.endsWith('/projects') ||
              path.endsWith('/issues') ||
              path.endsWith('/groups/3/issues') ||
              path.endsWith('/search')) {
            return jsonResponse(const <Object>[]);
          }
          return jsonResponse({'id': 1});
        });
        final api = _boundApi(adapter);
        addTearDown(api.close);

        await Future.wait(_scopeReads(api));
        await scenario.value.mutation(api);
        await Future.wait(_scopeReads(api));

        for (final scope in _Scope.values) {
          expect(
            getCounts[_scopePath(scope)],
            scenario.value.invalidated.contains(scope) ? 2 : 1,
            reason: '${scenario.key}: $scope',
          );
        }
      });
    }

    test('a child 404 clears only its path subtree', () async {
      var branchCalls = 0;
      var projectCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects/8')) {
          projectCalls++;
          return jsonResponse({...projectJson(8), 'license': null});
        }
        branchCalls++;
        return branchCalls == 2
            ? jsonResponse({}, status: 404)
            : jsonResponse({
                'name': 'main',
                'commit': {'id': _sha},
              });
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.cachedRecord(['projects', '8'], query: {'license': 'true'});
      await api.cachedRecord([
        'projects',
        '8',
        'repository',
        'branches',
        'main',
      ]);
      await expectLater(
        api.cachedRecord([
          'projects',
          '8',
          'repository',
          'branches',
          'main',
        ], fresh: true),
        throwsA(isA<ApiFailure>()),
      );
      await api.cachedRecord(['projects', '8'], query: {'license': 'true'});
      await api.cachedRecord([
        'projects',
        '8',
        'repository',
        'branches',
        'main',
      ]);

      expect(projectCalls, 1);
      expect(branchCalls, 3);
    });

    test(
      'an issue 404 clears that iid subtree but keeps its sibling',
      () async {
        var issueOneCalls = 0;
        var issueTwoCalls = 0;
        var notesCalls = 0;
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (path.endsWith('/issues/1/notes')) {
            notesCalls++;
            return jsonResponse(const <Object>[]);
          }
          if (path.endsWith('/issues/1')) {
            issueOneCalls++;
            return issueOneCalls == 2
                ? jsonResponse({}, status: 404)
                : jsonResponse({'id': 1, 'iid': 1});
          }
          issueTwoCalls++;
          return jsonResponse({'id': 2, 'iid': 2});
        });
        final api = _boundApi(adapter);
        addTearDown(api.close);

        await api.cachedRecord(['projects', '8', 'issues', '1']);
        await api.cachedRecords(['projects', '8', 'issues', '1', 'notes']);
        await api.cachedRecord(['projects', '8', 'issues', '2']);
        await expectLater(
          api.cachedRecord(['projects', '8', 'issues', '1'], fresh: true),
          throwsA(isA<ApiFailure>()),
        );
        await api.cachedRecords(['projects', '8', 'issues', '1', 'notes']);
        await api.cachedRecord(['projects', '8', 'issues', '2']);

        expect(notesCalls, 2);
        expect(issueTwoCalls, 1);
      },
    );

    test('only exact observed SHA values become pinned', () async {
      const sha64 =
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
      const mrSha = 'cccccccccccccccccccccccccccccccccccccccc';
      const baseSha = 'dddddddddddddddddddddddddddddddddddddddd';
      const startSha = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      final treeCalls = <String, int>{};
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/repository/commits/seen')) {
          return jsonResponse({'id': sha64});
        }
        if (path.endsWith('/merge_requests/1')) {
          return jsonResponse({
            'id': 1,
            'iid': 1,
            'sha': mrSha,
            'diff_refs': {
              'base_sha': baseSha,
              'head_sha': mrSha,
              'start_sha': startSha,
            },
          });
        }
        final ref = request.uri.queryParameters['ref']!;
        treeCalls[ref] = (treeCalls[ref] ?? 0) + 1;
        return jsonResponse(const <Object>[]);
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.cachedRecord([
        'projects',
        '8',
        'repository',
        'commits',
        'seen',
      ]);
      await api.cachedRecord(['projects', '8', 'merge_requests', '1']);
      for (final ref in [sha64.toLowerCase(), mrSha, baseSha, startSha]) {
        await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': ref},
        );
        await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': ref},
        );
        expect(treeCalls[ref], 1, reason: ref);
      }

      for (final length in [39, 40, 41, 64]) {
        final ref = ''.padRight(length, 'f');
        await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': ref},
        );
        await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': ref},
        );
        expect(treeCalls[ref], 2, reason: ref);
      }
    });

    test(
      'confirmed SHA is pinned across writes but revoked by authorization',
      () async {
        var treeCalls = 0;
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (request.method != 'GET') return jsonResponse({'id': 1});
          if (path.endsWith('/repository/branches/main')) {
            return jsonResponse({
              'name': 'main',
              'commit': {'id': _sha},
            });
          }
          if (path.endsWith('/repository/tree')) {
            treeCalls++;
            return jsonResponse([
              {
                'id': _sha,
                'name': 'README.md',
                'type': 'blob',
                'path': 'README.md',
              },
            ]);
          }
          if (path.endsWith('/user')) return jsonResponse({}, status: 401);
          return jsonResponse({...projectJson(8), 'license': null});
        });
        final api = _boundApi(adapter);
        addTearDown(api.close);

        final project = await api.project('8');
        expect(await api.defaultBranchSha(project), _sha);
        await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': _sha, 'path': '', 'per_page': '50'},
        );
        await api.updateIssue(8, 1, {'title': 'Synthetic'});
        await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': _sha, 'path': '', 'per_page': '50'},
        );
        expect(treeCalls, 1);

        await expectLater(api.currentUser(), throwsA(isA<ApiFailure>()));
        await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': _sha, 'path': '', 'per_page': '50'},
        );
        expect(treeCalls, 2);
      },
    );

    test('allowDisk false skips hydrated disk values', () async {
      var networkCalls = 0;
      final fetchedAt = DateTime.utc(2025);
      final adapter = FakeAdapter((_) {
        networkCalls++;
        return jsonResponse({'id': 2});
      });
      final api = _boundApi(
        adapter,
        clock: () => fetchedAt.add(const Duration(seconds: 1)),
        source: (_, _) async => CacheDiskEntry(
          value: {'id': 1},
          fetchedAt: fetchedAt,
          responseBytes: 8,
        ),
      );
      addTearDown(api.close);

      final disk = await api.cachedRecord(['projects', '8', 'issues', '1']);
      expect(disk.value['id'], 1);
      expect(disk.fetchedAt, fetchedAt);
      expect(disk.lineage, CacheLineage.disk);
      expect(networkCalls, 0);

      final network = await api.cachedRecord([
        'projects',
        '8',
        'issues',
        '1',
      ], allowDisk: false);
      expect(network.value['id'], 2);
      expect(network.lineage, CacheLineage.network);
      expect(networkCalls, 1);
    });

    test(
      'binding is one-shot and separate clients remain account-local',
      () async {
        final firstAdapter = FakeAdapter(
          (_) => jsonResponse({'name': 'first'}),
        );
        final secondAdapter = FakeAdapter(
          (_) => jsonResponse({'name': 'second'}),
        );
        final first = _api(firstAdapter);
        final second = _api(secondAdapter);
        addTearDown(first.close);
        addTearDown(second.close);

        final firstKey = '${first.instance.key}#7';
        final secondKey = '${second.instance.key}#8';
        first.bindReadCache(firstKey, 3);
        second.bindReadCache(secondKey, 4);
        expect(first.isReadCacheBound, isTrue);
        expect(first.readCacheAccountKey, firstKey);
        expect(first.readCacheGeneration, 3);
        expect(second.readCacheAccountKey, secondKey);

        expect(
          (await first.cachedRecord([
            'projects',
            '8',
            'issues',
            '1',
          ])).value['name'],
          'first',
        );
        expect(
          (await second.cachedRecord([
            'projects',
            '8',
            'issues',
            '1',
          ])).value['name'],
          'second',
        );
        expect(firstAdapter.requests, hasLength(1));
        expect(secondAdapter.requests, hasLength(1));

        first.bindReadCache(firstKey, 3);
        expect(first.isReadCacheBound, isFalse);
        await first.cachedRecord(['projects', '8', 'issues', '1']);
        await first.cachedRecord(['projects', '8', 'issues', '1']);
        expect(firstAdapter.requests, hasLength(3));
      },
    );

    test(
      'binding rejects a user id contradicted by an observed user',
      () async {
        final wrongAdapter = FakeAdapter(
          (_) =>
              jsonResponse({'id': 8, 'username': 'user-8', 'name': 'User 8'}),
        );
        final wrong = _api(wrongAdapter);
        addTearDown(wrong.close);
        await wrong.currentUser();
        wrong.bindReadCache('${wrong.instance.key}#7', 1);
        expect(wrong.isReadCacheBound, isFalse);

        final rightAdapter = FakeAdapter(
          (_) =>
              jsonResponse({'id': 8, 'username': 'user-8', 'name': 'User 8'}),
        );
        final right = _api(rightAdapter);
        addTearDown(right.close);
        await right.currentUser();
        right.bindReadCache('${right.instance.key}#8', 2);
        expect(right.isReadCacheBound, isTrue);
        expect(right.readCacheGeneration, 2);
      },
    );
  });
}

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

GitLabApi _api(
  FakeAdapter adapter, {
  DateTime Function()? clock,
  Future<CacheDiskEntry?> Function(Uri uri, String accept)? source,
}) {
  return GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheClock: clock,
    readCacheSource: source,
  );
}

GitLabApi _boundApi(
  FakeAdapter adapter, {
  DateTime Function()? clock,
  Future<CacheDiskEntry?> Function(Uri uri, String accept)? source,
}) {
  final api = _api(adapter, clock: clock, source: source);
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

String _path(String suffix) => '/gitlab/api/v4$suffix';

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

enum _Scope { project, projectLists, userLists, groupWorkItems, defaultScope }

final class _ScopeScenario {
  const _ScopeScenario({required this.mutation, required this.invalidated});

  final Future<Object?> Function(GitLabApi api) mutation;
  final Set<_Scope> invalidated;
}

List<Future<Object>> _scopeReads(GitLabApi api) => [
  api.cachedRecord(['projects', '8', 'issues', '1']),
  api.cachedRecords(['projects']),
  api.cachedRecords(['issues']),
  api.cachedRecords(['groups', '3', 'issues']),
  api.cachedRecords(['search'], query: {'scope': 'issues'}),
];

String _scopePath(_Scope scope) => switch (scope) {
  _Scope.project => _path('/projects/8/issues/1'),
  _Scope.projectLists => _path('/projects'),
  _Scope.userLists => _path('/issues'),
  _Scope.groupWorkItems => _path('/groups/3/issues'),
  _Scope.defaultScope => _path('/search'),
};
