import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';

AiProviderConfig _config() => const AiProviderConfig(
  id: 'fixture-provider',
  name: 'Fixture',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.chatCompletions,
  model: 'fixture-model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxTokens,
    requiresKey: false,
    toolChoice: true,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

ResponseBody _toolIssue4() => ResponseBody.fromString(
  'data: ${jsonEncode({
    'choices': [
      {
        'index': 0,
        'finish_reason': 'tool_calls',
        'delta': {
          'tool_calls': [
            {
              'index': 0,
              'id': 'fixture-call',
              'type': 'function',
              'function': {
                'name': 'get_issue',
                'arguments': jsonEncode({'iid': 4}),
              },
            },
          ],
        },
      },
    ],
  })}\n\ndata: [DONE]\n\n',
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

ResponseBody _answer() => ResponseBody.fromString(
  'data: ${jsonEncode({
    'choices': [
      {
        'index': 0,
        'finish_reason': 'stop',
        'delta': {'content': 'ack'},
      },
    ],
  })}\n\ndata: [DONE]\n\n',
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

Future<void> _until(bool Function() predicate) async {
  final elapsed = Stopwatch()..start();
  while (!predicate() && elapsed.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue, reason: 'fixture did not settle');
}

final class _HeldProvider implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Completer<ResponseBody>> pending = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    final result = Completer<ResponseBody>();
    pending.add(result);
    return Future.any([
      result.future,
      if (cancelFuture != null)
        cancelFuture.then<ResponseBody>((_) {
          throw DioException.requestCancelled(
            requestOptions: options,
            reason: 'synthetic cancel',
          );
        }),
    ]);
  }

  @override
  void close({bool force = false}) {}
}

final class _Harness {
  final workspace = WorkspaceFixture();
  final settings = AiSettingsController(MemoryAiStore());
  final now = ValueNotifier<DateTime>(DateTime.utc(2026, 10, 23));
  late final FakeAdapter gitlab;
  late final FakeAdapter oauth;
  late final GitLabApi api;
  late final SessionController session;
  final controllers = <AiChatController>[];

  Future<void> initialize({
    FutureOr<ResponseBody?> Function(RequestOptions)? override,
  }) async {
    workspace.issues[3] = workspace.issue(3, 'page issue');
    workspace.issues[4] = workspace.issue(4, 'tool issue');
    gitlab = FakeAdapter((request) async {
      final response = await override?.call(request);
      if (response != null) return response;
      if (request.uri.path.endsWith('/issues/3/notes')) {
        return jsonResponse(<Object?>[]);
      }
      return workspace.respond(request);
    });
    var refresh = 0;
    oauth = FakeAdapter((_) {
      refresh += 1;
      return jsonResponse({
        'access_token': 'new-access-$refresh',
        'refresh_token': 'new-refresh-$refresh',
        'token_type': 'bearer',
      });
    });
    api = GitLabApi(
      instance: workspace.account.instance,
      credential: const OAuthCredential(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        clientId: 'synthetic-client',
      ),
      dio: Dio()..httpClientAdapter = gitlab,
      oauth: OAuthTokenClient(
        instance: workspace.account.instance,
        clientId: 'synthetic-client',
        dio: Dio()..httpClientAdapter = oauth,
      ),
      readCacheClock: () => now.value,
    );
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    session = SessionController(
      accounts,
      readCache: accounts.readCache,
      createApi: (instance, credential, oauth, onOAuthRotated) => api,
    );
    await session.initialize();
    await settings.initialize();
    final provider = await settings.saveProvider(_config());
    await settings.loadAccount(workspace.account.key);
    await settings.grantConsent(
      workspace.account.key,
      aiConversationConsentContract(settings, workspace.account.key, provider),
      const {'synthetic': true},
    );
    addTearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
      settings.dispose();
      session.dispose();
      workspace.api.close();
      api.close();
    });
  }

  Future<AiChatController> controller(HttpClientAdapter provider) async {
    final controller = AiChatController(
      appInForeground: () => true,
      origin: AiWorkItemOrigin(
        project: workspace.project,
        kind: AiWorkItemKind.issue,
        iid: 3,
        title: 'page issue',
      ),
      session: session,
      settings: settings,
      runningCount: () => 0,
      now: () => now.value,
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              AiWireClient(
                transport: AiTransport(
                  endpoint: AiEndpoint.parse(
                    config.baseUrl,
                    allowLanCleartext: false,
                  ),
                  apiKey: apiKey ?? '',
                  authStyle: config.authStyle,
                  adapter: provider,
                ),
                wire: const ChatCompletionsFormat(),
                config: config,
                conversationId: conversationId,
                appVersion: 'test',
              ),
    );
    controllers.add(controller);
    await _until(() => controller.phase == AiChatPhase.idle);
    expect(
      controller.blocker,
      AiChatBlocker.none,
      reason: 'failure=${controller.failure}; unhandled=${workspace.unhandled}',
    );
    return controller;
  }

  void rate(int limit, int remaining) {
    api.rateBudget.noteResponse(
      headers: {
        'ratelimit-limit': ['$limit'],
        'ratelimit-remaining': ['$remaining'],
        'retry-after': ['60'],
      },
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: api.rateBudget.nextSequence(),
      trusted: true,
    );
  }
}

void main() {
  test(
    'real five-request tool read consumes five shared lease units',
    () async {
      final firstIssueStarted = Completer<void>();
      final firstIssueResponse = Completer<ResponseBody>();
      var armed = false;
      var issueGets = 0;
      var noteGets = 0;
      final harness = _Harness();
      await harness.initialize(
        override: (request) {
          if (!armed) return null;
          final path = request.uri.path;
          if (request.method == 'PUT' && path.endsWith('/issues/4')) {
            return jsonResponse(
              harness.workspace.issue(4, 'updated outside tool'),
            );
          }
          if (path.endsWith('/issues/4/notes')) {
            noteGets += 1;
            return noteGets == 1
                ? jsonResponse({'message': 'expired'}, status: 401)
                : jsonResponse(<Object?>[]);
          }
          if (path.endsWith('/issues/4')) {
            issueGets += 1;
            if (issueGets == 1) {
              firstIssueStarted.complete();
              return firstIssueResponse.future;
            }
            return jsonResponse(harness.workspace.issue(4, 'tool issue'));
          }
          return null;
        },
      );
      final provider = _HeldProvider();
      final controller = await harness.controller(provider);
      armed = true;

      final sending = controller.send('read issue four');
      await _until(() => provider.requests.length == 1);
      provider.pending[0].complete(_toolIssue4());
      await firstIssueStarted.future.timeout(const Duration(seconds: 5));
      await harness.api.updateIssue(42, 4, {'title': 'updated outside tool'});
      firstIssueResponse.complete(
        jsonResponse({'message': 'expired'}, status: 401),
      );
      await _until(() => provider.requests.length == 2);

      expect(
        issueGets,
        3,
        reason: harness.gitlab.requests
            .map((request) => '${request.method} ${request.uri}')
            .join('\n'),
      );
      expect(noteGets, 2);
      expect(harness.oauth.requests, hasLength(2));
      expect(controller.budgetAllocator.unconsumedReservations, 35);
      provider.pending[1].complete(_answer());
      await sending;
      expect(controller.budgetAllocator.activeLeases, 0);
    },
  );

  test('expired context preflight stops before a four-request read', () async {
    final harness = _Harness();
    await harness.initialize();
    final provider = _HeldProvider();
    final controller = await harness.controller(provider);
    harness.now.value = harness.now.value.add(const Duration(seconds: 61));
    harness.rate(100, 6); // Server reserve three leaves a three-request lease.
    final requestsBefore = harness.gitlab.requests.length;

    await controller.send('refresh without exceeding the grant');

    expect(harness.gitlab.requests, hasLength(requestsBefore));
    expect(provider.requests, isEmpty);
    expect(controller.budgetAllocator.activeLeases, 0);
  });
}
