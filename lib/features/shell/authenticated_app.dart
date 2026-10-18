import 'dart:async';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/adaptive_breakpoints.dart';
import '../../shared/hub_ui.dart';
import '../../shared/in_app_links.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../auth/recent_project.dart';
import '../auth/session_controller.dart';
import '../workspace/activity_page.dart';
import '../workspace/groups_page.dart';
import '../workspace/project_page.dart';
import '../workspace/projects_page.dart';
import '../workspace/inbox_page.dart';
import '../workspace/navigation.dart';
import '../workspace/search_page.dart';
import '../workspace/ci_page.dart';
import '../workspace/work_item_page.dart';
import '../workspace/editor.dart';
import 'app_shortcuts.dart';
import 'home_page.dart';
import 'appearance.dart';
import 'build_info.dart';

class AuthenticatedApp extends StatefulWidget {
  const AuthenticatedApp({
    super.key,
    required this.session,
    required this.appearance,
    required this.shortcuts,
    this.dynamicLight,
    this.dynamicDark,
    this.buildInfoLoader = loadBuildInfo,
  });
  final SessionController session;
  final AppearanceController appearance;
  final LauncherShortcuts shortcuts;
  final ColorScheme? dynamicLight;
  final ColorScheme? dynamicDark;
  final BuildInfoLoader buildInfoLoader;
  @override
  State<AuthenticatedApp> createState() => _AuthenticatedAppState();
}

/// Fires when a route above the shell starts to pop, so navigation tucked away
/// by scrolling returns together with the shell.
class _PopObserver extends NavigatorObserver with ChangeNotifier {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => notifyListeners();
}

class _AuthenticatedAppState extends State<AuthenticatedApp> {
  // The appearance lives outside this widget on purpose: the whole
  // authenticated tree is rebuilt on every account switch, and the choice is a
  // device preference that must survive both that and a restart.
  bool _dynamicProbeSettled = false;
  bool _probedScheme = false;
  final _pops = _PopObserver();
  late InAppLinkHandler _links;

  @override
  void dispose() {
    _pops.dispose();
    super.dispose();
  }

  /// Links tapped anywhere in this tree open for the account this tree was
  /// built for. Once the session moves on they go to the browser instead.
  InAppLinkHandler _bindLinks(SessionController session) {
    final account = session.active;
    final api = session.api;
    if (account == null || api == null) return (_, _) async => false;
    final generation = session.generation;
    return inAppLinkHandler(
      account,
      api,
      isCurrent: () =>
          mounted &&
          !api.isClosed &&
          session.generation == generation &&
          session.active?.key == account.key &&
          identical(session.api, api),
      ownerChanges: session,
      sessionGeneration: generation,
    );
  }

  @override
  void didUpdateWidget(covariant AuthenticatedApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _links = _bindLinks(widget.session);
    }
  }

  @override
  void initState() {
    super.initState();
    _links = _bindLinks(widget.session);
    if (widget.dynamicLight != null || widget.dynamicDark != null) {
      _dynamicProbeSettled = true;
      _probedScheme = true;
    } else {
      unawaited(_probeDynamicColor());
    }
  }

  Future<void> _probeDynamicColor() async {
    var hasScheme = false;
    try {
      hasScheme = await DynamicColorPlugin.getCorePalette() != null;
    } catch (_) {}
    if (!hasScheme) {
      try {
        hasScheme = await DynamicColorPlugin.getAccentColor() != null;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _dynamicProbeSettled = true;
      _probedScheme = hasScheme;
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.appearance,
    builder: (context, _) => DynamicColorBuilder(
      builder: (light, dark) {
        final resolvedLight = widget.dynamicLight ?? flutterScheme(light);
        final resolvedDark = widget.dynamicDark ?? flutterScheme(dark);
        final available = resolvedLight != null || resolvedDark != null || _probedScheme;
        final enabled = available && widget.appearance.useDynamicColor;
        if (_dynamicProbeSettled &&
            !available &&
            widget.appearance.loaded &&
            widget.appearance.useDynamicColor) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(widget.appearance.clearUnsupportedDynamicColor());
          });
        }
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          // Above the navigator, so every pushed route sees the link handler.
          builder: (context, child) => InAppLinks(
            handler: _links,
            child: applySystemBars(context, child),
          ),
          title: 'GitLab Mobile',
          theme: appTheme(
            Brightness.light,
            dynamicScheme: enabled ? resolvedLight : null,
          ),
          darkTheme: appTheme(
            Brightness.dark,
            dynamicScheme: enabled ? resolvedDark : null,
          ),
          themeMode: widget.appearance.mode,
          locale: const Locale('zh', 'TW'),
          supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          navigatorObservers: [_pops],
          home: _MobileShell(
            session: widget.session,
            shortcuts: widget.shortcuts,
            pops: _pops,
            theme: widget.appearance.mode,
            changeTheme: (mode) => unawaited(widget.appearance.select(mode)),
            useDynamicColor: widget.appearance.useDynamicColor,
            dynamicColorAvailable: available,
            changeDynamicColor: (value) =>
                unawaited(widget.appearance.setUseDynamicColor(value)),
            buildInfoLoader: widget.buildInfoLoader,
          ),
        );
      },
    ),
  );
}

class _MobileShell extends StatefulWidget {
  const _MobileShell({
    required this.session,
    required this.shortcuts,
    required this.pops,
    required this.theme,
    required this.changeTheme,
    required this.useDynamicColor,
    required this.dynamicColorAvailable,
    required this.changeDynamicColor,
    required this.buildInfoLoader,
  });
  final SessionController session;
  final LauncherShortcuts shortcuts;
  final Listenable pops;
  final ThemeMode theme;
  final ValueChanged<ThemeMode> changeTheme;
  final bool useDynamicColor;
  final bool dynamicColorAvailable;
  final ValueChanged<bool> changeDynamicColor;
  final BuildInfoLoader buildInfoLoader;
  @override
  State<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<_MobileShell> {
  final _backDispatcher = DetailBackDispatcher();
  final _chrome = ScrollChromeController();
  final _scrollTop = List.generate(4, (_) => ValueNotifier<int>(0));
  final _meScroll = ScrollController();
  bool? _useRail;
  int _selected = _home;
  int _searchToken = 0;
  int _locatorToken = 0;
  int _createToken = 0;
  int _todoToken = 0;
  bool _removing = false;
  final Set<int> _visited = {_home};

  static const _home = 0, _inbox = 1, _explore = 2, _me = 3;
  ApiFailure? _recentFailure;
  Account? _recentAccount;
  int? _recentProjectId;
  int? _recentGeneration;
  ResumeTarget? _resumeTarget;
  ApiFailure? _resumeFailure;
  Account? _resumeAccount;
  int? _resumeGeneration;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    widget.shortcuts.addListener(_onShortcut);
    widget.pops.addListener(_chrome.show);
    final account = widget.session.active;
    if (account != null) {
      unawaited(widget.shortcuts.publish(account.key));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_consumeResumeTarget());
        unawaited(_consumeShortcut());
      }
    });
  }

  @override
  void didUpdateWidget(covariant _MobileShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
    }
    if (oldWidget.pops != widget.pops) {
      oldWidget.pops.removeListener(_chrome.show);
      widget.pops.addListener(_chrome.show);
    }
  }

  void _onSession() {
    if (mounted) {
      if (widget.session.active != null && widget.session.pendingResumeTarget != null) {
        unawaited(_consumeResumeTarget());
      }
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.pops.removeListener(_chrome.show);
    _backDispatcher.dispose();
    _chrome.dispose();
    _meScroll.dispose();
    for (final signal in _scrollTop) {
      signal.dispose();
    }
    widget.session.removeListener(_onSession);
    widget.shortcuts.removeListener(_onShortcut);
    super.dispose();
  }

  void _onShortcut() {
    if (widget.shortcuts.pending != null) {
      unawaited(_consumeShortcut());
    }
  }

  Future<void> _consumeShortcut() async {
    final account = widget.session.active;
    final api = widget.session.api;
    if (account == null || api == null || !mounted) {
      return;
    }
    final shortcut = widget.shortcuts.takeFor(account.key);
    if (shortcut == null || !mounted) {
      return;
    }
    if (!await _bringShellForward() || !mounted || widget.session.active?.key != account.key) {
      return;
    }
    _chrome.show();
    switch (shortcut.kind) {
      case ShortcutKind.inbox:
        setState(() {
          _selected = _inbox;
          _visited.add(_inbox);
        });
      case ShortcutKind.search:
        setState(() {
          _selected = _explore;
          _visited.add(_explore);
          _searchToken++;
        });
      case ShortcutKind.recent:
        final id = shortcut.projectId;
        if (id == null) return;
        setState(() {
          _selected = _explore;
          _visited.add(_explore);
        });
        await _openRecent(account, api, id);
    }
  }

  /// Pops pushed routes so the shell is the visible page. A route that refuses
  /// to pop handles that attempt itself. An editor may still be flushing a
  /// draft or confirming the exit; that work is awaited. If the route is still
  /// up afterwards, the shortcut stops instead of discarding the guard.
  Future<bool> _bringShellForward() async {
    final navigator = Navigator.of(context);
    while (mounted) {
      final top = _topRoute(navigator);
      if (top == null || top.isFirst) return true;
      if (top is ModalRoute<Object?> && top.popDisposition == RoutePopDisposition.doNotPop) {
        top.onPopInvokedWithResult(false, null);
        final pending = RouteExit.pending(top);
        if (pending != null) {
          try {
            await pending;
          } catch (_) {
            // The route reports its own failure; the shortcut only needs to
            // know whether the page is still up.
          }
        } else {
          await Future<void>.delayed(Duration.zero);
        }
        if (!mounted || top.isActive) return false;
        continue;
      }
      navigator.pop();
    }
    return false;
  }

  Route<dynamic>? _topRoute(NavigatorState navigator) {
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }

  bool _sameAccount(Account account, int generation) =>
      mounted &&
      widget.session.generation == generation &&
      widget.session.active?.key == account.key;

  Future<void> _openRecent(Account account, GitLabApi api, int projectId) async {
    final generation = widget.session.generation;
    try {
      final project = await api.project('$projectId');
      if (!_sameAccount(account, generation) || !mounted) return;
      setState(() {
        _recentFailure = null;
        _recentAccount = null;
        _recentProjectId = null;
        _recentGeneration = null;
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProjectPage(account: account, api: api, project: project),
        ),
      );
    } catch (e) {
      if (!_sameAccount(account, generation)) return;
      final failure = safeFailure(e);
      if (failure.kind == FailureKind.cancelled) return;
      setState(() {
        _recentFailure = failure;
        _recentAccount = account;
        _recentProjectId = projectId;
        _recentGeneration = generation;
      });
    }
  }

  void _retryRecent() {
    final account = _recentAccount;
    final api = widget.session.api;
    final id = _recentProjectId;
    final generation = _recentGeneration;
    if (account == null || api == null || id == null || generation == null) return;
    if (!_sameAccount(account, generation)) return;
    unawaited(_openRecent(account, api, id));
  }

  bool get _showRecentFailure {
    final failure = _recentFailure;
    final account = _recentAccount;
    final generation = _recentGeneration;
    if (failure == null || account == null || generation == null || _recentProjectId == null) {
      return false;
    }
    return widget.session.generation == generation && widget.session.active?.key == account.key;
  }

  Future<void> _consumeResumeTarget() async {
    final account = widget.session.active;
    if (account == null || !mounted) return;
    final target = widget.session.takeResumeTarget();
    if (target == null || !mounted) return;
    await _openResumeTarget(target);
  }

  Future<void> _openResumeTarget(ResumeTarget target) async {
    final account = widget.session.active;
    final api = widget.session.api;
    if (account == null || api == null || !mounted) return;
    if (!await _bringShellForward() || !mounted || widget.session.active?.key != account.key) {
      return;
    }
    final generation = widget.session.generation;
    try {
      final projectRef = (target.projectPath != null && target.projectPath!.isNotEmpty)
          ? target.projectPath!
          : (target.projectId != null ? '${target.projectId}' : '');
      if (projectRef.isEmpty) return;

      final project = await api.project(projectRef);
      if (!_sameAccount(account, generation) || !mounted) return;

      setState(() {
        _resumeFailure = null;
        _resumeAccount = null;
        _resumeGeneration = null;
        _resumeTarget = null;
      });

      final Widget page;
      switch (target.resource) {
        case 'issues' || 'issue':
          if (target.iid != null) {
            page = WorkItemPage(
              account: account,
              api: api,
              project: project,
              resource: 'issues',
              iid: target.iid!,
            );
          } else {
            page = ProjectPage(
              account: account,
              api: api,
              project: project,
              initialTab: 1,
            );
          }
        case 'merge_requests' || 'merge_request':
          if (target.iid != null) {
            page = WorkItemPage(
              account: account,
              api: api,
              project: project,
              resource: 'merge_requests',
              iid: target.iid!,
            );
          } else {
            page = ProjectPage(
              account: account,
              api: api,
              project: project,
              initialTab: 2,
            );
          }
        case 'pipelines' || 'pipeline':
          if (target.iid != null) {
            page = PipelinePage(
              account: account,
              api: api,
              project: project,
              id: target.iid!,
            );
          } else {
            page = ProjectPage(
              account: account,
              api: api,
              project: project,
              initialTab: 3,
            );
          }
        case 'repository':
          page = ProjectPage(
            account: account,
            api: api,
            project: project,
            initialTab: 0,
          );
        case 'project':
        default:
          page = ProjectPage(
            account: account,
            api: api,
            project: project,
          );
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => page),
      );
    } catch (e) {
      if (!_sameAccount(account, generation)) return;
      final failure = safeFailure(e);
      if (failure.kind == FailureKind.cancelled) return;
      setState(() {
        _resumeFailure = failure;
        _resumeAccount = account;
        _resumeGeneration = generation;
        _resumeTarget = target;
      });
    }
  }

  void _retryResume() {
    final target = _resumeTarget;
    final account = _resumeAccount;
    final generation = _resumeGeneration;
    if (target == null || account == null || generation == null) return;
    if (!_sameAccount(account, generation)) return;
    unawaited(_openResumeTarget(target));
  }

  bool get _showResumeFailure {
    final failure = _resumeFailure;
    final account = _resumeAccount;
    final generation = _resumeGeneration;
    if (failure == null || account == null || generation == null || _resumeTarget == null) {
      return false;
    }
    return widget.session.generation == generation && widget.session.active?.key == account.key;
  }

  Future<void> _remove(Account account) async {
    if (_removing ||
        !await confirmAction(
          context,
          '移除此帳號？',
          '會清除這個帳號在此裝置的登入與草稿，不會撤銷 GitLab 上的 Token。',
        )) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _removing = true);
    try {
      await clearSecureDrafts(account);
      await clearAccountArtifacts(account);
      await clearRecentProject(account);
      await widget.session.remove(account);
    } catch (e) {
      if (mounted) {
        showFailure(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => _removing = false);
      }
    }
  }

  Widget _pane(int index, Widget child) => TabActiveScope(
    isActive: _selected == index,
    child: ScrollTopSignal(
      notifier: _scrollTop[index],
      child: ExcludeSemantics(
        excluding: _selected != index,
        child: TickerMode(
          enabled: _selected == index,
          child: IgnorePointer(ignoring: _selected != index, child: child),
        ),
      ),
    ),
  );

  /// Switching destinations reveals the navigation again. Tapping the active
  /// destination scrolls its lists back to the top; open details stay open.
  void _select(int index) {
    _chrome.show();
    if (index != _selected) {
      setState(() {
        _selected = index;
        _visited.add(index);
      });
      return;
    }
    _scrollTop[index].value++;
  }

  /// Home's 待辦, 瀏覽專案, 以連結開啟 and 新增專案 hand over to the inbox or
  /// the explore destination, which own those flows.
  void _goTo(int index, {bool locate = false, bool create = false, bool todo = false}) {
    _chrome.show();
    setState(() {
      _selected = index;
      _visited.add(index);
      if (locate) _locatorToken++;
      if (create) _createToken++;
      if (todo) _todoToken++;
    });
  }

  static const _destinations = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home, '首頁'),
    (Icons.inbox_outlined, Icons.inbox, '收件匣'),
    (Icons.explore_outlined, Icons.explore, '探索'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  Widget _bottomNavigation(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.navigationBarTheme.backgroundColor ?? theme.colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CollapsingChrome(
            visible: _chrome,
            edge: AxisDirection.down,
            child: MediaQuery.removePadding(
              context: context,
              // This context is above Scaffold: do not restore its status-bar
              // inset inside NavigationBar's SafeArea.
              removeTop: true,
              removeBottom: true,
              child: NavigationBar(
                selectedIndex: _selected,
                onDestinationSelected: _select,
                destinations: [
                  for (final (icon, selectedIcon, label) in _destinations)
                    NavigationDestination(icon: Icon(icon), selectedIcon: Icon(selectedIcon), label: label),
                ],
              ),
            ),
          ),
          // The gesture-bar inset stays reserved while the bar is tucked away,
          // so list ends never slide under the system handle.
          SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
        ],
      ),
    );
  }
  Widget _buildMyTab(BuildContext context, Account account, SessionController session) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    void push(Widget Function() page) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page()));
    return Scaffold(
      appBar: AppBar(title: const LargeTitle('我的')),
      body: gestureSafe(ScrollToTopOnSignal(
        controller: _meScroll,
        child: ListView(
          controller: _meScroll,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // Profile header, GitHub-style: round avatar, name, handle, instance.
            Material(
              color: theme.colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Row(children: [
                  Monogram(account.user.name, size: 72, circle: true),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.user.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall,
                        ),
                        Text(
                          '@${account.user.username}',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(color: muted),
                        ),
                        const SizedBox(height: 4),
                        Row(children: [
                          Icon(Icons.dns_outlined, size: 14, color: muted),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              account.instance.key,
                              style: theme.textTheme.bodySmall?.copyWith(color: muted),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
            HubSection(
              children: [
                HubRow(
                  leading: const IconTile(Icons.timeline, color: HubColors.slate),
                  title: '我的動態',
                  chevron: true,
                  onTap: () => push(() => ActivityPage(account: account, api: session.api!)),
                ),
                HubRow(
                  leading: const IconTile(Icons.workspaces_outline, color: HubColors.orange),
                  title: '我的群組',
                  chevron: true,
                  onTap: () => push(() => GroupsPage(account: account, api: session.api!)),
                ),
                HubRow(
                  leading: const IconTile(Icons.manage_search, color: HubColors.blue),
                  title: '全域搜尋',
                  chevron: true,
                  onTap: () => push(() => SearchPage(account: account, api: session.api!)),
                ),
              ],
            ),
            HubSection(
              title: '帳號',
              children: [
                for (final (index, saved) in session.accounts.indexed) ...[
                  if (index > 0) const Divider(height: 1, indent: 64),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    leading: Monogram(saved.user.name, size: 32, circle: true),
                    title: Text(
                      '@${saved.user.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(saved.key == account.key ? '${saved.instance.base.host} · 使用中' : saved.instance.base.host),
                    onTap:
                        session.busy ||
                                _removing ||
                                saved.key == account.key
                            ? null
                            : () => session.select(saved),
                    trailing: IconButton(
                      tooltip: '從此裝置移除帳號',
                      icon: const Icon(Icons.logout, size: 20),
                      onPressed: session.busy || _removing
                          ? null
                          : () => _remove(saved),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                    onPressed: () {
                      unawaited(session.endSession());
                    },
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Text('新增或重新連接帳號'),
                  )),
                ),
              ],
            ),
            HubSection(
              title: '外觀',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: AppearancePicker(mode: widget.theme, onChanged: widget.changeTheme),
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text('使用系統配色（Material You）'),
                  subtitle: Text(
                    widget.dynamicColorAvailable
                        ? 'Android 12 以上會依桌布色調產生配色'
                        : '此裝置沒有動態配色',
                  ),
                  value: widget.dynamicColorAvailable && widget.useDynamicColor,
                  onChanged: widget.dynamicColorAvailable
                      ? widget.changeDynamicColor
                      : null,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(
                  'GitLab Mobile',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                BuildInfoLine(load: widget.buildInfoLoader),
                const SizedBox(height: 4),
                const Text(
                  '獨立第三方客戶端 · 非 GitLab 官方產品',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text(
                  '新增與修改需要 Token 的 api 權限；read_api 可用於唯讀。專案角色與實例政策仍會限制操作。',
                  style: TextStyle(fontSize: 12),
                ),
              ]),
            ),
          ],
        ),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final account = session.active;
    if (account == null || session.api == null) {
      return const Scaffold(body: SizedBox());
    }
    return DetailBackScope(
      dispatcher: _backDispatcher,
      depth: 0,
      child: ListenableBuilder(
        listenable: _backDispatcher,
        builder: (context, _) {
          return PopScope<Object?>(
            canPop: _selected == _home && !_backDispatcher.canHandleBack,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              if (_backDispatcher.handleBack()) {
                return;
              }
              if (_selected != _home) {
                _chrome.show();
                setState(() => _selected = _home);
              }
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final useRail = AdaptiveBreakpoints.showNavigationRail(constraints.maxWidth);
                if (_useRail != useRail) {
                  // The rail never hides, so the bar comes back visible after rotating.
                  if (_useRail != null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _chrome.show(); });
                  }
                  _useRail = useRail;
                }
                return Scaffold(
                  body: Row(
                    children: [
                      if (useRail) ...[
                        SafeArea(
                          left: true,
                          top: true,
                          bottom: true,
                          right: false,
                          child: NavigationRail(
                            minWidth: AdaptiveBreakpoints.navigationRailWidth,
                            selectedIndex: _selected,
                            onDestinationSelected: _select,
                            labelType: NavigationRailLabelType.all,
                            destinations: [
                              for (final (icon, selectedIcon, label) in _destinations)
                                NavigationRailDestination(
                                  icon: Icon(icon),
                                  selectedIcon: Icon(selectedIcon),
                                  label: Text(label),
                                ),
                            ],
                          ),
                        ),
                        const VerticalDivider(
                          width: AdaptiveBreakpoints.navigationRailDividerWidth,
                          thickness: 1,
                        ),
                      ],
                      Expanded(
                        key: const ValueKey('shell-main-content-expanded'),
                        child: AdaptiveScope(
                          hasRail: useRail,
                          child: Builder(
                            builder: (contentContext) {
                              final isLtr = Directionality.of(contentContext) == TextDirection.ltr;
                              final content = Column(
                                key: const ValueKey('shell-main-column'),
                                children: [
                                  if (_showRecentFailure)
                                    SafeArea(
                                      bottom: false,
                                      child: FailureNotice(
                                        _recentFailure!,
                                        account: _recentAccount,
                                        resourceLabel: '${_recentProjectId ?? ''}',
                                        onRetry: _retryRecent,
                                        onSwitchAccount: () {
                                          if (_recentProjectId != null) {
                                            widget.session.setPendingResumeTarget(
                                              ResumeTarget(projectId: _recentProjectId, resource: 'project'),
                                            );
                                          }
                                          unawaited(widget.session.endSession(switching: true));
                                        },
                                      ),
                                    ),
                                  if (_showResumeFailure)
                                    SafeArea(
                                      bottom: false,
                                      child: FailureNotice(
                                        _resumeFailure!,
                                        account: _resumeAccount,
                                        resourceLabel: _resumeTarget?.projectPath ??
                                            (_resumeTarget?.projectId != null
                                                ? '${_resumeTarget!.projectId}'
                                                : ''),
                                        onRetry: _retryResume,
                                        onSwitchAccount: () {
                                          final target = _resumeTarget;
                                          if (target != null) {
                                            widget.session.setPendingResumeTarget(target);
                                          }
                                          unawaited(widget.session.endSession(switching: true));
                                        },
                                      ),
                                    ),
                                  Expanded(
                                    key: const ValueKey('shell-indexed-stack-expanded'),
                                    child: NotificationListener<RevealChromeNotification>(
                                      onNotification: (_) {
                                        _chrome.show();
                                        return false;
                                      },
                                      child: NotificationListener<ScrollNotification>(
                                      onNotification: useRail ? null : _chrome.handle,
                                      child: IndexedStack(
                                      key: const ValueKey('shell-indexed-stack'),
                                      index: _selected,
                                      children: [
                                        _pane(
                                          _home,
                                          HomePage(
                                            session: session,
                                            shortcuts: widget.shortcuts,
                                            onOpenInbox: () => _goTo(_inbox, todo: true),
                                            onExplore: () => _goTo(_explore),
                                            onLocate: () => _goTo(_explore, locate: true),
                                            onCreate: () => _goTo(_explore, create: true),
                                          ),
                                        ),
                                        _pane(
                                          _inbox,
                                          _visited.contains(_inbox)
                                              ? InboxPage(account: account, api: session.api!, todoToken: _todoToken)
                                              : const SizedBox(),
                                        ),
                                        // Explore stays built from the start so a launcher search
                                        // or a Home action reaches it through its tokens.
                                        _pane(
                                          _explore,
                                          ProjectsPage(
                                            session: session,
                                            shortcuts: widget.shortcuts,
                                            searchToken: _searchToken,
                                            locatorToken: _locatorToken,
                                            createToken: _createToken,
                                          ),
                                        ),
                                        _pane(
                                          _me,
                                          _visited.contains(_me)
                                              ? _buildMyTab(context, account, session)
                                              : const SizedBox(),
                                        ),
                                      ],
                                      ),
                                    ),
                                    ),
                                  ),
                                ],
                              );
                              return MediaQuery.removePadding(
                                key: const ValueKey('shell-content-padding'),
                                context: contentContext,
                                removeLeft: useRail && isLtr,
                                removeRight: useRail && !isLtr,
                                child: content,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  bottomNavigationBar: useRail ? null : _bottomNavigation(context),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
