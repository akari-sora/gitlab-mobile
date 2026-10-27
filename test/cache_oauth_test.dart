import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/request_meter.dart';

import 'support/fake_adapter.dart';

const _timeout = Timeout(Duration(seconds: 20));
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

GitLabApi _oauthApi({
  required FakeAdapter apiAdapter,
  required FakeAdapter tokenAdapter,
  DateTime Function()? clock,
  Future<CacheDiskEntry?> Function(Uri uri, String accept)? source,
}) {
  final instance = GitLabInstance.parse('https://example.com/gitlab');
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
    readCacheClock: clock,
    readCacheSource: source,
  );
  api.bindReadCache('${instance.key}#7', 1);
  return api;
}

void main() {
  test(
    'recoverable OAuth 401 publishes successful cached read and meters two API sends',
    () async {
      var issueRequests = 0;
      final apiAdapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/issues/2')) {
          issueRequests += 1;
          if (issueRequests == 1) {
            expect(request.headers['Authorization'], 'Bearer old-access');
            return jsonResponse({'message': 'expired'}, status: 401);
          }
          expect(request.headers['Authorization'], 'Bearer new-access');
          return jsonResponse({'id': 2, 'title': 'after refresh'});
        }
        fail('unexpected API request ${request.uri}');
      });
      final tokenAdapter = FakeAdapter(
        (_) => jsonResponse({
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'token_type': 'bearer',
        }),
      );
      final api = _oauthApi(apiAdapter: apiAdapter, tokenAdapter: tokenAdapter);
      addTearDown(api.close);
      final meter = RequestMeter();

      final result = await meter.runAsync(
        () => api.cachedRecord(<String>['projects', '1', 'issues', '2']),
      );

      expect(result.value['title'], 'after refresh');
      expect(result.lineage, CacheLineage.network);
      expect(result.superseded, isFalse);
      expect(result.dropped, isFalse);
      expect(meter.count, 2);
      expect(issueRequests, 2);
      expect(tokenAdapter.requests, hasLength(1));
      final cached = await api.cachedRecord(<String>[
        'projects',
        '1',
        'issues',
        '2',
      ]);
      expect(cached.value['title'], 'after refresh');
      expect(cached.fetchedAt, result.fetchedAt);
      expect(issueRequests, 2);
      expect(tokenAdapter.requests, hasLength(1));
    },
    timeout: _timeout,
  );

  test(
    'terminal 401 cancels pending hydration and rejects old memory and disk snapshots',
    () async {
      final now = DateTime.utc(2026, 10, 23, 8);
      final oldFetchedAt = now.subtract(const Duration(hours: 1));
      final pendingDisk = Completer<CacheDiskEntry?>();
      var diskEnabled = false;
      var issueOneDiskReads = 0;
      var issueOneNetworkReads = 0;
      final apiAdapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/user')) {
          return jsonResponse({'message': 'terminal'}, status: 401);
        }
        if (path.endsWith('/issues/1')) {
          issueOneNetworkReads += 1;
          return jsonResponse({
            'id': 1,
            'title': issueOneNetworkReads == 1 ? 'memory' : 'new network',
          });
        }
        if (path.endsWith('/issues/2')) {
          return jsonResponse({'id': 2, 'title': 'network fallback'});
        }
        fail('unexpected API request ${request.uri}');
      });
      final api = GitLabApi(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        token: 'synthetic-pat',
        dio: Dio()..httpClientAdapter = apiAdapter,
        readCacheClock: () => now,
        readCacheSource: (uri, _) {
          if (uri.path.endsWith('/issues/2')) return pendingDisk.future;
          if (diskEnabled && uri.path.endsWith('/issues/1')) {
            issueOneDiskReads += 1;
            return Future<CacheDiskEntry?>.value(
              CacheDiskEntry(
                value: const <String, Object?>{'id': 1, 'title': 'old disk'},
                fetchedAt: oldFetchedAt,
                responseBytes: 32,
              ),
            );
          }
          return Future<CacheDiskEntry?>.value();
        },
      );
      api.bindReadCache('${api.instance.key}#7', 1);
      addTearDown(api.close);

      final memory = await api.cachedRecord(<String>[
        'projects',
        '1',
        'issues',
        '1',
      ]);
      expect(memory.value['title'], 'memory');
      final pending = api.cachedRecord(<String>[
        'projects',
        '1',
        'issues',
        '2',
      ]);
      await Future<void>.delayed(Duration.zero);

      await expectLater(api.currentUser(), throwsA(isA<ApiFailure>()));
      diskEnabled = true;
      pendingDisk.complete(
        CacheDiskEntry(
          value: const <String, Object?>{'id': 2, 'title': 'old pending disk'},
          fetchedAt: oldFetchedAt,
          responseBytes: 32,
        ),
      );
      await expectLater(
        pending.timeout(const Duration(seconds: 20)),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );

      final after = await api.cachedRecord(<String>[
        'projects',
        '1',
        'issues',
        '1',
      ]);
      expect(after.value['title'], 'new network');
      expect(after.lineage, CacheLineage.network);
      expect(issueOneDiskReads, 1);
      expect(issueOneNetworkReads, 2);
    },
    timeout: _timeout,
  );

  test(
    'recoverable OAuth 401 preserves an older pinned disk snapshot',
    () async {
      final now = DateTime.utc(2026, 10, 23, 8);
      final originalFetchedAt = now.subtract(const Duration(hours: 2));
      var issueRequests = 0;
      var treeNetworkReads = 0;
      var diskReads = 0;
      final apiAdapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/issues/2')) {
          issueRequests += 1;
          return issueRequests == 1
              ? jsonResponse({'message': 'expired'}, status: 401)
              : jsonResponse({'id': 2, 'title': 'refreshed'});
        }
        if (path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': _sha},
          });
        }
        if (path.endsWith('/repository/tree')) {
          treeNetworkReads += 1;
          return jsonResponse(const <Object?>[]);
        }
        fail('unexpected API request ${request.uri}');
      });
      final tokenAdapter = FakeAdapter(
        (_) => jsonResponse({
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'token_type': 'bearer',
        }),
      );
      final api = _oauthApi(
        apiAdapter: apiAdapter,
        tokenAdapter: tokenAdapter,
        clock: () => now,
        source: (uri, _) async {
          if (!uri.path.endsWith('/repository/tree')) return null;
          diskReads += 1;
          return CacheDiskEntry(
            value: ApiPage<Json>(const <Json>[
              <String, Object?>{
                'id': _sha,
                'name': 'README.md',
                'type': 'blob',
                'path': 'README.md',
              },
            ]),
            fetchedAt: originalFetchedAt,
            responseBytes: 64,
          );
        },
      );
      addTearDown(api.close);

      final refreshed = await api.cachedRecord(<String>[
        'projects',
        '1',
        'issues',
        '2',
      ]);
      expect(refreshed.value['title'], 'refreshed');
      await api.cachedRecord(<String>[
        'projects',
        '1',
        'repository',
        'branches',
        'main',
      ]);
      final tree = await api.cachedRecords(
        <String>['projects', '1', 'repository', 'tree'],
        query: const <String, String>{
          'ref': _sha,
          'path': '',
          'per_page': '50',
        },
      );

      expect(tree.lineage, CacheLineage.disk);
      expect(tree.fetchedAt, originalFetchedAt);
      expect(tree.value.items.single['name'], 'README.md');
      expect(diskReads, 1);
      expect(treeNetworkReads, 0);
    },
    timeout: _timeout,
  );
}
