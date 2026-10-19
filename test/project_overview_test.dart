import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';

import 'support/fake_adapter.dart';
import 'support/shell_nav.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

/// Counts, license and a star toggle on top of the shared workspace fixture.
final class _OverviewFixture extends WorkspaceFixture {
  bool starred = false;
  int starWrites = 0;

  /// Extra fields merged into the project read, such as feature switches.
  Map<String, dynamic> features = const {};

  @override
  Future<ResponseBody> respond(RequestOptions request) async {
    final path = _apiPath(request);
    if (path == 'projects/42' && request.method == 'GET') {
      return jsonResponse({
        ...projectRecord,
        'star_count': starred ? 8 : 7,
        'forks_count': 3,
        'open_issues_count': 5,
        'license': {'key': 'gpl-3.0', 'name': 'GNU General Public License v3.0', 'nickname': 'GPL-3.0'},
        ...features,
      });
    }
    if (path == 'projects/42/starrers') {
      return jsonResponse(starred ? [{'user': {'id': 7, 'username': 'developer'}}] : <Object>[]);
    }
    if ((path == 'projects/42/star' || path == 'projects/42/unstar') && request.method == 'POST') {
      starWrites++;
      starred = path.endsWith('/star');
      return jsonResponse({...projectRecord, 'star_count': starred ? 8 : 7});
    }
    return super.respond(request);
  }
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('a project lands on a GitHub-style overview with counts, rows and the README', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(
      ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project),
    ));
    await settleNetworkWidgets(tester);

    expect(find.byType(ProjectOverview), findsOneWidget);
    expect(find.byType(TabBar), findsNothing, reason: 'the overview is a hub, not a tab');
    expect(find.text('studio/mobile-workspace'), findsOneWidget);
    expect(find.byKey(const ValueKey('project-overview-name')), findsOneWidget);
    expect(find.text('Mobile Workspace'), findsWidgets);
    expect(find.text('A focused space for code, reviews and delivery.'), findsOneWidget);
    expect(find.text('https://example.com/gitlab/studio/mobile-workspace'), findsOneWidget);
    expect(find.text('7'), findsOneWidget, reason: 'star count');
    expect(find.text('3'), findsOneWidget, reason: 'fork count');
    expect(find.text('5'), findsOneWidget, reason: 'open issues on the 議題 row');
    for (final row in ['議題', '合併請求', 'CI/CD', '更多', '目前分支', '檔案', '提交紀錄']) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    await tester.scrollUntilVisible(find.text('Focused collaboration, built for your phone.'), 200);
    expect(find.text('README.md'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('rows open the sections and the dashboard button returns to the overview', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture();
    fixture.issues[1] = fixture.issue(1, 'Overview issue');
    addTearDown(fixture.api.close);
    final sections = <int>[];
    await tester.pumpWidget(workspaceHost(ProjectPage(
      account: fixture.account, api: fixture.api, project: fixture.project, onTabChanged: sections.add,
    )));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('議題'));
    await settleNetworkWidgets(tester);
    expect(find.byType(TabBar), findsOneWidget);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    expect(find.text('Overview issue'), findsOneWidget);
    expect(sections.last, 1, reason: 'a list-detail parent learns about the nested section');
    expect(find.byType(ProjectOverview), findsNothing, reason: 'the overview steps aside');

    await tester.tap(find.byKey(const ValueKey('project-open-overview')));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectOverview), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
    expect(sections.last, 0);

    // The same section again still reports itself.
    await tester.tap(find.text('議題'));
    await settleNetworkWidgets(tester);
    expect(sections.last, 1);
    expect(find.text('Overview issue'), findsOneWidget);

    await openProjectTab(tester, '檔案');
    expect(find.byType(RepositoryTab), findsOneWidget);
    expect(find.text('lib'), findsOneWidget);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('a section slides in over the overview and slides away to uncover it', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project)));
    await settleNetworkWidgets(tester);
    Offset slide(Finder inside) => tester.widget<SlideTransition>(find.ancestor(
      of: inside, matching: find.byType(SlideTransition, skipOffstage: false)).first).position.value;

    await tester.tap(find.text('議題'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(slide(find.byKey(const ValueKey('project-tab-body'))).dx, greaterThan(0));
    await settleNetworkWidgets(tester);
    expect(slide(find.byKey(const ValueKey('project-tab-body'))), Offset.zero);

    await tester.tap(find.byKey(const ValueKey('project-open-overview')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(slide(find.byKey(const ValueKey('project-tab-body'))).dx, greaterThan(0),
      reason: 'the section leaves towards the trailing edge');
    expect(slide(find.byKey(const ValueKey('project-overview-name'))), Offset.zero,
      reason: 'the overview is already in place underneath');
    await settleNetworkWidgets(tester);
    expect(slide(find.byKey(const ValueKey('project-overview-name'))), Offset.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows for switched-off features are left out', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture()..features = {
      'merge_requests_access_level': 'disabled',
      'jobs_enabled': false,
      'wiki_enabled': true,
      'wiki_access_level': 'disabled',
      'releases_access_level': 'enabled',
    };
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project)));
    await settleNetworkWidgets(tester);
    expect(find.text('議題'), findsOneWidget);
    expect(find.text('合併請求'), findsNothing);
    expect(find.text('CI/CD'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('project-overview-more')));
    await settleNetworkWidgets(tester);
    expect(find.text('Wiki'), findsNothing);
    expect(find.text('Releases'), findsOneWidget);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('更多 expands in place and 所有功能 opens the More tab', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(
      ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project),
    ));
    await settleNetworkWidgets(tester);
    expect(find.text('成員'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('project-overview-more')));
    await settleNetworkWidgets(tester);
    for (final row in ['成員', '專案動態', 'Wiki', 'Releases', '授權', '所有功能']) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    expect(find.text('GPL-3.0'), findsOneWidget);

    await tester.ensureVisible(find.text('所有功能'));
    await tester.pump();
    await tester.tap(find.text('所有功能'));
    await settleNetworkWidgets(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 4);
    expect(find.text('專案分析'), findsOneWidget);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('the overview star shares one state and one write with the header and More tab', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(
      ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project),
    ));
    await settleNetworkWidgets(tester);
    final star = find.byKey(const ValueKey('project-overview-star'));
    expect(find.descendant(of: star, matching: find.text('加入星標')), findsOneWidget);

    await tester.tap(star);
    await settleNetworkWidgets(tester);
    expect(fixture.starWrites, 1);
    expect(fixture.starred, isTrue);
    expect(find.descendant(of: star, matching: find.text('已加星標')), findsOneWidget);
    expect(find.text('8'), findsOneWidget, reason: 'the count follows the write');
    expect(find.text('已加入星標'), findsOneWidget);

    await openProjectTab(tester, '更多');
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('project-header-star'))).tooltip, '移除星標');
    expect(fixture.starWrites, 1, reason: 'opening the sections does not write again');
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('the overview title appears in the app bar only after the header scrolls away', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(
      ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project),
    ));
    await settleNetworkWidgets(tester);
    final barTitle = find.descendant(of: find.byType(AppBar), matching: find.text('Mobile Workspace'));
    expect(barTitle, findsNothing);
    await tester.drag(find.byType(ProjectOverview), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(barTitle, findsOneWidget);
    await tester.drag(find.byType(ProjectOverview), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(barTitle, findsNothing);
  });

  testWidgets('a hidden files tab does not hold back while the overview is shown', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture();
    addTearDown(fixture.api.close);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('below')),
    ));
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project, initialTab: 0),
    )));
    await settleNetworkWidgets(tester);
    // Inside a folder the files tab owns back to go one level up.
    await tester.tap(find.text('lib'));
    await settleNetworkWidgets(tester);
    expect(find.text('根目錄'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project-open-overview')));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectOverview), findsOneWidget);
    // On the overview, back leaves the project instead of changing folders.
    expect(await tester.binding.handlePopRoute(), isTrue);
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsNothing);
    expect(find.text('below'), findsOneWidget);
  });

  testWidgets('an explicit section (resume targets, CI) skips the overview', (tester) async {
    _phone(tester);
    final fixture = _OverviewFixture();
    fixture.issues[2] = fixture.issue(2, 'Resume issue');
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(ProjectPage(
      account: fixture.account, api: fixture.api, project: fixture.project, initialTab: 1,
    )));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectOverview), findsNothing);
    expect(find.text('Resume issue'), findsOneWidget);
    await tester.tap(find.text('Resume issue'));
    await settleNetworkWidgets(tester);
    expect(find.byType(WorkItemPage), findsOneWidget);
    expect(fixture.unhandled, isEmpty);
  });
}
