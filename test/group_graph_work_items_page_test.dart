import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/groups_page.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _groupId = 'gid://gitlab/Group/9';
const _groupPath = 'team';

Account _account(GitLabApi api, [int user = 7]) => Account(
  instance: api.instance,
  user: GitLabUser(id: user, username: 'user$user', name: 'User $user'),
  token: 'synthetic-test-token',
);

Map<String, Object?> _summary({
  required int iid,
  required String title,
  String? id,
  String path = _groupPath,
  String groupId = _groupId,
}) => {
  'id': id ?? 'gid://gitlab/WorkItem/$iid',
  'iid': '$iid',
  'title': title,
  'state': 'OPEN',
  'createdAt': '2026-09-01T01:02:03Z',
  'updatedAt': '2026-09-02T03:04:05Z',
  'project': null,
  'namespace': {'id': groupId, 'fullPath': path},
  'workItemType': {
    'id': 'gid://gitlab/WorkItems::Type/99',
    'name': 'Epic renamed by server',
  },
  'widgets': const <Object?>[],
};

Map<String, Object?> _connection(List<Object?> nodes, {String? next}) => {
  'nodes': nodes,
  'pageInfo': {'hasNextPage': next != null, 'endCursor': next},
};

ResponseBody _groupList(
  List<Object?> nodes, {
  String path = _groupPath,
  String groupId = _groupId,
  String? next,
}) => jsonResponse({
  'data': {
    'group': {
      'id': groupId,
      'fullPath': path,
      'workItems': _connection(nodes, next: next),
    },
  },
});

ResponseBody _types({
  String path = _groupPath,
  String groupId = _groupId,
  List<Object?>? nodes,
}) => jsonResponse({
  'data': {
    'namespace': {
      'id': groupId,
      'fullPath': path,
      'workItemTypes': _connection(
        nodes ??
            [
              {
                'id': 'gid://gitlab/WorkItems::Type/99',
                'name': 'Epic renamed by server',
                'enabled': true,
                'isGroupWorkItemType': true,
                'widgetDefinitions': [
                  {'type': 'DESCRIPTION'},
                ],
              },
              {
                'id': 'gid://gitlab/WorkItems::Type/100',
                'name': 'Disabled objective',
                'enabled': false,
                'isGroupWorkItemType': true,
                'widgetDefinitions': <Object?>[],
              },
              {
                'id': 'gid://gitlab/WorkItems::Type/101',
                'name': 'Project-only issue',
                'enabled': true,
                'isGroupWorkItemType': false,
                'widgetDefinitions': <Object?>[],
              },
            ],
      ),
    },
  },
});

ResponseBody _detail(int iid, String title) => jsonResponse({
  'data': {
    'namespace': {
      'id': _groupId,
      'fullPath': _groupPath,
      'workItem': {
        ..._summary(iid: iid, title: title),
        'description': 'Group detail from verified namespace',
        'widgets': [
          {
            'type': 'DESCRIPTION',
            'description': 'Group detail from verified namespace',
            'edited': false,
            'lastEditedAt': null,
          },
        ],
      },
    },
  },
});

ResponseBody _state(int iid) => jsonResponse({
  'data': {
    'workItem': {
      'id': 'gid://gitlab/WorkItem/$iid',
      'iid': '$iid',
      'state': 'OPEN',
      'updatedAt': '2026-09-02T03:04:05Z',
      'project': null,
      'namespace': {'id': _groupId, 'fullPath': _groupPath},
      'workItemType': {'id': 'gid://gitlab/WorkItems::Type/99'},
      'userPermissions': {'updateWorkItem': false},
    },
  },
});

Map<String, Object?> _body(RequestOptions request) =>
    Map<String, Object?>.from(request.data as Map);

String _query(RequestOptions request) => _body(request)['query']! as String;

Map<String, Object?> _variables(RequestOptions request) =>
    Map<String, Object?>.from(_body(request)['variables']! as Map);

Widget _host(
  Account account,
  GitLabApi api, {
  String path = _groupPath,
  double scale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: GraphWorkItemsPage.group(
      account: account,
      api: api,
      namespacePath: path,
    ),
  ),
);

void main() {
  testWidgets('group page exposes one embedded Work Items tab', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter((request) {
      if (!request.uri.path.endsWith('/api/graphql')) {
        return jsonResponse(<Object?>[]);
      }
      final query = _query(request);
      if (query.contains('MobileGroupWorkItems')) {
        return _groupList([_summary(iid: 4, title: 'Visible from group')]);
      }
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      throw StateError('Unexpected request ${request.uri.path}');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GroupPage(
          account: _account(api),
          api: api,
          group: const {'id': 9, 'name': 'Team', 'full_path': _groupPath},
          initialTab: 4,
          isCurrent: () => true,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('分享連結'), findsOneWidget);
    expect(find.byTooltip('在 GitLab 開啟'), findsOneWidget);
    expect(find.text('包含子群組與專案'), findsOneWidget);
    expect(find.text('Visible from group'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'group controls send server filters instead of filtering one page',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var serverResult = 0;
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileGroupWorkItems')) {
          serverResult++;
          return _groupList([
            _summary(iid: serverResult, title: 'Server result'),
          ]);
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await settleNetworkWidgets(tester);

      Map<String, Object?> latestVariables() => _variables(
        adapter.requests.lastWhere(
          (request) => _query(request).contains('MobileGroupWorkItems'),
        ),
      );

      expect(latestVariables(), containsPair('includeDescendants', true));
      expect(latestVariables(), containsPair('state', 'opened'));
      expect(latestVariables(), containsPair('search', ''));
      expect(latestVariables(), containsPair('sort', 'CREATED_DESC'));

      await tester.tap(find.text('包含子群組與專案'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '已關閉'));
      await settleNetworkWidgets(tester);
      expect(latestVariables(), containsPair('state', 'closed'));

      await tester.enterText(
        find.byKey(const Key('group-work-item-search')),
        ' roadmap ',
      );
      await tester.tap(find.byTooltip('套用搜尋'));
      await settleNetworkWidgets(tester);
      expect(latestVariables(), containsPair('search', 'roadmap'));

      await tester.tap(find.byKey(const Key('group-work-item-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最近更新').last);
      await settleNetworkWidgets(tester);
      expect(latestVariables(), containsPair('sort', 'UPDATED_DESC'));

      await tester.tap(find.byKey(const Key('group-work-item-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Project-only issue').last);
      await settleNetworkWidgets(tester);
      expect(
        latestVariables(),
        containsPair('typeIds', ['gid://gitlab/WorkItems::Type/101']),
      );

      await tester.tap(find.text('僅此群組'));
      await settleNetworkWidgets(tester);
      expect(latestVariables(), containsPair('includeDescendants', false));
      expect(latestVariables().containsKey('typeIds'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a newer filter suppresses an older in-flight group page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final first = Completer<ResponseBody>();
    var itemRequests = 0;
    Object? latestRequestedState;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileGroupWorkItems')) {
        itemRequests++;
        if (itemRequests == 1) return first.future;
        latestRequestedState = _variables(request)['state'];
        return _groupList([_summary(iid: 2, title: 'Newest closed result')]);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await pumpUntil(
      tester,
      () => itemRequests == 1,
      description: 'first group page request',
    );
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pump(const Duration(milliseconds: 300));
    final closedChip = find.widgetWithText(ChoiceChip, '已關閉');
    tester.widget<ChoiceChip>(closedChip).onSelected!(true);
    await tester.pump();
    await pumpUntil(
      tester,
      () => itemRequests == 2,
      description: 'new filter request',
    );
    await settleNetworkWidgets(tester);
    expect(latestRequestedState, 'closed');

    first.complete(_groupList([_summary(iid: 1, title: 'Stale open result')]));
    await settleNetworkWidgets(tester);

    expect(
      find.text('Newest closed result', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Stale open result', skipOffstage: false), findsNothing);
    expect(itemRequests, 2);
  });

  testWidgets('a path change clears a type bound to the previous group', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      final path = _variables(request)['path']! as String;
      final isOther = path == 'other';
      final groupId = isOther ? 'gid://gitlab/Group/10' : _groupId;
      if (query.contains('MobileNamespaceWorkItemTypes')) {
        return _types(path: path, groupId: groupId);
      }
      if (query.contains('MobileGroupWorkItems')) {
        return _groupList(const [], path: path, groupId: groupId);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-work-item-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Epic renamed by server').last);
    await settleNetworkWidgets(tester);
    expect(
      _variables(
        adapter.requests.lastWhere(
          (request) => _query(request).contains('MobileGroupWorkItems'),
        ),
      ),
      containsPair('typeIds', ['gid://gitlab/WorkItems::Type/99']),
    );

    await tester.pumpWidget(_host(_account(api), api, path: 'other'));
    await settleNetworkWidgets(tester);

    final latest = _variables(
      adapter.requests.lastWhere(
        (request) => _query(request).contains('MobileGroupWorkItems'),
      ),
    );
    expect(latest['path'], 'other');
    expect(latest.containsKey('typeIds'), isFalse);
    expect(latest, containsPair('includeDescendants', true));
    expect(latest, containsPair('state', 'opened'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'early filter change binds pending types to the latest group page',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final initialItems = Completer<ResponseBody>();
      final filteredItems = Completer<ResponseBody>();
      var itemRequests = 0;
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileGroupWorkItems')) {
          itemRequests++;
          return itemRequests == 1 ? initialItems.future : filteredItems.future;
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await pumpUntil(
        tester,
        () => itemRequests == 1,
        description: 'initial item request',
      );
      await tester.tap(find.text('包含子群組與專案'));
      await tester.pump(const Duration(milliseconds: 300));
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '已關閉'))
          .onSelected!(true);
      await pumpUntil(
        tester,
        () => itemRequests == 2,
        description: 'filtered item request',
      );

      initialItems.complete(
        _groupList([_summary(iid: 1, title: 'Superseded initial page')]),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('無法讀取回應', skipOffstage: false), findsNothing);

      filteredItems.complete(
        _groupList([_summary(iid: 2, title: 'Latest filtered page')]),
      );
      await settleNetworkWidgets(tester);

      expect(
        find.text('Latest filtered page', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('Superseded initial page', skipOffstage: false),
        findsNothing,
      );
      expect(
        find.text('Epic renamed by server', skipOffstage: false),
        findsWidgets,
      );
      expect(find.text('無法讀取回應', skipOffstage: false), findsNothing);
    },
  );

  testWidgets('refresh keeps a selected type while responses are pending', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final refreshItems = Completer<ResponseBody>();
    final refreshTypes = Completer<ResponseBody>();
    var itemRequests = 0;
    var typeRequests = 0;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) {
        typeRequests++;
        return typeRequests == 1 ? _types() : refreshTypes.future;
      }
      if (query.contains('MobileGroupWorkItems')) {
        itemRequests++;
        if (itemRequests == 3) return refreshItems.future;
        return _groupList([
          _summary(iid: itemRequests, title: 'Typed item $itemRequests'),
        ]);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-work-item-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Epic renamed by server').last);
    await settleNetworkWidgets(tester);

    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await pumpUntil(
      tester,
      () => itemRequests == 3 && typeRequests == 2,
      description: 'selected type refresh requests',
    );

    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<DropdownButtonFormField<String?>>(
            find.byType(DropdownButtonFormField<String?>),
          )
          .initialValue,
      'gid://gitlab/WorkItems::Type/99',
    );

    refreshItems.complete(
      _groupList([_summary(iid: 3, title: 'Refreshed typed item')]),
    );
    refreshTypes.complete(_types());
    await settleNetworkWidgets(tester);
    await refresh;

    expect(find.text('Refreshed typed item'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final unavailableType in ['removed', 'disabled']) {
    testWidgets(
      '$unavailableType selected type is cleared and refetched on refresh',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 1200);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        var refreshCapabilities = false;
        var itemRequests = 0;
        final adapter = FakeAdapter((request) {
          final query = _query(request);
          if (query.contains('MobileNamespaceWorkItemTypes')) {
            if (!refreshCapabilities) return _types();
            return _types(
              nodes: unavailableType == 'removed'
                  ? const []
                  : [
                      {
                        'id': 'gid://gitlab/WorkItems::Type/99',
                        'name': 'Epic renamed by server',
                        'enabled': false,
                        'isGroupWorkItemType': true,
                        'widgetDefinitions': <Object?>[],
                      },
                    ],
            );
          }
          if (query.contains('MobileGroupWorkItems')) {
            itemRequests++;
            final typed = _variables(request).containsKey('typeIds');
            return _groupList([
              _summary(
                iid: itemRequests,
                title: typed ? 'Typed server row' : 'Unfiltered server row',
              ),
            ]);
          }
          throw StateError('Unexpected query');
        });
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(_host(_account(api), api));
        await settleNetworkWidgets(tester);
        await tester.tap(find.text('包含子群組與專案'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('group-work-item-type')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Epic renamed by server').last);
        await settleNetworkWidgets(tester);

        refreshCapabilities = true;
        final refresh = tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show();
        await settleNetworkWidgets(tester);
        await refresh;

        final latestItems = adapter.requests.lastWhere(
          (request) => _query(request).contains('MobileGroupWorkItems'),
        );
        expect(_variables(latestItems).containsKey('typeIds'), isFalse);
        expect(find.text('Unfiltered server row'), findsOneWidget);
        expect(find.text('Typed server row'), findsNothing);
        expect(find.textContaining('已選類型不再可用，已改為所有類型並重新讀取。'), findsOneWidget);
        expect(itemRequests, 4);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('refresh verifies a selected type on a later capability page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var refreshCapabilities = false;
    var itemRequests = 0;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) {
        if (!refreshCapabilities) return _types();
        final after = _variables(request)['after'];
        return jsonResponse({
          'data': {
            'namespace': {
              'id': _groupId,
              'fullPath': _groupPath,
              'workItemTypes': _connection([
                {
                  'id': after == null
                      ? 'gid://gitlab/WorkItems::Type/101'
                      : 'gid://gitlab/WorkItems::Type/99',
                  'name': after == null
                      ? 'Project-only issue'
                      : 'Epic renamed by server',
                  'enabled': true,
                  'isGroupWorkItemType': after != null,
                  'widgetDefinitions': <Object?>[],
                },
              ], next: after == null ? 'types-2' : null),
            },
          },
        });
      }
      if (query.contains('MobileGroupWorkItems')) {
        itemRequests++;
        return _groupList([
          _summary(iid: itemRequests, title: 'Typed item $itemRequests'),
        ]);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-work-item-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Epic renamed by server').last);
    await settleNetworkWidgets(tester);

    refreshCapabilities = true;
    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await settleNetworkWidgets(tester);
    await refresh;

    final itemVariables = adapter.requests
        .where((request) => _query(request).contains('MobileGroupWorkItems'))
        .map(_variables)
        .toList();
    expect(itemVariables, hasLength(3));
    expect(
      itemVariables.last,
      containsPair('typeIds', ['gid://gitlab/WorkItems::Type/99']),
    );
    expect(find.textContaining('已選類型不再可用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected type stays bound when verification paging fails', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var refreshCapabilities = false;
    var typeRequests = 0;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) {
        typeRequests++;
        if (!refreshCapabilities) return _types();
        if (_variables(request)['after'] != null) {
          return jsonResponse({'message': 'paging failed'}, status: 500);
        }
        return jsonResponse({
          'data': {
            'namespace': {
              'id': _groupId,
              'fullPath': _groupPath,
              'workItemTypes': _connection([
                {
                  'id': 'gid://gitlab/WorkItems::Type/101',
                  'name': 'Project-only issue',
                  'enabled': true,
                  'isGroupWorkItemType': false,
                  'widgetDefinitions': <Object?>[],
                },
              ], next: 'types-2'),
            },
          },
        });
      }
      if (query.contains('MobileGroupWorkItems')) {
        return _groupList([_summary(iid: 1, title: 'Typed row')]);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-work-item-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Epic renamed by server').last);
    await settleNetworkWidgets(tester);

    refreshCapabilities = true;
    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await settleNetworkWidgets(tester);
    await refresh;

    expect(typeRequests, 3);
    expect(find.text('後續類型載入失敗；目前只顯示已取得的資料。'), findsOneWidget);
    expect(find.textContaining('已選類型不再可用'), findsNothing);
    expect(
      _variables(
        adapter.requests.lastWhere(
          (request) => _query(request).contains('MobileGroupWorkItems'),
        ),
      ),
      containsPair('typeIds', ['gid://gitlab/WorkItems::Type/99']),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('late refresh capabilities do not restore an older type filter', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final delayedTypes = Completer<ResponseBody>();
    var refreshCapabilities = false;
    var itemRequests = 0;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) {
        return refreshCapabilities ? delayedTypes.future : _types();
      }
      if (query.contains('MobileGroupWorkItems')) {
        itemRequests++;
        final typed = _variables(request).containsKey('typeIds');
        return _groupList([
          _summary(
            iid: itemRequests,
            title: typed ? 'Typed A row' : 'Current B row',
          ),
        ]);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-work-item-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Epic renamed by server').last);
    await settleNetworkWidgets(tester);

    refreshCapabilities = true;
    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await pumpUntil(
      tester,
      () => itemRequests == 3,
      description: 'typed refresh item request',
    );
    await tester.tap(find.byKey(const Key('group-work-item-type')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('所有類型').last);
    await pumpUntil(
      tester,
      () => itemRequests == 4,
      description: 'new all-types filter request',
    );

    delayedTypes.complete(
      _types(
        nodes: [
          {
            'id': 'gid://gitlab/WorkItems::Type/99',
            'name': 'Epic renamed by server',
            'enabled': false,
            'isGroupWorkItemType': true,
            'widgetDefinitions': <Object?>[],
          },
        ],
      ),
    );
    await settleNetworkWidgets(tester);
    await refresh;

    expect(itemRequests, 4);
    expect(find.text('Current B row'), findsOneWidget);
    expect(find.textContaining('已選類型不再可用'), findsNothing);
    expect(
      _variables(
        adapter.requests.lastWhere(
          (request) => _query(request).contains('MobileGroupWorkItems'),
        ),
      ).containsKey('typeIds'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('late verification page cannot clear a newer selected type', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final pageTwo = Completer<ResponseBody>();
    var refreshCapabilities = false;
    var typeRequests = 0;
    var itemRequests = 0;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) {
        typeRequests++;
        if (!refreshCapabilities) return _types();
        if (_variables(request)['after'] != null) return pageTwo.future;
        return jsonResponse({
          'data': {
            'namespace': {
              'id': _groupId,
              'fullPath': _groupPath,
              'workItemTypes': _connection([
                {
                  'id': 'gid://gitlab/WorkItems::Type/101',
                  'name': 'Project-only issue',
                  'enabled': true,
                  'isGroupWorkItemType': false,
                  'widgetDefinitions': <Object?>[],
                },
              ], next: 'types-2'),
            },
          },
        });
      }
      if (query.contains('MobileGroupWorkItems')) {
        itemRequests++;
        return _groupList([
          _summary(iid: itemRequests, title: 'Current typed row'),
        ]);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-work-item-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Epic renamed by server').last);
    await settleNetworkWidgets(tester);

    refreshCapabilities = true;
    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await pumpUntil(
      tester,
      () => typeRequests == 3,
      description: 'second capability verification page',
    );
    await tester.tap(find.byKey(const Key('group-work-item-type')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Project-only issue').last);
    await pumpUntil(
      tester,
      () => itemRequests == 4,
      description: 'new selected type request',
    );

    pageTwo.complete(
      _types(
        nodes: [
          {
            'id': 'gid://gitlab/WorkItems::Type/102',
            'name': 'Later unrelated type',
            'enabled': true,
            'isGroupWorkItemType': true,
            'widgetDefinitions': <Object?>[],
          },
        ],
      ),
    );
    await settleNetworkWidgets(tester);
    await refresh;

    expect(itemRequests, 4);
    expect(
      _variables(
        adapter.requests.lastWhere(
          (request) => _query(request).contains('MobileGroupWorkItems'),
        ),
      ),
      containsPair('typeIds', ['gid://gitlab/WorkItems::Type/101']),
    );
    expect(find.textContaining('已選類型不再可用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late verification removal broadens the current state filter only',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final pageTwo = Completer<ResponseBody>();
      var refreshCapabilities = false;
      var typeRequests = 0;
      var itemRequests = 0;
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileNamespaceWorkItemTypes')) {
          typeRequests++;
          if (!refreshCapabilities) return _types();
          if (_variables(request)['after'] != null) return pageTwo.future;
          return jsonResponse({
            'data': {
              'namespace': {
                'id': _groupId,
                'fullPath': _groupPath,
                'workItemTypes': _connection([
                  {
                    'id': 'gid://gitlab/WorkItems::Type/101',
                    'name': 'Project-only issue',
                    'enabled': true,
                    'isGroupWorkItemType': false,
                    'widgetDefinitions': <Object?>[],
                  },
                ], next: 'types-2'),
              },
            },
          });
        }
        if (query.contains('MobileGroupWorkItems')) {
          itemRequests++;
          final variables = _variables(request);
          final typed = variables.containsKey('typeIds');
          return _groupList([
            _summary(
              iid: itemRequests,
              title: '${variables['state']} ${typed ? 'typed' : 'all types'}',
            ),
          ]);
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('包含子群組與專案'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('group-work-item-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Epic renamed by server').last);
      await settleNetworkWidgets(tester);

      refreshCapabilities = true;
      final refresh = tester
          .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
          .show();
      await pumpUntil(
        tester,
        () => typeRequests == 3,
        description: 'pending selected-type verification page',
      );
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '已關閉'))
          .onSelected!(true);
      await pumpUntil(
        tester,
        () => itemRequests == 4,
        description: 'new state with the same selected type',
      );

      pageTwo.complete(
        _types(
          nodes: [
            {
              'id': 'gid://gitlab/WorkItems::Type/102',
              'name': 'Later unrelated type',
              'enabled': true,
              'isGroupWorkItemType': true,
              'widgetDefinitions': <Object?>[],
            },
          ],
        ),
      );
      await settleNetworkWidgets(tester);
      await refresh;

      expect(itemRequests, 5);
      final latest = _variables(
        adapter.requests.lastWhere(
          (request) => _query(request).contains('MobileGroupWorkItems'),
        ),
      );
      expect(latest, containsPair('state', 'closed'));
      expect(latest.containsKey('typeIds'), isFalse);
      expect(find.text('closed all types'), findsOneWidget);
      expect(find.textContaining('已選類型不再可用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('initial item failure does not strand capability loading', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileGroupWorkItems')) {
        return jsonResponse({'message': 'temporary failure'}, status: 500);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);

    expect(find.text('讀取可用的工作項目類型…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed replacement does not park stale initial capabilities', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final initialItems = Completer<ResponseBody>();
    final initialTypes = Completer<ResponseBody>();
    var itemRequests = 0;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) {
        return initialTypes.future;
      }
      if (query.contains('MobileGroupWorkItems')) {
        itemRequests++;
        if (itemRequests == 1) return initialItems.future;
        return jsonResponse({'message': 'replacement failed'}, status: 500);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await pumpUntil(
      tester,
      () => itemRequests == 1,
      description: 'initial item request',
    );
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pump(const Duration(milliseconds: 300));
    tester
        .widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, '已關閉', skipOffstage: false),
        )
        .onSelected!(true);
    await pumpUntil(
      tester,
      () => itemRequests == 2,
      description: 'replacement item request',
    );
    await tester.pump();

    initialItems.complete(
      _groupList([_summary(iid: 1, title: 'Stale initial row')]),
    );
    initialTypes.complete(_types());
    await settleNetworkWidgets(tester);

    expect(find.text('Stale initial row'), findsNothing);
    expect(find.text('讀取可用的工作項目類型…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing a filter suppresses an in-flight continuation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final continuation = Completer<ResponseBody>();
    var itemRequests = 0;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileGroupWorkItems')) {
        itemRequests++;
        final variables = _variables(request);
        if (variables['after'] == 'old-cursor') return continuation.future;
        if (variables['state'] == 'closed') {
          return _groupList([
            _summary(iid: 3, title: 'Fresh filtered first page'),
          ]);
        }
        return _groupList([
          _summary(iid: 1, title: 'Initial page'),
        ], next: 'old-cursor');
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('載入更多工作項目'));
    await pumpUntil(
      tester,
      () => itemRequests == 2,
      description: 'continuation request',
    );
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pump(const Duration(milliseconds: 300));
    tester
        .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '已關閉'))
        .onSelected!(true);
    await pumpUntil(
      tester,
      () => itemRequests == 3,
      description: 'replacement filtered request',
    );
    await settleNetworkWidgets(tester);

    continuation.complete(
      _groupList([_summary(iid: 2, title: 'Stale continuation row')]),
    );
    await settleNetworkWidgets(tester);

    expect(
      find.text('Fresh filtered first page', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('Initial page', skipOffstage: false), findsNothing);
    expect(
      find.text('Stale continuation row', skipOffstage: false),
      findsNothing,
    );
    expect(itemRequests, 3);
  });

  testWidgets('group controls fit a narrow phone at 200 percent text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileGroupWorkItems')) return _groupList(const []);
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api, scale: 2));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('包含子群組與專案'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('group-work-item-filters')), findsOneWidget);
    final scopeChip = find.widgetWithText(ChoiceChip, '包含子群組與專案');
    final scopeLabel = find.descendant(
      of: scopeChip,
      matching: find.text('包含子群組與專案'),
    );
    final scopeParagraph = tester.renderObject<RenderParagraph>(scopeLabel);
    final labelBoxes = scopeParagraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 8),
    );
    expect(scopeParagraph.didExceedMaxLines, isFalse);
    expect(labelBoxes.length, greaterThanOrEqualTo(2));
    expect(
      tester.getRect(scopeChip).right,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('group-work-item-filters'))).right,
      ),
    );
    expect(
      find.byKey(const Key('group-work-item-search'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('group-work-item-sort'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('group-work-item-type'), skipOffstage: false),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selected Work Items tab stays visible after text scale changes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileGroupWorkItems')) return _groupList(const []);
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        throw StateError('Unexpected request ${request.uri.path}');
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final scale = ValueNotifier(1.0);
      addTearDown(scale.dispose);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => ValueListenableBuilder<double>(
            valueListenable: scale,
            child: child,
            builder: (context, value, navigator) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(value)),
              child: navigator!,
            ),
          ),
          home: GroupPage(
            account: _account(api),
            api: api,
            group: const {'id': 9, 'name': 'Team', 'full_path': _groupPath},
            initialTab: 4,
            isCurrent: () => true,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      final groupPageBefore = tester.state(find.byType(GroupPage));
      final navigatorBefore = tester.state(find.byType(Navigator));

      scale.value = 2;
      await tester.pumpAndSettle();

      expect(tester.state(find.byType(GroupPage)), same(groupPageBefore));
      expect(tester.state(find.byType(Navigator)), same(navigatorBefore));

      final selectedTab = find.widgetWithText(Tab, '工作項目');
      expect(selectedTab, findsOneWidget);
      final rect = tester.getRect(selectedTab);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a group page without an owner fails closed before requests', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      throw StateError('Ownerless page must not request ${request.uri}');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GroupPage(
          account: _account(api),
          api: api,
          group: const {'id': 9, 'name': 'Team', 'full_path': _groupPath},
          initialTab: 4,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('請求已取消'), findsOneWidget);
    expect(find.text('Visible from group'), findsNothing);
    expect(adapter.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mismatched owner never activates group data', (tester) async {
    final owner = _OwnerMarker()..generation = 2;
    const captured = 1;
    final adapter = FakeAdapter((request) {
      throw StateError('Mismatched page must not request ${request.uri}');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GroupPage(
          account: _account(api),
          api: api,
          group: const {'id': 9, 'name': 'Team', 'full_path': _groupPath},
          initialTab: 4,
          isCurrent: () => owner.generation == captured,
          ownerChanges: owner,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('請求已取消'), findsOneWidget);
    expect(adapter.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an owner replacement removes already activated group rows', (
    tester,
  ) async {
    final owner = _OwnerMarker();
    final captured = owner.generation;
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileGroupWorkItems')) {
        return _groupList([_summary(iid: 4, title: 'Owned group row')]);
      }
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      throw StateError('Unexpected request ${request.uri}');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GroupPage(
          account: _account(api),
          api: api,
          group: const {'id': 9, 'name': 'Team', 'full_path': _groupPath},
          initialTab: 4,
          isCurrent: () => owner.generation == captured,
          ownerChanges: owner,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('Owned group row'), findsOneWidget);

    owner.generation++;
    owner.notify();
    await tester.pumpAndSettle();

    expect(find.text('Owned group row'), findsNothing);
    expect(find.text('請求已取消'), findsOneWidget);
  });

  testWidgets(
    'group list stays embedded, preserves server capabilities, and opens by returned namespace',
    (tester) async {
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileGroupWorkItems')) {
          final variables = _variables(request);
          expect(variables['path'], _groupPath);
          expect(variables['after'], isNull);
          expect(variables['includeDescendants'], isTrue);
          expect(variables['state'], 'opened');
          return _groupList([_summary(iid: 7, title: 'Group planning item')]);
        }
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileWorkItemState')) return _state(7);
        if (query.contains('MobileNamespaceWorkItem')) {
          final variables = _variables(request);
          expect(variables, containsPair('path', _groupPath));
          expect(variables, containsPair('iid', '7'));
          return _detail(7, 'Group planning item');
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await settleNetworkWidgets(tester);

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text('包含子群組與專案'), findsOneWidget);
      expect(find.text('Epic renamed by server'), findsWidgets);
      expect(find.text('Disabled objective（未啟用）'), findsOneWidget);
      expect(find.text('Project-only issue'), findsOneWidget);
      expect(find.text('Group planning item'), findsOneWidget);
      expect(find.text('team · Epic renamed by server · #7'), findsOneWidget);

      await tester.tap(find.text('Group planning item'));
      await settleNetworkWidgets(tester);
      expect(find.text('Group detail from verified namespace'), findsOneWidget);
      expect(
        adapter.requests.any(
          (request) => _query(request).contains('MobileProjectWorkItem('),
        ),
        isFalse,
        reason: 'group rows must not guess or resolve a project identity',
      );
    },
  );

  testWidgets('group detail header fits 320dp at 2x text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter((request) {
      if (_query(request).contains('MobileWorkItemState')) {
        return _state(123456789);
      }
      expect(_query(request), contains('MobileNamespaceWorkItem'));
      expect(_variables(request), containsPair('path', _groupPath));
      expect(_variables(request), containsPair('iid', '123456789'));
      return _detail(123456789, 'Group planning item');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: GraphWorkItemDetailPage.namespace(
          account: _account(api),
          api: api,
          namespacePath: _groupPath,
          expectedNamespaceId: _groupId,
          iid: 123456789,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('工作項目 #123456789'), findsOneWidget);
    expect(find.byTooltip('分享連結'), findsOneWidget);
    expect(find.byTooltip('重新整理'), findsOneWidget);
    expect(
      tester.getRect(find.byTooltip('重新整理')).right,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'continuations skip exact duplicates and stop identity collisions',
    (tester) async {
      var pages = 0;
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileGroupWorkItems')) {
          pages++;
          final after = _variables(request)['after'];
          if (after == null) {
            return _groupList([
              _summary(iid: 1, title: 'First'),
            ], next: 'cursor-1');
          }
          expect(after, 'cursor-1');
          expect(_variables(request)['path'], _groupPath);
          return _groupList([
            _summary(iid: 1, title: 'First'),
            _summary(
              iid: 2,
              title: 'Conflicting ID',
              id: 'gid://gitlab/WorkItem/1',
            ),
          ]);
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('載入更多工作項目'));
      await settleNetworkWidgets(tester);

      expect(find.text('First'), findsOneWidget);
      expect(find.text('Conflicting ID'), findsNothing);
      expect(find.text('無法讀取回應'), findsOneWidget);
      expect(pages, 2);
    },
  );

  testWidgets('an empty first page keeps its server continuation accessible', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileGroupWorkItems')) {
        final after = _variables(request)['after'];
        return after == null
            ? _groupList(const [], next: 'empty-next')
            : _groupList([_summary(iid: 8, title: 'After empty page')]);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    expect(find.text('沒有可顯示的工作項目'), findsOneWidget);
    expect(find.text('載入更多工作項目'), findsOneWidget);

    await tester.tap(find.text('載入更多工作項目'));
    await settleNetworkWidgets(tester);
    expect(find.text('After empty page'), findsOneWidget);
  });

  testWidgets('a replayed cursor stops while preserving loaded rows', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileGroupWorkItems')) {
        final after = _variables(request)['after'];
        return switch (after) {
          null => _groupList([
            _summary(iid: 1, title: 'Loop item 1'),
          ], next: 'cursor-a'),
          'cursor-a' => _groupList([
            _summary(iid: 2, title: 'Loop item 2'),
          ], next: 'cursor-b'),
          'cursor-b' => _groupList([
            _summary(iid: 3, title: 'Loop item 3'),
          ], next: 'cursor-a'),
          _ => throw StateError('Unexpected cursor $after'),
        };
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    final loadMoreFinder = find.text('載入更多工作項目');
    await tester.ensureVisible(loadMoreFinder);
    await tester.pumpAndSettle();
    await tester.tap(loadMoreFinder);
    await settleNetworkWidgets(tester);
    await tester.ensureVisible(loadMoreFinder);
    await tester.pumpAndSettle();
    await tester.tap(loadMoreFinder);
    await settleNetworkWidgets(tester);

    expect(find.text('Loop item 1'), findsOneWidget);
    expect(find.text('Loop item 2'), findsOneWidget);
    expect(find.text('Loop item 3'), findsOneWidget);
    expect(find.text('無法讀取回應', skipOffstage: false), findsOneWidget);
    expect(find.text('載入更多工作項目'), findsNothing);
    expect(
      adapter.requests.where(
        (request) => _query(request).contains('MobileGroupWorkItems'),
      ),
      hasLength(3),
    );
  });

  testWidgets('a phone can reach and use continuation after a full page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileGroupWorkItems')) {
        return _variables(request)['after'] == null
            ? _groupList([
                for (var iid = 1; iid <= 20; iid++)
                  _summary(iid: iid, title: 'First page $iid'),
              ], next: 'full-page')
            : _groupList([_summary(iid: 21, title: 'Second page row')]);
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    final scrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('載入更多工作項目'),
      500,
      scrollable: scrollable,
    );
    await tester.tap(find.text('載入更多工作項目'));
    await settleNetworkWidgets(tester);

    expect(find.text('Second page row'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bounded list explains when more server rows remain', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileGroupWorkItems')) {
        final after = _variables(request)['after'] as String?;
        final page = after == null ? 1 : int.parse(after.split('-').last) + 1;
        return _groupList([
          _summary(iid: page, title: 'Bounded item $page'),
        ], next: 'cursor-$page');
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    for (var page = 2; page <= 10; page++) {
      final button = find.text('載入更多工作項目');
      expect(
        button,
        findsOneWidget,
        reason: 'page $page must retain its continuation',
      );
      await tester.tap(button);
      await settleNetworkWidgets(tester);
    }

    expect(find.text('Bounded item 1', skipOffstage: false), findsOneWidget);
    expect(find.text('Bounded item 10', skipOffstage: false), findsOneWidget);
    expect(
      find.textContaining('已載入工作項目上限', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('載入更多工作項目', skipOffstage: false), findsNothing);
    expect(
      adapter.requests.where(
        (request) => _query(request).contains('MobileGroupWorkItems'),
      ),
      hasLength(10),
    );
  });

  testWidgets('path and API switches clear stale in-flight group data', (
    tester,
  ) async {
    final delayed = Completer<ResponseBody>();
    final oldAdapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileGroupWorkItems')) return delayed.future;
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      throw StateError('Unexpected query');
    });
    final oldApi = testApi(oldAdapter);
    addTearDown(oldApi.close);
    final newAdapter = FakeAdapter((request) {
      final query = _query(request);
      if (query.contains('MobileGroupWorkItems')) {
        return _groupList(
          [
            _summary(
              iid: 3,
              title: 'Fresh group',
              path: 'other',
              groupId: 'gid://gitlab/Group/10',
            ),
          ],
          path: 'other',
          groupId: 'gid://gitlab/Group/10',
        );
      }
      if (query.contains('MobileNamespaceWorkItemTypes')) {
        return _types(path: 'other', groupId: 'gid://gitlab/Group/10');
      }
      throw StateError('Unexpected query');
    });
    final newApi = testApi(newAdapter);
    addTearDown(newApi.close);

    await tester.pumpWidget(_host(_account(oldApi), oldApi));
    await tester.pump();
    await tester.pumpWidget(_host(_account(newApi), newApi, path: 'other'));
    await settleNetworkWidgets(tester);
    delayed.complete(_groupList([_summary(iid: 1, title: 'Stale group')]));
    await settleNetworkWidgets(tester);

    expect(find.text('Fresh group'), findsOneWidget);
    expect(find.text('Stale group'), findsNothing);
    expect(find.text('other'), findsOneWidget);
  });

  testWidgets(
    'owner changes clear group data and close an owned detail route',
    (tester) async {
      final owner = _OwnerMarker();
      final captured = owner.generation;
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileGroupWorkItems')) {
          return _groupList([_summary(iid: 7, title: 'Owned item')]);
        }
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileWorkItemState')) return _state(7);
        if (query.contains('MobileNamespaceWorkItem')) {
          return _detail(7, 'Owned item');
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkItemsPage.group(
            account: _account(api),
            api: api,
            namespacePath: _groupPath,
            ownerChanges: owner,
            isCurrent: () => owner.generation == captured,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('Owned item'));
      await settleNetworkWidgets(tester);
      expect(find.text('Group detail from verified namespace'), findsOneWidget);

      owner.generation++;
      owner.notify();
      await tester.pumpAndSettle();

      expect(find.text('Owned item'), findsNothing);
      expect(find.text('Group detail from verified namespace'), findsNothing);
      expect(find.text('帳號已切換，工作項目頁面已關閉。'), findsOneWidget);
    },
  );

  testWidgets(
    'mismatched or unavailable group capabilities are not displayed',
    (tester) async {
      var unavailable = false;
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileGroupWorkItems')) return _groupList(const []);
        if (query.contains('MobileNamespaceWorkItemTypes')) {
          if (unavailable) {
            return jsonResponse({
              'data': {
                'namespace': {
                  'id': _groupId,
                  'fullPath': _groupPath,
                  'workItemTypes': null,
                },
              },
            });
          }
          return _types(groupId: 'gid://gitlab/Group/10');
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await settleNetworkWidgets(tester);
      expect(find.text('無法讀取回應'), findsOneWidget);
      expect(find.text('Epic renamed by server'), findsNothing);

      unavailable = true;
      await tester.tap(find.text('重新整理'));
      await settleNetworkWidgets(tester);
      expect(find.text('沒有操作權限'), findsOneWidget);
      expect(find.text('Epic renamed by server'), findsNothing);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('unsupported capability remains usable at text scale $scale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileGroupWorkItems')) return _groupList(const []);
        if (query.contains('MobileNamespaceWorkItemTypes')) {
          return jsonResponse({
            'errors': [
              {
                'message': 'field unavailable',
                'extensions': {'code': 'undefinedField'},
              },
            ],
          });
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: _host(_account(api), api),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('實例未提供原生工作項目'), findsOneWidget);
      expect(find.text('重新整理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'T17: Row with 5 labels and 3 assignees shows exactly one "更多" per partial connection with semantics "還有更多，未載入" and no +digit text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final itemWithPartials = {
        ..._summary(iid: 99, title: 'Item with 5 labels and 3 assignees'),
        'widgets': [
          {
            'type': 'LABELS',
            'labels': {
              'nodes': List.generate(
                5,
                (i) => {
                  'id': 'gid://gitlab/GroupLabel/$i',
                  'title': 'label-$i',
                  'color': '#ff0000',
                  'description': null,
                  'textColor': '#ffffff',
                },
              ),
              'pageInfo': {'hasNextPage': true, 'endCursor': 'label-cursor'},
            },
          },
          {
            'type': 'ASSIGNEES',
            'assignees': {
              'nodes': List.generate(
                3,
                (i) => {
                  'id': 'gid://gitlab/User/$i',
                  'name': 'Assignee $i',
                  'username': 'user$i',
                },
              ),
              'pageInfo': {'hasNextPage': true, 'endCursor': 'assignee-cursor'},
            },
          },
        ],
      };

      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileGroupWorkItems')) {
          return jsonResponse({
            'data': {
              'group': {
                'id': _groupId,
                'fullPath': _groupPath,
                'workItems': _connection([itemWithPartials]),
              },
            },
          });
        }
        throw StateError('Unexpected query');
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await settleNetworkWidgets(tester);

      expect(find.textContaining(RegExp(r'\+\s*\d')), findsNothing);
      expect(find.text('更多'), findsNWidgets(2));
      expect(find.bySemanticsLabel('還有更多，未載入'), findsNWidgets(2));
    },
  );

  testWidgets(
    'A9: embedded group list exposes display options button in header row',
    (tester) async {
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileGroupWorkItems')) {
          return _groupList([_summary(iid: 1, title: 'Item 1')]);
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await settleNetworkWidgets(tester);

      expect(
        find.byKey(const Key('graph-work-items-display-options-button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('graph-work-items-display-options-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('顯示設定'), findsOneWidget);
    },
  );
}

final class _OwnerMarker extends ChangeNotifier {
  int generation = 0;
  void notify() => notifyListeners();
}
