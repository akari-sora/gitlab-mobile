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

Future<BuildInfo> _approvalsTestBuildInfo() async => const BuildInfo(
  version: '0.4.0',
  buildNumber: '6',
  commit: 'mr_approvals_test',
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

  group('MR !30: MR Review & Approvals Decision Card Suite', () {
    testWidgets('MR shows Approvals card, allows external user to approve and unapprove', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      // Set MR author to someone else so that current user (id: 7) can approve
      fixture.mrAuthorId = 99;
      fixture.approvalsRequired = 1;

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
          buildInfoLoader: _approvalsTestBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);
      await openExplore(tester);

      // Navigate to Project -> MR
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await openProjectTab(tester, 'MR');
      await settleNetworkWidgets(tester);

      // Select MR !12
      await tester.tap(find.text('Improve private-project navigation'));
      await settleNetworkWidgets(tester);

      // Verify Approvals card is displayed
      expect(find.textContaining('審查核准進度'), findsOneWidget);
      expect(find.byKey(const ValueKey('mr-approve-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('mr-unapprove-btn')), findsNothing);

      // Tap "批准" button
      await tester.tap(find.byKey(const ValueKey('mr-approve-btn')));
      await settleNetworkWidgets(tester);

      // Confirm approval dialog
      expect(find.text('批准目前版本？'), findsOneWidget);
      expect(find.text('確認'), findsOneWidget);
      await tester.tap(find.text('確認'));
      await settleNetworkWidgets(tester);

      // Verify: Status updated to reached threshold, button changed to "撤回我的批准"
      expect(find.textContaining('已達核准門檻'), findsOneWidget);
      expect(find.byKey(const ValueKey('mr-unapprove-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('mr-approve-btn')), findsNothing);

      // Tap "撤回我的批准"
      await tester.tap(find.byKey(const ValueKey('mr-unapprove-btn')));
      await settleNetworkWidgets(tester);

      // Verify: Reverted to "批准"
      expect(find.byKey(const ValueKey('mr-approve-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('mr-unapprove-btn')), findsNothing);
    });

    testWidgets('MR shows reached threshold when pre-approved by another reviewer', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.approvalsRequired = 1;
      fixture.approvalsList.add({
        'user': {'id': 8, 'username': 'reviewer', 'name': 'Reviewer'}
      });

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
          buildInfoLoader: _approvalsTestBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);
      await openExplore(tester);

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await openProjectTab(tester, 'MR');
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Improve private-project navigation'));
      await settleNetworkWidgets(tester);

      // Verify: Shows "已達核准門檻（1 人已批准）" and mentions @reviewer
      expect(find.textContaining('已達核准門檻'), findsOneWidget);
      expect(find.textContaining('@reviewer'), findsOneWidget);
      expect(find.byKey(const ValueKey('mr-approve-btn')), findsOneWidget);
    });
  });
}
