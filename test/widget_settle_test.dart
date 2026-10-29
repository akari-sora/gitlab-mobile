import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/widget_settle.dart';

const _step = Duration(milliseconds: 50);

/// Native work that finishes on the real event loop, like file I/O or an
/// encryption isolate on a loaded CI host.
Future<void> _slowNativeWork(Duration duration) =>
    Isolate.run(() => sleep(duration));

void main() {
  testWidgets('pumpUntil waits for native work past its cycle budget without '
      'advancing the widget clock further', (tester) async {
    var done = false;
    final work = _slowNativeWork(const Duration(seconds: 2));
    final tracked = work.whenComplete(() => done = true);
    final start = tester.binding.clock.now();
    await pumpUntil(tester, () => done, step: _step, maxCycles: 2);
    await tracked;
    expect(done, isTrue);
    // The cycle loop and its final pump are the whole widget-clock budget.
    expect(tester.binding.clock.now().difference(start), _step * 3);
  });

  testWidgets('pumpUntil still times out when the condition never holds', (
    tester,
  ) async {
    final start = tester.binding.clock.now();
    FlutterError? timedOut;
    try {
      await pumpUntil(
        tester,
        () => false,
        step: _step,
        maxCycles: 2,
        realGrace: const Duration(milliseconds: 200),
        description: 'never',
      );
    } on FlutterError catch (error) {
      timedOut = error;
    }
    expect(
      timedOut?.message,
      contains('pumpUntil timed out after 2 cycles: never'),
    );
    expect(tester.binding.clock.now().difference(start), _step * 3);
  });
}
