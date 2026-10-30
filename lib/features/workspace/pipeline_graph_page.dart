import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/pipeline_graph.dart';
import '../../shared/workspace_ui.dart';
import '../../shared/resource_share.dart';
import 'ci_page.dart';

import '../../l10n/l10n.dart';
class PipelineGraphPage extends StatefulWidget {
  const PipelineGraphPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.pipelineId,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final int pipelineId;

  @override
  State<PipelineGraphPage> createState() => _PipelineGraphPageState();
}

class _PipelineGraphPageState extends State<PipelineGraphPage> {
  static const int _maxJobs = 300;

  final _scroll = ScrollController();
  final _rowKeys = <String, GlobalKey>{};
  final _jobs = <PipelineGraphJob>[];
  final _jobIds = <String>{};
  List<String> _stageNames = const [];
  bool _stagesTruncated = false;
  bool _hasNextPage = false;
  String? _endCursor;
  int? _iid;
  int _epoch = 0;
  bool _loading = false;
  ApiFailure? _error;
  ApiFailure? _pageError;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant PipelineGraphPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.api, widget.api) &&
        oldWidget.account.key == widget.account.key &&
        oldWidget.project.id == widget.project.id &&
        oldWidget.pipelineId == widget.pipelineId) {
      return;
    }
    _epoch++;
    _jobs.clear();
    _jobIds.clear();
    _rowKeys.clear();
    _stageNames = const [];
    _stagesTruncated = false;
    _hasNextPage = false;
    _endCursor = null;
    _iid = null;
    _loading = false;
    _error = null;
    _pageError = null;
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _epoch++;
    _scroll.dispose();
    super.dispose();
  }

  bool _requestIsCurrent({
    required int epoch,
    required GitLabApi api,
    required String accountKey,
    required int projectId,
    required int pipelineId,
  }) =>
      mounted &&
      epoch == _epoch &&
      identical(api, widget.api) &&
      accountKey == widget.account.key &&
      projectId == widget.project.id &&
      pipelineId == widget.pipelineId;

  Future<void> _refresh() async {
    if (_loading) return;
    final epoch = ++_epoch;
    _jobs.clear();
    _jobIds.clear();
    _rowKeys.clear();
    _stageNames = const [];
    _stagesTruncated = false;
    _hasNextPage = false;
    _endCursor = null;
    _iid = null;
    await _load(after: null, epoch: epoch, initial: true);
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasNextPage || _jobs.length >= _maxJobs) return;
    final cursor = _endCursor;
    if (cursor == null) return;
    await _load(after: cursor, epoch: _epoch, initial: false);
  }

  Future<void> _load({
    required String? after,
    required int epoch,
    required bool initial,
  }) async {
    final api = widget.api;
    final accountKey = widget.account.key;
    final project = widget.project;
    final pipelineId = widget.pipelineId;
    setState(() {
      _loading = true;
      if (initial) {
        _error = null;
      } else {
        _pageError = null;
      }
    });
    try {
      final raw = await api.pipelineGraphPage(
        project,
        pipelineId,
        after: after,
      );
      final page = PipelineGraphPageData.fromJson(raw);
      if (page.pipelineId != pipelineId) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (!_requestIsCurrent(
        epoch: epoch,
        api: api,
        accountKey: accountKey,
        projectId: project.id,
        pipelineId: pipelineId,
      )) {
        return;
      }
      if (!initial && _iid != page.iid) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (page.hasNextPage && page.endCursor == after) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      final room = _maxJobs - _jobs.length;
      for (final job in page.jobs.take(room)) {
        if (_jobIds.add(job.id)) _jobs.add(job);
      }
      setState(() {
        _iid ??= page.iid;
        if (initial) {
          _stageNames = page.stageNames;
          _stagesTruncated = page.stagesTruncated;
        }
        _hasNextPage = page.hasNextPage && _jobs.length < _maxJobs;
        _endCursor = _hasNextPage ? page.endCursor : null;
        _error = null;
        _pageError = null;
      });
    } catch (error) {
      if (!_requestIsCurrent(
        epoch: epoch,
        api: api,
        accountKey: accountKey,
        projectId: project.id,
        pipelineId: pipelineId,
      )) {
        return;
      }
      setState(() {
        if (initial) {
          _error = safeFailure(error);
        } else {
          _pageError = safeFailure(error);
        }
      });
    } finally {
      if (_requestIsCurrent(
        epoch: epoch,
        api: api,
        accountKey: accountKey,
        projectId: project.id,
        pipelineId: pipelineId,
      )) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _jumpTo(PipelineGraphJob job) async {
    final key = _rowKeys.putIfAbsent(job.id, GlobalKey.new);
    var target = key.currentContext;
    if (target == null && _scroll.hasClients) {
      final index = _jobs.indexWhere((value) => value.id == job.id);
      if (index < 0) return;
      final fraction = _jobs.length <= 1 ? 0.0 : index / (_jobs.length - 1);
      await _scroll.animateTo(
        _scroll.position.maxScrollExtent * fraction,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      target = key.currentContext;
    }
    if (!mounted) return;
    target = key.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        alignment: .16,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _openJob(PipelineGraphJob job) {
    final id = job.numericId;
    if (!job.canOpen || id == null) return;
    unawaited(
      Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => JobLogPage(
            account: widget.account,
            api: widget.api,
            project: widget.project,
            id: id,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _iid == null
        ? l10n.pipelineDependencyGraph(widget.pipelineId)
        : l10n.pipelineIidDependencyGraph(_iid);
    final theme = Theme.of(context);
    final titleStyle = theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge!;
    final subtitleStyle = theme.textTheme.bodySmall!;
    final scaler = MediaQuery.textScalerOf(context);
    final toolbarHeight = math.max(
      kToolbarHeight,
      scaler.scale(titleStyle.fontSize ?? 22) * (titleStyle.height ?? 1.2) +
          scaler.scale(subtitleStyle.fontSize ?? 12) * (subtitleStyle.height ?? 1.2) + 8,
    );
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: toolbarHeight,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              widget.project.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
            ),
          ],
        ),
        actions: [
          ResourceShareButton(
            uri: widget.account.instance.projectWeb('${widget.project.path}/-/pipelines/${widget.pipelineId}'),
            ownerKey: (widget.account.key, widget.api, widget.project.id, widget.pipelineId),
            isCurrent: () => mounted && !widget.api.isClosed),
          IconButton(
            tooltip: l10n.refreshDependencyGraph,
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: gestureSafe(Column(
        children: [
          if (_loading && _jobs.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody()),
        ],
      )),
    );
  }

  Widget _buildBody() {
    if (_jobs.isEmpty && _loading) return const ListSkeleton();
    if (_jobs.isEmpty && _error != null) {
      return SingleChildScrollView(
        child: FailureNotice(
          _error!,
          account: widget.account,
          resourceLabel:
              l10n.pathPipelineDependencyGraph(widget.project.path, widget.pipelineId),
          onRetry: _refresh,
          onSwitchAccount: endSessionFrom(context),
        ),
      );
    }
    if (_jobs.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: 80),
            EmptyState(l10n.pipelineHasNoJobs, icon: Icons.account_tree_outlined),
          ],
        ),
      );
    }
    final resolved = resolvePipelineGraphNeeds(_jobs);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _jobs.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) return _header();
          if (index == _jobs.length + 1) return _footer();
          final job = _jobs[index - 1];
          return _JobGraphRow(
            key: _rowKeys.putIfAbsent(job.id, GlobalKey.new),
            job: job,
            needs: resolved[job.id] ?? const <PipelineGraphNeed>[],
            onOpen: job.canOpen ? () => _openJob(job) : null,
            onNeed: (need) {
              final target = need.target;
              if (target != null) unawaited(_jumpTo(target));
            },
          );
        },
      ),
    );
  }

  Widget _header() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.jobDependencies,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(l10n.needsNotStageOrder),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final stage in _stageNames)
                Chip(
                  avatar: const Icon(Icons.layers_outlined, size: 16),
                  label: Text(stage),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (_stagesTruncated)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(l10n.stageListTruncated),
            ),
          const SizedBox(height: 8),
          Text(l10n.jobsLoadedLimit(_jobs.length, _maxJobs)),
        ],
      ),
    );
  }

  Widget _footer() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_pageError != null)
          FailureNotice(
            _pageError!,
            account: widget.account,
            resourceLabel:
                l10n.pathPipelineMoreJobs(widget.project.path, widget.pipelineId),
            onRetry: _loadMore,
            onSwitchAccount: endSessionFrom(context),
          ),
        if (_hasNextPage)
          OutlinedButton.icon(
            key: const Key('pipeline-graph-load-more'),
            onPressed: _loading ? null : _loadMore,
            icon: const Icon(Icons.expand_more),
            label: Text(l10n.loadMoreJobs),
          )
        else if (_jobs.length >= _maxJobs)
          Text(l10n.jobDisplayLimitReached, textAlign: TextAlign.center),
      ],
    ),
  );
}

class _JobGraphRow extends StatelessWidget {
  const _JobGraphRow({
    super.key,
    required this.job,
    required this.needs,
    required this.onOpen,
    required this.onNeed,
  });

  final PipelineGraphJob job;
  final List<PipelineGraphNeed> needs;
  final VoidCallback? onOpen;
  final ValueChanged<PipelineGraphNeed> onNeed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 3),
                child: Icon(Icons.circle, size: 13),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  job.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(job.status.toLowerCase()),
              if (onOpen != null) const Icon(Icons.chevron_right),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              if (job.stageName case final stage?)
                MetaChip(stage, icon: Icons.layers_outlined),
              if (job.retried) MetaChip(l10n.previousRetry, icon: Icons.history),
              if (!job.canOpen)
                MetaChip(job.kind, icon: Icons.extension_outlined),
            ],
          ),
          const SizedBox(height: 8),
          if (job.waitsForStage)
            Text(l10n.waitingOnStageOrder)
          else if (job.canRunImmediately)
            Text(l10n.noDependenciesRunNow)
          else ...[
            Text(l10n.mustCompleteFirst, style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [for (final need in needs) _needChip(context, need)],
            ),
          ],
          if (job.needsTruncated)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(l10n.jobNeedsTruncated),
            ),
          if (!job.canOpen)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(l10n.notBuildJobLog),
            ),
        ],
      ),
    );
    return Semantics(
      container: true,
      button: onOpen != null,
      label:
          l10n.jobNameStatusStage(job.name, statusLabel(job.status.toLowerCase()), job.stageName ?? l10n.unknownLabel),
      child: Card(
        key: ValueKey('pipeline-job-${job.id}'),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        clipBehavior: Clip.antiAlias,
        child: onOpen == null
            ? content
            : InkWell(onTap: onOpen, child: content),
      ),
    );
  }

  Widget _needChip(BuildContext context, PipelineGraphNeed need) {
    final (icon, prefix, enabled) = switch (need.state) {
      PipelineGraphNeedState.resolved => (Icons.arrow_upward, '', true),
      PipelineGraphNeedState.unloaded => (Icons.help_outline, l10n.notLoadedYet, false),
      PipelineGraphNeedState.ambiguous => (
        Icons.warning_amber_outlined,
        l10n.duplicateName,
        false,
      ),
    };
    return ActionChip(
      key: ValueKey('pipeline-need-${job.id}-${need.name}'),
      avatar: Icon(icon, size: 16),
      label: Text('$prefix${need.name}'),
      tooltip: enabled ? l10n.jumpToLoadedName(need.name) : null,
      onPressed: enabled ? () => onNeed(need) : null,
      visualDensity: VisualDensity.compact,
    );
  }
}
