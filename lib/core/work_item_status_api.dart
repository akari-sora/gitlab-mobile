part of 'gitlab_api.dart';

ApiFailure get _statusReadForbidden => ApiFailure(
  FailureKind.forbidden,
  title: l10n.cannotReadWorkItemStatus,
  detail: l10n.noPermissionReadWorkItem,
);
ApiFailure get _statusWriteForbidden => ApiFailure(
  FailureKind.forbidden,
  title: l10n.noPermissionChangeItemStatus,
  detail: l10n.needReadAndSetMetadata,
);
ApiFailure get _statusUnsupported => ApiFailure(
  FailureKind.unsupported,
  title: l10n.cannotSafelyEditStatus,
  detail: l10n.statusWidgetUnavailable,
);
ApiFailure get _statusConflict => ApiFailure(
  FailureKind.conflict,
  title: l10n.workItemStatusChanged,
  detail: l10n.statusLifecycleScopeChanged,
);
ApiFailure get _statusInvalidCandidate => ApiFailure(
  FailureKind.validation,
  title: l10n.invalidStatusIdentifier,
  detail: l10n.chooseFromFullStatusList,
);
ApiFailure get _statusRejected => ApiFailure(
  FailureKind.validation,
  title: l10n.gitlabRejectedStatusUpdate,
  detail: l10n.reloadConfirmStatus,
);
ApiFailure get _statusSpent => ApiFailure(
  FailureKind.writeUncertain,
  title: l10n.statusEditAlreadyUsed,
  detail: l10n.closeAndReloadLatestStatus,
);
ApiFailure get _statusUncertain => ApiFailure(
  FailureKind.writeUncertain,
  title: l10n.statusUpdateUnconfirmed,
  detail: l10n.reloadItemDoNotResubmit,
);
const _statusCancelled = ApiFailure(FailureKind.cancelled);

const _workItemStatusFields = r'''
id
name
iconName
color
position
description
category
''';

final _workItemStatusQuery =
    '''
query MobileWorkItemStatus(\$id: WorkItemID!) {
  currentUser { id }
  workItem(id: \$id) {
    id
    iid
    title
    state
    createdAt
    updatedAt
    lockVersion
    project { id fullPath }
    namespace { id fullPath }
    workItemType {
      id
      name
      widgetDefinitions {
        type
        ... on WorkItemWidgetDefinitionStatus {
          allowedStatuses { $_workItemStatusFields }
        }
      }
    }
    userPermissions { readWorkItem setWorkItemMetadata }
    widgets(onlyTypes: [STATUS]) {
      type
      ... on WorkItemWidgetStatus {
        status { $_workItemStatusFields }
      }
    }
  }
}
'''
        .trim();

final _workItemStatusMutation =
    '''
mutation MobileUpdateWorkItemStatus(\$input: WorkItemUpdateInput!) {
  workItemUpdate(input: \$input) {
    errors
    workItem {
      id
      iid
      state
      updatedAt
      project { id fullPath }
      namespace { id fullPath }
      workItemType { id }
      widgets(onlyTypes: [STATUS]) {
        type
        ... on WorkItemWidgetStatus {
          status { $_workItemStatusFields }
        }
      }
    }
  }
}
'''
        .trim();

final class WorkItemStatusAccess {
  const WorkItemStatusAccess._({
    required this.snapshot,
    required this.canWrite,
    required this.target,
  });

  final WorkItemStatusSnapshot snapshot;
  final bool canWrite;
  final WorkItemStatusTarget? target;
}

/// Single-use exact STATUS capability. Only [workItemStatus] can create one.
final class WorkItemStatusTarget {
  WorkItemStatusTarget._({
    required GitLabApi owner,
    required WorkItemGraphSummary expected,
    required this.opening,
  }) : _owner = owner,
       _expected = expected,
       _handoffEpoch = opening.readEpoch;

  final GitLabApi _owner;
  final WorkItemGraphSummary _expected;
  final int _handoffEpoch;
  final WorkItemStatusSnapshot opening;
  bool _consumed = false;

  bool get consumed => _consumed;
}

extension WorkItemStatusApi on GitLabApi {
  /// Reads one exact STATUS widget and its complete, non-paginated definition.
  Future<WorkItemStatusAccess> workItemStatus(
    WorkItemGraphDetail detail, {
    required int expectedUserId,
    required int generation,
    bool Function()? isCurrent,
  }) async {
    _requireStrictGroupOwnerApi(this, detail.summary.strictGroupOwner);
    _validateStatusExpected(detail.summary, expectedUserId, generation);
    final loaded = await _readWorkItemStatus(
      detail.summary,
      expectedUserId: expectedUserId,
      generation: generation,
      isCurrent: isCurrent,
    );
    final snapshot = loaded.snapshot;
    final writable =
        snapshot.readWorkItem &&
        snapshot.setWorkItemMetadata &&
        snapshot.assignment.kind != WorkItemStatusAssignmentKind.unidentified;
    return WorkItemStatusAccess._(
      snapshot: snapshot,
      canWrite: writable,
      target: writable
          ? WorkItemStatusTarget._(
              owner: this,
              expected: loaded.summary,
              opening: snapshot,
            )
          : null,
    );
  }

  /// Consumes [target] synchronously, performs one exact fresh preflight, sends
  /// at most one status-only mutation, then requires an independent readback.
  Future<WorkItemStatusSaveResult> updateWorkItemStatus(
    WorkItemStatusTarget target, {
    required String candidateId,
    required WorkItemStatusMutationSent onMutationSent,
    bool Function()? isCurrent,
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    if (target._consumed) {
      throw WorkItemStatusWriteFailure(
        failure: _statusSpent,
        mutationSent: false,
        handoff: WorkItemStatusHandoff.none,
      );
    }
    target._consumed = true;

    try {
      _requireStatusPreflightOwner(this, target, isCurrent);
    } on ApiFailure catch (failure) {
      throw _statusWriteFailure(failure);
    }

    final ({WorkItemGraphSummary summary, WorkItemStatusSnapshot snapshot}) fresh;
    try {
      fresh = await _readWorkItemStatus(
        target._expected,
        expectedUserId: target.opening.expectedUserId,
        generation: target.opening.generation,
        isCurrent: isCurrent,
      );
      _requireStatusPreflightOwner(this, target, isCurrent);
      _rejectStatusFence(fresh.snapshot, target.opening);
      if (!_validOpaqueGraphId(candidateId) ||
          !fresh.snapshot.allowedStatusIds.contains(candidateId)) {
        throw _statusInvalidCandidate;
      }
    } on ApiFailure catch (failure) {
      throw _statusWriteFailure(failure);
    } on Object {
      throw _statusWriteFailure(_statusUnsupported);
    }

    if (fresh.snapshot.assignment.id == candidateId) {
      return WorkItemStatusSaveResult(
        status: WorkItemStatusSaveStatus.noop,
        snapshot: fresh.snapshot,
        acknowledgement: null,
        mutationSent: false,
        handoff: WorkItemStatusHandoff.none,
      );
    }

    try {
      _requireStatusPreflightOwner(this, target, isCurrent);
    } on ApiFailure catch (failure) {
      throw _statusWriteFailure(failure);
    }

    if (beforeMutation != null) await beforeMutation();

    var handoff = WorkItemStatusHandoff.none;
    var reportedStart = false;
    void started(Object operationToken) {
      if (reportedStart) {
        throw StateError('STATUS mutation START reported twice');
      }
      reportedStart = true;
      handoff = WorkItemStatusHandoff.started;
    }

    try {
      onMutationSent(started);
      if (!reportedStart) {
        throw StateError('STATUS mutation START was not reported');
      }
    } on Object {
      throw WorkItemStatusWriteFailure(
        failure: _statusCancelled,
        mutationSent: false,
        handoff: handoff,
      );
    }

    if (mayStart != null && !mayStart()) {
      throw WorkItemStatusWriteFailure(
        failure: _statusCancelled,
        mutationSent: false,
        handoff: handoff,
      );
    }

    final ({Uint8List bytes, Headers headers, int statusCode}) response;
    var didSend = false;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        onSendStarted: () => didSend = true,
        data: {
          'query': _workItemStatusMutation,
          'variables': {
            'input': <String, Object?>{
              'id': fresh.snapshot.id,
              'statusWidget': <String, Object?>{'status': candidateId},
            },
          },
        },
      );
    } on Object catch (error) {
      if (_graphDefinitelyNotSent(error, didSend)) {
        throw WorkItemStatusWriteFailure(
          failure: error as ApiFailure,
          mutationSent: false,
          handoff: handoff,
        );
      }
      throw WorkItemStatusWriteFailure(
        failure: didSend ? _statusUncertain : _statusCancelled,
        mutationSent: didSend,
        handoff: handoff,
      );
    }

    final WorkItemStatusAcknowledgement acknowledgement;
    try {
      _requireStatusOwner(this, target, isCurrent);
      acknowledgement = _parseStatusAcknowledgement(
        response.bytes,
        target,
      );
      _requireStatusOwner(this, target, isCurrent);
      if (acknowledgement.updatedAt.isBefore(target.opening.updatedAt)) {
        throw _statusUncertain;
      }
      final acknowledgedDesired =
          acknowledgement.assignment.kind ==
              WorkItemStatusAssignmentKind.identified &&
          acknowledgement.assignment.id == candidateId;
      if (!acknowledgedDesired &&
          !_sameStatusAcknowledgementAsOpening(
            acknowledgement,
            target.opening,
          )) {
        throw _statusUncertain;
      }
    } on ApiFailure catch (failure) {
      if (target._expected.strictGroupOwner == null &&
          failure.kind == FailureKind.validation) {
        throw WorkItemStatusWriteFailure(
          failure: failure,
          mutationSent: true,
          handoff: handoff,
        );
      }
      throw WorkItemStatusWriteFailure(
        failure: _statusUncertain,
        mutationSent: true,
        handoff: handoff,
      );
    } on Object {
      throw WorkItemStatusWriteFailure(
        failure: _statusUncertain,
        mutationSent: true,
        handoff: handoff,
      );
    }

    final WorkItemStatusSnapshot confirmed;
    try {
      _requireStatusOwner(this, target, isCurrent);
      final readback = await _readWorkItemStatus(
        target._expected,
        expectedUserId: target.opening.expectedUserId,
        generation: target.opening.generation,
        isCurrent: isCurrent,
      );
      _requireStatusOwner(this, target, isCurrent);
      confirmed = readback.snapshot;
    } on Object {
      throw WorkItemStatusWriteFailure(
        failure: _statusUncertain,
        mutationSent: true,
        handoff: handoff,
      );
    }

    final applied =
        acknowledgement.assignment.kind ==
            WorkItemStatusAssignmentKind.identified &&
        acknowledgement.assignment.id == candidateId &&
        confirmed.assignment.kind == WorkItemStatusAssignmentKind.identified &&
        confirmed.assignment.id == candidateId &&
        confirmed.updatedAt == acknowledgement.updatedAt &&
        confirmed.state == acknowledgement.state &&
        _sameStatusOwner(confirmed, target.opening);
    if (applied) {
      return WorkItemStatusSaveResult(
        status: WorkItemStatusSaveStatus.success,
        snapshot: confirmed,
        acknowledgement: acknowledgement,
        mutationSent: true,
        handoff: handoff,
      );
    }

    if (_sameStatusAcknowledgementAsOpening(
          acknowledgement,
          target.opening,
        ) &&
        _sameStatusFence(confirmed, target.opening)) {
      return WorkItemStatusSaveResult(
        status: WorkItemStatusSaveStatus.notApplied,
        snapshot: confirmed,
        acknowledgement: acknowledgement,
        mutationSent: true,
        handoff: handoff,
      );
    }

    throw WorkItemStatusWriteFailure(
      failure: _statusUncertain,
      mutationSent: true,
      handoff: handoff,
    );
  }

  Future<({WorkItemGraphSummary summary, WorkItemStatusSnapshot snapshot})>
  _readWorkItemStatus(
    WorkItemGraphSummary expected, {
    required int expectedUserId,
    required int generation,
    required bool Function()? isCurrent,
  }) async {
    _requireCurrentWorkItemRequest(isCurrent);
    if (isClosed) throw _statusCancelled;
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _workItemStatusQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    if (isClosed) throw _statusCancelled;
    try {
      final data = _statusGraphData(response.bytes);
      final actorId = _requiredStatusActor(data, expectedUserId);
      if (data['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final node = objectJson(data['workItem']);
      final summary = _parseWorkItemSummary(
        node,
        strictGroupOwner: expected.strictGroupOwner,
      );
      if (!_sameStatusIdentity(summary, expected)) {
        throw const FormatException('Wrong STATUS work item identity');
      }
      final permissions = node['userPermissions'];
      if (permissions is! Map ||
          !permissions.containsKey('readWorkItem') ||
          !permissions.containsKey('setWorkItemMetadata')) {
        throw const FormatException('Missing STATUS permissions');
      }
      final readWorkItem = permissions['readWorkItem'];
      final setMetadata = permissions['setWorkItemMetadata'];
      if (readWorkItem is! bool || setMetadata is! bool) {
        throw const FormatException('Invalid STATUS permissions');
      }
      if (!readWorkItem) throw _statusReadForbidden;
      final lockVersion = node['lockVersion'];
      if (lockVersion is! int || lockVersion < 0) {
        throw const FormatException('Invalid STATUS lock version');
      }
      final assignment = _parseStatusAssignment(node['widgets']);
      final statuses = _parseAllowedStatuses(node['workItemType']);
      return (
        summary: summary,
        snapshot: WorkItemStatusSnapshot(
          accountKey: '${instance.key}#$expectedUserId',
          actorId: actorId,
          expectedUserId: expectedUserId,
          generation: generation,
          readEpoch: _readEpoch,
          id: summary.id,
          iid: summary.iid,
          project: summary.project,
          namespace: summary.namespace,
          typeId: summary.type.id,
          updatedAt: summary.updatedAt,
          lockVersion: lockVersion,
          state: _parseWorkItemState(summary.state),
          assignment: assignment,
          allowedStatuses: statuses,
          readWorkItem: readWorkItem,
          setWorkItemMetadata: setMetadata,
        ),
      );
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw _statusUnsupported;
    }
  }
}

void _validateStatusExpected(
  WorkItemGraphSummary expected,
  int expectedUserId,
  int generation,
) {
  if (expectedUserId <= 0 || generation < 0) {
    throw const ApiFailure(FailureKind.validation);
  }
  _validateExpectedWorkItemStateIdentity(expected);
}

void _requireStatusOwner(
  GitLabApi api,
  WorkItemStatusTarget target,
  bool Function()? isCurrent,
) {
  if (!identical(api, target._owner)) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (api.isClosed || (isCurrent != null && !isCurrent())) {
    throw _statusCancelled;
  }
}

void _requireStatusPreflightOwner(
  GitLabApi api,
  WorkItemStatusTarget target,
  bool Function()? isCurrent,
) {
  _requireStatusOwner(api, target, isCurrent);
  if (api._readEpoch != target._handoffEpoch) throw _statusCancelled;
}

WorkItemStatusWriteFailure _statusWriteFailure(ApiFailure failure) =>
    WorkItemStatusWriteFailure(
      failure: failure,
      mutationSent: false,
      handoff: WorkItemStatusHandoff.none,
    );

void _rejectStatusFence(
  WorkItemStatusSnapshot fresh,
  WorkItemStatusSnapshot opening,
) {
  if (!_sameStatusOwner(fresh, opening)) throw _statusCancelled;
  if (!_sameStatusFence(fresh, opening)) throw _statusConflict;
  if (!fresh.readWorkItem || !fresh.setWorkItemMetadata) {
    throw _statusWriteForbidden;
  }
}

bool _sameStatusOwner(
  WorkItemStatusSnapshot left,
  WorkItemStatusSnapshot right,
) =>
    left.accountKey == right.accountKey &&
    left.actorId == right.actorId &&
    left.expectedUserId == right.expectedUserId &&
    left.generation == right.generation &&
    left.id == right.id &&
    left.iid == right.iid &&
    left.typeId == right.typeId &&
    _sameAttributeRef(left.project, right.project) &&
    _sameAttributeRef(left.namespace, right.namespace);

bool _sameStatusFence(
  WorkItemStatusSnapshot left,
  WorkItemStatusSnapshot right,
) =>
    _sameStatusOwner(left, right) &&
    left.updatedAt == right.updatedAt &&
    left.lockVersion == right.lockVersion &&
    left.state == right.state &&
    left.readWorkItem == right.readWorkItem &&
    left.setWorkItemMetadata == right.setWorkItemMetadata &&
    _sameStatusAssignment(left.assignment, right.assignment) &&
    _sameOrderedStrings(left.allowedStatusIds, right.allowedStatusIds);

bool _sameStatusAcknowledgementAsOpening(
  WorkItemStatusAcknowledgement acknowledgement,
  WorkItemStatusSnapshot opening,
) =>
    acknowledgement.accountKey == opening.accountKey &&
    acknowledgement.actorId == opening.actorId &&
    acknowledgement.expectedUserId == opening.expectedUserId &&
    acknowledgement.generation == opening.generation &&
    acknowledgement.id == opening.id &&
    acknowledgement.iid == opening.iid &&
    acknowledgement.typeId == opening.typeId &&
    _sameAttributeRef(acknowledgement.project, opening.project) &&
    _sameAttributeRef(acknowledgement.namespace, opening.namespace) &&
    acknowledgement.updatedAt == opening.updatedAt &&
    acknowledgement.state == opening.state &&
    _sameStatusAssignment(acknowledgement.assignment, opening.assignment);

bool _sameStatusAssignment(
  WorkItemStatusAssignment left,
  WorkItemStatusAssignment right,
) =>
    left.kind == right.kind && left.id == right.id;

bool _sameOrderedStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameStatusIdentity(
  WorkItemGraphSummary left,
  WorkItemGraphSummary right,
) =>
    left.id == right.id &&
    left.iid == right.iid &&
    left.type.id == right.type.id &&
    _sameAttributeRef(left.project, right.project) &&
    _sameAttributeRef(left.namespace, right.namespace);

WorkItemStatusAssignment _parseStatusAssignment(Object? rawWidgets) {
  if (rawWidgets is! List || rawWidgets.length != 1) {
    throw const FormatException('Missing or duplicate STATUS widget');
  }
  final widget = objectJson(rawWidgets.single);
  if (widget['type'] != 'STATUS' || !widget.containsKey('status')) {
    throw const FormatException('Invalid STATUS widget');
  }
  final raw = widget['status'];
  if (raw == null) return const WorkItemStatusAssignment.unassigned();
  final record = _parseStatusRecord(raw, requireId: false);
  return record.id == null
      ? WorkItemStatusAssignment.unidentified(record)
      : WorkItemStatusAssignment.identified(record);
}

List<WorkItemStatusRecord> _parseAllowedStatuses(Object? rawType) {
  final type = objectJson(rawType);
  final rawDefinitions = type['widgetDefinitions'];
  if (rawDefinitions is! List) {
    throw const FormatException('Missing STATUS definitions');
  }
  Json? found;
  for (final raw in rawDefinitions) {
    final definition = objectJson(raw);
    final definitionType = definition['type'];
    if (definitionType is! String) {
      throw const FormatException('Invalid widget definition type');
    }
    if (definitionType != 'STATUS') continue;
    if (found != null) {
      throw const FormatException('Duplicate STATUS definition');
    }
    found = definition;
  }
  if (found == null || !found.containsKey('allowedStatuses')) {
    throw const FormatException('Missing STATUS definition');
  }
  final rawStatuses = found['allowedStatuses'];
  if (rawStatuses is! List) {
    throw const FormatException('Invalid allowed STATUS list');
  }
  final statuses = <WorkItemStatusRecord>[];
  final ids = <String>{};
  for (final raw in rawStatuses) {
    final status = _parseStatusRecord(raw, requireId: true);
    if (!ids.add(status.id!)) {
      throw const FormatException('Duplicate allowed STATUS');
    }
    statuses.add(status);
  }
  return List<WorkItemStatusRecord>.unmodifiable(statuses);
}

WorkItemStatusRecord _parseStatusRecord(
  Object? raw, {
  required bool requireId,
}) {
  final status = objectJson(raw);
  const keys = {
    'id',
    'name',
    'iconName',
    'color',
    'position',
    'description',
    'category',
  };
  if (!keys.every(status.containsKey)) {
    throw const FormatException('Incomplete STATUS record');
  }
  final id = _statusOptionalText(status['id'], 512);
  if ((requireId && id == null) || (id != null && !_validOpaqueGraphId(id))) {
    throw const FormatException('Invalid STATUS identity');
  }
  final position = status['position'];
  if (position != null && position is! int) {
    throw const FormatException('Invalid STATUS position');
  }
  return WorkItemStatusRecord(
    id: id,
    name: _statusOptionalText(status['name'], 512),
    iconName: _statusOptionalText(status['iconName'], 256),
    color: _statusOptionalText(status['color'], 128),
    position: position as int?,
    description: _statusOptionalText(
      status['description'],
      GitLabApi.maxTextBytes,
    ),
    category: _statusOptionalText(status['category'], 128),
  );
}

String? _statusOptionalText(Object? raw, int maximum) {
  if (raw == null) return null;
  if (raw is! String ||
      raw.length > maximum ||
      raw.contains('\u0000') ||
      (maximum == GitLabApi.maxTextBytes &&
          utf8.encode(raw).length > GitLabApi.maxTextBytes)) {
    throw const FormatException('Invalid STATUS text');
  }
  return raw;
}

String _requiredStatusActor(Json data, int expectedUserId) {
  if (!data.containsKey('currentUser') || data['currentUser'] == null) {
    throw _statusUnsupported;
  }
  final actorId = _parseNotificationActor(data['currentUser']);
  if (actorId == null || _notificationActorNumber(actorId) != expectedUserId) {
    throw _statusCancelled;
  }
  return actorId;
}

WorkItemStatusAcknowledgement _parseStatusAcknowledgement(
  Uint8List bytes,
  WorkItemStatusTarget target,
) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final topErrors = envelope['errors'];
    if (topErrors != null) {
      if (topErrors is! List || topErrors.isNotEmpty) throw _statusUncertain;
    }
    final data = objectJson(envelope['data']);
    final payload = objectJson(data['workItemUpdate']);
    final rawErrors = payload['errors'];
    if (rawErrors is! List) throw _statusUncertain;
    final messages = <String>[];
    for (final raw in rawErrors) {
      if (raw is! String || raw.isEmpty) throw _statusUncertain;
      messages.add(raw);
    }
    if (messages.isNotEmpty) {
      throw ApiFailure(
        FailureKind.validation,
        title: _statusRejected.title,
        detail: messages.join('\n'),
      );
    }
    final node = objectJson(payload['workItem']);
    _requireStrictGroupWorkItemOwner(node, target._expected.strictGroupOwner);
    final id = requiredString(node, 'id');
    final iid = _positiveWorkItemInt(node['iid']);
    final project = _parseOptionalResourceRef(node['project']);
    final namespace = _parseOptionalResourceRef(node['namespace']);
    final type = objectJson(node['workItemType']);
    final typeId = requiredString(type, 'id');
    if (!_validOpaqueGraphId(id) || !_validOpaqueGraphId(typeId)) {
      throw _statusUncertain;
    }
    final acknowledgement = WorkItemStatusAcknowledgement(
      accountKey: target.opening.accountKey,
      actorId: target.opening.actorId,
      expectedUserId: target.opening.expectedUserId,
      generation: target.opening.generation,
      id: id,
      iid: iid,
      project: project,
      namespace: namespace,
      typeId: typeId,
      updatedAt: _workItemTimestamp(node['updatedAt']),
      state: _parseWorkItemState(node['state']),
      assignment: _parseStatusAssignment(node['widgets']),
    );
    if (acknowledgement.id != target.opening.id ||
        acknowledgement.iid != target.opening.iid ||
        acknowledgement.typeId != target.opening.typeId ||
        !_sameAttributeRef(
          acknowledgement.project,
          target.opening.project,
        ) ||
        !_sameAttributeRef(
          acknowledgement.namespace,
          target.opening.namespace,
        )) {
      throw _statusUncertain;
    }
    return acknowledgement;
  } on ApiFailure {
    rethrow;
  } on Object {
    throw _statusUncertain;
  }
}

Json _statusGraphData(Uint8List bytes) {
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
        throw unsupported
            ? _statusUnsupported
            : const ApiFailure(FailureKind.invalidResponse);
      }
    }
    return objectJson(envelope['data']);
  } on ApiFailure {
    rethrow;
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}
