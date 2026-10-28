import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart'
    hide AiWriteOutcome;
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' show UploadPlaceholderTable;

import 'fx_coord_support.dart';
import 'mr6c_support.dart';

final class _Session {
  _Session(this.h) {
    gate = Mr6cExecutionGate(binding: binding(), clock: Mr6cClock())
      ..foreground = true;
    h.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: scope,
        level: h.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: consent,
        writePolicyRevision: policyRevision,
        scopeRevision: scopeRevision,
        sessionGeneration: generation,
        appInForeground: h.foreground,
        executionEligible: gate.executionEligible,
        ownerApi: owner,
      ),
      createPort: () => GitLabAiWritePort(h.api, accountKey: coordAccount),
      journal: h.journal,
      conversationId: conversation,
      budget: () => h.budget,
      readFreshness: (_) async {
        reads++;
        if (entered case final signal? when !signal.isCompleted) {
          signal.complete();
          await release!.future;
        }
        return const AiWriteFreshness(
          updatedAt: '2026-10-23T00:00:00Z',
          visibilityUnreadable: false,
        );
      },
      placeholders: UploadPlaceholderTable(instance: h.api.instance),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      now: () => h.clock,
      executionGate: gate,
      // Mirrors the controller's generation/API/account ownership check.
      onOutcome: (_, outcome) {
        if (scope.accountKey == coordAccount &&
            generation == 7 &&
            identical(owner, h.api)) {
          display.add(outcome);
        }
      },
    );
  }

  final CoordHarness h;
  static const conversation = 'c5-coordinator';
  late final Mr6cExecutionGate gate;
  AiWriteScope scope = coordScope;
  String consent = 'consent-v2';
  int policyRevision = 1;
  int scopeRevision = 1;
  int generation = 7;
  Object? get owner => ownerOverride ?? h.api;
  Object? ownerOverride;
  final List<AiWriteOutcome> display = [];
  int reads = 0;
  Completer<void>? entered;
  Completer<void>? release;

  AiExecutionRunBinding binding({String? permit}) => AiExecutionRunBinding(
    accountKey: coordAccount,
    generation: 7,
    ownerApi: h.api,
    conversationId: conversation,
    runId: 'logical-run',
    permitId: permit,
  );

  void begin() {
    h.coordinator.beginRun('Star this project');
    h.coordinator.beginTurn();
  }

  void renew() => gate.binding = binding(permit: 'new-permit');
}

void main() {
  test('permitless run keeps its ID and same-run settled result after resume',
      () async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    h.level = AiAutonomyLevel.bypass;
    final s = _Session(h)..begin();
    expect(h.coordinator.logicalRunId, 'logical-run');
    final first = await h.coordinator.execute(starCall('first'));
    expect(first.state, AiJournalState.succeeded);
    expect(h.mutations, 1);
    expect(h.journal.entries(coordAccount).single.runId, 'logical-run');

    s.renew();
    h.coordinator.resumeRun();
    final repeated = await h.coordinator.execute(starCall('first'));
    expect(repeated.state, AiJournalState.succeeded);
    expect(repeated.mutationCount, 0);
    expect(h.mutations, 1);
    final duplicate = (await h.coordinator.propose(starCall('second')))!;
    expect(duplicate.tier.decision, AiGateDecision.requireApproval);
    expect(duplicate.tier.reasons,
        contains(AiFixedConfirmReason.duplicateOfSettledWrite));
    expect(h.mutations, 1);
  });

  test('resume ends old approval; same call cannot recreate it', () async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    final s = _Session(h)..begin();
    final proposal = (await h.coordinator.propose(starCall('approval')))!;
    s.renew();
    h.coordinator.resumeRun();
    expect(proposal.valid, isFalse);
    expect((await h.coordinator.approve(proposal)).state,
        AiJournalState.notExecuted);
    final reads = s.reads;
    expect((await h.coordinator.execute(starCall('approval'))).state,
        AiJournalState.notExecuted);
    expect(s.reads, reads);
    expect(h.mutations, 0);
  });

  test('only approval wait is excluded; dispatch consumes active time',
      () async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    final s = _Session(h)..begin();
    final waiting = Completer<void>();
    final states = <bool>[];
    Duration active = Duration.zero;
    DateTime? activeSince = h.clock;
    final result = h.coordinator.execute(
      starCall('approval-clock'),
      onAwaitingApproval: (value) {
        states.add(value);
        if (value) {
          if (activeSince case final started?) {
            active += h.clock.difference(started);
          }
          activeSince = null;
          if (!waiting.isCompleted) waiting.complete();
        } else {
          activeSince = h.clock;
        }
      },
    );
    await waiting.future;
    final proposal = h.coordinator.proposals.single;
    final expiresAt = proposal.expiresAt;
    expect(expiresAt, h.clock.add(const Duration(minutes: 30)));
    h.clock = h.clock.add(const Duration(minutes: 29));
    h.foreground = false;
    expect((await h.coordinator.approve(proposal)).reasonCode, 'backgrounded');
    expect(states, [true]);
    expect(proposal.expiresAt, expiresAt);

    h.foreground = true;
    s.entered = Completer<void>();
    s.release = Completer<void>();
    final approved = h.coordinator.approve(proposal);
    await s.entered!.future;
    expect(states, [true, false]);
    expect(active, Duration.zero);
    h.clock = h.clock.add(const Duration(seconds: 5));
    expect(proposal.expiresAt, expiresAt);
    s.release!.complete();
    expect((await approved).state, AiJournalState.succeeded);
    expect((await result).state, AiJournalState.succeeded);
    active += h.clock.difference(activeSince!);
    expect(active, const Duration(seconds: 5));
    expect(states, [true, false]);
    expect(h.mutations, 1);
  });

  test('edited proposal resumes waiting, with the same wall-clock expiry',
      () async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    final s = _Session(h)..begin();
    final waiting = Completer<void>();
    final states = <bool>[];
    final result = h.coordinator.execute(
      coordNoteCall('edit-clock'),
      onAwaitingApproval: (value) {
        states.add(value);
        if (value && !waiting.isCompleted) waiting.complete();
      },
    );
    await waiting.future;
    final proposal = h.coordinator.proposals.single;
    final expiresAt = proposal.expiresAt;
    h.clock = h.clock.add(const Duration(minutes: 20));
    final edit = await h.coordinator.approve(
      proposal,
      editedText: 'Edited synthetic text',
    );
    expect(edit.reasonCode, 'approvalRequired');
    expect(states, [true, false, true]);
    expect(proposal.expiresAt, expiresAt);
    h.clock = h.clock.add(const Duration(minutes: 11));
    h.coordinator.checkNow();
    expect((await result).reasonCode, 'approvalExpired');
    expect(states, [true, false, true, false]);
    expect(h.mutations, 0);
    expect(s.reads, 1);
  });

  for (final (status, expected) in [
    (403, AiJournalState.failedCertain),
    (500, AiJournalState.writeUncertain),
  ]) {
    test('resume summarizes $expected without re-sending its execution',
        () async {
      final h = await CoordHarness.create();
      addTearDown(h.dispose);
      h.level = AiAutonomyLevel.bypass;
      h.failWritesWith = status;
      final s = _Session(h)..begin();
      final first = await h.coordinator.execute(starCall('first'));
      expect(first.state, expected);
      expect(h.mutations, 1);
      s.renew();
      h.coordinator.resumeRun();
      final repeated = await h.coordinator.execute(starCall('first'));
      expect(repeated.state, expected);
      expect(repeated.mutationCount, 0);
      expect(h.mutations, 1);
      if (expected == AiJournalState.writeUncertain) {
        final second = await h.coordinator.propose(starCall('second'));
        if (second != null) await h.coordinator.approve(second);
        expect(h.mutations, 1, reason: 'an isolated execution cannot be sent again');
        expect(second, isNull);
        expect(h.coordinator.outcomeFor('second')?.reasonCode, 'isolated');
      }
    });
  }

  test('resume cannot revive a pre-read that had not produced a proposal',
      () async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    h.level = AiAutonomyLevel.bypass;
    final s = _Session(h)..begin();
    s.entered = Completer<void>();
    s.release = Completer<void>();
    final original = h.coordinator.execute(starCall('stalled'));
    await s.entered!.future;
    s.renew();
    h.coordinator.resumeRun();
    expect((await h.coordinator.execute(starCall('stalled'))).state,
        AiJournalState.notExecuted);
    s.release!.complete();
    expect((await original).state, AiJournalState.notExecuted);
    expect(h.coordinator.proposals, isEmpty);
    expect(h.mutations, 0);
  });

  test('resume summarizes an accepted in-flight write while it settles once',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    late CoordHarness h;
    h = await CoordHarness.create(responder: (request) async {
      if (request.method != 'GET') {
        entered.complete();
        await release.future;
      }
      return h.respond(request);
    });
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      return h.dispose();
    });
    h.level = AiAutonomyLevel.bypass;
    final s = _Session(h)..begin();
    final original = h.coordinator.execute(starCall('in-flight'));
    await entered.future;
    h.coordinator.stop();
    s.renew();
    h.coordinator.resumeRun();
    final summary = await h.coordinator.execute(starCall('in-flight'));
    expect(summary.state, AiJournalState.writeUncertain);
    expect(summary.mutationCount, 0);
    expect(h.mutations, 1);
    release.complete();
    expect((await original).state, AiJournalState.succeeded);
    final entry = h.journal.entries(coordAccount).single;
    expect(entry.state, AiJournalState.succeeded);
    expect(entry.conversationId, _Session.conversation);
    expect(entry.runId, 'logical-run');
    expect(h.mutations, 1);
  });

  test('late success after account switch settles only the original account',
      () async {
    const otherAccount = 'https://example.com/gitlab#8';
    const otherScope = AiWriteScope(accountKey: otherAccount, grants: []);
    final entered = Completer<void>();
    final release = Completer<void>();
    late CoordHarness h;
    h = await CoordHarness.create(responder: (request) async {
      if (request.method != 'GET') {
        entered.complete();
        await release.future;
      }
      return h.respond(request);
    });
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      return h.dispose();
    });
    await h.journal.recoverAfterAccountsLoaded([coordAccount, otherAccount]);
    await h.journal.ensureInitialized(otherAccount);
    h.level = AiAutonomyLevel.bypass;
    final old = _Session(h)..begin();
    final oldCoordinator = h.coordinator;
    final pending = oldCoordinator.execute(starCall('late-success'));
    await entered.future;
    final beforeSwitch = h.journal.entries(coordAccount).single;
    expect(beforeSwitch.state, AiJournalState.dispatching);
    expect(h.mutations, 1);

    oldCoordinator.stop();
    final newOwner = Object();
    old.scope = otherScope;
    old.generation = 8;
    old.ownerOverride = newOwner;
    final newDisplay = <AiWriteOutcome>[];
    final newGate = Mr6cExecutionGate(
      binding: AiExecutionRunBinding(
        accountKey: otherAccount,
        generation: 8,
        ownerApi: newOwner,
        conversationId: 'new-conversation',
        runId: 'new-run',
      ),
      clock: Mr6cClock(),
    )..foreground = true;
    final newCoordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: otherScope,
        level: AiAutonomyLevel.bypass,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'new-consent',
        writePolicyRevision: 1,
        sessionGeneration: 8,
        appInForeground: true,
        ownerApi: newOwner,
      ),
      createPort: () => throw StateError('no new-account writes'),
      journal: h.journal,
      conversationId: 'new-conversation',
      budget: () => h.budget,
      readFreshness: (_) async => const AiWriteFreshness(),
      placeholders: UploadPlaceholderTable(instance: h.api.instance),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      executionGate: newGate,
      onOutcome: (_, outcome) => newDisplay.add(outcome),
    );
    h.coordinator = newCoordinator;
    newCoordinator.beginRun('New account conversation');
    release.complete();
    expect((await pending).state, AiJournalState.succeeded);

    final oldEntry = h.journal.entries(coordAccount).single;
    expect(oldEntry.executionId, beforeSwitch.executionId);
    expect(oldEntry.state, AiJournalState.succeeded);
    expect(oldEntry.accountKey, coordAccount);
    expect(oldEntry.conversationId, _Session.conversation);
    expect(oldEntry.runId, 'logical-run');
    expect(h.journal.entries(otherAccount), isEmpty);
    expect(newCoordinator.recordedOutcomeFor('late-success'), isNull);
    expect(old.display, isEmpty);
    expect(newDisplay, isEmpty);
    expect(h.mutations, 1);
  });

  for (final drift in [
    'account', 'generation', 'owner', 'scope', 'policy', 'consent',
    'visibility', 'binding-run', 'binding-owner',
  ]) {
    test('resume refuses $drift drift', () async {
      final h = await CoordHarness.create();
      addTearDown(h.dispose);
      final s = _Session(h)..begin();
      s.renew();
      switch (drift) {
        case 'account':
          s.scope = const AiWriteScope(accountKey: 'another', grants: []);
        case 'generation':
          s.generation++;
        case 'owner':
          s.ownerOverride = Object();
        case 'scope':
          s.scopeRevision++;
        case 'policy':
          s.policyRevision++;
        case 'consent':
          s.consent = 'changed';
        case 'visibility':
          h.foreground = false;
        case 'binding-run':
          s.gate.binding = AiExecutionRunBinding(
            accountKey: coordAccount, generation: 7, ownerApi: h.api,
            conversationId: _Session.conversation, runId: 'another-run',
            permitId: 'new-permit',
          );
        case 'binding-owner':
          s.gate.binding = AiExecutionRunBinding(
            accountKey: coordAccount, generation: 7, ownerApi: Object(),
            conversationId: _Session.conversation, runId: 'logical-run',
            permitId: 'new-permit',
          );
      }
      expect(() => h.coordinator.resumeRun(), throwsA(isA<AiExecutionPaused>()));
      expect(h.coordinator.executionRunCurrent, isFalse);
      expect(h.mutations, 0);
    });
  }
}
