import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/features/workspace/picker_sheet.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'support/fake_adapter.dart';
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

class _PendingAttachments implements AttachmentPicker {
  _PendingAttachments(this.onFirstFile);
  final void Function()? onFirstFile;
  final Completer<PickedAttachment?> gate = Completer<PickedAttachment?>();
  int images = 0, files = 0;
  @override
  Future<PickedAttachment?> pickImage() async {
    images++;
    return gate.future;
  }
  @override
  Future<PickedAttachment?> pickFile() {
    files++;
    if (files == 1) onFirstFile?.call();
    return gate.future;
  }
}

class _HeldUploads extends WorkspaceFixture {
  final Completer<void> uploadHold = Completer<void>();
  @override
  Future<ResponseBody> respond(RequestOptions request) async {
    if (request.method == 'POST' && request.uri.path.endsWith('/uploads')) {
      await uploadHold.future;
    }
    return Future<ResponseBody>.value(super.respond(request));
  }
}

const _shotSecret = '0123456789abcdef0123456789abcdef';
final _shotPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _ShotUploads extends WorkspaceFixture {
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = request.uri.path;
    if (request.method == 'POST' && path.endsWith('/uploads')) {
      return jsonResponse({
        'markdown': '![shot](/uploads/$_shotSecret/shot.png)',
        'url': '/uploads/$_shotSecret/shot.png',
        'full_path': '/-/project/42/uploads/$_shotSecret/shot.png',
      }, status: 201);
    }
    if (request.method == 'GET' && path.endsWith('/uploads/$_shotSecret/shot.png')) {
      return ResponseBody.fromBytes(_shotPng, 200, headers: {'content-type': ['image/png']});
    }
    return super.respond(request);
  }
}

class _OverLimit implements AttachmentPicker {
  int opened = 0;
  @override
  Future<PickedAttachment?> pickImage() => pickFile();
  @override
  Future<PickedAttachment?> pickFile() => readLimitedAttachment(
    filename: 'big.bin',
    length: GitLabApi.maxUploadBytes + 1,
    open: () {
      opened++;
      return const Stream<List<int>>.empty();
    },
  );
}

String _draftKey(String accountKey, String resource) =>
    'draft.v2.${base64Url.encode(utf8.encode(accountKey))}.${base64Url.encode(utf8.encode(resource))}';

Checkbox _createBox(WidgetTester tester) => tester.widget<Checkbox>(find.descendant(
  of: find.byKey(const ValueKey('picker-create-label')),
  matching: find.byType(Checkbox),
));

Finder _iconButton(String tooltip) => find.ancestor(
  of: find.byTooltip(tooltip),
  matching: find.byType(IconButton),
);

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
    await tester.ensureVisible(find.byKey(const ValueKey('editor-labels')));
    await tester.tap(find.byKey(const ValueKey('editor-labels')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('picker-row-a')));
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
    expect(body['labels'], 'a');
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

  testWidgets('preview renders an uploaded project image', (tester) async {
    final fixture = _ShotUploads();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      projectPath: fixture.project.path,
      title: 'Markdown',
      resource: 'markdown-image-preview',
      persistent: false,
      attachments: _FakeAttachments(PickedAttachment(filename: 'shot.png', bytes: _shotPng)),
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await _tapTooltip(tester, '附加圖片');
    await settleNetworkWidgets(tester);
    final controller = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!;
    expect(controller.text, '![shot](/uploads/$_shotSecret/shot.png)');
    await tester.tap(find.text('預覽'));
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNothing);
    expect(find.textContaining('無法載入附件'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('unknown label stays visible and can be removed after reopen', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(Scaffold(body: WorkItemsTab(
      account: fixture.account, api: fixture.api, project: fixture.project, resource: 'issues'))));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增議題'));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Drop spike');
    await tester.ensureVisible(find.byKey(const ValueKey('editor-labels')));
    await tester.tap(find.byKey(const ValueKey('editor-labels')));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('picker-search')), 'spike');
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('picker-create-label')));
    await tester.pump();
    expect(find.text('建立標籤「spike」'), findsOneWidget);
    expect(_createBox(tester).value, isTrue);
    await tester.tap(find.byKey(const ValueKey('picker-create-label')));
    await tester.pump();
    expect(find.text('建立標籤「spike」'), findsOneWidget);
    expect(_createBox(tester).value, isFalse);
    await tester.tap(find.byKey(const ValueKey('picker-create-label')));
    await tester.pump();
    expect(_createBox(tester).value, isTrue);
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('editor-labels')));
    await tester.tap(find.byKey(const ValueKey('editor-labels')));
    await settleNetworkWidgets(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('picker-search'))).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('picker-create-label')), findsNothing);
    expect(find.text('已選擇'), findsOneWidget);
    final pinned = find.byKey(const ValueKey('picker-row-spike'));
    expect(pinned, findsOneWidget);
    expect(tester.getTopLeft(pinned).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('picker-row-a'))).dy));
    expect(tester.widget<Checkbox>(find.descendant(of: pinned, matching: find.byType(Checkbox))).value, isTrue);
    await tester.tap(pinned);
    await tester.pump();
    expect(find.byKey(const ValueKey('picker-row-spike')), findsNothing);
    expect(find.text('已選擇'), findsNothing);
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    final post = fixture.adapter.requests.lastWhere(
      (request) => request.method == 'POST' && request.uri.path.endsWith('/issues'));
    expect((post.data as Map<String, dynamic>)['labels'], '');
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  for (final raw in ['1', '123', 'true', 'null']) {
    testWidgets('legacy label draft $raw restores and submits unchanged', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      _surface(tester);
      const resource = '42/issues/new';
      FlutterSecureStorage.setMockInitialValues({
        _draftKey(fixture.account.key, resource): jsonEncode({'title': 'Kept', 'labels': raw}),
      });
      await tester.pumpWidget(_host(Scaffold(body: WorkItemsTab(
        account: fixture.account, api: fixture.api, project: fixture.project, resource: 'issues'))));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('新增議題'));
      await settleNetworkWidgets(tester);
      expect(find.text(raw), findsWidgets);
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleNetworkWidgets(tester);
      final post = fixture.adapter.requests.lastWhere(
        (request) => request.method == 'POST' && request.uri.path.endsWith('/issues'));
      final body = post.data as Map<String, dynamic>;
      expect(body['labels'], raw);
      expect(body['labels'], isA<String>());
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  }

  testWidgets('legacy branch draft keeps a comma through restore and submit', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    const resource = '42/merge_requests/new';
    FlutterSecureStorage.setMockInitialValues({
      _draftKey(fixture.account.key, resource): jsonEncode({'title': 'Kept', 'source_branch': 'release,a'}),
    });
    await tester.pumpWidget(_host(Scaffold(body: WorkItemsTab(
      account: fixture.account, api: fixture.api, project: fixture.project, resource: 'merge_requests'))));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增合併請求'));
    await settleNetworkWidgets(tester);
    expect(find.text('release,a'), findsWidgets);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    final post = fixture.adapter.requests.lastWhere(
      (request) => request.method == 'POST' && request.uri.path.endsWith('/merge_requests'));
    final body = post.data as Map<String, dynamic>;
    expect(body['source_branch'], 'release,a');
    expect(body['target_branch'], 'main');
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('bare choice list draft restores chips and submits every field type', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    const resource = '42/merge_requests/new';
    FlutterSecureStorage.setMockInitialValues({
      _draftKey(fixture.account.key, resource): jsonEncode({
        'title': 'Kept',
        'source_branch': '[{"id":"feature/navigation","name":"feature/navigation"}]',
        'labels': '[{"id":"a","name":"a","color":"#d9534f"}]',
        'reviewer_ids': '[{"id":"8","name":"Reviewer","username":"reviewer"}]',
      }),
    });
    await tester.pumpWidget(_host(Scaffold(body: WorkItemsTab(
      account: fixture.account, api: fixture.api, project: fixture.project, resource: 'merge_requests'))));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增合併請求'));
    await settleNetworkWidgets(tester);
    expect(find.text('feature/navigation'), findsWidgets);
    expect(find.text('a'), findsWidgets);
    expect(find.byKey(const ValueKey('label-dot-a')), findsOneWidget);
    expect(find.text('@reviewer'), findsWidgets);
    expect(find.textContaining('[{"id"'), findsNothing);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    final post = fixture.adapter.requests.lastWhere(
      (request) => request.method == 'POST' && request.uri.path.endsWith('/merge_requests'));
    final body = post.data as Map<String, dynamic>;
    expect(body['source_branch'], 'feature/navigation');
    expect(body['target_branch'], 'main');
    expect(body['labels'], 'a');
    expect(body['reviewer_ids'], [8]);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('branch rows expose checked semantics at 48 dp', (tester) async {
    final handle = tester.ensureSemantics();
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: '分支',
      resource: 'branch-semantics',
      persistent: false,
      fields: const [EditField.picker('source_branch', '來源分支', source: PickerSource.branches)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('editor-source_branch')));
    await settleNetworkWidgets(tester);
    final row = find.byKey(const ValueKey('picker-row-feature/navigation'));
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    await tester.tap(row);
    await tester.pump();
    expect(tester.getSemantics(row), matchesSemantics(
      isButton: true,
      isFocusable: true,
      hasFocusAction: true,
      hasTapAction: true,
      hasCheckedState: true,
      isChecked: true,
      isInMutuallyExclusiveGroup: true,
      label: 'feature/navigation',
    ));
    expect(tester.getSemantics(find.byKey(const ValueKey('picker-row-main'))), matchesSemantics(
      isButton: true,
      isFocusable: true,
      hasFocusAction: true,
      hasTapAction: true,
      hasCheckedState: true,
      isChecked: false,
      isInMutuallyExclusiveGroup: true,
    ));
    expect(tester.takeException(), isNull);
    handle.dispose();
    await _finish(tester);
  });

  testWidgets('label rows expose selected state without a separate checkbox', (tester) async {
    final handle = tester.ensureSemantics();
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: '標籤',
      resource: 'label-semantics',
      persistent: false,
      fields: const [EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('editor-labels')));
    await settleNetworkWidgets(tester);
    final row = find.byKey(const ValueKey('picker-row-a'));
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    await tester.tap(row);
    await tester.pump();
    expect(tester.getSemantics(row), matchesSemantics(
      isButton: true,
      isFocusable: true,
      hasFocusAction: true,
      hasTapAction: true,
      hasSelectedState: true,
      isSelected: true,
      hasCheckedState: false,
      label: 'a',
    ));
    final box = find.descendant(of: row, matching: find.byType(Checkbox));
    expect(box, findsOneWidget);
    expect(tester.getSemantics(box), tester.getSemantics(row));
    expect(tester.takeException(), isNull);
    handle.dispose();
    await _finish(tester);
  });

  testWidgets('picker sheet stays below the status bar and above the keyboard', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: '標籤',
      resource: 'picker-safe',
      persistent: false,
      fields: const [EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('editor-labels')));
    await settleNetworkWidgets(tester);
    final sheet = find.byType(ChoicePickerSheet);
    final title = find.descendant(of: sheet, matching: find.text('標籤'));
    expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(47));
    expect(tester.getRect(sheet).top, greaterThanOrEqualTo(47));
    expect(tester.getRect(sheet).bottom, lessThanOrEqualTo(900 - 280 + 1));
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump();
    final done = find.byKey(const Key('picker-done'));
    expect(tester.getRect(done).bottom, lessThanOrEqualTo(900 - 34));
    expect(tester.getRect(sheet).bottom, lessThanOrEqualTo(900 - 34));
    tester.view.viewInsets = const FakeViewPadding(bottom: 5000);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(sheet).height, greaterThanOrEqualTo(0));
    await _finish(tester);
  });

  testWidgets('attachment picker locks save and leave before the file returns', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    var saved = false;
    late final _PendingAttachments pending;
    pending = _PendingAttachments(() {
      final image = tester.widget<IconButton>(_iconButton('附加圖片'));
      expect(image.onPressed, isNotNull);
      image.onPressed!.call();
    });
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: '附件',
      resource: 'attach-pending',
      persistent: false,
      attachments: pending,
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async { saved = true; },
    )));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'hello');
    await _tapTooltip(tester, '附加檔案');
    await tester.pump();
    expect(pending.files, 1);
    expect(pending.images, 0);
    expect(tester.widget<FilledButton>(find.byKey(const Key('editorSave'))).onPressed, isNull);
    expect(tester.widget<IconButton>(_iconButton('保留草稿並返回')).onPressed, isNull);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!.text, 'hello');
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('附件'), findsOneWidget);
    expect(saved, isFalse);
    pending.gate.complete(null);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('editorSave'))).onPressed, isNotNull);
    expect(fixture.adapter.requests.where((request) => request.uri.path.endsWith('/uploads')), isEmpty);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('late picker result after dispose does not upload', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    final pending = _PendingAttachments(null);
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: '附件',
      resource: 'attach-late',
      persistent: false,
      attachments: pending,
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'hello');
    await _tapTooltip(tester, '附加檔案');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    pending.gate.complete(const PickedAttachment(filename: 'note.txt', bytes: [1]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(fixture.adapter.requests.where((request) => request.uri.path.endsWith('/uploads')), isEmpty);
  });

  testWidgets('upload blocks leave until the markdown is inserted', (tester) async {
    final fixture = _HeldUploads();
    addTearDown(() { if (!fixture.uploadHold.isCompleted) fixture.uploadHold.complete(); });
    addTearDown(fixture.api.close);
    _surface(tester);
    const markdown = '![note.txt](/uploads/test/note.txt)';
    Widget host() => _host(Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => openEditor(
        context,
        account: fixture.account,
        api: fixture.api,
        projectId: fixture.project.id,
        title: '附件',
        resource: 'attach-hold',
        attachments: _FakeAttachments(const PickedAttachment(filename: 'note.txt', bytes: [1, 2, 3])),
        fields: const [EditField('description', '說明', lines: 6, markdown: true)],
        save: (_) async {},
      ),
      child: const Text('開啟編輯器'),
    ))));
    await tester.pumpWidget(host());
    await tester.tap(find.text('開啟編輯器'));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'hello');
    await _tapTooltip(tester, '附加檔案');
    await tester.pump();
    await tester.pump();
    final controller = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!;
    expect(controller.text, 'hello');
    expect(find.textContaining('上傳中'), findsOneWidget);
    expect(tester.widget<IconButton>(_iconButton('保留草稿並返回')).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('附件'), findsOneWidget);
    expect(controller.text, 'hello');
    fixture.uploadHold.complete();
    await tester.pump();
    await settleNetworkWidgets(tester);
    expect(controller.text, 'hello\n$markdown');
    await tester.tap(find.byTooltip('保留草稿並返回'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('開啟編輯器'));
    await settleNetworkWidgets(tester);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!.text, contains(markdown));
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('late upload after dispose does not rewrite the draft', (tester) async {
    final fixture = _HeldUploads();
    addTearDown(() { if (!fixture.uploadHold.isCompleted) fixture.uploadHold.complete(); });
    addTearDown(fixture.api.close);
    _surface(tester);
    Widget host() => _host(Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => openEditor(
        context,
        account: fixture.account,
        api: fixture.api,
        projectId: fixture.project.id,
        title: '附件',
        resource: 'attach-late-upload',
        attachments: _FakeAttachments(const PickedAttachment(filename: 'note.txt', bytes: [4])),
        fields: const [EditField('description', '說明', lines: 6, markdown: true)],
        save: (_) async {},
      ),
      child: const Text('開啟編輯器'),
    ))));
    await tester.pumpWidget(host());
    await tester.tap(find.text('開啟編輯器'));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'hello');
    await _tapTooltip(tester, '附加檔案');
    await tester.pump();
    await tester.pump();
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!.text, 'hello');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    fixture.uploadHold.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(host());
    await tester.tap(find.text('開啟編輯器'));
    await settleNetworkWidgets(tester);
    final text = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!.text;
    expect(text, 'hello');
    expect(text, isNot(contains('/uploads/')));
    await _finish(tester);
  });

  testWidgets('oversized attachment shows the 25 MiB limit', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    final picker = _OverLimit();
    await tester.pumpWidget(_host(ResourceEditor(
      account: fixture.account,
      api: fixture.api,
      projectId: fixture.project.id,
      title: '附件',
      resource: 'attach-big',
      persistent: false,
      attachments: picker,
      fields: const [EditField('description', '說明', lines: 6, markdown: true)],
      save: (_) async {},
    )));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'hello');
    await _tapTooltip(tester, '附加檔案');
    await settleNetworkWidgets(tester);
    expect(picker.opened, 0);
    expect(find.textContaining('附件超過 25 MiB 上限'), findsOneWidget);
    expect(find.textContaining('25 MiB'), findsWidgets);
    expect(find.textContaining('文字預覽上限'), findsNothing);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-description'))).controller!.text, 'hello');
    expect(tester.widget<FilledButton>(find.byKey(const Key('editorSave'))).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('a draft from an older revision stays unapplied and is not dirty', (tester) async {
    const resource = '42/issues/7/edit';
    final fixture = await _pumpRevisionEditor(
      tester,
      resource: resource,
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
      baseRevision: 'new',
    );
    expect(_editorTitle(tester), 'server title');
    expect(find.text(_staleNotice), findsOneWidget);
    expect(find.text('套用草稿'), findsOneWidget);
    expect(find.text('捨棄草稿'), findsOneWidget);
    await tester.tap(find.byTooltip('保留草稿並返回'));
    await settleNetworkWidgets(tester);
    expect(await _readDraft(fixture.account.key, resource), {'title': 'draft title', '__base': 'old'});
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('applying a stale draft fills the fields and drops the notice', (tester) async {
    const resource = '42/issues/7/edit';
    final fixture = await _pumpRevisionEditor(
      tester,
      resource: resource,
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
      baseRevision: 'new',
    );
    await tester.tap(find.text('套用草稿'));
    await settleNetworkWidgets(tester);
    expect(_editorTitle(tester), 'draft title');
    expect(find.text(_staleNotice), findsNothing);
    expect(await _readDraft(fixture.account.key, resource), {'title': 'draft title', '__base': 'new'});
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('discarding a stale draft deletes it and drops the notice', (tester) async {
    const resource = '42/issues/7/edit';
    final fixture = await _pumpRevisionEditor(
      tester,
      resource: resource,
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
      baseRevision: 'new',
    );
    await tester.tap(find.text('捨棄草稿'));
    await settleNetworkWidgets(tester);
    expect(_editorTitle(tester), 'server title');
    expect(find.text(_staleNotice), findsNothing);
    expect(await _readDraft(fixture.account.key, resource), isNull);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('a draft whose base revision matches is restored', (tester) async {
    await _pumpRevisionEditor(
      tester,
      resource: '42/issues/8/edit',
      draft: {'title': 'draft title', '__base': 'rev'},
      serverTitle: 'server title',
      baseRevision: 'rev',
    );
    expect(_editorTitle(tester), 'draft title');
    expect(find.text(_staleNotice), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('a legacy draft without a base revision is held back when editing an existing resource', (tester) async {
    // A v0.2 draft: same storage key, no `__base`. The server may have moved
    // since it was written, so it must not be applied over the loaded values.
    await _pumpRevisionEditor(
      tester,
      resource: '42/issues/9/edit',
      draft: {'title': 'draft title'},
      serverTitle: 'server title',
      baseRevision: 'new',
    );
    expect(_editorTitle(tester), 'server title');
    expect(find.text(_legacyNotice), findsOneWidget);
    expect(find.text('套用草稿'), findsOneWidget);
    expect(find.text('捨棄草稿'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '儲存')).onPressed, isNull);
    await tester.tap(find.text('套用草稿'));
    await tester.pump();
    expect(_editorTitle(tester), 'draft title');
    expect(find.text(_legacyNotice), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('a creation editor restores a legacy draft that has no base revision', (tester) async {
    // No `baseRevision` and no `__base`: nothing to compare, so the draft is
    // applied. Guards against holding every base-less draft, creates included.
    await _pumpRevisionEditor(
      tester,
      resource: '42/issues/new',
      draft: {'title': 'draft title'},
      serverTitle: 'server title',
    );
    expect(_editorTitle(tester), 'draft title');
    expect(find.text(_staleNotice), findsNothing);
    expect(find.text(_legacyNotice), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('a creation editor restores a draft when no base revision is set', (tester) async {
    await _pumpRevisionEditor(
      tester,
      resource: '42/issues/new',
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
    );
    expect(_editorTitle(tester), 'draft title');
    expect(find.text(_staleNotice), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('typing while a stale draft is held leaves the stored draft unchanged', (tester) async {
    const resource = '42/issues/7/edit';
    final fixture = await _pumpRevisionEditor(
      tester,
      resource: resource,
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
      baseRevision: 'new',
    );
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'typed title');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_editorTitle(tester), 'typed title');
    expect(await _readDraft(fixture.account.key, resource), {'title': 'draft title', '__base': 'old'});
    expect(tester.takeException(), isNull);
    await _finish(tester);
    expect(await _readDraft(fixture.account.key, resource), {'title': 'draft title', '__base': 'old'});
  });

  testWidgets('save is disabled while a stale draft is held', (tester) async {
    const resource = '42/issues/7/edit';
    var saved = 0;
    final fixture = await _pumpRevisionEditor(
      tester,
      resource: resource,
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
      baseRevision: 'new',
      onSave: (_) async { saved += 1; },
    );
    expect(tester.widget<FilledButton>(find.byKey(const Key('editorSave'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('editorSave')), warnIfMissed: false);
    await settleNetworkWidgets(tester);
    expect(saved, 0);
    expect(find.text(_staleNotice), findsOneWidget);
    expect(await _readDraft(fixture.account.key, resource), {'title': 'draft title', '__base': 'old'});
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('discarding a stale draft after typing leaves storage empty on return', (tester) async {
    const resource = '42/issues/7/edit';
    final fixture = await _pumpRevisionEditor(
      tester,
      resource: resource,
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
      baseRevision: 'new',
    );
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'typed title');
    await tester.tap(find.text('捨棄草稿'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('保留草稿並返回'));
    await settleNetworkWidgets(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(await _readDraft(fixture.account.key, resource), isNull);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('a failed stale-draft delete keeps the notice until retry succeeds', (tester) async {
    const resource = '42/issues/7/edit';
    final fixture = await _pumpRevisionEditor(
      tester,
      resource: resource,
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
      baseRevision: 'new',
    );
    final current = FlutterSecureStoragePlatform.instance as TestFlutterSecureStoragePlatform;
    final failing = _DeleteFailingStorage(current.data);
    FlutterSecureStoragePlatform.instance = failing;
    await tester.tap(find.text('捨棄草稿'));
    await settleNetworkWidgets(tester);
    expect(find.text(_staleNotice), findsOneWidget);
    expect(find.text('安全草稿儲存不可用。送出失敗時內容仍會保留在此畫面。'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '捨棄草稿')).onPressed, isNotNull);
    expect(await _readDraft(fixture.account.key, resource), {'title': 'draft title', '__base': 'old'});
    failing.fail = false;
    await tester.tap(find.text('捨棄草稿'));
    await settleNetworkWidgets(tester);
    expect(find.text(_staleNotice), findsNothing);
    expect(await _readDraft(fixture.account.key, resource), isNull);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('applying a stale draft stores the current base revision', (tester) async {
    const resource = '42/issues/7/edit';
    final fixture = await _pumpRevisionEditor(
      tester,
      resource: resource,
      draft: {'title': 'draft title', '__base': 'old'},
      serverTitle: 'server title',
      baseRevision: 'new',
    );
    await tester.tap(find.text('套用草稿'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(_staleNotice), findsNothing);
    expect(await _readDraft(fixture.account.key, resource), {'title': 'draft title', '__base': 'new'});
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });
}

const _staleNotice = '草稿來自較舊的版本，伺服器內容已在之後變更。';
const _legacyNotice = '草稿沒有版本資訊（來自舊版 App），無法確認是否比伺服器內容新。';

String _editorTitle(WidgetTester tester) =>
    tester.widget<TextFormField>(find.byKey(const ValueKey('editor-title'))).controller!.text;

Future<Object?> _readDraft(String accountKey, String resource) async {
  final raw = await const FlutterSecureStorage().read(key: _draftKey(accountKey, resource));
  if (raw == null) return null;
  return jsonDecode(raw) as Object;
}

Future<WorkspaceFixture> _pumpRevisionEditor(
  WidgetTester tester, {
  required String resource,
  required Map<String, Object?> draft,
  required String serverTitle,
  String? baseRevision,
  Future<void> Function(Map<String, String> values)? onSave,
}) async {
  final fixture = WorkspaceFixture();
  addTearDown(fixture.api.close);
  _surface(tester);
  FlutterSecureStorage.setMockInitialValues({
    _draftKey(fixture.account.key, resource): jsonEncode(draft),
  });
  await tester.pumpWidget(_host(Builder(builder: (context) => Scaffold(body: TextButton(
    onPressed: () => openEditor(
      context,
      account: fixture.account,
      title: '編輯',
      resource: resource,
      baseRevision: baseRevision,
      fields: [EditField('title', '標題', value: serverTitle)],
      save: (values) async {
        final save = onSave;
        if (save != null) await save(values);
      },
    ),
    child: const Text('開啟編輯器'),
  )))));
  await tester.tap(find.text('開啟編輯器'));
  await settleNetworkWidgets(tester);
  return fixture;
}

class _DeleteFailingStorage extends TestFlutterSecureStoragePlatform {
  _DeleteFailingStorage(super.data);
  var fail = true;

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {
    if (fail) throw StateError('draft delete failed');
    await super.delete(key: key, options: options);
  }
}
