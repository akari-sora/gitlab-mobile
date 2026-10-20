import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';

import 'runner_test.dart' as base;

void main() {
  test('failed closing call restores the pre-note tail', () async {
    final h = base.Harness();
    h.respond = (_, _) async {
      if (h.payloads.length == 4) {
        throw const AiFailure(AiFailureKind.network);
      }
      return h.turn(
        calls: [base.call('a'), base.call('b'), base.call('c'), base.call('d')],
      );
    };

    final failed = await h.runner.run('question');

    expect(failed.reason, AiRunEnd.toolBudget);
    expect(failed.failure?.kind, AiFailureKind.network);
    expect(h.payloads.last, contains(aiFinalAnswerNoteMarker));
    final restored = h.runner.segment!.tail! as AppToolResultsEntry;
    expect(restored.followUpText, isNull);

    h.respond = (_, _) async => h.turn(text: 'recovered');
    expect((await h.runner.run('retry')).reason, AiRunEnd.done);
    expect(h.payloads.last, isNot(contains(aiFinalAnswerNoteMarker)));
  });

  test('real decoder truncation cannot freeze a partial tool call', () async {
    final h = base.Harness();
    h.respond = (_, _) async {
      final decoder = const ChatCompletionsFormat().newDecoder();
      decoder.add(
        SseEvent(
          data: jsonEncode({
            'choices': [
              {
                'index': 0,
                'finish_reason': 'length',
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'partial-call',
                      'type': 'function',
                      'function': {
                        'name': 'read_file',
                        'arguments': '{"path":',
                      },
                    },
                  ],
                },
              },
            ],
            'usage': null,
          }),
        ),
      );
      decoder.add(const SseEvent(data: '[DONE]'));
      return decoder.finish();
    };

    final result = await h.runner.run('question');

    expect(result.failure?.kind, AiFailureKind.interrupted);
    expect(h.runner.segment!.entries, isEmpty);
  });

  test('four-call turn cap resets for the next tool turn', () async {
    final h = base.Harness();
    final executed = <String>[];
    h.execute = (toolCall) async {
      executed.add(toolCall.id);
      return AiToolResult(
        callId: toolCall.id,
        name: toolCall.name,
        content: 'result ${toolCall.id}',
      );
    };
    h.respond = (_, _) async => switch (h.payloads.length) {
      1 => h.turn(
        calls: [
          for (final id in ['a', 'b', 'c', 'd', 'e']) base.call(id),
        ],
      ),
      2 => h.turn(calls: [base.call('f')]),
      _ => h.turn(text: 'done'),
    };

    final result = await h.runner.run('question');

    expect(result.reason, AiRunEnd.done);
    expect(result.toolCalls, 5);
    expect(executed, ['a', 'b', 'c', 'd', 'f']);
    expect(h.payloads[1], contains('Not executed: budget'));
  });

  test('twelve-call run cap resets for the next send', () async {
    final h = base.Harness();
    final executed = <String>[];
    h.execute = (toolCall) async {
      executed.add(toolCall.id);
      return AiToolResult(
        callId: toolCall.id,
        name: toolCall.name,
        content: 'ok',
      );
    };
    h.respond = (_, _) async {
      if (h.payloads.length <= 3) {
        final prefix = h.payloads.length * 4;
        return h.turn(
          calls: [
            for (var i = prefix - 4; i < prefix; i++) base.call('call-$i'),
          ],
        );
      }
      if (h.payloads.length == 4) return h.turn(text: 'first complete');
      if (h.payloads.length == 5) {
        return h.turn(calls: [base.call('second-send')]);
      }
      return h.turn(text: 'second complete');
    };

    final first = await h.runner.run('first');
    final second = await h.runner.run('second');

    expect(first.reason, AiRunEnd.done);
    expect(first.toolCalls, 12);
    expect(second.reason, AiRunEnd.done);
    expect(second.toolCalls, 1);
    expect(executed.last, 'second-send');
  });

  test('tool-output character cap resets for the next send', () async {
    final h = base.Harness();
    final executed = <String>[];
    h.execute = (toolCall) async {
      executed.add(toolCall.id);
      return AiToolResult(
        callId: toolCall.id,
        name: toolCall.name,
        content: 'x' * 20000,
      );
    };
    h.respond = (_, _) async => switch (h.payloads.length) {
      1 => h.turn(
        calls: [
          for (final id in ['a', 'b', 'c', 'd']) base.call(id),
        ],
      ),
      2 => h.turn(calls: [base.call('e'), base.call('f')]),
      3 => h.turn(text: 'first complete'),
      4 => h.turn(calls: [base.call('second-send')]),
      _ => h.turn(text: 'second complete'),
    };

    final first = await h.runner.run('first');
    final second = await h.runner.run('second');

    expect(first.reason, AiRunEnd.done);
    expect(first.toolCalls, 6);
    expect(second.reason, AiRunEnd.done);
    expect(second.toolCalls, 1);
    expect(executed.last, 'second-send');
  });

  test('off-subnet cleartext LAN needs per-run confirmation', () async {
    final h = base.Harness();
    var approved = false;
    var confirmations = 0;
    final original = h.config();
    final config = AiProviderConfig(
      id: original.id,
      name: original.name,
      presetId: original.presetId,
      baseUrl: 'http://192.168.1.20:8080/v1',
      format: original.format,
      model: original.model,
      authStyle: original.authStyle,
      caps: original.caps,
      allowLanCleartext: true,
      toolsEnabled: original.toolsEnabled,
      recipientRevision: original.recipientRevision,
    );
    h.runner = AiRunner(
      config: config,
      wire: h.wire,
      complete: h.complete,
      secrets: h.secrets,
      refreshSecrets: () async {},
      guard: AiRunGuard(
        expectedGeneration: 1,
        ownerApi: h.owner,
        generation: () => h.generation,
        api: () => h.api,
        recipientRevision: () => h.revision,
        consentValid: () => h.consent,
      ),
      system: 'Synthetic system prompt.',
      tools: [base.spec],
      executeTool: (toolCall) async =>
          AiToolResult(callId: toolCall.id, name: toolCall.name, content: 'ok'),
      close: () => h.closed++,
      cancelActive: () => h.cancelled++,
      confirmCleartext: () async {
        confirmations++;
        return approved;
      },
      listInterfaceAddresses: ({required includeLinkLocal}) async => [
        InternetAddress('10.0.0.2'),
      ],
    );

    final denied = await h.runner.run('denied');
    expect(denied.failure?.kind, AiFailureKind.policyBlocked);
    expect(h.payloads, isEmpty);

    approved = true;
    expect((await h.runner.run('approved')).reason, AiRunEnd.done);
    expect(confirmations, 2);
    expect(h.payloads, hasLength(1));
  });
}
