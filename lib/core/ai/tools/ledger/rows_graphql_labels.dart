part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlLabelsRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemLabels',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'labels': AiArgSpec(AiArgType.stringList, required: true),
    },
    // At most 10 exact label titles; one complete candidate page (20) and
    // one complete current-label page (100), or refuse without paging.
    // F=1 freshness; P=actor 1 + item 1 + labels 1 + candidates 1=4.
    // L=2(F+P)+Mpre+Mrb=2(1+4)+1+1=12; httpCap=2L+1=25.
    httpCap: 25,
    readback: true,
  ),
];
