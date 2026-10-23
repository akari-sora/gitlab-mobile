import 'package:flutter/material.dart';

import '../../core/ai/tools/write_preview.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/markdown_view.dart' show firstStrongDirection;
import '../../shared/theme.dart';

/// What a write card shows about the change itself (plan v6 §3, §5 item 8,
/// §6, §7.7). Every string here came through the coordinator's display
/// redaction; GitLab names are isolated one piece at a time.
class AiWritePreviewView extends StatelessWidget {
  const AiWritePreviewView({
    super.key,
    required this.preview,
    this.storedVariables = false,
    this.operationId,
  });

  final AiWritePreview preview;

  /// The write the preview belongs to, where one preview type serves writes
  /// that read differently (marking all to-dos done is not a delete).
  final String? operationId;

  /// A rerun, retry or play that may reuse variables GitLab stored (the
  /// tier decides; §0 item 12).
  final bool storedVariables;

  @override
  Widget build(BuildContext context) => switch (preview) {
    final AiDiffPreview diff => _DiffPreview(diff: diff),
    final AiMergePreview merge => _MergePreview(
      merge: merge,
      approve: operationId == 'approveMergeRequest',
    ),
    final AiPipelinePreview pipeline => _PipelinePreview(
      pipeline: pipeline,
      storedVariables: storedVariables,
    ),
    final AiDraftPublishPreview drafts => _DraftsPreview(drafts: drafts),
    final AiDeletePreview delete => _DeletePreview(
      delete: delete,
      todos: operationId == 'markAllTodosDone',
      delayed:
          operationId == 'deleteProject' ||
          operationId == 'deleteContainerRepository',
    ),
    final AiCancelAutoMergePreview cancel => _CancelAutoMergePreview(
      cancel: cancel,
    ),
    // Plain field changes keep the card's own field rows.
    AiFieldsPreview() => const SizedBox.shrink(),
  };
}

/// A line of facts: label, then value, wrapping at large text sizes.
class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value, key: valueKey, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// An orange notice line, the same shape as the card's own warnings.
class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.icon = Icons.info_outline, this.noticeKey});

  final String text;
  final IconData icon;
  final Key? noticeKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: HubColors.orange),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            key: noticeKey,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}

/// A short excerpt of what would be deleted, set apart from the facts.
class _Quote extends StatelessWidget {
  const _Quote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 3,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 8),
          child: Text(
            text,
            key: const ValueKey('ai-preview-excerpt'),
            // A left-to-right comment reads left to right in an Arabic
            // interface, as MarkdownView does.
            textDirection: firstStrongDirection(text),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _DiffPreview extends StatelessWidget {
  const _DiffPreview({required this.diff});

  final AiDiffPreview diff;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final code = codeTextStyle(context, fontSize: 12);
    // Line numbers fit the widest one so the code columns stay aligned.
    final widest = diff.lines.fold<int>(
      1,
      (width, line) => [
        width,
        '${line.oldLine ?? ''}'.length,
        '${line.newLine ?? ''}'.length,
      ].reduce((a, b) => a > b ? a : b),
    );
    String number(int? value) =>
        (value == null ? '' : '$value').padLeft(widest);
    return Column(
      key: const ValueKey('ai-preview-diff'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Fact(
          diff.newFile ? l10n.aiPreviewNewFile : l10n.aiPreviewFile,
          '${isolated(diff.path)} @ ${isolated(diff.ref)}',
        ),
        if (diff.ciPath)
          _Notice(
            l10n.aiPreviewCiFile,
            icon: Icons.warning_amber_rounded,
            noticeKey: const ValueKey('ai-preview-ci-file'),
          ),
        if (diff.moreFiles > 0)
          _Notice(
            l10n.aiPreviewMoreFiles('${diff.moreFiles}'),
            icon: Icons.description_outlined,
            noticeKey: const ValueKey('ai-preview-more-files'),
          ),
        if (diff.preexistingSecretHits > 0)
          _Notice(
            l10n.aiPreviewExistingSecrets('${diff.preexistingSecretHits}'),
            noticeKey: const ValueKey('ai-preview-existing-secrets'),
          ),
        const SizedBox(height: 6),
        // Code reads left to right in every interface language, and long
        // lines scroll sideways instead of wrapping mid-token.
        Directionality(
          textDirection: TextDirection.ltr,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in diff.lines)
                      ColoredBox(
                        color: switch (line.kind) {
                          AiDiffLineKind.addition => HubColors.green.withValues(
                            alpha: 0.14,
                          ),
                          AiDiffLineKind.deletion => HubColors.red.withValues(
                            alpha: 0.14,
                          ),
                          AiDiffLineKind.hunk => scheme.surfaceContainerHigh,
                          AiDiffLineKind.context => Colors.transparent,
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 1,
                          ),
                          child: Text(
                            line.kind == AiDiffLineKind.hunk
                                ? line.text
                                : '${number(line.oldLine)} '
                                      '${number(line.newLine)} '
                                      '${switch (line.kind) {
                                        AiDiffLineKind.addition => '+',
                                        AiDiffLineKind.deletion => '-',
                                        _ => ' ',
                                      }} ${line.text}',
                            softWrap: false,
                            style: code.copyWith(
                              color: line.kind == AiDiffLineKind.hunk
                                  ? scheme.onSurfaceVariant
                                  : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MergePreview extends StatelessWidget {
  const _MergePreview({required this.merge, this.approve = false});

  final AiMergePreview merge;

  /// Approving uses the same snapshot, but nothing is merged: no file count
  /// or merge options.
  final bool approve;

  @override
  Widget build(BuildContext context) {
    final inScope = [
      for (final issue in merge.closingIssues)
        if (!issue.outOfScope) issue,
    ];
    final outOfScope = [
      for (final issue in merge.closingIssues)
        if (issue.outOfScope) issue,
    ];
    // GitLab's full reference names the project, so two `#7` in different
    // projects stay apart.
    String refs(List<AiClosingIssue> issues) => issues
        .map((issue) => isolated(issue.fullReference ?? '#${issue.iid}'))
        .join(', ');
    return Column(
      key: const ValueKey('ai-preview-merge'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Fact(
          l10n.aiPreviewBranches,
          l10n.aiPreviewBranchFlow(
            isolated(merge.sourceBranch),
            isolated(merge.targetBranch),
          ),
        ),
        _Fact(
          l10n.aiPreviewCommit,
          isolated(merge.shortSha),
          valueKey: const ValueKey('ai-preview-merge-sha'),
        ),
        if (!approve) _Fact(l10n.aiPreviewChangedFiles, '${merge.pathCount}'),
        if (!approve)
          _Fact(
            l10n.aiPreviewMergeOptions,
            [
              merge.squash ? l10n.aiPreviewSquashOn : l10n.aiPreviewSquashOff,
              if (merge.removeSourceBranch) l10n.aiPreviewRemoveSource,
              if (merge.autoMerge) l10n.aiPreviewAutoMerge,
            ].join(' · '),
          ),
        if (merge.headMovedCommits.isNotEmpty)
          _Notice(
            l10n.aiPreviewHeadMoved('${merge.headMovedCommits.length}'),
            icon: Icons.warning_amber_rounded,
            noticeKey: const ValueKey('ai-preview-head-moved'),
          ),
        if (merge.ciPaths.isNotEmpty)
          _Notice(
            l10n.aiPreviewMergeCiPaths(merge.ciPaths.map(isolated).join(', ')),
            icon: Icons.warning_amber_rounded,
            noticeKey: const ValueKey('ai-preview-merge-ci'),
          ),
        if (inScope.isNotEmpty)
          _Notice(
            l10n.aiProposalClosesOnMerge(refs(inScope)),
            icon: Icons.task_alt,
          ),
        if (outOfScope.isNotEmpty)
          _Notice(
            l10n.aiPreviewClosesOutOfScope(refs(outOfScope)),
            icon: Icons.warning_amber_rounded,
            noticeKey: const ValueKey('ai-preview-closes-out-of-scope'),
          ),
      ],
    );
  }
}

class _PipelinePreview extends StatelessWidget {
  const _PipelinePreview({
    required this.pipeline,
    required this.storedVariables,
  });

  final AiPipelinePreview pipeline;
  final bool storedVariables;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('ai-preview-pipeline'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Fact(l10n.aiPreviewRef, isolated(pipeline.ref)),
      if (pipeline.pipelineId case final id?)
        _Fact(l10n.aiPreviewPipeline, isolated('#$id')),
      if (pipeline.jobId case final id?)
        _Fact(
          l10n.aiPreviewJob,
          [
            isolated('#$id'),
            if (pipeline.jobName case final name?) isolated(name),
            if (pipeline.stage case final stage?) isolated(stage),
          ].join(' · '),
        ),
      if (pipeline.environment case final environment?)
        _Fact(l10n.aiPreviewEnvironment, isolated(environment)),
      // §0 item 12: a rerun or play may reuse variables GitLab stored and,
      // for a schedule, its current variables; the app cannot check them.
      if (storedVariables)
        _Notice(
          l10n.aiPreviewStoredVariables,
          noticeKey: const ValueKey('ai-preview-stored-variables'),
        ),
      if (pipeline.scheduleVariableNames.isNotEmpty)
        _Notice(
          l10n.aiPreviewScheduleVariables(
            pipeline.scheduleVariableNames.map(isolated).join(', '),
          ),
        ),
      if (pipeline.scheduleParamsUnreadable)
        _Notice(
          l10n.aiPreviewScheduleUnreadable,
          icon: Icons.warning_amber_rounded,
        ),
      if (pipeline.newVariableNames.isNotEmpty)
        _Notice(
          l10n.aiPreviewNewVariables(
            pipeline.newVariableNames.map(isolated).join(', '),
          ),
          icon: Icons.warning_amber_rounded,
          noticeKey: const ValueKey('ai-preview-new-variables'),
        ),
    ],
  );
}

class _DraftsPreview extends StatelessWidget {
  const _DraftsPreview({required this.drafts});

  final AiDraftPublishPreview drafts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ours = drafts.drafts.where((draft) => draft.createdInSegment).length;
    return Column(
      key: const ValueKey('ai-preview-drafts'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Fact(
          l10n.aiPreviewDraftCount,
          l10n.aiPreviewDraftSplit('${drafts.drafts.length}', '$ours'),
        ),
        for (final draft in drafts.drafts)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  draft.createdInSegment
                      ? Icons.auto_awesome_outlined
                      : Icons.person_outline,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                  semanticLabel: draft.createdInSegment
                      ? l10n.aiPreviewDraftByAi
                      : l10n.aiPreviewDraftByYou,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    draft.body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DeletePreview extends StatelessWidget {
  const _DeletePreview({
    required this.delete,
    required this.todos,
    this.delayed = false,
  });

  final AiDeletePreview delete;

  /// Marking every to-do done: the target is the account and the count is
  /// to-dos. GitLab can restore a done to-do, so this is not "can't be undone".
  final bool todos;

  /// A project or container repository delete that GitLab may only schedule.
  final bool delayed;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('ai-preview-delete'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (delete.targetName.isNotEmpty)
        _Fact(
          todos ? l10n.accountLabel : l10n.aiPreviewDeleteTarget,
          isolated(delete.targetName),
        ),
      if (delete.parentName case final parent?)
        _Fact(l10n.aiPreviewParent, isolated(parent)),
      if (delete.author case final author?)
        _Fact(l10n.author, isolated(author)),
      if (delete.excerpt case final excerpt? when excerpt.trim().isNotEmpty)
        _Quote(excerpt),
      // A branch or tag delete names the same thing twice; show it once.
      if (delete.path case final path? when path != delete.targetName)
        _Fact(l10n.aiPreviewPath, isolated(path)),
      if (delete.ref case final ref? when ref != delete.targetName)
        _Fact(l10n.aiPreviewRef, isolated(ref)),
      if (delete.count case final count?)
        _Fact(
          todos ? l10n.todoLabel : l10n.aiPreviewDeleteCount,
          delete.hasMore ? l10n.aiPreviewAtLeast('$count') : '$count',
        ),
      // GitLab may only schedule these; they can be restored for a while.
      if (delayed)
        _Notice(
          l10n.aiPreviewDeletionMayBeDelayed,
          icon: Icons.warning_amber_rounded,
          noticeKey: const ValueKey('ai-preview-deletion-delayed'),
        )
      else if (!todos)
        _Notice(
          l10n.aiPreviewCannotUndo,
          icon: Icons.warning_amber_rounded,
          noticeKey: const ValueKey('ai-preview-cannot-undo'),
        ),
    ],
  );
}

class _CancelAutoMergePreview extends StatelessWidget {
  const _CancelAutoMergePreview({required this.cancel});

  final AiCancelAutoMergePreview cancel;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('ai-preview-cancel-auto-merge'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Fact(l10n.mergeRequestLabel, isolated('!${cancel.iid}')),
      _Fact(
        l10n.aiPreviewBranches,
        l10n.aiPreviewBranchFlow(
          isolated(cancel.sourceBranch),
          isolated(cancel.targetBranch),
        ),
      ),
      if (cancel.mayLackPermission)
        _Notice(l10n.aiPreviewCancelMayLackPermission),
    ],
  );
}
