import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

const _limit = 4096;
const _count = _limit + 32;
const _deadline = Duration(seconds: 20);
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  test(
    'metadata maps stay bounded after alias scope and revocation churn',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.method != 'GET') return jsonResponse({'id': 1});
        if (['missing', 'issues'].contains(request.uri.pathSegments.last)) {
          return jsonResponse({}, status: 404);
        }
        final name = request.uri.pathSegments.last;
        final id = int.parse(name.split('/').last);
        return jsonResponse({
          ...projectJson(id),
          'path_with_namespace': 'team/$id',
        });
      });
      final api = _api(adapter);
      addTearDown(api.close);
      for (var id = 1; id <= _count; id++) {
        await api.cachedRecord(['projects', 'team/$id']).timeout(_deadline);
      }
      expect(api.readCacheMetadataCounts['aliases'], _limit);
      for (var id = 1; id <= _count; id++) {
        await api
            .writeRecord('PUT', ['projects', '$id'], {'name': 'synthetic'})
            .timeout(_deadline);
        await expectLater(
          api.record(['projects', '$id', 'missing']).timeout(_deadline),
          throwsA(isA<ApiFailure>()),
        );
        await expectLater(
          api
              .records(['issues'], query: {'scope': 'synthetic-$id'})
              .timeout(_deadline),
          throwsA(isA<ApiFailure>()),
        );
      }
      _expectBounds(api);
      expect(api.readCacheMetadataCounts['writes'], 0);
      api.clearReadCache();
      _expectBounds(api);
      expect(api.readCacheMetadataCounts['aliases'], 0);
      expect(api.readCacheMetadataCounts['revocations'], 0);
      expect(api.readCacheMetadataCounts['sourceRevocations'], 0);
      expect(api.readCacheMetadataCounts['sourceWrites'], 0);
    },
  );

  test(
    'write compaction fences held mutable reads and preserves held pinned reads',
    () async {
      final old = Completer<ResponseBody>();
      final pinned = Completer<ResponseBody>();
      final started = Completer<void>();
      final pinnedStarted = Completer<void>();
      var issueReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.method != 'GET') return jsonResponse({'id': 1});
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': _sha},
          });
        }
        if (request.uri.path.endsWith('/tree')) {
          pinnedStarted.complete();
          return pinned.future;
        }
        if (++issueReads == 1) {
          started.complete();
          return old.future;
        }
        return jsonResponse({'title': 'new'});
      });
      final api = _api(adapter);
      addTearDown(api.close);
      await api.record(['projects', '8', 'repository', 'branches', 'main']);
      final reading = api.cachedRecord(['projects', '8', 'issues', '1']);
      final tree = api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': _sha},
      );
      await Future.wait([
        started.future,
        pinnedStarted.future,
      ]).timeout(_deadline);
      for (var id = 1; id <= _count; id++) {
        await api
            .writeRecord('PUT', ['projects', '$id'], {'name': 'synthetic'})
            .timeout(_deadline);
      }
      old.complete(jsonResponse({'title': 'old'}));
      pinned.complete(jsonResponse(<Object>[]));
      expect((await reading.timeout(_deadline)).value['title'], 'new');
      final immutable = await tree.timeout(_deadline);
      expect(immutable.superseded, isFalse);
      expect(immutable.stale, isFalse);
      expect(issueReads, 2);
      expect(
        (await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': _sha},
        )).lineage,
        CacheLineage.memory,
      );
      _expectBounds(api);
    },
  );

  test(
    'compacted revocations reject old source values and held publications',
    () async {
      final now = DateTime.utc(2026, 10, 23);
      final old = Completer<ResponseBody>();
      final started = Completer<void>();
      var hold = true;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects/8/issues/1')) {
          if (hold) {
            hold = false;
            started.complete();
            return old.future;
          }
          return jsonResponse({'title': 'network'});
        }
        return jsonResponse({}, status: 404);
      });
      final api = _api(
        adapter,
        clock: () => now,
        source: (_, _) async => CacheDiskEntry(
          value: {'title': 'revoked disk'},
          fetchedAt: now.subtract(const Duration(minutes: 1)),
          responseBytes: 32,
        ),
      );
      addTearDown(api.close);
      final reading = api.cachedRecord([
        'projects',
        '8',
        'issues',
        '1',
      ], fresh: true);
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
      for (var id = 1; id <= _count; id++) {
        await expectLater(
          api.record(['projects', '$id', 'missing']).timeout(_deadline),
          throwsA(isA<ApiFailure>()),
        );
      }
      old.complete(jsonResponse({'title': 'held old'}));
      await rejected;
      final recovered = await api
          .cachedRecord(['projects', '8', 'issues', '1'])
          .timeout(_deadline);
      expect(recovered.value['title'], 'network');
      expect(recovered.lineage, CacheLineage.network);
      _expectBounds(api);
    },
  );

  test('compacted source write fences exclude pinned disk values', () async {
    final now = DateTime.utc(2026, 10, 23);
    var diskCalls = 0;
    final adapter = FakeAdapter((request) {
      if (request.method != 'GET') return jsonResponse({'id': 1});
      if (request.uri.path.endsWith('/branches/main')) {
        return jsonResponse({
          'commit': {'id': _sha},
        });
      }
      return jsonResponse({'title': 'network'});
    });
    final api = _api(
      adapter,
      clock: () => now,
      source: (uri, _) async {
        diskCalls++;
        return CacheDiskEntry(
          value: uri.path.endsWith('/tree')
              ? ApiPage<Json>(const [])
              : <String, dynamic>{'title': 'old disk'},
          fetchedAt: now.subtract(const Duration(minutes: 1)),
          responseBytes: 32,
        );
      },
    );
    addTearDown(api.close);
    await api.record(['projects', '8', 'repository', 'branches', 'main']);
    for (var id = 1; id <= _count; id++) {
      await api
          .writeRecord('PUT', ['projects', '$id'], {'name': 'synthetic'})
          .timeout(_deadline);
    }
    expect(
      (await api.cachedRecord(['projects', '8', 'issues', '1'])).value['title'],
      'network',
    );
    expect(
      (await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': _sha},
      )).lineage,
      CacheLineage.disk,
    );
    expect(diskCalls, 2);
    _expectBounds(api);
  });

  test(
    'compacted permission source fences still reject pinned disk values',
    () async {
      final now = DateTime.utc(2026, 10, 23);
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': _sha},
          });
        }
        if (request.uri.path.endsWith('/tree')) return jsonResponse(<Object>[]);
        return jsonResponse({}, status: 403);
      });
      final api = _api(
        adapter,
        clock: () => now,
        source: (_, _) async => CacheDiskEntry(
          value: ApiPage<Json>(const []),
          fetchedAt: now.subtract(const Duration(minutes: 1)),
          responseBytes: 32,
        ),
      );
      addTearDown(api.close);
      await api.record(['projects', '8', 'repository', 'branches', 'main']);
      await expectLater(
        api.record(['projects', '8']),
        throwsA(isA<ApiFailure>()),
      );
      for (var id = 100; id < _count + 100; id++) {
        await expectLater(
          api.record(['projects', '$id', 'missing']).timeout(_deadline),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(
        (await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': _sha},
        )).lineage,
        CacheLineage.network,
      );
      _expectBounds(api);
    },
  );

  test(
    'active write overflow is paired and pinned keeps its exemption',
    () async {
      final gate = Completer<void>();
      final adapter = FakeAdapter((request) async {
        if (request.method != 'GET') {
          await gate.future;
          return jsonResponse({'id': 1});
        }
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': _sha},
          });
        }
        return jsonResponse(<Object>[]);
      });
      final api = _api(adapter);
      addTearDown(api.close);
      await api.record(['projects', '8', 'repository', 'branches', 'main']);
      final writes = [
        for (var id = 1; id <= _count; id++)
          api.writeRecord('PUT', ['projects', '$id'], {'name': 'synthetic'}),
      ];
      try {
        _expectBounds(api);
        expect(api.readCacheMetadataCounts['writes'], greaterThan(0));
        final pinned = await api
            .cachedRecords(
              ['projects', '8', 'repository', 'tree'],
              query: {'ref': _sha},
            )
            .timeout(_deadline);
        expect(pinned.stale, isFalse);
        expect(pinned.superseded, isFalse);
      } finally {
        gate.complete();
        await Future.wait(writes).timeout(_deadline);
      }
      expect(api.readCacheMetadataCounts['writes'], 0);
      _expectBounds(api);
      expect(
        (await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': _sha},
        )).lineage,
        CacheLineage.memory,
      );
    },
  );
}

void _expectBounds(GitLabApi api) {
  for (final entry in api.readCacheMetadataCounts.entries) {
    expect(entry.value, lessThanOrEqualTo(_limit), reason: entry.key);
  }
}

GitLabApi _api(
  FakeAdapter adapter, {
  DateTime Function()? clock,
  ReadCacheSource? source,
}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheClock: clock,
    readCacheSource: source,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}
