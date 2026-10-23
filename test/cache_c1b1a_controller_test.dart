import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/record_controller.dart';

final fetched = DateTime.utc(2026, 10, 23);
final oldNext = Uri.parse(
  'https://example.com/api/v4/events?page=2&cursor=old',
);
final newNext = Uri.parse(
  'https://example.com/api/v4/events?page=2&cursor=new',
);

CachedRead<ApiPage<Json>> read(
  int id, {
  bool stale = false,
  bool superseded = false,
  Uri? next,
}) => CachedRead(
  value: ApiPage<Json>([
    {'id': id},
  ], next: next),
  fetchedAt: fetched,
  lineage: stale ? CacheLineage.memory : CacheLineage.network,
  stale: stale,
  superseded: superseded,
);

void main() {
  test(
    'SWR publishes cached rows and timestamp before revalidating then replaces through epoch',
    () async {
      final pending = Completer<CachedRead<ApiPage<Json>>>();
      final calls = <(bool, bool)>[];
      final states = <(int?, bool, bool)>[];
      final controller = RecordController(
        (_) async => throw StateError('first page must use cache'),
        cached: ({required fresh, required background}) {
          calls.add((fresh, background));
          return background
              ? pending.future
              : Future.value(read(1, stale: true));
        },
      );
      addTearDown(controller.dispose);
      controller.addListener(
        () => states.add((
          controller.items.firstOrNull?['id'] as int?,
          controller.stale,
          controller.revalidating,
        )),
      );
      await controller.refresh();
      expect(controller.fetchedAt, fetched);
      expect(controller.loading, isFalse);
      expect(states, containsAllInOrder([(1, true, false), (1, true, true)]));
      expect(calls, [(false, false), (true, true)]);
      pending.complete(read(2));
      await controller.more();
      expect(controller.items.single['id'], 2);
      expect(controller.stale, isFalse);
      expect(controller.revalidating, isFalse);
      expect(controller.backgroundFailure, isNull);
    },
  );

  test(
    'more waits for stale first page and uses only the refreshed continuation',
    () async {
      final pending = Completer<CachedRead<ApiPage<Json>>>();
      final pages = <Uri?>[];
      final controller = RecordController(
        (cursor) async {
          pages.add(cursor);
          return const ApiPage<Json>([
            {'id': 3},
          ]);
        },
        cached: ({required fresh, required background}) => background
            ? pending.future
            : Future.value(read(1, stale: true, next: oldNext)),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final more = controller.more();
      await Future<void>.delayed(Duration.zero);
      expect(pages, isEmpty);
      pending.complete(read(2, next: newNext));
      await more;
      expect(pages, [newNext]);
      expect(controller.items.map((item) => item['id']), [2, 3]);
    },
  );

  test(
    'new refresh invalidates background response and a waiting more',
    () async {
      final pending = Completer<CachedRead<ApiPage<Json>>>();
      var newer = false;
      var continuationCalls = 0;
      final controller = RecordController(
        (_) async {
          continuationCalls++;
          return const ApiPage<Json>([]);
        },
        cached: ({required fresh, required background}) => background
            ? pending.future
            : Future.value(
                newer
                    ? read(9, next: newNext)
                    : read(1, stale: true, next: oldNext),
              ),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final more = controller.more();
      newer = true;
      await controller.refresh(fresh: true);
      pending.complete(read(2, next: oldNext));
      await more;
      expect(controller.items.single['id'], 9);
      expect(controller.next, newNext);
      expect(continuationCalls, 0);
      expect(controller.revalidating, isFalse);
    },
  );

  test(
    'late initial cache result cannot publish after a newer refresh',
    () async {
      final pending = Completer<CachedRead<ApiPage<Json>>>();
      var calls = 0;
      final controller = RecordController(
        (_) async => const ApiPage<Json>([]),
        cached: ({required fresh, required background}) =>
            ++calls == 1 ? pending.future : Future.value(read(9)),
      );
      addTearDown(controller.dispose);
      final old = controller.refresh();
      await controller.refresh();
      pending.complete(read(1, stale: true));
      await old;
      expect(controller.items.single['id'], 9);
      expect(calls, 2);
    },
  );

  for (final kind in [
    FailureKind.unauthenticated,
    FailureKind.forbidden,
    FailureKind.invisible,
    FailureKind.network,
    FailureKind.rateLimited,
  ]) {
    test(
      'background failure $kind applies the permission versus offline/rate matrix',
      () async {
        final pending = Completer<CachedRead<ApiPage<Json>>>();
        final controller = RecordController(
          (_) async => throw StateError('stale cursor'),
          cached: ({required fresh, required background}) => background
              ? pending.future
              : Future.value(read(1, stale: true, next: oldNext)),
        );
        addTearDown(controller.dispose);
        await controller.refresh();
        pending.completeError(ApiFailure(kind));
        await Future<void>.delayed(Duration.zero);
        final revoked = [
          FailureKind.unauthenticated,
          FailureKind.forbidden,
          FailureKind.invisible,
        ].contains(kind);
        expect(controller.items, revoked ? isEmpty : hasLength(1));
        expect(controller.next, revoked ? isNull : oldNext);
        expect(controller.error?.kind, revoked ? kind : isNull);
        expect(controller.backgroundFailure, revoked ? isNull : kind);
        expect(controller.stale, !revoked);
        expect(controller.revalidating, isFalse);
        if (!revoked) expect(controller.fetchedAt, fetched);
      },
    );
  }

  test(
    'dropped background read releases more to revalidate before following a fresh cursor',
    () async {
      final pending = Completer<CachedRead<ApiPage<Json>>>();
      final controller = RecordController(
        (cursor) async {
          expect(cursor, newNext);
          return const ApiPage<Json>([{'id': 3}]);
        },
        cached: ({required fresh, required background}) => background
            ? pending.future
            : Future.value(fresh
                ? read(2, next: newNext)
                : read(1, stale: true, next: oldNext)),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final more = controller.more();
      pending.complete(const CachedRead.dropped());
      await more;
      await controller.more();
      expect(controller.items.map((item) => item['id']), [2, 3]);
      expect(controller.revalidating, isFalse);
      expect(controller.backgroundFailure, isNull);
      expect(controller.error, isNull);
      expect(controller.fetchedAt, fetched);
    },
  );

  test(
    'initial dropped read retains current rows and never reads its value',
    () async {
      var dropped = false;
      final controller = RecordController(
        (_) async => const ApiPage<Json>([]),
        cached: ({required fresh, required background}) async =>
            dropped ? const CachedRead.dropped() : read(1),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      dropped = true;
      await controller.refresh();
      expect(controller.items.single['id'], 1);
      expect(controller.error, isNull);
      expect(controller.loading, isFalse);
    },
  );

  for (final initial in [true, false]) {
    test(
      '${initial ? 'initial' : 'background'} superseded value is discarded and schedules one fresh reread',
      () async {
        final calls = <(bool, bool)>[];
        final published = <int>[];
        var superseded = false;
        final controller = RecordController(
          (_) async => const ApiPage<Json>([]),
          cached: ({required fresh, required background}) async {
            calls.add((fresh, background));
            if (!initial && !background) return read(1, stale: true);
            if (!superseded) {
              superseded = true;
              return read(666, superseded: true);
            }
            return read(2);
          },
        );
        addTearDown(controller.dispose);
        controller.addListener(
          () => published.addAll(
            controller.items.map((item) => item['id'] as int),
          ),
        );
        await controller.refresh();
        await controller.more();
        expect(published, isNot(contains(666)));
        expect(controller.items.single['id'], 2);
        expect(
          calls,
          initial
              ? [(false, false), (true, false)]
              : [(false, false), (true, true), (true, true)],
        );
      },
    );
  }

  test(
    'repeated superseded results stop after quiet recovery with prior rows and a retry notice',
    () async {
      var superseded = false, calls = 0;
      final controller = RecordController(
        (_) async => const ApiPage<Json>([]),
        cached: ({required fresh, required background}) async {
          calls++;
          return superseded ? read(666, superseded: true) : read(1);
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      superseded = true;
      await controller.refresh();
      expect(controller.items.single['id'], 1);
      expect(calls, 4);
      expect(controller.loading, isFalse);
      expect(controller.error?.kind, FailureKind.cancelled);
    },
  );

  test(
    'multi-page SWR reconciles atomically from new first-page cursors and deduplicates',
    () async {
      var phase = 0;
      final backgroundRead = Completer<CachedRead<ApiPage<Json>>>();
      final continuation = Completer<ApiPage<Json>>();
      final cursors = <Uri?>[];
      final controller = RecordController(
        (cursor) {
          cursors.add(cursor);
          return phase == 0
              ? Future.value(
                  const ApiPage<Json>([
                    {'id': 2},
                  ]),
                )
              : continuation.future;
        },
        cached: ({required fresh, required background}) => background
            ? backgroundRead.future
            : Future.value(read(1, stale: phase > 0, next: oldNext)),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.more();
      phase = 1;
      await controller.refresh();
      expect(controller.items.map((item) => item['id']), [1, 2]);
      backgroundRead.complete(read(4, next: newNext));
      await Future<void>.delayed(Duration.zero);
      expect(cursors, [oldNext, newNext]);
      expect(controller.items.map((item) => item['id']), [1, 2]);
      final done = controller.more();
      continuation.complete(
        const ApiPage<Json>([
          {'id': 4},
          {'id': 3},
        ]),
      );
      await done;
      expect(controller.items.map((item) => item['id']), [4, 3]);
      expect(controller.stale, isFalse);
    },
  );

  test(
    'multi-page background continuation failure preserves full window and cursor',
    () async {
      var phase = 0;
      final controller = RecordController(
        (cursor) async {
          if (phase > 0) throw const ApiFailure(FailureKind.network);
          return const ApiPage<Json>([
            {'id': 2},
          ]);
        },
        cached: ({required fresh, required background}) async => read(
          background ? 9 : 1,
          stale: !background && phase > 0,
          next: background ? newNext : oldNext,
        ),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.more();
      phase++;
      await controller.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(controller.items.map((item) => item['id']), [1, 2]);
      expect(controller.next, isNull);
      expect(controller.backgroundFailure, FailureKind.network);
      expect(controller.stale, isTrue);
    },
  );

  test(
    'explicit loaded-window reconciliation fetches cached first page fresh and continuations uncached',
    () async {
      final calls = <(bool, bool)>[];
      final controller = RecordController(
        (_) async => const ApiPage<Json>([
          {'id': 2},
        ]),
        cached: ({required fresh, required background}) async {
          calls.add((fresh, background));
          return read(fresh ? 3 : 1, next: newNext);
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.more();
      await controller.reconcileLoadedWindow();
      expect(calls, [(false, false), (true, false)]);
      expect(controller.items.map((item) => item['id']), [3, 2]);
    },
  );

  test(
    'more retries a background write-timeout stale read in foreground and never uses its cursor',
    () async {
      final first = Completer<CachedRead<ApiPage<Json>>>();
      final second = Completer<CachedRead<ApiPage<Json>>>();
      var backgroundCalls = 0, foregroundCalls = 0;
      final cursors = <Uri?>[];
      final controller = RecordController(
        (cursor) async {
          cursors.add(cursor);
          return const ApiPage<Json>([
            {'id': 4},
          ]);
        },
        cached: ({required fresh, required background}) {
          if (!background) {
            if (fresh) {
              foregroundCalls++;
              return second.future;
            }
            return Future.value(read(1, stale: true, next: oldNext));
          }
          backgroundCalls++;
          return first.future;
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final waiting = controller.more();
      first.complete(read(2, stale: true, next: oldNext));
      await Future<void>.delayed(Duration.zero);
      expect(cursors, isEmpty);
      expect(backgroundCalls, 1);
      expect(foregroundCalls, 1);
      second.complete(read(3, next: newNext));
      await waiting;
      expect(backgroundCalls, 1);
      expect(cursors, [newNext]);
      expect(controller.items.map((item) => item['id']), [3, 4]);
    },
  );

  for (final backgroundRefresh in [true, false]) {
    test(
      '${backgroundRefresh ? 'background' : 'explicit'} multi-page write-timeout never follows a stale first-page cursor',
      () async {
        var phase = 0;
        final cursors = <Uri?>[];
        final controller = RecordController(
          (cursor) async {
            cursors.add(cursor);
            if (phase == 1) throw StateError('must not follow stale cursor');
            return ApiPage<Json>([
              {'id': phase == 0 ? 2 : 4},
            ]);
          },
          cached: ({required fresh, required background}) async {
            if (phase == 0) return read(1, next: oldNext);
            if (phase == 1) return read(9, stale: true, next: oldNext);
            return read(3, next: newNext);
          },
        );
        addTearDown(controller.dispose);
        await controller.refresh();
        await controller.more();
        phase = 1;
        if (backgroundRefresh) {
          await controller.refresh();
          await Future<void>.delayed(Duration.zero);
        } else {
          await controller.reconcileLoadedWindow();
        }
        expect(controller.items.map((item) => item['id']), [1, 2]);
        expect(cursors, [oldNext]);
        expect(controller.error, isNull);
        expect(controller.backgroundFailure, isNull);
        expect(controller.stale, isTrue);
        phase = 2;
        await controller.more();
        expect(cursors, [oldNext, newNext]);
        expect(controller.items.map((item) => item['id']), [3, 4]);
        expect(controller.stale, isFalse);
      },
    );
  }

  test(
    'explicit fresh refresh replaces the loaded window with only page one',
    () async {
      var first = 1;
      final controller = RecordController(
        (_) async => const ApiPage<Json>([
          {'id': 2},
        ]),
        cached: ({required fresh, required background}) async =>
            read(first, next: oldNext),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.more();
      expect(controller.items.map((item) => item['id']), [1, 2]);
      first = 3;
      await controller.refresh(fresh: true);
      expect(controller.items.map((item) => item['id']), [3]);
      expect(controller.next, oldNext);
    },
  );

  test('dispose fences background completion and listener emissions', () async {
    final pending = Completer<CachedRead<ApiPage<Json>>>();
    final controller = RecordController(
      (_) async => const ApiPage<Json>([]),
      cached: ({required fresh, required background}) =>
          background ? pending.future : Future.value(read(1, stale: true)),
    );
    await controller.refresh();
    final done = controller.more();
    controller.dispose();
    pending.complete(read(2));
    await done;
    expect(controller.items, isEmpty);
  });
}
