import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/activity_page.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/file_history.dart';
import 'package:gitlab_mobile/features/workspace/groups_page.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/reactions.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/features/workspace/search_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/scroll_chrome.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

void _phone(WidgetTester tester, {Size size = const Size(412, 860)}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ScrollMetrics _metrics(double pixels, {double max = 2000}) => FixedScrollMetrics(
  minScrollExtent: 0, maxScrollExtent: max, pixels: pixels, viewportDimension: 600,
  axisDirection: AxisDirection.down, devicePixelRatio: 1);

void main() {
  group('ScrollChromeController', () {
    final context = _FakeContext();
    ScrollUpdateNotification update(double pixels, double delta) => ScrollUpdateNotification(
      metrics: _metrics(pixels), context: context, scrollDelta: delta, dragDetails: DragUpdateDetails(
        globalPosition: Offset.zero, delta: Offset(0, -delta)));

    test('hides after scrolling down past the top slop and shows on scroll up', () {
      final chrome = ScrollChromeController();
      addTearDown(chrome.dispose);
      chrome.handle(update(30, 30));
      expect(chrome.value, isTrue, reason: 'still inside the top slop');
      chrome.handle(update(120, 20));
      chrome.handle(update(140, 20));
      expect(chrome.value, isFalse);
      chrome.handle(update(130, -10));
      expect(chrome.value, isFalse, reason: 'small reversals do not flicker the chrome');
      chrome.handle(update(100, -30));
      expect(chrome.value, isTrue);
    });

    test('returns at the top, ignores horizontal and programmatic scrolls', () {
      final chrome = ScrollChromeController();
      addTearDown(chrome.dispose);
      chrome.handle(update(300, 40));
      expect(chrome.value, isFalse);
      chrome.handle(ScrollUpdateNotification(metrics: _metrics(600), context: context, scrollDelta: -300));
      expect(chrome.value, isFalse, reason: 'a jump without a drag leaves it alone');
      chrome.handle(ScrollUpdateNotification(metrics: FixedScrollMetrics(minScrollExtent: 0, maxScrollExtent: 900,
        pixels: 0, viewportDimension: 400, axisDirection: AxisDirection.right, devicePixelRatio: 1),
        context: context, scrollDelta: -50));
      expect(chrome.value, isFalse, reason: 'horizontal scrolling is ignored');
      chrome.handle(update(10, -290));
      expect(chrome.value, isTrue);
    });

    test('a list too short to scroll always keeps the chrome', () {
      final chrome = ScrollChromeController()..hide();
      addTearDown(chrome.dispose);
      chrome.handle(ScrollUpdateNotification(metrics: _metrics(0, max: 0), context: context, scrollDelta: 5));
      expect(chrome.value, isTrue);
    });
  });

  testWidgets('CollapsingChrome shrinks its child to zero height and back', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      CollapsingChrome(visible: visible, child: const SizedBox(key: Key('header'), height: 80)),
      const Expanded(child: SizedBox()),
    ]))));
    expect(tester.getSize(find.byType(CollapsingChrome)).height, 80);
    visible.value = false;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CollapsingChrome)).height, 0);
    visible.value = true;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CollapsingChrome)).height, 80);
  });

  testWidgets('scroll-top signal returns a feed to its first row', (tester) async {
    final signal = ValueNotifier(0);
    addTearDown(signal.dispose);
    final adapter = FakeAdapter((_) => jsonResponse([
      for (var i = 1; i <= 40; i++) {'id': i, 'name': 'Row $i'},
    ]));
    final api = testApi(adapter);
    addTearDown(api.close);
    final feed = GlobalKey<RecordsFeedState>();
    await tester.pumpWidget(workspaceHost(Scaffold(body: ScrollTopSignal(notifier: signal, child: RecordsFeed(
      key: feed, identity: 'rows', load: (next) => api.records(['rows'], next: next),
      itemBuilder: (context, value) => SizedBox(height: 60, child: Text(valueText(value, 'name'))),
    )))));
    await settleNetworkWidgets(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('Row 1'), findsNothing);
    signal.value++;
    await tester.pumpAndSettle();
    expect(find.text('Row 1'), findsOneWidget);
  });

  testWidgets('scoped labels render as two joined segments with the full name announced', (tester) async {
    await tester.pumpWidget(workspaceHost(const Scaffold(body: Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
      LabelPill('priority::high', color: Color(0xFFD9534F)),
      LabelPill('bug', color: Color(0xFF428BCA)),
    ])))));
    expect(find.text('priority'), findsOneWidget);
    expect(find.text('high'), findsOneWidget);
    expect(find.text('bug'), findsOneWidget);
    expect(find.bySemanticsLabel('priority::high'), findsOneWidget);
  });

  test('labelDetails reads names and colours from either label shape', () {
    final details = labelDetails({
      'labels': ['plain', {'name': 'colored', 'color': '#00ff00', 'text_color': '#000000'}, {'name': ''}, 3],
    });
    expect(details.map((d) => d.name), ['plain', 'colored']);
    expect(details.last.color, const Color(0xFF00FF00));
    expect(details.first.color, isNull);
  });

  test('stageOrder lists stages in creation order and jobs inside by id', () {
    final ordered = stageOrder([
      {'id': 9, 'stage': 'deploy'}, {'id': 4, 'stage': 'test'}, {'id': 2, 'stage': 'build'},
      {'id': 5, 'stage': 'test'}, {'id': 3, 'stage': 'build'},
    ]);
    expect(ordered.map((j) => j['id']), [2, 3, 4, 5, 9]);
    expect(formatDuration(42), '42 秒');
    expect(formatDuration(83), '1 分 23 秒');
    expect(formatDuration(3720), '1 小時 2 分');
  });

  test('activity sentences describe pushes, state changes and comments', () {
    expect(activitySentence({'action_name': 'pushed to',
      'push_data': {'ref': 'main', 'ref_type': 'branch', 'commit_count': 3, 'action': 'pushed'}}), '推送到分支 main（3 個提交）');
    expect(activitySentence({'action_name': 'opened', 'target_type': 'MergeRequest', 'target_iid': 7}), '開啟了合併請求 !7');
    expect(activitySentence({'action_name': 'commented on', 'target_type': 'Note',
      'note': {'noteable_type': 'Issue', 'noteable_iid': 12, 'body': 'hi'}}), '留言於議題 #12');
    expect(activitySentence({'action_name': 'joined'}), '加入了專案');
  });

  test('draft toggling adds Draft: and strips every prefix GitLab recognises', () {
    expect(toggledDraftTitle('Ship navigation', false), 'Draft: Ship navigation');
    expect(toggledDraftTitle('Draft: Ship navigation', true), 'Ship navigation');
    expect(toggledDraftTitle('[Draft] Ship', true), 'Ship');
    expect(toggledDraftTitle('(draft) Ship', true), 'Ship');
    expect(toggledDraftTitle('WIP: Ship', true), 'Ship');
    expect(toggledDraftTitle('Drafting docs', true), 'Drafting docs');
  });

  test('find-file matching accepts substrings and in-order characters', () {
    expect(findFileMatches('lib/features/workspace/repository_page.dart', 'repository'), isTrue);
    expect(findFileMatches('lib/features/workspace/repository_page.dart', 'rpp'), isTrue);
    expect(findFileMatches('lib/main.dart', 'xyz'), isFalse);
  });

  testWidgets('reactions toggle the signed-in user award on and off', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(1, 'Reaction target');
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: ReactionsBar(
      account: fixture.account, api: fixture.api, project: fixture.project, resource: 'issues', iid: 1)))));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('reaction-add')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.bySemanticsLabel('rocket'));
    await settleNetworkWidgets(tester);
    expect(fixture.awards['projects/42/issues/1']!.single['name'], 'rocket');
    expect(find.text('🚀 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reaction-rocket')));
    await settleNetworkWidgets(tester);
    expect(fixture.awards['projects/42/issues/1'], isEmpty);
    expect(find.text('🚀 1'), findsNothing);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('on a phone an open issue hides the project header and tabs instead of stacking', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(1, 'Phone detail issue');
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project)));
    await settleNetworkWidgets(tester);
    await tester.tap(find.widgetWithText(Tab, '議題'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('Phone detail issue'));
    await settleNetworkWidgets(tester);
    expect(find.byType(WorkItemPage), findsOneWidget);
    // One app bar: the project's header and tab bar step aside for the issue.
    expect(find.widgetWithText(Tab, '檔案'), findsNothing);
    expect(find.text('studio/mobile-workspace'), findsOneWidget, reason: 'only the issue app bar subtitle');
    expect(find.widgetWithText(Tab, '摘要'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    // The issue app bar sits directly under the status bar, not one inset lower.
    expect(tester.getTopLeft(find.text('#1')).dy, lessThan(40));
    await tester.tap(find.byType(BackButton));
    await settleNetworkWidgets(tester);
    expect(find.byType(WorkItemPage), findsNothing);
    expect(find.widgetWithText(Tab, '檔案'), findsOneWidget);
    expect(find.text('Phone detail issue'), findsOneWidget);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('issue detail shows reactions, details card and the notification switch', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    fixture.issues[1] = {
      ...fixture.issue(1, 'Detailed issue'),
      'subscribed': false,
      'due_date': '2026-12-31',
      'time_stats': {'human_time_estimate': '3h', 'human_total_time_spent': '1h 30m'},
    };
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project,
      resource: 'issues', iid: 1)));
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('reaction-add')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('work-item-subscribe')), 200,
      scrollable: find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first);
    expect(find.text('2026-12-31'), findsOneWidget);
    expect(find.text('已花費 1h 30m · 預估 3h'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('work-item-subscribe')));
    await settleNetworkWidgets(tester);
    expect(fixture.issues[1]!['subscribed'], isTrue);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('inbox todos can be swiped away and the write is sent once', (tester) async {
    _phone(tester);
    var done = 0;
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/todos') && request.method == 'GET') {
        return jsonResponse(done == 0 ? [{
          'id': 101, 'action_name': 'assigned', 'target_type': 'Issue', 'state': 'pending',
          'target': {'iid': 3, 'title': 'Swipe me'}, 'project': {'id': 10, 'path_with_namespace': 'team/core'},
          'author': {'username': 'lead'}, 'updated_at': '2026-09-20T10:00:00Z',
        }] : <Object>[]);
      }
      if (path.endsWith('/todos/101/mark_as_done') && request.method == 'POST') {
        done++;
        return jsonResponse({'id': 101, 'state': 'done'}, status: 201);
      }
      return jsonResponse(<Object>[]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(InboxPage(account: fixture.account, api: api)));
    await settleNetworkWidgets(tester);
    expect(find.text('Swipe me'), findsOneWidget);
    expect(find.byKey(const ValueKey('todos-mark-all-done')), findsOneWidget);
    await tester.drag(find.text('Swipe me'), const Offset(-500, 0));
    await settleNetworkWidgets(tester);
    expect(find.text('Swipe me'), findsNothing);
    expect(done, 1);
  });

  testWidgets('global search queries the chosen scope and lists results', (tester) async {
    _phone(tester);
    final requests = <RequestOptions>[];
    final adapter = FakeAdapter((request) {
      requests.add(request);
      if (request.uri.path.endsWith('/search')) {
        final scope = request.uri.queryParameters['scope'];
        return jsonResponse(scope == 'users'
          ? [{'id': 3, 'username': 'alice', 'name': 'Alice', 'state': 'active'}]
          : [{'id': 5, 'name': 'Mobile app', 'path_with_namespace': 'team/mobile-app', 'visibility': 'private',
              'last_activity_at': '2026-09-20T10:00:00Z'}]);
      }
      return jsonResponse(<Object>[]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(SearchPage(account: fixture.account, api: api)));
    await tester.pump();
    expect(find.text('搜尋專案、議題、合併請求與使用者'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('globalSearchField')), 'mobile');
    await tester.pump(const Duration(milliseconds: 450));
    await settleNetworkWidgets(tester);
    expect(find.text('Mobile app'), findsOneWidget);
    expect(requests.last.uri.queryParameters, containsPair('scope', 'projects'));
    await tester.tap(find.widgetWithText(ChoiceChip, '使用者'));
    await settleNetworkWidgets(tester);
    expect(find.text('@alice'), findsOneWidget);
    expect(requests.last.uri.queryParameters, containsPair('scope', 'users'));
  });

  testWidgets('a group page lists its projects and switches to subgroups', (tester) async {
    _phone(tester);
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/groups/9/projects')) {
        return jsonResponse([{'id': 42, 'name': 'Core app', 'path': 'core-app', 'path_with_namespace': 'team/core-app',
          'visibility': 'internal', 'last_activity_at': '2026-09-20T10:00:00Z'}]);
      }
      if (path.endsWith('/groups/9/subgroups')) {
        return jsonResponse([{'id': 10, 'name': 'Platform', 'full_path': 'team/platform', 'visibility': 'private'}]);
      }
      return jsonResponse(<Object>[]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(GroupPage(account: fixture.account, api: api,
      group: const {'id': 9, 'name': 'Team', 'full_path': 'team'})));
    await settleNetworkWidgets(tester);
    expect(find.text('Core app'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '子群組'));
    await settleNetworkWidgets(tester);
    expect(find.text('Platform'), findsOneWidget);
    expect(find.text('team/platform'), findsOneWidget);
  });

  testWidgets('pipeline jobs are grouped under their stages in pipeline order', (tester) async {
    _phone(tester);
    final fixture = _StagedPipeline();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(PipelinePage(account: fixture.account, api: fixture.api,
      project: fixture.project, id: 99)));
    await settleNetworkWidgets(tester);
    final build = tester.getTopLeft(find.text('build')).dy;
    final test = tester.getTopLeft(find.text('test')).dy;
    final compile = tester.getTopLeft(find.text('compile')).dy;
    final unit = tester.getTopLeft(find.text('unit tests')).dy;
    expect(build, lessThan(compile));
    expect(compile, lessThan(test));
    expect(test, lessThan(unit));
    expect(fixture.unhandled, isEmpty);
  });
}

class _FakeContext extends Fake implements BuildContext {}

class _StagedPipeline extends WorkspaceFixture {
  @override
  ResponseBody respond(RequestOptions request) {
    if (request.uri.path.endsWith('/pipelines/99/jobs')) {
      return jsonResponse([
        {'id': 12, 'name': 'unit tests', 'stage': 'test', 'status': 'success', 'duration': 61.0},
        {'id': 11, 'name': 'compile', 'stage': 'build', 'status': 'success', 'duration': 30.0},
      ]);
    }
    return super.respond(request) as ResponseBody;
  }
}
