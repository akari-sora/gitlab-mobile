import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;

void main() {
  testWidgets('PipelinePage tests tab displays summary metrics and failure filter by default', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.testReportSummaryRecord = {
      'total': {
        'time': 45.2,
        'count': 100,
        'success': 90,
        'failed': 8,
        'skipped': 1,
        'error': 1,
        'suite_error': null,
      },
      'test_suites': [
        {
          'name': 'frontend',
          'total_time': 20.0,
          'total_count': 50,
          'success_count': 45,
          'failed_count': 5,
          'skipped_count': 0,
          'error_count': 0,
          'suite_error': null,
        },
      ],
    };

    fixture.testReportRecord = {
      'total_time': 45.2,
      'total_count': 100,
      'success_count': 90,
      'failed_count': 8,
      'skipped_count': 1,
      'error_count': 1,
      'test_suites': [
        {
          'name': 'frontend',
          'total_time': 20.0,
          'total_count': 3,
          'success_count': 1,
          'failed_count': 1,
          'skipped_count': 0,
          'error_count': 1,
          'suite_error': null,
          'test_cases': [
            {
              'status': 'failed',
              'name': 'testLoginFailure',
              'classname': 'AuthTest',
              'file': 'test/auth_test.dart',
              'execution_time': 0.12,
              'stack_trace': 'AssertionError: expected false to be true',
              'system_output': 'stdout: attempting login...',
              'job_id': 501,
            },
            {
              'status': 'error',
              'name': 'testNetworkCrash',
              'classname': 'NetworkTest',
              'file': 'test/network_test.dart',
              'execution_time': 0.05,
              'job_id': 501,
            },
            {
              'status': 'success',
              'name': 'testHappyPath',
              'classname': 'AppTest',
              'file': 'test/app_test.dart',
              'execution_time': 0.5,
              'job_id': 501,
            },
          ],
        },
      ],
    };

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    // Initial tab is '工作'
    expect(find.text('Flutter tests'), findsOneWidget);
    expect(find.text('測試'), findsOneWidget);

    // Switch to '測試' tab
    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    // Verify Summary metrics
    expect(find.text('總計 100'), findsOneWidget);
    expect(find.text('成功 90'), findsOneWidget);
    expect(find.text('失敗 8'), findsWidgets);
    expect(find.text('錯誤 1'), findsWidgets);
    expect(find.text('跳過 1'), findsWidgets);

    // Global summary vs loaded cases isolation check:
    // Global summary reports 100 cases, while loaded cases list has 3 cases.
    // The partial loading indicator must show 3 / 100
    expect(find.text('已載入 3 / 100 筆測試案例（部分載入）'), findsOneWidget);

    // Default filter when failed > 0 is '失敗'
    expect(find.text('testLoginFailure'), findsOneWidget);
    // Success test is hidden under failed filter
    expect(find.text('testHappyPath'), findsNothing);

    // Tap '全部 (100)' filter chip
    await tester.ensureVisible(find.text('全部 (100)'));
    await tester.tap(find.text('全部 (100)'));
    await settleWorkspace(tester);
    expect(find.text('testLoginFailure'), findsOneWidget);
    expect(find.text('testHappyPath'), findsOneWidget);

    // Tap '成功 (90)' filter chip
    await tester.ensureVisible(find.text('成功 (90)'));
    await tester.tap(find.text('成功 (90)'));
    await settleWorkspace(tester);
    expect(find.text('testLoginFailure'), findsNothing);
    expect(find.text('testHappyPath'), findsOneWidget);

    // Switch back to '失敗 (8)'
    await tester.ensureVisible(find.text('失敗 (8)'));
    await tester.tap(find.text('失敗 (8)'));
    await settleWorkspace(tester);
    expect(find.text('testLoginFailure'), findsOneWidget);

    // Verify collapsible stacktrace and system output
    expect(find.text('錯誤追蹤與輸出'), findsOneWidget);
    expect(find.textContaining('AssertionError'), findsNothing);

    // Tap to expand stacktrace
    await tester.tap(find.text('錯誤追蹤與輸出'));
    await settleWorkspace(tester);
    expect(find.textContaining('AssertionError: expected false to be true'), findsOneWidget);
    expect(find.textContaining('stdout: attempting login...'), findsOneWidget);

    // Tap to collapse stacktrace
    await tester.tap(find.text('錯誤追蹤與輸出'));
    await settleWorkspace(tester);
    expect(find.textContaining('AssertionError'), findsNothing);

    // Verify Job entry navigation
    expect(find.text('工作 #501'), findsWidgets);
    await tester.tap(find.text('工作 #501').first);
    await settleWorkspace(tester);

    // We should be in JobLogPage
    expect(find.text('Flutter tests'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    // Navigate back to PipelinePage
    await tester.tap(find.byType(BackButton));
    await settleWorkspace(tester);

    // Still in PipelinePage
    expect(find.text('Pipeline #99'), findsOneWidget);
  });

  testWidgets('Empty test report displays "無測試報告" and does not claim all tests passed', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.testReportSummaryRecord = {
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

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    expect(find.text('無測試報告'), findsOneWidget);
    expect(find.text('此 Pipeline 沒有回報任何測試案例。'), findsOneWidget);
    expect(find.text('總計 0'), findsNothing);
    expect(find.text('所有測試均已通過'), findsNothing);
  });

  testWidgets('404 test report summary on finished pipeline displays "無測試報告"', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    final adapter = FakeAdapter((options) {
      if (options.uri.path.endsWith('/test_report_summary')) {
        return jsonResponse({'message': '404 Not Found'}, status: 404);
      }
      return fixture.respond(options);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    expect(find.text('無測試報告'), findsOneWidget);
    expect(find.textContaining('尚未上傳 JUnit 測試報告'), findsOneWidget);
  });

  testWidgets('Running pipeline shows in-progress state when test report is not available', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    final adapter = FakeAdapter((options) {
      if (options.uri.path.endsWith('/pipelines/99') && options.method == 'GET') {
        return jsonResponse({...fixture.pipeline, 'status': 'running'});
      }
      if (options.uri.path.endsWith('/test_report_summary')) {
        return jsonResponse({'message': '404 Not Found'}, status: 404);
      }
      return fixture.respond(options);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    expect(find.text('測試進行中'), findsOneWidget);
    expect(find.text('Pipeline 正在執行，尚未產生完整測試報告。'), findsOneWidget);
  });

  testWidgets('Suite error displays warning banner in summary', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.testReportSummaryRecord = {
      'total': {
        'time': 1.0,
        'count': 1,
        'success': 1,
        'failed': 0,
        'skipped': 0,
        'error': 0,
        'suite_error': 'JUnit XML parser exception: unexpected token',
      },
      'test_suites': <dynamic>[],
    };

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    expect(find.textContaining('測試套件解析錯誤: JUnit XML parser exception: unexpected token'), findsOneWidget);
  });

  testWidgets('Rate limiting (429) displays rate limit notice with retry option', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    var return429 = true;
    final adapter = FakeAdapter((options) {
      if (options.uri.path.endsWith('/test_report_summary')) {
        if (return429) {
          return jsonResponse({'message': 'Rate limited'}, status: 429, headers: {'retry-after': ['0']});
        }
        return jsonResponse(fixture.testReportSummaryRecord ?? {
          'total': {'time': 1.0, 'count': 1, 'success': 1, 'failed': 0, 'skipped': 0, 'error': 0, 'suite_error': null},
          'test_suites': <dynamic>[],
        });
      }
      return fixture.respond(options);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    expect(find.text('稍後再試'), findsOneWidget);
    expect(find.textContaining('GitLab 正在限制請求'), findsOneWidget);

    // Let the retry-after expire and tap retry
    return429 = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('重新整理'));
    await settleWorkspace(tester);

    expect(find.text('總計 1'), findsOneWidget);
  });

  testWidgets('Pagination appends subsequent test cases on load more', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.testReportSummaryRecord = {
      'total': {
        'time': 10.0,
        'count': 4,
        'success': 4,
        'failed': 0,
        'skipped': 0,
        'error': 0,
        'suite_error': null,
      },
      'test_suites': <dynamic>[],
    };

    final adapter = FakeAdapter((options) {
      if (options.uri.path.endsWith('/test_report')) {
        final page = int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
        if (page == 1) {
          return jsonResponse({
            'total_time': 10.0,
            'total_count': 4,
            'success_count': 4,
            'failed_count': 0,
            'skipped_count': 0,
            'error_count': 0,
            'test_suites': [
              {
                'name': 'unit',
                'total_time': 5.0,
                'total_count': 2,
                'success_count': 2,
                'failed_count': 0,
                'skipped_count': 0,
                'error_count': 0,
                'test_cases': [
                  {'status': 'success', 'name': 'Case Alpha', 'job_id': 501},
                  {'status': 'success', 'name': 'Case Beta', 'job_id': 501},
                ],
              },
            ],
          }, headers: {
            'x-next-page': ['2'],
          });
        } else {
          return jsonResponse({
            'total_time': 10.0,
            'total_count': 4,
            'success_count': 4,
            'failed_count': 0,
            'skipped_count': 0,
            'error_count': 0,
            'test_suites': [
              {
                'name': 'unit',
                'total_time': 5.0,
                'total_count': 2,
                'success_count': 2,
                'failed_count': 0,
                'skipped_count': 0,
                'error_count': 0,
                'test_cases': [
                  {'status': 'success', 'name': 'Case Gamma', 'job_id': 501},
                  {'status': 'success', 'name': 'Case Delta', 'job_id': 501},
                ],
              },
            ],
          });
        }
      }
      return fixture.respond(options);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    expect(find.text('Case Alpha'), findsOneWidget);
    expect(find.text('Case Beta'), findsOneWidget);
    expect(find.text('Case Gamma'), findsNothing);

    // Tap "載入更多測試案例"
    expect(find.text('載入更多測試案例'), findsOneWidget);
    await tester.tap(find.text('載入更多測試案例'));
    await settleWorkspace(tester);

    expect(find.text('Case Alpha'), findsOneWidget);
    expect(find.text('Case Beta'), findsOneWidget);
    expect(find.text('Case Gamma'), findsOneWidget);
    expect(find.text('Case Delta'), findsOneWidget);
    expect(find.text('載入更多測試案例'), findsNothing);
  });

  testWidgets('Generation switch: slow generation 1 does not overwrite generation 2', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    final gen1Completer = Completer<ResponseBody>();
    var requestCount = 0;

    final adapter = FakeAdapter((options) {
      if (options.uri.path.endsWith('/test_report_summary')) {
        requestCount++;
        if (requestCount == 1) {
          return gen1Completer.future;
        } else {
          return jsonResponse({
            'total': {'time': 99.0, 'count': 999, 'success': 999, 'failed': 0, 'skipped': 0, 'error': 0, 'suite_error': null},
            'test_suites': <dynamic>[],
          });
        }
      }
      return fixture.respond(options);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await pumpPending(tester);

    // Generation 1 is waiting on gen1Completer.
    // Trigger refresh (starts generation 2).
    await tester.tap(find.byTooltip('重新整理'));
    await pumpPending(tester);

    // Generation 2 completed and shows 999
    expect(find.text('總計 999'), findsOneWidget);

    // Now resolve delayed Generation 1 with obsolete data (10)
    gen1Completer.complete(jsonResponse({
      'total': {'time': 1.0, 'count': 10, 'success': 10, 'failed': 0, 'skipped': 0, 'error': 0, 'suite_error': null},
      'test_suites': <dynamic>[],
    }));
    await settleWorkspace(tester);

    // State must NOT be overwritten by generation 1
    expect(find.text('總計 999'), findsOneWidget);
    expect(find.text('總計 10'), findsNothing);
  });

  testWidgets('Retried job identity isolation: retrying job from test report updates job button ID', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    var retried = false;
    fixture.testReportSummaryRecord = {
      'total': {
        'time': 10.0, 'count': 1, 'success': 0, 'failed': 1, 'skipped': 0, 'error': 0, 'suite_error': null,
      },
      'test_suites': <dynamic>[],
    };

    final adapter = FakeAdapter((options) {
      if (options.uri.path.endsWith('/jobs/501/retry') && options.method == 'POST') {
        retried = true;
        return jsonResponse(fixture.job(701, status: 'running'));
      }
      if (options.uri.path.endsWith('/jobs/701')) {
        return jsonResponse(fixture.job(701, status: 'running'));
      }
      if (options.uri.path.endsWith('/jobs/701/trace')) {
        return ResponseBody.fromString('Running retried job...\n', 200);
      }
      if (options.uri.path.endsWith('/test_report')) {
        return jsonResponse({
          'total_time': 10.0,
          'total_count': 1,
          'success_count': 0,
          'failed_count': 1,
          'skipped_count': 0,
          'error_count': 0,
          'test_suites': [
            {
              'name': 'unit',
              'total_time': 10.0,
              'total_count': 1,
              'success_count': 0,
              'failed_count': 1,
              'skipped_count': 0,
              'error_count': 0,
              'test_cases': [
                {
                  'status': 'failed',
                  'name': 'testAuthRetry',
                  'classname': 'AuthTest',
                  'job_id': retried ? 701 : 501,
                },
              ],
            },
          ],
        });
      }
      return fixture.respond(options);
    });

    final api = testApi(adapter);
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    // Initial test case has Job #501
    expect(find.text('工作 #501'), findsOneWidget);
    expect(find.text('工作 #701'), findsNothing);

    // Open Job 501
    await tester.tap(find.text('工作 #501'));
    await settleWorkspace(tester);
    expect(find.text('Flutter tests'), findsOneWidget);

    // Retry job
    await tester.tap(find.byTooltip('工作操作'));
    await settleWorkspace(tester);
    await tester.tap(find.text('重試工作').hitTestable());
    await settleWorkspace(tester);
    await tester.tap(find.widgetWithText(FilledButton, '確認').hitTestable());
    await settleWorkspace(tester);

    // Pop back to PipelinePage
    await tester.tap(find.byType(BackButton));
    await settleWorkspace(tester);

    // The test case card MUST now show Job #701, isolating new identity from retried job #501
    expect(find.text('工作 #701'), findsOneWidget);
    expect(find.text('工作 #501'), findsNothing);
  });

  testWidgets('Error filter is selected by default when failedCount == 0 and errorCount > 0', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.testReportSummaryRecord = {
      'total': {
        'time': 5.0,
        'count': 1,
        'success': 0,
        'failed': 0,
        'skipped': 0,
        'error': 1,
        'suite_error': null,
      },
      'test_suites': <dynamic>[],
    };

    fixture.testReportRecord = {
      'total_time': 5.0,
      'total_count': 1,
      'success_count': 0,
      'failed_count': 0,
      'skipped_count': 0,
      'error_count': 1,
      'test_suites': [
        {
          'name': 'unit',
          'total_time': 5.0,
          'total_count': 1,
          'success_count': 0,
          'failed_count': 0,
          'skipped_count': 0,
          'error_count': 1,
          'test_cases': [
            {
              'status': 'error',
              'name': 'testConfigParseError',
              'classname': 'ConfigTest',
              'job_id': 501,
            },
          ],
        },
      ],
    };

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    // '錯誤 (1)' chip must be visible and selected
    final errorChip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '錯誤 (1)'));
    expect(errorChip.selected, isTrue);
    expect(find.text('testConfigParseError'), findsOneWidget);
  });

  testWidgets('Narrow screen width 320dp with long classname and file does not overflow', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.testReportSummaryRecord = {
      'total': {
        'time': 1.0,
        'count': 1,
        'success': 0,
        'failed': 1,
        'skipped': 0,
        'error': 0,
        'suite_error': null,
      },
      'test_suites': <dynamic>[],
    };

    fixture.testReportRecord = {
      'total_time': 1.0,
      'total_count': 1,
      'success_count': 0,
      'failed_count': 1,
      'skipped_count': 0,
      'error_count': 0,
      'test_suites': [
        {
          'name': 'ExtremelyLongSuiteNameWithoutAnyWhitespaceToTestRenderWrapConstraints',
          'total_time': 1.0,
          'total_count': 1,
          'success_count': 0,
          'failed_count': 1,
          'skipped_count': 0,
          'error_count': 0,
          'test_cases': [
            {
              'status': 'failed',
              'name': 'testLongMetadata',
              'classname': 'com.enterprise.deeply.nested.module.submodule.LongClassNameWithoutWhitespaceTest',
              'file': 'tests/deeply/nested/directory/structure/that/has/no/spaces/long_test_filename.dart',
              'job_id': 501,
            },
          ],
        },
      ],
    };

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    // No overflow exception should be thrown
    expect(tester.takeException(), isNull);
    expect(find.text('testLongMetadata'), findsOneWidget);
  });

  testWidgets('Page 1 test_report load failure shows FailureNotice and retries successfully', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    var failReport = true;
    final adapter = FakeAdapter((options) {
      if (options.uri.path.endsWith('/test_report')) {
        if (failReport) {
          return jsonResponse({'message': 'Internal Server Error'}, status: 500);
        }
        return jsonResponse(fixture.testReportRecord ?? {
          'total_time': 1.0,
          'total_count': 1,
          'success_count': 1,
          'failed_count': 0,
          'skipped_count': 0,
          'error_count': 0,
          'test_suites': <dynamic>[],
        });
      }
      return fixture.respond(options);
    });

    final api = testApi(adapter);
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    // Page 1 failed, so FailureNotice is shown, but EmptyState('沒有符合...') is NOT shown
    expect(find.byType(FailureNotice), findsOneWidget);
    expect(find.textContaining('沒有符合'), findsNothing);

    // Now server recovers and user taps retry
    failReport = false;
    await tester.tap(find.text('重新整理'));
    await settleWorkspace(tester);

    // Cases now loaded
    expect(find.byType(FailureNotice), findsNothing);
    expect(find.text('總計 2'), findsOneWidget);
  });

  testWidgets('Multiple test cases with same name and classname are not dropped on page 1', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.testReportSummaryRecord = {
      'total': {
        'time': 2.0, 'count': 2, 'success': 0, 'failed': 2, 'skipped': 0, 'error': 0, 'suite_error': null,
      },
      'test_suites': <dynamic>[],
    };

    fixture.testReportRecord = {
      'total_time': 2.0,
      'total_count': 2,
      'success_count': 0,
      'failed_count': 2,
      'skipped_count': 0,
      'error_count': 0,
      'test_suites': [
        {
          'name': 'unit',
          'total_time': 2.0,
          'total_count': 2,
          'success_count': 0,
          'failed_count': 2,
          'skipped_count': 0,
          'error_count': 0,
          'test_cases': [
            {
              'status': 'failed',
              'name': 'testValidation',
              'classname': 'ValidationTest',
              'file': 'test/val_test.dart',
              'execution_time': 0.1,
              'job_id': 501,
            },
            {
              'status': 'failed',
              'name': 'testValidation',
              'classname': 'ValidationTest',
              'file': 'test/val_test.dart',
              'execution_time': 0.2,
              'job_id': 501,
            },
          ],
        },
      ],
    };

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      id: 99,
    )));
    await settleWorkspace(tester);

    await tester.tap(find.text('測試'));
    await settleWorkspace(tester);

    // Both test cases must be rendered (findsNWidgets(2))
    expect(find.text('testValidation'), findsNWidgets(2));
    // Since 2/2 cases are loaded and next is null, partial banner is not shown
    expect(find.textContaining('部分載入'), findsNothing);
  });
}

Future<void> pumpPending(WidgetTester tester) async {
  for (var cycle = 0; cycle < 12; cycle++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
  }
}

