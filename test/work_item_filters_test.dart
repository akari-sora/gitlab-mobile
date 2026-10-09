import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/work_item_filters.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/features/workspace/picker_sheet.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Widget _host(
  Widget child, {
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: Scaffold(body: child),
);

void _surface(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, 900 * 2);
}

int _listRequestCount(WorkspaceFixture fixture, String resource) => fixture
    .adapter
    .requests
    .where(
      (request) =>
          request.method == 'GET' &&
          request.uri.path.endsWith('/projects/42/$resource'),
    )
    .length;

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });

  testWidgets('applying filters commits visible search and mutation reloads server order', (tester) async {
    _surface(tester, 840);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    fixture.issues[1] = fixture.issue(1, 'Alpha task');
    await tester.pumpWidget(_host(WorkItemsTab(account: fixture.account,
      api: fixture.api, project: fixture.project, resource: 'issues')));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const Key('work-items-search')), 'Alpha');
    final initial = _listRequestCount(fixture, 'issues');
    await tester.tap(find.byTooltip('篩選與排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-apply')));
    await settleNetworkWidgets(tester);
    expect(_listRequestCount(fixture, 'issues'), initial + 1);
    expect(fixture.adapter.requests.lastWhere((r) =>
      r.uri.path.endsWith('/projects/42/issues')).uri.queryParameters['search'], 'Alpha');
    await tester.tap(find.text('Alpha task').first);
    await settleNetworkWidgets(tester);
    final count = _listRequestCount(fixture, 'issues');
    tester.widget<WorkItemPage>(find.byType(WorkItemPage)).onMutated?.call({
      ...fixture.issues[1]!, 'updated_at': '2026-10-02T08:00:00Z'});
    await settleNetworkWidgets(tester);
    expect(_listRequestCount(fixture, 'issues'), count + 1,
      reason: 'server must restore updated-at ordering and page membership');
  });

  test('filter query follows GitLab issue and merge-request contracts', () {
    final filters = WorkItemFilters(
      orderBy: WorkItemOrderBy.dueDate,
      sort: WorkItemSort.asc,
      scope: WorkItemScope.assignedToMe,
      labels: const [
        PickerChoice(id: 'bug', name: 'bug'),
        PickerChoice(id: 'mobile', name: 'mobile'),
      ],
      milestone: const PickerChoice(id: '101', name: 'v1.0.0'),
      assignee: const PickerChoice(id: '7', name: 'Developer'),
      author: const PickerChoice(id: '8', name: 'Author'),
      reviewer: const PickerChoice(id: '9', name: 'Reviewer'),
    );

    expect(filters.toQuery(mergeRequest: false), {
      'scope': 'assigned_to_me',
      'order_by': 'due_date',
      'sort': 'asc',
      'labels': 'bug,mobile',
      'milestone': 'v1.0.0',
      'assignee_id': '7',
      'author_id': '8',
    });
    expect(filters.toQuery(mergeRequest: true), {
      'scope': 'assigned_to_me',
      'order_by': 'updated_at',
      'sort': 'asc',
      'labels': 'bug,mobile',
      'milestone': 'v1.0.0',
      'assignee_id': '7',
      'author_id': '8',
      'reviewer_id': '9',
    });
    expect(
      filters.identity(mergeRequest: false),
      contains('order_by=due_date'),
    );
    expect(filters.identity(mergeRequest: true), contains('reviewer_id=9'));
  });

  test('mutated rows must still match every active filter before patching', () {
    const filters = WorkItemFilters(
      scope: WorkItemScope.assignedToMe,
      labels: [PickerChoice(id: 'bug', name: 'Bug')],
      milestone: PickerChoice(id: '101', name: 'v1.0.0'),
    );
    final matching = <String, dynamic>{
      'title': 'Fix crash',
      'description': 'Mobile regression',
      'author': {'id': 8},
      'assignees': [
        {'id': 7},
      ],
      'labels': ['bug', 'mobile'],
      'milestone': {'id': 101, 'title': 'v1.0.0'},
    };
    expect(
      filters.matches(
        matching,
        userId: 7,
        mergeRequest: false,
        search: 'crash',
      ),
      isTrue,
    );
    expect(
      filters.matches(
        {...matching, 'assignees': <dynamic>[]},
        userId: 7,
        mergeRequest: false,
        search: 'crash',
      ),
      isFalse,
    );
    expect(
      filters.matches(
        {
          ...matching,
          'labels': ['mobile'],
        },
        userId: 7,
        mergeRequest: false,
        search: 'crash',
      ),
      isFalse,
    );
  });

  testWidgets(
    'issue search submits explicitly and cancelled filters do not reload',
    (tester) async {
      _surface(tester, 412);
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      fixture.issues[1] = fixture.issue(1, 'Alpha task');
      fixture.issues[2] = fixture.issue(2, 'Beta task');

      await tester.pumpWidget(
        _host(
          WorkItemsTab(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            resource: 'issues',
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      final initial = _listRequestCount(fixture, 'issues');

      await tester.enterText(
        find.byKey(const Key('work-items-search')),
        'Alpha',
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _listRequestCount(fixture, 'issues'),
        initial,
        reason: 'typing alone must not spend a request',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settleNetworkWidgets(tester);
      expect(_listRequestCount(fixture, 'issues'), initial + 1);
      expect(
        fixture.adapter.requests
            .lastWhere(
              (request) => request.uri.path.endsWith('/projects/42/issues'),
            )
            .uri
            .queryParameters['search'],
        'Alpha',
      );

      await tester.tap(find.byTooltip('篩選與排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-scope-assigned')));
      await tester.tap(find.byKey(const Key('filter-cancel')));
      await tester.pumpAndSettle();
      expect(
        _listRequestCount(fixture, 'issues'),
        initial + 1,
        reason: 'cancelled draft filters must not reload',
      );

      await tester.tap(find.byTooltip('篩選與排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-order-by')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('到期日').last);
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byKey(const Key('filter-sort-asc')));
      await _tapVisible(tester, find.byKey(const Key('filter-scope-assigned')));
      await _tapVisible(tester, find.byKey(const Key('filter-labels')));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byKey(const ValueKey('picker-row-a')));
      await tester.tap(find.byKey(const Key('picker-done')));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byKey(const Key('filter-milestone')));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byKey(const ValueKey('picker-row-101')));
      await tester.tap(find.byKey(const Key('picker-done')));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byKey(const Key('filter-apply')));
      await settleNetworkWidgets(tester);

      final query = fixture.adapter.requests
          .lastWhere(
            (request) => request.uri.path.endsWith('/projects/42/issues'),
          )
          .uri
          .queryParameters;
      expect(query, containsPair('order_by', 'due_date'));
      expect(query, containsPair('sort', 'asc'));
      expect(query, containsPair('scope', 'assigned_to_me'));
      expect(query, containsPair('labels', 'a'));
      expect(query, containsPair('milestone', 'v1.0.0'));
      expect(query, containsPair('search', 'Alpha'));
    },
  );

  testWidgets(
    'merge request review scope reaches the server and reset restores defaults',
    (tester) async {
      _surface(tester, 412);
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        _host(
          WorkItemsTab(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            resource: 'merge_requests',
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.byTooltip('篩選與排序'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-scope-review')), findsOneWidget);
      await tester.tap(find.byKey(const Key('filter-scope-review')));
      await tester.tap(find.byKey(const Key('filter-reviewer')));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byKey(const ValueKey('picker-row-8')));
      await tester.tap(find.byKey(const Key('picker-done')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await settleNetworkWidgets(tester);

      var query = fixture.adapter.requests
          .lastWhere(
            (request) =>
                request.uri.path.endsWith('/projects/42/merge_requests'),
          )
          .uri
          .queryParameters;
      expect(query, containsPair('scope', 'reviews_for_me'));
      expect(query, containsPair('reviewer_id', '8'));
      expect(query, containsPair('order_by', 'updated_at'));
      expect(query, containsPair('sort', 'desc'));

      await tester.tap(find.byTooltip('篩選與排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-reset')));
      await tester.tap(find.byKey(const Key('filter-apply')));
      await settleNetworkWidgets(tester);
      query = fixture.adapter.requests
          .lastWhere(
            (request) =>
                request.uri.path.endsWith('/projects/42/merge_requests'),
          )
          .uri
          .queryParameters;
      expect(query, containsPair('scope', 'all'));
      expect(query.containsKey('reviewer_id'), isFalse);
    },
  );

  for (final width in [320.0, 412.0, 840.0]) {
    testWidgets('filter sheet fits ${width.toInt()}dp at 2x text scale', (tester) async {
      _surface(tester, width);
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        _host(
          WorkItemsTab(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            resource: 'issues',
          ),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('篩選與排序'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('work-item-filter-sheet')), findsOneWidget);
      expect(find.byKey(const Key('filter-apply')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
