import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart' show Json;
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Future<BuildInfo> _shellBuildInfo() async => const BuildInfo(
  version: '0.4.0',
  buildNumber: '4',
  commit: 'shell_adaptive_test',
);

void main() {
  late MemoryAppearanceStore appearanceStore;
  late AppearanceController appearance;
  late LauncherShortcuts shortcuts;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    appearanceStore = MemoryAppearanceStore();
    appearance = AppearanceController(appearanceStore);
    shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
  });

  tearDown(() {
    appearance.dispose();
    shortcuts.dispose();
  });

  group('R5: AuthenticatedApp Shell Adaptive End-to-End Test Suite', () {
    testWidgets('Scenario 1: Full hierarchy resize continuity across 412 -> 840 -> 412 dp and 599 <-> 600 dp', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Shell Integration Issue 42');
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _shellBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // 1. Enter Project A in Compact mode (412 dp)
      expect(find.text('Mobile Workspace'), findsOneWidget);
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // 2. Switch to 議題 tab (WorkItemsTab)
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);
      expect(find.text('Shell Integration Issue 42'), findsOneWidget);

      // 3. Select Issue 42 -> enters detail view
      await tester.tap(find.text('Shell Integration Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // 4. Dynamic resize: 412 -> 840 dp (Compact -> Two-Pane)
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // NavigationRail is visible at >= 600 dp, NavigationBar is hidden
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // ProjectsPage is in Two-Pane (adaptive-two-pane-row found)
      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsWidgets);

      // Right pane shows ProjectPage, with 議題 tab still active
      expect(find.text('Shell Integration Issue 42'), findsOneWidget);
      // WorkItemsTab is also in Two-Pane, right pane showing Issue 42 Overview
      expect(find.text('Overview'), findsOneWidget);

      // 5. Dynamic resize: 840 -> 412 dp (Two-Pane -> Compact)
      tester.view.physicalSize = const Size(412, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // NavigationBar restored, Issue 42 Overview still active full-screen
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('Overview'), findsOneWidget);

      // 6. Dynamic resize: crossing 599 <-> 600 dp boundary (P1-1 check)
      tester.view.physicalSize = const Size(599, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      tester.view.physicalSize = const Size(600, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      tester.view.physicalSize = const Size(599, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Scenario 2: Two-stage system back via handlePopRoute() pops Issue 42 first then Project A', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Shell Integration Issue 42');
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _shellBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // Navigate to Project A -> Issues -> Issue 42
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Shell Integration Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // First system back: tester.binding.handlePopRoute()
      final handledFirst = await tester.binding.handlePopRoute();
      expect(handledFirst, isTrue, reason: 'First system back must be handled by Issue 42 detail');
      await settleNetworkWidgets(tester);

      // Verify: Issue 42 detail is dismissed, stayed on Project A\'s Issues tab!
      expect(find.text('Overview'), findsNothing, reason: 'Issue 42 detail must be dismissed');
      expect(find.text('Shell Integration Issue 42'), findsOneWidget, reason: 'Issues list must be visible');
      expect(find.text('檔案'), findsOneWidget, reason: 'Project A tabs must remain intact');
      expect(find.byKey(const Key('projectSearch')), findsNothing, reason: 'Must NOT have jumped back to Projects list');

      // Second system back: pops Project A
      final handledSecond = await tester.binding.handlePopRoute();
      expect(handledSecond, isTrue, reason: 'Second system back must be handled by Project A detail');
      await settleNetworkWidgets(tester);

      // Verify: Project A is dismissed, back to Projects list
      expect(find.byKey(const Key('projectSearch')), findsOneWidget, reason: 'Must return to Projects list');
      expect(find.text('Mobile Workspace'), findsOneWidget);
      expect(find.text('檔案'), findsNothing, reason: 'Project A must be dismissed');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Scenario 3: IndexedStack back isolation ensures non-active tabs do not intercept or clear details', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Shell Integration Issue 42');
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _shellBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // 1. In Projects tab, navigate to Project A -> Issues -> Issue 42
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Shell Integration Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // 2. Switch to CI tab (index 2)
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('CI')));
      await settleNetworkWidgets(tester);
      expect(find.text('選擇專案，查看流程與工作紀錄'), findsOneWidget);

      // 3. Trigger system back while on CI tab
      final handled = await tester.binding.handlePopRoute();
      expect(handled, isTrue, reason: 'System back should switch back to default Projects tab');
      await settleNetworkWidgets(tester);

      // 4. Verify: We are back on Projects tab, AND Issue 42 detail is STILL INTACT!
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
      expect(find.text('Overview'), findsOneWidget, reason: 'Issue 42 detail must NOT have been cleared while tab was inactive');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Scenario 4: Pagination persistence across 1000 -> 800 -> 1000 dp resize and detail back navigation', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1000, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      int projectsRequestCount = 0;
      final fixture = WorkspaceFixture();

      // Generate 6 test projects across 2 pages
      final page1Projects = List<Json>.generate(3, (i) => {
        'id': 101 + i,
        'name': 'Alpha Project ${i + 1}',
        'path_with_namespace': 'group/alpha-project-${i + 1}',
        'visibility': 'private',
        'default_branch': 'main',
        'archived': false,
        'last_activity_at': '2026-09-19T08:30:00Z',
      });
      final page2Projects = List<Json>.generate(3, (i) => {
        'id': 104 + i,
        'name': 'Beta Project ${i + 4}',
        'path_with_namespace': 'group/beta-project-${i + 4}',
        'visibility': 'private',
        'default_branch': 'main',
        'archived': false,
        'last_activity_at': '2026-09-19T08:30:00Z',
      });

      final customAdapter = FakeAdapter((request) {
        final segments = request.uri.pathSegments;
        final start = segments.indexOf('v4');
        final path = segments.skip(start + 1).toList();
        final joined = path.join('/');

        if (joined == 'projects') {
          projectsRequestCount++;
          final page = request.uri.queryParameters['page'];
          if (page == '2') {
            return ResponseBody.fromString(
              jsonEncode(page2Projects),
              200,
              headers: {
                'content-type': ['application/json'],
              },
            );
          }
          return ResponseBody.fromString(
            jsonEncode(page1Projects),
            200,
            headers: {
              'content-type': ['application/json'],
              'x-next-page': ['2'],
            },
          );
        }
        if (path.length == 2 && path[0] == 'projects') {
          final id = int.tryParse(path[1]);
          final found = [...page1Projects, ...page2Projects].firstWhere(
            (p) => p['id'] == id,
            orElse: () => fixture.projectRecord,
          );
          return jsonResponse(found);
        }
        return fixture.respond(request);
      });

      final store = MemoryAccountStore();
      final session = controllerFor(store, customAdapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _shellBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // 1. Initial page loaded: projectsRequestCount == 1
      expect(projectsRequestCount, equals(1));
      expect(find.text('Alpha Project 1'), findsOneWidget);
      expect(find.text('Alpha Project 3'), findsOneWidget);
      expect(find.text('Beta Project 4'), findsNothing);

      // 2. Tap "載入更多" to load page 2
      expect(find.text('載入更多'), findsOneWidget);
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);

      expect(projectsRequestCount, equals(2));
      expect(find.text('Alpha Project 1'), findsOneWidget);
      expect(find.text('Beta Project 4'), findsOneWidget);
      expect(find.text('Beta Project 6'), findsOneWidget);
      expect(find.text('載入更多'), findsNothing);

      // 3. Drag/scroll list
      await tester.drag(find.text('Alpha Project 1'), const Offset(0, -100));
      await tester.pump();

      // 4. Dynamic resize: 1000 -> 800 dp (Two-Pane -> Single-Column)
      tester.view.physicalSize = const Size(800, 1200);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Assert: request count must stay at 2 (NO reload!), all items preserved
      expect(projectsRequestCount, equals(2), reason: 'Resize to 800 dp must NOT trigger re-fetch');
      expect(find.text('Beta Project 6'), findsOneWidget);

      // 5. Dynamic resize: 800 -> 1000 dp (Single-Column -> Two-Pane)
      tester.view.physicalSize = const Size(1000, 1200);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(projectsRequestCount, equals(2), reason: 'Resize back to 1000 dp must NOT trigger re-fetch');
      expect(find.text('Beta Project 6'), findsOneWidget);

      // 6. Dynamic resize: to 412 dp (phone mode)
      tester.view.physicalSize = const Size(412, 1200);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Tap Alpha Project 1 to enter detail in single-column
      await tester.tap(find.text('Alpha Project 1'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // 7. System back to return to list
      final handled = await tester.binding.handlePopRoute();
      expect(handled, isTrue);
      await settleNetworkWidgets(tester);

      // Assert: Back on list, request count is STILL 2, all items preserved without re-fetching!
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(projectsRequestCount, equals(2), reason: 'Entering and exiting detail in single column must NOT re-fetch list data!');
      expect(find.text('Beta Project 6'), findsOneWidget, reason: 'All pages of loaded items must remain in memory');
      expect(tester.takeException(), isNull);
    });
  });
}
