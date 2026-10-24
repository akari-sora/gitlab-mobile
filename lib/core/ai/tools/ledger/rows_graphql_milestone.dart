part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlMilestoneRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemMilestone',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'milestoneTitle': AiArgSpec(AiArgType.string),
      'clearMilestone': AiArgSpec(AiArgType.boolean),
    },
    // L = 2 * (freshness 1 + actor 1 + item 1 + opening 1 + choices 1)
    //     + preflight 1 + independent readback 1 = 12.
    httpCap: 25,
    readback: true,
  ),
];
