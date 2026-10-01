import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart' show SemanticButton;
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
  commit: 'wide_back_test',
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

  group('P2-BACK: Wide Two-Pane System Back Navigation Suite', () {
    testWidgets('840 dp two-pane: system back pops Issue 42 first, then Project A on second back', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Wide Back Issue 42');
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

      // Select Project
      expect(find.text('Mobile Workspace'), findsOneWidget);
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Switch to 議題 tab (WorkItemsTab)
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Select Issue 42 -> Both list card on left and detail overview on right
      await tester.tap(find.text('Wide Back Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Wide Back Issue 42'), findsNWidgets(2));

      // First system back: tester.binding.handlePopRoute()
      final handledFirst = await tester.binding.handlePopRoute();
      expect(handledFirst, isTrue, reason: 'First system back must be consumed by Issue 42 selection');
      await settleNetworkWidgets(tester);

      // Verify after 1st back:
      // Detail is cleared (shows empty state), left list remains visible, Project remains open
      expect(find.text('Overview'), findsNothing, reason: 'Issue 42 detail must be cleared');
      expect(find.text('請選擇議題'), findsOneWidget, reason: 'Right pane must return to empty state');
      expect(find.text('Wide Back Issue 42'), findsOneWidget, reason: 'Issues list must remain on left pane');
      expect(find.text('檔案'), findsOneWidget, reason: 'Project tabs must remain intact');
      expect(find.byKey(const Key('projectSearch')), findsNothing, reason: 'Must NOT have exited project');

      // Second system back: pops Project
      final handledSecond = await tester.binding.handlePopRoute();
      expect(handledSecond, isTrue, reason: 'Second system back must exit Project');
      await settleNetworkWidgets(tester);

      // Verify after 2nd back: back to Projects list
      expect(find.byKey(const Key('projectSearch')), findsOneWidget, reason: 'Must return to Projects list');
      expect(find.descendant(of: find.byType(SemanticButton), matching: find.text('Mobile Workspace')), findsOneWidget);
      expect(find.text('檔案'), findsNothing, reason: 'Project must be dismissed');
      expect(tester.takeException(), isNull);
    });

    testWidgets('1200 dp two-pane: system back pops Issue 42 first, then Project A on second back', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Wide Back Issue 42');
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

      // Select Project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Switch to 議題 tab
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Select Issue 42
      await tester.tap(find.text('Wide Back Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // First system back
      final handledFirst = await tester.binding.handlePopRoute();
      expect(handledFirst, isTrue, reason: 'First system back must clear Issue selection at 1200 dp');
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsNothing);
      expect(find.text('請選擇議題'), findsOneWidget);
      expect(find.text('Wide Back Issue 42'), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsNothing);

      // Second system back
      final handledSecond = await tester.binding.handlePopRoute();
      expect(handledSecond, isTrue, reason: 'Second system back must exit Project at 1200 dp');
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('840 dp two-pane: system back pops MR 12 first, then Project A on second back', (tester) async {
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

      // Select Project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Switch to MR tab (Tab 2)
      await tester.tap(find.text('MR'));
      await settleNetworkWidgets(tester);

      // Select MR 12
      expect(find.text('Improve private-project navigation'), findsOneWidget);
      await tester.tap(find.text('Improve private-project navigation'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // First system back
      final handledFirst = await tester.binding.handlePopRoute();
      expect(handledFirst, isTrue, reason: 'First system back must clear MR selection');
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsNothing);
      expect(find.text('請選擇合併請求'), findsOneWidget);
      expect(find.text('Improve private-project navigation'), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsNothing);

      // Second system back
      final handledSecond = await tester.binding.handlePopRoute();
      expect(handledSecond, isTrue, reason: 'Second system back must exit Project');
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('840 dp two-pane: Project AppBar BackButton directly leaves project (tested separately from system back)', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'AppBar Back Test Issue');
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

      await tester.tap(find.text('AppBar Back Test Issue'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Tapping the AppBar BackButton directly switches project / returns to projects list
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(find.descendant(of: find.byType(SemanticButton), matching: find.text('Mobile Workspace')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('1200 dp two-pane: system back pops MR 12 first, then Project A on second back', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
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

      // Select Project
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);

      // Switch to MR tab (Tab 2)
      await tester.tap(find.text('MR'));
      await settleNetworkWidgets(tester);

      // Select MR 12
      expect(find.text('Improve private-project navigation'), findsOneWidget);
      await tester.tap(find.text('Improve private-project navigation'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // First system back
      final handledFirst = await tester.binding.handlePopRoute();
      expect(handledFirst, isTrue, reason: 'First system back must clear MR selection at 1200 dp');
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsNothing);
      expect(find.text('請選擇合併請求'), findsOneWidget);
      expect(find.text('Improve private-project navigation'), findsOneWidget);
      expect(find.byKey(const Key('projectSearch')), findsNothing);

      // Second system back
      final handledSecond = await tester.binding.handlePopRoute();
      expect(handledSecond, isTrue, reason: 'Second system back must exit Project at 1200 dp');
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('1200 dp two-pane: Project AppBar BackButton directly leaves project (tested separately from system back)', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'AppBar Back 1200dp Test Issue');
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

      await tester.tap(find.text('AppBar Back 1200dp Test Issue'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(find.descendant(of: find.byType(SemanticButton), matching: find.text('Mobile Workspace')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('839 <-> 840 dp boundary crossing preserves Issue selection and responds to two-pane system back', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(839, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Boundary 839-840 Issue');
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

      // Select Project -> Issues
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      // Select Issue 42 at 839 dp (Medium single column with NavigationRail)
      await tester.tap(find.text('Boundary 839-840 Issue'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Resize: 839 -> 840 dp (Crosses Expanded Two-Pane threshold)
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      // In Two-Pane mode: both left list card and right detail overview are visible
      expect(find.text('Boundary 839-840 Issue'), findsNWidgets(2));
      expect(find.text('Overview'), findsOneWidget);

      // First system back: clears Issue 42 selection to empty state
      final handledFirst = await tester.binding.handlePopRoute();
      expect(handledFirst, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsNothing);
      expect(find.text('請選擇議題'), findsOneWidget);
      expect(find.text('Boundary 839-840 Issue'), findsOneWidget);

      // Second system back: exits project
      final handledSecond = await tester.binding.handlePopRoute();
      expect(handledSecond, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('599 <-> 600 dp boundary crossing preserves wide two-pane selection and navigation continuity', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(599, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Boundary 599-600 Issue');
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

      // At 599 dp: NavigationBar is active
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Boundary 599-600 Issue'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Resize: 599 -> 600 dp (NavigationBar -> NavigationRail switch, P1-1 structure preserved)
      tester.view.physicalSize = const Size(600, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Overview'), findsOneWidget, reason: 'Issue detail preserved across 599-600 shell transition');

      // Resize: 600 -> 840 dp (Expanded Two-Pane)
      tester.view.physicalSize = const Size(840, 900);
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.text('Boundary 599-600 Issue'), findsNWidgets(2));
      expect(find.text('Overview'), findsOneWidget);

      // First system back pops Issue
      final handledFirst = await tester.binding.handlePopRoute();
      expect(handledFirst, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsNothing);
      expect(find.text('請選擇議題'), findsOneWidget);

      // Second system back exits Project
      final handledSecond = await tester.binding.handlePopRoute();
      expect(handledSecond, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.byKey(const Key('projectSearch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cross-tab isolation: switching to CI tab suppresses PopScope consumption and preserves Project tab state on return', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Cross Tab Issue 42');
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

      // Enter Project -> Issues -> select Issue 42
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Cross Tab Issue 42'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Switch to CI tab in NavigationRail (destination index 2)
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('CI')));
      await settleNetworkWidgets(tester);

      // Trigger system back while on CI tab
      await tester.binding.handlePopRoute();
      await settleNetworkWidgets(tester);

      // Switch back to Projects tab in NavigationRail
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('專案')));
      await settleNetworkWidgets(tester);

      // Assert: Issue 42 and its overview are STILL intact on the Project tab!
      expect(find.text('Overview'), findsOneWidget, reason: 'Issue detail must not be dismissed by back while hidden in inactive tab');
      expect(find.text('Cross Tab Issue 42'), findsNWidgets(2));

      // Now on active tab, system back clears Issue 42
      final handledActive = await tester.binding.handlePopRoute();
      expect(handledActive, isTrue);
      await settleNetworkWidgets(tester);

      expect(find.text('Overview'), findsNothing);
      expect(find.text('請選擇議題'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Account switch cleanup in wide mode clears active selection and resets navigation hierarchy', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Account Switch Wide Issue');

      final customAdapter = FakeAdapter((request) {
        final segments = request.uri.pathSegments;
        final start = segments.indexOf('v4');
        final path = segments.skip(start + 1).toList();
        final joined = path.join('/');

        final token = '${request.headers['PRIVATE-TOKEN'] ?? request.headers['private-token']}';
        if (joined == 'user') {
          if (token.contains('second-account-token')) {
            return jsonResponse({'id': 99, 'username': 'user_second', 'name': 'Second User'});
          }
        }
        if (joined == 'projects') {
          if (token.contains('second-account-token')) {
            return jsonResponse([
              {
                ...fixture.projectRecord,
                'id': 202,
                'name': 'Second Account Project',
              }
            ]);
          }
        }
        return fixture.respond(request);
      });

      final store = MemoryAccountStore();
      final session = controllerFor(store, customAdapter);
      addTearDown(session.dispose);
      addTearDown(fixture.api.close);

      await tester.runAsync(() async {
        await session.initialize();
        await session.connect('https://example.com/gitlab', 'first-account-token');
      });

      await tester.pumpWidget(
        ListenableBuilder(
          listenable: session,
          builder: (context, _) => AuthenticatedApp(
            key: ValueKey(session.generation),
            session: session,
            appearance: appearance,
            shortcuts: shortcuts,
            buildInfoLoader: _shellBuildInfo,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // Select Project -> Issues -> Issue 42 on Account 1
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Account Switch Wide Issue'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Now switch account to Account 2
      await tester.runAsync(() async {
        await session.connect('https://example.com/gitlab', 'second-account-token');
      });
      await tester.pump();
      await settleNetworkWidgets(tester);

      // Verify: Account 1's project and issue are completely unmounted and cleared
      expect(find.text('Account Switch Wide Issue'), findsNothing);
      expect(find.text('Overview'), findsNothing);
      expect(find.text('Second Account Project'), findsOneWidget, reason: 'Root projects screen of Account 2 shown');
      expect(tester.takeException(), isNull);
    });
  });
}
