import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/navigation.dart';
import 'package:gitlab_mobile/features/workspace/work_item_attributes.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = Project(id: 42, name: 'Example', path: 'team/example');

Account _account(GitLabApi api, int user) => Account(
  instance: api.instance,
  user: GitLabUser(id: user, username: 'user$user', name: 'User $user'),
  token: 'synthetic-test-token',
);

Map<String, Object?> _summary({
  String title = 'Customer follow-up',
  String typeName = 'Customer Request renamed',
  int iid = 7,
  String? id,
  bool includeNamespace = true,
}) => {
  'id': id ?? 'gid://gitlab/WorkItem/$iid',
  'iid': '$iid',
  'title': title,
  'state': 'OPEN',
  'createdAt': '2026-09-01T01:02:03Z',
  'updatedAt': '2026-09-02T03:04:05Z',
  'webUrl': 'https://example.com/gitlab/team/example/-/work_items/$iid',
  'project': {'id': 'gid://gitlab/Project/42', 'fullPath': 'team/example'},
  'namespace': includeNamespace
      ? {
          'id': 'gid://gitlab/Namespaces::ProjectNamespace/42',
          'fullPath': 'team/example',
        }
      : null,
  'workItemType': {'id': 'gid://gitlab/WorkItems::Type/99', 'name': typeName},
  'widgets': const <Object?>[],
};

Map<String, Object?> _connection(List<Object?> nodes, {bool more = false}) => {
  'nodes': nodes,
  'pageInfo': {'hasNextPage': more, 'endCursor': more ? 'next-page' : null},
};

ResponseBody _projectList({
  String title = 'Customer follow-up',
  int iid = 7,
  String? id,
  bool more = false,
}) => jsonResponse({
  'data': {
    'project': {
      'id': 'gid://gitlab/Project/42',
      'fullPath': 'team/example',
      'workItems': _connection([
        _summary(title: title, iid: iid, id: id),
      ], more: more),
    },
  },
});

ResponseBody _types() => jsonResponse({
  'data': {
    'namespace': {
      'id': 'gid://gitlab/Namespaces::ProjectNamespace/42',
      'fullPath': 'team/example',
      'workItemTypes': _connection([
        {
          'id': 'gid://gitlab/WorkItems::Type/99',
          'name': 'Customer Request renamed',
          'enabled': true,
          'isGroupWorkItemType': false,
          'widgetDefinitions': [
            {'type': 'DESCRIPTION'},
            {'type': 'HIERARCHY'},
          ],
        },
      ]),
    },
  },
});

ResponseBody _detail({int iid = 7, bool projectOnlyChild = false}) =>
    jsonResponse({
      'data': {
        'project': {
          'id': 'gid://gitlab/Project/42',
          'fullPath': 'team/example',
          'workItems': _connection([
            {
              ..._summary(iid: iid),
              'description': 'Native **Markdown** description',
              'widgets': [
                {
                  'type': 'DESCRIPTION',
                  'description': 'Native **Markdown** description',
                  'edited': false,
                  'lastEditedAt': null,
                },
                {
                  'type': 'ASSIGNEES',
                  'assignees': _connection([
                    {
                      'id': 'gid://gitlab/User/5',
                      'name': 'Example User',
                      'username': 'example',
                      'avatarUrl': null,
                    },
                  ], more: true),
                },
                {
                  'type': 'LABELS',
                  'labels': _connection([
                    {
                      'id': 'gid://gitlab/Label/6',
                      'title': 'mobile',
                      'color': '#336699',
                      'description': null,
                      'textColor': '#ffffff',
                    },
                  ]),
                },
                {
                  'type': 'HIERARCHY',
                  'hasParent': false,
                  'hasChildren': true,
                  'parent': null,
                  'children': _connection([
                    _summary(
                      title: 'Bounded child',
                      iid: 8,
                      includeNamespace: !projectOnlyChild,
                    ),
                  ], more: true),
                },
                {
                  'type': 'START_AND_DUE_DATE',
                  'startDate': '2026-09-03',
                  'dueDate': '2026-09-10',
                  'rollUp': false,
                },
              ],
            },
          ]),
        },
      },
    });

ResponseBody _state(
  int iid, {
  String state = 'OPEN',
  String updatedAt = '2026-09-02T03:04:05Z',
  bool canUpdate = false,
}) => jsonResponse({
  'data': {
    'workItem': {
      'id': 'gid://gitlab/WorkItem/$iid',
      'iid': '$iid',
      'state': state,
      'updatedAt': updatedAt,
      'project': {'id': 'gid://gitlab/Project/42', 'fullPath': 'team/example'},
      'namespace': {
        'id': 'gid://gitlab/Namespaces::ProjectNamespace/42',
        'fullPath': 'team/example',
      },
      'workItemType': {'id': 'gid://gitlab/WorkItems::Type/99'},
      'userPermissions': {'updateWorkItem': canUpdate},
    },
  },
});

ResponseBody _namespaceDetail({
  required int iid,
  required String namespaceId,
  required String namespacePath,
  required String title,
  String? projectId,
  String? projectPath,
}) => jsonResponse({
  'data': {
    'namespace': {
      'id': namespaceId,
      'fullPath': namespacePath,
      'workItem': {
        'id': 'gid://gitlab/WorkItem/$iid',
        'iid': '$iid',
        'title': title,
        'state': 'OPEN',
        'createdAt': '2026-09-01T01:02:03Z',
        'updatedAt': '2026-09-02T03:04:05Z',
        'project': projectId == null
            ? null
            : {'id': projectId, 'fullPath': projectPath},
        'namespace': {'id': namespaceId, 'fullPath': namespacePath},
        'workItemType': {
          'id': 'gid://gitlab/WorkItems::Type/99',
          'name': 'Issue',
        },
        'description': 'Verified namespace detail',
        'widgets': const <Object?>[],
      },
    },
  },
});

ResponseBody _namespaceState({
  required int iid,
  required String namespaceId,
  required String namespacePath,
  String? projectId,
  String? projectPath,
}) => jsonResponse({
  'data': {
    'workItem': {
      'id': 'gid://gitlab/WorkItem/$iid',
      'iid': '$iid',
      'state': 'OPEN',
      'updatedAt': '2026-09-02T03:04:05Z',
      'project': projectId == null
          ? null
          : {'id': projectId, 'fullPath': projectPath},
      'namespace': {'id': namespaceId, 'fullPath': namespacePath},
      'workItemType': {'id': 'gid://gitlab/WorkItems::Type/99'},
      'userPermissions': {'updateWorkItem': false},
    },
  },
});

ResponseBody _response(
  RequestOptions request, {
  String title = 'Customer follow-up',
  int iid = 7,
}) {
  final data = request.data as Map;
  final query = data['query'] as String;
  if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
  if (query.contains('MobileWorkItemState')) return _state(iid);
  if (query.contains('MobileProjectWorkItem(')) return _detail(iid: iid);
  if (query.contains('MobileProjectWorkItems(')) {
    return _projectList(title: title, iid: iid);
  }
  return jsonResponse({'message': 'unhandled'}, status: 404);
}

Widget _host(Account account, GitLabApi api, {double scale = 1}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: GraphWorkItemsPage(account: account, api: api, project: _project),
);

final class _OwnerMarker extends ChangeNotifier {
  String account = 'first';
  int generation = 1;
  Object api = Object();

  void changed() => notifyListeners();
}

void main() {
  testWidgets(
    'custom server type opens native readonly widgets without REST subtype routing',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final adapter = FakeAdapter(_response);
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api));
      await tester.pumpAndSettle();

      expect(find.text('Customer Request renamed'), findsWidgets);
      expect(find.text('Customer follow-up'), findsOneWidget);
      await tester.tap(find.text('Customer follow-up'));
      await settleNetworkWidgets(tester);

      expect(find.text('Native Markdown description'), findsOneWidget);
      expect(find.byTooltip('分享連結'), findsOneWidget);
      expect(find.byTooltip('重新整理'), findsOneWidget);
      expect(find.text('Example User · @example'), findsOneWidget);
      expect(find.text('mobile'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Bounded child'), 260);
      expect(find.text('Bounded child'), findsOneWidget);
      expect(find.text('只顯示前 20 位負責人。'), findsOneWidget);
      expect(find.text('只顯示前 20 個子項目；請在 GitLab 查看完整清單。'), findsOneWidget);
      expect(adapter.requests, isNotEmpty);
      expect(
        adapter.requests.every(
          (request) => request.uri.path.endsWith('/api/graphql'),
        ),
        isTrue,
      );
      expect(
        adapter.requests.where((request) {
          final variables = (request.data as Map)['variables'] as Map;
          return variables.containsKey('type') ||
              variables.values.contains('Customer Request renamed');
        }),
        isEmpty,
        reason:
            'custom display names are never used as routing or REST subtype filters',
      );
    },
  );

  testWidgets('project detail header fits 320dp at 2x text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter(
      (request) => _response(request, iid: 123456789),
    );
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
        home: GraphWorkItemDetailPage.project(
          account: _account(api, 7),
          api: api,
          project: _project,
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
    'namespace detail shares a verified descendant project URL with instance subpath and port',
    (tester) async {
      const iid = 59;
      const namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/194';
      const path = 'qa/synthetic-group/child-project';
      const projectId = 'gid://gitlab/Project/94';
      final adapter = FakeAdapter((request) {
        if (!request.uri.path.endsWith('/api/graphql')) {
          return jsonResponse({
            'id': 94,
            'name': 'Child project',
            'path_with_namespace': path,
            'visibility': 'private',
            'default_branch': 'main',
            'archived': false,
          });
        }
        final query = (request.data as Map)['query'] as String;
        if (query.contains('MobileWorkItemState')) {
          return _namespaceState(
            iid: iid,
            namespaceId: namespaceId,
            namespacePath: path,
            projectId: projectId,
            projectPath: path,
          );
        }
        if (query.contains('MobileNamespaceWorkItem')) {
          return _namespaceDetail(
            iid: iid,
            namespaceId: namespaceId,
            namespacePath: path,
            title: 'Descendant project item',
            projectId: projectId,
            projectPath: path,
          );
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkItemDetailPage.namespace(
            account: _account(api, 7),
            api: api,
            namespacePath: path,
            expectedNamespaceId: namespaceId,
            iid: iid,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      final share = tester.widget<ResourceShareButton>(
        find.byType(ResourceShareButton),
      );
      expect(
        share.uri.toString(),
        'https://example.com:8443/gitlab/qa/synthetic-group/child-project/-/work_items/59',
      );
    },
  );

  testWidgets(
    'wrong descendant project identity keeps plain Markdown and offers retry',
    (tester) async {
      const iid = 59;
      const namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/194';
      const path = 'qa/synthetic-group/child-project';
      const projectId = 'gid://gitlab/Project/94';
      var projectReads = 0;
      final adapter = FakeAdapter((request) {
        if (!request.uri.path.endsWith('/api/graphql')) {
          projectReads++;
          return jsonResponse({
            'id': projectReads == 1 ? 95 : 94,
            'name': 'Child project',
            'path_with_namespace': path,
            'visibility': 'private',
            'default_branch': 'main',
            'archived': false,
          });
        }
        final query = (request.data as Map)['query'] as String;
        if (query.contains('MobileWorkItemState')) {
          return _namespaceState(
            iid: iid,
            namespaceId: namespaceId,
            namespacePath: path,
            projectId: projectId,
            projectPath: path,
          );
        }
        if (query.contains('MobileNamespaceWorkItem')) {
          return _namespaceDetail(
            iid: iid,
            namespaceId: namespaceId,
            namespacePath: path,
            title: 'Descendant project item',
            projectId: projectId,
            projectPath: path,
          );
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkItemDetailPage.namespace(
            account: _account(api, 7),
            api: api,
            namespacePath: path,
            expectedNamespaceId: namespaceId,
            iid: iid,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(projectReads, 1);
      expect(find.text('專案 Markdown 整合'), findsOneWidget);
      expect(find.textContaining('仍可使用純 Markdown'), findsOneWidget);
      expect(find.text('無法讀取回應'), findsOneWidget);
      expect(find.textContaining(path), findsWidgets);
      expect(find.text('切換帳號'), findsOneWidget);

      final retry = find.ancestor(
        of: find.descendant(
          of: find.byKey(const ValueKey('work-item-project-context-failure')),
          matching: find.text('重新整理'),
        ),
        matching: find.byType(TextButton),
      );
      tester.widget<TextButton>(retry).onPressed!();
      await settleNetworkWidgets(tester);

      expect(projectReads, 2);
      expect(find.text('專案 Markdown 整合'), findsNothing);
      expect(find.text('無法讀取回應'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late descendant project context cannot escape namespace replacement',
    (tester) async {
      const projectPath = 'qa/synthetic-group/child-project';
      const projectNamespaceId =
          'gid://gitlab/Namespaces::ProjectNamespace/194';
      const replacementPath = 'qa/replacement-group';
      const replacementNamespaceId = 'gid://gitlab/Group/99';
      final pendingProject = Completer<ResponseBody>();
      final adapter = FakeAdapter((request) {
        if (!request.uri.path.endsWith('/api/graphql')) {
          return pendingProject.future;
        }
        final data = request.data as Map;
        final query = data['query'] as String;
        final variables = data['variables'] as Map;
        if (query.contains('MobileWorkItemState')) {
          final replacement = '${variables['id']}'.endsWith('/60');
          return _namespaceState(
            iid: replacement ? 60 : 59,
            namespaceId: replacement
                ? replacementNamespaceId
                : projectNamespaceId,
            namespacePath: replacement ? replacementPath : projectPath,
            projectId: replacement ? null : 'gid://gitlab/Project/94',
            projectPath: replacement ? null : projectPath,
          );
        }
        if (query.contains('MobileNamespaceWorkItem')) {
          final replacement = variables['path'] == replacementPath;
          return _namespaceDetail(
            iid: replacement ? 60 : 59,
            namespaceId: replacement
                ? replacementNamespaceId
                : projectNamespaceId,
            namespacePath: replacement ? replacementPath : projectPath,
            title: replacement
                ? 'Replacement group detail'
                : 'Old descendant project detail',
            projectId: replacement ? null : 'gid://gitlab/Project/94',
            projectPath: replacement ? null : projectPath,
          );
        }
        throw StateError('Unexpected query: $query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final account = _account(api, 7);

      Widget page({
        required String path,
        required String namespaceId,
        required int iid,
      }) => MaterialApp(
        home: GraphWorkItemDetailPage.namespace(
          account: account,
          api: api,
          namespacePath: path,
          expectedNamespaceId: namespaceId,
          iid: iid,
        ),
      );

      await tester.pumpWidget(
        page(path: projectPath, namespaceId: projectNamespaceId, iid: 59),
      );
      for (
        var attempt = 0;
        attempt < 10 &&
            find.text('Old descendant project detail').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Old descendant project detail'), findsOneWidget);

      await tester.pumpWidget(
        page(
          path: replacementPath,
          namespaceId: replacementNamespaceId,
          iid: 60,
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('Replacement group detail'), findsOneWidget);

      pendingProject.complete(
        jsonResponse({
          'id': 94,
          'name': 'Old child project',
          'path_with_namespace': projectPath,
          'visibility': 'private',
          'default_branch': 'main',
          'archived': false,
        }),
      );
      await tester.pumpAndSettle();

      expect(find.text('Replacement group detail'), findsOneWidget);
      expect(find.text('Old descendant project detail'), findsNothing);
      expect(find.text('專案 Markdown 整合'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('namespace group detail keeps the groups share URL', (
    tester,
  ) async {
    const iid = 49;
    const namespaceId = 'gid://gitlab/Group/9';
    const path = 'qa/synthetic-group/child-group';
    final adapter = FakeAdapter((request) {
      final query = (request.data as Map)['query'] as String;
      if (query.contains('MobileWorkItemState')) {
        return _namespaceState(
          iid: iid,
          namespaceId: namespaceId,
          namespacePath: path,
        );
      }
      if (query.contains('MobileNamespaceWorkItem')) {
        return _namespaceDetail(
          iid: iid,
          namespaceId: namespaceId,
          namespacePath: path,
          title: 'Descendant group item',
        );
      }
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GraphWorkItemDetailPage.namespace(
          account: _account(api, 7),
          api: api,
          namespacePath: path,
          expectedNamespaceId: namespaceId,
          iid: iid,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(
      share.uri.toString(),
      'https://example.com:8443/gitlab/groups/qa/synthetic-group/child-group/-/work_items/49',
    );
  });

  testWidgets('direct project detail keeps the project share URL', (
    tester,
  ) async {
    final adapter = FakeAdapter(_response);
    final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: GraphWorkItemDetailPage.project(
          account: _account(api, 7),
          api: api,
          project: _project,
          iid: 7,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(
      share.uri.toString(),
      'https://example.com:8443/gitlab/team/example/-/work_items/7',
    );
  });

  testWidgets(
    'verified state snapshot updates header without reloading stale detail',
    (tester) async {
      var detailReads = 0;
      final adapter = FakeAdapter((request) {
        final query = (request.data as Map)['query'] as String;
        if (query.contains('MobileWorkItemState')) {
          return _state(7, state: 'CLOSED', updatedAt: '2026-09-03T03:04:05Z');
        }
        if (query.contains('MobileProjectWorkItem(')) {
          detailReads++;
          return _detail();
        }
        throw StateError('Unexpected query');
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkItemDetailPage.project(
            account: _account(api, 7),
            api: api,
            project: _project,
            iid: 7,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('已關閉'), findsOneWidget);
      expect(find.text('目前為已關閉'), findsOneWidget);
      expect(find.textContaining('更新於 2026/09/03'), findsOneWidget);
      expect(
        detailReads,
        1,
        reason: 'the stale detail response is not replayed',
      );
    },
  );

  testWidgets('direct account replacement dismisses an owned confirmation', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final query = (request.data as Map)['query'] as String;
      if (query.contains('MobileWorkItemState')) {
        return _state(7, canUpdate: true);
      }
      if (query.contains('MobileProjectWorkItem(')) return _detail();
      throw StateError('Unexpected query');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    Widget host(int user) => MaterialApp(
      home: GraphWorkItemDetailPage.project(
        account: _account(api, user),
        api: api,
        project: _project,
        iid: 7,
      ),
    );

    await tester.pumpWidget(host(7));
    await settleNetworkWidgets(tester);
    await tester.ensureVisible(find.text('關閉工作項目'));
    await tester.tap(find.text('關閉工作項目'));
    await tester.pumpAndSettle();
    expect(find.text('關閉工作項目？'), findsOneWidget);

    await tester.pumpWidget(host(8));
    await settleNetworkWidgets(tester);

    expect(find.text('關閉工作項目？'), findsNothing);
    expect(find.text('Native Markdown description'), findsOneWidget);
  });

  testWidgets('late old-account pages cannot replace the active account data', (
    tester,
  ) async {
    final oldList = Completer<ResponseBody>();
    final oldTypes = Completer<ResponseBody>();
    final oldAdapter = FakeAdapter((request) {
      final query = (request.data as Map)['query'] as String;
      return query.contains('MobileNamespaceWorkItemTypes')
          ? oldTypes.future
          : oldList.future;
    });
    final oldApi = testApi(oldAdapter);
    final activeAdapter = FakeAdapter(
      (request) => _response(request, title: 'Active account item'),
    );
    final activeApi = testApi(activeAdapter);
    addTearDown(oldApi.close);
    addTearDown(activeApi.close);

    await tester.pumpWidget(_host(_account(oldApi, 7), oldApi));
    await pumpUntil(
      tester,
      () => oldAdapter.requests.length == 2,
      description: 'both old-account GraphQL reads started',
    );
    expect(oldAdapter.requests.length, 2);

    await tester.pumpWidget(_host(_account(activeApi, 8), activeApi));
    await pumpUntil(
      tester,
      () => find.text('Active account item').evaluate().isNotEmpty,
      description: 'active account result visible',
    );
    expect(find.text('Active account item'), findsOneWidget);

    oldList.complete(_projectList(title: 'Old account item'));
    oldTypes.complete(_types());
    await settleNetworkWidgets(tester);

    expect(find.text('Active account item'), findsOneWidget);
    expect(find.text('Old account item'), findsNothing);
  });

  testWidgets('320dp wide large text keeps the native list usable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 840);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter(_response);
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api, 7), api, scale: 2));
    await tester.pumpAndSettle();

    expect(find.text('Customer follow-up'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('date-only work item scalar keeps its UTC calendar day', () {
    final dateOnly = DateTime.utc(2026, 1, 1);
    expect(workItemCalendarDate(dateOnly), '2026/01/01');
  });

  testWidgets('cross-page duplicate project path and iid rejects a new GID', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final query = (request.data as Map)['query'] as String;
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileProjectWorkItems(')) {
        final variables = (request.data as Map)['variables'] as Map;
        return variables['after'] == null
            ? _projectList(more: true)
            : _projectList(
                title: 'Conflicting identity',
                iid: 7,
                id: 'gid://gitlab/WorkItem/700',
              );
      }
      return jsonResponse({'message': 'unhandled'}, status: 404);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api, 7), api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('載入更多工作項目'));
    await tester.pumpAndSettle();

    expect(find.text('無法讀取回應'), findsOneWidget);
    expect(find.text('Conflicting identity'), findsNothing);
  });

  testWidgets('cross-page duplicate GID rejects a different scoped iid', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final query = (request.data as Map)['query'] as String;
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileProjectWorkItems(')) {
        final variables = (request.data as Map)['variables'] as Map;
        return variables['after'] == null
            ? _projectList(more: true)
            : _projectList(
                title: 'Conflicting scoped IID',
                iid: 8,
                id: 'gid://gitlab/WorkItem/7',
              );
      }
      return jsonResponse({'message': 'unhandled'}, status: 404);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api, 7), api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('載入更多工作項目'));
    await tester.pumpAndSettle();

    expect(find.text('無法讀取回應'), findsOneWidget);
    expect(find.text('Conflicting scoped IID'), findsNothing);
  });

  testWidgets('cross-page matching GID and scoped iid deduplicates safely', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      final query = (request.data as Map)['query'] as String;
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileProjectWorkItems(')) {
        final variables = (request.data as Map)['variables'] as Map;
        return variables['after'] == null
            ? _projectList(more: true)
            : _projectList(title: 'Duplicate page copy');
      }
      return jsonResponse({'message': 'unhandled'}, status: 404);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api, 7), api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('載入更多工作項目'));
    await tester.pumpAndSettle();

    expect(find.text('無法讀取回應'), findsNothing);
    expect(find.text('Customer follow-up'), findsOneWidget);
    expect(find.text('Duplicate page copy'), findsNothing);
  });

  testWidgets('project-only hierarchy resolves and verifies the REST project', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      if (!request.uri.path.endsWith('/api/graphql')) {
        return jsonResponse({
          'id': 42,
          'name': 'Example',
          'path_with_namespace': 'team/example',
          'visibility': 'private',
          'default_branch': 'main',
        });
      }
      final data = request.data as Map;
      final query = data['query'] as String;
      if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
      if (query.contains('MobileWorkItemState')) {
        final id = '${(data['variables'] as Map)['id']}';
        return _state(int.parse(id.split('/').last));
      }
      if (query.contains('MobileProjectWorkItems(')) return _projectList();
      if (query.contains('MobileProjectWorkItem(')) {
        final iid = int.parse('${(data['variables'] as Map)['iid']}');
        return _detail(iid: iid, projectOnlyChild: iid == 7);
      }
      return jsonResponse({'message': 'unhandled'}, status: 404);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api, 7), api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customer follow-up'));
    await settleNetworkWidgets(tester);
    await tester.scrollUntilVisible(find.text('Bounded child'), 260);
    await tester.pump();
    await tester.tap(find.text('Bounded child'));
    await settleNetworkWidgets(tester);

    expect(
      adapter.requests.any(
        (request) =>
            !request.uri.path.endsWith('/api/graphql') &&
            request.uri.pathSegments.last == 'team/example',
      ),
      isTrue,
    );
    expect(find.text('工作項目 #8'), findsOneWidget);
  });

  for (final replacement in ['account', 'generation', 'api']) {
    testWidgets(
      'visible graph routes clear and close after $replacement changes',
      (tester) async {
        final marker = _OwnerMarker();
        final capturedAccount = marker.account;
        final capturedGeneration = marker.generation;
        final capturedApi = marker.api;
        final adapter = FakeAdapter(_response);
        final api = testApi(adapter);
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => GraphWorkItemsPage(
                        account: _account(api, 7),
                        api: api,
                        project: _project,
                        ownerChanges: marker,
                        isCurrent: () =>
                            marker.account == capturedAccount &&
                            marker.generation == capturedGeneration &&
                            identical(marker.api, capturedApi),
                      ),
                    ),
                  ),
                  child: const Text('Open work items'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open work items'));
        await tester.pumpAndSettle();
        expect(find.text('Customer follow-up'), findsOneWidget);
        await tester.tap(find.text('Customer follow-up'));
        await settleNetworkWidgets(tester);
        expect(find.text('Native Markdown description'), findsOneWidget);

        switch (replacement) {
          case 'account':
            marker.account = 'second';
          case 'generation':
            marker.generation++;
          case 'api':
            marker.api = Object();
        }
        marker.changed();
        await tester.pumpAndSettle();

        expect(find.text('Open work items'), findsOneWidget);
        expect(find.text('Customer follow-up'), findsNothing);
        expect(find.text('Native Markdown description'), findsNothing);
      },
    );
  }

  testWidgets('visible unresolved 404 closes when its owner changes', (
    tester,
  ) async {
    final marker = _OwnerMarker();
    final capturedGeneration = marker.generation;
    final adapter = FakeAdapter((_) => jsonResponse({}, status: 404));
    final api = testApi(adapter);
    addTearDown(api.close);
    final account = _account(api, 7);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => ResourceNavigator(
                account,
                api,
                ownerChanges: marker,
                isCurrent: () => marker.generation == capturedGeneration,
              ).project(context, '77'),
              child: const Text('Open missing'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open missing'));
    await settleNetworkWidgets(tester);
    expect(find.text('無法開啟'), findsOneWidget);

    marker.generation++;
    marker.changed();
    await tester.pumpAndSettle();

    expect(find.text('Open missing'), findsOneWidget);
    expect(find.text('專案 77'), findsNothing);
  });

  for (final kind in _MetadataKind.values) {
    testWidgets(
      'scroll-recreated Attributes reads ${kind.name} once after held A terminal',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 700);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final server = _MetadataGraphServer();
        final api = testApi(server.adapter);
        addTearDown(api.close);
        final ack = Completer<void>();
        server.holdWriteAck = ack;
        final edit = find.byKey(ValueKey('work-item-${kind.name}-edit'));
        final save = find.byKey(ValueKey('work-item-${kind.name}-save'));
        final row = find.byKey(ValueKey('work-item-attribute-${kind.name}'));
        final other = kind == _MetadataKind.weight
            ? _MetadataKind.milestone
            : _MetadataKind.weight;
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: GraphWorkItemDetailPage.project(
                account: _account(api, 7),
                api: api,
                project: _project,
                iid: 7,
              ),
            ),
          );
          await pumpUntil(
            tester,
            () =>
                server.detailReads == 1 &&
                find.text('Customer follow-up').evaluate().isNotEmpty,
          );
          await settleNetworkWidgets(tester);
          await _scrollGraphUntil(
            tester,
            () => find.text('屬性').hitTestable().evaluate().isNotEmpty,
            down: true,
          );
          await tester.tap(find.text('屬性'));
          await pumpUntil(
            tester,
            () =>
                server.attributeReads[_MetadataKind.weight] == 1 &&
                server.attributeReads[_MetadataKind.milestone] == 1 &&
                edit.evaluate().isNotEmpty,
            description: 'panel A loads both metadata rows',
          );
          await tester.pump(const Duration(milliseconds: 300));
          final panelA = tester.state(find.byType(WorkItemAttributesPanel));

          tester.widget<TextButton>(edit).onPressed!.call();
          await pumpUntil(
            tester,
            () => save.evaluate().isNotEmpty,
            description: '${kind.name} editor opens',
          );
          await settleNetworkWidgets(tester);
          await tester.pump(const Duration(milliseconds: 300));
          if (kind == _MetadataKind.weight) {
            await tester.enterText(
              find.byKey(const ValueKey('work-item-weight-input')),
              '9',
            );
            await tester.pump();
          } else {
            await tester.tap(find.text('November'));
            await tester.pump();
          }
          await tester.tap(save);
          await pumpUntil(
            tester,
            () => server.writes == 1 && server.holdWriteAck == null,
            description: '${kind.name} write is held after apply',
          );
          final readsAtHandoff = server.attributeReads[kind]!;
          final editorContext = tester.element(save);
          Navigator.of(
            editorContext,
          ).removeRoute(ModalRoute.of(editorContext)!);
          await tester.pump();

          await _scrollGraphUntil(
            tester,
            () => find
                .byType(WorkItemAttributesPanel, skipOffstage: false)
                .evaluate()
                .isEmpty,
            down: true,
          );
          expect(panelA.mounted, isFalse);
          await _scrollGraphUntil(
            tester,
            () => find.text('屬性').hitTestable().evaluate().isNotEmpty,
            down: false,
          );
          final panelB = tester.state(find.byType(WorkItemAttributesPanel));
          expect(identical(panelA, panelB), isFalse);
          final otherReads = server.attributeReads[other]!;
          await tester.tap(find.text('屬性'));
          await pumpUntil(
            tester,
            () => server.attributeReads[other] == otherReads + 1,
            description: 'panel B reads the ungated ${other.name} row',
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(server.attributeReads[kind], readsAtHandoff);
          expect(
            find.descendant(of: row, matching: find.text('等待讀取')),
            findsOneWidget,
          );
          expect(tester.widget<TextButton>(edit).onPressed, isNull);

          ack.complete();
          await pumpUntil(
            tester,
            () =>
                server.attributeReads[kind] == readsAtHandoff + 1 &&
                find
                    .descendant(of: row, matching: find.text(kind.savedText))
                    .evaluate()
                    .isNotEmpty,
            description:
                'panel B shows the fresh ${kind.name} without collapse',
          );
          await settleNetworkWidgets(tester);
          expect(
            identical(
              tester.state(find.byType(WorkItemAttributesPanel)),
              panelB,
            ),
            isTrue,
          );
          expect(server.attributeReads[kind], readsAtHandoff + 1);
          expect(server.attributeReads[other], otherReads + 1);
          expect(server.writes, 1);
          expect(
            find.descendant(of: row, matching: find.text('等待讀取')),
            findsNothing,
          );
          expect(tester.widget<TextButton>(edit).onPressed, isNotNull);
          expect(tester.takeException(), isNull);
        } finally {
          if (!ack.isCompleted) ack.complete();
        }
      },
    );
  }

  testWidgets(
    'T11: 20 list rows render with 1 POST per page and zero individual detail calls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var listPostCount = 0;
      var detailPostCount = 0;

      final items = List.generate(
        20,
        (i) => {
          ..._summary(title: 'Work item row $i', iid: i + 1),
          'widgets': [
            {
              'type': 'LABELS',
              'labels': {
                'nodes': [
                  {
                    'id': 'gid://gitlab/ProjectLabel/$i',
                    'title': 'bug-$i',
                    'color': '#ff0000',
                  },
                ],
                'pageInfo': {'hasNextPage': false},
              },
            },
            {
              'type': 'START_AND_DUE_DATE',
              'startDate': '2026-10-01',
              'dueDate': '2026-10-15',
            },
          ],
        },
      );

      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          listPostCount++;
          return jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'fullPath': 'team/example',
                'workItems': _connection(items),
              },
            },
          });
        }
        if (query.contains('MobileProjectWorkItem(')) {
          detailPostCount++;
          return _detail();
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api));
      await settleNetworkWidgets(tester);

      expect(listPostCount, 1);
      expect(detailPostCount, 0);
      expect(find.text('Work item row 0'), findsOneWidget);
      expect(find.text('bug-0'), findsOneWidget);
      expect(find.text('2026/10/01 - 2026/10/15'), findsWidgets);
    },
  );

  testWidgets(
    'T12: Account or owner switch mid-flight paints nothing and resets display preferences',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final holdList = Completer<ResponseBody>();
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) return holdList.future;
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);
      var current = true;
      final owner = _OwnerMarker();

      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkItemsPage(
            account: _account(api, 7),
            api: api,
            project: _project,
            isCurrent: () => current,
            ownerChanges: owner,
          ),
        ),
      );
      await tester.pump();

      current = false;
      owner.changed();
      await tester.pump();

      holdList.complete(_projectList(title: 'Stale item'));
      await tester.pumpAndSettle();

      expect(find.text('Stale item'), findsNothing);
      expect(find.text('帳號已切換，工作項目頁面已關閉。'), findsOneWidget);
    },
  );

  testWidgets(
    'T13: Double-tapped load-more deduplicates to 1 request via _loadingItems',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var listCalls = 0;
      final holdMore = Completer<ResponseBody>();

      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          listCalls++;
          final vars = body['variables'] as Map;
          if (vars['after'] == null) {
            return jsonResponse({
              'data': {
                'project': {
                  'id': 'gid://gitlab/Project/42',
                  'fullPath': 'team/example',
                  'workItems': {
                    'nodes': [
                      {
                        ..._summary(title: 'Item 1', iid: 1),
                        'widgets': const <Object?>[],
                      },
                    ],
                    'pageInfo': {'hasNextPage': true, 'endCursor': 'page-2'},
                  },
                },
              },
            });
          }
          return holdMore.future;
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api));
      await settleNetworkWidgets(tester);

      final loadMoreFinder = find.text('載入更多工作項目');
      expect(loadMoreFinder, findsOneWidget);
      expect(listCalls, 1);

      await tester.ensureVisible(loadMoreFinder);
      await tester.pumpAndSettle();
      final loadMoreCenter = tester.getCenter(loadMoreFinder);
      await tester.tap(loadMoreFinder);
      await tester.pump();

      final disabledButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '載入更多工作項目'),
      );
      expect(disabledButton.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tapAt(loadMoreCenter);
      await pumpUntil(
        tester,
        () => listCalls == 2,
        description: 'load-more request started',
      );

      expect(listCalls, 2);

      holdMore.complete(
        jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/42',
              'fullPath': 'team/example',
              'workItems': {
                'nodes': [
                  {
                    ..._summary(title: 'Item 2', iid: 2),
                    'widgets': const <Object?>[],
                  },
                ],
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        }),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('Item 2'), findsOneWidget);
    },
  );

  testWidgets(
    'T14: Toggling display switches sends 0 network calls and toggles chips instantly',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var networkCalls = 0;
      final adapter = FakeAdapter((request) {
        networkCalls++;
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          return jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'fullPath': 'team/example',
                'workItems': _connection([
                  {
                    ..._summary(title: 'Item with label', iid: 10),
                    'widgets': [
                      {
                        'type': 'LABELS',
                        'labels': {
                          'nodes': [
                            {
                              'id': 'gid://gitlab/ProjectLabel/9',
                              'title': 'visible-label',
                              'color': '#123456',
                            },
                          ],
                          'pageInfo': {'hasNextPage': false},
                        },
                      },
                    ],
                  },
                ]),
              },
            },
          });
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api));
      await settleNetworkWidgets(tester);

      expect(find.text('visible-label'), findsOneWidget);
      final callsBeforeSheet = networkCalls;

      await tester.tap(find.byKey(const Key('graph-work-items-display-options-button')));
      await tester.pumpAndSettle();

      expect(find.text('顯示設定'), findsOneWidget);
      expect(networkCalls, callsBeforeSheet);

      final labelsSwitch = find.widgetWithText(SwitchListTile, '標籤');
      expect(labelsSwitch, findsOneWidget);
      await tester.tap(labelsSwitch);
      await tester.pump();

      expect(networkCalls, callsBeforeSheet);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text('visible-label'), findsNothing);
      expect(networkCalls, callsBeforeSheet);
    },
  );

  testWidgets(
    'T15: T2 disables status, T3 disables all 6, 6 browser options unsupported across all tiers, 3-POST downgrade supported',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var projectCallCount = 0;
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          projectCallCount++;
          if (projectCallCount == 1) {
            return jsonResponse({
              'data': null,
              'errors': [
                {
                  'message': 'Type WorkItemWidgetStatus is unknown',
                  'extensions': {
                    'code': 'undefinedType',
                    'typeName': 'WorkItemWidgetStatus',
                  },
                },
              ],
            });
          } else if (projectCallCount == 2) {
            return jsonResponse({
              'data': null,
              'errors': [
                {
                  'message': 'Field widgets is unknown',
                  'extensions': {
                    'code': 'undefinedField',
                  },
                },
              ],
            });
          }
          return jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'fullPath': 'team/example',
                'workItems': _connection([_summary()]),
              },
            },
          });
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api));
      await settleNetworkWidgets(tester);

      expect(projectCallCount, 3);

      await tester.tap(find.byKey(const Key('graph-work-items-display-options-button')));
      await tester.pumpAndSettle();

      final sheetScrollable = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ).first;

      const supportedTitles = ['標籤', '指派對象', '里程碑', '起訖日期', '階層關係', '工作流程狀態'];
      for (final title in supportedTitles) {
        final tileFinder = find.widgetWithText(SwitchListTile, title);
        await tester.scrollUntilVisible(tileFinder, 50.0, scrollable: sheetScrollable);
        expect(tileFinder, findsOneWidget);
        final tile = tester.widget<SwitchListTile>(tileFinder);
        expect(tile.onChanged, isNull);
        expect(
          find.descendant(of: tileFinder, matching: find.text('此實例未提供')),
          findsOneWidget,
        );
      }

      const unsupportedTitles = ['阻礙項目', '留言數', '健康狀態', '疊代', '熱門度', '權重'];
      for (final title in unsupportedTitles) {
        final tileFinder = find.widgetWithText(SwitchListTile, title);
        await tester.scrollUntilVisible(tileFinder, 50.0, scrollable: sheetScrollable);
        expect(tileFinder, findsOneWidget);
        final tile = tester.widget<SwitchListTile>(tileFinder);
        expect(tile.onChanged, isNull);
        expect(
          find.descendant(of: tileFinder, matching: find.text('尚未支援')),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets(
    'T16: 320dp 2.0x text scaling has zero overflow and 390x844 viewport operates smoothly',
    (tester) async {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(320 * 2.0, 640 * 2.0);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          return jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'fullPath': 'team/example',
                'workItems': _connection([
                  {
                    ..._summary(
                      title:
                          'Very long title that might overflow narrow screens with large font scale',
                      iid: 1,
                    ),
                    'widgets': [
                      {
                        'type': 'STATUS',
                        'status': {
                          'id': 'gid://gitlab/WorkItems::Widgets::Status/1',
                          'name': 'In Development',
                        },
                      },
                      {
                        'type': 'LABELS',
                        'labels': {
                          'nodes': [
                            {
                              'id': 'gid://gitlab/ProjectLabel/1',
                              'title':
                                  'extremely-long-label-title-that-stretches',
                              'color': '#ff00aa',
                            },
                          ],
                          'pageInfo': {
                            'hasNextPage': true,
                            'endCursor': 'label-cursor',
                          },
                        },
                      },
                      {
                        'type': 'ASSIGNEES',
                        'assignees': {
                          'nodes': [
                            {
                              'id': 'gid://gitlab/User/1',
                              'name': 'Alice Engineer',
                              'username': 'alice',
                              'avatarUrl': null,
                            },
                          ],
                          'pageInfo': {
                            'hasNextPage': true,
                            'endCursor': 'assignee-cursor',
                          },
                        },
                      },
                      {
                        'type': 'MILESTONE',
                        'milestone': {
                          'id': 'gid://gitlab/Milestone/1',
                          'title': 'Long Milestone Title 2026',
                        },
                      },
                      {
                        'type': 'START_AND_DUE_DATE',
                        'startDate': '2026-10-01',
                        'dueDate': '2026-10-31',
                      },
                      {
                        'type': 'HIERARCHY',
                        'hasParent': true,
                        'parent': {
                          'id': 'gid://gitlab/WorkItem/99',
                          'iid': '99',
                          'title': 'Parent epic',
                          'workItemType': {
                            'id': 'gid://gitlab/WorkItems::Type/1',
                            'name': 'Epic',
                          },
                        },
                      },
                    ],
                  },
                ]),
              },
            },
          });
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api, scale: 2.0));
      await settleNetworkWidgets(tester);

      expect(find.text('In Development'), findsOneWidget);
      expect(
        find.text('extremely-long-label-title-that-stretches'),
        findsOneWidget,
      );
      expect(find.text('Alice Engineer'), findsOneWidget);
      expect(find.text('Long Milestone Title 2026'), findsOneWidget);
      expect(find.text('2026/10/01 - 2026/10/31'), findsOneWidget);
      expect(find.text('Epic #99'), findsOneWidget);
      expect(find.bySemanticsLabel('還有更多，未載入'), findsNWidgets(2));
      expect(find.text('更多'), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const Key('graph-work-items-display-options-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('顯示設定'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final sheetScrollable = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ).first;

      final supportedToggles = [
        ('工作流程狀態', 'In Development'),
        ('標籤', 'extremely-long-label-title-that-stretches'),
        ('指派對象', 'Alice Engineer'),
        ('里程碑', 'Long Milestone Title 2026'),
        ('起訖日期', '2026/10/01 - 2026/10/31'),
        ('階層關係', 'Epic #99'),
      ];

      for (var i = 0; i < supportedToggles.length; i++) {
        final (title, chipText) = supportedToggles[i];
        final tileFinder = find.widgetWithText(SwitchListTile, title);
        for (var step = 0; step < 20 && tileFinder.evaluate().isEmpty; step++) {
          await tester.drag(sheetScrollable, const Offset(0, 100));
          await tester.pump(const Duration(milliseconds: 50));
        }
        for (var step = 0; step < 20 && tileFinder.evaluate().isEmpty; step++) {
          await tester.drag(sheetScrollable, const Offset(0, -100));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.ensureVisible(tileFinder);
        await tester.tap(tileFinder);
        await tester.pumpAndSettle();
        expect(find.text(chipText), findsNothing);
        if (i == 2) {
          expect(find.text('更多'), findsNothing);
          expect(find.bySemanticsLabel('還有更多，未載入'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('顯示設定'), findsNothing);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(390 * 2.0, 844 * 2.0);
      await tester.pumpWidget(_host(_account(api, 7), api, scale: 1.0));
      await settleNetworkWidgets(tester);

      await tester.tap(
        find.byKey(const Key('graph-work-items-display-options-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('顯示設定'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'T15_t2: T2 disables only status, 5 summary toggles enabled, 6 unsupported disabled',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var projectCallCount = 0;
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          projectCallCount++;
          if (projectCallCount == 1) {
            return jsonResponse({
              'data': null,
              'errors': [
                {
                  'message': 'Type WorkItemWidgetStatus is unknown',
                  'extensions': {
                    'code': 'undefinedType',
                    'typeName': 'WorkItemWidgetStatus',
                  },
                },
              ],
            });
          }
          return jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'fullPath': 'team/example',
                'workItems': _connection([_summary()]),
              },
            },
          });
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api));
      await settleNetworkWidgets(tester);

      expect(projectCallCount, 2);

      await tester.tap(
        find.byKey(const Key('graph-work-items-display-options-button')),
      );
      await tester.pumpAndSettle();

      final statusTile =
          tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '工作流程狀態'));
      expect(statusTile.onChanged, isNull);

      final labelsTile =
          tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '標籤'));
      expect(labelsTile.onChanged, isNotNull);
      final assigneesTile =
          tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '指派對象'));
      expect(assigneesTile.onChanged, isNotNull);
      final milestoneTile =
          tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '里程碑'));
      expect(milestoneTile.onChanged, isNotNull);
      final datesTile =
          tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '起訖日期'));
      expect(datesTile.onChanged, isNotNull);
      final hierarchyTile =
          tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '階層關係'));
      expect(hierarchyTile.onChanged, isNotNull);

      final sheetScrollable = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ).first;
      const unsupportedTitles = ['阻礙項目', '留言數', '健康狀態', '疊代', '熱門度', '權重'];
      for (final title in unsupportedTitles) {
        final tileFinder = find.widgetWithText(SwitchListTile, title);
        await tester.scrollUntilVisible(tileFinder, 50.0, scrollable: sheetScrollable);
        final tile = tester.widget<SwitchListTile>(tileFinder);
        expect(tile.onChanged, isNull);
      }
    },
  );

  testWidgets(
    'RQ9: held A response and account B switch while display labels toggled off sheet owned results in B reset, actual tier, no A paint, and dismissed sheet',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var listCallsA = 0;
      final holdContinuationA = Completer<ResponseBody>();
      final adapterA = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          listCallsA++;
          final vars = body['variables'] as Map;
          if (vars['after'] == null) {
            return jsonResponse({
              'data': {
                'project': {
                  'id': 'gid://gitlab/Project/42',
                  'fullPath': 'team/example',
                  'workItems': {
                    'nodes': [
                      {
                        ..._summary(title: 'Item A', iid: 1),
                        'widgets': [
                          {
                            'type': 'STATUS',
                            'status': {
                              'id': 'gid://gitlab/WorkItems::Widgets::Status/1',
                              'name': 'In Development',
                            },
                          },
                          {
                            'type': 'LABELS',
                            'labels': {
                              'nodes': [
                                {
                                  'id': 'gid://gitlab/ProjectLabel/1',
                                  'title': 'a-label',
                                  'color': '#112233',
                                },
                              ],
                              'pageInfo': {'hasNextPage': false},
                            },
                          },
                        ],
                      },
                    ],
                    'pageInfo': {'hasNextPage': true, 'endCursor': 'page-2'},
                  },
                },
              },
            });
          }
          return holdContinuationA.future;
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final adapterB = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          return jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'fullPath': 'team/example',
                'workItems': _connection([
                  {
                    ..._summary(title: 'Item B', iid: 2),
                    'widgets': [
                      {
                        'type': 'STATUS',
                        'status': {
                          'id': 'gid://gitlab/WorkItems::Widgets::Status/2',
                          'name': 'In Review',
                        },
                      },
                      {
                        'type': 'LABELS',
                        'labels': {
                          'nodes': [
                            {
                              'id': 'gid://gitlab/ProjectLabel/2',
                              'title': 'b-label',
                              'color': '#334455',
                            },
                          ],
                          'pageInfo': {'hasNextPage': false},
                        },
                      },
                    ],
                  },
                ]),
              },
            },
          });
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final apiA = testApi(adapterA);
      final apiB = testApi(adapterB);
      addTearDown(apiA.close);
      addTearDown(apiB.close);

      var current = true;
      final owner = _OwnerMarker();

      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkItemsPage(
            account: _account(apiA, 7),
            api: apiA,
            project: _project,
            isCurrent: () => current,
            ownerChanges: owner,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('Item A'), findsOneWidget);
      expect(find.text('a-label'), findsOneWidget);
      expect(listCallsA, 1);

      final loadMoreFinder = find.text('載入更多工作項目');
      expect(loadMoreFinder, findsOneWidget);
      await tester.ensureVisible(loadMoreFinder);
      await tester.pumpAndSettle();
      await tester.tap(loadMoreFinder);
      await pumpUntil(
        tester,
        () => listCallsA == 2,
        description: 'held account A second read started',
      );
      expect(listCallsA, 2);

      await tester.tap(
        find.byKey(const Key('graph-work-items-display-options-button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('顯示設定'), findsOneWidget);

      final labelsSwitch = find.widgetWithText(SwitchListTile, '標籤');
      expect(labelsSwitch, findsOneWidget);
      final switchWidget = tester.widget<SwitchListTile>(labelsSwitch);
      expect(switchWidget.onChanged, isNotNull);
      await tester.tap(labelsSwitch);
      await tester.pump();
      expect(find.text('a-label'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: GraphWorkItemsPage(
            account: _account(apiB, 8),
            api: apiB,
            project: _project,
            isCurrent: () => current,
            ownerChanges: owner,
          ),
        ),
      );
      await tester.pump();

      holdContinuationA.complete(
        jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/42',
              'fullPath': 'team/example',
              'workItems': {
                'nodes': [
                  {
                    ..._summary(title: 'Item A2', iid: 11),
                    'widgets': [
                      {
                        'type': 'LABELS',
                        'labels': {
                          'nodes': [
                            {
                              'id': 'gid://gitlab/ProjectLabel/11',
                              'title': 'a-label-2',
                              'color': '#112233',
                            },
                          ],
                          'pageInfo': {'hasNextPage': false},
                        },
                      },
                    ],
                  },
                ],
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        }),
      );
      await tester.pumpAndSettle();

      expect(find.text('Item A'), findsNothing);
      expect(find.text('Item A2'), findsNothing);
      expect(find.text('a-label'), findsNothing);
      expect(find.text('a-label-2'), findsNothing);
      expect(find.text('Item B'), findsOneWidget);
      expect(find.text('b-label'), findsOneWidget);
      expect(find.text('顯示設定'), findsNothing);

      await tester.tap(
        find.byKey(const Key('graph-work-items-display-options-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('顯示設定'), findsOneWidget);

      final statusTile =
          tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '工作流程狀態'));
      expect(statusTile.onChanged, isNotNull);
    },
  );

  testWidgets(
    'A7: unknown tier disables all 12 switches and double tap deduplicates sheet route',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final holdList = Completer<ResponseBody>();
      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) return holdList.future;
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api));
      await tester.pump();

      final button =
          find.byKey(const Key('graph-work-items-display-options-button'));
      expect(button, findsOneWidget);
      final buttonCenter = tester.getCenter(button);
      final nav = Navigator.of(tester.element(button));
      expect(nav.canPop(), isFalse);

      await tester.tap(button);
      expect(nav.canPop(), isTrue);

      await tester.tapAt(buttonCenter);
      expect(nav.canPop(), isTrue);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('顯示設定'), findsOneWidget);

      final sheetScrollable = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ).first;

      const allTitles = [
        '標籤',
        '指派對象',
        '里程碑',
        '起訖日期',
        '階層關係',
        '工作流程狀態',
        '阻礙項目',
        '留言數',
        '健康狀態',
        '疊代',
        '熱門度',
        '權重',
      ];
      for (final title in allTitles) {
        final tileFinder = find.widgetWithText(SwitchListTile, title);
        await tester.scrollUntilVisible(tileFinder, 50.0, scrollable: sheetScrollable);
        expect(tileFinder, findsOneWidget);
        final tile = tester.widget<SwitchListTile>(tileFinder);
        expect(tile.onChanged, isNull);
      }

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('顯示設定'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(nav.canPop(), isFalse);

      holdList.complete(_projectList());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'A8: closed work item preserves closed StatusBadge and appends workflow status chip',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final adapter = FakeAdapter((request) {
        final body = request.data as Map;
        final query = body['query'] as String;
        if (query.contains('MobileNamespaceWorkItemTypes')) return _types();
        if (query.contains('MobileProjectWorkItems(')) {
          return jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'fullPath': 'team/example',
                'workItems': _connection([
                  {
                    ..._summary(title: 'Closed Item', iid: 55),
                    'state': 'CLOSED',
                    'widgets': [
                      {
                        'type': 'STATUS',
                        'status': {
                          'id': 'gid://gitlab/WorkItems::Widgets::Status/1',
                          'name': 'Done',
                        },
                      },
                    ],
                  },
                ]),
              },
            },
          });
        }
        return jsonResponse({'message': 'unhandled'}, status: 404);
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api, 7), api));
      await settleNetworkWidgets(tester);

      expect(find.text('Closed Item'), findsOneWidget);
      expect(find.text('已關閉'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    },
  );
}

enum _MetadataKind {
  weight('權重：9'),
  milestone('November');

  const _MetadataKind(this.savedText);

  final String savedText;
}

Future<void> _scrollGraphUntil(
  WidgetTester tester,
  bool Function() done, {
  required bool down,
}) async {
  for (var step = 0; step < 40; step++) {
    if (done()) return;
    await tester.drag(
      find.byType(Scrollable).last,
      Offset(0, down ? -320 : 320),
    );
    await tester.pump();
  }
  expect(done(), isTrue);
}

Map<String, Object?> _graphMilestone(int id, String title) => {
  'id': 'gid://gitlab/Milestone/$id',
  'iid': '$id',
  'title': title,
  'state': 'ACTIVE',
  'expired': false,
  'dueDate': '2026-10-31',
  'startDate': '2026-10-01',
  'webPath': '/team/example/-/milestones/$id',
  'project': {'id': 'gid://gitlab/Project/42', 'fullPath': 'team/example'},
  'group': null,
};

final class _MetadataGraphServer {
  int weight = 4;
  Map<String, Object?>? milestone = _graphMilestone(5, 'October');
  final choices = [_graphMilestone(6, 'November')];
  String updatedAt = '2026-09-02T03:04:05Z';
  Completer<void>? holdWriteAck;
  int detailReads = 0;
  int writes = 0;
  final attributeReads = {for (final kind in _MetadataKind.values) kind: 0};
  late final FakeAdapter adapter = FakeAdapter(_respond);

  Map<String, Object?> get _weightWidget => {
    'type': 'WEIGHT',
    'weight': weight,
    'rolledUpWeight': 10,
    'rolledUpCompletedWeight': 3,
  };

  Map<String, Object?> get _milestoneWidget => {
    'type': 'MILESTONE',
    'milestone': milestone,
  };

  Map<String, Object?> _item(
    List<Object?> widgets, {
    Map<String, Object?>? permissions,
  }) => {
    ..._summary(),
    'updatedAt': updatedAt,
    'userPermissions': ?permissions,
    'widgets': widgets,
  };

  static const _weightPermissions = {
    'readWorkItem': true,
    'adminWorkItem': true,
  };
  static const _milestonePermissions = {
    'readWorkItem': true,
    'setWorkItemMetadata': true,
  };

  Future<ResponseBody> _respond(RequestOptions request) async {
    final body = request.data as Map;
    final query = body['query'] as String;
    if (query.contains('query MobileProjectWorkItem(')) {
      detailReads++;
      return jsonResponse({
        'data': {
          'project': {
            'id': 'gid://gitlab/Project/42',
            'fullPath': 'team/example',
            'workItems': _connection([
              _item(
                [
                  _weightWidget,
                  _milestoneWidget,
                  {
                    'type': 'HIERARCHY',
                    'hasParent': false,
                    'hasChildren': true,
                    'parent': null,
                    'children': _connection([
                      for (var iid = 8; iid < 28; iid++)
                        _summary(title: 'Scroll child $iid', iid: iid),
                    ]),
                  },
                ],
                permissions: const {'readWorkItem': true},
              ),
            ]),
          },
        },
      });
    }
    if (query.contains('query MobileWorkItemWeightAttribute(')) {
      attributeReads[_MetadataKind.weight] =
          attributeReads[_MetadataKind.weight]! + 1;
      return jsonResponse({
        'data': {
          'workItem': _item([_weightWidget], permissions: _weightPermissions),
        },
      });
    }
    if (query.contains('query MobileWorkItemMilestoneAttribute(')) {
      attributeReads[_MetadataKind.milestone] =
          attributeReads[_MetadataKind.milestone]! + 1;
      return jsonResponse({
        'data': {
          'workItem': _item([_milestoneWidget]),
        },
      });
    }
    if (query.contains('query MobileWorkItemWeight(')) {
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'workItem': _item([_weightWidget], permissions: _weightPermissions),
        },
      });
    }
    if (query.contains('query MobileWorkItemMilestone(')) {
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'workItem': _item([
            _milestoneWidget,
          ], permissions: _milestonePermissions),
        },
      });
    }
    if (query.contains('query MobileProjectWorkItemMilestones(')) {
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'project': {
            'id': 'gid://gitlab/Project/42',
            'fullPath': 'team/example',
            'milestones': _connection(choices),
          },
        },
      });
    }
    final weightWrite = query.contains('mutation MobileSetWorkItemWeight(');
    final milestoneWrite = query.contains(
      'mutation MobileSetWorkItemMilestone(',
    );
    if (weightWrite || milestoneWrite) {
      writes++;
      final input = (body['variables'] as Map)['input'] as Map;
      if (weightWrite) {
        weight = (input['weightWidget'] as Map)['weight'] as int;
      } else {
        final id = (input['milestoneWidget'] as Map)['milestoneId'];
        milestone = choices.singleWhere((item) => item['id'] == id);
      }
      updatedAt = '2026-09-02T03:06:00Z';
      final ack = holdWriteAck;
      holdWriteAck = null;
      if (ack != null) await ack.future;
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': weightWrite
                ? _item([_weightWidget], permissions: _weightPermissions)
                : _item([_milestoneWidget]),
          },
        },
      });
    }
    return jsonResponse({'message': 'unhandled'}, status: 404);
  }
}
