part of 'gitlab_api.dart';

/// Failure categories specific to a snapshot request. UI translation is owned
/// by the presentation layer.
enum OfflineRequestFailureKind {
  resolveFailed,
  invalidTree,
  tooManyEntries,
  treeTooLarge,
  serverForbidsStorage,
  archiveTooLarge,
}

final class OfflineRequestFailure implements Exception {
  const OfflineRequestFailure(this.kind);
  final OfflineRequestFailureKind kind;
}

enum OfflineRefKind { branch, tag }

enum OfflineAccessScope { project, repository }

enum OfflineVersionState { ok, refGone, commitGone }

final class OfflineVersionProbe {
  const OfflineVersionProbe(this.state, {this.headSha});
  final OfflineVersionState state;
  final String? headSha;
}

final class OfflineAccessLoss {
  const OfflineAccessLoss({
    required this.binding,
    required this.projectId,
    required this.scope,
    required this.status,
  });
  final DiskBinding binding;
  final int projectId;
  final OfflineAccessScope scope;
  final int status;
}

final class OfflineResolvedRef {
  const OfflineResolvedRef({
    required this.sha,
    required this.commitTitle,
    required this.committedAt,
  });
  final String sha;
  final String? commitTitle;
  final DateTime? committedAt;
}

/// A continuation is an opaque value produced by the API, never a URL to be
/// sent with credentials. All outgoing URLs are rebuilt from original inputs.
final class OfflineTreeCursor {
  const OfflineTreeCursor._({this.pageToken, this.page});
  final String? pageToken;
  final int? page;
}

final class OfflineTreePage {
  const OfflineTreePage({required this.entries, required this.next});
  final List<Json> entries;
  final OfflineTreeCursor? next;
}

/// A stream keeps the transport registered with its client until the stream
/// finishes or [cancel] is invoked. The consumer supplies the idle watchdog.
final class OfflineArchive {
  OfflineArchive._(this.stream, this.cancel);
  final Stream<Uint8List> stream;
  final void Function() cancel;
}

bool _offlineNoStore(Headers headers) => (headers.value('cache-control') ?? '')
    .toLowerCase()
    .split(',')
    .any((directive) => directive.trim().split('=').first == 'no-store');

extension OfflineRepositoryApi on GitLabApi {
  Future<OfflineVersionProbe> probeOfflineVersion({
    required int projectId,
    required OfflineRefKind kind,
    required String name,
    required String sha,
  }) async {
    if (projectId <= 0 || name.isEmpty || !_fullSha.hasMatch(sha)) {
      throw const OfflineRequestFailure(
        OfflineRequestFailureKind.resolveFailed,
      );
    }
    try {
      final path = [
        'projects',
        '$projectId',
        'repository',
        kind == OfflineRefKind.branch ? 'branches' : 'tags',
        name,
      ];
      final ref = await _offlineProbeRequest(
        instance.api(path),
        () => record(path),
      );
      final id = objectJson(ref['commit'])['id'];
      if (id is! String || !_fullSha.hasMatch(id.toLowerCase())) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      return OfflineVersionProbe(
        OfflineVersionState.ok,
        headSha: id.toLowerCase(),
      );
    } on ApiFailure catch (error) {
      if (error.status != 404) rethrow;
    }
    final available = await offlineCommitAvailable(
      projectId: projectId,
      sha: sha,
    );
    return OfflineVersionProbe(
      available ? OfflineVersionState.refGone : OfflineVersionState.commitGone,
    );
  }

  /// A tree/archive 404 is ambiguous until the numeric project is checked.
  Future<bool> offlineCommitAvailable({
    required int projectId,
    required String sha,
  }) async {
    if (projectId <= 0 || !_fullSha.hasMatch(sha)) {
      throw const ApiFailure(FailureKind.validation);
    }
    await verifyOfflineProject(projectId);
    try {
      final uri = instance.api(
        ['projects', '$projectId', 'repository', 'tree'],
        {'ref': sha, 'per_page': '1'},
      );
      final result = await _offlineProbeRequest(uri, () => _read(uri));
      if (jsonDecode(utf8.decode(result.bytes)) is! List<dynamic>) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      return true;
    } on ApiFailure catch (error) {
      if (error.status != 404) rethrow;
      return false;
    }
  }

  Future<void> verifyOfflineProject(int projectId) async {
    if (projectId <= 0) throw const ApiFailure(FailureKind.validation);
    final path = ['projects', '$projectId'];
    final project = await _offlineProbeRequest(
      instance.api(path),
      () => record(path),
    );
    if (project['id'] != projectId) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// Binding is attached only after the same account generation is verified.
  void bindOfflineAccess({
    required DiskBinding binding,
    required void Function(OfflineAccessLoss) onAccessLoss,
    required void Function(DiskBinding) onValidatedJson,
    void Function(DiskBinding, int)? onAmbiguousAccessLoss,
  }) {
    if (!_cache.enabled ||
        _cache.accountKey != binding.accountKey ||
        _cache.generation != binding.generation) {
      throw StateError('Offline binding must match the read cache');
    }
    _offlineBinding = binding;
    _offlineAccessSink = onAccessLoss;
    _offlineValidatedSink = onValidatedJson;
    _offlineAliasProbeSink = onAmbiguousAccessLoss;
    _offlineLastValidated = null;
  }

  /// Branches are confirmed by the cache's branch observer; tags require an
  /// additional fresh commit read because tags do not confirm commit IDs.
  Future<OfflineResolvedRef> resolveOfflineRef({
    required int projectId,
    required OfflineRefKind kind,
    required String name,
  }) async {
    if (projectId <= 0 || name.isEmpty) {
      throw const OfflineRequestFailure(
        OfflineRequestFailureKind.resolveFailed,
      );
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        Json ref;
        if (kind == OfflineRefKind.branch) {
          final read = await cachedRecord(
            ['projects', '$projectId', 'repository', 'branches', name],
            fresh: true,
            allowDisk: false,
          );
          if (read.dropped || read.superseded) continue;
          ref = read.value;
        } else {
          ref = await record([
            'projects',
            '$projectId',
            'repository',
            'tags',
            name,
          ]);
        }
        final commit = objectJson(ref['commit']);
        final rawSha = commit['id'];
        if (rawSha is! String) {
          throw const OfflineRequestFailure(
            OfflineRequestFailureKind.resolveFailed,
          );
        }
        final sha = rawSha.toLowerCase();
        if (!_fullSha.hasMatch(sha)) {
          throw const OfflineRequestFailure(
            OfflineRequestFailureKind.resolveFailed,
          );
        }
        if (kind == OfflineRefKind.tag) {
          final verified = await cachedRecord(
            ['projects', '$projectId', 'repository', 'commits', sha],
            fresh: true,
            allowDisk: false,
          );
          if (verified.dropped || verified.superseded) continue;
          final id = verified.value['id'];
          if (id is! String || id.toLowerCase() != sha) continue;
        }
        if (!_cache.isConfirmed(sha)) continue;
        final title = commit['title'];
        final date = commit['committed_date'];
        return OfflineResolvedRef(
          sha: sha,
          commitTitle: title is String ? title : null,
          committedAt: date is String ? DateTime.tryParse(date)?.toUtc() : null,
        );
      } on FormatException {
        throw const OfflineRequestFailure(
          OfflineRequestFailureKind.resolveFailed,
        );
      }
    }
    throw const OfflineRequestFailure(OfflineRequestFailureKind.resolveFailed);
  }

  Future<OfflineTreePage> repositoryTreePage({
    required int projectId,
    required String sha,
    String subPath = '',
    OfflineTreeCursor? cursor,
    CancelToken? cancelToken,
  }) async {
    final normalized = sha.toLowerCase();
    if (projectId <= 0 ||
        !_fullSha.hasMatch(normalized) ||
        !_cache.isConfirmed(normalized) ||
        !_offlineValidPath(subPath, allowEmpty: true)) {
      throw const OfflineRequestFailure(OfflineRequestFailureKind.invalidTree);
    }
    final query = <String, String>{
      'ref': normalized,
      'path': subPath,
      'recursive': 'true',
      'per_page': '100',
      if (cursor?.page == null) 'pagination': 'keyset',
      'page_token': ?cursor?.pageToken,
      if (cursor?.page case final page?) 'page': '$page',
    };
    final uri = instance.api([
      'projects',
      '$projectId',
      'repository',
      'tree',
    ], query);
    final result = await _read(uri, cancelToken: cancelToken);
    if (_offlineNoStore(result.headers)) {
      throw const OfflineRequestFailure(
        OfflineRequestFailureKind.serverForbidsStorage,
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(result.bytes));
      if (decoded is! List<dynamic>) throw const FormatException();
      final entries = <Json>[];
      for (final raw in decoded) {
        final entry = objectJson(raw);
        _offlineValidateTreeEntry(entry, normalized.length, subPath);
        entries.add(Map<String, dynamic>.unmodifiable(entry));
      }
      final next = _offlineNextTreeCursor(
        this,
        uri,
        result.headers,
        projectId,
        cursor,
      );
      if (entries.isEmpty && next != null) throw const FormatException();
      return OfflineTreePage(entries: List.unmodifiable(entries), next: next);
    } on FormatException {
      throw const OfflineRequestFailure(OfflineRequestFailureKind.invalidTree);
    }
  }

  Future<OfflineArchive> repositoryArchive({
    required int projectId,
    required String sha,
    String subPath = '',
    CancelToken? cancelToken,
    Future<void> Function()? beforeSend,
  }) async {
    final normalized = sha.toLowerCase();
    if (projectId <= 0 ||
        !_fullSha.hasMatch(normalized) ||
        !_cache.isConfirmed(normalized) ||
        !_offlineValidPath(subPath, allowEmpty: true)) {
      throw const OfflineRequestFailure(
        OfflineRequestFailureKind.resolveFailed,
      );
    }
    final uri = instance.api(
      ['projects', '$projectId', 'repository', 'archive.tar.gz'],
      {
        'sha': normalized,
        'include_lfs_blobs': 'false',
        if (subPath.isNotEmpty) 'path': subPath,
      },
    );
    if (cancelToken?.isCancelled == true) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    final token = CancelToken();
    _requests.add(token);
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((_) {
          if (!token.isCancelled) token.cancel();
        }),
      );
    }
    try {
      return await _offlineOpenArchive(
        uri,
        token,
        allowRefresh: true,
        beforeSend: beforeSend,
      );
    } on Object {
      _requests.remove(token);
      rethrow;
    }
  }
}

bool _offlineValidPath(String path, {bool allowEmpty = false}) {
  if (path.isEmpty) return allowEmpty;
  if (path.startsWith('/') ||
      path.contains('\u0000') ||
      utf8.encode(path).length > 4096) {
    return false;
  }
  return path
      .split('/')
      .every((part) => part.isNotEmpty && part != '.' && part != '..');
}

void _offlineValidateTreeEntry(Json entry, int idLength, String subPath) {
  final path = entry['path'];
  final type = entry['type'];
  final mode = entry['mode'];
  final id = entry['id'];
  if (path is! String ||
      !_offlineValidPath(path) ||
      (subPath.isNotEmpty && !path.startsWith('$subPath/')) ||
      type is! String ||
      mode is! String ||
      id is! String ||
      id.length != idLength ||
      !RegExp(r'^[0-9a-f]+$').hasMatch(id)) {
    throw const FormatException();
  }
  final validMode = switch (type) {
    'blob' => const {'100644', '100755', '120000'}.contains(mode),
    'tree' => mode == '040000',
    'commit' => mode == '160000',
    _ => false,
  };
  if (!validMode) throw const FormatException();
}

/// Tracks global progress and parent membership across all pages before the
/// caller can persist the pending tree. Size reserves the largest final fields.
final class OfflineTreeValidator {
  OfflineTreeValidator({required this.sha, this.subPath = ''});
  final String sha;
  final String subPath;
  final Map<String, String> _paths = {};
  final Set<String> _tokens = {};
  int _pages = 0;
  late int _budget = utf8
      .encode(
        jsonEncode({
          'schema': 1,
          'snapshotId': '00000000000000000000000000000000',
          'sha': sha,
          'subPath': subPath,
          'e': <Object>[],
        }),
      )
      .length;

  void add(OfflineTreePage page) {
    _pages++;
    if (_pages > 50 || _paths.length + page.entries.length > 5000) {
      throw const OfflineRequestFailure(
        OfflineRequestFailureKind.tooManyEntries,
      );
    }
    for (final entry in page.entries) {
      try {
        _offlineValidateTreeEntry(entry, sha.length, subPath);
      } on FormatException {
        throw const OfflineRequestFailure(
          OfflineRequestFailureKind.invalidTree,
        );
      }
      final path = entry['path'] as String;
      if (_paths.containsKey(path)) {
        throw const OfflineRequestFailure(
          OfflineRequestFailureKind.invalidTree,
        );
      }
      _paths[path] = entry['type'] as String;
      _budget +=
          utf8
              .encode(
                jsonEncode({
                  'p': path,
                  't': entry['type'],
                  'm': entry['mode'],
                  'i': entry['id'],
                  's': 'unsupportedType',
                  'k': 'lfsPointer',
                  'z': 9999999999,
                  'l': 99999,
                }),
              )
              .length +
          1;
      if (_budget > 4 * 1024 * 1024) {
        throw const OfflineRequestFailure(
          OfflineRequestFailureKind.treeTooLarge,
        );
      }
    }
    final next = page.next;
    if (next != null) {
      final cursor = next.pageToken ?? 'page:${next.page}';
      if (!_tokens.add(cursor)) {
        throw const OfflineRequestFailure(
          OfflineRequestFailureKind.invalidTree,
        );
      }
    }
  }

  void finish() {
    for (final path in _paths.keys) {
      final slash = path.lastIndexOf('/');
      if (slash < 0) continue;
      final parent = path.substring(0, slash);
      if (parent == subPath) continue;
      if (_paths[parent] != 'tree') {
        throw const OfflineRequestFailure(
          OfflineRequestFailureKind.invalidTree,
        );
      }
    }
  }
}

OfflineTreeCursor? _offlineNextTreeCursor(
  GitLabApi api,
  Uri current,
  Headers headers,
  int projectId,
  OfflineTreeCursor? previous,
) {
  final link = headers.value('link');
  Uri? candidate;
  if (link != null) {
    for (final match in RegExp(
      r'<([^>]+)>\s*;\s*rel="?([^";,]+)"?',
    ).allMatches(link)) {
      if (match.group(2)?.trim().split(' ').contains('next') ?? false) {
        candidate = current.resolve(match.group(1)!);
        break;
      }
    }
  }
  if (candidate != null) {
    if (!api.instance.allowsApi(candidate) ||
        candidate.path != current.path ||
        candidate.queryParametersAll.values.any((v) => v.length != 1) ||
        candidate.queryParameters['ref'] != current.queryParameters['ref'] ||
        candidate.queryParameters['recursive'] != 'true' ||
        (candidate.queryParameters.containsKey('id') &&
            candidate.queryParameters['id'] != '$projectId') ||
        (current.queryParameters['path']!.isNotEmpty &&
            candidate.queryParameters['path'] !=
                current.queryParameters['path'])) {
      throw const FormatException();
    }
    final token = candidate.queryParameters['page_token'];
    if (token != null) {
      if (token.isEmpty ||
          utf8.encode(token).length > 4096 ||
          token == previous?.pageToken) {
        throw const FormatException();
      }
      return OfflineTreeCursor._(pageToken: token);
    }
    final suppliedPage = candidate.queryParameters['page'];
    if (suppliedPage != null) {
      final page = int.tryParse(suppliedPage);
      if (page == null || page <= (previous?.page ?? 1)) {
        throw const FormatException();
      }
      return OfflineTreeCursor._(page: page);
    }
    throw const FormatException();
  }
  final header = headers.value('x-next-page');
  if (header == null || header.isEmpty) return null;
  final page = int.tryParse(header);
  if (page == null || page <= (previous?.page ?? 1)) {
    throw const FormatException();
  }
  return OfflineTreeCursor._(page: page);
}

extension _OfflineApiInternals on GitLabApi {
  /// Keep unclassified proxy errors out of persisted version-gone metadata.
  /// The proof stays local to this request; general C2 failures are unchanged.
  Future<T> _offlineProbeRequest<T>(
    Uri expected,
    Future<T> Function() call,
  ) async {
    var verified404 = false;
    try {
      return await runZoned(
        call,
        zoneValues: {
          #offlineGitLabError: (Uri uri, int status) {
            if (uri == expected && status == 404) verified404 = true;
          },
        },
      );
    } on ApiFailure catch (error) {
      if (error.status == 404 && !verified404) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      rethrow;
    }
  }

  int? _offlineAliasProject(Uri uri) {
    if (_offlineBinding == null || _offlineAliasProbeSink == null) return null;
    final parts = _cache.path(uri);
    if (parts.length < 2 ||
        parts.first != 'projects' ||
        int.tryParse(parts[1]) != null) {
      return null;
    }
    return int.tryParse(_cache.alias(parts[1]) ?? '');
  }

  Future<bool> _offlineHandleAccessLoss(
    Uri uri,
    int status,
    Headers headers,
    ResponseBody? body, {
    CancelToken? cancelToken,
    int? aliasProject,
  }) async {
    final binding = _offlineBinding;
    final sink = _offlineAccessSink;
    if (binding == null ||
        sink == null ||
        body == null ||
        (status != 403 && status != 404) ||
        (headers.value('content-type') ?? '')
                .split(';')
                .first
                .trim()
                .toLowerCase() !=
            'application/json') {
      return false;
    }
    final parts = _cache.path(uri);
    if (parts.length < 2 || parts.first != 'projects') return false;
    // Alias refusals are ambiguous: defer them to a numeric project probe.
    final id = int.tryParse(parts[1]);
    if ((id == null || id <= 0) &&
        (aliasProject == null || aliasProject <= 0)) {
      return false;
    }
    OfflineAccessScope? scope;
    if (parts.length == 2) {
      scope = OfflineAccessScope.project;
    } else if (status == 403 &&
        parts.length >= 4 &&
        parts[2] == 'repository' &&
        (const {
              'tree',
              'blobs',
              'files',
              'branches',
              'tags',
            }.contains(parts[3]) ||
            parts[3].startsWith('archive'))) {
      scope = OfflineAccessScope.repository;
    }
    if (scope == null &&
        !(status == 404 &&
            parts.length >= 4 &&
            parts[2] == 'repository' &&
            (const {
                  'tree',
                  'blobs',
                  'files',
                  'branches',
                  'tags',
                  'commits',
                }.contains(parts[3]) ||
                parts[3].startsWith('archive')))) {
      return false;
    }
    final iterator = StreamIterator<Uint8List>(body.stream);
    final bytes = BytesBuilder(copy: false);
    var complete = false;
    var oversized = false;
    final watch = Stopwatch()..start();
    try {
      while (true) {
        final remaining = const Duration(seconds: 5) - watch.elapsed;
        if (remaining <= Duration.zero) throw TimeoutException(null);
        final next = await Future.any<Object>([
          iterator.moveNext().timeout(remaining),
          if (cancelToken != null)
            cancelToken.whenCancel.then<Object>((_) => _rawStreamCancelled),
        ]);
        if (identical(next, _rawStreamCancelled)) return true;
        if (next != true) break;
        final chunk = iterator.current;
        if (bytes.length + chunk.length > 4096) {
          oversized = true;
          break;
        }
        bytes.add(chunk);
      }
      if (!oversized) {
        try {
          final json = jsonDecode(utf8.decode(bytes.takeBytes()));
          complete =
              json is Map<String, dynamic> &&
              (json.containsKey('message') || json.containsKey('error'));
        } on FormatException {
          // Proxy and malformed bodies never revoke a snapshot.
        }
      }
    } on Object {
      // An interrupted error body cannot establish a GitLab refusal.
    } finally {
      await iterator.cancel();
    }
    if (complete &&
        !_closed &&
        _offlineBinding == binding &&
        _cache.accountKey == binding.accountKey &&
        _cache.generation == binding.generation) {
      (Zone.current[#offlineGitLabError] as void Function(Uri, int)?)?.call(
        uri,
        status,
      );
      if (scope == null) return true;
      if (id == null) {
        _offlineAliasProbeSink?.call(binding, aliasProject!);
      } else {
        sink(
          OfflineAccessLoss(
            binding: binding,
            projectId: id,
            scope: scope,
            status: status,
          ),
        );
      }
    }
    return true;
  }

  bool _offlineNeedsValidation(Headers headers) {
    if (_offlineBinding == null ||
        _offlineValidatedSink == null ||
        _closed ||
        (headers.value('content-type') ?? '')
                .split(';')
                .first
                .trim()
                .toLowerCase() !=
            'application/json') {
      return false;
    }
    final now = _readCacheClock().toUtc();
    final previous = _offlineLastValidated;
    return previous == null ||
        now.year != previous.year ||
        now.month != previous.month ||
        now.day != previous.day;
  }

  void _offlineNoteValidatedJson(Headers headers, Uint8List bytes) {
    final binding = _offlineBinding;
    final sink = _offlineValidatedSink;
    if (binding == null ||
        sink == null ||
        _closed ||
        _cache.accountKey != binding.accountKey ||
        _cache.generation != binding.generation ||
        (headers.value('content-type') ?? '')
                .split(';')
                .first
                .trim()
                .toLowerCase() !=
            'application/json') {
      return;
    }
    final now = _readCacheClock().toUtc();
    final previous = _offlineLastValidated;
    if (previous != null &&
        now.year == previous.year &&
        now.month == previous.month &&
        now.day == previous.day) {
      return;
    }
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> && value is! List<dynamic>) return;
    } on FormatException {
      return;
    }
    _offlineLastValidated = now;
    sink(binding);
  }

  Future<OfflineArchive> _offlineOpenArchive(
    Uri uri,
    CancelToken token, {
    required bool allowRefresh,
    Future<void> Function()? beforeSend,
  }) async {
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (!instance.allowsApi(uri)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    _checkRate(uri);
    final admission = RequestMeter.current?.beforeRequest;
    if (admission != null) await admission();
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    await beforeSend?.call();
    if (_closed || token.isCancelled) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    _checkRate(uri);
    final sequence = rateBudget.nextSequence();
    RequestMeter.current?.increment();
    Response<ResponseBody> response;
    try {
      response = await _dio.requestUri<ResponseBody>(
        uri,
        cancelToken: token,
        options: Options(
          method: 'GET',
          responseType: ResponseType.stream,
          // `null` inherits BaseOptions; zero disables Dio's byte timeout.
          receiveTimeout: Duration.zero,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) => status != null,
          headers: {..._authHeaders, 'Accept': 'application/octet-stream'},
        ),
      );
    } on DioException catch (error) {
      if (_closed ||
          token.isCancelled ||
          error.type == DioExceptionType.cancel) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    }
    _noteRateLimit(response, uri, sequence);
    final status = response.statusCode ?? 0;
    final body = response.data;
    if (status < 200 || status >= 300) {
      _cache.revoke(
        uri,
        status,
        terminal401: _credential is! OAuthCredential || !allowRefresh,
      );
      final consumed = await _offlineHandleAccessLoss(
        uri,
        status,
        response.headers,
        body,
        cancelToken: token,
      );
      await _cache.settleDiskSafety();
      if (!consumed) await _releaseBody(body);
      if (_closed || token.isCancelled) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      if (status == 401 && allowRefresh) {
        var refreshed = false;
        try {
          refreshed = await _refreshOAuth();
        } catch (_) {
          _cache.revoke(uri, 401);
          await _cache.settleDiskSafety();
          if (_closed || token.isCancelled) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          rethrow;
        }
        if (refreshed) {
          return _offlineOpenArchive(
            uri,
            token,
            allowRefresh: false,
            beforeSend: beforeSend,
          );
        }
        if (_credential is OAuthCredential) {
          _cache.revoke(uri, 401);
          await _cache.settleDiskSafety();
        }
      }
      throw ApiFailure.fromStatus(
        status,
        retryAt: rateBudget.retryAtFor(_rateClass(uri)),
      );
    }
    if (_offlineNoStore(response.headers)) {
      await _releaseBody(body);
      throw const OfflineRequestFailure(
        OfflineRequestFailureKind.serverForbidsStorage,
      );
    }
    if (body == null) throw const ApiFailure(FailureKind.invalidResponse);
    const maxBytes = 300 * 1024 * 1024;
    final declared = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    if (declared != null && declared > maxBytes) {
      await _releaseBody(body);
      throw const OfflineRequestFailure(
        OfflineRequestFailureKind.archiveTooLarge,
      );
    }
    void cancel() {
      if (!token.isCancelled) token.cancel();
      _requests.remove(token);
    }

    Stream<Uint8List> stream() async* {
      final iterator = StreamIterator<Uint8List>(body.stream);
      var count = 0;
      try {
        while (true) {
          final next = await Future.any<Object>([
            iterator.moveNext(),
            token.whenCancel.then<Object>((_) => _rawStreamCancelled),
          ]);
          if (identical(next, _rawStreamCancelled) || _closed) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          if (next != true) break;
          final chunk = iterator.current;
          count += chunk.length;
          if (count > maxBytes) {
            throw const OfflineRequestFailure(
              OfflineRequestFailureKind.archiveTooLarge,
            );
          }
          yield chunk;
        }
      } on ApiFailure {
        rethrow;
      } on OfflineRequestFailure {
        rethrow;
      } on Object {
        if (_closed || token.isCancelled) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        throw const ApiFailure(FailureKind.network);
      } finally {
        await iterator.cancel();
        cancel();
      }
    }

    return OfflineArchive._(stream(), cancel);
  }
}
