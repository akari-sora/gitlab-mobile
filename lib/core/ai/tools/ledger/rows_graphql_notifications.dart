part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlNotificationsRows = <AiCapability>[
  AiCapability(
    operationId: 'setWorkItemNotifications',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'iid': _iid,
      'enabled': _requiredBoolean,
    },
    httpCap: 21,
    readback: true,
  ),
];
