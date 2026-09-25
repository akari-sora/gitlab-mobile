import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;

class _CiActionCardsFixture extends WorkspaceFixture {
  final Map<int, Json> customJobs = {
    501: {'id': 501, 'name': 'Unit tests', 'status': 'failed', 'stage': 'test', 'failure_reason': 'script_failure'},
    502: {'id': 502, 'name': 'Deploy staging', 'status': 'manual', 'stage': 'deploy'},
    503: {'id': 503, 'name': 'Integration tests', 'status': 'running', 'stage': 'test'},
    504: {'id': 504, 'name': 'Lint & format', 'status': 'success', 'stage': 'build'},
  };

  Map<int, Json> get pipelines => {
    99: {
      'id': 99,
      'name': 'CI Pipeline #99',
      'ref': 'main',
      'sha': WorkspaceFixture.sha,
      'status': 'failed',
      'updated_at': '2026-09-26T00:00:00Z',
      'duration': 120,
    }
  };

  final List<String> requestedActions = [];

  List<String> pathOf(RequestOptions r) =>
      r.uri.pathSegments.skip(r.uri.pathSegments.indexOf('v4') + 1).toList();

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = pathOf(request);
    final method = request.method;

    if (path.length >= 2 && path[0] == 'projects' && path[1] == '42') {
      final sub = path.skip(2).toList();
      if (sub.length == 2 && sub[0] == 'pipelines' && sub[1] == '99' && method == 'GET') {
        return jsonResponse(pipelines[99]!);
      }
      if (sub.length == 3 && sub[0] == 'pipelines' && sub[1] == '99' && method == 'POST') {
        final action = sub[2];
        requestedActions.add('pipeline:99:$action');
        pipelines[99]!['status'] = action == 'retry' ? 'running' : 'canceled';
        return jsonResponse(pipelines[99]!);
      }
      if (sub.length == 3 && sub[0] == 'pipelines' && sub[1] == '99' && sub[2] == 'jobs' && method == 'GET') {
        return jsonResponse(customJobs.values.toList());
      }
      if (sub.length == 3 && sub[0] == 'pipelines' && sub[1] == '99' && sub[2] == 'test_report_summary' && method == 'GET') {
        return jsonResponse({'total': {'time': 0, 'count': 0, 'success': 0, 'failed': 0, 'skipped': 0, 'error': 0}, 'test_suites': <Json>[]});
      }
      if (sub.length >= 2 && sub[0] == 'jobs') {
        final jobId = int.tryParse(sub[1]);
        if (jobId != null && customJobs.containsKey(jobId)) {
          final job = customJobs[jobId]!;
          if (sub.length == 2 && method == 'GET') {
            return jsonResponse(job);
          }
          if (sub.length == 3 && sub[2] == 'trace' && method == 'GET') {
            return ResponseBody.fromString('Log for job $jobId\n', 200);
          }
          if (sub.length == 3 && method == 'POST') {
            final action = sub[2];
            requestedActions.add('job:$jobId:$action');
            if (action == 'retry') {
              final newId = 701;
              customJobs[newId] = {...job, 'id': newId, 'status': 'pending'};
              return jsonResponse(customJobs[newId]!, status: 201);
            }
            if (action == 'play') {
              job['status'] = 'pending';
              return jsonResponse(job);
            }
            if (action == 'cancel') {
              job['status'] = 'canceled';
              return jsonResponse(job);
            }
          }
        }
      }
    }
    return super.respond(request);
  }
}

Future<void> _confirmDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final confirmBtn = find.widgetWithText(FilledButton, '確認');
  expect(confirmBtn, findsOneWidget);
  await tester.tap(confirmBtn);
  await settleWorkspace(tester);
}

void main() {
  group('CI Pipeline job list direct action buttons', () {
    testWidgets('PipelinePage shows direct action buttons for manual, failed, and running jobs', (tester) async {
      final f = _CiActionCardsFixture();
      addTearDown(f.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(PipelinePage(
        account: f.account,
        api: f.api,
        project: f.project,
        id: 99,
      )));
      await settleWorkspace(tester);

      // Verify Pipeline quick retry button in header when pipeline is failed
      final pipelineRetryBtn = find.byKey(const ValueKey('pipeline-quick-retry-btn'));
      expect(pipelineRetryBtn, findsOneWidget);
      await tester.tap(pipelineRetryBtn);
      await _confirmDialog(tester);
      expect(f.requestedActions, contains('pipeline:99:retry'));

      // Check job list direct action buttons
      // Manual job (502): play button
      final playBtn = find.byKey(const ValueKey('job-action-play-502'));
      expect(playBtn, findsOneWidget);
      await tester.tap(playBtn);
      await _confirmDialog(tester);
      expect(f.requestedActions, contains('job:502:play'));

      // Failed job (501): retry button
      final retryBtn = find.byKey(const ValueKey('job-action-retry-501'));
      expect(retryBtn, findsOneWidget);
      await tester.tap(retryBtn);
      await _confirmDialog(tester);
      expect(f.requestedActions, contains('job:501:retry'));

      // Running job (503): cancel button
      final cancelBtn = find.byKey(const ValueKey('job-action-cancel-503'));
      expect(cancelBtn, findsOneWidget);
      await tester.tap(cancelBtn);
      await _confirmDialog(tester);
      expect(f.requestedActions, contains('job:503:cancel'));

      // Success job (504): no action button
      expect(find.byKey(const ValueKey('job-action-play-504')), findsNothing);
      expect(find.byKey(const ValueKey('job-action-retry-504')), findsNothing);
      expect(find.byKey(const ValueKey('job-action-cancel-504')), findsNothing);
    });
  });

  group('JobLogPage status action cards', () {
    testWidgets('manual job renders prominent action card and triggers play on confirmation', (tester) async {
      final f = _CiActionCardsFixture();
      addTearDown(f.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: f.account,
        api: f.api,
        project: f.project,
        id: 502,
      )));
      await settleWorkspace(tester);

      // Card is present
      expect(find.byKey(const ValueKey('job-banner-card-502')), findsOneWidget);
      expect(find.text('手動工作等待啟動'), findsOneWidget);

      final playBtn = find.byKey(const ValueKey('job-banner-play-502'));
      expect(playBtn, findsOneWidget);
      await tester.tap(playBtn);
      await _confirmDialog(tester);

      expect(f.requestedActions, contains('job:502:play'));
      expect(f.customJobs[502]!['status'], 'pending');
    });

    testWidgets('failed job renders retry action card with failure reason', (tester) async {
      final f = _CiActionCardsFixture();
      addTearDown(f.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: f.account,
        api: f.api,
        project: f.project,
        id: 501,
      )));
      await settleWorkspace(tester);

      // Card is present
      expect(find.byKey(const ValueKey('job-banner-card-501')), findsOneWidget);
      expect(find.text('工作執行失敗'), findsOneWidget);
      expect(find.text('原因：script_failure'), findsOneWidget);

      final retryBtn = find.byKey(const ValueKey('job-banner-retry-501'));
      expect(retryBtn, findsOneWidget);
      await tester.tap(retryBtn);
      await _confirmDialog(tester);

      expect(f.requestedActions, contains('job:501:retry'));
    });

    testWidgets('running job renders cancel action card and cancels on confirmation', (tester) async {
      final f = _CiActionCardsFixture();
      addTearDown(f.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: f.account,
        api: f.api,
        project: f.project,
        id: 503,
      )));
      await settleWorkspace(tester);

      // Card is present
      expect(find.byKey(const ValueKey('job-banner-card-503')), findsOneWidget);
      expect(find.text('工作執行中...'), findsOneWidget);

      final cancelBtn = find.byKey(const ValueKey('job-banner-cancel-503'));
      expect(cancelBtn, findsOneWidget);
      await tester.tap(cancelBtn);
      await _confirmDialog(tester);

      expect(f.requestedActions, contains('job:503:cancel'));
      expect(f.customJobs[503]!['status'], 'canceled');
    });
  });
}
