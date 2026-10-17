import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'widget_settle.dart';

/// Taps a root destination by its label in whichever navigation the shell
/// shows: the bottom bar on phones, the rail on wider windows.
Future<void> tapDestination(WidgetTester tester, String label) async {
  final bar = find.descendant(of: find.byType(NavigationBar), matching: find.text(label));
  final rail = find.descendant(of: find.byType(NavigationRail), matching: find.text(label));
  await tester.tap(bar.evaluate().isNotEmpty ? bar : rail);
  await settleNetworkWidgets(tester);
}

/// The shell opens on 首頁; project-list flows start from 探索.
Future<void> openExplore(WidgetTester tester) => tapDestination(tester, '探索');

/// Opens a [ProjectPage] section by its tab label (檔案, 議題, MR, CI, 更多),
/// from the tab bar when it shows, otherwise through the overview rows.
Future<void> openProjectTab(WidgetTester tester, String label) async {
  final tab = find.widgetWithText(Tab, label);
  if (tab.evaluate().isNotEmpty) {
    await tester.tap(tab);
    await settleNetworkWidgets(tester);
    return;
  }
  // Overview rows are built lazily, so short windows scroll to them first.
  final overview = find.descendant(of: find.byType(ProjectOverview), matching: find.byType(Scrollable)).first;
  Future<void> tapRow(Finder row) async {
    await tester.scrollUntilVisible(row, 120, scrollable: overview);
    await tester.pump();
    await tester.tap(row);
  }
  if (label == '更多') {
    await tapRow(find.byKey(const ValueKey('project-overview-more')));
    await settleNetworkWidgets(tester);
    await tapRow(find.text('所有功能'));
  } else {
    await tapRow(find.text(const {'MR': '合併請求', 'CI': 'CI/CD'}[label] ?? label));
  }
  await settleNetworkWidgets(tester);
}
