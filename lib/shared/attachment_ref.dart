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

final _uploadSecret = RegExp(r'^[0-9a-f]{32}$');

bool _secretOk(String secret) => _uploadSecret.hasMatch(secret);

bool _filenameOk(String filename) =>
    filename.isNotEmpty &&
    filename != '.' &&
    !filename.contains('/') &&
    !filename.contains('\\') &&
    !filename.contains('..');

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

List<String> _segments(Uri uri) => [
  for (final segment in uri.pathSegments)
    if (segment.isNotEmpty) segment,
];

/// Recognises this page's project uploads. Anything else, including another
/// project's `/-/project/<id>/…` path, is null so the caller does not fetch it.
ProjectUploadRef? parseProjectUpload(Uri uri, {Uri? base, int? projectId, Uri? projectWeb}) {
  if (projectId == null || uri.userInfo.isNotEmpty) return null;
  if (uri.hasScheme && uri.scheme != 'https') return null;
  var target = uri;
  if (!uri.hasScheme && uri.host.isEmpty && !uri.path.startsWith('/') && base != null) {
    target = base.resolveUri(uri);
  }
  if (target.userInfo.isNotEmpty || (target.hasScheme && target.scheme != 'https')) return null;
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
  if (!_secretOk(secret) || !_filenameOk(filename)) return null;
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
Uri projectUploadWeb(Uri projectWeb, ProjectUploadRef ref) => Uri(
  scheme: projectWeb.scheme,
  host: projectWeb.host,
  port: projectWeb.hasPort ? projectWeb.port : null,
  pathSegments: [..._segments(projectWeb), 'uploads', ref.secret, ref.filename],
);
