import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/merge_request_state.dart';
import '../../core/models.dart';
import '../../core/work_item_types.dart';
import '../../shared/external_link.dart';
import '../../shared/resource_share.dart';
import '../../shared/cache_freshness.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/markdown_view.dart';
import '../../shared/motion.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/skeleton.dart';
import '../../shared/workspace_ui.dart';
import 'ci_page.dart';
import 'diff_page.dart';
import 'editor.dart';
import 'comment_editor.dart';
import 'navigation.dart';
import 'picker_sheet.dart';
import 'reactions.dart';
import 'records_feed.dart';
import 'discussions_tab.dart';
import 'search_page.dart';
import 'draft_review_page.dart';
import 'work_item_filters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../auth/session_controller.dart';
import '../ai/ai_chat_page.dart';
import '../ai/ai_chat_session.dart';
import '../ai/ai_draft_target.dart';
import 'graph_work_items_page.dart';
import 'rest_issue_graph_bridge.dart';
import '../../shared/theme.dart';
import '../../l10n/l10n.dart';
export 'discussions_tab.dart';
export '../../core/merge_request_state.dart' show isAutoMergeEnabled, canAutoMerge;

class ProjectWorkItemsPage extends StatefulWidget {
  const ProjectWorkItemsPage({super.key, required this.account, required this.api, required this.project, required this.type}) : assert(type != ProjectWorkItemType.issue);

  final Account account;
  final GitLabApi api;
  final Project project;
  final ProjectWorkItemType type;

  @override
  State<ProjectWorkItemsPage> createState() => _ProjectWorkItemsPageState();
}

class _ProjectWorkItemsPageState extends State<ProjectWorkItemsPage> {
  final _focus = DetailFocus();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final titleStyle = theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge ?? const TextStyle(fontSize: 20);
    final pathStyle = theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12);
    double lineHeight(TextStyle style) => scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.2);
    final toolbarHeight = (lineHeight(titleStyle) + lineHeight(pathStyle) + 16).clamp(56.0, double.infinity).toDouble();
    return Scaffold(
      body: StatusBarInset(
      child: gestureSafe(
        Column(
          children: [
            if (!_focus.active)
              AppBar(
                primary: false,
                toolbarHeight: toolbarHeight,
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.type.listTitle),
                    Text(widget.project.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: pathStyle),
                  ],
                ),
              ),
            Expanded(
              child: DetailFocusScope(
                focus: _focus,
                child: WorkItemsTab(account: widget.account, api: widget.api, project: widget.project, resource: 'issues', type: widget.type),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class WorkItemsTab extends StatefulWidget {
  const WorkItemsTab({super.key, required this.account, required this.api, required this.project, required this.resource, this.type = ProjectWorkItemType.issue}) : assert(resource == 'issues' || type == ProjectWorkItemType.issue);
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  final ProjectWorkItemType type;
  @override
  State<WorkItemsTab> createState() => _WorkItemsTabState();
}

class _WorkItemsTabState extends State<WorkItemsTab> {
  late final _selection = ListDetailController<int>();
  final _feed = GlobalKey<RecordsFeedState>();
  final _search = TextEditingController();
  String _state = 'opened', _query = '';
  WorkItemFilters _filters = const WorkItemFilters();
  final Set<Route<dynamic>> _ownedRoutes = {};
  NavigatorState? _navigator;
  int _generation = 0;
  bool get mr => widget.resource == 'merge_requests';
  ProjectWorkItemType get type => mr ? ProjectWorkItemType.issue : widget.type;
  String get itemTitle => mr ? l10n.mergeRequestLabel : type.title;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissRoutes() {
    final navigator = _navigator;
    final routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator == null || !navigator.mounted) return;
      for (final route in routes) {
        if (!route.isActive) continue;
        navigator.popUntil((candidate) => candidate == route || candidate.isFirst);
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  bool _currentOwner(int generation, Account account, GitLabApi api, Project project, String resource, ProjectWorkItemType ownerType) => mounted && generation == _generation && widget.account.key == account.key && identical(widget.api, api) && widget.project.id == project.id && widget.resource == resource && type == ownerType;

  @override
  void didUpdateWidget(covariant WorkItemsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key || oldWidget.project.id != widget.project.id || oldWidget.resource != widget.resource || oldWidget.type != widget.type || !identical(oldWidget.api, widget.api)) {
      _generation++;
      _dismissRoutes();
      _selection.clear();
      _search.clear();
      _state = 'opened';
      _query = '';
      _filters = const WorkItemFilters();
    }
  }

  @override
  void dispose() {
    _generation++;
    _dismissRoutes();
    _search.dispose();
    _selection.dispose();
    super.dispose();
  }

  void _open(int iid) {
    _selection.select(iid);
  }

  void _applyMutation(Json updated) {
    final state = valueText(updated, 'state');
    final matchesType = mr || workItemTypeFromJson(updated) == type;
    final matchesFilter = matchesType && (_state == 'all' || _state == state) && _filters.matches(updated, userId: widget.account.user.id, mergeRequest: mr, search: _query);
    if (matchesFilter) {
      _feed.currentState?.patchItem(updated);
    } else {
      _feed.currentState?.removeItem('${updated['id'] ?? updated['iid']}');
    }
    // Edits can change updated_at/due_date and the pagination boundary. Let
    // the server restore the selected order after immediate row feedback.
    unawaited(_feed.currentState?.reconcileLoadedWindow() ?? Future<void>.value());
  }

  Future<void> _create() async {
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final resource = widget.resource;
    final ownerType = type;
    final generation = _generation;
    var iid = 0;
    Json? createdRecord;
    var writePending = false;
    final branch = project.defaultBranch ?? 'main';
    final fields = <EditField>[
      EditField('title', l10n.title, required: true),
      if (mr) ...[EditField.picker('source_branch', l10n.sourceBranch, source: PickerSource.branches, required: true), EditField.picker('target_branch', l10n.targetBranch, source: PickerSource.branches, required: true, value: _branchValue(branch))],
      EditField('description', l10n.descriptionLabel, lines: 7, hint: l10n.markdownSupported, markdown: true),
      if (!mr && ownerType == ProjectWorkItemType.incident) EditField.choice('severity', l10n.severity, required: true, value: 'unknown', choices: [EditChoice('unknown', l10n.severityUnclassified), EditChoice('low', l10n.severityLow), EditChoice('medium', l10n.severityMedium), EditChoice('high', l10n.severityHigh), EditChoice('critical', l10n.severityCritical)]),
      EditField.picker('labels', l10n.labelNoun, source: PickerSource.labels, multi: true, hint: l10n.namesCreatedOnSave),
      EditField.picker('assignee_ids', l10n.assignee, source: PickerSource.members, multi: true),
      if (mr) EditField.picker('reviewer_ids', l10n.reviewers, source: PickerSource.members, multi: true),
      EditField.picker('milestone_id', l10n.milestoneLabel, source: PickerSource.milestones, multi: false, hint: l10n.optionalMilestone),
      if (!mr) EditField.toggle('confidential', l10n.confidentialIssue, hint: l10n.confidentialIssueVisibility),
    ];
    final saved = await openEditor(
      context,
      account: account,
      api: api,
      projectId: project.id,
      projectPath: project.path,
      title: mr ? l10n.newMergeRequest : ownerType.createTitle,
      resource: mr || ownerType == ProjectWorkItemType.issue
          ? '${project.id}/$resource/new'
          : '${project.id}/$resource/${ownerType.apiValue}/new',
      subtitle: project.path,
      fields: fields,
      onRoute: _ownRoute,
      save: (values) async {
        if (!_currentOwner(generation, account, api, project, resource, ownerType)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        if (writePending) throw const ApiFailure(FailureKind.writeUncertain);
        final body = editorSubmission(fields, values);
        final title = body['title'];
        if (title is String) body['title'] = title.trim();
        if (body['milestone_id'] == null) {
          body.remove('milestone_id');
        }
        if (!mr) body['issue_type'] = ownerType.apiValue;
        writePending = true;
        late final Json created;
        try {
          created = mr ? await api.createMergeRequest(project.id, body) : await api.createIssue(project.id, body);
        } on ApiFailure catch (failure) {
          if (failure.kind != FailureKind.writeUncertain) writePending = false;
          rethrow;
        }
        if (!_currentOwner(generation, account, api, project, resource, ownerType)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        try {
          if (mr) {
            if (requiredInt(created, 'project_id') != project.id) {
              throw const FormatException();
            }
          } else {
            validateWorkItemIdentity(created, expectedType: ownerType, expectedProjectId: project.id);
          }
          iid = requiredInt(created, 'iid');
        } on ApiFailure {
          throw const ApiFailure(FailureKind.writeUncertain);
        } on FormatException {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        createdRecord = created;
      },
    );
    if (saved && _currentOwner(generation, account, api, project, resource, ownerType)) {
      final created = createdRecord;
      final matches = created != null && (_state == 'all' || _state == 'opened') && _filters.matches(created,
        userId: widget.account.user.id, mergeRequest: mr, search: _query);
      if (matches && _filters.canPrependCreated) {
        _feed.currentState?.prependItem(createdRecord!);
        unawaited(_feed.currentState?.reconcileLoadedWindow() ?? Future<void>.value());
      } else if (matches || created == null) {
        unawaited(_feed.currentState?.reconcileLoadedWindow() ?? Future<void>.value());
      }
      _open(iid);
    }
  }

  Widget _buildList(BuildContext context, bool isTwoPane, int? selected) {
    final filterQuery = _filters.toQuery(mergeRequest: mr);
    return RecordsFeed(
      key: _feed,
      identity: '${widget.account.key}/${widget.project.id}/${widget.resource}/${type.apiValue}/$_state/$_query/${_filters.identity(mergeRequest: mr)}/$_generation',
      storageId: '${widget.resource}/${type.apiValue}/${widget.account.key}/${widget.project.id}',
      account: widget.account,
      resourceLabel: '${widget.project.path} · $itemTitle',
      onSwitchAccount: endSessionFrom(context),
      empty: mr ? l10n.noMatchingMergeRequests : type.emptyLabel,
      emptyIcon: mr
          ? Icons.merge
          : switch (type) {
              ProjectWorkItemType.issue => Icons.adjust,
              ProjectWorkItemType.task => Icons.task_alt,
              ProjectWorkItemType.incident => Icons.warning_amber_rounded,
            },
      leading: (context, _) => _listControls(context),
      load: (next) async {
        final page = await widget.api.records(['projects', '${widget.project.id}', widget.resource], query: {...filterQuery, 'state': _state, 'with_labels_details': 'true', if (!mr) 'issue_type': type.apiValue, if (_query.isNotEmpty) 'search': _query}, next: next);
        if (!mr) {
          for (final item in page.items) {
            validateWorkItemIdentity(item, expectedType: type, expectedProjectId: widget.project.id);
          }
        }
        return page;
      },
      itemBuilder: (context, value) {
        final iid = requiredInt(value, 'iid');
        return workItemCard(context, value, mr: mr, selected: isTwoPane && selected == iid, onTap: () => _open(iid));
      },
    );
  }

  Future<void> _openFilters() async {
    final generation = _generation;
    final account = widget.account, api = widget.api, project = widget.project;
    final resource = widget.resource, ownerType = type;
    final selected = await showWorkItemFilters(context, api: widget.api, account: widget.account, projectId: widget.project.id, mergeRequest: mr, initial: _filters, onRoute: _ownRoute);
    if (selected == null || !_currentOwner(generation, account, api, project, resource, ownerType)) return;
    final query = _search.text.trim();
    if (selected == _filters && query == _query) return;
    setState(() {
      _filters = selected;
      _query = query;
    });
  }

  Widget _listControls(BuildContext context) => Column(
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(feedGutter(context), 12, feedGutter(context) - 4, 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('work-items-search'),
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: mr ? l10n.searchMergeRequests : type.searchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _search,
                    builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                key: const ValueKey('clear-work-items-search'),
                icon: const Icon(Icons.clear, size: 20),
                onPressed: () {
                  _search.clear();
                  if (_query.isNotEmpty) setState(() => _query = '');
                },
              );
            },
                  ),
                ),
                onSubmitted: (value) {
          final query = value.trim();
          if (query != _query) setState(() => _query = query);
        },
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: l10n.filterAndSort,
              onPressed: _openFilters,
              icon: _filters.activeCount(mergeRequest: mr) == 0
                  ? const Icon(Icons.tune)
                  : Badge.count(
                      count: _filters.activeCount(mergeRequest: mr),
                      child: const Icon(Icons.tune),
                    ),
            ),
            IconButton(tooltip: mr ? l10n.newMergeRequest : type.createTitle, onPressed: widget.project.archived == true ? null : _create, icon: const Icon(Icons.add_circle_outline)),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: feedGutter(context), vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final e in {'opened': l10n.statusOpen, 'closed': l10n.statusClosed, 'all': l10n.filterAll}.entries) ChoiceChip(label: Text(e.value), selected: _state == e.key, showCheckmark: false, onSelected: (_) => setState(() => _state = e.key)),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _buildDetail(BuildContext context, int iid, bool isTwoPane, VoidCallback onBack) => WorkItemPage(
    key: ValueKey('${widget.resource}-$iid'),
    account: widget.account,
    api: widget.api,
    project: widget.project,
    resource: widget.resource,
    type: type,
    iid: iid,
    showBackButton: !isTwoPane,
    onBack: onBack,
    onDeleted: () {
      _selection.clear();
      _feed.currentState?.removeItem('$iid');
      unawaited(_feed.currentState?.reconcileLoadedWindow() ?? Future<void>.value());
    },
    onMutated: _applyMutation,
  );

  Widget _buildEmpty(BuildContext context) => Center(
    child: EmptyState(
      mr ? l10n.selectMergeRequest : l10n.selectTypedItem(type.title),
      icon: mr
          ? Icons.merge
          : switch (type) {
              ProjectWorkItemType.issue => Icons.adjust,
              ProjectWorkItemType.task => Icons.task_alt,
              ProjectWorkItemType.incident => Icons.warning_amber_rounded,
            },
      detail: mr ? l10n.selectMergeRequestHint : type.selectionHint,
    ),
  );

  @override
  Widget build(BuildContext context) => ListDetailScaffold<int>(controller: _selection, listBuilder: _buildList, detailBuilder: _buildDetail, emptyBuilder: _buildEmpty, twoPaneConsumesBack: true);
}

/// Shared issue / merge-request row: state-tinted mark, title, then a meta row
/// with the status badge, the mono `#iid`, the author, branches for MRs and the
/// update time.
Widget workItemCard(
  BuildContext context,
  Json value, {
  required bool mr,
  required VoidCallback onTap,
  String? project,
  bool selected = false,
}) {
  final state = valueText(value, 'state');
  final source = valueText(value, 'source_branch'), target = valueText(value, 'target_branch');
  final pipeline = valueText(valueObject(value, 'head_pipeline'), 'status');
  final iid = '${mr ? '!' : '#'}${valueInt(value, 'iid')}';
  final isConfidential = valueBool(value, 'confidential');
  final milestone = valueObject(value, 'milestone');
  final milestoneTitle = valueText(milestone, 'title');
  final labels = labelDetails(value);
  final assignees = valueObjects(value, 'assignees');
  final author = valueObject(value, 'author');
  final notes = valueInt(value, 'user_notes_count');
  final upvotes = valueInt(value, 'upvotes');
  final tasks = valueObject(value, 'task_completion_status');
  final taskCount = valueInt(tasks, 'count');
  final due = valueText(value, 'due_date');
  final branch = mr && source.isNotEmpty && target.isNotEmpty
      ? MetaChip('$source → $target', icon: Icons.call_split, mono: true)
      : null;
  final labelRow = labels.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [
    for (final label in labels.take(6)) LabelPill(label.name, color: label.color, textColor: label.textColor),
    if (labels.length > 6) MetaChip('+${labels.length - 6}'),
  ]);
  return EntityCard(
    onTap: onTap,
    selected: selected,
    titleMaxLines: 3,
    title: Text(isolated(valueText(value, 'title'))),
    subtitle: project == null || project.isEmpty ? null : Text(project),
    body: branch == null && labelRow == null ? null : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ?branch,
      if (branch != null && labelRow != null) const SizedBox(height: 6),
      ?labelRow,
    ]),
    meta: [
      StatusBadge(state),
      if (mr && value['draft'] == true) MetaChip(l10n.draft, icon: Icons.edit_note),
      if (isConfidential)
        MetaChip(l10n.confidential, icon: Icons.lock_outline),
      if (milestoneTitle.isNotEmpty)
        MetaChip(milestoneTitle, icon: Icons.tour_outlined),
      if (mr && pipeline.isNotEmpty) StatusBadge(pipeline),
      if (mr && isAutoMergeEnabled(value))
        MetaChip(l10n.autoMerge, icon: Icons.schedule_send),
      if (mr && value['has_conflicts'] == true) MetaChip(l10n.conflict, icon: Icons.warning_amber_rounded),
      MetaChip(iid, mono: true),
      ?PersonChip.of(author),
      if (taskCount > 0) MetaChip('${valueInt(tasks, 'completed_count')}/$taskCount', icon: Icons.checklist),
      if (due.isNotEmpty) MetaChip(l10n.dueOn2(due), icon: Icons.event_outlined),
      if (notes > 0) MetaChip('$notes', icon: Icons.chat_bubble_outline),
      if (upvotes > 0) MetaChip('$upvotes', icon: Icons.thumb_up_outlined),
      MetaChip(relativeDate(valueText(value, 'updated_at')), icon: Icons.schedule_outlined),
      if (assignees.isNotEmpty) PeopleStack(assignees),
    ],
  );
}

class WorkItemPage extends StatefulWidget {
  const WorkItemPage({super.key, required this.account, required this.api, required this.project, required this.resource, required this.iid, this.type = ProjectWorkItemType.issue, this.showBackButton = true, this.onBack, this.onDeleted, this.onMutated}) : assert(resource == 'issues' || type == ProjectWorkItemType.issue);
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  final int iid;
  final ProjectWorkItemType type;
  final bool showBackButton;
  final VoidCallback? onBack;
  final VoidCallback? onDeleted;
  final ValueChanged<Json>? onMutated;
  @override
  State<WorkItemPage> createState() => WorkItemPageState();
}

/// Thread-class freshness for the approvals, related-MR and link reads below.
const _threadMaxAge = Duration(seconds: 30);

class WorkItemPageState extends State<WorkItemPage> with SingleTickerProviderStateMixin {
  Json? _data;
  Json? _approvalsData;
  int _relatedRevision = 0;
  IncidentStatusSnapshot? _incidentStatus;
  ApiFailure? _incidentStatusError;
  ApiFailure? _error;
  bool _loading = true, _busy = false;
  int _epoch = 0, _generation = 0, _readEpoch = 0;
  int _graphEpoch = 0, _graphReadyEpoch = 0;
  final _chrome = ScrollChromeController();
  final Set<Route<dynamic>> _ownedRoutes = {};
  NavigatorState? _navigator;
  late TabController _tabs = _newTabs();
  ValueListenable<TickerModeData>? _tickerMode;
  bool _backgroundEnabled = true, _resumeWhenVisible = false;
  bool _stale = false, _revalidating = false;
  FailureKind? _backgroundFailure;
  DateTime? _backgroundRetryAt;
  CachedRead<Json>? _detailRead;
  Json? get data => _data;
  ApiFailure? get readError => _error;
  DateTime? get fetchedAt => _detailRead?.fetchedAt;
  bool get stale => _stale;
  bool get revalidating => _revalidating;
  FailureKind? get backgroundFailure => _backgroundFailure;
  DateTime? get backgroundRetryAt => _backgroundRetryAt;

  // Metadata shown from an earlier read: say so while it is refreshed in the
  // background or after that refresh failed. Fresh data gets no strip.
  DateTime? get _freshnessAt => _data == null || _loading || _error != null ||
      !(_stale || _revalidating || _backgroundFailure != null) ? null : fetchedAt;
  bool get mr => widget.resource == 'merge_requests';
  ProjectWorkItemType get type => mr ? ProjectWorkItemType.issue : widget.type;
  List<String> get path => ['projects', '${widget.project.id}', widget.resource, '${widget.iid}'];
  String get label => '${mr ? '!' : '#'}${widget.iid}';
  Uri get web => widget.account.instance.projectWeb('${widget.project.path}/-/${widget.resource}/${widget.iid}');
  TabController _newTabs() => TabController(length: mr ? 4 : 2, vsync: this)..addListener(_chrome.show);

  @override
  void initState() { super.initState(); unawaited(_load()); }

  Future<void> _openAi({required bool summarize}) async {
    final data = _data;
    if (data == null) return;
    final owner = _owner;
    SessionController? session;
    int? sessionGeneration;
    try {
      session = ProviderScope.containerOf(context, listen: false).read(sessionProvider);
      sessionGeneration = captureRouteSessionGeneration(injected: null,
        owner: session, account: owner.account, api: owner.api,
        isCurrent: () => _currentOwner(owner) && !owner.api.isClosed);
    } catch (_) {
      session = null;
    }
    bool current() => _currentOwner(owner) && !owner.api.isClosed &&
        session != null &&
        routeSessionMatches(sessionGeneration, session, owner.account, owner.api);
    await openAiChat(context, AiWorkItemOrigin(
      project: owner.project,
      kind: mr ? AiWorkItemKind.mergeRequest : AiWorkItemKind.issue,
      iid: owner.iid,
      title: valueText(data, 'title'),
      summarize: summarize && mr,
    ), draftTarget: current() ? AiDraftTarget(
      existingText: () => readCommentDraft(
        owner.account, owner.project, owner.resource, owner.iid),
      // Read when the answer is appended, not when the chat opened: a chat
      // kept from an earlier visit must see the item as it is now.
      confidential: () =>
          !mr && _currentOwner(owner) && _data?['confidential'] == true,
      insert: (text) async {
        if (!current()) return;
        final saved = await openCommentEditor(context,
          account: owner.account, api: owner.api, project: owner.project,
          resource: owner.resource, iid: owner.iid, appendBody: text,
          isCurrent: current, onRoute: _ownRoute);
        if (saved && current()) {
          _tabs.animateTo(owner.resource == 'merge_requests' ? 2 : 1);
          await _loadAfterMutation();
        }
      },
    ) : null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
    _updateTickerMode();
  }

  void _updateTickerMode() {
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_tickerModeChanged);
      _tickerMode = mode;
      mode.addListener(_tickerModeChanged);
    }
    _tickerModeChanged();
  }

  void _tickerModeChanged() {
    _backgroundEnabled = _tickerMode!.value.enabled;
    if (!_backgroundEnabled && _revalidating) _resumeWhenVisible = true;
    if (_backgroundEnabled) _startRevalidation(_generation);
  }

  bool _readCurrent(int generation, int readEpoch) =>
      mounted &&
      generation == _generation &&
      readEpoch == _readEpoch &&
      !widget.api.isClosed;

  bool _canApplyRead(int generation, int readEpoch, {required bool background}) {
    if (!_readCurrent(generation, readEpoch)) return false;
    if (background && !_backgroundEnabled) {
      _stale = true;
      _resumeWhenVisible = true;
      return false;
    }
    return true;
  }

  bool _revoked(ApiFailure failure) => switch (failure.kind) {
    FailureKind.unauthenticated ||
    FailureKind.forbidden ||
    FailureKind.invisible => true,
    _ => false,
  };

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissRoutes() {
    final navigator = _navigator;
    final routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator == null || !navigator.mounted) return;
      for (final route in routes) {
        if (!route.isActive) continue;
        navigator.popUntil((candidate) => candidate == route || candidate.isFirst);
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  ({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) get _owner => (account: widget.account, api: widget.api, project: widget.project, resource: widget.resource, iid: widget.iid, type: type, generation: _generation);

  bool _currentOwner(({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) owner) => mounted && owner.generation == _generation && widget.account.key == owner.account.key && identical(widget.api, owner.api) && widget.project.id == owner.project.id && widget.resource == owner.resource && widget.iid == owner.iid && type == owner.type;

  List<String> _ownerPath(({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) owner) => ['projects', '${owner.project.id}', owner.resource, '${owner.iid}'];

  Future<Json> _updateOwner(({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) owner, Json fields) =>
    owner.resource == 'merge_requests'
      ? owner.api.updateMergeRequest(owner.project.id, owner.iid, fields)
      : owner.api.updateIssue(owner.project.id, owner.iid, fields);

  @override
  void didUpdateWidget(covariant WorkItemPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.account.key != widget.account.key || oldWidget.project.id != widget.project.id || oldWidget.resource != widget.resource || oldWidget.iid != widget.iid || oldWidget.type != widget.type || !identical(oldWidget.api, widget.api);
    if (!changed) return;
    final oldMr = oldWidget.resource == 'merge_requests';
    _generation++;
    _epoch++;
    _readEpoch++;
    _dismissRoutes();
    _withdraw();
    _incidentStatus = null;
    _incidentStatusError = null;
    _error = null;
    _busy = false;
    _loading = true;
    _backgroundFailure = null;
    _backgroundRetryAt = null;
    _resumeWhenVisible = false;
    if (oldMr != mr) {
      _tabs.dispose();
      _tabs = _newTabs();
    } else {
      _tabs.index = 0;
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _epoch++;
    _readEpoch++;
    _dismissRoutes();
    _tickerMode?.removeListener(_tickerModeChanged);
    _tabs.dispose();
    _chrome.dispose();
    super.dispose();
  }

  Future<CachedRead<Json>?> _readDetail(
    ({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) owner,
    int generation, {
    required int readEpoch,
    required List<String> ownerPath,
    required bool fresh,
    required bool background,
  }) async {
    Future<CachedRead<Json>> readPage(bool force, {bool quiet = false}) => CachedRead.run(
      () => owner.api.cachedRecord(ownerPath, fresh: force, background: background),
      mayStart: () => _readCurrent(generation, readEpoch) &&
          (!background || _backgroundEnabled),
      waitForQuiet: quiet,
    );
    var read = await readPage(fresh);
    if (!_canApplyRead(generation, readEpoch, background: background)) return null;
    if (read.superseded) {
      read = await readPage(true);
      if (!_canApplyRead(generation, readEpoch, background: background)) return null;
      if (read.superseded) {
        read = await readPage(true, quiet: true);
        if (!_canApplyRead(generation, readEpoch, background: background)) return null;
      }
      if (read.superseded) throw const ApiFailure(FailureKind.cancelled);
    }
    return read.dropped ? null : read;
  }

  /// Approvals share the detail read's bounded-retry shape (two superseded
  /// reads → one quiet-wait read → retryable failure) so a superseded
  /// approvals read is retried, never silently swallowed. Reads older than
  /// the thread freshness window go to the network via [maxAge].
  Future<CachedRead<Json>?> _readApprovals(
    ({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) owner,
    int generation, {
    required int readEpoch,
    required List<String> ownerPath,
    required bool fresh,
  }) async {
    Future<CachedRead<Json>> readPage(bool force, {bool quiet = false}) => CachedRead.run(
      () => owner.api.cachedRecord([...ownerPath, 'approvals'], fresh: force, maxAge: _threadMaxAge),
      mayStart: () => _readCurrent(generation, readEpoch),
      waitForQuiet: quiet,
    );
    var read = await readPage(fresh);
    if (!_readCurrent(generation, readEpoch)) return null;
    if (read.superseded) {
      read = await readPage(true);
      if (!_readCurrent(generation, readEpoch)) return null;
      if (read.superseded) {
        read = await readPage(true, quiet: true);
        if (!_readCurrent(generation, readEpoch)) return null;
      }
      if (read.superseded) throw const ApiFailure(FailureKind.cancelled);
    }
    return read.dropped ? null : read;
  }

  void _withdraw() {
    _data = null;
    _approvalsData = null;
    _detailRead = null;
    _stale = false;
  }

  void _failedDetail(ApiFailure failure, {required bool background}) {
    if (failure.kind == FailureKind.unauthenticated) {
      _withdraw();
      _error = failure;
      _incidentStatus = null;
      _incidentStatusError = null;
    } else if (!_revoked(failure)) {
      if (background) {
        _backgroundFailure = failure.kind;
        _backgroundRetryAt = failure.retryAt;
      } else {
        _error = failure;
      }
    } else {
      _withdraw();
      _error = failure;
    }
  }

  Future<void> _load({bool fresh = false}) async {
    final owner = _owner;
    final ownerPath = _ownerPath(owner);
    final generation = _generation;
    ++_epoch;
    final readEpoch = ++_readEpoch;
    final graphEpoch = ++_graphEpoch;
    if (fresh) _relatedRevision++;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _revalidating = false;
        _backgroundFailure = null;
        _backgroundRetryAt = null;
        _resumeWhenVisible = false;
      });
    }
    try {
      final read = await _readDetail(owner, generation, readEpoch: readEpoch, ownerPath: ownerPath, fresh: fresh, background: false);
      if (!_readCurrent(generation, readEpoch)) return;
      if (read == null) {
        if (_data == null) {
          setState(() => _error = const ApiFailure(FailureKind.cancelled));
        }
        return;
      }
      if (owner.resource != 'merge_requests') {
        validateWorkItemIdentity(read.value, expectedType: owner.type, expectedProjectId: owner.project.id);
      }
      Json? approvals;
      bool clearApprovals = false;
      IncidentStatusSnapshot? incidentStatus;
      ApiFailure? incidentStatusError;
      if (owner.resource == 'merge_requests') {
        try {
          final approvalsRead = await _readApprovals(owner, generation, readEpoch: readEpoch, ownerPath: ownerPath, fresh: fresh);
          if (!_readCurrent(generation, readEpoch)) return;
          if (approvalsRead != null) approvals = approvalsRead.value;
        } on ApiFailure catch (failure) {
          if (!_readCurrent(generation, readEpoch)) return;
          if (failure.kind == FailureKind.unauthenticated) {
            setState(() => _failedDetail(failure, background: false));
            return;
          }
          if (_revoked(failure)) {
            // A revoked approvals read withdraws the approvals part only;
            // the parent detail stays on screen.
            clearApprovals = true;
          }
          // Other failures (including a bounded-retry-exhausted superseded
          // read) keep the previous approvals value: fail-soft.
        }
      } else if (owner.type == ProjectWorkItemType.incident) {
        try {
          final raw = await owner.api.incidentStatus(owner.project, owner.iid);
          if (!_readCurrent(generation, readEpoch)) return;
          incidentStatus = IncidentStatusSnapshot.fromJson(raw, expectedProjectId: owner.project.id, expectedIid: owner.iid);
        } catch (error) {
          if (!_readCurrent(generation, readEpoch)) return;
          incidentStatusError = safeFailure(error);
        }
      }
      if (!_readCurrent(generation, readEpoch)) return;
      setState(() {
        _data = read.value;
        _detailRead = read;
        _stale = read.stale;
        if (clearApprovals) {
          _approvalsData = null;
        } else if (approvals != null) {
          _approvalsData = approvals;
        }
        _incidentStatus = incidentStatus;
        _incidentStatusError = incidentStatusError;
        _graphReadyEpoch = graphEpoch;
        _loading = false;
      });
      _startRevalidation(generation, readEpoch: readEpoch);
    } catch (e) {
      if (_readCurrent(generation, readEpoch)) {
        final failure = safeFailure(e);
        setState(() => _failedDetail(failure, background: false));
      }
    } finally {
      if (_readCurrent(generation, readEpoch) && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  void _startRevalidation(int generation, {int? readEpoch}) {
    final epoch = readEpoch ?? _readEpoch;
    if (!_readCurrent(generation, epoch) ||
        !_backgroundEnabled ||
        !_stale ||
        _loading ||
        _revalidating ||
        _backgroundFailure != null ||
        _error != null) {
      return;
    }
    setState(() {
      _revalidating = true;
      _resumeWhenVisible = false;
    });
    unawaited(_revalidate(_owner, generation, epoch));
  }

  Future<void> _revalidate(
    ({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) owner,
    int generation,
    int readEpoch,
  ) async {
    try {
      if (_detailRead?.stale != true) return;
      final ownerPath = _ownerPath(owner);
      final read = await _readDetail(owner, generation, readEpoch: readEpoch, ownerPath: ownerPath, fresh: true, background: true);
      if (_canApplyRead(generation, readEpoch, background: true) && read != null) {
        if (owner.resource != 'merge_requests') {
          validateWorkItemIdentity(read.value, expectedType: owner.type, expectedProjectId: owner.project.id);
        }
        setState(() {
          _data = read.value;
          _detailRead = read;
          _stale = read.stale;
        });
      }
    } catch (e) {
      if (!_readCurrent(generation, readEpoch)) return;
      final failure = safeFailure(e);
      if (!_revoked(failure) && !_canApplyRead(generation, readEpoch, background: true)) return;
      setState(() {
        if (_revoked(failure)) {
          _failedDetail(failure, background: true);
        } else {
          _backgroundFailure = failure.kind;
          _backgroundRetryAt = failure.retryAt;
        }
      });
    } finally {
      if (_readCurrent(generation, readEpoch)) {
        setState(() => _revalidating = false);
        if (_resumeWhenVisible && _backgroundEnabled) {
          _startRevalidation(generation, readEpoch: readEpoch);
        }
      }
    }
  }

  Future<void> _onOpenEditor() async {
    final oldOwner = _owner;
    SessionController? session;
    int? capturedSessionGeneration;
    try {
      session = ProviderScope.containerOf(context, listen: false).read(sessionProvider);
      capturedSessionGeneration = captureRouteSessionGeneration(
        injected: null,
        owner: session,
        account: oldOwner.account,
        api: oldOwner.api,
        isCurrent: () => _currentOwner(oldOwner) && !oldOwner.api.isClosed,
      );
    } catch (_) {
      session = null;
      capturedSessionGeneration = null;
    }

    if (!context.mounted) return;

    final route = MaterialPageRoute<void>(
      builder: (_) => GraphWorkItemDetailPage.project(
        account: oldOwner.account,
        api: oldOwner.api,
        project: oldOwner.project,
        iid: oldOwner.iid,
        isCurrent: () => _currentOwner(oldOwner) && !oldOwner.api.isClosed,
        ownerChanges: session,
        sessionGeneration: capturedSessionGeneration,
      ),
    );
    _ownRoute(route);

    await Navigator.of(context).push(route);

    if (!_currentOwner(oldOwner) || oldOwner.api.isClosed) return;
    if (capturedSessionGeneration != null &&
        !routeSessionMatches(capturedSessionGeneration, session, oldOwner.account, oldOwner.api)) {
      return;
    }
    unawaited(_load(fresh: true));
  }

  Future<void> _loadAfterMutation() async {
    final expectedEpoch = _epoch + 1;
    await _load(fresh: true);
    if (mounted && _epoch == expectedEpoch && _error == null && _data != null) {
      widget.onMutated?.call(_data!);
    }
  }

  Future<void> _edit() async {
    final data = _data;
    if (data == null || _busy) { return; }
    final owner = _owner;
    final ownerPath = _ownerPath(owner);
    final fields = <EditField>[
      EditField('title', l10n.title, required: true, value: valueText(data, 'title')),
      EditField('description', l10n.descriptionLabel, lines: 8, markdown: true, value: valueText(data, 'description')),
      if (owner.type == ProjectWorkItemType.incident) EditField.choice('severity', l10n.severity, required: true, value: incidentSeverityFromJson(data)?.apiValue ?? valueText(data, 'severity'), choices: [EditChoice('unknown', l10n.severityUnclassified), EditChoice('low', l10n.severityLow), EditChoice('medium', l10n.severityMedium), EditChoice('high', l10n.severityHigh), EditChoice('critical', l10n.severityCritical)]),
      EditField.picker('labels', l10n.labelNoun, source: PickerSource.labels, multi: true, value: _labelsValue(data), hint: l10n.blankRemovesLabels),
      EditField.picker('assignee_ids', l10n.assignee, source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'assignees'))),
      if (mr) EditField.picker('reviewer_ids', l10n.reviewers, source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'reviewers'))),
      EditField.picker('milestone_id', l10n.milestoneLabel, source: PickerSource.milestones, multi: false, value: _milestoneValue(data), hint: l10n.blankRemovesMilestone),
      if (!mr) EditField.toggle('confidential', l10n.confidentialIssue, value: valueBool(data, 'confidential') ? 'true' : 'false', hint: l10n.confidentialIssueVisibility),
    ];
    final saved = await openEditor(
      context,
      account: owner.account,
      api: owner.api,
      projectId: owner.project.id,
      projectPath: owner.project.path,
      title: l10n.editItemReference('${owner.resource == 'merge_requests' ? '!' : '#'}${owner.iid}'),
      resource: owner.resource == 'merge_requests' || owner.type == ProjectWorkItemType.issue
          ? '${owner.project.id}/${owner.resource}/${owner.iid}/edit'
          : '${owner.project.id}/${owner.resource}/${owner.type.apiValue}/${owner.iid}/edit',
      subtitle: owner.project.path,
      baseRevision: valueText(data, 'updated_at'),
      fields: fields,
      onRoute: _ownRoute,
      save: (values) async {
        if (!_currentOwner(owner)) throw const ApiFailure(FailureKind.cancelled);
        final current = await owner.api.record(ownerPath);
        if (!_currentOwner(owner)) throw const ApiFailure(FailureKind.cancelled);
        if (current['updated_at'] != data['updated_at']) { throw const ApiFailure(FailureKind.conflict); }
        final body = editorSubmission(fields, values);
        final title = body['title'];
        if (title is String) body['title'] = title.trim();
        if (!body.containsKey('milestone_id') || body['milestone_id'] == null) {
          body['milestone_id'] = 0;
        }
        body.remove('issue_type');
        await _updateOwner(owner, body);
      },
    );
    if (saved && _currentOwner(owner)) {
      await _loadAfterMutation();
    }
  }

  Future<void> _editAssignees() async {
    final data = _data;
    if (data == null || _busy) { return; }
    final owner = _owner;
    final ownerPath = _ownerPath(owner);
    final field = EditField.picker('assignee_ids', l10n.assigneeMembers, source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'assignees')), hint: l10n.blankRemovesAssignees);
    final saved = await openEditor(
      context,
      account: owner.account,
      api: owner.api,
      projectId: owner.project.id,
      projectPath: owner.project.path,
      title: l10n.editAssigneesReference('${owner.resource == 'merge_requests' ? '!' : '#'}${owner.iid}'),
      resource: owner.resource == 'merge_requests' || owner.type == ProjectWorkItemType.issue
          ? '${owner.project.id}/${owner.resource}/${owner.iid}/assignees'
          : '${owner.project.id}/${owner.resource}/${owner.type.apiValue}/${owner.iid}/assignees',
      subtitle: owner.project.path,
      baseRevision: valueText(data, 'updated_at'),
      fields: [field],
      onRoute: _ownRoute,
      save: (values) async {
        if (!_currentOwner(owner)) throw const ApiFailure(FailureKind.cancelled);
        final current = await owner.api.record(ownerPath);
        if (!_currentOwner(owner)) throw const ApiFailure(FailureKind.cancelled);
        if (current['updated_at'] != data['updated_at']) {
          throw const ApiFailure(FailureKind.conflict);
        }
        final body = editorSubmission([field], values);
        await _updateOwner(owner, body);
      },
    );
    if (saved && _currentOwner(owner)) {
      await _loadAfterMutation();
    }
  }

  Future<void> _editReviewers() async {
    final data = _data;
    if (data == null || _busy || !mr) { return; }
    final owner = _owner;
    final ownerPath = _ownerPath(owner);
    final field = EditField.picker('reviewer_ids', l10n.reviewerList, source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'reviewers')), hint: l10n.blankRemovesReviewers);
    final saved = await openEditor(
      context,
      account: owner.account,
      api: owner.api,
      projectId: owner.project.id,
      projectPath: owner.project.path,
      title: l10n.editReviewersReference(owner.iid),
      resource: '${owner.project.id}/${owner.resource}/${owner.iid}/reviewers',
      subtitle: owner.project.path,
      baseRevision: valueText(data, 'updated_at'),
      fields: [field],
      onRoute: _ownRoute,
      save: (values) async {
        if (!_currentOwner(owner)) throw const ApiFailure(FailureKind.cancelled);
        final current = await owner.api.record(ownerPath);
        if (!_currentOwner(owner)) throw const ApiFailure(FailureKind.cancelled);
        if (current['updated_at'] != data['updated_at']) {
          throw const ApiFailure(FailureKind.conflict);
        }
        final body = editorSubmission([field], values);
        await _updateOwner(owner, body);
      },
    );
    if (saved && _currentOwner(owner)) {
      await _loadAfterMutation();
    }
  }

  Future<void> _editLabelsQuick() async {
    final data = _data;
    if (data == null || _busy) return;
    final owner = _owner;
    final ownerPath = _ownerPath(owner);
    final initialChoices = decodeChoices(_labelsValue(data), source: PickerSource.labels);
    final picked = await showChoicePicker(context, api: owner.api, account: owner.account, projectId: owner.project.id, source: PickerSource.labels, multi: true, title: l10n.selectLabelsReference(label), initial: initialChoices, onRoute: _ownRoute);
    if (picked == null || !_currentOwner(owner)) return;
    setState(() => _busy = true);
    try {
      final current = await owner.api.record(ownerPath);
      if (!_currentOwner(owner)) return;
      if (current['updated_at'] != data['updated_at']) {
        throw const ApiFailure(FailureKind.conflict);
      }
      final newLabels = picked.map((c) => c.name).join(', ');
      await _updateOwner(owner, {'labels': newLabels});
      if (!mounted || !_currentOwner(owner)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.labelsUpdated)));
      await _loadAfterMutation();
    } catch (e) {
      if (!mounted || !_currentOwner(owner)) return;
      showFailure(context, e);
    } finally {
      if (_currentOwner(owner)) setState(() => _busy = false);
    }
  }

  Future<void> _removeLabelQuick(String labelToRemove) async {
    final data = _data;
    if (data == null || _busy) return;
    final owner = _owner;
    final ownerPath = _ownerPath(owner);
    setState(() => _busy = true);
    try {
      final current = await owner.api.record(ownerPath);
      if (!_currentOwner(owner)) return;
      if (current['updated_at'] != data['updated_at']) {
        throw const ApiFailure(FailureKind.conflict);
      }
      final labels = _extractLabels(current);
      final remaining = labels.where((l) => l != labelToRemove).join(', ');
      await _updateOwner(owner, {'labels': remaining});
      if (!mounted || !_currentOwner(owner)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.labelRemovedNamed(labelToRemove))));
      await _loadAfterMutation();
    } catch (e) {
      if (!mounted || !_currentOwner(owner)) return;
      showFailure(context, e);
    } finally {
      if (_currentOwner(owner)) setState(() => _busy = false);
    }
  }

  Future<void> _action(String action) async {
    if (_busy || _data == null) { return; }
    final owner = _owner;
    final ownerPath = _ownerPath(owner);
    final data = _data!;
    if (action == 'edit') { await _edit(); return; }
    if (action == 'web') { await openExternal(context, web); return; }
    final confirmation = switch (action) {
      'delete' => (l10n.deleteNamedItem(label), l10n.deleteItemAndThreads, label),
      'approve' => (l10n.approveCurrentVersionPrompt, l10n.approveVersionPolicyNote(label, shortSha(valueText(data, 'sha'))), null),
      'rebase' => (l10n.rebaseBranchPrompt, l10n.rebaseOntoTargetBranch, null),
      _ => null,
    };
    var squash = false;
    var removeSourceBranch = false;
    var autoMerge = false;
    var stillDraft = false;
    if (action == 'cancel_auto_merge') {
      if (!await confirmAction(context, l10n.cancelAutoMergePrompt, l10n.cancelAutoMergeExplanation, onRoute: _ownRoute)) { return; }
      if (!_currentOwner(owner)) {
        return;
      }
      setState(() => _busy = true);
      try {
        await owner.api.cancelAutoMerge(owner.project.id, owner.iid);
        if (!_currentOwner(owner)) return;
        await _loadAfterMutation();
        if (!mounted || !_currentOwner(owner)) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.autoMergeCanceled)));
      } catch (e) {
        if (!mounted || !_currentOwner(owner)) return;
        showFailure(context, e);
      } finally {
        if (_currentOwner(owner)) { setState(() => _busy = false); }
      }
      return;
    }
    if (action == 'merge') {
      final options = await _askMerge(data);
      if (options == null || !_currentOwner(owner)) { return; }
      squash = options.squash;
      removeSourceBranch = options.removeSourceBranch;
      autoMerge = options.autoMerge;
    } else if (confirmation != null && !await confirmAction(context, confirmation.$1, confirmation.$2, requiredText: confirmation.$3, onRoute: _ownRoute)) { return; }
    if (!_currentOwner(owner)) {
      return;
    }
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'delete':
          if (owner.resource == 'issues') {
            await owner.api.deleteIssue(owner.project.id, owner.iid);
          } else {
            await owner.api.deleteMergeRequest(owner.project.id, owner.iid);
          }
          if (_currentOwner(owner)) {
            if (widget.onDeleted != null) {
              widget.onDeleted!();
            } else {
              if (!mounted) return;
              Navigator.pop(context);
            }
          }
          return;
        case 'close':
        case 'reopen':
          await _updateOwner(owner, {'state_event': action});
        case 'assign':
          final ids = valueObjects(data, 'assignees').map((v) => valueInt(v, 'id')).where((id) => id > 0).toSet();
          ids.contains(owner.account.user.id) ? ids.remove(owner.account.user.id) : ids.add(owner.account.user.id);
          await _updateOwner(owner, {'assignee_ids': ids.toList()});
        case 'todo':
          await owner.api.createTodo(owner.project.id, owner.resource, owner.iid);
        case 'draft':
          final current = await owner.api.record(ownerPath);
          if (!_currentOwner(owner)) return;
          if (current['updated_at'] != data['updated_at']) { throw const ApiFailure(FailureKind.conflict); }
          final wasDraft = current['draft'] == true;
          final title = valueText(current, 'title').trim();
          final next = toggledDraftTitle(title, wasDraft);
          if (next.isEmpty || next == title) {
            stillDraft = true;
          } else {
            final updated = await _updateOwner(owner, {'title': next});
            stillDraft = wasDraft && updated['draft'] == true;
          }
        case 'approve':
          await owner.api.approveMergeRequest(owner.project.id, owner.iid, requiredString(data, 'sha'));
        case 'unapprove':
          await owner.api.unapproveMergeRequest(owner.project.id, owner.iid);
        case 'rebase':
          await owner.api.rebaseMergeRequest(owner.project.id, owner.iid);
        case 'merge':
          await owner.api.mergeRequest(owner.project.id, owner.iid, requiredString(data, 'sha'), squash: squash, removeSourceBranch: removeSourceBranch, autoMerge: autoMerge);
      }
      if (!_currentOwner(owner)) return;
      await _loadAfterMutation();
      if (_currentOwner(owner) && action == 'rebase') {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.rebaseBranchRequested)));
      }
      if (_currentOwner(owner) && stillDraft) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.draftMarkerCannotBeRemoved)));
      }
      if (_currentOwner(owner) && action == 'merge') {
        final merged = _data?['state'] == 'merged';
        final autoScheduled = isAutoMergeEnabled(_data ?? {});
        final message = merged
            ? l10n.merged
            : (autoScheduled
                ? l10n.autoMergeWaitingForPipeline
                : l10n.gitlabAcceptedMergeAction);
        if (!mounted) return;
        if (merged) unawaited(Haptics.success());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (!mounted || !_currentOwner(owner)) return;
      if (action == 'merge') unawaited(Haptics.failure());
      showFailure(context, e);
    } finally {
      if (_currentOwner(owner)) { setState(() => _busy = false); }
    }
  }

  Future<({bool squash, bool removeSourceBranch, bool autoMerge})?> _askMerge(Json data) {
    var squash = mergeSquashDefault(data);
    var removeSourceBranch = mergeRemoveSourceBranchDefault(data);
    final squashLocked = mergeSquashEnforced(data);
    final autoCandidate = canAutoMerge(data);
    var autoMerge = autoCandidate;
    final navigator = Navigator.of(context);
    final route = DialogRoute<({bool squash, bool removeSourceBranch, bool autoMerge})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(autoMerge ? l10n.scheduleAutoMergePrompt(label) : l10n.mergeItemPrompt(label)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.mergeVersionWarning(valueText(data, 'source_branch'), valueText(data, 'target_branch'), shortSha(valueText(data, 'sha'))),
                ),
                const SizedBox(height: 8),
                if (autoCandidate) SwitchListTile(key: const ValueKey('merge-auto'), contentPadding: EdgeInsets.zero, minTileHeight: 48, title: Text(l10n.autoMergeWhenPipelineSucceeds), subtitle: Text(l10n.autoMergeWhenChecksPass), value: autoMerge, onChanged: (value) => setDialog(() => autoMerge = value)),
                SwitchListTile(key: const ValueKey('merge-squash'), contentPadding: EdgeInsets.zero, minTileHeight: 48, title: Text(l10n.squashCommits), subtitle: squashLocked ? Text(l10n.optionRequiredByProject) : null, value: squash, onChanged: squashLocked ? null : (value) => setDialog(() => squash = value)),
                SwitchListTile(key: const ValueKey('merge-remove-branch'), contentPadding: EdgeInsets.zero, minTileHeight: 48, title: Text(l10n.deleteSourceBranchAfterMerge), value: removeSourceBranch, onChanged: (value) => setDialog(() => removeSourceBranch = value)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancelAction)),
            FilledButton(onPressed: () => Navigator.pop(context, (squash: squash, removeSourceBranch: removeSourceBranch, autoMerge: autoMerge)), child: Text(autoMerge ? l10n.scheduleAutoMerge : l10n.confirmAction)),
          ],
        ),
      ),
    );
    _ownRoute(route);
    return navigator.push(route);
  }

  /// Opens a person named on this item; [user] is the author, assignee or
  /// reviewer object from the item's own response.
  void _openUser(Json user) {
    final owner = _owner;
    if (valueInt(user, 'id') <= 0 || !_currentOwner(owner) || owner.api.isClosed) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => UserPage(account: owner.account, api: owner.api, user: user),
    );
    _ownRoute(route);
    unawaited(Navigator.of(context).push(route));
  }

  Future<void> _openDraftReview(Json data) async {
    final owner = _owner;
    final headSha = valueText(data, 'sha');
    if (headSha.isEmpty) {
      showFailure(context, const ApiFailure(FailureKind.invalidResponse));
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => DraftReviewPage(account: owner.account, api: owner.api, project: owner.project, iid: owner.iid, headSha: headSha),
    );
    _ownRoute(route);
    await Navigator.of(context).push<void>(route);
  }

  Widget _reviewCard(Json data) {
    final state = valueText(data, 'state');
    if (state != 'opened') {
      if (state != 'merged' && state != 'closed') { return const SizedBox.shrink(); }
      final at = relativeDate(valueText(data, state == 'merged' ? 'merged_at' : 'closed_at'));
      final label = state == 'merged' ? l10n.merged : l10n.statusClosed;
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(at.isEmpty ? label : '$label · $at', style: Theme.of(context).textTheme.titleSmall),
      );
    }
    final autoScheduled = isAutoMergeEnabled(data);
    final autoCandidate = canAutoMerge(data);
    final approvals = _approvalsData;
    final approvedBy = approvals != null ? valueObjects(approvals, 'approved_by') : <Json>[];
    final approvalsRequired = approvals != null ? valueInt(approvals, 'approvals_required') : 0;
    final approvalsLeft = approvals != null ? valueInt(approvals, 'approvals_left') : 0;
    final myId = widget.account.user.id;
    final hasApproved = approvedBy.any((v) => valueInt(valueObject(v, 'user'), 'id') == myId);
    final isThresholdReached = approvalsLeft == 0 && (approvalsRequired > 0 || approvedBy.isNotEmpty);
    final hasUnresolvedDiscussions = data['blocking_discussions_resolved'] == false;
    final divergedCommits = valueInt(data, 'diverged_commits_count');
    final rebaseInProgress = valueBool(data, 'rebase_in_progress');
    final hasConflicts = valueBool(data, 'has_conflicts');
    final canRebase = !hasConflicts && (divergedCommits > 0 || data['rebase_in_progress'] != null);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(mergeStatusLabel(data), style: Theme.of(context).textTheme.titleSmall)),
                  if (autoScheduled) const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.schedule_send, size: 20)),
                ],
              ),
              if (autoScheduled) ...[const SizedBox(height: 6), Text(l10n.mergeRunsAfterPipeline, style: TextStyle(fontSize: 12))],
              if (hasUnresolvedDiscussions) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('unresolved-discussions-notice'),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    children: [
                      Icon(Icons.chat_bubble_outline, size: 16, color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.unresolvedThreadsBlockMerge,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (approvals != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: isThresholdReached ? WorkshopColors.of(context).successContainer.withValues(alpha: 0.4) : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(isThresholdReached ? Icons.check_circle_outline : Icons.rule_outlined, size: 16, color: isThresholdReached ? WorkshopColors.of(context).onSuccessContainer : null),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(isThresholdReached ? l10n.approvalThresholdReached(approvedBy.length) : l10n.approvalProgress(approvedBy.length, approvalsRequired > 0 ? l10n.approvalsLeftSuffix(approvalsLeft) : ''), style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      if (approvedBy.isNotEmpty) ...[const SizedBox(height: 4), Text(l10n.approvedByList(approvedBy.map((v) => isolated('@${valueText(valueObject(v, 'user'), 'username')}')).join(l10n.listSeparator)), style: Theme.of(context).textTheme.bodySmall)],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(key: const ValueKey('mr-draft-review-btn'), onPressed: _busy ? null : () => _openDraftReview(data), icon: const Icon(Icons.rate_review_outlined, size: 18), label: Text(l10n.reviewDrafts)),
                  if (hasApproved)
                    OutlinedButton.icon(key: const ValueKey('mr-unapprove-btn'), onPressed: _busy ? null : () => _action('unapprove'), icon: const Icon(Icons.undo, size: 18), label: Text(l10n.revokeMyApproval))
                  else
                    OutlinedButton.icon(key: const ValueKey('mr-approve-btn'), onPressed: _busy ? null : () => _action('approve'), icon: const Icon(Icons.verified_outlined, size: 18), label: Text(l10n.approve2)),
                  if (rebaseInProgress)
                    OutlinedButton.icon(
                      key: const ValueKey('mr-rebase-progress-btn'),
                      onPressed: null,
                      icon: const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      label: Text(l10n.rebaseInProgress),
                    )
                  else if (canRebase)
                    OutlinedButton.icon(key: const ValueKey('mr-rebase-btn'), onPressed: _busy ? null : () => _action('rebase'), icon: const Icon(Icons.fork_right, size: 18), label: Text(divergedCommits > 0 ? l10n.rebaseBehindCount(divergedCommits) : 'Rebase')),
                  if (autoScheduled)
                    OutlinedButton.icon(key: const ValueKey('cancel-auto-merge'), onPressed: _busy ? null : () => _action('cancel_auto_merge'), icon: const Icon(Icons.close, size: 18), label: Text(l10n.cancelAutoMerge))
                  else
                    FilledButton.icon(onPressed: _busy ? null : () => _action('merge'), icon: Icon(autoCandidate ? Icons.schedule_send : Icons.merge, size: 18), label: Text(autoCandidate ? l10n.autoMergeEllipsis : l10n.merge)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setIncidentLifecycle(IncidentLifecycle next) async {
    if (_busy || type != ProjectWorkItemType.incident || !next.canSet) return;
    final owner = _owner;
    IncidentStatusSnapshot fresh;
    try {
      final raw = await owner.api.incidentStatus(owner.project, owner.iid);
      if (!_currentOwner(owner)) return;
      fresh = IncidentStatusSnapshot.fromJson(raw, expectedProjectId: owner.project.id, expectedIid: owner.iid);
    } catch (error) {
      if (!mounted || !_currentOwner(owner)) return;
      showFailure(context, error);
      return;
    }
    if (fresh.lifecycle == next) return;
    if (!mounted) return;
    final confirmed = await confirmAction(
      context,
      l10n.changeIncidentStatusPrompt,
      l10n.incidentStatusIndependent(fresh.lifecycle.label, next.label, statusLabel(fresh.issueState)),
      onRoute: _ownRoute,
    );
    if (!confirmed || !_currentOwner(owner)) return;
    setState(() => _busy = true);
    try {
      final raw = await owner.api.setIncidentStatus(owner.project, owner.iid, next.apiValue, expectedUpdatedAt: fresh.updatedAt, isCurrent: () => _currentOwner(owner));
      if (!_currentOwner(owner)) return;
      final updated = IncidentStatusSnapshot.fromJson(raw, expectedProjectId: owner.project.id, expectedIid: owner.iid);
      if (updated.lifecycle != next) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      setState(() {
        _incidentStatus = updated;
        _incidentStatusError = null;
      });
      await _loadAfterMutation();
    } catch (error) {
      if (!mounted || !_currentOwner(owner)) return;
      showFailure(context, error);
    } finally {
      if (_currentOwner(owner)) setState(() => _busy = false);
    }
  }

  Widget _incidentStatusCard(Json data) {
    final status = _incidentStatus;
    final error = _incidentStatusError;
    final severity = incidentSeverityFromJson(data);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Card(
        key: const ValueKey('incident-status-card'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.incidentStatus, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MetaChip(l10n.issueStateLabel(statusLabel(valueText(data, 'state'))), icon: Icons.adjust),
                  if (severity != null) MetaChip(l10n.severityLabel(severity.label), icon: Icons.priority_high),
                  if (status != null) MetaChip(l10n.incidentStatusLabel(status.lifecycle.label), icon: Icons.crisis_alert_outlined),
                ],
              ),
              if (status == null) ...[
                const SizedBox(height: 10),
                Text(error?.kind == FailureKind.unsupported ? l10n.incidentStatusUnavailable : l10n.incidentStatusTemporarilyUnavailable, key: const ValueKey('incident-lifecycle-unavailable'), style: Theme.of(context).textTheme.bodySmall),
                TextButton.icon(onPressed: _loading || _busy ? null : () => _load(fresh: true), icon: const Icon(Icons.refresh, size: 18), label: Text(l10n.retryIncidentStatus)),
              ] else ...[
                const SizedBox(height: 10),
                Text(l10n.incidentStatusDoesNotCloseIssue, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final next in IncidentLifecycle.values.where((value) => value.canSet)) OutlinedButton(key: ValueKey('incident-lifecycle-${next.name}'), onPressed: _busy || status.lifecycle == next ? null : () => _setIncidentLifecycle(next), child: Text(next.label))],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _subscribe(bool subscribed) async {
    if (_busy) return;
    final owner = _owner;
    setState(() => _busy = true);
    try {
      await owner.api.setSubscribed(owner.project.id, owner.resource, owner.iid, subscribed);
      if (!mounted || !_currentOwner(owner)) return;
      setState(() => _data = {...?_data, 'subscribed': subscribed});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(subscribed ? l10n.notificationsOn : l10n.notificationsOff)));
      // A failed refresh must not erase a confirmed subscription write.
      await _load(fresh: true);
    } catch (e) {
      if (!mounted || !_currentOwner(owner)) return;
      showFailure(context, e);
    } finally {
      if (_currentOwner(owner)) setState(() => _busy = false);
    }
  }

  List<Widget> _detailRows(Json data) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final rows = <Widget>[];
    void add(IconData icon, String label, String value) {
      rows
        ..add(const Divider(height: 20))
        ..add(
          Row(
            children: [
              Icon(icon, size: 18, color: muted),
              const SizedBox(width: 10),
              Text(label, style: theme.textTheme.titleSmall),
              const SizedBox(width: 12),
              Expanded(
                child: Text(value, textAlign: TextAlign.end, style: theme.textTheme.bodyMedium),
              ),
            ],
          ),
        );
    }

    final due = valueText(data, 'due_date');
    if (due.isNotEmpty) add(Icons.event_outlined, l10n.dueDate2, due);
    final time = valueObject(data, 'time_stats');
    final estimate = valueText(time, 'human_time_estimate'), spent = valueText(time, 'human_total_time_spent');
    if (estimate.isNotEmpty || spent.isNotEmpty) {
      add(Icons.timer_outlined, l10n.timeTrackingRow, l10n.spentAndEstimate(spent.isEmpty ? '0' : spent, estimate.isEmpty ? l10n.notSet : estimate));
    }
    if (data['weight'] is int) add(Icons.fitness_center, l10n.weight, '${data['weight']}');
    if (data['discussion_locked'] == true) add(Icons.lock_outline, l10n.thread, l10n.lockedMembersCanComment);
    final subscribed = data['subscribed'];
    if (subscribed is bool) {
      rows
        ..add(const Divider(height: 12))
        ..add(
          SwitchListTile(
            key: const ValueKey('work-item-subscribe'),
            contentPadding: EdgeInsets.zero,
            minTileHeight: 48,
            secondary: Icon(subscribed ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, color: muted),
            title: Text(l10n.notifications),
            subtitle: Text(subscribed ? l10n.notifyOnNewActivity : l10n.muteItemNotifications),
            value: subscribed,
            onChanged: _busy ? null : _subscribe,
          ),
        );
    }
    return rows;
  }

  /// The author line, tappable when the author carries a user ID.
  Widget _authorLink(Json author, String label, Widget child) {
    if (valueInt(author, 'id') <= 0) return child;
    void open() => _openUser(author);
    return SemanticButton(
      label: l10n.authorLabel(label),
      onTap: open,
      child: InkWell(
        key: const ValueKey('work-item-author'),
        borderRadius: BorderRadius.circular(6),
        onTap: open,
        child: child,
      ),
    );
  }

  Widget _buildAssigneesSection(Json data) {
    final assignees = valueObjects(data, 'assignees');
    final myId = widget.account.user.id;
    final isAssignedToMe = assignees.any((v) => valueInt(v, 'id') == myId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(l10n.assignee, style: Theme.of(context).textTheme.titleSmall),
            TextButton.icon(
              key: const ValueKey('quick-edit-assignees'),
              onPressed: _busy ? null : _editAssignees,
              icon: const Icon(Icons.group_add_outlined, size: 16),
              label: Text(l10n.editList),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, minimumSize: const Size(48, 48)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (isAssignedToMe)
              InputChip(key: const ValueKey('quick-unassign-me'), avatar: const Icon(Icons.check_circle, size: 16), label: Text(l10n.assignedToMe2), selected: true, showCheckmark: false, onDeleted: _busy ? null : () => _action('assign'), deleteIcon: const Icon(Icons.close, size: 14), deleteButtonTooltipMessage: l10n.unassignMe, onPressed: _busy ? null : () => _action('assign'))
            else
              ActionChip(key: const ValueKey('quick-assign-me'), avatar: const Icon(Icons.person_add_alt_1, size: 16), label: Text(l10n.assignToMe), onPressed: _busy ? null : () => _action('assign')),
            ...assignees.where((u) => valueInt(u, 'id') != myId).map((u) {
              final username = valueText(u, 'username');
              final name = valueText(u, 'name');
              return ActionChip(
                key: ValueKey('assignee-${valueInt(u, 'id')}'),
                avatar: CircleAvatar(radius: 12, child: Text((username.isNotEmpty ? username[0] : '?').toUpperCase(), style: const TextStyle(fontSize: 10))),
                label: Text(name.isNotEmpty ? '${isolated(name)} (${isolated('@$username')})' : isolated('@$username')),
                onPressed: valueInt(u, 'id') > 0 ? () => _openUser(u) : null,
              );
            }),
            if (assignees.isEmpty && !isAssignedToMe)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(l10n.noAssigneesYet, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildReviewersSection(Json data) {
    final reviewers = valueObjects(data, 'reviewers');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(l10n.reviewers, style: Theme.of(context).textTheme.titleSmall),
            TextButton.icon(
              key: const ValueKey('quick-edit-reviewers'),
              onPressed: _busy ? null : _editReviewers,
              icon: const Icon(Icons.person_search_outlined, size: 16),
              label: Text(l10n.editReviewers),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, minimumSize: const Size(48, 48)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...reviewers.map((u) {
              final username = valueText(u, 'username');
              final name = valueText(u, 'name');
              return ActionChip(
                key: ValueKey('reviewer-${valueInt(u, 'id')}'),
                avatar: CircleAvatar(radius: 12, child: Text((username.isNotEmpty ? username[0] : '?').toUpperCase(), style: const TextStyle(fontSize: 10))),
                label: Text(name.isNotEmpty ? '${isolated(name)} (${isolated('@$username')})' : isolated('@$username')),
                onPressed: valueInt(u, 'id') > 0 ? () => _openUser(u) : null,
              );
            }),
            if (reviewers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(l10n.noReviewersYet, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildLabelsSection(Json data) {
    final labels = _extractLabels(data);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(l10n.labelNoun, style: Theme.of(context).textTheme.titleSmall),
            TextButton.icon(
              key: const ValueKey('quick-edit-labels'),
              onPressed: _busy ? null : _editLabelsQuick,
              icon: const Icon(Icons.label_outline, size: 16),
              label: Text(l10n.manageLabels),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final label in labels) InputChip(key: ValueKey('label-chip-$label'), label: Text(label), onPressed: _busy ? null : _editLabelsQuick, onDeleted: _busy ? null : () => _removeLabelQuick(label), deleteIcon: const Icon(Icons.close, size: 14), deleteButtonTooltipMessage: l10n.removeLabelNamed(label)),
            ActionChip(key: const ValueKey('quick-add-label'), avatar: const Icon(Icons.add, size: 16), label: Text(l10n.addLabel2), onPressed: _busy ? null : _editLabelsQuick),
            if (labels.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(l10n.noLabelsYet, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final owner = _owner;
    final appBar = AppBar(
      primary: false,
      toolbarHeight: (MediaQuery.textScalerOf(context).scale(19) * 1.3 +
          MediaQuery.textScalerOf(context).scale(12) * 1.5 + 12).clamp(56, double.infinity),
      automaticallyImplyLeading: false,
      leading: widget.showBackButton ? BackButton(onPressed: widget.onBack) : null,
      titleSpacing: widget.showBackButton ? 0 : null,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(isolated(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 19)),
          Text(
            widget.project.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
      actions: [
        ResourceShareButton(uri: web,
          ownerKey: (owner.account.key, owner.api, owner.project.id, owner.resource, owner.iid, owner.generation),
          isCurrent: () => _currentOwner(owner) && !owner.api.isClosed),
        IconButton(tooltip: l10n.refreshAction, onPressed: _loading || _busy ? null : () => _load(fresh: true), icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(
          tooltip: l10n.moreOptions,
          enabled: !_busy && data != null,
          onSelected: (value) => value.startsWith('ai') ? _openAi(summarize: value == 'ai-summary') : _action(value),
          itemBuilder: (_) => [
            // AI is offered only where the app was built with it.
            if (AiRunRegistry.maybeOf(context) != null) ...[
              if (mr) PopupMenuItem(value: 'ai-summary', child: Text(l10n.aiSummarize)),
              PopupMenuItem(value: 'ai', child: Text(l10n.aiDiscuss)),
              const PopupMenuDivider(),
            ],
            PopupMenuItem(value: 'edit', child: Text(l10n.editAction)),
            if (data?['state'] == 'opened') PopupMenuItem(value: 'close', child: Text(type == ProjectWorkItemType.incident ? l10n.closeIssueState : l10n.closeAction)),
            if (mr && data?['state'] == 'opened') PopupMenuItem(value: 'draft', child: Text(data?['draft'] == true ? l10n.markAsReady2 : l10n.markAsDraft2)),
            if (data?['state'] == 'closed') PopupMenuItem(value: 'reopen', child: Text(type == ProjectWorkItemType.incident ? l10n.reopenIssueState : l10n.reopen)),
            PopupMenuItem(value: 'assign', child: Text(valueObjects(data ?? {}, 'assignees').any((v) => v['id'] == widget.account.user.id) ? l10n.unassignMe : l10n.assignToMe)),
            PopupMenuItem(value: 'todo', child: Text(l10n.addToMyTodo)),
            PopupMenuItem(value: 'web', child: Text(l10n.openInGitlab)),
            PopupMenuItem(value: 'delete', child: Text(l10n.delete)),
          ],
        ),
      ],
    );
    if (data == null) {
      return Scaffold(
        body: StatusBarInset(
          child: gestureSafe(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                appBar,
                Expanded(
                  child: _error != null
                      ? SingleChildScrollView(
                          child: FailureNotice(
                            _error!,
                            onRetry: () => _load(fresh: true),
                            account: widget.account,
                            resourceLabel: '${widget.project.path} · $label',
                            onSwitchAccount: endSessionFrom(context, ResumeTarget(projectId: widget.project.id, projectPath: widget.project.path, resource: widget.resource, iid: widget.iid)),
                          ),
                        )
                      : const DetailSkeleton(),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final author = valueObject(data, 'author');
    final authorName = valueText(author, 'name', valueText(author, 'username'));
    final created = relativeDate(valueText(data, 'created_at'));
    final crowded = MediaQuery.textScalerOf(context).scale(14) > 14 * 1.3;
    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: _chrome.handle,
        child: StatusBarInset(
          child: gestureSafe(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CollapsingChrome(
                  visible: _chrome,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      appBar,
                      Padding(
                        // Aligned with the content below, clear of the app bar.
                        padding: DetailSkeleton.headerPadding,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(valueText(data, 'title'), textDirection: firstStrongDirection(valueText(data, 'title')), minLines: 1, maxLines: 4, style: theme.textTheme.titleLarge?.copyWith(height: 1.3)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                StatusBadge(valueText(data, 'state')),
                                if (!mr && type != ProjectWorkItemType.issue) MetaChip(type.title, icon: type == ProjectWorkItemType.task ? Icons.task_alt : Icons.warning_amber_rounded),
                                if (data['draft'] == true) MetaChip(l10n.draft, icon: Icons.edit_note),
                                if (valueBool(data, 'confidential')) MetaChip(l10n.confidential, icon: Icons.lock_outline),
                                if (valueObject(data, 'milestone').isNotEmpty) MetaChip(valueText(valueObject(data, 'milestone'), 'title'), icon: Icons.tour_outlined),
                                _authorLink(
                                  author,
                                  '@${valueText(author, 'username')}${created.isEmpty ? '' : ' · $created'}',
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Monogram(authorName, size: 18),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          '${isolated('@${valueText(author, 'username')}')}${created.isEmpty ? '' : ' · $created'}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall?.copyWith(color: muted),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
                if (_freshnessAt case final fetchedAt?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: CacheFreshnessBar(
                      fetchedAt: fetchedAt,
                      refreshing: _revalidating,
                      failure: _backgroundFailure,
                      retryAt: _backgroundRetryAt,
                      onRetry: () => unawaited(_load(fresh: true)),
                    ),
                  ),
                TabBar(
                  controller: _tabs,
                  indicatorSize: TabBarIndicatorSize.tab,
                  isScrollable: crowded,
                  tabAlignment: crowded ? TabAlignment.start : null,
                  tabs: [
                    Tab(text: l10n.summary),
                    if (mr) Tab(text: l10n.changes),
                    Tab(text: l10n.thread),
                    if (mr) Tab(text: l10n.checks),
                  ],
                ),
                Expanded(
                  child: NotificationListener<KeepAliveNotification>(onNotification: (_) => true, child: TabBarView(
                    controller: _tabs,
                    children: [
                      ListView(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                        children: [
                          if (_error != null)
                            FailureNotice(
                              _error!,
                              onRetry: () => _load(fresh: true),
                              account: widget.account,
                              resourceLabel: '${widget.project.path} · $label',
                              onSwitchAccount: endSessionFrom(context, ResumeTarget(projectId: widget.project.id, projectPath: widget.project.path, resource: widget.resource, iid: widget.iid)),
                            ),
                          if (mr) _reviewCard(data),
                          if (type == ProjectWorkItemType.incident) _incidentStatusCard(data),
                          if (mr)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Wrap(
                                spacing: 10,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  MetaChip('${valueText(data, 'source_branch')} → ${valueText(data, 'target_branch')}', icon: Icons.alt_route, mono: true),
                                  if (valueText(data, 'changes_count').isNotEmpty) MetaChip(l10n.fileCount2(valueText(data, 'changes_count')), icon: Icons.difference_outlined),
                                ],
                              ),
                            ),
                          _RestDescription(
                            valueText(data, 'description').isEmpty ? l10n.noDescriptionYet : valueText(data, 'description'),
                            key: ValueKey('rest-description/${owner.account.key}/${owner.project.id}/${owner.resource}/${owner.iid}/${owner.generation}'),
                            account: widget.account,
                            base: web, api: widget.api, projectId: widget.project.id, projectWeb: widget.account.instance.projectWeb(widget.project.path), projectPath: widget.project.path,
                          ),
                          if (owner.resource == 'issues' && owner.type == ProjectWorkItemType.issue) ...[
                            const SizedBox(height: 14),
                            _WorkItemKeepAlive(
                              key: ValueKey('rest-issue-graph-bridge/${owner.account.key}/${owner.project.id}/${owner.iid}/${owner.generation}'),
                              child: RestIssueGraphBridge(
                                account: widget.account,
                                api: widget.api,
                                project: widget.project,
                                iid: widget.iid,
                                graphEpoch: _graphEpoch,
                                graphReadyEpoch: _graphReadyEpoch,
                                onOpenEditor: () => unawaited(_onOpenEditor()),
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          _WorkItemKeepAlive(
                            key: ValueKey('work-item-reactions/${owner.account.key}/${owner.project.id}/${owner.resource}/${owner.iid}/${owner.generation}'),
                            child: ReactionsBar(account: widget.account, api: widget.api, project: widget.project, resource: widget.resource, iid: widget.iid),
                          ),
                          const SizedBox(height: 16),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 4, 8, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildAssigneesSection(data),
                                  if (mr) ...[const Divider(height: 20), _buildReviewersSection(data)],
                                  const Divider(height: 20),
                                  _buildLabelsSection(data),
                                  if (valueObject(data, 'milestone').isNotEmpty) ...[
                                    const Divider(height: 20),
                                    Text(l10n.milestoneLabel, style: Theme.of(context).textTheme.titleSmall),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 2,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.tour_outlined, size: 18),
                                            const SizedBox(width: 8),
                                            Flexible(child: Text(valueText(valueObject(data, 'milestone'), 'title'))),
                                          ],
                                        ),
                                        if (valueText(valueObject(data, 'milestone'), 'due_date').isNotEmpty) Text(l10n.dueDateParen(valueText(valueObject(data, 'milestone'), 'due_date')), style: Theme.of(context).textTheme.bodySmall),
                                      ],
                                    ),
                                  ],
                                  ..._detailRows(data),
                                ],
                              ),
                            ),
                          ),
                          if (!mr)
                            _WorkItemKeepAlive(
                              key: ValueKey('work-item-related-issues/${owner.account.key}/${owner.project.id}/${owner.iid}/${owner.generation}'),
                              child: _RelatedIssueItems(account: widget.account, api: widget.api, project: widget.project, iid: widget.iid, revision: _relatedRevision),
                            ),
                          if (mr) _MergeRequestHistory(account: widget.account, api: widget.api, project: widget.project, iid: widget.iid),
                          const SizedBox(height: 12),
                          Text([if (valueText(data, 'created_at').isNotEmpty) l10n.createdRelative(relativeDate(valueText(data, 'created_at'))), l10n.updatedRelative(relativeDate(valueText(data, 'updated_at')))].join(' · '), style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                      if (mr) ReviewDiffPage(key: ValueKey(valueText(data, 'sha')), account: widget.account, api: widget.api, project: widget.project, iid: widget.iid, expectedSha: valueText(data, 'sha'), onApplied: _loadAfterMutation),
                      DiscussionsTab(account: widget.account, api: widget.api, project: widget.project, resource: widget.resource, iid: widget.iid, headSha: mr ? valueText(data, 'sha') : null, onChanged: _loadAfterMutation),
                      if (mr) _MergeChecks(account: widget.account, api: widget.api, path: path, data: data, busy: _busy, act: _action),
                    ],
                  )),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Long descriptions show a bounded plain-text preview; the Markdown tree is
/// parsed and built only after the reader asks for the full text.
class _RestDescription extends StatefulWidget {
  const _RestDescription(
    this.text, {
    super.key,
    required this.account,
    required this.base,
    required this.api,
    required this.projectId,
    required this.projectWeb,
    required this.projectPath,
  });
  final Account account;
  final String text;
  final Uri base;
  final GitLabApi api;
  final int projectId;
  final Uri projectWeb;
  final String projectPath;
  @override
  State<_RestDescription> createState() => _RestDescriptionState();
}

class _RestDescriptionState extends State<_RestDescription>
    with AutomaticKeepAliveClientMixin {
  // Same rune threshold as the GraphQL description card.
  static const _maxRichRunes = 800;
  static const _maxRichLines = 30;
  static const _previewLength = 280;
  static const _previewWindow = _previewLength * 2;
  bool _expanded = false;
  late bool _long;
  late int _runes;
  late String _preview;

  @override
  bool get wantKeepAlive => _expanded;

  @override
  void initState() {
    super.initState();
    _summarize();
  }

  @override
  void didUpdateWidget(covariant _RestDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    _summarize();
    if (_expanded) {
      _expanded = false;
      updateKeepAlive();
    }
  }

  void _summarize() {
    final text = widget.text;
    _runes = text.runes.length;
    _long =
        _runes > _maxRichRunes || '\n'.allMatches(text).length >= _maxRichLines;
    _preview = _long ? _previewOf(text) : '';
  }

  static String _previewOf(String text) {
    // Readable text only: no HTML comments, tags or Markdown markers.
    final head = markdownSummary(text, _previewWindow);
    final normalized = head.text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .characters;
    final shown = normalized.take(_previewLength).toString().trimRight();
    if (shown.isEmpty) return '';
    return head.more || normalized.length > _previewLength
        ? '$shown…'
        : shown;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    updateKeepAlive();
  }

  Widget _markdown() => MarkdownView(
    widget.text,
    account: widget.account,
    base: widget.base,
    api: widget.api,
    projectId: widget.projectId,
    projectWeb: widget.projectWeb,
    projectPath: widget.projectPath,
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_long) return _markdown();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Keep the toggle above the text: collapsing must not need a scroll past a long body.
        TextButton.icon(
          key: const ValueKey('work-item-description-toggle'),
          onPressed: _toggle,
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: Icon(
            _expanded ? Icons.unfold_less : Icons.unfold_more,
            size: 18,
          ),
          label: Semantics(
            expanded: _expanded,
            child: Text(_expanded ? l10n.collapseDescription : l10n.expandFullDescription),
          ),
        ),
        const SizedBox(height: 4),
        // The body grows from the summary to the full text (and back) instead
        // of jumping to its new height.
        AnimatedSize(
          duration: motionDuration(context, Durations.medium2),
          curve: Easing.standard,
          alignment: Alignment.topCenter,
          child: _expanded
              ? _markdown()
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // A description of only comments or images has no summary.
                  if (_preview.isNotEmpty) Text(
                    _preview,
                    key: const ValueKey('work-item-description-preview'),
                    textDirection: firstStrongDirection(_preview),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.descriptionTruncated(_runes),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ]),
        ),
      ],
    );
  }
}

/// Keeps bounded sibling widgets alive across viewport scrolling within the
/// same work item binding and retains the summary tab across tab switches.
/// Keyed on the owner's identity and generation so stale state is never
/// retained across account, project, resource, or iid changes.
class _WorkItemKeepAlive extends StatefulWidget {
  const _WorkItemKeepAlive({super.key, required this.child});
  final Widget child;

  @override
  State<_WorkItemKeepAlive> createState() => _WorkItemKeepAliveState();
}

class _WorkItemKeepAliveState extends State<_WorkItemKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _MergeChecks extends StatefulWidget {
  const _MergeChecks({required this.account, required this.api, required this.path, required this.data, required this.busy, required this.act});
  final Account account;
  final GitLabApi api;
  final List<String> path;
  final Json data;
  final bool busy;
  final Future<void> Function(String) act;
  @override
  State<_MergeChecks> createState() => _MergeChecksState();
}

class _MergeChecksState extends State<_MergeChecks> {
  late Future<Json> _approvals;
  Future<Json> _cachedApprovals({bool fresh = false}) async {
    var read = await widget.api.cachedRecord([...widget.path, 'approvals'], fresh: fresh, maxAge: _threadMaxAge);
    if (read.superseded) {
      read = await widget.api.cachedRecord([...widget.path, 'approvals'], fresh: true, maxAge: _threadMaxAge);
    }
    if (read.dropped || read.superseded) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    return read.value;
  }

  @override
  void initState() { super.initState(); _approvals = _cachedApprovals(); }

  @override
  void didUpdateWidget(covariant _MergeChecks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) { _approvals = _cachedApprovals(); }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(l10n.mergeConditions, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      Text(mergeStatusLabel(widget.data)),
      const SizedBox(height: 12),
      Text(
        l10n.versionShortSha(shortSha(valueText(widget.data, 'sha'))),
        style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace']),
      ),
      if (widget.data['head_pipeline'] is Json) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: StatusBadge(valueText(valueObject(widget.data, 'head_pipeline'), 'status'))),
      const Divider(height: 32),
      Text(l10n.review, style: Theme.of(context).textTheme.titleMedium),
      FutureBuilder<Json>(
        future: _approvals,
        builder: (context, snap) {
          if (snap.hasError) {
            return FailureNotice(
              safeFailure(snap.error!),
              account: widget.account,
              resourceLabel: l10n.mergeChecks,
              onSwitchAccount: endSessionFrom(context),
              onRetry: () => setState(() {
        _approvals = _cachedApprovals(fresh: true);
      }),
            );
          }
          if (!snap.hasData) { return const ListSkeleton(); }
          final approved = valueObjects(snap.data!, 'approved_by');
          return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(approved.isEmpty ? l10n.noApproversYet
        : approved.map((v) => isolated('@${valueText(valueObject(v, 'user'), 'username')}')).join(l10n.listSeparator)));
        },
      ),
      if (widget.data['state'] == 'opened') ...[
        OutlinedButton.icon(onPressed: widget.busy ? null : () => widget.act('approve'), icon: const Icon(Icons.verified_outlined), label: Text(l10n.approveCurrentVersion)),
        TextButton(onPressed: widget.busy ? null : () => widget.act('unapprove'), child: Text(l10n.revokeMyApproval)),
        const SizedBox(height: 16),
        if (isAutoMergeEnabled(widget.data))
          OutlinedButton.icon(key: const ValueKey('cancel-auto-merge-checks'), onPressed: widget.busy ? null : () => widget.act('cancel_auto_merge'), icon: const Icon(Icons.close), label: Text(l10n.cancelAutoMerge))
        else
          FilledButton.icon(onPressed: widget.busy ? null : () => widget.act('merge'), icon: Icon(canAutoMerge(widget.data) ? Icons.schedule_send : Icons.merge), label: Text(canAutoMerge(widget.data) ? l10n.autoMergeEllipsis : l10n.mergeEllipsis)),
        const SizedBox(height: 12),
        Text(l10n.gitlabRechecksMergeConditions, style: TextStyle(fontSize: 12)),
      ],
    ],
  );
}

/// Merge requests that mention or close an issue, and its linked issues.
class _RelatedIssueItems extends StatefulWidget {
  const _RelatedIssueItems({required this.account, required this.api, required this.project, required this.iid, this.revision = 0});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  /// Bumped by the page on every explicit (fresh) load so the list refreshes
  /// together with the detail; stale cache entries already re-read through
  /// [maxAge] on reopen.
  final int revision;
  @override
  State<_RelatedIssueItems> createState() => _RelatedIssueItemsState();
}

class _RelatedIssueItemsState extends State<_RelatedIssueItems> {
  List<Json> _mergeRequests = const [], _links = const [];
  ApiFailure? _error;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _RelatedIssueItems oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      unawaited(_load(fresh: true));
    }
  }

  Future<void> _load({bool fresh = false}) async {
    final epoch = ++_epoch;
    final base = ['projects', '${widget.project.id}', 'issues', '${widget.iid}'];
    if (_error != null) setState(() => _error = null);
    try {
      final reads = await Future.wait([
        widget.api.cachedRecords([...base, 'related_merge_requests'], fresh: fresh, maxAge: _threadMaxAge),
        widget.api.cachedRecords([...base, 'links'], fresh: fresh, maxAge: _threadMaxAge),
      ]);
      if (!mounted || epoch != _epoch) return;
      for (final read in reads) {
        if (read.dropped || read.superseded) {
          throw const ApiFailure(FailureKind.cancelled);
        }
      }
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _mergeRequests = reads[0].value.items;
        _links = reads[1].value.items;
      });
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = safeFailure(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return FailureNotice(error, account: widget.account, onRetry: () => _load(fresh: true), onSwitchAccount: endSessionFrom(context),
        resourceLabel: l10n.relatedMergeRequestsAndIssues(widget.project.path, widget.iid));
    }
    if (_mergeRequests.isEmpty && _links.isEmpty) return const SizedBox.shrink();
    final open = ResourceNavigator(widget.account, widget.api);
    final theme = Theme.of(context);
    Widget row(Json item, {required bool mr}) {
      final linkType = valueText(item, 'link_type');
      final relation = switch (linkType) {
        'blocks' => l10n.blocks, 'is_blocked_by' => l10n.blockedBy, 'relates_to' => l10n.related, _ => '',
      };
      return ListTile(
        contentPadding: EdgeInsets.zero,
        minTileHeight: 48,
        leading: Icon(mr ? Icons.merge : Icons.adjust, size: 20),
        title: Text(isolated(valueText(item, 'title')), maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text([isolated('${mr ? '!' : '#'}${valueInt(item, 'iid')}'), statusLabel(valueText(item, 'state')), if (relation.isNotEmpty) relation].join(' · ')),
        onTap: () => open.workItem(context, '${valueInt(item, 'project_id')}', mr ? 'merge_requests' : 'issues', valueInt(item, 'iid')),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_mergeRequests.isNotEmpty) ...[Text(l10n.relatedMergeRequests, style: theme.textTheme.titleSmall), for (final item in _mergeRequests) row(item, mr: true)],
              if (_links.isNotEmpty) ...[if (_mergeRequests.isNotEmpty) const Divider(height: 16), Text(l10n.linkedIssues, style: theme.textTheme.titleSmall), for (final item in _links) row(item, mr: false)],
            ],
          ),
        ),
      ),
    );
  }
}

/// Entry points to a merge request's commits and pipelines.
class _MergeRequestHistory extends StatelessWidget {
  const _MergeRequestHistory({required this.account, required this.api, required this.project, required this.iid});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;

  @override
  Widget build(BuildContext context) {
    final open = ResourceNavigator(account, api);
    final base = ['projects', '${project.id}', 'merge_requests', '$iid'];
    Future<void> push(String title, Widget body) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: gestureSafe(body))));
    return Padding(padding: const EdgeInsets.only(top: 12), child: Card(child: Column(children: [
      ListTile(
        key: const ValueKey('mr-commits-entry'),
        leading: const Icon(Icons.commit),
        title: Text(l10n.commitHistory),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => push(l10n.mergeRequestCommits(iid), RecordsFeed(
          identity: '${base.join('/')}/commits',
          account: account,
          resourceLabel: l10n.mergeRequestCommitsPath(project.path, iid),
          onSwitchAccount: endSessionFrom(context),
          empty: l10n.noCommits,
          grouped: true,
          cached: ({required bool fresh, required bool background}) => api.cachedRecords([...base, 'commits'], fresh: fresh, background: background),
          load: (next) => api.records([...base, 'commits'], next: next),
          itemBuilder: (context, value) => ListTile(
            minTileHeight: 56,
            leading: Monogram(valueText(value, 'author_name', '?'), size: 32),
            title: Text(isolated(valueText(value, 'title')), maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${valueText(value, 'short_id')} · ${valueText(value, 'author_name')} · '
              '${relativeDate(valueText(value, 'created_at'))}'),
            onTap: () => open.commit(context, '${project.id}', valueText(value, 'id')),
          ),
        )),
      ),
      const Divider(height: 1),
      ListTile(
        key: const ValueKey('mr-pipelines-entry'),
        leading: const Icon(Icons.account_tree_outlined),
        title: Text(l10n.pipelines),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => push(l10n.mergeRequestPipelines(iid), RecordsFeed(
          identity: '${base.join('/')}/pipelines',
          account: account,
          resourceLabel: l10n.mergeRequestPipelinesPath(project.path, iid),
          onSwitchAccount: endSessionFrom(context),
          empty: l10n.noPipelines2,
          grouped: true,
          cached: ({required bool fresh, required bool background}) => api.cachedRecords([...base, 'pipelines'], fresh: fresh, background: background),
          load: (next) => api.records([...base, 'pipelines'], next: next),
          itemBuilder: (context, value) => pipelineRow(context, value,
            onTap: () => open.pipeline(context, '${project.id}', valueInt(value, 'id'))),
        )),
      ),
    ])));
  }
}

String _branchValue(String name) => encodeChoices([PickerChoice(id: name, name: name)]);

List<String> _extractLabels(Json data) {
  final raw = data['labels'];
  final names = <String>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) {
        names.add(item.trim());
      } else if (item is Map && item['name'] is String) {
        final name = (item['name'] as String).trim();
        if (name.isNotEmpty) names.add(name);
      }
    }
  } else if (raw is String) {
    names.addAll(raw.split(',').map((part) => part.trim()).where((part) => part.isNotEmpty));
  }
  return names;
}

String _labelsValue(Json data) {
  final names = _extractLabels(data);
  return encodeChoices([for (final name in names) PickerChoice(id: name, name: name)]);
}

String _peopleValue(List<Json> users) => encodeChoices([
  for (final user in users)
    if (valueInt(user, 'id') > 0) PickerChoice(id: '${valueInt(user, 'id')}', name: valueText(user, 'name').isEmpty ? valueText(user, 'username') : valueText(user, 'name'), username: valueText(user, 'username').isEmpty ? null : valueText(user, 'username')),
]);

String _milestoneValue(Json data) {
  final milestone = valueObject(data, 'milestone');
  final id = valueInt(milestone, 'id');
  if (id <= 0) return '';
  return encodeChoices([PickerChoice(id: '$id', name: valueText(milestone, 'title'))]);
}

final _draftPrefix = RegExp(r'^\s*(\[draft\]|\(draft\)|draft:|draft\s+-|\[wip\]|wip:)\s*', caseSensitive: false);

/// GitLab marks a merge request as draft by its title prefix; toggling adds
/// `Draft: ` or strips every prefix GitLab recognises, which may be stacked.
String toggledDraftTitle(String title, bool isDraft) {
  if (!isDraft) return 'Draft: ${title.trim()}';
  var stripped = title;
  for (var next = stripped.replaceFirst(_draftPrefix, ''); next != stripped; next = stripped.replaceFirst(_draftPrefix, '')) {
    stripped = next;
  }
  return stripped.trim();
}

bool mergeSquashEnforced(Json data) {
  final option = data['squash_option'];
  return option == 'always' || option == 'never';
}

bool mergeSquashDefault(Json data) {
  if (data['squash_option'] == 'always') { return true; }
  if (data['squash_option'] == 'never') { return false; }
  if (data.containsKey('squash_on_merge')) { return data['squash_on_merge'] == true; }
  return data['squash'] == true;
}

bool mergeRemoveSourceBranchDefault(Json data) =>
  data['force_remove_source_branch'] == true || data['should_remove_source_branch'] == true;

String mergeStatusLabel(Json data) {
  if (isAutoMergeEnabled(data)) {
    final user = valueText(valueObject(data, 'merge_user'), 'username');
    return user.isNotEmpty ? l10n.autoMergeScheduledByUser(user) : l10n.autoMergeScheduled;
  }
  final token = valueText(data, 'detailed_merge_status');
  return switch (token) {
    'mergeable' => l10n.canBeMerged,
    'checking' || 'unchecked' || 'preparing' || 'approvals_syncing' || 'commits_status' => l10n.checkingMergeStatus,
    'ci_must_pass' => l10n.waitingForCi,
    'ci_still_running' => l10n.ciRunning,
    'conflict' => l10n.hasMergeConflicts,
    'need_rebase' => l10n.needsRebase,
    'not_approved' => l10n.waitingForApproval,
    'discussions_not_resolved' => l10n.unresolvedThreads,
    'draft_status' => l10n.draftStatus,
    'blocked_status' => l10n.blockedByAnotherMr,
    'broken_status' => l10n.sourceBranchProblem,
    'external_status_checks' => l10n.waitingForExternalChecks,
    'policies_denied' => l10n.policyNotAllowed,
    'jira_association_missing' => l10n.missingJiraLink,
    'requested_changes' => l10n.changesRequested,
    'not_open' => l10n.statusClosed,
    '' => l10n.waitingForGitlabChecks,
    _ => l10n.statusToken(token),
  };
}
