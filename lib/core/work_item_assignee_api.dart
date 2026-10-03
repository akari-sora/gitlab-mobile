part of 'gitlab_api.dart';

const _assigneePageSize = 100;
const _assigneeMaxPages = 20;
const _assigneeCandidateLimit = 20;

final _workItemAssigneesQuery =
    r'''
query MobileWorkItemAssignees($id: WorkItemID!, $after: String) {
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
    widgets(onlyTypes: [ASSIGNEES]) {
      type
      ... on WorkItemWidgetAssignees {
        allowsMultipleAssignees
        assignees(first: 100, after: $after) {
          nodes { id name username }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
'''
        .trim();

final _projectAssigneeCandidatesQuery =
    r'''
query MobileProjectAssigneeCandidates($fullPath: ID!, $search: String) {
  currentUser { id }
  project(fullPath: $fullPath) {
    id
    fullPath
    autocompleteUsers(search: $search) { id name username }
  }
}
'''
        .trim();

final _groupAssigneeCandidatesQuery =
    r'''
query MobileGroupAssigneeCandidates($fullPath: ID!, $search: String) {
  currentUser { id }
  group(fullPath: $fullPath) {
    id
    fullPath
    autocompleteUsers(search: $search) { id name username }
  }
}
'''
        .trim();

final _workItemAssigneesMutation =
    r'''
mutation MobileSetWorkItemAssignees($input: WorkItemUpdateInput!) {
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
      widgets(onlyTypes: [ASSIGNEES]) {
        type
        ... on WorkItemWidgetAssignees {
          allowsMultipleAssignees
          assignees(first: 100) {
            nodes { id name username }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
  }
}
'''
        .trim();

const _assigneesReadForbidden = ApiFailure(
  FailureKind.forbidden,
  title: '無法讀取工作項目負責人',
  detail: '目前帳號沒有讀取這個工作項目的權限。',
);

const _assigneesWriteForbidden = ApiFailure(
  FailureKind.forbidden,
  title: '無法變更負責人',
  detail: '目前帳號沒有設定這個工作項目中繼資料的權限。',
);

const _assigneesUnsupported = ApiFailure(
  FailureKind.unsupported,
  title: '負責人名單未完整載入，無法編輯',
  detail: '這次讀到的負責人連線不完整或不符合契約，不會送出被截斷的名單。',
);

const _assigneesRejected = ApiFailure(
  FailureKind.validation,
  title: 'GitLab 未接受負責人更新',
  detail: '請重新讀取工作項目，並確認負責人與權限仍然有效。',
);

const _assigneesConflict = ApiFailure(
  FailureKind.conflict,
  title: '負責人已經變更',
  detail: '請重新讀取最新版本後再設定。',
);

const _assigneesUncertain = ApiFailure(
  FailureKind.writeUncertain,
  title: '尚未確認負責人是否已更新',
  detail: '連線在送出後中斷。請重新讀取工作項目，不要重複送出同一次變更。',
);

/// Read result for one actor. [target] is null when the set cannot be edited.
/// Constructors stay in this part so callers cannot mint a writable target.
final class WorkItemAssigneeAccess {
  const WorkItemAssigneeAccess._({
    required this.snapshot,
    required this.actorId,
    required this.canWrite,
    required this.target,
  });

  final WorkItemAssigneeSnapshot snapshot;
  final String actorId;

  /// True only when this read saw `readWorkItem`, `setWorkItemMetadata`, and
  /// a present assignees widget whose `allowsMultipleAssignees` is a bool.
  /// `adminWorkItem` and `updateWorkItem` do not set this.
  final bool canWrite;
  final WorkItemAssigneeTarget? target;
}

/// Single-use capability. Searching candidates does not consume it.
/// [updateWorkItemAssignees] consumes it before the fresh preflight,
/// including a no-op. A second use is [FailureKind.writeUncertain].
final class WorkItemAssigneeTarget {
  WorkItemAssigneeTarget._({
    required GitLabApi owner,
    required this.actorId,
    required this.expectedUserId,
    required WorkItemAssigneeSnapshot snapshot,
    required this.readEpoch,
  }) : _owner = owner,
       _snapshot = snapshot,
       setWorkItemMetadata = true,
       assigneesWidgetPresent = true;

  final GitLabApi _owner;
  final WorkItemAssigneeSnapshot _snapshot;
  bool _consumed = false;

  final String actorId;
  final int expectedUserId;
  final int readEpoch;
  final bool setWorkItemMetadata;
  final bool assigneesWidgetPresent;

  WorkItemGraphSummary get summary => _snapshot.summary;
  DateTime get updatedAt => _snapshot.updatedAt;
  bool get allowsMultiple => _snapshot.allowsMultiple;
  List<String> get assigneeIds => _snapshot.assigneeIds;
  bool get consumed => _consumed;
}

extension WorkItemAssigneeApi on GitLabApi {
  /// Walks the assignees connection to completion for [detail]'s summary.
  ///
  /// Each page is `first: 100` and must repeat the same actor, work-item
  /// identity and revision. The detail view's existing first 20 assignees are
  /// not a write set. At most 20 pages are accepted. A 20th page that still
  /// has another page fails as unsupported and does not return a target.
  Future<WorkItemAssigneeAccess> workItemAssignees(
    WorkItemGraphDetail detail, {
    required int expectedUserId,
    bool Function()? isCurrent,
  }) {
    _validateAssigneeExpected(detail.summary, expectedUserId);
    return _readWorkItemAssignees(
      detail.summary,
      expectedUserId: expectedUserId,
      isCurrent: isCurrent,
    );
  }

  /// One autocomplete array, at most 20 users, with no connection paging.
  ///
  /// A project summary queries only that project. A summary with no project
  /// queries only its group namespace. The search does not consume [target].
  /// Candidate membership is not authorization. Users already in
  /// [WorkItemAssigneeTarget.assigneeIds] stay selected even when this array
  /// omits them.
  Future<List<WorkItemAssigneeUser>> searchWorkItemAssigneeCandidates(
    WorkItemAssigneeTarget target, {
    required String search,
    bool Function()? isCurrent,
  }) async {
    final normalized = _validatedAssigneeSearch(search);
    _requireActivityOwner(target._owner);
    if (target._consumed) throw _assigneesUncertain;
    _requireCurrentWorkItemRequest(isCurrent);
    if (_readEpoch != target.readEpoch) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    final scope = _assigneeCandidateScope(target.summary);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': scope.project
            ? _projectAssigneeCandidatesQuery
            : _groupAssigneeCandidatesQuery,
        'variables': {'fullPath': scope.fullPath, 'search': normalized},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    if (_readEpoch != target.readEpoch) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    try {
      final data = _assigneeGraphData(response.bytes, mutation: false);
      final actorId = _requiredAssigneeActor(data, target.expectedUserId);
      if (actorId != target.actorId) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      final container = objectJson(data[scope.project ? 'project' : 'group']);
      final id = requiredString(container, 'id');
      final fullPath = requiredString(container, 'fullPath');
      if (id != scope.id || fullPath != scope.fullPath) {
        throw const FormatException('Wrong assignee container');
      }
      final rawUsers = container['autocompleteUsers'];
      if (rawUsers is! List || rawUsers.length > _assigneeCandidateLimit) {
        throw const FormatException('Invalid assignee candidates');
      }
      final users = <WorkItemAssigneeUser>[];
      final seen = <String>{};
      for (final raw in rawUsers) {
        final user = _parseAssigneeUser(raw);
        if (!seen.add(user.id)) {
          throw const FormatException('Duplicate assignee candidate');
        }
        users.add(user);
      }
      return List<WorkItemAssigneeUser>.unmodifiable(users);
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw _assigneesUnsupported;
    }
  }

  /// Replaces the assignee set. Empty [assigneeIds] clears it.
  ///
  /// The target is consumed before the fresh read, including when the desired
  /// set is already current. That read must still match the actor, owner,
  /// identity, revision, permission, widget, multiplicity and current ids.
  /// Exactly one `workItemUpdate` is sent, and only `id` plus
  /// `assigneesWidget.assigneeIds`. After that request is handed to the
  /// transport, HTTP 400, 422, other HTTP failures, cancellation and a body
  /// that is not the contract are [FailureKind.writeUncertain] and are not
  /// replayed. HTTP 200 with a non-empty string `errors` list is validation
  /// even when the body has no actor. The mutation does not select
  /// `currentUser`; an extra one is ignored. Acknowledgement uses the bound
  /// target actor, and every continuation page must keep the mutation first
  /// page revision. Success publishes only a separate complete read. A dropped
  /// or truncated user is uncertain. Readback [updatedAt] may move forward and
  /// is not publication authority.
  Future<WorkItemAssigneeSnapshot> updateWorkItemAssignees(
    WorkItemAssigneeTarget target, {
    required List<String> assigneeIds,
    bool Function()? isCurrent,
  }) async {
    _validateAssigneeSelection(
      assigneeIds,
      allowsMultiple: target.allowsMultiple,
    );
    _requireActivityOwner(target._owner);
    if (target._consumed) throw _assigneesUncertain;
    target._consumed = true;
    final before = await _readWorkItemAssignees(
      target.summary,
      expectedUserId: target.expectedUserId,
      isCurrent: isCurrent,
    );
    if (before.actorId != target.actorId ||
        !before.canWrite ||
        before.target == null) {
      throw before.actorId == target.actorId
          ? _assigneesWriteForbidden
          : const ApiFailure(FailureKind.cancelled);
    }
    if (!_sameAssigneeFence(before.snapshot, target._snapshot)) {
      throw _assigneesConflict;
    }
    if (_readEpoch != target.readEpoch) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    _requireCurrentWorkItemRequest(isCurrent);
    final desired = List<String>.unmodifiable(assigneeIds);
    if (_sameAssigneeIdSet(before.snapshot.assigneeIds, desired)) {
      return before.snapshot;
    }

    ({Uint8List bytes, Headers headers, int statusCode}) response;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': _workItemAssigneesMutation,
          'variables': {
            'input': <String, Object?>{
              'id': before.snapshot.summary.id,
              'assigneesWidget': <String, Object?>{'assigneeIds': desired},
            },
          },
        },
      );
    } on Object {
      throw _assigneesUncertain;
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _assigneeGraphData(response.bytes, mutation: true);
      final payload = objectJson(data['workItemUpdate']);
      final errors = payload['errors'];
      if (errors is! List || errors.any((error) => error is! String)) {
        throw const FormatException('Invalid assignee errors');
      }
      if (errors.isNotEmpty) throw _assigneesRejected;
      final acknowledged = await _acknowledgeAssigneeWorkItem(
        payload['workItem'],
        target,
        isCurrent: isCurrent,
      );
      if (acknowledged.actorId != target.actorId ||
          !_sameAssigneeIdSet(acknowledged.snapshot.assigneeIds, desired) ||
          acknowledged.snapshot.allowsMultiple != target.allowsMultiple) {
        throw const FormatException('Wrong assignee acknowledgement');
      }
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.validation) rethrow;
      throw _assigneesUncertain;
    } on Object {
      throw _assigneesUncertain;
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final readback = await _readWorkItemAssignees(
        target.summary,
        expectedUserId: target.expectedUserId,
        isCurrent: isCurrent,
      );
      if (readback.actorId != target.actorId ||
          !_sameAssigneeIdentity(readback.snapshot.summary, target.summary) ||
          !_sameAssigneeIdSet(readback.snapshot.assigneeIds, desired)) {
        throw const FormatException('Wrong assignee readback');
      }
      return readback.snapshot;
    } on Object {
      throw _assigneesUncertain;
    }
  }

  Future<WorkItemAssigneeAccess> _readWorkItemAssignees(
    WorkItemGraphSummary expected, {
    required int expectedUserId,
    bool Function()? isCurrent,
  }) async {
    _requireCurrentWorkItemRequest(isCurrent);
    final users = <WorkItemAssigneeUser>[];
    final seenUsers = <String>{};
    final seenCursors = <String>{};
    String? cursor;
    DateTime? revision;
    String? actorId;
    var allowsMultiple = false;
    var canWrite = false;
    WorkItemGraphSummary? summary;
    for (var page = 0; page < _assigneeMaxPages; page++) {
      _requireCurrentWorkItemRequest(isCurrent);
      final response = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': _workItemAssigneesQuery,
          'variables': {'id': expected.id, 'after': cursor},
        },
      );
      _requireCurrentWorkItemRequest(isCurrent);
      final parsed = _parseAssigneeReadPage(
        response.bytes,
        expected: expected,
        expectedUserId: expectedUserId,
        expectedCursor: cursor,
      );
      if (actorId == null) {
        actorId = parsed.actorId;
        revision = parsed.snapshot.updatedAt;
        allowsMultiple = parsed.snapshot.allowsMultiple;
        canWrite = parsed.canWrite;
        summary = parsed.snapshot.summary;
      } else if (parsed.actorId != actorId ||
          parsed.snapshot.updatedAt != revision ||
          parsed.snapshot.allowsMultiple != allowsMultiple ||
          parsed.canWrite != canWrite ||
          !_sameAssigneeIdentity(parsed.snapshot.summary, summary!)) {
        throw _assigneesUnsupported;
      }
      for (final user in parsed.page.users) {
        if (!seenUsers.add(user.id)) throw _assigneesUnsupported;
        users.add(user);
      }
      if (!parsed.page.hasNextPage) {
        final snapshot = WorkItemAssigneeSnapshot(
          users: List<WorkItemAssigneeUser>.unmodifiable(users),
          allowsMultiple: allowsMultiple,
          updatedAt: revision!,
          actorId: actorId,
          summary: summary,
        );
        return WorkItemAssigneeAccess._(
          snapshot: snapshot,
          actorId: actorId,
          canWrite: canWrite,
          target: canWrite
              ? WorkItemAssigneeTarget._(
                  owner: this,
                  actorId: actorId,
                  expectedUserId: expectedUserId,
                  snapshot: snapshot,
                  readEpoch: _readEpoch,
                )
              : null,
        );
      }
      final next = parsed.page.endCursor;
      if (next == null || !seenCursors.add(next)) throw _assigneesUnsupported;
      cursor = next;
    }
    throw _assigneesUnsupported;
  }

  Future<({String actorId, WorkItemAssigneeSnapshot snapshot})>
  _acknowledgeAssigneeWorkItem(
    Object? raw,
    WorkItemAssigneeTarget target, {
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(target._owner);
    _requireCurrentWorkItemRequest(isCurrent);
    final first = _parseAssigneeWidgetNode(raw, target.summary);
    final users = <WorkItemAssigneeUser>[...first.page.users];
    final seenUsers = <String>{for (final user in users) user.id};
    if (seenUsers.length != users.length) {
      throw const FormatException('Duplicate acknowledged assignee');
    }
    var cursor = first.page.endCursor;
    final seenCursors = <String>{};
    var hasNext = first.page.hasNextPage;
    if (hasNext) {
      if (cursor == null || !seenCursors.add(cursor)) {
        throw const FormatException('Invalid assignee acknowledgement');
      }
    }
    for (var page = 1; hasNext && page < _assigneeMaxPages; page++) {
      _requireCurrentWorkItemRequest(isCurrent);
      final response = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': _workItemAssigneesQuery,
          'variables': {'id': target.summary.id, 'after': cursor},
        },
      );
      final parsed = _parseAssigneeReadPage(
        response.bytes,
        expected: target.summary,
        expectedUserId: target.expectedUserId,
        expectedCursor: cursor,
      );
      if (parsed.actorId != target.actorId ||
          parsed.snapshot.updatedAt != first.updatedAt ||
          parsed.snapshot.allowsMultiple != first.allowsMultiple ||
          !_sameAssigneeIdentity(parsed.snapshot.summary, target.summary)) {
        throw const FormatException('Invalid assignee acknowledgement');
      }
      for (final user in parsed.page.users) {
        if (!seenUsers.add(user.id)) {
          throw const FormatException('Duplicate acknowledged assignee');
        }
        users.add(user);
      }
      hasNext = parsed.page.hasNextPage;
      if (!hasNext) break;
      final next = parsed.page.endCursor;
      if (next == null || !seenCursors.add(next)) {
        throw const FormatException('Invalid assignee acknowledgement');
      }
      cursor = next;
    }
    if (hasNext) {
      throw const FormatException('Incomplete assignee acknowledgement');
    }
    return (
      actorId: target.actorId,
      snapshot: WorkItemAssigneeSnapshot(
        users: List<WorkItemAssigneeUser>.unmodifiable(users),
        allowsMultiple: first.allowsMultiple,
        updatedAt: first.updatedAt,
        actorId: target.actorId,
        summary: first.summary,
      ),
    );
  }
}

void _validateAssigneeExpected(
  WorkItemGraphSummary expected,
  int expectedUserId,
) {
  if (expectedUserId <= 0 || !_validOpaqueGraphId(expected.id)) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (expected.project == null && expected.namespace == null) {
    throw const ApiFailure(FailureKind.validation);
  }
}

String _validatedAssigneeSearch(String value) {
  final search = value.trim();
  if (search.runes.length > 256 || search.contains('\u0000')) {
    throw const ApiFailure(
      FailureKind.validation,
      title: '搜尋無效',
      detail: '負責人搜尋不能超過 256 個字元。',
    );
  }
  return search;
}

void _validateAssigneeSelection(
  List<String> assigneeIds, {
  required bool allowsMultiple,
}) {
  if (assigneeIds.length > _assigneePageSize * _assigneeMaxPages) {
    throw const ApiFailure(
      FailureKind.validation,
      title: '負責人無效',
      detail: '一次最多設定 2000 位負責人。',
    );
  }
  final seen = <String>{};
  for (final id in assigneeIds) {
    if (!_validAssigneeUserId(id) || !seen.add(id)) {
      throw const ApiFailure(
        FailureKind.validation,
        title: '負責人無效',
        detail: '負責人必須是不重複的使用者全域 ID。',
      );
    }
  }
  if (!allowsMultiple && assigneeIds.length > 1) {
    throw const ApiFailure(
      FailureKind.validation,
      title: '負責人無效',
      detail: '這個工作項目只能設定一位負責人。',
    );
  }
}

({bool project, String id, String fullPath}) _assigneeCandidateScope(
  WorkItemGraphSummary summary,
) {
  final project = summary.project;
  if (project != null) {
    if (!_isGraphIdType(project.id, const {'Project'})) {
      throw _assigneesUnsupported;
    }
    return (project: true, id: project.id, fullPath: project.fullPath);
  }
  final namespace = summary.namespace;
  if (namespace == null || !_isGraphIdType(namespace.id, const {'Group'})) {
    throw _assigneesUnsupported;
  }
  return (project: false, id: namespace.id, fullPath: namespace.fullPath);
}

({
  String actorId,
  WorkItemAssigneeSnapshot snapshot,
  WorkItemAssigneePage page,
  bool canWrite,
})
_parseAssigneeReadPage(
  Uint8List bytes, {
  required WorkItemGraphSummary expected,
  required int expectedUserId,
  required String? expectedCursor,
}) {
  try {
    final data = _assigneeGraphData(bytes, mutation: false);
    final actorId = _requiredAssigneeActor(data, expectedUserId);
    if (data['workItem'] == null) {
      throw const ApiFailure(
        FailureKind.invisible,
        title: '找不到工作項目',
        detail: '這個項目可能不存在，或目前帳號無法讀取。',
      );
    }
    final node = objectJson(data['workItem']);
    final summary = _parseWorkItemSummary(node);
    if (!_sameAssigneeIdentity(summary, expected)) {
      throw const FormatException('Wrong assignee identity');
    }
    if (!node.containsKey('userPermissions')) {
      throw const FormatException('Missing assignee permissions');
    }
    final permissions = objectJson(node['userPermissions']);
    if (!permissions.containsKey('readWorkItem') ||
        !permissions.containsKey('setWorkItemMetadata')) {
      throw const FormatException('Missing assignee permission');
    }
    final readWorkItem = permissions['readWorkItem'];
    final setMetadata = permissions['setWorkItemMetadata'];
    if (readWorkItem is! bool || setMetadata is! bool) {
      throw const FormatException('Invalid assignee permission');
    }
    if (!readWorkItem) throw _assigneesReadForbidden;
    final widget = _parseAssigneeWidgetNode(node, expected);
    if (widget.page.hasNextPage &&
        (widget.page.endCursor == null ||
            widget.page.endCursor == expectedCursor)) {
      throw const FormatException('Assignee cursor did not progress');
    }
    return (
      actorId: actorId,
      canWrite: setMetadata,
      page: widget.page,
      snapshot: WorkItemAssigneeSnapshot(
        users: widget.page.users,
        allowsMultiple: widget.allowsMultiple,
        updatedAt: summary.updatedAt,
        actorId: actorId,
        summary: summary,
      ),
    );
  } on ApiFailure {
    rethrow;
  } on FormatException {
    throw _assigneesUnsupported;
  }
}

({
  WorkItemGraphSummary summary,
  bool allowsMultiple,
  DateTime updatedAt,
  WorkItemAssigneePage page,
})
_parseAssigneeWidgetNode(Object? raw, WorkItemGraphSummary expected) {
  final node = objectJson(raw);
  final summary = _parseWorkItemSummary(node);
  if (!_sameAssigneeIdentity(summary, expected)) {
    throw const FormatException('Wrong assignee identity');
  }
  final rawWidgets = node['widgets'];
  if (rawWidgets is! List || rawWidgets.length != 1) {
    throw const FormatException('Missing assignees widget');
  }
  final widget = objectJson(rawWidgets.single);
  if (widget['type'] != 'ASSIGNEES') {
    throw const FormatException('Unexpected assignees widget');
  }
  if (!widget.containsKey('allowsMultipleAssignees')) {
    throw const FormatException('Missing allowsMultipleAssignees');
  }
  final allowsMultiple = widget['allowsMultipleAssignees'];
  if (allowsMultiple is! bool) {
    throw const FormatException('Invalid allowsMultipleAssignees');
  }
  final connection = widget['assignees'];
  if (connection is! Map) {
    throw const FormatException('Missing assignees connection');
  }
  final nodes = connection['nodes'];
  if (nodes is! List || nodes.length > _assigneePageSize) {
    throw const FormatException('Invalid assignees page');
  }
  final pageInfo = objectJson(connection['pageInfo']);
  final hasNext = pageInfo['hasNextPage'];
  final rawCursor = pageInfo['endCursor'];
  if (hasNext is! bool) {
    throw const FormatException('Invalid assignee page info');
  }
  if (rawCursor != null &&
      (rawCursor is! String ||
          rawCursor.isEmpty ||
          rawCursor.length > _workItemCursorLimit)) {
    throw const FormatException('Invalid assignee cursor');
  }
  if (hasNext && rawCursor is! String) {
    throw const FormatException('Missing assignee cursor');
  }
  final users = <WorkItemAssigneeUser>[];
  final seen = <String>{};
  for (final rawUser in nodes) {
    final user = _parseAssigneeUser(rawUser);
    if (!seen.add(user.id)) throw const FormatException('Duplicate assignee');
    users.add(user);
  }
  return (
    summary: summary,
    allowsMultiple: allowsMultiple,
    updatedAt: summary.updatedAt,
    page: WorkItemAssigneePage(
      users: List<WorkItemAssigneeUser>.unmodifiable(users),
      endCursor: rawCursor is String ? rawCursor : null,
      hasNextPage: hasNext,
    ),
  );
}

WorkItemAssigneeUser _parseAssigneeUser(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  if (!_validAssigneeUserId(id)) {
    throw const FormatException('Invalid assignee user');
  }
  return WorkItemAssigneeUser(
    id: id,
    name: _boundedRequiredText(node, 'name', 255),
    username: _boundedRequiredText(node, 'username', 255),
  );
}

bool _validAssigneeUserId(String id) =>
    RegExp(r'^gid://gitlab/User/[1-9][0-9]*$').hasMatch(id);

String _requiredAssigneeActor(Json data, int expectedUserId) {
  if (!data.containsKey('currentUser')) {
    throw const FormatException('Missing assignee actor');
  }
  final actorId = _parseNotificationActor(data['currentUser']);
  if (actorId == null) {
    throw const ApiFailure(
      FailureKind.unauthenticated,
      title: '登入已失效',
      detail: '請重新連接目前帳號，再讀取工作項目負責人。',
    );
  }
  if (_notificationActorNumber(actorId) != expectedUserId) {
    throw const ApiFailure(FailureKind.cancelled);
  }
  return actorId;
}

bool _sameAssigneeIdentity(
  WorkItemGraphSummary actual,
  WorkItemGraphSummary expected,
) =>
    actual.id == expected.id &&
    actual.iid == expected.iid &&
    actual.type.id == expected.type.id &&
    actual.type.name == expected.type.name &&
    _sameAttributeRef(actual.project, expected.project) &&
    _sameAttributeRef(actual.namespace, expected.namespace);

bool _sameAssigneeFence(
  WorkItemAssigneeSnapshot fresh,
  WorkItemAssigneeSnapshot bound,
) =>
    _sameAssigneeIdentity(fresh.summary, bound.summary) &&
    fresh.summary.updatedAt == bound.summary.updatedAt &&
    fresh.allowsMultiple == bound.allowsMultiple &&
    _sameAssigneeIdSet(fresh.assigneeIds, bound.assigneeIds);

bool _sameAssigneeIdSet(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  final a = left.toSet();
  final b = right.toSet();
  return a.length == left.length &&
      b.length == right.length &&
      a.length == b.length &&
      a.containsAll(b);
}

Json _assigneeGraphData(Uint8List bytes, {required bool mutation}) {
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
        if (unsupported && !mutation) throw _assigneesUnsupported;
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
