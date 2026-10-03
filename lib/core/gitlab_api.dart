import 'dart:async';
import 'dart:convert';
import 'dart:io' show FileSystemException, HttpDate, IOException, IOSink;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'failure.dart';
import 'analytics_models.dart';
import 'instance.dart';
import 'models.dart';
import 'oauth.dart';
import 'pagination.dart';
import 'registry_models.dart';
import 'snippet_models.dart';
import 'upload_names.dart';
import 'work_item_activity_models.dart';
import 'work_item_assignee_models.dart';
import 'work_item_attribute_models.dart';
import 'work_item_graph_models.dart';
import 'work_item_milestone_models.dart';
import 'work_item_weight_models.dart';
import 'work_item_state_models.dart';

part 'workspace_api.dart';
part 'incident_api.dart';
part 'analytics_api.dart';
part 'package_download_api.dart';
part 'snippet_graphql_api.dart';
part 'work_item_graphql_api.dart';
part 'work_item_attributes_api.dart';
part 'work_item_activity_api.dart';
part 'work_item_note_delete_api.dart';
part 'work_item_note_reactions_api.dart';
part 'work_item_notifications_api.dart';
part 'work_item_content_api.dart';
part 'work_item_milestone_api.dart';
part 'work_item_weight_api.dart';
part 'work_item_assignee_api.dart';
part 'work_item_state_api.dart';

final _artifactCancelled = Object();
const _artifactRedirects = {301, 302, 303, 307, 308};

/// Bytes saved from `GET /projects/:id/jobs/:job_id/artifacts`.
final class ArtifactDownload {
  const ArtifactDownload({
    required this.fileName,
    required this.bytesWritten,
    required this.contentType,
  });
  final String fileName;
  final int bytesWritten;
  final String? contentType;
}

String _artifactFileName(String? header, int job) {
  final parsed = header == null ? null : _contentDispositionName(header);
  final safe = _singlePathSegment(parsed);
  return safe ?? 'artifacts-$job.zip';
}

String? _singlePathSegment(String? name) {
  if (name == null) return null;
  final base = name.trim().split(RegExp(r'[\\/]')).last.trim();
  if (base.isEmpty ||
      base == '.' ||
      base == '..' ||
      base == '.partial' ||
      base == '.download.partial' ||
      base.contains('\u0000')) {
    return null;
  }
  return base;
}

String? _contentDispositionName(String header) {
  final star = RegExp(
    "filename\\*\\s*=\\s*[^']*'[^']*'([^;]+)",
    caseSensitive: false,
  ).firstMatch(header);
  if (star != null) {
    final encoded = star.group(1)!.trim();
    try {
      return Uri.decodeComponent(encoded);
    } on FormatException {
      return encoded;
    } on ArgumentError {
      return encoded;
    }
  }
  final quoted = RegExp(
    'filename\\s*=\\s*"([^"]*)"',
    caseSensitive: false,
  ).firstMatch(header);
  if (quoted != null) return quoted.group(1);
  final plain = RegExp(
    'filename\\s*=\\s*([^";\\s]+)',
    caseSensitive: false,
  ).firstMatch(header);
  return plain?.group(1)?.trim();
}

/// Absolute https URL with no userinfo. Relative, http, and credentialed
/// locations are refused so a redirect cannot receive the account credential.
Uri? _secureArtifactLocation(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.isAbsolute || uri.scheme != 'https') return null;
  if (uri.userInfo.isNotEmpty || uri.host.isEmpty) return null;
  return uri;
}

enum ProjectScope { member, starred, accessibleSearch }

/// One immutable account owns this client. Writes are never automatically retried.
final class GitLabApi {
  GitLabApi({
    required this.instance,
    String? token,
    AccountCredential? credential,
    Dio? dio,
    HttpClientAdapter? cdnAdapter,
    OAuthTokenClient? oauth,
    Future<void> Function(OAuthCredential rotated)? onOAuthRotated,
    DateTime Function()? readCacheClock,
  }) : _credential = credential ?? PatCredential(token ?? ''),
       _dio = dio ?? Dio(),
       _cdnAdapter = cdnAdapter,
       _oauth = oauth,
       _readCacheClock = readCacheClock ?? DateTime.now,
       _onOAuthRotated = onOAuthRotated {
    final access = _credential.accessToken;
    if (access.trim().isEmpty || RegExp(r'\s').hasMatch(access)) {
      throw const FormatException('Token 不可空白或包含空白字元。');
    }
    if (_credential is OAuthCredential) {
      final refresh = (_credential as OAuthCredential).refreshToken;
      if (refresh.trim().isEmpty || RegExp(r'\s').hasMatch(refresh)) {
        throw const FormatException('Token 不可空白或包含空白字元。');
      }
    }
    _dio.options.connectTimeout = const Duration(seconds: 15);
    _dio.options.receiveTimeout = const Duration(seconds: 25);
    _dio.options.sendTimeout = const Duration(seconds: 15);
  }
  final GitLabInstance instance;
  AccountCredential _credential;
  AccountCredential get credential => _credential;
  final Dio _dio;
  final HttpClientAdapter? _cdnAdapter;
  final OAuthTokenClient? _oauth;
  final DateTime Function() _readCacheClock;
  final Future<void> Function(OAuthCredential rotated)? _onOAuthRotated;
  Future<void>? _refreshing;
  final _readCache = <String, _CachedRead>{};
  final _readInFlight = <String, Future<Object>>{};
  int _readEpoch = 0, _readCacheBytes = 0, _writesInFlight = 0;
  static const maxCachedReads = 32;
  static const maxCachedReadBytes = 6 * 1024 * 1024;
  final Set<CancelToken> _requests = {};
  final Set<Dio> _bareClients = {};
  bool _closed = false;
  DateTime? _retryAt;
  static const maxTextBytes = 2 * 1024 * 1024;
  static const maxTextLines = 20000;
  static const maxUploadBytes = 25 * 1024 * 1024;
  static const maxArtifactBytes = 256 * 1024 * 1024;

  /// In-memory only, owned by this account client. Refresh and mutations discard
  /// both cached values and sharing gates, so older reads cannot refill them.
  void clearReadCache() {
    _readEpoch++;
    _readCache.clear();
    _readCacheBytes = 0;
    _readInFlight.clear();
  }

  Future<T> _cachedRead<T extends Object>(
    String key,
    Future<_CacheRead<T>> Function() load, {
    required int Function(T) cost,
    bool refresh = false,
    int invalidationRetries = 0,
  }) async {
    if (_closed) throw const ApiFailure(FailureKind.cancelled);
    if (refresh) clearReadCache();
    final cached = _readCache.remove(key);
    if (cached != null) {
      _readCacheBytes -= cached.cost;
      if (_readCacheClock().isBefore(cached.expires)) {
        _readCache[key] = cached;
        _readCacheBytes += cached.cost;
        return cached.value as T;
      }
    }
    final pending = _readInFlight[key];
    if (pending != null) return await pending as T;
    final epoch = _readEpoch;
    late final Future<T> request;
    request = () async {
      try {
        final loaded = await load();
        if (_closed) throw const ApiFailure(FailureKind.cancelled);
        if (_writesInFlight != 0) throw const ApiFailure(FailureKind.cancelled);
        if (epoch != _readEpoch) {
          if (invalidationRetries >= 1) throw const ApiFailure(FailureKind.cancelled);
          return await _cachedRead(key, load, cost: cost,
            invalidationRetries: invalidationRetries + 1);
        }
        final value = loaded.value;
        final bytes = 128 + key.length * 2 + cost(value);
        if (epoch == _readEpoch &&
            _writesInFlight == 0 &&
            loaded.ttl > Duration.zero &&
            bytes <= maxCachedReadBytes) {
          final previous = _readCache.remove(key);
          if (previous != null) _readCacheBytes -= previous.cost;
          _readCache[key] = _CachedRead(
            value,
            _readCacheClock().add(loaded.ttl),
            bytes,
          );
          _readCacheBytes += bytes;
          while (_readCache.length > maxCachedReads ||
              _readCacheBytes > maxCachedReadBytes) {
            _readCacheBytes -= _readCache.remove(_readCache.keys.first)!.cost;
          }
        }
        return value;
      } finally {
        if (identical(_readInFlight[key], request)) {
          unawaited(_readInFlight.remove(key));
        }
      }
    }();
    unawaited(_readInFlight[key] = request);
    return await request;
  }

  Duration _cacheTtl(Headers headers, Duration maximum) {
    final directives = (headers.value('cache-control') ?? '').toLowerCase().split(',').map((v) => v.trim());
    var ttl = maximum;
    var mustRevalidate = false, explicitFreshness = false;
    for (final directive in directives) {
      final name = directive.split('=').first;
      if (const {'no-store', 'no-cache'}.contains(name)) return Duration.zero;
      if (name == 'must-revalidate') mustRevalidate = true;
      if (name == 'max-age') {
        explicitFreshness = true;
        final seconds = int.tryParse(directive.split('=').last.replaceAll('"', ''));
        if (seconds == null || seconds <= 0) return Duration.zero;
        final age = int.tryParse(headers.value('age') ?? '') ?? 0;
        final allowed = Duration(seconds: seconds - age);
        if (allowed < ttl) ttl = allowed;
      }
    }
    final expires = headers.value('expires');
    if (expires != null) {
      explicitFreshness = true;
      try {
        final allowed = HttpDate.parse(expires).difference(_readCacheClock());
        if (allowed < ttl) ttl = allowed;
      } on FormatException { return Duration.zero; }
    }
    if (mustRevalidate && !explicitFreshness) return Duration.zero;
    return ttl > Duration.zero ? ttl : Duration.zero;
  }

  Map<String, String> get _authHeaders => switch (_credential) {
    PatCredential(:final token) => {
      'PRIVATE-TOKEN': token,
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
    },
    OAuthCredential(:final accessToken) => {
      'Authorization': 'Bearer $accessToken',
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
    },
  };

  Future<({Uint8List bytes, Headers headers, int statusCode})> _read(
    Uri uri, {
    String method = 'GET',
    Object? data,
    int maxBytes = 4 * 1024 * 1024,
    bool retried = false,
    Map<String, String>? headers,
    bool allowRangeNotSatisfiable = false,
    bool graphQuery = false,
  }) => _send(
    uri,
    method: method,
    data: data,
    maxBytes: maxBytes,
    retried: retried,
    headers: headers,
    allowRangeNotSatisfiable: allowRangeNotSatisfiable,
    graphQuery: graphQuery,
  );

  /// Shared request path for JSON calls and multipart uploads.
  /// JSON content-type is applied only when [data] is present and is not [FormData].
  Future<({Uint8List bytes, Headers headers, int statusCode})> _send(
    Uri uri, {
    String method = 'GET',
    Object? data,
    int maxBytes = 4 * 1024 * 1024,
    bool retried = false,
    Map<String, String>? headers,
    bool allowRangeNotSatisfiable = false,
    bool graphQuery = false,
    bool graphMutation = false,
  }) async {
    if (_closed) throw const ApiFailure(FailureKind.cancelled);
    if ((graphQuery && graphMutation) || (graphQuery || graphMutation
        ? method != 'POST' || !instance.allowsGraphQL(uri)
        : !instance.allowsApi(uri))) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final until = _retryAt;
    if (until != null && DateTime.now().isBefore(until)) {
      throw ApiFailure(FailureKind.rateLimited, status: 429, retryAt: until);
    }
    final cancel = CancelToken();
    _requests.add(cancel);
    // Only private, fixed GraphQL queries use this read path. POST mutations
    // retain the write fences and are never retried automatically.
    final writing = method != 'GET' && method != 'HEAD' && !graphQuery;
    if (writing) {
      _writesInFlight++;
      clearReadCache();
    }
    try {
      final response = await _dio.requestUri<ResponseBody>(
        uri,
        data: data,
        cancelToken: cancel,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          contentType: data == null || data is FormData
              ? null
              : Headers.jsonContentType,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (s) => s != null,
          headers: {
            ...(graphQuery || graphMutation)
                ? {
                    'Authorization': 'Bearer ${_credential.accessToken}',
                    'Accept': 'application/json',
                    'Cache-Control': 'no-store',
                  }
                : _authHeaders,
            ...?headers,
          },
        ),
      );
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
      final status = response.statusCode ?? 0;
      final body = response.data;
      if (allowRangeNotSatisfiable && status == 416) {
        if (body != null) await body.stream.listen((_) {}).cancel();
        return (
          bytes: Uint8List(0),
          headers: response.headers,
          statusCode: 416,
        );
      }
      if (status < 200 || status >= 300) {
        if (status == 401 || status == 403 || status == 404) clearReadCache();
        if (body != null) await body.stream.listen((_) {}).cancel();
        if (status == 401 && !retried && await _refreshOAuth()) {
          if (method == 'GET' || method == 'HEAD' || graphQuery) {
            return await _read(
              uri,
              method: method,
              data: data,
              maxBytes: maxBytes,
              retried: true,
              headers: headers,
              allowRangeNotSatisfiable: allowRangeNotSatisfiable,
              graphQuery: graphQuery,
            );
          }
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        if (status == 429) {
          final text = response.headers.value('retry-after');
          final seconds = int.tryParse(text ?? '');
          if (seconds != null && seconds >= 0) {
            _retryAt = DateTime.now().add(Duration(seconds: seconds));
          } else if (text != null) {
            try {
              _retryAt = HttpDate.parse(text);
            } on FormatException {
              /* manual retry only */
            }
          }
        }
        throw ApiFailure.fromStatus(status, retryAt: _retryAt);
      }
      if (method == 'HEAD' || status == 204) {
        if (body != null) await body.stream.listen((_) {}).cancel();
        return (
          bytes: Uint8List(0),
          headers: response.headers,
          statusCode: status,
        );
      }
      if (body == null) {
        throw ApiFailure(writing
            ? FailureKind.writeUncertain
            : FailureKind.invalidResponse);
      }
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (length != null && length > maxBytes) {
        await body.stream.listen((_) {}).cancel();
        throw ApiFailure(writing
            ? FailureKind.writeUncertain
            : FailureKind.tooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      try {
        await for (final chunk in body.stream) {
          if (_closed) throw const ApiFailure(FailureKind.cancelled);
          if (bytes.length + chunk.length > maxBytes) {
            cancel.cancel('response budget exceeded');
            throw ApiFailure(writing
                ? FailureKind.writeUncertain
                : FailureKind.tooLarge);
          }
          bytes.add(chunk);
        }
      } on ApiFailure {
        rethrow;
      } catch (_) {
        throw ApiFailure(writing
            ? FailureKind.writeUncertain
            : FailureKind.network);
      }
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
      return (
        bytes: bytes.takeBytes(),
        headers: response.headers,
        statusCode: status,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel || _closed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw ApiFailure(
        method == 'GET' || method == 'HEAD' || graphQuery
            ? FailureKind.network
            : FailureKind.writeUncertain,
      );
    } finally {
      _requests.remove(cancel);
      if (writing) {
        _writesInFlight--;
        clearReadCache();
      }
    }
  }

  Future<Map<String, dynamic>> _object(
    Uri uri, {
    String method = 'GET',
    Object? data,
  }) async {
    final result = await _read(uri, method: method, data: data);
    try {
      return objectJson(jsonDecode(utf8.decode(result.bytes)));
    } on FormatException {
      // A successful mutation can have taken effect despite an unreadable
      // acknowledgement. The editor must keep its pending-write fence.
      throw ApiFailure(method == 'GET' || method == 'HEAD'
          ? FailureKind.invalidResponse
          : FailureKind.writeUncertain);
    }
  }

  /// Actual job dependencies, rather than inferred REST stage relationships.
  /// Fixed query, no mutations, no caching, and no partial GraphQL success.
  Future<Map<String, dynamic>> pipelineGraphPage(
    Project project,
    int pipelineId, {
    String? after,
  }) async {
    if (pipelineId <= 0 ||
        project.id <= 0 ||
        project.path.isEmpty ||
        (after != null && (after.isEmpty || after.length > 4096))) {
      throw const ApiFailure(FailureKind.validation);
    }
    const query = r'''
query MobilePipelineGraph($path: ID!, $pipeline: CiPipelineID!, $after: String) {
  project(fullPath: $path) {
    id
    pipeline(id: $pipeline) {
      id iid
      stages(first: 100) { nodes { name } pageInfo { hasNextPage } }
      jobs(first: 20, after: $after) {
        nodes {
          id name status kind retried schedulingType stage { name }
          needs(first: 100) {
            nodes { name }
            pageInfo { hasNextPage endCursor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
''';
    try {
      final response = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': query,
          'variables': {
            'path': project.path,
            'pipeline': 'gid://gitlab/Ci::Pipeline/$pipelineId',
            'after': after,
          },
        },
      );
      final envelope = objectJson(jsonDecode(utf8.decode(response.bytes)));
      final errors = envelope['errors'];
      if (errors != null) {
        if (errors is! List) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
        if (errors.isNotEmpty) {
          final incompatible = errors.every(
            (error) =>
                error is Map &&
                error['extensions'] is Map &&
                const {
                  'undefinedField',
                  'undefinedArgument',
                  'variableRequiresValidType',
                  'argumentLiteralsIncompatible',
                  'missingRequiredArguments',
                }.contains((error['extensions'] as Map)['code']),
          );
          throw ApiFailure(
            incompatible
                ? FailureKind.unsupported
                : FailureKind.invalidResponse,
            title: incompatible ? '實例未提供工作相依圖' : null,
            detail: incompatible
                ? '這個 GitLab 版本未提供所需欄位。仍可從工作分頁查看工作與 Log。'
                : null,
          );
        }
      }
      final data = objectJson(envelope['data']);
      if (data['project'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final remoteProject = objectJson(data['project']);
      if (remoteProject['id'] != 'gid://gitlab/Project/${project.id}') {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (remoteProject['pipeline'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final pipeline = objectJson(remoteProject['pipeline']);
      if (pipeline['id'] != 'gid://gitlab/Ci::Pipeline/$pipelineId') {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (pipeline['jobs'] == null || pipeline['stages'] == null) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      return pipeline;
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  Future<ApiPage<T>> _page<T>(
    Uri uri,
    T Function(Map<String, dynamic>) parse,
  ) async {
    try {
      final result = await _read(uri);
      final data = jsonDecode(utf8.decode(result.bytes));
      if (data is! List<dynamic>) throw const FormatException('Expected array');
      return ApiPage(
        List.unmodifiable(data.map((j) => parse(objectJson(j)))),
        next: nextPageUri(
          instance: instance,
          current: uri,
          headers: result.headers.map,
        ),
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  Future<GitLabUser> currentUser() async =>
      GitLabUser.fromJson(await _object(instance.api(['user'])));

  Future<ApiPage<Project>> projects({
    required ProjectScope scope,
    String search = '',
    Uri? next,
  }) {
    final query = <String, String>{
      'per_page': '30',
      'order_by': 'last_activity_at',
      'sort': 'desc',
    };
    if (scope == ProjectScope.member) query['membership'] = 'true';
    if (scope == ProjectScope.starred) query['starred'] = 'true';
    if (search.trim().isNotEmpty) query['search'] = search.trim();
    final first = instance.api(['projects'], query);
    _validateContinuation(first, next);
    return _page(next ?? first, Project.fromJson);
  }

  Future<Project> project(String idOrFullPath, {bool refresh = false}) =>
      _cachedRead(
        'project:$idOrFullPath',
        () async {
          final result = await _read(instance.api(['projects', idOrFullPath]),
            headers: {'Cache-Control': 'max-age=0'});
          try {
            return _CacheRead(Project.fromJson(objectJson(jsonDecode(utf8.decode(result.bytes)))),
              _cacheTtl(result.headers, const Duration(seconds: 30)));
          } on FormatException { throw const ApiFailure(FailureKind.invalidResponse); }
        },
        cost: (p) =>
            256 +
            2 *
                (p.name.length +
                    p.path.length +
                    (p.description?.length ?? 0) +
                    (p.visibility?.length ?? 0) +
                    (p.defaultBranch?.length ?? 0) +
                    (p.markedForDeletionOn?.length ?? 0)),
        refresh: refresh,
      );

  Future<String> defaultBranchSha(Project project) async {
    final branch = project.defaultBranch;
    if (branch == null || branch.isEmpty) {
      throw const ApiFailure(FailureKind.invisible);
    }
    final j = await _object(
      instance.api([
        'projects',
        '${project.id}',
        'repository',
        'branches',
        branch,
      ]),
    );
    final sha = requiredString(objectJson(j['commit']), 'id');
    if (!RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(sha)) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    return sha;
  }

  Future<ApiPage<TreeEntry>> tree(
    int projectId,
    String sha, {
    String path = '',
    Uri? next,
  }) {
    final first = instance.api(
      ['projects', '$projectId', 'repository', 'tree'],
      {'ref': sha, 'path': path, 'per_page': '50'},
    );
    _validateContinuation(first, next);
    return _page(next ?? first, TreeEntry.fromJson);
  }

  void _validateContinuation(Uri first, Uri? next) {
    if (next == null) return;
    if (!instance.allowsApi(next) || next.path != first.path) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    for (final e in first.queryParameters.entries) {
      if (paginationKeys.contains(e.key)) continue;
      if (next.queryParameters[e.key] != e.value) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
    }
    if (next.queryParameters.keys.any(
      (k) =>
          !first.queryParameters.containsKey(k) && !paginationKeys.contains(k),
    )) {
      throw const ApiFailure(FailureKind.unsupported);
    }
  }

  Future<String> textFile(
    int projectId,
    String sha,
    String filePath, {
    bool refresh = false,
  }) {
    if (!RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(sha)) {
      return _readTextFile(projectId, sha, filePath).then((read) => read.value);
    }
    return _cachedRead(
      instance
          .api(
            ['projects', '$projectId', 'repository', 'files', filePath],
            {'ref': sha},
          )
          .toString(),
      () => _readTextFile(projectId, sha, filePath),
      cost: (text) => text.length * 2,
      refresh: refresh,
    );
  }

  Future<_CacheRead<String>> _readTextFile(int projectId, String sha, String filePath) async {
    final segments = [
      'projects',
      '$projectId',
      'repository',
      'files',
      filePath,
    ];
    final meta = await _read(
      instance.api(segments, {'ref': sha}),
      method: 'HEAD',
      headers: {'Cache-Control': 'max-age=0'},
    );
    final size = int.tryParse(meta.headers.value('x-gitlab-size') ?? '');
    if (size != null && size > maxTextBytes) {
      throw const ApiFailure(FailureKind.tooLarge);
    }
    final result = await _read(
      instance.api([...segments, 'raw'], {'ref': sha, 'lfs': 'false'}),
      maxBytes: maxTextBytes,
      headers: {'Cache-Control': 'max-age=0'},
    );
    if (result.bytes.contains(0)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    try {
      final text = utf8.decode(result.bytes);
      if ('\n'.allMatches(text).length + 1 > maxTextLines) {
        throw const ApiFailure(FailureKind.tooLarge);
      }
      final metaTtl = _cacheTtl(meta.headers, const Duration(minutes: 5));
      final rawTtl = _cacheTtl(result.headers, const Duration(minutes: 5));
      return _CacheRead(text, metaTtl < rawTtl ? metaTtl : rawTtl);
    } on FormatException {
      throw const ApiFailure(FailureKind.unsupported);
    }
  }

  Future<bool> _refreshOAuth() async {
    final current = _credential;
    final oauth = _oauth;
    if (current is! OAuthCredential || oauth == null) return false;
    final pending = _refreshing;
    if (pending != null) {
      await pending;
      return _credential is OAuthCredential &&
          (_credential as OAuthCredential).accessToken != current.accessToken;
    }
    final gate = () async {
      final rotated = await oauth.refresh(current);
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
      clearReadCache();
      _credential = current.replacedBy(rotated);
      await _onOAuthRotated?.call(_credential as OAuthCredential);
    }();
    _refreshing = gate;
    try {
      await gate;
      return true;
    } on ApiFailure {
      return false;
    } finally {
      if (identical(_refreshing, gate)) _refreshing = null;
    }
  }

  /// Downloads the job archive. The first hop is authenticated and never follows
  /// redirects. A single https `Location` is fetched once without
  /// `Authorization`, `PRIVATE-TOKEN`, or `Cookie`. [sink] is closed when the
  /// streamed body exceeds [maxBytes]; the caller closes it after success.
  Future<ArtifactDownload> downloadJobArtifacts(
    int project,
    int job, {
    required IOSink sink,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
    int maxBytes = maxArtifactBytes,
  }) {
    final result = Completer<ArtifactDownload>();
    // Dio can add a stream error after the subscription is cancelled. That
    // error is uncaught unless this zone owns both the request and the escape.
    runZonedGuarded(() {
      _downloadJobArtifacts(
        project,
        job,
        sink: sink,
        onProgress: onProgress,
        cancel: cancel,
        maxBytes: maxBytes,
      ).then((value) {
        if (!result.isCompleted) result.complete(value);
      }, onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) {
          result.completeError(_artifactEscape(error), stack);
        }
      });
    }, (Object error, StackTrace stack) {
      if (!result.isCompleted) {
        result.completeError(_artifactEscape(error), stack);
      }
    });
    return result.future;
  }

  Object _artifactEscape(Object error) {
    if (error is ApiFailure) return error;
    if (_closed) return const ApiFailure(FailureKind.cancelled);
    if (error is DioException && error.type == DioExceptionType.cancel) {
      return const ApiFailure(FailureKind.cancelled);
    }
    return error;
  }

  Future<ArtifactDownload> _downloadJobArtifacts(
    int project,
    int job, {
    required IOSink sink,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
    int maxBytes = maxArtifactBytes,
  }) async {
    if (_closed) throw const ApiFailure(FailureKind.cancelled);
    final until = _retryAt;
    if (until != null && DateTime.now().isBefore(until)) {
      throw ApiFailure(FailureKind.rateLimited, status: 429, retryAt: until);
    }
    final uri = instance.api([
      'projects',
      '$project',
      'jobs',
      '$job',
      'artifacts',
    ]);
    if (!instance.allowsApi(uri)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final token = CancelToken();
    _requests.add(token);
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          if (!token.isCancelled) token.cancel('artifact download aborted');
        }),
      );
    }
    try {
      final first = await _artifactResponse(uri, token, authenticated: true);
      return await _consumeArtifact(
        response: first,
        requestUri: uri,
        allowRedirect: true,
        allowRefresh: true,
        token: token,
        job: job,
        sink: sink,
        maxBytes: maxBytes,
        onProgress: onProgress,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel || _closed || token.isCancelled) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    } on ApiFailure {
      rethrow;
    } catch (_) {
      // close() can surface a raw stream error after the Dio wrapper is gone.
      if (_closed || token.isCancelled) throw const ApiFailure(FailureKind.cancelled);
      rethrow;
    } finally {
      _requests.remove(token);
    }
  }

  /// Downloads a project upload to [sink].
  ///
  /// Official API: `GET /api/v4/projects/:id/uploads/:secret/:filename` (GitLab 17.4+).
  /// Redirects are NEVER followed (throws [FailureKind.redirectBlocked]).
  /// Enforces [maxBytes] (default 4 MiB) through Content-Length pre-check
  /// and stream accumulation.
  Future<ArtifactDownload> downloadProjectUpload(
    int project,
    String secret,
    String filename, {
    required IOSink sink,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
    int maxBytes = 4 * 1024 * 1024,
  }) {
    final result = Completer<ArtifactDownload>();
    runZonedGuarded(() {
      _downloadProjectUpload(
        project,
        secret,
        filename,
        sink: sink,
        onProgress: onProgress,
        cancel: cancel,
        maxBytes: maxBytes,
      ).then((value) {
        if (!result.isCompleted) result.complete(value);
      }, onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) {
          result.completeError(_artifactEscape(error), stack);
        }
      });
    }, (Object error, StackTrace stack) {
      if (!result.isCompleted) {
        result.completeError(_artifactEscape(error), stack);
      }
    });
    return result.future;
  }

  Future<ArtifactDownload> _downloadProjectUpload(
    int project,
    String secret,
    String filename, {
    required IOSink sink,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
    int maxBytes = 4 * 1024 * 1024,
  }) async {
    if (!projectUploadNamesOk(secret, filename)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    if (_closed) throw const ApiFailure(FailureKind.cancelled);
    final until = _retryAt;
    if (until != null && DateTime.now().isBefore(until)) {
      throw ApiFailure(FailureKind.rateLimited, status: 429, retryAt: until);
    }
    final uri = instance.api(['projects', '$project', 'uploads', secret, filename]);
    if (!instance.allowsApi(uri)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final token = CancelToken();
    _requests.add(token);
    if (cancel != null) {
      unawaited(cancel.then((_) {
        if (!token.isCancelled) token.cancel('upload download aborted');
      }));
    }
    try {
      return await _fetchAndStreamUpload(
        uri: uri,
        secret: secret,
        filename: filename,
        sink: sink,
        token: token,
        maxBytes: maxBytes,
        onProgress: onProgress,
        allowRefresh: true,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel || _closed || token.isCancelled) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    } on ApiFailure {
      rethrow;
    } on IOException {
      throw const ApiFailure(FailureKind.network);
    } catch (_) {
      if (_closed || token.isCancelled) throw const ApiFailure(FailureKind.cancelled);
      rethrow;
    } finally {
      _requests.remove(token);
    }
  }

  Future<ArtifactDownload> _fetchAndStreamUpload({
    required Uri uri,
    required String secret,
    required String filename,
    required IOSink sink,
    required CancelToken token,
    required int maxBytes,
    required void Function(int received, int? total)? onProgress,
    required bool allowRefresh,
  }) async {
    if (_closed || token.isCancelled) throw const ApiFailure(FailureKind.cancelled);
    final response = await _dio.requestUri<ResponseBody>(
      uri,
      data: null,
      cancelToken: token,
      options: Options(
        method: 'GET',
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status != null,
        headers: _authHeaders,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 200) {
      return _writeUploadStream(
        response: response,
        filename: filename,
        sink: sink,
        token: token,
        maxBytes: maxBytes,
        onProgress: onProgress,
      );
    }
    await _discardBody(response.data);
    if (_closed || token.isCancelled) throw const ApiFailure(FailureKind.cancelled);
    if (status == 401 && allowRefresh && await _refreshOAuth()) {
      return _fetchAndStreamUpload(
        uri: uri,
        secret: secret,
        filename: filename,
        sink: sink,
        token: token,
        maxBytes: maxBytes,
        onProgress: onProgress,
        allowRefresh: false,
      );
    }
    if (status >= 300 && status < 400) {
      throw ApiFailure(FailureKind.redirectBlocked, status: status);
    }
    if (status == 429) {
      _rememberRetryAfter(response.headers.value('retry-after'));
    }
    throw ApiFailure.fromStatus(status, retryAt: _retryAt);
  }

  Future<ArtifactDownload> _writeUploadStream({
    required Response<ResponseBody> response,
    required String filename,
    required IOSink sink,
    required CancelToken token,
    required int maxBytes,
    required void Function(int received, int? total)? onProgress,
  }) async {
    final headers = response.headers;
    final total = int.tryParse(headers.value(Headers.contentLengthHeader) ?? '');
    if (total != null && total > maxBytes) {
      _cancelTransport(token);
      await _releaseBody(response.data);
      throw const ApiFailure(
        FailureKind.tooLarge,
        title: '超過大小上限',
        detail: '這個附件超過 4 MiB 上限。',
      );
    }
    final body = response.data;
    if (body == null) throw const ApiFailure(FailureKind.invalidResponse);
    final iterator = StreamIterator<Uint8List>(body.stream);
    final cancelled = token.whenCancel.then<Object?>((_) => _artifactCancelled);
    var received = 0;
    Future<Object?>? pendingMove;
    try {
      while (true) {
        if (_closed || token.isCancelled) throw const ApiFailure(FailureKind.cancelled);
        final move = iterator.moveNext().then<Object?>(
          (more) => more,
          onError: (Object error, StackTrace stack) {
            if (_closed || token.isCancelled) return _artifactCancelled;
            Error.throwWithStackTrace(error, stack);
          },
        );
        pendingMove = move;
        final step = await Future.any<Object?>([move, cancelled]);
        if (identical(step, _artifactCancelled) || _closed || token.isCancelled) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        if (step != true) break;
        final chunk = iterator.current;
        if (received + chunk.length > maxBytes) {
          _cancelTransport(token);
          try {
            await sink.close();
          } on Object {
            /* ignore */
          }
          throw const ApiFailure(
            FailureKind.tooLarge,
            title: '超過大小上限',
            detail: '這個附件超過 4 MiB 上限。',
          );
        }
        try {
          sink.add(chunk);
        } on StateError {
          throw const ApiFailure(FailureKind.cancelled);
        } on FileSystemException {
          throw ApiFailure.artifactStorage;
        }
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      if (pendingMove != null) {
        unawaited(pendingMove.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
      }
      try {
        await iterator.cancel();
      } on Object {
        /* ignore */
      }
    }
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (received == 0) onProgress?.call(0, total);
    return ArtifactDownload(
      fileName: filename,
      bytesWritten: received,
      contentType: headers.value(Headers.contentTypeHeader),
    );
  }

  /// CDN hop. A fresh client so [_dio] defaults, interceptors, and its cookie
  /// jar cannot ride along. The account adapter is never reused: production
  /// gets a new [IOHttpClientAdapter], and tests observe this hop only through
  /// an explicitly injected adapter, which is not closed with the hop.
  Dio _openBareArtifactDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: _dio.options.connectTimeout,
        receiveTimeout: _dio.options.receiveTimeout,
        sendTimeout: _dio.options.sendTimeout,
        followRedirects: false,
        maxRedirects: 0,
        responseType: ResponseType.stream,
        headers: const <String, dynamic>{},
        contentType: null,
      ),
    );
    dio.interceptors.clear(keepImplyContentTypeInterceptor: false);
    final cdn = _cdnAdapter;
    dio.httpClientAdapter = cdn == null ? IOHttpClientAdapter() : _ForwardingAdapter(cdn);
    _bareClients.add(dio);
    return dio;
  }

  void _closeBare(Dio? dio) {
    if (dio == null || !_bareClients.remove(dio)) return;
    dio.close(force: true);
  }

  Future<Response<ResponseBody>> _artifactResponse(
    Uri uri,
    CancelToken token, {
    required bool authenticated,
    Dio? client,
  }) {
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    return (client ?? _dio).requestUri<ResponseBody>(
      uri,
      data: null,
      cancelToken: token,
      options: Options(
        method: 'GET',
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status != null,
        headers: authenticated
            ? _authHeaders
            : const <String, dynamic>{'Accept': 'application/octet-stream'},
      ),
    );
  }

  Future<ArtifactDownload> _consumeArtifact({
    required Response<ResponseBody> response,
    required Uri requestUri,
    required bool allowRedirect,
    required bool allowRefresh,
    required CancelToken token,
    required int job,
    required IOSink sink,
    required int maxBytes,
    required void Function(int received, int? total)? onProgress,
  }) async {
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    final status = response.statusCode ?? 0;
    if (status == 200) {
      return _writeArtifact(
        response: response,
        sink: sink,
        job: job,
        token: token,
        maxBytes: maxBytes,
        onProgress: onProgress,
      );
    }
    await _discardBody(response.data);
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (status == 401 && allowRefresh && await _refreshOAuth()) {
      final retried = await _artifactResponse(
        requestUri,
        token,
        authenticated: true,
      );
      return _consumeArtifact(
        response: retried,
        requestUri: requestUri,
        allowRedirect: true,
        allowRefresh: false,
        token: token,
        job: job,
        sink: sink,
        maxBytes: maxBytes,
        onProgress: onProgress,
      );
    }
    if (allowRedirect && _artifactRedirects.contains(status)) {
      final location = _secureArtifactLocation(
        response.headers.value('location'),
      );
      if (location == null) {
        throw ApiFailure(FailureKind.redirectBlocked, status: status);
      }
      final bare = _openBareArtifactDio();
      try {
        final followed = await _artifactResponse(
          location,
          token,
          authenticated: false,
          client: bare,
        );
        return await _consumeArtifact(
          response: followed,
          requestUri: location,
          allowRedirect: false,
          allowRefresh: false,
          token: token,
          job: job,
          sink: sink,
          maxBytes: maxBytes,
          onProgress: onProgress,
        );
      } finally {
        _closeBare(bare);
      }
    }
    // A further redirect is blocked. Every other CDN status keeps its own
    // recovery copy, and 429 still arms the client's retry clock. The hop is
    // never replayed with the account credential.
    if (status >= 300 && status < 400) {
      throw ApiFailure(FailureKind.redirectBlocked, status: status);
    }
    if (status == 429) _rememberRetryAfter(response.headers.value('retry-after'));
    throw ApiFailure.fromStatus(status, retryAt: _retryAt);
  }

  Future<ArtifactDownload> _writeArtifact({
    required Response<ResponseBody> response,
    required IOSink sink,
    required int job,
    required CancelToken token,
    required int maxBytes,
    required void Function(int received, int? total)? onProgress,
  }) async {
    final headers = response.headers;
    final total = int.tryParse(headers.value(Headers.contentLengthHeader) ?? '');
    if (total != null && total > maxBytes) {
      _cancelTransport(token);
      await _releaseBody(response.data);
      throw ApiFailure.artifactTooLarge;
    }
    final body = response.data;
    if (body == null) throw const ApiFailure(FailureKind.invalidResponse);
    final iterator = StreamIterator<Uint8List>(body.stream);
    final cancelled = token.whenCancel.then<Object?>((_) => _artifactCancelled);
    var received = 0;
    Future<Object?>? pendingMove;
    try {
      while (true) {
        if (_closed || token.isCancelled) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        final move = iterator.moveNext().then<Object?>(
          (more) => more,
          onError: (Object error, StackTrace stack) {
            if (_closed || token.isCancelled) return _artifactCancelled;
            Error.throwWithStackTrace(error, stack);
          },
        );
        pendingMove = move;
        final step = await Future.any<Object?>(<Future<Object?>>[
          move,
          cancelled,
        ]);
        if (identical(step, _artifactCancelled) || _closed || token.isCancelled) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        if (step != true) break;
        final chunk = iterator.current;
        if (received + chunk.length > maxBytes) {
          _cancelTransport(token);
          try {
            await sink.close();
          } on Object {
            // A failed sink must not replace the size-limit failure.
          }
          throw ApiFailure.artifactTooLarge;
        }
        try {
          sink.add(chunk);
        } on StateError {
          throw const ApiFailure(FailureKind.cancelled);
        } on FileSystemException {
          throw ApiFailure.artifactStorage;
        }
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      // Cancelling the iterator completes a still-pending moveNext with an
      // error. Attach a listener before that cancel so it is not uncaught.
      if (pendingMove != null) {
        unawaited(pendingMove.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
      }
      try {
        await iterator.cancel();
      } on Object {
        // Subscription cancellation is not the caller's failure.
      }
    }
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (received == 0) onProgress?.call(0, total);
    return ArtifactDownload(
      fileName: _artifactFileName(headers.value('content-disposition'), job),
      bytesWritten: received,
      contentType: headers.value(Headers.contentTypeHeader),
    );
  }

  void _cancelTransport(CancelToken token) {
    if (!token.isCancelled) token.cancel('artifact exceeds size limit');
  }

  /// Subscribe only long enough to detach the socket. Do not read the body.
  Future<void> _releaseBody(ResponseBody? body) async {
    final stream = body?.stream;
    if (stream == null) return;
    try {
      final subscription = stream.listen(
        null,
        onError: (Object _, StackTrace _) {},
        cancelOnError: false,
      );
      await subscription.cancel();
    } on Object {
      return;
    }
  }

  Future<void> _discardBody(ResponseBody? body) async {
    final stream = body?.stream;
    if (stream == null) return;
    try {
      await stream.listen((_) {}, onError: (Object _) {}).cancel();
    } on ApiFailure {
      rethrow;
    } on Object {
      // Dropping an error page must not replace the status already chosen.
      return;
    }
  }

  void _rememberRetryAfter(String? text) {
    final seconds = int.tryParse(text ?? '');
    if (seconds != null && seconds >= 0) {
      _retryAt = DateTime.now().add(Duration(seconds: seconds));
      return;
    }
    if (text == null) return;
    try {
      _retryAt = HttpDate.parse(text);
    } on FormatException {
      // A malformed Retry-After still fails this call; retry stays manual.
    }
  }

  Future<({List<int> bytes, bool isEof, int? nextOffset})> jobTraceChunk(
    int project,
    int job, {
    int offset = 0,
    int? maxBytes,
  }) async {
    final query = <String, String>{
      if (offset > 0) 'offset': '$offset',
    };
    final headers = <String, String>{
      if (offset > 0) 'Range': 'bytes=$offset-',
    };
    final uri = instance.api(
      ['projects', '$project', 'jobs', '$job', 'trace'],
      query.isNotEmpty ? query : null,
    );
    try {
      final result = await _read(
        uri,
        headers: headers.isNotEmpty ? headers : null,
        maxBytes: maxBytes ?? maxTextBytes,
        allowRangeNotSatisfiable: true,
      );
      final eofHeader = result.headers.value('x-gitlab-trace-eof');
      var isEof = eofHeader == 'true' || eofHeader == '1';

      if (result.statusCode == 416) {
        return (bytes: const <int>[], isEof: isEof, nextOffset: offset);
      }

      final contentRange = result.headers.value('content-range');
      if (contentRange != null) {
        final match = RegExp(r'bytes\s+\d+-(\d+)/(\d+)', caseSensitive: false)
            .firstMatch(contentRange);
        if (match != null) {
          final end = int.tryParse(match.group(1) ?? '');
          final total = int.tryParse(match.group(2) ?? '');
          if (end != null && total != null && end + 1 >= total) {
            isEof = true;
          }
        }
      }

      List<int> chunkBytes;
      if (result.statusCode == 206) {
        chunkBytes = result.bytes;
      } else if (result.statusCode == 200) {
        if (offset > 0 && result.bytes.length > offset) {
          chunkBytes = result.bytes.sublist(offset);
        } else if (offset > 0 && result.bytes.length <= offset) {
          chunkBytes = const <int>[];
        } else {
          chunkBytes = result.bytes;
        }
      } else {
        chunkBytes = result.bytes;
      }

      final nextOffset = offset + chunkBytes.length;
      return (bytes: chunkBytes, isEof: isEof, nextOffset: nextOffset);
    } on ApiFailure catch (failure) {
      if (failure.status != 404) rethrow;
      final current = await _object(
        instance.api(['projects', '$project', 'jobs', '$job']),
      );
      if (const [
        'created',
        'pending',
        'manual',
        'scheduled',
        'preparing',
        'waiting_for_resource',
      ].contains(current['status'])) {
        return (bytes: const <int>[], isEof: false, nextOffset: offset);
      }
      rethrow;
    }
  }

  bool get isClosed => _closed;

  void close() {
    _closed = true;
    clearReadCache();
    for (final token in _requests.toList()) {
      token.cancel('session ended');
    }
    _requests.clear();
    for (final dio in _bareClients.toList()) {
      _bareClients.remove(dio);
      dio.close(force: true);
    }
    _dio.close(force: true);
  }
}

final class _CacheRead<T> {
  const _CacheRead(this.value, this.ttl);
  final T value;
  final Duration ttl;
}

final class _CachedRead {
  const _CachedRead(this.value, this.expires, this.cost);
  final Object value;
  final DateTime expires;
  final int cost;
}

/// Forwards a test double without closing it when the CDN client is discarded.
final class _ForwardingAdapter implements HttpClientAdapter {
  _ForwardingAdapter(this._inner);
  final HttpClientAdapter _inner;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _inner.fetch(options, requestStream, cancelFuture);
  }
}
