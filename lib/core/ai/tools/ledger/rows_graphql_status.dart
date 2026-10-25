part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlStatusRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemStatus',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'iid': _iid,
      'candidateId': _requiredString,
    },
    // L = 2 * (freshness 1 + actor 1 + item 1 + opening 1) + preflight 1
    //     + independent readback 1 = 10. OAuth: 2 * L + 1; PAT: L + 1.
    httpCap: 21,
    readback: true,
  ),
];
