import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/intent_lexicon.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/group_work_item_identity.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

void main() {
  group('§15 row 8 tier matrix', () {
    test('five levels times each tier', () {
      for (final AiAutonomyLevel level in AiAutonomyLevel.values) {
        for (final AiWriteTier tier in AiWriteTier.values) {
          final AiTierDecision decision = _decide(
            operationId: 'sample_${tier.name}',
            tier: tier,
            level: level,
          );
          expect(
            decision.decision,
            _matrix(level, tier),
            reason: '${level.name} ${tier.name}',
          );
          expect(decision.tier, tier, reason: '${level.name} ${tier.name}');
          expect(
            decision.requiresTypedName,
            decision.decision == AiGateDecision.requireApproval &&
                (tier == AiWriteTier.t4 || tier == AiWriteTier.hardLine),
            reason: '${level.name} ${tier.name}',
          );
        }
      }
    });

    test(
      'parameter upgrades take the highest tier and pipeline side effects do not',
      () {
        expect(
          _decide(
            operationId: 'edit_file',
            tier: AiWriteTier.t3,
            level: AiAutonomyLevel.conversationGrant,
            facts: const AiTierFacts(protectedOrDefaultBranch: true),
          ).tier,
          AiWriteTier.t4,
        );
        expect(
          _decide(
            operationId: 'createFile',
            tier: AiWriteTier.t3,
            level: AiAutonomyLevel.conversationGrant,
            facts: const AiTierFacts(protectedOrDefaultBranch: true),
          ).tier,
          AiWriteTier.t4,
        );
        expect(
          _decide(
            operationId: 'applySuggestion',
            tier: AiWriteTier.t3,
            level: AiAutonomyLevel.conversationGrant,
            facts: const AiTierFacts(protectedOrDefaultBranch: true),
          ).tier,
          AiWriteTier.t4,
        );
        final AiTierDecision squash = _decide(
          operationId: 'mergeRequest',
          tier: AiWriteTier.t3,
          level: AiAutonomyLevel.conversationGrant,
          facts: const AiTierFacts(squash: true),
        );
        expect(squash.tier, AiWriteTier.t3);
        expect(squash.showSquash, isTrue);
        expect(squash.decision, AiGateDecision.execute);
        expect(
          _decide(
            operationId: 'mergeRequest',
            tier: AiWriteTier.t3,
            level: AiAutonomyLevel.conversationGrant,
            facts: const AiTierFacts(
              protectedOrDefaultBranch: true,
              squash: true,
            ),
          ).tier,
          AiWriteTier.t4,
        );
        expect(
          _decide(
            operationId: 'mergeRequest',
            tier: AiWriteTier.t3,
            level: AiAutonomyLevel.conversationGrant,
            facts: const AiTierFacts(removeSourceBranch: true),
          ).tier,
          AiWriteTier.t4,
        );
        expect(
          _decide(
            operationId: 'setStar',
            tier: AiWriteTier.t1,
            level: AiAutonomyLevel.lowRiskAuto,
            facts: const AiTierFacts(removeSourceBranch: true),
          ).tier,
          AiWriteTier.t1,
        );
        for (final String operation in <String>[
          'createBranch',
          'rebaseMergeRequest',
        ]) {
          expect(
            _decide(
              operationId: operation,
              tier: AiWriteTier.t3,
              level: AiAutonomyLevel.conversationGrant,
              facts: const AiTierFacts(
                protectedOrDefaultBranch: true,
                triggersPipeline: true,
              ),
            ).tier,
            AiWriteTier.t3,
            reason: operation,
          );
        }
        expect(
          _decide(
            operationId: 'edit_file',
            tier: AiWriteTier.t3,
            level: AiAutonomyLevel.bypass,
            facts: const AiTierFacts(triggersPipeline: true),
          ).tier,
          AiWriteTier.t3,
        );
        final AiTierDecision ci = _decide(
          operationId: 'edit_file',
          tier: AiWriteTier.t3,
          level: AiAutonomyLevel.bypass,
          facts: const AiTierFacts(
            protectedOrDefaultBranch: true,
            touchesCiConfig: true,
          ),
        );
        expect(ci.tier, AiWriteTier.hardLine);
        expect(ci.decision, AiGateDecision.requireApproval);
        expect(ci.requiresTypedName, isTrue);
        for (final AiTierFacts facts in <AiTierFacts>[
          const AiTierFacts(confidentialLowered: true),
          const AiTierFacts(visibilityRaised: true),
          const AiTierFacts(newSnippetNotPrivate: true),
        ]) {
          expect(
            _decide(
              operationId: 'updateIssue',
              tier: AiWriteTier.t2,
              level: AiAutonomyLevel.bypass,
              facts: facts,
            ).tier,
            AiWriteTier.hardLine,
          );
        }
        expect(
          _decide(
            operationId: 'createTag',
            tier: AiWriteTier.t2,
            level: AiAutonomyLevel.confirmEach,
          ).tier,
          AiWriteTier.t4,
        );
      },
    );

    test(
      'createPipeline and playPipelineSchedule need a typed name, cancel stays T3',
      () {
        for (final AiAutonomyLevel level in <AiAutonomyLevel>[
          AiAutonomyLevel.conversationGrant,
          AiAutonomyLevel.lowRiskAuto,
          AiAutonomyLevel.confirmEach,
        ]) {
          final AiTierDecision pipeline = _decide(
            operationId: 'createPipeline',
            tier: AiWriteTier.t3,
            level: level,
          );
          expect(pipeline.tier, AiWriteTier.t4, reason: level.name);
          expect(
            pipeline.decision,
            AiGateDecision.requireApproval,
            reason: level.name,
          );
          expect(pipeline.requiresTypedName, isTrue, reason: level.name);
        }
        final AiTierDecision variables = _decide(
          operationId: 'createPipeline',
          tier: AiWriteTier.t4,
          level: AiAutonomyLevel.bypass,
          facts: const AiTierFacts(pipelineVariables: true),
        );
        expect(variables.tier, AiWriteTier.hardLine);
        expect(variables.requiresTypedName, isTrue);
        final AiTierDecision schedule = _decide(
          operationId: 'playPipelineSchedule',
          tier: AiWriteTier.t4,
          level: AiAutonomyLevel.conversationGrant,
        );
        expect(schedule.tier, AiWriteTier.t4);
        expect(schedule.requiresTypedName, isTrue);
        final AiTierDecision unsafe = _decide(
          operationId: 'playPipelineSchedule',
          tier: AiWriteTier.t4,
          level: AiAutonomyLevel.bypass,
          facts: const AiTierFacts(scheduleParamsUnsafe: true),
        );
        expect(unsafe.tier, AiWriteTier.hardLine);
        expect(unsafe.requiresTypedName, isTrue);
        final AiTierDecision cancel = _decide(
          operationId: 'pipelineAction',
          tier: AiWriteTier.t3,
          level: AiAutonomyLevel.conversationGrant,
          arguments: const <String, Object?>{'action': 'cancel'},
        );
        expect(cancel.tier, AiWriteTier.t3);
        expect(cancel.decision, AiGateDecision.execute);
        expect(cancel.requiresTypedName, isFalse);
        expect(cancel.cancelMayRunAfterScript, isTrue);
      },
    );

    test(
      'retry and play confirm without a typed name, and bypass still confirms the fixed list',
      () {
        for (final AiAutonomyLevel level in <AiAutonomyLevel>[
          AiAutonomyLevel.confirmEach,
          AiAutonomyLevel.lowRiskAuto,
          AiAutonomyLevel.conversationGrant,
        ]) {
          for (final (String, String) operation in <(String, String)>[
            ('pipelineAction', 'retry'),
            ('jobAction', 'retry'),
            ('jobAction', 'play'),
          ]) {
            final AiTierDecision decision = _decide(
              operationId: operation.$1,
              tier: AiWriteTier.t3,
              level: level,
              arguments: <String, Object?>{'action': operation.$2},
            );
            expect(
              decision.tier,
              AiWriteTier.t4,
              reason: '${level.name} ${operation.$1}',
            );
            expect(decision.decision, AiGateDecision.requireApproval);
            expect(decision.requiresTypedName, isFalse);
            expect(decision.reusesStoredVariables, isTrue);
          }
        }
        final AiTierDecision automatic = _decide(
          operationId: 'jobAction',
          tier: AiWriteTier.t3,
          level: AiAutonomyLevel.bypass,
          arguments: const <String, Object?>{'action': 'play'},
        );
        expect(automatic.decision, AiGateDecision.execute);
        expect(automatic.requiresTypedName, isFalse);
        expect(automatic.reusesStoredVariables, isTrue);
        final AiTierDecision unbound = _decide(
          operationId: 'pipelineAction',
          tier: AiWriteTier.t3,
          level: AiAutonomyLevel.bypass,
          arguments: const <String, Object?>{'action': 'retry'},
          binding: const AiBindingResult(
            userMessage: '',
            allBound: false,
            intentAuthorizesLowRisk: true,
          ),
        );
        expect(unbound.decision, AiGateDecision.requireApproval);
        expect(unbound.requiresTypedName, isFalse);
        expect(unbound.reasons, contains(AiFixedConfirmReason.targetUnbound));
        final AiTierDecision duplicate = _decide(
          operationId: 'jobAction',
          tier: AiWriteTier.t3,
          level: AiAutonomyLevel.bypass,
          arguments: const <String, Object?>{'action': 'retry'},
          facts: const AiTierFacts(
            reasons: <AiFixedConfirmReason>[
              AiFixedConfirmReason.duplicateOfSettledWrite,
            ],
          ),
        );
        expect(duplicate.decision, AiGateDecision.requireApproval);
        expect(duplicate.requiresTypedName, isFalse);
        expect(
          duplicate.reasons,
          contains(AiFixedConfirmReason.duplicateOfSettledWrite),
        );
      },
    );

    test(
      'fixed confirm reasons hold at bypass, and the bypass exemptions do not',
      () {
        final AiCapability markAll = AiCapability(
          operationId: 'markAllTodosDone',
          baseTier: AiWriteTier.t4,
          scopeClass: AiScopeClass.accountTodo,
          modelVisible: false,
        );
        for (final AiAutonomyLevel level in AiAutonomyLevel.values) {
          final AiTierDecision decision = decideTier(
            AiTierInput(
              level: level,
              capability: markAll,
              scope: const AiWriteScope(
                accountKey: 'https://gitlab.example#1',
                grants: <AiScopeGrant>[
                  AiScopeGrant(kind: AiScopeKind.accountGlobal),
                ],
              ),
              binding: _bound,
              target: AiTargetRef(kind: AiTargetKind.todo),
              typedName: '@ada',
            ),
          );
          if (level == AiAutonomyLevel.readOnly) {
            expect(decision.decision, AiGateDecision.deny);
          } else {
            expect(
              decision.decision,
              AiGateDecision.requireApproval,
              reason: level.name,
            );
            expect(decision.requiresTypedName, isTrue, reason: level.name);
            expect(
              decision.reasons,
              contains(AiFixedConfirmReason.markAllTodosDone),
            );
          }
        }
        expect(
          productionAiLedger.find('markAllTodosDone')!.baseTier,
          AiWriteTier.t4,
        );
        final AiTierDecision mention = _decide(
          operationId: 'createNote',
          tier: AiWriteTier.t2,
          level: AiAutonomyLevel.bypass,
          facts: const AiTierFacts(
            reasons: <AiFixedConfirmReason>[AiFixedConfirmReason.massMention],
          ),
        );
        expect(mention.decision, AiGateDecision.requireApproval);
        expect(mention.requiresTypedName, isFalse);
        final AiTierDecision reset = _decide(
          operationId: 'createNote',
          tier: AiWriteTier.t2,
          level: AiAutonomyLevel.bypass,
          facts: const AiTierFacts(
            reasons: <AiFixedConfirmReason>[
              AiFixedConfirmReason.journalResetWindow,
            ],
          ),
        );
        expect(reset.decision, AiGateDecision.execute);
        expect(
          reset.reasons,
          isNot(contains(AiFixedConfirmReason.journalResetWindow)),
        );
        final AiTierDecision held = _decide(
          operationId: 'createNote',
          tier: AiWriteTier.t2,
          level: AiAutonomyLevel.conversationGrant,
          facts: const AiTierFacts(
            reasons: <AiFixedConfirmReason>[
              AiFixedConfirmReason.journalResetWindow,
              AiFixedConfirmReason.confidentialOrVisibilityMix,
            ],
          ),
        );
        expect(held.decision, AiGateDecision.requireApproval);
        expect(
          held.reasons,
          contains(AiFixedConfirmReason.confidentialOrVisibilityMix),
        );
        final AiTierDecision mix = _decide(
          operationId: 'setStar',
          tier: AiWriteTier.t1,
          level: AiAutonomyLevel.lowRiskAuto,
          facts: const AiTierFacts(
            reasons: <AiFixedConfirmReason>[
              AiFixedConfirmReason.confidentialOrVisibilityMix,
            ],
          ),
        );
        expect(mix.decision, AiGateDecision.requireApproval);
        final AiTierDecision bypassMix = _decide(
          operationId: 'setStar',
          tier: AiWriteTier.t1,
          level: AiAutonomyLevel.bypass,
          facts: const AiTierFacts(
            reasons: <AiFixedConfirmReason>[
              AiFixedConfirmReason.confidentialOrVisibilityMix,
            ],
          ),
        );
        expect(bypassMix.decision, AiGateDecision.execute);
      },
    );

    test('low-risk T1 needs a unique intent, broader auto levels do not', () {
      final AiTierDecision missing = _decide(
        operationId: 'setStar',
        tier: AiWriteTier.t1,
        level: AiAutonomyLevel.lowRiskAuto,
        binding: const AiBindingResult(
          userMessage: 'star',
          allBound: true,
          intentAuthorizesLowRisk: false,
          reasons: <AiFixedConfirmReason>[AiFixedConfirmReason.intentNotUnique],
        ),
      );
      expect(missing.decision, AiGateDecision.requireApproval);
      expect(missing.reasons, contains(AiFixedConfirmReason.intentNotUnique));
      expect(
        _decide(
          operationId: 'setStar',
          tier: AiWriteTier.t1,
          level: AiAutonomyLevel.conversationGrant,
          binding: const AiBindingResult(
            userMessage: 'star',
            allBound: true,
            intentAuthorizesLowRisk: false,
          ),
        ).decision,
        AiGateDecision.execute,
      );
      expect(
        _decide(
          operationId: 'setStar',
          tier: AiWriteTier.t1,
          level: AiAutonomyLevel.bypass,
          binding: const AiBindingResult(
            userMessage: '',
            allBound: false,
            intentAuthorizesLowRisk: true,
          ),
        ).reasons,
        contains(AiFixedConfirmReason.targetUnbound),
      );
    });

    test('an unknown operation and a group work item are denied', () {
      aiGroupWorkItemWritesEnabledForTesting = false;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      expect(
        decideListed(
          ledger: productionAiLedger,
          operationId: 'not_a_listed_operation',
          build: (AiCapability capability) => AiTierInput(
            level: AiAutonomyLevel.bypass,
            capability: capability,
            scope: _projectScope,
            binding: _bound,
            target: _projectTarget,
          ),
        ).known,
        isFalse,
      );
      final AiTierDecision group = decideTier(
        AiTierInput(
          level: AiAutonomyLevel.bypass,
          capability: productionAiLedger.find('createNote')!,
          scope: AiWriteScope(
            accountKey: _account,
            grants: <AiScopeGrant>[
              AiScopeGrant(
                kind: AiScopeKind.groupWorkItem,
                groupFullPath: 'acme',
                iid: 3,
              ),
            ],
          ),
          binding: _bound,
          target: AiTargetRef(
            kind: AiTargetKind.groupWorkItem,
            groupFullPath: 'acme',
            iid: 3,
          ),
        ),
      );
      expect(group.decision, AiGateDecision.deny);
    });

    test('a missing typed name cannot be proposed', () {
      final AiTierDecision decision = _decide(
        operationId: 'deleteProject',
        tier: AiWriteTier.hardLine,
        level: AiAutonomyLevel.bypass,
        typedName: '   ',
      );
      expect(decision.requiresTypedName, isTrue);
      expect(decision.canPropose, isFalse);
      expect(decision.decision, AiGateDecision.requireApproval);
    });
  });

  group('group production gate and numeric scope', () {
    test('production gate defaults to true without an override', () {
      expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
      expect(aiGroupWorkItemWritesAreEnabled, isTrue);
    });

    test('gate and exact group identity constrain synthetic group rows', () {
      aiGroupWorkItemWritesEnabledForTesting = true;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      const row = AiCapability(
        operationId: 'updateGroupWorkItemState',
        baseTier: AiWriteTier.t2,
        scopeClass: AiScopeClass.groupWorkItem,
      );
      const scope = AiWriteScope(
        accountKey: _account,
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.groupWorkItem,
            groupId: 4,
            groupFullPath: 'acme/sub',
            iid: 3,
          ),
        ],
      );
      AiTargetRef target(int groupId, int iid, {int? projectId}) => AiTargetRef(
        kind: AiTargetKind.groupWorkItem,
        groupId: groupId,
        groupFullPath: 'acme/sub',
        iid: iid,
        projectId: projectId,
        origin: AiTargetOrigin.currentResource,
      );
      expect(
        aiWriteScopeKey(_account, scope.grants.single),
        '($_account, group:4, workItem, 3)',
      );
      expect(
        aiWriteScopeKey(_account, scope.grants.single),
        aiWriteScopeKey(
          _account,
          const AiScopeGrant(
            kind: AiScopeKind.groupWorkItem,
            groupId: 4,
            groupFullPath: 'renamed',
            iid: 3,
          ),
        ),
      );
      expect(
        aiWriteScopeKey(_account, scope.grants.single),
        isNot(
          aiWriteScopeKey(
            _account,
            const AiScopeGrant(
              kind: AiScopeKind.workItem,
              projectId: 4,
              iid: 3,
            ),
          ),
        ),
      );
      expect(scopeAdmits(scope, row, target(4, 3)), isTrue);
      expect(scopeAdmits(scope, row, target(5, 3)), isFalse);
      expect(scopeAdmits(scope, row, target(4, 9)), isFalse);
      expect(scopeAdmits(scope, row, target(4, 3, projectId: 4)), isFalse);
      expect(
        scopeAdmits(
          const AiWriteScope(accountKey: _account, grants: []),
          row,
          target(4, 3),
        ),
        isFalse,
      );
      expect(
        decideTier(
          AiTierInput(
            level: AiAutonomyLevel.conversationGrant,
            capability: row,
            scope: scope,
            binding: _bound,
            target: target(4, 3),
          ),
        ).decision,
        AiGateDecision.execute,
      );
      expect(_bind('', [target(5, 3)], scope: scope).allBound, isFalse);
      expect(_bind('', [target(4, 9)], scope: scope).allBound, isFalse);
      final offered = toolsForScope(
        scope,
      ).map((row) => row.operationId).toSet();
      expect(offered, containsAll(['snoozeTodo', 'unsnoozeTodo']));
      expect(offered, isNot(contains('markTodoDone')));
      final ownTodo = AiTargetRef(
        kind: AiTargetKind.todo,
        side: AiResourceSide.group,
        groupId: 4,
        groupFullPath: 'acme/sub',
        parentIid: 3,
        origin: AiTargetOrigin.currentResource,
      );
      expect(
        scopeAdmits(scope, productionAiLedger.find('snoozeTodo')!, ownTodo),
        isTrue,
      );
      expect(
        scopeAdmits(scope, productionAiLedger.find('markTodoDone')!, ownTodo),
        isFalse,
      );
      final foreignTodo = AiTargetRef(
        kind: AiTargetKind.todo,
        side: AiResourceSide.group,
        groupId: 5,
        groupFullPath: 'acme/sub',
        parentIid: 3,
        origin: AiTargetOrigin.uiAdded,
      );
      expect(
        scopeAdmits(scope, productionAiLedger.find('snoozeTodo')!, foreignTodo),
        isFalse,
      );
      expect(_bind('', [foreignTodo], scope: scope).allBound, isFalse);
      const accountScope = AiWriteScope(
        accountKey: _account,
        grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
      );
      final malformed = AiTargetRef(
        kind: AiTargetKind.todo,
        groupId: 5,
        groupFullPath: 'acme/sub',
        parentIid: 3,
        origin: AiTargetOrigin.uiAdded,
      );
      expect(
        scopeAdmits(
          accountScope,
          productionAiLedger.find('snoozeTodo')!,
          malformed,
        ),
        isFalse,
      );
      expect(_bind('', [malformed], scope: accountScope).allBound, isFalse);
      expect(
        scopeAdmits(
          _projectScope,
          productionAiLedger.find('createNote')!,
          AiTargetRef(
            kind: AiTargetKind.groupWorkItem,
            groupId: 4,
            groupFullPath: 'acme/sub',
            projectId: 9,
            iid: 3,
          ),
        ),
        isFalse,
      );
    });
  });

  group('§15 row 10 scope', () {
    test('a conversation with no scope offers no write tools', () {
      const AiWriteScope empty = AiWriteScope(
        accountKey: _account,
        grants: <AiScopeGrant>[],
      );
      expect(empty.allowsWrites, isFalse);
      expect(offersWriteTools(empty), isFalse);
      expect(toolsForScope(empty), isEmpty);
      expect(
        decideTier(
          AiTierInput(
            level: AiAutonomyLevel.bypass,
            capability: productionAiLedger.find('setStar')!,
            scope: empty,
            binding: _bound,
            target: _projectTarget,
          ),
        ).decision,
        AiGateDecision.deny,
      );
    });

    test('a project issue opened from a group page keeps the project key', () {
      final AiScopeGrant grant = projectIssueFromGroupPage(
        projectId: 9,
        projectPath: 'group/app',
        iid: 4,
      );
      final String key = aiWriteScopeKey(_account, grant);
      expect(key, '($_account, project:9, workItem, 4)');
      expect(key.contains('group:'), isFalse);
      final AiWriteScope scope = AiWriteScope(
        accountKey: _account,
        grants: <AiScopeGrant>[grant],
      );
      expect(
        scopeAdmits(
          scope,
          productionAiLedger.find('updateIssue')!,
          _issue(9, 4),
        ),
        isTrue,
      );
      expect(
        scopeAdmits(scope, productionAiLedger.find('createNote')!, _note(9, 4)),
        isTrue,
      );
      expect(
        scopeAdmits(
          scope,
          productionAiLedger.find('addAwardEmoji')!,
          _emoji(9, 4),
        ),
        isTrue,
      );
      expect(
        scopeAdmits(
          scope,
          productionAiLedger.find('updateIssue')!,
          _issue(9, 5),
        ),
        isFalse,
      );
      expect(
        scopeAdmits(scope, productionAiLedger.find('setStar')!, _projectTarget),
        isFalse,
      );
      expect(
        scopeAdmits(
          scope,
          productionAiLedger.find('createIssue')!,
          _projectTarget,
        ),
        isFalse,
      );
      // Owner decision 2026-10-23: an issue or merge request conversation
      // may upload into its own project, and only that project.
      expect(
        scopeAdmits(
          scope,
          productionAiLedger.find('upload_attachment')!,
          _projectTarget,
        ),
        isTrue,
      );
      final Set<String> offered = toolsForScope(
        scope,
      ).map((AiCapability row) => row.operationId).toSet();
      expect(
        offered,
        containsAll(<String>[
          'updateIssue',
          'createNote',
          'moveBoardCard',
          'markTodoDone',
          'upload_attachment',
        ]),
      );
      for (final String operation in <String>[
        'setStar',
        'createIssue',
        'createDraftNote',
      ]) {
        expect(offered.contains(operation), isFalse, reason: operation);
      }
    });

    test('project, merge request and todo scopes offer different tools', () {
      expect(
        toolsForScope(_projectScope),
        hasLength(productionAiLedger.modelVisible.length - _groupOperations.length - 1),
      );
      final Set<String> projectTools = toolsForScope(
        _projectScope,
      ).map((AiCapability row) => row.operationId).toSet();
      expect(
        projectTools,
        containsAll(<String>['createProject', 'forkProject']),
      );
      expect(projectTools, isNot(contains('markAllTodosDone')));
      expect(projectTools.intersection(_groupOperations), isEmpty);
      expect(
        projectTools,
        {..._mr6b1Operations, ..._mr6b2Operations, ..._mr6b3Operations}
          ..remove('markAllTodosDone'),
      );
      final AiWriteScope merge = AiWriteScope(
        accountKey: _account,
        grants: <AiScopeGrant>[
          AiScopeGrant(
            kind: AiScopeKind.mergeRequest,
            projectId: 9,
            projectPath: 'group/app',
            iid: 4,
          ),
        ],
      );
      final Set<String> mergeTools = toolsForScope(
        merge,
      ).map((AiCapability row) => row.operationId).toSet();
      expect(
        mergeTools,
        containsAll(<String>[
          'updateMergeRequest',
          'createDraftNote',
          'createNote',
          'upload_attachment',
        ]),
      );
      expect(mergeTools, isNot(contains('updateIssue')));
      expect(mergeTools, isNot(contains('setStar')));
      final AiWriteScope todos = AiWriteScope(
        accountKey: _account,
        grants: const <AiScopeGrant>[
          AiScopeGrant(kind: AiScopeKind.accountGlobal),
        ],
      );
      expect(
        toolsForScope(
          todos,
        ).map((AiCapability row) => row.operationId).toList(),
        <String>[
          'markTodoDone',
          'snoozeTodo',
          'unsnoozeTodo',
          'markAllTodosDone',
        ],
      );
      final AiWriteScope groupOnly = AiWriteScope(
        accountKey: _account,
        grants: <AiScopeGrant>[
          AiScopeGrant(
            kind: AiScopeKind.groupWorkItem,
            groupFullPath: 'acme',
            iid: 1,
          ),
        ],
      );
      expect(offersWriteTools(groupOnly), isFalse); // Missing numeric group ID.
    });

    test('production group scope offers only group aliases and snoozes', () {
      expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
      const scope = AiWriteScope(
        accountKey: _account,
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.groupWorkItem,
            groupId: 4,
            groupFullPath: 'acme',
            iid: 1,
          ),
        ],
      );
      final offered = toolsForScope(scope).map((row) => row.operationId).toSet();
      expect(offered, {..._groupOperations, 'snoozeTodo', 'unsnoozeTodo'});
      expect(offered, isNot(contains('markTodoDone')));
    });

    test('gate-off override refuses a valid group-only scope', () {
      aiGroupWorkItemWritesEnabledForTesting = false;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      const scope = AiWriteScope(
        accountKey: _account,
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.groupWorkItem,
            groupId: 4,
            groupFullPath: 'acme',
            iid: 1,
          ),
        ],
      );
      expect(offersWriteTools(scope), isFalse);
      expect(toolsForScope(scope), isEmpty);
    });
  });

  group('§15 row 15 intent catalogs', () {
    test('every language has intent, negation and condition phrases', () {
      expect(appLanguages, hasLength(24));
      const Set<String> generic = <String>{
        'ok',
        'main',
        'readme',
        'merge',
        'delete',
        'diff',
        '好',
        '完成',
      };
      for (final AppLanguage language in appLanguages) {
        for (final AiIntentDirection direction in AiIntentDirection.values) {
          final List<String> phrases = AiIntentLexicon.phrases(
            language,
            direction,
          );
          expect(phrases, isNotEmpty, reason: '${language.tag} $direction');
          for (final String phrase in phrases) {
            expect(phrase.length, greaterThan(1), reason: phrase);
            expect(
              generic.contains(phrase.toLowerCase()),
              isFalse,
              reason: phrase,
            );
          }
        }
        expect(
          AiIntentLexicon.negations(language),
          isNotEmpty,
          reason: language.tag,
        );
        expect(
          AiIntentLexicon.conditions(language),
          isNotEmpty,
          reason: language.tag,
        );
      }
    });

    test('only the automatic T1 directions have intent phrases', () {
      const Set<String> withIntent = <String>{
        'setStar',
        'setSubscribed',
        'addAwardEmoji',
        'removeAwardEmoji',
        'setWorkItemActivityNoteReaction',
        'setWorkItemNotifications',
        'setGroupWorkItemActivityNoteReaction',
        'setGroupWorkItemNotifications',
        'markTodoDone',
        'snoozeTodo',
        'unsnoozeTodo',
      };
      for (final String operation in withIntent) {
        expect(directionsFor(operation), isNotEmpty, reason: operation);
      }
      expect(
        requestedIntentDirection('setGroupWorkItemActivityNoteReaction', {
          'add': true,
        }, null),
        AiIntentDirection.workItemReactionAdd,
      );
      expect(
        requestedIntentDirection('setGroupWorkItemActivityNoteReaction', {
          'add': false,
        }, null),
        AiIntentDirection.workItemReactionRemove,
      );
      expect(
        requestedIntentDirection('setGroupWorkItemNotifications', {
          'enabled': true,
        }, null),
        AiIntentDirection.workItemNotificationsOn,
      );
      expect(
        requestedIntentDirection('setGroupWorkItemNotifications', {
          'enabled': false,
        }, null),
        AiIntentDirection.workItemNotificationsOff,
      );
      for (final AiCapability row in ProductionAiLedger.rows) {
        if (row.baseTier == AiWriteTier.t1) {
          expect(
            directionsFor(row.operationId),
            isNotEmpty,
            reason: 'T1 row ${row.operationId}',
          );
        }
        if (withIntent.contains(row.operationId)) continue;
        expect(
          directionsFor(row.operationId),
          isEmpty,
          reason: row.operationId,
        );
      }
      for (final String operation in <String>[
        'createNote',
        'edit_file',
        'deleteProject',
        'markAllTodosDone',
        'mergeRequest',
        'upload_attachment',
      ]) {
        expect(directionsFor(operation), isEmpty, reason: operation);
      }
      expect(
        productionAiLedger.modelVisible
            .map((AiCapability row) => row.operationId)
            .toSet(),
        _productionOperations,
      );
      for (final AiCapability row in ProductionAiLedger.rows) {
        expect(
          row.modelVisible,
          _productionOperations.contains(row.operationId),
          reason: row.operationId,
        );
      }
      expect(
        productionAiLedger.find('upload_attachment')!.namedMethod,
        'uploadProjectFile',
      );
      // Visible since catalogue 4: the graph families and their snooze
      // directions are offered to the model.
      expect(productionAiLedger.find('snoozeTodo')!.modelVisible, isTrue);
      expect(productionAiLedger.find('unsnoozeTodo')!.modelVisible, isTrue);
      expect(aiFixedConfirmOperationIds, <String>{'markAllTodosDone'});
      expect(AiWriteLimits.writesPerSend, 8);
      expect(AiWriteLimits.t4PerSend, 3);
      expect(AiWriteLimits.writesPerConversation, 40);
      expect(AiWriteLimits.t4PerConversation, 10);
      expect(AiWriteLimits.writesPerAccountPerRollingHour, 60);
      expect(AiWriteLimits.t4PerAccountPerRollingHour, 10);
      expect(AiWriteLimits.rollingWindow, const Duration(minutes: 60));
      expect(AiWriteLimits.batchResourceCap, 20);
      expect(AiWriteLimits.httpPerSend, 40);
      expect(AiWriteLimits.rereadHttp, 10);
      expect(
        AiWriteLimits.journalResetConfirmWindow,
        const Duration(hours: 24),
      );
    });
  });

  group('§15 row 16 target binding and intent words', () {
    test('ordinary words do not bind, and a file needs every component', () {
      final AiTargetRef file = AiTargetRef(
        kind: AiTargetKind.file,
        projectId: 9,
        projectPath: 'group/app',
        refName: 'main',
        path: 'src/app.dart',
      );
      expect(
        _bind('see main and README', <AiTargetRef>[file]).allBound,
        isFalse,
      );
      expect(
        _bind('see main and README', <AiTargetRef>[file]).missingComponents,
        <String>['ref', 'path'],
      );
      expect(
        _bind('update `src/app.dart`', <AiTargetRef>[file]).missingComponents,
        <String>['ref'],
      );
      expect(
        _bind('update `src/app.dart` on `main`', <AiTargetRef>[file]).allBound,
        isTrue,
      );
      expect(
        _bind('update `src/app.dart` on `develop`', <AiTargetRef>[
          file,
        ]).allBound,
        isFalse,
      );
      final AiTargetRef otherRef = AiTargetRef(
        kind: AiTargetKind.file,
        projectId: 9,
        projectPath: 'group/app',
        refName: 'develop',
        path: 'src/app.dart',
      );
      expect(
        _bind('`refs/heads/main` `src/app.dart`', <AiTargetRef>[file]).allBound,
        isTrue,
      );
      expect(
        _bind('`refs/heads/main` `src/app.dart`', <AiTargetRef>[
          otherRef,
        ]).allBound,
        isFalse,
      );
    });

    test(
      'bare iids are ambiguous across projects, and qualified iids are not',
      () {
        final AiWriteScope scope = _twoProjects;
        final AiTargetRef first = _issue(1, 5, path: 'group/a');
        final AiTargetRef second = _issue(2, 5, path: 'group/b');
        expect(
          _bind('#5', <AiTargetRef>[first], scope: scope).allBound,
          isFalse,
        );
        expect(
          _bind('group/a#5', <AiTargetRef>[first], scope: scope).allBound,
          isTrue,
        );
        expect(
          _bind('group/a#5', <AiTargetRef>[second], scope: scope).allBound,
          isFalse,
        );
        expect(
          _bind('group/b!5', <AiTargetRef>[
            _merge(2, 5, path: 'group/b'),
          ], scope: scope).allBound,
          isTrue,
        );
        expect(
          _bind('#5', <AiTargetRef>[
            _issue(9, 5),
          ], scope: _projectScope).allBound,
          isTrue,
        );
      },
    );

    test(
      'a group work item binds from the open item, a URL or the UI, not from #iid',
      () {
        final GitLabInstance instance = GitLabInstance.parse(
          'https://gitlab.example',
        );
        final identity = VerifiedGroupWorkItemIdentity.fromServerEvidence(
          instance: instance,
          expectedUserId: 7,
          actorUserId: 7,
          expectedGroupId: 4,
          expectedFullPath: 'acme/sub',
          expectedIid: 3,
          apiOwner: Object(),
          generation: 1,
          readEpoch: 1,
          namespace: {
            'id': 'gid://gitlab/Group/4',
            'fullPath': 'acme/sub',
            'workItem': {
              'id': 'gid://gitlab/WorkItem/99',
              'iid': '3',
              'project': null,
              'namespace': {
                'id': 'gid://gitlab/Group/4',
                'fullPath': 'acme/sub',
              },
            },
          },
        )!;
        final AiWriteScope scope = AiWriteScope(
          accountKey: '${instance.key}#7',
          instance: instance,
          uiAddedGroupWorkItems: [identity],
          grants: <AiScopeGrant>[
            AiScopeGrant(
              kind: AiScopeKind.groupWorkItem,
              groupFullPath: 'acme/sub',
              groupId: 4,
              iid: 3,
            ),
          ],
        );
        final AiTargetRef current = AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupFullPath: 'acme/sub',
          groupId: 4,
          iid: 3,
        );
        final AiTargetRef other = AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupFullPath: 'acme/sub',
          groupId: 4,
          iid: 9,
        );
        expect(
          _bind('', <AiTargetRef>[current], scope: scope).allBound,
          isTrue,
        );
        expect(
          _bind('#9', <AiTargetRef>[other], scope: scope).allBound,
          isFalse,
        );
        expect(
          _bind(
            'https://gitlab.example/groups/acme/sub/-/work_items/9',
            <AiTargetRef>[other],
            scope: scope,
          ).allBound,
          isFalse,
        );
        expect(
          _bind(
            'https://evil.example/groups/acme/sub/-/work_items/9',
            <AiTargetRef>[other],
            scope: scope,
          ).allBound,
          isFalse,
        );
        expect(
          _bind('', <AiTargetRef>[
            AiTargetRef(
              kind: AiTargetKind.groupWorkItem,
              groupFullPath: 'acme/sub',
              groupId: 4,
              iid: 3,
              workItemGid: 'gid://gitlab/WorkItem/99',
              origin: AiTargetOrigin.uiAdded,
            ),
          ], scope: scope).allBound,
          isTrue,
        );
        expect(
          _bind('', <AiTargetRef>[
            AiTargetRef(
              kind: AiTargetKind.groupWorkItem,
              groupFullPath: 'acme/sub',
              groupId: 4,
              iid: 3,
              workItemGid: 'gid://gitlab/WorkItem/100',
              origin: AiTargetOrigin.uiAdded,
            ),
          ], scope: scope).allBound,
          isFalse,
        );
        const capability = AiCapability(
          operationId: 'updateGroupWorkItemState',
          baseTier: AiWriteTier.t2,
          scopeClass: AiScopeClass.groupWorkItem,
        );
        aiGroupWorkItemWritesEnabledForTesting = true;
        addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
        expect(
          scopeAdmits(
            scope,
            capability,
            AiTargetRef(
              kind: AiTargetKind.groupWorkItem,
              groupFullPath: 'acme/sub',
              groupId: 4,
              iid: 3,
              workItemGid: 'gid://gitlab/WorkItem/100',
              origin: AiTargetOrigin.uiAdded,
            ),
          ),
          isFalse,
        );
        expect(
          scopeAdmits(
            scope,
            capability,
            AiTargetRef(
              kind: AiTargetKind.groupWorkItem,
              groupFullPath: 'acme/sub',
              groupId: 4,
              iid: 3,
              workItemGid: 'gid://gitlab/WorkItem/99',
              origin: AiTargetOrigin.uiAdded,
            ),
          ),
          isTrue,
        );
      },
    );

    test(
      'merge needs the request and both branches, and a new branch needs its name and source',
      () {
        final AiWriteScope scope = AiWriteScope(
          accountKey: _account,
          grants: <AiScopeGrant>[
            AiScopeGrant(
              kind: AiScopeKind.mergeRequest,
              projectId: 9,
              projectPath: 'group/app',
              iid: 4,
            ),
          ],
        );
        final AiTargetRef merge = AiTargetRef(
          kind: AiTargetKind.merge,
          projectId: 9,
          projectPath: 'group/app',
          iid: 4,
          sourceRef: 'feature',
          targetRef: 'main',
        );
        expect(
          _bind('', <AiTargetRef>[merge], scope: scope).missingComponents,
          containsAll(<String>['source', 'target']),
        );
        expect(
          _bind('`feature`', <AiTargetRef>[
            merge,
          ], scope: scope).missingComponents,
          <String>['target'],
        );
        expect(
          _bind('`feature` into `main`', <AiTargetRef>[
            merge,
          ], scope: scope).allBound,
          isTrue,
        );
        final AiTargetRef branch = AiTargetRef(
          kind: AiTargetKind.newBranch,
          projectId: 9,
          projectPath: 'group/app',
          name: 'feature/next',
          sourceRef: 'main',
        );
        expect(_bind('from main', <AiTargetRef>[branch]).allBound, isFalse);
        expect(
          _bind('`feature/next` from `main`', <AiTargetRef>[branch]).allBound,
          isTrue,
        );
      },
    );

    test('a job id from a tool result does not bind, a pipeline URL can', () {
      final GitLabInstance instance = GitLabInstance.parse(
        'https://gitlab.example/gitlab',
      );
      final AiWriteScope scope = AiWriteScope(
        accountKey: '${instance.key}#7',
        instance: instance,
        grants: <AiScopeGrant>[
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: 9,
            projectPath: 'group/app',
          ),
        ],
      );
      AiTargetRef job({
        bool belongs = false,
        bool created = false,
        AiTargetOrigin origin = AiTargetOrigin.toolResult,
      }) {
        return AiTargetRef(
          kind: AiTargetKind.job,
          origin: origin,
          projectId: 9,
          projectPath: 'group/app',
          pipelineId: 40,
          jobId: 7,
          jobBelongsToBoundPipeline: belongs,
          pipelineCreatedInSegment: created,
        );
      }

      expect(
        _bind('retry 7', <AiTargetRef>[job()], scope: scope).allBound,
        isFalse,
      );
      expect(
        _bind(
          'https://gitlab.example/gitlab/group/app/-/pipelines/40',
          <AiTargetRef>[job(belongs: true)],
          scope: scope,
        ).allBound,
        isTrue,
      );
      expect(
        _bind(
          'https://gitlab.example/gitlab/group/app/-/pipelines/40',
          <AiTargetRef>[job()],
          scope: scope,
        ).allBound,
        isFalse,
      );
      expect(
        _bind('https://gitlab.example/gitlab/group/app/-/jobs/7', <AiTargetRef>[
          job(),
        ], scope: scope).allBound,
        isTrue,
      );
      expect(
        _bind('', <AiTargetRef>[
          job(belongs: true, created: true),
        ], scope: scope).allBound,
        isTrue,
      );
      expect(
        _bind('https://gitlab.example/group/app/-/jobs/7', <AiTargetRef>[
          job(),
        ], scope: scope).allBound,
        isFalse,
      );
    });

    test(
      'direction, negation, quotes, conditions and restored history do not authorize T1',
      () {
        final AppLanguage zh = languageForTag('zh-TW')!;
        final String star = AiIntentLexicon.phrases(
          zh,
          AiIntentDirection.star,
        ).first;
        final String unstar = AiIntentLexicon.phrases(
          zh,
          AiIntentDirection.unstar,
        ).first;
        expect(unstar.contains(star), isTrue);
        expect(_intent(star, starred: true).intentAuthorizesLowRisk, isTrue);
        expect(_intent(unstar, starred: true).intentAuthorizesLowRisk, isFalse);
        expect(_intent(unstar, starred: false).intentAuthorizesLowRisk, isTrue);
        expect(
          _intent('$star $unstar', starred: true).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent('不要$star', starred: true).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent('如果$star', starred: true).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent('> $star', starred: true).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent('```\n$star\n```', starred: true).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent('`$star`', starred: true).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent(
            '$star ${'x' * aiIntentPasteLineLength}',
            starred: true,
          ).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent(star, starred: true, restored: true).intentAuthorizesLowRisk,
          isFalse,
        );
        final AiBindingResult restoredIssue = bindTargets(
          userMessage: '#12 $star',
          restoredFromHistory: true,
          scope: _projectScope,
          targets: <AiTargetRef>[_issue(9, 12)],
          interfaceLanguage: 'zh-TW',
          deviceLanguages: const <String>[],
          operationId: 'setStar',
          arguments: const <String, Object?>{'starred': true},
        );
        expect(restoredIssue.allBound, isFalse);
        expect(restoredIssue.intentAuthorizesLowRisk, isFalse);
        final AiTierDecision tier = decideTier(
          AiTierInput(
            level: AiAutonomyLevel.lowRiskAuto,
            capability: productionAiLedger.find('setStar')!,
            scope: _projectScope,
            binding: restoredIssue,
            target: _projectTarget,
            arguments: const <String, Object?>{'starred': true},
          ),
        );
        expect(tier.decision, AiGateDecision.requireApproval);
        expect(
          _intent(
            'do not $star',
            starred: true,
            deviceLanguages: const <String>['en-US'],
          ).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent(
            'diff the README then $star',
            starred: true,
          ).intentAuthorizesLowRisk,
          isTrue,
        );
        for (final String generic in <String>[
          'OK',
          '好',
          '完成',
          'main',
          'README',
          'merge',
          'diff',
        ]) {
          expect(
            _intent(generic, starred: true).intentAuthorizesLowRisk,
            isFalse,
            reason: generic,
          );
        }
      },
    );

    test(
      'each language hits its own star phrase and misses another language',
      () {
        final String japanese = AiIntentLexicon.phrases(
          languageForTag('ja')!,
          AiIntentDirection.star,
        ).first;
        expect(
          _intent(
            japanese,
            starred: true,
            interfaceLanguage: 'en',
          ).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent(
            japanese,
            starred: true,
            interfaceLanguage: 'en',
            deviceLanguages: const <String>['ja-JP'],
          ).intentAuthorizesLowRisk,
          isTrue,
        );
        for (final AppLanguage language in appLanguages) {
          final String phrase = AiIntentLexicon.phrases(
            language,
            AiIntentDirection.star,
          ).first;
          final AiBindingResult binding = _intent(
            phrase,
            starred: true,
            interfaceLanguage: language.tag,
          );
          expect(
            binding.intentAuthorizesLowRisk,
            isTrue,
            reason: '${language.tag} $phrase',
          );
          expect(binding.allBound, isTrue, reason: language.tag);
        }
        expect(
          _intent(
            'please unstar',
            starred: true,
            interfaceLanguage: 'en',
          ).intentAuthorizesLowRisk,
          isFalse,
        );
        expect(
          _intent(
            'please unstar',
            starred: false,
            interfaceLanguage: 'en',
          ).intentAuthorizesLowRisk,
          isTrue,
        );
        expect(
          _intent(
            'please star',
            starred: true,
            interfaceLanguage: 'en',
          ).intentAuthorizesLowRisk,
          isTrue,
        );
      },
    );

    test('the card keeps the user text and the already redacted reason', () {
      final AiBindingResult binding = _intent(
        '標星',
        starred: true,
        reason: 'because',
      );
      expect(binding.userMessage, '標星');
      expect(binding.redactedReason, 'because');
    });
  });
}

const String _account = 'https://gitlab.example#7';

const AiBindingResult _bound = AiBindingResult(
  userMessage: 'bound',
  allBound: true,
  intentAuthorizesLowRisk: true,
);

final AiWriteScope _projectScope = AiWriteScope(
  accountKey: _account,
  grants: <AiScopeGrant>[
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'group/app',
    ),
  ],
);

final AiWriteScope _twoProjects = AiWriteScope(
  accountKey: _account,
  grants: <AiScopeGrant>[
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 1,
      projectPath: 'group/a',
    ),
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 2,
      projectPath: 'group/b',
    ),
  ],
);

final AiTargetRef _projectTarget = AiTargetRef(
  kind: AiTargetKind.project,
  projectId: 9,
  projectPath: 'group/app',
);

AiTargetRef _issue(int projectId, int iid, {String path = 'group/app'}) {
  return AiTargetRef(
    kind: AiTargetKind.issue,
    projectId: projectId,
    projectPath: path,
    iid: iid,
  );
}

AiTargetRef _merge(int projectId, int iid, {required String path}) {
  return AiTargetRef(
    kind: AiTargetKind.mergeRequest,
    projectId: projectId,
    projectPath: path,
    iid: iid,
  );
}

AiTargetRef _note(int projectId, int iid) {
  return AiTargetRef(
    kind: AiTargetKind.note,
    projectId: projectId,
    projectPath: 'group/app',
    parentIid: iid,
  );
}

AiTargetRef _emoji(int projectId, int iid) {
  return AiTargetRef(
    kind: AiTargetKind.emoji,
    projectId: projectId,
    projectPath: 'group/app',
    parentIid: iid,
  );
}

const Set<String> _mr6b1Operations = <String>{
  'addAwardEmoji',
  'removeAwardEmoji',
  'setStar',
  'setSubscribed',
  'markTodoDone',
  'createNote',
  'updateNote',
  'createIssue',
  'updateIssue',
  'createMergeRequest',
  'updateMergeRequest',
  'unapproveMergeRequest',
  'createTodo',
  'createDiscussion',
  'createDiscussionNote',
  'updateDiscussionNote',
  'setDiscussionResolved',
  'createDraftNote',
  'updateDraftNote',
  'createLabel',
  'updateLabel',
  'createMilestone',
  'updateMilestone',
  'setMilestoneState',
  'createBoard',
  'renameBoard',
  'setBoardSystemListHidden',
  'createBoardList',
  'moveBoardList',
  'moveBoardCard',
  'upload_attachment',
};

const Set<String> _mr6b2Operations = <String>{
  'edit_file',
  'createFile',
  'deleteFile',
  'applySuggestion',
  'createBranch',
  'deleteBranch',
  'createTag',
  'deleteTag',
  'createRelease',
  'updateRelease',
  'deleteRelease',
  'mergeRequest',
  'approveMergeRequest',
  'rebaseMergeRequest',
  'cancelAutoMerge',
  'publishDraftNotes',
  'deleteDraftNote',
  'createPipeline',
  'pipelineAction',
  'jobAction',
  'playPipelineSchedule',
  'deletePipeline',
  'createSnippet',
  'updateSnippetMetadata',
  'updateSnippet',
  'updateSnippetFiles',
  'deleteSnippetFile',
  'deleteSnippet',
  'deleteNote',
  'deleteDiscussionNote',
  'deleteIssue',
  'deleteMergeRequest',
  'deleteLabel',
  'deleteMilestone',
  'deleteBoard',
  'deleteBoardList',
  'markAllTodosDone',
  'deletePackage',
  'deletePackageFile',
  'deleteContainerRepository',
  'deleteContainerTag',
  'createProject',
  'editProject',
  'deleteProject',
  'forkProject',
};

const _groupOperations = <String>{
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

const Set<String> _productionOperations = <String>{
  ..._mr6b1Operations,
  ..._mr6b2Operations,
  ..._mr6b3Operations,
  ..._groupOperations,
};

// MR6b-3 graph writes, visible since catalogue 4 (P14).
const Set<String> _mr6b3Operations = <String>{
  'updateWorkItemContent',
  'editWorkItemActivityNote',
  'updateWorkItemLabels',
  'createWorkItemActivityComment',
  'createWorkItemActivityReply',
  'deleteWorkItemActivityNote',
  'updateWorkItemAssignees',
  'updateWorkItemDates',
  'updateWorkItemHealthStatus',
  'updateWorkItemMilestone',
  'updateWorkItemWeight',
  'updateWorkItemState',
  'updateWorkItemStatus',
  'setIncidentStatus',
  'setWorkItemNotifications',
  'setWorkItemActivityNoteReaction',
  'snoozeTodo',
  'unsnoozeTodo',
};

AiGateDecision _matrix(AiAutonomyLevel level, AiWriteTier tier) {
  switch (level) {
    case AiAutonomyLevel.readOnly:
      return AiGateDecision.deny;
    case AiAutonomyLevel.confirmEach:
      return AiGateDecision.requireApproval;
    case AiAutonomyLevel.lowRiskAuto:
      return tier == AiWriteTier.t1
          ? AiGateDecision.execute
          : AiGateDecision.requireApproval;
    case AiAutonomyLevel.conversationGrant:
      if (tier == AiWriteTier.t4 || tier == AiWriteTier.hardLine) {
        return AiGateDecision.requireApproval;
      }
      return AiGateDecision.execute;
    case AiAutonomyLevel.bypass:
      return tier == AiWriteTier.hardLine
          ? AiGateDecision.requireApproval
          : AiGateDecision.execute;
  }
}

AiTierDecision _decide({
  required String operationId,
  required AiWriteTier tier,
  required AiAutonomyLevel level,
  AiTierFacts facts = const AiTierFacts(),
  Map<String, Object?> arguments = const <String, Object?>{},
  AiBindingResult binding = _bound,
  String? typedName = 'kept-name',
  AiScopeClass scopeClass = AiScopeClass.project,
}) {
  final bool account = scopeClass == AiScopeClass.accountTodo;
  return decideTier(
    AiTierInput(
      level: level,
      capability: AiCapability(
        operationId: operationId,
        baseTier: tier,
        scopeClass: scopeClass,
        modelVisible: false,
      ),
      scope: account
          ? const AiWriteScope(
              accountKey: _account,
              grants: <AiScopeGrant>[
                AiScopeGrant(kind: AiScopeKind.accountGlobal),
              ],
            )
          : _projectScope,
      binding: binding,
      target: account ? AiTargetRef(kind: AiTargetKind.todo) : _projectTarget,
      facts: facts,
      typedName: typedName,
      arguments: arguments,
    ),
  );
}

AiBindingResult _bind(
  String message,
  List<AiTargetRef> targets, {
  AiWriteScope? scope,
  String operationId = 'createNote',
}) {
  return bindTargets(
    userMessage: message,
    restoredFromHistory: false,
    scope: scope ?? _projectScope,
    targets: targets,
    interfaceLanguage: 'zh-TW',
    deviceLanguages: const <String>[],
    operationId: operationId,
  );
}

AiBindingResult _intent(
  String message, {
  required bool starred,
  bool restored = false,
  String interfaceLanguage = 'zh-TW',
  List<String> deviceLanguages = const <String>[],
  String? reason,
}) {
  return bindTargets(
    userMessage: message,
    restoredFromHistory: restored,
    scope: _projectScope,
    targets: <AiTargetRef>[_projectTarget],
    interfaceLanguage: interfaceLanguage,
    deviceLanguages: deviceLanguages,
    operationId: 'setStar',
    arguments: <String, Object?>{'starred': starred},
    redactedReason: reason,
  );
}
