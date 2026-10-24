part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlActivityCreateRows = <AiCapability>[
  AiCapability(
    operationId: 'createWorkItemActivityComment',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'note',
      ),
    },
    // L = 2 * (freshness1 + user1 + WI1 + access1) + preflight1 + readback1.
    httpCap: 21,
    readback: true,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'createWorkItemActivityReply',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'anchorNoteId': AiArgSpec(AiArgType.integer, required: true),
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'note',
      ),
    },
    // The three locator readers share two reads; no separate anchor lookup.
    httpCap: 29,
    readback: true,
    editableField: 'body',
  ),
];
