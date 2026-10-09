import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/core/work_item_types.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/navigation.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

final class _PageTestFixture {
  _PageTestFixture({
    this.statusSequence = const ['In progress'],
    this.delayGraphDetail,
  });

  List<String> statusSequence;
  int _statusIndex = 0;
  Completer<void>? delayGraphDetail;
  Completer<void>? delayGraphStatus;
  Completer<void>? delayRestLoad;

  final requests = <RequestOptions>[];
  late final adapter = FakeAdapter(_respond);
  late final api = testApi(adapter);

  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'tester', name: 'Tester'),
    token: 'synthetic-token',
  );

  Project get project => const Project(id: 42, name: 'Project 42', path: 'team/example');

  int get restIssueRecordReads => requests.where(
    (r) => r.method == 'GET' && RegExp(r'/projects/42/issues/\d+$').hasMatch(r.uri.path),
  ).length;

  int get graphDetailReads => requests.where(
    (r) => r.method == 'POST' &&
        r.uri == api.instance.graphQL &&
        '${(r.data is Json ? r.data['query'] : '')}'.startsWith('query MobileProjectWorkItem('),
  ).length;

  int get graphStatusReads => requests.where(
    (r) => r.method == 'POST' &&
        r.uri == api.instance.graphQL &&
        '${(r.data is Json ? r.data['query'] : '')}'.startsWith('query MobileWorkItemStatusAttribute('),
  ).length;

  int get totalGraphReads => requests.where(
    (r) => r.method == 'POST' && r.uri == api.instance.graphQL,
  ).length;

  FutureOr<ResponseBody> _respond(RequestOptions request) async {
    requests.add(request);
    final segments = request.uri.pathSegments;
    final path = segments.skip(segments.indexOf('v4') + 1).toList();
    final joined = path.join('/');

    if (request.method == 'POST' && request.uri == api.instance.graphQL) {
      final body = request.data is Json ? request.data as Json : <String, dynamic>{};
      final query = body['query'] as String? ?? '';
      final variables = body['variables'] is Json ? body['variables'] as Json : <String, dynamic>{};

      if (query.startsWith('query MobileProjectWorkItem(')) {
        if (delayGraphDetail != null) {
          await delayGraphDetail!.future;
        }
        final iid = variables['iid'] as String? ?? '7';
        final node = {
          'id': 'gid://gitlab/WorkItem/$iid',
          'iid': iid,
          'title': 'Test Issue $iid',
          'state': 'OPEN',
          'createdAt': '2026-09-01T01:02:03Z',
          'updatedAt': '2026-09-01T01:02:03Z',
          'project': {'id': 'gid://gitlab/Project/42', 'fullPath': project.path},
          'namespace': {'id': 'gid://gitlab/Namespaces::ProjectNamespace/142', 'fullPath': project.path},
          'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Issue'},
          'description': 'Description for $iid',
          'widgets': [
            {'type': 'STATUS'},
            {'type': 'HIERARCHY', 'hasParent': false, 'hasChildren': false, 'parent': null, 'children': {'nodes': <Json>[], 'pageInfo': {'hasNextPage': false, 'endCursor': null}}},
            {'type': 'START_AND_DUE_DATE', 'startDate': '2026-10-01', 'dueDate': null, 'rollUp': false},
          ],
        };
        return jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/42',
              'fullPath': project.path,
              'workItems': {
                'nodes': [node],
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        });
      }

      if (query.startsWith('query MobileWorkItemStatusAttribute(')) {
        if (delayGraphStatus != null) {
          await delayGraphStatus!.future;
        }
        final currentStatus = _statusIndex < statusSequence.length
            ? statusSequence[_statusIndex]
            : statusSequence.last;
        return jsonResponse({
          'data': {
            'workItem': {
              'id': variables['id'] ?? 'gid://gitlab/WorkItem/7',
              'iid': '7',
              'project': {'id': 'gid://gitlab/Project/42', 'fullPath': project.path},
              'namespace': {'id': 'gid://gitlab/Namespaces::ProjectNamespace/142', 'fullPath': project.path},
              'widgets': [
                {
                  'type': 'STATUS',
                  'status': {
                    'id': 'gid://gitlab/WorkItems::Widgets::Status/1',
                    'name': currentStatus,
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
    }

    if (request.method == 'GET') {
      if (joined == 'projects/42') {
        return jsonResponse({...projectJson(42), 'name': 'Project 42', 'path_with_namespace': 'team/example'});
      }

      if (joined.startsWith('projects/42/issues/')) {
        if (delayRestLoad != null) {
          await delayRestLoad!.future;
        }
        final iidStr = path[3];
        final iid = int.tryParse(iidStr) ?? 7;
        if (path.length == 4) {
          return jsonResponse({
            'id': 1000 + iid,
            'iid': iid,
            'project_id': 42,
            'title': 'REST Issue $iid',
            'description': 'A very long description for testing collapse and expansion in the issue page.\n' * 5,
            'state': 'opened',
            'author': {'id': 9, 'username': 'author', 'name': 'Author'},
            'assignees': <Json>[],
            'labels': <String>[],
            'created_at': '2026-09-01T01:02:03Z',
            'updated_at': '2026-09-01T01:02:03Z',
          });
        }
        if (path.length == 5) {
          final tail = path[4];
          if (tail == 'award_emoji' || tail == 'discussions' || tail == 'related_merge_requests' || tail == 'links') {
            return jsonResponse(<Json>[]);
          }
        }
      }

      if (joined.startsWith('projects/42/merge_requests/')) {
        final iid = int.tryParse(path[3]) ?? 7;
        if (path.length == 4) {
          return jsonResponse({
            'id': 2000 + iid,
            'iid': iid,
            'project_id': 42,
            'title': 'REST MR $iid',
            'description': 'MR description',
            'state': 'opened',
            'author': {'id': 9, 'username': 'author', 'name': 'Author'},
            'assignees': <Json>[],
            'labels': <String>[],
            'sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'created_at': '2026-09-01T01:02:03Z',
            'updated_at': '2026-09-01T01:02:03Z',
          });
        }
        if (path.length == 5) {
          final tail = path[4];
          if (tail == 'award_emoji' || tail == 'discussions' || tail == 'commits' || tail == 'pipelines' || tail == 'participants') {
            return jsonResponse(<Json>[]);
          }
          if (tail == 'approvals') {
            return jsonResponse({'approved_by': <Json>[], 'approvals_required': 0, 'approvals_left': 0});
          }
        }
      }
    }

    return jsonResponse({'message': '404 Not Found'}, status: 404);
  }

  void advanceStatus() {
    if (_statusIndex + 1 < statusSequence.length) {
      _statusIndex++;
    }
  }
}

Widget _wrapPage({
  required _PageTestFixture fixture,
  SessionController? session,
  String resource = 'issues',
  ProjectWorkItemType type = ProjectWorkItemType.issue,
  int iid = 7,
}) {
  final page = WorkItemPage(
    account: fixture.account,
    api: fixture.api,
    project: fixture.project,
    resource: resource,
    iid: iid,
    type: type,
  );
  if (session != null) {
    return ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(session),
      ],
      child: MaterialApp(home: page),
    );
  }
  return MaterialApp(home: page);
}

void main() {
  testWidgets('TC-PI-16: ResourceNavigator.workItem issue renders REST first and scrolls while Graph held, then loads exactly 2 GraphQL requests with "開啟中" lifecycle header', (tester) async {
    final holdGraph = Completer<void>();
    final fixture = _PageTestFixture(
      statusSequence: ['Done'],
      delayGraphDetail: holdGraph,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => ResourceNavigator(
                fixture.account,
                fixture.api,
              ).workItem(context, '42', 'issues', 7),
              child: const Text('Open Work Item'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Work Item'));
    await pumpUntil(tester, () => fixture.graphDetailReads == 1);

    // REST title and "開啟中" header badge rendered while Graph is held
    expect(find.text('REST Issue 7'), findsOneWidget);
    expect(find.text('開啟中'), findsOneWidget);

    // REST description and reactions are rendered and scrollable
    expect(find.textContaining('A very long description'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -100));
    await tester.pump();

    // Release Graph Completer
    holdGraph.complete();
    await settleNetworkWidgets(tester);

    // Total requests: exactly 1 REST issue record GET, 1 MobileProjectWorkItem, 1 MobileWorkItemStatusAttribute
    expect(fixture.restIssueRecordReads, 1);
    expect(fixture.graphDetailReads, 1);
    expect(fixture.graphStatusReads, 1);
    expect(fixture.totalGraphReads, 2);

    // Header badge is '開啟中', workflow status row is 'Done'
    expect(find.text('開啟中'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('TC-PI-17: Merge request page issues zero GraphQL requests across all tabs', (tester) async {
    final fixture = _PageTestFixture();
    await tester.pumpWidget(_wrapPage(fixture: fixture, resource: 'merge_requests'));
    await settleNetworkWidgets(tester);

    expect(find.text('摘要'), findsOneWidget);
    expect(fixture.totalGraphReads, 0);

    await tester.tap(find.text('變更'));
    await settleNetworkWidgets(tester);
    expect(fixture.totalGraphReads, 0);

    await tester.tap(find.text('討論'));
    await settleNetworkWidgets(tester);
    expect(fixture.totalGraphReads, 0);

    await tester.tap(find.text('檢查'));
    await settleNetworkWidgets(tester);
    expect(fixture.totalGraphReads, 0);
  });

  testWidgets('TC-PI-18: Stale epoch E detail read returning after E+1 refresh is dropped by predicate fence', (tester) async {
    final holdEpoch1 = Completer<void>();
    final fixture = _PageTestFixture(
      statusSequence: ['Old status', 'Done'],
      delayGraphDetail: holdEpoch1,
    );

    await tester.pumpWidget(_wrapPage(fixture: fixture));
    await pumpUntil(tester, () => fixture.graphDetailReads == 1);

    // While epoch 1 detail is held, tap AppBar refresh
    fixture.advanceStatus();
    fixture.delayGraphDetail = null; // epoch 2 will not be delayed

    await tester.tap(find.byTooltip('重新整理'));
    await settleNetworkWidgets(tester);

    // Fresh epoch 2 has completed with 'Done'
    expect(find.text('Done'), findsOneWidget);

    // Release old held epoch 1 detail read
    holdEpoch1.complete();
    await settleNetworkWidgets(tester);

    // Old 'Old status' is dropped by predicate fence and never painted
    expect(find.text('Old status'), findsNothing);
    expect(find.text('Done'), findsOneWidget);

    // detail == 2 (one old, one new) and status == 1 (old status was never dispatched because old detail was dropped)
    expect(fixture.graphDetailReads, 2);
    expect(fixture.graphStatusReads, 1);
  });

  testWidgets('TC-PI-19: SessionController generation advance with identical API drops pending read', (tester) async {
    final holdGraph = Completer<void>();
    final fixture = _PageTestFixture(
      statusSequence: ['In progress'],
      delayGraphDetail: holdGraph,
    );
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);

    await tester.pumpWidget(_wrapPage(fixture: fixture, session: session));
    await pumpUntil(tester, () => fixture.graphDetailReads == 1);

    // Advance session generation while read is held
    session.generation++;

    // Release held read
    holdGraph.complete();
    await settleNetworkWidgets(tester);

    // The returned read was for old session/generation and must not be accepted
    expect(fixture.graphStatusReads, 0);
    expect(find.text('In progress'), findsNothing);
  });

  testWidgets('TC-PI-20: Native editor opens with captured account api and session generation with grounded capabilities', (tester) async {
    final fixture = _PageTestFixture(statusSequence: ['In progress']);
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);

    await tester.pumpWidget(_wrapPage(fixture: fixture, session: session));
    await settleNetworkWidgets(tester);

    // Tap editor button
    await tester.tap(find.text('查看與編輯工作項目欄位'));
    await settleNetworkWidgets(tester);

    // Pushed GraphWorkItemDetailPage is mounted with captured parameters
    final p = tester.widget<GraphWorkItemDetailPage>(find.byType(GraphWorkItemDetailPage));
    expect(identical(p.api, fixture.api), isTrue);
    expect(p.account.key, fixture.account.key);
    expect(p.iid, 7);
    expect(p.sessionGeneration, session.generation);
    expect(identical(p.ownerChanges, session), isTrue);
  });

  testWidgets('TC-PI-21: Returning from native editor refreshes bridge and REST exactly once through coordinated page reload path', (tester) async {
    final fixture = _PageTestFixture(statusSequence: ['In progress']);
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);

    await tester.pumpWidget(_wrapPage(fixture: fixture, session: session));
    await settleNetworkWidgets(tester);

    // Open editor and settle
    await tester.tap(find.text('查看與編輯工作項目欄位'));
    await settleNetworkWidgets(tester);

    final restBefore = fixture.restIssueRecordReads;
    final detailBefore = fixture.graphDetailReads;
    final statusBefore = fixture.graphStatusReads;

    final nav = tester.state<NavigatorState>(find.byType(Navigator).last);
    nav.pop();
    await settleNetworkWidgets(tester);

    // Assert coordinated reload: exactly +1 REST, +1 detail, +1 status
    expect(fixture.restIssueRecordReads, restBefore + 1);
    expect(fixture.graphDetailReads, detailBefore + 1);
    expect(fixture.graphStatusReads, statusBefore + 1);
  });

  testWidgets('TC-PI-22: Stale pop after owner change does not dispatch duplicate new-owner requests or paint old owner', (tester) async {
    final fixture = _PageTestFixture(statusSequence: ['In progress']);
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);

    late StateSetter updateHost;
    var currentIid = 7;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(session),
        ],
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              updateHost = setState;
              return WorkItemPage(
                account: fixture.account,
                api: fixture.api,
                project: fixture.project,
                resource: 'issues',
                iid: currentIid,
                type: ProjectWorkItemType.issue,
              );
            },
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    // Open editor route
    await tester.tap(find.text('查看與編輯工作項目欄位'));
    await settleNetworkWidgets(tester);

    // Rebind IID to 8 on same State; _dismissRoutes() pops registered route
    final restReadsBefore = fixture.requests.where(
      (r) => r.method == 'GET' && r.uri.path.endsWith('/projects/42/issues/8'),
    ).length;

    updateHost(() {
      currentIid = 8;
    });
    await settleNetworkWidgets(tester);

    final restReadsAfter = fixture.requests.where(
      (r) => r.method == 'GET' && r.uri.path.endsWith('/projects/42/issues/8'),
    ).length;

    // Green issues new-owner REST GET == 1; mutant M5 issues new-owner REST GET == 2
    expect(restReadsAfter - restReadsBefore, 1);
  });

  testWidgets('TC-PI-23: Manual AppBar refresh reloads REST, clears old Graph rows before REST finishes, and updates Graph once', (tester) async {
    final holdRest = Completer<void>();
    final fixture = _PageTestFixture(
      statusSequence: ['In progress', 'Done'],
    );

    await tester.pumpWidget(_wrapPage(fixture: fixture));
    await settleNetworkWidgets(tester);
    expect(find.text('In progress'), findsOneWidget);

    fixture.advanceStatus();
    fixture.delayRestLoad = holdRest;

    // Tap AppBar refresh
    await tester.tap(find.byTooltip('重新整理'));
    await tester.pump();

    // Before REST finishes, old Graph rows are cleared immediately
    expect(find.text('In progress'), findsNothing);

    // Complete REST load
    holdRest.complete();
    await settleNetworkWidgets(tester);

    // Fresh 'Done' appears
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('TC-PI-24: Benign session notify keeps bridge data and issues zero requests', (tester) async {
    final fixture = _PageTestFixture(statusSequence: ['In progress']);
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);

    await tester.pumpWidget(_wrapPage(fixture: fixture, session: session));
    await settleNetworkWidgets(tester);
    expect(find.text('In progress'), findsOneWidget);

    final requestsBefore = fixture.requests.length;
    session.notifyListeners();
    await settleNetworkWidgets(tester);

    expect(fixture.requests.length, requestsBefore);
    expect(find.text('In progress'), findsOneWidget);
  });

  testWidgets('TC-PI-25: Read-only route without ProviderScope allows pop refresh when owner current while STATUS writer stays closed', (tester) async {
    final fixture = _PageTestFixture(statusSequence: ['In progress']);

    // Mount without ProviderScope
    await tester.pumpWidget(_wrapPage(fixture: fixture, session: null));
    await settleNetworkWidgets(tester);

    expect(find.text('In progress'), findsOneWidget);

    // Open editor route
    await tester.tap(find.text('查看與編輯工作項目欄位'));
    await settleNetworkWidgets(tester);

    final p = tester.widget<GraphWorkItemDetailPage>(find.byType(GraphWorkItemDetailPage));
    expect(p.sessionGeneration, isNull);
    expect(p.ownerChanges, isNull);

    final restBefore = fixture.restIssueRecordReads;
    final detailBefore = fixture.graphDetailReads;

    // Pop editor
    final nav = tester.state<NavigatorState>(find.byType(Navigator).last);
    nav.pop();
    await settleNetworkWidgets(tester);

    // Pop refresh executes _load() successfully
    expect(fixture.restIssueRecordReads, restBefore + 1);
    expect(fixture.graphDetailReads, detailBefore + 1);
    expect(find.text('In progress'), findsOneWidget);
  });

  testWidgets('TC-PI-26: Long description stays collapsed and tab index survives with bridge mounted', (tester) async {
    final fixture = _PageTestFixture(statusSequence: ['In progress']);
    await tester.pumpWidget(_wrapPage(fixture: fixture));
    await settleNetworkWidgets(tester);

    // Description is present in ListView
    expect(find.textContaining('A very long description'), findsOneWidget);

    // Switch to Discussions tab
    await tester.tap(find.text('討論'));
    await settleNetworkWidgets(tester);

    // Switch back to Summary tab
    await tester.tap(find.text('摘要'));
    await settleNetworkWidgets(tester);

    // Description and bridge remain mounted
    expect(find.textContaining('A very long description'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
  });
}
