import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';

const _wideTable = '''
Paragraph before the table.

| Scenario | Baseline expectation | Observed baseline | Upgrade expectation | Observed upgrade | Result |
| --- | --- | --- | --- | --- | --- |
| Database upgrade | Existing data is preserved | Verified | All migrations complete successfully | Verified | Final result |

Paragraph after the table.
''';

void main() {
  for (final configuration in [(320.0, 1.0), (390.0, 1.0), (320.0, 2.0)]) {
    testWidgets(
      'wide Markdown table stays readable at ${configuration.$1}px and ${configuration.$2}x text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(configuration.$1, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(configuration.$1, 1000),
                textScaler: TextScaler.linear(configuration.$2),
              ),
              child: const Scaffold(
                body: SingleChildScrollView(
                  padding: EdgeInsets.all(16),
                  child: MarkdownView(_wideTable),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final horizontal = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.right,
        );
        expect(horizontal, findsOneWidget);
        final scroll = tester.state<ScrollableState>(horizontal);
        expect(scroll.position.maxScrollExtent, greaterThan(configuration.$1));
        expect(tester.getSize(find.byType(Table)).height, lessThan(500));
        expect(
          tester.getSize(find.byType(MarkdownView)).width,
          configuration.$1 - 32,
        );

        await tester.drag(
          horizontal,
          Offset(-scroll.position.maxScrollExtent - 100, 0),
        );
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0));
        expect(
          find.text('Final result', findRichText: true).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.text('Paragraph after the table.', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
