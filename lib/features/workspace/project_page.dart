import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/external_link.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/scroll_chrome.dart';
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
  final _chrome = ScrollChromeController();
  final _focus = DetailFocus();
  late Project _project;
  @override
  void initState() {
    super.initState(); _project = widget.project;
    _focus.addListener(_focusChanged);
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
      _chrome.show();
      setState(() {});
    }
  }
  @override
  void didUpdateWidget(covariant ProjectPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project != widget.project) {
      _project = widget.project;
    }
  }
  void _focusChanged() {
    if (!mounted) return;
    _chrome.show();
    setState(() {});
  }
  @override
  void dispose() {
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _chrome.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final marked = _project.markedForDeletionOn != null;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final (visibilityLabel, visibilityIcon) = statusStyle(_project.visibility ?? '');
    final appBar = AppBar(
      primary: false,
      automaticallyImplyLeading: false,
      leading: widget.showBackButton ? BackButton(onPressed: widget.onBack) : null,
      titleSpacing: widget.showBackButton ? 0 : null,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(_project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 19, color: marked ? muted : null)),
        Row(children: [
          Tooltip(message: visibilityLabel, excludeFromSemantics: true, child: Semantics(label: _project.visibilityLabel,
            child: Icon(visibilityIcon, size: 13, color: muted))),
          const SizedBox(width: 4),
          Flexible(flex: 3, child: Text(_project.path, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: muted))),
          if (marked) ...[const SizedBox(width: 6), const Flexible(child: StatusBadge('marked_for_deletion'))],
          if (_project.archived == true) ...[
            const SizedBox(width: 6),
            Flexible(flex: 2, child: Text('已封存 · 唯讀', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: muted))),
          ],
        ]),
      ]),
      actions: [IconButton(tooltip: '在 GitLab 開啟', icon: const Icon(Icons.open_in_new, size: 20),
        onPressed: () => openExternal(context, widget.account.instance.projectWeb(_project.path)))],
    );
    // An issue or MR opened in place on a phone owns the screen: the project
    // header and tabs step aside and horizontal swipes stay with the detail.
    final focused = _focus.active;
    final crowded = MediaQuery.textScalerOf(context).scale(14) > 14 * 1.3;
    return Scaffold(
        body: NotificationListener<ScrollNotification>(
          onNotification: _chrome.handle,
          child: StatusBarInset(child: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!focused) CollapsingChrome(visible: _chrome, child: appBar),
              if (!focused) TabBar(controller: _tabs, indicatorSize: TabBarIndicatorSize.tab,
                isScrollable: crowded, tabAlignment: crowded ? TabAlignment.start : null,
                tabs: const [Tab(text: '檔案'), Tab(text: '議題'), Tab(text: 'MR'), Tab(text: 'CI'), Tab(text: '更多')]),
              Expanded(key: const ValueKey('project-tab-body'), child: DetailFocusScope(focus: _focus, child: TabBarView(controller: _tabs,
                physics: focused ? const NeverScrollableScrollPhysics() : null, children: [
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
              ]))),
            ]))),
        ),
    );
  }
}
