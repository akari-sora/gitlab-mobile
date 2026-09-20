import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'records_feed.dart';

class DiscussionsTab extends StatefulWidget {
  const DiscussionsTab({super.key, required this.account, required this.api, required this.project, required this.resource, required this.iid});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  final int iid;
  @override
  State<DiscussionsTab> createState() => _DiscussionsTabState();
}
class _DiscussionsTabState extends State<DiscussionsTab> {
  final _feed = GlobalKey<RecordsFeedState>();
  bool _busy = false;
  List<String> get path => ['projects', '${widget.project.id}', widget.resource, '${widget.iid}'];
  Future<void> _compose({Json? note, String? discussion, bool thread = false}) async {
    if (_busy) { return; }
    final saved = await openEditor(context, account: widget.account,
      title: note != null ? '編輯留言' : discussion != null ? '回覆討論' : thread ? '新增討論串' : '新增留言',
      resource: '${path.join('/')}/${discussion ?? 'root'}/${note?['id'] ?? (thread ? 'thread-new' : 'new')}',
      subtitle: '${widget.project.path} · ${widget.resource == 'issues' ? '#' : '!'}${widget.iid}', fields: [
        EditField('body', '留言內容', required: true, lines: 9, value: note == null ? '' : valueText(note, 'body'),
          hint: '支援 Markdown；以 / 開頭的行可能執行 GitLab quick actions'),
      ], save: (values) async {
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
  @override
  Widget build(BuildContext context) => Column(children: [
    Expanded(child: RecordsFeed(key: _feed, identity: '${path.join('/')}/discussions', empty: '還沒有討論',
      load: (next) => widget.api.records([...path, 'discussions'], next: next), itemBuilder: (context, discussion) {
        final notes = valueObjects(discussion, 'notes');
        final isThread = discussion['individual_note'] == false;
        final discussionId = isThread ? requiredString(discussion, 'id') : null;
        final resolvable = widget.resource == 'merge_requests' && notes.any((v) => v['resolvable'] == true);
        final resolved = notes.where((v) => v['resolvable'] == true).every((v) => v['resolved'] == true);
        return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            const SizedBox(height: 8), MarkdownView(valueText(notes[index], 'body'), base: widget.account.instance.projectWeb(widget.project.path)),
            const SizedBox(height: 8), Text(relativeDate(valueText(notes[index], 'created_at')), style: Theme.of(context).textTheme.bodySmall),
          ],
          if (isThread) Wrap(spacing: 8, children: [
            TextButton.icon(onPressed: _busy ? null : () => _compose(discussion: discussionId), icon: const Icon(Icons.reply, size: 18), label: const Text('回覆')),
            if (resolvable) TextButton.icon(onPressed: _busy ? null : () => _resolve(discussion, !resolved),
              icon: Icon(resolved ? Icons.undo : Icons.check, size: 18), label: Text(resolved ? '重新開啟討論' : '解決討論')),
          ]),
        ])));
      })),
    SafeArea(top: false, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Wrap(
      spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: _busy ? null : () => _compose(), icon: const Icon(Icons.add_comment_outlined), label: const Text('留言')),
        OutlinedButton(onPressed: _busy ? null : () => _compose(thread: true), child: const Text('新增討論串')),
      ]))),
  ]);
}
