import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Future<BuildInfo> _shellBuildInfo() async => const BuildInfo(
  version: '0.4.0',
  buildNumber: '4',
  commit: 'mutation_sync_test',
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

  group('P2-MUTATION: Resident Work Items Feed Mutation Synchronization Suite', () {
    testWidgets('Create issue in two-pane mode synchronizes to resident list feed without manual refresh', (tester) async {
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
          buildInfoLoader: _shellBuildInfo,
        ),
      );
      await settleNetworkWidgets(tester);

      // Select Project -> Issues tab
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Tap + button to create issue
      expect(find.byTooltip('新增議題'), findsOneWidget);
      await tester.tap(find.byTooltip('新增議題'));
      await settleNetworkWidgets(tester);

      // Enter issue title in editor
      expect(find.byKey(const ValueKey('editor-title')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Brand New Synchronized Issue');
      await tester.pump();

      // Save editor
      expect(find.byKey(const Key('editorSave')), findsOneWidget);
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleNetworkWidgets(tester);

      // Verify: In two-pane mode, both the left list card and right detail title display 'Brand New Synchronized Issue'
      // without needing manual refresh!
      expect(
        find.text('Brand New Synchronized Issue'),
        findsNWidgets(2),
        reason: 'Resident list feed on the left must synchronize and display the newly created issue',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Edit issue in two-pane mode synchronizes updated title to resident list feed', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Original Issue Title 42');
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

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Select Issue 42
      await tester.tap(find.text('Original Issue Title 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Original Issue Title 42'), findsNWidgets(2));

      // Tap More Actions -> Edit
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('編輯'));
      await settleNetworkWidgets(tester);

      // Edit title
      await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Updated Issue Title 42');
      await tester.pump();
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleNetworkWidgets(tester);

      // Verify: Right detail shows updated title
      expect(find.text('Overview'), findsOneWidget);
      // Verify: Left list card MUST ALSO display the updated title, not the stale old title!
      expect(find.text('Original Issue Title 42'), findsNothing, reason: 'Old title must be gone from list');
      expect(
        find.text('Updated Issue Title 42'),
        findsNWidgets(2),
        reason: 'Both list pane and detail pane must show the updated title without manual refresh',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Close issue in two-pane mode removes closed issue from opened list feed', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Issue To Be Closed');
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

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Select Issue 42
      await tester.tap(find.text('Issue To Be Closed'));
      await settleNetworkWidgets(tester);
      expect(find.text('Issue To Be Closed'), findsNWidgets(2));

      // Tap More Actions -> Close
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('關閉'));
      await settleNetworkWidgets(tester);

      // Verify: Right detail shows '已關閉' status in StatusBadge
      expect(find.widgetWithText(StatusBadge, '已關閉'), findsOneWidget);
      // Verify: In the opened list on the left pane, 'Issue To Be Closed' card must be removed!
      // Only the detail header on the right shows the title now (count == 1, not 2)
      expect(
        find.text('Issue To Be Closed'),
        findsNWidgets(1),
        reason: 'Closed issue must be removed from the opened issues list feed',
      );

      // Switch filter to '已關閉' (closed) chip
      await tester.tap(find.widgetWithText(ChoiceChip, '已關閉'));
      await settleNetworkWidgets(tester);

      // Verify: Now it appears in the closed list!
      expect(find.text('Issue To Be Closed'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Readonly viewing and resizing triggers zero extra feed requests', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      int issuesListRequestCount = 0;
      int issueDetailRequestCount = 0;

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Readonly Test Issue 42');

      final customAdapter = FakeAdapter((request) {
        final segments = request.uri.pathSegments;
        final start = segments.indexOf('v4');
        final path = segments.skip(start + 1).toList();
        final joined = path.join('/');

        if (joined == 'projects/42/issues' && request.method == 'GET') {
          issuesListRequestCount++;
        }
        if (joined == 'projects/42/issues/42' && request.method == 'GET') {
          issueDetailRequestCount++;
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

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // List requested exactly once on initial load
      expect(issuesListRequestCount, equals(1));

      // Select Issue 42
      await tester.tap(find.text('Readonly Test Issue 42'));
      await settleNetworkWidgets(tester);

      expect(issueDetailRequestCount, equals(1));
      expect(issuesListRequestCount, equals(1), reason: 'Selecting an issue must NOT re-fetch the list');

      // Dynamic resize: 840 -> 1200 dp
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(issuesListRequestCount, equals(1), reason: 'Resize to 1200 dp must NOT re-fetch issues list');
      expect(issueDetailRequestCount, equals(1), reason: 'Resize to 1200 dp must NOT re-fetch issue detail');

      // Dynamic resize: 1200 -> 412 dp
      tester.view.physicalSize = const Size(412, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(issuesListRequestCount, equals(1), reason: 'Resize to 412 dp must NOT re-fetch issues list');
      expect(issueDetailRequestCount, equals(1), reason: 'Resize to 412 dp must NOT re-fetch issue detail');

      // System back in compact mode to return to list
      final handled = await tester.binding.handlePopRoute();
      expect(handled, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsNothing);
      expect(find.text('Readonly Test Issue 42'), findsOneWidget);
      expect(issuesListRequestCount, equals(1), reason: 'Readonly back navigation must NOT trigger list re-fetch');
      expect(tester.takeException(), isNull);
    });
  });
}
