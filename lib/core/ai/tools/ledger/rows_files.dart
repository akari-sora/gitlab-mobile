part of '../write_ledger.dart';

const _fileCoordinates = <String, AiArgSpec>{
  'projectId': _projectId,
  'branch': _requiredPathOrRef,
  'path': _requiredPathOrRef,
  'commitMessage': AiArgSpec(
    AiArgType.string,
    required: true,
    text: AiTextRole.commitMessage,
  ),
};
const _suggestionCoordinates = <String, AiArgSpec>{
  'projectId': _projectId,
  'iid': _iid,
  'commitMessage': AiArgSpec(
    AiArgType.string,
    text: AiTextRole.commitMessage,
  ),
};
const _suggestionItem = <String, AiArgSpec>{
  'discussionId': _requiredString,
  'noteId': _projectId,
  'suggestionId': _projectId,
};

// Reads reserve two HTTP requests each for OAuth replay, including the HEAD
// and raw GET inside textFile. Count both prepares with cold immutable caches.
// edit: 2 * (user + project + branch + metadata + text HEAD/raw) * 2
//       + mutation + (metadata + text HEAD/raw) * 2 = 31.
// create: 2 * (user + project + branch + metadata) * 2 + 1 + 3 * 2 = 23.
// delete: 2 * 6 * 2 + 1 = 25; 204 is acknowledgement, no ambiguous 404 proof.
// suggestions: 2 * (user + project + MR + branch + discussions) * 2
//              + mutation + discussions * 2; at most 20 distinct discussions.
const List<AiCapability> aiFileRows = <AiCapability>[
  AiCapability(
    operationId: 'edit_file',
    namedMethod: 'updateRepositoryFile',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.project,
    modelVisible: false,
    httpCap: 31,
    readback: true,
    arguments: {
      ..._fileCoordinates,
      'edits': AiArgSpec(
        AiArgType.edits,
        required: true,
        text: AiTextRole.fragmentEdits,
      ),
    },
  ),
  AiCapability(
    operationId: 'createFile',
    namedMethod: 'createRepositoryFile',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.project,
    modelVisible: false,
    httpCap: 23,
    readback: true,
    arguments: {
      ..._fileCoordinates,
      'content': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.fullNewContent,
      ),
    },
  ),
  AiCapability(
    operationId: 'deleteFile',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: false,
    httpCap: 25,
    arguments: _fileCoordinates,
  ),
  AiCapability(
    operationId: 'applySuggestion',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 23,
    readback: true,
    arguments: {..._suggestionCoordinates, ..._suggestionItem},
  ),
  AiCapability(
    operationId: 'batchApplySuggestions',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 137,
    readback: true,
    arguments: {
      ..._suggestionCoordinates,
      'suggestions': AiArgSpec(
        AiArgType.suggestionList,
        required: true,
        properties: _suggestionItem,
      ),
    },
  ),
];
