import 'release_policy_support.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/runner.dart' show AiRunEnd;
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';

const _providerKey = 'synthetic-provider-key-0001';

AiProviderConfig _provider(
  AiFormat format, {
  String id = 'provider',
  bool requiresKey = false,
  bool tools = false,
  String model = 'synthetic-model',
  int maxRequestChars = 400000,
}) => AiProviderConfig(
  id: id,
  name: 'Synthetic $id',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: format,
  model: model,
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: switch (format) {
      AiFormat.responses => AiTokenLimitField.maxOutputTokens,
      _ => AiTokenLimitField.maxTokens,
    },
    requiresKey: requiresKey,
    toolChoice: true,
    maxRequestChars: maxRequestChars,
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
  // Bounded by time, not by turns: under CI load the journal's file work can
  // need more turns than a fixed count allows.
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(
    condition(),
    isTrue,
    reason: 'synthetic async operation did not start',
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final elapsed = Stopwatch()..start();
  while (!condition() && elapsed.elapsed < timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'history condition did not settle');
}

Future<_Environment> _environment({
  MemoryAiStore? aiStore,
  bool failFirstRepositoryRead = false,
  String? repositoryText,
  Responder? gitLabRespond,
}) async {
  final workspace = WorkspaceFixture();
  var failRepositoryRead = failFirstRepositoryRead;
  final gitLabAdapter =
      failFirstRepositoryRead || repositoryText != null || gitLabRespond != null
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
          return gitLabRespond == null
              ? workspace.respond(request)
              : gitLabRespond(request);
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
    final contract = aiConversationConsentContract(
      environment.settings,
      environment.workspace.account.key,
      saved, releasePolicy: fixtureReleasePolicy
    );
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
  Future<void> Function()? refreshSecrets,
  List<Duration>? historyRetryDelays,
}) => AiChatController(
  releasePolicy: fixtureReleasePolicy,
  appInForeground: () => true,
  origin: origin,
  session: environment.session,
  settings: environment.settings,
  runningCount: runningCount ?? () => 0,
  wireClientFactory: wireClientFactory,
  refreshSecrets: refreshSecrets,
  historyRetryDelays:
      historyRetryDelays ?? AiChatController.defaultHistoryRetryDelays,
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

List<String> _toolThenAnswer(
  AiFormat format, {
  String path = 'README.md',
  String toolName = 'read_file',
}) => switch (format) {
  AiFormat.responses => [
    _data({
      'type': 'response.completed',
      'response': {
        'output': [
          {
            'type': 'function_call',
            'call_id': 'call_read',
            'name': toolName,
            'arguments': jsonEncode({'path': path, 'revision': 'head'}),
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
                'function': {
                  'name': toolName,
                  'arguments': jsonEncode({'path': path, 'revision': 'head'}),
                },
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
            'name': toolName,
            'input': {'path': path, 'revision': 'head'},
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

Future<AiChatController> _readyController(
  _Environment environment,
  FakeAdapter adapter, {
  AiChatOrigin? origin,
  bool tools = true,
  bool requiresKey = false,
  int maxRequestChars = 400000,
  Future<void> Function()? refreshSecrets,
  List<Duration>? historyRetryDelays,
}) async {
  await _configure(
    environment,
    _provider(
      AiFormat.responses,
      tools: tools,
      requiresKey: requiresKey,
      maxRequestChars: maxRequestChars,
    ),
    grantConsent: true,
  );
  final controller = _controller(
    environment,
    origin:
        origin ??
        AiFileOrigin(
          project: environment.workspace.project,
          path: 'README.md',
          sha: WorkspaceFixture.sha,
        ),
    refreshSecrets: refreshSecrets,
    historyRetryDelays: historyRetryDelays,
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
  return controller;
}

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
      releasePolicy: fixtureReleasePolicy,
      appInForeground: () => true,
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

  test(
    'the title is cleaned with live secrets while consent is needed',
    () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      await _configure(environment, _provider(AiFormat.responses));
      final controller = _controller(environment);
      addTearDown(controller.dispose);
      // Nothing has been sent or prepared; the page already shows the title.
      expect(
        controller.displaySafe('Rotate synthetic-test-token now'),
        isNot(contains('synthetic-test-token')),
      );
      await controller.recheck();
      expect(controller.blocker, AiChatBlocker.consentRequired);
      expect(
        controller.displaySafe('Rotate synthetic-test-token now'),
        isNot(contains('synthetic-test-token')),
      );
    },
  );

  test('draft text keeps its lines and loses hidden characters', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    await _configure(environment, _provider(AiFormat.responses));
    final controller = _controller(environment);
    addTearDown(controller.dispose);
    await controller.recheck();
    const answer =
        'First line\n\n```\n\tcode\n```\n'
        'Rotate synthetic-test-token\u202e now\u200b';
    final draft = controller.draftSafe(answer);
    expect(draft, startsWith('First line\n\n```\n\tcode\n```\nRotate '));
    expect(draft, isNot(contains('synthetic-test-token')));
    expect(draft, isNot(contains('\u202e')));
    expect(draft, isNot(contains('\u200b')));
    // What the page shows as a label stays on one line.
    expect(controller.displaySafe(answer), isNot(contains('\n')));
    // GitLab deletes a lone CR, which joins what it split: the secret must be
    // caught after that join, not before it.
    final split = controller.draftSafe(
      'Rotate synthetic-test\r-token now\r\nok',
    );
    expect(split, isNot(contains('synthetic-test-token')));
    expect(split, isNot(contains('\r')));
    expect(split, endsWith(' now\nok'));
  });

  test('an unchanged secret set leaves the shown items alone', () async {
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
    await controller.send('explain');
    final before = List.of(controller.items);
    expect(before, isNotEmpty);

    // A recheck refreshes the secrets; none are new, so nothing is redone.
    await controller.recheck();
    for (var i = 0; i < before.length; i++) {
      expect(identical(controller.items[i], before[i]), isTrue, reason: '$i');
    }
  });

  String answer(String text) => _data({
    'type': 'response.completed',
    'response': {
      'output': [
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': text},
          ],
        },
      ],
    },
  });

  test(
    'reporting preserves attribution through redaction and hidden fallback',
    () async {
      const lateSecret = 'synthetic-answer-secret-0098';
      final environment = await _environment();
      addTearDown(environment.dispose);
      final controller = await _readyController(
        environment,
        FakeAdapter((_) => _sse(answer('answer $lateSecret'))),
        tools: false,
      );
      await controller.send('first');
      final original = controller.items.whereType<AiAssistantItem>().single;
      expect(original.source?.presetId, 'custom');
      expect(original.source?.format, AiFormat.responses.name);
      expect(original.source?.model, 'synthetic-model');
      expect(original.state, AiAssistantState.done);
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.markReported(
        const AiAssistantItem(text: 'unknown', state: AiAssistantState.done),
      );
      expect(notifications, 0);
      expect(
        identical(
          controller.items.whereType<AiAssistantItem>().single,
          original,
        ),
        isTrue,
      );
      controller.markReported(original);
      expect(notifications, 1);
      final marked = controller.items.whereType<AiAssistantItem>().single;
      expect(controller.currentOf(original), same(marked));
      expect(marked.reported, isTrue);
      expect(marked.text, original.text);
      expect(marked.source, same(original.source));
      expect(marked.usage, same(original.usage));
      expect(controller.historySaved, isFalse);
      controller.markReported(original);
      controller.markReported(marked);
      expect(notifications, 1);

      await environment.settings.saveProvider(
        _provider(
          AiFormat.chatCompletions,
          id: 'other',
          requiresKey: true,
          model: 'other-model',
        ),
      );
      await environment.settings.saveProviderKey(
        'other',
        lateSecret,
        acknowledgeWarning: true,
      );
      await controller.recheck();
      final redacted = controller.items.whereType<AiAssistantItem>().single;
      expect(redacted.text, isNot(contains(lateSecret)));
      expect(redacted.text, contains('REDACTED'));
      expect(redacted.source, same(original.source));
      expect(redacted.reported, isTrue);
      await environment.settings.saveProviderKey(
        'other',
        'REDACTED',
        acknowledgeWarning: true,
      );
      await controller.recheck();
      final hidden = controller.items.whereType<AiAssistantItem>().single;
      expect(hidden.state, AiAssistantState.hidden);
      expect(hidden.text, isEmpty);
      expect(hidden.source, same(original.source));
      expect(hidden.reported, isTrue);
      expect(controller.currentOf(original), same(hidden));
    },
  );

  test(
    'a report completed after redaction marks and saves its descendant',
    () async {
      const lateSecret = 'synthetic-delayed-report-secret-789';
      final store = MemoryAiStore();
      final environment = await _environment(aiStore: store);
      addTearDown(environment.dispose);
      final root = await Directory.systemTemp.createTemp('mr6a4-descendant-');
      final history = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
      addTearDown(() async {
        AiHistoryCoordinator.debugReset();
        await root.delete(recursive: true);
      });
      final controller = await _readyController(
        environment,
        FakeAdapter((_) => _sse(answer('answer $lateSecret'))),
        tools: false,
      );
      final account = environment.workspace.account.key;
      expect(await history.enable(account), AiHistoryState.ready);
      await environment.settings.loadAccount(account);
      await controller.send('first');
      expect(controller.historySaved, isFalse);
      final original = controller.items.whereType<AiAssistantItem>().single;
      expect(controller.currentOf(original), same(original));

      await environment.settings.saveProvider(
        _provider(AiFormat.responses, id: 'other', requiresKey: true),
      );
      await environment.settings.saveProviderKey(
        'other',
        lateSecret,
        acknowledgeWarning: true,
      );
      await controller.recheck();
      final rebuilt = controller.items.whereType<AiAssistantItem>().single;
      expect(rebuilt, isNot(same(original)));
      expect(rebuilt.text, isNot(contains(lateSecret)));
      expect(controller.currentOf(original), same(rebuilt));
      controller.markReported(original);
      await _waitUntil(() => controller.historySaved);
      final marked = controller.items.whereType<AiAssistantItem>().single;
      expect(marked.reported, isTrue);
      expect(controller.currentOf(original), same(marked));
      final saved = (await history.read(account))!.conversations.single;
      final restored = saved.conversation.items
          .whereType<AiAssistantItem>()
          .single;
      expect(restored.reported, isTrue);
      expect(restored.text, rebuilt.text);

      controller.startNewConversation();
      await controller.recheck();
      await controller.send('second');
      final fresh = controller.items.whereType<AiAssistantItem>().single;
      expect(controller.currentOf(original), isNull);
      expect(controller.currentOf(marked), isNull);
      expect(controller.currentOf(fresh), same(fresh));
      controller.markReported(original);
      controller.markReported(marked);
      expect(
        controller.items.whereType<AiAssistantItem>().single.reported,
        isFalse,
      );
      expect(controller.historySaved, isFalse);
      expect(controller.reportNotSaved, isFalse);
      const unrelated = AiAssistantItem(
        text: 'answer',
        state: AiAssistantState.done,
      );
      expect(controller.currentOf(unrelated), isNull);
    },
  );

  test(
    'reporting a streaming answer survives settle and saves encrypted history',
    () async {
      final store = MemoryAiStore();
      final environment = await _environment(aiStore: store);
      addTearDown(environment.dispose);
      final root = await Directory.systemTemp.createTemp('mr6a4-report-');
      final history = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
      addTearDown(() async {
        AiHistoryCoordinator.debugReset();
        await root.delete(recursive: true);
      });
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
      final controller = await _readyController(
        environment,
        adapter,
        tools: false,
      );
      final account = environment.workspace.account.key;
      expect(await history.enable(account), AiHistoryState.ready);
      await environment.settings.loadAccount(account);
      final send = controller.send('stream');
      await _waitFor(() => adapter.requests.isNotEmpty);
      stream.add(
        Uint8List.fromList(
          utf8.encode(
            _partialEvents(AiFormat.responses, 'partial'.padRight(256, '!')),
          ),
        ),
      );
      await _waitFor(
        () => controller.items
            .whereType<AiAssistantItem>()
            .single
            .text
            .isNotEmpty,
      );
      final partial = controller.items.whereType<AiAssistantItem>().single;
      expect(partial.source?.model, 'synthetic-model');
      controller.markReported(partial);
      // This read joins the coordinator's queue after the report save.
      final during = await history.read(account);
      expect(during!.conversations.single.id, controller.id);
      expect(
        (during.conversations.single.conversation.items.last as AiAssistantItem)
            .reported,
        isTrue,
      );
      stream.add(Uint8List.fromList(utf8.encode(answer('complete answer'))));
      await stream.close();
      await send;
      final settled = controller.items.whereType<AiAssistantItem>().single;
      expect(settled.state, AiAssistantState.done);
      expect(settled.source, same(partial.source));
      expect(settled.reported, isTrue);
      expect(controller.currentOf(partial), same(settled));
      final saved = (await history.read(account))!.conversations.single;
      final restored = saved.conversation.items
          .whereType<AiAssistantItem>()
          .single;
      expect(restored.text, settled.text);
      expect(restored.reported, isTrue);
      expect(restored.source?.presetId, partial.source?.presetId);
      expect(restored.source?.format, partial.source?.format);
      expect(restored.source?.model, partial.source?.model);
      expect(controller.historySaved, isTrue);
      Future<AiAssistantItem> savedWhen(
        bool Function(AiAssistantItem) matches,
      ) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          final snapshot = (await history.read(account))!.conversations.single;
          final answer = snapshot.conversation.items
              .whereType<AiAssistantItem>()
              .single;
          if (matches(answer)) return answer;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        fail('queued report snapshot was not persisted');
      }

      await environment.settings.saveProvider(
        _provider(AiFormat.responses, id: 'other', requiresKey: true),
      );
      await environment.settings.saveProviderKey(
        'other',
        'complete answer',
        acknowledgeWarning: true,
      );
      await controller.recheck();
      final redactedAnswer = await savedWhen(
        (answer) => !answer.text.contains('complete answer'),
      );
      expect(redactedAnswer.text, isNot(contains('complete answer')));
      expect(redactedAnswer.reported, isTrue);
      expect(redactedAnswer.source?.model, partial.source?.model);
      await environment.settings.saveProviderKey(
        'other',
        'REDACTED',
        acknowledgeWarning: true,
      );
      await controller.recheck();
      final hiddenAnswer = await savedWhen(
        (answer) => answer.state == AiAssistantState.hidden,
      );
      expect(hiddenAnswer.text, isEmpty);
      expect(hiddenAnswer.state, AiAssistantState.hidden);
      expect(hiddenAnswer.reported, isTrue);
      expect(hiddenAnswer.source?.model, partial.source?.model);
      final files = root.listSync(recursive: true).whereType<File>();
      expect(files, isNotEmpty);
      for (final file in files) {
        expect(
          utf8.decode(file.readAsBytesSync(), allowMalformed: true),
          isNot(contains('complete answer')),
        );
      }
    },
  );

  test('pending reported history retries after storage recovers', () async {
    final store = MemoryAiStore();
    final environment = await _environment(aiStore: store);
    addTearDown(environment.dispose);
    final root = await Directory.systemTemp.createTemp('mr6a4-retry-');
    var failWrites = false;
    var writes = 0;
    final history = AiHistoryCoordinator.debugReset(
      store: store,
      files: AiHistoryFileStore(
        root: () async {
          writes++;
          if (failWrites) throw const FileSystemException('synthetic outage');
          return root;
        },
      ),
    );
    addTearDown(() async {
      AiHistoryCoordinator.debugReset();
      await root.delete(recursive: true);
    });
    final controller = await _readyController(
      environment,
      FakeAdapter((_) => _sse(answer('persist this report'))),
      tools: false,
    );
    final account = environment.workspace.account.key;
    expect(await history.enable(account), AiHistoryState.ready);
    await environment.settings.loadAccount(account);
    await controller.send('first');
    failWrites = true;
    controller.markReported(
      controller.items.whereType<AiAssistantItem>().single,
    );
    await _waitFor(() => history.saveFailed(account, controller.id));
    expect(
      controller.items.whereType<AiAssistantItem>().single.reported,
      isTrue,
    );
    expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    failWrites = false;
    final before = writes;
    await _waitUntil(() => controller.historySaved);
    expect(writes, greaterThan(before));
    expect(history.saveFailed(account, controller.id), isFalse);
    final saved = (await history.read(account))!.conversations.single;
    expect(saved.id, controller.id);
    final restored = saved.conversation.items
        .whereType<AiAssistantItem>()
        .single;
    expect(restored.reported, isTrue);
    expect(restored.text, 'persist this report');
  });

  test('two failing controllers share bounded retry scheduling', () async {
    // Retries far beyond the window, so a slow machine cannot add one.
    const slow = [
      Duration(seconds: 30),
      Duration(seconds: 30),
      Duration(seconds: 30),
    ];
    final store = MemoryAiStore();
    final environment = await _environment(aiStore: store);
    addTearDown(environment.dispose);
    final root = await Directory.systemTemp.createTemp('mr6a4-two-retries-');
    var failWrites = false;
    var attempts = 0;
    final history = AiHistoryCoordinator.debugReset(
      store: store,
      files: AiHistoryFileStore(
        root: () async {
          if (failWrites) {
            attempts++;
            throw const FileSystemException('synthetic outage');
          }
          return root;
        },
      ),
    );
    addTearDown(() async {
      AiHistoryCoordinator.debugReset();
      await root.delete(recursive: true);
    });
    final first = await _readyController(
      environment,
      FakeAdapter((_) => _sse(answer('first answer'))),
      tools: false,
      historyRetryDelays: slow,
    );
    final second = await _readyController(
      environment,
      FakeAdapter((_) => _sse(answer('second answer'))),
      tools: false,
      historyRetryDelays: slow,
    );
    final account = environment.workspace.account.key;
    expect(await history.enable(account), AiHistoryState.ready);
    await environment.settings.loadAccount(account);
    await first.recheck();
    await second.recheck();
    await first.send('first');
    await second.send('second');
    failWrites = true;
    first.markReported(first.items.whereType<AiAssistantItem>().single);
    second.markReported(second.items.whereType<AiAssistantItem>().single);
    await _waitUntil(
      () =>
          history.saveFailed(account, first.id) &&
          history.saveFailed(account, second.id),
    );
    // Ready notifications and rechecks must not bypass the scheduled timer.
    for (var i = 0; i < 3; i++) {
      history.acknowledgeNotices(account);
      await first.recheck();
      await second.recheck();
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // One attempt each; a listener that flushed on every ready emit, or a
    // flush that ignored the pending timer, would add more in this window.
    expect(attempts, 2);
    expect(first.historySaved, isFalse);
    expect(second.historySaved, isFalse);
    expect(first.reportNotSaved, isFalse);
    expect(second.reportNotSaved, isFalse);
  });

  test(
    'permanent report save failure waits for a new snapshot and clears on success',
    () async {
      final store = MemoryAiStore();
      final environment = await _environment(aiStore: store);
      addTearDown(environment.dispose);
      final root = await Directory.systemTemp.createTemp('mr6a4-permanent-');
      var now = DateTime.now().toUtc();
      var accesses = 0;
      final history = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(
          root: () async {
            accesses++;
            return root;
          },
          clock: () => now,
        ),
      );
      addTearDown(() async {
        AiHistoryCoordinator.debugReset();
        await root.delete(recursive: true);
      });
      final controller = await _readyController(
        environment,
        FakeAdapter((_) => _sse(answer('reported answer'))),
        tools: false,
      );
      final account = environment.workspace.account.key;
      expect(await history.enable(account), AiHistoryState.ready);
      await environment.settings.loadAccount(account);
      await controller.send('first');
      // Make the fresh snapshot expire during the file store's retention pass.
      now = now.add(const Duration(days: 91));
      controller.markReported(
        controller.items.whereType<AiAssistantItem>().single,
      );
      await _waitUntil(() => controller.reportNotSaved);
      expect(history.evicted(account, controller.id), isTrue);
      expect(controller.historySaved, isFalse);
      final afterFailure = accesses;
      history.acknowledgeNotices(account);
      await controller.recheck();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(accesses, afterFailure);
      expect(controller.reportNotSaved, isTrue);

      now = DateTime.now().toUtc();
      await controller.send('new snapshot');
      await _waitUntil(() => controller.historySaved);
      expect(controller.reportNotSaved, isFalse);
      expect(history.evicted(account, controller.id), isFalse);
      final saved = (await history.read(account))!.conversations.single;
      expect(
        saved.conversation.items.whereType<AiAssistantItem>().first.reported,
        isTrue,
      );
    },
  );

  test(
    'exhausted report retries stay stopped until a new snapshot succeeds',
    () async {
      final store = MemoryAiStore();
      final environment = await _environment(aiStore: store);
      addTearDown(environment.dispose);
      final root = await Directory.systemTemp.createTemp('mr6a4-exhausted-');
      var failWrites = false;
      var attempts = 0;
      final history = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(
          root: () async {
            if (failWrites) {
              attempts++;
              throw const FileSystemException('synthetic outage');
            }
            return root;
          },
        ),
      );
      addTearDown(() async {
        AiHistoryCoordinator.debugReset();
        await root.delete(recursive: true);
      });
      // The same 1/5/30 s schedule, in milliseconds.
      final controller = await _readyController(
        environment,
        FakeAdapter((_) => _sse(answer('reported answer'))),
        tools: false,
        historyRetryDelays: const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 50),
          Duration(milliseconds: 300),
        ],
      );
      final account = environment.workspace.account.key;
      expect(await history.enable(account), AiHistoryState.ready);
      await environment.settings.loadAccount(account);
      await controller.send('first');
      failWrites = true;
      controller.markReported(
        controller.items.whereType<AiAssistantItem>().single,
      );
      await _waitUntil(() => controller.reportNotSaved);
      expect(attempts, 4);
      expect(controller.historySaved, isFalse);
      failWrites = false;
      history.acknowledgeNotices(account);
      await controller.recheck();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(controller.historySaved, isFalse);
      expect(controller.reportNotSaved, isTrue);
      await controller.send('try a new snapshot');
      await _waitUntil(() => controller.historySaved);
      expect(controller.reportNotSaved, isFalse);
    },
  );

  test('a recovery during a flush also saves what that flush skipped', () async {
    final store = MemoryAiStore();
    final environment = await _environment(aiStore: store);
    addTearDown(environment.dispose);
    final root = await Directory.systemTemp.createTemp('mr6a4-drain-');
    var failRoot = false;
    final history = AiHistoryCoordinator.debugReset(
      store: store,
      files: AiHistoryFileStore(
        root: () async {
          if (failRoot) throw const FileSystemException('synthetic outage');
          return root;
        },
      ),
    );
    addTearDown(() async {
      AiHistoryCoordinator.debugReset();
      await root.delete(recursive: true);
    });
    final controller = await _readyController(
      environment,
      FakeAdapter((_) => _sse(answer('synthetic reply'))),
      tools: false,
    );
    final account = environment.workspace.account.key;
    expect(await history.enable(account), AiHistoryState.ready);
    await environment.settings.loadAccount(account);
    // Conversation A is reported while another account's (sparse) file
    // fills the device cap, so A's snapshot is blocked.
    await controller.send('conversation A');
    final oldId = controller.id;
    final foreign = File(
      '${root.path}/ai_history/${'f' * 32}/c_${'e' * 32}.v1.bin',
    );
    foreign.parent.createSync(recursive: true);
    final handle = foreign.openSync(mode: FileMode.write);
    handle.truncateSync(AiHistoryFileStore.deviceByteLimit);
    handle.closeSync();
    controller.markReported(
      controller.items.whereType<AiAssistantItem>().single,
    );
    await _waitUntil(() => controller.reportNotSaved);
    controller.startNewConversation();
    await controller.recheck();
    foreign.deleteSync();
    // B's save is what turns a failed read back into ready, mid-flush.
    await controller.send('conversation B');
    failRoot = true;
    expect(await history.read(account), isNull);
    expect(history.state(account), AiHistoryState.readFailed);
    failRoot = false;
    controller.markReported(
      controller.items.whereType<AiAssistantItem>().single,
    );
    await _waitUntil(() => controller.historySaved);
    // No recheck, no new snapshot: the flush that ended after the recovery
    // saves A by itself.
    var savedA = false;
    final elapsed = Stopwatch()..start();
    while (!savedA && elapsed.elapsed < const Duration(seconds: 10)) {
      savedA =
          (await history.read(account))?.conversations.any(
            (conversation) => conversation.id == oldId,
          ) ??
          false;
      if (!savedA) await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(savedA, isTrue);
  });

  test(
    'a fresh conversation after kept display starts at its first item',
    () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      final adapters = <FakeAdapter>[];
      final controller = _controller(
        environment,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) {
              final adapter = FakeAdapter((_) => _sse(answer('Final answer')));
              adapters.add(adapter);
              return _wireClient(
                adapter,
                config: config,
                apiKey: apiKey,
                conversationId: conversationId,
              );
            },
      );
      addTearDown(controller.dispose);
      await _configure(
        environment,
        _provider(AiFormat.responses),
        grantConsent: true,
      );
      await controller.recheck();
      await controller.send('earlier question');
      final changed = await environment.settings.saveProvider(
        _provider(AiFormat.responses, model: 'changed-model'),
      );
      await environment.settings.grantConsent(
        environment.workspace.account.key,
        aiConversationConsentContract(
          environment.settings,
          environment.workspace.account.key,
          changed, releasePolicy: fixtureReleasePolicy
        ),
        const {'synthetic': true},
      );
      await controller.recheck();
      expect(
        controller.items.last,
        isA<AiNoticeItem>().having(
          (item) => item.kind,
          'kind',
          AiNoticeKind.newConversation,
        ),
      );
      // A conversation started from scratch owns everything from index 0 again.
      controller.startNewConversation();
      await controller.recheck();
      await controller.send('fresh question');
      final answer0 = controller.items.whereType<AiAssistantItem>().single;
      expect(controller.currentOf(answer0), same(answer0));
    },
  );

  test(
    'a saved snapshot leaves out display kept from an earlier conversation',
    () async {
      final store = MemoryAiStore();
      final environment = await _environment(aiStore: store);
      addTearDown(environment.dispose);
      final root = await Directory.systemTemp.createTemp('mr6a4-kept-');
      final history = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
      addTearDown(() async {
        AiHistoryCoordinator.debugReset();
        await root.delete(recursive: true);
      });
      final controller = _controller(
        environment,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                _wireClient(
                  FakeAdapter((_) => _sse(answer('Final answer'))),
                  config: config,
                  apiKey: apiKey,
                  conversationId: conversationId,
                ),
      );
      addTearDown(controller.dispose);
      await _configure(
        environment,
        _provider(AiFormat.responses),
        grantConsent: true,
      );
      final account = environment.workspace.account.key;
      expect(await history.enable(account), AiHistoryState.ready);
      await environment.settings.loadAccount(account);
      await controller.recheck();
      await controller.send('earlier question');
      final firstId = controller.id;
      controller.markReported(
        controller.items.whereType<AiAssistantItem>().single,
      );
      await _waitUntil(() => controller.historySaved);
      final changed = await environment.settings.saveProvider(
        _provider(AiFormat.responses, model: 'changed-model'),
      );
      await environment.settings.grantConsent(
        account,
        aiConversationConsentContract(
          environment.settings,
          environment.workspace.account.key,
          changed, releasePolicy: fixtureReleasePolicy
        ),
        const {'synthetic': true},
      );
      await controller.recheck();
      expect(controller.id, isNot(firstId));
      await controller.send('new question with nothing reported');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final saved = (await history.read(account))!.conversations;
      // Only the earlier conversation, which holds the report, is saved.
      expect(saved.map((conversation) => conversation.id), [firstId]);
      expect(controller.reportNotSaved, isFalse);
      // Once this conversation has its own report, it is saved without the
      // earlier conversation's items.
      controller.markReported(
        controller.items.whereType<AiAssistantItem>().last,
      );
      await _waitUntil(() => controller.historySaved);
      final secondId = controller.id;
      final second = (await history.read(account))!.conversations.singleWhere(
        (conversation) => conversation.id == secondId,
      );
      final items = second.conversation.items;
      expect(
        items.first,
        isA<AiUserItem>().having(
          (item) => item.text,
          'text',
          'new question with nothing reported',
        ),
      );
      expect(
        items.whereType<AiUserItem>().map((item) => item.text),
        isNot(contains('earlier question')),
      );
    },
  );

  test(
    'a kept reported answer does not mark a new conversation not saved',
    () async {
      final store = MemoryAiStore();
      final environment = await _environment(aiStore: store);
      addTearDown(environment.dispose);
      var failWrites = false;
      final root = await Directory.systemTemp.createTemp('mr6a4-kept-unsaved-');
      final history = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(
          root: () async {
            if (failWrites) {
              throw const FileSystemException('synthetic outage');
            }
            return root;
          },
        ),
      );
      addTearDown(() async {
        AiHistoryCoordinator.debugReset();
        await root.delete(recursive: true);
      });
      final controller = _controller(
        environment,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                _wireClient(
                  FakeAdapter((_) => _sse(answer('Final answer'))),
                  config: config,
                  apiKey: apiKey,
                  conversationId: conversationId,
                ),
        historyRetryDelays: const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 50),
          Duration(milliseconds: 300),
        ],
      );
      addTearDown(controller.dispose);
      await _configure(
        environment,
        _provider(AiFormat.responses),
        grantConsent: true,
      );
      final account = environment.workspace.account.key;
      expect(await history.enable(account), AiHistoryState.ready);
      await environment.settings.loadAccount(account);
      await controller.recheck();
      await controller.send('earlier question');
      final firstId = controller.id;
      controller.markReported(
        controller.items.whereType<AiAssistantItem>().single,
      );
      // The earlier conversation's save fails for good, so it shows not
      // saved there.
      failWrites = true;
      await _waitUntil(() => controller.reportNotSaved);
      expect(controller.historySaved, isFalse);
      // A new conversation keeps the reported answer on screen but has
      // nothing of its own waiting to be saved.
      final changed = await environment.settings.saveProvider(
        _provider(AiFormat.responses, model: 'changed-model'),
      );
      await environment.settings.grantConsent(
        account,
        aiConversationConsentContract(
          environment.settings,
          environment.workspace.account.key,
          changed, releasePolicy: fixtureReleasePolicy
        ),
        const {'synthetic': true},
      );
      await controller.recheck();
      expect(controller.id, isNot(firstId));
      await controller.send('new question with nothing reported');
      expect(controller.reportNotSaved, isFalse);
      expect(controller.historySaved, isFalse);
      // The new conversation's own unsaved report still shows.
      controller.markReported(
        controller.items.whereType<AiAssistantItem>().last,
      );
      await _waitUntil(() => controller.reportNotSaved);
    },
  );

  test('a failed refresh blocks an idle chat but leaves a run alone', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    var fail = false;
    final stream = StreamController<Uint8List>();
    addTearDown(() async {
      if (!stream.isClosed) await stream.close();
    });
    var requests = 0;
    final controller = await _readyController(
      environment,
      FakeAdapter((_) async {
        requests++;
        if (requests > 1) {
          return ResponseBody(
            stream.stream,
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
          );
        }
        return _sse(answer('synthetic reply'));
      }),
      tools: false,
      refreshSecrets: () async {
        if (fail) throw StateError('synthetic secret store failure');
      },
    );
    await controller.send('first');
    // During a run, while the reply streams: the phase, and Stop, stay.
    final second = controller.send('second');
    await _waitFor(() => requests > 1);
    // Pad past the first display threshold so the partial reply is shown
    // while still streaming.
    const partial = 'partial reply';
    stream.add(
      Uint8List.fromList(
        utf8.encode(
          _partialEvents(AiFormat.responses, partial.padRight(256, '!')),
        ),
      ),
    );
    await _waitFor(
      () => controller.items.whereType<AiAssistantItem>().any(
        (item) => item.text.contains(partial),
      ),
    );
    expect(controller.phase, AiChatPhase.running);
    fail = true;
    expect(await controller.refreshSecrets(), isFalse);
    expect(controller.phase, AiChatPhase.running);
    expect(controller.blocker, AiChatBlocker.none);
    fail = false;
    stream.add(Uint8List.fromList(utf8.encode(answer('complete reply'))));
    await stream.close();
    await second;
    expect(controller.phase, AiChatPhase.idle);
    expect(
      controller.items.whereType<AiAssistantItem>().last.text,
      'complete reply',
    );
    // While idle: the chat stops until the display can be checked.
    fail = true;
    expect(await controller.refreshSecrets(), isFalse);
    expect(controller.blocker, AiChatBlocker.contextUnavailable);
  });

  test('report saves retry after 1, 5 and 30 seconds', () {
    expect(AiChatController.defaultHistoryRetryDelays, const [
      Duration(seconds: 1),
      Duration(seconds: 5),
      Duration(seconds: 30),
    ]);
  });

  test('a missing history key says the mark is not saved at once', () async {
    final store = MemoryAiStore();
    final environment = await _environment(aiStore: store);
    addTearDown(environment.dispose);
    final root = await Directory.systemTemp.createTemp('mr6a4-no-key-');
    final account = environment.workspace.account.key;
    await store.saveAccount(account, AiAccountRecord(historyEnabled: true));
    final history = AiHistoryCoordinator.debugReset(
      store: store,
      files: AiHistoryFileStore(root: () async => root),
    );
    addTearDown(() async {
      AiHistoryCoordinator.debugReset();
      await root.delete(recursive: true);
    });
    final controller = await _readyController(
      environment,
      FakeAdapter((_) => _sse(answer('synthetic reply'))),
      tools: false,
    );
    expect(await history.load(account), AiHistoryState.keyMissing);
    await environment.settings.loadAccount(account);
    await controller.send('question');
    controller.markReported(
      controller.items.whereType<AiAssistantItem>().single,
    );
    // A missing key does not come back on a timer; the fold says so now,
    // not after attempts that never happen.
    await _waitUntil(() => controller.reportNotSaved);
    expect(controller.historySaved, isFalse);
    expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('the report text sees a token OAuth rotated in place', () async {
    const oldAccess = 'synthetic-old-opaque-access';
    const newAccess = 'synthetic-new-opaque-access-12345';
    const newRefresh = 'synthetic-new-opaque-refresh-56789';
    final workspace = WorkspaceFixture();
    final account = Account(
      instance: workspace.account.instance,
      user: workspace.account.user,
      credential: const OAuthCredential(
        accessToken: oldAccess,
        refreshToken: 'synthetic-old-opaque-refresh',
        clientId: 'synthetic-client',
      ),
    );
    final accounts = MemoryAccountStore()
      ..accounts = [account]
      ..lastActive = account.key;
    var rotate = false;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/oauth/token')) {
        return jsonResponse({
          'access_token': newAccess,
          'refresh_token': newRefresh,
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      }
      if (rotate && request.headers['Authorization'] == 'Bearer $oldAccess') {
        return jsonResponse({'message': 'synthetic expired'}, status: 401);
      }
      return workspace.respond(request);
    });
    final session = controllerFor(
      accounts,
      adapter,
      createOAuth: (instance, clientId) => OAuthTokenClient(
        instance: instance,
        clientId: clientId,
        dio: Dio()..httpClientAdapter = adapter,
      ),
    );
    await session.initialize();
    final environment = _Environment(
      workspace,
      session,
      AiSettingsController(MemoryAiStore()),
    );
    addTearDown(environment.dispose);
    // The answer quotes what is later the rotated access token.
    final controller = await _readyController(
      environment,
      FakeAdapter((_) => _sse(answer('the answer quotes $newAccess'))),
      tools: false,
    );
    await controller.send('question');
    var notified = 0;
    controller.addListener(() => notified++);
    final generation = session.generation;
    rotate = true;
    await session.api!.currentUser();
    expect(session.api!.credential.accessToken, newAccess);
    expect(session.generation, generation);
    const pasted = 'pasted $newAccess and $newRefresh';
    notified = 0;
    expect(await controller.refreshSecrets(), isTrue);
    // While idle the larger set re-redacts what is shown, and the page hears.
    expect(
      controller.items.whereType<AiAssistantItem>().single.text,
      isNot(contains(newAccess)),
    );
    expect(notified, greaterThan(0));
    final safe = controller.draftSafe(pasted);
    expect(safe, isNot(contains(newAccess)));
    expect(safe, isNot(contains(newRefresh)));
  });

  for (final format in AiFormat.values) {
    test(
      '${format.name} provider request bytes ignore report and source metadata',
      () async {
        Future<List<String>> requests(bool report) async {
          final environment = await _environment();
          addTearDown(environment.dispose);
          await _configure(environment, _provider(format), grantConsent: true);
          final adapter = FakeAdapter(
            (_) => _sse(_toolThenAnswer(format).last),
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
          await controller.send('first');
          final item = controller.items.whereType<AiAssistantItem>().single;
          expect(item.source?.format, format.name);
          if (report) controller.markReported(item);
          await controller.send('follow up');
          expect(controller.failure, isNull);
          expect(adapter.requests, hasLength(2));
          return adapter.requests
              .map((request) => jsonEncode(request.data))
              .toList();
        }

        expect(await requests(true), await requests(false));
      },
    );
  }

  test('a display pass that fails is tried again, not skipped', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final adapter = FakeAdapter((_) => _sse(answer('done')));
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    await controller.send('first');
    expect(controller.blocker, AiChatBlocker.none);

    // The redactor refuses a secret that sits inside its own marker.
    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'other', requiresKey: true),
    );
    await environment.settings.saveProviderKey(
      'other',
      'REDACTED',
      acknowledgeWarning: true,
    );
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.contextUnavailable);
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.contextUnavailable);
    expect(controller.canSend, isFalse);
  });

  test('a secret learned while blocked leaves the conversation', () async {
    const value = 'synthetic-local-key-77';
    final environment = await _environment();
    addTearDown(environment.dispose);
    final adapter = FakeAdapter((_) => _sse(answer('the key is $value')));
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    await controller.send('what is the key?');
    expect(
      controller.items.whereType<AiAssistantItem>().single.text,
      contains(value),
    );

    await environment.settings.revokeConsent(
      environment.workspace.account.key,
      'provider',
    );
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.consentRequired);
    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'other', requiresKey: true),
    );
    await environment.settings.saveProviderKey(
      'other',
      value,
      acknowledgeWarning: true,
    );
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.consentRequired);
    expect(
      controller.items.whereType<AiAssistantItem>().single.text,
      isNot(contains(value)),
    );
  });

  // The request left the device, so its chips stay even though it failed;
  // the context was not delivered, so the next request carries it again and
  // says so too.
  test('chips stay on a request that was sent and failed', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    var calls = 0;
    final adapter = FakeAdapter(
      (_) => ++calls == 1
          ? jsonResponse({'error': 'synthetic outage'}, status: 500)
          : _sse(answer('done')),
    );
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    await controller.send('first');
    expect(controller.failure, isNotNull);
    expect(controller.items.whereType<AiUserItem>().single.chips, isNotEmpty);

    await controller.send('second');
    final users = controller.items.whereType<AiUserItem>().toList();
    expect(users.first.chips, isNotEmpty);
    final chip = users.last.chips.single;
    expect(chip.sentText, _sentGitLabData(adapter.requests.last));
  });

  test('a summary sent after a new key is what the chip shows', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    var calls = 0;
    final adapter = FakeAdapter(
      (_) => ++calls == 1
          ? jsonResponse({'error': 'bad key'}, status: 401)
          : _sse(answer('done')),
    );
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
      requiresKey: true,
    );
    await controller.send('first');
    expect(controller.failure, isNotNull);

    // A corrected key keeps consent but starts a projected segment.
    await environment.settings.saveProviderKey(
      'provider',
      'synthetic-provider-key-0002',
      acknowledgeWarning: true,
    );
    await controller.recheck();
    await controller.send('second');
    final chip = controller.items.whereType<AiUserItem>().last.chips.single;
    expect(chip.sentText, _sentGitLabData(adapter.requests.last));
    expect(chip.source, 'conversation_summary');
    expect(chip.resource, isNull);
  });

  test('chips never show a secret learned during the send', () async {
    // Learn the secret at each refresh of the send in turn: before the
    // context is attached, between attaching and sending, and after. The
    // second secret is encoded in the request (`&amp;`, `&lt;`, `&gt;`).
    for (final late in const [
      'synthetic-late-chip-value-0091',
      'synthetic&late<chip>value-0092',
    ]) {
      final escaped = late
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      for (var k = 1; k <= 10; k++) {
        final environment = await _environment(
          repositoryText: 'first line\nvalue $late here\n',
        );
        addTearDown(environment.dispose);
        var armed = false;
        var learned = false;
        var refreshes = 0;
        final adapter = FakeAdapter((_) => _sse(answer('a reply')));
        final controller = await _readyController(
          environment,
          adapter,
          tools: false,
          refreshSecrets: () async {
            if (!armed || ++refreshes != k) return;
            learned = true;
            await environment.settings.saveProviderKey(
              'other',
              late,
              acknowledgeWarning: true,
            );
          },
        );
        await environment.settings.saveProvider(
          _provider(AiFormat.responses, id: 'other', requiresKey: true),
        );
        await controller.recheck();
        armed = true;
        await controller.send('explain');
        final chip = controller.items
            .whereType<AiUserItem>()
            .single
            .chips
            .single;
        final sent = _sentGitLabData(adapter.requests.single);
        if (learned) {
          for (final form in {late, escaped}) {
            expect(chip.sentText, isNot(contains(form)), reason: '$form k=$k');
            expect(chip.preview, isNot(contains(form)), reason: '$form k=$k');
          }
        }
        if (!sent.contains(escaped)) {
          expect(chip.sentText, sent, reason: '$late k=$k');
        }
      }
    }
  });

  test('a secret learned after the run is redacted in its chips', () async {
    const late = 'synthetic&late<after>value-0093';
    const escaped = 'synthetic&amp;late&lt;after&gt;value-0093';
    final environment = await _environment(
      repositoryText: 'first line\nvalue $late here\n',
    );
    addTearDown(environment.dispose);
    final adapter = FakeAdapter((_) => _sse(answer('a reply')));
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    await controller.send('explain');
    expect(_sentGitLabData(adapter.requests.single), contains(escaped));

    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'other', requiresKey: true),
    );
    await environment.settings.saveProviderKey(
      'other',
      late,
      acknowledgeWarning: true,
    );
    await controller.recheck();
    final chip = controller.items.whereType<AiUserItem>().single.chips.single;
    for (final form in [late, escaped]) {
      expect(chip.sentText, isNot(contains(form)), reason: form);
      expect(chip.preview, isNot(contains(form)), reason: form);
    }
    expect(chip.sentText, contains('[REDACTED]'));
    // The label still says how much was sent.
    expect(chip.sizeChars, _sentGitLabData(adapter.requests.single).length);
  });

  for (final kind in AiWorkItemKind.values) {
    for (final field in ['internal', 'confidential']) {
      test(
        '$kind $field note marks prepared, settled and redacted chips',
        () async {
          const lateSecret = 'synthetic-internal-note-0094';
          final workspace = WorkspaceFixture();
          workspace.mergeFields['diff_refs'] = {
            'head_sha': WorkspaceFixture.sha,
            'base_sha': WorkspaceFixture.sha,
          };
          workspace.issues[3] = {
            'iid': 3,
            'title': 'Synthetic issue',
            'description': '',
            'state': 'opened',
          };
          final environment = await _environment(
            gitLabRespond: (request) {
              if (request.uri.path.endsWith('/notes')) {
                return jsonResponse([
                  {
                    'body': lateSecret,
                    'created_at': '2026-10-22T00:00:00Z',
                    'system': false,
                    field: true,
                  },
                ]);
              }
              return workspace.respond(request);
            },
          );
          addTearDown(environment.dispose);
          final response = Completer<ResponseBody>();
          final adapter = FakeAdapter((_) => response.future);
          final controller = await _readyController(
            environment,
            adapter,
            tools: false,
            origin: AiWorkItemOrigin(
              project: environment.workspace.project,
              kind: kind,
              iid: kind == AiWorkItemKind.issue ? 3 : 12,
              title: 'Synthetic item',
            ),
          );
          expect(controller.blocker, AiChatBlocker.none);
          final sending = controller.send('Explain this item');
          await _waitFor(() => adapter.requests.isNotEmpty);
          AiContextChip chip() =>
              controller.items.whereType<AiUserItem>().single.chips.single;
          expect(chip().internal, isTrue);
          response.complete(_sse(answer('A synthetic answer')));
          await sending;
          expect(controller.failure, isNull);
          expect(chip().internal, isTrue);
          expect(chip().sentText, contains(lateSecret));

          await environment.settings.saveProvider(
            _provider(AiFormat.responses, id: 'other', requiresKey: true),
          );
          await environment.settings.saveProviderKey(
            'other',
            lateSecret,
            acknowledgeWarning: true,
          );
          await controller.recheck();
          expect(chip().internal, isTrue);
          expect(chip().sentText, isNot(contains(lateSecret)));
          expect(chip().sentText, contains('[REDACTED]'));
        },
      );
    }
  }

  test('a request refused before sending takes its chips back', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString(
        '',
        429,
        headers: {
          'retry-after': ['60'],
        },
      ),
    );
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    await controller.send('first');
    // Within the remembered Retry-After the transport refuses locally.
    await controller.send('second');
    expect(adapter.requests, hasLength(1));
    final users = controller.items.whereType<AiUserItem>().toList();
    expect(users.first.chips, isNotEmpty);
    expect(users.last.chips, isEmpty);
  });

  test('a first request too long to send takes its chips back', () async {
    final environment = await _environment(
      repositoryText: List.filled(400, 'synthetic line of text').join('\n'),
    );
    addTearDown(environment.dispose);
    final adapter = FakeAdapter((_) => _sse(answer('a reply')));
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
      maxRequestChars: 6000,
    );
    await controller.send('explain');
    expect(adapter.requests, isEmpty);
    expect(controller.items.whereType<AiUserItem>().single.chips, isEmpty);
  });

  test('a stop mid-stream keeps the chips of what was sent', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
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
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    final send = controller.send('stream');
    await _waitFor(() => adapter.requests.isNotEmpty);
    stream.add(
      Uint8List.fromList(
        utf8.encode(
          _partialEvents(AiFormat.responses, 'partial'.padRight(256, '!')),
        ),
      ),
    );
    await _waitFor(
      () => controller.items.whereType<AiAssistantItem>().any(
        (item) => item.text.isNotEmpty,
      ),
    );
    controller.stop();
    await stream.close();
    await send;
    expect(controller.items.whereType<AiUserItem>().single.chips, isNotEmpty);
  });

  test('a display pass hides what it cannot check', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final adapter = FakeAdapter((_) => _sse(answer('a reply')));
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    await controller.send('first');
    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'other', requiresKey: true),
    );
    await environment.settings.saveProviderKey(
      'other',
      'REDACTED',
      acknowledgeWarning: true,
    );
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.contextUnavailable);
    expect(controller.items.whereType<AiUserItem>(), isEmpty);
    expect(
      controller.items.whereType<AiAssistantItem>().single,
      isA<AiAssistantItem>()
          .having((item) => item.text, 'text', isEmpty)
          .having((item) => item.state, 'state', AiAssistantState.hidden),
    );
    expect(controller.displaySafe('README.md'), isEmpty);
    expect(controller.draftSafe('README.md'), isEmpty);
  });

  testWidgets('the page shows the block when nothing can be checked', (
    tester,
  ) async {
    late _Environment environment;
    late AiChatController controller;
    await tester.runAsync(() async {
      environment = await _environment();
      final adapter = FakeAdapter((_) => _sse(answer('a reply')));
      controller = await _readyController(environment, adapter, tools: false);
      await controller.send('first');
      await environment.settings.saveProvider(
        _provider(AiFormat.responses, id: 'other', requiresKey: true),
      );
      await environment.settings.saveProviderKey(
        'other',
        'REDACTED',
        acknowledgeWarning: true,
      );
      await controller.recheck();
    });
    addTearDown(environment.dispose);
    expect(controller.blocker, AiChatBlocker.contextUnavailable);

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: AiChatPage(session: controller),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text(l10n.aiChatContextUnavailable), findsOneWidget);
  });

  test('a display pass that fails while sending blocks the chat', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    var armed = false;
    final adapter = FakeAdapter((_) => _sse(answer('a reply')));
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
      refreshSecrets: () async {
        if (!armed) return;
        armed = false;
        await environment.settings.saveProvider(
          _provider(AiFormat.responses, id: 'other', requiresKey: true),
        );
        await environment.settings.saveProviderKey(
          'other',
          'REDACTED',
          acknowledgeWarning: true,
        );
      },
    );
    await controller.send('first');
    final requests = adapter.requests.length;
    // The blocker the send itself ends with, before the recheck that the
    // settings change starts afterwards.
    AiChatBlocker? ended;
    UserFacingFailure? failure;
    void listener() {
      if (ended == null && controller.phase == AiChatPhase.idle) {
        ended = controller.blocker;
        failure = controller.failure;
      }
    }

    armed = true;
    controller.addListener(listener);
    await controller.send('second');
    controller.removeListener(listener);
    expect(adapter.requests, hasLength(requests));
    expect(ended, AiChatBlocker.contextUnavailable);
    expect(
      failure,
      isA<AiFailure>().having(
        (failure) => failure.kind,
        'kind',
        AiFailureKind.policyBlocked,
      ),
    );
    expect(controller.items.whereType<AiUserItem>(), isEmpty);
  });

  test('a display pass that fails during the run keeps its outcome', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    var sent = false;
    var learned = false;
    final adapter = FakeAdapter((_) {
      sent = true;
      return _sse(answer('a reply'));
    });
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
      refreshSecrets: () async {
        if (!sent || learned) return;
        learned = true;
        await environment.settings.saveProviderKey(
          'other',
          'REDACTED',
          acknowledgeWarning: true,
        );
      },
    );
    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'other', requiresKey: true),
    );
    await controller.recheck();
    AiChatBlocker? ended;
    void listener() {
      if (ended == null && controller.phase == AiChatPhase.idle) {
        ended = controller.blocker;
      }
    }

    controller.addListener(listener);
    await controller.send('explain');
    controller.removeListener(listener);
    expect(learned, isTrue);
    expect(ended, AiChatBlocker.contextUnavailable);
    expect(controller.lastEnd, AiRunEnd.failed);
    expect(
      controller.items.whereType<AiAssistantItem>().single.state,
      AiAssistantState.hidden,
    );
  });

  test('a list of notices alone does not clear the block', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final gate = Completer<void>();
    var holdRefresh = false;
    var refreshing = false;
    final adapter = FakeAdapter((_) => throw StateError('must not send'));
    final controller = await _readyController(
      environment,
      adapter,
      refreshSecrets: () async {
        if (holdRefresh) {
          refreshing = true;
          await gate.future;
        }
      },
    );
    holdRefresh = true;
    final send = controller.send('keep this draft');
    await _waitFor(() => refreshing);
    controller.stop();
    gate.complete();
    await send;
    holdRefresh = false;
    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'other', requiresKey: true),
    );
    await environment.settings.saveProviderKey(
      'other',
      'REDACTED',
      acknowledgeWarning: true,
    );
    await controller.recheck();
    expect(controller.items.whereType<AiUserItem>(), isEmpty);
    expect(controller.blocker, AiChatBlocker.contextUnavailable);
    // Only notices are left, but redaction still fails.
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.contextUnavailable);
    expect(controller.canSend, isFalse);
  });

  test('a display pass hides only what it cannot check', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final adapter = FakeAdapter((_) => _sse(answer('a reply')));
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'other', requiresKey: true),
    );
    await environment.settings.saveProviderKey(
      'other',
      'x[REDACTED]y',
      acknowledgeWarning: true,
    );
    await controller.recheck();
    await controller.send('first late-key-77');
    await controller.send('xlate-key-77y');
    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'third', requiresKey: true),
    );
    await environment.settings.saveProviderKey(
      'third',
      'late-key-77',
      acknowledgeWarning: true,
    );
    await controller.recheck();
    // Redacting the second message would spell the first key.
    expect(controller.blocker, AiChatBlocker.contextUnavailable);
    expect(controller.items.whereType<AiUserItem>().map((item) => item.text), [
      'first [REDACTED]',
    ]);
    await controller.recheck();
    expect(controller.blocker, AiChatBlocker.none);
  });

  test('a stop before sending keeps only the blocked-path chips', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final gate = Completer<void>();
    var holdRefresh = false;
    var refreshing = false;
    final adapter = FakeAdapter((_) => throw StateError('must not send'));
    final controller = await _readyController(
      environment,
      adapter,
      origin: AiFileOrigin(
        project: environment.workspace.project,
        path: '.env',
        sha: WorkspaceFixture.sha,
      ),
      refreshSecrets: () async {
        if (holdRefresh) {
          refreshing = true;
          await gate.future;
        }
      },
    );
    holdRefresh = true;
    final send = controller.send('inspect');
    await _waitFor(() => refreshing);
    controller.stop();
    gate.complete();
    await send;
    expect(adapter.requests, isEmpty);
    final chips = controller.items.whereType<AiUserItem>().single.chips;
    expect(chips, hasLength(1));
    expect(chips.single.blocked, isTrue);
    expect(chips.single.source, '.env');
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
      final tool = controller.items.whereType<AiToolRunItem>().single;
      expect(tool.status, AiToolRunStatus.completed);
      expect(tool.argsPreview, 'README.md');
      expect(
        controller.items.whereType<AiAssistantItem>().single,
        isA<AiAssistantItem>()
            .having((item) => item.text, 'text', 'Final answer')
            .having((item) => item.state, 'state', AiAssistantState.done),
      );
      // The read is listed above the answer that uses it.
      expect(
        controller.items.indexOf(tool),
        lessThan(
          controller.items.indexWhere((item) => item is AiAssistantItem),
        ),
      );
      // The chip names the page; its source stays the provenance tag.
      final chip = controller.items.whereType<AiUserItem>().single.chips.single;
      expect((chip.source, chip.resource), ('file', 'README.md'));
      expect(providerAdapter.requests, hasLength(2));
      expect(
        environment.workspace.adapter.requests.map((request) => request.method),
        everyElement(isIn(['GET', 'HEAD'])),
      );
    });
  }

  for (final toolName in ['get_issue', 'search_project', 'get_merge_request']) {
    test(
      '$toolName disclosure flags survive settling and re-redaction',
      () async {
        const lateSecret = 'synthetic-confidential-description-0099';
        final workspace = WorkspaceFixture();
        workspace.issues[3] = {
          'iid': 3,
          'title': 'Synthetic issue',
          'description': lateSecret,
          'confidential': true,
        };
        final environment = await _environment(
          gitLabRespond: (request) {
            if (request.uri.path.endsWith('/issues/3/notes') ||
                request.uri.path.endsWith('/merge_requests/3/notes')) {
              return jsonResponse([
                {'body': 'Member-only note', 'system': false, 'internal': true},
              ]);
            }
            if (request.uri.path.endsWith('/merge_requests/3')) {
              return jsonResponse(workspace.issues[3]);
            }
            if (request.uri.path.endsWith('/search')) {
              return jsonResponse([workspace.issues[3]]);
            }
            return workspace.respond(request);
          },
        );
        addTearDown(environment.dispose);
        final responses = [
          _data({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'type': 'function_call',
                  'call_id': 'call_read',
                  'name': toolName,
                  'arguments': jsonEncode(
                    toolName == 'search_project'
                        ? {'scope': 'issues', 'query': 'synthetic'}
                        : {'iid': 3},
                  ),
                  'status': 'completed',
                },
              ],
            },
          }),
          _toolThenAnswer(AiFormat.responses).last,
        ].iterator;
        final adapter = FakeAdapter((_) {
          expect(responses.moveNext(), isTrue);
          return _sse(responses.current);
        });
        final controller = await _readyController(environment, adapter);
        await controller.send('Read issue #3');
        expect(controller.failure, isNull);
        expect(controller.phase, AiChatPhase.idle);
        final settled = controller.items.whereType<AiToolRunItem>().single;
        expect(settled.status, AiToolRunStatus.completed);
        expect(settled.confidential, toolName != 'get_merge_request');
        expect(settled.internal, toolName != 'search_project');
        expect(settled.resultExcerpt, contains(lateSecret));

        await environment.settings.saveProvider(
          _provider(AiFormat.responses, id: 'other', requiresKey: true),
        );
        await environment.settings.saveProviderKey(
          'other',
          lateSecret,
          acknowledgeWarning: true,
        );
        await controller.recheck();
        final redacted = controller.items.whereType<AiToolRunItem>().single;
        expect(redacted.confidential, toolName != 'get_merge_request');
        expect(redacted.internal, toolName != 'search_project');
        expect(redacted.resultExcerpt, isNot(contains(lateSecret)));
        expect(redacted.resultExcerpt, contains('REDACTED'));

        // Refusing the redaction marker exercises the hidden-row fallback too.
        await environment.settings.saveProviderKey(
          'other',
          'REDACTED',
          acknowledgeWarning: true,
        );
        await controller.recheck();
        final hidden = controller.items.whereType<AiToolRunItem>().single;
        expect(hidden.resultExcerpt, isEmpty);
        expect(hidden.confidential, toolName != 'get_merge_request');
        expect(hidden.internal, toolName != 'search_project');
        expect(hidden.status, AiToolRunStatus.completed);
      },
    );
  }

  test(
    'disclosure flags do not mark public, failed or blocked tool rows',
    () async {
      final workspace = WorkspaceFixture();
      workspace.issues[3] = {
        'iid': 3,
        'title': 'Synthetic private',
        'confidential': true,
      };
      workspace.issues[4] = {
        'iid': 4,
        'title': 'Synthetic public',
        'confidential': false,
      };
      final environment = await _environment(
        gitLabRespond: (request) {
          if (request.uri.path.endsWith('/issues/3/notes')) {
            return jsonResponse([
              {'body': 'Member-only note', 'internal': true},
            ]);
          }
          if (request.uri.path.endsWith('/notes')) return jsonResponse([]);
          return workspace.respond(request);
        },
      );
      addTearDown(environment.dispose);
      final calls = [
        for (final iid in [3, 4, 5])
          {
            'type': 'function_call',
            'call_id': 'call_$iid',
            'name': 'get_issue',
            'arguments': jsonEncode({'iid': iid}),
            'status': 'completed',
          },
        {
          'type': 'function_call',
          'call_id': 'call_blocked',
          'name': 'read_file',
          'arguments': jsonEncode({'path': '.env', 'revision': 'head'}),
          'status': 'completed',
        },
        // The runner pairs this fifth call without executing it.
        {
          'type': 'function_call',
          'call_id': 'call_skipped',
          'name': 'get_issue',
          'arguments': jsonEncode({'iid': 3}),
          'status': 'completed',
        },
      ];
      var request = 0;
      final adapter = FakeAdapter(
        (_) => _sse(
          request++ == 0
              ? _data({
                  'type': 'response.completed',
                  'response': {'output': calls},
                })
              : _toolThenAnswer(AiFormat.responses).last,
        ),
      );
      final controller = await _readyController(environment, adapter);
      await controller.send('Read synthetic issues');
      expect(controller.failure, isNull);
      final tools = controller.items.whereType<AiToolRunItem>().toList();
      expect(tools.map((tool) => tool.confidential), [
        true,
        false,
        false,
        false,
        false,
      ]);
      expect(tools.map((tool) => tool.internal), [
        true,
        false,
        false,
        false,
        false,
      ]);
      expect(tools.map((tool) => tool.status), [
        AiToolRunStatus.completed,
        AiToolRunStatus.completed,
        AiToolRunStatus.failed,
        AiToolRunStatus.completed,
        AiToolRunStatus.skipped,
      ]);
      expect(tools[3].blocked, isTrue);
    },
  );

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

  test('a tool row label is redacted and loses control characters', () async {
    const token = 'synthetic-test-token';
    final environment = await _environment();
    addTearDown(environment.dispose);
    await _configure(
      environment,
      _provider(AiFormat.responses, tools: true),
      grantConsent: true,
    );
    final responses = _toolThenAnswer(
      AiFormat.responses,
      path: 'notes/$token\u202e\u0007.md',
    ).iterator;
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
    await controller.send('read the note');

    final label = controller.items
        .whereType<AiToolRunItem>()
        .single
        .argsPreview;
    expect(label, startsWith('notes/'));
    expect(label, isNot(contains(token)));
    expect(label, contains('REDACTED'));
    expect(label, isNot(contains('\u202e')));
    expect(label, isNot(contains('\u0007')));
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
      AiNoticeKind.notSent,
    );
    expect(
      controller.items.first,
      isA<AiUserItem>().having((item) => item.text, 'text', 'do not send'),
    );
    expect(controller.items, hasLength(2));
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
      aiConversationConsentContract(
          environment.settings,
          environment.workspace.account.key,
          second, releasePolicy: fixtureReleasePolicy
        ),
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

  test(
    'r1 tool target strips controls before redacting while running',
    () async {
      const token = 'synthetic-test-token';
      final gate = Completer<void>();
      var reading = false;
      final environment = await _environment(
        gitLabRespond: (request) async {
          if (request.uri.path.contains('/repository/files/') &&
              !request.uri.path.contains('/README.md')) {
            reading = true;
            await gate.future;
            return ResponseBody.fromString('safe tool text', 200);
          }
          return WorkspaceFixture().respond(request);
        },
      );
      addTearDown(environment.dispose);
      final responses = _toolThenAnswer(
        AiFormat.responses,
        path: 'notes/synthetic-\u200btest-token.md',
      ).iterator;
      final adapter = FakeAdapter((_) {
        responses.moveNext();
        return _sse(responses.current);
      });
      final controller = await _readyController(environment, adapter);
      final send = controller.send('read');
      try {
        await _waitFor(() => reading);
        final running = controller.items.whereType<AiToolRunItem>().single;
        expect(running.status, AiToolRunStatus.running);
        expect(running.argsPreview, isNot(contains(token)));
        expect(running.argsPreview, contains('REDACTED'));
        expect(running.argsPreview, isNot(contains('\u200b')));
      } finally {
        gate.complete();
        await send;
      }
      final finished = controller.items.whereType<AiToolRunItem>().single;
      expect(finished.argsPreview, isNot(contains(token)));
      expect(finished.argsPreview, contains('REDACTED'));
    },
  );

  test('r1 tool targets retain long values for later redaction', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final path = 'notes/${'x' * 300}/tail.md';
    final responses = _toolThenAnswer(AiFormat.responses, path: path).iterator;
    final adapter = FakeAdapter((_) {
      responses.moveNext();
      return _sse(responses.current);
    });
    final controller = await _readyController(environment, adapter);
    await controller.send('read');
    expect(
      controller.items.whereType<AiToolRunItem>().single.argsPreview,
      path,
    );
  });

  test('r1 unknown tool names are blank and synthetic reads skipped', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final responses = _toolThenAnswer(
      AiFormat.responses,
      toolName: 'untrusted_unknown_tool',
    ).iterator;
    final adapter = FakeAdapter((_) {
      responses.moveNext();
      return _sse(responses.current);
    });
    final controller = await _readyController(
      environment,
      adapter,
      tools: false,
    );
    await controller.send('read');
    final tool = controller.items.whereType<AiToolRunItem>().single;
    expect(tool.name, isEmpty);
    expect(tool.status, AiToolRunStatus.skipped);
    expect(tool.sizeChars, 0);
  });

  for (final (status, kind) in [
    (401, FailureKind.unauthenticated),
    (403, FailureKind.forbidden),
    (404, FailureKind.invisible),
    (200, FailureKind.tooLarge),
  ]) {
    test('r1 GitLab context failure keeps $kind', () async {
      final environment = await _environment(
        gitLabRespond: (request) {
          if (request.uri.path.contains('/repository/files/')) {
            return status == 200
                ? ResponseBody.fromString('x' * (2 * 1024 * 1024 + 1), 200)
                : jsonResponse({'message': 'synthetic'}, status: status);
          }
          return WorkspaceFixture().respond(request);
        },
      );
      addTearDown(environment.dispose);
      final controller = await _readyController(
        environment,
        FakeAdapter((_) => throw StateError('must not send')),
      );
      expect(controller.blocker, AiChatBlocker.contextUnavailable);
      expect(
        controller.failure,
        isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind),
      );
    });
  }

  test('r1 malformed context is a GitLab invalid response', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final controller = await _readyController(
      environment,
      FakeAdapter((_) => throw StateError('must not send')),
      origin: AiFileOrigin(
        project: environment.workspace.project,
        path: 'README.md',
        sha: 'not-a-full-sha',
      ),
    );
    expect(
      controller.failure,
      isA<ApiFailure>().having(
        (failure) => failure.kind,
        'kind',
        FailureKind.invalidResponse,
      ),
    );
  });

  test('r1 provider failure retains provider semantics', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final controller = await _readyController(
      environment,
      FakeAdapter((_) => jsonResponse({'error': 'synthetic'}, status: 403)),
    );
    await controller.send('hello');
    expect(
      controller.failure,
      isA<AiFailure>().having(
        (failure) => failure.kind,
        'kind',
        AiFailureKind.forbidden,
      ),
    );
  });

  test('r1 sentText is the complete redacted context block', () async {
    final environment = await _environment(
      repositoryText: 'start ${'safe line\n' * 40} synthetic-test-token end',
    );
    addTearDown(environment.dispose);
    final adapter = FakeAdapter(
      (_) => _sse(_toolThenAnswer(AiFormat.responses).last),
    );
    final controller = await _readyController(environment, adapter);
    await controller.send('summarize');
    final chip = controller.items.whereType<AiUserItem>().single.chips.single;
    expect(chip.sentText, isNotNull);
    expect(chip.sentText!.length, greaterThan(chip.preview.length));
    expect(chip.sentText, isNot(contains('synthetic-test-token')));
    final request =
        jsonDecode(adapter.requests.single.data as String)
            as Map<String, Object?>;
    final input =
        (request['input']! as List<Object?>).single as Map<String, Object?>;
    final content =
        (input['content']! as List<Object?>).single as Map<String, Object?>;
    final sent = content['text']! as String;
    expect(sent, contains(chip.sentText!));
    final start = sent.indexOf('<gitlab_data');
    final end = sent.indexOf('</gitlab_data>') + '</gitlab_data>'.length;
    expect(chip.sentText, sent.substring(start, end));
    expect(chip.sentText, contains('REDACTED'));
    await controller.recheck();
    expect(
      controller.items.whereType<AiUserItem>().single.chips.single.sentText,
      chip.sentText,
    );
  });

  test(
    'r1 settings replacement retains display and starts a fresh segment',
    () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      final adapters = <FakeAdapter>[];
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
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) {
              final adapter = FakeAdapter(
                (_) => _sse(_toolThenAnswer(AiFormat.responses).last),
              );
              adapters.add(adapter);
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
      await controller.send('earlier synthetic question');
      final previous = controller.items.toList();
      final oldId = controller.id;
      final changed = await environment.settings.saveProvider(
        _provider(AiFormat.responses, model: 'changed-model'),
      );
      await environment.settings.grantConsent(
        environment.workspace.account.key,
        aiConversationConsentContract(
          environment.settings,
          environment.workspace.account.key,
          changed, releasePolicy: fixtureReleasePolicy
        ),
        const {'synthetic': true},
      );
      await controller.recheck();
      expect(
        controller.items
            .take(previous.length)
            .map(
              (item) => switch (item) {
                AiUserItem(:final text) || AiAssistantItem(:final text) => text,
                _ => '',
              },
            ),
        ['earlier synthetic question', 'Final answer'],
      );
      expect(
        controller.items.last,
        isA<AiNoticeItem>().having(
          (item) => item.kind,
          'kind',
          AiNoticeKind.newConversation,
        ),
      );
      expect(controller.id, isNot(oldId));
      // The kept answer belongs to the earlier conversation: it is not
      // resolved, or marked, from this one.
      final kept = controller.items.whereType<AiAssistantItem>().first;
      expect(controller.currentOf(kept), isNull);
      controller.markReported(kept);
      expect(
        controller.items.whereType<AiAssistantItem>().first.reported,
        isFalse,
      );
      await controller.send('new synthetic question');
      // This conversation's own answer resolves.
      final own = controller.items.whereType<AiAssistantItem>().last;
      expect(controller.currentOf(own), same(own));
      final requests = adapters.expand((adapter) => adapter.requests).toList();
      expect(requests, hasLength(2));
      final second = jsonEncode(requests.last.data);
      expect(second, contains('new synthetic question'));
      expect(second, isNot(contains('earlier synthetic question')));
      expect(second, isNot(contains('Final answer')));
      final chip = controller.items.whereType<AiUserItem>().last.chips.single;
      final body =
          jsonDecode(requests.last.data as String) as Map<String, Object?>;
      final input =
          (body['input']! as List<Object?>).single as Map<String, Object?>;
      final content =
          (input['content']! as List<Object?>).single as Map<String, Object?>;
      final sent = content['text']! as String;
      final start = sent.indexOf('<gitlab_data');
      final end = sent.indexOf('</gitlab_data>') + '</gitlab_data>'.length;
      expect(chip.sentText, sent.substring(start, end));
    },
  );

  test('r1 notice from a tool stays before the running answer', () async {
    final environment = await _environment(
      gitLabRespond: (request) {
        if (request.uri.path.endsWith('/repository/files/withheld.txt')) {
          return ResponseBody.fromString('', 200);
        }
        if (request.uri.path.endsWith('/repository/files/withheld.txt/raw')) {
          return ResponseBody.fromString(
            '-----BEGIN PRIVATE KEY-----\nsynthetic',
            200,
          );
        }
        return WorkspaceFixture().respond(request);
      },
    );
    addTearDown(environment.dispose);
    final gate = Completer<void>();
    var answering = false;
    var request = 0;
    final responses = _toolThenAnswer(AiFormat.responses, path: 'withheld.txt');
    final adapter = FakeAdapter((_) async {
      if (request++ == 0) return _sse(responses.first);
      answering = true;
      await gate.future;
      return _sse(responses.last);
    });
    final controller = await _readyController(environment, adapter);
    final send = controller.send('read');
    try {
      await _waitFor(() => answering);
      final notice = controller.items.whereType<AiNoticeItem>().singleWhere(
        (item) => item.kind == AiNoticeKind.privateKeyWithheld,
      );
      expect(
        controller.items.indexOf(notice),
        lessThan(
          controller.items.indexWhere((item) => item is AiAssistantItem),
        ),
      );
      expect(controller.items.last, isA<AiAssistantItem>());
    } finally {
      gate.complete();
      await send;
    }
    expect(controller.items.last, isA<AiAssistantItem>());
  });

  test(
    'r1 clipped tool excerpt drops a partial token before late redaction',
    () async {
      final environment = await _environment(
        gitLabRespond: (request) {
          if (request.uri.path.endsWith('/repository/files/long.txt')) {
            return ResponseBody.fromString('', 200);
          }
          if (request.uri.path.endsWith('/repository/files/long.txt/raw')) {
            return ResponseBody.fromString(
              '${'word ' * 380}${'q' * 400} end',
              200,
            );
          }
          return WorkspaceFixture().respond(request);
        },
      );
      addTearDown(environment.dispose);
      final responses = _toolThenAnswer(
        AiFormat.responses,
        path: 'long.txt',
      ).iterator;
      final adapter = FakeAdapter((_) {
        responses.moveNext();
        return _sse(responses.current);
      });
      final controller = await _readyController(
        environment,
        adapter,
        requiresKey: true,
      );
      await controller.send('read');
      final excerpt = controller.items
          .whereType<AiToolRunItem>()
          .single
          .resultExcerpt;
      expect(excerpt.length, lessThan(2000));
      expect(excerpt, isNot(contains('q')));
      expect(excerpt, endsWith(' '));
      await environment.settings.saveProviderKey(
        'provider',
        'q' * 400,
        acknowledgeWarning: true,
      );
      await controller.recheck();
      expect(
        controller.items.whereType<AiToolRunItem>().single.resultExcerpt,
        isNot(contains('q')),
      );
    },
  );

  test('r1 a secret-refresh failure keeps user text with notSent', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    var fail = false;
    final adapter = FakeAdapter((_) => throw StateError('must not send'));
    final controller = await _readyController(
      environment,
      adapter,
      refreshSecrets: () async {
        if (fail) throw const FormatException('synthetic refresh failure');
      },
    );
    fail = true;
    await controller.send('keep synthetic-test-token draft');
    expect(adapter.requests, isEmpty);
    expect(
      controller.items.first,
      isA<AiUserItem>().having(
        (item) => item.text,
        'text',
        isNot(contains('synthetic-test-token')),
      ),
    );
    expect(
      controller.items.last,
      isA<AiNoticeItem>().having(
        (item) => item.kind,
        'kind',
        AiNoticeKind.notSent,
      ),
    );
    expect(controller.items, hasLength(2));
    expect(
      controller.failure,
      isA<ApiFailure>().having(
        (failure) => failure.kind,
        'kind',
        FailureKind.invalidResponse,
      ),
    );
  });

  test('r1 stop during secret refresh keeps the unsent user text', () async {
    final environment = await _environment();
    addTearDown(environment.dispose);
    final gate = Completer<void>();
    var holdRefresh = false;
    var refreshing = false;
    final adapter = FakeAdapter((_) => throw StateError('must not send'));
    final controller = await _readyController(
      environment,
      adapter,
      refreshSecrets: () async {
        if (holdRefresh) {
          refreshing = true;
          await gate.future;
        }
      },
    );
    holdRefresh = true;
    final send = controller.send('keep this draft');
    await _waitFor(() => refreshing);
    controller.stop();
    gate.complete();
    await send;
    expect(adapter.requests, isEmpty);
    expect(controller.items, hasLength(2));
    expect(
      controller.items.first,
      isA<AiUserItem>()
          .having((item) => item.text, 'text', 'keep this draft')
          // Nothing was sent, so it shows no "What was sent" chips.
          .having((item) => item.chips, 'chips', isEmpty),
    );
    expect(
      controller.items.last,
      isA<AiNoticeItem>().having(
        (item) => item.kind,
        'kind',
        AiNoticeKind.notSent,
      ),
    );
    expect(controller.failure, isNull);
    expect(controller.phase, AiChatPhase.idle);
  });

  test(
    'r1 a read failure remains failed with an attempted result size',
    () async {
      final environment = await _environment();
      addTearDown(environment.dispose);
      final responses = _toolThenAnswer(
        AiFormat.responses,
        path: 'missing-file.txt',
      ).iterator;
      final adapter = FakeAdapter((_) {
        responses.moveNext();
        return _sse(responses.current);
      });
      final controller = await _readyController(environment, adapter);
      await controller.send('read');
      final tool = controller.items.whereType<AiToolRunItem>().single;
      expect(tool.name, 'read_file');
      expect(tool.status, AiToolRunStatus.failed);
      expect(tool.sizeChars, greaterThan(0));
    },
  );

  test('r1 sentText follows secrets learned during runner preflight', () async {
    const lateSecret = 'synthetic-late-provider-key-0099';
    final environment = await _environment(repositoryText: 'value=$lateSecret');
    addTearDown(environment.dispose);
    final gate = Completer<void>();
    var sending = false;
    final adapter = FakeAdapter((_) async {
      sending = true;
      await gate.future;
      return _sse(_toolThenAnswer(AiFormat.responses).last);
    });
    var armed = false;
    var refreshes = 0;
    final controller = await _readyController(
      environment,
      adapter,
      refreshSecrets: () async {
        if (armed && ++refreshes == 2) {
          await environment.settings.saveProviderKey(
            'other',
            lateSecret,
            acknowledgeWarning: true,
          );
        }
      },
    );
    await environment.settings.saveProvider(
      _provider(AiFormat.responses, id: 'other', requiresKey: true),
    );
    await controller.recheck();
    armed = true;
    final send = controller.send('summarize');
    try {
      await _waitFor(() => sending);
      final chip = controller.items.whereType<AiUserItem>().single.chips.single;
      expect(chip.sentText, isNot(contains(lateSecret)));
      expect(chip.sentText, contains('REDACTED'));
      final body =
          jsonDecode(adapter.requests.single.data as String)
              as Map<String, Object?>;
      final input =
          (body['input']! as List<Object?>).single as Map<String, Object?>;
      final content =
          (input['content']! as List<Object?>).single as Map<String, Object?>;
      final sent = content['text']! as String;
      final start = sent.indexOf('<gitlab_data');
      final end = sent.indexOf('</gitlab_data>') + '</gitlab_data>'.length;
      expect(chip.sentText, sent.substring(start, end));
    } finally {
      gate.complete();
      await send;
    }
  });
}

/// The `<gitlab_data …>…</gitlab_data>` block in a Responses request.
String _sentGitLabData(RequestOptions request) {
  final body = jsonDecode(request.data as String) as Map<String, Object?>;
  final text = [
    for (final input in body['input']! as List<Object?>)
      if (input is Map<String, Object?> && input['content'] is List<Object?>)
        for (final part in input['content']! as List<Object?>)
          if (part is Map<String, Object?> && part['text'] is String)
            part['text']! as String,
  ].firstWhere((text) => text.contains('<gitlab_data'));
  final start = text.indexOf('<gitlab_data');
  final end = text.indexOf('</gitlab_data>') + '</gitlab_data>'.length;
  return text.substring(start, end);
}
