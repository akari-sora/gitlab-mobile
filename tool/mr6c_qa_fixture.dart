// Standalone MR6c QA runtime, imported only by the explicit QA entrypoint.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/main.dart'
    show
        configureAiWriteJournal,
        configureReadCacheDisk,
        recoverAiWriteJournalAfterAccountsLoaded;

import '../test/support/workspace_fixture.dart';
import 'mr6c_qa_protocol.dart';

void _require(bool value) {
  if (!value) throw const QaSandboxUnavailable();
}

String _hash(List<int> value) => sha256.convert(value).toString();
String _objectHash(Object? value) => _hash(utf8.encode(jsonEncode(value)));

const _accountKeyName = 'gitlab_mobile_accounts_v2';
const _lastKeyName = 'gitlab_mobile_last_account_v1';
const _qaVariant = 'task_manager_stop';

/// Check all names before a write, session startup, recovery or synthetic API.
/// A dedicated AVD receipt is still a separate required host-side preflight.
final class QaSandbox {
  QaSandbox({required this.support, required this.storage});
  final Directory support;
  final FlutterSecureStorage storage;
  late final account = WorkspaceFixture().account;
  late final store = SecureAccountStore(storage);
  late final keys = SecureAiJournalKeyStore(storage);
  late final files = AiJournalFiles(support);

  bool _isType(String path, FileSystemEntityType type) =>
      FileSystemEntity.typeSync(path, followLinks: false) == type;

  void _checkDirectory(Directory directory, Set<String> allowed) {
    if (!directory.existsSync()) return;
    _require(_isType(directory.path, FileSystemEntityType.directory));
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.where((v) => v.isNotEmpty).last;
      _require(allowed.contains(name));
      _require(!_isType(entity.path, FileSystemEntityType.link));
    }
  }

  void _checkFiles({required bool recover}) {
    _require(_isType(support.path, FileSystemEntityType.directory));
    _checkDirectory(support, {
      'mr6c_qa',
      if (recover) 'ai_write_journal',
      'ai_history',
      'profileInstalled',
    });
    // AndroidX ProfileVerifier 1.4.0 writes this startup cache in files/.
    // Accept only its exact regular-file name, never a directory or link.
    final profileType = FileSystemEntity.typeSync(
      '${support.path}/profileInstalled',
      followLinks: false,
    );
    _require(
      profileType == FileSystemEntityType.notFound ||
          profileType == FileSystemEntityType.file,
    );
    // No history is seeded by this fixture. Empty directories are harmless.
    _checkDirectory(Directory('${support.path}/ai_history'), {});
    final journalRoot = Directory('${support.path}/ai_write_journal');
    final segment = AiJournalFiles.accountHash(account.key);
    _checkDirectory(journalRoot, {if (recover) segment});
    final accountDir = Directory('${journalRoot.path}/$segment');
    _checkDirectory(accountDir, {if (recover) AiJournalFiles.fileName});
    if (recover) {
      _require(_isType(journalRoot.path, FileSystemEntityType.directory));
      _require(_isType(accountDir.path, FileSystemEntityType.directory));
      _require(_isType(files.pathFor(account.key), FileSystemEntityType.file));
    } else {
      _require(!journalRoot.existsSync());
    }
  }

  Future<void> verifyEmpty() async {
    _checkFiles(recover: false);
    _require((await storage.readAll()).isEmpty);
    _require((await store.load()).isEmpty);
    _require(await store.loadLastActive() == null);
    _require(!await store.loadSignOutPending());
  }

  Future<void> seed() async {
    await verifyEmpty();
    await store.save([account]);
    await store.saveLastActive(account.key);
    await verifyAccounts(allowJournal: false);
  }

  Future<void> verifyAccounts({required bool allowJournal}) async {
    final all = await storage.readAll();
    final allowed = <String>{
      _accountKeyName,
      _lastKeyName,
      if (allowJournal) AiJournalKeyStore.keyName(account.key),
    };
    _require(
      all.keys.toSet().length == allowed.length &&
          all.keys.toSet().containsAll(allowed),
    );
    final loaded = await store.load();
    _require(
      loaded.length == 1 &&
          jsonEncode(loaded.single.toSecureJson()) ==
              jsonEncode(account.toSecureJson()),
    );
    _require(await store.loadLastActive() == account.key);
    _require(!await store.loadSignOutPending());
  }

  Future<Map<String, Object?>> verifyRecovery(QaCommand command) async {
    _checkFiles(recover: true);
    await verifyAccounts(allowJournal: true);
    final checkpoint = File('${support.path}/mr6c_qa/v9_checkpoint.json');
    _require(_isType(checkpoint.path, FileSystemEntityType.file));
    _require(await checkpoint.length() <= 4096);
    final raw = jsonDecode(await checkpoint.readAsString());
    _require(raw is Map<String, dynamic>);
    final data = Map<String, Object?>.from(raw as Map<String, dynamic>);
    _require(
      data.keys.toSet().length == 7 &&
          data.keys.toSet().containsAll({
            'schema',
            'session',
            'variant',
            'execution_digest',
            'file_digest',
            'plaintext_digest',
            'case',
          }),
    );
    _require(
      data['schema'] == 1 &&
          data['session'] == command.session &&
          data['variant'] == command.variant &&
          data['case'] == command.caseId,
    );
    final key = await keys.readKey(account.key);
    _require(key.failure == null && key.value != null);
    final bytes = await files.read(account.key);
    _require(bytes != null && _hash(bytes) == data['file_digest']);
    final decoded = await AiHistoryCipher.decryptJson(
      bytes!,
      key.value!,
      account.key,
      AiJournalFiles.fileName,
    );
    _require(_objectHash(decoded) == data['plaintext_digest']);
    final entries = decoded['entries'];
    _require(entries is List && entries.length == 1 && entries.single is Map);
    final entry = Map<String, Object?>.from((entries as List).single as Map);
    _require(
      entry['state'] == 'dispatching' &&
          entry['account'] == account.key &&
          entry['execution'] is String &&
          _objectHash(entry['execution']) == data['execution_digest'],
    );
    return data;
  }

  /// Read the recovered ciphertext independently of the journal's memory.
  Future<List<int>> verifyRecoveredJournal(
    AiJournalEntry memoryEntry,
    String executionDigest,
  ) async {
    final key = await keys.readKey(account.key);
    final bytes = await files.read(account.key);
    _require(key.failure == null && key.value != null && bytes != null);
    final decoded = await AiHistoryCipher.decryptJson(
      bytes!,
      key.value!,
      account.key,
      AiJournalFiles.fileName,
    );
    final entries = decoded['entries'];
    _require(entries is List && entries.length == 1 && entries.single is Map);
    final diskEntry = Map<String, Object?>.from(
      (entries as List).single as Map,
    );
    _require(
      diskEntry['account'] == account.key &&
          diskEntry['execution'] == memoryEntry.executionId &&
          _objectHash(diskEntry['execution']) == executionDigest &&
          diskEntry['state'] == 'writeUncertain' &&
          memoryEntry.writeKeys.isNotEmpty,
    );
    void requireKeys(Object? raw, Set<AiConflictKey> keys) {
      _require(raw is List);
      final actual = (raw as List).map(jsonEncode).toSet();
      final expected = keys.map((key) => jsonEncode(key.parts)).toSet();
      _require(
        raw.length == expected.length &&
            actual.length == expected.length &&
            actual.containsAll(expected),
      );
    }

    requireKeys(diskEntry['writes'], memoryEntry.writeKeys);
    requireKeys(diskEntry['dependencies'], memoryEntry.dependencyKeys);
    return bytes;
  }
}

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

/// Owns real app controllers and a never-completing synthetic accepted write.
final class QaV9Fixture {
  QaV9Fixture(this.sandbox, this.command, {@visibleForTesting this.testChannel})
    : workspace = WorkspaceFixture();
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
        writePolicy: aiMr6b1WritePolicy(level),
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

  Future<QaJournalRecovered> recover() async {
    final checkpoint = await sandbox.verifyRecovery(command);
    await _startSession();
    registry = AccountAiRunRegistry(
      session: session,
      settings: settings,
      backgroundExecution: _testOwner,
    );
    final entries = journal.entries(sandbox.account.key);
    _require(
      entries.length == 1 &&
          _objectHash(entries.single.executionId) ==
              checkpoint['execution_digest'],
    );
    final entry = entries.single;
    final gate = registry.backgroundExecution.createGate(
      conversationId: () => 'mr6c-recover',
      isCurrent: () => true,
    );
    final permitAbsent = gate.binding.permitId == null;
    final isolated = journal.isolated(sandbox.account.key, entry.writeKeys);
    final uncertain = entry.state == AiJournalState.writeUncertain;
    final bytes = await sandbox.verifyRecoveredJournal(
      entry,
      checkpoint['execution_digest']! as String,
    );
    _require(
      uncertain &&
          isolated &&
          permitAbsent &&
          _providerAdapter.calls == 0 &&
          _gitlab.mutations == 0,
    );
    gate.dispose();
    return QaJournalRecovered(
      executionDigest: checkpoint['execution_digest']! as String,
      fileDigest: _hash(bytes),
      uncertain: uncertain,
      isolated: isolated,
      permitAbsent: permitAbsent,
      persistentAccountsVerified: true,
      modelCalls: _providerAdapter.calls,
      mutationCalls: _gitlab.mutations,
    );
  }
}

bool qaSupportsV9(QaCommand command) =>
    command.caseId == 'V9' && command.variant == _qaVariant;
