import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/unified_diff.dart';
import '../../shared/external_link.dart';
import '../../shared/resource_share.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';

/// Displays the details and unified diff of a specific Git commit.
class CommitDetailPage extends StatefulWidget {
  const CommitDetailPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.sha,
    this.initialCommit,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final String sha;
  final Json? initialCommit;

  @override
  State<CommitDetailPage> createState() => _CommitDetailPageState();
}

class _CommitDetailPageState extends State<CommitDetailPage> {
  Json? _commit;
  List<Json> _diffs = const [];
  Uri? _diffNext;
  bool _loading = true;
  bool _diffsLoading = false;
  ApiFailure? _error;
  int _epoch = 0;
  final Set<String> _expandedFiles = <String>{};

  @override
  void initState() {
    super.initState();
    _commit = widget.initialCommit;
    unawaited(_load());
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        widget.api.commit(widget.project.id, widget.sha),
        widget.api.commitDiff(widget.project.id, widget.sha),
      ]);

      if (!mounted || epoch != _epoch) return;

      final commitData = results[0] as Json;
      final diffPage = results[1] as ApiPage<Json>;

      if (!mounted || epoch != _epoch) return;

      final diffsList = List<Json>.from(diffPage.items);
      // Auto-expand all files if count <= 10, otherwise collapse
      final initialExpanded = <String>{};
      if (diffsList.length <= 10) {
        for (var i = 0; i < diffsList.length; i++) {
          initialExpanded.add(_fileKey(diffsList[i], i));
        }
      }

      setState(() {
        _commit = commitData;
        _diffs = diffsList;
        _diffNext = diffPage.next;
        _expandedFiles
          ..clear()
          ..addAll(initialExpanded);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = safeFailure(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadMoreDiffs() async {
    final next = _diffNext;
    if (next == null || _diffsLoading) return;
    final epoch = _epoch;
    setState(() => _diffsLoading = true);

    try {
      final page = await widget.api.commitDiff(
        widget.project.id,
        widget.sha,
        next: next,
      );
      if (!mounted || epoch != _epoch) return;

      setState(() {
        final startIndex = _diffs.length;
        _diffs = [..._diffs, ...page.items];
        _diffNext = page.next;
        _diffsLoading = false;
        // Also expand new files if total count remains modest
        if (_diffs.length <= 10) {
          for (var i = startIndex; i < _diffs.length; i++) {
            _expandedFiles.add(_fileKey(_diffs[i], i));
          }
        }
      });
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
      setState(() => _diffsLoading = false);
      if (mounted) showFailure(context, e);
    }
  }

  String _fileKey(Json file, int index) {
    final path = valueText(file, 'new_path', valueText(file, 'old_path'));
    return path.isNotEmpty ? path : 'file-$index';
  }

  void _toggleFile(String key) {
    setState(() {
      if (_expandedFiles.contains(key)) {
        _expandedFiles.remove(key);
      } else {
        _expandedFiles.add(key);
      }
    });
  }

  void _expandAll() {
    setState(() {
      for (var i = 0; i < _diffs.length; i++) {
        _expandedFiles.add(_fileKey(_diffs[i], i));
      }
    });
  }

  void _collapseAll() {
    setState(() {
      _expandedFiles.clear();
    });
  }

  Future<void> _copySha(String sha) async {
    await Clipboard.setData(ClipboardData(text: sha));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已複製 Commit SHA')),
      );
    }
  }

  void _openParentCommit(String parentSha) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CommitDetailPage(
          account: widget.account,
          api: widget.api,
          project: widget.project,
          sha: parentSha,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget;
    final scheme = Theme.of(context).colorScheme;
    final webUri = widget.account.instance.projectWeb(
      '${widget.project.path}/-/commit/${widget.sha}',
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '提交 ${shortSha(widget.sha)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: codeFontFamily,
            fontFamilyFallback: ['Menlo', 'monospace'],
          ),
        ),
        actions: [
          ResourceShareButton(
            uri: webUri,
            ownerKey: (
              widget.account.key,
              widget.api,
              widget.project.id,
              widget.project.path,
              widget.sha,
            ),
            isCurrent: () =>
                mounted &&
                !owner.api.isClosed &&
                widget.account.key == owner.account.key &&
                identical(widget.api, owner.api) &&
                widget.project.id == owner.project.id &&
                widget.project.path == owner.project.path &&
                widget.sha == owner.sha,
          ),
          IconButton(
            tooltip: '在瀏覽器開啟',
            icon: const Icon(Icons.open_in_browser),
            onPressed: () => openExternal(context, webUri),
          ),
        ],
      ),
      body: gestureSafe(_buildBody(context, scheme)),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme scheme) {
    if (_loading && _commit == null) {
      return const ListSkeleton();
    }

    if (_error != null && _commit == null) {
      return ListView(
        children: [
          FailureNotice(
            _error!,
            onRetry: _load,
            account: widget.account,
            resourceLabel: '${widget.project.path} · 提交 ${shortSha(widget.sha)}',
            onSwitchAccount: endSessionFrom(context),
          ),
        ],
      );
    }

    final commit = _commit ?? widget.initialCommit ?? <String, dynamic>{};
    final stats = valueObject(commit, 'stats');
    final additions = stats['additions'] is int ? stats['additions'] as int : null;
    final deletions = stats['deletions'] is int ? stats['deletions'] as int : null;
    final totalChanges = stats['total'] is int ? stats['total'] as int : null;

    final title = valueText(commit, 'title', valueText(commit, 'message', '無提交標題'));
    final fullMessage = valueText(commit, 'message');
    final authorName = valueText(commit, 'author_name');
    final authorEmail = valueText(commit, 'author_email');
    final authoredDate = valueText(commit, 'authored_date', valueText(commit, 'created_at'));
    final parentIds = (commit['parent_ids'] is List)
        ? (commit['parent_ids'] as List).cast<String>()
        : const <String>[];

    final hasAdditionalMessage = fullMessage.isNotEmpty &&
        fullMessage.trim() != title.trim() &&
        fullMessage.trim().startsWith(title.trim());
    final messageBody = hasAdditionalMessage
        ? fullMessage.trim().substring(title.trim().length).trim()
        : '';

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // Commit metadata card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  if (messageBody.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      messageBody,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  // SHA row with copy button
                  Row(
                    children: [
                      const Text(
                        'SHA: ',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      Expanded(
                        child: SelectableText(
                          widget.sha,
                          style: const TextStyle(
                            fontFamily: codeFontFamily,
                            fontFamilyFallback: ['Menlo', 'monospace'],
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '複製 Commit SHA',
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => _copySha(widget.sha),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Author & Date
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.person_outline, size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          authorEmail.isNotEmpty
                              ? '$authorName <$authorEmail>'
                              : authorName.isNotEmpty
                                  ? authorName
                                  : '未知作者',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (authoredDate.isNotEmpty)
                        Text(
                          relativeDate(authoredDate),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                  // Parent Commits
                  if (parentIds.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '父提交：',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        for (final pSha in parentIds)
                          ActionChip(
                            avatar: const Icon(Icons.commit, size: 14),
                            label: Text(
                              shortSha(pSha),
                              style: const TextStyle(
                                fontFamily: codeFontFamily,
                                fontFamilyFallback: ['Menlo', 'monospace'],
                                fontSize: 11,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _openParentCommit(pSha),
                          ),
                      ],
                    ),
                  ],
                  // Stats chips
                  if (additions != null || deletions != null || totalChanges != null) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (additions != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: WorkshopColors.of(context).diffAdded.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '+$additions',
                              style: TextStyle(
                                color: WorkshopColors.of(context).diffAdded,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                fontFamily: codeFontFamily,
                                fontFamilyFallback: const ['Menlo', 'monospace'],
                              ),
                            ),
                          ),
                        if (deletions != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: WorkshopColors.of(context).diffRemoved.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '-$deletions',
                              style: TextStyle(
                                color: WorkshopColors.of(context).diffRemoved,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                fontFamily: codeFontFamily,
                                fontFamilyFallback: const ['Menlo', 'monospace'],
                              ),
                            ),
                          ),
                        if (totalChanges != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '共 $totalChanges 行變更',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // File diffs section toolbar
          Row(
            children: [
              Text(
                '變更檔案 (${_diffs.length})',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const Spacer(),
              if (_diffs.isNotEmpty) ...[
                TextButton.icon(
                  onPressed: _expandAll,
                  icon: const Icon(Icons.unfold_more, size: 16),
                  label: const Text('全部展開'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(48, 48),
                  ),
                ),
                TextButton.icon(
                  onPressed: _collapseAll,
                  icon: const Icon(Icons.unfold_less, size: 16),
                  label: const Text('全部折疊'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),

          if (_diffs.isEmpty && !_loading)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text('此提交無檔案變更或無文字差異。'),
                ),
              ),
            ),

          // File list & diff cards
          for (var i = 0; i < _diffs.length; i++)
            _buildFileDiffCard(context, _diffs[i], i, scheme),

          // Next page button
          if (_diffNext != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: _diffsLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : OutlinedButton.icon(
                        onPressed: _loadMoreDiffs,
                        icon: const Icon(Icons.arrow_downward, size: 18),
                        label: const Text('載入更多檔案變更'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(200, 48),
                        ),
                      ),
              ),
            ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildFileDiffCard(
    BuildContext context,
    Json file,
    int index,
    ColorScheme scheme,
  ) {
    final key = _fileKey(file, index);
    final isExpanded = _expandedFiles.contains(key);

    final newPath = valueText(file, 'new_path');
    final oldPath = valueText(file, 'old_path');
    final isNew = file['new_file'] == true;
    final isDeleted = file['deleted_file'] == true;
    final isRenamed = file['renamed_file'] == true;
    final aMode = valueText(file, 'a_mode');
    final bMode = valueText(file, 'b_mode');
    final modeChanged = aMode.isNotEmpty && bMode.isNotEmpty && aMode != bMode;

    final IconData statusIcon;
    final Color statusColor;
    if (isNew) {
      statusIcon = Icons.add_box_outlined;
      statusColor = WorkshopColors.of(context).diffAdded;
    } else if (isDeleted) {
      statusIcon = Icons.indeterminate_check_box_outlined;
      statusColor = WorkshopColors.of(context).diffRemoved;
    } else if (isRenamed) {
      statusIcon = Icons.drive_file_rename_outline;
      statusColor = Colors.orange;
    } else {
      statusIcon = Icons.code;
      statusColor = scheme.primary;
    }

    final displayPath = isRenamed ? '$oldPath → $newPath' : (newPath.isNotEmpty ? newPath : oldPath);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with expand toggle
          InkWell(
            onTap: () => _toggleFile(key),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(statusIcon, color: statusColor, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayPath,
                            style: const TextStyle(
                              fontFamily: codeFontFamily,
                              fontFamilyFallback: ['Menlo', 'monospace'],
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (modeChanged)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '模式變更：$aMode → $bMode',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Diff content when expanded
          if (isExpanded) ...[
            const Divider(height: 1),
            _buildDiffViewer(context, file, scheme),
          ],
        ],
      ),
    );
  }

  Widget _buildDiffViewer(BuildContext context, Json file, ColorScheme scheme) {
    if (file['too_large'] == true || file['collapsed'] == true) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'GitLab 限制了此差異（檔案過大或已折疊）。',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    }

    final diff = valueText(file, 'diff');
    if (diff.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '二進位檔案或無文字差異。',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    }

    List<DiffLine> lines;
    try {
      lines = parseUnifiedDiff(diff);
    } on FormatException {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '此差異不完整或超過排版上限。',
          style: TextStyle(color: Colors.red),
        ),
      );
    }

    final diffAdded = WorkshopColors.of(context).diffAdded;
    final diffRemoved = WorkshopColors.of(context).diffRemoved;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: MediaQuery.widthOf(context) - 32,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++)
              _buildDiffLineRow(lines[i], i, scheme, diffAdded, diffRemoved),
          ],
        ),
      ),
    );
  }

  Widget _buildDiffLineRow(
    DiffLine line,
    int index,
    ColorScheme scheme,
    Color diffAdded,
    Color diffRemoved,
  ) {
    final marker = line.kind == 'add'
        ? '+'
        : line.kind == 'remove'
            ? '−'
            : ' ';

    final Color? background;
    if (line.kind == 'add') {
      background = diffAdded.withValues(alpha: 0.16);
    } else if (line.kind == 'remove') {
      background = diffRemoved.withValues(alpha: 0.16);
    } else if (line.kind == 'hunk') {
      background = scheme.surfaceContainerHighest;
    } else {
      background = null;
    }

    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Old line number
          SizedBox(
            width: 32,
            child: Text(
              '${line.oldLine ?? ''}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant,
                fontFamily: codeFontFamily,
                fontFamilyFallback: const ['Menlo', 'monospace'],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // New line number
          SizedBox(
            width: 32,
            child: Text(
              '${line.newLine ?? ''}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant,
                fontFamily: codeFontFamily,
                fontFamilyFallback: const ['Menlo', 'monospace'],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Marker (+ / -)
          SizedBox(
            width: 16,
            child: Text(
              marker,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: line.kind == 'add'
                    ? diffAdded
                    : line.kind == 'remove'
                        ? diffRemoved
                        : scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Code line text
          Text(
            line.text,
            style: const TextStyle(
              fontFamily: codeFontFamily,
              fontFamilyFallback: ['Menlo', 'monospace'],
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
