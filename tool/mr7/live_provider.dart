// Provider-only live wire adapter. It never receives GitLab credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

/// One shared budget for all scenario clients in a run. The key belongs solely
/// to this component and never appears in its accounting records.
final class Mr7LiveProvider {
  Mr7LiveProvider(
    Map<String, dynamic> data,
    String providerKey, {
    HttpClientAdapter? adapter,
  }) : _providerKey = providerKey,
       _testAdapter = adapter,
       maxCost = _positive(data['maxCost']),
       priceInputPerMTok = _positive(data['priceInputPerMTok']),
       priceOutputPerMTok = _positive(data['priceOutputPerMTok']),
       maxCalls = _positiveInt(data['maxCalls']),
       config = _config(data) {
    if (providerKey.isEmpty || RegExp(r'\s').hasMatch(providerKey)) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
  }

  final String _providerKey;
  final HttpClientAdapter? _testAdapter;
  final AiProviderConfig config;
  final int maxCalls;
  final double maxCost, priceInputPerMTok, priceOutputPerMTok;
  final List<Map<String, num>> _usage = [];
  double _spent = 0;
  bool _leakDetected = false;
  bool _invalidAccounting = false;

  int get calls => _usage.length;
  double get spend => _spent;
  List<Map<String, num>> get usage => [
    for (final item in _usage) Map.unmodifiable(item),
  ];

  /// True only if the provider key appeared in a body that was then refused.
  bool get leakDetected => _leakDetected;
  WireFormatBase get wire => switch (config.format) {
    AiFormat.chatCompletions => const ChatCompletionsFormat(),
    AiFormat.anthropicMessages => const AnthropicMessagesFormat(),
    _ => throw const AiFailure(AiFailureKind.policyBlocked),
  };

  AiWireClient createClient(String conversationId) {
    final transport = AiTransport(
      endpoint: AiEndpoint.parse(config.baseUrl, allowLanCleartext: false),
      apiKey: _providerKey,
      authStyle: config.authStyle,
      adapter: _BudgetAdapter(
        this,
        _testAdapter ?? IOHttpClientAdapter(),
        ownsInner: _testAdapter == null,
      ),
    );
    return AiWireClient(
      transport: transport,
      wire: wire,
      config: config,
      conversationId: conversationId,
      appVersion: aiClientAppVersion,
    );
  }

  double _cost(int input, int output) =>
      (input * priceInputPerMTok + output * priceOutputPerMTok) / 1000000;

  static double _positive(Object? value) {
    if (value is! num || !value.isFinite || value <= 0) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final converted = value.toDouble();
    if (!converted.isFinite || converted <= 0) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    return converted;
  }

  static int _positiveInt(Object? value) {
    if (value is! int || value <= 0) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    return value;
  }

  static AiProviderConfig _config(Map<String, dynamic> data) {
    final format = switch (data['format']) {
      'chat_completions' => AiFormat.chatCompletions,
      'anthropic_messages' => AiFormat.anthropicMessages,
      _ => throw const AiFailure(AiFailureKind.policyBlocked),
    };
    final endpoint = data['endpoint'];
    final model = data['model'];
    final caps = data['caps'];
    final preset = data['preset'] ?? 'custom';
    if (endpoint is! String ||
        model is! String ||
        model.isEmpty ||
        caps is! Map ||
        caps.length != 2 ||
        !caps.containsKey('maxTokens') ||
        caps['tools'] != true ||
        (preset != 'custom' && preset != 'opencode-go') ||
        (preset == 'opencode-go' && format != AiFormat.chatCompletions)) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final parsedEndpoint = AiEndpoint.parse(endpoint, allowLanCleartext: false);
    if (parsedEndpoint.base.scheme != 'https') {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final tokens = _positiveInt(caps['maxTokens']);
    if (tokens < 512 || tokens > 1000000) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    return AiProviderConfig(
      id: 'mr7-live',
      name: 'MR7 live',
      presetId: preset as String,
      baseUrl: endpoint,
      format: format,
      model: model,
      authStyle: format == AiFormat.anthropicMessages
          ? AiAuthStyle.xApiKey
          : AiAuthStyle.bearer,
      caps: AiCaps(
        tokenLimitField: AiTokenLimitField.maxTokens,
        maxOutputTokens: tokens,
        // Usage reporting is mandatory for the harness when supported.
        streamUsage: true,
      ),
      allowLanCleartext: false,
      toolsEnabled: true,
      recipientRevision: 1,
    );
  }
}

/// Reserves the complete estimated worst case synchronously before delegation.
/// A failed, incomplete, malformed, or usage-free response keeps the reservation.
final class _BudgetAdapter implements HttpClientAdapter {
  _BudgetAdapter(this.owner, this.inner, {required this.ownsInner});
  final Mr7LiveProvider owner;
  final HttpClientAdapter inner;
  final bool ownsInner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method != 'POST' || requestStream == null) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    final bytes = <int>[];
    await for (final chunk in requestStream) {
      bytes.addAll(chunk);
      if (bytes.length > AiTransport.maxRequestBytes) {
        throw const AiFailure(AiFailureKind.requestTooLarge, notSent: true);
      }
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    if (_containsKey(decoded, owner._providerKey)) {
      owner._leakDetected = true;
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    if (decoded is! Map ||
        decoded['model'] != owner.config.model ||
        decoded['max_tokens'] != owner.config.caps.maxOutputTokens ||
        decoded['stream'] != true) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    // Serialized bytes plus fixed framing overhead is a conservative estimate;
    // it does not rely on a model-specific tokenizer.
    final input = bytes.length + 1024;
    final output = owner.config.caps.maxOutputTokens;
    final worst = owner._cost(input, output);
    final total = owner._spent + worst;
    if (owner._invalidAccounting ||
        owner.calls >= owner.maxCalls ||
        !worst.isFinite ||
        !total.isFinite ||
        total > owner.maxCost) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    final item = <String, num>{
      'inputTokens': input,
      'outputTokens': output,
      'spend': worst,
      'usageEstimated': 1,
    };
    owner._usage.add(item);
    owner._spent = total;
    final response = await inner.fetch(
      options,
      Stream.value(Uint8List.fromList(bytes)),
      cancelFuture,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return response;
    }
    return ResponseBody(
      _observe(response.stream, item, worst),
      response.statusCode,
      headers: response.headers,
      isRedirect: response.isRedirect,
      redirects: response.redirects,
      statusMessage: response.statusMessage,
    );
  }

  static bool _containsKey(Object? value, String key) {
    if (value is String) return value.contains(key);
    if (value is List) return value.any((item) => _containsKey(item, key));
    if (value is Map) {
      return value.entries.any(
        (entry) =>
            _containsKey(entry.key, key) || _containsKey(entry.value, key),
      );
    }
    return false;
  }

  Stream<Uint8List> _observe(
    Stream<Uint8List> source,
    Map<String, num> item,
    double reserved,
  ) async* {
    final bytes = <int>[];
    var overflow = false;
    try {
      await for (final chunk in source) {
        if (bytes.length + chunk.length <= AiTransport.maxStreamBytes) {
          bytes.addAll(chunk);
        } else {
          overflow = true;
        }
        yield chunk;
      }
    } finally {
      if (!overflow) _settle(bytes, item, reserved);
    }
  }

  void _settle(List<int> bytes, Map<String, num> item, double reserved) {
    int? input, output;
    var terminal = false;
    try {
      final text = utf8.decode(bytes);
      for (final line in const LineSplitter().convert(text)) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') {
          terminal = true;
          continue;
        }
        final value = jsonDecode(payload);
        if (value is! Map) continue;
        final type = value['type'];
        if (type == 'message_stop') terminal = true;
        final usage = type == 'message_start' && value['message'] is Map
            ? (value['message'] as Map)['usage']
            : value['usage'];
        if (usage is! Map) continue;
        final inKey = owner.config.format == AiFormat.anthropicMessages
            ? 'input_tokens'
            : 'prompt_tokens';
        final outKey = owner.config.format == AiFormat.anthropicMessages
            ? 'output_tokens'
            : 'completion_tokens';
        final i = usage[inKey], o = usage[outKey];
        if (i is int && i >= 0) {
          final created = usage['cache_creation_input_tokens'];
          final read = usage['cache_read_input_tokens'];
          if ((created != null && (created is! int || created < 0)) ||
              (read != null && (read is! int || read < 0))) {
            return;
          }
          final subtotal = i + ((created as int?) ?? 0);
          final total = subtotal + ((read as int?) ?? 0);
          if (subtotal < i || total < subtotal) return;
          input = total;
        }
        if (o is int && o >= 0) output = o;
      }
    } catch (_) {
      return;
    }
    if (!terminal || input == null || output == null) return;
    final actual = owner._cost(input, output);
    final next = owner._spent - reserved + actual;
    if (!actual.isFinite || !next.isFinite || next < 0) {
      owner._invalidAccounting = true;
      return;
    }
    item.addAll({
      'inputTokens': input,
      'outputTokens': output,
      'spend': actual,
      'usageEstimated': 0,
    });
    owner._spent = next;
  }

  @override
  void close({bool force = false}) {
    if (ownsInner) inner.close(force: force);
  }
}
