// Host-only MR7 isolation boundary. No network adapter is constructed here.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';

import 'candidate_release_policy.dart';

const mr7ProtectedProjectId = 86648389;
// Exact fixed ownership documents and mutations in the production Todo API.
const _todoPendingDocument =
    'f22f62567f47f099a08b71a3a4421170e061d1a024b3e86424ae5091af740a3f';
const _todoSnoozedDocument =
    'dfbf11e337a766c288cf3a2d53df90090682f3e79fe20971761c347bbce47ccb';
const _todoSnoozeDocument =
    '701de6e86afdaeeeabf384ee19086320683dc782be8ee9f7fd54a8c810a965c0';
const _todoUnsnoozeDocument =
    'b4daf82ea099dfc04752acd1aa93ed005dff928a76d248549a3822582023ce48';
const mr7ExcludedOperations = {
  'createProject',
  'forkProject',
  'markAllTodosDone',
  'batchApplySuggestions',
  'markTodoDone',
  'snoozeTodo',
  'unsnoozeTodo',
};
String mr7Digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

enum Mr7Policy { production, candidate }

AiReleasePolicyView mr7SandboxPolicy(
  Mr7Policy policy, {
  Set<String> reads = const {},
  Map<String, Set<AiTargetKind>> writes = const {},
}) => policy == Mr7Policy.production
    ? productionAiReleasePolicy
    : mr7CandidateReleasePolicy(readNames: reads, writeTargets: writes);

final class Mr7Refused implements Exception {
  const Mr7Refused(this.code);
  final String code;
  @override
  String toString() => 'Mr7Refused($code)';
}

final class Mr7Identity {
  const Mr7Identity({
    required this.projectId,
    required this.path,
    required this.userId,
    required this.namespaceId,
    required this.namespace,
    required this.nonce,
  });
  final int projectId;
  final String path;
  final int userId;
  final int namespaceId;
  final String namespace;
  final String nonce;
}

final class _Mr7TodoFixture {
  _Mr7TodoFixture({
    required this.id,
    required this.actorId,
    required this.projectId,
    required this.parentPath,
    required this.parentId,
    required this.iid,
    required this.mergeRequest,
    this.snoozedUntil,
  });
  final int id;
  final int actorId;
  final int projectId;
  final String parentPath;
  final int parentId;
  final int iid;
  final bool mergeRequest;
  String? snoozedUntil;
}

ResponseBody mr7Json(
  Object? value, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    'content-type': ['application/json'],
    ...headers,
  },
);

Map<String, List<String>> _pageHeaders(int page, int size, int total) => {
  'x-page': ['$page'],
  'x-per-page': ['$size'],
  'x-total': ['$total'],
  'x-total-pages': ['${total == 0 ? 1 : (total + size - 1) ~/ size}'],
  'x-next-page': [page * size < total ? '${page + 1}' : ''],
};

/// Completeness requires contiguous offset pages and stable, counted totals.
/// Missing metadata, cursor pagination and truncated pages cannot prove absence.
final class _PageSequence {
  int? _total;
  int? _size;
  int? _pages;

  int? next(Response<Object?> response, int page) {
    String header(String key) {
      final values = response.headers[key];
      if (values == null || values.length != 1) {
        throw const Mr7Refused('paginationIncomplete');
      }
      return values.single;
    }

    int number(String key) {
      final value = header(key);
      if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
        throw const Mr7Refused('paginationMalformed');
      }
      return int.parse(value);
    }

    if (response.statusCode != 200 || response.data is! List) {
      throw const Mr7Refused('paginationUnreadable');
    }
    final total = number('x-total');
    final size = number('x-per-page');
    final pages = number('x-total-pages');
    if (number('x-page') != page ||
        size < 1 ||
        size > 100 ||
        page > 20 ||
        (total == 0
            ? pages != 0 && pages != 1
            : pages != (total + size - 1) ~/ size) ||
        pages > 20 ||
        (pages > 0 && page > pages) ||
        (_total != null &&
            (_total != total || _size != size || _pages != pages))) {
      throw const Mr7Refused('paginationInconsistent');
    }
    _total = total;
    _size = size;
    _pages = pages;
    final expectedCount = page < pages ? size : total - (page - 1) * size;
    final next = header('x-next-page');
    if ((response.data! as List).length != expectedCount ||
        next != (page < pages ? '${page + 1}' : '')) {
      throw const Mr7Refused('paginationIncomplete');
    }
    return next.isEmpty ? null : int.parse(next);
  }
}

/// Simulated server, reached through serialized responses. Distinct writer and
/// observer adapters prove synthetic mechanics, never live server effects.
final class Mr7SyntheticGitLab {
  Mr7SyntheticGitLab({this.userId = 7, this.namespace = 'synthetic-owner'});
  final int userId;
  final String namespace;
  int projectId = 909;
  int namespaceId = 70;
  DateTime clock = DateTime.utc(2026, 10, 29);
  Map<String, Object?>? project;
  Map<String, Object?>? byPathOverride;
  final List<Map<String, Object?>> events = [];
  final List<String> requests = [];
  final Map<String, FutureOr<ResponseBody> Function(RequestOptions)> routes =
      {};
  int eventPageSize = 2;
  bool incompleteEvents = false;
  bool unreadableEvents = false;
  bool delayedDeletion = false;
  bool lostWriteReply = false;
  bool wrongWriteReply = false;
  int setupWrites = 0;
  int scenarioWrites = 0;
  int cleanupWrites = 0;
  Map<String, Object?>? _lastUpload;
  final Map<int, _Mr7TodoFixture> _todos = {};
  DateTime get serverTime => clock;

  void addEvent({int? target, String action = 'updated', DateTime? at}) =>
      events.add({
        'id': events.length + 1,
        'created_at': (at ?? clock).toUtc().toIso8601String(),
        'action_name': action,
        'project_id': target,
      });

  Future<ResponseBody> respond(RequestOptions request) async {
    clock = clock.add(const Duration(milliseconds: 10));
    final segments = request.uri.pathSegments;
    final marker = segments.indexOf('v4');
    final path = marker < 0
        ? request.uri.path
        : segments.skip(marker + 1).join('/');
    final key = '${request.method} $path';
    requests.add(key);
    if (key == 'GET projects/$projectId/uploads/mr7-observation') {
      return _lastUpload == null
          ? mr7Json({}, status: 404)
          : mr7Json(_lastUpload);
    }
    final todoRead = RegExp(
      '^GET projects/$projectId/todos/([1-9][0-9]*)/mr7-observation\$',
    ).firstMatch(key);
    if (todoRead != null) {
      final todo = _todos[int.parse(todoRead[1]!)];
      if (todo == null ||
          todo.projectId != projectId ||
          todo.actorId != userId) {
        return mr7Json({}, status: 404);
      }
      return mr7Json({
        'id': todo.id,
        'actor_id': todo.actorId,
        'project_id': todo.projectId,
        'parent_path': todo.parentPath,
        'parent_id': todo.parentId,
        'parent_iid': todo.iid,
        'snoozed_until': todo.snoozedUntil,
      });
    }
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/api/graphql') &&
        request.data is Map) {
      final body = request.data as Map;
      final query = body['query'];
      final vars = body['variables'];
      if (query is String && vars is Map) {
        final digest = mr7Digest(query);
        if (const {
          _todoPendingDocument,
          _todoSnoozedDocument,
        }.contains(digest)) {
          if (vars.length != 2 ||
              vars['first'] != 100 ||
              vars['after'] != null ||
              project == null ||
              _todos.length > 20) {
            throw const Mr7Refused('todoFixtureRead');
          }
          final snoozed = digest == _todoSnoozedDocument;
          final path = project!['path_with_namespace'];
          final nodes = [
            for (final todo in _todos.values)
              if ((todo.snoozedUntil != null) == snoozed)
                {
                  'id': 'gid://gitlab/Todo/${todo.id}',
                  'targetType': todo.mergeRequest ? 'MERGEREQUEST' : 'ISSUE',
                  'snoozedUntil': todo.snoozedUntil,
                  'project': {
                    'id': 'gid://gitlab/Project/${todo.projectId}',
                    'fullPath': path,
                  },
                  'group': null,
                  'targetEntity': {
                    '__typename': todo.mergeRequest ? 'MergeRequest' : 'Issue',
                    if (todo.mergeRequest) ...{
                      'mergeRequestId':
                          'gid://gitlab/MergeRequest/${todo.parentId}',
                      'mergeRequestProject': {
                        'id': 'gid://gitlab/Project/${todo.projectId}',
                        'fullPath': path,
                      },
                    } else ...{
                      'issueId': 'gid://gitlab/Issue/${todo.parentId}',
                      'projectId': todo.projectId,
                    },
                    'iid': todo.iid,
                  },
                },
          ];
          return mr7Json({
            'data': {
              'currentUser': {
                'id': 'gid://gitlab/User/$userId',
                'todos': {
                  'nodes': nodes,
                  'pageInfo': {'hasNextPage': false, 'endCursor': null},
                },
              },
            },
          });
        }
        if (const {
          _todoSnoozeDocument,
          _todoUnsnoozeDocument,
        }.contains(digest)) {
          final match = RegExp(
            r'^gid://gitlab/Todo/([1-9][0-9]*)$',
          ).firstMatch('${vars['id']}');
          final todo = match == null ? null : _todos[int.parse(match[1]!)];
          final snooze = digest == _todoSnoozeDocument;
          final until = vars['until'];
          if (todo == null ||
              todo.actorId != userId ||
              todo.projectId != projectId ||
              (snooze &&
                  (until is! String || DateTime.tryParse(until) == null)) ||
              (!snooze && vars.length != 1)) {
            throw const Mr7Refused('todoFixtureWrite');
          }
          todo.snoozedUntil = snooze ? until as String : null;
          scenarioWrites++;
          addEvent(target: projectId);
          if (lostWriteReply) throw const Mr7Refused('replyLostAfterSend');
          final operation = snooze ? 'todoSnooze' : 'todoUnSnooze';
          return mr7Json({
            'data': {
              operation: {
                'todo': {
                  'id': 'gid://gitlab/Todo/${todo.id}',
                  'snoozedUntil': todo.snoozedUntil,
                },
                'errors': <String>[],
              },
            },
          });
        }
      }
    }
    if (routes[key] case final route?) return await route(request);
    if (key == 'GET user') {
      return mr7Json({'id': userId, 'username': namespace});
    }
    if (key == 'GET namespaces') {
      return mr7Json([
        {
          'id': namespaceId,
          'full_path': namespace,
          'kind': 'user',
          'owner_id': userId,
        },
      ]);
    }
    if (path == 'users/$userId/events' && request.method == 'GET') {
      if (unreadableEvents) return mr7Json({}, status: 429);
      final page = int.parse('${request.queryParameters['page'] ?? 1}');
      final start = (page - 1) * eventPageSize;
      return mr7Json(
        events.skip(start).take(eventPageSize).toList(),
        headers: {
          ..._pageHeaders(page, eventPageSize, events.length),
          if (incompleteEvents) 'x-next-page': [],
        },
      );
    }
    if (key == 'POST projects') {
      if (project != null) throw const Mr7Refused('existingProject');
      final body = Map<String, Object?>.from(request.data as Map);
      final name = body['path']! as String;
      project = {
        'id': projectId,
        'name': name,
        'path_with_namespace': '$namespace/$name',
        'visibility': 'private',
        'default_branch': 'main',
        'archived': false,
        'mirror': false,
        'owner': {'id': userId},
        'namespace': {
          'id': namespaceId,
          'full_path': namespace,
          'kind': 'user',
        },
        'starred': false,
      };
      setupWrites++;
      addEvent(target: projectId, action: 'created');
      return mr7Json(project, status: 201);
    }
    if (request.method == 'GET' && path == 'projects') {
      return mr7Json([
        if (project != null) project,
      ], headers: _pageHeaders(1, 100, project == null ? 0 : 1));
    }
    if (request.method == 'GET' &&
        (path == 'projects/$projectId' ||
            path == 'projects/${project?['path_with_namespace']}')) {
      return project == null
          ? mr7Json({}, status: 404)
          : mr7Json(
              path == 'projects/$projectId'
                  ? project
                  : byPathOverride ?? project,
            );
    }
    if (key == 'POST projects/$projectId/star' ||
        key == 'POST projects/$projectId/unstar') {
      project!['starred'] = path.endsWith('/star');
      scenarioWrites++;
      addEvent(target: projectId);
      if (lostWriteReply) throw const Mr7Refused('replyLostAfterSend');
      return mr7Json(wrongWriteReply ? {'id': 999} : project, status: 201);
    }
    if (key == 'DELETE projects/$projectId') {
      cleanupWrites++;
      addEvent(target: projectId, action: 'removed');
      if (delayedDeletion) {
        project!['marked_for_deletion_on'] = clock.toIso8601String();
      } else {
        project = null;
      }
      return mr7Json({}, status: 202);
    }
    throw const Mr7Refused('unexpectedSyntheticRequest');
  }
}

void _checkUri(RequestOptions options, Uri instance) {
  final uri = options.uri;
  if (uri.scheme != instance.scheme ||
      uri.host != instance.host ||
      uri.port != instance.port ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.path == '${instance.path}/api/graphql' && uri.hasQuery) ||
      (!uri.path.startsWith('${instance.path}/api/v4/') &&
          uri.path != '${instance.path}/api/graphql') ||
      options.followRedirects) {
    throw const Mr7Refused('instanceOrRedirect');
  }
}

final class _GraphVariable {
  const _GraphVariable(this.name);
  final String name;
}

final class _GraphOperation {
  _GraphOperation(this.kind, this.name);
  final String kind;
  final String? name;
  final Set<String> variables = {};
  final Set<String> fields = {};
  final List<Map<String, Object?>> arguments = [];
  final Map<String, ({String field, Map<String, Object?> arguments})>
  selections = {};
  final List<
    ({String field, Map<String, Object?> arguments, bool identityProjection})
  >
  roots = [];

  Object? resolve(Object? value, Map<Object?, Object?> variables) {
    if (value is _GraphVariable) {
      if (!this.variables.contains(value.name) ||
          !variables.containsKey(value.name)) {
        throw const Mr7Refused('graphVariable');
      }
      return variables[value.name];
    }
    if (value is Map<String, Object?>) {
      return value.map((key, item) => MapEntry(key, resolve(item, variables)));
    }
    if (value is List) {
      return value.map((item) => resolve(item, variables)).toList();
    }
    return value;
  }
}

/// A deliberately closed executable-document subset, not a schema validator.
/// Named fragments, directives, defaults and block strings are refused rather
/// than skipped: hidden argument usage must not bypass sandbox scope checks.
final class _GraphParser {
  _GraphParser(String source) {
    if (source.length > 65536) throw const Mr7Refused('graphDocument');
    final token = RegExp(
      r'\.\.\.|[A-Za-z_][A-Za-z_0-9]*|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|"(?:\\.|[^"\\\r\n])*"|[!$():{}\[\]]',
    );
    final ignored = RegExp(r'[\s,\uFEFF]+|#[^\r\n]*');
    var offset = 0;
    while (offset < source.length) {
      final skip = ignored.matchAsPrefix(source, offset);
      if (skip != null) {
        offset = skip.end;
        continue;
      }
      final match = token.matchAsPrefix(source, offset);
      if (match == null) throw const Mr7Refused('graphDocument');
      _tokens.add(match[0]!);
      offset = match.end;
    }
  }

  final List<String> _tokens = [];
  int _index = 0;
  String? get _peek => _index < _tokens.length ? _tokens[_index] : null;
  bool _take(String token) {
    if (_peek != token) return false;
    _index++;
    return true;
  }

  void _expect(String token) {
    if (!_take(token)) throw const Mr7Refused('graphDocument');
  }

  String _name() {
    final value = _peek;
    if (value == null || !RegExp(r'^[A-Za-z_][A-Za-z_0-9]*$').hasMatch(value)) {
      throw const Mr7Refused('graphDocument');
    }
    _index++;
    return value;
  }

  void _type(int depth) {
    if (depth > 32) throw const Mr7Refused('graphDocument');
    if (_take('[')) {
      _type(depth + 1);
      _expect(']');
    } else {
      _name();
    }
    _take('!');
  }

  Object? _value(int depth) {
    if (depth > 32) throw const Mr7Refused('graphDocument');
    if (_take(r'$')) return _GraphVariable(_name());
    if (_take('{')) return _pairs('}', depth + 1);
    if (_take('[')) {
      final values = <Object?>[];
      while (!_take(']')) {
        values.add(_value(depth + 1));
      }
      return values;
    }
    final value = _peek;
    if (value == null) throw const Mr7Refused('graphDocument');
    if (value.startsWith('"') || RegExp(r'^-?[0-9]').hasMatch(value)) {
      _index++;
      return jsonDecode(value);
    }
    final name = _name();
    return switch (name) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => name,
    };
  }

  Map<String, Object?> _pairs(String end, int depth) {
    final values = <String, Object?>{};
    while (!_take(end)) {
      final name = _name();
      if (values.containsKey(name)) throw const Mr7Refused('graphDocument');
      _expect(':');
      values[name] = _value(depth);
    }
    return values;
  }

  bool _selection(_GraphOperation operation, int depth, [String path = '']) {
    if (depth > 32) throw const Mr7Refused('graphDocument');
    _expect('{');
    var count = 0;
    var identityOnly = true;
    while (!_take('}')) {
      if (_take('...')) {
        _expect('on');
        _name(); // Inline type condition; all enclosed fields remain checked.
        identityOnly = _selection(operation, depth + 1, path) && identityOnly;
        count++;
        continue;
      }
      var field = _name();
      final responseKey = field;
      if (_take(':')) field = _name();
      operation.fields.add(field);
      var arguments = <String, Object?>{};
      if (_take('(')) {
        arguments = _pairs(')', 0);
        if (arguments.isEmpty) throw const Mr7Refused('graphDocument');
        operation.arguments.add(arguments);
      }
      final selectionPath = path.isEmpty ? responseKey : '$path/$responseKey';
      final previous = operation.selections[selectionPath];
      if (previous != null &&
          (previous.field != field ||
              previous.arguments.isNotEmpty ||
              arguments.isNotEmpty)) {
        throw const Mr7Refused('graphDocument');
      }
      operation.selections[selectionPath] = (
        field: field,
        arguments: arguments,
      );
      final childProjection = _peek == '{'
          ? _selection(operation, depth + 1, selectionPath)
          : null;
      if (path.isEmpty) {
        operation.roots.add((
          field: field,
          arguments: arguments,
          identityProjection: childProjection == true,
        ));
      }
      identityOnly =
          identityOnly &&
          const {'id', 'username'}.contains(field) &&
          arguments.isEmpty &&
          childProjection == null;
      count++;
    }
    if (count == 0) throw const Mr7Refused('graphDocument');
    return identityOnly;
  }

  _GraphOperation select(Object? operationName) {
    final operations = <_GraphOperation>[];
    final names = <String>{};
    while (_peek != null) {
      final kind = _peek == '{' ? 'query' : _name();
      if (!const {'query', 'mutation', 'subscription'}.contains(kind)) {
        throw const Mr7Refused('graphDocument');
      }
      final name = _peek != '(' && _peek != '{' ? _name() : null;
      if (name != null && !names.add(name)) {
        throw const Mr7Refused('graphDocument');
      }
      final operation = _GraphOperation(kind, name);
      if (_take('(')) {
        do {
          _expect(r'$');
          if (!operation.variables.add(_name())) {
            throw const Mr7Refused('graphDocument');
          }
          _expect(':');
          _type(0);
        } while (_peek != ')');
        _expect(')');
      }
      _selection(operation, 0);
      operations.add(operation);
    }
    if (operations.isEmpty ||
        (operations.length > 1 && operations.any((op) => op.name == null)) ||
        (operationName != null && operationName is! String)) {
      throw const Mr7Refused('graphOperation');
    }
    return operationName == null
        ? operations.single
        : operations.singleWhere((op) => op.name == operationName);
  }
}

_GraphOperation? _selectedGraphOperation(Object? body) {
  if (body is! Map ||
      body['query'] is! String ||
      body.keys.any(
        (key) => !const {'query', 'variables', 'operationName'}.contains(key),
      )) {
    return null;
  }
  try {
    return _GraphParser(body['query'] as String).select(body['operationName']);
  } catch (_) {
    return null;
  }
}

bool _graphSnapshotTargets(
  Object? body,
  Map<String, String> bindings,
  String path,
) {
  final operation = _selectedGraphOperation(body);
  if (operation?.kind != 'mutation' ||
      body is! Map ||
      body['variables'] is! Map) {
    return false;
  }
  final gids = bindings.entries
      .where(
        (entry) =>
            entry.value == path &&
            RegExp(r'^gid://gitlab/[A-Za-z]+/[1-9][0-9]*$').hasMatch(entry.key),
      )
      .map((entry) => entry.key)
      .toSet();
  if (gids.isEmpty) return false;
  bool contains(Object? value) {
    if (value is String) return gids.contains(value);
    if (value is List) return value.any(contains);
    if (value is Map) return value.values.any(contains);
    return false;
  }

  try {
    return operation!.roots.any(
      (root) =>
          contains(operation.resolve(root.arguments, body['variables'] as Map)),
    );
  } catch (_) {
    return false;
  }
}

bool _sealedGraphRead(
  RequestOptions request,
  Map<String, Set<String>> documents,
) {
  final body = request.data;
  return request.method == 'POST' &&
      request.uri.path.endsWith('/api/graphql') &&
      body is Map &&
      body['query'] is String &&
      _selectedGraphOperation(body)?.kind == 'query' &&
      (documents[body['query']]?.contains(mr7Digest(body['variables'])) ??
          false);
}

Object? _selectRecord(Object? value, List<String> path) {
  for (final key in path) {
    if (value is! Map) return null;
    value = value[key];
  }
  return value;
}

final class Mr7ObserverAdapter implements HttpClientAdapter {
  Mr7ObserverAdapter(this.server, this.instance);
  final Mr7SyntheticGitLab server;
  final Uri instance;
  final List<String> requests = [];
  void Function()? beforeRequest;
  void Function(RequestOptions)? validateRequest;
  Map<String, Set<String>> graphReadDocuments = const {};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _checkUri(options, instance);
    if (options.method != 'GET' &&
        !_sealedGraphRead(options, graphReadDocuments)) {
      throw const Mr7Refused('observerReadOnly');
    }
    validateRequest?.call(options);
    beforeRequest?.call();
    requests.add(options.uri.path);
    final response = await server.respond(options);
    validateRequest?.call(options);
    return response;
  }

  @override
  void close({bool force = false}) {}
}

/// Closed final wire paths, additional to all production coordinator gates.
final class Mr7MutationPermit {
  Mr7MutationPermit({
    required this.operation,
    required this.paths,
    required this.resourceProjectId,
    this.maxMutations = 1,
    this.graphDocuments = const {},
    this.graphVariablesDigests = const {},
    this.resultPath = const [],
  });
  final String operation;
  final Set<String> paths;
  final int resourceProjectId;
  final int maxMutations;
  final Set<String> graphDocuments;
  final Set<String> graphVariablesDigests;
  final List<String> resultPath;
  int sent = 0;
  bool confirmed = false;
  Future<bool> Function()? confirmBeforeSend;
  int? returnedId;
  int? returnedIid;
  int? returnedProjectId;
  String? returnedGlobalId;
  Mr7MutationResult? result;
  Mr7PreReadSnapshot? snapshot;
  Map<String, Object?>? upload;
  String? _sentPath;
  Object? _sentBody;
  Map<String, String> _graphResourcesAtSend = const {};
  String? _rebaseBeforeSha;
}

/// Fields are represented by digests in receipts; field presence is bound too.
final class Mr7SnapshotSpec {
  Mr7SnapshotSpec({
    required this.path,
    required Set<String> fields,
    Set<String> unchangedFields = const {},
  }) : fields = Set.unmodifiable(fields),
       unchangedFields = Set.unmodifiable(unchangedFields);
  final String path;
  final Set<String> fields;
  final Set<String> unchangedFields;
}

final class _Mr7SnapshotRow {
  _Mr7SnapshotRow({
    required this.spec,
    required this.id,
    required this.iid,
    required this.digests,
  });
  final Mr7SnapshotSpec spec;
  final int id;
  final int? iid;
  final Map<String, String> digests;
}

final class Mr7PreReadSnapshot {
  Mr7PreReadSnapshot._(this.actorId, this.projectId, this._rows);
  final int actorId;
  final int projectId;
  final List<_Mr7SnapshotRow> _rows;
  Map<String, Object?> get metadata => {
    'actorId': actorId,
    'projectId': projectId,
    'resources': [
      for (final row in _rows)
        {
          'path': row.spec.path,
          'id': row.id,
          if (row.iid != null) 'iid': row.iid,
          'fieldDigests': row.digests,
          'unchangedFields': row.spec.unchangedFields.toList()..sort(),
        },
    ],
  };
}

String _snapshotFieldDigest(Map<String, Object?> row, String field) =>
    mr7Digest({'present': row.containsKey(field), 'value': row[field]});

/// Identifiers select subsequent reads; they are never evidence of effects.
final class Mr7MutationResult {
  const Mr7MutationResult({
    required this.status,
    this.id,
    this.iid,
    this.projectId,
    this.stringId,
  });
  final int status;
  final int? id;
  final int? iid;
  final int? projectId;
  final String? stringId;
}

enum Mr7ParentKind { project, issue, mergeRequest, issueNote, mergeRequestNote }

/// A global resource ID is distinct from its route iid.
final class Mr7Parent {
  const Mr7Parent.project()
    : kind = Mr7ParentKind.project,
      id = null,
      iid = null,
      noteId = null;
  const Mr7Parent.issue({required this.id, required this.iid})
    : kind = Mr7ParentKind.issue,
      noteId = null;
  const Mr7Parent.mergeRequest({required this.id, required this.iid})
    : kind = Mr7ParentKind.mergeRequest,
      noteId = null;
  const Mr7Parent.issueNote({
    required this.id,
    required this.iid,
    required this.noteId,
  }) : kind = Mr7ParentKind.issueNote;
  const Mr7Parent.mergeRequestNote({
    required this.id,
    required this.iid,
    required this.noteId,
  }) : kind = Mr7ParentKind.mergeRequestNote;
  final Mr7ParentKind kind;
  final int? id;
  final int? iid;
  final int? noteId;
}

/// Closed read-only vocabulary: no executable callback or arbitrary endpoint.
sealed class Mr7Observation<T> {
  const Mr7Observation();
  Future<T> _read(Mr7Readback observer);
}

final class Mr7DiscussionObservation
    extends Mr7Observation<Map<String, Object?>> {
  Mr7DiscussionObservation({
    required this.parent,
    required this.discussionId,
    required Set<int> noteIds,
    required this.resolved,
  }) : noteIds = Set.unmodifiable(noteIds);
  final Mr7Parent parent;
  final String discussionId;
  final Set<int> noteIds;
  final bool resolved;
  @override
  Future<Map<String, Object?>> _read(Mr7Readback observer) =>
      observer._discussion(this);
}

final class Mr7MilestoneObservation
    extends Mr7Observation<Map<String, Object?>> {
  const Mr7MilestoneObservation({required this.id, required this.iid});
  final int id;
  final int iid;
  @override
  Future<Map<String, Object?>> _read(Mr7Readback observer) =>
      observer._milestone(this);
}

final class Mr7ApprovalObservation extends Mr7Observation<bool> {
  const Mr7ApprovalObservation({required this.parent, required this.approved});
  final Mr7Parent parent;
  final bool approved;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._approval(this);
}

enum Mr7ListKind {
  awards,
  notes,
  discussions,
  issues,
  mergeRequests,
  labels,
  milestones,
  boards,
  draftNotes,
  pipelines,
  snippets,
  branches,
  tags,
  releases,
}

final class Mr7ListObservation
    extends Mr7Observation<List<Map<String, Object?>>> {
  Mr7ListObservation({
    required this.parent,
    required this.kind,
    required Set<Object> expectedIds,
  }) : expectedIds = Set.unmodifiable(expectedIds);
  final Mr7Parent parent;
  final Mr7ListKind kind;

  /// Exact complete set, including the empty set; never a single 404.
  final Set<Object> expectedIds;
  @override
  Future<List<Map<String, Object?>>> _read(Mr7Readback observer) =>
      observer._list(this);
}

final class Mr7FileObservation extends Mr7Observation<Map<String, Object?>> {
  const Mr7FileObservation({
    required this.path,
    required this.sha,
    required this.content,
  });
  final String path;
  final String sha;
  final String content;
  @override
  Future<Map<String, Object?>> _read(Mr7Readback observer) =>
      observer._file(this);
}

enum Mr7RefKind { branch, tag }

final class Mr7RefObservation extends Mr7Observation<Map<String, Object?>> {
  const Mr7RefObservation({
    required this.kind,
    required this.name,
    required this.sha,
  });
  final Mr7RefKind kind;
  final String name;
  final String sha;
  @override
  Future<Map<String, Object?>> _read(Mr7Readback observer) =>
      observer._ref(this);
}

final class Mr7ReleaseObservation extends Mr7Observation<Map<String, Object?>> {
  const Mr7ReleaseObservation({
    required this.tag,
    required this.name,
    required this.sha,
  });
  final String tag;
  final String name;
  final String sha;
  @override
  Future<Map<String, Object?>> _read(Mr7Readback observer) =>
      observer._release(this);
}

final class Mr7SnippetFile {
  Mr7SnippetFile({required this.ref, required List<int> bytes})
    : bytes = List.unmodifiable(bytes);
  final String ref;
  final List<int> bytes;
}

final class Mr7SnippetObservation
    extends Mr7Observation<Map<String, List<int>>> {
  Mr7SnippetObservation({
    required this.id,
    required this.revision,
    required Map<String, Mr7SnippetFile> files,
  }) : files = Map.unmodifiable(files);
  final int id;
  final String revision;
  final Map<String, Mr7SnippetFile> files;
  @override
  Future<Map<String, List<int>>> _read(Mr7Readback observer) =>
      observer._snippet(this);
}

enum Mr7ParentState { starred, subscribed, autoMerge }

final class Mr7ParentStateObservation extends Mr7Observation<bool> {
  const Mr7ParentStateObservation({
    required this.parent,
    required this.state,
    required this.expected,
  });
  final Mr7Parent parent;
  final Mr7ParentState state;
  final bool expected;
  bool matchesCall(String operation, Object? arguments, int projectId) {
    if (arguments is! Map || arguments['projectId'] != projectId) return false;
    return switch (state) {
      Mr7ParentState.starred =>
        operation == 'setStar' &&
            parent.kind == Mr7ParentKind.project &&
            arguments['starred'] == expected,
      Mr7ParentState.subscribed =>
        operation == 'setSubscribed' &&
            arguments['subscribed'] == expected &&
            arguments['iid'] == parent.iid &&
            ((arguments['resource'] == 'issues' &&
                    parent.kind == Mr7ParentKind.issue) ||
                (arguments['resource'] == 'merge_requests' &&
                    parent.kind == Mr7ParentKind.mergeRequest)),
      Mr7ParentState.autoMerge =>
        operation == 'cancelAutoMerge' &&
            !expected &&
            parent.kind == Mr7ParentKind.mergeRequest &&
            arguments['iid'] == parent.iid,
    };
  }

  @override
  Future<bool> _read(Mr7Readback observer) => observer._parentState(this);
}

final class Mr7RebaseObservation extends Mr7Observation<Map<String, Object?>> {
  const Mr7RebaseObservation({
    required this.parent,
    required this.sha,
    this.maxAttempts = 3,
    this.interval = const Duration(milliseconds: 10),
    this.timeout = const Duration(seconds: 1),
  });
  final Mr7Parent parent;
  final String sha;
  final int maxAttempts;
  final Duration interval;
  final Duration timeout;
  @override
  Future<Map<String, Object?>> _read(Mr7Readback observer) =>
      observer._rebase(this);
}

/// Synthetic server-side upload metadata, fetched independently after send.
final class Mr7UploadObservation extends Mr7Observation<bool> {
  const Mr7UploadObservation({required this.byteCount, required this.sha256});
  final int byteCount;
  final String sha256;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._upload(this);
}

/// Read synthetic fixture state after a project-owned Todo snooze operation.
final class Mr7TodoObservation extends Mr7Observation<bool> {
  const Mr7TodoObservation({required this.id, required this.snoozedUntil});
  final int id;
  final String? snoozedUntil;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._todo(this);
}

Future<Map<String, Object?>> _uploadMetadata(
  RequestOptions options,
  Stream<Uint8List>? stream,
) async {
  final data = options.data;
  if (data is! FormData ||
      stream == null ||
      data.fields.isNotEmpty ||
      data.files.length != 1 ||
      data.files.single.key != 'file' ||
      data.files.single.value.length > 25 * 1024 * 1024 ||
      data.length > 25 * 1024 * 1024 + 8192) {
    throw const Mr7Refused('uploadShape');
  }
  final collected = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in stream) {
    length += chunk.length;
    if (length > data.length || length > 25 * 1024 * 1024 + 8192) {
      throw const Mr7Refused('uploadSize');
    }
    collected.add(chunk);
  }
  final bytes = collected.takeBytes();
  final start = utf8.encode('--${data.boundary}\r\n');
  final end = utf8.encode('\r\n--${data.boundary}--\r\n');
  final fileLength = data.files.single.value.length;
  final payloadEnd = bytes.length - end.length;
  final payloadStart = payloadEnd - fileLength;
  bool matches(int offset, List<int> expected) =>
      offset >= 0 &&
      offset + expected.length <= bytes.length &&
      Iterable<int>.generate(
        expected.length,
      ).every((i) => bytes[offset + i] == expected[i]);
  if (length != data.length ||
      payloadStart < start.length + 4 ||
      payloadStart > 8192 ||
      !matches(0, start) ||
      !matches(payloadEnd, end) ||
      !matches(payloadStart - 4, const [13, 10, 13, 10])) {
    throw const Mr7Refused('uploadShape');
  }
  return Map.unmodifiable({
    'byteCount': fileLength,
    'sha256': sha256
        .convert(Uint8List.sublistView(bytes, payloadStart, payloadEnd))
        .toString(),
  });
}

/// Query seals are installed after the response. Parent and child IDs remain
/// independent: for example AwardEmoji -> Note -> WorkItem.
final class Mr7GraphObservation extends Mr7Observation<Map<String, Object?>> {
  Mr7GraphObservation({
    required this.document,
    required Map<String, Object?> variables,
    required List<String> recordPath,
    required this.parentId,
    List<String>? connectionPath,
    Set<String>? expectedIds,
    this.noteId,
    Set<String> absentIds = const {},
    this.cursorVariable = 'after',
  }) : variables = Map.unmodifiable(variables),
       recordPath = List.unmodifiable(recordPath),
       connectionPath = connectionPath == null
           ? null
           : List.unmodifiable(connectionPath),
       expectedIds = expectedIds == null ? null : Set.unmodifiable(expectedIds),
       absentIds = Set.unmodifiable(absentIds);
  final String document;
  final Map<String, Object?> variables;
  final List<String> recordPath;
  final String parentId;
  final List<String>? connectionPath;
  final Set<String>? expectedIds;
  final String? noteId;
  final Set<String> absentIds;
  final String cursorVariable;
  @override
  Future<Map<String, Object?>> _read(Mr7Readback observer) =>
      observer._graph(this);
}

final class Mr7GuardedAdapter implements HttpClientAdapter {
  Mr7GuardedAdapter(this.session);
  final Mr7SandboxSession session;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _checkUri(options, session.instance);
    if (options.method == 'GET' ||
        _sealedGraphRead(options, session.observerAdapter.graphReadDocuments)) {
      session.validateRead(options, allowStopped: false);
      session.chargeRequest();
      final response = await session.server.respond(options);
      session.validateRead(options, allowStopped: false);
      return response;
    }
    if (session.pendingMutations > 0 ||
        (session._finalizing && !session._cleanupAuthorized)) {
      session.stop('writeUncertain');
      throw const Mr7Refused('concurrentMutation');
    }
    session.pendingMutations++;
    bool dispatched = false;
    try {
      await session.beforeMutation(options);
      session.inFlight = true;
      final upload = session.permit?.operation == 'upload_attachment'
          ? await _uploadMetadata(options, requestStream)
          : null;
      if (!session._setupAuthorized && !session._cleanupAuthorized) {
        final permit = session.permit!;
        permit.sent++;
        permit._sentPath =
            options.uri.path == '${session.instance.path}/api/graphql'
            ? 'graphql'
            : session._restSegments(options).map(Uri.encodeComponent).join('/');
        permit._graphResourcesAtSend = Map.unmodifiable(
          session._graphResources,
        );
        permit._sentBody = options.data is Map
            ? jsonDecode(jsonEncode(options.data))
            : null;
      }
      dispatched = true;
      final response = await session.server.respond(options);
      if (upload != null &&
          response.statusCode >= 200 &&
          response.statusCode < 300) {
        session.server._lastUpload = upload;
        session.permit?.upload = upload;
      }
      final parentStateCandidate =
          response.statusCode == 304 &&
          const {
            'setStar',
            'setSubscribed',
          }.contains(session.permit?.operation) &&
          session.permit?.sent == 1;
      if (response.statusCode >= 500 ||
          (response.statusCode >= 300 &&
              response.statusCode < 400 &&
              !parentStateCandidate)) {
        session.stop('writeUncertain');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
      }
      if (!session.boundaryValid() || session.quarantined) {
        session.stop('writeUncertain');
      }
      Object? value;
      try {
        value = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        /* No response oracle. */
      }
      final permit = session.permit;
      value = _selectRecord(value, permit?.resultPath ?? const []);
      if (permit != null && value is Map) {
        permit.returnedId = value['id'] is int ? value['id'] as int : null;
        permit.returnedIid = value['iid'] is int ? value['iid'] as int : null;
        permit.returnedProjectId = value['project_id'] is int
            ? value['project_id'] as int
            : null;
        permit.returnedGlobalId = value['id'] is String
            ? value['id'] as String
            : null;
      }
      if (permit != null) {
        permit.result = Mr7MutationResult(
          status: response.statusCode,
          id: permit.returnedId,
          iid: permit.returnedIid,
          projectId: permit.returnedProjectId,
          stringId: permit.returnedGlobalId,
        );
      }
      if (permit?.operation == 'deleteProject' && response.statusCode == 202) {
        session.terminalDeletionAccepted = true;
      }
      return ResponseBody.fromBytes(
        bytes,
        response.statusCode,
        headers: response.headers,
      );
    } catch (_) {
      if (dispatched) session.stop('writeUncertain');
      rethrow;
    } finally {
      session.inFlight = false;
      session.pendingMutations--;
    }
  }

  @override
  void close({bool force = false}) {}
}

/// Target-bound independent reads exposed to scenario definitions. No access
/// to the writer, mutation response body, or simulated server state is exposed.
final class Mr7Readback {
  Mr7Readback(
    this._session,
    this._identity,
    this._permit, {
    this.paths = const {},
    this.graphQueries = const {},
  });
  final Mr7SandboxSession _session;
  final Mr7Identity _identity;
  final Mr7MutationPermit _permit;
  final Set<String> paths;
  final Map<String, Set<String>> graphQueries;
  int verifiedRequests = 0;

  Mr7MutationResult get result =>
      _permit.result ?? (throw const Mr7Refused('observerBeforeResponse'));
  Mr7PreReadSnapshot? get snapshot => _permit.snapshot;
  String get _root => 'projects/${_identity.projectId}';

  void _scope() {
    if (!_session._identityMatches(_identity) ||
        _session.inFlight ||
        _session.pendingMutations != 0 ||
        !_session.boundaryValid() ||
        (result.projectId != null && result.projectId != _identity.projectId)) {
      throw const Mr7Refused('readbackTarget');
    }
  }

  Future<void> _actorAndProject() async {
    _scope();
    final actor = await _session.read('user');
    if (actor['id'] != _identity.userId ||
        actor['username'] != _identity.namespace) {
      throw const Mr7Refused('observerIdentity');
    }
    await _session.verifyIdentity(observationOnly: true);
    _scope();
  }

  Future<bool> _upload(Mr7UploadObservation spec) async {
    if (_permit.operation != 'upload_attachment' ||
        spec.byteCount < 0 ||
        spec.byteCount > 25 * 1024 * 1024 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(spec.sha256)) {
      throw const Mr7Refused('observerUpload');
    }
    _sentTo('$_root/uploads');
    final row = await _map('$_root/uploads/mr7-observation');
    return row.length == 2 &&
        row['byteCount'] == spec.byteCount &&
        row['sha256'] == spec.sha256;
  }

  Future<bool> _todo(Mr7TodoObservation spec) async {
    if (spec.id <= 0 ||
        !const {'snoozeTodo', 'unsnoozeTodo'}.contains(_permit.operation)) {
      throw const Mr7Refused('observerTodo');
    }
    _sentTo('graphql');
    final body = _permit._sentBody;
    final vars = body is Map ? body['variables'] : null;
    final gid = 'gid://gitlab/Todo/${spec.id}';
    final parentPath = _permit._graphResourcesAtSend[gid];
    if (vars is! Map ||
        vars['id'] != gid ||
        parentPath == null ||
        (_permit.operation == 'snoozeTodo'
            ? vars['until'] != spec.snoozedUntil || spec.snoozedUntil == null
            : spec.snoozedUntil != null)) {
      throw const Mr7Refused('observerTodo');
    }
    final todo = await _map('$_root/todos/${spec.id}/mr7-observation');
    final parent = await _map(parentPath);
    if (todo['id'] != spec.id ||
        todo['actor_id'] != _identity.userId ||
        todo['project_id'] != _identity.projectId ||
        todo['parent_path'] != parentPath ||
        parent['id'] != todo['parent_id'] ||
        parent['iid'] != todo['parent_iid'] ||
        parent['project_id'] != _identity.projectId) {
      throw const Mr7Refused('observerTodo');
    }
    return todo.containsKey('snoozed_until') &&
        todo['snoozed_until'] == spec.snoozedUntil;
  }

  void _sentTo(String path) {
    if (_permit.sent != 1 || _permit._sentPath != path) {
      throw const Mr7Refused('observerMutationTarget');
    }
  }

  Future<T> observe<T>(Mr7Observation<T> observation) async {
    await _actorAndProject();
    final before = _session.observerAdapter.requests.length;
    final value = await observation._read(this);
    await _actorAndProject();
    _scope();
    verifiedRequests += _session.observerAdapter.requests.length - before;
    return value;
  }

  /// Re-read the original resource and preserved fields through the observer.
  Future<bool> verifySnapshot() async {
    final saved = snapshot;
    if (saved == null ||
        saved.actorId != _identity.userId ||
        saved.projectId != _identity.projectId ||
        _permit.sent != 1 ||
        _permit._sentPath == null) {
      throw const Mr7Refused('snapshotMissing');
    }
    await _actorAndProject();
    final before = _session.observerAdapter.requests.length;
    for (final original in saved._rows) {
      final path = original.spec.path;
      final sentPath = _permit._sentPath!;
      if (path != _root &&
          sentPath != path &&
          !sentPath.startsWith('$path/') &&
          !(sentPath == 'graphql' &&
              _graphSnapshotTargets(
                _permit._sentBody,
                _permit._graphResourcesAtSend,
                path,
              ))) {
        throw const Mr7Refused('snapshotTarget');
      }
      final current = await _map(path);
      if (current['id'] != original.id ||
          (original.iid != null && current['iid'] != original.iid) ||
          (path != _root && current['project_id'] != _identity.projectId) ||
          original.spec.unchangedFields.any(
            (field) =>
                _snapshotFieldDigest(current, field) != original.digests[field],
          )) {
        return false;
      }
    }
    await _actorAndProject();
    verifiedRequests += _session.observerAdapter.requests.length - before;
    return true;
  }

  String _name(String name) {
    if (name.isEmpty ||
        name.length > 1024 ||
        name.startsWith('/') ||
        name.contains('\\') ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        name.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const Mr7Refused('observerName');
    }
    return Uri.encodeComponent(name);
  }

  void _sha(String value) {
    if (!RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(value)) {
      throw const Mr7Refused('observerSha');
    }
  }

  void _path(String path) {
    _scope();
    if (!paths.contains(path) ||
        (path != _root && !path.startsWith('$_root/'))) {
      throw const Mr7Refused('readbackTarget');
    }
  }

  Future<Map<String, Object?>> _map(
    String path, {
    Map<String, Object?> query = const {},
  }) async {
    _path(path);
    final response = await _session.observer.get<Object?>(
      path,
      queryParameters: query,
    );
    if (response.statusCode != 200 ||
        response.data is! Map ||
        jsonEncode(response.data).length > 2 * 1024 * 1024) {
      throw const Mr7Refused('observerUnreadable');
    }
    final row = Map<String, Object?>.from(response.data! as Map);
    if (row.containsKey('project_id') &&
        row['project_id'] != _identity.projectId) {
      throw const Mr7Refused('readbackIdentity');
    }
    _scope();
    return row;
  }

  Future<({String path, Map<String, Object?> row})> _parent(
    Mr7Parent parent, {
    Map<String, Object?> query = const {},
  }) async {
    if (parent.kind == Mr7ParentKind.project) {
      final row = await _map(_root);
      if (row['id'] != _identity.projectId) {
        throw const Mr7Refused('observerParent');
      }
      return (path: _root, row: row);
    }
    if (parent.id == null ||
        parent.id! <= 0 ||
        parent.iid == null ||
        parent.iid! <= 0) {
      throw const Mr7Refused('observerParent');
    }
    final issue = const {
      Mr7ParentKind.issue,
      Mr7ParentKind.issueNote,
    }.contains(parent.kind);
    var path = '$_root/${issue ? 'issues' : 'merge_requests'}/${parent.iid}';
    var row = await _map(path, query: query);
    if (row['id'] != parent.id ||
        row['iid'] != parent.iid ||
        row['project_id'] != _identity.projectId) {
      throw const Mr7Refused('observerParent');
    }
    if (const {
      Mr7ParentKind.issueNote,
      Mr7ParentKind.mergeRequestNote,
    }.contains(parent.kind)) {
      if (parent.noteId == null || parent.noteId! <= 0) {
        throw const Mr7Refused('observerParent');
      }
      path = '$path/notes/${parent.noteId}';
      row = await _map(path);
      if (row['id'] != parent.noteId || row['noteable_id'] != parent.id) {
        throw const Mr7Refused('observerParent');
      }
    }
    return (path: path, row: row);
  }

  Future<Map<String, Object?>> _discussion(
    Mr7DiscussionObservation spec,
  ) async {
    if (!const {
      Mr7ParentKind.issue,
      Mr7ParentKind.mergeRequest,
    }.contains(spec.parent.kind)) {
      throw const Mr7Refused('observerParent');
    }
    final parent = await _parent(spec.parent);
    if (_permit.operation == 'createDiscussion' &&
        (result.stringId == null || result.stringId != spec.discussionId)) {
      throw const Mr7Refused('readbackReturnedId');
    }
    final discussionPath =
        '${parent.path}/discussions/${_name(spec.discussionId)}';
    switch (_permit.operation) {
      case 'createDiscussion':
        _sentTo('${parent.path}/discussions');
      case 'createDiscussionNote':
        _sentTo('$discussionPath/notes');
      case 'updateDiscussionNote':
        _sentTo('$discussionPath/notes/${result.id}');
      case 'setDiscussionResolved':
        _sentTo(discussionPath);
      default:
        throw const Mr7Refused('observerMutationTarget');
    }
    final row = await _map(
      '${parent.path}/discussions/${_name(spec.discussionId)}',
    );
    final notes = row['notes'];
    final ids = <int>{};
    if (row['id'] != spec.discussionId ||
        notes is! List ||
        notes.isEmpty ||
        notes.length > 2000) {
      throw const Mr7Refused('observerDiscussion');
    }
    for (final note in notes) {
      if (note is! Map ||
          note['id'] is! int ||
          (note['id'] as int) <= 0 ||
          !ids.add(note['id'] as int) ||
          note['noteable_id'] != spec.parent.id ||
          note['resolved'] != spec.resolved ||
          (note.containsKey('project_id') &&
              note['project_id'] != _identity.projectId)) {
        throw const Mr7Refused('observerDiscussion');
      }
    }
    if (ids.length != spec.noteIds.length ||
        !ids.containsAll(spec.noteIds) ||
        (const {
              'createDiscussionNote',
              'updateDiscussionNote',
            }.contains(_permit.operation) &&
            (result.id == null || !ids.contains(result.id)))) {
      throw const Mr7Refused('observerMembership');
    }
    return row;
  }

  Future<Map<String, Object?>> _milestone(Mr7MilestoneObservation spec) async {
    if (spec.id <= 0 ||
        spec.iid <= 0 ||
        result.id != spec.id ||
        result.iid != spec.iid) {
      throw const Mr7Refused('readbackReturnedId');
    }
    _sentTo(
      _permit.operation == 'createMilestone'
          ? '$_root/milestones'
          : '$_root/milestones/${spec.id}',
    );
    final row = await _map('$_root/milestones/${spec.id}');
    if (row['id'] != spec.id ||
        row['iid'] != spec.iid ||
        row['project_id'] != _identity.projectId) {
      throw const Mr7Refused('readbackIdentity');
    }
    return row;
  }

  Future<bool> _approval(Mr7ApprovalObservation spec) async {
    final expected = switch (_permit.operation) {
      'approveMergeRequest' => true,
      'unapproveMergeRequest' => false,
      _ => throw const Mr7Refused('observerApprovalOperation'),
    };
    if (spec.approved != expected) {
      throw const Mr7Refused('observerState');
    }
    if (spec.parent.kind != Mr7ParentKind.mergeRequest) {
      throw const Mr7Refused('observerParent');
    }
    final parent = await _parent(spec.parent);
    _sentTo('${parent.path}/${expected ? 'approve' : 'unapprove'}');
    final row = await _map('${parent.path}/approvals');
    final approved = row['approved_by'];
    if (row['id'] != spec.parent.id ||
        row['iid'] != spec.parent.iid ||
        approved is! List ||
        approved.length > 2000) {
      throw const Mr7Refused('observerApprovals');
    }
    final ids = <int>{};
    for (final entry in approved) {
      final user = entry is Map ? entry['user'] : null;
      if (user is! Map ||
          user['id'] is! int ||
          (user['id'] as int) <= 0 ||
          !ids.add(user['id'] as int)) {
        throw const Mr7Refused('observerApprovals');
      }
    }
    if (ids.contains(_identity.userId) != expected) {
      throw const Mr7Refused('observerState');
    }
    return true;
  }

  Future<List<Map<String, Object?>>> _list(Mr7ListObservation spec) async {
    final parent = await _parent(spec.parent);
    final childList = const {
      Mr7ListKind.awards,
      Mr7ListKind.notes,
      Mr7ListKind.discussions,
      Mr7ListKind.draftNotes,
    };
    if ((!childList.contains(spec.kind) &&
            spec.parent.kind != Mr7ParentKind.project) ||
        (const {
              Mr7ListKind.notes,
              Mr7ListKind.discussions,
            }.contains(spec.kind) &&
            !const {
              Mr7ParentKind.issue,
              Mr7ParentKind.mergeRequest,
            }.contains(spec.parent.kind)) ||
        (spec.kind == Mr7ListKind.draftNotes &&
            spec.parent.kind != Mr7ParentKind.mergeRequest)) {
      throw const Mr7Refused('observerParent');
    }
    final suffix = switch (spec.kind) {
      Mr7ListKind.awards => 'award_emoji',
      Mr7ListKind.notes => 'notes',
      Mr7ListKind.discussions => 'discussions',
      Mr7ListKind.issues => 'issues',
      Mr7ListKind.mergeRequests => 'merge_requests',
      Mr7ListKind.labels => 'labels',
      Mr7ListKind.milestones => 'milestones',
      Mr7ListKind.boards => 'boards',
      Mr7ListKind.draftNotes => 'draft_notes',
      Mr7ListKind.pipelines => 'pipelines',
      Mr7ListKind.snippets => 'snippets',
      Mr7ListKind.branches => 'repository/branches',
      Mr7ListKind.tags => 'repository/tags',
      Mr7ListKind.releases => 'releases',
    };
    if (spec.kind == Mr7ListKind.awards &&
        spec.parent.kind == Mr7ParentKind.project) {
      throw const Mr7Refused('observerParent');
    }
    final path = '${parent.path}/$suffix';
    _path(path);
    final removal =
        _permit.operation.startsWith('delete') ||
        _permit.operation.startsWith('remove');
    Object? removedId;
    if (removal) {
      final sent = _permit._sentPath;
      if (sent == null ||
          !sent.startsWith('$path/') ||
          sent.substring(path.length + 1).contains('/')) {
        throw const Mr7Refused('observerMutationTarget');
      }
      final target = Uri.decodeComponent(sent.substring(path.length + 1));
      removedId =
          const {
            Mr7ListKind.branches,
            Mr7ListKind.tags,
            Mr7ListKind.releases,
          }.contains(spec.kind)
          ? target
          : int.tryParse(target);
      if (removedId == null) throw const Mr7Refused('observerMutationTarget');
    } else if (!(_permit._sentPath?.startsWith('${parent.path}/') ?? false)) {
      throw const Mr7Refused('observerMutationTarget');
    }
    final rows = <Map<String, Object?>>[];
    final ids = <Object>{};
    final iids = <int>{};
    final pagination = _PageSequence();
    var page = 1;
    while (true) {
      final response = await _session.observer.get<Object?>(
        path,
        queryParameters: {'page': page, 'per_page': 100},
      );
      final next = pagination.next(response, page);
      for (final raw in response.data! as List) {
        final key = switch (spec.kind) {
          Mr7ListKind.branches || Mr7ListKind.tags => 'name',
          Mr7ListKind.releases => 'tag_name',
          _ => 'id',
        };
        final id = raw is Map ? raw[key] : null;
        final stringId = const {
          Mr7ListKind.branches,
          Mr7ListKind.tags,
          Mr7ListKind.releases,
          Mr7ListKind.discussions,
        }.contains(spec.kind);
        if (raw is! Map ||
            (stringId ? id is! String || id.isEmpty : id is! int || id <= 0) ||
            !ids.add(id as Object) ||
            (raw.containsKey('project_id') &&
                raw['project_id'] != _identity.projectId) ||
            (spec.kind == Mr7ListKind.notes &&
                raw['noteable_id'] != spec.parent.id)) {
          throw const Mr7Refused('observerList');
        }
        if (const {
          Mr7ListKind.issues,
          Mr7ListKind.mergeRequests,
        }.contains(spec.kind)) {
          final iid = raw['iid'];
          if (iid is! int || iid <= 0 || !iids.add(iid)) {
            throw const Mr7Refused('observerList');
          }
        }
        if (spec.kind == Mr7ListKind.awards) {
          final user = raw['user'];
          final note = spec.parent.noteId;
          if (user is! Map ||
              user['id'] is! int ||
              (user['id'] as int) <= 0 ||
              raw['awardable_id'] != (note ?? spec.parent.id) ||
              raw['awardable_type'] !=
                  (note != null
                      ? 'Note'
                      : spec.parent.kind == Mr7ParentKind.issue
                      ? 'Issue'
                      : 'MergeRequest')) {
            throw const Mr7Refused('observerRelationship');
          }
        }
        rows.add(
          Map<String, Object?>.unmodifiable(Map<String, Object?>.from(raw)),
        );
      }
      if (next == null) break;
      page = next;
    }
    // Revalidate the same parent after all pages; a disappearing parent cannot
    // turn an inaccessible collection into proof of removal.
    await _parent(spec.parent);
    if (ids.length != spec.expectedIds.length ||
        !ids.containsAll(spec.expectedIds) ||
        (removal &&
            (const {
                  Mr7ListKind.issues,
                  Mr7ListKind.mergeRequests,
                }.contains(spec.kind)
                ? iids.contains(removedId)
                : ids.contains(removedId)))) {
      throw const Mr7Refused('observerAbsence');
    }
    return List.unmodifiable(rows);
  }

  Future<Map<String, Object?>> _file(Mr7FileObservation spec) async {
    _sha(spec.sha);
    _sentTo('$_root/repository/files/${_name(spec.path)}');
    final body = _permit._sentBody;
    if (body is! Map ||
        body['branch'] is! String ||
        body['content'] is! String ||
        (body['encoding'] == 'base64'
                ? utf8.decode(base64Decode(body['content'] as String))
                : body['content']) !=
            spec.content) {
      throw const Mr7Refused('observerContent');
    }
    final branch = body['branch'] as String;
    Future<void> verifyBranch() async {
      final row = await _map('$_root/repository/branches/${_name(branch)}');
      final commit = row['commit'];
      if (row['name'] != branch || commit is! Map || commit['id'] != spec.sha) {
        throw const Mr7Refused('observerRef');
      }
    }

    await verifyBranch();
    final row = await _map(
      '$_root/repository/files/${_name(spec.path)}',
      query: {'ref': spec.sha},
    );
    if (row['file_path'] != spec.path ||
        row['commit_id'] != spec.sha ||
        row['encoding'] != 'base64' ||
        row['content'] is! String ||
        utf8.decode(base64Decode(row['content']! as String)) != spec.content) {
      throw const Mr7Refused('observerContent');
    }
    await verifyBranch();
    return row;
  }

  Future<Map<String, Object?>> _ref(Mr7RefObservation spec) async {
    _sha(spec.sha);
    final collection =
        '$_root/repository/${spec.kind == Mr7RefKind.branch ? 'branches' : 'tags'}';
    final body = _permit._sentBody;
    _sentTo(collection);
    if (body is! Map ||
        body['ref'] != spec.sha ||
        body[spec.kind == Mr7RefKind.branch ? 'branch' : 'tag_name'] !=
            spec.name) {
      throw const Mr7Refused('observerMutationTarget');
    }
    final row = await _map(
      '$_root/repository/${spec.kind == Mr7RefKind.branch ? 'branches' : 'tags'}/${_name(spec.name)}',
    );
    final commit = row['commit'];
    if (row['name'] != spec.name ||
        commit is! Map ||
        commit['id'] != spec.sha) {
      throw const Mr7Refused('observerRef');
    }
    return row;
  }

  Future<Map<String, Object?>> _release(Mr7ReleaseObservation spec) async {
    _sha(spec.sha);
    final body = _permit._sentBody;
    if (_permit.operation == 'createRelease') {
      _sentTo('$_root/releases');
      if (body is! Map || body['tag_name'] != spec.tag) {
        throw const Mr7Refused('observerMutationTarget');
      }
    } else {
      _sentTo('$_root/releases/${_name(spec.tag)}');
    }
    if (body is! Map || body['name'] != spec.name) {
      throw const Mr7Refused('observerMutationTarget');
    }
    final row = await _map('$_root/releases/${_name(spec.tag)}');
    final commit = row['commit'];
    if (row['tag_name'] != spec.tag ||
        row['name'] != spec.name ||
        commit is! Map ||
        commit['id'] != spec.sha) {
      throw const Mr7Refused('observerRelease');
    }
    return row;
  }

  Future<Map<String, List<int>>> _snippet(Mr7SnippetObservation spec) async {
    if (spec.id <= 0 ||
        spec.revision.isEmpty ||
        spec.files.isEmpty ||
        spec.files.length > 100 ||
        (result.id != null && result.id != spec.id)) {
      throw const Mr7Refused('observerSnippet');
    }
    final path = '$_root/snippets/${spec.id}';
    _sentTo(_permit.operation == 'createSnippet' ? '$_root/snippets' : path);
    final rawPaths = <String, String>{};
    for (final entry in spec.files.entries) {
      if (entry.value.bytes.length > 2 * 1024 * 1024) {
        throw const Mr7Refused('observerContent');
      }
      rawPaths[entry.key] =
          '$path/files/${_name(entry.value.ref)}/${_name(entry.key)}/raw';
    }
    Future<void> metadata() async {
      final row = await _map(path);
      final files = row['files'];
      if (row['id'] != spec.id ||
          row['project_id'] != _identity.projectId ||
          row['updated_at'] != spec.revision ||
          row['visibility'] != 'private' ||
          files is! List ||
          files.length != spec.files.length) {
        throw const Mr7Refused('observerSnippet');
      }
      final seen = <String>{};
      for (final file in files) {
        if (file is! Map ||
            file['path'] is! String ||
            !seen.add(file['path'] as String) ||
            !rawPaths.containsKey(file['path']) ||
            file['raw_url'] !=
                '${_session.instance}/${_identity.path}/-/snippets/${spec.id}/raw/${_name(spec.files[file['path']]!.ref)}/${(file['path'] as String).split('/').map(Uri.encodeComponent).join('/')}') {
          throw const Mr7Refused('observerSnippetRevision');
        }
      }
    }

    await metadata();
    final content = <String, List<int>>{};
    for (final entry in rawPaths.entries) {
      _path(entry.value);
      final response = await _session.observer.get<List<int>>(
        entry.value,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (response.statusCode != 200 ||
          bytes == null ||
          bytes.length > 2 * 1024 * 1024 ||
          bytes.length != spec.files[entry.key]!.bytes.length ||
          !Iterable<int>.generate(
            bytes.length,
          ).every((i) => bytes[i] == spec.files[entry.key]!.bytes[i])) {
        throw const Mr7Refused('observerContent');
      }
      content[entry.key] = List.unmodifiable(bytes);
    }
    await metadata();
    return Map.unmodifiable(content);
  }

  Future<bool> _parentState(Mr7ParentStateObservation spec) async {
    final parent = await _parent(spec.parent);
    if (spec.state == Mr7ParentState.autoMerge) {
      _sentTo('${parent.path}/cancel_auto_merge');
      final present = [
        'merge_when_pipeline_succeeds',
        'auto_merge_enabled',
      ].where(parent.row.containsKey).toList();
      if (present.isEmpty ||
          present.any((key) => parent.row[key] is! bool) ||
          present.any((key) => parent.row[key] == true) != spec.expected) {
        throw const Mr7Refused('observerState');
      }
      return true;
    }
    _sentTo(
      '${parent.path}/${spec.state == Mr7ParentState.starred ? (spec.expected ? 'star' : 'unstar') : (spec.expected ? 'subscribe' : 'unsubscribe')}',
    );
    final field = switch (spec.state) {
      Mr7ParentState.starred => 'starred',
      Mr7ParentState.subscribed => 'subscribed',
      Mr7ParentState.autoMerge => 'merge_when_pipeline_succeeds',
    };
    if (parent.row[field] is! bool || parent.row[field] != spec.expected) {
      throw const Mr7Refused('observerState');
    }
    return true;
  }

  Future<Map<String, Object?>> _rebase(Mr7RebaseObservation spec) async {
    _sha(spec.sha);
    if (_permit.operation != 'rebaseMergeRequest' ||
        _permit.sent != 1 ||
        result.status != 202 ||
        spec.parent.kind != Mr7ParentKind.mergeRequest ||
        spec.maxAttempts < 1 ||
        spec.maxAttempts > 20 ||
        spec.interval.isNegative ||
        spec.interval > const Duration(milliseconds: 100) ||
        spec.timeout <= Duration.zero ||
        spec.timeout > const Duration(seconds: 2)) {
      throw const Mr7Refused('observerRebase');
    }
    var expired = false;
    Future<Map<String, Object?>> poll() async {
      for (var attempt = 0; attempt < spec.maxAttempts; attempt++) {
        if (expired) throw const Mr7Refused('observerRebaseTimeout');
        final parent = await _parent(
          spec.parent,
          query: {'include_rebase_in_progress': true},
        );
        _sentTo('${parent.path}/rebase');
        if (expired) throw const Mr7Refused('observerRebaseTimeout');
        if (parent.row['rebase_in_progress'] == false &&
            parent.row.containsKey('merge_error') &&
            parent.row['merge_error'] == null &&
            parent.row['sha'] == spec.sha &&
            _permit._rebaseBeforeSha != null &&
            parent.row['sha'] != _permit._rebaseBeforeSha) {
          return parent.row;
        }
        if (attempt + 1 < spec.maxAttempts) {
          await Future<void>.delayed(spec.interval);
        }
      }
      throw const Mr7Refused('observerRebasePending');
    }

    return poll().timeout(
      spec.timeout,
      onTimeout: () {
        expired = true;
        throw const Mr7Refused('observerRebaseTimeout');
      },
    );
  }

  Future<void> bindReturnedResource(String gid, {required String path}) async {
    _scope();
    _path(path);
    if (gid != result.stringId &&
        !RegExp('^gid://gitlab/[A-Za-z]+/${result.id}\$').hasMatch(gid)) {
      throw const Mr7Refused('readbackReturnedId');
    }
    await _session.bindGraphResource(gid, path: path);
    _scope();
  }

  ({String rest, String field, String type, bool create})?
  get _graphCollectionKind => switch (_permit.operation) {
    'createNote' => (rest: 'notes', field: 'notes', type: 'Note', create: true),
    'updateNote' || 'deleteNote' => (
      rest: 'notes',
      field: 'notes',
      type: 'Note',
      create: false,
    ),
    'addAwardEmoji' => (
      rest: 'award_emoji',
      field: 'awardEmoji',
      type: 'AwardEmoji',
      create: true,
    ),
    'removeAwardEmoji' => (
      rest: 'award_emoji',
      field: 'awardEmoji',
      type: 'AwardEmoji',
      create: false,
    ),
    'createIssue' => (
      rest: 'issues',
      field: 'issues',
      type: 'Issue',
      create: true,
    ),
    'updateIssue' || 'deleteIssue' => (
      rest: 'issues',
      field: 'issues',
      type: 'Issue',
      create: false,
    ),
    'createMergeRequest' => (
      rest: 'merge_requests',
      field: 'mergeRequests',
      type: 'MergeRequest',
      create: true,
    ),
    'updateMergeRequest' || 'deleteMergeRequest' => (
      rest: 'merge_requests',
      field: 'mergeRequests',
      type: 'MergeRequest',
      create: false,
    ),
    'createLabel' => (
      rest: 'labels',
      field: 'labels',
      type: 'Label',
      create: true,
    ),
    'updateLabel' || 'deleteLabel' => (
      rest: 'labels',
      field: 'labels',
      type: 'Label',
      create: false,
    ),
    'createMilestone' => (
      rest: 'milestones',
      field: 'milestones',
      type: 'Milestone',
      create: true,
    ),
    'updateMilestone' || 'deleteMilestone' => (
      rest: 'milestones',
      field: 'milestones',
      type: 'Milestone',
      create: false,
    ),
    _ => null,
  };

  ({String field, String type, String target, String? noteId}) _graphCollection(
    Mr7GraphObservation spec,
    String parentPath,
  ) {
    final kind = _graphCollectionKind;
    if (kind == null || _permit.sent != 1) {
      throw const Mr7Refused('observerMutationTarget');
    }
    final parentPattern = kind.type == 'Note'
        ? '^$_root/(?:issues|merge_requests)/[1-9][0-9]*\$'
        : kind.type == 'AwardEmoji'
        ? '^$_root/(?:issues|merge_requests)/[1-9][0-9]*(?:/notes/[1-9][0-9]*)?\$'
        : '^$_root\$';
    if (!RegExp(parentPattern).hasMatch(parentPath)) {
      throw const Mr7Refused('observerParent');
    }
    String returned() {
      final gid = result.stringId ?? 'gid://gitlab/${kind.type}/${result.id}';
      if (!RegExp('^gid://gitlab/${kind.type}/[1-9][0-9]*\$').hasMatch(gid)) {
        throw const Mr7Refused('readbackReturnedId');
      }
      return gid;
    }

    final sentPath = _permit._sentPath;
    late String target;
    if (sentPath == 'graphql') {
      final body = _permit._sentBody;
      final operation = _selectedGraphOperation(body);
      final field = switch (_permit.operation) {
        'createNote' => 'createNote',
        'updateNote' => 'updateNote',
        'deleteNote' => 'destroyNote',
        'addAwardEmoji' => 'awardEmojiAdd',
        _ => null,
      };
      if (body is! Map ||
          operation == null ||
          operation.kind != 'mutation' ||
          operation.roots.length != 1 ||
          field == null ||
          operation.roots.single.field != field) {
        throw const Mr7Refused('observerMutationTarget');
      }
      final arguments = operation.resolve(
        operation.roots.single.arguments,
        body['variables'] as Map? ?? const {},
      );
      final input = arguments is Map ? arguments['input'] : null;
      if (input is! Map) throw const Mr7Refused('observerMutationTarget');
      if (_permit.operation == 'createNote') {
        if (input['noteableId'] != spec.parentId) {
          throw const Mr7Refused('observerMutationTarget');
        }
        target = returned();
      } else if (kind.type == 'Note') {
        final gid = input['id'];
        final path = _permit._graphResourcesAtSend[gid];
        if (gid is! String ||
            path == null ||
            !RegExp('^$parentPath/notes/[1-9][0-9]*\$').hasMatch(path)) {
          throw const Mr7Refused('observerMutationTarget');
        }
        target = gid;
      } else {
        if (input['awardableId'] != spec.parentId) {
          throw const Mr7Refused('observerMutationTarget');
        }
        target = returned();
      }
    } else {
      final collection = '$parentPath/${kind.rest}';
      if (kind.create) {
        _sentTo(collection);
        target = returned();
      } else {
        if (sentPath == null ||
            !RegExp('^$collection/[1-9][0-9]*\$').hasMatch(sentPath)) {
          throw const Mr7Refused('observerMutationTarget');
        }
        final selector = int.parse(sentPath.split('/').last);
        if (kind.type == 'Issue' || kind.type == 'MergeRequest') {
          final bound = _permit._graphResourcesAtSend.entries.where(
            (entry) =>
                entry.value == sentPath &&
                entry.key.startsWith('gid://gitlab/${kind.type}/'),
          );
          target = bound.length == 1
              ? bound.single.key
              : throw const Mr7Refused('observerMutationTarget');
        } else {
          target = 'gid://gitlab/${kind.type}/$selector';
        }
      }
    }
    if ((result.stringId != null || result.id != null) &&
        returned() != target) {
      throw const Mr7Refused('readbackReturnedId');
    }
    final note = kind.type == 'AwardEmoji'
        ? RegExp(r'/notes/([1-9][0-9]*)$').firstMatch(parentPath)
        : null;
    final noteId = note == null ? null : 'gid://gitlab/Note/${note[1]}';
    if (spec.noteId != noteId) {
      throw const Mr7Refused('observerRelationship');
    }
    return (field: kind.field, type: kind.type, target: target, noteId: noteId);
  }

  Future<Map<String, Object?>> _graph(Mr7GraphObservation spec) async {
    if (spec.parentId != 'gid://gitlab/Project/${_identity.projectId}' &&
        !_session._graphResources.containsKey(spec.parentId)) {
      throw const Mr7Refused('observerParent');
    }
    if ((spec.connectionPath == null) != (spec.expectedIds == null)) {
      throw const Mr7Refused('observerConnection');
    }
    final removal =
        _permit.operation.startsWith('delete') ||
        _permit.operation.startsWith('remove');
    if (spec.connectionPath == null &&
        (removal ||
            spec.absentIds.isNotEmpty ||
            !const {
              'setStar',
              'setSubscribed',
              'cancelAutoMerge',
            }.contains(_permit.operation))) {
      throw const Mr7Refused('observerConnection');
    }
    final parentPath =
        spec.parentId == 'gid://gitlab/Project/${_identity.projectId}'
        ? _root
        : _session._graphResources[spec.parentId]!;
    final sentBody = _permit._sentBody;
    final requested = RegExp(r'gid://gitlab/[A-Za-z]+/[1-9][0-9]*')
        .allMatches(jsonEncode(sentBody is Map ? sentBody['variables'] : null))
        .map((m) => m[0]!)
        .toSet();
    final sentPath = _permit._sentPath;
    if (sentPath == 'graphql' &&
        parentPath != _root &&
        _permit._graphResourcesAtSend[spec.parentId] != parentPath) {
      throw const Mr7Refused('observerMutationTarget');
    }
    if (sentPath != null && sentPath.startsWith('projects/')) {
      if (sentPath != parentPath && !sentPath.startsWith('$parentPath/')) {
        throw const Mr7Refused('observerMutationTarget');
      }
    } else if (!requested.any((gid) {
      final path = _permit._graphResourcesAtSend[gid];
      return path != null &&
          (path == parentPath || path.startsWith('$parentPath/'));
    })) {
      throw const Mr7Refused('observerMutationTarget');
    }
    final binding = spec.connectionPath == null
        ? null
        : _graphCollection(spec, parentPath);
    final operation = _selectedGraphOperation({'query': spec.document});
    if (binding != null) {
      final selection =
          operation?.selections[[
            ...spec.recordPath.skip(1),
            ...spec.connectionPath!,
          ].join('/')];
      if (spec.recordPath.isEmpty ||
          spec.recordPath.first != 'data' ||
          spec.connectionPath!.length != 1 ||
          selection == null ||
          selection.field != binding.field ||
          selection.arguments.keys.any(
            (key) => !const {'first', 'after'}.contains(key),
          )) {
        throw const Mr7Refused('observerConnection');
      }
      final first = selection.arguments['first'];
      if (first != null) {
        final size = operation!.resolve(first, spec.variables);
        if (size is! int || size <= 0 || size > 100) {
          throw const Mr7Refused('observerConnection');
        }
      }
      final after = selection.arguments['after'];
      if ((after != null &&
              (after is! _GraphVariable ||
                  after.name != spec.cursorVariable)) ||
          (after != null &&
              operation!.resolve(after, spec.variables) != null) ||
          (removal
              ? spec.absentIds.length != 1 ||
                    !spec.absentIds.contains(binding.target)
              : spec.absentIds.isNotEmpty)) {
        throw const Mr7Refused('observerAbsenceTarget');
      }
    }
    final variables = Map<String, Object?>.from(spec.variables);
    final ids = <String>{};
    final cursors = <String>{};
    int? total;
    for (var page = 0; page < 20; page++) {
      if (!(graphQueries[spec.document]?.contains(mr7Digest(variables)) ??
          false)) {
        throw const Mr7Refused('unsealedObserverQuery');
      }
      final response = await _session.observer.post<Object?>(
        '${_session.instance}/api/graphql',
        data: {'query': spec.document, 'variables': variables},
      );
      final envelope = response.data;
      final errors = envelope is Map ? envelope['errors'] : null;
      final actor = _selectRecord(envelope, const ['data', 'currentUser']);
      final record = _selectRecord(envelope, spec.recordPath);
      final project = record is Map
          ? (record['id'] == 'gid://gitlab/Project/${_identity.projectId}'
                ? record
                : record['project'])
          : null;
      if (response.statusCode != 200 ||
          envelope is! Map ||
          (errors != null && (errors is! List || errors.isNotEmpty)) ||
          actor is! Map ||
          actor['id'] != 'gid://gitlab/User/${_identity.userId}' ||
          actor['username'] != _identity.namespace ||
          record is! Map ||
          record['id'] != spec.parentId ||
          project is! Map ||
          project['id'] != 'gid://gitlab/Project/${_identity.projectId}' ||
          project['fullPath'] != _identity.path) {
        throw const Mr7Refused('readbackIdentity');
      }
      if (spec.connectionPath == null) return Map<String, Object?>.from(record);
      final connection = _selectRecord(record, spec.connectionPath!);
      final nodes = connection is Map ? connection['nodes'] : null;
      final info = connection is Map ? connection['pageInfo'] : null;
      final count = connection is Map ? connection['totalCount'] : null;
      if (connection is! Map ||
          nodes is! List ||
          nodes.length > 100 ||
          info is! Map ||
          info['hasNextPage'] is! bool ||
          count is! int ||
          count < 0 ||
          count > 2000 ||
          (total != null && count != total)) {
        throw const Mr7Refused('observerConnection');
      }
      total = count;
      for (final node in nodes) {
        final id = node is Map ? node['id'] : null;
        final note = node is Map ? node['note'] : null;
        if (node is! Map ||
            id is! String ||
            !RegExp(
              '^gid://gitlab/${binding!.type}/[1-9][0-9]*\$',
            ).hasMatch(id) ||
            !ids.add(id) ||
            (binding.noteId != null &&
                (note is! Map || note['id'] != binding.noteId))) {
          throw const Mr7Refused('observerRelationship');
        }
      }
      if (info['hasNextPage'] == false) {
        if (ids.length != total ||
            ids.length != spec.expectedIds!.length ||
            !ids.containsAll(spec.expectedIds!) ||
            (!removal && !ids.contains(binding!.target)) ||
            ids.any(spec.absentIds.contains)) {
          throw const Mr7Refused('observerAbsence');
        }
        return Map<String, Object?>.from(record);
      }
      final cursor = info['endCursor'];
      if (binding == null ||
          operation!
                  .selections[[
                    ...spec.recordPath.skip(1),
                    ...spec.connectionPath!,
                  ].join('/')]!
                  .arguments['after']
              is! _GraphVariable ||
          nodes.isEmpty ||
          cursor is! String ||
          cursor.isEmpty ||
          cursor.length > 1024 ||
          !cursors.add(cursor)) {
        throw const Mr7Refused('observerConnection');
      }
      variables[spec.cursorVariable] = cursor;
    }
    throw const Mr7Refused('observerConnectionCap');
  }

  Future<Map<String, Object?>> read(String path) async {
    final root = 'projects/${_identity.projectId}';
    if (!paths.contains(path) ||
        (path != root && !path.startsWith('$root/')) ||
        _permit.returnedId == null ||
        (_permit.returnedProjectId != null &&
            _permit.returnedProjectId != _identity.projectId)) {
      throw const Mr7Refused('readbackTarget');
    }
    final returnedId = _permit.returnedId!;
    if ((path == root && returnedId != _identity.projectId) ||
        (path != root &&
            int.tryParse(path.split('/').last) !=
                (RegExp(r'/milestones/[1-9][0-9]*$').hasMatch(path)
                    ? returnedId
                    : _permit.returnedIid ?? returnedId))) {
      throw const Mr7Refused('readbackReturnedId');
    }
    final row = await _session.read(path);
    if (row['id'] != returnedId ||
        (row.containsKey('project_id') &&
            row['project_id'] != _identity.projectId)) {
      throw const Mr7Refused('readbackIdentity');
    }
    verifiedRequests++;
    return row;
  }

  Future<Map<String, Object?>> query(
    String document,
    Map<String, Object?> variables, {
    required List<String> recordPath,
  }) async {
    final registered = _session.observerAdapter.graphReadDocuments[document];
    if (registered == null ||
        !registered.contains(mr7Digest(variables)) ||
        (_permit.returnedGlobalId == null && _permit.returnedId == null)) {
      throw const Mr7Refused('readbackTarget');
    }
    final response = await _session.observer.post<Object?>(
      '${_session.instance}/api/graphql',
      data: {'query': document, 'variables': variables},
    );
    final record = _selectRecord(response.data, recordPath);
    final project = record is Map ? record['project'] : null;
    if (response.statusCode != 200 ||
        record is! Map ||
        record['id'] != (_permit.returnedGlobalId ?? _permit.returnedId) ||
        project is! Map ||
        (project['id'] != _identity.projectId &&
            project['id'] != 'gid://gitlab/Project/${_identity.projectId}') ||
        project['fullPath'] != _identity.path) {
      throw const Mr7Refused('readbackIdentity');
    }
    verifiedRequests++;
    return Map<String, Object?>.from(record);
  }
}

final class Mr7SandboxSession {
  Mr7SandboxSession({
    required this.server,
    this.expectedUserId = 7,
    this.namespace = 'synthetic-owner',
    required this.nonce,
    Uri? instance,
    bool Function()? boundaryValid,
    Future<void> Function()? eventDelay,
    this.requestCap = 200,
  }) : instance = instance ?? Uri.parse('https://gitlab.invalid/install'),
       boundaryValid = boundaryValid ?? (() => true),
       eventDelay =
           eventDelay ??
           (() => Future<void>.delayed(const Duration(milliseconds: 10))) {
    observerAdapter = Mr7ObserverAdapter(server, this.instance);
    observerAdapter.beforeRequest = chargeRequest;
    observerAdapter.validateRequest = (request) =>
        validateRead(request, allowStopped: true);
    observer = Dio(
      BaseOptions(
        baseUrl: '${this.instance}/api/v4/',
        followRedirects: false,
        headers: {'cache-control': 'no-cache, no-store'},
        validateStatus: (s) => s != null && s < 500,
      ),
    )..httpClientAdapter = observerAdapter;
    writerAdapter = Mr7GuardedAdapter(this);
    writer = Dio(
      BaseOptions(baseUrl: '${this.instance}/api/v4/', followRedirects: false),
    )..httpClientAdapter = writerAdapter;
  }
  final Mr7SyntheticGitLab server;
  final int expectedUserId;
  final String namespace;
  final String nonce;
  final Uri instance;
  final bool Function() boundaryValid;
  final Future<void> Function() eventDelay;
  final int requestCap;
  late final Mr7ObserverAdapter observerAdapter;
  late final Mr7GuardedAdapter writerAdapter;
  late final Dio observer;
  late final Dio writer;
  Mr7Identity? identity;
  Mr7MutationPermit? permit;
  bool inFlight = false;
  int pendingMutations = 0;
  bool terminalDeletionAccepted = false;
  bool quarantined = false;
  bool _setupAuthorized = false;
  bool _cleanupAuthorized = false;
  bool _started = false;
  bool _finished = false;
  bool _finalizing = false;
  int _namespaceId = 0;
  int? _createdId;
  int _httpRequests = 0;
  bool _isolationFailed = false;
  final Map<String, String> _graphResources = {};
  String? stopReason;
  DateTime? windowStart;
  DateTime? windowEnd;
  final List<Map<String, Object?>> requestLedger = [];
  final List<Map<String, Object?>> observedEvents = [];
  final Map<String, Object?> isolation = {
    'status': 'NOT_RUN',
    'complete': false,
    'pages': 0,
  };
  final Map<String, Object?> cleanup = {
    'status': 'NOT_RUN',
    'accepted': false,
    'deletionVerified': false,
  };

  void stop(String reason) {
    stopReason ??= reason;
    quarantined = true;
    permit = null;
  }

  void _open() {
    if (!boundaryValid()) stop('accountBoundary');
    if (quarantined || _finished) {
      throw const Mr7Refused('sessionStopped');
    }
  }

  void chargeRequest() {
    if (_httpRequests >= requestCap) {
      stop('httpBudget');
      throw const Mr7Refused('httpBudget');
    }
    _httpRequests++;
  }

  List<String> _restSegments(RequestOptions request) => request.uri.pathSegments
      .skip(instance.pathSegments.where((s) => s.isNotEmpty).length + 2)
      .toList();

  /// Observations after quarantine remain read-only and restricted to this
  /// account and sandbox. A changed account generation permits no requests.
  void validateRead(RequestOptions request, {required bool allowStopped}) {
    final current = boundaryValid();
    if (!current) stop('accountBoundary');
    if (!current || _finished || (!allowStopped && quarantined)) {
      throw const Mr7Refused('sessionStopped');
    }
    final target = identity;
    if (_sealedGraphRead(request, observerAdapter.graphReadDocuments)) {
      if (target == null) throw const Mr7Refused('unboundRead');
      _requireGraphTargets(request.data);
      return;
    }
    final segments = _restSegments(request);
    final path = segments.join('/');
    final setupRead =
        path == 'user' ||
        (path == 'namespaces' && identity == null) ||
        path == 'users/$expectedUserId/events';
    final projectRead =
        target != null &&
        segments.length >= 2 &&
        segments.first == 'projects' &&
        (segments[1] == '${target.projectId}' ||
            (segments.length == 2 && segments[1] == target.path));
    final parentRead =
        _finalizing &&
        target != null &&
        path == 'projects' &&
        request.queryParameters.length == 3 &&
        request.queryParameters['namespace_id'] == target.namespaceId &&
        request.queryParameters['page'] is int &&
        (request.queryParameters['page'] as int) >= 1 &&
        (request.queryParameters['page'] as int) <= 20 &&
        request.queryParameters['per_page'] == 100;
    if (request.method != 'GET' ||
        (!setupRead && !projectRead && !parentRead)) {
      stop('outsideSandboxRead');
      throw const Mr7Refused('outsideSandboxRead');
    }
    if (!parentRead) _requireBoundValues(request.queryParameters);
  }

  /// Closed GraphQL documents still require independently proven ownership of
  /// resource GIDs; registering a variables digest alone grants no scope.
  Future<void> bindGraphResource(String gid, {required String path}) async {
    await _bindGraphResource(gid, path: path, workItem: false);
  }

  /// WorkItem is a separate GraphQL type, even when its REST owner is an issue.
  Future<void> bindWorkItemGraphResource(
    String gid, {
    required String path,
  }) async {
    await _bindGraphResource(gid, path: path, workItem: true);
  }

  /// Seed a Todo only in the synthetic server and bind its fresh project owner.
  Future<void> bindProjectTodo({
    required int todoId,
    required String parentPath,
    String? snoozedUntil,
  }) async {
    _open();
    final target = identity;
    if (target == null ||
        todoId <= 0 ||
        server._todos.length >= 20 ||
        server._todos.containsKey(todoId) ||
        (snoozedUntil != null && DateTime.tryParse(snoozedUntil) == null)) {
      throw const Mr7Refused('todoFixture');
    }
    final root = 'projects/${target.projectId}';
    if (!RegExp(
      '^$root/(issues|merge_requests)/[1-9][0-9]*\$',
    ).hasMatch(parentPath)) {
      throw const Mr7Refused('todoFixture');
    }
    await verifyIdentity();
    final actor = await read('user');
    final parent = await read(parentPath);
    final iid = int.parse(parentPath.split('/').last);
    if (actor['id'] != target.userId ||
        actor['username'] != target.namespace ||
        parent['id'] is! int ||
        (parent['id'] as int) <= 0 ||
        parent['iid'] != iid ||
        parent['project_id'] != target.projectId) {
      stop('todoForeign');
      throw const Mr7Refused('todoForeign');
    }
    server._todos[todoId] = _Mr7TodoFixture(
      id: todoId,
      actorId: target.userId,
      projectId: target.projectId,
      parentPath: parentPath,
      parentId: parent['id'] as int,
      iid: iid,
      mergeRequest: parentPath.contains('/merge_requests/'),
      snoozedUntil: snoozedUntil,
    );
    _graphResources['gid://gitlab/Todo/$todoId'] = parentPath;
    await verifyIdentity();
    _open();
  }

  bool allowsTodoFixture(String operation) =>
      const {'snoozeTodo', 'unsnoozeTodo'}.contains(operation) &&
      server._todos.isNotEmpty &&
      !quarantined;

  Future<void> _refreshTodo(String gid) async {
    final match = RegExp(r'^gid://gitlab/Todo/([1-9][0-9]*)$').firstMatch(gid);
    final target = identity;
    final todo = match == null ? null : server._todos[int.parse(match[1]!)];
    if (target == null ||
        todo == null ||
        todo.actorId != target.userId ||
        todo.projectId != target.projectId ||
        _graphResources[gid] != todo.parentPath) {
      stop('todoForeign');
      throw const Mr7Refused('todoForeign');
    }
    final actor = await read('user');
    final parent = await read(todo.parentPath);
    if (actor['id'] != target.userId ||
        actor['username'] != target.namespace ||
        parent['id'] != todo.parentId ||
        parent['iid'] != todo.iid ||
        parent['project_id'] != target.projectId) {
      stop('todoForeign');
      throw const Mr7Refused('todoForeign');
    }
  }

  Future<void> _bindGraphResource(
    String gid, {
    required String path,
    required bool workItem,
  }) async {
    _open();
    final match = RegExp(
      r'^gid://gitlab/([A-Za-z]+)/([1-9][0-9]*)$',
    ).firstMatch(gid);
    final target = identity;
    if (match == null || target == null || match[1] == 'Group') {
      throw const Mr7Refused('graphResource');
    }
    if (workItem != (match[1] == 'WorkItem')) {
      stop('foreignResource');
      throw const Mr7Refused('foreignResource');
    }
    final root = 'projects/${target.projectId}';
    const resourcePaths = {
      'Issue': r'issues/[1-9][0-9]*',
      'WorkItem': r'issues/[1-9][0-9]*',
      'MergeRequest': r'merge_requests/[1-9][0-9]*',
      'Note': r'(?:issues|merge_requests)/[1-9][0-9]*/notes/[1-9][0-9]*',
      'Label': r'labels/[1-9][0-9]*',
      'Milestone': r'milestones/[1-9][0-9]*',
    };
    final pattern = resourcePaths[match[1]];
    final typedPath = match[1] == 'Project'
        ? path == root
        : pattern != null && RegExp('^$root/$pattern\$').hasMatch(path);
    if (!typedPath) {
      stop('foreignResource');
      throw const Mr7Refused('foreignResource');
    }
    final row = await read(path);
    if (row['id'] != int.parse(match[2]!) ||
        (match[1] == 'Project'
            ? path != root
            : row['project_id'] != target.projectId)) {
      stop('foreignResource');
      throw const Mr7Refused('foreignResource');
    }
    if (match[1] == 'Issue' ||
        match[1] == 'MergeRequest' ||
        match[1] == 'WorkItem') {
      final iid = row['iid'];
      if (iid is! int || iid <= 0 || iid != int.parse(path.split('/').last)) {
        stop('foreignResource');
        throw const Mr7Refused('foreignResource');
      }
    }
    if (match[1] == 'Note') {
      final segments = path.split('/');
      final parent = await read(segments.take(4).join('/'));
      if (parent['id'] is! int ||
          (parent['id'] as int) <= 0 ||
          parent['iid'] != int.parse(segments[3]) ||
          parent['project_id'] != target.projectId ||
          row['noteable_id'] != parent['id']) {
        stop('foreignResource');
        throw const Mr7Refused('foreignResource');
      }
    }
    _open();
    _graphResources[gid] = path;
  }

  void _requireGraphTargets(Object? body) {
    final operation = _selectedGraphOperation(body);
    if (operation == null ||
        body is! Map ||
        (body['variables'] != null && body['variables'] is! Map)) {
      stop('unsealedGraph');
      throw const Mr7Refused('unsealedGraph');
    }
    try {
      final todoRead =
          body['query'] is String &&
          const {
            _todoPendingDocument,
            _todoSnoozedDocument,
          }.contains(mr7Digest(body['query'])) &&
          operation.kind == 'query' &&
          server._todos.isNotEmpty;
      if (!todoRead &&
          operation.fields.any(
            const {'group', 'groups', 'namespaces'}.contains,
          )) {
        throw const Mr7Refused('foreignResource');
      }
      for (final entry in operation.selections.entries.where(
        (entry) => entry.value.field == 'namespace',
      )) {
        final prefix = '${entry.key}/';
        final children = operation.selections.entries
            .where((child) => child.key.startsWith(prefix))
            .toList();
        if (!entry.key.contains('/') ||
            entry.value.arguments.isNotEmpty ||
            children.isEmpty ||
            children.any(
              (child) =>
                  child.key.substring(prefix.length).contains('/') ||
                  !const {'id', 'fullPath'}.contains(child.value.field) ||
                  child.value.arguments.isNotEmpty,
            )) {
          throw const Mr7Refused('foreignResource');
        }
      }
      // Retain the closed variables/literal checks, and additionally resolve
      // every argument under its actual schema name, independent of variable aliases.
      _requireBoundValues(body['variables'], graph: true);
      _requireBoundValues(body['query'], graph: true);
      for (final arguments in operation.arguments) {
        _requireBoundValues(
          operation.resolve(arguments, body['variables'] as Map? ?? const {}),
          graph: true,
        );
      }
      bool hasSelector(Object? value) {
        if (value is! Map) return false;
        return value.entries.any((entry) {
          final key = '${entry.key}'.replaceAll('_', '').toLowerCase();
          return (const {
                    'id',
                    'ids',
                    'workitemid',
                    'workitemids',
                    'targetid',
                    'targetids',
                    'noteableid',
                    'awardableid',
                    'projectid',
                    'projectids',
                    'targetprojectid',
                    'sourceprojectid',
                    'fullpath',
                    'projectpath',
                  }.contains(key) &&
                  entry.value != null &&
                  (entry.value is! List || (entry.value as List).isNotEmpty)) ||
              hasSelector(entry.value);
        });
      }

      for (final root in operation.roots) {
        if (todoRead && root.field == 'currentUser' && root.arguments.isEmpty) {
          continue;
        }
        if (operation.kind == 'query' &&
            root.field == 'currentUser' &&
            root.arguments.isEmpty &&
            root.identityProjection) {
          continue; // Bound to the already verified current account.
        }
        if (!hasSelector(
          operation.resolve(
            root.arguments,
            body['variables'] as Map? ?? const {},
          ),
        )) {
          throw const Mr7Refused('unboundGraphRoot');
        }
      }
    } catch (_) {
      stop('foreignResource');
      rethrow;
    }
  }

  void _requireBoundValues(Object? value, {bool graph = false}) {
    final target = identity;
    bool bound(Object? node) {
      if (node is Map) {
        for (final entry in node.entries) {
          final key = '${entry.key}'.replaceAll('_', '').toLowerCase();
          if (const {
            'groupid',
            'groupids',
            'namespaceid',
            'namespacepath',
            'forkedfromproject',
            'mirror',
            'importurl',
          }.contains(key)) {
            return false;
          }
          if ((key == 'projectid' ||
                  key == 'targetprojectid' ||
                  key == 'sourceprojectid') &&
              entry.value != target?.projectId &&
              entry.value != 'gid://gitlab/Project/${target?.projectId}') {
            return false;
          }
          if ((key == 'projectpath' || key == 'fullpath') &&
              entry.value != target?.path) {
            return false;
          }
          if (graph &&
              key.endsWith('ids') &&
              (entry.value is! List ||
                  !(entry.value as List).every(
                    (item) =>
                        item is String &&
                        RegExp(
                          r'^gid://gitlab/[A-Za-z]+/[1-9][0-9]*$',
                        ).hasMatch(item),
                  ))) {
            return false;
          }
          if (graph &&
              const {
                'id',
                'workitemid',
                'targetid',
                'noteableid',
                'awardableid',
              }.contains(key) &&
              (entry.value is! String ||
                  !RegExp(
                    r'^gid://gitlab/[A-Za-z]+/[1-9][0-9]*$',
                  ).hasMatch(entry.value as String))) {
            return false;
          }
          if (!bound(entry.value)) return false;
        }
      } else if (node is List) {
        return node.every(bound);
      } else if (node is String && graph) {
        for (final match in RegExp(
          r'gid://gitlab/[A-Za-z]+/[0-9]+',
        ).allMatches(node)) {
          final gid = match[0]!;
          if (gid != 'gid://gitlab/Project/${target?.projectId}' &&
              !_graphResources.containsKey(gid)) {
            return false;
          }
        }
        // Target arguments in a sealed document must come from checked
        // variables; do not admit inline literal target identifiers.
        if (RegExp(
          r'\b(?:id|projectId|groupId|fullPath|projectPath|noteableId|awardableId)\s*:\s*["0-9]',
        ).hasMatch(node)) {
          return false;
        }
      }
      return true;
    }

    if (!bound(value)) {
      stop('foreignResource');
      throw const Mr7Refused('foreignResource');
    }
  }

  Future<void> _refreshGraphResources(Object? variables) async {
    final encoded = jsonEncode(variables);
    for (final entry in _graphResources.entries.toList()) {
      if (encoded.contains(entry.key)) {
        if (entry.key.startsWith('gid://gitlab/Todo/')) {
          await _refreshTodo(entry.key);
        } else if (entry.key.startsWith('gid://gitlab/WorkItem/')) {
          await bindWorkItemGraphResource(entry.key, path: entry.value);
        } else {
          await bindGraphResource(entry.key, path: entry.value);
        }
      }
    }
  }

  Future<Map<String, Object?>> read(String path) async {
    final r = await observer.get<Object?>(path);
    if (r.statusCode != 200 || r.data is! Map) {
      throw const Mr7Refused('unreadableIdentity');
    }
    return Map<String, Object?>.from(r.data! as Map);
  }

  /// Capture only bounded, freshly read project/resource metadata before send.
  Future<Mr7PreReadSnapshot> captureSnapshot(
    List<Mr7SnapshotSpec> specs,
  ) async {
    _open();
    final target = identity;
    if (target == null ||
        specs.isEmpty ||
        specs.length > 8 ||
        inFlight ||
        pendingMutations != 0 ||
        permit?.sent != null && permit!.sent > 0) {
      throw const Mr7Refused('snapshotConfiguration');
    }
    await verifyIdentity();
    final actor = await read('user');
    if (actor['id'] != target.userId || actor['username'] != target.namespace) {
      stop('snapshotActor');
      throw const Mr7Refused('snapshotActor');
    }
    final root = 'projects/${target.projectId}';
    final paths = <String>{};
    final rows = <_Mr7SnapshotRow>[];
    for (final spec in specs) {
      if (!paths.add(spec.path) ||
          !(spec.path == root ||
              RegExp(
                '^$root/(issues|merge_requests)/[1-9][0-9]*\$',
              ).hasMatch(spec.path)) ||
          spec.fields.length > 32 ||
          !spec.fields.containsAll(spec.unchangedFields) ||
          spec.fields.any(
            (field) =>
                !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$').hasMatch(field),
          )) {
        throw const Mr7Refused('snapshotConfiguration');
      }
      final row = await read(spec.path);
      final id = row['id'];
      final iid = row['iid'];
      if (jsonEncode(row).length > 2 * 1024 * 1024 ||
          id is! int ||
          id <= 0 ||
          (spec.path == root
              ? id != target.projectId
              : row['project_id'] != target.projectId ||
                    iid is! int ||
                    iid <= 0 ||
                    iid != int.parse(spec.path.split('/').last))) {
        throw const Mr7Refused('snapshotIdentity');
      }
      rows.add(
        _Mr7SnapshotRow(
          spec: spec,
          id: id,
          iid: spec.path == root ? null : iid as int,
          digests: Map.unmodifiable({
            for (final field in spec.fields)
              field: _snapshotFieldDigest(row, field),
          }),
        ),
      );
    }
    await verifyIdentity();
    _open();
    return Mr7PreReadSnapshot._(
      target.userId,
      target.projectId,
      List.unmodifiable(rows),
    );
  }

  Future<void> _verifySnapshotBeforeSend(
    Mr7PreReadSnapshot snapshot,
    String path,
    Object? graphBody,
  ) async {
    final target = identity!;
    final root = 'projects/${target.projectId}';
    final actor = await read('user');
    if (snapshot.actorId != target.userId ||
        snapshot.projectId != target.projectId ||
        actor['id'] != target.userId ||
        actor['username'] != target.namespace) {
      stop('snapshotDrift');
      throw const Mr7Refused('snapshotDrift');
    }
    for (final saved in snapshot._rows) {
      final originalPath = saved.spec.path;
      if (originalPath != root &&
          path != originalPath &&
          !path.startsWith('$originalPath/') &&
          !(path == 'graphql' &&
              _graphSnapshotTargets(
                graphBody,
                _graphResources,
                originalPath,
              ))) {
        stop('snapshotDrift');
        throw const Mr7Refused('snapshotDrift');
      }
      final current = await read(originalPath);
      if (current['id'] != saved.id ||
          (saved.iid != null && current['iid'] != saved.iid) ||
          (originalPath != root && current['project_id'] != target.projectId) ||
          saved.spec.fields.any(
            (field) =>
                _snapshotFieldDigest(current, field) != saved.digests[field],
          )) {
        stop('snapshotDrift');
        throw const Mr7Refused('snapshotDrift');
      }
    }
    await verifyIdentity();
    _open();
  }

  Future<void> initialize() async {
    if (_started) throw const Mr7Refused('noResume');
    _started = true;
    try {
      if (expectedUserId <= 0 ||
          !RegExp(r'^[a-zA-Z0-9_-]{8,64}$').hasMatch(nonce) ||
          !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(namespace)) {
        throw const Mr7Refused('configuration');
      }
      final user = await read('user');
      if (user['id'] != expectedUserId || user['username'] != namespace) {
        throw const Mr7Refused('userIdentity');
      }
      final response = await observer.get<Object?>('namespaces');
      if (response.data is! List) throw const Mr7Refused('namespaceIdentity');
      final namespaces = (response.data! as List)
          .whereType<Map<Object?, Object?>>()
          .where(
            (r) =>
                r['full_path'] == namespace &&
                r['kind'] == 'user' &&
                r['owner_id'] == expectedUserId &&
                r['id'] is int,
          );
      if (namespaces.length != 1) throw const Mr7Refused('namespaceIdentity');
      _namespaceId = namespaces.single['id'] as int;
      windowStart = server.serverTime.subtract(const Duration(seconds: 2));
      await checkIsolation(baseline: true); // Before POST /projects.
      _setupAuthorized = true;
      final r = await writer.post<Object?>(
        'projects',
        data: {
          'name': 'mr7-$nonce',
          'path': 'mr7-$nonce',
          'namespace_id': _namespaceId,
          'visibility': 'private',
        },
      );
      _setupAuthorized = false;
      if (r.data is! Map || (r.data! as Map)['id'] is! int) {
        throw const Mr7Refused('setupIdentity');
      }
      _createdId = (r.data! as Map)['id'] as int;
      identity = Mr7Identity(
        projectId: _createdId!,
        path: '$namespace/mr7-$nonce',
        userId: expectedUserId,
        namespaceId: _namespaceId,
        namespace: namespace,
        nonce: nonce,
      );
      await verifyIdentity();
      await checkIsolation();
    } catch (e) {
      stop(e is Mr7Refused ? e.code : 'setupUnverified');
      rethrow;
    }
  }

  bool _identityMatches(Mr7Identity target) =>
      identical(target, identity) &&
      target.projectId == _createdId &&
      target.projectId > 0 &&
      target.projectId != mr7ProtectedProjectId &&
      target.path == '$namespace/mr7-$nonce' &&
      target.nonce == nonce &&
      target.namespace == namespace &&
      target.userId == expectedUserId &&
      target.namespaceId == _namespaceId;

  bool cleanupAllowed(Mr7Identity target) =>
      _identityMatches(target) &&
      !quarantined &&
      !inFlight &&
      pendingMutations == 0 &&
      boundaryValid();

  Future<void> verifyIdentity({bool observationOnly = false}) async {
    final expected = identity;
    if (!observationOnly) _open();
    if (expected == null || !_identityMatches(expected)) {
      stop('sandboxIdentity');
      throw const Mr7Refused('sandboxIdentity');
    }
    final byId = await read('projects/${expected.projectId}');
    final byPath = await read('projects/${Uri.encodeComponent(expected.path)}');
    for (final row in [byId, byPath]) {
      final owner = row['owner'];
      final ns = row['namespace'];
      if (row['id'] != expected.projectId ||
          row['path_with_namespace'] != expected.path ||
          row['visibility'] != 'private' ||
          row['archived'] != false ||
          row['mirror'] != false ||
          row['forked_from_project'] != null ||
          row['import_url'] != null ||
          owner is! Map ||
          owner['id'] != expected.userId ||
          ns is! Map ||
          ns['id'] != expected.namespaceId ||
          ns['kind'] != 'user' ||
          ns['full_path'] != expected.namespace) {
        stop('sandboxIdentity');
        throw const Mr7Refused('sandboxIdentity');
      }
    }
    if (!observationOnly) _open();
  }

  Future<void> beforeMutation(RequestOptions request) async {
    _open();
    final restPath = request.uri.pathSegments
        .skipWhile((s) => s != 'v4')
        .skip(1)
        .join('/');
    final graph = request.uri.path == '${instance.path}/api/graphql';
    final path = graph ? 'graphql' : restPath;
    String operation;
    if (_setupAuthorized &&
        identity == null &&
        server.setupWrites == 0 &&
        request.method == 'POST' &&
        path == 'projects') {
      final b = request.data;
      if (b is! Map ||
          b.length != 4 ||
          b['path'] != 'mr7-$nonce' ||
          b['name'] != 'mr7-$nonce' ||
          b['namespace_id'] != _namespaceId ||
          b['visibility'] != 'private') {
        throw const Mr7Refused('setupScope');
      }
      operation = 'harnessSetup';
    } else {
      await verifyIdentity();
      _open(); // Recheck after both awaited identity reads.
      final target = identity!;
      if (!graph &&
          !path.startsWith('projects/${target.projectId}/') &&
          path != 'projects/${target.projectId}') {
        stop('outsideSandbox');
        throw const Mr7Refused('outsideSandbox');
      }
      if (_cleanupAuthorized) {
        if (!_identityMatches(target) ||
            quarantined ||
            request.method != 'DELETE' ||
            path != 'projects/${target.projectId}') {
          throw const Mr7Refused('cleanupScope');
        }
        operation = 'harnessCleanup';
      } else {
        final allowed = permit;
        if (allowed != null &&
            !allowed.confirmed &&
            allowed.confirmBeforeSend != null) {
          allowed.confirmed = await allowed.confirmBeforeSend!();
          await verifyIdentity();
          _open();
        }
        if (allowed == null ||
            !allowed.confirmed ||
            (mr7ExcludedOperations.contains(allowed.operation) &&
                !allowsTodoFixture(allowed.operation)) ||
            allowed.operation.toLowerCase().contains('group') ||
            allowed.resourceProjectId != target.projectId ||
            !allowed.paths.contains('${request.method} $path') ||
            allowed.sent >= allowed.maxMutations ||
            (path == 'projects/${target.projectId}' &&
                !(allowed.operation == 'deleteProject' &&
                    request.method == 'DELETE') &&
                !(allowed.operation == 'editProject' &&
                    request.method == 'PUT'))) {
          stop('unconfirmedOrUnboundWrite');
          throw const Mr7Refused('unconfirmedOrUnboundWrite');
        }
        final b = request.data;
        if (graph &&
            (b is! Map ||
                b['query'] is! String ||
                _selectedGraphOperation(b)?.kind != 'mutation' ||
                !allowed.graphDocuments.contains(b['query']) ||
                !allowed.graphVariablesDigests.contains(
                  mr7Digest(b['variables']),
                ))) {
          stop('unsealedGraph');
          throw const Mr7Refused('unsealedGraph');
        }
        if (const {'snoozeTodo', 'unsnoozeTodo'}.contains(allowed.operation) &&
            (!graph ||
                b is! Map ||
                mr7Digest(b['query']) !=
                    (allowed.operation == 'snoozeTodo'
                        ? _todoSnoozeDocument
                        : _todoUnsnoozeDocument) ||
                b['variables'] is! Map ||
                (b['variables'] as Map)['id'] is! String ||
                !_graphResources.containsKey((b['variables'] as Map)['id']))) {
          stop('todoForeign');
          throw const Mr7Refused('todoForeign');
        }
        if (path.endsWith('/fork') ||
            path.contains('/transfer') ||
            (allowed.operation == 'editProject' &&
                (b is! Map ||
                    b.keys.any(
                      (key) => !const {'name', 'description'}.contains(key),
                    )))) {
          stop('externalSideEffect');
          throw const Mr7Refused('externalSideEffect');
        }
        if (allowed.operation == 'upload_attachment' &&
            (request.method != 'POST' ||
                path != 'projects/${target.projectId}/uploads')) {
          stop('uploadScope');
          throw const Mr7Refused('uploadScope');
        }
        if (allowed.snapshot case final snapshot?) {
          await _verifySnapshotBeforeSend(snapshot, path, graph ? b : null);
        }
        _requireBoundValues(
          graph && b is Map ? b['variables'] : b,
          graph: graph,
        );
        if (graph && b is Map) {
          _requireGraphTargets(b);
          await _refreshGraphResources(b['variables']);
          await verifyIdentity();
          _open();
        }
        if (allowed.operation == 'rebaseMergeRequest') {
          final segments = _restSegments(request);
          if (segments.length != 5 ||
              segments[2] != 'merge_requests' ||
              segments.last != 'rebase') {
            throw const Mr7Refused('observerRebaseTarget');
          }
          final parent = await read(segments.take(4).join('/'));
          if (parent['project_id'] != target.projectId ||
              parent['iid'] != int.tryParse(segments[3]) ||
              parent['sha'] is! String) {
            throw const Mr7Refused('observerRebaseTarget');
          }
          allowed._rebaseBeforeSha = parent['sha'] as String;
          await verifyIdentity();
          _open();
        }
        if (allowed.operation == 'createTodo') {
          final segments = _restSegments(request);
          if (request.method != 'POST' ||
              segments.length != 5 ||
              !const {'issues', 'merge_requests'}.contains(segments[2]) ||
              segments[4] != 'todo' ||
              !RegExp(r'^[1-9][0-9]*$').hasMatch(segments[3])) {
            stop('todoForeign');
            throw const Mr7Refused('todoForeign');
          }
          final actor = await read('user');
          final parent = await read(segments.take(4).join('/'));
          if (actor['id'] != target.userId ||
              actor['username'] != target.namespace ||
              parent['id'] is! int ||
              (parent['id'] as int) <= 0 ||
              parent['project_id'] != target.projectId ||
              parent['iid'] != int.parse(segments[3])) {
            stop('todoForeign');
            throw const Mr7Refused('todoForeign');
          }
          await verifyIdentity();
          _open();
        }
        operation = allowed.operation;
      }
    }
    chargeRequest();
    requestLedger.add({
      'method': request.method,
      'path': path,
      'operation': operation,
      'projectId': identity?.projectId ?? server.projectId,
      'at': server.serverTime.toIso8601String(),
    });
  }

  Future<void> checkIsolation({bool baseline = false}) async {
    try {
      final end = server.serverTime.add(const Duration(seconds: 2));
      final found = <int, Map<String, Object?>>{};
      var totalPages = 0;
      for (var pass = 0; pass < 2; pass++) {
        if (pass > 0) {
          await eventDelay().timeout(const Duration(seconds: 1));
        }
        var page = 1;
        final seen = <int>{};
        final eventIds = <int>{};
        final pagination = _PageSequence();
        while (true) {
          if (!seen.add(page) || seen.length > 20) {
            throw const Mr7Refused('eventsPagination');
          }
          final r = await observer.get<Object?>(
            'users/$expectedUserId/events',
            queryParameters: {
              'page': page,
              'per_page': 100,
              'after': windowStart!.toIso8601String().substring(0, 10),
              'before': end
                  .add(const Duration(days: 1))
                  .toIso8601String()
                  .substring(0, 10),
            },
          );
          totalPages++;
          final next = pagination.next(r, page);
          for (final raw in r.data! as List) {
            if (raw is! Map ||
                raw['id'] is! int ||
                (raw['id'] as int) <= 0 ||
                !eventIds.add(raw['id'] as int) ||
                raw['created_at'] is! String ||
                raw['action_name'] is! String ||
                !RegExp(
                  r'(Z|[+-]\d\d:\d\d)$',
                ).hasMatch(raw['created_at'] as String)) {
              throw const Mr7Refused('eventsMalformed');
            }
            final at = DateTime.tryParse(raw['created_at'] as String)?.toUtc();
            if (at == null) throw const Mr7Refused('eventsMalformed');
            if (at.isBefore(windowStart!) || at.isAfter(end)) continue;
            final row = <String, Object?>{
              'id': raw['id'],
              'at': at.toIso8601String(),
              'action':
                  const {
                    'created',
                    'updated',
                    'removed',
                    'commented',
                  }.contains(raw['action_name'])
                  ? raw['action_name']
                  : 'other',
              'projectId': raw['project_id'],
            };
            if (found[raw['id']] case final old?
                when jsonEncode(old) != jsonEncode(row)) {
              throw const Mr7Refused('eventsChanged');
            }
            found[raw['id'] as int] = row;
            if (raw['project_id'] is! int ||
                raw['project_id'] !=
                    (identity?.projectId ??
                        (baseline ? null : server.projectId))) {
              throw const Mr7Refused('eventsOutsideSandbox');
            }
          }
          if (next == null) break;
          page = next;
        }
      }
      observedEvents
        ..clear()
        ..addAll(found.values);
      windowEnd = end;
      isolation.addAll({
        'status': _isolationFailed ? 'NOT_VERIFIED' : 'PASS',
        'complete': !_isolationFailed,
        'pages': totalPages,
        'passes': 2,
      });
    } catch (e) {
      _isolationFailed = true;
      isolation.addAll({'status': 'NOT_VERIFIED', 'complete': false});
      stop(e is Mr7Refused ? e.code : 'eventsUnreadable');
      rethrow;
    }
  }

  Future<bool> _parentContainsProject(Mr7Identity target) async {
    final pagination = _PageSequence();
    final ids = <int>{};
    final projectPath = RegExp(
      '^${RegExp.escape(target.namespace)}/[A-Za-z0-9_][A-Za-z0-9_.-]*\$',
    );
    var page = 1;
    while (true) {
      final response = await observer.get<Object?>(
        'projects',
        queryParameters: {
          'namespace_id': target.namespaceId,
          'page': page,
          'per_page': 100,
        },
      );
      final next = pagination.next(response, page);
      for (final raw in response.data! as List) {
        if (raw is! Map ||
            raw['id'] is! int ||
            (raw['id'] as int) <= 0 ||
            !ids.add(raw['id'] as int) ||
            raw['namespace'] is! Map ||
            (raw['namespace'] as Map)['id'] is! int ||
            (raw['namespace'] as Map)['id'] != target.namespaceId ||
            raw['path_with_namespace'] is! String ||
            !projectPath.hasMatch(raw['path_with_namespace'] as String) ||
            (raw.containsKey('path') &&
                raw['path'] !=
                    (raw['path_with_namespace'] as String).split('/').last)) {
          throw const Mr7Refused('cleanupMalformed');
        }
      }
      if (next == null) return ids.contains(target.projectId);
      page = next;
    }
  }

  Future<void> finish({bool keep = false}) async {
    if (_finalizing) return;
    _finalizing = true;
    if (pendingMutations > 0 || inFlight) stop('writeUncertain');
    if (!boundaryValid()) stop('accountBoundary');
    if (keep) stop('ownerRetained');
    final target = identity;
    if (terminalDeletionAccepted) cleanup['reason'] = 'terminalScenario';
    if (target != null && !terminalDeletionAccepted && cleanupAllowed(target)) {
      try {
        await verifyIdentity();
        await checkIsolation();
        _cleanupAuthorized = true;
        final r = await writer.delete<Object?>('projects/${target.projectId}');
        _cleanupAuthorized = false;
        cleanup['accepted'] = r.statusCode == 202;
        final user = await read('user');
        final present = await _parentContainsProject(target);
        final lookup = await observer.get<Object?>(
          'projects/${target.projectId}',
        );
        final deleted =
            cleanup['accepted'] == true &&
            user['id'] == expectedUserId &&
            !present &&
            lookup.statusCode == 404;
        cleanup.addAll({
          'status': deleted ? 'PASS' : 'PENDING',
          'deletionVerified': deleted,
          'parentChecked': true,
          'identityChecked': user['id'] == expectedUserId,
        });
        if (!deleted) quarantined = true;
      } catch (e) {
        cleanup['status'] = 'NOT_VERIFIED';
        stop(e is Mr7Refused ? e.code : 'cleanupUnverified');
      }
    }
    _cleanupAuthorized = false;
    if (windowStart != null) {
      try {
        await checkIsolation();
      } catch (_) {
        /* Keep the original stop. */
      }
    }
    _finished = true;
    writer.close(force: true);
    observer.close(force: true);
  }

  Map<String, Object?> receipt({
    required Mr7Policy policy,
    required String releaseSha,
    required List<Map<String, Object?>> scenarios,
    required AiReleasePolicyView releasePolicy,
  }) => {
    'schema': 1,
    'status': stopReason == null ? 'PASS' : 'FAIL',
    'transport': 'synthetic',
    'policy': policy.name,
    'evidenceClass': policy == Mr7Policy.candidate
        ? 'CANDIDATE_ONLY'
        : 'SYNTHETIC',
    'finalEligible': false,
    'live': 'NOT_RUN',
    'releaseSha': releaseSha,
    'foreground': true,
    'background': false,
    'capabilityDigest': mr7Digest(releasePolicy.canonicalIdentity),
    'identity': identity == null
        ? null
        : {
            'projectId': identity!.projectId,
            'pathDigest': mr7Digest(identity!.path),
            'ownerId': identity!.userId,
            'namespaceId': identity!.namespaceId,
            'instanceDigest': mr7Digest(instance.toString()),
            'nonceDigest': mr7Digest(nonce),
          },
    'events': {
      ...isolation,
      'start': windowStart?.toIso8601String(),
      'end': windowEnd?.toIso8601String(),
      'items': observedEvents,
    },
    'requestLedger': requestLedger,
    'requestCount': _httpRequests,
    'scenarios': scenarios,
    'stoppedCount': scenarios.where((s) => s['status'] == 'NOT_RUN').length,
    'cleanup': {...cleanup},
    'quarantined': quarantined,
    if (stopReason != null) 'stopReason': stopReason,
    'limitations': [
      'synthetic transport only',
      'events are not a complete audit log',
      'host confirmation is not app UI evidence',
    ],
  };
}
