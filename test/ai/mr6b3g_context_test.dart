import 'release_policy_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as writes;
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart';

const _generation = 19;
const _operation = 'updateGroupWorkItemState';

Matcher get _unverifiable => throwsA(
  isA<writes.AiWriteRefused>().having(
    (failure) => failure.reason,
    'reason',
    'workItemUnverifiable',
  ),
);

writes.AiWriteRequest _request({
  String execution = 'g0g-context',
  AiWriteScope scope = g0eScope,
  Map<String, Object?> extra = const {},
}) => writes.AiWriteRequest(
  operationId: _operation,
  executionId: execution,
  scope: scope,
  arguments: {'groupId': 7, 'iid': 5, 'stateEvent': 'close', ...extra},
);

Map<String, Object?> _namespace() => {
  'id': 'gid://gitlab/Group/7',
  'fullPath': g0ePath,
  'workItem': {
    'id': 'gid://gitlab/WorkItem/91',
    'iid': '5',
    'title': 'Group item',
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': '2026-10-02T00:00:00Z',
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath},
    'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Task'},
    'widgets': <Object?>[],
  },
};

final class _ContextFixture {
  _ContextFixture({
    bool withContext = true,
    bool withGeneration = true,
    bool withPredicate = true,
    int generation = _generation,
  }) {
    adapter = FakeAdapter((request) {
      if (request.method == 'GET') {
        expect(request.uri.path, '/gitlab/api/v4/user');
        afterRead?.call();
        return jsonResponse({'id': actor, 'username': 'tester'});
      }
      expect(request.method, 'POST');
      expect(request.uri.path, '/gitlab/api/graphql');
      expect((request.data! as Map)['query'], namespaceWorkItemQuery);
      expect((request.data! as Map)['variables'], {
        'path': g0ePath,
        'iid': '5',
      });
      afterRead?.call();
      return jsonResponse({
        'data': {'namespace': _namespace()},
      });
    });
    api = testApi(adapter);
    currentApi = api;
    port = writes.GitLabAiWritePort.groupResolverForTesting(
      api,
      accountKey: g0eAccount,
      capability: const G0eLedger().find(_operation)!,
      sessionGeneration: withContext && withGeneration ? generation : null,
      isCurrent: withContext && withPredicate
          ? () =>
                live &&
                currentGeneration == generation &&
                identical(currentApi, api) &&
                currentAccount == g0eAccount
          : null,
      mutation: (hooks, isCurrent) async {
        if (!isCurrent()) {
          throw const writes.AiWriteRefused('workItemUnverifiable');
        }
        await hooks.beforeMutation();
        beforeStart?.call();
        if (!hooks.mayStart()) return const GraphWriteResult();
        mutations++;
        // The real transport advances the epoch at send/finish. Readback must
        // keep session ownership without rejecting this write's own change.
        api.clearReadCache();
        afterSend?.call();
        return GraphWriteResult(
          mutationSent: true,
          acknowledged: true,
          readbackVerified: isCurrent(),
        );
      },
    );
  }

  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final writes.GitLabAiWritePort port;
  Object? currentApi;
  int currentGeneration = _generation;
  String currentAccount = g0eAccount;
  int actor = 7;
  bool live = true;
  int mutations = 0;
  void Function()? afterRead;
  void Function()? beforeStart;
  void Function()? afterSend;
  void Function(int round)? onFreshness;
  int freshnessReads = 0;
  int _calls = 0;
  var budget = AiToolBudget(maxGitLabRequests: 40);

  Future<PolicyAiWriteCoordinator> coordinator(Mr6b3Harness base) async {
    final coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        scope: g0eScope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'g0g-test',
        writePolicyRevision: 1,
        sessionGeneration: _generation,
        ownerApi: api,
        appInForeground: true,
        currentResource: AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: 7,
          groupFullPath: g0ePath,
          iid: 5,
        ),
      ),
      createPort: () => port,
      journal: base.journal,
      conversationId: 'g0g-context',
      budget: () => budget,
      readFreshness: (_) async {
        freshnessReads++;
        onFreshness?.call(freshnessReads);
        return const AiWriteFreshness(
          targetVisibility: 'private',
          visibilityUnreadable: true,
        );
      },
      placeholders: text.UploadPlaceholderTable(
        instance: api.instance,
        accountKey: g0eAccount,
        conversationId: 'g0g-context',
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const G0eLedger(),
    );
    coordinator.beginRun('Close this group work item.');
    coordinator.beginTurn();
    addTearDown(coordinator.stop);
    return coordinator;
  }

  AiToolCall get call => AiToolCall(
    id: 'g0g-state-${_calls++}',
    name: _operation,
    arguments: const {
      'groupId': 7,
      'iid': 5,
      'stateEvent': 'close',
      'reason': 'Requested.',
    },
  );
}

_ContextFixture _fixture({bool withContext = true}) {
  final fixture = _ContextFixture(withContext: withContext);
  addTearDown(fixture.api.close);
  return fixture;
}

void main() {
  setUp(() {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  });

  test('core epoch snapshots revoke on invalidation and client close', () {
    final f = _fixture();
    final first = f.api.captureGroupReadEpoch();
    expect(first.isCurrent(), isTrue);
    f.api.clearReadCache();
    expect(first.isCurrent(), isFalse);
    final second = f.api.captureGroupReadEpoch();
    expect(second.readEpoch, greaterThan(first.readEpoch));
    expect(second.isCurrent(), isTrue);
    f.api.close();
    expect(second.isCurrent(), isFalse);
    expect(f.api.captureGroupReadEpoch().isCurrent(), isFalse);
    expect(f.adapter.requests, isEmpty);
  });

  test(
    'real dispatcher prepares nonzero-generation API-owned group identity',
    () async {
      final f = _fixture();
      final prepared = await f.port.prepare(_request());
      expect(prepared.groupIdentity!.generation, _generation);
      expect(prepared.groupIdentity!.apiOwner, same(f.api));
      expect(
        prepared.groupIdentity!.readEpoch,
        f.api.captureGroupReadEpoch().readEpoch,
      );
      expect(prepared.hasCurrentGroupIdentity, isTrue);
      expect(prepared.writeKeys.single.parts, prepared.groupIdentity!.keyParts);
      expect(f.adapter.requests, hasLength(2));
    },
  );

  test('real coordinator prepares both rounds and commits once', () async {
    final f = _fixture();
    final base = await Mr6b3Harness.create();
    addTearDown(base.dispose);
    final coordinator = await f.coordinator(base);
    final proposal = await coordinator.propose(f.call);
    expect(proposal, isNotNull);
    expect(f.adapter.requests, hasLength(2));
    final outcome = await coordinator.approve(proposal!);
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(outcome.readbackConfirmed, isTrue);
    expect(f.adapter.requests, hasLength(4));
    expect(f.mutations, 1);
  });

  final revocations = <String, void Function(_ContextFixture)>{
    'account switch': (f) => f.currentAccount = 'https://example.com/gitlab#8',
    'generation bump': (f) => f.currentGeneration++,
    'API replacement': (f) => f.currentApi = Object(),
    'API close': (f) => f.api.close(),
    'revoked session': (f) => f.live = false,
  };
  for (final entry in revocations.entries) {
    test('${entry.key} refuses proposal preparation before HTTP', () async {
      final f = _fixture();
      entry.value(f);
      await expectLater(f.port.prepare(_request()), _unverifiable);
      expect(f.adapter.requests, isEmpty);
      expect(f.mutations, 0);
    });

    test('${entry.key} rechecks dispatch preparation before HTTP', () async {
      final f = _fixture();
      final first = await f.port.prepare(_request());
      entry.value(f);
      await expectLater(
        f.port.prepare(_request(execution: 'g0g-dispatch')),
        _unverifiable,
      );
      expect(first.hasCurrentGroupIdentity, isFalse);
      expect(f.adapter.requests, hasLength(2));
      expect(f.mutations, 0);
    });
  }
  for (final entry in {
    ...revocations,
    'read epoch advance': (_ContextFixture f) => f.api.clearReadCache(),
  }.entries) {
    test(
      '${entry.key} blocks real coordinator dispatch without new HTTP',
      () async {
        final f = _fixture();
        final base = await Mr6b3Harness.create();
        addTearDown(base.dispose);
        final coordinator = await f.coordinator(base);
        final proposal = await coordinator.propose(f.call);
        expect(proposal, isNotNull);
        entry.value(f);
        final outcome = await coordinator.approve(proposal!);
        expect(outcome.state, isNot(AiJournalState.succeeded));
        expect(f.adapter.requests, hasLength(2));
        expect(f.mutations, 0);
      },
    );
  }

  test(
    'fresh openings recover on the same port after an epoch advance',
    () async {
      final f = _fixture();
      final first = await f.port.prepare(_request());
      f.api.clearReadCache();
      expect(first.hasCurrentGroupIdentity, isFalse);
      final next = await f.port.prepare(_request(execution: 'fresh-opening'));
      expect(
        next.groupIdentity!.readEpoch,
        greaterThan(first.groupIdentity!.readEpoch),
      );
      expect(next.hasCurrentGroupIdentity, isTrue);
      expect(f.adapter.requests, hasLength(4));
    },
  );

  test(
    'epoch advance during dispatch freshness refuses before resolver HTTP',
    () async {
      final f = _fixture();
      final base = await Mr6b3Harness.create();
      addTearDown(base.dispose);
      final coordinator = await f.coordinator(base);
      final proposal = await coordinator.propose(f.call);
      f.onFreshness = (round) {
        if (round == 2) f.api.clearReadCache();
      };
      final outcome = await coordinator.approve(proposal!);
      expect(outcome.reasonCode, 'workItemUnverifiable');
      expect(f.adapter.requests, hasLength(2));
      expect(f.mutations, 0);
      // A later proposal uses a fresh core snapshot on this same cached port.
      f.onFreshness = null;
      f.budget = AiToolBudget(maxGitLabRequests: 40);
      coordinator.beginRun('Close the group work item with fresh evidence.');
      coordinator.beginTurn();
      final next = await coordinator.propose(f.call);
      expect(next, isNotNull);
      final result = await coordinator.approve(next!);
      expect(result.state, AiJournalState.succeeded, reason: result.reasonCode);
      expect(f.adapter.requests, hasLength(6));
      expect(f.mutations, 1);
    },
  );

  test(
    'session revocation after send stays uncertain despite own epoch advance',
    () async {
      final f = _fixture();
      final base = await Mr6b3Harness.create();
      addTearDown(base.dispose);
      final coordinator = await f.coordinator(base);
      final proposal = await coordinator.propose(f.call);
      f.afterSend = () => f.currentGeneration++;
      final outcome = await coordinator.approve(proposal!);
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.readbackConfirmed, isFalse);
      expect(f.adapter.requests, hasLength(4));
      expect(f.mutations, 1);
    },
  );

  test(
    'no context refuses before HTTP in real dispatcher and resolver',
    () async {
      final f = _fixture(withContext: false);
      await expectLater(f.port.prepare(_request()), _unverifiable);
      await expectLater(
        f.port.resolveGroupWorkItemForTesting(_request()),
        _unverifiable,
      );
      expect(f.adapter.requests, isEmpty);
    },
  );

  test('partial or negative app context fails closed before HTTP', () async {
    for (final f in [
      _ContextFixture(withGeneration: false),
      _ContextFixture(withPredicate: false),
      _ContextFixture(generation: -1),
    ]) {
      addTearDown(f.api.close);
      await expectLater(f.port.prepare(_request()), _unverifiable);
      expect(f.adapter.requests, isEmpty);
    }
  });

  test('context cannot be supplied by model arguments', () async {
    final f = _fixture(withContext: false);
    final request = _request(
      extra: const {
        'generation': _generation,
        'sessionGeneration': _generation,
        'readEpoch': 0,
        'isCurrent': true,
        'apiOwner': 'model-declared-api',
      },
    );
    await expectLater(
      f.port.resolveGroupWorkItemForTesting(request),
      _unverifiable,
    );
    await expectLater(
      f.port.prepare(request),
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.validation,
        ),
      ),
    );
    expect(f.adapter.requests, isEmpty);
  });

  test(
    'resolver uses app context even when model supplies different coordinates',
    () async {
      final f = _fixture();
      final location = await f.port.resolveGroupWorkItemForTesting(
        _request(
          extra: const {
            'generation': 999,
            'readEpoch': 999,
            'isCurrent': false,
          },
        ),
      );
      expect(location.identity.generation, _generation);
      expect(
        location.identity.readEpoch,
        f.api.captureGroupReadEpoch().readEpoch,
      );
      expect(location.identity.apiOwner, same(f.api));
      expect(f.adapter.requests, hasLength(2));
    },
  );

  test(
    'accessor rejects another account or instance before actor HTTP',
    () async {
      final f = _fixture();
      for (final scope in [
        AiWriteScope(
          accountKey: 'https://example.com/gitlab#8',
          grants: g0eScope.grants,
        ),
        AiWriteScope(
          accountKey: g0eAccount,
          instance: GitLabInstance.parse('https://other.example'),
          grants: g0eScope.grants,
        ),
      ]) {
        await expectLater(
          f.port.resolveGroupWorkItemForTesting(_request(scope: scope)),
          _unverifiable,
        );
      }
      expect(f.adapter.requests, isEmpty);
    },
  );

  for (final round in [1, 2]) {
    for (final read in ['actor', 'namespace']) {
      test('round $round rechecks epoch after $read read', () async {
        final f = _fixture();
        if (round == 2) await f.port.prepare(_request());
        final before = f.adapter.requests.length;
        f.afterRead = () {
          if (f.adapter.requests.length == before + (read == 'actor' ? 1 : 2)) {
            f.api.clearReadCache();
          }
        };
        await expectLater(
          f.port.prepare(_request(execution: 'round-$round')),
          throwsA(
            anyOf(
              isA<writes.AiWriteRefused>(),
              isA<ApiFailure>().having(
                (failure) => failure.kind,
                'kind',
                FailureKind.cancelled,
              ),
            ),
          ),
        );
        expect(
          f.adapter.requests,
          hasLength(before + (read == 'actor' ? 1 : 2)),
        );
        expect(f.mutations, 0);
      });
    }
  }

  test(
    'revocation after journal flush blocks final synchronous START',
    () async {
      final f = _fixture();
      final base = await Mr6b3Harness.create();
      addTearDown(base.dispose);
      final coordinator = await f.coordinator(base);
      final proposal = await coordinator.propose(f.call);
      f.beforeStart = () => f.currentGeneration++;
      final outcome = await coordinator.approve(proposal!);
      expect(outcome.state, isNot(AiJournalState.succeeded));
      expect(f.adapter.requests, hasLength(4));
      expect(f.mutations, 0);
    },
  );
}
