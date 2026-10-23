import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

const _limit = 4096;
const _deadline = Duration(seconds: 20);
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _issuePath = ['projects', '8', 'issues', '1'];
const _notesPath = [..._issuePath, 'notes'];
const _treePath = ['projects', '8', 'repository', 'tree'];

void main() {
  for (final collection in [false, true]) {
    for (final disk in [false, true]) {
      test(
        'refreshed ${collection ? 'collection' : 'subtree'} revocation '
        'does not advance the ${disk ? 'disk' : 'permission'} floor past older entries',
        () async {
          var now = DateTime.utc(2026, 10, 23);
          final held = Completer<ResponseBody>();
          final started = Completer<void>();
          final adapter = FakeAdapter((request) {
            if (request.uri.path.endsWith('/branches/main')) {
              return jsonResponse({
                'commit': {'id': _sha},
              });
            }
            if (request.uri.path.endsWith('/projects/8/issues/1')) {
              started.complete();
              return held.future;
            }
            if (request.uri.path.endsWith('/tree')) {
              return jsonResponse(<Object>[]);
            }
            return jsonResponse({}, status: 404);
          });
          final api = _api(
            adapter,
            clock: () => now,
            source: (_, _) async => CacheDiskEntry(
              value: ApiPage<Json>(const []),
              fetchedAt: DateTime.utc(2026, 10, 23, 0, 1),
              responseBytes: 2,
            ),
          );
          addTearDown(api.close);
          await api.record(['projects', '8', 'repository', 'branches', 'main']);
          Future<void> revoke(int id) => expectLater(
            collection
                ? api.records(['issues'], query: {'scope': 'missing-$id'})
                : api.record(['projects', '$id', 'missing']),
            throwsA(isA<ApiFailure>()),
          );

          for (var id = 1; id <= _limit; id++) {
            await revoke(id);
          }
          now = now.add(const Duration(minutes: 2));
          Future<Object>? outcome;
          if (!disk) {
            outcome = api
                .cachedRecord(_issuePath, fresh: true)
                .then<Object>(
                  (value) => value,
                  onError: (Object error) => error,
                );
            await started.future.timeout(_deadline);
          }
          await revoke(1);
          await revoke(_limit + 1);

          if (disk) {
            expect(
              (await api.cachedRecords(
                _treePath,
                query: {'ref': _sha},
              )).lineage,
              CacheLineage.disk,
            );
          } else {
            held.complete(jsonResponse({'title': 'unrelated'}));
            expect(await outcome!.timeout(_deadline), isA<CachedRead<Json>>());
          }
        },
      );
    }
  }

  test(
    'compacted privacy revocations preserve unrelated pinned disk data',
    () async {
      var now = DateTime.utc(2026, 10, 23);
      var confidential = false;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': _sha},
          });
        }
        if (request.uri.path.endsWith('/issues')) {
          return jsonResponse([
            for (var iid = 1; iid <= _limit + 1; iid++)
              {..._issue(confidential), 'project_id': 9, 'iid': iid},
          ]);
        }
        if (request.uri.path.endsWith('/tree')) return jsonResponse(<Object>[]);
        return jsonResponse({}, status: 403);
      });
      final api = _api(
        adapter,
        clock: () => now,
        source: (_, _) async => CacheDiskEntry(
          value: ApiPage<Json>(const []),
          fetchedAt: DateTime.utc(2026, 10, 23, 0, 1),
          responseBytes: 2,
        ),
      );
      addTearDown(api.close);
      await api.record(['projects', '8', 'repository', 'branches', 'main']);
      await api.records(['issues']);
      now = now.add(const Duration(minutes: 2));
      confidential = true;
      await api.records(['issues']);

      expect(
        (await api.cachedRecords(_treePath, query: {'ref': _sha})).lineage,
        CacheLineage.disk,
      );
      expect(
        api.readCacheMetadataCounts.values,
        everyElement(lessThanOrEqualTo(_limit)),
      );
      await expectLater(
        api.record(['projects', '8']),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        (await api.cachedRecords(_treePath, query: {'ref': _sha})).lineage,
        CacheLineage.network,
      );
    },
  );

  for (final sameTime in [false, true]) {
    test(
      'older disk privacy cannot replace newer network privacy, equal time=$sameTime',
      () async {
        final now = DateTime.utc(2026, 10, 23);
        final held = Completer<ResponseBody>();
        final started = Completer<void>();
        final adapter = FakeAdapter((request) {
          if (request.uri.path.endsWith('/notes')) {
            started.complete();
            return held.future;
          }
          return jsonResponse(_issue(true));
        });
        final api = _api(
          adapter,
          clock: () => now,
          source: (uri, _) async => uri.path.endsWith('/api/v4/issues')
              ? CacheDiskEntry(
                  value: ApiPage<Json>([_issue(false)]),
                  fetchedAt: sameTime
                      ? now
                      : now.subtract(const Duration(minutes: 1)),
                  responseBytes: 64,
                )
              : null,
        );
        addTearDown(api.close);
        await api.record(_issuePath);
        expect(
          (await api.cachedRecords(['issues'])).lineage,
          CacheLineage.disk,
        );
        final notes = api
            .cachedRecords(_notesPath)
            .then<Object>((value) => value, onError: (Object error) => error);
        await started.future.timeout(_deadline);
        await api.record(_issuePath);
        held.complete(
          jsonResponse([
            {'body': 'current authorized notes'},
          ]),
        );

        expect(
          await notes.timeout(_deadline),
          isA<CachedRead<ApiPage<Json>>>(),
        );
      },
    );
  }

  test('alias hydration reuses a newer numeric publication', () async {
    final now = DateTime.utc(2026, 10, 23);
    final disk = Completer<CacheDiskEntry?>();
    final started = Completer<void>();
    var calls = 0;
    final api = _api(
      FakeAdapter((_) {
        calls++;
        return jsonResponse({...projectJson(8), 'name': 'network'});
      }),
      clock: () => now,
      source: (_, _) {
        started.complete();
        return disk.future;
      },
    );
    addTearDown(api.close);
    final pending = api.cachedRecord(['projects', 'team/example-8']);
    await started.future.timeout(_deadline);
    await api.cachedRecord(['projects', '8'], fresh: true);
    disk.complete(
      CacheDiskEntry(
        value: {...projectJson(8), 'name': 'disk'},
        fetchedAt: now.subtract(const Duration(minutes: 1)),
        responseBytes: 128,
      ),
    );

    final result = await pending.timeout(_deadline);
    expect(result.value['name'], 'network');
    expect(result.lineage, CacheLineage.memory);
    expect(calls, 1);
  });

  for (final scenario in [
    'network',
    'disk',
    'disk miss',
    'disk error',
    'network error',
  ]) {
    test('finished publication tickets are retired after $scenario', () async {
      final now = DateTime.utc(2026, 10, 23);
      final api = _api(
        FakeAdapter(
          (_) => jsonResponse({
            'title': 'network',
          }, status: scenario == 'network error' ? 503 : 200),
        ),
        clock: () => now,
        source: scenario == 'network' || scenario == 'network error'
            ? null
            : (_, _) async {
                if (scenario == 'disk error') {
                  throw StateError('synthetic disk error');
                }
                if (scenario == 'disk miss') return null;
                return CacheDiskEntry(
                  value: {'title': 'disk'},
                  fetchedAt: now,
                  responseBytes: 32,
                );
              },
      );
      addTearDown(api.close);
      final read = api.cachedRecord(_issuePath);
      if (scenario.endsWith('error')) {
        await expectLater(
          read,
          throwsA(anyOf(isA<ApiFailure>(), isA<StateError>())),
        );
      } else {
        await read;
      }
      expect(api.readCacheMetadataCounts['publications'], 0);
    });
  }

  test(
    'finished newer tickets fence older aliases until all reads settle',
    () async {
      final held = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = FakeAdapter((request) {
        if (request.uri.pathSegments.last == 'team/old') {
          started.complete();
          return held.future;
        }
        return jsonResponse({...projectJson(8), 'name': 'new'});
      });
      final api = _api(adapter);
      addTearDown(api.close);
      final pending = api.cachedRecord(['projects', 'team/old']);
      await started.future.timeout(_deadline);
      await api.cachedRecord(['projects', '8'], fresh: true);
      held.complete(
        jsonResponse({
          ...projectJson(8),
          'name': 'old',
          'path_with_namespace': 'team/old',
        }),
      );
      await pending.timeout(_deadline);

      expect((await api.cachedRecord(['projects', '8'])).value['name'], 'new');
      expect(adapter.requests, hasLength(2));
      expect(api.readCacheMetadataCounts['publications'], 0);
    },
  );

  for (final status in [403, 404]) {
    test(
      'GraphQL $status preserves pinned memory and disk; REST $status revokes',
      () async {
        final now = DateTime.utc(2026, 10, 23);
        var denyRest = false;
        final adapter = FakeAdapter((request) {
          if (request.uri.path.endsWith('/api/graphql') || denyRest) {
            return jsonResponse({}, status: status);
          }
          if (request.uri.path.endsWith('/branches/main')) {
            return jsonResponse({
              'commit': {'id': _sha},
            });
          }
          return jsonResponse(<Object>[]);
        });
        final api = _api(
          adapter,
          clock: () => now,
          source: (_, _) async => CacheDiskEntry(
            value: ApiPage<Json>(const []),
            fetchedAt: now.subtract(const Duration(minutes: 1)),
            responseBytes: 2,
          ),
        );
        addTearDown(api.close);
        await api.record(['projects', '8', 'repository', 'branches', 'main']);
        await api.cachedRecords(
          _treePath,
          query: {'ref': _sha, 'path': 'memory'},
          allowDisk: false,
        );
        await expectLater(
          api.pipelineGraphPage(Project.fromJson(projectJson(8)), 1),
          throwsA(isA<ApiFailure>()),
        );
        expect(
          (await api.cachedRecords(
            _treePath,
            query: {'ref': _sha, 'path': 'memory'},
          )).lineage,
          CacheLineage.memory,
        );
        expect(
          (await api.cachedRecords(
            _treePath,
            query: {'ref': _sha, 'path': 'disk'},
          )).lineage,
          CacheLineage.disk,
        );
        denyRest = true;
        await expectLater(
          api.record(['projects', '8']),
          throwsA(isA<ApiFailure>()),
        );
        denyRest = false;
        expect(
          (await api.cachedRecords(
            _treePath,
            query: {'ref': _sha, 'path': 'disk'},
          )).lineage,
          CacheLineage.network,
        );
      },
    );
  }
}

Json _issue(bool confidential) => {
  'id': 101,
  'project_id': 8,
  'iid': 1,
  'confidential': confidential,
};

GitLabApi _api(
  FakeAdapter adapter, {
  DateTime Function()? clock,
  ReadCacheSource? source,
}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheClock: clock,
    readCacheSource: source,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}
