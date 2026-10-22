part of '../write_ledger.dart';

// Caps include both prepares, controller project freshness, OAuth GET replay,
// one mutation and independent readback. Merge reuses SHA-bound diffs/commits
// on dispatch (decision 2), but rechecks closures, CI config and protection.
// Prefix locks deliberately intersect all children of an uncertain MR write.
// Cancel reserves the decision-3 fallback POST even though the integrated named
// wrapper currently exposes only the deprecated endpoint (integration gap).
const List<AiCapability> aiMergeRows = <AiCapability>[
  AiCapability(
    operationId: 'mergeRequest',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 37,
    readback: true,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'autoMerge': AiArgSpec(AiArgType.boolean),
      'squash': AiArgSpec(AiArgType.boolean),
      'removeSourceBranch': AiArgSpec(AiArgType.boolean),
    },
  ),
  AiCapability(
    operationId: 'approveMergeRequest',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 23,
    readback: true,
    arguments: {'projectId': _projectId, 'iid': _iid},
  ),
  AiCapability(
    operationId: 'rebaseMergeRequest',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 19,
    readback: true,
    arguments: {'projectId': _projectId, 'iid': _iid},
  ),
  AiCapability(
    operationId: 'cancelAutoMerge',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 20,
    readback: true,
    arguments: {'projectId': _projectId, 'iid': _iid},
  ),
  AiCapability(
    operationId: 'publishDraftNotes',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 23,
    readback: true,
    arguments: {'projectId': _projectId, 'iid': _iid},
  ),
  AiCapability(
    operationId: 'deleteDraftNote',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 23,
    readback: true,
    arguments: {'projectId': _projectId, 'iid': _iid, 'noteId': _projectId},
  ),
];
