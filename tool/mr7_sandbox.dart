// Host entrypoint uses flutter_tester because the production journal imports
// Flutter stores. There is no app lifecycle or live adapter in this packet.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/ai_work_item_write_registry.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr7/sandbox_contract.dart';

final class Mr7HostProposal {
  const Mr7HostProposal({
    required this.operation,
    required this.projectId,
    required this.tier,
    required this.payloadDigest,
    this.requiredTypedName,
  });
  final String operation;
  final int projectId;
  final String tier;
  final String payloadDigest;
  final String? requiredTypedName;
}

typedef Mr7Confirm = Future<bool> Function(Mr7HostProposal proposal);
typedef Mr7TypedConfirm = Future<String?> Function(Mr7HostProposal proposal);

/// 7B1–7B3 export lists of these definitions and pass them to runMr7Sandbox;
/// they do not implement another runner or alter its safety checks.
final class Mr7Scenario {
  const Mr7Scenario({
    required this.id,
    required this.suite,
    required this.operation,
    required this.variant,
    required this.tier,
    required this.call,
    required this.paths,
    required this.observe,
    this.targetKind = AiTargetKind.project,
    this.maxMutations = 1,
    this.expectedMutations = 1,
    this.utterance,
    this.resource,
    this.freshness,
    this.createRegistry,
    this.readNames = const {},
    this.graphDocuments = const {},
    this.graphVariablesDigests = const {},
    this.graphReadDocuments = const {},
    this.resultPath = const [],
    this.readbackPaths,
  });
  final String id;
  final String suite;
  final String operation;
  final String variant;
  final String tier;
  final AiToolCall Function(Mr7Identity identity) call;
  final Set<String> Function(Mr7Identity identity) paths;
  final Future<bool> Function(Mr7Readback observer, Mr7Identity identity)
  observe;
  final AiTargetKind targetKind;
  final int maxMutations;
  final int expectedMutations;
  final String Function(Mr7Identity identity)? utterance;
  final AiResourceRef Function(Mr7Identity identity)? resource;
  final Future<AiWriteFreshness> Function(
    Mr7SandboxSession session,
    port.AiWriteRequest request,
  )?
  freshness;
  final AiWorkItemWriteRegistry Function(GitLabApi api)? createRegistry;
  final Set<String> readNames;
  final Set<String> graphDocuments;
  final Set<String> graphVariablesDigests;
  final Map<String, Set<String>> graphReadDocuments;
  final List<String> resultPath;
  final Set<String> Function(Mr7Identity identity, Mr7MutationPermit result)?
  readbackPaths;
}

List<Mr7Scenario> mr7ContractScenarios() => [
  Mr7Scenario(
    id: 'b0-star',
    suite: 'rest',
    operation: 'setStar',
    variant: 'synthetic-star',
    tier: 'T1',
    utterance: (p) => 'Star the synthetic project ${p.path}.',
    call: (p) => AiToolCall(
      id: 'b0-star',
      name: 'setStar',
      arguments: {
        'projectId': p.projectId,
        'starred': true,
        'reason': 'Synthetic sandbox star requested.',
      },
    ),
    paths: (p) => {'POST projects/${p.projectId}/star'},
    observe: (s, p) async =>
        (await s.read('projects/${p.projectId}'))['starred'] == true,
  ),
];

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [
    'synthetic-gitlab-pat',
    'synthetic-provider-key',
  ];
}

/// Scripted wire transport, not a mocked coordinator or write port.
final class Mr7SyntheticProvider implements HttpClientAdapter {
  Mr7SyntheticProvider(this.call);
  final AiToolCall call;
  int requests = 0;
  bool leakDetected = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.host != 'provider.invalid' || options.method != 'POST') {
      throw const Mr7Refused('providerEndpoint');
    }
    final body = options.data is String
        ? options.data! as String
        : jsonEncode(options.data);
    if (body.contains('synthetic-gitlab-pat')) {
      leakDetected = true;
      throw const Mr7Refused('providerSecretLeak');
    }
    final output = requests++ == 0
        ? [
            {
              'type': 'function_call',
              'call_id': call.id,
              'name': call.name,
              'arguments': jsonEncode(call.arguments),
              'status': 'completed',
            },
          ]
        : [
            {
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': 'Synthetic scenario complete.'},
              ],
            },
          ];
    return ResponseBody.fromString(
      'data: ${jsonEncode({
        'type': 'response.completed',
        'response': {'output': output},
      })}\n\n',
      200,
      headers: {
        'content-type': ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _provider = AiProviderConfig(
  id: 'mr7-synthetic',
  name: 'MR7 synthetic',
  presetId: 'custom',
  baseUrl: 'https://provider.invalid/v1',
  format: AiFormat.responses,
  model: 'synthetic-model',
  allowLanCleartext: false,
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: false,
    toolChoice: true,
  ),
  toolsEnabled: true,
  recipientRevision: 1,
);

Future<Map<String, Object?>> runMr7Sandbox({
  Mr7Policy policy = Mr7Policy.production,
  required String releaseSha,
  required Mr7Confirm confirm,
  Mr7TypedConfirm? typedConfirm,
  List<Mr7Scenario>? scenarios,
  Mr7SandboxSession? session,
  Mr7SyntheticGitLab? server,
  String suite = 'all',
  int expectedUserId = 7,
  String namespace = 'synthetic-owner',
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
  bool Function()? boundaryValid,
}) async {
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(releaseSha) ||
      !const {'all', 'rest', 'graphql', 'advanced'}.contains(suite)) {
    throw const Mr7Refused('configuration');
  }
  final cases = (scenarios ?? mr7ContractScenarios())
      .where((s) => suite == 'all' || suite == s.suite)
      .toList();
  if (cases.map((s) => s.id).toSet().length != cases.length) {
    throw const Mr7Refused('duplicateScenario');
  }
  final view = mr7SandboxPolicy(
    policy,
    reads: {for (final c in cases) ...c.readNames},
    writes: {
      for (final s in cases)
        s.operation: {
          for (final other in cases.where((c) => c.operation == s.operation))
            other.targetKind,
        },
    },
  );
  final s =
      session ??
      Mr7SandboxSession(
        server:
            server ??
            Mr7SyntheticGitLab(userId: expectedUserId, namespace: namespace),
        expectedUserId: expectedUserId,
        namespace: namespace,
        boundaryValid: boundaryValid,
        nonce: List.generate(
          16,
          (_) => Random.secure().nextInt(16).toRadixString(16),
        ).join(),
      );
  final rows = <Map<String, Object?>>[];
  final root = await Directory.systemTemp.createTemp('mr7-journal-');
  PolicyAiWriteCoordinator? activeCoordinator;
  AiRunner? activeRunner;
  final account = '${s.instance}#${s.expectedUserId}';
  final journal = AiWriteJournal(
    keys: MemoryAiJournalKeyStore(),
    applicationSupport: root,
    processId: 'mr7-synthetic-host',
  );
  try {
    await s.initialize();
    await journal.recoverAfterAccountsLoaded([account]);
    await journal.ensureInitialized(account);
    for (final scenario in cases) {
      final row = <String, Object?>{
        'id': scenario.id,
        'suite': scenario.suite,
        'operation': scenario.operation,
        'variant': scenario.variant,
        'tier': scenario.tier,
        'scope': 'project',
        'status': 'NOT_RUN',
        'mutationCount': 0,
        'readback': 'NOT_RUN',
        'live': 'NOT_RUN',
        'releaseSha': releaseSha,
      };
      rows.add(row);
      if (s.quarantined) {
        row['reason'] = 'sessionStopped';
        continue;
      }
      if (mr7ExcludedOperations.contains(scenario.operation) ||
          scenario.operation.toLowerCase().contains('group') ||
          !view.allowsWrite(scenario.operation, scenario.targetKind)) {
        row['reason'] = 'releaseClosed';
        continue;
      }
      final target = s.identity!;
      s.observerAdapter.graphReadDocuments = Map.unmodifiable({
        for (final entry in scenario.graphReadDocuments.entries)
          entry.key: Set<String>.unmodifiable(entry.value),
      });
      final call = scenario.call(target);
      row['fixtureDigest'] = mr7Digest(call.arguments);
      if (call.name != scenario.operation) {
        throw const Mr7Refused('scenarioOperation');
      }
      final budget = AiToolBudget();
      final api = GitLabApi(
        instance: GitLabInstance.parse(s.instance.toString()),
        token: 'synthetic-gitlab-pat',
        dio: s.writer,
        cdnAdapter: s.writerAdapter,
      );
      final provider = Mr7SyntheticProvider(call);
      final transport = AiTransport(
        endpoint: AiEndpoint.parse(_provider.baseUrl, allowLanCleartext: false),
        apiKey: 'synthetic-provider-key',
        authStyle: _provider.authStyle,
        adapter: provider,
      );
      final client = AiWireClient(
        transport: transport,
        wire: const ResponsesFormat(),
        config: _provider,
        conversationId: 'mr7-${mr7Digest(scenario.id).substring(0, 24)}',
        appVersion: 'mr7-synthetic',
      );
      final writeScope = AiWriteScope(
        accountKey: account,
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: target.projectId,
            projectPath: target.path,
          ),
        ],
      );
      final coordinator = PolicyAiWriteCoordinator(
        releasePolicy: view,
        snapshot: () => AiWritePolicySnapshot(
          scope: writeScope,
          level: level,
          ceiling: AiAutonomyLevel.bypass,
          consentHash: mr7Digest(view.canonicalIdentity),
          writePolicyRevision: 1,
          scopeRevision: 1,
          sessionGeneration: 1,
          appInForeground: true,
          clientMayStartPredicate: () => !s.quarantined && s.boundaryValid(),
        ),
        createPort: () => port.GitLabAiWritePort(
          api,
          accountKey: account,
          workItemWriteRegistry: scenario.createRegistry?.call(api),
          sessionGeneration: 1,
          isCurrent: () => !s.quarantined && s.boundaryValid(),
        ),
        journal: journal,
        conversationId: scenario.id,
        budget: () => budget,
        readFreshness: (request) async {
          await s.verifyIdentity();
          if (scenario.freshness != null) {
            return scenario.freshness!(s, request);
          }
          final value = await s.read('projects/${target.projectId}');
          row['preread'] = {
            'projectId': value['id'],
            'versionDigest': mr7Digest(value),
          };
          return const AiWriteFreshness(
            visibilityUnreadable: false,
            sourceVisibilityUnreadable: false,
            targetVisibility: 'private',
          );
        },
        placeholders: UploadPlaceholderTable(instance: api.instance),
        knownSecrets: () => _Secrets().current.toSet(),
        safeDisplay: (value) => value,
      );
      activeCoordinator = coordinator;
      final catalogue = AiToolCatalogue(
        port: GitLabAiReadPort(api, target.projectId),
        scope: AiResourceScope(
          accountKey: account,
          instanceKey: api.instance.key,
          projectId: target.projectId,
          projectPath: target.path,
          current:
              scenario.resource?.call(target) ??
              const AiResourceRef(kind: AiResourceKind.file, id: 1),
        ),
        redactor: Redactor(secrets: _Secrets()),
        releasePolicy: view,
      );
      final permit = Mr7MutationPermit(
        operation: scenario.operation,
        paths: scenario.paths(target),
        resourceProjectId: target.projectId,
        maxMutations: scenario.maxMutations,
        graphDocuments: scenario.graphDocuments,
        graphVariablesDigests: scenario.graphVariablesDigests,
        resultPath: scenario.resultPath,
      );
      s.permit = permit;
      Future<void>? approving;
      Mr7HostProposal hostProposal({AiWriteProposal? product}) =>
          Mr7HostProposal(
            operation: scenario.operation,
            projectId: target.projectId,
            tier: scenario.tier,
            payloadDigest: product?.payloadDigest ?? mr7Digest(call.arguments),
            requiredTypedName: product?.tier.typedName,
          );
      Future<bool> confirmHost({AiWriteProposal? product}) async {
        row['proposalAt'] = DateTime.now().toUtc().toIso8601String();
        final host = hostProposal(product: product);
        row['payloadDigest'] = host.payloadDigest;
        final accepted = await confirm(host);
        row['confirmAt'] = DateTime.now().toUtc().toIso8601String();
        row['confirmation'] = accepted
            ? 'explicitSyntheticTestHook'
            : 'rejected';
        return accepted;
      }

      permit.confirmBeforeSend = () => confirmHost();
      final runner = AiRunner(
        config: _provider,
        wire: const ResponsesFormat(),
        complete: client.complete,
        secrets: _Secrets(),
        refreshSecrets: () async {},
        guard: AiRunGuard(
          expectedGeneration: 1,
          ownerApi: api,
          generation: () => 1,
          api: () => s.quarantined ? null : api,
          recipientRevision: () => 1,
          consentValid: () => s.boundaryValid(),
        ),
        tools: [...catalogue.specs, ...coordinator.specs],
        writeCoordinator: coordinator,
        executeTool: (call) async =>
            (await catalogue.execute(call, budget: budget)).result,
        onAwaitingApproval: (awaiting) {
          if (!awaiting || approving != null) return;
          approving =
              Future<void>(() async {
                final proposal = coordinator.proposals.single;
                final accepted = await confirmHost(product: proposal);
                if (accepted) {
                  final host = hostProposal(product: proposal);
                  final typed = host.requiredTypedName == null
                      ? null
                      : await typedConfirm?.call(host);
                  row['typedInputProvided'] = typed != null;
                  row['typedInputMatches'] =
                      typed != null && typed == host.requiredTypedName;
                  permit.confirmed = true;
                  final approved = await coordinator.approve(
                    proposal,
                    typedName: typed,
                  );
                  if (approved.state == AiJournalState.notExecuted &&
                      coordinator.proposals.isNotEmpty) {
                    await coordinator.reject(proposal);
                  }
                } else {
                  await coordinator.reject(proposal);
                }
              }).catchError((Object _) {
                s.stop('confirmationFailed');
                coordinator.stop('confirmationFailed');
              });
        },
        system: 'Use only the requested synthetic sandbox fixture.',
        close: transport.close,
        cancelActive: transport.cancelActive,
      );
      activeRunner = runner;
      try {
        final result = await runner.run(
          scenario.utterance?.call(target) ??
              'Perform ${scenario.operation} on the synthetic project ${target.path}.',
        );
        if (approving != null) await approving;
        final outcome = coordinator.recordedOutcomeFor(call.id);
        row['outcome'] = outcome?.state.name ?? 'notExecuted';
        row['mutationCount'] = permit.sent;
        row['provider'] = {
          'protocol': 'responses',
          'model': _provider.model,
          'calls': provider.requests,
          'capabilityDigest': mr7Digest({
            'tokenLimitField': _provider.caps.tokenLimitField.name,
            'requiresKey': _provider.caps.requiresKey,
            'toolChoice': _provider.caps.toolChoice,
            'maxOutputTokens': _provider.caps.maxOutputTokens,
            'maxRequestChars': _provider.caps.maxRequestChars,
          }),
          'secretLeakScan': provider.leakDetected ? 'FAIL' : 'PASS',
        };
        if (outcome?.state == AiJournalState.writeUncertain ||
            s.stopReason == 'writeUncertain') {
          row['status'] = 'writeUncertain';
          s.stop('writeUncertain');
        } else if (outcome?.noChange == true && permit.sent == 0) {
          row['status'] = scenario.expectedMutations == 0 ? 'PASS' : 'NOT_RUN';
          row['outcome'] = 'noChange';
        } else if (outcome?.state == AiJournalState.succeeded) {
          final observer = Mr7Readback(
            s,
            target,
            permit,
            paths:
                scenario.readbackPaths?.call(target, permit) ??
                {'projects/${target.projectId}'},
          );
          final verified = await scenario.observe(observer, target);
          row['observerRequests'] = observer.verifiedRequests;
          row['readback'] = verified && (row['observerRequests']! as int) > 0
              ? 'PASS'
              : 'NOT_VERIFIED';
          if (row['readback'] == 'PASS' &&
              permit.sent == scenario.expectedMutations) {
            row['status'] = 'PASS';
          } else {
            row['status'] = 'NOT_VERIFIED';
            s.stop('readbackUnverified');
          }
        } else if (permit.sent == 0 &&
            (row['confirmation'] == 'rejected' ||
                level == AiAutonomyLevel.readOnly)) {
          row['status'] = scenario.expectedMutations == 0 ? 'PASS' : 'NOT_RUN';
          row['reason'] = 'refused';
          row['outcome'] = 'notExecuted';
        } else {
          row['status'] = 'FAIL';
          row['reason'] = outcome?.reasonCode ?? result.reason.name;
          // A certain refusal ends this scenario; uncertainty fences the session above.
        }
        await s.checkIsolation();
      } catch (_) {
        row['status'] = s.stopReason == 'writeUncertain'
            ? 'writeUncertain'
            : 'NOT_VERIFIED';
        row['mutationCount'] = permit.sent;
        if (permit.sent > 0) row['readback'] = 'NOT_VERIFIED';
        s.stop('scenarioUnverified');
      } finally {
        s.permit = null;
        runner.stop();
        coordinator.stop('scenarioFinished');
        transport.close();
      }
    }
  } catch (_) {
    s.stop('runUnverified');
  } finally {
    activeRunner?.stop();
    activeCoordinator?.stop('runFinished');
    // No reset, retry or removal of the production journal's uncertain entries.
    await s.finish();
    if (root.existsSync()) {
      await root.delete(recursive: true); // Synthetic scratch only.
    }
  }
  for (final scenario in cases.where(
    (c) => !rows.any((r) => r['id'] == c.id),
  )) {
    rows.add({
      'id': scenario.id,
      'suite': scenario.suite,
      'operation': scenario.operation,
      'status': 'NOT_RUN',
      'mutationCount': 0,
      'reason': 'sessionStopped',
    });
  }
  final receipt = s.receipt(
    policy: policy,
    releaseSha: releaseSha,
    scenarios: rows,
    releasePolicy: view,
  );
  receipt['coverage'] = {
    for (final name in ['rest', 'graphql', 'advanced'])
      name: rows.any((r) => r['suite'] == name && r['status'] == 'PASS')
          ? 'SYNTHETIC'
          : 'NOT_RUN',
  };
  if (cases.isEmpty) {
    receipt['status'] = 'FAIL';
    receipt['reason'] = 'noScenarios';
  }
  if (rows.any((r) => r['status'] == 'FAIL')) receipt['status'] = 'FAIL';
  receipt['secretLeakScan'] =
      _Secrets().current.any((secret) => jsonEncode(receipt).contains(secret))
      ? 'FAIL'
      : 'PASS';
  if (receipt['secretLeakScan'] != 'PASS') receipt['status'] = 'FAIL';
  return receipt;
}

void main() {
  test('MR7 synthetic sandbox host', () async {
    final configPath = Platform.environment['MR7_SANDBOX_CONFIG_FILE'];
    final outputPath = Platform.environment['MR7_SANDBOX_RECEIPT_FILE'];
    if (configPath == null || outputPath == null) {
      throw const Mr7Refused('wrapperRequired');
    }
    final config =
        jsonDecode(await File(configPath).readAsString())
            as Map<String, dynamic>;
    final receipt = await runMr7Sandbox(
      policy: Mr7Policy.values.byName(config['policy'] as String),
      releaseSha: config['releaseSha'] as String,
      suite: config['suite'] as String,
      expectedUserId: config['expectedUserId'] as int,
      namespace: config['namespace'] as String,
      confirm: (_) async => true,
    ); // Explicit synthetic-only hook; never a live confirmation.
    await File(
      outputPath,
    ).writeAsString('${jsonEncode(receipt)}\n', flush: true);
    expect(receipt['status'], 'PASS');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
