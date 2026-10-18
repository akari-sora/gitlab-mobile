import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/motion.dart';

Widget _host(bool expanded, {bool reduce = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Scaffold(body: Column(children: [
      ExpandSection(expanded: expanded, child: const SizedBox(height: 120, child: Text('details'))),
      const Text('below'),
    ])),
  ),
);

void main() {
  testWidgets('a section folds open and closed, then leaves the tree', (tester) async {
    await tester.pumpWidget(_host(false));
    expect(find.text('details'), findsNothing);
    final collapsed = tester.getTopLeft(find.text('below')).dy;

    await tester.pumpWidget(_host(true));
    await tester.pump(const Duration(milliseconds: 100));
    final opening = tester.getTopLeft(find.text('below')).dy;
    expect(opening, greaterThan(collapsed));
    expect(opening, lessThan(collapsed + 120), reason: 'content below moves with the section');
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('below')).dy, collapsed + 120);

    await tester.pumpWidget(_host(false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('details'), findsOneWidget, reason: 'the rows stay while they fold away');
    await tester.pumpAndSettle();
    expect(find.text('details'), findsNothing);
    expect(tester.getTopLeft(find.text('below')).dy, collapsed);
  });

  testWidgets('reduced motion opens and closes at once', (tester) async {
    await tester.pumpWidget(_host(false, reduce: true));
    await tester.pumpWidget(_host(true, reduce: true));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('details'), findsOneWidget);
    await tester.pumpWidget(_host(false, reduce: true));
    await tester.pump();
    expect(find.text('details'), findsNothing);
  });

  testWidgets('scrolling to the start glides, or jumps with reduced motion', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    Widget list({bool reduce = false}) => MaterialApp(home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Scaffold(body: ListView.builder(controller: controller, itemCount: 200,
        itemBuilder: (context, index) => SizedBox(height: 50, child: Text('Row $index')))),
    ));
    await tester.pumpWidget(list());
    controller.jumpTo(3000);
    await tester.pump();
    final glide = scrollToStart(tester.element(find.byType(ListView)), controller);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, inExclusiveRange(0, 3000), reason: 'it moves over several frames');
    await tester.pumpAndSettle();
    await glide;
    expect(controller.offset, 0);

    await tester.pumpWidget(list(reduce: true));
    controller.jumpTo(3000);
    await tester.pump();
    unawaited(scrollToStart(tester.element(find.byType(ListView)), controller));
    expect(controller.offset, 0, reason: 'reduced motion jumps');
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the chevron turns over with its section', (tester) async {
    Widget chevron(bool open) => MaterialApp(home: Center(child: TurnChevron(open: open)));
    await tester.pumpWidget(chevron(false));
    expect(tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns, 0);
    await tester.pumpWidget(chevron(true));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns, .5);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });
}
