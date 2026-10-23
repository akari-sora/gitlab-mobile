import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

final class _ReadmeFixture {
  _ReadmeFixture({
    required this.deniedMethod,
    required this.deniedPath,
    required this.status,
  });

  final String deniedMethod, deniedPath;
  final int status;
  int projectId = 42, userId = 7, revision = 0;
  String detailsBranch = 'main';
  var now = DateTime.utc(2026, 10, 23, 8);
  final key = GlobalKey<ProjectOverviewState>();
  late final adapter = FakeAdapter(_respond);
  final apis = <GitLabApi>[];
  late GitLabApi api = newApi();
  FutureOr<ResponseBody>? Function(RequestOptions)? intercept;
  String get root => '/gitlab/api/v4/projects/$projectId';

  GitLabApi newApi() {
    final value = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => now,
    );
    value.bindReadCache('${value.instance.key}#$userId', 1);
    apis.add(value);
    return value;
  }

  void close() {
    for (final value in apis) {
      value.close();
    }
  }

  int count(String method, String suffix, {int id = 42}) => adapter.requests
      .where(
        (request) =>
            request.method == method &&
            request.uri.path == '/gitlab/api/v4/projects/$id$suffix',
      )
      .length;
  int get denials => count(deniedMethod, deniedPath);

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;
    final path = request.uri.path;
    if (request.method == deniedMethod && path == '$root$deniedPath') {
      return jsonResponse({}, status: status);
    }
    if (path == root) {
      return jsonResponse({
        ...projectJson(projectId, branch: detailsBranch),
        'forks_count': 7,
        'license': {'nickname': 'SYN'},
      });
    }
    if (path.startsWith('$root/repository/branches/')) {
      return jsonResponse({
        'name': path.split('/').last,
        'commit': {'id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'},
      });
    }
    if (path == '$root/repository/tree') {
      return jsonResponse([
        {'name': 'README.md', 'path': 'README.md', 'type': 'blob'},
      ]);
    }
    if (path == '$root/repository/files/README.md') {
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'x-gitlab-size': ['40'],
        },
      );
    }
    if (path == '$root/repository/files/README.md/raw') {
      return ResponseBody.fromString('# Synthetic README', 200);
    }
    throw StateError('Unexpected synthetic endpoint: ${request.method} $path');
  }

  Widget host({bool visible = true}) => workspaceHost(
    TickerMode(
      enabled: visible,
      child: Scaffold(
        body: ProjectOverview(
          key: key,
          account: Account(
            instance: api.instance,
            user: GitLabUser(id: userId, username: 'tester', name: 'Test User'),
            token: 'synthetic-test-token',
          ),
          api: api,
          // Keep the widget's default branch fixed: branch-change tests must
          // observe the details response rather than didUpdateWidget's owner.
          project: Project.fromJson(projectJson(projectId)),
          starControl: ProjectStarControl(
            starred: false,
            checked: true,
            busy: false,
            starCount: 0,
            revision: revision,
            recheck: () async {},
            setStar: (_) async => null,
          ),
          onSection: (_) {},
          isCurrent: () => true,
        ),
      ),
    ),
  );
}

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _deniedNotice(WidgetTester tester, int status) {
  expect(find.byType(FailureNotice), findsOneWidget);
  final notice = tester.widget<FailureNotice>(find.byType(FailureNotice));
  expect(notice.error.status, status);
  expect(notice.onRetry, isNotNull);
}

void main() {
  for (final endpoint in [
    ('GET', '/repository/branches/main'),
    ('GET', '/repository/tree'),
    ('HEAD', '/repository/files/README.md'),
    ('GET', '/repository/files/README.md/raw'),
  ]) {
    for (final status in [403, 404]) {
      testWidgets(
        'N-1 ${endpoint.$1} ${endpoint.$2} $status stays denied until explicit refresh',
        (tester) async {
          _viewport(tester);
          final fixture = _ReadmeFixture(
            deniedMethod: endpoint.$1,
            deniedPath: endpoint.$2,
            status: status,
          );
          addTearDown(fixture.close);
          await tester.pumpWidget(fixture.host());
          await settleNetworkWidgets(tester);
          expect(fixture.denials, 1, reason: 'cold denial must not self-retry');
          final state = fixture.key.currentState!;
          expect(state.stale, isFalse);
          expect(state.details!['forks_count'], 7);
          expect(state.details!['license']['nickname'], 'SYN');
          expect(state.error, isNull);
          _deniedNotice(tester, status);

          for (var cycle = 0; cycle < 3; cycle++) {
            await tester.pumpWidget(fixture.host(visible: false));
            await settleNetworkWidgets(tester, maxCycles: 5);
            _deniedNotice(tester, status);
            await tester.pumpWidget(fixture.host());
            await settleNetworkWidgets(tester, maxCycles: 5);
            expect(
              fixture.denials,
              1,
              reason: 'visibility/dependencies cycle $cycle',
            );
            _deniedNotice(tester, status);
          }

          // A metadata reload with the same branch must also preserve denial.
          fixture.now = fixture.now.add(const Duration(seconds: 301));
          fixture.revision++;
          await tester.pumpWidget(fixture.host());
          await settleNetworkWidgets(tester);
          expect(fixture.count('GET', ''), 2);
          expect(fixture.denials, 1);
          expect(state.stale, isFalse);
          _deniedNotice(tester, status);

          tester.widget<FailureNotice>(find.byType(FailureNotice)).onRetry!();
          await settleNetworkWidgets(tester);
          expect(
            fixture.denials,
            2,
            reason: 'explicit retry reads exactly once more',
          );
          expect(state.stale, isFalse);
          _deniedNotice(tester, status);
        },
      );
    }
  }

  testWidgets(
    'N-1 changed details branch retries without background notice flicker',
    (tester) async {
      _viewport(tester);
      final fixture = _ReadmeFixture(
        deniedMethod: 'GET',
        deniedPath: '/repository/branches/main',
        status: 403,
      );
      addTearDown(fixture.close);
      await tester.pumpWidget(fixture.host());
      await settleNetworkWidgets(tester);
      expect(fixture.denials, 1);
      _deniedNotice(tester, 403);

      final pending = Completer<ResponseBody>();
      fixture.intercept = (request) =>
          request.uri.path == '${fixture.root}/repository/branches/next'
          ? pending.future
          : null;
      fixture.detailsBranch = 'next';
      fixture.now = fixture.now.add(const Duration(seconds: 301));
      fixture.revision++;
      await tester.pumpWidget(fixture.host());
      await pumpUntil(
        tester,
        () => fixture.count('GET', '/repository/branches/next') == 1,
      );
      expect(fixture.key.currentState!.details!['default_branch'], 'next');
      expect(fixture.key.currentState!.revalidating, isTrue);
      _deniedNotice(tester, 403);
      pending.complete(
        jsonResponse({
          'name': 'next',
          'commit': {'id': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
        }),
      );
      await settleNetworkWidgets(tester);
      expect(fixture.key.currentState!.repositoryRef!.name, 'next');
      expect(fixture.key.currentState!.readme!.markdown, '# Synthetic README');
      expect(fixture.key.currentState!.stale, isFalse);
      expect(fixture.denials, 1);
      expect(fixture.count('GET', '/repository/branches/next'), 1);
      expect(find.byType(FailureNotice), findsNothing);
    },
  );

  for (final owner in ['project', 'api', 'account']) {
    testWidgets('N-1 new $owner owner clears retained denial', (tester) async {
      _viewport(tester);
      final fixture = _ReadmeFixture(
        deniedMethod: 'GET',
        deniedPath: '/repository/branches/main',
        status: 404,
      );
      addTearDown(fixture.close);
      await tester.pumpWidget(fixture.host());
      await settleNetworkWidgets(tester);
      expect(fixture.denials, 1);
      final state = fixture.key.currentState;
      switch (owner) {
        case 'project':
          fixture.projectId = 43;
        case 'api':
          fixture.api = fixture.newApi();
        case 'account':
          fixture.userId = 8;
          fixture.api.bindReadCache('${fixture.api.instance.key}#8', 2);
      }
      await tester.pumpWidget(fixture.host());
      await settleNetworkWidgets(tester);
      expect(fixture.key.currentState, same(state));
      expect(
        fixture.count(
          'GET',
          '/repository/branches/main',
          id: fixture.projectId,
        ),
        owner == 'project' ? 1 : 2,
      );
      expect(fixture.key.currentState!.stale, isFalse);
      _deniedNotice(tester, 404);
    });
  }
}
