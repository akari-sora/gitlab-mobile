import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../core/project_locator.dart';
import '../../shared/external_link.dart';
import '../../shared/hub_ui.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/workspace_ui.dart';
import 'navigation.dart';
import 'records_feed.dart';
import 'search_page.dart';
import 'work_item_page.dart';

import '../../l10n/l10n.dart';
class InboxPage extends StatefulWidget {
  const InboxPage({super.key, required this.account, required this.api, this.todoToken = 0});
  final Account account;
  final GitLabApi api;

  /// Bumped by the shell when Home's 待辦 opens the inbox: the 待辦 pill is
  /// selected again even if another one was left open.
  final int todoToken;
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final _chrome = ScrollChromeController();
  PageStorageBucket _storage = PageStorageBucket();
  int _ownerEpoch = 0;

  /// Reused across parent rebuilds (tab taps, root destination switches) so
  /// retained offstage panels are not rebuilt; dropped whenever the account or
  /// client object changes.
  Widget? _panels;
  Account get account => widget.account;
  GitLabApi get api => widget.api;

  @override
  void didUpdateWidget(covariant InboxPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api)) {
      _ownerEpoch++;
      _storage = PageStorageBucket();
    }
    if (!identical(oldWidget.account, widget.account) ||
        !identical(oldWidget.api, widget.api)) {
      _panels = null;
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _panels = null;
  }

  @override
  void dispose() {
    _chrome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    key: ValueKey('inbox-owner-$_ownerEpoch'),
    length: 4,
    child: _TabRequest(token: widget.todoToken, index: 0, onSelected: _chrome.show, child: Scaffold(
    body: NotificationListener<ScrollNotification>(onNotification: _chrome.handle, child: StatusBarInset(child: gestureSafe(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CollapsingChrome(visible: _chrome, child: AppBar(primary: false, title: LargeTitle(l10n.inboxTab), actions: [
        IconButton(tooltip: l10n.globalSearch, icon: const Icon(Icons.manage_search),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => SearchPage(account: account, api: api)))),
      ])),
      _InboxFilters(onSelected: _chrome.show),
      Expanded(child: _panels ??= _buildPanels(context)),
    ])))),
  )));

  // Horizontal swipes belong to the todo rows (swipe to complete), so the
  // tabs change from the tab bar only.
  Widget _buildPanels(BuildContext context) => PageStorage(bucket: _storage, child: TabBarView(
    physics: const NeverScrollableScrollPhysics(),
    children: [
      _InboxPanel(index: 0, child: _TodoFeed(account: account, api: api)),
      _InboxPanel(index: 1,
        child: _WorkFeed(account: account, api: api, kind: _WorkKind.assigned)),
      _InboxPanel(index: 2, child: RecordsFeed(
        identity: 'review-requests', empty: l10n.noMergeRequestsToReview, account: account,
        emptyIcon: Icons.rate_review_outlined,
        resourceLabel: l10n.mergeRequestsToReview, underShell: true, onSwitchAccount: endSessionFrom(context),
        load: (next) => api.records(['merge_requests'], query: {'scope': 'all', 'reviewer_id': '${account.user.id}',
          'state': 'opened', 'with_labels_details': 'true'}, next: next),
        itemBuilder: (context, data) => inboxWorkItem(context, account, api, data, 'merge_requests'))),
      _InboxPanel(index: 3,
        child: _WorkFeed(account: account, api: api, kind: _WorkKind.created)),
    ]));
}

/// Selects [index] of the enclosing [DefaultTabController] whenever [token]
/// changes. It waits for the frame so the pills and panels rebuild normally.
class _TabRequest extends StatefulWidget {
  const _TabRequest({required this.token, required this.index, required this.onSelected, required this.child});
  final int token;
  final int index;
  final VoidCallback onSelected;
  final Widget child;
  @override
  State<_TabRequest> createState() => _TabRequestState();
}

class _TabRequestState extends State<_TabRequest> {
  @override
  void didUpdateWidget(covariant _TabRequest oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token == widget.token) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onSelected();
      DefaultTabController.of(context).index = widget.index;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// GitHub-style pill filters in place of a tab bar. They drive the same
/// [DefaultTabController], so each panel keeps its list state.
class _InboxFilters extends StatelessWidget {
  const _InboxFilters({required this.onSelected});
  final VoidCallback onSelected;
  static List<(String, IconData)> get _labels => [
    (l10n.todoLabel, Icons.notifications_none),
    (l10n.assignedToMe, Icons.assignment_ind_outlined),
    (l10n.reviewRequests, Icons.rate_review_outlined),
    (l10n.createdByMe, Icons.edit_note),
  ];
  @override
  Widget build(BuildContext context) {
    final tabs = DefaultTabController.of(context);
    final theme = Theme.of(context);
    return Material(
      color: theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(
          color: theme.dividerTheme.color ?? theme.colorScheme.outlineVariant))),
        child: ListenableBuilder(
          listenable: tabs,
          builder: (context, _) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(children: [
              for (final (index, (label, icon)) in _labels.indexed) Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterPill(
                  key: ValueKey('inbox-filter-$index'),
                  label: label,
                  icon: icon,
                  selected: tabs.index == index,
                  onTap: () {
                    onSelected();
                    tabs.animateTo(index);
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _InboxPanel extends StatefulWidget {
  const _InboxPanel({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_InboxPanel> createState() => _InboxPanelState();
}

class _InboxPanelState extends State<_InboxPanel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tabs = DefaultTabController.of(context);
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, child) => TickerMode(enabled: tabs.index == widget.index, child: child!),
      child: widget.child,
    );
  }
}

Widget inboxWorkItem(BuildContext context, Account account, GitLabApi api, Json data, String resource) => workItemCard(context, data,
  mr: resource == 'merge_requests',
  project: valueText(valueObject(data, 'references'), 'full').split(RegExp('[#!]')).first,
  onTap: () => ResourceNavigator(account, api).workItem(context, '${valueInt(data, 'project_id')}', resource, valueInt(data, 'iid')));

enum _WorkKind { assigned, created }

/// Issues or merge requests assigned to, or created by, the signed-in user
/// across every project, with a switch between the two kinds.
class _WorkFeed extends StatefulWidget {
  const _WorkFeed({required this.account, required this.api, required this.kind});
  final Account account;
  final GitLabApi api;
  final _WorkKind kind;
  @override
  State<_WorkFeed> createState() => _WorkFeedState();
}

class _WorkFeedState extends State<_WorkFeed> {
  late String _resource = widget.kind == _WorkKind.assigned ? 'issues' : 'merge_requests';

  @override
  Widget build(BuildContext context) {
    final assigned = widget.kind == _WorkKind.assigned;
    final mr = _resource == 'merge_requests';
    final scope = assigned ? 'assigned_to_me' : 'created_by_me';
    final label = l10n.inboxScopeTitle(assigned ? l10n.assignedToMe : l10n.createdByMe2, mr ? l10n.mergeRequests : l10n.issues);
    return RecordsFeed(
      identity: '$scope/$_resource', storageId: scope,
      empty: assigned ? (mr ? l10n.noMergeRequestsAssignedToYou : l10n.noIssuesAssignedToYou) : (mr ? l10n.noOpenMergeRequestsByYou : l10n.noOpenIssuesByYou),
      emptyIcon: mr ? Icons.merge : Icons.adjust,
      account: widget.account, resourceLabel: label, underShell: true, onSwitchAccount: endSessionFrom(context),
      leading: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(feedGutter(context), 10, feedGutter(context), 0),
        child: Align(alignment: Alignment.centerLeft, child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'issues', icon: Icon(Icons.adjust, size: 18), label: Text(l10n.issues)),
            ButtonSegment(value: 'merge_requests', icon: Icon(Icons.merge, size: 18), label: Text(l10n.mergeRequests)),
          ],
          selected: {_resource},
          onSelectionChanged: (values) => setState(() => _resource = values.first),
        )),
      ),
      load: (next) => widget.api.records([_resource], query: {'scope': scope, 'state': 'opened', 'with_labels_details': 'true'},
        next: next),
      itemBuilder: (context, data) => inboxWorkItem(context, widget.account, widget.api, data, _resource),
    );
  }
}

/// Inbox filters, each one `GET /todos` filter GitLab applies server-side.
enum _TodoFilter {
  all(null),
  review(('action', 'review_requested')),
  mentioned(('action', 'mentioned')),
  assigned(('action', 'assigned')),
  failed(('action', 'build_failed')),
  mergeRequests(('type', 'MergeRequest')),
  issues(('type', 'Issue')),
  // REST leaves snoozed todos out; this list comes from GraphQL.
  snoozed(null);

  const _TodoFilter(this.parameter);
  final (String, String)? parameter;

  String get label => switch (this) {
    _TodoFilter.all => l10n.filterAll,
    _TodoFilter.review => l10n.reviewRequested,
    _TodoFilter.mentioned => l10n.mentionedYou,
    _TodoFilter.assigned => l10n.assignedToYou,
    _TodoFilter.failed => l10n.pipelineFailed,
    _TodoFilter.mergeRequests => l10n.mergeRequests,
    _TodoFilter.issues => l10n.issues,
    _TodoFilter.snoozed => l10n.snoozed,
  };

  Map<String, String> get query => {
    'state': 'pending',
    if (parameter case (final name, final value)) name: value,
  };
}

/// When a snoozed todo comes back, picked from presets in local time.
List<(String, DateTime)> todoSnoozePresets(DateTime now) {
  DateTime at9(DateTime day) => DateTime(day.year, day.month, day.day, 9);
  final tomorrow = now.add(const Duration(days: 1));
  final daysToMonday = (DateTime.monday - now.weekday + 7) % 7;
  final monday = now.add(Duration(days: daysToMonday == 0 ? 7 : daysToMonday));
  return [
    (l10n.snoozeInOneHour, now.add(const Duration(hours: 1))),
    (l10n.snoozeInThreeHours, now.add(const Duration(hours: 3))),
    (l10n.snoozeTomorrowMorning, at9(tomorrow)),
    (l10n.snoozeNextMondayMorning, at9(monday)),
  ];
}

/// A local wall-clock time relative to [now]: 今天 14:05, 明天 09:00 or 10/26 09:00.
String todoUntilLabel(DateTime until, DateTime now) {
  final local = until.toLocal();
  final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = day.difference(today).inDays;
  if (days == 0) return l10n.snoozeTodayAt(time);
  if (days == 1) return l10n.snoozeTomorrowAt(time);
  return '${local.month}/${local.day} $time';
}

class _TodoFeed extends StatefulWidget {
  const _TodoFeed({required this.account, required this.api});
  final Account account;
  final GitLabApi api;
  @override
  State<_TodoFeed> createState() => _TodoFeedState();
}
class _TodoFeedState extends State<_TodoFeed> with AutomaticKeepAliveClientMixin {
  final _feed = GlobalKey<RecordsFeedState>();
  final _busy = ValueNotifier<Set<int>>(<int>{});
  final _clearing = ValueNotifier(false);
  _TodoFilter _filter = _TodoFilter.all;

  /// Swiped rows waiting out the undo window, hidden even if a reload that
  /// started earlier brings them back. The tab stays alive meanwhile, so
  /// switching tabs neither drops the write nor strands the 復原 button.
  final _pending = <int>{};

  /// Replaced only when [_pending] changes, over a snapshot of it, so the feed
  /// keeps its derived rows across rebuilds that leave the pending set alone.
  bool Function(Json item) _visible = _visibleExcept(const <int>{});

  static bool Function(Json item) _visibleExcept(Set<int> hidden) =>
      (item) => !hidden.contains(valueInt(item, 'id'));

  @override
  bool get wantKeepAlive => _pending.isNotEmpty;

  void _setPending(int id, bool pending) {
    if (pending == _pending.contains(id)) return;
    setState(() {
      pending ? _pending.add(id) : _pending.remove(id);
      _visible = _visibleExcept(Set<int>.unmodifiable(_pending));
    });
    updateKeepAlive();
  }

  void _setBusy(int id, bool busy) {
    final next = Set<int>.of(_busy.value);
    final changed = busy ? next.add(id) : next.remove(id);
    if (changed) _busy.value = next;
  }

  /// GitLab pages todos by offset: after a change the list reloads, otherwise
  /// the next page would start one row late and skip a todo.
  Future<void> _done(int id) async {
    if (_busy.value.contains(id)) return;
    _setBusy(id, true);
    try {
      await widget.api.markTodoDone(id);
      if (mounted) _feed.currentState?.removeItem('$id');
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) {
        _setBusy(id, false);
        _setPending(id, false);
      }
    }
    if (mounted) await _feed.currentState?.refresh();
  }

  Future<void> _snooze(int id) async {
    if (_busy.value.contains(id)) return;
    final now = DateTime.now();
    final until = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(l10n.snoozeThisTodo, style: Theme.of(sheetContext).textTheme.titleMedium),
          subtitle: Text(l10n.snoozeReturnsToInbox)),
        for (final (label, at) in todoSnoozePresets(now)) ListTile(
          key: ValueKey('todo-snooze-$label'),
          leading: const Icon(Icons.snooze),
          title: Text(label),
          trailing: Text(todoUntilLabel(at, now)),
          onTap: () => Navigator.pop(sheetContext, at),
        ),
      ])),
    );
    if (until == null || !mounted) return;
    _setBusy(id, true);
    try {
      final acknowledged = await widget.api.snoozeTodo(id, until);
      if (!mounted) return;
      _feed.currentState?.removeItem('$id');
      final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(l10n.snoozedUntil(todoUntilLabel(acknowledged, DateTime.now()))),
        action: SnackBarAction(label: l10n.undoAction, onPressed: () => unawaited(_unsnooze(id, undo: true))),
      ));
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) _setBusy(id, false);
    }
    if (mounted) await _feed.currentState?.refresh();
  }

  /// Brings a snoozed todo back now: from the 已延後 list, or as the undo of
  /// a snooze just made.
  Future<void> _unsnooze(int id, {bool undo = false}) async {
    if (_busy.value.contains(id)) return;
    _setBusy(id, true);
    try {
      await widget.api.unsnoozeTodo(id);
      if (!mounted) return;
      if (!undo) {
        _feed.currentState?.removeItem('$id');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.movedBackToInbox)));
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) _setBusy(id, false);
    }
    if (mounted) await _feed.currentState?.refresh();
  }

  /// A swipe only hides the row; the write goes out once the undo snack bar
  /// closes without 復原. A newer swipe closes the previous bar, committing it.
  void _swiped(int id) {
    _setPending(id, true);
    final accessible = MediaQuery.accessibleNavigationOf(context);
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final bar = messenger.showSnackBar(SnackBar(
      content: Text(l10n.markedAsDone),
      duration: const Duration(seconds: 4),
      // Times out like a plain snack bar; screen-reader users keep it until
      // they choose 復原 or close it, which commits.
      persist: accessible,
      showCloseIcon: accessible,
      action: SnackBarAction(label: l10n.undoAction, onPressed: () {}),
    ));
    unawaited(bar.closed.then((reason) {
      if (!mounted) return;
      if (reason == SnackBarClosedReason.action) {
        _setPending(id, false);
      } else {
        unawaited(_done(id));
      }
    }));
  }

  Future<void> _clearAll() async {
    if (_clearing.value || !await confirmAction(context, l10n.markAllDoneConfirm, l10n.markAllDoneWarning)) return;
    if (!mounted) return;
    _clearing.value = true;
    try {
      await widget.api.markAllTodosDone();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) _clearing.value = false;
    }
    if (mounted) await _feed.currentState?.refresh();
  }

  /// Native pages open only when the todo names its target unambiguously;
  /// every other row explains itself and offers the server's own web link.
  void _openTarget(BuildContext context, _TodoTarget target, String title, String projectPath) {
    final navigator = ResourceNavigator(widget.account, widget.api);
    switch (target.route) {
      case _TodoRoute.workItem:
        unawaited(navigator.workItem(context, '${target.projectId}', target.resource, target.iid));
      case _TodoRoute.commit:
        unawaited(navigator.commit(context, '${target.projectId}', target.sha));
      case _TodoRoute.link:
        unawaited(navigator.link(context, target.link!));
      case _TodoRoute.explain:
        unawaited(_explain(context, target, title, projectPath));
    }
  }

  Future<void> _explain(BuildContext context, _TodoTarget target, String title, String projectPath) async {
    final api = widget.api;
    final accountKey = widget.account.key;
    bool current() => mounted && !api.isClosed && identical(api, widget.api) &&
        accountKey == widget.account.key;
    final refresh = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _TodoTargetSheet(target: target, title: title, projectPath: projectPath,
        isCurrent: current),
    );
    if (refresh == true && current()) await _feed.currentState?.refresh();
  }

  @override
  void dispose() {
    _busy.dispose();
    _clearing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _feedView(context);
  }

  /// Smaller, outlined chips, so they read as a refinement of the filled
  /// 待辦 pill above rather than a second row of destinations.
  Widget _filters(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(feedGutter(context), 6, feedGutter(context), 0),
      child: Row(children: [
        for (final filter in _TodoFilter.values) Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            key: ValueKey('todo-filter-${filter.name}'),
            label: Text(filter.label),
            selected: _filter == filter,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            labelStyle: theme.textTheme.labelLarge?.copyWith(
              color: _filter == filter ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
            backgroundColor: Colors.transparent,
            selectedColor: scheme.secondaryContainer,
            side: BorderSide(color: _filter == filter ? Colors.transparent : scheme.outlineVariant),
            onSelected: (_) => setState(() => _filter = filter),
          ),
        ),
      ]),
    );
  }

  Widget _feedView(BuildContext context) {
    final filtered = _filter != _TodoFilter.all;
    return RecordsFeed(key: _feed, identity: filtered ? 'todos/${_filter.name}' : 'todos', storageId: 'todos',
    empty: filtered ? l10n.noTodosForLabel(_filter.label) : l10n.allTodosDone,
    emptyDetail: _filter == _TodoFilter.snoozed
        ? l10n.snoozedTodosReturnHint
        : filtered ? l10n.switchToAllTodosHint : l10n.inboxEmptyEncouragement,
    emptyIcon: filtered ? Icons.filter_list_off : Icons.task_alt, emptyArt: filtered ? null : const CaughtUpArt(),
    filteredEmpty: l10n.todoAboutToBeDone,
    account: widget.account, resourceLabel: l10n.todoLabel, underShell: true,
    onSwitchAccount: endSessionFrom(context),
    visible: _visible,
    // The chips always show: an empty filter can be left, and an inbox with
    // nothing pending can still open 已延後.
    leading: (context, controller) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _filters(context),
            if (controller.items.isNotEmpty) Padding(
              padding: EdgeInsets.fromLTRB(feedGutter(context) + 4, 6, feedGutter(context) - 8, 0),
              child: Row(children: [
                Expanded(child: Text(l10n.todoSwipeHint(controller.items.where(_visible).length, controller.next == null ? '' : '+'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
                // Marks every pending todo, not just the filtered ones, so it
                // is offered only on the unfiltered list.
                if (!filtered) ValueListenableBuilder<bool>(
                  valueListenable: _clearing,
                  builder: (context, clearing, _) => TextButton.icon(
                    key: const ValueKey('todos-mark-all-done'),
                    onPressed: clearing ? null : _clearAll,
                    icon: const Icon(Icons.done_all, size: 18),
                    label: Text(l10n.markAllTodosDone),
                  ),
                ),
              ]),
            ),
          ]),
    load: _filter == _TodoFilter.snoozed
        ? (next) async {
            final snoozed = await widget.api.snoozedTodos();
            return ApiPage<Json>(snoozed.items);
          }
        : (next) => widget.api.records(['todos'], query: _filter.query, next: next),
    footer: _filter != _TodoFilter.snoozed ? null : (context, controller) => controller.items.length < todoSnoozedLimit
        ? const SizedBox.shrink()
        : Padding(padding: const EdgeInsets.only(top: 8), child: Text(l10n.snoozedTodosLimit(todoSnoozedLimit),
            style: Theme.of(context).textTheme.bodySmall)),
    itemBuilder: (context, data) {
      final target = valueObject(data, 'target'), project = valueObject(data, 'project');
      final id = valueInt(data, 'id');
      final todoTarget = _TodoTarget.of(data, widget.account.instance);
      final action = valueText(data, 'action_name');
      final actionLabel = switch (action) {
        'assigned' => l10n.assignedToYou, 'mentioned' || 'directly_addressed' => l10n.mentionedYou, 'review_requested' => l10n.reviewRequested,
        'build_failed' => l10n.pipelineFailed, 'marked' => l10n.markedByYou, 'approval_required' => l10n.needsYourApproval,
        'unmergeable' => l10n.cannotBeMerged, 'merge_train_removed' => l10n.removedFromMergeTrain, _ => '',
      };
      final author = valueObject(data, 'author');
      final scheme = Theme.of(context).colorScheme;
      final card = EntityCard(
        titleMaxLines: 3,
        leading: Container(width: 32, height: 32, alignment: Alignment.center,
          decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
          child: Icon(todoTarget.icon, size: 18, color: scheme.onPrimaryContainer)),
        title: Text(valueText(target, 'title', valueText(data, 'body', l10n.gitlabTodo))),
        subtitle: Text(valueText(project, 'path_with_namespace')),
        meta: [
          if (todoTarget.route == _TodoRoute.explain)
            MetaChip('${todoTarget.typeLabel} · ${todoTarget.web == null ? l10n.cannotOpen : l10n.webVersion}',
              icon: todoTarget.web == null ? Icons.link_off : Icons.open_in_new),
          if (actionLabel.isNotEmpty) MetaChip(actionLabel, icon: Icons.notifications_none),
          ?PersonChip.of(author),
          if (DateTime.tryParse(valueText(data, 'snoozed_until')) case final until?)
            MetaChip(l10n.snoozedUntil2(todoUntilLabel(until, DateTime.now())), icon: Icons.snooze)
          else
            MetaChip(relativeDate(valueText(data, 'updated_at', valueText(data, 'created_at'))), icon: Icons.schedule_outlined),
        ],
        trailing: ValueListenableBuilder<Set<int>>(
          valueListenable: _busy,
          builder: (context, busy, _) => Row(mainAxisSize: MainAxisSize.min, children: [
            if (_filter == _TodoFilter.snoozed)
              IconButton(tooltip: l10n.cancelSnooze, icon: const Icon(Icons.notifications_active_outlined),
                onPressed: busy.contains(id) ? null : () => unawaited(_unsnooze(id)))
            else
              IconButton(tooltip: l10n.snoozeThisTodo2, icon: const Icon(Icons.snooze),
                onPressed: busy.contains(id) ? null : () => unawaited(_snooze(id))),
            IconButton(tooltip: l10n.markTodoDone, icon: const Icon(Icons.check_circle_outline),
              onPressed: busy.contains(id) ? null : () => _done(id)),
          ]),
        ),
        onTap: () => _openTarget(context, todoTarget,
          valueText(target, 'title', valueText(data, 'body', l10n.gitlabTodo)),
          valueText(project, 'path_with_namespace')),
      );
      Widget background(Alignment alignment) => Container(
        alignment: alignment,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.done, color: scheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Text(l10n.done, style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
        ]),
      );
      return Dismissible(
        key: ValueKey('todo-$id'),
        background: background(Alignment.centerLeft),
        secondaryBackground: background(Alignment.centerRight),
        dismissThresholds: const {DismissDirection.startToEnd: .5, DismissDirection.endToStart: .5},
        confirmDismiss: (_) async => !_busy.value.contains(id),
        onDismissed: (_) => _swiped(id),
        child: card,
      );
    },
  );
  }
}

enum _TodoRoute { workItem, commit, link, explain }

/// What a todo row opens. Issue and merge request rows need the numeric
/// project ID and the target IID; commit rows need the project ID and a full
/// SHA. A known type missing those fields is never guessed into a native page.
/// Other types (work items, epics) open in the app only when the server's
/// `target_url` names one concrete resource on this instance.
final class _TodoTarget {
  const _TodoTarget._(
    this.route,
    this.typeLabel,
    this.icon, {
    this.projectId = 0,
    this.resource = '',
    this.iid = 0,
    this.sha = '',
    this.web,
    this.link,
    this.nativeType = false,
  });

  factory _TodoTarget.of(Json data, GitLabInstance instance) {
    final type = data['target_type'];
    final target = valueObject(data, 'target');
    final projectId = valueInt(valueObject(data, 'project'), 'id');
    final label = _todoTypeLabel(type);
    if (projectId > 0) {
      final iid = valueInt(target, 'iid');
      if ((type == 'Issue' || type == 'MergeRequest') && iid > 0) {
        final mr = type == 'MergeRequest';
        return _TodoTarget._(_TodoRoute.workItem, label, mr ? Icons.merge : Icons.adjust,
          projectId: projectId, resource: mr ? 'merge_requests' : 'issues', iid: iid, nativeType: true);
      }
      final sha = valueText(target, 'id');
      if (type == 'Commit' && _fullSha.hasMatch(sha)) {
        return _TodoTarget._(_TodoRoute.commit, label, Icons.commit,
          projectId: projectId, sha: sha.toLowerCase(), nativeType: true);
      }
    }
    final web = _todoWebUri(valueText(data, 'target_url'), instance);
    final nativeType = const ['Issue', 'MergeRequest', 'Commit'].contains(type);
    final link = web == null || nativeType
        ? null
        : GitLabLink.inApp(web, instance);
    if (link != null) {
      return _TodoTarget._(
        _TodoRoute.link,
        label,
        _linkIcon(link.target),
        web: web,
        link: link,
      );
    }
    return _TodoTarget._(
      _TodoRoute.explain,
      label,
      web == null ? Icons.link_off : Icons.open_in_new,
      web: web,
      nativeType: nativeType,
    );
  }

  static IconData _linkIcon(LinkTarget target) => switch (target) {
    LinkTarget.issue => Icons.adjust,
    LinkTarget.mergeRequest => Icons.merge,
    LinkTarget.pipeline => Icons.rocket_launch_outlined,
    LinkTarget.job => Icons.play_arrow_outlined,
    LinkTarget.commit => Icons.commit,
    LinkTarget.file => Icons.description_outlined,
    _ => Icons.category_outlined,
  };

  final _TodoRoute route;
  final String typeLabel;
  final IconData icon;
  final int projectId;
  final String resource;
  final int iid;
  final String sha;
  /// The server's `target_url`, kept only when it lies inside this instance.
  final Uri? web;

  /// The in-app resource [web] names, for [_TodoRoute.link] rows.
  final GitLabLink? link;
  final bool nativeType;

  static final _fullSha = RegExp(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$');
}

String _todoTypeLabel(Object? type) => switch (type) {
  'Issue' => l10n.issueTypeName,
  'MergeRequest' => l10n.mergeRequestLabel,
  'Commit' => l10n.commitLabel,
  'Epic' => l10n.epic,
  'WorkItem' => l10n.workItem,
  'DesignManagement::Design' => l10n.design,
  'AlertManagement::Alert' => l10n.alert,
  'Namespace' || 'Group' => l10n.groupLabel,
  'Project' => l10n.projectLabel,
  'Key' => l10n.sshKey,
  'User' => l10n.user,
  'WikiPage::Meta' => l10n.wikiPageLabel,
  _ => l10n.otherGitlabItem,
};

/// Accepts only an HTTPS link on this account's instance (host, port and
/// installation subpath) with no credentials, relative or encoded separators.
Uri? _todoWebUri(String text, GitLabInstance instance) {
  final value = text.trim();
  final rawPath = RegExp(r'^https://[^/?#]+([^?#]*)', caseSensitive: false).firstMatch(value)?.group(1);
  if (rawPath == null || rawPath.contains('\\') || rawPath.contains('//') ||
      RegExp(r'%(2f|5c|2e)', caseSensitive: false).hasMatch(rawPath) ||
      rawPath.split('/').any((part) => part == '.' || part == '..')) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !instance.sameOrigin(uri) || !safeExternalUri(uri)) return null;
  final base = instance.base.pathSegments.where((part) => part.isNotEmpty).toList();
  final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (segments.length <= base.length) return null;
  for (var i = 0; i < base.length; i++) {
    if (segments[i] != base[i]) return null;
  }
  return uri;
}

class _TodoTargetSheet extends StatelessWidget {
  const _TodoTargetSheet({required this.target, required this.title, required this.projectPath,
    required this.isCurrent});
  final _TodoTarget target;
  final String title;
  final String projectPath;
  final bool Function() isCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final web = target.web;
    final reason = target.nativeType
      ? l10n.todoTargetMissing(target.typeLabel)
      : l10n.todoTypeNoPage(target.typeLabel);
    return SafeArea(child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(web == null ? l10n.cannotOpenTodo : l10n.cannotOpenInApp, style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        Text(title, style: theme.textTheme.bodyLarge),
        if (projectPath.isNotEmpty) Text(projectPath, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        const SizedBox(height: 12),
        Text(reason),
        const SizedBox(height: 4),
        Text(web == null
          ? l10n.todoLinkWrongInstance
          : l10n.viewOnGitlabWebsiteInstead),
        if (web != null) ...[
          const SizedBox(height: 4),
          Text(web.toString(), key: const ValueKey('todo-target-web-url'),
            style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ],
        const SizedBox(height: 16),
        Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
          TextButton(key: const ValueKey('todo-target-close'),
            onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.closeAction)),
          if (web == null)
            OutlinedButton.icon(key: const ValueKey('todo-target-refresh'),
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.refresh), label: Text(l10n.refreshAction)),
          if (web != null)
            FilledButton.icon(key: const ValueKey('todo-target-open-web'),
              onPressed: () async {
                if (isCurrent()) await openExternal(context, web);
                if (context.mounted) Navigator.of(context).pop(false);
              },
              icon: const Icon(Icons.open_in_new), label: Text(l10n.openInGitlab)),
        ]),
      ]),
    ));
  }
}
