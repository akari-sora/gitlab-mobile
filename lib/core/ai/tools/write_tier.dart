import 'target_binding.dart';
import 'write_ledger.dart';

export 'write_levels.dart';

enum AiGateDecision { deny, requireApproval, execute }

final class AiTierFacts {
  const AiTierFacts({
    this.protectedOrDefaultBranch = false,
    this.removeSourceBranch = false,
    this.confidentialLowered = false,
    this.visibilityRaised = false,
    this.newSnippetNotPrivate = false,
    this.touchesCiConfig = false,
    this.pipelineVariables = false,
    this.scheduleParamsUnsafe = false,
    this.squash = false,
    this.triggersPipeline = false,
    this.reasons = const <AiFixedConfirmReason>[],
  });

  final bool protectedOrDefaultBranch;
  final bool removeSourceBranch;
  final bool confidentialLowered;
  final bool visibilityRaised;
  final bool newSnippetNotPrivate;
  final bool touchesCiConfig;
  final bool pipelineVariables;
  final bool scheduleParamsUnsafe;

  /// Shown on the preview. It does not raise the tier.
  final bool squash;

  /// A pipeline started by the write itself. It does not raise the tier.
  final bool triggersPipeline;
  final List<AiFixedConfirmReason> reasons;
}

final class AiTierInput {
  const AiTierInput({
    required this.level,
    required this.capability,
    required this.scope,
    required this.binding,
    required this.target,
    this.facts = const AiTierFacts(),
    this.typedName,
    this.arguments = const <String, Object?>{},
  });

  final AiAutonomyLevel level;
  final AiCapability capability;
  final AiWriteScope scope;
  final AiBindingResult binding;
  final AiTargetRef target;
  final AiTierFacts facts;

  /// Pre-read confirmation name. Missing when a name is required means the
  /// proposal must not be shown.
  final String? typedName;
  final Map<String, Object?> arguments;
}

final class AiTierDecision {
  const AiTierDecision({
    required this.decision,
    required this.tier,
    required this.requiresTypedName,
    required this.typedName,
    required this.reasons,
    this.reusesStoredVariables = false,
    this.showSquash = false,
    this.cancelMayRunAfterScript = false,
    this.known = true,
    this.scopeDenied = false,
  });

  const AiTierDecision.unknown()
    : decision = AiGateDecision.deny,
      tier = AiWriteTier.t1,
      requiresTypedName = false,
      typedName = null,
      reasons = const <AiFixedConfirmReason>[],
      reusesStoredVariables = false,
      showSquash = false,
      cancelMayRunAfterScript = false,
      known = false,
      scopeDenied = false;

  const AiTierDecision.denied(this.tier, {this.scopeDenied = false})
    : decision = AiGateDecision.deny,
      requiresTypedName = false,
      typedName = null,
      reasons = const <AiFixedConfirmReason>[],
      reusesStoredVariables = false,
      showSquash = false,
      cancelMayRunAfterScript = false,
      known = true;

  final AiGateDecision decision;
  final AiWriteTier tier;
  final bool requiresTypedName;
  final String? typedName;
  final List<AiFixedConfirmReason> reasons;

  /// Retry and play may reuse variables already stored on GitLab.
  final bool reusesStoredVariables;
  final bool showSquash;

  /// Cancel can still start the job's after_script.
  final bool cancelMayRunAfterScript;

  /// False when the operation is not on the ledger passed to the gate.
  final bool known;

  /// Only an unresolved owner/scope check may wait for a todo pre-read.
  /// A level denial remains final even when the owner is not known yet.
  final bool scopeDenied;

  bool get canPropose {
    final String? name = typedName;
    return known &&
        decision != AiGateDecision.deny &&
        (!requiresTypedName || (name != null && name.isNotEmpty));
  }
}

/// Null from the ledger is an unknown operation: deny, and do not propose.
AiTierDecision decideListed({
  required AiCapabilityLedger ledger,
  required String operationId,
  required AiTierInput Function(AiCapability capability) build,
}) {
  final AiCapability? capability = ledger.find(operationId);
  if (capability == null) return const AiTierDecision.unknown();
  return decideTier(build(capability));
}

AiTierDecision decideTier(AiTierInput input) {
  final AiCapability capability = input.capability;
  final AiWriteTier tier = _effectiveTier(
    capability.operationId,
    capability.baseTier,
    input.facts,
    input.arguments,
  );
  if (input.level == AiAutonomyLevel.readOnly) {
    return AiTierDecision.denied(tier);
  }
  if (!scopeAdmits(input.scope, capability, input.target)) {
    return AiTierDecision.denied(tier, scopeDenied: true);
  }
  var decision = _matrix(input.level, tier);
  final bool confirmOnly = _confirmOnly(
    capability.operationId,
    input.arguments,
  );
  final Set<AiFixedConfirmReason> reasons = <AiFixedConfirmReason>{
    ...input.binding.reasons,
    ...input.facts.reasons,
  };
  final AiFixedConfirmReason? operationReason =
      _fixedOperationReason[capability.operationId];
  if (operationReason != null) reasons.add(operationReason);
  if (input.level == AiAutonomyLevel.bypass) {
    reasons.removeAll(aiConfirmUnlessBypassReasons);
  }
  final bool intentMatters =
      input.level == AiAutonomyLevel.lowRiskAuto && tier == AiWriteTier.t1;
  if (!intentMatters || input.binding.intentAuthorizesLowRisk) {
    reasons.remove(AiFixedConfirmReason.intentNotUnique);
  } else {
    reasons.add(AiFixedConfirmReason.intentNotUnique);
  }
  if (input.binding.allBound) {
    reasons.remove(AiFixedConfirmReason.targetUnbound);
    reasons.remove(AiFixedConfirmReason.targetNamedNotMarked);
  } else if (reasons.contains(AiFixedConfirmReason.targetNamedNotMarked)) {
    reasons.remove(AiFixedConfirmReason.targetUnbound);
  } else {
    reasons.add(AiFixedConfirmReason.targetUnbound);
  }
  if (decision == AiGateDecision.execute && reasons.isNotEmpty) {
    decision = AiGateDecision.requireApproval;
  }
  final bool needsName =
      decision == AiGateDecision.requireApproval &&
      _needsName(tier, confirmOnly);
  final bool blocked = decision == AiGateDecision.deny;
  return AiTierDecision(
    decision: decision,
    tier: tier,
    requiresTypedName: needsName,
    typedName: _cleanName(input.typedName),
    reasons: _freeze(reasons),
    reusesStoredVariables: confirmOnly && !blocked,
    showSquash: input.facts.squash && !blocked,
    cancelMayRunAfterScript:
        _isCancel(capability.operationId, input.arguments) && !blocked,
  );
}

const Map<String, AiFixedConfirmReason> _fixedOperationReason =
    <String, AiFixedConfirmReason>{
      'markAllTodosDone': AiFixedConfirmReason.markAllTodosDone,
    };

const Set<String> _protectedBranchOperations = <String>{
  'edit_file',
  'createFile',
  'applySuggestion',
  'batchApplySuggestions',
  'mergeRequest',
};

AiWriteTier _effectiveTier(
  String operationId,
  AiWriteTier base,
  AiTierFacts facts,
  Map<String, Object?> arguments,
) {
  var tier = base;
  void raise(AiWriteTier next) {
    if (next.index > tier.index) tier = next;
  }

  if (operationId == 'createTag') raise(AiWriteTier.t4);
  if (operationId == 'createPipeline' ||
      operationId == 'playPipelineSchedule') {
    raise(AiWriteTier.t4);
  }
  if (_confirmOnly(operationId, arguments)) raise(AiWriteTier.t4);
  if (facts.protectedOrDefaultBranch &&
      _protectedBranchOperations.contains(operationId)) {
    raise(AiWriteTier.t4);
  }
  if (facts.removeSourceBranch && operationId == 'mergeRequest') {
    raise(AiWriteTier.t4);
  }
  if (facts.confidentialLowered ||
      facts.visibilityRaised ||
      facts.newSnippetNotPrivate ||
      facts.touchesCiConfig) {
    raise(AiWriteTier.hardLine);
  }
  if (facts.pipelineVariables && operationId == 'createPipeline') {
    raise(AiWriteTier.hardLine);
  }
  if (facts.scheduleParamsUnsafe && operationId == 'playPipelineSchedule') {
    raise(AiWriteTier.hardLine);
  }
  // facts.triggersPipeline and facts.squash are intentionally not raises.
  return tier;
}

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

bool _needsName(AiWriteTier tier, bool confirmOnly) {
  if (tier == AiWriteTier.hardLine) return true;
  if (tier == AiWriteTier.t4 && !confirmOnly) return true;
  return false;
}

bool _confirmOnly(String operationId, Map<String, Object?> arguments) {
  final Object? action = arguments['action'];
  if (action is! String) return false;
  if (operationId == 'pipelineAction' && action == 'retry') return true;
  if (operationId == 'jobAction' && (action == 'retry' || action == 'play')) {
    return true;
  }
  return false;
}

bool _isCancel(String operationId, Map<String, Object?> arguments) {
  final Object? action = arguments['action'];
  return action == 'cancel' &&
      (operationId == 'pipelineAction' || operationId == 'jobAction');
}

String? _cleanName(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}

List<AiFixedConfirmReason> _freeze(Set<AiFixedConfirmReason> reasons) {
  final List<AiFixedConfirmReason> list = reasons.toList()
    ..sort(
      (AiFixedConfirmReason a, AiFixedConfirmReason b) =>
          a.index.compareTo(b.index),
    );
  return List<AiFixedConfirmReason>.unmodifiable(list);
}
