part of 'gitlab_api.dart';

final _workItemNotificationsQuery =
    '''
query MobileWorkItemNotifications(\$id: WorkItemID!) {
  currentUser { id }
  workItem(id: \$id) {
    $_workItemAttributeIdentityFields
    workItemType { id }
    widgets(onlyTypes: [NOTIFICATIONS]) {
      type
      ... on WorkItemWidgetNotifications { subscribed }
    }
  }
}
''';

final _workItemNotificationsMutation =
    '''
mutation MobileSetWorkItemNotifications(\$input: WorkItemSubscribeInput!) {
  workItemSubscribe(input: \$input) {
    errors
    workItem {
      $_workItemAttributeIdentityFields
      workItemType { id }
      widgets(onlyTypes: [NOTIFICATIONS]) {
        type
        ... on WorkItemWidgetNotifications { subscribed }
      }
    }
  }
}
''';

enum WorkItemNotificationAvailability { present, absent, widgetsUnavailable }

/// A bounded notification snapshot. [canAttemptSubscription] means only that
/// an authenticated actor and the server widget are present; GitLab remains
/// authoritative for the independent `update_subscription` permission.
final class WorkItemNotificationAccess {
  const WorkItemNotificationAccess._({
    required this.availability,
    required this.subscribed,
    required this.actorId,
    required this.canAttemptSubscription,
    required this.target,
  });

  final WorkItemNotificationAvailability availability;
  final bool? subscribed;
  final String? actorId;
  final bool canAttemptSubscription;
  final WorkItemNotificationTarget? target;
}

/// A single subscription attempt bound to one API owner, actor, Work Item and
/// original server state. GitLab exposes no compare-and-swap input here.
final class WorkItemNotificationTarget {
  WorkItemNotificationTarget._({
    required GitLabApi owner,
    required WorkItemGraphSummary expected,
    required String actorId,
    required bool subscribed,
  }) : _owner = owner,
       _expected = expected,
       _actorId = actorId,
       _subscribed = subscribed;

  final GitLabApi _owner;
  final WorkItemGraphSummary _expected;
  final String _actorId;
  final bool _subscribed;
  bool _consumed = false;
}

extension WorkItemNotificationsApi on GitLabApi {
  Future<WorkItemNotificationAccess> workItemNotifications(
    WorkItemGraphSummary expected, {
    int? expectedUserId,
    bool Function()? isCurrent,
  }) async {
    _validateNotificationExpected(expected, expectedUserId);
    return _readWorkItemNotifications(
      expected,
      expectedUserId: expectedUserId,
      isCurrent: isCurrent,
    );
  }

  /// Uses a fresh identity/actor/widget/state preflight, sends at most one
  /// explicit desired-state mutation and confirms it with an independent read.
  /// Once the mutation is sent, any outcome other than a provable schema or
  /// validation rejection is uncertain and the target cannot be replayed.
  Future<WorkItemNotificationAccess> setWorkItemNotifications(
    WorkItemNotificationTarget target, {
    required bool subscribed,
    bool Function()? isCurrent,
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    _requireActivityOwner(target._owner);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    target._consumed = true;
    _requireCurrentWorkItemRequest(isCurrent);

    final actorNumber = _notificationActorNumber(target._actorId);
    final before = await _readWorkItemNotifications(
      target._expected,
      expectedUserId: actorNumber,
      isCurrent: isCurrent,
    );
    if (before.actorId != target._actorId) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (before.availability != WorkItemNotificationAvailability.present ||
        before.subscribed == null ||
        before.subscribed != target._subscribed) {
      throw const ApiFailure(FailureKind.conflict);
    }
    if (!before.canAttemptSubscription) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    if (before.subscribed == subscribed) return before;

    _requireCurrentWorkItemRequest(isCurrent);
    if (beforeMutation != null) await beforeMutation();
    if (mayStart != null && !mayStart()) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    ({Uint8List bytes, Headers headers, int statusCode}) response;
    var didSend = false;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        onSendStarted: () {
          didSend = true;
        },
        data: {
          'query': _workItemNotificationsMutation,
          'variables': {
            'input': {'id': target._expected.id, 'subscribed': subscribed},
          },
        },
      );
    } on Object catch (error) {
      if (_graphDefinitelyNotSent(error, didSend)) rethrow;
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _notificationGraphData(response.bytes, mutation: true);
      final payload = objectJson(data['workItemSubscribe']);
      final errors = payload['errors'];
      if (errors is! List || errors.any((error) => error is! String)) {
        throw const FormatException('Invalid subscription errors');
      }
      if (errors.isNotEmpty) {
        throw ApiFailure(
          FailureKind.validation,
          title: l10n.gitlabRejectedNotifications,
          detail: l10n.reloadConfirmNotifications,
        );
      }
      final acknowledged = _parseNotificationWorkItem(
        payload['workItem'],
        target._expected,
      );
      if (acknowledged.availability !=
              WorkItemNotificationAvailability.present ||
          acknowledged.subscribed != subscribed) {
        throw const FormatException('Wrong subscription acknowledgement');
      }
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.unsupported ||
          failure.kind == FailureKind.validation) {
        rethrow;
      }
      throw const ApiFailure(FailureKind.writeUncertain);
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final readback = await _readWorkItemNotifications(
        target._expected,
        expectedUserId: actorNumber,
        isCurrent: isCurrent,
      );
      if (readback.actorId != target._actorId ||
          readback.availability != WorkItemNotificationAvailability.present ||
          readback.subscribed != subscribed) {
        throw const FormatException('Subscription not independently visible');
      }
      return readback;
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
  }

  Future<WorkItemNotificationAccess> _readWorkItemNotifications(
    WorkItemGraphSummary expected, {
    required int? expectedUserId,
    bool Function()? isCurrent,
  }) async {
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _workItemNotificationsQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _notificationGraphData(response.bytes, mutation: false);
      if (data['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final parsed = _parseNotificationWorkItem(data['workItem'], expected);
      if (!data.containsKey('currentUser')) {
        throw const FormatException('Missing notification actor');
      }
      final actorId = _parseNotificationActor(data['currentUser']);
      if (expectedUserId != null) {
        if (actorId == null) {
          throw ApiFailure(
            FailureKind.unauthenticated,
            title: l10n.signInNoLongerValid,
            detail: l10n.reconnectThenReadNotifications,
          );
        }
        if (_notificationActorNumber(actorId) != expectedUserId) {
          throw const ApiFailure(FailureKind.cancelled);
        }
      }
      final canAttempt =
          actorId != null &&
          parsed.availability == WorkItemNotificationAvailability.present;
      return WorkItemNotificationAccess._(
        availability: parsed.availability,
        subscribed: parsed.subscribed,
        actorId: actorId,
        canAttemptSubscription: canAttempt,
        target: canAttempt
            ? WorkItemNotificationTarget._(
                owner: this,
                expected: expected,
                actorId: actorId,
                subscribed: parsed.subscribed!,
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

typedef _NotificationWorkItem = ({
  WorkItemNotificationAvailability availability,
  bool? subscribed,
});

_NotificationWorkItem _parseNotificationWorkItem(
  Object? raw,
  WorkItemGraphSummary expected,
) {
  final node = objectJson(raw);
  _requireExpectedAttributeIdentity(_parseAttributeIdentity(node), expected);
  final type = objectJson(node['workItemType']);
  if (requiredString(type, 'id') != expected.type.id ||
      !_validOpaqueGraphId(expected.type.id)) {
    throw const FormatException('Wrong work item type');
  }
  final rawWidgets = node['widgets'];
  if (rawWidgets == null) {
    return (
      availability: WorkItemNotificationAvailability.widgetsUnavailable,
      subscribed: null,
    );
  }
  if (rawWidgets is! List || rawWidgets.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid notification widgets');
  }
  Json? notification;
  for (final rawWidget in rawWidgets) {
    final widget = objectJson(rawWidget);
    final type = _boundedRequiredText(widget, 'type', 128);
    if (type != 'NOTIFICATIONS') {
      throw const FormatException('Unexpected filtered widget');
    }
    if (notification != null) {
      throw const FormatException('Duplicate notification widget');
    }
    notification = widget;
  }
  if (notification == null) {
    return (
      availability: WorkItemNotificationAvailability.absent,
      subscribed: null,
    );
  }
  final subscribed = notification['subscribed'];
  if (subscribed is! bool) {
    throw const FormatException('Invalid notification state');
  }
  return (
    availability: WorkItemNotificationAvailability.present,
    subscribed: subscribed,
  );
}

String? _parseNotificationActor(Object? raw) {
  if (raw == null) return null;
  final id = requiredString(objectJson(raw), 'id');
  _notificationActorNumber(id);
  return id;
}

int _notificationActorNumber(String id) {
  if (!_isGraphIdType(id, const {'User'})) {
    throw const FormatException('Invalid notification actor');
  }
  final value = int.tryParse(Uri.parse(id).pathSegments.last);
  if (value == null || value <= 0) {
    throw const FormatException('Invalid notification actor');
  }
  return value;
}

void _validateNotificationExpected(
  WorkItemGraphSummary expected,
  int? expectedUserId,
) {
  _validateExpectedAttributeIdentity(expected);
  if (!_validOpaqueGraphId(expected.type.id) ||
      (expectedUserId != null && expectedUserId <= 0)) {
    throw const ApiFailure(FailureKind.validation);
  }
}

Json _notificationGraphData(Uint8List bytes, {required bool mutation}) {
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
            title: l10n.instanceNoNotificationSettings,
            detail: l10n.noSafeNotificationSubscribe,
          );
        }
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
