import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/job_trace.dart';
import '../../core/models.dart';
import '../../shared/external_link.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'records_feed.dart';
import '../../shared/theme.dart';

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
      itemBuilder: (context, value) => SemanticButton(
        label: pipelineCardLabel(value), onTap: () => _open(requiredInt(value, 'id')),
        child: Card(child: InkWell(borderRadius: BorderRadius.circular(16),
        onTap: () => _open(requiredInt(value, 'id')), child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(valueText(value, 'name', 'Pipeline #${valueInt(value, 'id')}'),
              style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis)),
              const Icon(Icons.chevron_right, size: 18)]),
            const SizedBox(height: 10), Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
              children: [StatusBadge(valueText(value, 'status')),
                Text(valueText(value, 'ref'), style: const TextStyle(fontSize: 12)),
                Text(shortSha(valueText(value, 'sha')), style: const TextStyle(fontSize: 12, fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace']))]),
            const SizedBox(height: 10), Text(relativeDate(valueText(value, 'updated_at')), style: Theme.of(context).textTheme.bodySmall),
          ])))),
    )),
      ),
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
  ]), body: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
    if (_error != null) FailureNotice(_error!, onRetry: _load, account: widget.account,
      resourceLabel: '${widget.project.path} · Pipeline #${widget.id}', onSwitchAccount: endSessionFrom(context)),
    if (_data != null) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.project.path, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusBadge(valueText(_data!, 'status')), Text(valueText(_data!, 'ref')),
          Text(shortSha(valueText(_data!, 'sha')), style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'], fontSize: 12)),
          if (_data!['duration'] is num) Text('${(_data!['duration'] as num).round()} 秒', style: const TextStyle(fontSize: 12)),
        ]),
      ])),
    Expanded(child: RecordsFeed(key: _feed, identity: 'pipeline/${widget.id}/jobs', empty: '尚無工作',
      account: widget.account, resourceLabel: '${widget.project.path} · Pipeline #${widget.id} 工作',
      onSwitchAccount: endSessionFrom(context),
      load: (next) => widget.api.records(['projects', '${widget.project.id}', 'pipelines', '${widget.id}', 'jobs'],
        query: {'include_retried': 'false'}, next: next), itemBuilder: (context, value) => SemanticButton(
          label: jobCardLabel(value), onTap: () => _openJob(requiredInt(value, 'id')),
          child: Card(child: ListTile(
          title: Text(valueText(value, 'name')), subtitle: Padding(padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center,
              children: [StatusBadge(valueText(value, 'status')), Text(valueText(value, 'stage'), style: const TextStyle(fontSize: 12))])),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _openJob(requiredInt(value, 'id')),
        ))),
    )),
  ])));
}

/// Resolves `<temporary>/artifacts/<projectId>-<jobId>/`.
///
/// Job artifact bytes are the only disk write outside secure storage.
/// The operating system may purge this cache directory at any time.
Future<Directory> jobArtifactDirectory(int projectId, int jobId) async {
  final root = await getTemporaryDirectory();
  final directory = Directory('${root.path}/artifacts/$projectId-$jobId');
  await directory.create(recursive: true);
  return directory;
}

abstract interface class ArtifactSharer {
  Future<void> share(String path);
}

final class SystemArtifactSharer implements ArtifactSharer {
  const SystemArtifactSharer();
  @override
  Future<void> share(String path) => SharePlus.instance.share(ShareParams(files: [XFile(path)]));
}

String formatByteCount(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final shown = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$shown ${units[unit]}';
}

class JobLogPage extends StatefulWidget {
  const JobLogPage({super.key, required this.account, required this.api, required this.project, required this.id,
    this.sharer = const SystemArtifactSharer(), this.artifactDirectory = jobArtifactDirectory});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int id;
  final ArtifactSharer sharer;
  final Future<Directory> Function(int projectId, int jobId) artifactDirectory;
  @override
  State<JobLogPage> createState() => _JobLogPageState();
}
class _JobLogPageState extends State<JobLogPage> with WidgetsBindingObserver {
  late int _jobId;
  int _loadEpoch = 0;
  Json? _job;
  JobTrace _trace = JobTrace.empty;
  final Map<String, bool> _sectionOpen = {};
  ApiFailure? _error;
  bool _loading = false, _busy = false, _confirming = false, _downloading = false, _auto = false, _follow = true;
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
      final parsed = JobTrace.parse(trace);
      if ('\n'.allMatches(parsed.ansiStripped).take(GitLabApi.maxTextLines).length >= GitLabApi.maxTextLines) {
        throw const ApiFailure(FailureKind.tooLarge);
      }
      setState(() => _trace = parsed);
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
      await _downloadArtifacts();
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
          _jobId = newId; _trace = JobTrace.empty; _query = ''; _follow = true; _sectionOpen.clear();
        }
      });
      await _load();
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() { _busy = false; _confirming = false; }); } }
  }
  String _sectionKey(JobTraceSection section) => '${section.depth}:${section.name}:${section.start}:${section.startLine}';
  bool _collapsed(JobTraceSection section) {
    final opened = _sectionOpen[_sectionKey(section)];
    if (opened != null) return !opened;
    return section.collapsed;
  }
  void _toggleSection(JobTraceSection section) {
    final key = _sectionKey(section);
    setState(() => _sectionOpen[key] = _collapsed(section));
  }
  List<_LogRow> _visibleRows() {
    final rows = <_LogRow>[];
    void addLine(String text) {
      if (_query.isEmpty || text.toLowerCase().contains(_query.toLowerCase())) rows.add(_LogRow.line(text));
    }
    void walk(int from, int to, int depth) {
      var cursor = from;
      final indexes = <int>[];
      for (var i = 0; i < _trace.sections.length; i++) {
        final section = _trace.sections[i];
        if (section.depth == depth && section.startLine >= from && section.startLine < to) indexes.add(i);
      }
      indexes.sort((a, b) => _trace.sections[a].startLine.compareTo(_trace.sections[b].startLine));
      for (final index in indexes) {
        final section = _trace.sections[index];
        if (section.startLine < cursor) continue;
        for (var line = cursor; line < section.startLine; line++) {
          addLine(_trace.lines[line].text);
        }
        rows.add(_LogRow.header(index));
        if (!_collapsed(section)) walk(section.startLine, section.endLine, depth + 1);
        if (section.endLine > cursor) cursor = section.endLine;
      }
      for (var line = cursor; line < to; line++) {
        addLine(_trace.lines[line].text);
      }
    }
    walk(0, _trace.lines.length, 0);
    return rows;
  }
  Widget _sectionHeader(JobTraceSection section) {
    final collapsed = _collapsed(section);
    final duration = section.durationSeconds;
    final title = duration == null ? section.label : '${section.label} · $duration 秒';
    return Padding(padding: EdgeInsets.only(left: section.depth * 12), child: InkWell(
      onTap: () => _toggleSection(section),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
        Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18),
        const SizedBox(width: 4),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
      ])),
    ));
  }
  Future<void> _downloadArtifacts() async {
    final job = _job;
    if (job == null || _downloading) return;
    final info = valueObject(job, 'artifacts_file');
    final suggested = valueText(info, 'filename');
    if (suggested.isEmpty) return;
    final size = info['size'];
    final jobId = _jobId;
    setState(() => _downloading = true);
    try {
      final directory = await widget.artifactDirectory(widget.project.id, jobId);
      if (!mounted) return;
      await showModalBottomSheet<void>(context: context, isScrollControlled: true,
        builder: (context) => _ArtifactDownloadSheet(
          account: widget.account, api: widget.api, projectId: widget.project.id, projectPath: widget.project.path,
          jobId: jobId, directory: directory, suggestedName: suggested,
          suggestedSize: size is int ? size : null, sharer: widget.sharer,
          webUri: widget.account.instance.projectWeb('${widget.project.path}/-/jobs/$jobId/artifacts/browse'),
        ));
    } catch (error) { if (mounted) showFailure(context, error); }
    finally { if (mounted) setState(() => _downloading = false); }
  }
  @override
  Widget build(BuildContext context) {
    final rows = _visibleRows();
    final noLog = _trace.lines.isEmpty && _trace.sections.isEmpty;
    return Scaffold(appBar: AppBar(title: Text(_job == null ? 'Job #$_jobId' : valueText(_job!, 'name')),
      actions: [IconButton(tooltip: '重新讀取 Log', onPressed: _loading || _busy || _confirming ? null : _load, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(tooltip: '工作操作', enabled: !_busy && !_confirming && !_downloading && _job != null, onSelected: _action, itemBuilder: (_) => [
          const PopupMenuItem(value: 'retry', child: Text('重試工作')),
          if (_job?['status'] == 'manual') const PopupMenuItem(value: 'play', child: Text('啟動手動工作')),
          const PopupMenuItem(value: 'cancel', child: Text('取消工作')),
          if (valueObject(_job ?? {}, 'artifacts_file')['filename'] != null)
            const PopupMenuItem(value: 'artifacts', child: Text('下載產物')),
        ]),
      ]), body: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
        Expanded(child: noLog && !_loading && _error == null
          ? SingleChildScrollView(child: EmptyState('尚無 Log',
              detail: _job?['status'] == 'manual' ? '工作尚未啟動，可從右上角操作選單啟動。' : '工作開始執行後，紀錄會顯示在這裡。',
              icon: Icons.terminal))
          : SelectionArea(child: ListView.builder(controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: rows.length, itemBuilder: (context, index) {
                final row = rows[index];
                final section = row.section;
                if (section != null) return _sectionHeader(_trace.sections[section]);
                final text = row.text ?? '';
                return Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(text.isEmpty ? ' ' : text,
                  style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'], fontSize: 12, height: 1.5)));
              },
            ))),
      ])));
  }
}

final class _LogRow {
  const _LogRow.header(this.section) : text = null;
  const _LogRow.line(this.text) : section = null;
  final int? section;
  final String? text;
}

class _ArtifactDownloadSheet extends StatefulWidget {
  const _ArtifactDownloadSheet({
    required this.account, required this.api, required this.projectId, required this.projectPath,
    required this.jobId, required this.directory, required this.suggestedName, required this.suggestedSize,
    required this.sharer, required this.webUri,
  });
  final Account account;
  final GitLabApi api;
  final int projectId;
  final String projectPath;
  final int jobId;
  final Directory directory;
  final String suggestedName;
  final int? suggestedSize;
  final ArtifactSharer sharer;
  final Uri webUri;
  @override
  State<_ArtifactDownloadSheet> createState() => _ArtifactDownloadSheetState();
}

class _ArtifactDownloadSheetState extends State<_ArtifactDownloadSheet> {
  final Completer<void> _abort = Completer<void>();
  IOSink? _sink;
  File? _partial;
  int _received = 0;
  int? _total;
  bool _done = false, _popWhenCancelled = false, _started = false;
  String? _savedName, _savedPath;
  int _savedBytes = 0;
  ApiFailure? _error;
  @override
  void initState() {
    super.initState();
    _total = widget.suggestedSize;
    unawaited(_start());
  }
  @override
  void dispose() {
    if (!_abort.isCompleted) _abort.complete();
    super.dispose();
  }
  Future<void> _start() async {
    if (_started) return;
    _started = true;
    final partial = File('${widget.directory.path}/.partial');
    _partial = partial;
    final sink = partial.openWrite();
    _sink = sink;
    try {
      final result = await widget.api.downloadJobArtifacts(widget.projectId, widget.jobId, sink: sink,
        cancel: _abort.future, onProgress: (received, total) {
          if (!mounted) return;
          setState(() { _received = received; _total = total ?? _total; });
        });
      await sink.flush();
      await sink.close();
      _sink = null;
      final name = _downloadFileName(result.fileName, widget.jobId);
      final target = File('${widget.directory.path}/$name');
      if (target.existsSync()) await target.delete();
      await partial.rename(target.path);
      _partial = null;
      if (!mounted) return;
      setState(() { _done = true; _savedName = name; _savedBytes = result.bytesWritten; _savedPath = target.path; });
    } catch (error) {
      await _deletePartial();
      if (!mounted) return;
      final failure = safeFailure(error);
      if (failure.kind == FailureKind.cancelled) {
        if (_popWhenCancelled) Navigator.pop(context);
        return;
      }
      setState(() => _error = failure);
    }
  }
  Future<void> _deletePartial() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.close();
      } on Object catch (error) {
        if (error is! StateError && error is! FileSystemException) rethrow;
      }
    }
    final partial = _partial;
    _partial = null;
    if (partial != null && partial.existsSync()) await partial.delete();
  }
  void _cancel() {
    _popWhenCancelled = true;
    if (!_abort.isCompleted) _abort.complete();
  }
  Future<void> _share() async {
    final path = _savedPath;
    if (path == null) return;
    try { await widget.sharer.share(path); }
    catch (error) { if (mounted) showFailure(context, error); }
  }
  @override
  Widget build(BuildContext context) {
    final total = _total;
    final double? progress = total == null || total <= 0 ? null : (_received / total).clamp(0.0, 1.0).toDouble();
    final bytes = total == null ? formatByteCount(_received) : '${formatByteCount(_received)} / ${formatByteCount(total)}';
    return SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.suggestedName, style: Theme.of(context).textTheme.titleMedium),
        if (widget.suggestedSize != null) Padding(padding: const EdgeInsets.only(top: 4),
          child: Text(formatByteCount(widget.suggestedSize!), style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 16),
        if (_error != null) FailureNotice(_error!, account: widget.account,
          resourceLabel: '${widget.projectPath} · Job #${widget.jobId} 產物', onSwitchAccount: endSessionFrom(context)),
        if (_done) ...[
          Text('已下載 ${_savedName ?? widget.suggestedName} · ${formatByteCount(_savedBytes)}'),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => unawaited(_share()), child: const Text('開啟／分享')),
          TextButton(onPressed: () => unawaited(openExternal(context, widget.webUri)), child: const Text('在 GitLab 開啟')),
        ],
        if (_error == null && !_done) ...[
          LinearProgressIndicator(key: const Key('artifact-progress'), minHeight: 4, value: progress),
          const SizedBox(height: 8),
          Text(bytes, style: Theme.of(context).textTheme.bodySmall),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: _cancel, child: const Text('取消'))),
        ],
      ],
    )));
  }
}

String _downloadFileName(String name, int job) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  if (base.isEmpty || base == '.' || base == '..' || base.contains('\u0000')) return 'artifacts-$job.zip';
  return base;
}
