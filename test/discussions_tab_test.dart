import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

Json _note(int id, String username, String body, {required bool resolvable, bool resolved = false}) => {
  'id': id, 'body': body, 'system': false, 'resolvable': resolvable, 'resolved': resolved,
  'author': {'id': id + 20, 'username': username}, 'created_at': '2026-09-01T00:00:00Z',
};

Future<void> _openDiscussions(WidgetTester tester, WorkspaceFixture fixture, {
  Size size = const Size(412, 900), double scale = 1,
}) async {
  addTearDown(fixture.api.close);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(workspaceHost(WorkItemPage(
    account: fixture.account, api: fixture.api, project: fixture.project, resource: 'merge_requests', iid: 12), scale: scale));
  await settleWorkspace(tester);
  await tester.tap(find.widgetWithText(Tab, '討論'));
  await settleWorkspace(tester);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('resolved discussions start collapsed, expand on tap, and hide behind the unresolved filter', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
    final fixture = WorkspaceFixture()..mrDiscussions.addAll([
      {'id': 'resolved-thread', 'individual_note': false, 'notes': [
        _note(2, 'alice', '已解決討論的內文', resolvable: true, resolved: true),
      ]},
      {'id': 'open-thread', 'individual_note': false, 'notes': [
        _note(3, 'bob', '尚未解決的內文', resolvable: true),
      ]},
    ]);
    await _openDiscussions(tester, fixture);
    expect(find.text('2 則討論 · 1 已解決'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('已解決'), findsOneWidget);
    expect(find.textContaining('已解決討論的內文', findRichText: true), findsNothing);
    expect(find.textContaining('尚未解決的內文', findRichText: true), findsOneWidget);
    expect(tester.getSemantics(find.byKey(const ValueKey('discussion-header-resolved-thread'))),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: false, hint: '展開討論'));
    await tester.tap(find.byKey(const ValueKey('discussion-header-resolved-thread')));
    await tester.pump();
    expect(tester.getSemantics(find.byKey(const ValueKey('discussion-header-resolved-thread'))),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: true, hint: '收合討論'));
    expect(find.textContaining('已解決討論的內文', findRichText: true), findsOneWidget);
    expect(find.text('重新開啟討論'), findsOneWidget);
    expect(find.text('回覆'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('discussion-header-resolved-thread')));
    await tester.pump();
    expect(find.textContaining('已解決討論的內文', findRichText: true), findsNothing);
    await tester.tap(find.byKey(const ValueKey('discussion-header-resolved-thread')));
    await tester.pump();
    expect(find.textContaining('已解決討論的內文', findRichText: true), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, '只看未解決'));
    await tester.pump();
    expect(find.textContaining('已解決討論的內文', findRichText: true), findsNothing);
    expect(find.text('@alice'), findsNothing);
    expect(find.textContaining('尚未解決的內文', findRichText: true), findsOneWidget);
    expect(find.text('2 則討論 · 1 已解決'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('discussions with nothing resolvable omit the resolved count and stay expanded', (tester) async {
    final fixture = WorkspaceFixture()..mrDiscussions.add({
      'id': 'plain-note', 'individual_note': true, 'notes': [
        _note(4, 'developer', '一般留言內文', resolvable: false),
      ],
    });
    await _openDiscussions(tester, fixture);
    expect(find.text('1 則討論'), findsOneWidget);
    expect(find.textContaining('已解決'), findsNothing);
    expect(find.textContaining('一般留言內文', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('collapsed header fits 320px at double text scale', (tester) async {
    final fixture = WorkspaceFixture()..mrDiscussions.add({
      'id': 'resolved-thread', 'individual_note': false, 'notes': [
        _note(2, 'alice-with-a-very-long-display-name', '已解決討論的內文', resolvable: true, resolved: true),
      ],
    });
    await _openDiscussions(tester, fixture, size: const Size(320, 900), scale: 2);
    expect(find.textContaining(RegExp(r'\d{4}/\d{2}/\d{2}')), findsWidgets);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  Json resolvedThread(String id, String username) => {
    'id': id, 'individual_note': false, 'notes': [
      _note(id.hashCode.abs() % 1000 + 2, username, '討論 $id', resolvable: true, resolved: true),
    ],
  };

  testWidgets('partial discussion pages qualify the count and withhold the empty filter state', (tester) async {
    final fixture = WorkspaceFixture()
      ..discussionPages = [[resolvedThread('page-1', 'alice')], [resolvedThread('page-2', 'carol')]];
    await _openDiscussions(tester, fixture);
    expect(find.text('已載入 1 則討論 · 1 已解決'), findsOneWidget);
    expect(find.text('沒有未解決的討論'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, '只看未解決'));
    await tester.pump();
    expect(find.text('沒有未解決的討論'), findsNothing);
    expect(find.text('載入更多'), findsOneWidget);
    await tester.tap(find.text('載入更多'));
    await settleWorkspace(tester);
    expect(find.text('沒有未解決的討論'), findsOneWidget);
    expect(find.text('載入更多'), findsNothing);
    expect(find.text('2 則討論 · 2 已解決'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a failed discussion load shows no counts', (tester) async {
    final fixture = WorkspaceFixture()..failDiscussions = true;
    await _openDiscussions(tester, fixture);
    expect(find.textContaining('則討論'), findsNothing);
    expect(find.text('GitLab 暫時無法回應'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('filter modes separate user comments from system notes and update empty states dynamically', (tester) async {
    final fixture = WorkspaceFixture()..mrDiscussions.addAll([
      {
        'id': 'user-comment-1',
        'individual_note': false,
        'notes': [
          _note(101, 'dev_user', '這是一般開發者評論', resolvable: false),
        ],
      },
      {
        'id': 'system-note-1',
        'individual_note': true,
        'notes': [
          {
            'id': 102,
            'body': 'added label ~backend',
            'system': true,
            'resolvable': false,
            'resolved': false,
            'author': {'id': 99, 'username': 'gitlab-bot'},
            'created_at': '2026-09-01T00:00:00Z',
          },
        ],
      },
      {
        'id': 'resolved-comment-1',
        'individual_note': false,
        'notes': [
          _note(103, 'reviewer', '已解決的程式碼審查意見', resolvable: true, resolved: true),
        ],
      },
    ]);

    await _openDiscussions(tester, fixture);
    // 預設為全部活動 (all)：3 則全部顯示
    expect(find.text('3 則討論 · 1 已解決'), findsOneWidget);
    expect(find.textContaining('這是一般開發者評論', findRichText: true), findsOneWidget);
    expect(find.textContaining('added label ~backend', findRichText: true), findsOneWidget);
    expect(find.text('@reviewer'), findsOneWidget);

    // 切換為「僅評論」 (comments)：系統 note 隱藏
    await tester.tap(find.byKey(const ValueKey('filter-chip-comments')));
    await tester.pump();
    expect(find.textContaining('這是一般開發者評論', findRichText: true), findsOneWidget);
    expect(find.textContaining('added label ~backend', findRichText: true), findsNothing);
    expect(find.text('@reviewer'), findsOneWidget);

    // 疊加「只看未解決」：已解決的 reviewer 評論隱藏
    await tester.tap(find.byKey(const ValueKey('filter-chip-unresolved')));
    await tester.pump();
    expect(find.textContaining('這是一般開發者評論', findRichText: true), findsOneWidget);
    expect(find.text('@reviewer'), findsNothing);

    // 切換為「僅動態」 (system)：只有系統 note，但因為疊加了「只看未解決」（系統 note 不是 resolvable，_discussionResolved 為 false），所以系統 note 會顯示
    await tester.tap(find.byKey(const ValueKey('filter-chip-system')));
    await tester.pump();
    expect(find.textContaining('這是一般開發者評論', findRichText: true), findsNothing);
    expect(find.textContaining('added label ~backend', findRichText: true), findsOneWidget);

    // 取消「只看未解決」，依然在「僅動態」
    await tester.tap(find.byKey(const ValueKey('filter-chip-unresolved')));
    await tester.pump();
    expect(find.textContaining('added label ~backend', findRichText: true), findsOneWidget);

    // 回到「全部活動」
    await tester.tap(find.byKey(const ValueKey('filter-chip-all')));
    await tester.pump();
    expect(find.textContaining('這是一般開發者評論', findRichText: true), findsOneWidget);
    expect(find.textContaining('added label ~backend', findRichText: true), findsOneWidget);

    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('batch expand and collapse resolved discussions toggles all resolved threads', (tester) async {
    final fixture = WorkspaceFixture()..mrDiscussions.addAll([
      {
        'id': 'resolved-1',
        'individual_note': false,
        'notes': [
          _note(201, 'alice', '已解決主題 1', resolvable: true, resolved: true),
        ],
      },
      {
        'id': 'resolved-2',
        'individual_note': false,
        'notes': [
          _note(202, 'bob', '已解決主題 2', resolvable: true, resolved: true),
        ],
      },
    ]);

    await _openDiscussions(tester, fixture);
    // 初始狀態下已解決主題均收合
    expect(find.textContaining('已解決主題 1', findRichText: true), findsNothing);
    expect(find.textContaining('已解決主題 2', findRichText: true), findsNothing);
    expect(find.byKey(const ValueKey('toggle-all-resolved-btn')), findsOneWidget);
    expect(find.text('展開已解決'), findsOneWidget);

    // 點擊「展開已解決」：所有已解決主題全部展開
    await tester.tap(find.byKey(const ValueKey('toggle-all-resolved-btn')));
    await tester.pump();
    expect(find.textContaining('已解決主題 1', findRichText: true), findsOneWidget);
    expect(find.textContaining('已解決主題 2', findRichText: true), findsOneWidget);
    expect(find.text('收合已解決'), findsOneWidget);

    // 再次點擊「收合已解決」：所有已解決主題全部收合
    await tester.tap(find.byKey(const ValueKey('toggle-all-resolved-btn')));
    await tester.pump();
    expect(find.textContaining('已解決主題 1', findRichText: true), findsNothing);
    expect(find.textContaining('已解決主題 2', findRichText: true), findsNothing);
    expect(find.text('展開已解決'), findsOneWidget);

    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
