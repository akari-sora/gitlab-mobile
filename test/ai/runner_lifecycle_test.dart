import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_runner_binding.dart';
import 'package:gitlab_mobile/features/ai/ai_secrets.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';

void main() {
  test(
    'real OAuth refresh redacts old and rotated credentials from tool output',
    () async {
      final environment = await _Environment.create();
      addTearDown(environment.dispose);
      final payloads = <String>[];
      var calls = 0;
      final runner = environment.runner(
        complete: (plan, {onEvent}) async {
          payloads.add(environment.wire.encodeJson(plan, environment.caps));
          calls += 1;
          return calls == 1
              ? _turn(calls: [_readFileCall])
              : _turn(text: 'done');
        },
        withTools: true,
      );
      final binding = AiRunnerBinding(
        runner: runner,
        settings: environment.settings,
        session: environment.session,
      );
      addTearDown(binding.dispose);

      environment.expireNextRepositoryRead = true;
      final result = await runner.run('inspect the readme');

      expect(result.reason, AiRunEnd.done);
      expect(environment.oauthRefreshes, 1);
      expect(payloads, hasLength(2));
      for (final token in _allGitLabTokens) {
        expect(payloads.last, isNot(contains(token)), reason: token);
        expect(environment.secrets.current, contains(token), reason: token);
      }
      expect(payloads.last, contains('[REDACTED]'));
    },
  );

  test(
    'provider key replacement refreshes secrets and opens a segment',
    () async {
      final environment = await _Environment.create();
      addTearDown(environment.dispose);
      final payloads = <String>[];
      Future<AiDecodedTurn> complete(
        AiRequestPlan plan, {
        void Function(AiEvent)? onEvent,
      }) async {
        payloads.add(environment.wire.encodeJson(plan, environment.caps));
        return _turn(text: 'answer', opaque: 'opaque-original');
      }

      final runner = environment.runner(complete: complete);
      final binding = AiRunnerBinding(
        runner: runner,
        settings: environment.settings,
        session: environment.session,
      );
      addTearDown(binding.dispose);
      await runner.run('first turn');
      final firstSegment = runner.segment;

      await environment.settings.saveProviderKey(
        _providerId,
        _replacementProviderKey,
      );
      final replacement = environment.settings.providers.single;
      runner.replaceKeyRecipient(
        config: replacement,
        complete: complete,
        close: environment.closeTransport,
        cancelActive: environment.cancelActiveTransport,
      );
      final result = await runner.run(
        'compare $_initialProviderKey and $_replacementProviderKey',
      );

      expect(result.reason, AiRunEnd.done);
      expect(replacement.recipientRevision, 2);
      expect(runner.segment, isNot(same(firstSegment)));
      expect(payloads.last, isNot(contains(_initialProviderKey)));
      expect(payloads.last, isNot(contains(_replacementProviderKey)));
      expect(payloads.last, isNot(contains('opaque-original')));
      expect(
        environment.secrets.current,
        containsAll(<String>[_initialProviderKey, _replacementProviderKey]),
      );
    },
  );

  test(
    'binding stops a stalled stream as soon as consent is revoked',
    () async {
      final environment = await _Environment.create();
      addTearDown(environment.dispose);
      final started = Completer<void>();
      final stalled = Completer<AiDecodedTurn>();
      final runner = environment.runner(
        complete: (plan, {onEvent}) {
          started.complete();
          return stalled.future;
        },
      );
      final binding = AiRunnerBinding(
        runner: runner,
        settings: environment.settings,
        session: environment.session,
      );
      addTearDown(binding.dispose);

      final running = runner.run('wait for an answer');
      await started.future;
      await environment.settings.revokeConsent(
        environment.account.key,
        _providerId,
      );

      expect((await running).reason, AiRunEnd.stoppedBySettings);
      expect(environment.transportCloses, greaterThan(0));
      expect(runner.segment!.entries, isEmpty);
      stalled.complete(_turn(text: 'late'));
    },
  );
}

const _providerId = 'provider';
const _initialProviderKey = 'initial-provider-key';
const _replacementProviderKey = 'replacement-provider-key';
const _oldAccess = 'old-access-token';
const _oldRefresh = 'old-refresh-token';
const _newAccess = 'new-access-token';
const _newRefresh = 'new-refresh-token';
const _allGitLabTokens = <String>[
  _oldAccess,
  _oldRefresh,
  _newAccess,
  _newRefresh,
];

final _readFileCall = AiToolCall(
  id: 'read-one',
  name: 'read_file',
  arguments: <String, Object?>{'path': 'README.md', 'revision': 'head'},
);

final class _Environment {
  _Environment._({
    required this.fixture,
    required this.adapter,
    required this.accountStore,
    required this.account,
    required this.session,
    required this.settings,
    required this.contract,
    required this.secrets,
  });

  static Future<_Environment> create() async {
    final fixture = WorkspaceFixture();
    late _Environment environment;
    late final FakeAdapter adapter;
    adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/oauth/token')) {
        environment.oauthRefreshes += 1;
        return jsonResponse(<String, Object?>{
          'access_token': _newAccess,
          'refresh_token': _newRefresh,
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      }
      final repositoryRead = request.uri.path.contains('/repository/files/');
      if (environment.expireNextRepositoryRead &&
          repositoryRead &&
          !environment.repositoryReadExpired) {
        environment.repositoryReadExpired = true;
        return jsonResponse(<String, Object?>{
          'message': 'expired',
        }, status: 401);
      }
      if (environment.repositoryReadExpired &&
          request.uri.path.endsWith('/raw')) {
        return ResponseBody.fromString(_allGitLabTokens.join(' '), 200);
      }
      return fixture.respond(request);
    });

    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
      credential: const OAuthCredential(
        accessToken: _oldAccess,
        refreshToken: _oldRefresh,
        clientId: 'synthetic-client',
      ),
    );
    final accountStore = _MemoryAccountStore(<Account>[account]);
    final session = SessionController(
      accountStore,
      createApi: (instance, credential, oauth, onOAuthRotated) => GitLabApi(
        instance: instance,
        credential: credential,
        dio: Dio()..httpClientAdapter = adapter,
        oauth: oauth,
        onOAuthRotated: onOAuthRotated,
      ),
      createOAuth: (instance, clientId) => OAuthTokenClient(
        instance: instance,
        clientId: clientId,
        dio: Dio()..httpClientAdapter = adapter,
      ),
    );
    final aiStore = MemoryAiStore();
    await aiStore.saveProviders(<AiProviderConfig>[_provider()]);
    await aiStore.saveProviderKey(_providerId, _initialProviderKey);
    final settings = AiSettingsController(aiStore);
    final contract = _contract();
    final secrets = KnownSecretsLive(session, settings);
    environment = _Environment._(
      fixture: fixture,
      adapter: adapter,
      accountStore: accountStore,
      account: account,
      session: session,
      settings: settings,
      contract: contract,
      secrets: secrets,
    );
    await session.initialize();
    await session.select(account);
    if (session.api == null) {
      throw StateError('Synthetic session did not select');
    }
    await settings.initialize();
    await settings.grantConsent(account.key, contract, <String, Object?>{
      'provider': _providerId,
    });
    environment.catalogue = AiToolCatalogue(
      port: GitLabAiReadPort(session.api!, 42),
      scope: _scope(account),
      redactor: Redactor(secrets: secrets),
      refreshSecrets: secrets.refresh,
    );
    return environment;
  }

  final WorkspaceFixture fixture;
  final FakeAdapter adapter;
  final _MemoryAccountStore accountStore;
  final Account account;
  final SessionController session;
  final AiSettingsController settings;
  final AiConsentContract contract;
  final KnownSecretsLive secrets;
  late final AiToolCatalogue catalogue;
  final wire = const ChatCompletionsFormat();
  final caps = _caps;
  var expireNextRepositoryRead = false;
  var repositoryReadExpired = false;
  var oauthRefreshes = 0;
  var transportCloses = 0;

  AiRunner runner({required AiComplete complete, bool withTools = false}) {
    var budget = AiToolBudget();
    return AiRunner(
      appInForeground: () => true,
      config: settings.providers.single,
      wire: wire,
      complete: complete,
      secrets: secrets,
      refreshSecrets: secrets.refresh,
      guard: AiRunGuard(
        expectedGeneration: session.generation,
        ownerApi: session.api!,
        generation: () => session.generation,
        api: () => session.api,
        recipientRevision: () => settings.recipientRevision(_providerId),
        consentValid: () => settings.isValid(account.key, contract),
      ),
      system: 'Answer questions about the synthetic repository.',
      tools: withTools ? catalogue.specs : const <AiToolSpec>[],
      executeTool: withTools
          ? (call) => catalogue.executeResult(call, budget: budget)
          : null,
      resetToolBudget: withTools ? () => budget = AiToolBudget() : null,
      beginToolTurn: withTools ? () => budget.beginTurn() : null,
      close: closeTransport,
      cancelActive: cancelActiveTransport,
    );
  }

  void closeTransport() => transportCloses += 1;

  void cancelActiveTransport() {}

  void dispose() {
    settings.dispose();
    session.dispose();
  }
}

final class _MemoryAccountStore implements AccountStore {
  _MemoryAccountStore(this.accounts);

  List<Account> accounts;

  @override
  Future<List<Account>> load() async => List<Account>.of(accounts);

  @override
  Future<String?> loadLastActive() async => null;

  @override
  Future<bool> loadSignOutPending() async => false;

  @override
  Future<void> save(List<Account> value) async {
    accounts = List<Account>.of(value);
  }

  @override
  Future<void> saveLastActive(String? key) async {}

  @override
  Future<void> saveSignOutPending(bool pending) async {}
}

const _caps = AiCaps(
  tokenLimitField: AiTokenLimitField.maxTokens,
  replayChatExtras: true,
  maxRequestChars: 400000,
);

AiProviderConfig _provider() => const AiProviderConfig(
  id: _providerId,
  name: 'Synthetic',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.chatCompletions,
  model: 'synthetic',
  authStyle: AiAuthStyle.bearer,
  caps: _caps,
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

AiConsentContract _contract() => AiConsentContract(
  providerId: _providerId,
  origin: 'https://provider.example/v1',
  format: AiFormat.chatCompletions,
  cleartext: false,
  toolsEnabled: true,
  toolCatalogueVersion: aiToolCatalogueVersion,
  dataCategories: <String>{'source', 'tool_reads'},
  policyIdentity: 'custom',
  dataUse: AiDataUse.unknown,
  disclosureVersion: 1,
);

AiResourceScope _scope(Account account) => AiResourceScope(
  accountKey: account.key,
  instanceKey: account.instance.key,
  projectId: 42,
  projectPath: 'studio/mobile-workspace',
  current: const AiResourceRef(
    kind: AiResourceKind.file,
    id: 42,
    path: 'README.md',
  ),
  headSha: WorkspaceFixture.sha,
  defaultBranch: 'main',
);

AiDecodedTurn _turn({
  String text = '',
  List<AiToolCall> calls = const <AiToolCall>[],
  String opaque = '',
}) {
  final raw = <String, Object?>{
    'role': 'assistant',
    'content': text,
    if (opaque.isNotEmpty)
      'extra_content': <String, Object?>{'signature': opaque},
    if (calls.isNotEmpty)
      'tool_calls': <Object?>[
        for (final call in calls)
          <String, Object?>{
            'id': call.id,
            'type': 'function',
            'function': <String, Object?>{
              'name': call.name,
              'arguments': jsonEncode(call.arguments),
            },
          },
      ],
  };
  return AiDecodedTurn(
    ProviderOutputEntry(AiFormat.chatCompletions, raw, toolCalls: calls),
    AiStopReason.endTurn,
    null,
  );
}
