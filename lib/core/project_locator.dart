import 'instance.dart';

/// Typed result backed by the same parser used by the original G0 routes.
final class ProjectLocator {
  const ProjectLocator._(this.idOrPath);
  final String idOrPath;
  factory ProjectLocator.parse(String input, GitLabInstance instance) =>
    ProjectLocator._(projectLocator(instance, input));
}

/// Resolve the project root only. Never guess slash-containing branch names.
String projectLocator(GitLabInstance instance, String input) {
  final text = input.trim();
  if (RegExp(r'^[1-9][0-9]*$').hasMatch(text)) { return text; }
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
    final rawPath = RegExp(r'^https://[^/?#]+([^?#]*)', caseSensitive: false).firstMatch(text)?.group(1) ?? '';
    if (rawPath.contains('\\') || rawPath.split('/').any((part) {
      final decoded = Uri.decodeComponent(part);
      return decoded == '.' || decoded == '..';
    })) { throw const FormatException('專案連結不可包含相對路徑。'); }
    final baseSegments = instance.base.pathSegments.where((part) => part.isNotEmpty).toList();
    final segments = uri.pathSegments.toList();
    if (segments.length <= baseSegments.length) { throw const FormatException('連結沒有專案路徑。'); }
    for (var i = 0; i < baseSegments.length; i++) {
      if (segments[i] != baseSegments[i]) { throw const FormatException('連結不屬於目前 GitLab 安裝路徑。'); }
    }
    final projectParts = segments.skip(baseSegments.length).takeWhile((part) => part != '-').toList();
    while (projectParts.isNotEmpty && projectParts.last.isEmpty) { projectParts.removeLast(); }
    if (projectParts.any((part) => part.contains('/') || part.contains('%'))) {
      throw const FormatException('專案連結包含不明確的編碼路徑。');
    }
    path = projectParts.join('/');
  }
  while (path.endsWith('/')) { path = path.substring(0, path.length - 1); }
  if (path.endsWith('.git')) { path = path.substring(0, path.length - 4); }
  final parts = path.split('/');
  if (parts.length < 2 || parts.any((part) => part.isEmpty || part == '.' || part == '..') ||
      RegExp(r'[\\?#%\x00-\x1f\x7f]').hasMatch(path)) {
    throw const FormatException('請輸入完整 namespace/project 路徑或 numeric project ID。');
  }
  return path;
}

enum LinkTarget { project, issue, mergeRequest, pipeline, job, commit, file }

/// A pasted GitLab link resolved to the resource it names. The project part
/// goes through [projectLocator]; the resource part is only recognised when it
/// is unambiguous. File links need a commit SHA ref, because a branch name may
/// itself contain slashes.
final class GitLabLink {
  const GitLabLink._(this.project, this.target, {this.number, this.sha, this.filePath, this.line});
  final String project;
  final LinkTarget target;
  final int? number;
  final String? sha;
  final String? filePath;
  final int? line;

  factory GitLabLink.parse(String input, GitLabInstance instance) {
    final project = projectLocator(instance, input);
    final text = input.trim();
    if (!text.contains('://')) return GitLabLink._(project, LinkTarget.project);
    final uri = Uri.parse(text);
    final segments = uri.pathSegments.toList();
    final dash = segments.indexOf('-', instance.base.pathSegments.where((part) => part.isNotEmpty).length);
    if (dash < 0 || dash + 2 > segments.length) return GitLabLink._(project, LinkTarget.project);
    final kind = segments[dash + 1];
    final rest = segments.skip(dash + 2).where((part) => part.isNotEmpty).toList();
    final number = rest.isEmpty ? null : int.tryParse(rest.first);
    final positive = number != null && number > 0 ? number : null;
    switch (kind) {
      case 'issues' || 'work_items' when positive != null:
        return GitLabLink._(project, LinkTarget.issue, number: positive);
      case 'merge_requests' when positive != null:
        return GitLabLink._(project, LinkTarget.mergeRequest, number: positive);
      case 'pipelines' when positive != null:
        return GitLabLink._(project, LinkTarget.pipeline, number: positive);
      case 'jobs' when positive != null:
        return GitLabLink._(project, LinkTarget.job, number: positive);
      case 'commit' when rest.isNotEmpty && _sha.hasMatch(rest.first):
        return GitLabLink._(project, LinkTarget.commit, sha: rest.first.toLowerCase());
      case 'blob' when rest.length >= 2 && _sha.hasMatch(rest.first) &&
          !rest.skip(1).any((part) => part == '.' || part == '..'):
        final line = RegExp(r'^L(\d+)').firstMatch(uri.fragment)?.group(1);
        return GitLabLink._(project, LinkTarget.file, sha: rest.first.toLowerCase(),
          filePath: rest.skip(1).join('/'), line: line == null ? null : int.tryParse(line));
    }
    return GitLabLink._(project, LinkTarget.project);
  }

  static final _sha = RegExp(r'^[0-9a-fA-F]{7,64}$');
}
