import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'diff_page.dart';
import 'editor.dart';
import 'records_feed.dart';

bool _discussionResolved(Json discussion) {
  final resolvable = valueObjects(discussion, 'notes').where((note) => note['resolvable'] == true);
  return resolvable.isNotEmpty && resolvable.every((note) => note['resolved'] == true);
}

String _discussionSummary(List<Json> items, {required bool partial}) {
  final line = '${partial ? '已載入 ' : ''}${items.length} 則討論';
  final resolvable = items.any((item) => valueObjects(item, 'notes').any((note) => note['resolvable'] == true));
  if (!partial && !resolvable) { return line; }
  return '$line · ${items.where(_discussionResolved).length} 已解決';
}

class DiscussionsTab extends StatefulWidget {
  const DiscussionsTab({super.key, required this.account, required this.api, required this.project, required this.resource, required this.iid, this.headSha});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  final int iid;
  final String? headSha;
  @override
  State<DiscussionsTab> createState() => _DiscussionsTabState();
}
class _DiscussionsTabState extends State<DiscussionsTab> {
  final _feed = GlobalKey<RecordsFeedState>();
  final _open = <String>{};
  bool _busy = false, _unresolvedOnly = false;
  List<String> get path => ['projects', '${widget.project.id}', widget.resource, '${widget.iid}'];
  void _toggle(String id) => setState(() { if (!_open.remove(id)) { _open.add(id); } });
  Future<void> _compose({Json? note, String? discussion, bool thread = false}) async {
    if (_busy) { return; }
    final saved = await openEditor(context, account: widget.account,
      title: note != null ? '編輯留言' : discussion != null ? '回覆討論' : thread ? '新增討論串' : '新增留言',
      resource: '${path.join('/')}/${discussion ?? 'root'}/${note?['id'] ?? (thread ? 'thread-new' : 'new')}',
      subtitle: '${widget.project.path} · ${widget.resource == 'issues' ? '#' : '!'}${widget.iid}', fields: [
        EditField('body', '留言內容', required: true, lines: 9, markdown: true,
          value: note == null ? '' : valueText(note, 'body'),
          hint: '支援 Markdown；以 / 開頭的行可能執行 GitLab quick actions'),
      ], api: widget.api, projectId: widget.project.id, projectPath: widget.project.path, save: (values) async {
        if (note != null) {
          final endpoint = discussion == null ? [...path, 'notes', '${note['id']}']
            : [...path, 'discussions', discussion, 'notes', '${note['id']}'];
          await widget.api.writeRecord('PUT', endpoint, {'body': values['body']});
        } else if (discussion != null) {
          await widget.api.writeRecord('POST', [...path, 'discussions', discussion, 'notes'], {'body': values['body']});
        } else {
          await widget.api.writeRecord('POST', [...path, thread ? 'discussions' : 'notes'], {'body': values['body']});
        }
      });
    if (saved && mounted) { await _feed.currentState?.refresh(); }
  }
  Future<void> _delete(Json note, String? discussion) async {
    if (_busy || !await confirmAction(context, '刪除留言？', '此操作無法復原。')) { return; }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      final endpoint = discussion == null ? [...path, 'notes', '${note['id']}']
        : [...path, 'discussions', discussion, 'notes', '${note['id']}'];
      await widget.api.removeRecord(endpoint);
      if (mounted) { await _feed.currentState?.refresh(); }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Future<void> _resolve(Json discussion, bool resolved) async {
    if (_busy) { return; }
    setState(() => _busy = true);
    try {
      await widget.api.writeRecord('PUT', [...path, 'discussions', requiredString(discussion, 'id')], {'resolved': resolved});
      if (mounted) { await _feed.currentState?.refresh(); }
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
      button: true, expanded: isOpen, hint: isOpen ? '收合討論' : '展開討論',
      child: InkWell(
        onTap: () => _toggle(id),
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(author, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall)),
              const SizedBox(width: 8),
              Text(relativeDate(valueText(first, 'created_at')), maxLines: 1,
                style: Theme.of(context).textTheme.bodySmall),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              DecoratedBox(decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8)), child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2), child: Text('已解決'))),
              Text('${notes.length} 則', style: Theme.of(context).textTheme.bodySmall),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var index = 0; index < notes.length; index++) ...[
        if (index > 0) const Divider(height: 28),
        Row(children: [Expanded(child: Text('@${valueText(valueObject(notes[index], 'author'), 'username')}',
          style: Theme.of(context).textTheme.titleSmall)),
          if (notes[index]['system'] != true && valueInt(valueObject(notes[index], 'author'), 'id') == widget.account.user.id)
            PopupMenuButton<String>(tooltip: '留言操作', enabled: !_busy,
              onSelected: (action) => action == 'edit' ? _compose(note: notes[index], discussion: discussionId) : _delete(notes[index], discussionId),
              itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('編輯留言')), PopupMenuItem(value: 'delete', child: Text('刪除留言'))]),
        ]),
        if (notes[index]['position'] is Json) Text('${valueText(valueObject(notes[index], 'position'), 'new_path')} · '
          '${valueObject(notes[index], 'position')['new_line'] ?? valueObject(notes[index], 'position')['old_line'] ?? ''}',
          style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8), MarkdownView(valueText(notes[index], 'body'),
          base: widget.account.instance.projectWeb(widget.project.path), api: widget.api, projectId: widget.project.id,
          projectWeb: widget.account.instance.projectWeb(widget.project.path)),
        const SizedBox(height: 8), Text(relativeDate(valueText(notes[index], 'created_at')), style: Theme.of(context).textTheme.bodySmall),
      ],
      if (isThread) Wrap(spacing: 8, children: [
        if (textPosition != null && widget.resource == 'merge_requests') TextButton.icon(
          onPressed: _busy ? null : () => _openDiff(textPosition),
          icon: const Icon(Icons.code, size: 18), label: const Text('查看程式碼')),
        TextButton.icon(onPressed: _busy ? null : () => _compose(discussion: discussionId), icon: const Icon(Icons.reply, size: 18), label: const Text('回覆')),
        if (resolvable) TextButton.icon(onPressed: _busy ? null : () => _resolve(discussion, !resolved),
          icon: Icon(resolved ? Icons.undo : Icons.check, size: 18), label: Text(resolved ? '重新開啟討論' : '解決討論')),
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
      if (sha.isEmpty) sha = valueText(await widget.api.record(path), 'sha');
      if (!mounted || sha.isEmpty) return;
      // Same rule as inline anchoring: a supplied coordinate that is not a
      // positive int drops both lines, so the thread is listed under
      // 其他版本 instead of anchored on the row that matches its valid half.
      final lines = diffPositionLines(position);
      await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('差異')),
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
    Expanded(child: RecordsFeed(key: _feed, identity: '${path.join('/')}/discussions', empty: '還沒有討論',
      filteredEmpty: '沒有未解決的討論',
      account: widget.account, resourceLabel: '${widget.project.path} · 討論',
      onSwitchAccount: endSessionFrom(context),
      load: (next) => widget.api.records([...path, 'discussions'], next: next),
      visible: (item) => !_unresolvedOnly || !_discussionResolved(item),
      header: (_, controller) {
        if (controller.items.isEmpty && (controller.loading || controller.error != null)) { return const SizedBox.shrink(); }
        return Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_discussionSummary(controller.items, partial: controller.next != null), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            FilterChip(label: const Text('只看未解決'), selected: _unresolvedOnly, showCheckmark: false,
              onSelected: (value) => setState(() => _unresolvedOnly = value)),
          ],
        ));
      },
      itemBuilder: (context, discussion) {
        final notes = valueObjects(discussion, 'notes');
        final resolved = _discussionResolved(discussion);
        if (!resolved) {
          return Card(child: Padding(padding: const EdgeInsets.all(16), child: _thread(discussion)));
        }
        final collapsed = !_open.contains(valueText(discussion, 'id'));
        return Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(discussion, notes),
          if (!collapsed) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: _thread(discussion)),
        ]));
      })),
    SafeArea(top: false, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Wrap(
      spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: _busy ? null : () => _compose(), icon: const Icon(Icons.add_comment_outlined), label: const Text('留言')),
        OutlinedButton(onPressed: _busy ? null : () => _compose(thread: true), child: const Text('新增討論串')),
      ]))),
  ]);
}
