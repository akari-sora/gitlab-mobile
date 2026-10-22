import '../../instance.dart';
import 'write_levels.dart';

export 'write_levels.dart';

enum AiScopeKind {
  project,
  workItem,
  mergeRequest,
  groupWorkItem,
  accountGlobal,
}

/// How a capability is admitted by a grant. Group work items have no MR6b-1 tool.
enum AiScopeClass {
  project,
  workItem,
  mergeRequest,
  resource,
  accountTodo,
  groupWorkItem,
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
  wholeFieldDropsHiddenSpans,
  headMovedSincePreview,
  confirmMarkAfterManualRelease,
  journalResetWindow,
  confidentialOrVisibilityMix,
  targetUnbound,
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
  });

  final String accountKey;
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
      return '($accountKey, group:${grant.groupFullPath}, workItem, ${grant.iid})';
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

final class AiCapability {
  const AiCapability({
    required this.operationId,
    required this.baseTier,
    required this.scopeClass,
    this.modelVisible = true,
    String? namedMethod,
  }) : namedMethod = namedMethod ?? operationId;

  final String operationId;
  final AiWriteTier baseTier;
  final AiScopeClass scopeClass;

  /// MR6b-1 exposes implemented T1 and T2 rows. Higher tiers stay out of the
  /// model tool list; tests build those rows themselves.
  final bool modelVisible;

  /// Packet 5 method. `upload_attachment` calls `uploadProjectFile`.
  final String namedMethod;
}

abstract interface class AiCapabilityLedger {
  AiCapability? find(String operationId);
  List<AiCapability> get modelVisible;
}

final class ProductionAiLedger implements AiCapabilityLedger {
  const ProductionAiLedger();

  static const List<AiCapability> rows = <AiCapability>[
    AiCapability(
      operationId: 'addAwardEmoji',
      baseTier: AiWriteTier.t1,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'removeAwardEmoji',
      baseTier: AiWriteTier.t1,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'setStar',
      baseTier: AiWriteTier.t1,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'setSubscribed',
      baseTier: AiWriteTier.t1,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'markTodoDone',
      baseTier: AiWriteTier.t1,
      scopeClass: AiScopeClass.accountTodo,
    ),
    AiCapability(
      operationId: 'createNote',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'updateNote',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'createIssue',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'updateIssue',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.workItem,
    ),
    AiCapability(
      operationId: 'createMergeRequest',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'updateMergeRequest',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.mergeRequest,
    ),
    AiCapability(
      operationId: 'unapproveMergeRequest',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.mergeRequest,
    ),
    AiCapability(
      operationId: 'createTodo',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'createDiscussion',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'createDiscussionNote',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'updateDiscussionNote',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'setDiscussionResolved',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.resource,
    ),
    AiCapability(
      operationId: 'createDraftNote',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.mergeRequest,
    ),
    AiCapability(
      operationId: 'updateDraftNote',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.mergeRequest,
    ),
    AiCapability(
      operationId: 'createLabel',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'updateLabel',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'createMilestone',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'updateMilestone',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'setMilestoneState',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'createBoard',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'renameBoard',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'setBoardSystemListHidden',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'createBoardList',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'moveBoardList',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
    ),
    AiCapability(
      operationId: 'moveBoardCard',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.workItem,
    ),
    AiCapability(
      operationId: 'upload_attachment',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.project,
      namedMethod: 'uploadProjectFile',
    ),
  ];

  static final Map<String, AiCapability> _index = <String, AiCapability>{
    for (final AiCapability row in rows) row.operationId: row,
  };

  static final List<AiCapability> _visible = List<AiCapability>.unmodifiable(
    rows.where((AiCapability row) => row.modelVisible),
  );

  @override
  AiCapability? find(String operationId) => _index[operationId];

  @override
  List<AiCapability> get modelVisible => _visible;
}

const ProductionAiLedger productionAiLedger = ProductionAiLedger();

/// Tools the model may see for this scope. Empty when the conversation has no
/// writable grant, or only a group work item (no MR6b-1 tool admits it).
List<AiCapability> toolsForScope(AiWriteScope scope) {
  if (!scope.allowsWrites) return const <AiCapability>[];
  return <AiCapability>[
    for (final AiCapability row in productionAiLedger.modelVisible)
      if (_offered(scope, row)) row,
  ];
}

bool offersWriteTools(AiWriteScope scope) => toolsForScope(scope).isNotEmpty;

bool _offered(AiWriteScope scope, AiCapability row) {
  for (final AiScopeGrant grant in scope.grants) {
    if (_grantOffers(grant.kind, row.scopeClass)) return true;
  }
  return false;
}

bool _grantOffers(AiScopeKind kind, AiScopeClass scopeClass) {
  switch (scopeClass) {
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
          kind == AiScopeKind.mergeRequest;
    case AiScopeClass.groupWorkItem:
      return false;
  }
}
