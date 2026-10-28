// Issue #12 follow-ups (tests only): production-factory end-to-end (r2 m3),
// unknown-outcome kept card, and the r2 m1 cut regression.
//
// Plan v6 §3.1: a summary cut refuses a whole-field write with `fieldTooLong`.
// A later whole read in the same run lifts that mark (ledger rounds 2/3 m1).

import 'release_policy_support.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
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
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
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
    show
        CoordHarness,
        StackHarness,
        StackProvider,
        answerTurn,
        coordNoteCall,
        stackProviderConfig,
        toolTurn,
        waitFor;

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

void main() {
  test(
    'issue12 r2 m3 approved write performs one mutation with production gates',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final accounts = MemoryAccountStore()
        ..accounts = [fixture.account]
        ..lastActive = fixture.account.key;
      final session = controllerFor(accounts, fixture.adapter);
      addTearDown(session.dispose);
      await session.initialize();
      final settings = AiSettingsController(MemoryAiStore());
      addTearDown(settings.dispose);
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
          releasePolicy: fixtureReleasePolicy,
          writePolicy: aiMr6b1WritePolicy(AiAutonomyLevel.confirmEach, releasePolicy: fixtureReleasePolicy),
          agreedCeiling: AiAutonomyLevel.confirmEach,
        ),
        const {'synthetic': true},
      );

      final root = Directory.systemTemp.createTempSync('issue12-prod-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      // This process singleton is configured once in this file. Other tests
      // use private journals; this directory goes away after the registry.
      wireAiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root,
        fence: _NoFence(),
      );
      await recoverAiWriteJournalAfterAccountsLoaded(
        session,
        AiWriteJournal.instance,
      );
      expect(
        await AiWriteJournal.instance.keyStatus(fixture.account.key),
        AiJournalKeyStatus.uninitialized,
      );
      // Leave the new account uninitialized: its first write must initialize
      // the journal through the production reserve path.
      final provider = StackProvider();
      final activity = AiAccountActivity();
      final registry = AccountAiRunRegistry(
        session: session,
        settings: settings,
        sessionFactory: activity.track(({
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
            wireClientFactory: wireClientFactory,
            appInForeground: aiAppInForeground,
            clientMayStart: aiClientMayStart(session),
            releasePolicy: fixtureReleasePolicy,
          );
          return (
            session: controller,
            capacityChanged: controller.notifyCapacityChanged,
            dispose: controller.dispose,
          );
        }),
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
                adapter: provider.adapter,
              ),
              wire: const ResponsesFormat(),
              config: config,
              conversationId: conversationId,
              appVersion: 'test',
            ),
      );
      activity.attach(registry);
      addTearDown(registry.dispose);

      // Use the app's foreground and client gates with the synthetic policy.
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

      provider.script.add(
        (_) => toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic bug via production factory'},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = controller.send('Create an issue for the bug');
      await waitFor(() => controller.proposals.isNotEmpty);
      final proposal = controller.proposals.single;
      expect(proposal.operationId, 'createIssue');
      expect(activity.runningOrPending, 1);
      expect(
        fixture.adapter.requests.where(
          (r) => r.method != 'GET' && r.method != 'HEAD',
        ),
        isEmpty,
      );
      final outcome = await controller.approveWrite(proposal);
      await sending;
      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(
        await AiWriteJournal.instance.keyStatus(fixture.account.key),
        AiJournalKeyStatus.found,
      );
      final mutations = fixture.adapter.requests
          .where((r) => r.method != 'GET' && r.method != 'HEAD')
          .toList();
      expect(mutations, hasLength(1));
      expect(mutations.single.method, 'POST');
      expect(mutations.single.uri.path, endsWith('/projects/42/issues'));
      expect(
        (mutations.single.data as Map)['title'],
        'Synthetic bug via production factory',
      );
      expect(provider.script, isEmpty);
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

  test(
    'issue12 r2 m1 summary cut permits updateIssue after get_issue in the same run',
    () async {
      final description =
          'Description start. ${'A line of the description. ' * 200} Description end.';
      const rewritten = 'Rewritten description after the complete read.';
      final h = await StackHarness.create(
        origin: const AiWorkItemOrigin(
          project: Project(
            id: 42,
            name: 'Mobile Workspace',
            path: 'studio/mobile-workspace',
          ),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Synthetic five',
        ),
        level: AiAutonomyLevel.confirmEach,
        configure: (server) =>
            server.workspace.issues[5]!['description'] = description,
      );
      addTearDown(h.dispose);
      final config = await h.settings.saveProvider(
        AiProviderConfig(
          id: stackProviderConfig.id,
          name: stackProviderConfig.name,
          presetId: stackProviderConfig.presetId,
          baseUrl: stackProviderConfig.baseUrl,
          format: stackProviderConfig.format,
          model: stackProviderConfig.model,
          authStyle: stackProviderConfig.authStyle,
          caps: const AiCaps(
            tokenLimitField: AiTokenLimitField.maxOutputTokens,
            toolChoice: true,
            maxRequestChars: 180000,
          ),
          allowLanCleartext: false,
          toolsEnabled: true,
          recipientRevision: 1,
        ),
      );
      await h.settings.saveProviderKey(config.id, 'synthetic-issue12-key-0001');
      await h.controller.recheck();
      expect(h.controller.canSend, isTrue, reason: '${h.controller.blocker}');
      await h.controller.send('Discuss issue #5');
      expect(h.controller.failure, isNull);
      final firstChip = h.controller.items
          .whereType<AiUserItem>()
          .single
          .chips
          .single;
      expect(firstChip.source, 'issue #5');
      expect(firstChip.sentText, contains(description));
      expect(h.server.mutations, isEmpty);

      // Key replacement keeps the conversation and makes its next send start
      // a projected segment. Leave about 13k for the summary: its share cuts
      // the 5k description, while the later complete tool read still fits.
      await h.settings.saveProviderKey(config.id, 'synthetic-issue12-key-0002');
      await h.controller.recheck();
      final envelope =
          jsonDecode(h.provider.bodies.single) as Map<String, dynamic>;
      envelope['input'] = <Object?>[];
      final padding =
          config.caps.maxRequestChars - jsonEncode(envelope).length - 14000;
      expect(padding, isPositive);
      final request =
          'Update issue #5 description after reading it. ${'Context. ' * (padding ~/ 9)}';
      final update = <String, Object?>{
        'projectId': 42,
        'iid': 5,
        'fields': {'description': rewritten},
        'reason': 'The user asked to update issue #5.',
      };
      h.provider.script.addAll([
        (body) {
          expect(body, contains('conversation_summary'));
          expect(body, contains('Description start.'));
          expect(body, isNot(contains('Description end.')));
          return toolTurn('updateIssue', update);
        },
        (body) {
          final input =
              (jsonDecode(body) as Map<String, dynamic>)['input'] as List;
          final output = input.whereType<Map<String, dynamic>>().lastWhere(
            (entry) => entry['type'] == 'function_call_output',
          );
          expect(output['output'], contains('fieldTooLong'));
          expect(h.server.mutations, isEmpty);
          return toolTurn('get_issue', {'iid': 5});
        },
        (body) {
          final input =
              (jsonDecode(body) as Map<String, dynamic>)['input'] as List;
          final output = input.whereType<Map<String, dynamic>>().lastWhere(
            (entry) => entry['type'] == 'function_call_output',
          );
          expect(output['output'], contains(description));
          return toolTurn('updateIssue', update);
        },
        (_) => answerTurn,
      ]);
      final sending = h.controller.send(request);
      await waitFor(
        () =>
            h.controller.proposals.isNotEmpty ||
            h.controller.phase == AiChatPhase.idle,
      );
      expect(
        h.controller.proposals,
        hasLength(1),
        reason:
            'A complete get_issue must lift the summary cut before updateIssue: ${h.controller.failure}',
      );
      final proposal = h.controller.proposals.single;
      expect(proposal.operationId, 'updateIssue');
      expect(h.server.mutations, isEmpty);
      final outcome = await h.controller.approveWrite(proposal);
      await sending;
      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(h.controller.failure, isNull);
      expect(h.provider.script, isEmpty);
      final summaryChip = h.controller.items
          .whereType<AiUserItem>()
          .last
          .chips
          .single;
      expect(summaryChip.source, 'conversation_summary');
      expect(summaryChip.sentText, isNot(contains('Description end.')));
      expect(
        h.controller.items.whereType<AiToolRunItem>().map((item) => item.name),
        ['updateIssue', 'get_issue', 'updateIssue'],
      );
      expect(h.server.mutations, hasLength(1));
      final put = h.server.mutations.single;
      expect(put.method, 'PUT');
      expect(put.uri.path, endsWith('/projects/42/issues/5'));
      expect((put.data as Map)['description'], rewritten);
      expect(h.server.workspace.issues[5]!['description'], rewritten);
    },
  );

  group('issue12 page and tool description provenance', () {
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
      final api = testApi(adapter, host: root);
      addTearDown(api.close);
      return loadAiChatContext(
        origin: const AiWorkItemOrigin(
          project: Project(id: 42, name: 'Synthetic', path: 'group/project'),
          kind: AiWorkItemKind.issue,
          iid: 3,
          title: 'Issue title',
        ),
        api: api,
        redactor: Redactor(secrets: const _Secrets()),
        accountKey: '$root#7',
        refreshSecrets: () async {},
        isCurrent: () => true,
      );
    }

    AiToolCatalogue catalogue(
      _Port port,
      UploadPlaceholderTable placeholders,
    ) => AiToolCatalogue(
      releasePolicy: fixtureReleasePolicy,
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
      'page context cuts and whole tool reads share the description provenance key',
      () async {
        final placeholders = table();
        final context = await loadIssue('Line of the description. ' * 200);
        final field = context.field!;
        expect(field.provenance.sameField(issueField()), isTrue);

        // Record the complete page context under its description field key.
        context.recordDelivery(placeholders, context.built.blocks);
        expect(placeholders.seenOnlyCut(field.provenance), isFalse);
        expect(prepare(placeholders, field.provenance).policyBlocked, isFalse);

        // A clipped projection marks that same field key as cut.
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

        // A whole read-tool result shares the page field's key and clears
        // its cut mark. Controller sequencing is covered by the test above.
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
