part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlStateRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemState',
    namedMethod: 'updateWorkItemState',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'iid': _projectId,
      'stateEvent': AiArgSpec(
        AiArgType.string,
        required: true,
        enumValues: ['close', 'reopen'],
      ),
    },
    // L = 2 * (freshness 1 + user 1 + WI 1 + state 1) + preflight 1
    //     + independent readback 1 = 10. OAuth: 2 * L + mutation 1.
    httpCap: 21,
    readback: true,
  ),
];
