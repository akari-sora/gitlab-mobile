part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlActivityDeleteRows = <AiCapability>[
  AiCapability(
    operationId: 'deleteWorkItemActivityNote',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'iid': _iid, 'noteId': _iid},
    // L = 2 * (freshness1 + user1 + WI1 + locator2 + access1) + pre1 + rb1.
    httpCap: 29,
    readback: true,
  ),
];
