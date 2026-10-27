part of '../write_ledger.dart';

const List<AiCapability> aiGroupHealthRows = <AiCapability>[
  AiCapability(
    operationId: 'updateGroupWorkItemHealthStatus',
    namedMethod: 'updateWorkItemHealthStatus',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': AiArgSpec(AiArgType.integer, required: true),
      'healthStatus': AiArgSpec(
        AiArgType.string,
        required: true,
        enumValues: ['onTrack', 'needsAttention', 'atRisk', 'none'],
      ),
    },
    // L = 2 * (group freshness 1 + actor 1 + strict namespace 1 + health 1)
    //     + method preflight 1 + independent readback 1 = 10.
    // OAuth resources: 2 * L + mutation 1 = 21; PAT: L + 1 = 11.
    httpCap: 21,
    readback: true,
  ),
];
