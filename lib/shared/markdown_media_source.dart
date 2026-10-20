import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/instance.dart';
import 'attachment_ref.dart';

enum MarkdownMediaSourceKind { upload, repository, external, data, blocked }

final class MarkdownMediaNotImage implements Exception {
  const MarkdownMediaNotImage();
}

/// A Markdown media target after its trust boundary and repository coordinate
/// have been determined. Only fields meaningful for [kind] are populated.
final class MarkdownMediaSource {
  const MarkdownMediaSource({
    required this.kind,
    this.project,
    this.path,
    this.ref,
    this.uri,
    this.bytes,
    this.filename,
  });

  final MarkdownMediaSourceKind kind;
  final String? project;
  final String? path;
  final String? ref;
  final Uri? uri;
  final Uint8List? bytes;
  final String? filename;

  String get cacheKey => switch (kind) {
    MarkdownMediaSourceKind.repository ||
    MarkdownMediaSourceKind.upload => '${kind.name}:$project:$ref:$path',
    MarkdownMediaSourceKind.data =>
      '${kind.name}:${sha256.convert(bytes ?? const <int>[])}',
    _ => '${kind.name}:${uri?.toString() ?? ''}',
  };
}

const _externalImageBytes = 5 * 1024 * 1024;
const _repositoryImageBytes = 10 * 1024 * 1024;
const _mediaBytes = 100 * 1024 * 1024;
const _maxDataUriLength = (_externalImageBytes * 4 ~/ 3) + 4096;

/// Resolves a Markdown target without making a network request.
MarkdownMediaSource resolveMarkdownMedia(
  Uri uri, {
  Uri? base,
  GitLabInstance? instance,
  int? projectId,
  Uri? projectWeb,
}) {
  try {
    final upload = parseProjectUpload(
      uri,
      base: base,
      projectId: projectId,
      projectWeb: projectWeb,
    );
    if (upload != null) {
      return MarkdownMediaSource(
        kind: MarkdownMediaSourceKind.upload,
        project: '$projectId',
        path: '${upload.secret}/${upload.filename}',
        uri: projectWeb == null ? uri : projectUploadWeb(projectWeb, upload),
        filename: upload.filename,
      );
    }

    if (uri.scheme == 'data') return _dataSource(uri);
    if (uri.hasScheme || uri.host.isNotEmpty) {
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.host.isEmpty) {
        return _blocked(uri);
      }
      if (instance != null && instance.sameOrigin(uri)) {
        final repository = _absoluteRepository(
          uri,
          instance: instance,
          projectId: projectId,
          projectWeb: projectWeb,
        );
        if (repository != null) return repository;
      }
      return _safeExternal(uri) ? _external(uri) : _blocked(uri);
    }

    if (base == null || instance == null || !instance.sameOrigin(base)) {
      return _blocked(uri);
    }
    final coordinate = _blobCoordinate(base, instance);
    if (coordinate == null) return _blocked(uri);
    final path = _relativeRepositoryPath(uri, coordinate.path);
    if (path == null || path.isEmpty) return _blocked(uri);
    final currentProject = _isCurrentProject(
      coordinate.projectSegments,
      projectWeb,
      instance,
    );
    return MarkdownMediaSource(
      kind: MarkdownMediaSourceKind.repository,
      project: currentProject && projectId != null
          ? '$projectId'
          : coordinate.projectSegments.join('/'),
      path: path,
      ref: coordinate.ref,
      uri: uri,
      filename: path.split('/').last,
    );
  } on Object {
    return _blocked(uri);
  }
}

MarkdownMediaSource _dataSource(Uri uri) {
  if (uri.toString().length > _maxDataUriLength) return _blocked(uri);
  final data = uri.data;
  if (data == null ||
      !data.isBase64 ||
      !data.mimeType.toLowerCase().startsWith('image/')) {
    return _blocked(uri);
  }
  final bytes = Uint8List.fromList(data.contentAsBytes());
  if (bytes.length > _externalImageBytes) return _blocked(uri);
  final subtype = data.mimeType.split('/').last.split('+').first.toLowerCase();
  return MarkdownMediaSource(
    kind: MarkdownMediaSourceKind.data,
    uri: uri,
    bytes: bytes,
    filename: 'image.${subtype == 'jpeg' ? 'jpg' : subtype}',
  );
}

MarkdownMediaSource? _absoluteRepository(
  Uri uri, {
  required GitLabInstance instance,
  required int? projectId,
  required Uri? projectWeb,
}) {
  final segments = _withoutEmpty(uri.pathSegments);
  final prefix = _withoutEmpty(instance.base.pathSegments);
  if (!_startsWith(segments, prefix)) return null;
  final dash = _repositoryDash(segments, prefix.length);
  if (dash == null || dash + 3 >= segments.length) return null;
  final route = segments[dash + 1];
  if (route != 'raw' &&
      (route != 'blob' || uri.queryParameters['raw'] != 'true')) {
    return null;
  }
  final projectSegments = segments.sublist(prefix.length, dash);
  if (projectSegments.isEmpty) return null;
  final ref = segments[dash + 2];
  final pathSegments = segments.sublist(dash + 3);
  if (!_safeRepositorySegments(pathSegments) ||
      pathSegments.isEmpty ||
      !_safeRef(ref)) {
    return _blocked(uri);
  }
  final currentProject = _isCurrentProject(
    projectSegments,
    projectWeb,
    instance,
  );
  final path = pathSegments.join('/');
  return MarkdownMediaSource(
    kind: MarkdownMediaSourceKind.repository,
    project: currentProject && projectId != null
        ? '$projectId'
        : projectSegments.join('/'),
    path: path,
    ref: ref,
    uri: uri,
    filename: pathSegments.last,
  );
}

({List<String> projectSegments, String ref, String path})? _blobCoordinate(
  Uri base,
  GitLabInstance instance,
) {
  final segments = _withoutEmpty(base.pathSegments);
  final prefix = _withoutEmpty(instance.base.pathSegments);
  if (!_startsWith(segments, prefix)) return null;
  final dash = _repositoryDash(segments, prefix.length);
  if (dash == null ||
      dash + 3 >= segments.length ||
      segments[dash + 1] != 'blob') {
    return null;
  }
  final project = segments.sublist(prefix.length, dash);
  final ref = segments[dash + 2];
  final path = segments.sublist(dash + 3);
  if (project.isEmpty ||
      !_safeRef(ref) ||
      !_safeRepositorySegments(path) ||
      path.isEmpty) {
    return null;
  }
  return (projectSegments: project, ref: ref, path: path.join('/'));
}

int? _repositoryDash(List<String> segments, int start) {
  for (var i = start + 1; i + 1 < segments.length; i++) {
    if (segments[i] == '-' &&
        (segments[i + 1] == 'blob' || segments[i + 1] == 'raw')) {
      return i;
    }
  }
  return null;
}

String? _relativeRepositoryPath(Uri uri, String basePath) {
  if (uri.query.isNotEmpty && uri.path.isEmpty) return null;
  final output = uri.path.startsWith('/')
      ? <String>[]
      : (basePath.split('/')..removeLast());
  for (final segment in uri.pathSegments) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (output.isEmpty) return null;
      output.removeLast();
      continue;
    }
    if (!_safePathSegment(segment)) return null;
    output.add(segment);
  }
  return output.join('/');
}

bool _isCurrentProject(
  List<String> project,
  Uri? projectWeb,
  GitLabInstance instance,
) {
  if (projectWeb == null || !instance.sameOrigin(projectWeb)) return false;
  final web = _withoutEmpty(projectWeb.pathSegments);
  final prefix = _withoutEmpty(instance.base.pathSegments);
  if (!_startsWith(web, prefix)) return false;
  final webProject = web.sublist(prefix.length);
  return _sameSegments(project, webProject);
}

bool _safeRepositorySegments(List<String> segments) =>
    segments.every(_safePathSegment);

bool _safePathSegment(String segment) =>
    segment.isNotEmpty &&
    segment != '.' &&
    segment != '..' &&
    !segment.contains('/') &&
    !segment.contains(r'\');

bool _safeRef(String ref) =>
    ref.isNotEmpty && ref != '.' && ref != '..' && !ref.contains(r'\');

List<String> _withoutEmpty(List<String> values) => [
  for (final value in values)
    if (value.isNotEmpty) value,
];

bool _startsWith(List<String> values, List<String> prefix) {
  if (prefix.length > values.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (values[i] != prefix[i]) return false;
  }
  return true;
}

bool _sameSegments(List<String> left, List<String> right) =>
    left.length == right.length && _startsWith(left, right);

MarkdownMediaSource _external(Uri uri) => MarkdownMediaSource(
  kind: MarkdownMediaSourceKind.external,
  uri: uri,
  filename: _safeFilename(uri),
);

MarkdownMediaSource _blocked(Uri uri) => MarkdownMediaSource(
  kind: MarkdownMediaSourceKind.blocked,
  uri: uri,
  filename: _safeFilename(uri),
);

String? _safeFilename(Uri uri) {
  try {
    return uri.pathSegments.isEmpty ? null : uri.pathSegments.last;
  } on FormatException {
    return null;
  }
}

bool _safeExternal(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  final ipv4 = InternetAddress.tryParse(host);
  if (ipv4 == null) return true;
  if (ipv4.type == InternetAddressType.IPv4) {
    return _safeIpv4(ipv4.rawAddress);
  }
  final b = ipv4.rawAddress;
  final mappedIpv4 =
      b.take(10).every((value) => value == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mappedIpv4) return _safeIpv4(b.sublist(12));
  final compatibleIpv4 = b.take(12).every((value) => value == 0);
  if (compatibleIpv4) return _safeIpv4(b.sublist(12));
  final unspecified = b.every((value) => value == 0);
  final loopback = b.take(15).every((value) => value == 0) && b[15] == 1;
  final linkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80;
  final uniqueLocal = (b[0] & 0xfe) == 0xfc;
  final multicast = b[0] == 0xff;
  return !(unspecified || loopback || linkLocal || uniqueLocal || multicast);
}

bool _safeIpv4(List<int> b) =>
    !(b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        b[0] >= 224);

/// Loads resolved media. The external client is deliberately separate from
/// [GitLabApi], and receives no account headers or cookies from it.
final class MarkdownMediaLoader {
  MarkdownMediaLoader({GitLabApi? api, Dio? external})
    : _api = api,
      _external = _bareExternal(external);

  final GitLabApi? _api;
  final Dio _external;
  final Set<CancelToken> _requests = <CancelToken>{};
  bool _closed = false;

  Future<Uint8List> load(
    MarkdownMediaSource source, {
    bool image = true,
    CancelToken? cancelToken,
    void Function(int, int?)? onProgress,
    IOSink? sink,
  }) async {
    if (_closed || cancelToken?.isCancelled == true) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    final operation = cancelToken ?? CancelToken();
    _requests.add(operation);
    try {
      switch (source.kind) {
        case MarkdownMediaSourceKind.data:
          final bytes = source.bytes;
          if (bytes == null) {
            throw const ApiFailure(FailureKind.invalidResponse);
          }
          sink?.add(bytes);
          await sink?.flush();
          onProgress?.call(bytes.length, bytes.length);
          return sink == null ? bytes : Uint8List(0);
        case MarkdownMediaSourceKind.repository:
          final api = _api;
          if (api == null ||
              source.project == null ||
              source.ref == null ||
              source.path == null) {
            throw const ApiFailure(FailureKind.unsupported);
          }
          return await api.rawFileBytes(
            source.project!,
            source.ref!,
            source.path!,
            maxBytes: image ? _repositoryImageBytes : _mediaBytes,
            cancelToken: operation,
            onProgress: onProgress,
            sink: sink,
          );
        case MarkdownMediaSourceKind.upload:
          return await _loadUpload(
            source,
            image: image,
            cancelToken: operation,
            onProgress: onProgress,
            sink: sink,
          );
        case MarkdownMediaSourceKind.external:
          final uri = source.uri;
          if (uri == null) throw const ApiFailure(FailureKind.invalidResponse);
          return await _loadExternal(
            uri,
            image: image,
            cancelToken: operation,
            onProgress: onProgress,
            sink: sink,
          );
        case MarkdownMediaSourceKind.blocked:
          throw const ApiFailure(FailureKind.unsupported);
      }
    } finally {
      _requests.remove(operation);
    }
  }

  Future<Uint8List> _loadUpload(
    MarkdownMediaSource source, {
    required bool image,
    required CancelToken? cancelToken,
    required void Function(int, int?)? onProgress,
    required IOSink? sink,
  }) async {
    final api = _api;
    final project = int.tryParse(source.project ?? '');
    final parts = source.path?.split('/') ?? const <String>[];
    if (api == null || project == null || parts.length != 2) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final builder = sink == null ? BytesBuilder(copy: false) : null;
    final output = sink ?? IOSink(_BytesConsumer(builder!));
    final cancelled = Completer<void>();
    if (cancelToken != null) {
      if (cancelToken.isCancelled) {
        cancelled.complete();
      } else {
        unawaited(
          cancelToken.whenCancel.then((_) {
            if (!cancelled.isCompleted) cancelled.complete();
          }),
        );
      }
    }
    try {
      await api.downloadProjectUpload(
        project,
        parts[0],
        parts[1],
        sink: output,
        onProgress: onProgress,
        cancel: cancelToken == null ? null : cancelled.future,
        maxBytes: image ? _repositoryImageBytes : _mediaBytes,
      );
      await output.flush();
      return builder?.takeBytes() ?? Uint8List(0);
    } finally {
      if (sink == null) await output.close();
    }
  }

  Future<Uint8List> _loadExternal(
    Uri initial, {
    required bool image,
    required CancelToken? cancelToken,
    required void Function(int, int?)? onProgress,
    required IOSink? sink,
  }) async {
    var uri = initial;
    final token = cancelToken ?? CancelToken();
    _requests.add(token);
    final maxBytes = image ? _externalImageBytes : _mediaBytes;
    try {
      for (var redirects = 0; redirects <= 3; redirects++) {
        if (!_safeExternal(uri)) {
          throw const ApiFailure(FailureKind.unsupported);
        }
        final response = await _external.requestUri<ResponseBody>(
          uri,
          cancelToken: token,
          options: Options(
            method: 'GET',
            responseType: ResponseType.stream,
            followRedirects: false,
            maxRedirects: 0,
            validateStatus: (status) => status != null,
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 25),
            headers: const {
              'User-Agent': 'Mergeline/1.0 Markdown media',
              'Accept': 'image/*,video/*,audio/*;q=0.9,*/*;q=0.1',
            },
          ),
        );
        final status = response.statusCode ?? 0;
        if (status >= 300 && status < 400) {
          await _release(response.data);
          if (redirects == 3) {
            throw ApiFailure(FailureKind.redirectBlocked, status: status);
          }
          final location = response.headers.value('location');
          final next = location == null ? null : uri.resolve(location);
          if (next == null || !_safeExternal(next)) {
            throw ApiFailure(FailureKind.redirectBlocked, status: status);
          }
          uri = next;
          continue;
        }
        if (status < 200 || status >= 300) {
          await _release(response.data);
          throw ApiFailure.fromStatus(status);
        }
        final type = (response.headers.value(Headers.contentTypeHeader) ?? '')
            .split(';')
            .first
            .trim()
            .toLowerCase();
        if (image && !type.startsWith('image/')) {
          await _release(response.data);
          throw const MarkdownMediaNotImage();
        }
        if (!image && !_mediaType(type)) {
          await _release(response.data);
          throw const ApiFailure(FailureKind.unsupported);
        }
        return await _readBody(
          response,
          token: token,
          maxBytes: maxBytes,
          onProgress: onProgress,
          sink: sink,
        );
      }
      throw const ApiFailure(FailureKind.redirectBlocked);
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel ||
          token.isCancelled ||
          _closed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    } finally {
      _requests.remove(token);
    }
  }

  static bool _mediaType(String type) =>
      type.startsWith('video/') ||
      type.startsWith('audio/') ||
      type == 'application/octet-stream';

  static Future<Uint8List> _readBody(
    Response<ResponseBody> response, {
    required CancelToken token,
    required int maxBytes,
    required void Function(int, int?)? onProgress,
    required IOSink? sink,
  }) async {
    final total = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (total != null && total > maxBytes) {
      token.cancel('markdown media exceeds byte budget');
      await _release(response.data);
      throw const ApiFailure(FailureKind.tooLarge);
    }
    final body = response.data;
    if (body == null) throw const ApiFailure(FailureKind.invalidResponse);
    final bytes = sink == null ? BytesBuilder(copy: false) : null;
    var received = 0;
    await for (final chunk in body.stream) {
      if (token.isCancelled) throw const ApiFailure(FailureKind.cancelled);
      if (received + chunk.length > maxBytes) {
        token.cancel('markdown media exceeds byte budget');
        throw const ApiFailure(FailureKind.tooLarge);
      }
      sink?.add(chunk);
      bytes?.add(chunk);
      if (sink != null) await sink.flush();
      received += chunk.length;
      onProgress?.call(received, total);
    }
    if (received == 0) onProgress?.call(0, total);
    return bytes?.takeBytes() ?? Uint8List(0);
  }

  static Future<void> _release(ResponseBody? body) async {
    try {
      await body?.stream.listen((_) {}).cancel();
    } on Object {
      return;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final token in _requests.toList()) {
      if (!token.isCancelled) token.cancel('markdown media loader closed');
    }
    _requests.clear();
    _external.close(force: true);
  }
}

final class _BytesConsumer implements StreamConsumer<List<int>> {
  const _BytesConsumer(this.builder);
  final BytesBuilder builder;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      builder.add(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

Dio _bareExternal(Dio? supplied) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
    ),
  );
  if (supplied != null) dio.httpClientAdapter = supplied.httpClientAdapter;
  return dio;
}
