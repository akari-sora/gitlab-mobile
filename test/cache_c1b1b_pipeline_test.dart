import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/cache_freshness.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  testWidgets(
    '§3.4 fixture pipeline with no jobs or test cases cache warm viewport 412x900 clock +5s completion both tabs settled: second open reads each endpoint 0 times',
    (tester) async {
      final fixture = _PipelineCacheFixture();
      addTearDown(fixture.close);
      _viewport(tester);

      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.pipelineReads, 1);
      expect(fixture.jobsReads, 1);
      expect(fixture.testSummaryReads, 0);
      await _openTestsTab(tester);
      expect(fixture.testSummaryReads, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      await _openTestsTab(tester);

      expect(fixture.pipelineReads, 1);
      expect(fixture.jobsReads, 1);
      expect(fixture.testSummaryReads, 1);
      final state = tester.state<PipelinePageState>(find.byType(PipelinePage));
      expect(state.fetchedAt, isNotNull);
      expect(state.stale, isFalse);
      expect(state.revalidating, isFalse);
    },
  );

  testWidgets(
    '§3.4 fixture pipeline with no jobs or test cases cache warm viewport 412x900 clock +5s completion explicit refresh: metadata jobs and summary each read fresh',
    (tester) async {
      final fixture = _PipelineCacheFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      await _openTestsTab(tester);
      expect(fixture.pipelineReads, 1);
      expect(fixture.jobsReads, 1);
      expect(fixture.testSummaryReads, 1);
      fixture.now = fixture.now.add(const Duration(seconds: 5));

      await tester.tap(find.byIcon(Icons.refresh));
      await settleWorkspace(tester);
      expect(fixture.pipelineReads, 2);
      expect(fixture.jobsReads, 2);
      expect(fixture.testSummaryReads, 2);

      await tester.tap(find.byType(Tab).first);
      await settleWorkspace(tester);
      expect(fixture.pipelineReads, 2);
      expect(fixture.jobsReads, 2);
      expect(fixture.testSummaryReads, 2);
    },
  );

  testWidgets(
    '§3.4 fixture pipeline changes status cache stale viewport 412x900 clock +31s completion background response: stale then one fresh background read',
    (tester) async {
      final fixture = _PipelineCacheFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      fixture.now = fixture.now.add(const Duration(seconds: 31));
      final pending = Completer<ResponseBody>();
      fixture.nextPipeline = pending;
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await pumpUntil(tester, () => fixture.pipelineReads == 2);

      final state = tester.state<PipelinePageState>(find.byType(PipelinePage));
      expect(state.data?['status'], 'success');
      expect(state.stale, isTrue);
      expect(state.revalidating, isTrue);
      expect(fixture.pipelineReads, 2);

      pending.complete(jsonResponse(fixture.pipeline(status: 'failed')));
      await settleWorkspace(tester);
      expect(state.data?['status'], 'failed');
      expect(state.stale, isFalse);
      expect(state.revalidating, isFalse);
      expect(fixture.pipelineReads, 2);
    },
  );

  testWidgets(
    '§3.4 fixture pipeline cache stale viewport 412x900 clock +31s completion old background after explicit refresh: newer foreground wins',
    (tester) async {
      final fixture = _PipelineCacheFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      fixture.now = fixture.now.add(const Duration(seconds: 31));
      final oldBackground = Completer<ResponseBody>();
      fixture.nextPipeline = oldBackground;
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await pumpUntil(tester, () => fixture.pipelineReads == 2);
      final state = tester.state<PipelinePageState>(find.byType(PipelinePage));
      expect(state.revalidating, isTrue);

      fixture.pipelineStatus = 'running';
      await tester.tap(find.byIcon(Icons.refresh));
      await pumpUntil(
        tester,
        () => fixture.pipelineReads == 3 && state.data?['status'] == 'running',
      );
      expect(state.data?['status'], 'running');
      expect(state.revalidating, isFalse);

      oldBackground.complete(jsonResponse(fixture.pipeline(status: 'failed')));
      await settleNetworkWidgets(tester);
      expect(state.data?['status'], 'running');
      expect(fixture.pipelineReads, 3);
    },
  );

  for (final failure in [
    (500, false, FailureKind.server, false),
    (429, false, FailureKind.rateLimited, true),
    (401, true, FailureKind.unauthenticated, false),
    (403, true, FailureKind.forbidden, false),
    (404, true, FailureKind.invisible, false),
  ]) {
    testWidgets(
      '§3.4 fixture pipeline cache stale viewport 412x900 clock +31s completion ${failure.$1}: revoked withdraws=${failure.$2}',
      (tester) async {
        final fixture = _PipelineCacheFixture();
        addTearDown(fixture.close);
        _viewport(tester);
        await tester.pumpWidget(workspaceHost(fixture.page()));
        await settleWorkspace(tester);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        fixture.now = fixture.now.add(const Duration(seconds: 31));
        fixture.pipelineFailureStatus = failure.$1;
        await tester.pumpWidget(workspaceHost(fixture.page()));
        await settleWorkspace(tester);

        final state = tester.state<PipelinePageState>(
          find.byType(PipelinePage),
        );
        expect(state.data == null, failure.$2);
        expect(state.error?.kind, failure.$2 ? failure.$3 : null);
        expect(state.backgroundFailure, failure.$2 ? null : failure.$3);
        expect(state.backgroundRetryAt != null, failure.$4);
        expect(state.revalidating, isFalse);
        expect(fixture.pipelineReads, 2);
        // Kept metadata says the refresh failed; withdrawn metadata has none.
        final strip = find.descendant(
          of: find.byType(PipelinePage),
          matching: find.byType(CacheFreshnessBar),
        );
        expect(strip, failure.$2 ? findsNothing : findsWidgets);
        if (failure.$3 == FailureKind.rateLimited) {
          expect(find.text(l10n.cacheRateLimited), findsWidgets);
        } else if (!failure.$2) {
          expect(find.text(l10n.cacheRefreshFailed), findsWidgets);
        }
        // Dispose the cooldown timer before the binding checks pending timers.
        fixture.close();
      },
    );
  }

  testWidgets(
    '§3.4 fixture pipeline cache stale viewport 412x900 clock +31s completion network error: cached value retained',
    (tester) async {
      final fixture = _PipelineCacheFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 31));
      fixture.pipelineNetworkFailure = true;

      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      final state = tester.state<PipelinePageState>(find.byType(PipelinePage));
      expect(state.data?['status'], 'success');
      expect(state.error, isNull);
      expect(state.backgroundFailure, FailureKind.network);
      expect(state.revalidating, isFalse);
      expect(fixture.pipelineReads, 2);
      // The header data is old and the refresh could not connect: say so,
      // with a refresh that reads fresh.
      expect(find.text(l10n.cannotConnect), findsWidgets);
      fixture.pipelineNetworkFailure = false;
      await tester.tap(find.widgetWithText(TextButton, l10n.refreshAction).first);
      await settleWorkspace(tester);
      expect(fixture.pipelineReads, 3);
      expect(state.backgroundFailure, isNull);
    },
  );

  testWidgets(
    '§3.4 fixture pipeline cache stale viewport offstage then resumed clock +31s completion background response: pauses and resumes',
    (tester) async {
      final fixture = _PipelineCacheFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 31));

      await tester.pumpWidget(
        workspaceHost(
          TickerMode(
            enabled: false,
            child: fixture.page(key: const ValueKey('pipeline-page')),
          ),
        ),
      );
      await pumpUntil(
        tester,
        () =>
            tester.state<PipelinePageState>(find.byType(PipelinePage)).data !=
            null,
      );

      final state = tester.state<PipelinePageState>(find.byType(PipelinePage));
      expect(state.data?['status'], 'success');
      expect(state.stale, isTrue);
      expect(state.revalidating, isFalse);
      expect(fixture.pipelineReads, 1);

      final pending = Completer<ResponseBody>();
      fixture.nextPipeline = pending;
      await tester.pumpWidget(
        workspaceHost(
          TickerMode(
            enabled: true,
            child: fixture.page(key: const ValueKey('pipeline-page')),
          ),
        ),
      );
      await pumpUntil(tester, () => fixture.pipelineReads == 2);
      expect(state.revalidating, isTrue);
      pending.complete(jsonResponse(fixture.pipeline(status: 'running')));
      await settleWorkspace(tester);
      expect(state.data?['status'], 'running');
      expect(state.stale, isFalse);
      expect(state.revalidating, isFalse);
    },
  );
}

Future<void> _openTestsTab(WidgetTester tester) async {
  // TabBarView creates the summary lazily, only after the user visits its tab.
  await tester.tap(find.byType(Tab).last);
  await settleWorkspace(tester);
}

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final class _PipelineCacheFixture {
  _PipelineCacheFixture() {
    final dio = Dio()..httpClientAdapter = adapter;
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: dio,
      readCacheClock: () => now,
    );
    api.bindReadCache(account.key, 1);
  }

  DateTime now = DateTime.utc(2026, 10, 23, 1);
  late final FakeAdapter adapter = FakeAdapter(_respond);
  late final GitLabApi api;
  int pipelineReads = 0;
  int jobsReads = 0;
  int testSummaryReads = 0;
  String pipelineStatus = 'success';
  int? pipelineFailureStatus;
  bool pipelineNetworkFailure = false;
  Completer<ResponseBody>? nextPipeline;
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
  Json pipeline({String status = 'success'}) => {
    'id': 99,
    'iid': 7,
    'status': status,
    'ref': 'main',
    'sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'source': 'push',
  };
  PipelinePage page({Key? key}) => PipelinePage(
    key: key,
    account: account,
    api: api,
    project: project,
    id: 99,
  );
  void close() => api.close();

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final path = request.uri.path;
    if (path.endsWith('/projects/42/pipelines/99')) {
      pipelineReads++;
      final pending = nextPipeline;
      nextPipeline = null;
      if (pending != null) return pending.future;
      if (pipelineNetworkFailure) {
        pipelineNetworkFailure = false;
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
          error: const SocketException('synthetic offline'),
        );
      }
      final status = pipelineFailureStatus;
      pipelineFailureStatus = null;
      if (status != null) {
        return jsonResponse(
          {},
          status: status,
          headers: status == 429
              ? {
                  'retry-after': ['60'],
                }
              : const {},
        );
      }
      return jsonResponse(pipeline(status: pipelineStatus));
    }
    if (path.endsWith('/projects/42/pipelines/99/jobs')) {
      jobsReads++;
      return jsonResponse([]);
    }
    if (path.endsWith('/projects/42/pipelines/99/test_report_summary')) {
      testSummaryReads++;
      return jsonResponse({
        'total': {
          'count': 0,
          'success': 0,
          'failed': 0,
          'skipped': 0,
          'error': 0,
          'time': 0,
        },
      });
    }
    return jsonResponse({}, status: 404);
  }
}
