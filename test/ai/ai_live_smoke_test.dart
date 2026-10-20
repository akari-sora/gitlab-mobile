import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';

import '../../tool/ai_live_smoke.dart' as smoke;
import '../support/fake_adapter.dart';

void main() {
  test(
    'AI live smoke output guard rejects exact credentials and key prefixes',
    () {
      const credential = 'synthetic-exact-credential';
      expect(
        smoke.aiLiveUnsafeOutputReason('before $credential after', credential),
        'exact-credential',
      );
      for (final prefix in <String>[
        'sk'
            '-ant-',
        'oc'
            '_sk_',
      ]) {
        expect(
          smoke.aiLiveUnsafeOutputReason(
            'before ${prefix}synthetic',
            credential,
          ),
          'credential-prefix',
        );
      }
      expect(
        smoke.aiLiveUnsafeOutputReason('synthetic safe evidence', credential),
        isNull,
      );
    },
  );

  test('outgoing replay check requires an ordered byte-identical prefix', () {
    const first = '[{"turn":1}]';
    const second = '[{"turn":2}]';
    expect(
      smoke.aiLiveWirePrefixIsOrdered(
        '{"input":[{"turn":1},{"turn":2},{"tail":true}]}',
        const [first, second],
        format: AiFormat.responses,
      ),
      isTrue,
    );
    expect(
      smoke.aiLiveWirePrefixIsOrdered(
        '{"input":[{"turn":2},{"turn":1},{"tail":true}]}',
        const [first, second],
        format: AiFormat.responses,
      ),
      isFalse,
    );
    expect(
      smoke.aiLiveWirePrefixIsOrdered(
        '{"input":[{"other":true},{"turn":1},{"turn":2}]}',
        const [first, second],
        format: AiFormat.responses,
      ),
      isFalse,
    );
    expect(
      smoke.aiLiveWirePrefixIsOrdered(
        '{"input":[ {"turn":1},{"turn":2}]}',
        const [first, second],
        format: AiFormat.responses,
      ),
      isFalse,
      reason: 'wire evidence must remain byte-identical',
    );
  });

  test('text smoke rejects exact text when the turn hit max tokens', () async {
    final adapter = FakeAdapter(
      (_) => _responses(
        _messageOutput('SYNTHETIC_OK'),
        incomplete: true,
        streamedText: 'SYNTHETIC_OK',
      ),
    );

    final result = await smoke.aiLiveTextScenarioForTest(
      targetId: 'opencode-responses',
      adapter: adapter,
    );

    expect(result['status'], 'FAIL');
    final evidence = result['evidence']! as Map<String, Object?>;
    expect(evidence['stop'], 'maxTokens');
    expect(evidence['answerCompleted'], isFalse);
    expect(evidence['hasUsage'], isTrue);
  });

  test(
    'text smoke rejects an exact answer accompanied by tool calls',
    () async {
      final adapter = FakeAdapter(
        (_) => _responses(<Map<String, Object?>>[
          ..._messageOutput('SYNTHETIC_OK'),
          _toolOnlyOutput.first,
        ]),
      );

      final result = await smoke.aiLiveTextScenarioForTest(
        targetId: 'opencode-responses',
        adapter: adapter,
      );

      expect(result['status'], 'FAIL');
      final evidence = result['evidence']! as Map<String, Object?>;
      expect(evidence['answerCompleted'], isFalse);
    },
  );

  test('text smoke accepts exact completed raw output with usage', () async {
    final adapter = FakeAdapter(
      (_) => _responses(_messageOutput('SYNTHETIC_OK')),
    );

    final result = await smoke.aiLiveTextScenarioForTest(
      targetId: 'opencode-responses',
      adapter: adapter,
    );

    expect(result['status'], 'PASS');
    final evidence = result['evidence']! as Map<String, Object?>;
    expect(
      evidence['textChars'],
      0,
      reason: 'terminal raw output is authoritative',
    );
    expect(evidence['answerCompleted'], isTrue);
    expect(evidence['hasUsage'], isTrue);
  });

  test('tool-only responses cannot report a completed follow-up', () async {
    final adapter = FakeAdapter((_) => _responses(_toolOnlyOutput));

    final result = await smoke.aiLiveToolReplayScenarioForTest(
      targetId: 'opencode-responses',
      adapter: adapter,
    );

    expect(adapter.requests, hasLength(3));
    expect(result['status'], 'FAIL');
    final evidence = result['evidence']! as Map<String, Object?>;
    expect(evidence['followUpCompleted'], isFalse);
    expect(
      (evidence['reasoningReplay']! as Map<String, Object?>)['status'],
      'NOT_RUN',
    );
  });

  test('required reasoning without material is NOT_RUN, never PASS', () async {
    var request = 0;
    final adapter = FakeAdapter((_) {
      request++;
      return _responses(
        request == 1
            ? _toolOnlyOutput
            : _messageOutput(
                request == 2 ? 'synthetic values' : 'SYNTHETIC_FOLLOW_UP',
              ),
      );
    });

    final result = await smoke.aiLiveToolReplayScenarioForTest(
      targetId: 'opencode-responses',
      adapter: adapter,
    );

    expect(result['status'], 'NOT_RUN');
    final evidence = result['evidence']! as Map<String, Object?>;
    expect(evidence['followUpCompleted'], isTrue);
    expect(
      (evidence['reasoningReplay']! as Map<String, Object?>)['status'],
      'NOT_RUN',
    );
  });

  test(
    'encrypted reasoning and completed answers pass ordered replay',
    () async {
      var request = 0;
      final adapter = FakeAdapter((_) {
        request++;
        return _responses(switch (request) {
          1 => <Map<String, Object?>>[
            <String, Object?>{
              'type': 'reasoning',
              'id': 'reasoning-synthetic',
              'summary': const <Object?>[],
              'encrypted_content': 'synthetic-encrypted-reasoning',
            },
            ..._toolOnlyOutput,
          ],
          2 => _messageOutput('synthetic values'),
          _ => _messageOutput('SYNTHETIC_FOLLOW_UP'),
        });
      });

      final result = await smoke.aiLiveToolReplayScenarioForTest(
        targetId: 'opencode-responses',
        adapter: adapter,
      );

      expect(result['status'], 'PASS');
      final evidence = result['evidence']! as Map<String, Object?>;
      expect(evidence['followUpCompleted'], isTrue);
      expect(evidence['outgoingPrefixOrdered'], isTrue);
      expect(
        (evidence['reasoningReplay']! as Map<String, Object?>)['status'],
        'PASS',
      );
    },
  );

  test('stream cancellation starts on reasoning or visible text', () {
    expect(smoke.aiLiveCancellationTrigger(const AiReasoningActive()), isTrue);
    expect(smoke.aiLiveCancellationTrigger(const AiTextDelta('x')), isTrue);
    expect(smoke.aiLiveCancellationTrigger(const AiStarted()), isFalse);
  });

  test(
    'bounded runner smoke executes a tool and preserves the segment',
    () async {
      var request = 0;
      final adapter = FakeAdapter((_) {
        request++;
        return _responses(switch (request) {
          1 => _toolOutput(request),
          2 => _messageOutput('synthetic runner summary'),
          _ => _messageOutput('SYNTHETIC_RUNNER_FOLLOW_UP'),
        });
      });

      final result = await smoke.aiLiveRunnerLoopScenarioForTest(
        targetId: 'opencode-responses',
        adapter: adapter,
      );

      expect(result['status'], 'PASS');
      final evidence = result['evidence']! as Map<String, Object?>;
      expect(evidence['firstModelCalls'], 2);
      expect(evidence['firstToolCalls'], 1);
      expect(evidence['sameSegment'], isTrue);
      expect(evidence['lateRedactions'], 0);
      expect(adapter.requests, hasLength(3));
    },
  );

  test('bounded runner smoke reaches the real closing-call path', () async {
    var request = 0;
    final adapter = FakeAdapter((_) {
      request++;
      return _responses(_toolOutput(request));
    });

    final result = await smoke.aiLiveRunnerClosingScenarioForTest(
      targetId: 'opencode-responses',
      adapter: adapter,
    );

    expect(result['status'], 'PASS');
    final evidence = result['evidence']! as Map<String, Object?>;
    expect(evidence['end'], 'toolBudget');
    expect(evidence['modelCalls'], 6);
    expect(evidence['syntheticTailCompleted'], isTrue);
    expect(evidence['toolsKeptOnClosingRequest'], isTrue);
    expect(evidence['finishingChoiceOrNote'], isTrue);
    expect(adapter.requests, hasLength(6));
    expect(adapter.requests.last.data, contains('"tool_choice":"none"'));
  });

  test('closing verdict requires top-level tools and the finishing choice', () {
    const caps = AiCaps(
      tokenLimitField: AiTokenLimitField.maxOutputTokens,
      toolChoice: true,
    );
    final evidence = smoke.aiLiveAssessClosingRequestBodies(<String>[
      '{"tools":[{"name":"synthetic_lookup"}],"input":[]}',
      '{"input":[{"type":"function_call","name":"synthetic_lookup"}],"tool_choice":"none"}',
    ], caps: caps);

    expect(evidence['toolsKeptOnClosingRequest'], isFalse);
    expect(evidence['finishingChoiceOrNote'], isTrue);

    final wrongChoice = smoke.aiLiveAssessClosingRequestBodies(<String>[
      '{"tools":[{"name":"synthetic_lookup"}],"input":[]}',
      '{"tools":[{"name":"synthetic_lookup"}],"input":[],"tool_choice":"auto"}',
    ], caps: caps);
    expect(wrongChoice['toolsKeptOnClosingRequest'], isTrue);
    expect(wrongChoice['finishingChoiceOrNote'], isFalse);

    const fallbackCaps = AiCaps(tokenLimitField: AiTokenLimitField.maxTokens);
    final fallback = smoke.aiLiveAssessClosingRequestBodies(<String>[
      '{"tools":[{"name":"synthetic_lookup"}],"messages":[]}',
      '{"tools":[{"name":"synthetic_lookup"}],"messages":[{"role":"user","content":"<mergeline_final_answer>finish</mergeline_final_answer>"}]}',
    ], caps: fallbackCaps);
    expect(fallback['toolsKeptOnClosingRequest'], isTrue);
    expect(fallback['finishingChoiceOrNote'], isTrue);
  });

  test('runner smoke resumes from restored display history', () async {
    final adapter = FakeAdapter(
      (_) => _responses(_messageOutput('SYNTHETIC_HISTORY_RESUME')),
    );

    final result = await smoke.aiLiveRunnerHistoryResumeScenarioForTest(
      targetId: 'opencode-responses',
      adapter: adapter,
    );

    expect(result['status'], 'PASS');
    final evidence = result['evidence']! as Map<String, Object?>;
    expect(evidence['projectionPresent'], isTrue);
    expect(evidence['answerExact'], isTrue);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.data, contains('conversation_summary'));
    expect(adapter.requests.single.data, contains('SYNTHETIC_RESTORED_USER'));
  });

  test(
    'Anthropic runner smoke resumes from restored display history',
    () async {
      final adapter = FakeAdapter(
        (_) => _anthropic('SYNTHETIC_HISTORY_RESUME'),
      );

      final result = await smoke.aiLiveRunnerHistoryResumeScenarioForTest(
        targetId: 'anthropic-direct',
        adapter: adapter,
      );

      expect(result['status'], 'PASS');
      final evidence = result['evidence']! as Map<String, Object?>;
      expect(evidence['projectionPresent'], isTrue);
      expect(evidence['answerExact'], isTrue);
      expect(adapter.requests.single.data, contains('conversation_summary'));
    },
  );

  test(
    'runner smoke switches Responses models through a fresh segment',
    () async {
      var request = 0;
      final adapter = FakeAdapter((_) {
        request++;
        return _responses(
          _messageOutput(
            request == 1
                ? 'SYNTHETIC_BEFORE_MODEL_SWITCH'
                : 'SYNTHETIC_AFTER_MODEL_SWITCH',
          ),
        );
      });

      final result = await smoke.aiLiveRunnerModelSwitchScenarioForTest(
        targetId: 'opencode-responses',
        adapter: adapter,
      );

      expect(result['status'], 'PASS');
      final evidence = result['evidence']! as Map<String, Object?>;
      expect(evidence['fromModel'], 'gpt-6-luna');
      expect(evidence['toModel'], 'gpt-5.6-luna');
      expect(evidence['projectionPresent'], isTrue);
      expect(evidence['freshSegment'], isTrue);
      expect(adapter.requests, hasLength(2));
      final switched =
          jsonDecode(adapter.requests.last.data! as String)
              as Map<String, Object?>;
      expect(switched['model'], 'gpt-5.6-luna');
    },
  );

  test('runner smoke switches Chat models through a fresh segment', () async {
    var request = 0;
    final adapter = FakeAdapter((_) {
      request++;
      return _chat(
        request == 1
            ? 'SYNTHETIC_BEFORE_MODEL_SWITCH'
            : 'SYNTHETIC_AFTER_MODEL_SWITCH',
      );
    });

    final result = await smoke.aiLiveRunnerModelSwitchScenarioForTest(
      targetId: 'opencode-chat',
      adapter: adapter,
    );

    expect(result['status'], 'PASS');
    final evidence = result['evidence']! as Map<String, Object?>;
    expect(evidence['fromModel'], 'glm-5.3-flash');
    expect(evidence['toModel'], 'deepseek-v4.1-flash');
    expect(evidence['projectionPresent'], isTrue);
    expect(evidence['freshSegment'], isTrue);
    final switched =
        jsonDecode(adapter.requests.last.data! as String)
            as Map<String, Object?>;
    expect(switched['model'], 'deepseek-v4.1-flash');
  });
}

const _toolOnlyOutput = <Map<String, Object?>>[
  <String, Object?>{
    'type': 'function_call',
    'id': 'call-item-1',
    'call_id': 'call-1',
    'name': 'synthetic_lookup',
    'arguments': '{"fixture":"alpha"}',
    'status': 'completed',
  },
  <String, Object?>{
    'type': 'function_call',
    'id': 'call-item-2',
    'call_id': 'call-2',
    'name': 'synthetic_lookup',
    'arguments': '{"fixture":"beta"}',
    'status': 'completed',
  },
];

List<Map<String, Object?>> _toolOutput(int request) => <Map<String, Object?>>[
  <String, Object?>{
    'type': 'function_call',
    'id': 'runner-item-$request',
    'call_id': 'runner-call-$request',
    'name': 'synthetic_lookup',
    'arguments': '{"fixture":"alpha"}',
    'status': 'completed',
  },
];

List<Map<String, Object?>> _messageOutput(String text) =>
    <Map<String, Object?>>[
      <String, Object?>{
        'type': 'message',
        'id': 'message-synthetic',
        'role': 'assistant',
        'status': 'completed',
        'content': <Object?>[
          <String, Object?>{'type': 'output_text', 'text': text},
        ],
      },
    ];

ResponseBody _responses(
  List<Map<String, Object?>> output, {
  bool incomplete = false,
  String? streamedText,
}) {
  final event = jsonEncode(<String, Object?>{
    'type': incomplete ? 'response.incomplete' : 'response.completed',
    'response': <String, Object?>{
      'status': incomplete ? 'incomplete' : 'completed',
      'output': output,
      if (incomplete)
        'incomplete_details': const <String, Object?>{
          'reason': 'max_output_tokens',
        },
      'usage': const <String, Object?>{'input_tokens': 1, 'output_tokens': 1},
    },
  });
  return ResponseBody.fromString(
    '${streamedText == null ? '' : 'data: ${jsonEncode(<String, Object?>{'type': 'response.output_text.delta', 'delta': streamedText})}\n\n'}data: $event\n\n',
    200,
    headers: const <String, List<String>>{
      'content-type': <String>['text/event-stream'],
    },
  );
}

ResponseBody _chat(String text) {
  String event(Map<String, Object?> delta, {String? finishReason}) =>
      'data: ${jsonEncode(<String, Object?>{
        'id': 'synthetic-chat',
        'object': 'chat.completion.chunk',
        'choices': <Object?>[
          <String, Object?>{'index': 0, 'finish_reason': finishReason, 'delta': delta},
        ],
      })}\n\n';
  return ResponseBody.fromString(
    '${event(<String, Object?>{'role': 'assistant'})}'
    '${event(<String, Object?>{'content': text})}'
    '${event(const <String, Object?>{}, finishReason: 'stop')}'
    'data: [DONE]\n\n',
    200,
    headers: const <String, List<String>>{
      'content-type': <String>['text/event-stream'],
    },
  );
}

ResponseBody _anthropic(String text) {
  String event(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';
  return ResponseBody.fromString(
    '${event(<String, Object?>{
      'type': 'message_start',
      'message': <String, Object?>{
        'id': 'synthetic-message',
        'usage': <String, Object?>{'input_tokens': 1},
      },
    })}'
    '${event(<String, Object?>{
      'type': 'content_block_start',
      'index': 0,
      'content_block': <String, Object?>{'type': 'text', 'text': ''},
    })}'
    '${event(<String, Object?>{
      'type': 'content_block_delta',
      'index': 0,
      'delta': <String, Object?>{'type': 'text_delta', 'text': text},
    })}'
    '${event(<String, Object?>{'type': 'content_block_stop', 'index': 0})}'
    '${event(<String, Object?>{
      'type': 'message_delta',
      'delta': <String, Object?>{'stop_reason': 'end_turn'},
      'usage': <String, Object?>{'output_tokens': 1},
    })}'
    '${event(<String, Object?>{'type': 'message_stop'})}',
    200,
    headers: const <String, List<String>>{
      'content-type': <String>['text/event-stream'],
    },
  );
}
