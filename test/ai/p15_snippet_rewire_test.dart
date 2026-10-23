import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/snippets_page.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';

import '../snippet_multifile_page_test.dart' as multi;
import '../snippets_page_test.dart' as single;
import '../workspace_widget_test.dart' show workspaceHost;

class _MetadataFixture extends multi.MultiSnippetFixture {
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.method == 'PUT') {
      description = (request.data as Map)['description'] as String;
    }
    return super.respond(request);
  }
}

void _expectWire(
  RequestOptions request,
  String method,
  String path,
  String? body,
) {
  expect(request.method, method);
  expect(request.uri.toString(), 'https://example.com/gitlab/api/v4/$path');
  expect(request.followRedirects, isFalse);
  expect(
    request.data == null ? null : utf8.encode(jsonEncode(request.data)),
    body == null ? null : utf8.encode(body),
  );
}

Future<void> _settle(WidgetTester tester) async {
  final deadline = Stopwatch()..start();
  do {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    final loading = find.byWidgetPredicate((widget) {
      return widget is RowsSkeleton ||
          (widget is CircularProgressIndicator && widget.value == null) ||
          (widget is LinearProgressIndicator && widget.value == null);
    });
    if (loading.evaluate().isEmpty && !tester.binding.hasScheduledFrame) return;
  } while (deadline.elapsed < const Duration(seconds: 20));
  fail('Snippet UI did not settle within 20 seconds');
}

Future<void> _host(WidgetTester tester, SnippetsPage page) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(page.api.close);
  await tester.pumpWidget(workspaceHost(page));
  await _settle(tester);
}

Future<void> _openMulti(
  WidgetTester tester,
  multi.MultiSnippetFixture fixture,
) async {
  await _host(
    tester,
    SnippetsPage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
    ),
  );
  await tester.tap(find.text('Multi example'));
  await _settle(tester);
}

Future<void> _saveEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('editorSave')));
  await _settle(tester);
}

Future<void> _tapFileAction(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key)).last;
  await tester.scrollUntilVisible(
    control,
    250,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.ensureVisible(control);
  await tester.tap(control);
  await _settle(tester);
}

Future<void> _confirm(WidgetTester tester, String requiredText) async {
  final confirm = find.widgetWithText(FilledButton, '確認');
  expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    requiredText,
  );
  await tester.pump();
  await tester.tap(confirm);
  await _settle(tester);
  // confirmAction defers controller disposal until its route has exited.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final method in [
    'createSnippet',
    'updateSnippet',
    'updateSnippetMetadata',
    'updateSnippetFiles',
    'deleteSnippetFile',
    'deleteSnippet',
  ]) {
    test('P15 snippet wiring uses $method', () {
      final source = File(
        'lib/features/workspace/snippets_page.dart',
      ).readAsStringSync();
      expect(RegExp('\\bapi\\.$method\\(').allMatches(source), hasLength(1));
    });
  }

  test('P15 snippet wiring has no generic write calls', () {
    final source = File(
      'lib/features/workspace/snippets_page.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('.writeRecord(')));
    expect(source, isNot(contains('.removeRecord(')));
  });

  testWidgets('P15 snippet wire create legacy update and typed delete', (
    tester,
  ) async {
    final fixture = single.SnippetFixture();
    await _host(
      tester,
      SnippetsPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('create-snippet')));
    await _settle(tester);
    const description = '  **details**\n@reader\n';
    const content = '  /literal\n"quoted" λ\n';
    await tester.enterText(
      find.byKey(const ValueKey('editor-title')),
      '  Created λ  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-description')),
      description,
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-file_name')),
      '  notes/example.txt  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      content,
    );
    await _saveEditor(tester);
    expect(fixture.writes, hasLength(1));
    _expectWire(
      fixture.writes.single,
      'POST',
      'projects/42/snippets',
      '{"title":"Created λ","description":"  **details**\\n@reader\\n",'
          '"visibility":"private","files":[{"file_path":"notes/example.txt",'
          '"content":"  /literal\\n\\"quoted\\" λ\\n"}]}',
    );
    expect(fixture.content[1], content);

    await tester.tap(find.byTooltip('編輯 Snippet'));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      '  /updated\nλ "next"\n',
    );
    await _saveEditor(tester);
    expect(fixture.writes, hasLength(2));
    _expectWire(
      fixture.writes.last,
      'PUT',
      'projects/42/snippets/1',
      '{"title":"Created λ","description":"  **details**\\n@reader\\n",'
          '"visibility":"private","files":[{"action":"update",'
          '"file_path":"notes/example.txt","content":"  /updated\\nλ \\"next\\"\\n"}]}',
    );

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刪除'));
    await tester.pumpAndSettle();
    await _confirm(tester, '#1');
    expect(fixture.writes, hasLength(3));
    _expectWire(fixture.writes.last, 'DELETE', 'projects/42/snippets/1', null);
    expect(fixture.snippets, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('P15 snippet wire metadata and file create omit extra fields', (
    tester,
  ) async {
    final fixture = _MetadataFixture();
    await _openMulti(tester, fixture);
    await tester.tap(find.byTooltip('編輯 Snippet'));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-description')),
      '  **new**\n/literal λ\n',
    );
    await _saveEditor(tester);
    expect(fixture.writes, hasLength(1));
    _expectWire(
      fixture.writes.single,
      'PUT',
      'projects/42/snippets/6030720',
      '{"title":"Multi example","description":"  **new**\\n/literal λ\\n",'
          '"visibility":"private"}',
    );
    await tester.tap(find.byKey(const ValueKey('snippet-add-file')));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-file_path')),
      '  notes/new.txt  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      ' /new λ\n',
    );
    await _saveEditor(tester);
    expect(fixture.writes, hasLength(2));
    _expectWire(
      fixture.writes.last,
      'PUT',
      'projects/42/snippets/6030720',
      '{"title":"Multi example","description":"  **new**\\n/literal λ\\n",'
          '"visibility":"private","files":[{"action":"create",'
          '"file_path":"notes/new.txt","content":" /new λ\\n"}]}',
    );
    expect(fixture.files['notes/new.txt'], ' /new λ\n');
    expect(tester.takeException(), isNull);
  });

  testWidgets('P15 snippet wire file update move and typed deletion', (
    tester,
  ) async {
    final fixture = multi.MultiSnippetFixture();
    await _openMulti(tester, fixture);
    await _tapFileAction(tester, 'snippet-edit-file');
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      '  # Updated λ\n/literal\n',
    );
    await _saveEditor(tester);
    expect(fixture.writes, hasLength(1));
    _expectWire(
      fixture.writes.last,
      'PUT',
      'projects/42/snippets/6030720',
      '{"title":"Multi example","description":"**Markdown** notes",'
          '"visibility":"private","files":[{"action":"update",'
          '"file_path":"README.md","content":"  # Updated λ\\n/literal\\n"}]}',
    );
    await _tapFileAction(tester, 'snippet-rename-file');
    await tester.enterText(
      find.byKey(const ValueKey('editor-file_path')),
      '  docs/readme.txt  ',
    );
    await _saveEditor(tester);
    expect(fixture.writes, hasLength(2));
    _expectWire(
      fixture.writes.last,
      'PUT',
      'projects/42/snippets/6030720',
      '{"title":"Multi example","description":"**Markdown** notes",'
          '"visibility":"private","files":[{"action":"move",'
          '"previous_path":"README.md","file_path":"docs/readme.txt"}]}',
    );
    await _tapFileAction(tester, 'snippet-delete-file');
    await _confirm(tester, 'docs/readme.txt');
    expect(fixture.writes, hasLength(3));
    _expectWire(
      fixture.writes.last,
      'PUT',
      'projects/42/snippets/6030720',
      '{"title":"Multi example","description":"**Markdown** notes",'
          '"visibility":"private","files":[{"action":"delete",'
          '"file_path":"docs/readme.txt"}]}',
    );
    expect(fixture.files.keys, ['lib/main.dart']);
    expect(tester.takeException(), isNull);
  });
}
