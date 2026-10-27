part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlContentRows = <AiCapability>[
  AiCapability(
    operationId: 'updateWorkItemContent',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'iid': _projectId,
      'title': AiArgSpec(AiArgType.string, text: AiTextRole.plainContent),
      'description': AiArgSpec(
        AiArgType.string,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'issueDescription',
      ),
    },
    // F=1; P=user1+project WI1+content1=3; Mpre=1; Mrb=1.
    // L=2(F+P)+Mpre+Mrb=2*(1+3)+1+1=10; httpCap=2L+1=21.
    httpCap: 21,
    readback: true,
  ),
];
