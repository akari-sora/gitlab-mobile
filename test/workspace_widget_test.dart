import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'support/workspace_fixture.dart';
import 'support/widget_settle.dart';

Future<void> settleWorkspace(WidgetTester tester) => settleNetworkWidgets(tester);
Widget workspaceHost(Widget child, {Brightness brightness = Brightness.light, double scale = 1}) => MaterialApp(
  theme: appTheme(brightness), locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
  home: child,
);

void main() {
  test('merge switches default from squash and either source-branch flag', () {
    expect(mergeSquashDefault({}), isFalse);
    expect(mergeSquashDefault({'squash': false}), isFalse);
    expect(mergeSquashDefault({'squash': true}), isTrue);
    expect(mergeRemoveSourceBranchDefault({}), isFalse);
    expect(mergeRemoveSourceBranchDefault({'force_remove_source_branch': false, 'should_remove_source_branch': false}), isFalse);
    expect(mergeRemoveSourceBranchDefault({'force_remove_source_branch': true}), isTrue);
    expect(mergeRemoveSourceBranchDefault({'should_remove_source_branch': true}), isTrue);
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final width in [320.0, 412.0, 840.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in Brightness.values) {
        for (final screen in ['project', 'review', 'pipeline', 'editor']) {
          testWidgets('mobile $screen width=$width scale=$scale ${brightness.name}', (tester) async {
            final fixture = WorkspaceFixture(); addTearDown(fixture.api.close);
            tester.view.devicePixelRatio = 1; tester.view.physicalSize = Size(width, 900);
            addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
            final Widget page = switch (screen) {
              'project' => ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project),
              'review' => WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project, resource: 'merge_requests', iid: 12),
              'pipeline' => PipelinePage(account: fixture.account, api: fixture.api, project: fixture.project, id: 99),
              _ => ResourceEditor(account: fixture.account, title: '新增議題', resource: 'synthetic/editor', persistent: false,
                fields: const [EditField('title', '標題', required: true), EditField('description', '說明', lines: 8)], save: (_) async {}),
            };
            await tester.pumpWidget(workspaceHost(page, brightness: brightness, scale: scale));
            await settleWorkspace(tester);
            expect(tester.takeException(), isNull); expect(fixture.unhandled, isEmpty);
            await tester.pumpWidget(const SizedBox()); await tester.pump();
          });
        }
      }
    }
  }
  testWidgets('issue and comment CRUD from visible controls, including failed-write draft recovery', (tester) async {
    final fixture = WorkspaceFixture(); addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(Scaffold(appBar: AppBar(title: const Text('議題列表')),
      body: WorkItemsTab(account: fixture.account, api: fixture.api, project: fixture.project, resource: 'issues'))));
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('新增議題')); await settleWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Created from UI');
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'Synthetic content');
    fixture.failWrites = true;
    await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
    expect(fixture.issues, isEmpty, reason: 'Rejected POST must not create a fixture');
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-title'))).controller!.text, 'Created from UI');
    expect(find.text('請檢查輸入內容'), findsOneWidget, reason: '422 must display a useful form error. Visible text: ${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | ')}');
    fixture.failWrites = false;
    await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
    expect(fixture.issues, hasLength(1), reason: 'Successful editor save must send the issue POST');
    final iid = fixture.issues.keys.single;
    expect(find.text('Created from UI'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作')); await tester.pumpAndSettle();
    await tester.tap(find.text('編輯')); await settleWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Edited from UI');
    await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
    expect(fixture.issues[iid]!['title'], 'Edited from UI');
    await tester.tap(find.byTooltip('更多操作')); await tester.pumpAndSettle();
    await tester.tap(find.text('關閉')); await settleWorkspace(tester);
    expect(fixture.issues[iid]!['state'], 'closed');
    await tester.tap(find.byTooltip('更多操作')); await tester.pumpAndSettle();
    await tester.tap(find.text('重新開啟')); await settleWorkspace(tester);
    expect(fixture.issues[iid]!['state'], 'opened');
    await tester.tap(find.text('討論')); await settleWorkspace(tester);
    await tester.tap(find.text('留言')); await settleWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-body')), 'A real widget-posted note');
    await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
    expect(fixture.notes, hasLength(1));
    await tester.tap(find.byTooltip('留言操作')); await tester.pumpAndSettle();
    await tester.tap(find.text('編輯留言')); await settleWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-body')), 'Changed note');
    await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
    expect(fixture.notes.values.single['body'], 'Changed note');
    await tester.tap(find.byTooltip('留言操作')); await tester.pumpAndSettle();
    await tester.tap(find.text('刪除留言')); await tester.pumpAndSettle();
    await tester.tap(find.text('確認')); await settleWorkspace(tester);
    expect(fixture.notes, isEmpty);
    await tester.tap(find.byTooltip('更多操作')); await tester.pumpAndSettle();
    await tester.tap(find.text('刪除')); await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '#$iid');
    await tester.pump(); await tester.tap(find.text('確認')); await settleWorkspace(tester);
    expect(fixture.issues, isEmpty); expect(find.text('議題列表'), findsOneWidget);
    expect(tester.takeException(), isNull); expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox()); await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('returning to a secure composer restores its unsent draft', (tester) async {
    final fixture = WorkspaceFixture(); addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => openEditor(context, account: fixture.account, title: '草稿', resource: 'draft-test',
        fields: const [EditField('body', '內容', lines: 4)], save: (_) async {}), child: const Text('開啟編輯器'))))));
    await tester.tap(find.text('開啟編輯器')); await settleWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-body')), 'Keep this draft');
    await tester.tap(find.byTooltip('保留草稿並返回')); await settleWorkspace(tester);
    await tester.tap(find.text('開啟編輯器')); await settleWorkspace(tester);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-body'))).controller!.text, 'Keep this draft');
    await tester.pumpWidget(const SizedBox()); await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('merge confirmation sends the chosen squash and source-branch options with the reviewed SHA', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    fixture.mergeFields['force_remove_source_branch'] = true;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(WorkItemPage(
      account: fixture.account, api: fixture.api, project: fixture.project, resource: 'merge_requests', iid: 12)));
    await settleWorkspace(tester);
    expect(find.text('可以合併'), findsOneWidget);
    expect(tester.getSize(find.widgetWithText(OutlinedButton, '批准')).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(find.widgetWithText(FilledButton, '合併')).height, greaterThanOrEqualTo(48));
    await tester.tap(find.widgetWithText(FilledButton, '合併'));
    await settleWorkspace(tester);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('merge-squash'))).value, isFalse);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('merge-remove-branch'))).value, isTrue);
    await tester.tap(find.byKey(const ValueKey('merge-squash')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('merge-remove-branch')));
    await tester.pump();
    expect(tester.widget<Switch>(find.byKey(const ValueKey('merge-squash'))).value, isTrue);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('merge-remove-branch'))).value, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleWorkspace(tester);
    final merge = fixture.adapter.requests.lastWhere((request) => request.method == 'PUT' && request.uri.path.endsWith('/merge'));
    final body = merge.data as Map<String, dynamic>;
    expect(body['sha'], WorkspaceFixture.sha);
    expect(body['squash'], isTrue);
    expect(body['should_remove_source_branch'], isFalse);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
