// G14: the production group catalogue and its renewed consent boundary.
import 'release_policy_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/prompts.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'fx_coord_support.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart';
import 'p17_controller_support.dart' show p17ToolNames, p17WaitFor;
import 'runner_test.dart' as runner_test;

const _aliases = <String>{
  'updateGroupWorkItemState',
  'updateGroupWorkItemStatus',
  'updateGroupWorkItemDates',
  'updateGroupWorkItemHealthStatus',
  'updateGroupWorkItemAssignees',
  'updateGroupWorkItemMilestone',
  'updateGroupWorkItemWeight',
  'createGroupWorkItemActivityComment',
  'createGroupWorkItemActivityReply',
  'deleteGroupWorkItemActivityNote',
  'setGroupWorkItemActivityNoteReaction',
  'setGroupWorkItemNotifications',
  'updateGroupWorkItemContent',
  'editGroupWorkItemActivityNote',
  'updateGroupWorkItemLabels',
};
const _groupWrites = <String>{..._aliases, 'snoozeTodo', 'unsnoozeTodo'};
const _origin = AiGroupWorkItemOrigin(
  group: GraphResourceRef(id: 'gid://gitlab/Group/7', fullPath: g0ePath),
  iid: 5,
  title: 'Synthetic group work item',
);

void _serveGroup(StackServer server) {
  server.overrides['GET groups/7'] = (_) =>
      jsonResponse({'id': 7, 'full_path': g0ePath, 'visibility': 'private'});
  server.overrides['POST '] = (request) {
    expect(request.uri.toString(), 'https://example.com/gitlab/api/graphql');
    final body = request.data! as Map<String, Object?>;
    expect(body['query'], namespaceWorkItemQuery);
    expect(body['variables'], {'path': g0ePath, 'iid': '5'});
    return jsonResponse({
      'data': {
        'namespace': {
          'id': 'gid://gitlab/Group/7',
          'fullPath': g0ePath,
          'workItem': {
            'id': 'gid://gitlab/WorkItem/91',
            'iid': '5',
            'title': 'Synthetic group work item',
            'state': 'OPEN',
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': '2026-10-02T00:00:00Z',
            'project': null,
            'namespace': {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath},
            'workItemType': {
              'id': 'gid://gitlab/WorkItems::Type/1',
              'name': 'Task',
            },
            'description': 'Synthetic group description',
            'widgets': <Object?>[],
          },
        },
      },
    });
  };
}

/// Production coordinator/ledger over the existing synthetic opening port.
/// Mutable app-owned snapshots exercise approval fences without HTTP.
final class _Writes {
  _Writes(this.base) : port = G0eGraphPort(Object());

  static Future<_Writes> create() async {
    final h = _Writes(await Mr6b3Harness.create());
    h.coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        scope: h.scope,
        level: h.level,
        ceiling: h.ceiling,
        toolsEnabled: h.tools,
        consentValid: h.consentValid,
        consentHash: h.hash,
        writePolicyRevision: h.policyRevision,
        scopeRevision: h.scopeRevision,
        sessionGeneration: 7,
        ownerApi: h.port.api,
        appInForeground: true,
        currentResource: h.target,
      ),
      createPort: () => h.port,
      journal: h.base.journal,
      conversationId: 'g14-production',
      budget: () => h.budget,
      readFreshness: (_) async => const AiWriteFreshness(
        targetVisibility: 'private',
        visibilityUnreadable: true,
        sourceVisibilityUnreadable: false,
      ),
      placeholders: UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        accountKey: g0eAccount,
        conversationId: 'g14-production',
      ),
      knownSecrets: () => h.secrets,
      safeDisplay: (value) => value,
    );
    h.coordinator.beginRun('Update this group work item.');
    h.coordinator.beginTurn();
    return h;
  }

  final Mr6b3Harness base;
  final G0eGraphPort port;
  late final PolicyAiWriteCoordinator coordinator;
  final budget = AiToolBudget(maxGitLabRequests: 40);
  final secrets = <String>{};
  AiWriteScope scope = g0eScope;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  AiAutonomyLevel ceiling = AiAutonomyLevel.bypass;
  bool tools = true;
  bool consentValid = true;
  String hash = 'g14-current-consent';
  int policyRevision = 1;
  int scopeRevision = 1;
  final target = AiTargetRef(
    kind: AiTargetKind.groupWorkItem,
    side: AiResourceSide.group,
    groupId: 7,
    groupFullPath: g0ePath,
    iid: 5,
    workItemGid: 'gid://gitlab/WorkItem/91',
    origin: AiTargetOrigin.currentResource,
  );

  Future<void> dispose() async {
    coordinator.stop();
    await base.dispose();
  }
}

void main() {
  test('G14 rows remain intact and released in the v0.6.0 policy', () {
    expect(aiToolCatalogueVersion, 6);
    expect(aiDisclosureVersion, 2);
    expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
    expect(aiGroupWorkItemWritesAreEnabled, isTrue);
    final policy = aiProductionWritePolicy(AiAutonomyLevel.bypass);
    expect(policy.policyVersion, 5);
    expect(policy.catalogueVersion, 6);
    expect(policy.operationIds, containsAll(_aliases));
    final groups = ProductionAiLedger.rows.where(
      (row) => row.scopeClass == AiScopeClass.groupWorkItem,
    );
    expect(groups.map((row) => row.operationId).toSet(), _aliases);
    for (final row in groups) {
      expect(row.modelVisible, isTrue, reason: row.operationId);
      expect(fixtureAiLedger.modelVisible, contains(row));
    }
    expect(policy.fixedConfirmOperationIds, aiFixedConfirmOperationIds);
    expect(policy.escalationRuleIds, aiProductionWriteEscalationRuleIds);
    expect(
      aiWriteSystemPrompt,
      contains("conversation's scope names that exact group and item"),
    );
  });

  test(
    'G14 production group schemas offer only exact-scope aliases and snoozes',
    () async {
      final h = await _Writes.create();
      addTearDown(h.dispose);
      expect(h.coordinator.specs.map((s) => s.name).toSet(), _groupWrites);
      for (final spec in h.coordinator.specs.where(
        (s) => _aliases.contains(s.name),
      )) {
        final props = spec.parameters['properties']! as Map<String, Object?>;
        expect(props, isNot(contains('projectId')), reason: spec.name);
        expect((props['groupId']! as Map<String, Object?>)['enum'], [7]);
      }
      aiGroupWorkItemWritesEnabledForTesting = false;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      expect(h.coordinator.specs, isEmpty);
    },
  );

  for (final blocked in [
    'tools disabled',
    'read-only ceiling',
    'no scope',
    'invalid consent',
  ]) {
    test('G14 $blocked never offers or opens a group write', () async {
      final h = await _Writes.create();
      addTearDown(h.dispose);
      switch (blocked) {
        case 'tools disabled':
          h.tools = false;
        case 'read-only ceiling':
          h.ceiling = AiAutonomyLevel.readOnly;
        case 'no scope':
          h.scope = const AiWriteScope(accountKey: g0eAccount, grants: []);
        case 'invalid consent':
          h.consentValid = false;
      }
      expect(h.coordinator.specs, isEmpty);
      final result = await h.coordinator.execute(
        AiToolCall(
          id: 'blocked',
          name: 'updateGroupWorkItemContent',
          arguments: {
            'groupId': 7,
            'iid': 5,
            'title': 'Updated',
            'reason': 'Asked.',
          },
        ),
      );
      expect(result.state, AiJournalState.notExecuted);
      expect(h.port.prepares, 0);
      expect(h.port.mutations, 0);
    });
  }

  for (final level in [AiAutonomyLevel.readOnly, AiAutonomyLevel.confirmEach]) {
    test(
      'G14 old ${level.name} consent cannot authorize the group model tools',
      () async {
        final h = await StackHarness.create(
          origin: _origin,
          level: AiAutonomyLevel.confirmEach,
          configure: _serveGroup,
        );
        addTearDown(h.dispose);
        if (level == AiAutonomyLevel.readOnly) {
          await h.settings.setAutonomySettings(
            h.account,
            ceiling: AiAutonomyLevel.readOnly,
          );
        }
        final provider = h.settings.providers.single;
        final current = level == AiAutonomyLevel.readOnly
            ? aiCurrentConsentContractFor(provider, releasePolicy: fixtureReleasePolicy)
            : aiConversationConsentContract(h.settings, h.account, provider, releasePolicy: fixtureReleasePolicy);
        final currentPolicy = aiProductionWritePolicy(level, releasePolicy: fixtureReleasePolicy);
        final old = aiConsentContractFor(
          provider,
          toolCatalogueVersion: 4,
          writePolicy: level == AiAutonomyLevel.readOnly
              ? null
              : AiWritePolicy(
                  policyVersion: 3,
                  agreedCeiling: level,
                  catalogueVersion: 4,
                  operationIds: currentPolicy.operationIds.difference(_aliases),
                  hardLineOperationIds: currentPolicy.hardLineOperationIds,
                  fixedConfirmOperationIds:
                      currentPolicy.fixedConfirmOperationIds,
                  escalationRuleIds: currentPolicy.escalationRuleIds,
                  resetConfirmWindow: currentPolicy.resetConfirmWindow,
                ),
        );
        expect(old.hash, isNot(current.hash));
        await h.settings.grantConsent(h.account, old, const {
          'synthetic': true,
        });
        expect(h.settings.isValid(h.account, current), isFalse);
        await h.controller.recheck();
        expect(h.controller.blocker, AiChatBlocker.consentRequired);
        final beforeBlocked = h.server.adapter.requests.length;
        await h.controller.send('Read this group work item');
        expect(h.provider.bodies, isEmpty);
        expect(h.server.adapter.requests, hasLength(beforeBlocked));
        await h.settings.grantConsent(h.account, current, const {
          'synthetic': true,
        });
        await h.controller.recheck();
        expect(h.controller.canSend, isTrue);
        await h.controller.send('Read this group work item');
        final offered = p17ToolNames(h.provider.bodies.single);
        expect(offered, contains('get_group_work_item'));
        expect(
          offered.intersection(
            ProductionAiLedger.rows.map((r) => r.operationId).toSet(),
          ),
          level == AiAutonomyLevel.readOnly ? isEmpty : _groupWrites,
        );
        expect(offered, isNot(contains('markTodoDone')));
        expect(offered, isNot(contains('get_issue')));
      },
    );
  }

  test('G14 a policy-only version change renews write-enabled consent', () {
    for (final level in [AiAutonomyLevel.confirmEach, AiAutonomyLevel.bypass]) {
      final current = aiProductionWritePolicy(level);
      final previous = AiWritePolicy(
        policyVersion: 3,
        agreedCeiling: level,
        catalogueVersion: 5,
        operationIds: current.operationIds,
        hardLineOperationIds: current.hardLineOperationIds,
        fixedConfirmOperationIds: current.fixedConfirmOperationIds,
        escalationRuleIds: current.escalationRuleIds,
        resetConfirmWindow: current.resetConfirmWindow,
      );
      expect(
        aiConsentContractFor(stackProviderConfig, writePolicy: current).hash,
        isNot(
          aiConsentContractFor(stackProviderConfig, writePolicy: previous).hash,
        ),
      );
    }
  });

  test(
    'G14 every group alias preserves fixed confirmation and hard floors at all levels',
    () {
      final target = AiTargetRef(
        kind: AiTargetKind.groupWorkItem,
        side: AiResourceSide.group,
        groupId: 7,
        groupFullPath: g0ePath,
        iid: 5,
        origin: AiTargetOrigin.currentResource,
      );
      const binding = AiBindingResult(
        userMessage: 'Asked.',
        allBound: true,
        intentAuthorizesLowRisk: true,
      );
      for (final operation in _aliases) {
        final row = productionAiLedger.find(operation)!;
        for (final level in AiAutonomyLevel.values) {
          AiTierDecision decide(AiTierFacts facts) => decideTier(
            AiTierInput(
              level: level,
              capability: row,
              scope: g0eScope,
              binding: binding,
              target: target,
              facts: facts,
              typedName: 'team/sub#5',
            ),
          );
          for (final reason in aiAlwaysConfirmReasons) {
            final result = decide(AiTierFacts(reasons: [reason]));
            expect(
              result.decision,
              level == AiAutonomyLevel.readOnly
                  ? AiGateDecision.deny
                  : AiGateDecision.requireApproval,
              reason: '$operation ${level.name} ${reason.name}',
            );
            if (level != AiAutonomyLevel.readOnly) {
              expect(result.reasons, contains(reason));
            }
          }
          for (final facts in [
            const AiTierFacts(confidentialLowered: true),
            const AiTierFacts(visibilityRaised: true),
            const AiTierFacts(touchesCiConfig: true),
          ]) {
            final result = decide(facts);
            expect(result.tier, AiWriteTier.hardLine);
            expect(
              result.decision,
              level == AiAutonomyLevel.readOnly
                  ? AiGateDecision.deny
                  : AiGateDecision.requireApproval,
            );
            if (level != AiAutonomyLevel.readOnly) {
              expect(result.requiresTypedName, isTrue);
            }
          }
        }
        expect(row.arguments.keys, isNot(contains('confidential')));
        expect(row.arguments.keys, isNot(contains('visibility')));
      }
    },
  );

  test('G14 recipient revision invalidates a waiting group proposal', () async {
    final h = await _Writes.create();
    addTearDown(h.dispose);
    final provider = runner_test.Harness(format: AiFormat.responses);
    provider.respond = (_, _) async => provider.turn(
      calls: [
        AiToolCall(
          id: 'recipient-proposal',
          name: 'updateGroupWorkItemContent',
          arguments: {
            'groupId': 7,
            'iid': 5,
            'title': 'Updated',
            'reason': 'Asked.',
          },
        ),
      ],
    );
    final runner = AiRunner(
      config: provider.config(),
      wire: provider.wire,
      complete: provider.complete,
      secrets: provider.secrets,
      refreshSecrets: () async {},
      system: aiWriteSystemPrompt,
      appInForeground: () => true,
      guard: AiRunGuard(
        expectedGeneration: 1,
        ownerApi: provider.owner,
        generation: () => 1,
        api: () => provider.owner,
        recipientRevision: () => provider.revision,
        consentValid: () => true,
      ),
      currentTools: () => h.coordinator.specs,
      writeCoordinator: h.coordinator,
      close: () {},
      cancelActive: () {},
    );
    final sending = runner.run('Update this group work item');
    await p17WaitFor(() => h.coordinator.proposals.isNotEmpty);
    final proposal = h.coordinator.proposals.single;
    provider.revision = 2;
    runner.checkNow();
    expect((await sending).reason, AiRunEnd.stoppedBySettings);
    expect(proposal.valid, isFalse);
    expect(h.coordinator.proposals, isEmpty);
    expect(h.port.mutations, 0);
  });

  for (final changed in [
    'provider consent',
    'policy revision',
    'scope revision',
    'secret',
  ]) {
    test(
      'G14 $changed invalidates an old group proposal before mutation',
      () async {
        final h = await _Writes.create();
        addTearDown(h.dispose);
        final pending = h.coordinator.execute(
          AiToolCall(
            id: 'proposal',
            name: 'updateGroupWorkItemContent',
            arguments: {
              'groupId': 7,
              'iid': 5,
              'title': 'late-known-value',
              'reason': 'Asked.',
            },
          ),
        );
        await p17WaitFor(() => h.coordinator.proposals.isNotEmpty);
        final proposal = h.coordinator.proposals.single;
        expect(proposal.valid, isTrue);
        switch (changed) {
          case 'provider consent':
            h.hash = 'other-provider-consent';
          case 'policy revision':
            h.policyRevision++;
          case 'scope revision':
            h.scopeRevision++;
          case 'secret':
            h.secrets.add('late-known-value');
        }
        final outcome = await h.coordinator.approve(proposal);
        expect((await pending).reasonCode, outcome.reasonCode);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(
          outcome.reasonCode,
          changed == 'secret' ? 'secret' : 'settingsChanged',
        );
        expect(proposal.valid, isFalse);
        expect(h.port.mutations, 0);
      },
    );
  }

  for (final changed in [
    'secret',
    'recipient',
    'scope revision',
    'provider consent',
  ]) {
    test(
      'G14 $changed opens a fresh production-tool segment without opaque replay',
      () async {
        final h = await _Writes.create();
        addTearDown(h.dispose);
        final provider = runner_test.Harness(format: AiFormat.responses);
        var first = true;
        provider.respond = (_, _) async {
          final turn = provider.turn(
            text: 'Synthetic answer newly-known-secret',
            opaque: first ? 'old-opaque-group-output' : '',
          );
          first = false;
          return turn;
        };
        final runner = AiRunner(
          config: provider.config(),
          wire: provider.wire,
          complete: provider.complete,
          secrets: provider.secrets,
          refreshSecrets: () async {},
          system: aiWriteSystemPrompt,
          guard: AiRunGuard(
            expectedGeneration: 1,
            ownerApi: provider.owner,
            generation: () => 1,
            api: () => provider.owner,
            recipientRevision: () => provider.revision,
            consentValid: () => true,
          ),
          tools: h.coordinator.specs,
          currentTools: () => h.coordinator.specs,
          toolPolicyRevision: () => (h.scopeRevision, h.hash),
          writeCoordinator: h.coordinator,
          close: () {},
          cancelActive: () {},
        );
        expect((await runner.run('First group request')).reason, AiRunEnd.done);
        final old = runner.segment!;
        final frozen = old.frozenWireJson.toList();
        switch (changed) {
          case 'secret':
            provider.secrets.current.add('newly-known-secret');
          case 'recipient':
            provider.revision = 2;
            runner.replaceKeyRecipient(
              config: provider.config(),
              complete: provider.complete,
              close: () {},
              cancelActive: () {},
            );
          case 'scope revision':
            h.scopeRevision++;
          case 'provider consent':
            h.hash = 'changed-provider-consent';
        }
        expect(
          (await runner.run('Second group request')).reason,
          AiRunEnd.done,
        );
        expect(runner.segment, isNot(same(old)));
        expect(
          provider.payloads.last,
          isNot(contains('old-opaque-group-output')),
        );
        expect(
          provider.plans.last.tools.map((s) => s.name).toSet(),
          _groupWrites,
        );
        expect(old.frozenWireJson, frozen);
      },
    );
  }
}
