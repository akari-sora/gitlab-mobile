import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../../features/ai/ai_attachment_session.dart';
import '../../../features/ai/ai_write_journal.dart';
import '../../failure.dart';
import '../../instance.dart';
import '../ai_transcript.dart';
import '../app_text.dart';
import '../exact_edit.dart' as exact;
import '../wire/wire_format.dart';
import '../write_text.dart' as text;
import 'gitlab_write_port.dart' as port;
import 'graphql_write_hooks.dart';
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
    port.AiWritePreview? preview,
    this.fields = const <String, String>{},
    this.upload,
    this.closingRefs = const <String>[],
    this.editableField,
  }) : preview = preview ?? port.AiFieldsPreview(const {});

  final String executionId;
  final String operationId;
  AiTierDecision tier;
  String payloadDigest;
  String previewText;
  port.AiWritePreview preview;
  final String userUtterance;
  final String modelReason;
  final DateTime expiresAt;
  final int proposalEpoch;
  final int writePolicyRevision;
  final String consentHash;
  final int scopeRevision;
  final String releaseName;

  /// `upload_attachment` only: what the card shows about the file and the
  /// project it goes to (§3.1).
  final AiUploadPreview? upload;

  /// In-scope issues this description or commit message closes (§5 item 9).
  /// Out-of-scope references require fixed confirmation instead.
  List<String> closingRefs;

  /// The write's arguments for the approval card, each value redacted with
  /// the live secrets. The model's `reason` is [modelReason] instead.
  Map<String, String> fields;

  /// The one text field an edit may replace, from the ledger, and only when
  /// this write carries it; null means the card offers no edit.
  final String? editableField;
  String? editedText;
  bool get valid => _valid;
  bool _valid = true;
  void invalidate() => _valid = false;

  /// Why approval is held right now, or null. A held proposal stays valid
  /// and resumes when the hold lifts; approving it meanwhile dispatches
  /// nothing. [AiWritePause] names the values.
  String? get pausedReason => _pausedReason;
  String? _pausedReason;

  /// The account is being removed (§8 step 1): the card disables approve
  /// and says so. Cancelling the removal lifts the hold.
  bool get accountRemovalHeld =>
      _pausedReason == AiWritePause.accountRemovalHeld;

  /// How the proposal ended; null while it waits or runs.
  AiWriteOutcome? get outcome => _outcome;
  AiWriteOutcome? _outcome;
}

/// Holds that pause a waiting proposal instead of ending it. Each one still
/// refuses a dispatch at the §7.3 step 4.1, 4.3 and 4.4 checks.
abstract final class AiWritePause {
  /// §8 step 1: the account's removal hold.
  static const accountRemovalHeld = 'accountRemovalHeld';

  /// §12.2: no foreground service, and the app is not on screen.
  static const backgrounded = 'backgrounded';

  /// §7.3 step 4.1: GitLab asked to wait (Retry-After).
  static const clientUnavailable = 'clientUnavailable';
}

/// An upload card's file and target (§3.1, scope and preview: file name,
/// size, type, the target project's full path and its visibility). The project fields
/// come from the proposal's fresh project read; display strings are
/// redacted with the live secrets.
final class AiUploadPreview {
  const AiUploadPreview({
    required this.attachmentId,
    required this.filename,
    required this.sizeBytes,
    required this.contentType,
    required this.sha256Prefix,
    required this.projectId,
    required this.projectPath,
    required this.projectVisibility,
  });

  final String attachmentId;
  final String filename;
  final int sizeBytes;
  final String? contentType;
  final String sha256Prefix;
  final int projectId;
  final String? projectPath;

  /// `private`, `internal` or `public`; null when GitLab did not say.
  final String? projectVisibility;

  /// Anyone who can see content that quotes the file can fetch it: a
  /// public or internal project, or one whose visibility is unknown.
  bool get readersCanFetch => projectVisibility != 'private';

  /// Where the §3.1 warning goes at [level]: the card at the confirming
  /// levels, the audit row at the automatic ones.
  AiUploadVisibilityNotice noticeAt(AiAutonomyLevel level) =>
      uploadVisibilityNotice(
        visibility: readersCanFetch ? projectVisibility ?? 'internal' : '',
        level: level,
      );
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
    this.upload,
    this.auditNotice,
    this.targetName,
    this.webLink,
    this.uploadReferable,
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

  /// `upload_attachment`: the file and the project it went to.
  final AiUploadPreview? upload;

  /// The audit row's warning, or null: [uploadReadersCanFetch] when an
  /// upload into a public or internal project ran without a card (§3.1).
  final String? auditNotice;

  /// The write's target for the audit row (§7.7), from the pre-read: `#5`,
  /// `!12`, a project path, a file name or `@username`. Null when the write
  /// stopped before its target was read. Redacted.
  final String? targetName;

  /// A GitLab page for the target, built from the verified instance and
  /// pre-read or returned ids, never from a model URL (§7.7). Null when
  /// there is none (or the target was never read).
  final Uri? webLink;

  /// A succeeded upload: whether later text can quote it as
  /// `[[attachment:att-<n>]]`. False when GitLab's `markdown` is not one
  /// attachment token the app can rebuild (§3.1: the response has the wrong
  /// form and cannot be quoted).
  final bool? uploadReferable;

  bool get successful => state == AiJournalState.succeeded || noChange;
  String get summary => _singleLine(
    'write ${operationId ?? "operation"}'
    '${target == null ? "" : " on $target"}: '
    '${noChange ? "noChange" : state.name}; $reasonCode'
    '${reasonCode == "userRejected" ? "; the user rejected the proposal" : ""}'
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
  void beginSegment();
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
    this.currentJobId,
    this.currentResource,
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
  final int? currentJobId;
  final AiTargetRef? currentResource;

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

bool _graphWriteBack(String operation) => const {
  'updateWorkItemContent',
  'editWorkItemActivityNote',
  'updateWorkItemLabels',
}.contains(operation);

AiWriteFreshness _withPreparedFields(
  AiWriteFreshness fresh,
  port.AiWritePrepared prepared,
) => AiWriteFreshness(
  updatedAt: fresh.updatedAt,
  headSha: fresh.headSha,
  lastCommitId: fresh.lastCommitId,
  mergeCheckSummary: fresh.mergeCheckSummary,
  facts: fresh.facts,
  noChange: fresh.noChange,
  visibilityUnreadable: fresh.visibilityUnreadable,
  polluted: fresh.polluted,
  currentFields: {...fresh.currentFields, ...prepared.currentFields},
  provenance: fresh.provenance,
);

/// Packet 4 supplies the exact-edit checker. An absent checker refuses fragment
/// writes; it must never fall back to scanning or rewriting the whole source.
typedef AiWriteFragmentChecker =
    ({String? blockCode, List<AiFixedConfirmReason> confirmReasons}) Function(
      port.AiTextScan scan, {
      required Set<String> knownSecrets,
      required GitLabInstance instance,
      required text.AiVisibilityContext visibility,
    });

/// Production checks retain packet 4's unchanged-secret warning count. The
/// older reason-only injection remains available for existing family tests.
typedef AiWriteFragmentCheckerWithCount =
    exact.AiFragmentCheck Function(
      port.AiTextScan scan, {
      required Set<String> knownSecrets,
      required GitLabInstance instance,
      required text.AiVisibilityContext visibility,
    });

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
    this.checkFragments,
    this.checkFragmentsWithCount,
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
       _httpCost = httpCost;

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
  final AiWriteFragmentChecker? checkFragments;
  final AiWriteFragmentCheckerWithCount? checkFragmentsWithCount;
  final void Function()? onChanged;
  final void Function(AiToolCall call, AiWriteOutcome outcome)? onOutcome;
  final String interfaceLanguage;
  final List<String> deviceLanguages;
  final String Function()? currentInterfaceLanguage;
  final List<String> Function()? currentDeviceLanguages;
  final bool persistConversation;
  final DateTime Function() _now;
  final int Function(String)? _httpCost;
  final Set<port.AiCreatedRef> _segmentCreated = {};
  int _segmentGeneration = 0;
  final Map<String, _PendingWrite> _pending = {};
  final Map<String, AiWriteOutcome> _results = {};
  final List<AiWriteProposal> _settledEdits = [];
  final Map<Future<AiWriteOutcome>, String> _activeOperations = {};

  /// Attachments uploaded in the current batch of tool calls. §3.1: an
  /// upload and a write quoting it cannot be proposed in the same batch.
  final Set<String> _uploadedThisBatch = {};
  port.AiGitLabWritePort? _port;
  String _userUtterance = '';
  String _runId = _nonce();
  String? _stopped;
  bool _previousIncomplete = false;
  Timer? _approvalTimer;
  static final List<_WriteLease> _leases = [];
  // A failed graph boundary flush cannot be inferred safe from the cached
  // prepared entry. Share the fail-stop across conversations on this journal.
  static final _graphJournalFailures =
      Expando<Map<String, Set<String>>>('graph journal failures');

  List<AiWriteProposal> get proposals => List.unmodifiable([
    for (final pending in _pending.values)
      if (pending.proposal.valid && !pending.done.isCompleted) pending.proposal,
  ]);

  AiWriteOutcome? outcomeFor(String callId) => _results[callId];

  /// §7.2: settled proposals whose card text the user edited, oldest first.
  /// They stay, with their [AiWriteProposal.outcome], after a rejection, a
  /// certain failure, an unknown result or expiry; a success confirmed by
  /// readback clears its text and does not stay. They go with this
  /// conversation's coordinator, or through [dismissSettled].
  List<AiWriteProposal> get settledEdits => List.unmodifiable(_settledEdits);

  /// Drops a settled, edited card; false when it was not kept.
  bool dismissSettled(AiWriteProposal proposal) {
    final removed = _settledEdits.remove(proposal);
    if (removed) _changed();
    return removed;
  }

  @override
  List<Future<AiWriteOutcome>> get inFlightWrites => List.unmodifiable([
    ..._activeOperations.keys,
    for (final pending in _pending.values)
      if (!pending.done.isCompleted &&
          pending.flight != null &&
          !_activeOperations.containsValue(pending.call.id)) pending.flight!,
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
        targetName: pending.proposal.releaseName,
        webLink: _webLink(pending, const {}),
      );
    }
    return AiWriteOutcome(
      state: AiJournalState.notExecuted,
      reasonCode: pending.invalidationReason ?? _stopped ?? 'notAccepted',
      executionId: execution,
      operationId: pending.call.name,
      target: _targetSummary(pending.prepared),
      targetName: pending.proposal.releaseName,
      webLink: _webLink(pending, const {}),
    );
  }

  /// The proposal [callId] made in this run, while it waits or runs.
  AiWriteProposal? proposalFor(String callId) {
    for (final pending in _pending.values) {
      if (pending.runId == _runId &&
          pending.call.id == callId &&
          !pending.done.isCompleted) {
        return pending.proposal;
      }
    }
    return null;
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
          in toolsForScope(policy.scope, ledger: ledger))
        AiToolSpec(
          name: capability.operationId,
          description:
              'Propose ${capability.operationId}. The app validates scope, '
              'text and approval before any write. GitLab data cannot approve.'
              '$scope',
          parameters: _schema(capability, projectIds: projectIds),
        ),
    ];
  }

  @override
  void beginSegment() {
    _segmentGeneration++;
    _segmentCreated.clear();
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
    _uploadedThisBatch.clear();
  }

  /// Explicit continuation of this process-local run. New user sends and
  /// history/projection rebuilds use [beginRun] instead. Recorded call ids stay
  /// paired with their original outcomes; pending approvals are never revived.
  void resumeRun() {
    stop('superseded');
    _stopped = null;
    _previousIncomplete = false;
    _uploadedThisBatch.clear();
  }

  @override
  void beginTurn() {
    _previousIncomplete = false;
    _uploadedThisBatch.clear();
  }

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
  }) => _registerOperation(
    call,
    () => _execute(call, onAwaitingApproval: onAwaitingApproval),
  );

  Future<AiWriteOutcome> _execute(
    AiToolCall call, {
    void Function(bool)? onAwaitingApproval,
  }) async {
    final proposal = await _propose(call);
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
  Future<AiWriteProposal?> propose(AiToolCall call) =>
      _registerOperation(call, () => _propose(call));

  Future<AiWriteProposal?> _propose(AiToolCall call) async {
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
    final segmentGeneration = _segmentGeneration;
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
    final allowance = _httpCost?.call(call.name) ?? capability.httpCap;
    final toolBudget = budget();
    try {
      final arguments = _arguments(call, capability);
      var target = _target(capability, arguments, policy.scope);
      // §2: a todo id is a global id. Its issue or merge request is known
      // only once the port reads the todo, so its scope is decided on that
      // pre-read below (and the port refuses a todo outside the scope).
      final ownerFromPreRead =
          capability.scopeClass == AiScopeClass.accountTodo;
      // Scope and autonomy are checked before constructing a write port.
      final initialTier = _tier(
        capability,
        arguments,
        target,
        policy,
        const AiWriteFreshness(),
      );
      if (initialTier.decision == AiGateDecision.deny &&
          !(ownerFromPreRead && initialTier.scopeDenied)) {
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
      var fresh = await readFreshness(request);
      _requirePolicy(policy, runId: runId);
      // Whole-field GraphQL writes open their target before the shared text
      // policy, so even bypass sees the current field's hidden spans. Reuse
      // that capability after sanitizing; do not add a second opening read.
      final opened = _graphWriteBack(request.operationId)
          ? await (_port ??= createPort()).prepare(request)
          : null;
      _requirePolicy(policy, runId: runId);
      if (opened != null) fresh = _withPreparedFields(fresh, opened);
      final preparedText = _prepareText(request, policy, fresh);
      request = preparedText.request;
      final prepared = opened ?? await (_port ??= createPort()).prepare(request);
      if (opened != null) prepared.bindPreparedText(request);
      _requirePolicy(policy, runId: runId);
      if (prepared.boundary != capability.boundary) {
        throw const _WriteBlocked('graphBoundaryMismatch');
      }
      final scanReasons = _checkTextScan(prepared, policy, fresh);
      if (ownerFromPreRead) target = _todoTarget(prepared, policy.scope);
      final extra = <AiFixedConfirmReason>[
        ...preparedText.reasons, ...scanReasons.reasons,
      ];
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
      final settled = journal
          .entries(policy.scope.accountKey)
          .where((entry) => entry.operationId == call.name &&
              entry.writeKeys.length == prepared.writeKeys.length &&
              entry.writeKeys.containsAll(prepared.writeKeys));
      // §15.8: an identical proposal to a write this same run already settled
      // as succeeded or uncertain is always confirmed, resumed or not. Writes
      // from other runs or conversations only matter once runs resume (MR6c).
      if (settled.any((entry) =>
          entry.runId == runId &&
          entry.conversationId == conversationId &&
          (entry.state == AiJournalState.succeeded ||
              entry.state == AiJournalState.writeUncertain))) {
        extra.add(AiFixedConfirmReason.duplicateOfSettledWrite);
      }
      // §3.1 separately requires successful identical uploads to be confirmed
      // across runs and conversations, unlike §7.7's resume-only rule.
      if (call.name == 'upload_attachment' && settled.any((entry) =>
          entry.state == AiJournalState.succeeded)) {
        extra.add(AiFixedConfirmReason.duplicateUpload);
      }
      final tier = _tier(
        capability,
        request.arguments,
        target,
        policy,
        fresh,
        extra: extra,
        prepared: prepared,
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
        preview: redactAiWritePreview(prepared.preview, safeDisplay,
            preexistingSecretHits: scanReasons.preexistingSecretHits),
        fields: _fields(request, capability, safeDisplay),
        editableField: _editableField(request, capability),
        closingRefs: [
          for (final ref in preparedText.closingRefs) safeDisplay(ref),
        ],
        upload: attachment == null
            ? null
            : AiUploadPreview(
                attachmentId: attachment.id,
                filename: safeDisplay(attachment.filename),
                sizeBytes: attachment.size,
                contentType: attachment.mediaType,
                sha256Prefix: attachment.sha256Prefix,
                projectId: request.arguments['projectId']! as int,
                projectPath: _safeMetadata(prepared.projectPath),
                projectVisibility: prepared.projectVisibility,
              ),
      );
      _pending[id] = _PendingWrite(
        call,
        runId,
        segmentGeneration,
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

  Future<T> _registerOperation<T>(
    AiToolCall call,
    Future<T> Function() operation,
  ) {
    final done = Completer<AiWriteOutcome>();
    final settlement = done.future;
    _activeOperations[settlement] = call.id;
    final result = Future<T>.sync(operation);
    unawaited(result.then<void>((_) {
      if (!done.isCompleted) {
        done.complete(
          _results[call.id] ?? _notExecuted(call, 'operationSettled'),
        );
      }
      _activeOperations.remove(settlement);
    }, onError: (Object _) {
      if (!done.isCompleted) {
        done.complete(
          _results[call.id] ?? _notExecuted(call, 'operationSettled'),
        );
      }
      _activeOperations.remove(settlement);
    }));
    return result;
  }

  @override
  Future<AiWriteOutcome> approve(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  }) {
    final pending = _pending[proposal.executionId];
    if (pending != null && _activeOperations.containsValue(pending.call.id)) {
      return _approve(proposal, typedName: typedName, editedText: editedText);
    }
    final call = pending?.call ?? AiToolCall(
      id: proposal.executionId,
      name: proposal.operationId,
      arguments: const {},
    );
    return _registerOperation(
      call,
      () => _approve(proposal, typedName: typedName, editedText: editedText),
    );
  }

  Future<AiWriteOutcome> _approve(
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
        final request = _edit(
          pending.request, ledger.find(proposal.operationId)!, editedText,
        );
        pending.prepared.validatePreparedText(request);
        final processed = _prepareText(request, snapshot(), pending.fresh);
        pending.prepared.validatePreparedText(processed.request);
        final tier = _tier(
          ledger.find(proposal.operationId)!,
          processed.request.arguments,
          pending.target,
          snapshot(),
          pending.fresh,
          extra: [...pending.reasons, ...processed.reasons],
          prepared: pending.prepared,
        );
        if (!tier.canPropose) throw const _WriteBlocked('policyDenied');
        if (pending.prepared.boundary == AiWriteBoundary.graph) {
          pending.prepared.bindPreparedText(processed.request);
        }
        pending.request = request;
        pending.editBlocked = null;
        proposal.tier = tier;
        proposal.previewText = safeDisplay(
          _preview(processed.request, pending.prepared.releaseName),
        );
        proposal.fields = _fields(
          processed.request, ledger.find(proposal.operationId)!, safeDisplay,
        );
        if (proposal.preview is port.AiFieldsPreview) {
          proposal.preview = redactAiWritePreview(
            port.AiFieldsPreview(processed.request.arguments), safeDisplay,
          );
        }
        proposal.payloadDigest = _digest(processed.request);
        proposal.closingRefs = [
          for (final ref in processed.closingRefs) safeDisplay(ref),
        ];
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
    // A hold (§8 step 1: account removal; §12.2: app not on screen) refuses
    // the approval without dispatching or ending the proposal, which carries
    // on once the hold lifts (§8 step 2).
    if (_pendingFailure(pending, pauses: false) == null) {
      final held = _pauseFailure(snapshot());
      if (held != null) {
        if (_updatePause(pending)) _changed();
        return _notExecuted(
          pending.call,
          held,
          executionId: proposal.executionId,
          target: _targetSummary(pending.prepared),
        );
      }
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
    final graph = pending.prepared.boundary == AiWriteBoundary.graph;
    var graphMarkAttempted = false;
    var graphTerminalAttempted = false;
    var graphTerminalCompleted = false;
    var graphJournalFailed = false;
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
          lastCommitId: _safeMetadata(
            pending.prepared.journal.lastCommitId ??
                (_legacy(proposal.operationId) ? pending.fresh.lastCommitId : null),
          ),
          headSha: _safeMetadata(
            pending.prepared.journal.headSha ??
                (_legacy(proposal.operationId) ? pending.fresh.headSha : null),
          ),
          updatedAt: _safeMetadata(
            pending.prepared.journal.updatedAt ??
                (_legacy(proposal.operationId) ? pending.fresh.updatedAt : null),
          ),
          mergeCheckSummary: _safeMetadata(
            pending.prepared.journal.mergeCheckSummary ??
                (_legacy(proposal.operationId) ? pending.fresh.mergeCheckSummary : null),
          ),
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
      var fresh = await readFreshness(request);
      _requirePending(pending);
      final port.AiWritePrepared? opened;
      try {
        opened = _graphWriteBack(request.operationId)
            ? await _port!.prepare(request)
            : null;
      } on port.AiWriteRefused catch (failure) {
        // This proposal already proved ownership. A different author or
        // actor at dispatch is target drift, not a new proposal refusal.
        if (request.operationId == 'editWorkItemActivityNote' &&
            failure.reason == 'notOwnNote') {
          throw const _WriteBlocked('targetChanged');
        }
        rethrow;
      }
      _requirePending(pending);
      if (opened != null) fresh = _withPreparedFields(fresh, opened);
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
      final prepared = opened ?? await _port!.prepare(request);
      if (opened != null) prepared.bindPreparedText(request);
      _requirePending(pending);
      if (prepared.boundary != capability.boundary ||
          prepared.boundary != pending.prepared.boundary) {
        throw const _WriteBlocked('graphBoundaryMismatch');
      }
      if (!_sameKeys(prepared.writeKeys, pending.prepared.writeKeys) ||
          !_sameKeys(prepared.dependencyKeys, pending.prepared.dependencyKeys) ||
          prepared.releaseName != pending.prepared.releaseName ||
          prepared.confirmName != pending.prepared.confirmName ||
          prepared.bindingDigest != pending.prepared.bindingDigest) {
        throw const _WriteBlocked('targetChanged');
      }
      final scanReasons = _checkTextScan(prepared, snapshot(), fresh);
      final tier = _tier(
        capability,
        request.arguments,
        pending.target,
        snapshot(),
        fresh,
        extra: [...pending.reasons, ...processed.reasons, ...scanReasons.reasons],
        prepared: prepared,
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
        graphTerminalAttempted = graph;
        await journal.finish(
          executionId: proposal.executionId,
          terminal: AiJournalState.notExecuted,
        );
        graphTerminalAttempted = false;
        graphTerminalCompleted = graph;
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
      _requirePending(pending);
      if (graph) {
        Future<void> beforeMutation() async {
          _requirePending(pending);
          graphMarkAttempted = true;
          try {
            await journal.markDispatching(executionId: proposal.executionId);
            dispatching = true;
          } on Object catch (error) {
            // These journal gates run before any dispatching save. All other
            // failures can leave the flush outcome unknown.
            graphJournalFailed = error is! AiJournalException || !const {
              'accountBlocked', 'invalidTransition', 'isolated',
              'confirmationRequired', 'recoveryPending', 'unavailable',
              'unknownExecution', 'staleOwner', 'keyMissing', 'removed',
              'unknownFormat', 'overSize', 'uninitialized', 'storageLimit',
              'notConfigured',
            }.contains(error.reason);
            rethrow;
          }
        }
        prepared.bindGraphBeforeMutation(beforeMutation);
      } else {
        await journal.markDispatching(executionId: proposal.executionId);
        dispatching = true;
      }
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
            extra: [...pending.reasons, ...processed.reasons, ...scanReasons.reasons],
            prepared: prepared,
          );
          if (!currentTier.canPropose ||
              (!confirmed && currentTier.decision != AiGateDecision.execute) ||
              currentTier.tier != proposal.tier.tier ||
              currentTier.requiresTypedName !=
                  proposal.tier.requiresTypedName ||
              currentTier.typedName != proposal.tier.typedName ||
              !proposal.tier.reasons.toSet().containsAll(currentTier.reasons)) {
            pending.invalidationReason = 'approvalRequired';
            return false;
          }
          accepted = true;
          if (attachmentId != null) attachments?.beginUpload(attachmentId);
          return true;
        },
      );
      if (outcome is port.AiGraphNoChange) {
        if (!graph || dispatching || accepted) {
          throw const _WriteBlocked('graphContractViolation');
        }
        graphTerminalAttempted = true;
        await journal.finish(
          executionId: proposal.executionId,
          terminal: AiJournalState.notExecuted,
        );
        graphTerminalAttempted = false;
        graphTerminalCompleted = true;
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
      if (outcome is port.AiWriteNotSent) {
        graphTerminalAttempted = graph;
        if (dispatching) {
          await journal.revertDispatchingToNotExecuted(
            executionId: proposal.executionId,
          );
        } else {
          await journal.finish(
            executionId: proposal.executionId,
            terminal: AiJournalState.notExecuted,
          );
        }
        graphTerminalAttempted = false;
        graphTerminalCompleted = graph;
        return _complete(
          pending,
          _notExecuted(
            pending.call,
            _pendingFailure(pending) ?? outcome.reasonCode,
            executionId: proposal.executionId,
            target: _targetSummary(pending.prepared),
          ),
        );
      }
      final settled = outcome as port.AiWriteSettled;
      if (graph && (!accepted || !dispatching ||
          (settled.state != AiJournalState.succeeded &&
              settled.state != AiJournalState.writeUncertain))) {
        throw const _WriteBlocked('graphContractViolation');
      }
      graphTerminalAttempted = graph;
      await journal.finish(
        executionId: proposal.executionId,
        terminal: settled.state,
      );
      graphTerminalAttempted = false;
      graphTerminalCompleted = graph;
      if (settled.state == AiJournalState.succeeded &&
          pending.segmentGeneration == _segmentGeneration) {
        final created = prepared.createdOnSuccess;
        if (created != null && created.accountKey == pending.policy.scope.accountKey) {
          _segmentCreated.add(created);
        }
      }
      // §3.1: only an upload the journal has as succeeded can be quoted,
      // and only from a later batch. Its markdown stays in this memory.
      bool? referable;
      if (attachmentId != null && settled.state == AiJournalState.succeeded) {
        referable =
            attachments?.recordUpload(
              attachmentId,
              projectId: pending.request.arguments['projectId']! as int,
              markdown: settled.uploadMarkdown,
            ) ??
            false;
        _uploadedThisBatch.add(attachmentId);
      }
      final readbackConfirmed =
          settled.state == AiJournalState.succeeded &&
          settled.readbackVerified;
      if (readbackConfirmed) {
        proposal.editedText = null;
      }
      return _complete(
        pending,
        AiWriteOutcome(
          state: settled.state,
          reasonCode: settled.resultCode,
          mutationCount: settled.mutationCount,
          noChange: settled.resultCode == 'noChange',
          readbackConfirmed: readbackConfirmed,
          executionId: proposal.executionId,
          operationId: proposal.operationId,
          target: _targetSummary(pending.prepared),
          resultSummary: [
            _resultSummary(settled.projection),
            if (referable != null)
              'attachment=$attachmentId, referable=$referable',
          ].where((part) => part.isNotEmpty).join(', '),
          uploadReferable: referable,
          upload: proposal.upload,
          auditNotice: _auditNotice(proposal, confirmed: confirmed, state: settled.state),
        ),
        projection: settled.projection,
      );
    } on Object catch (error) {
      var state = accepted
          ? AiJournalState.writeUncertain
          : AiJournalState.notExecuted;
      // A later display/projection failure cannot undo a successful terminal
      // flush. Retrying finish/revert here would itself be an invalid transition.
      if (!graphTerminalCompleted) {
        try {
          if (graph && (graphJournalFailed || graphTerminalAttempted)) {
            // Do not retry a flush whose durable state is unknown, or claim a
            // refund. An explicit journal recovery/reset must resolve it first.
            throw const AiJournalException('journalUnavailable');
          }
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
          if (graph && (graphMarkAttempted || preparedOnDisk)) {
            graphJournalFailed = true;
            final failures = _graphJournalFailures[journal] ??= {};
            (failures[pending.policy.scope.accountKey] ??= {}).add(proposal.executionId);
          }
          // A failed durable rollback keeps dispatching/uncertain isolation.
          if (dispatching || accepted) state = AiJournalState.writeUncertain;
        }
      }
      return _complete(
        pending,
        AiWriteOutcome(
          state: state,
          reasonCode: graphJournalFailed ? 'journalUnavailable' : accepted
              ? 'writeUncertain'
              : _pendingFailure(pending) ?? _reason(error),
          mutationCount: accepted ? 1 : 0,
          executionId: proposal.executionId,
          operationId: proposal.operationId,
          target: _targetSummary(pending.prepared),
          upload: proposal.upload,
          auditNotice: accepted
              ? _auditNotice(proposal, confirmed: confirmed, state: state)
              : null,
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
        'userRejected',
        executionId: proposal.executionId,
        target: _targetSummary(pending.prepared),
      ),
    );
  }

  /// Backgrounding pauses waiting proposals; it does not end them (§12.2:
  /// without a foreground service no new write starts while the app is
  /// away, and the user carries on in the foreground; §7.2: a waiting
  /// proposal lapses after 30 minutes). Every dispatch check refuses while
  /// the app is not on screen.
  @override
  Future<void> onAppBackground() async => checkNow();

  @override
  void stop([String reason = 'stopped']) {
    _stopped = reason;
    checkNow();
  }

  @override
  void checkNow() {
    var paused = false;
    for (final pending in _pending.values.toList()) {
      if (pending.done.isCompleted) continue;
      final failure = _pendingFailure(pending, pauses: false);
      if (failure == null) {
        paused |= _updatePause(pending);
        continue;
      }
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
    if (paused) _changed();
  }

  /// Refreshes [pending]'s hold; true when it changed.
  bool _updatePause(_PendingWrite pending) {
    final reason = pending.flight == null ? _pauseOf(snapshot()) : null;
    if (pending.proposal._pausedReason == reason) return false;
    pending.proposal._pausedReason = reason;
    return true;
  }

  String? _policyFailure(AiWritePolicySnapshot policy, {bool pauses = true}) {
    if (_stopped != null) return _stopped;
    final failures = _graphJournalFailures[journal]?[policy.scope.accountKey];
    if (failures != null) {
      final unresolved = journal.entries(policy.scope.accountKey).where((entry) =>
          failures.contains(entry.executionId) && const {
            AiJournalState.prepared,
            AiJournalState.dispatching,
            AiJournalState.writeUncertain,
          }.contains(entry.state));
      if (unresolved.isNotEmpty) return 'journalUnavailable';
      _graphJournalFailures[journal]!.remove(policy.scope.accountKey);
    }
    if (!policy.alive) return 'accountChanged';
    if (!policy.enabled) return 'policyDenied';
    if (journal.tombstoneFlag(policy.scope.accountKey)) return 'accountBlocked';
    return pauses ? _pauseFailure(policy) : null;
  }

  /// The hold on [policy]'s account, as [AiWritePause] names it.
  String? _pauseOf(AiWritePolicySnapshot policy) {
    if (journal.removalHeld(policy.scope.accountKey)) {
      return AiWritePause.accountRemovalHeld;
    }
    if (!policy.appInForeground) return AiWritePause.backgrounded;
    if (!policy.clientMayStart) return AiWritePause.clientUnavailable;
    return null;
  }

  /// The refusal a hold gives a proposal or a dispatch.
  String? _pauseFailure(AiWritePolicySnapshot policy) =>
      switch (_pauseOf(policy)) {
        AiWritePause.accountRemovalHeld => 'accountBlocked',
        final String reason => reason,
        null => null,
      };

  void _requirePolicy(
    AiWritePolicySnapshot expected, {
    String? runId,
    bool pauses = true,
  }) {
    if (runId != null && runId != _runId) {
      throw const _WriteBlocked('superseded');
    }
    final current = snapshot();
    final failure = _policyFailure(current, pauses: pauses);
    if (failure != null) throw _WriteBlocked(failure);
    if (current.scope.accountKey != expected.scope.accountKey ||
        current.sessionGeneration != expected.sessionGeneration ||
        current.writePolicyRevision != expected.writePolicyRevision ||
        current.scopeRevision != expected.scopeRevision ||
        current.currentJobId != expected.currentJobId ||
        _originIdentity(current.currentResource) != _originIdentity(expected.currentResource) ||
        current.consentHash != expected.consentHash ||
        _scopeDigest(current.scope) != _scopeDigest(expected.scope)) {
      throw const _WriteBlocked('settingsChanged');
    }
  }

  /// Why [pending] cannot dispatch now. Without [pauses], a hold
  /// ([AiWritePause]) does not count: it pauses a waiting proposal.
  String? _pendingFailure(_PendingWrite pending, {bool pauses = true}) {
    try {
      if (pending.invalidationReason != null) return pending.invalidationReason;
      _requirePolicy(pending.policy, runId: pending.runId, pauses: pauses);
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

  AiWriteOutcome _complete(
    _PendingWrite pending,
    AiWriteOutcome result, {
    Map<String, Object?> projection = const {},
  }) {
    if (pending.done.isCompleted) return pending.outcome!;
    final outcome = AiWriteOutcome(
      state: result.state,
      reasonCode: result.reasonCode,
      mutationCount: result.mutationCount,
      noChange: result.noChange,
      readbackConfirmed: result.readbackConfirmed,
      executionId: result.executionId,
      operationId: result.operationId,
      target: result.target,
      resultSummary: result.resultSummary,
      upload: result.upload,
      auditNotice: result.auditNotice,
      targetName: result.targetName ?? pending.proposal.releaseName,
      webLink: result.webLink ?? _webLink(pending, projection),
      uploadReferable: result.uploadReferable,
    );
    pending.outcome = outcome;
    pending.proposal._outcome = outcome;
    pending.proposal.invalidate();
    if (pending.proposal.editedText != null) {
      _settledEdits.add(pending.proposal);
    }
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

  /// §3.1: an upload into a public or internal project that ran without a
  /// card warns on its audit row instead.
  static String? _auditNotice(
    AiWriteProposal proposal, {
    required bool confirmed,
    required AiJournalState state,
  }) {
    if (confirmed) return null;
    if (proposal.tier.reusesStoredVariables) {
      return state == AiJournalState.succeeded || state == AiJournalState.writeUncertain
          ? 'storedVariablesMayApply' : null;
    }
    final upload = proposal.upload;
    if (upload == null || !upload.readersCanFetch) return null;
    return uploadReadersCanFetch;
  }

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
    port.AiWritePrepared? prepared,
  }) {
    final facts = fresh.facts;
    final preparedFacts = prepared?.facts ?? const AiTierFacts();
    return decideTier(
      AiTierInput(
        level: policy.level,
        capability: capability,
        scope: policy.scope,
        target: target,
        arguments: arguments,
        typedName: prepared?.confirmName ??
            (_legacy(capability.operationId) ? prepared?.releaseName : null),
        binding: bindTargets(
          userMessage: _userUtterance,
          restoredFromHistory: false,
          scope: policy.scope,
          targets: [
            for (final bindingTarget in prepared?.bindingTargets.isNotEmpty == true
                ? prepared!.bindingTargets : [target])
              _boundTarget(bindingTarget, policy),
          ],
          interfaceLanguage:
              currentInterfaceLanguage?.call() ?? interfaceLanguage,
          deviceLanguages: currentDeviceLanguages?.call() ?? deviceLanguages,
          operationId: capability.operationId,
          arguments: arguments,
        ),
        facts: AiTierFacts(
          protectedOrDefaultBranch: facts.protectedOrDefaultBranch || preparedFacts.protectedOrDefaultBranch,
          removeSourceBranch: facts.removeSourceBranch || preparedFacts.removeSourceBranch,
          confidentialLowered: facts.confidentialLowered || preparedFacts.confidentialLowered,
          visibilityRaised: facts.visibilityRaised || preparedFacts.visibilityRaised,
          newSnippetNotPrivate: facts.newSnippetNotPrivate || preparedFacts.newSnippetNotPrivate,
          touchesCiConfig: facts.touchesCiConfig || preparedFacts.touchesCiConfig,
          pipelineVariables: facts.pipelineVariables || preparedFacts.pipelineVariables,
          scheduleParamsUnsafe: facts.scheduleParamsUnsafe || preparedFacts.scheduleParamsUnsafe,
          squash: facts.squash || preparedFacts.squash,
          triggersPipeline: facts.triggersPipeline || preparedFacts.triggersPipeline,
          reasons: {...facts.reasons, ...preparedFacts.reasons, ...extra}.toList(),
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
        if (_argumentSpecs(ledger.find(operation)!)[entry.key]?.portVisible == true)
          entry.key: entry.value,
      if (attachment != null) ...{
        'filename': attachment.filename,
        'contentType': attachment.mediaType ?? 'application/octet-stream',
      },
    },
    segmentCreated: _segmentCreated.where(
      (created) => created.accountKey == policy.scope.accountKey,
    ).toSet(),
    scheduleHmacKey: journal.scheduleHmacKey,
    uploadBytes: attachment?.bytes,
    sendTimeout: attachment == null
        ? null
        : port.GitLabAiWritePort.uploadSendTimeout(attachment.size),
  );

  ({
    port.AiWriteRequest request,
    List<AiFixedConfirmReason> reasons,
    List<String> closingRefs,
  })
  _prepareText(
    port.AiWriteRequest request,
    AiWritePolicySnapshot policy,
    AiWriteFreshness fresh,
  ) {
    final reasons = <AiFixedConfirmReason>[];
    final closingRefs = <String>[];
    final arguments = Map<String, Object?>.from(request.arguments);
    final capability = ledger.find(request.operationId)!;
    final project = arguments['projectId'] as int?;
    String prepare(String value, String field, AiArgSpec spec, String path) {
      final classA = spec.text == AiTextRole.quickActionMarkdown;
      // §3.1, placeholder substitution: `[[attachment:att-<n>]]` quotes an
      // upload this conversation finished in an earlier batch, into the
      // same project.
      var otherProject = false;
      for (final match in _attachmentPlaceholder.allMatches(value)) {
        final id = 'att-${match.group(1)}';
        if (_uploadedThisBatch.contains(id)) {
          throw const _WriteBlocked('attachmentNotUploaded');
        }
        final uploaded = attachments?.uploadedProjects(id) ?? const <int>{};
        if (uploaded.isNotEmpty && !uploaded.contains(project)) {
          otherProject = true;
        }
      }
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
          renderedMarkdown: classA || spec.text == AiTextRole.renderedMarkdown ||
              (spec.text == AiTextRole.fullNewContent &&
                  RegExp(r'\.(md|markdown)$', caseSensitive: false)
                      .hasMatch(path)),
          // A new merge request's description has no field provenance, yet
          // its closing keywords act on merge all the same.
          closesIssuesOnMerge: spec.text == AiTextRole.commitMessage ||
              (classA && request.operationId == 'createMergeRequest'),
          scopeGrants: policy.scope.grants,
        ),
        attachments: project == null
            ? null
            : attachmentSubstitution?.call(project),
        sameProjectClassA: project != null && !otherProject,
        currentFieldValue: fresh.currentFields[field],
      );
      if (outcome.policyBlocked || outcome.finalText == null) {
        // An id with no succeeded upload in this project.
        throw _WriteBlocked(
          outcome.blockedReasonCode == text.AiTextBlockCode.attachmentUnknown
              ? 'attachmentNotUploaded'
              : outcome.blockedReasonCode,
        );
      }
      if (spec.text == AiTextRole.pathOrRef) return outcome.finalText!;
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
      closingRefs.addAll(outcome.closingRefs);
      // Activity creation trims at the core boundary. Bind and display the
      // same normalized body so an edited preview agrees with the adapter.
      if (field == 'body' &&
          const {
            'createWorkItemActivityComment',
            'createWorkItemActivityReply',
          }.contains(request.operationId)) {
        final body = outcome.finalText!.trim();
        if (body.startsWith('/')) {
          throw const _WriteBlocked(text.AiTextBlockCode.quickAction);
        }
        return body;
      }
      return outcome.finalText!;
    }

    Object? visit(Object? value, AiArgSpec spec, String field, String path) {
      if (spec.text == AiTextRole.fragmentEdits) return value;
      if (spec.type == AiArgType.stringList) return value;
      if (value is String) return prepare(value, field, spec, path);
      if (value is Map<String, Object?>) {
        final properties = _nestedProperties(spec);
        final nestedPath = value['file_path'] ?? value['path'] ?? path;
        return {
          for (final entry in value.entries)
            entry.key: visit(entry.value, properties[entry.key]!, entry.key, '$nestedPath'),
        };
      }
      if (value is List<Object?> && spec.type != AiArgType.integerList) {
        final item = AiArgSpec(AiArgType.object, properties: _nestedProperties(spec));
        return [for (final element in value) visit(element, item, field, path)];
      }
      return value;
    }

    final specs = _argumentSpecs(capability);
    for (final entry in request.arguments.entries) {
      final spec = specs[entry.key];
      if (spec != null) {
        arguments[entry.key] = visit(entry.value, spec, entry.key,
            '${arguments['path'] ?? arguments['file_path'] ?? ''}');
      }
    }
    return (
      request: port.AiWriteRequest(
        operationId: request.operationId,
        executionId: request.executionId,
        scope: request.scope,
        arguments: arguments,
        uploadBytes: request.uploadBytes,
        sendTimeout: request.sendTimeout,
        segmentCreated: request.segmentCreated,
        scheduleHmacKey: request.scheduleHmacKey,
      ),
      reasons: reasons,
      closingRefs: closingRefs,
    );
  }
  ({List<AiFixedConfirmReason> reasons, int? preexistingSecretHits}) _checkTextScan(
    port.AiWritePrepared prepared,
    AiWritePolicySnapshot policy,
    AiWriteFreshness fresh,
  ) {
    final scan = prepared.textScan;
    final hasFragments = _hasFragmentRole(prepared.request.arguments,
        _argumentSpecs(ledger.find(prepared.request.operationId)!));
    if (scan == null) {
      if (hasFragments) throw const _WriteBlocked('fragmentCheckUnavailable');
      return (reasons: const [], preexistingSecretHits: null);
    }
    final visibility = text.AiVisibilityContext(
      polluted: fresh.polluted,
      visibilityUnreadable: fresh.visibilityUnreadable,
      renderedMarkdown: scan.markdown,
      targetProjectPath: _projectPath(policy.scope, prepared.request.arguments['projectId'] as int?),
      scopeGrants: policy.scope.grants,
    );
    final reasons = <AiFixedConfirmReason>[];
    int? preexistingSecretHits;
    if (hasFragments || scan.newTexts.isNotEmpty || scan.windows.isNotEmpty ||
        scan.files.isNotEmpty) {
      final countedChecker = checkFragmentsWithCount;
      final checker = checkFragments;
      if (countedChecker != null) {
        final checked = countedChecker(scan, knownSecrets: knownSecrets(),
            instance: placeholders.instance, visibility: visibility);
        if (checked.blockCode != null) throw _WriteBlocked(checked.blockCode!);
        reasons.addAll(checked.confirmReasons);
        preexistingSecretHits = checked.preexistingSecretHits;
      } else if (checker != null) {
        final checked = checker(scan, knownSecrets: knownSecrets(),
            instance: placeholders.instance, visibility: visibility);
        if (checked.blockCode != null) throw _WriteBlocked(checked.blockCode!);
        reasons.addAll(checked.confirmReasons);
      } else {
        throw const _WriteBlocked('fragmentCheckUnavailable');
      }
    }
    for (final body in scan.serverClassA) {
      final checked = text.prepareWriteText(
        textClass: text.AiTextClass.quickActionMarkdown,
        modelText: body,
        field: null,
        aiAttribution: false,
        keepNotifications: true,
        placeholders: placeholders,
        knownSecrets: knownSecrets(),
        visibility: visibility,
      );
      if (checked.policyBlocked || checked.finalText != body) {
        throw const _WriteBlocked('policyBlocked');
      }
      reasons.addAll(_confirmReasons(checked));
    }
    return (reasons: reasons, preexistingSecretHits: preexistingSecretHits);
  }

  AiTargetRef _boundTarget(AiTargetRef target, AiWritePolicySnapshot policy) {
    final origin = policy.currentResource;
    final currentResource = origin != null &&
        origin.projectId == target.projectId &&
        ((target.kind == AiTargetKind.file && origin.kind == AiTargetKind.file &&
            target.path == origin.path &&
            (target.refName == origin.refName || target.sourceRef == origin.refName)) ||
         (target.kind == AiTargetKind.merge && origin.kind == AiTargetKind.mergeRequest &&
            target.iid == origin.iid));
    final currentJob = target.kind == AiTargetKind.job &&
        target.jobId == policy.currentJobId && target.jobId != null &&
        policy.scope.grants.any((grant) => grant.projectId == target.projectId);
    final createdPipeline = target.kind == AiTargetKind.job &&
        target.jobBelongsToBoundPipeline &&
        _segmentCreated.any((created) =>
            created.accountKey == policy.scope.accountKey &&
            created.kind == AiTargetKind.pipeline &&
            created.projectId == target.projectId &&
            created.id != null && created.id == target.pipelineId);
    final created = _segmentCreated.any((created) =>
        created.accountKey == policy.scope.accountKey &&
        created.kind == target.kind && created.projectId == target.projectId &&
        ((target.kind == AiTargetKind.pipeline && created.id != null &&
            created.id == target.pipelineId) ||
         (target.kind == AiTargetKind.note &&
            target.side == AiResourceSide.mergeRequest && created.id != null &&
            created.id == (target.noteId ?? target.iid) && created.parentIid != null &&
            created.parentIid == target.parentIid)));
    if (!currentResource && !currentJob && !created && !createdPipeline) return target;
    return AiTargetRef(
      kind: target.kind, side: target.side,
      origin: currentResource || currentJob ? AiTargetOrigin.currentResource :
          created ? AiTargetOrigin.createdInSegment : target.origin,
      projectId: target.projectId, projectPath: target.projectPath,
      iid: target.iid, parentIid: target.parentIid, noteId: target.noteId,
      refName: target.refName, path: target.path,
      sourceRef: target.sourceRef, targetRef: target.targetRef,
      pipelineId: target.pipelineId, jobId: target.jobId,
      jobBelongsToBoundPipeline: target.jobBelongsToBoundPipeline,
      pipelineCreatedInSegment: target.pipelineCreatedInSegment || createdPipeline,
      groupFullPath: target.groupFullPath, groupId: target.groupId, name: target.name,
    );
  }

}

final class _PendingWrite {
  _PendingWrite(
    this.call,
    this.runId,
    this.segmentGeneration,
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
  final int segmentGeneration;
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

final _attachmentPlaceholder = RegExp(r'\[\[attachment:att-([0-9]+)\]\]');

String _singleLine(String value) =>
    value.replaceAll(RegExp(r'[\r\n\u2028\u2029]'), ' ');

String _reason(Object error) => switch (error) {
  GraphHookContractException() => 'graphContractViolation',
  _WriteBlocked(:final reason) => reason,
  port.AiWriteRefused(:final reason) => reason,
  AiJournalException(:final reason) => reason,
  ApiFailure(:final kind) when const {
    FailureKind.forbidden, FailureKind.invisible, FailureKind.validation,
    FailureKind.unsupported, FailureKind.invalidResponse,
    FailureKind.rateLimited, FailureKind.network,
  }.contains(kind) => kind.name,
  _ => 'preflightFailed',
};

String _originIdentity(AiTargetRef? origin) => jsonEncode(origin == null ? null : [
  origin.kind.name, origin.projectId, origin.iid, origin.path, origin.refName,
]);

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
    AiScopeClass.accountTodo ||
    AiScopeClass.accountGlobalOnly => AiTargetKind.todo,
    AiScopeClass.groupWorkItem => AiTargetKind.groupWorkItem,
    AiScopeClass.project ||
    AiScopeClass.projectUpload ||
    AiScopeClass.personalNamespace => AiTargetKind.project,
  };
  final bound = scope.grants.any(
    (grant) =>
        (capability.scopeClass == AiScopeClass.accountGlobalOnly &&
            grant.kind == AiScopeKind.accountGlobal) ||
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

/// §7.7: a GitLab page for [pending]'s target, from the verified instance,
/// the scope's project path and pre-read or returned ids. Never a model URL.
Uri? _webLink(_PendingWrite pending, Map<String, Object?> projection) {
  final instance = pending.policy.scope.resolvedInstance;
  if (instance == null) return null;
  final scope = pending.policy.scope;
  final args = pending.request.arguments;
  final operation = pending.call.name;
  int? positive(Object? value) => value is int && value > 0 ? value : null;
  final todo = pending.prepared.todoTarget;
  final project = todo?.projectId ?? positive(args['projectId']);
  final path = project == null ? null : _projectPath(scope, project);
  if (path == null) return null;
  Uri page(String suffix, [String? fragment]) {
    final uri = instance.projectWeb(suffix.isEmpty ? path : '$path/-/$suffix');
    return fragment == null ? uri : uri.replace(fragment: fragment);
  }

  if (todo != null) {
    return page(
      '${todo.resource == 'merge_requests' ? 'merge_requests' : 'issues'}'
      '/${todo.iid}',
    );
  }
  final resource = switch (operation) {
    'updateIssue' || 'moveBoardCard' => 'issues',
    'updateMergeRequest' ||
    'unapproveMergeRequest' ||
    'createDraftNote' ||
    'updateDraftNote' => 'merge_requests',
    _ => args['resource'] is String ? args['resource']! as String : null,
  };
  final iid = positive(args['iid']);
  if ((resource == 'issues' || resource == 'merge_requests') && iid != null) {
    final note = switch (operation) {
      'createNote' => positive(projection['id']),
      'updateNote' || 'updateDiscussionNote' => positive(args['noteId']),
      _ => null,
    };
    return page('$resource/$iid', note == null ? null : 'note_$note');
  }
  return switch (operation) {
    'createIssue' when positive(projection['iid']) != null => page(
      'issues/${projection['iid']}',
    ),
    'createMergeRequest' when positive(projection['iid']) != null => page(
      'merge_requests/${projection['iid']}',
    ),
    'deleteIssue' => page('issues'),
    'deleteMergeRequest' => page('merge_requests'),
    'deleteLabel' || 'createLabel' || 'updateLabel' => page('labels'),
    'deleteMilestone' => page('milestones'),
    'deleteBoard' => page('boards'),
    'createMilestone' || 'updateMilestone' || 'setMilestoneState' =>
      positive(projection['iid']) == null
          ? page('milestones')
          : page('milestones/${projection['iid']}'),
    'createBoard' =>
      positive(projection['id']) == null
          ? page('boards')
          : page('boards/${projection['id']}'),
    'renameBoard' ||
    'setBoardSystemListHidden' ||
    'createBoardList' ||
    'moveBoardList' ||
    'deleteBoardList' =>
      positive(args['boardId']) == null
          ? page('boards')
          : page('boards/${args['boardId']}'),
    _ => page(''),
  };
}

/// The target of a pre-read todo: the conversation's own issue or merge
/// request binds as the current resource; anything else is only proposed
/// (and an issue or merge request outside the scope is not admitted).
AiTargetRef _todoTarget(port.AiWritePrepared prepared, AiWriteScope scope) {
  final todo = prepared.todoTarget;
  if (todo == null) return AiTargetRef(kind: AiTargetKind.todo);
  final mergeRequest = todo.resource == 'merge_requests';
  final current = scope.grants.any(
    (grant) =>
        grant.projectId == todo.projectId &&
        grant.iid == todo.iid &&
        grant.kind ==
            (mergeRequest ? AiScopeKind.mergeRequest : AiScopeKind.workItem),
  );
  return AiTargetRef(
    kind: AiTargetKind.todo,
    side: mergeRequest ? AiResourceSide.mergeRequest : AiResourceSide.issue,
    projectId: todo.projectId,
    projectPath: _projectPath(scope, todo.projectId),
    parentIid: todo.iid,
    origin: current ? AiTargetOrigin.currentResource : AiTargetOrigin.proposed,
  );
}

/// Where [_edit] would put edited text: the ledger's field at the top level
/// or inside `fields`, or null when this write does not carry it as text.
({String field, bool nested})? _editTarget(
  port.AiWriteRequest request, AiCapability capability,
) {
  final field = capability.editableField;
  if (field == null) return null;
  final args = request.arguments;
  if (_argumentSpecs(capability).containsKey(field) && args[field] is String) {
    return (field: field, nested: false);
  }
  if (args['fields'] case final Map<String, Object?> fields
      when fields[field] is String &&
          _argumentSpecs(capability)['fields']?.properties.containsKey(field) == true) {
    return (field: field, nested: true);
  }
  return null;
}

String? _editableField(port.AiWriteRequest request, AiCapability capability) =>
    _editTarget(request, capability)?.field;

port.AiWriteRequest _edit(
  port.AiWriteRequest request, AiCapability capability, String edited,
) {
  final target = _editTarget(request, capability);
  if (target == null) throw const _WriteBlocked('noEditableText');
  final args = Map<String, Object?>.from(request.arguments);
  if (target.nested) {
    args['fields'] = {...args['fields']! as Map<String, Object?>, target.field: edited};
  } else {
    args[target.field] = edited;
  }
  return port.AiWriteRequest(
    operationId: request.operationId,
    executionId: request.executionId,
    scope: request.scope,
    arguments: args,
    uploadBytes: request.uploadBytes,
    sendTimeout: request.sendTimeout,
    segmentCreated: request.segmentCreated,
    scheduleHmacKey: request.scheduleHmacKey,
  );
}

// Identifiers are represented by the target; content comes from the ledger.
Map<String, String> _fields(
  port.AiWriteRequest request,
  AiCapability capability,
  String Function(String) safeDisplay,
) {
  final shown = <String, String>{};
  void add(Map<String, Object?> values, Map<String, AiArgSpec> specs) {
    for (final entry in values.entries) {
      final spec = specs[entry.key];
      if (spec == null || !spec.modelVisible || entry.value == null) continue;
      if (entry.key == 'fields' && entry.value is Map<String, Object?>) {
        add(entry.value! as Map<String, Object?>, spec.properties);
      } else if (entry.key != 'resource' && entry.key != 'iid' &&
          entry.key != 'position' && !entry.key.endsWith('Id')) {
        shown[entry.key] = safeDisplay(
          entry.value is String ? entry.value! as String : jsonEncode(entry.value),
        );
      }
    }
  }
  add(request.arguments, _argumentSpecs(capability));
  return Map.unmodifiable(shown);
}

String _preview(port.AiWriteRequest request, String releaseName) =>
    '${request.operationId} $releaseName\n${jsonEncode(request.arguments)}';

/// §4.4: the GitLab GETs one write can make. [fresh] is the freshness
/// reader's (the project, then the target record), [prepare] the write
/// port's pre-read (the current user, the project, the parent issue or
/// merge request and the operation's own records; a todo reads up to four
/// pages), each counted at its worst case and made once when the proposal
/// is built and once more after approval. [readback] is the port's
/// independent readback after the mutation.
final class AiWriteRequestCount {
  const AiWriteRequestCount({
    required this.fresh,
    required this.prepare,
    this.readback = 0,
  });

  final int fresh;
  final int prepare;
  final int readback;

  /// GETs from proposal to readback: two passes, then the readback.
  int get reads => 2 * (fresh + prepare) + readback;
}

/// Per-operation worst cases for the MR6b-1 ledger (§4.4, §15 row 19).
const aiWriteRequestCounts = <String, AiWriteRequestCount>{
  'setStar': AiWriteRequestCount(fresh: 1, prepare: 2),
  'setSubscribed': AiWriteRequestCount(fresh: 2, prepare: 3),
  'markTodoDone': AiWriteRequestCount(fresh: 0, prepare: 5),
  'addAwardEmoji': AiWriteRequestCount(fresh: 2, prepare: 4),
  'removeAwardEmoji': AiWriteRequestCount(fresh: 2, prepare: 5),
  'createNote': AiWriteRequestCount(fresh: 2, prepare: 3, readback: 1),
  'updateNote': AiWriteRequestCount(fresh: 2, prepare: 4, readback: 1),
  'createIssue': AiWriteRequestCount(fresh: 1, prepare: 2, readback: 1),
  'updateIssue': AiWriteRequestCount(fresh: 2, prepare: 3, readback: 1),
  'createMergeRequest': AiWriteRequestCount(fresh: 1, prepare: 2, readback: 1),
  'updateMergeRequest': AiWriteRequestCount(fresh: 2, prepare: 3, readback: 1),
  'unapproveMergeRequest': AiWriteRequestCount(fresh: 2, prepare: 3),
  'createTodo': AiWriteRequestCount(fresh: 2, prepare: 3),
  'createDiscussion': AiWriteRequestCount(fresh: 2, prepare: 4),
  'createDiscussionNote': AiWriteRequestCount(
    fresh: 2,
    prepare: 4,
    readback: 1,
  ),
  'updateDiscussionNote': AiWriteRequestCount(
    fresh: 2,
    prepare: 4,
    readback: 1,
  ),
  'setDiscussionResolved': AiWriteRequestCount(
    fresh: 2,
    prepare: 4,
    readback: 1,
  ),
  'createDraftNote': AiWriteRequestCount(fresh: 2, prepare: 4),
  'updateDraftNote': AiWriteRequestCount(fresh: 2, prepare: 4, readback: 1),
  'createLabel': AiWriteRequestCount(fresh: 1, prepare: 2),
  'updateLabel': AiWriteRequestCount(fresh: 2, prepare: 3, readback: 1),
  'createMilestone': AiWriteRequestCount(fresh: 1, prepare: 2),
  'updateMilestone': AiWriteRequestCount(fresh: 2, prepare: 3, readback: 1),
  'setMilestoneState': AiWriteRequestCount(fresh: 2, prepare: 3, readback: 1),
  'createBoard': AiWriteRequestCount(fresh: 1, prepare: 2),
  'renameBoard': AiWriteRequestCount(fresh: 2, prepare: 3),
  'setBoardSystemListHidden': AiWriteRequestCount(fresh: 2, prepare: 3),
  'createBoardList': AiWriteRequestCount(fresh: 1, prepare: 4),
  'moveBoardList': AiWriteRequestCount(fresh: 2, prepare: 4),
  'moveBoardCard': AiWriteRequestCount(fresh: 2, prepare: 3, readback: 1),
  'upload_attachment': AiWriteRequestCount(fresh: 1, prepare: 2),
};

/// §4.4: the HTTP requests a write reserves from the send's shared budget
/// when it is proposed. The ledger cap includes the mutation allowance (two
/// for cancel's compatibility fallback) and doubled logical GETs for OAuth
/// replay. A PAT needs each GET only once. An unknown
/// operation reserves the largest visible ledger cap for compatibility.
int aiWriteRequestAllowance(String operation, {bool oauthReplay = true}) {
  final cap = productionAiLedger.find(operation)?.httpCap ??
      productionAiLedger.modelVisible.fold<int>(0, (most, row) => row.httpCap > most ? row.httpCap : most);
  final mutations = operation == 'cancelAutoMerge' ? 2 : 1;
  return oauthReplay ? cap : (cap - mutations) ~/ 2 + mutations;
}

bool _legacy(String operation) => aiT12Rows.any((row) => row.operationId == operation);

Map<String, AiArgSpec> _argumentSpecs(AiCapability capability) =>
    capability.arguments.isEmpty
        ? productionAiLedger.find(capability.operationId)?.arguments ?? capability.arguments
        : capability.arguments;

Map<String, Object?> _arguments(AiToolCall call, AiCapability capability) {
  final args = call.arguments;
  final specs = {
    for (final entry in _argumentSpecs(capability).entries)
      if (entry.value.modelVisible) entry.key: entry.value,
    'reason': const AiArgSpec(AiArgType.string),
  };
  if (args is! Map<String, Object?> || !_validObject(args, specs) ||
      (args['projectId'] != null && (args['projectId']! as int) < 1) ||
      (args['iid'] != null && (args['iid']! as int) < 1)) {
    throw const _WriteBlocked('invalidArguments');
  }
  return args;
}

bool _validObject(Map<String, Object?> values, Map<String, AiArgSpec> specs) =>
    values.keys.every(specs.containsKey) &&
    specs.entries.every((entry) =>
        !entry.value.required || values.containsKey(entry.key)) &&
    values.entries.every((entry) => _validArg(entry.value, specs[entry.key]!));

bool _validArg(Object? value, AiArgSpec spec) => switch (spec.type) {
  AiArgType.string =>
    value is String &&
        (spec.enumValues == null || spec.enumValues!.contains(value)),
  AiArgType.integer => value is int,
  AiArgType.boolean => value is bool,
  AiArgType.object => value is Map<String, Object?> &&
      _validObject(value, _nestedProperties(spec)),
  AiArgType.integerList => value is List<Object?> && value.every((item) => item is int),
  AiArgType.stringList => value is List<Object?> && value.every((item) => item is String),
  AiArgType.edits || AiArgType.variables || AiArgType.suggestionList ||
  AiArgType.snippetActions => value is List<Object?> && value.length <= 20 &&
      value.every((item) => item is Map<String, Object?> &&
          _validObject(item, _nestedProperties(spec))),
};

bool _hasFragmentRole(Map<String, Object?> values, Map<String, AiArgSpec> specs) {
  for (final entry in values.entries) {
    final spec = specs[entry.key];
    if (spec == null) continue;
    if (spec.text == AiTextRole.fragmentEdits) return true;
    final value = entry.value;
    final nested = _nestedProperties(spec);
    if (value is Map<String, Object?> && _hasFragmentRole(value, nested)) return true;
    if (value is List<Object?> && value.any((item) =>
        item is Map<String, Object?> && _hasFragmentRole(item, nested))) {
      return true;
    }
  }
  return false;
}

/// Copies every display string through the live redactor. The prepared scan
/// and mutation retain their original bytes; only this card projection changes.
port.AiWritePreview redactAiWritePreview(
  port.AiWritePreview preview,
  String Function(String) safeDisplay, {
  int? preexistingSecretHits,
}) {
  Object? value(Object? item) => switch (item) {
    String() => safeDisplay(item),
    List<Object?>() => [for (final child in item) value(child)],
    Map<Object?, Object?>() => {
      for (final entry in item.entries) value(entry.key): value(entry.value),
    },
    _ => item,
  };
  String? optional(String? item) => item == null ? null : safeDisplay(item);
  return switch (preview) {
    port.AiFieldsPreview(:final fields) => port.AiFieldsPreview({
      for (final entry in fields.entries)
        safeDisplay(entry.key): value(entry.value),
    }),
    port.AiDiffPreview() => port.AiDiffPreview(
      path: safeDisplay(preview.path),
      ref: safeDisplay(preview.ref),
      lines: [
        for (final line in preview.lines)
          port.AiDiffLine(kind: line.kind, text: safeDisplay(line.text),
              oldLine: line.oldLine, newLine: line.newLine),
      ],
      newFile: preview.newFile,
      preexistingSecretHits:
          preexistingSecretHits ?? preview.preexistingSecretHits,
      ciPath: preview.ciPath,
      moreFiles: preview.moreFiles,
    ),
    port.AiMergePreview() => port.AiMergePreview(
      sourceBranch: safeDisplay(preview.sourceBranch),
      targetBranch: safeDisplay(preview.targetBranch),
      shortSha: safeDisplay(preview.shortSha),
      pathCount: preview.pathCount,
      squash: preview.squash,
      removeSourceBranch: preview.removeSourceBranch,
      autoMerge: preview.autoMerge,
      ciPaths: preview.ciPaths.map(safeDisplay).toList(),
      closingIssues: [
        for (final issue in preview.closingIssues)
          port.AiClosingIssue(projectId: issue.projectId, iid: issue.iid,
              outOfScope: issue.outOfScope,
              fullReference: optional(issue.fullReference)),
      ],
      headMovedCommits: preview.headMovedCommits.map(safeDisplay).toList(),
    ),
    port.AiPipelinePreview() => port.AiPipelinePreview(
      ref: safeDisplay(preview.ref),
      pipelineId: preview.pipelineId,
      jobId: preview.jobId,
      jobName: optional(preview.jobName),
      stage: optional(preview.stage),
      environment: optional(preview.environment),
      scheduleVariableNames:
          preview.scheduleVariableNames.map(safeDisplay).toList(),
      scheduleParamsUnreadable: preview.scheduleParamsUnreadable,
      newVariableNames: preview.newVariableNames.map(safeDisplay).toList(),
    ),
    port.AiDraftPublishPreview() => port.AiDraftPublishPreview(drafts: [
      for (final draft in preview.drafts)
        port.AiDraftPreview(id: draft.id, body: safeDisplay(draft.body),
            createdInSegment: draft.createdInSegment),
    ]),
    port.AiDeletePreview() => port.AiDeletePreview(
      targetName: safeDisplay(preview.targetName),
      path: optional(preview.path),
      ref: optional(preview.ref),
      count: preview.count,
      hasMore: preview.hasMore,
      parentName: optional(preview.parentName),
      author: optional(preview.author),
      excerpt: optional(preview.excerpt),
    ),
    port.AiCancelAutoMergePreview() => port.AiCancelAutoMergePreview(
      iid: preview.iid,
      sourceBranch: safeDisplay(preview.sourceBranch),
      targetBranch: safeDisplay(preview.targetBranch),
      mayLackPermission: preview.mayLackPermission,
    ),
  };
}

List<AiFixedConfirmReason> _confirmReasons(text.AiTextOutcome outcome) => [
  for (final reason in outcome.confirmReasons)
    switch (reason) {
      text.AiFixedConfirmReason.massMention => AiFixedConfirmReason.massMention,
      text.AiFixedConfirmReason.externalMedia => AiFixedConfirmReason.externalMediaInRenderedMarkdown,
      text.AiFixedConfirmReason.closingOrCrossProject => AiFixedConfirmReason.foreignClosingOrCrossProject,
      text.AiFixedConfirmReason.hiddenContentRemoved => AiFixedConfirmReason.wholeFieldDropsHiddenSpans,
    },
  if (outcome.levelConfirmReasons.isNotEmpty) AiFixedConfirmReason.confidentialOrVisibilityMix,
];

// Family rows may supply a more precise closed item shape through properties.
Map<String, AiArgSpec> _nestedProperties(AiArgSpec spec) {
  if (spec.properties.isNotEmpty) return spec.properties;
  const requiredText = AiArgSpec(AiArgType.string, required: true);
  const requiredId = AiArgSpec(AiArgType.integer, required: true);
  return switch (spec.type) {
    AiArgType.edits => {'old': requiredText, 'new': requiredText},
    AiArgType.variables => {
      'key': requiredText, 'value': requiredText,
      'variable_type': const AiArgSpec(AiArgType.string),
    },
    AiArgType.suggestionList => {
      'iid': requiredId, 'noteId': requiredId, 'suggestionId': requiredId,
    },
    AiArgType.snippetActions => {
      'action': requiredText, 'file_path': requiredText,
      'previous_path': const AiArgSpec(AiArgType.string, text: AiTextRole.pathOrRef),
      'content': const AiArgSpec(AiArgType.string, text: AiTextRole.fullNewContent),
      'edits': const AiArgSpec(AiArgType.edits, text: AiTextRole.fragmentEdits),
    },
    _ => const {},
  };
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
  AiCapability capability, {Set<int> projectIds = const <int>{}}
) => _objectSchema({
  for (final entry in _argumentSpecs(capability).entries)
    if (entry.value.modelVisible) entry.key: entry.value,
  'reason': const AiArgSpec(AiArgType.string, required: true),
}, projectIds: projectIds);

Map<String, Object?> _objectSchema(
  Map<String, AiArgSpec> specs, {Set<int> projectIds = const <int>{}}
) => {
  'type': 'object',
  'properties': {
    for (final entry in specs.entries)
      entry.key: {
        ..._argSchema(entry.value),
        if (entry.key == 'projectId' && projectIds.isNotEmpty)
          'enum': projectIds.toList()..sort(),
      },
  },
  'required': [for (final entry in specs.entries) if (entry.value.required) entry.key],
  'additionalProperties': false,
};

Map<String, Object?> _argSchema(AiArgSpec spec) => switch (spec.type) {
  AiArgType.string => spec.enumValues == null
      ? {'type': 'string'}
      : {
          'type': 'string',
          'enum': spec.enumValues,
        },
  AiArgType.integer => {'type': 'integer'},
  AiArgType.boolean => {'type': 'boolean'},
  AiArgType.object => _objectSchema(_nestedProperties(spec)),
  AiArgType.integerList => {'type': 'array', 'items': {'type': 'integer'}},
  AiArgType.stringList => {'type': 'array', 'items': {'type': 'string'}},
  AiArgType.edits || AiArgType.variables || AiArgType.suggestionList ||
  AiArgType.snippetActions => {
    'type': 'array', 'maxItems': 20,
    'items': _objectSchema(_nestedProperties(spec)),
  },
};
