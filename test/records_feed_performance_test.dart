import 'dart:async';
import 'dart:collection';

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
        0,
        reason: 'a parent rebuild with stable callbacks must reuse derived rows',
      );
      expect(arrangeCalls, 0);
      expect(sectionCalls, 0);

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

  testWidgets(
    'parent rebuilds reuse null or stable derivation inputs while changed callbacks rederive',
    (tester) async {
      final probeItems = _ProbeList([
        {'id': 1, 'title': 'One'},
        {'id': 2, 'title': 'Two'},
        {'id': 3, 'title': 'Three'},
      ]);
      var parentBuilds = 0;
      var visibleCalls = 0;
      var arrangeCalls = 0;
      var sectionCalls = 0;
      bool stableVisible(Json item) {
        visibleCalls++;
        return true;
      }
      List<Json> stableArrange(List<Json> items) {
        arrangeCalls++;
        return List<Json>.of(items);
      }
      String stableSection(Json item) {
        sectionCalls++;
        return 'Items';
      }

      bool Function(Json item)? visible;
      List<Json> Function(List<Json> items)? arrange;
      String Function(Json item)? sectionOf;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              parentBuilds++;
              return Scaffold(
                body: RecordsFeed(
                  identity: 'stable-parent',
                  load: (_) async => ApiPage<Json>(probeItems),
                  visible: visible,
                  arrange: arrange,
                  sectionOf: sectionOf,
                  itemBuilder: (context, item) =>
                      SizedBox(height: 48, child: Text(item['title']! as String)),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      probeItems.reads = 0;
      rebuild(() {});
      await tester.pump();
      expect(parentBuilds, 2);
      expect(
        probeItems.reads,
        0,
        reason: 'null callbacks and the same item list need no row derivation',
      );

      visible = stableVisible;
      arrange = stableArrange;
      sectionOf = stableSection;
      rebuild(() {});
      await tester.pump();
      expect(visibleCalls, 3);
      expect(arrangeCalls, 1);
      expect(sectionCalls, 3);
      visibleCalls = 0;
      arrangeCalls = 0;
      sectionCalls = 0;
      probeItems.reads = 0;

      rebuild(() {});
      await tester.pump();
      expect(visibleCalls, 0);
      expect(arrangeCalls, 0);
      expect(sectionCalls, 0);
      expect(probeItems.reads, 0);

      visible = (item) {
        visibleCalls++;
        return true;
      };
      rebuild(() {});
      await tester.pump();
      expect(
        visibleCalls,
        3,
        reason: 'a changed callback identity must invalidate derived rows',
      );
      expect(arrangeCalls, 1);
      expect(sectionCalls, 3);

      visibleCalls = 0;
      arrangeCalls = 0;
      sectionCalls = 0;
      arrange = (items) {
        arrangeCalls++;
        return items.reversed.toList();
      };
      rebuild(() {});
      await tester.pump();
      expect(visibleCalls, 3);
      expect(arrangeCalls, 1);
      expect(sectionCalls, 3);
      expect(find.text('Three'), findsOneWidget);

      visibleCalls = 0;
      arrangeCalls = 0;
      sectionCalls = 0;
      sectionOf = (item) {
        sectionCalls++;
        return item['id'] == 1 ? 'First' : 'Other';
      };
      rebuild(() {});
      await tester.pump();
      expect(visibleCalls, 3);
      expect(arrangeCalls, 1);
      expect(sectionCalls, 3);
      expect(find.text('First'), findsOneWidget);
    },
  );

  testWidgets(
    'pagination and list mutations rederive while identity and controller changes start fresh',
    (tester) async {
      final feed = GlobalKey<RecordsFeedState>();
      var visibleCalls = 0;
      var identity = 'first';
      var controllerEpoch = 0;
      late StateSetter rebuild;

      bool visible(Json item) {
        visibleCalls++;
        return true;
      }

      Future<ApiPage<Json>> load(Uri? next) async {
        if (controllerEpoch == 1) {
          return ApiPage<Json>([
            {'id': 30, 'title': 'Replacement controller'},
          ]);
        }
        if (identity == 'second') {
          return ApiPage<Json>([
            {'id': 20, 'title': 'Second identity'},
          ]);
        }
        return next == null
            ? ApiPage<Json>([
                {'id': 1, 'title': 'First page'},
              ], next: page2)
            : ApiPage<Json>([
                {'id': 2, 'title': 'Second page'},
              ]);
      }

      Widget app() => MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: RecordsFeed(
                key: controllerEpoch == 0
                    ? feed
                    : ValueKey('controller-$controllerEpoch'),
                identity: identity,
                load: load,
                visible: visible,
                itemBuilder: (context, item) =>
                    SizedBox(height: 48, child: Text(item['title']! as String)),
              ),
            );
          },
        ),
      );

      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump();
      visibleCalls = 0;

      await feed.currentState!.controller.more();
      await tester.pump();
      expect(visibleCalls, 2);
      expect(find.text('Second page'), findsOneWidget);

      visibleCalls = 0;
      feed.currentState!.patchItem({'id': 1, 'title': 'Patched'});
      await tester.pump();
      expect(visibleCalls, 2);
      expect(find.text('Patched'), findsOneWidget);

      visibleCalls = 0;
      feed.currentState!.removeItem('2');
      await tester.pump();
      expect(visibleCalls, 1);
      expect(find.text('Second page'), findsNothing);

      visibleCalls = 0;
      feed.currentState!.prependItem({'id': 3, 'title': 'Prepended'});
      await tester.pump();
      expect(visibleCalls, 2);
      expect(find.text('Prepended'), findsOneWidget);

      visibleCalls = 0;
      identity = 'second';
      rebuild(() {});
      await tester.pump();
      expect(find.text('Patched'), findsNothing);
      await tester.pump();
      expect(find.text('Second identity'), findsOneWidget);
      expect(visibleCalls, 1);

      controllerEpoch = 1;
      rebuild(() {});
      await tester.pump();
      expect(find.text('Second identity'), findsNothing);
      await tester.pump();
      expect(find.text('Replacement controller'), findsOneWidget);
    },
  );

  testWidgets('rows remain lazy and only rounded endpoints add clip layers', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    var builtRows = 0;
    var sectionCalls = 0;
    var taps = 0;
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
              return InkWell(onTap: () => taps++, child: SizedBox(
                height: 64, child: Text(item['title']! as String)));
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      MediaQuery.textScalerOf(tester.element(find.byType(RecordsFeed))).scale(1),
      2,
    );

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
            sectionOf: (_) => 'Section',
            itemBuilder: (context, item) =>
                InkWell(onTap: () => taps++, child:
                  SizedBox(height: 48, child: Text(item['title']! as String))),
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
    expect(
      find.byType(Divider),
      findsNWidgets(2),
      reason: 'each non-first row keeps one indented divider',
    );
    final divider = tester.widget<Divider>(find.byType(Divider).first);
    expect(divider.height, 1);
    expect(divider.indent, 16);
    expect(find.text('Section'), findsOneWidget);
    await tester.tap(find.text('Short row 1'));
    await tester.pump();
    expect(taps, 1, reason: 'the row Material still paints InkWell feedback');
    expect(tester.takeException(), isNull);
  });
}

final class _ProbeList extends ListBase<Json> {
  _ProbeList(this._items);
  final List<Json> _items;
  int reads = 0;

  @override
  int get length => _items.length;

  @override
  set length(int value) => _items.length = value;

  @override
  Json operator [](int index) {
    reads++;
    return _items[index];
  }

  @override
  void operator []=(int index, Json value) => _items[index] = value;
}
