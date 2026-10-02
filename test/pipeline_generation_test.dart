import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/pipeline_graph_page.dart';
import 'support/fake_adapter.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;

Widget _host(GitLabApi api, int id) => workspaceHost(
  PipelinePage(
    key: const ValueKey('same-pipeline'),
    account: Account(
      instance: api.instance,
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
      token: 'synthetic-test-token',
    ),
    api: api,
    project: Project.fromJson(projectJson(42)),
    id: id,
  ),
);

ResponseBody _respond(RequestOptions request, int id) {
  if (request.uri.path.endsWith('/jobs')) return jsonResponse(<Object>[]);
  return jsonResponse({'id': id, 'iid': id, 'status': 'failed', 'ref': 'main'});
}

void main() {
  testWidgets('old pipeline response cannot replace new owner', (tester) async {
    final gate = Completer<void>();
    final oldApi = testApi(
      FakeAdapter((r) async {
        await gate.future;
        return _respond(r, 91);
      }),
    );
    final currentApi = testApi(FakeAdapter((r) => _respond(r, 92)));
    addTearDown(oldApi.close);
    addTearDown(currentApi.close);
    await tester.pumpWidget(_host(oldApi, 91));
    await tester.pump();
    await tester.pumpWidget(_host(currentApi, 92));
    await settleWorkspace(tester);
    gate.complete();
    await settleWorkspace(tester);
    expect(find.text('Pipeline #92'), findsOneWidget);
    expect(find.text('Pipeline #91'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'replacement removes graph descendants and action confirmation without writes',
    (tester) async {
      final oldAdapter = FakeAdapter((r) => _respond(r, 91));
      final currentAdapter = FakeAdapter((r) => _respond(r, 92));
      final oldApi = testApi(oldAdapter), currentApi = testApi(currentAdapter);
      addTearDown(oldApi.close);
      addTearDown(currentApi.close);
      await tester.pumpWidget(_host(oldApi, 91));
      await settleWorkspace(tester);
      await tester.tap(find.byTooltip('工作相依圖'));
      await settleWorkspace(tester);
      expect(find.byType(PipelineGraphPage), findsOneWidget);
      final graphContext = tester.element(find.byType(PipelineGraphPage));
      unawaited(
        Navigator.of(graphContext).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('old graph descendant')),
          ),
        ),
      );
      await settleWorkspace(tester);
      expect(find.text('old graph descendant'), findsOneWidget);
      await tester.pumpWidget(_host(currentApi, 92));
      await settleWorkspace(tester);
      expect(find.text('old graph descendant'), findsNothing);
      expect(find.byType(PipelineGraphPage), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pipeline-quick-retry-btn')));
      await settleWorkspace(tester);
      expect(find.text('重試失敗工作？'), findsOneWidget);
      await tester.pumpWidget(_host(oldApi, 91));
      await settleWorkspace(tester);
      expect(find.text('重試失敗工作？'), findsNothing);
      // The graph performs a read-only POST. All REST writes remain absent.
      expect(
        oldAdapter.requests.where(
          (r) => r.method != 'GET' && r.uri.path != '/gitlab/api/graphql',
        ),
        isEmpty,
      );
      expect(currentAdapter.requests.where((r) => r.method != 'GET'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
