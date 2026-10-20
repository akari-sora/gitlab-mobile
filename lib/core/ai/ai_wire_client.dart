import 'dart:async';

import 'ai_endpoint.dart';
import 'ai_events.dart';
import 'ai_failure.dart';
import 'ai_provider.dart';
import 'ai_transport.dart';
import 'sse.dart';
import 'wire/wire_format.dart';

/// A conversation-scoped adapter client. It never owns conversation history or
/// executes tools; the runner decides whether/when to freeze a completed turn.
final class AiWireClient {
  AiWireClient({
    required this.transport,
    required this.wire,
    required this.config,
    required this.conversationId,
    required this.appVersion,
  }) {
    final configuredEndpoint = AiEndpoint.parse(
      config.baseUrl,
      allowLanCleartext: config.allowLanCleartext,
      modelsUrlOverride: config.modelsUrl,
    );
    if (wire.format != config.format ||
        transport.authStyle != config.authStyle ||
        transport.endpoint.modelsOverride !=
            configuredEndpoint.modelsOverride ||
        transport.endpoint.key != configuredEndpoint.key ||
        !RegExp(r'^[A-Za-z0-9_\-]{8,128}$').hasMatch(conversationId) ||
        !RegExp(r'^[A-Za-z0-9.+_\-]+$').hasMatch(appVersion)) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
  }

  final AiTransport transport;
  final WireFormatBase wire;
  final AiProviderConfig config;
  final String conversationId;
  final String appVersion;

  Map<String, String> get headers => {
    if (config.format == AiFormat.anthropicMessages)
      'anthropic-version': '2023-06-01',
    if (config.presetId == 'opencode-go') ...{
      'x-opencode-session': conversationId,
      'User-Agent': 'Mergeline/$appVersion',
    },
  };

  Future<AiDecodedTurn> complete(
    AiRequestPlan plan, {
    void Function(AiEvent)? onEvent,
  }) async {
    if (plan.model != config.model ||
        plan.segment.format != config.format ||
        plan.segment.providerId != config.id ||
        plan.segment.recipientRevision != config.recipientRevision ||
        (!config.toolsEnabled && plan.tools.isNotEmpty)) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final decoder = wire.newDecoder();
    try {
      final response = await transport.requestModel(
        transport.endpoint.resolve(wire.streamPath),
        json: const <String, Object?>{},
        encodedJson: wire.encodeJson(plan, config.caps),
        maxOutputTokens: plan.maxOutputTokens,
        providerHeaders: headers,
        decodeError: wire.decodeError,
      );
      final events = StreamIterator(const SseDecoder().decode(response.stream));
      AiDecodedTurn? terminalTurn;
      try {
        while (await events.moveNext()) {
          var terminal = false;
          for (final decoded in decoder.add(events.current)) {
            if (decoded is AiFinished) terminal = true;
            onEvent?.call(decoded);
          }
          if (terminal) {
            terminalTurn = decoder.finish();
            break;
          }
        }
      } finally {
        try {
          await events.cancel();
        } on Object {
          // A validated terminal turn is authoritative even when transport
          // cleanup itself reports an error.
        }
      }
      if (terminalTurn != null) return terminalTurn;
      final turn = decoder.finish();
      // Chat-compatible streams may terminate at EOF after finish_reason
      // instead of sending [DONE]. finish() validates that final boundary.
      onEvent?.call(AiFinished(turn.stop, usage: turn.usage));
      return turn;
    } on AiFailure catch (failure) {
      if (failure.requiresNewSegment) plan.segment.invalidateReplay();
      rethrow;
    }
  }

  Future<AiModelPage> listModels() async {
    var uri =
        transport.endpoint.modelsOverride ??
        transport.endpoint.resolve(['models']);
    final visited = <Uri>{};
    final models = <AiModel>[];
    for (var page = 0; page < 3; page++) {
      if (!visited.add(uri) || !transport.endpoint.allows(uri)) {
        throw const AiFailure(AiFailureKind.policyBlocked);
      }
      final json = await transport.getJson(
        uri,
        providerHeaders: headers,
        decodeError: wire.decodeError,
      );
      final decoded = wire.decodeModels(json);
      models.addAll(decoded.models);
      final next = wire.nextModelsPage(transport.endpoint, json);
      if (next == null) return AiModelPage(models: models);
      if (page == 2) return AiModelPage(models: models, hasMore: true);
      uri = next;
    }
    throw const AiFailure(AiFailureKind.invalidResponse);
  }

  Future<void> checkOpenRouterKey() async {
    if (config.presetId != 'openrouter' ||
        !transport.endpoint.allowKeyEndpoint) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    await transport.getJson(
      transport.endpoint.resolve(['key']),
      decodeError: wire.decodeError,
    );
  }
}
