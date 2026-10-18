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
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('${widget.label} $taps'),
  );
}

Widget _host(int index, {RevealStyle style = RevealStyle.fadeThrough, bool reduce = false,
    TextDirection direction = TextDirection.ltr}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: IndexedStack(index: index, children: [
          for (final (i, label) in ['A', 'B'].indexed)
            RevealOnShow(shown: index == i, style: style, child: _Counter(label)),
        ]),
      ),
    ),
  ),
);

double _opacity(WidgetTester tester, String label) => tester
    .widget<FadeTransition>(find.ancestor(of: find.textContaining(label), matching: find.byType(FadeTransition)).first)
    .opacity
    .value;

Offset _slide(WidgetTester tester, String label) => tester
    .widget<SlideTransition>(find.ancestor(of: find.textContaining(label), matching: find.byType(SlideTransition)).first)
    .position
    .value;

void main() {
  testWidgets('the first build shows the pane at rest', (tester) async {
    await tester.pumpWidget(_host(0));
    expect(_opacity(tester, 'A'), 1);
  });

  testWidgets('switching fades the new pane in and keeps both panes alive', (tester) async {
    await tester.pumpWidget(_host(0));
    await tester.tap(find.text('A 0'));
    await tester.pump();
    expect(find.text('A 1'), findsOneWidget);

    await tester.pumpWidget(_host(1));
    await tester.pump(const Duration(milliseconds: 40));
    final mid = _opacity(tester, 'B');
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));
    await tester.pumpAndSettle();
    expect(_opacity(tester, 'B'), 1);

    await tester.pumpWidget(_host(0));
    await tester.pumpAndSettle();
    expect(find.text('A 1', skipOffstage: false), findsOneWidget, reason: 'the first pane kept its state');
  });

  testWidgets('reduced motion switches at once', (tester) async {
    await tester.pumpWidget(_host(0, reduce: true));
    await tester.pumpWidget(_host(1, reduce: true));
    await tester.pump();
    expect(_opacity(tester, 'B'), 1);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('shared axis enters from the trailing edge forward and the leading edge back', (tester) async {
    await tester.pumpWidget(_host(0, style: RevealStyle.forward));
    await tester.pumpWidget(_host(1, style: RevealStyle.forward));
    await tester.pump(const Duration(milliseconds: 20));
    expect(_slide(tester, 'B').dx, greaterThan(0));
    await tester.pumpAndSettle();
    expect(_slide(tester, 'B'), Offset.zero);

    await tester.pumpWidget(_host(0, style: RevealStyle.backward));
    await tester.pumpWidget(_host(1, style: RevealStyle.backward));
    await tester.pump(const Duration(milliseconds: 20));
    expect(_slide(tester, 'B').dx, lessThan(0));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host(0, style: RevealStyle.forward, direction: TextDirection.rtl));
    await tester.pumpWidget(_host(1, style: RevealStyle.forward, direction: TextDirection.rtl));
    await tester.pump(const Duration(milliseconds: 20));
    expect(_slide(tester, 'B').dx, lessThan(0), reason: 'right-to-left mirrors the axis');
    await tester.pumpAndSettle();
  });

  testWidgets('animateOnInsert plays when the pane is built already shown', (tester) async {
    await tester.pumpWidget(MaterialApp(home: RevealOnShow(
      shown: true, style: RevealStyle.forward, animateOnInsert: true, child: const Text('late'))));
    await tester.pump(const Duration(milliseconds: 20));
    expect(_opacity(tester, 'late'), lessThan(1));
    await tester.pumpAndSettle();
    expect(_opacity(tester, 'late'), 1);
  });
}
