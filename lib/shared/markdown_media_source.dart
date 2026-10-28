import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/instance.dart';
import '../core/offline/snapshot_media_policy.dart';
import '../core/offline/snapshot_reader.dart';
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
    if (!uri.hasScheme && uri.host.isNotEmpty) {
      uri = uri.replace(scheme: 'https');
    }
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
  if (!_safeRepositorySegments(projectSegments) ||
      !_safeRepositorySegments(pathSegments) ||
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
      !_safeRepositorySegments(project) ||
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
    !segment.contains(r'\') &&
    !segment.runes.any(_controlCharacter);

bool _safeRef(String ref) {
  return ref.split('/').every(_safePathSegment);
}

bool _controlCharacter(int value) =>
    value <= 0x1f || (value >= 0x7f && value <= 0x9f);

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
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (host == 'localhost' || host.endsWith('.localhost')) return false;
  final labels = host.split('.');
  if (labels.isNotEmpty && labels.every(_numericHostLabel)) return false;
  final address = InternetAddress.tryParse(host);
  return address == null || _safeAddress(address);
}

bool _safeAddress(InternetAddress address, {bool allowLoopback = false}) {
  if (address.type == InternetAddressType.IPv4) {
    return _safeIpv4(address.rawAddress, allowLoopback: allowLoopback);
  }
  if (address.type != InternetAddressType.IPv6) return false;
  final b = address.rawAddress;
  final mappedIpv4 =
      b.take(10).every((value) => value == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mappedIpv4) {
    return _safeIpv4(b.sublist(12), allowLoopback: allowLoopback);
  }
  final translatedIpv4 =
      b.take(8).every((value) => value == 0) &&
      b[8] == 0xff &&
      b[9] == 0xff &&
      b[10] == 0 &&
      b[11] == 0;
  if (translatedIpv4) {
    return _safeIpv4(b.sublist(12), allowLoopback: allowLoopback);
  }
  final compatibleIpv4 = b.take(12).every((value) => value == 0);
  if (compatibleIpv4) {
    return _safeIpv4(b.sublist(12), allowLoopback: allowLoopback);
  }
  final unspecified = b.every((value) => value == 0);
  final loopback = b.take(15).every((value) => value == 0) && b[15] == 1;
  final linkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80;
  final siteLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0xc0;
  final uniqueLocal = (b[0] & 0xfe) == 0xfc;
  final multicast = b[0] == 0xff;
  final nat64 =
      b[0] == 0x00 &&
      b[1] == 0x64 &&
      b[2] == 0xff &&
      b[3] == 0x9b &&
      b.sublist(4, 12).every((value) => value == 0);
  if (nat64 && !_safeIpv4(b.sublist(12), allowLoopback: allowLoopback)) {
    return false;
  }
  final localUseNat64 =
      b[0] == 0x00 &&
      b[1] == 0x64 &&
      b[2] == 0xff &&
      b[3] == 0x9b &&
      b[4] == 0x00 &&
      b[5] == 0x01;
  if (localUseNat64) {
    final rfc6052 = <int>[b[6], b[7], b[9], b[10]];
    final trailing = b.sublist(12);
    final embedded = rfc6052.any((value) => value != 0) ? rfc6052 : trailing;
    if (!_safeIpv4(embedded, allowLoopback: allowLoopback)) {
      return false;
    }
  }
  final sixToFour = b[0] == 0x20 && b[1] == 0x02;
  if (sixToFour && !_safeIpv4(b.sublist(2, 6), allowLoopback: allowLoopback)) {
    return false;
  }
  return !(unspecified ||
      (!allowLoopback && loopback) ||
      linkLocal ||
      siteLocal ||
      uniqueLocal ||
      multicast);
}

bool _numericHostLabel(String label) {
  if (label.isEmpty) return false;
  if (label.length > 2 && label.startsWith('0x')) {
    return label
        .substring(2)
        .codeUnits
        .every(
          (value) =>
              (value >= 0x30 && value <= 0x39) ||
              (value >= 0x61 && value <= 0x66),
        );
  }
  return label.codeUnits.every((value) => value >= 0x30 && value <= 0x39);
}

bool _safeIpv4(List<int> b, {bool allowLoopback = false}) =>
    !(b[0] == 0 ||
        b[0] == 10 ||
        (!allowLoopback && b[0] == 127) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        b[0] >= 224);

String _normaliseContentType(String? value) =>
    (value ?? '').split(';').first.trim().toLowerCase();

/// Returns a conservative file extension for media players that require one.
String markdownMediaExtensionForContentType(String? contentType) =>
    switch (_normaliseContentType(contentType)) {
      'video/mp4' => '.mp4',
      'video/webm' => '.webm',
      'video/quicktime' => '.mov',
      'video/x-m4v' => '.m4v',
      'audio/mpeg' => '.mp3',
      'audio/mp4' || 'audio/x-m4a' => '.m4a',
      'audio/ogg' => '.ogg',
      'audio/wav' || 'audio/x-wav' => '.wav',
      'audio/webm' => '.webm',
      _ => '',
    };

/// Snapshot sources are deliberately separate from GitLabApi and cannot fall
/// back to a network client.
abstract interface class SnapshotMediaSource {
  Future<Uint8List> load(MarkdownMediaSource source, {required int maxBytes});
  void checkCurrent();
}

final class SnapshotReaderMediaSource implements SnapshotMediaSource {
  SnapshotReaderMediaSource({required this.reader, required this.projectPath,
      required this.refName});
  final SnapshotRepositoryReader reader;
  final String projectPath, refName;

  @override
  void checkCurrent() => reader.checkCurrent();

  @override
  Future<Uint8List> load(MarkdownMediaSource source, {required int maxBytes}) async {
    checkCurrent();
    final owner = reader.owner;
    final uri = source.uri;
    final path = source.path;
    final ref = source.ref;
    if (source.kind != MarkdownMediaSourceKind.repository || uri == null ||
        path == null || ref == null) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final instance = GitLabInstance.parse(owner.instanceKey);
    final relative = !uri.hasScheme && uri.host.isEmpty;
    var pathAtSource = projectPath;
    if (!relative) {
      if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || !instance.sameOrigin(uri)) {
        throw const ApiFailure(FailureKind.unsupported);
      }
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final prefix = instance.base.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < prefix.length + 5 ||
          !_startsWith(segments, prefix)) {
        throw const ApiFailure(FailureKind.unsupported);
      }
      final dash = _repositoryDash(segments, prefix.length);
      if (dash == null || dash + 3 >= segments.length ||
          (segments[dash + 1] != 'raw' &&
            (segments[dash + 1] != 'blob' || uri.queryParameters['raw'] != 'true')) ||
          segments[dash + 2] != ref || segments.sublist(dash + 3).join('/') != path) {
        throw const ApiFailure(FailureKind.unsupported);
      }
      pathAtSource = segments.sublist(prefix.length, dash).join('/');
    }
    final coordinate = SnapshotMediaCoordinate(accountKey: owner.accountKey,
      instanceKey: owner.instanceKey, projectId: int.tryParse(source.project ?? ''),
      projectPath: pathAtSource, ref: ref, path: path, relative: relative);
    final entry = await reader.snapshotEntry(path);
    checkCurrent();
    final policy = SnapshotMediaPolicy(accountKey: owner.accountKey,
      instanceKey: owner.instanceKey, projectId: owner.projectId, projectPath: projectPath,
      sha: owner.sha, refName: refName, subPath: owner.subPath);
    if (!policy.permits(coordinate, entry)) throw const ApiFailure(FailureKind.unsupported);
    final bytes = await reader.bytes(path, maxBytes: maxBytes);
    checkCurrent();
    return bytes;
  }
}

final class _BlockedAdapter implements HttpClientAdapter {
  int attempts = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    attempts++;
    throw const ApiFailure(FailureKind.unsupported);
  }
  @override
  void close({bool force = false}) {}
}

/// Loads resolved media. The external client is deliberately separate from
/// [GitLabApi], and receives no account headers or cookies from it.
final class MarkdownMediaLoader {
  MarkdownMediaLoader({
    GitLabApi? api,
    Dio? external,
    Duration externalImageTimeout = const Duration(seconds: 30),
    Future<List<InternetAddress>> Function(String host)? externalResolver,
    bool allowLoopbackAddressesForTesting = false,
    SecurityContext? externalSecurityContextForTesting,
  }) : _api = api,
       _snapshot = null,
       _blocked = null,
       _external = _bareExternal(
         external,
         resolver: externalResolver ?? InternetAddress.lookup,
         allowLoopback: allowLoopbackAddressesForTesting,
         securityContext: externalSecurityContextForTesting,
       ),
       _externalImageTimeout = externalImageTimeout;

  MarkdownMediaLoader.snapshot(SnapshotMediaSource source)
      : _api = null,
        _snapshot = source,
        _blocked = _BlockedAdapter(),
        _external = Dio(),
        _externalImageTimeout = const Duration(seconds: 30) {
    _external.httpClientAdapter = _blocked!;
  }

  final GitLabApi? _api;
  final SnapshotMediaSource? _snapshot;
  final _BlockedAdapter? _blocked;
  int get blockedNetworkAttempts => _blocked?.attempts ?? 0;
  final Dio _external;
  final Duration _externalImageTimeout;
  final Set<CancelToken> _requests = <CancelToken>{};
  bool _closed = false;

  Future<Uint8List> load(
    MarkdownMediaSource source, {
    bool image = true,
    CancelToken? cancelToken,
    void Function(int, int?)? onProgress,
    void Function(String)? onContentType,
    IOSink? sink,
  }) async {
    if (_closed || cancelToken?.isCancelled == true) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    final operation = cancelToken ?? CancelToken();
    _requests.add(operation);
    try {
      final snapshot = _snapshot;
      if (snapshot != null) {
        if (!image || sink != null || source.kind != MarkdownMediaSourceKind.repository) {
          throw const ApiFailure(FailureKind.unsupported);
        }
        final bytes = await snapshot.load(source, maxBytes: _repositoryImageBytes);
        snapshot.checkCurrent();
        if (_closed || operation.isCancelled) throw const ApiFailure(FailureKind.cancelled);
        onProgress?.call(bytes.length, bytes.length);
        snapshot.checkCurrent();
        return bytes;
      }
      switch (source.kind) {
        case MarkdownMediaSourceKind.data:
          final bytes = source.bytes;
          if (bytes == null) {
            throw const ApiFailure(FailureKind.invalidResponse);
          }
          sink?.add(bytes);
          await sink?.flush();
          onContentType?.call(
            _normaliseContentType(source.uri?.data?.mimeType),
          );
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
            onContentType: onContentType,
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
          final request = _loadExternal(
            uri,
            image: image,
            cancelToken: operation,
            onProgress: onProgress,
            onContentType: onContentType,
            sink: sink,
          );
          if (!image) return await request;
          return await request.timeout(
            _externalImageTimeout,
            onTimeout: () {
              if (!operation.isCancelled) {
                operation.cancel('external image total timeout');
              }
              throw const ApiFailure(FailureKind.network);
            },
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
    required void Function(String)? onContentType,
    required IOSink? sink,
  }) async {
    var uri = initial;
    final token = cancelToken ?? CancelToken();
    _requests.add(token);
    final maxBytes = image ? _externalImageBytes : _mediaBytes;
    var redirectHop = false;
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
            persistentConnection: false,
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
          final parsed = location == null ? null : Uri.tryParse(location);
          final next = parsed == null ? null : uri.resolveUri(parsed);
          if (next == null || !_safeExternal(next)) {
            throw ApiFailure(FailureKind.redirectBlocked, status: status);
          }
          uri = next;
          redirectHop = true;
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
        onContentType?.call(type);
        return await _readBody(
          response,
          token: token,
          maxBytes: maxBytes,
          onProgress: onProgress,
          sink: sink,
        );
      }
      throw const ApiFailure(FailureKind.redirectBlocked);
    } on ApiFailure {
      rethrow;
    } on MarkdownMediaNotImage {
      rethrow;
    } on FileSystemException {
      throw ApiFailure.artifactStorage;
    } on DioException catch (error) {
      if (_addressBlocked(error)) {
        throw ApiFailure(
          redirectHop ? FailureKind.redirectBlocked : FailureKind.unsupported,
        );
      }
      if (error.type == DioExceptionType.cancel ||
          token.isCancelled ||
          _closed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    } on Object {
      if (token.isCancelled || _closed) {
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
    Stream<Uint8List> checkedBody() async* {
      final iterator = StreamIterator<Uint8List>(body.stream);
      try {
        while (true) {
          final moved = await Future.any<Object>([
            iterator.moveNext(),
            token.whenCancel.then<Object>((_) => _mediaStreamCancelled),
          ]);
          if (identical(moved, _mediaStreamCancelled)) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          if (moved != true) break;
          final chunk = iterator.current;
          if (received + chunk.length > maxBytes) {
            token.cancel('markdown media exceeds byte budget');
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

    if (sink == null) {
      await for (final chunk in checkedBody()) {
        bytes!.add(chunk);
      }
    } else {
      await sink.addStream(checkedBody());
      await sink.flush();
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

final _mediaStreamCancelled = Object();

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

Dio _bareExternal(
  Dio? supplied, {
  required Future<List<InternetAddress>> Function(String host) resolver,
  required bool allowLoopback,
  required SecurityContext? securityContext,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
    ),
  );
  if (supplied != null) {
    dio.httpClientAdapter = supplied.httpClientAdapter;
  } else {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient(context: securityContext)
          ..findProxy = (_) => 'DIRECT';
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          if (proxyHost != null || proxyPort != null || uri.scheme != 'https') {
            throw const _ExternalAddressBlocked();
          }
          final addresses = await resolver(uri.host);
          if (addresses.isEmpty ||
              addresses.any(
                (address) =>
                    !_safeAddress(address, allowLoopback: allowLoopback),
              )) {
            throw const _ExternalAddressBlocked();
          }
          final connection = await Socket.startConnect(
            addresses.first,
            uri.port,
          );
          return ConnectionTask.fromSocket<Socket>(
            connection.socket.then(
              (socket) => SecureSocket.secure(
                socket,
                host: uri.host,
                context: securityContext,
              ),
            ),
            connection.cancel,
          );
        };
        return client;
      },
    );
  }
  return dio;
}

bool _addressBlocked(Object error) {
  Object? current = error;
  while (current is DioException) {
    current = current.error;
  }
  return current is _ExternalAddressBlocked;
}

final class _ExternalAddressBlocked implements Exception {
  const _ExternalAddressBlocked();
}
