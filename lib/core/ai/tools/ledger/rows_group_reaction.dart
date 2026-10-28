part of '../write_ledger.dart';

const List<AiCapability> aiGroupReactionRows = <AiCapability>[
  AiCapability(
    operationId: 'setGroupWorkItemActivityNoteReaction',
    namedMethod: 'setWorkItemActivityNoteReaction',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: <String, AiArgSpec>{
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'noteId': AiArgSpec(AiArgType.integer, required: true),
      'name': _requiredString,
      'add': _requiredBoolean,
    },
    httpCap: 37,
    readback: true,
  ),
];
