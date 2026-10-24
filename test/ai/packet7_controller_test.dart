import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
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
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';

void main() {
  test('a missing account record uses one autonomy default', () async {
    final harness = await _Harness.create(
      persistAutonomySettings: false,
      recheck: false,
    );
    addTearDown(harness.dispose);

    expect(harness.settings.accountRecord(harness.accountKey), isNull);
    expect(harness.controller.autonomyCeiling, AiAutonomyLevel.readOnly);
    expect(harness.controller.autonomyLevel, AiAutonomyLevel.readOnly);
    expect(
      aiConversationConsentContract(
        harness.settings,
        harness.accountKey,
        harness.settings.providers.single,
      ).writePolicy,
      isNull,
    );
  });

  test('§15 row 1 explicit write grant enables a T1 mutation', () async {
    final harness = await _Harness.create(clientMayStart: () => true);
    addTearDown(harness.dispose);

    await harness.controller.send('Star studio/mobile-workspace');

    expect(harness.starMutations, 1);
    expect(harness.portCreations, 1);
    expect(harness.controller.phase, AiChatPhase.idle);
    expect(
      harness.controller.items.whereType<AiToolRunItem>().single.writeStatus,
      AiWriteResultStatus.succeeded,
    );
  });

  test(
    '§15 rows 7 and 18 awaiting approval disables send and readonly prevents dispatch',
    () async {
      final harness = await _Harness.create(clientMayStart: () => true);
      addTearDown(harness.dispose);
      await harness.controller.setAutonomyLevel(AiAutonomyLevel.confirmEach);

      final running = harness.controller.send('Star studio/mobile-workspace');
      await _waitFor(() => harness.controller.proposals.isNotEmpty);

      expect(harness.controller.phase, AiChatPhase.awaitingApproval);
      expect(harness.controller.canSend, isFalse);
      await harness.controller.setAutonomyLevel(AiAutonomyLevel.bypass);
      expect(harness.controller.autonomyLevel, AiAutonomyLevel.confirmEach);

      await harness.controller.setAutonomyLevel(AiAutonomyLevel.readOnly);
      harness.controller.checkWriteProposals();
      await running;

      expect(harness.starMutations, 0);
      expect(harness.controller.proposals, isEmpty);
      expect(harness.controller.phase, AiChatPhase.idle);
    },
  );

  test(
    '§15 row 7 rejection cannot resume a fourth active conversation',
    () async {
      var active = 0;
      final harness = await _Harness.create(
        clientMayStart: () => true,
        runningCount: () => active,
      );
      addTearDown(harness.dispose);
      await harness.controller.setAutonomyLevel(AiAutonomyLevel.confirmEach);
      final running = harness.controller.send('Star studio/mobile-workspace');
      await _waitFor(() => harness.controller.proposals.isNotEmpty);
      active = 3;

      await harness.controller.rejectWrite(harness.controller.proposals.single);
      await running;

      expect(harness.starMutations, 0);
      expect(harness.providerCalls, 1);
      expect(harness.controller.phase, AiChatPhase.idle);
      expect(harness.controller.canSend, isFalse);
    },
  );

  test(
    '§15 row 29 missing client predicate fails before port construction',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      await harness.controller.send('Star studio/mobile-workspace');

      expect(harness.starMutations, 0);
      expect(harness.portCreations, 0);
      expect(
        harness.controller.items.whereType<AiToolRunItem>().single.writeStatus,
        AiWriteResultStatus.notExecuted,
      );
    },
  );
}

Future<void> _waitFor(bool Function() condition) async {
  // Bounded by time, not by turns: under CI load the journal's file work can
  // need more turns than a fixed count allows.
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(
    condition(),
    isTrue,
    reason: 'synthetic operation did not reach checkpoint',
  );
}

final class _Harness {
  _Harness({
    required this.root,
    required this.session,
    required this.settings,
    required this.controller,
  });

  static Future<_Harness> create({
    bool Function()? clientMayStart,
    int Function()? runningCount,
    bool persistAutonomySettings = true,
    bool recheck = true,
  }) async {
    final workspace = WorkspaceFixture();
    var stars = 0;
    final gitLabAdapter = FakeAdapter((request) {
      if (request.method == 'POST' &&
          request.uri.path.endsWith('/projects/42/star')) {
        stars++;
        return jsonResponse({
          ...workspace.projectRecord,
          'starred': true,
        }, status: 201);
      }
      return workspace.respond(request);
    });
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    final session = controllerFor(accounts, gitLabAdapter);
    await session.initialize();

    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final provider = await settings.saveProvider(_provider);
    if (persistAutonomySettings) {
      await settings.loadAccount(workspace.account.key);
      await settings.setAutonomySettings(
        workspace.account.key,
        ceiling: AiAutonomyLevel.lowRiskAuto,
        startingLevel: AiAutonomyLevel.lowRiskAuto,
      );
      final contract = settings.consentContractFor(
        workspace.account.key,
        provider,
        writePolicy: aiMr6b1WritePolicy(AiAutonomyLevel.lowRiskAuto),
        agreedCeiling: AiAutonomyLevel.lowRiskAuto,
      );
      await settings.grantConsent(workspace.account.key, contract, const {
        'synthetic': true,
      });
    }

    final root = Directory.systemTemp.createTempSync('packet7-controller-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'packet7-controller-test',
    );
    await journal.recoverAfterAccountsLoaded([workspace.account.key]);
    await journal.ensureInitialized(workspace.account.key);

    var providerCalls = 0;
    final providerAdapter = FakeAdapter((_) {
      providerCalls++;
      return _sse(providerCalls == 1 ? _writeTurn : _answerTurn);
    });
    var portCreations = 0;
    late final _Harness harness;
    final controller = AiChatController(
      origin: const AiGeneralOrigin(),
      session: session,
      settings: settings,
      runningCount: runningCount ?? () => 0,
      appInForeground: () => true,
      clientMayStart: clientMayStart,
      writeJournal: journal,
      writeScope: () => AiWriteScope(
        accountKey: workspace.account.key,
        instance: workspace.api.instance,
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: workspace.project.id,
            projectPath: workspace.project.path,
          ),
        ],
      ),
      readWriteFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      writePortFactory: () {
        portCreations++;
        return GitLabAiWritePort(
          session.api!,
          accountKey: workspace.account.key,
        );
      },
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) {
            final transport = AiTransport(
              endpoint: AiEndpoint.parse(
                config.baseUrl,
                allowLanCleartext: false,
              ),
              apiKey: apiKey ?? '',
              authStyle: config.authStyle,
              adapter: providerAdapter,
            );
            return AiWireClient(
              transport: transport,
              wire: const ResponsesFormat(),
              config: config,
              conversationId: conversationId,
              appVersion: 'test',
            );
          },
    );
    harness = _Harness(
      root: root,
      session: session,
      settings: settings,
      controller: controller,
    );
    harness._starCount = () => stars;
    harness._portCount = () => portCreations;
    harness._providerCount = () => providerCalls;
    if (recheck) {
      await controller.recheck();
      expect(controller.canSend, isTrue);
    }
    return harness;
  }

  final Directory root;
  final SessionController session;
  final AiSettingsController settings;
  final AiChatController controller;
  String get accountKey => session.active!.key;
  late int Function() _starCount;
  late int Function() _portCount;
  late int Function() _providerCount;

  int get starMutations => _starCount();
  int get portCreations => _portCount();
  int get providerCalls => _providerCount();

  void dispose() {
    controller.dispose();
    settings.dispose();
    session.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

const _provider = AiProviderConfig(
  id: 'packet7-provider',
  name: 'Packet 7 provider',
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

ResponseBody _sse(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

String _event(Object value) => 'data: ${jsonEncode(value)}\n\n';

final _writeTurn = _event({
  'type': 'response.completed',
  'response': {
    'output': [
      {
        'type': 'function_call',
        'call_id': 'call-star',
        'name': 'setStar',
        'arguments': jsonEncode({
          'projectId': 42,
          'starred': true,
          'reason': 'The user explicitly requested this star.',
        }),
        'status': 'completed',
      },
    ],
  },
});

final _answerTurn = _event({
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
