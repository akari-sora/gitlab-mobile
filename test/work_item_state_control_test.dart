import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_state_control.dart';

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
final _initialTime = DateTime.utc(2026, 10, 3, 10);
final _freshTime = DateTime.utc(2026, 10, 3, 11);

WorkItemGraphSummary _summary({String state = 'OPEN', DateTime? updatedAt}) =>
    WorkItemGraphSummary(
      id: 'gid://gitlab/WorkItem/31',
      iid: 31,
      title: 'Synthetic mobile work item',
      state: state,
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: updatedAt ?? _initialTime,
      project: _project,
      namespace: _namespace,
      type: const WorkItemGraphType(
        id: 'gid://gitlab/WorkItems::Type/9',
        name: 'Task',
      ),
    );

WorkItemStateSnapshot _snapshot({
  WorkItemState state = WorkItemState.open,
  DateTime? updatedAt,
  bool canUpdate = true,
}) => WorkItemStateSnapshot(
  id: 'gid://gitlab/WorkItem/31',
  iid: 31,
  state: state,
  updatedAt: updatedAt ?? _initialTime,
  project: _project,
  namespace: _namespace,
  typeId: 'gid://gitlab/WorkItems::Type/9',
  canUpdate: canUpdate,
);

Account _account(GitLabApi api, {int user = 7}) => Account(
  instance: api.instance,
  user: GitLabUser(id: user, username: 'reader$user', name: 'Reader $user'),
  token: 'synthetic-token',
);

Widget _host({
  required GitLabApi api,
  required WorkItemStateLoader load,
  WorkItemStateUpdater? update,
  WorkItemStateConfirmer? confirm,
  Future<void> Function(WorkItemStateSnapshot)? onChanged,
  WorkItemGraphSummary? summary,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  double textScale = 1,
  int user = 7,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: WorkItemStateControl(
        account: _account(api, user: user),
        api: api,
        summary: summary ?? _summary(),
        loadState: load,
        updateState: update,
        confirmChange: confirm,
        onChanged: onChanged,
        isCurrent: isCurrent,
        ownerChanges: ownerChanges,
      ),
    ),
  ),
);

final class _Owner extends ChangeNotifier {
  bool current = true;

  void replace() {
    current = false;
    notifyListeners();
  }
}

void main() {
  testWidgets('loading and permission denial are explicit and disable writes', (
    tester,
  ) async {
    final api = testApi(FakeAdapter((_) => jsonResponse({})));
    addTearDown(api.close);
    final pending = Completer<WorkItemStateSnapshot>();

    await tester.pumpWidget(
      _host(
        api: api,
        load: (_, {isCurrent}) => pending.future,
        update: (_, _, {required expectedUpdatedAt, isCurrent}) =>
            throw StateError('must not write'),
      ),
    );
    // The first read shows the state's shape; no write button exists yet.
    expect(
      find.byKey(const ValueKey('work-item-state-loading')),
      findsOneWidget,
    );
    expect(find.byType(OutlinedButton), findsNothing);

    pending.complete(_snapshot(canUpdate: false));
    await tester.pumpAndSettle();

    expect(find.text('目前為開啟'), findsOneWidget);
    expect(find.text('目前帳號沒有更新這個工作項目的權限。'), findsOneWidget);
    expect(find.text('關閉工作項目'), findsNothing);
  });

  testWidgets(
    'confirmation names account instance resource and cancel is idle',
    (tester) async {
      final api = testApi(
        FakeAdapter((_) => jsonResponse({})),
        host: 'https://example.com:8443/gitlab',
      );
      addTearDown(api.close);
      var writes = 0;
      await tester.pumpWidget(
        _host(
          api: api,
          load: (_, {isCurrent}) async => _snapshot(),
          update: (_, _, {required expectedUpdatedAt, isCurrent}) async {
            writes++;
            return _snapshot(state: WorkItemState.closed);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('關閉工作項目'));
      await tester.pumpAndSettle();

      expect(find.text('關閉工作項目？'), findsOneWidget);
      expect(
        find.textContaining('@reader7 · https://example.com:8443/gitlab'),
        findsOneWidget,
      );
      expect(
        find.textContaining('studio/mobile-workspace · #31'),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(writes, 0);
      expect(find.text('關閉工作項目'), findsOneWidget);
    },
  );

  testWidgets(
    'double tap starts one mutation and refresh callback follows success',
    (tester) async {
      final api = testApi(FakeAdapter((_) => jsonResponse({})));
      addTearDown(api.close);
      final write = Completer<WorkItemStateSnapshot>();
      var writes = 0;
      var refreshes = 0;
      await tester.pumpWidget(
        _host(
          api: api,
          load: (_, {isCurrent}) async => _snapshot(),
          confirm: (_, _, _) async => true,
          update: (_, event, {required expectedUpdatedAt, isCurrent}) {
            writes++;
            expect(event, WorkItemStateEvent.close);
            expect(expectedUpdatedAt, _initialTime);
            return write.future;
          },
          onChanged: (_) async => refreshes++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('關閉工作項目'));
      await tester.tap(find.text('關閉工作項目'));
      await tester.pump();
      expect(writes, 1);

      write.complete(
        _snapshot(state: WorkItemState.closed, updatedAt: _freshTime),
      );
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(find.text('重新開啟'), findsOneWidget);
    },
  );

  testWidgets('double tap opens only one confirmation dialog', (tester) async {
    final api = testApi(FakeAdapter((_) => jsonResponse({})));
    addTearDown(api.close);
    var writes = 0;
    await tester.pumpWidget(
      _host(
        api: api,
        load: (_, {isCurrent}) async => _snapshot(),
        update: (_, _, {required expectedUpdatedAt, isCurrent}) async {
          writes++;
          return _snapshot(state: WorkItemState.closed);
        },
      ),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '關閉工作項目'),
    );
    button.onPressed!();
    button.onPressed!();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, 0);
  });

  testWidgets(
    'same-owner timestamp replacement dismisses pending confirmation',
    (tester) async {
      final api = testApi(FakeAdapter((_) => jsonResponse({})));
      addTearDown(api.close);
      final owner = _Owner();
      Future<WorkItemStateSnapshot> load(
        WorkItemGraphSummary _, {
        bool Function()? isCurrent,
      }) async => _snapshot();

      await tester.pumpWidget(
        _host(
          api: api,
          summary: _summary(),
          load: load,
          isCurrent: () => owner.current,
          ownerChanges: owner,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('關閉工作項目'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.pumpWidget(
        _host(
          api: api,
          summary: _summary(updatedAt: _freshTime),
          load: load,
          isCurrent: () => owner.current,
          ownerChanges: owner,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'uncertain write requires reread and rebases the next write on fresh state',
    (tester) async {
      final api = testApi(FakeAdapter((_) => jsonResponse({})));
      addTearDown(api.close);
      var reads = 0;
      var writes = 0;
      final expectedStates = <String>[];
      final expectedTimes = <DateTime>[];
      final observedStates = <WorkItemState>[];
      await tester.pumpWidget(
        _host(
          api: api,
          summary: _summary(),
          load: (_, {isCurrent}) async {
            reads++;
            return reads == 1
                ? _snapshot()
                : _snapshot(state: WorkItemState.closed, updatedAt: _freshTime);
          },
          confirm: (_, _, _) async => true,
          update:
              (expected, event, {required expectedUpdatedAt, isCurrent}) async {
                writes++;
                expectedStates.add(expected.state);
                expectedTimes.add(expected.updatedAt);
                if (writes == 1) {
                  throw const ApiFailure(FailureKind.writeUncertain);
                }
                expect(event, WorkItemStateEvent.reopen);
                return _snapshot(
                  state: WorkItemState.open,
                  updatedAt: _freshTime,
                );
              },
          onChanged: (state) async => observedStates.add(state.state),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('關閉工作項目'));
      await tester.pumpAndSettle();
      expect(find.text('操作結果尚未確認，已停用再次寫入。'), findsOneWidget);
      expect(find.text('關閉工作項目'), findsNothing);
      expect(writes, 1);

      await tester.tap(find.text('重新讀取狀態'));
      await tester.pumpAndSettle();
      expect(find.text('目前為已關閉'), findsOneWidget);
      expect(find.text('重新開啟'), findsOneWidget);
      expect(observedStates, [WorkItemState.closed]);

      await tester.tap(find.text('重新開啟'));
      await tester.pumpAndSettle();
      expect(writes, 2);
      expect(expectedStates, ['OPEN', 'CLOSED']);
      expect(expectedTimes, [_initialTime, _freshTime]);
      expect(observedStates, [WorkItemState.closed, WorkItemState.open]);
    },
  );

  testWidgets('unsupported capability retries and does not expose a write', (
    tester,
  ) async {
    final api = testApi(FakeAdapter((_) => jsonResponse({})));
    addTearDown(api.close);
    var reads = 0;
    await tester.pumpWidget(
      _host(
        api: api,
        load: (_, {isCurrent}) async {
          if (reads++ == 0) {
            throw const ApiFailure(
              FailureKind.unsupported,
              title: '實例未提供工作項目狀態操作',
            );
          }
          return _snapshot();
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('實例未提供工作項目狀態操作'), findsOneWidget);
    expect(find.text('關閉工作項目'), findsNothing);
    await tester.tap(find.text('重新讀取狀態'));
    await tester.pumpAndSettle();
    expect(find.text('關閉工作項目'), findsOneWidget);
  });

  testWidgets('default API 404 settles into an explicit retry state', (
    tester,
  ) async {
    final api = testApi(FakeAdapter((_) => jsonResponse({}, status: 404)));
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkItemStateControl(
            account: _account(api),
            api: api,
            summary: _summary(),
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('重新讀取狀態'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'owner replacement dismisses confirmation and rejects late reads',
    (tester) async {
      final api = testApi(FakeAdapter((_) => jsonResponse({})));
      addTearDown(api.close);
      final owner = _Owner();
      var writes = 0;
      await tester.pumpWidget(
        _host(
          api: api,
          load: (_, {isCurrent}) async => _snapshot(),
          update: (_, _, {required expectedUpdatedAt, isCurrent}) async {
            writes++;
            return _snapshot(state: WorkItemState.closed);
          },
          isCurrent: () => owner.current,
          ownerChanges: owner,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('關閉工作項目'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      owner.replace();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('關閉工作項目'), findsNothing);
      expect(writes, 0);
    },
  );

  testWidgets('stale owner guard blocks confirmation without a notification', (
    tester,
  ) async {
    final api = testApi(FakeAdapter((_) => jsonResponse({})));
    addTearDown(api.close);
    var current = true;
    var confirms = 0;
    await tester.pumpWidget(
      _host(
        api: api,
        load: (_, {isCurrent}) async => _snapshot(),
        isCurrent: () => current,
        confirm: (_, _, _) async {
          confirms++;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    current = false;
    await tester.tap(find.text('關閉工作項目'));
    await tester.pump();

    expect(confirms, 0);
  });

  testWidgets('320x718dp at 2x text keeps confirmation actions reachable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 718));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = testApi(FakeAdapter((_) => jsonResponse({})));
    addTearDown(api.close);

    await tester.pumpWidget(
      _host(
        api: api,
        textScale: 2,
        load: (_, {isCurrent}) async => _snapshot(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('關閉工作項目'), findsOneWidget);
    await tester.tap(find.text('關閉工作項目'));
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('確認關閉'), findsOneWidget);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
