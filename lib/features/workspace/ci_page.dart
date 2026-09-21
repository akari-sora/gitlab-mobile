import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/external_link.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'records_feed.dart';

class PipelinesTab extends StatefulWidget {
  const PipelinesTab({super.key, required this.account, required this.api, required this.project});
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  State<PipelinesTab> createState() => _PipelinesTabState();
}
class _PipelinesTabState extends State<PipelinesTab> {
  final _feed = GlobalKey<RecordsFeedState>();
  String _state = '', _ref = '';
  Future<void> _open(int id) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PipelinePage(
      account: widget.account, api: widget.api, project: widget.project, id: id)));
    if (mounted) { await _feed.currentState?.refresh(); }
  }
  Future<void> _run() async {
    var id = 0;
    final saved = await openEditor(context, account: widget.account, title: '執行 Pipeline',
      resource: '${widget.project.id}/pipeline/new', subtitle: widget.project.path,
      fields: [EditField('ref', '分支或標籤', required: true, value: widget.project.defaultBranch ?? 'main',
        hint: '將使用此 ref 上的 .gitlab-ci.yml；可能執行部署工作。')],
      save: (values) async {
        id = requiredInt(await widget.api.createPipeline(widget.project.id, values['ref']!.trim()), 'id');
      });
    if (saved && mounted) { await _open(id); }
  }
  @override
  Widget build(BuildContext context) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(16, 12, 12, 8), child: Row(children: [
      Expanded(child: TextField(decoration: const InputDecoration(hintText: '依分支篩選', prefixIcon: Icon(Icons.alt_route)),
        textInputAction: TextInputAction.search, onSubmitted: (value) => setState(() => _ref = value.trim()))),
      const SizedBox(width: 8), IconButton(tooltip: '執行 Pipeline', onPressed: widget.project.archived == true ? null : _run,
        icon: const Icon(Icons.play_circle_outline)),
    ])),
    SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [for (final e in const {'': '全部', 'running': '執行中', 'failed': '失敗', 'success': '成功'}.entries)
        Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(e.value),
          selected: _state == e.key, showCheckmark: false, onSelected: (_) => setState(() => _state = e.key)))])),
    Expanded(child: RecordsFeed(key: _feed, identity: 'pipelines/$_state/$_ref', empty: '沒有符合的 Pipeline',
      account: widget.account, resourceLabel: '${widget.project.path} · Pipeline',
      onSwitchAccount: endSessionFrom(context),
      load: (next) => widget.api.records(['projects', '${widget.project.id}', 'pipelines'],
        query: {'order_by': 'id', 'sort': 'desc', if (_state.isNotEmpty) 'status': _state, if (_ref.isNotEmpty) 'ref': _ref}, next: next),
      itemBuilder: (context, value) => Card(child: InkWell(borderRadius: BorderRadius.circular(16),
        onTap: () => _open(requiredInt(value, 'id')), child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(valueText(value, 'name', 'Pipeline #${valueInt(value, 'id')}'),
              style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis)),
              const Icon(Icons.chevron_right, size: 18)]),
            const SizedBox(height: 10), Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
              children: [StatusBadge(valueText(value, 'status')),
                Text(valueText(value, 'ref'), style: const TextStyle(fontSize: 12)),
                Text(shortSha(valueText(value, 'sha')), style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))]),
            const SizedBox(height: 10), Text(relativeDate(valueText(value, 'updated_at')), style: Theme.of(context).textTheme.bodySmall),
          ])))),
    )),
  ]);
}

class PipelinePage extends StatefulWidget {
  const PipelinePage({super.key, required this.account, required this.api, required this.project, required this.id});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int id;
  @override
  State<PipelinePage> createState() => _PipelinePageState();
}
class _PipelinePageState extends State<PipelinePage> {
  final _feed = GlobalKey<RecordsFeedState>();
  Json? _data;
  ApiFailure? _error;
  bool _busy = false, _loading = false;
  @override
  void initState() { super.initState(); unawaited(_load()); }
  Future<void> _load() async {
    if (_loading || !mounted) { return; }
    setState(() { _loading = true; _error = null; });
    try {
      final data = await widget.api.record(['projects', '${widget.project.id}', 'pipelines', '${widget.id}']);
      if (mounted) { setState(() => _data = data); }
    } catch (e) { if (mounted) { setState(() => _error = safeFailure(e)); } }
    finally { if (mounted) { setState(() => _loading = false); } }
  }
  Future<void> _openJob(int id) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => JobLogPage(
      account: widget.account, api: widget.api, project: widget.project, id: id)));
    // The job route stays open across retries and completes only on real back.
    if (!mounted) { return; }
    await _load();
    if (mounted) { await _feed.currentState?.refresh(); }
  }
  Future<void> _action(String action) async {
    if (_busy) { return; }
    final label = action == 'retry' ? '重試失敗工作' : action == 'cancel' ? '取消流程' : '刪除 Pipeline';
    if (!await confirmAction(context, '$label？', '${widget.project.path}\nPipeline #${widget.id}',
      requiredText: action == 'delete' ? '${widget.id}' : null)) { return; }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      if (action == 'delete') {
        await widget.api.deletePipeline(widget.project.id, widget.id);
        if (mounted) { Navigator.pop(context); }
        return;
      }
      await widget.api.pipelineAction(widget.project.id, widget.id, action);
      await _load();
      if (mounted) { await _feed.currentState?.refresh(); }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text('Pipeline #${widget.id}'), actions: [
    IconButton(tooltip: '重新整理', onPressed: _loading || _busy ? null : () async {
      await _load(); if (mounted) { await _feed.currentState?.refresh(); }
    }, icon: const Icon(Icons.refresh)),
    PopupMenuButton<String>(enabled: !_busy, tooltip: 'Pipeline 操作', onSelected: _action, itemBuilder: (_) => const [
      PopupMenuItem(value: 'retry', child: Text('重試失敗工作')),
      PopupMenuItem(value: 'cancel', child: Text('取消流程')),
      PopupMenuItem(value: 'delete', child: Text('刪除 Pipeline')),
    ]),
  ]), body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
    if (_error != null) FailureNotice(_error!, onRetry: _load, account: widget.account,
      resourceLabel: '${widget.project.path} · Pipeline #${widget.id}', onSwitchAccount: endSessionFrom(context)),
    if (_data != null) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.project.path, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusBadge(valueText(_data!, 'status')), Text(valueText(_data!, 'ref')),
          Text(shortSha(valueText(_data!, 'sha')), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          if (_data!['duration'] is num) Text('${(_data!['duration'] as num).round()} 秒', style: const TextStyle(fontSize: 12)),
        ]),
      ])),
    Expanded(child: RecordsFeed(key: _feed, identity: 'pipeline/${widget.id}/jobs', empty: '尚無工作',
      account: widget.account, resourceLabel: '${widget.project.path} · Pipeline #${widget.id} 工作',
      onSwitchAccount: endSessionFrom(context),
      load: (next) => widget.api.records(['projects', '${widget.project.id}', 'pipelines', '${widget.id}', 'jobs'],
        query: {'include_retried': 'false'}, next: next), itemBuilder: (context, value) => Card(child: ListTile(
          title: Text(valueText(value, 'name')), subtitle: Padding(padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center,
              children: [StatusBadge(valueText(value, 'status')), Text(valueText(value, 'stage'), style: const TextStyle(fontSize: 12))])),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _openJob(requiredInt(value, 'id')),
        )),
    )),
  ]));
}

class JobLogPage extends StatefulWidget {
  const JobLogPage({super.key, required this.account, required this.api, required this.project, required this.id});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int id;
  @override
  State<JobLogPage> createState() => _JobLogPageState();
}
class _JobLogPageState extends State<JobLogPage> with WidgetsBindingObserver {
  late int _jobId;
  int _loadEpoch = 0;
  Json? _job;
  List<String> _lines = [];
  ApiFailure? _error;
  bool _loading = false, _busy = false, _confirming = false, _auto = false, _follow = true;
  String _query = '';
  Timer? _timer;
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState(); _jobId = widget.id;
    WidgetsBinding.instance.addObserver(this); unawaited(_load());
  }
  @override
  void dispose() {
    _loadEpoch++; _timer?.cancel(); _scroll.dispose();
    WidgetsBinding.instance.removeObserver(this); super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) { _timer?.cancel(); }
    else { _schedule(); }
  }
  void _schedule() {
    _timer?.cancel();
    if (!_auto || !mounted) { return; }
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed && !_loading && !_busy && !_confirming) {
        unawaited(_load());
      }
    });
  }
  Future<void> _load() async {
    if (_loading || !mounted) { return; }
    final epoch = ++_loadEpoch, jobId = _jobId;
    bool current() => mounted && epoch == _loadEpoch && jobId == _jobId;
    final follow = _follow && (!_scroll.hasClients || _scroll.position.extentAfter < 80);
    setState(() { _loading = true; _error = null; });
    try {
      final job = await widget.api.record(['projects', '${widget.project.id}', 'jobs', '$jobId']);
      if (!current()) { return; }
      // Metadata and trace have independent failure modes. Keep the controls
      // usable even when an expired or oversized trace cannot be displayed.
      setState(() {
        _job = job;
        if (!const ['running', 'pending', 'created', 'preparing', 'waiting_for_resource'].contains(job['status'])) {
          _auto = false; _timer?.cancel();
        }
      });
      final trace = await widget.api.jobTrace(widget.project.id, jobId);
      if (!current()) { return; }
      final plain = trace.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
      if ('\n'.allMatches(plain).take(GitLabApi.maxTextLines).length >= GitLabApi.maxTextLines) {
        throw const ApiFailure(FailureKind.tooLarge);
      }
      setState(() => _lines = plain.isEmpty ? [] : plain.split('\n'));
      if (follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (current() && _scroll.hasClients) { _scroll.jumpTo(_scroll.position.maxScrollExtent); }
        });
      }
    } catch (e) {
      if (current()) { setState(() { _error = safeFailure(e); _auto = false; _timer?.cancel(); }); }
    } finally { if (current()) { setState(() => _loading = false); } }
  }
  Future<void> _action(String action) async {
    if (_busy || _confirming || _job == null) { return; }
    if (action == 'artifacts') {
      await openExternal(context, widget.account.instance.projectWeb('${widget.project.path}/-/jobs/$_jobId/artifacts/browse'));
      return;
    }
    final jobId = _jobId;
    final label = action == 'retry' ? '重試工作' : action == 'play' ? '啟動手動工作' : '取消工作';
    // Confirmation prevents duplicate dialogs but is not a running operation.
    setState(() => _confirming = true);
    try {
      if (!await confirmAction(context, '$label？', '${widget.project.path}\nJob #$jobId')) { return; }
      if (!mounted || jobId != _jobId) { return; }
      setState(() { _confirming = false; _busy = true; });
      final result = await widget.api.jobAction(widget.project.id, jobId, action);
      final newId = requiredInt(result, 'id');
      if (!mounted || jobId != _jobId) { return; }
      if (action != 'retry' && newId != jobId) { throw const ApiFailure(FailureKind.invalidResponse); }
      // Keep one route across job attempts, so the parent's navigation await
      // completes on real back. Discard stale trace results from older epochs.
      setState(() {
        _loadEpoch++; _loading = false; _error = null;
        _auto = false; _timer?.cancel(); _job = result;
        if (newId != _jobId) {
          _jobId = newId; _lines = []; _query = ''; _follow = true;
        }
      });
      await _load();
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() { _busy = false; _confirming = false; }); } }
  }
  @override
  Widget build(BuildContext context) {
    final matches = <int>[for (var i = 0; i < _lines.length; i++)
      if (_query.isEmpty || _lines[i].toLowerCase().contains(_query.toLowerCase())) i];
    return Scaffold(appBar: AppBar(title: Text(_job == null ? 'Job #$_jobId' : valueText(_job!, 'name')),
      actions: [IconButton(tooltip: '重新讀取 Log', onPressed: _loading || _busy || _confirming ? null : _load, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(tooltip: '工作操作', enabled: !_busy && !_confirming && _job != null, onSelected: _action, itemBuilder: (_) => [
          const PopupMenuItem(value: 'retry', child: Text('重試工作')),
          if (_job?['status'] == 'manual') const PopupMenuItem(value: 'play', child: Text('啟動手動工作')),
          const PopupMenuItem(value: 'cancel', child: Text('取消工作')),
          if (valueObject(_job ?? {}, 'artifacts_file')['filename'] != null)
            const PopupMenuItem(value: 'artifacts', child: Text('在 GitLab 下載產物')),
        ]),
      ]), body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Wrap(
          spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (_job != null) StatusBadge(valueText(_job!, 'status')),
            Text('#$_jobId', style: Theme.of(context).textTheme.bodySmall),
            FilterChip(label: const Text('10 秒更新'), selected: _auto, onSelected: (value) {
              setState(() => _auto = value); _schedule();
            }),
            FilterChip(label: const Text('跟隨尾端'), selected: _follow, onSelected: (value) => setState(() => _follow = value)),
          ])),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(
          key: ValueKey('job-log-search-$_jobId'),
          decoration: const InputDecoration(hintText: '搜尋已載入的 Log', prefixIcon: Icon(Icons.search)),
          onChanged: (value) => setState(() => _query = value))),
        if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
        if (_error != null) FailureNotice(_error!, onRetry: _busy || _confirming ? null : _load,
          account: widget.account, resourceLabel: '${widget.project.path} · Job #$_jobId',
          onSwitchAccount: endSessionFrom(context)),
        Expanded(child: _lines.isEmpty && !_loading && _error == null
          ? SingleChildScrollView(child: EmptyState('尚無 Log',
              detail: _job?['status'] == 'manual' ? '工作尚未啟動，可從右上角操作選單啟動。' : '工作開始執行後，紀錄會顯示在這裡。',
              icon: Icons.terminal))
          : SelectionArea(child: ListView.builder(controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: matches.length, itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 3), child: Text(_lines[matches[index]].isEmpty ? ' ' : _lines[matches[index]],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5))),
            ))),
      ]));
  }
}
