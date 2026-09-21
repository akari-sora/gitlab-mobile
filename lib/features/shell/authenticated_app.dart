import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../core/models.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import '../workspace/projects_page.dart';
import '../workspace/inbox_page.dart';
import '../workspace/editor.dart';
import 'appearance.dart';

class AuthenticatedApp extends StatefulWidget {
  const AuthenticatedApp({
    super.key,
    required this.session,
    required this.appearance,
  });
  final SessionController session;
  final AppearanceController appearance;
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
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GitLab Mobile',
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: widget.appearance.mode,
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: _MobileShell(
        session: widget.session,
        theme: widget.appearance.mode,
        changeTheme: (mode) => unawaited(widget.appearance.select(mode)),
      ),
    ),
  );
}

class _MobileShell extends StatefulWidget {
  const _MobileShell({
    required this.session,
    required this.theme,
    required this.changeTheme,
  });
  final SessionController session;
  final ThemeMode theme;
  final ValueChanged<ThemeMode> changeTheme;
  @override
  State<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<_MobileShell> {
  int _selected = 1;
  bool _removing = false;
  final Set<int> _visited = {1};
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
    return PopScope(
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
            _pane(1, ProjectsPage(session: session)),
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
                      body: ListView(
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
