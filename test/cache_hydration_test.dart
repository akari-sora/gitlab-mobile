import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

void main() {
  group('cache hydration ordering', () {
    test(
      'delayed disk cannot overwrite a completed fresh network read',
      () async {
        final disk = Completer<CacheDiskEntry?>();
        final sourceStarted = Completer<void>();
        var networkCalls = 0;
        final adapter = FakeAdapter((_) {
          networkCalls++;
          return jsonResponse({'id': 2, 'title': 'network'});
        });
        final api = _boundApi(
          adapter,
          source: (_, _) {
            if (!sourceStarted.isCompleted) sourceStarted.complete();
            return disk.future;
          },
        );
        addTearDown(api.close);

        final hydrating = api.cachedRecord(['projects', '8', 'issues', '1']);
        await sourceStarted.future.timeout(const Duration(seconds: 20));
        final fresh = await api.cachedRecord([
          'projects',
          '8',
          'issues',
          '1',
        ], fresh: true);
        expect(fresh.value['title'], 'network');

        disk.complete(
          CacheDiskEntry(
            value: {'id': 1, 'title': 'disk'},
            fetchedAt: DateTime.now().subtract(const Duration(minutes: 1)),
            responseBytes: 32,
          ),
        );
        final hydrated = await hydrating.timeout(const Duration(seconds: 20));
        final later = await api.cachedRecord(['projects', '8', 'issues', '1']);

        expect(hydrated.value['title'], 'network');
        expect(later.value['title'], 'network');
        expect(networkCalls, 1);
      },
    );

    for (final scenario in <String, ({Duration? maxAge, bool allowDisk})>{
      'maxAge rejection': (maxAge: const Duration(seconds: 5), allowDisk: true),
      'allowDisk false rejection': (maxAge: null, allowDisk: false),
    }.entries) {
      test(
        '${scenario.key} preserves disk-backed memory for a later UI caller',
        () async {
          final now = DateTime.utc(2026);
          var sourceCalls = 0;
          var networkCalls = 0;
          final adapter = FakeAdapter((_) {
            networkCalls++;
            return jsonResponse({}, status: 503);
          });
          final api = _boundApi(
            adapter,
            clock: () => now,
            source: (_, _) async {
              sourceCalls++;
              if (sourceCalls > 1) return null;
              return CacheDiskEntry(
                value: {'id': 1, 'title': 'disk'},
                fetchedAt: scenario.value.maxAge == null
                    ? now
                    : now.subtract(const Duration(seconds: 10)),
                responseBytes: 32,
              );
            },
          );
          addTearDown(api.close);

          final disk = await api.cachedRecord(['projects', '8', 'issues', '1']);
          expect(disk.lineage, CacheLineage.disk);
          expect(disk.stale, isTrue);
          final originalFetchedAt = disk.fetchedAt;
          await expectLater(
            api.cachedRecord(
              ['projects', '8', 'issues', '1'],
              maxAge: scenario.value.maxAge,
              allowDisk: scenario.value.allowDisk,
            ),
            throwsA(isA<ApiFailure>()),
          );

          final later = await api.cachedRecord([
            'projects',
            '8',
            'issues',
            '1',
          ]);
          expect(later.value['title'], 'disk');
          expect(later.lineage, CacheLineage.disk);
          expect(later.stale, isTrue);
          expect(later.fetchedAt, originalFetchedAt);
          expect(networkCalls, 1);
        },
      );
    }

    test(
      'hydrated full-path project detail learns its numeric alias',
      () async {
        var sourceCalls = 0;
        var networkCalls = 0;
        final adapter = FakeAdapter((_) {
          networkCalls++;
          return jsonResponse({}, status: 503);
        });
        final api = _boundApi(
          adapter,
          source: (_, _) async {
            sourceCalls++;
            return CacheDiskEntry(
              value: {
                ...projectJson(8),
                'path_with_namespace': 'team/example-8',
                'license': null,
              },
              fetchedAt: DateTime.now(),
              responseBytes: 128,
            );
          },
        );
        addTearDown(api.close);

        final byPath = await api.cachedRecord(['projects', 'team/example-8']);
        final byId = await api.cachedRecord(['projects', '8']);

        expect(byPath.value['id'], 8);
        expect(byId.value['id'], 8);
        expect(byId.lineage, CacheLineage.disk);
        expect(sourceCalls, 1);
        expect(networkCalls, 0);
      },
    );

    test(
      'disk arriving after a related write cannot return stale data',
      () async {
        final disk = Completer<CacheDiskEntry?>();
        final sourceStarted = Completer<void>();
        var networkReads = 0;
        final adapter = FakeAdapter((request) {
          if (request.method != 'GET') return jsonResponse({'id': 1});
          networkReads++;
          return jsonResponse({'id': 1, 'title': 'after write'});
        });
        final api = _boundApi(
          adapter,
          source: (_, _) {
            if (!sourceStarted.isCompleted) sourceStarted.complete();
            return disk.future;
          },
        );
        addTearDown(api.close);

        final pending = api.cachedRecord(['projects', '8', 'issues', '1']);
        await sourceStarted.future.timeout(const Duration(seconds: 20));
        await api.updateIssue(8, 1, {'title': 'after write'});
        disk.complete(
          CacheDiskEntry(
            value: {'id': 1, 'title': 'before write'},
            fetchedAt: DateTime.now().subtract(const Duration(minutes: 1)),
            responseBytes: 32,
          ),
        );

        final result = await pending.timeout(const Duration(seconds: 20));
        expect(result.value['title'], 'after write');
        expect(result.lineage, CacheLineage.network);
        expect(networkReads, 1);
      },
    );

    test('project 403 blocks future hydration of old disk values', () async {
      final originalFetchedAt = DateTime.now().subtract(
        const Duration(minutes: 1),
      );
      var sourceCalls = 0;
      var networkCalls = 0;
      final adapter = FakeAdapter((_) {
        networkCalls++;
        return networkCalls == 1
            ? jsonResponse({}, status: 403)
            : jsonResponse({...projectJson(8), 'license': null});
      });
      final api = _boundApi(
        adapter,
        source: (_, _) async {
          sourceCalls++;
          return CacheDiskEntry(
            value: {...projectJson(8), 'name': 'old disk', 'license': null},
            fetchedAt: originalFetchedAt,
            responseBytes: 128,
          );
        },
      );
      addTearDown(api.close);

      expect(
        (await api.cachedRecord(['projects', '8'])).value['name'],
        'old disk',
      );
      await expectLater(
        api.cachedRecord(['projects', '8'], fresh: true),
        throwsA(isA<ApiFailure>()),
      );
      final recovered = await api.cachedRecord(['projects', '8']);

      expect(recovered.value['name'], isNot('old disk'));
      expect(recovered.lineage, CacheLineage.network);
      expect(sourceCalls, 2);
      expect(networkCalls, 2);
    });
  });

  test(
    'reads waiting on a project write do not occupy foreground admission slots',
    () async {
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      final unrelatedReachedNetwork = Completer<void>();
      final adapter = FakeAdapter((request) async {
        final path = request.uri.path;
        if (request.method != 'GET') {
          if (!writeStarted.isCompleted) writeStarted.complete();
          await releaseWrite.future;
          return jsonResponse({'id': 1});
        }
        if (path.endsWith('/projects/9/issues/1')) {
          if (!unrelatedReachedNetwork.isCompleted) {
            unrelatedReachedNetwork.complete();
          }
          return jsonResponse({'id': 1});
        }
        return jsonResponse({'id': int.parse(request.uri.pathSegments.last)});
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      final write = api.updateIssue(8, 1, {'title': 'held'});
      await writeStarted.future.timeout(const Duration(seconds: 20));
      final related = [
        for (var iid = 1; iid <= 16; iid++)
          api.cachedRecord(['projects', '8', 'issues', '$iid']),
      ];
      final unrelated = api.cachedRecord(['projects', '9', 'issues', '1']);

      var reachedBeforeRelease = true;
      try {
        await unrelatedReachedNetwork.future.timeout(
          const Duration(seconds: 2),
        );
      } on TimeoutException {
        reachedBeforeRelease = false;
      } finally {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      }
      await write.timeout(const Duration(seconds: 20));
      await Future.wait(related).timeout(const Duration(seconds: 20));
      expect((await unrelated).value['id'], 1);
      expect(
        reachedBeforeRelease,
        isTrue,
        reason: 'project-8 write waiters must not consume all 16 admissions',
      );
    },
  );
}

GitLabApi _boundApi(
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
