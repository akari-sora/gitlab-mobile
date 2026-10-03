part of 'gitlab_api.dart';

const _workItemMilestoneQuery = r'''
query MobileWorkItemMilestone($id: WorkItemID!) {
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
    userPermissions { readWorkItem setWorkItemMetadata }
    widgets(onlyTypes: [MILESTONE]) {
      type
      ... on WorkItemWidgetMilestone {
        milestone {
          id iid title state expired dueDate startDate webPath
          project { id fullPath }
          group { id fullPath }
        }
      }
    }
  }
}
''';

const _workItemMilestoneMutation = r'''
mutation MobileSetWorkItemMilestone($input: WorkItemUpdateInput!) {
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
      widgets(onlyTypes: [MILESTONE]) {
        type
        ... on WorkItemWidgetMilestone {
          milestone {
            id iid title state expired dueDate startDate webPath
            project { id fullPath }
            group { id fullPath }
          }
        }
      }
    }
  }
}
''';

const _projectMilestonePickerQuery = r'''
query MobileProjectWorkItemMilestones(
  $fullPath: ID!
  $after: String
  $search: String
) {
  currentUser { id }
  project(fullPath: $fullPath) {
    id
    fullPath
    milestones(
      first: 50
      after: $after
      state: active
      searchTitle: $search
      includeAncestors: true
      sort: EXPIRED_LAST_DUE_DATE_ASC
    ) {
      nodes {
        id iid title state expired dueDate startDate webPath
        project { id fullPath }
        group { id fullPath }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

const _groupMilestonePickerQuery = r'''
query MobileGroupWorkItemMilestones(
  $fullPath: ID!
  $after: String
  $search: String
) {
  currentUser { id }
  group(fullPath: $fullPath) {
    id
    fullPath
    milestones(
      first: 50
      after: $after
      state: active
      searchTitle: $search
      includeAncestors: true
      sort: EXPIRED_LAST_DUE_DATE_ASC
    ) {
      nodes {
        id iid title state expired dueDate startDate webPath
        project { id fullPath }
        group { id fullPath }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

const _workItemMilestonePickerPageSize = 50;
const _workItemMilestonePickerLimit = 200;

final class WorkItemMilestoneAccess {
  const WorkItemMilestoneAccess._({
    required this.snapshot,
    required this.actorId,
    required this.canSetMilestone,
    required this.target,
  });

  final WorkItemMilestoneSnapshot snapshot;
  final String actorId;
  final bool canSetMilestone;
  final WorkItemMilestoneTarget? target;
}

/// A single milestone update bound to one API owner, actor, exact Work Item,
/// supported widget, permission snapshot and original revision.
final class WorkItemMilestoneTarget {
  WorkItemMilestoneTarget._({
    required GitLabApi owner,
    required String actorId,
    required WorkItemMilestoneSnapshot snapshot,
  }) : _owner = owner,
       _actorId = actorId,
       _snapshot = snapshot,
       _binding = Object() {
    currentSelection = WorkItemMilestoneSelection._(
      owner: owner,
      binding: _binding,
      actorId: actorId,
      expected: snapshot.summary,
      milestone: snapshot.milestone,
    );
    clearSelection = WorkItemMilestoneSelection._(
      owner: owner,
      binding: _binding,
      actorId: actorId,
      expected: snapshot.summary,
      milestone: null,
    );
  }

  final GitLabApi _owner;
  final String _actorId;
  final WorkItemMilestoneSnapshot _snapshot;
  final Object _binding;
  late final WorkItemMilestoneSelection currentSelection;
  late final WorkItemMilestoneSelection clearSelection;
  bool _consumed = false;
}

/// Opaque desired milestone. A null [milestone] is an explicit clear choice.
final class WorkItemMilestoneSelection {
  const WorkItemMilestoneSelection._({
    required GitLabApi owner,
    required Object binding,
    required String actorId,
    required WorkItemGraphSummary expected,
    required this.milestone,
  }) : _owner = owner,
       _binding = binding,
       _actorId = actorId,
       _expected = expected;

  final GitLabApi _owner;
  final Object _binding;
  final String _actorId;
  final WorkItemGraphSummary _expected;
  final WorkItemMilestoneValue? milestone;
}

final class WorkItemMilestoneChoice {
  const WorkItemMilestoneChoice._({
    required this.milestone,
    required this.expired,
    required this.selection,
  });

  final WorkItemMilestoneValue milestone;
  final bool expired;
  final WorkItemMilestoneSelection selection;
}

final class WorkItemMilestonePickerContinuation {
  const WorkItemMilestonePickerContinuation._({
    required GitLabApi owner,
    required Object binding,
    required String actorId,
    required WorkItemGraphSummary expected,
    required String search,
    required String cursor,
    required int loaded,
    required Set<String> seenCursors,
    required Set<String> seenMilestoneIds,
  }) : _owner = owner,
       _binding = binding,
       _actorId = actorId,
       _expected = expected,
       _search = search,
       _cursor = cursor,
       _loaded = loaded,
       _seenCursors = seenCursors,
       _seenMilestoneIds = seenMilestoneIds;

  final GitLabApi _owner;
  final Object _binding;
  final String _actorId;
  final WorkItemGraphSummary _expected;
  final String _search;
  final String _cursor;
  final int _loaded;
  final Set<String> _seenCursors;
  final Set<String> _seenMilestoneIds;
}

final class WorkItemMilestonePickerPage {
  const WorkItemMilestonePickerPage._({
    required this.items,
    required this.clearSelection,
    required this.continuation,
    required this.isTruncated,
  });

  final List<WorkItemMilestoneChoice> items;
  final WorkItemMilestoneSelection clearSelection;
  final WorkItemMilestonePickerContinuation? continuation;
  final bool isTruncated;
  bool get isPartial => continuation != null || isTruncated;
}

extension WorkItemMilestoneApi on GitLabApi {
  /// Reads a fresh actor, exact Work Item identity, supported widget and the
  /// two permissions GitLab uses for a pure milestone-widget update.
  Future<WorkItemMilestoneAccess> workItemMilestone(
    WorkItemGraphDetail expected, {
    required int expectedUserId,
    bool Function()? isCurrent,
  }) async {
    _validateMilestoneExpected(expected, expectedUserId);
    return _readWorkItemMilestone(
      expected.summary,
      expectedUserId: expectedUserId,
      isCurrent: isCurrent,
    );
  }

  /// Reads one bounded active milestone connection. The raw cursor and the
  /// actor/scope/search binding remain opaque to callers.
  Future<WorkItemMilestonePickerPage> workItemMilestoneChoices(
    WorkItemMilestoneTarget target, {
    String search = '',
    WorkItemMilestonePickerContinuation? continuation,
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(target._owner);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    final normalizedSearch = _validatedMilestoneSearch(search);
    String? cursor;
    var loaded = 0;
    var seenCursors = <String>{};
    var seenMilestoneIds = <String>{};
    if (continuation != null) {
      _requireActivityOwner(continuation._owner);
      if (!identical(continuation._binding, target._binding) ||
          continuation._actorId != target._actorId ||
          !_sameMilestoneExpected(
            continuation._expected,
            target._snapshot.summary,
          ) ||
          continuation._search != normalizedSearch) {
        throw const ApiFailure(FailureKind.validation);
      }
      cursor = continuation._cursor;
      loaded = continuation._loaded;
      seenCursors = continuation._seenCursors.toSet();
      seenMilestoneIds = continuation._seenMilestoneIds.toSet();
      if (loaded <= 0 || loaded >= _workItemMilestonePickerLimit) {
        throw const ApiFailure(FailureKind.validation);
      }
      if (!seenCursors.add(cursor)) {
        throw const ApiFailure(FailureKind.validation);
      }
    }
    _requireCurrentWorkItemRequest(isCurrent);
    final expected = target._snapshot.summary;
    final scope = _milestoneScope(expected);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': scope.project == null
            ? _groupMilestonePickerQuery
            : _projectMilestonePickerQuery,
        'variables': {
          'fullPath': scope.path,
          'after': cursor,
          'search': normalizedSearch.isEmpty ? null : normalizedSearch,
        },
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _milestoneGraphData(response.bytes, mutation: false);
      final actorId = _parseRequiredMilestoneActor(data, target._actorId);
      final rawContainer = data[scope.project == null ? 'group' : 'project'];
      if (rawContainer == null) throw const ApiFailure(FailureKind.invisible);
      final container = objectJson(rawContainer);
      final containerId = requiredString(container, 'id');
      final containerPath = requiredString(container, 'fullPath');
      if (containerId != scope.id || containerPath != scope.path) {
        throw const FormatException('Wrong milestone picker scope');
      }
      final connection = objectJson(container['milestones']);
      final rawNodes = connection['nodes'];
      if (rawNodes is! List ||
          rawNodes.length > _workItemMilestonePickerPageSize ||
          loaded + rawNodes.length > _workItemMilestonePickerLimit) {
        throw const FormatException('Invalid milestone page cardinality');
      }
      final choices = <WorkItemMilestoneChoice>[];
      for (final rawNode in rawNodes) {
        final parsed = _parsePickerMilestone(rawNode, expected);
        if (!seenMilestoneIds.add(parsed.value.id)) {
          throw const FormatException('Duplicate milestone choice');
        }
        choices.add(
          WorkItemMilestoneChoice._(
            milestone: parsed.value,
            expired: parsed.expired,
            selection: WorkItemMilestoneSelection._(
              owner: this,
              binding: target._binding,
              actorId: actorId,
              expected: expected,
              milestone: parsed.value,
            ),
          ),
        );
      }
      final pageInfo = objectJson(connection['pageInfo']);
      final hasNext = pageInfo['hasNextPage'];
      if (hasNext is! bool) throw const FormatException('Invalid page state');
      final rawEndCursor = pageInfo['endCursor'];
      String? endCursor;
      if (rawEndCursor != null) {
        if (rawEndCursor is! String ||
            rawEndCursor.isEmpty ||
            rawEndCursor.length > _workItemCursorLimit ||
            rawEndCursor.contains('\u0000')) {
          throw const FormatException('Invalid milestone cursor');
        }
        endCursor = rawEndCursor;
      }
      if (hasNext && (endCursor == null || choices.isEmpty)) {
        throw const FormatException('Missing milestone continuation');
      }
      if (hasNext && (endCursor == cursor || seenCursors.contains(endCursor))) {
        throw const FormatException('Repeated milestone cursor');
      }
      final nextLoaded = loaded + choices.length;
      final truncated = hasNext && nextLoaded >= _workItemMilestonePickerLimit;
      final next = hasNext && !truncated
          ? WorkItemMilestonePickerContinuation._(
              owner: this,
              binding: target._binding,
              actorId: actorId,
              expected: expected,
              search: normalizedSearch,
              cursor: endCursor!,
              loaded: nextLoaded,
              seenCursors: Set.unmodifiable(seenCursors),
              seenMilestoneIds: Set.unmodifiable(seenMilestoneIds),
            )
          : null;
      return WorkItemMilestonePickerPage._(
        items: List.unmodifiable(choices),
        clearSelection: target.clearSelection,
        continuation: next,
        isTruncated: truncated,
      );
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// Consumes [target] before the asynchronous preflight, sends at most one
  /// pure widget mutation, then requires an independent same-actor readback.
  /// GitLab exposes no compare-and-set field, so a server-side race remains.
  Future<WorkItemMilestoneAccess> updateWorkItemMilestone(
    WorkItemMilestoneTarget target, {
    required WorkItemMilestoneSelection selection,
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(target._owner);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    target._consumed = true;
    if (!identical(selection._owner, this) ||
        !identical(selection._binding, target._binding) ||
        selection._actorId != target._actorId ||
        !_sameMilestoneExpected(
          selection._expected,
          target._snapshot.summary,
        )) {
      throw const ApiFailure(FailureKind.validation);
    }
    _requireCurrentWorkItemRequest(isCurrent);

    final actorNumber = _notificationActorNumber(target._actorId);
    final before = await _readWorkItemMilestone(
      target._snapshot.summary,
      expectedUserId: actorNumber,
      isCurrent: isCurrent,
    );
    if (before.actorId != target._actorId) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (!_sameMilestoneSnapshot(before.snapshot, target._snapshot)) {
      throw const ApiFailure(FailureKind.conflict);
    }
    if (!before.canSetMilestone || before.target == null) {
      throw const ApiFailure(
        FailureKind.forbidden,
        title: '無法變更里程碑',
        detail: '目前帳號沒有設定這個工作項目里程碑的權限。',
      );
    }
    final desired = selection.milestone;
    if (_sameDesiredMilestone(before.snapshot.milestone, desired)) {
      return before;
    }

    _requireCurrentWorkItemRequest(isCurrent);
    ({Uint8List bytes, Headers headers, int statusCode}) response;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': _workItemMilestoneMutation,
          'variables': {
            'input': {
              'id': before.snapshot.summary.id,
              'milestoneWidget': {'milestoneId': desired?.id},
            },
          },
        },
      );
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _milestoneGraphData(response.bytes, mutation: true);
      final payload = objectJson(data['workItemUpdate']);
      final errors = payload['errors'];
      if (errors is! List || errors.any((error) => error is! String)) {
        throw const FormatException('Invalid milestone errors');
      }
      if (errors.isNotEmpty) {
        throw const ApiFailure(
          FailureKind.validation,
          title: 'GitLab 未接受里程碑更新',
          detail: '請重新讀取工作項目，並確認里程碑與權限仍然有效。',
        );
      }
      final acknowledged = _parseMilestoneWorkItem(
        payload['workItem'],
        target._snapshot.summary,
        requirePermission: false,
      );
      if (acknowledged.snapshot.availability !=
              WorkItemMilestoneAvailability.present ||
          !_sameDesiredMilestone(acknowledged.snapshot.milestone, desired)) {
        throw const FormatException('Wrong milestone acknowledgement');
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
      final readback = await _readWorkItemMilestone(
        target._snapshot.summary,
        expectedUserId: actorNumber,
        isCurrent: isCurrent,
      );
      if (readback.actorId != target._actorId ||
          readback.snapshot.availability !=
              WorkItemMilestoneAvailability.present ||
          !_sameDesiredMilestone(readback.snapshot.milestone, desired)) {
        throw const FormatException('Milestone not independently visible');
      }
      return readback;
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
  }

  Future<WorkItemMilestoneAccess> _readWorkItemMilestone(
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
        'query': _workItemMilestoneQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _milestoneGraphData(response.bytes, mutation: false);
      final actorId = _parseRequiredMilestoneActor(data, null);
      if (_notificationActorNumber(actorId) != expectedUserId) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      if (data['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final parsed = _parseMilestoneWorkItem(
        data['workItem'],
        expected,
        requirePermission: true,
      );
      final canSet =
          parsed.readWorkItem &&
          parsed.setWorkItemMetadata &&
          parsed.snapshot.availability == WorkItemMilestoneAvailability.present;
      final target = canSet
          ? WorkItemMilestoneTarget._(
              owner: this,
              actorId: actorId,
              snapshot: parsed.snapshot,
            )
          : null;
      return WorkItemMilestoneAccess._(
        snapshot: parsed.snapshot,
        actorId: actorId,
        canSetMilestone: canSet,
        target: target,
      );
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
}

typedef _ParsedMilestoneWorkItem = ({
  WorkItemMilestoneSnapshot snapshot,
  bool readWorkItem,
  bool setWorkItemMetadata,
});

typedef _MilestoneScope = ({GraphResourceRef? project, String id, String path});

typedef _ParsedPickerMilestone = ({WorkItemMilestoneValue value, bool expired});

_ParsedMilestoneWorkItem _parseMilestoneWorkItem(
  Object? raw,
  WorkItemGraphSummary expected, {
  required bool requirePermission,
}) {
  final node = objectJson(raw);
  final summary = _parseWorkItemSummary(node);
  _requireExpectedMilestoneIdentity(summary, expected);
  var readWorkItem = false;
  var setWorkItemMetadata = false;
  if (requirePermission) {
    final permissions = objectJson(node['userPermissions']);
    final read = permissions['readWorkItem'];
    final setMetadata = permissions['setWorkItemMetadata'];
    if (read is! bool || setMetadata is! bool) {
      throw const FormatException('Invalid milestone permissions');
    }
    readWorkItem = read;
    setWorkItemMetadata = setMetadata;
  }
  final rawWidgets = node['widgets'];
  if (rawWidgets == null) {
    return (
      snapshot: WorkItemMilestoneSnapshot(
        summary: summary,
        availability: WorkItemMilestoneAvailability.widgetsUnavailable,
        milestone: null,
        milestoneExpired: null,
      ),
      readWorkItem: readWorkItem,
      setWorkItemMetadata: setWorkItemMetadata,
    );
  }
  if (rawWidgets is! List || rawWidgets.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid milestone widgets');
  }
  Json? milestoneWidget;
  for (final rawWidget in rawWidgets) {
    final widget = objectJson(rawWidget);
    if (_boundedRequiredText(widget, 'type', 128) != 'MILESTONE') {
      throw const FormatException('Unexpected filtered widget');
    }
    if (milestoneWidget != null) {
      throw const FormatException('Duplicate milestone widget');
    }
    milestoneWidget = widget;
  }
  if (milestoneWidget == null) {
    return (
      snapshot: WorkItemMilestoneSnapshot(
        summary: summary,
        availability: WorkItemMilestoneAvailability.absent,
        milestone: null,
        milestoneExpired: null,
      ),
      readWorkItem: readWorkItem,
      setWorkItemMetadata: setWorkItemMetadata,
    );
  }
  final parsedMilestone = _parseMilestoneWidgetValue(milestoneWidget);
  return (
    snapshot: WorkItemMilestoneSnapshot(
      summary: summary,
      availability: WorkItemMilestoneAvailability.present,
      milestone: parsedMilestone.value,
      milestoneExpired: parsedMilestone.expired,
    ),
    readWorkItem: readWorkItem,
    setWorkItemMetadata: setWorkItemMetadata,
  );
}

({WorkItemMilestoneValue? value, bool? expired}) _parseMilestoneWidgetValue(
  Json widget,
) {
  final raw = widget['milestone'];
  if (raw == null) return (value: null, expired: null);
  final parsed = _parseMilestoneAttribute({'milestone': raw}).milestone!;
  _requireMilestoneValueShape(parsed, requireOwner: false);
  final expired = objectJson(raw)['expired'];
  if (expired is! bool) throw const FormatException('Invalid milestone expiry');
  return (value: parsed, expired: expired);
}

_ParsedPickerMilestone _parsePickerMilestone(
  Object? raw,
  WorkItemGraphSummary expected,
) {
  final node = objectJson(raw);
  final value = _parseMilestoneAttribute({'milestone': node}).milestone!;
  _requireMilestoneValueShape(value, requireOwner: true);
  final expired = node['expired'];
  if (expired is! bool || value.state.toUpperCase() != 'ACTIVE') {
    throw const FormatException('Invalid active milestone');
  }
  _requireMilestoneChoiceScope(value, expected);
  return (value: value, expired: expired);
}

void _requireMilestoneValueShape(
  WorkItemMilestoneValue value, {
  required bool requireOwner,
}) {
  if (!_isGraphResourceType(value.id, const {'Milestone'})) {
    throw const FormatException('Wrong milestone identity type');
  }
  final project = value.project;
  final group = value.group;
  if (project != null && group != null) {
    throw const FormatException('Ambiguous milestone owner');
  }
  if (requireOwner && project == null && group == null) {
    throw const FormatException('Missing milestone owner');
  }
  if (project != null &&
      (project.id == null ||
          !_isGraphResourceType(project.id!, const {'Project'}))) {
    throw const FormatException('Invalid milestone project');
  }
  if (group != null &&
      (group.id == null || !_isGraphResourceType(group.id!, const {'Group'}))) {
    throw const FormatException('Invalid milestone group');
  }
}

void _requireMilestoneChoiceScope(
  WorkItemMilestoneValue value,
  WorkItemGraphSummary expected,
) {
  final scope = _milestoneScope(expected);
  final projectOwner = value.project;
  final groupOwner = value.group;
  if (scope.project != null &&
      projectOwner != null &&
      projectOwner.id == scope.project!.id &&
      projectOwner.fullPath == scope.project!.fullPath) {
    return;
  }
  // Legal group ancestry comes from this fresh, actor- and root-bound server
  // connection. Full-path prefixes are not an authority boundary and would
  // reject legal ancestors after a rename.
  if (groupOwner != null) {
    return;
  }
  throw const FormatException('Foreign milestone choice');
}

_MilestoneScope _milestoneScope(WorkItemGraphSummary summary) {
  _requireContentScope(summary);
  final project = summary.project;
  if (project != null) {
    return (project: project, id: project.id, path: project.fullPath);
  }
  final namespace = summary.namespace!;
  return (project: null, id: namespace.id, path: namespace.fullPath);
}

String _parseRequiredMilestoneActor(Json data, String? expectedActorId) {
  if (!data.containsKey('currentUser')) {
    throw const FormatException('Missing milestone actor');
  }
  final actor = _parseNotificationActor(data['currentUser']);
  if (actor == null) {
    throw const ApiFailure(
      FailureKind.unauthenticated,
      title: '登入已失效',
      detail: '請重新連接目前帳號，再讀取工作項目里程碑。',
    );
  }
  if (expectedActorId != null && actor != expectedActorId) {
    throw const ApiFailure(FailureKind.cancelled);
  }
  return actor;
}

void _validateMilestoneExpected(
  WorkItemGraphDetail expected,
  int expectedUserId,
) {
  _validateContentExpected(expected, expectedUserId);
  try {
    _milestoneScope(expected.summary);
  } on FormatException {
    throw const ApiFailure(FailureKind.validation);
  }
}

String _validatedMilestoneSearch(String value) {
  final search = value.trim();
  if (search.runes.length > 256 || search.contains('\u0000')) {
    throw const ApiFailure(FailureKind.validation);
  }
  return search;
}

void _requireExpectedMilestoneIdentity(
  WorkItemGraphSummary actual,
  WorkItemGraphSummary expected,
) {
  if (!_sameMilestoneExpected(actual, expected)) {
    throw const FormatException('Wrong milestone Work Item identity');
  }
}

bool _sameMilestoneExpected(
  WorkItemGraphSummary left,
  WorkItemGraphSummary right,
) =>
    left.id == right.id &&
    left.iid == right.iid &&
    _sameAttributeRef(left.project, right.project) &&
    _sameAttributeRef(left.namespace, right.namespace) &&
    left.type.id == right.type.id &&
    left.type.name == right.type.name;

bool _sameMilestoneSnapshot(
  WorkItemMilestoneSnapshot left,
  WorkItemMilestoneSnapshot right,
) =>
    _sameMilestoneExpected(left.summary, right.summary) &&
    left.summary.title == right.summary.title &&
    left.summary.state == right.summary.state &&
    left.summary.createdAt == right.summary.createdAt &&
    left.summary.updatedAt == right.summary.updatedAt &&
    left.availability == right.availability &&
    left.milestoneExpired == right.milestoneExpired &&
    _sameMilestoneValue(left.milestone, right.milestone);

bool _sameMilestoneValue(
  WorkItemMilestoneValue? left,
  WorkItemMilestoneValue? right,
) => left == null
    ? right == null
    : right != null &&
          left.id == right.id &&
          left.iid == right.iid &&
          left.title == right.title &&
          left.state == right.state &&
          left.webPath == right.webPath &&
          left.dueDate == right.dueDate &&
          left.startDate == right.startDate &&
          _sameMilestoneOwner(left.project, right.project) &&
          _sameMilestoneOwner(left.group, right.group);

bool _sameDesiredMilestone(
  WorkItemMilestoneValue? actual,
  WorkItemMilestoneValue? desired,
) => actual == null
    ? desired == null
    : desired != null && actual.id == desired.id;

bool _sameMilestoneOwner(
  WorkItemAttributeOwnerRef? left,
  WorkItemAttributeOwnerRef? right,
) => left == null
    ? right == null
    : right != null && left.id == right.id && left.fullPath == right.fullPath;

Json _milestoneGraphData(Uint8List bytes, {required bool mutation}) {
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
          throw const ApiFailure(
            FailureKind.unsupported,
            title: '實例未提供工作項目里程碑編輯',
            detail: '仍可查看工作項目；這個 GitLab 版本不支援安全的里程碑更新流程。',
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
