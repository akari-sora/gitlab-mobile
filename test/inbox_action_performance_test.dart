import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
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
  final account = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'tester', name: 'Tester'),
    token: 'synthetic-test-token',
  );

  testWidgets(
    'pending todo write rebuilds only action buttons and guards duplicates',
    (tester) async {
      final fixture = _PagedTodoFixture();
      addTearDown(fixture.api.close);
      await _pumpLoadedInbox(tester, account, fixture);

      final feed = tester.state<RecordsFeedState>(
        find.byType(RecordsFeed).first,
      );
      await tester.runAsync(feed.controller.more);
      await tester.pump();
      expect(feed.controller.items, hasLength(60));

      final probes = _installOffscreenProbes(feed);
      await tester.pump();
      for (final probe in probes) {
        probe.idReads = 0;
      }

      final target = _doneButton(1);
      final other = _doneButton(2);
      expect(tester.widget<IconButton>(target).onPressed, isNotNull);
      expect(tester.widget<IconButton>(other).onPressed, isNotNull);

      tester.widget<IconButton>(target).onPressed!();
      await tester.pump();
      await pumpUntil(
        tester,
        () => fixture.singleDoneCalls == 1,
        maxCycles: 20,
        description: 'single todo write starts',
      );

      expect(
        fixture.singleDoneCalls,
        1,
        reason: fixture.adapter.requests
            .map((request) => '${request.method} ${request.uri}')
            .join('\n'),
      );
      expect(tester.widget<IconButton>(target).onPressed, isNull);
      expect(tester.widget<IconButton>(other).onPressed, isNotNull);
      expect(
        probes.map((probe) => probe.idReads),
        everyElement(0),
        reason:
            'A transient write state must not refilter or recount offscreen rows.',
      );

      tester.widget<IconButton>(target).onPressed?.call();
      await tester.pump();
      expect(
        fixture.singleDoneCalls,
        1,
        reason: 'A disabled target cannot enqueue a duplicate write.',
      );

      fixture.singleDone.complete(jsonResponse({'id': 1, 'state': 'done'}));
      await pumpUntil(
        tester,
        () => fixture.refreshStarted,
        maxCycles: 20,
        description: 'post-write todo refresh starts',
      );
      expect(fixture.refreshStarted, isTrue);
      expect(
        probes.map((probe) => probe.idReads),
        everyElement(5),
        reason:
            'Completion may remove and rederive rows once; clearing a non-pending id must be a no-op.',
      );

      fixture.refresh.complete(
        jsonResponse(
          fixture.page(1),
          headers: {
            'x-next-page': ['2'],
          },
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('todo-1')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clear-all pending state is local and late completion is disposal-safe',
    (tester) async {
      final fixture = _PagedTodoFixture();
      addTearDown(fixture.api.close);
      await _pumpLoadedInbox(tester, account, fixture);

      final feed = tester.state<RecordsFeedState>(
        find.byType(RecordsFeed).first,
      );
      await tester.runAsync(feed.controller.more);
      await tester.pump();
      final probes = _installOffscreenProbes(feed);
      await tester.pump();
      for (final probe in probes) {
        probe.idReads = 0;
      }

      tester
          .widget<TextButton>(find.byKey(const ValueKey('todos-mark-all-done')))
          .onPressed!();
      await tester.pumpAndSettle();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '確認'))
          .onPressed!();
      await tester.pump();
      await pumpUntil(
        tester,
        () => fixture.clearCalls == 1,
        maxCycles: 20,
        description: 'clear-all write starts',
      );

      final clearButton = tester.widget<TextButton>(
        find.byKey(const ValueKey('todos-mark-all-done')),
      );
      expect(
        fixture.clearCalls,
        1,
        reason: fixture.adapter.requests
            .map((request) => '${request.method} ${request.uri}')
            .join('\n'),
      );
      expect(clearButton.onPressed, isNull);
      expect(tester.widget<IconButton>(_doneButton(1)).onPressed, isNotNull);
      expect(probes.map((probe) => probe.idReads), everyElement(0));

      tester
          .widget<TextButton>(find.byKey(const ValueKey('todos-mark-all-done')))
          .onPressed
          ?.call();
      await tester.pump();
      expect(fixture.clearCalls, 1);

      await tester.pumpWidget(const SizedBox());
      fixture.clearDone.complete(jsonResponse(<String, dynamic>{}));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('swipe and undo still invalidate todo visibility', (
    tester,
  ) async {
    final fixture = _PagedTodoFixture();
    addTearDown(fixture.api.close);
    await _pumpLoadedInbox(tester, account, fixture);

    expect(find.byKey(const ValueKey('todo-1')), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('todo-1')),
      const Offset(500, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('todo-1')), findsNothing);
    expect(find.text('復原'), findsOneWidget);

    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .hideCurrentSnackBar(reason: SnackBarClosedReason.action);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('todo-1')), findsOneWidget);
    expect(fixture.singleDoneCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpLoadedInbox(
  WidgetTester tester,
  Account account,
  _PagedTodoFixture fixture,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: InboxPage(account: account, api: fixture.api),
    ),
  );
  await settleNetworkWidgets(tester);
}

Finder _doneButton(int id) => find.descendant(
  of: find.byKey(ValueKey('todo-$id')),
  matching: find.widgetWithIcon(IconButton, Icons.check_circle_outline),
);

List<_IdProbeMap> _installOffscreenProbes(RecordsFeedState feed) {
  final probes = <_IdProbeMap>[];
  for (final item in feed.controller.items.skip(20).toList(growable: false)) {
    final probe = _IdProbeMap(item);
    probes.add(probe);
    feed.patchItem(probe);
  }
  return probes;
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

final class _PagedTodoFixture {
  _PagedTodoFixture() {
    adapter = FakeAdapter(_respond);
    api = testApi(adapter);
  }

  late final FakeAdapter adapter;
  late final GitLabApi api;
  final singleDone = Completer<ResponseBody>();
  final clearDone = Completer<ResponseBody>();
  final refresh = Completer<ResponseBody>();
  var singleDoneCalls = 0;
  var clearCalls = 0;
  var todoGets = 0;
  var refreshStarted = false;
  final removed = <int>{};

  List<Map<String, dynamic>> page(int number) => [
    for (var id = (number - 1) * 30 + 1; id <= number * 30; id++)
      if (!removed.contains(id))
        {
          'id': id,
          'target_type': 'Issue',
          'target': {'id': 1000 + id, 'iid': id, 'title': 'Todo $id'},
          'project': {'id': 10, 'path_with_namespace': 'team/core'},
          'state': 'pending',
          'created_at': '2026-10-03T00:00:00Z',
        },
  ];

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final path = request.uri.path;
    if (path.endsWith('/todos') && request.method == 'GET') {
      todoGets++;
      final number =
          int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 1;
      if (todoGets > 2 && number == 1) {
        refreshStarted = true;
        return refresh.future;
      }
      return jsonResponse(
        page(number),
        headers: number == 1
            ? {
                'x-next-page': ['2'],
              }
            : const {},
      );
    }
    if (path.endsWith('/todos/1/mark_as_done') && request.method == 'POST') {
      singleDoneCalls++;
      return singleDone.future.then((response) {
        removed.add(1);
        return response;
      });
    }
    if (path.endsWith('/todos/mark_as_done') && request.method == 'POST') {
      clearCalls++;
      return clearDone.future;
    }
    return jsonResponse(<dynamic>[]);
  }
}
