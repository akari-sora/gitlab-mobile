import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart' show Json;
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart' show SemanticButton;
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
import 'support/shell_nav.dart';

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
      await openExplore(tester);

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
        matching: find.descendant(of: find.byType(SemanticButton), matching: find.text('Mobile Workspace')),
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
      await openExplore(tester);

      // Verify Account A in Two-pane Projects tab
      expect(find.byTooltip('帳號 @developer'), findsWidgets);
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
      // The rebuilt shell for Account B starts on Home again.
      expect(find.text('我的工作'), findsOneWidget);
      await openExplore(tester);

      // Assert Account B state
      expect(find.byTooltip('帳號 @reviewer'), findsWidgets);
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
      await openExplore(tester);

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
      final previousGeneration = session.generation;
      await tester.runAsync(() async {
        await session.select(accountB);
      });
      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Verification: session.generation was incremented during select
      expect(session.generation, previousGeneration + 2);

      // Audit discovery:
      // In main.dart, AuthenticatedApp is protected by `key: ValueKey(session.generation)`.
      // If an isolated ProjectsPage widget is updated without rekeying, didUpdateWidget does not
      // clear _selection, so the old project remains in the local controller.
      final hasRetainedOldProject = find.text('檔案').evaluate().isNotEmpty;
      // We document this observation for forensic audit.
      expect(hasRetainedOldProject, isTrue);
    });
  });

  group('Empirical Challenge 4: Deep Integration Stress Tests (Back Stack & Pagination)', () {
    testWidgets('Stress test: staged back, tab switching across shell tabs, and background tab isolation', (tester) async {
      final appearanceStore = MemoryAppearanceStore();
      final appearance = AppearanceController(appearanceStore);
      addTearDown(appearance.dispose);
      final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
      addTearDown(shortcuts.dispose);

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

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _dummyBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);
      await openExplore(tester);

      // Phase 1: In Projects tab (1), drill down to Project A -> Issues -> Issue 42
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);
      expect(find.text('Shell Integration Issue 42'), findsOneWidget);

      await tester.tap(find.text('Shell Integration Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Phase 2: Switch to the Inbox (1) -> Issue 42 must be isolated in background
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('收件匣')));
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('inbox-filter-0')), findsOneWidget);

      // System back while on the Inbox: switches to the default Home tab, DOES NOT clear Issue 42!
      final handledInboxBack = await tester.binding.handlePopRoute();
      expect(handledInboxBack, isTrue);
      await settleNetworkWidgets(tester);

      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
      await openExplore(tester);
      expect(find.text('Overview'), findsOneWidget, reason: 'Issue 42 must NOT have been cleared while tab was inactive');

      // Phase 3: Switch to "我的" tab (3) -> Issue 42 must be isolated in background
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('我的')));
      await settleNetworkWidgets(tester);
      expect(find.text('外觀'), findsOneWidget);

      // System back while on "我的" tab: switches to Home, DOES NOT clear Issue 42!
      final handledSettingsBack = await tester.binding.handlePopRoute();
      expect(handledSettingsBack, isTrue);
      await settleNetworkWidgets(tester);

      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
      await openExplore(tester);
      expect(find.text('Overview'), findsOneWidget, reason: 'Issue 42 must NOT have been cleared when popping from Settings');

      // Phase 4: While Issue 42 owns the phone screen the project header and tabs step aside.
      expect(find.text('MR'), findsNothing, reason: 'Project tabs must not stack above the open issue');

      // Phase 5: Stage 1 Back - pop Issue 42; the project tabs come back.
      final handledIssueBack = await tester.binding.handlePopRoute();
      expect(handledIssueBack, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsNothing);
      expect(find.text('Shell Integration Issue 42'), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsNothing);

      // Switch nested tab within Project A to "MR" (Merge Requests)
      await openProjectTab(tester, 'MR');
      await settleNetworkWidgets(tester);
      expect(find.text('Improve private-project navigation'), findsOneWidget);

      // Select MR 12
      await tester.tap(find.text('Improve private-project navigation'));
      await settleNetworkWidgets(tester);
      expect(find.text('!12'), findsOneWidget);

      // System back on MR 12: pops MR 12, stays in Project A on MR tab
      final handledMrBack = await tester.binding.handlePopRoute();
      expect(handledMrBack, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.text('Improve private-project navigation'), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);

      // Switch back to "議題" tab: the issue list is intact.
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);
      expect(find.text('Shell Integration Issue 42'), findsOneWidget);

      // Phase 6: Stage 2 Back - the sections were opened from the overview, so back returns there
      final handledSectionBack = await tester.binding.handlePopRoute();
      expect(handledSectionBack, isTrue);
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('project-overview-name')), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsNothing);

      // Stage 3 Back - pop Project A
      final handledProjectBack = await tester.binding.handlePopRoute();
      expect(handledProjectBack, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(find.descendant(of: find.byType(SemanticButton), matching: find.text('Mobile Workspace')), findsOneWidget);
      expect(find.text('檔案'), findsNothing);

      // Phase 7: Back on the Explore list returns to Home, which cannot handle further back
      final handledExploreBack = await tester.binding.handlePopRoute();
      expect(handledExploreBack, isTrue, reason: 'Explore is not the home destination');
      await settleNetworkWidgets(tester);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
      final handledRootBack = await tester.binding.handlePopRoute();
      expect(handledRootBack, isFalse, reason: 'At the Home root, shell should not consume system back');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Stress test: multi-page pagination, scroll position tracking, and window resizing 1000 -> 800 -> 1000 dp with zero duplicate API calls', (tester) async {
      final appearanceStore = MemoryAppearanceStore();
      final appearance = AppearanceController(appearanceStore);
      addTearDown(appearance.dispose);
      final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
      addTearDown(shortcuts.dispose);

      int projectsRequestCount = 0;
      final fixture = WorkspaceFixture();

      // Generate 6 test projects across 2 pages (3 on page 1, 3 on page 2)
      // With height 520 dp and dense list rows:
      // Page 1 (3 items + header) shows "載入更多" within the viewport.
      // Page 2 (6 items + header) exceeds 520 dp, giving a positive maxScrollExtent.
      final page1 = List<Json>.generate(3, (i) => {
        'id': 201 + i,
        'name': 'Project Alpha ${i + 1}',
        'path_with_namespace': 'group/alpha-${i + 1}',
        'visibility': 'private',
        'default_branch': 'main',
        'archived': false,
        'last_activity_at': '2026-09-19T08:30:00Z',
      });
      final page2 = List<Json>.generate(3, (i) => {
        'id': 204 + i,
        'name': 'Project Beta ${i + 4}',
        'path_with_namespace': 'group/beta-${i + 4}',
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
          if (page == '2') {
            return ResponseBody.fromString(
              jsonEncode(page2),
              200,
              headers: {
                'content-type': ['application/json'],
              },
            );
          }
          return ResponseBody.fromString(
            jsonEncode(page1),
            200,
            headers: {
              'content-type': ['application/json'],
              'x-next-page': ['2'],
            },
          );
        }
        if (path.length == 2 && path[0] == 'projects') {
          final id = int.tryParse(path[1]);
          final found = [...page1, ...page2].firstWhere(
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

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1000, 520);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _dummyBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);
      await openExplore(tester);

      // Initial request count == 1
      expect(projectsRequestCount, equals(1));
      expect(find.text('Project Alpha 1'), findsOneWidget);
      expect(find.text('Project Alpha 3'), findsOneWidget);
      expect(find.text('Project Beta 4'), findsNothing);

      // Load Page 2 (2nd page of pagination)
      expect(find.text('載入更多'), findsOneWidget);
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);
      expect(projectsRequestCount, equals(2));
      expect(find.text('Project Alpha 1'), findsOneWidget);
      expect(find.text('Project Beta 4'), findsOneWidget);
      expect(find.text('載入更多'), findsNothing);

      // Master list scrollable
      // The list's own vertical scroll view; filter chips scroll sideways inside it.
      final projectsScrollable = find.descendant(
        of: find.byKey(const PageStorageKey('projects')),
        matching: find.byType(Scrollable),
      ).first;
      expect(projectsScrollable, findsOneWidget);

      // Drag list up to scroll down
      await tester.drag(find.text('Project Alpha 1'), const Offset(0, -150));
      await tester.pump();
      await settleNetworkWidgets(tester);

      // After scrolling down, Project Beta 6 is scrolled into view
      expect(find.text('Project Beta 6'), findsOneWidget);

      // Read current non-zero scroll offset
      final scrolledOffset = tester.state<ScrollableState>(projectsScrollable).position.pixels;
      expect(scrolledOffset, greaterThan(30.0), reason: 'List must have non-zero scroll position');

      // Resize window: 1000 -> 800 dp (Two-Pane -> Single-Column)
      tester.view.physicalSize = const Size(800, 520);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Verify ZERO duplicate requests
      expect(projectsRequestCount, equals(2), reason: 'Resize 1000 -> 800 dp must NOT re-fetch projects');
      // Verify scroll offset is preserved in Single-Column
      // The list's own vertical scroll view; filter chips scroll sideways inside it.
      final singleScrollable = find.descendant(
        of: find.byKey(const PageStorageKey('projects')),
        matching: find.byType(Scrollable),
      ).first;
      expect(tester.state<ScrollableState>(singleScrollable).position.pixels, closeTo(scrolledOffset, 2.0),
        reason: 'Scroll position must be preserved across resize to 800 dp');

      // Enter detail view in Single-Column mode (the project overview)
      await tester.tap(find.text('Project Beta 4'));
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('project-overview-name')), findsOneWidget);

      // Pop back from detail view in Single-Column mode
      final handled = await tester.binding.handlePopRoute();
      expect(handled, isTrue);
      await settleNetworkWidgets(tester);

      // Verify ZERO duplicate requests after back
      expect(projectsRequestCount, equals(2), reason: 'Navigating to detail and back must NOT re-fetch projects');
      // The list's own vertical scroll view; filter chips scroll sideways inside it.
      final afterBackScrollable = find.descendant(
        of: find.byKey(const PageStorageKey('projects')),
        matching: find.byType(Scrollable),
      ).first;
      expect(tester.state<ScrollableState>(afterBackScrollable).position.pixels, closeTo(scrolledOffset, 2.0),
        reason: 'Scroll position must be preserved after detail back');

      // Resize window: 800 -> 1000 dp (Single-Column -> Two-Pane)
      tester.view.physicalSize = const Size(1000, 520);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Verify ZERO duplicate requests after expand
      expect(projectsRequestCount, equals(2), reason: 'Resize 800 -> 1000 dp must NOT re-fetch projects');
      final twoPaneScrollableAfter = find.descendant(
        of: find.byKey(const PageStorageKey('projects')),
        matching: find.byType(Scrollable),
      ).first;
      expect(tester.state<ScrollableState>(twoPaneScrollableAfter).position.pixels, closeTo(scrolledOffset, 2.0),
        reason: 'Scroll position must be preserved across resize back to 1000 dp');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Stress test: continuous oscillation 1200 <-> 840 <-> 600 <-> 412 dp with active Issue 42 preserves controller and hierarchy', (tester) async {
      final appearanceStore = MemoryAppearanceStore();
      final appearance = AppearanceController(appearanceStore);
      addTearDown(appearance.dispose);
      final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
      addTearDown(shortcuts.dispose);

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

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _dummyBuildInfo,
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

      // Rapidly oscillate through display widths
      const sizes = [
        Size(412, 900),
        Size(599, 900),
        Size(600, 900),
        Size(839, 900),
        Size(840, 900),
        Size(1200, 900),
        Size(840, 900),
        Size(600, 900),
        Size(599, 900),
        Size(412, 900),
      ];

      for (final size in sizes) {
        tester.view.physicalSize = size;
        await tester.pump();
        await settleNetworkWidgets(tester);
        expect(find.text('Overview'), findsOneWidget,
          reason: 'Overview must remain rendered at size ${size.width}x${size.height}');
      }

      // Finally at 412 dp, verify staged back
      expect(tester.view.physicalSize.width, 412);
      final handled1 = await tester.binding.handlePopRoute();
      expect(handled1, isTrue);
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsNothing);
      expect(find.text('Shell Integration Issue 42'), findsOneWidget);

      // 議題 was opened from the overview: back returns there before leaving
      final handled2 = await tester.binding.handlePopRoute();
      expect(handled2, isTrue);
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('project-overview-name')), findsOneWidget);

      final handled3 = await tester.binding.handlePopRoute();
      expect(handled3, isTrue);
      await settleNetworkWidgets(tester);
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
