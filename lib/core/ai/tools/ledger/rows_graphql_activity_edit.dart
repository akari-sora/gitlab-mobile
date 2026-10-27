part of '../write_ledger.dart';

const List<AiCapability> aiGraphqlActivityEditRows = <AiCapability>[
  AiCapability(
    operationId: 'editWorkItemActivityNote',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'iid': _iid,
      'noteId': _noteId,
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'note',
      ),
    },
    // L = 2(F+P) + Mpre + Mrb
    //   = 2 * (freshness1 + user1 + WI1 + locator2 + access1) + 1 + 1 = 14.
    // httpCap = 2L+1 = 29; PAT = L+1 = 15. Locator shares two total reads.
    httpCap: 29,
    readback: true,
    editableField: 'body',
  ),
];
