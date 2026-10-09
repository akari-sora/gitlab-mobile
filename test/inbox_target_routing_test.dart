import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/commit_page.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/fake_adapter.dart';
import 'support/inbox_target_routing_fixture.dart';
import 'support/widget_settle.dart';

const _epicUrl = 'https://example.com/gitlab/groups/team/-/epics/3';

void main() {
  late InboxFakeUrlLauncher launcher;
  late UrlLauncherPlatform originalLauncher;

  setUp(() {
    launcher = InboxFakeUrlLauncher();
    originalLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
  });

  tearDown(() => UrlLauncherPlatform.instance = originalLauncher);

  Future<GitLabApi> pumpInbox(
    WidgetTester tester,
    InboxTodoServer server, {
    Account? account,
    Size size = const Size(412, 2400),
    double devicePixelRatio = 1,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.view.physicalSize = size * devicePixelRatio;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = testApi(server.adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        builder: textScale == 1
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
        home: InboxPage(account: account ?? inboxAccount(), api: api),
      ),
    );
    await settleNetworkWidgets(tester);
    return api;
  }

  Finder inSheet(Finder finder) =>
      find.descendant(of: find.byType(BottomSheet), matching: finder);

  testWidgets(
    'unsupported epic todo taps into an explanation with the canonical web action',
    (tester) async {
      final server = InboxTodoServer([
        inboxTodo(
          1,
          'Epic',
          'Roadmap epic',
          project: null,
          targetUrl: _epicUrl,
        ),
      ]);
      await pumpInbox(tester, server);

      expect(find.text('史詩 · 網頁版'), findsOneWidget);
      await tester.tap(find.text('Roadmap epic'));
      await settleNetworkWidgets(tester);

      expect(inSheet(find.text('無法在 App 內開啟')), findsOneWidget);
      expect(inSheet(find.text('「史詩」類型的待辦目前沒有 App 內頁面。')), findsOneWidget);
      expect(inSheet(find.text(_epicUrl)), findsOneWidget);
      expect(
        find.textContaining('Epic'),
        findsNothing,
        reason: 'the raw target_type must not reach the UI',
      );
      expect(
        server.nonTodoRequests,
        isEmpty,
        reason: 'no native lookup is attempted for an unsupported target',
      );

      await tester.tap(find.byKey(const ValueKey('todo-target-open-web')));
      await settleNetworkWidgets(tester);
      expect(launcher.launched, [_epicUrl]);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Roadmap epic'), findsOneWidget);
      expect(server.completed, isEmpty);
    },
  );

  testWidgets(
    'unknown target type still taps and explains with a generic label',
    (tester) async {
      const url = 'https://example.com/gitlab/team/core/-/somewhere/9#note_1';
      final server = InboxTodoServer([
        inboxTodo(2, 'Brand::NewThing', 'Future todo', targetUrl: url),
      ]);
      await pumpInbox(tester, server);

      await tester.tap(find.text('Future todo'));
      await settleNetworkWidgets(tester);

      expect(
        inSheet(find.text('「其他 GitLab 項目」類型的待辦目前沒有 App 內頁面。')),
        findsOneWidget,
      );
      expect(find.textContaining('Brand'), findsNothing);
      expect(find.textContaining('NewThing'), findsNothing);
      expect(
        find.byKey(const ValueKey('todo-target-open-web')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('todo-target-close')));
      await settleNetworkWidgets(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(launcher.launched, isEmpty);
    },
  );

  testWidgets(
    'missing or off-instance target links disable web open and offer refresh and close',
    (tester) async {
      const invalid = <String, Object?>{
        'Missing link': null,
        'Empty link': '',
        'Not a string': 42,
        'Cleartext link': 'http://example.com/gitlab/team/core/-/epics/1',
        'Third-party host': 'https://evil.example/gitlab/team/core/-/epics/1',
        'Other port': 'https://example.com:8443/gitlab/team/core/-/epics/1',
        'Outside subpath': 'https://example.com/other/team/core/-/epics/1',
        'Instance root only': 'https://example.com/gitlab/',
        'User info':
            'https://user:secret@example.com/gitlab/team/core/-/epics/1',
        'Token query':
            'https://example.com/gitlab/team/core/-/epics/1?private_token=abc',
        'Dot segments':
            'https://example.com/gitlab/../gitlab/team/core/-/epics/1',
        'Encoded slash': 'https://example.com/gitlab/team%2Fcore/-/epics/1',
        'Backslash path': 'https://example.com/gitlab/team\\core/-/epics/1',
        'Double slash': 'https://example.com/gitlab//team/core/-/epics/1',
        'Encoded dot':
            'https://example.com/gitlab/%2e%2e/gitlab/team/core/-/epics/1',
        'Encoded dot upper':
            'https://example.com/gitlab/team/core/-/epics/%2E1',
        'Encoded backslash': 'https://example.com/gitlab/team%5ccore/-/epics/1',
        'Script scheme': 'javascript:alert(1)',
        'Backslash authority':
            'https://evil.example\\@example.com/gitlab/team/core/-/epics/1',
      };
      var id = 10;
      final server = InboxTodoServer([
        for (final entry in invalid.entries)
          inboxTodo(
            id++,
            'Epic',
            entry.key,
            project: null,
            targetUrl: entry.value,
          ),
      ]);
      await pumpInbox(tester, server, size: const Size(412, 4800));

      expect(find.text('史詩 · 無法開啟'), findsNWidgets(invalid.length));
      expect(
        find.byTooltip('完成此待辦'),
        findsNWidgets(invalid.length),
        reason: 'completion stays available on rows that cannot open',
      );

      for (final title in invalid.keys) {
        await tester.ensureVisible(find.text(title));
        await tester.tap(find.text(title));
        await settleNetworkWidgets(tester);
        expect(inSheet(find.text('無法開啟此待辦')), findsOneWidget, reason: title);
        expect(
          find.byKey(const ValueKey('todo-target-open-web')),
          findsNothing,
          reason: title,
        );
        expect(
          find.byKey(const ValueKey('todo-target-web-url')),
          findsNothing,
          reason: title,
        );
        expect(
          find.byKey(const ValueKey('todo-target-refresh')),
          findsOneWidget,
          reason: title,
        );
        await tester.tap(find.byKey(const ValueKey('todo-target-close')));
        await settleNetworkWidgets(tester);
        expect(find.byType(BottomSheet), findsNothing, reason: title);
      }
      expect(launcher.launched, isEmpty);
      expect(server.todoGets, 1);

      await tester.tap(find.text('Missing link'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byKey(const ValueKey('todo-target-refresh')));
      await settleNetworkWidgets(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(server.todoGets, 2, reason: '重新整理 reloads the todo list');
      expect(server.nonTodoRequests, isEmpty);
    },
  );

  testWidgets(
    'supported types without sufficient identity explain instead of guessing a route',
    (tester) async {
      final server = InboxTodoServer([
        inboxTodo(
          20,
          'Issue',
          'Issue without iid',
          target: {'id': 501, 'title': 'Issue without iid'},
        ),
        inboxTodo(
          21,
          'MergeRequest',
          'MR without project',
          target: {'id': 601, 'iid': 22, 'title': 'MR without project'},
          project: null,
        ),
        inboxTodo(
          22,
          'Commit',
          'Short commit',
          target: {'id': '0123456', 'title': 'Short commit'},
        ),
      ]);
      await pumpInbox(tester, server);

      for (final (title, label) in [
        ('Issue without iid', '議題'),
        ('MR without project', '合併請求'),
        ('Short commit', '提交'),
      ]) {
        await tester.tap(find.text(title));
        await settleNetworkWidgets(tester);
        expect(
          inSheet(find.text('這則$label待辦缺少可辨識目標的資料，無法在 App 內開啟。')),
          findsOneWidget,
          reason: title,
        );
        expect(
          find.byKey(const ValueKey('todo-target-open-web')),
          findsNothing,
          reason: title,
        );
        await tester.tap(find.byKey(const ValueKey('todo-target-close')));
        await settleNetworkWidgets(tester);
      }
      expect(
        server.nonTodoRequests,
        isEmpty,
        reason: 'no project, issue or commit read is guessed from partial data',
      );
      expect(find.byType(WorkItemPage), findsNothing);
      expect(find.byType(CommitDetailPage), findsNothing);
    },
  );

  testWidgets('issue todo keeps the native work item route', (tester) async {
    final server = InboxTodoServer([
      inboxTodo(
        30,
        'Issue',
        'Native issue todo',
        target: {'id': 501, 'iid': 42, 'title': 'Native issue todo'},
        targetUrl: _epicUrl,
      ),
    ]);
    await pumpInbox(tester, server);

    await tester.tap(find.text('Native issue todo'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsNothing);
    final page = tester.widget<WorkItemPage>(find.byType(WorkItemPage));
    expect(page.resource, 'issues');
    expect(page.iid, 42);
    expect(page.project.id, 10);
    expect(launcher.launched, isEmpty);
  });

  testWidgets('commit todo with a full SHA opens the native commit page', (
    tester,
  ) async {
    final server = InboxTodoServer([
      inboxTodo(
        31,
        'Commit',
        'Native commit todo',
        target: {'id': inboxCommitSha, 'title': 'Native commit todo'},
      ),
    ]);
    await pumpInbox(tester, server);

    await tester.tap(find.text('Native commit todo'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsNothing);
    final page = tester.widget<CommitDetailPage>(find.byType(CommitDetailPage));
    expect(page.sha, inboxCommitSha);
    expect(page.project.id, 10);
  });

  testWidgets(
    'a native todo route resolved after an owner switch never opens for the new owner',
    (tester) async {
      final gate = Completer<ResponseBody>();
      final first = InboxTodoServer([
        inboxTodo(
          40,
          'Issue',
          'First owner issue',
          target: {'id': 501, 'iid': 42, 'title': 'First owner issue'},
        ),
      ])..projectGate = () => gate.future;
      final second = InboxTodoServer([
        inboxTodo(
          41,
          'Epic',
          'Second owner epic',
          project: null,
          targetUrl: _epicUrl,
        ),
      ]);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 2400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final firstApi = testApi(first.adapter);
      final secondApi = testApi(second.adapter);
      addTearDown(firstApi.close);
      addTearDown(secondApi.close);
      var generation = 1;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return KeyedSubtree(
                key: ValueKey(generation),
                child: generation == 1
                    ? InboxPage(account: inboxAccount(), api: firstApi)
                    : InboxPage(
                        account: inboxAccount(id: 8, username: 'second'),
                        api: secondApi,
                      ),
              );
            },
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('First owner issue'));
      await pumpUntil(
        tester,
        () => first.nonTodoRequests.isNotEmpty,
        description: 'the first owner project lookup is in flight',
      );
      expect(
        first.nonTodoRequests.map((r) => r.uri.path),
        contains(endsWith('/projects/10')),
      );

      rebuild(() => generation = 2);
      await tester.pump();
      gate.complete(jsonResponse(inboxProject));
      await settleNetworkWidgets(tester);

      expect(find.byType(WorkItemPage), findsNothing);
      expect(find.text('First owner issue'), findsNothing);
      expect(find.text('Second owner epic'), findsOneWidget);
      expect(second.nonTodoRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completing an unsupported todo stays separate from opening it', (
    tester,
  ) async {
    final server = InboxTodoServer([
      inboxTodo(50, 'Epic', 'Done epic', project: null, targetUrl: _epicUrl),
      inboxTodo(51, 'Brand::NewThing', 'Unopenable todo'),
    ]);
    await pumpInbox(tester, server);

    final doneButtons = find.byTooltip('完成此待辦');
    expect(doneButtons, findsNWidgets(2));
    await tester.tap(doneButtons.first);
    await settleNetworkWidgets(tester);

    expect(server.completed, {50});
    expect(find.byType(BottomSheet), findsNothing);
    expect(launcher.launched, isEmpty);
    expect(find.text('Done epic'), findsNothing);
    expect(find.text('Unopenable todo'), findsOneWidget);
    expect(
      server.requests.where((r) => r.method == 'POST').map((r) => r.uri.path),
      [endsWith('/todos/50/mark_as_done')],
    );
  });

  testWidgets(
    'explanation sheet leaves the pending query and retained panes untouched',
    (tester) async {
      final server = InboxTodoServer([
        inboxTodo(
          60,
          'Epic',
          'Retained epic',
          project: null,
          targetUrl: _epicUrl,
        ),
      ]);
      await pumpInbox(tester, server);

      await tester.tap(find.text('Retained epic'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byKey(const ValueKey('todo-target-close')));
      await settleNetworkWidgets(tester);

      for (final tab in ['指派給我', '待辦']) {
        await tester.tap(find.text(tab));
        await settleNetworkWidgets(tester);
      }
      expect(find.text('Retained epic'), findsOneWidget);
      expect(
        server.todoGets,
        1,
        reason: 'the todo pane is retained, not reloaded',
      );
      final todoGets = server.requests.where(
        (r) => r.uri.path.endsWith('/todos'),
      );
      expect(
        todoGets.map((r) => r.uri.queryParameters['state']),
        everyElement('pending'),
      );
      expect(server.requests.where((r) => r.method != 'GET'), isEmpty);
    },
  );

  testWidgets(
    'web action hands the exact server link with its query and fragment to the launcher',
    (tester) async {
      const url =
          'https://example.com/gitlab/team/core/-/work_items/5?show=a%20b&tab=notes#note_9';
      final server = InboxTodoServer([
        inboxTodo(70, 'WorkItem', 'Exact link todo', targetUrl: url),
      ]);
      await pumpInbox(tester, server);

      expect(find.text('工作項目 · 網頁版'), findsOneWidget);
      await tester.tap(find.text('Exact link todo'));
      await settleNetworkWidgets(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('todo-target-web-url')))
            .data,
        url,
      );

      await tester.tap(find.byKey(const ValueKey('todo-target-open-web')));
      await settleNetworkWidgets(tester);
      expect(launcher.launched, [url]);
      expect(server.nonTodoRequests, isEmpty);
    },
  );

  testWidgets(
    'a closed session client never launches from an explanation sheet left open',
    (tester) async {
      final server = InboxTodoServer([
        inboxTodo(
          80,
          'Epic',
          'Closing epic',
          project: null,
          targetUrl: _epicUrl,
        ),
      ]);
      final api = await pumpInbox(tester, server);

      await tester.tap(find.text('Closing epic'));
      await settleNetworkWidgets(tester);
      expect(
        find.byKey(const ValueKey('todo-target-open-web')),
        findsOneWidget,
      );

      api.close();
      await tester.tap(find.byKey(const ValueKey('todo-target-open-web')));
      await settleNetworkWidgets(tester);

      expect(launcher.launched, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      expect(server.nonTodoRequests, isEmpty);
    },
  );

  testWidgets(
    'an owner switch while the explanation sheet is open never launches for either owner',
    (tester) async {
      final first = InboxTodoServer([
        inboxTodo(
          81,
          'Epic',
          'First owner epic',
          project: null,
          targetUrl: _epicUrl,
        ),
      ]);
      final second = InboxTodoServer([
        inboxTodo(82, 'Brand::NewThing', 'Second owner todo'),
      ]);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 2400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final firstApi = testApi(first.adapter);
      final secondApi = testApi(second.adapter);
      addTearDown(firstApi.close);
      addTearDown(secondApi.close);
      var swapped = false;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return swapped
                  ? InboxPage(
                      account: inboxAccount(id: 8, username: 'second'),
                      api: secondApi,
                    )
                  : InboxPage(account: inboxAccount(), api: firstApi);
            },
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('First owner epic'));
      await settleNetworkWidgets(tester);
      expect(inSheet(find.text('無法在 App 內開啟')), findsOneWidget);

      rebuild(() => swapped = true);
      await settleNetworkWidgets(tester);
      expect(
        find.byKey(const ValueKey('todo-target-open-web')),
        findsOneWidget,
        reason: 'the sheet route outlives the in-place owner swap',
      );

      await tester.tap(find.byKey(const ValueKey('todo-target-open-web')));
      await settleNetworkWidgets(tester);

      expect(launcher.launched, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('First owner epic'), findsNothing);
      expect(find.text('Second owner todo'), findsOneWidget);
      expect(first.todoGets, 1);
      expect(first.nonTodoRequests, isEmpty);
      expect(second.nonTodoRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rows and explanation sheets fit 320dp at 2x text with CJK and keep 48dp targets',
    (tester) async {
      const title = '這是一則非常長的中文待辦標題，用來確認在窄螢幕與兩倍字級下不會溢出版面，也不會遮住任何操作按鈕';
      const url =
          'https://example.com/gitlab/team/core/-/issues/7/designs/mockup';
      final server = InboxTodoServer([
        inboxTodo(90, 'DesignManagement::Design', title, targetUrl: url),
        inboxTodo(91, 'AlertManagement::Alert', '沒有連結的警示待辦'),
      ]);
      await pumpInbox(
        tester,
        server,
        size: const Size(320, 1400),
        devicePixelRatio: 2,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);

      void expectTarget(Finder finder) {
        final size = tester.getSize(finder);
        expect(size.width, greaterThanOrEqualTo(48), reason: '$finder');
        expect(size.height, greaterThanOrEqualTo(48), reason: '$finder');
      }

      expect(find.text('設計稿 · 網頁版'), findsOneWidget);
      expect(find.text('警示 · 無法開啟'), findsOneWidget);
      final doneButtons = find.widgetWithIcon(
        IconButton,
        Icons.check_circle_outline,
      );
      expect(doneButtons, findsNWidgets(2));
      expectTarget(doneButtons.first);
      expectTarget(doneButtons.last);
      expectTarget(find.byKey(const ValueKey('todo-90')));
      expectTarget(find.byKey(const ValueKey('todo-91')));

      await tester.tap(find.text(title));
      await settleNetworkWidgets(tester);
      expect(tester.takeException(), isNull);
      expect(inSheet(find.text('「設計稿」類型的待辦目前沒有 App 內頁面。')), findsOneWidget);
      for (final key in ['todo-target-close', 'todo-target-open-web']) {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pump();
        expectTarget(find.byKey(ValueKey(key)));
      }
      await tester.tap(find.byKey(const ValueKey('todo-target-open-web')));
      await settleNetworkWidgets(tester);
      expect(launcher.launched, [url]);
      expect(find.byType(BottomSheet), findsNothing);

      await tester.tap(find.text('沒有連結的警示待辦'));
      await settleNetworkWidgets(tester);
      expect(tester.takeException(), isNull);
      expect(inSheet(find.text('無法開啟此待辦')), findsOneWidget);
      for (final key in ['todo-target-refresh', 'todo-target-close']) {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pump();
        expectTarget(find.byKey(ValueKey(key)));
      }
      await tester.tap(find.byKey(const ValueKey('todo-target-close')));
      await settleNetworkWidgets(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
      expect(server.nonTodoRequests, isEmpty);
    },
  );
}
