import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'records_feed.dart';
import '../../shared/theme.dart';

enum MetadataKind { branches, tags, commits, releases, labels, milestones }
String metadataTitle(MetadataKind kind) => switch (kind) {
  MetadataKind.branches => '分支', MetadataKind.tags => '標籤版本', MetadataKind.commits => '提交紀錄',
  MetadataKind.releases => 'Releases', MetadataKind.labels => '議題標籤', MetadataKind.milestones => '里程碑',
};

class ProjectMoreTab extends StatefulWidget {
  const ProjectMoreTab({super.key, required this.account, required this.api, required this.project, required this.onChanged});
  final Account account;
  final GitLabApi api;
  final Project project;
  final ValueChanged<Project> onChanged;
  @override
  State<ProjectMoreTab> createState() => _ProjectMoreTabState();
}
class _ProjectMoreTabState extends State<ProjectMoreTab> {
  bool _busy = false;
  Future<void> _edit() async {
    Project? updated;
    final saved = await openEditor(context, account: widget.account, title: '專案設定',
      resource: '${widget.project.id}/settings', subtitle: widget.project.path,
      fields: [EditField('name', '顯示名稱', required: true, value: widget.project.name),
        EditField('description', '專案說明', lines: 6, value: widget.project.description ?? '')], save: (values) async {
        updated = await widget.api.editProject(widget.project.id, name: values['name']!.trim(), description: values['description']!);
      });
    if (saved && mounted && updated != null) { widget.onChanged(updated!); }
  }
  Future<void> _star(bool starred) async {
    if (_busy) { return; }
    setState(() => _busy = true);
    try {
      await widget.api.setStar(widget.project.id, starred);
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(starred ? '已加入星標' : '已移除星標'))); }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Future<void> _delete() async {
    if (_busy || !await confirmAction(context, '刪除整個專案？',
      '包含 repository、議題、MR 及相關資料。部分實例會先排程刪除；App 不會要求立即永久刪除。',
      requiredText: widget.project.path)) { return; }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      await widget.api.deleteProject(widget.project.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('GitLab 已接受專案刪除要求。')));
        Navigator.pop(context);
      }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
    if (widget.project.description?.isNotEmpty ?? false) Padding(padding: const EdgeInsets.only(bottom: 20),
      child: MarkdownView(widget.project.description!, base: widget.account.instance.projectWeb(widget.project.path))),
    for (final kind in MetadataKind.values) Padding(padding: const EdgeInsets.only(bottom: 8), child: Card(child: ListTile(
      leading: Icon(switch (kind) {
        MetadataKind.branches => Icons.alt_route, MetadataKind.tags => Icons.sell_outlined,
        MetadataKind.commits => Icons.history, MetadataKind.releases => Icons.inventory_2_outlined,
        MetadataKind.labels => Icons.label_outline, MetadataKind.milestones => Icons.flag_outlined,
      }), title: Text(metadataTitle(kind)), trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MetadataPage(
        account: widget.account, api: widget.api, project: widget.project, kind: kind))),
    ))),
    const SizedBox(height: 16), Text('專案管理', style: Theme.of(context).textTheme.titleSmall), const SizedBox(height: 8),
    Card(child: Column(children: [
      ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('名稱與說明'),
        onTap: _busy || widget.project.archived == true ? null : _edit),
      const Divider(), ListTile(leading: const Icon(Icons.star_border), title: const Text('加入星標'), onTap: _busy ? null : () => _star(true)),
      const Divider(), ListTile(leading: const Icon(Icons.star_half), title: const Text('移除星標'), onTap: _busy ? null : () => _star(false)),
    ])),
    const SizedBox(height: 24), OutlinedButton.icon(onPressed: _busy ? null : _delete,
      icon: const Icon(Icons.delete_outline), label: const Text('刪除專案…')),
    const SizedBox(height: 12), Text('ID ${widget.project.id} · @${widget.account.user.username}', style: Theme.of(context).textTheme.bodySmall),
  ]);
}

class MetadataPage extends StatefulWidget {
  const MetadataPage({super.key, required this.account, required this.api, required this.project, required this.kind});
  final Account account;
  final GitLabApi api;
  final Project project;
  final MetadataKind kind;
  @override
  State<MetadataPage> createState() => _MetadataPageState();
}
class _MetadataPageState extends State<MetadataPage> {
  final _feed = GlobalKey<RecordsFeedState>();
  bool _busy = false;
  List<String> get path => ['projects', '${widget.project.id}',
    if (const [MetadataKind.branches, MetadataKind.tags, MetadataKind.commits].contains(widget.kind)) 'repository', widget.kind.name];
  String _name(Json value) => valueText(value, widget.kind == MetadataKind.commits ? 'title'
    : widget.kind == MetadataKind.milestones ? 'title' : 'name', valueText(value, 'tag_name'));
  String _detail(Json value) => widget.kind == MetadataKind.commits
    ? valueText(value, 'author_name')
    : valueText(value, 'description', valueText(valueObject(value, 'commit'), 'title'));
  /// Leading mark per kind: label colour swatch, branch/tag/commit glyphs.
  Widget _leading(BuildContext context, Json value) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.kind == MetadataKind.labels) {
      final hex = valueText(value, 'color').replaceFirst('#', '');
      final parsed = int.tryParse(hex.length == 6 ? 'FF$hex' : hex, radix: 16);
      return Container(width: 40, height: 40, alignment: Alignment.center,
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
        child: Container(width: 16, height: 16,
          decoration: BoxDecoration(color: parsed == null ? scheme.outline : Color(parsed), shape: BoxShape.circle)));
    }
    final icon = switch (widget.kind) {
      MetadataKind.branches => Icons.alt_route, MetadataKind.tags => Icons.sell_outlined,
      MetadataKind.commits => Icons.commit, MetadataKind.releases => Icons.inventory_2_outlined,
      MetadataKind.milestones => Icons.flag_outlined, MetadataKind.labels => Icons.label_outline,
    };
    return Container(width: 40, height: 40, alignment: Alignment.center,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, size: 20, color: scheme.onSurfaceVariant));
  }
  List<Widget> _meta(Json value) => switch (widget.kind) {
    MetadataKind.commits => [
      MetaChip(shortSha(valueText(value, 'id')), mono: true),
      MetaChip(relativeDate(valueText(value, 'committed_date', valueText(value, 'created_at'))), icon: Icons.schedule_outlined),
    ],
    MetadataKind.branches => [
      if (value['default'] == true) const MetaChip('預設', icon: Icons.star_outline),
      if (value['protected'] == true) const MetaChip('受保護', icon: Icons.lock_outline),
      MetaChip(shortSha(valueText(valueObject(value, 'commit'), 'id')), mono: true),
    ],
    MetadataKind.tags => [
      MetaChip(shortSha(valueText(valueObject(value, 'commit'), 'id')), mono: true),
      if (valueText(value, 'message').isNotEmpty) const MetaChip('附註標籤', icon: Icons.notes_outlined),
    ],
    MetadataKind.releases => [
      MetaChip(valueText(value, 'tag_name'), icon: Icons.sell_outlined, mono: true),
      MetaChip(relativeDate(valueText(value, 'released_at', valueText(value, 'created_at'))), icon: Icons.schedule_outlined),
    ],
    MetadataKind.milestones => [
      if (valueText(value, 'state').isNotEmpty) StatusBadge(valueText(value, 'state')),
      if (valueText(value, 'due_date').isNotEmpty) MetaChip('到期 ${valueText(value, 'due_date')}', icon: Icons.event_outlined),
    ],
    MetadataKind.labels => [
      if (valueInt(value, 'open_issues_count') > 0) MetaChip('${valueInt(value, 'open_issues_count')} 則開啟議題', icon: Icons.adjust),
    ],
  };
  String _id(Json value) => switch (widget.kind) {
    MetadataKind.branches || MetadataKind.tags => requiredString(value, 'name'),
    MetadataKind.releases => requiredString(value, 'tag_name'),
    MetadataKind.commits => requiredString(value, 'id'),
    _ => '${requiredInt(value, 'id')}',
  };
  bool _canEdit(Json value) => !const [MetadataKind.branches, MetadataKind.tags, MetadataKind.commits].contains(widget.kind);
  bool _canDelete(Json value) => widget.kind != MetadataKind.commits &&
    !(widget.kind == MetadataKind.branches && (value['default'] == true || value['protected'] == true));
  List<EditField> _fields(Json? value) {
    final data = value ?? <String, dynamic>{};
    final ref = widget.project.defaultBranch ?? 'main';
    return switch (widget.kind) {
      MetadataKind.branches => [const EditField('branch', '新分支名稱', required: true),
        EditField('ref', '來源 ref 或 commit SHA', required: true, value: ref)],
      MetadataKind.tags => [const EditField('tag_name', '新標籤名稱', required: true),
        EditField('ref', '來源 ref 或 commit SHA', required: true, value: ref), const EditField('message', '標籤訊息', lines: 3)],
      MetadataKind.releases => [
        if (value == null) const EditField('tag_name', '既有 Git tag', required: true),
        EditField('name', 'Release 名稱', required: true, value: valueText(data, 'name')),
        EditField('description', '發行說明', lines: 9, value: valueText(data, 'description'), hint: '支援 Markdown'),
      ],
      MetadataKind.labels => [EditField('name', '名稱', required: true, value: valueText(data, 'name')),
        EditField('color', '顏色', required: true, value: valueText(data, 'color', '#4763e4'), hint: '#RRGGBB'),
        EditField('description', '說明', lines: 3, value: valueText(data, 'description'))],
      MetadataKind.milestones => [EditField('title', '標題', required: true, value: valueText(data, 'title')),
        EditField('description', '說明', lines: 5, value: valueText(data, 'description')),
        EditField('start_date', '開始日期', value: valueText(data, 'start_date'), hint: 'YYYY-MM-DD；可留白'),
        EditField('due_date', '到期日期', value: valueText(data, 'due_date'), hint: 'YYYY-MM-DD；可留白')],
      MetadataKind.commits => [],
    };
  }
  Future<void> _edit([Json? value]) async {
    if (_busy) { return; }
    final saved = await openEditor(context, account: widget.account,
      title: '${value == null ? '新增' : '編輯'}${metadataTitle(widget.kind)}',
      resource: '${widget.project.id}/${widget.kind.name}/${value == null ? 'new' : _id(value)}',
      subtitle: widget.project.path, fields: _fields(value), save: (values) async {
        final body = <String, dynamic>{...values};
        if (widget.kind == MetadataKind.labels && !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(values['color'] ?? '')) {
          throw const ApiFailure(FailureKind.validation);
        }
        if (widget.kind == MetadataKind.milestones) {
          for (final key in ['start_date', 'due_date']) {
            final date = values[key]?.trim() ?? '';
            if (date.isNotEmpty && (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) || DateTime.tryParse(date) == null ||
                DateTime.parse(date).toIso8601String().substring(0, 10) != date)) {
              throw const ApiFailure(FailureKind.validation);
            }
            body[key] = date.isEmpty ? null : date;
          }
        }
        if (value == null) { await widget.api.writeRecord('POST', path, body); }
        else { await widget.api.writeRecord('PUT', [...path, _id(value)], body); }
      });
    if (saved && mounted) { await _feed.currentState?.refresh(); }
  }
  Future<void> _delete(Json value) async {
    if (_busy || !await confirmAction(context, '刪除${metadataTitle(widget.kind)}？', _name(value), requiredText: _name(value))) { return; }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      await widget.api.removeRecord([...path, _id(value)]);
      if (mounted) { await _feed.currentState?.refresh(); }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Future<void> _state(Json value) async {
    if (_busy) { return; }
    setState(() => _busy = true);
    try {
      await widget.api.writeRecord('PUT', [...path, _id(value)], {'state_event': value['state'] == 'closed' ? 'activate' : 'close'});
      if (mounted) { await _feed.currentState?.refresh(); }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Future<void> _view(Json value) async {
    await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: Text(_name(value))), body: gestureSafe(ListView(padding: const EdgeInsets.all(20), children: [
        Text(widget.project.path, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 16),
        if (value['state'] is String) Align(alignment: Alignment.centerLeft, child: StatusBadge(valueText(value, 'state'))),
        if (widget.kind == MetadataKind.commits) ...[
          SelectableText(_id(value), style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'], fontSize: 12)),
          const SizedBox(height: 16), SelectableText(valueText(value, 'message')),
          const SizedBox(height: 16), Text(valueText(value, 'author_name')),
        ] else MarkdownView(valueText(value, 'description', valueText(value, 'message', '尚未填寫說明。')),
          base: widget.account.instance.projectWeb(widget.project.path)),
        if (value['commit'] is Json) ...[const SizedBox(height: 20), Text(valueText(valueObject(value, 'commit'), 'title')),
          SelectableText(valueText(valueObject(value, 'commit'), 'id'), style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'], fontSize: 12))],
        if (widget.kind == MetadataKind.milestones) ...[const SizedBox(height: 16),
          Text('開始：${valueText(value, 'start_date', '未設定')}\n到期：${valueText(value, 'due_date', '未設定')}')],
      ])),
    )));
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(metadataTitle(widget.kind)), actions: [
    if (widget.kind != MetadataKind.commits) IconButton(tooltip: '新增${metadataTitle(widget.kind)}',
      onPressed: _busy || widget.project.archived == true ? null : _edit, icon: const Icon(Icons.add)),
  ]), body: gestureSafe(RecordsFeed(key: _feed, identity: '${widget.project.id}/${widget.kind.name}',
    account: widget.account, resourceLabel: '${widget.project.path} · ${metadataTitle(widget.kind)}',
    onSwitchAccount: endSessionFrom(context),
    empty: '尚無${metadataTitle(widget.kind)}', load: (next) => widget.api.records(path,
      query: {if (widget.kind == MetadataKind.labels) 'include_ancestor_groups': 'false'}, next: next),
    itemBuilder: (context, value) => EntityCard(
      onTap: () => _view(value),
      leading: _leading(context, value),
      title: Text(_name(value)),
      body: _detail(value).isEmpty ? null : Text(_detail(value), maxLines: 2, overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      meta: _meta(value),
      trailing: widget.kind == MetadataKind.commits || widget.project.archived == true ? null
        : PopupMenuButton<String>(tooltip: '項目操作', enabled: !_busy, onSelected: (action) {
          if (action == 'edit') { _edit(value); }
          if (action == 'delete') { _delete(value); }
          if (action == 'state') { _state(value); }
        }, itemBuilder: (_) => [
          if (_canEdit(value)) const PopupMenuItem(value: 'edit', child: Text('編輯')),
          if (widget.kind == MetadataKind.milestones) PopupMenuItem(value: 'state', child: Text(value['state'] == 'closed' ? '重新啟用' : '關閉里程碑')),
          if (_canDelete(value)) const PopupMenuItem(value: 'delete', child: Text('刪除')),
        ]),
    ),
  )));
}
