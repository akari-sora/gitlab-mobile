import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/external_link.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'diff_page.dart';
import 'editor.dart';
import 'picker_sheet.dart';
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
  final _feed = GlobalKey<RecordsFeedState>();
  final _search = TextEditingController();
  String _state = 'opened', _query = '';
  bool get mr => widget.resource == 'merge_requests';
  @override
  void dispose() { _search.dispose(); super.dispose(); }
  Future<void> _open(int iid) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => WorkItemPage(
      account: widget.account, api: widget.api, project: widget.project, resource: widget.resource, iid: iid)));
    if (mounted) { await _feed.currentState?.refresh(); }
  }
  Future<void> _create() async {
    var iid = 0;
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
    ];
    final saved = await openEditor(context, account: widget.account, api: widget.api, projectId: widget.project.id,
      title: mr ? '新增合併請求' : '新增議題', resource: '${widget.project.id}/${widget.resource}/new',
      subtitle: widget.project.path, fields: fields, save: (values) async {
        final body = editorSubmission(fields, values);
        final title = body['title'];
        if (title is String) body['title'] = title.trim();
        final created = mr ? await widget.api.createMergeRequest(widget.project.id, body)
          : await widget.api.createIssue(widget.project.id, body);
        iid = requiredInt(created, 'iid');
      });
    if (saved && mounted) { await _open(iid); }
  }
  @override
  Widget build(BuildContext context) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(16, 12, 12, 4), child: Row(children: [
      Expanded(child: TextField(controller: _search, textInputAction: TextInputAction.search,
        decoration: InputDecoration(hintText: mr ? '搜尋合併請求' : '搜尋議題', prefixIcon: const Icon(Icons.search)),
        onSubmitted: (value) => setState(() => _query = value.trim()))),
      const SizedBox(width: 8), IconButton(tooltip: mr ? '新增合併請求' : '新增議題',
        onPressed: widget.project.archived == true ? null : _create, icon: const Icon(Icons.add_circle_outline)),
    ])),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Align(
      alignment: Alignment.centerLeft, child: Wrap(spacing: 8, runSpacing: 4, children: [
        for (final e in const {'opened': '開啟中', 'closed': '已關閉', 'all': '全部'}.entries)
          ChoiceChip(label: Text(e.value), selected: _state == e.key, showCheckmark: false,
            onSelected: (_) => setState(() => _state = e.key)),
      ]))),
    Expanded(child: RecordsFeed(key: _feed, identity: '${widget.resource}/$_state/$_query',
      account: widget.account, resourceLabel: '${widget.project.path} · ${mr ? '合併請求' : '議題'}',
      onSwitchAccount: endSessionFrom(context),
      empty: mr ? '沒有符合的合併請求' : '沒有符合的議題',
      load: (next) => widget.api.records(['projects', '${widget.project.id}', widget.resource],
        query: {'state': _state, 'scope': 'all', 'order_by': 'updated_at', 'sort': 'desc', if (_query.isNotEmpty) 'search': _query}, next: next),
      itemBuilder: (context, value) => workItemCard(context, value, mr: mr, onTap: () => _open(requiredInt(value, 'iid'))),
    )),
  ]);
}

/// Shared issue / merge-request row: state-tinted mark, title, then a meta row
/// with the status badge, the mono `#iid`, branches for MRs and the update time.
Widget workItemCard(BuildContext context, Json value, {required bool mr, required VoidCallback onTap, String? project}) {
  final scheme = Theme.of(context).colorScheme;
  final workshop = WorkshopColors.of(context);
  final state = valueText(value, 'state');
  final (markBackground, markForeground) = switch (state) {
    'opened' => (scheme.primaryContainer, scheme.onPrimaryContainer),
    'merged' => (workshop.successContainer, workshop.onSuccessContainer),
    _ => (workshop.neutralContainer, workshop.onNeutralContainer),
  };
  final source = valueText(value, 'source_branch'), target = valueText(value, 'target_branch');
  final pipeline = valueText(valueObject(value, 'head_pipeline'), 'status');
  final iid = '${mr ? '!' : '#'}${valueInt(value, 'iid')}';
  return EntityCard(
    onTap: onTap,
    leading: Container(width: 40, height: 40, alignment: Alignment.center,
      decoration: BoxDecoration(color: markBackground, borderRadius: BorderRadius.circular(12)),
      child: Icon(mr ? Icons.merge : Icons.adjust, size: 20, color: markForeground)),
    title: Text(valueText(value, 'title')),
    subtitle: project == null ? null : Text(project),
    body: mr && source.isNotEmpty && target.isNotEmpty
        ? MetaChip('$source → $target', icon: Icons.call_split, mono: true)
        : null,
    meta: [
      StatusBadge(state),
      if (mr && pipeline.isNotEmpty) StatusBadge(pipeline),
      MetaChip(iid, mono: true),
      MetaChip(relativeDate(valueText(value, 'updated_at')), icon: Icons.schedule_outlined),
    ],
  );
}

class WorkItemPage extends StatefulWidget {
  const WorkItemPage({super.key, required this.account, required this.api, required this.project, required this.resource, required this.iid});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  final int iid;
  @override
  State<WorkItemPage> createState() => _WorkItemPageState();
}
class _WorkItemPageState extends State<WorkItemPage> {
  Json? _data;
  ApiFailure? _error;
  bool _loading = true, _busy = false;
  int _epoch = 0;
  bool get mr => widget.resource == 'merge_requests';
  List<String> get path => ['projects', '${widget.project.id}', widget.resource, '${widget.iid}'];
  String get label => '${mr ? '!' : '#'}${widget.iid}';
  Uri get web => widget.account.instance.projectWeb('${widget.project.path}/-/${widget.resource}/${widget.iid}');
  @override
  void initState() { super.initState(); unawaited(_load()); }
  Future<void> _load() async {
    final epoch = ++_epoch;
    if (mounted) { setState(() { _loading = true; _error = null; }); }
    try {
      final data = await widget.api.record(path);
      if (mounted && epoch == _epoch) { setState(() => _data = data); }
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
    ];
    final saved = await openEditor(context, account: widget.account, api: widget.api, projectId: widget.project.id,
      title: '編輯 $label', resource: '${widget.project.id}/${widget.resource}/${widget.iid}/edit',
      subtitle: widget.project.path, fields: fields, save: (values) async {
        final current = await widget.api.record(path);
        if (current['updated_at'] != data['updated_at']) { throw const ApiFailure(FailureKind.conflict); }
        final body = editorSubmission(fields, values);
        final title = body['title'];
        if (title is String) body['title'] = title.trim();
        await widget.api.writeRecord('PUT', path, body);
      });
    if (saved && mounted) { await _load(); }
  }
  Future<void> _action(String action) async {
    if (_busy || _data == null) { return; }
    final data = _data!;
    if (action == 'edit') { await _edit(); return; }
    if (action == 'web') { await openExternal(context, web); return; }
    final confirmation = switch (action) {
      'delete' => ('刪除 $label？', '將刪除此項目與相關討論，無法復原。', label),
      'approve' => ('批准目前版本？', '$label · ${shortSha(valueText(data, 'sha'))}\n仍受專案批准與重新認證政策限制。', null),
      _ => null,
    };
    var squash = false;
    var removeSourceBranch = false;
    if (action == 'merge') {
      final options = await _askMerge(data);
      if (options == null) { return; }
      squash = options.squash;
      removeSourceBranch = options.removeSourceBranch;
    } else if (confirmation != null && !await confirmAction(context, confirmation.$1, confirmation.$2, requiredText: confirmation.$3)) {
      return;
    }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'delete':
          await widget.api.removeRecord(path);
          if (mounted) { Navigator.pop(context); }
          return;
        case 'close':
        case 'reopen':
          await widget.api.writeRecord('PUT', path, {'state_event': action});
        case 'assign':
          final ids = valueObjects(data, 'assignees').map((v) => valueInt(v, 'id')).where((id) => id > 0).toSet();
          ids.contains(widget.account.user.id) ? ids.remove(widget.account.user.id) : ids.add(widget.account.user.id);
          await widget.api.writeRecord('PUT', path, {'assignee_ids': ids.toList()});
        case 'todo': await widget.api.writeRecord('POST', [...path, 'todo'], {});
        case 'approve': await widget.api.approveMergeRequest(widget.project.id, widget.iid, requiredString(data, 'sha'));
        case 'unapprove': await widget.api.writeRecord('POST', [...path, 'unapprove'], {});
        case 'merge': await widget.api.mergeRequest(widget.project.id, widget.iid, requiredString(data, 'sha'),
          squash: squash, removeSourceBranch: removeSourceBranch);
      }
      await _load();
      if (mounted && action == 'merge') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          _data?['state'] == 'merged' ? '已合併' : 'GitLab 已接受操作，請查看最新合併狀態。')));
      }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Future<({bool squash, bool removeSourceBranch})?> _askMerge(Json data) {
    var squash = mergeSquashDefault(data);
    var removeSourceBranch = mergeRemoveSourceBranchDefault(data);
    final squashLocked = mergeSquashEnforced(data);
    return showDialog<({bool squash, bool removeSourceBranch})>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text('合併 $label？'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${valueText(data, 'source_branch')} → ${valueText(data, 'target_branch')}\n'
            '版本 ${shortSha(valueText(data, 'sha'))}\n若版本變動會停止，不會自動改用新版本。'),
          const SizedBox(height: 8),
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
          FilledButton(onPressed: () => Navigator.pop(context, (squash: squash, removeSourceBranch: removeSourceBranch)),
            child: const Text('確認')),
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
    return Padding(padding: const EdgeInsets.only(bottom: 16), child: Card(child: Padding(
      padding: const EdgeInsets.all(14), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(mergeStatusLabel(data), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : () => _action('approve'), child: const Text('批准')),
          FilledButton(onPressed: _busy ? null : () => _action('merge'), child: const Text('合併')),
        ]),
      ]),
    )));
  }
  @override
  Widget build(BuildContext context) {
    final data = _data;
    return DefaultTabController(length: mr ? 4 : 2, child: Scaffold(
      appBar: AppBar(title: Text(label), actions: [
        IconButton(tooltip: '重新整理', onPressed: _loading || _busy ? null : _load, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(tooltip: '更多操作', enabled: !_busy && data != null, onSelected: _action, itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('編輯')),
          if (data?['state'] == 'opened') const PopupMenuItem(value: 'close', child: Text('關閉')),
          if (data?['state'] == 'closed') const PopupMenuItem(value: 'reopen', child: Text('重新開啟')),
          PopupMenuItem(value: 'assign', child: Text(valueObjects(data ?? {}, 'assignees')
            .any((v) => v['id'] == widget.account.user.id) ? '取消指派給我' : '指派給我')),
          const PopupMenuItem(value: 'todo', child: Text('加入我的待辦')),
          const PopupMenuItem(value: 'web', child: Text('在 GitLab 開啟')),
          const PopupMenuItem(value: 'delete', child: Text('刪除')),
        ]),
      ]),
      body: gestureSafe(data == null ? (_error != null ? SingleChildScrollView(child: FailureNotice(_error!, onRetry: _load,
        account: widget.account, resourceLabel: '${widget.project.path} · $label',
        onSwitchAccount: endSessionFrom(context))) : const ListSkeleton()) : Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.project.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8), Text(valueText(data, 'title'), maxLines: 3, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10), Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
              children: [StatusBadge(valueText(data, 'state')), if (data['draft'] == true) const Text('草稿'),
                Text('@${valueText(valueObject(data, 'author'), 'username')}', style: Theme.of(context).textTheme.bodySmall)]),
          ])),
          TabBar(isScrollable: true, tabAlignment: TabAlignment.start,
            tabs: [const Tab(text: '摘要'), if (mr) const Tab(text: '變更'), const Tab(text: '討論'), if (mr) const Tab(text: '檢查')]),
          Expanded(child: TabBarView(children: [
            ListView(padding: const EdgeInsets.all(20), children: [
              if (_error != null) FailureNotice(_error!, onRetry: _load, account: widget.account,
                resourceLabel: '${widget.project.path} · $label', onSwitchAccount: endSessionFrom(context)),
              if (mr) _reviewCard(data),
              if (mr) Padding(padding: const EdgeInsets.only(bottom: 16), child: Card(child: Padding(padding: const EdgeInsets.all(14),
                child: Text('${valueText(data, 'source_branch')} → ${valueText(data, 'target_branch')}',
                  style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'], fontSize: 13))))),
              MarkdownView(valueText(data, 'description').isEmpty ? '尚未填寫說明。' : valueText(data, 'description'), base: web),
              const SizedBox(height: 24), const Divider(), const SizedBox(height: 16),
              Text('指派', style: Theme.of(context).textTheme.titleSmall), const SizedBox(height: 8),
              Text(valueObjects(data, 'assignees').isEmpty ? '尚未指派'
                : valueObjects(data, 'assignees').map((v) => '@${valueText(v, 'username')}').join('、')),
              if (data['labels'] is List<dynamic>) ...[const SizedBox(height: 16), Wrap(spacing: 6, runSpacing: 6,
                children: (data['labels'] as List<dynamic>).whereType<String>().map((label) => Chip(label: Text(label))).toList())],
              const SizedBox(height: 16), Text('更新於 ${relativeDate(valueText(data, 'updated_at'))}', style: Theme.of(context).textTheme.bodySmall),
            ]),
            if (mr) ReviewDiffPage(key: ValueKey(valueText(data, 'sha')), account: widget.account, api: widget.api,
              project: widget.project, iid: widget.iid, expectedSha: valueText(data, 'sha')),
            DiscussionsTab(account: widget.account, api: widget.api, project: widget.project, resource: widget.resource, iid: widget.iid),
            if (mr) _MergeChecks(account: widget.account, api: widget.api, path: path, data: data, busy: _busy, act: _action),
          ])),
        ],
      )),
    ));
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
      const SizedBox(height: 16), FilledButton.icon(onPressed: widget.busy ? null : () => widget.act('merge'),
        icon: const Icon(Icons.merge), label: const Text('合併…')),
      const SizedBox(height: 12), const Text('GitLab 會再次檢查 SHA、權限、保護分支及所有合併條件。', style: TextStyle(fontSize: 12)),
    ],
  ]);
}

String _branchValue(String name) => encodeChoices([PickerChoice(id: name, name: name)]);

String _labelsValue(Json data) {
  final raw = data['labels'];
  final names = <String>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) names.add(item.trim());
    }
  } else if (raw is String) {
    names.addAll(raw.split(',').map((part) => part.trim()).where((part) => part.isNotEmpty));
  }
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
