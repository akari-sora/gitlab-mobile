import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';

/// Bounded condition polling helper that interleaves fake clock advancement
/// with real asynchronous event loop turns, guaranteeing clean settlement
/// without unbounded hanging.
///
/// The widget clock advances by at most [maxCycles] + 1 steps. When that
/// budget is spent, native work (file I/O, isolates) can still be catching up
/// on a loaded host, so for up to [realGrace] of wall time the loop keeps
/// giving the real event loop turns and flushing the widget clock without
/// advancing it. A run that meets the condition within the cycles is
/// unchanged; only one that would have timed out gets that extra real time.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 50),
  Duration realDelay = const Duration(milliseconds: 15),
  int maxCycles = 100,
  Duration realGrace = const Duration(seconds: 10),
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
  const graceTurn = Duration(milliseconds: 10);
  final turn = realDelay > graceTurn ? realDelay : graceTurn;
  final grace = Stopwatch()..start();
  while (grace.elapsed < realGrace) {
    await tester.runAsync(() => Future<void>.delayed(turn));
    await tester.pump(Duration.zero);
    if (condition()) return;
  }
  throw FlutterError(
    'pumpUntil timed out after $maxCycles cycles: ${description ?? "condition was never met"}',
  );
}

/// Native I/O can finish on the real loop while its caller's continuation is
/// queued on the widget clock. Keep both moving until this work acknowledges.
///
/// [work] is one future, captured before pumping starts. In particular,
/// `session.readCache.quiesced` snapshots the current queue tail: work enqueued
/// by a rebuild during this wait can chain after that tail and is not covered.
/// Call after the final assertions and expected requests; this is not a drain
/// of all work that widgets might enqueue later.
Future<void> pumpUntilComplete(WidgetTester tester, Future<void> work) async {
  var completed = false;
  final tracked = work.whenComplete(() => completed = true);
  await pumpUntil(tester, () => completed,
      description: 'native work and its widget-clock continuations finish');
  await tracked;
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

