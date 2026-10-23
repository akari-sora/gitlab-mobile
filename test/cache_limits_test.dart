import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

void main() {
  group('cache capacity and identity bounds', () {
    test(
      'raw response bytes times four enforce the 16 MiB LRU bound',
      () async {
        final calls = <String, int>{};
        final payload = 'x' * 900000;
        final adapter = FakeAdapter((request) {
          final id = request.uri.pathSegments.last;
          calls[id] = (calls[id] ?? 0) + 1;
          return jsonResponse({'id': int.parse(id), 'payload': payload});
        });
        final api = _boundApi(adapter);
        addTearDown(api.close);

        for (var id = 1; id <= 5; id++) {
          await api.cachedRecord(['projects', '8', 'issues', '$id']);
        }
        await api.cachedRecord(['projects', '8', 'issues', '5']);
        await api.cachedRecord(['projects', '8', 'issues', '1']);

        expect(calls['5'], 1);
        expect(calls['1'], 2);
      },
    );

    test('the 256-entry LRU bound is independent of the byte bound', () async {
      final calls = <int, int>{};
      final adapter = FakeAdapter((request) {
        final id = int.parse(request.uri.pathSegments.last);
        calls[id] = (calls[id] ?? 0) + 1;
        return jsonResponse({'id': id});
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      for (var id = 1; id <= GitLabApi.maxCachedReads; id++) {
        await api.cachedRecord(['projects', '8', 'issues', '$id']);
      }
      await api.cachedRecord(['projects', '8', 'issues', '1']);
      await api.cachedRecord([
        'projects',
        '8',
        'issues',
        '${GitLabApi.maxCachedReads + 1}',
      ]);
      await api.cachedRecord(['projects', '8', 'issues', '1']);
      await api.cachedRecord(['projects', '8', 'issues', '2']);

      expect(calls[1], 1);
      expect(calls[2], 2);
    });

    test('JSON over 1 MiB is delivered but not retained', () async {
      var calls = 0;
      final adapter = FakeAdapter((_) {
        calls++;
        return jsonResponse({'id': 1, 'payload': 'x' * (1024 * 1024)});
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      final first = await api.cachedRecord(['projects', '8', 'issues', '1']);
      final second = await api.cachedRecord(['projects', '8', 'issues', '1']);

      expect((first.value['payload'] as String).length, 1024 * 1024);
      expect((second.value['payload'] as String).length, 1024 * 1024);
      expect(calls, 2);
    });

    test('file over 1 MiB is delivered but not retained', () async {
      const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      var rawCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': sha},
          });
        }
        if (request.method == 'HEAD') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'x-gitlab-size': ['${1024 * 1024 + 1}'],
            },
          );
        }
        rawCalls++;
        return ResponseBody.fromString('x' * (1024 * 1024 + 1), 200);
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.cachedRecord([
        'projects',
        '8',
        'repository',
        'branches',
        'main',
      ]);
      expect((await api.textFile(8, sha, 'large.txt')).length, 1024 * 1024 + 1);
      expect((await api.textFile(8, sha, 'large.txt')).length, 1024 * 1024 + 1);
      expect(rawCalls, 2);
    });

    test('confirmed SHA LRU holds 4096 lowercase exact values', () async {
      final treeCalls = <String, int>{};
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.contains('/repository/branches/')) {
          final branch = request.uri.pathSegments.last;
          final index = int.parse(branch.substring(1));
          return jsonResponse({
            'name': branch,
            'commit': {'id': index.toRadixString(16).padLeft(40, '0')},
          });
        }
        final ref = request.uri.queryParameters['ref']!;
        treeCalls[ref] = (treeCalls[ref] ?? 0) + 1;
        return jsonResponse(const <Object>[]);
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      for (var index = 1; index <= 4096; index++) {
        await api.cachedRecord([
          'projects',
          '8',
          'repository',
          'branches',
          'b$index',
        ]);
      }
      final first = 1.toRadixString(16).padLeft(40, '0');
      final second = 2.toRadixString(16).padLeft(40, '0');
      await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': first},
      );
      await api.cachedRecord([
        'projects',
        '8',
        'repository',
        'branches',
        'b4097',
      ]);

      await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': first},
      );
      await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': second},
      );
      await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': second},
      );

      expect(treeCalls[first], 1);
      expect(treeCalls[second], 2);
    });

    test('tag responses do not confirm their commit SHA', () async {
      const sha = 'ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD';
      var treeCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/tags/v1')) {
          return jsonResponse({
            'name': 'v1',
            'commit': {'id': sha},
          });
        }
        treeCalls++;
        return jsonResponse(const <Object>[]);
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.cachedRecord(['projects', '8', 'repository', 'tags', 'v1']);
      for (var index = 0; index < 2; index++) {
        await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': sha.toLowerCase()},
        );
      }

      expect(treeCalls, 2);
    });

    test(
      'full-path project alias reuses the canonical numeric entry',
      () async {
        var calls = 0;
        final adapter = FakeAdapter((_) {
          calls++;
          return jsonResponse({...projectJson(8), 'license': null});
        });
        final api = _boundApi(adapter);
        addTearDown(api.close);

        final byPath = await api.cachedRecord(['projects', 'team/example-8']);
        final byId = await api.cachedRecord(['projects', '8']);

        expect(byPath.value['id'], 8);
        expect(byId.value['id'], 8);
        expect(calls, 1);
      },
    );

    test(
      'unresolved full-path read starts behind the default write fence',
      () async {
        final old = Completer<ResponseBody>();
        var reads = 0;
        final adapter = FakeAdapter((request) {
          if (request.method != 'GET') return jsonResponse({'id': 1});
          reads++;
          if (reads == 1) return old.future;
          return jsonResponse({
            ...projectJson(8),
            'name': 'After write',
            'license': null,
          });
        });
        final api = _boundApi(adapter);
        addTearDown(api.close);

        final pending = api.cachedRecord(['projects', 'team/example-8']);
        await _waitForRequests(adapter, 1);
        await api.writeRecord(
          'POST',
          ['projects', '8', 'repository', 'branches'],
          {'branch': 'new', 'ref': 'main'},
        );
        old.complete(
          jsonResponse({
            ...projectJson(8),
            'name': 'Before write',
            'license': null,
          }),
        );

        expect((await pending).value['name'], 'After write');
        expect(reads, 2);
      },
    );

    test('groupByPath is invalidated with projectLists', () async {
      var groupReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.method != 'GET') return jsonResponse({'id': 9});
        groupReads++;
        return jsonResponse({
          'id': 3,
          'name': 'Team',
          'full_path': 'team',
          'visibility': 'private',
        });
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.groupByPath('team');
      await api.groupByPath('team');
      await api.writeRecord('POST', ['projects'], {'name': 'New project'});
      await api.groupByPath('team');

      expect(groupReads, 2);
    });
  });

  test(
    'pinned disk and memory survive writes but project 403 purges both',
    () async {
      const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      var diskReads = 0;
      var treeNetworkReads = 0;
      var projectReads = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'name': 'main',
            'commit': {'id': sha},
          });
        }
        if (path.endsWith('/repository/tree')) {
          treeNetworkReads++;
          return jsonResponse(const <Object>[]);
        }
        if (path.endsWith('/api/graphql')) {
          return jsonResponse({
            'data': {
              'todoUnSnooze': {
                'todo': {'id': 'gid://gitlab/Todo/1', 'snoozedUntil': null},
                'errors': <Object>[],
              },
            },
          });
        }
        if (request.method != 'GET') return jsonResponse({'id': 1});
        if (path.endsWith('/projects/8')) {
          projectReads++;
          return jsonResponse({}, status: 403);
        }
        return jsonResponse({'id': 1});
      });
      final api = _boundApi(
        adapter,
        source: (uri, _) async {
          if (!uri.path.endsWith('/repository/tree') || diskReads++ != 0) {
            return null;
          }
          return CacheDiskEntry(
            value: ApiPage<Json>(const [
              {
                'id': sha,
                'name': 'README.md',
                'type': 'blob',
                'path': 'README.md',
              },
            ]),
            fetchedAt: DateTime.now(),
            responseBytes: 128,
          );
        },
      );
      addTearDown(api.close);

      await api.cachedRecord([
        'projects',
        '8',
        'repository',
        'branches',
        'main',
      ]);
      final disk = await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': sha},
      );
      expect(disk.lineage, CacheLineage.disk);

      await api.unsnoozeTodo(1);
      expect(
        (await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': sha},
        )).lineage,
        CacheLineage.disk,
      );
      await api.createNote(8, 'issues', 1, 'Synthetic comment');
      expect(
        (await api.cachedRecords(
          ['projects', '8', 'repository', 'tree'],
          query: {'ref': sha},
        )).lineage,
        CacheLineage.disk,
      );
      expect(diskReads, 1);
      expect(treeNetworkReads, 0);

      await expectLater(
        api.cachedRecord(['projects', '8'], fresh: true),
        throwsA(isA<ApiFailure>()),
      );
      await api.cachedRecords(
        ['projects', '8', 'repository', 'tree'],
        query: {'ref': sha},
      );

      expect(projectReads, 1);
      expect(diskReads, 2);
      expect(treeNetworkReads, 1);
    },
  );
}

GitLabApi _boundApi(FakeAdapter adapter, {ReadCacheSource? source}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheSource: source,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

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
