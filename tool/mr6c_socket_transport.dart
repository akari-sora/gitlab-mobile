// QA-only socket transport. Production main never imports this library.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'mr6c_qa_protocol.dart';

const mr6cSyntheticToken = 'mr6c-synthetic-token';

final class Mr6cFixtureEndpoint {
  Mr6cFixtureEndpoint._(this.host, this.port, this.certificatePem);
  final String host;
  final int port;
  final String certificatePem;

  /// Loopback is an explicit host-test option, never an emulator fallback.
  static Mr6cFixtureEndpoint parse(Object? input, {bool hostTest = false}) {
    if (input is! Map<String, dynamic> ||
        input.length != 4 ||
        !input.keys.toSet().containsAll({
          'host',
          'port',
          'certificate_pem',
          'network_conclusion',
        })) {
      throw const QaProtocolException('invalid_fixture_endpoint');
    }
    final host = input['host'];
    final port = input['port'];
    final pem = input['certificate_pem'];
    final allowedHost =
        host == '10.0.2.2' ||
        hostTest && (host == '127.0.0.1' || host == 'localhost');
    if (!allowedHost ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        pem is! String ||
        pem.length > 16384 ||
        !RegExp(
          r'^-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*$',
        ).hasMatch(pem) ||
        input['network_conclusion'] != 'NOT_VERIFIED') {
      throw const QaProtocolException('invalid_fixture_endpoint');
    }
    return Mr6cFixtureEndpoint._(host as String, port, pem);
  }

  Uri uri(String path) =>
      Uri(scheme: 'https', host: host, port: port, path: path);
}

/// Counters retain neither payloads nor credentials. A shared clock permits
/// provider and GitLab adapters to contribute to the same observation window.
final class Mr6cSocketMetrics {
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object>> _events = [];

  void _record(String kind, [int bytes = 0]) {
    if (_events.length >= 10000) {
      throw const QaProtocolException('fixture_evidence_limit');
    }
    _events.add({
      'kind': kind,
      'elapsed_ms': _clock.elapsedMilliseconds,
      'bytes': bytes,
    });
  }

  Map<String, Object> snapshot() => {
    'schema': 1,
    'duration_ms': _clock.elapsedMilliseconds,
    'events': _events.map((value) => Map<String, Object>.from(value)).toList(),
    'network_conclusion': 'NOT_VERIFIED',
  };
}

/// Inject through AiTransport.adapter or GitLabApi's independent Dio client.
/// Trust consists solely of the session certificate, with ordinary chain and
/// hostname verification. Redirects, proxies and alternate origins are refused.
final class Mr6cSocketAdapter implements HttpClientAdapter {
  Mr6cSocketAdapter(this.endpoint, this.metrics) {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(endpoint.certificatePem));
    _inner = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient(context: context)..findProxy = (_) => 'DIRECT',
    );
  }

  final Mr6cFixtureEndpoint endpoint;
  final Mr6cSocketMetrics metrics;
  late final IOHttpClientAdapter _inner;

  bool _allowed(RequestOptions options) {
    final uri = options.uri;
    if (uri.scheme != 'https' ||
        uri.host != endpoint.host ||
        uri.port != endpoint.port ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.hasQuery) {
      return false;
    }
    for (final entry in options.headers.entries) {
      final name = entry.key.toLowerCase();
      if (name == 'cookie' ||
          name == 'proxy-authorization' ||
          name == 'x-api-key') {
        return false;
      }
      if (name == 'authorization' &&
          entry.value != 'Bearer $mr6cSyntheticToken') {
        return false;
      }
      if (name == 'private-token' && entry.value != mr6cSyntheticToken) {
        return false;
      }
    }
    return switch ((options.method.toUpperCase(), uri.path)) {
      ('POST', '/v1/chat/completions' || '/api/v4/projects/1/issues') => true,
      (
        'GET',
        '/api/v4/user' || '/api/v4/projects/1' || '/api/v4/projects/1/issues/1',
      ) =>
        true,
      _ => false,
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!_allowed(options)) {
      throw const QaProtocolException('fixture_origin_or_credentials');
    }
    final response = await _inner.fetch(
      options.copyWith(followRedirects: false, maxRedirects: 0),
      requestStream,
      cancelFuture,
    );
    if (response.statusCode >= 300 && response.statusCode < 400) {
      await response.stream.listen((_) {}).cancel();
      throw const QaProtocolException('fixture_redirect');
    }
    final sse = options.uri.path == '/v1/chat/completions';
    metrics._record(sse ? 'model_response_headers' : 'gitlab_response_headers');
    final source = response.stream;
    response.stream = _measure(
      source,
      sse: sse,
      successful: response.statusCode >= 200 && response.statusCode < 300,
    );
    return response;
  }

  Stream<Uint8List> _measure(
    Stream<Uint8List> source, {
    required bool sse,
    required bool successful,
  }) async* {
    var suffix = '';
    await for (final chunk in source) {
      metrics._record(
        sse ? 'sse_bytes_received' : 'gitlab_bytes_received',
        chunk.length,
      );
      if (sse && successful) {
        suffix += latin1.decode(chunk);
        const marker = ': heartbeat\n\n';
        var index = suffix.indexOf(marker);
        while (index >= 0) {
          metrics._record('sse_heartbeat_received');
          suffix = suffix.substring(index + marker.length);
          index = suffix.indexOf(marker);
        }
        if (suffix.length > marker.length) {
          suffix = suffix.substring(suffix.length - marker.length);
        }
      }
      yield chunk;
    }
    if (!sse && successful) {
      metrics._record('gitlab_readback_received');
    }
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}
