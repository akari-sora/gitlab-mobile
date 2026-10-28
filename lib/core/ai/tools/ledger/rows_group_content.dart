part of '../write_ledger.dart';

const List<AiCapability> aiGroupContentRows = <AiCapability>[
  AiCapability(
    operationId: 'updateGroupWorkItemContent',
    namedMethod: 'updateWorkItemContent',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'title': AiArgSpec(AiArgType.string, text: AiTextRole.plainContent),
      'description': AiArgSpec(
        AiArgType.string,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'issueDescription',
      ),
    },
    // F=1; P=user1+strict namespace WI1+content1=3; Mpre=1; Mrb=1.
    // L=2(F+P)+Mpre+Mrb=2*(1+3)+1+1=10; httpCap=2L+1=21.
    httpCap: 21,
    readback: true,
    editableField: 'description',
  ),
];
