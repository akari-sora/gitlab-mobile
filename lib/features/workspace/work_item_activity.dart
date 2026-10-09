import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_activity_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/attachment_budget.dart';
import '../../shared/markdown_view.dart';
import '../../shared/resource_share.dart';
import '../../shared/workspace_ui.dart' show FailureNotice, endSessionFrom;
import 'editor.dart';
import 'reactions.dart' show reactionChoices, reactionGlyph;

const _maxDiscussionPages = 5;
const _maxNotePages = 5;
const _maxRenderedActivityItems = 100;
const _maxRetainedNotes = 2000;
const _maxRetainedBodyCharacters = 4 * 1024 * 1024;

String _filterLabel(WorkItemActivityFilter filter) => switch (filter) {
  WorkItemActivityFilter.all => '全部活動',
  WorkItemActivityFilter.comments => '只看留言',
  WorkItemActivityFilter.history => '只看歷史',
};

String _orderLabel(WorkItemActivityOrder order) => switch (order) {
  WorkItemActivityOrder.oldestFirst => '最舊優先',
  WorkItemActivityOrder.newestFirst => '最新優先',
};

int? _positiveGraphId(String value, Set<String> types) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'gid' ||
      uri.host != 'gitlab' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.length != 2 ||
      !types.contains(uri.pathSegments.first)) {
    return null;
  }
  final raw = uri.pathSegments.last;
  if (!RegExp(r'^[1-9][0-9]*$').hasMatch(raw)) return null;
  return int.tryParse(raw);
}

bool _safeWorkItemPath(String value) {
  if (value.isEmpty ||
      value.trim() != value ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('//') ||
      value.contains('\\') ||
      value.contains('?') ||
      value.contains('#') ||
      RegExp(r'%(2f|5c|2e)', caseSensitive: false).hasMatch(value)) {
    return false;
  }
  return value
      .split('/')
      .every(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      );
}

/// A bounded activity reader for a work item.
///
/// Nothing is requested until the user expands the section. Each server page
/// stays cached, while only the selected page (at most 20 discussions) is
/// built. This keeps long histories from creating thousands of Markdown trees.
class WorkItemActivityPanel extends StatefulWidget {
  const WorkItemActivityPanel({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    required this.project,
    this.isCurrent,
    this.ownerChanges,
    this.onRoute,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final Project? project;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;

  @override
  State<WorkItemActivityPanel> createState() => _WorkItemActivityPanelState();
}

class _WorkItemActivityPanelState extends State<WorkItemActivityPanel> {
  final List<_DiscussionPage> _pages = [];
  final Set<String> _retainedNoteIds = {};
  final Set<String> _pendingNoteActionIds = {};
  final Set<Route<dynamic>> _noteActionRoutes = {};
  AttachmentBudget _attachmentBudget = AttachmentBudget();
  ApiFailure? _initialError;
  ApiFailure? _nextPageError;
  bool _expanded = false;
  bool _loadingInitial = false;
  bool _loadingNextPage = false;
  bool _retentionLimitReached = false;
  int _activePage = 0;
  int _epoch = 0;
  int _ownerEpoch = 0;
  int _retainedBodyCharacters = 0;
  WorkItemActivityFilter _filter = WorkItemActivityFilter.all;
  WorkItemActivityOrder _order = WorkItemActivityOrder.oldestFirst;
  bool _controlsSupported = true;
  WorkItemActivityWriteAccess? _writeAccess;
  ApiFailure? _writeAccessError;
  bool _loadingWriteAccess = false;

  bool get _hasNotesWidget =>
      widget.detail.widgetTypes.any((type) => type.toUpperCase() == 'NOTES');

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);

  bool _writeCurrent(int ownerEpoch) =>
      mounted &&
      ownerEpoch == _ownerEpoch &&
      (widget.isCurrent?.call() ?? true);

  bool _noteActionCurrent(int ownerEpoch, int feedEpoch) =>
      _writeCurrent(ownerEpoch) && feedEpoch == _epoch;

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemActivityPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    final oldSummary = oldWidget.detail.summary;
    final summary = widget.detail.summary;
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldSummary.id != summary.id ||
        oldSummary.iid != summary.iid ||
        oldSummary.project?.id != summary.project?.id ||
        oldSummary.project?.fullPath != summary.project?.fullPath ||
        oldSummary.namespace?.id != summary.namespace?.id ||
        oldSummary.namespace?.fullPath != summary.namespace?.fullPath ||
        !identical(oldWidget.detail, widget.detail)) {
      _reset(notify: false);
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _epoch++;
    _dismissNoteActionRoutes();
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _reset();
  }

  void _reset({bool notify = true}) {
    _clearFeed();
    _ownerEpoch++;
    _expanded = false;
    _filter = WorkItemActivityFilter.all;
    _order = WorkItemActivityOrder.oldestFirst;
    _controlsSupported = true;
    _clearWriteAccess();
    if (notify && mounted) setState(() {});
  }

  void _dismissNoteActionRoutes() {
    for (final route in _noteActionRoutes.toList()) {
      final navigator = route.navigator;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator?.mounted == true && route.isActive) {
          navigator!.removeRoute(route);
        }
      });
    }
    _noteActionRoutes.clear();
  }

  void _clearWriteAccess() {
    _writeAccess = null;
    _writeAccessError = null;
    _loadingWriteAccess = false;
  }

  void _clearFeed() {
    _dismissNoteActionRoutes();
    _epoch++;
    _pages.clear();
    _retainedNoteIds.clear();
    _attachmentBudget = AttachmentBudget();
    _initialError = null;
    _nextPageError = null;
    _loadingInitial = false;
    _loadingNextPage = false;
    _retentionLimitReached = false;
    _activePage = 0;
    _retainedBodyCharacters = 0;
  }

  void _changeSelection({
    WorkItemActivityFilter? filter,
    WorkItemActivityOrder? order,
  }) {
    if (!_controlsSupported || !_current(_epoch)) return;
    final selectedFilter = filter ?? _filter;
    final selectedOrder = order ?? _order;
    if (selectedFilter == _filter && selectedOrder == _order) return;
    setState(() {
      _clearFeed();
      _filter = selectedFilter;
      _order = selectedOrder;
    });
    if (_expanded) unawaited(_loadInitial());
  }

  void _refresh() {
    if (!_current(_epoch) || _loadingInitial || _loadingNextPage) return;
    setState(_clearFeed);
    if (_expanded) unawaited(_loadInitial());
  }

  Future<void> _loadWriteAccess() async {
    if (_loadingWriteAccess || _writeAccess != null) return;
    final ownerEpoch = _ownerEpoch;
    final expected = widget.detail.summary;
    setState(() {
      _loadingWriteAccess = true;
      _writeAccessError = null;
    });
    try {
      final access = await widget.api.workItemActivityWriteAccess(
        expected,
        isCurrent: () => _writeCurrent(ownerEpoch),
      );
      if (!_writeCurrent(ownerEpoch)) return;
      setState(() => _writeAccess = access);
    } catch (error) {
      if (!_writeCurrent(ownerEpoch)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _writeAccessError = failure);
      }
    } finally {
      if (_writeCurrent(ownerEpoch)) {
        setState(() => _loadingWriteAccess = false);
      }
    }
  }

  void _retryWriteAccess() {
    if (!_writeCurrent(_ownerEpoch) || _loadingWriteAccess) return;
    setState(() => _writeAccessError = null);
    unawaited(_loadWriteAccess());
  }

  Future<void> _openComment(WorkItemActivityCommentTarget target) async {
    final ownerEpoch = _ownerEpoch;
    final summary = widget.detail.summary;
    final saved = await openEditor(
      context,
      account: widget.account,
      title: '新增留言',
      resource: 'work-item-activity:${summary.id}:comment',
      subtitle:
          '${summary.project?.fullPath ?? summary.namespace?.fullPath ?? ''} · #${summary.iid}',
      fields: const [
        EditField(
          'body',
          '留言內容',
          required: true,
          lines: 9,
          markdown: true,
          quickActions: false,
          hint: '支援 Markdown；此編輯器不支援 / 開頭的 GitLab 快捷指令。',
        ),
      ],
      save: (values) async {
        await widget.api.createWorkItemActivityComment(
          target,
          values['body'] ?? '',
          isCurrent: () => _writeCurrent(ownerEpoch),
        );
      },
      blockRetryOnWriteUncertain: true,
      api: widget.project == null ? null : widget.api,
      projectId: widget.project?.id,
      projectPath: widget.project?.path,
      projectToolsEnabled: widget.project != null,
      isCurrent: () => _writeCurrent(ownerEpoch),
      onRoute: widget.onRoute,
    );
    if (saved && _writeCurrent(ownerEpoch)) _refreshAfterWrite();
  }

  Future<void> _openReply(
    String discussionId,
    WorkItemActivityReplyTarget target,
  ) async {
    final ownerEpoch = _ownerEpoch;
    final summary = widget.detail.summary;
    final saved = await openEditor(
      context,
      account: widget.account,
      title: '回覆留言',
      resource:
          'work-item-activity:${summary.id}:discussion:$discussionId:reply',
      subtitle:
          '${summary.project?.fullPath ?? summary.namespace?.fullPath ?? ''} · #${summary.iid}',
      fields: const [
        EditField(
          'body',
          '回覆內容',
          required: true,
          lines: 9,
          markdown: true,
          quickActions: false,
          hint: '支援 Markdown；此編輯器不支援 / 開頭的 GitLab 快捷指令。',
        ),
      ],
      save: (values) async {
        await widget.api.createWorkItemActivityReply(
          target,
          values['body'] ?? '',
          isCurrent: () => _writeCurrent(ownerEpoch),
        );
      },
      blockRetryOnWriteUncertain: true,
      api: widget.project == null ? null : widget.api,
      projectId: widget.project?.id,
      projectPath: widget.project?.path,
      projectToolsEnabled: widget.project != null,
      isCurrent: () => _writeCurrent(ownerEpoch),
      onRoute: widget.onRoute,
    );
    if (saved && _writeCurrent(ownerEpoch)) _refreshAfterWrite();
  }

  Future<void> _openNoteActions(
    WorkItemActivityDiscussion discussion,
    WorkItemActivityNote note,
  ) async {
    if (note.system || !_pendingNoteActionIds.add(note.id)) return;
    if (mounted) setState(() {});
    final ownerEpoch = _ownerEpoch;
    final feedEpoch = _epoch;
    final expected = widget.detail.summary;
    final permalink = _notePermalink(expected, note);
    final scope =
        '${expected.project?.fullPath ?? expected.namespace?.fullPath ?? ''} · #${expected.iid}';
    final route = DialogRoute<_WorkItemNoteActionResult>(
      context: context,
      builder: (_) => _WorkItemNoteActionsDialog(
        loadEdit: () => widget.api.workItemActivityEditAccess(
          expected,
          discussion,
          note,
          isCurrent: () => _noteActionCurrent(ownerEpoch, feedEpoch),
        ),
        loadDelete: () => widget.api.workItemActivityDeleteAccess(
          expected,
          discussion,
          note,
          isCurrent: () => _noteActionCurrent(ownerEpoch, feedEpoch),
        ),
        deleteNote: (target) => widget.api.deleteWorkItemActivityNote(
          target,
          isCurrent: () => _noteActionCurrent(ownerEpoch, feedEpoch),
        ),
        loadReactions: () => widget.api.workItemActivityReactionAccess(
          expected,
          discussion,
          note,
          isCurrent: () => _noteActionCurrent(ownerEpoch, feedEpoch),
        ),
        setReaction: (target, name, {required awarded}) =>
            widget.api.setWorkItemActivityNoteReaction(
              target,
              name,
              awarded: awarded,
              isCurrent: () => _noteActionCurrent(ownerEpoch, feedEpoch),
            ),
        account: widget.account,
        scopeLabel: scope,
        permalink: permalink,
        ownerKey: (
          widget.account.key,
          widget.api,
          expected.id,
          note.id,
          ownerEpoch,
          feedEpoch,
        ),
        isCurrent: () => _noteActionCurrent(ownerEpoch, feedEpoch),
      ),
    );
    _noteActionRoutes.add(route);
    widget.onRoute?.call(route);
    try {
      final result = await Navigator.of(context).push(route);
      if (!_noteActionCurrent(ownerEpoch, feedEpoch)) return;
      switch (result) {
        case _EditWorkItemNoteAction(:final target):
          await _openEditNote(target, ownerEpoch, feedEpoch);
        case _WorkItemNoteChangedAction():
          _refreshAfterWrite();
        case null:
          break;
      }
    } finally {
      _noteActionRoutes.remove(route);
      _pendingNoteActionIds.remove(note.id);
      if (mounted) setState(() {});
    }
  }

  Uri? _notePermalink(WorkItemGraphSummary summary, WorkItemActivityNote note) {
    if (summary.iid <= 0 ||
        _positiveGraphId(summary.id, const {'WorkItem'}) == null) {
      return null;
    }
    final noteId = _positiveGraphId(note.id, const {'Note', 'DiscussionNote'});
    if (noteId == null) return null;

    final project = summary.project;
    final namespace = summary.namespace;
    late final String path;
    if (project != null) {
      if (_positiveGraphId(project.id, const {'Project'}) == null ||
          namespace == null ||
          _positiveGraphId(namespace.id, const {
                'Namespaces::ProjectNamespace',
              }) ==
              null ||
          namespace.fullPath != project.fullPath ||
          !_safeWorkItemPath(project.fullPath)) {
        return null;
      }
      path = '${project.fullPath}/-/work_items/${summary.iid}';
    } else {
      if (namespace == null ||
          _positiveGraphId(namespace.id, const {'Group'}) == null ||
          !_safeWorkItemPath(namespace.fullPath)) {
        return null;
      }
      path = 'groups/${namespace.fullPath}/-/work_items/${summary.iid}';
    }
    return widget.account.instance
        .projectWeb(path)
        .replace(fragment: 'note_$noteId');
  }

  Future<void> _openEditNote(
    WorkItemActivityEditTarget target,
    int ownerEpoch,
    int feedEpoch,
  ) async {
    final summary = widget.detail.summary;
    final note = target.note;
    final saved = await openEditor(
      context,
      account: widget.account,
      title: '編輯留言',
      resource: 'work-item-activity:${summary.id}:note:${note.id}:edit',
      subtitle:
          '${summary.project?.fullPath ?? summary.namespace?.fullPath ?? ''} · #${summary.iid}',
      baseRevision: note.updatedAt.toUtc().toIso8601String(),
      fields: [
        EditField(
          'body',
          '留言內容',
          value: note.body,
          required: true,
          lines: 9,
          markdown: true,
          quickActions: false,
          hint: '支援 Markdown；此編輯器不支援 / 開頭的 GitLab 快捷指令。',
        ),
      ],
      save: (values) async {
        await widget.api.editWorkItemActivityNote(
          target,
          values['body'] ?? '',
          isCurrent: () => _noteActionCurrent(ownerEpoch, feedEpoch),
        );
      },
      blockRetryOnWriteUncertain: true,
      api: widget.project == null ? null : widget.api,
      projectId: widget.project?.id,
      projectPath: widget.project?.path,
      projectToolsEnabled: widget.project != null,
      isCurrent: () => _noteActionCurrent(ownerEpoch, feedEpoch),
      onRoute: widget.onRoute,
    );
    if (saved && _noteActionCurrent(ownerEpoch, feedEpoch)) {
      _refreshAfterWrite();
    }
  }

  void _refreshAfterWrite() {
    setState(() {
      _clearFeed();
      _clearWriteAccess();
    });
    if (_expanded) {
      unawaited(_loadInitial());
      unawaited(_loadWriteAccess());
    }
  }

  Future<void> _loadInitial() async {
    if (_loadingInitial || _pages.isNotEmpty || _retentionLimitReached) return;
    final epoch = _epoch;
    final expected = widget.detail.summary;
    setState(() {
      _loadingInitial = true;
      _initialError = null;
    });
    try {
      final result = await widget.api.workItemActivity(
        expected,
        filter: _filter,
        order: _order,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      _requireSnapshotIdentity(result.snapshot, expected);
      if (!_retainNotes(_pageNotes(result))) {
        setState(() => _retentionLimitReached = true);
        return;
      }
      setState(() {
        _filter = result.filter;
        _order = result.order;
        _controlsSupported = result.controlsSupported;
        _pages.add(_DiscussionPage(result));
      });
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _initialError = failure);
      }
    } finally {
      if (_current(epoch)) setState(() => _loadingInitial = false);
    }
  }

  Future<void> _loadNextPage() async {
    if (_loadingNextPage || _pages.isEmpty || _retentionLimitReached) return;
    final source = _pages.last.result.nextDiscussions;
    if (source == null || _pages.length >= _maxDiscussionPages) return;
    final epoch = _epoch;
    setState(() {
      _loadingNextPage = true;
      _nextPageError = null;
    });
    try {
      final result = await widget.api.workItemActivityNext(
        source,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      _requireSnapshotIdentity(result.snapshot, widget.detail.summary);
      final knownDiscussionIds = {
        for (final page in _pages)
          for (final discussion in page.result.snapshot.discussions.items)
            discussion.id,
      };
      final knownReplyIds = {
        for (final page in _pages)
          for (final discussion in page.result.snapshot.discussions.items)
            discussion.replyId,
      };
      for (final discussion in result.snapshot.discussions.items) {
        if (!knownDiscussionIds.add(discussion.id) ||
            !knownReplyIds.add(discussion.replyId)) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
      }
      if (!_retainNotes(_pageNotes(result))) {
        setState(() => _retentionLimitReached = true);
        return;
      }
      setState(() {
        _pages.add(_DiscussionPage(result));
        _activePage = _pages.length - 1;
      });
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _nextPageError = failure);
      }
    } finally {
      if (_current(epoch)) setState(() => _loadingNextPage = false);
    }
  }

  Future<void> _loadMoreNotes(_DiscussionState discussion) async {
    if (discussion.loading ||
        discussion.next == null ||
        _retentionLimitReached) {
      return;
    }
    if (discussion.pageCount >= _maxNotePages) return;
    final epoch = _epoch;
    final continuation = discussion.next!;
    setState(() {
      discussion.loading = true;
      discussion.error = null;
    });
    try {
      final result = await widget.api.workItemDiscussionNotesNext(
        continuation,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      if (result.workItemId != widget.detail.summary.id ||
          result.discussionId != discussion.value.id) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      final known = discussion.notes.map((note) => note.id).toSet();
      for (final note in result.notes.items) {
        if (!known.add(note.id)) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
      }
      if (!_retainNotes(result.notes.items)) {
        setState(() => _retentionLimitReached = true);
        return;
      }
      setState(() {
        if (result.notes.availability ==
            WorkItemActivityConnectionAvailability.unavailable) {
          discussion.continuationUnavailable = true;
        } else {
          discussion.notes.addAll(result.notes.items);
        }
        discussion.next = result.next;
        discussion.pageCount++;
      });
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => discussion.error = failure);
      }
    } finally {
      if (_current(epoch)) {
        setState(() => discussion.loading = false);
      }
    }
  }

  void _requireSnapshotIdentity(
    WorkItemActivitySnapshot snapshot,
    WorkItemGraphSummary expected,
  ) {
    if (snapshot.workItemId != expected.id ||
        snapshot.iid != expected.iid ||
        snapshot.project?.id != expected.project?.id ||
        snapshot.project?.fullPath != expected.project?.fullPath ||
        snapshot.namespace?.id != expected.namespace?.id ||
        snapshot.namespace?.fullPath != expected.namespace?.fullPath) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  Iterable<WorkItemActivityNote> _pageNotes(WorkItemActivityPage page) sync* {
    for (final discussion in page.snapshot.discussions.items) {
      yield* discussion.notes.items;
    }
  }

  bool _retainNotes(Iterable<WorkItemActivityNote> notes) {
    final candidateIds = <String>{};
    var candidateCharacters = 0;
    for (final note in notes) {
      if (_retainedNoteIds.contains(note.id) || !candidateIds.add(note.id)) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      candidateCharacters += note.body.length;
    }
    if (_retainedNoteIds.length + candidateIds.length > _maxRetainedNotes ||
        _retainedBodyCharacters + candidateCharacters >
            _maxRetainedBodyCharacters) {
      return false;
    }
    _retainedNoteIds.addAll(candidateIds);
    _retainedBodyCharacters += candidateCharacters;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasNotesWidget) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('work-item-activity'),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey('work-item-activity-expansion-$_ownerEpoch'),
        maintainState: false,
        title: Text('活動', style: Theme.of(context).textTheme.titleMedium),
        subtitle: const Text('留言與系統事件'),
        onExpansionChanged: (expanded) {
          _expanded = expanded;
          if (expanded) {
            unawaited(_loadInitial());
            unawaited(_loadWriteAccess());
          }
          setState(() {});
        },
        children: _expanded
            ? [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _content(context),
                ),
              ]
            : const [],
      ),
    );
  }

  Widget _content(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _selectionControls(context),
        const SizedBox(height: 12),
        _writeControls(context),
        const SizedBox(height: 16),
        _feedContent(context),
      ],
    );
  }

  Widget _writeControls(BuildContext context) {
    if (_loadingWriteAccess) {
      return const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Expanded(child: Text('正在確認留言權限…')),
        ],
      );
    }
    if (_writeAccessError case final error?) {
      if (error.kind == FailureKind.unsupported) {
        return const Text('此實例暫不支援新增留言；已載入的活動仍可閱讀。');
      }
      return _InlineActivityFailure(
        error: error,
        onRetry: _retryWriteAccess,
        retryLabel: '重試留言權限',
      );
    }
    final access = _writeAccess;
    if (access == null) return const SizedBox.shrink();
    if (access.discussionLocked) {
      return const Text('這個工作項目的討論已鎖定；已載入的活動仍可閱讀。');
    }
    if (!access.canCreateNote) {
      return const Text('目前帳號可閱讀活動，但沒有新增留言的權限。');
    }
    final target = access.commentTarget;
    if (target == null) {
      return const Text('伺服器未提供安全的留言目標；已載入的活動仍可閱讀。');
    }
    if (_filter == WorkItemActivityFilter.history) {
      return OutlinedButton.icon(
        key: const ValueKey('work-item-activity-switch-to-comments'),
        onPressed: _controlsSupported
            ? () => _changeSelection(filter: WorkItemActivityFilter.comments)
            : null,
        icon: const Icon(Icons.comment_outlined),
        label: const Text('切換至留言後新增'),
      );
    }
    return FilledButton.icon(
      key: const ValueKey('work-item-activity-add-comment'),
      onPressed: () => unawaited(_openComment(target)),
      icon: const Icon(Icons.add_comment_outlined),
      label: const Text('新增留言'),
    );
  }

  Widget _selectionControls(BuildContext context) {
    final enabled = _controlsSupported && _current(_epoch);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final sideBySide =
                constraints.maxWidth >= 300 &&
                MediaQuery.textScalerOf(context).scale(14) <= 18.2;
            final width = sideBySide
                ? (constraints.maxWidth - 12) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: width,
                  child: _labelledControl(
                    context,
                    label: '活動篩選',
                    enabled: enabled,
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<WorkItemActivityFilter>(
                        key: const ValueKey('work-item-activity-filter'),
                        value: _filter,
                        isExpanded: true,
                        itemHeight: null,
                        onChanged: enabled
                            ? (value) {
                                if (value != null) {
                                  _changeSelection(filter: value);
                                }
                              }
                            : null,
                        items: [
                          for (final value in WorkItemActivityFilter.values)
                            DropdownMenuItem(
                              value: value,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(_filterLabel(value)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _labelledControl(
                    context,
                    label: '活動排序',
                    enabled: enabled,
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<WorkItemActivityOrder>(
                        key: const ValueKey('work-item-activity-order'),
                        value: _order,
                        isExpanded: true,
                        itemHeight: null,
                        onChanged: enabled
                            ? (value) {
                                if (value != null) {
                                  _changeSelection(order: value);
                                }
                              }
                            : null,
                        items: [
                          for (final value in WorkItemActivityOrder.values)
                            DropdownMenuItem(
                              value: value,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(_orderLabel(value)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        if (!_controlsSupported)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('此實例未提供活動篩選或排序，顯示全部活動（最舊優先）。'),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('work-item-activity-refresh'),
          onPressed: !_current(_epoch) || _loadingInitial || _loadingNextPage
              ? null
              : _refresh,
          icon: const Icon(Icons.refresh),
          label: const Text('重新載入活動'),
        ),
      ],
    );
  }

  Widget _labelledControl(
    BuildContext context, {
    required String label,
    required bool enabled,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 6),
        InputDecorator(
          decoration: InputDecoration(
            enabled: enabled,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 4,
            ),
            border: const OutlineInputBorder(),
          ),
          child: Semantics(label: label, child: child),
        ),
      ],
    );
  }

  Widget _feedContent(BuildContext context) {
    if (_loadingInitial) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_initialError case final error?) {
      return _InlineActivityFailure(
        error: error,
        onRetry: () => unawaited(_loadInitial()),
      );
    }
    if (_pages.isEmpty) {
      return _retentionLimitReached
          ? const _ActivityRetentionLimitNotice()
          : const Text('尚未載入活動。');
    }
    final page = _pages[_activePage];
    final snapshot = page.result.snapshot;
    if (snapshot.availability == WorkItemActivityAvailability.absent) {
      return const Text('這個工作項目沒有提供活動。');
    }
    if (snapshot.availability ==
        WorkItemActivityAvailability.widgetsUnavailable) {
      return const Text('伺服器未回傳 widgets，無法判定活動內容。');
    }
    if (snapshot.discussions.availability ==
        WorkItemActivityConnectionAvailability.unavailable) {
      return const Text('伺服器未回傳活動清單。');
    }
    if (snapshot.discussions.items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(switch (_filter) {
            WorkItemActivityFilter.all => '尚無活動',
            WorkItemActivityFilter.comments => '尚無留言',
            WorkItemActivityFilter.history => '尚無歷史活動',
          }),
          if (page.result.nextDiscussions != null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('伺服器指出還有下一頁，但目前頁面沒有可顯示的活動。'),
            ),
          if (_retentionLimitReached)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: _ActivityRetentionLimitNotice(),
            )
          else if (_pages.length > 1 ||
              page.result.nextDiscussions != null) ...[
            const SizedBox(height: 8),
            _pageControls(context, showStatus: true),
          ],
          if (_activePage == _pages.length - 1 && _nextPageError != null) ...[
            const SizedBox(height: 8),
            _InlineActivityFailure(
              error: _nextPageError!,
              onRetry: () => unawaited(_loadNextPage()),
            ),
          ],
        ],
      );
    }

    final renderBudget = _ActivityRenderBudget(_maxRenderedActivityItems);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_pages.length > 1 || page.result.nextDiscussions != null)
          _pageControls(context, showStatus: false),
        for (var index = 0; index < page.discussions.length; index++) ...[
          if (index > 0) const Divider(height: 28),
          _discussion(context, page.discussions[index], renderBudget),
        ],
        if (renderBudget.omitted > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '為維持捲動順暢，本頁最多排版 $_maxRenderedActivityItems 則活動內容；'
              '另有 ${renderBudget.omitted} 則已載入內容未在本頁排版。',
            ),
          ),
        if (_retentionLimitReached) ...[
          const SizedBox(height: 12),
          const _ActivityRetentionLimitNotice(),
        ],
        if (_activePage == _pages.length - 1 && _nextPageError != null) ...[
          const SizedBox(height: 12),
          _InlineActivityFailure(
            error: _nextPageError!,
            onRetry: () => unawaited(_loadNextPage()),
          ),
        ],
        const SizedBox(height: 12),
        _pageControls(context, showStatus: true),
      ],
    );
  }

  Widget _pageControls(BuildContext context, {required bool showStatus}) {
    final page = _pages[_activePage];
    final atLastCached = _activePage == _pages.length - 1;
    final hasServerNext = page.result.nextDiscussions != null;
    final reachedCap =
        atLastCached && hasServerNext && _pages.length >= _maxDiscussionPages;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _activePage == 0
                  ? null
                  : () => setState(() => _activePage--),
              icon: const Icon(Icons.chevron_left),
              label: const Text('上一頁'),
            ),
            Text('第 ${_activePage + 1} / ${_pages.length} 頁'),
            if (!atLastCached)
              OutlinedButton.icon(
                onPressed: () => setState(() => _activePage++),
                icon: const Icon(Icons.chevron_right),
                label: const Text('下一頁'),
              )
            else if (hasServerNext && !reachedCap && !_retentionLimitReached)
              OutlinedButton.icon(
                onPressed: _loadingNextPage
                    ? null
                    : () => unawaited(_loadNextPage()),
                icon: _loadingNextPage
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more),
                label: const Text('載入下一頁'),
              ),
          ],
        ),
        if (showStatus &&
            hasServerNext &&
            !reachedCap &&
            !_retentionLimitReached)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('尚有更多活動；每次只載入一頁。'),
          ),
        if (showStatus && reachedCap)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('為限制記憶體用量，這裡最多保留 5 頁活動。'),
          ),
      ],
    );
  }

  Widget _discussion(
    BuildContext context,
    _DiscussionState discussion,
    _ActivityRenderBudget budget,
  ) {
    if (discussion.notesAvailability ==
        WorkItemActivityConnectionAvailability.unavailable) {
      return const Text('伺服器未回傳這串活動的內容。');
    }
    if (discussion.notes.isEmpty) return const Text('這串活動沒有內容。');

    var firstCommentSeen = false;
    var hiddenComments = 0;
    final visible = <WorkItemActivityNote>[];
    for (final note in discussion.notes) {
      if (note.system) {
        visible.add(note);
        continue;
      }
      if (!firstCommentSeen) {
        firstCommentSeen = true;
        visible.add(note);
      } else if (discussion.commentsExpanded) {
        visible.add(note);
      } else {
        hiddenComments++;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < visible.length; index++) ...[
          if (index > 0) const SizedBox(height: 12),
          _note(context, discussion.value, visible[index], budget),
        ],
        if (hiddenComments > 0)
          TextButton.icon(
            onPressed: () => setState(() => discussion.commentsExpanded = true),
            icon: const Icon(Icons.unfold_more),
            label: Text('顯示其餘 $hiddenComments 則留言'),
          )
        else if (discussion.commentsExpanded &&
            discussion.notes.where((note) => !note.system).length > 1)
          TextButton.icon(
            onPressed: () =>
                setState(() => discussion.commentsExpanded = false),
            icon: const Icon(Icons.unfold_less),
            label: const Text('收合回覆'),
          ),
        if (_writeAccess?.canCreateNote == true &&
            _writeAccess?.discussionLocked == false &&
            discussion.replyTarget != null &&
            _filter != WorkItemActivityFilter.history)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: ValueKey('work-item-activity-reply:${discussion.value.id}'),
              onPressed: () => unawaited(
                _openReply(discussion.value.id, discussion.replyTarget!),
              ),
              icon: const Icon(Icons.reply_outlined),
              label: const Text('回覆'),
            ),
          ),
        if (discussion.error case final error?)
          _InlineActivityFailure(
            error: error,
            onRetry: () => unawaited(_loadMoreNotes(discussion)),
          ),
        if (discussion.continuationUnavailable)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('伺服器未回傳更多回覆；已載入的活動仍保留。'),
          ),
        if (discussion.next != null &&
            discussion.pageCount < _maxNotePages &&
            !_retentionLimitReached)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: discussion.loading
                  ? null
                  : () => unawaited(_loadMoreNotes(discussion)),
              icon: discussion.loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more),
              label: const Text('載入更多回覆'),
            ),
          ),
        if (discussion.next != null && discussion.pageCount >= _maxNotePages)
          const Text('為限制記憶體用量，這串活動最多保留 5 頁回覆。'),
      ],
    );
  }

  Widget _note(
    BuildContext context,
    WorkItemActivityDiscussion discussion,
    WorkItemActivityNote note,
    _ActivityRenderBudget budget,
  ) {
    final author = note.author;
    final authorText = author == null
        ? '作者資料不可用'
        : author.name.trim().isEmpty
        ? '@${author.username}'
        : '${author.name} · @${author.username}';
    final local = note.createdAt.toLocal();
    final date =
        '${local.year}/${local.month.toString().padLeft(2, '0')}/'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';

    if (!budget.take()) return const SizedBox.shrink();
    if (note.system) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.bolt_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: SelectionArea(
                  child: Text('$authorText · $date\n${note.body}'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final project = widget.project;
    final actionsPending = _pendingNoteActionIds.contains(note.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    authorText,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(date, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(
              key: ValueKey('work-item-activity-note-actions:${note.id}'),
              tooltip: '留言動作',
              onPressed: actionsPending
                  ? null
                  : () => unawaited(_openNoteActions(discussion, note)),
              icon: actionsPending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.more_vert),
            ),
          ],
        ),
        const SizedBox(height: 6),
        MarkdownView(
          note.body,
          account: widget.account,
          api: project == null ? null : widget.api,
          projectId: project?.id,
          projectWeb: project == null
              ? null
              : widget.account.instance.projectWeb(project.path),
          projectPath: project?.path,
          base: project == null
              ? null
              : widget.account.instance.projectWeb(project.path),
          budget: _attachmentBudget,
        ),
      ],
    );
  }
}

sealed class _WorkItemNoteActionResult {
  const _WorkItemNoteActionResult();
}

final class _EditWorkItemNoteAction extends _WorkItemNoteActionResult {
  const _EditWorkItemNoteAction(this.target);

  final WorkItemActivityEditTarget target;
}

final class _WorkItemNoteChangedAction extends _WorkItemNoteActionResult {
  const _WorkItemNoteChangedAction();
}

class _WorkItemNoteActionsDialog extends StatefulWidget {
  const _WorkItemNoteActionsDialog({
    required this.loadEdit,
    required this.loadDelete,
    required this.deleteNote,
    required this.loadReactions,
    required this.setReaction,
    required this.account,
    required this.scopeLabel,
    required this.permalink,
    required this.ownerKey,
    required this.isCurrent,
  });

  final Future<WorkItemActivityEditAccess> Function() loadEdit;
  final Future<WorkItemActivityDeleteAccess> Function() loadDelete;
  final Future<void> Function(WorkItemActivityDeleteTarget target) deleteNote;
  final Future<WorkItemActivityReactionAccess> Function() loadReactions;
  final Future<WorkItemActivityReactionAccess> Function(
    WorkItemActivityReactionTarget target,
    String name, {
    required bool awarded,
  })
  setReaction;
  final Account account;
  final String scopeLabel;
  final Uri? permalink;
  final Object ownerKey;
  final bool Function() isCurrent;

  @override
  State<_WorkItemNoteActionsDialog> createState() =>
      _WorkItemNoteActionsDialogState();
}

class _WorkItemNoteActionsDialogState
    extends State<_WorkItemNoteActionsDialog> {
  WorkItemActivityEditAccess? _editAccess;
  ApiFailure? _editError;
  bool _loadingEdit = false;
  bool _deleteOpen = false;
  WorkItemActivityDeleteAccess? _deleteAccess;
  ApiFailure? _deleteError;
  bool _loadingDelete = false;
  bool _deleting = false;
  bool _deleteUncertain = false;
  bool _reactionsOpen = false;
  bool _reactionPickerOpen = false;
  WorkItemActivityReactionAccess? _reactionAccess;
  ApiFailure? _reactionError;
  bool _loadingReactions = false;
  bool _changingReaction = false;
  bool _reactionUncertain = false;

  bool get _writeBusy => _deleting || _changingReaction;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEdit());
  }

  Future<void> _loadEdit() async {
    if (_loadingEdit || !widget.isCurrent()) return;
    setState(() {
      _loadingEdit = true;
      _editError = null;
    });
    try {
      final access = await widget.loadEdit();
      if (mounted && widget.isCurrent()) {
        setState(() => _editAccess = access);
      }
    } catch (error) {
      if (mounted && widget.isCurrent()) {
        setState(() => _editError = safeFailure(error));
      }
    } finally {
      if (mounted && widget.isCurrent()) {
        setState(() => _loadingEdit = false);
      }
    }
  }

  void _openDelete() {
    if (_loadingDelete || _deleting || !widget.isCurrent()) return;
    setState(() {
      _deleteOpen = true;
      _deleteAccess = null;
      _deleteError = null;
    });
    unawaited(_loadDelete());
  }

  Future<void> _loadDelete() async {
    if (_loadingDelete ||
        _deleting ||
        _deleteUncertain ||
        !widget.isCurrent()) {
      return;
    }
    setState(() {
      _loadingDelete = true;
      _deleteError = null;
      _deleteAccess = null;
    });
    try {
      final access = await widget.loadDelete();
      if (mounted && widget.isCurrent()) {
        setState(() => _deleteAccess = access);
      }
    } catch (error) {
      if (mounted && widget.isCurrent()) {
        setState(() => _deleteError = safeFailure(error));
      }
    } finally {
      if (mounted && widget.isCurrent()) {
        setState(() => _loadingDelete = false);
      }
    }
  }

  Future<void> _delete() async {
    final target = _deleteAccess?.target;
    if (target == null ||
        _deleting ||
        _deleteUncertain ||
        !widget.isCurrent()) {
      return;
    }
    setState(() {
      _deleting = true;
      _deleteError = null;
    });
    try {
      await widget.deleteNote(target);
      if (!mounted || !widget.isCurrent()) return;
      Navigator.of(context).pop(const _WorkItemNoteChangedAction());
    } catch (error) {
      if (!mounted || !widget.isCurrent()) return;
      final failure = safeFailure(error);
      setState(() {
        _deleteError = failure;
        _deleteAccess = null;
        _deleteUncertain = failure.kind == FailureKind.writeUncertain;
      });
    } finally {
      if (mounted && widget.isCurrent()) setState(() => _deleting = false);
    }
  }

  void _openReactions() {
    if (!widget.isCurrent()) return;
    if (_reactionsOpen) {
      setState(() {
        _reactionsOpen = false;
        _reactionPickerOpen = false;
      });
      return;
    }
    setState(() => _reactionsOpen = true);
    if (_reactionAccess == null && !_loadingReactions) {
      unawaited(_loadReactions());
    }
  }

  Future<void> _loadReactions() async {
    if (_loadingReactions ||
        _changingReaction ||
        _reactionUncertain ||
        !widget.isCurrent()) {
      return;
    }
    setState(() {
      _loadingReactions = true;
      _reactionError = null;
      _reactionAccess = null;
      _reactionPickerOpen = false;
    });
    try {
      final access = await widget.loadReactions();
      if (mounted && widget.isCurrent()) {
        setState(() => _reactionAccess = access);
      }
    } catch (error) {
      if (mounted && widget.isCurrent()) {
        setState(() => _reactionError = safeFailure(error));
      }
    } finally {
      if (mounted && widget.isCurrent()) {
        setState(() => _loadingReactions = false);
      }
    }
  }

  bool _hasMyReaction(WorkItemActivityReactionAccess access, String name) =>
      access.actorId != null &&
      access.reactions.any(
        (reaction) =>
            reaction.name == name && reaction.actorId == access.actorId,
      );

  Future<void> _setReaction(String name, {required bool awarded}) async {
    final access = _reactionAccess;
    final target = access?.target;
    if (access == null ||
        target == null ||
        !access.canAward ||
        _changingReaction ||
        _reactionUncertain ||
        !widget.isCurrent()) {
      return;
    }
    setState(() {
      _changingReaction = true;
      _reactionError = null;
      _reactionPickerOpen = false;
    });
    try {
      final fresh = await widget.setReaction(target, name, awarded: awarded);
      if (mounted && widget.isCurrent()) {
        setState(() => _reactionAccess = fresh);
      }
    } catch (error) {
      if (!mounted || !widget.isCurrent()) return;
      final failure = safeFailure(error);
      setState(() {
        _reactionError = failure;
        _reactionAccess = null;
        _reactionUncertain = failure.kind == FailureKind.writeUncertain;
      });
    } finally {
      if (mounted && widget.isCurrent()) {
        setState(() => _changingReaction = false);
      }
    }
  }

  Future<void> _copyPermalink() async {
    final permalink = widget.permalink;
    if (permalink == null || !widget.isCurrent()) return;
    try {
      await Clipboard.setData(ClipboardData(text: permalink.toString()));
    } catch (_) {
      if (!mounted || !widget.isCurrent()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('無法複製留言連結。')));
      return;
    }
    if (!mounted || !widget.isCurrent()) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已複製留言連結。')));
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_writeBusy,
    child: AlertDialog(
      scrollable: true,
      title: Text(_deleteOpen ? '刪除留言' : '留言動作'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: _deleteOpen ? _deleteContent(context) : _actionsContent(context),
      ),
      actions: [
        if (_deleteOpen && !_deleting && !_deleteUncertain)
          TextButton(
            onPressed: widget.isCurrent()
                ? () => setState(() {
                    _deleteOpen = false;
                    _deleteAccess = null;
                    _deleteError = null;
                  })
                : null,
            child: const Text('返回'),
          ),
        TextButton(
          onPressed: _writeBusy ? null : () => Navigator.of(context).pop(),
          child: const Text('關閉'),
        ),
      ],
    ),
  );

  Widget _actionsContent(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _permissionContent(context),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          key: const ValueKey('work-item-activity-note-reactions'),
          onPressed: widget.isCurrent() && !_changingReaction
              ? _openReactions
              : null,
          icon: const Icon(Icons.add_reaction_outlined),
          label: Text(_reactionsOpen ? '收合表情回應' : '表情回應'),
        ),
      ),
      if (_reactionsOpen) ...[
        const SizedBox(height: 8),
        _reactionContent(context),
      ],
      if (widget.permalink case final permalink?) ...[
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            key: const ValueKey('work-item-activity-copy-note-link'),
            onPressed: widget.isCurrent() && !_writeBusy
                ? _copyPermalink
                : null,
            icon: const Icon(Icons.link_outlined),
            label: const Text('複製留言連結'),
          ),
        ),
        Row(
          children: [
            const Expanded(child: Text('以其他 App 分享')),
            ResourceShareButton(
              uri: permalink,
              ownerKey: widget.ownerKey,
              isCurrent: () => widget.isCurrent() && !_writeBusy,
            ),
          ],
        ),
      ],
    ],
  );

  Widget _permissionContent(BuildContext context) {
    if (_loadingEdit) {
      return const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Expanded(child: Text('正在確認留言權限…')),
        ],
      );
    }
    if (_editError case final error?) {
      if (error.kind == FailureKind.unsupported) {
        return const Text('此實例暫不支援編輯留言；留言仍可閱讀。');
      }
      if (error.kind == FailureKind.cancelled) {
        return const Text('留言或帳號已變更，請關閉後重新開啟留言動作。');
      }
      return _InlineActivityFailure(
        error: error,
        onRetry: _loadEdit,
        retryLabel: '重試留言權限',
      );
    }
    final access = _editAccess;
    if (access == null) return const SizedBox.shrink();
    final target = access.target;
    if (!access.canEditNote) {
      return const Text('目前帳號可閱讀這則留言，但沒有編輯留言的權限。');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (target == null)
          const Text('伺服器未提供安全的編輯目標；留言仍可閱讀。')
        else
          FilledButton.icon(
            key: const ValueKey('work-item-activity-edit-note'),
            onPressed: _writeBusy
                ? null
                : () => Navigator.of(
                    context,
                  ).pop(_EditWorkItemNoteAction(target)),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('編輯留言'),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('work-item-activity-delete-note'),
          onPressed: widget.isCurrent() && !_writeBusy ? _openDelete : null,
          icon: const Icon(Icons.delete_outline),
          label: const Text('刪除留言'),
        ),
      ],
    );
  }

  Widget _deleteContent(BuildContext context) {
    if (_loadingDelete || _deleting) {
      return Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(_deleting ? '正在刪除留言…' : '正在重新確認刪除權限…')),
        ],
      );
    }
    if (_deleteError case final error?) {
      if (_deleteUncertain) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(error.title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text('刪除結果尚未確認。請關閉並重新整理活動後再確認，這裡不會重複送出。'),
          ],
        );
      }
      if (error.kind == FailureKind.invisible) {
        return FailureNotice(
          error,
          account: widget.account,
          resourceLabel: '${widget.scopeLabel} 留言',
          onRetry: _loadDelete,
          onSwitchAccount: endSessionFrom(context),
        );
      }
      return _InlineActivityFailure(
        error: error,
        onRetry: _loadDelete,
        retryLabel: '重新確認刪除權限',
      );
    }
    final access = _deleteAccess;
    if (access == null) return const SizedBox.shrink();
    final target = access.target;
    if (!access.canDeleteNote) {
      return const Text('目前帳號沒有刪除這則留言的權限。');
    }
    if (target == null) {
      return const Text('伺服器未提供安全的刪除目標；留言仍會保留。');
    }
    final body = target.note.body.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.scopeLabel, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 144),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SingleChildScrollView(
            child: Text(body.isEmpty ? '（空白留言）' : body),
          ),
        ),
        const SizedBox(height: 12),
        const Text('刪除後無法復原。請確認這是你要刪除的留言。'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('work-item-activity-confirm-delete-note'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: widget.isCurrent() ? _delete : null,
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('永久刪除留言'),
          ),
        ),
      ],
    );
  }

  Widget _reactionContent(BuildContext context) {
    if (_loadingReactions) {
      return const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Expanded(child: Text('正在讀取表情回應…')),
        ],
      );
    }
    if (_reactionError case final error?) {
      if (_reactionUncertain) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(error.title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text('表情回應結果尚未確認。請關閉並重新整理活動後再確認，這裡不會重複送出。'),
          ],
        );
      }
      if (error.kind == FailureKind.invisible) {
        return FailureNotice(
          error,
          account: widget.account,
          resourceLabel: '${widget.scopeLabel} 留言',
          onRetry: _loadReactions,
          onSwitchAccount: endSessionFrom(context),
        );
      }
      return _InlineActivityFailure(
        error: error,
        onRetry: _loadReactions,
        retryLabel: '重新讀取表情回應',
      );
    }
    final access = _reactionAccess;
    if (access == null) return const SizedBox.shrink();
    final counts = <String, int>{};
    final glyphs = <String, String>{};
    for (final reaction in access.reactions) {
      counts[reaction.name] = (counts[reaction.name] ?? 0) + 1;
      final unicode = reaction.unicode?.trim();
      if (unicode != null && unicode.isNotEmpty) {
        glyphs[reaction.name] = unicode;
      }
    }
    final controlsEnabled =
        access.canAward &&
        access.target != null &&
        !_changingReaction &&
        widget.isCurrent();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (counts.isEmpty) const Text('目前還沒有表情回應。'),
        if (counts.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in counts.entries)
                Builder(
                  builder: (context) {
                    final selected = _hasMyReaction(access, entry.key);
                    final glyph = glyphs[entry.key] ?? reactionGlyph(entry.key);
                    return Semantics(
                      button: controlsEnabled,
                      selected: selected,
                      label:
                          '$glyph ${entry.key} 表情回應，${entry.value} 人${selected ? '，您已回應' : ''}',
                      excludeSemantics: true,
                      child: FilterChip(
                        key: ValueKey(
                          'work-item-activity-reaction:${entry.key}',
                        ),
                        showCheckmark: false,
                        selected: selected,
                        label: Text('$glyph ${entry.value}'),
                        onSelected: controlsEnabled
                            ? (_) => unawaited(
                                _setReaction(entry.key, awarded: !selected),
                              )
                            : null,
                      ),
                    );
                  },
                ),
            ],
          ),
        if (!access.canAward) ...[
          const SizedBox(height: 8),
          const Text('目前帳號可查看表情回應，但沒有新增或移除的權限。'),
          const SizedBox(height: 8),
          const ActionChip(
            avatar: Icon(Icons.add_reaction_outlined, size: 18),
            label: Text('新增表情回應'),
            onPressed: null,
          ),
        ] else if (access.target == null) ...[
          const SizedBox(height: 8),
          const Text('伺服器未提供安全的表情回應目標。'),
        ] else ...[
          const SizedBox(height: 8),
          ActionChip(
            key: const ValueKey('work-item-activity-add-reaction'),
            avatar: _changingReaction
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_reaction_outlined, size: 18),
            label: Text(_reactionPickerOpen ? '收合表情選擇' : '新增表情回應'),
            onPressed: controlsEnabled
                ? () =>
                      setState(() => _reactionPickerOpen = !_reactionPickerOpen)
                : null,
          ),
          if (_reactionPickerOpen) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in reactionChoices.entries)
                  Semantics(
                    button: true,
                    label:
                        '${entry.key} 表情回應${_hasMyReaction(access, entry.key) ? '，目前已選取' : ''}',
                    excludeSemantics: true,
                    child: IconButton(
                      key: ValueKey(
                        'work-item-activity-pick-reaction:${entry.key}',
                      ),
                      tooltip: entry.key,
                      onPressed: controlsEnabled
                          ? () => unawaited(
                              _setReaction(
                                entry.key,
                                awarded: !_hasMyReaction(access, entry.key),
                              ),
                            )
                          : null,
                      icon: Text(
                        entry.value,
                        style: const TextStyle(fontSize: 24),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

class _DiscussionPage {
  _DiscussionPage(this.result)
    : discussions = [
        for (final value in result.snapshot.discussions.items)
          _DiscussionState(
            value,
            next: result.nextNotesByDiscussion[value.id],
            replyTarget: result.replyTargetsByDiscussion[value.id],
          ),
      ];

  final WorkItemActivityPage result;
  final List<_DiscussionState> discussions;
}

class _DiscussionState {
  _DiscussionState(this.value, {required this.next, required this.replyTarget})
    : notesAvailability = value.notes.availability,
      notes = value.notes.items.toList();

  final WorkItemActivityDiscussion value;
  final List<WorkItemActivityNote> notes;
  WorkItemActivityConnectionAvailability notesAvailability;
  WorkItemDiscussionNotesContinuation? next;
  final WorkItemActivityReplyTarget? replyTarget;
  ApiFailure? error;
  bool loading = false;
  bool commentsExpanded = false;
  bool continuationUnavailable = false;
  int pageCount = 1;
}

class _ActivityRenderBudget {
  _ActivityRenderBudget(this.limit);

  final int limit;
  int rendered = 0;
  int omitted = 0;

  bool take() {
    if (rendered >= limit) {
      omitted++;
      return false;
    }
    rendered++;
    return true;
  }
}

class _InlineActivityFailure extends StatelessWidget {
  const _InlineActivityFailure({
    required this.error,
    required this.onRetry,
    this.retryLabel = '重試',
  });

  final ApiFailure error;
  final VoidCallback onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(error.title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(error.detail),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: Text(retryLabel),
      ),
    ],
  );
}

class _ActivityRetentionLimitNotice extends StatelessWidget {
  const _ActivityRetentionLimitNotice();

  @override
  Widget build(BuildContext context) => const Text(
    '已達活動快取上限（2,000 則或 4 Mi 字元）。已載入的活動仍保留；'
    '重新整理後才能繼續載入。',
  );
}
