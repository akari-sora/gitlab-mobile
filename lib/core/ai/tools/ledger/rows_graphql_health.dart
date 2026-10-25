part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlHealthRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemHealthStatus',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'iid': AiArgSpec(AiArgType.integer, required: true),
      'healthStatus': AiArgSpec(
        AiArgType.string,
        required: true,
        enumValues: ['onTrack', 'needsAttention', 'atRisk', 'none'],
      ),
    },
    // L = 2 * (freshness 1 + user 1 + item 1 + health 1) + preflight 1
    //     + independent readback 1 = 10. OAuth: 2 * L + 1; PAT: L + 1.
    httpCap: 21,
    readback: true,
  ),
];
