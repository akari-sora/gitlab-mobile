import 'release_policy_support.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/workspace_fixture.dart';
import 'fx_coord_support.dart';
import 'p6_support.dart';

const p17Timeout = Duration(seconds: 20);

final class P17ScanPort implements port.AiGitLabWritePort {
  P17ScanPort(this.server);

  final P6Server server;
  int prepares = 0;

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) {
    prepares++;
    return server.writePort.prepare(
      port.AiWriteRequest(
        operationId: 'edit_file',
        executionId: request.executionId,
        scope: p6Scope,
        arguments: {
          ...p6Args('edit_file', path: 'README.md'),
          'edits': [
            {'old': 'alpha', 'new': 'beta'},
          ],
        },
      ),
    );
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => throw StateError('P17 scan fixture never dispatches');
}

final class P17ScanFixture {
  P17ScanFixture._(
    this.root,
    this.session,
    this.settings,
    this.controller,
    this.server,
    this.scanPort,
  );

  final Directory root;
  final SessionController session;
  final AiSettingsController settings;
  final AiChatController controller;
  final P6Server server;
  final P17ScanPort scanPort;

  static Future<P17ScanFixture> create() async {
    final workspace = WorkspaceFixture();
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    final session = controllerFor(accounts, workspace.adapter);
    await session.initialize();
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final config = await settings.saveProvider(stackProviderConfig);
    await settings.loadAccount(workspace.account.key);
    await settings.setAutonomySettings(
      workspace.account.key,
      ceiling: AiAutonomyLevel.bypass,
      startingLevel: AiAutonomyLevel.confirmEach,
    );
    await settings.grantConsent(
      workspace.account.key,
      settings.consentContractFor(
        workspace.account.key,
        config,
        releasePolicy: fixtureReleasePolicy,
        writePolicy: aiMr6b1WritePolicy(AiAutonomyLevel.bypass, releasePolicy: fixtureReleasePolicy),
        agreedCeiling: AiAutonomyLevel.bypass,
      ),
      const {'synthetic': true},
    );
    final root = Directory.systemTemp.createTempSync('p17-controller-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
    );
    await journal.recoverAfterAccountsLoaded([workspace.account.key]);
    await journal.ensureInitialized(workspace.account.key);
    final provider = StackProvider()
      ..script.add(
        (_) => toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic issue'},
          'reason': 'Exercise the production fragment checker.',
        }),
      );
    final server = P6Server();
    server.contents[p6L] = 'synthetic-test-token\nalpha\n';
    final scanPort = P17ScanPort(server);
    final controller = AiChatController(
      releasePolicy: fixtureReleasePolicy,
      origin: AiFileOrigin(
        project: workspace.project,
        path: 'README.md',
        sha: WorkspaceFixture.sha,
      ),
      session: session,
      settings: settings,
      runningCount: () => 0,
      appInForeground: () => true,
      clientMayStart: () => true,
      writeJournal: journal,
      writePortFactory: () => scanPort,
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
    await controller.recheck().timeout(p17Timeout);
    expect(controller.canSend, isTrue);
    return P17ScanFixture._(
      root,
      session,
      settings,
      controller,
      server,
      scanPort,
    );
  }

  Future<void> dispose() async {
    controller.dispose();
    settings.dispose();
    session.dispose();
    server.close();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

Set<String> p17ToolNames(String body) {
  final decoded = jsonDecode(body) as Map<String, Object?>;
  final tools = decoded['tools'];
  if (tools is! List<Object?>) return const {};
  return {
    for (final tool in tools)
      (tool! as Map<String, Object?>)['name']! as String,
  };
}

Future<void> p17WaitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(p17Timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'P17 controller checkpoint timed out');
}
