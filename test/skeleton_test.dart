import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byType(RowsSkeleton),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

int _rows(WidgetTester tester) =>
    find
        .descendant(
          of: find.byType(RowsSkeleton),
          matching: find.byType(FractionallySizedBox),
        )
        .evaluate()
        .length ~/
    2;

void main() {
  testWidgets(
    'shows its rows in a scroll view and only what fits in a bounded body',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [SliverToBoxAdapter(child: RowsSkeleton())],
            ),
          ),
        ),
      );
      expect(_rows(tester), 8);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: RowsSkeleton.rowHeight * 3.5,
                  child: RowsSkeleton(),
                ),
              ],
            ),
          ),
        ),
      );
      expect(_rows(tester), 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pulses, holds still with reduced motion and reads as one loading region',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RowsSkeleton())),
      );
      final start = _opacity(tester);
      await tester.pump(const Duration(milliseconds: 450));
      expect(_opacity(tester), lessThan(start));
      expect(find.bySemanticsLabel('正在載入'), findsOneWidget);
      semantics.dispose();

      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: RowsSkeleton()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1);
    },
  );

  testWidgets(
    'a first RecordsFeed load shows skeleton rows that the loaded rows replace',
    (tester) async {
      final page = Completer<ApiPage<Json>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecordsFeed(
              identity: 'issues',
              load: (_) => page.future,
              grouped: true,
              itemBuilder: (context, item) =>
                  SizedBox(height: 56, child: Text(item['title']! as String)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(RowsSkeleton), findsOneWidget);
      expect(
        tester.widget<RowsSkeleton>(find.byType(RowsSkeleton)).grouped,
        isTrue,
      );

      page.complete(
        ApiPage<Json>([
          {'id': 1, 'title': 'Issue 1'},
        ]),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(RowsSkeleton), findsNothing);
      expect(find.text('Issue 1'), findsOneWidget);
    },
  );
}
