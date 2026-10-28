part of '../write_ledger.dart';

const List<AiCapability> aiGroupAssigneesRows = <AiCapability>[
  AiCapability(
    operationId: 'updateGroupWorkItemAssignees',
    namedMethod: 'updateWorkItemAssignees',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    // L = 2 * (group freshness 1 + actor 1 + namespace 1 + opening 1
    //     + group autocomplete 4) + preflight 1 + readback 1 = 18.
    // OAuth resource allowance = 2L + 1 = 37; PAT = L + 1 = 19.
    httpCap: 37,
    readback: true,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'assigneeUsernames': AiArgSpec(
        AiArgType.stringList,
        required: true,
        allowIdentifierMentions: true,
      ),
    },
  ),
];
