import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

final _project = Project.fromJson(projectJson(42));
Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _contributor(String name) => {
  'name': name,
  'email': '$name@private.example',
  'commits': 7,
  'additions': 20,
  'deletions': 3,
};

Map<String, Object?> _commit({
  Object? stats = const {'additions': 10, 'deletions': 2},
  String committedDate = '2026-10-02T03:04:05Z',
}) => {
  'id': 'a' * 40,
  'short_id': 'private-short-id',
  'title': 'private title',
  'message': 'private message',
  'author_email': 'private@example.test',
  'committer_email': 'private@example.test',
  'trailers': {'Secret': 'private'},
  'committed_date': committedDate,
  'parent_ids': ['b' * 40, 'c' * 40],
  'stats': stats,
};

void main() {
  test(
    'contributors preserve rows, discard email and bind exact REST scope',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse([
          _contributor('Same Name'),
          _contributor('Same Name'),
        ]),
      );
      final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
      addTearDown(api.close);

      final page = await api.repositoryContributors(_project, ref: 'release/1');

      expect(page.items, hasLength(2));
      expect(page.items.map((row) => row.displayName), [
        'Same Name',
        'Same Name',
      ]);
      expect(page.items.first.commits, 7);
      expect(page.items.first.additions, 20);
      expect(page.items.first.deletions, 3);
      expect(page.items.first.toString(), isNot(contains('@private')));
      expect(() => page.items.add(page.items.first), throwsUnsupportedError);
      final request = adapter.requests.single;
      expect(
        request.uri.path,
        '/gitlab/api/v4/projects/42/repository/contributors',
      );
      expect(request.uri.queryParameters, {
        'ref': 'release/1',
        'order_by': 'commits',
        'sort': 'desc',
        'per_page': '100',
      });
      expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
    },
  );

  test('repository activity uses an exact half-open UTC window', () async {
    final inclusive = testApi(
      FakeAdapter(
        (_) => jsonResponse([_commit(committedDate: '2026-10-01T00:00:00Z')]),
      ),
    );
    expect(
      (await inclusive.repositoryActivity(
        _project,
        ref: 'main',
        from: DateTime.utc(2026, 10, 1),
        to: DateTime.utc(2026, 10, 3),
      )).items,
      hasLength(1),
    );
    inclusive.close();

    for (final outside in [
      '2026-09-30T23:59:59.999999Z',
      '2026-10-03T00:00:00Z',
    ]) {
      final api = testApi(
        FakeAdapter((_) => jsonResponse([_commit(committedDate: outside)])),
      );
      await expectLater(
        api.repositoryActivity(
          _project,
          ref: 'main',
          from: DateTime.utc(2026, 10, 1),
          to: DateTime.utc(2026, 10, 3),
        ),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test('contributor continuation retains immutable scope', () async {
    var calls = 0;
    final adapter = FakeAdapter((request) {
      calls++;
      return jsonResponse(
        [_contributor('Page $calls')],
        headers: calls == 1
            ? {
                'x-next-page': ['2'],
              }
            : const {},
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final first = await api.repositoryContributors(_project, ref: 'main');
    expect(first.next?.queryParameters['page'], '2');
    final second = await api.repositoryContributors(
      _project,
      ref: 'main',
      next: first.next,
    );
    expect(second.items.single.displayName, 'Page 2');
    expect(adapter.requests.last.uri.queryParameters['ref'], 'main');

    expect(
      () => api.repositoryContributors(
        _project,
        ref: 'main',
        next: first.next!.replace(
          queryParameters: {...first.next!.queryParameters, 'ref': 'other'},
        ),
      ),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
    expect(adapter.requests, hasLength(2));
  });

  test(
    'repository activity emits only aggregation fields and UTC filters',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse([_commit()]));
      final api = testApi(adapter);
      addTearDown(api.close);
      final result = await api.repositoryActivity(
        _project,
        ref: 'main',
        from: DateTime.parse('2026-10-01T08:00:00+08:00'),
        to: DateTime.parse('2026-10-03T08:00:00+08:00'),
      );
      final commit = result.items.single;
      expect(commit.id, 'a' * 40);
      expect(commit.committedAt, DateTime.parse('2026-10-02T03:04:05Z'));
      expect(commit.parentCount, 2);
      expect(commit.additions, 10);
      expect(commit.deletions, 2);
      expect(commit.toString(), isNot(contains('private')));
      expect(adapter.requests.single.uri.queryParameters, {
        'ref_name': 'main',
        'since': '2026-10-01T00:00:00.000Z',
        'until': '2026-10-02T23:59:59.999999Z',
        'with_stats': 'true',
        'per_page': '100',
      });
    },
  );

  test('repository activity keeps unavailable stats nullable', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse([
        _commit(stats: null, committedDate: '2026-10-01T12:00:00Z'),
      ]),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final result = await api.repositoryActivity(
      _project,
      ref: 'main',
      from: DateTime.utc(2026, 10, 1),
      to: DateTime.utc(2026, 10, 2),
    );
    expect(result.items.single.additions, isNull);
    expect(result.items.single.deletions, isNull);
  });

  test(
    'activity pagination keeps caller scope when GitLab canonicalizes dates',
    () async {
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        return jsonResponse(
          [_commit()],
          headers: calls == 1
              ? {
                  'link': [
                    '<https://example.com/gitlab/api/v4/projects/42/repository/commits?'
                        'id=42&order=default&page=2&pagination=legacy&per_page=100&'
                        'ref_name=main&since=2026-10-01T00%3A00%3A00%2B00%3A00&'
                        'trailers=false&until=2026-10-02T23%3A59%3A59.999999%2B00%3A00&'
                        'with_stats=true>; rel="next"',
                  ],
                }
              : const {},
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final first = await api.repositoryActivity(
        _project,
        ref: 'main',
        from: DateTime.utc(2026, 10, 1),
        to: DateTime.utc(2026, 10, 3),
      );
      expect(first.next?.queryParameters, {
        'ref_name': 'main',
        'since': '2026-10-01T00:00:00.000Z',
        'until': '2026-10-02T23:59:59.999999Z',
        'with_stats': 'true',
        'per_page': '100',
        'page': '2',
        'pagination': 'legacy',
      });
      final second = await api.repositoryActivity(
        _project,
        ref: 'main',
        from: DateTime.utc(2026, 10, 1),
        to: DateTime.utc(2026, 10, 3),
        next: first.next,
      );
      expect(second.items, hasLength(1));
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.uri.queryParameters['id'], isNull);
      expect(adapter.requests.last.uri.queryParameters['trailers'], isNull);
    },
  );

  test(
    'activity pagination rejects an off-origin Link without transport',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(
          [_commit()],
          headers: {
            'link': [
              '<https://evil.example/api/v4/projects/42/repository/commits?'
                  'page=2>; rel="next"',
            ],
          },
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.repositoryActivity(
          _project,
          ref: 'main',
          from: DateTime.utc(2026, 10, 1),
          to: DateTime.utc(2026, 10, 3),
        ),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test('activity Link cannot change ref, date or stats scope', () async {
    final canonical = <String, String>{
      'id': '42',
      'order': 'default',
      'page': '2',
      'pagination': 'legacy',
      'per_page': '100',
      'ref_name': 'main',
      'since': '2026-10-01T00:00:00+00:00',
      'trailers': 'false',
      'until': '2026-10-02T23:59:59.999999+00:00',
      'with_stats': 'true',
    };
    for (final changed in <Map<String, String>>[
      {'ref_name': 'other'},
      {'since': '2026-09-30T00:00:00+00:00'},
      {'with_stats': 'false'},
    ]) {
      final next = Uri.parse(
        'https://example.com/gitlab/api/v4/projects/42/repository/commits',
      ).replace(queryParameters: {...canonical, ...changed});
      final adapter = FakeAdapter(
        (_) => jsonResponse(
          [_commit()],
          headers: {
            'link': ['<$next>; rel="next"'],
          },
        ),
      );
      final api = testApi(adapter);
      await expectLater(
        api.repositoryActivity(
          _project,
          ref: 'main',
          from: DateTime.utc(2026, 10, 1),
          to: DateTime.utc(2026, 10, 3),
        ),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(adapter.requests, hasLength(1));
      api.close();
    }
  });

  test('malformed contributor and commit fields fail closed', () async {
    for (final payload in <Object?>[
      [
        {..._contributor('Name'), 'commits': -1},
      ],
      [
        {..._contributor('Name'), 'additions': 1.5},
      ],
    ]) {
      final api = testApi(FakeAdapter((_) => jsonResponse(payload)));
      await expectLater(
        api.repositoryContributors(_project),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
    for (final payload in <Object?>[
      [
        {..._commit(), 'committed_date': 'not-a-date'},
      ],
      [
        {..._commit(), 'committed_date': '2026-02-31T03:04:05Z'},
      ],
      [
        {..._commit(), 'committed_date': '2026-10-02T03:04:05'},
      ],
      [
        {
          ..._commit(),
          'parent_ids': [7],
        },
      ],
      [
        _commit(stats: {'additions': -1, 'deletions': 2}),
      ],
      [
        _commit(stats: {'additions': 1}),
      ],
    ]) {
      final api = testApi(FakeAdapter((_) => jsonResponse(payload)));
      await expectLater(
        api.repositoryActivity(
          _project,
          ref: 'main',
          from: DateTime.utc(2026, 10, 1),
          to: DateTime.utc(2026, 10, 2),
        ),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test('invalid project, ref and interval issue no request', () async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final api = testApi(adapter);
    addTearDown(api.close);
    const badProject = Project(id: 0, name: 'Bad', path: 'team/bad');
    expect(
      () => api.repositoryContributors(badProject),
      throwsA(_failure(FailureKind.validation)),
    );
    for (final ref in ['', ' main', 'main\nother']) {
      expect(
        () => api.repositoryActivity(
          _project,
          ref: ref,
          from: DateTime.utc(2026, 10, 1),
          to: DateTime.utc(2026, 10, 2),
        ),
        throwsA(_failure(FailureKind.validation)),
      );
    }
    expect(
      () => api.repositoryActivity(
        _project,
        ref: 'main',
        from: DateTime.utc(2026, 10, 2),
        to: DateTime.utc(2026, 10, 1),
      ),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests, isEmpty);
  });

  test('closing the account client rejects an older REST response', () async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => pending.future);
    final api = testApi(adapter);
    final operation = api.repositoryContributors(_project);
    await Future<void>.delayed(Duration.zero);
    api.close();
    pending.complete(jsonResponse([_contributor('Old account')]));
    await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
  });
}
