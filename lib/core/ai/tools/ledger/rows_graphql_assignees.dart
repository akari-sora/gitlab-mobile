part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlAssigneesRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemAssignees',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    // L = 2 * (freshness 1 + actor 1 + item 1 + opening 1 + searches 4)
    //     + preflight 1 + independent readback 1 = 18. OAuth: 2L + 1.
    httpCap: 37,
    readback: true,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'assigneeUsernames': AiArgSpec(AiArgType.stringList, required: true),
    },
  ),
];
