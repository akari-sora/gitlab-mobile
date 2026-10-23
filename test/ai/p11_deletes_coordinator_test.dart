import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart'
    show GitLabAiWritePort;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show UploadPlaceholderTable;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b2_deletes_port_test.dart'
    show
        DeleteServer,
        deleteAccount,
        deleteCases,
        deleteGlobalScope,
        deleteScope;

const _timeout = Duration(seconds: 20);

// Only this test ledger exposes packet 11. Production stays hidden until p17.
final class _VisibleDeletes implements AiCapabilityLedger {
  const _VisibleDeletes();

  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || !deleteCases.containsKey(operationId)) return row;
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      namedMethod: row.namedMethod,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
      editableField: row.editableField,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    ...productionAiLedger.modelVisible,
    for (final op in deleteCases.keys) find(op)!,
  ];
}

final class _Fixture {
  _Fixture({this.oauthReplay = false});

  final bool oauthReplay;
  final server = DeleteServer();
  late final root = Directory.systemTemp.createTempSync('p11-deletes-');
  late final journal = AiWriteJournal(
    keys: MemoryAiJournalKeyStore(),
    applicationSupport: root,
    processId: 'p11-tests',
  );
  bool replayNext = false;
  int refreshes = 0;
  late final adapter = FakeAdapter((request) {
    if (request.uri.path.endsWith('/oauth/token')) {
      refreshes++;
      return jsonResponse({
        'access_token': 'synthetic-access-$refreshes',
        'refresh_token': 'synthetic-refresh-$refreshes',
        'token_type': 'bearer',
      });
    }
    if (oauthReplay && request.method == 'GET') {
      replayNext = !replayNext;
      if (replayNext) return jsonResponse({}, status: 401);
    }
    return server.respond(request);
  });
  late final dio = Dio()..httpClientAdapter = adapter;
  late final instance = GitLabInstance.parse('https://example.com/gitlab');
  late final api = oauthReplay
      ? GitLabApi(
          instance: instance,
          credential: const OAuthCredential(
            accessToken: 'synthetic-access',
            refreshToken: 'synthetic-refresh',
            clientId: 'synthetic-client',
          ),
          dio: dio,
          oauth: OAuthTokenClient(
            instance: instance,
            clientId: 'synthetic-client',
            dio: dio,
          ),
        )
      : GitLabApi(instance: instance, token: 'synthetic-token', dio: dio);
  final coordinators = <PolicyAiWriteCoordinator>[];
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  AiWriteScope scope = deleteScope;
  late PolicyAiWriteCoordinator coordinator;

  Future<void> initialize() async {
    await journal.recoverAfterAccountsLoaded([deleteAccount]);
    await journal.ensureInitialized(deleteAccount);
    newConversation();
  }

  void newConversation() {
    final budget = AiToolBudget();
    coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: scope,
        level: level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p11-synthetic-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        appInForeground: true,
      ),
      createPort: () => GitLabAiWritePort(api, accountKey: deleteAccount),
      journal: journal,
      conversationId: 'p11-conversation-${coordinators.length}',
      budget: () => budget,
      // Matches the integrated controller for new project operations: one
      // project freshness GET, with decision reads left to the family port.
      readFreshness: (request) async {
        final project = request.arguments['projectId'];
        if (project is int) await api.record(['projects', '$project']);
        return const AiWriteFreshness(visibilityUnreadable: false);
      },
      placeholders: UploadPlaceholderTable(instance: instance),
      knownSecrets: () => {},
      safeDisplay: (value) => value,
      ledger: const _VisibleDeletes(),
    );
    coordinators.add(coordinator);
    coordinator.beginRun('Apply this requested change in team/example-9');
    coordinator.beginTurn();
  }

  Future<AiWriteProposal?> propose(String op, {Map<String, Object?>? args}) =>
      coordinator
          .propose(
            AiToolCall(
              id: op,
              name: op,
              arguments: {
                ...?args ?? deleteCases[op]?.args,
                'reason': 'Synthetic user request',
              },
            ),
          )
          .timeout(_timeout);

  Future<AiWriteOutcome> approve(AiWriteProposal p, {String? typedName}) =>
      coordinator
          .approve(p, typedName: typedName ?? p.tier.typedName)
          .timeout(_timeout);

  int get mutations => adapter.requests
      .where((r) => r.method != 'GET' && !r.uri.path.endsWith('/oauth/token'))
      .length;

  Future<void> dispose() async {
    for (final c in coordinators) {
      for (final p in c.proposals) {
        await c.reject(p).timeout(_timeout);
      }
      c.stop('disposed');
    }
    api.close();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

void main() {
  late _Fixture f;
  setUp(() async {
    f = _Fixture();
    await f.initialize();
  });
  tearDown(() => f.dispose());

  for (final entry in deleteCases.entries) {
    test(
      'p11 coordinator ${entry.key} requires the pre-read typed name',
      () async {
        if (entry.key == 'markAllTodosDone') f.scope = deleteGlobalScope;
        final p = await f.propose(entry.key);
        expect(
          p,
          isNotNull,
          reason: '${f.coordinator.outcomeFor(entry.key)?.reasonCode}',
        );
        expect(p!.tier.tier, AiWriteTier.t4);
        expect(p.tier.decision, AiGateDecision.requireApproval);
        expect(p.tier.requiresTypedName, isTrue);
        expect(p.tier.typedName, entry.value.name);
        expect(p.releaseName, entry.value.release);
        expect(f.mutations, 0);
        final wrong = await f.approve(p, typedName: 'incorrect');
        expect(wrong.reasonCode, 'typedNameMismatch');
        expect(p.valid, isTrue);
        expect(f.mutations, 0);
        final result = await f.approve(p);
        expect(result.state, AiJournalState.succeeded);
        expect(f.mutations, 1);
      },
    );
  }

  test('p11 markAllTodosDone requires confirmation even at bypass', () async {
    f.scope = deleteGlobalScope;
    f.level = AiAutonomyLevel.bypass;
    final p = await f.propose('markAllTodosDone');
    expect(p, isNotNull);
    expect(p!.tier.decision, AiGateDecision.requireApproval);
    expect(p.tier.reasons, contains(AiFixedConfirmReason.markAllTodosDone));
    expect(p.tier.typedName, '@tester');
    expect(f.mutations, 0);
    expect((await f.approve(p)).state, AiJournalState.succeeded);
  });

  for (final operation in [
    'deleteLabel',
    'deleteMilestone',
    'deleteBoard',
    'deleteBoardList',
    'deleteNote',
    'deleteDiscussionNote',
  ]) {
    test('fix1 $operation stays unbound at bypass without an explicit target',
        () async {
      f.level = AiAutonomyLevel.bypass;
      final proposal = await f.propose(operation);
      expect(proposal, isNotNull);
      expect(proposal!.tier.decision, AiGateDecision.requireApproval);
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.targetUnbound),
      );
      expect(f.mutations, 0);
    });
  }

  const related = <String, Map<String, Object?>>{
    'createNote': {
      'projectId': 9,
      'resource': 'issues',
      'iid': 3,
      'body': 'synthetic',
    },
    'moveBoardCard': {
      'projectId': 9,
      'iid': 3,
      'fields': {'labels': 'ready'},
    },
  };
  for (final entry in related.entries) {
    for (final deleteFirst in [true, false]) {
      test(
        'p11 uncertain issue blocks ${entry.key} in both directions deleteFirst=$deleteFirst',
        () async {
          final first = deleteFirst ? 'deleteIssue' : entry.key;
          final second = deleteFirst ? entry.key : 'deleteIssue';
          f.server.failureStatus = 500;
          final p = await f.propose(
            first,
            args: deleteFirst ? null : entry.value,
          );
          expect(
            p,
            isNotNull,
            reason: '${f.coordinator.outcomeFor(first)?.reasonCode}',
          );
          expect((await f.approve(p!)).state, AiJournalState.writeUncertain);
          f.server.failureStatus = null;
          f.newConversation();
          expect(
            await f.propose(second, args: deleteFirst ? entry.value : null),
            isNull,
          );
          expect(f.coordinator.outcomeFor(second)?.reasonCode, 'isolated');
          expect(f.mutations, 1);
        },
      );
    }
  }

  for (final first in ['deleteBoard', 'deleteBoardList', 'moveBoardList']) {
    test('p11 uncertain $first blocks the shared board key', () async {
      f.server.failureStatus = 500;
      final p = await f.propose(
        first,
        args: first == 'moveBoardList'
            ? {'projectId': 9, 'boardId': 8, 'listId': 6, 'position': 1}
            : null,
      );
      expect(p, isNotNull);
      expect((await f.approve(p!)).state, AiJournalState.writeUncertain);
      f.newConversation();
      final second = first == 'deleteBoardList'
          ? 'moveBoardList'
          : 'deleteBoardList';
      expect(
        await f.propose(
          second,
          args: second == 'moveBoardList'
              ? {'projectId': 9, 'boardId': 8, 'listId': 6, 'position': 1}
              : null,
        ),
        isNull,
      );
      expect(f.coordinator.outcomeFor(second)?.reasonCode, 'isolated');
      expect(f.mutations, 1);
    });
  }

  for (final allFirst in [true, false]) {
    test(
      'p11 account todo prefix blocks single todos allFirst=$allFirst',
      () async {
        f.scope = deleteGlobalScope;
        f.server.failureStatus = 500;
        final first = allFirst ? 'markAllTodosDone' : 'markTodoDone';
        final second = allFirst ? 'markTodoDone' : 'markAllTodosDone';
        final p = await f.propose(
          first,
          args: allFirst ? null : {'todoId': 18},
        );
        expect(p, isNotNull);
        expect((await f.approve(p!)).state, AiJournalState.writeUncertain);
        f.newConversation();
        expect(
          await f.propose(second, args: allFirst ? {'todoId': 18} : null),
          isNull,
        );
        expect(f.coordinator.outcomeFor(second)?.reasonCode, 'isolated');
        expect(f.mutations, 1);
      },
    );
  }

  test('p11 changed revision invalidates approval before deletion', () async {
    final p = (await f.propose('deleteIssue'))!;
    f.server.updatedAt = '2026-10-23T01:00:00Z';
    expect((await f.approve(p)).reasonCode, 'targetChanged');
    expect(f.mutations, 0);
  });

  test('p11 renamed target invalidates the original typed name', () async {
    final p = (await f.propose('deleteLabel'))!;
    f.server.overrides['projects/9/labels/8'] = {'id': 8, 'name': 'renamed'};
    expect((await f.approve(p)).reasonCode, 'targetChanged');
    expect(f.mutations, 0);
  });

  for (final entry in deleteCases.entries) {
    test(
      'p11 ${entry.key} actual OAuth replay HTTP count matches independent cap',
      () async {
        await f.dispose();
        f = _Fixture(oauthReplay: true);
        await f.initialize();
        if (entry.key == 'markAllTodosDone') f.scope = deleteGlobalScope;
        final p = await f.propose(entry.key);
        expect(
          p,
          isNotNull,
          reason: '${f.coordinator.outcomeFor(entry.key)?.reasonCode}',
        );
        expect((await f.approve(p!)).state, AiJournalState.succeeded);
        final apiRequests = f.adapter.requests
            .where((r) => !r.uri.path.endsWith('/oauth/token'))
            .toList();
        expect(
          f.refreshes,
          2 *
              (entry.value.prepareGets +
                  (entry.key == 'markAllTodosDone' ? 0 : 1)),
        );
        expect(apiRequests.length, entry.value.cap);
        expect(
          apiRequests.length,
          lessThanOrEqualTo(productionAiLedger.find(entry.key)!.httpCap),
        );
        expect(f.mutations, 1);
      },
    );
  }
}
