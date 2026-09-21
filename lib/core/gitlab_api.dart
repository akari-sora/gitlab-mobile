import 'dart:async';
import 'dart:convert';
import 'dart:io' show FileSystemException, HttpDate, IOSink;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'failure.dart';
import 'instance.dart';
import 'models.dart';
import 'oauth.dart';
import 'pagination.dart';

part 'workspace_api.dart';

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
    OAuthTokenClient? oauth,
    Future<void> Function(OAuthCredential rotated)? onOAuthRotated,
  }) : _credential = credential ?? PatCredential(token ?? ''),
       _dio = dio ?? Dio(),
       _oauth = oauth,
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
  final OAuthTokenClient? _oauth;
  final Future<void> Function(OAuthCredential rotated)? _onOAuthRotated;
  Future<void>? _refreshing;
  final Set<CancelToken> _requests = {};
  final Set<Dio> _bareClients = {};
  bool _closed = false;
  DateTime? _retryAt;
  static const maxTextBytes = 2 * 1024 * 1024;
  static const maxTextLines = 20000;
  static const maxUploadBytes = 25 * 1024 * 1024;
  static const maxArtifactBytes = 256 * 1024 * 1024;

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

  Future<({Uint8List bytes, Headers headers})> _read(
    Uri uri, {
    String method = 'GET',
    Object? data,
    int maxBytes = 4 * 1024 * 1024,
    bool retried = false,
  }) => _send(
    uri,
    method: method,
    data: data,
    maxBytes: maxBytes,
    retried: retried,
  );

  /// Shared request path for JSON calls and multipart uploads.
  /// JSON content-type is applied only when [data] is present and is not [FormData].
  Future<({Uint8List bytes, Headers headers})> _send(
    Uri uri, {
    String method = 'GET',
    Object? data,
    int maxBytes = 4 * 1024 * 1024,
    bool retried = false,
  }) async {
    if (_closed) throw const ApiFailure(FailureKind.cancelled);
    if (!instance.allowsApi(uri)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final until = _retryAt;
    if (until != null && DateTime.now().isBefore(until)) {
      throw ApiFailure(FailureKind.rateLimited, status: 429, retryAt: until);
    }
    final cancel = CancelToken();
    _requests.add(cancel);
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
          headers: _authHeaders,
        ),
      );
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
      final status = response.statusCode ?? 0;
      final body = response.data;
      if (status < 200 || status >= 300) {
        if (body != null) await body.stream.listen((_) {}).cancel();
        if (status == 401 && !retried && await _refreshOAuth()) {
          if (method == 'GET' || method == 'HEAD') {
            return await _read(
              uri,
              method: method,
              data: data,
              maxBytes: maxBytes,
              retried: true,
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
        return (bytes: Uint8List(0), headers: response.headers);
      }
      if (body == null) throw const ApiFailure(FailureKind.invalidResponse);
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (length != null && length > maxBytes) {
        await body.stream.listen((_) {}).cancel();
        throw const ApiFailure(FailureKind.tooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (_closed) throw const ApiFailure(FailureKind.cancelled);
        if (bytes.length + chunk.length > maxBytes) {
          cancel.cancel('response budget exceeded');
          throw const ApiFailure(FailureKind.tooLarge);
        }
        bytes.add(chunk);
      }
      if (_closed) throw const ApiFailure(FailureKind.cancelled);
      return (bytes: bytes.takeBytes(), headers: response.headers);
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel || _closed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw ApiFailure(
        method == 'GET' || method == 'HEAD'
            ? FailureKind.network
            : FailureKind.writeUncertain,
      );
    } finally {
      _requests.remove(cancel);
    }
  }

  Future<Map<String, dynamic>> _object(
    Uri uri, {
    String method = 'GET',
    Object? data,
  }) async {
    try {
      final result = await _read(uri, method: method, data: data);
      return objectJson(jsonDecode(utf8.decode(result.bytes)));
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

  Future<Project> project(String idOrFullPath) async =>
      Project.fromJson(await _object(instance.api(['projects', idOrFullPath])));

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

  Future<String> textFile(int projectId, String sha, String filePath) async {
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
    );
    final size = int.tryParse(meta.headers.value('x-gitlab-size') ?? '');
    if (size != null && size > maxTextBytes) {
      throw const ApiFailure(FailureKind.tooLarge);
    }
    final result = await _read(
      instance.api([...segments, 'raw'], {'ref': sha, 'lfs': 'false'}),
      maxBytes: maxTextBytes,
    );
    if (result.bytes.contains(0)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    try {
      final text = utf8.decode(result.bytes);
      if ('\n'.allMatches(text).length + 1 > maxTextLines) {
        throw const ApiFailure(FailureKind.tooLarge);
      }
      return text;
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

  /// CDN hop. A fresh client so [_dio] defaults, interceptors, and its cookie
  /// jar cannot ride along. Test adapters are forwarded without being closed.
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
    final adapter = _dio.httpClientAdapter;
    if (adapter is! IOHttpClientAdapter) {
      dio.httpClientAdapter = _ForwardingAdapter(adapter);
    }
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

  void close() {
    _closed = true;
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
