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
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
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
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr7/sandbox_contract.dart';

final class Mr7HostProposal {
  const Mr7HostProposal({
    required this.operation,
    required this.projectId,
    required this.tier,
    required this.payloadDigest,
    this.requiredTypedName,
    this.editableField,
    this.previewText,
  });
  final String operation;
  final int projectId;
  final String tier;
  final String payloadDigest;
  final String? requiredTypedName;
  final String? editableField;
  final String? previewText;
}

typedef Mr7Confirm = Future<bool> Function(Mr7HostProposal proposal);
typedef Mr7TypedConfirm = Future<String?> Function(Mr7HostProposal proposal);
typedef Mr7Edit = Future<String?> Function(Mr7HostProposal proposal);

enum Mr7ClosureCause {
  releasePolicy,
  fixtureUnavailable,
  unsupportedServer,
  ownershipUnproven,
  observerUnavailable,
  scopeExcluded,
}

final class Mr7ClosedRefusal {
  const Mr7ClosedRefusal(this.cause, this.code);
  final Mr7ClosureCause cause;
  final String code;
  Map<String, Object?> get metadata {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]{0,63}$').hasMatch(code)) {
      throw const Mr7Refused('closureCode');
    }
    return {'type': 'closedVariant', 'cause': cause.name, 'code': code};
  }
}

/// A disposition has no executable call or provider. Missing fixtures stay
/// explicit in candidate receipts instead of disappearing from the inventory.
final class Mr7ClosedVariant {
  const Mr7ClosedVariant({
    required this.id,
    required this.suite,
    required this.operation,
    required this.variant,
    required this.tier,
    required this.refusal,
  });
  final String id;
  final String suite;
  final String operation;
  final String variant;
  final String tier;
  final Mr7ClosedRefusal refusal;
}

/// Returned only after the new sandbox has been initialized. Documents and
/// variable digests may therefore bind its fresh project ID and path.
final class Mr7ScenarioFixtures {
  const Mr7ScenarioFixtures({
    this.graphReadDocuments = const {},
    this.graphDocuments = const {},
    this.graphVariablesDigests = const {},
    this.attachments,
    this.providerScript,
    this.onProviderRequest,
  });
  final Map<String, Set<String>> graphReadDocuments;
  final Set<String> graphDocuments;
  final Set<String> graphVariablesDigests;
  final AiAttachmentSession? attachments;
  final List<List<AiToolCall>>? providerScript;
  final void Function(Map<String, Object?> request)? onProviderRequest;
}

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
    this.targetKinds,
    this.fixture,
    this.preRead,
    this.closed,
    this.projectTodo = false,
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
    this.observerQueries,
    this.noChangeObservation,
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
  final Set<AiTargetKind>? targetKinds;
  Set<AiTargetKind> get allowedTargetKinds =>
      Set.unmodifiable(targetKinds ?? {targetKind});
  final Future<Mr7ScenarioFixtures> Function(
    Mr7SandboxSession session,
    Mr7Identity identity,
  )?
  fixture;
  final List<Mr7SnapshotSpec> Function(Mr7Identity identity)? preRead;
  final Mr7ClosedRefusal? closed;
  final bool projectTodo;
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

  /// Installed after the response, so selectors may use returned IDs. Every
  /// document and every continuation variables digest remains closed.
  final Map<String, Set<String>> Function(
    Mr7Identity identity,
    Mr7MutationResult result,
  )?
  observerQueries;
  final Mr7ParentStateObservation Function(Mr7Identity identity)?
  noChangeObservation;
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
  Mr7SyntheticProvider(
    this.call, {
    List<List<AiToolCall>>? script,
    this.onRequest,
    this.allowedMetadata,
    this.allowedUserText,
    Iterable<String> hostText = const [],
    Iterable<AiStoredAttachment> attachments = const [],
  }) : script = List.unmodifiable([
         for (final batch
             in script ??
                 [
                   [call],
                 ])
           List<AiToolCall>.unmodifiable(batch),
       ]),
       attachments = List.unmodifiable(attachments) {
    final calls = this.script.expand((batch) => batch).toList();
    if (this.script.length > 12 ||
        this.script.any((batch) => batch.isEmpty || batch.length > 4) ||
        calls.length > 12 ||
        calls.map((c) => c.id).toSet().length != calls.length) {
      throw const Mr7Refused('providerScriptBound');
    }
    trustHostText(hostText);
    for (final next in calls) {
      final payloads = _freeText(next.arguments, 'payload').toList();
      // The host-selected write is an independent source, like its utterance.
      // Fixture scripts may add reads, but their arbitrary text is unproven.
      if (mr7Digest(next.arguments) == mr7Digest(call.arguments) ||
          !payloads.any((value) => value is String)) {
        trustHostText([jsonEncode(next.arguments)]);
        _hostPayloads.addAll(payloads.map(jsonEncode));
      }
      final args = next.arguments;
      if (next.id == call.id &&
          next.name == call.name &&
          mr7Digest(next.arguments) == mr7Digest(call.arguments) &&
          next.name == 'upload_attachment' &&
          args is Map &&
          args['projectId'] is int) {
        for (final attachment in this.attachments.where(
          (a) => a.id == args['attachmentId'],
        )) {
          // Independently reconstruct this closed result from metadata and
          // fixed outcome enums. Never trust arbitrary delivered result text.
          for (final referable in [false, true]) {
            trustHostText([
              AiWriteOutcome(
                state: AiJournalState.succeeded,
                reasonCode: 'succeeded',
                operationId: next.name,
                target:
                    'project:${args['projectId']}/upload/${attachment.sha256} (${attachment.filename})',
                resultSummary:
                    'attachment=${attachment.id}, referable=$referable',
              ).summary,
            ]);
          }
        }
      }
    }
  }
  final AiToolCall call;
  final List<List<AiToolCall>> script;
  final List<AiStoredAttachment> attachments;
  final void Function(Map<String, Object?> request)? onRequest;
  final String? allowedMetadata;
  final String? allowedUserText;
  final Set<String> _hostPayloads = {};

  // Register source projections before wire encoding, never from the decoded
  // provider request. Short payloads outside this closed set fail closed.
  void trustHostText(Iterable<String> text) {
    _hostPayloads.addAll(text.map(jsonEncode));
  }

  void trustHostTools(Iterable<AiToolSpec> tools) {
    _hostPayloads.addAll(
      _freeText({
        'tools': [
          for (final tool in tools)
            {
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
        ],
      }).map(jsonEncode),
    );
  }

  int requests = 0;
  bool leakDetected = false;
  bool attachmentLeakDetected = false;

  // Shapes follow lib/core/ai/wire/{responses,chat_completions,
  // anthropic_messages}.dart. Exemptions apply only at those wire positions;
  // unrecognised fields and function-argument objects are all payload.
  static Iterable<Object?> _freeText(
    Object? value, [
    String shape = 'request',
  ]) sync* {
    if (value is String) {
      yield value;
    } else if (value is List) {
      if (value.isNotEmpty && value.every((item) => item is num)) {
        yield value;
      } else {
        for (final item in value) {
          yield* _freeText(item, shape);
        }
      }
    } else if (value is Map) {
      final protocol = switch (shape) {
        'request' => const {
          'model',
          'stream',
          'store',
          'max_tokens',
          'max_completion_tokens',
          'max_output_tokens',
          'include',
        },
        'message' => const {
          'role',
          'type',
          'id',
          'call_id',
          'tool_call_id',
          'status',
        },
        'part' => const {'type', 'id', 'tool_use_id', 'status'},
        'tool' || 'function' => const {'name', 'type'},
        'toolCall' => const {'id', 'type', 'index'},
        'choice' => const {'type', 'name'},
        'cache' => const {'type'},
        'schema' => const {
          'type',
          'enum',
          'const',
          'required',
          r'$schema',
          r'$ref',
          'format',
          'nullable',
        },
        _ => const <String>{},
      };
      for (final entry in value.entries) {
        if (protocol.contains(entry.key) ||
            (entry.key == 'name' &&
                ((shape == 'message' && value['type'] == 'function_call') ||
                    (shape == 'part' &&
                        const {
                          'tool_use',
                          'server_tool_use',
                        }.contains(value['type']))))) {
          continue;
        }
        final child = switch ((shape, entry.key)) {
          ('request', 'input' || 'messages') => 'message',
          ('request', 'tools') => 'tool',
          ('request', 'tool_choice') => 'choice',
          ('message', 'content' || 'summary') =>
            value['role'] != 'tool' && entry.value is List ? 'part' : 'payload',
          ('message', 'tool_calls') => 'toolCall',
          ('message', 'function_call') ||
          ('toolCall' || 'tool', 'function') => 'function',
          ('tool' || 'function', 'parameters' || 'input_schema') => 'schema',
          ('part', 'cache_control') => 'cache',
          (
            'schema',
            'properties' || r'$defs' || 'definitions' || 'patternProperties',
          ) =>
            'properties',
          (
            'schema',
            'items' ||
                'anyOf' ||
                'allOf' ||
                'oneOf' ||
                'not' ||
                'additionalProperties',
          ) ||
          ('properties', _) => 'schema',
          _ => 'payload',
        };
        // A string tool choice is itself an enum; unknown object members scan.
        if (child == 'choice' && entry.value is String) continue;
        yield* _freeText(entry.value, child);
      }
    }
  }

  static ({Map<String, Object?> owner, String key})? _userText(
    Map<String, Object?> body,
  ) {
    final messages = body['input'] ?? body['messages'];
    if (messages is! List) return null;
    // Responses and Anthropic start with the host user entry. Chat prepends
    // exactly one system message. Never grant an exemption to a later user.
    final index =
        body.containsKey('messages') &&
            messages.isNotEmpty &&
            messages.first is Map &&
            (messages.first as Map)['role'] == 'system'
        ? 1
        : 0;
    if (messages.length > index) {
      final message = messages[index];
      if (message is! Map<String, Object?> || message['role'] != 'user') {
        return null;
      }
      final content = message['content'];
      if (content is String) return (owner: message, key: 'content');
      if (content is List && content.length == 1) {
        final part = content.single;
        if (part is Map<String, Object?> &&
            const {'input_text', 'text'}.contains(part['type']) &&
            part['text'] is String) {
          return (owner: part, key: 'text');
        }
      }
    }
    return null;
  }

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
    if (body.length > 128000 || requests > 12) {
      throw const Mr7Refused('providerRequestBound');
    }
    if (body.contains('synthetic-gitlab-pat')) {
      leakDetected = true;
      throw const Mr7Refused('providerSecretLeak');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const Mr7Refused('providerRequest');
    }
    final scanBody = jsonDecode(body) as Map<String, Object?>;
    final user = _userText(scanBody);
    final userText = user == null ? null : user.owner[user.key] as String;
    for (final attachment in attachments) {
      final bytes = attachment.bytes;
      if (bytes.isEmpty) continue;
      // Below 16 bytes, common words/identifiers are not distinctive. Bind the
      // entire user text to the host projection instead of substring-scanning it.
      final short = bytes.length < 16;
      if (short && (allowedUserText == null || userText != allowedUserText)) {
        attachmentLeakDetected = true;
        throw const Mr7Refused('providerAttachmentBytes');
      }
      if (user != null) {
        final suffix = '\n\n$allowedMetadata';
        user.owner[user.key] = short
            ? null
            : allowedMetadata != null && userText!.endsWith(suffix)
            ? userText.substring(0, userText.length - suffix.length)
            : userText;
      }
      final encoded = base64Encode(bytes);
      final array = jsonEncode(bytes);
      String? plain;
      try {
        plain = utf8.decode(bytes);
      } on FormatException {
        /* Binary bytes have no text projection. */
      }
      bool leaks(Object? value) {
        if (value is String) {
          final text = value;
          bool matches(String needle) =>
              short ? text == needle : text.contains(needle);
          if (matches(encoded) ||
              matches(array) ||
              (plain != null && matches(plain))) {
            return true;
          }
          // Argument strings and tool results can contain encoded JSON values,
          // including spaced byte arrays and keys that resemble protocol fields.
          try {
            final nested = jsonDecode(text);
            if (nested is List || nested is Map) return leaks(nested);
          } on FormatException {
            /* Ordinary free text is not JSON. */
          }
          return false;
        }
        if (value is List) {
          if (value.length == bytes.length &&
              Iterable<int>.generate(
                bytes.length,
              ).every((i) => value[i] == bytes[i])) {
            return true;
          }
          return value.any(leaks);
        }
        if (value is Map) return value.values.any(leaks);
        return false;
      }

      final leaked = _freeText(scanBody).any(
        (value) =>
            leaks(value) ||
            (short && !_hostPayloads.contains(jsonEncode(value))),
      );
      if (user != null) user.owner[user.key] = userText;
      if (leaked) {
        attachmentLeakDetected = true;
        throw const Mr7Refused('providerAttachmentBytes');
      }
    }
    onRequest?.call(Map.unmodifiable(decoded));
    final index = requests++;
    final output = index < script.length
        ? [
            for (final next in script[index])
              {
                'type': 'function_call',
                'call_id': next.id,
                'name': next.name,
                'arguments': jsonEncode(next.arguments),
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
  Mr7Edit? editConfirm,
  List<Mr7Scenario>? scenarios,
  List<Mr7ClosedVariant> closedVariants = const [],
  Mr7SandboxSession? session,
  Mr7SyntheticGitLab? server,
  String suite = 'all',
  int expectedUserId = 7,
  String namespace = 'synthetic-owner',
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
  bool Function()? boundaryValid,
  AiToolBudget? sharedBudget,
  AiWriteJournal? journal,
  String? conversationId,
  DateTime Function()? now,
}) async {
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(releaseSha) ||
      !const {'all', 'rest', 'graphql', 'advanced'}.contains(suite)) {
    throw const Mr7Refused('configuration');
  }
  final cases = (scenarios ?? mr7ContractScenarios())
      .where((s) => suite == 'all' || suite == s.suite)
      .toList();
  final closed = closedVariants
      .where((v) => suite == 'all' || suite == v.suite)
      .toList();
  final ids = [...cases.map((s) => s.id), ...closed.map((v) => v.id)];
  if (ids.toSet().length != ids.length) {
    throw const Mr7Refused('duplicateScenario');
  }
  final productBudget = AiToolBudget();
  if (cases.any(
        (s) =>
            !s.allowedTargetKinds.contains(s.targetKind) ||
            s.maxMutations < 1 ||
            s.maxMutations > 8 ||
            s.expectedMutations < 0 ||
            s.expectedMutations > s.maxMutations,
      ) ||
      (conversationId != null &&
          !RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(conversationId)) ||
      (sharedBudget != null &&
          (sharedBudget.maxGitLabRequests < 1 ||
              sharedBudget.maxGitLabRequests >
                  productBudget.maxGitLabRequests ||
              sharedBudget.maxCallsPerRun < 1 ||
              sharedBudget.maxCallsPerRun > productBudget.maxCallsPerRun ||
              sharedBudget.maxCallsPerTurn < 1 ||
              sharedBudget.maxCallsPerTurn > productBudget.maxCallsPerTurn ||
              sharedBudget.maxSearches < 0 ||
              sharedBudget.maxSearches > productBudget.maxSearches ||
              sharedBudget.maxOutputChars < 0 ||
              sharedBudget.maxOutputChars > productBudget.maxOutputChars ||
              sharedBudget.maxSingleOutputChars < 0 ||
              sharedBudget.maxSingleOutputChars >
                  productBudget.maxSingleOutputChars))) {
    throw const Mr7Refused('scenarioBound');
  }
  final view = mr7SandboxPolicy(
    policy,
    reads: {for (final c in cases) ...c.readNames},
    writes: {
      for (final s in cases)
        s.operation: {
          for (final other in cases.where((c) => c.operation == s.operation))
            ...other.allowedTargetKinds,
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
  final rows = <Map<String, Object?>>[
    for (final v in closed)
      {
        'id': v.id,
        'suite': v.suite,
        'operation': v.operation,
        'variant': v.variant,
        'tier': v.tier,
        'status': 'NOT_RUN',
        'classification': 'closedVariant',
        'refusal': v.refusal.metadata,
        'reason': v.refusal.code,
        'mutationCount': 0,
        'readback': 'NOT_RUN',
        'providerCalls': 0,
        'live': 'NOT_RUN',
        'releaseSha': releaseSha,
      },
  ];
  final root = journal == null
      ? await Directory.systemTemp.createTemp('mr7-journal-')
      : null;
  PolicyAiWriteCoordinator? activeCoordinator;
  AiRunner? activeRunner;
  final account = '${s.instance}#${s.expectedUserId}';
  final journalStore =
      journal ??
      AiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root!,
        processId: 'mr7-synthetic-host',
      );
  if (now != null) journalStore.now = now;
  final attachmentSessions = <AiAttachmentSession>{};
  final placeholderTables = <String, UploadPlaceholderTable>{};
  try {
    await s.initialize();
    if (journal == null) {
      await journalStore.recoverAfterAccountsLoaded([account]);
    } else if (!journalStore.recovered(account)) {
      throw const Mr7Refused('journalRecoveryRequired');
    }
    final keyStatus = await journalStore.keyStatus(account);
    if (keyStatus == AiJournalKeyStatus.uninitialized) {
      await journalStore.ensureInitialized(account);
    } else if (keyStatus != AiJournalKeyStatus.found) {
      throw const Mr7Refused('journalUnavailable');
    }
    for (final scenario in cases) {
      final scenarioView = mr7SandboxPolicy(
        policy,
        reads: Set.unmodifiable(scenario.readNames),
        writes: {scenario.operation: scenario.allowedTargetKinds},
      );
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
        'targetKinds': scenario.allowedTargetKinds.map((k) => k.name).toList()
          ..sort(),
      };
      rows.add(row);
      if (scenario.closed case final refusal?) {
        row.addAll({
          'classification': 'closedVariant',
          'refusal': refusal.metadata,
          'reason': refusal.code,
          'providerCalls': 0,
        });
        continue;
      }
      if (s.quarantined) {
        row['reason'] = 'sessionStopped';
        continue;
      }
      final projectTodo =
          scenario.projectTodo &&
          const {'snoozeTodo', 'unsnoozeTodo'}.contains(scenario.operation);
      if ((mr7ExcludedOperations.contains(scenario.operation) &&
              !projectTodo) ||
          scenario.operation.toLowerCase().contains('group') ||
          !scenarioView.allowsWrite(scenario.operation, scenario.targetKind)) {
        row.addAll({
          'reason': 'releaseClosed',
          'classification': 'closedVariant',
          'providerCalls': 0,
          'refusal': const Mr7ClosedRefusal(
            Mr7ClosureCause.releasePolicy,
            'releaseClosed',
          ).metadata,
        });
        continue;
      }
      row.addAll({
        'declaredTier': scenario.tier,
        'tier': null,
        'decision': null,
        'confirmationReasons': <String>[],
        'decisionProjection': 'unavailable',
        'decisionUnavailable': 'proposalUnavailable',
      });
      final target = s.identity!;
      final scenarioConversationId = conversationId ?? scenario.id;
      final placeholders = placeholderTables.putIfAbsent(
        scenarioConversationId,
        () => UploadPlaceholderTable(
          instance: GitLabInstance.parse(s.instance.toString()),
          accountKey: account,
          conversationId: scenarioConversationId,
        ),
      );
      final fixtures =
          await scenario.fixture?.call(s, target) ??
          const Mr7ScenarioFixtures();
      if (projectTodo && !s.allowsTodoFixture(scenario.operation)) {
        throw const Mr7Refused('todoFixtureUnproven');
      }
      final attachments = fixtures.attachments;
      if (attachments != null) {
        attachmentSessions.add(attachments);
        if (attachments.accountKey != account ||
            attachments.conversationId != scenarioConversationId ||
            attachments.fileCapBytes > GitLabApi.maxUploadBytes) {
          throw const Mr7Refused('attachmentSessionIdentity');
        }
      }
      await s.verifyIdentity();
      s.observerAdapter.graphReadDocuments = Map.unmodifiable({
        for (final key in {
          ...scenario.graphReadDocuments.keys,
          ...fixtures.graphReadDocuments.keys,
        })
          key: Set<String>.unmodifiable({
            ...?scenario.graphReadDocuments[key],
            ...?fixtures.graphReadDocuments[key],
          }),
      });
      final call = scenario.call(target);
      row['fixtureDigest'] = mr7Digest(call.arguments);
      if (call.name != scenario.operation) {
        throw const Mr7Refused('scenarioOperation');
      }
      final snapshotSpecs =
          scenario.preRead?.call(target) ?? const <Mr7SnapshotSpec>[];
      final snapshot = snapshotSpecs.isEmpty
          ? null
          : await s.captureSnapshot(snapshotSpecs);
      if (snapshot != null) row['preread'] = snapshot.metadata;
      final budget = sharedBudget ?? AiToolBudget();
      final api = GitLabApi(
        instance: GitLabInstance.parse(s.instance.toString()),
        token: 'synthetic-gitlab-pat',
        dio: s.writer,
        cdnAdapter: s.writerAdapter,
      );
      final script = fixtures.providerScript;
      if (script != null &&
          (script
                      .expand((batch) => batch)
                      .where((c) => c.name == scenario.operation)
                      .length !=
                  1 ||
              script
                      .expand((batch) => batch)
                      .where(
                        (c) =>
                            c.id == call.id &&
                            c.name == call.name &&
                            mr7Digest(c.arguments) == mr7Digest(call.arguments),
                      )
                      .length !=
                  1 ||
              script
                  .expand((batch) => batch)
                  .any(
                    (c) =>
                        c.name != scenario.operation &&
                        !scenario.readNames.contains(c.name),
                  ))) {
        throw const Mr7Refused('providerScriptOperation');
      }
      final metadata = attachments?.metadataForModel()['block'];
      final utterance =
          scenario.utterance?.call(target) ??
          'Perform ${scenario.operation} on the synthetic project ${target.path}.';
      final userText = metadata is String
          ? '$utterance\n\n$metadata'
          : utterance;
      final provider = Mr7SyntheticProvider(
        call,
        script: script,
        onRequest: fixtures.onProviderRequest,
        attachments: attachments?.items ?? const [],
        allowedMetadata: metadata is String ? metadata : null,
        allowedUserText: userText,
      );
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
      late final PolicyAiWriteCoordinator coordinator;
      coordinator = PolicyAiWriteCoordinator(
        releasePolicy: scenarioView,
        snapshot: () => AiWritePolicySnapshot(
          scope: writeScope,
          level: level,
          ceiling: AiAutonomyLevel.bypass,
          consentHash: mr7Digest(scenarioView.canonicalIdentity),
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
        journal: journalStore,
        conversationId: scenarioConversationId,
        budget: () => budget,
        readFreshness: (request) async {
          await s.verifyIdentity();
          if (scenario.freshness != null) {
            return scenario.freshness!(s, request);
          }
          final value = await s.read('projects/${target.projectId}');
          row.putIfAbsent(
            'preread',
            () => {'projectId': value['id'], 'versionDigest': mr7Digest(value)},
          );
          return const AiWriteFreshness(
            visibilityUnreadable: false,
            sourceVisibilityUnreadable: false,
            targetVisibility: 'private',
          );
        },
        placeholders: placeholders,
        attachments: attachments,
        attachmentSubstitution: (project) =>
            attachments?.substitutionFor(project),
        now: now,
        knownSecrets: () => _Secrets().current.toSet(),
        safeDisplay: (value) => value,
        checkFragmentsWithCount: exact.checkFragments,
        onChanged: () {
          final observed = coordinator.proposalFor(call.id)?.tier;
          if (observed == null) return;
          final tier = observed.tier.name == 'hardLine'
              ? 'hardLine'
              : observed.tier.name.toUpperCase();
          row.addAll({
            'tier': tier,
            'decision': observed.decision.name,
            'confirmationReasons': observed.reasons.map((r) => r.name).toList()
              ..sort(),
            'decisionProjection': 'observed',
          });
          row.remove('decisionUnavailable');
          if (tier != scenario.tier) s.stop('tierMismatch');
        },
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
        releasePolicy: scenarioView,
        placeholders: placeholders,
      );
      final permit = Mr7MutationPermit(
        operation: scenario.operation,
        paths: scenario.paths(target),
        resourceProjectId: target.projectId,
        maxMutations: scenario.maxMutations,
        graphDocuments: Set.unmodifiable({
          ...scenario.graphDocuments,
          ...fixtures.graphDocuments,
        }),
        graphVariablesDigests: Set.unmodifiable({
          ...scenario.graphVariablesDigests,
          ...fixtures.graphVariablesDigests,
        }),
        resultPath: scenario.resultPath,
      );
      permit.snapshot = snapshot;
      s.permit = permit;
      Future<void>? approving;
      Mr7HostProposal hostProposal({AiWriteProposal? product}) =>
          Mr7HostProposal(
            operation: scenario.operation,
            projectId: target.projectId,
            tier:
                row['tier'] as String? ??
                (throw const Mr7Refused('decisionUnavailable')),
            payloadDigest: product?.payloadDigest ?? mr7Digest(call.arguments),
            requiredTypedName: product?.tier.typedName,
            editableField: product?.editableField,
            previewText: product?.previewText,
          );
      Future<bool> confirmHost({AiWriteProposal? product}) async {
        row['proposalAt'] = DateTime.now().toUtc().toIso8601String();
        final host = hostProposal(product: product);
        row['payloadDigest'] = host.payloadDigest;
        final confirmations =
            row.putIfAbsent('confirmations', () => <Map<String, Object?>>[])!
                as List<Map<String, Object?>>;
        final accepted = await confirm(host);
        confirmations.add({
          'payloadDigest': host.payloadDigest,
          'accepted': accepted,
        });
        row['confirmAt'] = DateTime.now().toUtc().toIso8601String();
        row['confirmation'] = accepted
            ? 'explicitSyntheticTestHook'
            : 'rejected';
        return accepted;
      }

      permit.confirmBeforeSend = () => confirmHost();
      const system = 'Use only the requested synthetic sandbox fixture.';
      final tools = [...catalogue.specs, ...coordinator.specs];
      provider.trustHostText([system]);
      provider.trustHostTools(tools);
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
        tools: tools,
        writeCoordinator: coordinator,
        executeTool: (call) async =>
            (await catalogue.execute(call, budget: budget)).result,
        prepareToolResults: (calls, results, beforeDelivery) =>
            catalogue.prepareDelivery(
              calls,
              results,
              budget: budget,
              beforeDelivery: beforeDelivery,
            ),
        beginToolTurn: budget.beginTurn,
        toolBudgetExhausted: () => budget.exhausted,
        onAwaitingApproval: (awaiting) {
          if (!awaiting || approving != null) return;
          approving =
              Future<void>(() async {
                final proposal = coordinator.proposals.single;
                var accepted = await confirmHost(product: proposal);
                if (accepted &&
                    editConfirm != null &&
                    proposal.editableField != null) {
                  final editedText = await editConfirm(
                    hostProposal(product: proposal),
                  );
                  if (editedText != null) {
                    final before = proposal.payloadDigest;
                    final edited = await coordinator.approve(
                      proposal,
                      editedText: editedText,
                    );
                    row['edit'] = {
                      'beforeDigest': before,
                      'afterDigest': proposal.payloadDigest,
                      'state': edited.state.name,
                      'reason': edited.reasonCode,
                    };
                    accepted =
                        edited.state == AiJournalState.notExecuted &&
                        edited.reasonCode == 'approvalRequired' &&
                        await confirmHost(product: proposal);
                  }
                }
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
        system: system,
        close: transport.close,
        cancelActive: transport.cancelActive,
      );
      activeRunner = runner;
      try {
        final result = await runner.run(userText, bindingUtterance: utterance);
        if (approving != null) await approving;
        final outcome = coordinator.recordedOutcomeFor(call.id);
        row['outcome'] = outcome?.state.name ?? 'notExecuted';
        row['coreOutcome'] = outcome?.state.name ?? 'notExecuted';
        row['coreNoChange'] = outcome?.noChange ?? false;
        row['mutationCount'] = permit.sent;
        row['budget'] = {
          'gitLabRequests': budget.gitLabRequests,
          'calls': budget.calls,
          'shared': sharedBudget != null,
          'journalInjected': journal != null,
        };
        if (permit.upload != null) row['upload'] = permit.upload;
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
          'attachmentLeakScan': provider.attachmentLeakDetected
              ? 'FAIL'
              : 'PASS',
        };
        if (s.stopReason == 'tierMismatch') {
          row['status'] = 'FAIL';
          row['reason'] = 'tierMismatch';
        } else if (outcome?.state == AiJournalState.writeUncertain ||
            s.stopReason == 'writeUncertain') {
          row['status'] = 'writeUncertain';
          s.stop('writeUncertain');
        } else if (outcome?.noChange == true && permit.sent == 0) {
          row['outcome'] = 'noChange';
          final state = scenario.noChangeObservation?.call(target);
          if (state == null) throw const Mr7Refused('noChangeUnverified');
          final observer = Mr7Readback(
            s,
            target,
            permit,
            paths:
                scenario.readbackPaths?.call(target, permit) ??
                {'projects/${target.projectId}'},
          );
          final verified = await observer.observeNoChange(
            state,
            arguments: call.arguments,
          );
          row.addAll({
            'parentStateVerified': verified,
            'observerRequests': observer.verifiedRequests,
            'readback': verified && observer.verifiedRequests > 0
                ? 'PASS'
                : 'NOT_VERIFIED',
            'status':
                verified &&
                    observer.verifiedRequests > 0 &&
                    scenario.expectedMutations == 0
                ? 'PASS'
                : 'NOT_VERIFIED',
          });
          if (row['status'] == 'PASS') {
            row['classification'] = 'verifiedNoOp';
          } else {
            row['reason'] = 'noChangeUnverified';
            s.stop('noChangeUnverified');
          }
        } else if (outcome?.state == AiJournalState.succeeded) {
          final queries =
              scenario.observerQueries?.call(target, permit.result!) ??
              const <String, Set<String>>{};
          final sealedQueries = Map<String, Set<String>>.unmodifiable({
            for (final entry in queries.entries)
              entry.key: Set<String>.unmodifiable(entry.value),
          });
          s.observerAdapter.graphReadDocuments = Map.unmodifiable({
            ...s.observerAdapter.graphReadDocuments,
            for (final entry in sealedQueries.entries)
              entry.key: Set<String>.unmodifiable({
                ...?s.observerAdapter.graphReadDocuments[entry.key],
                ...entry.value,
              }),
          });
          final observer = Mr7Readback(
            s,
            target,
            permit,
            paths:
                scenario.readbackPaths?.call(target, permit) ??
                {'projects/${target.projectId}'},
            graphQueries: sealedQueries,
          );
          final noChangeResponse =
              permit.result?.status == 304 || outcome?.noChange == true;
          bool verified;
          if (noChangeResponse) {
            final state = scenario.noChangeObservation?.call(target);
            final recognized =
                permit.sent == 1 &&
                ((permit.result?.status == 304 &&
                        const {
                          'setStar',
                          'setSubscribed',
                        }.contains(scenario.operation)) ||
                    (permit.result?.status == 409 &&
                        outcome?.noChange == true));
            if (!recognized ||
                state == null ||
                !state.matchesCall(
                  scenario.operation,
                  call.arguments,
                  target.projectId,
                )) {
              throw const Mr7Refused('noChangeUnverified');
            }
            verified = await observer.observe(state);
            row['outcome'] = 'noChange';
            row['responseStatus'] = permit.result!.status;
            row['parentStateVerified'] = verified;
          } else {
            verified = await scenario.observe(observer, target);
          }
          if (snapshot != null) {
            verified = await observer.verifySnapshot() && verified;
            row['snapshotVerified'] = verified;
          }
          row['observerRequests'] = observer.verifiedRequests;
          row['readback'] = verified && (row['observerRequests']! as int) > 0
              ? 'PASS'
              : 'NOT_VERIFIED';
          if (row['readback'] == 'PASS' &&
              permit.sent == scenario.expectedMutations) {
            row['status'] = 'PASS';
            if (noChangeResponse) row['classification'] = 'verifiedNoOp';
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
      } catch (error) {
        row['status'] = s.stopReason == 'tierMismatch'
            ? 'FAIL'
            : s.stopReason == 'writeUncertain'
            ? 'writeUncertain'
            : 'NOT_VERIFIED';
        row['mutationCount'] = permit.sent;
        row['reason'] = s.stopReason == 'tierMismatch'
            ? 'tierMismatch'
            : error is Mr7Refused
            ? error.code
            : 'scenarioUnverified';
        if (permit.sent > 0 || row['coreNoChange'] == true) {
          row['readback'] = 'NOT_VERIFIED';
        }
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
    for (final attachments in attachmentSessions) {
      attachments.discardAll();
    }
    if (root != null && root.existsSync()) {
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
  if (cases.isEmpty && closed.isEmpty) {
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
