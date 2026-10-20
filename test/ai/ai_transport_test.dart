import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';

import '../support/fake_adapter.dart';

void main() {
  late AiEndpoint endpoint;
  late Uri responses;

  setUp(() {
    endpoint = AiEndpoint.parse(
      'https://provider.example/v1',
      allowLanCleartext: false,
    );
    responses = Uri.parse('https://provider.example/v1/responses');
  });

  test('uses an independent client and sends only its own key', () async {
    final adapter = FakeAdapter((_) => _bytes('ok'));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'ai-secret',
      authStyle: AiAuthStyle.bearer,
      adapter: adapter,
    );

    final response = await transport.request(responses, json: {'input': 'x'});
    expect(utf8.decode(await _collect(response.stream)), 'ok');
    final request = adapter.requests.single;
    expect(request.headers['Authorization'], 'Bearer ai-secret');
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('private-token')),
    );
    expect(request.followRedirects, isFalse);
    expect(request.maxRedirects, 0);
    expect(request.data, '{"input":"x"}');
    transport.close();
    expect(adapter.closed, isTrue);
  });

  test('supports x-api-key and keyless providers', () async {
    for (final style in [AiAuthStyle.xApiKey, AiAuthStyle.none]) {
      final adapter = FakeAdapter((_) => _bytes('ok'));
      final transport = AiTransport(
        endpoint: endpoint,
        apiKey: 'ai-secret',
        authStyle: style,
        adapter: adapter,
      );
      await _collect((await transport.request(responses)).stream);
      expect(
        adapter.requests.single.headers['x-api-key'],
        style == AiAuthStyle.xApiKey ? 'ai-secret' : isNull,
      );
      transport.close();
    }
  });

  test('uses the Azure api-key header spelling', () async {
    final adapter = FakeAdapter((_) => _bytes('ok'));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'azure-secret',
      authStyle: AiAuthStyle.apiKey,
      adapter: adapter,
    );
    await _collect((await transport.request(responses)).stream);
    expect(adapter.requests.single.headers['api-key'], 'azure-secret');
    expect(adapter.requests.single.headers['Authorization'], isNull);
    transport.close();
  });

  test('blocks disallowed targets before the adapter', () async {
    final adapter = FakeAdapter((_) => throw StateError('must not run'));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    await expectLater(
      transport.request(Uri.parse('https://attacker.example/v1/responses')),
      throwsA(_failure(AiFailureKind.policyBlocked)),
    );
    expect(adapter.requests, isEmpty);
    transport.close();
  });

  test('rejects an oversized request before the adapter', () async {
    final adapter = FakeAdapter((_) => throw StateError('must not run'));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    await expectLater(
      transport.request(responses, json: 'x' * AiTransport.maxRequestBytes),
      throwsA(_failure(AiFailureKind.requestTooLarge)),
    );
    expect(adapter.requests, isEmpty);
    transport.close();
  });

  test('enforces streaming response byte budget', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody(
        Stream.fromIterable([
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ]),
        200,
      ),
    );
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    final response = await transport.request(responses, maxResponseBytes: 3);
    await expectLater(
      response.stream.toList(),
      throwsA(_failure(AiFailureKind.responseTooLarge)),
    );
    transport.close();
  });

  test('stream cancellation cancels the request token', () async {
    final source = StreamController<Uint8List>();
    final adapter = FakeAdapter((_) => ResponseBody(source.stream, 200));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    final response = await transport.request(responses);
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
    await expectLater(adapter.cancelFutures.single, completes);
    await source.close();
    transport.close();
  });

  test('close cancels active requests and refuses new work', () async {
    final source = StreamController<Uint8List>();
    final adapter = FakeAdapter((_) => ResponseBody(source.stream, 200));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    final response = await transport.request(responses);
    final failure = expectLater(
      response.stream.toList(),
      throwsA(_failure(AiFailureKind.cancelled)),
    );
    transport.close();
    await failure;
    await expectLater(adapter.cancelFutures.single, completes);
    await expectLater(
      transport.request(responses),
      throwsA(_failure(AiFailureKind.cancelled)),
    );
    await source.close();
  });

  test(
    'a response first listened after close fails before source data',
    () async {
      final source = StreamController<Uint8List>();
      final adapter = FakeAdapter((_) => ResponseBody(source.stream, 200));
      final transport = AiTransport(
        endpoint: endpoint,
        apiKey: 'key',
        adapter: adapter,
      );
      final response = await transport.request(responses);
      transport.close();
      source.add(Uint8List.fromList([1]));
      await expectLater(
        response.stream.toList(),
        throwsA(_failure(AiFailureKind.cancelled)),
      );
      await source.close();
    },
  );

  test('wall timeout covers a stalled response stream', () async {
    final source = StreamController<Uint8List>();
    final adapter = FakeAdapter((_) => ResponseBody(source.stream, 200));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    final response = await transport.request(
      responses,
      wallTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      response.stream.toList(),
      throwsA(_failure(AiFailureKind.timeout)),
    );
    await source.close();
    transport.close();
  });

  test('redirects are blocked without following them', () async {
    final adapter = FakeAdapter(
      (_) => _bytes(
        '',
        status: 307,
        headers: {
          'location': ['https://x.test'],
        },
      ),
    );
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    await expectLater(
      transport.request(responses),
      throwsA(_failure(AiFailureKind.redirectBlocked)),
    );
    expect(adapter.requests, hasLength(1));
    transport.close();
  });

  test('429 with Retry-After populates the shared registry', () async {
    var now = DateTime.utc(2026, 1, 1);
    final registry = AiRateLimitRegistry();
    final adapter = FakeAdapter(
      (_) => _bytes(
        '',
        status: 429,
        headers: {
          'retry-after': ['60'],
        },
      ),
    );
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
      rateLimits: registry,
      clock: () => now,
    );
    await expectLater(
      transport.request(responses),
      throwsA(_failure(AiFailureKind.rateLimited)),
    );
    await expectLater(
      transport.request(responses),
      throwsA(_failure(AiFailureKind.rateLimited)),
    );
    expect(adapter.requests, hasLength(1));
    now = now.add(const Duration(seconds: 61));
    await expectLater(
      transport.request(responses),
      throwsA(_failure(AiFailureKind.rateLimited)),
    );
    expect(adapter.requests, hasLength(2));
    transport.close();
  });

  test(
    '429 without Retry-After is quota exhaustion and is not cached',
    () async {
      final adapter = FakeAdapter((_) => _bytes('', status: 429));
      final transport = AiTransport(
        endpoint: endpoint,
        apiKey: 'key',
        adapter: adapter,
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          transport.request(responses),
          throwsA(_failure(AiFailureKind.quotaExhausted)),
        );
      }
      expect(adapter.requests, hasLength(2));
      transport.close();
    },
  );

  test('GET models override is bounded and decoded', () async {
    final endpointWithModels = AiEndpoint.parse(
      'https://provider.example/openai/v1',
      allowLanCleartext: false,
      modelsUrlOverride: 'https://provider.example/v1/models',
    );
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': ['model'],
      }),
    );
    final transport = AiTransport(
      endpoint: endpointWithModels,
      apiKey: 'key',
      adapter: adapter,
    );
    final value = await transport.getJson(
      Uri.parse('https://provider.example/v1/models'),
    );
    expect(value, {
      'data': ['model'],
    });
    expect(adapter.requests.single.method, 'GET');
    transport.close();
  });

  test('GET JSON cannot raise the fixed models budget', () async {
    final models = Uri.parse('https://provider.example/v1/models');
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(
        Uint8List(AiTransport.maxModelsBytes + 1),
        200,
      ),
    );
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    await expectLater(
      transport.getJson(models, maxBytes: AiTransport.maxStreamBytes),
      throwsA(_failure(AiFailureKind.responseTooLarge)),
    );
    transport.close();
  });
}

ResponseBody _bytes(
  String text, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromBytes(utf8.encode(text), status, headers: headers);

Future<List<int>> _collect(Stream<Uint8List> stream) async {
  final result = <int>[];
  await for (final chunk in stream) {
    result.addAll(chunk);
  }
  return result;
}

Matcher _failure(AiFailureKind kind) =>
    isA<AiFailure>().having((failure) => failure.kind, 'kind', kind);
