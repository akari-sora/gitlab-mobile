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
const mr7ExcludedOperations = {
  'createProject',
  'forkProject',
  'markAllTodosDone',
  'batchApplySuggestions',
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
/// Fragments, directives, defaults and block strings are refused rather than
/// skipped: hidden argument usage must never bypass the sandbox scope checks.
final class _GraphParser {
  _GraphParser(String source) {
    if (source.length > 65536) throw const Mr7Refused('graphDocument');
    final token = RegExp(
      r'[A-Za-z_][A-Za-z_0-9]*|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|"(?:\\.|[^"\\\r\n])*"|[!$():{}\[\]]',
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

  bool _selection(_GraphOperation operation, int depth) {
    if (depth > 32) throw const Mr7Refused('graphDocument');
    _expect('{');
    var count = 0;
    var identityOnly = true;
    while (!_take('}')) {
      var field = _name();
      if (_take(':')) field = _name();
      operation.fields.add(field);
      var arguments = <String, Object?>{};
      if (_take('(')) {
        arguments = _pairs(')', 0);
        if (arguments.isEmpty) throw const Mr7Refused('graphDocument');
        operation.arguments.add(arguments);
      }
      final childProjection = _peek == '{'
          ? _selection(operation, depth + 1)
          : null;
      if (depth == 0) {
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
      if (!session._setupAuthorized && !session._cleanupAuthorized) {
        session.permit!.sent++;
      }
      dispatched = true;
      final response = await session.server.respond(options);
      if (response.statusCode >= 500 ||
          (response.statusCode >= 300 && response.statusCode < 400)) {
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
  });
  final Mr7SandboxSession _session;
  final Mr7Identity _identity;
  final Mr7MutationPermit _permit;
  final Set<String> paths;
  int verifiedRequests = 0;

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
                (_permit.returnedIid ?? returnedId))) {
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
    _open();
    final match = RegExp(
      r'^gid://gitlab/([A-Za-z]+)/([1-9][0-9]*)$',
    ).firstMatch(gid);
    final target = identity;
    if (match == null || target == null || match[1] == 'Group') {
      throw const Mr7Refused('graphResource');
    }
    final root = 'projects/${target.projectId}';
    const resourcePaths = {
      'Issue': r'issues/[1-9][0-9]*',
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
      if (operation.fields.any(
        const {'group', 'groups', 'namespace', 'namespaces'}.contains,
      )) {
        throw const Mr7Refused('foreignResource');
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
              (key == 'id' || key == 'workitemid' || key == 'targetid') &&
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
          r'\b(?:id|projectId|groupId|fullPath|projectPath)\s*:\s*["0-9]',
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
        await bindGraphResource(entry.key, path: entry.value);
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

  Future<void> verifyIdentity() async {
    final expected = identity;
    _open();
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
    _open();
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
            mr7ExcludedOperations.contains(allowed.operation) ||
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
