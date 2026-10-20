part of 'gitlab_api.dart';

const _workItemStateQuery = r'''
query MobileWorkItemState($id: WorkItemID!) {
  workItem(id: $id) {
    id
    iid
    state
    updatedAt
    project { id fullPath }
    namespace { id fullPath }
    workItemType { id }
    userPermissions { updateWorkItem }
  }
}
''';

const _workItemStateMutation = r'''
mutation MobileUpdateWorkItemState($input: WorkItemUpdateInput!) {
  workItemUpdate(input: $input) {
    errors
    workItem {
      id
      iid
      state
      updatedAt
      project { id fullPath }
      namespace { id fullPath }
      workItemType { id }
    }
  }
}
''';

extension WorkItemStateApi on GitLabApi {
  /// Reads lifecycle and permission separately from the detail query so older
  /// GitLab schemas keep their existing read-only fallback.
  Future<WorkItemStateSnapshot> workItemState(
    WorkItemGraphSummary expected, {
    bool Function()? isCurrent,
  }) async {
    _validateExpectedWorkItemStateIdentity(expected);
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _workItemStateQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemStateGraphData(response.bytes, mutation: false);
      if (data['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      return _parseWorkItemStateSnapshot(
        data['workItem'],
        expected,
        requirePermission: true,
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// Performs a fresh permission/identity/state preflight, at most one
  /// mutation, then an independent readback. A write is never replayed.
  Future<WorkItemStateSnapshot> updateWorkItemState(
    WorkItemGraphSummary expected,
    WorkItemStateEvent event, {
    required DateTime expectedUpdatedAt,
    bool Function()? isCurrent,
  }) async {
    _validateExpectedWorkItemStateIdentity(expected);
    _requireCurrentWorkItemRequest(isCurrent);
    final before = await workItemState(expected, isCurrent: isCurrent);
    _requireCurrentWorkItemRequest(isCurrent);
    final expectedState = _parseWorkItemState(expected.state);
    if (before.updatedAt != expectedUpdatedAt.toUtc() ||
        before.updatedAt != expected.updatedAt.toUtc() ||
        before.state != expectedState) {
      throw const ApiFailure(FailureKind.conflict);
    }
    if (!before.canUpdate) {
      throw ApiFailure(
        FailureKind.forbidden,
        title: l10n.cannotChangeWorkItemState,
        detail: l10n.noPermissionUpdateWorkItem,
      );
    }
    if (before.state == event.result) return before;

    // This check is intentionally adjacent to the only write.
    _requireCurrentWorkItemRequest(isCurrent);
    final ({Uint8List bytes, Headers headers, int statusCode}) response;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': _workItemStateMutation,
          'variables': {
            'input': {'id': before.id, 'stateEvent': event.apiValue},
          },
        },
      );
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.redirectBlocked ||
          failure.kind == FailureKind.cancelled) {
        rethrow;
      }
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    try {
      final data = _workItemStateGraphData(response.bytes, mutation: true);
      final payload = objectJson(data['workItemUpdate']);
      final errors = payload['errors'];
      if (errors is! List || errors.any((error) => error is! String)) {
        throw const FormatException('Invalid work item mutation errors');
      }
      if (errors.isNotEmpty) {
        throw ApiFailure(
          FailureKind.validation,
          title: l10n.gitlabRejectedStateChange,
          detail: l10n.reloadConfirmCanUpdate,
        );
      }
      if (payload['workItem'] == null) {
        throw const FormatException('Missing work item acknowledgement');
      }
      final changed = _parseWorkItemStateSnapshot(
        payload['workItem'],
        expected,
        requirePermission: false,
      );
      if (changed.state != event.result || changed.id != before.id) {
        throw const FormatException('Wrong work item acknowledgement');
      }
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.validation ||
          failure.kind == FailureKind.unsupported) {
        rethrow;
      }
      throw const ApiFailure(FailureKind.writeUncertain);
    } on FormatException {
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final readback = await workItemState(expected, isCurrent: isCurrent);
      if (readback.id != before.id || readback.state != event.result) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      return readback;
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.cancelled) rethrow;
      throw const ApiFailure(FailureKind.writeUncertain);
    }
  }
}

Json _workItemStateGraphData(Uint8List bytes, {required bool mutation}) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors != null) {
      if (errors is! List) throw const FormatException('Invalid errors');
      if (errors.isNotEmpty) {
        final unsupported = errors.every(
          (error) =>
              error is Map &&
              error['extensions'] is Map &&
              _workItemSchemaErrors.contains(
                (error['extensions'] as Map)['code'],
              ),
        );
        if (unsupported) {
          throw ApiFailure(
            FailureKind.unsupported,
            title: l10n.instanceNoWorkItemStateActions,
            detail: l10n.noSafeCloseReopenFlow,
          );
        }
        throw ApiFailure(
          mutation ? FailureKind.writeUncertain : FailureKind.invalidResponse,
        );
      }
    }
    return objectJson(envelope['data']);
  } on FormatException {
    throw ApiFailure(
      mutation ? FailureKind.writeUncertain : FailureKind.invalidResponse,
    );
  }
}

void _validateExpectedWorkItemStateIdentity(WorkItemGraphSummary expected) {
  if (!_validOpaqueGraphId(expected.id) ||
      expected.iid <= 0 ||
      !_validOpaqueGraphId(expected.type.id) ||
      (expected.project == null && expected.namespace == null)) {
    throw const ApiFailure(FailureKind.validation);
  }
  try {
    _parseWorkItemState(expected.state);
  } on FormatException {
    throw const ApiFailure(FailureKind.validation);
  }
  for (final ref in [expected.project, expected.namespace]) {
    if (ref != null &&
        (!_validOpaqueGraphId(ref.id) ||
            _validatedNamespacePathOrNull(ref.fullPath) == null)) {
      throw const ApiFailure(FailureKind.validation);
    }
  }
}

WorkItemStateSnapshot _parseWorkItemStateSnapshot(
  Object? raw,
  WorkItemGraphSummary expected, {
  required bool requirePermission,
}) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  final iid = _positiveWorkItemInt(node['iid']);
  final state = _parseWorkItemState(node['state']);
  final updatedAt = _workItemTimestamp(node['updatedAt']);
  final project = _parseOptionalResourceRef(node['project']);
  final namespace = _parseOptionalResourceRef(node['namespace']);
  final typeNode = objectJson(node['workItemType']);
  final typeId = requiredString(typeNode, 'id');
  if (!_validOpaqueGraphId(typeId)) {
    throw const FormatException('Invalid work item type identity');
  }
  bool canUpdate = false;
  if (requirePermission) {
    final permissions = objectJson(node['userPermissions']);
    final permission = permissions['updateWorkItem'];
    if (permission is! bool) {
      throw const FormatException('Invalid work item permission');
    }
    canUpdate = permission;
  }
  if (id != expected.id ||
      iid != expected.iid ||
      typeId != expected.type.id ||
      !_sameWorkItemRef(project, expected.project) ||
      !_sameWorkItemRef(namespace, expected.namespace)) {
    throw const FormatException('Wrong work item state identity');
  }
  return WorkItemStateSnapshot(
    id: id,
    iid: iid,
    state: state,
    updatedAt: updatedAt,
    project: project,
    namespace: namespace,
    typeId: typeId,
    canUpdate: canUpdate,
  );
}

WorkItemState _parseWorkItemState(Object? raw) => switch (raw) {
  'OPEN' => WorkItemState.open,
  'CLOSED' => WorkItemState.closed,
  _ => throw const FormatException('Unknown work item state'),
};

bool _sameWorkItemRef(GraphResourceRef? left, GraphResourceRef? right) =>
    left?.id == right?.id && left?.fullPath == right?.fullPath;
