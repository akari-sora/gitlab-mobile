import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';

void main() {
  test('FIX2 Chat normalizes non-AiFailure errors and poisons the turn', () {
    final decoder = ChatStreamDecoder();
    // JSON accepts an overflowing numeric exponent; re-encoding its infinity
    // for the opaque-extras budget raises JsonUnsupportedObjectError.
    expect(
      () => decoder.add(
        const SseEvent(
          data: '{"choices":[{"index":0,"delta":{"opaque":1e999}}]}',
        ),
      ),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.kind,
          'kind',
          AiFailureKind.invalidResponse,
        ),
      ),
    );
    expect(
      decoder.finish,
      throwsA(
        isA<AiFailure>().having(
          (e) => e.kind,
          'kind',
          AiFailureKind.interrupted,
        ),
      ),
    );
  });
  for (final field in ['text', 'summary']) {
    for (final badFirst in [true, false]) {
      test(
        'FIX2 reasoning $field rejects wrong ${badFirst ? 'prior' : 'next'} type',
        () {
          final decoder = ChatStreamDecoder();
          SseEvent delta(Object value) => SseEvent(
            data: jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'delta': {
                    'reasoning_details': [
                      {'type': 'reasoning.$field', 'index': 0, field: value},
                    ],
                  },
                },
              ],
            }),
          );
          decoder.add(delta(badFirst ? 5 : 'x'));
          expect(
            () => decoder.add(delta(badFirst ? 'x' : 5)),
            throwsA(
              isA<AiFailure>().having(
                (e) => e.kind,
                'kind',
                AiFailureKind.invalidResponse,
              ),
            ),
          );
          expect(
            decoder.finish,
            throwsA(
              isA<AiFailure>().having(
                (e) => e.kind,
                'kind',
                AiFailureKind.interrupted,
              ),
            ),
          );
        },
      );
    }
  }

  for (final unusable in [
    <String, Object?>{'prompt_tokens': 'bad'},
    <String, Object?>{'completion_tokens': -1},
    <String, Object?>{},
  ]) {
    test('FIX2 Chat keeps earlier usage after unusable usage $unusable', () {
      final decoder = ChatStreamDecoder();
      final first = decoder.add(
        SseEvent(
          data: jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'kept'},
              },
            ],
            'usage': {'prompt_tokens': 100, 'completion_tokens': 5},
          }),
        ),
      );
      final second = decoder.add(
        SseEvent(
          data: jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': <String, Object?>{},
                'finish_reason': 'stop',
              },
            ],
            'usage': unusable,
          }),
        ),
      );
      decoder.add(const SseEvent(data: '[DONE]'));
      final turn = decoder.finish();
      expect(first.whereType<AiUsageUpdated>(), hasLength(1));
      expect(second.whereType<AiUsageUpdated>(), isEmpty);
      expect(turn.usage!.inputTokens, 100);
      expect(turn.usage!.outputTokens, 5);
      expect(turn.usage!.totalTokens, 105);
    });
  }

  for (final responses in [false, true]) {
    final format = responses ? 'Responses' : 'Chat';
    for (final cached in [80, 120, -1, 'bad', null]) {
      test('FIX2 $format preserves completed output with cached=$cached', () {
        final usage = {
          responses ? 'input_tokens' : 'prompt_tokens': 100,
          responses ? 'output_tokens' : 'completion_tokens': 5,
          responses ? 'input_tokens_details' : 'prompt_tokens_details': {
            'cached_tokens': cached,
          },
        };
        final decoder = responses
            ? ResponsesStreamDecoder()
            : ChatStreamDecoder();
        decoder.add(
          SseEvent(
            data: jsonEncode(
              responses
                  ? {
                      'type': 'response.completed',
                      'response': {
                        'output': [
                          {
                            'type': 'message',
                            'content': [
                              {'type': 'output_text', 'text': 'kept'},
                            ],
                          },
                        ],
                        'usage': usage,
                      },
                    }
                  : {
                      'choices': [
                        {
                          'index': 0,
                          'delta': {'content': 'kept'},
                          'finish_reason': 'stop',
                        },
                      ],
                      'usage': usage,
                    },
            ),
          ),
        );
        if (!responses) decoder.add(const SseEvent(data: '[DONE]'));
        final turn = decoder.finish();
        expect(jsonEncode(turn.output.raw), contains('kept'));
        final validSplit = cached == 80;
        expect(turn.usage!.inputTokens, validSplit ? 20 : 100);
        expect(turn.usage!.cacheReadInputTokens, validSplit ? 80 : null);
        expect(turn.usage!.outputTokens, 5);
        expect(turn.usage!.totalTokens, 105);
      });
    }
    for (final malformed in [
      'bad',
      <String, Object?>{
        responses ? 'input_tokens' : 'prompt_tokens': -1,
        responses ? 'output_tokens' : 'completion_tokens': 'bad',
        responses ? 'input_tokens_details' : 'prompt_tokens_details': {
          'cached_tokens': 80,
        },
      },
      <String, Object?>{
        responses ? 'input_tokens' : 'prompt_tokens': 100,
        responses ? 'output_tokens' : 'completion_tokens': 5,
        responses ? 'input_tokens_details' : 'prompt_tokens_details': 'bad',
      },
    ]) {
      test('FIX2 $format ignores malformed ancillary usage $malformed', () {
        final decoder = responses
            ? ResponsesStreamDecoder()
            : ChatStreamDecoder();
        decoder.add(
          SseEvent(
            data: jsonEncode(
              responses
                  ? {
                      'type': 'response.completed',
                      'response': {'output': <Object?>[], 'usage': malformed},
                    }
                  : {
                      'choices': [
                        {
                          'index': 0,
                          'delta': <String, Object?>{},
                          'finish_reason': 'stop',
                        },
                      ],
                      'usage': malformed,
                    },
            ),
          ),
        );
        if (!responses) decoder.add(const SseEvent(data: '[DONE]'));
        expect(decoder.finish, returnsNormally);
      });
    }
  }
}
