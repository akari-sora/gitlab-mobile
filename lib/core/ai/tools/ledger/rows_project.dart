part of '../write_ledger.dart';

// Caps include two freshness/preparation passes, one mutation and independent
// readback; every logical GET reserves its single OAuth replay. File lists are
// bounded to three pages. Prefix locks deliberately cover child resources.
const List<AiCapability> aiProjectRows = <AiCapability>[
  AiCapability(
    operationId: 'deletePackage',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'packageId': _projectId},
    httpCap: 19, // 2 * (2 * (fresh 1 + prepare 3) + readback 1) + 1.
    readback: true,
  ),
  AiCapability(
    operationId: 'deletePackageFile',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'packageId': _projectId,
      'fileId': _projectId,
    },
    httpCap: 35, // 2 * (2 * (fresh 1 + prepare 6) + readback 3) + 1.
    readback: true,
  ),
  AiCapability(
    operationId: 'deleteContainerRepository',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId, 'repositoryId': _projectId},
    httpCap: 23, // 2 * (2 * (fresh 1 + prepare 4) + readback 1) + 1.
    readback: true,
  ),
  AiCapability(
    operationId: 'deleteContainerTag',
    baseTier: AiWriteTier.t4,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'repositoryId': _projectId,
      'tag': _requiredPathOrRef,
    },
    httpCap: 27, // 2 * (2 * (fresh 1 + prepare 5) + readback 1) + 1.
    readback: true,
  ),
  AiCapability(
    operationId: 'createProject',
    baseTier: AiWriteTier.hardLine,
    scopeClass: AiScopeClass.personalNamespace,
    modelVisible: true,
    arguments: {
      'name': _requiredPlain,
      'path': _requiredPathOrRef,
      'description': _rendered,
    },
    httpCap: 7, // 2 * (2 * prepare 1 + readback 1) + 1.
    readback: true,
  ),
  AiCapability(
    operationId: 'editProject',
    baseTier: AiWriteTier.hardLine,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {
      'projectId': _projectId,
      'name': _plain,
      'description': _rendered,
    },
    httpCap: 15, // 2 * (2 * (fresh 1 + prepare 2) + readback 1) + 1.
    readback: true,
  ),
  AiCapability(
    operationId: 'deleteProject',
    baseTier: AiWriteTier.hardLine,
    scopeClass: AiScopeClass.project,
    modelVisible: true,
    arguments: {'projectId': _projectId},
    httpCap: 15,
    readback: true,
  ),
  AiCapability(
    operationId: 'forkProject',
    baseTier: AiWriteTier.hardLine,
    scopeClass: AiScopeClass.personalNamespace,
    modelVisible: true,
    arguments: {'projectId': _projectId},
    httpCap: 15,
    readback: true,
  ),
];
