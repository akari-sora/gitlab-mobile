import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_activity.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'support/fake_adapter.dart';

const _workItemId = 'gid://gitlab/WorkItem/700';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/42';
const _path = 'team/example-42';
const _project = Project(id: 42, name: 'Example', path: _path);

final _summary = WorkItemGraphSummary(
  id: _workItemId,
  iid: 7,
  title: 'Synthetic work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  project: const GraphResourceRef(id: _projectId, fullPath: _path),
  namespace: const GraphResourceRef(id: _namespaceId, fullPath: _path),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/server-owned',
    name: 'Task',
  ),
);

final _detail = WorkItemGraphDetail(
  summary: _summary,
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'NOTES'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'reader', name: 'Reader'),
  token: 'synthetic-token',
);

Map<String, Object?> _pageInfo({bool next = false, String? cursor}) => {
  'hasNextPage': next,
  'endCursor': cursor,
};

Map<String, Object?> _identity() => {
  'id': _workItemId,
  'iid': '7',
  'project': {'id': _projectId, 'fullPath': _path},
  'namespace': {'id': _namespaceId, 'fullPath': _path},
};

Map<String, Object?> _note(
  String suffix, {
  bool system = false,
  String? body,
  Object? author = const {
    'id': 'gid://gitlab/User/9',
    'name': 'Synthetic User',
    'username': 'synthetic-user',
  },
}) => {
  'id': 'gid://gitlab/Note/$suffix',
  'system': system,
  'systemNoteIconName': system ? 'status' : null,
  'body': body ?? (system ? 'system-$suffix' : '**comment-$suffix**'),
  'createdAt': '2026-10-01T01:02:03Z',
  'updatedAt': '2026-10-01T01:03:04Z',
  'author': author,
};

Map<String, Object?> _discussion(
  String suffix, {
  List<Object?> notes = const [],
  bool notesNext = false,
  String? notesCursor,
  String? replyId,
}) => {
  'id': 'gid://gitlab/Discussion/$suffix',
  'replyId': replyId ?? 'reply-$suffix',
  'createdAt': '2026-10-01T01:00:00Z',
  'notes': {
    'nodes': notes,
    'pageInfo': _pageInfo(next: notesNext, cursor: notesCursor),
  },
};

Map<String, Object?> _activity({
  Object? widgets,
  bool widgetsUnavailable = false,
  List<Object?> discussions = const [],
  bool next = false,
  String? cursor,
  bool canCreateNote = true,
  bool discussionLocked = false,
}) => {
  'data': {
    'currentUser': {'id': 'gid://gitlab/User/7'},
    'workItem': {
      ..._identity(),
      'userPermissions': {'createNote': canCreateNote},
      'widgets': widgetsUnavailable
          ? null
          : widgets ??
                [
                  {
                    'type': 'NOTES',
                    'discussionLocked': discussionLocked,
                    'discussions': {
                      'nodes': discussions,
                      'pageInfo': _pageInfo(next: next, cursor: cursor),
                    },
                  },
                ],
    },
  },
};

Map<String, Object?> _notesPage(
  String discussion, {
  required String anchor,
  required List<Object?> notes,
  bool next = false,
  String? cursor,
}) => {
  'data': {
    'workItem': _identity(),
    'anchor': {
      'id': 'gid://gitlab/Note/$anchor',
      'project': {'id': _projectId, 'fullPath': _path},
      'discussion': _discussion(
        discussion,
        notes: notes,
        notesNext: next,
        notesCursor: cursor,
      ),
    },
  },
};

bool _isWriteAccessRequest(RequestOptions request) =>
    ((request.data as Map)['query'] as String).contains(
      'MobileWorkItemActivityWriteAccess',
    );

Map<String, Object?> _createdNote(
  String suffix,
  String body, {
  String discussionId = 'gid://gitlab/Discussion/created',
  String replyId = 'gid://gitlab/Discussion/created-reply',
  String discussionCreatedAt = '2026-10-01T02:00:00Z',
}) => {
  ..._note(suffix, body: body),
  'internal': false,
  'author': {
    'id': 'gid://gitlab/User/7',
    'name': 'Reader',
    'username': 'reader',
  },
  'noteableType': 'Issue',
  'noteableId': '700',
  'project': {'id': _projectId, 'fullPath': _path},
  'discussion': {
    'id': discussionId,
    'replyId': replyId,
    'createdAt': discussionCreatedAt,
  },
};

Map<String, Object?> _createdMutation(Map<String, Object?> note) => {
  'data': {
    'createNote': {'errors': const <Object?>[], 'note': note},
  },
};

Map<String, Object?> _createdReadback(Map<String, Object?> note) => {
  'data': {'workItem': _identity(), 'note': note},
};

Map<String, Object?> _replyPreflight({
  required String anchorNoteId,
  required String discussionId,
  required String replyId,
  String discussionCreatedAt = '2026-10-01T01:00:00Z',
}) => {
  'data': {
    'currentUser': {'id': 'gid://gitlab/User/7'},
    'workItem': {
      ..._identity(),
      'userPermissions': {'createNote': true},
      'widgets': const [
        {'type': 'NOTES', 'discussionLocked': false},
      ],
    },
    'anchor': {
      'id': anchorNoteId,
      'noteableType': 'Issue',
      'noteableId': '700',
      'project': {'id': _projectId, 'fullPath': _path},
      'discussion': {
        'id': discussionId,
        'replyId': replyId,
        'createdAt': discussionCreatedAt,
      },
    },
  },
};

Widget _host(
  GitLabApi api, {
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  double textScale = 1,
  Brightness? brightness,
  ValueChanged<Route<dynamic>>? onRoute,
}) => MaterialApp(
  theme: brightness == null ? null : appTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: WorkItemActivityPanel(
        account: _account(api),
        api: api,
        detail: _detail,
        project: _project,
        isCurrent: isCurrent,
        ownerChanges: ownerChanges,
        onRoute: onRoute,
      ),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

Future<void> _selectControl(
  WidgetTester tester,
  String key,
  String label,
) async {
  await _tap(tester, find.byKey(ValueKey(key)));
  await tester.pump(const Duration(milliseconds: 300));
  await _tap(tester, find.text(label).last);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _expand(WidgetTester tester) async {
  await _tap(tester, find.text('活動'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'activity labels clear their fields in $brightness at ${textScale}x text',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(textScale == 1 ? 390 : 320, 900);
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          try {
            final api = testApi(FakeAdapter((_) => jsonResponse(_activity())));
            addTearDown(api.close);
            await tester.pumpWidget(
              _host(api, brightness: brightness, textScale: textScale),
            );
            await _expand(tester);

            for (final entry in {
              'work-item-activity-filter': '活動篩選',
              'work-item-activity-order': '活動排序',
            }.entries) {
              final control = find.byKey(ValueKey(entry.key));
              await tester.ensureVisible(control);
              await tester.pump();
              final label = find.text(entry.value);
              final field = find.ancestor(
                of: control,
                matching: find.byType(InputDecorator),
              );
              expect(label, findsOneWidget);
              expect(field, findsOneWidget);
              expect(
                tester.getRect(label).bottom,
                lessThanOrEqualTo(tester.getRect(field).top),
                reason: 'The entire label must stay above the filled field.',
              );
              expect(tester.getSemantics(control).label, contains(entry.value));
              expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
            }
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('six activity configurations fetch a fresh server stream', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final variables = (request.data as Map)['variables'] as Map;
      expect(variables['after'], isNull);
      return jsonResponse(
        _activity(
          discussions: [
            _discussion(
              'same-id',
              notes: [
                _note(
                  'same-note',
                  body: '${variables['filter']}/${variables['sort']}',
                ),
              ],
            ),
          ],
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));
    await _expand(tester);
    expect(find.text('ALL_NOTES/CREATED_ASC'), findsOneWidget);
    for (final entry in [
      ('work-item-activity-order', '最新優先', 'ALL_NOTES/CREATED_DESC'),
      ('work-item-activity-filter', '只看留言', 'ONLY_COMMENTS/CREATED_DESC'),
      ('work-item-activity-order', '最舊優先', 'ONLY_COMMENTS/CREATED_ASC'),
      ('work-item-activity-filter', '只看歷史', 'ONLY_ACTIVITY/CREATED_ASC'),
      ('work-item-activity-order', '最新優先', 'ONLY_ACTIVITY/CREATED_DESC'),
    ]) {
      await _selectControl(tester, entry.$1, entry.$2);
      await tester.pumpAndSettle();
      expect(find.text(entry.$3), findsOneWidget);
      expect(find.byType(MarkdownView), findsOneWidget);
    }
    expect(adapter.requests, hasLength(7));
    expect(tester.takeException(), isNull);
  });

  for (final pendingKind in ['initial', 'next', 'reply']) {
    testWidgets('selection invalidates pending $pendingKind and cached notes', (
      tester,
    ) async {
      final pending = Completer<ResponseBody>();
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final variables = body['variables'] as Map;
        final notesQuery = (body['query'] as String).contains(
          'MobileWorkItemDiscussionNotes',
        );
        if (variables['filter'] == 'ONLY_COMMENTS') {
          expect(variables['after'], isNull);
          return jsonResponse(
            _activity(
              discussions: [
                _discussion(
                  'fresh',
                  notes: [_note('shared', body: 'fresh stream')],
                ),
              ],
            ),
          );
        }
        if (pendingKind == 'initial' ||
            pendingKind == 'next' && variables['after'] != null ||
            pendingKind == 'reply' && notesQuery) {
          return pending.future;
        }
        return jsonResponse(
          _activity(
            discussions: [
              _discussion(
                'thread',
                notes: [_note('shared')],
                notesNext: pendingKind == 'reply',
                notesCursor: pendingKind == 'reply' ? 'notes-1' : null,
              ),
            ],
            next: pendingKind == 'next',
            cursor: pendingKind == 'next' ? 'outer-1' : null,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(_host(api));
      await _tap(tester, find.text('活動'));
      await tester.pump(const Duration(milliseconds: 300));
      if (pendingKind != 'initial') {
        await _tap(
          tester,
          find.text(pendingKind == 'next' ? '載入下一頁' : '載入更多回覆').first,
        );
        await tester.pump();
      }
      await _selectControl(tester, 'work-item-activity-filter', '只看留言');
      expect(find.text('fresh stream'), findsOneWidget);
      pending.complete(
        jsonResponse(
          pendingKind == 'reply'
              ? _notesPage('thread', anchor: 'shared', notes: [_note('late')])
              : _activity(
                  discussions: [
                    _discussion('late', notes: [_note('late')]),
                  ],
                ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('comment-late'), findsNothing);
      expect(find.text('fresh stream'), findsOneWidget);
      expect(find.text('第 2 / 2 頁'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'new selection resets loaded pages and refresh retains selection',
    (tester) async {
      final adapter = FakeAdapter((request) {
        final variables = (request.data as Map)['variables'] as Map;
        final suffix = variables['after'] == null ? 'first' : 'second';
        return jsonResponse(
          _activity(
            discussions: [
              _discussion(suffix, notes: [_note(suffix)]),
            ],
            next: variables['after'] == null,
            cursor: variables['after'] == null ? 'next-1' : null,
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(_host(api));
      await _expand(tester);
      await _tap(tester, find.text('載入下一頁').first);
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 2 頁'), findsWidgets);
      await _selectControl(tester, 'work-item-activity-order', '最新優先');
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 1 頁'), findsWidgets);
      expect(find.textContaining('comment-second'), findsNothing);
      await _tap(
        tester,
        find.byKey(const ValueKey('work-item-activity-refresh')),
      );
      await tester.pumpAndSettle();
      expect(adapter.requests, hasLength(5));
      final variables = (adapter.requests.last.data as Map)['variables'] as Map;
      expect(variables['sort'], 'CREATED_DESC');
      expect(variables['after'], isNull);
      expect(find.textContaining('comment-first'), findsOneWidget);
    },
  );

  testWidgets(
    'unsupported controls show honest legacy options and disable menus',
    (tester) async {
      final adapter = FakeAdapter((request) {
        final query = (request.data as Map)['query'] as String;
        if (query.contains('NotesFilterType')) {
          return jsonResponse({
            'errors': [
              {
                'message':
                    "Field 'discussions' doesn't accept argument 'filter'",
                'extensions': {
                  'code': 'argumentNotAccepted',
                  'name': 'discussions',
                  'typeName': 'Field',
                  'argumentName': 'filter',
                },
              },
            ],
          });
        }
        return jsonResponse(
          _activity(
            discussions: [
              _discussion('legacy', notes: [_note('legacy')]),
            ],
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(_host(api));
      await _expand(tester);
      expect(adapter.requests, hasLength(3));
      expect(find.textContaining('此實例未提供活動篩選或排序'), findsOneWidget);
      final filter = tester.widget<DropdownButton<WorkItemActivityFilter>>(
        find.byKey(const ValueKey('work-item-activity-filter')),
      );
      final order = tester.widget<DropdownButton<WorkItemActivityOrder>>(
        find.byKey(const ValueKey('work-item-activity-order')),
      );
      expect(filter.value, WorkItemActivityFilter.all);
      expect(order.value, WorkItemActivityOrder.oldestFirst);
      expect(filter.onChanged, isNull);
      expect(order.onChanged, isNull);
      expect(find.textContaining('comment-legacy'), findsOneWidget);
    },
  );

  testWidgets('320dp twice-text controls and every menu item remain usable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    final api = testApi(FakeAdapter((_) => jsonResponse(_activity())));
    addTearDown(api.close);
    await tester.pumpWidget(_host(api, textScale: 2));
    await _expand(tester);
    for (final entry in [
      ('work-item-activity-filter', '只看留言'),
      ('work-item-activity-filter', '只看歷史'),
      ('work-item-activity-filter', '全部活動'),
      ('work-item-activity-order', '最新優先'),
      ('work-item-activity-order', '最舊優先'),
    ]) {
      final control = find.byKey(ValueKey(entry.$1));
      expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
      await _selectControl(tester, entry.$1, entry.$2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('activity stays network-idle while collapsed', (tester) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse(_activity(discussions: const [])),
    );
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('work-item-activity')), findsOneWidget);
    expect(adapter.requests, isEmpty);
    expect(find.text('尚無活動'), findsNothing);
  });

  testWidgets(
    'verified top-level comment refreshes the feed and keeps Markdown preview',
    (tester) async {
      var activityReads = 0;
      var mutations = 0;
      const submitted = '**new comment**';
      final created = _createdNote('502', submitted);
      final adapter = FakeAdapter((request) {
        final data = request.data as Map;
        final query = data['query'] as String;
        if (query.contains('MobileWorkItemActivityWriteAccess')) {
          return jsonResponse(_activity());
        }
        if (query.contains('MobileCreateWorkItemActivityNote')) {
          mutations++;
          final input = ((data['variables'] as Map)['input'] as Map);
          expect(input['body'], submitted);
          expect(input.containsKey('discussionId'), isFalse);
          return jsonResponse(_createdMutation(created));
        }
        if (query.contains('MobileWorkItemActivityNoteReadback')) {
          return jsonResponse(_createdReadback(created));
        }
        if (query.contains('MobileWorkItemActivity(')) {
          activityReads++;
          return jsonResponse(
            _activity(
              discussions: activityReads == 1
                  ? [
                      _discussion('before', notes: [_note('before')]),
                    ]
                  : [
                      _discussion('created', notes: [created]),
                    ],
            ),
          );
        }
        throw StateError('Unexpected activity request: $query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      Route<dynamic>? editorRoute;

      await tester.pumpWidget(
        _host(api, onRoute: (route) => editorRoute = route),
      );
      await _expand(tester);
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('work-item-activity-add-comment')),
          )
          .onPressed!();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(editorRoute, isNotNull);
      expect(editorRoute!.isActive, isTrue);
      expect(editorRoute!.isCurrent, isTrue);

      expect(
        find.byKey(const ValueKey('editor-quick-actions-btn')),
        findsNothing,
      );
      expect(find.byTooltip('提及'), findsOneWidget);
      expect(find.byTooltip('附加圖片'), findsOneWidget);
      expect(find.byTooltip('附加檔案'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('editor-body'), skipOffstage: false),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((widget) => widget.data)
            .whereType<String>()
            .join(' | '),
      );
      await tester.enterText(
        find.byKey(const ValueKey('editor-body'), skipOffstage: false),
        submitted,
      );
      await _tap(tester, find.text('預覽'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('new comment'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('editorSave')));
      await tester.pumpAndSettle();

      expect(mutations, 1);
      expect(
        activityReads,
        2,
        reason:
            '${adapter.requests.map((request) => ((request.data as Map)['query'] as String).split('\n').firstWhere((line) => line.contains('query ') || line.contains('mutation '), orElse: () => 'unknown')).join(' | ')}\n'
            '${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().join(' | ')}',
      );
      expect(find.text('new comment'), findsOneWidget);
      expect(find.textContaining('comment-before'), findsNothing);
      expect(
        find.byKey(const ValueKey('work-item-activity-add-comment')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('group-owned editor keeps Markdown but hides project tools', (
    tester,
  ) async {
    const groupWorkItemId = 'gid://gitlab/WorkItem/701';
    const groupNamespaceId = 'gid://gitlab/Group/9';
    const groupPath = 'team/group';
    final groupSummary = WorkItemGraphSummary(
      id: groupWorkItemId,
      iid: 8,
      title: 'Group work item',
      state: 'OPEN',
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 2),
      project: null,
      namespace: const GraphResourceRef(
        id: groupNamespaceId,
        fullPath: groupPath,
      ),
      type: const WorkItemGraphType(
        id: 'gid://gitlab/WorkItems::Type/group-task',
        name: 'Task',
      ),
    );
    final groupDetail = WorkItemGraphDetail(
      summary: groupSummary,
      description: null,
      widgetsAvailable: true,
      widgetTypes: const {'NOTES'},
      descriptionWidget: null,
      assignees: null,
      labels: null,
      hierarchy: null,
      dates: null,
    );
    final groupResponse = {
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/7'},
        'workItem': {
          'id': groupWorkItemId,
          'iid': '8',
          'project': null,
          'namespace': {'id': groupNamespaceId, 'fullPath': groupPath},
          'userPermissions': {'createNote': true},
          'widgets': [
            {
              'type': 'NOTES',
              'discussionLocked': false,
              'discussions': {
                'nodes': const <Object?>[],
                'pageInfo': _pageInfo(),
              },
            },
          ],
        },
      },
    };
    final api = testApi(FakeAdapter((_) => jsonResponse(groupResponse)));
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkItemActivityPanel(
            account: _account(api),
            api: api,
            detail: groupDetail,
            project: null,
          ),
        ),
      ),
    );
    await _expand(tester);
    tester
        .widget<FilledButton>(
          find.byKey(const ValueKey('work-item-activity-add-comment')),
        )
        .onPressed!();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.byTooltip('粗體'), findsOneWidget);
    expect(find.byTooltip('提及'), findsNothing);
    expect(find.byTooltip('附加圖片'), findsNothing);
    expect(find.byTooltip('附加檔案'), findsNothing);
    expect(
      find.byKey(const ValueKey('editor-quick-actions-btn')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'verified discussion reply uses its opaque target and refreshes',
    (tester) async {
      const discussionId = 'gid://gitlab/Discussion/thread';
      const replyId = 'gid://gitlab/Discussion/thread-reply';
      const anchorId = 'gid://gitlab/Note/501';
      const submitted = 'reply from native';
      final created = _createdNote(
        '503',
        submitted,
        discussionId: discussionId,
        replyId: replyId,
        discussionCreatedAt: '2026-10-01T01:00:00Z',
      );
      var activityReads = 0;
      var mutations = 0;
      final adapter = FakeAdapter((request) {
        final data = request.data as Map;
        final query = data['query'] as String;
        if (query.contains('MobileWorkItemActivityReplyPreflight')) {
          return jsonResponse(
            _replyPreflight(
              anchorNoteId: anchorId,
              discussionId: discussionId,
              replyId: replyId,
            ),
          );
        }
        if (query.contains('MobileWorkItemActivityWriteAccess')) {
          return jsonResponse(_activity());
        }
        if (query.contains('MobileCreateWorkItemActivityNote')) {
          mutations++;
          final input = ((data['variables'] as Map)['input'] as Map);
          expect(input['body'], submitted);
          expect(input['discussionId'], replyId);
          return jsonResponse(_createdMutation(created));
        }
        if (query.contains('MobileWorkItemActivityNoteReadback')) {
          return jsonResponse(_createdReadback(created));
        }
        if (query.contains('MobileWorkItemActivity(')) {
          activityReads++;
          return jsonResponse(
            _activity(
              discussions: [
                _discussion(
                  'thread',
                  replyId: replyId,
                  notes: activityReads == 1
                      ? [_note('501')]
                      : [_note('501'), created],
                ),
              ],
            ),
          );
        }
        throw StateError('Unexpected activity request: $query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(api));
      await _expand(tester);
      final reply = find.byKey(
        const ValueKey('work-item-activity-reply:$discussionId'),
      );
      expect(reply, findsOneWidget);
      tester.widget<OutlinedButton>(reply).onPressed!();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('editor-body')),
        submitted,
      );
      await _tap(tester, find.byKey(const Key('editorSave')));
      await tester.pumpAndSettle();

      expect(mutations, 1);
      expect(
        activityReads,
        2,
        reason: adapter.requests
            .map(
              (request) => ((request.data as Map)['query'] as String)
                  .split('\n')
                  .firstWhere(
                    (line) =>
                        line.contains('query ') || line.contains('mutation '),
                    orElse: () => 'unknown',
                  ),
            )
            .join(' | '),
      );
      await _tap(tester, find.text('顯示其餘 1 則留言'));
      await tester.pump();
      expect(find.text(submitted), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read-only permission keeps activity visible without composer', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      if (_isWriteAccessRequest(request)) {
        return jsonResponse(_activity(canCreateNote: false));
      }
      return jsonResponse(
        _activity(
          discussions: [
            _discussion('readable', notes: [_note('readable')]),
          ],
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);

    expect(find.textContaining('comment-readable'), findsOneWidget);
    expect(find.textContaining('沒有新增留言的權限'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('work-item-activity-add-comment')),
      findsNothing,
    );
  });

  testWidgets('unsupported writer leaves the activity reader available', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      if (_isWriteAccessRequest(request)) {
        return jsonResponse({
          'errors': [
            {
              'message': 'private schema detail',
              'extensions': {'code': 'undefinedField'},
            },
          ],
        });
      }
      return jsonResponse(
        _activity(
          discussions: [
            _discussion('unsupported-writer', notes: [_note('604')]),
          ],
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);

    expect(find.textContaining('comment-604'), findsOneWidget);
    expect(find.textContaining('暫不支援新增留言'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('work-item-activity-add-comment')),
      findsNothing,
    );
    expect(find.text('重試留言權限'), findsNothing);
  });

  testWidgets(
    'locked discussion stays readable and suppresses all composition',
    (tester) async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(
          _activity(
            discussionLocked: true,
            discussions: [
              _discussion(
                'locked',
                replyId: 'gid://gitlab/Discussion/locked-reply',
                notes: [_note('601')],
              ),
            ],
          ),
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(api));
      await _expand(tester);

      expect(find.textContaining('comment-601'), findsOneWidget);
      expect(find.textContaining('討論已鎖定'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-activity-add-comment')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey(
            'work-item-activity-reply:gid://gitlab/Discussion/locked',
          ),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('late write access cannot escape owner invalidation', (
    tester,
  ) async {
    final pendingAccess = Completer<ResponseBody>();
    final adapter = FakeAdapter((request) {
      if (_isWriteAccessRequest(request)) return pendingAccess.future;
      return jsonResponse(
        _activity(
          discussions: [
            _discussion('before-owner-change', notes: [_note('602')]),
          ],
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final owner = ChangeNotifier();
    addTearDown(owner.dispose);
    var current = true;

    await tester.pumpWidget(
      _host(api, isCurrent: () => current, ownerChanges: owner),
    );
    await _tap(tester, find.text('活動'));
    for (
      var attempt = 0;
      attempt < 10 && find.textContaining('comment-602').evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('comment-602'), findsOneWidget);

    current = false;
    owner.notifyListeners();
    pendingAccess.complete(jsonResponse(_activity()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('work-item-activity-add-comment')),
      findsNothing,
    );
    expect(find.textContaining('comment-602'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history mode requires an explicit switch before composing', (
    tester,
  ) async {
    final filters = <String>[];
    final adapter = FakeAdapter((request) {
      if (_isWriteAccessRequest(request)) return jsonResponse(_activity());
      final variables = (request.data as Map)['variables'] as Map;
      filters.add('${variables['filter']}');
      return jsonResponse(_activity());
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);
    await _selectControl(tester, 'work-item-activity-filter', '只看歷史');
    expect(
      find.byKey(const ValueKey('work-item-activity-switch-to-comments')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('work-item-activity-add-comment')),
      findsNothing,
    );

    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-switch-to-comments')),
    );
    await tester.pumpAndSettle();

    expect(
      filters,
      containsAllInOrder(['ALL_NOTES', 'ONLY_ACTIVITY', 'ONLY_COMMENTS']),
    );
    expect(
      find.byKey(const ValueKey('work-item-activity-add-comment')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('editorSave')), findsNothing);
  });

  testWidgets('activity is absent when NOTES was not advertised', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => fail('must remain network-idle'));
    final api = testApi(adapter);
    addTearDown(api.close);
    final withoutNotes = WorkItemGraphDetail(
      summary: _summary,
      description: null,
      widgetsAvailable: true,
      widgetTypes: const {'STATUS'},
      descriptionWidget: null,
      assignees: null,
      labels: null,
      hierarchy: null,
      dates: null,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: WorkItemActivityPanel(
          account: _account(api),
          api: api,
          detail: withoutNotes,
          project: _project,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('work-item-activity')), findsNothing);
    expect(adapter.requests, isEmpty);
  });

  testWidgets('outer page retry keeps completed pages cached', (tester) async {
    var secondAttempts = 0;
    final adapter = FakeAdapter((request) {
      final variables = (request.data as Map)['variables'] as Map;
      if (variables['after'] == null) {
        return jsonResponse(
          _activity(
            discussions: [
              _discussion('one', notes: [_note('one')]),
            ],
            next: true,
            cursor: 'outer-two',
          ),
        );
      }
      secondAttempts++;
      if (secondAttempts == 1) {
        return jsonResponse({
          'data': {
            'workItem': {'broken': true},
          },
        });
      }
      return jsonResponse(
        _activity(
          discussions: [
            _discussion('two', notes: [_note('two')]),
          ],
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);
    expect(find.textContaining('comment-one'), findsOneWidget);

    await _tap(tester, find.text('載入下一頁').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(adapter.requests, hasLength(3));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('無法讀取回應'), findsOneWidget);

    await _tap(tester, find.text('重試'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('comment-two'), findsOneWidget);
    expect(find.text('第 2 / 2 頁'), findsWidgets);

    await _tap(tester, find.text('上一頁').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('comment-one'), findsOneWidget);
    expect(adapter.requests, hasLength(4));
  });

  testWidgets('empty outer page can advance and remains cached', (
    tester,
  ) async {
    var calls = 0;
    final adapter = FakeAdapter((request) {
      if (_isWriteAccessRequest(request)) {
        return jsonResponse(_activity());
      }
      calls++;
      final variables = (request.data as Map)['variables'] as Map;
      if (variables['after'] == null) {
        return jsonResponse(_activity(next: true, cursor: 'after-empty'));
      }
      return jsonResponse(
        _activity(
          discussions: [
            _discussion('after-empty', notes: [_note('after-empty')]),
          ],
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);
    expect(find.text('尚無活動'), findsOneWidget);
    expect(find.text('載入下一頁'), findsOneWidget);

    await _tap(tester, find.text('載入下一頁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('comment-after-empty'), findsOneWidget);

    await _tap(tester, find.text('上一頁').first);
    await tester.pump();
    expect(find.text('尚無活動'), findsOneWidget);
    expect(find.text('下一頁'), findsOneWidget);
    await _tap(tester, find.text('下一頁'));
    await tester.pump();
    expect(find.textContaining('comment-after-empty'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('nested notes preserve system events and isolate retry', (
    tester,
  ) async {
    var nestedAttempts = 0;
    final adapter = FakeAdapter((request) {
      final query = ((request.data as Map)['query'] as String);
      if (query.contains('MobileWorkItemActivity')) {
        return jsonResponse(
          _activity(
            discussions: [
              _discussion(
                'thread',
                notes: [_note('system', system: true), _note('first')],
                notesNext: true,
                notesCursor: 'notes-two',
              ),
            ],
          ),
        );
      }
      nestedAttempts++;
      if (nestedAttempts == 1) {
        return jsonResponse({
          'data': {
            'workItem': {'broken': true},
            'anchor': null,
          },
        });
      }
      return jsonResponse(
        _notesPage(
          'thread',
          anchor: 'first',
          notes: [_note('second', author: null)],
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);
    expect(find.textContaining('system-system'), findsOneWidget);
    expect(find.byType(MarkdownView), findsOneWidget);

    await _tap(tester, find.text('載入更多回覆'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.textContaining('system-system'), findsOneWidget);

    await _tap(tester, find.text('重試'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('system-system'), findsOneWidget);
    expect(find.text('顯示其餘 1 則留言'), findsOneWidget);
    await _tap(tester, find.text('顯示其餘 1 則留言'));
    await tester.pumpAndSettle();
    expect(find.text('作者資料不可用'), findsOneWidget);
    expect(find.byType(MarkdownView), findsNWidgets(2));
  });

  testWidgets('unavailable nested page keeps already loaded activity', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final query = ((request.data as Map)['query'] as String);
      if (query.contains('MobileWorkItemActivity')) {
        return jsonResponse(
          _activity(
            discussions: [
              _discussion(
                'unavailable-thread',
                notes: [_note('kept')],
                notesNext: true,
                notesCursor: 'notes-next',
              ),
            ],
          ),
        );
      }
      return jsonResponse({
        'data': {
          'workItem': _identity(),
          'anchor': {
            'id': 'gid://gitlab/Note/kept',
            'project': {'id': _projectId, 'fullPath': _path},
            'discussion': {
              ..._discussion('unavailable-thread'),
              'notes': {'nodes': null, 'pageInfo': _pageInfo()},
            },
          },
        },
      });
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);
    await _tap(tester, find.text('載入更多回覆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('comment-kept'), findsOneWidget);
    expect(find.textContaining('已載入的活動仍保留'), findsOneWidget);
  });

  testWidgets('availability states remain explicit', (tester) async {
    final responses = <Object?>[
      _activity(widgetsUnavailable: true),
      _activity(
        widgets: const [
          {'type': 'NOTES', 'discussionLocked': false, 'discussions': null},
        ],
      ),
      _activity(discussions: const []),
    ];
    var call = 0;
    final api = testApi(
      FakeAdapter(
        (request) => jsonResponse(
          _isWriteAccessRequest(request) ? _activity() : responses[call++],
        ),
      ),
    );
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);
    expect(find.textContaining('未回傳 widgets'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host(api));
    await _expand(tester);
    expect(find.text('伺服器未回傳活動清單。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host(api));
    await _expand(tester);
    expect(find.text('尚無活動'), findsOneWidget);
  });

  testWidgets('owner generation change clears and rejects a late response', (
    tester,
  ) async {
    final response = Completer<ResponseBody>();
    final api = testApi(FakeAdapter((_) => response.future));
    addTearDown(api.close);
    var current = true;
    final owner = ChangeNotifier();
    addTearDown(owner.dispose);

    await tester.pumpWidget(
      _host(api, isCurrent: () => current, ownerChanges: owner),
    );
    await _tap(tester, find.text('活動'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));

    current = false;
    owner.notifyListeners();
    response.complete(
      jsonResponse(
        _activity(
          discussions: [
            _discussion('late', notes: [_note('late')]),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('comment-late'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('API replacement clears stale work and requires a fresh expand', (
    tester,
  ) async {
    final oldResponse = Completer<ResponseBody>();
    final oldApi = testApi(FakeAdapter((_) => oldResponse.future));
    final newAdapter = FakeAdapter(
      (_) => jsonResponse(
        _activity(
          discussions: [
            _discussion('fresh', notes: [_note('fresh')]),
          ],
        ),
      ),
    );
    final newApi = testApi(newAdapter);
    addTearDown(oldApi.close);
    addTearDown(newApi.close);

    await tester.pumpWidget(_host(oldApi));
    await _tap(tester, find.text('活動'));
    await tester.pump();

    await tester.pumpWidget(_host(newApi));
    await tester.pump();
    expect(newAdapter.requests, isEmpty);
    expect(find.textContaining('comment-fresh'), findsNothing);

    await _expand(tester);
    expect(find.textContaining('comment-fresh'), findsOneWidget);
    oldResponse.complete(
      jsonResponse(
        _activity(
          discussions: [
            _discussion('stale', notes: [_note('stale')]),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('comment-fresh'), findsOneWidget);
    expect(find.textContaining('comment-stale'), findsNothing);
  });

  testWidgets('outer and nested caches stop at their five-page caps', (
    tester,
  ) async {
    var outerPage = 0;
    var notePage = 0;
    final adapter = FakeAdapter((request) {
      if (_isWriteAccessRequest(request)) {
        return jsonResponse(_activity());
      }
      final body = request.data as Map;
      final query = body['query'] as String;
      if (query.contains('MobileWorkItemDiscussionNotes')) {
        notePage++;
        final variables = body['variables'] as Map;
        final anchor = (variables['anchorNoteId'] as String).split('/').last;
        return jsonResponse(
          _notesPage(
            'capped-thread',
            anchor: anchor,
            notes: [_note('nested-$notePage')],
            next: true,
            cursor: 'notes-${notePage + 1}',
          ),
        );
      }
      outerPage++;
      return jsonResponse(
        _activity(
          discussions: [
            _discussion(
              outerPage == 1 ? 'capped-thread' : 'outer-$outerPage',
              notes: [_note(outerPage == 1 ? 'initial' : 'outer-$outerPage')],
              notesNext: outerPage == 1,
              notesCursor: outerPage == 1 ? 'notes-1' : null,
            ),
          ],
          next: true,
          cursor: 'outer-${outerPage + 1}',
        ),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api));
    await _expand(tester);

    for (var page = 1; page < 5; page++) {
      await _tap(tester, find.text('載入更多回覆'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('最多保留 5 頁回覆'), findsOneWidget);
    expect(notePage, 4);

    for (var page = 1; page < 5; page++) {
      await _tap(tester, find.text('載入下一頁').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('最多保留 5 頁活動'), findsWidgets);
    expect(outerPage, 5);
  });

  testWidgets(
    'global body budget rejects an excess page, preserves cache, and resets',
    (tester) async {
      final largeBody = List.filled(700000, 'x').join();
      var page = 0;
      final oldAdapter = FakeAdapter((request) {
        if (_isWriteAccessRequest(request)) {
          return jsonResponse(_activity());
        }
        page++;
        return jsonResponse(
          _activity(
            discussions: [
              _discussion(
                'large-$page-a',
                notes: [_note('large-$page-a', body: largeBody)],
              ),
              _discussion(
                'large-$page-b',
                notes: [_note('large-$page-b', body: largeBody)],
              ),
              _discussion(
                'marker-$page',
                notes: [_note('marker-$page', body: '**page-$page-marker**')],
              ),
            ],
            next: true,
            cursor: 'large-cursor-${page + 1}',
          ),
        );
      });
      final oldApi = testApi(oldAdapter);
      addTearDown(oldApi.close);

      await tester.pumpWidget(_host(oldApi));
      await _expand(tester);
      expect(find.textContaining('page-1-marker'), findsOneWidget);

      await _tap(tester, find.text('載入下一頁').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('page-2-marker'), findsOneWidget);

      await _tap(tester, find.text('載入下一頁').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('活動快取上限'), findsOneWidget);
      expect(find.textContaining('page-3-marker'), findsNothing);
      expect(find.text('第 2 / 2 頁'), findsWidgets);
      expect(find.text('載入下一頁'), findsNothing);

      await _tap(tester, find.text('上一頁').first);
      await tester.pump();
      expect(find.textContaining('page-1-marker'), findsOneWidget);
      await _tap(tester, find.text('下一頁').first);
      await tester.pump();
      expect(find.textContaining('page-2-marker'), findsOneWidget);

      final newAdapter = FakeAdapter(
        (_) => jsonResponse(
          _activity(
            discussions: [
              _discussion('fresh-budget', notes: [_note('fresh-budget')]),
            ],
          ),
        ),
      );
      final newApi = testApi(newAdapter);
      addTearDown(newApi.close);
      await tester.pumpWidget(_host(newApi));
      await tester.pump();
      expect(find.textContaining('活動快取上限'), findsNothing);
      expect(newAdapter.requests, isEmpty);

      await _expand(tester);
      expect(find.textContaining('comment-fresh-budget'), findsOneWidget);
      expect(newAdapter.requests, hasLength(2));
    },
  );

  testWidgets('reply Markdown is bounded and large text does not overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 840);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final discussions = [
      for (var discussion = 0; discussion < 6; discussion++)
        _discussion(
          'many-$discussion',
          notes: [
            for (var note = 0; note < 20; note++)
              _note('many-$discussion-$note'),
          ],
        ),
    ];
    final api = testApi(
      FakeAdapter((_) => jsonResponse(_activity(discussions: discussions))),
    );
    addTearDown(api.close);

    await tester.pumpWidget(_host(api, textScale: 2));
    await _expand(tester);
    expect(find.byType(MarkdownView), findsNWidgets(6));

    for (var index = 0; index < 6; index++) {
      final button = find.text('顯示其餘 19 則留言').first;
      await tester.ensureVisible(button);
      await _tap(tester, button);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownView), findsNWidgets(100));
    expect(find.textContaining('最多排版 100 則活動內容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
