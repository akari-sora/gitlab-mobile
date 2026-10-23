part of '../write_ledger.dart';

const _releaseDescription = AiArgSpec(
  AiArgType.string,
  text: AiTextRole.renderedMarkdown,
  writableField: 'releaseDescription',
);

// Each pass includes one visibility GET in freshness. The port reads the
// actor, project and source/target once; create/update also read back once.
// Caps reserve both passes and two attempts per GET for OAuth replay.
// Ref names intentionally share one key across branches/tags. Prefix locks
// conservatively intersect descendant file keys, per decision 13.
const List<AiCapability> aiRefRows = <AiCapability>[
  AiCapability(
    operationId: 'createBranch',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'branch': _requiredPathOrRef,
      'ref': _requiredPathOrRef,
    },
    httpCap: 19,
    readback: true,
  ),
  AiCapability(
    operationId: 'deleteBranch',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'branch': _requiredPathOrRef},
    httpCap: 17,
  ),
  AiCapability(
    operationId: 'createTag',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'tag_name': _requiredPathOrRef,
      'ref': _requiredPathOrRef,
      'message': _plain,
    },
    httpCap: 19,
    readback: true,
  ),
  AiCapability(
    operationId: 'deleteTag',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'tag_name': _requiredPathOrRef},
    httpCap: 17,
  ),
  AiCapability(
    operationId: 'createRelease',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'fields': AiArgSpec(AiArgType.object, required: true, properties: {
        'tag_name': _requiredPathOrRef,
        'name': _plain,
        'description': _releaseDescription,
      }),
    },
    httpCap: 19,
    readback: true,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'updateRelease',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'tag_name': _requiredPathOrRef,
      'fields': AiArgSpec(AiArgType.object, required: true, properties: {
        'name': _plain,
        'description': _releaseDescription,
      }),
    },
    httpCap: 19,
    readback: true,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'deleteRelease',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'tag_name': _requiredPathOrRef},
    httpCap: 17,
  ),
];
