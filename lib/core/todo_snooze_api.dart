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
        targetEntity {
          __typename
          ... on Issue { id iid project { id fullPath } }
          ... on MergeRequest { id iid project { id fullPath } }
          ... on WorkItem {
            id iid project { id fullPath } namespace { id fullPath }
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
        targetEntity {
          __typename
          ... on Issue { id iid project { id fullPath } }
          ... on MergeRequest { id iid project { id fullPath } }
          ... on WorkItem {
            id iid project { id fullPath } namespace { id fullPath }
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
    if (todo['snoozedUntil'] != null) throw const ApiFailure(FailureKind.invalidResponse);
  }

  /// A complete, actor-bound pending ownership set, including expired snoozes.
  /// `items` contains only supported project targets. IDs in `unsupportedIds`
  /// are known but must be refused as todoUnsupportedTarget; an ID absent from
  /// both collections is foreign to this complete set (todoForeign).
  Future<({String actorId, List<Json> items, Set<int> unsupportedIds})> pendingTodosForSnooze({
    int maxPages = 4,
  }) => _todosForSnoozeOwnership(_pendingTodosForSnoozeQuery, maxPages);

  /// A complete, actor-bound set of currently snoozed pending todos.
  /// Uses the same supported/unsupported/absent contract as [pendingTodosForSnooze].
  Future<({String actorId, List<Json> items, Set<int> unsupportedIds})> snoozedTodosForUnsnooze({
    int maxPages = 4,
  }) => _todosForSnoozeOwnership(_snoozedTodosForUnsnoozeQuery, maxPages);

  Future<({String actorId, List<Json> items, Set<int> unsupportedIds})> _todosForSnoozeOwnership(
    String query,
    int maxPages,
  ) async {
    if (maxPages < 1 || maxPages > 4) throw const ApiFailure(FailureKind.validation);
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
          final todo = _snoozeOwnershipTodo(objectJson(raw));
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

({int id, Json? item}) _snoozeOwnershipTodo(Json node) {
  final todo = _todoGid.firstMatch(requiredString(node, 'id'));
  if (todo == null) throw const FormatException('Invalid todo identity');
  final id = int.parse(todo.group(1)!);
  // Null is a valid unsupported target; an omitted field is a schema error.
  if (!node.containsKey('project') || !node.containsKey('targetEntity') ||
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
  var namespaceMatches = true;
  // Only these fragments select an ID, iid and project. Unknown target types
  // and Commit can legally return only __typename, so do not demand fragments
  // that the query did not select for them.
  if (entity != null && const {'Issue', 'MergeRequest', 'WorkItem'}.contains(entityType)) {
    entityId = requiredString(entity, 'id');
    if (!RegExp('^gid://gitlab/$entityType/[1-9][0-9]*\$').hasMatch(entityId)) {
      throw const FormatException('Invalid todo target identity');
    }
    final rawIid = '${entity['iid']}';
    iid = RegExp(r'^[1-9][0-9]*$').hasMatch(rawIid) ? int.tryParse(rawIid) : null;
    if (iid == null || iid <= 0 || !entity.containsKey('project')) {
      throw const FormatException('Invalid todo target coordinates');
    }
    ownProject = _snoozeOwnershipProject(entity['project']);
    if (entityType == 'WorkItem') {
      final namespace = objectJson(entity['namespace']);
      final namespaceId = requiredString(namespace, 'id');
      final namespacePath = requiredString(namespace, 'fullPath');
      final projectNamespace = RegExp(r'^gid://gitlab/Namespaces::ProjectNamespace/[1-9][0-9]*$').hasMatch(namespaceId);
      final groupNamespace = RegExp(r'^gid://gitlab/Group/[1-9][0-9]*$').hasMatch(namespaceId);
      if ((!projectNamespace && !groupNamespace) ||
          _validatedNamespacePathOrNull(namespacePath) != namespacePath) {
        throw const FormatException('Invalid todo work item namespace');
      }
      namespaceMatches = project != null &&
          ((projectNamespace && namespacePath == project.path) ||
              (groupNamespace && project.path.startsWith('$namespacePath/')));
    }
  }
  if (project == null || expected == null || entityType != expected ||
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
