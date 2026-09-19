import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../auth/session_controller.dart';
import '../code/file_args.dart';
import '../../shared/error_panel.dart';
import '../../shared/external_link.dart';
import 'repository_controller.dart';

class ProjectDetailScreen extends StatefulWidget {
  const ProjectDetailScreen({super.key, required this.id, required this.session});
  final String id;
  final SessionController session;
  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  late RepositoryController controller;
  @override
  void initState() { super.initState(); _createController(); }

  void _createController() {
    controller = RepositoryController(widget.session.api!, widget.id);
    unawaited(controller.initialize());
  }

  @override
  void didUpdateWidget(covariant ProjectDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || controller.api != widget.session.api) {
      controller.dispose(); _createController();
    }
  }

  @override
  void dispose() { controller.dispose(); super.dispose(); }

  void _up() {
    final path = controller.path;
    if (path.isEmpty) { context.pop(); return; }
    unawaited(controller.openDirectory(path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : ''));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final account = widget.session.active!;
      final p = controller.project;
      final sha = controller.sha;
      final path = controller.path;
      final browser = p == null ? null : account.instance.projectWeb(p.path);
      return PopScope(
        canPop: path.isEmpty,
        onPopInvokedWithResult: (didPop, _) { if (!didPop) _up(); },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(tooltip: path.isEmpty ? '返回專案' : '上一層目錄',
              onPressed: _up, icon: const Icon(Icons.arrow_back)),
            title: Text(p?.name ?? '專案'),
            actions: [if (browser != null) IconButton(
              tooltip: '以系統瀏覽器開啟', icon: const Icon(Icons.open_in_browser),
              onPressed: () { unawaited(openExternal(context, browser)); })],
          ),
          body: SafeArea(child: RefreshIndicator(
            onRefresh: controller.refresh,
            child: CustomScrollView(
              key: PageStorageKey('tree:${account.key}:${p?.id}:$sha:$path'),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(padding: const EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (p != null) ...[
                        Text(p.path, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text('${p.visibilityLabel} · @${account.user.username}'),
                        if (p.description?.isNotEmpty == true) Padding(
                          padding: const EdgeInsets.only(top: 12), child: Text(p.description!)),
                        const SizedBox(height: 16),
                        if (sha != null) SelectableText('${p.defaultBranch} · ${sha.substring(0, 8)}',
                          style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 8), const Text('檔案 · 固定提交版本'),
                        const Text('此輪只開放檔案閱讀；MR、議題與 CI 在後續階段接入。'),
                        const Divider(height: 28),
                      ],
                      if (controller.loading) const LinearProgressIndicator(),
                      if (controller.isEmptyRepository && !controller.loading)
                        const Text('此專案尚無預設分支或為空儲存庫。'),
                      if (sha != null) ...[
                        Text(path.isEmpty ? '/' : '/$path', style: Theme.of(context).textTheme.titleMedium),
                        if (controller.fetchedAt != null)
                          Text('此目錄更新於 ${controller.fetchedAt!.toLocal().toString().substring(11, 19)}',
                            style: Theme.of(context).textTheme.bodySmall),
                        if (path.isNotEmpty) ListTile(
                          leading: const Icon(Icons.drive_folder_upload_outlined),
                          title: const Text('上一層'), onTap: _up),
                      ],
                    ],
                  )),
                ),
                if (controller.error != null) SliverToBoxAdapter(child: ErrorPanel(
                  failure: controller.error!, account: account, resourceLabel: p?.path ?? widget.id,
                  onRetry: () { unawaited(controller.refresh()); },
                  onSwitchAccount: widget.session.endSession,
                  onOpenBrowser: browser == null ? null : () { unawaited(openExternal(context, browser)); },
                )),
                if (sha != null && controller.entries.isEmpty && !controller.loading && controller.error == null)
                  const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(24), child: Text('此目錄沒有項目。'))),
                SliverList(delegate: SliverChildBuilderDelegate((context, index) {
                  final entry = controller.entries[index];
                  return ListTile(
                    key: ValueKey(entry.path),
                    leading: Icon(entry.isDirectory ? Icons.folder_outlined :
                      entry.type == 'commit' ? Icons.link : Icons.description_outlined),
                    title: Text(entry.name),
                    subtitle: !entry.isDirectory && !entry.isTextCandidate
                      ? Text('類型：${entry.type} · 此版本不展開') : null,
                    trailing: entry.isDirectory || entry.isTextCandidate ? const Icon(Icons.chevron_right) : null,
                    onTap: entry.isDirectory ? () { unawaited(controller.openDirectory(entry.path)); }
                      : entry.isTextCandidate && p != null && sha != null
                        ? () { unawaited(context.push('/file', extra: FileArgs(p, sha, entry.path))); } : null,
                  );
                }, childCount: controller.entries.length)),
                if (controller.pageError != null) SliverToBoxAdapter(child: ErrorPanel(
                  failure: controller.pageError!, compact: true,
                  onRetry: () { unawaited(controller.loadMore()); },
                )),
                if (controller.next != null) SliverToBoxAdapter(child: Padding(
                  padding: const EdgeInsets.all(16), child: OutlinedButton(
                    onPressed: controller.loading || controller.loadingMore ? null
                      : () { unawaited(controller.loadMore()); },
                    child: Text(controller.loadingMore ? '正在載入…' : '載入更多檔案'),
                  ),
                )),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          )),
        ),
      );
    },
  );
}
