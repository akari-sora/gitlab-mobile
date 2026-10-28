import 'release_policy_support.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart';

const _knownSecret = 'synthetic-known-list-credential';
const _listArguments = {
  'updateWorkItemLabels': 'labels',
  'updateGroupWorkItemLabels': 'labels',
  'updateWorkItemAssignees': 'assigneeUsernames',
  'updateGroupWorkItemAssignees': 'assigneeUsernames',
};

// Expose production argument specs, including hidden rows, only to this test.
final class _Ledger implements AiCapabilityLedger {
  const _Ledger();

  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || !_listArguments.containsKey(operationId)) return null;
    return AiCapability(
      operationId: row.operationId,
      namedMethod: row.namedMethod,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      boundary: row.boundary,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final operation in _listArguments.keys) find(operation)!,
  ];
}

// Observe the exact payload leaving the real coordinator in both rounds.
// The existing family tests separately exercise the real GraphQL adapters.
final class _CapturePort implements port.AiGitLabWritePort {
  _CapturePort(this.api);
  final GitLabApi api;
  final opened = <port.AiWriteRequest>[];
  port.AiWriteRequest? dispatched;

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    opened.add(request);
    final group = request.arguments.containsKey('groupId');
    return port.AiWritePrepared.graph(
      request: request,
      owner: this,
      releaseName: group ? '$g0ePath#5' : '#3',
      groupIdentity: group ? g0eIdentity(api) : null,
      groupIdentityIsCurrent: group ? () => true : null,
      writeKeys: {
        group
            ? const AiConflictKey([g0eAccount, 'group:7', 'workItem', '5'])
            : mr6b3WriteKey,
      },
      textBindingDigest: (_) => 'list-policy-binding',
      textMutation: (hooks, boundRequest) async {
        await hooks.beforeMutation();
        if (!hooks.mayStart()) return const GraphWriteResult();
        dispatched = boundRequest;
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

final class _Harness {
  _Harness(this.base, this.api, this.adapter);
  final Mr6b3Harness base;
  final GitLabApi api;
  final FakeAdapter adapter;
  late final _CapturePort capture;
  late final PolicyAiWriteCoordinator coordinator;
  final secrets = <String>{_knownSecret};

  static Future<_Harness> create(
    String operation, {
    bool realPort = false,
  }) async {
    final adapter = FakeAdapter((_) => jsonResponse({'visibility': 'private'}));
    final api = testApi(adapter);
    final h = _Harness(await Mr6b3Harness.create(), api, adapter);
    h.capture = _CapturePort(api);
    final group = operation.startsWith('updateGroup');
    final budget = AiToolBudget(maxGitLabRequests: 40);
    h.coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        appInForeground: true,
        scope: group ? g0eScope : mr6b3Scope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'string-list-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        ownerApi: api,
        currentResource: group
            ? AiTargetRef(
                kind: AiTargetKind.groupWorkItem,
                groupId: 7,
                groupFullPath: g0ePath,
                iid: 5,
              )
            : AiTargetRef(
                kind: AiTargetKind.issue,
                projectId: 9,
                projectPath: 'team/example-9',
                iid: 3,
              ),
      ),
      createPort: () => realPort
          ? port.GitLabAiWritePort(
              api,
              accountKey: mr6b3Account,
              sessionGeneration: 7,
              isCurrent: () => true,
            )
          : h.capture,
      journal: h.base.journal,
      conversationId: 'string-list-policy',
      budget: () => budget,
      readFreshness: (_) async {
        // A blocked list must not even reach this first HTTP read.
        await api.record(group ? ['groups', '7'] : ['projects', '9']);
        return const AiWriteFreshness(visibilityUnreadable: false);
      },
      placeholders: text.UploadPlaceholderTable(instance: api.instance),
      knownSecrets: () => h.secrets,
      safeDisplay: (value) => value,
      ledger: const _Ledger(),
    );
    h.coordinator.beginRun('Update this work item.');
    h.coordinator.beginTurn();
    addTearDown(() async {
      h.coordinator.stop('disposed');
      api.close();
      await h.base.dispose();
    });
    return h;
  }

  Future<AiWriteProposal?> propose(String operation, List<String> items) =>
      coordinator.propose(
        AiToolCall(
          id: 'list-call',
          name: operation,
          arguments: {
            if (operation.startsWith('updateGroup')) ...{
              'groupId': 7,
              'iid': 5,
            } else ...{
              'projectId': 9,
              'iid': 3,
            },
            _listArguments[operation]!: items,
            'reason': 'synthetic list request',
          },
        ),
      );
}

void main() {
  setUp(() {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  });

  test('inventory includes visible and hidden production string lists', () {
    expect({
      for (final row in ProductionAiLedger.rows)
        for (final arg in row.arguments.entries)
          if (arg.value.type == AiArgType.stringList) row.operationId: arg.key,
    }, _listArguments);
  });

  const blockedItems = {
    'known secret': (_knownSecret, text.AiTextBlockCode.secret),
    'secret pattern': (
      'glpat-0123456789abcdefghij',
      text.AiTextBlockCode.secret,
    ),
    'upload placeholder': ('[[upload:u-42]]', text.AiTextBlockCode.rereadField),
    'nonce placeholder': (
      '[[upload:u-nonce]]',
      text.AiTextBlockCode.rereadField,
    ),
    'attachment placeholder': (
      '[[attachment:att-1]]',
      text.AiTextBlockCode.attachmentScope,
    ),
    'upload token': (
      '/uploads/0123456789abcdef0123456789abcdef/a.png',
      text.AiTextBlockCode.rawUpload,
    ),
    'rebuilt upload': (
      '![safe](/uploads/0123456789abcdef0123456789abcdef/a.png)',
      text.AiTextBlockCode.rawUpload,
    ),
    'secret in upload label': (
      '![$_knownSecret](/uploads/0123456789abcdef0123456789abcdef/a.png)',
      text.AiTextBlockCode.rawUpload,
    ),
    'secret in upload filename': (
      '![safe](/uploads/0123456789abcdef0123456789abcdef/$_knownSecret.png)',
      text.AiTextBlockCode.rawUpload,
    ),
    'redaction marker': ('[REDACTED]', text.AiTextBlockCode.redactionMarker),
    'untrusted text marker': (
      '<gitlab_data nonce="synthetic">',
      text.AiTextBlockCode.redactionMarker,
    ),
  };
  for (final operation in _listArguments.keys) {
    for (final entry in blockedItems.entries) {
      test('$operation blocks ${entry.key} before any HTTP', () async {
        final h = await _Harness.create(operation, realPort: true);
        expect(await h.propose(operation, ['clean', entry.value.$1]), isNull);
        expect(
          h.coordinator.outcomeFor('list-call')?.reasonCode,
          entry.value.$2,
        );
        expect(h.adapter.requests, isEmpty);
      });
    }

    test('$operation preserves clean list bytes through dispatch', () async {
      final h = await _Harness.create(operation);
      final items = _listArguments[operation] == 'labels'
          ? ['  Café::e\u0301  ', '日本語😀', 'release/2026']
          : ['alice', '@name'];
      final bytes = utf8.encode(jsonEncode(items));
      final proposal = await h.propose(operation, items);
      expect(
        proposal,
        isNotNull,
        reason: h.coordinator.outcomeFor('list-call')?.reasonCode,
      );
      final outcome = await h.coordinator.approve(proposal!);
      expect(outcome.state, AiJournalState.succeeded);
      for (final request in [...h.capture.opened, h.capture.dispatched!]) {
        expect(
          utf8.encode(jsonEncode(request.arguments[_listArguments[operation]])),
          bytes,
        );
      }
      expect(h.adapter.requests, hasLength(2));
    });
  }

  for (final operation in [
    'updateWorkItemLabels',
    'updateGroupWorkItemLabels',
  ]) {
    for (final item in ['@name', '@all', 'label\r\nvalue']) {
      test(
        '$operation refuses altered identifier $item instead of rewriting',
        () async {
          final h = await _Harness.create(operation, realPort: true);
          expect(await h.propose(operation, [item]), isNull);
          expect(
            h.coordinator.outcomeFor('list-call')?.reasonCode,
            'policyBlocked',
          );
          expect(h.adapter.requests, isEmpty);
        },
      );
    }
  }

  test('newly known list secret blocks approval before fresh HTTP', () async {
    const operation = 'updateGroupWorkItemLabels';
    final h = await _Harness.create(operation);
    final proposal = await h.propose(operation, ['newly-sensitive-label']);
    expect(proposal, isNotNull);
    h.secrets.add('newly-sensitive-label');
    final before = h.adapter.requests.length;
    final outcome = await h.coordinator.approve(proposal!);
    expect(outcome.reasonCode, text.AiTextBlockCode.secret);
    expect(h.adapter.requests, hasLength(before));
    expect(h.capture.dispatched, isNull);
  });
}
