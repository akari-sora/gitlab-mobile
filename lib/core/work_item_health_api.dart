part of 'gitlab_api.dart';

ApiFailure get _healthReadForbidden => ApiFailure(
  FailureKind.forbidden,
  title: l10n.cannotReadWorkItemHealth,
  detail: l10n.noPermissionReadWorkItem,
);

ApiFailure get _healthWriteForbidden => ApiFailure(
  FailureKind.forbidden,
  title: l10n.cannotChangeHealthStatus,
  detail: l10n.noPermissionManageHealth,
);

ApiFailure get _healthUnsupported => ApiFailure(
  FailureKind.unsupported,
  title: l10n.instanceNoHealthStatusEdit,
  detail: l10n.noSafeHealthStatusWidget,
);

ApiFailure get _healthConflict => ApiFailure(
  FailureKind.conflict,
  title: l10n.healthStatusHasChanged,
  detail: l10n.reloadLatestBeforeSetting,
);

ApiFailure get _healthUncertain => ApiFailure(
  FailureKind.writeUncertain,
  title: l10n.healthUpdateUnconfirmed,
  detail: l10n.reloadItemDoNotResubmit,
);

const _healthInvalid = ApiFailure(FailureKind.invalidResponse);
const _healthCancelled = ApiFailure(FailureKind.cancelled);
const _healthValidation = ApiFailure(FailureKind.validation);

final _workItemHealthEditQuery =
    r'''
query MobileWorkItemHealthEdit($id: WorkItemID!) {
  currentUser { id }
  workItem(id: $id) {
    id
    iid
    title
    state
    createdAt
    updatedAt
    project { id fullPath }
    namespace { id fullPath }
    workItemType { id name }
    userPermissions { readWorkItem adminWorkItem }
    widgets(onlyTypes: [HEALTH_STATUS]) {
      type
      ... on WorkItemWidgetHealthStatus {
        healthStatus
        rolledUpHealthStatus { healthStatus count }
      }
    }
  }
}
'''
        .trim();

final _workItemHealthEditMutation =
    r'''
mutation MobileSetWorkItemHealthStatus($input: WorkItemUpdateInput!) {
  workItemUpdate(input: $input) {
    errors
    workItem {
      id
      updatedAt
      widgets(onlyTypes: [HEALTH_STATUS]) {
        type
        ... on WorkItemWidgetHealthStatus {
          healthStatus
        }
      }
    }
  }
}
'''
        .trim();

// The group-only acknowledgement requests ownership in the same mutation
// response. The ordinary UI query remains unchanged.
final _workItemHealthEditStrictMutation = _workItemHealthEditMutation.replaceFirst(
  '      id\n      updatedAt',
  '      id\n      iid\n      updatedAt\n      project { id fullPath }\n      namespace { id fullPath }',
);

final class WorkItemHealthEditAccess {
  const WorkItemHealthEditAccess._({
    required this.snapshot,
    required this.actorId,
    required this.canWrite,
    required this.target,
  });

  final WorkItemHealthEditSnapshot snapshot;
  final String actorId;
  final bool canWrite;
  final WorkItemHealthEditTarget? target;
}

final class WorkItemHealthEditTarget {
  WorkItemHealthEditTarget._({
    required GitLabApi owner,
    required String actorId,
    required int expectedUserId,
    required int generation,
    required WorkItemHealthEditSnapshot opening,
  }) : _owner = owner,
       _actorId = actorId,
       _expectedUserId = expectedUserId,
       _generation = generation,
       _opening = opening;

  final GitLabApi _owner;
  final String _actorId;
  final int _expectedUserId;
  final int _generation;
  final WorkItemHealthEditSnapshot _opening;
  bool _consumed = false;
}

final class WorkItemHealthEditSaveResult {
  const WorkItemHealthEditSaveResult({
    required this.status,
    required this.snapshot,
    required this.acknowledgedUpdatedAt,
    required this.mutationSent,
  });

  final WorkItemHealthEditSaveStatus status;
  final WorkItemHealthEditSnapshot snapshot;
  final DateTime? acknowledgedUpdatedAt;
  final bool mutationSent;
}

final class WorkItemHealthEditFailure implements Exception {
  const WorkItemHealthEditFailure(this.failure, this.mutationSent);

  final ApiFailure failure;
  final bool mutationSent;

  @override
  String toString() =>
      'WorkItemHealthEditFailure(${failure.kind.name}, '
      'mutationSent: $mutationSent)';
}

typedef _ParsedHealthWorkItem = ({
  WorkItemHealthEditSnapshot snapshot,
  bool readWorkItem,
  bool adminWorkItem,
});

typedef _HealthAcknowledgement = ({
  WorkItemHealthEditValue? value,
  DateTime updatedAt,
});

extension WorkItemHealthEditApi on GitLabApi {
  Future<WorkItemHealthEditAccess> workItemHealthEdit(
    WorkItemGraphDetail detail, {
    required int expectedUserId,
    required int generation,
    required bool Function() isCurrent,
  }) async {
    _requireStrictGroupOwnerApi(this, detail.summary.strictGroupOwner);
    _validateHealthExpected(detail, expectedUserId, generation);
    _requireHealthCurrent(this, isCurrent);
    return _readWorkItemHealth(
      detail.summary,
      expectedUserId: expectedUserId,
      generation: generation,
      isCurrent: isCurrent,
      requireRevision: true,
      conflictOnMismatch: false,
    );
  }

  Future<WorkItemHealthEditSaveResult> updateWorkItemHealthStatus(
    WorkItemHealthEditTarget target, {
    required WorkItemHealthEditValue? desired,
    required int generation,
    required bool Function() isCurrent,
    void Function()? onMutationSent,
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    if (target._consumed) {
      throw WorkItemHealthEditFailure(_healthUncertain, false);
    }
    target._consumed = true;
    if (generation < 0) {
      throw const WorkItemHealthEditFailure(_healthValidation, false);
    }
    try {
      _requireHealthUpdateOwner(this, target, generation, isCurrent);
    } on Object catch (error) {
      throw WorkItemHealthEditFailure(_healthPreflightFailure(error), false);
    }

    WorkItemHealthEditAccess before;
    try {
      before = await _readWorkItemHealth(
        target._opening.summary,
        expectedUserId: target._expectedUserId,
        generation: generation,
        isCurrent: isCurrent,
        requireRevision: true,
        conflictOnMismatch: true,
      );
      _requireHealthUpdateOwner(this, target, generation, isCurrent);
      if (before.actorId != target._actorId) throw _healthCancelled;
      if (!before.canWrite || before.target == null) {
        if (before.snapshot.availability !=
                WorkItemHealthEditAvailability.present ||
            !before.snapshot.healthStatusFieldPresent) {
          throw _healthUnsupported;
        }
        throw _healthWriteForbidden;
      }
      if (!_sameHealthSnapshot(before.snapshot, target._opening)) {
        throw _healthConflict;
      }
    } on Object catch (error) {
      throw WorkItemHealthEditFailure(_healthPreflightFailure(error), false);
    }

    if (before.snapshot.value == desired) {
      return WorkItemHealthEditSaveResult(
        status: WorkItemHealthEditSaveStatus.noop,
        snapshot: before.snapshot,
        acknowledgedUpdatedAt: null,
        mutationSent: false,
      );
    }

    final requestData = <String, Object?>{
      'query': target._opening.summary.strictGroupOwner == null
          ? _workItemHealthEditMutation
          : _workItemHealthEditStrictMutation,
      'variables': {
        'input': <String, Object?>{
          'id': before.snapshot.summary.id,
          'healthStatusWidget': <String, Object?>{
            'healthStatus': desired?.graphValue,
          },
        },
      },
    };
    try {
      _requireHealthUpdateOwner(this, target, generation, isCurrent);
    } on Object catch (error) {
      throw WorkItemHealthEditFailure(_healthPreflightFailure(error), false);
    }
    if (beforeMutation != null) await beforeMutation();
    try {
      onMutationSent?.call();
    } on Object {
      throw WorkItemHealthEditFailure(ApiFailure(FailureKind.cancelled), false);
    }
    if (mayStart != null && !mayStart()) {
      throw const WorkItemHealthEditFailure(_healthCancelled, false);
    }

    var didSend = false;
    try {
      final response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        onSendStarted: () => didSend = true,
        data: requestData,
      );

      _requireHealthUpdateOwner(this, target, generation, isCurrent);
      final acknowledgement = _parseHealthAcknowledgement(
        response.bytes,
        target._opening.summary,
      );
      final preflightRevision = before.snapshot.summary.updatedAt;

      _requireHealthUpdateOwner(this, target, generation, isCurrent);
      final readback = await _readWorkItemHealth(
        target._opening.summary,
        expectedUserId: target._expectedUserId,
        generation: generation,
        isCurrent: isCurrent,
        requireRevision: false,
        conflictOnMismatch: false,
      );
      _requireHealthUpdateOwner(this, target, generation, isCurrent);
      if (readback.actorId != target._actorId ||
          !readback.canWrite ||
          readback.target == null ||
          !_sameHealthStableIdentity(
            readback.snapshot.summary,
            target._opening.summary,
          ) ||
          readback.snapshot.availability !=
              WorkItemHealthEditAvailability.present ||
          !readback.snapshot.healthStatusFieldPresent ||
          readback.snapshot.summary.updatedAt != acknowledgement.updatedAt) {
        throw const FormatException('Health readback drift');
      }

      if (!acknowledgement.updatedAt.isBefore(preflightRevision) &&
          acknowledgement.value == desired &&
          readback.snapshot.value == desired) {
        return WorkItemHealthEditSaveResult(
          status: WorkItemHealthEditSaveStatus.success,
          snapshot: readback.snapshot,
          acknowledgedUpdatedAt: acknowledgement.updatedAt,
          mutationSent: true,
        );
      }
      if (acknowledgement.value == before.snapshot.value &&
          acknowledgement.updatedAt == preflightRevision &&
          readback.snapshot.value == before.snapshot.value &&
          readback.snapshot.summary.updatedAt == preflightRevision) {
        return WorkItemHealthEditSaveResult(
          status: WorkItemHealthEditSaveStatus.notApplied,
          snapshot: readback.snapshot,
          acknowledgedUpdatedAt: acknowledgement.updatedAt,
          mutationSent: true,
        );
      }
      throw const FormatException('Health update outcome drift');
    } on WorkItemHealthEditFailure {
      rethrow;
    } on _HealthPayloadValidation {
      if (target._opening.summary.strictGroupOwner != null) {
        throw WorkItemHealthEditFailure(_healthUncertain, true);
      }
      throw WorkItemHealthEditFailure(
        ApiFailure(
          FailureKind.validation,
          title: l10n.gitlabRejectedHealthUpdate,
          detail: l10n.reloadConfirmHealthStatus,
        ),
        true,
      );
    } on Object catch (error) {
      if (_graphDefinitelyNotSent(error, didSend)) {
        throw WorkItemHealthEditFailure(error as ApiFailure, false);
      }
      if (!didSend) {
        throw const WorkItemHealthEditFailure(_healthInvalid, false);
      }
      throw WorkItemHealthEditFailure(_healthUncertain, true);
    }
  }

  Future<WorkItemHealthEditAccess> _readWorkItemHealth(
    WorkItemGraphSummary expected, {
    required int expectedUserId,
    required int generation,
    required bool Function() isCurrent,
    required bool requireRevision,
    required bool conflictOnMismatch,
  }) async {
    if (generation < 0) throw _healthValidation;
    _requireHealthCurrent(this, isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _workItemHealthEditQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireHealthCurrent(this, isCurrent);
    try {
      final data = _healthGraphData(response.bytes);
      if (!data.containsKey('currentUser')) {
        throw const FormatException('Missing health actor');
      }
      final actorId = _parseNotificationActor(data['currentUser']);
      if (actorId == null) {
        throw ApiFailure(
          FailureKind.unauthenticated,
          title: l10n.signInNoLongerValid,
          detail: l10n.reconnectThenReadHealth,
        );
      }
      if (_notificationActorNumber(actorId) != expectedUserId) {
        throw _healthCancelled;
      }
      if (data['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final parsed = _parseHealthWorkItem(
        data['workItem'],
        expected,
        requireRevision: requireRevision,
      );
      if (!parsed.readWorkItem) throw _healthReadForbidden;
      final canWrite =
          parsed.adminWorkItem &&
          parsed.snapshot.availability ==
              WorkItemHealthEditAvailability.present &&
          parsed.snapshot.healthStatusFieldPresent;
      return WorkItemHealthEditAccess._(
        snapshot: parsed.snapshot,
        actorId: actorId,
        canWrite: canWrite,
        target: canWrite
            ? WorkItemHealthEditTarget._(
                owner: this,
                actorId: actorId,
                expectedUserId: expectedUserId,
                generation: generation,
                opening: parsed.snapshot,
              )
            : null,
      );
    } on _HealthExpectedConflict {
      throw conflictOnMismatch ? _healthConflict : _healthInvalid;
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw _healthInvalid;
    }
  }
}

final class _HealthPayloadValidation implements Exception {
  const _HealthPayloadValidation();
}

final class _HealthExpectedConflict implements Exception {
  const _HealthExpectedConflict();
}

void _validateHealthExpected(
  WorkItemGraphDetail detail,
  int expectedUserId,
  int generation,
) {
  _validateContentExpected(detail, expectedUserId);
  if (generation < 0) throw _healthValidation;
  if (!const {'OPEN', 'CLOSED'}.contains(detail.summary.state)) {
    throw _healthUnsupported;
  }
}

void _requireHealthCurrent(GitLabApi api, bool Function() isCurrent) {
  if (api.isClosed) throw _healthCancelled;
  try {
    final current = isCurrent();
    if (api.isClosed || !current) throw _healthCancelled;
  } on ApiFailure {
    rethrow;
  } on Object catch (error) {
    throw safeFailure(error);
  }
}

void _requireHealthUpdateOwner(
  GitLabApi api,
  WorkItemHealthEditTarget target,
  int generation,
  bool Function() isCurrent,
) {
  if (!identical(target._owner, api) ||
      generation != target._generation ||
      api.isClosed) {
    throw _healthCancelled;
  }
  _requireHealthCurrent(api, isCurrent);
}

ApiFailure _healthPreflightFailure(Object error) {
  final failure = safeFailure(error);
  if (failure.kind == FailureKind.invisible) return _healthConflict;
  return failure;
}

_ParsedHealthWorkItem _parseHealthWorkItem(
  Object? raw,
  WorkItemGraphSummary expected, {
  required bool requireRevision,
}) {
  final node = objectJson(raw);
  final summary = _parseWorkItemSummary(
    node,
    strictGroupOwner: expected.strictGroupOwner,
  );
  if (!_sameHealthStableIdentity(summary, expected) ||
      (requireRevision && summary.updatedAt != expected.updatedAt)) {
    throw const _HealthExpectedConflict();
  }
  if (!node.containsKey('userPermissions')) {
    throw const FormatException('Missing health permissions');
  }
  final permissions = objectJson(node['userPermissions']);
  if (!permissions.containsKey('readWorkItem') ||
      !permissions.containsKey('adminWorkItem')) {
    throw const FormatException('Missing health permission');
  }
  final readWorkItem = permissions['readWorkItem'];
  final adminWorkItem = permissions['adminWorkItem'];
  if (readWorkItem is! bool || adminWorkItem is! bool) {
    throw const FormatException('Invalid health permission');
  }
  final parsed = _parseHealthWidgets(node['widgets']);
  return (
    snapshot: WorkItemHealthEditSnapshot(
      summary: summary,
      availability: parsed.availability,
      healthStatusFieldPresent: parsed.fieldPresent,
      value: parsed.value,
      rolledUp: parsed.rolledUp,
    ),
    readWorkItem: readWorkItem,
    adminWorkItem: adminWorkItem,
  );
}

({
  WorkItemHealthEditAvailability availability,
  bool fieldPresent,
  WorkItemHealthEditValue? value,
  List<WorkItemHealthEditRollup>? rolledUp,
})
_parseHealthWidgets(Object? rawWidgets) {
  if (rawWidgets == null) {
    return (
      availability: WorkItemHealthEditAvailability.widgetsUnavailable,
      fieldPresent: false,
      value: null,
      rolledUp: null,
    );
  }
  if (rawWidgets is! List || rawWidgets.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid health widgets');
  }
  if (rawWidgets.isEmpty) {
    return (
      availability: WorkItemHealthEditAvailability.absent,
      fieldPresent: false,
      value: null,
      rolledUp: null,
    );
  }
  if (rawWidgets.length != 1) {
    throw const FormatException('Invalid health widget cardinality');
  }
  final widget = objectJson(rawWidgets.single);
  if (_boundedRequiredText(widget, 'type', 128) != 'HEALTH_STATUS') {
    throw const FormatException('Unexpected filtered health widget');
  }
  if (!widget.containsKey('healthStatus')) {
    throw const FormatException('Missing health status field');
  }
  final value = WorkItemHealthEditValue.parse(widget['healthStatus']);
  final rawRollup = widget['rolledUpHealthStatus'];
  List<WorkItemHealthEditRollup>? rolledUp;
  if (rawRollup != null) {
    if (rawRollup is! List || rawRollup.length > 32) {
      throw const FormatException('Invalid health rollup');
    }
    final seen = <WorkItemHealthEditValue>{};
    final values = <WorkItemHealthEditRollup>[];
    for (final raw in rawRollup) {
      final item = objectJson(raw);
      final rollupValue = WorkItemHealthEditValue.parse(item['healthStatus']);
      final count = item['count'];
      if (rollupValue == null ||
          count is! int ||
          count < 0 ||
          !seen.add(rollupValue)) {
        throw const FormatException('Invalid health rollup value');
      }
      values.add(WorkItemHealthEditRollup(value: rollupValue, count: count));
    }
    rolledUp = List<WorkItemHealthEditRollup>.unmodifiable(values);
  }
  return (
    availability: WorkItemHealthEditAvailability.present,
    fieldPresent: true,
    value: value,
    rolledUp: rolledUp,
  );
}

_HealthAcknowledgement _parseHealthAcknowledgement(
  Uint8List bytes,
  WorkItemGraphSummary expected,
) {
  final envelope = _healthEnvelope(bytes);
  final payload = objectJson(objectJson(envelope['data'])['workItemUpdate']);
  if (!payload.containsKey('errors')) {
    throw const FormatException('Missing health payload errors');
  }
  final errors = payload['errors'];
  if (errors is! List || errors.any((error) => error is! String)) {
    throw const FormatException('Invalid health payload errors');
  }
  if (errors.isNotEmpty) throw const _HealthPayloadValidation();
  final node = objectJson(payload['workItem']);
  _requireStrictGroupWorkItemOwner(node, expected.strictGroupOwner);
  if (requiredString(node, 'id') != expected.id) {
    throw const FormatException('Wrong health acknowledgement identity');
  }
  final widgets = _parseHealthWidgets(node['widgets']);
  if (widgets.availability != WorkItemHealthEditAvailability.present ||
      !widgets.fieldPresent) {
    throw const FormatException('Missing health acknowledgement widget');
  }
  return (
    value: widgets.value,
    updatedAt: _workItemTimestamp(node['updatedAt']),
  );
}

Json _healthGraphData(Uint8List bytes) {
  final envelope = _healthEnvelope(bytes);
  return objectJson(envelope['data']);
}

Json _healthEnvelope(Uint8List bytes) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors != null) {
      if (errors is! List || errors.isNotEmpty) {
        throw const FormatException('Health GraphQL errors');
      }
    }
    return envelope;
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException('Invalid health GraphQL envelope');
  }
}

bool _sameHealthStableIdentity(
  WorkItemGraphSummary left,
  WorkItemGraphSummary right,
) =>
    left.id == right.id &&
    left.iid == right.iid &&
    _sameAttributeRef(left.project, right.project) &&
    _sameAttributeRef(left.namespace, right.namespace) &&
    left.type.id == right.type.id &&
    left.type.name == right.type.name &&
    left.state == right.state;

bool _sameHealthSnapshot(
  WorkItemHealthEditSnapshot left,
  WorkItemHealthEditSnapshot right,
) =>
    _sameHealthStableIdentity(left.summary, right.summary) &&
    left.summary.updatedAt == right.summary.updatedAt &&
    left.availability == right.availability &&
    left.healthStatusFieldPresent == right.healthStatusFieldPresent &&
    left.value == right.value;
