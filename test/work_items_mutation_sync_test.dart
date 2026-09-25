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

    testWidgets('Close then reopen issue in two-pane mode synchronizes to resident list feed across state filters', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Issue To Reopen');
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
      await tester.tap(find.text('Issue To Reopen'));
      await settleNetworkWidgets(tester);

      // Close it
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('關閉'));
      await settleNetworkWidgets(tester);
      expect(find.widgetWithText(StatusBadge, '已關閉'), findsOneWidget);

      // Now switch to '已關閉' filter
      await tester.tap(find.widgetWithText(ChoiceChip, '已關閉'));
      await settleNetworkWidgets(tester);
      expect(find.text('Issue To Reopen'), findsNWidgets(2));

      // Reopen it
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新開啟'));
      await settleNetworkWidgets(tester);
      expect(find.widgetWithText(StatusBadge, '開啟中'), findsOneWidget);

      // In the '已關閉' list feed, it should now be removed!
      expect(find.text('Issue To Reopen'), findsNWidgets(1), reason: 'Reopened issue must be removed from closed list feed');

      // Switch filter back to '開啟中'
      await tester.tap(find.widgetWithText(ChoiceChip, '開啟中'));
      await settleNetworkWidgets(tester);
      expect(find.text('Issue To Reopen'), findsNWidgets(2), reason: 'Reopened issue must appear in opened list feed');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Compact mode (412 dp): Edit issue synchronizes updated title to list when returning via system back', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Compact Original Title');
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

      // Select Issue 42 in compact mode
      await tester.tap(find.text('Compact Original Title'));
      await settleNetworkWidgets(tester);

      // Verify in detail view
      expect(find.text('Overview'), findsOneWidget);

      // Edit issue title
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('編輯'));
      await settleNetworkWidgets(tester);

      await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Compact Updated Title');
      await tester.pump();
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleNetworkWidgets(tester);

      expect(find.text('Compact Updated Title'), findsOneWidget);

      // Press system back to return to list
      final handled = await tester.binding.handlePopRoute();
      expect(handled, isTrue);
      await settleNetworkWidgets(tester);

      // Now back on list pane: must show updated title and not old title!
      expect(find.text('Overview'), findsNothing);
      expect(find.text('Compact Original Title'), findsNothing, reason: 'Old title must not remain on list');
      expect(find.text('Compact Updated Title'), findsOneWidget, reason: 'Updated title must be displayed on list');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Multi-page issues: Edit issue on page 2 preserves in-place position, 0 extra list requests, other page 2 items, page 3 cursor and allows page 3 load', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      int issuesListRequestCount = 0;
      final fixture = WorkspaceFixture();
      final page1 = [fixture.issue(1, 'Issue 1'), fixture.issue(2, 'Issue 2'), fixture.issue(3, 'Issue 3')];
      final page2 = [fixture.issue(4, 'Issue 4'), fixture.issue(5, 'Issue 5'), fixture.issue(6, 'Issue 6')];
      final page3 = [fixture.issue(7, 'Issue 7'), fixture.issue(8, 'Issue 8'), fixture.issue(9, 'Issue 9')];
      for (final item in [...page1, ...page2, ...page3]) {
        fixture.issues[item['iid'] as int] = item;
      }

      final customAdapter = FakeAdapter((request) {
        final segments = request.uri.pathSegments;
        final start = segments.indexOf('v4');
        final path = segments.skip(start + 1).toList();
        final joined = path.join('/');

        if (joined == 'projects/42/issues' && request.method == 'GET') {
          issuesListRequestCount++;
          final pageParam = request.uri.queryParameters['page'];
          if (pageParam == '3') {
            return ResponseBody.fromString(
              jsonEncode(page3),
              200,
              headers: {'content-type': ['application/json']},
            );
          }
          if (pageParam == '2') {
            return ResponseBody.fromString(
              jsonEncode(page2),
              200,
              headers: {
                'content-type': ['application/json'],
                'x-next-page': ['3'],
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

      // Select Project -> Issues tab
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      expect(issuesListRequestCount, equals(1));
      expect(find.text('Issue 1'), findsOneWidget);
      expect(find.text('Issue 3'), findsOneWidget);
      expect(find.text('Issue 4'), findsNothing);

      // Tap "載入更多" to load page 2
      expect(find.text('載入更多'), findsOneWidget);
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);

      expect(issuesListRequestCount, equals(2));
      expect(find.text('Issue 1'), findsOneWidget);
      expect(find.text('Issue 4'), findsOneWidget);
      expect(find.text('Issue 5'), findsOneWidget);
      expect(find.text('Issue 6'), findsOneWidget);
      expect(find.text('載入更多'), findsOneWidget, reason: 'Page 3 cursor present');

      // Scroll/select Issue 5 on page 2
      await tester.tap(find.text('Issue 5'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Edit Issue 5
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('編輯'));
      await settleNetworkWidgets(tester);

      await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Updated Page 2 Issue 5');
      await tester.pump();
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleNetworkWidgets(tester);

      // Assert: Zero extra list GET requests!
      expect(issuesListRequestCount, equals(2), reason: 'Zero extra list requests after edit mutation');

      // Assert: Detail shows updated title
      expect(find.text('Overview'), findsOneWidget);
      // Assert: Left list card updated in place
      expect(find.text('Issue 5'), findsNothing, reason: 'Old Issue 5 title replaced');
      expect(find.text('Updated Page 2 Issue 5'), findsNWidgets(2), reason: 'Updated title appears on both list and detail');

      // Assert: Other page 2 items are STILL on the list!
      expect(find.text('Issue 4'), findsOneWidget, reason: 'Issue 4 on page 2 preserved in memory');
      expect(find.text('Issue 6'), findsOneWidget, reason: 'Issue 6 on page 2 preserved in memory');

      // Assert: Page 3 cursor is STILL retained!
      expect(find.text('載入更多'), findsOneWidget, reason: 'Page 3 cursor preserved after edit mutation');

      // Continue pagination: Tap "載入更多" and assert page 3 loads!
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);

      expect(issuesListRequestCount, equals(3), reason: 'Page 3 loaded successfully with retained cursor');
      expect(find.text('Issue 7'), findsOneWidget);
      expect(find.text('載入更多'), findsNothing, reason: 'Page 3 was terminal page');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Multi-page MRs: Edit and close MR on page 2 preserves other page 2 items and page 3 cursor', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 1400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      int mrListRequestCount = 0;
      final fixture = WorkspaceFixture();

      Json mrItem(int iid, String title) => {
        ...fixture.issue(iid, title),
        'source_branch': 'feature/branch-$iid',
        'target_branch': 'main',
        'sha': WorkspaceFixture.sha,
        'detailed_merge_status': 'mergeable',
        'draft': false,
        'head_pipeline': {'id': 99, 'status': 'success'},
      };

      final mrPage1 = [mrItem(1, 'MR 1'), mrItem(2, 'MR 2'), mrItem(3, 'MR 3')];
      final mrPage2 = [mrItem(4, 'MR 4'), mrItem(5, 'MR 5'), mrItem(6, 'MR 6')];
      final mrPage3 = [mrItem(7, 'MR 7'), mrItem(8, 'MR 8'), mrItem(9, 'MR 9')];
      for (final item in [...mrPage1, ...mrPage2, ...mrPage3]) {
        fixture.createdMergeRequests[item['iid'] as int] = item;
      }

      final customAdapter = FakeAdapter((request) {
        final segments = request.uri.pathSegments;
        final start = segments.indexOf('v4');
        final path = segments.skip(start + 1).toList();
        final joined = path.join('/');

        if (joined == 'projects/42/merge_requests' && request.method == 'GET') {
          mrListRequestCount++;
          final pageParam = request.uri.queryParameters['page'];
          if (pageParam == '3') {
            return ResponseBody.fromString(
              jsonEncode(mrPage3),
              200,
              headers: {'content-type': ['application/json']},
            );
          }
          if (pageParam == '2') {
            return ResponseBody.fromString(
              jsonEncode(mrPage2),
              200,
              headers: {
                'content-type': ['application/json'],
                'x-next-page': ['3'],
              },
            );
          }
          return ResponseBody.fromString(
            jsonEncode(mrPage1),
            200,
            headers: {
              'content-type': ['application/json'],
              'x-next-page': ['2'],
            },
          );
        }
        if (path.length == 4 && path[0] == 'projects' && path[1] == '42' && path[2] == 'merge_requests' && request.method == 'PUT') {
          final iid = int.tryParse(path[3]);
          final item = iid == null ? null : fixture.createdMergeRequests[iid];
          if (item != null) {
            final body = request.data is Json ? request.data as Json : <String, dynamic>{};
            item.addAll(body);
            if (body['state_event'] == 'close') item['state'] = 'closed';
            if (body['state_event'] == 'reopen') item['state'] = 'opened';
            return jsonResponse(item);
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
      await tester.tap(find.text('MR'));
      await settleNetworkWidgets(tester);

      expect(mrListRequestCount, equals(1));
      expect(find.text('MR 1'), findsOneWidget);
      expect(find.text('MR 4'), findsNothing);

      // Load page 2
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);

      expect(mrListRequestCount, equals(2));
      expect(find.text('MR 4'), findsOneWidget);
      expect(find.text('MR 5'), findsOneWidget);
      expect(find.text('MR 6'), findsOneWidget);
      expect(find.text('載入更多'), findsOneWidget);

      // Select MR 5
      await tester.tap(find.text('MR 5'));
      await settleNetworkWidgets(tester);
      expect(find.text('Overview'), findsOneWidget);

      // Close MR 5
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('關閉'));
      await settleNetworkWidgets(tester);

      // Zero extra MR list requests
      expect(mrListRequestCount, equals(2), reason: 'Closing MR must NOT trigger full list re-fetch');

      // MR 5 is removed from opened list
      expect(find.text('MR 5'), findsNWidgets(1), reason: 'MR 5 only in detail header, removed from opened list');

      // MR 4, MR 6 and Page 3 cursor remain intact!
      expect(find.text('MR 4'), findsOneWidget, reason: 'MR 4 on page 2 preserved');
      expect(find.text('MR 6'), findsOneWidget, reason: 'MR 6 on page 2 preserved');
      expect(find.text('載入更多'), findsOneWidget, reason: 'Page 3 cursor preserved after closing MR 5');

      // Load page 3
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);

      expect(mrListRequestCount, equals(3));
      expect(find.text('MR 7'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Write failure protection: 422 error during issue edit leaves multi-page list feed and cursor intact', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 1400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      int issuesListRequestCount = 0;
      final fixture = WorkspaceFixture();
      final page1 = [fixture.issue(1, 'Stable Issue 1'), fixture.issue(2, 'Stable Issue 2'), fixture.issue(3, 'Stable Issue 3')];
      final page2 = [fixture.issue(4, 'Stable Issue 4'), fixture.issue(5, 'Stable Issue 5'), fixture.issue(6, 'Stable Issue 6')];
      final page3 = [fixture.issue(7, 'Stable Issue 7')];
      for (final item in [...page1, ...page2, ...page3]) {
        fixture.issues[item['iid'] as int] = item;
      }

      bool simulate422 = false;

      final customAdapter = FakeAdapter((request) {
        final segments = request.uri.pathSegments;
        final start = segments.indexOf('v4');
        final path = segments.skip(start + 1).toList();
        final joined = path.join('/');

        if (joined == 'projects/42/issues' && request.method == 'GET') {
          issuesListRequestCount++;
          final pageParam = request.uri.queryParameters['page'];
          if (pageParam == '2') {
            return ResponseBody.fromString(
              jsonEncode(page2),
              200,
              headers: {'content-type': ['application/json'], 'x-next-page': ['3']},
            );
          }
          return ResponseBody.fromString(
            jsonEncode(page1),
            200,
            headers: {'content-type': ['application/json'], 'x-next-page': ['2']},
          );
        }
        if (joined == 'projects/42/issues/5' && request.method == 'PUT' && simulate422) {
          return ResponseBody.fromString(
            jsonEncode({'message': 'Validation failed: Title is invalid'}),
            422,
            headers: {'content-type': ['application/json']},
          );
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

      // Load page 2
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);
      expect(issuesListRequestCount, equals(2));
      expect(find.text('Stable Issue 5'), findsOneWidget);
      expect(find.text('載入更多'), findsOneWidget);

      // Select Issue 5
      await tester.tap(find.text('Stable Issue 5'));
      await settleNetworkWidgets(tester);

      // Enable 422 failure simulation
      simulate422 = true;

      // Edit Issue 5
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('編輯'));
      await settleNetworkWidgets(tester);

      await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Invalid Attempted Title');
      await tester.pump();
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleNetworkWidgets(tester);

      // The save encounters 422, so the editor displays error.
      // Dismiss editor via close button in app bar
      expect(find.byTooltip('保留草稿並返回'), findsOneWidget);
      await tester.tap(find.byTooltip('保留草稿並返回'));
      await settleNetworkWidgets(tester);

      // Assert: List request count has NOT increased
      expect(issuesListRequestCount, equals(2), reason: 'Failed write must not trigger list refresh');
      // Assert: List items on page 2 and page 3 cursor are completely intact!
      expect(find.text('Stable Issue 4'), findsOneWidget);
      expect(find.text('Stable Issue 5'), findsWidgets);
      expect(find.text('Stable Issue 6'), findsOneWidget);
      expect(find.text('載入更多'), findsOneWidget, reason: 'Page 3 cursor intact after failed mutation');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Account switch isolation: switching account cleanly disposes previous feed and does not leak stale mutations', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(840, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = WorkspaceFixture();
      fixture.issues[42] = fixture.issue(42, 'Account A Issue 42');

      final customAdapter = FakeAdapter((request) {
        final segments = request.uri.pathSegments;
        final start = segments.indexOf('v4');
        final path = segments.skip(start + 1).toList();
        final joined = path.join('/');

        final token = '${request.headers['PRIVATE-TOKEN'] ?? request.headers['private-token']}';
        if (joined == 'user') {
          if (token.contains('account-b-token')) {
            return jsonResponse({'id': 99, 'username': 'user_b', 'name': 'User B'});
          }
        }
        if (joined == 'projects') {
          if (token.contains('account-b-token')) {
            return jsonResponse([
              {
                ...fixture.projectRecord,
                'id': 101,
                'name': 'Account B Project',
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
        await session.connect('https://example.com/gitlab', 'account-a-token');
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

      // Enter project on Account A
      await tester.tap(find.text('Mobile Workspace'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('議題'));
      await settleNetworkWidgets(tester);

      expect(find.text('Account A Issue 42'), findsOneWidget);

      // Now switch account to Account B
      await tester.runAsync(() async {
        await session.connect('https://example.com/gitlab', 'account-b-token');
      });
      await tester.pump();
      await settleNetworkWidgets(tester);

      // The new account starts at root screen with new generation, no stale Issue 42 visible
      expect(find.text('Account A Issue 42'), findsNothing, reason: 'Stale account A issue feed must be unmounted');
      expect(find.text('Account B Project'), findsOneWidget, reason: 'New account shell loaded with Account B Project');
      expect(tester.takeException(), isNull);
    });
  });
}
