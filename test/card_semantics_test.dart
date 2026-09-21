import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
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
    expect(node.label, 'Mobile Workspace · 私有 · ${relativeDate('2026-09-19T08:30:00Z')}');
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
    expect(node.label, 'Pipeline #99 · 成功 · main');
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
  });
}
