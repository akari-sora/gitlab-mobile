import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'mr6b3g_support.dart';
import 'mr6b3_support.dart';

// The complete contract set is pinned independently of production rows.
const groupStateContractOperations = <String>{'updateGroupWorkItemState'};

const groupStateStageOperations = <String>{'updateGroupWorkItemState'};

const _operation = 'updateGroupWorkItemState';
const _workItemId = 'gid://gitlab/WorkItem/91';

port.AiWriteRequest _request({
  AiWriteScope scope = g0eScope,
  Map<String, Object?> arguments = const {
    'groupId': 7,
    'iid': 5,
    'stateEvent': 'close',
  },
}) => port.AiWriteRequest(
  operationId: _operation,
  executionId: 'gp2-state-seam',
  scope: scope,
  arguments: arguments,
);

Map<String, Object?> _namespace() => {
  'id': 'gid://gitlab/Group/7',
  'fullPath': g0ePath,
  'workItem': {
    'id': _workItemId,
    'iid': '5',
    'title': 'Synthetic group state item',
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': '2026-10-02T00:00:00Z',
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath},
    'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Task'},
    'widgets': <Object?>[],
  },
};

// Check recorded traffic outside the responder: Dio can wrap a responder's
// assertion failure as an API error, which a refusal matcher could accept.
void _expectResolverReads(FakeAdapter adapter, int count) {
  expect(adapter.requests, hasLength(count));
  for (final (index, request) in adapter.requests.indexed) {
    expect(request.method, index == 0 ? 'GET' : 'POST');
    expect(
      request.uri.toString(),
      index == 0
          ? 'https://example.com/gitlab/api/v4/user'
          : 'https://example.com/gitlab/api/graphql',
    );
    if (index == 0) continue;
    final body = request.data! as Map;
    expect(body.keys, unorderedEquals(['query', 'variables']));
    expect(body['query'], namespaceWorkItemQuery);
    expect(body['variables'], {'path': g0ePath, 'iid': '5'});
  }
}

const _revision = '2026-10-02T00:00:00Z';
const _nextRevision = '2026-10-02T01:00:00Z';
const _args = <String, Object?>{'groupId': 7, 'iid': 5, 'stateEvent': 'close'};

final class _Server {
  _Server({bool oauth = false, this.challengeRead = 0}) {
    adapter = FakeAdapter(_respond);
    if (oauth) {
      final dio = Dio()..httpClientAdapter = adapter;
      api = GitLabApi(
        instance: g0eScope.resolvedInstance!,
        credential: const OAuthCredential(
          accessToken: 'synthetic-access',
          refreshToken: 'synthetic-refresh',
          clientId: 'synthetic-client',
        ),
        dio: dio,
        oauth: OAuthTokenClient(
          instance: g0eScope.resolvedInstance!,
          clientId: 'synthetic-client',
          dio: dio,
        ),
      );
    } else {
      api = testApi(adapter);
    }
    currentApi = api;
    writePort = port.GitLabAiWritePort(
      api,
      accountKey: g0eAccount,
      sessionGeneration: 7,
      isCurrent: () =>
          live &&
          generation == 7 &&
          currentAccount == g0eAccount &&
          identical(currentApi, api),
    );
  }
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writePort;
  Object? currentApi;
  String currentAccount = g0eAccount;
  int generation = 7;
  bool live = true;
  String state = 'OPEN';
  String revision = _revision;
  bool canUpdate = true;
  String? stateOverride;
  String? openingRevision;
  int mutations = 0;
  int stateReads = 0;
  int namespaceReads = 0;
  int groupReads = 0;
  int actorReads = 0;
  int readAttempts = 0;
  int refreshes = 0;
  int challengeRead;
  bool challenged = false;
  String? corruptionPhase;
  String? corruption;
  final corruptions = <String, int>{};
  int? mutationStatus;
  int? readbackStatus;
  bool payloadErrors = false;
  void Function()? onMutation;
  void Function(int)? onStateRead;
  Completer<void>? mutationEntered;
  Completer<void>? releaseMutation;

  Map<String, Object?> node({bool detail = false}) => {
    'id': _workItemId,
    'iid': '5',
    'state': stateOverride ?? state,
    'updatedAt': detail ? revision : openingRevision ?? revision,
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath},
    'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Task'},
    'userPermissions': {'updateWorkItem': canUpdate},
    if (detail) ...{
      'title': 'Synthetic group item',
      'createdAt': '2026-10-01T00:00:00Z',
      'widgets': <Object?>[],
    },
  };
  void corrupt(Map<String, Object?> item, String phase) {
    if (corruptionPhase != phase || corruption == null) return;
    corruptions.update(phase, (count) => count + 1, ifAbsent: () => 1);
    switch (corruption) {
      case 'missing project':
        item.remove('project');
      case 'project owner':
        item['project'] = {'id': 'gid://gitlab/Project/7', 'fullPath': g0ePath};
      case 'missing namespace':
        item.remove('namespace');
      case 'null namespace':
        item['namespace'] = null;
      case 'foreign namespace':
        item['namespace'] = {'id': 'gid://gitlab/Group/8', 'fullPath': g0ePath};
      case 'foreign path':
        item['namespace'] = {
          'id': 'gid://gitlab/Group/7',
          'fullPath': 'team/other',
        };
      case 'different iid':
        item['iid'] = '6';
      case 'different id':
        item['id'] = 'gid://gitlab/WorkItem/92';
      case 'different type':
        item['workItemType'] = {'id': 'gid://gitlab/WorkItems::Type/2'};
      case 'wrong state':
        item['state'] = state == 'OPEN' ? 'CLOSED' : 'OPEN';
    }
  }

  Future<ResponseBody> _respond(RequestOptions request) async {
    if (request.uri.path.endsWith('/oauth/token')) {
      refreshes++;
      return jsonResponse({
        'access_token': 'synthetic-rotated',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
      });
    }
    final data = request.data;
    final query = data is Map ? data['query'] as String? ?? '' : '';
    if (query.startsWith('mutation ')) {
      mutations++;
      onMutation?.call();
      mutationEntered?.complete();
      if (releaseMutation != null) await releaseMutation!.future;
      if (mutationStatus != null) {
        return jsonResponse({
          'message': 'synthetic failure',
        }, status: mutationStatus!);
      }
      final input = ((data! as Map)['variables'] as Map)['input'] as Map;
      if (!payloadErrors) {
        state = input['stateEvent'] == 'CLOSE' ? 'CLOSED' : 'OPEN';
        revision = _nextRevision;
      }
      final item = node();
      corrupt(item, 'ack');
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': payloadErrors ? ['synthetic'] : <Object?>[],
            'workItem': item,
          },
        },
      });
    }
    readAttempts++;
    if (challengeRead == readAttempts && !challenged) {
      challenged = true;
      return jsonResponse({'message': 'synthetic expired read'}, status: 401);
    }
    if (request.method == 'GET' && request.uri.path.endsWith('/user')) {
      actorReads++;
      return jsonResponse({
        'id': 7,
        'username': 'synthetic',
        'name': 'Synthetic',
      });
    }
    if (request.method == 'GET' && request.uri.path.endsWith('/groups/7')) {
      groupReads++;
      return jsonResponse({
        'id': 7,
        'full_path': g0ePath,
        'visibility': 'private',
      });
    }
    if (query == namespaceWorkItemQuery) {
      namespaceReads++;
      final item = node(detail: true);
      corrupt(item, 'namespace');
      return jsonResponse({
        'data': {
          'namespace': {
            'id': 'gid://gitlab/Group/7',
            'fullPath': g0ePath,
            'workItem': item,
          },
        },
      });
    }
    if (query.startsWith('query MobileWorkItemState(')) {
      stateReads++;
      onStateRead?.call(stateReads);
      if (mutations > 0 && readbackStatus != null) {
        return jsonResponse({'message': 'synthetic'}, status: readbackStatus!);
      }
      final item = node();
      final phase = switch (stateReads) {
        1 => 'opening',
        2 => 'dispatch',
        3 => 'preflight',
        _ => 'readback',
      };
      corrupt(item, phase);
      return jsonResponse({
        'data': {'workItem': item},
      });
    }
    throw StateError(
      'Unexpected synthetic route ${request.method} ${request.uri.path}: $query',
    );
  }
}

final class _Harness {
  _Harness(this.base, this.server, {bool patAllowance = false}) {
    coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: g0eScope,
        level: base.policy.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'gp2-test',
        writePolicyRevision: base.policy.revision,
        scopeRevision: 1,
        sessionGeneration: 7,
        ownerApi: server.api,
        alive: base.policy.alive,
        consentValid: base.policy.consentValid,
        clientMayStart:
            base.policy.clientMayStart && server.api.mayStartRequest,
        appInForeground: true,
        currentResource: AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: 7,
          groupFullPath: g0ePath,
          iid: 5,
        ),
      ),
      createPort: () => server.writePort,
      journal: base.journal,
      conversationId: mr6b3Conversation,
      budget: () => base.budget,
      readFreshness: (_) async {
        final group = await server.api.group(7);
        if (group['id'] != 7 || group['full_path'] != g0ePath) {
          throw const port.AiWriteRefused('workItemUnverifiable');
        }
        return const AiWriteFreshness(
          targetVisibility: 'private',
          visibilityUnreadable: true,
        );
      },
      placeholders: text.UploadPlaceholderTable(
        instance: server.api.instance,
        accountKey: g0eAccount,
        conversationId: mr6b3Conversation,
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const G0eLedger(),
      now: () => base.clock,
      httpCost: patAllowance
          ? (op) => aiWriteRequestAllowance(op, oauthReplay: false)
          : null,
    );
    beginRun();
  }
  static Future<_Harness> create({
    bool oauth = false,
    int challengeRead = 0,
    bool patAllowance = false,
  }) async {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
    final harness = _Harness(
      await Mr6b3Harness.create(),
      _Server(oauth: oauth, challengeRead: challengeRead),
      patAllowance: patAllowance,
    );
    addTearDown(harness.dispose);
    return harness;
  }

  final Mr6b3Harness base;
  final _Server server;
  late final PolicyAiWriteCoordinator coordinator;
  int calls = 0;
  void beginRun() {
    base.budget = AiToolBudget(maxGitLabRequests: 40);
    coordinator.beginRun('Close this group work item.');
    coordinator.beginTurn();
  }

  Future<AiWriteProposal?> propose({Map<String, Object?> args = _args}) =>
      coordinator
          .propose(
            AiToolCall(
              id: 'gp2-${calls++}',
              name: _operation,
              arguments: {...args, 'reason': 'Synthetic request'},
            ),
          )
          .timeout(mr6b3Timeout);
  Future<AiWriteOutcome> approve(AiWriteProposal proposal) => coordinator
      .approve(proposal, typedName: proposal.tier.typedName)
      .timeout(mr6b3Timeout);
  Future<void> dispose() async {
    if (server.releaseMutation != null &&
        !server.releaseMutation!.isCompleted) {
      server.releaseMutation!.complete();
    }
    coordinator.stop('disposed');
    server.api.close();
    await base.dispose();
  }
}

void _lifecycleTests() {
  for (final event in ['close', 'reopen']) {
    test(
      'production $event proves group owner through independent readback',
      () async {
        final h = await _Harness.create(patAllowance: true);
        h.server.state = event == 'close' ? 'OPEN' : 'CLOSED';
        final proposal = (await h.propose(
          args: {..._args, 'stateEvent': event},
        ))!;
        expect(proposal.tier.decision, AiGateDecision.requireApproval);
        expect((proposal.preview as port.AiFieldsPreview).fields, {
          'stateEvent': event,
        });
        expect(h.server.mutations, 0);
        h.server.onMutation = () => expect(
          h.base.journal.entries(g0eAccount).last.state,
          AiJournalState.dispatching,
        );
        final outcome = await h.approve(proposal);
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.readbackConfirmed, isTrue);
        expect(outcome.mutationCount, 1);
        expect(h.server.mutations, 1);
        expect(h.server.groupReads, 2);
        expect(h.server.actorReads, 2);
        expect(h.server.namespaceReads, 2);
        expect(h.server.stateReads, 4);
        expect(h.server.adapter.requests, hasLength(11));
        expect(h.base.budget.gitLabRequests, 11);
        final sends = h.server.adapter.requests
            .where(
              (r) =>
                  r.data is Map &&
                  ((r.data as Map)['query'] as String? ?? '').startsWith(
                    'mutation ',
                  ),
            )
            .toList();
        expect(sends, hasLength(1));
        final input =
            (((sends.single.data as Map)['variables'] as Map)['input'] as Map);
        expect(input, {
          'id': _workItemId,
          'stateEvent': event == 'close' ? 'CLOSE' : 'REOPEN',
        });
        final groups = h.server.adapter.requests.where(
          (r) => r.uri.path.endsWith('/groups/7'),
        );
        expect(
          groups.every(
            (r) => r.uri.queryParameters['with_projects'] == 'false',
          ),
          isTrue,
        );
      },
    );
  }
  test(
    'strict noop preflights without hooks or mutation and refunds write count',
    () async {
      final h = await _Harness.create();
      h.server.state = 'CLOSED';
      final outcome = await h.approve((await h.propose())!);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.noChange, isTrue);
      expect(outcome.mutationCount, 0);
      expect(h.server.mutations, 0);
      expect(h.server.stateReads, 3);
      expect(
        h.base.journal.entries(g0eAccount).last.state,
        AiJournalState.notExecuted,
      );
      expect(
        h.base.journal.conversationWriteCount(g0eAccount, mr6b3Conversation),
        0,
      );
      final prepared = await h.server.writePort.prepare(_request());
      var before = 0;
      var start = 0;
      prepared.bindGraphBeforeMutation(() async {
        before++;
      });
      final direct = await h.server.writePort.commit(
        prepared,
        mayStart: () {
          start++;
          return true;
        },
      );
      expect(direct, isA<port.AiGraphNoChange>());
      expect(before, 0);
      expect(start, 0);
    },
  );
  test(
    'prepared identity, journal, release name and digest bind the exact group',
    () async {
      final h = await _Harness.create();
      final first = await h.server.writePort.prepare(_request());
      expect(first.releaseName, '$g0ePath#5');
      expect(first.writeKeys.single.parts, [
        g0eAccount,
        'group:7',
        'workItem',
        '5',
      ]);
      expect(first.dependencyKeys, isEmpty);
      expect(first.groupIdentity!.workItemGid, _workItemId);
      expect(first.groupIdentity!.generation, 7);
      expect(first.bindingTargets.single.groupId, 7);
      expect(
        DateTime.parse(first.journal.updatedAt!),
        DateTime.parse(_revision),
      );
      expect((first.preview as port.AiFieldsPreview).fields, {
        'stateEvent': 'close',
      });
      h.server.state = 'CLOSED';
      final changed = await h.server.writePort.prepare(_request());
      expect(first.bindingDigest, isNot(changed.bindingDigest));
    },
  );
  for (final extra in <Map<String, Object?>>[
    {'projectId': 7},
    {'workItemGid': _workItemId},
    {'query': 'mutation x'},
    {'confirmName': 'team/sub#5'},
    {'expectedUpdatedAt': _revision},
    {'stateEvent': 'open'},
  ]) {
    test(
      'invalid or extra model field refuses before any write: $extra',
      () async {
        final h = await _Harness.create();
        await expectLater(
          h.server.writePort.prepare(_request(arguments: {..._args, ...extra})),
          throwsA(anyOf(isA<port.AiWriteRefused>(), isA<ApiFailure>())),
        );
        expect(h.server.adapter.requests, isEmpty);
      },
    );
  }
  for (final coords in <Map<String, Object?>>[
    {'groupId': 8, 'iid': 5, 'stateEvent': 'close'},
    {'groupId': 7, 'iid': 6, 'stateEvent': 'close'},
    {'groupId': 7, 'iid': 5, 'projectId': 7, 'stateEvent': 'close'},
  ]) {
    test(
      'real port refuses coordinates outside exact group grant: $coords',
      () async {
        final h = await _Harness.create();
        await expectLater(
          h.server.writePort.prepare(_request(arguments: coords)),
          throwsA(anyOf(isA<port.AiWriteRefused>(), isA<ApiFailure>())),
        );
        expect(h.server.mutations, 0);
        expect(h.server.namespaceReads, 0);
      },
    );
  }
  for (final scenario in [
    'missing project',
    'project owner',
    'missing namespace',
    'null namespace',
    'foreign namespace',
    'foreign path',
    'different iid',
    'different id',
    'different type',
  ]) {
    for (final phase in [
      'opening',
      'dispatch',
      'preflight',
      'ack',
      'readback',
    ]) {
      test(
        '$phase $scenario ${phase == 'ack' || phase == 'readback' ? 'is uncertain' : 'refuses before send'}',
        () async {
          final h = await _Harness.create();
          h.server.corruption = scenario;
          h.server.corruptionPhase = phase;
          final proposal = await h.propose();
          if (phase == 'opening') {
            expect(proposal, isNull);
            expect(h.server.mutations, 0);
            expect(h.server.stateReads, 1);
            expect(h.server.corruptions, {'opening': 1});
            return;
          }
          expect(proposal, isNotNull);
          expect(h.server.corruptions, isEmpty);
          final outcome = await h.approve(proposal!);
          expect(h.server.corruptions, {phase: 1});
          expect(h.server.stateReads, switch (phase) {
            'dispatch' => 2,
            'preflight' || 'ack' => 3,
            _ => 4,
          });
          final accepted = phase == 'ack' || phase == 'readback';
          expect(
            outcome.state,
            accepted
                ? AiJournalState.writeUncertain
                : AiJournalState.notExecuted,
          );
          expect(h.server.mutations, accepted ? 1 : 0);
          expect(outcome.readbackConfirmed, isFalse);
          if (accepted) {
            expect(
              h.base.journal.isolated(g0eAccount, {
                AiConflictKey([g0eAccount, 'group:7', 'workItem', '5']),
              }),
              isTrue,
            );
            h.beginRun();
            expect(await h.propose(), isNull);
            expect(h.server.mutations, 1);
          }
        },
      );
    }
  }
  test('noop with missing strict owner at preflight refuses', () async {
    final h = await _Harness.create();
    h.server.state = 'CLOSED';
    final proposal = (await h.propose())!;
    h.server.corruptionPhase = 'preflight';
    h.server.corruption = 'missing project';
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.noChange, isFalse);
    expect(h.server.mutations, 0);
    expect(h.server.stateReads, 3);
    expect(h.server.corruptions, {'preflight': 1});
  });
  for (final phase in ['opening', 'preflight']) {
    test('$phase revocation refuses without mutation', () async {
      final h = await _Harness.create();
      h.server.onStateRead = (n) {
        if (n == (phase == 'opening' ? 1 : 3)) h.server.live = false;
      };
      final proposal = await h.propose();
      if (phase == 'opening') {
        expect(proposal, isNull);
      } else {
        final outcome = await h.approve(proposal!);
        expect(outcome.state, AiJournalState.notExecuted);
      }
      expect(h.server.mutations, 0);
    });
  }
  for (final failure in ['payload', '401', '500', 'readback 401']) {
    test('accepted $failure stays uncertain and cannot retry', () async {
      final h = await _Harness.create();
      final proposal = (await h.propose())!;
      switch (failure) {
        case 'payload':
          h.server.payloadErrors = true;
        case '401':
          h.server.mutationStatus = 401;
        case '500':
          h.server.mutationStatus = 500;
        case 'readback 401':
          h.server.readbackStatus = 401;
      }
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.readbackConfirmed, isFalse);
      expect(h.server.mutations, 1);
      h.beginRun();
      expect(await h.propose(), isNull);
      expect(h.server.mutations, 1);
    });
  }

  for (final invalid in ['generation', 'account', 'api', 'revoked']) {
    test('production context $invalid refuses before HTTP', () async {
      final h = await _Harness.create();
      switch (invalid) {
        case 'generation':
          h.server.generation++;
        case 'account':
          h.server.currentAccount = 'https://example.com/gitlab#8';
        case 'api':
          h.server.currentApi = Object();
        case 'revoked':
          h.server.live = false;
      }
      await expectLater(
        h.server.writePort.prepare(_request()),
        throwsA(isA<port.AiWriteRefused>()),
      );
      expect(h.server.adapter.requests, isEmpty);
    });
  }
  for (final phase in ['opening', 'preflight']) {
    test('$phase epoch invalidation refuses before mutation', () async {
      final h = await _Harness.create();
      h.server.onStateRead = (n) {
        if (n == (phase == 'opening' ? 1 : 3)) h.server.api.clearReadCache();
      };
      final proposal = await h.propose();
      if (phase == 'opening') {
        expect(proposal, isNull);
      } else {
        final outcome = await h.approve(proposal!);
        expect(outcome.state, AiJournalState.notExecuted);
      }
      expect(h.server.mutations, 0);
    });
  }
  test('session revoked after acceptance stays uncertain', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.server.onMutation = () {
      h.server.live = false;
    };
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.writeUncertain);
    expect(outcome.readbackConfirmed, isFalse);
    expect(h.server.mutations, 1);
    expect(h.server.stateReads, 3);
  });
  test('permission revoked at opening refuses before send', () async {
    final h = await _Harness.create();
    h.server.canUpdate = false;
    expect(await h.propose(), isNull);
    expect(h.server.stateReads, 1);
    expect(h.server.mutations, 0);
  });
  test('revision changed during approval invalidates the proposal', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.server.revision = _nextRevision;
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(h.server.mutations, 0);
  });
  test('opening revision mismatch fails closed', () async {
    final h = await _Harness.create();
    h.server.openingRevision = _nextRevision;
    expect(await h.propose(), isNull);
    expect(h.server.mutations, 0);
  });
  for (final invalid in ['wrong state', 'missing project']) {
    test('strict ack $invalid never becomes success', () async {
      final h = await _Harness.create();
      final proposal = (await h.propose())!;
      h.server.corruptionPhase = 'ack';
      h.server.corruption = invalid;
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.readbackConfirmed, isFalse);
      expect(h.server.mutations, 1);
    });
  }
  test('beforeMutation journal flush failure prevents dispatch', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.base.files.failWriteNumber = h.base.files.writeCount + 2;
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.reasonCode, 'journalUnavailable');
    expect(h.server.mutations, 0);
  });
  test('terminal journal flush failure keeps sent write isolated', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.server.onMutation = () {
      h.base.files.failWriteNumber = h.base.files.writeCount + 1;
    };
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.writeUncertain);
    expect(outcome.reasonCode, 'journalUnavailable');
    expect(h.server.mutations, 1);
  });
  test('policy loss at journal barrier prevents mutation', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    final entered = h.base.files.armBarrier(
      writesBeforeBarrier: 1,
      afterPersist: true,
    );
    final pending = h.approve(proposal);
    await entered;
    expect(h.server.mutations, 0);
    h.base.policy.revision++;
    h.base.files.releaseBarrier();
    final outcome = await pending;
    expect(outcome.state, AiJournalState.notExecuted);
    expect(h.server.mutations, 0);
  });
  test('double approval starts only one mutation', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.server.mutationEntered = Completer<void>();
    h.server.releaseMutation = Completer<void>();
    final first = h.approve(proposal);
    await h.server.mutationEntered!.future.timeout(mr6b3Timeout);
    final second = h.approve(proposal);
    h.server.releaseMutation!.complete();
    final outcomes = await Future.wait([first, second]);
    expect(outcomes.first.state, AiJournalState.succeeded);
    expect(h.server.mutations, 1);
  });
  test(
    'OAuth without challenges reserves 21 and sends 11 resource requests',
    () async {
      final h = await _Harness.create(oauth: true);
      final outcome = await h.approve((await h.propose())!);
      expect(outcome.state, AiJournalState.succeeded);
      expect(h.server.adapter.requests, hasLength(11));
      expect(h.base.budget.gitLabRequests, 21);
      expect(h.server.refreshes, 0);
    },
  );
  test(
    'OAuth freshness challenge is replayed before group context capture',
    () async {
      final h = await _Harness.create(oauth: true, challengeRead: 1);
      final outcome = await h.approve((await h.propose())!);
      expect(outcome.state, AiJournalState.succeeded);
      expect(h.server.refreshes, 1);
      expect(h.server.mutations, 1);
      expect(
        h.server.adapter.requests.where(
          (r) => !r.uri.path.endsWith('/oauth/token'),
        ),
        hasLength(12),
      );
      expect(h.base.budget.gitLabRequests, 21);
    },
  );
  test(
    'OAuth challenge after group context capture cannot revive the epoch',
    () async {
      final h = await _Harness.create(oauth: true, challengeRead: 4);
      expect(await h.propose(), isNull);
      expect(h.server.refreshes, 1);
      expect(h.server.mutations, 0);
      expect(h.server.adapter.requests.length, lessThanOrEqualTo(22));
    },
  );

  for (final challengedRead in [2, 3, 5, 6, 7, 8, 9, 10]) {
    test(
      'OAuth challenge at logical read $challengedRead respects epoch and cap',
      () async {
        final h = await _Harness.create(
          oauth: true,
          challengeRead: challengedRead,
        );
        final proposal = await h.propose();
        if (challengedRead <= 3) {
          expect(proposal, isNull);
          expect(h.server.mutations, 0);
        } else {
          final outcome = await h.approve(proposal!);
          if (challengedRead == 10) {
            expect(outcome.state, AiJournalState.succeeded);
            expect(outcome.readbackConfirmed, isTrue);
            expect(h.server.mutations, 1);
          } else {
            expect(outcome.state, AiJournalState.notExecuted);
            expect(h.server.mutations, 0);
          }
        }
        expect(h.server.refreshes, 1);
        expect(
          h.server.adapter.requests
              .where((r) => !r.uri.path.endsWith('/oauth/token'))
              .length,
          lessThanOrEqualTo(21),
        );
      },
    );
  }
  for (final available in [20, 21]) {
    test(
      'group static reservation with $available available requests',
      () async {
        final h = await _Harness.create();
        h.base.budget = AiToolBudget(maxGitLabRequests: available);
        final proposal = await h.propose();
        if (available == 20) {
          expect(proposal, isNull);
          expect(h.server.adapter.requests, isEmpty);
        } else {
          expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
        }
      },
    );
  }
  for (final used in [18, 19, 20]) {
    test('group 40 request boundary after $used reserved', () async {
      final h = await _Harness.create();
      expect(h.base.budget.reserve(requests: used, search: false), isNull);
      final proposal = await h.propose();
      if (used <= 19) {
        expect(proposal, isNotNull);
        expect(h.base.budget.gitLabRequests, used + 21);
        expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
      } else {
        expect(proposal, isNull);
        expect(h.server.adapter.requests, isEmpty);
      }
    });
  }
}

void main() {
  _lifecycleTests();
  test('G-P2 pins the complete visible state row and fixed cap', () {
    expect(groupStateContractOperations, {_operation});
    expect(groupStateStageOperations, {_operation});
    expect(
      aiGroupStateRows.map((row) => row.operationId).toSet(),
      groupStateStageOperations,
    );
    final row = productionAiLedger.find(_operation)!;
    expect(row.namedMethod, 'updateWorkItemState');
    expect(row.baseTier, AiWriteTier.t2);
    expect(row.scopeClass, AiScopeClass.groupWorkItem);
    expect(row.boundary, AiWriteBoundary.graph);
    expect(row.modelVisible, isTrue);
    expect(row.readback, isTrue);
    expect(row.arguments.keys.toSet(), {'groupId', 'iid', 'stateEvent'});
    expect(row.arguments.values.every((arg) => arg.required), isTrue);
    expect(row.arguments['groupId']!.type, AiArgType.integer);
    expect(row.arguments['iid']!.type, AiArgType.integer);
    expect(row.arguments['stateEvent']!.enumValues, ['close', 'reopen']);
    expect(row.httpCap, 21);
    expect(aiWriteRequestAllowance(_operation), 21);
    expect(aiWriteRequestAllowance(_operation, oauthReplay: false), 11);
    expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
    expect(aiGroupWorkItemWritesAreEnabled, isTrue);
  });

  for (final event in ['close', 'reopen']) {
    test(
      '$event producer without context refuses before any API request',
      () async {
        aiGroupWorkItemWritesEnabledForTesting = true;
        addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
        final adapter = FakeAdapter((request) {
          fail('An unavailable family must not make an API request.');
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final writePort = port.GitLabAiWritePort(api, accountKey: g0eAccount);
        await expectLater(
          writePort.prepare(
            _request(arguments: {'groupId': 7, 'iid': 5, 'stateEvent': event}),
          ),
          throwsA(
            isA<port.AiWriteRefused>().having(
              (failure) => failure.reason,
              'reason',
              'workItemUnverifiable',
            ),
          ),
        );
        expect(adapter.requests, isEmpty);
      },
    );
  }

  test(
    'strict resolver binds the exact group owner using U1 plus N1',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.method == 'GET') {
          expect(request.uri.path, '/gitlab/api/v4/user');
          return jsonResponse({'id': 7, 'username': 'synthetic'});
        }
        expect(request.method, 'POST');
        expect(request.uri.path, '/gitlab/api/graphql');
        final body = request.data! as Map;
        expect(body.keys, unorderedEquals(['query', 'variables']));
        expect(body['query'], namespaceWorkItemQuery);
        expect(body['variables'], {'path': g0ePath, 'iid': '5'});
        return jsonResponse({
          'data': {'namespace': _namespace()},
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      var current = true;
      final readEpoch = api.captureGroupReadEpoch().readEpoch;
      final location = await port.GitLabAiWritePort(
        api,
        accountKey: g0eAccount,
        sessionGeneration: 7,
        isCurrent: () => current,
      ).resolveGroupWorkItemForTesting(_request());
      expect(location.detail.summary.project, isNull);
      expect(location.identity.groupId, 7);
      expect(location.identity.iid, 5);
      expect(location.identity.workItemGid, _workItemId);
      expect(location.identity.apiOwner, same(api));
      expect(location.identity.generation, 7);
      expect(location.identity.readEpoch, readEpoch);
      expect(location.identity.keyParts, [
        g0eAccount,
        'group:7',
        'workItem',
        '5',
      ]);
      _expectResolverReads(adapter, 2);
      current = false;
      expect(location.isCurrent(), isFalse);
    },
  );

  final foreignResponses = <String, void Function(Map<String, Object?>)>{
    'foreign outer Group with the same path': (node) =>
        node['id'] = 'gid://gitlab/Group/8',
    'same iid with a different item owner': (node) =>
        (node['workItem']! as Map)['namespace'] = {
          'id': 'gid://gitlab/Group/8',
          'fullPath': g0ePath,
        },
    'same numeric project owner': (node) =>
        (node['workItem']! as Map)['project'] = {
          'id': 'gid://gitlab/Project/7',
          'fullPath': g0ePath,
        },
    'missing project evidence': (node) =>
        (node['workItem']! as Map).remove('project'),
    'missing namespace evidence': (node) =>
        (node['workItem']! as Map).remove('namespace'),
    'Group GID used as WorkItem GID': (node) =>
        (node['workItem']! as Map)['id'] = 'gid://gitlab/Group/7',
    'different iid in the granted group': (node) =>
        (node['workItem']! as Map)['iid'] = '6',
    'renamed group with the same numeric identity': (node) =>
        node['fullPath'] = 'team/renamed',
  };
  for (final entry in foreignResponses.entries) {
    test('strict resolver refuses ${entry.key} with no mutation', () async {
      final node = _namespace();
      entry.value(node);
      final adapter = FakeAdapter((request) {
        if (request.method == 'GET') {
          return jsonResponse({'id': 7, 'username': 'synthetic'});
        }
        expect((request.data! as Map)['query'], namespaceWorkItemQuery);
        return jsonResponse({
          'data': {'namespace': node},
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        port.GitLabAiWritePort(
          api,
          accountKey: g0eAccount,
          sessionGeneration: 7,
          isCurrent: () => true,
        ).resolveGroupWorkItemForTesting(_request()),
        throwsA(anyOf(isA<port.AiWriteRefused>(), isA<ApiFailure>())),
      );
      _expectResolverReads(adapter, 2);
    });
  }

  for (final arguments in <Map<String, Object?>>[
    {'groupId': 8, 'iid': 5, 'stateEvent': 'close'},
    {'groupId': 7, 'iid': 6, 'stateEvent': 'close'},
    {'groupId': 7, 'projectId': 7, 'iid': 5, 'stateEvent': 'close'},
  ]) {
    test('out-of-grant coordinates $arguments never reach namespace', () async {
      final adapter = FakeAdapter((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/gitlab/api/v4/user');
        return jsonResponse({'id': 7, 'username': 'synthetic'});
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        port.GitLabAiWritePort(
          api,
          accountKey: g0eAccount,
          sessionGeneration: 7,
          isCurrent: () => true,
        ).resolveGroupWorkItemForTesting(_request(arguments: arguments)),
        throwsA(isA<port.AiWriteRefused>()),
      );
      _expectResolverReads(adapter, 1);
    });
  }

  for (final revokeAfter in [0, 1, 2]) {
    test('revoking the test caller after $revokeAfter reads refuses', () async {
      var reads = 0;
      var current = revokeAfter != 0;
      final adapter = FakeAdapter((request) {
        reads++;
        if (reads == revokeAfter) current = false;
        if (request.method == 'GET') {
          return jsonResponse({'id': 7, 'username': 'synthetic'});
        }
        expect((request.data! as Map)['query'], namespaceWorkItemQuery);
        return jsonResponse({
          'data': {'namespace': _namespace()},
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        port.GitLabAiWritePort(
          api,
          accountKey: g0eAccount,
          sessionGeneration: 7,
          isCurrent: () => current,
        ).resolveGroupWorkItemForTesting(_request()),
        throwsA(anyOf(isA<port.AiWriteRefused>(), isA<ApiFailure>())),
      );
      _expectResolverReads(adapter, revokeAfter);
    });
  }
}
