import 'dart:convert';

import '../ai_events.dart';
import '../ai_failure.dart';
import '../ai_provider.dart';
import '../ai_transcript.dart';
import '../sse.dart';
import 'wire_format.dart';

final class ResponsesFormat extends WireFormatBase {
  const ResponsesFormat();
  @override
  AiFormat get format => AiFormat.responses;
  @override
  List<String> get streamPath => const ['responses'];

  @override
  Map<String, Object?> encode(AiRequestPlan plan, AiCaps caps) {
    if (plan.segment.format != format) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    return {
      'model': plan.model,
      'instructions': plan.system,
      'input': encodeWireEntries(plan, caps, encodeEntry),
      'stream': true,
      'store': false,
      'max_output_tokens': plan.maxOutputTokens,
      if (caps.includeEncryptedReasoning)
        'include': ['reasoning.encrypted_content'],
      if (plan.tools.isNotEmpty) ...{
        'tools': [
          for (final tool in plan.tools)
            {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
        ],
        if (caps.toolChoice) 'tool_choice': plan.toolChoice.name,
      },
    };
  }

  @override
  List<Object?> encodeEntry(AiEntry entry, AiCaps caps) => switch (entry) {
    AppUserEntry() => [_user(userEntryText(entry))],
    ProviderOutputEntry() =>
      entry.format == format
          ? wireList(entry.raw)
          : throw const AiFailure(AiFailureKind.policyBlocked),
    AppToolResultsEntry() => [
      for (final result in entry.results)
        {
          'type': 'function_call_output',
          'call_id': result.callId,
          'output': result.content,
        },
      if (entry.followUpText case final String text) _user(text),
    ],
  };

  static Map<String, Object?> _user(String text) => {
    'role': 'user',
    'content': [
      {'type': 'input_text', 'text': text},
    ],
  };

  @override
  AiStreamDecoder newDecoder() => ResponsesStreamDecoder();
}

final class ResponsesStreamDecoder implements AiStreamDecoder {
  bool _started = false;
  bool _terminal = false;
  AiFailure? _failure;
  AiDecodedTurn? _turn;
  int ignoredAfterTerminal = 0;

  @override
  List<AiEvent> add(SseEvent event) {
    if (_terminal) {
      ignoredAfterTerminal++;
      return const [];
    }
    try {
      final data = wireObject(jsonDecode(event.data));
      final type = data['type'] ?? event.event;
      final events = <AiEvent>[];
      if (type == 'response.queued') return events;
      if (!_started) {
        _started = true;
        events.add(const AiStarted());
      }
      switch (type) {
        case 'response.created' || 'response.in_progress':
          break;
        case 'response.output_item.added' || 'response.output_item.done':
          _index(data);
          final item = wireObject(data['item']);
          if (item['type'] == 'reasoning') {
            events.add(const AiReasoningActive());
          }
          break;
        case 'response.output_text.delta':
          final delta = data['delta'];
          if (delta is! String) {
            throw const AiFailure(AiFailureKind.invalidResponse);
          }
          events.add(AiTextDelta(delta));
          break;
        case 'response.refusal.delta':
          final delta = data['delta'];
          if (delta is! String) {
            throw const AiFailure(AiFailureKind.invalidResponse);
          }
          events.add(AiRefusalDelta(delta));
          break;
        case 'response.reasoning_summary_text.delta' ||
            'response.reasoning_text.delta':
          events.add(const AiReasoningActive());
          break;
        case 'response.function_call_arguments.delta':
          _index(data);
          final delta = data['delta'];
          if (delta is! String) {
            throw const AiFailure(AiFailureKind.invalidResponse);
          }
          break;
        case 'response.function_call_arguments.done':
          _index(data);
          final arguments = data['arguments'];
          if (arguments is! String) {
            throw const AiFailure(AiFailureKind.invalidResponse);
          }
          break;
        case 'response.completed' || 'response.incomplete':
          final response = wireObject(data['response']);
          final output = wireList(response['output']);
          final calls = <AiToolCall>[];
          var refused = false;
          for (final value in output) {
            final item = wireObject(value);
            if (item['type'] == 'message') {
              for (final part in wireList(item['content'])) {
                if (wireObject(part)['type'] == 'refusal') refused = true;
              }
            }
            if (item['type'] != 'function_call') continue;
            final id = item['call_id'];
            final name = item['name'];
            final arguments = item['arguments'];
            if (id is! String ||
                id.isEmpty ||
                name is! String ||
                name.isEmpty ||
                arguments is! String ||
                item['status'] != 'completed') {
              throw const AiFailure(AiFailureKind.interrupted);
            }
            calls.add(
              AiToolCall(
                id: id,
                name: name,
                arguments: wireArguments(arguments),
              ),
            );
          }
          final details = response['incomplete_details'];
          final reason = type == 'response.incomplete'
              ? wireStop(
                  details is Map<String, Object?>
                      ? details['reason'] as String?
                      : null,
                )
              : refused
              ? AiStopReason.refusal
              : AiStopReason.endTurn;
          final usage = _usage(response['usage']);
          // Only terminal output is authoritative. In particular encrypted
          // reasoning may differ from output_item.done (different ciphertext).
          _turn = AiDecodedTurn(
            ProviderOutputEntry(AiFormat.responses, output, toolCalls: calls),
            reason,
            usage,
          );
          _terminal = true;
          if (usage != null) events.add(AiUsageUpdated(usage));
          events.add(AiFinished(reason, usage: usage));
          break;
        case 'response.failed' || 'error':
          final response = data['response'];
          final body = response is Map<String, Object?> ? response : data;
          final error = body['error'];
          final server =
              error is Map<String, Object?> &&
              (error['type'] == 'server_error' ||
                  error['code'] == 'server_error');
          _failure = decodeWireError(server ? 500 : 400, body, null);
          _terminal = true;
          throw _failure!;
      }
      return events;
    } on AiFailure catch (error) {
      _failure = error;
      _terminal = true;
      rethrow;
    } on Object {
      _failure = const AiFailure(AiFailureKind.invalidResponse);
      _terminal = true;
      throw _failure!;
    }
  }

  @override
  AiDecodedTurn finish() {
    if (_failure case final AiFailure error) throw error;
    final turn = _turn;
    if (!_terminal || turn == null) {
      _terminal = true;
      _failure = const AiFailure(AiFailureKind.interrupted);
      throw _failure!;
    }
    return turn;
  }

  static int _index(Map<String, Object?> data) {
    final index = data['output_index'];
    if (index is! int || index < 0) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    return index;
  }

  static AiUsage? _usage(Object? json) {
    if (json is! Map<String, Object?>) return null;
    int? count(Object? value) => value is int && value >= 0 ? value : null;

    final input = count(json['input_tokens']);
    final details = json['input_tokens_details'];
    var cached = details is Map<String, Object?>
        ? count(details['cached_tokens'])
        : null;
    if (input == null || (cached != null && cached > input)) {
      cached = null;
    }
    final output = count(json['output_tokens']);
    if (input == null && output == null) return null;

    return AiUsage(
      inputTokens: input == null ? null : input - (cached ?? 0),
      outputTokens: output,
      cacheReadInputTokens: cached,
    );
  }
}
