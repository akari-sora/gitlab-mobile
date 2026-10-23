import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/activity_page.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/file_history.dart';
import 'package:gitlab_mobile/features/workspace/groups_page.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'package:gitlab_mobile/features/workspace/navigation.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/reactions.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/features/workspace/search_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/scroll_chrome.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;
import 'support/shell_nav.dart';

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

    test('a finger turning upward reveals only after the travel threshold', () {
      final chrome = ScrollChromeController();
      addTearDown(chrome.dispose);
      chrome.handle(update(300, 40));
      expect(chrome.value, isFalse);
      // A real drag reports the direction flip before any distance.
      chrome.handle(UserScrollNotification(metrics: _metrics(299), context: context, direction: ScrollDirection.forward));
      chrome.handle(update(290, -9));
      expect(chrome.value, isFalse, reason: 'jitter while scrolling down does not pop the chrome back');
      chrome.handle(update(260, -30));
      expect(chrome.value, isTrue);
    });

    test('content that scrolls only a little keeps the chrome', () {
      final chrome = ScrollChromeController();
      addTearDown(chrome.dispose);
      chrome.handle(ScrollUpdateNotification(metrics: _metrics(120, max: 150), context: context, scrollDelta: 60,
        dragDetails: DragUpdateDetails(globalPosition: Offset.zero, delta: const Offset(0, -60))));
      expect(chrome.value, isTrue, reason: 'hiding would grow the viewport past the content and bounce back');
    });

    ScrollUpdateNotification drag(double pixels, double delta, {required double max, required double viewport}) =>
      ScrollUpdateNotification(context: context, scrollDelta: delta,
        metrics: FixedScrollMetrics(minScrollExtent: 0, maxScrollExtent: max, pixels: pixels, viewportDimension: viewport,
          axisDirection: AxisDirection.down, devicePixelRatio: 1),
        dragDetails: DragUpdateDetails(globalPosition: Offset.zero, delta: Offset(0, -delta)));

    test('a list just above the threshold stays hidden while the grown viewport still scrolls', () {
      final chrome = ScrollChromeController();
      addTearDown(chrome.dispose);
      chrome.handle(drag(90, 40, max: 250, viewport: 450));
      expect(chrome.value, isFalse);
      // The collapse grew the viewport by 150 dp; 100 dp of content still scrolls.
      chrome.handle(drag(100, 10, max: 100, viewport: 600));
      expect(chrome.value, isFalse, reason: 'no bounce back while the finger keeps going');
      chrome.handle(drag(70, -30, max: 100, viewport: 600));
      expect(chrome.value, isTrue, reason: 'a scroll back still reveals it');
    });

    test('content that fits once the chrome is gone brings it back once and then keeps it', () {
      final chrome = ScrollChromeController();
      addTearDown(chrome.dispose);
      chrome.handle(drag(90, 40, max: 210, viewport: 450));
      expect(chrome.value, isFalse);
      chrome.handle(drag(0, -1, max: 0, viewport: 730));
      expect(chrome.value, isTrue, reason: 'nothing left to scroll, so nothing could reveal it');
      chrome.handle(drag(90, 40, max: 210, viewport: 450));
      expect(chrome.value, isTrue, reason: 'it learnt that hiding grows the viewport by 280 dp');
    });
  });

  testWidgets('a list slightly taller than the threshold hides the chrome without bouncing', (tester) async {
    final chrome = ScrollChromeController();
    addTearDown(chrome.dispose);
    // 600 dp window: 450 dp list over 150 dp of chrome; 700 dp of rows scroll 250 dp, or 100 dp once hidden.
    await tester.pumpWidget(MaterialApp(home: NotificationListener<ScrollNotification>(onNotification: chrome.handle,
      child: Column(children: [
        Expanded(child: ListView(children: [for (var i = 0; i < 14; i++) SizedBox(height: 50, child: Text('Row $i'))])),
        CollapsingChrome(visible: chrome, edge: AxisDirection.down, child: const SizedBox(height: 150)),
      ]))));
    final gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    for (var i = 0; i < 16; i++) {
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
    expect(tester.getSize(find.byType(CollapsingChrome)).height, 0);
  });

  testWidgets('a list running without tickers (out of sight) never moves the chrome', (tester) async {
    final chrome = ScrollChromeController();
    addTearDown(chrome.dispose);
    final onScreen = ValueNotifier(false);
    addTearDown(onScreen.dispose);
    await tester.pumpWidget(MaterialApp(home: NotificationListener<ScrollNotification>(
      onNotification: chrome.handle,
      child: ValueListenableBuilder<bool>(valueListenable: onScreen, builder: (context, enabled, _) => TickerMode(
        enabled: enabled,
        child: ListView(children: [for (var i = 0; i < 60; i++) SizedBox(height: 60, child: Text('Row $i'))]))),
    )));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(chrome.value, isTrue, reason: 'an inactive destination or the list behind a detail stays out of it');
    onScreen.value = true;
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(chrome.value, isFalse);
  });

  testWidgets('the scroll-top signal skips lists that are out of sight', (tester) async {
    final signal = ValueNotifier(0);
    final shown = ScrollController(), hidden = ScrollController();
    addTearDown(signal.dispose);
    addTearDown(shown.dispose);
    addTearDown(hidden.dispose);
    Widget list(ScrollController controller) => ScrollToTopOnSignal(controller: controller, child: ListView(
      controller: controller, children: [for (var i = 0; i < 60; i++) SizedBox(height: 60, child: Text('Row $i'))]));
    await tester.pumpWidget(MaterialApp(home: ScrollTopSignal(notifier: signal, child: Column(children: [
      Expanded(child: list(shown)),
      Expanded(child: TickerMode(enabled: false, child: list(hidden))),
    ]))));
    shown.jumpTo(900);
    hidden.jumpTo(900);
    await tester.pump();
    signal.value++;
    await tester.pumpAndSettle();
    expect(shown.offset, 0);
    expect(hidden.offset, 900);
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

  testWidgets('CollapsingChrome stays at full height for screen-reader navigation', (tester) async {
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(accessibleNavigation: true),
      child: Scaffold(body: Column(children: [
        CollapsingChrome(visible: visible, child: const SizedBox(key: Key('header'), height: 80)),
        const Expanded(child: SizedBox()),
      ])),
    )));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('header'))).height, 80);
  });

  testWidgets('a focused issue keeps horizontal swipes inside the detail', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(1, 'Swipe inside me');
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project)));
    await settleNetworkWidgets(tester);
    await openProjectTab(tester, '議題');
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('Swipe inside me'));
    await settleNetworkWidgets(tester);
    await tester.fling(find.byType(WorkItemPage), const Offset(-400, 0), 1500);
    await settleNetworkWidgets(tester);
    await tester.fling(find.byType(WorkItemPage), const Offset(-400, 0), 1500);
    await settleNetworkWidgets(tester);
    expect(find.byType(WorkItemPage), findsOneWidget, reason: 'the project tabs never page away from the open issue');
    await tester.tap(find.byType(BackButton));
    await settleNetworkWidgets(tester);
    expect(find.text('Swipe inside me'), findsOneWidget, reason: 'still on the issues tab after closing the detail');
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

  test('activity sentences use the language\'s spacing between verb and target', () {
    useLanguage(languageForTag('en')!);
    addTearDown(() => useLanguage(sourceLanguage));
    expect(activitySentence({'action_name': 'commented on', 'target_type': 'Note',
      'note': {'noteable_type': 'Issue', 'noteable_iid': 12, 'body': 'hi'}}), 'Commented on Issue #12');
    expect(activitySentence({'action_name': 'opened', 'target_type': 'MergeRequest', 'target_iid': 7}),
      'Opened Merge request !7');
    expect(activitySentence({'action_name': 'opened', 'target_type': 'Unknown', 'target_iid': 3}), 'Opened #3');

    useLanguage(languageForTag('ja')!);
    expect(activitySentence({'action_name': 'opened', 'target_type': 'MergeRequest', 'target_iid': 7}),
      'オープンしました（マージリクエスト） !7');

    // Arabic isolates the verb and the target separately and keeps the reference in one isolate.
    useLanguage(languageForTag('ar')!);
    expect(activitySentence({'action_name': 'opened', 'target_type': 'MergeRequest', 'target_iid': 7}),
      '\u2068فتح\u2069 \u2068طلب دمج\u2069 \u2068!7\u2069');
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
    await openProjectTab(tester, '議題');
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
    final subscribe = find.byKey(const ValueKey('work-item-subscribe'));
    await tester.scrollUntilVisible(subscribe, 200,
      scrollable: find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first);
    await tester.ensureVisible(subscribe);
    await tester.pump();
    expect(subscribe.hitTestable(), findsOneWidget);
    expect(find.text('2026-12-31'), findsOneWidget);
    expect(find.text('已花費 1h 30m · 預估 3h'), findsOneWidget);
    await tester.tap(subscribe);
    await settleNetworkWidgets(tester);
    expect(fixture.issues[1]!['subscribed'], isTrue);
    expect(fixture.unhandled, isEmpty);
  });

  group('inbox todos', () {
    late int done, reads;
    late bool failWrite;
    Json todo() => {
      'id': 101, 'action_name': 'assigned', 'target_type': 'Issue', 'state': 'pending',
      'target': {'iid': 3, 'title': 'Swipe me'}, 'project': {'id': 10, 'path_with_namespace': 'team/core'},
      'author': {'username': 'lead'}, 'updated_at': '2026-09-20T10:00:00Z',
    };
    Future<void> pumpInbox(WidgetTester tester, {ResponseBody Function(RequestOptions request)? markAll}) async {
      _phone(tester);
      done = 0;
      reads = 0;
      failWrite = false;
      final api = testApi(FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/todos') && request.method == 'GET') {
          reads++;
          return jsonResponse(done == 0 ? [todo()] : <Object>[]);
        }
        if (path.endsWith('/todos/101/mark_as_done') && request.method == 'POST') {
          if (failWrite) return jsonResponse({'message': '403 Forbidden'}, status: 403);
          done++;
          return jsonResponse({'id': 101, 'state': 'done'}, status: 201);
        }
        if (path.endsWith('/todos/mark_as_done') && request.method == 'POST' && markAll != null) return markAll(request);
        return jsonResponse(<Object>[]);
      }));
      addTearDown(api.close);
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(workspaceHost(InboxPage(account: fixture.account, api: api)));
      await settleNetworkWidgets(tester);
      expect(find.text('Swipe me'), findsOneWidget);
    }

    testWidgets('a swipe waits out the undo window, writes once and reloads the list', (tester) async {
      await pumpInbox(tester);
      await tester.drag(find.text('Swipe me'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Swipe me'), findsNothing);
      expect(find.text('已標示為完成'), findsOneWidget);
      expect(done, 0, reason: 'nothing is written while 復原 is offered');
      await tester.pump(const Duration(seconds: 5));
      await settleNetworkWidgets(tester);
      expect(done, 1);
      expect(reads, 2, reason: 'todos are offset-paged, so the list reloads after the write');
      expect(find.text('Swipe me'), findsNothing);
    });

    testWidgets('復原 restores the row and nothing is written', (tester) async {
      await pumpInbox(tester);
      await tester.drag(find.text('Swipe me'), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Swipe me'), findsNothing);
      await tester.tap(find.text('復原'));
      await tester.pumpAndSettle();
      expect(find.text('Swipe me'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await settleNetworkWidgets(tester);
      expect(done, 0);
    });

    testWidgets('a refused write brings the row back with the reason', (tester) async {
      await pumpInbox(tester);
      failWrite = true;
      await tester.drag(find.text('Swipe me'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await settleNetworkWidgets(tester);
      expect(find.text('Swipe me'), findsOneWidget);
      expect(find.textContaining(const ApiFailure(FailureKind.forbidden).title), findsOneWidget);
    });

    testWidgets('switching tabs during the undo window still writes the swipe once', (tester) async {
      await pumpInbox(tester);
      await tester.drag(find.text('Swipe me'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('待辦即將標示為完成'), findsOneWidget, reason: 'not 待辦已清空 while 復原 is still offered');
      await tester.tap(find.byKey(const ValueKey('inbox-filter-1')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await settleNetworkWidgets(tester);
      expect(done, 1);
      await tester.tap(find.byKey(const ValueKey('inbox-filter-0')));
      await settleNetworkWidgets(tester);
      expect(find.text('Swipe me'), findsNothing);
      expect(done, 1);
    });

    testWidgets('a sideways swipe never changes the inbox tab', (tester) async {
      await pumpInbox(tester);
      await tester.drag(find.textContaining('左右滑動可完成'), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Swipe me'), findsOneWidget);
      expect(done, 0);
    });

    testWidgets('全部完成 asks first and reloads even when the write is uncertain', (tester) async {
      await pumpInbox(tester, markAll: (request) => throw DioException(requestOptions: request, type: DioExceptionType.connectionError));
      await tester.tap(find.byKey(const ValueKey('todos-mark-all-done')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(reads, 1);
      await tester.tap(find.byKey(const ValueKey('todos-mark-all-done')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await settleNetworkWidgets(tester);
      expect(find.textContaining(const ApiFailure(FailureKind.writeUncertain).title), findsOneWidget);
      expect(reads, 2, reason: 'the server may have cleared the todos anyway');
    });
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
    await tester.pump(const Duration(seconds: 1));
    expect(requests, isEmpty, reason: 'typing alone does not spend the search rate limit');
    await tester.testTextInput.receiveAction(TextInputAction.search);
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
      group: const {'id': 9, 'name': 'Team', 'full_path': 'team'}, isCurrent: () => true)));
    await settleNetworkWidgets(tester);
    expect(find.text('Core app'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '子群組'));
    await settleNetworkWidgets(tester);
    expect(find.text('Platform'), findsOneWidget);
    expect(find.text('team/platform'), findsOneWidget);
  });

  testWidgets('linked issues render from the list shape and open the other issue', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(1, 'Has links');
    fixture.issues[2] = fixture.issue(2, 'Blocked follow-up');
    fixture.issueLinks[1] = [{...fixture.issue(2, 'Blocked follow-up'), 'issue_link_id': 9, 'link_type': 'blocks'}];
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project,
      resource: 'issues', iid: 1)));
    await settleNetworkWidgets(tester);
    final overview = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Blocked follow-up'), 200, scrollable: overview);
    expect(find.text('關聯議題'), findsOneWidget);
    expect(find.textContaining('#2'), findsWidgets);
    expect(find.textContaining('阻擋'), findsOneWidget);
    await tester.tap(find.text('Blocked follow-up'));
    await settleNetworkWidgets(tester);
    expect(find.byType(WorkItemPage, skipOffstage: false), findsNWidgets(2));
    expect(find.text('#2'), findsOneWidget, reason: 'the linked issue opens in its own page');
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('a failed related-items read shows the ambiguous notice instead of an empty card', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture()..failRelated = true;
    fixture.issues[1] = fixture.issue(1, 'Hidden relations');
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project,
      resource: 'issues', iid: 1)));
    await settleNetworkWidgets(tester);
    final overview = find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first;
    final target = find.text('目標：studio/mobile-workspace · #1 相關合併請求與關聯議題');
    await tester.scrollUntilVisible(target, 200, scrollable: overview);
    expect(find.text('App 帳號：@developer'), findsWidgets);
    fixture.failRelated = false;
    fixture.relatedMergeRequests[1] = [{...fixture.mergeRequest, 'title': 'Fixes the relation'}];
    final retry = find.descendant(of: find.ancestor(of: target, matching: find.byType(FailureNotice)),
      matching: find.text('重新整理'));
    await tester.ensureVisible(retry);
    await tester.pump();
    expect(retry.hitTestable(), findsOneWidget);
    await tester.tap(retry);
    await settleNetworkWidgets(tester);
    expect(target, findsNothing);
    expect(find.text('Fixes the relation'), findsOneWidget);
  });

  testWidgets('a cross-project link that cannot be resolved names the account and retries into the resource', (tester) async {
    _phone(tester);
    var hidden = true;
    final api = testApi(FakeAdapter((request) {
      final path = request.uri.path.replaceFirst('/gitlab/api/v4', '');
      if (path == '/projects/77') {
        return hidden ? jsonResponse({'message': '404 Project Not Found'}, status: 404) : jsonResponse(projectJson(77));
      }
      if (path == '/projects/77/issues/5') {
        return jsonResponse({'id': 500, 'iid': 5, 'project_id': 77, 'title': 'Found after retry', 'state': 'opened',
          'author': {'id': 7, 'username': 'developer'}, 'description': '', 'updated_at': 'r1', 'created_at': '2026-09-19T08:00:00Z'});
      }
      return jsonResponse(<Object>[]);
    }));
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(Scaffold(body: Builder(builder: (context) => Center(child: TextButton(
      onPressed: () => ResourceNavigator(fixture.account, api).workItem(context, '77', 'issues', 5),
      child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await settleNetworkWidgets(tester);
    expect(find.text('無法開啟'), findsOneWidget);
    expect(find.text('目標：專案 77'), findsOneWidget);
    expect(find.text('App 帳號：@developer'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    hidden = false;
    await tester.tap(find.text('重新整理'));
    await settleNetworkWidgets(tester);
    expect(find.text('無法開啟'), findsNothing);
    expect(find.text('Found after retry'), findsWidgets);
  });

  testWidgets('a transient failure opening a cross-project link stays a snack bar', (tester) async {
    _phone(tester);
    final api = testApi(FakeAdapter((_) => jsonResponse({'message': '503 Service Unavailable'}, status: 503)));
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(Scaffold(body: Builder(builder: (context) => Center(child: TextButton(
      onPressed: () => ResourceNavigator(fixture.account, api).workItem(context, '77', 'issues', 5),
      child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await settleNetworkWidgets(tester);
    expect(find.text('無法開啟'), findsNothing);
    expect(find.textContaining(const ApiFailure(FailureKind.server).title), findsOneWidget);
  });

  testWidgets('marking a draft ready strips its prefix, and a copy changed elsewhere is not overwritten', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    fixture.mergeFields.addAll({'title': 'Draft: Ship navigation', 'draft': true});
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project,
      resource: 'merge_requests', iid: 12)));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('標示為可審查'));
    await settleNetworkWidgets(tester);
    expect(fixture.mergeFields['title'], 'Ship navigation');
    expect(fixture.mergeFields['draft'], isFalse);
    ScaffoldMessenger.of(tester.element(find.byType(WorkItemPage))).removeCurrentSnackBar();
    fixture.mergeFields['updated_at'] = 'changed-elsewhere';
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('標示為草稿'));
    await settleNetworkWidgets(tester);
    expect(fixture.mergeFields['title'], 'Ship navigation', reason: 'a stale copy is refused before the PUT');
    expect(find.textContaining(const ApiFailure(FailureKind.conflict).title), findsOneWidget);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('a draft whose title has no removable prefix is not rewritten', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    fixture.mergeFields.addAll({'title': 'Ship navigation', 'draft': true});
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project,
      resource: 'merge_requests', iid: 12)));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('標示為可審查'));
    await settleNetworkWidgets(tester);
    expect(fixture.adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
    expect(find.textContaining('GitLab 仍將此合併請求視為草稿'), findsOneWidget);
  });

  testWidgets('fork and schedule play are confirmed before writing', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    fixture.pipelineSchedules.add({'id': 3, 'description': 'Nightly build', 'ref': 'main', 'cron': '0 2 * * *',
      'cron_timezone': 'UTC', 'active': true, 'next_run_at': '2026-10-03T02:00:00Z'});
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(Scaffold(body: ProjectMoreTab(account: fixture.account, api: fixture.api,
      project: fixture.project, onChanged: (_) {}))));
    await settleNetworkWidgets(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Fork'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(fixture.forks, 0);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Fork'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);
    expect(fixture.forks, 1);
    expect(find.textContaining('developer/mobile-workspace'), findsOneWidget);

    await tester.pumpWidget(workspaceHost(PipelineSchedulesPage(account: fixture.account, api: fixture.api,
      project: fixture.project)));
    await settleNetworkWidgets(tester);
    expect(find.text('Nightly build'), findsOneWidget);
    await tester.tap(find.byTooltip('立即執行'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(fixture.playedSchedules, isEmpty);
    await tester.tap(find.byTooltip('立即執行'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);
    expect(fixture.playedSchedules, [3]);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('the star toggle waits for a known state and accepts 304', (tester) async {
    _phone(tester);
    final fixture = _StarFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(Scaffold(body: ProjectMoreTab(account: fixture.account, api: fixture.api,
      project: fixture.project, onChanged: (_) {}))));
    await settleNetworkWidgets(tester);
    expect(find.text('重新確認星標'), findsOneWidget, reason: 'an unknown state is never shown as unstarred');
    fixture.starrersFail = false;
    await tester.tap(find.text('重新確認星標'));
    await settleNetworkWidgets(tester);
    expect(find.text('移除星標'), findsOneWidget);
    await tester.tap(find.text('移除星標'));
    await settleNetworkWidgets(tester);
    expect(find.text('加入星標'), findsOneWidget, reason: '304 means it was already unstarred elsewhere');
    expect(find.text('已移除星標'), findsOneWidget);
  });

  testWidgets('blame fits a narrow phone at double text and clips minified lines', (tester) async {
    _phone(tester, size: const Size(320, 700));
    final api = testApi(FakeAdapter((_) => jsonResponse([
      {'commit': {'id': 'a' * 40, 'author_name': 'An author whose display name is far too long for a phone',
        'authored_date': '2026-09-20T10:00:00Z', 'message': 'Refactor the session controller'},
       'lines': ['short', 'x' * 5000]},
    ])));
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(BlamePage(account: fixture.account, api: api, project: fixture.project,
      path: 'lib/main.dart', sha: 'a' * 40), scale: 2));
    await settleNetworkWidgets(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('逐行作者'), findsOneWidget);
    final clipped = tester.widget<Text>(find.byWidgetPredicate((w) => w is Text && (w.data?.startsWith('xxxx') ?? false)));
    expect(clipped.data!.length, lessThan(500));
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

class _StarFixture extends WorkspaceFixture {
  bool starrersFail = true;
  @override
  ResponseBody respond(RequestOptions request) {
    final path = request.uri.path.replaceFirst('/gitlab/api/v4/', '');
    if (path == 'projects/42/starrers') {
      return starrersFail
          ? jsonResponse({'message': '502 Bad Gateway'}, status: 502)
          : jsonResponse([{'user': {'id': 7, 'username': 'developer'}}]);
    }
    if (path == 'projects/42/unstar' && request.method == 'POST') return ResponseBody.fromString('', 304);
    return super.respond(request) as ResponseBody;
  }
}

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
