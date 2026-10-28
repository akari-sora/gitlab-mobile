part of '../write_ledger.dart';

const List<AiCapability> aiGroupLabelsRows = <AiCapability>[
  AiCapability(
    operationId: 'updateGroupWorkItemLabels',
    namedMethod: 'updateWorkItemLabels',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'labels': AiArgSpec(AiArgType.stringList, required: true),
    },
    // At most 10 exact titles; current labels and the fixed direct-group
    // catalog must each be complete in one page of 100, including for clear.
    // F=1 group freshness; P=actor 1 + strict namespace 1 + current 1 + catalog 1=4.
    // L=2(F+P)+Mpre+Mrb=2(1+4)+1+1=12; httpCap=2L+1=25.
    httpCap: 25,
    readback: true,
  ),
];
