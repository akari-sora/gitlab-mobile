import '../core/upload_names.dart';

export '../core/upload_names.dart';

/// A project upload named by Markdown, not a general image URL.
final class ProjectUploadRef {
  const ProjectUploadRef({required this.secret, required this.filename});
  final String secret;
  final String filename;

  @override
  bool operator ==(Object other) =>
      other is ProjectUploadRef && other.secret == secret && other.filename == filename;
  @override
  int get hashCode => Object.hash(secret, filename);
}

const _maxUploadPathLength = 4096;

bool _sameOrigin(Uri uri, Uri origin) =>
    uri.scheme == 'https' &&
    origin.scheme == 'https' &&
    uri.host.toLowerCase() == origin.host.toLowerCase() &&
    uri.port == origin.port &&
    uri.userInfo.isEmpty;

bool _sameSegments(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

bool _prefixOf(List<String> prefix, List<String> path) {
  if (prefix.length > path.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (prefix[i] != path[i]) return false;
  }
  return true;
}

bool _hex(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x46) ||
    (unit >= 0x61 && unit <= 0x66);

/// A `%` that is not two hex digits. `pathSegments` keeps some of these as
/// literal text and throws on others; both are rejected before a fetch.
bool _brokenPercent(String path) {
  for (var i = 0; i < path.length; i++) {
    if (path.codeUnitAt(i) != 0x25) continue;
    if (i + 2 >= path.length || !_hex(path.codeUnitAt(i + 1)) || !_hex(path.codeUnitAt(i + 2))) {
      return true;
    }
    i += 2;
  }
  return false;
}

List<String> _segments(Uri uri) => [
  for (final segment in uri.pathSegments)
    if (segment.isNotEmpty) segment,
];

/// Recognises this page's project uploads. Anything else, including another
/// project's `/-/project/<id>/…` path, is null so the caller does not fetch it.
/// Malformed escapes and over-long paths are null and never throw.
ProjectUploadRef? parseProjectUpload(Uri uri, {Uri? base, int? projectId, Uri? projectWeb}) {
  try {
    return _parseProjectUpload(uri, base: base, projectId: projectId, projectWeb: projectWeb);
  } catch (_) {
    return null;
  }
}

ProjectUploadRef? _parseProjectUpload(Uri uri, {Uri? base, int? projectId, Uri? projectWeb}) {
  if (projectId == null || uri.userInfo.isNotEmpty) return null;
  if (uri.hasScheme && uri.scheme != 'https') return null;
  if (uri.path.length > _maxUploadPathLength || _brokenPercent(uri.path)) return null;
  var target = uri;
  if (!uri.hasScheme && uri.host.isEmpty && !uri.path.startsWith('/') && base != null) {
    target = base.resolveUri(uri);
  }
  if (target.userInfo.isNotEmpty || (target.hasScheme && target.scheme != 'https')) return null;
  if (target.path.length > _maxUploadPathLength || _brokenPercent(target.path)) return null;
  final origin = projectWeb ?? base;
  if (target.host.isNotEmpty) {
    if (origin == null || !_sameOrigin(target, origin)) return null;
  } else if (target.hasScheme) {
    return null;
  }
  if (!target.path.startsWith('/')) return null;
  final segments = _segments(target);
  if (segments.length < 3 || segments[segments.length - 3] != 'uploads') return null;
  final secret = segments[segments.length - 2];
  final filename = segments[segments.length - 1];
  if (!projectUploadNamesOk(secret, filename)) return null;
  final head = segments.sublist(0, segments.length - 3);
  final webPath = projectWeb == null ? null : _segments(projectWeb);
  if (head.isEmpty) return ProjectUploadRef(secret: secret, filename: filename);
  if (webPath != null && _sameSegments(head, webPath)) {
    return ProjectUploadRef(secret: secret, filename: filename);
  }
  if (head.length >= 3 &&
      head[head.length - 3] == '-' &&
      head[head.length - 2] == 'project' &&
      head.last == '$projectId') {
    final prefix = head.sublist(0, head.length - 3);
    if (prefix.isEmpty || (webPath != null && _prefixOf(prefix, webPath))) {
      return ProjectUploadRef(secret: secret, filename: filename);
    }
  }
  return null;
}

/// Browser URL for 「在 GitLab 開啟」. Credentials are never added.
/// Malformed input is null instead of throwing into the viewer.
Uri? projectUploadWeb(Uri projectWeb, ProjectUploadRef ref) {
  try {
    if (!projectUploadNamesOk(ref.secret, ref.filename)) return null;
    if (projectWeb.path.length > _maxUploadPathLength || _brokenPercent(projectWeb.path)) return null;
    final uri = Uri(
      scheme: projectWeb.scheme,
      host: projectWeb.host,
      port: projectWeb.hasPort ? projectWeb.port : null,
      pathSegments: [..._segments(projectWeb), 'uploads', ref.secret, ref.filename],
    );
    if (uri.path.length > _maxUploadPathLength) return null;
    return uri;
  } catch (_) {
    return null;
  }
}
