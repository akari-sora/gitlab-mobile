import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/external_link.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/resource_share.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import 'repository_page.dart';
import 'work_item_page.dart';
import 'ci_page.dart';
import 'project_more_page.dart';

class ProjectPage extends StatefulWidget {
  const ProjectPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.initialTab = 0,
    this.showBackButton = true,
    this.onBack,
    this.onDeleted,
    this.onTabChanged,
    this.onStarChanged,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int initialTab;
  final bool showBackButton;
  final VoidCallback? onBack;
  final VoidCallback? onDeleted;
  final ValueChanged<int>? onTabChanged;
  final Future<void> Function()? onStarChanged;
  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _chrome = ScrollChromeController();
  final _focus = DetailFocus();
  late Project _project;
  SessionController? _session;
  int? _sessionGeneration;
  bool _sessionAvailable = false,
      _starChecked = false,
      _starBusy = true,
      _starStarted = false;
  bool? _starred;
  int? _starCount;
  int _generation = 0, _starEpoch = 0, _starRevision = 0;
  @override
  void initState() {
    super.initState();
    _project = widget.project;
    _focus.addListener(_focusChanged);
    _tabs = TabController(
      length: 5,
      vsync: this,
      initialIndex: widget.initialTab,
    );
    _tabs.addListener(_tabChanged);
    if (widget.initialTab != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onTabChanged?.call(widget.initialTab);
      });
    }
  }

  void _bindSession() {
    try {
      final candidate = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(sessionProvider);
      _sessionAvailable = true;
      if (!identical(_session, candidate)) {
        _session?.removeListener(_sessionChanged);
        _session = candidate;
        candidate.addListener(_sessionChanged);
      }
      _sessionGeneration = candidate.generation;
    } on StateError {
      _sessionAvailable = false;
      _session = null;
      _sessionGeneration = null;
    }
  }

  bool _sessionCurrent() =>
      !_sessionAvailable ||
      (_session?.active?.key == widget.account.key &&
          identical(_session?.api, widget.api) &&
          _session?.generation == _sessionGeneration);
  ({String account, GitLabApi api, int project, int generation})
  get _starOwner => (
    account: widget.account.key,
    api: widget.api,
    project: widget.project.id,
    generation: _generation,
  );
  bool _currentStar(
    ({String account, GitLabApi api, int project, int generation}) owner,
  ) =>
      mounted &&
      owner.generation == _generation &&
      owner.account == widget.account.key &&
      identical(owner.api, widget.api) &&
      owner.project == widget.project.id &&
      !owner.api.isClosed &&
      _sessionCurrent();
  void _sessionChanged() {
    if (_sessionCurrent()) {
      return;
    }
    _generation++;
    _starEpoch++;
    if (mounted) {
      setState(() {
        _starred = null;
        _starCount = null;
        _starChecked = false;
        _starBusy = false;
      });
    }
  }

  Future<void> _loadStar({bool reportFailure = false}) async {
    final owner = _starOwner, epoch = ++_starEpoch;
    if (!_currentStar(owner)) {
      if (reportFailure) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      return;
    }
    setState(() => _starBusy = true);
    try {
      final starred = await owner.api.hasStarred(
        owner.project,
        widget.account.user.username,
      );
      if (!_currentStar(owner) || epoch != _starEpoch) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      setState(() {
        _starred = starred;
        _starChecked = true;
      });
    } catch (_) {
      if (_currentStar(owner) && epoch == _starEpoch) {
        setState(() {
          _starred = null;
          _starChecked = true;
        });
      }
      if (reportFailure) {
        if (!_currentStar(owner) || epoch != _starEpoch) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        rethrow;
      }
    } finally {
      if (_currentStar(owner) && epoch == _starEpoch) {
        setState(() => _starBusy = false);
      }
    }
  }

  Future<Json?> _setStar(bool starred) async {
    if (_starBusy) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    final owner = _starOwner, epoch = ++_starEpoch;
    if (!_currentStar(owner)) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    setState(() => _starBusy = true);
    try {
      final Json? updated;
      try {
        updated = await owner.api.setStar(owner.project, starred);
      } catch (_) {
        if (!_currentStar(owner) || epoch != _starEpoch) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        rethrow;
      }
      if (!_currentStar(owner) || epoch != _starEpoch) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      setState(() {
        _starred = starred;
        _starCount = updated?['star_count'] is int
            ? updated!['star_count'] as int
            : null;
        _starChecked = true;
        _starRevision++;
      });
      final refresh = widget.onStarChanged;
      if (refresh != null) {
        unawaited(refresh());
      }
      return updated;
    } finally {
      if (_currentStar(owner) && epoch == _starEpoch) {
        setState(() => _starBusy = false);
      }
    }
  }

  void _showStarFailure(Object error) {
    if (!mounted ||
        error is ApiFailure && error.kind == FailureKind.cancelled) {
      return;
    }
    showFailure(context, error);
  }

  Future<void> _retryStar() async {
    try {
      await _loadStar(reportFailure: true);
    } catch (error) {
      _showStarFailure(error);
    }
  }

  Future<void> _toggleStarFromHeader() async {
    final owner = _starOwner;
    final current = _starred;
    if (current == null) {
      await _retryStar();
      return;
    }
    final desired = !current;
    try {
      await _setStar(desired);
      if (!mounted || !_currentStar(owner)) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(desired ? '已加入星標' : '已移除星標')));
    } catch (error) {
      _showStarFailure(error);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindSession();
    if (!_starStarted && _sessionCurrent()) {
      _starStarted = true;
      unawaited(_loadStar());
    }
  }

  void _tabChanged() {
    if (mounted) {
      if (!_tabs.indexIsChanging) {
        widget.onTabChanged?.call(_tabs.index);
      }
      _chrome.show();
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant ProjectPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ownerChanged =
        oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id;
    if (oldWidget.project != widget.project) {
      _project = widget.project;
    }
    if (ownerChanged) {
      _generation++;
      _starEpoch++;
      _starred = null;
      _starCount = null;
      _starChecked = false;
      _starBusy = true;
      _starStarted = true;
      _bindSession();
      if (_sessionCurrent()) unawaited(_loadStar());
    }
  }

  void _focusChanged() {
    if (!mounted) return;
    _chrome.show();
    setState(() {});
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    _generation++;
    _starEpoch++;
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _chrome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final marked = _project.markedForDeletionOn != null;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final (visibilityLabel, visibilityIcon) = statusStyle(
      _project.visibility ?? '',
    );
    final starTooltip = !_starChecked
        ? '確認星標中…'
        : _starred == null
        ? '重新確認星標'
        : _starred!
        ? '移除星標'
        : '加入星標';
    final scaler = MediaQuery.textScalerOf(context);
    final crowded = scaler.scale(14) > 14 * 1.3;
    final titleStyle =
        theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 19) ??
        theme.textTheme.titleLarge!.copyWith(fontSize: 19);
    final subtitleStyle = theme.textTheme.bodySmall!;
    final toolbarHeight = math.max(
      kToolbarHeight,
      scaler.scale(titleStyle.fontSize ?? 19) * (titleStyle.height ?? 1.2) +
          scaler.scale(subtitleStyle.fontSize ?? 12) *
              (subtitleStyle.height ?? 1.2) +
          12,
    );
    final shareOwner = (
      widget.account.key,
      widget.api,
      widget.project.id,
      _project.path,
      _generation,
    );
    bool shareCurrent() =>
        mounted &&
        !widget.api.isClosed &&
        shareOwner ==
            (
              widget.account.key,
              widget.api,
              widget.project.id,
              _project.path,
              _generation,
            ) &&
        _sessionCurrent();
    final appBar = AppBar(
      primary: false,
      toolbarHeight: toolbarHeight,
      automaticallyImplyLeading: false,
      leading: widget.showBackButton
          ? BackButton(onPressed: widget.onBack)
          : null,
      titleSpacing: widget.showBackButton ? 0 : null,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _project.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.appBarTheme.titleTextStyle?.copyWith(
              fontSize: 19,
              color: marked ? muted : null,
            ),
          ),
          Row(
            children: [
              Tooltip(
                message: visibilityLabel,
                excludeFromSemantics: true,
                child: Semantics(
                  label: _project.visibilityLabel,
                  child: Icon(visibilityIcon, size: 13, color: muted),
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                flex: 3,
                child: Text(
                  _project.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              if (marked) ...[
                const SizedBox(width: 6),
                const Flexible(child: StatusBadge('marked_for_deletion')),
              ],
              if (_project.archived == true) ...[
                const SizedBox(width: 6),
                Flexible(
                  flex: 2,
                  child: Text(
                    '已封存 · 唯讀',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          key: const ValueKey('project-header-star'),
          tooltip: starTooltip,
          onPressed: _starBusy || !_currentStar(_starOwner)
              ? null
              : _toggleStarFromHeader,
          icon: _starBusy && !_starChecked
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  _starred == true
                      ? Icons.star
                      : _starred == null
                      ? Icons.star_half
                      : Icons.star_border,
                  size: 20,
                ),
        ),
        ResourceShareButton(
          uri: widget.account.instance.projectWeb(_project.path),
          ownerKey: shareOwner,
          isCurrent: shareCurrent,
        ),
        IconButton(
          tooltip: '在 GitLab 開啟',
          icon: const Icon(Icons.open_in_new, size: 20),
          onPressed: () => openExternal(
            context,
            widget.account.instance.projectWeb(_project.path),
          ),
        ),
      ],
    );
    // An issue or MR opened in place on a phone owns the screen: the project
    // header and tabs step aside and horizontal swipes stay with the detail.
    final focused = _focus.active;
    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: _chrome.handle,
        child: StatusBarInset(
          child: gestureSafe(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!focused) CollapsingChrome(visible: _chrome, child: appBar),
                if (!focused)
                  TabBar(
                    controller: _tabs,
                    indicatorSize: TabBarIndicatorSize.tab,
                    isScrollable: crowded,
                    tabAlignment: crowded ? TabAlignment.start : null,
                    tabs: const [
                      Tab(text: '檔案'),
                      Tab(text: '議題'),
                      Tab(text: 'MR'),
                      Tab(text: 'CI'),
                      Tab(text: '更多'),
                    ],
                  ),
                Expanded(
                  key: const ValueKey('project-tab-body'),
                  child: DetailFocusScope(
                    focus: _focus,
                    child: TabBarView(
                      controller: _tabs,
                      physics: focused
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      children: [
                        RepositoryTab(
                          account: widget.account,
                          api: widget.api,
                          project: _project,
                          active: _tabs.index == 0,
                        ),
                        TabActiveScope(
                          isActive:
                              TabActiveScope.of(context) && _tabs.index == 1,
                          child: WorkItemsTab(
                            account: widget.account,
                            api: widget.api,
                            project: _project,
                            resource: 'issues',
                          ),
                        ),
                        TabActiveScope(
                          isActive:
                              TabActiveScope.of(context) && _tabs.index == 2,
                          child: WorkItemsTab(
                            account: widget.account,
                            api: widget.api,
                            project: _project,
                            resource: 'merge_requests',
                          ),
                        ),
                        PipelinesTab(
                          account: widget.account,
                          api: widget.api,
                          project: _project,
                        ),
                        ProjectMoreTab(
                          account: widget.account,
                          api: widget.api,
                          project: _project,
                          onChanged: (value) =>
                              setState(() => _project = value),
                          onDeleted: widget.onDeleted,
                          starControl: ProjectStarControl(
                            starred: _starred,
                            checked: _starChecked,
                            busy: _starBusy,
                            starCount: _starCount,
                            revision: _starRevision,
                            recheck: () => _loadStar(reportFailure: true),
                            setStar: _setStar,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
