part of '../write_ledger.dart';

const List<AiCapability> aiGroupActivityCreateRows = <AiCapability>[
  AiCapability(
    operationId: 'createGroupWorkItemActivityComment',
    namedMethod: 'createWorkItemActivityComment',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'note',
      ),
    },
    // L = 2 * (group freshness1 + user1 + namespace WI1 + access1) + preflight1 + readback1.
    httpCap: 21,
    readback: true,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'createGroupWorkItemActivityReply',
    namedMethod: 'createWorkItemActivityReply',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'anchorNoteId': AiArgSpec(AiArgType.integer, required: true),
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'note',
      ),
    },
    // L = 2 * (F1 + U1 + N1 + locator2 + access1) + preflight1 + readback1.
    // The three locator readers share two reads; no separate anchor lookup.
    httpCap: 29,
    readback: true,
    editableField: 'body',
  ),
];
