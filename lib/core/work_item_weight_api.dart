part of 'gitlab_api.dart';

const _weightInt32Max = 2147483647;

final _workItemWeightQuery =
    r'''
query MobileWorkItemWeight($id: WorkItemID!) {
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
    widgets(onlyTypes: [WEIGHT]) {
      type
      ... on WorkItemWidgetWeight {
        weight
        rolledUpWeight
        rolledUpCompletedWeight
      }
    }
  }
}
'''
        .trim();

final _workItemWeightMutation =
    r'''
mutation MobileSetWorkItemWeight($input: WorkItemUpdateInput!) {
  workItemUpdate(input: $input) {
    errors
    workItem {
      id
      iid
      title
      state
      createdAt
      updatedAt
      project { id fullPath }
      namespace { id fullPath }
      workItemType { id name }
      widgets(onlyTypes: [WEIGHT]) {
        type
        ... on WorkItemWidgetWeight {
          weight
          rolledUpWeight
          rolledUpCompletedWeight
        }
      }
    }
  }
}
'''
        .trim();

ApiFailure get _weightReadForbidden => ApiFailure(
  FailureKind.forbidden,
  title: l10n.cannotReadWorkItemWeight,
  detail: l10n.noPermissionReadWorkItem,
);

ApiFailure get _weightWriteForbidden => ApiFailure(
  FailureKind.forbidden,
  title: l10n.cannotChangeWeight,
  detail: l10n.noPermissionSetWeight,
);

ApiFailure get _weightUnsupported => ApiFailure(
  FailureKind.unsupported,
  title: l10n.instanceNoWeightEditing,
  detail: l10n.noSafeWeightUpdateFlow,
);

ApiFailure get _weightRejected => ApiFailure(
  FailureKind.validation,
  title: l10n.gitlabRejectedWeightUpdate,
  detail: l10n.reloadConfirmWeight,
);

ApiFailure get _weightConflict => ApiFailure(
  FailureKind.conflict,
  title: l10n.weightHasChanged,
  detail: l10n.reloadLatestBeforeSetting,
);

ApiFailure get _weightUncertain => ApiFailure(
  FailureKind.writeUncertain,
  title: l10n.weightUpdateUnconfirmed,
  detail: l10n.droppedAfterAssigneeSubmit,
);

/// Read result for one actor. [target] is null when the weight cannot be set.
/// Constructors stay in this part so callers cannot mint a writable target.
final class WorkItemWeightAccess {
  const WorkItemWeightAccess._({
    required this.snapshot,
    required this.actorId,
    required this.canSetWeight,
    required this.target,
  });

  final WorkItemWeightSnapshot snapshot;
  final String actorId;
  final bool canSetWeight;
  final WorkItemWeightTarget? target;
}

/// Single-use capability bound to one API, actor, identity, read epoch, own
/// weight and revision. Rolled-up totals are not part of the binding.
final class WorkItemWeightTarget {
  WorkItemWeightTarget._({
    required GitLabApi owner,
    required String actorId,
    required WorkItemWeightSnapshot snapshot,
    required int epoch,
  }) : _owner = owner,
       _actorId = actorId,
       _snapshot = snapshot,
       _epoch = epoch;

  final GitLabApi _owner;
  final String _actorId;
  final WorkItemWeightSnapshot _snapshot;
  final int _epoch;
  bool _consumed = false;
}

extension WorkItemWeightApi on GitLabApi {
  /// Fresh weight read. It does not use the filtered attribute query.
  /// [expectedUserId] is the active account's numeric user id.
  Future<WorkItemWeightAccess> workItemWeight(
    WorkItemGraphDetail detail, {
    required int expectedUserId,
    bool Function()? isCurrent,
  }) {
    _validateContentExpected(detail, expectedUserId);
    return _readWorkItemWeight(
      detail.summary,
      expectedUserId: expectedUserId,
      isCurrent: isCurrent,
    );
  }

  /// Sets or clears the own weight. There is no compare-and-swap: the fresh
  /// preflight must keep the same actor, permission, identity, revision and
  /// own value. Rolled-up totals may move and are never written or treated as
  /// a conflict. An unchanged own weight still performs those checks and sends
  /// nothing. After the mutation is sent, an ambiguous result is
  /// [FailureKind.writeUncertain] and is never replayed.
  Future<WorkItemWeightSnapshot> updateWorkItemWeight(
    WorkItemWeightTarget target, {
    required int? weight,
    bool Function()? isCurrent,
    void Function()? onMutationSent,
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    _validateWeightInput(weight);
    _requireActivityOwner(target._owner);
    if (target._consumed) throw _weightUncertain;
    target._consumed = true;
    final before = await _readWorkItemWeight(
      target._snapshot.summary,
      expectedUserId: _notificationActorNumber(target._actorId),
      isCurrent: isCurrent,
    );
    if (before.actorId != target._actorId) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (!_sameWeightFence(before.snapshot, target._snapshot)) {
      throw _weightConflict;
    }
    if (!before.canSetWeight || before.target == null) {
      throw _weightWriteForbidden;
    }
    if (_readEpoch != target._epoch) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    _requireCurrentWorkItemRequest(isCurrent);
    if (before.snapshot.value?.weight == weight) return before.snapshot;

    ({Uint8List bytes, Headers headers, int statusCode}) response;
    if (beforeMutation != null) await beforeMutation();
    if (mayStart != null && !mayStart()) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    var didSend = false;
    var callbackFailed = false;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        beforeSend: () {
          try {
            onMutationSent?.call();
          } on Object {
            callbackFailed = true;
            rethrow;
          }
        },
        onSendStarted: () => didSend = true,
        data: {
          'query': _workItemWeightMutation,
          'variables': {
            'input': <String, Object?>{
              'id': before.snapshot.summary.id,
              'weightWidget': <String, Object?>{'weight': weight},
            },
          },
        },
      );
    } on Object catch (error) {
      if (callbackFailed || _graphDefinitelyNotSent(error, didSend)) rethrow;
      throw _weightUncertain;
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _weightGraphData(response.bytes, mutation: true);
      final payload = objectJson(data['workItemUpdate']);
      final errors = payload['errors'];
      if (errors is! List || errors.any((error) => error is! String)) {
        throw const FormatException('Invalid weight errors');
      }
      if (errors.isNotEmpty) throw _weightRejected;
      final acknowledged = _parseWeightWorkItem(
        payload['workItem'],
        target._snapshot.summary,
        requirePermission: false,
      );
      _requireAcknowledgedWeight(acknowledged.snapshot, weight);
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.unsupported ||
          failure.kind == FailureKind.validation) {
        rethrow;
      }
      throw _weightUncertain;
    } on Object {
      throw _weightUncertain;
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final readback = await _readWorkItemWeight(
        target._snapshot.summary,
        expectedUserId: _notificationActorNumber(target._actorId),
        isCurrent: isCurrent,
      );
      if (readback.actorId != target._actorId) {
        throw const FormatException('Weight actor changed');
      }
      _requireAcknowledgedWeight(readback.snapshot, weight);
      return readback.snapshot;
    } on Object {
      throw _weightUncertain;
    }
  }

  Future<WorkItemWeightAccess> _readWorkItemWeight(
    WorkItemGraphSummary expected, {
    required int expectedUserId,
    bool Function()? isCurrent,
  }) async {
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _workItemWeightQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _weightGraphData(response.bytes, mutation: false);
      if (!data.containsKey('currentUser')) {
        throw const FormatException('Missing weight actor');
      }
      final actorId = _parseNotificationActor(data['currentUser']);
      if (actorId == null) {
        throw ApiFailure(
          FailureKind.unauthenticated,
          title: l10n.signInNoLongerValid,
          detail: l10n.reconnectThenReadWeight,
        );
      }
      if (_notificationActorNumber(actorId) != expectedUserId) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      if (data['workItem'] == null) {
        throw ApiFailure(
          FailureKind.invisible,
          title: l10n.workItemNotFound,
          detail: l10n.itemMissingOrUnreadable,
        );
      }
      final parsed = _parseWeightWorkItem(data['workItem'], expected);
      final canSet = parsed.canSetWeight;
      return WorkItemWeightAccess._(
        snapshot: parsed.snapshot,
        actorId: actorId,
        canSetWeight: canSet,
        target: canSet
            ? WorkItemWeightTarget._(
                owner: this,
                actorId: actorId,
                snapshot: parsed.snapshot,
                epoch: _readEpoch,
              )
            : null,
      );
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
}

void _validateWeightInput(int? weight) {
  if (weight != null && (weight < 0 || weight > _weightInt32Max)) {
    throw ApiFailure(
      FailureKind.validation,
      title: l10n.invalidWeight,
      detail: l10n.weightIntegerOrExplicitClear,
    );
  }
}

({WorkItemWeightSnapshot snapshot, bool canSetWeight}) _parseWeightWorkItem(
  Object? raw,
  WorkItemGraphSummary expected, {
  bool requirePermission = true,
}) {
  final node = objectJson(raw);
  final summary = _parseWorkItemSummary(node);
  _requireExpectedMilestoneIdentity(summary, expected);
  bool? readWorkItem;
  bool? adminWorkItem;
  if (requirePermission) {
    if (!node.containsKey('userPermissions')) {
      throw const FormatException('Missing weight permissions');
    }
    final permissions = objectJson(node['userPermissions']);
    if (!permissions.containsKey('readWorkItem') ||
        !permissions.containsKey('adminWorkItem')) {
      throw const FormatException('Missing weight permission');
    }
    final read = permissions['readWorkItem'];
    final admin = permissions['adminWorkItem'];
    if (read is! bool || admin is! bool) {
      throw const FormatException('Invalid weight permission');
    }
    readWorkItem = read;
    adminWorkItem = admin;
  }
  final parsedWidget = _parseWeightWidgetList(node['widgets']);
  if (requirePermission && readWorkItem != true) throw _weightReadForbidden;
  final canSet =
      adminWorkItem == true &&
      parsedWidget.availability == WorkItemAttributeAvailability.present &&
      parsedWidget.value != null;
  return (
    snapshot: WorkItemWeightSnapshot(
      summary: summary,
      availability: parsedWidget.availability,
      value: parsedWidget.value,
    ),
    canSetWeight: canSet,
  );
}

({WorkItemAttributeAvailability availability, WorkItemWeightAttribute? value})
_parseWeightWidgetList(Object? rawWidgets) {
  if (rawWidgets == null) {
    return (
      availability: WorkItemAttributeAvailability.widgetsUnavailable,
      value: null,
    );
  }
  if (rawWidgets is! List || rawWidgets.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid weight widgets');
  }
  Json? weightWidget;
  for (final rawWidget in rawWidgets) {
    final widget = objectJson(rawWidget);
    if (_boundedRequiredText(widget, 'type', 128) != 'WEIGHT') {
      throw const FormatException('Unexpected filtered widget');
    }
    if (weightWidget != null) {
      throw const FormatException('Duplicate weight widget');
    }
    weightWidget = widget;
  }
  if (weightWidget == null) {
    return (availability: WorkItemAttributeAvailability.absent, value: null);
  }
  return (
    availability: WorkItemAttributeAvailability.present,
    value: _parsePresentWeight(weightWidget),
  );
}

WorkItemWeightAttribute _parsePresentWeight(Json widget) =>
    WorkItemWeightAttribute(
      weight: _weightScalar(widget, 'weight'),
      rolledUpWeight: _weightScalar(widget, 'rolledUpWeight'),
      rolledUpCompletedWeight: _weightScalar(widget, 'rolledUpCompletedWeight'),
    );

int? _weightScalar(Json widget, String key) {
  if (!widget.containsKey(key)) {
    throw const FormatException('Missing weight field');
  }
  final raw = widget[key];
  if (raw == null) return null;
  if (raw is! int || raw < 0 || raw > _weightInt32Max) {
    throw const FormatException('Invalid weight scalar');
  }
  return raw;
}

bool _sameWeightFence(
  WorkItemWeightSnapshot fresh,
  WorkItemWeightSnapshot bound,
) {
  final freshValue = fresh.value;
  final boundValue = bound.value;
  return _sameMilestoneExpected(fresh.summary, bound.summary) &&
      fresh.summary.updatedAt == bound.summary.updatedAt &&
      fresh.availability == WorkItemAttributeAvailability.present &&
      bound.availability == WorkItemAttributeAvailability.present &&
      freshValue != null &&
      boundValue != null &&
      freshValue.weight == boundValue.weight;
}

void _requireAcknowledgedWeight(WorkItemWeightSnapshot snapshot, int? weight) {
  final value = snapshot.value;
  if (snapshot.availability != WorkItemAttributeAvailability.present ||
      value == null ||
      value.weight != weight) {
    throw const FormatException('Wrong weight acknowledgement');
  }
}

Json _weightGraphData(Uint8List bytes, {required bool mutation}) {
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
        if (unsupported) throw _weightUnsupported;
        throw ApiFailure(
          mutation ? FailureKind.writeUncertain : FailureKind.invalidResponse,
        );
      }
    }
    return objectJson(envelope['data']);
  } on ApiFailure {
    rethrow;
  } on FormatException {
    throw ApiFailure(
      mutation ? FailureKind.writeUncertain : FailureKind.invalidResponse,
    );
  }
}
