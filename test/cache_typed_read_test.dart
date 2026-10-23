import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _sha = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd';
const _networkSha = '1234567890abcdef1234567890abcdef12345678';
const _project = Project(
  id: 8,
  name: 'Example 8',
  path: 'team/example-8',
  defaultBranch: 'main',
);

void main() {
  test(
    'typed default branch shares memory and network SHA pins tree',
    () async {
      var branchCalls = 0;
      var treeCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/branches/main')) {
          branchCalls++;
          return jsonResponse({
            'name': 'main',
            'commit': {'id': _sha.toUpperCase()},
          });
        }
        if (request.uri.path.endsWith('/repository/tree')) {
          treeCalls++;
          return jsonResponse([_treeEntry]);
        }
        throw StateError('Unexpected request: ${request.uri}');
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      expect(await api.defaultBranchSha(_project).timeout(_deadline), _sha);
      expect(await api.defaultBranchSha(_project).timeout(_deadline), _sha);
      await api.tree(8, _sha).timeout(_deadline);
      await api.tree(8, _sha).timeout(_deadline);

      expect(branchCalls, 1);
      expect(treeCalls, 1);
    },
  );

  test('allowDisk false bypasses a hydrated default branch entry', () async {
    final now = DateTime.utc(2026, 10, 23, 12);
    var branchCalls = 0;
    final adapter = FakeAdapter((request) {
      expect(request.uri.path, endsWith('/repository/branches/main'));
      branchCalls++;
      return jsonResponse({
        'name': 'main',
        'commit': {'id': _networkSha},
      });
    });
    final api = _boundApi(
      adapter,
      clock: () => now,
      source: (uri, _) async {
        if (!uri.path.endsWith('/repository/branches/main')) return null;
        return CacheDiskEntry(
          value: {
            'name': 'main',
            'commit': {'id': _sha},
          },
          fetchedAt: now,
          responseBytes: 96,
        );
      },
    );
    addTearDown(api.close);

    expect(await api.defaultBranchSha(_project).timeout(_deadline), _sha);
    expect(branchCalls, 0);
    expect(
      await api.defaultBranchSha(_project, allowDisk: false).timeout(_deadline),
      _networkSha,
    );
    expect(branchCalls, 1);
  });

  test(
    'disk branch SHA stays unconfirmed until a trusted network read',
    () async {
      final now = DateTime.utc(2026, 10, 23, 12);
      var branchCalls = 0;
      var treeCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/branches/main')) {
          branchCalls++;
          return jsonResponse({
            'name': 'main',
            'commit': {'id': _sha},
          });
        }
        if (request.uri.path.endsWith('/repository/tree')) {
          treeCalls++;
          return jsonResponse([_treeEntry]);
        }
        throw StateError('Unexpected request: ${request.uri}');
      });
      final api = _boundApi(
        adapter,
        clock: () => now,
        source: (uri, _) async {
          if (!uri.path.endsWith('/repository/branches/main')) return null;
          return CacheDiskEntry(
            value: {
              'name': 'main',
              'commit': {'id': _sha},
            },
            fetchedAt: now,
            responseBytes: 96,
          );
        },
      );
      addTearDown(api.close);

      expect(await api.defaultBranchSha(_project).timeout(_deadline), _sha);
      await api.tree(8, _sha).timeout(_deadline);
      await api.tree(8, _sha).timeout(_deadline);
      expect(treeCalls, 2);

      expect(
        await api
            .defaultBranchSha(_project, allowDisk: false)
            .timeout(_deadline),
        _sha,
      );
      await api.tree(8, _sha).timeout(_deadline);
      await api.tree(8, _sha).timeout(_deadline);

      expect(branchCalls, 1);
      expect(treeCalls, 3);
    },
  );
}

const _treeEntry = {
  'id': _sha,
  'name': 'README.md',
  'type': 'blob',
  'path': 'README.md',
};

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
