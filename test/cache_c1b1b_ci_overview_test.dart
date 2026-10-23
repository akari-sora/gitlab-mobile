import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_overview_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart' show pumpUntil, settleNetworkWidgets;
import 'workspace_widget_test.dart' show workspaceHost;

void main() {
  testWidgets(
    'fixture=12 projects cache=empty viewport=800x2400 clock=fixed completion=all pipeline checks: CI overview stages 8 then remainder with four explicit row states and bounded concurrency',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = DateTime.utc(2026, 10, 23, 12);
      expect(clock.isUtc, isTrue);

      final pending = <int, Completer<ResponseBody>>{};
      var active = 0;
      var maxActive = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          return jsonResponse(
            List.generate(12, (index) => projectJson(index + 1)),
          );
        }
        final match = RegExp(
          r'/projects/(\d+)/pipelines$',
        ).firstMatch(request.uri.path);
        if (match != null) {
          final id = int.parse(match.group(1)!);
          active++;
          maxActive = max(maxActive, active);
          final completer = pending.putIfAbsent(
            id,
            Completer<ResponseBody>.new,
          );
          return completer.future.whenComplete(() => active--);
        }
        return jsonResponse({}, status: 404);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(
          CiOverviewPage(account: _account(), api: api, maxConcurrent: 4),
        ),
      );
      await pumpUntil(tester, () => pending.length == 4);

      expect(pending.keys, unorderedEquals({1, 2, 3, 4}));
      expect(maxActive, 4);
      expect(_stateFinder(1, ProjectCiLoadState.loading), findsOneWidget);
      expect(_stateFinder(5, ProjectCiLoadState.unknown), findsOneWidget);
      expect(_stateFinder(9, ProjectCiLoadState.unknown), findsOneWidget);

      for (var id = 1; id <= 4; id++) {
        pending[id]!.complete(_pipelineResponse(id));
      }
      await pumpUntil(tester, () => pending.length == 8);

      expect(pending.keys, unorderedEquals({1, 2, 3, 4, 5, 6, 7, 8}));
      expect(_stateFinder(1, ProjectCiLoadState.known), findsOneWidget);
      expect(_stateFinder(5, ProjectCiLoadState.loading), findsOneWidget);
      expect(_stateFinder(9, ProjectCiLoadState.unknown), findsOneWidget);

      for (var id = 5; id <= 8; id++) {
        pending[id]!.complete(
          id == 8
              ? jsonResponse({'message': 'failed'}, status: 500)
              : _pipelineResponse(id),
        );
      }
      await pumpUntil(tester, () => pending.length == 12);

      expect(_stateFinder(8, ProjectCiLoadState.error), findsOneWidget);
      expect(_stateFinder(9, ProjectCiLoadState.loading), findsOneWidget);
      expect(maxActive, lessThanOrEqualTo(4));

      for (var id = 9; id <= 12; id++) {
        pending[id]!.complete(_pipelineResponse(id));
      }
      await pumpUntil(
        tester,
        () =>
            find
                .byKey(const ValueKey('ci-overview-state-12-known'))
                .evaluate()
                .isNotEmpty &&
            active == 0,
      );

      expect(_requestCount(adapter, '/projects'), 1);
      for (var id = 1; id <= 12; id++) {
        expect(_requestCount(adapter, '/projects/$id/pipelines'), 1);
      }
    },
  );

  testWidgets(
    'fixture=10 projects one failed cache=empty viewport=800x2400 clock=fixed completion=all unknown checks: failed filter keeps unresolved rows and puts known matches first',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = DateTime.utc(2026, 10, 23, 12);
      expect(clock.isUtc, isTrue);

      final pending = <int, Completer<ResponseBody>>{};
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          return jsonResponse(
            List.generate(10, (index) => projectJson(index + 1)),
          );
        }
        final match = RegExp(
          r'/projects/(\d+)/pipelines$',
        ).firstMatch(request.uri.path);
        if (match != null) {
          final id = int.parse(match.group(1)!);
          return pending.putIfAbsent(id, Completer<ResponseBody>.new).future;
        }
        return jsonResponse({}, status: 404);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(
          CiOverviewPage(account: _account(), api: api, maxConcurrent: 2),
        ),
      );
      await pumpUntil(tester, () => pending.length == 2);

      pending[1]!.complete(_pipelineResponse(1, status: 'failed'));
      pending[2]!.complete(_pipelineResponse(2, status: 'success'));
      await pumpUntil(tester, () => pending.length == 4);

      await tester.tap(find.byKey(const ValueKey('ci-overview-filter-failed')));
      await tester.pump();

      expect(_stateFinder(1, ProjectCiLoadState.known), findsOneWidget);
      expect(find.text('Example 2'), findsNothing);
      expect(find.text('Example 3'), findsOneWidget);
      expect(find.byType(EmptyState), findsNothing);
      expect(
        tester.getTopLeft(find.text('Example 1')).dy,
        lessThan(tester.getTopLeft(find.text('Example 3')).dy),
      );

      for (var id = 3; id <= 10; id++) {
        await pumpUntil(tester, () => pending.containsKey(id));
        pending[id]!.complete(_pipelineResponse(id, status: 'success'));
        await tester.pump();
      }
      await pumpUntil(
        tester,
        () =>
            find.text('Example 10').evaluate().isEmpty &&
            _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );

      expect(find.text('Example 1'), findsOneWidget);
      for (var id = 2; id <= 10; id++) {
        expect(find.text('Example $id'), findsNothing);
      }
      expect(_requestCount(adapter, '/projects'), 1);
      for (var id = 1; id <= 10; id++) {
        expect(_requestCount(adapter, '/projects/$id/pipelines'), 1);
      }
    },
  );

  testWidgets(
    'fixture=two project pages cache=empty viewport=800x2400 clock=fixed completion=both pipeline queues: load more cannot overlap the active bounded queue',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = DateTime.utc(2026, 10, 23, 12);
      expect(clock.isUtc, isTrue);

      final pending = <int, Completer<ResponseBody>>{};
      var active = 0;
      var maxActive = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          if (request.uri.queryParameters['page'] == '2') {
            return jsonResponse([projectJson(5), projectJson(6)]);
          }
          return jsonResponse(
            List.generate(4, (index) => projectJson(index + 1)),
            headers: {
              'x-next-page': ['2'],
            },
          );
        }
        final match = RegExp(
          r'/projects/(\d+)/pipelines$',
        ).firstMatch(request.uri.path);
        if (match != null) {
          final id = int.parse(match.group(1)!);
          active++;
          maxActive = max(maxActive, active);
          return pending
              .putIfAbsent(id, Completer<ResponseBody>.new)
              .future
              .whenComplete(() => active--);
        }
        return jsonResponse({}, status: 404);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(
          CiOverviewPage(account: _account(), api: api, maxConcurrent: 2),
        ),
      );
      await pumpUntil(tester, () => pending.length == 2);

      await tester.tap(find.byKey(const ValueKey('ci-overview-load-more')));
      await tester.pump();
      expect(_requestCount(adapter, '/projects'), 1);
      expect(pending.keys, unorderedEquals({1, 2}));

      for (var id = 1; id <= 4; id++) {
        await pumpUntil(tester, () => pending.containsKey(id));
        pending[id]!.complete(_pipelineResponse(id));
        await tester.pump();
      }
      await pumpUntil(
        tester,
        () =>
            _stateFinder(4, ProjectCiLoadState.known).evaluate().isNotEmpty &&
            active == 0,
      );
      expect(active, 0);

      await tester.tap(find.byKey(const ValueKey('ci-overview-load-more')));
      await pumpUntil(tester, () => pending.length == 6 && active == 2);
      expect(_requestCount(adapter, '/projects'), 2);
      expect(active, 2);
      expect(maxActive, lessThanOrEqualTo(2));

      for (var id = 5; id <= 6; id++) {
        pending[id]!.complete(_pipelineResponse(id));
      }
      await pumpUntil(
        tester,
        () =>
            _stateFinder(6, ProjectCiLoadState.known).evaluate().isNotEmpty &&
            active == 0,
      );
      expect(active, 0);
      for (var id = 1; id <= 6; id++) {
        expect(_requestCount(adapter, '/projects/$id/pipelines'), 1);
      }
    },
  );

  testWidgets(
    'fixture=owner switch with old pipeline and new project page pending cache=empty viewport=800x2400 clock=fixed completion=both owners: old rows withdraw immediately and stale completion cannot return',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = DateTime.utc(2026, 10, 23, 12);
      expect(clock.isUtc, isTrue);

      final oldPipeline = Completer<ResponseBody>();
      final oldAdapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          return jsonResponse([_namedProjectJson(1, 'Old project')]);
        }
        if (request.uri.path.endsWith('/projects/1/pipelines')) {
          return oldPipeline.future;
        }
        return jsonResponse({}, status: 404);
      });
      final oldApi = testApi(oldAdapter);
      addTearDown(oldApi.close);

      final newProjects = Completer<ResponseBody>();
      final newAdapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          return newProjects.future;
        }
        if (request.uri.path.endsWith('/projects/2/pipelines')) {
          return _pipelineResponse(2, status: 'success');
        }
        return jsonResponse({}, status: 404);
      });
      final newApi = testApi(newAdapter);
      addTearDown(newApi.close);

      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: _account(), api: oldApi)),
      );
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.loading).evaluate().isNotEmpty,
      );
      expect(find.text('Old project'), findsOneWidget);

      await tester.pumpWidget(
        workspaceHost(
          CiOverviewPage(account: _account(userId: 2), api: newApi),
        ),
      );
      expect(find.text('Old project'), findsNothing);
      await pumpUntil(
        tester,
        () => _requestCount(newAdapter, '/projects') == 1,
      );
      expect(_requestCount(newAdapter, '/projects'), 1);

      oldPipeline.complete(_pipelineResponse(1, status: 'failed'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
      expect(find.text('Old project'), findsNothing);

      newProjects.complete(jsonResponse([_namedProjectJson(2, 'New project')]));
      await pumpUntil(
        tester,
        () => _stateFinder(2, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      expect(find.text('Old project'), findsNothing);
      expect(find.text('New project'), findsOneWidget);
      expect(_requestCount(oldAdapter, '/projects/1/pipelines'), 1);
      expect(_requestCount(newAdapter, '/projects/2/pipelines'), 1);
    },
  );

  testWidgets(
    'fixture=one project cache=warm viewport=800x2400 clock=inside freshness completion=row known: warm reopen sends zero requests per endpoint',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 23, 12);
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          return jsonResponse([projectJson(1)]);
        }
        if (request.uri.path.endsWith('/projects/1/pipelines')) {
          return _pipelineResponse(1, status: 'failed');
        }
        return jsonResponse({}, status: 404);
      });
      final account = _account();
      final api = _boundApi(adapter, account, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      expect(_requestCount(adapter, '/projects'), 1);
      expect(_requestCount(adapter, '/projects/1/pipelines'), 1);

      await tester.pumpWidget(workspaceHost(const SizedBox()));
      await tester.pump();
      now = now.add(const Duration(seconds: 30));
      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );

      expect(_requestCount(adapter, '/projects'), 1);
      expect(_requestCount(adapter, '/projects/1/pipelines'), 1);
      expect(_statusText(1, '失敗'), findsOneWidget);
    },
  );

  testWidgets(
    'fixture=one failed project cache=stale viewport=800x2400 clock=after freshness completion=held revalidation done: stale open renders known status then updates in background',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 23, 12);
      final projectsRefresh = Completer<ResponseBody>();
      final pipelineRefresh = Completer<ResponseBody>();
      var projectReads = 0;
      var pipelineReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          projectReads++;
          return projectReads == 1
              ? jsonResponse([projectJson(1)])
              : projectsRefresh.future;
        }
        if (request.uri.path.endsWith('/projects/1/pipelines')) {
          pipelineReads++;
          return pipelineReads == 1
              ? _pipelineResponse(1, status: 'failed')
              : pipelineRefresh.future;
        }
        return jsonResponse({}, status: 404);
      });
      final account = _account();
      final api = _boundApi(adapter, account, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      await tester.pumpWidget(workspaceHost(const SizedBox()));
      await tester.pump();

      now = now.add(const Duration(seconds: 61));
      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () =>
            projectReads == 2 &&
            _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      expect(_statusText(1, '失敗'), findsOneWidget);

      projectsRefresh.complete(jsonResponse([projectJson(1)]));
      await pumpUntil(tester, () => pipelineReads == 2);
      expect(_stateFinder(1, ProjectCiLoadState.known), findsOneWidget);
      expect(_statusText(1, '失敗'), findsOneWidget);

      pipelineRefresh.complete(_pipelineResponse(1, status: 'success'));
      await pumpUntil(tester, () => _statusText(1, '失敗').evaluate().isEmpty);
      expect(_requestCount(adapter, '/projects'), 2);
      expect(_requestCount(adapter, '/projects/1/pipelines'), 2);
    },
  );

  testWidgets(
    'fixture=one failed project cache=stale viewport=800x2400 clock=after freshness completion=covered denied revalidation done: hidden pipeline 403 withdraws known row',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 23, 12);
      final pipelineRefresh = Completer<ResponseBody>();
      var pipelineReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          return jsonResponse([projectJson(1)]);
        }
        if (request.uri.path.endsWith('/projects/1/pipelines')) {
          pipelineReads++;
          return pipelineReads == 1
              ? _pipelineResponse(1, status: 'failed')
              : pipelineRefresh.future;
        }
        if (request.uri.path.endsWith('/projects/1/pipelines/101')) {
          return jsonResponse(_pipelineJson(1, status: 'failed'));
        }
        return jsonResponse({}, status: 404);
      });
      final account = _account();
      final api = _boundApi(adapter, account, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      await tester.pumpWidget(workspaceHost(const SizedBox()));
      await tester.pump();

      now = now.add(const Duration(seconds: 61));
      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () =>
            pipelineReads == 2 &&
            _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      expect(_statusText(1, '失敗'), findsOneWidget);

      await tester.tap(_stateFinder(1, ProjectCiLoadState.known));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      pipelineRefresh.complete(
        jsonResponse({'message': 'denied'}, status: 403),
      );
      await settleNetworkWidgets(tester);
      expect(
        find.byKey(
          const ValueKey('ci-overview-state-1-error'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(_requestCount(adapter, '/projects/1/pipelines'), 2);
    },
  );

  testWidgets(
    'fixture=one project cache=warm viewport=800x2400 clock=fixed completion=refresh done: explicit refresh sends exactly one request per endpoint',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.utc(2026, 10, 23, 12);
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          return jsonResponse([projectJson(1)]);
        }
        if (request.uri.path.endsWith('/projects/1/pipelines')) {
          return _pipelineResponse(1);
        }
        return jsonResponse({}, status: 404);
      });
      final account = _account();
      final api = _boundApi(adapter, account, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );

      await tester.tap(find.byIcon(Icons.refresh));
      await pumpUntil(
        tester,
        () =>
            _requestCount(adapter, '/projects') == 2 &&
            _requestCount(adapter, '/projects/1/pipelines') == 2,
      );

      expect(_requestCount(adapter, '/projects'), 2);
      expect(_requestCount(adapter, '/projects/1/pipelines'), 2);
      expect(_stateFinder(1, ProjectCiLoadState.known), findsOneWidget);
    },
  );

  testWidgets(
    'fixture=two projects mixed row freshness viewport=800x2400 clock=after project freshness completion=covered background released then return: hidden result is not applied and only stale rows resume once',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 23, 12);
      final projectsRefresh = Completer<ResponseBody>();
      var projectReads = 0;
      var pipelineReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          projectReads++;
          return projectReads == 1
              ? jsonResponse([projectJson(1), projectJson(2)])
              : projectsRefresh.future;
        }
        if (RegExp(r'/projects/\d+/pipelines$').hasMatch(request.uri.path)) {
          pipelineReads++;
          final id = request.uri.path.contains('/projects/1/') ? 1 : 2;
          return _pipelineResponse(id, status: 'failed');
        }
        if (request.uri.path.endsWith('/projects/1/pipelines/101')) {
          return jsonResponse(_pipelineJson(1, status: 'failed'));
        }
        return jsonResponse({}, status: 404);
      });
      final account = _account();
      final api = _boundApi(adapter, account, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () =>
            _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty &&
            _stateFinder(2, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      expect(projectReads, 1);
      expect(pipelineReads, 2);

      await tester.pumpWidget(workspaceHost(const SizedBox()));
      await tester.pump();
      now = now.add(const Duration(seconds: 30));
      await tester.runAsync(
        () => CachedRead.run(
          () => api.cachedRecords(
            ['projects', '1', 'pipelines'],
            query: {'per_page': '1'},
            fresh: true,
          ),
          mayStart: () => true,
        ),
      );
      expect(_requestCount(adapter, '/projects/1/pipelines'), 2);
      expect(_requestCount(adapter, '/projects/2/pipelines'), 1);
      now = now.add(const Duration(seconds: 31));
      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(tester, () => projectReads == 2);

      await tester.tap(_stateFinder(1, ProjectCiLoadState.known));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(Scaffold, skipOffstage: false), findsNWidgets(2));
      final coveredOverview = tester.element(
        find.byType(CiOverviewPage, skipOffstage: false),
      );
      expect(ModalRoute.of(coveredOverview)?.isCurrent, isFalse);

      projectsRefresh.complete(
        jsonResponse([
          projectJson(1),
          _namedProjectJson(2, 'Refreshed project'),
        ]),
      );
      await settleNetworkWidgets(tester);

      expect(pipelineReads, 3);
      expect(_requestCount(adapter, '/projects/1/pipelines'), 2);
      expect(_requestCount(adapter, '/projects/2/pipelines'), 1);
      expect(find.text('Refreshed project', skipOffstage: false), findsNothing);

      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pump();
      await pumpUntil(
        tester,
        () =>
            find.text('Refreshed project').evaluate().isNotEmpty &&
            pipelineReads == 4,
      );
      expect(projectReads, 2);
      expect(_requestCount(adapter, '/projects/1/pipelines'), 2);
      expect(_requestCount(adapter, '/projects/2/pipelines'), 2);
    },
  );

  testWidgets(
    'fixture=one failed project cache=warm viewport=800x2400 clock=inside freshness completion=pipeline return: return sends zero overview requests',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.utc(2026, 10, 23, 12);
      var projectReads = 0;
      var pipelineReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          projectReads++;
          return jsonResponse([projectJson(1)]);
        }
        if (request.uri.path.endsWith('/projects/1/pipelines')) {
          pipelineReads++;
          return _pipelineResponse(1, status: 'failed');
        }
        if (request.uri.path.endsWith('/projects/1/pipelines/101')) {
          return jsonResponse(_pipelineJson(1, status: 'failed'));
        }
        return jsonResponse({}, status: 404);
      });
      final account = _account();
      final api = _boundApi(adapter, account, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );

      await tester.tap(_stateFinder(1, ProjectCiLoadState.known));
      await tester.pump();
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(_stateFinder(1, ProjectCiLoadState.known), findsOneWidget);
      expect(_statusText(1, '失敗'), findsOneWidget);
      expect(projectReads, 1);
      expect(pipelineReads, 1);
    },
  );

  testWidgets(
    'fixture=one stale row with background admission occupied viewport=800x2400 clock=mixed freshness completion=covered queue released then return: hidden queued row sends zero requests and resumes exactly once',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 23, 12);
      final occupied = Completer<void>();
      var blockerReads = 0;
      var projectReads = 0;
      var pipelineReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.contains('/projects/8/issues/')) {
          blockerReads++;
          return occupied.future.then((_) => jsonResponse({'id': 1}));
        }
        if (request.uri.path.endsWith('/projects')) {
          projectReads++;
          return jsonResponse([projectJson(1)]);
        }
        if (request.uri.path.endsWith('/projects/1/pipelines')) {
          pipelineReads++;
          return _pipelineResponse(
            1,
            status: pipelineReads == 1 ? 'failed' : 'success',
          );
        }
        if (request.uri.path.endsWith('/projects/1/pipelines/101')) {
          return jsonResponse(_pipelineJson(1, status: 'failed'));
        }
        return jsonResponse({}, status: 404);
      });
      final account = _account();
      final api = _boundApi(adapter, account, clock: () => now);
      addTearDown(api.close);

      Widget queuedHost(bool visible) => workspaceHost(
        TickerMode(
          enabled: visible,
          child: CiOverviewPage(
            key: const ValueKey('queued-ci-overview'),
            account: account,
            api: api,
          ),
        ),
      );

      await tester.pumpWidget(queuedHost(true));
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      await tester.pumpWidget(workspaceHost(const SizedBox()));
      await tester.pump();

      now = now.add(const Duration(seconds: 30));
      await tester.runAsync(
        () => CachedRead.run(
          () => api.cachedRecords(
            ['projects'],
            query: {
              'membership': 'true',
              'order_by': 'last_activity_at',
              'sort': 'desc',
            },
            fresh: true,
          ),
          mayStart: () => true,
        ),
      );
      now = now.add(const Duration(seconds: 31));

      final blockers = [
        for (var id = 1; id <= 4; id++)
          api.cachedRecord(
            ['projects', '8', 'issues', '$id'],
            fresh: true,
            background: true,
          ),
      ];
      await pumpUntil(tester, () => blockerReads == 4);

      await tester.pumpWidget(queuedHost(true));
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );
      expect(projectReads, 2);
      expect(pipelineReads, 1);

      await tester.pumpWidget(queuedHost(false));
      await tester.pump();

      occupied.complete();
      await settleNetworkWidgets(tester);
      await tester.runAsync(() => Future.wait(blockers));
      expect(pipelineReads, 1, reason: 'hidden queued row must send no HTTP');

      await tester.pumpWidget(queuedHost(true));
      await pumpUntil(
        tester,
        () => pipelineReads == 2 && _statusText(1, '失敗').evaluate().isEmpty,
      );
      await settleNetworkWidgets(tester);
      expect(projectReads, 2);
      expect(
        pipelineReads,
        2,
        reason: 'visibility resumes exactly one row read',
      );
      expect(_statusText(1, '失敗'), findsNothing);
    },
  );

  testWidgets(
    'fixture=one project without pipeline cache=warm viewport=800x2400 clock=inside freshness completion=project return: return sends zero overview requests',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.utc(2026, 10, 23, 12);
      var projectReads = 0;
      var overviewPipelineReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects')) {
          projectReads++;
          return jsonResponse([projectJson(1)]);
        }
        if (request.uri.path.endsWith('/projects/1/pipelines') &&
            request.uri.queryParameters['per_page'] == '1') {
          overviewPipelineReads++;
          return jsonResponse([]);
        }
        if (request.uri.path.endsWith('/projects/1/pipelines')) {
          return jsonResponse([]);
        }
        if (request.uri.path.endsWith('/projects/1')) {
          return jsonResponse(projectJson(1));
        }
        return jsonResponse({}, status: 404);
      });
      final account = _account();
      final api = _boundApi(adapter, account, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(CiOverviewPage(account: account, api: api)),
      );
      await pumpUntil(
        tester,
        () => _stateFinder(1, ProjectCiLoadState.known).evaluate().isNotEmpty,
      );

      await tester.tap(_stateFinder(1, ProjectCiLoadState.known));
      await tester.pump();
      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(_stateFinder(1, ProjectCiLoadState.known), findsOneWidget);
      expect(projectReads, 1);
      expect(overviewPipelineReads, 1);
    },
  );
}

Account _account({int userId = 1}) => Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: GitLabUser(id: userId, username: 'dev$userId', name: 'Developer'),
  token: 'token',
);

Map<String, Object?> _namedProjectJson(int id, String name) => {
  ...projectJson(id),
  'name': name,
};

ResponseBody _pipelineResponse(int id, {String status = 'running'}) =>
    jsonResponse([_pipelineJson(id, status: status)]);

Map<String, Object?> _pipelineJson(int id, {String status = 'running'}) => {
  'id': 100 + id,
  'status': status,
  'ref': 'main',
  'sha': '1234567890abcdef',
  'updated_at': '2026-10-23T12:00:00Z',
};

GitLabApi _boundApi(
  FakeAdapter adapter,
  Account account, {
  required DateTime Function() clock,
}) {
  final api = GitLabApi(
    instance: account.instance,
    token: account.token,
    dio: Dio()..httpClientAdapter = adapter,
    readCacheClock: clock,
  );
  api.bindReadCache(account.key, 1);
  return api;
}

Finder _stateFinder(int id, ProjectCiLoadState state) =>
    find.byKey(ValueKey('ci-overview-state-$id-${state.name}'));

Finder _statusText(int id, String text) => find.descendant(
  of: _stateFinder(id, ProjectCiLoadState.known),
  matching: find.text(text),
);

int _requestCount(FakeAdapter adapter, String suffix) => adapter.requests
    .where(
      (request) => request.method == 'GET' && request.uri.path.endsWith(suffix),
    )
    .length;
