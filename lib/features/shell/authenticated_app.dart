import 'dart:async';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../auth/recent_project.dart';
import '../auth/session_controller.dart';
import '../workspace/project_page.dart';
import '../workspace/projects_page.dart';
import '../workspace/inbox_page.dart';
import '../workspace/editor.dart';
import 'app_shortcuts.dart';
import 'appearance.dart';

class AuthenticatedApp extends StatefulWidget {
  const AuthenticatedApp({
    super.key,
    required this.session,
    required this.appearance,
    required this.shortcuts,
    this.dynamicLight,
    this.dynamicDark,
  });
  final SessionController session;
  final AppearanceController appearance;
  final LauncherShortcuts shortcuts;
  final ColorScheme? dynamicLight;
  final ColorScheme? dynamicDark;
  @override
  State<AuthenticatedApp> createState() => _AuthenticatedAppState();
}

class _AuthenticatedAppState extends State<AuthenticatedApp> {
  // The appearance lives outside this widget on purpose: the whole
  // authenticated tree is rebuilt on every account switch, and the choice is a
  // device preference that must survive both that and a restart.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.appearance,
    builder: (context, _) => DynamicColorBuilder(
      builder: (light, dark) {
        final resolvedLight = widget.dynamicLight ?? flutterScheme(light);
        final resolvedDark = widget.dynamicDark ?? flutterScheme(dark);
        final enabled = widget.appearance.useDynamicColor;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
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
          home: _MobileShell(
            session: widget.session,
            shortcuts: widget.shortcuts,
            theme: widget.appearance.mode,
            changeTheme: (mode) => unawaited(widget.appearance.select(mode)),
            useDynamicColor: enabled,
            dynamicColorAvailable: resolvedLight != null || resolvedDark != null,
            changeDynamicColor: (value) =>
                unawaited(widget.appearance.setUseDynamicColor(value)),
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
    required this.theme,
    required this.changeTheme,
    required this.useDynamicColor,
    required this.dynamicColorAvailable,
    required this.changeDynamicColor,
  });
  final SessionController session;
  final LauncherShortcuts shortcuts;
  final ThemeMode theme;
  final ValueChanged<ThemeMode> changeTheme;
  final bool useDynamicColor;
  final bool dynamicColorAvailable;
  final ValueChanged<bool> changeDynamicColor;
  @override
  State<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<_MobileShell> {
  int _selected = 1;
  int _searchToken = 0;
  bool _removing = false;
  final Set<int> _visited = {1};
  @override
  void initState() {
    super.initState();
    widget.shortcuts.addListener(_onShortcut);
    final account = widget.session.active;
    if (account != null) {
      unawaited(widget.shortcuts.publish(account.key));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_consumeShortcut());
      }
    });
  }

  @override
  void dispose() {
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
    switch (shortcut.kind) {
      case ShortcutKind.inbox:
        setState(() {
          _selected = 0;
          _visited.add(0);
        });
      case ShortcutKind.search:
        setState(() {
          _selected = 1;
          _visited.add(1);
          _searchToken++;
        });
      case ShortcutKind.recent:
        setState(() {
          _selected = 1;
          _visited.add(1);
        });
        await _openRecent(account, api);
    }
  }

  Future<void> _openRecent(Account account, GitLabApi api) async {
    RecentProject? recent;
    try {
      recent = await widget.shortcuts.readRecent(account.key);
    } catch (e) {
      if (mounted) {
        showFailure(context, e);
      }
      return;
    }
    if (!mounted || widget.session.active?.key != account.key || recent == null) {
      return;
    }
    try {
      final project = await api.project('${recent.id}');
      if (!mounted || widget.session.active?.key != account.key) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ProjectPage(account: account, api: api, project: project),
        ),
      );
    } catch (e) {
      if (mounted) {
        showFailure(context, e);
      }
    }
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

  Widget _pane(int index, Widget child) => ExcludeSemantics(
    excluding: _selected != index,
    child: TickerMode(
      enabled: _selected == index,
      child: IgnorePointer(ignoring: _selected != index, child: child),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final account = session.active;
    if (account == null || session.api == null) {
      return const Scaffold(body: SizedBox());
    }
    return PopScope<Object?>(
      canPop: _selected == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() => _selected = 1);
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _selected,
          children: [
            _pane(
              0,
              _visited.contains(0)
                  ? InboxPage(account: account, api: session.api!)
                  : const SizedBox(),
            ),
            _pane(
              1,
              ProjectsPage(
                session: session,
                shortcuts: widget.shortcuts,
                searchToken: _searchToken,
              ),
            ),
            _pane(
              2,
              _visited.contains(2)
                  ? ProjectsPage(session: session, forCi: true)
                  : const SizedBox(),
            ),
            _pane(
              3,
              _visited.contains(3)
                  ? Scaffold(
                      appBar: AppBar(title: const Text('我的')),
                      body: gestureSafe(
                        ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Row(
                            children: [
                              Monogram(account.user.name, size: 56),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      account.user.name,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                    Text(
                                      '@${account.user.username}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      account.instance.key,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 28),
                          Text(
                            '外觀',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final entry in const {
                                ThemeMode.system: '跟隨系統',
                                ThemeMode.light: '淺色',
                                ThemeMode.dark: '深色',
                              }.entries)
                                ChoiceChip(
                                  label: Text(entry.value),
                                  selected: widget.theme == entry.key,
                                  onSelected: (_) =>
                                      widget.changeTheme(entry.key),
                                ),
                            ],
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('使用系統配色（Material You）'),
                            subtitle: Text(
                              widget.dynamicColorAvailable
                                  ? 'Android 12 以上會依桌布色調產生配色'
                                  : '此系統沒有動態配色（需要 Android 12 以上）',
                            ),
                            value: widget.useDynamicColor,
                            onChanged: widget.dynamicColorAvailable
                                ? widget.changeDynamicColor
                                : null,
                          ),
                          const SizedBox(height: 28),
                          Text(
                            '帳號',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 12),
                          for (final saved in session.accounts)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Card(
                                child: ListTile(
                                  leading: Monogram(saved.user.name, size: 32),
                                  title: Text(
                                    '@${saved.user.username}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(saved.instance.base.host),
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
                              ),
                            ),
                          TextButton.icon(
                            onPressed: session.endSession,
                            icon: const Icon(Icons.person_add_outlined),
                            label: const Text('新增或重新連接帳號'),
                          ),
                          const SizedBox(height: 28),
                          const Text(
                            'GitLab Mobile',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
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
                        ],
                      ),
                      ),
                    )
                  : const SizedBox(),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selected,
          onDestinationSelected: (index) => setState(() {
            _selected = index;
            _visited.add(index);
          }),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.inbox_outlined),
              selectedIcon: Icon(Icons.inbox),
              label: '收件匣',
            ),
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: '專案',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_tree_outlined),
              selectedIcon: Icon(Icons.account_tree),
              label: 'CI',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
