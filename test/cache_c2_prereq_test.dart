import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';
import 'support/work_item_labels_fixture.dart';

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
          if (request.uri.path.endsWith('/api/v4/issues')) {
            return jsonResponse([_issue(true)]);
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
          CacheLineage.network,
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

  test(
    'held alias hydration reads the caller URI after a project rename',
    () async {
      final now = DateTime.utc(2026, 10, 23);
      final disk = Completer<CacheDiskEntry?>();
      final started = Completer<void>();
      var renamed = false;
      final adapter = FakeAdapter((request) {
        final project = request.uri.pathSegments.last;
        if (project == '8') {
          return jsonResponse({
            ...projectJson(8),
            'path_with_namespace': renamed ? 'team/new' : 'team/old',
          });
        }
        if (project == 'team/old') {
          return jsonResponse({
            ...projectJson(renamed ? 9 : 8),
            'path_with_namespace': 'team/old',
          });
        }
        throw StateError('Unexpected project URI: ${request.uri}');
      });
      final api = _api(
        adapter,
        clock: () => now,
        source: (_, _) {
          started.complete();
          return disk.future;
        },
      );
      addTearDown(api.close);
      final pending = api.cachedRecord(['projects', 'team/old']);
      await started.future.timeout(_deadline);
      expect(
        (await api.cachedRecord([
          'projects',
          '8',
        ], fresh: true)).value['path_with_namespace'],
        'team/old',
      );
      renamed = true;
      expect(
        (await api.cachedRecord([
          'projects',
          '8',
        ], fresh: true)).value['path_with_namespace'],
        'team/new',
      );
      disk.complete(
        CacheDiskEntry(
          value: {...projectJson(8), 'path_with_namespace': 'team/old'},
          fetchedAt: now.subtract(const Duration(minutes: 1)),
          responseBytes: 128,
        ),
      );

      final result = await pending.timeout(_deadline);
      expect(result.value['id'], 9);
      expect(result.value['path_with_namespace'], 'team/old');
      expect(result.lineage, CacheLineage.network);
      expect(adapter.requests.map((request) => request.uri), [
        api.instance.api(['projects', '8'], {'license': 'true'}),
        api.instance.api(['projects', '8'], {'license': 'true'}),
        api.instance.api(['projects', 'team/old'], {'license': 'true'}),
      ]);
    },
  );

  test(
    'P3 project rejects a renamed known alias after held hydration',
    () async {
      var now = DateTime.utc(2026, 10, 23);
      final disk = Completer<CacheDiskEntry?>();
      final started = Completer<void>();
      var renamed = false;
      late final GitLabApi api;
      Future<CachedRead<Json>>? observed;
      final adapter = FakeAdapter((request) {
        final requested = request.uri.pathSegments.last;
        if (requested == 'team/old') {
          // Join project()'s network request to observe its lineage.
          observed = api.cachedRecord([
            'projects',
            'team/old',
          ], allowDisk: false);
        }
        return jsonResponse({
          ...projectJson(requested == 'team/old' && renamed ? 9 : 8),
          'path_with_namespace': requested == '8' && renamed
              ? 'team/new'
              : 'team/old',
        });
      });
      api = _api(
        adapter,
        clock: () => now,
        source: (uri, _) {
          expect(uri, _projectUri('team/old'));
          if (!started.isCompleted) started.complete();
          return disk.future;
        },
      );
      addTearDown(api.close);
      await api.project('8', allowDisk: false);
      now = now.add(const Duration(minutes: 6));
      final pending = api.project('team/old');
      await started.future.timeout(_deadline);
      renamed = true;
      expect((await api.project('8', refresh: true)).path, 'team/new');
      disk.complete(null);

      final project = await pending.timeout(_deadline);
      expect(project.id, 9);
      expect(project.path, 'team/old');
      expect(observed, isNotNull);
      final read = await observed!.timeout(_deadline);
      expect(read.value['id'], 9);
      expect(read.value['path_with_namespace'], 'team/old');
      expect(read.lineage, CacheLineage.network);
      expect(adapter.requests.map((request) => request.uri), [
        _projectUri('8'),
        _projectUri('8'),
        _projectUri('team/old'),
      ]);
    },
  );

  test('P4 evicted known alias rejects a renamed hydration winner', () async {
    final now = DateTime.utc(2026, 10, 23);
    final disk = Completer<CacheDiskEntry?>();
    final started = Completer<void>();
    var renamed = false;
    final adapter = FakeAdapter((request) {
      final requested = request.uri.pathSegments.last;
      if (requested == 'team/old') {
        return jsonResponse({
          ...projectJson(9),
          'path_with_namespace': 'team/old',
        });
      }
      final id = int.parse(requested);
      return jsonResponse({
        ...projectJson(id),
        if (id == 8) 'path_with_namespace': renamed ? 'team/new' : 'team/old',
      });
    });
    final api = _api(
      adapter,
      clock: () => now,
      source: (uri, _) {
        expect(uri, _projectUri('team/old'));
        started.complete();
        return disk.future;
      },
    );
    addTearDown(api.close);
    await api.cachedRecord(['projects', '8'], fresh: true);
    for (var id = 100; id < 360; id++) {
      await api.cachedRecord(['projects', '$id'], fresh: true);
    }
    final pending = api.cachedRecord(['projects', 'team/old']);
    await started.future.timeout(_deadline);
    renamed = true;
    await api.cachedRecord(['projects', '8'], fresh: true);
    disk.complete(null);

    final read = await pending.timeout(_deadline);
    expect(read.value['id'], 9);
    expect(read.value['path_with_namespace'], 'team/old');
    expect(read.lineage, CacheLineage.network);
    expect(adapter.requests, hasLength(263));
    expect(adapter.requests.skip(261).map((request) => request.uri), [
      _projectUri('8'),
      _projectUri('team/old'),
    ]);
  });

  test(
    'P5 numeric project never joins a held path-form network read',
    () async {
      var now = DateTime.utc(2026, 10, 23);
      final held = Completer<ResponseBody>();
      final started = Completer<void>();
      var renamed = false;
      final adapter = FakeAdapter((request) {
        if (request.uri.pathSegments.last == 'team/old') {
          started.complete();
          return held.future;
        }
        return jsonResponse({
          ...projectJson(8),
          'path_with_namespace': renamed ? 'team/new' : 'team/old',
        });
      });
      final api = _api(adapter, clock: () => now);
      addTearDown(api.close);
      await api.project('8');
      now = now.add(const Duration(minutes: 6));
      renamed = true;
      final byPath = api.project('team/old');
      await started.future.timeout(_deadline);
      final byId = api.project('8');
      try {
        // It must finish on its own URI while the path response is still held.
        final numeric = await byId.timeout(_deadline);
        expect(numeric.id, 8);
        expect(numeric.path, 'team/new');
      } finally {
        held.complete(
          jsonResponse({...projectJson(9), 'path_with_namespace': 'team/old'}),
        );
        await byPath.timeout(_deadline);
        await byId.timeout(_deadline);
      }
      final project = await byPath;
      expect(project.id, 9);
      expect(project.path, 'team/old');
      expect(adapter.requests.map((request) => request.uri), [
        _projectUri('8'),
        _projectUri('team/old'),
        _projectUri('8'),
      ]);
    },
  );

  for (final requested in ['8', 'team/old']) {
    test(
      'project identity rejects mismatched disk detail for $requested',
      () async {
        final now = DateTime.utc(2026, 10, 23);
        final adapter = FakeAdapter(
          (_) => jsonResponse({
            ...projectJson(8),
            'path_with_namespace': 'team/old',
          }),
        );
        final api = _api(
          adapter,
          clock: () => now,
          source: (_, _) async => CacheDiskEntry(
            value: {
              ...projectJson(requested == '8' ? 9 : 8),
              'path_with_namespace': 'team/new',
            },
            fetchedAt: now,
            responseBytes: 128,
          ),
        );
        addTearDown(api.close);

        final read = await api.cachedRecord(['projects', requested]);
        expect(read.value['id'], 8);
        expect(read.value['path_with_namespace'], 'team/old');
        expect(read.lineage, CacheLineage.network);
        expect(adapter.requests.map((request) => request.uri), [
          _projectUri(requested),
        ]);
      },
    );
  }

  for (final afterHydration in [false, true]) {
    test(
      'project identity checks pending result afterHydration=$afterHydration',
      () async {
        final disk = Completer<CacheDiskEntry?>();
        final diskStarted = Completer<void>();
        final held = Completer<ResponseBody>();
        final networkStarted = Completer<void>();
        var calls = 0;
        final adapter = FakeAdapter((_) {
          if (++calls == 1) {
            networkStarted.complete();
            return held.future;
          }
          return jsonResponse(projectJson(8));
        });
        final api = _api(
          adapter,
          source: (_, _) {
            diskStarted.complete();
            return disk.future;
          },
        );
        addTearDown(api.close);
        Future<CachedRead<Json>>? joining;
        if (afterHydration) {
          joining = api.cachedRecord(['projects', '8']);
          await diskStarted.future.timeout(_deadline);
        }
        final owner = api.cachedRecord(['projects', '8'], allowDisk: false);
        await networkStarted.future.timeout(_deadline);
        if (afterHydration) {
          disk.complete(null);
          // Let the disk miss reach the second pending lookup before the reply.
          await Future<void>.delayed(Duration.zero);
        } else {
          joining = api.cachedRecord(['projects', '8'], allowDisk: false);
        }
        held.complete(jsonResponse(projectJson(9)));

        expect((await owner.timeout(_deadline)).value['id'], 9);
        final read = await joining!.timeout(_deadline);
        expect(read.value['id'], 8);
        expect(read.lineage, CacheLineage.network);
        expect(adapter.requests.map((request) => request.uri), [
          _projectUri('8'),
          _projectUri('8'),
        ]);
      },
    );
  }

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
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              scenario == 'disk error'
                  ? FailureKind.invalidResponse
                  : FailureKind.server,
            ),
          ),
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
    test('GraphQL $status advances epoch and preserves pinned memory; '
        'disk control; REST $status revokes', () async {
      final now = DateTime.utc(2026, 10, 23);
      final labels = WorkItemLabelsFixture(initialLabelCount: 0);
      addTearDown(labels.api.close);
      var denyGraph = false;
      var denyRest = false;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/api/graphql')) {
          return denyGraph
              ? jsonResponse({}, status: status)
              : labels.adapter.respond(request);
        }
        if (denyRest) {
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
      final detail = await api.projectWorkItem(labels.project, 100);
      Future<int> readEpoch() async => (await api.workItemLabels(
        detail,
        expectedUserId: 7,
        generation: 1,
      )).snapshot.readEpoch;
      final beforeEpoch = await readEpoch();
      await api.record(['projects', '8', 'repository', 'branches', 'main']);
      await api.cachedRecords(
        _treePath,
        query: {'ref': _sha, 'path': 'memory'},
        allowDisk: false,
      );
      final beforeMetadata = api.readCacheMetadataCounts;
      denyGraph = true;
      await expectLater(
        api.pipelineGraphPage(Project.fromJson(projectJson(8)), 1),
        throwsA(isA<ApiFailure>()),
      );
      denyGraph = false;
      final afterEpoch = await readEpoch();
      // Memory preservation catches the GraphQL revocation regression.
      expect(
        (await api.cachedRecords(
          _treePath,
          query: {'ref': _sha, 'path': 'memory'},
        )).lineage,
        CacheLineage.memory,
      );
      expect(afterEpoch, beforeEpoch + 1);
      expect(api.readCacheMetadataCounts, beforeMetadata);
      // Disk hydration is a control: it also passed before the scope fix.
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
    });
  }
}

Json _issue(bool confidential) => {
  'id': 101,
  'project_id': 8,
  'iid': 1,
  'confidential': confidential,
};

Uri _projectUri(String project) => GitLabInstance.parse(
  'https://example.com/gitlab',
).api(['projects', project], {'license': 'true'});

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
