import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

import 'linear_timing.dart';

void main() {
  const format = AnthropicMessagesFormat();
  const cachedCaps = AiCaps(
    tokenLimitField: AiTokenLimitField.maxTokens,
    toolChoice: true,
    promptCaching: true,
  );

  group('Anthropic request encoding', () {
    test('encodes prompt caching, tools, and tool choice without thinking', () {
      final segment = _segment()
        ..setTail(
          AppUserEntry(
            text: 'Explain the failure.',
            context: const <AiContextBlock>[
              AiContextBlock(
                source: 'job',
                text: '<gitlab_data>log</gitlab_data>',
              ),
              AiContextBlock(
                source: 'file',
                text: '<gitlab_data>code</gitlab_data>',
              ),
            ],
          ),
        );
      final body = format.encode(
        AiRequestPlan(
          model: 'claude-synthetic',
          system: 'Synthetic system prompt.',
          segment: segment,
          tools: <AiToolSpec>[
            AiToolSpec(
              name: 'read_file',
              description: 'Read a synthetic file.',
              parameters: <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{},
              },
            ),
          ],
          toolChoice: AiToolChoice.none,
        ),
        cachedCaps,
      );

      expect(body['max_tokens'], 4096);
      expect(body, isNot(contains('thinking')));
      expect(body['tool_choice'], <String, Object?>{'type': 'none'});
      final messages = body['messages']! as List<Object?>;
      final content =
          (messages.single! as Map<String, Object?>)['content']!
              as List<Object?>;
      expect(content, <Object?>[
        <String, Object?>{
          'type': 'text',
          'text': '<gitlab_data>log</gitlab_data>',
          'cache_control': <String, Object?>{'type': 'ephemeral'},
        },
        <String, Object?>{
          'type': 'text',
          'text': '<gitlab_data>code</gitlab_data>',
        },
        <String, Object?>{'type': 'text', 'text': 'Explain the failure.'},
      ]);
      expect(
        ((body['tools']! as List<Object?>).single!
            as Map<String, Object?>)['input_schema'],
        <String, Object?>{'type': 'object', 'properties': <String, Object?>{}},
      );
    });

    test('flatMaps tool results and follow-up into one user message', () {
      final results = AppToolResultsEntry(const <AiToolResult>[
        AiToolResult(
          callId: 'toolu_synthetic_a',
          name: 'read_file',
          content: 'first result',
        ),
        AiToolResult(
          callId: 'toolu_synthetic_b',
          name: 'search',
          content: 'second result',
          isError: true,
        ),
      ], followUpText: 'Now answer.');

      expect(format.encodeEntry(results, cachedCaps), <Object?>[
        <String, Object?>{
          'role': 'user',
          'content': <Object?>[
            <String, Object?>{
              'type': 'tool_result',
              'tool_use_id': 'toolu_synthetic_a',
              'content': 'first result',
            },
            <String, Object?>{
              'type': 'tool_result',
              'tool_use_id': 'toolu_synthetic_b',
              'content': 'second result',
              'is_error': true,
            },
            <String, Object?>{'type': 'text', 'text': 'Now answer.'},
          ],
        },
      ]);
    });

    test(
      'replays frozen prefix and prunes blocks before the last fallback',
      () {
        final segment = _segment()..setTail(AppUserEntry(text: 'Question'));
        final output = ProviderOutputEntry(
          AiFormat.anthropicMessages,
          <Object?>[
            <String, Object?>{
              'type': 'thinking',
              'thinking': 'old',
              'signature': 'sig_synthetic_old',
            },
            <String, Object?>{'type': 'text', 'text': 'kept before fallback'},
            <String, Object?>{
              'type': 'tool_use',
              'id': 'toolu_synthetic_old',
              'name': 'read_file',
              'input': <String, Object?>{},
            },
            <String, Object?>{
              'type': 'fallback',
              'text': 'synthetic fallback',
              'opaque_extension': <String, Object?>{'kept': true},
            },
            <String, Object?>{
              'type': 'thinking',
              'thinking': '',
              'signature': 'sig_synthetic_new',
            },
          ],
          toolCalls: <AiToolCall>[
            AiToolCall(
              id: 'toolu_synthetic_old',
              name: 'read_file',
              arguments: <String, Object?>{},
            ),
          ],
        );
        segment.freezeWith(
          output,
          (entry) => format.encodeEntry(entry, cachedCaps),
        );
        segment.setTail(AppUserEntry(text: 'Follow-up'));

        final plan = AiRequestPlan(
          model: 'claude-synthetic',
          system: 'Synthetic system prompt.',
          segment: segment,
        );
        final firstJson = format.encodeJson(plan, cachedCaps);
        final secondJson = format.encodeJson(plan, cachedCaps);
        expect(secondJson, firstJson);
        final body = jsonDecode(firstJson) as Map<String, Object?>;
        final messages = body['messages']! as List<Object?>;
        final assistant = messages[1]! as Map<String, Object?>;
        expect(assistant['content'], <Object?>[
          <String, Object?>{'type': 'text', 'text': 'kept before fallback'},
          <String, Object?>{
            'type': 'fallback',
            'text': 'synthetic fallback',
            'opaque_extension': <String, Object?>{'kept': true},
          },
          <String, Object?>{
            'type': 'thinking',
            'thinking': '',
            'signature': 'sig_synthetic_new',
          },
        ]);
        expect(
          firstJson,
          contains(segment.frozenWireJson.first.substring(1, 20)),
        );
      },
    );

    test('omits tools and tool choice together when catalogue is empty', () {
      final segment = _segment()..setTail(AppUserEntry(text: 'Question'));
      final body = format.encode(
        AiRequestPlan(
          model: 'claude-synthetic',
          system: 'Synthetic system prompt.',
          segment: segment,
        ),
        cachedCaps,
      );

      expect(body, isNot(contains('tools')));
      expect(body, isNot(contains('tool_choice')));
    });

    test('omits empty user and follow-up text blocks', () {
      final user = format.encodeEntry(
        AppUserEntry(
          text: '',
          context: const <AiContextBlock>[
            AiContextBlock(source: 'job', text: 'synthetic context'),
          ],
        ),
        cachedCaps,
      );
      expect(user, <Object?>[
        <String, Object?>{
          'role': 'user',
          'content': <Object?>[
            <String, Object?>{
              'type': 'text',
              'text': 'synthetic context',
              'cache_control': <String, Object?>{'type': 'ephemeral'},
            },
          ],
        },
      ]);

      final results = format.encodeEntry(
        AppToolResultsEntry(const <AiToolResult>[
          AiToolResult(
            callId: 'toolu_synthetic',
            name: 'read_file',
            content: 'synthetic result',
          ),
        ], followUpText: ''),
        cachedCaps,
      );
      final content =
          (results.single! as Map<String, Object?>)['content']!
              as List<Object?>;
      expect(content, hasLength(1));
      expect(
        content.single,
        isNot(<String, Object?>{'type': 'text', 'text': ''}),
      );
    });
  });

  group('Anthropic stream decoding', () {
    test(
      'preserves all blocks, signatures, tools, and latest usage fields',
      () {
        final decoder = format.newDecoder();
        final events = <AiEvent>[];
        void add(Map<String, Object?> value, {String event = 'message'}) {
          events.addAll(decoder.add(_event(value, event: event)));
        }

        add(<String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{
            'id': 'msg_synthetic',
            'usage': <String, Object?>{
              'input_tokens': 12,
              'cache_creation_input_tokens': 4,
              'cache_read_input_tokens': 2,
            },
          },
        });
        add(<String, Object?>{
          'type': 'content_block_start',
          'index': 0,
          'content_block': <String, Object?>{
            'type': 'thinking',
            'thinking': '',
            'signature': '',
            'display': 'omitted',
          },
        });
        add(<String, Object?>{
          'type': 'content_block_delta',
          'index': 0,
          'delta': <String, Object?>{'type': 'thinking_delta', 'thinking': ''},
        });
        add(<String, Object?>{
          'type': 'content_block_delta',
          'index': 0,
          'delta': <String, Object?>{
            'type': 'signature_delta',
            'signature': 'sig_synthetic_',
          },
        });
        add(<String, Object?>{
          'type': 'content_block_delta',
          'index': 0,
          'delta': <String, Object?>{
            'type': 'signature_delta',
            'signature': 'complete',
          },
        });
        add(<String, Object?>{'type': 'content_block_stop', 'index': 0});
        add(<String, Object?>{
          'type': 'content_block_start',
          'index': 1,
          'content_block': <String, Object?>{
            'type': 'redacted_thinking',
            'data': 'opaque_synthetic_redaction',
          },
        });
        add(<String, Object?>{'type': 'content_block_stop', 'index': 1});
        add(<String, Object?>{
          'type': 'content_block_start',
          'index': 2,
          'content_block': <String, Object?>{'type': 'text', 'text': ''},
        });
        add(<String, Object?>{
          'type': 'content_block_delta',
          'index': 2,
          'delta': <String, Object?>{'type': 'text_delta', 'text': 'Answer'},
        });
        add(<String, Object?>{'type': 'content_block_stop', 'index': 2});
        for (final call in <(int, String, String)>[
          (3, 'toolu_synthetic_a', 'read_file'),
          (4, 'toolu_synthetic_b', 'search'),
        ]) {
          add(<String, Object?>{
            'type': 'content_block_start',
            'index': call.$1,
            'content_block': <String, Object?>{
              'type': 'tool_use',
              'id': call.$2,
              'name': call.$3,
              'input': <String, Object?>{},
            },
          });
          add(<String, Object?>{
            'type': 'content_block_delta',
            'index': call.$1,
            'delta': <String, Object?>{
              'type': 'input_json_delta',
              'partial_json': '{"value":',
            },
          });
          add(<String, Object?>{
            'type': 'content_block_delta',
            'index': call.$1,
            'delta': <String, Object?>{
              'type': 'input_json_delta',
              'partial_json': '${call.$1}}',
            },
          });
          add(<String, Object?>{
            'type': 'content_block_stop',
            'index': call.$1,
          });
        }
        add(<String, Object?>{'type': 'ping'});
        add(<String, Object?>{
          'type': 'message_delta',
          'delta': <String, Object?>{
            'stop_reason': 'tool_use',
            'stop_sequence': null,
            'stop_details': <String, Object?>{'reason': 'synthetic'},
            'container': <String, Object?>{'id': 'container_synthetic'},
          },
          'usage': <String, Object?>{'output_tokens': 19},
        });
        add(<String, Object?>{'type': 'message_stop'});
        add(<String, Object?>{
          'type': 'content_block_delta',
          'index': 2,
          'delta': <String, Object?>{'type': 'text_delta', 'text': ' ignored'},
        });

        expect(events.whereType<AiStarted>(), hasLength(1));
        expect(events.whereType<AiReasoningActive>(), hasLength(3));
        expect(
          events.whereType<AiTextDelta>().map((event) => event.text),
          <String>['Answer'],
        );
        expect(events.whereType<AiFinished>(), hasLength(1));
        expect((decoder as AnthropicStreamDecoder).ignoredAfterTerminal, 1);
        final turn = decoder.finish();
        expect(turn.stop, AiStopReason.endTurn);
        expect(turn.usage?.inputTokens, 12);
        expect(turn.usage?.outputTokens, 19);
        expect(turn.usage?.cacheCreationInputTokens, 4);
        expect(turn.usage?.cacheReadInputTokens, 2);
        expect(turn.output.toolCalls, hasLength(2));
        expect(turn.output.toolCalls.first.arguments, <String, Object?>{
          'value': 3,
        });
        final blocks = turn.output.raw as List<Object?>;
        expect(blocks, hasLength(5));
        expect(
          (blocks[0]! as Map<String, Object?>)['signature'],
          'sig_synthetic_complete',
        );
        expect((blocks[0]! as Map<String, Object?>)['display'], 'omitted');
        expect(
          (blocks[1]! as Map<String, Object?>)['data'],
          'opaque_synthetic_redaction',
        );
      },
    );

    test('treats invalid or unfinished tool input as interrupted', () {
      final invalid = format.newDecoder();
      invalid.add(
        _event(<String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{'usage': <String, Object?>{}},
        }),
      );
      invalid.add(
        _event(<String, Object?>{
          'type': 'content_block_start',
          'index': 0,
          'content_block': <String, Object?>{
            'type': 'tool_use',
            'id': 'toolu_synthetic',
            'name': 'read_file',
            'input': <String, Object?>{},
          },
        }),
      );
      invalid.add(
        _event(<String, Object?>{
          'type': 'content_block_delta',
          'index': 0,
          'delta': <String, Object?>{
            'type': 'input_json_delta',
            'partial_json': '{',
          },
        }),
      );
      expect(
        () => invalid.add(
          _event(<String, Object?>{'type': 'content_block_stop', 'index': 0}),
        ),
        throwsA(_failure(AiFailureKind.interrupted)),
      );

      final unfinished = format.newDecoder();
      unfinished.add(
        _event(<String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{'usage': <String, Object?>{}},
        }),
      );
      unfinished.add(
        _event(<String, Object?>{
          'type': 'content_block_start',
          'index': 0,
          'content_block': <String, Object?>{
            'type': 'tool_use',
            'id': 'toolu_synthetic',
            'name': 'read_file',
            'input': <String, Object?>{},
          },
        }),
      );
      unfinished.add(
        _event(<String, Object?>{
          'type': 'message_delta',
          'delta': <String, Object?>{'stop_reason': 'max_tokens'},
          'usage': <String, Object?>{'output_tokens': 20},
        }),
      );
      expect(
        () => unfinished.add(_event(<String, Object?>{'type': 'message_stop'})),
        throwsA(_failure(AiFailureKind.interrupted)),
      );
      expect(unfinished.finish, throwsA(_failure(AiFailureKind.interrupted)));
    });

    test('never rewrites missing tool input or freezes unsigned thinking', () {
      final missingInput = format.newDecoder();
      missingInput.add(
        _event(<String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{'usage': <String, Object?>{}},
        }),
      );
      missingInput.add(
        _event(<String, Object?>{
          'type': 'content_block_start',
          'index': 0,
          'content_block': <String, Object?>{
            'type': 'tool_use',
            'id': 'toolu_synthetic',
            'name': 'read_file',
          },
        }),
      );
      expect(
        () => missingInput.add(
          _event(<String, Object?>{'type': 'content_block_stop', 'index': 0}),
        ),
        throwsA(_failure(AiFailureKind.interrupted)),
      );
      expect(missingInput.finish, throwsA(_failure(AiFailureKind.interrupted)));

      final unsigned = format.newDecoder();
      unsigned.add(
        _event(<String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{'usage': <String, Object?>{}},
        }),
      );
      unsigned.add(
        _event(<String, Object?>{
          'type': 'content_block_start',
          'index': 0,
          'content_block': <String, Object?>{
            'type': 'thinking',
            'thinking': '',
            'signature': '',
          },
        }),
      );
      unsigned.add(
        _event(<String, Object?>{'type': 'content_block_stop', 'index': 0}),
      );
      expect(
        () => unsigned.add(_event(<String, Object?>{'type': 'message_stop'})),
        throwsA(_failure(AiFailureKind.interrupted)),
      );
      expect(unsigned.finish, throwsA(_failure(AiFailureKind.interrupted)));
    });

    test('poisons invalid streams and rejects message_stop before start', () {
      final invalid = format.newDecoder();
      expect(
        () => invalid.add(
          _event(<String, Object?>{
            'type': 'content_block_delta',
            'index': 0,
            'delta': <String, Object?>{'type': 'text_delta', 'text': 'bad'},
          }),
        ),
        throwsA(_failure(AiFailureKind.invalidResponse)),
      );
      expect(
        invalid.add(
          _event(<String, Object?>{
            'type': 'message_start',
            'message': <String, Object?>{'usage': <String, Object?>{}},
          }),
        ),
        isEmpty,
      );
      expect(invalid.finish, throwsA(_failure(AiFailureKind.invalidResponse)));

      final idle = format.newDecoder();
      expect(
        () => idle.add(_event(<String, Object?>{'type': 'message_stop'})),
        throwsA(_failure(AiFailureKind.interrupted)),
      );
    });

    test('rejects all content and message deltas before message_start', () {
      for (final event in <Map<String, Object?>>[
        <String, Object?>{
          'type': 'content_block_start',
          'index': 0,
          'content_block': <String, Object?>{'type': 'text', 'text': ''},
        },
        <String, Object?>{
          'type': 'content_block_delta',
          'index': 0,
          'delta': <String, Object?>{'type': 'text_delta', 'text': 'bad'},
        },
        <String, Object?>{'type': 'content_block_stop', 'index': 0},
        <String, Object?>{
          'type': 'message_delta',
          'delta': <String, Object?>{'stop_reason': 'end_turn'},
        },
      ]) {
        final decoder = format.newDecoder();
        expect(
          () => decoder.add(_event(event)),
          throwsA(_failure(AiFailureKind.invalidResponse)),
        );
        expect(
          decoder.finish,
          throwsA(_failure(AiFailureKind.invalidResponse)),
        );
      }
    });

    test(
      'preserves an unknown block start across known and unknown deltas',
      () {
        final decoder = format.newDecoder();
        decoder.add(
          _event(<String, Object?>{
            'type': 'message_start',
            'message': <String, Object?>{'usage': <String, Object?>{}},
          }),
        );
        const raw = <String, Object?>{
          'type': 'future',
          'opaque': 'A',
          'nested': <String, Object?>{'kept': true},
        };
        decoder.add(
          _event(<String, Object?>{
            'type': 'content_block_start',
            'index': 0,
            'content_block': raw,
          }),
        );
        for (final delta in <Map<String, Object?>>[
          <String, Object?>{'type': 'future_delta', 'opaque': 'B', 'new': 1},
          <String, Object?>{'type': 'text_delta', 'text': 'ignored'},
        ]) {
          decoder.add(
            _event(<String, Object?>{
              'type': 'content_block_delta',
              'index': 0,
              'delta': delta,
            }),
          );
        }
        decoder.add(
          _event(<String, Object?>{'type': 'content_block_stop', 'index': 0}),
        );
        decoder.add(_event(<String, Object?>{'type': 'message_stop'}));

        final turn = decoder.finish();
        expect(turn.output.raw, <Object?>[raw]);
        expect(format.encodeEntry(turn.output, cachedCaps), <Object?>[
          <String, Object?>{
            'role': 'assistant',
            'content': <Object?>[raw],
          },
        ]);
      },
    );

    test('one-byte signature deltas grow linearly through 1 MiB', () {
      final delta = _event(<String, Object?>{
        'type': 'content_block_delta',
        'index': 0,
        'delta': <String, Object?>{'type': 'signature_delta', 'signature': 'x'},
      });
      Duration measure(int count) {
        final decoder = format.newDecoder();
        _startThinking(decoder);
        final watch = Stopwatch()..start();
        for (var index = 0; index < count; index++) {
          decoder.add(delta);
          checkDeltaBudget(watch, index);
        }
        _finishThinking(decoder);
        final raw = decoder.finish().output.raw as List<Object?>;
        watch.stop();
        expect(
          (raw.single! as Map<String, Object?>)['signature'],
          hasLength(count),
        );
        return watch.elapsed;
      }

      expectLinearGrowth('Anthropic signature', 512 * 1024, measure);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('does not execute tool calls discarded before the last fallback', () {
      final decoder = format.newDecoder();
      decoder.add(
        _event(<String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{'usage': <String, Object?>{}},
        }),
      );
      final blocks = <Map<String, Object?>>[
        <String, Object?>{
          'type': 'tool_use',
          'id': 'toolu_synthetic_old',
          'name': 'old_tool',
          'input': <String, Object?>{},
        },
        <String, Object?>{'type': 'fallback', 'text': 'synthetic fallback'},
        <String, Object?>{
          'type': 'tool_use',
          'id': 'toolu_synthetic_new',
          'name': 'new_tool',
          'input': <String, Object?>{},
        },
      ];
      for (var index = 0; index < blocks.length; index++) {
        decoder.add(
          _event(<String, Object?>{
            'type': 'content_block_start',
            'index': index,
            'content_block': blocks[index],
          }),
        );
        decoder.add(
          _event(<String, Object?>{
            'type': 'content_block_stop',
            'index': index,
          }),
        );
      }
      decoder.add(
        _event(<String, Object?>{
          'type': 'message_delta',
          'delta': <String, Object?>{'stop_reason': 'tool_use'},
          'usage': <String, Object?>{'output_tokens': 1},
        }),
      );
      decoder.add(_event(<String, Object?>{'type': 'message_stop'}));

      final turn = decoder.finish();
      expect(turn.output.raw, blocks);
      expect(turn.output.toolCalls, hasLength(1));
      expect(turn.output.toolCalls.single.id, 'toolu_synthetic_new');
      expect(
        (format.encodeEntry(turn.output, cachedCaps).single!
            as Map<String, Object?>)['content'],
        <Object?>[blocks[1], blocks[2]],
      );
    });

    test('requires a terminal event and accepts an empty final answer', () {
      final interrupted = format.newDecoder();
      interrupted.add(
        _event(<String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{'usage': <String, Object?>{}},
        }),
      );
      expect(interrupted.finish, throwsA(_failure(AiFailureKind.interrupted)));
      expect(
        interrupted.add(_event(<String, Object?>{'type': 'message_stop'})),
        isEmpty,
      );
      expect(interrupted.finish, throwsA(_failure(AiFailureKind.interrupted)));
      expect((interrupted as AnthropicStreamDecoder).ignoredAfterTerminal, 1);

      final empty = format.newDecoder();
      empty.add(
        _event(<String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{
            'usage': <String, Object?>{'input_tokens': 1},
          },
        }),
      );
      empty.add(
        _event(<String, Object?>{
          'type': 'message_delta',
          'delta': <String, Object?>{'stop_reason': 'end_turn'},
          'usage': <String, Object?>{'output_tokens': 0},
        }),
      );
      empty.add(_event(<String, Object?>{'type': 'message_stop'}));

      final turn = empty.finish();
      expect(turn.output.raw, isEmpty);
      expect(turn.output.toolCalls, isEmpty);
      expect(turn.usage?.outputTokens, 0);
    });
  });

  test('decodes Anthropic model pages with pagination metadata', () {
    final page = format.decodeModels(<String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': 'claude-synthetic',
          'display_name': 'Synthetic Claude',
        },
      ],
      'has_more': true,
      'last_id': 'claude-synthetic',
    });

    expect(page.models.single.id, 'claude-synthetic');
    expect(page.models.single.name, 'Synthetic Claude');
    expect(page.hasMore, isTrue);
  });
}

AiSegment _segment() => AiSegment(
  providerId: 'provider-synthetic',
  recipientRevision: 1,
  format: AiFormat.anthropicMessages,
  model: 'claude-synthetic',
  secretSetAtStart: SecretSetId.fromSecrets(const <String>[]),
);

SseEvent _event(Map<String, Object?> value, {String event = 'message'}) =>
    SseEvent(data: jsonEncode(value), event: event);

Matcher _failure(AiFailureKind kind) =>
    isA<AiFailure>().having((failure) => failure.kind, 'kind', kind);

void _startThinking(AiStreamDecoder decoder) {
  decoder.add(
    _event(<String, Object?>{
      'type': 'message_start',
      'message': <String, Object?>{'usage': <String, Object?>{}},
    }),
  );
  decoder.add(
    _event(<String, Object?>{
      'type': 'content_block_start',
      'index': 0,
      'content_block': <String, Object?>{
        'type': 'thinking',
        'thinking': '',
        'signature': '',
      },
    }),
  );
}

void _finishThinking(AiStreamDecoder decoder) {
  decoder.add(
    _event(<String, Object?>{'type': 'content_block_stop', 'index': 0}),
  );
  decoder.add(_event(<String, Object?>{'type': 'message_stop'}));
}
