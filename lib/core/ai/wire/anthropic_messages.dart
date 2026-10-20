import 'dart:convert';

import '../ai_events.dart';
import '../ai_failure.dart';
import '../ai_provider.dart';
import '../ai_transcript.dart';
import '../sse.dart';
import 'wire_format.dart';

final class AnthropicMessagesFormat extends WireFormatBase {
  const AnthropicMessagesFormat();

  @override
  AiFormat get format => AiFormat.anthropicMessages;

  @override
  List<String> get streamPath => const ['messages'];

  @override
  Map<String, Object?> encode(AiRequestPlan plan, AiCaps caps) {
    if (plan.segment.format != format) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final messages = encodeWireEntries(plan, caps, encodeEntry);
    _assertAlternatingRoles(messages);
    return <String, Object?>{
      'model': plan.model,
      'system': plan.system,
      'messages': messages,
      'stream': true,
      'max_tokens': plan.maxOutputTokens,
      if (plan.tools.isNotEmpty) ...{
        'tools': <Object?>[
          for (final tool in plan.tools)
            <String, Object?>{
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.parameters,
            },
        ],
        if (caps.toolChoice)
          'tool_choice': <String, Object?>{
            'type': plan.toolChoice == AiToolChoice.none ? 'none' : 'auto',
          },
      },
    };
  }

  @override
  List<Object?> encodeEntry(AiEntry entry, AiCaps caps) => switch (entry) {
    AppUserEntry() => <Object?>[_encodeUser(entry, caps)],
    ProviderOutputEntry() => <Object?>[_encodeOutput(entry)],
    AppToolResultsEntry() => <Object?>[_encodeToolResults(entry)],
  };

  @override
  AiStreamDecoder newDecoder() => AnthropicStreamDecoder();

  Map<String, Object?> _encodeUser(AppUserEntry entry, AiCaps caps) {
    final content = <Object?>[];
    for (var index = 0; index < entry.context.length; index++) {
      content.add(<String, Object?>{
        'type': 'text',
        'text': entry.context[index].text,
        if (index == 0 && caps.promptCaching)
          'cache_control': const <String, Object?>{'type': 'ephemeral'},
      });
    }
    if (entry.text.isNotEmpty) {
      content.add(<String, Object?>{'type': 'text', 'text': entry.text});
    }
    return <String, Object?>{'role': 'user', 'content': content};
  }

  Map<String, Object?> _encodeOutput(ProviderOutputEntry entry) {
    if (entry.format != format) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    return <String, Object?>{
      'role': 'assistant',
      'content': _fallbackReplayBlocks(wireList(entry.raw)),
    };
  }

  Map<String, Object?> _encodeToolResults(AppToolResultsEntry entry) =>
      <String, Object?>{
        'role': 'user',
        'content': <Object?>[
          for (final result in entry.results)
            <String, Object?>{
              'type': 'tool_result',
              'tool_use_id': result.callId,
              'content': result.content,
              if (result.isError) 'is_error': true,
            },
          if (entry.followUpText case final String text when text.isNotEmpty)
            <String, Object?>{'type': 'text', 'text': text},
        ],
      };

  void _assertAlternatingRoles(List<Object?> messages) {
    String? previous;
    for (final value in messages) {
      final role = wireObject(value)['role'];
      if (role is! String || (role != 'user' && role != 'assistant')) {
        throw const AiFailure(AiFailureKind.invalidResponse);
      }
      if (role == previous) {
        throw StateError('Anthropic messages must alternate roles.');
      }
      previous = role;
    }
  }
}

final class AnthropicStreamDecoder implements AiStreamDecoder {
  final Map<int, Map<String, Object?>> _blocks = {};
  final Map<int, StringBuffer> _partialInput = {};
  final Map<int, StringBuffer> _text = {};
  final Map<int, StringBuffer> _thinking = {};
  final Map<int, StringBuffer> _signature = {};
  final Set<int> _closedBlocks = {};
  var _started = false;
  var _terminal = false;
  String? _stopReason;
  AiUsage? _usage;
  AiFailure? _failure;
  int ignoredAfterTerminal = 0;

  @override
  List<AiEvent> add(SseEvent event) {
    if (_terminal) {
      ignoredAfterTerminal += 1;
      return const <AiEvent>[];
    }
    try {
      return _add(event);
    } on AiFailure catch (failure) {
      _failure = failure;
      _terminal = true;
      rethrow;
    } on Object {
      _failure = const AiFailure(AiFailureKind.invalidResponse);
      _terminal = true;
      throw _failure!;
    }
  }

  List<AiEvent> _add(SseEvent event) {
    if (event.data.isEmpty) return const <AiEvent>[];
    final body = _decodeObject(event.data);
    final type = body['type'] is String ? body['type'] as String : event.event;
    switch (type) {
      case 'ping':
        return const <AiEvent>[];
      case 'error':
        _failure = decodeWireError(500, body, null);
        _terminal = true;
        throw _failure!;
      case 'message_start':
        final events = <AiEvent>[];
        if (!_started) {
          _started = true;
          events.add(const AiStarted());
        }
        final message = wireObject(body['message']);
        final usage = _mergeUsage(message['usage']);
        if (usage != null) events.add(AiUsageUpdated(usage));
        return events;
      case 'content_block_start':
        _requireStarted();
        final index = _index(body);
        if (_blocks.containsKey(index)) {
          throw const AiFailure(AiFailureKind.invalidResponse);
        }
        final block = Map<String, Object?>.from(
          wireObject(body['content_block']),
        );
        if (block['type'] is! String) {
          throw const AiFailure(AiFailureKind.invalidResponse);
        }
        _blocks[index] = block;
        switch (block['type']) {
          case 'text':
            _text[index] = _initialBuffer(block, 'text');
            break;
          case 'thinking':
            _thinking[index] = _initialBuffer(block, 'thinking');
            _signature[index] = _initialBuffer(block, 'signature');
            break;
          case 'tool_use':
            _partialInput[index] = StringBuffer();
            break;
        }
        if (block['type'] == 'thinking' ||
            block['type'] == 'redacted_thinking') {
          return const <AiEvent>[AiReasoningActive()];
        }
        return const <AiEvent>[];
      case 'content_block_delta':
        _requireStarted();
        return _addBlockDelta(_index(body), wireObject(body['delta']));
      case 'content_block_stop':
        _requireStarted();
        _closeBlock(_index(body));
        return const <AiEvent>[];
      case 'message_delta':
        _requireStarted();
        final delta = wireObject(body['delta']);
        if (delta['stop_reason'] case final String reason) {
          _stopReason = reason;
        }
        final usage = _mergeUsage(body['usage']);
        return usage == null
            ? const <AiEvent>[]
            : <AiEvent>[AiUsageUpdated(usage)];
      case 'message_stop':
        if (!_started) {
          throw const AiFailure(AiFailureKind.interrupted);
        }
        _validateCompleteBlocks();
        _terminal = true;
        return <AiEvent>[AiFinished(wireStop(_stopReason), usage: _usage)];
      default:
        return const <AiEvent>[];
    }
  }

  @override
  AiDecodedTurn finish() {
    if (_failure case final AiFailure failure) throw failure;
    try {
      if (!_terminal || !_started) {
        throw const AiFailure(AiFailureKind.interrupted);
      }
      _validateCompleteBlocks();
      final indexes = _blocks.keys.toList()..sort();
      final blocks = <Object?>[for (final index in indexes) _blocks[index]!];
      final calls = <AiToolCall>[
        for (final block in _fallbackReplayBlocks(blocks).map(wireObject))
          if (block['type'] == 'tool_use')
            AiToolCall(
              id: block['id'] as String,
              name: block['name'] as String,
              arguments: block['input'],
            ),
      ];
      return AiDecodedTurn(
        ProviderOutputEntry(
          AiFormat.anthropicMessages,
          blocks,
          toolCalls: calls,
        ),
        wireStop(_stopReason),
        _usage,
      );
    } on AiFailure catch (failure) {
      _failure = failure;
      _terminal = true;
      rethrow;
    }
  }

  List<AiEvent> _addBlockDelta(int index, Map<String, Object?> delta) {
    final block = _blocks[index];
    if (block == null || _closedBlocks.contains(index)) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    final blockType = block['type'];
    if (blockType != 'text' &&
        blockType != 'thinking' &&
        blockType != 'tool_use') {
      return const <AiEvent>[];
    }
    switch (delta['type']) {
      case 'text_delta':
        final text = delta['text'];
        final buffer = _text[index];
        if (text is! String || buffer == null) {
          throw const AiFailure(AiFailureKind.invalidResponse);
        }
        buffer.write(text);
        return text.isEmpty ? const <AiEvent>[] : <AiEvent>[AiTextDelta(text)];
      case 'thinking_delta':
        final thinking = delta['thinking'];
        final buffer = _thinking[index];
        if (thinking is! String || buffer == null) {
          throw const AiFailure(AiFailureKind.invalidResponse);
        }
        buffer.write(thinking);
        return const <AiEvent>[AiReasoningActive()];
      case 'signature_delta':
        final signature = delta['signature'];
        final buffer = _signature[index];
        if (signature is! String || buffer == null) {
          throw const AiFailure(AiFailureKind.invalidResponse);
        }
        buffer.write(signature);
        return const <AiEvent>[];
      case 'input_json_delta':
        final partial = delta['partial_json'];
        if (partial is! String || !_partialInput.containsKey(index)) {
          throw const AiFailure(AiFailureKind.invalidResponse);
        }
        _partialInput[index]!.write(partial);
        return const <AiEvent>[];
      case 'citations_delta':
        final citations = block.putIfAbsent('citations', () => <Object?>[]);
        if (citations is! List<Object?> || !delta.containsKey('citation')) {
          throw const AiFailure(AiFailureKind.invalidResponse);
        }
        citations.add(delta['citation']);
        return const <AiEvent>[];
      default:
        for (final entry in delta.entries) {
          if (entry.key != 'type' && entry.value != null) {
            block[entry.key] = entry.value;
          }
        }
        return const <AiEvent>[];
    }
  }

  void _closeBlock(int index) {
    final block = _blocks[index];
    if (block == null || !_closedBlocks.add(index)) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    if (_text.remove(index) case final StringBuffer buffer) {
      block['text'] = buffer.toString();
    }
    if (_thinking.remove(index) case final StringBuffer buffer) {
      block['thinking'] = buffer.toString();
    }
    if (_signature.remove(index) case final StringBuffer buffer) {
      block['signature'] = buffer.toString();
    }
    if (block['type'] != 'tool_use') return;
    final partial = _partialInput[index];
    if (partial == null) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    final value = partial.toString();
    if (value.isNotEmpty) {
      block['input'] = wireArguments(value);
      return;
    }
    if (block['input'] is! Map<String, Object?>) {
      throw const AiFailure(AiFailureKind.interrupted);
    }
  }

  StringBuffer _initialBuffer(Map<String, Object?> block, String field) {
    final initial = block[field];
    if (initial != null && initial is! String) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    return StringBuffer(initial ?? '');
  }

  void _requireStarted() {
    if (!_started) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
  }

  void _validateCompleteBlocks() {
    for (final entry in _blocks.entries) {
      final block = entry.value;
      if (!_closedBlocks.contains(entry.key) ||
          (block['type'] == 'tool_use' && !_validToolBlock(block)) ||
          (block['type'] == 'thinking' &&
              (block['signature'] is! String ||
                  (block['signature'] as String).isEmpty))) {
        throw const AiFailure(AiFailureKind.interrupted);
      }
    }
  }

  bool _validToolBlock(Map<String, Object?> block) =>
      block['id'] is String &&
      (block['id'] as String).isNotEmpty &&
      block['name'] is String &&
      (block['name'] as String).isNotEmpty &&
      block['input'] is Map<String, Object?>;

  AiUsage? _mergeUsage(Object? value) {
    if (value == null) return null;
    final map = wireObject(value);
    final previous = _usage;
    var updated = false;
    int? latest(String key, int? old) {
      final current = map[key];
      if (current == null) return old;
      if (current is! int || current < 0) {
        throw const AiFailure(AiFailureKind.invalidResponse);
      }
      updated = true;
      return current;
    }

    final next = AiUsage(
      inputTokens: latest('input_tokens', previous?.inputTokens),
      outputTokens: latest('output_tokens', previous?.outputTokens),
      cacheCreationInputTokens: latest(
        'cache_creation_input_tokens',
        previous?.cacheCreationInputTokens,
      ),
      cacheReadInputTokens: latest(
        'cache_read_input_tokens',
        previous?.cacheReadInputTokens,
      ),
    );
    if (!updated) return null;
    _usage = next;
    return next;
  }

  int _index(Map<String, Object?> body) {
    final index = body['index'];
    if (index is! int || index < 0) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    return index;
  }

  Map<String, Object?> _decodeObject(String value) {
    try {
      return wireObject(jsonDecode(value));
    } on AiFailure {
      rethrow;
    } on FormatException {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
  }
}

List<Object?> _fallbackReplayBlocks(List<Object?> blocks) {
  var lastFallback = -1;
  for (var index = 0; index < blocks.length; index++) {
    if (wireObject(blocks[index])['type'] == 'fallback') {
      lastFallback = index;
    }
  }
  return <Object?>[
    for (var index = 0; index < blocks.length; index++)
      if (!_discardBeforeFallback(index, lastFallback, blocks[index]))
        blocks[index],
  ];
}

bool _discardBeforeFallback(int index, int lastFallback, Object? value) {
  if (index >= lastFallback) return false;
  final type = wireObject(value)['type'];
  return type == 'thinking' ||
      type == 'redacted_thinking' ||
      type == 'tool_use';
}
