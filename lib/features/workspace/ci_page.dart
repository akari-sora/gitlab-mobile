import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
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
  final _testsKey = GlobalKey<PipelineTestsViewState>();
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
    if (mounted) {
      await _feed.currentState?.refresh();
      await _testsKey.currentState?.refresh();
    }
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
      if (mounted) {
        await _feed.currentState?.refresh();
        await _testsKey.currentState?.refresh();
      }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(title: Text('Pipeline #${widget.id}'), actions: [
        IconButton(tooltip: '重新整理', onPressed: _loading || _busy ? null : () async {
          await _load();
          if (mounted) {
            await _feed.currentState?.refresh();
            await _testsKey.currentState?.refresh();
          }
        }, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(enabled: !_busy, tooltip: 'Pipeline 操作', onSelected: _action, itemBuilder: (_) => const [
          PopupMenuItem(value: 'retry', child: Text('重試失敗工作')),
          PopupMenuItem(value: 'cancel', child: Text('取消流程')),
          PopupMenuItem(value: 'delete', child: Text('刪除 Pipeline')),
        ]),
      ]),
      body: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
        if (_error != null) FailureNotice(_error!, onRetry: _load, account: widget.account,
          resourceLabel: '${widget.project.path} · Pipeline #${widget.id}', onSwitchAccount: endSessionFrom(context)),
        if (_data != null) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.project.path, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              StatusBadge(valueText(_data!, 'status')), Text(valueText(_data!, 'ref')),
              Text(shortSha(valueText(_data!, 'sha')), style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'], fontSize: 12)),
              if (_data!['duration'] is num) Text('${(_data!['duration'] as num).round()} 秒', style: const TextStyle(fontSize: 12)),
            ]),
          ])),
        if (_data != null)
          const TabBar(
            tabs: [
              Tab(text: '工作'),
              Tab(text: '測試'),
            ],
          ),
        if (_data != null)
          Expanded(
            child: TabBarView(
              children: [
                RecordsFeed(
                  key: _feed,
                  identity: 'pipeline/${widget.id}/jobs',
                  empty: '尚無工作',
                  account: widget.account,
                  resourceLabel: '${widget.project.path} · Pipeline #${widget.id} 工作',
                  onSwitchAccount: endSessionFrom(context),
                  load: (next) => widget.api.records(
                    ['projects', '${widget.project.id}', 'pipelines', '${widget.id}', 'jobs'],
                    query: {'include_retried': 'false'},
                    next: next,
                  ),
                  itemBuilder: (context, value) => SemanticButton(
                    label: jobCardLabel(value),
                    onTap: () => _openJob(requiredInt(value, 'id')),
                    child: Card(
                      child: ListTile(
                        title: Text(valueText(value, 'name')),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              StatusBadge(valueText(value, 'status')),
                              Text(valueText(value, 'stage'), style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: () => _openJob(requiredInt(value, 'id')),
                      ),
                    ),
                  ),
                ),
                PipelineTestsView(
                  key: _testsKey,
                  account: widget.account,
                  api: widget.api,
                  project: widget.project,
                  pipelineId: widget.id,
                  pipelineStatus: valueText(_data!, 'status'),
                  onOpenJob: _openJob,
                ),
              ],
            ),
          ),
      ])),
    ),
  );
}

class PipelineTestsView extends StatefulWidget {
  const PipelineTestsView({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.pipelineId,
    required this.pipelineStatus,
    required this.onOpenJob,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final int pipelineId;
  final String pipelineStatus;
  final Future<void> Function(int jobId) onOpenJob;

  @override
  State<PipelineTestsView> createState() => PipelineTestsViewState();
}

class PipelineTestsViewState extends State<PipelineTestsView> {
  static const int maxCasesBudget = 500;
  static const int maxOutputChars = 5000;

  int _generation = 0;
  int _casesGeneration = 0;
  bool _loadingSummary = false;
  bool _loadingCases = false;
  bool _loadingMore = false;
  TestReportSummary? _summary;
  ApiFailure? _summaryError;
  ApiFailure? _casesError;
  List<TestCase> _cases = [];
  Uri? _nextPage;
  String _filter = 'all';
  final Set<String> _expandedCases = {};

  bool get _isInProgress => const [
    'running',
    'pending',
    'preparing',
    'waiting_for_resource',
    'scheduled',
    'created',
  ].contains(widget.pipelineStatus.toLowerCase());

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  @override
  void didUpdateWidget(covariant PipelineTestsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pipelineId != widget.pipelineId ||
        oldWidget.pipelineStatus != widget.pipelineStatus) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _generation++;
    _casesGeneration++;
    super.dispose();
  }

  Future<void> refresh() async {
    final gen = ++_generation;
    setState(() {
      _loadingSummary = true;
      _summaryError = null;
      _casesError = null;
      _cases = [];
      _nextPage = null;
    });

    try {
      final summary = await widget.api.pipelineTestReportSummary(
        widget.project.id,
        widget.pipelineId,
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        _summary = summary;
        _loadingSummary = false;
        if (summary.failedCount > 0 || summary.errorCount > 0 || summary.hasSuiteError) {
          _filter = 'failed';
        } else {
          _filter = 'all';
        }
      });
      if (summary.totalCount > 0) {
        unawaited(_loadCases(gen));
      }
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _summaryError = safeFailure(e);
        _loadingSummary = false;
      });
    }
  }

  Future<void> _loadCases(int summaryGen) async {
    final caseGen = ++_casesGeneration;
    setState(() {
      _loadingCases = true;
      _casesError = null;
    });

    try {
      final page = await widget.api.pipelineTestReport(
        widget.project.id,
        widget.pipelineId,
        perPage: 30,
      );
      if (!mounted || summaryGen != _generation || caseGen != _casesGeneration) return;
      final seen = <String>{};
      final uniqueCases = <TestCase>[];
      for (final c in page.testCases) {
        if (seen.add(c.identity)) uniqueCases.add(c);
      }
      setState(() {
        _cases = uniqueCases;
        _nextPage = page.next;
        _loadingCases = false;
      });
    } catch (e) {
      if (!mounted || summaryGen != _generation || caseGen != _casesGeneration) return;
      setState(() {
        _casesError = safeFailure(e);
        _loadingCases = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final next = _nextPage;
    if (next == null || _loadingMore || _loadingCases) return;
    if (_cases.length >= maxCasesBudget) return;
    final gen = _generation;
    final caseGen = _casesGeneration;
    setState(() {
      _loadingMore = true;
      _casesError = null;
    });

    try {
      final page = await widget.api.pipelineTestReport(
        widget.project.id,
        widget.pipelineId,
        next: next,
      );
      if (!mounted || gen != _generation || caseGen != _casesGeneration) return;
      final seen = _cases.map((c) => c.identity).toSet();
      final newCases = <TestCase>[];
      for (final c in page.testCases) {
        if (seen.add(c.identity)) newCases.add(c);
      }
      setState(() {
        _cases = [..._cases, ...newCases];
        _nextPage = page.next;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation || caseGen != _casesGeneration) return;
      setState(() {
        _casesError = safeFailure(e);
        _loadingMore = false;
      });
    }
  }

  String _filterLabel(String filter) => switch (filter) {
    'all' => '全部',
    'failed' => '失敗',
    'error' => '錯誤',
    'skipped' => '跳過',
    'success' => '成功',
    _ => filter,
  };

  String _truncateOutput(String text) {
    if (text.length <= maxOutputChars) return text;
    return '${text.substring(0, maxOutputChars)}\n\n… [輸出過長，已截斷顯示]';
  }

  Widget _buildSummaryCard(BuildContext context, TestReportSummary summary) {
    final theme = Theme.of(context);
    final workshop = WorkshopColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusBadge(switch (summary.status) {
                  TestReportStatus.failed => 'failed',
                  TestReportStatus.error => 'error',
                  TestReportStatus.suiteError => 'error',
                  TestReportStatus.skipped => 'skipped',
                  TestReportStatus.success => 'success',
                  _ => 'status_unknown',
                }),
                Text('總計 ${summary.totalCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('成功 ${summary.successCount}', style: TextStyle(color: workshop.onSuccessContainer)),
                if (summary.failedCount > 0)
                  Text('失敗 ${summary.failedCount}', style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold)),
                if (summary.errorCount > 0)
                  Text('錯誤 ${summary.errorCount}', style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold)),
                if (summary.skippedCount > 0)
                  Text('跳過 ${summary.skippedCount}', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                Text('耗時 ${summary.totalTime.toStringAsFixed(2)} 秒', style: theme.textTheme.bodySmall),
              ],
            ),
            if (summary.hasSuiteError) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '測試套件解析錯誤: ${summary.suiteError ?? summary.testSuites.firstWhere((s) => s.hasSuiteError, orElse: () => const TestSuiteSummary(name: '', totalTime: 0, totalCount: 0, successCount: 0, failedCount: 0, skippedCount: 0, errorCount: 0, suiteError: '未知套件錯誤')).suiteError}',
                        style: TextStyle(color: theme.colorScheme.onErrorContainer, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChips(BuildContext context, TestReportSummary summary) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text('全部 (${summary.totalCount})'),
              selected: _filter == 'all',
              showCheckmark: false,
              onSelected: (_) => setState(() => _filter = 'all'),
            ),
          ),
          if (summary.failedCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('失敗 (${summary.failedCount})'),
                selected: _filter == 'failed',
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = 'failed'),
              ),
            ),
          if (summary.errorCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('錯誤 (${summary.errorCount})'),
                selected: _filter == 'error',
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = 'error'),
              ),
            ),
          if (summary.skippedCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('跳過 (${summary.skippedCount})'),
                selected: _filter == 'skipped',
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = 'skipped'),
              ),
            ),
          if (summary.successCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('成功 (${summary.successCount})'),
                selected: _filter == 'success',
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = 'success'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTestCaseCard(BuildContext context, TestCase item) {
    final theme = Theme.of(context);
    final isExpanded = _expandedCases.contains(item.identity);
    final hasTraceOrOutput = (item.stackTrace != null && item.stackTrace!.isNotEmpty) ||
        (item.systemOutput != null && item.systemOutput!.isNotEmpty);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusBadge(item.status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.name,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (item.classname != null && item.classname!.isNotEmpty)
                  Text(
                    item.classname!,
                    style: const TextStyle(
                      fontFamily: codeFontFamily,
                      fontFamilyFallback: ['Menlo', 'monospace'],
                      fontSize: 12,
                    ),
                  ),
                if (item.suiteName != null && item.suiteName!.isNotEmpty)
                  Text('套件: ${item.suiteName}', style: theme.textTheme.bodySmall),
                if (item.file != null && item.file!.isNotEmpty)
                  Text(item.file!, style: theme.textTheme.bodySmall),
                if (item.executionTime != null)
                  Text('${item.executionTime!.toStringAsFixed(3)} 秒', style: theme.textTheme.bodySmall),
              ],
            ),
            if (item.jobId != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.terminal, size: 16),
                  label: Text('工作 #${item.jobId}'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () => widget.onOpenJob(item.jobId!),
                ),
              ),
            ],
            if (hasTraceOrOutput) ...[
              const SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedCases.remove(item.identity);
                    } else {
                      _expandedCases.add(item.identity);
                    }
                  });
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
                      const SizedBox(width: 6),
                      Text(
                        '錯誤追蹤與輸出',
                        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              if (isExpanded) ...[
                if (item.stackTrace != null && item.stackTrace!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('錯誤堆疊 (Stacktrace):', style: theme.textTheme.labelSmall),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      _truncateOutput(item.stackTrace!),
                      style: const TextStyle(
                        fontFamily: codeFontFamily,
                        fontFamilyFallback: ['Menlo', 'monospace'],
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
                if (item.systemOutput != null && item.systemOutput!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('系統輸出 (System Output):', style: theme.textTheme.labelSmall),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      _truncateOutput(item.systemOutput!),
                      style: const TextStyle(
                        fontFamily: codeFontFamily,
                        fontFamilyFallback: ['Menlo', 'monospace'],
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingSummary && _summary == null) {
      return const ListSkeleton();
    }

    if (_summaryError != null) {
      if (_summaryError!.status == 404 || _summaryError!.kind == FailureKind.invisible) {
        if (_isInProgress) {
          return const EmptyState('測試進行中', detail: 'Pipeline 正在執行，尚未產生完整測試報告。', icon: Icons.schedule);
        }
        return const EmptyState('無測試報告', detail: '此 Pipeline 尚未上傳 JUnit 測試報告，或報告已過期／無權限存取。', icon: Icons.rule_folder_outlined);
      }
      return FailureNotice(
        _summaryError!,
        account: widget.account,
        resourceLabel: '${widget.project.path} · Pipeline #${widget.pipelineId} 測試報告',
        onSwitchAccount: endSessionFrom(context),
        onRetry: refresh,
      );
    }

    final summary = _summary;
    if (summary == null || summary.isEmpty) {
      if (_isInProgress) {
        return const EmptyState('測試進行中', detail: 'Pipeline 正在執行，尚未產生完整測試報告。', icon: Icons.schedule);
      }
      return const EmptyState('無測試報告', detail: '此 Pipeline 沒有回報任何測試案例。', icon: Icons.rule_folder_outlined);
    }

    final filteredCases = _cases.where((c) => switch (_filter) {
      'failed' => c.isFailed,
      'error' => c.status == 'error',
      'skipped' => c.isSkipped,
      'success' => c.isSuccess,
      _ => true,
    }).toList();

    final isPartial = summary.totalCount > _cases.length || _nextPage != null;
    final gutter = feedGutter(context);

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          _buildSummaryCard(context, summary),
          const SizedBox(height: 12),
          _buildFilterChips(context, summary),
          const SizedBox(height: 12),
          if (isPartial)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '已載入 ${_cases.length} / ${summary.totalCount} 筆測試案例（部分載入）',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_loadingCases && _cases.isEmpty)
            const ListSkeleton()
          else if (filteredCases.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: EmptyState('沒有符合「${_filterLabel(_filter)}」的已載入測試案例'),
            )
          else
            for (final c in filteredCases)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _buildTestCaseCard(context, c),
              ),
          if (_casesError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FailureNotice(
                _casesError!,
                account: widget.account,
                resourceLabel: '${widget.project.path} · 測試案例分頁',
                onSwitchAccount: endSessionFrom(context),
                onRetry: _loadMore,
              ),
            ),
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_nextPage != null)
            if (_cases.length >= maxCasesBudget)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '已達單次預覽上限（$maxCasesBudget 筆）。如需檢視完整測試報告，請至 GitLab 網頁端或各工作 Log 檢視。',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextButton.icon(
                  icon: const Icon(Icons.expand_more),
                  label: const Text('載入更多測試案例'),
                  onPressed: _loadMore,
                ),
              ),
        ],
      ),
    );
  }
}

/// Override in tests. Production uses the app temporary directory, which the
/// OS may purge. Widget tests have no path_provider channel, so they use the
/// process temp directory instead of waiting on that call.
Future<Directory> Function() artifactStorageRoot = _defaultArtifactRoot;

Future<Directory> _defaultArtifactRoot() {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return Future<Directory>.value(Directory.systemTemp);
  }
  return getTemporaryDirectory();
}

/// Path segment for [account]. A fixed-length digest so a long installation
/// path cannot exceed the 255-byte directory-component limit.
String artifactAccountSegment(Account account) =>
    sha256.convert(utf8.encode(account.key)).toString().substring(0, 32);

int _artifactAttempt = 0;

/// `<temporary>/artifacts/<account>/<project>-<job>/<attempt>/`.
///
/// Each call is one attempt. Cleanup of that directory cannot truncate another
/// attempt, account, or instance that happens to reuse the same numeric ids.
/// The operating system may purge this cache directory at any time.
Future<Directory> jobArtifactDirectory(Account account, int projectId, int jobId) async {
  final root = await artifactStorageRoot();
  final attempt = ++_artifactAttempt;
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final directory = Directory(
    '${root.path}/artifacts/${artifactAccountSegment(account)}/$projectId-$jobId/$stamp-$attempt',
  );
  await directory.create(recursive: true);
  return directory;
}

/// Deletes archives left behind for [account], including completed downloads.
/// Filesystem checks stay synchronous so account removal is not left waiting
/// on a plugin or an I/O future the widget test clock will not complete.
/// Lookup and deletion failures of that account directory propagate so the
/// account is not removed while its archives remain. The `share_plus` cache
/// is removed best-effort and cannot abort removal.
Future<void> clearAccountArtifacts(Account account) async {
  final Directory root;
  try {
    root = await artifactStorageRoot();
  } on Object {
    throw ApiFailure.artifactCleanup;
  }
  final directory = Directory('${root.path}/artifacts/${artifactAccountSegment(account)}');
  if (directory.existsSync()) {
    try {
      removeArtifactDirectory(directory);
    } on FileSystemException {
      throw ApiFailure.artifactCleanup;
    }
  }
  // share_plus is not account-scoped. A failure here must not keep the account.
  _deleteSharePlusDirectory(root);
}

/// share_plus copies the archive into `<cache>/share_plus/` and does not
/// delete it. Dismissed, unavailable, and failed shares delete that copy
/// immediately. A successful share leaves it until the app resumes after
/// leaving the foreground, so the receiving app can finish reading it.
/// Lookup can throw [MissingPlatformDirectoryException], which is not a
/// [FileSystemException], so every error here is ignored.
/// [serial] is the share that owns the folder when the caller decided to
/// delete it. The cache-root lookup awaits, and a newer share may start (and
/// plant its own copy) meanwhile, so ownership is re-checked after the await.
/// A null serial deletes unconditionally.
Future<void> _discardSharePlusCopies([int? serial]) async {
  try {
    final root = await artifactStorageRoot();
    if (serial != null && serial != _shareSerial) return;
    _deleteSharePlusDirectory(root);
  } on Object {
    return;
  }
}

void _deleteSharePlusDirectory(Directory root) {
  try {
    removeArtifactDirectory(Directory('${root.path}/share_plus'));
  } on Object {
    return;
  }
}

/// Deletes one account's artifact directory. Tests replace it to inject a
/// failure: a read-only directory does not stop deletion for root (the CI
/// runner), so permissions cannot simulate that path portably.
@visibleForTesting
void Function(Directory directory) removeArtifactDirectory =
    (directory) => directory.deleteSync(recursive: true);

Future<File> promoteArtifactFile(File partial, File target) async {
  if (target.existsSync()) await target.delete();
  return partial.rename(target.path);
}

const _artifactPartialName = '.download.partial';

IOSink openArtifactSink(File file) => file.openWrite();

/// Throttles archive progress to one notification per 100 ms, plus completion.
final class ArtifactProgress {
  ArtifactProgress({DateTime Function()? clock, (int, int?) initial = (0, null)})
      : _clock = clock ?? DateTime.now,
        value = ValueNotifier<(int, int?)>(initial);
  final DateTime Function() _clock;
  final ValueNotifier<(int, int?)> value;
  DateTime? _last;

  void report(int received, int? total, {bool completed = false}) {
    final now = _clock();
    final last = _last;
    if (!completed && last != null && now.difference(last) < const Duration(milliseconds: 100)) {
      return;
    }
    _last = now;
    final current = value.value;
    value.value = (received, total ?? current.$2);
  }

  void dispose() => value.dispose();
}

enum ShareOutcome { success, dismissed, unavailable }

int _shareSerial = 0;
// Created lazily in the caller's zone: a future made in another zone (a test
// tearDown) would schedule its continuations there and never run here.
Future<void>? _shareCleanup;
_ShareCopyWatch? _shareCopyWatch;

/// Hands [path] to [sharer] and then decides what happens to the plugin copy
/// in `<cache>/share_plus`. Only the newest share owns that folder: an older
/// share that completes later must not delete a copy planted by a newer one
/// (the plugin replaces the folder when a share starts). A dismissed,
/// unavailable or failed share deletes the copy at once. A successful share
/// keeps it until the app resumes after leaving the foreground, so the
/// receiving app can finish reading the `content://` stream; a later share
/// supersedes that hold.
@visibleForTesting
Future<void> shareDownloadedArtifact(ArtifactSharer sharer, String path) async {
  final serial = ++_shareSerial;
  _disarmShareCopyWatch();
  ShareOutcome? outcome;
  try {
    outcome = await sharer.share(path);
  } catch (error, stack) {
    await _cleanupAfterShare(serial, null);
    Error.throwWithStackTrace(error, stack);
  }
  await _cleanupAfterShare(serial, outcome);
}

/// Cleanup steps run one at a time, in completion order.
Future<void> _cleanupAfterShare(int serial, ShareOutcome? outcome) {
  final previous = _shareCleanup ?? Future<void>.value();
  final step = previous.then((_) async {
    if (serial != _shareSerial) return;
    if (outcome == ShareOutcome.success) {
      _armShareCopyWatch(serial);
      return;
    }
    await _discardSharePlusCopies(serial);
  });
  _shareCleanup = step.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  return step;
}

/// At most one watcher is registered; it is not owned by any sheet, so a
/// sheet that closes before the app comes back does not cancel the cleanup.
void _armShareCopyWatch(int serial) {
  final existing = _shareCopyWatch;
  if (existing != null) {
    existing.serial = serial;
    return;
  }
  final watch = _ShareCopyWatch(serial);
  final state = WidgetsBinding.instance.lifecycleState;
  watch.departed = _leftForeground(state);
  _shareCopyWatch = watch;
  WidgetsBinding.instance.addObserver(watch);
}

void _disarmShareCopyWatch() {
  final watch = _shareCopyWatch;
  if (watch == null) return;
  WidgetsBinding.instance.removeObserver(watch);
  _shareCopyWatch = null;
}

bool _leftForeground(AppLifecycleState? state) =>
    state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.hidden;

@visibleForTesting
void resetArtifactShareCleanup() {
  _disarmShareCopyWatch();
  _shareSerial = 0;
  _shareCleanup = null;
}

final class _ShareCopyWatch extends WidgetsBindingObserver {
  _ShareCopyWatch(this.serial);
  int serial;
  var departed = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_leftForeground(state)) {
      departed = true;
      return;
    }
    if (state != AppLifecycleState.resumed || !departed) return;
    _disarmShareCopyWatch();
    unawaited(_discardSharePlusCopies(serial));
  }
}

abstract interface class ArtifactSharer {
  Future<ShareOutcome> share(String path);
}

final class SystemArtifactSharer implements ArtifactSharer {
  const SystemArtifactSharer();
  @override
  Future<ShareOutcome> share(String path) async {
    final result = await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    return switch (result.status) {
      ShareResultStatus.success => ShareOutcome.success,
      ShareResultStatus.dismissed => ShareOutcome.dismissed,
      ShareResultStatus.unavailable => ShareOutcome.unavailable,
    };
  }
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
    this.generation = 0, this.sharer = const SystemArtifactSharer(), this.artifactDirectory = jobArtifactDirectory,
    this.openSink = openArtifactSink, this.promoteArtifact = promoteArtifactFile});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int generation;
  final int id;
  final ArtifactSharer sharer;
  final Future<Directory> Function(Account account, int projectId, int jobId) artifactDirectory;
  final IOSink Function(File file) openSink;
  final Future<File> Function(File partial, File target) promoteArtifact;
  @override
  State<JobLogPage> createState() => _JobLogPageState();
}
class _JobLogPageState extends State<JobLogPage> with WidgetsBindingObserver {
  late int _jobId;
  int _loadEpoch = 0;
  Json? _job;
  JobTrace _trace = JobTrace.empty;
  JobTrace _indexed = JobTrace.empty;
  List<int> _sectionOrder = const <int>[];
  List<List<int>> _sectionChildren = const <List<int>>[];
  List<int> _sectionRoots = const <int>[];
  Set<int> _queryHits = const <int>{};
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
  void _ensureSectionIndex() {
    if (identical(_indexed, _trace)) return;
    final built = _indexSections(_trace);
    _indexed = _trace;
    _sectionOrder = built.order;
    _sectionChildren = built.children;
    _sectionRoots = built.roots;
  }
  bool _collapsed(int index) {
    if (_queryHits.contains(index)) return false;
    final section = _trace.sections[index];
    final opened = _sectionOpen[_sectionKey(section)];
    if (opened != null) return !opened;
    return section.collapsed;
  }
  void _toggleSection(int index) {
    final key = _sectionKey(_trace.sections[index]);
    setState(() => _sectionOpen[key] = _collapsed(index));
  }
  Set<int> _sectionsMatching(String query) {
    if (query.isEmpty) return const <int>{};
    final needle = query.toLowerCase();
    final sections = _trace.sections;
    final hits = <int>{};
    var next = 0;
    final active = <int>[];
    for (var line = 0; line < _trace.lines.length; line++) {
      while (active.isNotEmpty && sections[active.last].endLine <= line) {
        active.removeLast();
      }
      while (next < _sectionOrder.length && sections[_sectionOrder[next]].startLine <= line) {
        final index = _sectionOrder[next];
        if (sections[index].endLine > line) active.add(index);
        next++;
      }
      if (_trace.lines[line].text.toLowerCase().contains(needle)) hits.addAll(active);
    }
    return hits;
  }
  List<_LogRow> _visibleRows() {
    _ensureSectionIndex();
    _queryHits = _sectionsMatching(_query);
    final rows = <_LogRow>[];
    final lines = _trace.lines;
    final sections = _trace.sections;
    final needle = _query.toLowerCase();
    void addLine(int line) {
      final text = lines[line].text;
      if (needle.isEmpty || text.toLowerCase().contains(needle)) rows.add(_LogRow.line(text));
    }
    final stack = <_SectionWalk>[_SectionWalk(0, lines.length, _sectionRoots)];
    while (stack.isNotEmpty) {
      final frame = stack.last;
      if (frame.child >= frame.kids.length) {
        for (var line = frame.cursor; line < frame.to; line++) {
          addLine(line);
        }
        stack.removeLast();
        continue;
      }
      final index = frame.kids[frame.child];
      final section = sections[index];
      if (section.startLine < frame.cursor) {
        frame.child++;
        continue;
      }
      final end = section.endLine < frame.to ? section.endLine : frame.to;
      for (var line = frame.cursor; line < section.startLine && line < frame.to; line++) {
        addLine(line);
      }
      frame.cursor = end > frame.cursor ? end : frame.cursor;
      frame.child++;
      if (section.depth >= JobTrace.maxDepth) {
        for (var line = section.startLine; line < end; line++) {
          addLine(line);
        }
        continue;
      }
      rows.add(_LogRow.header(index));
      if (!_collapsed(index)) stack.add(_SectionWalk(section.startLine, end, _sectionChildren[index]));
    }
    return rows;
  }
  Widget _sectionHeader(int index) {
    final section = _trace.sections[index];
    final collapsed = _collapsed(index);
    final duration = section.durationSeconds;
    final title = duration == null ? section.label : '${section.label} · $duration 秒';
    return Semantics(
      button: true,
      expanded: !collapsed,
      label: title,
      excludeSemantics: true,
      onTap: () => _toggleSection(index),
      child: InkWell(
        onTap: () => _toggleSection(index),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: EdgeInsets.only(left: (section.depth > 4 ? 4 : section.depth) * 12.0),
            child: Row(children: [
              Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18),
              const SizedBox(width: 4),
              Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
      ),
    );
  }
  Future<void> _downloadArtifacts() async {
    final job = _job;
    if (job == null || _downloading) return;
    final info = valueObject(job, 'artifacts_file');
    final suggested = valueText(info, 'filename');
    if (suggested.isEmpty) return;
    final size = info['size'];
    final jobId = _jobId;
    final generation = widget.generation;
    final accountKey = widget.account.key;
    final api = widget.api;
    setState(() => _downloading = true);
    try {
      if (!mounted) return;
      await showModalBottomSheet<void>(context: context, isScrollControlled: true,
        builder: (context) => _ArtifactDownloadSheet(
          account: widget.account, api: api, projectId: widget.project.id, projectPath: widget.project.path,
          jobId: jobId, suggestedName: suggested, suggestedSize: size is int ? size : null,
          sharer: widget.sharer, artifactDirectory: widget.artifactDirectory, openSink: widget.openSink,
          promoteArtifact: widget.promoteArtifact,
          sessionCurrent: () => !api.isClosed && widget.generation == generation && widget.account.key == accountKey,
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
                if (section != null) return _sectionHeader(section);
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

final class _SectionWalk {
  _SectionWalk(this.cursor, this.to, this.kids);
  int cursor;
  final int to;
  final List<int> kids;
  int child = 0;
}

final class _SectionIndex {
  const _SectionIndex(this.order, this.children, this.roots);
  final List<int> order;
  final List<List<int>> children;
  final List<int> roots;
}

_SectionIndex _indexSections(JobTrace trace) {
  final sections = trace.sections;
  final order = List<int>.generate(sections.length, (index) => index)..sort((a, b) {
    final start = sections[a].startLine.compareTo(sections[b].startLine);
    if (start != 0) return start;
    return sections[a].depth.compareTo(sections[b].depth);
  });
  final children = List<List<int>>.generate(sections.length, (_) => <int>[]);
  final roots = <int>[];
  final stack = <int>[];
  for (final index in order) {
    final section = sections[index];
    while (stack.isNotEmpty &&
        (sections[stack.last].endLine <= section.startLine || sections[stack.last].depth >= section.depth)) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(index);
    } else {
      children[stack.last].add(index);
    }
    stack.add(index);
  }
  return _SectionIndex(order, children, roots);
}

class _ArtifactDownloadSheet extends StatefulWidget {
  const _ArtifactDownloadSheet({
    required this.account, required this.api, required this.projectId, required this.projectPath,
    required this.jobId, required this.suggestedName, required this.suggestedSize,
    required this.sharer, required this.artifactDirectory, required this.openSink,
    required this.promoteArtifact, required this.sessionCurrent, required this.webUri,
  });
  final Account account;
  final GitLabApi api;
  final int projectId;
  final String projectPath;
  final int jobId;
  final String suggestedName;
  final int? suggestedSize;
  final ArtifactSharer sharer;
  final Future<Directory> Function(Account account, int projectId, int jobId) artifactDirectory;
  final IOSink Function(File file) openSink;
  final Future<File> Function(File partial, File target) promoteArtifact;
  final bool Function() sessionCurrent;
  final Uri webUri;
  @override
  State<_ArtifactDownloadSheet> createState() => _ArtifactDownloadSheetState();
}

class _ArtifactDownloadSheetState extends State<_ArtifactDownloadSheet> {
  Completer<void> _abort = Completer<void>();
  late final ArtifactProgress _progress;
  int _attempt = 0;
  bool _disposed = false, _done = false, _popWhenCancelled = false, _sharing = false;
  Directory? _attemptDirectory;
  File? _partial;
  String? _savedName, _savedPath;
  int _savedBytes = 0;
  ApiFailure? _error;
  @override
  void initState() {
    super.initState();
    _progress = ArtifactProgress(initial: (0, widget.suggestedSize));
    unawaited(_start());
  }
  @override
  void dispose() {
    _disposed = true;
    if (!_abort.isCompleted) _abort.complete();
    final directory = _attemptDirectory;
    final partial = _partial;
    _progress.dispose();
    unawaited(_deleteAttemptFiles(directory, partial));
    super.dispose();
  }
  Future<void> _start() async {
    final attempt = ++_attempt;
    final abort = Completer<void>();
    _abort = abort;
    IOSink? ownedSink;
    Directory? ownedDirectory;
    File? ownedPartial;
    Object? sinkFailure;
    // A closed client or a changed account/generation must not publish the archive.
    bool current() => !_disposed && mounted && attempt == _attempt && identical(_abort, abort) && !abort.isCompleted
        && widget.sessionCurrent();
    Future<void> cleanup() async {
      final open = ownedSink;
      ownedSink = null;
      if (open != null) {
        try {
          await open.close();
        } on Object catch (error) {
          if (error is! StateError && error is! FileSystemException) rethrow;
        }
      }
      await _deleteAttemptFiles(ownedDirectory, ownedPartial);
      if (identical(_attemptDirectory, ownedDirectory)) _attemptDirectory = null;
      if (identical(_partial, ownedPartial)) _partial = null;
      ownedDirectory = null;
      ownedPartial = null;
    }
    try {
      final directory = await widget.artifactDirectory(widget.account, widget.projectId, widget.jobId);
      ownedDirectory = directory;
      _attemptDirectory = directory;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      final partial = File('${directory.path}/$_artifactPartialName');
      ownedPartial = partial;
      _partial = partial;
      final sink = widget.openSink(partial);
      ownedSink = sink;
      unawaited(sink.done.then<void>((_) {}, onError: (Object error, StackTrace _) {
        sinkFailure ??= error;
        if (!abort.isCompleted) abort.complete();
      }));
      final result = await widget.api.downloadJobArtifacts(widget.projectId, widget.jobId,
        sink: sink, cancel: abort.future, onProgress: (received, total) {
          if (_disposed || attempt != _attempt) return;
          _progress.report(received, total);
        });
      if (sinkFailure != null) throw sinkFailure!;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      await sink.flush();
      if (sinkFailure != null) throw sinkFailure!;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      await sink.close();
      ownedSink = null;
      if (sinkFailure != null) throw sinkFailure!;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      final name = _downloadFileName(result.fileName, widget.jobId);
      final target = File('${directory.path}/$name');
      if (sinkFailure != null) throw sinkFailure!;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      final saved = await widget.promoteArtifact(partial, target);
      ownedPartial = null;
      _partial = null;
      if (sinkFailure != null || !current()) {
        if (saved.existsSync()) await saved.delete();
        throw sinkFailure ?? const ApiFailure(FailureKind.cancelled);
      }
      _progress.report(result.bytesWritten, _progress.value.value.$2, completed: true);
      if (!mounted || attempt != _attempt) {
        await _deleteAttemptFiles(directory, null);
        if (identical(_attemptDirectory, directory)) _attemptDirectory = null;
        return;
      }
      setState(() {
        _done = true; _error = null; _savedName = name; _savedBytes = result.bytesWritten; _savedPath = target.path;
      });
    } catch (error) {
      await cleanup();
      if (_disposed || !mounted || attempt != _attempt) return;
      final cause = sinkFailure ?? error;
      final failure = cause is FileSystemException ? ApiFailure.artifactStorage : safeFailure(cause);
      if (sinkFailure == null && failure.kind == FailureKind.cancelled) {
        if (_popWhenCancelled) Navigator.pop(context);
        return;
      }
      setState(() => _error = failure);
    }
  }
  Future<void> _retry() async {
    if (!_abort.isCompleted) _abort.complete();
    if (!mounted || _disposed) return;
    setState(() { _error = null; _done = false; _savedName = null; _savedPath = null; _savedBytes = 0; });
    _progress.report(0, widget.suggestedSize, completed: true);
    await _start();
  }
  void _cancel() {
    _popWhenCancelled = true;
    if (!_abort.isCompleted) _abort.complete();
  }
  Future<void> _share() async {
    final path = _savedPath;
    if (path == null || _sharing) return;
    setState(() => _sharing = true);
    try {
      await shareDownloadedArtifact(widget.sharer, path);
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    return SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.suggestedName, style: Theme.of(context).textTheme.titleMedium),
        if (widget.suggestedSize != null) Padding(padding: const EdgeInsets.only(top: 4),
          child: Text(formatByteCount(widget.suggestedSize!), style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 16),
        if (_error != null) FailureNotice(_error!, onRetry: () { unawaited(_retry()); }, account: widget.account,
          resourceLabel: '${widget.projectPath} · Job #${widget.jobId} 產物', onSwitchAccount: endSessionFrom(context)),
        if (_done) ...[
          Text('已下載 ${_savedName ?? widget.suggestedName} · ${formatByteCount(_savedBytes)}'),
          const SizedBox(height: 12),
          FilledButton(onPressed: _sharing ? null : () => unawaited(_share()), child: const Text('開啟／分享')),
          TextButton(onPressed: () => unawaited(openExternal(context, widget.webUri)), child: const Text('在 GitLab 開啟')),
        ],
        if (_error == null && !_done) ...[
          ValueListenableBuilder<(int, int?)>(
            valueListenable: _progress.value,
            builder: (context, value, _) {
              final received = value.$1;
              final total = value.$2;
              final double? progress = total == null || total <= 0 ? null : (received / total).clamp(0.0, 1.0).toDouble();
              final bytes = total == null ? formatByteCount(received) : '${formatByteCount(received)} / ${formatByteCount(total)}';
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                LinearProgressIndicator(key: const Key('artifact-progress'), minHeight: 4, value: progress),
                const SizedBox(height: 8),
                Text(bytes, style: Theme.of(context).textTheme.bodySmall),
              ]);
            },
          ),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: _cancel, child: const Text('取消'))),
        ],
      ],
    )));
  }
}

Future<void> _deleteAttemptFiles(Directory? directory, File? partial) async {
  if (partial != null && partial.existsSync()) {
    try {
      await partial.delete();
    } on FileSystemException {
      // A cancelled attempt may already have removed the temp file.
    }
  }
  if (directory != null && directory.existsSync()) {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // The cache directory can disappear while cleanup is in progress.
    }
  }
}

String _downloadFileName(String name, int job) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  if (base.isEmpty || base == '.' || base == '..' || base == '.partial' || base == _artifactPartialName ||
      base.contains('\u0000')) {
    return 'artifacts-$job.zip';
  }
  return base;
}
