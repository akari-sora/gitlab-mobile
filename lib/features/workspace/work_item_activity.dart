import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_activity_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/attachment_budget.dart';
import '../../shared/markdown_view.dart';

const _maxDiscussionPages = 5;
const _maxNotePages = 5;
const _maxRenderedActivityItems = 100;
const _maxRetainedNotes = 2000;
const _maxRetainedBodyCharacters = 4 * 1024 * 1024;

/// A bounded, read-only activity reader for a work item.
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
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final Project? project;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  State<WorkItemActivityPanel> createState() => _WorkItemActivityPanelState();
}

class _WorkItemActivityPanelState extends State<WorkItemActivityPanel> {
  final List<_DiscussionPage> _pages = [];
  final Set<String> _retainedNoteIds = {};
  AttachmentBudget _attachmentBudget = AttachmentBudget();
  ApiFailure? _initialError;
  ApiFailure? _nextPageError;
  bool _expanded = false;
  bool _loadingInitial = false;
  bool _loadingNextPage = false;
  bool _retentionLimitReached = false;
  int _activePage = 0;
  int _epoch = 0;
  int _retainedBodyCharacters = 0;

  bool get _hasNotesWidget =>
      widget.detail.widgetTypes.any((type) => type.toUpperCase() == 'NOTES');

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);

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
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _reset();
  }

  void _reset({bool notify = true}) {
    _epoch++;
    _pages.clear();
    _retainedNoteIds.clear();
    _attachmentBudget = AttachmentBudget();
    _initialError = null;
    _nextPageError = null;
    _expanded = false;
    _loadingInitial = false;
    _loadingNextPage = false;
    _retentionLimitReached = false;
    _activePage = 0;
    _retainedBodyCharacters = 0;
    if (notify && mounted) setState(() {});
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
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      _requireSnapshotIdentity(result.snapshot, expected);
      if (!_retainNotes(_pageNotes(result))) {
        setState(() => _retentionLimitReached = true);
        return;
      }
      setState(() => _pages.add(_DiscussionPage(result)));
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
        key: ValueKey('work-item-activity-expansion-$_epoch'),
        maintainState: false,
        title: Text('活動', style: Theme.of(context).textTheme.titleMedium),
        subtitle: const Text('留言與系統事件'),
        onExpansionChanged: (expanded) {
          _expanded = expanded;
          if (expanded) unawaited(_loadInitial());
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
          const Text('尚無活動'),
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
          _note(context, visible[index], budget),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(authorText, style: Theme.of(context).textTheme.labelLarge),
        Text(date, style: Theme.of(context).textTheme.bodySmall),
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

class _DiscussionPage {
  _DiscussionPage(this.result)
    : discussions = [
        for (final value in result.snapshot.discussions.items)
          _DiscussionState(value, next: result.nextNotesByDiscussion[value.id]),
      ];

  final WorkItemActivityPage result;
  final List<_DiscussionState> discussions;
}

class _DiscussionState {
  _DiscussionState(this.value, {required this.next})
    : notesAvailability = value.notes.availability,
      notes = value.notes.items.toList();

  final WorkItemActivityDiscussion value;
  final List<WorkItemActivityNote> notes;
  WorkItemActivityConnectionAvailability notesAvailability;
  WorkItemDiscussionNotesContinuation? next;
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
  const _InlineActivityFailure({required this.error, required this.onRetry});

  final ApiFailure error;
  final VoidCallback onRetry;

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
        label: const Text('重試'),
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
