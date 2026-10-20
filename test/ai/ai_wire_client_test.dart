import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

import '../support/fake_adapter.dart';

AiProviderConfig config({
  String preset = 'opencode-go',
  String model = 'model',
  String baseUrl = 'https://provider.example/v1',
  String? modelsUrl,
  AiAuthStyle authStyle = AiAuthStyle.bearer,
}) => AiProviderConfig(
  id: 'synthetic',
  name: 'Synthetic',
  presetId: preset,
  baseUrl: baseUrl,
  format: AiFormat.responses,
  model: model,
  modelsUrl: modelsUrl,
  authStyle: authStyle,
  caps: const AiCaps(tokenLimitField: AiTokenLimitField.maxOutputTokens),
  allowLanCleartext: false,
  toolsEnabled: false,
  recipientRevision: 1,
);

AiSegment segment() => AiSegment(
  providerId: 'synthetic',
  recipientRevision: 1,
  format: AiFormat.responses,
  model: 'model',
  secretSetAtStart: SecretSetId.fromSecrets([]),
)..setTail(AppUserEntry(text: 'Synthetic input'));

void main() {
  test(
    'Go headers stay stable across segments and change per conversation',
    () async {
      final adapter = FakeAdapter(
        (_) => ResponseBody(
          Stream.fromIterable([
            Uint8List.fromList(
              utf8.encode(
                'data: {"type":"response.completed","response":{"output":[]}}\n\n',
              ),
            ),
          ]),
          200,
        ),
      );
      final transport = AiTransport(
        endpoint: AiEndpoint.parse(
          'https://provider.example/v1',
          allowLanCleartext: false,
        ),
        apiKey: 'synthetic-key',
        adapter: adapter,
      );
      final client = AiWireClient(
        transport: transport,
        wire: const ResponsesFormat(),
        config: config(),
        conversationId: 'conversation-one',
        appVersion: '0.6.0',
      );
      final events = <AiEvent>[];
      for (var i = 0; i < 2; i++) {
        await client.complete(
          AiRequestPlan(model: 'model', system: 'system', segment: segment()),
          onEvent: events.add,
        );
      }
      for (final request in adapter.requests) {
        expect(request.headers['x-opencode-session'], 'conversation-one');
        expect(request.headers['User-Agent'], 'Mergeline/0.6.0');
        expect(
          jsonDecode(request.data! as String),
          isA<Map<String, Object?>>(),
        );
      }
      final other = AiWireClient(
        transport: transport,
        wire: const ResponsesFormat(),
        config: config(),
        conversationId: 'conversation-two',
        appVersion: '0.6.0',
      );
      expect(
        other.headers['x-opencode-session'],
        isNot(client.headers['x-opencode-session']),
      );
      expect(events.whereType<AiFinished>(), hasLength(2));
      transport.close();
    },
  );

  test(
    'binding 400 invalidates the entire segment regardless of server path',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'message':
                'messages.1.content.4: thinking bound to a different conversation',
          },
        }, status: 400),
      );
      final transport = AiTransport(
        endpoint: AiEndpoint.parse(
          'https://provider.example/v1',
          allowLanCleartext: false,
        ),
        apiKey: 'synthetic-key',
        adapter: adapter,
      );
      final client = AiWireClient(
        transport: transport,
        wire: const ResponsesFormat(),
        config: config(),
        conversationId: 'conversation-one',
        appVersion: '0.6.0',
      );
      final state = segment();
      final plan = AiRequestPlan(model: 'model', system: '', segment: state);
      await expectLater(
        client.complete(plan),
        throwsA(
          isA<AiFailure>().having(
            (error) => error.requiresNewSegment,
            'requiresNewSegment',
            true,
          ),
        ),
      );
      expect(state.replayable, false);
      await expectLater(client.complete(plan), throwsA(isA<AiFailure>()));
      expect(adapter.requests, hasLength(1));
      expect(state.frozenLength, 0);
      transport.close();
    },
  );

  test('terminal completion cancels a source that never closes', () async {
    var cancelled = false;
    late StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () {
        controller.add(
          Uint8List.fromList(
            utf8.encode(
              'data: {"type":"response.completed","response":{"output":[]}}\n\n',
            ),
          ),
        );
      },
      onCancel: () {
        cancelled = true;
      },
    );
    final transport = AiTransport(
      endpoint: AiEndpoint.parse(
        'https://provider.example/v1',
        allowLanCleartext: false,
      ),
      apiKey: 'synthetic-key',
      adapter: FakeAdapter((_) => ResponseBody(controller.stream, 200)),
    );
    addTearDown(transport.close);
    addTearDown(controller.close);
    final client = AiWireClient(
      transport: transport,
      wire: const ResponsesFormat(),
      config: config(),
      conversationId: 'conversation-one',
      appVersion: '0.6.0',
    );

    final turn = await client
        .complete(AiRequestPlan(model: 'model', system: '', segment: segment()))
        .timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);

    expect(turn.stop, AiStopReason.endTurn);
    expect(cancelled, isTrue);
  });

  test(
    'malformed bytes after terminal completion cannot overturn it',
    () async {
      var cancelled = false;
      final terminal = Uint8List.fromList(
        utf8.encode(
          'data: {"type":"response.completed","response":{"output":[]}}\n\n',
        ),
      );
      final source = Stream<Uint8List>.multi((sink) {
        sink.add(terminal);
        sink.add(Uint8List.fromList(const [0xff, 0x0a, 0x0a]));
        sink.close();
        sink.onCancel = () {
          cancelled = true;
        };
      });
      final transport = AiTransport(
        endpoint: AiEndpoint.parse(
          'https://provider.example/v1',
          allowLanCleartext: false,
        ),
        apiKey: 'synthetic-key',
        adapter: FakeAdapter((_) => ResponseBody(source, 200)),
      );
      addTearDown(transport.close);
      final client = AiWireClient(
        transport: transport,
        wire: const ResponsesFormat(),
        config: config(),
        conversationId: 'conversation-one',
        appVersion: '0.6.0',
      );

      final turn = await client.complete(
        AiRequestPlan(model: 'model', system: '', segment: segment()),
      );

      expect(turn.stop, AiStopReason.endTurn);
      expect(cancelled, isTrue);
    },
  );

  test('all supported binding errors invalidate replay', () {
    const wire = ResponsesFormat();
    for (final body in [
      {
        'error': {
          'type': 'invalid_request_error',
          'code': 'invalid_encrypted_content',
          'message': 'Encrypted content could not be verified.',
        },
      },
      {
        'error': {
          'type': 'invalid_request_error',
          'message':
              'Thinking block has an invalid signature and cannot be reused.',
        },
      },
    ]) {
      final failure = wire.decodeError(400, body, null);
      expect(failure.kind, AiFailureKind.invalidResponse);
      expect(failure.requiresNewSegment, isTrue);
    }
  });

  test('OpenRouter metadata.raw binding errors invalidate replay', () {
    final failure = const ResponsesFormat().decodeError(400, <String, Object?>{
      'error': <String, Object?>{
        'message': 'Provider returned an error.',
        'metadata': <String, Object?>{
          'raw':
              'The thinking block is bound to a different conversation and cannot be reused.',
        },
      },
    }, null);

    expect(failure.kind, AiFailureKind.invalidResponse);
    expect(failure.requiresNewSegment, isTrue);

    final nestedCode = const ResponsesFormat().decodeError(
      400,
      <String, Object?>{
        'error': <String, Object?>{
          'message': 'Provider returned an error.',
          'metadata': <String, Object?>{
            'raw': '{"error":{"code":"invalid_encrypted_content"}}',
          },
        },
      },
      null,
    );
    expect(nestedCode.requiresNewSegment, isTrue);

    final beyondBound = const ResponsesFormat().decodeError(400, <
      String,
      Object?
    >{
      'error': <String, Object?>{
        'message': 'Provider returned an error.',
        'metadata': <String, Object?>{
          'raw':
              '${List<String>.filled(16384, 'x').join()} thinking block bound to a different conversation',
        },
      },
    }, null);
    expect(beyondBound.requiresNewSegment, isFalse);
  });

  test('Responses SSE rolls over binding 400 but preserves genuine 500', () {
    final binding = const ResponsesFormat().newDecoder();
    expect(
      () => binding.add(
        SseEvent(
          data: jsonEncode({
            'type': 'response.failed',
            'response': {
              'error': {
                'type': 'invalid_request_error',
                'code': 'invalid_encrypted_content',
                'message': 'Encrypted content could not be verified.',
              },
            },
          }),
        ),
      ),
      throwsA(
        isA<AiFailure>()
            .having((error) => error.status, 'status', 400)
            .having(
              (error) => error.requiresNewSegment,
              'requiresNewSegment',
              isTrue,
            ),
      ),
    );

    final server = const ResponsesFormat().newDecoder();
    expect(
      () => server.add(
        SseEvent(
          data: jsonEncode({
            'type': 'response.failed',
            'response': {
              'error': {
                'type': 'server_error',
                'message':
                    'Upstream request failed: thinking bound to a different conversation.',
              },
            },
          }),
        ),
      ),
      throwsA(
        isA<AiFailure>()
            .having((error) => error.status, 'status', 500)
            .having(
              (error) => error.requiresNewSegment,
              'requiresNewSegment',
              isFalse,
            ),
      ),
    );
  });

  test('three Go body shapes classify unknown model without leaking body', () {
    const wire = ResponsesFormat();
    for (final body in [
      {
        'error': {
          'type': 'server_error',
          'message': 'Upstream request failed: Model is unavailable.',
        },
      },
      {
        'type': 'error',
        'error': {
          'type': 'server_error',
          'message':
              'Upstream request failed: [not_found_error] model: unknown model',
        },
      },
      {
        'model': 'bad-model',
        'error': {'code': 'model_not_found', 'message': 'no such model'},
      },
    ]) {
      final failure = wire.decodeError(400, body, null);
      expect(failure.kind, AiFailureKind.notFound);
      expect(failure.toString(), isNot(contains('Upstream')));
    }
    expect(
      wire.decodeError(400, {
        'type': 'error',
        'error': {'type': 'MissingSessionID'},
      }, null).kind,
      AiFailureKind.invalidResponse,
    );
  });

  test('proxy context-limit wording maps to contextTooLong', () {
    const wire = ResponsesFormat();
    for (final message in [
      'Upstream request failed: maximum context length is 128000 tokens',
      'Upstream request failed: context length exceeded for this model',
      'Upstream request failed: context window exceeded',
    ]) {
      expect(
        wire.decodeError(400, {
          'error': {'type': 'server_error', 'message': message},
        }, null).kind,
        AiFailureKind.contextTooLong,
      );
    }
  });

  test('model pagination is bounded, safe and explicitly truncated', () async {
    final adapter = FakeAdapter(
      (request) => jsonResponse({
        'data': [
          {
            'id': 'model-${request.uri.queryParameters['after_id'] ?? 'first'}',
            'display_name': 'Synthetic',
          },
        ],
        'has_more': true,
        'last_id': 'page-${request.uri.queryParameters['after_id'] ?? 'first'}',
      }),
    );
    final transport = AiTransport(
      endpoint: AiEndpoint.parse(
        'https://provider.example/v1',
        allowLanCleartext: false,
      ),
      apiKey: 'synthetic-key',
      adapter: adapter,
    );
    final client = AiWireClient(
      transport: transport,
      wire: const ResponsesFormat(),
      config: config(),
      conversationId: 'conversation-one',
      appVersion: '0.6.0',
    );
    final page = await client.listModels();
    expect(page.models, hasLength(3));
    expect(page.hasMore, true);
    expect(adapter.requests, hasLength(3));
    expect(adapter.requests.every((r) => r.method == 'GET'), true);
    transport.close();
  });

  test(
    'models directory override and non-Go headers respect endpoint policy',
    () async {
      final endpoint = AiEndpoint.parse(
        'https://provider.example/v1',
        allowLanCleartext: false,
        modelsUrlOverride: 'https://provider.example/catalog/models',
      );
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'data': [
            {'id': 'one'},
          ],
        }),
      );
      final transport = AiTransport(
        endpoint: endpoint,
        apiKey: 'synthetic-key',
        adapter: adapter,
      );
      final client = AiWireClient(
        transport: transport,
        wire: const ResponsesFormat(),
        config: config(
          preset: 'custom',
          modelsUrl: 'https://provider.example/catalog/models',
        ),
        conversationId: 'conversation-one',
        appVersion: '0.6.0',
      );
      expect(client.headers, isEmpty);
      expect((await client.listModels()).models.single.id, 'one');
      expect(adapter.requests.single.uri.path, '/catalog/models');
      transport.close();
    },
  );

  test(
    'provider header allowlist rejects injection and credential overrides',
    () async {
      final adapter = FakeAdapter((_) => throw StateError('must not run'));
      final transport = AiTransport(
        endpoint: AiEndpoint.parse(
          'https://provider.example/v1',
          allowLanCleartext: false,
        ),
        apiKey: 'synthetic-key',
        adapter: adapter,
      );
      for (final headers in [
        {'Authorization': 'replacement'},
        {'x-opencode-session': 'a\r\nb'},
        {'User-Agent': 'Arbitrary client'},
      ]) {
        await expectLater(
          transport.request(
            transport.endpoint.resolve(['responses']),
            providerHeaders: headers,
          ),
          throwsA(isA<AiFailure>()),
        );
      }
      expect(adapter.requests, isEmpty);
      transport.close();
    },
  );

  test('pagination preserves catalogue override for every page', () async {
    final endpoint = AiEndpoint.parse(
      'https://provider.example/v1',
      allowLanCleartext: false,
      modelsUrlOverride: 'https://provider.example/catalog/models',
    );
    final adapter = FakeAdapter(
      (request) => jsonResponse({
        'data': [
          {'id': 'one'},
        ],
        'has_more': request.uri.query.isEmpty,
        'last_id': 'one',
      }),
    );
    final transport = AiTransport(
      endpoint: endpoint,
      apiKey: 'synthetic-key',
      adapter: adapter,
    );
    final client = AiWireClient(
      transport: transport,
      wire: const ResponsesFormat(),
      config: config(modelsUrl: 'https://provider.example/catalog/models'),
      conversationId: 'conversation-one',
      appVersion: '0.6.0',
    );
    expect((await client.listModels()).models, hasLength(2));
    expect(adapter.requests.map((request) => request.uri.path), [
      '/catalog/models',
      '/catalog/models',
    ]);
    expect(adapter.requests.last.uri.queryParameters['after_id'], 'one');
    transport.close();
  });

  test(
    'OpenCode Go preset models override stays allowed across pages',
    () async {
      final preset = AiPresets.openCodeGo;
      final baseUrl = preset.baseUrls[AiFormat.responses]!;
      final endpoint = AiEndpoint.parse(
        baseUrl,
        allowLanCleartext: false,
        modelsUrlOverride: preset.modelsUrl,
      );
      final adapter = FakeAdapter(
        (request) => jsonResponse({
          'data': [
            {'id': request.uri.query.isEmpty ? 'one' : 'two'},
          ],
          'has_more': request.uri.query.isEmpty,
          'last_id': 'one',
        }),
      );
      final transport = AiTransport(
        endpoint: endpoint,
        apiKey: 'synthetic-key',
        adapter: adapter,
      );
      final client = AiWireClient(
        transport: transport,
        wire: const ResponsesFormat(),
        config: config(baseUrl: baseUrl, modelsUrl: preset.modelsUrl),
        conversationId: 'conversation-one',
        appVersion: '0.6.0',
      );
      expect(baseUrl, 'https://opencode.ai/inference/go/openai/v1');
      expect(preset.modelsUrl, 'https://opencode.ai/inference/go/v1/models');
      expect((await client.listModels()).models.map((model) => model.id), [
        'one',
        'two',
      ]);
      expect(adapter.requests.map((request) => request.uri), [
        Uri.parse(preset.modelsUrl!),
        Uri.parse('${preset.modelsUrl}?after_id=one&limit=100'),
      ]);
      for (final request in adapter.requests) {
        expect(endpoint.allows(request.uri), true);
        expect(request.headers['x-opencode-session'], 'conversation-one');
        expect(request.headers['User-Agent'], 'Mergeline/0.6.0');
      }
      transport.close();
    },
  );

  test(
    'client enforces configured auth, catalogue and disabled tools',
    () async {
      final transport = AiTransport(
        endpoint: AiEndpoint.parse(
          'https://provider.example/v1',
          allowLanCleartext: false,
        ),
        apiKey: 'synthetic-key',
        adapter: FakeAdapter((_) => throw StateError('must not run')),
      );
      for (final provider in [
        config(authStyle: AiAuthStyle.none),
        config(modelsUrl: 'https://provider.example/catalog/models'),
      ]) {
        expect(
          () => AiWireClient(
            transport: transport,
            wire: const ResponsesFormat(),
            config: provider,
            conversationId: 'conversation-one',
            appVersion: '0.6.0',
          ),
          throwsA(isA<AiFailure>()),
        );
      }
      final client = AiWireClient(
        transport: transport,
        wire: const ResponsesFormat(),
        config: config(),
        conversationId: 'conversation-one',
        appVersion: '0.6.0',
      );
      await expectLater(
        client.complete(
          AiRequestPlan(
            model: 'model',
            system: '',
            segment: segment(),
            tools: [
              AiToolSpec(name: 'read', description: 'Read', parameters: {}),
            ],
          ),
        ),
        throwsA(isA<AiFailure>()),
      );
      transport.close();
    },
  );

  test('malformed model metadata produces a safe failure', () {
    const wire = ResponsesFormat();
    for (final model in [
      {'id': 'one', 'display_name': 3},
      {'id': 3},
    ]) {
      expect(
        () => wire.decodeModels({
          'data': [model],
        }),
        throwsA(isA<AiFailure>()),
      );
    }
  });
}
