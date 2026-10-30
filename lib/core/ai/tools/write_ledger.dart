import 'package:flutter/foundation.dart';

import '../../group_work_item_identity.dart';
import '../../instance.dart';
import 'release_policy.dart';
import 'target_binding.dart' show AiTargetKind;
import 'write_levels.dart';

export 'write_levels.dart';

part 'ledger/rows_ci.dart';
part 'ledger/rows_deletes.dart';
part 'ledger/rows_files.dart';
part 'ledger/rows_graphql_activity_create.dart';
part 'ledger/rows_graphql_activity_delete.dart';
part 'ledger/rows_graphql_activity_edit.dart';
part 'ledger/rows_graphql_content.dart';
part 'ledger/rows_graphql_labels.dart';
part 'ledger/rows_graphql_assignees.dart';
part 'ledger/rows_graphql_dates.dart';
part 'ledger/rows_graphql_health.dart';
part 'ledger/rows_graphql_incident.dart';
part 'ledger/rows_graphql_milestone.dart';
part 'ledger/rows_graphql_notifications.dart';
part 'ledger/rows_graphql_reaction.dart';
part 'ledger/rows_graphql_snooze.dart';
part 'ledger/rows_graphql_state.dart';
part 'ledger/rows_graphql_status.dart';
part 'ledger/rows_graphql_weight.dart';
part 'ledger/rows_group_state.dart';
part 'ledger/rows_group_status.dart';
part 'ledger/rows_group_dates.dart';
part 'ledger/rows_group_health.dart';
part 'ledger/rows_group_assignees.dart';
part 'ledger/rows_group_milestone.dart';
part 'ledger/rows_group_weight.dart';
part 'ledger/rows_group_activity_create.dart';
part 'ledger/rows_group_activity_delete.dart';
part 'ledger/rows_group_reaction.dart';
part 'ledger/rows_group_notifications.dart';
part 'ledger/rows_group_content.dart';
part 'ledger/rows_group_activity_edit.dart';
part 'ledger/rows_group_labels.dart';
part 'ledger/rows_merge.dart';
part 'ledger/rows_project.dart';
part 'ledger/rows_refs.dart';
part 'ledger/rows_snippets.dart';
part 'ledger/rows_t12.dart';

/// G14 changes this only together with the consent/catalogue upgrade.
const bool aiGroupWorkItemWritesEnabled = true;

@visibleForTesting
bool? aiGroupWorkItemWritesEnabledForTesting;

bool get aiGroupWorkItemWritesAreEnabled =>
    aiGroupWorkItemWritesEnabledForTesting ?? aiGroupWorkItemWritesEnabled;

enum AiScopeKind {
  project,
  workItem,
  mergeRequest,
  groupWorkItem,
  accountGlobal,
}

/// Every model-visible operation is released for every target kind in v0.6.0
/// (owner decision 2026-10-30: synthetic sandbox suites plus one emulator
/// walkthrough instead of the 7R live matrix). Binding, the confirmation card,
/// typed-name deletes and hard lines still apply to each call.
final Map<String, Set<AiTargetKind>> aiReleasedWriteTargets =
    Map<String, Set<AiTargetKind>>.unmodifiable(<String, Set<AiTargetKind>>{
      for (final AiCapability row in ProductionAiLedger.rows)
        if (row.modelVisible)
          row.operationId: Set<AiTargetKind>.unmodifiable(AiTargetKind.values),
    });

/// How a capability is admitted by a grant. Group work items have no MR6b-1 tool.
enum AiScopeClass {
  project,
  workItem,
  mergeRequest,
  resource,
  accountTodo,
  groupWorkItem,

  /// A file uploaded into a project's uploads: the project of any project,
  /// issue or merge request grant, and nothing else in that project.
  projectUpload,

  /// Writes whose target is the signed-in account rather than a project.
  accountGlobalOnly,

  /// Project creation in the current user's namespace, or a fork whose
  /// source project must be covered by a project grant.
  personalNamespace,
}

/// Why an automatic write is held for confirmation. Codes only; the card copy
/// is translated by the UI packet.
enum AiFixedConfirmReason {
  markAllTodosDone,
  foreignDraftsInPublish,
  massMention,
  externalMediaInRenderedMarkdown,
  foreignClosingOrCrossProject,
  duplicateOfSettledWrite,
  duplicateUpload,
  wholeFieldDropsHiddenSpans,
  headMovedSincePreview,
  confirmMarkAfterManualRelease,
  journalResetWindow,
  confidentialOrVisibilityMix,
  targetUnbound,
  targetNamedNotMarked,
  intentNotUnique,
}

/// Operation ids that always require confirmation, including ones this MR does
/// not implement. Source of `AiWritePolicy.fixedConfirmOperationIds`.
const Set<String> aiFixedConfirmOperationIds = <String>{'markAllTodosDone'};

/// §4.1 reasons that still require confirmation at bypass.
const Set<AiFixedConfirmReason> aiAlwaysConfirmReasons = <AiFixedConfirmReason>{
  AiFixedConfirmReason.markAllTodosDone,
  AiFixedConfirmReason.foreignDraftsInPublish,
  AiFixedConfirmReason.massMention,
  AiFixedConfirmReason.externalMediaInRenderedMarkdown,
  AiFixedConfirmReason.foreignClosingOrCrossProject,
  AiFixedConfirmReason.duplicateOfSettledWrite,
  AiFixedConfirmReason.duplicateUpload,
  AiFixedConfirmReason.wholeFieldDropsHiddenSpans,
};

/// §4.1 reasons that require confirmation at every level except bypass.
const Set<AiFixedConfirmReason> aiConfirmUnlessBypassReasons =
    <AiFixedConfirmReason>{
      AiFixedConfirmReason.headMovedSincePreview,
      AiFixedConfirmReason.confirmMarkAfterManualRelease,
      AiFixedConfirmReason.journalResetWindow,
      AiFixedConfirmReason.confidentialOrVisibilityMix,
    };

/// §4.4 write budgets. T4 caps include hard-line operations. The per-turn tool
/// cap stays 4 and the per-send tool cap stays 12; 8 is the whole send.
abstract final class AiWriteLimits {
  static const int writesPerSend = 8;
  static const int t4PerSend = 3;
  static const int writesPerConversation = 40;
  static const int t4PerConversation = 10;
  static const int writesPerAccountPerRollingHour = 60;
  static const int t4PerAccountPerRollingHour = 10;
  static const Duration rollingWindow = Duration(minutes: 60);
  static const int batchResourceCap = 20;
  static const int httpPerSend = 40;
  static const int rereadHttp = 10;
  static const Duration journalResetConfirmWindow = Duration(hours: 24);
}

final class AiScopeGrant {
  const AiScopeGrant({
    required this.kind,
    this.projectId,
    this.projectPath,
    this.iid,
    this.groupFullPath,
    this.groupId,
  });

  final AiScopeKind kind;
  final int? projectId;
  final String? projectPath;
  final int? iid;
  final String? groupFullPath;
  final int? groupId;
}

final class AiWriteScope {
  const AiWriteScope({
    required this.accountKey,
    required this.grants,
    this.instance,
    this.uiAddedGroupWorkItems = const <VerifiedGroupWorkItemIdentity>[],
  });

  final String accountKey;
  final List<VerifiedGroupWorkItemIdentity> uiAddedGroupWorkItems;
  final List<AiScopeGrant> grants;

  /// Instance parsed from [accountKey] when omitted. Resource URLs are checked
  /// against it.
  final GitLabInstance? instance;

  /// A conversation with no grant does not offer write tools.
  bool get allowsWrites => grants.isNotEmpty;

  GitLabInstance? get resolvedInstance {
    final given = instance;
    if (given != null) return given;
    return instanceFromAccountKey(accountKey);
  }
}

/// `(account, project:<id>, workItem, iid)` and the other scope keys.
String aiWriteScopeKey(String accountKey, AiScopeGrant grant) {
  switch (grant.kind) {
    case AiScopeKind.project:
      return '($accountKey, project:${grant.projectId})';
    case AiScopeKind.workItem:
      return '($accountKey, project:${grant.projectId}, workItem, ${grant.iid})';
    case AiScopeKind.mergeRequest:
      return '($accountKey, project:${grant.projectId}, mergeRequest, ${grant.iid})';
    case AiScopeKind.groupWorkItem:
      return '($accountKey, group:${grant.groupId}, workItem, ${grant.iid})';
    case AiScopeKind.accountGlobal:
      return '($accountKey, accountGlobal, todos)';
  }
}

/// A project work item opened from a group page. The key is the project, and
/// the grant covers that item and its children only.
AiScopeGrant projectIssueFromGroupPage({
  required int projectId,
  required String projectPath,
  required int iid,
}) {
  return AiScopeGrant(
    kind: AiScopeKind.workItem,
    projectId: projectId,
    projectPath: projectPath,
    iid: iid,
  );
}

GitLabInstance? instanceFromAccountKey(String accountKey) {
  final split = accountKey.lastIndexOf('#');
  if (split <= 0) return null;
  try {
    return GitLabInstance.parse(accountKey.substring(0, split));
  } on FormatException {
    return null;
  }
}

enum AiArgType {
  integer,
  string,
  stringList,
  boolean,
  object,
  integerList,
  edits,
  variables,
  suggestionList,
  snippetActions,
}

enum AiWriteBoundary { rest, graph }

enum AiTextRole {
  none,
  quickActionMarkdown,
  plainContent,
  renderedMarkdown,
  commitMessage,
  fragmentEdits,
  fullNewContent,
  pathOrRef,
}

final class AiArgSpec {
  const AiArgSpec(
    this.type, {
    this.required = false,
    this.text = AiTextRole.none,
    this.writableField,
    this.properties = const <String, AiArgSpec>{},
    this.modelVisible = true,
    this.portVisible = true,
    this.enumValues,
    this.allowIdentifierMentions = false,
  }) : assert(enumValues == null || type == AiArgType.string),
       assert(!allowIdentifierMentions || type == AiArgType.stringList);

  final AiArgType type;
  final bool required;
  final AiTextRole text;
  final String? writableField;

  /// Username list items use names (including a literal @name) as identifiers,
  /// not notification text. Only the mention check is exempt; all secret,
  /// placeholder, upload and untrusted-text checks still apply (D32).
  final bool allowIdentifierMentions;

  /// Closed nested object fields. An empty map means the object has no
  /// ledger-defined nested shape.
  final Map<String, AiArgSpec> properties;

  /// The upload row joins model-facing attachment ids with port-facing file
  /// metadata. These flags retain each boundary's narrower whitelist.
  final bool modelVisible;
  final bool portVisible;

  /// Allowed string values shown to the model as a closed enum. Null means
  /// the string accepts any value.
  final List<String>? enumValues;
}

final class AiCapability {
  const AiCapability({
    required this.operationId,
    required this.baseTier,
    required this.scopeClass,
    this.modelVisible = true,
    String? namedMethod,
    this.arguments = const <String, AiArgSpec>{},
    this.httpCap = 39,
    this.readback = false,
    this.editableField,
    this.boundary = AiWriteBoundary.rest,
  }) : namedMethod = namedMethod ?? operationId;

  final String operationId;
  final AiWriteTier baseTier;
  final AiScopeClass scopeClass;

  /// Implementation visibility is additionally restricted by release policy.
  final bool modelVisible;

  /// Packet 5 method. `upload_attachment` calls `uploadProjectFile`.
  final String namedMethod;

  /// Model and internal port arguments. `reason` is coordinator metadata and
  /// is deliberately absent. Unlisted keys are rejected.
  final Map<String, AiArgSpec> arguments;

  /// OAuth worst-case request allowance, including mutation and readback.
  final int httpCap;
  final bool readback;

  final AiWriteBoundary boundary;

  /// The one text field a confirmation card may replace.
  final String? editableField;
}

abstract interface class AiCapabilityLedger {
  AiCapability? find(String operationId);
  List<AiCapability> get modelVisible;
}

final class ProductionAiLedger implements AiCapabilityLedger {
  const ProductionAiLedger({this.releasePolicy = productionAiReleasePolicy});

  final AiReleasePolicyView releasePolicy;

  static const List<AiCapability> rows = <AiCapability>[
    ...aiT12Rows,
    ...aiFileRows,
    ...aiGraphqlActivityCreateRows,
    ...aiGraphqlActivityDeleteRows,
    ...aiGraphqlActivityEditRows,
    ...aiGraphqlContentRows,
    ...aiGraphqlLabelsRows,
    ...aiGraphqlAssigneesRows,
    ...aiGraphqlDatesRows,
    ...aiGraphqlHealthRows,
    ...aiGraphqlIncidentRows,
    ...aiGraphqlMilestoneRows,
    ...aiGraphqlNotificationsRows,
    ...aiGraphqlReactionRows,
    ...aiGraphqlSnoozeRows,
    ...aiGraphqlStateRows,
    ...aiGraphqlStatusRows,
    ...aiGraphqlWeightRows,
    ...aiGroupStateRows,
    ...aiGroupStatusRows,
    ...aiGroupDatesRows,
    ...aiGroupHealthRows,
    ...aiGroupAssigneesRows,
    ...aiGroupMilestoneRows,
    ...aiGroupWeightRows,
    ...aiGroupActivityCreateRows,
    ...aiGroupActivityDeleteRows,
    ...aiGroupReactionRows,
    ...aiGroupNotificationsRows,
    ...aiGroupContentRows,
    ...aiGroupActivityEditRows,
    ...aiGroupLabelsRows,
    ...aiRefRows,
    ...aiMergeRows,
    ...aiCiRows,
    ...aiSnippetRows,
    ...aiDeleteRows,
    ...aiProjectRows,
  ];

  static final Map<String, AiCapability> _index = <String, AiCapability>{
    for (final AiCapability row in rows) row.operationId: row,
  };

  @override
  AiCapability? find(String operationId) => _index[operationId];

  @override
  List<AiCapability> get modelVisible => List<AiCapability>.unmodifiable(
    rows.where(
      (row) =>
          row.modelVisible &&
          releasePolicy.allowsWriteOperation(row.operationId),
    ),
  );
}

const ProductionAiLedger productionAiLedger = ProductionAiLedger();

/// Tools the model may see for this scope. Empty when the conversation has no
/// writable grant, or only a group work item (no MR6b-1 tool admits it).
List<AiCapability> toolsForScope(
  AiWriteScope scope, {
  AiCapabilityLedger? ledger,
  AiReleasePolicyView releasePolicy = productionAiReleasePolicy,
}) {
  if (!scope.allowsWrites) return const <AiCapability>[];
  final capabilities =
      ledger ?? ProductionAiLedger(releasePolicy: releasePolicy);
  return <AiCapability>[
    for (final AiCapability row in capabilities.modelVisible)
      if (releasePolicy.allowsWriteOperation(row.operationId) &&
          _offered(scope, row, releasePolicy))
        row,
  ];
}

bool offersWriteTools(
  AiWriteScope scope, {
  AiReleasePolicyView releasePolicy = productionAiReleasePolicy,
}) => toolsForScope(scope, releasePolicy: releasePolicy).isNotEmpty;

/// The owning target known before opening a port. Prepared child targets must
/// also be released, and are rechecked by the coordinator at the final send.
AiTargetKind aiWriteProposalTargetKind(
  AiCapability row, {
  bool mergeRequest = false,
}) => switch (row.scopeClass) {
  AiScopeClass.workItem => AiTargetKind.issue,
  AiScopeClass.mergeRequest => AiTargetKind.mergeRequest,
  AiScopeClass.resource =>
    mergeRequest ? AiTargetKind.mergeRequest : AiTargetKind.issue,
  AiScopeClass.accountTodo ||
  AiScopeClass.accountGlobalOnly => AiTargetKind.todo,
  AiScopeClass.groupWorkItem => switch (row.operationId) {
    'setGroupWorkItemActivityNoteReaction' => AiTargetKind.emoji,
    'deleteGroupWorkItemActivityNote' ||
    'editGroupWorkItemActivityNote' => AiTargetKind.note,
    _ => AiTargetKind.groupWorkItem,
  },
  AiScopeClass.project ||
  AiScopeClass.projectUpload ||
  AiScopeClass.personalNamespace => AiTargetKind.project,
};

bool _offered(
  AiWriteScope scope,
  AiCapability row,
  AiReleasePolicyView releasePolicy,
) {
  for (final AiScopeGrant grant in scope.grants) {
    if (grant.kind == AiScopeKind.groupWorkItem &&
        (grant.groupId == null ||
            grant.groupId! <= 0 ||
            grant.groupFullPath == null ||
            grant.groupFullPath!.isEmpty ||
            grant.iid == null ||
            grant.iid! <= 0 ||
            grant.projectId != null ||
            grant.projectPath != null)) {
      continue;
    }
    if (!_grantOffers(grant.kind, row)) continue;
    final mergeRequest = grant.kind == AiScopeKind.mergeRequest;
    if (releasePolicy.allowsWrite(
      row.operationId,
      aiWriteProposalTargetKind(row, mergeRequest: mergeRequest),
    )) {
      return true;
    }
    if (grant.kind == AiScopeKind.project &&
        row.scopeClass == AiScopeClass.resource &&
        releasePolicy.allowsWrite(
          row.operationId,
          aiWriteProposalTargetKind(row, mergeRequest: true),
        )) {
      return true;
    }
  }
  return false;
}

bool _grantOffers(AiScopeKind kind, AiCapability capability) {
  switch (capability.scopeClass) {
    case AiScopeClass.project:
      return kind == AiScopeKind.project;
    case AiScopeClass.workItem:
      return kind == AiScopeKind.project || kind == AiScopeKind.workItem;
    case AiScopeClass.mergeRequest:
      return kind == AiScopeKind.project || kind == AiScopeKind.mergeRequest;
    case AiScopeClass.resource:
      return kind == AiScopeKind.project ||
          kind == AiScopeKind.workItem ||
          kind == AiScopeKind.mergeRequest;
    case AiScopeClass.accountTodo:
      return kind == AiScopeKind.accountGlobal ||
          kind == AiScopeKind.project ||
          kind == AiScopeKind.workItem ||
          kind == AiScopeKind.mergeRequest ||
          (kind == AiScopeKind.groupWorkItem &&
              aiGroupWorkItemWritesAreEnabled &&
              (capability.operationId == 'snoozeTodo' ||
                  capability.operationId == 'unsnoozeTodo'));
    case AiScopeClass.groupWorkItem:
      return aiGroupWorkItemWritesAreEnabled &&
          kind == AiScopeKind.groupWorkItem;
    case AiScopeClass.projectUpload:
      return kind == AiScopeKind.project ||
          kind == AiScopeKind.workItem ||
          kind == AiScopeKind.mergeRequest;
    case AiScopeClass.accountGlobalOnly:
      return kind == AiScopeKind.accountGlobal;
    case AiScopeClass.personalNamespace:
      return kind == AiScopeKind.project;
  }
}
