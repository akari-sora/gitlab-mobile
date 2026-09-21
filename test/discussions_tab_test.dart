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

Future<void> _openDiscussions(WidgetTester tester, WorkspaceFixture fixture) async {
  addTearDown(fixture.api.close);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(workspaceHost(WorkItemPage(
    account: fixture.account, api: fixture.api, project: fixture.project, resource: 'merge_requests', iid: 12)));
  await settleWorkspace(tester);
  await tester.tap(find.widgetWithText(Tab, '討論'));
  await settleWorkspace(tester);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('resolved discussions start collapsed, expand on tap, and hide behind the unresolved filter', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('discussion-header-resolved-thread')));
    await tester.pump();
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
}
