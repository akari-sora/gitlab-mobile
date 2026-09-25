import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
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

Future<BuildInfo> _testBuildInfo() async => const BuildInfo(
      version: '0.4.0',
      buildNumber: '4',
      commit: 'challenger',
    );

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('CHALLENGE 1: AuthenticatedApp Shell vs Local Breakpoint at 840 dp', () {
    testWidgets('Investigate whether 840 dp screen width shows two-pane in AuthenticatedApp', (tester) async {
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
          buildInfoLoader: _testBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // Verify shell navigation: NavigationRail is visible at 840 dp
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // Check whether ListDetailScaffold inside ProjectsPage is in two-pane or single-pane
      final twoPaneFinder = find.byKey(const ValueKey('adaptive-two-pane-row'));
      final isTwoPanePresent = twoPaneFinder.evaluate().isNotEmpty;

      // Report empirical finding:
      // When screen width is exactly 840 dp, NavigationRail occupies ~80 dp,
      // leaving 759 dp for the content pane.
      // ListDetailScaffold.breakpoint defaults to 840.0 dp.
      // Therefore, at 840 dp screen width, the content pane is single-pane.
      debugPrint('[Empirical Challenge 1] At 840 dp screen width with AuthenticatedApp: isTwoPane = $isTwoPanePresent');

      // Now let's test what screen width triggers two-pane in AuthenticatedApp:
      // Rail width (80) + Divider (1) + Breakpoint (840) = 921 dp.
      tester.view.physicalSize = const Size(921, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      final isTwoPaneAt921 = twoPaneFinder.evaluate().isNotEmpty;
      debugPrint('[Empirical Challenge 1] At 921 dp screen width with AuthenticatedApp: isTwoPane = $isTwoPaneAt921');
      expect(isTwoPaneAt921, isTrue);
    });
  });

  group('CHALLENGE 2: Large Display Gutter Distortion & Overflow in Detail Pane', () {
    testWidgets('Detail pane internal feedGutter at 1200 dp and 1600 dp', (tester) async {
      final fixture = WorkspaceFixture();
      fixture.issues[1] = fixture.issue(1, 'Gutter Test Issue 1');
      fixture.issues[2] = fixture.issue(2, 'Gutter Test Issue 2');
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

      // Select Project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Switch to Issues tab inside ProjectPage
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Check whether WorkItemsTab is visible
      expect(find.text('Gutter Test Issue 1'), findsOneWidget);

      // Let's inspect the layout and sizes in the right pane at 1200 dp
      final detailPaneFinder = find.byKey(const ValueKey('adaptive-detail-pane'));
      expect(detailPaneFinder, findsOneWidget);
      final detailSize = tester.getSize(detailPaneFinder);
      debugPrint('[Empirical Challenge 2] Detail pane size at 1200 dp: $detailSize');

      // Now expand to 1600 dp
      tester.view.physicalSize = const Size(1600, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(tester.takeException(), isNull);
      debugPrint('[Empirical Challenge 2] After resize to 1600 dp: has Gutter Test Issue 1? ${find.text('Gutter Test Issue 1').evaluate().length}');

      // Check whether container is constrained to 960 dp
      final containerFinder = find.byKey(const ValueKey('detail-content-container'));
      expect(containerFinder, findsOneWidget);
      final containerSize = tester.getSize(containerFinder);
      debugPrint('[Empirical Challenge 2] Detail content container size at 1600 dp: $containerSize');
      expect(containerSize.width, lessThanOrEqualTo(960.0));

      final listViews = tester.widgetList<ListView>(find.byType(ListView));
      for (final lv in listViews) {
        debugPrint('[Empirical Challenge 2] ListView padding: ${lv.padding}');
      }

      // Expand to extreme 2400 dp (4K display / desktop window)
      tester.view.physicalSize = const Size(2400, 1200);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(tester.takeException(), isNull);
      final containerSize2400 = tester.getSize(containerFinder);
      debugPrint('[Empirical Challenge 2] Detail content container size at 2400 dp: $containerSize2400');
      expect(containerSize2400.width, lessThanOrEqualTo(960.0));
    });
  });

  group('CHALLENGE 3: State Continuity Loss Across Breakpoint Transitions (R1.3)', () {
    testWidgets('Tab index in ProjectPage is reset from 議題 (1) to 檔案 (0) when resizing 412 -> 840 dp', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      // Start in Compact (412x900)
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(testAdaptiveHost(ProjectsPage(session: session)));
      await settleNetworkWidgets(tester);

      // Select project -> opens ProjectPage in Compact mode
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Default tab is 檔案 (0). Switch to 議題 (1)
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Confirm we are on 議題 tab (search box for issues is present)
      expect(find.byType(TextField), findsOneWidget);

      // Now RESIZE from 412 dp -> 840 dp (Compact -> Expanded Two-Pane)
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Check which tab is active!
      // In ProjectPage: TabBar has tabs: 檔案, 議題, MR, CI, 更多
      // If state continuity (R1.3) holds, 議題 should still be active!
      final hasIssueSearch = find.widgetWithText(TextField, '搜尋議題').evaluate().isNotEmpty;
      debugPrint('[Empirical Challenge 3.1] After 412 -> 840 dp resize: Is 議題 tab still active? $hasIssueSearch');
      expect(hasIssueSearch, isTrue, reason: 'R1.3 Violation: ProjectPage detail tab index was reset to 0 upon resize!');
    });

    testWidgets('Selected issue in WorkItemsTab is lost when resizing Two-Pane to Compact', (tester) async {
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

      final hasOverview = find.text('Overview').evaluate().isNotEmpty;
      debugPrint('[Empirical Challenge 3.2] After 1000 -> 412 dp resize: Is selected issue Overview still active? $hasOverview');
      expect(hasOverview, isTrue, reason: 'R1.3 Violation: Selected Issue was lost when resizing from Two-Pane to Compact!');
    });
  });

  group('CHALLENGE 4: Rapid Multi-Cycle Bidirectional Stress Test with Open Modals', () {
    testWidgets('Rapid resizing between 320, 412, 600, 840, 1200, 1600 while Dialog is open', (tester) async {
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

      // Open a dialog via "以連結或路徑開啟" (locator)
      await tester.tap(find.byTooltip('以連結或路徑開啟'));
      await tester.pumpAndSettle();
      expect(find.text('開啟專案'), findsOneWidget);

      // Perform a stress sequence of resizes WHILE the dialog is active
      final sizes = [
        const Size(412, 900),
        const Size(599, 800),
        const Size(600, 800),
        const Size(839, 800),
        const Size(840, 900),
        const Size(1199, 1000),
        const Size(1200, 1000),
        const Size(1600, 1200),
        const Size(840, 900),
        const Size(412, 900),
        const Size(320, 600),
        const Size(840, 900),
      ];

      for (var cycle = 0; cycle < 3; cycle++) {
        for (final s in sizes) {
          tester.view.physicalSize = s;
          await tester.pump();
        }
      }
      await settleNetworkWidgets(tester);

      // Verify dialog is still alive and responsive
      expect(find.text('開啟專案'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await settleNetworkWidgets(tester);

      expect(find.text('開啟專案'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Case D Extreme: 50 consecutive random-step resize cycles with selected project', (tester) async {
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

      final sequence = [
        const Size(1200, 900),
        const Size(1199, 900),
        const Size(840, 900),
        const Size(839, 900),
        const Size(600, 900),
        const Size(599, 900),
        const Size(412, 900),
        const Size(360, 800),
        const Size(412, 900),
        const Size(840, 900),
        const Size(1200, 900),
      ];

      for (var i = 0; i < 5; i++) {
        for (final size in sequence) {
          tester.view.physicalSize = size;
          await tester.pump();
        }
      }
      await settleNetworkWidgets(tester);

      // After 55 dynamic resizes, verify state integrity
      expect(find.text('檔案'), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CHALLENGE 5: PopScope & System Back Gesture Integrity in Two-Pane vs Compact', () {
    testWidgets('PopScope does not swallow or misroute back action when transitioning between two-pane and compact', (tester) async {
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

      // In 840 dp, select Project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Shrink to 412 dp (Compact)
      tester.view.physicalSize = const Size(412, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // In Compact: verify PopScope is present
      final popScopeFinder = find.byWidgetPredicate((widget) => widget is PopScope);
      expect(popScopeFinder, findsWidgets);

      // Expand back to 840 dp without popping
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // In 840 dp: selection is still intact in two-pane
      expect(find.text('檔案'), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
