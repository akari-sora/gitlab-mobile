import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

const _format = ChatCompletionsFormat();
const _caps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
  streamUsage: true,
  toolChoice: true,
  replayChatExtras: true,
);

void main() {
  group('Chat Completions encoding', () {
    test('encodes system, tools, token cap, and flatMap tool results', () {
      final segment = _segment()
        ..setTail(
          AppToolResultsEntry([
            const AiToolResult(
              callId: 'call-a',
              name: 'read_file',
              content: 'first result',
            ),
            const AiToolResult(
              callId: 'call-b',
              name: 'read_file',
              content: 'second result',
              isError: true,
            ),
          ], followUpText: 'Compare them.'),
        );
      final body = _format.encode(
        AiRequestPlan(
          model: 'synthetic-model',
          system: '',
          segment: segment,
          tools: [
            AiToolSpec(
              name: 'read_file',
              description: 'Reads synthetic content.',
              parameters: <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'path': <String, Object?>{'type': 'string'},
                },
              },
            ),
          ],
          toolChoice: AiToolChoice.none,
        ),
        _caps,
      );

      expect(body['model'], 'synthetic-model');
      expect(body['max_tokens'], 4096);
      expect(body['stream'], isTrue);
      expect(body['stream_options'], {'include_usage': true});
      expect(body['tool_choice'], 'none');
      expect(body['messages'], [
        {'role': 'system', 'content': ''},
        {'role': 'tool', 'tool_call_id': 'call-a', 'content': 'first result'},
        {'role': 'tool', 'tool_call_id': 'call-b', 'content': 'second result'},
        {'role': 'user', 'content': 'Compare them.'},
      ]);
    });

    test('omits tools and tool choice together and selects token field', () {
      final caps = <AiTokenLimitField, String>{
        AiTokenLimitField.maxTokens: 'max_tokens',
        AiTokenLimitField.maxCompletionTokens: 'max_completion_tokens',
        AiTokenLimitField.maxOutputTokens: 'max_output_tokens',
      };

      for (final entry in caps.entries) {
        final segment = _segment()
          ..setTail(AppUserEntry(text: 'Hello', context: const []));
        final body = _format.encode(
          AiRequestPlan(
            model: 'synthetic-model',
            system: 'System',
            segment: segment,
          ),
          AiCaps(tokenLimitField: entry.key),
        );

        expect(body[entry.value], 4096);
        expect(body, isNot(contains('tools')));
        expect(body, isNot(contains('tool_choice')));
        expect(body, isNot(contains('stream_options')));
      }
    });

    test('rejects a segment bound to another wire format', () {
      final segment = AiSegment(
        providerId: 'synthetic-provider',
        recipientRevision: 1,
        format: AiFormat.responses,
        model: 'synthetic-model',
        secretSetAtStart: SecretSetId.fromSecrets(const []),
      )..setTail(AppUserEntry(text: 'Hello'));

      expect(
        () => _format.encode(
          AiRequestPlan(
            model: 'synthetic-model',
            system: 'System',
            segment: segment,
          ),
          _caps,
        ),
        throwsA(_failure(AiFailureKind.policyBlocked)),
      );
    });

    test('replays extras only when enabled', () {
      final output = ProviderOutputEntry(
        AiFormat.chatCompletions,
        <String, Object?>{
          'role': 'assistant',
          'content': '',
          'reasoning_content': 'private reasoning shape',
          'tool_calls': <Object?>[
            <String, Object?>{
              'id': 'call-a',
              'type': 'function',
              'function': <String, Object?>{
                'name': 'read_file',
                'arguments': '{}',
                'provider_function_extra': 'drop-me',
              },
              'extra_content': <String, Object?>{
                'provider_signature': 'drop-me',
              },
            },
          ],
        },
        toolCalls: const [],
      );

      expect(
        _format.encodeEntry(output, _caps).single,
        containsPair('reasoning_content', 'private reasoning shape'),
      );
      final withoutExtras =
          _format
                  .encodeEntry(
                    output,
                    const AiCaps(tokenLimitField: AiTokenLimitField.maxTokens),
                  )
                  .single
              as Map<String, Object?>;
      expect(withoutExtras, isNot(contains('reasoning_content')));
      final tool =
          (withoutExtras['tool_calls'] as List<Object?>).single
              as Map<String, Object?>;
      expect(tool, isNot(contains('extra_content')));
      expect(tool['function'], {'name': 'read_file', 'arguments': '{}'});
    });

    test('cached frozen prefix remains byte-identical', () {
      final segment = _segment()..setTail(AppUserEntry(text: 'First'));
      final output = ProviderOutputEntry(
        AiFormat.chatCompletions,
        <String, Object?>{
          'role': 'assistant',
          'content': null,
          'reasoning_content': 'opaque fragment',
          'tool_calls': <Object?>[
            <String, Object?>{
              'id': 'call-a',
              'type': 'function',
              'function': <String, Object?>{
                'name': 'read_file',
                'arguments': '{"path":"a.dart"}',
              },
            },
          ],
        },
        toolCalls: [
          AiToolCall(
            id: 'call-a',
            name: 'read_file',
            arguments: <String, Object?>{'path': 'a.dart'},
          ),
        ],
      );
      segment.freezeWith(output, (entry) => _format.encodeEntry(entry, _caps));
      final frozen = List<String>.of(segment.frozenWireJson);
      segment.setTail(
        AppToolResultsEntry([
          const AiToolResult(
            callId: 'call-a',
            name: 'read_file',
            content: 'result',
          ),
        ]),
      );

      final encoded = _format.encodeJson(
        AiRequestPlan(
          model: 'synthetic-model',
          system: 'System',
          segment: segment,
        ),
        _caps,
      );

      expect(segment.frozenWireJson, frozen);
      for (final fragment in frozen) {
        expect(encoded, contains(fragment.substring(1, fragment.length - 1)));
      }
    });
  });

  group('Chat Completions streaming', () {
    test('merges known extensions without corrupting opaque fields', () {
      final decoder = _format.newDecoder();
      final events = <AiEvent>[
        ...decoder.add(
          _event({
            'choices': [
              {
                'index': 0,
                'finish_reason': null,
                'delta': {
                  'role': 'assistant',
                  'content': 'Answer ',
                  'reasoning_content': 'Think ',
                  'reasoning_details': [
                    {
                      'type': 'reasoning.text',
                      'index': 0,
                      'id': 'reason-1',
                      'format': 'synthetic',
                      'text': 'alpha ',
                      'summary': 'replace-me',
                    },
                  ],
                  'custom_scalar': 'first',
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call-1',
                      'type': 'function',
                      'function': {
                        'name': 'read_file',
                        'arguments': '{"path":',
                      },
                      'extra_content': {
                        'google': {'thought_signature': 'synthetic-a'},
                      },
                    },
                  ],
                },
              },
            ],
            'usage': null,
          }),
        ),
        ...decoder.add(
          _event({
            'choices': [
              {
                'index': 0,
                'finish_reason': null,
                'delta': {
                  'content': 'complete.',
                  'reasoning_content': 'again',
                  'reasoning_details': [
                    {
                      'type': 'reasoning.text',
                      'index': 0,
                      'id': 'repeated-id-must-not-concatenate',
                      'format': 'repeated-format',
                      'text': 'beta',
                      'summary': 'replacement',
                    },
                    {
                      'type': 'reasoning.encrypted',
                      'index': 1,
                      'data': 'synthetic-opaque-value',
                    },
                  ],
                  'custom_scalar': 'last',
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'repeated-call-id',
                      'type': 'repeated-type',
                      'function': {
                        'name': 'repeated-name',
                        'arguments': '"a.dart"}',
                      },
                      'extra_content': {
                        'google': {'thought_signature': 'synthetic-b'},
                      },
                    },
                  ],
                },
              },
            ],
            'usage': null,
          }),
        ),
        ...decoder.add(
          _event({
            'choices': [
              <String, Object?>{
                'index': 0,
                'finish_reason': 'stop',
                'delta': <String, Object?>{},
              },
            ],
            'usage': null,
          }),
        ),
        ...decoder.add(
          _event({
            'choices': <Object?>[],
            'usage': {
              'prompt_tokens': 12,
              'completion_tokens': 7,
              'total_tokens': 19,
            },
          }),
        ),
        ...decoder.add(const SseEvent(data: '[DONE]')),
      ];

      expect(events.whereType<AiStarted>(), hasLength(1));
      expect(events.whereType<AiTextDelta>().map((event) => event.text), [
        'Answer ',
        'complete.',
      ]);
      expect(events.whereType<AiReasoningActive>(), hasLength(2));
      expect(events.whereType<AiFinished>(), hasLength(1));
      final turn = decoder.finish();
      expect(turn.stop, AiStopReason.endTurn);
      expect(turn.usage?.inputTokens, 12);
      expect(turn.usage?.outputTokens, 7);
      expect(turn.hasToolCalls, isTrue);
      expect(turn.output.toolCalls.single.id, 'call-1');
      expect(turn.output.toolCalls.single.name, 'read_file');
      expect(turn.output.toolCalls.single.arguments, {'path': 'a.dart'});

      final raw = turn.output.raw as Map<String, Object?>;
      expect(raw['content'], 'Answer complete.');
      expect(raw['reasoning_content'], 'Think again');
      expect(raw['custom_scalar'], 'last');
      final details = raw['reasoning_details'] as List<Object?>;
      expect(details, hasLength(2));
      expect(details.first, {
        'type': 'reasoning.text',
        'index': 0,
        'id': 'reason-1',
        'format': 'synthetic',
        'text': 'alpha beta',
        'summary': 'replacement',
      });
      expect(details.last, {
        'type': 'reasoning.encrypted',
        'index': 1,
        'data': 'synthetic-opaque-value',
      });
      final tool =
          (raw['tool_calls'] as List<Object?>).single as Map<String, Object?>;
      expect(tool['id'], 'call-1');
      expect(tool['type'], 'function');
      expect(tool['extra_content'], {
        'google': {'thought_signature': 'synthetic-b'},
      });
    });

    test(
      'complete tool calls drive continuation despite stop finish reason',
      () {
        final decoder = _format.newDecoder();
        decoder.add(
          _event({
            'choices': [
              {
                'index': 0,
                'finish_reason': 'stop',
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call-1',
                      'type': 'function',
                      'function': {'name': 'read_file', 'arguments': '{}'},
                    },
                  ],
                },
              },
            ],
            'usage': null,
          }),
        );
        decoder.add(const SseEvent(data: '[DONE]'));

        expect(decoder.finish().hasToolCalls, isTrue);
      },
    );

    test('accepts EOF after finish reason for compatible providers', () {
      final decoder = _format.newDecoder();
      final events = decoder.add(
        _event({
          'choices': [
            {
              'index': 0,
              'finish_reason': 'length',
              'delta': {'reasoning_content': 'partial reasoning'},
            },
          ],
          'usage': null,
        }),
      );

      expect(events.whereType<AiFinished>(), isEmpty);
      expect(decoder.finish().stop, AiStopReason.maxTokens);
    });

    test('rejects EOF without a terminal signal or finish reason', () {
      final decoder = _format.newDecoder();
      decoder.add(
        _event({
          'choices': [
            {
              'index': 0,
              'finish_reason': null,
              'delta': {'content': 'partial'},
            },
          ],
          'usage': null,
        }),
      );

      expect(decoder.finish, throwsA(_failure(AiFailureKind.interrupted)));
      expect(
        () => decoder.add(const SseEvent(data: '[DONE]')),
        throwsA(_failure(AiFailureKind.interrupted)),
      );
    });

    test('rejects complete stream containing partial tool arguments', () {
      final decoder = _format.newDecoder();
      decoder.add(
        _event({
          'choices': [
            {
              'index': 0,
              'finish_reason': 'length',
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call-1',
                    'type': 'function',
                    'function': {'name': 'read_file', 'arguments': '{"path":'},
                  },
                ],
              },
            },
          ],
          'usage': null,
        }),
      );

      expect(
        () => decoder.add(const SseEvent(data: '[DONE]')),
        throwsA(_failure(AiFailureKind.interrupted)),
      );
      expect(decoder.finish, throwsA(_failure(AiFailureKind.interrupted)));
    });

    test('rejects malformed legacy function arguments', () {
      final decoder = _format.newDecoder();
      decoder.add(
        _event({
          'choices': [
            {
              'index': 0,
              'finish_reason': 'stop',
              'delta': {
                'function_call': {'name': 'read_file', 'arguments': '{"path":'},
              },
            },
          ],
          'usage': null,
        }),
      );

      expect(
        () => decoder.add(const SseEvent(data: '[DONE]')),
        throwsA(_failure(AiFailureKind.interrupted)),
      );
    });

    test('rejects oversized extras immediately and poisons the decoder', () {
      final decoder = _format.newDecoder();

      expect(
        () => decoder.add(
          _event({
            'choices': [
              {
                'index': 0,
                'finish_reason': null,
                'delta': {'provider_extra': 'x' * (1024 * 1024 + 1)},
              },
            ],
            'usage': null,
          }),
        ),
        throwsA(_failure(AiFailureKind.responseTooLarge)),
      );
      expect(decoder.finish, throwsA(_failure(AiFailureKind.interrupted)));
    });

    test('maps OpenRouter error finish reason to failure', () {
      final decoder = _format.newDecoder();

      expect(
        () => decoder.add(
          _event({
            'choices': [
              {
                'index': 0,
                'finish_reason': 'error',
                'delta': <String, Object?>{},
              },
            ],
            'usage': null,
          }),
        ),
        throwsA(_failure(AiFailureKind.server)),
      );
    });

    test('emits refusal deltas and ignores data after terminal', () {
      final decoder = ChatStreamDecoder();
      final refusal = decoder.add(
        _event({
          'choices': [
            {
              'index': 0,
              'finish_reason': 'content_filter',
              'delta': {'refusal': 'Cannot comply.'},
            },
          ],
          'usage': null,
        }),
      );
      decoder.add(const SseEvent(data: '[DONE]'));

      expect(refusal.whereType<AiRefusalDelta>().single.text, 'Cannot comply.');
      expect(decoder.finish().stop, AiStopReason.contentFilter);
      expect(
        decoder.add(
          _event({
            'choices': [
              {
                'index': 0,
                'finish_reason': null,
                'delta': {'content': 'ignored'},
              },
            ],
            'usage': null,
          }),
        ),
        isEmpty,
      );
      expect(decoder.ignoredAfterTerminal, 1);
    });
  });
}

AiSegment _segment() => AiSegment(
  providerId: 'synthetic-provider',
  recipientRevision: 1,
  format: AiFormat.chatCompletions,
  model: 'synthetic-model',
  secretSetAtStart: SecretSetId.fromSecrets(const []),
);

SseEvent _event(Map<String, Object?> value) =>
    SseEvent(data: jsonEncode(value));

Matcher _failure(AiFailureKind kind) =>
    isA<AiFailure>().having((failure) => failure.kind, 'kind', kind);
