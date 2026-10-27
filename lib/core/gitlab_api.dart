import 'dart:async';
import 'dart:convert';
import 'rate_budget.dart';
import 'request_meter.dart';
import 'dart:io' show FileSystemException, IOException, IOSink;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'failure.dart';
import 'analytics_models.dart';
import 'group_work_item_identity.dart';
import 'instance.dart';
import 'models.dart';
import 'oauth.dart';
import 'pagination.dart';
import 'read_cache_disk_contract.dart';
import 'read_cache_projection.dart';
import 'registry_models.dart';
import 'release_assets.dart';
import 'snippet_models.dart';
import 'upload_names.dart';
import 'work_item_activity_models.dart';
import 'work_item_assignee_models.dart';
import 'work_item_labels_models.dart';
import 'work_item_attribute_models.dart';
import 'work_item_graph_models.dart';
import 'work_item_health_edit_models.dart';
import 'work_item_milestone_models.dart';
import 'work_item_status_models.dart';
import 'work_item_weight_models.dart';
import 'work_item_state_models.dart';
import 'work_item_dates_models.dart';

import '../l10n/l10n.dart';
part 'workspace_api.dart';
part 'cached_read_api.dart';
part 'incident_api.dart';
part 'analytics_api.dart';
part 'package_download_api.dart';
part 'snippet_graphql_api.dart';
part 'todo_snooze_api.dart';
part 'work_item_graphql_api.dart';
part 'work_item_attributes_api.dart';
part 'work_item_health_api.dart';
part 'work_item_activity_api.dart';
part 'work_item_note_delete_api.dart';
part 'work_item_note_reactions_api.dart';
part 'work_item_notifications_api.dart';
part 'work_item_content_api.dart';
part 'work_item_milestone_api.dart';
part 'work_item_weight_api.dart';
part 'work_item_assignee_api.dart';
part 'work_item_labels_api.dart';
part 'work_item_status_api.dart';
part 'work_item_state_api.dart';
part 'work_item_dates_api.dart';

final _rawStreamCancelled = Object();

bool _safeRawFileCoordinate(String value) {
  if (value.isEmpty || value.contains(r'\')) return false;
  return value
      .split('/')
      .every(
        (segment) =>
            segment.isNotEmpty &&
            segment != '.' &&
            segment != '..' &&
            !segment.contains(r'\') &&
            !segment.runes.any(
              (rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f),
            ),
      );
}

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
    ReadCacheSource? readCacheSource,
    GitLabRateBudget? rateBudget,
  }) : _credential = credential ?? PatCredential(token ?? ''),
       _dio = dio ?? Dio(),
       _cdnAdapter = cdnAdapter,
       _oauth = oauth,
       _readCacheClock = readCacheClock ?? DateTime.now,
       _readCacheSource = readCacheSource,
       rateBudget = rateBudget ?? GitLabRateBudget(now: readCacheClock),
       _onOAuthRotated = onOAuthRotated {
    final access = _credential.accessToken;
    if (access.trim().isEmpty || RegExp(r'\s').hasMatch(access)) {
      throw InputFormatException(l10n.tokenCannotBeBlank);
    }
    if (_credential is OAuthCredential) {
      final refresh = (_credential as OAuthCredential).refreshToken;
      if (refresh.trim().isEmpty || RegExp(r'\s').hasMatch(refresh)) {
        throw InputFormatException(l10n.tokenCannotBeBlank);
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
  final ReadCacheSource? _readCacheSource;
  final GitLabRateBudget rateBudget;
  late final _ReadCache _cache = _ReadCache(this);
  final Future<void> Function(OAuthCredential rotated)? _onOAuthRotated;
  Future<void>? _refreshing;
  int _readEpoch = 0;
  static const maxCachedReads = 256;
  static const maxCachedReadBytes = 16 * 1024 * 1024;
  final Set<CancelToken> _requests = {};
  final Set<Dio> _bareClients = {};
  bool _closed = false;
  DateTime? get _retryAt => rateBudget.retryAtFor(RateRequestClass.global);
  static const maxTextBytes = 2 * 1024 * 1024;
  static const maxTextLines = 20000;
  static const maxUploadBytes = 25 * 1024 * 1024;
  static const maxArtifactBytes = 256 * 1024 * 1024;

  /// Explicit cache clear revokes even immutable entries and pending results.
  void clearReadCache() {
    _cache.sourceAccountRevokedAt = _readCacheClock();
    _cache.clear();
  }

  // Compatibility for workspace_api.dart's groupByPath caller.
  Future<T> _cachedRead<T extends Object>(
    String key,
    Future<_CacheRead<T>> Function() load, {
    required int Function(T) cost,
    bool refresh = false,
    int invalidationRetries = 0,
  }) async {
    final uri = key.startsWith('group-path:')
        ? instance.api(['groups', key.substring('group-path:'.length)], {'with_projects': 'false'})
        : Uri.parse(key);
    final read = await _cache.read<T>(uri, _ReadClass.projectMeta, () async {
      final loaded = await load();
      return _LoadedRead(loaded.value, cost(loaded.value), loaded.ttl > Duration.zero);
    }, fresh: refresh);
    if (read.dropped || read.superseded) throw const ApiFailure(FailureKind.cancelled);
    return read.value;
  }

  Duration _cacheTtl(Headers headers, Duration maximum) {
    final directives = (headers.value('cache-control') ?? '').toLowerCase().split(',');
    return directives.any((v) => v.trim().split('=').first == 'no-store')
        ? Duration.zero : maximum;
  }

  RateRequestClass _rateClass(Uri uri, [String method = 'GET']) {
    if (instance.allowsGraphQL(uri)) return RateRequestClass.global;
    final p = _cache.path(uri);
    if (method == 'POST' && (p.length == 1 && const {'projects', 'groups'}.contains(p.first) ||
        p.length == 3 && p.first == 'projects' && p.last == 'fork')) { return RateRequestClass.create; }
    if (p.length == 4 && p.first == 'projects' && p[2] == 'repository' &&
        p[3].startsWith('archive')) {
      return RateRequestClass.archive;
    }
    if (p.contains('search') || uri.queryParameters.containsKey('search')) return RateRequestClass.search;
    if (method == 'GET' && p.length == 1 && p.first == 'groups') { return RateRequestClass.groupList; }
    if (method == 'GET' && p.length == 1 && p.first == 'projects') { return RateRequestClass.projectList; }
    return RateRequestClass.global;
  }

  void _checkRate(Uri uri, [String method = 'GET']) {
    if (_closed) throw const ApiFailure(FailureKind.cancelled);
    final until = rateBudget.retryAtFor(_rateClass(uri, method));
    if (until != null && _readCacheClock().isBefore(until)) {
      throw ApiFailure(FailureKind.rateLimited, status: 429, retryAt: until);
    }
  }

  void _noteRateLimit(Response<ResponseBody> response, Uri origin, int sequence, [String method = 'GET']) {
    rateBudget.noteResponse(headers: response.headers.map, statusCode: response.statusCode ?? 0,
      requestClass: _rateClass(origin, method), sequence: sequence,
      trusted: instance.allowsApi(origin) || instance.allowsGraphQL(origin));
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
    Duration? sendTimeout,
    void Function()? onSendStarted,
  }) async {
    if (_closed) {
      const failure = ApiFailure(FailureKind.cancelled);
      if (graphMutation) {
        (Zone.current[#graphMutationBlockedBeforeSend]
            as void Function(Object)?)?.call(failure);
      }
      throw failure;
    }
    if ((graphQuery && graphMutation) || (graphQuery || graphMutation
        ? method != 'POST' || !instance.allowsGraphQL(uri)
        : !instance.allowsApi(uri))) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    _checkRate(uri, method);
    final cancel = CancelToken();
    _requests.add(cancel);
    // Only private, fixed GraphQL queries use this read path. POST mutations
    // retain the write fences and are never retried automatically.
    final writing = method != 'GET' && method != 'HEAD' && !graphQuery;
    final affected = writing ? _cache.affected(uri, method, data, graphMutation: graphMutation) : <String>{};
    var writeStarted = false;
    var sendStarted = false;
    try {
      if (writing) {
        _cache.write(affected, starting: true);
        writeStarted = true;
        final begin = _cache.mutationDiskBarrier(affected, beforeSend: true);
        if (begin != null) {
          await _cache.awaitDiskBarrier(
            begin,
            operation: ReadCacheCleanupOperation.mutation,
            disposition: ReadCacheCleanupDisposition.requestBlockedBeforeSend,
            beforeSend: true,
          );
        }
      }
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
      onSendStarted?.call();
      if (graphMutation) {
        (Zone.current[#graphMutationSendStarted] as void Function()?)?.call();
      }
      sendStarted = true;
      final sequence = rateBudget.nextSequence();
      RequestMeter.current?.increment();
      final response = await _dio.requestUri<ResponseBody>(
        uri,
        data: data,
        cancelToken: cancel,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          sendTimeout: sendTimeout,
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
      _noteRateLimit(response, uri, sequence, method);
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
        _cache.revoke(uri, status,
            terminal401: _credential is! OAuthCredential || retried);
        await _cache.settleDiskSafety();
        if (_closed) throw const ApiFailure(FailureKind.cancelled);
        if (body != null) await body.stream.listen((_) {}).cancel();
        var refreshed = false;
        if (status == 401 && !retried) {
          try {
            refreshed = await _refreshOAuth();
          } catch (_) {
            // Keep the mutation's known refusal even if refresh/persistence
            // fails with an unrelated transport or storage exception.
            _cache.revoke(uri, 401);
            await _cache.settleDiskSafety();
            if (_closed) throw const ApiFailure(FailureKind.cancelled);
            if (writing) {
              throw _knownMutation401(refreshSucceeded: false);
            }
            rethrow;
          }
        }
        if (refreshed) {
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
          throw _knownMutation401(refreshSucceeded: true);
        }
        if (status == 401 && _credential is OAuthCredential && !retried) {
          _cache.revoke(uri, 401);
          await _cache.settleDiskSafety();
          if (_closed) throw const ApiFailure(FailureKind.cancelled);
        }
        throw ApiFailure.fromStatus(status, retryAt: rateBudget.retryAtFor(_rateClass(uri, method)));
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
    } on ApiFailure catch (failure) {
      if (graphMutation && !sendStarted &&
          (failure.kind == FailureKind.cancelled ||
              failure.kind == FailureKind.readCacheCleanup &&
                  failure.cleanup?.disposition ==
                      ReadCacheCleanupDisposition.requestBlockedBeforeSend)) {
        // Only the transport can prove that acceptance never reached a send.
        (Zone.current[#graphMutationBlockedBeforeSend]
            as void Function(Object)?)?.call(failure);
      }
      rethrow;
    } finally {
      _requests.remove(cancel);
      if (writeStarted) {
        _cache.write(affected, starting: false);
        // Cleanup after a send is non-fatal: preserve the original value,
        // ApiFailure identity and stack, including writeUncertain.
        try {
          final end = sendStarted
              ? _cache.mutationDiskBarrier(affected, beforeSend: false)
              : null;
          if (end != null) {
            await _cache.awaitDiskBarrier(
              end,
              operation: ReadCacheCleanupOperation.mutation,
              disposition: ReadCacheCleanupDisposition.originalOutcomePreserved,
            );
          }
        } on Object {
          _cache.reportCleanup(
            const ReadCacheCleanupState(
              operation: ReadCacheCleanupOperation.mutation,
              disposition: ReadCacheCleanupDisposition.originalOutcomePreserved,
              code: ReadCacheCleanupCode.cleanupFailed,
              clearResult: _ReadCache.unknownClear,
            ),
          );
        }
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
      final value = objectJson(jsonDecode(utf8.decode(result.bytes)));
      if (method == 'GET') {
        _cache.observe(uri, value);
        _cache.observeRawPrivacy(uri, value);
        await _cache.settleDiskSafety();
        if (_closed) throw const ApiFailure(FailureKind.cancelled);
      }
      return value;
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
            title: incompatible ? l10n.instanceNoJobDependencyGraph : null,
            detail: incompatible
                ? l10n.jobsTabWithoutGraphFields
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
      _cache.observeRawPrivacy(uri, data);
      await _cache.settleDiskSafety();
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
      return ApiPage(
        List.unmodifiable(
          data.map((j) {
            final value = objectJson(j);
            _cache.observe(uri, value);
            return parse(value);
          }),
        ),
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

  Future<Project> project(String idOrFullPath, {bool refresh = false, bool allowDisk = true}) async {
    final read = await cachedRecord(['projects', idOrFullPath], fresh: refresh,
      maxAge: const Duration(minutes: 5), allowDisk: allowDisk);
    if (read.dropped || read.superseded) throw const ApiFailure(FailureKind.cancelled);
    try { return Project.fromJson(read.value); }
    on FormatException { throw const ApiFailure(FailureKind.invalidResponse); }
  }

  Future<String> defaultBranchSha(Project project, {bool allowDisk = true}) async {
    final branch = project.defaultBranch;
    if (branch == null || branch.isEmpty) {
      throw const ApiFailure(FailureKind.invisible);
    }
    final read = await cachedRecord([
      'projects',
      '${project.id}',
      'repository',
      'branches',
      branch,
    ], maxAge: const Duration(seconds: 60), allowDisk: allowDisk);
    if (read.dropped || read.superseded) throw const ApiFailure(FailureKind.cancelled);
    final j = read.value;
    final sha = requiredString(objectJson(j['commit']), 'id');
    if (!_fullSha.hasMatch(sha.toLowerCase())) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    if (read.lineage != CacheLineage.disk) _cache.confirm(sha);
    return sha.toLowerCase();
  }

  Future<ApiPage<TreeEntry>> tree(
    int projectId,
    String sha, {
    String path = '',
    Uri? next,
    bool allowDisk = true,
  }) async {
    final ref = _cache.isConfirmed(sha) ? sha.toLowerCase() : sha;
    final read = await cachedRecords(['projects', '$projectId', 'repository', 'tree'],
      query: {'ref': ref, 'path': path, 'per_page': '50'}, next: next, allowDisk: allowDisk);
    if (read.dropped || read.superseded) throw const ApiFailure(FailureKind.cancelled);
    return ApiPage(List.unmodifiable(read.value.items.map(TreeEntry.fromJson)), next: read.value.next);
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
    bool allowDisk = true,
    // AI file edits read the live content; nothing is joined or stored.
    bool useCache = true,
  }) async {
    if (!useCache) {
      return (await _readTextFile(projectId, sha, filePath)).value;
    }
    final pinned = _cache.isConfirmed(sha);
    final ref = pinned ? sha.toLowerCase() : sha;
    final uri = instance.api(['projects', '$projectId', 'repository', 'files', filePath], {'ref': ref});
    final read = await _cache.read<String>(uri, pinned ? _ReadClass.pinned : null, () async {
      final loaded = await _readTextFile(projectId, ref, filePath);
      return _LoadedRead(loaded.value, loaded.responseBytes ?? utf8.encode(loaded.value).length,
        loaded.ttl > Duration.zero);
    }, fresh: refresh, allowDisk: allowDisk, accept: 'text/plain');
    if (read.dropped || read.superseded) throw const ApiFailure(FailureKind.cancelled);
    return read.value;
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
      return _CacheRead(text, metaTtl < rawTtl ? metaTtl : rawTtl, responseBytes: result.bytes.length);
    } on FormatException {
      throw const ApiFailure(FailureKind.unsupported);
    }
  }

  /// Reads one repository file as bounded bytes. The request stays on this
  /// instance's API origin, never follows redirects, and carries cancellation
  /// through to the response stream.
  Future<Uint8List> rawFileBytes(
    String project,
    String ref,
    String filePath, {
    int maxBytes = 10 * 1024 * 1024,
    CancelToken? cancelToken,
    void Function(int received, int? total)? onProgress,
    void Function(String contentType)? onContentType,
    IOSink? sink,
  }) async {
    if (_closed || cancelToken?.isCancelled == true) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (!_safeRawFileCoordinate(project) ||
        !_safeRawFileCoordinate(ref) ||
        !_safeRawFileCoordinate(filePath) ||
        maxBytes <= 0 ||
        maxBytes > 100 * 1024 * 1024) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final uri = instance.api(
      ['projects', project, 'repository', 'files', filePath, 'raw'],
      {'ref': ref, 'lfs': 'false'},
    );
    if (!instance.allowsApi(uri)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final token = CancelToken();
    _requests.add(token);
    if (cancelToken != null) {
      unawaited(cancelToken.whenCancel.then((_) {
        if (!token.isCancelled) token.cancel('repository media aborted');
      }));
    }
    try {
      return await _rawFileBytes(
        uri,
        token: token,
        maxBytes: maxBytes,
        onProgress: onProgress,
        onContentType: onContentType,
        sink: sink,
        allowRefresh: true,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel || _closed || token.isCancelled) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    } finally {
      _requests.remove(token);
    }
  }

  Future<Uint8List> _rawFileBytes(
    Uri uri, {
    required CancelToken token,
    required int maxBytes,
    required void Function(int received, int? total)? onProgress,
    required void Function(String contentType)? onContentType,
    required IOSink? sink,
    required bool allowRefresh,
  }) async {
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    _checkRate(uri);
    final sequence = rateBudget.nextSequence();
    RequestMeter.current?.increment();
    final response = await _dio.requestUri<ResponseBody>(
      uri,
      cancelToken: token,
      options: Options(
        method: 'GET',
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status != null,
        headers: {..._authHeaders, 'Accept': 'application/octet-stream'},
      ),
    );
    _noteRateLimit(response, uri, sequence);
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      _cache.revoke(uri, status,
          terminal401: _credential is! OAuthCredential || !allowRefresh);
      await _cache.settleDiskSafety();
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
      await _releaseBody(response.data);
      if (_closed || token.isCancelled) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      var refreshed = false;
      if (status == 401 && allowRefresh) {
        try {
          refreshed = await _refreshOAuth();
        } catch (_) {
          _cache.revoke(uri, 401);
          await _cache.settleDiskSafety();
          if (_closed) throw const ApiFailure(FailureKind.cancelled);
          rethrow;
        }
      }
      if (refreshed) {
        return await _rawFileBytes(
          uri,
          token: token,
          maxBytes: maxBytes,
          onProgress: onProgress,
          onContentType: onContentType,
          sink: sink,
          allowRefresh: false,
        );
      }
      if (status == 401 && _credential is OAuthCredential && allowRefresh) {
        _cache.revoke(uri, 401);
        await _cache.settleDiskSafety();
        if (_closed) throw const ApiFailure(FailureKind.cancelled);
      }
      throw ApiFailure.fromStatus(status, retryAt: rateBudget.retryAtFor(_rateClass(uri)));
    }
    final total = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    onContentType?.call(
      (response.headers.value(Headers.contentTypeHeader) ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase(),
    );
    if (total != null && total > maxBytes) {
      _cancelTransport(token);
      await _releaseBody(response.data);
      throw const ApiFailure(FailureKind.tooLarge);
    }
    final body = response.data;
    if (body == null) throw const ApiFailure(FailureKind.invalidResponse);
    final bytes = sink == null ? BytesBuilder(copy: false) : null;
    var received = 0;
    Stream<Uint8List> checkedBody() async* {
      final iterator = StreamIterator<Uint8List>(body.stream);
      try {
        while (true) {
          final moved = await Future.any<Object>([
            iterator.moveNext(),
            token.whenCancel.then<Object>((_) => _rawStreamCancelled),
          ]);
          if (identical(moved, _rawStreamCancelled) || _closed) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          if (moved != true) break;
          final chunk = iterator.current;
          if (received + chunk.length > maxBytes) {
            _cancelTransport(token);
            throw const ApiFailure(FailureKind.tooLarge);
          }
          received += chunk.length;
          onProgress?.call(received, total);
          yield chunk;
        }
      } finally {
        unawaited(
          iterator.cancel().then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
      }
    }
    try {
      if (sink == null) {
        await for (final chunk in checkedBody()) {
          bytes!.add(chunk);
        }
      } else {
        await sink.addStream(checkedBody());
        await sink.flush();
      }
    } on ApiFailure {
      rethrow;
    } on FileSystemException {
      throw ApiFailure.artifactStorage;
    } on Object {
      if (_closed || token.isCancelled) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    }
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (received == 0) onProgress?.call(0, total);
    return bytes?.takeBytes() ?? Uint8List(0);
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
      _cache.clear(revoke: false);
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
        authenticated: true,
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
    _checkRate(uri);
    final sequence = rateBudget.nextSequence();
    RequestMeter.current?.increment();
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
    _noteRateLimit(response, uri, sequence);
    final status = response.statusCode ?? 0;
    _cache.revoke(uri, status,
        terminal401: _credential is! OAuthCredential || !allowRefresh);
    await _cache.settleDiskSafety();
    if (_closed) throw const ApiFailure(FailureKind.cancelled);
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
    var refreshed = false;
    if (status == 401 && allowRefresh) {
      try {
        refreshed = await _refreshOAuth();
      } catch (_) {
        _cache.revoke(uri, 401);
        await _cache.settleDiskSafety();
        if (_closed) throw const ApiFailure(FailureKind.cancelled);
        rethrow;
      }
    }
    if (refreshed) {
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
    if (status == 401 && _credential is OAuthCredential && allowRefresh) {
      _cache.revoke(uri, 401);
      await _cache.settleDiskSafety();
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
    }
    if (status >= 300 && status < 400) {
      throw ApiFailure(FailureKind.redirectBlocked, status: status);
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
      throw ApiFailure(
        FailureKind.tooLarge,
        title: l10n.exceedsSizeLimit,
        detail: l10n.attachmentExceeds4Mib,
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
          throw ApiFailure(
            FailureKind.tooLarge,
            title: l10n.exceedsSizeLimit,
            detail: l10n.attachmentExceeds4Mib,
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
  }) async {
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (authenticated) _checkRate(uri);
    final sequence = rateBudget.nextSequence();
    RequestMeter.current?.increment();
    final response = await (client ?? _dio).requestUri<ResponseBody>(
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
    if (authenticated) {
      _noteRateLimit(response, uri, sequence);
      _cache.revoke(uri, response.statusCode ?? 0,
          terminal401: _credential is! OAuthCredential);
      await _cache.settleDiskSafety();
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
    }
    return response;
  }

  Future<ArtifactDownload> _consumeArtifact({
    required Response<ResponseBody> response,
    required Uri requestUri,
    required bool authenticated,
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
    var refreshed = false;
    if (status == 401 && authenticated && allowRefresh) {
      try {
        refreshed = await _refreshOAuth();
      } catch (_) {
        _cache.revoke(requestUri, 401);
        await _cache.settleDiskSafety();
        if (_closed) throw const ApiFailure(FailureKind.cancelled);
        rethrow;
      }
    }
    if (refreshed) {
      final retried = await _artifactResponse(
        requestUri,
        token,
        authenticated: true,
      );
      return _consumeArtifact(
        response: retried,
        requestUri: requestUri,
        authenticated: true,
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
          authenticated: false,
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
    if (status == 401 &&
        authenticated &&
        instance.allowsApi(requestUri) &&
        _credential is OAuthCredential) {
      _cache.revoke(requestUri, 401);
      await _cache.settleDiskSafety();
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
    }
    // CDN failures keep their status without changing the API rate budget.
    // The hop is never replayed with the account credential.
    if (status >= 300 && status < 400) {
      throw ApiFailure(FailureKind.redirectBlocked, status: status);
    }
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

  Future<
    ({
      List<int> bytes,
      bool isEof,
      int? nextOffset,
      int? startOffset,
      int? totalBytes,
      int requestCount,
    })
  >
  jobTraceChunk(int project, int job, {int offset = 0, int? maxBytes}) async {
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
        return (
          bytes: const <int>[],
          isEof: isEof,
          nextOffset: offset,
          startOffset: offset,
          totalBytes: null,
          requestCount: 1,
        );
      }

      final contentRange = result.headers.value('content-range');
      int? startOffset = result.statusCode == 206 ? null : offset;
      int? totalBytes;
      if (contentRange != null) {
        final match = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+)', caseSensitive: false)
            .firstMatch(contentRange);
        if (match != null) {
          startOffset = int.tryParse(match.group(1) ?? '');
          final end = int.tryParse(match.group(2) ?? '');
          final total = int.tryParse(match.group(3) ?? '');
          totalBytes = total;
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
      return (
        bytes: chunkBytes,
        isEof: isEof,
        nextOffset: nextOffset,
        startOffset: startOffset,
        totalBytes: totalBytes,
        requestCount: 1,
      );
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
        return (
          bytes: const <int>[],
          isEof: false,
          nextOffset: offset,
          startOffset: offset,
          totalBytes: null,
          requestCount: 2,
        );
      }
      rethrow;
    }
  }

  bool get isClosed => _closed;

  /// Server cooldown gate for an ordinary write (create is independent).
  bool get mayStartRequest => !_closed && rateBudget.mayStart(RateRequestClass.global);

  bool mayStartRequestFor(List<String> path, {String method = 'POST'}) =>
      !_closed && rateBudget.mayStart(_rateClass(instance.api(path), method));

  void close() {
    _closed = true;
    _cache.close();
    rateBudget.close();
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
  const _CacheRead(this.value, this.ttl, {this.responseBytes});
  final T value;
  final Duration ttl;
  final int? responseBytes;
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
