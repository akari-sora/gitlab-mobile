// Provider-only live wire adapter. It never receives GitLab credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
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
    final session = _BudgetSession();
    final transport = AiTransport(
      endpoint: AiEndpoint.parse(config.baseUrl, allowLanCleartext: false),
      apiKey: _providerKey,
      authStyle: config.authStyle,
      adapter: _BudgetAdapter(
        this,
        session,
        _testAdapter ?? IOHttpClientAdapter(),
        ownsInner: _testAdapter == null,
      ),
    );
    return AiWireClient(
      transport: transport,
      wire: _BudgetWireFormat(wire, session),
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

// A client may have only one in-flight completion: this makes the decoder and
// its reservation unambiguously belong to the same request. Other clients can
// still run concurrently against the shared budget.
final class _BudgetSession {
  _BudgetAttempt? active;
}

final class _BudgetAttempt {
  void Function()? settle;
  bool cancelled = false;
  bool sourceComplete = false;
}

final class _BudgetWireFormat extends WireFormatBase {
  const _BudgetWireFormat(this.delegate, this.session);
  final WireFormatBase delegate;
  final _BudgetSession session;

  @override
  AiFormat get format => delegate.format;
  @override
  List<String> get streamPath => delegate.streamPath;
  @override
  Map<String, Object?> encode(AiRequestPlan plan, AiCaps caps) =>
      delegate.encode(plan, caps);
  @override
  String encodeJson(AiRequestPlan plan, AiCaps caps) {
    try {
      return delegate.encodeJson(plan, caps);
    } on Object {
      session.active = null;
      rethrow;
    }
  }

  @override
  List<Object?> encodeEntry(AiEntry entry, AiCaps caps) =>
      delegate.encodeEntry(entry, caps);
  @override
  AiModelPage decodeModels(Object? json) => delegate.decodeModels(json);
  @override
  Uri? nextModelsPage(AiEndpoint endpoint, Object? json) =>
      delegate.nextModelsPage(endpoint, json);
  @override
  AiFailure decodeError(int status, Object? json, String? retryAfter) =>
      delegate.decodeError(status, json, retryAfter);

  @override
  AiStreamDecoder newDecoder() {
    if (session.active != null && !session.active!.sourceComplete) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    final attempt = _BudgetAttempt();
    session.active = attempt;
    return _BudgetDecoder(delegate.newDecoder(), session, attempt);
  }
}

final class _BudgetDecoder implements AiStreamDecoder {
  _BudgetDecoder(this.delegate, this.session, this.attempt);
  final AiStreamDecoder delegate;
  final _BudgetSession session;
  final _BudgetAttempt attempt;

  void _release() {
    if (identical(session.active, attempt)) session.active = null;
  }

  @override
  List<AiEvent> add(SseEvent event) {
    try {
      return delegate.add(event);
    } on Object {
      _release();
      rethrow;
    }
  }

  @override
  AiDecodedTurn finish() {
    try {
      final turn = delegate.finish();
      // A cancellation requested by an event callback is signalled through a
      // future. Let that signal run before considering a reservation refund.
      scheduleMicrotask(() => attempt.settle?.call());
      return turn;
    } finally {
      _release();
    }
  }
}

/// Reserves the complete estimated worst case synchronously before delegation.
/// A failed, incomplete, malformed, or usage-free response keeps the reservation.
final class _BudgetAdapter implements HttpClientAdapter {
  _BudgetAdapter(
    this.owner,
    this.session,
    this.inner, {
    required this.ownsInner,
  });
  final Mr7LiveProvider owner;
  final _BudgetSession session;
  final HttpClientAdapter inner;
  final bool ownsInner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final attempt = session.active;
    try {
      return await _fetch(options, requestStream, cancelFuture);
    } on Object {
      if (identical(session.active, attempt)) session.active = null;
      rethrow;
    }
  }

  Future<ResponseBody> _fetch(
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
    final attempt = session.active;
    if (attempt == null) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    if (cancelFuture != null) {
      unawaited(cancelFuture.then((_) => attempt.cancelled = true));
    }
    final ResponseBody response;
    try {
      response = await inner.fetch(
        options,
        Stream.value(Uint8List.fromList(bytes)),
        cancelFuture,
      );
    } on Object {
      if (identical(session.active, attempt)) session.active = null;
      rethrow;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (identical(session.active, attempt)) session.active = null;
      return response;
    }
    return ResponseBody(
      _observe(response.stream, attempt, item, worst),
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
    _BudgetAttempt attempt,
    Map<String, num> item,
    double reserved,
  ) async* {
    final bytes = <int>[];
    var overflow = false;
    attempt.settle = () {
      if (!overflow && !attempt.cancelled) _settle(bytes, item, reserved);
    };
    var completed = false;
    try {
      await for (final chunk in source) {
        if (bytes.length + chunk.length <= AiTransport.maxStreamBytes) {
          bytes.addAll(chunk);
        } else {
          overflow = true;
        }
        yield chunk;
      }
      completed = true;
      attempt.sourceComplete = true;
    } on Object {
      if (identical(session.active, attempt)) session.active = null;
      rethrow;
    } finally {
      if (!completed && identical(session.active, attempt)) {
        session.active = null;
      }
    }
  }

  void _settle(List<int> bytes, Map<String, num> item, double reserved) {
    int? input, finalOutput;
    final anthropic = owner.config.format == AiFormat.anthropicMessages;
    var terminal = false;
    try {
      final text = utf8.decode(bytes);
      for (final line in const LineSplitter().convert(text)) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') {
          terminal = !anthropic;
          break;
        }
        final value = jsonDecode(payload);
        if (value is! Map) continue;
        final type = value['type'];
        if (anthropic && type == 'message_stop') {
          terminal = true;
          break;
        }
        if (!anthropic) {
          // include_usage reports both totals in the final, empty-choices
          // chunk. Earlier or partial chunks cannot supply missing counts.
          input = null;
          finalOutput = null;
          final choices = value['choices'];
          final usage = value['usage'];
          if (choices is! List || choices.isNotEmpty || usage is! Map) continue;
          final i = usage['prompt_tokens'], o = usage['completion_tokens'];
          if (i is int && i >= 0 && o is int && o >= 0) {
            input = i;
            finalOutput = o;
          }
        } else if (type == 'message_start') {
          // message_start output_tokens is provisional; only its input usage
          // (including disjoint cache counts) belongs to the final bill.
          input = null;
          finalOutput = null;
          final message = value['message'];
          final usage = message is Map ? message['usage'] : null;
          if (usage is! Map) continue;
          final i = usage['input_tokens'];
          if (i is! int || i < 0) continue;
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
        } else if (type == 'message_delta') {
          // Deltas are cumulative. A missing/invalid last count must not fall
          // back to either an earlier delta or the initial output count.
          final usage = value['usage'];
          final o = usage is Map ? usage['output_tokens'] : null;
          finalOutput = o is int && o >= 0 ? o : null;
        }
      }
    } catch (_) {
      return;
    }
    if (!terminal || input == null || finalOutput == null) return;
    final actual = owner._cost(input, finalOutput);
    final next = owner._spent - reserved + actual;
    if (!actual.isFinite || !next.isFinite || next < 0) {
      owner._invalidAccounting = true;
      return;
    }
    item.addAll({
      'inputTokens': input,
      'outputTokens': finalOutput,
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
