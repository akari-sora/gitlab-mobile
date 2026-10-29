// Live egress is reachable only after the shared session's final guards.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'sandbox_contract.dart';
import 'session_transport.dart';

final class Mr7LiveGitLab implements Mr7SessionTransport {
  Mr7LiveGitLab(String pat) : this._(pat, Uri.parse('https://gitlab.com'));

  /// The only alternate origin is an explicit numeric-loopback test server.
  factory Mr7LiveGitLab.forTesting(String pat, Uri loopback) {
    if (loopback.scheme != 'http' ||
        loopback.host != '127.0.0.1' ||
        loopback.path.isNotEmpty ||
        loopback.userInfo.isNotEmpty ||
        loopback.hasQuery ||
        loopback.hasFragment) {
      throw const Mr7Refused('testLoopbackRequired');
    }
    return Mr7LiveGitLab._(pat, Uri.parse('https://gitlab.com'), loopback);
  }

  Mr7LiveGitLab._(this.gitLabToken, this.instance, [this._loopback]) {
    if (gitLabToken.isEmpty || RegExp(r'\s').hasMatch(gitLabToken)) {
      throw const Mr7Refused('credentialInvalid');
    }
  }

  @override
  final String gitLabToken;
  final Uri instance;
  final Uri? _loopback;
  final HttpClientAdapter _writer = IOHttpClientAdapter();
  final HttpClientAdapter _observer = IOHttpClientAdapter();
  DateTime? _serverTime;
  @override
  int setupWrites = 0;
  @override
  int projectId = 0;
  bool _closed = false;
  int? _userId, _namespaceId;
  String? _namespace;
  bool _actorVerified = false;
  void Function(RequestOptions)? _beforeAdditionalRead;

  @override
  void bindSession({
    required int userId,
    required String namespace,
    required void Function(RequestOptions) beforeAdditionalRead,
  }) {
    if (_userId != null) throw const Mr7Refused('noResume');
    _userId = userId;
    _namespace = namespace;
    _beforeAdditionalRead = beforeAdditionalRead;
  }

  @override
  DateTime get serverTime =>
      _serverTime ?? (throw const Mr7Refused('serverTimeUnverified'));

  @override
  Future<ResponseBody> send(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancellation, {
    required bool observation,
  }) async {
    final uri = request.uri;
    if (_closed ||
        uri.origin != instance.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        request.followRedirects ||
        (!uri.path.startsWith('/api/v4/') && uri.path != '/api/graphql')) {
      throw const Mr7Refused('instanceOrRedirect');
    }
    if (observation &&
        request.method != 'GET' &&
        !(request.method == 'POST' && uri.path == '/api/graphql')) {
      throw const Mr7Refused('observerReadOnly');
    }
    // Authentication is bound here as well as in the production GitLabApi.
    final headers = <String, dynamic>{
      for (final entry in request.headers.entries)
        if (!const {
          'authorization',
          'private-token',
          'x-api-key',
          'api-key',
          'cache-control',
        }.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
      if (uri.path == '/api/graphql')
        'Authorization': 'Bearer $gitLabToken'
      else
        'PRIVATE-TOKEN': gitLabToken,
      'cache-control': 'no-cache, no-store',
    };
    final outgoing = request.copyWith(
      headers: headers,
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
    );
    final setup = request.method == 'POST' && uri.path == '/api/v4/projects';
    if (setup) {
      if (setupWrites != 0) throw const Mr7Refused('noResume');
      setupWrites++; // Consumed before dispatch, including an uncertain reply.
    }
    var selected = outgoing;
    if (request.method == 'GET' && uri.path == '/api/v4/namespaces') {
      if (!_actorVerified) throw const Mr7Refused('userIdentity');
      selected = outgoing.copyWith(
        queryParameters: {
          'owned_only': true,
          'search': _namespace,
          'per_page': 100,
        },
      );
    }
    // GitLab lists a user's personal projects at this endpoint. A namespace_id
    // query on the global projects endpoint does not establish that boundary.
    if (request.method == 'GET' && uri.path == '/api/v4/projects') {
      if (!_actorVerified ||
          _namespaceId == null ||
          request.queryParameters['namespace_id'] != _namespaceId) {
        throw const Mr7Refused('cleanupMalformed');
      }
      selected = outgoing.copyWith(
        path: 'users/$_userId/projects',
        queryParameters: Map.of(request.queryParameters)
          ..remove('namespace_id'),
      );
    }
    var response = await _fetch(
      selected,
      body,
      cancellation,
      observation: observation,
    );
    if (response.statusCode == 200 &&
        request.method == 'GET' &&
        (uri.path == '/api/v4/user' ||
            uri.path == '/api/v4/namespaces' ||
            (observation &&
                RegExp(
                  r'^/api/v4/projects/[1-9][0-9]*$',
                ).hasMatch(uri.path)))) {
      final bytes = await _bytes(response);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (uri.path == '/api/v4/user') {
        _actorVerified =
            decoded is Map &&
            decoded['id'] == _userId &&
            decoded['username'] == _namespace;
      }
      if (uri.path == '/api/v4/namespaces' && decoded is List) {
        for (final row in decoded.whereType<Map<String, dynamic>>()) {
          if (row['full_path'] == _namespace &&
              row['kind'] == 'user' &&
              row['id'] is int &&
              (row['id'] as int) > 0 &&
              (!row.containsKey('owner_id') || row['owner_id'] == _userId)) {
            // Personal namespace full_path is the freshly verified username;
            // namespace responses need not carry the synthetic owner_id field.
            row['owner_id'] = _userId;
            _namespaceId = row['id'] as int;
          }
        }
      }
      if (observation &&
          RegExp(r'^/api/v4/projects/[1-9][0-9]*$').hasMatch(uri.path) &&
          decoded is Map) {
        if (!_actorVerified || decoded['id'] != projectId || projectId <= 0) {
          throw const Mr7Refused('readbackIdentity');
        }
        // Derive actor state from fresh, complete starrers responses on the
        // independent observer. Never trust the synthetic project field.
        decoded['starred'] = await _starred(outgoing, cancellation);
      }
      response = ResponseBody.fromString(
        jsonEncode(decoded),
        response.statusCode,
        headers: _jsonHeaders(response.headers),
        statusMessage: response.statusMessage,
      );
    } else if (setup &&
        response.statusCode >= 200 &&
        response.statusCode < 300) {
      final bytes = await _bytes(response);
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map && value['id'] is int) projectId = value['id'] as int;
      response = ResponseBody.fromBytes(
        bytes,
        response.statusCode,
        headers: response.headers,
        statusMessage: response.statusMessage,
      );
    }
    final bytes = await _bytes(response);
    return ResponseBody.fromBytes(
      bytes,
      response.statusCode,
      headers: response.headers,
      isRedirect: response.isRedirect,
      statusMessage: response.statusMessage,
    );
  }

  Map<String, List<String>> _jsonHeaders(Map<String, List<String>> original) =>
      {
        for (final entry in original.entries)
          if (!const {
            'content-length',
            'content-encoding',
          }.contains(entry.key.toLowerCase()))
            entry.key: entry.value,
      };

  Future<ResponseBody> _fetch(
    RequestOptions outgoing,
    Stream<Uint8List>? body,
    Future<void>? cancellation, {
    required bool observation,
  }) async {
    final uri = outgoing.uri;
    final networkRequest = _loopback == null
        ? outgoing
        : outgoing.copyWith(
            baseUrl: '',
            path: _loopback
                .replace(path: uri.path, query: uri.hasQuery ? uri.query : null)
                .toString(),
          );
    final response = await runZoned(
      () => (observation ? _observer : _writer).fetch(
        networkRequest,
        body,
        cancellation,
      ),
      zoneValues: _loopback == null ? const {} : {#flutter.io.allow_http: true},
    );
    // A 429 carries no data and is classified by the session even when a rate
    // limiter omits Date; it never advances the verified server time.
    if (response.statusCode == 429) return response;
    final date = response.headers['date'];
    if (date == null || date.length != 1) {
      throw const Mr7Refused('serverTimeUnverified');
    }
    try {
      final at = HttpDate.parse(date.single).toUtc();
      if (_serverTime != null &&
          at.isBefore(_serverTime!.subtract(const Duration(seconds: 2)))) {
        throw const Mr7Refused('serverTimeUnverified');
      }
      _serverTime = at;
    } on FormatException {
      throw const Mr7Refused('serverTimeUnverified');
    }
    return response;
  }

  Future<List<int>> _bytes(ResponseBody response) async {
    final bytes = <int>[];
    await for (final part in response.stream) {
      bytes.addAll(part);
      if (bytes.length > 2 * 1024 * 1024) {
        throw const Mr7Refused('responseBound');
      }
    }
    return bytes;
  }

  Future<bool> _starred(
    RequestOptions project,
    Future<void>? cancellation,
  ) async {
    int? expectedTotal, expectedPages;
    final users = <int>{};
    var found = false;
    for (var page = 1; page <= 20; page++) {
      final request = project.copyWith(
        path: 'projects/$projectId/starrers',
        queryParameters: {'search': _namespace, 'page': page, 'per_page': 100},
      );
      _beforeAdditionalRead!(request);
      final response = await _fetch(
        request,
        null,
        cancellation,
        observation: true,
      );
      if (response.statusCode == 429) throw Mr7RateLimited(response.headers);
      final decoded = jsonDecode(utf8.decode(await _bytes(response)));
      String header(String key) {
        final value = response.headers[key];
        if (value == null || value.length != 1) {
          throw const Mr7Refused('paginationIncomplete');
        }
        return value.single;
      }

      int number(String key) {
        final value = header(key);
        if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
          throw const Mr7Refused('paginationMalformed');
        }
        return int.parse(value);
      }

      if (response.statusCode != 200 || decoded is! List) {
        throw const Mr7Refused('paginationUnreadable');
      }
      final total = number('x-total'), pages = number('x-total-pages');
      if (number('x-page') != page ||
          number('x-per-page') != 100 ||
          pages > 20 ||
          (pages > 0 && page > pages) ||
          (total == 0
              ? pages != 0 && pages != 1
              : pages != (total + 99) ~/ 100) ||
          (expectedTotal != null &&
              (total != expectedTotal || pages != expectedPages)) ||
          decoded.length != (page < pages ? 100 : total - (page - 1) * 100) ||
          header('x-next-page') != (page < pages ? '${page + 1}' : '')) {
        throw const Mr7Refused('paginationIncomplete');
      }
      expectedTotal = total;
      expectedPages = pages;
      for (final row in decoded) {
        final user = row is Map ? row['user'] : null;
        if (user is! Map ||
            user['id'] is! int ||
            (user['id'] as int) <= 0 ||
            user['username'] is! String ||
            !users.add(user['id'] as int)) {
          throw const Mr7Refused('observerState');
        }
        if (user['id'] == _userId && user['username'] == _namespace) {
          found = true;
        }
        if ((user['id'] == _userId) != (user['username'] == _namespace)) {
          throw const Mr7Refused('userIdentity');
        }
      }
      if (page >= pages) return found;
    }
    throw const Mr7Refused('paginationIncomplete');
  }

  @override
  void close() {
    _closed = true;
    _writer.close(force: true);
    _observer.close(force: true);
  }
}
