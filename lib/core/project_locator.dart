import 'instance.dart';

/// Resolves ONLY a project root. Query/fragment/leaf context is deliberately
/// not sent to GitLab's project endpoint; no branch-name guessing is involved.
String projectLocator(GitLabInstance instance, String input) {
  final text = input.trim();
  if (RegExp(r'^[1-9][0-9]*$').hasMatch(text)) return text;
  var path = text;
  if (text.contains('://')) {
    final uri = Uri.tryParse(text);
    if (uri == null || !instance.sameOrigin(uri)) {
      throw const FormatException('請貼上同一實例的 HTTPS 專案連結。');
    }
    if (uri.queryParameters.keys.any((key) => const {
      'access_token', 'private_token', 'token', 'job_token',
    }.contains(key.toLowerCase()))) {
      throw const FormatException('連結含憑證參數；請改用不含 Token 的專案連結。');
    }
    final rawPath = RegExp(r'^https://[^/?#]+([^?#]*)', caseSensitive: false)
        .firstMatch(text)?.group(1) ?? '';
    if (rawPath.contains('\\') || rawPath.split('/').any((part) {
      final decoded = Uri.decodeComponent(part);
      return decoded == '.' || decoded == '..';
    })) {
      throw const FormatException('專案連結不可包含相對路徑。');
    }
    final baseSegments = instance.base.pathSegments.where((part) => part.isNotEmpty).toList();
    final segments = uri.pathSegments.toList();
    if (segments.length <= baseSegments.length) throw const FormatException('連結沒有專案路徑。');
    for (var i = 0; i < baseSegments.length; i++) {
      if (segments[i] != baseSegments[i]) throw const FormatException('連結不屬於目前 GitLab 安裝路徑。');
    }
    final projectParts = segments.skip(baseSegments.length).takeWhile((part) => part != '-').toList();
    while (projectParts.isNotEmpty && projectParts.last.isEmpty) { projectParts.removeLast(); }
    // A percent-encoded slash must not introduce a second namespace hierarchy.
    if (projectParts.any((part) => part.contains('/') || part.contains('%'))) {
      throw const FormatException('專案連結包含不明確的編碼路徑。');
    }
    path = projectParts.join('/');
  }
  while (path.endsWith('/')) { path = path.substring(0, path.length - 1); }
  if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
  final parts = path.split('/');
  if (parts.length < 2 || parts.any((part) => part.isEmpty || part == '.' || part == '..') ||
      RegExp(r'[\\?#%\x00-\x1f\x7f]').hasMatch(path)) {
    throw const FormatException('請輸入完整 namespace/project 路徑或 numeric project ID。');
  }
  return path;
}
