import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_work_item_write_registry.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_status.dart';

import '../support/fake_adapter.dart';
import 'mr6b3g_support.dart';

// These tests exercise the real coordinator and journal through the explicitly
// synthetic G0e graph port. The port's send counter is not an HTTP counter.
void main() {
  setUp(() => aiGroupWorkItemWritesEnabledForTesting = true);
  tearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);

  for (final operation in <String, Map<String, Object?>>{
    'updateGroupWorkItemState': {'stateEvent': 'close'},
    'updateGroupWorkItemContent': {'description': 'Safe replacement'},
    'editGroupWorkItemActivityNote': {'noteId': 31, 'body': 'Safe note'},
    'updateGroupWorkItemLabels': {
      'labels': <String>['ready'],
    },
  }.entries) {
    test('${operation.key} double approval has one durable dispatch', () async {
      final h = await _harness();
      final proposal = await h.coordinator.propose(
        h.call(operation.key, operation.value),
      );
      expect(proposal, isNotNull);
      final entered = h.base.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final first = h.coordinator.approve(proposal!);
      await entered;
      final second = h.coordinator.approve(proposal);
      expect(h.graph.mutations, 0);
      final disk = await h.base.readDurableJournal();
      expect(
        ((disk['entries']! as List).single as Map)['state'],
        'dispatching',
      );
      h.base.files.releaseBarrier();
      final outcomes = await Future.wait([first, second]);
      expect(outcomes.every((o) => o.successful), isTrue);
      expect(
        outcomes.every((o) => o.executionId == proposal.executionId),
        isTrue,
      );
      expect(h.graph.mutations, 1);
      expect(h.base.journal.entries(g0eAccount), hasLength(1));
    });
  }

  test(
    'two group conversations share a journal and dispatch at most once',
    () async {
      final h = await _harness();
      final firstPolicy = _Policy(h);
      final secondPolicy = _Policy(h, graph: G0eGraphPort(h.api));
      final first = firstPolicy.coordinator(conversation: 'g15-first');
      final second = secondPolicy.coordinator(conversation: 'g15-second');
      final firstProposal = await first.propose(
        h.call('updateGroupWorkItemState', {'stateEvent': 'close'}),
      );
      final secondProposal = await second.propose(
        h.call('updateGroupWorkItemState', {'stateEvent': 'close'}),
      );
      expect(firstProposal, isNotNull);
      expect(secondProposal, isNotNull);
      final entered = h.base.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final firstResult = first.approve(firstProposal!);
      await entered;
      final secondResult = second.approve(secondProposal!);
      h.base.files.releaseBarrier();
      final outcomes = await Future.wait([firstResult, secondResult]);
      expect(outcomes.where((outcome) => outcome.successful), hasLength(1));
      expect(
        outcomes.where(
          (outcome) => outcome.state == AiJournalState.notExecuted,
        ),
        hasLength(1),
      );
      expect(firstPolicy.graph.mutations + secondPolicy.graph.mutations, 1);
      expect(h.base.journal.entries(g0eAccount), hasLength(1));
    },
  );

  test(
    'stopped in-flight group send stays isolated until late completion',
    () async {
      final h = await _harness();
      final latePort = _LatePort(h.api);
      addTearDown(() {
        if (!latePort.release.isCompleted) latePort.release.complete();
      });
      final policy = _Policy(h, writePort: latePort);
      final coordinator = policy.coordinator();
      final proposal = await coordinator.propose(
        h.call('updateGroupWorkItemState', {'stateEvent': 'close'}),
      );
      expect(proposal, isNotNull);
      final pending = coordinator.approve(proposal!);
      await latePort.entered.future.timeout(const Duration(seconds: 10));
      final entry = h.base.journal.entries(g0eAccount).single;
      expect(entry.state, AiJournalState.dispatching);
      expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isTrue);
      coordinator.stop();
      expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isTrue);
      final peerPolicy = _Policy(h);
      final peer = peerPolicy.coordinator(conversation: 'g15-late-peer');
      final retryCall = h.call('updateGroupWorkItemState', {
        'stateEvent': 'close',
      });
      final retry = await peer.propose(retryCall);
      if (retry != null) {
        final blocked = await peer.approve(retry);
        expect(blocked.state, AiJournalState.notExecuted);
        expect(blocked.reasonCode, 'isolated');
      } else {
        final blocked = peer.recordedOutcomeFor(retryCall.id);
        expect(blocked, isNotNull);
        expect(blocked!.state, AiJournalState.notExecuted);
        expect(blocked.reasonCode, 'isolated');
      }
      expect(h.graph.mutations, 0);
      latePort.release.complete();
      final outcome = await pending;
      expect(latePort.sends, 1);
      expect(outcome.mutationCount, 1);
      expect(h.base.journal.entries(g0eAccount), hasLength(1));
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.readbackConfirmed, isTrue);
      expect(
        h.base.journal.entries(g0eAccount).single.state,
        AiJournalState.succeeded,
      );
      expect(h.base.journal.isolated(g0eAccount, entry.writeKeys), isFalse);
    },
  );

  for (final minutes in [29, 31]) {
    test(
      'group approval at $minutes minutes ${minutes == 29 ? 'remains valid' : 'expires'}',
      () async {
        final h = await _harness();
        final policy = _Policy(h);
        final coordinator = policy.coordinator();
        final proposal = await coordinator.propose(
          h.call('updateGroupWorkItemState', {'stateEvent': 'close'}),
        );
        expect(proposal, isNotNull);
        policy.clock = policy.clock.add(Duration(minutes: minutes));
        coordinator.checkNow();
        final outcome = await coordinator.approve(proposal!);
        expect(
          outcome.state,
          minutes == 29 ? AiJournalState.succeeded : AiJournalState.notExecuted,
        );
        expect(
          outcome.reasonCode,
          minutes == 29 ? 'succeeded' : 'approvalExpired',
        );
        expect(h.graph.mutations, minutes == 29 ? 1 : 0);
      },
    );
  }

  for (final change in [
    'level',
    'scope',
    'consent',
    'generation',
    'api',
    'client',
    'stop',
  ]) {
    test('group dispatching flush rechecks $change before send', () async {
      final h = await _harness();
      final policy = _Policy(h);
      final coordinator = policy.coordinator();
      final proposal = await coordinator.propose(
        h.call('updateGroupWorkItemState', {'stateEvent': 'close'}),
      );
      expect(proposal, isNotNull);
      final entered = h.base.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = coordinator.approve(proposal!);
      await entered;
      switch (change) {
        case 'level':
          policy.level = AiAutonomyLevel.readOnly;
        case 'scope':
          policy.scope = const AiWriteScope(accountKey: g0eAccount, grants: []);
        case 'consent':
          policy.consentValid = false;
        case 'generation':
          policy.generation++;
        case 'api':
          policy.api = Object();
        case 'client':
          policy.clientMayStart = false;
        case 'stop':
          coordinator.stop();
      }
      h.base.files.releaseBarrier();
      final outcome = await pending;
      expect(
        outcome.state,
        AiJournalState.notExecuted,
        reason: '$change: ${outcome.reasonCode}',
      );
      expect(outcome.mutationCount, 0);
      expect(h.graph.mutations, 0);
      expect(
        h.base.journal.entries(g0eAccount).single.state,
        AiJournalState.notExecuted,
      );
    });
  }

  for (final change in ['level', 'scope', 'consent', 'generation', 'api']) {
    test('group pending approval rejects changed $change', () async {
      final h = await _harness();
      final policy = _Policy(h);
      final coordinator = policy.coordinator();
      final proposal = await coordinator.propose(
        h.call('updateGroupWorkItemState', {'stateEvent': 'close'}),
      );
      expect(proposal, isNotNull);
      switch (change) {
        case 'level':
          policy.level = AiAutonomyLevel.readOnly;
        case 'scope':
          policy.scope = const AiWriteScope(accountKey: g0eAccount, grants: []);
        case 'consent':
          policy.consentValid = false;
        case 'generation':
          policy.generation++;
        case 'api':
          policy.api = Object();
      }
      final outcome = await coordinator.approve(proposal!);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(h.graph.mutations, 0);
    });
  }

  test(
    'real UI registry and AI group leases exclude each other across kinds',
    () {
      const gid = 'gid://gitlab/WorkItem/91';
      final api = testApi(FakeAdapter((_) => jsonResponse({})));
      addTearDown(api.close);
      final registry = createAiWorkspaceWorkItemWriteRegistry(
        api: api,
        accountKey: g0eAccount,
        instanceKey: api.instance.key,
        generation: 7,
        isCurrent: () => true,
      );
      final status = WorkItemStatusWriteRegistry.instance;
      final uiToken = Object();
      expect(status.tryStartExternal(api, gid, uiToken), isTrue);
      for (final kind in AiWorkItemWriteKind.values) {
        expect(registry.tryStart(gid, kind), isNull, reason: kind.name);
      }
      status.settleExternal(api, gid, token: uiToken, mutationSent: false);
      for (final kind in AiWorkItemWriteKind.values) {
        final lease = registry.tryStart(gid, kind);
        expect(lease, isNotNull, reason: kind.name);
        expect(registry.isActive(gid), isTrue, reason: kind.name);
        if (kind != AiWorkItemWriteKind.health) {
          expect(
            status.tryStartExternal(api, gid, Object()),
            isFalse,
            reason: kind.name,
          );
        }
        for (final peer in AiWorkItemWriteKind.values) {
          expect(
            registry.tryStart(gid, peer),
            isNull,
            reason: '${kind.name}/${peer.name}',
          );
        }
        registry.settle(lease!, AiWorkItemWriteResult.notSent, null);
        expect(registry.isActive(gid), isFalse);
      }
    },
  );
}

Future<G0eHarness> _harness() async {
  final h = await G0eHarness.create();
  addTearDown(h.dispose);
  return h;
}

final class _Policy {
  _Policy(this.h, {G0eGraphPort? graph, this.writePort})
    : api = h.api,
      graph = graph ?? h.graph;
  final G0eHarness h;
  final G0eGraphPort graph;
  final port.AiGitLabWritePort? writePort;
  AiWriteScope scope = g0eScope;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  bool consentValid = true;
  bool clientMayStart = true;
  int generation = 7;
  Object api;
  DateTime clock = DateTime.utc(2026, 10, 28, 12);

  PolicyAiWriteCoordinator coordinator({String conversation = 'g15-races'}) {
    final budget = AiToolBudget(maxGitLabRequests: 40);
    final result = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: scope,
        level: level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'g15-consent',
        consentValid: consentValid,
        writePolicyRevision: 1,
        sessionGeneration: generation,
        ownerApi: api,
        currentResource: h.currentResource,
        appInForeground: true,
        clientMayStart: clientMayStart,
      ),
      createPort: () => writePort ?? graph,
      journal: h.base.journal,
      conversationId: conversation,
      budget: () => budget,
      readFreshness: (_) async => const AiWriteFreshness(
        targetVisibility: 'private',
        visibilityUnreadable: true,
        sourceVisibilityUnreadable: false,
      ),
      placeholders: h.placeholders,
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const G0eLedger(),
      now: () => clock,
    );
    result.beginRun('Update this group work item.');
    result.beginTurn();
    addTearDown(result.stop);
    return result;
  }
}

// This port delays after mayStart and represents one accepted synthetic send.
final class _LatePort implements port.AiGitLabWritePort {
  _LatePort(this.api);
  final Object api;
  final entered = Completer<void>();
  final release = Completer<void>();
  int epoch = 0;
  int sends = 0;

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    final current = ++epoch;
    return port.AiWritePrepared.graph(
      request: request,
      owner: this,
      releaseName: '$g0ePath#5',
      groupIdentity: g0eIdentity(api, readEpoch: current),
      groupIdentityIsCurrent: () => epoch == current,
      writeKeys: {
        const AiConflictKey([g0eAccount, 'group:7', 'workItem', '5']),
      },
      bindingDigest: 'g15-late',
      mutation: (hooks) async {
        await hooks.beforeMutation();
        if (!hooks.mayStart()) return const GraphWriteResult();
        sends++;
        entered.complete();
        await release.future;
        return const GraphWriteResult(
          mutationSent: true,
          acknowledged: true,
          readbackVerified: true,
        );
      },
    );
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => prepared.commitGraph(mayStart: mayStart);
}
