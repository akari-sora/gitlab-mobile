import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/failure.dart';
import '../../core/unified_diff.dart';
import '../../shared/external_link.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';

class ReviewDiffPage extends StatefulWidget {
  const ReviewDiffPage({super.key, required this.account, required this.api,
    required this.project, required this.iid, required this.expectedSha});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final String expectedSha;
  @override
  State<ReviewDiffPage> createState() => _ReviewDiffPageState();
}
class _ReviewDiffPageState extends State<ReviewDiffPage> {
  Json? _version;
  ApiFailure? _error;
  bool _loading = true;
  List<String> get path => ['projects', '${widget.project.id}', 'merge_requests', '${widget.iid}'];
  @override
  void initState() { super.initState(); unawaited(_load()); }
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final versions = await widget.api.records([...path, 'versions']);
      final matches = versions.items.where((value) => value['head_commit_sha'] == widget.expectedSha);
      if (matches.isEmpty) { throw const ApiFailure(FailureKind.conflict); }
      final version = await widget.api.record([...path, 'versions', '${requiredInt(matches.first, 'id')}']);
      if (version['head_commit_sha'] != widget.expectedSha) {
        throw const ApiFailure(FailureKind.conflict);
      }
      if (mounted) { setState(() => _version = version); }
    } catch (e) { if (mounted) { setState(() => _error = safeFailure(e)); } }
    finally { if (mounted) { setState(() => _loading = false); } }
  }
  Future<void> _open(Json file) async {
    final version = _version!;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _DiffFileScreen(
      account: widget.account, api: widget.api, project: widget.project, iid: widget.iid,
      file: file, version: version)));
  }
  @override
  Widget build(BuildContext context) {
    if (_loading) { return const ListSkeleton(); }
    if (_error != null) { return ListView(children: [FailureNotice(_error!, onRetry: _load)]); }
    final files = valueObjects(_version ?? {}, 'diffs');
    return RefreshIndicator(onRefresh: _load, child: ListView(
      physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
        Text('固定版本 ${shortSha(widget.expectedSha)}', style: Theme.of(context).textTheme.bodySmall),
        if (_version?['overflow'] == true) const Padding(padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('GitLab 限制了部分差異。下列檔案不代表完整變更。')),
        if (files.isEmpty) const EmptyState('沒有可顯示的文字差異', detail: '可能沒有變更，或差異未由伺服器提供。'),
        for (final file in files) Padding(padding: const EdgeInsets.only(top: 10), child: Card(child: ListTile(
          leading: Icon(file['new_file'] == true ? Icons.add_box_outlined : file['deleted_file'] == true
            ? Icons.indeterminate_check_box_outlined : Icons.code),
          title: Text(valueText(file, 'new_path', valueText(file, 'old_path'))),
          subtitle: file['renamed_file'] == true ? Text('原路徑：${valueText(file, 'old_path')}') : null,
          trailing: const Icon(Icons.chevron_right, size: 18), onTap: () => _open(file),
        ))),
      ],
    ));
  }
}
class _DiffFileScreen extends StatefulWidget {
  const _DiffFileScreen({required this.account, required this.api, required this.project,
    required this.iid, required this.file, required this.version});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final Json file;
  final Json version;
  @override
  State<_DiffFileScreen> createState() => _DiffFileScreenState();
}
class _DiffFileScreenState extends State<_DiffFileScreen> {
  List<DiffLine>? _lines;
  String? _unavailable;
  @override
  void initState() {
    super.initState();
    final diff = valueText(widget.file, 'diff');
    if (widget.file['too_large'] == true || widget.file['collapsed'] == true || diff.isEmpty) {
      _unavailable = 'GitLab 未提供這份文字差異，或內容為二進位檔案。';
    } else {
      try { _lines = parseUnifiedDiff(diff); }
      on FormatException { _unavailable = '這份差異不完整或超過排版上限，已停用行內留言，避免貼錯位置。'; }
    }
  }
  Future<void> _comment(DiffLine line) async {
    if (!line.commentable) { return; }
    final oldPath = requiredString(widget.file, 'old_path');
    final newPath = requiredString(widget.file, 'new_path');
    final sha = requiredString(widget.version, 'head_commit_sha');
    final position = <String, dynamic>{
      'position_type': 'text', 'base_sha': requiredString(widget.version, 'base_commit_sha'),
      'start_sha': requiredString(widget.version, 'start_commit_sha'), 'head_sha': sha,
      'old_path': oldPath, 'new_path': newPath,
      if (line.oldLine != null) 'old_line': line.oldLine,
      if (line.newLine != null) 'new_line': line.newLine,
    };
    await openEditor(context, account: widget.account, title: '對這一行留言',
      resource: '${widget.project.id}/mr/${widget.iid}/$sha/$oldPath/$newPath/${line.oldLine}/${line.newLine}',
      subtitle: '$newPath · ${line.newLine ?? line.oldLine} · ${shortSha(sha)}',
      fields: const [EditField('body', '留言', lines: 8, required: true)], save: (values) async {
        final path = ['projects', '${widget.project.id}', 'merge_requests', '${widget.iid}'];
        final current = await widget.api.record(path);
        if (current['sha'] != sha) { throw const ApiFailure(FailureKind.conflict); }
        await widget.api.writeRecord('POST', [...path, 'discussions'], {'body': values['body'], 'position': position});
      });
  }
  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(appBar: AppBar(title: Text(valueText(widget.file, 'new_path'),
      maxLines: 1, overflow: TextOverflow.ellipsis), actions: [
      IconButton(tooltip: '在 GitLab 開啟', icon: const Icon(Icons.open_in_new), onPressed: () => openExternal(context,
        widget.account.instance.projectWeb('${widget.project.path}/-/merge_requests/${widget.iid}/diffs'))),
    ]), body: lines == null ? EmptyState('無法顯示差異', detail: _unavailable, icon: Icons.code_off) : Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('點選程式碼行新增留言 · ${shortSha(valueText(widget.version, 'head_commit_sha'))}',
            style: Theme.of(context).textTheme.bodySmall)),
        Expanded(child: SelectionArea(child: ListView.builder(itemCount: lines.length, itemBuilder: (context, index) {
          final line = lines[index];
          final marker = line.kind == 'add' ? '+' : line.kind == 'remove' ? '−' : ' ';
          final background = line.kind == 'add' ? scheme.primaryContainer.withValues(alpha: .45)
            : line.kind == 'remove' ? scheme.errorContainer.withValues(alpha: .45)
            : line.kind == 'hunk' ? scheme.surfaceContainerHighest : null;
          return Material(color: background ?? scheme.surface, child: InkWell(
            onTap: line.commentable ? () => _comment(line) : null,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: Row(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 30, child: Text('${line.oldLine ?? ''}', textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant))),
                SizedBox(width: 30, child: Text('${line.newLine ?? ''}', textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant))),
                SizedBox(width: 20, child: Text(marker, textAlign: TextAlign.center)),
                Expanded(child: Text(line.text, style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5))),
              ],
            )),
          ));
        }))),
      ],
    ));
  }
}
