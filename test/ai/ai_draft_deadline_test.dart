import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_draft_preview.dart';

void main() {
  test('work that finishes in time returns its result', () async {
    expect(
      await runWithDeadline(() => 6 * 7, const Duration(seconds: 10)),
      42,
    );
  });

  test('work that fails is reported, not returned', () async {
    await expectLater(
      runWithDeadline<int>(
        () => throw StateError('synthetic'),
        const Duration(seconds: 10),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('work still running at the deadline is stopped, not abandoned', () async {
    final beats = ReceivePort();
    final send = beats.sendPort;
    var count = 0;
    beats.listen((_) => count++);
    await expectLater(
      runWithDeadline<void>(() {
        while (true) {
          send.send(1);
          sleep(const Duration(milliseconds: 5));
        }
      }, const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
    // Let messages already in flight arrive, then expect no more.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final after = count;
    expect(after, greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(count, after, reason: 'the worker must not keep running');
    beats.close();
  });

  test('a draft too slow to check gives up at the deadline', () async {
    // One candidate already in code makes the batch check fail, and the long
    // unbroken run makes every one-by-one reparse slow: this takes far longer
    // than the deadline below. Run on the calling isolate it would also block
    // it until done.
    final text =
        '${List.generate(49, (i) => '@user$i').join(' ')} '
        '`@hidden` ${'x' * 12000}';
    final clock = Stopwatch()..start();
    await expectLater(
      analyzeAiDraft(text, '', timeout: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
