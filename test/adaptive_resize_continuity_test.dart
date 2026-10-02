import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart' show SemanticButton;
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

void main() {
  group('AdaptiveBreakpoints Unit Tests', () {
    test('classifies window sizes accurately', () {
      expect(AdaptiveBreakpoints.windowSize(320), AdaptiveWindowSize.compact);
      expect(AdaptiveBreakpoints.windowSize(412), AdaptiveWindowSize.compact);
      expect(AdaptiveBreakpoints.windowSize(599), AdaptiveWindowSize.compact);
      expect(AdaptiveBreakpoints.windowSize(600), AdaptiveWindowSize.medium);
      expect(AdaptiveBreakpoints.windowSize(839), AdaptiveWindowSize.medium);
      expect(AdaptiveBreakpoints.windowSize(840), AdaptiveWindowSize.expanded);
      expect(AdaptiveBreakpoints.windowSize(1199), AdaptiveWindowSize.expanded);
      expect(AdaptiveBreakpoints.windowSize(1200), AdaptiveWindowSize.large);
      expect(AdaptiveBreakpoints.windowSize(1600), AdaptiveWindowSize.large);
    });

    test('isTwoPane and isLarge predicates adhere to breakpoint thresholds', () {
      expect(AdaptiveBreakpoints.isTwoPane(412), isFalse);
      expect(AdaptiveBreakpoints.isTwoPane(839), isFalse);
      expect(AdaptiveBreakpoints.isTwoPane(840), isTrue);
      expect(AdaptiveBreakpoints.isTwoPane(1200), isTrue);

      expect(AdaptiveBreakpoints.isTwoPane(758, hasRail: true), isFalse);
      expect(AdaptiveBreakpoints.isTwoPane(759, hasRail: true), isTrue);
      expect(AdaptiveBreakpoints.isTwoPane(840, hasRail: true), isTrue);

      expect(AdaptiveBreakpoints.isLarge(840), isFalse);
      expect(AdaptiveBreakpoints.isLarge(1199), isFalse);
      expect(AdaptiveBreakpoints.isLarge(1200), isTrue);

      expect(AdaptiveBreakpoints.navigationRailTotalWidth, 81.0);
      expect(AdaptiveBreakpoints.expandedMinWithRail, 759.0);
      expect(AdaptiveBreakpoints.largeMinWithRail, 1119.0);
    });
  });

  group('Adaptive Resize Continuity (Case A ~ D)', () {
    testWidgets('Case A (412 -> 840 dp): List to Detail in Compact, expands to Two-Pane with Tab continuity', (tester) async {
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
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Verify Compact List view
      expect(find.text('Mobile Workspace'), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsNothing);

      // Tap to open detail in Compact
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Switch to 議題 tab (index 1)
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);
      expect(find.widgetWithText(TextField, '搜尋議題'), findsOneWidget);

      // Dynamic Resize: 412 -> 840 dp (Compact -> Expanded Two-Pane)
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Assert Two-Pane layout and Tab continuity (議題 tab still active)
      expect(find.byKey(const Key('projectSearch')), findsOneWidget); // Left List
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsOneWidget); // Right Detail
      expect(find.widgetWithText(TextField, '搜尋議題'), findsOneWidget,
          reason: 'R1.3 Violation: Tab index in ProjectPage must be preserved across resize');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Case B (840 -> 412 dp): Select in Two-Pane, shrinks to Compact, back to list', (tester) async {
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

      // Initial state: Two-Pane with empty detail
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(find.text('請選擇專案'), findsOneWidget);

      // Select Project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // Dynamic Resize: 840 -> 412 dp
      tester.view.physicalSize = const Size(412, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Assert: Full-screen Detail with Back Button
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);

      // Tap Back: returns to List
      await tester.tap(find.byType(BackButton));
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(find.text('檔案'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Nested selection continuity: Selected issue in WorkItemsTab persists across Two-Pane to Compact resize', (tester) async {
      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Deep Nested Issue 42');
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      // Start in Two-Pane (1000x900)
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Select project -> opens ProjectPage in right pane
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Switch to 議題 tab
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);
      expect(find.text('Deep Nested Issue 42'), findsOneWidget);

      // Select issue 42 inside WorkItemsTab
      await tester.tap(find.text('Deep Nested Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Now RESIZE from 1000 dp -> 412 dp (Two-Pane -> Compact)
      tester.view.physicalSize = const Size(412, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Verify nested selection is preserved: Overview is still active
      expect(find.text('Overview'), findsOneWidget,
          reason: 'R1.3 Violation: Selected Issue was lost when resizing from Two-Pane to Compact!');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Case C (840 -> 1200 dp): Issue selected in Two-Pane, expands to Large with 960dp constraints', (tester) async {
      final fixture = WorkspaceFixture();
      fixture.issues[1] = fixture.issue(1, 'Adaptive Issue 1');
      addTearDown(fixture.api.close);

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(
        Scaffold(body: WorkItemsTab(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
        )),
      ));
      await settleNetworkWidgets(tester);

      // Initial state: Two-Pane with empty detail on right
      expect(find.text('Adaptive Issue 1'), findsOneWidget);
      expect(find.text('請選擇議題'), findsOneWidget);

      // Select issue 1
      await tester.tap(find.text('Adaptive Issue 1'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Dynamic Resize: 840 -> 1200 dp (Large)
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Verify detail content container is constrained by max content width 960 dp
      final containerFinder = find.byKey(const ValueKey('detail-content-container'));
      expect(containerFinder, findsOneWidget);
      final size = tester.getSize(containerFinder);
      expect(size.width, lessThanOrEqualTo(960.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Case D (1200 -> 840 -> 412 -> 840 dp): Continuous bidirectional resize stress test', (tester) async {
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
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Select Project at 1200 dp
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // Step 1: 1200 -> 840 dp (Expanded Two-Pane)
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);

      // Step 2: 840 -> 412 dp (Compact Single-Pane)
      tester.view.physicalSize = const Size(412, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);

      // Step 3: 412 -> 840 dp (Restored to Two-Pane)
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Assert: Smooth restoration to Two-Pane without exceptions or duplicate routes
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-detail-pane')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Boundary & Layout Verification Tests', () {
    testWidgets('839 dp vs 840 dp boundary threshold switching', (tester) async {
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

      // 839 dp: Single pane
      tester.view.physicalSize = const Size(839, 900);
      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsNothing);
      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsNothing);
      expect(find.text('Mobile Workspace'), findsOneWidget);

      // 840 dp: Two pane
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-empty-pane')), findsOneWidget);
      expect(find.text('請選擇專案'), findsOneWidget);
    });

    testWidgets('Touch target meets >= 48dp on Project card and Chips', (tester) async {
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
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      final chipSize = tester.getSize(find.widgetWithText(ChoiceChip, '我的專案'));
      expect(chipSize.height, greaterThanOrEqualTo(48.0));

      final cardSize = tester.getSize(find.widgetWithText(SemanticButton, 'Mobile Workspace'));
      expect(cardSize.height, greaterThanOrEqualTo(48.0));
      expect(cardSize.width, greaterThanOrEqualTo(48.0));
    });

    testWidgets('Shell integration: AuthenticatedApp at 840 dp shows NavigationRail and Two-Pane Projects (GAP-2)', (tester) async {
      final appearanceStore = MemoryAppearanceStore();
      final appearance = AppearanceController(appearanceStore);
      final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
      addTearDown(() {
        appearance.dispose();
        shortcuts.dispose();
      });

      final fixture = WorkspaceFixture();
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: () async => const BuildInfo(
            version: '0.4.0',
            buildNumber: '4',
            commit: 'test',
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // 840 dp shows NavigationRail and hides NavigationBar
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // 840 dp content pane (840 - 81 = 759 dp) triggers Two-Pane via AdaptiveScope
      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsOneWidget);

      // Resize down to 839 dp (839 - 81 = 758 dp < 759 dp) -> reverts to Single-Pane
      tester.view.physicalSize = const Size(839, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-two-pane-row')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Account Switch & State Isolation Tests', () {
    testWidgets('Adaptive selection state is completely purged on account switch', (tester) async {
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

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(
        key: ValueKey(session.generation),
        session: session,
      )));
      await settleNetworkWidgets(tester);

      // Select project under Account A
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      expect(find.text('檔案'), findsOneWidget);

      // Switch to Account B (generation increments, rebuilding with fresh key)
      await tester.runAsync(() => session.select(accountB));
      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(
        key: ValueKey(session.generation),
        session: session,
      )));
      await settleNetworkWidgets(tester);

      // Verify Account B starts with empty selection state
      expect(find.text('請選擇專案'), findsOneWidget);
      expect(find.text('檔案'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
