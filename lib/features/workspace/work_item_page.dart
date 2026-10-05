import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_types.dart';
import '../../shared/external_link.dart';
import '../../shared/resource_share.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/markdown_view.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/workspace_ui.dart';
import 'ci_page.dart';
import 'diff_page.dart';
import 'editor.dart';
import 'navigation.dart';
import 'picker_sheet.dart';
import 'reactions.dart';
import 'records_feed.dart';
import 'discussions_tab.dart';
import 'draft_review_page.dart';
import 'work_item_filters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../auth/session_controller.dart';
import 'graph_work_items_page.dart';
import 'rest_issue_graph_bridge.dart';
import '../../shared/theme.dart';
export 'discussions_tab.dart';

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
  String get itemTitle => mr ? '合併請求' : type.title;

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
      const EditField('title', '標題', required: true),
      if (mr) ...[const EditField.picker('source_branch', '來源分支', source: PickerSource.branches, required: true), EditField.picker('target_branch', '目標分支', source: PickerSource.branches, required: true, value: _branchValue(branch))],
      const EditField('description', '說明', lines: 7, hint: '支援 Markdown', markdown: true),
      if (!mr && ownerType == ProjectWorkItemType.incident) const EditField.choice('severity', '嚴重度', required: true, value: 'unknown', choices: [EditChoice('unknown', '未分級'), EditChoice('low', '低'), EditChoice('medium', '中'), EditChoice('high', '高'), EditChoice('critical', '嚴重')]),
      const EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true, hint: '不存在的名稱會在儲存時建立'),
      const EditField.picker('assignee_ids', '指派', source: PickerSource.members, multi: true),
      if (mr) const EditField.picker('reviewer_ids', '審查者', source: PickerSource.members, multi: true),
      const EditField.picker('milestone_id', '里程碑', source: PickerSource.milestones, multi: false, hint: '可選里程碑'),
      if (!mr) const EditField.toggle('confidential', '機密議題', hint: '僅專案成員與被指派者可見此議題'),
    ];
    final saved = await openEditor(
      context,
      account: account,
      api: api,
      projectId: project.id,
      projectPath: project.path,
      title: mr ? '新增合併請求' : ownerType.createTitle,
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
      empty: mr ? '沒有符合的合併請求' : type.emptyLabel,
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
                  hintText: mr ? '搜尋合併請求' : type.searchHint,
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
              tooltip: '篩選與排序',
              onPressed: _openFilters,
              icon: _filters.activeCount(mergeRequest: mr) == 0
                  ? const Icon(Icons.tune)
                  : Badge.count(
                      count: _filters.activeCount(mergeRequest: mr),
                      child: const Icon(Icons.tune),
                    ),
            ),
            IconButton(tooltip: mr ? '新增合併請求' : type.createTitle, onPressed: widget.project.archived == true ? null : _create, icon: const Icon(Icons.add_circle_outline)),
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
              for (final e in const {'opened': '開啟中', 'closed': '已關閉', 'all': '全部'}.entries) ChoiceChip(label: Text(e.value), selected: _state == e.key, showCheckmark: false, onSelected: (_) => setState(() => _state = e.key)),
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
      mr ? '請選擇合併請求' : '請選擇${type.title}',
      icon: mr
          ? Icons.merge
          : switch (type) {
              ProjectWorkItemType.issue => Icons.adjust,
              ProjectWorkItemType.task => Icons.task_alt,
              ProjectWorkItemType.incident => Icons.warning_amber_rounded,
            },
      detail: mr ? '從左側清單選擇合併請求以查看變更與審查狀態。' : type.selectionHint,
    ),
  );

  @override
  Widget build(BuildContext context) => ListDetailScaffold<int>(controller: _selection, listBuilder: _buildList, detailBuilder: _buildDetail, emptyBuilder: _buildEmpty, twoPaneConsumesBack: true);
}

/// Shared issue / merge-request row: state-tinted mark, title, then a meta row
/// with the status badge, the mono `#iid`, branches for MRs and the update time.
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
    title: Text(valueText(value, 'title')),
    subtitle: project == null || project.isEmpty ? null : Text(project),
    body: branch == null && labelRow == null ? null : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ?branch,
      if (branch != null && labelRow != null) const SizedBox(height: 6),
      ?labelRow,
    ]),
    meta: [
      StatusBadge(state),
      if (mr && value['draft'] == true) const MetaChip('草稿', icon: Icons.edit_note),
      if (isConfidential)
        const MetaChip('機密', icon: Icons.lock_outline),
      if (milestoneTitle.isNotEmpty)
        MetaChip(milestoneTitle, icon: Icons.tour_outlined),
      if (mr && pipeline.isNotEmpty) StatusBadge(pipeline),
      if (mr && isAutoMergeEnabled(value))
        const MetaChip('自動合併', icon: Icons.schedule_send),
      if (mr && value['has_conflicts'] == true) const MetaChip('衝突', icon: Icons.warning_amber_rounded),
      MetaChip(iid, mono: true),
      if (taskCount > 0) MetaChip('${valueInt(tasks, 'completed_count')}/$taskCount', icon: Icons.checklist),
      if (due.isNotEmpty) MetaChip('到期 $due', icon: Icons.event_outlined),
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
  State<WorkItemPage> createState() => _WorkItemPageState();
}

class _WorkItemPageState extends State<WorkItemPage> with SingleTickerProviderStateMixin {
  Json? _data;
  Json? _approvalsData;
  IncidentStatusSnapshot? _incidentStatus;
  ApiFailure? _incidentStatusError;
  ApiFailure? _error;
  bool _loading = true, _busy = false;
  int _epoch = 0, _generation = 0;
  int _graphEpoch = 0, _graphReadyEpoch = 0;
  final _chrome = ScrollChromeController();
  final Set<Route<dynamic>> _ownedRoutes = {};
  NavigatorState? _navigator;
  late TabController _tabs = _newTabs();
  bool get mr => widget.resource == 'merge_requests';
  ProjectWorkItemType get type => mr ? ProjectWorkItemType.issue : widget.type;
  List<String> get path => ['projects', '${widget.project.id}', widget.resource, '${widget.iid}'];
  String get label => '${mr ? '!' : '#'}${widget.iid}';
  Uri get web => widget.account.instance.projectWeb('${widget.project.path}/-/${widget.resource}/${widget.iid}');
  TabController _newTabs() => TabController(length: mr ? 4 : 2, vsync: this)..addListener(_chrome.show);

  @override
  void initState() { super.initState(); unawaited(_load()); }

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

  ({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) get _owner => (account: widget.account, api: widget.api, project: widget.project, resource: widget.resource, iid: widget.iid, type: type, generation: _generation);

  bool _currentOwner(({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) owner) => mounted && owner.generation == _generation && widget.account.key == owner.account.key && identical(widget.api, owner.api) && widget.project.id == owner.project.id && widget.resource == owner.resource && widget.iid == owner.iid && type == owner.type;

  List<String> _ownerPath(({Account account, GitLabApi api, Project project, String resource, int iid, ProjectWorkItemType type, int generation}) owner) => ['projects', '${owner.project.id}', owner.resource, '${owner.iid}'];

  @override
  void didUpdateWidget(covariant WorkItemPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.account.key != widget.account.key || oldWidget.project.id != widget.project.id || oldWidget.resource != widget.resource || oldWidget.iid != widget.iid || oldWidget.type != widget.type || !identical(oldWidget.api, widget.api);
    if (!changed) return;
    final oldMr = oldWidget.resource == 'merge_requests';
    _generation++;
    _epoch++;
    _dismissRoutes();
    _data = null;
    _approvalsData = null;
    _incidentStatus = null;
    _incidentStatusError = null;
    _error = null;
    _busy = false;
    _loading = true;
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
    _dismissRoutes();
    _tabs.dispose();
    _chrome.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final owner = _owner;
    final ownerPath = _ownerPath(owner);
    final epoch = ++_epoch;
    final graphEpoch = ++_graphEpoch;
    if (mounted) { setState(() { _loading = true; _error = null; }); }
    try {
      final data = await owner.api.record(ownerPath);
      if (owner.resource != 'merge_requests') {
        validateWorkItemIdentity(data, expectedType: owner.type, expectedProjectId: owner.project.id);
      }
      Json? approvals;
      IncidentStatusSnapshot? incidentStatus;
      ApiFailure? incidentStatusError;
      if (owner.resource == 'merge_requests') {
        try {
          approvals = await owner.api.record([...ownerPath, 'approvals']);
        } catch (_) {
          // fail-soft if approvals not supported
        }
      } else if (owner.type == ProjectWorkItemType.incident) {
        try {
          final raw = await owner.api.incidentStatus(owner.project, owner.iid);
          incidentStatus = IncidentStatusSnapshot.fromJson(raw, expectedProjectId: owner.project.id, expectedIid: owner.iid);
        } catch (error) {
          incidentStatusError = safeFailure(error);
        }
      }
      if (_currentOwner(owner) && epoch == _epoch) {
        setState(() {
          _data = data;
          _approvalsData = approvals;
          _incidentStatus = incidentStatus;
          _incidentStatusError = incidentStatusError;
          _graphReadyEpoch = graphEpoch;
        });
      }
    } catch (e) { if (mounted && epoch == _epoch) { setState(() => _error = safeFailure(e)); } } finally { if (mounted && epoch == _epoch) { setState(() => _loading = false); } }
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
    unawaited(_load());
  }

  Future<void> _loadAfterMutation() async {
    final expectedEpoch = _epoch + 1;
    await _load();
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
      EditField('title', '標題', required: true, value: valueText(data, 'title')),
      EditField('description', '說明', lines: 8, markdown: true, value: valueText(data, 'description')),
      if (owner.type == ProjectWorkItemType.incident) EditField.choice('severity', '嚴重度', required: true, value: incidentSeverityFromJson(data)?.apiValue ?? valueText(data, 'severity'), choices: const [EditChoice('unknown', '未分級'), EditChoice('low', '低'), EditChoice('medium', '中'), EditChoice('high', '高'), EditChoice('critical', '嚴重')]),
      EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true, value: _labelsValue(data), hint: '留白會移除所有標籤'),
      EditField.picker('assignee_ids', '指派', source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'assignees'))),
      if (mr) EditField.picker('reviewer_ids', '審查者', source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'reviewers'))),
      EditField.picker('milestone_id', '里程碑', source: PickerSource.milestones, multi: false, value: _milestoneValue(data), hint: '留白會移除里程碑'),
      if (!mr) EditField.toggle('confidential', '機密議題', value: valueBool(data, 'confidential') ? 'true' : 'false', hint: '僅專案成員與被指派者可見此議題'),
    ];
    final saved = await openEditor(
      context,
      account: owner.account,
      api: owner.api,
      projectId: owner.project.id,
      projectPath: owner.project.path,
      title: '編輯 ${owner.resource == 'merge_requests' ? '!' : '#'}${owner.iid}',
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
        await owner.api.writeRecord('PUT', ownerPath, body);
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
    final field = EditField.picker('assignee_ids', '指派成員', source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'assignees')), hint: '留白會移除所有指派成員');
    final saved = await openEditor(
      context,
      account: owner.account,
      api: owner.api,
      projectId: owner.project.id,
      projectPath: owner.project.path,
      title: '修改指派 · ${owner.resource == 'merge_requests' ? '!' : '#'}${owner.iid}',
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
        await owner.api.writeRecord('PUT', ownerPath, body);
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
    final field = EditField.picker('reviewer_ids', '審查者名單', source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'reviewers')), hint: '留白會移除所有審查者');
    final saved = await openEditor(
      context,
      account: owner.account,
      api: owner.api,
      projectId: owner.project.id,
      projectPath: owner.project.path,
      title: '修改審查者 · !${owner.iid}',
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
        await owner.api.writeRecord('PUT', ownerPath, body);
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
    final picked = await showChoicePicker(context, api: owner.api, account: owner.account, projectId: owner.project.id, source: PickerSource.labels, multi: true, title: '選擇標籤 · $label', initial: initialChoices, onRoute: _ownRoute);
    if (picked == null || !_currentOwner(owner)) return;
    setState(() => _busy = true);
    try {
      final current = await owner.api.record(ownerPath);
      if (!_currentOwner(owner)) return;
      if (current['updated_at'] != data['updated_at']) {
        throw const ApiFailure(FailureKind.conflict);
      }
      final newLabels = picked.map((c) => c.name).join(', ');
      await owner.api.writeRecord('PUT', ownerPath, {'labels': newLabels});
      if (!mounted || !_currentOwner(owner)) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('標籤已更新')));
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
      await owner.api.writeRecord('PUT', ownerPath, {'labels': remaining});
      if (!mounted || !_currentOwner(owner)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已移除標籤「$labelToRemove」')));
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
      'delete' => ('刪除 $label？', '將刪除此項目與相關討論，無法復原。', label),
      'approve' => ('批准目前版本？', '$label · ${shortSha(valueText(data, 'sha'))}\n仍受專案批准與重新認證政策限制。', null),
      'rebase' => ('Rebase 分支？', '將此合併請求來源分支 Rebase 至目標分支。', null),
      _ => null,
    };
    var squash = false;
    var removeSourceBranch = false;
    var autoMerge = false;
    var stillDraft = false;
    if (action == 'cancel_auto_merge') {
      if (!await confirmAction(context, '取消自動合併？', '取消後將不再於流水線通過時自動合併此變更。', onRoute: _ownRoute)) { return; }
      if (!_currentOwner(owner)) {
        return;
      }
      setState(() => _busy = true);
      try {
        await owner.api.cancelAutoMerge(owner.project.id, owner.iid);
        if (!_currentOwner(owner)) return;
        await _loadAfterMutation();
        if (!mounted || !_currentOwner(owner)) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已取消自動合併')));
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
          await owner.api.removeRecord(ownerPath);
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
          await owner.api.writeRecord('PUT', ownerPath, {'state_event': action});
        case 'assign':
          final ids = valueObjects(data, 'assignees').map((v) => valueInt(v, 'id')).where((id) => id > 0).toSet();
          ids.contains(owner.account.user.id) ? ids.remove(owner.account.user.id) : ids.add(owner.account.user.id);
          await owner.api.writeRecord('PUT', ownerPath, {'assignee_ids': ids.toList()});
        case 'todo':
          await owner.api.writeRecord('POST', [...ownerPath, 'todo'], {});
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
            final updated = await owner.api.writeRecord('PUT', ownerPath, {'title': next});
            stillDraft = wasDraft && updated['draft'] == true;
          }
        case 'approve':
          await owner.api.approveMergeRequest(owner.project.id, owner.iid, requiredString(data, 'sha'));
        case 'unapprove':
          await owner.api.writeRecord('POST', [...ownerPath, 'unapprove'], {});
        case 'rebase':
          await owner.api.rebaseMergeRequest(owner.project.id, owner.iid);
        case 'merge':
          await owner.api.mergeRequest(owner.project.id, owner.iid, requiredString(data, 'sha'), squash: squash, removeSourceBranch: removeSourceBranch, autoMerge: autoMerge);
      }
      if (!_currentOwner(owner)) return;
      await _loadAfterMutation();
      if (_currentOwner(owner) && action == 'rebase') {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已請求 Rebase 分支')));
      }
      if (_currentOwner(owner) && stillDraft) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('GitLab 仍將此合併請求視為草稿：標題沒有可移除的草稿標記，請編輯標題或在 GitLab 網頁標示為可審查。')));
      }
      if (_currentOwner(owner) && action == 'merge') {
        final merged = _data?['state'] == 'merged';
        final autoScheduled = isAutoMergeEnabled(_data ?? {});
        final message = merged
            ? '已合併'
            : (autoScheduled
                ? '已排程自動合併，等待流水線完成。'
                : 'GitLab 已接受操作，請查看最新合併狀態。');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (!mounted || !_currentOwner(owner)) return;
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
          title: Text(autoMerge ? '排程自動合併 $label？' : '合併 $label？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${valueText(data, 'source_branch')} → ${valueText(data, 'target_branch')}\n'
                  '版本 ${shortSha(valueText(data, 'sha'))}\n若版本變動會停止，不會自動改用新版本。',
                ),
                const SizedBox(height: 8),
                if (autoCandidate) SwitchListTile(key: const ValueKey('merge-auto'), contentPadding: EdgeInsets.zero, minTileHeight: 48, title: const Text('流水線成功時自動合併 (MWPS)'), subtitle: const Text('當所有檢查與 CI 通過後自動合併'), value: autoMerge, onChanged: (value) => setDialog(() => autoMerge = value)),
                SwitchListTile(key: const ValueKey('merge-squash'), contentPadding: EdgeInsets.zero, minTileHeight: 48, title: const Text('Squash 提交'), subtitle: squashLocked ? const Text('專案設定強制此選項') : null, value: squash, onChanged: squashLocked ? null : (value) => setDialog(() => squash = value)),
                SwitchListTile(key: const ValueKey('merge-remove-branch'), contentPadding: EdgeInsets.zero, minTileHeight: 48, title: const Text('合併後刪除來源分支'), value: removeSourceBranch, onChanged: (value) => setDialog(() => removeSourceBranch = value)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, (squash: squash, removeSourceBranch: removeSourceBranch, autoMerge: autoMerge)), child: Text(autoMerge ? '排程自動合併' : '確認')),
          ],
        ),
      ),
    );
    _ownRoute(route);
    return navigator.push(route);
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
      final label = state == 'merged' ? '已合併' : '已關閉';
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
              if (autoScheduled) ...[const SizedBox(height: 6), const Text('流水線通過後將自動執行合併。', style: TextStyle(fontSize: 12))],
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
                          '尚有未解決的討論，解決後方可合併',
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
                            child: Text(isThresholdReached ? '已達核准門檻（${approvedBy.length} 人已批准）' : '審查核准進度：已批准 ${approvedBy.length} 人${approvalsRequired > 0 ? ' · 尚需 $approvalsLeft 人' : ''}', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      if (approvedBy.isNotEmpty) ...[const SizedBox(height: 4), Text('已核准：${approvedBy.map((v) => '@${valueText(valueObject(v, 'user'), 'username')}').join('、')}', style: Theme.of(context).textTheme.bodySmall)],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(key: const ValueKey('mr-draft-review-btn'), onPressed: _busy ? null : () => _openDraftReview(data), icon: const Icon(Icons.rate_review_outlined, size: 18), label: const Text('審查草稿')),
                  if (hasApproved)
                    OutlinedButton.icon(key: const ValueKey('mr-unapprove-btn'), onPressed: _busy ? null : () => _action('unapprove'), icon: const Icon(Icons.undo, size: 18), label: const Text('撤回我的批准'))
                  else
                    OutlinedButton.icon(key: const ValueKey('mr-approve-btn'), onPressed: _busy ? null : () => _action('approve'), icon: const Icon(Icons.verified_outlined, size: 18), label: const Text('批准')),
                  if (rebaseInProgress)
                    OutlinedButton.icon(
                      key: const ValueKey('mr-rebase-progress-btn'),
                      onPressed: null,
                      icon: const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      label: const Text('Rebase 進行中…'),
                    )
                  else if (canRebase)
                    OutlinedButton.icon(key: const ValueKey('mr-rebase-btn'), onPressed: _busy ? null : () => _action('rebase'), icon: const Icon(Icons.fork_right, size: 18), label: Text(divergedCommits > 0 ? 'Rebase (落後 $divergedCommits)' : 'Rebase')),
                  if (autoScheduled)
                    OutlinedButton.icon(key: const ValueKey('cancel-auto-merge'), onPressed: _busy ? null : () => _action('cancel_auto_merge'), icon: const Icon(Icons.close, size: 18), label: const Text('取消自動合併'))
                  else
                    FilledButton.icon(onPressed: _busy ? null : () => _action('merge'), icon: Icon(autoCandidate ? Icons.schedule_send : Icons.merge, size: 18), label: Text(autoCandidate ? '自動合併…' : '合併')),
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
      '變更事件處理狀態？',
      '事件處理狀態：${fresh.lifecycle.label} → ${next.label}\n'
          '議題狀態仍為${statusLabel(fresh.issueState)}，兩者彼此獨立。',
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
              Text('Incident 狀態', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MetaChip('議題狀態：${statusLabel(valueText(data, 'state'))}', icon: Icons.adjust),
                  if (severity != null) MetaChip('嚴重度：${severity.label}', icon: Icons.priority_high),
                  if (status != null) MetaChip('事件處理狀態：${status.lifecycle.label}', icon: Icons.crisis_alert_outlined),
                ],
              ),
              if (status == null) ...[
                const SizedBox(height: 10),
                Text(error?.kind == FailureKind.unsupported ? '此 GitLab 實例未提供可用的事件處理狀態。議題內容仍可正常查看與編輯。' : '事件處理狀態暫時無法取得。議題內容仍可正常查看與編輯。', key: const ValueKey('incident-lifecycle-unavailable'), style: Theme.of(context).textTheme.bodySmall),
                TextButton.icon(onPressed: _loading || _busy ? null : _load, icon: const Icon(Icons.refresh, size: 18), label: const Text('重試事件狀態')),
              ] else ...[
                const SizedBox(height: 10),
                Text('事件處理狀態不會自動關閉或重新開啟議題。', style: Theme.of(context).textTheme.bodySmall),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(subscribed ? '已開啟通知' : '已關閉通知')));
      // A failed refresh must not erase a confirmed subscription write.
      await _load();
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
    if (due.isNotEmpty) add(Icons.event_outlined, '到期日', due);
    final time = valueObject(data, 'time_stats');
    final estimate = valueText(time, 'human_time_estimate'), spent = valueText(time, 'human_total_time_spent');
    if (estimate.isNotEmpty || spent.isNotEmpty) {
      add(Icons.timer_outlined, '工時', '已花費 ${spent.isEmpty ? '0' : spent} · 預估 ${estimate.isEmpty ? '未設定' : estimate}');
    }
    if (data['weight'] is int) add(Icons.fitness_center, '權重', '${data['weight']}');
    if (data['discussion_locked'] == true) add(Icons.lock_outline, '討論', '已鎖定，只有成員可留言');
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
            title: const Text('通知'),
            subtitle: Text(subscribed ? '有新動態時通知我' : '不接收此項目的通知'),
            value: subscribed,
            onChanged: _busy ? null : _subscribe,
          ),
        );
    }
    return rows;
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
            Text('指派', style: Theme.of(context).textTheme.titleSmall),
            TextButton.icon(
              key: const ValueKey('quick-edit-assignees'),
              onPressed: _busy ? null : _editAssignees,
              icon: const Icon(Icons.group_add_outlined, size: 16),
              label: const Text('修改名單'),
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
              InputChip(key: const ValueKey('quick-unassign-me'), avatar: const Icon(Icons.check_circle, size: 16), label: const Text('已指派給我'), selected: true, showCheckmark: false, onDeleted: _busy ? null : () => _action('assign'), deleteIcon: const Icon(Icons.close, size: 14), deleteButtonTooltipMessage: '取消指派給我', onPressed: _busy ? null : () => _action('assign'))
            else
              ActionChip(key: const ValueKey('quick-assign-me'), avatar: const Icon(Icons.person_add_alt_1, size: 16), label: const Text('指派給我'), onPressed: _busy ? null : () => _action('assign')),
            ...assignees.where((u) => valueInt(u, 'id') != myId).map((u) {
              final username = valueText(u, 'username');
              final name = valueText(u, 'name');
              return Chip(
                avatar: CircleAvatar(radius: 12, child: Text((username.isNotEmpty ? username[0] : '?').toUpperCase(), style: const TextStyle(fontSize: 10))),
                label: Text(name.isNotEmpty ? '$name (@$username)' : '@$username'),
              );
            }),
            if (assignees.isEmpty && !isAssignedToMe)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('尚未指派成員', style: Theme.of(context).textTheme.bodySmall),
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
            Text('審查者', style: Theme.of(context).textTheme.titleSmall),
            TextButton.icon(
              key: const ValueKey('quick-edit-reviewers'),
              onPressed: _busy ? null : _editReviewers,
              icon: const Icon(Icons.person_search_outlined, size: 16),
              label: const Text('修改審查者'),
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
              return Chip(
                avatar: CircleAvatar(radius: 12, child: Text((username.isNotEmpty ? username[0] : '?').toUpperCase(), style: const TextStyle(fontSize: 10))),
                label: Text(name.isNotEmpty ? '$name (@$username)' : '@$username'),
              );
            }),
            if (reviewers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('尚未指定審查者', style: Theme.of(context).textTheme.bodySmall),
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
            Text('標籤', style: Theme.of(context).textTheme.titleSmall),
            TextButton.icon(
              key: const ValueKey('quick-edit-labels'),
              onPressed: _busy ? null : _editLabelsQuick,
              icon: const Icon(Icons.label_outline, size: 16),
              label: const Text('管理標籤'),
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
            for (final label in labels) InputChip(key: ValueKey('label-chip-$label'), label: Text(label), onPressed: _busy ? null : _editLabelsQuick, onDeleted: _busy ? null : () => _removeLabelQuick(label), deleteIcon: const Icon(Icons.close, size: 14), deleteButtonTooltipMessage: '移除標籤 $label'),
            ActionChip(key: const ValueKey('quick-add-label'), avatar: const Icon(Icons.add, size: 16), label: const Text('新增標籤'), onPressed: _busy ? null : _editLabelsQuick),
            if (labels.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('尚未設定標籤', style: Theme.of(context).textTheme.bodySmall),
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
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 19)),
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
        IconButton(tooltip: '重新整理', onPressed: _loading || _busy ? null : _load, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(
          tooltip: '更多操作',
          enabled: !_busy && data != null,
          onSelected: _action,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('編輯')),
            if (data?['state'] == 'opened') PopupMenuItem(value: 'close', child: Text(type == ProjectWorkItemType.incident ? '關閉議題狀態' : '關閉')),
            if (mr && data?['state'] == 'opened') PopupMenuItem(value: 'draft', child: Text(data?['draft'] == true ? '標示為可審查' : '標示為草稿')),
            if (data?['state'] == 'closed') PopupMenuItem(value: 'reopen', child: Text(type == ProjectWorkItemType.incident ? '重新開啟議題狀態' : '重新開啟')),
            PopupMenuItem(value: 'assign', child: Text(valueObjects(data ?? {}, 'assignees').any((v) => v['id'] == widget.account.user.id) ? '取消指派給我' : '指派給我')),
            const PopupMenuItem(value: 'todo', child: Text('加入我的待辦')),
            const PopupMenuItem(value: 'web', child: Text('在 GitLab 開啟')),
            const PopupMenuItem(value: 'delete', child: Text('刪除')),
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
                            onRetry: _load,
                            account: widget.account,
                            resourceLabel: '${widget.project.path} · $label',
                            onSwitchAccount: endSessionFrom(context, ResumeTarget(projectId: widget.project.id, projectPath: widget.project.path, resource: widget.resource, iid: widget.iid)),
                          ),
                        )
                      : const ListSkeleton(),
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
                        padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(valueText(data, 'title'), minLines: 1, maxLines: 4, style: theme.textTheme.titleLarge?.copyWith(height: 1.3)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                StatusBadge(valueText(data, 'state')),
                                if (!mr && type != ProjectWorkItemType.issue) MetaChip(type.title, icon: type == ProjectWorkItemType.task ? Icons.task_alt : Icons.warning_amber_rounded),
                                if (data['draft'] == true) const MetaChip('草稿', icon: Icons.edit_note),
                                if (valueBool(data, 'confidential')) const MetaChip('機密', icon: Icons.lock_outline),
                                if (valueObject(data, 'milestone').isNotEmpty) MetaChip(valueText(valueObject(data, 'milestone'), 'title'), icon: Icons.tour_outlined),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Monogram(authorName, size: 18),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        '@${valueText(author, 'username')}${created.isEmpty ? '' : ' · $created'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                                      ),
                                    ),
                                  ],
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
                TabBar(
                  controller: _tabs,
                  indicatorSize: TabBarIndicatorSize.tab,
                  isScrollable: crowded,
                  tabAlignment: crowded ? TabAlignment.start : null,
                  tabs: [
                    const Tab(text: '摘要'),
                    if (mr) const Tab(text: '變更'),
                    const Tab(text: '討論'),
                    if (mr) const Tab(text: '檢查'),
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
                              onRetry: _load,
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
                                  if (valueText(data, 'changes_count').isNotEmpty) MetaChip('${valueText(data, 'changes_count')} 個檔案', icon: Icons.difference_outlined),
                                ],
                              ),
                            ),
                          _RestDescription(
                            valueText(data, 'description').isEmpty ? '尚未填寫說明。' : valueText(data, 'description'),
                            key: ValueKey('rest-description/${owner.account.key}/${owner.project.id}/${owner.resource}/${owner.iid}/${owner.generation}'),
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
                                    Text('里程碑', style: Theme.of(context).textTheme.titleSmall),
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
                                        if (valueText(valueObject(data, 'milestone'), 'due_date').isNotEmpty) Text('（到期日：${valueText(valueObject(data, 'milestone'), 'due_date')}）', style: Theme.of(context).textTheme.bodySmall),
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
                              child: _RelatedIssueItems(account: widget.account, api: widget.api, project: widget.project, iid: widget.iid),
                            ),
                          if (mr) _MergeRequestHistory(account: widget.account, api: widget.api, project: widget.project, iid: widget.iid),
                          const SizedBox(height: 12),
                          Text([if (valueText(data, 'created_at').isNotEmpty) '建立於 ${relativeDate(valueText(data, 'created_at'))}', '更新於 ${relativeDate(valueText(data, 'updated_at'))}'].join(' · '), style: Theme.of(context).textTheme.bodySmall),
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
    required this.base,
    required this.api,
    required this.projectId,
    required this.projectWeb,
    required this.projectPath,
  });
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
    final head = text.characters.take(_previewWindow + 1);
    final normalized = head
        .take(_previewWindow)
        .toString()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .characters;
    final shown = normalized.take(_previewLength).toString().trimRight();
    return head.length > _previewWindow || normalized.length > _previewLength
        ? '$shown…'
        : shown;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    updateKeepAlive();
  }

  Widget _markdown() => MarkdownView(
    widget.text,
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
            child: Text(_expanded ? '收合說明' : '展開完整說明'),
          ),
        ),
        const SizedBox(height: 4),
        if (_expanded)
          _markdown()
        else ...[
          Text(
            _preview,
            key: const ValueKey('work-item-description-preview'),
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          Text(
            '說明較長（共 $_runes 字元），目前僅顯示開頭摘要。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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
  @override
  void initState() { super.initState(); _approvals = widget.api.record([...widget.path, 'approvals']); }

  @override
  void didUpdateWidget(covariant _MergeChecks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) { _approvals = widget.api.record([...widget.path, 'approvals']); }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('合併條件', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      Text(mergeStatusLabel(widget.data)),
      const SizedBox(height: 12),
      Text(
        '版本 ${shortSha(valueText(widget.data, 'sha'))}',
        style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace']),
      ),
      if (widget.data['head_pipeline'] is Json) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: StatusBadge(valueText(valueObject(widget.data, 'head_pipeline'), 'status'))),
      const Divider(height: 32),
      Text('審查', style: Theme.of(context).textTheme.titleMedium),
      FutureBuilder<Json>(
        future: _approvals,
        builder: (context, snap) {
          if (snap.hasError) {
            return FailureNotice(
              safeFailure(snap.error!),
              account: widget.account,
              resourceLabel: '合併檢查',
              onSwitchAccount: endSessionFrom(context),
              onRetry: () => setState(() {
        _approvals = widget.api.record([...widget.path, 'approvals']);
      }),
            );
          }
          if (!snap.hasData) { return const ListSkeleton(); }
          final approved = valueObjects(snap.data!, 'approved_by');
          return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(approved.isEmpty ? '尚無批准者'
        : approved.map((v) => '@${valueText(valueObject(v, 'user'), 'username')}').join('、')));
        },
      ),
      if (widget.data['state'] == 'opened') ...[
        OutlinedButton.icon(onPressed: widget.busy ? null : () => widget.act('approve'), icon: const Icon(Icons.verified_outlined), label: const Text('批准目前版本')),
        TextButton(onPressed: widget.busy ? null : () => widget.act('unapprove'), child: const Text('撤回我的批准')),
        const SizedBox(height: 16),
        if (isAutoMergeEnabled(widget.data))
          OutlinedButton.icon(key: const ValueKey('cancel-auto-merge-checks'), onPressed: widget.busy ? null : () => widget.act('cancel_auto_merge'), icon: const Icon(Icons.close), label: const Text('取消自動合併'))
        else
          FilledButton.icon(onPressed: widget.busy ? null : () => widget.act('merge'), icon: Icon(canAutoMerge(widget.data) ? Icons.schedule_send : Icons.merge), label: Text(canAutoMerge(widget.data) ? '自動合併…' : '合併…')),
        const SizedBox(height: 12),
        const Text('GitLab 會再次檢查 SHA、權限、保護分支及所有合併條件。', style: TextStyle(fontSize: 12)),
      ],
    ],
  );
}

/// Merge requests that mention or close an issue, and its linked issues.
class _RelatedIssueItems extends StatefulWidget {
  const _RelatedIssueItems({required this.account, required this.api, required this.project, required this.iid});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
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

  Future<void> _load() async {
    final epoch = ++_epoch;
    final base = ['projects', '${widget.project.id}', 'issues', '${widget.iid}'];
    if (_error != null) setState(() => _error = null);
    try {
      final results = await Future.wait([
        widget.api.records([...base, 'related_merge_requests']),
        widget.api.records([...base, 'links']),
      ]);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _mergeRequests = results[0].items;
        _links = results[1].items;
      });
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = safeFailure(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return FailureNotice(error, account: widget.account, onRetry: _load, onSwitchAccount: endSessionFrom(context),
        resourceLabel: '${widget.project.path} · #${widget.iid} 相關合併請求與關聯議題');
    }
    if (_mergeRequests.isEmpty && _links.isEmpty) return const SizedBox.shrink();
    final open = ResourceNavigator(widget.account, widget.api);
    final theme = Theme.of(context);
    Widget row(Json item, {required bool mr}) {
      final linkType = valueText(item, 'link_type');
      final relation = switch (linkType) {
        'blocks' => '阻擋', 'is_blocked_by' => '被阻擋', 'relates_to' => '相關', _ => '',
      };
      return ListTile(
        contentPadding: EdgeInsets.zero,
        minTileHeight: 48,
        leading: Icon(mr ? Icons.merge : Icons.adjust, size: 20),
        title: Text(valueText(item, 'title'), maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(['${mr ? '!' : '#'}${valueInt(item, 'iid')}', statusLabel(valueText(item, 'state')), if (relation.isNotEmpty) relation].join(' · ')),
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
              if (_mergeRequests.isNotEmpty) ...[Text('相關合併請求', style: theme.textTheme.titleSmall), for (final item in _mergeRequests) row(item, mr: true)],
              if (_links.isNotEmpty) ...[if (_mergeRequests.isNotEmpty) const Divider(height: 16), Text('關聯議題', style: theme.textTheme.titleSmall), for (final item in _links) row(item, mr: false)],
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
        title: const Text('提交紀錄'),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => push('!$iid 提交紀錄', RecordsFeed(
          identity: '${base.join('/')}/commits',
          account: account,
          resourceLabel: '${project.path} · !$iid 提交',
          onSwitchAccount: endSessionFrom(context),
          empty: '沒有提交',
          grouped: true,
          load: (next) => api.records([...base, 'commits'], next: next),
          itemBuilder: (context, value) => ListTile(
            minTileHeight: 56,
            leading: Monogram(valueText(value, 'author_name', '?'), size: 32),
            title: Text(valueText(value, 'title'), maxLines: 2, overflow: TextOverflow.ellipsis),
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
        title: const Text('流程'),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => push('!$iid 流程', RecordsFeed(
          identity: '${base.join('/')}/pipelines',
          account: account,
          resourceLabel: '${project.path} · !$iid 流程',
          onSwitchAccount: endSessionFrom(context),
          empty: '沒有 Pipeline',
          grouped: true,
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

bool isAutoMergeEnabled(Json data) {
  final state = valueText(data, 'state');
  if (state == 'merged' || state == 'closed') return false;
  return data['merge_when_pipeline_succeeds'] == true || data['auto_merge_enabled'] == true;
}

bool canAutoMerge(Json data) {
  if (valueText(data, 'state') != 'opened' || isAutoMergeEnabled(data)) return false;
  if (data['draft'] == true || data['work_in_progress'] == true) return false;
  if (data['has_conflicts'] == true || data['merge_status'] == 'cannot_be_merged') return false;

  final status = valueText(data, 'detailed_merge_status');
  if (const ['conflict', 'need_rebase', 'draft_status', 'broken_status', 'not_open', 'cannot_be_merged', 'mergeable'].contains(status)) {
    return false;
  }
  if (status == 'ci_still_running' || status == 'ci_must_pass') return true;

  final pipeline = valueObject(data, 'head_pipeline');
  final pipeStatus = valueText(pipeline, 'status');
  return const ['running', 'pending', 'created', 'waiting_for_resource', 'preparing', 'manual']
      .contains(pipeStatus);
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
    return user.isNotEmpty ? '已由 @$user 排程自動合併' : '已排程自動合併';
  }
  final token = valueText(data, 'detailed_merge_status');
  return switch (token) {
    'mergeable' => '可以合併',
    'checking' || 'unchecked' || 'preparing' || 'approvals_syncing' || 'commits_status' => '正在檢查',
    'ci_must_pass' => '等待 CI 通過',
    'ci_still_running' => 'CI 執行中',
    'conflict' => '有合併衝突',
    'need_rebase' => '需要 rebase',
    'not_approved' => '等待批准',
    'discussions_not_resolved' => '尚有未解決討論',
    'draft_status' => '草稿狀態',
    'blocked_status' => '被其他 MR 阻擋',
    'broken_status' => '來源分支異常',
    'external_status_checks' => '等待外部檢查',
    'policies_denied' => '政策不允許',
    'jira_association_missing' => '缺少 Jira 關聯',
    'requested_changes' => '有變更請求',
    'not_open' => '已關閉',
    '' => '等待 GitLab 檢查',
    _ => '狀態：$token',
  };
}
