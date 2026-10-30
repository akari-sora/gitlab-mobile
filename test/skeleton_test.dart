import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

int _rows(WidgetTester tester) =>
    find
        .descendant(
          of: find.byType(RowsSkeleton),
          matching: find.byType(FractionallySizedBox),
        )
        .evaluate()
        .length ~/
    2;

double _shimmerAnimationValue(WidgetTester tester, Finder root) {
  final builder = tester.widget<AnimatedBuilder>(
    find.descendant(of: root, matching: find.byType(AnimatedBuilder)).first,
  );
  return (builder.listenable as Animation<double>).value;
}

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
    'shimmers, holds still with reduced motion and reads as one loading region',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RowsSkeleton())),
      );
      expect(
        find.descendant(
          of: find.byType(RowsSkeleton),
          matching: find.byType(ShaderMask),
        ),
        findsOneWidget,
      );
      final semanticsWidget = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(SkeletonSemantics),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semanticsWidget.container, isTrue);

      final v0 = _shimmerAnimationValue(tester, find.byType(RowsSkeleton));
      expect(v0, 0.0);
      await tester.pump(const Duration(milliseconds: 450));
      final v1 = _shimmerAnimationValue(tester, find.byType(RowsSkeleton));
      expect(v1, greaterThan(v0));
      await tester.pump(const Duration(milliseconds: 450));
      final v2 = _shimmerAnimationValue(tester, find.byType(RowsSkeleton));
      expect(v2, greaterThan(v1));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
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
      expect(tester.binding.transientCallbackCount, 0);
      expect(
        find.descendant(
          of: find.byType(RowsSkeleton),
          matching: find.byType(ShaderMask),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'every skeleton clips without overflow in a 200dp body and short landscape screen',
    (tester) async {
      const skeletons = <Widget>[
        RowsSkeleton(),
        ListSkeleton(),
        MarkdownSkeleton(),
        CodeSkeleton(),
        DiffSkeleton(),
        LogSkeleton(),
        DetailSkeleton(),
        HomeSectionSkeleton(),
        PipelineSkeleton(),
        CompareSkeleton(),
        EditorSkeleton(),
        CommitSkeleton(),
        SnippetDetailSkeleton(),
        BoardColumnsSkeleton(),
        StageColumnsSkeleton(),
        ChartSkeleton(),
      ];
      for (final skeleton in skeletons) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [SizedBox(height: 200, child: skeleton)],
              ),
            ),
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '${skeleton.runtimeType} must not overflow a 200dp body',
        );
      }

      tester.view.physicalSize = const Size(915, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final skeleton in skeletons) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('x')),
              body: Column(children: [Expanded(child: skeleton)]),
            ),
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason:
              '${skeleton.runtimeType} must not overflow in a 300dp landscape screen',
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'toggling reduce motion while mounted stops and restarts the shimmer',
    (tester) async {
      final flag = ValueNotifier<bool>(false);
      addTearDown(flag.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: flag,
            builder: (context, disable, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: disable),
              child: const Scaffold(body: CodeSkeleton()),
            ),
          ),
        ),
      );
      final state0 = tester.state(find.byType(SkeletonShimmer));
      expect(tester.binding.transientCallbackCount, 1);
      expect(find.byType(ShaderMask), findsOneWidget);

      flag.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(identical(state0, tester.state(find.byType(SkeletonShimmer))), isTrue);
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(ShaderMask), findsNothing);

      flag.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(identical(state0, tester.state(find.byType(SkeletonShimmer))), isTrue);
      expect(tester.binding.transientCallbackCount, 1);
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(
        _shimmerAnimationValue(tester, find.byType(CodeSkeleton)),
        greaterThan(0),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'toggling TickerMode while mounted pauses and resumes the shimmer',
    (tester) async {
      final on = ValueNotifier<bool>(true);
      addTearDown(on.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: on,
            builder: (context, enabled, _) => TickerMode(
              enabled: enabled,
              child: const Scaffold(body: LogSkeleton()),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final pausedValue = _shimmerAnimationValue(
        tester,
        find.byType(LogSkeleton),
      );
      expect(pausedValue, greaterThan(0));
      expect(tester.binding.transientCallbackCount, 1);

      on.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(
        _shimmerAnimationValue(tester, find.byType(LogSkeleton)),
        equals(pausedValue),
      );

      on.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.transientCallbackCount, 1);
      expect(
        _shimmerAnimationValue(tester, find.byType(LogSkeleton)),
        isNot(equals(pausedValue)),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'ShimmerGradientTransform spans [-0.75, 0.75] and honors textDirection override',
    () {
      const bounds = Rect.fromLTWH(0, 0, 200, 40);
      const start = ShimmerGradientTransform(progress: 0.0);
      const mid = ShimmerGradientTransform(progress: 0.5);
      const end = ShimmerGradientTransform(progress: 1.0);
      expect(start.dx, closeTo(-0.75, 1e-6));
      expect(mid.dx, closeTo(0.0, 1e-6));
      expect(end.dx, closeTo(0.75, 1e-6));
      expect(
        start.transform(bounds)!.getTranslation().x,
        closeTo(-150.0, 1e-6),
      );
      expect(
        end.transform(bounds)!.getTranslation().x,
        closeTo(150.0, 1e-6),
      );
      expect(
        end
            .transform(bounds, textDirection: TextDirection.rtl)!
            .getTranslation()
            .x,
        closeTo(-150.0, 1e-6),
      );
      const rtlEnd = ShimmerGradientTransform(
        progress: 1.0,
        textDirection: TextDirection.rtl,
      );
      expect(rtlEnd.dx, closeTo(-0.75, 1e-6));
      expect(
        rtlEnd
            .transform(bounds, textDirection: TextDirection.ltr)!
            .getTranslation()
            .x,
        closeTo(150.0, 1e-6),
      );
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
