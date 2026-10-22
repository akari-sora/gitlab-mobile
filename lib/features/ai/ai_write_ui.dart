import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ai/ai_display.dart';
import '../../core/ai/tools/write_coordinator.dart';
import '../../core/ai/tools/write_ledger.dart';
import '../../core/ai/tools/write_preview.dart'
    show AiFieldsPreview, AiMergePreview, AiPipelinePreview;
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/theme.dart';
import '../../core/registry_models.dart' show registryBytes;
import 'ai_attachment_session.dart';
import 'ai_chat_session.dart';
import 'ai_write_journal.dart' show AiJournalState;
import 'ai_write_previews.dart';
import 'ai_write_settings.dart';

/// What a write does, in the user's words. The model sees operation ids; the
/// user never does.
/// Whether [name] is one of the app's write tools rather than a read.
bool aiIsWriteTool(String name) => productionAiLedger.find(name) != null;

String aiOperationLabel(String operationId) => switch (operationId) {
  'addAwardEmoji' => l10n.aiOpAddAwardEmoji,
  'removeAwardEmoji' => l10n.aiOpRemoveAwardEmoji,
  'setStar' => l10n.aiOpSetStar,
  'setSubscribed' => l10n.aiOpSetSubscribed,
  'markTodoDone' => l10n.aiOpMarkTodoDone,
  'createNote' => l10n.aiOpCreateNote,
  'updateNote' => l10n.aiOpUpdateNote,
  'createIssue' => l10n.aiOpCreateIssue,
  'updateIssue' => l10n.aiOpUpdateIssue,
  'createMergeRequest' => l10n.aiOpCreateMergeRequest,
  'updateMergeRequest' => l10n.aiOpUpdateMergeRequest,
  'unapproveMergeRequest' => l10n.aiOpUnapproveMergeRequest,
  'createTodo' => l10n.aiOpCreateTodo,
  'createDiscussion' => l10n.aiOpCreateDiscussion,
  'createDiscussionNote' => l10n.aiOpCreateDiscussionNote,
  'updateDiscussionNote' => l10n.aiOpUpdateDiscussionNote,
  'setDiscussionResolved' => l10n.aiOpSetDiscussionResolved,
  'createDraftNote' => l10n.aiOpCreateDraftNote,
  'updateDraftNote' => l10n.aiOpUpdateDraftNote,
  'createLabel' => l10n.aiOpCreateLabel,
  'updateLabel' => l10n.aiOpUpdateLabel,
  'createMilestone' => l10n.aiOpCreateMilestone,
  'updateMilestone' => l10n.aiOpUpdateMilestone,
  'setMilestoneState' => l10n.aiOpSetMilestoneState,
  'createBoard' => l10n.aiOpCreateBoard,
  'renameBoard' => l10n.aiOpRenameBoard,
  'setBoardSystemListHidden' => l10n.aiOpSetBoardSystemListHidden,
  'createBoardList' => l10n.aiOpCreateBoardList,
  'moveBoardList' => l10n.aiOpMoveBoardList,
  'moveBoardCard' => l10n.aiOpMoveBoardCard,
  'upload_attachment' => l10n.aiOpUploadAttachment,
  _ => l10n.aiOpUnknown,
};

/// The card's title: a two-way operation names the direction it goes, so
/// "star or unstar" never leaves the user reading `starred: true`.
String aiProposalTitle(AiWriteProposal proposal) {
  final fields = proposal.fields;
  bool? flag(String key) => switch (fields[key]) {
    'true' => true,
    'false' => false,
    _ => null,
  };
  return switch (proposal.operationId) {
    'setStar' => switch (flag('starred')) {
      true => l10n.star,
      false => l10n.unstar,
      null => aiOperationLabel(proposal.operationId),
    },
    'setSubscribed' => switch (flag('subscribed')) {
      true => l10n.aiOpSubscribeOn,
      false => l10n.aiOpSubscribeOff,
      null => aiOperationLabel(proposal.operationId),
    },
    'setDiscussionResolved' => switch (flag('resolved')) {
      true => l10n.aiOpResolveThread,
      false => l10n.aiOpReopenThread,
      null => aiOperationLabel(proposal.operationId),
    },
    'setBoardSystemListHidden' => switch (flag('hidden')) {
      true => l10n.aiOpHideBoardList,
      false => l10n.aiOpShowBoardList,
      null => aiOperationLabel(proposal.operationId),
    },
    'setMilestoneState' => switch (fields['stateEvent']) {
      'close' => l10n.closeMilestone,
      'activate' => l10n.aiOpReopenMilestone,
      _ => aiOperationLabel(proposal.operationId),
    },
    _ => aiOperationLabel(proposal.operationId),
  };
}

/// Fields the title already states; the card does not repeat them.
bool aiFieldInTitle(String operationId, String key) =>
    switch ((operationId, key)) {
      ('setStar', 'starred') ||
      ('setSubscribed', 'subscribed') ||
      ('setDiscussionResolved', 'resolved') ||
      ('setBoardSystemListHidden', 'hidden') ||
      ('setMilestoneState', 'stateEvent') => true,
      _ => false,
    };

/// A field's value as the card shows it: yes or no for a switch, a word for
/// a state change, the text itself otherwise.
String aiFieldValue(String key, String value) => switch ((key, value)) {
  (_, 'true') => l10n.yesLabel,
  (_, 'false') => l10n.noLabel,
  ('state_event', 'close') => l10n.closeAction,
  ('state_event', 'reopen') => l10n.reopen,
  _ => value,
};

/// Field names on the approval card, reusing the editors' own labels.
String aiFieldLabel(String key) => switch (key) {
  'body' => l10n.commentBody,
  'title' => l10n.title,
  'description' => l10n.descriptionLabel,
  'labels' => l10n.labelNoun,
  'assignee_ids' => l10n.assignee,
  'reviewer_ids' => l10n.reviewers,
  'milestone_id' => l10n.milestoneLabel,
  'confidential' => l10n.confidentialIssue,
  'severity' => l10n.severity,
  'source_branch' => l10n.sourceBranch,
  'target_branch' => l10n.targetBranch,
  'due_date' => l10n.dueDate,
  'start_date' => l10n.startDate,
  'name' => l10n.nameLabel,
  'color' => l10n.color,
  'state_event' => l10n.status,
  'issue_type' => l10n.workItemTypeFilter,
  'filename' => l10n.fileName,
  'contentType' => l10n.aiFieldFileType,
  'list' => l10n.aiFieldBoardList,
  _ => key,
};

/// Why a write that could have run on its own waits for the user.
String aiConfirmReasonText(AiFixedConfirmReason reason) => switch (reason) {
  AiFixedConfirmReason.markAllTodosDone => l10n.aiConfirmMarkAllTodosDone,
  AiFixedConfirmReason.foreignDraftsInPublish =>
    l10n.aiConfirmForeignDraftsInPublish,
  AiFixedConfirmReason.massMention => l10n.aiConfirmMassMention,
  AiFixedConfirmReason.externalMediaInRenderedMarkdown =>
    l10n.aiConfirmExternalMedia,
  AiFixedConfirmReason.foreignClosingOrCrossProject =>
    l10n.aiConfirmClosingOrCrossProject,
  AiFixedConfirmReason.duplicateOfSettledWrite => l10n.aiConfirmDuplicate,
  AiFixedConfirmReason.wholeFieldDropsHiddenSpans =>
    l10n.aiConfirmDropsHiddenContent,
  AiFixedConfirmReason.headMovedSincePreview => l10n.aiConfirmHeadMoved,
  AiFixedConfirmReason.confirmMarkAfterManualRelease =>
    l10n.aiConfirmAfterManualRelease,
  AiFixedConfirmReason.journalResetWindow => l10n.aiConfirmJournalReset,
  AiFixedConfirmReason.confidentialOrVisibilityMix =>
    l10n.aiConfirmConfidentialMix,
  AiFixedConfirmReason.targetUnbound => l10n.aiConfirmTargetUnbound,
  AiFixedConfirmReason.intentNotUnique => l10n.aiConfirmIntentNotUnique,
};

String aiTierLabel(AiWriteTier tier) => switch (tier) {
  AiWriteTier.t1 => l10n.aiTierLow,
  AiWriteTier.t2 => l10n.aiTierNormal,
  AiWriteTier.t3 => l10n.aiTierMajor,
  AiWriteTier.t4 || AiWriteTier.hardLine => l10n.aiTierHigh,
};

/// How a finished write went, for the tool row in the conversation.
String aiWriteStatusLabel(AiWriteResultStatus status) => switch (status) {
  AiWriteResultStatus.notExecuted => l10n.aiWriteStatusNotExecuted,
  AiWriteResultStatus.succeeded => l10n.aiWriteStatusSucceeded,
  AiWriteResultStatus.readbackConfirmed => l10n.aiWriteStatusConfirmed,
  AiWriteResultStatus.failedCertain => l10n.aiWriteStatusFailed,
  AiWriteResultStatus.writeUncertain => l10n.aiWriteStatusUncertain,
  AiWriteResultStatus.resolvedByUser => l10n.aiWriteStatusResolvedByUser,
  AiWriteResultStatus.noChange => l10n.aiWriteStatusNoChange,
};

(IconData, Color) _tierStyle(AiWriteTier tier, ColorScheme scheme) =>
    switch (tier) {
      AiWriteTier.t1 => (Icons.bolt_outlined, HubColors.green),
      AiWriteTier.t2 => (Icons.edit_outlined, scheme.primary),
      AiWriteTier.t3 => (Icons.warning_amber_rounded, HubColors.orange),
      AiWriteTier.t4 ||
      AiWriteTier.hardLine => (Icons.dangerous_outlined, scheme.error),
    };

// Fields that hold prose, shown in a box with their line breaks.
const _proseFields = {'body', 'description', 'note'};

/// One write the AI asks to make, with everything it would send. Nothing is
/// written until the user approves; editing the text asks again.
class AiWriteProposalCard extends StatefulWidget {
  const AiWriteProposalCard({
    super.key,
    required this.proposal,
    required this.session,
  });

  final AiWriteProposal proposal;
  final AiWriteChatSession session;

  @override
  State<AiWriteProposalCard> createState() => _AiWriteProposalCardState();
}

class _AiWriteProposalCardState extends State<AiWriteProposalCard> {
  final _typed = TextEditingController();
  var _busy = false;
  String? _message;
  var _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _typed.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  AiWriteProposal get _proposal => widget.proposal;

  /// The field an edit replaces, as the coordinator picks it: the body, or
  /// the single title, description or name among the fields.
  String? get _editableField {
    final fields = _proposal.fields;
    // A reaction's name is an emoji code, not text to rewrite.
    if (_proposal.operationId.endsWith('AwardEmoji')) return null;
    if (fields.containsKey('body')) return 'body';
    final candidates = [
      for (final key in const ['description', 'title', 'name'])
        if (fields.containsKey(key)) key,
    ];
    return candidates.length == 1 ? candidates.single : null;
  }

  bool get _nameTyped {
    final tier = _proposal.tier;
    if (!tier.requiresTypedName) return true;
    final name = tier.typedName;
    // Direction marks copied from an Arabic interface do not count.
    return name != null &&
        attachmentReleaseNamesMatch(_typed.text.trim(), name);
  }

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final AiWriteOutcome outcome;
    try {
      outcome = await widget.session.approveWrite(
        _proposal,
        // The stored name once it matches, so the exact check downstream
        // never sees the marks.
        typedName: _proposal.tier.requiresTypedName && _nameTyped
            ? _proposal.tier.typedName
            : _proposal.tier.requiresTypedName
            ? _typed.text.trim()
            : null,
      );
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = l10n.aiProposalNotRun;
          _messageIsError = true;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (outcome.successful) return;
      _messageIsError = true;
      _message = switch (outcome.reasonCode) {
        'typedNameMismatch' => l10n.aiProposalNameMismatch,
        'tooManyRunning' => l10n.aiProposalTooManyRunning,
        AiWritePause.accountRemovalHeld ||
        'accountBlocked' => l10n.aiProposalPausedRemoval,
        AiWritePause.clientUnavailable => l10n.aiProposalPausedRateLimited,
        // Still waiting: the proposal is fine, only the edited text was
        // refused, so the user can change it again.
        _
            when _proposal.editedText != null &&
                widget.session.proposals.contains(_proposal) =>
          l10n.aiProposalEditRefused,
        _ => l10n.aiProposalNotRun,
      };
    });
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      await widget.session.rejectWrite(_proposal);
    } on Object {
      // Rejecting only drops the proposal; a failure leaves it on the card.
      if (mounted) {
        setState(() {
          _message = l10n.aiProposalNotRun;
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(String field) async {
    final edited = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _EditSheet(
        title: aiFieldLabel(field),
        initial: _proposal.editedText ?? _proposal.fields[field] ?? '',
      ),
    );
    if (edited == null || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    AiWriteOutcome? outcome;
    try {
      outcome = await widget.session.approveWrite(
        _proposal,
        editedText: edited,
      );
    } on Object {
      outcome = null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      // An accepted edit comes back as "approve again"; the card now shows
      // the new text and the tier it was checked at.
      if (outcome?.reasonCode == 'approvalRequired') {
        _message = l10n.aiProposalEdited;
        _messageIsError = false;
      } else {
        _message = l10n.aiProposalEditBlocked;
        _messageIsError = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final proposal = _proposal;
    final tier = proposal.tier;
    final (tierIcon, tierColor) = _tierStyle(tier.tier, scheme);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final valid = proposal.valid;
    final upload = proposal.upload;
    // Held by an account removal or a GitLab rate limit: still valid, but
    // approve waits until the hold ends.
    final paused = switch (proposal.pausedReason) {
      null || AiWritePause.backgrounded => null,
      AiWritePause.accountRemovalHeld => l10n.aiProposalPausedRemoval,
      _ => l10n.aiProposalPausedRateLimited,
    };
    final editable = _editableField;
    final preview = proposal.preview;
    // A structured preview already shows the squash option, the stored
    // variables and the issues a merge closes; the card does not repeat them.
    final warnings = [
      for (final reason in tier.reasons) aiConfirmReasonText(reason),
      if (tier.reusesStoredVariables && preview is! AiPipelinePreview)
        l10n.aiProposalStoredVariables,
      if (tier.showSquash && preview is! AiMergePreview) l10n.aiProposalSquash,
      if (tier.cancelMayRunAfterScript) l10n.aiProposalCancelMayRun,
    ];
    final until = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(proposal.expiresAt.toLocal()));
    return DecoratedBox(
      key: ValueKey('ai-proposal-${proposal.executionId}'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(tierIcon, color: tierColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        aiProposalTitle(proposal),
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        '${aiTierLabel(tier.tier)} · '
                        '${isolated(proposal.releaseName)}',
                        style: muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (proposal.modelReason.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                l10n.aiProposalReason(proposal.modelReason.trim()),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (upload != null) ...[
              const SizedBox(height: 8),
              _UploadPreview(
                upload: upload,
                file: widget.session.attachments
                    .where((file) => file.id == upload.attachmentId)
                    .firstOrNull,
              ),
            ],
            if (preview is! AiFieldsPreview) ...[
              const SizedBox(height: 8),
              AiWritePreviewView(
                preview: preview,
                storedVariables: tier.reusesStoredVariables,
              ),
            ],
            for (final MapEntry(:key, :value) in proposal.fields.entries)
              if (!aiFieldInTitle(proposal.operationId, key) &&
                  !(upload != null && _uploadFields.contains(key))) ...[
                const SizedBox(height: 8),
                Text(aiFieldLabel(key), style: theme.textTheme.labelMedium),
                const SizedBox(height: 2),
                if (_proseFields.contains(key))
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          value,
                          key: ValueKey('ai-proposal-field-$key'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                  )
                else
                  Text(
                    aiFieldValue(key, value),
                    key: ValueKey('ai-proposal-field-$key'),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            if (proposal.closingRefs.isNotEmpty &&
                preview is! AiMergePreview) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.task_alt, size: 16, color: HubColors.orange),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.aiProposalClosesOnMerge(
                        proposal.closingRefs.map(isolated).join(', '),
                      ),
                      key: const ValueKey('ai-proposal-closes'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            for (final warning in warnings) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 16,
                    color: HubColors.orange,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(warning, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ],
            if (valid && tier.requiresTypedName) ...[
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('ai-proposal-typed-name'),
                controller: _typed,
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: l10n.aiProposalTypeName(tier.typedName ?? ''),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              !valid
                  ? l10n.aiProposalInvalid
                  : paused ?? l10n.aiProposalValidUntil(until),
              key: const ValueKey('ai-proposal-status'),
              style: !valid
                  ? muted?.copyWith(color: scheme.error)
                  : paused != null
                  ? muted?.copyWith(color: HubColors.orange)
                  : muted,
            ),
            if (_message case final message?) ...[
              const SizedBox(height: 4),
              Text(
                message,
                key: const ValueKey('ai-proposal-message'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _messageIsError ? scheme.error : null,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 4,
              children: [
                TextButton(
                  key: const ValueKey('ai-proposal-reject'),
                  onPressed: _busy || !valid ? null : _reject,
                  child: Text(l10n.aiProposalReject),
                ),
                if (editable != null)
                  TextButton.icon(
                    key: const ValueKey('ai-proposal-edit'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: _busy || !valid ? null : () => _edit(editable),
                    label: Text(l10n.aiProposalEdit),
                  ),
                FilledButton.icon(
                  key: const ValueKey('ai-proposal-approve'),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check, size: 18),
                  onPressed: _busy || !valid || paused != null || !_nameTyped
                      ? null
                      : _approve,
                  label: Text(l10n.aiProposalApprove),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A card whose text the user edited, kept until a readback confirms the
/// write (§7.2): rejected, failed, unknown, expired, or written without a
/// readback. The status says which; the edit can be copied, so the user's
/// work is not lost; dismissing it drops it.
class AiSettledEditCard extends StatelessWidget {
  const AiSettledEditCard({
    super.key,
    required this.proposal,
    required this.onDismiss,
  });

  final AiWriteProposal proposal;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = proposal.editedText ?? '';
    final outcome = proposal.outcome;
    // A write that ran but was not read back is kept too (§7.2 clears only
    // after readback); it must never read as "not made".
    final (status, explanation) = switch (outcome) {
      AiWriteOutcome(reasonCode: 'rejected') => (
        l10n.aiSettledEditRejected,
        l10n.aiSettledEditKept,
      ),
      AiWriteOutcome(state: AiJournalState.succeeded, noChange: true) => (
        l10n.aiWriteStatusNoChange,
        l10n.aiSettledEditWritten,
      ),
      AiWriteOutcome(state: AiJournalState.succeeded) => (
        l10n.aiWriteStatusSucceeded,
        l10n.aiSettledEditWritten,
      ),
      AiWriteOutcome(state: AiJournalState.writeUncertain) => (
        l10n.aiWriteStatusUncertain,
        l10n.aiSettledEditUncertain,
      ),
      AiWriteOutcome(state: AiJournalState.failedCertain) => (
        l10n.aiWriteStatusFailed,
        l10n.aiSettledEditKept,
      ),
      _ => (l10n.aiWriteStatusNotExecuted, l10n.aiSettledEditKept),
    };
    return DecoratedBox(
      key: ValueKey('ai-settled-edit-${proposal.executionId}'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.edit_note, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        aiProposalTitle(proposal),
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        '$status · ${isolated(proposal.releaseName)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('ai-settled-edit-dismiss'),
                  tooltip: l10n.closeAction,
                  visualDensity: VisualDensity.compact,
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8, top: 4),
              child: Text(
                explanation,
                key: const ValueKey('ai-settled-edit-explanation'),
                style: theme.textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8, top: 6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: SizedBox(
                    width: double.infinity,
                    child: SelectableText(
                      text,
                      key: const ValueKey('ai-settled-edit-text'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const ValueKey('ai-settled-edit-copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.maybeOf(
                    context,
                  )?.showSnackBar(SnackBar(content: Text(l10n.aiChatCopied)));
                },
                icon: const Icon(Icons.copy, size: 18),
                label: Text(l10n.aiSettledEditCopy),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fields the upload preview already shows.
const _uploadFields = {'filename', 'contentType'};

/// What an upload card sends where (§3.1): the file with a local thumbnail,
/// its size and type, the target project and its visibility. A public,
/// internal or unknown visibility carries the warning that anyone who sees
/// content citing the file can fetch it.
class _UploadPreview extends StatelessWidget {
  const _UploadPreview({required this.upload, required this.file});

  final AiUploadPreview upload;

  /// The held file, for the thumbnail; null once it was removed.
  final AiStoredAttachment? file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final type = upload.contentType ?? file?.mediaType;
    final image = type?.startsWith('image/') ?? false;
    final bytes = file?.bytes;
    final visibility = switch (upload.projectVisibility) {
      'public' => l10n.visibilityPublic,
      'internal' => l10n.visibilityInternal,
      'private' => l10n.visibilityPrivate,
      _ => l10n.aiUploadVisibilityUnknown,
    };
    final project = upload.projectPath ?? '${upload.projectId}';
    return Column(
      key: const ValueKey('ai-proposal-upload'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox.square(
                dimension: 48,
                child: image && bytes != null
                    ? Image.memory(
                        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
                        cacheWidth: 144,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.broken_image_outlined,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    : ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.insert_drive_file_outlined,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isolated(upload.filename),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    [
                      registryBytes(upload.sizeBytes),
                      if (type != null) isolated(type),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    l10n.aiUploadTarget(isolated(project), visibility),
                    key: const ValueKey('ai-proposal-upload-target'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (upload.readersCanFetch) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.public, size: 16, color: HubColors.orange),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.aiUploadReadersCanFetch,
                  key: const ValueKey('ai-proposal-upload-warning'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + media.viewInsets.bottom + media.padding.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.aiProposalEditTitle(widget.title),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('ai-proposal-edit-text'),
              controller: _text,
              autofocus: true,
              minLines: 3,
              maxLines: 10,
              style: codeTextStyle(context, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelAction),
                ),
                FilledButton(
                  key: const ValueKey('ai-proposal-edit-done'),
                  onPressed: () => Navigator.of(context).pop(_text.text),
                  child: Text(l10n.aiProposalEditDone),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The conversation's write level in the chat's app bar. Tapping it picks
/// any level up to the conversation's ceiling.
class AiChatLevelButton extends StatelessWidget {
  const AiChatLevelButton({
    super.key,
    required this.session,
    this.enabled = true,
  });

  final AiChatSession session;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final level = session.autonomyLevel;
    final ceiling = session.autonomyCeiling;
    final (icon, color) = switch (level) {
      AiAutonomyLevel.readOnly => (Icons.visibility_outlined, null),
      AiAutonomyLevel.confirmEach => (Icons.front_hand_outlined, null),
      AiAutonomyLevel.lowRiskAuto => (Icons.bolt_outlined, null),
      AiAutonomyLevel.conversationGrant => (
        Icons.lock_open_outlined,
        HubColors.orange,
      ),
      AiAutonomyLevel.bypass => (
        Icons.warning_amber_rounded,
        Theme.of(context).colorScheme.error,
      ),
    };
    return IconButton(
      key: const ValueKey('ai-chat-level'),
      tooltip: l10n.aiChatLevelTooltip(aiLevelLabel(level)),
      icon: Icon(icon, color: color),
      onPressed: !enabled || ceiling == AiAutonomyLevel.readOnly
          ? null
          : () async {
              final picked = await showAiLevelPicker(
                context,
                title: l10n.aiChatLevelTitle,
                current: level,
                options: [
                  for (final option in AiAutonomyLevel.values)
                    if (option.index <= ceiling.index) option,
                ],
              );
              if (picked != null && picked != level) {
                await session.setAutonomyLevel(picked);
              }
            },
    );
  }
}

/// Shown at the top of the conversation while the AI writes without asking
/// (this-conversation grant or allow everything, plan v6 §4.2). Stop ends the
/// run and drops the conversation to confirm-each, so nothing more happens on
/// its own; the level button raises it again.
class AiAutoWriteBanner extends StatelessWidget {
  const AiAutoWriteBanner({
    super.key,
    required this.level,
    required this.onStop,
  });

  final AiAutonomyLevel level;
  final VoidCallback? onStop;

  static bool shows(AiAutonomyLevel level) =>
      level == AiAutonomyLevel.conversationGrant ||
      level == AiAutonomyLevel.bypass;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bypass = level == AiAutonomyLevel.bypass;
    final accent = bypass ? scheme.error : HubColors.orange;
    return Material(
      key: const ValueKey('ai-auto-write-banner'),
      color: Color.alphaBlend(accent.withValues(alpha: 0.12), scheme.surface),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 4),
        child: Row(
          children: [
            Icon(
              bypass ? Icons.warning_amber_rounded : Icons.lock_open_outlined,
              color: accent,
              size: 20,
            ),
            const SizedBox(width: 12),
            // Three lines at most, so large text never pushes the composer
            // off a short screen; the full sentence stays in semantics.
            Expanded(
              child: Semantics(
                label: l10n.aiAutoWriteBanner(aiLevelLabel(level)),
                excludeSemantics: true,
                child: Text(
                  l10n.aiAutoWriteBanner(aiLevelLabel(level)),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Tooltip(
                message: l10n.aiAutoWriteStopHint,
                child: TextButton.icon(
                  key: const ValueKey('ai-auto-write-stop'),
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: Text(
                    l10n.aiChatStop,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Why a file was not attached, or null when there is nothing to say.
String? aiAttachFailureText(AiAttachStatus status) => switch (status) {
  AiAttachStatus.stored || AiAttachStatus.cancelled => null,
  AiAttachStatus.disabled => l10n.aiAttachDisabled,
  AiAttachStatus.capacity => l10n.aiAttachCapacity,
  AiAttachStatus.tooLarge => l10n.aiAttachTooLarge,
  AiAttachStatus.readFailed => l10n.aiAttachReadFailed,
  AiAttachStatus.invalidName => l10n.aiAttachInvalidName,
  AiAttachStatus.expired => l10n.aiAttachExpired,
};

/// The files held for this conversation, above the composer. They stay on
/// the device; images show a local thumbnail.
class AiAttachmentStrip extends StatelessWidget {
  const AiAttachmentStrip({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  final List<AiStoredAttachment> attachments;
  final ValueChanged<String>? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final attachment in attachments)
            InputChip(
              key: ValueKey('ai-attachment-${attachment.id}'),
              visualDensity: VisualDensity.compact,
              avatar: _thumbnail(attachment, theme),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  '${isolated(attachment.filename)} · '
                  '${registryBytes(attachment.size)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              deleteButtonTooltipMessage: l10n.aiAttachmentRemove,
              onDeleted: onRemove == null
                  ? null
                  : () => onRemove!(attachment.id),
            ),
        ],
      ),
    );
  }

  Widget _thumbnail(AiStoredAttachment attachment, ThemeData theme) {
    final image = attachment.mediaType?.startsWith('image/') ?? false;
    if (!image) {
      return Icon(
        Icons.insert_drive_file_outlined,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }
    // The held bytes themselves, not a copy: the same buffer keeps the same
    // image cache entry across rebuilds.
    final bytes = attachment.bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.memory(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        width: 24,
        height: 24,
        cacheWidth: 72,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // A file that claims to be an image but does not decode.
        errorBuilder: (_, _, _) => Icon(
          Icons.broken_image_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
