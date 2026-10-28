part of '../write_ledger.dart';

const List<AiCapability> aiGroupStatusRows = <AiCapability>[
  AiCapability(
    operationId: 'updateGroupWorkItemStatus',
    namedMethod: 'updateWorkItemStatus',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: <String, AiArgSpec>{
      'groupId': _iid,
      'iid': _iid,
      'candidateId': _requiredString,
    },
    // L = 2 * (group freshness 1 + actor 1 + namespace item 1 + opening 1)
    //     + preflight 1 + independent readback 1 = 10.
    // OAuth resource cap: 2 * L + 1 = 21; PAT: L + 1 = 11.
    httpCap: 21,
    readback: true,
  ),
];
