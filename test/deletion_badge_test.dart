import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  test('Project keeps marked_for_deletion_on and treats blank as absent', () {
    final marked = Project.fromJson({...projectJson(8), 'marked_for_deletion_on': '2026-10-01'});
    expect(marked.markedForDeletionOn, '2026-10-01');
    expect(Project.fromJson(projectJson(8)).markedForDeletionOn, isNull);
    expect(Project.fromJson({...projectJson(8), 'marked_for_deletion_on': ''}).markedForDeletionOn, isNull);
    expect(
      () => Project.fromJson({...projectJson(8), 'marked_for_deletion_on': 1}),
      throwsFormatException,
    );
  });

  testWidgets('project card and header show a deletion badge and mute the title', (tester) async {
    final fixture = WorkspaceFixture();
    fixture.projectRecord['marked_for_deletion_on'] = '2026-10-01';
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
    expect(find.text('待刪除'), findsOneWidget);
    final cardName = tester.widget<Text>(find.text('Mobile Workspace'));
    expect(cardName.style?.color, Theme.of(tester.element(find.text('Mobile Workspace'))).colorScheme.onSurfaceVariant);

    await tester.pumpWidget(workspaceHost(ProjectPage(
      account: fixture.account, api: fixture.api, project: fixture.project,
    )));
    await settleWorkspace(tester);
    expect(find.text('待刪除'), findsOneWidget);
    final title = tester.widget<Text>(find.text('Mobile Workspace'));
    expect(title.style?.color, Theme.of(tester.element(find.text('Mobile Workspace'))).colorScheme.onSurfaceVariant);
  });
}
