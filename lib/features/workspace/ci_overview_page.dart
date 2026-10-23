import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import 'ci_page.dart';
import 'project_page.dart';

import '../../l10n/l10n.dart';
enum ProjectCiLoadState { unknown, loading, known, error }

final class ProjectCiItem {
  const ProjectCiItem({
    required this.project,
    this.state = ProjectCiLoadState.unknown,
    this.latestPipeline,
    this.error,
  });

  final Project project;
  final ProjectCiLoadState state;
  final Json? latestPipeline;
  final ApiFailure? error;

  ProjectCiItem copyWith({
    ProjectCiLoadState? state,
    Json? latestPipeline,
    ApiFailure? error,
  }) => ProjectCiItem(
    project: project,
    state: state ?? this.state,
    latestPipeline: latestPipeline,
    error: error,
  );

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
  static const _pipelineBatchSize = 8;

  int _loadEpoch = 0;
  bool _loading = false;
  bool _loadingMore = false;
  Uri? _nextPageUri;
  ApiFailure? _error;
  List<ProjectCiItem> _items = const [];
  String _filter = ''; // '', 'running', 'failed'
  String _search = '';
  final _searchController = TextEditingController();
  final _scroll = ScrollController();

  Account? get _account => widget.account ?? widget.session?.active;
  GitLabApi? get _api => widget.api ?? widget.session?.api;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(CiOverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final accountChanged = oldWidget.account?.key != widget.account?.key;
    final apiChanged = !identical(oldWidget.api, widget.api);
    final sessionChanged = !identical(oldWidget.session, widget.session);
    if (accountChanged || apiChanged || sessionChanged) {
      _loadEpoch++;
      _loading = false;
      _loadingMore = false;
      _nextPageUri = null;
      _error = null;
      _items = const [];
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool fresh = false, bool background = false}) async {
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
        identical(_api, curApi) &&
        _account?.key == startAccountKey &&
        (widget.session == null || widget.session!.generation == startGeneration) &&
        (widget.session == null || widget.session!.active?.key == startAccountKey);

    setState(() {
      _loading = true;
      _error = null;
    });

    var revalidateStaleProjects = false;
    try {
      final read = await _cachedPage(
        curApi,
        ['projects'],
        query: {
          'membership': 'true',
          'order_by': 'last_activity_at',
          'sort': 'desc',
        },
        fresh: fresh,
        background: background,
        current: current,
      );
      if (!current()) return;
      if (read == null) {
        if (!background && _items.isEmpty) {
          setState(() => _error = const ApiFailure(FailureKind.cancelled));
        }
        return;
      }
      final page = read.value;
      revalidateStaleProjects = read.stale && !fresh;
      _nextPageUri = page.next;

      final projects = page.items.map(Project.fromJson).toList();
      setState(() {
        final previous = {for (final item in _items) item.project.id: item};
        _items = projects.map((project) {
          final item = previous[project.id];
          return item == null
              ? ProjectCiItem(project: project)
              : ProjectCiItem(
                  project: project,
                  state: item.state,
                  latestPipeline: item.latestPipeline,
                  error: item.error,
                );
        }).toList();
      });
      await _loadPipelineRows(
        projects,
        api: curApi,
        current: current,
        fresh: fresh,
        background: background,
        revalidateStale: !revalidateStaleProjects,
      );
    } catch (e) {
      if (current()) {
        setState(() {
          _error = safeFailure(e);
        });
      }
    } finally {
      if (current()) {
        setState(() {
          _loading = false;
        });
        if (revalidateStaleProjects) {
          unawaited(_load(fresh: true, background: true));
        }
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
        identical(_api, curApi) &&
        _account?.key == startAccountKey &&
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
      setState(() {
        _items = [
          ..._items,
          ...projects.map((project) => ProjectCiItem(project: project)),
        ];
      });
      await _loadPipelineRows(projects, api: curApi, current: current);
    } catch (_) {
      // Keep existing items on failure
    } finally {
      if (current()) {
        setState(() {
          _loadingMore = false;
        });
      }
    }
  }

  List<ProjectCiItem> get _filteredItems {
    Iterable<ProjectCiItem> list = _items;
    if (_filter == 'running') {
      list = list.where((i) => i.isRunning || _isUnresolved(i));
    } else if (_filter == 'failed') {
      list = list.where((i) => i.isFailed || _isUnresolved(i));
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where((i) =>
              i.project.name.toLowerCase().contains(q) ||
              i.project.path.toLowerCase().contains(q));
    }
    final results = list.toList();
    final sourceIndex = <int, int>{
      for (var index = 0; index < _items.length; index++)
        _items[index].project.id: index,
    };
    results.sort((a, b) {
      final stateOrder = _stateOrder(a.state).compareTo(_stateOrder(b.state));
      if (stateOrder != 0) return stateOrder;
      return sourceIndex[a.project.id]!.compareTo(sourceIndex[b.project.id]!);
    });
    return results;
  }

  int _stateOrder(ProjectCiLoadState state) => switch (state) {
    ProjectCiLoadState.known => 0,
    ProjectCiLoadState.error => 1,
    ProjectCiLoadState.loading => 2,
    ProjectCiLoadState.unknown => 3,
  };

  bool _isUnresolved(ProjectCiItem item) =>
      item.state == ProjectCiLoadState.unknown ||
      item.state == ProjectCiLoadState.loading;

  Future<void> _loadPipelineRows(
    List<Project> projects, {
    required GitLabApi api,
    required bool Function() current,
    bool fresh = false,
    bool background = false,
    bool revalidateStale = true,
  }) async {
    final stale = <Project>[];
    for (var start = 0; start < projects.length; start += _pipelineBatchSize) {
      if (!current()) return;
      final proposedEnd = start + _pipelineBatchSize;
      final end = proposedEnd < projects.length ? proposedEnd : projects.length;
      final batch = projects.sublist(start, end);
      final results = await poolMap(
        batch,
        (project) => _loadPipelineRow(
          project,
          api: api,
          current: current,
          fresh: fresh,
          background: background,
        ),
        maxConcurrent: widget.maxConcurrent,
      );
      for (var index = 0; index < results.length; index++) {
        if (results[index]) stale.add(batch[index]);
      }
    }
    if (revalidateStale && stale.isNotEmpty && current()) {
      unawaited(_loadPipelineRows(
        stale,
        api: api,
        current: current,
        fresh: true,
        background: true,
        revalidateStale: false,
      ));
    }
  }

  Future<bool> _loadPipelineRow(
    Project project, {
    required GitLabApi api,
    required bool Function() current,
    bool fresh = false,
    bool background = false,
  }) async {
    if (!current()) return false;
    _replaceItem(
      project.id,
      (item) => item.state == ProjectCiLoadState.known
          ? item
          : item.copyWith(state: ProjectCiLoadState.loading),
    );
    try {
      final read = await _cachedPage(
        api,
        ['projects', '${project.id}', 'pipelines'],
        query: {'per_page': '1'},
        fresh: fresh,
        background: background,
        current: current,
      );
      if (!current()) return false;
      if (read == null) {
        if (!background) {
          _replaceItem(
            project.id,
            (item) => item.state == ProjectCiLoadState.known
                ? item
                : item.copyWith(
                    state: ProjectCiLoadState.error,
                    error: const ApiFailure(FailureKind.cancelled),
                  ),
          );
        }
        return false;
      }
      final pipelinePage = read.value;
      _replaceItem(
        project.id,
        (item) => item.copyWith(
          state: ProjectCiLoadState.known,
          latestPipeline: pipelinePage.items.isNotEmpty ? pipelinePage.items.first : null,
        ),
      );
      return read.stale && !fresh;
    } catch (e) {
      if (!current()) return false;
      final failure = safeFailure(e);
      final revoked = switch (failure.kind) {
        FailureKind.unauthenticated ||
        FailureKind.forbidden ||
        FailureKind.invisible => true,
        _ => false,
      };
      _replaceItem(
        project.id,
        (item) => background && !revoked && item.state == ProjectCiLoadState.known
            ? item
            : item.copyWith(
                state: ProjectCiLoadState.error,
                error: failure,
              ),
      );
      return false;
    }
  }

  Future<CachedRead<ApiPage<Json>>?> _cachedPage(
    GitLabApi api,
    List<String> path, {
    required Map<String, String> query,
    required bool fresh,
    required bool background,
    required bool Function() current,
  }) async {
    Future<CachedRead<ApiPage<Json>>> readPage({
      required bool fresh,
      bool quiet = false,
    }) => CachedRead.run(
      () => api.cachedRecords(
        path,
        query: query,
        fresh: fresh,
        background: background,
      ),
      mayStart: current,
      waitForQuiet: quiet,
    );

    var read = await readPage(fresh: fresh);
    if (read.superseded) {
      read = await readPage(fresh: true);
      if (read.superseded) {
        read = await readPage(fresh: true, quiet: true);
      }
      if (read.superseded) {
        throw const ApiFailure(FailureKind.cancelled);
      }
    }
    return read.dropped ? null : read;
  }

  void _replaceItem(
    int projectId,
    ProjectCiItem Function(ProjectCiItem item) replace,
  ) {
    if (!mounted) return;
    final index = _items.indexWhere((item) => item.project.id == projectId);
    if (index < 0) return;
    setState(() {
      final items = List<ProjectCiItem>.of(_items);
      items[index] = replace(items[index]);
      _items = items;
    });
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
      unawaited(_load(fresh: true, background: true));
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
            tooltip: l10n.refreshAction,
            onPressed: _loading ? null : () => _load(fresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () => _load(fresh: true),
          child: ScrollToTopOnSignal(
            controller: _scroll,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _header(context, gutter)),
                ..._bodySlivers(gutter, displayed),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, double gutter) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(gutter + 4, 0, gutter, 8),
              child: Text(
                l10n.selectProjectForCi,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _search = value.trim()),
                decoration: InputDecoration(
                  hintText: l10n.searchMemberProjects,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(
                          tooltip: l10n.clearSearch,
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
                  for (final entry in {
                    '': l10n.filterAll,
                    'running': l10n.statusRunning,
                    'failed': l10n.statusFailed,
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: ValueKey(
                          'ci-overview-filter-${entry.key.isEmpty ? 'all' : entry.key}',
                        ),
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
          ],
        );

  List<Widget> _bodySlivers(double gutter, List<ProjectCiItem> displayed) {
    if (_loading && _items.isEmpty) {
      return const [SliverFillRemaining(hasScrollBody: false, child: ListSkeleton())];
    }
    if (_error != null && _items.isEmpty) {
      return [SliverToBoxAdapter(child: FailureNotice(
        _error!,
        onRetry: _load,
        onSwitchAccount: widget.session != null ? endSessionFrom(context) : null,
      ))];
    }
    if (displayed.isEmpty) {
      final msg = _filter.isNotEmpty || _search.isNotEmpty
          ? l10n.noPipelinesMatchFilters
          : l10n.noMemberProjects;
      return [SliverToBoxAdapter(child: EmptyState(msg, icon: Icons.account_tree_outlined))];
    }

    final hasMore = _nextPageUri != null || _loadingMore;
    return [SliverPadding(
      padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 24),
      sliver: SliverList.builder(
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
                      label: Text(l10n.loadMoreMemberProjects),
                      onPressed: _loadMore,
                    ),
            ),
          );
        }
        final item = displayed[index];
        return _buildProjectCard(item);
      },
    ))];
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
        key: ValueKey(
          'ci-overview-state-${item.project.id}-${item.state.name}',
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: side,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _isUnresolved(item) ? null : () => _openItem(item),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                  if (item.state == ProjectCiLoadState.loading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (item.state == ProjectCiLoadState.unknown)
                    Icon(
                      Icons.help_outline,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    )
                  else if (item.latestPipeline != null)
                    StatusBadge(valueText(item.latestPipeline!, 'status'))
                  else if (item.error != null)
                    Tooltip(
                      message: item.error!.status == 404
                          ? l10n.ciResourcesUnavailable
                          : item.error!.status == 403
                              ? l10n.noProjectCicdViewPermission
                              : l10n.ciStatusLoadFailed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          item.error!.status == 403
                              ? l10n.noCiPermission
                              : item.error!.status == 404
                                  ? l10n.ciInaccessibleOrMissing
                                  : l10n.ciStatusLoadFailed,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: scheme.onErrorContainer,
                              ),
                        ),
                      ),
                    )
                    else
                      Text(
                        l10n.noPipelines,
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
                          'Pipeline #${valueInt(item.latestPipeline!, 'iid') > 0 ? valueInt(item.latestPipeline!, 'iid') : valueInt(item.latestPipeline!, 'id')}',
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
