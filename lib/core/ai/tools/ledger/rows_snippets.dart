part of '../write_ledger.dart';

const _snippetId = <String, AiArgSpec>{
  'projectId': _projectId,
  'snippetId': _projectId,
};
const _snippetDescription = AiArgSpec(
  AiArgType.string,
  text: AiTextRole.renderedMarkdown,
  writableField: 'snippetDescription',
);

// Each proposal/dispatch pass has one freshness project GET. Port preparation
// reads actor + project, then an existing snippet. Content reads are bracketed
// by two REST records; no unbounded GraphQL lookup is used. Every GET reserves
// two attempts for OAuth replay: 2 * (2 * (fresh + prepare) + readback) + 1.
// File actions are bounded to two; whole-snippet deletion reads at most four
// files. Oversized operations refuse before reading any file content.
const List<AiCapability> aiSnippetRows = <AiCapability>[
  AiCapability(
    operationId: 'createSnippet',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    httpCap: 19, // fresh 1, prepare 2, readback 3.
    readback: true,
    arguments: {
      'projectId': _projectId,
      'title': _requiredPlain,
      'description': _snippetDescription,
      'visibility': _plain,
      'path': _requiredPathOrRef,
      'content': AiArgSpec(AiArgType.string, required: true,
          text: AiTextRole.fullNewContent),
    },
  ),
  AiCapability(
    operationId: 'updateSnippetMetadata',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    httpCap: 19, // fresh 1, prepare 3, readback 1.
    readback: true,
    editableField: 'description',
    arguments: {
      ..._snippetId,
      'fields': AiArgSpec(AiArgType.object, required: true, properties: {
        'title': _plain,
        'description': _snippetDescription,
        'visibility': _plain,
      }),
    },
  ),
  AiCapability(
    operationId: 'updateSnippet',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    httpCap: 31, // fresh 1, prepare 5, readback 3.
    readback: true,
    arguments: {
      ..._snippetId,
      'edits': AiArgSpec(AiArgType.edits, required: true,
          text: AiTextRole.fragmentEdits),
    },
  ),
  AiCapability(
    operationId: 'updateSnippetFiles',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    httpCap: 37, // fresh 1, prepare 6, readback 4 (two affected files).
    readback: true,
    arguments: {
      ..._snippetId,
      'actions': AiArgSpec(AiArgType.snippetActions, required: true, properties: {
        'action': _requiredString,
        'file_path': _requiredPathOrRef,
        'previous_path': AiArgSpec(AiArgType.string, text: AiTextRole.pathOrRef),
        'content': AiArgSpec(AiArgType.string, text: AiTextRole.fullNewContent),
        'edits': AiArgSpec(AiArgType.edits, text: AiTextRole.fragmentEdits),
      }),
    },
  ),
  AiCapability(
    operationId: 'deleteSnippetFile',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    httpCap: 27, // fresh 1, prepare 5, readback 1.
    readback: true,
    arguments: {..._snippetId, 'path': _requiredPathOrRef},
  ),
  AiCapability(
    operationId: 'deleteSnippet',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    httpCap: 37, // fresh 1, prepare 8 (four affected files), no readback.
    arguments: _snippetId,
  ),
];
