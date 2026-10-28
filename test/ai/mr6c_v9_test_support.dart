// Test-only V9 held-write harness; the runtime QA fixture keeps production policy.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/main.dart'
    show
        configureAiWriteJournal,
        configureReadCacheDisk,
        recoverAiWriteJournalAfterAccountsLoaded;

import '../support/workspace_fixture.dart';
import '../../tool/mr6c_qa_protocol.dart';
import '../../tool/mr6c_qa_fixture.dart' show QaSandbox, QaSandboxUnavailable;
import 'release_policy_support.dart';

void _require(bool value) {
  if (!value) throw const QaSandboxUnavailable();
}

String _hash(List<int> value) => sha256.convert(value).toString();
String _objectHash(Object? value) => _hash(utf8.encode(jsonEncode(value)));

final class _SyntheticAdapter implements HttpClientAdapter {
  _SyntheticAdapter(this.workspace);
  final WorkspaceFixture workspace;
  int mutations = 0;
  final mutationEntered = Completer<void>();
  final _hold = Completer<ResponseBody>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _require(
      options.uri.scheme == 'https' &&
          options.uri.host == 'example.com' &&
          options.uri.path.startsWith('/gitlab/api/v4/'),
    );
    if (options.method != 'GET' && options.method != 'HEAD') {
      _require(
        options.method == 'POST' &&
            options.uri.path == '/gitlab/api/v4/projects/42/issues' &&
            mutations == 0,
      );
      mutations++;
      mutationEntered.complete();
      return _hold.future;
    }
    return workspace.respond(options);
  }

  @override
  void close({bool force = false}) {}
}

final class _SyntheticProvider implements HttpClientAdapter {
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _require(
      options.uri.scheme == 'https' &&
          options.uri.host == 'provider.example' &&
          options.method == 'POST',
    );
    calls++;
    final response = {
      'type': 'response.completed',
      'response': {
        'output': [
          {
            'type': 'function_call',
            'call_id': 'mr6c-call-1',
            'name': 'createIssue',
            'arguments': jsonEncode({
              'projectId': 42,
              'fields': {
                'title': 'Synthetic MR6c issue',
                'confidential': false,
              },
              'reason': 'Create a synthetic issue.',
            }),
            'status': 'completed',
          },
        ],
      },
    };
    return ResponseBody.fromString(
      'data: ${jsonEncode(response)}\n\n',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _provider = AiProviderConfig(
  id: 'mr6c-synthetic-provider',
  name: 'MR6c synthetic provider',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.responses,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: false,
    toolChoice: true,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

final class TestV9Fixture {
  TestV9Fixture(
    this.sandbox,
    this.command, {
    @visibleForTesting this.testChannel,
  }) : workspace = WorkspaceFixture();
  final QaSandbox sandbox;
  final QaCommand command;
  @visibleForTesting
  final MethodChannel? testChannel;
  final WorkspaceFixture workspace;
  late final _SyntheticAdapter _gitlab = _SyntheticAdapter(workspace);
  final _SyntheticProvider _providerAdapter = _SyntheticProvider();
  late final SessionController session;
  late final AiSettingsController settings;
  late AccountAiRunRegistry registry;
  late final AiWriteJournal journal = AiWriteJournal.instance;

  AiBackgroundExecution? get _testOwner => testChannel == null
      ? null
      : AiBackgroundExecution(
          accountKey: sandbox.account.key,
          generation: session.generation,
          ownerApi: session.api!,
          isCurrent: () =>
              session.active?.key == sandbox.account.key && session.api != null,
          appInForeground: aiAppInForeground,
          channel: testChannel,
        );

  Future<void> _startSession() async {
    final cache = ReadCacheDiskCoordinator(coordinationScope: Object());
    configureReadCacheDisk(
      cache,
      files: ReadCacheFileStore(root: () async => sandbox.support),
    );
    session = SessionController(
      sandbox.store,
      readCache: cache,
      createApi: (instance, credential, oauth, rotated) {
        _require(
          instance.key == sandbox.account.instance.key &&
              credential is PatCredential &&
              credential.accessToken ==
                  sandbox.account.credential.accessToken &&
              oauth == null,
        );
        return GitLabApi(
          instance: instance,
          credential: credential,
          dio: Dio()..httpClientAdapter = _gitlab,
        );
      },
    );
    await session.initialize();
    _require(
      session.accountsLoaded &&
          session.accounts.length == 1 &&
          session.accounts.single.key == sandbox.account.key &&
          session.active?.key == sandbox.account.key &&
          session.api != null,
    );
    _require(
      await configureAiWriteJournal(
        keys: sandbox.keys,
        applicationSupport: () async => sandbox.support,
      ),
    );
    // Recovery can delete orphans; it must never precede sandbox preflight.
    await AiHistoryCoordinator.instance.startRecovery(session);
    await recoverAiWriteJournalAfterAccountsLoaded(session, journal);
    _require(journal.recovered(sandbox.account.key));
    settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
  }

  Future<QaJournalBarrier> prepare() async {
    await sandbox.seed();
    await _startSession();
    const level = AiAutonomyLevel.conversationGrant;
    final config = await settings.saveProvider(_provider);
    await settings.loadAccount(sandbox.account.key);
    await settings.setAutonomySettings(
      sandbox.account.key,
      ceiling: level,
      startingLevel: AiAutonomyLevel.lowRiskAuto,
    );
    await settings.grantConsent(
      sandbox.account.key,
      settings.consentContractFor(
        sandbox.account.key,
        config,
        releasePolicy: fixtureReleasePolicy,
        writePolicy: aiMr6b1WritePolicy(
          level,
          releasePolicy: fixtureReleasePolicy,
        ),
        agreedCeiling: level,
      ),
      const {'synthetic': true},
    );
    final origin = AiFileOrigin(
      project: workspace.project,
      path: 'README.md',
      sha: WorkspaceFixture.sha,
    );
    registry = AccountAiRunRegistry(
      session: session,
      settings: settings,
      backgroundExecution: _testOwner,
      sessionFactory:
          ({
            required origin,
            required session,
            required settings,
            required runningCount,
            wireClientFactory,
          }) {
            final controller = AiChatController(
              releasePolicy: fixtureReleasePolicy,
              origin: origin,
              session: session,
              settings: settings,
              runningCount: runningCount,
              appInForeground: aiAppInForeground,
              clientMayStart: aiClientMayStart(session),
              writeJournal: journal,
              wireClientFactory:
                  ({
                    required config,
                    required apiKey,
                    required conversationId,
                  }) => AiWireClient(
                    transport: AiTransport(
                      endpoint: AiEndpoint.parse(
                        config.baseUrl,
                        allowLanCleartext: false,
                      ),
                      apiKey: apiKey ?? '',
                      authStyle: config.authStyle,
                      adapter: _providerAdapter,
                    ),
                    wire: const ResponsesFormat(),
                    config: config,
                    conversationId: conversationId,
                    appVersion: 'test',
                  ),
            );
            return (
              session: controller,
              capacityChanged: controller.notifyCapacityChanged,
              dispose: controller.dispose,
            );
          },
    );
    final controller = registry.open(origin) as AiChatController;
    await controller.recheck();
    _require(controller.canSend);
    await controller.setAutonomyLevel(level);
    _require(controller.autonomyLevel == level);
    unawaited(
      controller
          .send('Create an issue for the synthetic bug')
          .catchError((Object _) {}),
    );
    await _gitlab.mutationEntered.future.timeout(const Duration(seconds: 60));
    final entries = journal.entries(sandbox.account.key);
    _require(
      entries.length == 1 &&
          entries.single.state == AiJournalState.dispatching &&
          registry.backgroundExecution.status ==
              AiBackgroundExecutionStatus.active &&
          controller.executionStatus == AiChatExecutionStatus.active &&
          registry.backgroundExecution.serviceWorkCount == 1 &&
          _providerAdapter.calls > 0 &&
          _gitlab.mutations == 1,
    );
    final key = await sandbox.keys.readKey(sandbox.account.key);
    final bytes = await sandbox.files.read(sandbox.account.key);
    _require(key.failure == null && key.value != null && bytes != null);
    final decoded = await AiHistoryCipher.decryptJson(
      bytes!,
      key.value!,
      sandbox.account.key,
      AiJournalFiles.fileName,
    );
    final executionDigest = _objectHash(entries.single.executionId);
    final fileDigest = _hash(bytes);
    final checkpoint = <String, Object>{
      'schema': 1,
      'session': command.session,
      'case': command.caseId,
      'variant': command.variant,
      'execution_digest': executionDigest,
      'file_digest': fileDigest,
      'plaintext_digest': _objectHash(decoded),
    };
    final directory = Directory('${sandbox.support.path}/mr6c_qa');
    final temp = File('${directory.path}/v9_checkpoint.tmp');
    await temp.writeAsString(jsonEncode(checkpoint), flush: true);
    await temp.rename('${directory.path}/v9_checkpoint.json');
    return QaJournalBarrier(
      executionDigest: executionDigest,
      fileDigest: fileDigest,
      dispatchAccepted: true,
      journalFlushed: true,
      nativeServiceActive: true,
      modelCalls: _providerAdapter.calls,
      mutationCalls: _gitlab.mutations,
    );
  }
}
