import 'failure.dart';
import 'instance.dart';
import 'models.dart';

/// [commit] pins a read-only view to one SHA, e.g. a file opened from a
/// permalink or a search hit.
enum RepositoryRefKind { branch, tag, commit }

final class RepositoryRef {
  const RepositoryRef({
    required this.kind,
    required this.name,
    required this.sha,
    required this.protected,
    this.isDefault = false,
  });

  final RepositoryRefKind kind;
  final String name;
  final String sha;
  final bool protected;
  final bool isDefault;

  bool get writable => kind == RepositoryRefKind.branch;
  String get identity => '${kind.name}:$name@$sha';

  static final _shaRegex = RegExp(r'^[0-9a-fA-F]{40,64}$');

  static String shortSha(String sha) =>
      sha.length > 8 ? sha.substring(0, 8) : sha;

  static String validateCommitSha(String raw) {
    final trimmed = raw.trim();
    if (!_shaRegex.hasMatch(trimmed)) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    return trimmed.toLowerCase();
  }

  factory RepositoryRef.fromBranch(Map<String, dynamic> json) {
    final commit = objectJson(json['commit']);
    final sha = validateCommitSha(requiredString(commit, 'id'));
    return RepositoryRef(
      kind: RepositoryRefKind.branch,
      name: requiredString(json, 'name'),
      sha: sha,
      protected: json['protected'] == true,
      isDefault: json['default'] == true,
    );
  }

  factory RepositoryRef.fromTag(Map<String, dynamic> json) {
    final commit = objectJson(json['commit']);
    final sha = validateCommitSha(requiredString(commit, 'id'));
    return RepositoryRef(
      kind: RepositoryRefKind.tag,
      name: requiredString(json, 'name'),
      sha: sha,
      protected: json['protected'] == true,
      isDefault: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RepositoryRef &&
          other.kind == kind &&
          other.name == name &&
          other.sha == sha &&
          other.protected == protected &&
          other.isDefault == isDefault;

  @override
  int get hashCode => Object.hash(kind, name, sha, protected, isDefault);

  @override
  String toString() => '$name (${kind.name}) @ ${shortSha(sha)}';
}

/// Builds an immutable web permalink for a repository blob at a specific commit SHA and optional line.
///
/// Follows GitLab URL conventions: `https://<instance>/<project_path>/-/blob/<sha>/<file_path>#L<line>`.
/// Never appends access tokens, credentials, or user info.
Uri repositoryBlobWebUri({
  required GitLabInstance instance,
  required String projectPath,
  required String sha,
  required String filePath,
  int? line,
}) {
  final cleanProjectPath = projectPath.replaceAll(RegExp(r'^/+|/+$'), '').trim();
  if (cleanProjectPath.isEmpty) {
    throw const FormatException('專案路徑不可為空。');
  }
  final cleanFilePath = filePath.replaceAll(RegExp(r'^/+|/+$'), '').trim();
  if (cleanFilePath.isEmpty) {
    throw const FormatException('檔案路徑不可為空。');
  }

  // Reject path traversal and tampering
  if (cleanProjectPath.contains('\\') ||
      cleanFilePath.contains('\\') ||
      RegExp(r'%(2f|5c|2e)', caseSensitive: false).hasMatch(cleanProjectPath) ||
      RegExp(r'%(2f|5c|2e)', caseSensitive: false).hasMatch(cleanFilePath)) {
    throw const FormatException('路徑不可包含編碼分隔符或反斜線。');
  }

  final projectSegments =
      cleanProjectPath.split('/').where((s) => s.isNotEmpty).toList();
  final fileSegments =
      cleanFilePath.split('/').where((s) => s.isNotEmpty).toList();

  if (projectSegments.isEmpty ||
      projectSegments.any((s) => s == '.' || s == '..')) {
    throw const FormatException('專案路徑不可包含相對路徑或遍歷語法。');
  }
  if (fileSegments.isEmpty || fileSegments.any((s) => s == '.' || s == '..')) {
    throw const FormatException('檔案路徑不可包含相對路徑或遍歷語法。');
  }

  final validSha = RepositoryRef.validateCommitSha(sha);

  final base = instance.projectWeb(
    '${projectSegments.join('/')}/-/blob/$validSha/${fileSegments.join('/')}',
  );
  if (line != null && line > 0) {
    return base.replace(fragment: 'L$line');
  }
  return base;
}

/// Represents the repository root README content pinned to an immutable commit SHA.
final class RepositoryReadme {
  const RepositoryReadme({
    required this.path,
    required this.sha,
    required this.markdown,
  });

  final String path;
  final String sha;
  final String markdown;

  String get identity => '$sha:$path';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RepositoryReadme &&
          other.path == path &&
          other.sha == sha &&
          other.markdown == markdown;

  @override
  int get hashCode => Object.hash(path, sha, markdown);

  @override
  String toString() => 'RepositoryReadme($path @ ${RepositoryRef.shortSha(sha)})';
}
