import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ai/ai_display.dart';
import '../../core/failure.dart';
import '../../core/ai/tools/target_binding.dart' show isValidAiGroupPath;
import '../../core/ai/tools/write_coordinator.dart';
import '../../core/ai/tools/write_ledger.dart';
import '../../core/ai/tools/write_preview.dart'
    show
        AiCancelAutoMergePreview,
        AiDeletePreview,
        AiDiffPreview,
        AiDraftPublishPreview,
        AiFieldsPreview,
        AiMergePreview,
        AiPipelinePreview,
        AiWritePreview;
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

/// The group work item a group alias writes to, read back from the release
/// name its port builds, `<group full path>#<iid>` (breakdown §3.1). Null for
/// every other write, and for a name without that exact shape (one the
/// redaction changed, say): the caller then shows the name as it is.
({String path, int iid})? aiGroupWriteTarget(
  String operationId,
  String releaseName,
) {
  if (productionAiLedger.find(operationId)?.scopeClass !=
      AiScopeClass.groupWorkItem) {
    return null;
  }
  // A group path never holds `#`, so the last one starts the number.
  final hash = releaseName.lastIndexOf('#');
  if (hash < 1) return null;
  final path = releaseName.substring(0, hash);
  final number = releaseName.substring(hash + 1);
  final iid = int.tryParse(number);
  if (iid == null || iid < 1 || '$iid' != number) return null;
  if (!isValidAiGroupPath(path)) return null;
  return (path: path, iid: iid);
}

/// A write's target as the card, its row and the change log show it. A
/// group work item shows its group path and `#iid` as two isolated values,
/// so `team/sub` and `#5` each keep their direction in Arabic; anything else
/// is one isolated value.
String aiWriteTargetText(String operationId, String releaseName) =>
    switch (aiGroupWriteTarget(operationId, releaseName)) {
      (:final path, :final iid) => '${isolated(path)} ${isolated('#$iid')}',
      null => isolated(releaseName),
    };

/// The account a to-do snooze changes, without its `@`: the release name the
/// snooze port builds is `@username` (breakdown §3.1). Null for any other
/// write or name.
String? aiOwnTodoUsername(String operationId, String releaseName) =>
    (operationId == 'snoozeTodo' || operationId == 'unsnoozeTodo') &&
        releaseName.length > 1 &&
        releaseName.startsWith('@') &&
        !releaseName.contains(RegExp(r'\s'))
    ? releaseName.substring(1)
    : null;

/// Deleting a comment is limited to the account's own comments, in a
/// project and in a group work item alike (§3, note delete).
bool _deletesOwnNote(String operationId) =>
    operationId == 'deleteWorkItemActivityNote' ||
    operationId == 'deleteGroupWorkItemActivityNote';

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
  'applySuggestion' => l10n.aiOpApplySuggestion,
  'batchApplySuggestions' => l10n.aiOpBatchApplySuggestions,
  'approveMergeRequest' => l10n.aiOpApproveMergeRequest,
  'cancelAutoMerge' => l10n.aiOpCancelAutoMerge,
  'mergeRequest' => l10n.aiOpMergeRequest,
  'rebaseMergeRequest' => l10n.aiOpRebaseMergeRequest,
  'createBranch' => l10n.aiOpCreateBranch,
  'deleteBranch' => l10n.aiOpDeleteBranch,
  'createTag' => l10n.aiOpCreateTag,
  'deleteTag' => l10n.aiOpDeleteTag,
  'createRelease' => l10n.aiOpCreateRelease,
  'updateRelease' => l10n.aiOpUpdateRelease,
  'deleteRelease' => l10n.aiOpDeleteRelease,
  'createFile' => l10n.aiOpCreateFile,
  'edit_file' => l10n.aiOpEditFile,
  'deleteFile' => l10n.aiOpDeleteFile,
  'createPipeline' => l10n.aiOpCreatePipeline,
  'pipelineAction' => l10n.aiOpPipelineAction,
  'deletePipeline' => l10n.aiOpDeletePipeline,
  'jobAction' => l10n.aiOpJobAction,
  'playPipelineSchedule' => l10n.aiOpPlayPipelineSchedule,
  'createProject' => l10n.aiOpCreateProject,
  'editProject' => l10n.aiOpEditProject,
  'deleteProject' => l10n.aiOpDeleteProject,
  'forkProject' => l10n.aiOpForkProject,
  'deleteBoard' => l10n.aiOpDeleteBoard,
  'deleteBoardList' => l10n.aiOpDeleteBoardList,
  'deleteContainerRepository' => l10n.aiOpDeleteContainerRepository,
  'deleteContainerTag' => l10n.aiOpDeleteContainerTag,
  'deleteNote' => l10n.aiOpDeleteNote,
  'deleteDiscussionNote' => l10n.aiOpDeleteDiscussionNote,
  'deleteDraftNote' => l10n.aiOpDeleteDraftNote,
  'deleteIssue' => l10n.aiOpDeleteIssue,
  'deleteMergeRequest' => l10n.aiOpDeleteMergeRequest,
  'deleteLabel' => l10n.aiOpDeleteLabel,
  'deleteMilestone' => l10n.aiOpDeleteMilestone,
  'deletePackage' => l10n.aiOpDeletePackage,
  'deletePackageFile' => l10n.aiOpDeletePackageFile,
  'markAllTodosDone' => l10n.aiOpMarkAllTodosDone,
  'publishDraftNotes' => l10n.aiOpPublishDraftNotes,
  'createSnippet' => l10n.aiOpCreateSnippet,
  'updateSnippet' => l10n.aiOpUpdateSnippet,
  'updateSnippetMetadata' => l10n.aiOpUpdateSnippetMetadata,
  'updateSnippetFiles' => l10n.aiOpUpdateSnippetFiles,
  'deleteSnippetFile' => l10n.aiOpDeleteSnippetFile,
  'deleteSnippet' => l10n.aiOpDeleteSnippet,
  // MR6b-3 GraphQL writes. The note rows reuse the REST note wording: to the
  // user a work item comment is a comment; only the delete names its
  // own-note limit, because that limit is the row's whole safety story.
  'createWorkItemActivityComment' => l10n.aiOpCreateNote,
  'createWorkItemActivityReply' => l10n.aiOpCreateDiscussionNote,
  'deleteWorkItemActivityNote' => l10n.aiOpDeleteOwnComment,
  'editWorkItemActivityNote' => l10n.aiOpUpdateNote,
  'updateWorkItemContent' => l10n.editWorkItem,
  'updateWorkItemLabels' => l10n.aiOpSetWorkItemLabels,
  'updateWorkItemAssignees' => l10n.aiOpSetWorkItemAssignees,
  'updateWorkItemDates' => l10n.aiOpSetWorkItemDates,
  'updateWorkItemHealthStatus' => l10n.aiOpSetHealthStatus,
  'updateWorkItemMilestone' => l10n.aiOpSetMilestone,
  'updateWorkItemWeight' => l10n.aiOpSetWeight,
  'updateWorkItemState' => l10n.aiOpSetWorkItemState,
  'updateWorkItemStatus' => l10n.aiOpSetStatus,
  'setIncidentStatus' => l10n.aiOpSetIncidentStatus,
  'setWorkItemNotifications' => l10n.aiOpSetNotifications,
  'setWorkItemActivityNoteReaction' => l10n.aiOpSetCommentReaction,
  'snoozeTodo' => l10n.aiOpSnoozeTodo,
  'unsnoozeTodo' => l10n.aiOpUnsnoozeTodo,
  // MR6b-3g group work-item aliases: the same actions on a work item a
  // group owns. A label that names the work item names the group's; one
  // that names only the action keeps the project row's words. snoozeTodo
  // and unsnoozeTodo keep their own ids; setIncidentStatus has no alias.
  'updateGroupWorkItemContent' => l10n.aiOpEditGroupWorkItem,
  'updateGroupWorkItemState' => l10n.aiOpSetGroupWorkItemState,
  'updateGroupWorkItemAssignees' => l10n.aiOpSetGroupWorkItemAssignees,
  'updateGroupWorkItemDates' => l10n.aiOpSetGroupWorkItemDates,
  'createGroupWorkItemActivityComment' => l10n.aiOpCreateNote,
  'createGroupWorkItemActivityReply' => l10n.aiOpCreateDiscussionNote,
  'deleteGroupWorkItemActivityNote' => l10n.aiOpDeleteOwnComment,
  'editGroupWorkItemActivityNote' => l10n.aiOpUpdateNote,
  'updateGroupWorkItemLabels' => l10n.aiOpSetWorkItemLabels,
  'updateGroupWorkItemHealthStatus' => l10n.aiOpSetHealthStatus,
  'updateGroupWorkItemMilestone' => l10n.aiOpSetMilestone,
  'updateGroupWorkItemWeight' => l10n.aiOpSetWeight,
  'updateGroupWorkItemStatus' => l10n.aiOpSetStatus,
  'setGroupWorkItemNotifications' => l10n.aiOpSetNotifications,
  'setGroupWorkItemActivityNoteReaction' => l10n.aiOpSetCommentReaction,
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
    'setWorkItemActivityNoteReaction' ||
    'setGroupWorkItemActivityNoteReaction' => switch (flag('add')) {
      true => l10n.aiOpAddAwardEmoji,
      false => l10n.aiOpRemoveAwardEmoji,
      null => aiOperationLabel(proposal.operationId),
    },
    'setWorkItemNotifications' ||
    'setGroupWorkItemNotifications' => switch (flag('enabled')) {
      true => l10n.aiOpSubscribeOn,
      false => l10n.aiOpSubscribeOff,
      null => aiOperationLabel(proposal.operationId),
    },
    'updateWorkItemState' => switch (fields['stateEvent']) {
      'close' => l10n.closeWorkItem,
      'reopen' => l10n.aiOpReopenWorkItem,
      _ => aiOperationLabel(proposal.operationId),
    },
    'updateGroupWorkItemState' => switch (fields['stateEvent']) {
      'close' => l10n.aiOpCloseGroupWorkItem,
      'reopen' => l10n.aiOpReopenGroupWorkItem,
      _ => aiOperationLabel(proposal.operationId),
    },
    'setMilestoneState' => switch (fields['stateEvent']) {
      'close' => l10n.closeMilestone,
      'activate' => l10n.aiOpReopenMilestone,
      _ => aiOperationLabel(proposal.operationId),
    },
    'pipelineAction' => switch (fields['action']) {
      'retry' => l10n.aiOpRetryPipeline,
      'cancel' => l10n.aiOpCancelPipeline,
      _ => aiOperationLabel(proposal.operationId),
    },
    'jobAction' => switch (fields['action']) {
      'retry' => l10n.aiOpRetryJob,
      'cancel' => l10n.aiOpCancelJob,
      'play' => l10n.aiOpPlayJob,
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
      ('setMilestoneState', 'stateEvent') ||
      ('updateWorkItemState', 'stateEvent') ||
      ('updateGroupWorkItemState', 'stateEvent') ||
      ('setWorkItemActivityNoteReaction', 'add') ||
      ('setGroupWorkItemActivityNoteReaction', 'add') ||
      ('setWorkItemNotifications', 'enabled') ||
      ('setGroupWorkItemNotifications', 'enabled') ||
      ('pipelineAction', 'action') ||
      ('jobAction', 'action') => true,
      _ => false,
    };

/// A field's value as the card shows it: yes or no for a switch, a word for
/// a state change, the text itself otherwise.
String aiFieldValue(String key, String value) => switch ((key, value)) {
  (_, 'true') => l10n.yesLabel,
  (_, 'false') => l10n.noLabel,
  ('state_event', 'close') => l10n.closeAction,
  ('state_event', 'reopen') => l10n.reopen,
  ('stateEvent', 'close') => l10n.closeAction,
  ('stateEvent', 'reopen') => l10n.reopen,
  ('visibility', 'private') => l10n.visibilityPrivate,
  ('visibility', 'internal') => l10n.visibilityInternal,
  ('visibility', 'public') => l10n.visibilityPublic,
  ('healthStatus', 'onTrack') => l10n.healthOnTrack,
  ('healthStatus', 'needsAttention') => l10n.healthNeedsAttention,
  ('healthStatus', 'atRisk') => l10n.healthAtRisk,
  ('healthStatus', 'none') => l10n.clearHealthStatus,
  ('mode', 'manual') => l10n.manualDates,
  ('mode', 'inherited') => l10n.datesRolledUpFromHierarchy,
  ('status', 'TRIGGERED') => l10n.incidentTriggered,
  ('status', 'ACKNOWLEDGED') => l10n.incidentAcknowledged,
  ('status', 'RESOLVED') => l10n.resolvedLabel,
  // The port hands the assignee and label sets over as JSON arrays; the
  // editors show a plain list of names, each isolated so a list of Latin
  // names keeps its order in Arabic.
  ('assigneeUsernames' || 'labels', _) => _nameList(value) ?? value,
  ('variables', _) => _variableLines(value) ?? value,
  _ => value,
};

/// A JSON array of names as `a, b`, or null when [json] is not one. An empty
/// array keeps its raw form: it means "clear all", which the card must not
/// hide behind a blank line.
String? _nameList(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    final names = decoded.whereType<String>().toList();
    if (names.isEmpty || names.length != decoded.length) return null;
    return names.map(isolated).join(', ');
  } on FormatException {
    return null;
  }
}

/// Pipeline variables as `KEY = value` lines, so the user sees every value
/// the AI would send. The value was already display-redacted.
String? _variableLines(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;
  final lines = <String>[];
  for (final item in decoded) {
    if (item is! Map || item['key'] is! String) return null;
    final file = item['variable_type'] == 'file' ? ' (file)' : '';
    lines.add('${item['key']}$file = ${item['value'] ?? ''}');
  }
  return lines.join('\n');
}

/// Fields a structured preview already shows; the card does not repeat them.
bool aiFieldInPreview(AiWritePreview preview, String key) => switch (preview) {
  AiFieldsPreview() => false,
  AiMergePreview() => const {
    'squash',
    'removeSourceBranch',
    'autoMerge',
  }.contains(key),
  AiDiffPreview() => const {
    'edits',
    'content',
    'path',
    'file_path',
    'ref',
    'branch',
    'suggestions',
  }.contains(key),
  AiPipelinePreview() => key == 'ref' || key == 'action',
  AiDeletePreview() => const {
    'branch',
    'tag_name',
    'path',
    'file_path',
    'ref',
    'name',
  }.contains(key),
  AiDraftPublishPreview() || AiCancelAutoMergePreview() => true,
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
  'branch' => l10n.branchNoun,
  'ref' => l10n.aiPreviewRef,
  'tag_name' || 'tag' => l10n.aiFieldTagName,
  'commitMessage' => l10n.commitMessage,
  'message' => l10n.tagMessage,
  'content' => l10n.content,
  'path' || 'file_path' => l10n.filePath,
  'previous_path' => l10n.aiFieldPreviousPath,
  'visibility' => l10n.visibility,
  'variables' => l10n.aiFieldVariables,
  // MR6b-3 GraphQL writes: the editors' own labels for the same fields,
  // camelCase as the model arguments spell them. Identifier arguments
  // (*Id, iid) never reach the card — the target line names them.
  'assigneeUsernames' => l10n.assignee,
  'startDate' => l10n.startDate,
  'dueDate' => l10n.dueDate,
  'healthStatus' => l10n.healthStatus,
  'weight' => l10n.weight,
  'clearWeight' => l10n.aiFieldClearWeight,
  'stateEvent' => l10n.status,
  'status' => l10n.status,
  'mode' => l10n.aiFieldDateMode,
  'clearStart' => l10n.aiFieldClearStart,
  'clearDue' => l10n.aiFieldClearDue,
  'clearMilestone' => l10n.aiFieldClearMilestone,
  'milestoneTitle' => l10n.milestoneLabel,
  'targetType' => l10n.aiFieldTargetType,
  'until' => l10n.aiFieldSnoozeUntil,
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
  AiFixedConfirmReason.duplicateOfSettledWrite ||
  AiFixedConfirmReason.duplicateUpload => l10n.aiConfirmDuplicate,
  AiFixedConfirmReason.wholeFieldDropsHiddenSpans =>
    l10n.aiConfirmDropsHiddenContent,
  AiFixedConfirmReason.headMovedSincePreview => l10n.aiConfirmHeadMoved,
  AiFixedConfirmReason.confirmMarkAfterManualRelease =>
    l10n.aiConfirmAfterManualRelease,
  AiFixedConfirmReason.journalResetWindow => l10n.aiConfirmJournalReset,
  AiFixedConfirmReason.confidentialOrVisibilityMix =>
    l10n.aiConfirmConfidentialMix,
  AiFixedConfirmReason.targetUnbound => l10n.aiConfirmTargetUnbound,
  AiFixedConfirmReason.targetNamedNotMarked =>
    l10n.aiConfirmTargetNamedNotMarked,
  AiFixedConfirmReason.intentNotUnique => l10n.aiConfirmIntentNotUnique,
};

/// Codes the approve and the edit path both report with their own reason
/// instead of the generic edit messages: the proposal lapsed, its run ended,
/// or (quickAction) the text holds a slash command the card can explain.
const _proposalStateCodes = {
  'quickAction',
  'approvalExpired',
  'proposalInvalidated',
  'attachmentExpired',
  'invalidProposal',
  'accountChanged',
  'settingsChanged',
  'superseded',
  'stopped',
  'timeout',
};

/// Why GitLab or a recheck stopped an approved write, for the card. Codes
/// come from the write port and the coordinator; an unknown code is null so
/// the card falls back to "not made". A missing target is ambiguous (it may
/// be hidden from you), never "deleted".
///
/// With [operationId] a group alias gets its own words where the shared
/// sentence would mislead: a missing widget is the group work item's lack
/// of the feature, not a refusal, and an unverifiable item is one whose
/// group ownership (path, number, work item) could not be proven again.
///
/// The group dates row is the exception for `unsupported`: there the code
/// comes from the strict no-op refusal (D29; `WorkItemDatesApi` refuses a
/// request equal to the current dates because it cannot prove ownership
/// without another read), not from a missing feature, so it gets a sentence
/// that claims only what is certain: nothing was sent, the dates may already
/// match.
String? aiRefusalText(String code, {String? operationId}) {
  if (operationId != null &&
      productionAiLedger.find(operationId)?.scopeClass ==
          AiScopeClass.groupWorkItem) {
    switch (code) {
      case 'unsupported' when operationId == 'updateGroupWorkItemDates':
        return l10n.aiRefusedGroupDatesNotSent;
      case 'unsupported' || 'healthUnsupported':
        return l10n.aiRefusedGroupUnsupported;
      case 'workItemUnverifiable':
        return l10n.aiRefusedGroupUnverifiable;
    }
  }
  return _refusalText(code);
}

String? _refusalText(String code) => switch (code) {
  'quickAction' => l10n.aiRefusedQuickAction,
  // The proposal lapsed, its run ended or was replaced, or the settings or
  // account changed under it; no write was sent.
  'approvalExpired' ||
  'attachmentExpired' ||
  'invalidProposal' ||
  'accountChanged' ||
  'settingsChanged' ||
  'superseded' ||
  'stopped' ||
  'timeout' => l10n.aiProposalNotRun,
  'proposalInvalidated' => l10n.aiProposalInvalid,
  'alreadyMerged' => l10n.aiRefusedAlreadyMerged,
  'projectArchived' => l10n.aiRefusedArchived,
  'protectedBranch' => l10n.aiRefusedProtectedBranch,
  'defaultBranch' => l10n.aiRefusedDefaultBranch,
  'mergeCheckIncomplete' => l10n.aiRefusedMergeChecking,
  'targetChanged' ||
  'previewChanged' ||
  'headMoved' ||
  'draftsChanged' ||
  'fileExists' ||
  'fragmentNotFound' ||
  'fragmentNotUnique' ||
  'fragmentsOverlap' ||
  'snippetChanged' ||
  // MR6b-3: the pre-read lost a race with the live object (a fence moved,
  // the anchor note or the work item changed under the proposal).
  'anchorMismatch' ||
  'noteChanged' ||
  'assigneeConflict' ||
  'stateConflict' ||
  'datesConflict' ||
  'healthConflict' ||
  'reactionConflict' ||
  'notificationConflict' ||
  'statusStaleFence' ||
  'incidentConflict' ||
  'milestoneConflict' ||
  'weightConflict' ||
  'conflict' => l10n.aiRefusedChanged,
  'refMissing' ||
  'releaseMissing' ||
  'tagMissing' ||
  'scheduleMissing' ||
  'containerMissing' ||
  'fileMissing' ||
  'jobNotInPipeline' ||
  // MR6b-3: the todo was gone before the write could bind to it.
  'todoNotFound' ||
  'noteMissing' ||
  'invisible' => l10n.aiRefusedGone,
  'maintainerRequired' ||
  'packageNotDeletable' ||
  // MR6b-3: the account cannot do this to the work item, its notes, its
  // fields or its todos.
  'activityForbidden' ||
  'assigneeForbidden' ||
  'datesForbidden' ||
  'healthForbidden' ||
  'milestoneForbidden' ||
  'notificationForbidden' ||
  'reactionForbidden' ||
  'stateForbidden' ||
  'weightForbidden' ||
  'forbidden' => l10n.aiRefusedPermission,
  'autoMergeNotEnabled' ||
  'mergeCheckUnsupported' ||
  'autoMergeCancelError' ||
  'cancelEndpointUnavailable' ||
  'suggestionForeign' ||
  'suggestionNotAppliable' ||
  'personalNamespaceUnknown' ||
  'snippetLastFile' ||
  // MR6b-3: the instance or the work item type does not offer this field,
  // or the requested value is not one the item accepts.
  'healthUnsupported' ||
  'todoUnsupportedTarget' ||
  'incidentInvalidStatus' ||
  'statusInvalidCandidate' ||
  'assigneeInvalidSelection' ||
  'validation' ||
  'unsupported' => l10n.aiRefusedNotAllowed,
  'batchTooLarge' ||
  'binaryFile' ||
  'fileTooLarge' ||
  'invalidPath' ||
  'sensitivePath' ||
  'noEditableText' ||
  'snippetBinary' ||
  'snippetTooLarge' ||
  'snippetPathInvalid' ||
  'snippetTooManyFiles' ||
  'pipelineVariableForbidden' ||
  'pipelineVariableSecret' => l10n.aiRefusedContent,
  'scheduleParamsUnreadable' ||
  'snippetFilesUnreadable' ||
  // MR6b-3: the identities or access records a graph write must bind to
  // (the account, the work item, the todo's owner) could not be read in
  // full, so nothing was sent.
  'activityUnverifiable' ||
  'workItemUnverifiable' ||
  'todoUnverifiable' ||
  'registryUnavailable' => l10n.aiRefusedUnverifiable,
  // MR6b-3: the ports throw these both when the mutation never started
  // (a gate failed, the request errored before acceptance) and when the
  // server or the readback reports the old value, so the sentence claims
  // only what is true on every path: nothing took effect.
  'datesNotApplied' ||
  'stateNotApplied' ||
  'statusNotStarted' ||
  'assigneeRejected' ||
  'milestoneRejected' ||
  'weightRejected' ||
  'incidentRejected' => l10n.aiRefusedNotApplied,
  // MR6b-3: the model's own instruction did not name one direction.
  'intentUnclear' => l10n.aiRefusedIntentUnclear,
  // MR6b-3: the discussion rejects new activity while locked.
  'activityLocked' => l10n.aiRefusedDiscussionLocked,
  // MR6b-3: note delete is restricted to the account's own notes.
  'notOwnNote' => l10n.aiRefusedNotOwnNote,
  'labelUnknown' => l10n.aiRefusedLabelUnknown,
  // MR6b-3: the todo belongs to a different account.
  'todoForeign' => l10n.aiRefusedTodoForeign,
  // A pre-read that hit a transport limit says which, in the app's own words.
  'rateLimited' => const ApiFailure(FailureKind.rateLimited).title,
  'network' => const ApiFailure(FailureKind.network).title,
  'invalidResponse' => const ApiFailure(FailureKind.invalidResponse).title,
  _ => null,
};

/// A successful write whose code says more than "written": the three merge
/// outcomes stay distinct (breakdown §7.8), and an asynchronous delete is only
/// scheduled. Null keeps the generic status.
String? aiWriteResultText(String? code) => switch (code) {
  'merged' => l10n.aiWriteMerged,
  'autoMergeScheduled' => l10n.aiWriteAutoMergeScheduled,
  'mergeAccepted' => l10n.aiWriteMergeAccepted,
  'deletionScheduled' => l10n.aiWriteDeletionScheduled,
  _ => null,
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

/// Never shown with an old value, whatever the comparison carries: prose is
/// too long to repeat, and a set change is read from the marker alone.
const _noPreviousFields = {'description', 'labels', 'assignee_ids'};

/// An old value as the card shows it: a boolean field reads 是/否 like its
/// proposed value; anything else (an old title that is literally `false`)
/// stays as GitLab has it.
String _previousText(String key, String previous) =>
    key == 'confidential' || key == 'discussion_locked'
    ? aiFieldValue(key, previous)
    : previous;

/// The snooze deadline in the user's words. A parseable timestamp becomes a
/// local date and time; anything else shows exactly as the model sent it.
String _snoozeUntilText(BuildContext context, String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final localizations = MaterialLocalizations.of(context);
  return '${localizations.formatMediumDate(parsed.toLocal())} '
      '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(parsed.toLocal()))}';
}

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

  /// The field an edit replaces: the ledger's editable field when this
  /// write carries it, so the card never offers an edit the coordinator
  /// would refuse.
  String? get _editableField {
    final field = _proposal.editableField;
    return field != null && _proposal.fields.containsKey(field) ? field : null;
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
        // The background work could not start for this approval: nothing
        // was sent. Usually the run pauses and withdraws the proposal (the
        // chat's pause card offers Continue); if it was not running, the
        // proposal stays. The text holds in both cases.
        'executionPaused' => l10n.aiProposalBackgroundUnavailable,
        // A pause is shown once, by the card's status line, when the
        // coordinator has marked the proposal paused; a background pause is
        // never shown.
        AiWritePause.backgrounded => null,
        AiWritePause.accountRemovalHeld ||
        'accountBlocked' ||
        AiWritePause.clientUnavailable
            when _proposal.pausedReason != null =>
          null,
        AiWritePause.accountRemovalHeld ||
        'accountBlocked' => l10n.aiProposalPausedRemoval,
        AiWritePause.clientUnavailable => l10n.aiProposalPausedRateLimited,
        final code when _proposalStateCodes.contains(code) =>
          aiRefusalText(code),
        // Still waiting: the proposal is fine, only the edited text was
        // refused, so the user can change it again.
        _
            when _proposal.editedText != null &&
                widget.session.proposals.contains(_proposal) =>
          l10n.aiProposalEditRefused,
        final code =>
          aiRefusalText(code, operationId: _proposal.operationId) ??
              l10n.aiProposalNotRun,
      };
      // Not the user's error and nothing was sent.
      if (outcome.reasonCode == 'executionPaused') _messageIsError = false;
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
    // The sheet would hand focus back to the composer on close and raise
    // the keyboard over the card the user is reading. Unfocusing the node
    // itself also clears its scope's memory of it.
    FocusManager.instance.primaryFocus?.unfocus();
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
        // A pause keeps the earlier text: the edit was not applied, and the
        // card's status line already says why approval waits.
        _message = switch (outcome?.reasonCode) {
          final code? when _proposalStateCodes.contains(code) =>
            aiRefusalText(code),
          _ => l10n.aiProposalEditBlocked,
        };
        _messageIsError = true;
      }
    });
  }

  /// One proposed value: prose in a bordered box, anything else on one line.
  Widget _fieldValue(
    BuildContext context,
    String key,
    String value,
    TextStyle? style,
  ) {
    if (!_proseFields.contains(key)) {
      return Text(
        key == 'until'
            ? _snoozeUntilText(context, value)
            : aiFieldValue(key, value),
        key: ValueKey('ai-proposal-field-$key'),
        style: style,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
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
            style: style,
          ),
        ),
      ),
    );
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
    // A group work item names its owning group and number on a line of its
    // own: `team/sub#5` would otherwise read like a project path, and a
    // same-numbered item in another group must not look the same.
    final groupTarget = aiGroupWriteTarget(
      proposal.operationId,
      proposal.releaseName,
    );
    final ownTodo = aiOwnTodoUsername(
      proposal.operationId,
      proposal.releaseName,
    );
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
                        groupTarget != null
                            ? aiTierLabel(tier.tier)
                            : '${aiTierLabel(tier.tier)} · '
                                  '${aiWriteTargetText(proposal.operationId, proposal.releaseName)}',
                        style: muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (groupTarget case (:final path, :final iid)) ...[
              const SizedBox(height: 8),
              _CardLine(
                icon: Icons.workspaces_outline,
                color: scheme.primary,
                // The generated message isolates each value in Arabic.
                text: l10n.aiProposalGroupTarget(path, iid),
                textKey: const ValueKey('ai-proposal-group-target'),
              ),
            ],
            if (ownTodo != null) ...[
              const SizedBox(height: 8),
              _CardLine(
                icon: Icons.person_outline,
                color: scheme.onSurfaceVariant,
                text: l10n.aiProposalOwnTodo(ownTodo),
                textKey: const ValueKey('ai-proposal-own-todo'),
              ),
            ],
            if (_deletesOwnNote(proposal.operationId)) ...[
              const SizedBox(height: 8),
              _CardLine(
                icon: Icons.person_outline,
                color: HubColors.orange,
                text: l10n.aiProposalDeleteOwnNote,
                textKey: const ValueKey('ai-proposal-own-note'),
              ),
            ],
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
                operationId: proposal.operationId,
              ),
            ],
            for (final MapEntry(:key, :value) in proposal.fields.entries)
              if (!aiFieldInTitle(proposal.operationId, key) &&
                  !aiFieldInPreview(preview, key) &&
                  !(upload != null && _uploadFields.contains(key))) ...[
                const SizedBox(height: 8),
                // Compared with the current record (REST issue and MR
                // updates): a marker, and for short fields the value now.
                // One semantics node, so the marker is read with the field.
                if (proposal.fieldChanges[key] case final change?
                    when change.status != AiFieldChangeStatus.unknown)
                  MergeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          runSpacing: 2,
                          children: [
                            Text(
                              aiFieldLabel(key),
                              style: theme.textTheme.labelMedium,
                            ),
                            _FieldChangeMarker(
                              key: ValueKey('ai-proposal-change-$key'),
                              changed:
                                  change.status == AiFieldChangeStatus.changed,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        _fieldValue(
                          context,
                          key,
                          value,
                          change.status == AiFieldChangeStatus.changed
                              ? theme.textTheme.bodySmall
                              : muted,
                        ),
                        if (change.previous case final previous?
                            when change.status == AiFieldChangeStatus.changed &&
                                !_noPreviousFields.contains(key)) ...[
                          const SizedBox(height: 2),
                          Text(
                            l10n.aiProposalFieldPrevious(
                              isolated(_previousText(key, previous)),
                            ),
                            key: ValueKey('ai-proposal-previous-$key'),
                            style: muted,
                          ),
                        ],
                      ],
                    ),
                  )
                else ...[
                  Text(aiFieldLabel(key), style: theme.textTheme.labelMedium),
                  const SizedBox(height: 2),
                  _fieldValue(context, key, value, theme.textTheme.bodySmall),
                ],
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

/// Beside a field label: whether the write changes the field (icon and text,
/// never colour alone). The unchanged icon is two bars, read as "=".
class _FieldChangeMarker extends StatelessWidget {
  const _FieldChangeMarker({super.key, required this.changed});

  final bool changed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(theme.brightness);
    final color = changed ? palette.accent : palette.muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(changed ? Icons.edit : Icons.drag_handle, size: 14, color: color),
        const SizedBox(width: 2),
        Text(
          changed ? l10n.aiProposalFieldChanged : l10n.aiProposalFieldUnchanged,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// One icon-and-text line of a proposal card: status is never colour alone.
class _CardLine extends StatelessWidget {
  const _CardLine({
    required this.icon,
    required this.color,
    required this.text,
    required this.textKey,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Key textKey;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          key: textKey,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
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
      AiWriteOutcome(reasonCode: 'rejected' || 'userRejected') => (
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
                        '$status · '
                        '${aiWriteTargetText(proposal.operationId, proposal.releaseName)}',
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
