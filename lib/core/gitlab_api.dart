import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'failure.dart';
import 'instance.dart';
import 'models.dart';
import 'oauth.dart';
import 'pagination.dart';

part 'workspace_api.dart';

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
  bool _closed = false;
  DateTime? _retryAt;
  static const maxTextBytes = 2 * 1024 * 1024;
  static const maxTextLines = 20000;

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
          contentType: data == null ? null : Headers.jsonContentType,
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

  void close() {
    _closed = true;
    for (final token in _requests.toList()) {
      token.cancel('session ended');
    }
    _requests.clear();
    _dio.close(force: true);
  }
}
