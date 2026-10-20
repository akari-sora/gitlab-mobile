import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

void main() {
  const root = 'test/ai/fixtures/recorded';
  const cases = <_ReplayCase>[
    _ReplayCase(
      'A',
      'loop/01-loop1.response.sse',
      'loop/02-loop2.request.jsonc',
    ),
    _ReplayCase(
      'A',
      'loop/02-loop2.response.sse',
      'loop/03-loop3.request.jsonc',
    ),
    _ReplayCase(
      'A',
      'loop/03-loop3.response.sse',
      'loop/04-followup.request.jsonc',
    ),
    _ReplayCase(
      'C',
      'loop/01-loop1.response.sse',
      'loop/02-loop2.request.jsonc',
    ),
    _ReplayCase(
      'C',
      'loop/02-loop2.response.sse',
      'loop/03-loop3.request.jsonc',
    ),
    _ReplayCase(
      'R',
      'loop/01-loop1.response.sse',
      'loop/02-loop2.request.jsonc',
    ),
    _ReplayCase(
      'R',
      'loop/02-loop2.response.sse',
      'loop/03-loop3.request.jsonc',
    ),
    _ReplayCase(
      'R',
      'loop/03-loop3.response.sse',
      'loop/04-followup.request.jsonc',
    ),
  ];

  for (final replayCase in cases) {
    test(
      'recorded next request independently matches decoded ${replayCase.column} ${replayCase.response}',
      () async {
        final wire = replayCase.wire;
        final decoder = wire.newDecoder();
        await for (final event in const SseDecoder().decode(
          Stream.value(
            File(
              '$root/${replayCase.column}/${replayCase.response}',
            ).readAsBytesSync(),
          ),
        )) {
          decoder.add(event);
        }
        final output = decoder.finish().output;
        final encodedOutput = wire.encodeEntry(output, replayCase.caps);
        final request = _readJsonc(
          '$root/${replayCase.column}/${replayCase.nextRequest}',
        );
        final history =
            request[wire.format == AiFormat.responses ? 'input' : 'messages']!
                as List<Object?>;

        expect(
          _containsContiguousJson(history, encodedOutput),
          isTrue,
          reason:
              'the fixed recorded next request is the independent replay oracle',
        );
      },
    );
  }
}

Map<String, Object?> _readJsonc(String path) {
  final text = File(path).readAsStringSync();
  return jsonDecode(
        text.split('\n').where((line) => !line.startsWith('//')).join('\n'),
      )
      as Map<String, Object?>;
}

bool _containsContiguousJson(List<Object?> values, List<Object?> expected) {
  if (expected.isEmpty || expected.length > values.length) return false;
  final encodedExpected = expected
      .map((value) => jsonEncode(_canonicalJson(value)))
      .toList(growable: false);
  final encodedValues = values
      .map((value) => jsonEncode(_canonicalJson(value)))
      .toList(growable: false);
  for (var start = 0; start <= values.length - expected.length; start++) {
    var matches = true;
    for (var offset = 0; offset < expected.length; offset++) {
      if (encodedValues[start + offset] != encodedExpected[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Object? _canonicalJson(Object? value) {
  if (value is List<Object?>) {
    return value.map(_canonicalJson).toList(growable: false);
  }
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  return value;
}

final class _ReplayCase {
  const _ReplayCase(this.column, this.response, this.nextRequest);

  final String column;
  final String response;
  final String nextRequest;

  WireFormatBase get wire => switch (column) {
    'A' => const AnthropicMessagesFormat(),
    'C' => const ChatCompletionsFormat(),
    'R' => const ResponsesFormat(),
    _ => throw StateError('Unknown recorded column.'),
  };

  AiCaps get caps => switch (column) {
    'A' => AiPresets.anthropic.capsFor(AiFormat.anthropicMessages),
    'C' => AiPresets.openCodeGo.capsFor(AiFormat.chatCompletions),
    'R' => AiPresets.openCodeGo.capsFor(AiFormat.responses),
    _ => throw StateError('Unknown recorded column.'),
  };
}
