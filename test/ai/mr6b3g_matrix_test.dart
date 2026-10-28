import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';

import 'mr6b3g_support.dart';
import 'mr6b3g_t1_test.dart' as group_t1;

// Policy tests use the real, still-hidden production rows and the group test
// gate. They exercise tier decisions, not the family HTTP implementations.
const _tiers = <String, AiWriteTier>{
  'updateGroupWorkItemState': AiWriteTier.t2,
  'updateGroupWorkItemStatus': AiWriteTier.t2,
  'updateGroupWorkItemDates': AiWriteTier.t2,
  'updateGroupWorkItemHealthStatus': AiWriteTier.t2,
  'updateGroupWorkItemAssignees': AiWriteTier.t2,
  'updateGroupWorkItemMilestone': AiWriteTier.t2,
  'updateGroupWorkItemWeight': AiWriteTier.t2,
  'updateGroupWorkItemLabels': AiWriteTier.t2,
  'updateGroupWorkItemContent': AiWriteTier.t2,
  'createGroupWorkItemActivityComment': AiWriteTier.t2,
  'createGroupWorkItemActivityReply': AiWriteTier.t2,
  'editGroupWorkItemActivityNote': AiWriteTier.t2,
  'deleteGroupWorkItemActivityNote': AiWriteTier.t4,
  'setGroupWorkItemActivityNoteReaction': AiWriteTier.t1,
  'setGroupWorkItemNotifications': AiWriteTier.t1,
};
final _aliases = _tiers.keys;

AiTierDecision _decide(
  String operation,
  AiAutonomyLevel level, {
  bool bound = true,
  bool intent = true,
  AiTierFacts facts = const AiTierFacts(),
}) => decideTier(
  AiTierInput(
    level: level,
    capability: productionAiLedger.find(operation)!,
    scope: g0eScope,
    binding: AiBindingResult(
      userMessage: 'Synthetic explicit user request',
      allBound: bound,
      intentAuthorizesLowRisk: intent,
    ),
    target: AiTargetRef(
      kind: AiTargetKind.groupWorkItem,
      groupId: 7,
      groupFullPath: g0ePath,
      iid: 5,
    ),
    typedName: '$g0ePath#5',
    facts: facts,
  ),
);

void main() {
  setUp(() => aiGroupWorkItemWritesEnabledForTesting = true);
  tearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);

  // Re-run the family-owned real-port fixtures here for cross-family
  // acceptance, including their 24-locale direction and adversarial corpus.
  group('G15 repeated group T1 family fixtures', group_t1.main);

  test(
    'all fifteen actual group rows stay hidden while policy tests use their tiers',
    () {
      expect(_aliases, hasLength(15));
      for (final name in _aliases) {
        final row = productionAiLedger.find(name);
        expect(row, isNotNull, reason: name);
        expect(row!.modelVisible, isFalse, reason: name);
        expect(row.baseTier, _tiers[name], reason: name);
        expect(row.scopeClass, AiScopeClass.groupWorkItem, reason: name);
        expect(row.boundary, AiWriteBoundary.graph, reason: name);
      }
      expect(aiGroupWorkItemWritesEnabled, isFalse);
    },
  );

  for (final name in _aliases) {
    for (final level in AiAutonomyLevel.values) {
      test('$name ${level.name} applies the five-level group policy', () {
        final decision = _decide(name, level);
        final tier = _tiers[name]!;
        final expected = switch ((level, tier)) {
          (AiAutonomyLevel.readOnly, _) => AiGateDecision.deny,
          (AiAutonomyLevel.confirmEach, _) => AiGateDecision.requireApproval,
          (AiAutonomyLevel.lowRiskAuto, AiWriteTier.t1) =>
            AiGateDecision.execute,
          (AiAutonomyLevel.lowRiskAuto, _) => AiGateDecision.requireApproval,
          (
            AiAutonomyLevel.conversationGrant,
            AiWriteTier.t1 || AiWriteTier.t2,
          ) =>
            AiGateDecision.execute,
          (AiAutonomyLevel.conversationGrant, _) =>
            AiGateDecision.requireApproval,
          (AiAutonomyLevel.bypass, AiWriteTier.hardLine) =>
            AiGateDecision.requireApproval,
          (AiAutonomyLevel.bypass, _) => AiGateDecision.execute,
        };
        expect(decision.tier, tier);
        expect(decision.decision, expected);
        if (tier == AiWriteTier.t4 &&
            expected == AiGateDecision.requireApproval) {
          expect(decision.requiresTypedName, isTrue);
          expect(decision.typedName, '$g0ePath#5');
        }
      });
    }
  }

  for (final name in _aliases) {
    test('$name bypass still confirms an unbound target', () {
      final result = _decide(name, AiAutonomyLevel.bypass, bound: false);
      expect(result.decision, AiGateDecision.requireApproval);
      expect(result.reasons, contains(AiFixedConfirmReason.targetUnbound));
    });
  }

  for (final name in [
    'setGroupWorkItemNotifications',
    'setGroupWorkItemActivityNoteReaction',
  ]) {
    test('$name low risk automatic requires trusted directional intent', () {
      final result = _decide(name, AiAutonomyLevel.lowRiskAuto, intent: false);
      expect(result.decision, AiGateDecision.requireApproval);
      expect(result.reasons, contains(AiFixedConfirmReason.intentNotUnique));
    });
  }

  for (final facts in [
    const AiTierFacts(confidentialLowered: true),
    const AiTierFacts(visibilityRaised: true),
    const AiTierFacts(touchesCiConfig: true),
  ]) {
    for (final level in AiAutonomyLevel.values) {
      test(
        'hard-line fact $facts at ${level.name} remains typed confirmation',
        () {
          final result = _decide(
            'updateGroupWorkItemState',
            level,
            facts: facts,
          );
          expect(result.tier, AiWriteTier.hardLine);
          if (level == AiAutonomyLevel.readOnly) {
            expect(result.decision, AiGateDecision.deny);
          } else {
            expect(result.decision, AiGateDecision.requireApproval);
            expect(result.requiresTypedName, isTrue);
          }
        },
      );
    }
  }
}
