import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'ai_write_port_test.dart' as rest_fixture;
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart';
import 'mr6b3g_budget_test.dart' as group_fixture;

const _key = AiConflictKey([g0eAccount, 'group:7', 'workItem', '5']);
const _note = AiConflictKey([
  g0eAccount,
  'group:7',
  'workItem',
  '5',
  'notes',
  '12',
]);
const _project = AiConflictKey([g0eAccount, 'project:7', 'workItem', '5']);

Future<void> _uncertain(
  AiWriteJournal journal, {
  String id = 'uncertain',
}) async {
  await journal.prepare(
    draft: AiJournalDraft(
      executionId: id,
      accountKey: g0eAccount,
      conversationId: 'conversation-a',
      runId: 'run-a',
      operationId: 'updateGroupWorkItemState',
      writeKeys: {_key},
      payloadSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      releaseName: '$g0ePath#5',
    ),
  );
  await journal.markDispatching(executionId: id);
  await journal.finish(
    executionId: id,
    terminal: AiJournalState.writeUncertain,
  );
}

void main() {
  for (final operation in group_fixture.g15LogicalReads.keys) {
    test('real $operation preparation locks the exact group parent', () async {
      aiGroupWorkItemWritesEnabledForTesting = true;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      final h = await group_fixture.G15Harness.create();
      addTearDown(h.dispose);
      final prepared = await h.server.writer.prepare(
        port.AiWriteRequest(
          operationId: operation,
          executionId: 'g15-parent-$operation',
          scope: g0eScope,
          arguments: group_fixture.g15Arguments(operation),
        ),
      );
      expect(
        {
          ...prepared.writeKeys,
          ...prepared.dependencyKeys,
        }.any(group_fixture.g15Key.intersects),
        isTrue,
        reason: '$operation must conflict with the actual group WI parent',
      );
      expect(h.server.mutations, 0);
    });
  }

  test('real uncertain state blocks a different alias in a new run', () async {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
    final h = await group_fixture.G15Harness.create();
    addTearDown(h.dispose);
    h.server.mutationStatus = 500;
    final first = await h.propose('updateGroupWorkItemState');
    expect(first, isNotNull);
    final result = await h.approve(first!);
    expect(result.state, AiJournalState.writeUncertain);
    expect(result.mutationCount, 1);
    expect(h.server.mutations, 1);
    expect(h.base.journal.isolated(g0eAccount, {group_fixture.g15Key}), isTrue);
    h.coordinator.beginRun('Change the group work item title.');
    h.coordinator.beginTurn();
    final previousRequests = h.server.adapter.requests.length;
    final second = await h.propose('updateGroupWorkItemContent');
    expect(second, isNull);
    expect(h.coordinator.outcomeFor('g15-1')?.reasonCode, 'isolated');
    expect(h.server.mutations, 1);
    // The real coordinator performs the fresh opening before checking its
    // prepared keys against the journal. Those are reads, never a second send.
    final subsequent = h.server.adapter.requests.skip(previousRequests);
    expect(subsequent, hasLength(4));
    expect(
      subsequent.where(
        (request) =>
            request.data is Map &&
            ((request.data as Map)['query'] as String? ?? '').startsWith(
              'mutation ',
            ),
      ),
      isEmpty,
    );
  });

  test(
    'recovered journal blocks real group proposal from another coordinator',
    () async {
      aiGroupWorkItemWritesEnabledForTesting = true;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      final h = await group_fixture.G15Harness.create();
      addTearDown(h.dispose);
      h.server.mutationStatus = 500;
      final first = await h.propose('updateGroupWorkItemState');
      expect(first, isNotNull);
      final outcome = await h.approve(first!);
      expect(outcome.state, AiJournalState.writeUncertain);
      final recovered = AiWriteJournal(
        keys: h.base.keys,
        applicationSupport: h.base.root,
        files: h.base.files,
        processId: 'g15-real-restart',
      );
      await recovered.recoverAfterAccountsLoaded([g0eAccount]);
      final budget = AiToolBudget(maxGitLabRequests: 40);
      final peer = PolicyAiWriteCoordinator(
        snapshot: () => AiWritePolicySnapshot(
          scope: g0eScope,
          level: AiAutonomyLevel.confirmEach,
          ceiling: AiAutonomyLevel.bypass,
          consentHash: 'g15-recovered',
          writePolicyRevision: 1,
          scopeRevision: 1,
          sessionGeneration: 7,
          ownerApi: h.server.api,
          appInForeground: true,
          clientMayStart: h.server.api.mayStartRequest,
        ),
        createPort: () => h.server.writer,
        journal: recovered,
        conversationId: 'g15-other-conversation',
        budget: () => budget,
        readFreshness: (_) async {
          final group = await h.server.api.group(7);
          return AiWriteFreshness(
            targetVisibility: group['visibility'] as String?,
            visibilityUnreadable: true,
          );
        },
        placeholders: text.UploadPlaceholderTable(
          instance: h.server.api.instance,
        ),
        knownSecrets: () => const {},
        safeDisplay: (value) => value,
        ledger: const group_fixture.G15Ledger(),
        httpCost: (operation) =>
            aiWriteRequestAllowance(operation, oauthReplay: false),
      );
      addTearDown(peer.stop);
      peer.beginRun('Update the group work item title.');
      peer.beginTurn();
      final before = h.server.adapter.requests.length;
      final proposal = await peer.propose(
        AiToolCall(
          id: 'recovered-other-alias',
          name: 'updateGroupWorkItemContent',
          arguments: {
            ...group_fixture.g15Arguments('updateGroupWorkItemContent'),
            'reason': 'synthetic',
          },
        ),
      );
      expect(proposal, isNull);
      expect(peer.outcomeFor('recovered-other-alias')?.reasonCode, 'isolated');
      expect(h.server.mutations, 1);
      final subsequent = h.server.adapter.requests.skip(before);
      expect(subsequent, hasLength(4));
      expect(
        subsequent.where(
          (request) =>
              request.data is Map &&
              ((request.data as Map)['query'] as String? ?? '').startsWith(
                'mutation ',
              ),
        ),
        isEmpty,
      );
    },
  );
  test(
    'numeric group and project namespaces remain disjoint; a rename retains isolation',
    () async {
      final h = await Mr6b3Harness.create();
      addTearDown(h.dispose);
      final original = g0eIdentity(Object());
      final renamed = g0eIdentity(Object(), fullPath: 'renamed/sub');
      expect(original.keyParts, renamed.keyParts);
      expect(AiConflictKey(original.keyParts), _key);
      expect(AiConflictKey(renamed.keyParts).intersects(_note), isTrue);
      expect(AiConflictKey(renamed.keyParts).intersects(_project), isFalse);
      await _uncertain(h.journal);
      expect(
        h.journal.isolated(g0eAccount, {AiConflictKey(renamed.keyParts)}),
        isTrue,
      );
      expect(h.journal.isolated(g0eAccount, {_note}), isTrue);
      expect(h.journal.isolated(g0eAccount, {_project}), isFalse);
    },
  );

  test(
    'group-path release is exact and confirmation survives recovery',
    () async {
      final h = await Mr6b3Harness.create();
      addTearDown(h.dispose);
      await _uncertain(h.journal);
      final recovered = AiWriteJournal(
        keys: h.keys,
        applicationSupport: h.root,
        files: h.files,
        processId: 'g15-recovered',
      );
      await recovered.recoverAfterAccountsLoaded([g0eAccount]);
      expect(recovered.entries(g0eAccount).single.releaseName, '$g0ePath#5');
      for (final wrong in ['#5', 'team/renamed#5', '\u2068$g0ePath#5\u2069']) {
        await expectLater(
          recovered.releaseByUser(executionId: 'uncertain', typedName: wrong),
          throwsA(
            isA<AiJournalException>().having(
              (e) => e.reason,
              'reason',
              'confirmationRequired',
            ),
          ),
        );
        expect(recovered.isolated(g0eAccount, {_note}), isTrue);
      }
      await recovered.recordObservation(
        executionId: 'uncertain',
        summary: 'still visible',
      );
      expect(recovered.isolated(g0eAccount, {_key}), isTrue);
      await recovered.releaseByUser(
        executionId: 'uncertain',
        typedName: '$g0ePath#5',
      );
      expect(recovered.isolated(g0eAccount, {_note}), isFalse);
      expect(recovered.requiresConfirmation(g0eAccount, {_note}), isTrue);
    },
  );

  for (final operation in [
    'updateGroupWorkItemState',
    'updateGroupWorkItemContent',
  ]) {
    test(
      'fresh run and operation $operation cannot bypass uncertain group lock',
      () async {
        aiGroupWorkItemWritesEnabledForTesting = true;
        addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
        // G0eGraphPort is an explicit seam double; the real journal and
        // coordinator perform the isolation check.
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        await _uncertain(h.base.journal);
        h.beginRun('Update the group work item.');
        final call = h.call(
          operation,
          operation == 'updateGroupWorkItemState'
              ? {'stateEvent': 'close'}
              : {'description': 'Synthetic replacement'},
        );
        expect(await h.coordinator.propose(call), isNull);
        expect(h.coordinator.outcomeFor(call.id)?.reasonCode, 'isolated');
        expect(h.graph.mutations, 0);
      },
    );
  }

  test(
    'group-origin project item intersects real REST, GraphQL and board preparations',
    () async {
      final grant = projectIssueFromGroupPage(
        projectId: 9,
        projectPath: 'team/example-9',
        iid: 3,
      );
      final scope = AiWriteScope(accountKey: g0eAccount, grants: [grant]);
      final adapter = FakeAdapter(rest_fixture.preflight);
      final api = testApi(adapter);
      addTearDown(api.close);
      final realPort = port.GitLabAiWritePort(api, accountKey: g0eAccount);
      Future<port.AiWritePrepared> prepareRest(String operation) =>
          realPort.prepare(
            port.AiWriteRequest(
              operationId: operation,
              executionId: 'g15-$operation',
              scope: scope,
              arguments: const {
                'projectId': 9,
                'iid': 3,
                'fields': {'labels': 'synthetic'},
              },
            ),
          );
      final issue = await prepareRest('updateIssue');
      final board = await prepareRest('moveBoardCard');
      final graphHarness = await Mr6b3ApiHarness.create(oauth: false);
      addTearDown(graphHarness.dispose);
      final graph = await graphHarness.server.writePort.prepare(
        port.AiWriteRequest(
          operationId: 'updateWorkItemState',
          executionId: 'g15-graph',
          scope: scope,
          arguments: const {'projectId': 9, 'iid': 3, 'stateEvent': 'close'},
        ),
      );
      expect(issue.writeKeys.single, board.writeKeys.single);
      expect(issue.writeKeys.single.intersects(graph.writeKeys.single), isTrue);
      expect(issue.writeKeys.single.parts, [
        g0eAccount,
        'project:9',
        'workItem',
        '3',
      ]);
      expect(issue.writeKeys.single.intersects(_key), isFalse);
      expect(
        adapter.requests.every((request) => request.method == 'GET'),
        isTrue,
      );
      expect(graphHarness.server.mutations, 0);
      expect(
        scopeAdmits(
          scope,
          productionAiLedger.find('updateWorkItemState')!,
          AiTargetRef(kind: AiTargetKind.issue, projectId: 9, iid: 4),
        ),
        isFalse,
      );
    },
  );
}
