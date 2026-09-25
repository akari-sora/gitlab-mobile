import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import 'ci_page.dart';
import 'project_page.dart';

final class ProjectCiItem {
  const ProjectCiItem({
    required this.project,
    this.latestPipeline,
    this.error,
  });

  final Project project;
  final Json? latestPipeline;
  final ApiFailure? error;

  String get status {
    if (error != null) return 'error';
    if (latestPipeline != null) {
      return valueText(latestPipeline!, 'status', 'unknown');
    }
    return 'none';
  }

  bool get isRunning => status == 'running';
  bool get isFailed => const ['failed', 'canceled'].contains(status);
}

/// Concurrency pool mapping items with a maximum number of concurrent tasks.
Future<List<R>> poolMap<T, R>(
  List<T> items,
  Future<R> Function(T item) worker, {
  int maxConcurrent = 4,
}) async {
  if (items.isEmpty) return <R>[];
  final results = List<R?>.filled(items.length, null);
  var nextIndex = 0;
  Future<void> runWorker() async {
    while (true) {
      final currentIndex = nextIndex++;
      if (currentIndex >= items.length) break;
      results[currentIndex] = await worker(items[currentIndex]);
    }
  }

  final workerCount = maxConcurrent.clamp(1, items.length);
  final workers = List.generate(workerCount, (_) => runWorker());
  await Future.wait(workers);
  return results.cast<R>();
}

class CiOverviewPage extends StatefulWidget {
  const CiOverviewPage({
    super.key,
    this.session,
    this.account,
    this.api,
    this.maxConcurrent = 4,
  });

  final SessionController? session;
  final Account? account;
  final GitLabApi? api;
  final int maxConcurrent;

  @override
  State<CiOverviewPage> createState() => _CiOverviewPageState();
}

class _CiOverviewPageState extends State<CiOverviewPage> {
  int _loadEpoch = 0;
  bool _loading = false;
  bool _loadingMore = false;
  Uri? _nextPageUri;
  ApiFailure? _error;
  List<ProjectCiItem> _items = const [];
  String _filter = ''; // '', 'running', 'failed'
  String _search = '';
  final _searchController = TextEditingController();

  Account? get _account => widget.account ?? widget.session?.active;
  GitLabApi? get _api => widget.api ?? widget.session?.api;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || !mounted) return;
    final curAccount = _account;
    final curApi = _api;
    if (curAccount == null || curApi == null) return;
    final epoch = ++_loadEpoch;
    final startGeneration = widget.session?.generation;
    final startAccountKey = curAccount.key;
    bool current() =>
        mounted &&
        epoch == _loadEpoch &&
        (widget.session == null || widget.session!.generation == startGeneration) &&
        (widget.session == null || widget.session!.active?.key == startAccountKey);

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final page = await curApi.records(
        ['projects'],
        query: {
          'membership': 'true',
          'order_by': 'last_activity_at',
          'sort': 'desc',
        },
      );
      if (!current()) return;
      _nextPageUri = page.next;

      final projects = page.items.map(Project.fromJson).toList();

      final items = await poolMap(
        projects,
        (project) async {
          if (!current()) {
            return ProjectCiItem(project: project);
          }
          try {
            final pipelinePage = await curApi.records(
              ['projects', '${project.id}', 'pipelines'],
              query: {'per_page': '1'},
            );
            return ProjectCiItem(
              project: project,
              latestPipeline: pipelinePage.items.isNotEmpty ? pipelinePage.items.first : null,
            );
          } catch (e) {
            return ProjectCiItem(
              project: project,
              error: safeFailure(e),
            );
          }
        },
        maxConcurrent: widget.maxConcurrent,
      );

      if (!current()) return;
      setState(() {
        _items = items;
      });
    } catch (e) {
      if (current()) {
        setState(() {
          _error = safeFailure(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _nextPageUri == null || !mounted) return;
    final curAccount = _account;
    final curApi = _api;
    if (curAccount == null || curApi == null) return;
    final epoch = _loadEpoch;
    final startGeneration = widget.session?.generation;
    final startAccountKey = curAccount.key;
    bool current() =>
        mounted &&
        epoch == _loadEpoch &&
        (widget.session == null || widget.session!.generation == startGeneration) &&
        (widget.session == null || widget.session!.active?.key == startAccountKey);

    setState(() {
      _loadingMore = true;
    });

    try {
      final page = await curApi.records(
        ['projects'],
        query: {
          'membership': 'true',
          'order_by': 'last_activity_at',
          'sort': 'desc',
        },
        next: _nextPageUri,
      );
      if (!current()) return;
      _nextPageUri = page.next;

      final projects = page.items.map(Project.fromJson).toList();

      final newItems = await poolMap(
        projects,
        (project) async {
          if (!current()) {
            return ProjectCiItem(project: project);
          }
          try {
            final pipelinePage = await curApi.records(
              ['projects', '${project.id}', 'pipelines'],
              query: {'per_page': '1'},
            );
            return ProjectCiItem(
              project: project,
              latestPipeline: pipelinePage.items.isNotEmpty ? pipelinePage.items.first : null,
            );
          } catch (e) {
            return ProjectCiItem(
              project: project,
              error: safeFailure(e),
            );
          }
        },
        maxConcurrent: widget.maxConcurrent,
      );

      if (!current()) return;
      setState(() {
        _items = [..._items, ...newItems];
      });
    } catch (_) {
      // Keep existing items on failure
    } finally {
      if (mounted) {
        setState(() {
          _loadingMore = false;
        });
      }
    }
  }

  List<ProjectCiItem> get _filteredItems {
    var list = _items;
    if (_filter == 'running') {
      list = list.where((i) => i.isRunning).toList();
    } else if (_filter == 'failed') {
      list = list.where((i) => i.isFailed).toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where((i) =>
              i.project.name.toLowerCase().contains(q) ||
              i.project.path.toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  Future<void> _openItem(ProjectCiItem item) async {
    final curAccount = _account;
    final curApi = _api;
    if (curAccount == null || curApi == null) return;
    final latest = item.latestPipeline;
    if (latest != null) {
      final pipelineId = requiredInt(latest, 'id');
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PipelinePage(
            account: curAccount,
            api: curApi,
            project: item.project,
            id: pipelineId,
          ),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ProjectPage(
            account: curAccount,
            api: curApi,
            project: item.project,
            initialTab: 3,
          ),
        ),
      );
    }
    if (mounted) {
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final curAccount = _account;
    final curApi = _api;
    if (curAccount == null || curApi == null) {
      return const Scaffold(
        body: Center(child: SizedBox()),
      );
    }
    final gutter = feedGutter(context);
    final displayed = _filteredItems;

    return Scaffold(
      appBar: AppBar(
        title: const Text('CI / CD'),
        actions: [
          IconButton(
            tooltip: '重新整理',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 12),
              child: Row(
                children: [
                  Monogram(curAccount.user.name, size: 32),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '@${curAccount.user.username}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          '選擇專案，查看流程與工作紀錄',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (widget.session != null)
                    IconButton(
                      tooltip: '切換帳號',
                      onPressed: () {
                        unawaited(widget.session!.endSession());
                      },
                      icon: const Icon(Icons.swap_horiz, size: 20),
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _search = value.trim()),
                decoration: InputDecoration(
                  hintText: '搜尋成員專案',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(
                          tooltip: '清除搜尋',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _search = '');
                          },
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: Row(
                children: [
                  for (final entry in const {
                    '': '全部',
                    'running': '執行中',
                    'failed': '失敗',
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(entry.value),
                        selected: _filter == entry.key,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _filter = entry.key),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: _buildBody(gutter, displayed),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(double gutter, List<ProjectCiItem> displayed) {
    if (_loading && _items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: FailureNotice(
            _error!,
            onRetry: _load,
            onSwitchAccount:
                widget.session != null ? endSessionFrom(context) : null,
          ),
        ),
      );
    }
    if (displayed.isEmpty) {
      final msg = _filter.isNotEmpty || _search.isNotEmpty
          ? '沒有符合條件的 Pipeline'
          : '沒有成員專案';
      return Center(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: EmptyState(
            msg,
            icon: Icons.account_tree_outlined,
          ),
        ),
      );
    }

    final hasMore = _nextPageUri != null || _loadingMore;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 4),
      itemCount: displayed.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == displayed.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: _loadingMore
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : OutlinedButton.icon(
                      key: const ValueKey('ci-overview-load-more'),
                      icon: const Icon(Icons.expand_more, size: 18),
                      label: const Text('載入更多成員專案'),
                      onPressed: _loadMore,
                    ),
            ),
          );
        }
        final item = displayed[index];
        return _buildProjectCard(item);
      },
    );
  }

  Widget _buildProjectCard(ProjectCiItem item) {
    final scheme = Theme.of(context).colorScheme;
    final workshop = WorkshopColors.of(context);

    BorderSide side;
    if (item.isFailed) {
      side = BorderSide(color: scheme.error, width: 1.5);
    } else if (item.isRunning) {
      side = BorderSide(color: workshop.running, width: 1.5);
    } else {
      side = BorderSide(color: scheme.outlineVariant);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: item.isFailed || item.isRunning ? 2 : 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: side,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openItem(item),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.project.name,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.project.path,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (item.latestPipeline != null)
                    StatusBadge(valueText(item.latestPipeline!, 'status'))
                  else if (item.error != null)
                    Tooltip(
                      message: item.error!.status == 404
                          ? '目前無法取得 CI 資源，可能不存在或目前帳號無權存取'
                          : item.error!.status == 403
                              ? '目前帳號沒有此專案的 CI/CD 檢視權限'
                              : '無法取得 CI 狀態',
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          item.error!.status == 403
                              ? '沒有 CI 權限'
                              : item.error!.status == 404
                                  ? '無法存取或無 CI 資源'
                                  : '無法取得 CI 狀態',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: scheme.onErrorContainer,
                              ),
                        ),
                      ),
                    )
                    else
                      Text(
                        '無 Pipeline',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                  ],
                ),
                if (item.latestPipeline != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        valueText(
                          item.latestPipeline!,
                          'name',
                          'Pipeline #${valueInt(item.latestPipeline!, 'id')}',
                        ),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      if (valueText(item.latestPipeline!, 'ref').isNotEmpty)
                        Text(
                          valueText(item.latestPipeline!, 'ref'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      if (valueText(item.latestPipeline!, 'sha').isNotEmpty)
                        Text(
                          shortSha(valueText(item.latestPipeline!, 'sha')),
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: codeFontFamily,
                            fontFamilyFallback: ['Menlo', 'monospace'],
                          ),
                        ),
                    ],
                  ),
                  if (valueText(item.latestPipeline!, 'updated_at').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      relativeDate(valueText(item.latestPipeline!, 'updated_at')),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
