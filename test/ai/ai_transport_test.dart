import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';

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

  test('allows only the provider header allowlist', () async {
    final adapter = FakeAdapter((_) => _bytes('ok'));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );

    await _collect(
      (await transport.request(
        responses,
        providerHeaders: const {
          'Anthropic-Version': '2023-06-01',
          'anthropic-beta': 'synthetic-feature',
        },
      )).stream,
    );
    expect(adapter.requests.single.headers['Anthropic-Version'], '2023-06-01');
    expect(
      adapter.requests.single.headers['anthropic-beta'],
      'synthetic-feature',
    );
    await expectLater(
      transport.request(
        responses,
        providerHeaders: const {'Private-Token': 'gitlab-secret'},
      ),
      throwsA(_failure(AiFailureKind.policyBlocked)),
    );
    await expectLater(
      transport.request(
        responses,
        providerHeaders: const {
          'Anthropic-Version': '2023-06-01',
          'anthropic-version': '2023-06-01',
        },
      ),
      throwsA(_failure(AiFailureKind.policyBlocked)),
    );
    expect(adapter.requests, hasLength(1));
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
    // The body never arrives, so the wall timeout must fire on the stream.
    // It also runs while the headers are on their way, so keep it far above
    // their latency on a loaded host.
    final response = await transport.request(
      responses,
      wallTimeout: const Duration(seconds: 2),
    );
    // Without the wall timer the stalled stream never ends: fail fast instead.
    await expectLater(
      response.stream.toList().timeout(const Duration(seconds: 20)),
      throwsA(_failure(AiFailureKind.timeout)),
    );
    await source.close();
    transport.close();
  });

  test('idle timeout after headers maps to timeout', () async {
    final source = StreamController<Uint8List>();
    final adapter = FakeAdapter((_) => ResponseBody(source.stream, 200));
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );
    final response = await transport.request(responses);
    final result = response.stream.toList();
    source.addError(
      DioException(
        requestOptions: RequestOptions(path: responses.toString()),
        type: DioExceptionType.receiveTimeout,
      ),
    );
    await source.close();

    await expectLater(result, throwsA(_failure(AiFailureKind.timeout)));
    transport.close();
  });

  test(
    'transport and SSE map a mid-stream disconnect to interrupted',
    () async {
      final source = StreamController<Uint8List>();
      final adapter = FakeAdapter((_) => ResponseBody(source.stream, 200));
      final transport = AiTransport(
        endpoint: endpoint,
        apiKey: 'key',
        adapter: adapter,
      );
      final response = await transport.request(responses);
      final result = const SseDecoder().decode(response.stream).toList();
      source.add(Uint8List.fromList(utf8.encode('data: partial\n\n')));
      source.addError(const SocketException('synthetic disconnect'));
      await source.close();

      await expectLater(result, throwsA(_failure(AiFailureKind.interrupted)));
      transport.close();
    },
  );

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
      throwsA(
        isA<AiFailure>()
            .having((f) => f.kind, 'kind', AiFailureKind.rateLimited)
            .having((f) => f.notSent, 'notSent', isFalse),
      ),
    );
    // Refused locally: the failure says the request never left.
    await expectLater(
      transport.request(responses),
      throwsA(
        isA<AiFailure>()
            .having((f) => f.kind, 'kind', AiFailureKind.rateLimited)
            .having((f) => f.notSent, 'notSent', isTrue),
      ),
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

  for (final status in [401, 429]) {
    test('close during a stalled $status discard returns cancelled', () async {
      final listened = Completer<void>();
      final source = StreamController<Uint8List>(onListen: listened.complete);
      final registry = AiRateLimitRegistry();
      final adapter = FakeAdapter(
        (_) => ResponseBody(
          source.stream,
          status,
          headers: status == 429
              ? {
                  'retry-after': ['60'],
                }
              : const {},
        ),
      );
      final transport = AiTransport(
        endpoint: endpoint,
        apiKey: 'key',
        adapter: adapter,
        rateLimits: registry,
      );
      final request = transport.request(responses);
      await listened.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      transport.close();

      await expectLater(request, throwsA(_failure(AiFailureKind.cancelled)));
      expect(registry.retryAt(endpoint), isNull);
      await source.close();
    });
  }

  for (final status in [401, 429]) {
    test(
      'request cancellation during stalled $status discard stays cancelled',
      () async {
        final listened = Completer<void>();
        final source = StreamController<Uint8List>(onListen: listened.complete);
        final registry = AiRateLimitRegistry();
        final adapter = FakeAdapter(
          (_) => ResponseBody(
            source.stream,
            status,
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
        );
        final request = transport.request(responses);
        await listened.future;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        adapter.requests.single.cancelToken!.cancel('synthetic cancellation');
        await expectLater(request, throwsA(_failure(AiFailureKind.cancelled)));
        expect(registry.retryAt(endpoint), isNull);
        await source.close();
        transport.close();
      },
    );
  }

  test('duplicate Retry-After is contained as invalidResponse', () async {
    final adapter = FakeAdapter(
      (_) => _bytes(
        '',
        status: 429,
        headers: {
          'retry-after': ['1', '2'],
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
      throwsA(_failure(AiFailureKind.invalidResponse)),
    );
    transport.close();
  });

  test('budget-sized discarded error body cancels the request token', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody(
        Stream.fromIterable([Uint8List(AiTransport.maxErrorBytes)]),
        500,
      ),
    );
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );

    await expectLater(
      transport.request(responses),
      throwsA(_failure(AiFailureKind.server)),
    );
    await expectLater(
      adapter.cancelFutures.single!.timeout(const Duration(seconds: 1)),
      completes,
    );
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

  test('Content-Length rejects oversized responses before streaming', () async {
    final source = StreamController<Uint8List>();
    final adapter = FakeAdapter(
      (_) => ResponseBody(
        source.stream,
        200,
        headers: {
          Headers.contentLengthHeader: ['4'],
        },
      ),
    );
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'key',
      adapter: adapter,
    );

    await expectLater(
      transport.request(responses, maxResponseBytes: 3),
      throwsA(_failure(AiFailureKind.responseTooLarge)),
    );
    await expectLater(adapter.cancelFutures.single, completes);
    await source.close();
    transport.close();
  });

  test('duplicate Content-Length is contained as invalidResponse', () async {
    final adapter = FakeAdapter(
      (_) => _bytes(
        'ok',
        headers: {
          Headers.contentLengthHeader: ['2', '3'],
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
      throwsA(_failure(AiFailureKind.invalidResponse)),
    );
    transport.close();
  });

  for (final length in ['invalid', '-1']) {
    test(
      'malformed Content-Length $length is contained as invalidResponse',
      () async {
        final adapter = FakeAdapter(
          (_) => _bytes(
            'ok',
            headers: {
              Headers.contentLengthHeader: [length],
            },
          ),
        );
        final transport = AiTransport(
          endpoint: endpoint,
          apiKey: 'key',
          adapter: adapter,
        );
        addTearDown(transport.close);
        await expectLater(
          transport.request(responses),
          throwsA(_failure(AiFailureKind.invalidResponse)),
        );
      },
    );
  }

  test('stream budget clamps to the fixed minimum and maximum', () {
    expect(AiTransport.streamBudget(0), AiTransport.minStreamBytes);
    expect(AiTransport.streamBudget(8193), 8193 * 512);
    expect(AiTransport.streamBudget(1000000), AiTransport.maxStreamBytes);
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
