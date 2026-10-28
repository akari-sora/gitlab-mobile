import 'release_policy_support.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart'
    as write_port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_reread.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

// Plan v6 §15 row 5: 「停止後原寫入仍在途（`dispatching`）時，另一段對話
// 對同一 MR 的提議被擋；換 nonce、換 tool-call ID、換段、從紀錄恢復後重提
// 都被擋；兩種 scope 或 REST 與 GraphQL 兩種入口指向同一資源被擋」。
// 「重新讀取」只產生觀察，隔離維持；「原請求在途時不提供讀取」；
// 「手動解除需要輸入依 key 種類決定的確認名稱」。
// These are graph-family scenarios, including the real REST alias prepares.
// NOT_RUN §15 row 5: the same resource through two different scope entries;
// delimiter/isolated() direction-isolate key/name cases; changed-payload create
// retries, DELETE present/404 and same-name create/recreate observations;
// edit_file/deleteFile, merge, pipeline/job cross-operation isolation;
// empty/unparseable 2xx, 400/403/404/409/429 and mutation/readback 401 variants;
// MR/group release names, multi-key release, unavailable release-name pre-read,
// and notification/link/model release denial. These are graph-key scenarios,
// not the complete REST result-classification or release-entrypoint matrix.

const _families = [
  'updateWorkItemState',
  'updateWorkItemDates',
  'createWorkItemActivityReply',
  'snoozeTodo',
  'setWorkItemActivityNoteReaction',
];

void main() {
  for (final operation in _families) {
    test('§15 row 5 $operation dispatching and recovered isolation', () async {
      final h = await _harness();
      final transport = _Transport(h);
      addTearDown(transport.close);
      final first = _peer(h, transport, 'first-$operation');
      final proposal = (await first.propose(_call(operation, 'first')))!;
      transport.hold = true;
      final pending = first.approve(
        proposal,
        typedName: proposal.tier.typedName,
      );
      await transport.entered.future.timeout(mr6b3Timeout);
      final entry = h.journal.entries(mr6b3Account).single;
      expect(entry.state, AiJournalState.dispatching);
      expect(entry.executionId, proposal.executionId);
      first.stop('stopped-in-flight');
      expect(
        () => h.journal.rereadableEntry(mr6b3Account, entry.executionId),
        throwsA(
          isA<AiJournalException>().having((e) => e.reason, 'code', 'inFlight'),
        ),
      );
      expect(h.journal.isolated(mr6b3Account, entry.writeKeys), isTrue);
      await _expectSharedJournalBlocks(
        h,
        transport,
        operation,
        suffix: 'in-flight',
      );
      expect(transport.mutations, 1);
      transport.release();
      final outcome = await pending.timeout(mr6b3Timeout);
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.mutationCount, 1);
      expect(
        h.journal.rereadableEntry(mr6b3Account, entry.executionId).state,
        AiJournalState.writeUncertain,
      );
      expect(h.journal.isolated(mr6b3Account, entry.writeKeys), isTrue);
      await _expectSharedJournalBlocks(
        h,
        transport,
        operation,
        suffix: 'new-nonce',
      );
      final segment = _peer(h, transport, 'segment-$operation');
      segment.beginSegment();
      expect(
        await segment.propose(_call(operation, 'changed-tool-id')),
        isNull,
      );
      expect(segment.outcomeFor('changed-tool-id')?.reasonCode, 'isolated');

      final recovered = await h.recoverInNewProcess();
      final restored = _peer(
        h,
        transport,
        'restored-$operation',
        journal: recovered,
      );
      expect(
        await restored.propose(_call(operation, 'history-reproposal')),
        isNull,
      );
      expect(restored.outcomeFor('history-reproposal')?.reasonCode, 'isolated');
      expect(recovered.isolated(mr6b3Account, entry.writeKeys), isTrue);
      expect(transport.mutations, 1);
    });

    test('§15 row 5 $operation typed release affects only its keys', () async {
      final h = await _harness();
      final transport = _Transport(h);
      addTearDown(transport.close);
      final uncertain = await _makeUncertain(h, transport, operation);
      final entry = h.journal.entries(mr6b3Account).single;
      const unrelated = AiConflictKey([mr6b3Account, 'todos', '999']);
      await h.journal.prepare(
        draft: AiJournalDraft(
          executionId: 'unrelated',
          accountKey: mr6b3Account,
          conversationId: 'unrelated',
          runId: 'unrelated',
          operationId: 'snoozeTodo',
          writeKeys: {unrelated},
          payloadSha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          releaseName: '@synthetic',
        ),
      );
      await h.journal.markDispatching(executionId: 'unrelated');
      await h.journal.finish(
        executionId: 'unrelated',
        terminal: AiJournalState.writeUncertain,
      );
      expect(
        entry.releaseName,
        operation == 'snoozeTodo' ? '@synthetic' : '#3',
      );
      await expectLater(
        h.journal.releaseByUser(
          executionId: uncertain.executionId!,
          typedName: '#wrong',
        ),
        throwsA(
          isA<AiJournalException>().having(
            (e) => e.reason,
            'code',
            'confirmationRequired',
          ),
        ),
      );
      expect(h.journal.isolated(mr6b3Account, entry.writeKeys), isTrue);
      expect(h.journal.isolated(mr6b3Account, {unrelated}), isTrue);
      await h.journal.releaseByUser(
        executionId: uncertain.executionId!,
        typedName: entry.releaseName,
      );
      expect(h.journal.isolated(mr6b3Account, entry.writeKeys), isFalse);
      expect(h.journal.isolated(mr6b3Account, {unrelated}), isTrue);
      expect(
        h.journal.requiresConfirmation(mr6b3Account, entry.writeKeys),
        isTrue,
      );
      final next = _peer(h, transport, 'after-release-$operation');
      final nextProposal = await next.propose(
        _call(operation, 'after-release'),
      );
      expect(nextProposal, isNotNull);
      expect(nextProposal!.tier.decision, AiGateDecision.requireApproval);
      expect(
        nextProposal.tier.reasons.map((e) => e.name),
        contains('confirmMarkAfterManualRelease'),
      );
      expect(transport.mutations, 1);
    });
  }

  for (final operation in [
    'updateWorkItemState',
    'setWorkItemActivityNoteReaction',
    'snoozeTodo',
  ]) {
    test('§15 row 5 $operation real re-read and late landing', () async {
      final h = await _harness();
      final transport = _Transport(h);
      addTearDown(transport.close);
      final first = _peer(h, transport, 'reread-$operation');
      final proposal = (await first.propose(_call(operation, 'reread-first')))!;
      transport.hold = true;
      final pending = first.approve(
        proposal,
        typedName: proposal.tier.typedName,
      );
      await transport.entered.future.timeout(mr6b3Timeout);
      final entry = h.journal.entries(mr6b3Account).single;
      final intersection = operation == 'updateWorkItemState'
          ? 'createWorkItemActivityComment'
          : 'updateWorkItemState';
      final initialCount = transport.adapter.requests.length;
      await expectLater(
        rereadInterruptedWrite(
          journal: h.journal,
          accountKey: mr6b3Account,
          executionId: entry.executionId,
          api: transport.api,
        ),
        throwsA(
          isA<AiJournalException>().having((e) => e.reason, 'code', 'inFlight'),
        ),
      );
      expect(transport.adapter.requests.length, initialCount);
      await _expectSharedJournalBlocks(
        h,
        transport,
        intersection,
        suffix: 'reread-in-flight',
      );
      expect(transport.mutations, 1);
      first.stop('stopped-in-flight');
      transport.release();
      expect(
        (await pending.timeout(mr6b3Timeout)).state,
        AiJournalState.writeUncertain,
      );

      Future<AiRereadResult> check(
        AiWriteJournal journal,
        String suffix,
      ) async {
        final before = transport.adapter.requests.length;
        final result = await rereadInterruptedWrite(
          journal: journal,
          accountKey: mr6b3Account,
          executionId: entry.executionId,
          api: transport.api,
        );
        final requests = transport.adapter.requests.sublist(before);
        expect(requests, isNotEmpty);
        expect(requests.every((request) => request.method == 'GET'), isTrue);
        expect(result.requests, requests.length);
        expect(result.requests, lessThanOrEqualTo(AiWriteLimits.rereadHttp));
        final saved = journal.entries(mr6b3Account).single;
        final decoded = AiRereadObservation.decode(saved.observation);
        expect(decoded, isNotNull);
        expect(decoded!.encode(), result.observation.encode());
        expect(saved.state, AiJournalState.writeUncertain);
        expect(journal.isolated(mr6b3Account, entry.writeKeys), isTrue);
        await _expectSharedJournalBlocks(
          h,
          transport,
          intersection,
          suffix: suffix,
          journal: journal,
        );
        expect(transport.mutations, 1);
        return result;
      }

      final before = await check(h.journal, 'before-recovery');
      final subject = switch (operation) {
        'updateWorkItemState' => AiRereadSubject.issue,
        'setWorkItemActivityNoteReaction' => AiRereadSubject.note,
        _ => AiRereadSubject.todo,
      };
      expect(before.observation.subject, subject);
      expect(before.observation.presence, AiRereadPresence.present);
      if (operation == 'updateWorkItemState') {
        expect(before.observation.detail, AiRereadDetail.opened);
      }
      if (operation == 'snoozeTodo') {
        expect(before.observation.detail, AiRereadDetail.pending);
      }

      final recovered = await h.recoverInNewProcess();
      final recoveredEntry = recovered.entries(mr6b3Account).single;
      expect(recoveredEntry.state, AiJournalState.writeUncertain);
      expect(recoveredEntry.observation, before.observation.encode());
      final afterRecovery = await check(recovered, 'after-recovery');
      expect(afterRecovery.observation.subject, subject);
      expect(afterRecovery.observation.presence, AiRereadPresence.present);
      await transport.landLate(operation);
      expect(h.server.mutations, 1);
      final afterLate = await check(recovered, 'after-late-landing');
      expect(afterLate.observation.subject, subject);
      if (operation == 'updateWorkItemState') {
        expect(h.server.workItemState, 'CLOSED');
        expect(afterLate.observation.detail, AiRereadDetail.closed);
      } else if (operation == 'snoozeTodo') {
        expect(afterLate.observation.presence, AiRereadPresence.absent);
        expect(afterLate.observation.detail, AiRereadDetail.notPending);
      } else {
        expect(h.server.reactionAwarded, isTrue);
        expect(h.server.noteUpdatedAt, '2026-10-01T01:03:05Z');
        expect(afterLate.observation.presence, AiRereadPresence.present);
      }
      await expectLater(
        recovered.releaseByUser(
          executionId: entry.executionId,
          typedName: '#wrong',
        ),
        throwsA(
          isA<AiJournalException>().having(
            (e) => e.reason,
            'code',
            'confirmationRequired',
          ),
        ),
      );
      expect(recovered.isolated(mr6b3Account, entry.writeKeys), isTrue);
      await _expectSharedJournalBlocks(
        h,
        transport,
        intersection,
        suffix: 'wrong-release',
        journal: recovered,
      );
      await recovered.releaseByUser(
        executionId: entry.executionId,
        typedName: entry.releaseName,
      );
      expect(recovered.isolated(mr6b3Account, entry.writeKeys), isFalse);
      final afterRelease = _peer(
        h,
        transport,
        'after-correct-release-$operation',
        journal: recovered,
      );
      final next = await afterRelease.propose(_call(intersection, 'released'));
      expect(next, isNotNull);
      expect(next!.tier.decision, AiGateDecision.requireApproval);
      expect(transport.mutations, 1);
    });
  }

  const crossFamilies = [
    'updateWorkItemState',
    'createWorkItemActivityComment',
    'updateWorkItemDates',
    'setWorkItemActivityNoteReaction',
  ];
  for (final first in crossFamilies.take(3)) {
    for (final second in crossFamilies.where(
      (operation) => operation != first,
    )) {
      test('§15 row 5 uncertain $first isolates $second on #3', () async {
        final h = await _harness();
        final transport = _Transport(h);
        addTearDown(transport.close);
        await _makeUncertain(h, transport, first);
        await _expectSharedJournalBlocks(
          h,
          transport,
          second,
          suffix: 'cross-family',
        );
        expect(
          h.journal.entries(mr6b3Account).single.state,
          AiJournalState.writeUncertain,
        );
        expect(transport.mutations, 1);
      });
    }
  }

  for (final pair in [
    ('markTodoDone', 'snoozeTodo'),
    ('snoozeTodo', 'markTodoDone'),
    ('deleteNote', 'deleteWorkItemActivityNote'),
    ('deleteWorkItemActivityNote', 'deleteNote'),
  ]) {
    test('§15 row 5 REST/graph ${pair.$1} isolates ${pair.$2}', () async {
      final h = await _harness();
      final transport = _Transport(h);
      addTearDown(transport.close);
      final firstPrepared = await transport.port.prepare(
        _request(pair.$1, 'alias-first'),
      );
      final secondPrepared = await transport.port.prepare(
        _request(pair.$2, 'alias-second'),
      );
      expect(
        firstPrepared.writeKeys.any(
          (a) => secondPrepared.writeKeys.any(a.intersects),
        ),
        isTrue,
      );
      await _makeUncertain(h, transport, pair.$1);
      await _expectSharedJournalBlocks(h, transport, pair.$2, suffix: 'alias');
      expect(transport.mutations, 1);
    });
  }
}

Future<Mr6b3ApiHarness> _harness() async {
  final h = await Mr6b3ApiHarness.create(oauth: false);
  h.server.applyMutations = false;
  addTearDown(h.dispose);
  return h;
}

Future<AiWriteOutcome> _makeUncertain(
  Mr6b3ApiHarness h,
  _Transport transport,
  String operation,
) async {
  final coordinator = _peer(h, transport, 'uncertain-$operation');
  final proposal = await coordinator.propose(_call(operation, 'uncertain'));
  expect(
    proposal,
    isNotNull,
    reason: coordinator.outcomeFor('uncertain')?.reasonCode,
  );
  final outcome = await coordinator
      .approve(proposal!, typedName: proposal.tier.typedName)
      .timeout(mr6b3Timeout);
  expect(
    outcome.state,
    AiJournalState.writeUncertain,
    reason: outcome.reasonCode,
  );
  expect(outcome.mutationCount, 1);
  return outcome;
}

Future<void> _expectSharedJournalBlocks(
  Mr6b3ApiHarness h,
  _Transport transport,
  String operation, {
  required String suffix,
  AiWriteJournal? journal,
}) async {
  final coordinator = _peer(
    h,
    transport,
    'peer-$suffix-$operation',
    journal: journal,
  );
  final call = _call(operation, 'fresh-tool-id-$suffix');
  expect(
    await coordinator.propose(call).timeout(mr6b3Timeout),
    isNull,
    reason: '$operation must stay isolated across conversations',
  );
  expect(coordinator.outcomeFor(call.id)?.reasonCode, 'isolated');
}

Map<String, Object?> _arguments(String operation) => switch (operation) {
  'markTodoDone' => {'todoId': 400},
  'deleteNote' => {
    'projectId': 9,
    'resource': 'issues',
    'iid': 3,
    'noteId': 401,
  },
  _ => mr6b3ApiArguments(operation),
};

AiToolCall _call(String operation, String id) => AiToolCall(
  id: id,
  name: operation,
  arguments: {
    ..._arguments(operation),
    'reason': 'synthetic isolation request',
  },
);

write_port.AiWriteRequest _request(String operation, String execution) =>
    write_port.AiWriteRequest(
      operationId: operation,
      executionId: execution,
      scope: mr6b3Scope,
      arguments: _arguments(operation),
    );

PolicyAiWriteCoordinator _peer(
  Mr6b3ApiHarness h,
  _Transport transport,
  String conversation, {
  AiWriteJournal? journal,
}) {
  final budget = AiToolBudget(maxGitLabRequests: 40);
  final coordinator = PolicyAiWriteCoordinator(
    releasePolicy: fixtureReleasePolicy,
    snapshot: () => AiWritePolicySnapshot(
      appInForeground: true,
      scope: mr6b3Scope,
      level: AiAutonomyLevel.lowRiskAuto,
      ceiling: AiAutonomyLevel.bypass,
      consentHash: 'mr6b3-consent',
      writePolicyRevision: 1,
      scopeRevision: 1,
      sessionGeneration: 7,
    ),
    createPort: () => transport.port,
    journal: journal ?? h.journal,
    conversationId: conversation,
    budget: () => budget,
    readFreshness: (_) async => const AiWriteFreshness(
      updatedAt: mr6b3Revision,
      visibilityUnreadable: false,
    ),
    placeholders: text.UploadPlaceholderTable(instance: transport.api.instance),
    knownSecrets: () => const {},
    safeDisplay: (v) => v,
    now: () => DateTime.utc(2026, 10, 23, 12),
    httpCost: (op) => aiWriteRequestAllowance(op, oauthReplay: false),
  );
  coordinator.beginRun('Update #3 in team/example-9.');
  coordinator.beginTurn();
  addTearDown(() => coordinator.stop('testEnd'));
  return coordinator;
}

// An async adapter wrapper reuses all graph payloads from the existing server.
// REST aliases and re-read views are supplied here; every write returns 5xx.
final class _Transport {
  _Transport(this.h) {
    adapter = FakeAdapter(_respond);
    api = testApi(adapter);
    port = write_port.GitLabAiWritePort(
      api,
      accountKey: mr6b3Account,
      workItemWriteRegistry: h.server.writePort.workItemWriteRegistry,
    );
  }
  final Mr6b3ApiHarness h;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final write_port.GitLabAiWritePort port;
  final entered = Completer<void>();
  final _release = Completer<void>();
  bool hold = false;
  int mutations = 0;
  RequestOptions? delayedMutation;
  bool todoPending = true;

  Future<void> landLate(String operation) async {
    final request = delayedMutation!;
    // Apply the captured original request at the fake server, without a new
    // client fetch. This models late landing after the uncertain Future ended.
    h.server.applyMutations = true;
    await h.server.adapter.respond(request);
    h.server.applyMutations = false;
    if (operation == 'snoozeTodo') todoPending = false;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  void close() {
    release();
    api.close();
  }

  Future<ResponseBody> _respond(RequestOptions request) async {
    final data = request.data;
    final graph = data is Map ? data['query'] : null;
    final mutation = graph is String
        ? graph.startsWith('mutation ')
        : request.method != 'GET';
    if (mutation) {
      mutations++;
      delayedMutation = request;
      if (graph is String && !hold) await h.server.adapter.respond(request);
      if (!entered.isCompleted) entered.complete();
      if (hold) await _release.future.timeout(mr6b3Timeout);
      return jsonResponse({
        'message': 'synthetic uncertain response',
      }, status: 500);
    }
    final path = request.uri.path;
    if (path.endsWith('/api/v4/todos')) {
      return jsonResponse(
        todoPending
            ? [
                {
                  'id': 400,
                  'target_type': 'Issue',
                  'project': {'id': 9},
                  'target': {'iid': 3},
                },
              ]
            : <Object?>[],
      );
    }
    if (path.endsWith('/projects/9/issues/3/notes/401')) {
      return jsonResponse({
        'id': 401,
        'body': 'Synthetic note',
        'updated_at': h.server.noteUpdatedAt,
        'author': {'username': 'synthetic'},
      });
    }
    if (path.endsWith('/projects/9/issues/3')) {
      return jsonResponse({
        'id': 31,
        'iid': 3,
        'project_id': 9,
        'state': h.server.workItemState == 'CLOSED' ? 'closed' : 'opened',
        'updated_at': mr6b3Revision,
      });
    }
    return await h.server.adapter.respond(request);
  }
}
