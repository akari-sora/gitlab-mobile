part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlIncidentRows = <AiCapability>[
  AiCapability(
    operationId: 'setIncidentStatus',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    // L = 2 * (freshness 1 + user 1 + WI 1 + incident 1) + preflight 1
    //     + independent readback 1 = 10; OAuth cap = 2 * L + mutation 1.
    httpCap: 21,
    readback: true,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'status': AiArgSpec(
        AiArgType.string,
        required: true,
        enumValues: ['TRIGGERED', 'ACKNOWLEDGED', 'RESOLVED'],
      ),
    },
  ),
];
