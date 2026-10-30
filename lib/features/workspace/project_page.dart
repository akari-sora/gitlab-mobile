import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/external_link.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/motion.dart';
import '../../shared/resource_share.dart';
import '../../shared/reveal_transition.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/skeleton.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import '../../core/repository_ref.dart';
import '../offline/offline_repositories.dart';
import '../offline/offline_status.dart';
import '../offline/save_sheet.dart';
import '../offline/snapshot_browser_page.dart';
import 'repository_page.dart';
import 'work_item_page.dart';
import 'ci_page.dart';
import 'project_more_page.dart';
import 'project_overview.dart';

import '../../l10n/l10n.dart';
class ProjectPage extends StatefulWidget {
  const ProjectPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.initialTab,
    this.showBackButton = true,
    this.onBack,
    this.onDeleted,
    this.onTabChanged,
    this.onStarChanged,
  });
  final Account account;
  final GitLabApi api;
  final Project project;

  /// The section to open (0 files, 1 issues, 2 merge requests, 3 CI,
  /// 4 more). Null lands on the GitHub-style project overview instead.
  final int? initialTab;
  final bool showBackButton;
  final VoidCallback? onBack;
  final VoidCallback? onDeleted;
  final ValueChanged<int>? onTabChanged;
  final Future<void> Function()? onStarChanged;
  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

enum _ProjectHeaderAction {
  copyId,
  openWeb,
  offline,
}

class _ProjectPageState extends State<ProjectPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _chrome = ScrollChromeController();
  final _focus = DetailFocus();
  final _overviewScroll = ScrollController();
  final _overviewTitle = ValueNotifier<bool>(false);
  late bool _overview = widget.initialTab == null;
  late bool _overviewVisited = _overview;
  late bool _sectionsVisited = !_overview;
  // Back from a section returns to the overview. That return is the shallowest
  // entry of this page's back chain: an open issue or MR, a folder level and
  // anything else registered below [DetailBackScope] here outranks it. Inside
  // a list-detail parent (探索) the entry joins the parent's dispatcher, one
  // level below the parent's own entry; a pushed page owns the dispatcher and
  // the route veto.
  DetailBackDispatcher? _ownBack, _back;
  int _backDepth = 1;
  bool _backActive = true;
  late final _overviewReturn = DetailBackEntry(
    depth: _backDepth,
    canHandle: () => mounted && _backActive && _returnsToOverview,
    onBack: _openOverview,
  );
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
      initialIndex: widget.initialTab ?? 0,
    );
    _tabs.addListener(_tabChanged);
    _overviewScroll.addListener(_overviewScrolled);
    final initialTab = widget.initialTab;
    if (initialTab != null && initialTab != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onTabChanged?.call(initialTab);
      });
    }
  }

  /// The overview's own header shows the name; the app bar takes it over
  /// once that header has scrolled away.
  void _overviewScrolled() {
    _overviewTitle.value = _overviewScroll.hasClients && _overviewScroll.offset > 110;
  }

  /// A section opened from this page's overview goes back to it; resume
  /// targets, CI and links that open a section directly have none to return to.
  bool get _returnsToOverview => widget.initialTab == null && !_overview;

  void _bindBack() {
    final parent = DetailBackScope.maybeOf(context);
    final dispatcher =
        parent?.dispatcher ?? (_ownBack ??= DetailBackDispatcher());
    _backDepth = (parent?.depth ?? 0) + 1;
    _backActive = TabActiveScope.of(context);
    _overviewReturn.depth = _backDepth;
    if (!identical(dispatcher, _back)) {
      _back?.unregister(_overviewReturn);
      _back = dispatcher;
      dispatcher.register(_overviewReturn);
    } else {
      dispatcher.notifyChanged();
    }
  }

  /// The section app bar's back inside a list-detail parent, which otherwise
  /// closes the project at once. A pushed page keeps the default back button,
  /// which pops through the route and so through the same chain as system back.
  void _sectionsBack() {
    if (_returnsToOverview) {
      _openOverview();
    } else {
      widget.onBack?.call();
    }
  }

  /// Leaves the overview for one section. Selecting the section already
  /// under the tab bar still reports it, so a list-detail parent can react.
  void _openSection(int index) {
    if (!mounted) return;
    final same = _tabs.index == index;
    setState(() {
      _overview = false;
      _sectionsVisited = true;
    });
    _back?.notifyChanged();
    _chrome.show();
    if (same) {
      widget.onTabChanged?.call(index);
    } else {
      _tabs.index = index;
    }
  }

  void _openOverview() {
    if (!mounted || _overview) return;
    setState(() {
      _overview = true;
      _overviewVisited = true;
    });
    _back?.notifyChanged();
    _chrome.show();
    // The overview is not a nested list-detail section.
    widget.onTabChanged?.call(0);
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
  ({String account, String instance, GitLabApi api, int project, int generation})
  get _copyOwner => (
    account: widget.account.key,
    instance: widget.account.instance.key,
    api: widget.api,
    project: _project.id,
    generation: _generation,
  );
  bool _currentCopy(
    ({String account, String instance, GitLabApi api, int project, int generation}) owner,
  ) =>
      mounted &&
      owner.generation == _generation &&
      owner.account == widget.account.key &&
      owner.instance == widget.account.instance.key &&
      identical(owner.api, widget.api) &&
      owner.project == _project.id &&
      owner.project > 0 &&
      !owner.api.isClosed &&
      _sessionCurrent();

  Future<void> _copyProjectId(
    ({String account, String instance, GitLabApi api, int project, int generation}) owner,
  ) async {
    if (!_currentCopy(owner)) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: '${owner.project}'));
      if (!mounted || !_currentCopy(owner)) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.copiedProjectId(owner.project))),
      );
    } catch (_) {
      if (!mounted || !_currentCopy(owner)) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.copyProjectIdFailed)),
      );
    }
  }
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
      ).showSnackBar(SnackBar(content: Text(desired ? l10n.starredAdded : l10n.starRemoved)));
    } catch (error) {
      _showStarFailure(error);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindSession();
    _bindBack();
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
    _back?.notifyChanged();
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
    _overviewScroll.removeListener(_overviewScrolled);
    _overviewScroll.dispose();
    _overviewTitle.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _chrome.dispose();
    _back?.unregister(_overviewReturn);
    _ownBack?.dispose();
    super.dispose();
  }

  /// "離線保存…" / "離線版本…" (§6.2): the default branch, whole repository.
  void _openOfflineSheet(OfflineRepositories offline) {
    final branch = _project.defaultBranch;
    unawaited(
      openOfflineSaveSheet(
        context,
        repositories: offline,
        account: widget.account,
        project: _project,
        ref: branch == null || branch.isEmpty
            ? null
            : RepositoryRef(
                kind: RepositoryRefKind.branch,
                name: branch,
                sha: '',
                protected: false,
                isDefault: true,
              ),
        onOpen: (record) => unawaited(
          openSnapshot(
            context,
            repositories: offline,
            record: record,
            account: widget.account,
          ),
        ),
      ),
    );
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
        ? l10n.checkingStar
        : _starred == null
        ? l10n.recheckStar
        : _starred!
        ? l10n.unstar
        : l10n.star;
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
    final headerMenu = PopupMenuButton<_ProjectHeaderAction>(
      key: const ValueKey('project-header-actions'),
      tooltip: l10n.moreActions,
      icon: const Icon(Icons.more_vert, size: 20),
      enabled: !widget.api.isClosed && _sessionCurrent(),
      itemBuilder: (_) {
        final owner = _copyOwner;
        final web = widget.account.instance.projectWeb(_project.path);
        return [
          if (owner.project > 0)
            PopupMenuItem(
              key: const ValueKey('project-header-action-copy-id'),
              value: _ProjectHeaderAction.copyId,
              onTap: () => unawaited(_copyProjectId(owner)),
              child: Text(l10n.copyProjectId(owner.project)),
            ),
          PopupMenuItem(
            key: const ValueKey('project-header-action-open-web'),
            value: _ProjectHeaderAction.openWeb,
            onTap: () {
              if (_currentCopy(owner)) {
                openExternal(context, web);
              }
            },
            child: Text(l10n.openInGitlab),
          ),
          if (OfflineScope.maybeOf(context, listen: false) case final offline?)
            PopupMenuItem(
              key: const ValueKey('project-header-action-offline'),
              value: _ProjectHeaderAction.offline,
              // After the menu has popped: the sheet must not be the route
              // the menu closes.
              onTap: () => WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _openOfflineSheet(offline);
              }),
              child: Text(
                completeSnapshotsOf(offline, _project.id).isEmpty
                    ? l10n.offlineSaveMenu
                    : l10n.offlineVersionMenu,
              ),
            ),
        ];
      },
    );
    final appBar = AppBar(
      primary: false,
      toolbarHeight: toolbarHeight,
      automaticallyImplyLeading: false,
      leading: widget.showBackButton
          ? BackButton(onPressed: widget.onBack == null ? null : _sectionsBack)
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
                    l10n.archivedReadOnly,
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
              ? const SkeletonBone(width: 20, height: 20, radius: 10)
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
        headerMenu,
      ],
    );
    final starControl = ProjectStarControl(
      starred: _starred,
      checked: _starChecked,
      busy: _starBusy,
      starCount: _starCount,
      revision: _starRevision,
      recheck: () => _loadStar(reportFailure: true),
      setStar: _setStar,
    );
    final heroColor = theme.brightness == Brightness.dark
        ? theme.scaffoldBackgroundColor
        : theme.colorScheme.surface;
    // An issue or MR opened in place on a phone owns the screen: the project
    // header and tabs step aside and horizontal swipes stay with the detail.
    final focused = _focus.active;
    final parentActive = TabActiveScope.of(context);
    final sections = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!focused) CollapsingChrome(visible: _chrome, child: appBar),
        if (!focused)
          DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(
              color: theme.tabBarTheme.dividerColor ?? theme.colorScheme.outlineVariant))),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('project-open-overview'),
                  tooltip: l10n.projectOverview,
                  onPressed: _openOverview,
                  icon: const Icon(Icons.space_dashboard_outlined, size: 20),
                ),
                Expanded(
                  child: TabBar(
                    controller: _tabs,
                    dividerHeight: 0,
                    indicatorSize: TabBarIndicatorSize.label,
                    isScrollable: crowded,
                    tabAlignment: crowded ? TabAlignment.start : null,
                    labelPadding: crowded ? null : const EdgeInsets.symmetric(horizontal: 4),
                    tabs: [
                      Tab(text: l10n.compareFilesSection),
                      Tab(text: l10n.issues),
                      Tab(text: 'MR'),
                      Tab(text: 'CI'),
                      Tab(text: l10n.moreItems),
                    ],
                  ),
                ),
              ],
            ),
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
                  active: !_overview && _tabs.index == 0,
                ),
                TabActiveScope(
                  isActive:
                      parentActive && !_overview && _tabs.index == 1,
                  child: WorkItemsTab(
                    account: widget.account,
                    api: widget.api,
                    project: _project,
                    resource: 'issues',
                  ),
                ),
                TabActiveScope(
                  isActive:
                      parentActive && !_overview && _tabs.index == 2,
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
                  starControl: starControl,
                ),
              ],
            ),
          ),
        ),
      ],
    );
    final overviewBar = AppBar(
      primary: false,
      backgroundColor: heroColor,
      automaticallyImplyLeading: false,
      leading: widget.showBackButton
          ? BackButton(onPressed: widget.onBack)
          : null,
      titleSpacing: widget.showBackButton ? 0 : null,
      title: ValueListenableBuilder<bool>(
        valueListenable: _overviewTitle,
        builder: (context, visible, _) => AnimatedSwitcher(
          duration: motionDuration(context, Durations.short3),
          child: !visible
              ? const SizedBox.shrink()
              : Column(
                  key: const ValueKey('project-overview-title'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _project.path.contains('/')
                          ? _project.path.substring(0, _project.path.lastIndexOf('/'))
                          : _project.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    Text(
                      _project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 18),
                    ),
                  ],
                ),
        ),
      ),
      actions: [headerMenu],
    );
    final overview = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        overviewBar,
        Expanded(
          child: ProjectOverview(
            account: widget.account,
            api: widget.api,
            project: _project,
            starControl: starControl,
            onSection: _openSection,
            isCurrent: () =>
                mounted && !widget.api.isClosed && _sessionCurrent(),
            controller: _overviewScroll,
          ),
        ),
      ],
    );
    Widget pane(bool shown, bool visited, Widget child) => !visited
        ? const SizedBox.shrink()
        : TabActiveScope(
            isActive: parentActive && shown,
            child: ExcludeSemantics(
              excluding: !shown,
              child: TickerMode(
                enabled: shown,
                child: IgnorePointer(ignoring: !shown, child: child),
              ),
            ),
          );
    final page = Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: _chrome.handle,
        child: StatusBarInset(
          color: _overview ? heroColor : null,
          child: gestureSafe(
            // A section slides in over the overview like a pushed page, and
            // slides away again to uncover it.
            AnimatedIndexedStack(
              key: const ValueKey('project-mode-stack'),
              index: _overview ? 0 : 1,
              sizing: StackFit.expand,
              motion: (from, to) => to == 1 ? StackMotion.push : StackMotion.pop,
              children: [
                pane(_overview, _overviewVisited, overview),
                pane(!_overview, _sectionsVisited, sections),
              ],
            ),
          ),
        ),
      ),
    );
    // The route veto is published only when this page owns the chain; inside
    // a list-detail parent the parent's scope already vetoes and dispatches.
    final back = _back!;
    final owned = identical(back, _ownBack);
    return DetailBackScope(
      dispatcher: back,
      depth: _backDepth,
      child: ListenableBuilder(
        listenable: back,
        child: page,
        builder: (context, child) => PopScope<Object?>(
          canPop: !owned || !back.canHandleBack,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && owned) back.handleBack();
          },
          child: child!,
        ),
      ),
    );
  }
}
