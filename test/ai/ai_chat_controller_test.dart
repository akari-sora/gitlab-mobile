import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';

const _providerKey = 'synthetic-provider-key-0001';

AiProviderConfig _provider(
  AiFormat format, {
  String id = 'provider',
  bool requiresKey = false,
  bool tools = false,
}) => AiProviderConfig(
  id: id,
  name: 'Synthetic $id',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: format,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: switch (format) {
      AiFormat.responses => AiTokenLimitField.maxOutputTokens,
      _ => AiTokenLimitField.maxTokens,
    },
    requiresKey: requiresKey,
    toolChoice: true,
  ),
  allowLanCleartext: false,
  toolsEnabled: tools,
  recipientRevision: 1,
);

final class _Environment {
  _Environment(this.workspace, this.session, this.settings);
  final WorkspaceFixture workspace;
  final SessionController session;
  final AiSettingsController settings;
  void dispose() {
    settings.dispose();
    session.dispose();
  }
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(
    condition(),
    isTrue,
    reason: 'synthetic async operation did not start',
  );
}

Future<_Environment> _environment({
  MemoryAiStore? aiStore,
  bool failFirstRepositoryRead = false,
  String? repositoryText,
}) async {
  final workspace = WorkspaceFixture();
  var failRepositoryRead = failFirstRepositoryRead;
  final gitLabAdapter = failFirstRepositoryRead || repositoryText != null
      ? FakeAdapter((request) {
          if (failRepositoryRead &&
              request.uri.path.contains('/repository/files/')) {
            failRepositoryRead = false;
            return jsonResponse({'message': 'synthetic outage'}, status: 500);
          }
          if (repositoryText != null &&
              request.uri.path.endsWith('/repository/files/README.md/raw')) {
            return ResponseBody.fromString(repositoryText, 200);
          }
          return workspace.respond(request);
        })
      : workspace.adapter;
  final accounts = MemoryAccountStore()
    ..accounts = [workspace.account]
    ..lastActive = workspace.account.key;
  final session = controllerFor(accounts, gitLabAdapter);
  await session.initialize();
  expect(session.active?.key, workspace.account.key);
  return _Environment(
    workspace,
    session,
    AiSettingsController(aiStore ?? MemoryAiStore()),
  );
}

Future<AiProviderConfig> _configure(
  _Environment environment,
  AiProviderConfig provider, {
  bool grantConsent = false,
}) async {
  await environment.settings.initialize();
  final saved = await environment.settings.saveProvider(provider);
  if (saved.caps.requiresKey) {
    await environment.settings.saveProviderKey(
      saved.id,
      _providerKey,
      acknowledgeWarning: true,
    );
  }
  await environment.settings.loadAccount(environment.workspace.account.key);
  if (grantConsent) {
    final contract = aiCurrentConsentContractFor(saved);
    await environment.settings.grantConsent(
      environment.workspace.account.key,
      contract,
      const {'synthetic': true},
    );
  }
  return environment.settings.providers.single;
}

AiChatController _controller(
  _Environment environment, {
  AiChatOrigin origin = const AiGeneralOrigin(),
  int Function()? runningCount,
  AiChatWireClientFactory? wireClientFactory,
}) => AiChatController(
  origin: origin,
  session: environment.session,
  settings: environment.settings,
  runningCount: runningCount ?? () => 0,
  wireClientFactory: wireClientFactory,
);

AiWireClient _wireClient(
  FakeAdapter adapter, {
  required AiProviderConfig config,
  required String? apiKey,
  required String conversationId,
}) {
  final transport = AiTransport(
    endpoint: AiEndpoint.parse(config.baseUrl, allowLanCleartext: false),
    apiKey: apiKey ?? '',
    authStyle: config.authStyle,
    adapter: adapter,
  );
  final wire = switch (config.format) {
    AiFormat.chatCompletions => const ChatCompletionsFormat(),
    AiFormat.responses => const ResponsesFormat(),
    AiFormat.anthropicMessages => const AnthropicMessagesFormat(),
  };
  return AiWireClient(
    transport: transport,
    wire: wire,
    config: config,
    conversationId: conversationId,
    appVersion: 'test',
  );
}

ResponseBody _sse(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

String _data(Object value, {String? event}) =>
    '${event == null ? '' : 'event: $event\n'}data: ${jsonEncode(value)}\n\n';

List<String> _toolThenAnswer(AiFormat format) => switch (format) {
  AiFormat.responses => [
    _data({
      'type': 'response.completed',
      'response': {
        'output': [
          {
            'type': 'function_call',
            'call_id': 'call_read',
            'name': 'read_file',
            'arguments': '{"path":"README.md","revision":"head"}',
            'status': 'completed',
          },
        ],
      },
    }),
    _data({
      'type': 'response.completed',
      'response': {
        'output': [
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'Final answer'},
            ],
          },
        ],
      },
    }),
  ],
  AiFormat.chatCompletions => [
    '${_data({
      'choices': [
        {
          'index': 0,
          'finish_reason': 'tool_calls',
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_read',
                'type': 'function',
                'function': {'name': 'read_file', 'arguments': '{"path":"README.md","revision":"head"}'},
              },
            ],
          },
        },
      ],
    })}data: [DONE]\n\n',
    '${_data({
      'choices': [
        {
          'index': 0,
          'finish_reason': 'stop',
          'delta': {'content': 'Final answer'},
        },
      ],
    })}data: [DONE]\n\n',
  ],
  AiFormat.anthropicMessages => [
    '${_data({
          'type': 'message_start',
          'message': {
            'content': <Object?>[],
            'usage': {'input_tokens': 1, 'output_tokens': 0},
          },
        }, event: 'message_start')}'
        '${_data({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'tool_use',
            'id': 'call_read',
            'name': 'read_file',
            'input': {'path': 'README.md', 'revision': 'head'},
          },
        }, event: 'content_block_start')}'
        '${_data({'type': 'content_block_stop', 'index': 0}, event: 'content_block_stop')}'
        '${_data({
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
          'usage': {'output_tokens': 1},
        }, event: 'message_delta')}'
        '${_data({'type': 'message_stop'}, event: 'message_stop')}',
    '${_data({
          'type': 'message_start',
          'message': {
            'content': <Object?>[],
            'usage': {'input_tokens': 1, 'output_tokens': 0},
          },
        }, event: 'message_start')}'
        '${_data({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': 'Final answer'},
        }, event: 'content_block_start')}'
        '${_data({'type': 'content_block_stop', 'index': 0}, event: 'content_block_stop')}'
        '${_data({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 2},
        }, event: 'message_delta')}'
        '${_data({'type': 'message_stop'}, event: 'message_stop')}',
  ],
};

String _partialEvents(AiFormat format, String partial) => switch (format) {
  AiFormat.responses =>
    '${_data({
          'type': 'response.created',
          'response': {'output': <Object?>[]},
        })}'
        '${_data({'type': 'response.output_text.delta', 'delta': partial})}',
  AiFormat.chatCompletions => _data({
    'choices': [
      {
        'index': 0,
        'finish_reason': null,
        'delta': {'role': 'assistant', 'content': partial},
      },
    ],
  }),
  AiFormat.anthropicMessages =>
    '${_data({
          'type': 'message_start',
          'message': {
            'content': <Object?>[],
            'usage': {'input_tokens': 1, 'output_tokens': 0},
          },
        }, event: 'message_start')}'
        '${_data({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        }, event: 'content_block_start')}'
        '${_data({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': partial},
        }, event: 'content_block_delta')}',
};

void main() {
  test('cold chat loads persisted consent and account token cap', () async {
    final store = MemoryAiStore();
    final environment = await _environment(aiStore: store);
    addTearDown(environment.dispose);
    await _configure(
      environment,
      _provider(AiFormat.responses),
      grantConsent: true,
    );
    final accountKey = environment.workspace.account.key;
    await environment.settings.setConversationTokenCap(accountKey, 70000);
    environment.settings.dispose();
    await Future<void>.delayed(Duration.zero);
    final freshSettings = AiSettingsController(store);
    addTearDown(freshSettings.dispose);
    await freshSettings.initialize();
    expect(freshSettings.accountRecord(accountKey), isNull);
    final controller = AiChatController(
      origin: const AiGeneralOrigin(),
      session: environment.session,
      settings: freshSettings,
      runningCount: () => 0,
    );
    addTearDown(controller.dispose);
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.none);
    expect(controller.canSend, isTrue);
    expect(
      freshSettings.accountRecord(accountKey)?.conversationTokenCap,
      70000,
    );
  });

  test('unreadable account settings block until a successful retry', () async {
    final store = MemoryAiStore();
    final environment = await _environment(aiStore: store);
    addTearDown(environment.dispose);
    await environment.settings.initialize();
    await environment.settings.saveProvider(_provider(AiFormat.responses));
    store.debugPut(
      SecureAiStore.accountKey(environment.workspace.account.key),
      '{malformed-account',
    );
    final controller = _controller(environment);
    addTearDown(controller.dispose);
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.settingsUnavailable);
    expect(controller.canSend, isFalse);
    await store.saveAccount(
      environment.workspace.account.key,
      AiAccountRecord(),
    );
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.consentRequired);
  });

  group('preparing blockers', () {
    test('moves from settings loading to no provider', () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      final controller = _controller(environment);
      addTearDown(controller.dispose);
      await controller.recheck();
      expect(controller.blocker, AiChatBlocker.settingsLoading);
      await environment.settings.initialize();
      await controller.recheck();
      expect(controller.blocker, AiChatBlocker.noProvider);
    });

    test('maps a settings initialization failure', () async {
      final store = MemoryAiStore()
        ..debugPut(SecureAiStore.providersStorageKey, '{not-json');
      final environment = await _environment(aiStore: store);
      addTearDown(environment.dispose);
      await expectLater(environment.settings.initialize(), throwsA(anything));
      final controller = _controller(environment);
      addTearDown(controller.dispose);
      await controller.recheck();
      expect(controller.blocker, AiChatBlocker.settingsUnavailable);
    });

    test('requires a key before consent', () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      await environment.settings.initialize();
      await environment.settings.saveProvider(
        _provider(AiFormat.responses, requiresKey: true),
      );
      final controller = _controller(environment);
      addTearDown(controller.dispose);
      await controller.recheck();
      expect(controller.blocker, AiChatBlocker.keyMissing);
      await environment.settings.saveProviderKey(
        'provider',
        _providerKey,
        acknowledgeWarning: true,
      );
      await controller.recheck();
      expect(controller.blocker, AiChatBlocker.consentRequired);
      expect(controller.consentRequest, isNotNull);
    });

    test(
      'granted consent enables sending and capacity refuses visibly',
      () async {
        final environment = await _environment();
        addTearDown(environment.dispose);
        await _configure(
          environment,
          _provider(AiFormat.responses),
          grantConsent: true,
        );
        var running = 0;
        final controller = _controller(
          environment,
          runningCount: () => running,
        );
        addTearDown(controller.dispose);
        await controller.recheck();
        expect(controller.blocker, AiChatBlocker.none);
        expect(controller.canSend, isTrue);
        running = AiRunRegistry.maxRunning;
        await controller.send('blocked by capacity');
        expect(controller.blocker, AiChatBlocker.tooManyRunning);
        expect(controller.items, isEmpty);
      },
    );

    test('failed starting context transitions to ready on retry', () async {
      final environment = await _environment(failFirstRepositoryRead: true);
      addTearDown(environment.dispose);
      await _configure(
        environment,
        _provider(AiFormat.responses),
        grantConsent: true,
      );
      final controller = _controller(
        environment,
        origin: AiFileOrigin(
          project: environment.workspace.project,
          path: 'README.md',
          sha: WorkspaceFixture.sha,
        ),
      );
      addTearDown(controller.dispose);
      await controller.recheck();
      expect(controller.blocker, AiChatBlocker.contextUnavailable);
      expect(controller.failure, isNotNull);
      await controller.recheck();
      expect(controller.blocker, AiChatBlocker.none);
      expect(controller.failure, isNull);
      expect(controller.canSend, isTrue);
    });
  });

  for (final format in AiFormat.values) {
    test('streams a tool run and final answer for ${format.name}', () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      await _configure(
        environment,
        _provider(format, tools: true),
        grantConsent: true,
      );
      final responses = _toolThenAnswer(format).iterator;
      final providerAdapter = FakeAdapter((_) {
        if (!responses.moveNext()) {
          return jsonResponse({'error': 'unexpected call'}, status: 500);
        }
        return _sse(responses.current);
      });
      final controller = _controller(
        environment,
        origin: AiFileOrigin(
          project: environment.workspace.project,
          path: 'README.md',
          sha: WorkspaceFixture.sha,
        ),
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                _wireClient(
                  providerAdapter,
                  config: config,
                  apiKey: apiKey,
                  conversationId: conversationId,
                ),
      );
      addTearDown(controller.dispose);
      await controller.recheck();
      await controller.send('Read the file');
      expect(controller.phase, AiChatPhase.idle);
      expect(controller.failure, isNull);
      expect(
        controller.items.whereType<AiToolRunItem>().single.status,
        AiToolRunStatus.completed,
      );
      expect(
        controller.items.whereType<AiAssistantItem>().single,
        isA<AiAssistantItem>()
            .having((item) => item.text, 'text', 'Final answer')
            .having((item) => item.state, 'state', AiAssistantState.done),
      );
      expect(providerAdapter.requests, hasLength(2));
      expect(
        environment.workspace.adapter.requests.map((request) => request.method),
        everyElement(isIn(['GET', 'HEAD'])),
      );
    });
  }

  test('GitLab credential is redacted from a tool result', () async {
    const token = 'synthetic-test-token';
    final environment = await _environment(repositoryText: 'value=$token');
    addTearDown(environment.dispose);
    await _configure(
      environment,
      _provider(AiFormat.responses, tools: true),
      grantConsent: true,
    );
    final responses = _toolThenAnswer(AiFormat.responses).iterator;
    final adapter = FakeAdapter((_) {
      responses.moveNext();
      return _sse(responses.current);
    });
    final controller = _controller(
      environment,
      origin: AiFileOrigin(
        project: environment.workspace.project,
        path: 'README.md',
        sha: WorkspaceFixture.sha,
      ),
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              ),
    );
    addTearDown(controller.dispose);
    await controller.recheck();
    await controller.send('read the credential-shaped text');

    final result = controller.items.whereType<AiToolRunItem>().single;
    expect(result.resultExcerpt, isNot(contains(token)));
    expect(result.resultExcerpt, contains('REDACTED'));
    expect(
      controller.items.whereType<AiNoticeItem>().any(
        (item) => item.kind == AiNoticeKind.redacted,
      ),
      isTrue,
    );
  });

  test('private-key context is withheld with a visible notice', () async {
    final environment = await _environment(
      repositoryText: '-----BEGIN PRIVATE KEY-----\nsynthetic payload',
    );
    addTearDown(environment.dispose);
    await _configure(
      environment,
      _provider(AiFormat.responses),
      grantConsent: true,
    );
    final adapter = FakeAdapter(
      (_) => _sse(_toolThenAnswer(AiFormat.responses).last),
    );
    final controller = _controller(
      environment,
      origin: AiFileOrigin(
        project: environment.workspace.project,
        path: 'README.md',
        sha: WorkspaceFixture.sha,
      ),
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              ),
    );
    addTearDown(controller.dispose);
    await controller.recheck();
    await controller.send('summarize safely');

    expect(controller.items.whereType<AiUserItem>().single.chips, isNotEmpty);
    expect(
      controller.items.whereType<AiNoticeItem>().any(
        (item) => item.kind == AiNoticeKind.privateKeyWithheld,
      ),
      isTrue,
    );
  });

  test('sensitive file origin produces a blocked display chip', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    await _configure(
      environment,
      _provider(AiFormat.responses),
      grantConsent: true,
    );
    final adapter = FakeAdapter(
      (_) => _sse(_toolThenAnswer(AiFormat.responses).last),
    );
    final controller = _controller(
      environment,
      origin: AiFileOrigin(
        project: environment.workspace.project,
        path: '.env',
        sha: WorkspaceFixture.sha,
      ),
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              ),
    );
    addTearDown(controller.dispose);
    await controller.recheck();
    await controller.send('inspect');

    final chips = controller.items.whereType<AiUserItem>().single.chips;
    expect(chips, hasLength(1));
    expect(chips.single.blocked, isTrue);
    expect(chips.single.source, '.env');
  });

  test('stop before runner creation prevents a provider request', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    await _configure(
      environment,
      _provider(AiFormat.responses),
      grantConsent: true,
    );
    final adapter = FakeAdapter(
      (_) => _sse(_toolThenAnswer(AiFormat.responses).last),
    );
    final controller = _controller(
      environment,
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              ),
    );
    addTearDown(controller.dispose);
    await controller.recheck();

    final send = controller.send('do not send');
    controller.stop();
    await send;

    expect(adapter.requests, isEmpty);
    expect(controller.phase, AiChatPhase.idle);
    expect(
      controller.items.whereType<AiNoticeItem>().single.kind,
      AiNoticeKind.stopped,
    );
  });

  for (final format in AiFormat.values) {
    test('stop mid-stream keeps ${format.name} partial reply', () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      await _configure(environment, _provider(format), grantConsent: true);
      final stream = StreamController<Uint8List>();
      final adapter = FakeAdapter(
        (_) => ResponseBody(
          stream.stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        ),
      );
      final controller = _controller(
        environment,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                _wireClient(
                  adapter,
                  config: config,
                  apiKey: apiKey,
                  conversationId: conversationId,
                ),
      );
      addTearDown(controller.dispose);
      await controller.recheck();

      final send = controller.send('stream');
      await _waitFor(() => adapter.requests.isNotEmpty);
      final partial = 'partial answer'.padRight(256, '!');
      stream.add(
        Uint8List.fromList(utf8.encode(_partialEvents(format, partial))),
      );
      await _waitFor(
        () => controller.items.whereType<AiAssistantItem>().any(
          (item) => item.text == partial,
        ),
      );
      controller.stop();
      await stream.close();
      await send;

      expect(
        controller.items.whereType<AiAssistantItem>().single,
        isA<AiAssistantItem>()
            .having((item) => item.text, 'text', partial)
            .having(
              (item) => item.state,
              'state',
              AiAssistantState.interrupted,
            ),
      );
      expect(
        controller.items.whereType<AiNoticeItem>().last.kind,
        AiNoticeKind.stopped,
      );
    });
  }

  testWidgets('stream notifications are coalesced to one per 100 milliseconds', (
    tester,
  ) async {
    final environment = (await tester.runAsync(_environment))!;
    addTearDown(environment.dispose);
    await tester.runAsync(
      () => _configure(
        environment,
        _provider(AiFormat.responses),
        grantConsent: true,
      ),
    );
    final stream = StreamController<Uint8List>.broadcast();
    final adapter = FakeAdapter(
      (_) => ResponseBody(
        stream.stream,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      ),
    );
    final controller = _controller(
      environment,
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              ),
    );
    addTearDown(controller.dispose);
    await controller.recheck();
    var notifications = 0;
    controller.addListener(() => notifications++);
    var finished = false;
    final send = controller.send('stream').then((_) => finished = true);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(adapter.requests, hasLength(1));
    expect(stream.hasListener, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    notifications = 0;
    stream.add(
      Uint8List.fromList(
        utf8.encode(
          '${_data({
            'type': 'response.created',
            'response': {'output': <Object?>[]},
          })}'
          '${_data({'type': 'response.output_text.delta', 'delta': 'a' * 256})}'
          '${_data({'type': 'response.output_text.delta', 'delta': 'b' * 256})}'
          '${_data({'type': 'response.output_text.delta', 'delta': 'c' * 512})}',
        ),
      ),
    );
    await tester.pump();
    expect(
      controller.items.whereType<AiAssistantItem>().single.text.length,
      1024,
    );
    expect(notifications, 0);
    await tester.pump(const Duration(milliseconds: 99));
    expect(notifications, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(notifications, 1);
    stream.add(
      Uint8List.fromList(
        utf8.encode(
          _data({'type': 'response.output_text.delta', 'delta': 'd' * 1024}),
        ),
      ),
    );
    await tester.pump();
    expect(notifications, 1);
    await tester.pump(const Duration(milliseconds: 99));
    expect(notifications, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(notifications, 2);
    controller.stop();
    unawaited(stream.close());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(finished, isTrue);
    await send;
    expect(controller.phase, AiChatPhase.idle);
    // The runner's canceled model future retains its deadline until settled.
    await tester.pump(const Duration(minutes: 5));
  });

  test(
    'consent revocation stops a stalled run and blocks the next send',
    () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      final provider = await _configure(
        environment,
        _provider(AiFormat.responses),
        grantConsent: true,
      );
      final stream = StreamController<Uint8List>();
      final adapter = FakeAdapter(
        (_) => ResponseBody(
          stream.stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        ),
      );
      final controller = _controller(
        environment,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                _wireClient(
                  adapter,
                  config: config,
                  apiKey: apiKey,
                  conversationId: conversationId,
                ),
      );
      addTearDown(controller.dispose);
      await controller.recheck();
      final send = controller.send('wait forever');
      await _waitFor(() => adapter.requests.isNotEmpty);
      unawaited(adapter.cancelFutures.single!.then((_) => stream.close()));

      await environment.settings.revokeConsent(
        environment.workspace.account.key,
        provider.id,
      );
      await send;

      expect(controller.blocker, AiChatBlocker.consentRequired);
      expect(controller.canSend, isFalse);
      expect(
        controller.items.whereType<AiNoticeItem>().last.kind,
        AiNoticeKind.settingsChanged,
      );
    },
  );

  test(
    'recheck keeps the existing runner callbacks live for a second turn',
    () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      await _configure(
        environment,
        _provider(AiFormat.responses),
        grantConsent: true,
      );
      final adapter = FakeAdapter(
        (_) => _sse(_toolThenAnswer(AiFormat.responses).last),
      );
      var clients = 0;
      final controller = _controller(
        environment,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) {
              clients++;
              return _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              );
            },
      );
      addTearDown(controller.dispose);
      await controller.recheck();
      await controller.send('first');
      await controller.recheck();
      await controller.send('second');

      expect(clients, 1);
      expect(adapter.requests, hasLength(2));
      expect(
        controller.items.whereType<AiAssistantItem>().map((item) => item.text),
        ['Final answer', 'Final answer'],
      );
    },
  );

  test('new conversation and provider switch clear display state', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    await _configure(
      environment,
      _provider(AiFormat.responses, id: 'first'),
      grantConsent: true,
    );
    final second = await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'second'),
    );
    await environment.settings.grantConsent(
      environment.workspace.account.key,
      aiCurrentConsentContractFor(second),
      const {'synthetic': true},
    );
    final adapter = FakeAdapter(
      (_) => _sse(_toolThenAnswer(AiFormat.responses).last),
    );
    final controller = _controller(
      environment,
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              ),
    );
    addTearDown(controller.dispose);
    await controller.recheck();
    await controller.send('hello');
    final firstId = controller.id;
    expect(controller.items, isNotEmpty);
    controller.startNewConversation();
    await controller.recheck();
    expect(controller.id, isNot(firstId));
    expect(controller.items, isEmpty);
    final nextId = controller.id;
    await controller.useProvider('second');
    expect(controller.provider?.id, 'second');
    expect(controller.id, isNot(nextId));
    expect(controller.items, isEmpty);
  });
}
