import 'instance.dart';

import 'failure.dart';
import '../l10n/l10n.dart';
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
      throw InputFormatException(l10n.pasteSameInstanceProjectLink);
    }
    final Map<String, String> query;
    try {
      query = uri.queryParameters;
    } on FormatException {
      // Percent-encoding that is not UTF-8: the pasted link is malformed.
      throw InputFormatException(l10n.projectLinkAmbiguousPath);
    }
    if (query.keys.any((key) => const {
      'access_token', 'private_token', 'token', 'job_token',
    }.contains(key.toLowerCase()))) {
      throw InputFormatException(l10n.linkContainsTokenParams);
    }
    final rawPath = RegExp(r'^https://[^/?#]+([^?#]*)', caseSensitive: false).firstMatch(text)?.group(1) ?? '';
    if (rawPath.contains('\\') || rawPath.split('/').any((part) {
      final String decoded;
      try {
        decoded = Uri.decodeComponent(part);
      } on ArgumentError {
        throw InputFormatException(l10n.projectLinkAmbiguousPath);
      } on FormatException {
        throw InputFormatException(l10n.projectLinkAmbiguousPath);
      }
      return decoded == '.' || decoded == '..';
    })) { throw InputFormatException(l10n.projectLinkNoRelativePath); }
    final baseSegments = instance.base.pathSegments.where((part) => part.isNotEmpty).toList();
    final segments = uri.pathSegments.toList();
    if (segments.length <= baseSegments.length) { throw InputFormatException(l10n.linkMissingProjectPath); }
    for (var i = 0; i < baseSegments.length; i++) {
      if (segments[i] != baseSegments[i]) { throw InputFormatException(l10n.linkOutsideInstallPath); }
    }
    final projectParts = segments.skip(baseSegments.length).takeWhile((part) => part != '-').toList();
    while (projectParts.isNotEmpty && projectParts.last.isEmpty) { projectParts.removeLast(); }
    if (projectParts.any((part) => part.contains('/') || part.contains('%'))) {
      throw InputFormatException(l10n.projectLinkAmbiguousPath);
    }
    path = projectParts.join('/');
  }
  while (path.endsWith('/')) { path = path.substring(0, path.length - 1); }
  if (path.endsWith('.git')) { path = path.substring(0, path.length - 4); }
  final parts = path.split('/');
  if (parts.length < 2 || parts.any((part) => part.isEmpty || part == '.' || part == '..') ||
      RegExp(r'[\\?#%\x00-\x1f\x7f]').hasMatch(path)) {
    throw InputFormatException(l10n.enterNamespacePathOrId);
  }
  return path;
}

enum LinkTarget { project, group, groupWorkItems, issue, workItem, mergeRequest, pipeline, job, commit, file }

enum WorkItemLinkScope { project, group }

/// A pasted GitLab link resolved to the resource it names. The project part
/// goes through [projectLocator]; the resource part is only recognised when it
/// is unambiguous. File links need a commit SHA ref, because a branch name may
/// itself contain slashes.
final class GitLabLink {
  const GitLabLink._(this.project, this.target, {this.number, this.sha, this.filePath, this.line, this.workItemScope});
  final String project;
  final LinkTarget target;
  final int? number;
  final String? sha;
  final String? filePath;
  final int? line;
  final WorkItemLinkScope? workItemScope;

  factory GitLabLink.parse(String input, GitLabInstance instance) {
    final project = projectLocator(instance, input);
    final text = input.trim();
    if (!text.contains('://')) return GitLabLink._(project, LinkTarget.project);
    final uri = Uri.parse(text);
    final segments = uri.pathSegments.toList();
    final baseLength = instance.base.pathSegments.where((part) => part.isNotEmpty).length;
    final dash = segments.indexOf('-', baseLength);
    final groupLink = segments.length > baseLength && segments[baseLength] == 'groups';
    if (groupLink && dash < 0) {
      return GitLabLink._(_groupPath(segments.skip(baseLength + 1)), LinkTarget.group);
    }
    if (dash < 0 || dash + 2 > segments.length) return GitLabLink._(project, LinkTarget.project);
    final kind = segments[dash + 1];
    final rest = segments.skip(dash + 2).where((part) => part.isNotEmpty).toList();
    final number = rest.isEmpty ? null : int.tryParse(rest.first);
    final positive = number != null && number > 0 ? number : null;
    final beforeDash = segments.sublist(baseLength, dash);
    if (groupLink) {
      final groupPath = _groupPath(beforeDash.skip(1));
      if (kind == 'work_items') {
        if (rest.isEmpty) return GitLabLink._(groupPath, LinkTarget.groupWorkItems);
        if (positive != null && rest.length == 1) {
        return GitLabLink._(groupPath, LinkTarget.workItem, number: positive,
          workItemScope: WorkItemLinkScope.group);
        }
      }
      throw InputFormatException(l10n.groupLinkUnsupported);
    }
    if (kind == 'work_items' && positive != null && rest.length == 1) {
      return GitLabLink._(project, LinkTarget.workItem, number: positive,
        workItemScope: WorkItemLinkScope.project);
    }
    switch (kind) {
      case 'issues' when positive != null:
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

  /// Sub-pages that still show the whole resource, so the resource's own
  /// screen is the right place for them.
  static const _sameResourceTabs = <LinkTarget, Set<String>>{
    LinkTarget.mergeRequest: {'diffs', 'commits', 'pipelines'},
  };

  /// The resource a tapped web link names, when the app has a screen for
  /// exactly that resource: an issue, merge request, work item, pipeline,
  /// job, commit, or a file pinned to a commit SHA, on [instance] over HTTPS.
  /// Everything else returns null and belongs in the browser: another origin,
  /// project, group and user pages, a file on a branch, and sub-pages such as
  /// a job's artifact download or an issue's design, which the parent's
  /// screen would not show.
  static GitLabLink? inApp(Uri uri, GitLabInstance instance) {
    if (!instance.sameOrigin(uri)) return null;
    final GitLabLink link;
    try {
      link = GitLabLink.parse(uri.toString(), instance);
    } catch (_) {
      return null;
    }
    switch (link.target) {
      case LinkTarget.project || LinkTarget.group || LinkTarget.groupWorkItems:
        return null;
      case LinkTarget.file:
        return link;
      case LinkTarget.issue ||
          LinkTarget.mergeRequest ||
          LinkTarget.workItem ||
          LinkTarget.pipeline ||
          LinkTarget.job ||
          LinkTarget.commit:
        final segments = uri.pathSegments;
        final baseLength = instance.base.pathSegments
            .where((part) => part.isNotEmpty)
            .length;
        final dash = segments.indexOf('-', baseLength);
        final tail = segments
            .skip(dash + 2)
            .where((part) => part.isNotEmpty)
            .skip(1)
            .toList();
        if (tail.isEmpty ||
            tail.length == 1 &&
                (_sameResourceTabs[link.target]?.contains(tail.single) ??
                    false)) {
          return link;
        }
        return null;
    }
  }

  static String _groupPath(Iterable<String> rawParts) {
    final parts = rawParts.toList();
    while (parts.isNotEmpty && parts.last.isEmpty) { parts.removeLast(); }
    if (parts.isEmpty || parts.any((part) => part.isEmpty || part == '.' || part == '..' ||
        part.contains('/') || part.contains('\\') || part.contains('%') ||
        RegExp(r'[?#\x00-\x1f\x7f]').hasMatch(part))) {
      throw InputFormatException(l10n.groupLinkMissingFullPath);
    }
    return parts.join('/');
  }
}
