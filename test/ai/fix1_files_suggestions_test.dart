import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';
import 'fx_coord_support.dart';
import 'mr6b2_support.dart';
import 'p6_support.dart';

const _timeout = Duration(seconds: 20);

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(_timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('file production-controller checkpoint timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final class _OAuthReplayServer {
  final workspace = WorkspaceFixture();
  final String branchHead = WorkspaceFixture.sha;
  late final adapter = FakeAdapter(_respond);
  var content = '# Mobile Workspace\n\nOld sentence.\n';
  var replayReads = false;
  var _rejectNextRead = true;
  var mutations = 0;

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    if (replayReads && (request.method == 'GET' || request.method == 'HEAD')) {
      if (_rejectNextRead) {
        _rejectNextRead = false;
        return jsonResponse({'message': 'expired'}, status: 401);
      }
      _rejectNextRead = true;
    }
    final segments = request.uri.pathSegments;
    final start = segments.indexOf('v4');
    final path = start < 0 ? '' : segments.skip(start + 1).join('/');
    if (path == 'projects/42' && request.method == 'GET') {
      return jsonResponse({...workspace.projectRecord, 'ci_config_path': null});
    }
    if (path == 'projects/42/repository/branches/main') {
      return jsonResponse({
        'name': 'main',
        'protected': true,
        'default': true,
        'commit': {'id': branchHead},
      });
    }
    if (path == 'projects/42/repository/files/README.md' &&
        request.method == 'HEAD') {
      return ResponseBody.fromString('', 200, headers: {
        'cache-control': ['no-store'],
        'x-gitlab-size': ['${content.length}'],
        'x-gitlab-last-commit-id': [WorkspaceFixture.sha],
      });
    }
    if (path == 'projects/42/repository/files/README.md/raw') {
      return ResponseBody.fromString(content, 200, headers: {
        'cache-control': ['no-store'],
      });
    }
    if (path == 'projects/42/repository/files/README.md' &&
        request.method == 'PUT') {
      mutations++;
      final body = request.data! as Map<String, dynamic>;
      content = body['content']! as String;
      return jsonResponse({'file_path': 'README.md'});
    }
    return workspace.respond(request);
  }
}

final class _OAuthHarness {
  _OAuthHarness._(
    this.root,
    this.server,
    this.oauthAdapter,
    this.provider,
    this.session,
    this.settings,
    this.journal,
    this.controller,
  );

  final Directory root;
  final _OAuthReplayServer server;
  final FakeAdapter oauthAdapter;
  final StackProvider provider;
  final SessionController session;
  final AiSettingsController settings;
  final AiWriteJournal journal;
  final AiChatController controller;

  static Future<_OAuthHarness> create() async {
    final server = _OAuthReplayServer();
    final instance = server.workspace.api.instance;
    final account = Account(
      instance: instance,
      user: server.workspace.account.user,
      credential: const OAuthCredential(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        clientId: 'synthetic-app-id',
      ),
    );
    final accounts = MemoryAccountStore()
      ..accounts = [account]
      ..lastActive = account.key;
    var refreshes = 0;
    final oauthAdapter = FakeAdapter((_) {
      refreshes++;
      return jsonResponse({
        'access_token': 'rotated-access-$refreshes',
        'refresh_token': 'rotated-refresh-$refreshes',
        'token_type': 'bearer',
        'expires_in': 7200,
      });
    });
    final session = controllerFor(
      accounts,
      server.adapter,
      createOAuth: (oauthInstance, clientId) => OAuthTokenClient(
        instance: oauthInstance,
        clientId: clientId,
        dio: Dio()..httpClientAdapter = oauthAdapter,
      ),
    );
    await session.initialize();

    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final config = await settings.saveProvider(stackProviderConfig);
    await settings.loadAccount(account.key);
    await settings.setAutonomySettings(
      account.key,
      ceiling: AiAutonomyLevel.confirmEach,
      startingLevel: AiAutonomyLevel.confirmEach,
    );
    await settings.grantConsent(
      account.key,
      settings.consentContractFor(
        account.key,
        config,
        writePolicy: aiMr6b1WritePolicy(AiAutonomyLevel.confirmEach),
        agreedCeiling: AiAutonomyLevel.confirmEach,
      ),
      const {'synthetic': true},
    );

    final root = Directory.systemTemp.createTempSync('fix1-oauth-files-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'fix1-oauth-files-test',
    );
    await journal.recoverAfterAccountsLoaded([account.key]);
    await journal.ensureInitialized(account.key);
    final provider = StackProvider();
    late final AiChatController controller;
    controller = AiChatController(
      origin: AiFileOrigin(
        project: server.workspace.project,
        path: 'README.md',
        sha: WorkspaceFixture.sha,
      ),
      session: session,
      settings: settings,
      runningCount: () => 0,
      appInForeground: () => true,
      clientMayStart: () => true,
      writeJournal: journal,
      attachmentPicker: FakePicker(),
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
    await _waitUntil(() => controller.canSend);
    expect(
      controller.canSend,
      isTrue,
      reason:
          '${controller.blocker} ${controller.failure} '
          '${server.adapter.requests.map((r) => '${r.method} ${r.uri.path}').toList()}',
    );
    server.replayReads = true;
    return _OAuthHarness._(
      root,
      server,
      oauthAdapter,
      provider,
      session,
      settings,
      journal,
      controller,
    );
  }

  void dispose() {
    controller.dispose();
    settings.dispose();
    session.dispose();
    server.workspace.api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  test(
    'batch suggestions are outside consent and the production 40-request budget',
    () async {
      final row = productionAiLedger.find('batchApplySuggestions')!;
      expect(row.modelVisible, isFalse);
      expect(row.httpCap, 141);
      expect(
        aiProductionWritePolicy(AiAutonomyLevel.bypass).operationIds,
        isNot(contains('batchApplySuggestions')),
      );

      final h = await Mr6b2Harness.create(maxGitLabRequests: 40);
      addTearDown(h.dispose);
      final before = h.server.adapter.requests.length;
      final proposal = await h.propose('batchApplySuggestions', {
        ...p6Args('batchApplySuggestions'),
        'suggestions': [p6Item(1)],
      }, id: 'batch-production-budget');
      expect(proposal, isNull);
      expect(
        h.coordinator.outcomeFor('batch-production-budget')?.reasonCode,
        'httpBudgetExceeded',
      );
      expect(h.server.adapter.requests, hasLength(before));
      expect(h.server.mutationCount(), 0);
    },
  );

  test(
    'production controller counts both file freshness reads and cold PAT traffic',
    () async {
      var content = '# Mobile Workspace\n\nOld sentence.\n';
      final h = await StackHarness.create(
        level: AiAutonomyLevel.confirmEach,
        configure: (server) {
          server.overrides['GET projects/42'] = (_) => jsonResponse({
            ...server.workspace.projectRecord,
            'ci_config_path': null,
          });
          server.overrides['GET projects/42/repository/branches/main'] = (_) =>
              jsonResponse({
                'name': 'main',
                'protected': true,
                'default': true,
                'commit': {'id': WorkspaceFixture.sha},
              });
          server.overrides['HEAD projects/42/repository/files/README.md'] =
              (_) => ResponseBody.fromString(
                '',
                200,
                headers: {
                  'cache-control': ['no-store'],
                  'x-gitlab-size': ['${content.length}'],
                  'x-gitlab-last-commit-id': [WorkspaceFixture.sha],
                },
              );
          server.overrides['GET projects/42/repository/files/README.md/raw'] =
              (_) => ResponseBody.fromString(
                content,
                200,
                headers: {
                  'cache-control': ['no-store'],
                },
              );
          server.overrides['PUT projects/42/repository/files/README.md'] =
              (request) {
                final body = request.data! as Map<String, dynamic>;
                content = body['content']! as String;
                return jsonResponse({'file_path': 'README.md'});
              };
        },
      );
      addTearDown(h.dispose);
      h.provider.script.add(
        (_) => toolTurn('edit_file', {
          'projectId': 42,
          'branch': 'main',
          'path': 'README.md',
          'commitMessage': 'Update synthetic sentence',
          'edits': [
            {'old': 'Old sentence.', 'new': 'New sentence.'},
          ],
          'reason': 'The user requested this exact edit.',
        }),
      );

      final before = h.server.adapter.requests.length;
      final sending = h.controller.send('Edit `README.md` on `main`.');
      await _waitUntil(
        () =>
            h.controller.proposals.isNotEmpty ||
            h.controller.phase == AiChatPhase.idle,
      );
      expect(
        h.controller.proposals,
        hasLength(1),
        reason:
            '${h.controller.failure} '
            '${h.server.adapter.requests.skip(before).map((r) => '${r.method} ${r.uri.path}').toList()} '
            '${h.controller.items.whereType<AiToolRunItem>().map((r) => '${r.name}:${r.resultExcerpt}').toList()}',
      );
      final proposal = h.controller.proposals.single;
      final outcome = await h.controller.approveWrite(
        proposal,
        typedName: proposal.tier.typedName,
      );
      await sending.timeout(_timeout);

      final requests = h.server.adapter.requests.skip(before).toList();
      expect(outcome.state, AiJournalState.succeeded);
      expect(content, contains('New sentence.'));
      expect(requests, hasLength(18));
      expect(
        requests.where(
          (request) => request.method == 'GET' || request.method == 'HEAD',
        ),
        hasLength(17),
      );
      expect(
        requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );
      expect(
        requests.where(
          (request) =>
              request.method == 'GET' &&
              request.uri.path.endsWith('/projects/42'),
        ),
        hasLength(4),
        reason: 'project freshness and port reads each run twice',
      );
      expect(aiWriteRequestAllowance('edit_file', oauthReplay: false), 18);
      expect(aiWriteRequestAllowance('edit_file'), 35);
    },
  );

  test(
    'production controller records all OAuth replays and reserves 35 of 40',
    () async {
      final h = await _OAuthHarness.create();
      addTearDown(h.dispose);
      const args = <String, Object?>{
        'projectId': 42,
        'branch': 'main',
        'path': 'README.md',
        'commitMessage': 'Update synthetic sentence',
        'edits': [
          {'old': 'Old sentence.', 'new': 'New sentence.'},
        ],
        'reason': 'The user requested this exact edit.',
      };
      h.provider.script.add(
        (_) => toolTurn('edit_file', args, calls: [('edit_file', args)]),
      );

      final beforeGitLab = h.server.adapter.requests.length;
      final beforeRefreshes = h.oauthAdapter.requests.length;
      final sending = h.controller.send('Edit `README.md` on `main`.');
      await _waitUntil(
        () =>
            h.controller.proposals.isNotEmpty ||
            h.controller.phase == AiChatPhase.idle,
      );
      expect(h.controller.proposals, hasLength(1), reason:
          '${h.controller.blocker} ${h.controller.failure} '
          '${h.server.adapter.requests.skip(beforeGitLab).map((r) => '${r.method} ${r.uri.path}').toList()} '
          '${h.controller.items.whereType<AiToolRunItem>().map((r) => '${r.name}:${r.resultExcerpt}').toList()}');
      final proposal = h.controller.proposals.single;
      final outcome = await h.controller.approveWrite(
        proposal,
        typedName: proposal.tier.typedName,
      );
      await sending.timeout(_timeout);

      final requests = h.server.adapter.requests.skip(beforeGitLab).toList();
      final rows = h.controller.items.whereType<AiToolRunItem>()
          .where((item) => item.name == 'edit_file').toList();
      final outcomes = [
        for (final row in rows) h.controller.writeRowFor(row)?.outcome,
      ];
      expect(outcome.state, AiJournalState.succeeded);
      expect(h.server.content, contains('New sentence.'));
      expect(h.server.mutations, 1);
      expect(requests, hasLength(35));
      expect(
        requests.where(
          (request) => request.method == 'GET' || request.method == 'HEAD',
        ),
        hasLength(34),
      );
      expect(requests.where((request) => request.method == 'PUT'), hasLength(1));
      expect(h.oauthAdapter.requests.length - beforeRefreshes, 17);
      expect(rows, hasLength(2));
      expect(
        outcomes.where((value) => value?.reasonCode == 'httpBudgetExceeded'),
        hasLength(1),
        reason: 'the second 35-request reservation cannot fit in 40',
      );
      expect(aiWriteRequestAllowance('edit_file'), 35);
    },
  );

  test('file origin binds only when the branch-head SHA matches', () async {
    Future<({StackHarness harness, Future<void> sending})> start(
      String branchHead,
    ) async {
      var content = '# Mobile Workspace\n\nOld sentence.\n';
      final harness = await StackHarness.create(
        level: AiAutonomyLevel.bypass,
        configure: (server) {
          server.overrides['GET projects/42'] = (_) => jsonResponse({
            ...server.workspace.projectRecord,
            'default_branch': 'develop',
            'ci_config_path': null,
          });
          server.overrides['GET projects/42/repository/branches/main'] = (_) =>
              jsonResponse({
                'name': 'main',
                'protected': false,
                'default': false,
                'commit': {'id': branchHead},
              });
          server.overrides['HEAD projects/42/repository/files/README.md'] =
              (_) => ResponseBody.fromString('', 200, headers: {
                'cache-control': ['no-store'],
                'x-gitlab-size': ['${content.length}'],
                'x-gitlab-last-commit-id': [WorkspaceFixture.sha],
              });
          server.overrides['GET projects/42/repository/files/README.md/raw'] =
              (_) => ResponseBody.fromString(content, 200, headers: {
                'cache-control': ['no-store'],
              });
          server.overrides['PUT projects/42/repository/files/README.md'] =
              (request) {
                final body = request.data! as Map<String, dynamic>;
                content = body['content']! as String;
                return jsonResponse({'file_path': 'README.md'});
              };
        },
      );
      harness.provider.script.add(
        (_) => toolTurn('edit_file', {
          'projectId': 42,
          'branch': 'main',
          'path': 'README.md',
          'commitMessage': 'Update synthetic sentence',
          'edits': [
            {'old': 'Old sentence.', 'new': 'New sentence.'},
          ],
          'reason': 'The user requested this exact edit.',
        }),
      );
      return (harness: harness, sending: harness.controller.send('Edit this file.'));
    }

    final matching = await start(WorkspaceFixture.sha);
    addTearDown(matching.harness.dispose);
    bool needsCard(AiWriteProposal proposal) =>
        proposal.tier.decision == AiGateDecision.requireApproval;
    await _waitUntil(
      () =>
          matching.harness.controller.proposals.any(needsCard) ||
          matching.harness.server.mutations.isNotEmpty,
    );
    expect(
      matching.harness.controller.proposals.where(needsCard),
      isEmpty,
      reason: 'the bound origin file runs at bypass without a card',
    );
    await matching.sending.timeout(_timeout);
    expect(matching.harness.server.mutations, hasLength(1));

    final mismatching = await start(WorkspaceFixture.olderSha);
    addTearDown(mismatching.harness.dispose);
    await _waitUntil(() => mismatching.harness.controller.proposals.isNotEmpty);
    final proposal = mismatching.harness.controller.proposals.single;
    expect(proposal.tier.reasons, contains(AiFixedConfirmReason.targetUnbound));
    expect(mismatching.harness.server.mutations, isEmpty);
    await mismatching.harness.controller.rejectWrite(proposal);
    await mismatching.sending.timeout(_timeout);
  });
}
