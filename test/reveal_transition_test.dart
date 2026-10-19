import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/reveal_transition.dart';

/// Counts its own taps, so a test can tell whether the element survived.
class _Counter extends StatefulWidget {
  const _Counter(this.label);
  final String label;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: TextButton(
      onPressed: () => setState(() => taps++),
      child: Text('${widget.label} $taps'),
    ),
  );
}

Widget _host(
  int index, {
  StackMotion motion = StackMotion.fade,
  bool reduce = false,
  TextDirection direction = TextDirection.ltr,
  VoidCallback? onSettled,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: AnimatedIndexedStack(
          index: index,
          sizing: StackFit.expand,
          motion: (_, _) => motion,
          onSettled: onSettled,
          children: const [_Counter('A'), _Counter('B'), _Counter('C')],
        ),
      ),
    ),
  ),
);

Finder _layer(String label) => find.ancestor(
  of: find.textContaining(label, skipOffstage: false),
  matching: find.byType(Offstage, skipOffstage: false),
).first;

bool _painted(WidgetTester tester, String label) =>
    !tester.widget<Offstage>(_layer(label)).offstage;

double _opacity(WidgetTester tester, String label) => tester
    .widget<FadeTransition>(find.descendant(
      of: _layer(label),
      matching: find.byType(FadeTransition, skipOffstage: false),
      skipOffstage: false,
    ).first)
    .opacity
    .value;

Offset _slide(WidgetTester tester, String label) => tester
    .widget<SlideTransition>(find.descendant(
      of: _layer(label),
      matching: find.byType(SlideTransition, skipOffstage: false),
      skipOffstage: false,
    ).first)
    .position
    .value;

/// The labels of the painted layers, bottom to top.
List<String> _paintOrder(WidgetTester tester) {
  final stack = tester.widget<Stack>(find.descendant(
    of: find.byType(AnimatedIndexedStack),
    matching: find.byType(Stack),
  ).first);
  return [
    for (final child in stack.children)
      if (child is KeyedSubtree && !(child.child as Offstage).offstage)
        'ABC'[(child.key! as ValueKey<int>).value],
  ];
}

void main() {
  testWidgets('the first build paints only the current child, at rest', (tester) async {
    await tester.pumpWidget(_host(0));
    expect(_paintOrder(tester), ['A']);
    expect(_opacity(tester, 'A'), 1);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a fade never uncovers the background and keeps every child alive', (tester) async {
    await tester.pumpWidget(_host(0));
    await tester.tap(find.text('A 0'));
    await tester.pump();

    var settled = 0;
    await tester.pumpWidget(_host(1, onSettled: () => settled++));
    final duration = AnimatedIndexedStack.durationOf(StackMotion.fade);
    var elapsed = Duration.zero;
    const step = Duration(milliseconds: 10);
    while (elapsed < duration) {
      // Every frame of the switch: the page being left is painted, fully
      // opaque and unmoved underneath the incoming one.
      expect(_paintOrder(tester), ['A', 'B']);
      expect(_painted(tester, 'A'), isTrue);
      expect(_opacity(tester, 'A'), 1);
      if (elapsed >= duration * .3) {
        expect(_opacity(tester, 'B'), 1, reason: 'opacity settles early so the layers barely overlap');
      }
      await tester.pump(step);
      elapsed += step;
    }
    await tester.pumpAndSettle();
    expect(_paintOrder(tester), ['B']);
    expect(_opacity(tester, 'B'), 1);
    expect(settled, 1);

    await tester.tap(find.text('B 0'));
    await tester.pumpWidget(_host(0));
    await tester.pumpAndSettle();
    expect(find.text('A 1'), findsOneWidget, reason: 'the first child kept its state');
    expect(find.text('B 1', skipOffstage: false), findsOneWidget);
  });

  testWidgets('only the current child takes taps during a switch', (tester) async {
    await tester.pumpWidget(_host(0, motion: StackMotion.pop));
    await tester.pumpWidget(_host(1, motion: StackMotion.pop));
    await tester.pump(const Duration(milliseconds: 20));
    // A pops on top of B, but the tap goes through it to B.
    expect(_paintOrder(tester), ['B', 'A']);
    await tester.tapAt(tester.getCenter(find.byType(AnimatedIndexedStack)));
    await tester.pumpAndSettle();
    expect(find.text('B 1'), findsOneWidget);
    expect(find.text('A 0', skipOffstage: false), findsOneWidget);
  });

  testWidgets('push slides the new child in over the old; pop slides the old one off', (tester) async {
    await tester.pumpWidget(_host(0, motion: StackMotion.push));
    await tester.pumpWidget(_host(1, motion: StackMotion.push));
    await tester.pump(const Duration(milliseconds: 30));
    expect(_paintOrder(tester), ['A', 'B']);
    expect(_slide(tester, 'B').dx, greaterThan(0), reason: 'enters from the trailing edge');
    expect(_slide(tester, 'A'), Offset.zero, reason: 'the page underneath stays put');
    expect(_opacity(tester, 'A'), 1);
    await tester.pumpAndSettle();
    expect(_slide(tester, 'B'), Offset.zero);

    await tester.pumpWidget(_host(0, motion: StackMotion.pop));
    await tester.pump(const Duration(milliseconds: 60));
    expect(_paintOrder(tester), ['A', 'B'], reason: 'the leaving page moves on top');
    expect(_slide(tester, 'B').dx, greaterThan(0), reason: 'it leaves towards the trailing edge');
    expect(_slide(tester, 'A'), Offset.zero);
    expect(_opacity(tester, 'A'), 1, reason: 'the page it uncovers is already in place');
    await tester.pumpAndSettle();
    expect(_paintOrder(tester), ['A']);
    expect(_slide(tester, 'B'), Offset.zero, reason: 'a hidden child rests unmoved');
  });

  testWidgets('the moving page is opaque even when it has no background of its own', (tester) async {
    Color backdrop(String label) => tester.widget<ColoredBox>(find.descendant(
      of: _layer(label),
      matching: find.byType(ColoredBox, skipOffstage: false),
      skipOffstage: false,
    ).first).color;
    await tester.pumpWidget(_host(0, motion: StackMotion.push));
    expect(backdrop('A').a, 0, reason: 'at rest nothing extra is painted');
    await tester.pumpWidget(_host(1, motion: StackMotion.push));
    await tester.pump(const Duration(milliseconds: 30));
    final canvas = Theme.of(tester.element(find.byType(AnimatedIndexedStack))).scaffoldBackgroundColor;
    expect(backdrop('B'), canvas);
    expect(backdrop('B').a, 1);
    await tester.pumpAndSettle();
    expect(backdrop('B').a, 0);

    await tester.pumpWidget(_host(0, motion: StackMotion.pop));
    await tester.pump(const Duration(milliseconds: 30));
    expect(backdrop('B'), canvas, reason: 'the page sliding away stays a solid sheet');
    await tester.pumpAndSettle();
  });

  testWidgets('right-to-left mirrors the axis', (tester) async {
    await tester.pumpWidget(_host(0, motion: StackMotion.push, direction: TextDirection.rtl));
    await tester.pumpWidget(_host(1, motion: StackMotion.push, direction: TextDirection.rtl));
    await tester.pump(const Duration(milliseconds: 30));
    expect(_slide(tester, 'B').dx, lessThan(0));
    await tester.pumpAndSettle();
  });

  testWidgets('a switch during a switch starts again from the current child', (tester) async {
    await tester.pumpWidget(_host(0));
    await tester.pumpWidget(_host(1));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(_host(2));
    await tester.pump(const Duration(milliseconds: 10));
    expect(_paintOrder(tester), ['B', 'C']);
    await tester.pumpAndSettle();
    expect(_paintOrder(tester), ['C']);
  });

  testWidgets('reduced motion switches at once and still reports settling', (tester) async {
    var settled = 0;
    await tester.pumpWidget(_host(0, reduce: true));
    await tester.pumpWidget(_host(1, reduce: true, onSettled: () => settled++));
    expect(_paintOrder(tester), ['B']);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump();
    expect(settled, 1);
  });
}
