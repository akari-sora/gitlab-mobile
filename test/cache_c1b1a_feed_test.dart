import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';

CachedRead<ApiPage<Json>> _cachedPage(
  int id, {
  bool stale = false,
  Uri? next,
}) => CachedRead(
  value: ApiPage<Json>([
    {'id': id, 'title': 'Row $id'},
  ], next: next),
  fetchedAt: DateTime.utc(2026, 10, 23, 8),
  lineage: CacheLineage.memory,
  stale: stale,
);

Widget _host({
  required Key key,
  required String identity,
  required Future<ApiPage<Json>> Function(Uri? next) load,
  Future<CachedRead<ApiPage<Json>>> Function({
    required bool fresh,
    required bool background,
  })?
  cached,
  bool tickerEnabled = true,
}) => MaterialApp(
  home: Scaffold(
    body: TickerMode(
      enabled: tickerEnabled,
      child: RecordsFeed(
        key: key,
        identity: identity,
        cached: cached,
        load: load,
        itemBuilder: (context, item) =>
            SizedBox(height: 56, child: Text(item['title']! as String)),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'one-row cache fixture, warm state, 800x600 viewport, fixed clock: pull completion forwards fresh true once',
    (tester) async {
      final calls = <({bool fresh, bool background})>[];
      var id = 0;
      final key = GlobalKey<RecordsFeedState>();

      await tester.pumpWidget(
        _host(
          key: key,
          identity: 'pull',
          load: (_) => throw StateError('first page must use cached'),
          cached: ({required fresh, required background}) async {
            calls.add((fresh: fresh, background: background));
            return _cachedPage(++id);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Row 1'), findsOneWidget);
      expect(calls, [(fresh: false, background: false)]);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(find.text('Row 2'), findsOneWidget);
      expect(calls, [
        (fresh: false, background: false),
        (fresh: true, background: false),
      ]);
    },
  );

  testWidgets(
    'imperative feed refresh preserves the explicit fresh read contract',
    (tester) async {
      final calls = <bool>[];
      final key = GlobalKey<RecordsFeedState>();
      await tester.pumpWidget(
        _host(
          key: key,
          identity: 'imperative',
          load: (_) => throw StateError('first page must use cached'),
          cached: ({required fresh, required background}) async {
            calls.add(fresh);
            return _cachedPage(calls.length);
          },
        ),
      );
      await tester.pumpAndSettle();
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      expect(calls, [false, true]);
      expect(find.text('Row 2'), findsOneWidget);
    },
  );

  testWidgets('TickerMode changes do not rebuild a retained fresh feed', (
    tester,
  ) async {
    var enabled = true, builds = 0;
    late StateSetter rebuild;
    final child = RecordsFeed(
      identity: 'retained',
      cached: ({required fresh, required background}) async => _cachedPage(1),
      load: (_) => throw StateError('first page must use cached'),
      header: (context, controller) {
        builds++;
        return const SizedBox.shrink();
      },
      itemBuilder: (context, item) => Text(item['title'] as String),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return TickerMode(enabled: enabled, child: child);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    builds = 0;
    rebuild(() => enabled = false);
    await tester.pump();
    rebuild(() => enabled = true);
    await tester.pump();
    expect(builds, 0);
  });

  testWidgets(
    'one stale row fixture, cached state, 800x600 viewport, fixed clock: TickerMode false blocks revalidation until enabled and background settles',
    (tester) async {
      final calls = <({bool fresh, bool background})>[];
      final backgroundRead = Completer<CachedRead<ApiPage<Json>>>();
      final key = GlobalKey<RecordsFeedState>();

      Future<CachedRead<ApiPage<Json>>> cached({
        required bool fresh,
        required bool background,
      }) {
        calls.add((fresh: fresh, background: background));
        if (fresh) return backgroundRead.future;
        return Future.value(_cachedPage(1, stale: true));
      }

      await tester.pumpWidget(
        _host(
          key: key,
          identity: 'offstage',
          tickerEnabled: false,
          load: (_) => throw StateError('first page must use cached'),
          cached: cached,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Row 1'), findsOneWidget);
      expect(calls, [(fresh: false, background: false)]);
      expect(key.currentState!.controller.revalidating, isFalse);

      await tester.pumpWidget(
        _host(
          key: key,
          identity: 'offstage',
          tickerEnabled: true,
          load: (_) => throw StateError('first page must use cached'),
          cached: cached,
        ),
      );
      await tester.pump();
      expect(calls, [
        (fresh: false, background: false),
        (fresh: true, background: true),
      ]);
      expect(key.currentState!.controller.revalidating, isTrue);

      backgroundRead.complete(_cachedPage(2));
      await tester.pumpAndSettle();
      expect(find.text('Row 2'), findsOneWidget);
      expect(key.currentState!.controller.revalidating, isFalse);
    },
  );

  testWidgets(
    'two-account fixture, cold cache state, 800x600 viewport, fixed clock: identity switch completion cannot publish the old async first page',
    (tester) async {
      final oldPage = Completer<CachedRead<ApiPage<Json>>>();
      final key = GlobalKey<RecordsFeedState>();

      await tester.pumpWidget(
        _host(
          key: key,
          identity: 'account-a',
          load: (_) => throw StateError('first page must use cached'),
          cached: ({required fresh, required background}) => oldPage.future,
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        _host(
          key: key,
          identity: 'account-b',
          load: (_) => throw StateError('first page must use cached'),
          cached: ({required fresh, required background}) async =>
              _cachedPage(2),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Row 2'), findsOneWidget);

      oldPage.complete(_cachedPage(1));
      await tester.pumpAndSettle();
      expect(find.text('Row 2'), findsOneWidget);
      expect(find.text('Row 1'), findsNothing);
    },
  );

  testWidgets(
    'two-page unmigrated fixture, no cache state, 800x600 viewport, fixed clock: first and continuation loaders finish unchanged',
    (tester) async {
      final next = Uri.parse('https://example.com/api/v4/issues?page=2');
      final calls = <Uri?>[];
      final key = GlobalKey<RecordsFeedState>();

      await tester.pumpWidget(
        _host(
          key: key,
          identity: 'legacy',
          load: (cursor) async {
            calls.add(cursor);
            return cursor == null
                ? ApiPage<Json>([
                    {'id': 1, 'title': 'Row 1'},
                  ], next: next)
                : const ApiPage<Json>([
                    {'id': 2, 'title': 'Row 2'},
                  ]);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Row 1'), findsOneWidget);
      expect(calls, [null]);

      await key.currentState!.controller.more();
      await tester.pumpAndSettle();
      expect(find.text('Row 1'), findsOneWidget);
      expect(find.text('Row 2'), findsOneWidget);
      expect(calls, [null, next]);
    },
  );
}
