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

const _observerDeadlineKey = #mr7ObserverDeadline;

/// One budget covers identity checks, response bodies and every pagination page.
/// A zone keeps concurrent observations' cancellation tokens independent.
final class _Mr7ObserverDeadline {
  _Mr7ObserverDeadline(this.timeout);
  final Duration timeout;
  final token = CancelToken();
  final watch = Stopwatch()..start();
  bool active = true;
  bool expired = false;

  Duration get remaining => timeout - watch.elapsed;

  void check() {
    if (!active || expired || remaining <= Duration.zero) {
      throw const Mr7Refused('observerTimeout');
    }
  }

  Future<T> run<T>(Future<T> Function() action) async {
    final expiry = Completer<T>();
    final timer = Timer(remaining, () {
      expired = true;
      token.cancel('observerTimeout');
      expiry.completeError(const Mr7Refused('observerTimeout'));
    });
    try {
      final value = await Future.any([
        runZoned(action, zoneValues: {_observerDeadlineKey: this}),
        expiry.future,
      ]);
      check();
      return value;
    } catch (error) {
      if (expired ||
          remaining <= Duration.zero ||
          (error is DioException &&
              error.type == DioExceptionType.receiveTimeout)) {
        expired = true;
        token.cancel('observerTimeout');
        throw const Mr7Refused('observerTimeout');
      }
      rethrow;
    } finally {
      active = false;
      timer.cancel();
    }
  }
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

Future<Map<String, Object?>> _effectMap(
  Dio dio,
  String path, {
  Map<String, Object?> query = const {},
}) async {
  final response = await dio.get<Object?>(path, queryParameters: query);
  if (response.statusCode != 200 ||
      response.data is! Map ||
      utf8.encode(jsonEncode(response.data)).length > 2 * 1024 * 1024) {
    throw const Mr7Refused('observerUnreadable');
  }
  return Map<String, Object?>.from(response.data! as Map);
}

Future<List<Map<String, Object?>>> _effectRows(
  Dio dio,
  String path, {
  Map<String, Object?> query = const {},
  String key = 'id',
  bool stringIds = false,
}) async {
  final sequence = _PageSequence();
  final rows = <Map<String, Object?>>[];
  final ids = <Object>{};
  var page = 1;
  while (true) {
    final response = await dio.get<Object?>(
      path,
      queryParameters: {...query, 'page': page, 'per_page': 100},
    );
    if (utf8.encode(jsonEncode(response.data)).length > 2 * 1024 * 1024) {
      throw const Mr7Refused('observerUnreadable');
    }
    final next = sequence.next(response, page);
    for (final raw in response.data! as List) {
      final id = raw is Map ? raw[key] : null;
      if (raw is! Map ||
          !(stringIds ? id is String && id.isNotEmpty : id is int && id > 0) ||
          !ids.add(id! as Object)) {
        throw const Mr7Refused('observerList');
      }
      rows.add(Map<String, Object?>.from(raw));
    }
    if (next == null) return rows;
    page = next;
  }
}

Map<String, Object?> _suggestionIn(
  Map<String, Object?> discussion,
  String discussionId,
  int noteId,
  int suggestionId,
) {
  final notes = discussion['notes'];
  if (discussion['id'] != discussionId || notes is! List) {
    throw const Mr7Refused('observerDiscussion');
  }
  final matching = notes
      .whereType<Map<Object?, Object?>>()
      .where((n) => n['id'] == noteId)
      .toList();
  if (matching.length != 1 || matching.single['suggestions'] is! List) {
    throw const Mr7Refused('observerDiscussion');
  }
  final suggestions = (matching.single['suggestions'] as List)
      .whereType<Map<Object?, Object?>>()
      .where((s) => s['id'] == suggestionId)
      .toList();
  final position = matching.single['position'];
  if (suggestions.length != 1 ||
      position is! Map ||
      position['position_type'] != 'text') {
    throw const Mr7Refused('observerDiscussion');
  }
  return {
    'suggestion': Map<String, Object?>.from(suggestions.single),
    'position': Map<String, Object?>.from(position),
  };
}

Future<List<Map<String, Object?>>> _publicNotes(
  Dio dio,
  String parent,
  int parentId,
) async {
  final notes = await _effectRows(dio, '$parent/notes');
  final discussions = await _effectRows(
    dio,
    '$parent/discussions',
    stringIds: true,
  );
  final byId = <int, Map<String, Object?>>{};
  void add(Map<String, Object?> note, String? discussion) {
    final id = note['id'];
    final author = note['author'];
    if (id is! int ||
        id <= 0 ||
        author is! Map ||
        author['id'] is! int ||
        note['body'] is! String ||
        note['system'] is! bool ||
        (note.containsKey('noteable_id') && note['noteable_id'] != parentId)) {
      throw const Mr7Refused('observerPublishedNote');
    }
    final row = {...note, '_discussion': discussion};
    final previous = byId[id];
    if (previous != null &&
        (previous['body'] != note['body'] ||
            mr7Digest(previous['author']) != mr7Digest(author) ||
            (previous['_discussion'] != null &&
                previous['_discussion'] != discussion))) {
      throw const Mr7Refused('observerPublishedNote');
    }
    byId[id] = row;
  }

  for (final note in notes) {
    add(note, null);
  }
  for (final discussion in discussions) {
    final children = discussion['notes'];
    if (discussion['id'] is! String ||
        children is! List ||
        children.isEmpty ||
        children.length > 2000) {
      throw const Mr7Refused('observerDiscussion');
    }
    final seen = <int>{};
    for (final child in children) {
      if (child is! Map ||
          child['id'] is! int ||
          !seen.add(child['id'] as int)) {
        throw const Mr7Refused('observerDiscussion');
      }
      add(Map<String, Object?>.from(child), discussion['id'] as String);
    }
  }
  return byId.values.toList();
}

bool _draftPositionSupported(Object? position) {
  if (position == null) return true;
  if (position is! Map ||
      position['position_type'] != 'text' ||
      position['line_range'] != null) {
    return false;
  }
  for (final key in ['base_sha', 'start_sha', 'head_sha']) {
    if (position[key] is! String ||
        !RegExp(
          r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$',
        ).hasMatch(position[key] as String)) {
      return false;
    }
  }
  for (final key in ['old_path', 'new_path']) {
    if (position[key] is! String || (position[key] as String).isEmpty) {
      return false;
    }
  }
  for (final key in ['old_line', 'new_line']) {
    if (position[key] != null &&
        (position[key] is! int || (position[key] as int) <= 0)) {
      return false;
    }
  }
  return position['old_line'] != null || position['new_line'] != null;
}

bool _draftPositionMatches(Object? draft, Object? published) {
  if (draft == null) return published == null;
  if (draft is! Map ||
      published is! Map ||
      !_draftPositionSupported(draft) ||
      !_draftPositionSupported(published)) {
    return false;
  }
  return const [
    'position_type',
    'base_sha',
    'start_sha',
    'head_sha',
    'old_path',
    'new_path',
    'old_line',
    'new_line',
  ].every((key) => draft[key] == published[key]);
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
    if (key == 'GET projects/$projectId/todos/mr7-observation') {
      final page = int.parse('${request.queryParameters['page'] ?? 1}');
      final rows = [
        for (final todo in _todos.values)
          {
            'id': todo.id,
            'actor_id': todo.actorId,
            'author': {'id': todo.actorId},
            'project_id': todo.projectId,
            'target_type': todo.mergeRequest ? 'MergeRequest' : 'Issue',
            'target_id': todo.parentId,
            'target_iid': todo.iid,
            'state': 'pending',
          },
      ];
      return mr7Json(
        rows.skip((page - 1) * 100).take(100).toList(),
        headers: _pageHeaders(page, 100, rows.length),
      );
    }
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
  String projectPath,
) {
  final operation = _selectedGraphOperation(body);
  if (operation?.kind != 'mutation' ||
      operation!.roots.length != 1 ||
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
  try {
    final root = operation.roots.single;
    final arguments = operation.resolve(
      root.arguments,
      body['variables'] as Map,
    );
    final input = (arguments as Map)['input'];
    if (root.field == 'issueSetEscalationStatus') {
      return input is Map &&
          input['projectPath'] == projectPath &&
          input['iid'] is String &&
          RegExp(r'^[1-9][0-9]*$').hasMatch(input['iid'] as String) &&
          path.endsWith('/issues/${input['iid']}');
    }
    // These selectors match the product mutation documents. Ordinary text and
    // other arguments cannot establish which resource the mutation changes.
    final selector = switch (root.field) {
      'workItemUpdate' ||
      'workItemSubscribe' ||
      'updateNote' ||
      'destroyNote' ||
      'todoSnooze' ||
      'todoUnSnooze' => 'id',
      'createNote' => 'noteableId',
      'awardEmojiAdd' || 'awardEmojiRemove' => 'awardableId',
      _ => null,
    };
    if (selector == null) return false;
    return input is Map &&
        input[selector] is String &&
        gids.contains(input[selector]);
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
    final deadline =
        Zone.current[_observerDeadlineKey] as _Mr7ObserverDeadline?;
    deadline?.check();
    beforeRequest?.call();
    requests.add(options.uri.path);
    Future<ResponseBody> respond() async {
      final response = await server.respond(options);
      if (options.cancelToken?.isCancelled == true) {
        await response.stream.listen(null).cancel();
        throw options.cancelToken!.cancelError!;
      }
      deadline?.check();
      return response;
    }

    final response = await Future.any([
      respond(),
      if (cancelFuture != null)
        cancelFuture.then<ResponseBody>(
          (_) =>
              throw options.cancelToken?.cancelError ??
                  const Mr7Refused('observerCancelled'),
        ),
    ]);
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
    this.scenarioId,
    this.maxMutations = 1,
    this.graphDocuments = const {},
    this.graphVariablesDigests = const {},
    this.resultPath = const [],
    this.captureEffects = false,
    Object? callArguments,
  }) : callArguments = callArguments is Map
           ? _mr7FrozenJson(callArguments) as Map<String, Object?>
           : null;
  final String operation;
  final String? scenarioId;
  final Set<String> paths;
  final int resourceProjectId;
  final int maxMutations;
  final Set<String> graphDocuments;
  final Set<String> graphVariablesDigests;
  final List<String> resultPath;
  final bool captureEffects;
  // The runner captures the actual tool call before preparation or dispatch.
  final Map<String, Object?>? callArguments;
  Map<String, Object?> Function()? _preparedArguments;

  // Keep the production preparation itself: approval edits rebind its request.
  void capturePreparedArguments(Map<String, Object?> Function() arguments) =>
      _preparedArguments = arguments;

  Map<String, Object?>? get preparedArguments => _preparedArguments == null
      ? null
      : _mr7FrozenJson(_preparedArguments!()) as Map<String, Object?>;

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
  int? _todoParentId;
  Set<int>? _todoIdsBefore;
  String? _ownedActivityNoteAtSend;
  final Map<String, int> _preparedParentIds = {};
  ({String id, String parentPath})? _preparedActivityNote;
  final List<_Mr7Dispatch> _dispatches = [];
  Map<String, Object?>? _effectBefore;
}

/// Captured at the guarded transport, never supplied by a scenario observer.
final class _Mr7Dispatch {
  const _Mr7Dispatch(this.method, this.path, this.at, this.status);
  final String method;
  final String path;
  final DateTime at;
  final int status;
}

enum Mr7SnapshotKind { parent, board, milestone, label, draftNote, workItem }

/// Fields are represented by digests in receipts; field presence is bound too.
final class Mr7SnapshotSpec {
  Mr7SnapshotSpec({
    required String path,
    required Set<String> fields,
    Set<String> unchangedFields = const {},
  }) : this._(
         path: path,
         fields: fields,
         unchangedFields: unchangedFields,
         kind: Mr7SnapshotKind.parent,
       );
  Mr7SnapshotSpec.board({
    required String path,
    Set<String> unchangedFields = const {},
  }) : this._(
         path: path,
         kind: Mr7SnapshotKind.board,
         fields: {'name', 'hide_backlog_list', 'hide_closed_list'},
         unchangedFields: unchangedFields,
       );
  Mr7SnapshotSpec.milestone({
    required String path,
    Set<String> unchangedFields = const {},
  }) : this._(
         path: path,
         kind: Mr7SnapshotKind.milestone,
         fields: {'title', 'description', 'start_date', 'due_date', 'state'},
         unchangedFields: unchangedFields,
       );
  Mr7SnapshotSpec.label({
    required String path,
    Set<String> unchangedFields = const {},
  }) : this._(
         path: path,
         kind: Mr7SnapshotKind.label,
         fields: {'name', 'color', 'description'},
         unchangedFields: unchangedFields,
       );
  Mr7SnapshotSpec.draftNote({
    required String path,
    Set<String> unchangedFields = const {},
  }) : this._(
         path: path,
         kind: Mr7SnapshotKind.draftNote,
         fields: {'note', 'body', 'position', 'commit_id', 'author_id'},
         unchangedFields: unchangedFields,
       );
  Mr7SnapshotSpec.workItem({
    required String path,
    required String workItemId,
    Set<String> fields = _mr7WorkItemFields,
    Set<String> unchangedFields = const {},
  }) : this._(
         path: path,
         kind: Mr7SnapshotKind.workItem,
         workItemId: workItemId,
         fields: fields,
         unchangedFields: unchangedFields,
       );
  Mr7SnapshotSpec._({
    required this.path,
    required Set<String> fields,
    required Set<String> unchangedFields,
    required this.kind,
    this.workItemId,
  }) : fields = Set.unmodifiable(fields),
       unchangedFields = Set.unmodifiable(unchangedFields);
  final String path;
  final Set<String> fields;
  final Set<String> unchangedFields;
  final Mr7SnapshotKind kind;
  final String? workItemId;

  bool _allowsPath(String root) => switch (kind) {
    Mr7SnapshotKind.parent =>
      path == root ||
          RegExp('^$root/(issues|merge_requests)/[1-9][0-9]*\$').hasMatch(path),
    Mr7SnapshotKind.board => RegExp(
      '^$root/boards/[1-9][0-9]*\$',
    ).hasMatch(path),
    Mr7SnapshotKind.milestone => RegExp(
      '^$root/milestones/[1-9][0-9]*\$',
    ).hasMatch(path),
    Mr7SnapshotKind.label => RegExp(
      '^$root/labels/[1-9][0-9]*\$',
    ).hasMatch(path),
    Mr7SnapshotKind.draftNote => RegExp(
      '^$root/merge_requests/[1-9][0-9]*/draft_notes/[1-9][0-9]*\$',
    ).hasMatch(path),
    Mr7SnapshotKind.workItem => RegExp(
      '^$root/issues/[1-9][0-9]*\$',
    ).hasMatch(path),
  };
}

final class _Mr7SnapshotRow {
  _Mr7SnapshotRow({
    required this.spec,
    required this.id,
    required this.iid,
    required this.digests,
    required this.presentFields,
    required this.identityDigests,
    this.parentId,
    this.values = const {},
  });
  final Mr7SnapshotSpec spec;
  final int id;
  final int? iid;
  final Map<String, String> digests;
  final Set<String> presentFields;
  final Map<String, String> identityDigests;
  final int? parentId;
  final Map<String, Object?> values;
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
          'kind': row.spec.kind.name,
          'id': row.id,
          if (row.iid != null) 'iid': row.iid,
          if (row.parentId != null) 'parentId': row.parentId,
          'identityDigests': row.identityDigests,
          'fieldDigests': row.digests,
          'unchangedFields': row.spec.unchangedFields.toList()..sort(),
          if (row.spec.kind != Mr7SnapshotKind.parent)
            'preserveOmittedFields': true,
        },
    ],
  };
}

String _snapshotFieldDigest(Map<String, Object?> row, String field) =>
    mr7Digest({'present': row.containsKey(field), 'value': row[field]});

Set<String> _snapshotPreservedFields(_Mr7SnapshotRow saved, Object? sentBody) {
  if (saved.spec.kind == Mr7SnapshotKind.parent) {
    return saved.spec.unchangedFields;
  }
  if (sentBody is! Map) throw const Mr7Refused('snapshotTarget');
  if (saved.spec.kind == Mr7SnapshotKind.workItem) {
    final operation = _selectedGraphOperation(sentBody);
    if (operation == null || operation.roots.length != 1) {
      throw const Mr7Refused('snapshotTarget');
    }
    final input = _mr7MutationInput(sentBody, operation.roots.single.field);
    final changed = <String>{};
    for (final key in input.keys) {
      switch (key) {
        case 'title':
          changed.add('title');
        case 'stateEvent':
          changed.add('state');
        case 'descriptionWidget':
          changed.add('description');
        case 'statusWidget':
          changed.add('status');
        case 'assigneesWidget':
          changed.add('assignees');
        case 'milestoneWidget':
          changed.add('milestone');
        case 'labelsWidget':
          changed.add('labels');
        case 'subscribed':
          changed.add('subscribed');
        case 'startAndDueDateWidget':
          final dates = input[key];
          if (dates is! Map) throw const Mr7Refused('snapshotTarget');
          changed.addAll(dates.keys.cast<String>());
          if (dates.containsKey('isFixed')) {
            changed.addAll({
              'startDate',
              'dueDate',
              'startDateSourcingWorkItem',
              'dueDateSourcingWorkItem',
              'startDateSourcingMilestone',
              'dueDateSourcingMilestone',
            });
          }
      }
    }
    return {
      ...saved.spec.unchangedFields,
      ...saved.spec.fields.where((f) => !changed.contains(f)),
    };
  }
  final changed = sentBody.keys.toSet();
  if (saved.spec.kind == Mr7SnapshotKind.milestone &&
      changed.contains('state_event')) {
    changed.add('state');
  }
  if (saved.spec.kind == Mr7SnapshotKind.label &&
      changed.contains('new_name')) {
    changed.add('name');
  }
  if (saved.spec.kind == Mr7SnapshotKind.draftNote &&
      changed.contains('note')) {
    changed.add('body');
  }
  return {
    ...saved.spec.unchangedFields,
    ...saved.spec.fields.where((field) => !changed.contains(field)),
  };
}

bool _snapshotResourceIdentityMatches(
  Mr7SnapshotSpec spec,
  Map<String, Object?> row,
  Mr7Identity identity, {
  int? parentId,
}) {
  final root = 'projects/${identity.projectId}';
  final id = row['id'];
  final iid = row['iid'];
  final iidRoute =
      (spec.kind == Mr7SnapshotKind.parent ||
          spec.kind == Mr7SnapshotKind.workItem) &&
      spec.path != root;
  if (!spec._allowsPath(root) ||
      id is! int ||
      id <= 0 ||
      (spec.path == root
          ? id != identity.projectId
          : (iidRoute ? iid : id) != int.parse(spec.path.split('/').last)) ||
      ((iidRoute ||
              spec.kind == Mr7SnapshotKind.milestone ||
              row.containsKey('iid')) &&
          (iid is! int || iid <= 0)) ||
      (row.containsKey('project_id') &&
          row['project_id'] != identity.projectId)) {
    return false;
  }
  return switch (spec.kind) {
    Mr7SnapshotKind.parent =>
      spec.path == root || row['project_id'] == identity.projectId,
    Mr7SnapshotKind.milestone => row['project_id'] == identity.projectId,
    Mr7SnapshotKind.board =>
      row['project'] is Map &&
          (row['project'] as Map)['id'] == identity.projectId,
    Mr7SnapshotKind.label => row['is_project_label'] == true,
    Mr7SnapshotKind.draftNote =>
      row['author_id'] == identity.userId &&
          parentId != null &&
          row['merge_request_id'] == parentId,
    Mr7SnapshotKind.workItem =>
      row['project_id'] == identity.projectId &&
          spec.workItemId == 'gid://gitlab/WorkItem/$id',
  };
}

bool _snapshotIdentityMatches(
  _Mr7SnapshotRow saved,
  Map<String, Object?> row,
  Mr7Identity identity,
) =>
    row['id'] == saved.id &&
    _snapshotResourceIdentityMatches(
      saved.spec,
      row,
      identity,
      parentId: saved.parentId,
    ) &&
    saved.identityDigests.entries.every(
      (e) => _snapshotFieldDigest(row, e.key) == e.value,
    );

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

final class Mr7DeletedFileObservation extends Mr7Observation<bool> {
  const Mr7DeletedFileObservation({
    required this.path,
    required this.ref,
    required this.sha,
  });
  final String path;
  final String ref;
  final String sha;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._deletedFile(this);
}

final class Mr7SuggestionObservation extends Mr7Observation<bool> {
  Mr7SuggestionObservation({
    required this.parent,
    required this.discussionId,
    required this.noteId,
    required this.suggestionId,
    required this.path,
    required this.ref,
    required this.sha,
    required this.blobSha,
    required List<int> bytes,
  }) : bytes = List.unmodifiable(bytes);
  final Mr7Parent parent;
  final String discussionId;
  final int noteId;
  final int suggestionId;
  final String path;
  final String ref;
  final String sha;
  final String blobSha;
  final List<int> bytes;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._suggestion(this);
}

final class Mr7DeletedBoardListObservation extends Mr7Observation<bool> {
  const Mr7DeletedBoardListObservation({
    required this.boardId,
    required this.listId,
  });
  final int boardId;
  final int listId;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._deletedBoardList(this);
}

final class Mr7PublishedDraftsObservation extends Mr7Observation<bool> {
  Mr7PublishedDraftsObservation({
    required this.parent,
    required Map<int, String> drafts,
  }) : drafts = Map.unmodifiable(drafts);
  final Mr7Parent parent;
  final Map<int, String> drafts;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._publishedDrafts(this);
}

final class Mr7SchedulePipelineObservation
    extends Mr7Observation<Map<String, Object?>> {
  const Mr7SchedulePipelineObservation({
    required this.scheduleId,
    required this.ref,
    required this.pipelineId,
    this.maxAttempts = 3,
    this.interval = Duration.zero,
    this.timeout = const Duration(seconds: 2),
  });
  final int scheduleId;
  final String ref;
  final int pipelineId;
  final int maxAttempts;
  final Duration interval;
  final Duration timeout;
  @override
  Future<Map<String, Object?>> _read(Mr7Readback observer) =>
      observer._schedulePipeline(this);
}

final class Mr7LegacyCancelObservation extends Mr7Observation<bool> {
  const Mr7LegacyCancelObservation({required this.parent});
  final Mr7Parent parent;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._legacyCancel(this);
}

final class Mr7ProjectDeletionObservation extends Mr7Observation<bool> {
  const Mr7ProjectDeletionObservation();
  @override
  Future<bool> _read(Mr7Readback observer) => observer._projectDeletion();
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
    this.visibility = 'private',
  }) : files = Map.unmodifiable(files);
  final int id;
  final String revision;
  final String visibility;
  final Map<String, Mr7SnippetFile> files;
  @override
  Future<Map<String, List<int>>> _read(Mr7Readback observer) =>
      observer._snippet(this);
}

/// Only these sealed witnesses may prove a zero-dispatch core no-op.
sealed class Mr7StateObservation extends Mr7Observation<bool> {
  const Mr7StateObservation();
  bool matchesCall(String operation, Object? arguments, int projectId);
}

const _mr7WorkItemOperations = {
  'updateWorkItemState',
  'updateWorkItemStatus',
  'updateWorkItemDates',
  'updateWorkItemAssignees',
  'updateWorkItemMilestone',
  'updateWorkItemContent',
  'updateWorkItemLabels',
  'setWorkItemNotifications',
  'setIncidentStatus',
};

/// Arguments are the production tool arguments, including projectId/iid.
/// Effects are also compared with the resolved input of the actual dispatch.
final class Mr7WorkItemObservation extends Mr7StateObservation {
  Mr7WorkItemObservation({
    required this.workItemId,
    required this.iid,
    required this.operation,
    required Map<String, Object?> arguments,
    this.milestoneState,
    this.milestoneExpired,
  }) : arguments =
           _mr7FrozenJson({...arguments}..remove('reason'))
               as Map<String, Object?>;
  final String workItemId;
  final int iid;
  final String operation;
  final Map<String, Object?> arguments;
  final String? milestoneState;
  final bool? milestoneExpired;

  @override
  bool matchesCall(String op, Object? value, int projectId) =>
      _mr7WorkItemOperations.contains(operation) &&
      op == operation &&
      iid > 0 &&
      arguments['projectId'] == projectId &&
      arguments['iid'] == iid &&
      // The coordinator excludes model justification from the port request.
      _mr7SameJson(
        arguments,
        value is Map ? ({...value}..remove('reason')) : value,
      );

  @override
  Future<bool> _read(Mr7Readback observer) => observer._workItemEffect(this);
}

Object? _mr7FrozenJson(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _mr7FrozenJson(entry.value),
  }),
  List() => List<Object?>.unmodifiable(value.map(_mr7FrozenJson)),
  _ => value,
};

bool _mr7SameJson(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.entries.every(
          (e) =>
              right.containsKey(e.key) && _mr7SameJson(e.value, right[e.key]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(
          left.length,
          (i) => i,
        ).every((i) => _mr7SameJson(left[i], right[i]));
  }
  return left == right;
}

Map<String, Object?> _mr7MutationInput(Object? body, String root) {
  final operation = _selectedGraphOperation(body);
  if (body is! Map ||
      operation?.kind != 'mutation' ||
      operation!.roots.length != 1 ||
      operation.roots.single.field != root) {
    throw const Mr7Refused('observerMutationTarget');
  }
  final args = operation.resolve(
    operation.roots.single.arguments,
    body['variables'] as Map? ?? const {},
  );
  final input = args is Map ? args['input'] : null;
  if (input is! Map) throw const Mr7Refused('observerMutationTarget');
  return Map<String, Object?>.from(input);
}

bool _mr7Date(Object? value) {
  if (value == null) return true;
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return false;
  }
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.toIso8601String().startsWith(value);
}

const _mr7WorkItemFields = {
  'state',
  'title',
  'description',
  'status',
  'startDate',
  'dueDate',
  'rollUp',
  'isFixed',
  'startDateSourcingWorkItem',
  'dueDateSourcingWorkItem',
  'startDateSourcingMilestone',
  'dueDateSourcingMilestone',
  'assignees',
  'milestone',
  'labels',
  'subscribed',
};

// All selections below intersect the production documents and GitLab schema.
const _mr7WidgetSelections = {
  'DESCRIPTION': '... on WorkItemWidgetDescription { description }',
  'STATUS': '... on WorkItemWidgetStatus { status { id } }',
  'ASSIGNEES': '''... on WorkItemWidgetAssignees {
    assignees(first: 100, after: \$after) {
      nodes { id name username } pageInfo { hasNextPage endCursor }
    }
  }''',
  'MILESTONE': '''... on WorkItemWidgetMilestone {
    milestone { id iid title state expired dueDate startDate webPath
      project { id fullPath } }
  }''',
  'LABELS': '''... on WorkItemWidgetLabels {
    labels(first: 100, after: \$after) {
      nodes { id title color textColor } pageInfo { hasNextPage endCursor }
    }
  }''',
  'NOTIFICATIONS': '... on WorkItemWidgetNotifications { subscribed }',
};

String _mr7WidgetType(String field) => switch (field) {
  'description' => 'DESCRIPTION',
  'status' => 'STATUS',
  'assignees' => 'ASSIGNEES',
  'milestone' => 'MILESTONE',
  'labels' => 'LABELS',
  'subscribed' => 'NOTIFICATIONS',
  _ => 'START_AND_DUE_DATE',
};

String _mr7WorkItemPath(
  Mr7SandboxSession session,
  Mr7Identity identity,
  String id,
) {
  final path = session._graphResources[id];
  if (!RegExp(r'^gid://gitlab/WorkItem/[1-9][0-9]*$').hasMatch(id) ||
      path == null ||
      !RegExp(
        '^projects/${identity.projectId}/issues/[1-9][0-9]*\$',
      ).hasMatch(path)) {
    throw const Mr7Refused('observerParent');
  }
  return path;
}

void _mr7WorkItemRecord(
  Mr7SandboxSession session,
  Mr7Identity identity,
  String id,
  Map<String, Object?> record,
) {
  final path = _mr7WorkItemPath(session, identity, id);
  final project = record['project'];
  if (record['id'] != id ||
      record['iid'] != path.split('/').last ||
      project is! Map ||
      project['id'] != 'gid://gitlab/Project/${identity.projectId}' ||
      project['fullPath'] != identity.path) {
    throw const Mr7Refused('readbackIdentity');
  }
}

const _mr7CeDateFields = {
  'isFixed',
  'startDateSourcingWorkItem',
  'dueDateSourcingWorkItem',
  'startDateSourcingMilestone',
  'dueDateSourcingMilestone',
};

final class _Mr7CeDates implements Exception {
  const _Mr7CeDates();
}

// The same precise CE schema signal used by production. Permission, transport,
// partial-data and unrelated schema errors never authorize a weaker witness.
bool _mr7PreciseCeDatesErrors(Object? errors) {
  if (errors is! List || errors.isEmpty) return false;
  final seen = <String>{};
  for (final error in errors) {
    final details = error is Map ? error['extensions'] : null;
    if (details is! Map ||
        details['code'] != 'undefinedField' ||
        details['typeName'] != 'WorkItemWidgetStartAndDueDate' ||
        !_mr7CeDateFields.contains(details['fieldName']) ||
        !seen.add(details['fieldName'] as String)) {
      return false;
    }
  }
  return seen.contains('isFixed');
}

Future<Map<String, Object?>> _mr7SealedQuery(
  Mr7SandboxSession session,
  Mr7Identity identity,
  String document,
  Map<String, Object?> variables, {
  bool probeDates = false,
}) async {
  // Only private callers supply these fixed documents and exact continuations.
  session.observerAdapter.graphReadDocuments = Map.unmodifiable({
    ...session.observerAdapter.graphReadDocuments,
    document: Set<String>.unmodifiable({
      ...?session.observerAdapter.graphReadDocuments[document],
      mr7Digest(variables),
    }),
  });
  final response = await session.observer.post<Object?>(
    '${session.instance}/api/graphql',
    data: {'query': document, 'variables': variables},
  );
  final envelope = response.data;
  if (jsonEncode(envelope).length > 2 * 1024 * 1024) {
    throw const Mr7Refused('observerUnreadable');
  }
  final errors = envelope is Map ? envelope['errors'] : null;
  final data = envelope is Map ? envelope['data'] : null;
  final actor = data is Map ? data['currentUser'] : null;
  if (response.statusCode == 200 &&
      probeDates &&
      data == null &&
      _mr7PreciseCeDatesErrors(errors)) {
    throw const _Mr7CeDates();
  }
  if (response.statusCode != 200 ||
      envelope is! Map ||
      (errors != null && (errors is! List || errors.isNotEmpty)) ||
      data is! Map ||
      actor is! Map ||
      actor['id'] != 'gid://gitlab/User/${identity.userId}') {
    throw const Mr7Refused('readbackIdentity');
  }
  return Map<String, Object?>.from(data);
}

/// Internal projection names are real response fields; connections are stored
/// as sorted complete node lists. No totalCount or invented widget fields.
Future<Map<String, Object?>> _mr7ReadWorkItem(
  Mr7SandboxSession session,
  Mr7Identity identity,
  String id,
  Set<String> fields,
) async {
  if (fields.isEmpty || !fields.every(_mr7WorkItemFields.contains)) {
    throw const Mr7Refused('observerWidget');
  }
  final groups = <String, Set<String>>{};
  for (final field in fields.where((f) => f != 'title' && f != 'state')) {
    groups.putIfAbsent(_mr7WidgetType(field), () => {}).add(field);
  }
  if (groups.isEmpty) groups[''] = {};
  final projection = <String, Object?>{};
  String? revision;
  for (final group in groups.entries) {
    final type = group.key;
    final connected = type == 'ASSIGNEES' || type == 'LABELS';
    final connectionField = type == 'ASSIGNEES' ? 'assignees' : 'labels';
    final selectedFields = {...group.value};
    String document() {
      final selection = type == 'START_AND_DUE_DATE'
          ? '... on WorkItemWidgetStartAndDueDate { ${((selectedFields.toList())..sort()).map((f) => f.endsWith('WorkItem') || f.endsWith('Milestone') ? '$f { id }' : f).join(' ')} }'
          : _mr7WidgetSelections[type];
      return 'query Mr7Widget(\$id: WorkItemID!${connected ? ', \$after: String' : ''}) { '
          'currentUser { id } workItem(id: \$id) { '
          'id iid title state updatedAt project { id fullPath } '
          '${type.isEmpty ? '' : 'widgets(onlyTypes: [$type]) { type $selection }'} } }';
    }

    final cursors = <String>{};
    final nodeIds = <String>{};
    final nodes = <Map<String, Object?>>[];
    String? after;
    var complete = false;
    for (var page = 0; page < 20; page++) {
      final variables = <String, Object?>{
        'id': id,
        if (connected) 'after': after,
      };
      Map<String, Object?> data;
      try {
        data = await _mr7SealedQuery(
          session,
          identity,
          document(),
          variables,
          probeDates:
              type == 'START_AND_DUE_DATE' &&
              selectedFields.contains('isFixed'),
        );
      } on _Mr7CeDates {
        selectedFields.removeAll(_mr7CeDateFields);
        data = await _mr7SealedQuery(session, identity, document(), variables);
      }
      final raw = data['workItem'];
      if (raw is! Map) throw const Mr7Refused('readbackIdentity');
      final row = Map<String, Object?>.from(raw);
      _mr7WorkItemRecord(session, identity, id, row);
      if (row['updatedAt'] is! String ||
          DateTime.tryParse(row['updatedAt'] as String) == null ||
          (revision != null && revision != row['updatedAt'])) {
        throw const Mr7Refused('observerRevision');
      }
      revision = row['updatedAt'] as String;
      for (final field in ['title', 'state']) {
        if (fields.contains(field)) {
          if (row[field] is! String ||
              (projection.containsKey(field) &&
                  projection[field] != row[field])) {
            throw const Mr7Refused('observerRevision');
          }
          projection[field] = row[field];
        }
      }
      if (type.isEmpty) {
        complete = true;
        break;
      }
      final widgets = row['widgets'];
      if (widgets is! List ||
          widgets.length > 32 ||
          widgets.any((w) => w is! Map || w['type'] is! String)) {
        throw const Mr7Refused('observerWidget');
      }
      final matches = widgets.where((w) => (w as Map)['type'] == type).toList();
      if (matches.length > 1) throw const Mr7Refused('observerWidget');
      // An absent widget stays absent in the snapshot, distinct from null.
      if (matches.isEmpty) {
        complete = true;
        break;
      }
      final widget = matches.single as Map;
      if (!connected) {
        for (final field in selectedFields) {
          if (!widget.containsKey(field)) {
            throw const Mr7Refused('observerWidget');
          }
          projection[field] = widget[field];
        }
        complete = true;
        break;
      }
      final connection = widget[connectionField];
      final pageNodes = connection is Map ? connection['nodes'] : null;
      final info = connection is Map ? connection['pageInfo'] : null;
      if (pageNodes is! List ||
          pageNodes.length > 100 ||
          info is! Map ||
          info['hasNextPage'] is! bool) {
        throw const Mr7Refused('observerConnection');
      }
      for (final node in pageNodes) {
        final gid = node is Map ? node['id'] : null;
        final pattern = type == 'ASSIGNEES'
            ? r'^gid://gitlab/User/[1-9][0-9]*$'
            : r'^gid://gitlab/(Label|ProjectLabel)/[1-9][0-9]*$';
        if (node is! Map ||
            gid is! String ||
            !RegExp(pattern).hasMatch(gid) ||
            !nodeIds.add(gid) ||
            nodes.length >= 2000 ||
            (type == 'ASSIGNEES'
                ? node['username'] is! String
                : node['title'] is! String)) {
          throw const Mr7Refused('observerRelationship');
        }
        nodes.add(Map<String, Object?>.from(node));
      }
      if (info['hasNextPage'] == false) {
        nodes.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
        projection[connectionField] = nodes;
        complete = true;
        break;
      }
      final cursor = info['endCursor'];
      if (pageNodes.isEmpty ||
          cursor is! String ||
          cursor.isEmpty ||
          cursor.length > 1024 ||
          !cursors.add(cursor)) {
        throw const Mr7Refused('observerConnection');
      }
      after = cursor;
    }
    if (!complete) throw const Mr7Refused('observerConnectionCap');
  }
  return projection;
}

/// The activity observer is bound to a single project WorkItem and Note.
/// Discussion and reply IDs are opaque server values, never constructed here.
final class Mr7WorkItemActivityObservation extends Mr7StateObservation {
  const Mr7WorkItemActivityObservation({
    required this.workItemId,
    required this.iid,
    required this.operation,
    required this.noteId,
    this.discussionId,
    this.replyId,
    this.body,
    this.emojiName,
    this.add,
  });

  final String workItemId;
  final int iid;
  final String operation;
  final String noteId;
  final String? discussionId;
  final String? replyId;
  final String? body;
  final String? emojiName;
  final bool? add;

  @override
  bool matchesCall(String op, Object? arguments, int projectId) {
    if (op != operation ||
        arguments is! Map ||
        arguments['projectId'] != projectId ||
        arguments['iid'] != iid ||
        iid <= 0) {
      return false;
    }
    final noteNumber = int.tryParse(noteId.split('/').last);
    if (noteNumber == null ||
        noteNumber <= 0 ||
        noteId != 'gid://gitlab/Note/$noteNumber') {
      return false;
    }
    return switch (operation) {
      'editWorkItemActivityNote' =>
        arguments['noteId'] == noteNumber &&
            body is String &&
            arguments['body'] == body,
      'setWorkItemActivityNoteReaction' =>
        arguments['noteId'] == noteNumber &&
            emojiName is String &&
            arguments['name'] == emojiName &&
            add is bool &&
            arguments['add'] == add,
      _ => false,
    };
  }

  @override
  Future<bool> _read(Mr7Readback observer) => observer._workItemActivity(this);
}

// These selections are a subset of the production activity, strict note and
// reaction queries. No synthetic fields or AwardEmoji IDs are selected.
const _mr7ActivityPage = r'''
query Mr7Activity($id: WorkItemID!, $after: String) {
  currentUser { id }
  workItem(id: $id) {
    id iid project { id fullPath }
    widgets {
      type
      ... on WorkItemWidgetNotes {
        discussions(first: 20, after: $after) {
          nodes {
            id replyId
            notes(first: 20) {
              nodes { id body system author { id } }
              pageInfo { hasNextPage endCursor }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
''';
const _mr7ActivityNotesPage = r'''
query Mr7DiscussionNotes($workItemId: WorkItemID!, $anchorNoteId: NoteID!, $after: String) {
  currentUser { id }
  workItem(id: $workItemId) { id iid project { id fullPath } }
  anchor: note(id: $anchorNoteId) {
    id noteableType noteableId project { id fullPath }
    discussion {
      id replyId
      notes(first: 20, after: $after) {
        nodes { id body system author { id } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
''';
const _mr7ActivityNote = r'''
query Mr7Note($workItemId: WorkItemID!, $noteId: NoteID!) {
  currentUser { id }
  workItem(id: $workItemId) { id iid project { id fullPath } }
  note(id: $noteId) {
    id body system internal noteableType noteableId
    author { id } project { id fullPath }
    discussion { id replyId }
  }
}
''';
const _mr7ActivityReactions = r'''
query Mr7Reactions($workItemId: WorkItemID!, $noteId: NoteID!, $after: String) {
  currentUser { id }
  workItem(id: $workItemId) { id iid project { id fullPath } }
  note(id: $noteId) {
    id body system internal noteableType noteableId
    author { id } project { id fullPath }
    discussion { id }
    awardEmoji(first: 50, after: $after) {
      nodes { name unicode user { id } }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

enum Mr7ParentState { starred, subscribed, autoMerge }

final class Mr7ParentStateObservation extends Mr7StateObservation {
  const Mr7ParentStateObservation({
    required this.parent,
    required this.state,
    required this.expected,
  });
  final Mr7Parent parent;
  final Mr7ParentState state;
  final bool expected;
  @override
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

/// Creation is witnessed by a complete synthetic project list, never a global
/// account list or the mutation acknowledgement alone.
final class Mr7CreatedTodoObservation extends Mr7Observation<bool> {
  const Mr7CreatedTodoObservation({required this.parent, required this.id});
  final Mr7Parent parent;
  final int id;
  @override
  Future<bool> _read(Mr7Readback observer) => observer._createdTodo(this);
}

Future<List<Map<String, Object?>>> _projectTodoList(
  Dio reader,
  String path,
  Mr7Identity identity,
) async {
  final rows = <Map<String, Object?>>[];
  final ids = <int>{};
  final pagination = _PageSequence();
  var page = 1;
  while (true) {
    final response = await reader.get<Object?>(
      path,
      queryParameters: {'page': page, 'per_page': 100},
    );
    final next = pagination.next(response, page);
    if (jsonEncode(response.data).length > 2 * 1024 * 1024) {
      throw const Mr7Refused('observerTodo');
    }
    for (final raw in response.data! as List) {
      final id = raw is Map ? raw['id'] : null;
      final author = raw is Map ? raw['author'] : null;
      if (raw is! Map ||
          id is! int ||
          id <= 0 ||
          !ids.add(id) ||
          raw['project_id'] != identity.projectId ||
          raw['actor_id'] != identity.userId ||
          author is! Map ||
          author['id'] != identity.userId ||
          !const {'Issue', 'MergeRequest'}.contains(raw['target_type']) ||
          raw['target_id'] is! int ||
          (raw['target_id'] as int) <= 0 ||
          raw['target_iid'] is! int ||
          (raw['target_iid'] as int) <= 0 ||
          !const {'pending', 'done'}.contains(raw['state'])) {
        throw const Mr7Refused('observerTodo');
      }
      rows.add(Map.unmodifiable(Map<String, Object?>.from(raw)));
    }
    if (next == null) return List.unmodifiable(rows);
    page = next;
  }
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
        options.method == 'HEAD' ||
        _sealedGraphRead(options, session.observerAdapter.graphReadDocuments)) {
      session.validateRead(options, allowStopped: false);
      if (options.method == 'HEAD' &&
          requestStream != null &&
          await requestStream.any((chunk) => chunk.isNotEmpty)) {
        session.stop('headBody');
        throw const Mr7Refused('headBody');
      }
      session.chargeRequest();
      final permit = session.permit;
      final response = await session.server.respond(options);
      session.validateRead(options, allowStopped: false);
      if (options.method == 'HEAD') {
        if (await response.stream.any((chunk) => chunk.isNotEmpty)) {
          session.stop('headBody');
          throw const Mr7Refused('headBody');
        }
        session.validateRead(options, allowStopped: false);
        return ResponseBody.fromBytes(
          const [],
          response.statusCode,
          headers: response.headers,
        );
      }
      final path = session._restSegments(options).join('/');
      if (response.statusCode == 200 &&
          permit != null &&
          (_mr7WorkItemOperations.contains(permit.operation) ||
              const {
                'editWorkItemActivityNote',
                'setWorkItemActivityNoteReaction',
              }.contains(permit.operation)) &&
          _sealedGraphRead(
            options,
            session.observerAdapter.graphReadDocuments,
          )) {
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            throw const Mr7Refused('noChangeTargetUnbound');
          }
        }
        if (!identical(session.permit, permit)) {
          throw const Mr7Refused('noChangeTargetUnbound');
        }
        session._capturePreparedWorkItem(
          options.data,
          jsonDecode(utf8.decode(bytes)),
          permit,
        );
        session.validateRead(options, allowStopped: false);
        return ResponseBody.fromBytes(
          bytes,
          response.statusCode,
          headers: response.headers,
        );
      }
      if (options.method == 'GET' &&
          response.statusCode == 200 &&
          permit != null &&
          const {
            'setSubscribed',
            'cancelAutoMerge',
            ..._mr7WorkItemOperations,
            'editWorkItemActivityNote',
            'setWorkItemActivityNoteReaction',
          }.contains(permit.operation) &&
          RegExp(
            '^projects/${permit.resourceProjectId}/(issues|merge_requests)/[1-9][0-9]*\$',
          ).hasMatch(path)) {
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            throw const Mr7Refused('noChangeTargetUnbound');
          }
        }
        final row = jsonDecode(utf8.decode(bytes));
        final id = row is Map ? row['id'] : null;
        if (!identical(session.permit, permit) ||
            row is! Map ||
            id is! int ||
            id <= 0 ||
            row['project_id'] != permit.resourceProjectId ||
            row['iid'] != int.parse(path.split('/').last)) {
          throw const Mr7Refused('noChangeTargetUnbound');
        }
        if (permit._preparedParentIds.containsKey(path) &&
            permit._preparedParentIds[path] != id) {
          session.stop('noChangeTargetDrift');
          throw const Mr7Refused('noChangeTargetDrift');
        }
        permit._preparedParentIds[path] = id;
        session.validateRead(options, allowStopped: false);
        return ResponseBody.fromBytes(
          bytes,
          response.statusCode,
          headers: response.headers,
        );
      }
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
      final preparedPermit = session.permit;
      String? graphBodyDigest;
      if (options.uri.path == '${session.instance.path}/api/graphql') {
        try {
          graphBodyDigest = mr7Digest(options.data);
        } catch (_) {
          session.stop('unsealedGraph');
          throw const Mr7Refused('unsealedGraph');
        }
      }
      await session.beforeMutation(options);
      session.inFlight = true;
      final upload = preparedPermit?.operation == 'upload_attachment'
          ? await _uploadMetadata(options, requestStream)
          : null;
      session._open();
      if (graphBodyDigest != null) {
        var unchanged = false;
        try {
          unchanged = mr7Digest(options.data) == graphBodyDigest;
        } catch (_) {
          // A changed non-JSON payload cannot retain the original seal.
        }
        if (!unchanged) {
          session.stop('unsealedGraph');
          throw const Mr7Refused('unsealedGraph');
        }
      }
      if (!session._setupAuthorized && !session._cleanupAuthorized) {
        final permit = session.permit;
        if (permit == null ||
            !identical(permit, preparedPermit) ||
            !permit.confirmed ||
            permit.sent >= permit.maxMutations) {
          session.stop('unconfirmedOrUnboundWrite');
          throw const Mr7Refused('unconfirmedOrUnboundWrite');
        }
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
      final dispatchAt = session.server.serverTime;
      final response = await session.server.respond(options);
      if (!session._setupAuthorized &&
          !session._cleanupAuthorized &&
          preparedPermit != null) {
        preparedPermit._dispatches.add(
          _Mr7Dispatch(
            options.method,
            preparedPermit._sentPath!,
            dispatchAt,
            response.statusCode,
          ),
        );
      }
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
        session._terminalDeleteDispatched = true;
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
    this.timeout,
  });
  final Mr7SandboxSession _session;
  final Mr7Identity _identity;
  final Mr7MutationPermit _permit;
  final Set<String> paths;
  final Map<String, Set<String>> graphQueries;
  final Duration? timeout;
  int verifiedRequests = 0;
  String? _projectDeletionState;

  /// `absent` is a scoped observed absence, not proof of permanent erasure.
  String? get projectDeletionState => _projectDeletionState;
  Mr7StateObservation? _noDispatchObservation;

  Mr7MutationResult get result =>
      _permit.result ?? (throw const Mr7Refused('observerBeforeResponse'));
  Mr7PreReadSnapshot? get snapshot => _permit.snapshot;
  String get _root => 'projects/${_identity.projectId}';

  void _scope() {
    if (!_session._identityMatches(_identity) ||
        _session.inFlight ||
        _session.pendingMutations != 0 ||
        !_session.boundaryValid() ||
        (_permit.result == null && _noDispatchObservation == null) ||
        (_permit.result?.projectId != null &&
            _permit.result!.projectId != _identity.projectId)) {
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

  Future<bool> _createdTodo(Mr7CreatedTodoObservation spec) async {
    if (_permit.operation != 'createTodo' ||
        spec.id <= 0 ||
        result.id != spec.id ||
        _permit._todoIdsBefore == null ||
        _permit._todoIdsBefore!.contains(spec.id) ||
        !const {
          Mr7ParentKind.issue,
          Mr7ParentKind.mergeRequest,
        }.contains(spec.parent.kind)) {
      throw const Mr7Refused('observerTodo');
    }
    final parent = await _parent(spec.parent);
    _sentTo('${parent.path}/todo');
    if (parent.row['id'] != _permit._todoParentId) {
      throw const Mr7Refused('observerTodo');
    }
    final path = '$_root/todos/mr7-observation';
    _path(path);
    final rows = await _projectTodoList(_session.observer, path, _identity);
    final created = rows.where((row) => row['id'] == spec.id).toList();
    final after = await _parent(spec.parent);
    if (after.row['id'] != _permit._todoParentId || created.length != 1) {
      throw const Mr7Refused('observerTodo');
    }
    final todo = created.single;
    return todo['target_type'] ==
            (spec.parent.kind == Mr7ParentKind.issue
                ? 'Issue'
                : 'MergeRequest') &&
        todo['target_id'] == _permit._todoParentId &&
        todo['target_iid'] == spec.parent.iid &&
        todo['state'] == 'pending';
  }

  void _sentTo(String path) {
    if (_permit.sent != 1 || _permit._sentPath != path) {
      throw const Mr7Refused('observerMutationTarget');
    }
  }

  Future<T> observe<T>(Mr7Observation<T> observation) async {
    final limit = observation is Mr7SchedulePipelineObservation
        ? (observation as Mr7SchedulePipelineObservation).timeout
        : timeout;
    if (limit == null) return _observe(observation);
    if (limit <= Duration.zero || limit > const Duration(seconds: 2)) {
      throw const Mr7Refused('observerTimeoutConfiguration');
    }
    return _Mr7ObserverDeadline(limit).run(() => _observe(observation));
  }

  Future<T> _observe<T>(Mr7Observation<T> observation) async {
    if (observation is Mr7ProjectDeletionObservation) {
      final before = _session.observerAdapter.requests.length;
      await _terminalActor();
      final value = await observation._read(this);
      await _terminalActor();
      verifiedRequests += _session.observerAdapter.requests.length - before;
      return value;
    }
    await _actorAndProject();
    final before = _session.observerAdapter.requests.length;
    final value = await observation._read(this);
    await _actorAndProject();
    _scope();
    verifiedRequests += _session.observerAdapter.requests.length - before;
    return value;
  }

  /// A core no-op has no HTTP response. Only this sealed state vocabulary can
  /// observe it, bound to the requested arguments and the prepared route.
  Future<bool> observeNoChange(
    Mr7StateObservation observation, {
    required Object? arguments,
  }) async {
    final expectedArguments = _permit.preparedArguments;
    final original = _permit.callArguments;
    if (!identical(_session.permit, _permit) ||
        _permit.sent != 0 ||
        _permit.result != null ||
        _noDispatchObservation != null ||
        expectedArguments == null ||
        !_mr7SameJson(expectedArguments, arguments) ||
        (original != null &&
            const [
              'projectId',
              'groupId',
              'resource',
              'iid',
              'noteId',
              'anchorNoteId',
            ].any(
              (key) =>
                  original.containsKey(key) !=
                      expectedArguments.containsKey(key) ||
                  original[key] != expectedArguments[key],
            )) ||
        !observation.matchesCall(
          _permit.operation,
          arguments,
          _identity.projectId,
        )) {
      throw const Mr7Refused('noChangeUnverified');
    }
    _noDispatchObservation = observation;
    try {
      final verified = await observe(observation);
      if (!identical(_session.permit, _permit)) {
        throw const Mr7Refused('noChangeUnverified');
      }
      return verified;
    } finally {
      _noDispatchObservation = null;
    }
  }

  /// Re-read the original resource and preserved fields through the observer.
  Future<bool> verifySnapshot() async {
    final saved = snapshot;
    if (saved == null ||
        saved.actorId != _identity.userId ||
        saved.projectId != _identity.projectId ||
        (_permit.sent != 1 && _noDispatchObservation == null) ||
        (_permit._sentPath == null && _noDispatchObservation == null)) {
      throw const Mr7Refused('snapshotMissing');
    }
    await _actorAndProject();
    final before = _session.observerAdapter.requests.length;
    for (final original in saved._rows) {
      final path = original.spec.path;
      final sentPath = _permit._sentPath;
      final noop = _noDispatchObservation != null;
      if (path != _root &&
          !noop &&
          sentPath != path &&
          !(sentPath?.startsWith('$path/') ?? false) &&
          !(sentPath == 'graphql' &&
              _graphSnapshotTargets(
                _permit._sentBody,
                _permit._graphResourcesAtSend,
                path,
                _identity.path,
              ))) {
        throw const Mr7Refused('snapshotTarget');
      }
      final current = await _session._readSnapshotRow(
        original.spec,
        resource: await _map(path),
      );
      if (original.spec.kind == Mr7SnapshotKind.workItem &&
          jsonEncode(current).length > 2 * 1024 * 1024) {
        throw const Mr7Refused('observerUnreadable');
      }
      if (original.parentId != null) {
        final parentPath = path.split('/').take(4).join('/');
        final parent = await _map(parentPath);
        if (parent['id'] != original.parentId ||
            parent['iid'] != int.parse(parentPath.split('/').last) ||
            parent['project_id'] != _identity.projectId) {
          return false;
        }
      }
      if (!_snapshotIdentityMatches(original, current, _identity) ||
          (original.spec.kind == Mr7SnapshotKind.draftNote &&
              current.containsKey('body') !=
                  original.presentFields.contains('body')) ||
          (noop
                  ? original.spec.fields
                  : _snapshotPreservedFields(original, _permit._sentBody))
              .any(
                (field) =>
                    _snapshotFieldDigest(current, field) !=
                    original.digests[field],
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

  _Mr7Dispatch _effectDispatch(String operation, String method) {
    if (_permit.operation != operation ||
        _permit.sent != 1 ||
        _permit._dispatches.length != 1 ||
        _permit._effectBefore == null) {
      throw const Mr7Refused('observerMutationTarget');
    }
    final sent = _permit._dispatches.single;
    if (sent.method != method || sent.status < 200 || sent.status >= 300) {
      throw const Mr7Refused('observerMutationTarget');
    }
    return sent;
  }

  Future<List<Map<String, Object?>>> _rows(
    String path, {
    Map<String, Object?> query = const {},
    String key = 'id',
  }) async {
    _path(path);
    final rows = await _effectRows(
      _session.observer,
      path,
      query: query,
      key: key,
      stringIds: key != 'id',
    );
    if (rows.any(
      (r) =>
          r.containsKey('project_id') && r['project_id'] != _identity.projectId,
    )) {
      throw const Mr7Refused('readbackIdentity');
    }
    _scope();
    return rows;
  }

  Future<void> _branchAt(String ref, String sha) async {
    _sha(sha);
    final branch = await _map('$_root/repository/branches/${_name(ref)}');
    final commit = branch['commit'];
    if (branch['name'] != ref || commit is! Map || commit['id'] != sha) {
      throw const Mr7Refused('observerRef');
    }
  }

  Future<bool> _deletedFile(Mr7DeletedFileObservation spec) async {
    _effectDispatch('deleteFile', 'DELETE');
    _sentTo('$_root/repository/files/${_name(spec.path)}');
    final before = _permit._effectBefore!;
    if (before['path'] != spec.path ||
        before['ref'] != spec.ref ||
        before['sha'] == spec.sha) {
      throw const Mr7Refused('observerMutationTarget');
    }
    await _branchAt(spec.ref, spec.sha);
    final rows = await _rows(
      '$_root/repository/tree',
      query: {'ref': spec.sha, 'recursive': true},
      key: 'path',
    );
    for (final row in rows) {
      if (row['id'] is! String ||
          row['name'] is! String ||
          row['path'] is! String ||
          !const {'blob', 'tree', 'commit'}.contains(row['type']) ||
          row['mode'] is! String) {
        throw const Mr7Refused('observerTree');
      }
      _sha(row['id'] as String);
      _name(row['path'] as String);
      if (row['path'] == spec.path) throw const Mr7Refused('observerAbsence');
    }
    await _branchAt(spec.ref, spec.sha);
    return true;
  }

  Future<bool> _suggestion(Mr7SuggestionObservation spec) async {
    _effectDispatch('applySuggestion', 'PUT');
    _sentTo('suggestions/${spec.suggestionId}/apply');
    final before = _permit._effectBefore!;
    if (spec.parent.kind != Mr7ParentKind.mergeRequest ||
        spec.parent.id != before['parentId'] ||
        spec.discussionId != before['discussionId'] ||
        spec.noteId != before['noteId'] ||
        spec.suggestionId != before['suggestionId'] ||
        spec.path != before['path'] ||
        spec.ref != before['ref'] ||
        spec.sha == before['sha'] ||
        mr7Digest(spec.bytes) != before['expectedBytesDigest'] ||
        spec.bytes.length > 2 * 1024 * 1024) {
      throw const Mr7Refused('observerDiscussion');
    }
    final parent = await _parent(spec.parent);
    if (parent.path != before['parent']) {
      throw const Mr7Refused('observerDiscussion');
    }
    final discussion = await _map(
      '${parent.path}/discussions/${_name(spec.discussionId)}',
    );
    final selected = _suggestionIn(
      discussion,
      spec.discussionId,
      spec.noteId,
      spec.suggestionId,
    );
    if ((selected['suggestion'] as Map)['applied'] != true ||
        mr7Digest(selected['position']) != before['positionDigest']) {
      throw const Mr7Refused('observerDiscussion');
    }
    await _branchAt(spec.ref, spec.sha);
    _sha(spec.blobSha);
    final row = await _map(
      '$_root/repository/files/${_name(spec.path)}',
      query: {'ref': spec.sha},
    );
    final bytes = row['encoding'] == 'base64' && row['content'] is String
        ? base64Decode(row['content'] as String)
        : null;
    final blobBytes = [
      ...utf8.encode('blob ${spec.bytes.length}\u0000'),
      ...spec.bytes,
    ];
    final blob = (spec.blobSha.length == 40 ? sha1 : sha256)
        .convert(blobBytes)
        .toString();
    if (row['file_path'] != spec.path ||
        row['commit_id'] != spec.sha ||
        row['blob_id'] != spec.blobSha ||
        blob != spec.blobSha ||
        bytes == null ||
        mr7Digest(bytes) != mr7Digest(spec.bytes)) {
      throw const Mr7Refused('observerContent');
    }
    await _branchAt(spec.ref, spec.sha);
    await _parent(spec.parent);
    return true;
  }

  Future<bool> _deletedBoardList(Mr7DeletedBoardListObservation spec) async {
    _effectDispatch('deleteBoardList', 'DELETE');
    final before = _permit._effectBefore!;
    final boardPath = '$_root/boards/${spec.boardId}';
    _sentTo('$boardPath/lists/${spec.listId}');
    if (before['boardId'] != spec.boardId || before['listId'] != spec.listId) {
      throw const Mr7Refused('observerMutationTarget');
    }
    Future<void> board() async {
      final row = await _map(boardPath);
      if (row['id'] != spec.boardId) throw const Mr7Refused('observerParent');
    }

    await board();
    final rows = await _rows('$boardPath/lists');
    if (rows.any((r) => r['id'] == spec.listId)) {
      throw const Mr7Refused('observerAbsence');
    }
    await board();
    return true;
  }

  Future<bool> _publishedDrafts(Mr7PublishedDraftsObservation spec) async {
    _effectDispatch('publishDraftNotes', 'POST');
    final before = _permit._effectBefore!;
    final parent = await _parent(spec.parent);
    if (spec.parent.kind != Mr7ParentKind.mergeRequest ||
        parent.path != before['parent'] ||
        spec.parent.id != before['parentId']) {
      throw const Mr7Refused('observerParent');
    }
    _sentTo('${parent.path}/draft_notes/bulk_publish');
    final drafts = (before['drafts'] as List).cast<Map<Object?, Object?>>();
    if (spec.drafts.length != drafts.length ||
        drafts.any((r) => spec.drafts[r['id']] != r['note'])) {
      throw const Mr7Refused('observerDrafts');
    }
    for (final suffix in ['notes', 'discussions', 'draft_notes']) {
      _path('${parent.path}/$suffix');
    }
    final notes = await _publicNotes(
      _session.observer,
      parent.path,
      spec.parent.id!,
    );
    final fresh = notes
        .where(
          (r) =>
              !(before['notes'] as List).contains(r['id']) &&
              r['system'] == false &&
              r['internal'] == false &&
              (r['author'] as Map)['id'] == _identity.userId,
        )
        .toList();
    if (fresh.length != drafts.length) {
      throw const Mr7Refused('observerPublishedNote');
    }
    final originalDiscussions = (before['discussions'] as List).cast<String>();
    final newDiscussions = <String>{};
    for (final draft in drafts) {
      final index = fresh.indexWhere(
        (r) =>
            r['body'] == draft['note'] &&
            r['_discussion'] is String &&
            (draft['discussion_id'] == null
                ? !originalDiscussions.contains(r['_discussion']) &&
                      !newDiscussions.contains(r['_discussion'])
                : r['_discussion'] == draft['discussion_id']) &&
            _draftPositionMatches(draft['position'], r['position']),
      );
      if (index < 0) throw const Mr7Refused('observerPublishedNote');
      if (draft['discussion_id'] == null) {
        newDiscussions.add(fresh[index]['_discussion'] as String);
      }
      fresh.removeAt(index);
    }
    final remaining = await _rows('${parent.path}/draft_notes');
    if (remaining.isNotEmpty) throw const Mr7Refused('observerDrafts');
    await _parent(spec.parent);
    return true;
  }

  Future<Map<String, Object?>> _schedulePipeline(
    Mr7SchedulePipelineObservation spec,
  ) async {
    // The documented pipelines response cannot attest current schedule inputs.
    // Reading schedules/detail would fetch stored values, so this stays closed.
    throw const Mr7Refused('scheduleParametersUnproven');
  }

  Future<bool> _legacyCancel(Mr7LegacyCancelObservation spec) async {
    final before = _permit._effectBefore;
    if (_permit.operation != 'cancelAutoMerge' ||
        _permit.sent != 2 ||
        _permit._dispatches.length != 2 ||
        before?['enabled'] != true ||
        spec.parent.kind != Mr7ParentKind.mergeRequest ||
        spec.parent.id != before?['parentId']) {
      throw const Mr7Refused('observerLegacyCancel');
    }
    final parent = await _parent(spec.parent);
    final first = _permit._dispatches[0];
    final last = _permit._dispatches[1];
    if (parent.path != before!['parent'] ||
        first.method != 'POST' ||
        last.method != 'POST' ||
        first.path != '${parent.path}/cancel_auto_merge' ||
        !const {404, 405}.contains(first.status) ||
        last.path != '${parent.path}/cancel_merge_when_pipeline_succeeds' ||
        last.status < 200 ||
        last.status >= 300 ||
        last.at.isBefore(first.at)) {
      throw const Mr7Refused('observerLegacyCancel');
    }
    final row = parent.row;
    if (row['merge_when_pipeline_succeeds'] != false ||
        (row.containsKey('auto_merge_enabled') &&
            row['auto_merge_enabled'] != false)) {
      throw const Mr7Refused('observerState');
    }
    return true;
  }

  Future<void> _terminalActor() async {
    _scope();
    final sent = _effectDispatch('deleteProject', 'DELETE');
    if (sent.path != _root ||
        sent.status != 202 ||
        !_session.terminalDeletionAccepted ||
        _session._finalizing ||
        _session._finished ||
        _permit._effectBefore?['projectId'] != _identity.projectId) {
      throw const Mr7Refused('observerTerminalDeletion');
    }
    final actor = await _session.read('user');
    if (actor['id'] != _identity.userId ||
        actor['username'] != _identity.namespace) {
      throw const Mr7Refused('observerIdentity');
    }
    _scope();
  }

  Future<bool> _projectDeletion() async {
    _path(_root);
    if (!paths.contains('users/${_identity.userId}/projects')) {
      throw const Mr7Refused('readbackTarget');
    }
    final rows = await _session._projectEffectInventory();
    final matching = rows
        .where(
          (r) =>
              r['id'] == _identity.projectId ||
              r['path_with_namespace'] == _identity.path,
        )
        .toList();
    final byId = await _session.observer.get<Object?>(_root);
    final byPath = await _session.observer.get<Object?>(
      'projects/${Uri.encodeComponent(_identity.path)}',
    );
    if (matching.isEmpty &&
        byId.statusCode == 404 &&
        byPath.statusCode == 404) {
      _projectDeletionState = 'absent';
      return true;
    }
    bool pending(Object? raw) {
      if (raw is! Map) return false;
      final ns = raw['namespace'];
      final owner = raw['owner'];
      final date = raw['marked_for_deletion_on'];
      return raw['id'] == _identity.projectId &&
          raw['path_with_namespace'] == _identity.path &&
          raw['visibility'] == 'private' &&
          owner is Map &&
          owner['id'] == _identity.userId &&
          ns is Map &&
          ns['id'] == _identity.namespaceId &&
          ns['kind'] == 'user' &&
          ns['full_path'] == _identity.namespace &&
          date is String &&
          DateTime.tryParse(date) != null;
    }

    if (matching.length == 1 &&
        pending(matching.single) &&
        byId.statusCode == 200 &&
        byPath.statusCode == 200 &&
        pending(byId.data) &&
        pending(byPath.data)) {
      _projectDeletionState = 'pending';
      return true;
    }
    throw const Mr7Refused('observerTerminalDeletion');
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
    if (_permit.operation == 'createSnippet' && spec.visibility != 'private') {
      if (result.id != spec.id ||
          _permit._dispatches.length != 1 ||
          _permit._dispatches.single.method != 'POST' ||
          _permit._dispatches.single.path != '$_root/snippets' ||
          _permit._dispatches.single.status != 201) {
        throw const Mr7Refused('observerSnippetCreation');
      }
    }
    final body = _permit._sentBody;
    if (!const {'private', 'internal', 'public'}.contains(spec.visibility) ||
        ((spec.visibility != 'private' ||
                (body is Map && body.containsKey('visibility'))) &&
            (body is! Map || body['visibility'] != spec.visibility))) {
      throw const Mr7Refused('observerSnippetVisibility');
    }
    if (_permit.operation == 'createSnippet' &&
        (spec.visibility != 'private' ||
            (body is Map && body.containsKey('files')))) {
      final files = body is Map ? body['files'] : null;
      if (files is! List || files.length != spec.files.length) {
        throw const Mr7Refused('observerContent');
      }
      final seen = <String>{};
      for (final file in files) {
        if (file is! Map ||
            file['file_path'] is! String ||
            file['content'] is! String ||
            !seen.add(file['file_path'] as String) ||
            !spec.files.containsKey(file['file_path']) ||
            mr7Digest(utf8.encode(file['content'] as String)) !=
                mr7Digest(spec.files[file['file_path']]!.bytes)) {
          throw const Mr7Refused('observerContent');
        }
      }
    }
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
          row['visibility'] != spec.visibility ||
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

  ({List<dynamic> nodes, String? next}) _activityConnection(
    Object? value,
    int maxSize,
    Set<String> seenCursors,
  ) {
    if (value is! Map ||
        value['nodes'] is! List ||
        (value['nodes'] as List).length > maxSize ||
        value['pageInfo'] is! Map) {
      throw const Mr7Refused('observerConnection');
    }
    final nodes = value['nodes'] as List;
    final info = value['pageInfo'] as Map;
    final more = info['hasNextPage'];
    if (more is! bool) throw const Mr7Refused('observerConnection');
    if (!more) return (nodes: nodes, next: null);
    final cursor = info['endCursor'];
    if (nodes.isEmpty ||
        cursor is! String ||
        cursor.isEmpty ||
        cursor.length > 4096 ||
        !seenCursors.add(cursor)) {
      throw const Mr7Refused('observerConnection');
    }
    return (nodes: nodes, next: cursor);
  }

  void _activityNoteIdentity(
    Map<Object?, Object?> note,
    Mr7WorkItemActivityObservation spec,
    String parent, {
    bool requireTarget = true,
  }) {
    final project = note['project'];
    final actor = note['author'];
    final numericParent = int.tryParse(spec.workItemId.split('/').last);
    if ((requireTarget && note['id'] != spec.noteId) ||
        note['noteableType'] != 'Issue' ||
        note['noteableId'] != numericParent ||
        note['system'] != false ||
        note['internal'] != false ||
        actor is! Map ||
        actor['id'] != 'gid://gitlab/User/${_identity.userId}' ||
        project is! Map ||
        project['id'] != 'gid://gitlab/Project/${_identity.projectId}' ||
        project['fullPath'] != _identity.path ||
        !_workItemPath(spec.workItemId).startsWith(parent)) {
      throw const Mr7Refused('observerNoteOwnership');
    }
  }

  Future<bool> _workItemActivity(Mr7WorkItemActivityObservation spec) async {
    const operations = {
      'createWorkItemActivityComment',
      'createWorkItemActivityReply',
      'editWorkItemActivityNote',
      'deleteWorkItemActivityNote',
      'setWorkItemActivityNoteReaction',
    };
    if (!operations.contains(spec.operation) ||
        _permit.operation != spec.operation ||
        spec.iid <= 0 ||
        !RegExp(r'^gid://gitlab/Note/[1-9][0-9]*$').hasMatch(spec.noteId)) {
      throw const Mr7Refused('observerMutationTarget');
    }
    final parent = _workItemPath(spec.workItemId);
    if (int.tryParse(parent.split('/').last) != spec.iid) {
      throw const Mr7Refused('observerParent');
    }
    final notePath = '$parent/notes/${spec.noteId.split('/').last}';
    final creating =
        spec.operation == 'createWorkItemActivityComment' ||
        spec.operation == 'createWorkItemActivityReply';
    final deleting = spec.operation == 'deleteWorkItemActivityNote';
    final reaction = spec.operation == 'setWorkItemActivityNoteReaction';
    if (_permit.sent == 0) {
      final prepared = await _session.read(parent);
      if (prepared['id'] != int.tryParse(spec.workItemId.split('/').last) ||
          prepared['iid'] != spec.iid ||
          prepared['project_id'] != _identity.projectId ||
          _permit._preparedParentIds[parent] != prepared['id'] ||
          _noDispatchObservation != spec ||
          !const {
            'editWorkItemActivityNote',
            'setWorkItemActivityNoteReaction',
          }.contains(spec.operation) ||
          _permit._preparedActivityNote !=
              (id: spec.noteId, parentPath: parent) ||
          _session._graphResources[spec.noteId] != notePath) {
        throw const Mr7Refused('observerMutationTarget');
      }
    } else {
      if (_permit._graphResourcesAtSend[spec.workItemId] != parent) {
        throw const Mr7Refused('observerMutationTarget');
      }
      final root = switch (spec.operation) {
        'createWorkItemActivityComment' ||
        'createWorkItemActivityReply' => 'createNote',
        'editWorkItemActivityNote' => 'updateNote',
        'deleteWorkItemActivityNote' => 'destroyNote',
        'setWorkItemActivityNoteReaction' =>
          spec.add == true ? 'awardEmojiAdd' : 'awardEmojiRemove',
        _ => throw const Mr7Refused('observerMutationTarget'),
      };
      final input = _mutationInput(root);
      if (creating) {
        if (result.stringId != spec.noteId ||
            input['noteableId'] != spec.workItemId ||
            spec.body is! String ||
            input['body'] != spec.body ||
            (spec.operation == 'createWorkItemActivityReply'
                ? (spec.replyId == null ||
                      input['discussionId'] != spec.replyId)
                : input.containsKey('discussionId'))) {
          throw const Mr7Refused('observerMutationTarget');
        }
        if (spec.operation == 'createWorkItemActivityReply') {
          final call = _permit.callArguments;
          final anchorNumber = call?['anchorNoteId'];
          if (call?['projectId'] != _identity.projectId ||
              call?['iid'] != spec.iid ||
              anchorNumber is! int ||
              anchorNumber <= 0 ||
              spec.discussionId == null ||
              spec.replyId == null) {
            throw const Mr7Refused('observerReplyAnchor');
          }
          final anchorId = 'gid://gitlab/Note/$anchorNumber';
          if (_permit._graphResourcesAtSend[anchorId] !=
              '$parent/notes/$anchorNumber') {
            throw const Mr7Refused('observerReplyAnchor');
          }
          final data = await _sealedWorkItemQuery(_mr7ActivityNote, {
            'workItemId': spec.workItemId,
            'noteId': anchorId,
          });
          final record = data['workItem'];
          final anchor = data['note'];
          if (record is! Map || anchor is! Map || anchor['id'] != anchorId) {
            throw const Mr7Refused('observerReplyAnchor');
          }
          _workItemRecord(spec.workItemId, Map<String, Object?>.from(record));
          _activityNoteIdentity(anchor, spec, parent, requireTarget: false);
          final discussion = anchor['discussion'];
          if (discussion is! Map ||
              discussion['id'] != spec.discussionId ||
              discussion['replyId'] != spec.replyId ||
              input['discussionId'] != discussion['replyId']) {
            throw const Mr7Refused('observerReplyAnchor');
          }
        }
        final returned = await _session.read(notePath);
        final author = returned['author'];
        if (returned['id'] != int.parse(spec.noteId.split('/').last) ||
            returned['project_id'] != _identity.projectId ||
            returned['noteable_id'] !=
                int.parse(spec.workItemId.split('/').last) ||
            author is! Map ||
            author['id'] != _identity.userId) {
          throw const Mr7Refused('observerNoteOwnership');
        }
        await bindReturnedResource(spec.noteId, path: notePath);
      } else if (_permit._graphResourcesAtSend[spec.noteId] != notePath ||
          (reaction
              ? (input['awardableId'] != spec.noteId ||
                    input['name'] != spec.emojiName ||
                    spec.add == null)
              : (input['id'] != spec.noteId ||
                    (!deleting &&
                        (spec.body == null || input['body'] != spec.body))))) {
        throw const Mr7Refused('observerMutationTarget');
      }
      // Deletion loses the Note body and author. Require a fresh pre-dispatch
      // ownership binding made by the guard for this exact Note and actor.
      if (deleting && _permit._ownedActivityNoteAtSend != spec.noteId) {
        throw const Mr7Refused('observerNoteOwnership');
      }
    }

    if (reaction) {
      if (spec.emojiName is! String ||
          spec.emojiName!.isEmpty ||
          spec.add == null) {
        throw const Mr7Refused('observerReaction');
      }
      final cursors = <String>{};
      final pairs = <String>{};
      String? after;
      var actorFound = false;
      for (var page = 0; page < 20; page++) {
        final data = await _sealedWorkItemQuery(_mr7ActivityReactions, {
          'workItemId': spec.workItemId,
          'noteId': spec.noteId,
          'after': after,
        });
        final record = data['workItem'];
        if (record is! Map) throw const Mr7Refused('readbackIdentity');
        _workItemRecord(spec.workItemId, Map<String, Object?>.from(record));
        final note = data['note'];
        if (note is! Map) throw const Mr7Refused('observerNoteOwnership');
        _activityNoteIdentity(note, spec, parent);
        if (spec.discussionId != null &&
            (note['discussion'] is! Map ||
                (note['discussion'] as Map)['id'] != spec.discussionId)) {
          throw const Mr7Refused('observerRelationship');
        }
        final connection = _activityConnection(note['awardEmoji'], 50, cursors);
        for (final node in connection.nodes) {
          final user = node is Map ? node['user'] : null;
          if (node is! Map ||
              node['name'] is! String ||
              user is! Map ||
              user['id'] is! String ||
              !RegExp(
                r'^gid://gitlab/User/[1-9][0-9]*$',
              ).hasMatch(user['id'] as String)) {
            throw const Mr7Refused('observerRelationship');
          }
          final pair = '${node['name']}\u0000${user['id']}';
          if (!pairs.add(pair)) throw const Mr7Refused('observerRelationship');
          if (node['name'] == spec.emojiName &&
              user['id'] == 'gid://gitlab/User/${_identity.userId}') {
            actorFound = true;
          }
        }
        if (connection.next == null) return actorFound == spec.add;
        after = connection.next;
      }
      throw const Mr7Refused('observerConnectionCap');
    }

    if (!deleting) {
      final data = await _sealedWorkItemQuery(_mr7ActivityNote, {
        'workItemId': spec.workItemId,
        'noteId': spec.noteId,
      });
      final record = data['workItem'];
      if (record is! Map) throw const Mr7Refused('readbackIdentity');
      _workItemRecord(spec.workItemId, Map<String, Object?>.from(record));
      final note = data['note'];
      if (note is! Map) throw const Mr7Refused('observerNoteOwnership');
      _activityNoteIdentity(note, spec, parent);
      final discussion = note['discussion'];
      if (note['body'] != spec.body ||
          discussion is! Map ||
          discussion['id'] is! String ||
          (spec.discussionId != null &&
              discussion['id'] != spec.discussionId) ||
          (spec.replyId != null && discussion['replyId'] != spec.replyId)) {
        return false;
      }
    }

    // Iterate every discussion and every nested note page. A null note lookup
    // is deliberately never consulted as deletion proof.
    final discussionIds = <String>{};
    final noteIds = <String>{};
    final outerCursors = <String>{};
    String? outerAfter;
    for (var outer = 0; outer < 20; outer++) {
      final data = await _sealedWorkItemQuery(_mr7ActivityPage, {
        'id': spec.workItemId,
        'after': outerAfter,
      });
      final record = data['workItem'];
      if (record is! Map) throw const Mr7Refused('readbackIdentity');
      _workItemRecord(spec.workItemId, Map<String, Object?>.from(record));
      final widgets = record['widgets'];
      if (widgets is! List) throw const Mr7Refused('observerConnection');
      final notesWidgets = widgets
          .where((w) => w is Map && w['type'] == 'NOTES')
          .toList();
      if (notesWidgets.length != 1) {
        throw const Mr7Refused('observerConnection');
      }
      final discussions = _activityConnection(
        (notesWidgets.single as Map)['discussions'],
        20,
        outerCursors,
      );
      for (final discussion in discussions.nodes) {
        if (discussion is! Map ||
            discussion['id'] is! String ||
            (discussion['id'] as String).isEmpty ||
            discussion['replyId'] is! String ||
            (discussion['replyId'] as String).isEmpty ||
            !discussionIds.add(discussion['id'] as String)) {
          throw const Mr7Refused('observerRelationship');
        }
        final innerCursors = <String>{};
        var notes = _activityConnection(discussion['notes'], 20, innerCursors);
        for (var inner = 0; inner < 20; inner++) {
          for (final note in notes.nodes) {
            final id = note is Map ? note['id'] : null;
            if (id is! String ||
                !RegExp(r'^gid://gitlab/Note/[1-9][0-9]*$').hasMatch(id) ||
                !noteIds.add(id)) {
              throw const Mr7Refused('observerRelationship');
            }
            if (id == spec.noteId &&
                (note['author'] is! Map ||
                    (note['author'] as Map)['id'] !=
                        'gid://gitlab/User/${_identity.userId}' ||
                    note['system'] != false ||
                    note['body'] != spec.body ||
                    (spec.discussionId != null &&
                        discussion['id'] != spec.discussionId) ||
                    (spec.replyId != null &&
                        discussion['replyId'] != spec.replyId))) {
              throw const Mr7Refused('observerRelationship');
            }
          }
          if (notes.next == null) break;
          if (inner == 19 || notes.nodes.isEmpty) {
            throw const Mr7Refused('observerConnectionCap');
          }
          final anchor = (notes.nodes.last as Map)['id'] as String;
          final anchorPath = '$parent/notes/${anchor.split('/').last}';
          if (_session._graphResources[anchor] != anchorPath) {
            await _session.bindGraphResource(anchor, path: anchorPath);
          }
          final continuation =
              await _sealedWorkItemQuery(_mr7ActivityNotesPage, {
                'workItemId': spec.workItemId,
                'anchorNoteId': anchor,
                'after': notes.next,
              });
          final item = continuation['workItem'];
          if (item is! Map) throw const Mr7Refused('readbackIdentity');
          _workItemRecord(spec.workItemId, Map<String, Object?>.from(item));
          final anchored = continuation['anchor'];
          final anchoredDiscussion = anchored is Map
              ? anchored['discussion']
              : null;
          final anchoredProject = anchored is Map ? anchored['project'] : null;
          if (anchored is! Map ||
              anchored['id'] != anchor ||
              anchored['noteableType'] != 'Issue' ||
              anchored['noteableId'] !=
                  int.parse(spec.workItemId.split('/').last) ||
              anchoredProject is! Map ||
              anchoredProject['id'] !=
                  'gid://gitlab/Project/${_identity.projectId}' ||
              anchoredProject['fullPath'] != _identity.path ||
              anchoredDiscussion is! Map ||
              anchoredDiscussion['id'] != discussion['id'] ||
              anchoredDiscussion['replyId'] != discussion['replyId']) {
            throw const Mr7Refused('observerRelationship');
          }
          notes = _activityConnection(
            anchoredDiscussion['notes'],
            20,
            innerCursors,
          );
        }
      }
      if (discussions.next == null) {
        return deleting
            ? !noteIds.contains(spec.noteId)
            : noteIds.contains(spec.noteId);
      }
      outerAfter = discussions.next;
    }
    throw const Mr7Refused('observerConnectionCap');
  }

  String _workItemPath(String id) => _mr7WorkItemPath(_session, _identity, id);

  void _workItemRecord(String id, Map<String, Object?> row) =>
      _mr7WorkItemRecord(_session, _identity, id, row);

  Future<Map<String, Object?>> _sealedWorkItemQuery(
    String document,
    Map<String, Object?> variables,
  ) => _mr7SealedQuery(_session, _identity, document, variables);

  Map<String, Object?> _mutationInput(String root) {
    _sentTo('graphql');
    return _mr7MutationInput(_permit._sentBody, root);
  }

  Future<bool> _workItemEffect(Mr7WorkItemObservation spec) async {
    final a = spec.arguments;
    if (!spec.matchesCall(_permit.operation, a, _identity.projectId)) {
      throw const Mr7Refused('observerWidget');
    }
    final path = _workItemPath(spec.workItemId);
    final parent = await _session.read(path);
    final number = int.parse(spec.workItemId.split('/').last);
    if (path != '$_root/issues/${spec.iid}' ||
        parent['id'] != number ||
        parent['iid'] != spec.iid ||
        parent['project_id'] != _identity.projectId) {
      throw const Mr7Refused('observerParent');
    }
    final noop = identical(_noDispatchObservation, spec);
    if (noop &&
        (_permit.sent != 0 ||
            !_permit.paths.contains('POST graphql') ||
            _permit._preparedParentIds[path] != number)) {
      throw const Mr7Refused('noChangeUnverified');
    }
    final incident = spec.operation == 'setIncidentStatus';
    final root = incident
        ? 'issueSetEscalationStatus'
        : spec.operation == 'setWorkItemNotifications'
        ? 'workItemSubscribe'
        : 'workItemUpdate';
    final input = noop ? null : _mutationInput(root);
    if (!noop &&
        (_permit._graphResourcesAtSend[spec.workItemId] != path ||
            (incident
                ? input!['projectPath'] != _identity.path ||
                      input['iid'] != '${spec.iid}'
                : input!['id'] != spec.workItemId))) {
      throw const Mr7Refused('observerMutationTarget');
    }
    // A typed snapshot is mandatory for changed widgets: omitted fields must
    // survive, and label deltas need their complete independently read base.
    final saved = snapshot?._rows
        .where(
          (r) =>
              r.spec.kind == Mr7SnapshotKind.workItem &&
              r.spec.path == path &&
              r.spec.workItemId == spec.workItemId,
        )
        .toList();
    if (!noop && (saved == null || saved.length != 1)) {
      throw const Mr7Refused('snapshotMissing');
    }
    final before = saved?.length == 1
        ? saved!.single.values
        : <String, Object?>{};
    if (incident) {
      const document = r'''
query Mr7Incident($path: ID!, $iid: String!) {
  currentUser { id }
  project(fullPath: $path) {
    id
    issues(iids: [$iid], types: [INCIDENT], first: 2) {
      nodes { id iid projectId state severity escalationStatus updatedAt }
      pageInfo { hasNextPage }
    }
  }
}
''';
      if (!const {
            'TRIGGERED',
            'ACKNOWLEDGED',
            'RESOLVED',
          }.contains(a['status']) ||
          (!noop &&
              !_mr7SameJson(input, {
                'projectPath': _identity.path,
                'iid': '${spec.iid}',
                'status': a['status'],
              }))) {
        throw const Mr7Refused('observerMutationTarget');
      }
      final data = await _sealedWorkItemQuery(document, {
        'path': _identity.path,
        'iid': '${spec.iid}',
      });
      final project = data['project'];
      final connection = project is Map ? project['issues'] : null;
      final nodes = connection is Map ? connection['nodes'] : null;
      final info = connection is Map ? connection['pageInfo'] : null;
      if (project is! Map ||
          project['id'] != 'gid://gitlab/Project/${_identity.projectId}' ||
          nodes is! List ||
          nodes.length != 1 ||
          info is! Map ||
          info['hasNextPage'] != false) {
        throw const Mr7Refused('observerConnection');
      }
      final issue = nodes.single;
      if (issue is! Map ||
          issue['id'] != 'gid://gitlab/Issue/$number' ||
          issue['iid'] != '${spec.iid}' ||
          issue['projectId'] != _identity.projectId ||
          issue['escalationStatus'] != a['status'] ||
          issue['updatedAt'] is! String ||
          DateTime.tryParse(issue['updatedAt'] as String) == null) {
        return false;
      }
      return await _finishWorkItemWitness(path, number, preserve: true);
    }
    final fields = switch (spec.operation) {
      'updateWorkItemState' => <String>{'state'},
      'updateWorkItemStatus' => <String>{'status'},
      'updateWorkItemDates' => <String>{
        'startDate',
        'dueDate',
        'rollUp',
        ..._mr7CeDateFields,
      },
      'updateWorkItemAssignees' => <String>{'assignees'},
      'updateWorkItemMilestone' => <String>{'milestone'},
      'updateWorkItemContent' => <String>{'title', 'description'},
      'updateWorkItemLabels' => <String>{'labels'},
      'setWorkItemNotifications' => <String>{'subscribed'},
      _ => throw const Mr7Refused('observerWidget'),
    };
    final row = await _mr7ReadWorkItem(
      _session,
      _identity,
      spec.workItemId,
      fields,
    );
    bool exactInput(Map<String, Object?> desired) =>
        noop || _mr7SameJson(input, {'id': spec.workItemId, ...desired});
    bool matches = false;
    switch (spec.operation) {
      case 'updateWorkItemState':
        final state = switch (a['stateEvent']) {
          'close' => 'CLOSED',
          'reopen' => 'OPEN',
          _ => null,
        };
        matches =
            state != null &&
            row['state'] == state &&
            exactInput({'stateEvent': a['stateEvent']});
      case 'updateWorkItemStatus':
        final status = row['status'];
        matches =
            a['candidateId'] is String &&
            status is Map &&
            status['id'] == a['candidateId'] &&
            exactInput({
              'statusWidget': {'status': a['candidateId']},
            });
      case 'updateWorkItemDates':
        final inherited = a['mode'] == 'inherited';
        if (!inherited && a['mode'] != 'manual') break;
        if (!row.containsKey('startDate') ||
            !row.containsKey('dueDate') ||
            row['rollUp'] is! bool ||
            !_mr7Date(row['startDate']) ||
            !_mr7Date(row['dueDate'])) {
          break;
        }
        if (row.containsKey('isFixed') || inherited) {
          if (row['isFixed'] != !inherited) break;
          var sourcesValid = true;
          for (final f in fields.where((f) => f.contains('Sourcing'))) {
            final source = row[f];
            final type = f.endsWith('Milestone') ? 'Milestone' : 'WorkItem';
            if (!row.containsKey(f) ||
                (source != null &&
                    (source is! Map ||
                        source['id'] is! String ||
                        !RegExp(
                          '^gid://gitlab/$type/[1-9][0-9]*\$',
                        ).hasMatch(source['id'] as String)))) {
              sourcesValid = false;
            }
          }
          if (!sourcesValid) break;
        }
        if (inherited) {
          matches = exactInput({
            'startAndDueDateWidget': {'isFixed': false},
          });
        } else {
          final widget = input?['startAndDueDateWidget'];
          var datesMatch = true;
          for (final f in ['startDate', 'dueDate']) {
            final clear =
                a[f == 'startDate' ? 'clearStart' : 'clearDue'] == true;
            if (clear && a.containsKey(f)) datesMatch = false;
            final expected = clear
                ? null
                : a.containsKey(f)
                ? a[f]
                : before[f];
            if ((clear || a.containsKey(f) || before.containsKey(f)) &&
                row[f] != expected) {
              datesMatch = false;
            }
            if (!noop &&
                (widget is! Map ||
                    !widget.containsKey(f) ||
                    widget[f] != row[f])) {
              datesMatch = false;
            }
          }
          final desired = {
            'startAndDueDateWidget': {
              if (row.containsKey('isFixed')) 'isFixed': true,
              'startDate': row['startDate'],
              'dueDate': row['dueDate'],
            },
          };
          matches = datesMatch && exactInput(desired);
        }
      case 'updateWorkItemAssignees':
        final names = a['assigneeUsernames'];
        final actual = row['assignees'];
        if (names is! List ||
            names.length > 1 ||
            names.any((n) => n != _identity.namespace) ||
            actual is! List) {
          break;
        }
        final expected = names.isEmpty
            ? <String>{}
            : {'gid://gitlab/User/${_identity.userId}'};
        final ids = actual.map((n) => (n as Map)['id']).toSet();
        matches =
            ids.length == expected.length &&
            ids.containsAll(expected) &&
            actual.every(
              (n) => (n as Map)['username'] == _identity.namespace,
            ) &&
            exactInput({
              'assigneesWidget': {'assigneeIds': expected.toList()},
            });
      case 'updateWorkItemMilestone':
        if (!row.containsKey('milestone')) break;
        final milestone = row['milestone'];
        if (a['clearMilestone'] == true) {
          matches =
              !a.containsKey('milestoneTitle') &&
              milestone == null &&
              exactInput({
                'milestoneWidget': {'milestoneId': null},
              });
        } else if (a['milestoneTitle'] is String && milestone is Map) {
          final project = milestone['project'];
          final widget = input?['milestoneWidget'];
          final id = milestone['id'];
          matches =
              id is String &&
              RegExp(r'^gid://gitlab/Milestone/[1-9][0-9]*$').hasMatch(id) &&
              milestone['title'] == a['milestoneTitle'] &&
              project is Map &&
              project['id'] == 'gid://gitlab/Project/${_identity.projectId}' &&
              project['fullPath'] == _identity.path &&
              (spec.milestoneState == null ||
                  milestone['state'] == spec.milestoneState) &&
              (spec.milestoneExpired == null ||
                  milestone['expired'] == spec.milestoneExpired) &&
              (noop ||
                  (widget is Map &&
                      widget['milestoneId'] == id &&
                      _permit._graphResourcesAtSend[id] ==
                          '$_root/milestones/${id.split('/').last}' &&
                      exactInput({
                        'milestoneWidget': {'milestoneId': id},
                      })));
        }
      case 'updateWorkItemContent':
        if (!a.containsKey('title') && !a.containsKey('description')) break;
        matches =
            (!a.containsKey('title') ||
                (a['title'] is String && row['title'] == a['title'])) &&
            (!a.containsKey('description') ||
                (a['description'] is String &&
                    row.containsKey('description') &&
                    (row['description'] ?? '') == a['description']));
        if (!noop) {
          if (input!.keys.any(
                (k) => !const {'id', 'title', 'descriptionWidget'}.contains(k),
              ) ||
              input.length < 2) {
            matches = false;
          }
          if (input.containsKey('title') &&
              (!a.containsKey('title') || input['title'] != a['title'])) {
            matches = false;
          }
          if (input.containsKey('descriptionWidget') &&
              (!a.containsKey('description') ||
                  !_mr7SameJson(input['descriptionWidget'], {
                    'description': a['description'],
                  }))) {
            matches = false;
          }
          if (!input.containsKey('title') &&
              a.containsKey('title') &&
              before['title'] != a['title']) {
            matches = false;
          }
          if (!input.containsKey('descriptionWidget') &&
              a.containsKey('description') &&
              (before['description'] ?? '') != a['description']) {
            matches = false;
          }
        }
      case 'updateWorkItemLabels':
        final names = a['labels'];
        final actual = row['labels'];
        if (names is! List ||
            names.any((n) => n is! String) ||
            names.toSet().length != names.length ||
            actual is! List) {
          break;
        }
        final actualNames = actual.map((n) => (n as Map)['title']).toSet();
        matches =
            actualNames.length == names.length &&
            actualNames.containsAll(names) &&
            actual.length == names.length;
        if (!noop) {
          final widget = input!['labelsWidget'];
          final old = before['labels'];
          if (widget is! Map ||
              old is! List ||
              widget.keys.any(
                (k) => !const {'addLabelIds', 'removeLabelIds'}.contains(k),
              ) ||
              widget['addLabelIds'] is! List ||
              widget['removeLabelIds'] is! List) {
            matches = false;
            break;
          }
          final adds = (widget['addLabelIds'] as List).toSet();
          final removes = (widget['removeLabelIds'] as List).toSet();
          final oldIds = old.map((n) => (n as Map)['id']).toSet();
          final actualIds = actual.map((n) => (n as Map)['id']).toSet();
          final expected = {...oldIds}
            ..removeAll(removes)
            ..addAll(adds);
          matches =
              matches &&
              adds.length == (widget['addLabelIds'] as List).length &&
              removes.length == (widget['removeLabelIds'] as List).length &&
              adds.intersection(removes).isEmpty &&
              oldIds.containsAll(removes) &&
              oldIds.intersection(adds).isEmpty &&
              actualIds.length == expected.length &&
              actualIds.containsAll(expected) &&
              exactInput({'labelsWidget': Map<String, Object?>.from(widget)});
        }
      case 'setWorkItemNotifications':
        matches =
            a['enabled'] is bool &&
            row['subscribed'] is bool &&
            row['subscribed'] == a['enabled'] &&
            exactInput({'subscribed': a['enabled']});
    }
    if (!matches) return false;
    return await _finishWorkItemWitness(path, number, preserve: true);
  }

  Future<bool> _finishWorkItemWitness(
    String path,
    int number, {
    required bool preserve,
  }) async {
    final parent = await _session.read(path);
    if (parent['id'] != number ||
        parent['project_id'] != _identity.projectId ||
        parent['iid'] != int.parse(path.split('/').last)) {
      throw const Mr7Refused('observerParent');
    }
    return !preserve || snapshot == null || await verifySnapshot();
  }

  Future<bool> _parentState(Mr7ParentStateObservation spec) async {
    final parent = await _parent(spec.parent);
    void boundTo(String path) {
      if (identical(_noDispatchObservation, spec)) {
        if (_permit.sent != 0 ||
            !_permit.paths.contains('POST $path') ||
            (parent.path != _root &&
                _permit._preparedParentIds[parent.path] != parent.row['id'])) {
          throw const Mr7Refused('noChangeUnverified');
        }
      } else {
        _sentTo(path);
      }
    }

    if (spec.state == Mr7ParentState.autoMerge) {
      boundTo('${parent.path}/cancel_auto_merge');
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
    boundTo(
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
    observer =
        Dio(
            BaseOptions(
              baseUrl: '${this.instance}/api/v4/',
              followRedirects: false,
              headers: {'cache-control': 'no-cache, no-store'},
              validateStatus: (s) => s != null && s < 500,
            ),
          )
          ..httpClientAdapter = observerAdapter
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final deadline =
                    Zone.current[_observerDeadlineKey] as _Mr7ObserverDeadline?;
                if (deadline != null) {
                  try {
                    deadline.check();
                  } on Mr7Refused catch (error) {
                    handler.reject(
                      DioException(requestOptions: options, error: error),
                    );
                    return;
                  }
                  options.cancelToken = deadline.token;
                  options.receiveTimeout = deadline.remaining;
                }
                handler.next(options);
              },
            ),
          );
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
  bool _terminalDeleteDispatched = false;
  bool quarantined = false;
  bool _setupAuthorized = false;
  bool _cleanupAuthorized = false;
  bool _started = false;
  bool _finished = false;
  bool _finalizing = false;
  bool _effectInventoryAllowed = false;
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
    final effectInventoryRead =
        _effectInventoryAllowed &&
        target != null &&
        path == 'users/${target.userId}/projects' &&
        request.queryParameters.length == 2 &&
        request.queryParameters['page'] is int &&
        (request.queryParameters['page'] as int) >= 1 &&
        (request.queryParameters['page'] as int) <= 20 &&
        request.queryParameters['per_page'] == 100;
    final finalQuery = request.uri.queryParametersAll;
    final fileHead =
        request.method == 'HEAD' &&
        projectRead &&
        segments.length == 5 &&
        segments[2] == 'repository' &&
        segments[3] == 'files' &&
        segments[4].isNotEmpty &&
        segments[4].length <= 4096 &&
        !segments[4].contains('\\') &&
        !segments[4]
            .split('/')
            .any((s) => s.isEmpty || s == '.' || s == '..') &&
        request.data == null &&
        finalQuery.length == 1 &&
        finalQuery['ref']?.length == 1 &&
        finalQuery['ref']!.single.isNotEmpty &&
        finalQuery['ref']!.single.length <= 1024;
    if (!fileHead &&
        (request.method != 'GET' ||
            (!setupRead &&
                !projectRead &&
                !parentRead &&
                !effectInventoryRead))) {
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
      'ProjectLabel': r'labels/[1-9][0-9]*',
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
          final incidentIids =
              graph &&
              key == 'iids' &&
              permit?.operation == 'setIncidentStatus' &&
              entry.value is List &&
              (entry.value as List).length == 1 &&
              (entry.value as List).every(
                (v) => v is String && RegExp(r'^[1-9][0-9]*$').hasMatch(v),
              );
          if (graph &&
              !incidentIids &&
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
              gid != 'gid://gitlab/User/${target?.userId}' &&
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

  Future<Map<String, Object?>> _readSnapshotRow(
    Mr7SnapshotSpec spec, {
    Map<String, Object?>? resource,
  }) async {
    final row = resource ?? await read(spec.path);
    if (spec.kind != Mr7SnapshotKind.workItem) return row;
    if (spec.fields.length != _mr7WorkItemFields.length ||
        !spec.fields.containsAll(_mr7WorkItemFields)) {
      throw const Mr7Refused('snapshotConfiguration');
    }
    final target = identity!;
    final gid = spec.workItemId;
    if (gid == null ||
        _mr7WorkItemPath(this, target, gid) != spec.path ||
        row['id'] != int.parse(gid.split('/').last) ||
        row['iid'] != int.parse(spec.path.split('/').last) ||
        row['project_id'] != target.projectId) {
      throw const Mr7Refused('snapshotIdentity');
    }
    final fields = await _mr7ReadWorkItem(this, target, gid, spec.fields);
    return {
      ...row,
      for (final f in spec.fields)
        if (fields.containsKey(f)) f: fields[f],
    }..removeWhere(
      (key, _) => spec.fields.contains(key) && !fields.containsKey(key),
    );
  }

  void _capturePreparedWorkItem(
    Object? body,
    Object? envelope,
    Mr7MutationPermit permit,
  ) {
    final target = identity!;
    final operation = _selectedGraphOperation(body);
    if (body is! Map || operation?.kind != 'query' || envelope is! Map) return;
    final errors = envelope['errors'];
    final data = envelope['data'];
    if (data is! Map ||
        (errors != null && (errors is! List || errors.isNotEmpty))) {
      return;
    }
    final vars = body['variables'] as Map? ?? const {};
    void bind(Object? raw, Object? requestedId, Object? requestedIid) {
      if (raw is! Map || raw['id'] is! String) return;
      final id = raw['id'] as String;
      if (requestedId != null && requestedId != id) {
        throw const Mr7Refused('noChangeTargetUnbound');
      }
      final path = _graphResources[id];
      if (path == null || !id.startsWith('gid://gitlab/WorkItem/')) return;
      _mr7WorkItemRecord(this, target, id, Map<String, Object?>.from(raw));
      if (requestedIid != null && requestedIid != raw['iid']) {
        throw const Mr7Refused('noChangeTargetUnbound');
      }
      final number = int.parse(id.split('/').last);
      if (permit._preparedParentIds.containsKey(path) &&
          permit._preparedParentIds[path] != number) {
        stop('noChangeTargetDrift');
        throw const Mr7Refused('noChangeTargetDrift');
      }
      permit._preparedParentIds[path] = number;
    }

    for (final entry in operation!.selections.entries) {
      final selection = entry.value;
      if (!entry.key.contains('/') && selection.field == 'workItem') {
        final args = operation.resolve(selection.arguments, vars) as Map;
        bind(data[entry.key], args['id'], null);
      }
      if (selection.field == 'issues' &&
          entry.key.split('/').length == 2 &&
          permit.operation == 'setIncidentStatus') {
        final ownerKey = entry.key.split('/').first;
        final ownerSelection = operation.selections[ownerKey];
        if (ownerSelection?.field != 'project') continue;
        final ownerArgs =
            operation.resolve(ownerSelection!.arguments, vars) as Map;
        final args = operation.resolve(selection.arguments, vars) as Map;
        final iids = args['iids'];
        final types = args['types'];
        final owner = data[ownerKey];
        final connection = _selectRecord(data, entry.key.split('/'));
        if (ownerArgs['fullPath'] != target.path ||
            owner is! Map ||
            owner['id'] != 'gid://gitlab/Project/${target.projectId}' ||
            iids is! List ||
            iids.length != 1 ||
            iids.single is! String ||
            !RegExp(r'^[1-9][0-9]*$').hasMatch(iids.single as String) ||
            types is! List ||
            types.length != 1 ||
            types.single != 'INCIDENT' ||
            args['first'] != 2 ||
            connection is! Map ||
            connection['nodes'] is! List ||
            (connection['nodes'] as List).length != 1 ||
            connection['pageInfo'] is! Map ||
            (connection['pageInfo'] as Map)['hasNextPage'] != false) {
          continue;
        }
        final issue = (connection['nodes'] as List).single;
        if (issue is! Map ||
            issue['id'] is! String ||
            !RegExp(
              r'^gid://gitlab/Issue/[1-9][0-9]*$',
            ).hasMatch(issue['id'] as String) ||
            issue['iid'] != iids.single ||
            issue['projectId'] != target.projectId) {
          continue;
        }
        final number = int.parse((issue['id'] as String).split('/').last);
        final gid = 'gid://gitlab/WorkItem/$number';
        final path = 'projects/${target.projectId}/issues/${iids.single}';
        if (_graphResources[gid] != path) continue;
        if (permit._preparedParentIds.containsKey(path) &&
            permit._preparedParentIds[path] != number) {
          stop('noChangeTargetDrift');
          throw const Mr7Refused('noChangeTargetDrift');
        }
        permit._preparedParentIds[path] = number;
      }
      if (selection.field == 'workItems' && entry.key.split('/').length == 2) {
        final ownerKey = entry.key.split('/').first;
        final ownerSelection = operation.selections[ownerKey];
        if (ownerSelection?.field != 'project') continue;
        final ownerArgs =
            operation.resolve(ownerSelection!.arguments, vars) as Map;
        final args = operation.resolve(selection.arguments, vars) as Map;
        final owner = data[ownerKey];
        final connection = _selectRecord(data, entry.key.split('/'));
        if (ownerArgs['fullPath'] != target.path ||
            owner is! Map ||
            owner['id'] != 'gid://gitlab/Project/${target.projectId}' ||
            owner['fullPath'] != target.path ||
            connection is! Map ||
            connection['nodes'] is! List ||
            (connection['nodes'] as List).length != 1 ||
            connection['pageInfo'] is! Map ||
            (connection['pageInfo'] as Map)['hasNextPage'] != false ||
            args['iid'] is! String) {
          continue;
        }
        bind((connection['nodes'] as List).single, null, args['iid']);
      }
    }
    if (!const {
      'editWorkItemActivityNote',
      'setWorkItemActivityNoteReaction',
    }.contains(permit.operation)) {
      return;
    }
    // Only an exact Note selection records preparation. Notes appearing in an
    // activity connection, earlier fixture bindings and observer reads do not.
    for (final entry in operation.selections.entries) {
      final selection = entry.value;
      if (entry.key.contains('/') || selection.field != 'note') continue;
      final capability = permit.operation == 'editWorkItemActivityNote'
          ? 'adminNote'
          : 'awardEmoji';
      final requiredSelections = {
        'id': 'id',
        'system': 'system',
        'internal': 'internal',
        'noteableType': 'noteableType',
        'noteableId': 'noteableId',
        'project/id': 'id',
        'project/fullPath': 'fullPath',
        'author/id': 'id',
        'userPermissions/$capability': capability,
      };
      if (requiredSelections.entries.any(
        (field) =>
            operation.selections['${entry.key}/${field.key}']?.field !=
            field.value,
      )) {
        continue;
      }
      final args = operation.resolve(selection.arguments, vars) as Map;
      final note = data[entry.key];
      final id = args['id'];
      if (id is! String ||
          !RegExp(r'^gid://gitlab/Note/[1-9][0-9]*$').hasMatch(id) ||
          note is! Map ||
          note['id'] != id) {
        continue;
      }
      final notePath = _graphResources[id];
      if (notePath == null) continue;
      final parent = notePath.split('/').take(4).join('/');
      final parentId = permit._preparedParentIds[parent];
      final project = note['project'];
      final author = note['author'];
      final permissions = note['userPermissions'];
      if (notePath != '$parent/notes/${id.split('/').last}' ||
          parentId == null ||
          _graphResources['gid://gitlab/WorkItem/$parentId'] != parent ||
          note['noteableType'] != 'Issue' ||
          note['noteableId'] != parentId ||
          note['system'] != false ||
          note['internal'] != false ||
          project is! Map ||
          project['id'] != 'gid://gitlab/Project/${target.projectId}' ||
          project['fullPath'] != target.path ||
          author is! Map ||
          author['id'] != 'gid://gitlab/User/${target.userId}' ||
          permissions is! Map ||
          permissions[capability] != true) {
        continue;
      }
      final prepared = (id: id, parentPath: parent);
      if (permit._preparedActivityNote != null &&
          permit._preparedActivityNote != prepared) {
        stop('noChangeTargetDrift');
        throw const Mr7Refused('noChangeTargetDrift');
      }
      permit._preparedActivityNote = prepared;
    }
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
          !spec._allowsPath(root) ||
          spec.fields.length > 32 ||
          !spec.fields.containsAll(spec.unchangedFields) ||
          spec.fields.any(
            (field) =>
                !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$').hasMatch(field),
          )) {
        throw const Mr7Refused('snapshotConfiguration');
      }
      final row = await _readSnapshotRow(spec);
      final id = row['id'];
      final iid = row['iid'];
      if (jsonEncode(row).length > 2 * 1024 * 1024) {
        throw const Mr7Refused('snapshotIdentity');
      }
      int? parentId;
      if (spec.kind == Mr7SnapshotKind.draftNote) {
        final parentPath = spec.path.split('/').take(4).join('/');
        final parent = await read(parentPath);
        if (parent['id'] is! int ||
            (parent['id'] as int) <= 0 ||
            parent['iid'] != int.parse(parentPath.split('/').last) ||
            parent['project_id'] != target.projectId) {
          throw const Mr7Refused('snapshotIdentity');
        }
        parentId = parent['id'] as int;
      }
      if (!_snapshotResourceIdentityMatches(
        spec,
        row,
        target,
        parentId: parentId,
      )) {
        throw const Mr7Refused('snapshotIdentity');
      }
      rows.add(
        _Mr7SnapshotRow(
          spec: spec,
          id: id as int,
          iid: iid is int ? iid : null,
          parentId: parentId,
          presentFields: Set.unmodifiable(spec.fields.where(row.containsKey)),
          identityDigests: Map.unmodifiable({
            for (final field in ['iid', 'global_id', 'gid'])
              field: _snapshotFieldDigest(row, field),
          }),
          digests: Map.unmodifiable({
            for (final field in spec.fields)
              field: _snapshotFieldDigest(row, field),
          }),
          values: Map.unmodifiable({
            for (final field in spec.fields)
              if (row.containsKey(field))
                field: jsonDecode(jsonEncode(row[field])),
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
                target.path,
              ))) {
        stop('snapshotDrift');
        throw const Mr7Refused('snapshotDrift');
      }
      final current = await _readSnapshotRow(saved.spec);
      var parentMatches = true;
      if (saved.parentId != null) {
        final parentPath = originalPath.split('/').take(4).join('/');
        final parent = await read(parentPath);
        parentMatches =
            parent['id'] == saved.parentId &&
            parent['iid'] == int.parse(parentPath.split('/').last) &&
            parent['project_id'] == target.projectId;
      }
      if (!parentMatches ||
          !_snapshotIdentityMatches(saved, current, target) ||
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

  Future<void> _prepareEffect(
    Mr7MutationPermit allowed,
    RequestOptions request,
  ) async {
    if (allowed.operation == 'playPipelineSchedule') {
      throw const Mr7Refused('scheduleParametersUnproven');
    }
    // Global suggestion routes require independent ownership even without an
    // effect witness. The flag controls baseline capture, never write authority.
    if (!allowed.captureEffects && allowed.operation != 'applySuggestion') {
      return;
    }
    final actor = await read('user');
    if (actor['id'] != identity!.userId ||
        actor['username'] != identity!.namespace) {
      stop('observerIdentity');
      throw const Mr7Refused('observerIdentity');
    }
    if (allowed.sent != 0) {
      if (allowed.operation == 'cancelAutoMerge') {
        final first = allowed._dispatches;
        final parent = allowed._effectBefore?['parent'];
        if (allowed.sent != 1 ||
            first.length != 1 ||
            parent is! String ||
            first.single.method != 'POST' ||
            first.single.path != '$parent/cancel_auto_merge' ||
            !const {404, 405}.contains(first.single.status) ||
            request.method != 'POST' ||
            _restSegments(request).join('/') !=
                '$parent/cancel_merge_when_pipeline_succeeds') {
          throw const Mr7Refused('observerLegacyCancel');
        }
      } else if (const {
        'deleteFile',
        'applySuggestion',
        'deleteBoardList',
        'publishDraftNotes',
        'playPipelineSchedule',
        'deleteProject',
      }.contains(allowed.operation)) {
        throw const Mr7Refused('observerMutationTarget');
      }
      return;
    }
    final root = 'projects/${identity!.projectId}';
    final segments = _restSegments(request);
    final path = segments.join('/');
    final b = request.data;
    Future<Map<String, Object?>> parent(String parentPath) async {
      final row = await _effectMap(observer, parentPath);
      if (row['id'] is! int ||
          (row['id'] as int) <= 0 ||
          row['project_id'] != identity!.projectId ||
          row['iid'] != int.tryParse(parentPath.split('/').last)) {
        throw const Mr7Refused('observerParent');
      }
      return row;
    }

    Future<String> head(String ref) async {
      final row = await _effectMap(
        observer,
        '$root/repository/branches/${Uri.encodeComponent(ref)}',
      );
      final commit = row['commit'];
      if (row['name'] != ref ||
          commit is! Map ||
          commit['id'] is! String ||
          !RegExp(
            r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$',
          ).hasMatch(commit['id'] as String)) {
        throw const Mr7Refused('observerRef');
      }
      return commit['id'] as String;
    }

    switch (allowed.operation) {
      case 'deleteFile':
        if (request.method != 'DELETE' ||
            segments.length != 5 ||
            segments[2] != 'repository' ||
            segments[3] != 'files' ||
            b is! Map ||
            b['branch'] is! String) {
          throw const Mr7Refused('observerMutationTarget');
        }
        final ref = b['branch'] as String;
        final sha = await head(ref);
        final file = await _effectMap(
          observer,
          '$root/repository/files/${Uri.encodeComponent(segments[4])}',
          query: {'ref': sha},
        );
        if (file['file_path'] != segments[4] ||
            file['commit_id'] != sha ||
            file['last_commit_id'] != b['last_commit_id']) {
          throw const Mr7Refused('observerContent');
        }
        allowed._effectBefore = {'path': segments[4], 'ref': ref, 'sha': sha};
      case 'applySuggestion':
        final a = allowed.preparedArguments ?? allowed.callArguments;
        if (a == null ||
            a['projectId'] != identity!.projectId ||
            a['iid'] is! int ||
            (a['iid'] as int) <= 0 ||
            a['noteId'] is! int ||
            (a['noteId'] as int) <= 0 ||
            a['suggestionId'] is! int ||
            (a['suggestionId'] as int) <= 0 ||
            a['discussionId'] is! String ||
            !RegExp(
              r'^[A-Za-z0-9_-]{1,128}$',
            ).hasMatch(a['discussionId'] as String) ||
            request.method != 'PUT' ||
            path != 'suggestions/${a['suggestionId']}/apply') {
          throw const Mr7Refused('observerMutationTarget');
        }
        final parentPath = '$root/merge_requests/${a['iid']}';
        final mr = await parent(parentPath);
        if (mr['source_project_id'] != identity!.projectId ||
            mr['source_branch'] is! String) {
          throw const Mr7Refused('observerParent');
        }
        final discussionPath = '$parentPath/discussions/${a['discussionId']}';
        final discussion = await _effectMap(observer, discussionPath);
        final selected = _suggestionIn(
          discussion,
          a['discussionId'] as String,
          a['noteId'] as int,
          a['suggestionId'] as int,
        );
        final suggestion = selected['suggestion'] as Map;
        final position = selected['position'] as Map;
        final refs = mr['diff_refs'];
        if (suggestion['appliable'] != true ||
            suggestion['applied'] != false ||
            suggestion['from_content'] is! String ||
            suggestion['to_content'] is! String ||
            refs is! Map ||
            mr['sha'] != refs['head_sha'] ||
            const [
              'base_sha',
              'start_sha',
              'head_sha',
            ].any((key) => position[key] != refs[key])) {
          throw const Mr7Refused('observerDiscussion');
        }
        if (!allowed.captureEffects) return;
        final filePath = position['new_path'] ?? position['old_path'];
        if (filePath is! String || filePath.isEmpty) {
          throw const Mr7Refused('observerContent');
        }
        final ref = mr['source_branch'] as String;
        final sha = await head(ref);
        if (sha != mr['sha']) throw const Mr7Refused('observerRef');
        final file = await _effectMap(
          observer,
          '$root/repository/files/${Uri.encodeComponent(filePath)}',
          query: {'ref': sha},
        );
        final from = suggestion['from_line'];
        final to = suggestion['to_line'];
        if (file['file_path'] != filePath ||
            file['commit_id'] != sha ||
            file['encoding'] != 'base64' ||
            file['content'] is! String ||
            from is! int ||
            to is! int ||
            from < 1 ||
            to < from) {
          throw const Mr7Refused('observerSuggestionRange');
        }
        final text = utf8.decode(base64Decode(file['content'] as String));
        final lines = RegExp(r'[^\n]*(?:\n|$)')
            .allMatches(text)
            .map((m) => m.group(0)!)
            .where((s) => s.isNotEmpty)
            .toList();
        if (text.contains('\r') ||
            to > lines.length ||
            lines.sublist(from - 1, to).join() != suggestion['from_content']) {
          throw const Mr7Refused('observerSuggestionRange');
        }
        final expected = utf8.encode(
          lines.take(from - 1).join() +
              (suggestion['to_content'] as String) +
              lines.skip(to).join(),
        );
        if (expected.length > 2 * 1024 * 1024) {
          throw const Mr7Refused('observerContent');
        }
        allowed._effectBefore = {
          'parent': parentPath,
          'parentId': mr['id'],
          'discussion': discussionPath,
          'discussionId': a['discussionId'],
          'noteId': a['noteId'],
          'suggestionId': a['suggestionId'],
          'path': filePath,
          'ref': ref,
          'sha': sha,
          'expectedBytesDigest': mr7Digest(expected),
          'positionDigest': mr7Digest(position),
        };
      case 'deleteBoardList':
        if (request.method != 'DELETE' ||
            segments.length != 6 ||
            segments[2] != 'boards' ||
            segments[4] != 'lists') {
          throw const Mr7Refused('observerMutationTarget');
        }
        final boardPath = segments.take(4).join('/');
        final board = await _effectMap(observer, boardPath);
        if (board['id'] != int.tryParse(segments[3])) {
          throw const Mr7Refused('observerParent');
        }
        final lists = await _effectRows(observer, '$boardPath/lists');
        final listId = int.tryParse(segments[5]);
        if (!lists.any((r) => r['id'] == listId)) {
          throw const Mr7Refused('observerAbsenceTarget');
        }
        allowed._effectBefore = {'boardId': board['id'], 'listId': listId};
      case 'publishDraftNotes':
        if (request.method != 'POST' ||
            segments.length != 6 ||
            segments[2] != 'merge_requests' ||
            segments[4] != 'draft_notes' ||
            segments[5] != 'bulk_publish') {
          throw const Mr7Refused('observerMutationTarget');
        }
        final parentPath = segments.take(4).join('/');
        final mr = await parent(parentPath);
        final drafts = await _effectRows(observer, '$parentPath/draft_notes');
        if (drafts.isEmpty ||
            drafts.length > 20 ||
            drafts.any(
              (r) =>
                  r['author_id'] != identity!.userId ||
                  r['merge_request_id'] != mr['id'] ||
                  r['note'] is! String ||
                  (r['discussion_id'] != null &&
                      (r['discussion_id'] is! String ||
                          (r['discussion_id'] as String).isEmpty)) ||
                  !_draftPositionSupported(r['position']),
            )) {
          throw const Mr7Refused('observerDrafts');
        }
        final notes = await _publicNotes(observer, parentPath, mr['id'] as int);
        final discussions = notes
            .map((r) => r['_discussion'])
            .whereType<String>()
            .toSet();
        if (drafts.any(
          (draft) =>
              draft['discussion_id'] != null &&
              !discussions.contains(draft['discussion_id']),
        )) {
          throw const Mr7Refused('observerDrafts');
        }
        allowed._effectBefore = {
          'parent': parentPath,
          'parentId': mr['id'],
          'drafts': drafts,
          'notes': notes.map((r) => r['id']).toList(),
          'discussions': discussions.toList(),
        };
      case 'cancelAutoMerge':
        if (segments.last == 'cancel_merge_when_pipeline_succeeds') {
          throw const Mr7Refused('observerLegacyCancel');
        }
        if (request.method == 'POST' &&
            segments.length == 5 &&
            segments[2] == 'merge_requests') {
          final parentPath = segments.take(4).join('/');
          final mr = await parent(parentPath);
          allowed._effectBefore = {
            'parent': parentPath,
            'parentId': mr['id'],
            'enabled':
                mr['auto_merge_enabled'] == true ||
                mr['merge_when_pipeline_succeeds'] == true,
          };
        }
      case 'deleteProject':
        if (request.method != 'DELETE' || path != root) {
          throw const Mr7Refused('observerMutationTarget');
        }
        final actor = await read('user');
        if (actor['id'] != identity!.userId ||
            actor['username'] != identity!.namespace) {
          throw const Mr7Refused('observerIdentity');
        }
        final inventory = await _projectEffectInventory();
        if (!inventory.any((r) => r['id'] == identity!.projectId)) {
          throw const Mr7Refused('observerProjectInventory');
        }
        allowed._effectBefore = {'projectId': identity!.projectId};
    }
    if (allowed._effectBefore != null) {
      allowed._effectBefore =
          _mr7FrozenJson(allowed._effectBefore) as Map<String, Object?>;
      await verifyIdentity();
      _open();
    }
  }

  Future<List<Map<String, Object?>>> _projectEffectInventory() async {
    _effectInventoryAllowed = true;
    try {
      final target = identity!;
      final rows = await _effectRows(
        observer,
        'users/${target.userId}/projects',
      );
      for (final row in rows) {
        final ns = row['namespace'];
        if (ns is! Map ||
            ns['id'] != target.namespaceId ||
            ns['kind'] != 'user' ||
            ns['full_path'] != target.namespace ||
            row['path_with_namespace'] is! String ||
            !(row['path_with_namespace'] as String).startsWith(
              '${target.namespace}/',
            )) {
          throw const Mr7Refused('observerProjectInventory');
        }
      }
      return rows;
    } finally {
      _effectInventoryAllowed = false;
    }
  }

  Future<void> beforeMutation(RequestOptions request) async {
    if (_terminalDeleteDispatched) {
      stop('terminalScenario');
      throw const Mr7Refused('terminalScenario');
    }
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
      final suggestionArgs = permit?.preparedArguments ?? permit?.callArguments;
      final scopedSuggestion =
          permit?.operation == 'applySuggestion' &&
          request.method == 'PUT' &&
          suggestionArgs?['projectId'] == target.projectId &&
          suggestionArgs?['suggestionId'] is int &&
          path == 'suggestions/${suggestionArgs!['suggestionId']}/apply';
      if (!graph &&
          !scopedSuggestion &&
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
        Object? b = request.data;
        if (graph) {
          try {
            b = jsonDecode(jsonEncode(b));
          } catch (_) {
            stop('unsealedGraph');
            throw const Mr7Refused('unsealedGraph');
          }
        }
        if (graph &&
            allowed != null &&
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
        await _prepareEffect(allowed, request);
        _requireBoundValues(
          graph && b is Map ? b['variables'] : b,
          graph: graph,
        );
        if (graph && b is Map) {
          _requireGraphTargets(b);
          await _refreshGraphResources(b['variables']);
          if (allowed.operation == 'setIncidentStatus') {
            final input = _mr7MutationInput(b, 'issueSetEscalationStatus');
            final iid = input['iid'];
            final parentPath = 'projects/${target.projectId}/issues/$iid';
            final owners = _graphResources.entries.where(
              (e) =>
                  e.value == parentPath &&
                  e.key.startsWith('gid://gitlab/WorkItem/'),
            );
            if (input['projectPath'] != target.path ||
                iid is! String ||
                !RegExp(r'^[1-9][0-9]*$').hasMatch(iid) ||
                owners.length != 1) {
              throw const Mr7Refused('incidentSelector');
            }
            await bindWorkItemGraphResource(
              owners.single.key,
              path: parentPath,
            );
          }
          if (allowed.operation == 'deleteWorkItemActivityNote') {
            final input = _mr7MutationInput(b, 'destroyNote');
            final noteId = input['id'];
            final notePath = _graphResources[noteId];
            if (noteId is! String ||
                notePath == null ||
                !RegExp(
                  '^projects/${target.projectId}/issues/[1-9][0-9]*/notes/[1-9][0-9]*\$',
                ).hasMatch(notePath)) {
              throw const Mr7Refused('observerNoteOwnership');
            }
            final parentPath = notePath.split('/').take(4).join('/');
            final parent = await read(parentPath);
            final note = await read(notePath);
            final author = note['author'];
            if (parent['project_id'] != target.projectId ||
                parent['iid'] != int.parse(parentPath.split('/').last) ||
                _graphResources['gid://gitlab/WorkItem/${parent['id']}'] !=
                    parentPath ||
                note['id'] != int.parse(noteId.split('/').last) ||
                note['project_id'] != target.projectId ||
                note['noteable_id'] != parent['id'] ||
                author is! Map ||
                author['id'] != target.userId ||
                note['system'] != false ||
                note['internal'] != false) {
              throw const Mr7Refused('observerNoteOwnership');
            }
            allowed._ownedActivityNoteAtSend = noteId;
          }
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
          allowed._todoParentId = parent['id'] as int;
          final before = await _projectTodoList(
            observer,
            'projects/${target.projectId}/todos/mr7-observation',
            target,
          );
          allowed._todoIdsBefore = Set.unmodifiable(
            before.map((row) => row['id']! as int),
          );
          final finalActor = await read('user');
          final finalParent = await read(segments.take(4).join('/'));
          if (finalActor['id'] != target.userId ||
              finalActor['username'] != target.namespace ||
              finalParent['id'] != allowed._todoParentId ||
              finalParent['iid'] != int.parse(segments[3]) ||
              finalParent['project_id'] != target.projectId) {
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
      if (!_setupAuthorized &&
          !_cleanupAuthorized &&
          permit?.scenarioId != null)
        'scenarioId': permit!.scenarioId,
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
