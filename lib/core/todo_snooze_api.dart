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

/// GraphQL `TodoTargetEnum` values the inbox opens natively, as REST names them.
const _todoTargetTypes = {'ISSUE': 'Issue', 'MERGEREQUEST': 'MergeRequest', 'COMMIT': 'Commit', 'WORKITEM': 'WorkItem'};

final _todoGid = RegExp(r'^gid://gitlab/Todo/([1-9][0-9]*)$');
final _projectGid = RegExp(r'^gid://gitlab/Project/([1-9][0-9]*)$');

/// Snoozing hides a pending todo until a time (GitLab 17.9+). REST
/// `GET /todos` leaves snoozed todos out, so the snoozed list and both writes
/// go through GraphQL. Writes are never retried.
extension TodoSnoozeApi on GitLabApi {
  /// Snoozes todo [id] until [until] and returns the time GitLab acknowledged.
  Future<DateTime> snoozeTodo(int id, DateTime until) async {
    if (id <= 0 || !until.isAfter(DateTime.now())) throw const ApiFailure(FailureKind.validation);
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
  Future<void> unsnoozeTodo(int id) async {
    if (id <= 0) throw const ApiFailure(FailureKind.validation);
    final response = await _send(instance.graphQL, method: 'POST', graphMutation: true, data: {
      'query': _todoUnsnoozeMutation,
      'variables': {'id': 'gid://gitlab/Todo/$id'},
    });
    final todo = _todoMutationTodo(response.bytes, 'todoUnSnooze', id);
    if (todo['snoozedUntil'] != null) throw const ApiFailure(FailureKind.invalidResponse);
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
          title: unsupported ? '這個 GitLab 不支援延後待辦' : null,
          detail: unsupported ? '延後待辦需要 GitLab 17.9 以上。' : null,
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
