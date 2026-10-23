import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  testWidgets(
    '§3.4 fixture branch tree README cache empty viewport 412x900 clock fixed completion settled: first open reads branch tree HEAD raw once each',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      expect(fixture.branchReads, 1, reason: 'GET branch');
      expect(fixture.treeReads, 1, reason: 'GET pinned tree');
      expect(fixture.readmeHeadReads, 1, reason: 'HEAD README bounds');
      expect(fixture.readmeRawReads, 1, reason: 'GET pinned README raw');
      final branchReq = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/branches/main',
      );
      expect(branchReq.uri.queryParameters, isEmpty);
      final treeReq = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/tree',
      );
      expect(treeReq.uri.queryParameters, equals({'ref': _RepositoryFixture.sha, 'path': '', 'per_page': '50'}));
      final headReq = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'HEAD' && r.uri.path == '/gitlab/api/v4/projects/42/repository/files/README.md',
      );
      expect(headReq.uri.queryParameters, equals({'ref': _RepositoryFixture.sha}));
      final rawReq = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/files/README.md/raw',
      );
      expect(rawReq.uri.queryParameters, equals({'ref': _RepositoryFixture.sha, 'lfs': 'false'}));
    },
  );

  testWidgets(
    '§3.4 fixture branch tree README cache warm viewport 412x900 clock +20s completion settled: second open reads 0 times',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      expect(fixture.branchReads, 1);
      expect(fixture.treeReads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 20));
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      expect(fixture.branchReads, 1);
      expect(fixture.treeReads, 1);
      expect(fixture.readmeHeadReads, 1);
      expect(fixture.readmeRawReads, 1);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.currentRef?.sha, _RepositoryFixture.sha);
      expect(state.stale, isFalse);
    },
  );

  testWidgets(
    '§3.4 fixture branch stale viewport 412x900 clock +61s completion background response: stale then one fresh background read',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      final pending = Completer<ResponseBody>();
      fixture.nextBranch = pending;
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await pumpUntil(tester, () => fixture.branchReads == 2);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.currentRef?.sha, _RepositoryFixture.sha);
      expect(state.stale, isTrue);
      expect(state.revalidating, isTrue);
      pending.complete(jsonResponse({'name': 'main', 'commit': {'id': _RepositoryFixture.sha}}));
      await settleWorkspace(tester);
      expect(state.stale, isFalse);
      expect(state.revalidating, isFalse);
      expect(fixture.branchReads, 2);
    },
  );

  testWidgets(
    '§3.4 fixture branch tree 403 cache warm viewport 412x900 clock +61s completion settled: tree 403 keeps branch and project context',
    (tester) async {
      final fixture = _RepositoryFixture()..treeStatus = 403;
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.currentRef, isNotNull);
      expect(state.loadError, isNull);
      expect(fixture.branchReads, 1);
    },
  );

  testWidgets(
    '§3.4 fixture branch 404 cache warm viewport 412x900 clock +61s completion settled: branch 404 withdraws ref but file view keeps pinned reads',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      fixture.branchStatus = 404;
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.currentRef, isNull);
      expect(state.loadError?.status, 404);
    },
  );

  testWidgets(
    '§3.4 fixture branch stale viewport offstage then resumed clock +61s completion background response: pauses and resumes',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      await tester.pumpWidget(
        workspaceHost(TickerMode(enabled: false, child: fixture.tab(key: const ValueKey('repo')))),
      );
      await pumpUntil(tester, () => tester.state<RepositoryTabState>(find.byType(RepositoryTab)).currentRef != null);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.stale, isTrue);
      expect(state.revalidating, isFalse);
      expect(fixture.branchReads, 1);
      await tester.pumpWidget(
        workspaceHost(TickerMode(enabled: true, child: fixture.tab(key: const ValueKey('repo')))),
      );
      await settleWorkspace(tester);
      expect(fixture.branchReads, 2);
      expect(state.stale, isFalse);
    },
  );

  testWidgets(
    '§3.4 fixture file pinned cache warm viewport 412x900 clock +20s completion settled: second open reads file 0 times',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.runAsync(() => fixture.api.cachedRecord(['projects', '42', 'repository', 'branches', 'main']));
      await tester.pumpWidget(workspaceHost(fixture.filePage()));
      await settleWorkspace(tester);
      expect(fixture.readmeRawReads, 1, reason: 'GET pinned file raw');
      final headAfterFirst = fixture.readmeHeadReads;
      expect(headAfterFirst, 2, reason: 'HEAD fileMetadata plus HEAD textFile bounds');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 20));
      await tester.pumpWidget(workspaceHost(fixture.filePage()));
      await settleWorkspace(tester);
      expect(fixture.readmeRawReads, 1, reason: 'pinned file raw warm reread sends 0 requests');
      expect(fixture.readmeHeadReads, headAfterFirst + 1, reason: 'HEAD fileMetadata always sends; textFile HEAD stays cached');
    },
  );

  testWidgets(
    '§3.4 fixture file cold dropped viewport 412x900 clock fixed completion retry notice: dropped cold read shows retry and recovers',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      var admitted = true;
      var refusals = 0;
      Future<T> fenced<T>(Future<T> Function() body) => CachedRead.run(
        body,
        mayStart: () {
          if (!admitted) refusals++;
          return admitted;
        },
      );
      await fenced(() async {
        admitted = false;
        await tester.pumpWidget(workspaceHost(fixture.filePage()));
        await settleWorkspace(tester);
        expect(refusals, greaterThan(0));
        expect(find.byType(FailureNotice), findsWidgets);
        admitted = true;
        final notices = tester.widgetList<FailureNotice>(find.byType(FailureNotice));
        expect(notices.any((n) => n.onRetry != null), isTrue);
        notices.firstWhere((n) => n.onRetry != null).onRetry!();
        await pumpUntil(tester, () => fixture.readmeRawReads >= 1);
        await settleWorkspace(tester);
      });
    },
  );
}

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final class _RepositoryFixture {
  _RepositoryFixture() {
    final dio = Dio()..httpClientAdapter = adapter;
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: dio,
      readCacheClock: () => now,
    );
    api.bindReadCache(account.key, 1);
  }
  static const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  var now = DateTime.utc(2026, 10, 23, 1);
  late final FakeAdapter adapter = FakeAdapter(_respond);
  late final GitLabApi api;
  int? branchStatus;
  int? treeStatus;
  Completer<ResponseBody>? nextBranch;
  int get branchReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/branches/main')
      .length;
  int get treeReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/tree')
      .length;
  int get readmeHeadReads => adapter.requests
      .where((r) => r.method == 'HEAD' && r.uri.path == '/gitlab/api/v4/projects/42/repository/files/README.md')
      .length;
  int get readmeRawReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/files/README.md/raw')
      .length;

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
  Widget tab({Key? key}) => RepositoryTab(key: key, account: account, api: api, project: project);
  Widget filePage() => RepositoryFilePage(
    account: account,
    api: api,
    project: project,
    branch: 'main',
    sha: sha,
    filePath: 'README.md',
  );
  void close() => api.close();

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final path = request.uri.path;
    final method = request.uri.path;
    if (path == '/gitlab/api/v4/projects/42/repository/branches/main') {
      final pending = nextBranch;
      nextBranch = null;
      if (pending != null) return pending.future;
      final status = branchStatus;
      if (status != null) return jsonResponse({}, status: status);
      return jsonResponse({'name': 'main', 'commit': {'id': sha}});
    }
    if (path == '/gitlab/api/v4/projects/42/repository/tree') {
      final status = treeStatus;
      if (status != null) return jsonResponse({}, status: status);
      return jsonResponse([
        {'id': '1', 'name': 'lib', 'path': 'lib', 'type': 'tree', 'mode': '040000'},
        {'id': '2', 'name': 'README.md', 'path': 'README.md', 'type': 'blob', 'mode': '100644'},
      ]);
    }
    if (path == '/gitlab/api/v4/projects/42/repository/files/README.md' && request.method == 'HEAD') {
      return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['80'], 'x-gitlab-last-commit-id': [sha]});
    }
    if (path == '/gitlab/api/v4/projects/42/repository/files/README.md/raw') {
      return ResponseBody.fromString('# Synthetic README', 200);
    }
    if (method.endsWith('/award_emoji')) return jsonResponse([]);
    return jsonResponse({}, status: 404);
  }
}
