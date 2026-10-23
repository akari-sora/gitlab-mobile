import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  testWidgets(
    '§3.4 fixture running job cache uncached viewport 412x900 clock 10s then budget transitions completion each timer: cadence rearms normal 10 low 30 critical 60',
    (tester) async {
      final fixture = _PollingFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.traceReads, 1);

      await tester.tap(find.byType(FilterChip).first);
      await tester.pump();
      final state = tester.state<JobLogPageState>(find.byType(JobLogPage));
      expect(state.pollingInterval, const Duration(seconds: 10));
      expect(find.text(l10n.refreshEveryTenSeconds), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(fixture.traceReads, 1);
      await _pumpUntilTrace(tester, fixture, const Duration(seconds: 1), 2);
      expect(fixture.traceReads, 2);

      fixture.setBudget(remaining: 10);
      await tester.pump();
      expect(fixture.budget.snapshot().level, RateLevel.low);
      expect(state.pollingInterval, const Duration(seconds: 30));
      // The chip names the slower cadence, not the normal 10 s.
      expect(find.text(l10n.refreshEveryThirtySeconds), findsOneWidget);
      expect(find.text(l10n.refreshEveryTenSeconds), findsNothing);
      await tester.pump(const Duration(seconds: 29));
      expect(fixture.traceReads, 2);
      await _pumpUntilTrace(tester, fixture, const Duration(seconds: 1), 3);
      expect(fixture.traceReads, 3);

      fixture.setBudget(remaining: 0);
      await tester.pump();
      expect(fixture.budget.snapshot().level, RateLevel.critical);
      expect(state.pollingInterval, const Duration(seconds: 60));
      expect(find.text(l10n.refreshEveryMinute), findsOneWidget);
      await tester.pump(const Duration(seconds: 59));
      expect(fixture.traceReads, 3);
      await _pumpUntilTrace(tester, fixture, const Duration(seconds: 1), 4);
      expect(fixture.traceReads, 4);
      expect(fixture.jobReads, 4);
      // Dispose the reset timer before the binding checks pending timers.
      fixture.close();
    },
  );

  testWidgets(
    '§3.4 fixture running job cache uncached viewport offstage clock +70s completion pumped: polling pauses and resumes from full cadence',
    (tester) async {
      final fixture = _PollingFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        workspaceHost(
          TickerMode(
            enabled: true,
            child: fixture.page(key: const ValueKey('polling-page')),
          ),
        ),
      );
      await settleWorkspace(tester);
      await tester.tap(find.byType(FilterChip).first);
      await tester.pump();
      final state = tester.state<JobLogPageState>(find.byType(JobLogPage));
      expect(
        tester.widget<FilterChip>(find.byType(FilterChip).first).selected,
        isTrue,
      );

      await tester.pumpWidget(
        workspaceHost(
          TickerMode(
            enabled: false,
            child: fixture.page(key: const ValueKey('polling-page')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 70));
      expect(fixture.traceReads, 1);
      expect(
        tester.state<JobLogPageState>(find.byType(JobLogPage)),
        same(state),
      );
      expect(
        tester.widget<FilterChip>(find.byType(FilterChip).first).selected,
        isTrue,
      );

      await tester.pumpWidget(
        workspaceHost(
          TickerMode(
            enabled: true,
            child: fixture.page(key: const ValueKey('polling-page')),
          ),
        ),
      );
      await tester.pump();
      expect(tester.binding.lifecycleState, AppLifecycleState.resumed);
      expect(
        tester.state<JobLogPageState>(find.byType(JobLogPage)),
        same(state),
      );
      expect(
        tester.widget<FilterChip>(find.byType(FilterChip).first).selected,
        isTrue,
      );
      await tester.pump(const Duration(seconds: 9));
      expect(fixture.traceReads, 1);
      await _pumpUntilTrace(tester, fixture, const Duration(seconds: 1), 2);
      expect(fixture.traceReads, 2);
    },
  );
}

Future<void> _pumpUntilTrace(
  WidgetTester tester,
  _PollingFixture fixture,
  Duration duration,
  int expected,
) async {
  await tester.pump(duration);
  await pumpUntil(tester, () => fixture.traceReads >= expected);
  await settleNetworkWidgets(tester);
  expect(fixture.traceReads, expected);
}

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final class _PollingFixture {
  _PollingFixture() {
    final dio = Dio()..httpClientAdapter = adapter;
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: dio,
      rateBudget: budget,
    );
  }

  final DateTime now = DateTime.utc(2026, 10, 23, 1);
  late final GitLabRateBudget budget = GitLabRateBudget(now: () => now);
  late final FakeAdapter adapter = FakeAdapter(_respond);
  late final GitLabApi api;
  int jobReads = 0;
  int traceReads = 0;
  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
    token: 'synthetic-test-token',
  );
  Project get project => Project.fromJson(const {
    'id': 42,
    'name': 'Mobile Workspace',
    'path_with_namespace': 'studio/mobile-workspace',
    'visibility': 'private',
    'default_branch': 'main',
    'archived': false,
  });
  JobLogPage page({Key? key}) => JobLogPage(
    key: key,
    account: account,
    api: api,
    project: project,
    id: 501,
  );
  void close() => api.close();
  void setBudget({required int remaining}) {
    budget.noteResponse(
      headers: {
        'date': [HttpDate.format(now)],
        'ratelimit-limit': ['100'],
        'ratelimit-remaining': ['$remaining'],
        'ratelimit-reset': [
          '${now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000}',
        ],
      },
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: budget.nextSequence(),
      trusted: true,
    );
  }

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    if (request.uri.path.endsWith('/projects/42/jobs/501/trace')) {
      traceReads++;
      return ResponseBody.fromString('line $traceReads\n', 200);
    }
    if (request.uri.path.endsWith('/projects/42/jobs/501')) {
      jobReads++;
      return jsonResponse({
        'id': 501,
        'name': 'test',
        'status': 'running',
        'stage': 'test',
        'ref': 'main',
        'pipeline': {'id': 99, 'iid': 7, 'project_id': 42},
      });
    }
    return jsonResponse({}, status: 404);
  }
}
