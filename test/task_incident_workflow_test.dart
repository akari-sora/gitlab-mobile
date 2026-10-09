import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_types.dart';
import 'package:gitlab_mobile/features/workspace/draft_review_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
  home: Scaffold(body: child),
);

Account _account(GitLabApi api, {int user = 7}) => Account(
  instance: api.instance,
  user: GitLabUser(id: user, username: 'user$user', name: 'User $user'),
  token: 'synthetic-test-token',
);

Project _project([int id = 42]) => Project.fromJson({
  'id': id,
  'name': 'Project $id',
  'path_with_namespace': 'group/project-$id',
  'visibility': 'private',
  'default_branch': 'main',
  'archived': false,
});

Json _issue(int iid, ProjectWorkItemType type, {String state = 'opened', String severity = 'unknown'}) => {
  'id': 1000 + iid,
  'iid': iid,
  'project_id': 42,
  'issue_type': type.apiValue,
  'title': '${type.title} $iid',
  'description': 'typed work item',
  'state': state,
  'severity': severity,
  'author': {'id': 7, 'username': 'user7'},
  'assignees': <Json>[],
  'labels': <String>[],
  'updated_at': '2026-10-02T08:00:00Z',
  'created_at': '2026-10-02T07:00:00Z',
};

final class _TypedBackend {
  _TypedBackend({this.lifecycleSupported = true, this.delayList, this.delayGraphStatus, this.delayedStatusRead = 0, this.firstListItem, this.secondListItem, this.createResponse});

  final bool lifecycleSupported;
  final Completer<ResponseBody>? delayList;
  final Completer<ResponseBody>? delayGraphStatus;
  final int delayedStatusRead;
  final Json? firstListItem, secondListItem, createResponse;
  late final adapter = FakeAdapter(respond);
  late final api = testApi(adapter);
  IncidentLifecycle lifecycle = IncidentLifecycle.triggered;
  String issueState = 'opened';
  int counter = 20;
  int graphStatusReads = 0;

  Json get incident => _issue(7, ProjectWorkItemType.incident, state: issueState, severity: 'high');

  Json _status() => {
    'id': 'gid://gitlab/Issue/1007',
    'iid': '7',
    'projectId': 42,
    'state': issueState,
    'severity': 'HIGH',
    'escalationStatus': lifecycle.apiValue,
    'updatedAt': '2026-10-02T08:00:00Z',
  };

  ResponseBody graphReadResponse() => jsonResponse({
    'data': {
      'project': {
        'id': 'gid://gitlab/Project/42',
        'issues': {
          'nodes': [_status()],
          'pageInfo': {'hasNextPage': false},
        },
      },
    },
  });

  FutureOr<ResponseBody> _graphql(Json body) {
    final query = body['query'] as String? ?? '';
    if (!lifecycleSupported) {
      return jsonResponse({
        'errors': [
          {
            'message': 'field unavailable',
            'extensions': {'code': 'undefinedField'},
          },
        ],
      });
    }
    if (query.contains('mutation MobileSetIncidentStatus')) {
      final input = ((body['variables'] as Json)['input'] as Json);
      lifecycle = IncidentLifecycle.values.firstWhere((value) => value.apiValue == input['status']);
      return jsonResponse({
        'data': {
          'issueSetEscalationStatus': {'errors': <String>[], 'issue': _status()},
        },
      });
    }
    graphStatusReads++;
    if (delayGraphStatus != null && graphStatusReads == delayedStatusRead) {
      return delayGraphStatus!.future;
    }
    return graphReadResponse();
  }

  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = request.uri.path;
    final body = request.data is Json ? request.data as Json : <String, dynamic>{};
    if (path.endsWith('/api/graphql')) return _graphql(body);
    if (path.endsWith('/projects/42/repository/branches')) {
      return jsonResponse([
        {'name': 'main', 'default': true},
        {'name': 'feature/create-fence', 'default': false},
      ]);
    }
    if (path.endsWith('/projects/42/merge_requests')) {
      if (request.method == 'POST') {
        return jsonResponse(createResponse ?? <String, dynamic>{
          ..._issue(++counter, ProjectWorkItemType.issue),
          ...body,
          'source_branch': body['source_branch'],
          'target_branch': body['target_branch'],
        }, status: 201);
      }
      return jsonResponse([]);
    }
    if (path.endsWith('/projects/42/issues') && request.method == 'GET') {
      if (delayList != null && !delayList!.isCompleted) return delayList!.future;
      final type = request.uri.queryParameters['issue_type'];
      final defaultItem = switch (type) {
        'task' => _issue(4, ProjectWorkItemType.task),
        'incident' => incident,
        _ => _issue(1, ProjectWorkItemType.issue),
      };
      final item = request.uri.queryParameters['page'] == null ? firstListItem ?? defaultItem : secondListItem ?? defaultItem;
      return jsonResponse(
        [item],
        headers: request.uri.queryParameters['page'] == null
            ? {
                'x-next-page': ['2'],
              }
            : const {},
      );
    }
    if (path.endsWith('/projects/42/issues') && request.method == 'POST') {
      if (createResponse != null) return jsonResponse(createResponse!, status: 201);
      final type = ProjectWorkItemType.values.firstWhere((value) => value.apiValue == body['issue_type']);
      return jsonResponse({
        ..._issue(++counter, type, severity: '${body['severity'] ?? 'unknown'}'),
        ...body,
      }, status: 201);
    }
    if (path.endsWith('/projects/42/issues/7')) {
      if (request.method == 'PUT') {
        if (body['state_event'] == 'close') issueState = 'closed';
        if (body['state_event'] == 'reopen') issueState = 'opened';
      }
      return jsonResponse(incident);
    }
    if (RegExp(r'/projects/42/issues/\d+$').hasMatch(path)) {
      final iid = int.parse(path.split('/').last);
      return jsonResponse(_issue(iid, iid == 4 ? ProjectWorkItemType.task : ProjectWorkItemType.incident));
    }
    if (path.contains('/related_merge_requests') ||
        path.endsWith('/links') ||
        path.endsWith('/discussions') ||
        path.endsWith('/award_emoji')) {
      return jsonResponse([]);
    }
    return jsonResponse({'message': 'not found'}, status: 404);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  test('typed model rejects mismatched lifecycle identity and preserves issue state', () {
    expect(workItemTypeFromJson(<String, dynamic>{}), ProjectWorkItemType.issue);
    expect(
      () => workItemTypeFromJson({'issue_type': 'future_type'}),
      throwsA(isA<ApiFailure>().having((failure) => failure.kind, 'kind', FailureKind.invalidResponse)),
    );
    for (final malformed in <Object?>[42, <String, dynamic>{'name': 'issue'}]) {
      expect(
        () => workItemTypeFromJson({'issue_type': malformed}),
        throwsA(isA<ApiFailure>().having((failure) => failure.kind, 'kind', FailureKind.invalidResponse)),
      );
    }
    final parsed = IncidentStatusSnapshot.fromJson(
      {
        'iid': '7',
        'projectId': 42,
        'state': 'closed',
        'severity': 'HIGH',
        'escalationStatus': 'ACKNOWLEDGED',
        'updatedAt': '2026-10-02T08:00:00Z',
      },
      expectedProjectId: 42,
      expectedIid: 7,
    );
    expect(parsed.issueState, 'closed');
    expect(parsed.lifecycle, IncidentLifecycle.acknowledged);
    expect(
      () => IncidentStatusSnapshot.fromJson(
        {
          'iid': '7',
          'projectId': 43,
          'state': 'closed',
          'severity': 'HIGH',
          'escalationStatus': 'ACKNOWLEDGED',
          'updatedAt': '2026-10-02T08:00:00Z',
        },
        expectedProjectId: 42,
        expectedIid: 7,
      ),
      throwsA(isA<ApiFailure>()),
    );
  });

  testWidgets('task pagination keeps the server issue_type filter', (tester) async {
    final backend = _TypedBackend();
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        WorkItemsTab(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
          resource: 'issues',
          type: ProjectWorkItemType.task,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('Task 4'), findsOneWidget);
    await tester.tap(find.text('載入更多'));
    await settleNetworkWidgets(tester);
    final listReads = backend.adapter.requests
        .where((request) => request.method == 'GET' && request.uri.path.endsWith('/projects/42/issues'))
        .toList();
    expect(listReads, hasLength(2));
    expect(listReads.every((request) => request.uri.queryParameters['issue_type'] == 'task'), isTrue);
    expect(listReads.last.uri.queryParameters['page'], '2');
  });

  testWidgets('typed list rejects missing type on page one', (tester) async {
    final wrong = _issue(1, ProjectWorkItemType.issue)..remove('issue_type');
    final backend = _TypedBackend(firstListItem: wrong);
    addTearDown(backend.api.close);
    await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'issues', type: ProjectWorkItemType.task)));
    await settleNetworkWidgets(tester);
    expect(find.text('Issue 1'), findsNothing);
    expect(find.text('無法讀取回應'), findsOneWidget);
  });

  for (final variant in <String>['missing', 'wrong']) {
    testWidgets('typed list rejects $variant project_id on page one', (tester) async {
      final wrong = _issue(1, ProjectWorkItemType.task);
      if (variant == 'missing') {
        wrong.remove('project_id');
      } else {
        wrong['project_id'] = 43;
      }
      final backend = _TypedBackend(firstListItem: wrong);
      addTearDown(backend.api.close);
      await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'issues', type: ProjectWorkItemType.task)));
      await settleNetworkWidgets(tester);
      expect(find.text('Task 1'), findsNothing);
      expect(find.text('無法讀取回應'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ordinary issue list rejects unknown type before row rendering', (tester) async {
    final wrong = {..._issue(1, ProjectWorkItemType.issue), 'issue_type': 'future_type'};
    final backend = _TypedBackend(firstListItem: wrong);
    addTearDown(backend.api.close);
    await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'issues')));
    await settleNetworkWidgets(tester);
    expect(find.text('議題 1'), findsNothing);
    expect(find.text('無法讀取回應'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typed list rejects a mixed wrong type on page two', (tester) async {
    final backend = _TypedBackend(secondListItem: _issue(7, ProjectWorkItemType.incident));
    addTearDown(backend.api.close);
    await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'issues', type: ProjectWorkItemType.task)));
    await settleNetworkWidgets(tester);
    expect(find.text('Task 4'), findsOneWidget);
    await tester.tap(find.text('載入更多'));
    await settleNetworkWidgets(tester);
    expect(find.text('Incident 7'), findsNothing);
    expect(find.text('無法讀取回應'), findsOneWidget);
  });

  for (final variant in <String>['missing', 'wrong']) {
    testWidgets('typed list rejects $variant project_id on page two', (tester) async {
      final wrong = _issue(7, ProjectWorkItemType.task);
      if (variant == 'missing') {
        wrong.remove('project_id');
      } else {
        wrong['project_id'] = 43;
      }
      final backend = _TypedBackend(secondListItem: wrong);
      addTearDown(backend.api.close);
      await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'issues', type: ProjectWorkItemType.task)));
      await settleNetworkWidgets(tester);
      expect(find.text('Task 4'), findsOneWidget);
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);
      expect(find.text('Task 7'), findsNothing);
      expect(find.text('無法讀取回應'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('typed create uncertain acknowledgement cannot send a duplicate POST', (tester) async {
    final backend = _TypedBackend(createResponse: _issue(22, ProjectWorkItemType.issue));
    addTearDown(backend.api.close);
    await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'issues', type: ProjectWorkItemType.task)));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增 Task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Typed acknowledgement');
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    expect(find.text('尚未確認操作結果'), findsOneWidget);
    int writes() => backend.adapter.requests.where((request) => request.method == 'POST' && request.uri.path.endsWith('/projects/42/issues')).length;
    expect(writes(), 1);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    expect(writes(), 1);
  });

  for (final variant in <String>['missing', 'wrong']) {
    testWidgets('typed create treats $variant project_id acknowledgement as uncertain', (tester) async {
      final acknowledgement = _issue(22, ProjectWorkItemType.task);
      if (variant == 'missing') {
        acknowledgement.remove('project_id');
      } else {
        acknowledgement['project_id'] = 43;
      }
      final backend = _TypedBackend(createResponse: acknowledgement);
      addTearDown(backend.api.close);
      await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'issues', type: ProjectWorkItemType.task)));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('新增 Task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Project acknowledgement');
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleNetworkWidgets(tester);
      expect(find.text('尚未確認操作結果'), findsOneWidget);
      int writes() => backend.adapter.requests.where((request) => request.method == 'POST' && request.uri.path.endsWith('/projects/42/issues')).length;
      expect(writes(), 1);
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleNetworkWidgets(tester);
      expect(writes(), 1);
    });
  }

  testWidgets('ordinary issue create with an empty 201 acknowledgement cannot send a duplicate POST', (tester) async {
    final backend = _TypedBackend(createResponse: <String, dynamic>{});
    addTearDown(backend.api.close);
    await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'issues')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增議題'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Issue acknowledgement');
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    expect(find.text('尚未確認操作結果'), findsOneWidget);
    int writes() => backend.adapter.requests.where((request) => request.method == 'POST' && request.uri.path.endsWith('/projects/42/issues')).length;
    expect(writes(), 1);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    expect(writes(), 1);
  });

  testWidgets('merge request create with an empty 201 acknowledgement cannot send a duplicate POST', (tester) async {
    final backend = _TypedBackend(createResponse: <String, dynamic>{});
    addTearDown(backend.api.close);
    await tester.pumpWidget(_host(WorkItemsTab(account: _account(backend.api), api: backend.api, project: _project(), resource: 'merge_requests')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增合併請求'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Merge acknowledgement');
    await tester.tap(find.byKey(const ValueKey('editor-source_branch')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('picker-row-feature/create-fence')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    expect(find.text('尚未確認操作結果'), findsOneWidget);
    int writes() => backend.adapter.requests.where((request) => request.method == 'POST' && request.uri.path.endsWith('/projects/42/merge_requests')).length;
    expect(writes(), 1);
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    expect(writes(), 1);
  });

  testWidgets('incident create sends type and severity and fits 320dp at 2x', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(640, 1600);
    final backend = _TypedBackend();
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        ProjectWorkItemsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
          type: ProjectWorkItemType.incident,
        ),
        textScale: 2,
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增 Incident'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Production outage');
    final severity = find.byKey(const ValueKey('editor-severity'));
    await tester.ensureVisible(severity);
    await tester.pumpAndSettle();
    await tester.tap(severity);
    await tester.pumpAndSettle();
    await tester.tap(find.text('嚴重').last);
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('editorSave'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await settleNetworkWidgets(tester);
    final write = backend.adapter.requests.lastWhere(
      (request) => request.method == 'POST' && request.uri.path.endsWith('/projects/42/issues'),
    );
    expect(write.data, containsPair('issue_type', 'incident'));
    expect(write.data, containsPair('severity', 'critical'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Task and Incident shells fit 320 and 412dp with 2x text', (tester) async {
    final backend = _TypedBackend();
    addTearDown(backend.api.close);
    for (final width in <double>[320, 412]) {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(width * 2, 1600);
      for (final type in <ProjectWorkItemType>[ProjectWorkItemType.task, ProjectWorkItemType.incident]) {
        await tester.pumpWidget(_host(ProjectWorkItemsPage(account: _account(backend.api), api: backend.api, project: _project(), type: type), textScale: 2));
        await settleNetworkWidgets(tester);
        expect(find.text(type.listTitle), findsOneWidget);
        expect(find.text(_project().path), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('incident issue state and escalation lifecycle are independent controls', (tester) async {
    final backend = _TypedBackend();
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        WorkItemPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
          resource: 'issues',
          iid: 7,
          type: ProjectWorkItemType.incident,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('議題狀態：開啟中'), findsOneWidget);
    expect(find.text('事件處理狀態：已觸發'), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('關閉議題狀態'));
    await settleNetworkWidgets(tester);
    expect(find.text('議題狀態：已關閉'), findsOneWidget);
    expect(find.text('事件處理狀態：已觸發'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('incident-lifecycle-acknowledged')));
    await tester.pumpAndSettle();
    expect(find.textContaining('議題狀態仍為已關閉'), findsOneWidget);
    await tester.tap(find.text('確認'));
    await settleNetworkWidgets(tester);
    expect(find.text('事件處理狀態：已確認'), findsOneWidget);
    final restStateWrites = backend.adapter.requests
        .where((request) => request.method == 'PUT' && request.uri.path.endsWith('/projects/42/issues/7'))
        .toList();
    expect(restStateWrites.single.data, {'state_event': 'close'});
    final graphMutation = backend.adapter.requests.singleWhere(
      (request) => request.method == 'POST' && '${request.data}'.contains('MobileSetIncidentStatus'),
    );
    expect((((graphMutation.data as Json)['variables'] as Json)['input'] as Json)['status'], 'ACKNOWLEDGED');
  });

  testWidgets('incident lifecycle success refreshes externally changed REST issue state', (tester) async {
    final backend = _TypedBackend();
    addTearDown(backend.api.close);
    Json? listUpdate;
    await tester.pumpWidget(
      _host(
        WorkItemPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
          resource: 'issues',
          iid: 7,
          type: ProjectWorkItemType.incident,
          onMutated: (value) => listUpdate = value,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('議題狀態：開啟中'), findsOneWidget);

    backend.issueState = 'closed';
    await tester.tap(find.byKey(const ValueKey('incident-lifecycle-acknowledged')));
    await tester.pumpAndSettle();
    expect(find.textContaining('議題狀態仍為已關閉'), findsOneWidget);
    await tester.tap(find.text('確認'));
    await settleNetworkWidgets(tester);

    expect(find.text('議題狀態：已關閉'), findsOneWidget);
    expect(find.text('事件處理狀態：已確認'), findsOneWidget);
    expect(listUpdate?['state'], 'closed');
    final mutations = backend.adapter.requests.where(
      (request) => request.method == 'POST' && '${request.data}'.contains('MobileSetIncidentStatus'),
    );
    expect(mutations, hasLength(1));
  });

  testWidgets('unsupported lifecycle stays explicit while REST incident remains usable', (tester) async {
    final backend = _TypedBackend(lifecycleSupported: false);
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        WorkItemPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
          resource: 'issues',
          iid: 7,
          type: ProjectWorkItemType.incident,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('Incident 7'), findsOneWidget);
    expect(find.byKey(const ValueKey('incident-lifecycle-unavailable')), findsOneWidget);
    expect(find.textContaining('未提供可用的事件處理狀態'), findsOneWidget);
    expect(find.byKey(const ValueKey('incident-lifecycle-resolved')), findsNothing);
  });

  testWidgets('incident edit updates severity without attempting a type conversion', (tester) async {
    final backend = _TypedBackend();
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        WorkItemPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
          resource: 'issues',
          iid: 7,
          type: ProjectWorkItemType.incident,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('編輯'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-severity')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('嚴重').last);
    final save = find.byKey(const Key('editorSave'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await settleNetworkWidgets(tester);
    final write = backend.adapter.requests.lastWhere(
      (request) => request.method == 'PUT' && request.uri.path.endsWith('/projects/42/issues/7'),
    );
    expect(write.data, containsPair('severity', 'critical'));
    expect(write.data, isNot(contains('issue_type')));
  });

  testWidgets('account API switch dismisses owned editor choice popup and rejects delayed old list', (tester) async {
    final delayed = Completer<ResponseBody>();
    final old = _TypedBackend(delayList: delayed);
    final current = _TypedBackend();
    final replacement = _TypedBackend();
    addTearDown(old.api.close);
    addTearDown(current.api.close);
    addTearDown(replacement.api.close);
    late StateSetter update;
    var api = old.api;
    var account = _account(old.api);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return WorkItemsTab(
              account: account,
              api: api,
              project: _project(),
              resource: 'issues',
              type: ProjectWorkItemType.incident,
            );
          },
        ),
      ),
    );
    await tester.pump();
    update(() {
      api = current.api;
      account = _account(current.api, user: 8);
    });
    await settleNetworkWidgets(tester);
    expect(find.text('Incident 7'), findsOneWidget);
    await tester.tap(find.byTooltip('新增 Incident'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-title')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-severity')));
    await tester.pumpAndSettle();
    expect(find.text('嚴重'), findsWidgets);
    update(() {
      api = replacement.api;
      account = _account(replacement.api, user: 9);
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-title')), findsNothing);
    expect(find.text('嚴重'), findsNothing);
    delayed.complete(jsonResponse([_issue(99, ProjectWorkItemType.incident)]));
    await settleNetworkWidgets(tester);
    expect(find.text('Incident 99'), findsNothing);
    expect(current.adapter.requests.where((request) => request.method != 'GET'), isEmpty);
  });

  testWidgets('detail owner switch dismisses incident severity popup and editor root', (tester) async {
    final old = _TypedBackend();
    final current = _TypedBackend();
    addTearDown(old.api.close);
    addTearDown(current.api.close);
    late StateSetter update;
    var api = old.api;
    var account = _account(old.api);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return WorkItemPage(
              account: account,
              api: api,
              project: _project(),
              resource: 'issues',
              iid: 7,
              type: ProjectWorkItemType.incident,
            );
          },
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('編輯'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-severity')));
    await tester.pumpAndSettle();
    expect(find.text('嚴重'), findsWidgets);
    update(() {
      api = current.api;
      account = _account(current.api, user: 8);
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-title')), findsNothing);
    expect(find.text('嚴重'), findsNothing);
    await settleNetworkWidgets(tester);
    expect(find.text('Incident 7'), findsOneWidget);
    expect(old.adapter.requests.where((request) => request.method != 'GET' && !request.uri.path.endsWith('/api/graphql')), isEmpty);
  });

  testWidgets('detail owner switch dismisses quick label picker root', (tester) async {
    final old = _TypedBackend();
    final current = _TypedBackend();
    addTearDown(old.api.close);
    addTearDown(current.api.close);
    late StateSetter update;
    var api = old.api;
    var account = _account(old.api);
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, setState) {
      update = setState;
      return WorkItemPage(account: account, api: api, project: _project(), resource: 'issues', iid: 7, type: ProjectWorkItemType.incident);
    })));
    await settleNetworkWidgets(tester);
    final quickLabel = find.byKey(const ValueKey('quick-add-label'));
    await tester.ensureVisible(quickLabel);
    await tester.pumpAndSettle();
    await tester.tap(quickLabel);
    await settleNetworkWidgets(tester);
    expect(find.text('選擇標籤 · #7'), findsOneWidget);
    update(() {
      api = current.api;
      account = _account(current.api, user: 8);
    });
    await settleNetworkWidgets(tester);
    expect(find.text('選擇標籤 · #7'), findsNothing);
    expect(find.text('Incident 7'), findsOneWidget);
    expect(old.adapter.requests.where((request) => request.method != 'GET' && !request.uri.path.endsWith('/api/graphql')), isEmpty);
  });

  testWidgets('merge dialog and draft review route are dismissed on owner switches', (tester) async {
    final first = WorkspaceFixture(), second = WorkspaceFixture(), third = WorkspaceFixture();
    addTearDown(first.api.close);
    addTearDown(second.api.close);
    addTearDown(third.api.close);
    late StateSetter update;
    var fixture = first;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, setState) {
      update = setState;
      return WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project, resource: 'merge_requests', iid: 12);
    })));
    await settleNetworkWidgets(tester);
    await tester.tap(find.widgetWithText(FilledButton, '合併'));
    await tester.pumpAndSettle();
    expect(find.text('合併 !12？'), findsOneWidget);
    update(() => fixture = second);
    await tester.pumpAndSettle();
    expect(find.text('合併 !12？'), findsNothing);
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('mr-draft-review-btn')));
    await settleNetworkWidgets(tester);
    expect(find.byType(DraftReviewPage), findsOneWidget);
    update(() => fixture = third);
    await settleNetworkWidgets(tester);
    expect(find.byType(DraftReviewPage), findsNothing);
    expect(find.text('Improve private-project navigation'), findsOneWidget);
    expect(first.adapter.requests.where((request) => request.method != 'GET'), isEmpty);
    expect(second.adapter.requests.where((request) => request.method != 'GET'), isEmpty);
  });

  testWidgets('owner switch during lifecycle inner preflight prevents old API mutation', (tester) async {
    final delayedPreflight = Completer<ResponseBody>();
    final old = _TypedBackend(delayGraphStatus: delayedPreflight, delayedStatusRead: 3);
    final current = _TypedBackend();
    addTearDown(old.api.close);
    addTearDown(current.api.close);
    late StateSetter update;
    var api = old.api;
    var account = _account(old.api);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return WorkItemPage(
              account: account,
              api: api,
              project: _project(),
              resource: 'issues',
              iid: 7,
              type: ProjectWorkItemType.incident,
            );
          },
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('incident-lifecycle-acknowledged')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確認'));
    await pumpUntil(tester, () => old.graphStatusReads == 3, description: 'inner incident status preflight');
    bool oldMutation(RequestOptions request) => request.method == 'POST' && '${request.data}'.contains('MobileSetIncidentStatus');
    expect(old.adapter.requests.where(oldMutation), isEmpty);
    update(() {
      api = current.api;
      account = _account(current.api, user: 8);
    });
    await settleNetworkWidgets(tester);
    delayedPreflight.complete(old.graphReadResponse());
    await settleNetworkWidgets(tester);
    expect(old.adapter.requests.where(oldMutation), isEmpty);
    expect(find.text('事件處理狀態：已觸發'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
