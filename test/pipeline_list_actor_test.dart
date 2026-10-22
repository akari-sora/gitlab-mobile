import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';

import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  testWidgets(
    'pipeline summaries render before bounded executor details finish',
    (tester) async {
      final fixture = _HeldPipelineActorsFixture(projectId: 42, userId: 7);
      addTearDown(fixture.api.close);

      await tester.pumpWidget(
        workspaceHost(
          Scaffold(
            body: PipelinesTab(
              account: fixture.account,
              api: fixture.api,
              project: fixture.project,
            ),
          ),
        ),
      );
      await settleWorkspace(tester);

      expect(find.text('Owner 7 pipeline 1'), findsOneWidget);
      expect(find.text('@runner-1'), findsNothing);
      expect(fixture.detailRequests, 4);
      expect(fixture.maxActiveDetails, 4);

      fixture.complete(1, username: 'runner-1');
      await settleWorkspace(tester);

      expect(find.text('@runner-1'), findsOneWidget);
      expect(fixture.detailRequests, 5);
      expect(fixture.maxActiveDetails, 4);

      await fixture.releaseAll(tester);
    },
  );

  testWidgets(
    'pending executor from previous owner and project never appears',
    (tester) async {
      final oldFixture = _HeldPipelineActorsFixture(projectId: 42, userId: 7);
      final newFixture = _HeldPipelineActorsFixture(projectId: 84, userId: 8);
      addTearDown(oldFixture.api.close);
      addTearDown(newFixture.api.close);

      Widget subject(_HeldPipelineActorsFixture fixture) => workspaceHost(
        Scaffold(
          body: PipelinesTab(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
          ),
        ),
      );

      await tester.pumpWidget(subject(oldFixture));
      await settleWorkspace(tester);
      expect(find.text('Owner 7 pipeline 1'), findsOneWidget);
      expect(oldFixture.detailRequests, 4);

      await tester.pumpWidget(subject(newFixture));
      await settleWorkspace(tester);
      expect(find.text('Owner 8 pipeline 1'), findsOneWidget);
      expect(find.text('Owner 7 pipeline 1'), findsNothing);

      oldFixture.complete(1, username: 'stale-runner');
      await settleWorkspace(tester);
      expect(find.text('@stale-runner'), findsNothing);

      newFixture.complete(1, username: 'fresh-runner');
      await settleWorkspace(tester);
      expect(find.text('@fresh-runner'), findsOneWidget);

      await oldFixture.releaseAll(tester);
      await newFixture.releaseAll(tester);
    },
  );
}

final class _HeldPipelineActorsFixture extends WorkspaceFixture {
  _HeldPipelineActorsFixture({required this.projectId, required this.userId});

  final int projectId;
  final int userId;
  final detailCompleters = <int, Completer<ResponseBody>>{};
  int activeDetails = 0;
  int maxActiveDetails = 0;
  int detailRequests = 0;

  @override
  Account get account => Account(
    instance: api.instance,
    user: GitLabUser(
      id: userId,
      username: 'owner-$userId',
      name: 'Owner $userId',
    ),
    token: 'synthetic-test-token',
  );

  @override
  Project get project => Project.fromJson({
    ...projectRecord,
    'id': projectId,
    'name': 'Project $projectId',
    'path_with_namespace': 'studio/project-$projectId',
  });

  void complete(int pipelineId, {String? username}) {
    final completer = detailCompleters[pipelineId];
    if (completer == null || completer.isCompleted) return;
    completer.complete(
      jsonResponse({
        'id': pipelineId,
        'user': {
          'id': pipelineId + 100,
          'name': username ?? 'Runner $pipelineId',
          'username': username ?? 'runner-$pipelineId',
        },
      }),
    );
  }

  Future<void> releaseAll(WidgetTester tester) async {
    var stableCycles = 0;
    for (var cycle = 0; cycle < 40 && stableCycles < 3; cycle++) {
      for (final id in detailCompleters.keys.toList()) {
        complete(id);
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      if (activeDetails == 0 &&
          detailCompleters.values.every((completer) => completer.isCompleted)) {
        stableCycles++;
      } else {
        stableCycles = 0;
      }
    }
    expect(activeDetails, 0);
    await tester.pumpAndSettle();
  }

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final v4 = segments.indexOf('v4');
    final path = segments.skip(v4 + 1).toList();
    if (path.join('/') == 'projects/$projectId/pipelines') {
      return jsonResponse([
        for (var id = 1; id <= 6; id++)
          {
            'id': id,
            'name': 'Owner $userId pipeline $id',
            'ref': 'main',
            'sha': WorkspaceFixture.sha,
            'status': 'success',
            'updated_at': '2026-09-19T08:30:00Z',
          },
      ]);
    }
    if (path.length == 4 &&
        path[0] == 'projects' &&
        path[1] == '$projectId' &&
        path[2] == 'pipelines') {
      detailRequests++;
      activeDetails++;
      if (activeDetails > maxActiveDetails) maxActiveDetails = activeDetails;
      final id = int.parse(path[3]);
      final completer = detailCompleters.putIfAbsent(
        id,
        Completer<ResponseBody>.new,
      );
      return completer.future.whenComplete(() => activeDetails--);
    }
    return super.respond(request);
  }
}
