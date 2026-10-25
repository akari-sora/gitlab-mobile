part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlWeightRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemWeight',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'weight': AiArgSpec(AiArgType.integer),
      'clearWeight': AiArgSpec(AiArgType.boolean),
    },
    // L = 2 * (freshness 1 + actor 1 + item 1 + opening 1)
    //     + preflight 1 + independent readback 1 = 10.
    httpCap: 21,
    readback: true,
  ),
];
