import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_overview_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart' show pumpUntil;
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
    jsonResponse([
      {
        'id': 100 + id,
        'status': status,
        'ref': 'main',
        'sha': '1234567890abcdef',
        'updated_at': '2026-10-23T12:00:00Z',
      },
    ]);

Finder _stateFinder(int id, ProjectCiLoadState state) =>
    find.byKey(ValueKey('ci-overview-state-$id-${state.name}'));

int _requestCount(FakeAdapter adapter, String suffix) => adapter.requests
    .where(
      (request) => request.method == 'GET' && request.uri.path.endsWith(suffix),
    )
    .length;
