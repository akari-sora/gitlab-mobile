import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/analytics_models.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

final _project = Project.fromJson(projectJson(42));
final _from = DateTime.utc(2026, 10, 1);
final _to = DateTime.utc(2026, 10, 3);
Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _pipelineEnvelope({
  Object? analytics,
  Object? project = const _Absent(),
}) => {
  'data': {
    'project': project is _Absent
        ? {
            'id': 'gid://gitlab/Project/42',
            'pipelineAnalytics':
                analytics ??
                {
                  'aggregate': {
                    'label': null,
                    'all': '12',
                    'success': '7',
                    'failed': '3',
                    'other': '2',
                    'durationStatistics': {'p50': 1.5, 'p95': 8.25},
                  },
                  'timeSeries': [
                    {
                      'label': '2026-10-01',
                      'all': '12',
                      'success': 0,
                      'failed': null,
                      'other': '2',
                      'durationStatistics': {'p50': 1.25, 'p95': 4},
                    },
                  ],
                },
          }
        : project,
  },
};

Map<String, Object?> _coverageEnvelope({Object? summary}) => {
  'data': {
    'project': {
      'id': 'gid://gitlab/Project/42',
      'codeCoverageSummary': summary,
    },
  },
};

final class _Absent {
  const _Absent();
}

void main() {
  test(
    'fixed pipeline query preserves exact endpoint, variables and auth',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_pipelineEnvelope()));
      final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
      addTearDown(api.close);
      final snapshot = await api.pipelineAnalytics(
        _project,
        ref: 'main',
        from: _from,
        to: _to,
        period: AnalyticsPeriod.week,
      );
      final bucket = snapshot.buckets.single;
      expect(bucket.label, DateTime.utc(2026, 10, 1));
      expect(bucket.total, BigInt.from(12));
      expect(bucket.successful, BigInt.zero);
      expect(bucket.failed, isNull);
      expect(bucket.other, BigInt.two);
      expect(bucket.p50Seconds, 1.25);
      expect(bucket.p95Seconds, 4.0);
      expect(snapshot.aggregate?.label, isNull);
      expect(snapshot.aggregate?.total, BigInt.from(12));
      expect(snapshot.aggregate?.successful, BigInt.from(7));
      expect(snapshot.aggregate?.failed, BigInt.from(3));
      expect(snapshot.aggregate?.other, BigInt.from(2));
      expect(snapshot.aggregate?.p50Seconds, 1.5);
      expect(snapshot.aggregate?.p95Seconds, 8.25);
      expect(() => snapshot.buckets.add(bucket), throwsUnsupportedError);

      final request = adapter.requests.single;
      expect(
        request.uri.toString(),
        'https://example.com:8443/gitlab/api/graphql',
      );
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer synthetic-test-token');
      expect(request.headers['PRIVATE-TOKEN'], isNull);
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect((request.data as Map)['variables'], {
        'path': _project.path,
        'ref': 'main',
        'fromTime': '2026-10-01T00:00:00.000Z',
        'toTime': '2026-10-03T00:00:00.000Z',
        'period': 'WEEK',
      });
      final query = (request.data as Map)['query'] as String;
      expect(query, startsWith('query MobilePipelineAnalytics'));
      expect(query, contains(r'$source: CiPipelineSources'));
      expect(query, contains(r'source: $source'));
      expect(query, contains('aggregate {'));
      expect(query, contains('all: count'));
      expect(query, contains('success: count(status: SUCCESS)'));
      expect(query, contains('durationStatistics { p50 p95 }'));
      expect(query, isNot(contains('mutation')));
    },
  );

  test('pipeline source enum is exact and any omits the variable', () async {
    expect(AnalyticsPipelineSource.values.map((value) => value.graphQLValue), [
      null,
      'UNKNOWN',
      'PUSH',
      'WEB',
      'TRIGGER',
      'SCHEDULE',
      'API',
      'EXTERNAL',
      'PIPELINE',
      'CHAT',
      'WEBIDE',
      'MERGE_REQUEST_EVENT',
      'EXTERNAL_PULL_REQUEST_EVENT',
      'PARENT_PIPELINE',
      'ONDEMAND_DAST_SCAN',
      'ONDEMAND_DAST_VALIDATION',
      'SECURITY_ORCHESTRATION_POLICY',
      'CONTAINER_REGISTRY_PUSH',
      'DUO_WORKFLOW',
      'PIPELINE_EXECUTION_POLICY_SCHEDULE',
      'DEPENDENCY_MANAGEMENT_SECURITY_UPDATE',
    ]);
    final adapter = FakeAdapter((_) => jsonResponse(_pipelineEnvelope()));
    final api = testApi(adapter);
    addTearDown(api.close);
    await api.pipelineAnalytics(_project, ref: 'main', from: _from, to: _to);
    await api.pipelineAnalytics(
      _project,
      ref: 'main',
      from: _from,
      to: _to,
      source: AnalyticsPipelineSource.schedule,
    );
    expect(
      (adapter.requests.first.data as Map)['variables'],
      isNot(contains('source')),
    );
    expect(
      (adapter.requests.last.data as Map)['variables'],
      containsPair('source', 'SCHEDULE'),
    );
  });

  test('nullable labels, counts and duration statistics remain null', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse(
        _pipelineEnvelope(
          analytics: {
            'timeSeries': [
              {
                'label': null,
                'all': null,
                'success': null,
                'failed': null,
                'other': null,
                'durationStatistics': null,
              },
            ],
          },
        ),
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final snapshot = await api.pipelineAnalytics(
      _project,
      ref: 'main',
      from: _from,
      to: _to,
    );
    final bucket = snapshot.buckets.single;
    expect(snapshot.aggregate, isNull);
    expect([
      bucket.label,
      bucket.total,
      bucket.successful,
      bucket.failed,
      bucket.other,
      bucket.p50Seconds,
      bucket.p95Seconds,
    ], everyElement(isNull));
  });

  test(
    'signed 64-bit counts are exact and overflow or floats fail closed',
    () async {
      final valid = FakeAdapter(
        (_) => jsonResponse(
          _pipelineEnvelope(
            analytics: {
              'timeSeries': [
                {
                  'label': '2026-10-01',
                  'all': '9223372036854775807',
                  'success': '0',
                  'failed': 1,
                  'other': 2,
                  'durationStatistics': {'p50': 0, 'p95': 0.5},
                },
              ],
            },
          ),
        ),
      );
      final validApi = testApi(valid);
      expect(
        (await validApi.pipelineAnalytics(
          _project,
          ref: 'main',
          from: _from,
          to: _to,
        )).buckets.single.total,
        BigInt.parse('9223372036854775807'),
      );
      validApi.close();

      for (final count in [
        '9223372036854775808',
        '-1',
        '+1',
        '01',
        '1' * 4096,
        1.5,
      ]) {
        final api = testApi(
          FakeAdapter(
            (_) => jsonResponse(
              _pipelineEnvelope(
                analytics: {
                  'timeSeries': [
                    {
                      'label': '2026-10-01',
                      'all': count,
                      'success': 0,
                      'failed': 0,
                      'other': 0,
                      'durationStatistics': null,
                    },
                  ],
                },
              ),
            ),
          ),
        );
        await expectLater(
          api.pipelineAnalytics(_project, ref: 'main', from: _from, to: _to),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }
    },
  );

  test('bad durations, labels and oversized result sets fail closed', () async {
    for (final analytics in <Object?>[
      {
        'timeSeries': [
          {
            'label': '2026-10-01',
            'all': 1,
            'success': 1,
            'failed': 0,
            'other': 0,
            'durationStatistics': {'p50': -1, 'p95': 2},
          },
        ],
      },
      {
        'timeSeries': [
          {
            'label': '2026-10-03',
            'all': 1,
            'success': 1,
            'failed': 0,
            'other': 0,
            'durationStatistics': null,
          },
        ],
      },
      {
        'timeSeries': [
          {
            'label': '2030-01-01',
            'all': 1,
            'success': 1,
            'failed': 0,
            'other': 0,
            'durationStatistics': {'p50': 1, 'p95': '2'},
          },
        ],
      },
      {'timeSeries': List.filled(401, const <String, Object?>{})},
      {'timeSeries': 'not-a-list'},
      {
        'aggregate': {
          'label': null,
          'all': '9223372036854775808',
          'success': 0,
          'failed': 0,
          'other': 0,
          'durationStatistics': null,
        },
        'timeSeries': const <Object?>[],
      },
    ]) {
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse(_pipelineEnvelope(analytics: analytics)),
        ),
      );
      await expectLater(
        api.pipelineAnalytics(_project, ref: 'main', from: _from, to: _to),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test('calendar period labels honor an exclusive timestamp end', () async {
    Future<PipelineAnalyticsBucket> load({
      required AnalyticsPeriod period,
      required DateTime from,
      required DateTime to,
      required String label,
    }) async {
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _pipelineEnvelope(
              analytics: {
                'timeSeries': [
                  {
                    'label': label,
                    'all': 1,
                    'success': 1,
                    'failed': 0,
                    'other': 0,
                    'durationStatistics': null,
                  },
                ],
              },
            ),
          ),
        ),
      );
      addTearDown(api.close);
      return (await api.pipelineAnalytics(
        _project,
        ref: 'main',
        from: from,
        to: to,
        period: period,
      )).buckets.single;
    }

    expect(
      (await load(
        period: AnalyticsPeriod.day,
        from: DateTime.utc(2026, 10, 1, 12),
        to: DateTime.utc(2026, 10, 2, 12),
        label: '2026-10-01',
      )).label,
      DateTime.utc(2026, 10, 1),
    );
    expect(
      (await load(
        period: AnalyticsPeriod.week,
        from: DateTime.utc(2026, 10, 1, 12),
        to: DateTime.utc(2026, 10, 8, 12),
        label: '2026-09-28',
      )).label,
      DateTime.utc(2026, 9, 28),
    );
    expect(
      (await load(
        period: AnalyticsPeriod.month,
        from: DateTime.utc(2026, 10, 15),
        to: DateTime.utc(2026, 11, 15),
        label: '2026-10-01',
      )).label,
      DateTime.utc(2026, 10, 1),
    );

    await expectLater(
      load(
        period: AnalyticsPeriod.day,
        from: DateTime.utc(2026, 10, 1, 12),
        to: DateTime.utc(2026, 10, 2),
        label: '2026-10-02',
      ),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test(
    'schema errors are unsupported and partial private errors are sanitized',
    () async {
      final payload = _pipelineEnvelope()
        ..['errors'] = [
          {
            'message': 'private schema details',
            'extensions': {'code': 'undefinedField'},
          },
        ];
      final api = testApi(FakeAdapter((_) => jsonResponse(payload)));
      try {
        await api.pipelineAnalytics(
          _project,
          ref: 'main',
          from: _from,
          to: _to,
        );
        fail('partial data must not succeed');
      } on ApiFailure catch (error) {
        expect(error.kind, FailureKind.unsupported);
        expect('${error.title} ${error.detail}', isNot(contains('private')));
      } finally {
        api.close();
      }
    },
  );

  test('unknown GraphQL errors and malformed envelopes are invalid', () async {
    for (final payload in <Object?>[
      {
        ..._pipelineEnvelope(),
        'errors': [
          {'message': 'private'},
        ],
      },
      {..._pipelineEnvelope(), 'errors': 'bad'},
      {'data': null},
      {'data': <Object?>[]},
    ]) {
      final api = testApi(FakeAdapter((_) => jsonResponse(payload)));
      await expectLater(
        api.pipelineAnalytics(_project, ref: 'main', from: _from, to: _to),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
  });

  test(
    'null project is invisible; null analytics is explicitly unsupported',
    () async {
      final forbidden = testApi(
        FakeAdapter((_) => jsonResponse(_pipelineEnvelope(project: null))),
      );
      await expectLater(
        forbidden.pipelineAnalytics(
          _project,
          ref: 'main',
          from: _from,
          to: _to,
        ),
        throwsA(_failure(FailureKind.invisible)),
      );
      forbidden.close();

      final unsupported = testApi(
        FakeAdapter(
          (_) => jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'pipelineAnalytics': null,
              },
            },
          }),
        ),
      );
      await expectLater(
        unsupported.pipelineAnalytics(
          _project,
          ref: 'main',
          from: _from,
          to: _to,
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );
      unsupported.close();
    },
  );

  test(
    'pipeline analytics rejects a different numeric project generation',
    () async {
      final payload = _pipelineEnvelope(
        project: {
          'id': 'gid://gitlab/Project/99',
          'pipelineAnalytics': {
            'aggregate': null,
            'timeSeries': const <Object?>[],
          },
        },
      );
      final api = testApi(FakeAdapter((_) => jsonResponse(payload)));
      await expectLater(
        api.pipelineAnalytics(_project, ref: 'main', from: _from, to: _to),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    },
  );

  test(
    'code coverage query is independent and preserves null values',
    () async {
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        final query = (request.data as Map)['query'] as String;
        expect(query, startsWith('query MobileCodeCoverageSummary'));
        return jsonResponse(
          _coverageEnvelope(
            summary: calls == 1
                ? {
                    'averageCoverage': 87.5,
                    'coverageCount': '0',
                    'lastUpdatedOn': '2026-10-02',
                  }
                : null,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final value = await api.codeCoverageSummary(_project);
      expect(value?.averageCoverage, 87.5);
      expect(value?.coverageCount, BigInt.zero);
      expect(value?.lastUpdatedOn, DateTime.utc(2026, 10, 2));
      expect(await api.codeCoverageSummary(_project), isNull);
      expect(adapter.requests, hasLength(2));
    },
  );

  test('coverage rejects invalid values and project identity', () async {
    for (final summary in <Object?>[
      {
        'averageCoverage': 100.1,
        'coverageCount': 1,
        'lastUpdatedOn': '2026-10-02',
      },
      {
        'averageCoverage': 'not-a-number',
        'coverageCount': 1,
        'lastUpdatedOn': '2026-10-02',
      },
      {
        'averageCoverage': 50,
        'coverageCount': '9223372036854775808',
        'lastUpdatedOn': 'bad',
      },
    ]) {
      final api = testApi(
        FakeAdapter((_) => jsonResponse(_coverageEnvelope(summary: summary))),
      );
      await expectLater(
        api.codeCoverageSummary(_project),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      api.close();
    }
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/99',
              'codeCoverageSummary': null,
            },
          },
        }),
      ),
    );
    await expectLater(
      api.codeCoverageSummary(_project),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
    api.close();
  });

  test('invalid analytics input makes no request', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_pipelineEnvelope()));
    final api = testApi(adapter);
    addTearDown(api.close);
    for (final ref in ['', ' main', 'main\rnext']) {
      await expectLater(
        api.pipelineAnalytics(_project, ref: ref, from: _from, to: _to),
        throwsA(_failure(FailureKind.validation)),
      );
    }
    await expectLater(
      api.pipelineAnalytics(_project, ref: 'main', from: _to, to: _from),
      throwsA(_failure(FailureKind.validation)),
    );
    await expectLater(
      api.pipelineAnalytics(
        _project,
        ref: 'main',
        from: DateTime.utc(2025, 1, 1),
        to: DateTime.utc(2026, 10, 1),
      ),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests, isEmpty);
  });

  test('closing account client rejects older GraphQL response', () async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => pending.future);
    final api = testApi(adapter);
    final operation = api.pipelineAnalytics(
      _project,
      ref: 'main',
      from: _from,
      to: _to,
    );
    await Future<void>.delayed(Duration.zero);
    api.close();
    pending.complete(jsonResponse(_pipelineEnvelope()));
    await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
  });
}
