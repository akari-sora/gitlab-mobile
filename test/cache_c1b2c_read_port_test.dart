import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _project = Project(
  id: 9,
  name: 'Example 9',
  path: 'team/example-9',
  defaultBranch: 'main',
);

void main() {
  test('AI issue read hits fresh memory with zero physical requests', () async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/notes')) {
        return jsonResponse([
          {'id': 4, 'body': 'network note'},
        ]);
      }
      return jsonResponse({'iid': 3, 'title': 'network issue'});
    });
    final api = _boundApi(adapter);
    addTearDown(api.close);
    final port = GitLabAiReadPort(api, 9);

    final first = await port.issue(3).timeout(_deadline);
    final second = await port.issue(3).timeout(_deadline);

    expect(first.requestCount, 2);
    expect(second.requestCount, 0);
    expect(second.value['title'], 'network issue');
    expect(adapter.requests, hasLength(2));
  });

  test('AI issue read refuses disk values promoted to memory', () async {
    final now = DateTime.utc(2026, 10, 23, 12);
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/notes')) {
        return jsonResponse([
          {'id': 5, 'body': 'network note'},
        ]);
      }
      return jsonResponse({'iid': 3, 'title': 'network issue'});
    });
    final api = _boundApi(
      adapter,
      clock: () => now,
      source: (uri, _) async {
        if (uri.path.endsWith('/notes')) {
          return CacheDiskEntry(
            value: ApiPage<Map<String, dynamic>>([
              {'id': 4, 'body': 'disk note'},
            ]),
            fetchedAt: now,
            responseBytes: 32,
          );
        }
        return CacheDiskEntry(
          value: {'iid': 3, 'title': 'disk issue'},
          fetchedAt: now,
          responseBytes: 32,
        );
      },
    );
    addTearDown(api.close);

    final diskIssue = await api.cachedRecord(_issuePath).timeout(_deadline);
    final diskNotes = await api
        .cachedRecords(_notesPath, query: _notesQuery)
        .timeout(_deadline);
    expect(diskIssue.lineage, CacheLineage.disk);
    expect(diskNotes.lineage, CacheLineage.disk);

    final read = await GitLabAiReadPort(api, 9).issue(3).timeout(_deadline);
    expect(read.value['title'], 'network issue');
    expect(
      ((read.value['notes'] as List<Object?>).single
          as Map<String, dynamic>)['body'],
      'network note',
    );
    expect(read.requestCount, 2);
    expect(adapter.requests, hasLength(2));
  });

  test(
    'AI expired issue reports unavailable when refresh network fails',
    () async {
      var now = DateTime.utc(2026, 10, 23, 12);
      var networkDown = false;
      final adapter = FakeAdapter((request) {
        if (networkDown) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
          );
        }
        if (request.uri.path.endsWith('/notes')) return jsonResponse([]);
        return jsonResponse({'iid': 3, 'title': 'old issue'});
      });
      final api = _boundApi(adapter, clock: () => now);
      addTearDown(api.close);
      final port = GitLabAiReadPort(api, 9);

      expect(
        (await port.issue(3).timeout(_deadline)).value['title'],
        'old issue',
      );
      now = now.add(const Duration(seconds: 61));
      networkDown = true;

      await expectLater(
        port.issue(3).timeout(_deadline),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests, hasLength(3));
    },
  );

  test(
    'AI MR versions refuse promoted disk and then hit fresh memory',
    () async {
      final now = DateTime.utc(2026, 10, 23, 12);
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 5, 'head_commit_sha': _head, 'base_commit_sha': _base},
          ]);
        }
        return jsonResponse({
          'id': 5,
          'head_commit_sha': _head,
          'base_commit_sha': _base,
          'diffs': [
            {'old_path': 'a', 'new_path': 'a', 'diff': '+network'},
          ],
        });
      });
      final api = _boundApi(
        adapter,
        clock: () => now,
        source: (uri, _) async {
          if (uri.path.endsWith('/versions')) {
            return CacheDiskEntry(
              value: ApiPage<Map<String, dynamic>>([
                {'id': 5, 'head_commit_sha': _head, 'base_commit_sha': _base},
              ]),
              fetchedAt: now,
              responseBytes: 80,
            );
          }
          return CacheDiskEntry(
            value: {
              'id': 5,
              'head_commit_sha': _head,
              'base_commit_sha': _base,
              'diffs': [
                {'old_path': 'a', 'new_path': 'a', 'diff': '+disk'},
              ],
            },
            fetchedAt: now,
            responseBytes: 120,
          );
        },
      );
      addTearDown(api.close);

      expect(
        (await api
                .cachedRecords(_versionsPath, query: const {'per_page': '100'})
                .timeout(_deadline))
            .lineage,
        CacheLineage.disk,
      );
      expect(
        (await api.cachedRecord(_versionPath).timeout(_deadline)).lineage,
        CacheLineage.disk,
      );
      final port = GitLabAiReadPort(api, 9);

      final first = await port
          .mergeRequestDiff(3, headSha: _head, baseSha: _base)
          .timeout(_deadline);
      final second = await port
          .mergeRequestDiff(3, headSha: _head, baseSha: _base)
          .timeout(_deadline);

      expect(
        ((first.value['changes'] as List<Object?>).single
            as Map<String, dynamic>)['diff'],
        '+network',
      );
      expect(first.requestCount, 2);
      expect(second.requestCount, 0);
      expect(adapter.requests, hasLength(2));
    },
  );

  test('AI pinned file read refuses disk values promoted to memory', () async {
    final now = DateTime.utc(2026, 10, 23, 12);
    var diskReads = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/repository/branches/main')) {
        return jsonResponse({
          'name': 'main',
          'commit': {'id': _head},
        });
      }
      if (request.method == 'HEAD') {
        return ResponseBody.fromString(
          '',
          200,
          headers: const {
            'x-gitlab-size': ['12'],
          },
        );
      }
      return ResponseBody.fromString('network file', 200);
    });
    final api = _boundApi(
      adapter,
      clock: () => now,
      source: (uri, accept) async {
        if (!uri.path.contains('/repository/files/') ||
            accept != 'text/plain') {
          return null;
        }
        diskReads++;
        return CacheDiskEntry(
          value: 'disk file',
          fetchedAt: now,
          responseBytes: 9,
        );
      },
    );
    addTearDown(api.close);

    expect(await api.defaultBranchSha(_project).timeout(_deadline), _head);
    expect(await api.textFile(9, _head, 'lib/a.dart'), 'disk file');
    expect(diskReads, 1);

    final read = await GitLabAiReadPort(
      api,
      9,
    ).readFile(_head, 'lib/a.dart').timeout(_deadline);
    expect(read.value, 'network file');
    expect(read.requestCount, 2);
    final memory = await GitLabAiReadPort(
      api,
      9,
    ).readFile(_head, 'lib/a.dart').timeout(_deadline);
    expect(memory.value, 'network file');
    expect(memory.requestCount, 0);
    expect(adapter.requests, hasLength(3));
  });
}

const _issuePath = ['projects', '9', 'issues', '3'];
const _notesPath = ['projects', '9', 'issues', '3', 'notes'];
const _notesQuery = {
  'order_by': 'created_at',
  'sort': 'desc',
  'per_page': '30',
};
const _versionsPath = ['projects', '9', 'merge_requests', '3', 'versions'];
const _versionPath = ['projects', '9', 'merge_requests', '3', 'versions', '5'];

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
