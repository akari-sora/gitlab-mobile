import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/pipeline_graph_page.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

final account = Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
  token: 'synthetic-test-token',
);
const project = Project(
  id: 42,
  name: 'Mobile Workspace',
  path: 'studio/mobile-workspace',
  defaultBranch: 'main',
);

Map<String, dynamic> graphJob({
  required int id,
  required String name,
  String stage = 'test',
  List<String> needs = const [],
  String status = 'SUCCESS',
  String kind = 'BUILD',
  bool retried = false,
  String schedulingType = 'DAG',
  bool needsTruncated = false,
}) => {
  'id': 'gid://gitlab/Ci::Build/$id',
  'name': name,
  'status': status,
  'kind': kind,
  'retried': retried,
  'schedulingType': schedulingType,
  'stage': {'name': stage},
  'needs': {
    'nodes': [
      for (final value in needs) {'name': value},
    ],
    'pageInfo': {'hasNextPage': needsTruncated, 'endCursor': null},
  },
};

Map<String, dynamic> graphResponse(
  List<Map<String, dynamic>> jobs, {
  bool hasNext = false,
  String? cursor,
  int projectId = 42,
  int pipelineId = 77,
}) => {
  'data': {
    'project': {
      'id': 'gid://gitlab/Project/$projectId',
      'pipeline': {
        'id': 'gid://gitlab/Ci::Pipeline/$pipelineId',
        'iid': '12',
        'stages': {
          'nodes': [
            {'name': 'build'},
            {'name': 'test'},
          ],
          'pageInfo': {'hasNextPage': false},
        },
        'jobs': {
          'nodes': jobs,
          'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
        },
      },
    },
  },
};

Widget host(Widget child, {double width = 412, double textScale = 1}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(width, 900),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: child,
    );

void main() {
  testWidgets('loads exact GraphQL identity and shows only explicit needs', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (request) => jsonResponse(
        graphResponse([
          graphJob(id: 1, name: 'compile', stage: 'build'),
          graphJob(id: 2, name: 'unit', needs: ['compile', 'not-loaded']),
          graphJob(id: 3, name: 'deploy', schedulingType: 'STAGE'),
        ]),
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      host(
        PipelineGraphPage(
          account: account,
          api: api,
          project: project,
          pipelineId: 77,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.uri.path, '/gitlab/api/graphql');
    expect(request.data, isA<Map<String, dynamic>>());
    final variables =
        (request.data as Map<String, dynamic>)['variables']
            as Map<String, dynamic>;
    expect(variables, {
      'path': 'studio/mobile-workspace',
      'pipeline': 'gid://gitlab/Ci::Pipeline/77',
      'after': null,
    });
    expect(find.text('相依關係來自 GitLab needs；階段順序不會畫成相依線。'), findsOneWidget);
    expect(find.text('compile'), findsWidgets);
    expect(find.text('尚未載入：not-loaded'), findsOneWidget);
    expect(find.text('依階段順序等待；這不是 needs 相依。'), findsOneWidget);
    expect(find.textContaining('已載入 3 個工作'), findsOneWidget);
  });

  testWidgets('page-two failure preserves jobs and retry continues cursor', (
    tester,
  ) async {
    var pageTwoAttempts = 0;
    final adapter = FakeAdapter((request) {
      final variables =
          (request.data as Map<String, dynamic>)['variables']
              as Map<String, dynamic>;
      if (variables['after'] == 'cursor-2') {
        pageTwoAttempts++;
        if (pageTwoAttempts == 1) return jsonResponse({}, status: 403);
        return jsonResponse(graphResponse([graphJob(id: 2, name: 'unit')]));
      }
      return jsonResponse(
        graphResponse(
          [graphJob(id: 1, name: 'compile')],
          hasNext: true,
          cursor: 'cursor-2',
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      host(
        PipelineGraphPage(
          account: account,
          api: api,
          project: project,
          pipelineId: 77,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('pipeline-graph-load-more')),
    );
    await tester.tap(find.byKey(const Key('pipeline-graph-load-more')));
    await settleNetworkWidgets(tester);
    expect(find.text('compile'), findsWidgets);
    expect(find.text('沒有操作權限'), findsOneWidget);

    await tester.ensureVisible(find.text('重新整理'));
    await tester.tap(find.text('重新整理'));
    await settleNetworkWidgets(tester);
    expect(find.text('compile'), findsWidgets);
    expect(find.text('unit'), findsOneWidget);
    expect(pageTwoAttempts, 2);
  });

  testWidgets('resolved need jumps and build row opens existing JobLogPage', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/api/graphql')) {
        return jsonResponse(
          graphResponse([
            graphJob(id: 1, name: 'compile'),
            graphJob(id: 2, name: 'unit', needs: ['compile']),
          ]),
        );
      }
      return jsonResponse({
        'id': 1,
        'name': 'compile',
        'status': 'success',
        'stage': 'test',
      });
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      host(
        PipelineGraphPage(
          account: account,
          api: api,
          project: project,
          pipelineId: 77,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey('pipeline-need-gid://gitlab/Ci::Build/2-compile'),
      ),
    );
    await tester.pumpAndSettle();
    final compileCard = find.byKey(
      const ValueKey('pipeline-job-gid://gitlab/Ci::Build/1'),
    );
    await tester.tap(
      find.descendant(of: compileCard, matching: find.byType(InkWell)),
    );
    await settleNetworkWidgets(tester);
    expect(find.byType(JobLogPage), findsOneWidget);
  });

  testWidgets('late old account response cannot replace current graph', (
    tester,
  ) async {
    final pending = Completer<ResponseBody>();
    final oldAdapter = FakeAdapter((_) => pending.future);
    final newAdapter = FakeAdapter(
      (_) => jsonResponse(
        graphResponse([graphJob(id: 9, name: 'current-account-job')]),
      ),
    );
    final oldApi = testApi(oldAdapter);
    final newApi = testApi(newAdapter);
    addTearDown(oldApi.close);
    addTearDown(newApi.close);

    await tester.pumpWidget(
      host(
        PipelineGraphPage(
          account: account,
          api: oldApi,
          project: project,
          pipelineId: 77,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      host(
        PipelineGraphPage(
          account: account,
          api: newApi,
          project: project,
          pipelineId: 77,
        ),
      ),
    );
    await tester.pumpAndSettle();
    pending.complete(
      jsonResponse(graphResponse([graphJob(id: 1, name: 'stale-job')])),
    );
    await tester.pumpAndSettle();

    expect(find.text('current-account-job'), findsOneWidget);
    expect(find.text('stale-job'), findsNothing);
  });

  testWidgets('manual pagination stops at the 300-job display cap', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final variables =
          (request.data as Map<String, dynamic>)['variables']
              as Map<String, dynamic>;
      final after = variables['after'] as String?;
      final page = after == null
          ? 1
          : int.parse(after.substring('cursor-'.length));
      final firstId = (page - 1) * 20 + 1;
      return jsonResponse(
        graphResponse(
          [
            for (var offset = 0; offset < 20; offset++)
              graphJob(id: firstId + offset, name: 'job-${firstId + offset}'),
          ],
          hasNext: true,
          cursor: 'cursor-${page + 1}',
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      host(
        PipelineGraphPage(
          account: account,
          api: api,
          project: project,
          pipelineId: 77,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    for (var page = 2; page <= 15; page++) {
      await tester.scrollUntilVisible(
        find.byKey(const Key('pipeline-graph-load-more')),
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('pipeline-graph-load-more')));
      await settleNetworkWidgets(tester);
    }

    expect(adapter.requests, hasLength(15));
    expect(find.byKey(const Key('pipeline-graph-load-more')), findsNothing);
    await tester.scrollUntilVisible(
      find.text('已達 300 個工作顯示上限。'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('已達 300 個工作顯示上限。'), findsOneWidget);
  });

  for (final width in [320.0, 412.0, 840.0]) {
    testWidgets('pipeline graph fits ${width.toInt()}dp at 2x text', (
      tester,
    ) async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(
          graphResponse([
            graphJob(
              id: 1,
              name: 'a very long compile job name for narrow mobile screens',
              needs: ['dependency-that-is-not-loaded-yet'],
              needsTruncated: true,
            ),
          ]),
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        host(
          PipelineGraphPage(
            account: account,
            api: api,
            project: project,
            pipelineId: 77,
          ),
          width: width,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(RegExp('工作 a very long compile job')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
