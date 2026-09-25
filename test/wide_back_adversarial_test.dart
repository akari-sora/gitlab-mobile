import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Future<BuildInfo> _adversarialBuildInfo() async => const BuildInfo(
  version: '0.4.0',
  buildNumber: '4',
  commit: 'challenger_wide_back',
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

  group('CHALLENGER ADVERSARIAL: Wide Two-Pane Back Hierarchy & Geometry Stress Test', () {
    testWidgets('Rapid 5 consecutive handlePopRoute calls: no crash, no loop, graceful bottom-out', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Stress Pop Issue 42');
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
          buildInfoLoader: _adversarialBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // Navigate to Project -> Issues -> Select Issue 42
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('Stress Pop Issue 42'));
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Stress Pop Issue 42'), findsNWidgets(2));

      // Pop 1: Must consume Issue 42 selection
      final pop1 = await tester.binding.handlePopRoute();
      expect(pop1, isTrue, reason: 'Pop 1 should clear issue detail selection');
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsNothing);
      expect(find.text('請選擇議題'), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget, reason: 'Still inside project');

      // Pop 2: Must exit ProjectPage route to Projects root
      final pop2 = await tester.binding.handlePopRoute();
      expect(pop2, isTrue, reason: 'Pop 2 should pop ProjectPage route');
      await settleNetworkWidgets(tester);
      expect(find.byKey(const Key('projectSearch')), findsOneWidget, reason: 'Must be on Projects list');
      expect(find.text('檔案'), findsNothing);

      // Pop 3: At root Projects tab. No routes left on navigator stack.
      // Must not throw, crash, or enter infinite loop.
      final pop3 = await tester.binding.handlePopRoute();
      expect(pop3, isFalse, reason: 'Pop 3 at root tab should return false (system handles app exit)');
      await settleNetworkWidgets(tester);
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);

      // Pop 4: Rapid consecutive call on root
      final pop4 = await tester.binding.handlePopRoute();
      expect(pop4, isFalse, reason: 'Pop 4 at root tab should consistently return false');
      await settleNetworkWidgets(tester);

      // Pop 5: Rapid consecutive call on root
      final pop5 = await tester.binding.handlePopRoute();
      expect(pop5, isFalse, reason: 'Pop 5 at root tab should consistently return false');
      await settleNetworkWidgets(tester);

      expect(tester.takeException(), isNull, reason: 'No unhandled exception after 5 rapid pops');
    });

    testWidgets('1200 dp rapid selection switching (Issue 1 -> 2 -> 3) and single-pop stack deflation', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[1] = fixture.issue(1, 'Alpha Issue 1');
      fixture.issues[2] = fixture.issue(2, 'Beta Issue 2');
      fixture.issues[3] = fixture.issue(3, 'Gamma Issue 3');
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
          buildInfoLoader: _adversarialBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // Enter Project -> Issues
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Verify all 3 issues are rendered in the list
      expect(find.text('Alpha Issue 1'), findsOneWidget);
      expect(find.text('Beta Issue 2'), findsOneWidget);
      expect(find.text('Gamma Issue 3'), findsOneWidget);
      expect(find.text('請選擇議題'), findsOneWidget);

      // Select Issue 1
      await tester.tap(find.text('Alpha Issue 1'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Alpha Issue 1'), findsNWidgets(2)); // list card + detail header

      // Directly select Issue 2 without popping
      await tester.tap(find.text('Beta Issue 2'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Beta Issue 2'), findsNWidgets(2)); // list card + detail header
      expect(find.text('Alpha Issue 1'), findsOneWidget); // now only in list

      // Directly select Issue 3 without popping
      await tester.tap(find.text('Gamma Issue 3'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Gamma Issue 3'), findsNWidgets(2)); // list card + detail header
      expect(find.text('Beta Issue 2'), findsOneWidget); // now only in list

      // Trigger first handlePopRoute:
      // The back mechanism must NOT unwind through Beta Issue 2, then Alpha Issue 1!
      // It must immediately clear the active selection to empty state!
      final popResult1 = await tester.binding.handlePopRoute();
      expect(popResult1, isTrue, reason: 'First pop consumes active selection');
      await settleNetworkWidgets(tester);

      // Assert: Right pane returns directly to empty state, NOT to Issue 2!
      expect(find.text('Overview'), findsNothing, reason: 'Stack must not have inflated with prior selections');
      expect(find.text('請選擇議題'), findsOneWidget, reason: 'Right pane must be in clean empty state');
      expect(find.text('Alpha Issue 1'), findsOneWidget);
      expect(find.text('Beta Issue 2'), findsOneWidget);
      expect(find.text('Gamma Issue 3'), findsOneWidget);
      expect(find.text('檔案'), findsOneWidget, reason: 'Project tab remains active');

      // Second handlePopRoute: Immediately exits ProjectPage to Projects list
      final popResult2 = await tester.binding.handlePopRoute();
      expect(popResult2, isTrue, reason: 'Second pop exits ProjectPage directly');
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget, reason: 'Returned to root Projects list');
      expect(find.text('檔案'), findsNothing);

      // Third pop: Root tab does not pop
      final popResult3 = await tester.binding.handlePopRoute();
      expect(popResult3, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('840 dp two-pane width constraint, spatial non-overlap, and bidirectional hitTestable rigour', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[1] = fixture.issue(1, 'HitTest Left Item 1');
      fixture.issues[2] = fixture.issue(2, 'HitTest Left Item 2');
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
          buildInfoLoader: _adversarialBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // Verify side NavigationRail is present (80 dp + 1 dp divider = 81 dp)
      expect(find.byType(NavigationRail), findsOneWidget);
      final railSize = tester.getSize(find.byType(NavigationRail));
      expect(railSize.width, equals(80.0));

      // Enter Project -> Issues
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Verify two-pane layout exists
      final listPaneFinder = find.byKey(const ValueKey('list-pane'));
      final detailPaneFinder = find.byKey(const ValueKey('detail-pane-expanded'));
      expect(listPaneFinder, findsOneWidget);
      expect(detailPaneFinder, findsOneWidget);

      // Exact geometry verification:
      // Total: 840 dp. Rail: 81 dp. List: 380 dp. Divider: 1 dp. Detail: 840 - 81 - 380 - 1 = 378 dp.
      final listPaneSize = tester.getSize(listPaneFinder);
      final detailPaneSize = tester.getSize(detailPaneFinder);
      expect(listPaneSize.width, equals(380.0));
      expect(detailPaneSize.width, equals(378.0));

      final listPaneRect = tester.getRect(listPaneFinder);
      final detailPaneRect = tester.getRect(detailPaneFinder);

      // Strict non-overlapping bounds check:
      // Rail (0..80) -> Divider (80..81) -> List (81..461) -> Divider (461..462) -> Detail (462..840)
      expect(listPaneRect.left, equals(81.0));
      expect(listPaneRect.right, equals(461.0));
      expect(detailPaneRect.left, equals(462.0));
      expect(detailPaneRect.right, equals(840.0));
      expect(listPaneRect.right, lessThan(detailPaneRect.left));

      // Select Item 1
      await tester.tap(find.text('HitTest Left Item 1'));
      await settleNetworkWidgets(tester);

      final cardItem1 = find.descendant(
        of: find.byType(Card),
        matching: find.text('HitTest Left Item 1'),
      ).first;
      final cardItem2 = find.descendant(
        of: find.byType(Card),
        matching: find.text('HitTest Left Item 2'),
      ).first;
      final detailOverview = find.text('Overview');

      // Both panes must be hit-testable
      expect(cardItem1.hitTestable(), findsOneWidget);
      expect(cardItem2.hitTestable(), findsOneWidget);
      expect(detailOverview.hitTestable(), findsOneWidget);

      // Bidirectional gesture testing:
      // 1. Interact with right pane: tap 'Overview'
      await tester.tap(detailOverview);
      await settleNetworkWidgets(tester);

      // 2. Interact with left pane without back: directly tap cardItem2
      await tester.tap(cardItem2);
      await settleNetworkWidgets(tester);

      // Assert Item 2 is now loaded in detail pane
      expect(find.text('HitTest Left Item 2'), findsNWidgets(2));
      expect(find.text('HitTest Left Item 1'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('Rapid alternation of selection and pop cycles maintains clean state machine', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[1] = fixture.issue(1, 'Cycle Issue 1');
      fixture.issues[2] = fixture.issue(2, 'Cycle Issue 2');
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
          buildInfoLoader: _adversarialBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // 3 cycles of select -> pop -> select -> pop
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Cycle Issue 1'));
        await settleNetworkWidgets(tester);
        expect(find.text('Overview'), findsOneWidget);

        final pop1 = await tester.binding.handlePopRoute();
        expect(pop1, isTrue);
        await settleNetworkWidgets(tester);
        expect(find.text('Overview'), findsNothing);
        expect(find.text('請選擇議題'), findsOneWidget);

        await tester.tap(find.text('Cycle Issue 2'));
        await settleNetworkWidgets(tester);
        expect(find.text('Overview'), findsOneWidget);

        final pop2 = await tester.binding.handlePopRoute();
        expect(pop2, isTrue);
        await settleNetworkWidgets(tester);
        expect(find.text('Overview'), findsNothing);
        expect(find.text('請選擇議題'), findsOneWidget);
      }

      // Exit project after cycles
      final exitPop = await tester.binding.handlePopRoute();
      expect(exitPop, isTrue);
      await settleNetworkWidgets(tester);
      expect(find.byKey(const Key('projectSearch')), findsOneWidget);

      expect(tester.takeException(), isNull);
    });
  });
}
