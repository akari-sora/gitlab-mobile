import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

void _surface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('workItemCard renders confidential icon and milestone chip', (tester) async {
    _surface(tester);

    final rawIssue = {
      'id': 1001,
      'iid': 1,
      'title': 'Confidential security issue',
      'state': 'opened',
      'confidential': true,
      'milestone': {'id': 101, 'title': 'v1.0.0'},
      'updated_at': '2026-09-25T10:00:00Z',
    };

    await tester.pumpWidget(_host(Scaffold(
      body: Builder(
        builder: (context) => workItemCard(
          context,
          rawIssue,
          mr: false,
          onTap: () {},
        ),
      ),
    )));
    await tester.pump();

    // Verify confidential lock icon and chip
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(find.text('機密'), findsOneWidget);

    // Verify milestone chip
    expect(find.byIcon(Icons.tour_outlined), findsWidgets);
    expect(find.text('v1.0.0'), findsOneWidget);
  });

  testWidgets('WorkItemPage details header and summary render confidential badge and milestone', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(
      1,
      'Private security vulnerability',
      confidential: true,
      milestone: {'id': 101, 'title': 'v1.0.0', 'due_date': '2026-10-01'},
    );

    await tester.pumpWidget(_host(WorkItemPage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      resource: 'issues',
      iid: 1,
    )));
    await settleNetworkWidgets(tester);

    // Verify Header Chips
    expect(find.text('機密'), findsOneWidget);
    expect(find.text('v1.0.0'), findsWidgets);

    // Verify Summary section contains Milestone with due date
    expect(find.text('里程碑'), findsOneWidget);
    expect(find.text('（到期日：2026-10-01）'), findsOneWidget);
  });

  testWidgets('WorkItemsTab search input has debounce and clear button', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(1, 'Alpha task');
    fixture.issues[2] = fixture.issue(2, 'Beta task');

    await tester.pumpWidget(_host(Scaffold(
      body: WorkItemsTab(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'issues',
      ),
    )));
    await settleNetworkWidgets(tester);

    expect(find.text('Alpha task'), findsOneWidget);
    expect(find.text('Beta task'), findsOneWidget);

    // Enter search text
    final searchInput = find.byType(TextField);
    await tester.enterText(searchInput, 'Alpha');
    // Debounce is 300ms, not settled yet
    await tester.pump(const Duration(milliseconds: 100));
    // Wait past 300ms
    await tester.pump(const Duration(milliseconds: 250));
    await settleNetworkWidgets(tester);

    // Now query should filter to Alpha task only
    expect(find.text('Alpha task'), findsOneWidget);
    expect(find.text('Beta task'), findsNothing);

    // Clear button should be visible and working
    final clearBtn = find.byKey(const ValueKey('clear-work-items-search'));
    expect(clearBtn, findsOneWidget);
    await tester.tap(clearBtn);
    await settleNetworkWidgets(tester);

    // Both tasks visible again
    expect(find.text('Alpha task'), findsOneWidget);
    expect(find.text('Beta task'), findsOneWidget);
  });

  testWidgets('Issue creation sheet includes milestone picker and confidential toggle', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    await tester.pumpWidget(_host(Scaffold(
      body: WorkItemsTab(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'issues',
      ),
    )));
    await settleNetworkWidgets(tester);

    // Tap create issue
    await tester.tap(find.byTooltip('新增議題'));
    await settleNetworkWidgets(tester);

    // Enter title
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Security report');

    // Tap milestone picker
    await tester.ensureVisible(find.byKey(const ValueKey('editor-milestone_id')));
    await tester.tap(find.byKey(const ValueKey('editor-milestone_id')));
    await settleNetworkWidgets(tester);

    // Verify milestone options from fixture
    expect(find.text('v1.0.0'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('picker-row-101')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);

    // Toggle confidential switch
    await tester.ensureVisible(find.byKey(const ValueKey('editor-toggle-confidential')));
    await tester.tap(find.byKey(const ValueKey('editor-toggle-confidential')));
    await tester.pump();

    // Save
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);

    // Verify API POST request data
    final post = fixture.adapter.requests.lastWhere(
      (req) => req.method == 'POST' && req.uri.path.endsWith('/issues'),
    );
    final data = post.data as Map<String, dynamic>;
    expect(data['title'], 'Security report');
    expect(data['milestone_id'], 101);
    expect(data['confidential'], isTrue);
  });

  testWidgets('ReviewDiffPage displays review progress bar and toggle all viewed button', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    fixture.versionDiffs = [
      {'old_path': 'lib/a.dart', 'new_path': 'lib/a.dart', 'new_file': false, 'deleted_file': false, 'diff': '@@ -1,1 +1,2 @@\n context\n+added\n'},
      {'old_path': 'lib/b.dart', 'new_path': 'lib/b.dart', 'new_file': true, 'deleted_file': false, 'diff': '@@ -0,0 +1,1 @@\n+created\n'},
    ];

    await tester.pumpWidget(_host(Scaffold(
      body: ReviewDiffPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        iid: 12,
        expectedSha: WorkspaceFixture.sha,
      ),
    )));
    await settleNetworkWidgets(tester);

    // Initial review progress: 0/2
    expect(find.text('審查進度 (0/2)'), findsOneWidget);
    expect(find.text('全部標記已檢視'), findsOneWidget);

    // Tap single file viewed toggle
    final toggleA = find.byKey(const ValueKey('viewed-toggle-lib/a.dart'));
    expect(toggleA, findsOneWidget);
    await tester.tap(toggleA);
    await tester.pump();

    // Progress updated to 1/2
    expect(find.text('審查進度 (1/2)'), findsOneWidget);

    // Tap "全部標記已檢視" button
    final toggleAllBtn = find.byKey(const ValueKey('toggle-all-viewed'));
    await tester.tap(toggleAllBtn);
    await tester.pump();

    // Progress updated to 2/2, button changes to "全部取消"
    expect(find.text('審查進度 (2/2)'), findsOneWidget);
    expect(find.text('全部取消'), findsOneWidget);

    // Tap "全部取消"
    await tester.tap(toggleAllBtn);
    await tester.pump();
    expect(find.text('審查進度 (0/2)'), findsOneWidget);
    expect(find.text('全部標記已檢視'), findsOneWidget);
  });

  testWidgets('ReviewDiffPage interactive elements satisfy >= 48dp touch targets', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    fixture.versionDiffs = [
      {'old_path': 'lib/main.dart', 'new_path': 'lib/main.dart', 'new_file': false, 'deleted_file': false, 'diff': '@@ -1,1 +1,2 @@\n+line\n'},
    ];

    await tester.pumpWidget(_host(Scaffold(
      body: ReviewDiffPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        iid: 12,
        expectedSha: WorkspaceFixture.sha,
      ),
    )));
    await settleNetworkWidgets(tester);

    final toggleAllBtn = find.byKey(const ValueKey('toggle-all-viewed'));
    final toggleAllBox = tester.renderObject<RenderBox>(toggleAllBtn);
    expect(toggleAllBox.size.height, greaterThanOrEqualTo(48.0));

    final fileToggleBtn = find.byKey(const ValueKey('viewed-toggle-lib/main.dart'));
    final fileToggleBox = tester.renderObject<RenderBox>(fileToggleBtn);
    expect(fileToggleBox.size.width, greaterThanOrEqualTo(48.0));
    expect(fileToggleBox.size.height, greaterThanOrEqualTo(48.0));
  });

  testWidgets('_DiffFileScreen AppBar viewed toggle updates state and syncs with parent', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();

    await tester.pumpWidget(_host(Scaffold(
      body: ReviewDiffPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        iid: 12,
        expectedSha: WorkspaceFixture.sha,
      ),
    )));
    await settleNetworkWidgets(tester);

    // Tap on file tile to open _DiffFileScreen
    await tester.tap(find.text('lib/session.dart'));
    await settleNetworkWidgets(tester);

    // Verify viewed toggle button in AppBar
    final appBarToggle = find.byKey(const ValueKey('diff-file-viewed-toggle'));
    expect(appBarToggle, findsOneWidget);

    // Tap to mark as viewed
    await tester.tap(appBarToggle);
    await tester.pump();

    // Back to file list
    await tester.tap(find.byType(BackButton));
    await settleNetworkWidgets(tester);

    // Verify progress reflects viewed status (1/1)
    expect(find.text('審查進度 (1/1)'), findsOneWidget);
  });

  testWidgets('ReviewDiffPage correctly falls back to old_path for deleted files with empty new_path', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    fixture.versionDiffs = [
      {
        'old_path': 'lib/deleted_legacy.dart',
        'new_path': '',
        'new_file': false,
        'deleted_file': true,
        'diff': '@@ -1,2 +0,0 @@\n-old line 1\n-old line 2\n',
      },
    ];

    await tester.pumpWidget(_host(Scaffold(
      body: ReviewDiffPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        iid: 12,
        expectedSha: WorkspaceFixture.sha,
      ),
    )));
    await settleNetworkWidgets(tester);

    // Old path is rendered, not an empty title
    expect(find.text('lib/deleted_legacy.dart'), findsWidgets);
    expect(find.byIcon(Icons.indeterminate_check_box_outlined), findsOneWidget);

    // Open screen, check AppBar title
    await tester.tap(find.text('lib/deleted_legacy.dart'));
    await settleNetworkWidgets(tester);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text('lib/deleted_legacy.dart')), findsOneWidget);

    // Toggle viewed in AppBar and verify progress upon return
    final appBarToggle = find.byKey(const ValueKey('diff-file-viewed-toggle'));
    await tester.tap(appBarToggle);
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await settleNetworkWidgets(tester);

    expect(find.text('審查進度 (1/1)'), findsOneWidget);
  });

  testWidgets('WorkItemsTab search clear button displays immediately before debounce duration expires', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();

    await tester.pumpWidget(_host(Scaffold(
      body: WorkItemsTab(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'issues',
      ),
    )));
    await settleNetworkWidgets(tester);

    final searchInput = find.byType(TextField);
    await tester.enterText(searchInput, 'instant');
    // Only 1ms pump, debounce (300ms) has NOT fired yet
    await tester.pump(const Duration(milliseconds: 1));

    // Clear button should already be visible via ValueListenableBuilder!
    final clearBtn = find.byKey(const ValueKey('clear-work-items-search'));
    expect(clearBtn, findsOneWidget);

    // Tap clear button immediately
    await tester.tap(clearBtn);
    await tester.pump();

    expect(clearBtn, findsNothing);
  });
}

