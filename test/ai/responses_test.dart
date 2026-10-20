import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

SseEvent event(String type, [Map<String, Object?> fields = const {}]) =>
    SseEvent(data: jsonEncode({'type': type, ...fields}));

void main() {
  test(
    'terminal output wins over done items, preserving all opaque fields',
    () {
      final decoder = ResponsesStreamDecoder();
      final events = <AiEvent>[];
      events.addAll(decoder.add(event('response.queued')));
      events.addAll(decoder.add(event('response.created')));
      events.addAll(decoder.add(event('response.created')));
      events.addAll(decoder.add(event('response.in_progress')));
      decoder.add(
        event('response.output_item.done', {
          'output_index': 0,
          'item': {'type': 'reasoning', 'encrypted_content': 'OLD'},
        }),
      );
      final output = [
        {
          'type': 'reasoning',
          'id': 'rs_synthetic',
          'summary': <Object?>[],
          'encrypted_content': 'SYNTHETIC_FINAL',
          'phase': 'analysis',
        },
        {
          'type': 'function_call',
          'id': 'fc_one',
          'call_id': 'call_one',
          'name': 'read_file',
          'arguments': '{"path":"lib/a.dart"}',
          'status': 'completed',
          'unknown': {'keep': true},
        },
      ];
      events.addAll(
        decoder.add(
          event('response.completed', {
            'response': {
              'output': output,
              'usage': {'input_tokens': 10, 'output_tokens': 20},
            },
          }),
        ),
      );
      expect(
        decoder.add(event('response.output_text.delta', {'delta': 'late'})),
        isEmpty,
      );
      final turn = decoder.finish();
      expect(turn.output.raw, output);
      expect(turn.hasToolCalls, isTrue);
      expect(turn.output.toolCalls.single.name, 'read_file');
      expect(turn.usage!.outputTokens, 20);
      expect(events.whereType<AiStarted>(), hasLength(1));
      expect(events.whereType<AiFinished>(), hasLength(1));
      expect(decoder.ignoredAfterTerminal, 1);
    },
  );

  test('arguments done without name waits for authoritative terminal item', () {
    final decoder = ResponsesStreamDecoder();
    decoder.add(
      event('response.output_item.added', {
        'output_index': 0,
        'item': {'type': 'function_call', 'name': 'read_file', 'id': 'fc_one'},
      }),
    );
    decoder.add(
      event('response.function_call_arguments.delta', {
        'output_index': 0,
        'item_id': 'fc_one',
        'delta': '{',
        'obfuscation': 'x',
      }),
    );
    decoder.add(
      event('response.function_call_arguments.done', {
        'output_index': 0,
        'item_id': 'fc_one',
        'arguments': '{}',
      }),
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

  test('refusal waits for completion and incomplete reasons stay distinct', () {
    final decoder = ResponsesStreamDecoder();
    expect(
      decoder
          .add(event('response.refusal.delta', {'delta': 'No'}))
          .whereType<AiFinished>(),
      isEmpty,
    );
    decoder.add(
      event('response.completed', {
        'response': {
          'output': <Object?>[
            {
              'type': 'message',
              'content': [
                {'type': 'refusal', 'refusal': 'No'},
              ],
            },
          ],
        },
      }),
    );
    expect(decoder.finish().stop, AiStopReason.refusal);
    for (final reason in [
      'max_output_tokens',
      'content_filter',
      'max_messages',
      'steered',
    ]) {
      final other = ResponsesStreamDecoder();
      other.add(
        event('response.incomplete', {
          'response': {
            'output': <Object?>[],
            'incomplete_details': {'reason': reason},
          },
        }),
      );
      expect(other.finish().stop, switch (reason) {
        'max_output_tokens' => AiStopReason.maxTokens,
        'content_filter' => AiStopReason.contentFilter,
        _ => AiStopReason.other,
      });
    }
  });

  test('partial tool arguments never become a replayable turn', () {
    final decoder = ResponsesStreamDecoder();
    expect(
      () => decoder.add(
        event('response.incomplete', {
          'response': {
            'incomplete_details': {'reason': 'max_output_tokens'},
            'output': [
              {
                'type': 'function_call',
                'call_id': 'call_one',
                'name': 'read_file',
                'arguments': '{"path":',
                'status': 'incomplete',
              },
            ],
          },
        }),
      ),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.kind,
          'kind',
          AiFailureKind.interrupted,
        ),
      ),
    );
    expect(decoder.finish, throwsA(isA<AiFailure>()));
  });

  test('missing or failed call status is never treated as completed', () {
    for (final status in [null, 'failed', 'unknown']) {
      final decoder = ResponsesStreamDecoder();
      expect(
        () => decoder.add(
          event('response.incomplete', {
            'response': {
              'output': [
                {
                  'type': 'function_call',
                  'call_id': 'call_one',
                  'name': 'read_file',
                  'arguments': '{}',
                  'status': ?status,
                },
              ],
            },
          }),
        ),
        throwsA(
          isA<AiFailure>().having(
            (e) => e.kind,
            'kind',
            AiFailureKind.interrupted,
          ),
        ),
      );
    }
  });

  test(
    'terminal refusal is authoritative and failed finish cannot recover',
    () {
      final decoder = ResponsesStreamDecoder();
      decoder.add(
        event('response.refusal.delta', {'delta': 'partial refusal'}),
      );
      decoder.add(
        event('response.completed', {
          'response': {'output': <Object?>[]},
        }),
      );
      expect(decoder.finish().stop, AiStopReason.endTurn);
      final interrupted = ResponsesStreamDecoder();
      expect(interrupted.finish, throwsA(isA<AiFailure>()));
      expect(
        interrupted.add(
          event('response.completed', {
            'response': {'output': <Object?>[]},
          }),
        ),
        isEmpty,
      );
      expect(
        interrupted.finish,
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

  test(
    'malformed usage is ancillary and streamed server errors map safely',
    () {
      final decoder = ResponsesStreamDecoder();
      expect(
        () => decoder.add(
          event('response.completed', {
            'response': {
              'output': <Object?>[],
              'usage': {'input_tokens': -1, 'output_tokens': 5},
            },
          }),
        ),
        returnsNormally,
      );
      final usage = decoder.finish().usage!;
      expect(usage.inputTokens, isNull);
      expect(usage.outputTokens, 5);
      final error = ResponsesStreamDecoder();
      expect(
        () => error.add(
          event('error', {
            'error': {'type': 'server_error'},
          }),
        ),
        throwsA(
          isA<AiFailure>().having((e) => e.kind, 'kind', AiFailureKind.server),
        ),
      );
    },
  );

  test('failed response and error events fail without saving a turn', () {
    for (final type in ['response.failed', 'error']) {
      final decoder = ResponsesStreamDecoder();
      expect(
        () => decoder.add(
          event(type, {
            'error': {'message': 'failure'},
          }),
        ),
        throwsA(isA<AiFailure>()),
      );
      expect(decoder.finish, throwsA(isA<AiFailure>()));
    }
  });

  test('request omits optional tools and uses safe reasoning defaults', () {
    const wire = ResponsesFormat();
    final segment = AiSegment(
      providerId: 'p',
      recipientRevision: 1,
      format: AiFormat.responses,
      model: 'model',
      secretSetAtStart: SecretSetId.fromSecrets([]),
    );
    segment.setTail(AppUserEntry(text: 'Hello'));
    final plan = AiRequestPlan(
      model: 'model',
      system: 'system',
      segment: segment,
    );
    final json = wire.encode(plan, AiPresets.openAi.capsFor(wire.format));
    expect(json['store'], false);
    expect(json['max_output_tokens'], greaterThanOrEqualTo(2048));
    expect(json.containsKey('previous_response_id'), false);
    expect(json.containsKey('tools'), false);
    expect(json.containsKey('tool_choice'), false);
    expect(json.containsKey('strict'), false);
    expect(json['include'], ['reasoning.encrypted_content']);
    expect(
      jsonDecode(wire.encodeJson(plan, AiPresets.openAi.capsFor(wire.format))),
      json,
    );
    expect(
      () => AiRequestPlan(
        model: 'model',
        system: '',
        segment: segment,
        maxOutputTokens: 512,
      ),
      throwsArgumentError,
    );
  });
}
