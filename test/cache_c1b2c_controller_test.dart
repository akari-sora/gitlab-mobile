import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';

AiProviderConfig _config({bool tools = false}) => AiProviderConfig(
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
  toolsEnabled: tools,
  recipientRevision: 1,
);

ResponseBody _tool(
  String name,
  Map<String, Object?> arguments,
) => ResponseBody.fromString(
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
              'function': {'name': name, 'arguments': jsonEncode(arguments)},
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

ResponseBody _answer({int? inputTokens}) => ResponseBody.fromString(
  'data: ${jsonEncode({
    if (inputTokens != null) 'usage': {'prompt_tokens': inputTokens},
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

final class _Harness {
  final workspace = WorkspaceFixture();
  final settings = AiSettingsController(MemoryAiStore());
  DateTime now = DateTime.utc(2026, 10, 23);
  String title = 'initial network title';
  bool networkDown = false;
  FutureOr<ResponseBody?> Function(RequestOptions)? gitlabOverride;
  late final GitLabApi api;
  late final SessionController session;
  late final FakeAdapter gitlab;
  final List<AiChatController> controllers = [];

  Future<void> initialize({bool tools = false}) async {
    workspace.issues[4] = workspace.issue(4, 'tool-only issue');
    gitlab = FakeAdapter((request) async {
      final response = await gitlabOverride?.call(request);
      if (response != null) return response;
      if (request.uri.path.endsWith('/issues/3')) {
        return networkDown
            ? jsonResponse({'message': 'unavailable'}, status: 503)
            : jsonResponse(workspace.issue(3, title));
      }
      if (request.uri.path.endsWith('/issues/3/notes') ||
          request.uri.path.endsWith('/issues/4/notes')) {
        return jsonResponse(<Object?>[]);
      }
      return workspace.respond(request);
    });
    api = GitLabApi(
      instance: workspace.account.instance,
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = gitlab,
      readCacheClock: () => now,
    );
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    session = SessionController(
      accounts,
      createApi: (instance, credential, oauth, onOAuthRotated) => api,
    );
    await session.initialize();
    await settings.initialize();
    final provider = await settings.saveProvider(_config(tools: tools));
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

  Future<AiChatController> controller(
    HttpClientAdapter adapter, {
    bool issue = false,
    AiChatOrigin? origin,
    Future<void> Function()? refreshSecrets,
  }) async {
    final controller = AiChatController(
      origin:
          origin ??
          (issue
              ? AiWorkItemOrigin(
                  project: workspace.project,
                  kind: AiWorkItemKind.issue,
                  iid: 3,
                  title: title,
                )
              : const AiGeneralOrigin()),
      session: session,
      settings: settings,
      runningCount: () => 0,
      now: () => now,
      refreshSecrets: refreshSecrets,
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
                  adapter: adapter,
                ),
                wire: const ChatCompletionsFormat(),
                config: config,
                conversationId: conversationId,
                appVersion: 'test',
              ),
    );
    controllers.add(controller);
    await _until(() => controller.phase == AiChatPhase.idle);
    expect(controller.blocker, AiChatBlocker.none);
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

void main() {
  test('fix4 cooldown during refresh retains user text and notSent', () async {
    final harness = _Harness();
    await harness.initialize();
    var armed = false;
    final provider = FakeAdapter((_) => _answer());
    final controller = await harness.controller(
      provider,
      refreshSecrets: () async {
        if (armed) {
          harness.api.rateBudget.noteResponse(
            headers: {
              'retry-after': ['60'],
            },
            statusCode: 429,
            requestClass: RateRequestClass.global,
            sequence: harness.api.rateBudget.nextSequence(),
            trusted: true,
          );
        }
      },
    );
    armed = true;
    await controller.send('keep this cooldown message');
    expect(provider.requests, isEmpty);
    expect(controller.sendBlockReason, AiChatSendBlockReason.serverCooldown);
    expect(
      controller.items.whereType<AiUserItem>().single.text,
      'keep this cooldown message',
    );
    expect(
      controller.items.whereType<AiNoticeItem>().map((item) => item.kind),
      contains(AiNoticeKind.notSent),
    );
    expect((controller.failure as AiFailure?)?.kind, AiFailureKind.rateLimited);
    expect((controller.failure as AiFailure?)?.notSent, isTrue);
    // GitLab's budget stopped it, not the AI provider (round-2 U-2).
    expect(controller.failure?.title, l10n.aiGitLabBudgetTitle);
    expect(
      (controller.failure as AiFailure?)?.retryAt,
      controller.sendBlockedUntil,
    );
    expect(controller.budgetAllocator.activeLeases, 0);
  });

  test(
    'fix5 unchanged refresh keeps earlier tool contents and meters refresh',
    () async {
      final harness = _Harness();
      await harness.initialize(tools: true);
      final provider = _HeldProvider();
      final controller = await harness.controller(provider, issue: true);
      final initial = controller.send('read issue four');
      await _until(() => provider.requests.length == 1);
      provider.pending[0].complete(_tool('get_issue', {'iid': 4}));
      await _until(() => provider.requests.length == 2);
      expect(provider.requests.last.data, contains('tool-only issue'));
      provider.pending[1].complete(_answer());
      await initial;
      final beforeRefresh = harness.gitlab.requests.length;
      harness.now = harness.now.add(const Duration(seconds: 61));
      final followUp = controller.send('what was its title');
      await _until(() => provider.requests.length == 3);
      expect(provider.requests.last.data, contains('tool-only issue'));
      expect(
        provider.requests.last.data,
        isNot(contains('conversation_summary')),
      );
      expect(
        controller.items.whereType<AiNoticeItem>().map((item) => item.kind),
        isNot(contains(AiNoticeKind.segmentSummary)),
      );
      expect(
        harness.gitlab.requests.where((r) => r.uri.path.endsWith('/issues/3')),
        hasLength(2),
      );
      expect(harness.gitlab.requests.length - beforeRefresh, 4);
      expect(controller.budgetAllocator.unconsumedReservations, 36);
      provider.pending[2].complete(_answer());
      await followUp;
      expect(controller.lastEnd, AiRunEnd.done);
      expect(controller.budgetAllocator.activeLeases, 0);
    },
  );

  for (final usage in [true, false]) {
    test('fix5 changed refresh preserves token cap usage=$usage', () async {
      final harness = _Harness();
      await harness.initialize();
      await harness.settings.setConversationTokenCap(
        harness.workspace.account.key,
        50000,
      );
      final provider = FakeAdapter(
        (_) => _answer(inputTokens: usage ? 50001 : null),
      );
      final controller = await harness.controller(provider, issue: true);
      final id = controller.id;
      await controller.send(
        usage
            ? 'use the token cap'
            : List.filled(10000, 'synthetic question ').join(),
      );
      expect(provider.requests, hasLength(1));
      await controller.send('already over cap');
      expect(controller.lastEnd, AiRunEnd.tokenBudget);
      harness.title = 'changed title after token cap';
      harness.now = harness.now.add(const Duration(seconds: 61));
      await controller.send('still over cap after context refresh');
      expect(controller.id, id);
      expect(controller.lastEnd, AiRunEnd.tokenBudget);
      expect(provider.requests, hasLength(1));
      expect(controller.budgetAllocator.activeLeases, 0);
      expect(
        controller.items.whereType<AiNoticeItem>().where(
          (item) => item.kind == AiNoticeKind.segmentSummary,
        ),
        hasLength(1),
      );
    });
  }

  for (final path in ['README.md', '.env']) {
    test('fix5 pinned file context never expires path=$path', () async {
      final harness = _Harness();
      await harness.initialize();
      harness.gitlabOverride = (request) {
        if (request.uri.path.contains('/repository/files/')) {
          return ResponseBody.fromString(
            request.method == 'HEAD' ? '' : 'immutable source',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/plain'],
            },
          );
        }
        return null;
      };
      final provider = FakeAdapter((_) => _answer());
      final controller = await harness.controller(
        provider,
        origin: AiFileOrigin(
          project: harness.workspace.project,
          path: path,
          sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      );
      await controller.send('first pinned question');
      final reads = harness.gitlab.requests.length;
      harness.now = harness.now.add(const Duration(seconds: 61));
      await controller.send('followup pinned question');
      expect(harness.gitlab.requests, hasLength(reads));
      expect(provider.requests, hasLength(2));
      expect(
        provider.requests.last.data,
        isNot(contains('conversation_summary')),
      );
    });
  }

  test(
    'fix5 failed refresh consumes physical requests before releasing lease',
    () async {
      final harness = _Harness();
      await harness.initialize();
      final provider = FakeAdapter((_) => _answer());
      final controller = await harness.controller(provider, issue: true);
      await controller.send('initial');
      harness.now = harness.now.add(const Duration(seconds: 61));
      final pending = Completer<ResponseBody>();
      harness.gitlabOverride = (request) =>
          request.uri.path.endsWith('/issues/3/notes') ? pending.future : null;
      final sending = controller.send('refresh with pending notes');
      await _until(
        () =>
            harness.gitlab.requests
                .where((r) => r.uri.path.endsWith('/issues/3/notes'))
                .length ==
            2,
      );
      // The successful metadata request has settled; notes is physically in flight.
      expect(controller.budgetAllocator.activeLeases, 1);
      final lease = controller.runBudgetLease!;
      expect(lease.granted, 40);
      pending.complete(jsonResponse({}, status: 503));
      await sending;
      expect(controller.blocker, AiChatBlocker.contextUnavailable);
      expect(provider.requests, hasLength(1));
      expect(controller.budgetAllocator.activeLeases, 0);
      expect(lease.isReleased, isTrue);
      expect(lease.remaining, 38, reason: 'both physical sends remain charged');
    },
  );

  test(
    'every send checks the 60s context age and refreshes before provider delivery',
    () async {
      final harness = _Harness();
      await harness.initialize();
      final provider = FakeAdapter((_) => _answer());
      final controller = await harness.controller(provider, issue: true);
      await controller.send('first');
      expect(provider.requests.single.data, contains('initial network title'));
      harness.title = 'fresh replacement title';
      harness.now = harness.now.add(const Duration(seconds: 59));
      await controller.send('still within age');
      expect(
        harness.gitlab.requests.where((r) => r.uri.path.endsWith('/issues/3')),
        hasLength(1),
      );
      harness.now = harness.now.add(const Duration(seconds: 1));
      await controller.send('refresh at hard boundary');
      expect(
        harness.gitlab.requests.where((r) => r.uri.path.endsWith('/issues/3')),
        hasLength(2),
      );
      expect(provider.requests.last.data, contains('fresh replacement title'));
      expect(
        provider.requests.last.data,
        isNot(contains('initial network title')),
      );
      expect(controller.lastEnd, AiRunEnd.done);
      expect(controller.budgetAllocator.activeLeases, 0);
    },
  );

  test(
    'expired context and network outage expose unavailable and deliver no stale value',
    () async {
      final harness = _Harness();
      await harness.initialize();
      final provider = FakeAdapter((_) => _answer());
      final controller = await harness.controller(provider, issue: true);
      await controller.send('initial');
      harness.now = harness.now.add(const Duration(seconds: 61));
      harness.networkDown = true;
      await controller.send('must not deliver stale context');
      expect(provider.requests, hasLength(1));
      expect(controller.blocker, AiChatBlocker.contextUnavailable);
      expect(controller.failure, isNotNull);
      expect(controller.lastEnd, AiRunEnd.failed);
      expect(controller.budgetAllocator.activeLeases, 0);
      expect(controller.budgetAllocator.unconsumedReservations, 0);
    },
  );

  for (final limit in [1, 2, 3]) {
    test(
      'critical send block uses V6 boundaries at L=$limit and releases no phantom lease',
      () async {
        final harness = _Harness();
        await harness.initialize();
        final provider = FakeAdapter((_) => _answer());
        final controller = await harness.controller(provider);
        harness.rate(limit, limit);
        expect(controller.sendBlockReason, isNull);
        await controller.send('full allowance');
        expect(provider.requests, hasLength(1));
        harness.rate(limit, limit - 1);
        expect(
          controller.sendBlockReason,
          limit == 1 ? AiChatSendBlockReason.criticalRateBudget : isNull,
        );
        if (limit > 1) {
          await controller.send('one request used');
          expect(provider.requests, hasLength(2));
        }
        harness.rate(limit, 0);
        expect(controller.canSend, isFalse);
        expect(
          controller.sendBlockReason,
          AiChatSendBlockReason.criticalRateBudget,
        );
        expect(
          controller.sendBlockedUntil,
          harness.now.add(const Duration(seconds: 60)),
        );
        final before = provider.requests.length;
        await controller.send('critical must block');
        expect(provider.requests, hasLength(before));
        expect(controller.budgetAllocator.activeLeases, 0);
        harness.now = harness.now.add(const Duration(seconds: 50));
        expect(
          controller.sendBlockReason,
          isNull,
          reason: 'T=10 is not critical',
        );
        await controller.send('T=10 boundary');
        expect(provider.requests, hasLength(before + 1));
      },
    );
  }

  test(
    'critical change during secret refresh blocks the send after its await',
    () async {
      final harness = _Harness();
      await harness.initialize();
      var makeCritical = false;
      final provider = FakeAdapter((_) => _answer());
      final controller = await harness.controller(
        provider,
        refreshSecrets: () async {
          if (makeCritical) harness.rate(100, 0);
        },
      );
      makeCritical = true;
      await controller.send('becomes critical while preparing');
      expect(provider.requests, isEmpty);
      expect(
        controller.sendBlockReason,
        AiChatSendBlockReason.criticalRateBudget,
      );
      expect(controller.budgetAllocator.activeLeases, 0);
      expect(
        controller.items.whereType<AiUserItem>().single.text,
        'becomes critical while preparing',
      );
      expect(
        controller.items.whereType<AiNoticeItem>().map((item) => item.kind),
        contains(AiNoticeKind.notSent),
      );
      expect(
        (controller.failure as AiFailure?)?.kind,
        AiFailureKind.rateLimited,
      );
      expect((controller.failure as AiFailure?)?.notSent, isTrue);
      // GitLab's budget stopped it, not the AI provider (round-2 U-2).
      expect(controller.failure?.title, l10n.aiGitLabBudgetTitle);
      expect(
        (controller.failure as AiFailure?)?.retryAt,
        controller.sendBlockedUntil,
      );
    },
  );

  test(
    'the first provider dispatch rechecks critical after runner preparation',
    () async {
      final harness = _Harness();
      await harness.initialize();
      var armed = false;
      var refreshes = 0;
      final provider = FakeAdapter((_) => _answer());
      final controller = await harness.controller(
        provider,
        refreshSecrets: () async {
          if (armed && ++refreshes == 2) harness.rate(100, 0);
        },
      );
      armed = true;
      await controller.send('critical after the controller preparation');
      expect(refreshes, greaterThanOrEqualTo(2));
      expect(provider.requests, isEmpty);
      expect(controller.lastEnd, AiRunEnd.failed);
      expect(controller.budgetAllocator.activeLeases, 0);
    },
  );

  test(
    'context expiring during runner preparation never reaches the provider',
    () async {
      final harness = _Harness();
      await harness.initialize();
      var armed = false;
      var refreshes = 0;
      final provider = FakeAdapter((_) => _answer());
      final controller = await harness.controller(
        provider,
        issue: true,
        refreshSecrets: () async {
          if (armed && ++refreshes == 2) {
            harness.now = harness.now.add(const Duration(seconds: 61));
          }
        },
      );
      armed = true;
      await controller.send('context expires after the controller preparation');
      expect(provider.requests, isEmpty);
      expect(controller.blocker, AiChatBlocker.contextUnavailable);
      expect(controller.budgetAllocator.activeLeases, 0);
    },
  );

  test(
    'a completed tool consumes physical HTTP units and critical permits its active run to finish',
    () async {
      final harness = _Harness();
      await harness.initialize(tools: true);
      harness.gitlabOverride = (request) {
        if (request.uri.path.endsWith('/issues/4/notes')) {
          harness.rate(100, 0);
          return jsonResponse(<Object?>[]);
        }
        return null;
      };
      final provider = _HeldProvider();
      final controller = await harness.controller(provider, issue: true);
      final sending = controller.send('read issue four');
      await _until(() => provider.requests.length == 1);
      expect(controller.budgetAllocator.unconsumedReservations, 40);
      provider.pending[0].complete(_tool('get_issue', {'iid': 4}));
      await _until(() => provider.requests.length == 2);
      expect(
        harness.gitlab.requests.where((r) => r.uri.path.contains('/issues/4')),
        hasLength(2),
      );
      expect(
        controller.sendBlockReason,
        AiChatSendBlockReason.criticalRateBudget,
      );
      expect(controller.budgetAllocator.unconsumedReservations, 38);
      provider.pending[1].complete(_answer());
      await sending;
      expect(controller.lastEnd, AiRunEnd.done);
      expect(controller.budgetAllocator.activeLeases, 0);
      expect(controller.canSend, isFalse);
    },
  );

  test('the granted account lease bounds the tool budget', () async {
    final harness = _Harness();
    await harness.initialize(tools: true);
    final provider = _HeldProvider();
    final controller = await harness.controller(provider, issue: true);
    harness.rate(100, 5); // reserve=3 leaves a two-HTTP grant.
    final sending = controller.send('insufficient allowance for issue four');
    await _until(() => provider.requests.length == 1);
    expect(controller.budgetAllocator.unconsumedReservations, 2);
    provider.pending[0].complete(_tool('get_issue', {'iid': 4}));
    await _until(() => provider.requests.length == 2);
    expect(
      harness.gitlab.requests.where((r) => r.uri.path.contains('/issues/4')),
      isEmpty,
    );
    expect(
      provider.requests.last.data,
      contains('GitLab request limit reached'),
    );
    expect(controller.budgetAllocator.unconsumedReservations, 2);
    provider.pending[1].complete(_answer());
    await sending;
    expect(controller.budgetAllocator.activeLeases, 0);
  });

  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'dispose' : 'cancel'} keeps a pending tool lease until actual HTTP settles',
      () async {
        final harness = _Harness();
        await harness.initialize(tools: true);
        final notes = Completer<ResponseBody>();
        harness.gitlabOverride = (request) =>
            request.uri.path.endsWith('/issues/4/notes') ? notes.future : null;
        final provider = _HeldProvider();
        final controller = await harness.controller(provider, issue: true);
        final sending = controller.send('pending issue four');
        await _until(() => provider.requests.length == 1);
        provider.pending[0].complete(_tool('get_issue', {'iid': 4}));
        await _until(
          () => harness.gitlab.requests.any(
            (r) => r.uri.path.endsWith('/issues/4/notes'),
          ),
        );
        if (dispose) {
          controller.dispose();
        } else {
          controller.stop();
        }
        await sending;
        expect(controller.budgetAllocator.activeLeases, 1);
        notes.complete(jsonResponse(<Object?>[]));
        await _until(() => controller.budgetAllocator.activeLeases == 0);
        expect(controller.budgetAllocator.unconsumedReservations, 0);
        expect(provider.requests, hasLength(1));
      },
    );
  }

  test(
    'an old conversation settles only its own lease while its replacement runs',
    () async {
      final harness = _Harness();
      await harness.initialize(tools: true);
      final notes = Completer<ResponseBody>();
      harness.gitlabOverride = (request) =>
          request.uri.path.endsWith('/issues/4/notes') ? notes.future : null;
      final provider = _HeldProvider();
      final controller = await harness.controller(provider, issue: true);
      final oldSend = controller.send('old conversation');
      await _until(() => provider.requests.length == 1);
      provider.pending[0].complete(_tool('get_issue', {'iid': 4}));
      await _until(
        () => harness.gitlab.requests.any(
          (r) => r.uri.path.endsWith('/issues/4/notes'),
        ),
      );
      controller.startNewConversation();
      await oldSend;
      await _until(() => controller.phase == AiChatPhase.idle);
      final newSend = controller.send('new conversation');
      await _until(() => provider.requests.length == 2);
      expect(controller.budgetAllocator.activeLeases, 2);
      notes.complete(jsonResponse(<Object?>[]));
      await _until(() => controller.budgetAllocator.activeLeases == 1);
      expect(controller.budgetAllocator.unconsumedReservations, 40);
      provider.pending[1].complete(_answer());
      await newSend;
      expect(controller.lastEnd, AiRunEnd.done);
      expect(controller.budgetAllocator.activeLeases, 0);
    },
  );

  test(
    'provider failure releases the lease and returns all unused allowance',
    () async {
      final harness = _Harness();
      await harness.initialize();
      final provider = FakeAdapter(
        (_) => jsonResponse({'message': 'unavailable'}, status: 503),
      );
      final controller = await harness.controller(provider);
      await controller.send('failure');
      expect(controller.lastEnd, AiRunEnd.failed);
      expect(controller.budgetAllocator.activeLeases, 0);
      expect(controller.budgetAllocator.unconsumedReservations, 0);
    },
  );

  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'dispose' : 'cancel'} releases an active lease',
      () async {
        final harness = _Harness();
        await harness.initialize();
        final provider = _HeldProvider();
        final controller = await harness.controller(provider);
        final sending = controller.send('held provider request');
        await _until(() => provider.requests.isNotEmpty);
        expect(controller.budgetAllocator.activeLeases, 1);
        expect(controller.budgetAllocator.unconsumedReservations, 40);
        if (dispose) {
          controller.dispose();
        } else {
          controller.stop();
        }
        await sending;
        expect(controller.budgetAllocator.activeLeases, 0);
        expect(controller.budgetAllocator.unconsumedReservations, 0);
      },
    );
  }

  test(
    'controllers share one account allocator and cap concurrent leases at three',
    () async {
      final harness = _Harness();
      await harness.initialize();
      final provider = _HeldProvider();
      final controllers = <AiChatController>[];
      final sends = <Future<void>>[];
      for (var i = 0; i < 4; i++) {
        controllers.add(await harness.controller(provider));
      }
      for (final controller in controllers.take(3)) {
        sends.add(controller.send('parallel'));
      }
      await _until(() => provider.requests.length == 3);
      expect(controllers.first.budgetAllocator.activeLeases, 3);
      expect(
        identical(
          controllers.first.budgetAllocator,
          controllers.last.budgetAllocator,
        ),
        isTrue,
      );
      expect(
        controllers.last.sendBlockReason,
        AiChatSendBlockReason.runBudgetUnavailable,
      );
      await controllers.last.send('fourth run');
      expect(provider.requests, hasLength(3));
      for (final controller in controllers.take(3)) {
        controller.stop();
      }
      await Future.wait(sends);
      expect(controllers.first.budgetAllocator.activeLeases, 0);
    },
  );
}
