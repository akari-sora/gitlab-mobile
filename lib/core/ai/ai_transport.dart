import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'ai_endpoint.dart';
import 'ai_failure.dart';
import 'ai_provider.dart';

typedef AiErrorDecoder =
    AiFailure Function(int status, Object? json, String? retryAfter);

/// Process-local rate-limit state. It contains no response bodies or secrets.
final class AiRateLimitRegistry {
  final Map<String, DateTime> _until = {};

  DateTime? retryAt(AiEndpoint endpoint, {DateTime? now}) {
    final value = _until[endpoint.key];
    if (value == null) return null;
    if (!(now ?? DateTime.now()).isBefore(value)) {
      _until.remove(endpoint.key);
      return null;
    }
    return value;
  }

  void remember(AiEndpoint endpoint, DateTime retryAt) {
    _until[endpoint.key] = retryAt;
  }

  void clear(AiEndpoint endpoint) => _until.remove(endpoint.key);
}

final class AiTransportResponse {
  const AiTransportResponse({
    required this.statusCode,
    required this.headers,
    required this.stream,
  });

  final int statusCode;
  final Headers headers;
  final Stream<Uint8List> stream;
}

/// A provider-only client. It owns an independent Dio instance and one key.
final class AiTransport {
  AiTransport({
    required this.endpoint,
    required this.apiKey,
    this.authStyle = AiAuthStyle.bearer,
    AiRateLimitRegistry? rateLimits,
    HttpClientAdapter? adapter,
    DateTime Function()? clock,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration idleTimeout = const Duration(seconds: 180),
  }) : rateLimits = rateLimits ?? AiRateLimitRegistry(),
       _clock = clock ?? DateTime.now,
       _dio = Dio(
         BaseOptions(
           connectTimeout: connectTimeout,
           receiveTimeout: idleTimeout,
           sendTimeout: connectTimeout,
         ),
       ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  static const int maxRequestBytes = 4 * 1024 * 1024;
  static const int maxErrorBytes = 64 * 1024;
  static const int maxModelsBytes = 4 * 1024 * 1024;
  static const int minStreamBytes = 4 * 1024 * 1024;
  static const int maxStreamBytes = 16 * 1024 * 1024;
  static const Duration modelWallTimeout = Duration(minutes: 5);

  final AiEndpoint endpoint;
  final String apiKey;
  final AiAuthStyle authStyle;
  final AiRateLimitRegistry rateLimits;
  final DateTime Function() _clock;
  final Dio _dio;
  final Set<CancelToken> _requests = {};
  final Set<Timer> _timers = {};
  bool _closed = false;

  static int streamBudget(int maxOutputTokens) =>
      (maxOutputTokens * 512).clamp(minStreamBytes, maxStreamBytes);

  Future<AiTransportResponse> requestModel(
    Uri uri, {
    required Object json,
    required int maxOutputTokens,
    Duration wallTimeout = modelWallTimeout,
    Map<String, String> providerHeaders = const {},
    String? encodedJson,
    AiErrorDecoder? decodeError,
  }) => request(
    uri,
    json: json,
    maxResponseBytes: streamBudget(maxOutputTokens),
    wallTimeout: wallTimeout,
    providerHeaders: providerHeaders,
    encodedJson: encodedJson,
    decodeError: decodeError,
  );

  Future<AiTransportResponse> request(
    Uri uri, {
    String method = 'POST',
    Object? json,
    int maxResponseBytes = maxStreamBytes,
    Duration wallTimeout = modelWallTimeout,
    String accept = 'text/event-stream',
    Map<String, String> providerHeaders = const {},
    String? encodedJson,
    AiErrorDecoder? decodeError,
  }) async {
    // Refusals before the request is handed to the network say so.
    if (_closed) {
      throw const AiFailure(AiFailureKind.cancelled, notSent: true);
    }
    if (!endpoint.allows(uri, method: method)) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    final until = rateLimits.retryAt(endpoint, now: _clock());
    if (until != null) {
      throw AiFailure(
        AiFailureKind.rateLimited,
        status: 429,
        retryAt: until,
        notSent: true,
      );
    }
    if (maxResponseBytes < 0) {
      throw const AiFailure(AiFailureKind.policyBlocked, notSent: true);
    }
    final responseLimit = maxResponseBytes.clamp(0, maxStreamBytes);
    final encoded = encodedJson ?? (json == null ? null : jsonEncode(json));
    if (encoded != null && utf8.encode(encoded).length > maxRequestBytes) {
      throw const AiFailure(AiFailureKind.requestTooLarge, notSent: true);
    }
    final safeProviderHeaders = _providerHeaders(providerHeaders);
    final token = CancelToken();
    _requests.add(token);
    var wallTimedOut = false;
    var handedOff = false;
    late final Timer timer;
    timer = Timer(wallTimeout, () {
      wallTimedOut = true;
      if (!token.isCancelled) token.cancel('AI request wall timeout');
      _requests.remove(token);
      _timers.remove(timer);
    });
    _timers.add(timer);
    try {
      final response = await runZoned(
        () => _dio.requestUri<ResponseBody>(
          uri,
          data: encoded,
          cancelToken: token,
          options: Options(
            method: method.toUpperCase(),
            responseType: ResponseType.stream,
            contentType: encoded == null ? null : Headers.jsonContentType,
            followRedirects: false,
            maxRedirects: 0,
            validateStatus: (status) => status != null,
            headers: {
              'Accept': accept,
              'Cache-Control': 'no-store',
              ...safeProviderHeaders,
              ..._authHeaders,
            },
          ),
        ),
        zoneValues: {#flutter.io.allow_http: endpoint.cleartext},
      );
      if (_closed) {
        final body = response.data;
        if (body != null) await _release(body);
        throw const AiFailure(AiFailureKind.cancelled);
      }
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        final error = await _readError(response.data, maxErrorBytes, token);
        timer.cancel();
        if (wallTimedOut) throw const AiFailure(AiFailureKind.timeout);
        if (_closed || (token.isCancelled && !error.limitReached)) {
          throw const AiFailure(AiFailureKind.cancelled);
        }
        final retryAfter = _singleHeader(response.headers, 'retry-after');
        // Rate-limit timing stays tied to this client's clock. Other provider
        // classifications inspect bounded JSON, which is never retained.
        final failure = status == 429 || decodeError == null
            ? AiFailure.fromStatus(status, retryAfter: retryAfter, now: _clock())
            : decodeError(status, error.json, retryAfter);
        if (status == 429 && retryAfter != null && failure.retryAt != null) {
          rateLimits.remember(endpoint, failure.retryAt!);
        }
        throw failure;
      }
      final body = response.data;
      if (body == null) {
        timer.cancel();
        throw const AiFailure(AiFailureKind.invalidResponse);
      }
      String? contentLengthValue;
      try {
        contentLengthValue = _singleHeader(
          response.headers,
          Headers.contentLengthHeader,
        );
      } on AiFailure {
        timer.cancel();
        if (!token.isCancelled) token.cancel('Invalid AI content length');
        await _release(body);
        rethrow;
      }
      final contentLength = contentLengthValue == null
          ? null
          : int.tryParse(contentLengthValue);
      if (contentLengthValue != null &&
          (contentLength == null || contentLength < 0)) {
        timer.cancel();
        if (!token.isCancelled) token.cancel('Invalid AI content length');
        await _release(body);
        throw const AiFailure(AiFailureKind.invalidResponse);
      }
      if (contentLength != null && contentLength > responseLimit) {
        timer.cancel();
        if (!token.isCancelled) token.cancel('AI response exceeds byte limit');
        await _release(body);
        throw const AiFailure(AiFailureKind.responseTooLarge);
      }
      handedOff = true;
      return AiTransportResponse(
        statusCode: status,
        headers: response.headers,
        stream: _bounded(
          body.stream,
          token: token,
          timer: timer,
          maxBytes: responseLimit,
          wallTimedOut: () => wallTimedOut,
        ),
      );
    } on AiFailure {
      rethrow;
    } on DioException catch (error) {
      timer.cancel();
      final underlying = error.error;
      if (underlying is UnsupportedError) throw underlying;
      if (_closed) throw const AiFailure(AiFailureKind.cancelled);
      if (wallTimedOut || _isTimeout(error)) {
        throw const AiFailure(AiFailureKind.timeout);
      }
      if (CancelToken.isCancel(error)) {
        throw const AiFailure(AiFailureKind.cancelled);
      }
      throw const AiFailure(AiFailureKind.network);
    } on UnsupportedError {
      timer.cancel();
      rethrow;
    } on IOException {
      timer.cancel();
      if (_closed) throw const AiFailure(AiFailureKind.cancelled);
      throw const AiFailure(AiFailureKind.network);
    } finally {
      if (!handedOff) timer.cancel();
      // Successful streams retain their token until their subscription ends.
      if (timer.isActive && token.isCancelled) timer.cancel();
      if (!timer.isActive || token.isCancelled) {
        _requests.remove(token);
        _timers.remove(timer);
      }
    }
  }

  Future<Object?> getJson(
    Uri uri, {
    int maxBytes = maxModelsBytes,
    Map<String, String> providerHeaders = const {},
    AiErrorDecoder? decodeError,
  }) async {
    if (maxBytes < 0) throw const AiFailure(AiFailureKind.policyBlocked);
    final response = await request(
      uri,
      method: 'GET',
      maxResponseBytes: maxBytes.clamp(0, maxModelsBytes),
      accept: Headers.jsonContentType,
      providerHeaders: providerHeaders,
      decodeError: decodeError,
    );
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
    }
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
  }

  /// Cancel in-flight requests while keeping this conversation transport usable.
  void cancelActive() {
    for (final token in _requests.toList()) {
      if (!token.isCancelled) token.cancel('AI transport closed');
    }
    for (final timer in _timers) {
      timer.cancel();
    }
    _requests.clear();
    _timers.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    cancelActive();
    _dio.close(force: true);
  }

  Map<String, String> get _authHeaders => switch (authStyle) {
    AiAuthStyle.bearer => {'Authorization': 'Bearer $apiKey'},
    AiAuthStyle.apiKey => {'api-key': apiKey},
    AiAuthStyle.xApiKey => {'x-api-key': apiKey},
    AiAuthStyle.none => const {},
  };

  static Map<String, String> _providerHeaders(Map<String, String> headers) {
    const allowed = {
      'anthropic-version', 'anthropic-beta', 'x-opencode-session', 'user-agent',
    };
    final names = <String>{};
    for (final entry in headers.entries) {
      final normalized = entry.key.toLowerCase();
      if (!allowed.contains(normalized) ||
          !names.add(normalized) ||
          entry.value.contains('\r') ||
          entry.value.contains('\n') ||
          (normalized == 'user-agent' &&
              !RegExp(r'^Mergeline/[A-Za-z0-9.+_\-]+$').hasMatch(entry.value))) {
        throw const AiFailure(AiFailureKind.policyBlocked);
      }
    }
    return Map.unmodifiable(headers);
  }

  static String? _singleHeader(Headers headers, String name) {
    final values = headers[name];
    if (values == null || values.isEmpty) return null;
    if (values.length != 1) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    return values.single;
  }

  Stream<Uint8List> _bounded(
    Stream<Uint8List> source, {
    required CancelToken token,
    required Timer timer,
    required int maxBytes,
    required bool Function() wallTimedOut,
  }) {
    late StreamController<Uint8List> controller;
    StreamSubscription<Uint8List>? subscription;
    var received = 0;
    var finished = false;

    Future<void> finish({Object? error, StackTrace? stack}) async {
      if (finished) return;
      finished = true;
      timer.cancel();
      _timers.remove(timer);
      _requests.remove(token);
      if (error != null) controller.addError(error, stack);
      await controller.close();
    }

    controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        if (token.isCancelled) {
          unawaited(
            finish(
              error: wallTimedOut()
                  ? const AiFailure(AiFailureKind.timeout)
                  : const AiFailure(AiFailureKind.cancelled),
            ),
          );
          return;
        }
        unawaited(
          token.whenCancel.then((_) async {
            if (finished) return;
            await subscription?.cancel();
            await finish(
              error: wallTimedOut()
                  ? const AiFailure(AiFailureKind.timeout)
                  : const AiFailure(AiFailureKind.cancelled),
            );
          }),
        );
        if (token.isCancelled) return;
        subscription = source.listen(
          (chunk) {
            if (finished) return;
            received += chunk.length;
            if (received > maxBytes) {
              unawaited(subscription?.cancel());
              unawaited(
                finish(error: const AiFailure(AiFailureKind.responseTooLarge)),
              );
              if (!token.isCancelled) {
                token.cancel('AI response exceeds byte limit');
              }
              return;
            }
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            final mapped = _streamFailure(
              error,
              closed: _closed,
              cancelled: token.isCancelled,
              timedOut: wallTimedOut(),
            );
            unawaited(finish(error: mapped, stack: stack));
          },
          onDone: () {
            unawaited(finish());
          },
          cancelOnError: true,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        if (finished) return;
        finished = true;
        timer.cancel();
        _timers.remove(timer);
        _requests.remove(token);
        await subscription?.cancel();
        if (!token.isCancelled) token.cancel('AI response stream cancelled');
      },
    );
    return controller.stream;
  }

  static Object _streamFailure(
    Object error, {
    required bool closed,
    required bool cancelled,
    required bool timedOut,
  }) {
    if (error is AiFailure) return error;
    if (timedOut) return const AiFailure(AiFailureKind.timeout);
    if (closed || cancelled) return const AiFailure(AiFailureKind.cancelled);
    if (error is DioException && _isTimeout(error)) {
      return const AiFailure(AiFailureKind.timeout);
    }
    return const AiFailure(AiFailureKind.interrupted);
  }

  static bool _isTimeout(DioException error) =>
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout;

  /// Reads at most [maxBytes] of an error body and decodes it as JSON when it
  /// is complete. Reaching the limit stops reading and cancels the request
  /// token, so the connection is released; the status mapping then decides.
  static Future<({Object? json, bool limitReached})> _readError(
    ResponseBody? body,
    int maxBytes,
    CancelToken token,
  ) async {
    if (body == null) return (json: null, limitReached: false);
    var read = 0;
    var limitReached = maxBytes == 0;
    var complete = false;
    final bytes = <int>[];
    Object? json;
    final iterator = StreamIterator<Uint8List>(body.stream);
    try {
      while (!limitReached) {
        final step = await Future.any<Object?>([
          iterator.moveNext(),
          token.whenCancel.then<Object?>((_) => null),
        ]);
        if (step != true) {
          complete = step == false;
          break;
        }
        read += iterator.current.length;
        if (read >= maxBytes) {
          limitReached = true;
          break;
        }
        bytes.addAll(iterator.current);
      }
      if (complete) json = jsonDecode(utf8.decode(bytes));
    } on Object {
      // The bounded status mapping remains authoritative if the body is unreadable.
    } finally {
      await iterator.cancel();
    }
    if (limitReached && !token.isCancelled) {
      token.cancel('AI error response exceeds byte limit');
    }
    return (json: json, limitReached: limitReached);
  }

  static Future<void> _release(ResponseBody body) async {
    try {
      final subscription = body.stream.listen(
        null,
        onError: (Object _, StackTrace _) {},
      );
      await subscription.cancel();
    } on Object {
      return;
    }
  }
}
