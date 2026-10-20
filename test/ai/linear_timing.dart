import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

// Bound slow mutations early, including during warmup, rather than waiting for
// a quadratic run to finish. Five seconds allows coverage and runner contention.
void checkDeltaBudget(Stopwatch watch, int index) {
  if (index % 1024 == 0 && watch.elapsed >= const Duration(seconds: 5)) {
    fail('Delta decoding exceeded the five-second ceiling');
  }
}

void expectLinearGrowth(
  String label,
  int count,
  Duration Function(int count) measure,
) {
  measure(count ~/ 8); // Warm JSON parsing and decoder paths before comparison.
  final small = <int>[];
  final large = <int>[];
  for (var trial = 0; trial < 3; trial++) {
    for (final size in [count, count * 2]) {
      final elapsed = measure(size);
      expect(elapsed, lessThan(const Duration(seconds: 5)));
      (size == count ? small : large).add(elapsed.inMicroseconds);
    }
  }
  // The fastest of interleaved samples limits scheduler/GC noise. A small fixed
  // allowance keeps sub-millisecond cases stable without hiding quadratic work.
  small.sort();
  large.sort();
  debugPrint('$label: N=$count ${small.first} us, 2N=${large.first} us');
  expect(large.first, lessThan(small.first * 3 + 20000), reason: label);
}
