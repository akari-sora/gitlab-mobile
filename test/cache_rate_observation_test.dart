import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';

import 'support/fake_adapter.dart';

final _now = DateTime.utc(2026, 10, 23);
final _reset = _now.add(const Duration(minutes: 5));
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, List<String>> _rateHeaders(String name, {int remaining = 14}) => {
  'RateLimit-Name': [name],
  'RateLimit-Limit': ['100'],
  'RateLimit-Remaining': ['$remaining'],
  'RateLimit-ResetTime': [_reset.toIso8601String()],
};

GitLabApi _api(FakeAdapter adapter, {FakeAdapter? cdn}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
    cdnAdapter: cdn,
    readCacheClock: () => _now,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  addTearDown(api.close);
  return api;
}

void _expectBucket(GitLabApi api, String name, {int remaining = 14}) {
  final snapshot = api.rateBudget.snapshot();
  expect(snapshot.buckets.keys, [name]);
  final bucket = snapshot.buckets[name]!;
  expect(bucket.name, name);
  expect(bucket.limit, 100);
  expect(bucket.remaining, remaining);
  expect(bucket.resetAt, _reset);
  final level = remaining == 0 ? RateLevel.critical : RateLevel.low;
  expect(bucket.level, level);
  expect(snapshot.level, level);
}

void main() {
  test(
    'REST observes rate headers and a branch SHA through transport',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': _sha},
          }, headers: _rateHeaders('rest'));
        }
        expect(request.uri.path, endsWith('/repository/tree'));
        expect(request.uri.queryParameters['ref'], _sha);
        return jsonResponse(const <Object>[]);
      });
      final api = _api(adapter);

      await api.record(['projects', '8', 'repository', 'branches', 'main']);
      _expectBucket(api, 'rest');
      expect(api.rateBudget.snapshot().cooldowns, isEmpty);
      final first = await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': _sha},
      );
      final hit = await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': _sha},
      );

      expect(first.lineage, CacheLineage.network);
      expect(hit.lineage, CacheLineage.memory);
      expect(hit.value.items, isEmpty);
      _expectBucket(api, 'rest');
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.every((r) => api.instance.allowsApi(r.uri)),
        isTrue,
      );
    },
  );

  for (final graphql in [false, true]) {
    test(
      '${graphql ? 'exact GraphQL' : 'REST'} 429 sets API cooldown',
      () async {
        final adapter = FakeAdapter(
          (_) => jsonResponse(
            {'message': 'synthetic limit'},
            status: 429,
            headers: _rateHeaders('limited', remaining: 0),
          ),
        );
        final api = _api(adapter);
        final request = graphql
            ? api.pipelineGraphPage(Project.fromJson(projectJson(8)), 1)
            : api.currentUser();

        await expectLater(
          request,
          throwsA(
            isA<ApiFailure>()
                .having(
                  (failure) => failure.kind,
                  'kind',
                  FailureKind.rateLimited,
                )
                .having((failure) => failure.status, 'status', 429)
                .having((failure) => failure.retryAt, 'retryAt', _reset),
          ),
        );
        _expectBucket(api, 'limited', remaining: 0);
        expect(api.rateBudget.snapshot().cooldowns, {
          RateRequestClass.global: _reset,
        });
        expect(api.mayStartRequest, isFalse);
        await expectLater(api.currentUser(), throwsA(isA<ApiFailure>()));
        expect(adapter.requests, hasLength(1));
        expect(
          adapter.requests.single.uri,
          graphql ? api.instance.graphQL : api.instance.api(['user']),
        );
        expect(adapter.requests.single.method, graphql ? 'POST' : 'GET');
      },
    );
  }

  test(
    'exact GraphQL responses update the API rate budget without caching',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/8',
              'pipeline': {
                'id': 'gid://gitlab/Ci::Pipeline/1',
                'jobs': {'nodes': <Object>[]},
                'stages': {'nodes': <Object>[]},
              },
            },
          },
        }, headers: _rateHeaders('graphql')),
      );
      final api = _api(adapter);
      final project = Project.fromJson(projectJson(8));

      for (var i = 0; i < 2; i++) {
        final pipeline = await api.pipelineGraphPage(project, 1);
        expect(pipeline['id'], 'gid://gitlab/Ci::Pipeline/1');
        _expectBucket(api, 'graphql');
      }

      expect(api.rateBudget.snapshot().cooldowns, isEmpty);
      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        expect(request.method, 'POST');
        expect(request.uri, api.instance.graphQL);
        expect(api.instance.allowsApi(request.uri), isFalse);
        expect(api.instance.allowsGraphQL(request.uri), isTrue);
      }
      expect(
        api.instance.allowsGraphQL(
          api.instance.graphQL.replace(queryParameters: {'extra': '1'}),
        ),
        isFalse,
      );
      expect(
        api.instance.allowsGraphQL(
          api.instance.graphQL.replace(path: '${api.instance.graphQL.path}/'),
        ),
        isFalse,
      );
    },
  );

  for (final status in [200, 429]) {
    test(
      'CDN $status cannot change observed API buckets or cooldowns',
      () async {
        const location = 'https://cdn.example.com/artifacts.zip';
        final adapter = FakeAdapter((request) {
          if (request.uri.path.endsWith('/artifacts')) {
            return ResponseBody.fromString(
              '',
              302,
              headers: {
                ..._rateHeaders('rest'),
                'location': [location],
              },
            );
          }
          expect(request.uri.path, endsWith('/user'));
          return jsonResponse({'id': 7, 'username': 'tester'});
        });
        final cdn = FakeAdapter(
          (_) => ResponseBody.fromString(
            'zip',
            status,
            headers: {
              ..._rateHeaders('cdn', remaining: 0),
              'retry-after': ['600'],
              'content-type': ['application/zip'],
            },
          ),
        );
        final api = _api(adapter, cdn: cdn);
        final output = StreamController<List<int>>();
        final drained = output.stream.drain<void>();
        final sink = IOSink(output.sink);
        addTearDown(() async {
          await sink.close();
          await drained;
        });

        final download = api.downloadJobArtifacts(8, 3, sink: sink);
        if (status == 200) {
          expect((await download).bytesWritten, 3);
        } else {
          await expectLater(
            download,
            throwsA(
              isA<ApiFailure>()
                  .having((f) => f.kind, 'kind', FailureKind.rateLimited)
                  .having((f) => f.status, 'status', 429)
                  .having((f) => f.retryAt, 'retryAt', isNull),
            ),
          );
        }

        _expectBucket(api, 'rest');
        expect(api.rateBudget.snapshot().cooldowns, isEmpty);
        expect(api.mayStartRequest, isTrue);
        expect((await api.currentUser()).id, 7);
        _expectBucket(api, 'rest');
        expect(adapter.requests, hasLength(2));
        expect(cdn.requests, hasLength(1));
        final request = cdn.requests.single;
        expect(request.uri.toString(), location);
        expect(request.followRedirects, isFalse);
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains(anyOf('private-token', 'authorization', 'cookie'))),
        );
      },
    );
  }
}
