import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/project_locator.dart';
import '../../features/auth/session_controller.dart';
import '../../shared/error_panel.dart';
import '../../shared/external_link.dart';
import 'project_controller.dart';

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key, required this.session});
  final SessionController session;
  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}
class _ProjectsScreenState extends State<ProjectsScreen> {
  late final ProjectController controller;
  final search = TextEditingController();
  bool opening = false;
  @override
  void initState() {
    super.initState();
    controller = ProjectController(widget.session.api!);
    unawaited(controller.refresh());
  }
  @override
  void dispose() { controller.dispose(); search.dispose(); super.dispose(); }

  Future<void> _openProject() async {
    final text = await showDialog<String>(context: context,
      builder: (context) => const _ProjectLocatorDialog());
    if (text == null || !mounted) return;
    final session = widget.session;
    final account = session.active;
    final api = session.api;
    final generation = session.generation;
    if (account == null || api == null) return;
    setState(() => opening = true);
    try {
      final id = projectLocator(account.instance, text);
      final browser = id.contains('/') ? account.instance.projectWeb(id) : null;
      while (mounted && session.generation == generation) {
        try {
          final project = await api.project(id);
          if (mounted && session.generation == generation) {
            await context.push('/projects/${project.id}');
          }
          return;
        } catch (e) {
          if (!mounted || session.generation != generation) return;
          final action = await showModalBottomSheet<_OpenFailureAction>(
            context: context, isScrollControlled: true,
            builder: (sheetContext) => SafeArea(child: SingleChildScrollView(child: ErrorPanel(
              failure: safeFailure(e), account: account, resourceLabel: id,
              onRetry: () => Navigator.pop(sheetContext, _OpenFailureAction.retry),
              onSwitchAccount: () => Navigator.pop(sheetContext, _OpenFailureAction.switchAccount),
              onOpenBrowser: browser == null ? null : () {
                unawaited(openExternal(sheetContext, browser));
              },
            ))),
          );
          if (!mounted || session.generation != generation) return;
          if (action == _OpenFailureAction.switchAccount) { session.endSession(); return; }
          if (action != _OpenFailureAction.retry) return;
        }
      }
    } on FormatException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('連結格式不正確：請使用同實例、無憑證且無相對路徑的專案 URL，或完整路徑／ID。')));
      }
    } finally { if (mounted) setState(() => opening = false); }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: controller, builder: (context, _) {
    final account = widget.session.active!;
    return Scaffold(
      appBar: AppBar(title: const Text('專案'), actions: [
        IconButton(tooltip: '以連結或路徑開啟', onPressed: opening ? null : () { unawaited(_openProject()); },
          icon: opening ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add_link)),
        IconButton(tooltip: '帳號與設定', onPressed: () => context.go('/me'), icon: const Icon(Icons.account_circle_outlined)),
      ]),
      body: SafeArea(child: RefreshIndicator(onRefresh: controller.refresh,
        child: CustomScrollView(key: const PageStorageKey('projects-scroll'), physics: const AlwaysScrollableScrollPhysics(), slivers: [
          SliverPadding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), sliver: SliverToBoxAdapter(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${account.instance.key} · @${account.user.username}'),
              const SizedBox(height: 16),
              TextField(controller: search, textInputAction: TextInputAction.search,
                decoration: InputDecoration(labelText: '搜尋專案', prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(tooltip: '執行搜尋', icon: const Icon(Icons.arrow_forward),
                    onPressed: () { unawaited(controller.search(controller.scope, search.text)); })),
                onSubmitted: (text) { unawaited(controller.search(controller.scope, text)); }),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final scope in ProjectScope.values) ChoiceChip(
                  label: Text(switch (scope) { ProjectScope.member => '我的專案',
                    ProjectScope.starred => '星標', ProjectScope.accessibleSearch => '可存取搜尋' }),
                  selected: controller.scope == scope,
                  onSelected: (_) { unawaited(controller.search(scope, search.text)); },
                ),
              ]),
              const SizedBox(height: 8),
              Text(switch (controller.scope) {
                ProjectScope.member => '只列 membership 範圍；不是所有可存取專案。',
                ProjectScope.starred => 'GitLab 伺服器的星標；本機釘選尚未實作。',
                ProjectScope.accessibleSearch => '搜尋可見專案，不限 membership；可含公開專案。',
              }, style: Theme.of(context).textTheme.bodySmall),
              if (controller.fetchedAt != null) Text('更新於 ${controller.fetchedAt!.toLocal().toString().substring(11, 19)}',
                style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              if (controller.loading) const LinearProgressIndicator(),
            ],
          ))),
          if (controller.error != null) SliverToBoxAdapter(child: ErrorPanel(
            failure: controller.error!, account: account,
            onRetry: () { unawaited(controller.refresh()); }, onSwitchAccount: widget.session.endSession,
          )),
          if (!controller.loading && controller.items.isEmpty && controller.error == null)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Text('此範圍沒有專案。可改用可存取搜尋，或貼上專案連結。'))),
          SliverList(delegate: SliverChildBuilderDelegate((context, index) {
            final project = controller.items[index];
            return Card(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: ListTile(contentPadding: const EdgeInsets.all(16),
                leading: const Icon(Icons.folder_outlined),
                title: Text(project.name),
                subtitle: Padding(padding: const EdgeInsets.only(top: 8), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(project.path), const SizedBox(height: 4),
                    Wrap(spacing: 8, children: [Text(project.visibilityLabel),
                      if (project.archived == true) const Text('已封存')]),
                  ],
                )),
                trailing: const Icon(Icons.chevron_right),
                onTap: () { unawaited(context.push('/projects/${project.id}')); },
              ));
          }, childCount: controller.items.length)),
          if (controller.pageError != null) SliverToBoxAdapter(child: ErrorPanel(
            failure: controller.pageError!, compact: true,
            onRetry: () { unawaited(controller.loadMore()); },
          )),
          if (controller.next != null) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16),
            child: OutlinedButton(onPressed: controller.loadingMore ? null : () { unawaited(controller.loadMore()); },
              child: Text(controller.loadingMore ? '正在載入…' : '載入下一頁')))),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ]),
      )),
    );
  });
}

enum _OpenFailureAction { retry, switchAccount }

// Controller lifetime follows the dialog's actual route disposal, including
// its reverse transition; never dispose it immediately after Navigator.pop.
class _ProjectLocatorDialog extends StatefulWidget {
  const _ProjectLocatorDialog();
  @override
  State<_ProjectLocatorDialog> createState() => _ProjectLocatorDialogState();
}
class _ProjectLocatorDialogState extends State<_ProjectLocatorDialog> {
  final input = TextEditingController();
  @override
  void dispose() { input.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('開啟專案'),
    content: TextField(controller: input, autofocus: true,
      decoration: const InputDecoration(labelText: '專案 URL、完整路徑或 ID',
        hintText: 'group/subgroup/project'),
      onSubmitted: (value) => Navigator.pop(context, value)),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.pop(context, input.text), child: const Text('開啟'))],
  );
}
