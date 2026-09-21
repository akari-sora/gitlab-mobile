import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'records_feed.dart';

class RepositoryTab extends StatefulWidget {
  const RepositoryTab({super.key, required this.account, required this.api, required this.project, this.active = true});
  final Account account;
  final GitLabApi api;
  final Project project;
  final bool active;
  @override
  State<RepositoryTab> createState() => _RepositoryTabState();
}
class _RepositoryTabState extends State<RepositoryTab> {
  String? _sha;
  late String _branch;
  String _folder = '';
  ApiFailure? _error;
  bool _loading = true;
  int _epoch = 0;
  final _feed = GlobalKey<RecordsFeedState>();
  @override
  void initState() {
    super.initState(); _branch = widget.project.defaultBranch ?? 'main';
    if (widget.project.defaultBranch?.isNotEmpty ?? false) { unawaited(_resolve()); }
    else { _loading = false; }
  }
  Future<void> _resolve() async {
    final epoch = ++_epoch;
    setState(() { _loading = true; _error = null; });
    try {
      final value = await widget.api.record(['projects', '${widget.project.id}', 'repository', 'branches', _branch]);
      final sha = requiredString(valueObject(value, 'commit'), 'id');
      if (!RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(sha)) { throw const ApiFailure(FailureKind.invalidResponse); }
      if (mounted && epoch == _epoch) { setState(() => _sha = sha); }
    } catch (e) { if (mounted && epoch == _epoch) { setState(() => _error = safeFailure(e)); } }
    finally { if (mounted && epoch == _epoch) { setState(() => _loading = false); } }
  }
  void _up() {
    final parts = _folder.split('/')..removeLast();
    setState(() => _folder = parts.join('/'));
  }
  Future<void> _branches() async {
    final selected = await Navigator.push<String>(context, MaterialPageRoute(builder: (context) => Scaffold(
      appBar: AppBar(title: const Text('選擇分支')), body: RecordsFeed(identity: 'branch-picker',
        account: widget.account, resourceLabel: '${widget.project.path} · 分支',
        onSwitchAccount: endSessionFrom(context),
        load: (next) => widget.api.records(['projects', '${widget.project.id}', 'repository', 'branches'], next: next),
        itemBuilder: (context, data) => Card(child: ListTile(leading: const Icon(Icons.alt_route),
          title: Text(valueText(data, 'name')), subtitle: data['protected'] == true ? const Text('受保護分支') : null,
          trailing: data['name'] == _branch ? const Icon(Icons.check) : null,
          onTap: () => Navigator.pop(context, requiredString(data, 'name')))),
      ),
    )));
    if (selected != null && mounted && selected != _branch) {
      setState(() { _branch = selected; _folder = ''; _sha = null; });
      await _resolve();
    }
  }
  Future<void> _newFile() async {
    final branch = _branch;
    final saved = await openEditor(context, account: widget.account, title: '新增檔案',
      resource: '${widget.project.id}/files/new/$branch/$_folder',
      subtitle: '${widget.project.path} · $branch', fields: [
        EditField('path', '完整檔案路徑', required: true, value: _folder.isEmpty ? '' : '$_folder/'),
        const EditField('content', '內容', lines: 10),
        const EditField('message', 'Commit 訊息', required: true, value: 'Add file from GitLab Mobile'),
      ], save: (values) async {
        await widget.api.saveFile(widget.project.id, values['path']!.trim(), branch: branch,
          content: values['content']!, message: values['message']!.trim());
      });
    if (saved && mounted) { await _resolve(); }
  }
  Future<void> _entry(Json data) async {
    final type = valueText(data, 'type');
    final path = requiredString(data, 'path');
    if (type == 'tree') { setState(() => _folder = path); return; }
    if (type != 'blob' || data['mode'] == '120000') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Submodule 與符號連結不會當成一般檔案開啟。')));
      }
      return;
    }
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => RepositoryFilePage(
      account: widget.account, api: widget.api, project: widget.project, branch: _branch, sha: _sha!, filePath: path)));
    if (changed == true && mounted) { await _resolve(); }
  }
  @override
  Widget build(BuildContext context) => PopScope(canPop: !widget.active || _folder.isEmpty,
    onPopInvokedWithResult: (didPop, _) { if (!didPop && widget.active && _folder.isNotEmpty) { _up(); } },
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 8, 8, 0), child: Row(children: [
        Expanded(child: TextButton.icon(onPressed: _loading ? null : _branches, icon: const Icon(Icons.alt_route, size: 18),
          label: Align(alignment: Alignment.centerLeft, child: Text(_branch, maxLines: 1, overflow: TextOverflow.ellipsis)))),
        IconButton(tooltip: '重新讀取最新版本', onPressed: _loading ? null : _resolve, icon: const Icon(Icons.refresh, size: 20)),
        IconButton(tooltip: '新增檔案', onPressed: widget.project.archived == true || _loading ? null : _newFile,
          icon: const Icon(Icons.note_add_outlined, size: 20)),
      ])),
      if (_sha != null) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text('固定版本 ${shortSha(_sha!)}', style: Theme.of(context).textTheme.bodySmall)),
      if (_folder.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
        IconButton(tooltip: '上一層目錄', onPressed: _up, icon: const Icon(Icons.arrow_upward, size: 18)),
        Expanded(child: Text(_folder, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
        TextButton(onPressed: () => setState(() => _folder = ''), child: const Text('根目錄')),
      ])),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      if (_error != null) FailureNotice(_error!, onRetry: _resolve, account: widget.account,
        resourceLabel: '${widget.project.path} · $_branch', onSwitchAccount: endSessionFrom(context)),
      Expanded(child: _sha == null ? (_loading ? const ListSkeleton() : const EmptyState('Repository 尚未初始化',
        detail: '新增第一個檔案後就會顯示內容。', icon: Icons.create_new_folder_outlined)) : RecordsFeed(
        key: _feed, identity: '${widget.project.id}/$_sha/$_folder', empty: '此目錄沒有檔案',
        account: widget.account, resourceLabel: '${widget.project.path} · $_folder',
        onSwitchAccount: endSessionFrom(context),
        load: (next) => widget.api.records(['projects', '${widget.project.id}', 'repository', 'tree'],
          query: {'ref': _sha!, 'path': _folder, 'per_page': '50'}, next: next),
        itemBuilder: (context, data) => Card(child: ListTile(
          leading: Icon(data['type'] == 'tree' ? Icons.folder_outlined : data['type'] == 'commit'
            ? Icons.link : Icons.description_outlined, color: data['type'] == 'tree' ? Theme.of(context).colorScheme.primary : null),
          title: Text(valueText(data, 'name'), maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right, size: 18), onTap: () => _entry(data),
        )),
      )),
    ]),
  );
}

class RepositoryFilePage extends StatefulWidget {
  const RepositoryFilePage({super.key, required this.account, required this.api, required this.project,
    required this.branch, required this.sha, required this.filePath});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String branch;
  final String sha;
  final String filePath;
  @override
  State<RepositoryFilePage> createState() => _RepositoryFilePageState();
}
class _RepositoryFilePageState extends State<RepositoryFilePage> {
  String? _text, _lastCommit;
  ApiFailure? _error;
  bool _loading = true, _busy = false, _preview = false, _wrap = true;
  String _query = '';
  late final bool _markdown;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  @override
  void initState() {
    super.initState(); _markdown = RegExp(r'\.(md|markdown)$', caseSensitive: false).hasMatch(widget.filePath);
    _preview = _markdown; unawaited(_load());
  }
  @override
  void dispose() {
    _vertical.dispose(); _horizontal.dispose(); super.dispose();
  }
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final meta = await widget.api.fileMetadata(widget.project.id, widget.filePath, widget.sha);
      final text = await widget.api.textFile(widget.project.id, widget.sha, widget.filePath);
      if (mounted) { setState(() { _text = text; _lastCommit = requiredString(meta, 'last_commit_id'); }); }
    } catch (e) { if (mounted) { setState(() => _error = safeFailure(e)); } }
    finally { if (mounted) { setState(() => _loading = false); } }
  }
  bool get _lfs => _text?.startsWith('version https://git-lfs.github.com/spec/v1') ?? false;
  Future<void> _checkCurrent() async {
    final current = await widget.api.fileMetadata(widget.project.id, widget.filePath, widget.branch);
    if (current['last_commit_id'] != _lastCommit) { throw const ApiFailure(FailureKind.conflict); }
  }
  Future<void> _edit() async {
    if (_busy || _text == null || _lfs) { return; }
    final saved = await openEditor(context, account: widget.account, title: '編輯檔案',
      resource: '${widget.project.id}/files/${widget.branch}/${widget.filePath}/${widget.sha}',
      subtitle: '${widget.filePath} · ${widget.branch}', fields: [
        EditField('content', '內容', lines: 12, value: _text!),
        const EditField('message', 'Commit 訊息', required: true, value: 'Update file from GitLab Mobile'),
      ], save: (values) async {
        await _checkCurrent();
        await widget.api.saveFile(widget.project.id, widget.filePath, branch: widget.branch,
          content: values['content']!, message: values['message']!.trim(), lastCommit: _lastCommit);
      });
    if (saved && mounted) { Navigator.pop(context, true); }
  }
  Future<void> _delete() async {
    if (_busy || _lastCommit == null) { return; }
    if (!await confirmAction(context, '刪除檔案？',
      '${widget.filePath}\n分支 ${widget.branch}\n會建立刪除檔案的 commit。', requiredText: widget.filePath)) { return; }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      await _checkCurrent();
      await widget.api.deleteFile(widget.project.id, widget.filePath, branch: widget.branch,
        message: 'Delete ${widget.filePath} from GitLab Mobile', lastCommit: _lastCommit!);
      if (mounted) { Navigator.pop(context, true); }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  @override
  Widget build(BuildContext context) {
    final text = _text;
    final lines = text?.split('\n') ?? [];
    final matches = <int>[for (var i = 0; i < lines.length; i++)
      if (_query.isEmpty || lines[i].toLowerCase().contains(_query.toLowerCase())) i];
    return Scaffold(appBar: AppBar(title: Text(widget.filePath.split('/').last), actions: [
      if (_markdown) IconButton(tooltip: _preview ? '顯示原始文字' : 'Markdown 預覽',
        onPressed: () => setState(() => _preview = !_preview), icon: Icon(_preview ? Icons.code : Icons.preview_outlined)),
      PopupMenuButton<String>(tooltip: '檔案操作', onSelected: (action) {
        if (action == 'edit') { unawaited(_edit()); }
        if (action == 'delete') { unawaited(_delete()); }
        if (action == 'wrap') { setState(() => _wrap = !_wrap); }
      }, itemBuilder: (_) => [
        PopupMenuItem(value: 'wrap', child: Text(_wrap ? '關閉自動換行' : '開啟自動換行')),
        if (text != null && !_lfs && widget.project.archived != true && !_busy) ...[
          const PopupMenuItem(value: 'edit', child: Text('編輯檔案')),
          const PopupMenuItem(value: 'delete', child: Text('刪除檔案')),
        ],
      ]),
    ]), body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: Text(
        '${widget.filePath}\n${widget.branch} · ${shortSha(widget.sha)}', style: Theme.of(context).textTheme.bodySmall)),
      if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
      if (_error != null) FailureNotice(_error!, onRetry: _load, account: widget.account,
        resourceLabel: '${widget.project.path} · ${widget.filePath}', onSwitchAccount: endSessionFrom(context)),
      if (_lfs) const Padding(padding: EdgeInsets.all(16), child: Text('這是 Git LFS pointer，不是原始檔案。此版本不會自動下載大型物件。')),
      if (text != null && !_preview) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: TextField(decoration: const InputDecoration(hintText: '搜尋目前檔案', prefixIcon: Icon(Icons.search)),
          onChanged: (value) => setState(() => _query = value))),
      Expanded(child: text == null ? const SizedBox() : _preview
        ? SingleChildScrollView(padding: const EdgeInsets.all(20), child: MarkdownView(text,
            base: widget.account.instance.projectWeb('${widget.project.path}/-/blob/${widget.sha}/${widget.filePath}')))
        : LayoutBuilder(builder: (context, constraints) {
            final fontSize = MediaQuery.textScalerOf(context).scale(13);
            final longest = lines.fold<int>(0, (n, line) => math.max(n, line.length));
            final contentWidth = _wrap ? constraints.maxWidth
              : math.max(constraints.maxWidth, math.min(24000.0, longest * fontSize * 0.65 + 80));
            return Directionality(textDirection: TextDirection.ltr, child: Scrollbar(controller: _horizontal,
              child: SingleChildScrollView(controller: _horizontal, scrollDirection: Axis.horizontal,
                physics: _wrap ? const NeverScrollableScrollPhysics() : null,
                child: SizedBox(width: contentWidth, height: constraints.maxHeight,
                  child: SelectionArea(child: ListView.builder(controller: _vertical, itemCount: matches.length,
                    padding: const EdgeInsets.symmetric(vertical: 12), itemBuilder: (context, index) {
                      final number = matches[index];
                      return Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3), child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(width: 40, child: Text('${number + 1}', style: Theme.of(context).textTheme.bodySmall)),
                          Expanded(child: Text(lines[number].isEmpty ? ' ' : lines[number],
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.55))),
                        ],
                      ));
                    }))))));
          })),
    ]));
  }
}
