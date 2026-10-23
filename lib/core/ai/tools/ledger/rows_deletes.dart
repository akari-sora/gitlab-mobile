part of '../write_ledger.dart';

// Each read reserves its OAuth replay, in both prepare passes. Project rows
// also reserve the coordinator's project freshness read in each pass.
const List<AiCapability> aiDeleteRows = <AiCapability>[
  AiCapability(
    operationId: 'deleteNote',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.resource,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'resource': _requiredString,
      'iid': _iid,
      'noteId': _iid,
    },
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'deleteDiscussionNote',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.resource,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'resource': _requiredString,
      'iid': _iid,
      'discussionId': _requiredString,
      'noteId': _iid,
    },
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'deleteIssue',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.workItem,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'iid': _iid},
    httpCap: 17,
  ),
  AiCapability(
    operationId: 'deleteMergeRequest',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'iid': _iid},
    httpCap: 17,
  ),
  AiCapability(
    operationId: 'deleteLabel',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'labelId': _iid},
    httpCap: 17,
  ),
  AiCapability(
    operationId: 'deleteMilestone',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'milestoneId': _iid},
    httpCap: 17,
  ),
  AiCapability(
    operationId: 'deleteBoard',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'boardId': _iid},
    httpCap: 17,
  ),
  AiCapability(
    operationId: 'deleteBoardList',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'boardId': _iid, 'listId': _iid},
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'markAllTodosDone',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.accountGlobalOnly,
    modelVisible: true,
    httpCap: 9,
  ),
];
