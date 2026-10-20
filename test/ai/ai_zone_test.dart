import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';

final _httpOverridesCleared = (() {
  HttpOverrides.global = null;
  return true;
})();

void main() {
  test(
    'the false allow-http zone encloses the actual adapter request',
    () async {
      expect(_httpOverridesCleared, isTrue);
      final adapter = _ZoneProbeAdapter();
      final endpoint = AiEndpoint.parse(
        'https://provider.example/v1',
        allowLanCleartext: false,
      );
      final transport = AiTransport(
        endpoint: endpoint,
        apiKey: 'key',
        adapter: adapter,
      );

      await expectLater(
        transport.request(Uri.parse('https://provider.example/v1/responses')),
        throwsA(isA<UnsupportedError>()),
      );
      expect(adapter.sawFalseZone, isTrue);
      expect(adapter.connectionAttempted, isFalse);
      transport.close();
    },
  );

  test('the true allow-http zone encloses a LAN adapter request', () async {
    final adapter = _RecordingZoneAdapter();
    final endpoint = AiEndpoint.parse(
      'http://127.0.0.1:11434/v1',
      allowLanCleartext: true,
    );
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: '',
      adapter: adapter,
    );

    final response = await transport.request(
      Uri.parse('http://127.0.0.1:11434/v1/responses'),
    );
    await response.stream.drain<void>();

    expect(adapter.zoneValue, isTrue);
    transport.close();
  });
}

final class _RecordingZoneAdapter implements HttpClientAdapter {
  Object? zoneValue;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    zoneValue = Zone.current[#flutter.io.allow_http];
    return ResponseBody.fromBytes(Uint8List(0), 200);
  }

  @override
  void close({bool force = false}) {}
}

final class _ZoneProbeAdapter implements HttpClientAdapter {
  bool sawFalseZone = false;
  bool connectionAttempted = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sawFalseZone = Zone.current[#flutter.io.allow_http] == false;
    final client = HttpClient();
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      connectionAttempted = true;
      throw StateError('socket creation must remain unreachable');
    };
    try {
      await client.openUrl('GET', Uri.parse('http://192.0.2.1/probe'));
      throw StateError('cleartext request was unexpectedly allowed');
    } finally {
      client.close(force: true);
    }
  }

  @override
  void close({bool force = false}) {}
}
