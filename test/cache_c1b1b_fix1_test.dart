import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

enum _Page { pipeline, project }

final class _Fixture {
  _Fixture(this.page, {this.hasReadme = false}) {
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => now,
    );
    api.bindReadCache(account.key, 1);
  }

  final _Page page;
  final bool hasReadme;
  var now = DateTime.utc(2026, 10, 23, 8);
  late final adapter = FakeAdapter(_respond);
  late final GitLabApi api;
  final pipelineKey = GlobalKey<PipelinePageState>();
  final projectKey = GlobalKey<ProjectOverviewState>();
  FutureOr<ResponseBody>? Function(RequestOptions)? intercept;
  static const root = '/gitlab/api/v4/projects/42';
  static const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  String get target => page == _Page.pipeline ? '$root/pipelines/99' : root;
  int count(String path) => adapter.requests
      .where((request) => request.method == 'GET' && request.uri.path == path)
      .length;
  int get reads => count(target);
  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'tester', name: 'Test User'),
    token: 'synthetic-test-token',
  );
  Project get project => Project.fromJson(projectJson(42));
  Json details({int forks = 7}) => {
    ...projectJson(42),
    'forks_count': forks,
    'open_issues_count': 3,
    'license': {'name': 'Synthetic license', 'nickname': 'SYN'},
  };
  Json result({bool updated = false}) => page == _Page.pipeline
      ? {
          'id': 99,
          'iid': 7,
          'status': updated ? 'failed' : 'success',
          'ref': 'main',
          'sha': sha,
        }
      : details(forks: updated ? 9 : 7);
  Json? get value => page == _Page.pipeline
      ? pipelineKey.currentState!.data
      : projectKey.currentState!.details;
  ApiFailure? get error => page == _Page.pipeline
      ? pipelineKey.currentState!.error
      : projectKey.currentState!.error;
  FailureKind? get backgroundFailure => page == _Page.pipeline
      ? pipelineKey.currentState!.backgroundFailure
      : projectKey.currentState!.backgroundFailure;
  bool get revalidating => page == _Page.pipeline
      ? pipelineKey.currentState!.revalidating
      : projectKey.currentState!.revalidating;
  bool get stale => page == _Page.pipeline
      ? pipelineKey.currentState!.stale
      : projectKey.currentState!.stale;
  DateTime? get fetchedAt => page == _Page.pipeline
      ? pipelineKey.currentState!.fetchedAt
      : projectKey.currentState!.fetchedAt;

  Widget host({bool visible = true}) => workspaceHost(
    TickerMode(
      enabled: visible,
      child: page == _Page.pipeline
          ? PipelinePage(
              key: pipelineKey,
              account: account,
              api: api,
              project: project,
              id: 99,
            )
          : Scaffold(
              body: ProjectOverview(
                key: projectKey,
                account: account,
                api: api,
                project: project,
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

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;
    if (request.method != 'GET' && request.method != 'HEAD') {
      return jsonResponse({'id': 1});
    }
    final path = request.uri.path;
    if (path == target) return jsonResponse(result());
    if (path == '$root/repository/branches/main') {
      return jsonResponse({
        'name': 'main',
        'commit': {'id': sha},
      });
    }
    if (path == '$root/repository/tree') {
      return jsonResponse([
        if (hasReadme)
          {'name': 'README.md', 'path': 'README.md', 'type': 'blob'},
      ]);
    }
    if (path == '$root/repository/files/README.md') {
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'x-gitlab-size': ['20'],
        },
      );
    }
    if (path == '$root/repository/files/README.md/raw') {
      return ResponseBody.fromString('# Synthetic README', 200);
    }
    if (path == '$root/pipelines/99/jobs') return jsonResponse([]);
    throw StateError('Unexpected synthetic endpoint: ${request.method} $path');
  }

  Future<void> warm(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await settleNetworkWidgets(tester);
    expect(value, result());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    now = now.add(Duration(seconds: page == _Page.pipeline ? 31 : 301));
  }
}

void main() {
  for (final page in _Page.values) {
    testWidgets(
      'I1 ${page.name}: queued background read waits until visible again',
      (tester) async {
        final fixture = _Fixture(page);
        addTearDown(fixture.api.close);
        await fixture.warm(tester);
        final occupied = Completer<void>();
        fixture.intercept = (request) =>
            request.uri.path.contains('/projects/8/issues/')
            ? occupied.future.then((_) => jsonResponse({'id': 1}))
            : null;
        final blockers = [
          for (var id = 1; id <= 4; id++)
            fixture.api.cachedRecord(
              ['projects', '8', 'issues', '$id'],
              fresh: true,
              background: true,
            ),
        ];
        await pumpUntil(
          tester,
          () =>
              fixture.adapter.requests.length >=
              (page == _Page.pipeline ? 6 : 7),
        );
        await tester.pumpWidget(fixture.host());
        await pumpUntil(tester, () => fixture.revalidating);
        await tester.pumpWidget(fixture.host(visible: false));
        occupied.complete();
        await settleNetworkWidgets(tester);
        await tester.runAsync(() => Future.wait(blockers));
        expect(
          fixture.reads,
          1,
          reason: 'hidden queued read must send no HTTP',
        );
        expect(fixture.value, fixture.result());
        expect(fixture.stale, isTrue);
        expect(fixture.backgroundFailure, isNull);
        await tester.pumpWidget(fixture.host());
        await settleNetworkWidgets(tester);
        expect(fixture.reads, 2, reason: 'visibility resumes exactly one read');
        expect(fixture.stale, isFalse);
      },
    );

    testWidgets(
      'I1 ${page.name}: hidden background completion is ignored and resumes',
      (tester) async {
        final fixture = _Fixture(page);
        addTearDown(fixture.api.close);
        await fixture.warm(tester);
        final pending = Completer<ResponseBody>();
        fixture.intercept = (request) =>
            request.uri.path == fixture.target ? pending.future : null;
        await tester.pumpWidget(fixture.host());
        await pumpUntil(tester, () => fixture.reads == 2);
        final oldTime = fixture.fetchedAt;
        await tester.pumpWidget(fixture.host(visible: false));
        pending.complete(jsonResponse(fixture.result(updated: true)));
        await settleNetworkWidgets(tester);
        expect(fixture.value, fixture.result());
        expect(fixture.fetchedAt, oldTime);
        expect(fixture.stale, isTrue);
        expect(fixture.backgroundFailure, isNull);
        fixture.intercept = null;
        await tester.pumpWidget(fixture.host());
        await settleNetworkWidgets(tester);
        expect(fixture.reads, 3);
        expect(fixture.stale, isFalse);
      },
    );

    for (final status in [401, 403, 404]) {
      testWidgets(
        'I1 ${page.name}: hidden background $status withdraws revoked data',
        (tester) async {
          final fixture = _Fixture(page);
          addTearDown(fixture.api.close);
          await fixture.warm(tester);
          final pending = Completer<ResponseBody>();
          fixture.intercept = (request) =>
              request.uri.path == fixture.target ? pending.future : null;
          await tester.pumpWidget(fixture.host());
          await pumpUntil(tester, () => fixture.reads == 2);
          await tester.pumpWidget(fixture.host(visible: false));
          pending.complete(jsonResponse({}, status: status));
          await settleNetworkWidgets(tester);
          expect(fixture.value, isNull);
          expect(fixture.error?.status, status);
          expect(fixture.backgroundFailure, isNull);
          expect(fixture.revalidating, isFalse);
        },
      );
    }

    testWidgets('I1 ${page.name}: explicit read completes while hidden', (
      tester,
    ) async {
      final fixture = _Fixture(page);
      addTearDown(fixture.api.close);
      final pending = Completer<ResponseBody>();
      fixture.intercept = (request) =>
          request.uri.path == fixture.target ? pending.future : null;
      await tester.pumpWidget(fixture.host());
      await pumpUntil(tester, () => fixture.reads == 1);
      await tester.pumpWidget(fixture.host(visible: false));
      pending.complete(jsonResponse(fixture.result(updated: true)));
      await settleNetworkWidgets(tester);
      expect(fixture.value, fixture.result(updated: true));
      expect(fixture.error, isNull);
      expect(fixture.reads, 1);
    });

    for (final background in [false, true]) {
      for (final sustained in [false, true]) {
        testWidgets(
          'I2 ${page.name}: ${background ? 'background' : 'cold'} supersedes '
          '${sustained ? 'leave retryable failure' : 'recover after writes stop'}',
          (tester) async {
            final fixture = _Fixture(page);
            addTearDown(fixture.api.close);
            if (background) await fixture.warm(tester);
            final responses = List.generate(
              sustained ? 6 : 4,
              (_) => Completer<ResponseBody>(),
            );
            var reads = 0;
            fixture.intercept = (request) {
              if (request.method != 'GET' ||
                  request.uri.path != fixture.target) {
                return null;
              }
              final index = reads++;
              return index < responses.length ? responses[index].future : null;
            };
            await tester.pumpWidget(fixture.host());
            for (var index = 0; index < responses.length; index++) {
              await pumpUntil(
                tester,
                () => reads == index + 1,
                description: 'next bounded/quiet read after superseding write',
              );
              await tester.runAsync(
                () => fixture.api.updateIssue(42, 1, {
                  'title': 'synthetic write $index',
                }),
              );
              responses[index].complete(
                jsonResponse(fixture.result(updated: true)),
              );
            }
            await pumpUntil(
              tester,
              () => sustained
                  ? (background
                        ? fixture.backgroundFailure != null
                        : fixture.error != null)
                  : reads >= 5 &&
                        fixture.value != null &&
                        !fixture.stale &&
                        !fixture.revalidating,
              description: 'quiet recovery finishes or reports bounded failure',
            );
            await settleNetworkWidgets(tester);
            if (!sustained) {
              expect(reads, 5);
              expect(fixture.value, fixture.result());
              expect(fixture.error, isNull);
              expect(fixture.backgroundFailure, isNull);
              expect(fixture.stale, isFalse);
            } else {
              expect(reads, 6, reason: 'recovery must be bounded');
              expect(fixture.value, background ? fixture.result() : isNull);
              expect(
                fixture.error?.kind,
                background ? null : FailureKind.cancelled,
              );
              expect(
                fixture.backgroundFailure,
                background ? FailureKind.cancelled : null,
              );
              if (!background) {
                final notice = tester.widget<FailureNotice>(
                  find.byType(FailureNotice).first,
                );
                expect(notice.onRetry, isNotNull);
                fixture.intercept = null;
                notice.onRetry!();
                await pumpUntil(
                  tester,
                  () => fixture.value != null && fixture.error == null,
                );
                await settleNetworkWidgets(tester);
                expect(fixture.value, fixture.result());
                expect(fixture.error, isNull);
              }
            }
            expect(fixture.revalidating, isFalse);
          },
        );
      }
    }
  }

  for (final status in [401, 403, 404]) {
    testWidgets('I4 details $status shows one retry notice', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture(_Page.project);
      addTearDown(fixture.api.close);
      fixture.intercept = (request) => request.uri.path == fixture.target
          ? jsonResponse({}, status: status)
          : null;
      await tester.pumpWidget(fixture.host());
      await settleNetworkWidgets(tester);
      expect(fixture.value, isNull);
      expect(fixture.error?.status, status);
      expect(find.byType(FailureNotice), findsOneWidget);
      expect(
        tester.widget<FailureNotice>(find.byType(FailureNotice)).onRetry,
        isNotNull,
      );
    });
  }

  testWidgets('I4 hidden branch 404 clears only README data', (tester) async {
    final fixture = _Fixture(_Page.project, hasReadme: true);
    addTearDown(fixture.api.close);
    await fixture.warm(tester);
    final pending = Completer<ResponseBody>();
    fixture.intercept = (request) =>
        request.uri.path == '${_Fixture.root}/repository/branches/main'
        ? pending.future
        : null;
    await tester.pumpWidget(fixture.host());
    await pumpUntil(
      tester,
      () => fixture.count('${_Fixture.root}/repository/branches/main') == 2,
    );
    expect(fixture.projectKey.currentState!.readme, isNotNull);
    await tester.pumpWidget(fixture.host(visible: false));
    pending.complete(jsonResponse({}, status: 404));
    await settleNetworkWidgets(tester);
    expect(fixture.value, fixture.details());
    expect(fixture.error, isNull);
    expect(fixture.projectKey.currentState!.repositoryRef, isNull);
    expect(fixture.projectKey.currentState!.readme, isNull);
    await tester.scrollUntilVisible(find.byType(FailureNotice), 400);
    expect(
      tester.widget<FailureNotice>(find.byType(FailureNotice)).error.status,
      404,
    );
  });

  for (final denied in [
    ('branch', '/repository/branches/main', 404),
    ('tree', '/repository/tree', 403),
    ('README', '/repository/files/README.md', 404),
  ]) {
    testWidgets(
      'I4 ${denied.$1} ${denied.$3} keeps project details and revalidation',
      (tester) async {
        final fixture = _Fixture(_Page.project, hasReadme: true);
        addTearDown(fixture.api.close);
        await fixture.warm(tester);
        // A new SHA ensures the pinned tree and README actually need reading.
        fixture.intercept = (request) {
          if (request.uri.path == '${_Fixture.root}${denied.$2}') {
            return jsonResponse({}, status: denied.$3);
          }
          if (denied.$1 != 'branch' &&
              request.uri.path == '${_Fixture.root}/repository/branches/main') {
            return jsonResponse({
              'name': 'main',
              'commit': {'id': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
            });
          }
          return null;
        };
        await tester.pumpWidget(fixture.host());
        await settleNetworkWidgets(tester);
        final state = fixture.projectKey.currentState!;
        expect(state.details, fixture.details());
        expect(state.fetchedAt, isNotNull);
        expect(state.details!['forks_count'], 7);
        expect(state.details!['license']['nickname'], 'SYN');
        expect(state.repositoryRef, isNull);
        expect(state.readme, isNull);
        expect(state.error, isNull);
        expect(state.backgroundFailure, isNull);
        await tester.scrollUntilVisible(find.byType(FailureNotice), 400);
        final notice = tester.widget<FailureNotice>(find.byType(FailureNotice));
        expect(notice.onRetry, isNotNull);
        expect(notice.error.status, denied.$3);
        await tester.pumpWidget(fixture.host(visible: false));
        fixture.now = fixture.now.add(const Duration(seconds: 301));
        // Reopen with the retained metadata now stale: README failure must not
        // become a page-level gate that prevents metadata revalidation.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(fixture.host());
        await settleNetworkWidgets(tester);
        expect(fixture.reads, 3);
        expect(fixture.value, fixture.details());
        expect(fixture.error, isNull);
      },
    );
  }
}
