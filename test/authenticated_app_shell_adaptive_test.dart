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
import 'package:gitlab_mobile/shared/workspace_ui.dart' show SemanticButton;
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'support/shell_nav.dart';

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
      await openExplore(tester);

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

      // ProjectsPage is in Two-Pane with collapsed master, WorkItemsTab is in Two-Pane
      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsWidgets);

      // Both the list card on the left pane and the detail page on the right pane are onstage
      expect(find.text('Shell Integration Issue 42'), findsNWidgets(2));
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
      await pumpUntilComplete(tester, session.readCache.quiesced);
    });

    testWidgets('Scenario 2: Staged system back via handlePopRoute() pops Issue 42, then the 議題 section, then Project A', (tester) async {
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
      await openExplore(tester);

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

      // Second system back: 議題 was opened from the overview, so it returns there
      final handledSecond = await tester.binding.handlePopRoute();
      expect(handledSecond, isTrue, reason: 'Second system back must return to the Project A overview');
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('project-overview-name')), findsOneWidget, reason: 'Must be on the overview');
      expect(find.byKey(const Key('projectSearch')), findsNothing, reason: 'Project A must still be open');

      // Third system back: pops Project A
      final handledThird = await tester.binding.handlePopRoute();
      expect(handledThird, isTrue, reason: 'Third system back must be handled by Project A detail');
      await settleNetworkWidgets(tester);

      // Verify: Project A is dismissed, back to Projects list
      expect(find.byKey(const Key('projectSearch')), findsOneWidget, reason: 'Must return to Projects list');
      expect(find.descendant(of: find.byType(SemanticButton), matching: find.text('Mobile Workspace')), findsOneWidget);
      expect(find.text('檔案'), findsNothing, reason: 'Project A must be dismissed');
      expect(tester.takeException(), isNull);
      await pumpUntilComplete(tester, session.readCache.quiesced);
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
      await openExplore(tester);

      // 1. In Projects tab, navigate to Project A -> Issues -> Issue 42
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Shell Integration Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // 2. Switch to the Inbox (index 1)
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('收件匣')));
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('inbox-filter-0')), findsOneWidget);

      // 3. Trigger system back while on the Inbox
      final handled = await tester.binding.handlePopRoute();
      expect(handled, isTrue, reason: 'System back should switch back to the default Home tab');
      await settleNetworkWidgets(tester);

      // 4. Verify: We are back on Home, AND Issue 42 detail is STILL INTACT in Explore!
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
      await openExplore(tester);
      expect(find.text('Overview'), findsOneWidget, reason: 'Issue 42 detail must NOT have been cleared while tab was inactive');
      expect(tester.takeException(), isNull);
      await pumpUntilComplete(tester, session.readCache.quiesced);
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
      final page3Projects = List<Json>.generate(3, (i) => {
        'id': 107 + i,
        'name': 'Gamma Project ${i + 7}',
        'path_with_namespace': 'group/gamma-project-${i + 7}',
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

        // Home's starred-project preview is a separate read; only the Explore
        // list counts here.
        if (joined == 'projects' && request.uri.queryParameters['starred'] != 'true') {
          projectsRequestCount++;
          final page = request.uri.queryParameters['page'];
          if (page == '3') {
            return ResponseBody.fromString(
              jsonEncode(page3Projects),
              200,
              headers: {
                'content-type': ['application/json'],
              },
            );
          }
          if (page == '2') {
            return ResponseBody.fromString(
              jsonEncode(page2Projects),
              200,
              headers: {
                'content-type': ['application/json'],
                'x-next-page': ['3'],
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
          final found = [...page1Projects, ...page2Projects, ...page3Projects].firstWhere(
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
      await openExplore(tester);

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
      // Unread page 3 cursor is active and retained
      expect(find.text('載入更多'), findsOneWidget, reason: 'Unread page 3 cursor must be visible before resize/nav');

      // 3. Drag/scroll list
      await tester.drag(find.text('Alpha Project 1'), const Offset(0, -100));
      await tester.pump();

      // 4. Dynamic resize: 1000 -> 800 dp (Two-Pane -> Single-Column)
      tester.view.physicalSize = const Size(800, 1200);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Assert: request count must stay at 2 (NO reload!), all items and page 3 cursor preserved
      expect(projectsRequestCount, equals(2), reason: 'Resize to 800 dp must NOT trigger re-fetch');
      expect(find.text('Beta Project 6'), findsOneWidget);
      expect(find.text('載入更多'), findsOneWidget, reason: 'Page 3 cursor preserved across resize to 800 dp');

      // 5. Dynamic resize: 800 -> 1000 dp (Single-Column -> Two-Pane)
      tester.view.physicalSize = const Size(1000, 1200);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(projectsRequestCount, equals(2), reason: 'Resize back to 1000 dp must NOT trigger re-fetch');
      expect(find.text('Beta Project 6'), findsOneWidget);
      expect(find.text('載入更多'), findsOneWidget, reason: 'Page 3 cursor preserved across resize to 1000 dp');

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

      // 8. Verify unread page 3 cursor is still retained after returning from detail!
      expect(find.text('載入更多'), findsOneWidget, reason: 'Retained unread page 3 cursor must still be present after detail back');

      // 9. Continue pagination: Tap "載入更多" and assert page 3 loads correctly
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);

      expect(projectsRequestCount, equals(3), reason: 'Tapping load more with retained cursor loads page 3');
      expect(find.text('Gamma Project 7'), findsOneWidget);
      await tester.drag(find.text('Beta Project 6'), const Offset(0, -200));
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.text('Gamma Project 9'), findsOneWidget);
      expect(find.text('載入更多'), findsNothing, reason: 'Page 3 was the terminal page');
      expect(tester.takeException(), isNull);
      await pumpUntilComplete(tester, session.readCache.quiesced);
    });

    testWidgets('Scenario 5: P2-UX formal entry point at 840 dp and 1200 dp serves Issues list and Issue detail simultaneously with size assertions and project switching back button', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Adaptive Layout Issue 42');
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
      await openExplore(tester);

      // 1. Initial 840 dp: NavigationRail present (81 dp), NavigationBar absent
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // Select Project
      expect(find.text('Mobile Workspace'), findsOneWidget);
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // Switch to 議題 tab (WorkItemsTab)
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // 2. At 840 dp in Issues tab:
      // ProjectsPage master list is collapsed, WorkItemsTab is in Two-Pane!
      // Verify WorkItemsTab Two-Pane layout exists:
      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsOneWidget);
      final listPaneFinder = find.byKey(const ValueKey('list-pane'));
      final detailPaneExpandedFinder = find.byKey(const ValueKey('detail-pane-expanded'));
      expect(listPaneFinder, findsOneWidget);
      expect(detailPaneExpandedFinder, findsOneWidget);

      // Size assertions at 840 dp:
      // Rail width is 81 dp, total width is 840 dp.
      // Available width for WorkItemsTab is 759 dp.
      // List pane width must be 380 dp, Detail pane width must be 378 dp (>= 320 dp).
      final listPaneSize = tester.getSize(listPaneFinder);
      final detailPaneSize = tester.getSize(detailPaneExpandedFinder);
      expect(listPaneSize.width, equals(380.0));
      expect(detailPaneSize.width, greaterThanOrEqualTo(320.0));
      expect(detailPaneSize.width, equals(378.0));

      // Detail pane initially shows EmptyState ('請選擇議題')
      expect(find.text('請選擇議題'), findsOneWidget);

      // AppBar must provide clear BackButton for project switching
      expect(find.byType(BackButton), findsOneWidget);

      // 3. Select Issue 42 -> Both list card and detail overview serve simultaneously
      await tester.tap(find.text('Adaptive Layout Issue 42'));
      await settleNetworkWidgets(tester);

      // Assert simultaneous presence:
      // 1 card in the list pane on the left, 1 title in the detail pane on the right
      expect(find.text('Adaptive Layout Issue 42'), findsNWidgets(2));
      expect(find.text('Overview'), findsOneWidget);

      // Assert spatial geometry: list card is strictly to the left of detail pane
      final listCardBox = tester.getRect(find.descendant(of: find.byType(Card), matching: find.text('Adaptive Layout Issue 42')).first);
      final detailOverviewBox = tester.getRect(find.text('Overview'));
      expect(listCardBox.right, lessThan(detailOverviewBox.left));

      // 4. Dynamic resize to 1200 dp (Large tablet / desktop)
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Assert Two-Pane preserved at 1200 dp with expanded detail width
      final listPane1200 = tester.getSize(listPaneFinder);
      final detailPane1200 = tester.getSize(detailPaneExpandedFinder);
      expect(listPane1200.width, equals(380.0));
      // Available width is 1200 - 81 = 1119 dp, detail is 1119 - 380 - 1 = 738 dp >= 320 dp
      expect(detailPane1200.width, equals(738.0));
      expect(find.text('Adaptive Layout Issue 42'), findsNWidgets(2));
      expect(find.text('Overview'), findsOneWidget);

      // 5. Test interaction: tap Back button in AppBar returns to Projects list
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settleNetworkWidgets(tester);

      // Verify returned to Projects list with project search input visible
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(find.descendant(of: find.byType(SemanticButton), matching: find.text('Mobile Workspace')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await pumpUntilComplete(tester, session.readCache.quiesced);
    });
  });
}
