import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/external_link.dart';
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
import '../../shared/theme.dart';
export 'discussions_tab.dart';

class WorkItemsTab extends StatefulWidget {
  const WorkItemsTab({super.key, required this.account, required this.api, required this.project, required this.resource});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  @override
  State<WorkItemsTab> createState() => _WorkItemsTabState();
}
class _WorkItemsTabState extends State<WorkItemsTab> {
  late final _selection = ListDetailController<int>();
  final _feed = GlobalKey<RecordsFeedState>();
  final _search = TextEditingController();
  Timer? _debounce;
  String _state = 'opened', _query = '';
  bool get mr => widget.resource == 'merge_requests';
  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _selection.dispose();
    super.dispose();
  }
  void _open(int iid) {
    _selection.select(iid);
  }

  void _applyMutation(Json updated) {
    final state = valueText(updated, 'state');
    final matchesFilter = _state == 'all' || _state == state;
    if (matchesFilter) {
      _feed.currentState?.patchItem(updated);
    } else {
      _feed.currentState?.removeItem('${updated['id'] ?? updated['iid']}');
    }
  }
  Future<void> _create() async {
    var iid = 0;
    Json? createdRecord;
    final branch = widget.project.defaultBranch ?? 'main';
    final fields = <EditField>[
      const EditField('title', '標題', required: true),
      if (mr) ...[
        const EditField.picker('source_branch', '來源分支', source: PickerSource.branches, required: true),
        EditField.picker('target_branch', '目標分支', source: PickerSource.branches, required: true, value: _branchValue(branch)),
      ],
      const EditField('description', '說明', lines: 7, hint: '支援 Markdown', markdown: true),
      const EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true, hint: '不存在的名稱會在儲存時建立'),
      const EditField.picker('assignee_ids', '指派', source: PickerSource.members, multi: true),
      if (mr) const EditField.picker('reviewer_ids', '審查者', source: PickerSource.members, multi: true),
      const EditField.picker('milestone_id', '里程碑', source: PickerSource.milestones, multi: false, hint: '可選里程碑'),
      if (!mr) const EditField.toggle('confidential', '機密議題', hint: '僅專案成員與被指派者可見此議題'),
    ];
    final saved = await openEditor(context, account: widget.account, api: widget.api, projectId: widget.project.id, projectPath: widget.project.path,
      title: mr ? '新增合併請求' : '新增議題', resource: '${widget.project.id}/${widget.resource}/new',
      subtitle: widget.project.path, fields: fields, save: (values) async {
        final body = editorSubmission(fields, values);
        final title = body['title'];
        if (title is String) body['title'] = title.trim();
        if (body['milestone_id'] == null) {
          body.remove('milestone_id');
        }
        final created = mr ? await widget.api.createMergeRequest(widget.project.id, body)
          : await widget.api.createIssue(widget.project.id, body);
        iid = requiredInt(created, 'iid');
        createdRecord = created;
      });
    if (saved && mounted) {
      if (createdRecord != null && (_state == 'all' || _state == 'opened')) {
        _feed.currentState?.prependItem(createdRecord!);
      } else {
        unawaited(_feed.currentState?.refresh() ?? Future<void>.value());
      }
      _open(iid);
    }
  }
  Widget _buildList(BuildContext context, bool isTwoPane, int? selected) {
    return RecordsFeed(key: _feed, identity: '${widget.resource}/$_state/$_query', storageId: widget.resource,
      account: widget.account, resourceLabel: '${widget.project.path} · ${mr ? '合併請求' : '議題'}',
      onSwitchAccount: endSessionFrom(context),
      empty: mr ? '沒有符合的合併請求' : '沒有符合的議題',
      emptyIcon: mr ? Icons.merge : Icons.adjust,
      leading: (context, _) => _listControls(context),
      load: (next) => widget.api.records(['projects', '${widget.project.id}', widget.resource],
        query: {'state': _state, 'scope': 'all', 'order_by': 'updated_at', 'sort': 'desc', 'with_labels_details': 'true',
          if (_query.isNotEmpty) 'search': _query}, next: next),
      itemBuilder: (context, value) {
        final iid = requiredInt(value, 'iid');
        return workItemCard(
          context,
          value,
          mr: mr,
          selected: isTwoPane && selected == iid,
          onTap: () => _open(iid),
        );
      },
    );
  }

  Widget _listControls(BuildContext context) => Column(children: [
    Padding(padding: EdgeInsets.fromLTRB(feedGutter(context), 12, feedGutter(context) - 4, 4), child: Row(children: [
      Expanded(child: TextField(
        controller: _search,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: mr ? '搜尋合併請求' : '搜尋議題',
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
                  _debounce?.cancel();
                  setState(() => _query = '');
                },
              );
            },
          ),
        ),
        onChanged: (value) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), () {
            if (mounted) setState(() => _query = value.trim());
          });
        },
        onSubmitted: (value) {
          _debounce?.cancel();
          setState(() => _query = value.trim());
        },
      )),
      const SizedBox(width: 8), IconButton(tooltip: mr ? '新增合併請求' : '新增議題',
        onPressed: widget.project.archived == true ? null : _create, icon: const Icon(Icons.add_circle_outline)),
    ])),
    Padding(padding: EdgeInsets.symmetric(horizontal: feedGutter(context), vertical: 4), child: Align(
      alignment: Alignment.centerLeft, child: Wrap(spacing: 8, runSpacing: 4, children: [
        for (final e in const {'opened': '開啟中', 'closed': '已關閉', 'all': '全部'}.entries)
          ChoiceChip(label: Text(e.value), selected: _state == e.key, showCheckmark: false,
            onSelected: (_) => setState(() => _state = e.key)),
      ]))),
  ]);

  Widget _buildDetail(BuildContext context, int iid, bool isTwoPane, VoidCallback onBack) => WorkItemPage(
    key: ValueKey('${widget.resource}-$iid'),
    account: widget.account,
    api: widget.api,
    project: widget.project,
    resource: widget.resource,
    iid: iid,
    showBackButton: !isTwoPane,
    onBack: onBack,
    onDeleted: () {
      _selection.clear();
      _feed.currentState?.removeItem('$iid');
    },
    onMutated: _applyMutation,
  );

  Widget _buildEmpty(BuildContext context) => Center(
    child: EmptyState(
      mr ? '請選擇合併請求' : '請選擇議題',
      icon: mr ? Icons.merge : Icons.adjust,
      detail: mr ? '從左側清單選擇合併請求以查看變更與審查狀態。' : '從左側清單選擇議題以查看內容與討論。',
    ),
  );

  @override
  Widget build(BuildContext context) => ListDetailScaffold<int>(
    controller: _selection,
    listBuilder: _buildList,
    detailBuilder: _buildDetail,
    emptyBuilder: _buildEmpty,
    twoPaneConsumesBack: true,
  );
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
  const WorkItemPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.resource,
    required this.iid,
    this.showBackButton = true,
    this.onBack,
    this.onDeleted,
    this.onMutated,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  final int iid;
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
  ApiFailure? _error;
  bool _loading = true, _busy = false;
  int _epoch = 0;
  final _chrome = ScrollChromeController();
  late final TabController _tabs = TabController(length: mr ? 4 : 2, vsync: this)..addListener(_chrome.show);
  bool get mr => widget.resource == 'merge_requests';
  List<String> get path => ['projects', '${widget.project.id}', widget.resource, '${widget.iid}'];
  String get label => '${mr ? '!' : '#'}${widget.iid}';
  Uri get web => widget.account.instance.projectWeb('${widget.project.path}/-/${widget.resource}/${widget.iid}');
  @override
  void initState() { super.initState(); unawaited(_load()); }
  @override
  void dispose() {
    _tabs.dispose();
    _chrome.dispose();
    super.dispose();
  }
  Future<void> _load() async {
    final epoch = ++_epoch;
    if (mounted) { setState(() { _loading = true; _error = null; }); }
    try {
      final data = await widget.api.record(path);
      Json? approvals;
      if (mr) {
        try {
          approvals = await widget.api.record([...path, 'approvals']);
        } catch (_) {
          // fail-soft if approvals not supported
        }
      }
      if (mounted && epoch == _epoch) {
        setState(() {
          _data = data;
          _approvalsData = approvals;
        });
        widget.onMutated?.call(data);
      }
    } catch (e) { if (mounted && epoch == _epoch) { setState(() => _error = safeFailure(e)); } }
    finally { if (mounted && epoch == _epoch) { setState(() => _loading = false); } }
  }
  Future<void> _edit() async {
    final data = _data;
    if (data == null || _busy) { return; }
    final fields = <EditField>[
      EditField('title', '標題', required: true, value: valueText(data, 'title')),
      EditField('description', '說明', lines: 8, markdown: true, value: valueText(data, 'description')),
      EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true, value: _labelsValue(data), hint: '留白會移除所有標籤'),
      EditField.picker('assignee_ids', '指派', source: PickerSource.members, multi: true, value: _peopleValue(valueObjects(data, 'assignees'))),
      if (mr) EditField.picker('reviewer_ids', '審查者', source: PickerSource.members, multi: true,
        value: _peopleValue(valueObjects(data, 'reviewers'))),
      EditField.picker('milestone_id', '里程碑', source: PickerSource.milestones, multi: false,
        value: _milestoneValue(data), hint: '留白會移除里程碑'),
      if (!mr) EditField.toggle('confidential', '機密議題', value: valueBool(data, 'confidential') ? 'true' : 'false',
        hint: '僅專案成員與被指派者可見此議題'),
    ];
    final saved = await openEditor(context, account: widget.account, api: widget.api, projectId: widget.project.id, projectPath: widget.project.path,
      title: '編輯 $label', resource: '${widget.project.id}/${widget.resource}/${widget.iid}/edit',
      subtitle: widget.project.path, baseRevision: valueText(data, 'updated_at'), fields: fields, save: (values) async {
        final current = await widget.api.record(path);
        if (current['updated_at'] != data['updated_at']) { throw const ApiFailure(FailureKind.conflict); }
        final body = editorSubmission(fields, values);
        final title = body['title'];
        if (title is String) body['title'] = title.trim();
        if (!body.containsKey('milestone_id') || body['milestone_id'] == null) {
          body['milestone_id'] = 0;
        }
        await widget.api.writeRecord('PUT', path, body);
      });
    if (saved && mounted) {
      await _load();
      if (mounted && _data != null) {
        widget.onMutated?.call(_data!);
      }
    }
  }
  Future<void> _editAssignees() async {
    final data = _data;
    if (data == null || _busy) { return; }
    final field = EditField.picker(
      'assignee_ids',
      '指派成員',
      source: PickerSource.members,
      multi: true,
      value: _peopleValue(valueObjects(data, 'assignees')),
      hint: '留白會移除所有指派成員',
    );
    final saved = await openEditor(
      context,
      account: widget.account,
      api: widget.api,
      projectId: widget.project.id,
      projectPath: widget.project.path,
      title: '修改指派 · $label',
      resource: '${widget.project.id}/${widget.resource}/${widget.iid}/assignees',
      subtitle: widget.project.path,
      baseRevision: valueText(data, 'updated_at'),
      fields: [field],
      save: (values) async {
        final current = await widget.api.record(path);
        if (current['updated_at'] != data['updated_at']) {
          throw const ApiFailure(FailureKind.conflict);
        }
        final body = editorSubmission([field], values);
        await widget.api.writeRecord('PUT', path, body);
      },
    );
    if (saved && mounted) {
      await _load();
      if (mounted && _data != null) {
        widget.onMutated?.call(_data!);
      }
    }
  }
  Future<void> _editReviewers() async {
    final data = _data;
    if (data == null || _busy || !mr) { return; }
    final field = EditField.picker(
      'reviewer_ids',
      '審查者名單',
      source: PickerSource.members,
      multi: true,
      value: _peopleValue(valueObjects(data, 'reviewers')),
      hint: '留白會移除所有審查者',
    );
    final saved = await openEditor(
      context,
      account: widget.account,
      api: widget.api,
      projectId: widget.project.id,
      projectPath: widget.project.path,
      title: '修改審查者 · $label',
      resource: '${widget.project.id}/${widget.resource}/${widget.iid}/reviewers',
      subtitle: widget.project.path,
      baseRevision: valueText(data, 'updated_at'),
      fields: [field],
      save: (values) async {
        final current = await widget.api.record(path);
        if (current['updated_at'] != data['updated_at']) {
          throw const ApiFailure(FailureKind.conflict);
        }
        final body = editorSubmission([field], values);
        await widget.api.writeRecord('PUT', path, body);
      },
    );
    if (saved && mounted) {
      await _load();
      if (mounted && _data != null) {
        widget.onMutated?.call(_data!);
      }
    }
  }

  Future<void> _editLabelsQuick() async {
    final data = _data;
    if (data == null || _busy) return;
    final initialChoices = decodeChoices(_labelsValue(data), source: PickerSource.labels);
    final picked = await showChoicePicker(
      context,
      api: widget.api,
      account: widget.account,
      projectId: widget.project.id,
      source: PickerSource.labels,
      multi: true,
      title: '選擇標籤 · $label',
      initial: initialChoices,
    );
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final current = await widget.api.record(path);
      if (current['updated_at'] != data['updated_at']) {
        throw const ApiFailure(FailureKind.conflict);
      }
      final newLabels = picked.map((c) => c.name).join(', ');
      await widget.api.writeRecord('PUT', path, {'labels': newLabels});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('標籤已更新')),
        );
      }
      await _load();
      if (mounted && _data != null) {
        widget.onMutated?.call(_data!);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeLabelQuick(String labelToRemove) async {
    final data = _data;
    if (data == null || _busy) return;
    setState(() => _busy = true);
    try {
      final current = await widget.api.record(path);
      if (current['updated_at'] != data['updated_at']) {
        throw const ApiFailure(FailureKind.conflict);
      }
      final labels = _extractLabels(current);
      final remaining = labels.where((l) => l != labelToRemove).join(', ');
      await widget.api.writeRecord('PUT', path, {'labels': remaining});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已移除標籤「$labelToRemove」')),
        );
      }
      await _load();
      if (mounted && _data != null) {
        widget.onMutated?.call(_data!);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  Future<void> _action(String action) async {
    if (_busy || _data == null) { return; }
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
    if (action == 'cancel_auto_merge') {
      if (!await confirmAction(context, '取消自動合併？', '取消後將不再於流水線通過時自動合併此變更。')) {
        return;
      }
      if (!mounted) { return; }
      setState(() => _busy = true);
      try {
        await widget.api.cancelAutoMerge(widget.project.id, widget.iid);
        await _load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已取消自動合併')));
        }
      } catch (e) {
        if (mounted) { showFailure(context, e); }
      } finally {
        if (mounted) { setState(() => _busy = false); }
      }
      return;
    }
    if (action == 'merge') {
      final options = await _askMerge(data);
      if (options == null) { return; }
      squash = options.squash;
      removeSourceBranch = options.removeSourceBranch;
      autoMerge = options.autoMerge;
    } else if (confirmation != null && !await confirmAction(context, confirmation.$1, confirmation.$2, requiredText: confirmation.$3)) {
      return;
    }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'delete':
          await widget.api.removeRecord(path);
          if (mounted) {
            if (widget.onDeleted != null) {
              widget.onDeleted!();
            } else {
              Navigator.pop(context);
            }
          }
          return;
        case 'close':
        case 'reopen':
          await widget.api.writeRecord('PUT', path, {'state_event': action});
        case 'assign':
          final ids = valueObjects(data, 'assignees').map((v) => valueInt(v, 'id')).where((id) => id > 0).toSet();
          ids.contains(widget.account.user.id) ? ids.remove(widget.account.user.id) : ids.add(widget.account.user.id);
          await widget.api.writeRecord('PUT', path, {'assignee_ids': ids.toList()});
        case 'todo': await widget.api.writeRecord('POST', [...path, 'todo'], {});
        case 'draft':
          final current = await widget.api.record(path);
          if (current['updated_at'] != data['updated_at']) { throw const ApiFailure(FailureKind.conflict); }
          await widget.api.writeRecord('PUT', path, {'title': toggledDraftTitle(valueText(current, 'title'), data['draft'] == true)});
        case 'approve': await widget.api.approveMergeRequest(widget.project.id, widget.iid, requiredString(data, 'sha'));
        case 'unapprove': await widget.api.writeRecord('POST', [...path, 'unapprove'], {});
        case 'rebase': await widget.api.rebaseMergeRequest(widget.project.id, widget.iid);
        case 'merge': await widget.api.mergeRequest(widget.project.id, widget.iid, requiredString(data, 'sha'),
          squash: squash, removeSourceBranch: removeSourceBranch, autoMerge: autoMerge);
      }
      await _load();
      if (mounted && _data != null) {
        widget.onMutated?.call(_data!);
      }
      if (mounted && action == 'rebase') {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已請求 Rebase 分支')));
      }
      if (mounted && action == 'merge') {
        final merged = _data?['state'] == 'merged';
        final autoScheduled = isAutoMergeEnabled(_data ?? {});
        final message = merged
            ? '已合併'
            : (autoScheduled
                ? '已排程自動合併，等待流水線完成。'
                : 'GitLab 已接受操作，請查看最新合併狀態。');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Future<({bool squash, bool removeSourceBranch, bool autoMerge})?> _askMerge(Json data) {
    var squash = mergeSquashDefault(data);
    var removeSourceBranch = mergeRemoveSourceBranchDefault(data);
    final squashLocked = mergeSquashEnforced(data);
    final autoCandidate = canAutoMerge(data);
    var autoMerge = autoCandidate;
    return showDialog<({bool squash, bool removeSourceBranch, bool autoMerge})>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text(autoMerge ? '排程自動合併 $label？' : '合併 $label？'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${valueText(data, 'source_branch')} → ${valueText(data, 'target_branch')}\n'
            '版本 ${shortSha(valueText(data, 'sha'))}\n若版本變動會停止，不會自動改用新版本。'),
          const SizedBox(height: 8),
          if (autoCandidate)
            SwitchListTile(
              key: const ValueKey('merge-auto'), contentPadding: EdgeInsets.zero, minTileHeight: 48,
              title: const Text('流水線成功時自動合併 (MWPS)'),
              subtitle: const Text('當所有檢查與 CI 通過後自動合併'),
              value: autoMerge,
              onChanged: (value) => setDialog(() => autoMerge = value)),
          SwitchListTile(
            key: const ValueKey('merge-squash'), contentPadding: EdgeInsets.zero, minTileHeight: 48,
            title: const Text('Squash 提交'),
            subtitle: squashLocked ? const Text('專案設定強制此選項') : null,
            value: squash, onChanged: squashLocked ? null : (value) => setDialog(() => squash = value)),
          SwitchListTile(
            key: const ValueKey('merge-remove-branch'), contentPadding: EdgeInsets.zero, minTileHeight: 48,
            title: const Text('合併後刪除來源分支'), value: removeSourceBranch,
            onChanged: (value) => setDialog(() => removeSourceBranch = value)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, (squash: squash, removeSourceBranch: removeSourceBranch, autoMerge: autoMerge)),
            child: Text(autoMerge ? '排程自動合併' : '確認')),
        ],
      ),
    ));
  }
  Widget _reviewCard(Json data) {
    final state = valueText(data, 'state');
    if (state != 'opened') {
      if (state != 'merged' && state != 'closed') { return const SizedBox.shrink(); }
      final at = relativeDate(valueText(data, state == 'merged' ? 'merged_at' : 'closed_at'));
      final label = state == 'merged' ? '已合併' : '已關閉';
      return Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(
        at.isEmpty ? label : '$label · $at', style: Theme.of(context).textTheme.titleSmall));
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

    return Padding(padding: const EdgeInsets.only(bottom: 16), child: Card(child: Padding(
      padding: const EdgeInsets.all(14), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(mergeStatusLabel(data), style: Theme.of(context).textTheme.titleSmall)),
          if (autoScheduled)
            const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.schedule_send, size: 20)),
        ]),
        if (autoScheduled) ...[
          const SizedBox(height: 6),
          const Text('流水線通過後將自動執行合併。', style: TextStyle(fontSize: 12)),
        ],
        if (hasUnresolvedDiscussions) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('unresolved-discussions-notice'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.chat_bubble_outline, size: 16, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '尚有未解決的討論，解決後方可合併',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
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
            decoration: BoxDecoration(
              color: isThresholdReached
                  ? WorkshopColors.of(context).successContainer.withValues(alpha: 0.4)
                  : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isThresholdReached ? Icons.check_circle_outline : Icons.rule_outlined,
                      size: 16,
                      color: isThresholdReached ? WorkshopColors.of(context).onSuccessContainer : null,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        isThresholdReached
                            ? '已達核准門檻（${approvedBy.length} 人已批准）'
                            : '審查核准進度：已批准 ${approvedBy.length} 人${approvalsRequired > 0 ? ' · 尚需 $approvalsLeft 人' : ''}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                if (approvedBy.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '已核准：${approvedBy.map((v) => '@${valueText(valueObject(v, 'user'), 'username')}').join('、')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (hasApproved)
            OutlinedButton.icon(
              key: const ValueKey('mr-unapprove-btn'),
              onPressed: _busy ? null : () => _action('unapprove'),
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('撤回我的批准'),
            )
          else
            OutlinedButton.icon(
              key: const ValueKey('mr-approve-btn'),
              onPressed: _busy ? null : () => _action('approve'),
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: const Text('批准'),
            ),
          if (rebaseInProgress)
            OutlinedButton.icon(
              key: const ValueKey('mr-rebase-progress-btn'),
              onPressed: null,
              icon: const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              label: const Text('Rebase 進行中…'),
            )
          else if (canRebase)
            OutlinedButton.icon(
              key: const ValueKey('mr-rebase-btn'),
              onPressed: _busy ? null : () => _action('rebase'),
              icon: const Icon(Icons.fork_right, size: 18),
              label: Text(divergedCommits > 0 ? 'Rebase (落後 $divergedCommits)' : 'Rebase'),
            ),
          if (autoScheduled)
            OutlinedButton.icon(
              key: const ValueKey('cancel-auto-merge'),
              onPressed: _busy ? null : () => _action('cancel_auto_merge'),
              icon: const Icon(Icons.close, size: 18),
              label: const Text('取消自動合併'),
            )
          else
            FilledButton.icon(
              onPressed: _busy ? null : () => _action('merge'),
              icon: Icon(autoCandidate ? Icons.schedule_send : Icons.merge, size: 18),
              label: Text(autoCandidate ? '自動合併…' : '合併'),
            ),
        ]),
      ]),
    )));
  }

  Future<void> _subscribe(bool subscribed) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.setSubscribed(widget.project.id, widget.resource, widget.iid, subscribed);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(subscribed ? '已開啟通知' : '已關閉通知')));
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Widget> _detailRows(Json data) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final rows = <Widget>[];
    void add(IconData icon, String label, String value) {
      rows
        ..add(const Divider(height: 20))
        ..add(Row(children: [
          Icon(icon, size: 18, color: muted),
          const SizedBox(width: 10),
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(width: 12),
          Expanded(child: Text(value, textAlign: TextAlign.end, style: theme.textTheme.bodyMedium)),
        ]));
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
        ..add(SwitchListTile(
          key: const ValueKey('work-item-subscribe'),
          contentPadding: EdgeInsets.zero,
          minTileHeight: 48,
          secondary: Icon(subscribed ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, color: muted),
          title: const Text('通知'),
          subtitle: Text(subscribed ? '有新動態時通知我' : '不接收此項目的通知'),
          value: subscribed,
          onChanged: _busy ? null : _subscribe,
        ));
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
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(48, 48),
              ),
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
              InputChip(
                key: const ValueKey('quick-unassign-me'),
                avatar: const Icon(Icons.check_circle, size: 16),
                label: const Text('已指派給我'),
                selected: true,
                showCheckmark: false,
                onDeleted: _busy ? null : () => _action('assign'),
                deleteIcon: const Icon(Icons.close, size: 14),
                deleteButtonTooltipMessage: '取消指派給我',
                onPressed: _busy ? null : () => _action('assign'),
              )
            else
              ActionChip(
                key: const ValueKey('quick-assign-me'),
                avatar: const Icon(Icons.person_add_alt_1, size: 16),
                label: const Text('指派給我'),
                onPressed: _busy ? null : () => _action('assign'),
              ),
            ...assignees.where((u) => valueInt(u, 'id') != myId).map((u) {
              final username = valueText(u, 'username');
              final name = valueText(u, 'name');
              return Chip(
                avatar: CircleAvatar(
                  radius: 12,
                  child: Text(
                    (username.isNotEmpty ? username[0] : '?').toUpperCase(),
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
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
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(48, 48),
              ),
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
                avatar: CircleAvatar(
                  radius: 12,
                  child: Text(
                    (username.isNotEmpty ? username[0] : '?').toUpperCase(),
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
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
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final label in labels)
              InputChip(
                key: ValueKey('label-chip-$label'),
                label: Text(label),
                onPressed: _busy ? null : _editLabelsQuick,
                onDeleted: _busy ? null : () => _removeLabelQuick(label),
                deleteIcon: const Icon(Icons.close, size: 14),
                deleteButtonTooltipMessage: '移除標籤 $label',
              ),
            ActionChip(
              key: const ValueKey('quick-add-label'),
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('新增標籤'),
              onPressed: _busy ? null : _editLabelsQuick,
            ),
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
    final appBar = AppBar(
        primary: false,
        automaticallyImplyLeading: false,
        leading: widget.showBackButton ? BackButton(onPressed: widget.onBack) : null,
        titleSpacing: widget.showBackButton ? 0 : null,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 19)),
          Text(widget.project.path, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ]),
        actions: [
        IconButton(tooltip: '重新整理', onPressed: _loading || _busy ? null : _load, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(tooltip: '更多操作', enabled: !_busy && data != null, onSelected: _action, itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('編輯')),
          if (data?['state'] == 'opened') const PopupMenuItem(value: 'close', child: Text('關閉')),
          if (mr && data?['state'] == 'opened')
            PopupMenuItem(value: 'draft', child: Text(data?['draft'] == true ? '標示為可審查' : '標示為草稿')),
          if (data?['state'] == 'closed') const PopupMenuItem(value: 'reopen', child: Text('重新開啟')),
          PopupMenuItem(value: 'assign', child: Text(valueObjects(data ?? {}, 'assignees')
            .any((v) => v['id'] == widget.account.user.id) ? '取消指派給我' : '指派給我')),
          const PopupMenuItem(value: 'todo', child: Text('加入我的待辦')),
          const PopupMenuItem(value: 'web', child: Text('在 GitLab 開啟')),
          const PopupMenuItem(value: 'delete', child: Text('刪除')),
        ]),
      ]);
    if (data == null) {
      return Scaffold(
        body: StatusBarInset(child: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            appBar,
            Expanded(child: _error != null ? SingleChildScrollView(child: FailureNotice(_error!, onRetry: _load,
              account: widget.account, resourceLabel: '${widget.project.path} · $label',
              onSwitchAccount: endSessionFrom(context, ResumeTarget(
                projectId: widget.project.id,
                projectPath: widget.project.path,
                resource: widget.resource,
                iid: widget.iid,
              )))) : const ListSkeleton()),
          ]))),
      );
    }
    final author = valueObject(data, 'author');
    final authorName = valueText(author, 'name', valueText(author, 'username'));
    final created = relativeDate(valueText(data, 'created_at'));
    return ScrollChromeScope(controller: _chrome, child: Scaffold(
      body: NotificationListener<ScrollNotification>(onNotification: _chrome.handle, child:
          StatusBarInset(child: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CollapsingChrome(visible: _chrome, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            appBar,
            Padding(padding: const EdgeInsets.fromLTRB(20, 2, 20, 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(valueText(data, 'title'), maxLines: 4,
                style: theme.textTheme.titleLarge?.copyWith(height: 1.3)),
              const SizedBox(height: 8), Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusBadge(valueText(data, 'state')),
                  if (data['draft'] == true) const MetaChip('草稿', icon: Icons.edit_note),
                  if (valueBool(data, 'confidential')) const MetaChip('機密', icon: Icons.lock_outline),
                  if (valueObject(data, 'milestone').isNotEmpty)
                    MetaChip(valueText(valueObject(data, 'milestone'), 'title'), icon: Icons.tour_outlined),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Monogram(authorName, size: 18),
                    const SizedBox(width: 6),
                    Flexible(child: Text('@${valueText(author, 'username')}${created.isEmpty ? '' : ' · $created'}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted))),
                  ]),
                ]),
            ])),
          ])),
          if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
          TabBar(controller: _tabs, indicatorSize: TabBarIndicatorSize.tab,
            tabs: [const Tab(text: '摘要'), if (mr) const Tab(text: '變更'), const Tab(text: '討論'), if (mr) const Tab(text: '檢查')]),
          Expanded(child: TabBarView(controller: _tabs, children: [
            ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
              if (_error != null) FailureNotice(_error!, onRetry: _load, account: widget.account,
                resourceLabel: '${widget.project.path} · $label',
                onSwitchAccount: endSessionFrom(context, ResumeTarget(
                  projectId: widget.project.id,
                  projectPath: widget.project.path,
                  resource: widget.resource,
                  iid: widget.iid,
                ))),
              if (mr) _reviewCard(data),
              if (mr) Padding(padding: const EdgeInsets.only(bottom: 12), child: Wrap(spacing: 10, runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center, children: [
                  MetaChip('${valueText(data, 'source_branch')} → ${valueText(data, 'target_branch')}',
                    icon: Icons.alt_route, mono: true),
                  if (valueText(data, 'changes_count').isNotEmpty)
                    MetaChip('${valueText(data, 'changes_count')} 個檔案', icon: Icons.difference_outlined),
                ])),
              MarkdownView(valueText(data, 'description').isEmpty ? '尚未填寫說明。' : valueText(data, 'description'),
                base: web, api: widget.api, projectId: widget.project.id,
                projectWeb: widget.account.instance.projectWeb(widget.project.path),
                projectPath: widget.project.path),
              const SizedBox(height: 14),
              ReactionsBar(account: widget.account, api: widget.api, project: widget.project,
                resource: widget.resource, iid: widget.iid),
              const SizedBox(height: 16),
              Card(child: Padding(padding: const EdgeInsets.fromLTRB(14, 4, 8, 12), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildAssigneesSection(data),
                  if (mr) ...[const Divider(height: 20), _buildReviewersSection(data)],
                  const Divider(height: 20),
                  _buildLabelsSection(data),
                  if (valueObject(data, 'milestone').isNotEmpty) ...[
                    const Divider(height: 20),
                    Text('里程碑', style: Theme.of(context).textTheme.titleSmall), const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.tour_outlined, size: 18),
                      const SizedBox(width: 8),
                      Flexible(child: Text(valueText(valueObject(data, 'milestone'), 'title'))),
                      if (valueText(valueObject(data, 'milestone'), 'due_date').isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text('（到期日：${valueText(valueObject(data, 'milestone'), 'due_date')}）',
                          style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ]),
                  ],
                  ..._detailRows(data),
                ],
              ))),
              if (!mr) _RelatedIssueItems(account: widget.account, api: widget.api, project: widget.project, iid: widget.iid),
              if (mr) _MergeRequestHistory(account: widget.account, api: widget.api, project: widget.project, iid: widget.iid),
              const SizedBox(height: 12),
              Text([
                if (valueText(data, 'created_at').isNotEmpty) '建立於 ${relativeDate(valueText(data, 'created_at'))}',
                '更新於 ${relativeDate(valueText(data, 'updated_at'))}',
              ].join(' · '), style: Theme.of(context).textTheme.bodySmall),
            ]),
            if (mr) ReviewDiffPage(key: ValueKey(valueText(data, 'sha')), account: widget.account, api: widget.api,
              project: widget.project, iid: widget.iid, expectedSha: valueText(data, 'sha'), onApplied: _load),
            DiscussionsTab(
              account: widget.account,
              api: widget.api,
              project: widget.project,
              resource: widget.resource,
              iid: widget.iid,
              headSha: mr ? valueText(data, 'sha') : null,
              onChanged: _load,
            ),
            if (mr) _MergeChecks(account: widget.account, api: widget.api, path: path, data: data, busy: _busy, act: _action),
          ])),
          ]))),
      )),
    );
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
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(20), children: [
    Text('合併條件', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 10),
    Text(mergeStatusLabel(widget.data)),
    const SizedBox(height: 12), Text('版本 ${shortSha(valueText(widget.data, 'sha'))}', style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'])),
    if (widget.data['head_pipeline'] is Json) Padding(padding: const EdgeInsets.symmetric(vertical: 16),
      child: StatusBadge(valueText(valueObject(widget.data, 'head_pipeline'), 'status'))),
    const Divider(height: 32), Text('審查', style: Theme.of(context).textTheme.titleMedium),
    FutureBuilder<Json>(future: _approvals, builder: (context, snap) {
      if (snap.hasError) { return FailureNotice(safeFailure(snap.error!), account: widget.account,
        resourceLabel: '合併檢查', onSwitchAccount: endSessionFrom(context),
        onRetry: () => setState(() {
        _approvals = widget.api.record([...widget.path, 'approvals']);
      })); }
      if (!snap.hasData) { return const ListSkeleton(); }
      final approved = valueObjects(snap.data!, 'approved_by');
      return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(approved.isEmpty ? '尚無批准者'
        : approved.map((v) => '@${valueText(valueObject(v, 'user'), 'username')}').join('、')));
    }),
    if (widget.data['state'] == 'opened') ...[
      OutlinedButton.icon(onPressed: widget.busy ? null : () => widget.act('approve'),
        icon: const Icon(Icons.verified_outlined), label: const Text('批准目前版本')),
      TextButton(onPressed: widget.busy ? null : () => widget.act('unapprove'), child: const Text('撤回我的批准')),
      const SizedBox(height: 16),
      if (isAutoMergeEnabled(widget.data))
        OutlinedButton.icon(
          key: const ValueKey('cancel-auto-merge-checks'),
          onPressed: widget.busy ? null : () => widget.act('cancel_auto_merge'),
          icon: const Icon(Icons.close),
          label: const Text('取消自動合併'),
        )
      else
        FilledButton.icon(
          onPressed: widget.busy ? null : () => widget.act('merge'),
          icon: Icon(canAutoMerge(widget.data) ? Icons.schedule_send : Icons.merge),
          label: Text(canAutoMerge(widget.data) ? '自動合併…' : '合併…'),
        ),
      const SizedBox(height: 12), const Text('GitLab 會再次檢查 SHA、權限、保護分支及所有合併條件。', style: TextStyle(fontSize: 12)),
    ],
  ]);
}

/// Merge requests that mention or close an issue, and its linked issues.
/// Both reads are optional context: a failure hides that list.
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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final base = ['projects', '${widget.project.id}', 'issues', '${widget.iid}'];
    Future<List<Json>> soft(List<String> path) async {
      try {
        return (await widget.api.records(path)).items;
      } catch (_) {
        return const [];
      }
    }
    final results = await Future.wait([soft([...base, 'related_merge_requests']), soft([...base, 'links'])]);
    if (!mounted) return;
    setState(() {
      _mergeRequests = results[0];
      _links = results[1];
    });
  }

  @override
  Widget build(BuildContext context) {
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
        subtitle: Text([
          '${mr ? '!' : '#'}${valueInt(item, 'iid')}',
          statusLabel(valueText(item, 'state')),
          if (relation.isNotEmpty) relation,
        ].join(' · ')),
        onTap: () => open.workItem(context, '${valueInt(item, 'project_id')}', mr ? 'merge_requests' : 'issues',
          valueInt(item, 'iid')),
      );
    }
    return Padding(padding: const EdgeInsets.only(top: 12), child: Card(child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_mergeRequests.isNotEmpty) ...[
          Text('相關合併請求', style: theme.textTheme.titleSmall),
          for (final item in _mergeRequests) row(item, mr: true),
        ],
        if (_links.isNotEmpty) ...[
          if (_mergeRequests.isNotEmpty) const Divider(height: 16),
          Text('關聯議題', style: theme.textTheme.titleSmall),
          for (final item in _links) row(item, mr: false),
        ],
      ]),
    )));
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
        title: const Text('Pipelines'),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => push('!$iid Pipelines', RecordsFeed(
          identity: '${base.join('/')}/pipelines',
          account: account,
          resourceLabel: '${project.path} · !$iid Pipelines',
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
    if (valueInt(user, 'id') > 0)
      PickerChoice(
        id: '${valueInt(user, 'id')}',
        name: valueText(user, 'name').isEmpty ? valueText(user, 'username') : valueText(user, 'name'),
        username: valueText(user, 'username').isEmpty ? null : valueText(user, 'username'),
      ),
]);

String _milestoneValue(Json data) {
  final milestone = valueObject(data, 'milestone');
  final id = valueInt(milestone, 'id');
  if (id <= 0) return '';
  return encodeChoices([
    PickerChoice(
      id: '$id',
      name: valueText(milestone, 'title'),
    ),
  ]);
}

final _draftPrefix = RegExp(r'^\s*(\[draft\]|\(draft\)|draft:|draft\s+-|wip:)\s*', caseSensitive: false);

/// GitLab marks a merge request as draft by its title prefix; toggling adds
/// `Draft: ` or strips any prefix GitLab recognises.
String toggledDraftTitle(String title, bool isDraft) {
  if (isDraft) return title.replaceFirst(_draftPrefix, '').trim();
  return 'Draft: ${title.trim()}';
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
