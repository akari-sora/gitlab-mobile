part of '../write_ledger.dart';

const List<AiCapability> aiGroupNotificationsRows = <AiCapability>[
  AiCapability(
    operationId: 'setGroupWorkItemNotifications',
    namedMethod: 'setWorkItemNotifications',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: <String, AiArgSpec>{
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'enabled': _requiredBoolean,
    },
    httpCap: 21,
    readback: true,
  ),
];
