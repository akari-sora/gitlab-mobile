import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  testWidgets('project card is one button labelled with name, visibility and age', (tester) async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    await tester.pumpWidget(workspaceHost(ProjectsPage(session: session)));
    await settleWorkspace(tester);
    final node = tester.getSemantics(find.byType(SemanticButton));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.label, 'Mobile Workspace · studio/mobile-workspace · A focused space for code, reviews and delivery. · 私有 · ${relativeDate('2026-09-19T08:30:00Z')}');
    await tester.tap(find.descendant(of: find.byType(SemanticButton), matching: find.byType(InkWell)).first);
    await settleWorkspace(tester);
    expect(find.text('檔案'), findsOneWidget);
    expect(find.text('studio/mobile-workspace'), findsWidgets);
  });

  testWidgets('same-named projects stay distinct when the namespace or archive state differs', (tester) async {
    final fixture = _SameNameProjects();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    await tester.pumpWidget(workspaceHost(ProjectsPage(session: session)));
    await settleWorkspace(tester);
    final labels = tester.widgetList<SemanticButton>(find.byType(SemanticButton)).map((button) => button.label).toList();
    expect(labels.singleWhere((label) => label.contains('alpha/app')), contains('已封存'));
    expect(labels.singleWhere((label) => label.contains('beta/app')), isNot(contains('已封存')));
    expect(labels.where((label) => label.startsWith('App ·')), hasLength(2));
    await tester.tap(find.text('alpha').first);
    await settleWorkspace(tester);
    expect(find.text('alpha/app'), findsOneWidget);
    expect(find.text('已封存 · 唯讀'), findsOneWidget);
  });

  testWidgets('pipeline card is one button labelled with id, status and ref', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(Scaffold(body: PipelinesTab(
      account: fixture.account, api: fixture.api, project: fixture.project,
    ))));
    await settleWorkspace(tester);
    final node = tester.getSemantics(find.byType(SemanticButton));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.label, 'Pipeline #99 · 成功 · main · aaaaaaaa');
    await tester.tap(find.descendant(of: find.byType(SemanticButton), matching: find.byType(InkWell)).first);
    await settleWorkspace(tester);
    expect(find.text('Flutter tests'), findsOneWidget);
  });

  testWidgets('job card is one button labelled with name, status and stage', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(PipelinePage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 99,
    )));
    await settleWorkspace(tester);
    final node = tester.getSemantics(find.byWidgetPredicate(
      (widget) => widget is SemanticButton && widget.label == 'Flutter tests · 成功 · verify',
    ));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.label, 'Flutter tests · 成功 · verify');
    final manual = tester.getSemantics(find.byWidgetPredicate(
      (widget) => widget is SemanticButton && widget.label == 'Manual deploy · 等待手動啟動 · verify',
    ));
    expect(manual.flagsCollection.isButton, isTrue);
    expect(manual.label, 'Manual deploy · 等待手動啟動 · verify');
    await tester.tap(find.descendant(
      of: find.byWidgetPredicate((widget) => widget is SemanticButton && widget.label == 'Flutter tests · 成功 · verify'),
      matching: find.byType(InkWell),
    ));
    await settleWorkspace(tester);
    expect(find.byTooltip('重新讀取 Log'), findsOneWidget);
  });
}

class _SameNameProjects extends WorkspaceFixture {
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final start = segments.indexOf('v4');
    final joined = segments.skip(start + 1).join('/');
    if (joined == 'projects' && request.method == 'GET') {
      return jsonResponse([
        {
          'id': 1, 'name': 'App', 'path_with_namespace': 'alpha/app', 'description': 'Alpha copy',
          'visibility': 'private', 'archived': true, 'last_activity_at': '2026-09-19T08:30:00Z',
        },
        {
          'id': 2, 'name': 'App', 'path_with_namespace': 'beta/app', 'description': 'Beta copy',
          'visibility': 'private', 'archived': false, 'last_activity_at': '2026-09-19T08:30:00Z',
        },
      ]);
    }
    return super.respond(request);
  }
}
