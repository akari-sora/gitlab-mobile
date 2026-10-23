// Issue #12 follow-ups (tests only): production-factory end-to-end (r2 m3),
// unknown-outcome kept card, and the r2 m1 cut regression.
//
// Plan v6 §3.1: a whole-field write of a field the provider saw only cut is
// refused with `fieldTooLong`, whether the cut was by a read tool, the page
// context or the runner's own clipping. The latest delivery wins: a later
// whole copy lifts the mark.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart' show buildAiProjectionData;
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_account_cleanup.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_ui.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/main.dart'
    show recoverAiWriteJournalAfterAccountsLoaded;
import 'package:gitlab_mobile/shared/theme.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';
import 'fx_coord_support.dart'
    show CoordHarness, coordNoteCall, stackProviderConfig, waitFor;

final class _NoFence implements AiJournalAccountFence {
  @override
  bool isCleaning(String accountKey) => false;

  @override
  Future<T> run<T>(String accountKey, Future<T> Function() action) => action();
}

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: child,
    ),
  ),
);

ResponseBody _sse(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

String _event(Object value) => 'data: ${jsonEncode(value)}\n\n';

String _toolEvent(String name, Map<String, Object?> arguments) => _event({
  'type': 'response.completed',
  'response': {
    'output': [
      {
        'type': 'function_call',
        'call_id': 'issue12-${DateTime.now().microsecondsSinceEpoch}',
        'name': name,
        'arguments': jsonEncode(arguments),
        'status': 'completed',
      },
    ],
  },
});

final _answerEvent = _event({
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

void main() {
  test(
    'issue12 r2 m3 production factory approved write performs one mutation',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final fixture = WorkspaceFixture();
      final accounts = MemoryAccountStore()
        ..accounts = [fixture.account]
        ..lastActive = fixture.account.key;
      final session = controllerFor(accounts, fixture.adapter);
      await session.initialize();
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      final config = await settings.saveProvider(stackProviderConfig);
      await settings.loadAccount(fixture.account.key);
      await settings.setAutonomySettings(
        fixture.account.key,
        ceiling: AiAutonomyLevel.confirmEach,
        startingLevel: AiAutonomyLevel.confirmEach,
      );
      await settings.grantConsent(
        fixture.account.key,
        settings.consentContractFor(
          fixture.account.key,
          config,
          writePolicy: aiMr6b1WritePolicy(AiAutonomyLevel.confirmEach),
          agreedCeiling: AiAutonomyLevel.confirmEach,
        ),
        const {'synthetic': true},
      );

      final root = Directory.systemTemp.createTempSync('issue12-prod-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      wireAiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root,
        fence: _NoFence(),
      );
      await recoverAiWriteJournalAfterAccountsLoaded(
        session,
        AiWriteJournal.instance,
      );
      await AiWriteJournal.instance.ensureInitialized(fixture.account.key);

      final bodies = <String>[];
      final script = <String Function(String body)>[];
      final providerAdapter = FakeAdapter((request) {
        final data = request.data;
        final body = data is String ? data : jsonEncode(data);
        bodies.add(body);
        final next = script.isEmpty ? (_) => _answerEvent : script.removeAt(0);
        return _sse(next(body));
      });
      final registry = AccountAiRunRegistry(
        session: session,
        settings: settings,
        wireClientFactory:
            ({
              required AiProviderConfig config,
              required String? apiKey,
              required String conversationId,
            }) => AiWireClient(
              transport: AiTransport(
                endpoint: AiEndpoint.parse(
                  config.baseUrl,
                  allowLanCleartext: false,
                ),
                apiKey: apiKey ?? '',
                authStyle: config.authStyle,
                adapter: providerAdapter,
              ),
              wire: const ResponsesFormat(),
              config: config,
              conversationId: conversationId,
              appVersion: 'test',
            ),
      );
      addTearDown(registry.dispose);
      addTearDown(session.dispose);
      addTearDown(settings.dispose);
      addTearDown(fixture.api.close);

      // The production factory supplies the real foreground and client gates;
      // nothing is injected for them.
      final controller =
          registry.open(
                AiFileOrigin(
                  project: fixture.project,
                  path: 'README.md',
                  sha: WorkspaceFixture.sha,
                ),
              )
              as AiChatController;
      expect(controller.writeGatesOpen, isTrue);
      await controller.recheck();
      expect(
        controller.canSend,
        isTrue,
        reason: '${controller.blocker} ${controller.failure}',
      );

      script.add(
        (_) => _toolEvent('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic bug via production factory'},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = controller.send('Create an issue for the bug');
      await waitFor(() => controller.proposals.isNotEmpty);
      final proposal = controller.proposals.single;
      expect(proposal.operationId, 'createIssue');
      final outcome = await controller.approveWrite(proposal);
      await sending;
      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      final mutations = fixture.adapter.requests
          .where((r) => r.method != 'GET' && r.method != 'HEAD')
          .toList();
      expect(mutations, hasLength(1));
      expect(mutations.single.method, 'POST');
      expect(mutations.single.uri.path, endsWith('/projects/42/issues'));
    },
  );

  testWidgets('issue12 unknown-outcome kept card keeps its own sentence', (
    tester,
  ) async {
    late CoordHarness h;
    late AiWriteProposal kept;
    await tester.runAsync(() async {
      h = await CoordHarness.create();
      h.newRun('Comment on #3 in team/example-9');
      final proposal = (await h.coordinator.propose(coordNoteCall('unknown')))!;
      final edit = await h.coordinator.approve(
        proposal,
        editedText: 'my own words for unknown',
      );
      expect(edit.reasonCode, 'approvalRequired');
      h.failWritesWith = 500;
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(h.coordinator.settledEdits, [proposal]);
      kept = h.coordinator.settledEdits.single;
    });
    addTearDown(() => tester.runAsync(h.dispose));
    expect(kept.outcome?.state, AiJournalState.writeUncertain);
    await tester.pumpWidget(
      _host(AiSettledEditCard(proposal: kept, onDismiss: () {})),
    );
    expect(find.text('my own words for unknown'), findsOneWidget);
    expect(find.textContaining(l10n.aiWriteStatusUncertain), findsOneWidget);
    expect(find.text(l10n.aiSettledEditUncertain), findsOneWidget);
    expect(find.text(l10n.aiSettledEditKept), findsNothing);
    expect(find.textContaining(l10n.aiWriteStatusNotExecuted), findsNothing);
  });

  group('issue12 r2 m1 summary cut then read', () {
    const root = 'https://gitlab.example.com';
    AiFieldProvenance issueField() => AiFieldProvenance.gitLab(
      instance: GitLabInstance.parse(root),
      projectId: 42,
      projectPath: 'group/project',
      resource: 'issues',
      iid: 3,
    );

    UploadPlaceholderTable table() =>
        UploadPlaceholderTable(instance: GitLabInstance.parse(root));

    AiTextOutcome prepare(
      UploadPlaceholderTable placeholders,
      AiFieldProvenance field,
    ) => prepareWriteText(
      textClass: AiTextClass.quickActionMarkdown,
      modelText: 'Rewritten description',
      field: field,
      placeholders: placeholders,
      knownSecrets: const <String>{},
      aiAttribution: false,
      visibility: const AiVisibilityContext(targetProjectPath: 'group/project'),
    );

    Future<AiChatContext> loadIssue(String description) {
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/issues/3/notes')) {
          return jsonResponse(<Object?>[]);
        }
        if (path.endsWith('/projects/42/issues/3')) {
          return jsonResponse({
            'title': 'Issue title',
            'description': description,
            'state': 'opened',
            'labels': <Object?>[],
          });
        }
        if (path.endsWith('/projects/42')) {
          return jsonResponse({
            'id': 42,
            'name': 'Synthetic',
            'path_with_namespace': 'group/project',
          });
        }
        return jsonResponse({'error': 'not found'}, status: 404);
      });
      return loadAiChatContext(
        origin: const AiWorkItemOrigin(
          project: Project(id: 42, name: 'Synthetic', path: 'group/project'),
          kind: AiWorkItemKind.issue,
          iid: 3,
          title: 'Issue title',
        ),
        api: testApi(adapter),
        redactor: Redactor(secrets: const _Secrets()),
        accountKey: 'https://example.com/gitlab#7',
        refreshSecrets: () async {},
        isCurrent: () => true,
      );
    }

    AiToolCatalogue catalogue(
      _Port port,
      UploadPlaceholderTable placeholders,
    ) => AiToolCatalogue(
      port: port,
      scope: const AiResourceScope(
        accountKey: '$root#7',
        instanceKey: root,
        projectId: 42,
        projectPath: 'group/project',
        current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
        headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        baseSha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      redactor: Redactor(secrets: const _Secrets()),
      placeholders: placeholders,
    );

    test(
      'a new segment summary cut blocks updateIssue until get_issue reads whole',
      () async {
        final placeholders = table();
        final context = await loadIssue('Line of the description. ' * 200);
        final field = context.field!;
        expect(field.provenance.sameField(issueField()), isTrue);

        // The first segment delivers the page context whole.
        context.recordDelivery(placeholders, context.built.blocks);
        expect(placeholders.seenOnlyCut(field.provenance), isFalse);
        expect(prepare(placeholders, field.provenance).policyBlocked, isFalse);

        // A new segment carries only a summary cut from that context.
        final summary = buildAiProjectionData(
          context: context.built.blocks,
          entries: const [],
          budget: 2000,
          redact: (value) => value,
        );
        context.recordDelivery(placeholders, [
          AiContextBlock.fromData(
            source: 'conversation_summary',
            data: summary,
          ),
        ]);
        expect(placeholders.seenOnlyCut(field.provenance), isTrue);
        expect(
          prepare(placeholders, field.provenance).blockedReasonCode,
          AiTextBlockCode.fieldTooLong,
        );

        // The same run reads the issue whole, which lifts the cut, so the
        // whole-field write is offered again. Plan v6 §3.1 refuses only the
        // field the provider saw cut; the latest whole delivery wins.
        final port = _Port(description: 'Line of the description. ' * 200);
        final execution = await catalogue(port, placeholders).execute(
          AiToolCall(id: 'call-1', name: 'get_issue', arguments: {'iid': 3}),
          budget: AiToolBudget(),
        );
        expect(execution.truncated, isFalse);
        expect(placeholders.seenOnlyCut(field.provenance), isFalse);
        expect(prepare(placeholders, field.provenance).policyBlocked, isFalse);
      },
    );
  });
}

final class _Secrets implements KnownSecretsSource {
  const _Secrets();

  @override
  Iterable<String> get current => const <String>[];
}

final class _Port implements AiGitLabReadPort {
  _Port({required this.description});

  final String description;

  AiJson get _discussion => {
    'iid': 3,
    'title': 'Issue title',
    'description': description,
    'state': 'opened',
    'notes': const <AiJson>[],
  };

  @override
  Future<AiPortRead<AiJson>> issue(int iid) async =>
      AiPortRead(_discussion, requestCount: 2);

  @override
  Future<AiPortRead<AiJson>> mergeRequest(int iid) async =>
      AiPortRead(_discussion, requestCount: 2);

  @override
  Future<AiPortRead<AiJson>> commit(String sha) => throw UnimplementedError();

  @override
  Future<AiPortRead<String>> jobLog(int jobId) => throw UnimplementedError();

  @override
  Future<AiPortRead<List<AiJson>>> commitDiff(String sha) =>
      throw UnimplementedError();

  @override
  Future<AiPortRead<List<AiTreeItem>>> listDirectory(String sha, String path) =>
      throw UnimplementedError();

  @override
  Future<AiPortRead<AiJson>> mergeRequestDiff(
    int iid, {
    required String headSha,
    required String baseSha,
  }) => throw UnimplementedError();

  @override
  Future<AiPortRead<List<AiJson>>> pipelineJobs(int pipelineId) =>
      throw UnimplementedError();

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) =>
      throw UnimplementedError();

  @override
  Future<AiPortRead<List<AiJson>>> search(String scope, String query) =>
      throw UnimplementedError();
}
