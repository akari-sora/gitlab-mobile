import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/adaptive_breakpoints.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Widget testAdaptiveHost(Widget child) {
  return MaterialApp(
    theme: appTheme(Brightness.light),
    home: child,
  );
}

Future<BuildInfo> _dummyBuildInfo() async => const BuildInfo(
  version: '0.4.0',
  buildNumber: '4',
  commit: 'challenger2',
);

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('Empirical Challenge 1: Boundary Thresholds Stress Testing', () {
    test('Unit-level mathematical precision at boundary limits', () {
      // 599 vs 600 dp (NavigationBar vs NavigationRail)
      expect(AdaptiveBreakpoints.windowSize(599.0), AdaptiveWindowSize.compact);
      expect(AdaptiveBreakpoints.windowSize(599.999), AdaptiveWindowSize.compact);
      expect(AdaptiveBreakpoints.windowSize(600.0), AdaptiveWindowSize.medium);
      expect(AdaptiveBreakpoints.showNavigationRail(599.0), isFalse);
      expect(AdaptiveBreakpoints.showNavigationRail(599.999), isFalse);
      expect(AdaptiveBreakpoints.showNavigationRail(600.0), isTrue);

      // 839 vs 840 dp (Single-pane vs Two-pane)
      expect(AdaptiveBreakpoints.windowSize(839.0), AdaptiveWindowSize.medium);
      expect(AdaptiveBreakpoints.windowSize(839.999), AdaptiveWindowSize.medium);
      expect(AdaptiveBreakpoints.windowSize(840.0), AdaptiveWindowSize.expanded);
      expect(AdaptiveBreakpoints.showDualPane(839.0), isFalse);
      expect(AdaptiveBreakpoints.showDualPane(839.999), isFalse);
      expect(AdaptiveBreakpoints.showDualPane(840.0), isTrue);

      // 1199 vs 1200 dp (Unconstrained Two-pane vs Large 960dp constrained)
      expect(AdaptiveBreakpoints.windowSize(1199.0), AdaptiveWindowSize.expanded);
      expect(AdaptiveBreakpoints.windowSize(1199.999), AdaptiveWindowSize.expanded);
      expect(AdaptiveBreakpoints.windowSize(1200.0), AdaptiveWindowSize.large);
      expect(AdaptiveBreakpoints.isLarge(1199.0), isFalse);
      expect(AdaptiveBreakpoints.isLarge(1199.999), isFalse);
      expect(AdaptiveBreakpoints.isLarge(1200.0), isTrue);
    });

    testWidgets('Widget-level 599 dp vs 600 dp: NavigationBar and NavigationRail mutual exclusivity', (tester) async {
      final appearanceStore = MemoryAppearanceStore();
      final appearance = AppearanceController(appearanceStore);
      addTearDown(appearance.dispose);
      final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
      addTearDown(shortcuts.dispose);

      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Subtest 1: 599 dp (Compact) -> NavigationBar only, NO NavigationRail
      tester.view.physicalSize = const Size(599, 900);
      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _dummyBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.byType(NavigationBar), findsOneWidget, reason: 'At 599 dp, NavigationBar must be present');
      expect(find.byType(NavigationRail), findsNothing, reason: 'At 599 dp, NavigationRail must be absent');

      // Subtest 2: 599.9 dp -> NavigationBar only
      tester.view.physicalSize = const Size(599.9, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      // Subtest 3: 600.0 dp (Medium) -> NavigationRail only, NO NavigationBar
      tester.view.physicalSize = const Size(600, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.byType(NavigationRail), findsOneWidget, reason: 'At 600 dp, NavigationRail must be present');
      expect(find.byType(NavigationBar), findsNothing, reason: 'At 600 dp, NavigationBar must be absent');

      // Subtest 4: 840 dp -> NavigationRail only
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // Subtest 5: 1200 dp -> NavigationRail only
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // Verify mutual exclusivity across all sizes
      expect(tester.takeException(), isNull);
    });

    testWidgets('Widget-level 839 dp vs 840 dp: Single-Pane vs Two-Pane transition', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 839.0 dp: Single-pane
      tester.view.physicalSize = const Size(839, 900);
      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsNothing);
      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsNothing);
      expect(find.text('Mobile Workspace'), findsOneWidget);

      // Open detail in 839 dp
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Full screen detail with BackButton
      expect(find.byKey(const ValueKey('adaptive-compact-detail')), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsNothing);

      // 840.0 dp: Two-pane
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Dual pane row visible, search bar visible on left, detail visible on right
      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsOneWidget);
      expect(find.byType(BackButton), findsNothing, reason: 'Two-pane mode should not show full-screen back button');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Widget-level 1199 dp vs 1200 dp: Max width 960 dp constraint boundary', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 1199 dp: Expanded (not Large)
      tester.view.physicalSize = const Size(1199, 900);
      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // In 1199 dp, detail is not wrapped in detail-content-container
      expect(find.byKey(const ValueKey('detail-content-container')), findsNothing);
      // Detail pane occupies full expanded area: 1199 - 380 (master) - 1 (divider) = 818
      final detailPaneFinder = find.byKey(const ValueKey('adaptive-detail-pane'));
      expect(detailPaneFinder, findsOneWidget);
      final unconstrainedWidth = tester.getSize(detailPaneFinder).width;
      expect(unconstrainedWidth, closeTo(818.0, 1.0));

      // 1200 dp: Large (constrained by 960 dp)
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      final containerFinder = find.byKey(const ValueKey('detail-content-container'));
      expect(containerFinder, findsOneWidget, reason: 'At 1200 dp, detail pane must have detail-content-container');
      final constrainedWidth = tester.getSize(containerFinder).width;
      // In 1200 dp: available is 1200 - 380 - 1 = 819 dp, which is <= 960 dp
      expect(constrainedWidth, lessThanOrEqualTo(960.0));

      // 1600 dp: Large (available is 1600 - 381 = 1219 dp, so constrained box caps it at exactly 960 dp)
      tester.view.physicalSize = const Size(1600, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      final wideContainer = find.byKey(const ValueKey('detail-content-container'));
      expect(wideContainer, findsOneWidget);
      final cappedWidth = tester.getSize(wideContainer).width;
      expect(cappedWidth, closeTo(960.0, 0.1), reason: 'On 1600 dp screen, detail content container must be capped at 960 dp');
    });
  });

  group('Empirical Challenge 2: Empty States & Selection Integrity', () {
    testWidgets('ProjectsPage: Canonical Empty State when unselected, disappears on select, restores on delete', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Phase 1: Unselected state shows specification Empty State
      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsOneWidget);
      expect(find.text('請選擇專案'), findsOneWidget);
      expect(find.text('從左側清單選擇專案以查看詳情、檔案與流程。'), findsOneWidget);
      expect(find.byIcon(Icons.folder_open_outlined), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsNothing);

      // Phase 2: Select item -> empty state replaced by detail
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsNothing);
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);

      // Phase 3: Project deletion callback restores empty state
      // Find the ProjectPage widget and trigger onDeleted
      final projectPage = tester.widget<ProjectPage>(find.byType(ProjectPage));
      projectPage.onDeleted?.call();
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsOneWidget);
      expect(find.text('請選擇專案'), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsNothing);
    });

    testWidgets('WorkItemsTab: Issues vs MRs specification Empty States', (tester) async {
      final fixture = WorkspaceFixture();
      fixture.issues[1] = fixture.issue(1, 'Issue Alpha');
      addTearDown(fixture.api.close);

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Subtest 1: Issues empty state
      await tester.pumpWidget(testAdaptiveHost(
        Scaffold(body: WorkItemsTab(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
        )),
      ));
      await settleNetworkWidgets(tester);

      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsOneWidget);
      expect(find.text('請選擇議題'), findsOneWidget);
      expect(find.text('從左側清單選擇議題以查看內容與討論。'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('adaptive-empty-pane')), matching: find.byIcon(Icons.adjust)), findsOneWidget);

      // Subtest 2: MRs empty state
      await tester.pumpWidget(testAdaptiveHost(
        Scaffold(body: WorkItemsTab(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'merge_requests',
        )),
      ));
      await settleNetworkWidgets(tester);

      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsOneWidget);
      expect(find.text('請選擇合併請求'), findsOneWidget);
      expect(find.text('從左側清單選擇合併請求以查看變更與審查狀態。'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('adaptive-empty-pane')), matching: find.byIcon(Icons.merge)), findsOneWidget);
    });

    testWidgets('Pull-to-refresh & list feed reload does NOT disrupt or flicker active detail pane', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Select Project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      expect(find.text('檔案'), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      // Trigger pull-to-refresh on the left master list feed
      final masterFeedFinder = find.descendant(
        of: find.byKey(const ValueKey('list-pane')),
        matching: find.byType(RecordsFeed),
      );
      final feedState = tester.state<RecordsFeedState>(masterFeedFinder);
      unawaited(feedState.refresh());
      // Pump initial loading frame
      await tester.pump();

      // Right detail pane MUST remain visible without dropping to empty pane
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsOneWidget, reason: 'Detail pane must not disappear during pull-to-refresh');
      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsNothing);
      expect(find.text('檔案'), findsOneWidget);

      // Settle network requests
      await settleNetworkWidgets(tester);

      // Still visible and stable
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('List search filter updates master list while detail pane retains selection', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects') && (request.uri.queryParameters['search']?.isNotEmpty ?? false)) {
          return jsonResponse([]);
        }
        return fixture.respond(request);
      });
      final session = controllerFor(store, adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Select project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // Enter search query that matches nothing
      await tester.enterText(find.byKey(const Key('projectSearch')), 'NonExistentProjectName');
      // Wait for search debounce (350ms)
      await tester.pump(const Duration(milliseconds: 400));
      await settleNetworkWidgets(tester);

      // Master list shows empty search result
      expect(find.text('找不到符合的專案'), findsOneWidget);

      // Right pane STILL shows selected project
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);

      // Clear search query
      await tester.tap(find.byTooltip('清除搜尋'));
      await tester.pump(const Duration(milliseconds: 400));
      await settleNetworkWidgets(tester);

      // Master list restored, project still highlighted
      final masterItem = find.descendant(
        of: find.byKey(const ValueKey('list-pane')),
        matching: find.text('Mobile Workspace'),
      );
      expect(masterItem, findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Empirical Challenge 3: Account Switch & Logout State Isolation', () {
    testWidgets('AuthenticatedApp lifecycle: account switch purges selection across shell tabs in Two-Pane (1000 dp)', (tester) async {
      final appearanceStore = MemoryAppearanceStore();
      final appearance = AppearanceController(appearanceStore);
      addTearDown(appearance.dispose);
      final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
      addTearDown(shortcuts.dispose);

      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);

      final instance = fixture.api.instance;
      final accountA = Account(
        instance: instance,
        user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
        token: 'synthetic-test-token-a',
      );
      final accountB = Account(
        instance: instance,
        user: const GitLabUser(id: 8, username: 'reviewer', name: 'Reviewer'),
        token: 'synthetic-test-token-b',
      );

      final store = MemoryAccountStore()..accounts = [accountA, accountB];
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        final token = request.headers['private-token'];
        if (path.endsWith('/user')) {
          if (token == 'synthetic-test-token-a') {
            return jsonResponse({'id': 7, 'username': 'developer', 'name': 'Developer'});
          }
          if (token == 'synthetic-test-token-b') {
            return jsonResponse({'id': 8, 'username': 'reviewer', 'name': 'Reviewer'});
          }
        }
        return fixture.respond(request);
      });
      final session = controllerFor(store, adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.select(accountA);
      });

      tester.view.devicePixelRatio = 1.0;
      // In AuthenticatedApp, NavigationRail takes 81 dp. 1000 dp gives 919 dp to content (> 840 dp two-pane).
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Pump AuthenticatedApp keyed with ValueKey(session.generation) as in main.dart
      Widget buildApp() {
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            if (session.active == null || session.api == null) {
              return const MaterialApp(home: Scaffold(body: Text('LOGIN_SCREEN')));
            }
            return AuthenticatedApp(
              key: ValueKey(session.generation),
              session: session,
              appearance: appearance,
              shortcuts: shortcuts,
              buildInfoLoader: _dummyBuildInfo,
            );
          },
        );
      }

      await tester.pumpWidget(buildApp());
      await settleNetworkWidgets(tester);

      // Verify Account A in Two-pane Projects tab
      expect(find.text('@developer'), findsWidgets);
      expect(find.text('請選擇專案'), findsOneWidget);

      // Select Project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // Switch to Account B
      await tester.runAsync(() async {
        await session.select(accountB);
      });
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Assert Account B state
      expect(find.text('@reviewer'), findsWidgets);
      expect(find.text('請選擇專案'), findsOneWidget, reason: 'Account B must see empty state, not Account A detail');
      expect(find.text('檔案'), findsNothing, reason: 'Account A project details must be 100% purged');

      // Now test Logout: session.endSession()
      await tester.runAsync(() async {
        await session.endSession();
      });
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
      expect(find.text('Mobile Workspace'), findsNothing);
      expect(find.text('請選擇專案'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AuthenticatedApp Shell NavigationRail offset probe: 840 dp vs 921 dp content transition', (tester) async {
      final appearanceStore = MemoryAppearanceStore();
      final appearance = AppearanceController(appearanceStore);
      addTearDown(appearance.dispose);
      final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
      addTearDown(shortcuts.dispose);

      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Probe 1: 839 dp window in AuthenticatedApp.
      // NavigationRail (80 dp) + Divider (1 dp) consumes 81 dp.
      // Content width = 839 - 81 = 758 dp (< 759 dp expandedMinWithRail).
      // Therefore, under AuthenticatedApp, 839 dp screen gives Single-Pane layout to ProjectsPage!
      tester.view.physicalSize = const Size(839, 900);
      await tester.pumpWidget(
        AuthenticatedApp(
          key: ValueKey(session.generation),
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _dummyBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsNothing,
        reason: 'At 839 dp screen width, Shell NavigationRail leaves 758 dp to content, which is single-pane');

      // Probe 2: 840 dp window in AuthenticatedApp.
      // Content width = 840 - 81 = 759 dp (>= 759 dp expandedMinWithRail).
      // ProjectsPage switches to Two-Pane!
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsOneWidget,
        reason: 'At 840 dp screen width, content area reaches 759 dp (expandedMinWithRail) and switches to Two-Pane');
      expect(find.text('請選擇專案'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Probing ProjectsPage didUpdateWidget resilience when account switches without rekeying', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);

      final instance = fixture.api.instance;
      final accountA = Account(
        instance: instance,
        user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
        token: 'synthetic-test-token-a',
      );
      final accountB = Account(
        instance: instance,
        user: const GitLabUser(id: 8, username: 'reviewer', name: 'Reviewer'),
        token: 'synthetic-test-token-b',
      );

      final store = MemoryAccountStore()..accounts = [accountA, accountB];
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        final token = request.headers['private-token'];
        if (path.endsWith('/user')) {
          if (token == 'synthetic-test-token-a') {
            return jsonResponse({'id': 7, 'username': 'developer', 'name': 'Developer'});
          }
          if (token == 'synthetic-test-token-b') {
            return jsonResponse({'id': 8, 'username': 'reviewer', 'name': 'Reviewer'});
          }
        }
        return fixture.respond(request);
      });
      final session = controllerFor(store, adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.select(accountA);
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Mount ProjectsPage directly WITHOUT key
      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // Switch account to accountB, BUT pump ProjectsPage with the same element (no key change)
      await tester.runAsync(() async {
        await session.select(accountB);
      });
      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Verification: session.generation was incremented during select
      expect(session.generation, 4);

      // Audit discovery:
      // In main.dart, AuthenticatedApp is protected by `key: ValueKey(session.generation)`.
      // If an isolated ProjectsPage widget is updated without rekeying, didUpdateWidget does not
      // clear _selection, so the old project remains in the local controller.
      final hasRetainedOldProject = find.text('檔案').evaluate().isNotEmpty;
      // We document this observation for forensic audit.
      expect(hasRetainedOldProject, isTrue);
    });
  });
}
