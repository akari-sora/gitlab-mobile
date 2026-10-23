import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/attachment_budget.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'diff_page.dart';
import 'editor.dart';
import 'comment_editor.dart';
import 'records_feed.dart';
import '../../core/suggestion.dart';
import 'suggestion_card.dart';

import '../../l10n/l10n.dart';
bool _discussionResolved(Json discussion) {
  final resolvable = valueObjects(discussion, 'notes').where((note) => note['resolvable'] == true);
  return resolvable.isNotEmpty && resolvable.every((note) => note['resolved'] == true);
}

String _discussionSummary(List<Json> items, {required bool partial}) {
  final line = l10n.threadCountLabel(partial ? l10n.loadedPrefix : '', items.length);
  final resolvable = items.any((item) => valueObjects(item, 'notes').any((note) => note['resolvable'] == true));
  if (!partial && !resolvable) { return line; }
  return l10n.resolvedOnLine(line, items.where(_discussionResolved).length);
}

enum DiscussionFilterMode {
  all,
  comments,
  system;

  String get label => switch (this) {
    DiscussionFilterMode.all => l10n.allActivity,
    DiscussionFilterMode.comments => l10n.commentsOnly,
    DiscussionFilterMode.system => l10n.activityOnly,
  };
}

bool _isSystemDiscussion(Json discussion) {
  final notes = valueObjects(discussion, 'notes');
  return notes.isNotEmpty && notes.every((note) => note['system'] == true);
}

/// First paragraph of a system note as plain text. Notes such as "added 2
/// commits" continue with an HTML commit list and a Markdown compare link.
String systemNoteSummary(String body) {
  final first = body.trim().split(RegExp(r'\n\s*\n')).first;
  return first
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (match) => match.group(1)!)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

bool _isCommentDiscussion(Json discussion) {
  final notes = valueObjects(discussion, 'notes');
  return notes.any((note) => note['system'] != true);
}

class DiscussionsTab extends StatefulWidget {
  const DiscussionsTab({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.resource,
    required this.iid,
    this.headSha,
    this.onChanged,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  final int iid;
  final String? headSha;
  final VoidCallback? onChanged;
  @override
  State<DiscussionsTab> createState() => _DiscussionsTabState();
}
class _DiscussionsTabState extends State<DiscussionsTab> {
  final _feed = GlobalKey<RecordsFeedState>();
  final _attachments = AttachmentBudget();
  final _open = <String>{};
  bool _busy = false, _unresolvedOnly = false;
  DiscussionFilterMode _filterMode = DiscussionFilterMode.all;

  String get _filteredEmptyText {
    if (_unresolvedOnly) {
      switch (_filterMode) {
        case DiscussionFilterMode.all:
          return l10n.noUnresolvedThreads;
        case DiscussionFilterMode.comments:
          return l10n.noUnresolvedUserComments;
        case DiscussionFilterMode.system:
          return l10n.noUnresolvedSystemNotes;
      }
    }
    switch (_filterMode) {
      case DiscussionFilterMode.all:
        return l10n.noThreadsYet;
      case DiscussionFilterMode.comments:
        return l10n.noMatchingUserComments;
      case DiscussionFilterMode.system:
        return l10n.noMatchingSystemNotes;
    }
  }

  bool _isItemVisible(Json item) {
    if (_unresolvedOnly && _discussionResolved(item)) {
      return false;
    }
    switch (_filterMode) {
      case DiscussionFilterMode.all:
        return true;
      case DiscussionFilterMode.comments:
        return _isCommentDiscussion(item);
      case DiscussionFilterMode.system:
        return _isSystemDiscussion(item);
    }
  }
  List<String> get path => ['projects', '${widget.project.id}', widget.resource, '${widget.iid}'];
  void _toggle(String id) => setState(() { if (!_open.remove(id)) { _open.add(id); } });
  Future<void> _compose({Json? note, String? discussion, bool thread = false}) async {
    if (_busy) { return; }
    if (note == null && discussion == null && !thread) {
      final account = widget.account;
      final api = widget.api;
      final project = widget.project;
      final resource = widget.resource;
      final iid = widget.iid;
      bool current() => mounted && widget.account.key == account.key &&
          identical(widget.api, api) && widget.project.id == project.id &&
          widget.resource == resource && widget.iid == iid;
      final saved = await openCommentEditor(context, account: account, api: api,
        project: project, resource: resource, iid: iid, isCurrent: current);
      if (saved && current()) {
        await _feed.currentState?.refresh();
        widget.onChanged?.call();
      }
      return;
    }
    final saved = await openEditor(context, account: widget.account,
      title: note != null ? l10n.editComment : discussion != null ? l10n.replyToThread : thread ? l10n.newThread : l10n.newComment,
      resource: '${path.join('/')}/${discussion ?? 'root'}/${note?['id'] ?? (thread ? 'thread-new' : 'new')}',
      subtitle: '${widget.project.path} · ${widget.resource == 'issues' ? '#' : '!'}${widget.iid}', fields: [
        EditField('body', l10n.commentBody, required: true, lines: 9, markdown: true, quickActions: true,
          value: note == null ? '' : valueText(note, 'body'),
          hint: l10n.markdownQuickActionsHint),
      ], api: widget.api, projectId: widget.project.id, projectPath: widget.project.path, save: (values) async {
        final body = values['body']!;
        final projectId = widget.project.id;
        final resource = widget.resource;
        final iid = widget.iid;
        if (note != null) {
          final noteId = requiredInt(note, 'id');
          if (discussion == null) {
            await widget.api.updateNote(projectId, resource, iid, noteId, body);
          } else {
            await widget.api.updateDiscussionNote(projectId, resource, iid, discussion, noteId, body);
          }
        } else if (discussion != null) {
          await widget.api.createDiscussionNote(projectId, resource, iid, discussion, body);
        } else if (thread) {
          await widget.api.createDiscussion(projectId, resource, iid, body);
        } else {
          await widget.api.createNote(projectId, resource, iid, body);
        }
      });
    if (saved && mounted) {
      await _feed.currentState?.refresh();
      widget.onChanged?.call();
    }
  }
  void _reload() {
    _feed.currentState?.refresh();
    widget.onChanged?.call();
  }
  Future<void> _delete(Json note, String? discussion) async {
    if (_busy || !await confirmAction(context, l10n.deleteCommentConfirm, l10n.actionCannotBeUndone)) { return; }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      final noteId = requiredInt(note, 'id');
      if (discussion == null) {
        await widget.api.deleteNote(widget.project.id, widget.resource, widget.iid, noteId);
      } else {
        await widget.api.deleteDiscussionNote(widget.project.id, widget.resource, widget.iid, discussion, noteId);
      }
      if (mounted) {
        await _feed.currentState?.refresh();
        widget.onChanged?.call();
      }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Future<void> _resolve(Json discussion, bool resolved) async {
    if (_busy) { return; }
    setState(() => _busy = true);
    try {
      await widget.api.setDiscussionResolved(widget.project.id, widget.resource, widget.iid, requiredString(discussion, 'id'), resolved);
      if (mounted) {
        await _feed.currentState?.refresh();
        widget.onChanged?.call();
      }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Widget _header(Json discussion, List<Json> notes) {
    final first = notes.first;
    final id = valueText(discussion, 'id');
    final isOpen = _open.contains(id);
    final author = '@${valueText(valueObject(first, 'author'), 'username')}';
    return Semantics(
      key: ValueKey('discussion-header-$id'),
      button: true, expanded: isOpen, hint: isOpen ? l10n.collapseThread : l10n.expandThread,
      child: InkWell(
        onTap: () => _toggle(id),
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(isolated(author), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall)),
              const SizedBox(width: 8),
              Text(relativeDate(valueText(first, 'created_at')), maxLines: 1,
                style: Theme.of(context).textTheme.bodySmall),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              DecoratedBox(decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8)), child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2), child: Text(l10n.resolvedLabel))),
              Text(l10n.noteCount(notes.length), style: Theme.of(context).textTheme.bodySmall),
            ]),
          ]),
        )),
      ),
    );
  }
  Widget _thread(Json discussion) {
    final notes = valueObjects(discussion, 'notes');
    final rawPosition = notes.isEmpty ? null : notes.first['position'];
    final textPosition = rawPosition is Json && rawPosition['position_type'] == 'text' ? rawPosition : null;
    final isThread = discussion['individual_note'] == false;
    final discussionId = isThread ? requiredString(discussion, 'id') : null;
    final resolvable = widget.resource == 'merge_requests' && notes.any((v) => v['resolvable'] == true);
    final resolved = notes.where((v) => v['resolvable'] == true).every((v) => v['resolved'] == true);
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var index = 0; index < notes.length; index++) ...[
        if (index > 0) const Divider(height: 24),
        Row(children: [
          Monogram(valueText(valueObject(notes[index], 'author'), 'name',
            valueText(valueObject(notes[index], 'author'), 'username')), size: 26),
          const SizedBox(width: 8),
          Flexible(child: Text(isolated('@${valueText(valueObject(notes[index], 'author'), 'username')}'),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall)),
          const SizedBox(width: 6),
          Expanded(child: Text(relativeDate(valueText(notes[index], 'created_at')), maxLines: 1,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          if (notes[index]['system'] != true && valueInt(valueObject(notes[index], 'author'), 'id') == widget.account.user.id)
            PopupMenuButton<String>(tooltip: l10n.commentActions, enabled: !_busy,
              onSelected: (action) => action == 'edit' ? _compose(note: notes[index], discussion: discussionId) : _delete(notes[index], discussionId),
              itemBuilder: (_) => [PopupMenuItem(value: 'edit', child: Text(l10n.editComment)), PopupMenuItem(value: 'delete', child: Text(l10n.deleteComment))]),
        ]),
        if (notes[index]['position'] is Json) Text('${valueText(valueObject(notes[index], 'position'), 'new_path')} · '
          '${valueObject(notes[index], 'position')['new_line'] ?? valueObject(notes[index], 'position')['old_line'] ?? ''}',
          style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8), MarkdownView(valueText(notes[index], 'body'), account: widget.account,
          base: widget.account.instance.projectWeb(widget.project.path), api: widget.api, projectId: widget.project.id,
          projectWeb: widget.account.instance.projectWeb(widget.project.path), projectPath: widget.project.path,
          budget: _attachments),
        for (final suggestion in parseNoteSuggestions(notes[index])) ...[
          const SizedBox(height: 6),
          SuggestedChangeCard(
            suggestion: suggestion,
            api: widget.api,
            onApplied: () {
              _reload();
              widget.onChanged?.call();
            },
          ),
        ],
      ],
      if (isThread) Wrap(spacing: 8, children: [
        if (textPosition != null && widget.resource == 'merge_requests') TextButton.icon(
          onPressed: _busy ? null : () => _openDiff(textPosition),
          icon: const Icon(Icons.code, size: 18), label: Text(l10n.viewCode)),
        TextButton.icon(onPressed: _busy ? null : () => _compose(discussion: discussionId), icon: const Icon(Icons.reply, size: 18), label: Text(l10n.replyAction)),
        if (resolvable) TextButton.icon(onPressed: _busy ? null : () => _resolve(discussion, !resolved),
          icon: Icon(resolved ? Icons.undo : Icons.check, size: 18), label: Text(resolved ? l10n.reopenThread : l10n.resolveThread)),
      ]),
    ]);
  }
  Future<void> _openDiff(Json position) async {
    if (_busy || widget.resource != 'merge_requests') return;
    final newPath = valueText(position, 'new_path');
    final oldPath = valueText(position, 'old_path');
    final filePath = newPath.isNotEmpty ? newPath : oldPath;
    if (filePath.isEmpty) return;
    setState(() => _busy = true);
    try {
      var sha = widget.headSha ?? '';
      if (sha.isEmpty) {
        final detail = await widget.api.cachedRecord(path);
        if (detail.dropped || detail.superseded) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        sha = valueText(detail.value, 'sha');
      }
      if (!mounted || sha.isEmpty) return;
      // Same rule as inline anchoring: a supplied coordinate that is not a
      // positive int drops both lines, so the thread is listed under
      // 其他版本 instead of anchored on the row that matches its valid half.
      final lines = diffPositionLines(position);
      await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => Scaffold(
        appBar: AppBar(title: Text(l10n.changesLink)),
        body: ReviewDiffPage(
          account: widget.account, api: widget.api, project: widget.project, iid: widget.iid, expectedSha: sha,
          initialTarget: DiffTarget(
            path: filePath,
            newPath: newPath,
            oldPath: oldPath,
            newLine: lines?.newLine,
            oldLine: lines?.oldLine,
            baseSha: valueText(position, 'base_sha'),
            startSha: valueText(position, 'start_sha'),
            headSha: valueText(position, 'head_sha'),
          ),
        ),
      )));
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => Column(children: [
    Expanded(child: RecordsFeed(key: _feed, identity: '${path.join('/')}/discussions', empty: l10n.noThreadsYet,
      filteredEmpty: _filteredEmptyText,
      account: widget.account, resourceLabel: l10n.pathThreadTitle(widget.project.path),
      onSwitchAccount: endSessionFrom(context),
      cached: ({required bool fresh, required bool background}) => widget.api.cachedRecords([...path, 'discussions'], fresh: fresh, background: background),
      load: (next) => widget.api.records([...path, 'discussions'], next: next),
      visible: _isItemVisible,
      leading: (_, controller) {
        if (controller.items.isEmpty && (controller.loading || controller.error != null)) { return const SizedBox.shrink(); }
        final resolvedItems = controller.items.where(_discussionResolved).toList();
        final hasResolved = resolvedItems.isNotEmpty;
        final allResolvedOpen = hasResolved && resolvedItems.every((item) => _open.contains(valueText(item, 'id')));

        return Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(_discussionSummary(controller.items, partial: controller.next != null), maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (hasResolved && !_unresolvedOnly)
                TextButton.icon(
                  key: const ValueKey('toggle-all-resolved-btn'),
                  onPressed: () {
                    setState(() {
                      if (allResolvedOpen) {
                        for (final item in resolvedItems) {
                          _open.remove(valueText(item, 'id'));
                        }
                      } else {
                        for (final item in resolvedItems) {
                          _open.add(valueText(item, 'id'));
                        }
                      }
                    });
                  },
                  icon: Icon(allResolvedOpen ? Icons.unfold_less : Icons.unfold_more, size: 18),
                  label: Text(allResolvedOpen ? l10n.collapseResolved : l10n.expandResolved),
                ),
            ]),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final mode in DiscussionFilterMode.values) ...[
                    FilterChip(
                      key: ValueKey('filter-chip-${mode.name}'),
                      label: Text(mode.label),
                      selected: _filterMode == mode,
                      showCheckmark: false,
                      onSelected: (val) {
                        if (val) setState(() => _filterMode = mode);
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilterChip(
                    key: const ValueKey('filter-chip-unresolved'),
                    label: Text(l10n.unresolvedOnly),
                    selected: _unresolvedOnly,
                    showCheckmark: false,
                    onSelected: (value) => setState(() => _unresolvedOnly = value),
                  ),
                ],
              ),
            ),
          ],
        ));
      },
      itemBuilder: (context, discussion) {
        final notes = valueObjects(discussion, 'notes');
        final resolved = _discussionResolved(discussion);
        if (_isSystemDiscussion(discussion)) return _systemNote(context, notes);
        if (!resolved) {
          return Card(child: Padding(padding: const EdgeInsets.fromLTRB(14, 10, 8, 12), child: _thread(discussion)));
        }
        final collapsed = !_open.contains(valueText(discussion, 'id'));
        return Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(discussion, notes),
          if (!collapsed) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: _thread(discussion)),
        ]));
      })),
    Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 8, 8), child: Row(children: [
        Expanded(flex: 3, child: FilledButton.icon(
          style: FilledButton.styleFrom(alignment: Alignment.centerLeft),
          onPressed: _busy ? null : () => _compose(), icon: const Icon(Icons.add_comment_outlined),
          label: Text(l10n.addComment, maxLines: 1, overflow: TextOverflow.ellipsis))),
        const SizedBox(width: 8),
        Flexible(flex: 2, child: OutlinedButton.icon(onPressed: _busy ? null : () => _compose(thread: true),
          icon: const Icon(Icons.forum_outlined, size: 18),
          label: Text(l10n.newThread, maxLines: 1, overflow: TextOverflow.ellipsis))),
      ]))),
    ),
  ]);

  /// GitLab's own activity (mentions, label and assignee changes) as quiet
  /// timeline lines instead of full comment cards.
  Widget _systemNote(BuildContext context, List<Json> notes) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget line(Json note) {
      final body = systemNoteSummary(valueText(note, 'body'));
      return Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: Row(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(_systemIcon(body), size: 16, color: muted)),
          const SizedBox(width: 10),
          Expanded(child: Text.rich(TextSpan(children: [
            TextSpan(text: isolated('@${valueText(valueObject(note, 'author'), 'username')}'),
              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
            TextSpan(text: ' $body · ${relativeDate(valueText(note, 'created_at'))}'),
          ]), style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.4))),
        ],
      ));
    }
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final note in notes) line(note)],
    ));
  }

  static IconData _systemIcon(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('label')) return Icons.label_outline;
    if (lower.contains('assign')) return Icons.person_outline;
    if (lower.contains('mention')) return Icons.alternate_email;
    if (lower.contains('closed')) return Icons.check_circle_outline;
    if (lower.contains('reopen')) return Icons.adjust;
    if (lower.contains('merged')) return Icons.merge;
    if (lower.contains('milestone')) return Icons.flag_outlined;
    if (lower.contains('commit')) return Icons.commit;
    if (lower.contains('title') || lower.contains('description')) return Icons.edit_outlined;
    return Icons.info_outline;
  }
}
