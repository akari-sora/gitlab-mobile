import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../../features/ai/ai_attachment_session.dart';
import '../../../features/ai/ai_write_journal.dart';
import '../ai_transcript.dart';
import '../app_text.dart';
import '../wire/wire_format.dart';
import '../write_text.dart' as text;
import 'gitlab_write_port.dart' as port;
import 'target_binding.dart';
import 'tool_catalogue.dart';
import 'write_ledger.dart';
import 'write_tier.dart';

export 'write_tier.dart' show AiGateDecision;

/// A process-local approval. Neither its text nor its payload is journaled.
final class AiWriteProposal {
  AiWriteProposal({
    required this.executionId,
    required this.operationId,
    required this.tier,
    required this.payloadDigest,
    required this.previewText,
    required this.userUtterance,
    required this.modelReason,
    required this.expiresAt,
    required this.proposalEpoch,
    required this.writePolicyRevision,
    required this.consentHash,
    required this.scopeRevision,
    required this.releaseName,
    this.fields = const <String, String>{},
  });

  final String executionId;
  final String operationId;
  AiTierDecision tier;
  String payloadDigest;
  String previewText;
  final String userUtterance;
  final String modelReason;
  final DateTime expiresAt;
  final int proposalEpoch;
  final int writePolicyRevision;
  final String consentHash;
  final int scopeRevision;
  final String releaseName;

  /// The write's arguments for the approval card, each value redacted with
  /// the live secrets. The model's `reason` is [modelReason] instead.
  Map<String, String> fields;
  String? editedText;
  bool get valid => _valid;
  bool _valid = true;
  void invalidate() => _valid = false;
}

/// App-owned, single-line projection of a write. It contains no replay payload.
final class AiWriteOutcome {
  const AiWriteOutcome({
    required this.state,
    required this.reasonCode,
    this.mutationCount = 0,
    this.noChange = false,
    this.readbackConfirmed = false,
    this.executionId,
    this.operationId,
    this.target,
    this.resultSummary,
  });

  final AiJournalState state;
  final String reasonCode;
  final int mutationCount;
  final bool noChange;
  final bool readbackConfirmed;
  final String? executionId;
  final String? operationId;
  final String? target;
  final String? resultSummary;
  bool get successful => state == AiJournalState.succeeded || noChange;
  String get summary => _singleLine(
    'write ${operationId ?? "operation"}'
    '${target == null ? "" : " on $target"}: '
    '${noChange ? "noChange" : state.name}; $reasonCode'
    '${state == AiJournalState.writeUncertain || state == AiJournalState.dispatching ? "; doNotRetry" : ""}'
    '${resultSummary == null || resultSummary!.isEmpty ? "" : "; $resultSummary"}',
  );

  AiToolResult toToolResult(AiToolCall call) => AiToolResult.fromData(
    callId: call.id,
    name: call.name,
    data: AiAppText.plain(summary),
    isError: !successful,
    notExecuted: state == AiJournalState.notExecuted && !noChange,
  );
}

abstract interface class AiWriteCoordinator {
  bool handles(String name);
  void beginRun(String userUtterance);
  void beginTurn();
  Future<AiWriteOutcome> execute(
    AiToolCall call, {
    void Function(bool)? onAwaitingApproval,
  });
  Future<AiWriteProposal?> propose(AiToolCall call);
  Future<AiWriteOutcome> approve(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  });
  Future<void> reject(AiWriteProposal proposal);
  Future<void> onAppBackground();
  void stop([String reason = 'stopped']);
  void checkNow();
}

/// Optional snapshot surface for interruption pairing; it never starts work.
abstract interface class AiWriteStateSource {
  AiWriteOutcome? recordedOutcomeFor(String callId);
}

/// Account-switch/removal owners can await these original journal-settling
/// futures rather than reviving an interrupted runner or a prior approval.
abstract interface class AiWriteSettlementSource {
  List<Future<AiWriteOutcome>> get inFlightWrites;
}

/// All synchronous acceptance predicates are read together, again after flush.
/// The owner must bind [alive] to account generation AND API object identity.
final class AiWritePolicySnapshot {
  const AiWritePolicySnapshot({
    required this.scope,
    required this.level,
    required this.ceiling,
    required this.consentHash,
    required this.writePolicyRevision,
    this.scopeRevision = 0,
    this.sessionGeneration = 0,
    this.toolsEnabled = true,
    this.consentValid = true,
    this.alive = true,
    this.appInForeground = true,
    this.clientMayStart = true,
    this.aiAttribution = false,
  });

  final AiWriteScope scope;
  final AiAutonomyLevel level;
  final AiAutonomyLevel ceiling;
  final String consentHash;
  final int writePolicyRevision;
  final int scopeRevision;
  final int sessionGeneration;
  final bool toolsEnabled;
  final bool consentValid;
  final bool alive;
  final bool appInForeground;
  final bool clientMayStart;
  final bool aiAttribution;

  bool get enabled =>
      alive &&
      toolsEnabled &&
      consentValid &&
      scope.allowsWrites &&
      level != AiAutonomyLevel.readOnly &&
      ceiling != AiAutonomyLevel.readOnly &&
      level.index <= ceiling.index;
}

/// Trusted fresh metadata, never taken from model arguments. The callback
/// consumes at most two logical GETs (four with OAuth replay) per invocation.
/// MR6b-2 can fill the reserved head/commit fields without changing the journal.
final class AiWriteFreshness {
  const AiWriteFreshness({
    this.updatedAt,
    this.headSha,
    this.lastCommitId,
    this.mergeCheckSummary,
    this.facts = const AiTierFacts(),
    this.noChange = false,
    this.visibilityUnreadable = true,
    this.polluted = false,
    this.currentFields = const {},
    this.provenance = const {},
  });

  final String? updatedAt;
  final String? headSha;
  final String? lastCommitId;
  final String? mergeCheckSummary;
  final AiTierFacts facts;
  final bool noChange;
  final bool visibilityUnreadable;
  final bool polluted;
  final Map<String, String> currentFields;
  final Map<String, text.AiFieldProvenance> provenance;
}

typedef AiWriteFreshnessReader =
    Future<AiWriteFreshness> Function(port.AiWriteRequest request);

/// REST write orchestration. Waiting approvals stay in memory. The only disk
/// writes are to the existing journal, after confirmation and before dispatch.
final class PolicyAiWriteCoordinator
    implements AiWriteCoordinator, AiWriteStateSource, AiWriteSettlementSource {
  PolicyAiWriteCoordinator({
    required this.snapshot,
    required this.createPort,
    required this.journal,
    required this.conversationId,
    required this.budget,
    required this.readFreshness,
    required this.placeholders,
    required this.knownSecrets,
    required this.safeDisplay,
    this.ledger = productionAiLedger,
    this.attachments,
    this.attachmentSubstitution,
    this.onChanged,
    this.onOutcome,
    this.interfaceLanguage = 'en',
    this.deviceLanguages = const ['en'],
    this.currentInterfaceLanguage,
    this.currentDeviceLanguages,
    this.persistConversation = true,
    DateTime Function()? now,
    int Function(String)? httpCost,
  }) : _now = now ?? DateTime.now,
       _httpCost = httpCost ?? _requestAllowance;

  final AiWritePolicySnapshot Function() snapshot;
  final port.AiGitLabWritePort Function() createPort;
  final AiWriteJournal journal;
  final String conversationId;
  final AiToolBudget Function() budget;
  final AiWriteFreshnessReader readFreshness;
  final text.UploadPlaceholderTable placeholders;
  final Set<String> Function() knownSecrets;
  final String Function(String) safeDisplay;
  final AiCapabilityLedger ledger;
  final AiAttachmentSession? attachments;
  final text.AttachmentSubstitution? Function(int projectId)?
  attachmentSubstitution;
  final void Function()? onChanged;
  final void Function(AiToolCall call, AiWriteOutcome outcome)? onOutcome;
  final String interfaceLanguage;
  final List<String> deviceLanguages;
  final String Function()? currentInterfaceLanguage;
  final List<String> Function()? currentDeviceLanguages;
  final bool persistConversation;
  final DateTime Function() _now;
  final int Function(String) _httpCost;
  final Map<String, _PendingWrite> _pending = {};
  final Map<String, AiWriteOutcome> _results = {};
  port.AiGitLabWritePort? _port;
  String _userUtterance = '';
  String _runId = _nonce();
  String? _stopped;
  bool _previousIncomplete = false;
  Timer? _approvalTimer;
  static final List<_WriteLease> _leases = [];

  List<AiWriteProposal> get proposals => List.unmodifiable([
    for (final pending in _pending.values)
      if (pending.proposal.valid && !pending.done.isCompleted) pending.proposal,
  ]);

  AiWriteOutcome? outcomeFor(String callId) => _results[callId];

  @override
  List<Future<AiWriteOutcome>> get inFlightWrites => List.unmodifiable([
    for (final pending in _pending.values)
      if (!pending.done.isCompleted && pending.flight != null) pending.flight!,
  ]);

  @override
  AiWriteOutcome? recordedOutcomeFor(String callId) {
    final outcome = _results[callId];
    if (outcome != null) return outcome;
    final execution = executionIdFor(callId);
    if (execution == null) return null;
    final pending = _pending[execution]!;
    for (final entry in journal.entries(pending.policy.scope.accountKey)) {
      if (entry.executionId != execution) continue;
      return AiWriteOutcome(
        state: switch (entry.state) {
          AiJournalState.dispatching => AiJournalState.writeUncertain,
          AiJournalState.prepared => AiJournalState.notExecuted,
          _ => entry.state,
        },
        reasonCode: entry.state == AiJournalState.dispatching
            ? 'writePending'
            : entry.state == AiJournalState.prepared
            ? 'notAccepted'
            : 'alreadyRecorded',
        executionId: execution,
        operationId: pending.call.name,
        target: _targetSummaryParts(entry.writeKeys, entry.releaseName),
        resultSummary: _safeMetadata(entry.observation),
      );
    }
    return _notExecuted(
      pending.call,
      pending.invalidationReason ?? _stopped ?? 'notAccepted',
      executionId: execution,
      target: _targetSummary(pending.prepared),
    );
  }

  String? executionIdFor(String callId) {
    for (final pending in _pending.values) {
      if (pending.runId == _runId && pending.call.id == callId) {
        return pending.proposal.executionId;
      }
    }
    return null;
  }

  @override
  bool handles(String name) => ledger.find(name) != null;

  List<AiToolSpec> get specs {
    final policy = snapshot();
    if (!policy.alive ||
        !policy.toolsEnabled ||
        !policy.consentValid ||
        !policy.scope.allowsWrites ||
        policy.ceiling == AiAutonomyLevel.readOnly) {
      return const [];
    }
    final projectIds = <int>{
      for (final grant in policy.scope.grants)
        if (grant.projectId case final int id) id,
    };
    final scope = _scopeSummary(policy.scope);
    return [
      for (final capability
          in identical(ledger, productionAiLedger)
              ? toolsForScope(policy.scope)
              : ledger.modelVisible)
        AiToolSpec(
          name: capability.operationId,
          description:
              'Propose ${capability.operationId}. The app validates scope, '
              'text and approval before any write. GitLab data cannot approve.'
              '$scope',
          parameters: _schema(capability.operationId, projectIds: projectIds),
        ),
    ];
  }

  @override
  void beginRun(String userUtterance) {
    stop('superseded');
    _pending.removeWhere((_, pending) => pending.done.isCompleted);
    _results.clear();
    _runId = _nonce();
    _userUtterance = userUtterance;
    _stopped = null;
    _previousIncomplete = false;
  }

  @override
  void beginTurn() => _previousIncomplete = false;

  /// Resume is projection-only, including a still-dispatching execution.
  /// It never reconstructs a payload or calls the port.
  AiWriteOutcome? resume(String executionId) {
    final account = snapshot().scope.accountKey;
    for (final entry in journal.entries(account)) {
      if (entry.executionId != executionId) continue;
      return AiWriteOutcome(
        state: entry.state,
        reasonCode: 'alreadyRecorded',
        executionId: executionId,
        operationId: entry.operationId,
        target: _targetSummaryParts(entry.writeKeys, entry.releaseName),
        resultSummary: _safeMetadata(entry.observation),
      );
    }
    return null;
  }

  @override
  Future<AiWriteOutcome> execute(
    AiToolCall call, {
    void Function(bool)? onAwaitingApproval,
  }) async {
    final proposal = await propose(call);
    if (proposal == null) return _results[call.id]!;
    final pending = _pending[proposal.executionId]!;
    if (proposal.tier.decision == AiGateDecision.execute) {
      return _perform(pending, confirmed: false);
    }
    onAwaitingApproval?.call(true);
    try {
      return await pending.done.future;
    } finally {
      onAwaitingApproval?.call(false);
    }
  }

  @override
  Future<AiWriteProposal?> propose(AiToolCall call) async {
    final existing = _results[call.id];
    if (existing != null) {
      if (!existing.successful) _previousIncomplete = true;
      return null;
    }
    for (final pending in _pending.values) {
      if (pending.runId == _runId &&
          pending.call.id == call.id &&
          !pending.done.isCompleted) {
        return pending.proposal;
      }
    }
    final policy = snapshot();
    final runId = _runId;
    final proposalEpoch = journal.proposalEpoch(policy.scope.accountKey);
    final initialFailure = _previousIncomplete
        ? 'previousWriteIncomplete'
        : _policyFailure(policy);
    if (initialFailure != null) {
      _record(call, _notExecuted(call, initialFailure));
      return null;
    }
    final capability = ledger.find(call.name);
    if (capability == null || !capability.modelVisible) {
      _record(call, _notExecuted(call, 'unknownOperation'));
      return null;
    }
    AiBudgetHold? hold;
    var reserved = false;
    final allowance = _httpCost(call.name);
    final toolBudget = budget();
    try {
      final arguments = _arguments(call);
      final target = _target(capability, arguments, policy.scope);
      // Scope and autonomy are checked before constructing a write port.
      final initialTier = _tier(
        capability,
        arguments,
        target,
        policy,
        const AiWriteFreshness(),
      );
      if (initialTier.decision == AiGateDecision.deny) {
        throw const _WriteBlocked('policyDenied');
      }
      if (allowance < 1 ||
          toolBudget.reserve(requests: allowance, search: false) != null) {
        throw const _WriteBlocked('httpBudgetExceeded');
      }
      reserved = true;
      hold = await journal.tryReserve(
        AiBudgetRequest(
          accountKey: policy.scope.accountKey,
          conversationId: conversationId,
          runId: runId,
          tier4: initialTier.tier.index >= AiWriteTier.t4.index,
          persistConversation: persistConversation,
        ),
      );
      if (hold == null) throw const _WriteBlocked('writeBudgetExceeded');
      _requirePolicy(policy, runId: runId);
      final id = _nonce();
      final attachment = _attachment(call.name, arguments);
      var request = _request(call.name, id, policy, arguments, attachment);
      final rawRequest = request;
      // The allowance remains charged once the first pre-read can start.
      reserved = false;
      final fresh = await readFreshness(request);
      _requirePolicy(policy, runId: runId);
      final preparedText = _prepareText(request, policy, fresh);
      request = preparedText.request;
      final prepared = await (_port ??= createPort()).prepare(request);
      _requirePolicy(policy, runId: runId);
      final extra = <AiFixedConfirmReason>[...preparedText.reasons];
      final keys = {...prepared.writeKeys, ...prepared.dependencyKeys};
      if (journal.proposalEpoch(policy.scope.accountKey) != proposalEpoch) {
        throw const _WriteBlocked('proposalInvalidated');
      }
      if (journal.isolated(policy.scope.accountKey, keys)) {
        throw const _WriteBlocked('isolated');
      }
      if (journal.requiresConfirmation(policy.scope.accountKey, keys)) {
        extra.add(AiFixedConfirmReason.confirmMarkAfterManualRelease);
      }
      if (journal
          .entries(policy.scope.accountKey)
          .any(
            (entry) =>
                entry.operationId == call.name &&
                entry.state != AiJournalState.notExecuted &&
                entry.state != AiJournalState.prepared &&
                entry.writeKeys.any((key) => prepared.writeKeys.contains(key)),
          )) {
        extra.add(AiFixedConfirmReason.duplicateOfSettledWrite);
      }
      final tier = _tier(
        capability,
        request.arguments,
        target,
        policy,
        fresh,
        extra: extra,
        releaseName: prepared.releaseName,
      );
      if (!tier.canPropose) throw const _WriteBlocked('policyDenied');
      // A dynamic tier must have the same budget class as the reservation.
      if ((tier.tier.index >= AiWriteTier.t4.index) != hold.request.tier4) {
        await journal.refund(hold);
        hold = await journal.tryReserve(
          AiBudgetRequest(
            accountKey: policy.scope.accountKey,
            conversationId: conversationId,
            runId: runId,
            tier4: tier.tier.index >= AiWriteTier.t4.index,
            persistConversation: persistConversation,
          ),
        );
        if (hold == null) throw const _WriteBlocked('writeBudgetExceeded');
        _requirePolicy(policy, runId: runId);
      }
      final proposal = AiWriteProposal(
        executionId: id,
        operationId: call.name,
        tier: tier,
        payloadDigest: _digest(request),
        previewText: safeDisplay(_preview(request, prepared.releaseName)),
        userUtterance: safeDisplay(_userUtterance),
        modelReason: safeDisplay(arguments['reason'] as String? ?? ''),
        expiresAt: _now().add(const Duration(minutes: 30)),
        proposalEpoch: proposalEpoch,
        writePolicyRevision: policy.writePolicyRevision,
        consentHash: policy.consentHash,
        scopeRevision: policy.scopeRevision,
        releaseName: safeDisplay(prepared.releaseName),
        fields: _fields(request, safeDisplay),
      );
      _pending[id] = _PendingWrite(
        call,
        runId,
        proposal,
        policy,
        rawRequest,
        prepared,
        fresh,
        hold,
        target,
        extra,
        attachment?.id,
      );
      if (attachment != null) attachments?.noteProposed(attachment.id);
      _approvalTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        checkNow();
      });
      _changed();
      return proposal;
    } on Object catch (error) {
      if (reserved) toolBudget.refundRequests(allowance);
      if (hold != null) await journal.refund(hold);
      _record(call, _notExecuted(call, _reason(error)), runId: runId);
      return null;
    }
  }

  @override
  Future<AiWriteOutcome> approve(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  }) async {
    final pending = _pending[proposal.executionId];
    if (pending == null || !identical(pending.proposal, proposal)) {
      return const AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: 'invalidProposal',
      );
    }
    if (pending.done.isCompleted) return pending.done.future;
    if (pending.flight != null) return pending.flight!;
    if (editedText != null && editedText != proposal.editedText) {
      proposal.editedText = editedText;
      try {
        _requirePending(pending);
        final request = _edit(pending.request, editedText);
        final processed = _prepareText(request, snapshot(), pending.fresh);
        final tier = _tier(
          ledger.find(proposal.operationId)!,
          processed.request.arguments,
          pending.target,
          snapshot(),
          pending.fresh,
          extra: [...pending.reasons, ...processed.reasons],
          releaseName: pending.prepared.releaseName,
        );
        if (!tier.canPropose) throw const _WriteBlocked('policyDenied');
        pending.request = request;
        pending.editBlocked = null;
        proposal.tier = tier;
        proposal.previewText = safeDisplay(
          _preview(processed.request, pending.prepared.releaseName),
        );
        proposal.fields = _fields(processed.request, safeDisplay);
        proposal.payloadDigest = _digest(processed.request);
        _changed();
        return _notExecuted(pending.call, 'approvalRequired');
      } on Object catch (error) {
        pending.editBlocked = _reason(error);
        _changed();
        return _notExecuted(pending.call, pending.editBlocked!);
      }
    }
    if (pending.editBlocked != null) {
      return _notExecuted(pending.call, pending.editBlocked!);
    }
    if (proposal.tier.requiresTypedName &&
        typedName != proposal.tier.typedName) {
      return _notExecuted(pending.call, 'typedNameMismatch');
    }
    return _perform(pending, confirmed: true);
  }

  Future<AiWriteOutcome> _perform(
    _PendingWrite pending, {
    required bool confirmed,
  }) {
    if (pending.done.isCompleted) return pending.done.future;
    return pending.flight ??= _dispatch(pending, confirmed: confirmed);
  }

  Future<AiWriteOutcome> _dispatch(
    _PendingWrite pending, {
    required bool confirmed,
  }) async {
    final proposal = pending.proposal;
    _WriteLease? lease;
    var preparedOnDisk = false;
    var dispatching = false;
    var accepted = false;
    try {
      _requirePending(pending);
      // Approval becomes durable before the conflict lock/final reads. A
      // failure after this point always has a prepared -> notExecuted record.
      await journal.prepare(
        draft: AiJournalDraft(
          executionId: proposal.executionId,
          accountKey: pending.policy.scope.accountKey,
          conversationId: conversationId,
          runId: pending.runId,
          operationId: proposal.operationId,
          writeKeys: pending.prepared.writeKeys,
          dependencyKeys: pending.prepared.dependencyKeys,
          payloadSha256: proposal.payloadDigest,
          releaseName: proposal.releaseName,
          instance: pending.policy.scope.resolvedInstance?.key ?? '',
          sessionGeneration: pending.policy.sessionGeneration,
          normalizedTarget: jsonEncode([
            for (final key in pending.prepared.writeKeys) key.parts,
          ]),
          lastCommitId: _safeMetadata(pending.fresh.lastCommitId),
          headSha: _safeMetadata(pending.fresh.headSha),
          updatedAt: _safeMetadata(pending.fresh.updatedAt),
          mergeCheckSummary: _safeMetadata(pending.fresh.mergeCheckSummary),
          policyRevision: proposal.writePolicyRevision,
          summary: _targetSummary(pending.prepared),
          tier4: pending.hold.request.tier4,
          persistConversation: persistConversation,
          budgetHold: pending.hold,
          confirmed: confirmed,
          bypass: snapshot().level == AiAutonomyLevel.bypass,
        ),
      );
      preparedOnDisk = true;
      final attachmentId = pending.attachmentId;
      if (attachmentId != null) {
        attachments?.notePrepared(
          attachmentId,
          projectId: pending.request.arguments['projectId']! as int,
        );
      }
      lease = await _acquire({
        ...pending.prepared.writeKeys,
        ...pending.prepared.dependencyKeys,
      });
      _requirePending(pending);
      var request = pending.request;
      final fresh = await readFreshness(request);
      _requirePending(pending);
      final processed = _prepareText(request, snapshot(), fresh);
      request = processed.request;
      if (_digest(request) != proposal.payloadDigest) {
        throw const _WriteBlocked('previewChanged');
      }
      if (pending.fresh.updatedAt != fresh.updatedAt ||
          pending.fresh.headSha != fresh.headSha ||
          pending.fresh.lastCommitId != fresh.lastCommitId) {
        throw const _WriteBlocked('targetChanged');
      }
      final capability = ledger.find(request.operationId)!;
      final tier = _tier(
        capability,
        request.arguments,
        pending.target,
        snapshot(),
        fresh,
        extra: [...pending.reasons, ...processed.reasons],
        releaseName: pending.prepared.releaseName,
      );
      if (!tier.canPropose) throw const _WriteBlocked('policyDenied');
      if (tier.tier != proposal.tier.tier ||
          tier.requiresTypedName != proposal.tier.requiresTypedName ||
          tier.typedName != proposal.tier.typedName ||
          !proposal.tier.reasons.toSet().containsAll(tier.reasons)) {
        throw const _WriteBlocked('approvalRequired');
      }
      if (!confirmed && tier.decision != AiGateDecision.execute) {
        throw const _WriteBlocked('approvalRequired');
      }
      if (fresh.noChange) {
        await journal.finish(
          executionId: proposal.executionId,
          terminal: AiJournalState.notExecuted,
        );
        return _complete(
          pending,
          AiWriteOutcome(
            state: AiJournalState.succeeded,
            reasonCode: 'noChange',
            noChange: true,
            executionId: proposal.executionId,
            operationId: proposal.operationId,
            target: _targetSummary(pending.prepared),
          ),
        );
      }
      final prepared = await _port!.prepare(request);
      _requirePending(pending);
      if (!_sameKeys(prepared.writeKeys, pending.prepared.writeKeys) ||
          !_sameKeys(
            prepared.dependencyKeys,
            pending.prepared.dependencyKeys,
          ) ||
          prepared.releaseName != pending.prepared.releaseName) {
        throw const _WriteBlocked('targetChanged');
      }
      _requirePending(pending);
      await journal.markDispatching(executionId: proposal.executionId);
      dispatching = true;
      // There is no await between this final check and the port's mutation.
      final outcome = await _port!.commit(
        prepared,
        mayStart: () {
          if (_pendingFailure(pending) != null) return false;
          final currentTier = _tier(
            capability,
            request.arguments,
            pending.target,
            snapshot(),
            fresh,
            extra: [...pending.reasons, ...processed.reasons],
            releaseName: prepared.releaseName,
          );
          if (!currentTier.canPropose ||
              (!confirmed && currentTier.decision != AiGateDecision.execute) ||
              currentTier.tier != proposal.tier.tier ||
              currentTier.requiresTypedName !=
                  proposal.tier.requiresTypedName) {
            pending.invalidationReason = 'approvalRequired';
            return false;
          }
          accepted = true;
          if (attachmentId != null) attachments?.beginUpload(attachmentId);
          return true;
        },
      );
      if (outcome is port.AiWriteNotSent) {
        await journal.revertDispatchingToNotExecuted(
          executionId: proposal.executionId,
        );
        return _complete(
          pending,
          _notExecuted(
            pending.call,
            _pendingFailure(pending) ?? 'notAccepted',
            executionId: proposal.executionId,
            target: _targetSummary(pending.prepared),
          ),
        );
      }
      final settled = outcome as port.AiWriteSettled;
      await journal.finish(
        executionId: proposal.executionId,
        terminal: settled.state,
      );
      final readbackConfirmed =
          settled.state == AiJournalState.succeeded &&
          _readbackOperations.contains(proposal.operationId);
      if (readbackConfirmed) {
        proposal.editedText = null;
      }
      return _complete(
        pending,
        AiWriteOutcome(
          state: settled.state,
          reasonCode: settled.resultCode,
          mutationCount: settled.mutationCount,
          readbackConfirmed: readbackConfirmed,
          executionId: proposal.executionId,
          operationId: proposal.operationId,
          target: _targetSummary(pending.prepared),
          resultSummary: _resultSummary(settled.projection),
        ),
      );
    } on Object catch (error) {
      var state = accepted
          ? AiJournalState.writeUncertain
          : AiJournalState.notExecuted;
      try {
        if (dispatching && !accepted) {
          await journal.revertDispatchingToNotExecuted(
            executionId: proposal.executionId,
          );
        } else if (preparedOnDisk) {
          await journal.finish(
            executionId: proposal.executionId,
            terminal: state,
          );
        } else {
          await journal.refund(pending.hold);
        }
      } on Object {
        // A failed durable rollback keeps dispatching/uncertain isolation.
        if (dispatching || accepted) state = AiJournalState.writeUncertain;
      }
      return _complete(
        pending,
        AiWriteOutcome(
          state: state,
          reasonCode: accepted
              ? 'writeUncertain'
              : _pendingFailure(pending) ?? _reason(error),
          mutationCount: accepted ? 1 : 0,
          executionId: proposal.executionId,
          operationId: proposal.operationId,
          target: _targetSummary(pending.prepared),
        ),
      );
    } finally {
      if (pending.attachmentId != null) {
        attachments?.finishUpload(pending.attachmentId!);
      }
      lease?.release();
    }
  }

  @override
  Future<void> reject(AiWriteProposal proposal) async {
    final pending = _pending[proposal.executionId];
    if (pending == null ||
        !identical(pending.proposal, proposal) ||
        pending.flight != null ||
        pending.done.isCompleted) {
      return;
    }
    proposal.invalidate();
    await journal.refund(pending.hold);
    _complete(
      pending,
      _notExecuted(
        pending.call,
        'rejected',
        executionId: proposal.executionId,
        target: _targetSummary(pending.prepared),
      ),
    );
  }

  @override
  Future<void> onAppBackground() async => stop('backgrounded');

  @override
  void stop([String reason = 'stopped']) {
    _stopped = reason;
    checkNow();
  }

  @override
  void checkNow() {
    for (final pending in _pending.values.toList()) {
      if (pending.done.isCompleted) continue;
      final failure = _pendingFailure(pending);
      if (failure == null) continue;
      pending.invalidationReason = failure;
      pending.proposal.invalidate();
      // In-flight writes own their real future and settle the journal even
      // when the runner has already returned its frozen interruption result.
      if (pending.flight != null) continue;
      unawaited(journal.refund(pending.hold));
      _complete(
        pending,
        _notExecuted(
          pending.call,
          failure,
          executionId: pending.proposal.executionId,
          target: _targetSummary(pending.prepared),
        ),
      );
    }
    if (proposals.isEmpty) {
      _approvalTimer?.cancel();
      _approvalTimer = null;
    }
  }

  String? _policyFailure(AiWritePolicySnapshot policy) {
    if (_stopped != null) return _stopped;
    if (!policy.alive) return 'accountChanged';
    if (!policy.enabled) return 'policyDenied';
    if (!policy.appInForeground) return 'backgrounded';
    if (!policy.clientMayStart) return 'clientUnavailable';
    if (journal.removalHeld(policy.scope.accountKey) ||
        journal.tombstoneFlag(policy.scope.accountKey)) {
      return 'accountBlocked';
    }
    return null;
  }

  void _requirePolicy(AiWritePolicySnapshot expected, {String? runId}) {
    if (runId != null && runId != _runId) {
      throw const _WriteBlocked('superseded');
    }
    final current = snapshot();
    final failure = _policyFailure(current);
    if (failure != null) throw _WriteBlocked(failure);
    if (current.scope.accountKey != expected.scope.accountKey ||
        current.sessionGeneration != expected.sessionGeneration ||
        current.writePolicyRevision != expected.writePolicyRevision ||
        current.scopeRevision != expected.scopeRevision ||
        current.consentHash != expected.consentHash ||
        _scopeDigest(current.scope) != _scopeDigest(expected.scope)) {
      throw const _WriteBlocked('settingsChanged');
    }
  }

  String? _pendingFailure(_PendingWrite pending) {
    try {
      if (pending.invalidationReason != null) return pending.invalidationReason;
      _requirePolicy(pending.policy, runId: pending.runId);
      if (!pending.proposal.valid) return 'invalidProposal';
      if (!_now().isBefore(pending.proposal.expiresAt)) {
        return 'approvalExpired';
      }
      if (journal.proposalEpoch(pending.policy.scope.accountKey) !=
          pending.proposal.proposalEpoch) {
        return 'proposalInvalidated';
      }
      final id = pending.attachmentId;
      if (id != null && attachments?.resolveModelId(id).accepted != true) {
        return 'attachmentExpired';
      }
      return null;
    } on Object catch (error) {
      return _reason(error);
    }
  }

  void _requirePending(_PendingWrite pending) {
    final failure = _pendingFailure(pending);
    if (failure != null) throw _WriteBlocked(failure);
  }

  AiWriteOutcome _complete(_PendingWrite pending, AiWriteOutcome outcome) {
    if (pending.done.isCompleted) return pending.outcome!;
    pending.outcome = outcome;
    pending.proposal.invalidate();
    _record(pending.call, outcome, runId: pending.runId);
    pending.done.complete(outcome);
    if (proposals.isEmpty) {
      _approvalTimer?.cancel();
      _approvalTimer = null;
    }
    _changed();
    return outcome;
  }

  void _record(AiToolCall call, AiWriteOutcome outcome, {String? runId}) {
    if (runId == null || runId == _runId) {
      _results[call.id] = outcome;
      if (!outcome.successful) _previousIncomplete = true;
    }
    try {
      onOutcome?.call(call, outcome);
    } on Object {
      // Display observers cannot change a journal terminal state.
    }
  }

  void _changed() {
    try {
      onChanged?.call();
    } on Object {
      // Observers do not own the approval or dispatch state machine.
    }
  }

  String? _safeMetadata(String? value) =>
      value == null ? null : safeDisplay(value);

  String _targetSummary(port.AiWritePrepared prepared) =>
      _targetSummaryParts(prepared.writeKeys, prepared.releaseName);

  String _targetSummaryParts(Set<AiConflictKey> keys, String releaseName) =>
      _singleLine(
        safeDisplay(
          '${keys.map((key) => key.parts.skip(1).join("/")).join(", ")} '
          '($releaseName)',
        ),
      );

  String _resultSummary(Map<String, Object?> projection) => [
    for (final key in const ['id', 'iid', 'state', 'resolved', 'position'])
      if (projection[key] case final value?
          when value is int ||
              value is bool ||
              (key == 'state' &&
                  const {
                    'opened',
                    'closed',
                    'active',
                    'merged',
                  }.contains(value)))
        '$key=$value',
  ].join(', ');

  AiTierDecision _tier(
    AiCapability capability,
    Map<String, Object?> arguments,
    AiTargetRef target,
    AiWritePolicySnapshot policy,
    AiWriteFreshness fresh, {
    List<AiFixedConfirmReason> extra = const [],
    String? releaseName,
  }) {
    final facts = fresh.facts;
    return decideTier(
      AiTierInput(
        level: policy.level,
        capability: capability,
        scope: policy.scope,
        target: target,
        arguments: arguments,
        typedName: releaseName,
        binding: bindTargets(
          userMessage: _userUtterance,
          restoredFromHistory: false,
          scope: policy.scope,
          targets: [target],
          interfaceLanguage:
              currentInterfaceLanguage?.call() ?? interfaceLanguage,
          deviceLanguages: currentDeviceLanguages?.call() ?? deviceLanguages,
          operationId: capability.operationId,
          arguments: arguments,
        ),
        facts: AiTierFacts(
          protectedOrDefaultBranch: facts.protectedOrDefaultBranch,
          removeSourceBranch: facts.removeSourceBranch,
          confidentialLowered: facts.confidentialLowered,
          visibilityRaised: facts.visibilityRaised,
          newSnippetNotPrivate: facts.newSnippetNotPrivate,
          touchesCiConfig: facts.touchesCiConfig,
          pipelineVariables: facts.pipelineVariables,
          scheduleParamsUnsafe: facts.scheduleParamsUnsafe,
          squash: facts.squash,
          triggersPipeline: facts.triggersPipeline,
          reasons: [...facts.reasons, ...extra],
        ),
      ),
    );
  }

  AiStoredAttachment? _attachment(String operation, Map<String, Object?> args) {
    if (operation != 'upload_attachment') return null;
    final id = args['attachmentId'];
    if (id is! String) throw const _WriteBlocked('attachmentExpired');
    final verdict = attachments?.resolveModelId(id);
    if (verdict?.accepted != true) {
      throw _WriteBlocked(verdict?.reasonCode ?? 'attachmentExpired');
    }
    return verdict!.attachment;
  }

  port.AiWriteRequest _request(
    String operation,
    String id,
    AiWritePolicySnapshot policy,
    Map<String, Object?> arguments,
    AiStoredAttachment? attachment,
  ) => port.AiWriteRequest(
    operationId: operation,
    executionId: id,
    scope: policy.scope,
    arguments: {
      for (final entry in arguments.entries)
        if (entry.key != 'reason' && entry.key != 'attachmentId')
          entry.key: entry.value,
      if (attachment != null) ...{
        'filename': attachment.filename,
        'contentType': attachment.mediaType ?? 'application/octet-stream',
      },
    },
    uploadBytes: attachment?.bytes,
    sendTimeout: attachment == null
        ? null
        : port.GitLabAiWritePort.uploadSendTimeout(attachment.size),
  );

  ({port.AiWriteRequest request, List<AiFixedConfirmReason> reasons})
  _prepareText(
    port.AiWriteRequest request,
    AiWritePolicySnapshot policy,
    AiWriteFreshness fresh,
  ) {
    final reasons = <AiFixedConfirmReason>[];
    final arguments = Map<String, Object?>.from(request.arguments);
    final fields = arguments['fields'];
    final project = arguments['projectId'] as int?;
    String prepare(String value, String field) {
      final classA =
          field == 'body' ||
          (field == 'description' &&
              !request.operationId.contains('Label') &&
              !request.operationId.contains('Milestone'));
      final outcome = text.prepareWriteText(
        textClass: classA
            ? text.AiTextClass.quickActionMarkdown
            : text.AiTextClass.plainContent,
        modelText: value,
        field: fresh.provenance[field],
        placeholders: placeholders,
        knownSecrets: knownSecrets(),
        aiAttribution: policy.aiAttribution && classA,
        visibility: text.AiVisibilityContext(
          polluted: fresh.polluted,
          visibilityUnreadable: fresh.visibilityUnreadable,
          targetProjectPath: _projectPath(policy.scope, project),
          renderedMarkdown: classA || field == 'description',
        ),
        attachments: project == null
            ? null
            : attachmentSubstitution?.call(project),
        currentFieldValue: fresh.currentFields[field],
      );
      if (outcome.policyBlocked || outcome.finalText == null) {
        throw _WriteBlocked(outcome.blockedReasonCode);
      }
      reasons.addAll(
        outcome.confirmReasons.map(
          (reason) => switch (reason) {
            text.AiFixedConfirmReason.massMention =>
              AiFixedConfirmReason.massMention,
            text.AiFixedConfirmReason.externalMedia =>
              AiFixedConfirmReason.externalMediaInRenderedMarkdown,
            text.AiFixedConfirmReason.closingOrCrossProject =>
              AiFixedConfirmReason.foreignClosingOrCrossProject,
            text.AiFixedConfirmReason.hiddenContentRemoved =>
              AiFixedConfirmReason.wholeFieldDropsHiddenSpans,
          },
        ),
      );
      if (outcome.levelConfirmReasons.isNotEmpty) {
        reasons.add(AiFixedConfirmReason.confidentialOrVisibilityMix);
      }
      return outcome.finalText!;
    }

    for (final key in ['body', 'name', 'filename']) {
      if (arguments[key] case final String value) {
        arguments[key] = prepare(value, key);
      }
    }
    if (fields is Map<String, Object?>) {
      arguments['fields'] = {
        for (final entry in fields.entries)
          entry.key: entry.value is String
              ? prepare(entry.value! as String, entry.key)
              : entry.value,
      };
    }
    return (
      request: port.AiWriteRequest(
        operationId: request.operationId,
        executionId: request.executionId,
        scope: request.scope,
        arguments: arguments,
        uploadBytes: request.uploadBytes,
        sendTimeout: request.sendTimeout,
      ),
      reasons: reasons,
    );
  }
}

final class _PendingWrite {
  _PendingWrite(
    this.call,
    this.runId,
    this.proposal,
    this.policy,
    this.request,
    this.prepared,
    this.fresh,
    this.hold,
    this.target,
    this.reasons,
    this.attachmentId,
  );
  final AiToolCall call;
  final String runId;
  final AiWriteProposal proposal;
  final AiWritePolicySnapshot policy;
  port.AiWriteRequest request;
  final port.AiWritePrepared prepared;
  final AiWriteFreshness fresh;
  final AiBudgetHold hold;
  final AiTargetRef target;
  final List<AiFixedConfirmReason> reasons;
  final String? attachmentId;
  final Completer<AiWriteOutcome> done = Completer();
  AiWriteOutcome? outcome;
  String? editBlocked;
  String? invalidationReason;
  Future<AiWriteOutcome>? flight;
}

final class _WriteBlocked implements Exception {
  const _WriteBlocked(this.reason);
  final String reason;
}

final class _WriteLease {
  _WriteLease(this.keys);
  final Set<AiConflictKey> keys;
  final Completer<void> done = Completer();
  void release() {
    PolicyAiWriteCoordinator._leases.remove(this);
    if (!done.isCompleted) done.complete();
  }
}

Future<_WriteLease> _acquire(Set<AiConflictKey> keys) async {
  while (true) {
    final conflicting = PolicyAiWriteCoordinator._leases
        .where((lease) => keys.any((key) => lease.keys.any(key.intersects)))
        .toList();
    if (conflicting.isEmpty) {
      final lease = _WriteLease(keys);
      PolicyAiWriteCoordinator._leases.add(lease);
      return lease;
    }
    await Future.any(conflicting.map((lease) => lease.done.future));
  }
}

AiWriteOutcome _notExecuted(
  AiToolCall call,
  String reason, {
  String? executionId,
  String? target,
}) => AiWriteOutcome(
  state: AiJournalState.notExecuted,
  reasonCode: reason,
  executionId: executionId,
  operationId: call.name,
  target: target,
);

String _singleLine(String value) =>
    value.replaceAll(RegExp(r'[\r\n\u2028\u2029]'), ' ');

String _reason(Object error) => switch (error) {
  _WriteBlocked(:final reason) => reason,
  AiJournalException(:final reason) => reason,
  _ => 'preflightFailed',
};

String _nonce() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Object? _canonical(Object? value) => switch (value) {
  Map<String, Object?> values => {
    for (final key in values.keys.toList()..sort())
      key: _canonical(values[key]),
  },
  List<Object?> values => values.map(_canonical).toList(),
  _ => value,
};

String _digest(port.AiWriteRequest request) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonical({
            'operation': request.operationId,
            'arguments': request.arguments,
            if (request.uploadBytes != null)
              'attachmentSha256': sha256
                  .convert(request.uploadBytes!)
                  .toString(),
          }),
        ),
      ),
    )
    .toString();

String _scopeDigest(AiWriteScope scope) => jsonEncode([
  scope.accountKey,
  scope.resolvedInstance?.key,
  for (final grant in scope.grants)
    [
      grant.kind.name,
      grant.projectId,
      grant.projectPath,
      grant.iid,
      grant.groupFullPath,
      grant.groupId,
    ],
]);

bool _sameKeys(Set<AiConflictKey> first, Set<AiConflictKey> second) =>
    first.length == second.length && first.containsAll(second);

String? _projectPath(AiWriteScope scope, int? id) {
  for (final grant in scope.grants) {
    if (grant.projectId == id) return grant.projectPath;
  }
  return null;
}

AiTargetRef _target(
  AiCapability capability,
  Map<String, Object?> args,
  AiWriteScope scope,
) {
  final project = args['projectId'] as int?;
  final iid = args['iid'] as int?;
  final kind = switch (capability.scopeClass) {
    AiScopeClass.workItem => AiTargetKind.issue,
    AiScopeClass.mergeRequest => AiTargetKind.mergeRequest,
    AiScopeClass.resource =>
      args['resource'] == 'merge_requests'
          ? AiTargetKind.mergeRequest
          : AiTargetKind.issue,
    AiScopeClass.accountTodo => AiTargetKind.todo,
    AiScopeClass.groupWorkItem => AiTargetKind.groupWorkItem,
    AiScopeClass.project ||
    AiScopeClass.projectUpload => AiTargetKind.project,
  };
  final bound = scope.grants.any(
    (grant) =>
        (kind == AiTargetKind.project &&
            grant.kind == AiScopeKind.project &&
            grant.projectId == project) ||
        (kind == AiTargetKind.issue &&
            grant.kind == AiScopeKind.workItem &&
            grant.projectId == project &&
            grant.iid == iid) ||
        (kind == AiTargetKind.mergeRequest &&
            grant.kind == AiScopeKind.mergeRequest &&
            grant.projectId == project &&
            grant.iid == iid),
  );
  return AiTargetRef(
    kind: kind,
    projectId: project,
    iid: iid,
    projectPath: _projectPath(scope, project),
    origin: bound ? AiTargetOrigin.currentResource : AiTargetOrigin.proposed,
  );
}

port.AiWriteRequest _edit(port.AiWriteRequest request, String edited) {
  final args = Map<String, Object?>.from(request.arguments);
  if (args.containsKey('body')) {
    args['body'] = edited;
  } else if (args['fields'] case final Map<String, Object?> fields) {
    final writable = fields.keys
        .where((key) => key == 'description' || key == 'title' || key == 'name')
        .toList();
    if (writable.length != 1) throw const _WriteBlocked('ambiguousEditedField');
    args['fields'] = {...fields, writable.single: edited};
  } else {
    throw const _WriteBlocked('noEditableText');
  }
  return port.AiWriteRequest(
    operationId: request.operationId,
    executionId: request.executionId,
    scope: request.scope,
    arguments: args,
    uploadBytes: request.uploadBytes,
    sendTimeout: request.sendTimeout,
  );
}

// What the card shows: content, not the identifiers the target name already
// stands for. A nested `fields` map is spread.
const _hiddenFields = {
  'reason', 'projectId', 'resource', 'iid', 'noteId', 'discussionId',
  'todoId', 'awardId', 'labelId', 'milestoneId', 'boardId', 'listId',
  'commitId', 'position', 'fields', 'attachmentId',
};

Map<String, String> _fields(
  port.AiWriteRequest request,
  String Function(String) safeDisplay,
) {
  final nested = request.arguments['fields'];
  final shown = <String, String>{};
  void add(String key, Object? value) {
    if (_hiddenFields.contains(key) || value == null) return;
    shown[key] = safeDisplay(value is String ? value : jsonEncode(value));
  }

  for (final MapEntry(:key, :value) in request.arguments.entries) {
    add(key, value);
  }
  if (nested is Map) {
    for (final MapEntry(:key, :value) in nested.entries) {
      add('$key', value);
    }
  }
  return Map.unmodifiable(shown);
}

String _preview(port.AiWriteRequest request, String releaseName) =>
    '${request.operationId} $releaseName\n${jsonEncode(request.arguments)}';

// Includes both preflight passes, bounded freshness reads, one mutation and
// readback. Each logical GET reserves two requests for OAuth refresh replay.
int _requestAllowance(String operation) => switch (operation) {
  'setStar' => 17,
  'setSubscribed' ||
  'createNote' ||
  'updateIssue' ||
  'updateMergeRequest' ||
  'createIssue' ||
  'createMergeRequest' => 25,
  _ => 39,
};

// The existing port does not expose a readback flag. Keep this conservative
// list aligned with its explicit readback callbacks; accepted is distinct.
const _readbackOperations = {
  'createIssue',
  'updateIssue',
  'createMergeRequest',
  'updateMergeRequest',
  'createNote',
  'updateNote',
  'createDiscussionNote',
  'updateDiscussionNote',
  'setDiscussionResolved',
  'updateDraftNote',
  'updateLabel',
  'updateMilestone',
  'setMilestoneState',
  'moveBoardCard',
};

Map<String, Object?> _arguments(AiToolCall call) {
  final args = call.arguments;
  final allowed = _allowedArguments[call.name];
  if (args is! Map<String, Object?> ||
      (allowed != null && args.keys.any((key) => !allowed.contains(key))) ||
      (args['reason'] != null && args['reason'] is! String) ||
      (args['projectId'] != null &&
          (args['projectId'] is! int || (args['projectId']! as int) < 1)) ||
      (args['iid'] != null &&
          (args['iid'] is! int || (args['iid']! as int) < 1))) {
    throw const _WriteBlocked('invalidArguments');
  }
  return args;
}

/// The conversation's scope as the app knows it, so the model can name the
/// project id a write tool needs. Built from the user's own grants only.
String _scopeSummary(AiWriteScope scope) {
  final parts = <String>[];
  for (final grant in scope.grants) {
    final id = grant.projectId;
    if (id == null) continue;
    final what = switch (grant.kind) {
      AiScopeKind.workItem => 'issue #${grant.iid} in project $id',
      AiScopeKind.mergeRequest => 'merge request !${grant.iid} in project $id',
      _ => 'project $id',
    };
    final path = grant.projectPath;
    parts.add(path == null ? what : '$what ($path)');
  }
  return parts.isEmpty ? '' : ' In scope: ${parts.join('; ')}.';
}

Map<String, Object?> _schema(
  String operation, {
  Set<int> projectIds = const <int>{},
}) => {
  'type': 'object',
  'properties': {
    for (final key in _allowedArguments[operation] ?? const {'reason'})
      key: switch (key) {
        'projectId' => {
          'type': 'integer',
          if (projectIds.isNotEmpty) 'enum': projectIds.toList()..sort(),
        },
        'iid' ||
        'todoId' ||
        'noteId' ||
        'awardId' ||
        'labelId' ||
        'milestoneId' ||
        'boardId' ||
        'listId' => {'type': 'integer'},
        'position' => {
          'type': operation == 'moveBoardList' ? 'integer' : 'object',
        },
        'starred' ||
        'subscribed' ||
        'resolved' ||
        'hidden' => {'type': 'boolean'},
        'fields' => {'type': 'object'},
        _ => {'type': 'string'},
      },
  },
  'required': [
    if (operation == 'markTodoDone') 'todoId' else 'projectId',
    if (operation == 'upload_attachment') 'attachmentId',
    'reason',
  ],
  'additionalProperties': false,
};

const _allowedArguments = <String, Set<String>>{
  'setStar': {'projectId', 'starred', 'reason'},
  'setSubscribed': {'projectId', 'resource', 'iid', 'subscribed', 'reason'},
  'markTodoDone': {'todoId', 'reason'},
  'addAwardEmoji': {'projectId', 'resource', 'iid', 'name', 'noteId', 'reason'},
  'removeAwardEmoji': {
    'projectId',
    'resource',
    'iid',
    'awardId',
    'noteId',
    'reason',
  },
  'createNote': {'projectId', 'resource', 'iid', 'body', 'reason'},
  'updateNote': {'projectId', 'resource', 'iid', 'noteId', 'body', 'reason'},
  'createIssue': {'projectId', 'fields', 'reason'},
  'updateIssue': {'projectId', 'iid', 'fields', 'reason'},
  'createMergeRequest': {'projectId', 'fields', 'reason'},
  'updateMergeRequest': {'projectId', 'iid', 'fields', 'reason'},
  'unapproveMergeRequest': {'projectId', 'iid', 'reason'},
  'createTodo': {'projectId', 'resource', 'iid', 'reason'},
  'createDiscussion': {
    'projectId',
    'resource',
    'iid',
    'body',
    'position',
    'reason',
  },
  'createDiscussionNote': {
    'projectId',
    'resource',
    'iid',
    'discussionId',
    'body',
    'reason',
  },
  'updateDiscussionNote': {
    'projectId',
    'resource',
    'iid',
    'discussionId',
    'noteId',
    'body',
    'reason',
  },
  'setDiscussionResolved': {
    'projectId',
    'resource',
    'iid',
    'discussionId',
    'resolved',
    'reason',
  },
  'createDraftNote': {
    'projectId',
    'iid',
    'body',
    'commitId',
    'position',
    'reason',
  },
  'updateDraftNote': {'projectId', 'iid', 'noteId', 'body', 'reason'},
  'createLabel': {'projectId', 'fields', 'reason'},
  'updateLabel': {'projectId', 'labelId', 'fields', 'reason'},
  'createMilestone': {'projectId', 'fields', 'reason'},
  'updateMilestone': {'projectId', 'milestoneId', 'fields', 'reason'},
  'setMilestoneState': {'projectId', 'milestoneId', 'stateEvent', 'reason'},
  'createBoard': {'projectId', 'name', 'reason'},
  'renameBoard': {'projectId', 'boardId', 'name', 'reason'},
  'setBoardSystemListHidden': {
    'projectId',
    'boardId',
    'list',
    'hidden',
    'reason',
  },
  'createBoardList': {'projectId', 'boardId', 'labelId', 'reason'},
  'moveBoardList': {'projectId', 'boardId', 'listId', 'position', 'reason'},
  'moveBoardCard': {'projectId', 'iid', 'fields', 'reason'},
  'upload_attachment': {'projectId', 'attachmentId', 'reason'},
};
