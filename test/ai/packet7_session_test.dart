import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart'
    show AiAutonomyLevel, AiConsentContract, AiProviderConfig;
import 'package:gitlab_mobile/core/ai/prompts.dart';
import 'package:gitlab_mobile/core/ai/runner.dart' show AiRunEnd;
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart'
    show AiTierDecision;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/workspace_fixture.dart';

AiWriteProposal _proposal() => AiWriteProposal(
  executionId: 'execution-1',
  operationId: 'createNote',
  tier: const AiTierDecision.unknown(),
  payloadDigest: 'digest',
  previewText: 'Synthetic proposal',
  userUtterance: 'Write a note',
  modelReason: 'Synthetic reason',
  expiresAt: DateTime.utc(2026, 10, 22, 1),
  proposalEpoch: 1,
  writePolicyRevision: 1,
  consentHash: 'consent',
  scopeRevision: 1,
  releaseName: '!12',
);

void main() {
  test('§15 row 12: read-only sessions get safe write API fallbacks', () async {
    final AiChatSession session = _Session(const AiGeneralOrigin());
    addTearDown((session as _Session).dispose);

    expect(session.proposals, isEmpty);
    expect(session.autonomyLevel, AiAutonomyLevel.readOnly);
    await session.setAutonomyLevel(AiAutonomyLevel.bypass);
    expect(session.autonomyLevel, AiAutonomyLevel.readOnly);
  });

  test(
    '§15 rows 7 and 12: write sessions expose proposals and level',
    () async {
      final write = _WriteSession(const AiGeneralOrigin())
        ..pending.add(_proposal());
      final AiChatSession session = write;
      addTearDown(write.dispose);

      expect(session.proposals, hasLength(1));
      expect(session.autonomyLevel, AiAutonomyLevel.lowRiskAuto);
      await session.setAutonomyLevel(AiAutonomyLevel.confirmEach);
      expect(session.autonomyLevel, AiAutonomyLevel.confirmEach);
    },
  );

  test(
    '§15 row 19: awaiting approval does not consume registry capacity',
    () async {
      final fixture = WorkspaceFixture();
      final owner = controllerFor(MemoryAccountStore(), fixture.adapter);
      final settings = AiSettingsController(MemoryAiStore());
      addTearDown(owner.dispose);
      addTearDown(settings.dispose);
      addTearDown(fixture.api.close);
      await owner.initialize();
      await owner.connect('https://example.com/gitlab', 'synthetic-token');

      final created = <_WriteSession>[];
      final registry = AccountAiRunRegistry(
        session: owner,
        settings: settings,
        sessionFactory:
            ({
              required origin,
              required session,
              required settings,
              required runningCount,
              wireClientFactory,
            }) {
              final chat = _WriteSession(origin);
              created.add(chat);
              return (
                session: chat,
                capacityChanged: () {},
                dispose: chat.dispose,
              );
            },
      );
      addTearDown(registry.dispose);

      final waiting = registry.open(const AiGeneralOrigin()) as _WriteSession;
      final running = <_WriteSession>[
        registry.open(
              AiJobOrigin(project: fixture.project, jobId: 1, jobName: 'one'),
            )
            as _WriteSession,
        registry.open(
              AiJobOrigin(project: fixture.project, jobId: 2, jobName: 'two'),
            )
            as _WriteSession,
        registry.open(
              AiJobOrigin(project: fixture.project, jobId: 3, jobName: 'three'),
            )
            as _WriteSession,
      ];
      waiting
        ..pending.add(_proposal())
        ..setPhase(AiChatPhase.awaitingApproval);
      for (final chat in running) {
        chat.setPhase(AiChatPhase.running);
      }

      expect(created, hasLength(4));
      expect(registry.runningCount, AiRunRegistry.maxRunning);

      registry.release(waiting);
      expect(registry.open(const AiGeneralOrigin()), same(waiting));
      waiting.setPhase(AiChatPhase.idle);
      registry.release(waiting);
      expect(registry.open(const AiGeneralOrigin()), same(waiting));
    },
  );

  test(
    '§15 row 4: registry stops sessions and snapshots write futures',
    () async {
      final fixture = WorkspaceFixture();
      final owner = controllerFor(MemoryAccountStore(), fixture.adapter);
      final settings = AiSettingsController(MemoryAiStore());
      addTearDown(owner.dispose);
      addTearDown(settings.dispose);
      addTearDown(fixture.api.close);
      await owner.initialize();
      await owner.connect('https://example.com/gitlab', 'synthetic-token');

      final registry = AccountAiRunRegistry(
        session: owner,
        settings: settings,
        sessionFactory:
            ({
              required origin,
              required session,
              required settings,
              required runningCount,
              wireClientFactory,
            }) {
              final chat = _WriteSession(origin);
              return (
                session: chat,
                capacityChanged: () {},
                dispose: chat.dispose,
              );
            },
      );
      addTearDown(registry.dispose);

      final first = registry.open(const AiGeneralOrigin()) as _WriteSession;
      final second =
          registry.open(
                AiJobOrigin(
                  project: fixture.project,
                  jobId: 7,
                  jobName: 'settlement',
                ),
              )
              as _WriteSession;
      final firstDone = Completer<AiWriteOutcome>();
      final secondDone = Completer<AiWriteOutcome>();
      first
        ..settlements.add(firstDone.future)
        ..setPhase(AiChatPhase.running);
      second
        ..settlements.add(secondDone.future)
        ..setPhase(AiChatPhase.awaitingApproval);

      expect(
        registry.inFlightWrites,
        orderedEquals(<Future<AiWriteOutcome>>[
          firstDone.future,
          secondDone.future,
        ]),
      );
      final snapshot = registry.stopAndSnapshotWrites();

      expect(first.phase, AiChatPhase.idle);
      expect(second.phase, AiChatPhase.idle);
      expect(
        snapshot,
        orderedEquals(<Future<AiWriteOutcome>>[
          firstDone.future,
          secondDone.future,
        ]),
      );

      firstDone.complete(
        const AiWriteOutcome(
          state: AiJournalState.succeeded,
          reasonCode: 'accepted',
        ),
      );
      secondDone.complete(
        const AiWriteOutcome(
          state: AiJournalState.writeUncertain,
          reasonCode: 'clientClosed',
        ),
      );
      await Future.wait(snapshot);
    },
  );

  test('§10 write prompt adds disclosure without changing readonly prompt', () {
    expect(
      aiSystemPrompt,
      startsWith("You are Mergeline's read-only GitLab assistant."),
    );
    expect(aiWriteSystemPrompt, contains("user's account"));
    expect(aiWriteSystemPrompt, contains('explicit user approval'));
    expect(aiWriteSystemPrompt, contains('Never retry an uncertain write'));
    expect(aiWriteSystemPrompt, contains('<gitlab_data>'));
  });
}

class _Session extends ChangeNotifier implements AiChatSession {
  _Session(this.origin);

  @override
  final AiChatOrigin origin;
  AiChatPhase currentPhase = AiChatPhase.idle;

  @override
  String get id => origin.key;
  @override
  List<AiChatItem> get items => const <AiChatItem>[];
  @override
  AiChatPhase get phase => currentPhase;
  @override
  AiChatBlocker get blocker => AiChatBlocker.none;
  @override
  List<AiProviderConfig> get providers => const <AiProviderConfig>[];
  @override
  AiProviderConfig? get provider => null;
  @override
  AiConsentContract? get consentRequest => null;
  @override
  UserFacingFailure? get failure => null;
  @override
  AiRunEnd? get lastEnd => null;
  @override
  bool get offerNewConversation => false;
  @override
  bool get historySaved => false;
  @override
  bool get canSend => currentPhase == AiChatPhase.idle;

  void setPhase(AiChatPhase value) {
    currentPhase = value;
    notifyListeners();
  }

  @override
  void stop() => setPhase(AiChatPhase.idle);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _WriteSession extends _Session
    implements AiWriteChatSession, AiWriteSettlementSource {
  _WriteSession(super.origin);

  final pending = <AiWriteProposal>[];
  final settlements = <Future<AiWriteOutcome>>[];
  AiAutonomyLevel level = AiAutonomyLevel.lowRiskAuto;

  @override
  List<Future<AiWriteOutcome>> get inFlightWrites =>
      List.unmodifiable(settlements);
  @override
  List<AiWriteProposal> get proposals => List.unmodifiable(pending);
  @override
  AiAutonomyLevel get autonomyLevel => level;
  @override
  Future<void> setAutonomyLevel(AiAutonomyLevel value) async {
    level = value;
    notifyListeners();
  }
}
