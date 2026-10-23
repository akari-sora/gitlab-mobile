import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

final class _Fixture {
  _Fixture({this.hasReadme = true});

  int id = 42;
  final bool hasReadme;
  var now = DateTime.utc(2026, 10, 23, 8);
  var sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  var branch = 'main';
  FutureOr<ResponseBody>? Function(RequestOptions)? intercept;
  late final adapter = FakeAdapter(_respond);
  late final api = _api();
  GitLabApi _api() {
    final value = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => now,
    );
    value.bindReadCache('${value.instance.key}#7', 1);
    return value;
  }

  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'tester', name: 'Test User'),
    token: 'synthetic-test-token',
  );
  Project get project => Project.fromJson(projectJson(id, branch: branch));
  String get root => '/gitlab/api/v4/projects/$id';
  int count(String method, String suffix, {int? projectId}) => adapter.requests
      .where(
        (request) =>
            request.method == method &&
            request.uri.path ==
                '/gitlab/api/v4/projects/${projectId ?? id}$suffix',
      )
      .length;

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;
    final path = request.uri.path;
    if (path == root) return jsonResponse(projectJson(id, branch: branch));
    if (path.startsWith('$root/repository/branches/')) {
      return jsonResponse({
        'name': branch,
        'commit': {'id': sha},
      });
    }
    if (path == '$root/repository/tree') {
      return jsonResponse([
        if (hasReadme)
          {'name': 'README.md', 'path': 'README.md', 'type': 'blob'},
      ]);
    }
    if (path == '$root/repository/files/README.md' &&
        request.method == 'HEAD') {
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'x-gitlab-size': ['80'],
        },
      );
    }
    if (path == '$root/repository/files/README.md/raw') {
      return ResponseBody.fromString('# Synthetic $id at $sha', 200);
    }
    throw StateError('Unexpected synthetic endpoint: ${request.method} $path');
  }
}

Widget _host(
  _Fixture fixture,
  GlobalKey<ProjectOverviewState> key, {
  bool enabled = true,
}) => MaterialApp(
  home: Scaffold(
    body: TickerMode(
      enabled: enabled,
      child: ProjectOverview(
        key: key,
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        starControl: ProjectStarControl(
          starred: false,
          checked: true,
          busy: false,
          starCount: 0,
          revision: 0,
          recheck: () async {},
          setStar: (_) async => null,
        ),
        onSection: (_) {},
        isCurrent: () => true,
      ),
    ),
  ),
);

Future<void> _loaded(
  WidgetTester tester,
  GlobalKey<ProjectOverviewState> key,
) => pumpUntil(
  tester,
  () =>
      key.currentState != null &&
      !key.currentState!.loading &&
      !key.currentState!.revalidating,
  description: 'overview reads and background work finish',
);

void _counts(
  _Fixture fixture, {
  int? projectId,
  int details = 1,
  int branches = 1,
  int trees = 1,
  int files = 1,
}) {
  int count(String method, String suffix) =>
      fixture.count(method, suffix, projectId: projectId);
  expect(count('GET', ''), details, reason: 'GET project metadata');
  expect(
    count('GET', '/repository/branches/main'),
    branches,
    reason: 'GET default branch',
  );
  expect(
    count('GET', '/repository/tree'),
    trees,
    reason: 'GET pinned root tree',
  );
  expect(
    count('HEAD', '/repository/files/README.md'),
    files,
    reason: 'HEAD README bounds',
  );
  expect(
    count('GET', '/repository/files/README.md/raw'),
    files,
    reason: 'GET pinned README',
  );
}

void main() {
  for (final hasReadme in [true, false]) {
    testWidgets(
      'project fixture README=$hasReadme, cold then fresh memory cache, 800x600 viewport, clock +20s: reopen and all background work finish with zero repeated endpoint reads',
      (tester) async {
        final fixture = _Fixture(hasReadme: hasReadme);
        addTearDown(fixture.api.close);
        final first = GlobalKey<ProjectOverviewState>();
        await tester.pumpWidget(_host(fixture, first));
        await _loaded(tester, first);
        _counts(fixture, files: hasReadme ? 1 : 0);
        await tester.pumpWidget(const SizedBox.shrink());
        fixture.now = fixture.now.add(const Duration(seconds: 20));
        final second = GlobalKey<ProjectOverviewState>();
        await tester.pumpWidget(_host(fixture, second));
        await _loaded(tester, second);
        expect(second.currentState!.stale, isFalse);
        expect(second.currentState!.backgroundFailure, isNull);
        _counts(fixture, files: hasReadme ? 1 : 0);
      },
    );
  }

  testWidgets(
    'project fixture README single file, warm memory cache, 800x600 viewport, clock +20s: canonical typed file reads finish without initialRef or repeated endpoint reads',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.api.close);
      final key = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, key));
      await _loaded(tester, key);
      fixture.now = fixture.now.add(const Duration(seconds: 20));
      final sha = await fixture.api.defaultBranchSha(fixture.project);
      await fixture.api.tree(fixture.id, sha);
      await fixture.api.textFile(fixture.id, sha, 'README.md');
      _counts(fixture);
    },
  );

  testWidgets(
    'project fixture README and moved branch, stale branch memory cache, 800x600 viewport, clock +61s: cached README remains until one revalidation finishes',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.api.close);
      final first = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, first));
      await _loaded(tester, first);
      final cachedReadme = first.currentState!.readme;
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      final response = Completer<ResponseBody>();
      fixture.intercept = (request) =>
          request.uri.path.endsWith('/branches/main') ? response.future : null;
      final second = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, second));
      await pumpUntil(
        tester,
        () => fixture.count('GET', '/repository/branches/main') == 2,
      );
      expect(second.currentState!.stale, isTrue);
      expect(second.currentState!.revalidating, isTrue);
      expect(second.currentState!.readme, cachedReadme);
      fixture.sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      response.complete(
        jsonResponse({
          'name': 'main',
          'commit': {'id': fixture.sha},
        }),
      );
      await _loaded(tester, second);
      expect(second.currentState!.stale, isFalse);
      expect(second.currentState!.readme!.sha, fixture.sha);
      _counts(fixture, branches: 2, trees: 2, files: 2);
    },
  );

  testWidgets(
    'project fixture renamed default branch, stale metadata cache, 800x600 viewport, clock +301s: one revalidation follows the new branch through README completion',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.api.close);
      final first = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, first));
      await _loaded(tester, first);
      final cachedReadme = first.currentState!.readme;
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.now = fixture.now.add(const Duration(seconds: 301));
      final response = Completer<ResponseBody>();
      fixture.intercept = (request) =>
          request.uri.path == fixture.root ? response.future : null;
      final second = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, second));
      await pumpUntil(tester, () => fixture.count('GET', '') == 2);
      expect(second.currentState!.readme, cachedReadme);
      expect(second.currentState!.stale, isTrue);
      expect(second.currentState!.revalidating, isTrue);
      fixture.branch = 'develop';
      fixture.sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      response.complete(jsonResponse(projectJson(42, branch: 'develop')));
      await _loaded(tester, second);
      expect(second.currentState!.repositoryRef!.name, 'develop');
      expect(second.currentState!.readme!.sha, fixture.sha);
      expect(second.currentState!.stale, isFalse);
      _counts(fixture, details: 2, trees: 2, files: 2);
      expect(fixture.count('GET', '/repository/branches/develop'), 1);
    },
  );

  for (final status in [401, 403, 404]) {
    testWidgets(
      'project fixture README single file, stale metadata cache, 800x600 viewport, clock +301s: background $status completes and withdraws cached values',
      (tester) async {
        final fixture = _Fixture();
        addTearDown(fixture.api.close);
        final first = GlobalKey<ProjectOverviewState>();
        await tester.pumpWidget(_host(fixture, first));
        await _loaded(tester, first);
        await tester.pumpWidget(const SizedBox.shrink());
        fixture.now = fixture.now.add(const Duration(seconds: 301));
        final response = Completer<ResponseBody>();
        fixture.intercept = (request) =>
            request.uri.path == fixture.root ? response.future : null;
        final second = GlobalKey<ProjectOverviewState>();
        await tester.pumpWidget(_host(fixture, second));
        await pumpUntil(tester, () => fixture.count('GET', '') == 2);
        expect(second.currentState!.readme, isNotNull);
        expect(second.currentState!.revalidating, isTrue);
        response.complete(jsonResponse({}, status: status));
        await _loaded(tester, second);
        expect(second.currentState!.details, isNull);
        expect(second.currentState!.readme, isNull);
        expect(second.currentState!.fetchedAt, isNull);
        expect(second.currentState!.error!.status, status);
        expect(second.currentState!.backgroundFailure, isNull);
        _counts(fixture, details: 2);
      },
    );
  }

  for (final failure in [FailureKind.network, FailureKind.rateLimited]) {
    testWidgets(
      'project fixture README single file, stale branch cache, 800x600 viewport, clock +61s: background ${failure.name} completes and keeps cached values',
      (tester) async {
        final fixture = _Fixture();
        addTearDown(fixture.api.close);
        final first = GlobalKey<ProjectOverviewState>();
        await tester.pumpWidget(_host(fixture, first));
        await _loaded(tester, first);
        final readme = first.currentState!.readme;
        final fetchedAt = first.currentState!.fetchedAt;
        await tester.pumpWidget(const SizedBox.shrink());
        fixture.now = fixture.now.add(const Duration(seconds: 61));
        final response = Completer<ResponseBody>();
        fixture.intercept = (request) =>
            request.uri.path.endsWith('/branches/main')
            ? response.future
            : null;
        final second = GlobalKey<ProjectOverviewState>();
        await tester.pumpWidget(_host(fixture, second));
        await pumpUntil(
          tester,
          () => fixture.count('GET', '/repository/branches/main') == 2,
        );
        if (failure == FailureKind.network) {
          response.completeError(
            DioException(
              requestOptions: RequestOptions(path: '/synthetic'),
              type: DioExceptionType.connectionError,
            ),
          );
        } else {
          response.complete(
            jsonResponse(
              {},
              status: 429,
              headers: {
                'retry-after': ['60'],
              },
            ),
          );
        }
        await _loaded(tester, second);
        expect(second.currentState!.readme, readme);
        expect(second.currentState!.fetchedAt, fetchedAt);
        expect(second.currentState!.stale, isTrue);
        expect(second.currentState!.error, isNull);
        expect(second.currentState!.backgroundFailure, failure);
        expect(
          second.currentState!.backgroundRetryAt,
          failure == FailureKind.rateLimited ? isNotNull : isNull,
        );
        _counts(fixture, branches: 2);
        // Dispose the cooldown timer before the binding checks pending timers.
        fixture.api.close();
      },
    );
  }

  testWidgets(
    'project fixture README single file, stale branch cache, 800x600 offstage viewport, clock +61s: no background read until TickerMode resumes and settles',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.api.close);
      final first = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, first));
      await _loaded(tester, first);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      final second = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, second, enabled: false));
      await _loaded(tester, second);
      expect(second.currentState!.stale, isTrue);
      _counts(fixture);
      await tester.pumpWidget(_host(fixture, second));
      await _loaded(tester, second);
      expect(second.currentState!.stale, isFalse);
      _counts(fixture, branches: 2);
    },
  );

  testWidgets(
    'project fixture README single file on two projects sharing one API, stale branch cache, 800x600 viewport, clock +61s: old background completion cannot replace the new project epoch',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.api.close);
      final first = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, first));
      await _loaded(tester, first);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      final response = Completer<ResponseBody>();
      final oldBranchPath = '${fixture.root}/repository/branches/main';
      fixture.intercept = (request) =>
          request.uri.path == oldBranchPath ? response.future : null;
      final shared = GlobalKey<ProjectOverviewState>();
      await tester.pumpWidget(_host(fixture, shared));
      await pumpUntil(
        tester,
        () => fixture.count('GET', '/repository/branches/main') == 2,
      );
      fixture.id = 99;
      await tester.pumpWidget(_host(fixture, shared));
      await _loaded(tester, shared);
      response.complete(
        jsonResponse({
          'name': 'main',
          'commit': {'id': fixture.sha},
        }),
      );
      await settleNetworkWidgets(tester);
      expect(shared.currentState!.details!['id'], 99);
      expect(shared.currentState!.readme!.markdown, contains('Synthetic 99'));
      _counts(fixture, projectId: 42, branches: 2);
      _counts(fixture);
    },
  );
}
