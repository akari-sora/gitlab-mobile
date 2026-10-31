// Shared harnesses for the fx-coord tests (MR6b-1 review round 1).

import 'release_policy_support.dart';
import 'mr6b3_support.dart' show Mr6b3JournalFiles;
import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart'
    show AiGitLabWritePort, GitLabAiWritePort;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show UploadPlaceholderTable;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';

// ---------------------------------------------------------------------------
// Coordinator over the real GitLabAiWritePort, journal and a FakeAdapter.
// ---------------------------------------------------------------------------

const coordAccount = 'https://example.com/gitlab#7';
const coordScope = AiWriteScope(
  accountKey: coordAccount,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);

AiToolCall starCall(String id) => AiToolCall(
  id: id,
  name: 'setStar',
  arguments: const {
    'projectId': 9,
    'starred': true,
    'reason': 'The user asked for a star.',
  },
);

AiToolCall coordNoteCall(String id, {String body = 'synthetic body'}) =>
    AiToolCall(
      id: id,
      name: 'createNote',
      arguments: {
        'projectId': 9,
        'resource': 'issues',
        'iid': 3,
        'body': body,
        'reason': 'The user asked for a note.',
      },
    );

final class CoordHarness {
  CoordHarness._(
    this.root,
    this.journal,
    this.adapter,
    this.api,
    this.budget,
    this.files,
  ) : _maxGitLabRequests = budget.maxGitLabRequests;

  static Future<CoordHarness> create({
    int maxGitLabRequests = 40,
    Responder? responder,
  }) async {
    final root = Directory.systemTemp.createTempSync('fx-coord-');
    final files = Mr6b3JournalFiles(root);
    final journal = AiWriteJournal(
      files: files,
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'fx-coord-test',
    );
    await journal.recoverAfterAccountsLoaded([coordAccount]);
    await journal.ensureInitialized(coordAccount);
    late final CoordHarness harness;
    final adapter = FakeAdapter(
      responder ?? (request) => harness.respond(request),
    );
    final api = testApi(adapter);
    harness = CoordHarness._(
      root,
      journal,
      adapter,
      api,
      AiToolBudget(maxGitLabRequests: maxGitLabRequests),
      files,
    );
    harness.coordinator = harness.newCoordinator();
    return harness;
  }

  final Directory root;
  final Mr6b3JournalFiles files;
  final AiWriteJournal journal;
  final FakeAdapter adapter;
  final GitLabApi api;
  AiToolBudget budget;
  final int _maxGitLabRequests;
  late PolicyAiWriteCoordinator coordinator;

  /// A new run, as the runner starts one: a fresh tool budget, then the
  /// coordinator's run and first turn.
  void newRun(String userText) {
    budget = AiToolBudget(maxGitLabRequests: _maxGitLabRequests);
    coordinator.beginRun(userText);
    coordinator.beginTurn();
  }

  /// The conversation's attachments, as the controller passes them.
  final attachments = AiAttachmentSession(
    accountKey: coordAccount,
    conversationId: 'fx-coord-conversation',
  );

  /// Visibility of project 9 in GitLab's answers.
  String projectVisibility = 'private';

  /// When set, every mutation answers with this HTTP status.
  int? failWritesWith;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  bool foreground = true;
  bool clientMayStart = true;
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  Completer<void>? freshnessEntered;
  Completer<void>? releaseFreshness;
  int freshnessReads = 0;
  int portCreations = 0;

  /// The fresh read (1-based) that waits on [freshnessEntered]; null: any.
  int? barrierRead;

  PolicyAiWriteCoordinator newCoordinator({
    String conversationId = 'fx-coord-conversation',
    AiReleasePolicyView? releasePolicy,
    AiCapabilityLedger? ledger,
    AiWriteScope scope = coordScope,
    AiGitLabWritePort Function()? portFactory,
    AiWriteFragmentChecker? checkFragments,
  }) => PolicyAiWriteCoordinator(
    releasePolicy: releasePolicy ?? fixtureReleasePolicy,
    ledger: ledger,
    snapshot: () => AiWritePolicySnapshot(
      scope: scope,
      level: level,
      ceiling: AiAutonomyLevel.bypass,
      consentHash: 'consent-v2',
      writePolicyRevision: 1,
      scopeRevision: 1,
      sessionGeneration: 7,
      appInForeground: foreground,
      clientMayStart: clientMayStart,
    ),
    createPort: () {
      portCreations++;
      return portFactory?.call() ??
          GitLabAiWritePort(api, accountKey: coordAccount);
    },
    journal: journal,
    conversationId: conversationId,
    budget: () => budget,
    readFreshness: (_) async {
      freshnessReads++;
      if (freshnessEntered case final entered?
          when !entered.isCompleted &&
              (barrierRead == null || barrierRead == freshnessReads)) {
        entered.complete();
        if (releaseFreshness case final release?) await release.future;
      }
      return const AiWriteFreshness(
        updatedAt: '2026-10-23T00:00:00Z',
        visibilityUnreadable: false,
      );
    },
    placeholders: UploadPlaceholderTable(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
    ),
    knownSecrets: () => const {},
    safeDisplay: (value) => value,
    now: () => clock,
    attachments: attachments,
    checkFragments: checkFragments,
  );

  /// Holds one picked file as `att-<n>`.
  Future<AiStoredAttachment> attach(
    String filename,
    List<int> bytes, {
    String? contentType = 'image/png',
  }) async {
    final result = await attachments.reserveAndRead(
      picker: FakePicker([
        PickedAttachment(
          filename: filename,
          bytes: bytes,
          contentType: contentType,
        ),
      ]),
      uploadToolInSegment: true,
    );
    expect(result.attachment, isNotNull, reason: '${result.reasonCode}');
    return result.attachment!;
  }

  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = request.uri.path;
    if (request.method != 'GET') {
      if (failWritesWith case final status?) {
        return jsonResponse({'message': 'synthetic failure'}, status: status);
      }
      if (path.endsWith('/projects/9/uploads')) {
        return jsonResponse({
          'alt': 'shot.png',
          'markdown': '![shot.png](/uploads/$uploadSecret/shot.png)',
          'url': '/uploads/$uploadSecret/shot.png',
        }, status: 201);
      }
      if (path.endsWith('/projects/9/issues/3/notes')) {
        return jsonResponse({'id': 31, 'body': 'synthetic'}, status: 201);
      }
      return jsonResponse(projectJson(9), status: 201);
    }
    if (path.endsWith('/user')) {
      return jsonResponse({'id': 7, 'username': 'tester'});
    }
    if (path.endsWith('/projects/9')) {
      return jsonResponse({...projectJson(9), 'visibility': projectVisibility});
    }
    if (path.endsWith('/projects/9/issues/3')) {
      return jsonResponse({'id': 30, 'iid': 3, 'project_id': 9});
    }
    if (path.contains('/projects/9/issues/3/notes/')) {
      return jsonResponse({'id': 31, 'body': 'synthetic'});
    }
    throw StateError('Unexpected request: ${request.method} ${request.uri}');
  }

  int get mutations =>
      adapter.requests.where((request) => request.method != 'GET').length;

  Future<void> dispose() async {
    coordinator.stop('disposed');
    attachments.discardAll();
    api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

// ---------------------------------------------------------------------------
// The production chat controller, runner, coordinator and port, with GitLab
// (WorkspaceFixture plus overrides) and a scripted Responses provider faked
// at the Dio adapter.
// ---------------------------------------------------------------------------

/// A 32-hex upload secret the fake GitLab returns for every upload.
const uploadSecret = '0123456789abcdef0123456789abcdef';

final class StackServer {
  StackServer() {
    workspace.issues[5] = workspace.issue(5, 'Synthetic five');
    workspace.issues[6] = workspace.issue(6, 'Synthetic six');
    for (final iid in [5, 6]) {
      overrides['GET projects/42/issues/$iid/notes'] = (_) =>
          jsonResponse(<Object?>[]);
    }
  }

  final workspace = WorkspaceFixture();
  late final adapter = FakeAdapter(_respond);
  final mutations = <RequestOptions>[];

  /// Overrides that answer before [WorkspaceFixture]. Keys are the path
  /// below `/api/v4/`, prefixed with the method, e.g. `GET todos`.
  final overrides = <String, FutureOr<ResponseBody> Function(RequestOptions)>{};

  /// Replaces the project record's visibility.
  String? visibility;

  /// What `POST projects/42/uploads` returns as `markdown`.
  String Function(String filename) uploadMarkdown = (name) =>
      '![$name](/uploads/$uploadSecret/$name)';

  int gets = 0;

  List<RequestOptions> get uploads => [
    for (final request in mutations)
      if (request.uri.path.endsWith('/projects/42/uploads')) request,
  ];

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final start = segments.indexOf('v4');
    final path = start < 0 ? '' : segments.skip(start + 1).join('/');
    final method = request.method;
    if (method == 'GET' || method == 'HEAD') {
      gets++;
    } else {
      mutations.add(request);
    }
    final override = overrides['$method $path'];
    if (override != null) return override(request);
    if (path == 'projects/42' && method == 'GET' && visibility != null) {
      return jsonResponse({
        ...workspace.projectRecord,
        'visibility': visibility,
      });
    }
    if (path == 'projects/42/uploads' && method == 'POST') {
      var name = 'file';
      final data = request.data;
      if (data is FormData && data.files.isNotEmpty) {
        name = data.files.first.value.filename ?? name;
      }
      return jsonResponse({
        'alt': name,
        'markdown': uploadMarkdown(name),
        'url': '/uploads/$uploadSecret/$name',
        'full_path': '/studio/mobile-workspace/uploads/$uploadSecret/$name',
      }, status: 201);
    }
    return workspace.respond(request);
  }
}

/// A scripted Responses provider. Each request takes the next turn; an empty
/// script answers in text.
final class StackProvider {
  final bodies = <String>[];
  final script = <String Function(String body)>[];
  late final adapter = FakeAdapter((request) {
    final data = request.data;
    final body = data is String ? data : jsonEncode(data);
    bodies.add(body);
    final next = script.isEmpty ? (_) => answerTurn : script.removeAt(0);
    return _sse(next(body));
  });
}

final class FakePicker implements AttachmentPicker {
  FakePicker([List<PickedAttachment?> picks = const []])
    : picks = List.of(picks);

  final List<PickedAttachment?> picks;

  @override
  Future<PickedAttachment?> pickImage() async => _next();

  @override
  Future<PickedAttachment?> pickFile() async => _next();

  PickedAttachment? _next() => picks.isEmpty ? null : picks.removeAt(0);
}

final class StackHarness {
  StackHarness._(
    this.root,
    this.server,
    this.provider,
    this.session,
    this.settings,
    this.journal,
    this.journalKeys,
    this.picker,
  );

  final Directory root;
  final StackServer server;
  final StackProvider provider;
  final SessionController session;
  final AiSettingsController settings;
  final AiWriteJournal journal;

  /// The journal's keys, so a test can decrypt the file the journal wrote.
  final MemoryAiJournalKeyStore journalKeys;
  final FakePicker picker;
  late final AiChatController controller;

  String get account => server.workspace.account.key;

  static Future<StackHarness> create({
    AiChatOrigin? origin,
    AiAutonomyLevel level = AiAutonomyLevel.lowRiskAuto,
    AiWriteScope Function(StackServer server)? writeScope,
    List<PickedAttachment?> picks = const [],
    void Function(StackServer server)? configure,
    Future<void> Function(SessionController session, StackServer server)?
    prepareSession,
    DateTime Function()? now,
    Future<void> Function()? refreshSecrets,
  }) async {
    final server = StackServer();
    configure?.call(server);
    final workspace = server.workspace;
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    final session = controllerFor(accounts, server.adapter);
    await session.initialize();
    await prepareSession?.call(session, server);

    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final config = await settings.saveProvider(stackProviderConfig);
    await settings.loadAccount(workspace.account.key);
    await settings.setAutonomySettings(
      workspace.account.key,
      ceiling: level,
      // The conversation grant is only ever a conversation's own choice.
      startingLevel: level == AiAutonomyLevel.conversationGrant
          ? AiAutonomyLevel.lowRiskAuto
          : level,
    );
    await settings.grantConsent(
      workspace.account.key,
      settings.consentContractFor(
        workspace.account.key,
        config,
        writePolicy: aiMr6b1WritePolicy(
          level,
          releasePolicy: fixtureReleasePolicy,
        ),
        agreedCeiling: level,
        releasePolicy: fixtureReleasePolicy,
      ),
      const {'synthetic': true},
    );

    final root = Directory.systemTemp.createTempSync('fx-coord-stack-');
    final journalKeys = MemoryAiJournalKeyStore();
    final journal = AiWriteJournal(
      keys: journalKeys,
      applicationSupport: root,
      processId: 'fx-coord-stack-test',
    );
    await journal.recoverAfterAccountsLoaded([workspace.account.key]);
    await journal.ensureInitialized(workspace.account.key);

    final provider = StackProvider();
    final picker = FakePicker(picks);
    final harness = StackHarness._(
      root,
      server,
      provider,
      session,
      settings,
      journal,
      journalKeys,
      picker,
    );
    harness.controller = AiChatController(
      releasePolicy: fixtureReleasePolicy,
      origin:
          origin ??
          AiFileOrigin(
            project: workspace.project,
            path: 'README.md',
            sha: WorkspaceFixture.sha,
          ),
      session: session,
      settings: settings,
      runningCount: () => 0,
      appInForeground: () => harness.foreground,
      clientMayStart: () => true,
      writeJournal: journal,
      attachmentPicker: picker,
      now: now,
      refreshSecrets: refreshSecrets,
      writeScope: writeScope == null ? null : () => writeScope(server),
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
                  adapter: provider.adapter,
                ),
                wire: const ResponsesFormat(),
                config: config,
                conversationId: conversationId,
                appVersion: 'test',
              ),
    );
    await harness.controller.recheck();
    expect(
      harness.controller.canSend,
      isTrue,
      reason:
          '${harness.controller.blocker} ${harness.controller.failure} '
          '${server.adapter.requests.map((r) => '${r.method} ${r.uri.path}').toList()}',
    );
    if (level == AiAutonomyLevel.conversationGrant) {
      await harness.controller.setAutonomyLevel(level);
      expect(harness.controller.autonomyLevel, level);
    }
    return harness;
  }

  bool foreground = true;

  /// Sends [text]; when the run waits for approval, approves the waiting
  /// proposal (with [typedName] when it asks for one) and returns its
  /// outcome. Null when nothing waited.
  Future<AiWriteOutcome?> sendAndApprove(
    String text, {
    String? typedName,
  }) async {
    final sending = controller.send(text);
    AiWriteOutcome? outcome;
    for (var i = 0; i < 500; i++) {
      if (controller.phase == AiChatPhase.awaitingApproval &&
          controller.proposals.isNotEmpty) {
        final proposal = controller.proposals.first;
        outcome = await controller.approveWrite(
          proposal,
          typedName: typedName ?? proposal.tier.typedName,
        );
        break;
      }
      if (controller.phase == AiChatPhase.idle) break;
      await Future<void>.delayed(Duration.zero);
    }
    await sending;
    return outcome;
  }

  void dispose() {
    controller.dispose();
    settings.dispose();
    session.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

const stackProviderConfig = AiProviderConfig(
  id: 'fx-coord-provider',
  name: 'fx-coord provider',
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

var _callCounter = 0;

/// One provider turn that calls [name]; [calls] adds more calls to the
/// same batch.
String toolTurn(
  String name,
  Map<String, Object?> arguments, {
  List<(String, Map<String, Object?>)> calls = const [],
}) => _event({
  'type': 'response.completed',
  'response': {
    'output': [
      for (final (callName, callArguments) in [(name, arguments), ...calls])
        {
          'type': 'function_call',
          'call_id': 'fx-call-${++_callCounter}',
          'name': callName,
          'arguments': jsonEncode(callArguments),
          'status': 'completed',
        },
    ],
  },
});

final answerTurn = _event({
  'type': 'response.completed',
  'response': {
    'output': [
      {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': 'Done'},
        ],
      },
    ],
  },
});

ResponseBody _sse(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

String _event(Object value) => 'data: ${jsonEncode(value)}\n\n';

Future<void> waitFor(bool Function() condition) async {
  // Bounded by time, not by turns: under CI load the journal's file work can
  // need more turns than a fixed count allows.
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'the run did not reach the checkpoint');
}
