import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'ai_endpoint.dart';
import 'ai_failure.dart';
import 'ai_provider.dart';

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
  }) => request(
    uri,
    json: json,
    maxResponseBytes: streamBudget(maxOutputTokens),
    wallTimeout: wallTimeout,
    providerHeaders: providerHeaders,
  );

  Future<AiTransportResponse> request(
    Uri uri, {
    String method = 'POST',
    Object? json,
    int maxResponseBytes = maxStreamBytes,
    Duration wallTimeout = modelWallTimeout,
    String accept = 'text/event-stream',
    Map<String, String> providerHeaders = const {},
  }) async {
    if (_closed) throw const AiFailure(AiFailureKind.cancelled);
    if (!endpoint.allows(uri, method: method)) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final until = rateLimits.retryAt(endpoint, now: _clock());
    if (until != null) {
      throw AiFailure(AiFailureKind.rateLimited, status: 429, retryAt: until);
    }
    if (maxResponseBytes < 0) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final responseLimit = maxResponseBytes.clamp(0, maxStreamBytes);
    final encoded = json == null ? null : jsonEncode(json);
    if (encoded != null && utf8.encode(encoded).length > maxRequestBytes) {
      throw const AiFailure(AiFailureKind.requestTooLarge);
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
        await _discard(response.data, maxErrorBytes, token);
        timer.cancel();
        if (wallTimedOut) throw const AiFailure(AiFailureKind.timeout);
        final retryAfter = response.headers.value('retry-after');
        final failure = AiFailure.fromStatus(
          status,
          retryAfter: retryAfter,
          now: _clock(),
        );
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
      final contentLength = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
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
  }) async {
    if (maxBytes < 0) throw const AiFailure(AiFailureKind.policyBlocked);
    final response = await request(
      uri,
      method: 'GET',
      maxResponseBytes: maxBytes.clamp(0, maxModelsBytes),
      accept: Headers.jsonContentType,
      providerHeaders: providerHeaders,
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

  void close() {
    if (_closed) return;
    _closed = true;
    for (final token in _requests.toList()) {
      if (!token.isCancelled) token.cancel('AI transport closed');
    }
    for (final timer in _timers) {
      timer.cancel();
    }
    _requests.clear();
    _timers.clear();
    _dio.close(force: true);
  }

  Map<String, String> get _authHeaders => switch (authStyle) {
    AiAuthStyle.bearer => {'Authorization': 'Bearer $apiKey'},
    AiAuthStyle.apiKey => {'api-key': apiKey},
    AiAuthStyle.xApiKey => {'x-api-key': apiKey},
    AiAuthStyle.none => const {},
  };

  static Map<String, String> _providerHeaders(Map<String, String> headers) {
    const allowed = {'anthropic-version', 'anthropic-beta'};
    if (headers.keys.any((name) => !allowed.contains(name.toLowerCase()))) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    return Map.unmodifiable(headers);
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
    return const AiFailure(AiFailureKind.network);
  }

  static bool _isTimeout(DioException error) =>
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout;

  static Future<void> _discard(
    ResponseBody? body,
    int maxBytes,
    CancelToken token,
  ) async {
    if (body == null) return;
    var read = 0;
    final iterator = StreamIterator<Uint8List>(body.stream);
    try {
      while (read <= maxBytes) {
        final step = await Future.any<Object?>([
          iterator.moveNext(),
          token.whenCancel.then<Object?>((_) => null),
        ]);
        if (step != true) break;
        read += iterator.current.length;
      }
    } on Object {
      return;
    } finally {
      await iterator.cancel();
    }
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
