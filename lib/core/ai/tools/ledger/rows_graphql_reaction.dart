part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlReactionRows = <AiCapability>[
  AiCapability(
    operationId: 'setWorkItemActivityNoteReaction',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'iid': _iid,
      'noteId': AiArgSpec(AiArgType.integer, required: true),
      'name': _requiredString,
      'add': _requiredBoolean,
    },
    httpCap: 37,
    readback: true,
  ),
];
