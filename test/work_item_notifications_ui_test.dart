import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_notifications.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = GraphResourceRef(
  id: 'gid://gitlab/Project/42',
  fullPath: 'studio/mobile-workspace',
);
const _namespace = GraphResourceRef(
  id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
  fullPath: 'studio/mobile-workspace',
);
const _groupNamespace = GraphResourceRef(
  id: 'gid://gitlab/Namespaces::GroupNamespace/84',
  fullPath: 'studio/mobile-group',
);

WorkItemGraphSummary _summary({DateTime? updatedAt, bool group = false}) =>
    WorkItemGraphSummary(
      id: 'gid://gitlab/WorkItem/31',
      iid: 31,
      title: 'Synthetic notification item',
      state: 'OPEN',
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: updatedAt ?? DateTime.utc(2026, 10, 3, 10),
      project: group ? null : _project,
      namespace: group ? _groupNamespace : _namespace,
      type: const WorkItemGraphType(
        id: 'gid://gitlab/WorkItems::Type/9',
        name: 'Task',
      ),
    );

Account _account(GitLabApi api, {int id = 7}) => Account(
  instance: api.instance,
  user: GitLabUser(id: id, username: 'reader$id', name: 'Reader $id'),
  token: 'synthetic-token',
);

Widget _host({
  required GitLabApi api,
  WorkItemGraphSummary? summary,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: WorkItemNotificationsControl(
        account: _account(api),
        api: api,
        summary: summary ?? _summary(),
        isCurrent: isCurrent,
        ownerChanges: ownerChanges,
      ),
    ),
  ),
);

Map<String, Object?> _workItem({
  bool subscribed = false,
  bool widgetsUnavailable = false,
  bool absent = false,
  bool group = false,
}) => {
  'id': 'gid://gitlab/WorkItem/31',
  'iid': '31',
  'project': group ? null : {'id': _project.id, 'fullPath': _project.fullPath},
  'namespace': {
    'id': group ? _groupNamespace.id : _namespace.id,
    'fullPath': group ? _groupNamespace.fullPath : _namespace.fullPath,
  },
  'workItemType': {'id': 'gid://gitlab/WorkItems::Type/9'},
  'widgets': widgetsUnavailable
      ? null
      : absent
      ? <Object?>[]
      : [
          {'type': 'NOTIFICATIONS', 'subscribed': subscribed},
        ],
};

Map<String, Object?> _readEnvelope({
  bool subscribed = false,
  bool widgetsUnavailable = false,
  bool absent = false,
  bool anonymous = false,
  int actorId = 7,
  bool group = false,
}) => {
  'data': {
    'currentUser': anonymous ? null : {'id': 'gid://gitlab/User/$actorId'},
    'workItem': _workItem(
      subscribed: subscribed,
      widgetsUnavailable: widgetsUnavailable,
      absent: absent,
      group: group,
    ),
  },
};

final class _NotificationServer {
  bool subscribed;
  bool absent;
  bool widgetsUnavailable;
  bool anonymous = false;
  int actorId = 7;
  bool group;
  bool failNextRead = false;
  bool failNextMutationAfterApply = false;
  Completer<void>? mutationGate;
  int reads = 0;
  int writes = 0;

  _NotificationServer({
    this.subscribed = false,
    this.absent = false,
    this.widgetsUnavailable = false,
    this.group = false,
  });

  Future<ResponseBody> respond(RequestOptions request) async {
    final body = request.data as Map;
    final query = body['query'] as String;
    if (query.contains('MobileWorkItemNotifications')) {
      reads++;
      if (failNextRead) {
        failNextRead = false;
        return jsonResponse({'message': 'synthetic failure'}, status: 503);
      }
      return jsonResponse(
        _readEnvelope(
          subscribed: subscribed,
          absent: absent,
          widgetsUnavailable: widgetsUnavailable,
          anonymous: anonymous,
          actorId: actorId,
          group: group,
        ),
      );
    }
    if (query.contains('MobileSetWorkItemNotifications')) {
      writes++;
      final input = ((body['variables'] as Map)['input'] as Map);
      subscribed = input['subscribed'] as bool;
      await mutationGate?.future;
      if (failNextMutationAfterApply) {
        failNextMutationAfterApply = false;
        return jsonResponse({'message': 'lost acknowledgement'}, status: 503);
      }
      return jsonResponse({
        'data': {
          'workItemSubscribe': {
            'errors': <Object?>[],
            'workItem': _workItem(subscribed: subscribed, group: group),
          },
        },
      });
    }
    throw StateError('Unexpected operation');
  }
}

final class _Owner extends ChangeNotifier {
  bool current = true;

  void replace() {
    current = false;
    notifyListeners();
  }
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.text('通知訂閱'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('stays lazy until expanded and shows account-scoped state', (
    tester,
  ) async {
    final server = _NotificationServer();
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter, host: 'https://example.com:8443/gitlab');
    addTearDown(api.close);

    await tester.pumpWidget(_host(api: api));
    await tester.pump();
    expect(adapter.requests, isEmpty);

    await _expand(tester);
    expect(server.reads, 1);
    expect(find.text('GitLab 已確認：目前未訂閱。'), findsOneWidget);
    expect(find.text('訂閱通知'), findsOneWidget);
    expect(
      find.textContaining('@reader7 · https://example.com:8443/gitlab'),
      findsOneWidget,
    );
    expect(find.text('studio/mobile-workspace · 工作項目 #31'), findsOneWidget);
  });

  testWidgets('project toggle on and off uses confirmed readback', (
    tester,
  ) async {
    final server = _NotificationServer();
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api));
    await _expand(tester);

    await tester.tap(find.text('訂閱通知'));
    await tester.pumpAndSettle();
    expect(server.writes, 1);
    expect(find.text('GitLab 已確認：目前已訂閱。'), findsOneWidget);
    expect(find.text('取消訂閱通知'), findsOneWidget);

    await tester.tap(find.text('取消訂閱通知'));
    await tester.pumpAndSettle();
    expect(server.writes, 2);
    expect(find.text('GitLab 已確認：目前未訂閱。'), findsOneWidget);
  });

  testWidgets('group toggle uses the group-bound Work Item identity', (
    tester,
  ) async {
    final server = _NotificationServer(group: true);
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api, summary: _summary(group: true)));
    await _expand(tester);

    expect(find.text('studio/mobile-group · 工作項目 #31'), findsOneWidget);
    await tester.tap(find.text('訂閱通知'));
    await settleNetworkWidgets(tester);

    expect(server.writes, 1);
    expect(find.text('GitLab 已確認：目前已訂閱。'), findsOneWidget);
  });

  testWidgets('busy state prevents duplicate writes', (tester) async {
    final server = _NotificationServer()..mutationGate = Completer<void>();
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api));
    await _expand(tester);

    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '訂閱通知'),
    );
    button.onPressed!();
    button.onPressed!();
    await pumpUntil(tester, () => server.writes == 1);
    expect(server.writes, 1);
    expect(find.text('正在更新…'), findsOneWidget);

    server.mutationGate!.complete();
    await tester.pumpAndSettle();
    expect(server.writes, 1);
  });

  testWidgets('uncertain write blocks replay until manual refresh', (
    tester,
  ) async {
    final server = _NotificationServer()..failNextMutationAfterApply = true;
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api));
    await _expand(tester);

    await tester.tap(find.text('訂閱通知'));
    await pumpUntil(
      tester,
      () => find.text('操作結果尚未確認，已停用再次寫入。').evaluate().isNotEmpty,
    );
    expect(server.writes, 1);
    expect(find.text('操作結果尚未確認，已停用再次寫入。'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '訂閱通知'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('重新讀取通知設定'));
    await settleNetworkWidgets(tester);
    expect(find.text('GitLab 已確認：目前已訂閱。'), findsOneWidget);
    expect(find.text('取消訂閱通知'), findsOneWidget);
    expect(server.writes, 1);
  });

  testWidgets('failed refresh retains confirmed state but disables target', (
    tester,
  ) async {
    final server = _NotificationServer(subscribed: true);
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api));
    await _expand(tester);
    expect(find.text('GitLab 已確認：目前已訂閱。'), findsOneWidget);

    server.failNextRead = true;
    // Same-identity revision replacement refreshes only because it is expanded.
    await tester.pumpWidget(
      _host(
        api: api,
        summary: _summary(updatedAt: DateTime.utc(2026, 10, 3, 11)),
      ),
    );
    await pumpUntil(
      tester,
      () => find.text('重新讀取失敗；仍顯示上次確認的狀態，已停用變更。').evaluate().isNotEmpty,
    );

    expect(find.text('GitLab 已確認：目前已訂閱。'), findsOneWidget);
    expect(find.text('重新讀取失敗；仍顯示上次確認的狀態，已停用變更。'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '取消訂閱通知'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('absent and widgets unavailable are explicit read-only states', (
    tester,
  ) async {
    for (final unavailable in [false, true]) {
      final server = _NotificationServer(
        absent: !unavailable,
        widgetsUnavailable: unavailable,
      );
      final adapter = FakeAdapter(server.respond);
      final api = testApi(adapter);
      await tester.pumpWidget(_host(api: api));
      await _expand(tester);

      expect(
        find.byKey(
          ValueKey(
            unavailable
                ? 'work-item-notifications-widgets-unavailable'
                : 'work-item-notifications-absent',
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('訂閱通知'), findsNothing);
      api.close();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('unsupported schema is visible and never exposes a write', (
    tester,
  ) async {
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse({
          'errors': [
            {
              'message': 'Unknown field',
              'extensions': {'code': 'undefinedField'},
            },
          ],
        }),
      ),
    );
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api));
    await _expand(tester);

    expect(find.text('實例未提供工作項目通知設定'), findsOneWidget);
    expect(find.text('訂閱通知'), findsNothing);
    expect(find.text('切換帳號'), findsOneWidget);
  });

  testWidgets('invisible resource keeps account scope retry and switch', (
    tester,
  ) async {
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': null,
          },
        }),
      ),
      host: 'https://example.com:8443/gitlab',
    );
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api));
    await _expand(tester);

    expect(find.text('重新整理'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    expect(find.text('實例：https://example.com:8443/gitlab'), findsOneWidget);
    expect(find.text('目標：studio/mobile-workspace · 工作項目 #31'), findsOneWidget);
    expect(find.text('訂閱通知'), findsNothing);
  });

  testWidgets('owner invalidation ignores a late response', (tester) async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => pending.future);
    final api = testApi(adapter);
    addTearDown(api.close);
    final owner = _Owner();
    await tester.pumpWidget(
      _host(api: api, isCurrent: () => owner.current, ownerChanges: owner),
    );
    await tester.tap(find.text('通知訂閱'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('work-item-notifications-loading')),
      findsOneWidget,
    );

    owner.replace();
    pending.complete(jsonResponse(_readEnvelope(subscribed: true)));
    await tester.pumpAndSettle();

    expect(find.text('GitLab 已確認：目前已訂閱。'), findsNothing);
    expect(find.text('訂閱通知'), findsNothing);
    expect(find.text('讀取通知設定'), findsOneWidget);
  });

  testWidgets('actor mismatch on refresh clears prior confirmed state', (
    tester,
  ) async {
    final server = _NotificationServer(subscribed: true);
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api));
    await _expand(tester);
    expect(find.text('GitLab 已確認：目前已訂閱。'), findsOneWidget);

    server.actorId = 8;
    await tester.pumpWidget(
      _host(
        api: api,
        summary: _summary(updatedAt: DateTime.utc(2026, 10, 3, 12)),
      ),
    );
    await pumpUntil(
      tester,
      () => find.text('GitLab 登入帳號已變更').evaluate().isNotEmpty,
    );

    expect(find.text('GitLab 已確認：目前已訂閱。'), findsNothing);
    expect(find.text('取消訂閱通知'), findsNothing);
    expect(find.text('切換帳號'), findsOneWidget);
  });

  testWidgets('lost actor during preflight sends no mutation', (tester) async {
    final server = _NotificationServer();
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);
    await tester.pumpWidget(_host(api: api));
    await _expand(tester);

    server.anonymous = true;
    await tester.tap(find.text('訂閱通知'));
    await pumpUntil(tester, () => find.text('登入已失效').evaluate().isNotEmpty);

    expect(server.writes, 0);
    expect(find.text('GitLab 已確認：目前未訂閱。'), findsNothing);
    expect(find.text('訂閱通知'), findsNothing);
    expect(find.text('切換帳號'), findsOneWidget);
  });

  testWidgets('large text narrow layout has no overflow and 48dp actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final server = _NotificationServer();
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);

    await tester.pumpWidget(_host(api: api, textScale: 2));
    await _expand(tester);

    final button = find.widgetWithText(OutlinedButton, '訂閱通知');
    expect(button, findsOneWidget);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));

    server.failNextMutationAfterApply = true;
    await tester.tap(find.text('訂閱通知'));
    await pumpUntil(tester, () => find.text('重新讀取通知設定').evaluate().isNotEmpty);
    final refreshButton = find.widgetWithText(OutlinedButton, '重新讀取通知設定');
    await tester.ensureVisible(refreshButton);
    await tester.pump();
    final buttonRect = tester.getRect(refreshButton);
    final labelRect = tester.getRect(find.text('重新讀取通知設定'));
    expect(buttonRect.height, greaterThanOrEqualTo(48));
    expect(labelRect.top, greaterThanOrEqualTo(buttonRect.top));
    expect(labelRect.bottom, lessThanOrEqualTo(buttonRect.bottom));
    expect(tester.takeException(), isNull);
  });
}
