import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<void> openFile(WidgetTester tester) async {
    await tester.tap(find.text('lib/session.dart'));
    await settleWorkspace(tester);
  }

  testWidgets(
    'anchored thread sits under its line and other discussions stay unanchored',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        workspaceHost(
          ReviewDiffPage(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            iid: 12,
            expectedSha: WorkspaceFixture.sha,
          ),
        ),
      );
      await settleWorkspace(tester);
      await openFile(tester);

      expect(
        find.textContaining('GENERAL-NOTE-SHOULD-NOT-APPEAR', findRichText: true),
        findsNothing,
      );
      expect(find.text('其他版本的討論'), findsOneWidget);
      expect(find.text('以較舊版本為準，無法對應目前差異'), findsWidgets);
      expect(find.byKey(const ValueKey('diff-thread-anchored-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-thread-older-1')), findsNothing);
      expect(find.byKey(const ValueKey('diff-other-older-1')), findsOneWidget);

      final lineY = tester.getTopLeft(find.text('new')).dy;
      final anchoredY = tester
          .getTopLeft(
            find.textContaining('ANCHORED-THREAD-BODY', findRichText: true),
          )
          .dy;
      final sectionY = tester.getTopLeft(find.text('其他版本的討論')).dy;
      final olderY = tester.getTopLeft(find.textContaining('OLDER-VERSION-THREAD')).dy;
      expect(anchoredY, greaterThan(lineY));
      expect(anchoredY, lessThan(sectionY));
      expect(olderY, greaterThan(sectionY));

      expect(
        find.textContaining('SECOND-NOTE-VISIBLE', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('THIRD-NOTE-HIDDEN', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.text('顯示全部 3 則'));
      await tester.pump();
      expect(
        find.textContaining('THIRD-NOTE-HIDDEN', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.text('new'));
      await settleWorkspace(tester);
      expect(find.text('對這一行留言'), findsOneWidget);
      await tester.tap(find.byTooltip('保留草稿並返回'));
      await settleWorkspace(tester);
      expect(find.text('對這一行留言'), findsNothing);

      await tester.tap(find.text('回覆'));
      await settleWorkspace(tester);
      expect(find.text('回覆討論'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('editor-body')), '請看這段差異');
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleWorkspace(tester);
      final replies = fixture.adapter.requests.where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith(
              '/merge_requests/12/discussions/anchored-1/notes',
            ),
      );
      expect(replies, hasLength(1));
      final replyBody = replies.single.data as Map<String, dynamic>;
      expect(replyBody['body'], '請看這段差異');

      await tester.ensureVisible(find.text('解決'));
      await tester.tap(find.text('解決'));
      await settleWorkspace(tester);
      final resolves = fixture.adapter.requests.where(
        (request) =>
            request.method == 'PUT' &&
            request.uri.path.endsWith('/merge_requests/12/discussions/anchored-1'),
      );
      expect(resolves, hasLength(1));
      final resolveBody = resolves.single.data as Map<String, dynamic>;
      expect(resolveBody['resolved'], isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'initialTarget for an older version lands in the other-version section',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        workspaceHost(
          ReviewDiffPage(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            iid: 12,
            expectedSha: WorkspaceFixture.sha,
            initialTarget: const DiffTarget(
              path: 'lib/session.dart',
              newLine: 1,
              baseSha: WorkspaceFixture.olderSha,
              startSha: WorkspaceFixture.olderSha,
              headSha: WorkspaceFixture.olderSha,
            ),
          ),
        ),
      );
      await settleWorkspace(tester);
      expect(find.textContaining('點選程式碼行新增留言'), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-other-older-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-thread-older-1')), findsNothing);
      expect(find.text('以較舊版本為準，無法對應目前差異'), findsWidgets);
      final sectionY = tester.getTopLeft(find.text('其他版本的討論')).dy;
      final olderY = tester.getTopLeft(find.textContaining('OLDER-VERSION-THREAD')).dy;
      expect(olderY, greaterThan(sectionY));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('查看程式碼 opens the diff with the anchored line visible', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      workspaceHost(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'merge_requests',
          iid: 12,
        ),
      ),
    );
    await settleWorkspace(tester);
    await tester.tap(find.text('討論'));
    await settleWorkspace(tester);
    final codeButton = find.text('查看程式碼');
    expect(codeButton, findsNWidgets(2));
    await tester.ensureVisible(codeButton.first);
    await tester.tap(codeButton.first);
    await settleWorkspace(tester);
    expect(find.textContaining('點選程式碼行新增留言'), findsOneWidget);
    expect(find.text('new'), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-thread-anchored-1')), findsOneWidget);
    final lineY = tester.getTopLeft(find.text('new')).dy;
    final threadY = tester
        .getTopLeft(find.byKey(const ValueKey('diff-thread-anchored-1')))
        .dy;
    expect(threadY, greaterThan(lineY));
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
  });
}
