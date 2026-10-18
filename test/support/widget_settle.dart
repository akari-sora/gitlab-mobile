import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';

/// Bounded condition polling helper that interleaves fake clock advancement
/// with real asynchronous event loop turns, guaranteeing clean settlement
/// without unbounded hanging.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 50),
  Duration realDelay = const Duration(milliseconds: 15),
  int maxCycles = 100,
  String? description,
}) async {
  for (var cycle = 0; cycle < maxCycles; cycle++) {
    if (condition()) return;
    await tester.pump(step);
    await tester.runAsync(() => Future<void>.delayed(realDelay));
  }
  if (condition()) return;
  await tester.pump(step);
  if (condition()) return;
  throw FlutterError(
    'pumpUntil timed out after $maxCycles cycles: ${description ?? "condition was never met"}',
  );
}

/// Dio response cancellation and chained requests can cross the test clock and
/// real event loop. Animation settling alone does not imply HTTP readiness.
/// Avoids pumpAndSettle hanging when indeterminate progress indicators are animating.
Future<void> settleNetworkWidgets(
  WidgetTester tester, {
  int maxCycles = 15,
  Duration step = const Duration(milliseconds: 50),
  Duration realDelay = const Duration(milliseconds: 15),
}) async {
  for (var cycle = 0; cycle < maxCycles; cycle++) {
    await tester.pump(step);
    await tester.runAsync(() => Future<void>.delayed(realDelay));
  }

  // An indeterminate progress indicator or a pulsing skeleton runs an infinite
  // repeating animation. pumpAndSettle() will ALWAYS timeout while one is in the tree.
  final hasIndeterminateSpinner = find.byWidgetPredicate((widget) {
    if (widget is CircularProgressIndicator && widget.value == null) return true;
    if (widget is LinearProgressIndicator && widget.value == null) return true;
    if (widget is RowsSkeleton) return true;
    return false;
  }).evaluate().isNotEmpty;

  if (!hasIndeterminateSpinner) {
    try {
      await tester.pumpAndSettle(
        step,
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
    } catch (_) {
      await tester.pump();
    }
  } else {
    // Settle a bounded number of frames for the spinner without hanging
    for (var i = 0; i < 5; i++) {
      await tester.pump(step);
    }
  }
}

