part of '../write_ledger.dart';

const List<AiCapability> aiGroupMilestoneRows = <AiCapability>[
  AiCapability(
    operationId: 'updateGroupWorkItemMilestone',
    namedMethod: 'updateWorkItemMilestone',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'milestoneTitle': AiArgSpec(AiArgType.string),
      'clearMilestone': AiArgSpec(AiArgType.boolean),
    },
    // L = 2 * (group freshness 1 + actor 1 + namespace item 1 + opening 1 + choices 1)
    //     + preflight 1 + independent readback 1 = 12.
    httpCap: 25,
    readback: true,
  ),
];
