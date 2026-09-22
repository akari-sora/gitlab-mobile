import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/external_link.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/workspace_ui.dart';
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
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int initialTab;
  final bool showBackButton;
  final VoidCallback? onBack;
  final VoidCallback? onDeleted;
  final ValueChanged<int>? onTabChanged;
  @override
  State<ProjectPage> createState() => _ProjectPageState();
}
class _ProjectPageState extends State<ProjectPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late Project _project;
  @override
  void initState() {
    super.initState(); _project = widget.project;
    _tabs = TabController(length: 5, vsync: this, initialIndex: widget.initialTab);
    _tabs.addListener(_tabChanged);
    if (widget.initialTab != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onTabChanged?.call(widget.initialTab);
      });
    }
  }
  void _tabChanged() {
    if (mounted) {
      if (!_tabs.indexIsChanging) {
        widget.onTabChanged?.call(_tabs.index);
      }
      setState(() {});
    }
  }
  @override
  void dispose() {
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final marked = _project.markedForDeletionOn != null;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: widget.showBackButton
            ? BackButton(onPressed: widget.onBack)
            : null,
        title: Text(_project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: marked ? Theme.of(context).appBarTheme.titleTextStyle?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant) : null),
        actions: [IconButton(tooltip: '在 GitLab 開啟', icon: const Icon(Icons.open_in_new, size: 20),
          onPressed: () => openExternal(context, widget.account.instance.projectWeb(_project.path)))],
      ),
    body: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), child: Wrap(spacing: 8, runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusBadge(_project.visibility ?? ''),
          if (marked) const StatusBadge('marked_for_deletion'),
          Text(_project.path, style: Theme.of(context).textTheme.bodySmall),
          if (_project.archived == true) const Text('已封存 · 唯讀'),
        ])),
      TabBar(controller: _tabs, isScrollable: true, tabAlignment: TabAlignment.start,
        tabs: const [Tab(text: '檔案'), Tab(text: '議題'), Tab(text: 'MR'), Tab(text: 'CI'), Tab(text: '更多')]),
      Expanded(child: TabBarView(controller: _tabs, children: [
        RepositoryTab(account: widget.account, api: widget.api, project: _project, active: _tabs.index == 0),
        TabActiveScope(
          isActive: TabActiveScope.of(context) && _tabs.index == 1,
          child: WorkItemsTab(account: widget.account, api: widget.api, project: _project, resource: 'issues'),
        ),
        TabActiveScope(
          isActive: TabActiveScope.of(context) && _tabs.index == 2,
          child: WorkItemsTab(account: widget.account, api: widget.api, project: _project, resource: 'merge_requests'),
        ),
        PipelinesTab(account: widget.account, api: widget.api, project: _project),
        ProjectMoreTab(account: widget.account, api: widget.api, project: _project,
          onChanged: (value) => setState(() => _project = value),
          onDeleted: widget.onDeleted),
      ])),
    ])),
  );
  }
}
