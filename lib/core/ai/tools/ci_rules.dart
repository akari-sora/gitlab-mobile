import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../instance.dart';
import '../write_text.dart';
import 'sensitive_paths.dart';
import 'write_ledger.dart' show AiWriteScope, AiScopeKind;

sealed class AiCiConfig {
  const AiCiConfig();

  factory AiCiConfig.fromProject(Object? ciConfigPath) {
    if (ciConfigPath is! String) return const AiCiConfigUnreadable();
    if (ciConfigPath.isEmpty) {
      return const AiCiConfigLocal('.gitlab-ci.yml');
    }
    if (ciConfigPath.contains('://') ||
        ciConfigPath.startsWith('//') ||
        RegExp(r'^.+@[^/]+/.+$').hasMatch(ciConfigPath)) {
      return const AiCiConfigExternal();
    }
    final path = _repositoryPath(ciConfigPath);
    return path == null ? const AiCiConfigUnreadable() : AiCiConfigLocal(path);
  }
}

final class AiCiConfigLocal extends AiCiConfig {
  const AiCiConfigLocal(this.path);
  final String path;
}

final class AiCiConfigExternal extends AiCiConfig {
  const AiCiConfigExternal();
}

final class AiCiConfigUnreadable extends AiCiConfig {
  const AiCiConfigUnreadable();
}

bool isCiConfigPath(String path, AiCiConfig config) {
  if (config is AiCiConfigUnreadable) return true;
  final local = _repositoryPath(path);
  if (local == null) return true;
  return local == '.gitlab-ci.yml' ||
      local.startsWith('.gitlab/') ||
      local == 'CODEOWNERS' ||
      local == 'docs/CODEOWNERS' ||
      (config is AiCiConfigLocal && local == config.path);
}

String? _repositoryPath(String path) {
  if (path.isEmpty || !isValidRepositoryPath(path)) return null;
  final parts = path.split('/').where((part) => part != '.').toList();
  if (parts.isEmpty || parts.any((part) => part.isEmpty)) return null;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) return null;
  return parts.join('/');
}

final class AiChangedPath {
  const AiChangedPath({
    required this.oldPath,
    required this.newPath,
    required this.newFile,
    required this.deletedFile,
    required this.renamedFile,
  });

  final String oldPath;
  final String newPath;
  final bool newFile;
  final bool deletedFile;
  final bool renamedFile;

  List<Object> _json() => [oldPath, newPath, newFile, deletedFile, renamedFile];
}

final class AiMergeChanges {
  AiMergeChanges({
    required List<AiChangedPath> paths,
    required this.complete,
    required this.digest,
  }) : paths = List.unmodifiable(paths);

  final List<AiChangedPath> paths;
  final bool complete;
  final String digest;
}

AiMergeChanges collectMergeChanges(
  List<List<Map<String, dynamic>>> diffPages, {
  required Object? changesCount,
  required bool hasMorePages,
}) {
  final paths = <AiChangedPath>[];
  final seen = <String>{};
  var complete = !hasMorePages && diffPages.isNotEmpty;
  for (final page in diffPages) {
    for (final row in page) {
      final oldPath = row['old_path'];
      final newPath = row['new_path'];
      final newFile = row['new_file'];
      final deletedFile = row['deleted_file'];
      final renamedFile = row['renamed_file'];
      if (oldPath is! String ||
          newPath is! String ||
          _repositoryPath(oldPath) == null ||
          _repositoryPath(newPath) == null ||
          newFile is! bool ||
          deletedFile is! bool ||
          renamedFile is! bool) {
        complete = false;
        continue;
      }
      final path = AiChangedPath(
        oldPath: oldPath,
        newPath: newPath,
        newFile: newFile,
        deletedFile: deletedFile,
        renamedFile: renamedFile,
      );
      if (!seen.add(jsonEncode([oldPath, newPath]))) complete = false;
      paths.add(path);
    }
  }
  final count = switch (changesCount) {
    int n when n >= 0 => n,
    String s when RegExp(r'^[0-9]+$').hasMatch(s) => int.tryParse(s),
    _ => null,
  };
  complete = complete && count != null && count == paths.length;
  paths.sort((a, b) => jsonEncode(a._json()).compareTo(jsonEncode(b._json())));
  return AiMergeChanges(
    paths: paths,
    complete: complete,
    digest: _digest([complete, paths.map((path) => path._json()).toList()]),
  );
}

final class AiMergeCheck {
  AiMergeCheck({
    required List<String> ciPaths,
    required this.closesOutOfScope,
    required this.crossProjectReference,
    required this.closingUnknown,
    required this.digest,
    required this.journalSummary,
  }) : ciPaths = List.unmodifiable(ciPaths);

  final List<String> ciPaths;
  final bool closesOutOfScope;
  final bool crossProjectReference;
  final bool closingUnknown;
  final String digest;
  final String journalSummary;
}

AiMergeCheck evaluateMergeCheck({
  required AiMergeChanges changes,
  required AiCiConfig ci,
  required List<Map<String, dynamic>>? closesIssues,
  required String description,
  required List<String> commitMessages,
  required AiWriteScope scope,
  required GitLabInstance instance,
}) {
  final ciPaths = <String>{
    for (final path in changes.paths)
      for (final name in [path.oldPath, path.newPath])
        if (isCiConfigPath(name, ci)) name,
  }.toList()..sort();
  final mrPaths = {
    for (final grant in scope.grants)
      if (grant.kind == AiScopeKind.mergeRequest && grant.projectPath != null)
        grant.projectPath!,
  };
  final projectPaths = {
    for (final grant in scope.grants)
      if (grant.projectPath != null) grant.projectPath!,
  };
  final candidates = mrPaths.isNotEmpty ? mrPaths : projectPaths;
  final target = candidates.length == 1 ? candidates.single : null;
  var unknown = !changes.complete || closesIssues == null;
  var outside = false;
  var crossProject = false;
  final closed = <String>{};
  for (final issue in closesIssues ?? <Map<String, dynamic>>[]) {
    final project = issue['project_id'];
    final iid = issue['iid'];
    if (project is! int || project < 1 || iid is! int || iid < 1) {
      unknown = true;
      continue;
    }
    closed.add('$project#$iid');
    if (!scope.grants.any(
      (grant) =>
          grant.projectId == project &&
          (grant.kind == AiScopeKind.project ||
              (grant.kind == AiScopeKind.workItem && grant.iid == iid)),
    )) {
      outside = true;
    }
  }
  final placeholders = UploadPlaceholderTable(instance: instance);
  for (final text in [description, ...commitMessages]) {
    // These are existing server texts, not a new payload. Only classify the
    // existing effects; never log their bodies or duplicate the text parser.
    AiTextOutcome classify(bool closing) => prepareWriteText(
      textClass: AiTextClass.plainContent,
      modelText: text,
      field: null,
      placeholders: placeholders,
      knownSecrets: const {},
      aiAttribution: false,
      secretFragments: const [],
      visibility: AiVisibilityContext(
        targetProjectPath: target,
        closesIssuesOnMerge: closing,
        scopeGrants: scope.grants,
      ),
    );
    final references = classify(false);
    final closing = classify(true);
    unknown = unknown || references.policyBlocked || closing.policyBlocked;
    outside = outside || closing.foreignClosingRefs.isNotEmpty;
    crossProject =
        crossProject ||
        references.confirmReasons.contains(
          AiFixedConfirmReason.closingOrCrossProject,
        );
  }
  final closedKeys = closed.toList()..sort();
  final digest = _digest([
    changes.digest,
    switch (ci) {
      AiCiConfigLocal(:final path) => ['local', path],
      AiCiConfigExternal() => ['external'],
      AiCiConfigUnreadable() => ['unreadable'],
    },
    ciPaths,
    closedKeys,
    _digest(description),
    commitMessages.map(_digest).toList()..sort(),
    outside,
    crossProject,
    unknown,
  ]);
  return AiMergeCheck(
    ciPaths: ciPaths,
    closesOutOfScope: outside,
    crossProjectReference: crossProject,
    closingUnknown: unknown,
    digest: digest,
    journalSummary: jsonEncode({
      'paths': changes.paths.length,
      'ciPaths': ciPaths.length,
      'closesIssues': closed.length,
      'digest': digest,
    }),
  );
}

String _digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
