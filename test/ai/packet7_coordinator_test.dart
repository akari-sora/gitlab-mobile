import 'release_policy_support.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    hide AiFixedConfirmReason;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';

const _account = 'https://example.com/gitlab#7';
const _scope = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);

void main() {
  late _Harness h;

  setUp(() async {
    h = await _Harness.create();
  });

  tearDown(() async {
    await h.dispose();
  });

  test(
    '§15 rows 7 and 18 waiting approval is memory-only and fail-stops the turn',
    () async {
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      final first = _starCall('first');
      final proposal = await h.coordinator.propose(first);

      expect(proposal, isNotNull);
      expect(proposal!.tier.decision, AiGateDecision.requireApproval);
      expect(h.journal.entries(_account), isEmpty);
      expect(h.nonGetRequests, 0);

      proposal.editedText = 'user-edited text';
      await h.coordinator.reject(proposal);
      expect(proposal.editedText, 'user-edited text');
      expect(h.coordinator.outcomeFor(first.id)?.reasonCode, 'userRejected');
      expect(h.journal.entries(_account), isEmpty);

      final portCreations = h.portCreations;
      final later = _starCall('later');
      expect(await h.coordinator.propose(later), isNull);
      expect(
        h.coordinator.outcomeFor(later.id)?.reasonCode,
        'previousWriteIncomplete',
      );
      expect(h.portCreations, portCreations);
      expect(h.nonGetRequests, 0);
    },
  );

  test(
    '§15 row7 expiry retains edited text and never reaches journal',
    () async {
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      final call = _starCall('expires');
      final proposal = (await h.coordinator.propose(call))!;
      proposal.editedText = 'keep after expiry';

      h.clock = h.clock.add(const Duration(minutes: 31));
      h.coordinator.checkNow();
      await Future<void>.delayed(Duration.zero);

      expect(proposal.valid, isFalse);
      expect(proposal.editedText, 'keep after expiry');
      expect(h.coordinator.outcomeFor(call.id)?.reasonCode, 'approvalExpired');
      expect(h.journal.entries(_account), isEmpty);
      expect(h.nonGetRequests, 0);
    },
  );

  test(
    '§15 row19 no HTTP reservation constructs no port or proposal',
    () async {
      await h.dispose();
      h = await _Harness.create(maxGitLabRequests: 0, httpCost: (_) => 1);
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      final call = _starCall('no-budget');

      expect(await h.coordinator.propose(call), isNull);
      expect(
        h.coordinator.outcomeFor(call.id)?.reasonCode,
        'httpBudgetExceeded',
      );
      expect(h.portCreations, 0);
      expect(h.freshnessReads, 0);
      expect(h.adapter.requests, isEmpty);
      expect(h.journal.entries(_account), isEmpty);
    },
  );

  test('§15 row29 post-flush policy flip prevents the mutation', () async {
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final proposal = (await h.coordinator.propose(_starCall('barrier')))!;
    h.files.entered = Completer<void>();
    h.files.resume = Completer<void>();

    final approving = h.coordinator.approve(proposal);
    await h.files.entered!.future;
    h.consentValid = false;
    h.files.resume!.complete();
    final outcome = await approving;

    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.mutationCount, 0);
    expect(outcome.reasonCode, 'policyDenied');
    expect(h.nonGetRequests, 0);
    expect(
      h.journal.entries(_account).single.state,
      AiJournalState.notExecuted,
    );
  });

  test(
    '§15 rows 1 and 29 approved proposal dispatches once and journals',
    () async {
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      final proposal = (await h.coordinator.propose(_starCall('approved')))!;

      final outcome = await h.coordinator.approve(proposal);

      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.mutationCount, 1);
      expect(outcome.readbackConfirmed, isFalse);
      expect(outcome.summary, contains('project:9/star/7'));
      expect(h.nonGetRequests, 1);
      expect(
        h.journal.entries(_account).single.state,
        AiJournalState.succeeded,
      );
      expect(await h.coordinator.approve(proposal), same(outcome));
      expect(h.nonGetRequests, 1);
    },
  );

  test('edited text requires a second explicit approval', () async {
    h.coordinator.beginRun('Comment on #3 in team/example-9');
    h.coordinator.beginTurn();
    final proposal = (await h.coordinator.propose(_noteCall('edit')))!;

    final edited = await h.coordinator.approve(
      proposal,
      editedText: 'edited synthetic body',
    );

    expect(edited.reasonCode, 'approvalRequired');
    expect(edited.mutationCount, 0);
    expect(proposal.valid, isTrue);
    expect(proposal.editedText, 'edited synthetic body');
    expect(h.nonGetRequests, 0);
    expect(h.journal.entries(_account), isEmpty);

    final approved = await h.coordinator.approve(proposal);
    expect(approved.state, AiJournalState.succeeded);
    expect(approved.mutationCount, 1);
    expect(approved.readbackConfirmed, isTrue);
    expect(proposal.editedText, isNull);
    expect(h.nonGetRequests, 1);
  });

  test('hard-line typed name is checked again at approval', () async {
    await h.dispose();
    h = await _Harness.create(ledger: const _HardLineStarLedger());
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final proposal = (await h.coordinator.propose(_starCall('typed')))!;

    expect(proposal.tier.requiresTypedName, isTrue);
    expect(proposal.tier.typedName, 'team/example-9');
    final mismatch = await h.coordinator.approve(
      proposal,
      typedName: 'team/wrong',
    );
    expect(mismatch.reasonCode, 'typedNameMismatch');
    expect(mismatch.mutationCount, 0);
    expect(proposal.valid, isTrue);
    expect(h.nonGetRequests, 0);

    final approved = await h.coordinator.approve(
      proposal,
      typedName: proposal.tier.typedName,
    );
    expect(approved.state, AiJournalState.succeeded);
    expect(h.nonGetRequests, 1);
  });

  test('no-change succeeds without fail-stopping the same turn', () async {
    h.freshness = const AiWriteFreshness(
      updatedAt: '2026-10-22T00:00:00Z',
      visibilityUnreadable: false,
      noChange: true,
    );
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();

    final first = (await h.coordinator.propose(_starCall('no-change')))!;
    final outcome = await h.coordinator.approve(first);
    expect(outcome.noChange, isTrue);
    expect(outcome.successful, isTrue);
    expect(outcome.mutationCount, 0);
    expect(
      h.journal.entries(_account).single.state,
      AiJournalState.notExecuted,
    );

    final second = await h.coordinator.propose(_starCall('after-no-change'));
    expect(second, isNotNull);
    expect(h.coordinator.outcomeFor('after-no-change'), isNull);
  });

  test('resume projects a recorded execution without GitLab traffic', () async {
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final proposal = (await h.coordinator.propose(_starCall('recorded')))!;
    final outcome = await h.coordinator.approve(proposal);
    final requests = h.adapter.requests.length;

    final resumed = h.coordinator.resume(outcome.executionId!);

    expect(resumed?.reasonCode, 'alreadyRecorded');
    expect(resumed?.state, AiJournalState.succeeded);
    expect(resumed?.operationId, 'setStar');
    expect(resumed?.target, outcome.target);
    expect(h.adapter.requests, hasLength(requests));
    expect(h.coordinator.resume('missing-execution'), isNull);
    expect(h.adapter.requests, hasLength(requests));
  });

  test('a same-run settled duplicate on resume still requires confirmation at bypass', () async {
    h.level = AiAutonomyLevel.bypass;
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final first = (await h.coordinator.propose(_starCall('first-bypass')))!;
    expect(first.tier.decision, AiGateDecision.execute);
    expect((await h.coordinator.approve(first)).successful, isTrue);

    h.coordinator.resumeRun();
    h.coordinator.beginTurn();
    final duplicate = (await h.coordinator.propose(
      _starCall('duplicate-bypass'),
    ))!;

    expect(duplicate.tier.decision, AiGateDecision.requireApproval);
    expect(
      duplicate.tier.reasons,
      contains(AiFixedConfirmReason.duplicateOfSettledWrite),
    );
    expect(h.nonGetRequests, 1);
  });

  test(
    'coordinators with the same write keys never overlap mutations',
    () async {
      final mutationEntered = Completer<void>();
      final releaseMutation = Completer<void>();
      await h.dispose();
      h = await _Harness.create(
        responder: (request) async {
          if (request.method != 'GET') {
            if (!mutationEntered.isCompleted) {
              mutationEntered.complete();
              await releaseMutation.future;
            }
            return jsonResponse(projectJson(9));
          }
          if (request.uri.path.endsWith('/user')) {
            return jsonResponse({'id': 7, 'username': 'tester'});
          }
          if (request.uri.path.endsWith('/projects/9')) {
            return jsonResponse(projectJson(9));
          }
          throw StateError(
            'Unexpected request: ${request.method} ${request.uri}',
          );
        },
      );
      final peer = h.newCoordinator(conversationId: 'conversation-peer');
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      peer.beginRun('Star team/example-9');
      peer.beginTurn();
      final first = (await h.coordinator.propose(_starCall('coordinator-a')))!;
      final second = (await peer.propose(_starCall('coordinator-b')))!;

      final firstApproval = h.coordinator.approve(first);
      await mutationEntered.future;
      final secondApproval = peer.approve(second);
      await Future<void>.delayed(Duration.zero);
      expect(h.nonGetRequests, 1);

      releaseMutation.complete();
      expect((await firstApproval).successful, isTrue);
      final peerOutcome = await secondApproval;
      expect(peerOutcome.mutationCount, 0);
      expect(peerOutcome.successful, isFalse);
      expect(h.nonGetRequests, 1);
      peer.stop('disposed');
    },
  );

  test(
    'stopped post-accept write projects uncertain until its real settlement',
    () async {
      final mutationEntered = Completer<void>();
      final releaseMutation = Completer<void>();
      await h.dispose();
      h = await _Harness.create(
        responder: (request) async {
          if (request.method != 'GET') {
            mutationEntered.complete();
            await releaseMutation.future;
            return jsonResponse(projectJson(9));
          }
          if (request.uri.path.endsWith('/user')) {
            return jsonResponse({'id': 7, 'username': 'tester'});
          }
          if (request.uri.path.endsWith('/projects/9')) {
            return jsonResponse(projectJson(9));
          }
          throw StateError(
            'Unexpected request: ${request.method} ${request.uri}',
          );
        },
      );
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      const callId = 'accepted-before-stop';
      final proposal = (await h.coordinator.propose(_starCall(callId)))!;
      final approval = h.coordinator.approve(proposal);
      await mutationEntered.future;

      expect(h.coordinator, isA<AiWriteStateSource>());
      expect(h.coordinator, isA<AiWriteSettlementSource>());
      expect(h.coordinator.inFlightWrites, hasLength(1));
      var settlementCompleted = false;
      final settlement = h.coordinator.inFlightWrites.single.then((outcome) {
        settlementCompleted = true;
        return outcome;
      });

      h.coordinator.stop('stopped');
      final projected = h.coordinator.recordedOutcomeFor(callId);
      expect(projected?.state, AiJournalState.writeUncertain);
      expect(projected?.reasonCode, 'writePending');
      expect(projected?.mutationCount, 0);
      expect(settlementCompleted, isFalse);
      expect(h.coordinator.inFlightWrites, hasLength(1));
      expect(
        h.journal.entries(_account).single.state,
        AiJournalState.dispatching,
      );

      releaseMutation.complete();
      final terminal = await approval;
      expect(await settlement, same(terminal));
      expect(terminal.state, AiJournalState.succeeded);
      expect(terminal.mutationCount, 1);
      expect(settlementCompleted, isTrue);
      expect(h.coordinator.inFlightWrites, isEmpty);
      expect(
        h.journal.entries(_account).single.state,
        AiJournalState.succeeded,
      );
    },
  );

  test(
    'stopped pre-accept write projects and settles as not executed',
    () async {
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      const callId = 'stopped-before-accept';
      final proposal = (await h.coordinator.propose(_starCall(callId)))!;
      h.freshnessEntered = Completer<void>();
      h.releaseFreshness = Completer<void>();

      final approval = h.coordinator.approve(proposal);
      await h.freshnessEntered!.future;
      expect(h.coordinator.inFlightWrites, hasLength(1));

      h.coordinator.stop('stopped');
      final projected = h.coordinator.recordedOutcomeFor(callId);
      expect(projected?.state, AiJournalState.notExecuted);
      expect(projected?.reasonCode, 'notAccepted');
      expect(projected?.mutationCount, 0);
      expect(h.nonGetRequests, 0);

      h.releaseFreshness!.complete();
      final terminal = await approval;
      expect(terminal.state, AiJournalState.notExecuted);
      expect(terminal.reasonCode, 'stopped');
      expect(terminal.mutationCount, 0);
      expect(h.nonGetRequests, 0);
      expect(h.coordinator.inFlightWrites, isEmpty);
      expect(
        h.journal.entries(_account).single.state,
        AiJournalState.notExecuted,
      );
    },
  );

  test('late old-run settlement cannot poison a reused call id', () async {
    final mutationEntered = Completer<void>();
    final releaseMutation = Completer<void>();
    await h.dispose();
    h = await _Harness.create(
      maxGitLabRequests: 80,
      responder: (request) async {
        if (request.method != 'GET') {
          mutationEntered.complete();
          await releaseMutation.future;
          return jsonResponse({
            'message': 'synthetic server failure',
          }, status: 500);
        }
        if (request.uri.path.endsWith('/user')) {
          return jsonResponse({'id': 7, 'username': 'tester'});
        }
        if (request.uri.path.endsWith('/projects/9')) {
          return jsonResponse(projectJson(9));
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.uri}',
        );
      },
    );
    const reusedCallId = 'provider-reused-call-id';
    h.coordinator.beginRun('Star team/example-9');
    h.coordinator.beginTurn();
    final oldProposal = (await h.coordinator.propose(_starCall(reusedCallId)))!;
    final oldApproval = h.coordinator.approve(oldProposal);
    await mutationEntered.future;

    h.coordinator.stop('stopped');
    h.coordinator.beginRun('Star team/example-9 in a new run');
    h.coordinator.beginTurn();
    expect(h.coordinator.outcomeFor(reusedCallId), isNull);

    releaseMutation.complete();
    final oldTerminal = await oldApproval;
    expect(oldTerminal.state, AiJournalState.writeUncertain);
    expect(oldTerminal.mutationCount, 1);
    expect(h.coordinator.outcomeFor(reusedCallId), isNull);

    final currentProposal = await h.coordinator.propose(
      _issueCall(reusedCallId),
    );
    expect(
      currentProposal,
      isNotNull,
      reason: h.coordinator.outcomeFor(reusedCallId)?.reasonCode,
    );
    expect(currentProposal!.operationId, 'createIssue');
    expect(currentProposal.tier.decision, AiGateDecision.requireApproval);
    expect(h.coordinator.outcomeFor(reusedCallId), isNull);
  });

  for (final guard
      in <({String name, String reason, void Function(_Harness) flip})>[
        (name: 'stop', reason: 'stopped', flip: (h) => h.coordinator.stop()),
        (
          name: 'account generation',
          reason: 'settingsChanged',
          flip: (h) => h.sessionGeneration++,
        ),
        (
          name: 'consent',
          reason: 'policyDenied',
          flip: (h) => h.consentValid = false,
        ),
        (
          name: 'client availability',
          reason: 'clientUnavailable',
          flip: (h) => h.clientMayStart = false,
        ),
        (
          name: 'foreground',
          reason: 'backgrounded',
          flip: (h) => h.foreground = false,
        ),
        (
          name: 'proposal epoch',
          reason: 'proposalInvalidated',
          flip: (h) => h.journal.bumpProposalEpoch(_account),
        ),
        (
          name: 'tombstone',
          reason: 'accountBlocked',
          flip: (h) => h.journal.noteTombstoneSet(_account),
        ),
        (
          name: 'removal hold',
          reason: 'accountBlocked',
          flip: (h) => h.removal = h.journal.beginRemoval(_account),
        ),
      ]) {
    test('post-flush ${guard.name} flip permits zero mutations', () async {
      h.coordinator.beginRun('Star team/example-9');
      h.coordinator.beginTurn();
      final proposal = (await h.coordinator.propose(
        _starCall('guard-${guard.name}'),
      ))!;
      h.files.entered = Completer<void>();
      h.files.resume = Completer<void>();

      final approving = h.coordinator.approve(proposal);
      await h.files.entered!.future;
      guard.flip(h);
      h.files.resume!.complete();
      final outcome = await approving;

      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, guard.reason);
      expect(outcome.mutationCount, 0);
      expect(h.nonGetRequests, 0);
      h.removal?.cancelFinal();
      h.removal = null;
    });
  }
}

AiToolCall _starCall(String id) => AiToolCall(
  id: id,
  name: 'setStar',
  arguments: const {
    'projectId': 9,
    'starred': true,
    'reason': 'The user requested this star.',
  },
);

AiToolCall _noteCall(String id) => AiToolCall(
  id: id,
  name: 'createNote',
  arguments: const {
    'projectId': 9,
    'resource': 'issues',
    'iid': 3,
    'body': 'original synthetic body',
    'reason': 'The user requested this note.',
  },
);

AiToolCall _issueCall(String id) => AiToolCall(
  id: id,
  name: 'createIssue',
  arguments: const {
    'projectId': 9,
    'fields': {'title': 'synthetic issue'},
    'reason': 'The user requested this issue.',
  },
);

final class _Harness {
  _Harness._({
    required this.root,
    required this.files,
    required this.journal,
    required this.adapter,
    required this.api,
    required this.toolBudget,
    required this.ledger,
    required this.httpCost,
  }) {
    coordinator = newCoordinator();
  }

  PolicyAiWriteCoordinator newCoordinator({
    String conversationId = 'conversation-1',
  }) => PolicyAiWriteCoordinator(
    releasePolicy: fixtureReleasePolicy,
    snapshot: () => AiWritePolicySnapshot(
      scope: _scope,
      level: level,
      ceiling: AiAutonomyLevel.bypass,
      consentHash: 'consent-v2',
      writePolicyRevision: policyRevision,
      scopeRevision: scopeRevision,
      sessionGeneration: sessionGeneration,
      consentValid: consentValid,
      alive: alive,
      appInForeground: foreground,
      clientMayStart: clientMayStart,
    ),
    createPort: () {
      portCreations++;
      return GitLabAiWritePort(api, accountKey: _account);
    },
    journal: journal,
    conversationId: conversationId,
    budget: () => toolBudget,
    readFreshness: (_) async {
      freshnessReads++;
      if (freshnessEntered case final entered? when !entered.isCompleted) {
        entered.complete();
        if (releaseFreshness case final release?) await release.future;
      }
      return freshness;
    },
    placeholders: UploadPlaceholderTable(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
    ),
    knownSecrets: () => const {},
    safeDisplay: (value) => value,
    now: () => clock,
    httpCost: httpCost,
    ledger: ledger,
  );

  static Future<_Harness> create({
    int maxGitLabRequests = 40,
    int Function(String)? httpCost,
    AiCapabilityLedger? ledger,
    Responder? responder,
  }) async {
    final root = Directory.systemTemp.createTempSync('packet7-coordinator-');
    final files = _BarrierFiles(root);
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      files: files,
      processId: 'packet7-test',
    );
    await journal.recoverAfterAccountsLoaded([_account]);
    await journal.ensureInitialized(_account);
    final adapter = FakeAdapter(
      responder ??
          (request) {
            if (request.method != 'GET') return jsonResponse(projectJson(9));
            if (request.uri.path.endsWith('/user')) {
              return jsonResponse({'id': 7, 'username': 'tester'});
            }
            if (request.uri.path.endsWith('/projects/9')) {
              return jsonResponse(projectJson(9));
            }
            if (request.uri.path.endsWith('/projects/9/issues/3')) {
              return jsonResponse({'id': 30, 'iid': 3, 'project_id': 9});
            }
            if (request.uri.path.contains('/projects/9/issues/3/notes/')) {
              return jsonResponse({'id': 31, 'body': 'synthetic'});
            }
            throw StateError(
              'Unexpected request: ${request.method} ${request.uri}',
            );
          },
    );
    final api = testApi(adapter);
    return _Harness._(
      root: root,
      files: files,
      journal: journal,
      adapter: adapter,
      api: api,
      toolBudget: AiToolBudget(maxGitLabRequests: maxGitLabRequests),
      ledger: ledger ?? fixtureAiLedger,
      httpCost: httpCost,
    );
  }

  final Directory root;
  final _BarrierFiles files;
  final AiWriteJournal journal;
  final FakeAdapter adapter;
  final GitLabApi api;
  final AiToolBudget toolBudget;
  final AiCapabilityLedger ledger;
  final int Function(String)? httpCost;
  late final PolicyAiWriteCoordinator coordinator;
  DateTime clock = DateTime.utc(2026, 10, 22, 12);
  bool consentValid = true;
  bool alive = true;
  bool foreground = true;
  bool clientMayStart = true;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  int sessionGeneration = 7;
  int policyRevision = 1;
  int scopeRevision = 1;
  int portCreations = 0;
  int freshnessReads = 0;
  Completer<void>? freshnessEntered;
  Completer<void>? releaseFreshness;
  AiRemovalJob? removal;
  AiWriteFreshness freshness = const AiWriteFreshness(
    updatedAt: '2026-10-22T00:00:00Z',
    visibilityUnreadable: false,
  );

  int get nonGetRequests =>
      adapter.requests.where((request) => request.method != 'GET').length;

  Future<void> dispose() async {
    coordinator.stop('disposed');
    removal?.cancelFinal();
    api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _HardLineStarLedger implements AiCapabilityLedger {
  const _HardLineStarLedger();

  static const capability = AiCapability(
    operationId: 'setStar',
    baseTier: AiWriteTier.hardLine,
    scopeClass: AiScopeClass.project,
  );

  @override
  AiCapability? find(String operationId) =>
      operationId == capability.operationId ? capability : null;

  @override
  List<AiCapability> get modelVisible => const [capability];
}

final class _BarrierFiles extends AiJournalFiles {
  _BarrierFiles(super.root);

  Completer<void>? entered;
  Completer<void>? resume;

  @override
  Future<void> write(
    String account,
    Uint8List bytes, {
    required bool Function() mayCommit,
  }) async {
    if (entered case final barrier? when !barrier.isCompleted) {
      barrier.complete();
    }
    if (resume case final barrier?) await barrier.future;
    await super.write(account, bytes, mayCommit: mayCommit);
  }
}
