import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

/// Layouts that choose between a row and a column by measuring their
/// labels: long translations must neither overflow nor break inside a word.
void main() {
  void phone(WidgetTester tester, double width) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget host(String tag, Widget child, {double scale = 1}) {
    useLanguage(languageForTag(tag)!);
    return MaterialApp(
      theme: appTheme(Brightness.light),
      locale: Locale(tag),
      supportedLocales: [Locale(tag)],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    );
  }

  /// Every word of [button]'s label fits the width its text was laid out
  /// in, so a wrap can only happen between words.
  void expectNoWordBreak(WidgetTester tester, Finder button) {
    // The label's own paragraph (an icon is a RichText too).
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.descendant(of: button, matching: find.byType(Text)),
        matching: find.byType(RichText),
      ),
    );
    final span = paragraph.text as TextSpan;
    final label = span.toPlainText();
    for (final word in label.split(RegExp(r'\s+')).where((word) => word.isNotEmpty)) {
      final painter = TextPainter(
        text: TextSpan(text: word, style: span.style),
        textDirection: TextDirection.ltr,
        textScaler: paragraph.textScaler,
      )..layout();
      expect(
        painter.width,
        lessThanOrEqualTo(paragraph.constraints.maxWidth + 0.5),
        reason: '"$word" in "$label" must not break inside the word',
      );
      painter.dispose();
    }
  }

  testWidgets('review progress action does not overflow in Turkish at 393 dp and 1.3x text', (tester) async {
    phone(tester, 393);
    const head = '3333333333333333333333333333333333333333';
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/versions')) {
        return jsonResponse([
          {'id': 1, 'head_commit_sha': head},
        ]);
      }
      if (path.endsWith('/versions/1')) {
        return jsonResponse({
          'id': 1,
          'head_commit_sha': head,
          'base_commit_sha': '1111111111111111111111111111111111111111',
          'start_commit_sha': '2222222222222222222222222222222222222222',
          'diffs': [
            for (final name in ['a', 'b'])
              {
                'old_path': 'lib/$name.dart',
                'new_path': 'lib/$name.dart',
                'new_file': false,
                'renamed_file': false,
                'deleted_file': false,
                'diff': '@@ -1,1 +1,1 @@\n-old\n+new',
              },
          ],
        });
      }
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 7, username: 'reviewer', name: 'Reviewer'),
      token: 'synthetic-token',
    );
    final project = Project.fromJson({
      'id': 42,
      'name': 'Project',
      'path': 'project',
      'path_with_namespace': 'group/project',
      'description': '',
      'visibility': 'private',
      'default_branch': 'main',
      'archived': false,
      'last_activity_at': '2026-09-20T10:00:00Z',
    });

    await tester.pumpWidget(host(
      'tr',
      Scaffold(
        body: ReviewDiffPage(account: account, api: api, project: project, iid: 10, expectedSha: head),
      ),
      scale: 1.3,
    ));
    await settleNetworkWidgets(tester);

    expect(tester.takeException(), isNull);
    final action = find.byKey(const ValueKey('toggle-all-viewed'));
    expect(find.descendant(of: action, matching: find.text(l10n.markAllAsViewed)), findsOneWidget);
    expect(tester.getRect(action).right, lessThanOrEqualTo(393));
    expectNoWordBreak(tester, action);
  });

  testWidgets('three review actions in German keep whole words and do not overflow', (tester) async {
    phone(tester, 393);
    final fixture = WorkspaceFixture()..mergeFields.addAll({'diverged_commits_count': 2});
    addTearDown(fixture.api.close);

    await tester.pumpWidget(host(
      'de',
      WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
      ),
    ));
    await settleNetworkWidgets(tester);

    expect(tester.takeException(), isNull);
    for (final key in ['mr-draft-review-btn', 'mr-approve-btn', 'mr-rebase-btn']) {
      final button = find.byKey(ValueKey(key));
      expect(button, findsOneWidget, reason: key);
      expect(tester.getRect(button).right, lessThanOrEqualTo(393), reason: key);
      expectNoWordBreak(tester, button);
    }
  });

  testWidgets('German tab bars scroll at 360 dp instead of cutting labels', (tester) async {
    phone(tester, 360);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    await tester.pumpWidget(host(
      'de',
      WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
      ),
    ));
    await settleNetworkWidgets(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isTrue);

    await tester.pumpWidget(host(
      'de',
      ProjectPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        initialTab: 0,
      ),
    ));
    await settleNetworkWidgets(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isTrue);
    expect(tester.takeException(), isNull);
  });
}
