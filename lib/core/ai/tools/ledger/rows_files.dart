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
// Each pass also has the coordinator's uncached project freshness GET.
// edit: 2 * (freshness + user + project + branch + metadata + text HEAD/raw)
//       * 2 + mutation + (metadata + text HEAD/raw) * 2 = 35.
// create: 2 * (freshness + user + project + branch + metadata) * 2
//         + mutation + 3 * 2 = 27.
// delete: 2 * (freshness + 6 prepare reads) * 2 + mutation = 29;
//         204 is acknowledgement, no ambiguous 404 proof.
// suggestions: 2 * (freshness + user + project + MR + branch + discussions)
//              * 2 + mutation + discussions * 2; at most 20 discussions.
const List<AiCapability> aiFileRows = <AiCapability>[
  AiCapability(
    operationId: 'edit_file',
    namedMethod: 'updateRepositoryFile',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    httpCap: 35,
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
    modelVisible: true,
    httpCap: 27,
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
    modelVisible: true,
    httpCap: 29,
    arguments: _fileCoordinates,
  ),
  AiCapability(
    operationId: 'applySuggestion',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: true,
    httpCap: 27,
    readback: true,
    arguments: {..._suggestionCoordinates, ..._suggestionItem},
  ),
  AiCapability(
    operationId: 'batchApplySuggestions',
    baseTier: AiWriteTier.t3,
    scopeClass: AiScopeClass.mergeRequest,
    modelVisible: false,
    httpCap: 141,
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
