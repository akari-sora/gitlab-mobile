import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_overview_page.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

enum _Page { pipeline, project, ci }

final class _Fixture {
  _Fixture(this.page) {
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => now,
    );
    api.bindReadCache(account.key, 1);
  }

  final _Page page;
  var now = DateTime.utc(2026, 10, 23, 8);
  late final adapter = FakeAdapter(_respond);
  late final GitLabApi api;
  final pipelineKey = GlobalKey<PipelinePageState>();
  final projectKey = GlobalKey<ProjectOverviewState>();
  bool admitted = true;
  int refusals = 0;
  String? refuseAfter;
  VoidCallback? pipelineRefresh;
  String branchSha = sha;
  static const root = '/gitlab/api/v4/projects/42';
  static const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  static const projects = '/gitlab/api/v4/projects';
  String get target => switch (page) {
    _Page.pipeline => '$root/pipelines/99',
    _Page.project => root,
    _Page.ci => projects,
  };
  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'tester', name: 'Test User'),
    token: 'synthetic-test-token',
  );
  Json get pipeline => {
    'id': 99,
    'iid': 7,
    'status': 'success',
    'ref': 'main',
    'sha': sha,
  };
  int count(String path) =>
      adapter.requests.where((request) => request.uri.path == path).length;
  Finder get knownRow =>
      find.byKey(const ValueKey('ci-overview-state-42-known'));

  // The foreground cap queues rather than drops. Exercise the real cache's
  // refusal result through its send fence without closing/changing page owners.
  Future<T> fenced<T>(Future<T> Function() body) => CachedRead.run(
    body,
    mayStart: () {
      if (!admitted) refusals++;
      return admitted;
    },
  );

  ResponseBody _respond(RequestOptions request) {
    final path = request.uri.path;
    if (path == refuseAfter) admitted = false;
    if (path == projects) return jsonResponse([projectJson(42)]);
    if (path == root) return jsonResponse(projectJson(42));
    if (path == '$root/pipelines/99') return jsonResponse(pipeline);
    if (path == '$root/pipelines') return jsonResponse([pipeline]);
    if (path == '$root/pipelines/99/jobs') return jsonResponse([]);
    if (path == '$root/repository/branches/main') {
      return jsonResponse({
        'name': 'main',
        'commit': {'id': branchSha},
      });
    }
    if (path == '$root/repository/tree') return jsonResponse([]);
    throw StateError('Unexpected synthetic endpoint: $path');
  }

  Widget host({bool visible = true}) => workspaceHost(
    TickerMode(
      enabled: visible,
      child: switch (page) {
        _Page.pipeline => PipelinePage(
          key: pipelineKey,
          account: account,
          api: api,
          project: Project.fromJson(projectJson(42)),
          id: 99,
        ),
        _Page.project => Scaffold(
          body: ProjectOverview(
            key: projectKey,
            account: account,
            api: api,
            project: Project.fromJson(projectJson(42)),
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
        _Page.ci => CiOverviewPage(account: account, api: api),
      },
    ),
  );

  void expectData() {
    switch (page) {
      case _Page.pipeline:
        expect(pipelineKey.currentState!.data, pipeline);
        expect(pipelineKey.currentState!.error, isNull);
        expect(pipelineKey.currentState!.backgroundFailure, isNull);
      case _Page.project:
        expect(projectKey.currentState!.details, projectJson(42));
        expect(projectKey.currentState!.error, isNull);
        expect(projectKey.currentState!.backgroundFailure, isNull);
      case _Page.ci:
        expect(knownRow, findsOneWidget);
        expect(find.text('Pipeline #7'), findsOneWidget);
    }
    expect(find.byType(FailureNotice), findsNothing);
  }

  Future<void> refresh(WidgetTester tester) async {
    if (page == _Page.project) {
      unawaited(projectKey.currentState!.refresh());
    } else if (page == _Page.pipeline && pipelineRefresh != null) {
      pipelineRefresh!();
    } else {
      await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh).first);
    }
    await settleNetworkWidgets(tester);
  }

  Future<void> retryNotice(WidgetTester tester) async {
    if (page == _Page.project) {
      await tester.scrollUntilVisible(find.byType(FailureNotice), 400);
    }
    final notice = tester.widget<FailureNotice>(find.byType(FailureNotice));
    expect(notice.error.kind, FailureKind.cancelled);
    expect(notice.onRetry, isNotNull);
    if (page == _Page.pipeline) pipelineRefresh = notice.onRetry;
    // Tap the actual retry control, proving the existing notice renders it.
    await tester.tap(
      find
          .descendant(
            of: find.byType(FailureNotice),
            matching: find.byType(TextButton),
          )
          .first,
    );
    await settleNetworkWidgets(tester);
  }
}

void main() {
  for (final page in _Page.values) {
    testWidgets(
      'fix1b ${page.name}: cold drop shows failure and retry recovers',
      (tester) async {
        final fixture = _Fixture(page);
        addTearDown(fixture.api.close);
        await fixture.fenced(() async {
          fixture.admitted = false;
          await tester.pumpWidget(fixture.host());
          await settleNetworkWidgets(tester);
          expect(fixture.refusals, greaterThan(0));
          expect(fixture.count(fixture.target), 0);
          expect(find.byType(FailureNotice), findsOneWidget);
          fixture.admitted = true;
          await fixture.retryNotice(tester);
          fixture.expectData();
          expect(fixture.count(fixture.target), 1);
        });
      },
    );

    testWidgets('fix1b ${page.name}: foreground drop keeps displayed data', (
      tester,
    ) async {
      final fixture = _Fixture(page);
      addTearDown(fixture.api.close);
      await fixture.fenced(() async {
        if (page == _Page.pipeline) {
          // Use the public page retry callback to avoid also refreshing the
          // independent jobs feed through the app-bar action.
          fixture.admitted = false;
          await tester.pumpWidget(fixture.host());
          await settleNetworkWidgets(tester);
          fixture.admitted = true;
          await fixture.retryNotice(tester);
          fixture.refusals = 0;
          // Make the retry callback perform a cold cache lookup while keeping
          // the page's rendered value available.
          fixture.api.clearReadCache();
        } else {
          await tester.pumpWidget(fixture.host());
          await settleNetworkWidgets(tester);
        }
        fixture.expectData();
        final previousReads = fixture.count(fixture.target);
        fixture.admitted = false;
        await fixture.refresh(tester);
        expect(fixture.refusals, greaterThan(0));
        fixture.expectData();
        expect(fixture.count(fixture.target), previousReads);
      });
    });
  }

  for (final page in _Page.values) {
    testWidgets('fix1b ${page.name}: background drop stays silent', (
      tester,
    ) async {
      final fixture = _Fixture(page);
      addTearDown(fixture.api.close);
      await fixture.fenced(() async {
        await tester.pumpWidget(fixture.host());
        await settleNetworkWidgets(tester);
        fixture.expectData();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        fixture.now = fixture.now.add(const Duration(minutes: 6));
        fixture.admitted = false;
        final previousReads = fixture.count(fixture.target);
        await tester.pumpWidget(fixture.host());
        await settleNetworkWidgets(tester);
        expect(fixture.refusals, greaterThan(0));
        fixture.expectData();
        expect(fixture.count(fixture.target), previousReads);
      });
    });
  }

  for (final endpoint in ['branch', 'tree']) {
    for (final warm in [false, true]) {
      testWidgets(
        'fix1b project $endpoint: drop ${warm ? 'keeps repository data' : 'shows repository retry'}',
        (tester) async {
          final fixture = _Fixture(_Page.project);
          addTearDown(fixture.api.close);
          await fixture.fenced(() async {
            if (warm) {
              await tester.pumpWidget(fixture.host());
              await settleNetworkWidgets(tester);
              expect(
                fixture.projectKey.currentState!.repositoryRef?.sha,
                _Fixture.sha,
              );
            }
            if (warm && endpoint == 'tree') {
              fixture.branchSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
            }
            fixture.refuseAfter = endpoint == 'branch'
                ? _Fixture.root
                : '${_Fixture.root}/repository/branches/main';
            if (warm) {
              // Prevent stale background work; only the explicit refresh runs.
              await tester.pumpWidget(fixture.host(visible: false));
              await fixture.refresh(tester);
            } else {
              await tester.pumpWidget(fixture.host(visible: false));
              await settleNetworkWidgets(tester);
            }
            expect(fixture.refusals, greaterThan(0));
            expect(fixture.projectKey.currentState!.details, projectJson(42));
            expect(fixture.projectKey.currentState!.error, isNull);
            if (warm) {
              fixture.expectData();
              expect(
                fixture.projectKey.currentState!.repositoryRef?.sha,
                _Fixture.sha,
              );
            } else {
              await tester.scrollUntilVisible(find.byType(FailureNotice), 400);
              fixture.refuseAfter = null;
              fixture.admitted = true;
              await fixture.retryNotice(tester);
              fixture.expectData();
              expect(
                fixture.projectKey.currentState!.repositoryRef?.sha,
                _Fixture.sha,
              );
            }
          });
        },
      );
    }
  }

  for (final warm in [false, true]) {
    testWidgets(
      'fix1b ci row: drop ${warm ? 'keeps known pipeline' : 'shows row failure and refresh recovers'}',
      (tester) async {
        final fixture = _Fixture(_Page.ci);
        addTearDown(fixture.api.close);
        await fixture.fenced(() async {
          if (warm) {
            await tester.pumpWidget(fixture.host());
            await settleNetworkWidgets(tester);
            fixture.expectData();
          }
          fixture.refuseAfter = _Fixture.projects;
          if (warm) {
            await fixture.refresh(tester);
          } else {
            await tester.pumpWidget(fixture.host());
            await settleNetworkWidgets(tester);
          }
          expect(fixture.refusals, greaterThan(0));
          if (warm) {
            fixture.expectData();
          } else {
            expect(
              find.byKey(const ValueKey('ci-overview-state-42-error')),
              findsOneWidget,
            );
            fixture.refuseAfter = null;
            fixture.admitted = true;
            await fixture.refresh(tester);
            fixture.expectData();
          }
        });
      },
    );
  }
}
