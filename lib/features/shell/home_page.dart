import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/hub_ui.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/workspace_ui.dart';
import '../auth/recent_project.dart';
import '../auth/session_controller.dart';
import '../workspace/activity_page.dart';
import '../workspace/ci_overview_page.dart';
import '../workspace/groups_page.dart';
import '../workspace/my_work_page.dart';
import '../workspace/project_page.dart';
import '../workspace/projects_page.dart';
import '../workspace/search_page.dart';
import 'account_sheet.dart';
import 'app_shortcuts.dart';

/// The Home destination, laid out like GitHub Mobile's: 我的工作 rows with
/// coloured tiles, the projects opened recently on this device, the account's
/// starred projects and one-tap shortcuts. Everything here belongs to the
/// active account; reads that finish after an account change are dropped.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.session,
    this.shortcuts,
    this.recentStore,
    this.onOpenInbox,
    this.onExplore,
    this.onLocate,
    this.onCreate,
  });
  final SessionController session;
  final LauncherShortcuts? shortcuts;
  final RecentProjectStore? recentStore;
  final VoidCallback? onOpenInbox;
  final VoidCallback? onExplore;
  final VoidCallback? onLocate;
  final VoidCallback? onCreate;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scroll = ScrollController();
  List<RecentProject> _recent = const [];
  List<Json>? _starred;
  ApiFailure? _starredError;
  bool _loadingStarred = false;
  bool _opening = false;
  int _epoch = 0;
  RecentProjectStore? _fallbackStore;

  RecentProjectStore get _store =>
      widget.recentStore ?? widget.shortcuts?.recentStore ?? (_fallbackStore ??= SecureRecentProjectStore());

  ({String account, GitLabApi api, int generation})? get _owner {
    final account = widget.session.active, api = widget.session.api;
    if (account == null || api == null) return null;
    return (account: account.key, api: api, generation: widget.session.generation);
  }

  bool _current(({String account, GitLabApi api, int generation}) owner, int epoch) =>
      mounted &&
      epoch == _epoch &&
      !owner.api.isClosed &&
      widget.session.active?.key == owner.account &&
      identical(widget.session.api, owner.api) &&
      widget.session.generation == owner.generation;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_sessionChanged);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_sessionChanged);
      widget.session.addListener(_sessionChanged);
      _sessionChanged();
    }
  }

  void _sessionChanged() {
    final owner = _owner;
    if (owner == null) return;
    // The shell rebuilds on every account switch; this only drops a stale
    // in-flight read if the client changes underneath the page.
    if (_loadedFor != null && _loadedFor != owner) {
      _epoch++;
      setState(() {
        _recent = const [];
        _starred = null;
        _starredError = null;
        _opening = false;
      });
      unawaited(_refresh());
    }
  }

  ({String account, GitLabApi api, int generation})? _loadedFor;

  @override
  void dispose() {
    _epoch++;
    widget.session.removeListener(_sessionChanged);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final owner = _owner;
    if (owner == null) return;
    _loadedFor = owner;
    final epoch = ++_epoch;
    await Future.wait([_loadRecent(owner, epoch), _loadStarred(owner, epoch)]);
  }

  Future<void> _loadRecent(({String account, GitLabApi api, int generation}) owner, int epoch) async {
    try {
      final list = await _store.readList(owner.account);
      if (_current(owner, epoch)) setState(() => _recent = list);
    } catch (_) {}
  }

  Future<void> _loadStarred(({String account, GitLabApi api, int generation}) owner, int epoch) async {
    setState(() {
      _loadingStarred = true;
      _starredError = null;
    });
    try {
      final page = await owner.api.records(['projects'], query: const {
        'starred': 'true', 'order_by': 'last_activity_at', 'sort': 'desc', 'per_page': '5',
      });
      if (!_current(owner, epoch)) return;
      setState(() => _starred = page.items.take(5).toList());
    } catch (e) {
      if (!_current(owner, epoch)) return;
      final failure = safeFailure(e);
      if (failure.kind == FailureKind.cancelled) return;
      setState(() => _starredError = failure);
    } finally {
      if (_current(owner, epoch)) setState(() => _loadingStarred = false);
    }
  }

  void _push(Widget Function(Account account, GitLabApi api) page) {
    final account = widget.session.active, api = widget.session.api;
    if (account == null || api == null) return;
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page(account, api))));
  }

  void _pushProjects(String title, int scope) {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProjectsPage(
      session: widget.session,
      shortcuts: widget.shortcuts,
      recentStore: widget.recentStore,
      title: title,
      initialScope: scope,
    ))));
  }

  Future<void> _remember(({String account, GitLabApi api, int generation}) owner, Project project) async {
    final recent = RecentProject(id: project.id, name: project.name, path: project.path);
    final store = _store, shortcutStore = widget.shortcuts?.recentStore;
    Future<void> touch(RecentProjectStore target) async {
      try {
        await target.touch(owner.account, recent);
      } catch (_) {}
    }
    await Future.wait([
      touch(store),
      if (shortcutStore != null && !identical(shortcutStore, store)) touch(shortcutStore),
    ]);
    if (!mounted || widget.session.active?.key != owner.account || widget.session.generation != owner.generation) {
      return;
    }
    final shortcuts = widget.shortcuts;
    if (shortcuts != null) unawaited(shortcuts.publish(owner.account));
    await _loadRecent(owner, _epoch);
  }

  void _openProject(Project project) {
    final owner = _owner;
    final account = widget.session.active;
    if (owner == null || account == null) return;
    unawaited(_remember(owner, project));
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ProjectPage(account: account, api: owner.api, project: project),
    )));
  }

  Future<void> _openRecent(RecentProject recent) async {
    final owner = _owner;
    if (owner == null || _opening) return;
    final epoch = _epoch;
    setState(() => _opening = true);
    try {
      final project = await owner.api.project('${recent.id}');
      if (!_current(owner, epoch)) return;
      _openProject(project);
    } catch (e) {
      if (!mounted || !_current(owner, epoch)) return;
      showFailure(context, e);
    } finally {
      if (_current(owner, epoch)) setState(() => _opening = false);
    }
  }

  Future<void> _addMenu() async {
    final action = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (sheet) =>
      SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.add_box_outlined),
          title: const Text('新增專案'),
          subtitle: const Text('建立私有專案並附上 README'),
          onTap: () => Navigator.pop(sheet, 'create'),
        ),
        ListTile(
          leading: const Icon(Icons.link),
          title: const Text('以連結或路徑開啟'),
          subtitle: const Text('專案、議題、MR、Pipeline 或提交連結'),
          onTap: () => Navigator.pop(sheet, 'locate'),
        ),
        const SizedBox(height: 8),
      ])));
    if (!mounted) return;
    switch (action) {
      case 'create':
        widget.onCreate?.call();
      case 'locate':
        widget.onLocate?.call();
    }
  }

  Widget _myWork(BuildContext context) => HubSection(
    title: '我的工作',
    children: [
      HubRow(
        leading: const IconTile(Icons.adjust, color: HubColors.green),
        title: '議題',
        onTap: () => _push((account, api) => MyWorkPage(account: account, api: api, kind: MyWorkKind.issues)),
      ),
      HubRow(
        leading: const IconTile(Icons.merge, color: HubColors.blue),
        title: '合併請求',
        onTap: () => _push((account, api) => MyWorkPage(account: account, api: api, kind: MyWorkKind.mergeRequests)),
      ),
      HubRow(
        leading: const IconTile(Icons.rocket_launch_outlined, color: HubColors.purple),
        title: 'CI/CD',
        onTap: () => _push((account, api) => CiOverviewPage(session: widget.session)),
      ),
      HubRow(
        leading: const IconTile(Icons.book_outlined, color: HubColors.grey),
        title: '專案',
        onTap: () => _pushProjects('專案', 0),
      ),
      HubRow(
        leading: const IconTile(Icons.workspaces_outline, color: HubColors.orange),
        title: '群組',
        onTap: () => _push((account, api) => GroupsPage(account: account, api: api)),
      ),
      HubRow(
        leading: const IconTile(Icons.timeline, color: HubColors.slate),
        title: '動態',
        onTap: () => _push((account, api) => ActivityPage(account: account, api: api, title: '我的動態')),
      ),
      HubRow(
        leading: const IconTile(Icons.star_border, color: HubColors.yellow),
        title: '星標',
        onTap: () => _pushProjects('星標專案', 1),
      ),
    ],
  );

  Widget _projectRow(BuildContext context, {required String name, required String path, String? value,
      required VoidCallback? onTap, Key? key}) {
    final namespace = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : path;
    return HubRow(
      key: key,
      leading: Monogram(name, size: 32),
      title: name,
      subtitle: namespace,
      value: value,
      onTap: onTap,
    );
  }

  Widget _recentSection(BuildContext context) => HubSection(
    title: '最近開啟',
    children: [
      if (_opening) const LinearProgressIndicator(minHeight: 2),
      for (final recent in _recent.take(5))
        _projectRow(context,
          key: ValueKey('home-recent-${recent.id}'),
          name: recent.name, path: recent.path ?? '',
          onTap: _opening ? null : () => _openRecent(recent)),
    ],
  );

  Widget _starredSection(BuildContext context) {
    final theme = Theme.of(context);
    final starred = _starred;
    final List<Widget> body;
    if (starred == null && _starredError == null) {
      body = [const Padding(padding: EdgeInsets.all(20), child: Center(child: SizedBox.square(
        dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))))];
    } else if (_starredError != null && (starred == null || starred.isEmpty)) {
      body = [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text('${_starredError!.title}。${_starredError!.detail}',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: HubButton(label: '重新整理', icon: Icons.refresh, onPressed: _loadingStarred ? null : _refresh),
        ),
      ];
    } else if (starred!.isEmpty) {
      body = [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Text('為常用的專案加上星標，隨時一鍵開啟，不必再搜尋。', textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: HubButton(label: '瀏覽專案', onPressed: widget.onExplore),
        ),
      ];
    } else {
      body = [
        for (final data in starred)
          Builder(builder: (context) {
            final Project project;
            try {
              project = Project.fromJson(data);
            } catch (_) {
              return const SizedBox.shrink();
            }
            final stars = valueInt(data, 'star_count');
            return _projectRow(context,
              key: ValueKey('home-starred-${project.id}'),
              name: project.name, path: project.path,
              value: stars > 0 ? '★ $stars' : null,
              onTap: () => _openProject(project));
          }),
      ];
    }
    return HubSection(
      title: '星標專案',
      trailing: starred != null && starred.isNotEmpty
          ? TextButton(onPressed: () => _pushProjects('星標專案', 1), child: const Text('查看全部'))
          : null,
      children: body,
    );
  }

  Widget _shortcutsSection(BuildContext context) {
    final theme = Theme.of(context);
    return HubSection(
      title: '捷徑',
      divider: false,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('需要的東西，一鍵直達',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            CircleShortcut(icon: Icons.search, color: HubColors.blue, label: '全域搜尋',
              onTap: () => _push((account, api) => SearchPage(account: account, api: api))),
            CircleShortcut(icon: Icons.inbox_outlined, color: HubColors.green, label: '待辦',
              onTap: () => widget.onOpenInbox?.call()),
            CircleShortcut(icon: Icons.rate_review_outlined, color: HubColors.purple, label: '待我審查',
              onTap: () => _push((account, api) => MyWorkPage(account: account, api: api, kind: MyWorkKind.mergeRequests))),
            CircleShortcut(icon: Icons.link, color: HubColors.orange, label: '以連結開啟',
              onTap: () => widget.onLocate?.call()),
            CircleShortcut(icon: Icons.add, color: HubColors.pink, label: '新增專案',
              onTap: () => widget.onCreate?.call()),
          ]),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.session.active;
    if (account == null) return const Scaffold(body: SizedBox());
    final width = MediaQuery.sizeOf(context).width;
    Widget column(Widget child) => width > 760
        ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child))
        : child;
    return Scaffold(
      body: StatusBarInset(child: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppBar(
          primary: false,
          title: const LargeTitle('首頁'),
          actions: [
            IconButton(
              tooltip: '全域搜尋',
              icon: const Icon(Icons.search),
              onPressed: () => _push((account, api) => SearchPage(account: account, api: api)),
            ),
            IconButton(
              tooltip: '重新整理',
              icon: const Icon(Icons.refresh),
              onPressed: _loadingStarred ? null : _refresh,
            ),
            IconButton(
              tooltip: '新增',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: _addMenu,
            ),
            AccountAvatarButton(session: widget.session),
            const SizedBox(width: 4),
          ],
        ),
        Expanded(child: RefreshIndicator(
          onRefresh: _refresh,
          child: ScrollToTopOnSignal(controller: _scroll, child: ListView(
            key: const PageStorageKey('home'),
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              column(_myWork(context)),
              if (_recent.isNotEmpty) column(_recentSection(context)),
              column(_starredSection(context)),
              column(_shortcutsSection(context)),
            ],
          )),
        )),
      ]))),
    );
  }
}
