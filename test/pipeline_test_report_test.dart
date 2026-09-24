import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'support/fake_adapter.dart';

void main() {
  group('TestReportSummary Model', () {
    test('parses standard GitLab test report summary payload', () {
      final json = {
        'total': {
          'time': 61.1,
          'count': 9,
          'success': 8,
          'failed': 1,
          'skipped': 0,
          'error': 0,
          'suite_error': null,
        },
        'test_suites': [
          {
            'name': 'Secure',
            'total_time': 60.7,
            'total_count': 8,
            'success_count': 8,
            'failed_count': 0,
            'skipped_count': 0,
            'error_count': 0,
            'suite_error': null,
            'build_ids': [101, 102],
          },
          {
            'name': 'Backend',
            'total_time': 0.4,
            'total_count': 1,
            'success_count': 0,
            'failed_count': 1,
            'skipped_count': 0,
            'error_count': 0,
            'suite_error': null,
            'build_ids': [103],
          },
        ],
      };

      final summary = TestReportSummary.fromJson(json);
      expect(summary.totalTime, 61.1);
      expect(summary.totalCount, 9);
      expect(summary.successCount, 8);
      expect(summary.failedCount, 1);
      expect(summary.skippedCount, 0);
      expect(summary.errorCount, 0);
      expect(summary.suiteError, isNull);
      expect(summary.hasSuiteError, isFalse);
      expect(summary.isSuccess, isFalse);
      expect(summary.isFailed, isTrue);
      expect(summary.isEmpty, isFalse);
      expect(summary.status, TestReportStatus.failed);

      expect(summary.testSuites, hasLength(2));
      expect(summary.testSuites[0].name, 'Secure');
      expect(summary.testSuites[0].buildIds, [101, 102]);
      expect(summary.testSuites[1].name, 'Backend');
      expect(summary.testSuites[1].buildIds, [103]);
    });

    test('parses flat summary payload without total wrapper', () {
      final json = {
        'total_time': 12.5,
        'total_count': 5,
        'success_count': 5,
        'failed_count': 0,
        'skipped_count': 0,
        'error_count': 0,
        'suite_error': null,
        'test_suites': <dynamic>[],
      };

      final summary = TestReportSummary.fromJson(json);
      expect(summary.totalTime, 12.5);
      expect(summary.totalCount, 5);
      expect(summary.successCount, 5);
      expect(summary.isSuccess, isTrue);
      expect(summary.status, TestReportStatus.success);
    });

    test('identifies suite_error in total and in nested test_suites', () {
      final jsonTotalError = {
        'total': {
          'time': 0.0,
          'count': 1,
          'success': 0,
          'failed': 0,
          'skipped': 0,
          'error': 1,
          'suite_error': 'JUnit XML parser exception: unexpected EOF',
        },
        'test_suites': <dynamic>[],
      };

      final summaryTotalError = TestReportSummary.fromJson(jsonTotalError);
      expect(summaryTotalError.hasSuiteError, isTrue);
      expect(summaryTotalError.suiteError, 'JUnit XML parser exception: unexpected EOF');
      expect(summaryTotalError.status, TestReportStatus.suiteError);

      final jsonSuiteError = {
        'total': {
          'time': 1.0,
          'count': 1,
          'success': 1,
          'failed': 0,
          'skipped': 0,
          'error': 0,
        },
        'test_suites': [
          {
            'name': 'Corrupt Suite',
            'total_time': 1.0,
            'total_count': 1,
            'success_count': 1,
            'failed_count': 0,
            'skipped_count': 0,
            'error_count': 0,
            'suite_error': 'XML syntax error on line 42',
          },
        ],
      };

      final summarySuiteError = TestReportSummary.fromJson(jsonSuiteError);
      expect(summarySuiteError.hasSuiteError, isTrue);
      expect(summarySuiteError.status, TestReportStatus.suiteError);
      expect(summarySuiteError.isSuccess, isFalse);
    });

    test('empty report distinguishes noReport from success', () {
      final jsonEmpty = {
        'total': {
          'time': 0.0,
          'count': 0,
          'success': 0,
          'failed': 0,
          'skipped': 0,
          'error': 0,
          'suite_error': null,
        },
        'test_suites': <dynamic>[],
      };

      final summary = TestReportSummary.fromJson(jsonEmpty);
      expect(summary.isEmpty, isTrue);
      expect(summary.isSuccess, isFalse, reason: 'Empty report is NOT success');
      expect(summary.status, TestReportStatus.noReport);
    });
  });

  group('TestCase Model', () {
    test('parses test case fields and extracts job ID from various keys', () {
      final c1 = TestCase.fromJson({
        'status': 'failed',
        'name': 'testAddOrder',
        'classname': 'OrderServiceTest',
        'file': 'tests/order_service_test.dart',
        'execution_time': 0.125,
        'system_output': 'Server error: 500',
        'stack_trace': 'at OrderService.addOrder (order_service.dart:45)',
        'job_id': 881,
      });

      expect(c1.status, 'failed');
      expect(c1.isFailed, isTrue);
      expect(c1.isSuccess, isFalse);
      expect(c1.name, 'testAddOrder');
      expect(c1.classname, 'OrderServiceTest');
      expect(c1.file, 'tests/order_service_test.dart');
      expect(c1.executionTime, 0.125);
      expect(c1.systemOutput, 'Server error: 500');
      expect(c1.stackTrace, contains('OrderService.addOrder'));
      expect(c1.jobId, 881);

      final c2 = TestCase.fromJson({
        'status': 'success',
        'name': 'testFindOrder',
        'build_id': 882,
      });
      expect(c2.jobId, 882);
      expect(c2.isSuccess, isTrue);

      final c3 = TestCase.fromJson({
        'status': 'skipped',
        'name': 'testSlowJob',
        'job_url': 'https://gitlab.example.com/project/-/jobs/883',
      });
      expect(c3.jobId, 883);
      expect(c3.isSkipped, isTrue);

      final c4 = TestCase.fromJson({
        'status': 'success',
        'name': 'testDefaultJob',
      }, defaultJobId: 999);
      expect(c4.jobId, 999);
    });

    test('handles non-string system_output and stack_trace gracefully', () {
      final c = TestCase.fromJson({
        'status': 'failed',
        'name': 'testComplexPayload',
        'system_output': {'line': 1, 'text': 'Failure details'},
        'stack_trace': ['frame 1', 'frame 2'],
      });

      expect(c.systemOutput, contains('Failure details'));
      expect(c.stackTrace, contains('frame 1'));
    });

    test('normalizes non-standard statuses and distinguishes failed from error', () {
      final passedCase = TestCase.fromJson({'status': 'passed', 'name': 't1'});
      expect(passedCase.status, 'success');
      expect(passedCase.isSuccess, isTrue);
      expect(passedCase.isFailed, isFalse);
      expect(passedCase.isError, isFalse);

      final failureCase = TestCase.fromJson({'status': 'failure', 'name': 't2'});
      expect(failureCase.status, 'failed');
      expect(failureCase.isFailed, isTrue);
      expect(failureCase.isError, isFalse);
      expect(failureCase.isProblem, isTrue);

      final errorCase = TestCase.fromJson({'status': 'error', 'name': 't3'});
      expect(errorCase.status, 'error');
      expect(errorCase.isFailed, isFalse);
      expect(errorCase.isError, isTrue);
      expect(errorCase.isProblem, isTrue);

      final ignoredCase = TestCase.fromJson({'status': 'ignored', 'name': 't4'});
      expect(ignoredCase.status, 'skipped');
      expect(ignoredCase.isSkipped, isTrue);
    });

    test('falls back to job_url when job_id is invalid string or absent', () {
      final c1 = TestCase.fromJson({
        'status': 'failed',
        'name': 't_builds',
        'job_id': '',
        'job_url': 'https://gitlab.example.com/project/-/builds/777',
      });
      expect(c1.jobId, 777);

      final c2 = TestCase.fromJson({
        'status': 'failed',
        'name': 't_invalid_id',
        'job_id': 'not_a_number',
        'job_url': 'https://gitlab.example.com/project/-/jobs/888',
      });
      expect(c2.jobId, 888);
    });

    test('identity incorporates suiteName, classname, file, name, executionTime, and jobId', () {
      final c1 = TestCase.fromJson({
        'status': 'failed',
        'name': 'testSameName',
        'classname': 'OrderTest',
        'file': 'tests/order_test.dart',
        'execution_time': 0.1,
        'job_id': 100,
      }, suiteName: 'unit');

      final c2 = TestCase.fromJson({
        'status': 'failed',
        'name': 'testSameName',
        'classname': 'OrderTest',
        'file': 'tests/order_test.dart',
        'execution_time': 0.2,
        'job_id': 100,
      }, suiteName: 'unit');

      expect(c1.identity, isNot(equals(c2.identity)), reason: 'Different executionTime produces distinct identity');
      expect(c1.identity, contains('unit:OrderTest:tests/order_test.dart:testSameName:0.1:100'));
    });
  });

  group('TestSuite Model', () {
    test('parses single element build_ids when element is num or numeric string', () {
      final s1 = TestSuite.fromJson({
        'name': 'Suite Num',
        'total_time': 1.0,
        'total_count': 1,
        'success_count': 1,
        'failed_count': 0,
        'skipped_count': 0,
        'error_count': 0,
        'build_ids': [404.0],
        'test_cases': [
          {'status': 'success', 'name': 't1'},
        ],
      });
      expect(s1.testCases.first.jobId, 404);

      final s2 = TestSuite.fromJson({
        'name': 'Suite Str',
        'total_time': 1.0,
        'total_count': 1,
        'success_count': 1,
        'failed_count': 0,
        'skipped_count': 0,
        'error_count': 0,
        'build_ids': ['505'],
        'test_cases': [
          {'status': 'success', 'name': 't2'},
        ],
      });
      expect(s2.testCases.first.jobId, 505);
    });
  });

  group('PipelineTestReportPage Model', () {
    test('flattens test cases across suites and preserves pagination', () {
      final json = {
        'total_time': 5.0,
        'total_count': 2,
        'success_count': 1,
        'failed_count': 1,
        'skipped_count': 0,
        'error_count': 0,
        'test_suites': [
          {
            'name': 'Suite A',
            'total_time': 2.0,
            'total_count': 1,
            'success_count': 1,
            'failed_count': 0,
            'skipped_count': 0,
            'error_count': 0,
            'test_cases': [
              {'status': 'success', 'name': 'test_a', 'job_id': 1},
            ],
          },
          {
            'name': 'Suite B',
            'total_time': 3.0,
            'total_count': 1,
            'success_count': 0,
            'failed_count': 1,
            'skipped_count': 0,
            'error_count': 0,
            'test_cases': [
              {'status': 'failed', 'name': 'test_b', 'job_id': 2},
            ],
          },
        ],
      };

      final nextUri = Uri.parse('https://gitlab.example.com/api/v4/projects/42/pipelines/99/test_report?page=2&per_page=30');
      final page = PipelineTestReportPage.fromJson(json, next: nextUri);

      expect(page.totalCount, 2);
      expect(page.suites, hasLength(2));
      expect(page.testCases, hasLength(2));
      expect(page.testCases[0].suiteName, 'Suite A');
      expect(page.testCases[0].name, 'test_a');
      expect(page.testCases[1].suiteName, 'Suite B');
      expect(page.testCases[1].name, 'test_b');
      expect(page.next, nextUri);
    });
  });

  group('GitLabApi test_report_summary and test_report Contract', () {
    test('pipelineTestReportSummary fetches and parses summary successfully', () async {
      late RequestOptions seenRequest;
      final adapter = FakeAdapter((options) {
        seenRequest = options;
        return jsonResponse({
          'total': {
            'time': 10.0,
            'count': 3,
            'success': 2,
            'failed': 1,
            'skipped': 0,
            'error': 0,
            'suite_error': null,
          },
          'test_suites': [
            {
              'name': 'Unit',
              'total_time': 10.0,
              'total_count': 3,
              'success_count': 2,
              'failed_count': 1,
              'skipped_count': 0,
              'error_count': 0,
              'suite_error': null,
            },
          ],
        });
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      final summary = await api.pipelineTestReportSummary(42, 99);
      expect(summary.totalCount, 3);
      expect(summary.failedCount, 1);
      expect(seenRequest.uri.path, endsWith('/api/v4/projects/42/pipelines/99/test_report_summary'));
      expect(seenRequest.method, 'GET');
    });

    test('pipelineTestReportSummary throws invalidResponse on JSON array payload', () async {
      final adapter = FakeAdapter((options) {
        return jsonResponse([
          {'count': 1},
        ]);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      expect(
        () => api.pipelineTestReportSummary(42, 99),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.invalidResponse)),
      );
    });

    test('pipelineTestReportSummary throws invisible on 404', () async {
      final adapter = FakeAdapter((options) {
        return jsonResponse({'message': '404 Not Found'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      expect(
        () => api.pipelineTestReportSummary(42, 99),
        throwsA(isA<ApiFailure>().having((f) => f.status, 'status', 404)),
      );
    });

    test('pipelineTestReportSummary throws forbidden on 403', () async {
      final adapter = FakeAdapter((options) {
        return jsonResponse({'message': '403 Forbidden'}, status: 403);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      expect(
        () => api.pipelineTestReportSummary(42, 99),
        throwsA(isA<ApiFailure>().having((f) => f.status, 'status', 403)),
      );
    });

    test('pipelineTestReport handles pagination headers and loads page 1 and page 2', () async {
      final requests = <RequestOptions>[];
      final adapter = FakeAdapter((options) {
        requests.add(options);
        final page = int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
        if (page == 1) {
          return jsonResponse({
            'total_time': 20.0,
            'total_count': 4,
            'success_count': 4,
            'failed_count': 0,
            'skipped_count': 0,
            'error_count': 0,
            'test_suites': [
              {
                'name': 'Unit',
                'total_time': 10.0,
                'total_count': 2,
                'success_count': 2,
                'failed_count': 0,
                'skipped_count': 0,
                'error_count': 0,
                'test_cases': [
                  {'status': 'success', 'name': 'test1', 'job_id': 10},
                  {'status': 'success', 'name': 'test2', 'job_id': 10},
                ],
              },
            ],
          }, headers: {
            'x-next-page': ['2'],
          });
        } else {
          return jsonResponse({
            'total_time': 20.0,
            'total_count': 4,
            'success_count': 4,
            'failed_count': 0,
            'skipped_count': 0,
            'error_count': 0,
            'test_suites': [
              {
                'name': 'Unit',
                'total_time': 10.0,
                'total_count': 2,
                'success_count': 2,
                'failed_count': 0,
                'skipped_count': 0,
                'error_count': 0,
                'test_cases': [
                  {'status': 'success', 'name': 'test3', 'job_id': 11},
                  {'status': 'success', 'name': 'test4', 'job_id': 11},
                ],
              },
            ],
          });
        }
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      final page1 = await api.pipelineTestReport(42, 99, perPage: 2);
      expect(page1.testCases, hasLength(2));
      expect(page1.testCases[0].name, 'test1');
      expect(page1.next, isNotNull);
      expect(page1.next!.queryParameters['page'], '2');

      final page2 = await api.pipelineTestReport(42, 99, next: page1.next);
      expect(page2.testCases, hasLength(2));
      expect(page2.testCases[0].name, 'test3');
      expect(page2.next, isNull);

      expect(requests, hasLength(2));
      expect(requests[0].uri.queryParameters['per_page'], '2');
      expect(requests[1].uri.queryParameters['page'], '2');
    });

    test('pipelineTestReport rejects invalid continuation targets', () async {
      final adapter = FakeAdapter((options) => jsonResponse({}));
      final api = testApi(adapter);
      addTearDown(api.close);

      final foreignUri = Uri.parse('https://attacker.com/api/v4/projects/42/pipelines/99/test_report?page=2');
      expect(
        () => api.pipelineTestReport(42, 99, next: foreignUri),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.unsupported)),
      );

      final changedPath = Uri.parse('https://gitlab.example.com/api/v4/projects/42/pipelines/99/other?page=2');
      expect(
        () => api.pipelineTestReport(42, 99, next: changedPath),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.unsupported)),
      );
    });

    test('rate limited 429 response records retryAt and blocks subsequent immediate calls', () async {
      final adapter = FakeAdapter((options) {
        return jsonResponse(
          {'message': 'Rate limited'},
          status: 429,
          headers: {'retry-after': ['60']},
        );
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      try {
        await api.pipelineTestReportSummary(42, 99);
        fail('Expected 429 ApiFailure');
      } on ApiFailure catch (f) {
        expect(f.kind, FailureKind.rateLimited);
        expect(f.status, 429);
        expect(f.retryAt, isNotNull);
      }

      // Next immediate call must fail fast with rateLimited without making network request
      try {
        await api.pipelineTestReport(42, 99);
        fail('Expected immediate 429 ApiFailure');
      } on ApiFailure catch (f) {
        expect(f.kind, FailureKind.rateLimited);
        expect(f.status, 429);
      }
    });

    test('client cancellation throws ApiFailure.cancelled', () async {
      final adapter = FakeAdapter((options) {
        return jsonResponse({'total': {'count': 0}, 'test_suites': <dynamic>[]});
      });

      final api = testApi(adapter);
      api.close();

      expect(
        () => api.pipelineTestReportSummary(42, 99),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.cancelled)),
      );
    });
  });
}
