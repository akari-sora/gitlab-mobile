import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/scroll_performance.dart';

void main() {
  const settleWindow = Duration(milliseconds: 500);
  const activeTimeout = Duration(seconds: 20);

  testWidgets('only the starting context and depth can end a sample', (
    tester,
  ) async {
    final capture = _PerformanceLogCapture();
    final harness = _ScrollHarness();
    addTearDown(harness.dispose);
    try {
      await tester.pumpWidget(harness.widget);

      final primary = harness.primary.currentContext!;
      _start(primary);

      _end(primary, dispatchFrom: harness.nested.currentContext!);
      _end(harness.unrelated.currentContext!);
      await tester.pump(const Duration(seconds: 2));
      expect(capture.messages, isEmpty);

      _end(primary);
      await tester.pump(settleWindow);

      expect(capture.messages, hasLength(1));
      expect(_summary(capture.messages.single)['sequence'], 1);
    } finally {
      capture.restore();
    }
  });

  testWidgets(
    'a duplicate matching end does not postpone or duplicate output',
    (tester) async {
      final capture = _PerformanceLogCapture();
      final harness = _ScrollHarness();
      addTearDown(harness.dispose);
      try {
        await tester.pumpWidget(harness.widget);

        final primary = harness.primary.currentContext!;
        _start(primary);
        _end(primary);
        await tester.pump(const Duration(milliseconds: 300));
        _end(primary);
        await tester.pump(const Duration(milliseconds: 200));

        expect(capture.messages, hasLength(1));
        await tester.pump(const Duration(seconds: 2));
        expect(capture.messages, hasLength(1));
      } finally {
        capture.restore();
      }
    },
  );

  testWidgets('active timeout emits one truncated sample after settling', (
    tester,
  ) async {
    final capture = _PerformanceLogCapture();
    final harness = _ScrollHarness();
    addTearDown(harness.dispose);
    try {
      await tester.pumpWidget(harness.widget);

      _start(harness.primary.currentContext!);
      await tester.pump(activeTimeout);
      expect(capture.messages, isEmpty);
      await tester.pump(settleWindow);

      expect(capture.messages, hasLength(1));
      expect(_summary(capture.messages.single)['truncated'], isTrue);
    } finally {
      capture.restore();
    }
  });

  testWidgets('dispose cancels active and settling samples', (tester) async {
    final capture = _PerformanceLogCapture();
    final harness = _ScrollHarness();
    addTearDown(harness.dispose);
    try {
      await tester.pumpWidget(harness.widget);

      final primary = harness.primary.currentContext!;
      _start(primary);
      _end(primary);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(activeTimeout + const Duration(seconds: 2));

      expect(capture.messages, isEmpty);
    } finally {
      capture.restore();
    }
  });

  testWidgets('disabled TickerMode ignores starts and matching ends', (
    tester,
  ) async {
    final capture = _PerformanceLogCapture();
    final harness = _ScrollHarness();
    addTearDown(harness.dispose);
    try {
      await tester.pumpWidget(harness.widget);

      harness.tickersEnabled.value = false;
      await tester.pump();
      final controlled = harness.controlled.currentContext!;
      _start(controlled);
      await tester.pump(activeTimeout + settleWindow);
      expect(capture.messages, isEmpty);

      harness.tickersEnabled.value = true;
      await tester.pump();
      _start(controlled);
      harness.tickersEnabled.value = false;
      await tester.pump();
      _end(controlled);
      await tester.pump(const Duration(seconds: 2));
      expect(capture.messages, isEmpty);

      harness.tickersEnabled.value = true;
      await tester.pump();
      _end(controlled);
      await tester.pump(settleWindow);
      expect(capture.messages, hasLength(1));
    } finally {
      capture.restore();
    }
  });

  testWidgets('a late matching timing batch extends the bounded settle', (
    tester,
  ) async {
    final capture = _PerformanceLogCapture();
    final harness = _ScrollHarness();
    addTearDown(harness.dispose);
    try {
      await tester.pumpWidget(harness.widget);

      final primary = harness.primary.currentContext!;
      _start(primary);
      final start =
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
      await tester.pump(const Duration(milliseconds: 10));
      final end =
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
      _end(primary);

      await tester.pump(const Duration(milliseconds: 400));
      tester.platformDispatcher.onReportTimings!.call([
        _frame(vsyncStart: start + ((end - start) ~/ 2)),
      ]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(capture.messages, isEmpty);
      await tester.pump(const Duration(milliseconds: 150));

      expect(capture.messages, hasLength(1));
      expect(_summary(capture.messages.single), {
        'label': 'profile',
        'sequence': 1,
        'frames': 1,
        'truncated': false,
        'missed60': 0,
        'missed120': 0,
        'latency60': 0,
        'max_total_us': 350,
        'p95_total_us': 350,
        'avg_total_us': 350,
        'max_build_us': 100,
        'max_raster_us': 100,
      });
    } finally {
      capture.restore();
    }
  });
}

class _ScrollHarness {
  final primary = GlobalKey();
  final unrelated = GlobalKey();
  final nested = GlobalKey();
  final controlled = GlobalKey();
  final tickersEnabled = ValueNotifier(true);

  Widget get widget => MaterialApp(
    home: ScrollPerformance(
      child: Column(
        children: [
          Builder(key: primary, builder: (_) => const SizedBox()),
          Builder(key: unrelated, builder: (_) => const SizedBox()),
          SizedBox(
            height: 80,
            child: ListView(
              children: [
                Builder(key: nested, builder: (_) => const SizedBox(height: 1)),
              ],
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: tickersEnabled,
            builder: (context, enabled, child) => TickerMode(
              enabled: enabled,
              child: Builder(key: controlled, builder: (_) => const SizedBox()),
            ),
          ),
        ],
      ),
    ),
  );

  void dispose() => tickersEnabled.dispose();
}

final _metrics = FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: 100,
  pixels: 10,
  viewportDimension: 50,
  axisDirection: AxisDirection.down,
  devicePixelRatio: 1,
);

void _start(BuildContext context) {
  ScrollStartNotification(
    metrics: _metrics,
    context: context,
    dragDetails: DragStartDetails(),
  ).dispatch(context);
}

void _end(BuildContext context, {BuildContext? dispatchFrom}) {
  ScrollEndNotification(
    metrics: _metrics,
    context: context,
  ).dispatch(dispatchFrom ?? context);
}

FrameTiming _frame({required int vsyncStart}) => FrameTiming(
  vsyncStart: vsyncStart,
  buildStart: vsyncStart + 100,
  buildFinish: vsyncStart + 200,
  rasterStart: vsyncStart + 250,
  rasterFinish: vsyncStart + 350,
  rasterFinishWallTime: vsyncStart + 350,
);

class _PerformanceLogCapture {
  _PerformanceLogCapture() : _previous = debugPrint {
    debugPrint = (message, {wrapWidth}) {
      if (message?.startsWith('[scroll_perf] ') ?? false) {
        messages.add(message!);
      }
    };
  }

  final DebugPrintCallback _previous;
  final messages = <String>[];

  void restore() => debugPrint = _previous;
}

Map<String, Object?> _summary(String line) =>
    jsonDecode(line.substring('[scroll_perf] '.length)) as Map<String, Object?>;
