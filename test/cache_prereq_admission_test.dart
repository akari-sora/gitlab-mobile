import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 5);
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _project = Project(
  id: 8,
  name: 'Example 8',
  path: 'team/example-8',
  defaultBranch: 'main',
);

void main() {
  for (final kind in ['project', 'branch', 'tree', 'record', 'records']) {
    test('foreground $kind cannot join a droppable background read', () async {
      final gate = Completer<void>();
      final adapter = FakeAdapter((request) async {
        if (request.uri.path.contains('/issues/block-')) await gate.future;
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({
            'commit': {'id': _sha},
          });
        }
        if (request.uri.path.endsWith('/tree') ||
            request.uri.path.endsWith('/issues')) {
          return jsonResponse(const <Object>[]);
        }
        return jsonResponse(projectJson(8));
      });
      final api = testApi(adapter)
        ..bindReadCache('https://example.com/gitlab#7', 1);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
        api.close();
      });
      if (kind == 'tree') {
        await api.defaultBranchSha(_project).timeout(_deadline);
      }
      final blockers = [
        for (var i = 0; i < 4; i++)
          api
              .cachedRecord([
                'projects',
                '8',
                'issues',
                'block-$i',
              ], background: true)
              .then<Object>((value) => value, onError: (Object error) => error),
      ];
      final before = adapter.requests.length;
      await _until(() => adapter.requests.length == before + 4);
      final path = switch (kind) {
        'project' => ['projects', '8'],
        'branch' => ['projects', '8', 'repository', 'branches', 'main'],
        'tree' => ['projects', '8', 'repository', 'tree'],
        'records' => ['projects', '8', 'issues'],
        _ => ['projects', '8', 'issues', '1'],
      };
      final query = kind == 'tree'
          ? {'ref': _sha, 'path': '', 'per_page': '50'}
          : const <String, String>{};
      final Future<Object> background = kind == 'tree' || kind == 'records'
          ? api.cachedRecords(path, query: query, background: true)
          : api.cachedRecord(path, background: true);
      final Future<Object> foreground = switch (kind) {
        'project' => api.project('8'),
        'branch' => api.defaultBranchSha(_project),
        'tree' => api.tree(8, _sha),
        'records' => api.cachedRecords(path),
        _ => api.cachedRecord(path),
      };
      final outcome = foreground.then<Object>(
        (value) => value,
        onError: (Object error) => error,
      );
      final queued = [
        for (var i = 0; i < 32; i++)
          api
              .cachedRecord([
                'projects',
                '8',
                'issues',
                'queued-$i',
              ], background: true)
              .then<Object>((value) => value, onError: (Object error) => error),
      ];
      expect(
        (await background.timeout(_deadline) as CachedRead<Object>).dropped,
        isTrue,
      );
      final result = await outcome.timeout(_deadline);
      switch (kind) {
        case 'project':
          expect(result, isA<Project>());
        case 'branch':
          expect(result, _sha);
        case 'tree':
          expect(result, isA<ApiPage<TreeEntry>>());
        case 'records':
          expect(result, isA<CachedRead<ApiPage<Json>>>());
          expect((result as CachedRead<ApiPage<Json>>).dropped, isFalse);
        default:
          expect(result, isA<CachedRead<Json>>());
          expect((result as CachedRead<Json>).dropped, isFalse);
      }
      gate.complete();
      await Future.wait([...blockers, ...queued]).timeout(_deadline);
    });
  }

  for (final kind in [
    'unbound',
    'outside policy',
    'text branch',
    'unconfirmed tree',
    'full path',
  ]) {
    test('uncacheable $kind bypasses admission and cache revocation', () async {
      final foregroundGate = Completer<void>();
      final readGate = Completer<void>();
      final adapter = FakeAdapter((request) async {
        if (request.uri.path.contains('/issues/block-')) {
          await foregroundGate.future;
          return jsonResponse({'id': 1});
        }
        if (request.uri.queryParameters['deny'] == 'true') {
          return jsonResponse({}, status: 403);
        }
        await readGate.future;
        if (request.method == 'HEAD') return ResponseBody.fromString('', 200);
        if (request.uri.path.endsWith('/raw')) {
          return ResponseBody.fromString('branch content', 200);
        }
        if (request.uri.path.endsWith('/tree')) {
          return jsonResponse(const <Object>[]);
        }
        return jsonResponse(projectJson(8));
      });
      final api = testApi(adapter);
      if (kind != 'unbound') api.bindReadCache('${api.instance.key}#7', 1);
      addTearDown(() {
        if (!foregroundGate.isCompleted) foregroundGate.complete();
        if (!readGate.isCompleted) readGate.complete();
        api.close();
      });
      final blockers = [
        for (var i = 0; i < 16; i++)
          api
              .cachedRecord(['projects', '8', 'issues', 'block-$i'])
              .then<Object>((value) => value, onError: (Object error) => error),
      ];
      await _until(() => adapter.requests.length == 16);
      final before = adapter.requests.length;
      Future<Object> read() => switch (kind) {
        'unbound' => api.project('8'),
        'outside policy' => api.cachedRecord(['projects', '8', 'unknown']),
        'text branch' => api.textFile(8, 'main', 'README.md'),
        'unconfirmed tree' => api.tree(8, _sha),
        _ => api.cachedRecord(['projects', 'team/example-8', 'issues', '1']),
      };
      final first = read().then<Object>(
        (value) => value,
        onError: (Object error) => error,
      );
      await _until(() => adapter.requests.length == before + 1);
      // Revoke every cache permission while the uncached network read is held.
      await expectLater(
        api.record(['projects', '8'], query: {'deny': 'true'}),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.forbidden,
          ),
        ),
      );
      api.clearReadCache();
      readGate.complete();
      final result = await first.timeout(_deadline);
      expect(result, isNot(isA<Exception>()));
      expect(result, isNot(isA<Error>()));
      final after = adapter.requests.length;
      await read().timeout(_deadline);
      expect(adapter.requests.length - after, kind == 'text branch' ? 2 : 1);
      foregroundGate.complete();
      await Future.wait(blockers).timeout(_deadline);
    });
  }
}

Future<void> _until(bool Function() done) async {
  final end = DateTime.now().add(_deadline);
  while (!done()) {
    if (!DateTime.now().isBefore(end)) {
      throw TimeoutException('condition', _deadline);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
