part of '../write_ledger.dart';

const List<AiCapability> aiGroupActivityDeleteRows = <AiCapability>[
  AiCapability(
    operationId: 'deleteGroupWorkItemActivityNote',
    namedMethod: 'deleteWorkItemActivityNote',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {'groupId': _iid, 'iid': _iid, 'noteId': _iid},
    // L = 2 * (group freshness1 + user1 + namespace1 + locator2 + access1)
    //     + preflight1 + readback1 = 14; cap = 2L + mutation1 = 29.
    httpCap: 29,
    readback: true,
  ),
];
