import 'dart:convert';

import '../ai_events.dart';
import '../ai_failure.dart';
import '../ai_provider.dart';
import '../ai_transcript.dart';
import '../sse.dart';
import 'wire_format.dart';

final class ChatCompletionsFormat extends WireFormatBase {
  const ChatCompletionsFormat();

  @override
  AiFormat get format => AiFormat.chatCompletions;

  @override
  List<String> get streamPath => const ['chat', 'completions'];

  @override
  Map<String, Object?> encode(AiRequestPlan plan, AiCaps caps) {
    if (plan.segment.format != format) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final messages = <Object?>[
      {'role': 'system', 'content': plan.system},
      ...encodeWireEntries(plan, caps, encodeEntry),
    ];
    final body = <String, Object?>{
      'model': plan.model,
      'messages': messages,
      'stream': true,
      switch (caps.tokenLimitField) {
        AiTokenLimitField.maxTokens => 'max_tokens',
        AiTokenLimitField.maxCompletionTokens => 'max_completion_tokens',
        AiTokenLimitField.maxOutputTokens => 'max_output_tokens',
      }: plan.maxOutputTokens,
    };
    if (caps.streamUsage) {
      body['stream_options'] = <String, Object?>{'include_usage': true};
    }
    if (plan.tools.isNotEmpty) {
      body['tools'] = [
        for (final tool in plan.tools)
          <String, Object?>{
            'type': 'function',
            'function': <String, Object?>{
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
          },
      ];
      if (caps.toolChoice) body['tool_choice'] = plan.toolChoice.name;
    }
    return body;
  }

  @override
  List<Object?> encodeEntry(AiEntry entry, AiCaps caps) => switch (entry) {
    AppUserEntry() => [
      <String, Object?>{'role': 'user', 'content': userEntryText(entry)},
    ],
    ProviderOutputEntry() => [_replayMessage(entry, caps)],
    AppToolResultsEntry() => [
      for (final result in entry.results)
        <String, Object?>{
          'role': 'tool',
          'tool_call_id': result.callId,
          'content': result.content,
        },
      if (entry.followUpText case final String text)
        <String, Object?>{'role': 'user', 'content': text},
    ],
  };

  Map<String, Object?> _replayMessage(ProviderOutputEntry entry, AiCaps caps) {
    if (entry.format != format) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final message = wireObject(entry.raw);
    if (caps.replayChatExtras) return message;
    return <String, Object?>{
      for (final key in const [
        'role',
        'content',
        'refusal',
        'tool_calls',
        'function_call',
      ])
        if (message.containsKey(key))
          key: key == 'tool_calls'
              ? [
                  for (final value in wireList(message[key]))
                    _standardToolCall(wireObject(value)),
                ]
              : message[key],
    };
  }

  Map<String, Object?> _standardToolCall(Map<String, Object?> call) =>
      <String, Object?>{
        for (final key in const ['id', 'type', 'function'])
          if (call.containsKey(key))
            key: key == 'function'
                ? <String, Object?>{
                    for (final functionKey in const ['name', 'arguments'])
                      if (wireObject(call[key]).containsKey(functionKey))
                        functionKey: wireObject(call[key])[functionKey],
                  }
                : call[key],
      };

  @override
  AiStreamDecoder newDecoder() => ChatStreamDecoder();
}

final class ChatStreamDecoder implements AiStreamDecoder {
  static const _standardMessageFields = {
    'role',
    'content',
    'refusal',
    'tool_calls',
    'function_call',
  };
  static const _standardToolFields = {'index', 'id', 'type', 'function'};
  static const _maxExtrasBytes = 1024 * 1024;

  final Map<String, Object?> _message = <String, Object?>{'role': 'assistant'};
  final Map<int, Map<String, Object?>> _toolCalls = {};
  final Map<Map<String, Object?>, Map<String, int>> _extraSizes =
      Map.identity();
  int _extrasBytes = 0;
  bool _started = false;
  bool _terminal = false;
  bool _poisoned = false;
  String? _finishReason;
  AiUsage? _usage;
  AiDecodedTurn? _turn;
  int ignoredAfterTerminal = 0;

  @override
  List<AiEvent> add(SseEvent event) {
    if (_poisoned) throw const AiFailure(AiFailureKind.interrupted);
    try {
      return _add(event);
    } on AiFailure {
      _poisoned = true;
      rethrow;
    } on Object {
      _poisoned = true;
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
  }

  List<AiEvent> _add(SseEvent event) {
    if (_terminal) {
      ignoredAfterTerminal += 1;
      return const [];
    }
    if (event.data == '[DONE]') {
      return _complete();
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(event.data);
    } on FormatException {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    final chunk = wireObject(decoded);
    if (chunk['error'] != null) {
      throw decodeWireError(500, chunk, null);
    }

    final emitted = <AiEvent>[];
    if (!_started) {
      _started = true;
      emitted.add(const AiStarted());
    }
    final usage = _decodeUsage(chunk['usage']);
    if (usage != null) {
      _usage = usage;
      emitted.add(AiUsageUpdated(usage));
    }

    for (final value in wireList(chunk['choices'])) {
      final choice = wireObject(value);
      final index = choice['index'];
      if (index is! int || index != 0) continue;
      if (choice['finish_reason'] case final String reason) {
        if (reason == 'error') {
          throw const AiFailure(AiFailureKind.server);
        }
        _finishReason = reason;
      }
      final delta = wireObject(choice['delta']);
      _mergeDelta(delta, emitted);
    }
    return emitted;
  }

  void _mergeDelta(Map<String, Object?> delta, List<AiEvent> emitted) {
    for (final key in const [
      'content',
      'refusal',
      'reasoning_content',
      'reasoning',
    ]) {
      if (delta[key] != null && delta[key] is! String) {
        throw const AiFailure(AiFailureKind.invalidResponse);
      }
    }
    for (final key in const ['tool_calls', 'reasoning_details']) {
      if (delta[key] != null && delta[key] is! List<Object?>) {
        throw const AiFailure(AiFailureKind.invalidResponse);
      }
    }
    if (delta['function_call'] != null &&
        delta['function_call'] is! Map<String, Object?>) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    if (delta['function_call'] case final Map<String, Object?> legacy) {
      final target = _message.putIfAbsent(
        'function_call',
        () => <String, Object?>{},
      );
      _mergeFunction(wireObject(target), legacy);
    }
    if (delta['content'] case final String content) {
      _appendString(_message, 'content', content);
      if (content.isNotEmpty) emitted.add(AiTextDelta(content));
    }
    if (delta['refusal'] case final String refusal) {
      _appendString(_message, 'refusal', refusal);
      if (refusal.isNotEmpty) emitted.add(AiRefusalDelta(refusal));
    }

    var reasoningActive = false;
    for (final key in const ['reasoning_content', 'reasoning']) {
      if (delta[key] case final String text) {
        _appendExtra(_message, key, text);
        reasoningActive = reasoningActive || text.isNotEmpty;
      }
    }
    if (delta['reasoning_details'] case final List<Object?> details) {
      _mergeReasoningDetails(details);
      reasoningActive = reasoningActive || details.isNotEmpty;
    }
    if (reasoningActive) emitted.add(const AiReasoningActive());

    if (delta['tool_calls'] case final List<Object?> calls) {
      for (final value in calls) {
        _mergeToolCall(wireObject(value));
      }
    }
    for (final entry in delta.entries) {
      if (_standardMessageFields.contains(entry.key) ||
          entry.key == 'reasoning_content' ||
          entry.key == 'reasoning' ||
          entry.key == 'reasoning_details' ||
          entry.value == null) {
        continue;
      }
      _setExtra(_message, entry.key, deepFreezeJson(entry.value));
    }
    _checkExtrasSize();
  }

  void _mergeToolCall(Map<String, Object?> delta) {
    final index = delta['index'];
    if (index is! int || index < 0) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    final target = _toolCalls.putIfAbsent(index, () => <String, Object?>{});
    for (final key in const ['id', 'type']) {
      final value = delta[key];
      if (target[key] == null && value is String && value.isNotEmpty) {
        target[key] = value;
      }
    }
    if (delta['function'] case final Map<String, Object?> function) {
      final targetFunction = target.putIfAbsent(
        'function',
        () => <String, Object?>{},
      );
      _mergeFunction(wireObject(targetFunction), function);
    }
    for (final entry in delta.entries) {
      if (_standardToolFields.contains(entry.key) || entry.value == null) {
        continue;
      }
      if (entry.key == 'extra_content') {
        final extra = wireObject(entry.value);
        if (extra.isEmpty) continue;
      }
      _setExtra(target, entry.key, deepFreezeJson(entry.value));
    }
  }

  void _mergeFunction(Map<String, Object?> target, Map<String, Object?> delta) {
    final name = delta['name'];
    if (target['name'] == null && name is String && name.isNotEmpty) {
      target['name'] = name;
    }
    if (delta['arguments'] case final String arguments) {
      _appendString(target, 'arguments', arguments);
    }
    for (final entry in delta.entries) {
      if (entry.key == 'name' ||
          entry.key == 'arguments' ||
          entry.value == null) {
        continue;
      }
      _setExtra(target, entry.key, deepFreezeJson(entry.value));
    }
  }

  void _mergeReasoningDetails(List<Object?> delta) {
    var details = _message['reasoning_details'] as List<Object?>?;
    if (details == null) {
      details = <Object?>[];
      _setExtra(_message, 'reasoning_details', details);
    }
    for (final value in delta) {
      final item = wireObject(value);
      final type = item['type'];
      final mergeable = type == 'reasoning.text' || type == 'reasoning.summary';
      final previous = details.isEmpty ? null : wireObject(details.last);
      if (!mergeable ||
          previous == null ||
          previous['type'] != type ||
          previous['index'] != item['index']) {
        final added = <String, Object?>{};
        _extrasBytes += (details.isEmpty ? 0 : 1);
        details.add(added);
        // Empty objects still occupy two bytes.
        if (item.isEmpty) _extrasBytes += 2;
        for (final entry in item.entries) {
          _setExtra(added, entry.key, deepFreezeJson(entry.value));
        }
        continue;
      }
      final chunkField = type == 'reasoning.text' ? 'text' : 'summary';
      if (item[chunkField] != null && item[chunkField] is! String) {
        throw const AiFailure(AiFailureKind.invalidResponse);
      }
      if (item[chunkField] case final String text) {
        _appendExtra(previous, chunkField, text);
      }
      for (final key in const ['type', 'id', 'format', 'signature']) {
        final value = item[key];
        if ((previous[key] == null || previous[key] == '') && value != null) {
          _setExtra(previous, key, deepFreezeJson(value));
        }
      }
      for (final entry in item.entries) {
        if ({
              chunkField,
              'type',
              'id',
              'format',
              'signature',
            }.contains(entry.key) ||
            entry.value == null) {
          continue;
        }
        _setExtra(previous, entry.key, deepFreezeJson(entry.value));
      }
    }
  }

  void _setExtra(Map<String, Object?> target, String key, Object? value) {
    final sizes = _extraSizes.putIfAbsent(target, () => <String, int>{});
    final old = sizes[key];
    final size =
        utf8.encode(jsonEncode(key)).length +
        1 +
        utf8.encode(jsonEncode(value)).length;
    _extrasBytes +=
        size - (old ?? 0) + (old == null ? (sizes.isEmpty ? 2 : 1) : 0);
    sizes[key] = size;
    target[key] = value;
    _checkExtrasSize();
  }

  void _appendExtra(Map<String, Object?> target, String key, String text) {
    final previous = target[key];
    if (previous != null &&
        previous is! String &&
        previous is! _BufferedString) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    final buffer = previous is _BufferedString
        ? previous
        : _BufferedString(previous as String? ?? '');
    if (previous is! _BufferedString) {
      _setExtra(target, key, buffer.toString());
      target[key] = buffer;
    }
    final added = buffer.append(text);
    _extraSizes[target]![key] = _extraSizes[target]![key]! + added;
    _extrasBytes += added;
    _checkExtrasSize();
  }

  List<AiEvent> _complete() {
    if (!_started || _finishReason == null) {
      throw const AiFailure(AiFailureKind.interrupted);
    }
    final turn = _buildTurn();
    _terminal = true;
    _turn = turn;
    return [AiFinished(turn.stop, usage: turn.usage)];
  }

  AiDecodedTurn _buildTurn() {
    // Legacy calls cannot be paired with modern tool-result entries.
    if (_message.containsKey('function_call')) {
      throw const AiFailure(AiFailureKind.interrupted);
    }
    if (_toolCalls.isNotEmpty) {
      _message['tool_calls'] = [
        for (final index in _toolCalls.keys.toList()..sort())
          Map<String, Object?>.of(_toolCalls[index]!),
      ];
    }
    _checkExtrasSize();
    final calls = <AiToolCall>[];
    for (final index in _toolCalls.keys.toList()..sort()) {
      final value = _toolCalls[index]!;
      final functionValue = value['function'];
      if (functionValue is! Map<String, Object?>) {
        throw const AiFailure(AiFailureKind.interrupted);
      }
      final function = functionValue;
      final id = value['id'];
      final name = function['name'];
      final arguments = _materialize(function['arguments']);
      if (id is! String ||
          id.isEmpty ||
          name is! String ||
          name.isEmpty ||
          arguments is! String) {
        throw const AiFailure(AiFailureKind.interrupted);
      }
      calls.add(
        AiToolCall(id: id, name: name, arguments: wireArguments(arguments)),
      );
    }
    final stop = _chatStop(_finishReason);
    return AiDecodedTurn(
      ProviderOutputEntry(
        AiFormat.chatCompletions,
        _materialize(_message)!,
        toolCalls: calls,
      ),
      stop,
      _usage,
    );
  }

  void _checkExtrasSize() {
    if (_extrasBytes > _maxExtrasBytes) {
      throw const AiFailure(AiFailureKind.responseTooLarge);
    }
  }

  @override
  AiDecodedTurn finish() {
    if (_poisoned) throw const AiFailure(AiFailureKind.interrupted);
    final turn = _turn;
    if (turn != null) return turn;
    if (_finishReason != null) {
      try {
        _terminal = true;
        return _turn = _buildTurn();
      } on Object {
        _poisoned = true;
        rethrow;
      }
    }
    _poisoned = true;
    throw const AiFailure(AiFailureKind.interrupted);
  }
}

AiStopReason _chatStop(String? value) => switch (value) {
  'length' => AiStopReason.maxTokens,
  'content_filter' => AiStopReason.contentFilter,
  'refusal' => AiStopReason.refusal,
  _ => AiStopReason.endTurn,
};

// Buffers stay private to the decoder; only materialized JSON crosses freeze.
final class _BufferedString {
  _BufferedString(String initial) {
    _buffer.write(initial);
    if (initial.isNotEmpty) {
      _lastCodeUnit = initial.codeUnitAt(initial.length - 1);
    }
  }
  final StringBuffer _buffer = StringBuffer();
  int? _lastCodeUnit;
  int append(String value) {
    var bytes = 0;
    for (var i = 0; i < value.length; i++) {
      final code = value.codeUnitAt(i);
      if (code == 0x22 ||
          code == 0x5c ||
          code == 8 ||
          code == 9 ||
          code == 10 ||
          code == 12 ||
          code == 13) {
        bytes += 2;
      } else if (code < 0x20) {
        bytes += 6;
      } else if (code < 0x80) {
        bytes++;
      } else if (code < 0x800) {
        bytes += 2;
      } else if (code >= 0xd800 &&
          code <= 0xdbff &&
          i + 1 < value.length &&
          value.codeUnitAt(i + 1) >= 0xdc00 &&
          value.codeUnitAt(i + 1) <= 0xdfff) {
        bytes += 4;
        i++;
      } else {
        bytes += code >= 0xd800 && code <= 0xdfff ? 6 : 3;
      }
    }
    // JSON escapes lone surrogates; a pair split across deltas becomes one
    // four-byte scalar rather than two six-byte escapes.
    if (value.isNotEmpty) {
      final first = value.codeUnitAt(0);
      if (_lastCodeUnit != null &&
          _lastCodeUnit! >= 0xd800 &&
          _lastCodeUnit! <= 0xdbff &&
          first >= 0xdc00 &&
          first <= 0xdfff) {
        bytes -= 8;
      }
      _lastCodeUnit = value.codeUnitAt(value.length - 1);
    }
    _buffer.write(value);
    return bytes;
  }

  @override
  String toString() => _buffer.toString();
}

void _appendString(Map<String, Object?> target, String key, String value) {
  final previous = target[key];
  if (previous != null && previous is! String && previous is! _BufferedString) {
    throw const AiFailure(AiFailureKind.invalidResponse);
  }
  final buffer = previous is _BufferedString
      ? previous
      : _BufferedString(previous as String? ?? '');
  buffer.append(value);
  target[key] = buffer;
}

Object? _materialize(Object? value) => switch (value) {
  _BufferedString() => value.toString(),
  Map<String, Object?>() => <String, Object?>{
    for (final entry in value.entries) entry.key: _materialize(entry.value),
  },
  List<Object?>() => <Object?>[for (final item in value) _materialize(item)],
  _ => value,
};

AiUsage? _decodeUsage(Object? value) {
  if (value is! Map<String, Object?>) return null;
  int? count(Object? value) => value is int && value >= 0 ? value : null;

  final input = count(value['prompt_tokens']);
  final details = value['prompt_tokens_details'];
  var cached = details is Map<String, Object?>
      ? count(details['cached_tokens'])
      : null;
  // Usage is ancillary: an impossible split must not discard billed output.
  if (input == null || (cached != null && cached > input)) {
    cached = null;
  }
  final output = count(value['completion_tokens']);
  // A later chunk with no usable count must not erase earlier usage.
  if (input == null && output == null) return null;
  return AiUsage(
    // Chat prompt_tokens includes cached tokens; AiUsage totals cache
    // separately, as with Anthropic's disjoint usage counts.
    inputTokens: input == null ? null : input - (cached ?? 0),
    outputTokens: output,
    cacheReadInputTokens: cached,
  );
}
