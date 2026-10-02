import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/snippets_page.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

class MultiSnippetFixture {
  MultiSnippetFixture({this.host = 'https://example.com/gitlab'});

  final String host;
  late final adapter = FakeAdapter(respond);
  late final api = testApi(adapter, host: host);
  late final account = Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
    token: 'synthetic-test-token',
  );
  final project = const Project(id: 42, name: 'Example', path: 'team/example');
  final files = <String, String>{
    'README.md': '# Read me',
    'lib/main.dart': 'void main() {}',
  };
  final writes = <RequestOptions>[];
  final blobPaths = <String>[];
  Completer<ResponseBody>? blobGate;
  bool failBlobAfterWrite = false;
  String description = '**Markdown** notes';
  int revision = 1;

  String get restUpdatedAt =>
      '2026-08-13T15:25:${revision.toString().padLeft(2, '0')}.905Z';
  String get graphUpdatedAt =>
      '2026-08-13T15:25:${revision.toString().padLeft(2, '0')}Z';

  Map<String, dynamic> get snippet => {
    'id': 6030720,
    'project_id': 42,
    'title': 'Multi example',
    'description': description,
    'visibility': 'private',
    'file_name': files.keys.first,
    'updated_at': restUpdatedAt,
    'author': {'name': 'Synthetic User'},
    'files': [
      for (final path in files.keys) {'path': path},
    ],
  };

  Map<String, dynamic> identity({Object? blobs}) => {
    'id': 'gid://gitlab/ProjectSnippet/6030720',
    'project': {'id': 'gid://gitlab/Project/42', 'fullPath': 'team/example'},
    'updatedAt': graphUpdatedAt,
    'blobs': ?blobs,
  };

  ResponseBody graphList() => jsonResponse({
    'data': {
      'snippets': {
        'nodes': [identity()],
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      },
    },
  });

  ResponseBody graphBlob(String path) => jsonResponse({
    'data': {
      'snippets': {
        'nodes': [
          identity(
            blobs: {
              'hasUnretrievableBlobs': false,
              'nodes': [
                {
                  'binary': false,
                  'name': path.split('/').last,
                  'path': path,
                  'rawPath': 'https://example.com/raw/$path',
                  'size': utf8.encode(files[path]!).length,
                  'rawPlainData': files[path],
                  'renderedAsText': true,
                  'simpleViewer': {'tooLarge': false, 'renderError': null},
                },
              ],
            },
          ),
        ],
      },
    },
  });

  List<String> apiPath(RequestOptions request) {
    final segments = request.uri.pathSegments;
    return segments.skip(segments.indexOf('v4') + 1).toList();
  }

  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path.endsWith('/graphql')) {
      final body = request.data as Map;
      final query = body['query'] as String;
      if (query.contains('MobileProjectSnippets')) return graphList();
      final variables = body['variables'] as Map;
      final path = ((variables['paths'] as List).single) as String;
      blobPaths.add(path);
      final gate = blobGate;
      if (gate != null && !gate.isCompleted) return gate.future;
      if (failBlobAfterWrite && writes.isNotEmpty) {
        return jsonResponse({
          'data': {
            'snippets': {'nodes': <Object>[]},
          },
        });
      }
      return graphBlob(path);
    }
    final path = apiPath(request);
    if (path.length == 3 &&
        path[0] == 'projects' &&
        path[1] == '42' &&
        path[2] == 'snippets' &&
        request.method == 'GET') {
      return jsonResponse([snippet]);
    }
    if (path.length == 4 &&
        path[0] == 'projects' &&
        path[1] == '42' &&
        path[2] == 'snippets' &&
        path[3] == '6030720') {
      if (request.method == 'GET') return jsonResponse(snippet);
      if (request.method == 'PUT') {
        writes.add(request);
        final body = Map<String, dynamic>.from(request.data as Map);
        final actions = body['files'];
        if (actions is List) {
          for (final raw in actions) {
            final action = Map<String, dynamic>.from(raw as Map);
            switch (action['action']) {
              case 'create':
              case 'update':
                files[action['file_path'] as String] =
                    action['content'] as String;
              case 'move':
                final old = action['previous_path'] as String;
                files[action['file_path'] as String] = files.remove(old)!;
              case 'delete':
                files.remove(action['file_path']);
            }
          }
        }
        revision++;
        return jsonResponse(snippet);
      }
    }
    return jsonResponse({'message': '404 Not Found'}, status: 404);
  }
}

Future<void> hostMulti(
  WidgetTester tester,
  MultiSnippetFixture fixture, {
  double width = 412,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, 900 * 2);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(fixture.api.close);
  await tester.pumpWidget(
    workspaceHost(
      SnippetsPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
      ),
      scale: textScale,
    ),
  );
  await settleNetworkWidgets(tester);
}

Future<void> openMulti(WidgetTester tester, MultiSnippetFixture fixture) async {
  await hostMulti(tester, fixture);
  await tester.tap(find.text('Multi example'));
  await settleNetworkWidgets(tester);
}

Future<void> saveEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('editorSave')));
  await settleNetworkWidgets(tester);
}

class OwnerHarness extends StatefulWidget {
  const OwnerHarness({super.key, required this.first, required this.second});

  final MultiSnippetFixture first;
  final MultiSnippetFixture second;

  @override
  State<OwnerHarness> createState() => OwnerHarnessState();
}

class OwnerHarnessState extends State<OwnerHarness> {
  late MultiSnippetFixture current = widget.first;
  Project? overrideProject;

  void switchOwner() => setState(() => current = widget.second);
  void renameProject() => setState(() {
    overrideProject = const Project(
      id: 42,
      name: 'Example',
      path: 'team/renamed-example',
    );
  });

  @override
  Widget build(BuildContext context) => SnippetsPage(
    account: current.account,
    api: current.api,
    project: overrideProject ?? current.project,
  );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('long description folds so file controls stay reachable', (
    tester,
  ) async {
    final fixture = MultiSnippetFixture()
      ..description = List.filled(
        80,
        'A long explanatory paragraph.',
      ).join('\n\n');
    await openMulti(tester, fixture);
    expect(
      find.byKey(const ValueKey('snippet-description-toggle')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('README.md').hitTestable(), findsWidgets);
    expect(
      find.byKey(const ValueKey('snippet-source-mode')).hitTestable(),
      findsOneWidget,
    );
    expect(fixture.blobPaths, ['README.md']);
    await tester.tap(find.byKey(const ValueKey('snippet-description-toggle')));
    await settleNetworkWidgets(tester);
    expect(
      find.textContaining('A long explanatory paragraph.', findRichText: true),
      findsWidgets,
    );
    expect(fixture.blobPaths, ['README.md']);
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'loads only the selected path and toggles Markdown at 320dp with 2x text',
    (tester) async {
      final fixture = MultiSnippetFixture();
      await hostMulti(tester, fixture, width: 320, textScale: 2);
      await tester.tap(find.text('Multi example'));
      await settleNetworkWidgets(tester);

      expect(fixture.blobPaths, ['README.md']);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('snippet-source-mode')),
        250,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('snippet-markdown-mode')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('snippet-markdown-mode')));
      await tester.pumpAndSettle();
      expect(find.text('Read me'), findsWidgets);
      expect(fixture.blobPaths, ['README.md']);

      await tester.ensureVisible(
        find.byKey(const ValueKey('snippet-file-lib/main.dart')),
      );
      await tester.tap(
        find.byKey(const ValueKey('snippet-file-lib/main.dart')),
      );
      await settleNetworkWidgets(tester);
      expect(fixture.blobPaths, ['README.md', 'lib/main.dart']);
      expect(find.text('void main() {}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('adds a file with an exact action and verified readback', (
    tester,
  ) async {
    final fixture = MultiSnippetFixture();
    await openMulti(tester, fixture);

    await tester.tap(find.byKey(const ValueKey('snippet-add-file')));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-file_path')),
      ' notes/todo.md ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      '- verify',
    );
    await saveEditor(tester);

    expect(fixture.writes, hasLength(1));
    final body = Map<String, dynamic>.from(fixture.writes.single.data as Map);
    expect(body['files'], [
      {'action': 'create', 'file_path': 'notes/todo.md', 'content': '- verify'},
    ]);
    expect(find.text('notes/todo.md'), findsWidgets);
    expect(find.text('- verify'), findsOneWidget);
  });

  testWidgets('updates renames and deletes one selected file', (tester) async {
    final fixture = MultiSnippetFixture();
    await openMulti(tester, fixture);

    final editFile = find.byKey(const ValueKey('snippet-edit-file')).last;
    await tester.scrollUntilVisible(
      editFile,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(editFile);
    await tester.tap(editFile);
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      '# Updated',
    );
    await saveEditor(tester);

    final renameFile = find.byKey(const ValueKey('snippet-rename-file')).last;
    await tester.scrollUntilVisible(
      renameFile,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(renameFile);
    await tester.tap(renameFile);
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-file_path')),
      ' docs/README.md ',
    );
    await saveEditor(tester);

    final deleteFile = find.byKey(const ValueKey('snippet-delete-file')).last;
    await tester.scrollUntilVisible(
      deleteFile,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(deleteFile);
    await tester.tap(deleteFile);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'docs/README.md',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);

    expect(fixture.writes, hasLength(3));
    final actions = [
      for (final request in fixture.writes)
        ((request.data as Map)['files'] as List).single as Map,
    ];
    expect(actions[0], {
      'action': 'update',
      'file_path': 'README.md',
      'content': '# Updated',
    });
    expect(actions[1], {
      'action': 'move',
      'previous_path': 'README.md',
      'file_path': 'docs/README.md',
    });
    expect(actions[2], {'action': 'delete', 'file_path': 'docs/README.md'});
    expect(find.text('docs/README.md'), findsNothing);
    expect(fixture.files.keys, ['lib/main.dart']);
  });

  testWidgets('stale snapshot blocks a multi-file write', (tester) async {
    final stale = MultiSnippetFixture();
    await openMulti(tester, stale);
    await tester.tap(find.byKey(const ValueKey('snippet-add-file')));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-file_path')),
      'stale.txt',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      'stale',
    );
    stale.revision++;
    await saveEditor(tester);
    expect(find.text('Snippet 已經變更'), findsOneWidget);
    expect(stale.writes, isEmpty);
  });

  testWidgets('uncertain readback fences a second write', (tester) async {
    final uncertain = MultiSnippetFixture();
    await openMulti(tester, uncertain);
    uncertain.failBlobAfterWrite = true;
    await tester.tap(find.byKey(const ValueKey('snippet-add-file')));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-file_path')),
      'uncertain.txt',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      'once',
    );
    await saveEditor(tester);
    expect(find.text('尚未確認操作結果'), findsOneWidget);
    await saveEditor(tester);
    expect(uncertain.writes, hasLength(1));
  });

  testWidgets('account switch dismisses detail while an old blob is delayed', (
    tester,
  ) async {
    final first = MultiSnippetFixture();
    final second = MultiSnippetFixture(host: 'https://next.example/gitlab');
    first.blobGate = Completer<ResponseBody>();
    addTearDown(first.api.close);
    addTearDown(second.api.close);
    final key = GlobalKey<OwnerHarnessState>();
    await tester.pumpWidget(
      workspaceHost(OwnerHarness(key: key, first: first, second: second)),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('Multi example'));
    await pumpUntil(
      tester,
      () => first.blobPaths.isNotEmpty,
      description: 'old account blob request',
    );

    key.currentState!.switchOwner();
    await tester.pump();
    first.blobGate!.complete(first.graphBlob('README.md'));
    await settleNetworkWidgets(tester);

    expect(find.text('Snippet #6030720'), findsNothing);
    expect(find.text('# Read me'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same numeric project with a new path dismisses delayed detail', (
    tester,
  ) async {
    final fixture = MultiSnippetFixture();
    fixture.blobGate = Completer<ResponseBody>();
    addTearDown(fixture.api.close);
    final key = GlobalKey<OwnerHarnessState>();
    await tester.pumpWidget(
      workspaceHost(OwnerHarness(key: key, first: fixture, second: fixture)),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('Multi example'));
    await pumpUntil(
      tester,
      () => fixture.blobPaths.isNotEmpty,
      description: 'old project-path blob request',
    );

    key.currentState!.renameProject();
    await tester.pump();
    fixture.blobGate!.complete(fixture.graphBlob('README.md'));
    await settleNetworkWidgets(tester);

    expect(find.text('Snippet #6030720'), findsNothing);
    expect(find.text('# Read me'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
