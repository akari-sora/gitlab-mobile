import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/board_queries.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/boards_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = Project(
  id: 42,
  name: 'Mobile',
  path: 'studio/mobile',
  visibility: 'private',
  defaultBranch: 'main',
);

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
  token: 'synthetic-test-token',
);

Map<String, Object?> _issue(
  int iid,
  String title, {
  String state = 'opened',
  bool inBug = true,
}) => {
  'id': 1000 + iid,
  'iid': iid,
  'project_id': 42,
  'title': title,
  'description': 'Synthetic board issue.',
  'state': state,
  'labels': [
    {'name': 'team', 'color': '#336699'},
    if (inBug) {'name': 'bug', 'color': '#d9534f'},
  ],
  'author': {'id': 7, 'username': 'developer'},
  'assignees': [
    {'id': 7, 'username': 'developer', 'name': 'Developer'},
  ],
  'milestone': {'id': 100, 'title': 'Sprint'},
  'weight': 3,
  'created_at': '2026-10-01T00:00:00Z',
  'updated_at': '2026-10-02T00:00:00Z',
};

Map<String, Object?> get _board => {
  'id': 1,
  'name': 'Delivery',
  'hide_backlog_list': false,
  'hide_closed_list': false,
  'labels': [
    {'name': 'team'},
  ],
  'assignee': {'id': 7, 'username': 'developer'},
  'milestone': {'id': 100, 'title': 'Sprint'},
  'weight': 3,
};

List<Map<String, Object?>> get _lists => [
  {
    'id': 11,
    'position': 1,
    'label': {'name': 'bug', 'color': '#d9534f'},
  },
  {
    'id': 12,
    'position': 2,
    'assignee': {'id': 7, 'username': 'developer', 'name': 'Developer'},
  },
  {
    'id': 13,
    'position': 3,
    'milestone': {'id': 100, 'title': 'Sprint'},
  },
  {
    'id': 14,
    'position': 4,
    'iteration': {'id': 5, 'title': 'Iteration 5'},
  },
];

List<Map<String, Object?>> get _supportedLists => _lists.take(1).toList();

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  builder: (context, value) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: value!,
  ),
  home: child,
);

class _BoardOwnerHarness extends StatefulWidget {
  const _BoardOwnerHarness({
    super.key,
    required this.first,
    required this.next,
  });

  final GitLabApi first;
  final GitLabApi next;

  @override
  State<_BoardOwnerHarness> createState() => _BoardOwnerHarnessState();
}

class _BoardOwnerHarnessState extends State<_BoardOwnerHarness> {
  late GitLabApi api = widget.first;

  void switchOwner() => setState(() => api = widget.next);

  @override
  Widget build(BuildContext context) =>
      BoardsPage(account: _account(api), api: api, project: _project);
}

void main() {
  test(
    'board queries retain board scope and add the server-side list filter',
    () {
      final board = BoardDefinition.fromJson(
        Map<String, dynamic>.from(_board),
        _lists.map(Map<String, dynamic>.from).toList(),
      );

      expect(board.columns.map((column) => column.title), [
        'Open',
        'bug',
        'Developer',
        'Sprint',
        'Iteration',
        'Closed',
      ]);
      final labelQuery = boardIssueQuery(
        board,
        board.columns[1],
        search: ' crash ',
      );
      expect(labelQuery.supported, isTrue);
      expect(labelQuery.parameters, containsPair('labels', 'team,bug'));
      expect(labelQuery.parameters, containsPair('assignee_id', '7'));
      expect(labelQuery.parameters, containsPair('milestone', 'Sprint'));
      expect(labelQuery.parameters, isNot(contains('milestone_id')));
      expect(labelQuery.parameters, containsPair('weight', '3'));
      expect(labelQuery.parameters, containsPair('search', 'crash'));
      expect(
        boardIssueQuery(board, board.columns[3]).parameters,
        containsPair('milestone', 'Sprint'),
      );
      expect(boardIssueQuery(board, board.columns[4]).supported, isFalse);
      final supportedBoard = BoardDefinition.fromJson(
        Map<String, dynamic>.from(_board),
        _supportedLists.map(Map<String, dynamic>.from).toList(),
      );
      expect(
        boardOpenIssueMatches(
          supportedBoard,
          Map<String, dynamic>.from(_issue(1, 'Already in bug')),
        ),
        isFalse,
      );
      final open = supportedBoard.columns.first;
      final openQuery = boardIssueQuery(supportedBoard, open);
      expect(
        boardColumnIssueMatches(
          supportedBoard,
          open,
          openQuery,
          Map<String, dynamic>.from(_issue(2, 'Still open', inBug: false)),
        ),
        isTrue,
      );
      expect(
        boardColumnIssueMatches(
          supportedBoard,
          open,
          openQuery,
          Map<String, dynamic>.from(_issue(2, 'Moved to bug')),
        ),
        isFalse,
      );
      expect(
        boardIssueQuery(board, board.columns.last).parameters['state'],
        'closed',
      );
    },
  );

  test(
    'scope variants are preserved and malformed scope blocks issue reads',
    () {
      final serialized = BoardDefinition.fromJson({
        'id': 2,
        'name': 'Serialized scope',
        'labels': 'team,bug',
        'assignee_id': 7,
        'milestone': 'Sprint',
        'weight': 3,
      }, const []);
      final query = boardIssueQuery(serialized, serialized.columns.first);
      expect(query.supported, isTrue);
      expect(query.parameters, containsPair('labels', 'team,bug'));
      expect(query.parameters, containsPair('assignee_id', '7'));
      expect(query.parameters, containsPair('milestone', 'Sprint'));

      final malformed = BoardDefinition.fromJson({
        'id': 3,
        'name': 'Malformed scope',
        'labels': {'name': 'must-not-be-ignored'},
      }, const []);
      final blocked = boardIssueQuery(malformed, malformed.columns.first);
      expect(blocked.supported, isFalse);
      expect(blocked.reason, contains('標籤篩選格式'));
    },
  );

  testWidgets(
    'board loads columns, submits search, paginates and opens issue actions',
    (tester) async {
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/boards')) return jsonResponse([_board]);
        if (path.endsWith('/projects/42/boards/1/lists')) {
          return jsonResponse(_supportedLists);
        }
        if (path.endsWith('/projects/42/boards/1')) return jsonResponse(_board);
        if (path.endsWith('/projects/42/issues/1')) {
          return jsonResponse(_issue(1, 'First issue', inBug: false));
        }
        if (path.endsWith('/projects/42/issues')) {
          final page = request.uri.queryParameters['page'];
          if (page == '2') {
            return jsonResponse([_issue(2, 'Second issue', inBug: false)]);
          }
          return jsonResponse(
            [_issue(1, 'First issue', inBug: false)],
            headers: {
              'x-next-page': ['2'],
            },
          );
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        _host(BoardsPage(account: _account(api), api: api, project: _project)),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('Delivery'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('First issue'), findsOneWidget);
      final initial = adapter.requests.lastWhere(
        (request) => request.uri.path.endsWith('/issues'),
      );
      expect(initial.uri.queryParameters, containsPair('labels', 'team'));
      expect(initial.uri.queryParameters, containsPair('assignee_id', '7'));
      expect(initial.uri.queryParameters, containsPair('milestone', 'Sprint'));
      expect(initial.uri.queryParameters, isNot(contains('milestone_id')));

      await tester.enterText(find.byType(TextField), 'crash');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settleNetworkWidgets(tester);
      final searched = adapter.requests.lastWhere(
        (request) => request.uri.path.endsWith('/issues'),
      );
      expect(searched.uri.queryParameters['search'], 'crash');

      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);
      expect(find.text('Second issue'), findsOneWidget);
      expect(
        adapter.requests.any(
          (request) => request.uri.queryParameters['page'] == '2',
        ),
        isTrue,
      );

      await tester.ensureVisible(find.text('First issue'));
      await tester.tap(find.text('First issue'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkItemPage), findsOneWidget);
    },
  );

  testWidgets(
    'unsupported list is explicit and never falls back to all issues',
    (tester) async {
      var issueReads = 0;
      final unsupportedBoard = {
        'id': 1,
        'name': 'Iteration planning',
        'hide_backlog_list': true,
        'hide_closed_list': true,
      };
      final unsupportedLists = [_lists.last];
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/boards')) {
          return jsonResponse([unsupportedBoard]);
        }
        if (path.endsWith('/projects/42/boards/1/lists')) {
          return jsonResponse(unsupportedLists);
        }
        if (path.endsWith('/projects/42/boards/1')) {
          return jsonResponse(unsupportedBoard);
        }
        if (path.endsWith('/projects/42/issues')) {
          issueReads++;
          return jsonResponse([]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        _host(BoardsPage(account: _account(api), api: api, project: _project)),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('無法載入「Iteration」'), findsOneWidget);
      expect(find.textContaining('未載入任何替代議題'), findsOneWidget);
      expect(issueReads, 0);
    },
  );

  testWidgets('ambiguous board 404 identifies account, instance and resource', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({'message': 'not found'}, status: 404),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      _host(BoardsPage(account: _account(api), api: api, project: _project)),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('App 帳號：@developer'), findsOneWidget);
    expect(find.text('實例：https://example.com/gitlab'), findsOneWidget);
    expect(find.text('目標：studio/mobile · 議題看板'), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
  });

  testWidgets(
    'definition pagination limit fails explicitly before loading issues',
    (tester) async {
      var issueReads = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects/42/boards')) {
          final page =
              int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 1;
          return jsonResponse(
            [
              {..._board, 'id': page, 'name': 'Board $page'},
            ],
            headers: {
              'x-next-page': ['${page + 1}'],
            },
          );
        }
        if (request.uri.path.endsWith('/projects/42/issues')) issueReads++;
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        _host(BoardsPage(account: _account(api), api: api, project: _project)),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('看板定義超過載入上限'), findsOneWidget);
      expect(find.textContaining('未顯示不完整的看板'), findsOneWidget);
      expect(issueReads, 0);
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/boards'),
        ),
        hasLength(4),
      );
    },
  );

  testWidgets('definition cursor loop fails explicitly before loading issues', (
    tester,
  ) async {
    var issueReads = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/projects/42/boards')) {
        return jsonResponse(
          [_board],
          headers: {
            'x-next-page': ['2'],
          },
        );
      }
      if (request.uri.path.endsWith('/projects/42/issues')) issueReads++;
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      _host(BoardsPage(account: _account(api), api: api, project: _project)),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('無法讀取回應'), findsOneWidget);
    expect(issueReads, 0);
    expect(
      adapter.requests.where((request) => request.uri.path.endsWith('/boards')),
      hasLength(2),
    );
  });

  testWidgets(
    'replacing the API reloads the same account and project generation',
    (tester) async {
      FakeAdapter adapterFor(String boardName) => FakeAdapter((request) {
        final path = request.uri.path;
        final board = {..._board, 'name': boardName};
        if (path.endsWith('/projects/42/boards')) return jsonResponse([board]);
        if (path.endsWith('/projects/42/boards/1/lists')) {
          return jsonResponse([]);
        }
        if (path.endsWith('/projects/42/boards/1')) return jsonResponse(board);
        if (path.endsWith('/projects/42/issues')) return jsonResponse([]);
        return jsonResponse([]);
      });

      final firstAdapter = adapterFor('First generation');
      final firstApi = testApi(firstAdapter);
      final secondAdapter = adapterFor('Second generation');
      final secondApi = testApi(secondAdapter);
      addTearDown(firstApi.close);
      addTearDown(secondApi.close);
      await tester.pumpWidget(
        _host(
          BoardsPage(
            account: _account(firstApi),
            api: firstApi,
            project: _project,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('First generation'), findsOneWidget);

      await tester.pumpWidget(
        _host(
          BoardsPage(
            account: _account(secondApi),
            api: secondApi,
            project: _project,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('Second generation'), findsOneWidget);
      expect(secondAdapter.requests, isNotEmpty);
    },
  );

  testWidgets(
    'issue mutations refresh every mounted column and delete removes sibling cards',
    (tester) async {
      final board = {
        'id': 1,
        'name': 'Labels',
        'hide_backlog_list': false,
        'hide_closed_list': true,
      };
      final lists = [
        {
          'id': 11,
          'position': 1,
          'label': {'name': 'a', 'color': '#336699'},
        },
        {
          'id': 12,
          'position': 2,
          'label': {'name': 'b', 'color': '#d9534f'},
        },
      ];
      var deleted = false;
      var revision = 1;
      final issue = <String, Object?>{
        ..._issue(1, 'Moves across columns', inBug: false),
        'labels': <Object?>[],
        'updated_at': 'revision-$revision',
      };

      List<String> issueLabels() => (issue['labels']! as List<Object?>)
          .map((value) => (value! as Map<String, Object?>)['name']! as String)
          .toList();

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/boards')) {
          return jsonResponse([board]);
        }
        if (path.endsWith('/projects/42/boards/1/lists')) {
          return jsonResponse(lists);
        }
        if (path.endsWith('/projects/42/boards/1')) {
          return jsonResponse(board);
        }
        if (path.endsWith('/projects/42/labels')) {
          return jsonResponse([
            {'id': 21, 'name': 'a', 'color': '#336699'},
            {'id': 22, 'name': 'b', 'color': '#d9534f'},
          ]);
        }
        if (path.endsWith('/projects/42/issues/1')) {
          if (request.method == 'DELETE') {
            deleted = true;
            return jsonResponse({});
          }
          if (request.method == 'PUT') {
            final body = request.data! as Map<String, Object?>;
            final labels = (body['labels']! as String)
                .split(',')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toList();
            revision++;
            issue['labels'] = [
              for (final label in labels)
                {'name': label, 'color': label == 'a' ? '#336699' : '#d9534f'},
            ];
            issue['updated_at'] = 'revision-$revision';
          }
          return jsonResponse(issue);
        }
        if (path.endsWith('/projects/42/issues')) {
          if (deleted) return jsonResponse([]);
          final labels = request.uri.queryParameters['labels'];
          if (labels != null &&
              !labels
                  .split(',')
                  .every((label) => issueLabels().contains(label))) {
            return jsonResponse([]);
          }
          return jsonResponse([issue]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        _host(BoardsPage(account: _account(api), api: api, project: _project)),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('Moves across columns'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('board-column-list-11')));
      await settleNetworkWidgets(tester);
      expect(find.text('Moves across columns'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('board-column-list-12')));
      await settleNetworkWidgets(tester);
      expect(find.text('Moves across columns'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('board-column-open')));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('Moves across columns'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byKey(const ValueKey('quick-add-label')));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byKey(const ValueKey('picker-row-a')));
      await tester.tap(find.byKey(const ValueKey('picker-row-b')));
      await tester.tap(find.byKey(const ValueKey('picker-done')));
      await settleNetworkWidgets(tester);
      await tester.pageBack();
      await settleNetworkWidgets(tester);

      expect(find.text('Moves across columns'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('board-column-list-11')));
      await settleNetworkWidgets(tester);
      expect(find.text('Moves across columns'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('board-column-list-12')));
      await settleNetworkWidgets(tester);
      expect(find.text('Moves across columns'), findsOneWidget);

      await tester.tap(find.text('Moves across columns'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刪除'));
      await tester.pumpAndSettle();
      final confirmation = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '確認名稱',
      );
      expect(confirmation, findsOneWidget);
      await tester.enterText(confirmation, '#1');
      await tester.pump();
      await tester.tap(find.text('確認'));
      await settleNetworkWidgets(tester);

      expect(deleted, isTrue);
      expect(find.byType(WorkItemPage), findsNothing);
      expect(find.text('Moves across columns'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('board-column-list-11')));
      await settleNetworkWidgets(tester);
      expect(find.text('Moves across columns'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('board-column-list-12')));
      await settleNetworkWidgets(tester);
      expect(find.text('Moves across columns'), findsNothing);
    },
  );

  testWidgets(
    'long press moves a card using fresh snapshots and verifies readback',
    (tester) async {
      final board = {
        'id': 1,
        'name': 'Move board',
        'hide_backlog_list': false,
        'hide_closed_list': false,
      };
      final lists = [
        {
          'id': 11,
          'position': 1,
          'label': {'id': 21, 'name': 'doing', 'color': '#336699'},
        },
      ];
      final issue = <String, Object?>{
        ..._issue(1, 'Move me', inBug: false),
        'labels': [
          {'name': 'customer', 'color': '#999999'},
        ],
      };
      Map<String, Object?>? write;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/boards')) return jsonResponse([board]);
        if (path.endsWith('/projects/42/boards/1/lists')) {
          return jsonResponse(lists);
        }
        if (path.endsWith('/projects/42/boards/1')) {
          return jsonResponse(board);
        }
        if (path.endsWith('/projects/42/issues/1')) {
          if (request.method == 'PUT') {
            write = Map<String, Object?>.from(request.data! as Map);
            issue['labels'] = [
              {'name': 'customer', 'color': '#999999'},
              {'name': 'doing', 'color': '#336699'},
            ];
          }
          return jsonResponse(issue);
        }
        if (path.endsWith('/projects/42/issues')) {
          final requested = request.uri.queryParameters['labels'];
          if (requested?.contains('doing') == true && write == null) {
            return jsonResponse([]);
          }
          return jsonResponse([issue]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        _host(BoardsPage(account: _account(api), api: api, project: _project)),
      );
      await settleNetworkWidgets(tester);

      await tester.longPress(find.text('Move me'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('move-issue-to-list-11')));
      await settleNetworkWidgets(tester);

      expect(write, {'labels': 'customer,doing'});
      expect(find.text('已移動到「doing」'), findsOneWidget);
      expect(
        adapter.requests
            .where(
              (request) =>
                  request.uri.path.endsWith('/projects/42/issues/1') &&
                  request.method == 'GET',
            )
            .length,
        greaterThanOrEqualTo(2),
      );
    },
  );

  testWidgets('board manager renames with server readback', (tester) async {
    var name = 'Before';
    Map<String, Object?>? write;
    Map<String, Object?> board() => {
      'id': 1,
      'name': name,
      'hide_backlog_list': false,
      'hide_closed_list': false,
    };
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/projects/42/boards')) {
        return jsonResponse([board()]);
      }
      if (path.endsWith('/projects/42/boards/1/lists')) {
        return jsonResponse([]);
      }
      if (path.endsWith('/projects/42/boards/1')) {
        if (request.method == 'PUT') {
          write = Map<String, Object?>.from(request.data! as Map);
          name = write!['name']! as String;
        }
        return jsonResponse(board());
      }
      if (path.endsWith('/projects/42/issues')) return jsonResponse([]);
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      _host(BoardsPage(account: _account(api), api: api, project: _project)),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.byTooltip('管理看板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理目前看板'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rename-board')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('board-name-field')),
      'After',
    );
    await tester.tap(find.text('儲存'));
    await settleNetworkWidgets(tester);

    expect(write, {'name': 'After'});
    expect(find.text('After'), findsOneWidget);
  });

  testWidgets('API change dismisses board dialogs without writing', (
    tester,
  ) async {
    ResponseBody respond(RequestOptions request) {
      final path = request.uri.path;
      if (path.endsWith('/projects/42/boards')) return jsonResponse([_board]);
      if (path.endsWith('/projects/42/boards/1/lists')) {
        return jsonResponse(_supportedLists);
      }
      if (path.endsWith('/projects/42/boards/1')) return jsonResponse(_board);
      if (path.endsWith('/projects/42/issues')) return jsonResponse([]);
      return jsonResponse([]);
    }

    final firstAdapter = FakeAdapter(respond);
    final nextAdapter = FakeAdapter(respond);
    final first = testApi(firstAdapter);
    final next = testApi(nextAdapter);
    addTearDown(first.close);
    addTearDown(next.close);
    final key = GlobalKey<_BoardOwnerHarnessState>();
    await tester.pumpWidget(
      _host(_BoardOwnerHarness(key: key, first: first, next: next)),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('管理看板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理目前看板'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rename-board')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('board-name-field')),
      'Must not write',
    );

    key.currentState!.switchOwner();
    await tester.pump();
    await settleNetworkWidgets(tester);

    expect(find.byKey(const ValueKey('board-name-field')), findsNothing);
    expect(
      firstAdapter.requests.where((request) => request.method == 'PUT'),
      isEmpty,
    );
    expect(
      nextAdapter.requests.where((request) => request.method == 'PUT'),
      isEmpty,
    );
  });

  for (final width in [320.0, 412.0, 840.0]) {
    testWidgets('board has no overflow at ${width.toInt()}dp and 2x text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(width * 2, 900 * 2);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/boards')) return jsonResponse([_board]);
        if (path.endsWith('/projects/42/boards/1/lists')) {
          return jsonResponse(_supportedLists);
        }
        if (path.endsWith('/projects/42/boards/1')) return jsonResponse(_board);
        if (path.endsWith('/projects/42/issues')) {
          return jsonResponse([
            _issue(1, 'Long issue title remains readable', inBug: false),
          ]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        _host(
          BoardsPage(account: _account(api), api: api, project: _project),
          textScale: 2,
        ),
      );
      await settleNetworkWidgets(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('議題看板'), findsOneWidget);
      expect(find.text('Long issue title remains readable'), findsOneWidget);
    });
  }
}
