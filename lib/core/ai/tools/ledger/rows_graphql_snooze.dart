part of '../write_ledger.dart';

// Per direction: F=0, P=user1+ownership4, Mpre=Mrb=0. L=10;
// OAuth cap=2*L+1=21, PAT=11. Success is the checked mutation acknowledgement.
const List<AiCapability> aiGraphqlSnoozeRows = <AiCapability>[
  AiCapability(
    operationId: 'snoozeTodo',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.accountTodo,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: {
      'todoId': AiArgSpec(AiArgType.integer, required: true),
      'until': AiArgSpec(AiArgType.string, required: true),
    },
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'unsnoozeTodo',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.accountTodo,
    boundary: AiWriteBoundary.graph,
    modelVisible: false,
    arguments: {'todoId': AiArgSpec(AiArgType.integer, required: true)},
    httpCap: 21,
  ),
];
