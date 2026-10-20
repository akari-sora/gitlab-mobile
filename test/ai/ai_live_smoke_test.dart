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
