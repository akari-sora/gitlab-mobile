import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/navigation.dart';
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
    await tester.drag(find.byType(ListView).last, const Offset(0, -320));
    await tester.pumpAndSettle();
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
}
