import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';

import 'linear_timing.dart';

SseEvent _chat(Map<String, Object?> delta, {String? finish}) => SseEvent(
  data: jsonEncode({
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': finish},
    ],
  }),
);
Matcher _failure(AiFailureKind kind) =>
    isA<AiFailure>().having((e) => e.kind, 'kind', kind);

void main() {
  test('FIX1 Chat cached usage decodes without double counting', () {
    final decoder = ChatStreamDecoder();
    decoder.add(
      SseEvent(
        data: jsonEncode({
          'choices': [
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
          'usage': {
            'prompt_tokens': 100,
            'completion_tokens': 5,
            'prompt_tokens_details': {'cached_tokens': 80},
          },
        }),
      ),
    );
    decoder.add(const SseEvent(data: '[DONE]'));
    final usage = decoder.finish().usage!;
    expect(usage.cacheReadInputTokens, 80);
    expect(usage.inputTokens, 20);
    expect(usage.totalTokens, 105);
    // FIX2 covers malformed ancillary counts: they stay unknown without
    // discarding completed output, while valid cache accounting stays disjoint.
  });

  test(
    'FIX1 DONE requires started stream and finish reason before finish()',
    () {
      for (final partial in [false, true]) {
        final decoder = ChatStreamDecoder();
        if (partial) decoder.add(_chat({'content': 'truncated'}));
        expect(
          () => decoder.add(const SseEvent(data: '[DONE]')),
          throwsA(_failure(AiFailureKind.interrupted)),
        );
        expect(decoder.finish, throwsA(_failure(AiFailureKind.interrupted)));
      }
    },
  );

  test(
    'FIX1 complete legacy calls consistently reject rather than disappear',
    () {
      for (final arguments in ['{}', '{']) {
        final decoder = ChatStreamDecoder();
        decoder.add(
          _chat({
            'function_call': {'name': 'read_file', 'arguments': arguments},
          }, finish: 'function_call'),
        );
        expect(
          () => decoder.add(const SseEvent(data: '[DONE]')),
          throwsA(_failure(AiFailureKind.interrupted)),
        );
      }
    },
  );

  for (final level in ['message', 'tool', 'function']) {
    test('FIX1 extras budget includes $level field names and nested JSON', () {
      for (final value in [
        0,
        {
          'nested': ['v'],
        },
      ]) {
        final extra = <String, Object?>{'x' * (1024 * 1024 + 1): value};
        final delta = switch (level) {
          'message' => extra,
          'tool' => <String, Object?>{
            'tool_calls': [
              {'index': 0, ...extra},
            ],
          },
          _ => <String, Object?>{
            'tool_calls': [
              {'index': 0, 'function': extra},
            ],
          },
        };
        expect(
          () => ChatStreamDecoder().add(_chat(delta)),
          throwsA(_failure(AiFailureKind.responseTooLarge)),
        );
      }
    });
  }

  test('FIX1 extras replacement releases size and counts all small fields', () {
    final decoder = ChatStreamDecoder();
    decoder.add(_chat({'opaque': 'x' * 700000}));
    decoder.add(_chat({'opaque': 'small'}));
    decoder.add(_chat({'other': 'y' * 700000}, finish: 'stop'));
    decoder.add(const SseEvent(data: '[DONE]'));
    expect((decoder.finish().output.raw as Map)['opaque'], 'small');
    final many = <String, Object?>{
      for (var i = 0; i < 10000; i++) '${'k' * 110}$i': 0,
    };
    expect(
      () => ChatStreamDecoder().add(_chat(many)),
      throwsA(_failure(AiFailureKind.responseTooLarge)),
    );
  });

  test('FIX1 escaped Unicode fragments count exact extras bytes', () {
    final decoder = ChatStreamDecoder();
    // {"reasoning":"..."} is 16 bytes before its value's payload.
    decoder.add(_chat({'reasoning': 'x' * (1024 * 1024 - 24)}));
    decoder.add(_chat({'reasoning': String.fromCharCode(0xd83d)}));
    // A split surrogate pair occupies four bytes, not twelve escaped bytes.
    decoder.add(_chat({'reasoning': String.fromCharCode(0xde00)}));
    decoder.add(_chat({'reasoning': 'xxxx'}, finish: 'stop'));
    decoder.add(const SseEvent(data: '[DONE]'));
    final raw = decoder.finish().output.raw as Map;
    expect(
      utf8.encode(jsonEncode({'reasoning': raw['reasoning']})).length,
      1024 * 1024,
    );
  });

  for (final field in [
    'content',
    'reasoning_content',
    'reasoning_details',
    'arguments',
  ]) {
    test('FIX1 timed tiny Chat $field deltas stay linear', () {
      Duration measure(int count) {
        final decoder = ChatStreamDecoder();
        const fragment = 'xxxxxxxx';
        if (field == 'arguments') {
          decoder.add(
            _chat({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'c',
                  'function': {'name': 'read_file', 'arguments': '{"x":"'},
                },
              ],
            }),
          );
        }
        final event = _chat(switch (field) {
          'reasoning_details' => {
            'reasoning_details': [
              {'type': 'reasoning.text', 'index': 0, 'text': fragment},
            ],
          },
          'arguments' => {
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': fragment},
              },
            ],
          },
          _ => {field: fragment},
        });
        final watch = Stopwatch()..start();
        for (var i = 0; i < count; i++) {
          decoder.add(event);
          checkDeltaBudget(watch, i);
        }
        if (field == 'arguments') {
          decoder.add(
            _chat({
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': '"}'},
                },
              ],
            }),
          );
        }
        decoder.add(_chat({}, finish: 'stop'));
        decoder.add(const SseEvent(data: '[DONE]'));
        final raw = decoder.finish().output.raw as Map;
        watch.stop();
        final text = switch (field) {
          'arguments' =>
            ((raw['tool_calls'] as List).single as Map)['function']['arguments']
                as String,
          'reasoning_details' =>
            (raw['reasoning_details'] as List).single['text'] as String,
          _ => raw[field] as String,
        };
        expect(
          text.length,
          count * fragment.length + (field == 'arguments' ? 8 : 0),
        );
        return watch.elapsed;
      }

      expectLinearGrowth('FIX1 Chat $field', 40000, measure);
    }, timeout: const Timeout(Duration(minutes: 1)));
  }

  test('FIX1 timed Responses argument deltas do not accumulate unused data', () {
    Duration measure(int count) {
      final decoder = ResponsesStreamDecoder();
      const event = SseEvent(
        data:
            '{"type":"response.function_call_arguments.delta","output_index":0,"delta":"xxxxxxxx"}',
      );
      final watch = Stopwatch()..start();
      for (var i = 0; i < count; i++) {
        decoder.add(event);
        checkDeltaBudget(watch, i);
      }
      decoder.add(
        const SseEvent(
          data: '{"type":"response.completed","response":{"output":[]}}',
        ),
      );
      expect(decoder.finish().output.toolCalls, isEmpty);
      watch.stop();
      return watch.elapsed;
    }

    expectLinearGrowth('FIX1 Responses arguments', 40000, measure);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'FIX1 malformed known Chat delta fields reject instead of disappear',
    () {
      for (final delta in <Map<String, Object?>>[
        {'content': 1},
        {'refusal': <Object?>[]},
        {'reasoning_content': <Object?>[]},
        {'reasoning': {}},
        {'tool_calls': 'bad'},
        {'reasoning_details': 'bad'},
        {'function_call': 'bad'},
      ]) {
        expect(
          () => ChatStreamDecoder().add(_chat(delta)),
          throwsA(_failure(AiFailureKind.invalidResponse)),
        );
      }
    },
  );
}
