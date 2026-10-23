part of '../write_ledger.dart';

// Each row reserves both prepares, one mutation and an independent readback.
// GETs count twice for OAuth replay. Create checks a branch, then a tag on 404:
// 2 * (user + project + branch + tag) * 2 + mutation + readback * 2 = 19.
// Other rows use user + project + target in each prepare: 15 requests.
// Schedule detail failure permits at most two list pages to verify its ref:
// 2 * (user + project + detail + 2 pages) * 2 + mutation + readback * 2 = 23.
// Prefix intersections deliberately make an unknown create/schedule hold all
// pipeline writes for the project. Jobs are children of their owning pipeline;
// sibling jobs do not conflict. Release names always come from fresh reads.
const List<AiCapability> aiCiRows = <AiCapability>[
  AiCapability(
    operationId: 'createPipeline',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'ref': AiArgSpec(AiArgType.string, required: true,
          text: AiTextRole.pathOrRef),
      'variables': AiArgSpec(AiArgType.variables, properties: {
        'key': AiArgSpec(AiArgType.string, required: true),
        'value': AiArgSpec(AiArgType.string, required: true),
        'variable_type': AiArgSpec(AiArgType.string),
      }),
    },
    httpCap: 19,
    readback: true,
  ),
  // Cancel is T3; retry is promoted to T4 by the gate, confirmation only.
  // Stored variables/inputs are neither read nor bound. The body is {}.
  AiCapability(
    operationId: 'pipelineAction',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'pipelineId': AiArgSpec(AiArgType.integer, required: true),
      'action': AiArgSpec(AiArgType.string, required: true),
    },
    httpCap: 15,
    readback: true,
  ),
  // Retry/play are T4 confirmation-only, regardless of current job status.
  // Cancel remains T3; the gate exposes cancelMayRunAfterScript.
  AiCapability(
    operationId: 'jobAction',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'jobId': AiArgSpec(AiArgType.integer, required: true),
      'action': AiArgSpec(AiArgType.string, required: true),
    },
    httpCap: 15,
    readback: true,
  ),
  // Only explicit empty variables AND inputs remain T4. Nonempty/unreadable
  // schedules are hard-line. Parameter values and HMAC never enter the journal.
  AiCapability(
    operationId: 'playPipelineSchedule',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'scheduleId': AiArgSpec(AiArgType.integer, required: true),
    },
    httpCap: 23,
    readback: true,
  ),
  AiCapability(
    operationId: 'deletePipeline',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'pipelineId': AiArgSpec(AiArgType.integer, required: true),
    },
    httpCap: 15,
    readback: true,
  ),
];
