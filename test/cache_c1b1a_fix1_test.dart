import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/record_controller.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

final _fetched = DateTime.utc(2026, 10, 23);
final _next = Uri.parse(
  'https://example.com/gitlab/api/v4/issues?per_page=30&page=2',
);

CachedRead<ApiPage<Json>> _read(
  int id, {
  bool stale = false,
  bool superseded = false,
  Uri? next,
}) => CachedRead(
  value: ApiPage<Json>([
    {'id': id},
  ], next: next),
  fetchedAt: _fetched,
  lineage: CacheLineage.memory,
  stale: stale,
  superseded: superseded,
);

GitLabApi _api(FakeAdapter adapter, {DateTime Function()? clock}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheClock: clock,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

RecordController _controller(GitLabApi api) => RecordController(
  (next) => api.records(['issues'], next: next),
  cached: ({required fresh, required background}) =>
      api.cachedRecords(['issues'], fresh: fresh, background: background),
);

int _gets(FakeAdapter adapter, {String path = '/issues', int page = 1}) =>
    adapter.requests
        .where(
          (request) =>
              request.method == 'GET' &&
              request.uri.path.endsWith(path) &&
              (request.uri.queryParameters['page'] ?? '1') == '$page',
        )
        .length;

ResponseBody _page(int id, {int? next}) => jsonResponse(
  [
    {'id': id},
  ],
  headers: {
    if (next != null) 'x-next-page': ['$next'],
  },
);

Widget _host(
  GitLabApi api,
  GlobalKey<RecordsFeedState> key,
  bool visible, {
  bool useCache = true,
}) => MaterialApp(
  home: Scaffold(
    body: TickerMode(
      enabled: visible,
      child: RecordsFeed(
        key: key,
        identity: 'issues',
        load: (next) => api.records(['issues'], next: next),
        cached: useCache
            ? ({required fresh, required background}) => api.cachedRecords(
                ['issues'],
                fresh: fresh,
                background: background,
              )
            : null,
        itemBuilder: (_, item) => Text('Row ${item['id']}'),
      ),
    ),
  ),
);

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  for (final status in [401, 403, 404, 429, 503]) {
    testWidgets('Codex I-1: load more $status applies the withdrawal matrix', (
      tester,
    ) async {
      final adapter = FakeAdapter(
        (request) => request.uri.queryParameters['page'] == '2'
            ? jsonResponse({}, status: status)
            : _page(1, next: 2),
      );
      final api = _api(adapter);
      addTearDown(api.close);
      await tester.runAsync(() => api.cachedRecords(['issues']));
      final key = GlobalKey<RecordsFeedState>();
      await tester.pumpWidget(_host(api, key, true));
      await settleNetworkWidgets(tester);
      final controller = key.currentState!.controller;
      await tester.runAsync(controller.more);
      await tester.pump();
      final revoked = [401, 403, 404].contains(status);
      expect(controller.items, revoked ? isEmpty : hasLength(1));
      expect(controller.next, revoked ? isNull : _next);
      expect(controller.fetchedAt, revoked ? isNull : isNotNull);
      expect(controller.error?.status, status);
      expect(find.byType(FailureNotice), findsOneWidget);
      expect(_gets(adapter), 1);
      expect(_gets(adapter, page: 2), 1);
      if (status == 404) {
        expect(controller.error!.kind, FailureKind.invisible);
        expect(controller.error!.detail, contains('或'));
      }
      if (revoked) {
        await tester.runAsync(controller.retry);
        expect(_gets(adapter), 2, reason: 'retry must restart at page one');
        expect(_gets(adapter, page: 2), 1);
        expect(controller.items.single['id'], 1);
      }
    });
  }

  test('Codex I-1: network failure keeps the cached window', () async {
    final controller = RecordController(
      (_) async => throw const ApiFailure(FailureKind.network),
      cached: ({required fresh, required background}) async =>
          _read(1, next: _next),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    await controller.more();
    expect(controller.items.single['id'], 1);
    expect(controller.next, _next);
    expect(controller.fetchedAt, _fetched);
    expect(controller.failedMore, isTrue);
  });

  test(
    'Codex I-2: two supersedes recover only after the write goes quiet',
    () async {
      final responses = List.generate(4, (_) => Completer<ResponseBody>());
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (request.method != 'GET') return jsonResponse({'id': 1});
        final read = reads++;
        return read < responses.length ? responses[read].future : _page(9);
      });
      final api = _api(adapter);
      addTearDown(api.close);
      final controller = _controller(api);
      addTearDown(controller.dispose);
      final stopwatch = Stopwatch();
      final refresh = controller.refresh();
      for (var i = 0; i < 4; i++) {
        await _until(() => _gets(adapter) == i + 1);
        await api.updateIssue(8, 1, {'title': 'synthetic write $i'});
        if (i == 3) stopwatch.start();
        responses[i].complete(_page(666));
      }
      await refresh;
      expect(controller.items.map((item) => item['id']), [9]);
      expect(controller.error, isNull);
      expect(_gets(adapter), 5);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 900)),
      );
    },
  );

  for (final end in ['reset', 'dispose', 'hidden']) {
    test('Codex I-2: explicit quiet recovery respects $end', () async {
      final pending = Completer<CachedRead<ApiPage<Json>>>();
      var calls = 0;
      final controller = RecordController(
        (_) async => const ApiPage<Json>([]),
        cached: ({required fresh, required background}) {
          calls++;
          if (calls <= 2) return Future.value(_read(666, superseded: true));
          if (calls == 3) return pending.future;
          return Future.value(_read(9));
        },
      );
      if (end != 'dispose') addTearDown(controller.dispose);
      final refresh = controller.refresh();
      await _until(() => calls == 3 || !controller.loading);
      expect(calls, 3);
      switch (end) {
        case 'reset':
          await controller.refresh(reset: true);
        case 'dispose':
          controller.dispose();
        case 'hidden':
          controller.setBackgroundEnabled(false);
      }
      pending.complete(_read(666));
      await refresh;
      expect(controller.items.map((item) => item['id']), switch (end) {
        'reset' => [9],
        'hidden' => [666],
        _ => isEmpty,
      });
      if (end == 'hidden') {
        controller.setBackgroundEnabled(true);
        expect(controller.revalidating, isFalse);
        expect(calls, 3, reason: 'an explicit read completes while hidden');
      }
    });
  }

  test(
    'Codex I-2: sustained supersedes leave an explicit retryable failure',
    () async {
      var calls = 0;
      final controller = RecordController(
        (_) async => const ApiPage<Json>([]),
        cached: ({required fresh, required background}) async {
          calls++;
          return _read(666, superseded: true);
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.error, isNotNull);
      expect(controller.items, isEmpty);
      expect(controller.loading, isFalse);
      expect(calls, 3);
    },
  );

  testWidgets(
    'Codex I-3: queued background HTTP waits for visibility after admission',
    (tester) async {
      var now = _fetched;
      var reads = 0;
      final occupied = Completer<void>();
      final adapter = FakeAdapter((request) async {
        if (request.uri.path.endsWith('/issues')) {
          return _page(reads++ == 0 ? 1 : 9);
        }
        await occupied.future;
        return jsonResponse({'id': 1});
      });
      final api = _api(adapter, clock: () => now);
      addTearDown(api.close);
      await tester.runAsync(() => api.cachedRecords(['issues']));
      now = now.add(const Duration(seconds: 61));
      final blockers = [
        for (var id = 1; id <= 4; id++)
          api.cachedRecord(
            ['projects', '8', 'issues', '$id'],
            fresh: true,
            background: true,
          ),
      ];
      final key = GlobalKey<RecordsFeedState>();
      await tester.pumpWidget(_host(api, key, true));
      await settleNetworkWidgets(tester);
      expect(adapter.requests, hasLength(5));
      expect(key.currentState!.controller.revalidating, isTrue);
      await tester.pumpWidget(_host(api, key, false));
      occupied.complete();
      await settleNetworkWidgets(tester);
      await Future.wait(blockers);
      expect(
        _gets(adapter),
        1,
        reason: 'a hidden queued feed must not send HTTP',
      );
      expect(key.currentState!.controller.items.single['id'], 1);
      await tester.pumpWidget(_host(api, key, true));
      await settleNetworkWidgets(tester);
      expect(_gets(adapter), 2);
      expect(key.currentState!.controller.items.single['id'], 9);
      for (var id = 1; id <= 4; id++) {
        expect(_gets(adapter, path: '/projects/8/issues/$id'), 1);
      }
    },
  );

  for (final operation in ['background', 'refresh', 'reconcile']) {
    for (final hideAt in [1, 2, 3]) {
      testWidgets(
        'Codex I-3: hiding during $operation page $hideAt fences background work only',
        (tester) async {
          var now = _fetched, rebuilding = false, held = false;
          final pending = Completer<ResponseBody>();
          final adapter = FakeAdapter((request) {
            final page = int.parse(request.uri.queryParameters['page'] ?? '1');
            if (rebuilding && page == hideAt && !held) {
              held = true;
              return pending.future;
            }
            return _page(
              (rebuilding ? 10 : 0) + page,
              next: page < 3 ? page + 1 : null,
            );
          });
          final api = _api(adapter, clock: () => now);
          addTearDown(api.close);
          final key = GlobalKey<RecordsFeedState>();
          await tester.pumpWidget(_host(api, key, true));
          await settleNetworkWidgets(tester);
          final controller = key.currentState!.controller;
          await tester.runAsync(controller.more);
          await tester.runAsync(controller.more);
          final oldTime = controller.fetchedAt;
          rebuilding = true;
          now = now.add(const Duration(seconds: 61));
          final background = operation == 'background';
          if (operation == 'refresh') api.clearReadCache();
          final refresh = operation == 'reconcile'
              ? controller.reconcileLoadedWindow()
              : controller.refresh();
          if (background) await refresh;
          await pumpUntil(tester, () => held);
          final requestsBeforeHide = [
            for (var page = 1; page <= 3; page++) _gets(adapter, page: page),
          ];
          await tester.pumpWidget(_host(api, key, false));
          pending.complete(
            _page(10 + hideAt, next: hideAt < 3 ? hideAt + 1 : null),
          );
          await settleNetworkWidgets(tester);
          if (!background) await refresh;
          expect(
            controller.items.map((item) => item['id']),
            background ? [1, 2, 3] : [11, 12, 13],
          );
          expect(controller.fetchedAt, background ? oldTime : now);
          expect(
            [for (var page = 1; page <= 3; page++) _gets(adapter, page: page)],
            background ? requestsBeforeHide : [2, 2, 2],
            reason: 'only background continuation HTTP waits for visibility',
          );
          expect(controller.next, isNull);
          await tester.pumpWidget(_host(api, key, true));
          await settleNetworkWidgets(tester);
          expect(controller.items.map((item) => item['id']), [11, 12, 13]);
          expect(_gets(adapter), background ? 3 : 2);
          expect(_gets(adapter, page: 2), background && hideAt > 1 ? 3 : 2);
          expect(_gets(adapter, page: 3), background && hideAt == 3 ? 3 : 2);
        },
      );
    }
  }

  testWidgets('N-1: an uncached hidden feed sends its initial HTTP', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => _page(1));
    final api = _api(adapter);
    addTearDown(api.close);
    final key = GlobalKey<RecordsFeedState>();
    await tester.pumpWidget(_host(api, key, false, useCache: false));
    await settleNetworkWidgets(tester);
    expect(_gets(adapter), 1);
    expect(key.currentState!.controller.items.single['id'], 1);
    await tester.pumpWidget(_host(api, key, true, useCache: false));
    await settleNetworkWidgets(tester);
    expect(_gets(adapter), 1);
    expect(key.currentState!.controller.items.single['id'], 1);
  });

  testWidgets(
    'N-1: uncached hidden reconciliation completes the whole window',
    (tester) async {
      var rebuilding = false;
      final adapter = FakeAdapter((request) {
        final page = int.parse(request.uri.queryParameters['page'] ?? '1');
        return _page((rebuilding ? 10 : 0) + page, next: page == 1 ? 2 : null);
      });
      final api = _api(adapter);
      addTearDown(api.close);
      final key = GlobalKey<RecordsFeedState>();
      await tester.pumpWidget(_host(api, key, true, useCache: false));
      await settleNetworkWidgets(tester);
      final controller = key.currentState!.controller;
      await tester.runAsync(controller.more);
      rebuilding = true;
      await tester.pumpWidget(_host(api, key, false, useCache: false));
      await tester.runAsync(controller.reconcileLoadedWindow);
      expect(_gets(adapter), 2);
      expect(_gets(adapter, page: 2), 2);
      expect(controller.items.map((item) => item['id']), [11, 12]);
      await tester.pumpWidget(_host(api, key, true, useCache: false));
      await settleNetworkWidgets(tester);
      expect(_gets(adapter), 2);
      expect(_gets(adapter, page: 2), 2);
      expect(controller.items.map((item) => item['id']), [11, 12]);
    },
  );

  for (final outcome in ['success', 'network', '429']) {
    for (final completeHidden in [false, true]) {
      testWidgets(
        'N-1: a cold cached feed created hidden reports $outcome when completed ${completeHidden ? 'hidden' : 'visible'}',
        (tester) async {
          final pending = Completer<ResponseBody>();
          final adapter = FakeAdapter((_) => pending.future);
          final api = _api(adapter);
          addTearDown(api.close);
          final key = GlobalKey<RecordsFeedState>();
          await tester.pumpWidget(_host(api, key, false));
          expect(find.byType(RowsSkeleton), findsOneWidget);
          expect(find.byType(EmptyState), findsNothing);
          await settleNetworkWidgets(tester);
          final controller = key.currentState!.controller;
          expect(
            _gets(adapter),
            1,
            reason: 'the explicit read sends while hidden',
          );
          expect(controller.loading, isTrue);
          expect(find.byType(RowsSkeleton), findsOneWidget);
          expect(find.byType(EmptyState), findsNothing);

          if (!completeHidden) {
            await tester.pumpWidget(_host(api, key, true));
            await settleNetworkWidgets(tester);
            expect(_gets(adapter), 1);
            expect(controller.loading, isTrue);
            expect(find.byType(RowsSkeleton), findsOneWidget);
            expect(find.byType(EmptyState), findsNothing);
          }

          switch (outcome) {
            case 'success':
              pending.complete(_page(9));
            case 'network':
              pending.completeError(
                DioException(
                  requestOptions: adapter.requests.single,
                  type: DioExceptionType.connectionError,
                ),
              );
            case '429':
              pending.complete(
                jsonResponse(
                  {},
                  status: 429,
                  headers: {
                    'retry-after': ['60'],
                  },
                ),
              );
          }
          await settleNetworkWidgets(tester);
          expect(controller.loading, isFalse);
          expect(find.byType(RowsSkeleton), findsNothing);
          expect(find.byType(EmptyState), findsNothing);
          if (completeHidden) {
            await tester.pumpWidget(_host(api, key, true));
            await settleNetworkWidgets(tester);
          }
          expect(
            _gets(adapter),
            1,
            reason: 'showing the feed needs no new read',
          );
          expect(controller.revalidating, isFalse);
          expect(controller.backgroundFailure, isNull);
          expect(find.byType(EmptyState), findsNothing);
          if (outcome == 'success') {
            expect(controller.items.single['id'], 9);
            expect(controller.error, isNull);
            expect(find.text('Row 9'), findsOneWidget);
            expect(find.byType(FailureNotice), findsNothing);
          } else {
            expect(controller.items, isEmpty);
            expect(
              controller.error?.kind,
              outcome == 'network'
                  ? FailureKind.network
                  : FailureKind.rateLimited,
            );
            expect(find.byType(FailureNotice), findsOneWidget);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          api.close();
        },
      );
    }
  }

  testWidgets('Codex I-3: a stale hidden feed revalidates only when visible', (
    tester,
  ) async {
    var now = _fetched;
    var reads = 0;
    final adapter = FakeAdapter((_) => _page(reads++ == 0 ? 1 : 9));
    final api = _api(adapter, clock: () => now);
    addTearDown(api.close);
    await tester.runAsync(() => api.cachedRecords(['issues']));
    now = now.add(const Duration(seconds: 61));
    final key = GlobalKey<RecordsFeedState>();
    await tester.pumpWidget(_host(api, key, false));
    await settleNetworkWidgets(tester);
    final controller = key.currentState!.controller;
    expect(_gets(adapter), 1);
    expect(controller.items.single['id'], 1);
    expect(controller.stale, isTrue);
    expect(controller.revalidating, isFalse);
    await tester.pumpWidget(_host(api, key, true));
    await settleNetworkWidgets(tester);
    expect(_gets(adapter), 2);
    expect(controller.items.single['id'], 9);
    expect(controller.stale, isFalse);
    expect(controller.revalidating, isFalse);
  });

  test('Codex I-2: background quiet recovery waits for visibility', () async {
    final pending = Completer<CachedRead<ApiPage<Json>>>();
    var calls = 0;
    final controller = RecordController(
      (_) async => const ApiPage<Json>([]),
      cached: ({required fresh, required background}) {
        if (!fresh) return Future.value(_read(1, stale: true));
        calls++;
        if (calls <= 2) return Future.value(_read(666, superseded: true));
        if (calls == 3) return pending.future;
        return Future.value(_read(9));
      },
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    await _until(() => calls == 3);
    controller.setBackgroundEnabled(false);
    pending.complete(_read(666));
    await _until(() => !controller.revalidating);
    expect(controller.items.single['id'], 1);
    expect(calls, 3);
    controller.setBackgroundEnabled(true);
    await _until(() => !controller.revalidating);
    expect(controller.items.single['id'], 9);
    expect(calls, 4);
  });

  for (final inFlight in [false, true]) {
    for (final failed in [false, true]) {
      test(
        'Opus I-1: load more retries stale page one after ${inFlight ? 'pending' : 'settled'} ${failed ? 'network failure' : 'dropped revalidation'}',
        () async {
          final first = Completer<CachedRead<ApiPage<Json>>>();
          final pending = Completer<CachedRead<ApiPage<Json>>>();
          final newNext = _next.replace(
            queryParameters: {'per_page': '30', 'page': '3'},
          );
          final calls = <(bool, bool)>[];
          final cursors = <Uri?>[];
          final controller = RecordController(
            (next) async {
              cursors.add(next);
              return const ApiPage<Json>([
                {'id': 3},
              ]);
            },
            cached: ({required fresh, required background}) {
              calls.add((fresh, background));
              if (background) {
                if (inFlight) return pending.future;
                return failed
                    ? Future.error(const ApiFailure(FailureKind.network))
                    : Future.value(const CachedRead.dropped());
              }
              return fresh
                  ? first.future
                  : Future.value(_read(1, stale: true, next: _next));
            },
          );
          addTearDown(controller.dispose);
          await controller.refresh();
          if (!inFlight) await _until(() => !controller.revalidating);
          final more = controller.more();
          if (inFlight) {
            if (failed) {
              pending.completeError(const ApiFailure(FailureKind.network));
            } else {
              pending.complete(const CachedRead.dropped());
            }
          }
          await Future<void>.delayed(Duration.zero);
          expect(calls, [(false, false), (true, true), (true, false)]);
          expect(controller.loadingMore, isTrue);
          expect(cursors, isEmpty);
          first.complete(_read(2, next: newNext));
          await more;
          expect(controller.items.map((item) => item['id']), [2, 3]);
          expect(cursors, [newNext]);
          expect(controller.error, isNull);
          expect(controller.backgroundFailure, isNull);
        },
      );
    }
  }
}
