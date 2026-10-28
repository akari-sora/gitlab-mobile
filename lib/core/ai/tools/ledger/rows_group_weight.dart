part of '../write_ledger.dart';

const List<AiCapability> aiGroupWeightRows = <AiCapability>[
  AiCapability(
    operationId: 'updateGroupWorkItemWeight',
    namedMethod: 'updateWorkItemWeight',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'weight': AiArgSpec(AiArgType.integer),
      'clearWeight': AiArgSpec(AiArgType.boolean),
    },
    // L = 2 * (group freshness 1 + actor 1 + namespace item 1 + opening 1)
    //     + preflight 1 + independent readback 1 = 10.
    httpCap: 21,
    readback: true,
  ),
];
