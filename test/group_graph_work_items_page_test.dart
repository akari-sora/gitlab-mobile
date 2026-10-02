import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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

Map<String, Object?> _body(RequestOptions request) =>
    Map<String, Object?>.from(request.data as Map);

String _query(RequestOptions request) => _body(request)['query']! as String;

Map<String, Object?> _variables(RequestOptions request) =>
    Map<String, Object?>.from(_body(request)['variables']! as Map);

Widget _host(Account account, GitLabApi api, {String path = _groupPath}) =>
    MaterialApp(
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
    expect(find.text('僅此群組的工作項目'), findsOneWidget);
    expect(find.text('Visible from group'), findsOneWidget);
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
          expect(query, contains('includeDescendants: false'));
          return _groupList([_summary(iid: 7, title: 'Group planning item')]);
        }
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
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
      expect(find.text('僅此群組的工作項目'), findsOneWidget);
      expect(find.text('Epic renamed by server'), findsWidgets);
      expect(find.text('Disabled objective（未啟用）'), findsOneWidget);
      expect(find.text('Project-only issue'), findsNothing);
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
    await tester.tap(find.text('載入更多工作項目'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('載入更多工作項目'));
    await settleNetworkWidgets(tester);

    expect(find.text('Loop item 1'), findsOneWidget);
    expect(find.text('Loop item 2'), findsOneWidget);
    expect(find.text('Loop item 3'), findsOneWidget);
    expect(find.text('無法讀取回應'), findsOneWidget);
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
}

final class _OwnerMarker extends ChangeNotifier {
  int generation = 0;
  void notify() => notifyListeners();
}
