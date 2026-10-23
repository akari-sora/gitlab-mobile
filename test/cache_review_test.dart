import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _issue = ['projects', '8', 'issues', '1'];

void main() {
  for (final revokedPath in ['8', 'team/example-8']) {
    test(
      'unresolved disk alias checks permission fences for $revokedPath',
      () async {
        var now = DateTime.utc(2026);
        final held = Completer<CacheDiskEntry?>();
        final started = Completer<void>();
        final api = _api(
          FakeAdapter((_) => jsonResponse({}, status: 403)),
          clock: () => now,
          source: (_, _) {
            started.complete();
            return held.future;
          },
        );
        addTearDown(api.close);
        final reading = api.cachedRecord(['projects', 'team/example-8']);
        final rejected = expectLater(
          reading.timeout(_deadline),
          throwsA(
            isA<ApiFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        await started.future.timeout(_deadline);
        await expectLater(
          api.record(['projects', revokedPath]),
          throwsA(isA<ApiFailure>()),
        );
        now = now.add(const Duration(seconds: 1));
        held.complete(
          CacheDiskEntry(
            value: projectJson(8),
            fetchedAt: now,
            responseBytes: 128,
          ),
        );
        await rejected;
      },
    );

    test(
      'unresolved alias response checks permission fences for $revokedPath',
      () async {
        final held = Completer<ResponseBody>();
        final started = Completer<void>();
        final adapter = FakeAdapter((request) {
          if (request.uri.pathSegments.last == 'team/example-8' &&
              !started.isCompleted) {
            started.complete();
            return held.future;
          }
          return jsonResponse({}, status: 403);
        });
        final api = _api(adapter);
        addTearDown(api.close);
        final reading = api.cachedRecord(['projects', 'team/example-8']);
        final rejected = expectLater(
          reading.timeout(_deadline),
          throwsA(
            isA<ApiFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        await started.future.timeout(_deadline);
        await expectLater(
          api.record(['projects', revokedPath]),
          throwsA(isA<ApiFailure>()),
        );
        held.complete(jsonResponse(projectJson(8)));
        await rejected;
      },
    );
  }

  test(
    'unresolved alias cannot publish over a newer numeric refresh',
    () async {
      final old = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = FakeAdapter((request) {
        if (request.uri.pathSegments.last == 'team/example-8') {
          started.complete();
          return old.future;
        }
        return jsonResponse({...projectJson(8), 'name': 'new'});
      });
      final api = _api(adapter);
      addTearDown(api.close);
      final reading = api.cachedRecord(['projects', 'team/example-8']);
      await started.future.timeout(_deadline);
      await api.cachedRecord(['projects', '8'], fresh: true);
      old.complete(jsonResponse({...projectJson(8), 'name': 'old'}));
      final result = await reading.timeout(_deadline);
      expect(result.superseded, isFalse);
      expect(result.stale, isFalse);
      expect((await api.cachedRecord(['projects', '8'])).value['name'], 'new');
      expect(
        (await api.cachedRecord(['projects', 'team/example-8'])).value['name'],
        'new',
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'no-store fresh success removes the old canonical cache entry',
    () async {
      var calls = 0;
      final adapter = FakeAdapter(
        (_) => jsonResponse(
          {'title': '${++calls}'},
          headers: calls == 2
              ? {
                  'cache-control': ['no-store'],
                }
              : {},
        ),
      );
      final api = _api(adapter);
      addTearDown(api.close);
      await api.cachedRecord(_issue);
      expect((await api.cachedRecord(_issue, fresh: true)).value['title'], '2');
      expect((await api.cachedRecord(_issue)).value['title'], '3');
      expect(calls, 3);
    },
  );

  test(
    'disk miss joiner preserves network ownership and typed success',
    () async {
      final held = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = FakeAdapter((_) {
        started.complete();
        return held.future;
      });
      final api = _api(adapter, source: (_, _) async => null);
      addTearDown(api.close);
      final first = api.project('8');
      await started.future.timeout(_deadline);
      final second = api.project('8');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      held.complete(jsonResponse(projectJson(8)));
      expect((await first.timeout(_deadline)).id, 8);
      expect((await second.timeout(_deadline)).id, 8);
      expect(
        (await api.cachedRecord(['projects', '8'])).lineage,
        CacheLineage.memory,
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test('losing a fresh publication race returns valid network flags', () async {
    final held = Completer<ResponseBody>();
    final started = Completer<void>();
    var calls = 0;
    final adapter = FakeAdapter((_) {
      if (++calls == 1) {
        started.complete();
        return held.future;
      }
      return jsonResponse({'title': 'new'});
    });
    final api = _api(adapter);
    addTearDown(api.close);
    final first = api.cachedRecord(_issue);
    await started.future.timeout(_deadline);
    await api.cachedRecord(_issue, fresh: true);
    held.complete(jsonResponse({'title': 'old'}));
    final result = await first.timeout(_deadline);
    expect(result.value['title'], 'old');
    expect(result.superseded, isFalse);
    expect(result.stale, isFalse);
    expect((await api.cachedRecord(_issue)).value['title'], 'new');
  });

  for (final lateError in [false, true]) {
    test(
      'close cancels a held hydration and consumes late error=$lateError',
      () async {
        final held = Completer<CacheDiskEntry?>();
        final started = Completer<void>();
        final adapter = FakeAdapter((_) => jsonResponse({'title': 'network'}));
        final api = _api(
          adapter,
          source: (_, _) {
            started.complete();
            return held.future;
          },
        );
        final reading = api.cachedRecord(_issue);
        await started.future.timeout(_deadline);
        final rejected = expectLater(
          reading.timeout(const Duration(seconds: 1)),
          throwsA(
            isA<ApiFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        api.close();
        try {
          await rejected;
        } finally {
          if (lateError) {
            held.completeError(StateError('late source failure'));
          } else {
            held.complete(
              CacheDiskEntry(
                value: {'title': 'disk'},
                fetchedAt: DateTime.now(),
                responseBytes: 20,
              ),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(adapter.requests, isEmpty);
      },
    );
  }

  test(
    'fresh and cache misses resolve the caller path after retargeting',
    () async {
      var id = 8;
      final adapter = FakeAdapter((request) {
        final requested = request.uri.pathSegments.last;
        final actual = int.tryParse(requested) ?? id;
        return jsonResponse({
          ...projectJson(actual),
          'path_with_namespace': 'team/app',
        });
      });
      final api = _api(adapter);
      addTearDown(api.close);
      expect((await api.project('team/app')).id, 8);
      id = 9;
      expect((await api.project('team/app', refresh: true)).id, 9);
      expect(adapter.requests.last.uri.pathSegments.last, 'team/app');
    },
  );

  test(
    'alias hit with a renamed project drops the alias and refetches',
    () async {
      var renamed = false;
      final adapter = FakeAdapter((request) {
        final requested = request.uri.pathSegments.last;
        final id = requested.toLowerCase() == 'team/app' && renamed ? 9 : 8;
        return jsonResponse({
          ...projectJson(id),
          'path_with_namespace': id == 8 && renamed ? 'team/old' : 'team/app',
        });
      });
      final api = _api(adapter);
      addTearDown(api.close);
      await api.project('team/app');
      renamed = true;
      await api.project('8', refresh: true);
      expect((await api.project('TEAM/APP')).id, 9);
      expect(
        adapter.requests.last.uri.pathSegments.last.toLowerCase(),
        'team/app',
      );
    },
  );

  test('older numeric response cannot retarget a newer caller alias', () async {
    var now = DateTime.utc(2026);
    final held = Completer<ResponseBody>();
    final started = Completer<void>();
    var pathCalls = 0;
    final api = _api(
      FakeAdapter((request) {
        if (request.uri.pathSegments.last == '8') {
          started.complete();
          return held.future;
        }
        return jsonResponse({
          ...projectJson(++pathCalls == 1 ? 8 : 9),
          'path_with_namespace': 'team/app',
        });
      }),
      clock: () => now,
    );
    addTearDown(api.close);
    await api.project('team/app');
    now = now.add(const Duration(minutes: 29));
    final reading = api.project('8', refresh: true);
    await started.future.timeout(_deadline);
    now = now.add(const Duration(minutes: 2));
    expect((await api.project('team/app', refresh: true)).id, 9);
    held.complete(
      jsonResponse({...projectJson(8), 'path_with_namespace': 'team/app'}),
    );
    expect((await reading.timeout(_deadline)).id, 8);
    expect((await api.cachedRecord(['projects', 'team/app'])).value['id'], 9);
  });

  for (final crossesExpiry in [false, true]) {
    test(
      'losing path response cannot restore an obsolete alias across expiry=$crossesExpiry',
      () async {
        var now = DateTime.utc(2026);
        final old = Completer<ResponseBody>();
        final started = Completer<void>();
        var pathCalls = 0;
        final adapter = FakeAdapter((request) {
          if (request.uri.pathSegments.last == '8') {
            return jsonResponse({
              ...projectJson(8),
              'path_with_namespace': null,
            });
          }
          if (++pathCalls == 1) {
            return jsonResponse({
              ...projectJson(8),
              'path_with_namespace': 'team/app',
            });
          }
          if (pathCalls == 2) {
            started.complete();
            return old.future;
          }
          return jsonResponse({
            ...projectJson(9),
            'path_with_namespace': 'team/app',
          });
        });
        final api = _api(adapter, clock: () => now);
        addTearDown(api.close);
        await api.project('team/app');
        now = now.add(const Duration(minutes: 29));
        await api.cachedRecord(['projects', '8'], fresh: true);
        if (!crossesExpiry) now = now.add(const Duration(minutes: 2));
        final reading = api.project('team/app', refresh: true);
        await started.future.timeout(_deadline);
        if (crossesExpiry) now = now.add(const Duration(minutes: 2));
        expect((await api.project('team/app', refresh: true)).id, 9);
        old.complete(
          jsonResponse({...projectJson(8), 'path_with_namespace': 'team/app'}),
        );
        expect((await reading.timeout(_deadline)).id, 8);
        expect(
          (await api.cachedRecord(['projects', 'team/app'])).value['id'],
          9,
        );
        expect(pathCalls, 3);
      },
    );
  }

  test(
    'alias expires after thirty minutes even when numeric entry is newer',
    () async {
      var now = DateTime.utc(2026);
      final adapter = FakeAdapter(
        (request) => jsonResponse({
          ...projectJson(8),
          if (request.uri.pathSegments.last == '8')
            'path_with_namespace': null
          else
            'path_with_namespace': 'team/app',
        }),
      );
      final api = _api(adapter, clock: () => now);
      addTearDown(api.close);
      await api.project('team/app');
      now = now.add(const Duration(minutes: 29));
      await api.cachedRecord(['projects', '8'], fresh: true);
      // A numeric project read without a path field refreshes the entry only.
      adapter.requests.clear();
      now = now.add(const Duration(minutes: 2));
      await api.project('team/app');
      expect(adapter.requests.last.uri.pathSegments.last, 'team/app');
    },
  );
}

GitLabApi _api(
  FakeAdapter adapter, {
  ReadCacheSource? source,
  DateTime Function()? clock,
}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheSource: source,
    readCacheClock: clock,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}
