import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;

void main() {
  group('Diff Discussion Thread Navigator', () {
    late WorkspaceFixture fixture;

    setUp(() {
      fixture = WorkspaceFixture();
    });

    tearDown(() {
      fixture.api.close();
    });

    Json textDiscussion({
      required String id,
      required String filePath,
      required int newLine,
      bool resolved = false,
      String body = 'Need change here',
    }) => {
      'id': id,
      'notes': [
        {
          'id': int.tryParse(id) ?? 1001,
          'body': body,
          'resolvable': true,
          'resolved': resolved,
          'position': {
            'position_type': 'text',
            'base_sha': WorkspaceFixture.sha,
            'start_sha': WorkspaceFixture.sha,
            'head_sha': WorkspaceFixture.sha,
            'old_path': filePath,
            'new_path': filePath,
            'new_line': newLine,
          },
        },
      ],
    };

    testWidgets('navigator is hidden when there are no discussions in the file', (tester) async {
      final f = WorkspaceFixture();
      f.mrDiscussions.clear();
      addTearDown(f.api.close);

      await tester.pumpWidget(workspaceHost(
        ReviewDiffPage(
          account: f.account,
          api: f.api,
          project: f.project,
          iid: 12,
          expectedSha: WorkspaceFixture.sha,
        ),
      ));
      await settleWorkspace(tester);

      // Open the file
      await tester.tap(find.text('lib/session.dart'));
      await settleWorkspace(tester);

      // The navigator should be completely hidden
      expect(find.byKey(const ValueKey('diff-discussion-navigator')), findsNothing);
    });

    testWidgets('navigator shows greyed out with 未解決討論 0 when all discussions are resolved', (tester) async {
      final f = WorkspaceFixture();
      f.mrDiscussions.addAll([
        textDiscussion(id: 'disc-1', filePath: 'lib/session.dart', newLine: 1, resolved: true, body: 'All good!'),
      ]);
      addTearDown(f.api.close);

      await tester.pumpWidget(workspaceHost(
        ReviewDiffPage(
          account: f.account,
          api: f.api,
          project: f.project,
          iid: 12,
          expectedSha: WorkspaceFixture.sha,
        ),
      ));
      await settleWorkspace(tester);

      // Open the file
      await tester.tap(find.text('lib/session.dart'));
      await settleWorkspace(tester);

      // Navigator is visible
      expect(find.byKey(const ValueKey('diff-discussion-navigator')), findsOneWidget);
      expect(find.text('未解決討論 0'), findsOneWidget);

      // Buttons are disabled (onPressed == null)
      final prevBtn = tester.widget<IconButton>(find.byKey(const ValueKey('diff-nav-prev')));
      final nextBtn = tester.widget<IconButton>(find.byKey(const ValueKey('diff-nav-next')));
      expect(prevBtn.onPressed, isNull);
      expect(nextBtn.onPressed, isNull);
    });

    testWidgets('navigator displays unresolved count and navigates next and prev with highlight', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final f = WorkspaceFixture();
      // Configure diff with multiple lines
      f.versionDiffs = [
        {
          'old_path': 'lib/multi.dart',
          'new_path': 'lib/multi.dart',
          'diff': '@@ -1,6 +1,6 @@\n line1\n-line2\n+line2_new\n line3\n line4\n-line5\n+line5_new\n line6\n',
        },
      ];
      f.mrDiscussions.addAll([
        textDiscussion(id: 'disc-10', filePath: 'lib/multi.dart', newLine: 2, resolved: false, body: 'Review line 2'),
        textDiscussion(id: 'disc-20', filePath: 'lib/multi.dart', newLine: 5, resolved: false, body: 'Review line 5'),
        textDiscussion(id: 'disc-30', filePath: 'lib/multi.dart', newLine: 6, resolved: true, body: 'Resolved line 6'),
      ]);
      addTearDown(f.api.close);

      await tester.pumpWidget(workspaceHost(
        ReviewDiffPage(
          account: f.account,
          api: f.api,
          project: f.project,
          iid: 12,
          expectedSha: WorkspaceFixture.sha,
        ),
      ));
      await settleWorkspace(tester);

      // In ReviewDiffPage file list, badge shows 2 unresolved discussions
      expect(find.byKey(const ValueKey('file-unresolved-badge-lib/multi.dart')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      // Tap file to open _DiffFileScreen
      await tester.tap(find.text('lib/multi.dart'));
      await settleWorkspace(tester);

      // Floating navigator shows 未解決討論 2
      expect(find.byKey(const ValueKey('diff-discussion-navigator')), findsOneWidget);
      expect(find.text('未解決討論 2'), findsOneWidget);

      // Verify touch targets >= 48x48dp
      final prevRect = tester.getRect(find.byKey(const ValueKey('diff-nav-prev')));
      expect(prevRect.width, greaterThanOrEqualTo(48.0));
      expect(prevRect.height, greaterThanOrEqualTo(48.0));
      final nextRect = tester.getRect(find.byKey(const ValueKey('diff-nav-next')));
      expect(nextRect.width, greaterThanOrEqualTo(48.0));
      expect(nextRect.height, greaterThanOrEqualTo(48.0));

      // Tap Next button -> navigates to first discussion (1/2)
      await tester.tap(find.byKey(const ValueKey('diff-nav-next')));
      await settleWorkspace(tester);
      expect(find.text('未解決討論 2 (1/2)'), findsOneWidget);

      // Tap Next button -> navigates to second discussion (2/2)
      await tester.tap(find.byKey(const ValueKey('diff-nav-next')));
      await settleWorkspace(tester);
      expect(find.text('未解決討論 2 (2/2)'), findsOneWidget);

      // Tap Next button again -> wraps around to (1/2)
      await tester.tap(find.byKey(const ValueKey('diff-nav-next')));
      await settleWorkspace(tester);
      expect(find.text('未解決討論 2 (1/2)'), findsOneWidget);

      // Tap Prev button -> wraps around backward to (2/2)
      await tester.tap(find.byKey(const ValueKey('diff-nav-prev')));
      await settleWorkspace(tester);
      expect(find.text('未解決討論 2 (2/2)'), findsOneWidget);
    });

    testWidgets('adapts smoothly to dark theme', (tester) async {
      final f = WorkspaceFixture();
      f.mrDiscussions.addAll([
        textDiscussion(id: 'disc-dark', filePath: 'lib/session.dart', newLine: 1, resolved: false),
      ]);
      addTearDown(f.api.close);

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ReviewDiffPage(
            account: f.account,
            api: f.api,
            project: f.project,
            iid: 12,
            expectedSha: WorkspaceFixture.sha,
          ),
        ),
      ));
      await settleWorkspace(tester);

      await tester.tap(find.text('lib/session.dart'));
      await settleWorkspace(tester);

      expect(find.byKey(const ValueKey('diff-discussion-navigator')), findsOneWidget);
      expect(find.text('未解決討論 1'), findsOneWidget);
    });

    testWidgets('handles multiple discussions on the same line with accurate location navigation and denominator', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final f = WorkspaceFixture();
      f.versionDiffs = [
        {
          'old_path': 'lib/multi.dart',
          'new_path': 'lib/multi.dart',
          'diff': '@@ -1,6 +1,6 @@\n line1\n-line2\n+line2_new\n line3\n line4\n-line5\n+line5_new\n line6\n',
        },
      ];
      // 2 discussions on line 2, 1 on line 5
      f.mrDiscussions.addAll([
        textDiscussion(id: 'disc-2a', filePath: 'lib/multi.dart', newLine: 2, resolved: false, body: 'Note A on line 2'),
        textDiscussion(id: 'disc-2b', filePath: 'lib/multi.dart', newLine: 2, resolved: false, body: 'Note B on line 2'),
        textDiscussion(id: 'disc-5', filePath: 'lib/multi.dart', newLine: 5, resolved: false, body: 'Note on line 5'),
      ]);
      addTearDown(f.api.close);

      await tester.pumpWidget(workspaceHost(
        ReviewDiffPage(
          account: f.account,
          api: f.api,
          project: f.project,
          iid: 12,
          expectedSha: WorkspaceFixture.sha,
        ),
      ));
      await settleWorkspace(tester);

      // Badge in file list displays total unresolved count = 3
      expect(find.byKey(const ValueKey('file-unresolved-badge-lib/multi.dart')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      await tester.tap(find.text('lib/multi.dart'));
      await settleWorkspace(tester);

      // Navigator displays 未解決討論 3
      expect(find.text('未解決討論 3'), findsOneWidget);

      // Next -> 1/2 (stop 1 of 2 locations, containing both line 2 notes)
      await tester.tap(find.byKey(const ValueKey('diff-nav-next')));
      await settleWorkspace(tester);
      expect(find.text('未解決討論 3 (1/2)'), findsOneWidget);

      // Next -> 2/2 (stop 2 of 2 locations, line 5)
      await tester.tap(find.byKey(const ValueKey('diff-nav-next')));
      await settleWorkspace(tester);
      expect(find.text('未解決討論 3 (2/2)'), findsOneWidget);

      // Next -> wraps around to 1/2
      await tester.tap(find.byKey(const ValueKey('diff-nav-next')));
      await settleWorkspace(tester);
      expect(find.text('未解決討論 3 (1/2)'), findsOneWidget);
    });

    testWidgets('composes initialTarget and navigator highlight when navigating to initialTarget line', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final f = WorkspaceFixture();
      f.versionDiffs = [
        {
          'old_path': 'lib/multi.dart',
          'new_path': 'lib/multi.dart',
          'diff': '@@ -1,6 +1,6 @@\n line1\n-line2\n+line2_new\n line3\n line4\n-line5\n+line5_new\n line6\n',
        },
      ];
      f.mrDiscussions.addAll([
        textDiscussion(id: 'disc-20', filePath: 'lib/multi.dart', newLine: 2, resolved: false, body: 'Target discussion'),
      ]);
      addTearDown(f.api.close);

      final target = DiffTarget(
        path: 'lib/multi.dart',
        newPath: 'lib/multi.dart',
        newLine: 2,
        baseSha: WorkspaceFixture.sha,
        startSha: WorkspaceFixture.sha,
        headSha: WorkspaceFixture.sha,
      );

      await tester.pumpWidget(workspaceHost(
        ReviewDiffPage(
          account: f.account,
          api: f.api,
          project: f.project,
          iid: 12,
          expectedSha: WorkspaceFixture.sha,
          initialTarget: target,
        ),
      ));
      await settleWorkspace(tester);

      // Tap file to open diff
      await tester.tap(find.text('lib/multi.dart'));
      await settleWorkspace(tester);

      // Tap Next to navigate to the unresolved discussion at line 2 (which is also initialTarget)
      await tester.tap(find.byKey(const ValueKey('diff-nav-next')));
      await settleWorkspace(tester);

      expect(find.text('未解決討論 1 (1/1)'), findsOneWidget);

      // Find DecoratedBox with tertiary border
      final decoratedBoxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
      final hasTertiaryBorder = decoratedBoxes.any((box) {
        final border = (box.decoration as BoxDecoration).border;
        return border != null && border.top.width == 2.0;
      });
      expect(hasTertiaryBorder, isTrue);
    });
  });
}
