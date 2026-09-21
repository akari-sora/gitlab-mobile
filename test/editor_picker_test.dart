import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/features/workspace/picker_sheet.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

void _surface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _tapTooltip(WidgetTester tester, String tooltip) async {
  final finder = find.byTooltip(tooltip);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

int _gets(WorkspaceFixture fixture, String suffix) => fixture.adapter.requests
    .where((request) => request.method == 'GET' && request.uri.path.endsWith(suffix))
    .length;

class _FakeAttachments implements AttachmentPicker {
  _FakeAttachments(this.file);
  final PickedAttachment? file;
  @override
  Future<PickedAttachment?> pickImage() async => file;
  @override
  Future<PickedAttachment?> pickFile() async => file;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('label picker lists fixture labels and posts the two selected names', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(Scaffold(body: WorkItemsTab(
      account: fixture.account, api: fixture.api, project: fixture.project, resource: 'issues'))));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增議題'));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Labeled');
    await tester.ensureVisible(find.byKey(const ValueKey('editor-labels')));
    await tester.tap(find.byKey(const ValueKey('editor-labels')));
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('picker-row-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('picker-row-b')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('picker-row-a'))).height, greaterThanOrEqualTo(48));
    final dot = tester.widget<Container>(find.byKey(const ValueKey('label-dot-a')));
    expect((dot.decoration as BoxDecoration).color, const Color.fromARGB(255, 0xD9, 0x53, 0x4F));
    await tester.enterText(find.byKey(const ValueKey('picker-search')), 'a');
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('picker-row-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('picker-row-b')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('picker-row-a')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('picker-search')), '');
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('picker-row-b')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('editor-assignee_ids')));
    await tester.tap(find.byKey(const ValueKey('editor-assignee_ids')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('picker-row-7')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    final post = fixture.adapter.requests.lastWhere(
      (request) => request.method == 'POST' && request.uri.path.endsWith('/issues'));
    final body = post.data as Map<String, dynamic>;
    expect(body['labels'], 'a, b');
    expect(body['assignee_ids'], [7]);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await _finish(tester);
  });

  testWidgets('unknown label search offers to create it', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(Scaffold(body: WorkItemsTab(
      account: fixture.account, api: fixture.api, project: fixture.project, resource: 'issues'))));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增議題'));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'New label');
    await tester.ensureVisible(find.byKey(const ValueKey('editor-labels')));
    await tester.tap(find.byKey(const ValueKey('editor-labels')));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('picker-search')), 'spike');
    await settleNetworkWidgets(tester);
    expect(find.text('建立標籤「spike」'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('picker-create-label')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    expect(find.text('spike'), findsWidgets);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    final post = fixture.adapter.requests.lastWhere(
      (request) => request.method == 'POST' && request.uri.path.endsWith('/issues'));
    expect((post.data as Map<String, dynamic>)['labels'], 'spike');
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('merge request create posts branches and reviewer ids', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(Scaffold(body: WorkItemsTab(
      account: fixture.account, api: fixture.api, project: fixture.project, resource: 'merge_requests'))));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增合併請求'));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Review it');
    expect(find.text('main'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('editor-source_branch')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('picker-row-feature/navigation')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('editor-reviewer_ids')));
    await tester.tap(find.byKey(const ValueKey('editor-reviewer_ids')));
    await settleNetworkWidgets(tester);
    expect(find.text('@reviewer'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('picker-row-8')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    final post = fixture.adapter.requests.lastWhere(
      (request) => request.method == 'POST' && request.uri.path.endsWith('/merge_requests'));
    final body = post.data as Map<String, dynamic>;
    expect(body['source_branch'], 'feature/navigation');
    expect(body['target_branch'], 'main');
    expect(body['reviewer_ids'], [8]);
    expect(tester.takeException(), isNull);
    expect(fixture.unhandled, isEmpty);
    await _finish(tester);
  });

  testWidgets('picker draft restores chips without another labels request', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => openEditor(
        context,
        account: fixture.account,
        api: fixture.api,
        projectId: fixture.project.id,
        title: '草稿',
        resource: 'picker-draft',
        fields: const [EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true)],
        save: (_) async {},
      ),
      child: const Text('開啟編輯器'),
    )))));
    await tester.tap(find.text('開啟編輯器'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('editor-labels')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('picker-row-a')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('保留草稿並返回'));
    await settleNetworkWidgets(tester);
    final reads = _gets(fixture, '/labels');
    expect(reads, 1);
    await tester.tap(find.text('開啟編輯器'));
    await settleNetworkWidgets(tester);
    expect(find.text('a'), findsOneWidget);
    expect(find.byKey(const ValueKey('label-dot-a')), findsOneWidget);
    expect(_gets(fixture, '/labels'), reads);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('attachment upload inserts markdown at the cursor', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    const markdown = '![note.txt](/uploads/test/note.txt)';
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: '附件',
      resource: 'attach',
      persistent: false,
      attachments: _FakeAttachments(const PickedAttachment(filename: 'note.txt', bytes: [1, 2, 3])),
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'hello');
    final controller = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!;
    controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();
    await _tapTooltip(tester, '附加檔案');
    await settleNetworkWidgets(tester);
    expect(controller.text, 'hello\n$markdown');
    controller.value = const TextEditingValue(text: 'hello', selection: TextSelection.collapsed(offset: 0));
    await tester.pump();
    await _tapTooltip(tester, '附加檔案');
    await settleNetworkWidgets(tester);
    expect(controller.text, '${markdown}hello');
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('failed attachment upload keeps the editor text', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    fixture.failWrites = true;
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: '附件',
      resource: 'attach-fail',
      persistent: false,
      attachments: _FakeAttachments(const PickedAttachment(filename: 'note.txt', bytes: [9])),
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'hello');
    await _tapTooltip(tester, '附加檔案');
    await settleNetworkWidgets(tester);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!.text, 'hello');
    expect(find.textContaining('請檢查輸入內容'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('bold wraps the selection', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: 'Markdown',
      resource: 'markdown-bold',
      persistent: false,
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'text');
    final controller = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();
    await _tapTooltip(tester, '粗體');
    await tester.pump();
    expect(controller.text, '**text**');
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('list button on an empty line inserts a bullet', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: 'Markdown',
      resource: 'markdown-list',
      persistent: false,
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), '');
    await _tapTooltip(tester, '項目符號清單');
    await tester.pump();
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!.text, '- ');
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('preview renders markdown and restores the same input', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: 'Markdown',
      resource: 'markdown-preview',
      persistent: false,
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), '**hello**');
    final controller = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!;
    final cursor = controller.selection;
    await tester.tap(find.text('預覽'));
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('**hello**'), findsNothing);
    await tester.tap(find.text('編輯'));
    await tester.pumpAndSettle();
    expect(controller.text, '**hello**');
    expect(controller.selection, cursor);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });
}
