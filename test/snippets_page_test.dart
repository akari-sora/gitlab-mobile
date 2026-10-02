import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/snippets_page.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

class SnippetFixture {
  SnippetFixture({this.explicitFiles, this.omitFiles = false});

  final List<Map<String, dynamic>>? explicitFiles;
  final bool omitFiles;
  late final adapter = FakeAdapter(respond);
  late final api = testApi(adapter);
  late final account = Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
    token: 'synthetic-test-token',
  );
  final project = const Project(id: 42, name: 'Example', path: 'team/example');
  final snippets = <int, Map<String, dynamic>>{};
  final content = <int, String>{};
  final writes = <RequestOptions>[];
  int revision = 1;

  Map<String, dynamic> snippet(
    int id, {
    String title = 'Useful example',
    String description = '**Markdown** notes',
    String visibility = 'private',
    String fileName = 'main.dart',
  }) => {
    'id': id,
    'project_id': 42,
    'title': title,
    'description': description,
    'visibility': visibility,
    'file_name': fileName,
    'updated_at': 'revision-$revision',
    'author': {'username': 'developer'},
    if (!omitFiles)
      'files':
          explicitFiles ??
          [
            {'path': fileName},
          ],
    'raw_url': 'https://attacker.invalid/leak',
  };

  List<String> pathOf(RequestOptions request) {
    final path = request.uri.pathSegments;
    return path.skip(path.indexOf('v4') + 1).toList();
  }

  ResponseBody missing() =>
      jsonResponse({'message': '404 Not Found'}, status: 404);

  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = pathOf(request);
    final method = request.method;
    if (path.length < 3 ||
        path[0] != 'projects' ||
        path[1] != '42' ||
        path[2] != 'snippets') {
      return missing();
    }
    final tail = path.skip(3).toList();
    if (tail.isEmpty) {
      if (method == 'GET') return jsonResponse(snippets.values.toList());
      if (method == 'POST') {
        writes.add(request);
        final body = Map<String, dynamic>.from(request.data as Map);
        final file = Map<String, dynamic>.from(
          (body['files'] as List).single as Map,
        );
        final id = snippets.isEmpty
            ? 1
            : snippets.keys.reduce((a, b) => a > b ? a : b) + 1;
        snippets[id] = snippet(
          id,
          title: body['title'] as String,
          description: body['description'] as String,
          visibility: body['visibility'] as String,
          fileName: file['file_path'] as String,
        );
        content[id] = file['content'] as String;
        return jsonResponse(snippets[id], status: 201);
      }
    }
    final id = int.tryParse(tail.first);
    if (id == null || !snippets.containsKey(id)) return missing();
    if (tail.length == 1) {
      if (method == 'GET') return jsonResponse(snippets[id]);
      if (method == 'PUT') {
        writes.add(request);
        final body = Map<String, dynamic>.from(request.data as Map);
        final row = snippets[id]!;
        row
          ..['title'] = body['title']
          ..['description'] = body['description']
          ..['visibility'] = body['visibility'];
        final files = body['files'];
        if (files is List && files.isNotEmpty) {
          final file = Map<String, dynamic>.from(files.single as Map);
          if (file['action'] == 'update') {
            content[id] = file['content'] as String;
          }
          if (file['action'] == 'move') row['file_name'] = file['file_path'];
        }
        row['updated_at'] = 'revision-${++revision}';
        return jsonResponse(row);
      }
      if (method == 'DELETE') {
        writes.add(request);
        snippets.remove(id);
        content.remove(id);
        return ResponseBody.fromString('', 204);
      }
    }
    if (tail.length == 2 && tail.last == 'raw' && method == 'GET') {
      return ResponseBody.fromString(content[id]!, 200);
    }
    return missing();
  }
}

class SnippetOwnerHarness extends StatefulWidget {
  const SnippetOwnerHarness({
    super.key,
    required this.first,
    required this.next,
  });

  final SnippetFixture first;
  final SnippetFixture next;

  @override
  State<SnippetOwnerHarness> createState() => SnippetOwnerHarnessState();
}

class SnippetOwnerHarnessState extends State<SnippetOwnerHarness> {
  late SnippetFixture owner = widget.first;

  void switchOwner() => setState(() => owner = widget.next);

  @override
  Widget build(BuildContext context) => SnippetsPage(
    account: owner.account,
    api: owner.api,
    project: owner.project,
  );
}

Future<void> host(
  WidgetTester tester,
  SnippetFixture fixture, {
  double width = 412,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(fixture.api.close);
  await tester.pumpWidget(
    workspaceHost(
      SnippetsPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
      ),
    ),
  );
  await settleNetworkWidgets(tester);
}

Future<void> saveEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('editorSave')));
  await settleNetworkWidgets(tester);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'lists and lazily reads a single snippet from the same instance',
    (tester) async {
      final fixture = SnippetFixture();
      fixture.snippets[1] = fixture.snippet(1);
      fixture.content[1] = 'void main() {}';
      await host(tester, fixture, width: 320);

      expect(find.text('Useful example'), findsOneWidget);
      expect(
        fixture.adapter.requests.where((r) => fixture.pathOf(r).last == 'raw'),
        isEmpty,
      );
      await tester.tap(find.text('Useful example'));
      await settleNetworkWidgets(tester);

      expect(find.byType(MarkdownView), findsOneWidget);
      expect(find.text('void main() {}'), findsOneWidget);
      final raw = fixture.adapter.requests.singleWhere(
        (r) => fixture.pathOf(r).last == 'raw',
      );
      expect(raw.uri.host, 'example.com');
      expect(raw.uri.path, '/gitlab/api/v4/projects/42/snippets/1/raw');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shows explicit unsupported state for verified multi-file metadata',
    (tester) async {
      final fixture = SnippetFixture(
        explicitFiles: [
          {'path': 'one.txt'},
          {'path': 'two.txt'},
        ],
      );
      fixture.snippets[1] = fixture.snippet(1, fileName: 'one.txt');
      fixture.content[1] = 'must not be read as the whole snippet';
      await host(tester, fixture);
      await tester.tap(find.text('Useful example'));
      await settleNetworkWidgets(tester);

      expect(find.text('多檔 Snippet 尚無法安全讀取'), findsOneWidget);
      final edit = find.byIcon(Icons.edit_outlined);
      expect(edit, findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(of: edit, matching: find.byType(IconButton)),
            )
            .onPressed,
        isNull,
      );
      expect(
        fixture.adapter.requests.where((r) => fixture.pathOf(r).last == 'raw'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'file_name without files cannot enable legacy preview or editing',
    (tester) async {
      final fixture = SnippetFixture(omitFiles: true);
      fixture.snippets[1] = fixture.snippet(1, fileName: 'README.md');
      fixture.content[1] =
          'partial legacy raw must not be presented as complete';
      await host(tester, fixture);
      await tester.tap(find.text('Useful example'));
      await settleNetworkWidgets(tester);

      expect(find.text('無法確認 Snippet 檔案清單'), findsOneWidget);
      final edit = find.byIcon(Icons.edit_outlined);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(of: edit, matching: find.byType(IconButton)),
            )
            .onPressed,
        isNull,
      );
      expect(
        fixture.adapter.requests.where(
          (request) => fixture.pathOf(request).last == 'raw',
        ),
        isEmpty,
      );
    },
  );

  testWidgets('creates, reads back, edits and typed-deletes a single file', (
    tester,
  ) async {
    final fixture = SnippetFixture();
    await host(tester, fixture);

    await tester.tap(find.byKey(const ValueKey('create-snippet')));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-title')),
      'Created',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-description')),
      'Details',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-file_name')),
      'note.txt',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      'first',
    );
    await saveEditor(tester);

    expect(find.text('Snippet #1'), findsOneWidget);
    expect(find.text('first'), findsOneWidget);
    final post = fixture.writes.singleWhere((r) => r.method == 'POST');
    final postBody = Map<String, dynamic>.from(post.data as Map);
    expect(postBody['visibility'], 'private');
    expect(postBody['files'], [
      {'file_path': 'note.txt', 'content': 'first'},
    ]);

    await tester.tap(find.byTooltip('編輯 Snippet'));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-title')),
      'Updated',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      'second',
    );
    await saveEditor(tester);

    expect(find.text('Updated'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    final put = fixture.writes.singleWhere((r) => r.method == 'PUT');
    final putBody = Map<String, dynamic>.from(put.data as Map);
    expect(putBody['files'], [
      {'action': 'update', 'file_path': 'note.txt', 'content': 'second'},
    ]);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刪除'));
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(FilledButton, '確認');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '#1',
    );
    await tester.pump();
    await tester.tap(confirm);
    await settleNetworkWidgets(tester);

    expect(fixture.snippets, isEmpty);
    expect(find.text('這個專案沒有 Snippet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refuses a stale overwrite and keeps the editor draft', (
    tester,
  ) async {
    final fixture = SnippetFixture();
    fixture.snippets[1] = fixture.snippet(1);
    fixture.content[1] = 'server before';
    await host(tester, fixture);
    await tester.tap(find.text('Useful example'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('編輯 Snippet'));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      'my unsaved draft',
    );

    fixture.snippets[1]!['updated_at'] = 'revision-from-another-client';
    fixture.content[1] = 'server after';
    await saveEditor(tester);

    expect(find.text('編輯 Snippet'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('editor-content')))
          .controller!
          .text,
      'my unsaved draft',
    );
    expect(fixture.writes.where((request) => request.method == 'PUT'), isEmpty);
    expect(find.textContaining('內容已經變更'), findsOneWidget);
  });

  testWidgets('account API change dismisses an owned editor without writing', (
    tester,
  ) async {
    final first = SnippetFixture();
    final next = SnippetFixture();
    addTearDown(first.api.close);
    addTearDown(next.api.close);
    final key = GlobalKey<SnippetOwnerHarnessState>();
    await tester.pumpWidget(
      workspaceHost(SnippetOwnerHarness(key: key, first: first, next: next)),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('create-snippet')));
    await settleNetworkWidgets(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Draft');

    key.currentState!.switchOwner();
    await tester.pump();
    await settleNetworkWidgets(tester);

    expect(find.byKey(const Key('editorSave')), findsNothing);
    expect(first.writes, isEmpty);
    expect(next.writes, isEmpty);
  });

  testWidgets(
    'account API change dismisses detail confirmation without delete',
    (tester) async {
      final first = SnippetFixture();
      first.snippets[1] = first.snippet(1);
      first.content[1] = 'content';
      final next = SnippetFixture();
      addTearDown(first.api.close);
      addTearDown(next.api.close);
      final key = GlobalKey<SnippetOwnerHarnessState>();
      await tester.pumpWidget(
        workspaceHost(SnippetOwnerHarness(key: key, first: first, next: next)),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('Useful example'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刪除'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      key.currentState!.switchOwner();
      await tester.pump();
      await settleNetworkWidgets(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        first.writes.where((request) => request.method == 'DELETE'),
        isEmpty,
      );
      expect(next.writes, isEmpty);
    },
  );

  testWidgets(
    'caps huge-line layout and tells the user full content is retained',
    (tester) async {
      final fixture = SnippetFixture();
      fixture.snippets[1] = fixture.snippet(1);
      fixture.content[1] = 'x' * 2500;
      await host(tester, fixture, width: 320);
      await tester.tap(find.text('Useful example'));
      await settleNetworkWidgets(tester);

      expect(find.textContaining('預覽已截短'), findsOneWidget);
      expect(find.textContaining(' …'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
