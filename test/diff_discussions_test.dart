import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

Map<String, dynamic> _textDiscussion({
  required String id,
  required String body,
  required String oldPath,
  required String newPath,
  String base = WorkspaceFixture.sha,
  String start = WorkspaceFixture.sha,
  String head = WorkspaceFixture.sha,
  int? oldLine,
  int? newLine,
}) => {
  'id': id,
  'individual_note': false,
  'notes': [
    {
      'id': id,
      'body': body,
      'author': {'id': 7, 'username': 'developer'},
      'created_at': '2026-09-19T08:00:00Z',
      'system': false,
      'resolvable': false,
      'resolved': false,
      'position': {
        'position_type': 'text',
        'base_sha': base,
        'start_sha': start,
        'head_sha': head,
        'old_path': oldPath,
        'new_path': newPath,
        'old_line': ?oldLine,
        'new_line': ?newLine,
      },
    },
  ],
};

Future<void> _pumpDiff(
  WidgetTester tester,
  WorkspaceFixture fixture, {
  DiffTarget? initialTarget,
  Size size = const Size(412, 1400),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
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
        initialTarget: initialTarget,
      ),
    ),
  );
  await settleWorkspace(tester);
}

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
      expect(find.text('另 1 則'), findsOneWidget);
      await tester.tap(find.text('顯示全部 3 則'));
      await tester.pump();
      expect(find.text('另 1 則'), findsNothing);
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

      await tester.ensureVisible(find.text('解決討論'));
      await tester.tap(find.text('解決討論'));
      await settleWorkspace(tester);
      final resolves = fixture.adapter.requests.where(
        (request) =>
            request.method == 'PUT' &&
            request.uri.path.endsWith('/merge_requests/12/discussions/anchored-1'),
      );
      expect(resolves, hasLength(1));
      final resolveBody = resolves.single.data as Map<String, dynamic>;
      expect(resolveBody['resolved'], isTrue);
      expect(find.text('重新開啟討論'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await settleWorkspace(tester);
      await openFile(tester);
      expect(find.text('重新開啟討論'), findsOneWidget);
      await tester.ensureVisible(find.text('顯示全部 4 則'));
      await tester.tap(find.text('顯示全部 4 則'));
      await tester.pump();
      expect(
        find.textContaining('請看這段差異', findRichText: true),
        findsOneWidget,
      );
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

  testWidgets(
    'sha, path and dual-coordinate mismatches stay in other-version discussions',
    (tester) async {
      const dual = '@@ -10,2 +20,2 @@\n context\n-old\n+new\n';
      final fixture = WorkspaceFixture()
        ..omitSeedDiscussions = true
        ..versionDiffs = [
          {
            'old_path': 'lib/session.dart',
            'new_path': 'lib/session.dart',
            'diff': dual,
          },
        ]
        ..extraDiscussions.addAll([
          _textDiscussion(
            id: 'dual-ok',
            body: 'DUAL-MATCH',
            oldPath: 'lib/session.dart',
            newPath: 'lib/session.dart',
            oldLine: 10,
            newLine: 20,
          ),
          _textDiscussion(
            id: 'dual-bad',
            body: 'DUAL-MISMATCH',
            oldPath: 'lib/session.dart',
            newPath: 'lib/session.dart',
            oldLine: 10,
            newLine: 21,
          ),
          _textDiscussion(
            id: 'sha-bad',
            body: 'SHA-MISMATCH',
            oldPath: 'lib/session.dart',
            newPath: 'lib/session.dart',
            oldLine: 10,
            newLine: 20,
            base: WorkspaceFixture.olderSha,
            start: WorkspaceFixture.olderSha,
            head: WorkspaceFixture.olderSha,
          ),
          _textDiscussion(
            id: 'new-path-bad',
            body: 'NEW-PATH-MISMATCH',
            oldPath: 'lib/session.dart',
            newPath: 'lib/other.dart',
            oldLine: 10,
            newLine: 20,
          ),
          _textDiscussion(
            id: 'old-path-bad',
            body: 'OLD-PATH-MISMATCH',
            oldPath: 'lib/other.dart',
            newPath: 'lib/session.dart',
            oldLine: 10,
            newLine: 20,
          ),
          _textDiscussion(
            id: 'empty-start',
            body: 'EMPTY-START',
            oldPath: 'lib/session.dart',
            newPath: 'lib/session.dart',
            oldLine: 10,
            newLine: 20,
            start: '',
          ),
        ]);
      addTearDown(fixture.api.close);
      await _pumpDiff(tester, fixture);
      expect(find.text('其他版本的討論'), findsOneWidget);
      expect(find.textContaining('NEW-PATH-MISMATCH'), findsOneWidget);
      expect(find.textContaining('OLD-PATH-MISMATCH'), findsOneWidget);
      expect(find.textContaining('DUAL-MISMATCH'), findsNothing);
      expect(find.text('目前差異未提供此行（可能已折疊或超出大小上限）'), findsWidgets);
      await tester.tap(find.widgetWithText(ListTile, 'lib/session.dart'));
      await settleWorkspace(tester);
      expect(find.byKey(const ValueKey('diff-thread-dual-ok')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-other-dual-ok')), findsNothing);
      expect(find.byKey(const ValueKey('diff-other-dual-bad')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-other-sha-bad')), findsOneWidget);
      expect(find.byKey(const ValueKey('diff-other-empty-start')), findsOneWidget);
      expect(find.text('以較舊版本為準，無法對應目前差異'), findsWidgets);
      expect(find.text('目前差異未提供此行（可能已折疊或超出大小上限）'), findsWidgets);
      final lineY = tester.getTopLeft(find.text('context')).dy;
      final threadY = tester
          .getTopLeft(find.byKey(const ValueKey('diff-thread-dual-ok')))
          .dy;
      expect(threadY, greaterThan(lineY));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('renamed-file deletion anchors on the old line', (tester) async {
    final fixture = WorkspaceFixture()
      ..omitSeedDiscussions = true
      ..versionDiffs = [
        {
          'old_path': 'lib/old_name.dart',
          'new_path': 'lib/new_name.dart',
          'renamed_file': true,
          'diff': '@@ -4 +3,0 @@\n-removed\n',
        },
      ]
      ..extraDiscussions.addAll([
        _textDiscussion(
          id: 'renamed-del',
          body: 'RENAMED-DELETION',
          oldPath: 'lib/old_name.dart',
          newPath: 'lib/new_name.dart',
          oldLine: 4,
        ),
        _textDiscussion(
          id: 'cross-path',
          body: 'CROSS-PATH',
          oldPath: 'lib/elsewhere.dart',
          newPath: 'lib/old_name.dart',
          oldLine: 4,
        ),
      ]);
    addTearDown(fixture.api.close);
    await _pumpDiff(
      tester,
      fixture,
      initialTarget: const DiffTarget(
        path: 'lib/new_name.dart',
        oldPath: 'lib/old_name.dart',
        newPath: 'lib/new_name.dart',
        oldLine: 4,
        baseSha: WorkspaceFixture.sha,
        startSha: WorkspaceFixture.sha,
        headSha: WorkspaceFixture.sha,
      ),
    );
    expect(find.text('removed'), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-thread-renamed-del')), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-other-renamed-del')), findsNothing);
    expect(find.textContaining('CROSS-PATH'), findsNothing);
    final lineY = tester.getTopLeft(find.text('removed')).dy;
    final threadY = tester
        .getTopLeft(find.byKey(const ValueKey('diff-thread-renamed-del')))
        .dy;
    expect(threadY, greaterThan(lineY));
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation reaches a line past 1000 rows and the trailing section', (
    tester,
  ) async {
    const rows = 1100;
    final diff = StringBuffer('@@ -1,$rows +1,$rows @@\n');
    for (var i = 0; i < rows; i++) {
      diff.writeln(' line$i');
    }
    final fixture = WorkspaceFixture()
      ..omitSeedDiscussions = true
      ..versionDiffs = [
        {
          'old_path': 'lib/session.dart',
          'new_path': 'lib/session.dart',
          'diff': diff.toString(),
        },
      ];
    addTearDown(fixture.api.close);
    await _pumpDiff(
      tester,
      fixture,
      size: const Size(412, 640),
      initialTarget: const DiffTarget(
        path: 'lib/session.dart',
        newLine: 1001,
        baseSha: WorkspaceFixture.sha,
        startSha: WorkspaceFixture.sha,
        headSha: WorkspaceFixture.sha,
      ),
    );
    final line = find.text('line1000');
    expect(line, findsOneWidget);
    final lineY = tester.getTopLeft(line).dy;
    expect(lineY, greaterThanOrEqualTo(0));
    expect(lineY, lessThan(640));
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation reaches the trailing other-version section', (tester) async {
    const rows = 1100;
    final diff = StringBuffer('@@ -1,$rows +1,$rows @@\n');
    for (var i = 0; i < rows; i++) {
      diff.writeln(' line$i');
    }
    final fixture = WorkspaceFixture()
      ..omitSeedDiscussions = true
      ..versionDiffs = [
        {
          'old_path': 'lib/session.dart',
          'new_path': 'lib/session.dart',
          'diff': diff.toString(),
        },
      ]
      ..extraDiscussions.add(
        _textDiscussion(
          id: 'missing-row',
          body: 'MISSING-ROW',
          oldPath: 'lib/session.dart',
          newPath: 'lib/session.dart',
          newLine: 99999,
        ),
      );
    addTearDown(fixture.api.close);
    await _pumpDiff(
      tester,
      fixture,
      size: const Size(412, 640),
      initialTarget: const DiffTarget(
        path: 'lib/session.dart',
        newLine: 99999,
        baseSha: WorkspaceFixture.sha,
        startSha: WorkspaceFixture.sha,
        headSha: WorkspaceFixture.sha,
      ),
    );
    final section = find.text('其他版本的討論');
    expect(section, findsOneWidget);
    final sectionY = tester.getTopLeft(section).dy;
    expect(sectionY, greaterThanOrEqualTo(0));
    expect(sectionY, lessThan(640));
    expect(find.text('目前差異未提供此行（可能已折疊或超出大小上限）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a discussion whose file is absent from the diff stays on the root list', (
    tester,
  ) async {
    final fixture = WorkspaceFixture()
      ..extraDiscussions.add(
        _textDiscussion(
          id: 'absent-file',
          body: 'ABSENT-FILE-THREAD',
          oldPath: 'lib/not-in-diff.dart',
          newPath: 'lib/not-in-diff.dart',
          newLine: 3,
        ),
      );
    addTearDown(fixture.api.close);
    await _pumpDiff(tester, fixture);
    expect(find.text('lib/session.dart'), findsOneWidget);
    expect(find.text('其他版本的討論'), findsOneWidget);
    expect(find.textContaining('ABSENT-FILE-THREAD'), findsOneWidget);
    expect(find.textContaining('OLDER-VERSION-THREAD'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a later discussion page failure keeps the pages already loaded', (
    tester,
  ) async {
    final fixture = WorkspaceFixture()
      ..discussionPageCount = 2
      ..failDiscussionPage = 2;
    addTearDown(fixture.api.close);
    await _pumpDiff(tester, fixture);
    await tester.tap(find.text('lib/session.dart'));
    await settleWorkspace(tester);
    expect(find.textContaining('PAGE-1-THREAD', findRichText: true), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);
    expect(find.text('GitLab 暫時無法回應'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the discussion walk stops at 20 pages and says so', (tester) async {
    final fixture = WorkspaceFixture()..discussionPageCount = 21;
    addTearDown(fixture.api.close);
    await _pumpDiff(tester, fixture);
    expect(find.text('lib/session.dart'), findsOneWidget);
    expect(find.text('討論已達 20 頁上限，後續討論未載入。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing during the discussion walk does not apply a stale page', (
    tester,
  ) async {
    final gate = Completer<ResponseBody>();
    final fixture = WorkspaceFixture()
      ..discussionPageCount = 2
      ..deferDiscussionOnPage = 2
      ..deferDiscussionPage = gate;
    addTearDown(fixture.api.close);
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete(jsonResponse([{'id': 'late', 'notes': <Object>[]}]));
      }
    });
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
    for (var i = 0; i < 30 && find.text('lib/session.dart').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('lib/session.dart'), findsOneWidget);
    expect(find.text('討論已達 20 頁上限，後續討論未載入。'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    gate.complete(jsonResponse([
      {'id': 'late', 'individual_note': true, 'notes': <Map<String, dynamic>>[]},
    ]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
