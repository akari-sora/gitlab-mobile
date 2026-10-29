import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

import '../../tool/mr7/live_provider.dart';

const _pat = 'synthetic-gitlab-pat-never-forward';
const _key = 'synthetic-provider-key';

Map<String, dynamic> _configuration(
  String format, {
  double maxCost = 1,
  int maxCalls = 4,
  bool openCode = false,
}) => {
  'endpoint': 'https://provider.invalid/v1',
  'format': format,
  'model': 'fixture-model',
  'caps': {'tools': true, 'maxTokens': 2048},
  'priceInputPerMTok': 2.0,
  'priceOutputPerMTok': 4.0,
  'maxCost': maxCost,
  'maxCalls': maxCalls,
  if (openCode) 'preset': 'opencode-go',
};

AiRequestPlan _plan(
  Mr7LiveProvider provider, {
  String text = 'Synthetic request',
}) => AiRequestPlan(
  model: provider.config.model,
  system: 'Synthetic fixture only',
  maxOutputTokens: provider.config.caps.maxOutputTokens,
  segment: AiSegment(
    providerId: provider.config.id,
    recipientRevision: 1,
    format: provider.config.format,
    model: provider.config.model,
    secretSetAtStart: SecretSetId.fromSecrets([]),
  )..setTail(AppUserEntry(text: text)),
);

// Maps the configured fake HTTPS recipient onto a loopback server only.
final class _LoopbackAdapter implements HttpClientAdapter {
  _LoopbackAdapter(this.port);
  final int port;
  final HttpClient client = HttpClient();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) => runZoned(() async {
    final request = await client.openUrl(
      options.method,
      Uri.parse('http://127.0.0.1:$port${options.uri.path}'),
    );
    options.headers.forEach((name, value) {
      if (value != null) request.headers.set(name, value.toString());
    });
    if (stream != null) await request.addStream(stream);
    final response = await request.close();
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) => headers[name] = values);
    return ResponseBody(
      response.map((chunk) => Uint8List.fromList(chunk)),
      response.statusCode,
      headers: headers,
    );
  }, zoneValues: {#flutter.io.allow_http: true});
  @override
  void close({bool force = false}) => client.close(force: force);
}

String _event(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';
String _answer(
  String format,
  bool usage, {
  Object? inputTokens = 10,
  Object? outputTokens = 3,
  bool terminal = true,
}) {
  if (format == 'chat_completions') {
    final first = _event({
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': 'ok'},
          'finish_reason': 'stop',
        },
      ],
      'usage': null,
    });
    return first +
        (usage
            ? _event({
                'choices': [],
                'usage': {
                  'prompt_tokens': inputTokens,
                  'completion_tokens': outputTokens,
                },
              })
            : '') +
        (terminal ? 'data: [DONE]\n\n' : '');
  }
  return _event({
        'type': 'message_start',
        'message': {
          'id': 'message',
          'usage': {'input_tokens': 10, 'output_tokens': 1},
        },
      }) +
      _event({
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text', 'text': ''},
      }) +
      _event({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'ok'},
      }) +
      _event({'type': 'content_block_stop', 'index': 0}) +
      _event({
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        if (usage) 'usage': {'output_tokens': outputTokens},
      }) +
      (terminal ? _event({'type': 'message_stop'}) : '');
}

void liveProviderTests() {
  for (final format in ['chat_completions', 'anthropic_messages']) {
    test(
      'live provider $format sends through production wire and accounts usage',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <String>[];
        final headers = <Map<String, String>>[];
        final subscription = server.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          requests.add(body);
          headers.add({
            for (final name in [
              'authorization',
              'x-api-key',
              'anthropic-version',
              'x-opencode-session',
              'user-agent',
            ])
              name: request.headers.value(name) ?? '',
          });
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(_answer(format, true));
          await request.response.close();
        });
        final adapter = _LoopbackAdapter(server.port);
        final provider = Mr7LiveProvider(
          _configuration(
            format,
            maxCost: 0.015,
            openCode: format == 'chat_completions',
          ),
          _key,
          adapter: adapter,
        );
        final client = provider.createClient('test-conversation');
        try {
          await client.complete(_plan(provider));
          expect(requests, hasLength(1));
          expect(requests.single, isNot(contains(_pat)));
          expect(jsonDecode(requests.single)['max_tokens'], 2048);
          expect(headers.single.values.join(), isNot(contains(_pat)));
          if (format == 'chat_completions') {
            expect(jsonDecode(requests.single)['stream_options'], {
              'include_usage': true,
            });
            expect(headers.single['authorization'], 'Bearer $_key');
            expect(headers.single['x-opencode-session'], 'test-conversation');
            expect(headers.single['user-agent'], startsWith('Mergeline/'));
          } else {
            expect(headers.single['x-api-key'], _key);
            expect(headers.single['anthropic-version'], '2023-06-01');
          }
          expect(provider.calls, 1);
          expect(provider.usage.single['inputTokens'], 10);
          expect(provider.usage.single['outputTokens'], 3);
          expect(provider.usage.single['usageEstimated'], 0);
          expect(provider.spend, closeTo(0.000032, 0.000000001));
          expect(jsonEncode(provider.usage), isNot(contains(_key)));
          await client.complete(_plan(provider));
          expect(requests, hasLength(2));
          expect(provider.calls, 2);
          expect(provider.spend, closeTo(0.000064, 0.000000001));
        } finally {
          client.transport.close();
          adapter.close(force: true);
          await subscription.cancel();
          await server.close(force: true);
        }
      },
    );
    final anthropic = format == 'anthropic_messages';
    final terminal = anthropic
        ? _event({'type': 'message_stop'})
        : 'data: [DONE]\n\n';
    final finalUsage = anthropic
        ? _event({
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 3},
          })
        : _event({
            'choices': [],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 3},
          });
    final cases = <String, ({String response, bool decodingFails})>{
      'missing final usage': (
        response: _answer(format, false),
        decodingFails: false,
      ),
      'null final output usage': (
        response: _answer(format, true, outputTokens: null),
        decodingFails: false,
      ),
      for (final invalid in <String, Object>{
        'negative': -1,
        'fractional': 1.5,
        'string': '3',
      }.entries)
        '${invalid.key} final output usage': (
          response: _answer(format, true, outputTokens: invalid.value),
          decodingFails: anthropic,
        ),
      'final usage without terminal': (
        response: _answer(format, true, terminal: false),
        decodingFails: anthropic,
      ),
      'usage after terminal': (
        response: _answer(format, false) + finalUsage,
        decodingFails: false,
      ),
      if (anthropic)
        'earlier delta usage followed by missing final usage': (
          response: _answer(format, true).replaceFirst(
            terminal,
            _event({
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'end_turn'},
                }) +
                terminal,
          ),
          decodingFails: false,
        )
      else ...{
        'usage on content chunk only': (
          response: _answer(format, false).replaceFirst(
            '"usage":null',
            '"usage":{"prompt_tokens":10,"completion_tokens":1}',
          ),
          decodingFails: false,
        ),
        'missing final input usage': (
          response: _answer(format, true, inputTokens: null),
          decodingFails: false,
        ),
        'earlier final usage followed by incomplete final usage': (
          response: _answer(format, true).replaceFirst(
            terminal,
            _event({
                  'choices': [],
                  'usage': {'prompt_tokens': 10},
                }) +
                terminal,
          ),
          decodingFails: false,
        ),
      },
    };
    for (final entry in cases.entries) {
      test(
        'live provider $format ${entry.key} retains reservation and refuses next send',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          var requests = 0;
          final subscription = server.listen((request) async {
            requests++;
            await request.drain<void>();
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.write(entry.value.response);
            await request.response.close();
          });
          final adapter = _LoopbackAdapter(server.port);
          final provider = Mr7LiveProvider(
            _configuration(format, maxCost: 0.015),
            _key,
            adapter: adapter,
          );
          final client = provider.createClient('test-conversation');
          try {
            if (entry.value.decodingFails) {
              await expectLater(
                client.complete(_plan(provider)),
                throwsA(anything),
              );
            } else {
              await client.complete(_plan(provider));
            }
            expect(requests, 1);
            expect(provider.usage.single['usageEstimated'], 1);
            expect(provider.usage.single['inputTokens'], greaterThan(1024));
            expect(provider.usage.single['outputTokens'], 2048);
            final reserved = provider.spend;
            expect(reserved, greaterThan(0.008));
            expect(reserved, lessThan(0.015));
            await expectLater(
              client.complete(_plan(provider)),
              throwsA(anything),
            );
            expect(requests, 1);
            expect(provider.calls, 1);
            expect(provider.spend, reserved);
          } finally {
            client.transport.close();
            adapter.close(force: true);
            await subscription.cancel();
            await server.close(force: true);
          }
        },
      );
    }
  }
  test(
    'malformed event in same chunk as usage and terminal retains reservation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        final malformed = _event({
          'choices': [
            {
              'index': 0,
              'delta': {'content': 42},
              'finish_reason': 'stop',
            },
          ],
          'usage': null,
        });
        final usage = _event({
          'choices': [],
          'usage': {'prompt_tokens': 10, 'completion_tokens': 3},
        });
        request.response.write('$malformed${usage}data: [DONE]\n\n');
        await request.response.close();
      });
      final adapter = _LoopbackAdapter(server.port);
      final provider = Mr7LiveProvider(
        _configuration('chat_completions'),
        _key,
        adapter: adapter,
      );
      final client = provider.createClient('test-conversation');
      try {
        await expectLater(client.complete(_plan(provider)), throwsA(anything));
        expect(provider.usage.single['usageEstimated'], 1);
        expect(provider.usage.single['inputTokens'], greaterThan(1024));
        expect(provider.usage.single['outputTokens'], 2048);
        expect(provider.spend, greaterThan(0.008));
      } finally {
        client.transport.close();
        adapter.close(force: true);
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
  test(
    'cancelled consumer keeps full reservation even with terminal usage',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(_answer('chat_completions', true));
        await request.response.close();
      });
      final adapter = _LoopbackAdapter(server.port);
      final provider = Mr7LiveProvider(
        _configuration('chat_completions'),
        _key,
        adapter: adapter,
      );
      final client = provider.createClient('test-conversation');
      try {
        await expectLater(
          client.complete(
            _plan(provider),
            onEvent: (event) {
              if (event is AiFinished) {
                client.transport.cancelActive();
                throw StateError('consumer cancelled');
              }
            },
          ),
          throwsStateError,
        );
        expect(provider.usage.single['usageEstimated'], 1);
        expect(provider.usage.single['inputTokens'], greaterThan(1024));
        expect(provider.usage.single['outputTokens'], 2048);
      } finally {
        client.transport.close();
        adapter.close(force: true);
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
  test('transport cancelled at terminal event keeps the reservation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(_answer('chat_completions', true));
      await request.response.close();
    });
    final adapter = _LoopbackAdapter(server.port);
    final provider = Mr7LiveProvider(
      _configuration('chat_completions'),
      _key,
      adapter: adapter,
    );
    final client = provider.createClient('test-conversation');
    try {
      try {
        await client.complete(
          _plan(provider),
          onEvent: (event) {
            if (event is AiFinished) client.transport.cancelActive();
          },
        );
      } on Object {
        // The decoder or transport may observe the cancellation first.
      }
      expect(provider.usage.single['usageEstimated'], 1);
      expect(provider.usage.single['outputTokens'], 2048);
    } finally {
      client.transport.close();
      adapter.close(force: true);
      await subscription.cancel();
      await server.close(force: true);
    }
  });
  test(
    'live provider refuses cost before send and enforces maxCalls',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        await request.drain<void>();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(_answer('chat_completions', false));
        await request.response.close();
      });
      final adapter = _LoopbackAdapter(server.port);
      final expensive = Mr7LiveProvider(
        _configuration('chat_completions', maxCost: 0.000001),
        _key,
        adapter: adapter,
      );
      final expensiveClient = expensive.createClient('test-conversation');
      final limited = Mr7LiveProvider(
        _configuration('chat_completions', maxCalls: 1),
        _key,
        adapter: adapter,
      );
      final limitedClient = limited.createClient('test-conversation');
      final bounded = Mr7LiveProvider(
        _configuration('chat_completions', maxCost: 0.015),
        _key,
        adapter: adapter,
      );
      final boundedClient = bounded.createClient('test-conversation');
      try {
        await expectLater(
          expensiveClient.complete(_plan(expensive)),
          throwsA(anything),
        );
        expect(requests, 0);
        expect(expensive.calls, 0);
        await limitedClient.complete(_plan(limited));
        expect(requests, 1);
        expect(limited.usage.single['inputTokens'], greaterThan(1024));
        expect(limited.usage.single['outputTokens'], 2048);
        expect(limited.usage.single['usageEstimated'], 1);
        expect(limited.spend, greaterThan(0));
        await expectLater(
          limitedClient.complete(_plan(limited)),
          throwsA(anything),
        );
        expect(requests, 1);
        expect(limited.calls, 1);
        await boundedClient.complete(_plan(bounded));
        expect(requests, 2);
        await expectLater(
          boundedClient.complete(_plan(bounded)),
          throwsA(anything),
        );
        expect(requests, 2);
        expect(bounded.calls, 1);
        await expectLater(
          boundedClient.complete(_plan(bounded, text: _key)),
          throwsA(anything),
        );
        expect(requests, 2);
        expect(bounded.leakDetected, isTrue);
      } finally {
        expensiveClient.transport.close();
        limitedClient.transport.close();
        boundedClient.transport.close();
        adapter.close(force: true);
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
  test(
    'live provider rejects unsupported capabilities and nonfinite prices',
    () {
      final unknownCaps = _configuration('chat_completions');
      unknownCaps['caps'] = {'tools': true, 'maxTokens': 2048, 'unknown': true};
      expect(() => Mr7LiveProvider(unknownCaps, _key), throwsA(anything));
      final badPrice = _configuration('chat_completions');
      badPrice['priceInputPerMTok'] = double.infinity;
      expect(() => Mr7LiveProvider(badPrice, _key), throwsA(anything));
    },
  );
}

void main() => liveProviderTests();
