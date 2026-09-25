import 'dart:async';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/ci_overview_page.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

class _TestAccountStore implements AccountStore {
  List<Account> accounts = [];
  String? lastActive;
  bool signOutPending = false;
  @override
  Future<List<Account>> load() async => accounts;
  @override
  Future<void> save(List<Account> value) async {
    accounts = List.of(value);
  }
  @override
  Future<String?> loadLastActive() async => lastActive;
  @override
  Future<void> saveLastActive(String? key) async {
    lastActive = key;
  }
  @override
  Future<bool> loadSignOutPending() async => signOutPending;
  @override
  Future<void> saveSignOutPending(bool pending) async {
    signOutPending = pending;
  }
}

void main() {
  test('poolMap respects concurrency limit = 4 and preserves item order', () async {
    final items = List.generate(10, (i) => i);
    var active = 0;
    var maxActive = 0;

    final results = await poolMap<int, String>(
      items,
      (item) async {
        active++;
        maxActive = max(maxActive, active);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        active--;
        return 'item-$item';
      },
      maxConcurrent: 4,
    );

    expect(maxActive, lessThanOrEqualTo(4));
    expect(maxActive, greaterThan(1));
    expect(results, List.generate(10, (i) => 'item-$i'));
  });

  testWidgets('CiOverviewPage queries member projects and latest pipelines with concurrency <= 4', (tester) async {
    var activePipelines = 0;
    var maxActivePipelines = 0;

    tester.view.physicalSize = const Size(800, 6000);
    addTearDown(tester.view.resetPhysicalSize);

    final api = testApi(FakeAdapter((request) async {
      if (request.uri.path.endsWith('/projects') && request.method == 'GET') {
        final list = List.generate(8, (i) => projectJson(i + 1));
        return jsonResponse(list);
      }
      final pipelineMatch = RegExp(r'/projects/(\d+)/pipelines').firstMatch(request.uri.path);
      if (pipelineMatch != null) {
        activePipelines++;
        maxActivePipelines = max(maxActivePipelines, activePipelines);
        final id = int.parse(pipelineMatch.group(1)!);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        activePipelines--;
        return jsonResponse([
          {
            'id': 100 + id,
            'status': id % 2 == 0 ? 'failed' : 'running',
            'ref': 'main',
            'sha': '1234567890abcdef',
            'updated_at': '2026-09-22T05:00:00Z',
          }
        ]);
      }
      return jsonResponse({}, status: 404);
    }));
    addTearDown(api.close);

    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'testuser', name: 'Test User'),
      token: 'tok',
    );

    await tester.pumpWidget(workspaceHost(CiOverviewPage(account: account, api: api)));
    await settleWorkspace(tester);

    expect(maxActivePipelines, lessThanOrEqualTo(4));
    expect(find.text('選擇專案，查看流程與工作紀錄'), findsOneWidget);
    for (var i = 1; i <= 8; i++) {
      expect(find.text('Example $i'), findsOneWidget);
    }
  });

  testWidgets('CiOverviewPage isolates per-project errors and highlights running and failed', (tester) async {
    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/projects') && request.method == 'GET') {
        return jsonResponse([
          projectJson(1), // running
          projectJson(2), // failed
          projectJson(3), // success
          projectJson(4), // 403 error
          projectJson(5), // no pipelines
        ]);
      }
      final pipelineMatch = RegExp(r'/projects/(\d+)/pipelines').firstMatch(request.uri.path);
      if (pipelineMatch != null) {
        final id = int.parse(pipelineMatch.group(1)!);
        if (id == 1) {
          return jsonResponse([{'id': 101, 'status': 'running', 'ref': 'feature', 'sha': 'aaa111', 'updated_at': '2026-09-22T05:00:00Z'}]);
        }
        if (id == 2) {
          return jsonResponse([{'id': 102, 'status': 'failed', 'ref': 'bugfix', 'sha': 'bbb222', 'updated_at': '2026-09-22T05:00:00Z'}]);
        }
        if (id == 3) {
          return jsonResponse([{'id': 103, 'status': 'success', 'ref': 'main', 'sha': 'ccc333', 'updated_at': '2026-09-22T05:00:00Z'}]);
        }
        if (id == 4) {
          return jsonResponse({'message': '403 Forbidden'}, status: 403);
        }
        if (id == 5) {
          return jsonResponse([]);
        }
      }
      return jsonResponse({}, status: 404);
    }));
    addTearDown(api.close);

    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'dev', name: 'Developer'),
      token: 'tok',
    );

    tester.view.physicalSize = const Size(800, 2400);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(workspaceHost(CiOverviewPage(account: account, api: api)));
    await settleWorkspace(tester);

    // Verify all 5 projects rendered without crash
    expect(find.text('Example 1'), findsOneWidget);
    expect(find.text('Example 2'), findsOneWidget);
    expect(find.text('Example 3'), findsOneWidget);
    expect(find.text('Example 4'), findsOneWidget);
    expect(find.text('Example 5'), findsOneWidget);

    // Verify statuses
    expect(find.text('執行中'), findsWidgets);
    expect(find.text('失敗'), findsWidgets);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('沒有 CI 權限'), findsOneWidget);
    expect(find.text('無 Pipeline'), findsOneWidget);

    // Test filter: running
    await tester.tap(find.widgetWithText(ChoiceChip, '執行中'));
    await tester.pumpAndSettle();
    expect(find.text('Example 1'), findsOneWidget);
    expect(find.text('Example 2'), findsNothing);
    expect(find.text('Example 3'), findsNothing);

    // Test filter: failed
    await tester.tap(find.widgetWithText(ChoiceChip, '失敗'));
    await tester.pumpAndSettle();
    expect(find.text('Example 1'), findsNothing);
    expect(find.text('Example 2'), findsOneWidget);
    expect(find.text('Example 3'), findsNothing);

    // Test filter: all
    await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
    await tester.pumpAndSettle();
    expect(find.text('Example 1'), findsOneWidget);
    expect(find.text('Example 2'), findsOneWidget);
    expect(find.text('Example 3'), findsOneWidget);

    // Test search filter
    await tester.enterText(find.byType(TextField), 'Example 3');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Card, 'Example 1'), findsNothing);
    expect(find.widgetWithText(Card, 'Example 3'), findsOneWidget);

    // Clear search
    await tester.tap(find.byTooltip('清除搜尋'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Card, 'Example 1'), findsOneWidget);
  });

  testWidgets('CiOverviewPage strictly binds to session.generation and account.key', (tester) async {
    final completer = Completer<ResponseBody>();
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/user')) {
        return jsonResponse({'id': 1, 'username': 'user1', 'name': 'User One'});
      }
      if (request.uri.path.endsWith('/projects')) {
        return completer.future;
      }
      return jsonResponse({});
    });

    final store = _TestAccountStore();
    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'user1', name: 'User One'),
      token: 'tok1',
    );
    store.accounts = [account];
    store.lastActive = account.key;

    final session = SessionController(
      store,
      createApi: (instance, credential, oauth, onOAuthRotated) =>
          testApi(adapter, host: instance.key),
    );
    await tester.runAsync(() async {
      await session.initialize();
    });
    expect(session.active, isNotNull);
    addTearDown(session.dispose);

    await tester.pumpWidget(workspaceHost(CiOverviewPage(session: session)));
    await tester.pump(); // Start loading

    // In-flight request is pending. Now bump generation by ending session / switching
    final oldGeneration = session.generation;
    await tester.runAsync(() async {
      await session.endSession();
    });
    expect(session.generation, greaterThan(oldGeneration));

    // Now complete the pending request with project data
    if (!completer.isCompleted) {
      completer.complete(jsonResponse([projectJson(99)]));
    }
    await settleWorkspace(tester);

    // The stale project data from the old generation must NOT be displayed
    expect(find.text('Example 99'), findsNothing);
  });

  testWidgets('CiOverviewPage tap navigates to PipelinePage when pipeline exists, and ProjectPage when none', (tester) async {
    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/projects') && request.method == 'GET') {
        return jsonResponse([projectJson(1), projectJson(2)]);
      }
      if (request.uri.path.endsWith('/projects/1/pipelines')) {
        return jsonResponse([{'id': 101, 'status': 'success', 'ref': 'main', 'sha': 'aaa', 'updated_at': '2026-09-22T05:00:00Z'}]);
      }
      if (request.uri.path.endsWith('/projects/2/pipelines')) {
        return jsonResponse([]);
      }
      if (request.uri.path.endsWith('/projects/1/pipelines/101')) {
        return jsonResponse({'id': 101, 'status': 'success', 'ref': 'main', 'sha': 'aaa', 'updated_at': '2026-09-22T05:00:00Z'});
      }
      if (request.uri.path.endsWith('/projects/1/pipelines/101/jobs')) {
        return jsonResponse([]);
      }
      if (request.uri.path.endsWith('/projects/2')) {
        return jsonResponse(projectJson(2));
      }
      return jsonResponse({}, status: 404);
    }));
    addTearDown(api.close);

    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'dev', name: 'Dev'),
      token: 'tok',
    );

    await tester.pumpWidget(workspaceHost(CiOverviewPage(account: account, api: api)));
    await settleWorkspace(tester);

    // Tap Example 1 (has pipeline 101) -> should push PipelinePage
    await tester.tap(find.text('Example 1'));
    await settleWorkspace(tester);
    expect(find.byType(PipelinePage), findsOneWidget);

    // Pop back
    Navigator.of(tester.element(find.byType(PipelinePage))).pop();
    await settleWorkspace(tester);
    expect(find.byType(PipelinePage), findsNothing);

    // Tap Example 2 (no pipeline) -> should push ProjectPage (CI tab)
    await tester.tap(find.text('Example 2'));
    await settleWorkspace(tester);
    expect(find.byType(ProjectPage), findsOneWidget);
  });

  testWidgets('CiOverviewPage displays failure notice on network error and allows retry', (tester) async {
    var failProjects = true;
    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/projects')) {
        if (failProjects) {
          return jsonResponse({'message': 'Server error'}, status: 500);
        }
        return jsonResponse([projectJson(42)]);
      }
      if (request.uri.path.endsWith('/projects/42/pipelines')) {
        return jsonResponse([{'id': 200, 'status': 'success', 'ref': 'main', 'sha': 'abc', 'updated_at': '2026-09-22T05:00:00Z'}]);
      }
      return jsonResponse({}, status: 404);
    }));
    addTearDown(api.close);

    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'dev', name: 'Dev'),
      token: 'tok',
    );

    await tester.pumpWidget(workspaceHost(CiOverviewPage(account: account, api: api)));
    await settleWorkspace(tester);

    // Failure notice displayed
    expect(find.byType(FailureNotice), findsOneWidget);

    // Now make it succeed on retry
    failProjects = false;
    await tester.tap(find.text('重新整理'));
    await settleWorkspace(tester);

    expect(find.byType(FailureNotice), findsNothing);
    expect(find.text('Example 42'), findsOneWidget);
  });

  testWidgets('CiOverviewPage renders ambiguous 404 text and tooltip conforming to AGENTS.md', (tester) async {
    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/projects')) {
        return jsonResponse([projectJson(99)]);
      }
      if (request.uri.path.endsWith('/projects/99/pipelines')) {
        return jsonResponse({'message': '404 Not Found'}, status: 404);
      }
      return jsonResponse({}, status: 404);
    }));
    addTearDown(api.close);

    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'dev', name: 'Dev'),
      token: 'tok',
    );

    await tester.pumpWidget(workspaceHost(CiOverviewPage(account: account, api: api)));
    await settleWorkspace(tester);

    final card = find.widgetWithText(Card, 'Example 99');
    expect(find.descendant(of: card, matching: find.text('無法存取或無 CI 資源')), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(
      find.descendant(of: card, matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, '目前無法取得 CI 資源，可能不存在或目前帳號無權存取');
  });

  testWidgets('CiOverviewPage supports pagination with load more button', (tester) async {
    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/projects')) {
        final pageNum = request.uri.queryParameters['page'];
        if (pageNum == null || pageNum == '1') {
          return jsonResponse(
            [projectJson(1)],
            headers: {
              'x-next-page': ['2'],
            },
          );
        } else {
          return jsonResponse([projectJson(2)]);
        }
      }
      if (request.uri.path.contains('/pipelines')) {
        return jsonResponse([]);
      }
      return jsonResponse({}, status: 404);
    }));
    addTearDown(api.close);

    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'dev', name: 'Dev'),
      token: 'tok',
    );

    await tester.pumpWidget(workspaceHost(CiOverviewPage(account: account, api: api)));
    await settleWorkspace(tester);

    expect(find.text('Example 1'), findsOneWidget);

    final loadMoreBtn = find.byKey(const ValueKey('ci-overview-load-more'));
    expect(loadMoreBtn, findsOneWidget);

    await tester.tap(loadMoreBtn);
    await settleWorkspace(tester);

    expect(find.text('Example 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('ci-overview-load-more')), findsNothing);
  });
}
