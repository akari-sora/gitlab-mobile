part of '../write_ledger.dart';

const List<AiCapability> aiGroupActivityEditRows = <AiCapability>[
  AiCapability(
    operationId: 'editGroupWorkItemActivityNote',
    namedMethod: 'editWorkItemActivityNote',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.groupWorkItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'groupId': AiArgSpec(AiArgType.integer, required: true),
      'iid': _iid,
      'noteId': _noteId,
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'note',
      ),
    },
    // F=group freshness1; P=actor1 + strict namespace WI1 + locator2 + access1.
    // L=2*(F+P)+Mpre1+Mrb1=2*(1+5)+1+1=14.
    // httpCap=2L+1=29; PAT=L+1=15. Locator shares two total reads.
    httpCap: 29,
    readback: true,
    editableField: 'body',
  ),
];
