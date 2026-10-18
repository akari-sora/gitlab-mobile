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
import 'support/shell_nav.dart';

Future<BuildInfo> _testBuildInfo() async => const BuildInfo(
  version: '0.4.0',
  buildNumber: '5',
  commit: 'quick_assign_test',
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

  group('MR !29: Quick Assign & Unassign ActionChip Suite', () {
    testWidgets('Tapping "Quick Assign Me" assigns issue to current user and updates UI', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);

      // Seed an unassigned issue
      fixture.issues[1] = fixture.issue(1, 'Quick Assign Candidate Issue');

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _testBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);
      await openExplore(tester);

      // Navigate to Project -> Issues
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Select issue 1
      await tester.tap(find.text('Quick Assign Candidate Issue'));
      await settleNetworkWidgets(tester);

      // Initial state: "指派給我" ActionChip should exist
      expect(find.byKey(const ValueKey('quick-assign-me')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-unassign-me')), findsNothing);

      // Target the issue-detail vertical scrollable by binding directly to the
      // actual quick-assign chip's vertical scrolling ancestor, guarding against the
      // master list pane (RecordsFeed), inactive detail tabs, and horizontal ancestors (TabBarView).
      final assignChip = find.byKey(const ValueKey('quick-assign-me'));
      final detailScrollable = find.ancestor(
        of: assignChip,
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      expect(detailScrollable, findsOneWidget);

      // Scroll only the issue-detail vertical scrollable with real vertical
      // drag(s) until the required chip is hit-testable inside its visible clipping rect.
      for (var i = 0; i < 20 && assignChip.hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(detailScrollable, const Offset(0, -200));
        await settleNetworkWidgets(tester);
      }
      expect(assignChip.hitTestable(), findsOneWidget);

      // Tap "指派給我"
      await tester.tap(assignChip);
      await settleNetworkWidgets(tester);

      // After assignment: should now show "已指派給我"
      expect(find.byKey(const ValueKey('quick-unassign-me')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-assign-me')), findsNothing);

      // Ensure "已指派給我" chip is hit-testable before unassigning
      final unassignChip = find.byKey(const ValueKey('quick-unassign-me'));
      final unassignScrollable = find.ancestor(
        of: unassignChip,
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      for (var i = 0; i < 20 && unassignChip.hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(unassignScrollable, const Offset(0, -200));
        await settleNetworkWidgets(tester);
      }
      expect(unassignChip.hitTestable(), findsOneWidget);

      // Tap "已指派給我" to unassign
      await tester.tap(unassignChip);
      await settleNetworkWidgets(tester);

      // Should return to "指派給我"
      expect(find.byKey(const ValueKey('quick-assign-me')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-unassign-me')), findsNothing);
    });

    testWidgets('Tapping "修改名單" opens assignees editor', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      final store = MemoryAccountStore();
      final session = controllerFor(store, fixture.adapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);

      fixture.issues[1] = fixture.issue(1, 'Member Picker Issue');

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'synthetic-test-token');
      });

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          buildInfoLoader: _testBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);
      await openExplore(tester);

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Member Picker Issue'));
      await settleNetworkWidgets(tester);

      // Quick edit button should be visible
      expect(find.byKey(const ValueKey('quick-edit-assignees')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quick-edit-assignees')));
      await settleNetworkWidgets(tester);

      // Editor should open with title "修改指派 · #1"
      expect(find.text('修改指派 · #1'), findsOneWidget);
      expect(find.text('指派成員'), findsOneWidget);

      // Close editor
      await tester.tap(find.byIcon(Icons.close));
      await settleNetworkWidgets(tester);
      expect(find.text('修改指派 · #1'), findsNothing);
    });

    testWidgets('MR shows Reviewers section with quick-edit-reviewers button', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
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
          buildInfoLoader: _testBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);
      await openExplore(tester);

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await openProjectTab(tester, 'MR');
      await settleNetworkWidgets(tester);

      // Select MR !12
      await tester.tap(find.text('Improve private-project navigation'));
      await settleNetworkWidgets(tester);

      // Both assignees and reviewers sections should be present
      expect(find.byKey(const ValueKey('quick-assign-me')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-edit-assignees')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-edit-reviewers')), findsOneWidget);
    });
  });
}
