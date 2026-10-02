import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/analytics_models.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import '../../shared/scroll_chrome.dart';

class ProjectAnalyticsPage extends StatefulWidget {
  const ProjectAnalyticsPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  State<ProjectAnalyticsPage> createState() => _ProjectAnalyticsPageState();
}

class _ProjectAnalyticsPageState extends State<ProjectAnalyticsPage>
    with SingleTickerProviderStateMixin {
  static const _pageLimit = 20, _rowLimit = 2000;
  static const _ranges = [7, 30, 90, 180];
  late final TabController _tabs;
  late final TextEditingController _ref;
  int _generation = 0, _activeDays = 30, _draftDays = 30;
  AnalyticsPipelineSource _activeSource = AnalyticsPipelineSource.any;
  AnalyticsPipelineSource _draftSource = AnalyticsPipelineSource.any;
  String _activeRef = '';
  late DateTime _from, _to;

  List<ContributorSummary>? _contributors;
  ApiFailure? _contributorError;
  Uri? _nextContributors;
  int _contributorPages = 0;
  int _contributorRequest = 0;
  bool _contributorLoading = false, _contributorLimited = false;

  List<RepositoryActivityCommit>? _commits;
  Uri? _nextCommits;
  ApiFailure? _commitError, _moreError;
  bool _commitLoading = false;
  int _commitPages = 0;
  int _commitRequest = 0;
  List<MapEntry<DateTime, _ActivityDay>> _dayRows = const [];
  int _dayMax = 1;

  PipelineAnalyticsSnapshot? _pipelines;
  ApiFailure? _pipelineError, _coverageError, _languageError;
  bool _ciLoading = false, _coverageLoaded = false;
  int _pipelineRequest = 0;
  bool _coverageLoading = false, _languageLoading = false;
  int _coverageRequest = 0, _languageRequest = 0;
  CoverageSummary? _coverage;
  List<(String, double)>? _languages;

  @override
  void initState() {
    super.initState();
    _activeRef = widget.project.defaultBranch ?? '';
    final window = _newWindow(_activeDays);
    _from = window.$1;
    _to = window.$2;
    _ref = TextEditingController(text: _activeRef);
    _tabs = TabController(length: 3, vsync: this)..addListener(_tabChanged);
    unawaited(_ensureLoaded());
  }

  @override
  void didUpdateWidget(covariant ProjectAnalyticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key == widget.account.key &&
        oldWidget.project.id == widget.project.id &&
        oldWidget.project.path == widget.project.path &&
        identical(oldWidget.api, widget.api)) {
      return;
    }
    _generation++;
    _activeRef = widget.project.defaultBranch ?? '';
    _activeDays = _draftDays = 30;
    _activeSource = _draftSource = AnalyticsPipelineSource.any;
    final window = _newWindow(_activeDays);
    _from = window.$1;
    _to = window.$2;
    _ref.text = _activeRef;
    _clear();
    _tabs.index = 0;
    unawaited(_ensureLoaded());
  }

  @override
  void dispose() {
    _generation++;
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    _ref.dispose();
    super.dispose();
  }

  void _tabChanged() {
    if (_tabs.indexIsChanging) return;
    setState(() {});
    unawaited(_ensureLoaded());
  }

  _Owner get _owner => _Owner(
    _generation,
    widget.account.key,
    widget.api,
    widget.project,
    _activeRef,
    _activeDays,
    _activeSource,
    _from,
    _to,
  );
  bool _currentContributor(_Owner owner) =>
      _currentProject(owner.projectOwner) && owner.ref == _activeRef;
  bool _currentRepository(_Owner owner) =>
      _currentProject(owner.projectOwner) &&
      owner.ref == _activeRef &&
      owner.from == _from &&
      owner.to == _to;
  bool _currentPipeline(_Owner owner) =>
      _currentRepository(owner) && owner.source == _activeSource;

  _ProjectOwner get _projectOwner => _ProjectOwner(
    _generation,
    widget.account.key,
    widget.api,
    widget.project,
  );
  bool _currentProject(_ProjectOwner owner) =>
      mounted &&
      owner.generation == _generation &&
      owner.accountKey == widget.account.key &&
      identical(owner.api, widget.api) &&
      owner.projectId == widget.project.id &&
      owner.projectPath == widget.project.path;

  void _clear() {
    _contributors = null;
    _contributorError = null;
    _nextContributors = null;
    _contributorPages = 0;
    _contributorLoading = false;
    _contributorLimited = false;
    _commits = null;
    _nextCommits = null;
    _commitError = null;
    _moreError = null;
    _commitLoading = false;
    _commitPages = 0;
    _dayRows = const [];
    _dayMax = 1;
    _pipelines = null;
    _pipelineError = null;
    _ciLoading = false;
    _coverage = null;
    _coverageLoaded = false;
    _coverageLoading = false;
    _coverageError = null;
    _languages = null;
    _languageLoading = false;
    _languageError = null;
  }

  (DateTime, DateTime) _newWindow(int days) {
    final now = DateTime.now().toUtc();
    final to = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    return (to.subtract(Duration(days: days)), to);
  }

  Future<void> _apply() async {
    final ref = _ref.text.trim();
    if (ref.isEmpty && _tabs.index != 0) {
      showFailure(
        context,
        const ApiFailure(
          FailureKind.validation,
          detail: '儲存庫與 CI 分析需要明確的 ref。',
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    if (ref == _activeRef &&
        _draftDays == _activeDays &&
        _draftSource == _activeSource) {
      return;
    }
    final refChanged = ref != _activeRef;
    final windowChanged = _draftDays != _activeDays;
    final sourceChanged = _draftSource != _activeSource;
    final window = refChanged || windowChanged
        ? _newWindow(_draftDays)
        : (_from, _to);
    setState(() {
      _activeRef = ref;
      _activeDays = _draftDays;
      _activeSource = _draftSource;
      _from = window.$1;
      _to = window.$2;
      if (refChanged) {
        _contributors = null;
        _contributorError = null;
        _nextContributors = null;
        _contributorPages = 0;
        _contributorLoading = false;
        _contributorLimited = false;
      }
      if (refChanged || windowChanged) {
        _commits = null;
        _nextCommits = null;
        _commitError = null;
        _moreError = null;
        _commitLoading = false;
        _commitPages = 0;
        _dayRows = const [];
        _dayMax = 1;
      }
      if (refChanged || windowChanged || sourceChanged) {
        _pipelines = null;
        _pipelineError = null;
        _ciLoading = false;
      }
    });
    await _ensureLoaded();
  }

  Future<void> _refresh() async {
    final tab = _tabs.index;
    final window = tab == 0 ? (_from, _to) : _newWindow(_activeDays);
    final windowMoved = window.$1 != _from || window.$2 != _to;
    setState(() {
      _from = window.$1;
      _to = window.$2;
      if (windowMoved) {
        _commits = null;
        _nextCommits = null;
        _commitError = null;
        _moreError = null;
        _commitLoading = false;
        _commitPages = 0;
        _dayRows = const [];
        _dayMax = 1;
        _pipelines = null;
        _pipelineError = null;
        _ciLoading = false;
      }
      switch (tab) {
        case 0:
          _contributors = null;
          _contributorError = null;
          _nextContributors = null;
          _contributorPages = 0;
          _contributorLoading = false;
          _contributorLimited = false;
        case 1:
          if (!windowMoved) {
            _commits = null;
            _nextCommits = null;
            _commitError = null;
            _moreError = null;
            _commitLoading = false;
            _commitPages = 0;
            _dayRows = const [];
            _dayMax = 1;
          }
          _coverage = null;
          _coverageLoaded = false;
          _coverageLoading = false;
          _coverageError = null;
          _languages = null;
          _languageLoading = false;
          _languageError = null;
        case 2:
          if (!windowMoved) {
            _pipelines = null;
            _pipelineError = null;
            _ciLoading = false;
          }
      }
    });
    await _ensureLoaded();
  }

  Future<void> _ensureLoaded() => switch (_tabs.index) {
    0
        when _contributors == null &&
            _contributorError == null &&
            !_contributorLoading =>
      _loadContributors(),
    1 => _loadRepository(),
    2
        when _activeRef.isNotEmpty &&
            _pipelines == null &&
            _pipelineError == null &&
            !_ciLoading =>
      _loadPipeline(),
    _ => Future.value(),
  };

  Future<void> _loadRepository() async {
    final tasks = <Future<void>>[];
    if (_activeRef.isNotEmpty &&
        _commits == null &&
        _commitError == null &&
        !_commitLoading) {
      tasks.add(_loadCommits(reset: true));
    }
    if (!_coverageLoaded && _coverageError == null && !_coverageLoading) {
      tasks.add(_loadCoverage());
    }
    if (_languages == null && _languageError == null && !_languageLoading) {
      tasks.add(_loadLanguages());
    }
    await Future.wait(tasks);
  }

  Future<void> _loadContributors({bool reset = true}) async {
    if (_contributorLoading) return;
    final owner = _owner;
    final request = ++_contributorRequest;
    final before = reset
        ? const <ContributorSummary>[]
        : (_contributors ?? const []);
    final next = reset ? null : _nextContributors;
    if (!reset && next == null) return;
    setState(() {
      _contributorLoading = true;
      _contributorError = null;
      if (reset) {
        _contributors = null;
        _nextContributors = null;
        _contributorPages = 0;
        _contributorLimited = false;
      }
    });
    try {
      final page = await owner.api.repositoryContributors(
        owner.project,
        ref: owner.ref.isEmpty ? null : owner.ref,
        next: next,
      );
      if (!_currentContributor(owner) || request != _contributorRequest) return;
      final rows = <ContributorSummary>[
        ...before,
        ...page.items.take(_rowLimit - before.length),
      ];
      final pages = (reset ? 0 : _contributorPages) + 1;
      final limited = rows.length >= _rowLimit || pages >= _pageLimit;
      setState(() {
        _contributors = List.unmodifiable(rows);
        _nextContributors = limited ? null : page.next;
        _contributorPages = pages;
        _contributorLimited = limited && page.next != null;
      });
    } catch (error) {
      if (_currentContributor(owner) && request == _contributorRequest) {
        setState(() => _contributorError = safeFailure(error));
      }
    } finally {
      if (_currentContributor(owner) && request == _contributorRequest) {
        setState(() => _contributorLoading = false);
      }
    }
  }

  Future<void> _loadCommits({required bool reset}) async {
    if (_commitLoading) return;
    final owner = _owner;
    final request = ++_commitRequest;
    final before = reset
        ? const <RepositoryActivityCommit>[]
        : (_commits ?? const []);
    final next = reset ? null : _nextCommits;
    if (!reset && next == null) return;
    setState(() {
      _commitLoading = true;
      if (reset) {
        _commits = null;
        _nextCommits = null;
        _commitError = null;
        _moreError = null;
        _commitPages = 0;
        _dayRows = const [];
        _dayMax = 1;
      } else {
        _moreError = null;
      }
    });
    try {
      final page = await owner.api.repositoryActivity(
        owner.project,
        ref: owner.ref,
        from: owner.from,
        to: owner.to,
        next: next,
      );
      if (!_currentRepository(owner) || request != _commitRequest) return;
      final combined = <RepositoryActivityCommit>[
        ...before,
        ...page.items.take(_rowLimit - before.length),
      ];
      final pages = (reset ? 0 : _commitPages) + 1;
      final limited = combined.length >= _rowLimit || pages >= _pageLimit;
      final aggregated = _aggregate(combined);
      final rows = aggregated.entries.toList()
        ..sort((a, b) => b.key.compareTo(a.key));
      final maxCount = rows.fold<int>(
        1,
        (max, row) => row.value.commits > max ? row.value.commits : max,
      );
      setState(() {
        _commits = List.unmodifiable(combined);
        _nextCommits = limited ? null : page.next;
        _commitPages = pages;
        _dayRows = List.unmodifiable(rows);
        _dayMax = maxCount;
      });
    } catch (error) {
      if (_currentRepository(owner) && request == _commitRequest) {
        setState(() {
          if (reset) {
            _commitError = safeFailure(error);
          } else {
            _moreError = safeFailure(error);
          }
        });
      }
    } finally {
      if (_currentRepository(owner) && request == _commitRequest) {
        setState(() => _commitLoading = false);
      }
    }
  }

  Map<DateTime, _ActivityDay> _aggregate(
    List<RepositoryActivityCommit> commits,
  ) {
    final result = <DateTime, _ActivityDay>{};
    for (final commit in commits) {
      if (commit.parentCount > 1) continue;
      final local = commit.committedAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      result[day] = (result[day] ?? const _ActivityDay()).add(commit);
    }
    return Map.unmodifiable(result);
  }

  Future<void> _loadPipeline() async {
    final owner = _owner;
    final request = ++_pipelineRequest;
    setState(() {
      _ciLoading = true;
      _pipelineError = null;
    });
    try {
      final value = await owner.api.pipelineAnalytics(
        owner.project,
        ref: owner.ref,
        from: owner.from,
        to: owner.to,
        source: owner.source,
      );
      if (_currentPipeline(owner) && request == _pipelineRequest) {
        setState(() => _pipelines = value);
      }
    } catch (error) {
      if (_currentPipeline(owner) && request == _pipelineRequest) {
        setState(() => _pipelineError = safeFailure(error));
      }
    } finally {
      if (_currentPipeline(owner) && request == _pipelineRequest) {
        setState(() => _ciLoading = false);
      }
    }
  }

  Future<void> _loadCoverage() async {
    if (_coverageLoading) return;
    final owner = _projectOwner;
    final request = ++_coverageRequest;
    setState(() {
      _coverageLoading = true;
      _coverageLoaded = false;
      _coverageError = null;
    });
    try {
      final value = await owner.api.codeCoverageSummary(owner.project);
      if (_currentProject(owner) && request == _coverageRequest) {
        setState(() {
          _coverage = value;
          _coverageLoaded = true;
        });
      }
    } catch (error) {
      if (_currentProject(owner) && request == _coverageRequest) {
        setState(() {
          _coverageLoaded = true;
          _coverageError = safeFailure(error);
        });
      }
    } finally {
      if (_currentProject(owner) && request == _coverageRequest) {
        setState(() => _coverageLoading = false);
      }
    }
  }

  Future<void> _loadLanguages() async {
    if (_languageLoading) return;
    final owner = _projectOwner;
    final request = ++_languageRequest;
    setState(() {
      _languageLoading = true;
      _languageError = null;
    });
    try {
      final value = await owner.api.languages(owner.project.id);
      if (_currentProject(owner) && request == _languageRequest) {
        setState(() => _languages = value);
      }
    } catch (error) {
      if (_currentProject(owner) && request == _languageRequest) {
        setState(() => _languageError = safeFailure(error));
      }
    } finally {
      if (_currentProject(owner) && request == _languageRequest) {
        setState(() => _languageLoading = false);
      }
    }
  }

  Widget _controls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('analytics-ref'),
            controller: _ref,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Ref / 分支',
              prefixIcon: Icon(Icons.alt_route),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => unawaited(_apply()),
          ),
          const SizedBox(height: 8),
          if (_tabs.index == 2) ...[
            DropdownButtonFormField<AnalyticsPipelineSource>(
              key: const ValueKey('analytics-source'),
              initialValue: _draftSource,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Pipeline 來源'),
              items: [
                for (final source in AnalyticsPipelineSource.values)
                  DropdownMenuItem(
                    value: source,
                    child: Text(
                      _sourceLabel(source),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _draftSource = value);
              },
            ),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_tabs.index != 0)
                for (final days in _ranges)
                  ChoiceChip(
                    key: ValueKey('analytics-range-$days'),
                    label: Text('$days 天'),
                    selected: _draftDays == days,
                    onSelected: (_) => setState(() => _draftDays = days),
                  ),
              FilledButton.icon(
                key: const ValueKey('analytics-apply'),
                onPressed: _apply,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('套用'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _tabs.index == 0
                ? '目前：${_activeRef.isEmpty ? '伺服器預設 ref' : _activeRef} · 所有歷史'
                : '目前：${_activeRef.isEmpty ? '尚未選擇 ref' : _activeRef} · ${_date(_from)}（含）至 ${_date(_to)}（不含） · UTC${_tabs.index == 2 ? ' · ${_sourceLabel(_activeSource)}' : ''}',
            key: const ValueKey('analytics-active-window'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _contributorsTab() {
    if (_contributorLoading && _contributors == null) {
      return const ListSkeleton();
    }
    if (_contributorError != null && _contributors == null) {
      return FailureNotice(
        _contributorError!,
        account: widget.account,
        resourceLabel: '${widget.project.path} · 貢獻者',
        onRetry: _loadContributors,
        onSwitchAccount: endSessionFrom(context),
      );
    }
    final rows = _contributors ?? const <ContributorSummary>[];
    final headerCount =
        2 +
        (_contributorLimited ? 1 : 0) +
        (_contributorError != null ? 1 : 0) +
        (rows.isEmpty ? 1 : 0);
    return CustomScrollView(
      key: const PageStorageKey('analytics-contributors'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverList.builder(
            itemCount: headerCount,
            itemBuilder: (context, index) {
              var cursor = 0;
              if (index == cursor++) {
                return const Text(
                  '所選 ref 的所有歷史貢獻者；日期範圍不適用。相同顯示名稱不代表同一 GitLab 使用者。',
                );
              }
              if (index == cursor++) {
                return Text(
                  '已載入 ${rows.length} / $_rowLimit 位 · $_contributorPages / $_pageLimit 頁${_nextContributors != null ? ' · 尚有更多' : ''}',
                  key: const ValueKey('contributors-loaded-window'),
                );
              }
              if (_contributorLimited && index == cursor++) {
                return const _Notice('已達 2,000 位／20 頁載入上限。');
              }
              if (_contributorError != null && index == cursor++) {
                return FailureNotice(
                  _contributorError!,
                  account: widget.account,
                  resourceLabel: '${widget.project.path} · 貢獻者後續頁面',
                  onRetry: () => _loadContributors(reset: false),
                  onSwitchAccount: endSessionFrom(context),
                );
              }
              return const _Empty(Icons.group_outlined, '沒有貢獻者資料');
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              return Card(
                key: ValueKey('contributor-$index'),
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(row.displayName),
                  subtitle: Text(
                    '${row.commits} commits · +${row.additions} / -${row.deletions}',
                  ),
                ),
              );
            },
          ),
        ),
        if (_nextContributors != null && !_contributorLimited)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverToBoxAdapter(
              child: OutlinedButton.icon(
                key: const ValueKey('contributors-load-more'),
                onPressed: _contributorLoading
                    ? null
                    : () => _loadContributors(reset: false),
                icon: _contributorLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more),
                label: const Text('載入更多'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _repositoryTab() {
    final commits = _commits ?? const <RepositoryActivityCommit>[];
    final days = _dayRows;
    final limited = commits.length >= _rowLimit || _commitPages >= _pageLimit;
    Widget? activityLead;
    if (_activeRef.isEmpty) {
      activityLead = const _Empty(Icons.alt_route, '請輸入 ref 後套用，再讀取儲存庫活動。');
    } else if (_commitLoading && _commits == null) {
      activityLead = const ListSkeleton();
    } else if (_commitError != null && _commits == null) {
      activityLead = FailureNotice(
        _commitError!,
        account: widget.account,
        resourceLabel: '${widget.project.path} · 儲存庫活動',
        onRetry: () => _loadCommits(reset: true),
        onSwitchAccount: endSessionFrom(context),
      );
    }
    final hasActivityData = _activeRef.isNotEmpty && activityLead == null;
    final footerCount =
        (_moreError != null ? 1 : 0) +
        (hasActivityData && days.isEmpty ? 1 : 0) +
        (_nextCommits != null && !limited ? 1 : 0);
    return CustomScrollView(
      key: const PageStorageKey('analytics-repository'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverList.list(
            children: [
              ?activityLead,
              if (hasActivityData) ...[
                Text(
                  '已載入 ${commits.length} / $_rowLimit 筆 · $_commitPages / $_pageLimit 頁${limited
                      ? ' · 已達上限'
                      : _nextCommits != null
                      ? ' · 尚有更多'
                      : ''}',
                  key: const ValueKey('repository-loaded-window'),
                ),
                const Text('依裝置本地日期聚合；合併提交（超過一個 parent）不列入圖表。'),
              ],
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.builder(
            itemCount: days.length,
            itemBuilder: (context, index) {
              final row = days[index];
              return Card(
                key: ValueKey('activity-${_date(row.key)}'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SizedBox(width: 92, child: Text(_date(row.key))),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: row.value.commits / _dayMax,
                              minHeight: 8,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text('${row.value.commits}'),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${row.value.additionsComplete ? '+${row.value.additions}' : '+—'} / ${row.value.deletionsComplete ? '-${row.value.deletions}' : '-—'}',
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverList.builder(
            itemCount: footerCount,
            itemBuilder: (context, index) {
              var cursor = 0;
              if (_moreError != null && index == cursor++) {
                return FailureNotice(
                  _moreError!,
                  account: widget.account,
                  resourceLabel: '${widget.project.path} · 儲存庫活動後續頁面',
                  onRetry: () => _loadCommits(reset: false),
                  onSwitchAccount: endSessionFrom(context),
                );
              }
              if (hasActivityData && days.isEmpty && index == cursor++) {
                return const _Empty(Icons.insights_outlined, '這段期間沒有非合併提交');
              }
              return OutlinedButton.icon(
                key: const ValueKey('repository-load-more'),
                onPressed: _commitLoading
                    ? null
                    : () => _loadCommits(reset: false),
                icon: _commitLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more),
                label: const Text('載入更多'),
              );
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          sliver: SliverList.list(
            children: [_coverageCard(), _languagesCard()],
          ),
        ),
      ],
    );
  }

  Widget _ciTab() {
    if (_activeRef.isEmpty) {
      return const _Empty(Icons.alt_route, '請輸入 ref 後套用，再讀取 CI 分析。');
    }
    final buckets = _pipelines?.buckets ?? const <PipelineAnalyticsBucket>[];
    Widget? lead;
    if (_ciLoading && _pipelines == null && _pipelineError == null) {
      lead = const ListSkeleton();
    }
    if (_pipelineError != null) {
      lead = FailureNotice(
        _pipelineError!,
        account: widget.account,
        resourceLabel: '${widget.project.path} · CI/CD 分析',
        onRetry: _loadPipeline,
        onSwitchAccount: endSessionFrom(context),
      );
    }
    if (!_ciLoading && _pipelines != null && buckets.isEmpty) {
      lead = const _Empty(Icons.query_stats, '這段期間沒有 Pipeline 分析資料');
    }
    final headerCount = (lead == null ? 0 : 1) + (buckets.isEmpty ? 0 : 1);
    return CustomScrollView(
      key: const PageStorageKey('analytics-ci'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverList.builder(
            itemCount: headerCount,
            itemBuilder: (context, index) {
              if (lead != null && index == 0) return lead;
              return _summary(_pipelines!);
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.builder(
            itemCount: buckets.length,
            itemBuilder: (context, index) => _bucket(index, buckets[index]),
          ),
        ),
      ],
    );
  }

  Widget _summary(PipelineAnalyticsSnapshot snapshot) {
    final aggregate = snapshot.aggregate;
    final buckets = snapshot.buckets;
    final exact = aggregate != null
        ? aggregate.successful != null && aggregate.failed != null
        : buckets.every((b) => b.successful != null && b.failed != null);
    final success = aggregate != null
        ? aggregate.successful
        : exact
        ? buckets.fold<BigInt>(BigInt.zero, (sum, b) => sum + b.successful!)
        : null;
    final failed = aggregate != null
        ? aggregate.failed
        : exact
        ? buckets.fold<BigInt>(BigInt.zero, (sum, b) => sum + b.failed!)
        : null;
    final denominator = success == null || failed == null
        ? null
        : success + failed;
    final ratio = denominator == null || denominator == BigInt.zero
        ? null
        : success!.toDouble() / denominator.toDouble() * 100;
    return Card(
      key: const ValueKey('pipeline-summary'),
      child: ListTile(
        leading: const Icon(Icons.query_stats),
        title: Text(
          '成功率${aggregate?.total == null ? '' : ' · 全部 ${aggregate!.total}'}',
        ),
        subtitle: Text(
          !exact
              ? '計數未完整，無法計算'
              : ratio == null
              ? '沒有 success / failed 可計算資料'
              : '${ratio.toStringAsFixed(1)}% · 僅 success / (success + failed)${aggregate == null ? '' : ' · 整體 p50 ${_seconds(aggregate.p50Seconds)} · p95 ${_seconds(aggregate.p95Seconds)}'}',
        ),
      ),
    );
  }

  Widget _bucket(int index, PipelineAnalyticsBucket bucket) => Card(
    key: ValueKey('pipeline-bucket-$index'),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            bucket.label == null ? '日期未提供' : _date(bucket.label!),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              MetaChip('全部 ${_count(bucket.total)}'),
              MetaChip('成功 ${_count(bucket.successful)}'),
              MetaChip('失敗 ${_count(bucket.failed)}'),
              MetaChip('其他 ${_count(bucket.other)}'),
              MetaChip('p50 ${_seconds(bucket.p50Seconds)}'),
              MetaChip('p95 ${_seconds(bucket.p95Seconds)}'),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _coverageCard() {
    if (!_coverageLoaded && _coverageError == null) {
      return const Card(
        child: ListTile(
          title: Text('覆蓋率'),
          trailing: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_coverageError != null) {
      return FailureNotice(
        _coverageError!,
        account: widget.account,
        resourceLabel: '${widget.project.path} · 覆蓋率',
        onRetry: _loadCoverage,
        onSwitchAccount: endSessionFrom(context),
      );
    }
    final value = _coverage;
    return Card(
      key: const ValueKey('coverage-summary'),
      child: ListTile(
        leading: const Icon(Icons.fact_check_outlined),
        title: const Text('覆蓋率'),
        subtitle: Text(
          value == null
              ? '沒有覆蓋率摘要'
              : '${value.averageCoverage == null ? '平均 —' : '平均 ${value.averageCoverage!.toStringAsFixed(1)}%'} · 樣本 ${_count(value.coverageCount)}${value.lastUpdatedOn == null ? '' : ' · ${_date(value.lastUpdatedOn!)}'}',
        ),
      ),
    );
  }

  Widget _languagesCard() {
    if (_languages == null && _languageError == null) {
      return const Card(
        child: ListTile(
          title: Text('語言'),
          trailing: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_languageError != null) {
      return FailureNotice(
        _languageError!,
        account: widget.account,
        resourceLabel: '${widget.project.path} · 語言',
        onRetry: _loadLanguages,
        onSwitchAccount: endSessionFrom(context),
      );
    }
    final rows = _languages ?? const <(String, double)>[];
    return Card(
      key: const ValueKey('analytics-languages'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('語言', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              const Text('沒有語言資料')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (name, share) in rows)
                    MetaChip('$name ${share.toStringAsFixed(1)}%'),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final crowded = MediaQuery.textScalerOf(context).scale(14) > 18;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight = scaler.scale(20) * 1.25;
    final pathHeight = scaler.scale(12) * 1.25;
    final toolbarHeight = (titleHeight + pathHeight + 16).clamp(
      kToolbarHeight,
      104.0,
    );
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final safePadding = MediaQuery.paddingOf(context);
    final usableHeight =
        viewportHeight -
        MediaQuery.viewInsetsOf(context).bottom -
        safePadding.vertical;
    final compactControls = keyboardOpen || viewportHeight < 720;
    final controlsHeight = keyboardOpen
        ? (usableHeight - toolbarHeight - 56).clamp(0.0, 320.0)
        : (usableHeight * .45).clamp(160.0, 340.0);
    return Scaffold(
      body: StatusBarInset(
        child: gestureSafe(
          Column(
            children: [
              AppBar(
                primary: false,
                toolbarHeight: toolbarHeight,
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '專案分析',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.project.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                actions: [
                  IconButton(
                    key: const ValueKey('analytics-refresh'),
                    tooltip: '重新整理',
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              if (compactControls)
                SizedBox(
                  height: controlsHeight,
                  child: SingleChildScrollView(
                    key: ValueKey(
                      keyboardOpen
                          ? 'analytics-keyboard-controls'
                          : 'analytics-compact-controls',
                    ),
                    child: _controls(context),
                  ),
                )
              else
                _controls(context),
              TabBar(
                controller: _tabs,
                isScrollable: crowded,
                tabAlignment: crowded ? TabAlignment.start : null,
                tabs: const [
                  Tab(text: '貢獻者'),
                  Tab(text: '儲存庫'),
                  Tab(text: 'CI'),
                ],
              ),
              if (!keyboardOpen)
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [_contributorsTab(), _repositoryTab(), _ciTab()],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _Owner {
  const _Owner(
    this.generation,
    this.accountKey,
    this.api,
    this.project,
    this.ref,
    this.days,
    this.source,
    this.from,
    this.to,
  );
  final int generation, days;
  final String accountKey, ref;
  final AnalyticsPipelineSource source;
  final GitLabApi api;
  final Project project;
  final DateTime from, to;
  int get projectId => project.id;
  String get projectPath => project.path;
  _ProjectOwner get projectOwner =>
      _ProjectOwner(generation, accountKey, api, project);
}

final class _ProjectOwner {
  const _ProjectOwner(this.generation, this.accountKey, this.api, this.project);
  final int generation;
  final String accountKey;
  final GitLabApi api;
  final Project project;
  int get projectId => project.id;
  String get projectPath => project.path;
}

final class _ActivityDay {
  const _ActivityDay({
    this.commits = 0,
    this.additions = 0,
    this.deletions = 0,
    this.additionsComplete = true,
    this.deletionsComplete = true,
  });
  final int commits;
  final int additions, deletions;
  final bool additionsComplete, deletionsComplete;
  _ActivityDay add(RepositoryActivityCommit commit) => _ActivityDay(
    commits: commits + 1,
    additions: additions + (commit.additions ?? 0),
    deletions: deletions + (commit.deletions ?? 0),
    additionsComplete: additionsComplete && commit.additions != null,
    deletionsComplete: deletionsComplete && commit.deletions != null,
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(
      children: [Icon(icon, size: 36), const SizedBox(height: 8), Text(text)],
    ),
  );
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
String _count(BigInt? value) => value?.toString() ?? '—';
String _seconds(double? value) {
  if (value == null) return '—';
  final text = value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value
            .toStringAsFixed(2)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
  return '$text 秒';
}

String _sourceLabel(AnalyticsPipelineSource source) => switch (source) {
  AnalyticsPipelineSource.any => '所有來源',
  AnalyticsPipelineSource.unknown => '未知',
  AnalyticsPipelineSource.push => 'Push',
  AnalyticsPipelineSource.web => 'Web',
  AnalyticsPipelineSource.trigger => 'Trigger',
  AnalyticsPipelineSource.schedule => 'Schedule',
  AnalyticsPipelineSource.api => 'API',
  AnalyticsPipelineSource.external => 'External',
  AnalyticsPipelineSource.pipeline => 'Pipeline',
  AnalyticsPipelineSource.chat => 'Chat',
  AnalyticsPipelineSource.webIde => 'Web IDE',
  AnalyticsPipelineSource.mergeRequestEvent => 'Merge request',
  AnalyticsPipelineSource.externalPullRequestEvent => 'External pull request',
  AnalyticsPipelineSource.parentPipeline => 'Parent pipeline',
  AnalyticsPipelineSource.onDemandDastScan => 'On-demand DAST scan',
  AnalyticsPipelineSource.onDemandDastValidation => 'On-demand DAST validation',
  AnalyticsPipelineSource.securityOrchestrationPolicy => 'Security policy',
  AnalyticsPipelineSource.containerRegistryPush => 'Container registry push',
  AnalyticsPipelineSource.duoWorkflow => 'Duo workflow',
  AnalyticsPipelineSource.pipelineExecutionPolicySchedule =>
    'Pipeline policy schedule',
  AnalyticsPipelineSource.dependencyManagementSecurityUpdate =>
    'Dependency security update',
};
