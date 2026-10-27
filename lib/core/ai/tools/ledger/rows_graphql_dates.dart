part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlDatesRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemDates',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'mode': AiArgSpec(
        AiArgType.string,
        required: true,
        enumValues: ['manual', 'inherited'],
      ),
      'startDate': AiArgSpec(AiArgType.string),
      'dueDate': AiArgSpec(AiArgType.string),
      'clearStart': AiArgSpec(AiArgType.boolean),
      'clearDue': AiArgSpec(AiArgType.boolean),
    },
    // F=1, P=user1+WI1+base1+probe1=4, Mpre=2, Mrb=2.
    // L=2*(1+4)+2+2=14; OAuth=2*14+1=29, PAT=15.
    httpCap: 29,
    readback: true,
  ),
];
