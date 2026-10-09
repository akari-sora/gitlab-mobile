import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/rest_issue_graph_bridge.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

final class _BridgeWidgetFixture {
  _BridgeWidgetFixture({
    this.widgetsAvailable = true,
    Set<String>? widgetTypes,
    this.parentIid,
    this.parentTitle,
    this.startDate,
    this.statusName = 'In progress',
    this.schemaUnsupported = false,
    this.projectNull = false,
    this.nullWorkItemsConnection = false,
    this.duplicateNodes = false,
    this.wrongProjectGid = false,
    this.typeId = 'gid://gitlab/WorkItems::Type/1',
    this.typeName = 'Issue',
    this.instanceSubpath = '/gitlab',
    this.healthStatus = 'onTrack',
    this.failHealth = false,
    this.iterationTitle = 'Sprint 1',
    this.failIteration = false,
    this.delayHealth,
    this.delayIteration,
  }) : widgetTypes = widgetTypes ?? {'STATUS', 'HIERARCHY', 'START_AND_DUE_DATE'};

  final bool widgetsAvailable;
  Set<String> widgetTypes;
  int? parentIid;
  String? parentTitle;
  DateTime? startDate;
  String? statusName;
  bool failDetail = false;
  bool failStatus = false;
  bool schemaUnsupported;
  bool projectNull;
  bool nullWorkItemsConnection;
  bool duplicateNodes;
  bool wrongProjectGid;
  bool wrongProjectFullPath = false;
  String typeId;
  String typeName;
  String instanceSubpath;
  Completer<void>? delayDetail;
  String? healthStatus;
  bool failHealth;
  String? iterationTitle;
  bool failIteration;
  Completer<void>? delayHealth;
  Completer<void>? delayIteration;
  Completer<void>? delayStatus;

  int concurrentLazy = 0;
  int maxConcurrentLazy = 0;

  final requests = <RequestOptions>[];
  late final adapter = FakeAdapter(_respond);
  late final api = testApi(adapter, host: 'https://example.com$instanceSubpath');

  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'testuser', name: 'Test User'),
    token: 'synthetic-token',
  );

  Project get project => const Project(id: 42, name: 'Project 42', path: 'team/example');

  FutureOr<ResponseBody> _respond(RequestOptions request) async {
    requests.add(request);
    if (request.method == 'POST' && request.uri == api.instance.graphQL) {
      final body = request.data is Json ? request.data as Json : <String, dynamic>{};
      final query = body['query'] as String? ?? '';
      final variables = body['variables'] is Json ? body['variables'] as Json : <String, dynamic>{};

      if (query.startsWith('query MobileProjectWorkItem(')) {
        if (delayDetail != null) {
          await delayDetail!.future;
        }
        if (schemaUnsupported) {
          return jsonResponse({
            'errors': [
              {
                'message': 'Field missing on WorkItem',
                'extensions': {'code': 'undefinedField'},
              },
            ],
          }, status: 200);
        }
        if (failDetail) {
          return jsonResponse({'message': 'Internal Server Error'}, status: 500);
        }
        if (projectNull) {
          return jsonResponse({'data': {'project': null}});
        }
        if (nullWorkItemsConnection) {
          return jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'fullPath': project.path,
                'workItems': null,
              },
            },
          });
        }
        final iid = variables['iid'] as String? ?? '';
        final pId = wrongProjectGid ? 'gid://gitlab/Project/999' : 'gid://gitlab/Project/42';
        final pPath = wrongProjectFullPath ? 'wrong/path' : project.path;
        const namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/142';

        final node = {
          'id': 'gid://gitlab/WorkItem/$iid',
          'iid': iid,
          'title': 'Test Work Item $iid',
          'state': 'OPEN',
          'createdAt': '2026-09-01T01:02:03Z',
          'updatedAt': '2026-09-01T01:02:03Z',
          'project': {'id': pId, 'fullPath': pPath},
          'namespace': {'id': namespaceId, 'fullPath': pPath},
          'workItemType': {'id': typeId, 'name': typeName},
          'description': 'Description of work item $iid',
          'widgets': !widgetsAvailable
              ? null
              : [
                  if (widgetTypes.contains('STATUS')) {'type': 'STATUS'},
                  if (widgetTypes.contains('HIERARCHY'))
                    {
                      'type': 'HIERARCHY',
                      'hasParent': parentIid != null,
                      'hasChildren': false,
                      'parent': parentIid == null
                          ? null
                          : {
                              'id': 'gid://gitlab/WorkItem/$parentIid',
                              'iid': '$parentIid',
                              'title': parentTitle ?? 'Parent $parentIid',
                              'state': 'OPEN',
                              'createdAt': '2026-09-01T01:02:03Z',
                              'updatedAt': '2026-09-01T01:02:03Z',
                              'project': {'id': pId, 'fullPath': pPath},
                              'namespace': {'id': namespaceId, 'fullPath': pPath},
                              'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Issue'},
                            },
                      'children': {'nodes': <Json>[], 'pageInfo': {'hasNextPage': false, 'endCursor': null}},
                    },
                  if (widgetTypes.contains('START_AND_DUE_DATE'))
                    {
                      'type': 'START_AND_DUE_DATE',
                      'startDate': startDate?.toIso8601String().split('T').first,
                      'dueDate': null,
                      'rollUp': false,
                    },
                  if (widgetTypes.contains('HEALTH_STATUS')) {'type': 'HEALTH_STATUS'},
                  if (widgetTypes.contains('ITERATION')) {'type': 'ITERATION'},
                ],
        };

        return jsonResponse({
          'data': {
            'project': {
              'id': pId,
              'fullPath': pPath,
              'workItems': {
                'nodes': duplicateNodes ? [node, node] : [node],
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        });
      }

      if (query.startsWith('query MobileWorkItemStatusAttribute(')) {
        if (delayStatus != null) {
          await delayStatus!.future;
        }
        if (failStatus) {
          return jsonResponse({'message': 'status error'}, status: 500);
        }
        final id = variables['id'] as String? ?? 'gid://gitlab/WorkItem/7';
        return jsonResponse({
          'data': {
            'workItem': {
              'id': id,
              'iid': '7',
              'project': {'id': 'gid://gitlab/Project/42', 'fullPath': project.path},
              'namespace': {'id': 'gid://gitlab/Namespaces::ProjectNamespace/142', 'fullPath': project.path},
              'widgets': [
                {
                  'type': 'STATUS',
                  'status': statusName == null
                      ? null
                      : {
                          'id': 'gid://gitlab/WorkItems::Widgets::Status/1',
                          'name': statusName,
                          'iconName': 'status_scheduled',
                          'color': '#1f75cb',
                          'category': 'IN_PROGRESS',
                        },
                },
              ],
            },
          },
        });
      }

      if (query.startsWith('query MobileWorkItemHealthAttribute(')) {
        concurrentLazy++;
        if (concurrentLazy > maxConcurrentLazy) maxConcurrentLazy = concurrentLazy;
        try {
          if (delayHealth != null) {
            await delayHealth!.future;
          }
          if (failHealth) {
            return jsonResponse({'message': 'health error'}, status: 500);
          }
          final id = variables['id'] as String? ?? 'gid://gitlab/WorkItem/7';
          return jsonResponse({
            'data': {
              'workItem': {
                'id': id,
                'iid': '7',
                'project': {'id': 'gid://gitlab/Project/42', 'fullPath': project.path},
                'namespace': {'id': 'gid://gitlab/Namespaces::ProjectNamespace/142', 'fullPath': project.path},
                'widgets': [
                  {
                    'type': 'HEALTH_STATUS',
                    'healthStatus': healthStatus,
                    'rolledUpHealthStatus': null,
                  },
                ],
              },
            },
          });
        } finally {
          concurrentLazy--;
        }
      }

      if (query.startsWith('query MobileWorkItemIterationAttribute(')) {
        concurrentLazy++;
        if (concurrentLazy > maxConcurrentLazy) maxConcurrentLazy = concurrentLazy;
        try {
          if (delayIteration != null) {
            await delayIteration!.future;
          }
          if (failIteration) {
            return jsonResponse({'message': 'iteration error'}, status: 500);
          }
          final id = variables['id'] as String? ?? 'gid://gitlab/WorkItem/7';
          return jsonResponse({
            'data': {
              'workItem': {
                'id': id,
                'iid': '7',
                'project': {'id': 'gid://gitlab/Project/42', 'fullPath': project.path},
                'namespace': {'id': 'gid://gitlab/Namespaces::ProjectNamespace/142', 'fullPath': project.path},
                'widgets': [
                  {
                    'type': 'ITERATION',
                    'iteration': iterationTitle == null
                        ? null
                        : {
                            'id': 'gid://gitlab/Iteration/1',
                            'iid': 1,
                            'title': iterationTitle,
                            'state': 'opened',
                            'webUrl': 'https://example.com/gitlab/iteration/1',
                            'startDate': '2026-10-01',
                            'dueDate': '2026-10-15',
                            'group': {'id': 'gid://gitlab/Group/1', 'fullPath': 'team'},
                            'iterationCadence': {'id': 'gid://gitlab/Cadence/1', 'title': 'Two-week'},
                          },
                  },
                ],
              },
            },
          });
        } finally {
          concurrentLazy--;
        }
      }
    }
    return jsonResponse({'message': '404 Not Found'}, status: 404);
  }
}

Widget _wrapBridge({
  required _BridgeWidgetFixture fixture,
  int graphEpoch = 1,
  int graphReadyEpoch = 1,
  Key? bridgeKey,
  int generation = 0,
  VoidCallback? onOpenEditor,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: RestIssueGraphBridge(
          key: bridgeKey ??
              ValueKey(
                'rest-issue-graph-bridge/${fixture.account.key}/${fixture.project.id}/7/$generation',
              ),
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 7,
          graphEpoch: graphEpoch,
          graphReadyEpoch: graphReadyEpoch,
          onOpenEditor: onOpenEditor ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('TC-BW-01: Loads one project work item read after REST data and paints workflow status separately from lifecycle with no bridge status badge', (tester) async {
    final fixture = _BridgeWidgetFixture(
      parentIid: 9,
      parentTitle: 'Parent 9',
      startDate: DateTime(2026, 10, 1),
      statusName: 'In progress',
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(fixture.requests.length, 2);
    expect(find.byType(StatusBadge), findsNothing);
    expect(find.text('工作流程狀態'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.textContaining('#9'), findsOneWidget);
    expect(find.text('2026/10/01'), findsOneWidget);
  });

  testWidgets('TC-BW-02: Defers health and iteration reads until expanded with at most two concurrent', (tester) async {
    final delayHealth = Completer<void>();
    final delayIteration = Completer<void>();
    final fixture = _BridgeWidgetFixture(
      widgetTypes: {'STATUS', 'HEALTH_STATUS', 'ITERATION'},
      delayHealth: delayHealth,
      delayIteration: delayIteration,
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(fixture.requests.length, 2); // detail + status only
    await tester.tap(find.text('展開其他欄位'));
    await pumpUntil(tester, () => fixture.maxConcurrentLazy > 0);

    expect(fixture.maxConcurrentLazy, inInclusiveRange(1, 2));

    delayHealth.complete();
    delayIteration.complete();
    await settleNetworkWidgets(tester);

    expect(fixture.requests.length, 4); // +2 for health & iteration
    expect(find.text('目前：正常'), findsOneWidget);
    expect(find.text('Sprint 1'), findsOneWidget);
  });

  testWidgets('TC-BW-03: Schema unsupported shows instance-unsupported notice not permission using actual GraphQL failure wording', (tester) async {
    final fixture = _BridgeWidgetFixture(schemaUnsupported: true);
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(find.text('實例未提供原生工作項目'), findsOneWidget);
    expect(find.text('這個 GitLab 版本不支援所需的唯讀欄位。'), findsOneWidget);
    expect(find.text('無法讀取回應'), findsNothing);
    expect(find.text('沒有操作權限'), findsNothing);
    expect(find.widgetWithText(TextButton, '重新整理'), findsOneWidget);
  });

  testWidgets('TC-BW-04: Project null shows ambiguous 404 with account instance resource retry and switch', (tester) async {
    final fixture = _BridgeWidgetFixture(projectNull: true);
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(find.textContaining('team/example · #7 · 工作項目欄位'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重新整理'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
  });

  testWidgets('TC-BW-05: Null workItems connection shows permission notice', (tester) async {
    final fixture = _BridgeWidgetFixture(nullWorkItemsConnection: true);
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(find.text('沒有操作權限'), findsOneWidget);
    expect(find.text('實例未提供原生工作項目'), findsNothing);
  });

  testWidgets('TC-BW-06: Fresh success then refresh failure fails closed and clears previous Graph values including lazy cache, then retry restores rows', (tester) async {
    final fixture = _BridgeWidgetFixture(
      widgetTypes: {'STATUS', 'HEALTH_STATUS', 'ITERATION'},
      statusName: 'In progress',
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixture, graphEpoch: 1, graphReadyEpoch: 1));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('展開其他欄位'));
    await settleNetworkWidgets(tester);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Sprint 1'), findsOneWidget);

    // Step 2: Bump graphEpoch with failing API
    fixture.failDetail = true;
    await tester.pumpWidget(_wrapBridge(fixture: fixture, graphEpoch: 2, graphReadyEpoch: 2));
    await settleNetworkWidgets(tester);

    expect(find.text('In progress'), findsNothing);
    expect(find.text('Sprint 1'), findsNothing);
    expect(find.byType(FailureNotice), findsOneWidget);

    // Step 3: Retry restores all rows
    fixture.failDetail = false;
    await tester.tap(find.widgetWithText(TextButton, '重新整理'));
    await settleNetworkWidgets(tester);

    expect(find.text('In progress'), findsOneWidget);
  });

  testWidgets('TC-BW-07: Duplicate matching nodes fail closed as inconsistent data', (tester) async {
    final fixture = _BridgeWidgetFixture(duplicateNodes: true);
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(find.text('無法讀取回應'), findsOneWidget);
    expect(find.text('工作流程狀態'), findsNothing);
  });

  testWidgets('TC-BW-08: Wrong project gid or fullPath fails closed via API deserializer', (tester) async {
    final fixture = _BridgeWidgetFixture(wrongProjectGid: true);
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(find.text('無法讀取回應'), findsOneWidget);
  });

  testWidgets('TC-BW-09: Task typed node with same project and IID is accepted', (tester) async {
    final fixture = _BridgeWidgetFixture(
      typeId: 'gid://gitlab/WorkItems::Type/2',
      typeName: 'Task',
      statusName: 'In progress',
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(find.text('In progress'), findsOneWidget);
  });

  testWidgets('TC-BW-10: Installation subpath posts only to /gitlab/api/graphql', (tester) async {
    final fixture = _BridgeWidgetFixture(instanceSubpath: '/gitlab');
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(fixture.requests, isNotEmpty);
    for (final req in fixture.requests) {
      expect(req.uri.path, '/gitlab/api/graphql');
    }
  });

  testWidgets('TC-BW-11: Widgets unavailable shows muted caption and zero attribute rows without failure', (tester) async {
    final fixture = _BridgeWidgetFixture(widgetsAvailable: false);
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    expect(find.text('伺服器未回傳 widgets，無法判定'), findsOneWidget);
    expect(find.text('工作流程狀態'), findsNothing);
    expect(find.byType(FailureNotice), findsNothing);
  });

  testWidgets('TC-BW-12: Row-specific attribute failure on expand shows inline row error and preserves workflow status parent start date and other lazy row', (tester) async {
    final fixture = _BridgeWidgetFixture(
      parentIid: 9,
      startDate: DateTime(2026, 10, 1),
      widgetTypes: {'STATUS', 'HIERARCHY', 'START_AND_DUE_DATE', 'HEALTH_STATUS', 'ITERATION'},
      failHealth: true,
      failIteration: false,
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('展開其他欄位'));
    await settleNetworkWidgets(tester);

    expect(find.text('工作流程狀態'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.textContaining('#9'), findsOneWidget);
    expect(find.text('2026/10/01'), findsOneWidget);
    expect(find.text('Sprint 1'), findsOneWidget);
    expect(find.text('無法載入'), findsOneWidget);
    expect(find.byTooltip('重試'), findsOneWidget);
  });

  testWidgets('TC-BW-13: Retrying failed row attribute issues exactly one attribute request and restores row on success', (tester) async {
    final fixture = _BridgeWidgetFixture(
      widgetTypes: {'STATUS', 'HEALTH_STATUS', 'ITERATION'},
      failHealth: true,
      failIteration: false,
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('展開其他欄位'));
    await settleNetworkWidgets(tester);
    expect(find.text('無法載入'), findsOneWidget);
    final countBefore = fixture.requests.length;

    fixture.failHealth = false;
    await tester.tap(find.byTooltip('重試'));
    await settleNetworkWidgets(tester);

    expect(fixture.requests.length, countBefore + 1);
    expect(find.text('目前：正常'), findsOneWidget);
    expect(find.text('無法載入'), findsNothing);
  });

  testWidgets('TC-BW-14: Collapsing and reopening expanded attributes issues zero extra requests while owner revision unchanged', (tester) async {
    final fixture = _BridgeWidgetFixture(
      widgetTypes: {'STATUS', 'HEALTH_STATUS', 'ITERATION'},
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixture));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('展開其他欄位'));
    await settleNetworkWidgets(tester);
    final countAfterExpand = fixture.requests.length;

    await tester.tap(find.text('收起其他欄位'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('展開其他欄位'));
    await settleNetworkWidgets(tester);

    expect(fixture.requests.length, countAfterExpand);
  });

  testWidgets('TC-BW-15: Displays precise absent and null values for parent start date health iteration and status without inventing fields', (tester) async {
    // 1. All null/absent
    final fixtureAbsent = _BridgeWidgetFixture(
      parentIid: null,
      startDate: null,
      healthStatus: null,
      iterationTitle: null,
      statusName: null,
      widgetTypes: {'STATUS', 'HIERARCHY', 'START_AND_DUE_DATE', 'HEALTH_STATUS', 'ITERATION'},
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixtureAbsent));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('展開其他欄位'));
    await settleNetworkWidgets(tester);

    expect(find.text('上層項目'), findsNothing);
    expect(find.text('開始日期'), findsNothing);
    expect(find.text('目前：未設定'), findsOneWidget);
    expect(find.text('未設定'), findsNWidgets(2)); // Status and Iteration

    // 2. Raw unknown health value
    await tester.pumpWidget(const SizedBox());
    final fixtureRawHealth = _BridgeWidgetFixture(
      healthStatus: 'customHealthState',
      widgetTypes: {'HEALTH_STATUS'},
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixtureRawHealth));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('展開其他欄位'));
    await settleNetworkWidgets(tester);

    expect(find.text('目前：customHealthState'), findsOneWidget);

    // 3. STATUS widget absent from widgetTypes: row hidden and 0 status read
    await tester.pumpWidget(const SizedBox());
    final fixtureNoStatus = _BridgeWidgetFixture(
      widgetTypes: {'HIERARCHY'},
    );
    await tester.pumpWidget(_wrapBridge(fixture: fixtureNoStatus));
    await settleNetworkWidgets(tester);

    expect(fixtureNoStatus.requests.length, 1); // detail only, 0 status read
    expect(find.text('工作流程狀態'), findsNothing);
  });
}
