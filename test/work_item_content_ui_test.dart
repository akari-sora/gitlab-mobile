import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/features/workspace/work_item_content.dart';

import 'support/fake_adapter.dart';

const _projectRef = GraphResourceRef(
  id: 'gid://gitlab/Project/42',
  fullPath: 'studio/mobile-workspace',
);
const _namespaceRef = GraphResourceRef(
  id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
  fullPath: 'studio/mobile-workspace',
);
const _groupNamespaceRef = GraphResourceRef(
  id: 'gid://gitlab/Group/84',
  fullPath: 'studio/mobile-group',
);
const _type = WorkItemGraphType(
  id: 'gid://gitlab/WorkItems::Type/9',
  name: 'Task',
);

WorkItemGraphSummary _summary({
  String title = 'Original title',
  DateTime? updatedAt,
  bool group = false,
}) => WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/31',
  iid: 31,
  title: title,
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: updatedAt ?? DateTime.utc(2026, 10, 3, 10),
  project: group ? null : _projectRef,
  namespace: group ? _groupNamespaceRef : _namespaceRef,
  type: _type,
);

WorkItemGraphDetail _detail({bool group = false}) => WorkItemGraphDetail(
  summary: _summary(group: group),
  description: 'Displayed detail may be stale',
  widgetsAvailable: true,
  widgetTypes: const {'DESCRIPTION'},
  descriptionWidget: const WorkItemDescriptionWidget(
    description: 'Displayed detail may be stale',
    edited: false,
    lastEditedAt: null,
  ),
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'reader7', name: 'Reader 7'),
  token: 'synthetic-token',
);

enum _DescriptionMode { present, absent, unavailable }

final class _ContentServer {
  _ContentServer({this.group = false});

  final bool group;
  String title = 'Fresh title';
  String description = '  Fresh **Markdown**\n\n';
  String updatedAt = '2026-10-03T10:00:00Z';
  bool canUpdate = true;
  bool rejectNextMutation = false;
  _DescriptionMode mode = _DescriptionMode.present;
  int reads = 0;
  int writes = 0;
  Map<String, Object?>? lastInput;

  List<Object?>? get widgets => switch (mode) {
    _DescriptionMode.present => [
      {
        'type': 'DESCRIPTION',
        'description': description,
        'edited': false,
        'lastEditedAt': null,
      },
    ],
    _DescriptionMode.absent => <Object?>[],
    _DescriptionMode.unavailable => null,
  };

  Map<String, Object?> workItem({required bool permission}) => {
    'id': 'gid://gitlab/WorkItem/31',
    'iid': '31',
    'title': title,
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': updatedAt,
    'project': group
        ? null
        : {'id': _projectRef.id, 'fullPath': _projectRef.fullPath},
    'namespace': {
      'id': group ? _groupNamespaceRef.id : _namespaceRef.id,
      'fullPath': group ? _groupNamespaceRef.fullPath : _namespaceRef.fullPath,
    },
    'workItemType': {'id': _type.id, 'name': _type.name},
    if (permission) 'userPermissions': {'updateWorkItem': canUpdate},
    'widgets': widgets,
  };

  Future<ResponseBody> respond(RequestOptions request) async {
    final body = request.data as Map;
    final query = body['query'] as String;
    if (query.contains('MobileWorkItemContent')) {
      reads++;
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'workItem': workItem(permission: true),
        },
      });
    }
    if (query.contains('MobileUpdateWorkItemContent')) {
      writes++;
      final variables = body['variables'] as Map;
      lastInput = Map<String, Object?>.from(variables['input'] as Map);
      if (rejectNextMutation) {
        rejectNextMutation = false;
        return jsonResponse({
          'data': {
            'workItemUpdate': {
              'errors': ['synthetic rejection'],
              'workItem': null,
            },
          },
        });
      }
      final nextTitle = lastInput!['title'];
      if (nextTitle is String) title = nextTitle;
      final descriptionWidget = lastInput!['descriptionWidget'];
      if (descriptionWidget is Map) {
        description = descriptionWidget['description']! as String;
      }
      updatedAt = '2026-10-03T10:01:00Z';
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': workItem(permission: false),
          },
        },
      });
    }
    throw StateError('Unexpected operation');
  }
}

Widget _host({
  required GitLabApi api,
  required Future<void> Function() onSaved,
  WorkItemGraphDetail? detail,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: WorkItemContentControl(
        account: _account(api),
        api: api,
        detail: detail ?? _detail(),
        project: (detail ?? _detail()).summary.project == null
            ? null
            : const Project(
                id: 42,
                name: 'Mobile workspace',
                path: 'studio/mobile-workspace',
              ),
        onSaved: onSaved,
      ),
    ),
  ),
);

Future<void> _openEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('work-item-content-edit')));
  await tester.pumpAndSettle();
  expect(find.text('編輯工作項目'), findsOneWidget);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('description validator enforces UTF-8 bytes and line boundaries', () {
    expect(
      validateWorkItemDescriptionInput('😀' * (GitLabApi.maxTextBytes ~/ 4)),
      isNull,
    );
    expect(
      validateWorkItemDescriptionInput(
        '😀' * (GitLabApi.maxTextBytes ~/ 4 + 1),
      ),
      '說明超過 2 MiB 上限',
    );
    expect(
      validateWorkItemDescriptionInput(
        List.filled(GitLabApi.maxTextLines, 'line').join('\n'),
      ),
      isNull,
    );
    expect(
      validateWorkItemDescriptionInput(
        List.filled(GitLabApi.maxTextLines + 1, 'line').join('\n'),
      ),
      '說明超過 20,000 行上限',
    );
  });

  testWidgets('loads lazily and saves exact Markdown from a fresh snapshot', (
    tester,
  ) async {
    final server = _ContentServer();
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
    addTearDown(api.close);
    var saved = 0;
    await tester.pumpWidget(_host(api: api, onSaved: () async => saved++));
    await tester.pump();
    expect(server.reads, 0);

    await _openEditor(tester);
    expect(server.reads, 1);
    expect(find.text('Fresh title'), findsOneWidget);
    expect(find.textContaining('可編輯標題與 Markdown 說明'), findsOneWidget);

    const nextDescription = '  Leading space\n\nTrailing space  ';
    await tester.enterText(
      find.byKey(const ValueKey('editor-title')),
      'Updated title',
    );
    await tester.enterText(
      find.byKey(const ValueKey('editor-description')),
      nextDescription,
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await tester.pumpAndSettle();

    expect(server.writes, 1);
    expect(
      server.reads,
      3,
      reason: 'open, write preflight, independent readback',
    );
    expect(server.lastInput!['title'], 'Updated title');
    expect(server.lastInput!['descriptionWidget'], {
      'description': nextDescription,
    });
    expect(saved, 1);
    expect(find.text('編輯工作項目'), findsNothing);
  });

  for (final mode in [_DescriptionMode.absent, _DescriptionMode.unavailable]) {
    testWidgets('${mode.name} description offers title-only editing', (
      tester,
    ) async {
      final server = _ContentServer()..mode = mode;
      final adapter = FakeAdapter(server.respond);
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(_host(api: api, onSaved: () async {}));

      await _openEditor(tester);
      expect(find.byKey(const ValueKey('editor-title')), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-description')), findsNothing);
      expect(find.textContaining('只編輯標題'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('editor-title')),
        'Title only',
      );
      await tester.tap(find.byKey(const Key('editorSave')));
      await tester.pumpAndSettle();
      expect(server.writes, 1);
      expect(server.lastInput!.containsKey('descriptionWidget'), isFalse);
    });
  }

  testWidgets('read-only permission is explicit and never opens an editor', (
    tester,
  ) async {
    final server = _ContentServer()..canUpdate = false;
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api, onSaved: () async {}));

    await tester.tap(find.byKey(const ValueKey('work-item-content-edit')));
    await tester.pumpAndSettle();
    expect(find.text('無法編輯工作項目'), findsOneWidget);
    expect(find.text('編輯工作項目'), findsNothing);
    expect(server.reads, 1);
    expect(server.writes, 0);
  });

  testWidgets('local title limit preserves the unused target for correction', (
    tester,
  ) async {
    final server = _ContentServer();
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api, onSaved: () async {}));
    await _openEditor(tester);

    await tester.enterText(
      find.byKey(const ValueKey('editor-title')),
      'x' * 4097,
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await tester.pump();
    expect(find.text('不可超過 4096 個字元'), findsOneWidget);
    expect(server.writes, 0);

    await tester.enterText(
      find.byKey(const ValueKey('editor-title')),
      'Corrected title',
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await tester.pumpAndSettle();
    expect(server.writes, 1);
  });

  testWidgets(
    'invalid description stays local and correction uses the fresh target',
    (tester) async {
      final server = _ContentServer();
      final adapter = FakeAdapter(server.respond);
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(_host(api: api, onSaved: () async {}));
      await _openEditor(tester);

      await tester.enterText(
        find.byKey(const ValueKey('editor-description')),
        'invalid\u0000description',
      );
      await tester.tap(find.byKey(const Key('editorSave')));
      await tester.pump();
      expect(find.text('說明包含無法儲存的控制字元'), findsOneWidget);
      expect(server.reads, 1, reason: 'local validation must not preflight');
      expect(server.writes, 0);

      await tester.enterText(
        find.byKey(const ValueKey('editor-description')),
        'corrected description',
      );
      await tester.tap(find.byKey(const Key('editorSave')));
      await tester.pumpAndSettle();
      expect(server.reads, 3);
      expect(server.writes, 1);
      expect(server.description, 'corrected description');
    },
  );

  testWidgets(
    'failed content save shows the scoped Work Item instead of draft identity',
    (tester) async {
      final server = _ContentServer()..rejectNextMutation = true;
      final adapter = FakeAdapter(server.respond);
      final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
      addTearDown(api.close);
      await tester.pumpWidget(_host(api: api, onSaved: () async {}));
      await _openEditor(tester);

      await tester.enterText(
        find.byKey(const ValueKey('editor-title')),
        'Rejected title',
      );
      await tester.tap(find.byKey(const Key('editorSave')));
      await tester.pumpAndSettle();

      expect(server.writes, 1);
      expect(find.text('實例：https://example.com:8443/gitlab'), findsOneWidget);
      expect(find.text('App 帳號：@reader7'), findsOneWidget);
      expect(
        find.text(
          '目標：work-item-content:gid://gitlab/Project/42:'
          'gid://gitlab/WorkItem/31',
        ),
        findsNothing,
      );
      expect(
        find.text('目標：studio/mobile-workspace · 工作項目 #31'),
        findsOneWidget,
      );
    },
  );

  testWidgets('group failure label keeps the same IID bound to group scope', (
    tester,
  ) async {
    final server = _ContentServer(group: true)..rejectNextMutation = true;
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      _host(api: api, detail: _detail(group: true), onSaved: () async {}),
    );
    await _openEditor(tester);

    await tester.enterText(
      find.byKey(const ValueKey('editor-title')),
      'Rejected group title',
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await tester.pumpAndSettle();

    expect(find.text('目標：studio/mobile-group · 工作項目 #31'), findsOneWidget);
    expect(find.text('目標：studio/mobile-workspace · 工作項目 #31'), findsNothing);
  });

  testWidgets(
    'single-use save failure disables retry until editor is reopened',
    (tester) async {
      final fixtureApi = testApi(
        FakeAdapter((_) => throw StateError('unused')),
      );
      addTearDown(fixtureApi.close);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceEditor(
            account: _account(fixtureApi),
            title: '編輯工作項目',
            resource: 'work-item-content-single-use',
            persistent: false,
            blockRetryOnSaveFailure: true,
            fields: const [
              EditField('title', '標題', required: true, value: 'Title'),
            ],
            save: (_) async {
              calls++;
              throw const ApiFailure(FailureKind.conflict);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editorSave')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('內容已經變更'), findsOneWidget);
      expect(find.text('目標：work-item-content-single-use'), findsOneWidget);
      expect(find.text('請保留草稿並返回，重新開啟編輯以確認最新內容後再儲存。'), findsOneWidget);
      final save = tester.widget<FilledButton>(
        find.byKey(const Key('editorSave')),
      );
      expect(save.onPressed, isNull);
      await tester.tap(
        find.byKey(const Key('editorSave')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(calls, 1);
    },
  );
}
