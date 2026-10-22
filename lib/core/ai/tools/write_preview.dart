import 'target_binding.dart';

/// Structured, process-local card data. Rendering and localization belong to UI.
sealed class AiWritePreview {
  const AiWritePreview();
}

final class AiFieldsPreview extends AiWritePreview {
  AiFieldsPreview(Map<String, Object?> fields)
    : fields = Map.unmodifiable(fields);

  final Map<String, Object?> fields;
}

enum AiDiffLineKind { context, addition, deletion, hunk }

final class AiDiffLine {
  const AiDiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final AiDiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

final class AiDiffPreview extends AiWritePreview {
  AiDiffPreview({
    required this.path,
    required this.ref,
    required List<AiDiffLine> lines,
    this.newFile = false,
    this.preexistingSecretHits = 0,
    this.ciPath = false,
  }) : lines = List.unmodifiable(lines);

  final String path;
  final String ref;
  final List<AiDiffLine> lines;
  final bool newFile;
  final int preexistingSecretHits;
  final bool ciPath;
}

final class AiClosingIssue {
  const AiClosingIssue({
    required this.projectId,
    required this.iid,
    required this.outOfScope,
  });

  final int projectId;
  final int iid;
  final bool outOfScope;
}

final class AiMergePreview extends AiWritePreview {
  AiMergePreview({
    required this.sourceBranch,
    required this.targetBranch,
    required this.shortSha,
    required this.pathCount,
    this.squash = false,
    this.removeSourceBranch = false,
    this.autoMerge = false,
    List<String> ciPaths = const [],
    List<AiClosingIssue> closingIssues = const [],
    List<String> headMovedCommits = const [],
  }) : ciPaths = List.unmodifiable(ciPaths),
       closingIssues = List.unmodifiable(closingIssues),
       headMovedCommits = List.unmodifiable(headMovedCommits);

  final String sourceBranch;
  final String targetBranch;
  final String shortSha;
  final bool squash;
  final bool removeSourceBranch;
  final bool autoMerge;
  final int pathCount;
  final List<String> ciPaths;
  final List<AiClosingIssue> closingIssues;
  final List<String> headMovedCommits;
}

final class AiPipelinePreview extends AiWritePreview {
  AiPipelinePreview({
    required this.ref,
    this.pipelineId,
    this.jobId,
    this.jobName,
    this.stage,
    this.environment,
    List<String> scheduleVariableNames = const [],
    this.scheduleParamsUnreadable = false,
    List<String> newVariableNames = const [],
  }) : scheduleVariableNames = List.unmodifiable(scheduleVariableNames),
       newVariableNames = List.unmodifiable(newVariableNames);

  final String ref;
  final int? pipelineId;
  final int? jobId;
  final String? jobName;
  final String? stage;
  final String? environment;
  final List<String> scheduleVariableNames;
  final bool scheduleParamsUnreadable;
  final List<String> newVariableNames;
}

final class AiDraftPreview {
  const AiDraftPreview({
    required this.id,
    required this.body,
    required this.createdInSegment,
  });

  final int id;
  final String body;
  final bool createdInSegment;
}

final class AiDraftPublishPreview extends AiWritePreview {
  AiDraftPublishPreview({required List<AiDraftPreview> drafts})
    : drafts = List.unmodifiable(drafts);

  final List<AiDraftPreview> drafts;
}

final class AiDeletePreview extends AiWritePreview {
  const AiDeletePreview({
    required this.targetName,
    this.path,
    this.ref,
    this.count,
    this.hasMore = false,
  });

  final String targetName;
  final String? path;
  final String? ref;
  final int? count;
  final bool hasMore;
}

final class AiCancelAutoMergePreview extends AiWritePreview {
  const AiCancelAutoMergePreview({
    required this.iid,
    required this.sourceBranch,
    required this.targetBranch,
    this.mayLackPermission = false,
  });

  final int iid;
  final String sourceBranch;
  final String targetBranch;
  final bool mayLackPermission;
}

/// The same changed block with three lines of context before and after editing.
final class AiTextWindow {
  const AiTextWindow({required this.before, required this.after});

  final String before;
  final String after;
}

/// Full source is kept in memory for fragment validation, never journaled.
final class AiTextScan {
  AiTextScan({
    List<String> newTexts = const [],
    List<AiTextWindow> windows = const [],
    this.original = '',
    this.markdown = false,
    List<String> serverClassA = const [],
  }) : newTexts = List.unmodifiable(newTexts),
       windows = List.unmodifiable(windows),
       serverClassA = List.unmodifiable(serverClassA);

  final List<String> newTexts;
  final List<AiTextWindow> windows;
  final String original;
  final bool markdown;
  final List<String> serverClassA;
}

/// App-owned successful-create identity; it is never decoded from model input.
final class AiCreatedRef {
  const AiCreatedRef({
    required this.accountKey,
    required this.kind,
    this.projectId,
    this.id,
    this.iid,
    this.parentIid,
    this.ref,
    this.path,
  });

  final String accountKey;
  final AiTargetKind kind;
  final int? projectId;
  final int? id;
  final int? iid;
  final int? parentIid;
  final String? ref;
  final String? path;

  @override
  bool operator ==(Object other) =>
      other is AiCreatedRef &&
      accountKey == other.accountKey &&
      kind == other.kind &&
      projectId == other.projectId &&
      id == other.id &&
      iid == other.iid &&
      parentIid == other.parentIid &&
      ref == other.ref &&
      path == other.path;

  @override
  int get hashCode =>
      Object.hash(accountKey, kind, projectId, id, iid, parentIid, ref, path);
}

/// Safe journal metadata only. Schedule parameters and HMACs have no slot here.
final class AiJournalBindings {
  const AiJournalBindings({
    this.headSha,
    this.lastCommitId,
    this.updatedAt,
    this.mergeCheckSummary,
  });

  final String? headSha;
  final String? lastCommitId;
  final String? updatedAt;
  final String? mergeCheckSummary;
}
