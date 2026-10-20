import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';

void main() {
  const fixture =
      '\ufeff:id ignored\r\n'
      'id: 42\r'
      'event: delta\n'
      'retry: 1500\r\n'
      'data: 第一行\n'
      'data: second\r\n'
      '\r\n'
      'data: done\n\n';

  test(
    'decodes bytewise, random, and multibyte-split chunks identically',
    () async {
      final bytes = utf8.encode(fixture);
      final random = Random(493);
      final randomChunks = <List<int>>[];
      for (var offset = 0; offset < bytes.length;) {
        final length = min(1 + random.nextInt(7), bytes.length - offset);
        randomChunks.add(bytes.sublist(offset, offset + length));
        offset += length;
      }
      final chunkings = <List<List<int>>>[
        [
          for (final byte in bytes) [byte],
        ],
        randomChunks,
        [bytes.sublist(0, 38), bytes.sublist(38, 39), bytes.sublist(39)],
      ];

      for (final chunks in chunkings) {
        final events = await const SseDecoder()
            .decode(Stream.fromIterable(chunks))
            .toList();
        expect(events, hasLength(2));
        expect(events.first.data, '第一行\nsecond');
        expect(events.first.event, 'delta');
        expect(events.first.id, '42');
        expect(events.first.retry, const Duration(milliseconds: 1500));
        expect(events.last.data, 'done');
        expect(events.last.event, 'message');
        expect(events.last.id, '42');
      }
    },
  );

  test('only strips a BOM at the start of the stream', () async {
    final events = await const SseDecoder()
        .decode(Stream.value(utf8.encode('\ufeffdata: a\n\ndata: \ufeffb\n\n')))
        .toList();

    expect(events.map((event) => event.data), ['a', '\ufeffb']);
  });

  test(
    'ignores comments and unknown fields and honors field parsing rules',
    () async {
      final events = await const SseDecoder()
          .decode(
            Stream.value(
              utf8.encode(
                ': ping\nunknown: value\ndata\ndata:  x\nid: bad\u0000id\n\n',
              ),
            ),
          )
          .toList();

      expect(events.single.data, '\n x');
      expect(events.single.id, isNull);
    },
  );

  test(
    'discards a pending event at EOF even when its final line ended',
    () async {
      for (final input in ['data: pending', 'data: pending\n']) {
        final events = await const SseDecoder()
            .decode(Stream.value(utf8.encode(input)))
            .toList();
        expect(events, isEmpty);
      }
    },
  );

  test('ignores an overflowing numeric retry field', () async {
    final events = await const SseDecoder()
        .decode(
          Stream.value(
            utf8.encode('retry: 999999999999999999999999999\ndata: ok\n\n'),
          ),
        )
        .toList();

    expect(events.single.data, 'ok');
    expect(events.single.retry, isNull);
  });

  test('resets event type across an empty dispatch with no data', () async {
    final events = await const SseDecoder()
        .decode(Stream.value(utf8.encode('event: delta\n\ndata: value\n\n')))
        .toList();

    expect(events.single.event, 'message');
  });

  test('dispatches an explicit empty data field with its event type', () async {
    final events = await const SseDecoder()
        .decode(Stream.value(utf8.encode('event: delta\ndata:\n\n')))
        .toList();

    expect(events.single.event, 'delta');
    expect(events.single.data, isEmpty);
  });

  test('cancelling the decoded stream cancels its byte source', () async {
    final listened = Completer<void>();
    final received = Completer<void>();
    final cancelled = Completer<void>();
    final controller = StreamController<List<int>>(
      onListen: listened.complete,
      onCancel: cancelled.complete,
    );
    final subscription = const SseDecoder()
        .decode(controller.stream)
        .listen((_) => received.complete());

    await listened.future;
    controller.add(utf8.encode('data: ready\n\n'));
    await received.future;
    final cancellation = subscription.cancel();

    await expectLater(cancelled.future, completes);
    unawaited(controller.close());
    await cancellation;
  });

  test('rejects an over-budget line', () async {
    final stream = const SseDecoder(
      maxLineBytes: 5,
    ).decode(Stream.value(utf8.encode('data: x\n\n')));

    await expectLater(
      stream.toList(),
      _failsWith(AiFailureKind.responseTooLarge),
    );
  });

  test('rejects cumulative event data over budget', () async {
    final stream = const SseDecoder(
      maxEventDataBytes: 4,
    ).decode(Stream.value(utf8.encode('data: ab\ndata: cd\n\n')));

    await expectLater(
      stream.toList(),
      _failsWith(AiFailureKind.responseTooLarge),
    );
  });

  test('rejects malformed UTF-8 as invalidResponse', () async {
    final stream = const SseDecoder().decode(
      Stream.fromIterable([
        [0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0xc3, 0x0a, 0x0a],
      ]),
    );

    await expectLater(
      stream.toList(),
      _failsWith(AiFailureKind.invalidResponse),
    );
  });

  test('maps an upstream stream failure to interrupted', () async {
    final controller = StreamController<List<int>>();
    final result = const SseDecoder().decode(controller.stream).toList();
    final expectation = expectLater(
      result,
      _failsWith(AiFailureKind.interrupted),
    );
    controller.add(utf8.encode('data: partial\n'));
    controller.addError(StateError('synthetic disconnect'));
    await controller.close();

    await expectation;
  });
}

Matcher _failsWith(AiFailureKind kind) =>
    throwsA(isA<AiFailure>().having((failure) => failure.kind, 'kind', kind));
