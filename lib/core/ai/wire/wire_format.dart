import 'dart:convert';

import '../ai_endpoint.dart';
import '../ai_events.dart';
import '../ai_failure.dart';
import '../ai_provider.dart';
import '../ai_transcript.dart';
import '../sse.dart';

enum AiToolChoice { auto, none }

final class AiToolSpec {
  AiToolSpec({
    required this.name,
    required this.description,
    required Map<String, Object?> parameters,
  }) : parameters = wireObject(deepFreezeJson(parameters));
  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

final class AiRequestPlan {
  AiRequestPlan({
    required this.model,
    required this.system,
    required this.segment,
    List<AiToolSpec> tools = const [],
    this.toolChoice = AiToolChoice.auto,
    this.maxOutputTokens = 4096,
  }) : tools = List.unmodifiable(tools) {
    if (maxOutputTokens < 2048) {
      throw ArgumentError.value(maxOutputTokens, 'maxOutputTokens');
    }
  }
  final String model;
  final String system;
  final AiSegment segment;
  final List<AiToolSpec> tools;
  final AiToolChoice toolChoice;
  final int maxOutputTokens;
}

final class AiDecodedTurn {
  const AiDecodedTurn(this.output, this.stop, this.usage);
  final ProviderOutputEntry output;
  final AiStopReason stop;
  final AiUsage? usage;
  bool get hasToolCalls => output.toolCalls.isNotEmpty;
}

abstract interface class AiStreamDecoder {
  List<AiEvent> add(SseEvent event);
  AiDecodedTurn finish();
}

final class AiModel {
  const AiModel({required this.id, this.name});
  final String id;
  final String? name;
}

final class AiModelPage {
  AiModelPage({required List<AiModel> models, this.hasMore = false})
    : models = List.unmodifiable(models);
  final List<AiModel> models;
  final bool hasMore;
}

abstract interface class AiWireFormat {
  AiFormat get format;
  List<String> get streamPath;
  Map<String, Object?> encode(AiRequestPlan plan, AiCaps caps);
  List<Object?> encodeEntry(AiEntry entry, AiCaps caps);
  AiStreamDecoder newDecoder();
  AiModelPage decodeModels(Object? json);
  Uri? nextModelsPage(AiEndpoint endpoint, Object? json);
  AiFailure decodeError(int status, Object? json, String? retryAfter);
}

abstract class WireFormatBase implements AiWireFormat {
  const WireFormatBase();

  @override
  AiModelPage decodeModels(Object? json) {
    final body = wireObject(json);
    final models = <AiModel>[];
    for (final value in wireList(body['data'])) {
      final model = wireObject(value);
      final id = model['id'];
      final name = model['display_name'];
      if (id is! String || id.isEmpty || (name != null && name is! String)) {
        throw const AiFailure(AiFailureKind.invalidResponse);
      }
      models.add(AiModel(id: id, name: name as String?));
    }
    return AiModelPage(models: models, hasMore: body['has_more'] == true);
  }

  @override
  Uri? nextModelsPage(AiEndpoint endpoint, Object? json) {
    final body = wireObject(json);
    if (body['has_more'] != true) return null;
    final id = body['last_id'];
    if (id is! String || id.isEmpty) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    final uri = endpoint.modelsOverride ?? endpoint.resolve(['models']);
    return uri.replace(queryParameters: {'after_id': id, 'limit': '100'});
  }

  @override
  AiFailure decodeError(int status, Object? json, String? retryAfter) =>
      decodeWireError(status, json, retryAfter);

  /// Serialize the cached flatMap fragments without re-encoding the prefix.
  String encodeJson(AiRequestPlan plan, AiCaps caps) {
    final body = encode(plan, caps);
    final key = format == AiFormat.responses ? 'input' : 'messages';
    final fragments = <String>[
      if (format == AiFormat.chatCompletions)
        jsonEncode({'role': 'system', 'content': plan.system}),
      for (final fragment in plan.segment.frozenWireJson)
        if (fragment.length > 2) fragment.substring(1, fragment.length - 1),
      if (plan.segment.tail case final AiEntry tail)
        for (final item in encodeEntry(tail, caps)) jsonEncode(item),
    ];
    return '{${body.entries.map((entry) => '${jsonEncode(entry.key)}:${entry.key == key ? '[${fragments.join(',')}]' : jsonEncode(entry.value)}').join(',')}}';
  }
}

List<Object?> encodeWireEntries(
  AiRequestPlan plan,
  AiCaps caps,
  List<Object?> Function(AiEntry, AiCaps) encodeEntry,
) {
  if (plan.segment.model != plan.model || !plan.segment.replayable) {
    throw const AiFailure(AiFailureKind.policyBlocked);
  }
  plan.segment.bindWireConfiguration(
    jsonEncode({
      'system': plan.system,
      'tools': [
        for (final tool in plan.tools)
          {
            'name': tool.name,
            'description': tool.description,
            'parameters': tool.parameters,
          },
      ],
      'replayChatExtras': caps.replayChatExtras,
      'promptCaching': caps.promptCaching,
    }),
  );
  return [
    for (final entry in plan.segment.frozenWire) ...wireList(entry),
    if (plan.segment.tail case final AiEntry tail) ...encodeEntry(tail, caps),
  ];
}

String userEntryText(AppUserEntry entry) =>
    [...entry.context.map((block) => block.text), entry.text].join('\n\n');

Map<String, Object?> wireObject(Object? value) {
  if (value is Map<String, Object?>) return value;
  throw const AiFailure(AiFailureKind.invalidResponse);
}

List<Object?> wireList(Object? value) {
  if (value is List<Object?>) return value;
  throw const AiFailure(AiFailureKind.invalidResponse);
}

Map<String, Object?> wireArguments(String value) {
  try {
    return wireObject(jsonDecode(value));
  } on Object {
    throw const AiFailure(AiFailureKind.interrupted);
  }
}

AiStopReason wireStop(String? value) => switch (value) {
  'length' || 'max_tokens' || 'max_output_tokens' => AiStopReason.maxTokens,
  'content_filter' => AiStopReason.contentFilter,
  'refusal' => AiStopReason.refusal,
  'stop' ||
  'end_turn' ||
  'stop_sequence' ||
  'tool_use' ||
  'tool_calls' ||
  'completed' => AiStopReason.endTurn,
  _ => AiStopReason.other,
};

AiFailure decodeWireError(int status, Object? json, String? retryAfter) {
  // Inspect only known error fields, never retain arbitrary provider text.
  final body = json is Map<String, Object?> ? json : const <String, Object?>{};
  final nested = body['error'];
  final error = nested is Map<String, Object?> ? nested : body;
  final message = '${error['message'] ?? (nested is String ? nested : '')}'
      .toLowerCase();
  final metadata = error['metadata'];
  final metadataRaw =
      metadata is Map<String, Object?> && metadata['raw'] is String
      ? metadata['raw']! as String
      : '';
  final boundedRaw = metadataRaw.length <= 16384
      ? metadataRaw
      : metadataRaw.substring(0, 16384);
  final bindingMessage = '$message\n$boundedRaw'.toLowerCase();
  final code = '${error['code'] ?? error['type'] ?? error['name'] ?? ''}'
      .toLowerCase();
  final invalidThinkingSignature =
      RegExp(
        r'invalid.{0,32}signature.{0,96}thinking.{0,32}block',
      ).hasMatch(bindingMessage) ||
      RegExp(
        r'thinking.{0,32}block.{0,96}invalid.{0,32}signature',
      ).hasMatch(bindingMessage);
  final invalidEncryptedContent =
      code == 'invalid_encrypted_content' ||
      bindingMessage.contains('invalid_encrypted_content') ||
      (bindingMessage.contains('encrypted content') &&
          (bindingMessage.contains('could not be verified') ||
              bindingMessage.contains('could not be decrypted') ||
              bindingMessage.contains('invalid')));
  if (status == 400 &&
      (bindingMessage.contains('bound to a different conversation') ||
          invalidThinkingSignature ||
          invalidEncryptedContent)) {
    return AiFailure(
      AiFailureKind.invalidResponse,
      status: status,
      requiresNewSegment: true,
    );
  }
  if (status == 400 &&
      (code.contains('model_not_found') ||
          code.contains('unsupported_model') ||
          RegExp(
            r'model.{0,80}(unavailable|not found|does not exist|not exist|unsupported|unknown)',
          ).hasMatch(message) ||
          message.contains('unknown model'))) {
    return AiFailure(AiFailureKind.notFound, status: status);
  }
  if (code.contains('context_length') ||
      code.contains('context_window') ||
      message.contains('prompt is too long') ||
      message.contains('maximum context length') ||
      message.contains('context length exceeded') ||
      message.contains('context window exceeded')) {
    return AiFailure(AiFailureKind.contextTooLong, status: status);
  }
  return AiFailure.fromStatus(status, retryAfter: retryAfter);
}
