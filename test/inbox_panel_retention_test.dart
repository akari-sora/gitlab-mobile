import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

void main() {
  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final firstAccount = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'first', name: 'First'),
    token: 'synthetic-first',
  );
  final secondAccount = Account(
    instance: instance,
    user: const GitLabUser(id: 8, username: 'second', name: 'Second'),
    token: 'synthetic-second',
  );

  testWidgets(
    'all inbox panels load once and retain page two cursor rows and scroll across tab cycles',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final firstPageGets = <String, int>{};
      var todoPageTwoGets = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        final page = request.uri.queryParameters['page'];
        if (path.endsWith('/todos')) {
          if (page == '2') {
            todoPageTwoGets++;
            return jsonResponse(
              [_todo(100, 'Todo page two')],
              headers: {'x-next-page': ['3']},
            );
          }
          firstPageGets['todos'] = (firstPageGets['todos'] ?? 0) + 1;
          return jsonResponse(
            [for (var id = 1; id <= 30; id++) _todo(id, 'Todo $id')],
            headers: {'x-next-page': ['2']},
          );
        }
        if (path.endsWith('/issues')) {
          expect(request.uri.queryParameters['scope'], 'assigned_to_me');
          firstPageGets['assigned'] = (firstPageGets['assigned'] ?? 0) + 1;
          return jsonResponse([_workItem(201, 'Assigned issue')]);
        }
        if (path.endsWith('/merge_requests') &&
            request.uri.queryParameters['reviewer_id'] != null) {
          expect(request.uri.queryParameters['reviewer_id'], '7');
          firstPageGets['review'] = (firstPageGets['review'] ?? 0) + 1;
          return jsonResponse([_workItem(301, 'Review request')]);
        }
        if (path.endsWith('/merge_requests')) {
          expect(request.uri.queryParameters['scope'], 'created_by_me');
          firstPageGets['created'] = (firstPageGets['created'] ?? 0) + 1;
          return jsonResponse([_workItem(401, 'Created merge request')]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(home: InboxPage(account: firstAccount, api: api)),
      );
      await settleNetworkWidgets(tester);

      for (final tab in ['指派給我', '待我審查', '我建立的', '待辦']) {
        await tester.tap(find.text(tab));
        await settleNetworkWidgets(tester);
      }
      expect(firstPageGets, {
        'todos': 1,
        'assigned': 1,
        'review': 1,
        'created': 1,
      });

      final todoFeed = _feed(tester, 'todos');
      final todoScroll = _scrollView(tester, todoFeed);
      // The button lives in a sliver after 30 lazily built rows, so it has no
      // element until the todo list itself is scrolled toward it.
      await tester.scrollUntilVisible(
        find.text('載入更多'),
        300,
        scrollable: find
            .descendant(of: todoScroll, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(find.text('載入更多'));
      await settleNetworkWidgets(tester);
      expect(todoPageTwoGets, 1);
      expect(find.text('Todo page two'), findsOneWidget);

      expect(todoFeed.controller.items, hasLength(31));
      expect(todoFeed.controller.next?.queryParameters['page'], '3');
      final scrollController =
          tester.widget<CustomScrollView>(todoScroll).controller!;
      scrollController.jumpTo(scrollController.offset - 300);
      await tester.pump();
      final retainedOffset = scrollController.offset;
      expect(retainedOffset, greaterThan(0));
      expect(
        retainedOffset,
        lessThan(scrollController.position.maxScrollExtent),
      );

      for (final tab in ['待我審查', '我建立的', '指派給我', '待辦']) {
        await tester.tap(find.text(tab));
        await settleNetworkWidgets(tester);
      }

      final retainedTodoFeed = _feed(tester, 'todos');
      expect(identical(retainedTodoFeed, todoFeed), isTrue);
      expect(retainedTodoFeed.controller.items, hasLength(31));
      expect(retainedTodoFeed.controller.next?.queryParameters['page'], '3');
      expect(scrollController.offset, retainedOffset);
      // The retained offset sits 300 px above the end, so the page-two row is
      // checked once the list is scrolled back to it.
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
      expect(find.text('Todo page two'), findsOneWidget);
      expect(firstPageGets, {
        'todos': 1,
        'assigned': 1,
        'review': 1,
        'created': 1,
      });
      expect(todoPageTwoGets, 1);

      // A Dio-backed request cannot be awaited directly in the fake-async
      // test zone; drive it through the bounded network pump instead.
      final refreshing = retainedTodoFeed.refresh();
      var refreshed = false;
      unawaited(refreshing.whenComplete(() {
        refreshed = true;
      }));
      try {
        await pumpUntil(
          tester,
          () => refreshed,
          description: 'explicit todo refresh completes',
        );
        await settleNetworkWidgets(tester);
      } finally {
        if (!refreshed) {
          await tester.runAsync(
            () => refreshing.timeout(
              const Duration(seconds: 5),
              onTimeout: () {},
            ),
          );
        }
      }
      expect(firstPageGets['todos'], 2);
      expect(retainedTodoFeed.controller.items, hasLength(30));
      expect(find.text('Todo page two'), findsNothing);
    },
  );

  testWidgets(
    'reused InboxPage state drops old rows and requests a fresh owner',
    (tester) async {
      final firstAdapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/todos')) {
          return jsonResponse([_todo(1, 'First owner todo')]);
        }
        return jsonResponse([]);
      });
      final secondAdapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/todos')) {
          return jsonResponse([_todo(2, 'Second owner todo')]);
        }
        return jsonResponse([]);
      });
      final firstApi = testApi(firstAdapter);
      final secondApi = testApi(secondAdapter);
      addTearDown(firstApi.close);
      addTearDown(secondApi.close);

      await tester.pumpWidget(
        MaterialApp(home: InboxPage(account: firstAccount, api: firstApi)),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('First owner todo'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(home: InboxPage(account: secondAccount, api: secondApi)),
      );
      await tester.pump();
      expect(
        find.text('First owner todo'),
        findsNothing,
        reason: 'an owner change must synchronously remove the old response',
      );
      await settleNetworkWidgets(tester);

      expect(find.text('Second owner todo'), findsOneWidget);
      expect(
        secondAdapter.requests.where(
          (request) =>
              request.method == 'GET' && request.uri.path.endsWith('/todos'),
        ),
        hasLength(1),
      );
      await tester.tap(find.text('待我審查'));
      await settleNetworkWidgets(tester);
      final review = secondAdapter.requests.singleWhere(
        (request) =>
            request.method == 'GET' &&
            request.uri.path.endsWith('/merge_requests') &&
            request.uri.queryParameters['reviewer_id'] != null,
      );
      expect(review.uri.queryParameters['reviewer_id'], '8');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'session generation key destroys retained panels and starts with no old content',
    (tester) async {
      var todoGets = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/todos')) {
          todoGets++;
          return jsonResponse([
            _todo(
              todoGets,
              todoGets == 1 ? 'Previous generation' : 'Current generation',
            ),
          ]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      var generation = 1;
      late StateSetter rebuild;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return KeyedSubtree(
                key: ValueKey(generation),
                child: InboxPage(account: firstAccount, api: api),
              );
            },
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('Previous generation'), findsOneWidget);

      generation++;
      rebuild(() {});
      await tester.pump();
      expect(find.text('Previous generation'), findsNothing);
      await settleNetworkWidgets(tester);

      expect(find.text('Current generation'), findsOneWidget);
      expect(todoGets, 2);
    },
  );

  testWidgets(
    'tab taps and root rebuilds skip offstage panels while pending changes still refilter',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var todoGets = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/todos') && request.method == 'GET') {
          todoGets++;
          return jsonResponse([
            for (var id = 1; id <= 30; id++) _todo(id, 'Todo $id'),
          ]);
        }
        if (path.endsWith('/issues')) {
          return jsonResponse([_workItem(201, 'Assigned issue')]);
        }
        if (path.endsWith('/merge_requests') &&
            request.uri.queryParameters['reviewer_id'] != null) {
          return jsonResponse([_workItem(301, 'Review request')]);
        }
        if (path.endsWith('/merge_requests')) {
          return jsonResponse([_workItem(401, 'Created merge request')]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      var inboxSelected = true;
      late StateSetter rebuildRoot;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuildRoot = setState;
              // Mirrors a root destination switch: a fresh InboxPage widget
              // for the same account and client under a toggled TickerMode.
              return TickerMode(
                enabled: inboxSelected,
                child: InboxPage(account: firstAccount, api: api),
              );
            },
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      for (final tab in ['指派給我', '待我審查', '我建立的', '待辦']) {
        await tester.tap(find.text(tab));
        await settleNetworkWidgets(tester);
      }
      final requestsBefore = adapter.requests.length;

      final todoFeed = _feed(tester, 'todos');
      expect(todoFeed.controller.items, hasLength(30));
      final probes = <_IdProbeMap>[
        for (final item in todoFeed.controller.items.skip(20).toList())
          _IdProbeMap(item),
      ];
      for (final probe in probes) {
        todoFeed.patchItem(probe);
      }
      await tester.pump();
      void resetProbes() {
        for (final probe in probes) {
          probe.idReads = 0;
        }
      }

      bool tickerEnabled(String identity) => TickerMode.getValuesNotifier(
        tester.element(
          find.byWidget(_feed(tester, identity).widget, skipOffstage: false),
        ),
      ).value.enabled;

      final rebuilds = <String, int>{};
      debugOnRebuildDirtyWidget = (element, _) {
        final widget = element.widget;
        if (widget is RecordsFeed) {
          rebuilds[widget.identity] = (rebuilds[widget.identity] ?? 0) + 1;
        }
      };
      try {
        resetProbes();
        // Todo (0) to created (3) and on to assigned (1) are non-adjacent
        // jumps; the panels not involved in a jump must not rebuild, and the
        // offstage Todo rows must not be refiltered.
        await tester.tap(find.text('我建立的'));
        await settleNetworkWidgets(tester);
        expect(rebuilds['assigned_to_me/issues'] ?? 0, 0);
        expect(rebuilds['review-requests'] ?? 0, 0);
        expect(tickerEnabled('todos'), isFalse);
        expect(tickerEnabled('created_by_me/merge_requests'), isTrue);

        rebuilds.clear();
        await tester.tap(find.text('指派給我'));
        await settleNetworkWidgets(tester);
        expect(rebuilds['todos'] ?? 0, 0);
        expect(rebuilds['review-requests'] ?? 0, 0);
        expect(tickerEnabled('assigned_to_me/issues'), isTrue);
        expect(tickerEnabled('created_by_me/merge_requests'), isFalse);
        expect(probes.map((probe) => probe.idReads), everyElement(0));

        await tester.tap(find.text('待辦'));
        await settleNetworkWidgets(tester);
        expect(tickerEnabled('todos'), isTrue);

        rebuilds.clear();
        resetProbes();
        rebuildRoot(() => inboxSelected = false);
        await tester.pump();
        expect(tickerEnabled('todos'), isFalse);
        rebuildRoot(() => inboxSelected = true);
        await tester.pump();
        rebuildRoot(() {});
        await tester.pump();
        expect(tickerEnabled('todos'), isTrue);
        expect(
          rebuilds,
          isEmpty,
          reason: 'A root rebuild with the same owner must not rebuild any '
              'retained panel.',
        );
        expect(probes.map((probe) => probe.idReads), everyElement(0));

        // A real pending change still hides the row and refilters, and stays
        // in force across later root rebuilds until it is undone.
        await tester.drag(
          find.byKey(const ValueKey('todo-1')),
          const Offset(500, 0),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byKey(const ValueKey('todo-1')), findsNothing);
        expect(find.text('復原'), findsOneWidget);
        expect(probes.map((probe) => probe.idReads), everyElement(greaterThan(0)));

        resetProbes();
        rebuildRoot(() {});
        await tester.pump();
        expect(find.byKey(const ValueKey('todo-1')), findsNothing);
        expect(probes.map((probe) => probe.idReads), everyElement(0));

        tester
            .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
            .hideCurrentSnackBar(reason: SnackBarClosedReason.action);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byKey(const ValueKey('todo-1')), findsOneWidget);
        expect(probes.map((probe) => probe.idReads), everyElement(greaterThan(0)));

        resetProbes();
        rebuildRoot(() {});
        await tester.pump();
        expect(find.byKey(const ValueKey('todo-1')), findsOneWidget);
        expect(probes.map((probe) => probe.idReads), everyElement(0));
      } finally {
        debugOnRebuildDirtyWidget = null;
      }

      expect(identical(_feed(tester, 'todos'), todoFeed), isTrue);
      expect(todoGets, 1);
      expect(
        adapter.requests.skip(requestsBefore),
        isEmpty,
        reason: 'Tab taps and root rebuilds reuse the loaded panels, and '
            'undo sends no completion write.',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

final class _IdProbeMap extends MapBase<String, dynamic> {
  _IdProbeMap(Map<String, dynamic> source) : _delegate = Map.of(source);
  final Map<String, dynamic> _delegate;
  int idReads = 0;

  @override
  dynamic operator [](Object? key) {
    if (key == 'id') idReads++;
    return _delegate[key];
  }

  @override
  void operator []=(String key, dynamic value) => _delegate[key] = value;

  @override
  void clear() => _delegate.clear();

  @override
  Iterable<String> get keys => _delegate.keys;

  @override
  dynamic remove(Object? key) => _delegate.remove(key);
}

RecordsFeedState _feed(WidgetTester tester, String identity) =>
    tester
        .stateList<RecordsFeedState>(
          find.byType(RecordsFeed, skipOffstage: false),
        )
        .singleWhere((state) => state.widget.identity == identity);

Finder _scrollView(WidgetTester tester, RecordsFeedState feed) =>
    find.descendant(
      of: find.byWidget(feed.widget, skipOffstage: false),
      matching: find.byType(CustomScrollView, skipOffstage: false),
      skipOffstage: false,
    );

Json _todo(int id, String title) => {
  'id': id,
  'target_type': 'Issue',
  'target': {'id': 1000 + id, 'iid': id, 'title': title},
  'project': {'id': 10, 'path_with_namespace': 'team/core'},
  'state': 'pending',
};

Json _workItem(int id, String title) => {
  'id': id,
  'iid': id,
  'project_id': 10,
  'title': title,
  'updated_at': '2026-10-04T00:00:00Z',
};
