part of 'gitlab_api.dart';

const _workItemContentQuery = r'''
query MobileWorkItemContent($id: WorkItemID!) {
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
    userPermissions { updateWorkItem }
    widgets(onlyTypes: [DESCRIPTION]) {
      type
      ... on WorkItemWidgetDescription {
        description
        edited
        lastEditedAt
      }
    }
  }
}
''';

const _workItemContentMutation = r'''
mutation MobileUpdateWorkItemContent($input: WorkItemUpdateInput!) {
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
      widgets(onlyTypes: [DESCRIPTION]) {
        type
        ... on WorkItemWidgetDescription {
          description
          edited
          lastEditedAt
        }
      }
    }
  }
}
''';

enum WorkItemDescriptionAvailability { present, absent, widgetsUnavailable }

/// A fresh server snapshot used by the editor. A present DESCRIPTION widget
/// canonicalizes a null GraphQL description to the empty Markdown source.
final class WorkItemContentSnapshot {
  const WorkItemContentSnapshot._({
    required this.summary,
    required this.rawDescription,
    required this.edited,
    required this.lastEditedAt,
    required this.descriptionAvailability,
  });

  final WorkItemGraphSummary summary;
  final String? rawDescription;
  final bool? edited;
  final DateTime? lastEditedAt;
  final WorkItemDescriptionAvailability descriptionAvailability;
}

final class WorkItemContentAccess {
  const WorkItemContentAccess._({
    required this.snapshot,
    required this.actorId,
    required this.canUpdate,
    required this.target,
  });

  final WorkItemContentSnapshot snapshot;
  final String actorId;
  final bool canUpdate;
  final WorkItemContentTarget? target;
}

/// A single content update bound to the API owner, actor, exact Work Item
/// identity and the server snapshot that opened the editor.
final class WorkItemContentTarget {
  WorkItemContentTarget._({
    required GitLabApi owner,
    required String actorId,
    required WorkItemContentSnapshot snapshot,
  }) : _owner = owner,
       _actorId = actorId,
       _snapshot = snapshot;

  final GitLabApi _owner;
  final String _actorId;
  final WorkItemContentSnapshot _snapshot;
  bool _consumed = false;
}

extension WorkItemContentApi on GitLabApi {
  /// Opens a fresh editor snapshot. The displayed detail may be stale; only its
  /// opaque identity and server-defined type constrain this independent read.
  Future<WorkItemContentAccess> workItemContent(
    WorkItemGraphDetail expected, {
    required int expectedUserId,
    bool Function()? isCurrent,
  }) async {
    _validateContentExpected(expected, expectedUserId);
    return _readWorkItemContent(
      expected.summary,
      expectedUserId: expectedUserId,
      isCurrent: isCurrent,
    );
  }

  /// Reserves [target] before asynchronous work, performs a fresh exact
  /// preflight, sends at most one mutation, then requires an actor-bound read.
  /// AI callers also provide the displayed revision as `expectedUpdatedAt`.
  /// Its server support is not inferred: independent readback is still required.
  Future<WorkItemContentAccess> updateWorkItemContent(
    WorkItemContentTarget target, {
    String? title,
    String? description,
    DateTime? expectedUpdatedAt,
    bool allowEmptyTitle = false,
    bool Function()? isCurrent,
    void Function()? onMutationSent,
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    _validateContentInput(title, description, allowEmptyTitle: allowEmptyTitle);
    _requireActivityOwner(target._owner);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    target._consumed = true;
    _requireCurrentWorkItemRequest(isCurrent);

    final actorNumber = _notificationActorNumber(target._actorId);
    final before = await _readWorkItemContent(
      target._snapshot.summary,
      expectedUserId: actorNumber,
      isCurrent: isCurrent,
    );
    if (before.actorId != target._actorId) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (!_sameContentSnapshot(before.snapshot, target._snapshot) ||
        (expectedUpdatedAt != null &&
            before.snapshot.summary.updatedAt != expectedUpdatedAt)) {
      throw const ApiFailure(FailureKind.conflict);
    }
    if (!before.canUpdate || before.target == null) {
      throw ApiFailure(
        FailureKind.forbidden,
        title: l10n.cannotEditWorkItem,
        detail: l10n.noPermissionUpdateWorkItem,
      );
    }
    if (description != null &&
        before.snapshot.descriptionAvailability !=
            WorkItemDescriptionAvailability.present) {
      throw ApiFailure(
        FailureKind.unsupported,
        title: l10n.cannotEditItemDescription,
        detail: l10n.noSafeDescriptionWidget,
      );
    }
    final desiredTitle = title ?? before.snapshot.summary.title;
    final titleChanged =
        title != null && title != before.snapshot.summary.title;
    final descriptionChanged =
        description != null && description != before.snapshot.rawDescription;
    if (!titleChanged && !descriptionChanged) return before;

    final input = <String, Object?>{
      'id': before.snapshot.summary.id,
      if (expectedUpdatedAt != null)
        'expectedUpdatedAt': expectedUpdatedAt.toIso8601String(),
    };
    if (titleChanged) input['title'] = title;
    if (descriptionChanged) {
      input['descriptionWidget'] = {'description': description};
    }

    _requireCurrentWorkItemRequest(isCurrent);
    if (beforeMutation != null) await beforeMutation();
    _requireCurrentWorkItemRequest(isCurrent);
    if (mayStart != null && !mayStart()) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    onMutationSent?.call();
    ({Uint8List bytes, Headers headers, int statusCode}) response;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': _workItemContentMutation,
          'variables': {'input': input},
        },
      );
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _workItemContentGraphData(response.bytes, mutation: true);
      final payload = objectJson(data['workItemUpdate']);
      final errors = payload['errors'];
      if (errors is! List || errors.any((error) => error is! String)) {
        throw const FormatException('Invalid content errors');
      }
      if (errors.isNotEmpty) {
        throw ApiFailure(
          FailureKind.validation,
          title: l10n.gitlabRejectedContentUpdate,
          detail: l10n.draftKeptRecheckFields,
        );
      }
      final acknowledged = _parseContentWorkItem(
        payload['workItem'],
        target._snapshot.summary,
        requirePermission: false,
      );
      if (acknowledged.snapshot.summary.title != desiredTitle ||
          (description != null &&
              (acknowledged.snapshot.descriptionAvailability !=
                      WorkItemDescriptionAvailability.present ||
                  acknowledged.snapshot.rawDescription != description))) {
        throw const FormatException('Wrong content acknowledgement');
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
      final readback = await _readWorkItemContent(
        target._snapshot.summary,
        expectedUserId: actorNumber,
        isCurrent: isCurrent,
      );
      final expectedDescription =
          description ?? target._snapshot.rawDescription;
      if (readback.actorId != target._actorId ||
          readback.snapshot.summary.title != desiredTitle ||
          readback.snapshot.descriptionAvailability !=
              target._snapshot.descriptionAvailability ||
          readback.snapshot.rawDescription != expectedDescription) {
        throw const FormatException('Content not independently visible');
      }
      return readback;
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
  }

  Future<WorkItemContentAccess> _readWorkItemContent(
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
        'query': _workItemContentQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemContentGraphData(response.bytes, mutation: false);
      if (!data.containsKey('currentUser')) {
        throw const FormatException('Missing content actor');
      }
      final actorId = _parseNotificationActor(data['currentUser']);
      if (actorId == null) {
        throw ApiFailure(
          FailureKind.unauthenticated,
          title: l10n.signInNoLongerValid,
          detail: l10n.reconnectThenEditWorkItem,
        );
      }
      if (_notificationActorNumber(actorId) != expectedUserId) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      if (data['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final parsed = _parseContentWorkItem(
        data['workItem'],
        expected,
        requirePermission: true,
      );
      final target = parsed.canUpdate
          ? WorkItemContentTarget._(
              owner: this,
              actorId: actorId,
              snapshot: parsed.snapshot,
            )
          : null;
      return WorkItemContentAccess._(
        snapshot: parsed.snapshot,
        actorId: actorId,
        canUpdate: parsed.canUpdate,
        target: target,
      );
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
}

typedef _ParsedWorkItemContent = ({
  WorkItemContentSnapshot snapshot,
  bool canUpdate,
});

_ParsedWorkItemContent _parseContentWorkItem(
  Object? raw,
  WorkItemGraphSummary expected, {
  required bool requirePermission,
}) {
  final node = objectJson(raw);
  final summary = _parseWorkItemSummary(node);
  _requireExpectedContentIdentity(summary, expected);

  bool canUpdate = false;
  if (requirePermission) {
    final permission = objectJson(node['userPermissions'])['updateWorkItem'];
    if (permission is! bool) {
      throw const FormatException('Invalid content permission');
    }
    canUpdate = permission;
  }

  final rawWidgets = node['widgets'];
  if (rawWidgets == null) {
    return (
      snapshot: WorkItemContentSnapshot._(
        summary: summary,
        rawDescription: null,
        edited: null,
        lastEditedAt: null,
        descriptionAvailability:
            WorkItemDescriptionAvailability.widgetsUnavailable,
      ),
      canUpdate: canUpdate,
    );
  }
  if (rawWidgets is! List || rawWidgets.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid content widgets');
  }
  Json? descriptionWidget;
  for (final rawWidget in rawWidgets) {
    final widget = objectJson(rawWidget);
    if (_boundedRequiredText(widget, 'type', 128) != 'DESCRIPTION') {
      throw const FormatException('Unexpected filtered widget');
    }
    if (descriptionWidget != null) {
      throw const FormatException('Duplicate description widget');
    }
    descriptionWidget = widget;
  }
  if (descriptionWidget == null) {
    return (
      snapshot: WorkItemContentSnapshot._(
        summary: summary,
        rawDescription: null,
        edited: null,
        lastEditedAt: null,
        descriptionAvailability: WorkItemDescriptionAvailability.absent,
      ),
      canUpdate: canUpdate,
    );
  }
  final widget = _parseDescriptionWidget(descriptionWidget);
  return (
    snapshot: WorkItemContentSnapshot._(
      summary: summary,
      rawDescription: widget.description ?? '',
      edited: widget.edited,
      lastEditedAt: widget.lastEditedAt,
      descriptionAvailability: WorkItemDescriptionAvailability.present,
    ),
    canUpdate: canUpdate,
  );
}

void _requireExpectedContentIdentity(
  WorkItemGraphSummary actual,
  WorkItemGraphSummary expected,
) {
  if (actual.id != expected.id ||
      actual.iid != expected.iid ||
      !_sameAttributeRef(actual.project, expected.project) ||
      !_sameAttributeRef(actual.namespace, expected.namespace) ||
      actual.type.id != expected.type.id ||
      actual.type.name != expected.type.name) {
    throw const FormatException('Wrong content identity');
  }
}

bool _sameContentSnapshot(
  WorkItemContentSnapshot left,
  WorkItemContentSnapshot right,
) =>
    left.summary.id == right.summary.id &&
    left.summary.iid == right.summary.iid &&
    left.summary.title == right.summary.title &&
    left.summary.updatedAt == right.summary.updatedAt &&
    left.summary.type.id == right.summary.type.id &&
    left.summary.type.name == right.summary.type.name &&
    _sameAttributeRef(left.summary.project, right.summary.project) &&
    _sameAttributeRef(left.summary.namespace, right.summary.namespace) &&
    left.descriptionAvailability == right.descriptionAvailability &&
    left.rawDescription == right.rawDescription;

void _validateContentExpected(
  WorkItemGraphDetail expected,
  int expectedUserId,
) {
  _validateExpectedAttributeIdentity(expected.summary);
  if (expectedUserId <= 0 ||
      !_isGraphResourceType(expected.summary.id, const {'WorkItem'}) ||
      !_isGraphResourceType(expected.summary.type.id, const {
        'WorkItems::Type',
      }) ||
      expected.summary.type.name.isEmpty ||
      expected.summary.type.name.length > 256 ||
      expected.summary.type.name.contains('\u0000')) {
    throw const ApiFailure(FailureKind.validation);
  }
  try {
    _requireContentScope(expected.summary);
  } on FormatException {
    throw const ApiFailure(FailureKind.validation);
  }
}

void _requireContentScope(WorkItemGraphSummary summary) {
  final project = summary.project;
  final namespace = summary.namespace;
  if (project == null) {
    if (namespace == null ||
        !_isGraphResourceType(namespace.id, const {'Group'})) {
      throw const FormatException('Invalid group work item scope');
    }
    return;
  }
  if (namespace == null ||
      !_isGraphResourceType(project.id, const {'Project'}) ||
      !_isGraphResourceType(namespace.id, const {
        'Namespaces::ProjectNamespace',
      }) ||
      project.fullPath != namespace.fullPath) {
    throw const FormatException('Invalid project work item scope');
  }
}

void _validateContentInput(
  String? title,
  String? description, {
  bool allowEmptyTitle = false,
}) {
  if (title == null && description == null) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (title != null &&
      ((!allowEmptyTitle && title.trim().isEmpty) ||
          (title.isNotEmpty && title.trim().isEmpty) ||
          title.length > 4096 ||
          title.contains('\u0000'))) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (description != null) {
    try {
      _boundedOptionalDescription(description);
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw const ApiFailure(FailureKind.validation);
    }
  }
}

Json _workItemContentGraphData(Uint8List bytes, {required bool mutation}) {
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
            title: l10n.instanceNoWorkItemContentEdit,
            detail: l10n.noSafeTitleDescriptionFlow,
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
