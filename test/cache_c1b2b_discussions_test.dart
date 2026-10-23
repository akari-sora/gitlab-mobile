import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/discussions_tab.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  testWidgets(
    '§3.4 fixture one discussion cache empty viewport 412x900 clock fixed completion settled: first page reads once with exact URI',
    (tester) async {
      final fixture = _DiscussionsFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.host()));
      await settleWorkspace(tester);
      expect(fixture.discussionsReads, 1);
      final req = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'GET' && r.uri.path.endsWith('/discussions'),
      );
      expect(req.method, 'GET');
      expect(req.uri.path, '/gitlab/api/v4/projects/42/issues/1/discussions');
      expect(req.uri.queryParameters, equals({'per_page': '30'}));
      expect(find.textContaining('First comment', findRichText: true), findsOneWidget);
    },
  );

  testWidgets(
    '§3.4 fixture one discussion cache warm viewport 412x900 clock +5s completion settled: second open reads 0 times',
    (tester) async {
      final fixture = _DiscussionsFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.host()));
      await settleWorkspace(tester);
      expect(fixture.discussionsReads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await tester.pumpWidget(workspaceHost(fixture.host()));
      await settleWorkspace(tester);
      expect(fixture.discussionsReads, 1);
      expect(find.textContaining('First comment', findRichText: true), findsOneWidget);
    },
  );

  testWidgets(
    '§3.4 fixture one discussion cache warm viewport 412x900 clock +5s completion explicit refresh: exactly one fresh read',
    (tester) async {
      final fixture = _DiscussionsFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.host()));
      await settleWorkspace(tester);
      expect(fixture.discussionsReads, 1);
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await tester.runAsync(() => tester.state<RecordsFeedState>(find.byType(RecordsFeed)).refresh());
      await settleWorkspace(tester);
      expect(fixture.discussionsReads, 2);
    },
  );

  testWidgets(
    '§3.4 fixture one discussion cache stale viewport 412x900 clock +31s completion background response: stale then one fresh background read',
    (tester) async {
      final fixture = _DiscussionsFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.host()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 31));
      final pending = Completer<ResponseBody>();
      fixture.nextDiscussions = pending;
      await tester.pumpWidget(workspaceHost(fixture.host()));
      await pumpUntil(tester, () => fixture.discussionsReads == 2);
      expect(find.textContaining('First comment', findRichText: true), findsOneWidget);
      pending.complete(jsonResponse([fixture.thread(body: 'Updated comment')]));
      await settleWorkspace(tester);
      expect(find.textContaining('Updated comment', findRichText: true), findsOneWidget);
      expect(fixture.discussionsReads, 2);
    },
  );

  testWidgets(
    '§3.4 fixture one discussion cold dropped viewport 412x900 clock fixed completion retry notice: dropped cold read shows retry and recovers',
    (tester) async {
      final fixture = _DiscussionsFixture();
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
        await tester.pumpWidget(workspaceHost(fixture.host()));
        await settleWorkspace(tester);
        expect(refusals, greaterThan(0));
        expect(find.byType(FailureNotice), findsOneWidget);
        admitted = true;
        final notice = tester.widget<FailureNotice>(find.byType(FailureNotice).first);
        expect(notice.onRetry, isNotNull);
        notice.onRetry!();
        await pumpUntil(tester, () => find.textContaining('First comment', findRichText: true).evaluate().isNotEmpty);
        await settleWorkspace(tester);
        expect(fixture.discussionsReads, 1);
      });
    },
  );

  testWidgets(
    '§3.4 fixture discussions 404 cache empty viewport 412x900 clock fixed completion settled: feed error does not withdraw other cached detail',
    (tester) async {
      final fixture = _DiscussionsFixture()..discussionsStatus = 404;
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.host()));
      await settleWorkspace(tester);
      expect(find.byType(FailureNotice), findsOneWidget);
      expect(fixture.discussionsReads, 1);
    },
  );
}

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final class _DiscussionsFixture {
  _DiscussionsFixture() {
    final dio = Dio()..httpClientAdapter = adapter;
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: dio,
      readCacheClock: () => now,
    );
    api.bindReadCache(account.key, 1);
  }
  var now = DateTime.utc(2026, 10, 23, 1);
  late final FakeAdapter adapter = FakeAdapter(_respond);
  late final GitLabApi api;
  int? discussionsStatus;
  Completer<ResponseBody>? nextDiscussions;
  int get discussionsReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/issues/1/discussions')
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
  Json thread({String body = 'First comment'}) => {
    'id': 'thread-1',
    'individual_note': false,
    'notes': [
      {'id': 1, 'body': body, 'author': {'id': 7, 'username': 'developer'}, 'created_at': '2026-10-23T00:00:00Z', 'system': false},
    ],
  };
  Widget host() => Scaffold(body: DiscussionsTab(account: account, api: api, project: project, resource: 'issues', iid: 1));
  void close() => api.close();

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final path = request.uri.path;
    if (path == '/gitlab/api/v4/projects/42/issues/1/discussions') {
      final pending = nextDiscussions;
      nextDiscussions = null;
      if (pending != null) return pending.future;
      final status = discussionsStatus;
      if (status != null) return jsonResponse({}, status: status);
      if (request.uri.queryParameters['page'] != null && request.uri.queryParameters['page'] != '1') {
        return jsonResponse([]);
      }
      return jsonResponse([thread()]);
    }
    return jsonResponse({}, status: 404);
  }
}
