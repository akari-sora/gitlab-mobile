import 'release_policy_support.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/workspace_fixture.dart';
import 'fx_coord_support.dart'
    show StackProvider, stackProviderConfig, toolTurn;
import 'p6_support.dart';

const _timeout = Duration(seconds: 20);

// Hidden file rows cannot be offered before packet 17. This test-only port
// bridges an offered createNote to a real family prepare so the production
// controller/runner/coordinator consume its scan, with no checker injection.
// Every proposal is rejected; this bridge cannot dispatch a mutation.
final class _ScanPort implements port.AiGitLabWritePort {
  _ScanPort(this.server, this.operation, this.replacement);
  final P6Server server;
  final String operation;
  final String replacement;
  int prepares = 0;

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) {
    prepares++;
    final args = p6Args(operation, path: 'README.md');
    if (operation == 'edit_file') {
      args['edits'] = [
        {'old': 'alpha', 'new': replacement},
      ];
    } else if (operation == 'createFile') {
      args['content'] = replacement;
    } else {
      server.suggestionPath = 'README.md';
      server.suggestionAfter = replacement;
    }
    return server.writePort.prepare(
      port.AiWriteRequest(
        operationId: operation,
        executionId: request.executionId,
        scope: request.scope,
        arguments: args,
      ),
    );
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => throw StateError('scan-only test port cannot dispatch');
}

final class _Fixture {
  _Fixture(
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
  final _ScanPort scanPort;

  static Future<_Fixture> create(String operation, String replacement) async {
    final workspace = WorkspaceFixture();
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    final session = controllerFor(accounts, workspace.adapter);
    await session.initialize();
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final config = await settings.saveProvider(stackProviderConfig);
    await settings.loadAccount(p6Account);
    await settings.setAutonomySettings(
      p6Account,
      ceiling: AiAutonomyLevel.bypass,
      startingLevel: AiAutonomyLevel.confirmEach,
    );
    await settings.grantConsent(
      p6Account,
      settings.consentContractFor(
        p6Account,
        config,
        releasePolicy: fixtureReleasePolicy,
        writePolicy: aiMr6b1WritePolicy(AiAutonomyLevel.bypass, releasePolicy: fixtureReleasePolicy),
        agreedCeiling: AiAutonomyLevel.bypass,
      ),
      const {'synthetic': true},
    );
    final root = Directory.systemTemp.createTempSync('seams-controller-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
    );
    await journal.recoverAfterAccountsLoaded([p6Account]);
    await journal.ensureInitialized(p6Account);
    final provider = StackProvider();
    provider.script.add(
      (_) => toolTurn('createNote', {
        'projectId': 9,
        'resource': 'issues',
        'iid': 3,
        'body': 'synthetic body',
        'reason': 'synthetic request',
      }),
    );
    final server = P6Server()..missing = operation == 'createFile';
    final scanPort = _ScanPort(server, operation, replacement);
    final controller = AiChatController(
      releasePolicy: fixtureReleasePolicy,
      origin: const AiGeneralOrigin(),
      session: session,
      settings: settings,
      runningCount: () => 0,
      appInForeground: () => true,
      clientMayStart: () => true,
      writeJournal: journal,
      writeScope: () => p6Scope,
      readWriteFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
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
    await controller.recheck().timeout(_timeout);
    expect(controller.canSend, isTrue);
    return _Fixture(root, session, settings, controller, server, scanPort);
  }

  Future<void> dispose() async {
    controller.dispose();
    settings.dispose();
    session.dispose();
    server.close();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(_timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'controller checkpoint timed out');
}

void main() {
  for (final op in ['edit_file', 'createFile', 'applySuggestion']) {
    test('controller real fragment checker accepts safe $op scan', () async {
      final f = await _Fixture.create(op, 'beta');
      addTearDown(f.dispose);
      final sending = f.controller.send('Make the requested change');
      await _waitFor(
        () =>
            f.controller.proposals.isNotEmpty ||
            f.controller.phase == AiChatPhase.idle,
      );
      expect(f.scanPort.prepares, 1);
      expect(f.controller.proposals, hasLength(1));
      expect(f.controller.phase, AiChatPhase.awaitingApproval);
      await f.controller.rejectWrite(f.controller.proposals.single);
      await sending.timeout(_timeout);
      expect(f.server.mutations, 0);
      expect(productionAiLedger.find(op)!.modelVisible, isTrue);
    });

    test(
      'controller real fragment checker blocks live account secret in $op',
      () async {
        // The account token is absent from model arguments; only the family scan
        // contains it. This proves the callback receives the live secret union.
        final f = await _Fixture.create(op, 'synthetic-test-token');
        addTearDown(f.dispose);
        await f.controller.send('Make the requested change').timeout(_timeout);
        expect(f.scanPort.prepares, 1);
        expect(f.controller.proposals, isEmpty);
        final row = f.controller.items.whereType<AiToolRunItem>().single;
        expect(row.writeStatus, AiWriteResultStatus.notExecuted);
        expect(f.controller.writeRowFor(row)?.outcome?.reasonCode, 'secret');
        expect(f.server.mutations, 0);
      },
    );
  }

  test(
    'controller fragment checker forwards Markdown confirmation reasons',
    () async {
      final f = await _Fixture.create('edit_file', '@all');
      addTearDown(f.dispose);
      final sending = f.controller.send('Make the requested change');
      await _waitFor(
        () =>
            f.controller.proposals.isNotEmpty ||
            f.controller.phase == AiChatPhase.idle,
      );
      expect(f.controller.proposals, hasLength(1));
      expect(
        f.controller.proposals.single.tier.reasons,
        contains(AiFixedConfirmReason.massMention),
      );
      await f.controller.rejectWrite(f.controller.proposals.single);
      await sending.timeout(_timeout);
      expect(f.server.mutations, 0);
    },
  );
}
