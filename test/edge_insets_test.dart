import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'support/shell_nav.dart';

void main() {
  const insets = FakeViewPadding(left: 32, top: 20, right: 18, bottom: 28);

  void useLandscapeInsets(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 400);
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  testWidgets('project detail stays inside horizontal and bottom insets', (tester) async {
    useLandscapeInsets(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(
      ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project),
    ));
    await settleNetworkWidgets(tester);
    void expectInside(Finder path, Finder body) {
      expect(tester.getTopLeft(path).dx, greaterThanOrEqualTo(insets.left));
      expect(tester.getTopRight(path).dx, lessThanOrEqualTo(800 - insets.right));
      expect(tester.getTopLeft(body).dx, greaterThanOrEqualTo(insets.left));
      expect(tester.getBottomLeft(body).dy, lessThanOrEqualTo(400 - insets.bottom + 0.1));
    }
    // The overview first, then the sections behind it.
    expectInside(find.text('studio/mobile-workspace'), find.byType(ProjectOverview));
    await openProjectTab(tester, '檔案');
    expectInside(find.text('studio/mobile-workspace'), find.byType(TabBarView));
    final safe = tester.widgetList<SafeArea>(find.byType(SafeArea)).where((area) => area.left && !area.top);
    expect(safe, isNotEmpty);
  });

  testWidgets('inbox list stays inside horizontal and bottom insets', (tester) async {
    useLandscapeInsets(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(InboxPage(account: fixture.account, api: fixture.api)));
    await settleNetworkWidgets(tester);
    final body = find.byType(TabBarView);
    expect(tester.getTopLeft(body).dx, greaterThanOrEqualTo(insets.left));
    expect(tester.getTopRight(body).dx, lessThanOrEqualTo(800 - insets.right));
    expect(tester.getBottomLeft(body).dy, lessThanOrEqualTo(400 - insets.bottom + 0.1));
  });
}
