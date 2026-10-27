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

import '../support/fake_adapter.dart';
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

// Plan v6 §15 row 5: 「停止後原寫入仍在途（`dispatching`）時，另一段對話
// 對同一 MR 的提議被擋；換 nonce、換 tool-call ID、換段、從紀錄恢復後重提
// 都被擋；兩種 scope 或 REST 與 GraphQL 兩種入口指向同一資源被擋」。
// 「重新讀取」只產生觀察，隔離維持；「原請求在途時不提供讀取」；
// 「手動解除需要輸入依 key 種類決定的確認名稱」。
// These are graph-family scenarios, including the real REST alias prepares.

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
      // A read through the real port is an observation, never an unlock.
      await transport.port.prepare(_request(operation, 'read-while-in-flight'));
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
      await h.journal.recordObservation(
        executionId: entry.executionId,
        summary: 'Fresh fixed reads still show the old synthetic state.',
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
      expect(
        recovered.entries(mr6b3Account).single.observation,
        contains('old synthetic state'),
      );
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
}) async {
  final coordinator = _peer(h, transport, 'peer-$suffix-$operation');
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
    snapshot: () => AiWritePolicySnapshot(
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
// Only the two REST alias routes are supplied here; every write returns 5xx.
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
      if (graph is String) await h.server.adapter.respond(request);
      if (!entered.isCompleted) entered.complete();
      if (hold) await _release.future.timeout(mr6b3Timeout);
      return jsonResponse({
        'message': 'synthetic uncertain response',
      }, status: 500);
    }
    final path = request.uri.path;
    if (path.endsWith('/api/v4/todos')) {
      return jsonResponse([
        {
          'id': 400,
          'target_type': 'Issue',
          'project': {'id': 9},
          'target': {'iid': 3},
        },
      ]);
    }
    if (path.endsWith('/projects/9/issues/3/notes/401')) {
      return jsonResponse({
        'id': 401,
        'body': 'Synthetic note',
        'updated_at': mr6b3Revision,
        'author': {'username': 'synthetic'},
      });
    }
    if (path.endsWith('/projects/9/issues/3')) {
      return jsonResponse({
        'id': 31,
        'iid': 3,
        'project_id': 9,
        'updated_at': mr6b3Revision,
      });
    }
    return await h.server.adapter.respond(request);
  }
}
