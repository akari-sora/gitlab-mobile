import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/home_page.dart';
import 'package:gitlab_mobile/features/workspace/my_work_page.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

/// The workspace fixture with an empty starred list on request.
final class _HomeFixture extends WorkspaceFixture {
  bool noStars = false;

  @override
  Future<ResponseBody> respond(RequestOptions request) async {
    final segments = request.uri.pathSegments;
    final path = segments.skip(segments.indexOf('v4') + 1).join('/');
    if (noStars && path == 'projects' && request.uri.queryParameters['starred'] == 'true') {
      return jsonResponse(<Object>[]);
    }
    return super.respond(request);
  }
}

Future<SessionController> _session(WidgetTester tester, WorkspaceFixture fixture) async {
  final session = controllerFor(MemoryAccountStore(), fixture.adapter);
  addTearDown(session.dispose);
  await tester.runAsync(() async {
    await session.initialize();
    await session.connect('https://example.com/gitlab', 'synthetic-test-token');
  });
  return session;
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Iterable<Map<String, String>> _queries(WorkspaceFixture fixture, String last) => fixture.adapter.requests
    .where((request) => request.method == 'GET' && request.uri.pathSegments.last == last)
    .map((request) => request.uri.queryParameters);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('Home lists My Work, the account starred projects and shortcuts', (tester) async {
    _phone(tester);
    final fixture = _HomeFixture();
    addTearDown(fixture.api.close);
    final session = await _session(tester, fixture);
    await tester.pumpWidget(workspaceHost(HomePage(session: session, recentStore: MemoryRecentProjectStore())));
    await settleNetworkWidgets(tester);

    expect(find.text('首頁'), findsOneWidget);
    expect(find.text('我的工作'), findsOneWidget);
    for (final row in ['議題', '合併請求', 'CI/CD', '專案', '群組', '動態', '星標']) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    expect(find.text('星標專案'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-starred-42')), findsOneWidget);
    expect(find.text('最近開啟'), findsNothing, reason: 'no recent project on this device yet');
    final starredQuery = _queries(fixture, 'projects').single;
    expect(starredQuery['starred'], 'true');
    expect(starredQuery['per_page'], '5');
    await tester.scrollUntilVisible(find.text('捷徑'), 200);
    expect(find.text('全域搜尋'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('My Work issues filter by scope and state across projects', (tester) async {
    _phone(tester);
    final fixture = _HomeFixture();
    addTearDown(fixture.api.close);
    final session = await _session(tester, fixture);
    await tester.pumpWidget(workspaceHost(HomePage(session: session, recentStore: MemoryRecentProjectStore())));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('議題'));
    await settleNetworkWidgets(tester);
    expect(find.byType(MyWorkPage), findsOneWidget);
    expect(_queries(fixture, 'issues').last, containsPair('scope', 'assigned_to_me'));
    expect(_queries(fixture, 'issues').last, containsPair('state', 'opened'));
    expect(find.text('沒有指派給你的開啟中議題'), findsOneWidget);

    await tester.tap(find.text('我建立的'));
    await settleNetworkWidgets(tester);
    expect(_queries(fixture, 'issues').last, containsPair('scope', 'created_by_me'));

    await tester.tap(find.byKey(const ValueKey('my-work-state')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部').last);
    await settleNetworkWidgets(tester);
    expect(_queries(fixture, 'issues').last.containsKey('state'), isFalse);
    expect(find.text('你還沒有建立議題'), findsOneWidget);
    expect(find.text('待我審查'), findsNothing, reason: 'review requests are merge requests only');
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('My Work merge requests include review requests for the signed-in user', (tester) async {
    _phone(tester);
    final fixture = _HomeFixture();
    addTearDown(fixture.api.close);
    final session = await _session(tester, fixture);
    await tester.pumpWidget(workspaceHost(HomePage(session: session, recentStore: MemoryRecentProjectStore())));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('合併請求'));
    await settleNetworkWidgets(tester);
    expect(find.text('Improve private-project navigation'), findsOneWidget);
    await tester.tap(find.text('待我審查'));
    await settleNetworkWidgets(tester);
    final query = _queries(fixture, 'merge_requests').last;
    expect(query, containsPair('reviewer_id', '7'));
    expect(query, containsPair('scope', 'all'));
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('an empty starred list offers 瀏覽專案 and Home actions hand over', (tester) async {
    _phone(tester);
    final fixture = _HomeFixture()..noStars = true;
    addTearDown(fixture.api.close);
    final session = await _session(tester, fixture);
    final calls = <String>[];
    await tester.pumpWidget(workspaceHost(HomePage(
      session: session,
      recentStore: MemoryRecentProjectStore(),
      onExplore: () => calls.add('explore'),
      onCreate: () => calls.add('create'),
      onLocate: () => calls.add('locate'),
      onOpenInbox: () => calls.add('inbox'),
    )));
    await settleNetworkWidgets(tester);

    expect(find.text('為常用的專案加上星標，隨時一鍵開啟，不必再搜尋。'), findsOneWidget);
    await tester.tap(find.text('瀏覽專案'));
    await tester.pump();
    await tester.tap(find.byTooltip('新增'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('以連結或路徑開啟'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('新增專案'), 200);
    await tester.tap(find.text('新增專案'));
    await tester.tap(find.text('待辦'));
    await tester.pump();
    expect(calls, ['explore', 'locate', 'create', 'inbox']);
  });

  testWidgets('a recent project opens its overview and a starred one becomes recent', (tester) async {
    _phone(tester);
    final fixture = _HomeFixture();
    addTearDown(fixture.api.close);
    final session = await _session(tester, fixture);
    final store = MemoryRecentProjectStore();
    final key = session.active!.key;
    await store.touch(key, const RecentProject(id: 42, name: 'Mobile Workspace', path: 'studio/mobile-workspace'));
    await tester.pumpWidget(workspaceHost(HomePage(session: session, recentStore: store)));
    await settleNetworkWidgets(tester);

    expect(find.text('最近開啟'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-recent-42')));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsOneWidget);
    expect(find.byType(ProjectOverview), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await settleNetworkWidgets(tester);

    store.values[key] = [];
    await tester.tap(find.byKey(const ValueKey('home-starred-42')));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectOverview), findsOneWidget);
    expect((await store.readList(key)).map((project) => project.id), [42]);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('Home fits a 320 dp phone at double text size', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final fixture = _HomeFixture();
    addTearDown(fixture.api.close);
    final session = await _session(tester, fixture);
    await tester.pumpWidget(workspaceHost(HomePage(session: session, recentStore: MemoryRecentProjectStore())));
    await settleNetworkWidgets(tester);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('捷徑'), 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
