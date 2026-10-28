part of 'gitlab_api.dart';

/// Most snoozed todos the inbox lists in one read; GitLab pages them by
/// cursor, and a person rarely has more snoozed at once.
const todoSnoozedLimit = 100;

const _todoSchemaErrors = {
  'undefinedField',
  'undefinedArgument',
  'undefinedType',
  'variableRequiresValidType',
  'argumentLiteralsIncompatible',
  'missingRequiredArguments',
};

const _todoSnoozeMutation = r'''
mutation MobileTodoSnooze($id: TodoID!, $until: Time!) {
  todoSnooze(input: {id: $id, snoozeUntil: $until}) {
    todo { id snoozedUntil }
    errors
  }
}''';

const _todoUnsnoozeMutation = r'''
mutation MobileTodoUnsnooze($id: TodoID!) {
  todoUnSnooze(input: {id: $id}) {
    todo { id snoozedUntil }
    errors
  }
}''';

const _snoozedTodosQuery = r'''
query MobileSnoozedTodos($first: Int!) {
  currentUser {
    todos(state: pending, isSnoozed: true, first: $first) {
      pageInfo { hasNextPage }
      nodes {
        id action body createdAt snoozedUntil targetType targetUrl
        author { username }
        project { id fullPath }
        targetEntity {
          ... on Issue { iid title }
          ... on MergeRequest { iid title }
          ... on WorkItem { iid title }
          ... on Commit { sha title }
        }
      }
    }
  }
}''';

// These ownership reads deliberately have fixed filters. They do not use the
// inbox's partial list or a REST fallback to prove that a todo can be written.
const _pendingTodosForSnoozeQuery = r'''
query MobilePendingTodosForSnooze($first: Int!, $after: String) {
  currentUser {
    id
    todos(state: pending, isSnoozed: false, first: $first, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id targetType snoozedUntil
        project { id fullPath }
        group { id fullPath }
        targetEntity {
          __typename
          ... on Issue { issueId: id iid projectId }
          ... on MergeRequest { mergeRequestId: id iid mergeRequestProject: project { id fullPath } }
          ... on WorkItem {
            workItemId: id iid workItemProject: project { id fullPath } namespace { id fullPath }
          }
        }
      }
    }
  }
}''';

const _snoozedTodosForUnsnoozeQuery = r'''
query MobileSnoozedTodosForUnsnooze($first: Int!, $after: String) {
  currentUser {
    id
    todos(state: pending, isSnoozed: true, first: $first, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id targetType snoozedUntil
        project { id fullPath }
        group { id fullPath }
        targetEntity {
          __typename
          ... on Issue { issueId: id iid projectId }
          ... on MergeRequest { mergeRequestId: id iid mergeRequestProject: project { id fullPath } }
          ... on WorkItem {
            workItemId: id iid workItemProject: project { id fullPath } namespace { id fullPath }
          }
        }
      }
    }
  }
}''';

/// GraphQL `TodoTargetEnum` values the inbox opens natively, as REST names them.
const _todoTargetTypes = {'ISSUE': 'Issue', 'MERGEREQUEST': 'MergeRequest', 'COMMIT': 'Commit', 'WORKITEM': 'WorkItem'};

final _todoGid = RegExp(r'^gid://gitlab/Todo/([1-9][0-9]*)$');
final _projectGid = RegExp(r'^gid://gitlab/Project/([1-9][0-9]*)$');

/// Snoozing hides a pending todo until a time (GitLab 17.9+). REST
/// `GET /todos` leaves snoozed todos out, so the snoozed list and both writes
/// go through GraphQL. Writes are never retried.
///
/// Group-write callers must bind the verified owner and Todo ID on the strict
/// ownership reader before sending: [pendingTodosForSnooze] for snooze and
/// [snoozedTodosForUnsnooze] for unsnooze. The preflight must prove that the
/// exact Todo belongs to the expected actor and group work item. The
/// mutation acknowledgement must return the same Todo ID and expected time
/// (null for unsnooze); a missing or mismatched acknowledgement is uncertain.
/// The group family owns this sequence and uses no post-send readback (Mrb=0).
/// Note and reaction writes have a separate strict readback requirement.
extension TodoSnoozeApi on GitLabApi {
  /// Snoozes todo [id] until [until] and returns the time GitLab acknowledged.
  Future<DateTime> snoozeTodo(int id, DateTime until, {
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    if (id <= 0 || !until.isAfter(DateTime.now())) throw const ApiFailure(FailureKind.validation);
    if (beforeMutation != null) await beforeMutation();
    if (mayStart != null && !mayStart()) throw const ApiFailure(FailureKind.cancelled);
    final response = await _send(instance.graphQL, method: 'POST', graphMutation: true, data: {
      'query': _todoSnoozeMutation,
      'variables': {'id': 'gid://gitlab/Todo/$id', 'until': until.toUtc().toIso8601String()},
    });
    final todo = _todoMutationTodo(response.bytes, 'todoSnooze', id);
    final acknowledged = DateTime.tryParse('${todo['snoozedUntil'] ?? ''}');
    if (acknowledged == null) throw const ApiFailure(FailureKind.invalidResponse);
    return acknowledged;
  }

  /// Brings snoozed todo [id] back to the pending list now.
  Future<void> unsnoozeTodo(int id, {
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    if (id <= 0) throw const ApiFailure(FailureKind.validation);
    if (beforeMutation != null) await beforeMutation();
    if (mayStart != null && !mayStart()) throw const ApiFailure(FailureKind.cancelled);
    final response = await _send(instance.graphQL, method: 'POST', graphMutation: true, data: {
      'query': _todoUnsnoozeMutation,
      'variables': {'id': 'gid://gitlab/Todo/$id'},
    });
    final todo = _todoMutationTodo(response.bytes, 'todoUnSnooze', id);
    if (!todo.containsKey('snoozedUntil') || todo['snoozedUntil'] != null) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// A complete, actor-bound pending ownership set, including expired snoozes.
  /// `items` contains supported project targets and, when explicitly enabled,
  /// verified group Work Items. IDs in `unsupportedIds`
  /// are known but must be refused as todoUnsupportedTarget; an ID absent from
  /// both collections is not found in this complete set (todoNotFound).
  Future<({String actorId, List<Json> items, Set<int> unsupportedIds})> pendingTodosForSnooze({
    int maxPages = 4,
    bool allowGroupTargets = false,
    VerifiedGroupWorkItemIdentity? strictGroupOwner,
    int? strictGroupTodoId,
  }) => _todosForSnoozeOwnership(_pendingTodosForSnoozeQuery, maxPages, allowGroupTargets,
    strictGroupOwner: strictGroupOwner, strictGroupTodoId: strictGroupTodoId);

  /// A complete, actor-bound set of currently snoozed pending todos.
  /// Uses the same supported/unsupported/absent contract as [pendingTodosForSnooze].
  Future<({String actorId, List<Json> items, Set<int> unsupportedIds})> snoozedTodosForUnsnooze({
    int maxPages = 4,
    bool allowGroupTargets = false,
    VerifiedGroupWorkItemIdentity? strictGroupOwner,
    int? strictGroupTodoId,
  }) => _todosForSnoozeOwnership(_snoozedTodosForUnsnoozeQuery, maxPages, allowGroupTargets,
    strictGroupOwner: strictGroupOwner, strictGroupTodoId: strictGroupTodoId);

  Future<({String actorId, List<Json> items, Set<int> unsupportedIds})> _todosForSnoozeOwnership(
    String query,
    int maxPages,
    bool allowGroupTargets, {
    VerifiedGroupWorkItemIdentity? strictGroupOwner,
    int? strictGroupTodoId,
  }) async {
    _requireStrictGroupOwnerApi(this, strictGroupOwner);
    if (maxPages < 1 || maxPages > 4) throw const ApiFailure(FailureKind.validation);
    if ((strictGroupOwner == null) != (strictGroupTodoId == null) ||
        (strictGroupTodoId != null && (strictGroupTodoId <= 0 || !allowGroupTargets))) {
      throw const ApiFailure(FailureKind.validation);
    }
    String? actorId;
    String? after;
    final cursors = <String>{};
    final ids = <int>{};
    final items = <Json>[];
    final unsupportedIds = <int>{};
    for (var page = 0; page < maxPages; page++) {
      final response = await _read(instance.graphQL, method: 'POST', graphQuery: true, data: {
        'query': query,
        'variables': {'first': todoSnoozedLimit, 'after': after},
      });
      final data = _todoGraphData(response.bytes);
      if (data['currentUser'] == null) throw const ApiFailure(FailureKind.unauthenticated);
      try {
        final user = objectJson(data['currentUser']);
        final currentActor = requiredString(user, 'id');
        if (!RegExp(r'^gid://gitlab/User/[1-9][0-9]*$').hasMatch(currentActor) ||
            (actorId != null && actorId != currentActor)) {
          throw const FormatException('Changed todo actor');
        }
        actorId = currentActor;
        final connection = objectJson(user['todos']);
        final nodes = connection['nodes'];
        if (nodes is! List || nodes.length > todoSnoozedLimit) {
          throw const FormatException('Invalid todo page');
        }
        for (final raw in nodes) {
          final node = objectJson(raw);
          final todo = _snoozeOwnershipTodo(node, allowGroupTargets: allowGroupTargets);
          if (strictGroupOwner != null && todo.id == strictGroupTodoId) {
            _requireStrictGroupTodoOwner(node, strictGroupOwner);
          }
          if (!ids.add(todo.id)) throw const FormatException('Duplicate todo');
          final item = todo.item;
          if (item == null) {
            unsupportedIds.add(todo.id);
          } else {
            items.add(item);
          }
        }
        final next = _nextWorkItemCursor(connection, previous: after);
        if (next == null) {
          return (
            actorId: currentActor,
            items: List<Json>.unmodifiable(items),
            unsupportedIds: Set<int>.unmodifiable(unsupportedIds),
          );
        }
        if (!cursors.add(next) || page + 1 == maxPages) {
          throw const FormatException('Incomplete todo ownership');
        }
        after = next;
      } on FormatException {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
    }
    throw const ApiFailure(FailureKind.invalidResponse);
  }

  /// The signed-in user's snoozed pending todos in the REST shape the inbox
  /// renders, each with `snoozed_until`. [truncated] when GitLab has more
  /// than [todoSnoozedLimit].
  Future<({List<Json> items, bool truncated})> snoozedTodos() async {
    final response = await _read(instance.graphQL, method: 'POST', graphQuery: true, data: {
      'query': _snoozedTodosQuery,
      'variables': {'first': todoSnoozedLimit},
    });
    final data = _todoGraphData(response.bytes);
    final user = data['currentUser'];
    if (user == null) throw const ApiFailure(FailureKind.unauthenticated);
    try {
      final connection = objectJson(objectJson(user)['todos']);
      final nodes = connection['nodes'];
      if (nodes is! List || nodes.length > todoSnoozedLimit) throw const FormatException('Invalid todo page');
      final pageInfo = objectJson(connection['pageInfo']);
      return (
        items: [for (final node in nodes) _restShapedTodo(objectJson(node))],
        truncated: pageInfo['hasNextPage'] == true,
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
}

/// Reuse the selected target evidence for one exact Todo. The account-wide
/// connection may contain unrelated todos, which are parsed normally.
void _requireStrictGroupTodoOwner(Json node, VerifiedGroupWorkItemIdentity owner) {
  final entity = objectJson(node['targetEntity']);
  if (!node.containsKey('project') || node['project'] != null ||
      node['targetType'] != 'WORKITEM' || entity['__typename'] != 'WorkItem') {
    throw const FormatException('Unproven group todo owner');
  }
  _requireStrictGroupWorkItemOwner({
    'id': entity['workItemId'],
    'iid': entity['iid'],
    if (entity.containsKey('workItemProject')) 'project': entity['workItemProject'],
    'namespace': entity['namespace'],
  }, owner);
  if (node['group'] != null) {
    final group = objectJson(node['group']);
    if (group['id'] != owner.groupGid || group['fullPath'] != owner.fullPath) {
      throw const FormatException('Conflicting group todo owner');
    }
  }
}

({int id, Json? item}) _snoozeOwnershipTodo(Json node, {required bool allowGroupTargets}) {
  final todo = _todoGid.firstMatch(requiredString(node, 'id'));
  if (todo == null) throw const FormatException('Invalid todo identity');
  final id = int.parse(todo.group(1)!);
  // Null is a valid unsupported target; an omitted field is a schema error.
  if (!node.containsKey('project') || !node.containsKey('group') || !node.containsKey('targetEntity') ||
      !node.containsKey('snoozedUntil')) {
    throw const FormatException('Incomplete todo node');
  }
  final until = node['snoozedUntil'];
  if (until != null && (until is! String || DateTime.tryParse(until) == null)) {
    throw const FormatException('Invalid snooze time');
  }
  final project = _snoozeOwnershipProject(node['project']);
  final type = requiredString(node, 'targetType');
  final entity = node['targetEntity'] == null ? null : objectJson(node['targetEntity']);
  final entityType = entity == null ? null : requiredString(entity, '__typename');
  final expected = _todoTargetTypes[type];
  String? entityId;
  int? iid;
  ({int id, String path})? ownProject;
  ({int id, String gid, String path})? group;
  String? groupWorkItemId;
  var namespaceMatches = true;
  // Only these fragments select an ID, iid and project ownership. Unknown target types
  // and Commit can legally return only __typename, so do not demand fragments
  // that the query did not select for them.
  if (entity != null && const {'Issue', 'MergeRequest', 'WorkItem'}.contains(entityType)) {
    final idKey = switch (entityType) {
      'Issue' => 'issueId',
      'MergeRequest' => 'mergeRequestId',
      _ => 'workItemId',
    };
    entityId = requiredString(entity, idKey);
    final entityMatch = RegExp('^gid://gitlab/$entityType/([1-9][0-9]*)\$').firstMatch(entityId);
    if (entityMatch == null) {
      throw const FormatException('Invalid todo target identity');
    }
    final rawIid = '${entity['iid']}';
    iid = RegExp(r'^[1-9][0-9]*$').hasMatch(rawIid) ? int.tryParse(rawIid) : null;
    if (iid == null || iid <= 0) {
      throw const FormatException('Invalid todo target coordinates');
    }
    if (entityType == 'Issue') {
      // Issue exposes only a nullable numeric projectId. Missing or invalid
      // ownership stays unsupported, just like a different own project.
      final projectId = entity['projectId'];
      ownProject = projectId is int && projectId > 0 && projectId == project?.id ? project : null;
      if (project == null && entity.containsKey('projectId') && projectId == null && node['group'] != null) {
        if (int.tryParse(entityMatch.group(1)!) == null) {
          throw const FormatException('Invalid group issue todo identity');
        }
        group = _snoozeOwnershipGroup(node['group']!, allowGroupTargets: allowGroupTargets);
        // GitLab v19.5.0-ee app/models/work_item.rb:3-17 uses the issues
        // table; app/graphql/types/work_item_id_type.rb:19-25,37-50 converts
        // Issue GIDs to WorkItem GIDs using that same row's numeric ID.
        groupWorkItemId = 'gid://gitlab/WorkItem/${entityMatch.group(1)!}';
      }
    } else {
      final projectKey = entityType == 'MergeRequest' ? 'mergeRequestProject' : 'workItemProject';
      if (!entity.containsKey(projectKey)) {
        throw const FormatException('Invalid todo target coordinates');
      }
      ownProject = _snoozeOwnershipProject(entity[projectKey]);
    }
    if (entityType == 'WorkItem') {
      final todoGroup = project == null && ownProject == null && node['group'] != null
          ? _snoozeOwnershipGroup(node['group']!, allowGroupTargets: allowGroupTargets)
          : null;
      final namespace = objectJson(entity['namespace']);
      final namespaceId = requiredString(namespace, 'id');
      final namespacePath = requiredString(namespace, 'fullPath');
      final projectNamespace = RegExp(r'^gid://gitlab/Namespaces::ProjectNamespace/[1-9][0-9]*$').hasMatch(namespaceId);
      final groupId = groupKeyNumericId(namespaceId);
      final groupNamespace = project == null
          ? groupId != null
          : RegExp(r'^gid://gitlab/Group/[1-9][0-9]*$').hasMatch(namespaceId);
      if ((!projectNamespace && !groupNamespace) ||
          _validatedNamespacePathOrNull(namespacePath) != namespacePath ||
          (groupNamespace && !_validStrictGroupPath(namespacePath))) {
        if (!allowGroupTargets && int.tryParse(entityMatch.group(1)!) != null &&
            _snoozeOwnershipGroup(namespace, allowGroupTargets: false) == null) {
          return (id: id, item: null);
        }
        throw const FormatException('Invalid todo work item namespace');
      }
      namespaceMatches = project != null && projectNamespace && namespacePath == project.path;
      if (project == null && ownProject == null && groupId != null) {
        if (int.tryParse(entityMatch.group(1)!) == null) {
          throw const FormatException('Invalid group work item identity');
        }
        group = (id: groupId, gid: namespaceId, path: namespacePath);
        groupWorkItemId = entityId;
        // WorkItem supplies its own namespace evidence; a supplied Todo group
        // must agree with it rather than silently contradict that owner.
        if (node['group'] != null && (todoGroup?.gid != namespaceId || todoGroup?.path != namespacePath)) {
          return (id: id, item: null);
        }
      }
    }
  }
  if (group != null && allowGroupTargets &&
      (expected == 'Issue' || expected == 'WorkItem') &&
      entityType == expected && groupWorkItemId != null && iid != null) {
    return (id: id, item: Map<String, dynamic>.unmodifiable({
      'id': id,
      'target_type': 'WorkItem',
      'snoozed_until': until,
      'project': null,
      'namespace': Map<String, dynamic>.unmodifiable({
        'id': group.gid, 'group_id': group.id, 'full_path': group.path,
      }),
      'target': Map<String, dynamic>.unmodifiable({
        'id': groupWorkItemId, 'iid': iid,
      }),
    }));
  }
  // GitLab v19.5.0-ee todo_service.rb:524-526 and todo.rb:87-90 keep a
  // project's Todo group null, even when that project belongs to a group.
  if (project == null || node['group'] != null || expected == null || entityType != expected ||
      entityId == null || iid == null || ownProject != project || !namespaceMatches) {
    return (id: id, item: null);
  }
  return (id: id, item: Map<String, dynamic>.unmodifiable({
    'id': id,
    'target_type': expected,
    'snoozed_until': until,
    'project': Map<String, dynamic>.unmodifiable({
      'id': project.id, 'path_with_namespace': project.path,
    }),
    'target': Map<String, dynamic>.unmodifiable({
      'id': entityId, 'iid': iid,
    }),
  }));
}

({int id, String gid, String path})? _snoozeOwnershipGroup(Object? raw, {required bool allowGroupTargets}) {
  final owner = objectJson(raw);
  final gid = requiredString(owner, 'id');
  final path = requiredString(owner, 'fullPath');
  final id = groupKeyNumericId(gid);
  if (id == null || !_validStrictGroupPath(path)) {
    // Disabled group targets cannot authorize a write. Keep these two strict
    // identity failures local to the item, preserving all other schema errors.
    if (!allowGroupTargets && gid.startsWith('gid://gitlab/Group/') &&
        _validatedNamespacePathOrNull(path) == path) {
      return null;
    }
    throw const FormatException('Invalid todo group');
  }
  return (id: id, gid: gid, path: path);
}

({int id, String path})? _snoozeOwnershipProject(Object? raw) {
  if (raw == null) return null;
  final project = objectJson(raw);
  final projectId = _projectGid.firstMatch(requiredString(project, 'id'));
  final path = requiredString(project, 'fullPath');
  if (projectId == null || _validatedNamespacePathOrNull(path) != path) {
    throw const FormatException('Invalid todo project');
  }
  return (id: int.parse(projectId.group(1)!), path: path);
}

Json _todoGraphData(Uint8List bytes) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors != null) {
      if (errors is! List) throw const ApiFailure(FailureKind.invalidResponse);
      if (errors.isNotEmpty) {
        final unsupported = errors.every((error) =>
            error is Map && error['extensions'] is Map &&
            _todoSchemaErrors.contains((error['extensions'] as Map)['code']));
        throw ApiFailure(
          unsupported ? FailureKind.unsupported : FailureKind.invalidResponse,
          title: unsupported ? l10n.gitlabNoSnoozeTodos : null,
          detail: unsupported ? l10n.snoozeTodosRequiresGitlab179 : null,
        );
      }
    }
    return objectJson(envelope['data']);
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

/// The `todo` of a snooze mutation payload, checked to be todo [id]. GitLab
/// reports refusals in the payload's `errors` with a 200.
Json _todoMutationTodo(Uint8List bytes, String field, int id) {
  final data = _todoGraphData(bytes);
  try {
    final payload = objectJson(data[field]);
    final errors = payload['errors'];
    if (errors is List && errors.isNotEmpty) {
      throw ApiFailure(FailureKind.validation, detail: errors.whereType<String>().join('\n'));
    }
    final todo = objectJson(payload['todo']);
    final match = _todoGid.firstMatch('${todo['id'] ?? ''}');
    if (match == null || int.parse(match.group(1)!) != id) throw const FormatException('Other todo');
    return todo;
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

Json _restShapedTodo(Json node) {
  final id = _todoGid.firstMatch('${node['id'] ?? ''}');
  if (id == null) throw const FormatException('Invalid todo identity');
  final project = node['project'] is Map ? objectJson(node['project']) : null;
  final projectId = project == null ? null : _projectGid.firstMatch('${project['id'] ?? ''}');
  final entity = node['targetEntity'] is Map ? objectJson(node['targetEntity']) : const <String, dynamic>{};
  final type = '${node['targetType'] ?? ''}';
  return {
    'id': int.parse(id.group(1)!),
    'action_name': node['action'],
    'target_type': _todoTargetTypes[type] ?? type,
    'target_url': node['targetUrl'],
    'body': node['body'],
    'created_at': node['createdAt'],
    'updated_at': node['createdAt'],
    'snoozed_until': node['snoozedUntil'],
    'author': node['author'] is Map ? {'username': objectJson(node['author'])['username']} : null,
    'project': projectId == null
        ? null
        : {'id': int.parse(projectId.group(1)!), 'path_with_namespace': project!['fullPath']},
    'target': {
      if (entity['iid'] != null) 'iid': int.tryParse('${entity['iid']}'),
      if (entity['sha'] != null) 'id': entity['sha'],
      'title': entity['title'],
    },
  };
}
