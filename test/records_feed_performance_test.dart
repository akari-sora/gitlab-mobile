import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';

void main() {
  final page2 = Uri.parse('https://example.com/api/v4/issues?page=2');

  testWidgets(
    'loading notifications reuse derived rows and page failure preserves content',
    (tester) async {
      final firstPage = Completer<ApiPage<Json>>();
      final secondPage = Completer<ApiPage<Json>>();
      final feed = GlobalKey<RecordsFeedState>();
      var visibleCalls = 0;
      var arrangeCalls = 0;
      var sectionCalls = 0;

      bool visible(Json item) {
        visibleCalls++;
        return true;
      }

      List<Json> arrange(List<Json> items) {
        arrangeCalls++;
        return List<Json>.of(items);
      }

      String sectionOf(Json item) {
        sectionCalls++;
        return item['section']! as String;
      }

      Future<ApiPage<Json>> load(Uri? next) =>
          next == null ? firstPage.future : secondPage.future;
      Widget itemBuilder(BuildContext context, Json item) =>
          SizedBox(height: 56, child: Text(item['title']! as String));

      Widget app() => MaterialApp(
        home: Scaffold(
          body: RecordsFeed(
            key: feed,
            identity: 'issues',
            load: load,
            visible: visible,
            arrange: arrange,
            sectionOf: sectionOf,
            itemBuilder: itemBuilder,
          ),
        ),
      );

      await tester.pumpWidget(app());
      firstPage.complete(
        ApiPage<Json>([
          {'id': 1, 'title': 'Issue 1', 'section': 'Open'},
          {'id': 2, 'title': 'Issue 2', 'section': 'Open'},
          {'id': 3, 'title': 'Issue 3', 'section': 'Closed'},
        ], next: page2),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Issue 1'), findsOneWidget);
      visibleCalls = 0;
      arrangeCalls = 0;
      sectionCalls = 0;

      final loadingMore = feed.currentState!.controller.more();
      await tester.pump();
      expect(
        visibleCalls,
        0,
        reason: 'loadingMore must not refilter unchanged items',
      );
      expect(
        arrangeCalls,
        0,
        reason: 'loadingMore must not rearrange unchanged items',
      );
      expect(
        sectionCalls,
        0,
        reason: 'loadingMore must reuse unchanged section labels',
      );

      secondPage.completeError(const ApiFailure(FailureKind.network));
      await loadingMore;
      await tester.pump();
      expect(find.text('Issue 1'), findsOneWidget);
      expect(feed.currentState!.controller.items, hasLength(3));
      expect(feed.currentState!.controller.failedMore, isTrue);
      expect(
        visibleCalls,
        0,
        reason: 'page-two failure must keep the derived first page',
      );
      expect(
        arrangeCalls,
        0,
        reason: 'page-two failure must keep the derived first page',
      );
      expect(
        sectionCalls,
        0,
        reason: 'page-two failure must keep the derived first page',
      );

      feed.currentState!.patchItem({
        'id': 2,
        'title': 'Issue 2 updated',
        'section': 'Open',
      });
      await tester.pump();
      expect(visibleCalls, 3);
      expect(arrangeCalls, 1);
      expect(sectionCalls, 3);
      expect(find.text('Issue 2 updated'), findsOneWidget);

      visibleCalls = 0;
      arrangeCalls = 0;
      sectionCalls = 0;
      await tester.pumpWidget(app());
      expect(
        visibleCalls,
        3,
        reason: 'a new widget instance can carry new closure state',
      );
      expect(arrangeCalls, 1);
      expect(sectionCalls, 3);

      visibleCalls = 0;
      arrangeCalls = 0;
      sectionCalls = 0;
      feed.currentState!.removeItem('1');
      await tester.pump();
      expect(visibleCalls, 2);
      expect(arrangeCalls, 1);
      expect(sectionCalls, 2);

      visibleCalls = 0;
      arrangeCalls = 0;
      sectionCalls = 0;
      feed.currentState!.prependItem({
        'id': 4,
        'title': 'Issue 4',
        'section': 'Open',
      });
      await tester.pump();
      expect(visibleCalls, 3);
      expect(arrangeCalls, 1);
      expect(sectionCalls, 3);
    },
  );

  testWidgets('rows remain lazy and only rounded endpoints add clip layers', (
    tester,
  ) async {
    var builtRows = 0;
    var sectionCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordsFeed(
            identity: 'grouped',
            grouped: true,
            load: (_) async => ApiPage<Json>([
              for (var index = 0; index < 100; index++)
                {'id': index, 'title': 'Row $index'},
            ]),
            sectionOf: (item) {
              sectionCalls++;
              return 'Section';
            },
            itemBuilder: (context, item) {
              builtRows++;
              return SizedBox(
                height: 64,
                child: Text(item['title']! as String),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      builtRows,
      lessThan(100),
      reason: 'SliverList must build only the visible rows',
    );
    expect(
      sectionCalls,
      lessThan(100),
      reason: 'section labels stay lazy with the row builder',
    );
    expect(find.text('Row 99'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordsFeed(
            identity: 'three-grouped',
            grouped: true,
            load: (_) async => ApiPage<Json>([
              for (var index = 0; index < 3; index++)
                {'id': index, 'title': 'Short row $index'},
            ]),
            itemBuilder: (context, item) =>
                SizedBox(height: 48, child: Text(item['title']! as String)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(ClipRRect),
      findsNWidgets(2),
      reason: 'middle rows do not need a zero-radius clip layer',
    );
  });
}
