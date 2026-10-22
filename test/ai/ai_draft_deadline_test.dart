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

  test('work that fails reports its own error', () async {
    await expectLater(
      runWithDeadline<int>(
        () => throw StateError('synthetic failure'),
        const Duration(seconds: 10),
      ),
      throwsA(
        isA<RemoteError>().having(
          (error) => error.toString(),
          'error',
          contains('synthetic failure'),
        ),
      ),
    );
  });

  test('work still running at the deadline is stopped, not abandoned', () async {
    final beats = ReceivePort();
    addTearDown(beats.close);
    final send = beats.sendPort;
    var count = 0;
    beats.listen((_) => count++);
    await expectLater(
      runWithDeadline<void>(() {
        while (true) {
          send.send(1);
          sleep(const Duration(milliseconds: 5));
        }
      }, const Duration(seconds: 2)),
      throwsA(isA<TimeoutException>()),
    );
    // A killed worker goes quiet, whether or not it got to run before the
    // deadline; one left running sends every 5 ms, however late it starts,
    // and never does. Wait up to 10 s for half a second without a
    // heartbeat, so a busy machine delays the test instead of failing it.
    var last = -1;
    for (var tries = 0; tries < 20 && count != last; tries++) {
      last = count;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    expect(count, last, reason: 'the worker must stop sending');
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
