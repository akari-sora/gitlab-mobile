import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import '../auth/session_controller.dart';
import '../projects/projects_screen.dart';
import '../projects/project_detail_screen.dart';
import '../code/file_args.dart';
import '../code/file_screen.dart';
import '../../shared/theme.dart';

class AuthenticatedApp extends StatefulWidget {
  const AuthenticatedApp({super.key, required this.session});
  final SessionController session;
  @override
  State<AuthenticatedApp> createState() => _AuthenticatedAppState();
}
class _AuthenticatedAppState extends State<AuthenticatedApp> {
  late final GoRouter router;
  @override
  void initState() {
    super.initState();
    final session = widget.session;
    router = GoRouter(initialLocation: '/projects', routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => Scaffold(body: shell, bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (index) => shell.goBranch(index),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.inbox_outlined), label: '收件匣'),
            NavigationDestination(icon: Icon(Icons.folder_outlined), label: '專案'),
            NavigationDestination(icon: Icon(Icons.account_tree_outlined), label: 'CI'),
            NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
          ],
        )),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/inbox', builder: (context, _) => const _PendingScreen(
            title: '收件匣', text: '尚未接入 GitLab 待辦、待我審查與我的指派。\n此頁是開發範圍說明，不是空的通知列表。'))]),
          StatefulShellBranch(routes: [GoRoute(path: '/projects', builder: (context, _) => ProjectsScreen(session: session),
            routes: [GoRoute(path: ':id', builder: (context, state) => ProjectDetailScreen(id: state.pathParameters['id']!, session: session))])]),
          StatefulShellBranch(routes: [GoRoute(path: '/ci', builder: (context, _) => const _PendingScreen(
            title: 'CI', text: '尚未接入 Pipeline、Job 與 Log。\n這個版本不觸發或取消任何 CI 工作。'))]),
          StatefulShellBranch(routes: [GoRoute(path: '/me', builder: (context, _) => _AccountScreen(session: session))]),
        ],
      ),
      // Focus route is outside the shell, so code reading hides the tab bar.
      GoRoute(path: '/file', builder: (context, state) => state.extra is FileArgs
        ? FileScreen(args: state.extra! as FileArgs, session: session)
        : const _PendingScreen(title: '缺少檔案上下文', text: '請從專案檔案列表重新開啟。')),
    ]);
  }
  @override
  void dispose() { router.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'GitLab Mobile', debugShowCheckedModeBanner: false,
    theme: appTheme(Brightness.light), darkTheme: appTheme(Brightness.dark),
    locale: const Locale('zh', 'TW'),
    localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
    routerConfig: router,
  );
}

class _PendingScreen extends StatelessWidget {
  const _PendingScreen({required this.title, required this.text});
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(title)),
    body: SafeArea(child: ListView(padding: const EdgeInsets.all(24), children: [
      const Icon(Icons.construction_outlined, size: 40), const SizedBox(height: 20),
      Text('後續開發項目', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12), Text(text),
    ])));
}

class _AccountScreen extends StatelessWidget {
  const _AccountScreen({required this.session});
  final SessionController session;
  @override
  Widget build(BuildContext context) {
    final account = session.active!;
    return Scaffold(appBar: AppBar(title: const Text('我的')), body: SafeArea(child: ListView(
      padding: const EdgeInsets.all(16), children: [
        Text(account.user.name, style: Theme.of(context).textTheme.headlineSmall),
        Text('@${account.user.username} · ID ${account.user.id}'),
        const SizedBox(height: 8), SelectableText(account.instance.key),
        const Divider(height: 32),
        const ListTile(leading: Icon(Icons.lock_outline), title: Text('安全儲存'),
          subtitle: Text('只保存 Token 與帳號身分；未啟用私有內容磁碟快取。')),
        const ListTile(leading: Icon(Icons.science_outlined), title: Text('G0 開發預覽'),
          subtitle: Text('PAT 唯讀切片。OAuth、寫入、推播、離線草稿與真機驗收尚未完成。')),
        OutlinedButton.icon(onPressed: session.endSession, icon: const Icon(Icons.switch_account_outlined),
          label: const Text('切換／加入帳號')),
        const SizedBox(height: 12),
        TextButton(onPressed: () async {
          final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
            title: const Text('從此裝置移除帳號？'), content: const Text('移除本機憑證，不會撤銷 GitLab 伺服器上的 Token。'),
            actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('移除'))],
          ));
          if (accepted == true) unawaited(session.remove(account));
        }, child: const Text('移除此裝置上的帳號')),
        if (session.message != null) Text(session.message!),
      ],
    )));
  }
}
