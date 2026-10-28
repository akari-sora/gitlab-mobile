import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import 'ai/fx_coord_support.dart';
import 'ai/release_policy_support.dart';
import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';

const _pastedSecret = '9876543210fedcba9876543210fedcba';
const _pastedUpload =
    'https://example.com/gitlab/studio/mobile-workspace/'
    'uploads/$_pastedSecret/pasted.png';
const _issueUpload = '/uploads/$uploadSecret/screen.png';

void main() {
  test(
    'changed refresh retains placeholder safety state and expansion',
    () async {
      final harness = await _RefreshHarness.create();
      addTearDown(harness.dispose);

      harness.provider.script.add(
        (_) => toolTurn('get_issue', const {'iid': 5}),
      );
      await harness.controller.send(
        'Inspect issue 5 and remember the pasted image $_pastedUpload',
      );

      final initialToolResult = harness.provider.bodies.last;
      final placeholders = _placeholderIds(initialToolResult);
      expect(placeholders, hasLength(1), reason: initialToolResult);
      final placeholder = placeholders.single;
      expect(initialToolResult, contains('[[upload:u-$placeholder]]'));
      expect(initialToolResult, isNot(contains(uploadSecret)));
      expect(initialToolResult, isNot(contains(_pastedSecret)));
      expect(harness.server.mutations, isEmpty);

      harness.server.workspace.issues[5]!['description'] =
          '![shot]($_issueUpload)\n${List.filled(7000, 'cut ').join()}';
      harness.now = harness.now.add(const Duration(seconds: 61));
      harness.provider.script.add(
        (_) => toolTurn('get_issue', const {'iid': 5}),
      );
      await harness.controller.send('Reread the oversized issue 5');

      expect(_segmentSummaryCount(harness.controller), 0);
      harness.server.workspace.issues[3]!['title'] =
          'changed delivered page title';
      harness.now = harness.now.add(const Duration(seconds: 61));
      await harness.controller.send('Continue after the page changed');

      expect(
        harness.provider.bodies.last,
        contains('changed delivered page title'),
      );
      expect(_segmentSummaryCount(harness.controller), 1);

      harness.provider.script.add(
        (_) => toolTurn('updateIssue', {
          'projectId': 42,
          'iid': 5,
          'fields': {'description': 'Keep ![shot]([[upload:u-$placeholder]])'},
          'reason': 'Keep the existing screenshot.',
        }),
      );
      await _sendAndRejectUnexpectedProposal(
        harness.controller,
        'Rewrite the cut description',
      );
      expect(harness.controller.proposals, isEmpty);
      expect(
        harness.provider.bodies.last,
        contains(AiTextBlockCode.fieldTooLong),
      );

      harness.provider.script.add(
        (_) => toolTurn('createNote', const {
          'projectId': 42,
          'resource': 'issues',
          'iid': 5,
          'body': 'Repost $_pastedUpload',
          'reason': 'Post the image supplied by the user.',
        }),
      );
      await _sendAndRejectUnexpectedProposal(
        harness.controller,
        'Post the pasted image',
      );
      expect(harness.controller.proposals, isEmpty);
      expect(
        harness.provider.bodies.last,
        contains(AiTextBlockCode.pasteOnScreen),
      );

      harness.server.workspace.issues[5]!['description'] =
          'Short description with ![shot]($_issueUpload)';
      harness.now = harness.now.add(const Duration(seconds: 61));
      harness.provider.script.add(
        (_) => toolTurn('get_issue', const {'iid': 5}),
      );
      await harness.controller.send('Reread all of issue 5');
      expect(_placeholderIds(harness.provider.bodies.last).toSet(), {
        placeholder,
      });

      harness.provider.script.add(
        (_) => toolTurn('updateIssue', {
          'projectId': 42,
          'iid': 5,
          'fields': {
            'description': 'Restored ![shot]([[upload:u-$placeholder]])',
          },
          'reason': 'Keep the verified existing screenshot.',
        }),
      );
      final proposing = harness.controller.send(
        'Rewrite the complete description',
      );
      await waitFor(() => harness.controller.proposals.isNotEmpty);
      final proposal = harness.controller.proposals.single;
      expect(proposal.fields['description'], contains('[REDACTED]'));
      expect(proposal.fields['description'], isNot(contains('[[upload:u-')));
      expect(harness.server.mutations, isEmpty);
      await harness.controller.rejectWrite(proposal);
      await proposing;

      expect(harness.server.mutations, isEmpty);
      expect(_segmentSummaryCount(harness.controller), 1);
    },
  );
}

List<int> _placeholderIds(String body) => [
  for (final match in RegExp(r'\[\[upload:u-([0-9]+)\]\]').allMatches(body))
    int.parse(match.group(1)!),
];

int _segmentSummaryCount(AiChatController controller) => controller.items
    .whereType<AiNoticeItem>()
    .where((item) => item.kind == AiNoticeKind.segmentSummary)
    .length;

Future<void> _sendAndRejectUnexpectedProposal(
  AiChatController controller,
  String text,
) async {
  final sending = controller.send(text);
  await waitFor(
    () =>
        controller.phase == AiChatPhase.idle || controller.proposals.isNotEmpty,
  );
  if (controller.proposals.isNotEmpty) {
    await controller.rejectWrite(controller.proposals.single);
  }
  await sending;
}

final class _RefreshHarness {
  _RefreshHarness._(
    this.root,
    this.server,
    this.provider,
    this.api,
    this.session,
    this.settings,
    this.journal,
    this.clock,
  );

  final Directory root;
  final StackServer server;
  final StackProvider provider;
  final GitLabApi api;
  final SessionController session;
  final AiSettingsController settings;
  final AiWriteJournal journal;
  final _Clock clock;
  late final AiChatController controller;
  DateTime get now => clock.now;
  set now(DateTime value) => clock.now = value;

  static Future<_RefreshHarness> create() async {
    final server = StackServer();
    server.workspace.issues[3] = server.workspace.issue(
      3,
      'initial delivered page title',
    );
    server.workspace.issues[5] = {
      ...server.workspace.issue(5, 'Synthetic five'),
      'description': 'Short description with ![shot]($_issueUpload)',
    };
    server.overrides['GET projects/42/issues/3/notes'] = (_) =>
        jsonResponse(<Object?>[]);

    final clock = _Clock();
    final api = GitLabApi(
      instance: server.workspace.account.instance,
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = server.adapter,
      readCacheClock: () => clock.now,
    );
    final accounts = MemoryAccountStore()
      ..accounts = [server.workspace.account]
      ..lastActive = server.workspace.account.key;
    final session = SessionController(
      accounts,
      readCache: accounts.readCache,
      createApi: (instance, credential, oauth, onOAuthRotated) => api,
    );
    await session.initialize();

    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final config = await settings.saveProvider(stackProviderConfig);
    await settings.loadAccount(server.workspace.account.key);
    await settings.setAutonomySettings(
      server.workspace.account.key,
      ceiling: AiAutonomyLevel.confirmEach,
      startingLevel: AiAutonomyLevel.confirmEach,
    );
    await settings.grantConsent(
      server.workspace.account.key,
      settings.consentContractFor(
        server.workspace.account.key,
        config,
        writePolicy: aiMr6b1WritePolicy(
          AiAutonomyLevel.confirmEach,
          releasePolicy: fixtureReleasePolicy,
        ),
        agreedCeiling: AiAutonomyLevel.confirmEach,
        releasePolicy: fixtureReleasePolicy,
      ),
      const {'synthetic': true},
    );

    final root = Directory.systemTemp.createTempSync('refresh-state-test-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'refresh-state-test',
    );
    await journal.recoverAfterAccountsLoaded([server.workspace.account.key]);
    await journal.ensureInitialized(server.workspace.account.key);

    final provider = StackProvider();
    final harness = _RefreshHarness._(
      root,
      server,
      provider,
      api,
      session,
      settings,
      journal,
      clock,
    );
    harness.controller = AiChatController(
      releasePolicy: fixtureReleasePolicy,
      origin: AiWorkItemOrigin(
        project: server.workspace.project,
        kind: AiWorkItemKind.issue,
        iid: 3,
        title: 'initial delivered page title',
      ),
      session: session,
      settings: settings,
      runningCount: () => 0,
      now: () => clock.now,
      appInForeground: () => true,
      clientMayStart: () => true,
      writeJournal: journal,
      writeScope: () => AiWriteScope(
        accountKey: server.workspace.account.key,
        grants: const [
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: 42,
            projectPath: 'studio/mobile-workspace',
          ),
        ],
      ),
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
    expect(harness.controller.canSend, isTrue);
    return harness;
  }

  void dispose() {
    controller.dispose();
    settings.dispose();
    session.dispose();
    api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _Clock {
  DateTime now = DateTime.utc(2026, 10, 23, 12);
}
