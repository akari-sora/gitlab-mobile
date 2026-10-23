import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _alias = 'team/app';

void main() {
  for (final numericFirst in [true, false]) {
    test(
      '${numericFirst ? 'P1' : 'P2'} sub-resource pages keep literal cache keys',
      () async {
        final adapter = FakeAdapter((request) {
          if (request.uri.pathSegments.length == 5) {
            return jsonResponse(_project);
          }
          return _page(request);
        });
        final api = _api(adapter);
        addTearDown(api.close);
        await api.project(_alias);
        final forms = numericFirst ? ['8', _alias] : [_alias, '8'];
        for (final project in forms) {
          final page = await api.cachedRecords(['projects', project, 'issues']);
          expect(page.lineage, CacheLineage.network);
          expect(page.value.next!.pathSegments[4], project);
        }
        expect(adapter.requests, hasLength(3));
        for (final project in forms) {
          final page = await api.cachedRecords(['projects', project, 'issues']);
          expect(page.lineage, CacheLineage.memory);
          expect(page.value.next!.pathSegments[4], project);
        }
        expect(adapter.requests, hasLength(3));
      },
      timeout: const Timeout(_deadline),
    );
  }

  test(
    'P3 path reads do not join numeric pending pages and can continue',
    () async {
      final held = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = FakeAdapter((request) {
        if (request.uri.pathSegments.length == 5) {
          return jsonResponse(_project);
        }
        if (request.uri.pathSegments[4] == '8') {
          started.complete();
          return held.future;
        }
        return _page(request);
      });
      final api = _api(adapter);
      addTearDown(api.close);
      await api.project(_alias);
      final numeric = api.cachedRecords(['projects', '8', 'issues']);
      await started.future.timeout(_deadline);
      final numericRequest = adapter.requests.last;
      final path = api.cachedRecords(['projects', _alias, 'issues']);
      held.complete(_page(numericRequest));
      final page = await path.timeout(_deadline);
      await numeric.timeout(_deadline);
      final next = await api.cachedRecords([
        'projects',
        _alias,
        'issues',
      ], next: page.value.next);
      expect(page.value.next!.pathSegments[4], _alias);
      expect(next.lineage, CacheLineage.network);
      expect(next.value.items.single['title'], '$_alias page 2');
      expect(adapter.requests, hasLength(4));
    },
    timeout: const Timeout(_deadline),
  );

  test(
    'P4 retargeted path cannot publish into a numeric sub-resource key',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.pathSegments.length == 5) {
          return jsonResponse(_project);
        }
        final project = request.uri.pathSegments[4] == _alias ? 9 : 8;
        return jsonResponse(_issue(project));
      });
      final api = _api(adapter);
      addTearDown(api.close);
      await api.project(_alias);
      final path = await api.cachedRecord([
        'projects',
        _alias,
        'issues',
        '1',
      ], fresh: true);
      expect(path.value['project_id'], 9);
      final numeric = await api.cachedRecord(['projects', '8', 'issues', '1']);
      expect(numeric.lineage, CacheLineage.network);
      expect(numeric.value['project_id'], 8);
      for (final project in [_alias, '8']) {
        final cached = await api.cachedRecord([
          'projects',
          project,
          'issues',
          '1',
        ]);
        expect(cached.lineage, CacheLineage.memory);
        expect(cached.value['project_id'], project == _alias ? 9 : 8);
      }
      expect(adapter.requests, hasLength(3));
    },
    timeout: const Timeout(_deadline),
  );

  for (final disk in [false, true]) {
    test(
      'P4 stale alias cannot hide response project revocation from ${disk ? 'disk' : 'network'}',
      () async {
        final network = Completer<ResponseBody>();
        final hydration = Completer<CacheDiskEntry?>();
        final started = Completer<void>();
        final adapter = FakeAdapter((request) {
          if (request.uri.pathSegments.length == 5) {
            return jsonResponse(_project);
          }
          if (request.uri.pathSegments[4] == _alias) {
            started.complete();
            return network.future;
          }
          return jsonResponse({}, status: 403);
        });
        final api = _api(
          adapter,
          source: disk
              ? (uri, _) async {
                  if (uri.pathSegments.length == 5) return null;
                  started.complete();
                  return hydration.future;
                }
              : null,
        );
        addTearDown(api.close);
        await api.project(_alias);
        final reading = api.cachedRecord(['projects', _alias, 'issues', '1']);
        final rejected = expectLater(
          reading.timeout(_deadline),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        await started.future.timeout(_deadline);
        await expectLater(
          api.record(['projects', '9', 'issues', '1']),
          throwsA(isA<ApiFailure>()),
        );
        if (disk) {
          hydration.complete(
            CacheDiskEntry(
              value: _issue(9),
              fetchedAt: DateTime.utc(2026),
              responseBytes: 128,
            ),
          );
        } else {
          network.complete(jsonResponse(_issue(9)));
        }
        await rejected;
      },
      timeout: const Timeout(_deadline),
    );
  }
}

final _project = {...projectJson(8), 'path_with_namespace': _alias};

Map<String, Object> _issue(int project) => {
  'id': project * 10,
  'iid': 1,
  'project_id': project,
  'title': 'issue of project $project',
};

ResponseBody _page(RequestOptions request) {
  final project = request.uri.pathSegments[4];
  final second = request.uri.queryParameters['page'] == '2';
  return jsonResponse(
    [
      {'title': '$project page ${second ? 2 : 1}'},
    ],
    headers: second
        ? {}
        : {
            'x-next-page': ['2'],
          },
  );
}

GitLabApi _api(FakeAdapter adapter, {ReadCacheSource? source}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheSource: source,
    readCacheClock: () => DateTime.utc(2026),
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}
