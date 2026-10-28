part of '../write_ledger.dart';

const List<AiCapability> aiGroupStateRows = <AiCapability>[
  AiCapability(
    operationId: 'updateGroupWorkItemState',
    namedMethod: 'updateWorkItemState',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'stateEvent': AiArgSpec(
        AiArgType.string,
        required: true,
        enumValues: ['close', 'reopen'],
      ),
    },
    // L = 2 * (group freshness 1 + actor 1 + namespace WI 1 + state 1)
    //     + preflight 1 + independent readback 1 = 10. OAuth: 2 * L + 1.
    httpCap: 21,
    readback: true,
  ),
];
