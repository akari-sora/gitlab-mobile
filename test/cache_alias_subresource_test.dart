import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _alias = 'team/app';
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _file = ['projects', _alias, 'repository', 'files', 'README.md'];
const _issues = ['projects', _alias, 'issues'];
const _links = ['projects', '8', 'issues', '1', 'links'];

void main() {
  for (final numericFirst in [true, false]) {
    test(
      '${numericFirst ? 'P1' : 'P2'} full-path pages send every time and preserve cursors',
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
        for (var round = 0; round < 3; round++) {
          for (final project in forms) {
            final page = await api.cachedRecords([
              'projects',
              project,
              'issues',
            ]);
            expect(
              page.lineage,
              round == 0 || project == _alias
                  ? CacheLineage.network
                  : CacheLineage.memory,
            );
            expect(page.value.next!.pathSegments[4], project);
          }
        }
        expect(adapter.requests, hasLength(5));
        expect(
          (await api.cachedRecord(['projects', _alias])).lineage,
          CacheLineage.memory,
        );
        expect(adapter.requests, hasLength(5));
      },
      timeout: const Timeout(_deadline),
    );
  }

  test(
    'P3 full-path reads do not join numeric pending pages and can continue',
    () async {
      final held = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = FakeAdapter((request) {
        if (request.uri.pathSegments.length == 5) return jsonResponse(_project);
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
      final path = await api.cachedRecords(_issues).timeout(_deadline);
      expect((await api.cachedRecords(_issues)).lineage, CacheLineage.network);
      held.complete(_page(numericRequest));
      await numeric.timeout(_deadline);
      for (var round = 0; round < 2; round++) {
        final next = await api.cachedRecords(_issues, next: path.value.next);
        expect(next.lineage, CacheLineage.network);
        expect(next.value.items.single['title'], '$_alias page 2');
      }
      expect(adapter.requests, hasLength(6));
    },
    timeout: const Timeout(_deadline),
  );

  test('full-path reads of the same pending resource each send', () async {
    final held = Completer<ResponseBody>();
    final started = Completer<void>();
    final adapter = FakeAdapter((request) {
      if (!started.isCompleted) {
        started.complete();
        return held.future;
      }
      return _page(request);
    });
    final api = _api(adapter);
    addTearDown(api.close);
    final first = api.cachedRecords(_issues);
    await started.future.timeout(_deadline);
    final second = await api.cachedRecords(_issues).timeout(_deadline);
    expect(second.lineage, CacheLineage.network);
    held.complete(_page(adapter.requests.first));
    expect((await first.timeout(_deadline)).lineage, CacheLineage.network);
    expect(adapter.requests, hasLength(2));
  }, timeout: const Timeout(_deadline));

  test(
    'full-path sub-resources skip disk and memory across read classes',
    () async {
      var hydrations = 0;
      final adapter = FakeAdapter(
        (request) => jsonResponse(
          request.uri.pathSegments.last == 'main'
              ? {
                  'commit': {'id': _sha},
                }
              : _issue(9),
        ),
      );
      final api = _api(
        adapter,
        source: (_, _) async {
          hydrations++;
          return CacheDiskEntry(
            value: _issue(99),
            fetchedAt: DateTime.utc(2026),
            responseBytes: 128,
          );
        },
      );
      addTearDown(api.close);
      await api.record(['projects', '8', 'repository', 'branches', 'main']);
      final cases = [
        (path: ['issues', '1'], query: <String, String>{}),
        (path: ['repository', 'branches', 'main'], query: <String, String>{}),
        (path: ['repository', 'files', 'README.md'], query: {'ref': _sha}),
        (
          path: ['merge_requests', '1', 'versions', '2'],
          query: <String, String>{},
        ),
        (path: ['issues', '1', 'notes'], query: <String, String>{}),
        (path: ['search'], query: {'search': 'example'}),
      ];
      for (final endpoint in cases) {
        for (var round = 0; round < 2; round++) {
          final result = await api.cachedRecord([
            'projects',
            _alias,
            ...endpoint.path,
          ], query: endpoint.query);
          expect(result.lineage, CacheLineage.network);
        }
      }
      expect(hydrations, 0);
      expect(adapter.requests, hasLength(13));
    },
    timeout: const Timeout(_deadline),
  );

  for (final supplied in [false, true]) {
    test(
      'full-path pages validate ${supplied ? 'caller' : 'response'} cursors',
      () async {
        final adapter = FakeAdapter(
          (request) => supplied
              ? _page(request)
              : jsonResponse(
                  [],
                  headers: {
                    'link': [
                      '<${request.uri.replace(path: '/gitlab/api/v4/projects/8/issues', queryParameters: {'per_page': '30', 'page': '2'})}>; rel="next"',
                    ],
                  },
                ),
        );
        final api = _api(adapter);
        addTearDown(api.close);
        final next = api.instance.api(
          ['projects', '8', 'issues'],
          {'per_page': '30', 'page': '2'},
        );
        await expectLater(
          Future.sync(
            () => api.cachedRecords(_issues, next: supplied ? next : null),
          ),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              supplied ? FailureKind.unsupported : FailureKind.invalidResponse,
            ),
          ),
        );
        expect(adapter.requests, hasLength(supplied ? 0 : 1));
      },
      timeout: const Timeout(_deadline),
    );
  }

  test(
    'P4 retargeted full-path detail stays uncached and cannot replace numeric data',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.pathSegments.length == 5) return jsonResponse(_project);
        return jsonResponse(
          _issue(request.uri.pathSegments[4] == _alias ? 9 : 8),
        );
      });
      final api = _api(adapter);
      addTearDown(api.close);
      await api.project(_alias);
      for (var round = 0; round < 3; round++) {
        final path = await api.cachedRecord([
          'projects',
          _alias,
          'issues',
          '1',
        ], fresh: round == 0);
        expect(path.lineage, CacheLineage.network);
        expect(path.value['project_id'], 9);
        final numeric = await api.cachedRecord([
          'projects',
          '8',
          'issues',
          '1',
        ]);
        expect(
          numeric.lineage,
          round == 0 ? CacheLineage.network : CacheLineage.memory,
        );
        expect(numeric.value['project_id'], 8);
      }
      expect(adapter.requests, hasLength(5));
    },
    timeout: const Timeout(_deadline),
  );

  for (final probe in ['R1', 'R2', 'R7']) {
    test(
      '$probe full-path entries cannot survive numeric revocation after alias loss',
      () async {
        var now = DateTime.utc(2026);
        var revoked = false;
        final adapter = FakeAdapter((request) {
          if (revoked) return jsonResponse({}, status: 404);
          if (request.uri.pathSegments.length == 5) {
            return jsonResponse(_project);
          }
          if (request.method == 'POST') {
            return jsonResponse({'name': 'example'});
          }
          if (request.uri.pathSegments.last == 'main') {
            return jsonResponse({
              'commit': {'id': _sha},
            });
          }
          return probe == 'R2'
              ? _page(request)
              : jsonResponse({'content': 'synthetic private file'});
        });
        final api = _api(adapter, clock: () => now);
        addTearDown(api.close);
        await api.project(_alias);
        if (probe == 'R2') {
          now = now.add(const Duration(minutes: 25));
        } else {
          await api.record(['projects', '8', 'repository', 'branches', 'main']);
        }
        Future<CacheLineage> read() async => probe == 'R2'
            ? (await api.cachedRecords(_issues)).lineage
            : (await api.cachedRecord(_file, query: {'ref': _sha})).lineage;
        expect(await read(), CacheLineage.network);
        if (probe == 'R7') {
          await api.writeRecord(
            'POST',
            ['projects', '8', 'labels'],
            {'name': 'example'},
          );
        } else {
          now = DateTime.utc(2026).add(const Duration(minutes: 31));
        }
        revoked = true;
        await expectLater(api.record(['projects', '8']), throwsA(_invisible));
        final before = adapter.requests.length;
        for (var round = 0; round < 2; round++) {
          await expectLater(read(), throwsA(_invisible));
        }
        expect(adapter.requests, hasLength(before + 2));
      },
      timeout: const Timeout(_deadline),
    );
  }

  for (final disk in [false, true]) {
    for (final revokedProject in ['8', '9']) {
      test(
        'R5 ${disk ? 'disk' : 'network'} links check owner permission, revoked=$revokedProject',
        () async {
          final network = Completer<ResponseBody>();
          final hydration = Completer<CacheDiskEntry?>();
          final started = Completer<void>();
          final adapter = FakeAdapter((request) {
            if (request.uri.pathSegments.last == 'links') {
              started.complete();
              return network.future;
            }
            return jsonResponse({}, status: 404);
          });
          final api = _api(
            adapter,
            source: disk
                ? (_, _) {
                    started.complete();
                    return hydration.future;
                  }
                : null,
          );
          addTearDown(api.close);
          final reading = api.cachedRecords(_links);
          final checked = revokedProject == '8'
              ? expectLater(
                  reading.timeout(_deadline),
                  throwsA(
                    isA<ApiFailure>().having(
                      (failure) => failure.kind,
                      'kind',
                      FailureKind.cancelled,
                    ),
                  ),
                )
              : expectLater(
                  reading.timeout(_deadline),
                  completion(isA<CachedRead<ApiPage<Json>>>()),
                );
          await started.future.timeout(_deadline);
          await expectLater(
            api.record(['projects', revokedProject]),
            throwsA(_invisible),
          );
          final value = ApiPage<Json>([_issue(9)]);
          if (disk) {
            hydration.complete(
              CacheDiskEntry(
                value: value,
                fetchedAt: DateTime.utc(2026),
                responseBytes: 128,
              ),
            );
          } else {
            network.complete(jsonResponse(value.items));
          }
          await checked;
          if (revokedProject == '9') {
            final result = await reading;
            expect(result.value.items.single['project_id'], 9);
            expect(
              result.lineage,
              disk ? CacheLineage.disk : CacheLineage.network,
            );
            final sends = adapter.requests.length;
            expect(
              (await api.cachedRecords(
                _links,
              )).value.items.single['project_id'],
              9,
            );
            expect(adapter.requests, hasLength(sends));
          }
        },
        timeout: const Timeout(_deadline),
      );
    }
  }
}

final _project = {...projectJson(8), 'path_with_namespace': _alias};
final _invisible = isA<ApiFailure>().having(
  (failure) => failure.kind,
  'kind',
  FailureKind.invisible,
);

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
    readCacheClock: clock ?? () => DateTime.utc(2026),
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}
