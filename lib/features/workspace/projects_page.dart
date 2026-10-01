import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/project_locator.dart';
import '../../shared/adaptive_breakpoints.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/workspace_ui.dart';
import '../auth/recent_project.dart';
import '../auth/session_controller.dart';
import '../shell/app_shortcuts.dart';
import 'editor.dart';
import 'groups_page.dart';
import 'navigation.dart';
import 'project_page.dart';
import 'records_feed.dart';
import 'search_page.dart';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({
    super.key,
    required this.session,
    this.forCi = false,
    this.shortcuts,
    this.recentStore,
    this.searchToken = 0,
  });
  final SessionController session;
  final bool forCi;
  final LauncherShortcuts? shortcuts;
  final RecentProjectStore? recentStore;
  final int searchToken;
  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}
class _ProjectsPageState extends State<ProjectsPage> {
  late final _selection = ListDetailController<Project>(equals: (a, b) => a.id == b.id);
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _feed = GlobalKey<RecordsFeedState>();
  Timer? _debounce;
  int _scope = 0;
  int _seenSearch = 0;
  String _query = '';
  String _sort = 'activity';
  bool _opening = false;
  int _projectTabIndex = 0;
  List<RecentProject> _recentProjects = const [];
  String? _activeAccountKey;
  int _activeGeneration = 0;

  RecentProjectStore get _recentStore =>
      widget.recentStore ?? widget.shortcuts?.recentStore ?? SecureRecentProjectStore();
  Account get account => widget.session.active!;
  GitLabApi get api => widget.session.api!;

  @override
  void initState() {
    super.initState();
    _activeAccountKey = widget.session.active?.key;
    _activeGeneration = widget.session.generation;
    _projectTabIndex = widget.forCi ? 3 : 0;
    _selection.addListener(_onSelectionChanged);
    widget.shortcuts?.addListener(_onShortcutsChanged);
    widget.session.addListener(_onSessionChanged);
    unawaited(_loadRecentProjects());
  }

  void _onSessionChanged() {
    final currentKey = widget.session.active?.key;
    final currentGen = widget.session.generation;
    if (currentKey != _activeAccountKey || currentGen != _activeGeneration) {
      _activeAccountKey = currentKey;
      _activeGeneration = currentGen;
      if (mounted) {
        setState(() {
          _recentProjects = const [];
          _opening = false;
        });
        unawaited(_loadRecentProjects());
      }
    }
  }

  Future<void> _loadRecentProjects() async {
    final active = widget.session.active;
    if (active == null) return;
    try {
      final list = await _recentStore.readList(active.key);
      if (mounted && widget.session.active?.key == active.key) {
        setState(() => _recentProjects = list);
      }
    } catch (_) {}
  }

  void _onSelectionChanged() {
    if (!_selection.hasSelection && _projectTabIndex != (widget.forCi ? 3 : 0)) {
      if (mounted) {
        setState(() {
          _projectTabIndex = widget.forCi ? 3 : 0;
        });
      }
    }
  }

  void _onShortcutsChanged() {
    if (mounted) {
      _selection.clear();
    }
  }

  @override
  void didUpdateWidget(covariant ProjectsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
    final currentKey = widget.session.active?.key;
    final currentGen = widget.session.generation;
    if (currentKey != _activeAccountKey || currentGen != _activeGeneration) {
      _activeAccountKey = currentKey;
      _activeGeneration = currentGen;
      _recentProjects = const [];
      _opening = false;
      unawaited(_loadRecentProjects());
    }
    if (oldWidget.shortcuts != widget.shortcuts) {
      oldWidget.shortcuts?.removeListener(_onShortcutsChanged);
      widget.shortcuts?.addListener(_onShortcutsChanged);
    }
    if (!widget.forCi && widget.searchToken != _seenSearch) {
      _seenSearch = widget.searchToken;
      _selection.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_feed.currentState?.scrollToTop());
        _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _selection.removeListener(_onSelectionChanged);
    widget.shortcuts?.removeListener(_onShortcutsChanged);
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _selection.dispose();
    super.dispose();
  }

  void _searchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () { if (mounted) setState(() => _query = value.trim()); });
  }

  void _open(Project project) {
    final activeAccount = widget.session.active;
    if (activeAccount == null) return;
    _projectTabIndex = widget.forCi ? 3 : 0;
    final shortcuts = widget.shortcuts;
    if (shortcuts != null) {
      unawaited(shortcuts.rememberOpened(accountKey: activeAccount.key, id: project.id, name: project.name));
    }
    unawaited(_recentStore.touch(
      activeAccount.key,
      RecentProject(id: project.id, name: project.name, path: project.path),
    ).then((_) {
      if (mounted && widget.session.active?.key == activeAccount.key) {
        _loadRecentProjects();
      }
    }).catchError((_) {}));
    _selection.select(project);
  }

  Future<void> _openRecentProject(RecentProject rp) async {
    if (_opening) return;
    final targetAccount = widget.session.active;
    if (targetAccount == null) return;
    final targetAccountKey = targetAccount.key;
    final targetGeneration = widget.session.generation;
    setState(() => _opening = true);
    try {
      final proj = await api.project('${rp.id}');
      if (!mounted) return;
      if (widget.session.active?.key != targetAccountKey ||
          widget.session.generation != targetGeneration) {
        return;
      }
      _open(proj);
    } catch (e) {
      if (!mounted) return;
      if (widget.session.active?.key != targetAccountKey ||
          widget.session.generation != targetGeneration) {
        return;
      }
      showFailure(context, e);
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> _locator() async {
    final input = TextEditingController();
    final locator = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('開啟專案'), content: TextField(controller: input, autofocus: true,
        autocorrect: false, decoration: const InputDecoration(labelText: '專案網址、完整路徑或 ID',
          hintText: 'group/project', helperText: '也可貼上議題、MR、Pipeline、Job 或提交連結', helperMaxLines: 2),
        onSubmitted: (value) => Navigator.pop(context, value)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, input.text), child: const Text('開啟'))],
    ));
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), input.dispose));
    if (locator == null || !mounted || _opening) return;
    final targetAccount = widget.session.active;
    if (targetAccount == null) return;
    final targetAccountKey = targetAccount.key;
    final targetGeneration = widget.session.generation;
    setState(() => _opening = true);
    try {
      final parsed = ProjectLocator.parse(locator, account.instance);
      final link = GitLabLink.parse(locator, account.instance);
      if (link.target != LinkTarget.project) {
        await ResourceNavigator(account, api).link(context, link);
        return;
      }
      final project = await api.project(parsed.idOrPath);
      if (!mounted) return;
      if (widget.session.active?.key != targetAccountKey ||
          widget.session.generation != targetGeneration) {
        return;
      }
      _open(project);
    } catch (e) {
      if (!mounted) return;
      if (widget.session.active?.key != targetAccountKey ||
          widget.session.generation != targetGeneration) {
        return;
      }
      showFailure(context, e);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }
  Future<void> _create() async {
    Project? created;
    final saved = await openEditor(context, account: account, title: '新增私有專案',
      resource: 'projects/new', subtitle: '新專案預設為私有，並建立 README。', fields: const [
        EditField('name', '專案名稱', required: true),
        EditField('path', '網址路徑', hint: '可留白，由 GitLab 依名稱產生'),
        EditField('description', '專案說明', lines: 4),
      ], save: (values) async {
        created = await api.createProject(name: values['name']!.trim(),
          path: values['path']!.trim().isEmpty ? null : values['path']!.trim(), description: values['description']!);
      });
    if (!mounted) return;
    if (saved && created != null) _open(created!);
  }
  static const _sorts = <String, (String, String, String)>{
    'activity': ('最近活動', 'last_activity_at', 'desc'),
    'name': ('名稱', 'name', 'asc'),
    'created': ('建立時間', 'created_at', 'desc'),
    'stars': ('星標數', 'star_count', 'desc'),
  };

  Future<void> _openAccounts() async {
    final session = widget.session;
    await showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
        Row(children: [
          Monogram(account.user.name, size: 48),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(account.user.name, style: theme.textTheme.titleMedium),
            Text('@${account.user.username}', style: theme.textTheme.bodyMedium),
            Text(account.instance.key, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ])),
        ]),
        const SizedBox(height: 12),
        for (final saved in session.accounts.where((saved) => saved.key != account.key))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Monogram(saved.user.name, size: 32),
            title: Text('@${saved.user.username}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(saved.instance.base.host),
            trailing: const Icon(Icons.swap_horiz),
            onTap: session.busy ? null : () {
              Navigator.pop(sheetContext);
              unawaited(session.select(saved));
            },
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_add_outlined),
          title: const Text('新增或切換帳號'),
          onTap: () {
            Navigator.pop(sheetContext);
            unawaited(session.endSession());
          },
        ),
      ]));
    });
  }

  Widget _appBar(BuildContext context) => SliverAppBar(
    floating: true, snap: true,
    title: Text(widget.forCi ? 'CI / CD' : '專案'),
    actions: [
      IconButton(tooltip: '全域搜尋', icon: const Icon(Icons.manage_search),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SearchPage(account: account, api: api)))),
      IconButton(tooltip: '以連結或路徑開啟', onPressed: _opening ? null : _locator, icon: const Icon(Icons.link)),
      if (!widget.forCi) IconButton(tooltip: '新增專案', onPressed: _create, icon: const Icon(Icons.add)),
      IconButton(tooltip: '帳號 @${account.user.username}', onPressed: _openAccounts,
        icon: Monogram(account.user.name, size: 30)),
      const SizedBox(width: 4),
    ],
    bottom: PreferredSize(preferredSize: const Size.fromHeight(64), child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        key: const Key('projectSearch'), focusNode: _searchFocus, controller: _search, onChanged: _searchChanged,
        textInputAction: TextInputAction.search,
        onSubmitted: (value) { _debounce?.cancel(); setState(() => _query = value.trim()); },
        decoration: InputDecoration(hintText: '搜尋專案', prefixIcon: const Icon(Icons.search),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          suffixIcon: IconButton(tooltip: '清除搜尋', icon: const Icon(Icons.close, size: 18),
            onPressed: () { _search.clear(); _debounce?.cancel(); setState(() => _query = ''); })),
      ),
    )),
  );

  Widget _controls(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = feedGutter(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_opening) const LinearProgressIndicator(minHeight: 2),
      SingleChildScrollView(scrollDirection: Axis.horizontal, padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 0),
        child: Row(children: [
          for (var i = 0; i < 4; i++) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
            label: Text(const ['我的專案', '星標', '所有可存取', '群組'][i]), selected: _scope == i,
            showCheckmark: false, onSelected: (_) => setState(() => _scope = i))),
          if (_scope != 3) PopupMenuButton<String>(
            tooltip: '排序方式',
            initialValue: _sort,
            onSelected: (value) => setState(() => _sort = value),
            itemBuilder: (_) => [
              for (final entry in _sorts.entries)
                CheckedPopupMenuItem(value: entry.key, checked: _sort == entry.key, child: Text(entry.value.$1)),
            ],
            child: Chip(avatar: const Icon(Icons.sort, size: 18), label: Text(_sorts[_sort]!.$1)),
          ),
        ])),
      if (_query.isEmpty && _recentProjects.isNotEmpty) ...[
        Padding(padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 6), child: Text('最近開啟',
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: gutter),
          child: Row(children: [
            for (final rp in _recentProjects)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  key: ValueKey('recent-project-${rp.id}'),
                  avatar: Monogram(rp.name, size: 22),
                  label: Text(rp.name),
                  tooltip: rp.path,
                  onPressed: _opening ? null : () => _openRecentProject(rp),
                ),
              ),
          ]),
        ),
      ],
    ]);
  }

  Widget _projectRow(BuildContext context, Json data, bool isTwoPane) {
    final project = Project.fromJson(data);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final marked = project.markedForDeletionOn != null;
    final muted = marked ? scheme.onSurfaceVariant : null;
    final isSelected = isTwoPane && _selection.isSelected(project);
    final namespace = project.path.split('/').take(project.path.split('/').length - 1).join('/');
    final stars = valueInt(data, 'star_count');
    final (visibilityLabel, visibilityIcon) = statusStyle(project.visibility ?? '');
    final secondary = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return SemanticButton(
      label: projectCardLabel(project, valueText(data, 'last_activity_at')),
      onTap: () => _open(project),
      child: Material(
        color: isSelected ? scheme.secondaryContainer : Colors.transparent,
        child: InkWell(onTap: () => _open(project), child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Monogram(project.name, size: 38),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontSize: 15, color: muted)),
              const SizedBox(height: 2),
              Row(children: [
                Icon(visibilityIcon, size: 13, color: scheme.onSurfaceVariant, semanticLabel: visibilityLabel),
                const SizedBox(width: 4),
                Flexible(flex: 3, child: Text(namespace.isEmpty ? visibilityLabel : namespace,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: secondary)),
                Flexible(flex: 2, child: Text(' · ${relativeDate(valueText(data, 'last_activity_at'))}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: secondary)),
              ]),
              if (project.description?.trim().isNotEmpty ?? false) Padding(padding: const EdgeInsets.only(top: 4),
                child: Text(project.description!.trim(), maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted ?? scheme.onSurface))),
              if (marked || project.archived == true) Padding(padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  if (marked) const StatusBadge('marked_for_deletion'),
                  if (project.archived == true) const MetaChip('已封存', icon: Icons.inventory_2_outlined),
                ])),
            ])),
            const SizedBox(width: 6),
            if (stars > 0) Padding(padding: const EdgeInsets.only(top: 1, right: 2), child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.star_border, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 2),
              Text('$stars', style: secondary),
            ])),
            Icon(isSelected ? Icons.check_circle : Icons.chevron_right, size: 18,
              color: isSelected ? scheme.primary : scheme.onSurfaceVariant),
          ]),
        )),
      ),
    );
  }

  Widget _buildList(BuildContext context, bool isTwoPane, Project? selected) {
    final idleAllScope = _scope == 2 && _query.isEmpty;
    final groups = _scope == 3;
    final sort = _sorts[_sort]!;
    return Scaffold(
      body: SafeArea(top: false, child: RecordsFeed(key: _feed,
        identity: groups ? 'groups/$_query' : 'projects/$_scope/$_sort/$_query', storageId: 'projects',
        account: account, resourceLabel: groups ? '群組列表' : '專案列表', underShell: true, grouped: true,
        onSwitchAccount: () { unawaited(widget.session.endSession()); },
        topSlivers: (context, _) => [_appBar(context)],
        leading: (context, _) => _controls(context),
        empty: groups
            ? (_query.isEmpty ? '你還沒有加入群組' : '找不到符合的群組')
            : idleAllScope ? '搜尋所有可存取的專案' : _query.isEmpty ? '目前沒有專案' : '找不到符合的專案',
        emptyDetail: groups
            ? null
            : idleAllScope ? '輸入名稱查找公開與私有專案，不限目前的成員專案。' : '可使用右上角連結，以完整路徑或 ID 開啟。',
        emptyIcon: groups ? Icons.workspaces_outline : idleAllScope ? Icons.search : Icons.folder_off_outlined,
        load: groups
            ? (next) => api.groups(search: _query, next: next)
            : idleAllScope ? (_) async => const ApiPage<Json>([]) : (next) => api.records(['projects'], query: {
          'order_by': sort.$2, 'sort': sort.$3,
          if (_scope == 0) 'membership': 'true', if (_scope == 1) 'starred': 'true',
          if (_query.isNotEmpty) 'search': _query,
        }, next: next),
        itemBuilder: (context, data) => groups
            ? groupRow(context, data, onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => GroupPage(account: account, api: api, group: data))))
            : _projectRow(context, data, isTwoPane),
      )),
    );
  }

  Widget _buildDetail(BuildContext context, Project item, bool isTwoPane, VoidCallback onBack) {
    final hasRail = AdaptiveScope.hasRailOf(context);
    final isNestedTab = hasRail && (_projectTabIndex == 1 || _projectTabIndex == 2);
    return ProjectPage(
      key: ValueKey('project-${item.id}'),
      account: account,
      api: api,
      project: item,
      initialTab: widget.forCi ? 3 : 0,
      showBackButton: !isTwoPane || isNestedTab,
      onBack: () {
        _projectTabIndex = widget.forCi ? 3 : 0;
        onBack();
      },
      onTabChanged: (index) {
        if (_projectTabIndex != index) {
          setState(() => _projectTabIndex = index);
        }
      },
      onDeleted: () {
        _projectTabIndex = widget.forCi ? 3 : 0;
        _selection.clear();
        unawaited(_feed.currentState?.refresh() ?? Future<void>.value());
      },
    );
  }

  Widget _buildEmpty(BuildContext context) => const Center(
    child: EmptyState(
      '請選擇專案',
      icon: Icons.folder_open_outlined,
      detail: '從左側清單選擇專案以查看詳情、檔案與流程。',
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hasRail = AdaptiveScope.hasRailOf(context);
    return ListDetailScaffold<Project>(
      controller: _selection,
      listBuilder: _buildList,
      detailBuilder: _buildDetail,
      emptyBuilder: _buildEmpty,
      collapseMaster: (selected) =>
          selected != null &&
          hasRail &&
          (_projectTabIndex == 1 || _projectTabIndex == 2),
    );
  }
}
