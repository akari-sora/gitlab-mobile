import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

Object outputFor(AiFormat format) => switch (format) {
  AiFormat.chatCompletions => {
    'role': 'assistant',
    'content': '',
    'tool_calls': [
      for (final id in ['a', 'b'])
        {
          'id': 'call_$id',
          'type': 'function',
          'function': {'name': 'read_file', 'arguments': '{"path":"$id.dart"}'},
        },
    ],
  },
  AiFormat.responses => [
    for (final id in ['a', 'b'])
      {
        'type': 'function_call',
        'id': 'fc_$id',
        'call_id': 'call_$id',
        'name': 'read_file',
        'arguments': '{"path":"$id.dart"}',
        'status': 'completed',
      },
  ],
  AiFormat.anthropicMessages => [
    for (final id in ['a', 'b'])
      {
        'type': 'tool_use',
        'id': 'call_$id',
        'name': 'read_file',
        'input': {'path': '$id.dart'},
      },
  ],
};

void main() {
  for (final wire in <WireFormatBase>[
    const ChatCompletionsFormat(),
    const ResponsesFormat(),
    const AnthropicMessagesFormat(),
  ]) {
    final caps = AiCaps(
      tokenLimitField: AiTokenLimitField.maxTokens,
      replayChatExtras: true,
      toolChoice: true,
    );
    AiSegment segment() => AiSegment(
      providerId: 'synthetic',
      recipientRevision: 1,
      format: wire.format,
      model: 'synthetic-model',
      secretSetAtStart: SecretSetId.fromSecrets([]),
    );
    AiRequestPlan plan(
      AiSegment segment, {
      String system = 'Synthetic system',
      AiToolChoice choice = AiToolChoice.auto,
      bool tools = true,
    }) => AiRequestPlan(
      model: 'synthetic-model',
      system: system,
      segment: segment,
      toolChoice: choice,
      tools: tools
          ? [
              AiToolSpec(
                name: 'read_file',
                description: 'Read synthetic file',
                parameters: {
                  'type': 'object',
                  'properties': {
                    'path': {'type': 'string'},
                  },
                },
              ),
            ]
          : [],
    );
    ProviderOutputEntry output() => ProviderOutputEntry(
      wire.format,
      outputFor(wire.format),
      toolCalls: [
        for (final id in ['a', 'b'])
          AiToolCall(
            id: 'call_$id',
            name: 'read_file',
            arguments: {'path': '$id.dart'},
          ),
      ],
    );

    test(
      '${wire.format.name} two parallel tools plus followup matches golden',
      () {
        final state = segment()..setTail(AppUserEntry(text: 'Read both'));
        wire.encode(plan(state), caps);
        state.freezeWith(output(), (entry) => wire.encodeEntry(entry, caps));
        state.setTail(
          AppToolResultsEntry([
            AiToolResult(
              callId: 'call_a',
              name: 'read_file',
              content: 'A',
            ),
            AiToolResult(
              callId: 'call_b',
              name: 'read_file',
              content: 'B',
            ),
          ], followUpText: 'Explain more'),
        );
        final body = wire.encode(plan(state), caps);
        final golden = jsonDecode(
          File(
            'test/ai/fixtures/golden/${wire.format.name}.json',
          ).readAsStringSync(),
        );
        expect(body, golden);
        expect(jsonDecode(wire.encodeJson(plan(state), caps)), golden);
      },
    );

    test(
      '${wire.format.name} retries and new-tail clipping preserve prefix bytes',
      () {
        final state = segment()..setTail(AppUserEntry(text: 'Read both'));
        final first = wire.encode(plan(state), caps);
        state.freezeWith(output(), (entry) => wire.encodeEntry(entry, caps));
        final cached = state.frozenWireJson.toList();
        state.setTail(
          AppToolResultsEntry([
            AiToolResult(
              callId: 'call_a',
              name: 'read_file',
              content:
                  'A'
                  ' long result',
            ),
            AiToolResult(
              callId: 'call_b',
              name: 'read_file',
              content:
                  'B'
                  ' long result',
            ),
          ]),
        );
        state.clipTailToolResults(3);
        final second = wire.encode(
          plan(state, choice: AiToolChoice.none),
          caps,
        );
        final key = wire.format == AiFormat.responses ? 'input' : 'messages';
        final before = jsonEncode(first[key]);
        expect(
          jsonEncode(second[key]),
          startsWith(before.substring(0, before.length - 1)),
        );
        expect(second['tools'], first['tools']);
        expect(state.frozenWireJson, cached);
        final serialized = wire.encodeJson(
          plan(state, choice: AiToolChoice.none),
          caps,
        );
        expect(jsonDecode(serialized), second);
        // Failed/interrupted attempts do not advance or rewrite the watermark.
        state.restoreTail(state.tail);
        expect(
          wire.encodeJson(plan(state, choice: AiToolChoice.none), caps),
          serialized,
        );
        expect(state.frozenLength, 2);
        expect(
          () => wire.encode(plan(state, system: 'Changed'), caps),
          throwsStateError,
        );
        expect(
          () => wire.encode(plan(state, tools: false), caps),
          throwsStateError,
        );
      },
    );

    test(
      '${wire.format.name} caps without choice retain tools for closing call',
      () {
        final state = segment()..setTail(AppUserEntry(text: 'Read both'));
        const noChoice = AiCaps(tokenLimitField: AiTokenLimitField.maxTokens);
        final body = wire.encode(
          plan(state, choice: AiToolChoice.none),
          noChoice,
        );
        expect(body.containsKey('tools'), true);
        expect(body.containsKey('tool_choice'), false);
      },
    );
  }
}
