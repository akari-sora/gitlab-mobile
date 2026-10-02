import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/external_link.dart';
import '../../shared/workspace_ui.dart';
import 'navigation.dart';
import 'records_feed.dart';
import 'work_item_page.dart';

/// One group as a dense row with its namespace path.
Widget groupRow(BuildContext context, Json value, {required VoidCallback onTap}) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  final name = valueText(value, 'name');
  final fullPath = valueText(value, 'full_path');
  final (visibility, icon) = statusStyle(valueText(value, 'visibility'));
  return SemanticButton(
    label: [name, fullPath, visibility].where((part) => part.isNotEmpty).join(' · '),
    onTap: onTap,
    child: InkWell(onTap: onTap, child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Monogram(name, size: 38),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontSize: 15)),
          const SizedBox(height: 2),
          Row(children: [
            Tooltip(message: visibility, excludeFromSemantics: true, child: Icon(icon, size: 13, color: muted)),
            const SizedBox(width: 4),
            Flexible(child: Text(fullPath, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: muted))),
          ]),
          if (valueText(value, 'description').trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(valueText(value, 'description').trim(), maxLines: 2, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall)),
        ])),
        Icon(Icons.chevron_right, size: 18, color: muted),
      ]),
    )),
  );
}

/// Groups the signed-in user belongs to.
class GroupsPage extends StatefulWidget {
  const GroupsPage({super.key, required this.account, required this.api});
  final Account account;
  final GitLabApi api;
  @override
  State<GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends State<GroupsPage> {
  String _query = '';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('我的群組')),
    body: gestureSafe(RecordsFeed(
      identity: 'groups/mine/$_query', storageId: 'groups/mine',
      account: widget.account,
      resourceLabel: '群組列表',
      onSwitchAccount: endSessionFrom(context),
      empty: _query.isEmpty ? '你還沒有加入群組' : '找不到符合的群組',
      emptyIcon: Icons.workspaces_outline,
      grouped: true,
      leading: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(feedGutter(context), 8, feedGutter(context), 4),
        child: TextField(
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: '搜尋群組', prefixIcon: Icon(Icons.search)),
          onSubmitted: (value) => setState(() => _query = value.trim()),
        ),
      ),
      load: (next) => widget.api.groups(search: _query, next: next),
      itemBuilder: (context, value) => groupRow(context, value, onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => GroupPage(account: widget.account, api: widget.api, group: value)))),
    )),
  );
}

/// A group: its projects, subgroups, and open issues and merge requests.
class GroupPage extends StatefulWidget {
  const GroupPage({super.key, required this.account, required this.api, required this.group});
  final Account account;
  final GitLabApi api;
  final Json group;
  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  int get _id => valueInt(widget.group, 'id');
  ResourceNavigator get _open => ResourceNavigator(widget.account, widget.api);

  Widget _projects() => RecordsFeed(
    identity: 'group/$_id/projects',
    account: widget.account,
    resourceLabel: '${valueText(widget.group, 'full_path')} · 專案',
    onSwitchAccount: endSessionFrom(context),
    empty: '這個群組沒有專案',
    emptyIcon: Icons.folder_off_outlined,
    grouped: true,
    load: (next) => widget.api.groupProjects(_id, next: next),
    itemBuilder: (context, value) {
      final theme = Theme.of(context);
      final muted = theme.colorScheme.onSurfaceVariant;
      final name = valueText(value, 'name');
      final (visibility, icon) = statusStyle(valueText(value, 'visibility'));
      void tap() => _open.project(context, '${valueInt(value, 'id')}');
      return SemanticButton(
        label: [name, valueText(value, 'path_with_namespace'), visibility].join(' · '),
        onTap: tap,
        child: InkWell(onTap: tap, child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Monogram(name, size: 36),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontSize: 15)),
              const SizedBox(height: 2),
              Row(children: [
                Icon(icon, size: 13, color: muted),
                const SizedBox(width: 4),
                Flexible(child: Text('${valueText(value, 'path')} · ${relativeDate(valueText(value, 'last_activity_at'))}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted))),
              ]),
              if (valueText(value, 'description').trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
                child: Text(valueText(value, 'description').trim(), maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall)),
            ])),
            Icon(Icons.chevron_right, size: 18, color: muted),
          ]),
        )),
      );
    },
  );

  Widget _subgroups() => RecordsFeed(
    identity: 'group/$_id/subgroups',
    account: widget.account,
    resourceLabel: '${valueText(widget.group, 'full_path')} · 子群組',
    onSwitchAccount: endSessionFrom(context),
    empty: '沒有子群組',
    emptyIcon: Icons.workspaces_outline,
    grouped: true,
    load: (next) => widget.api.subgroups(_id, next: next),
    itemBuilder: (context, value) => groupRow(context, value, onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => GroupPage(account: widget.account, api: widget.api, group: value)))),
  );

  Widget _workItems(String resource) => RecordsFeed(
    identity: 'group/$_id/$resource',
    account: widget.account,
    resourceLabel: '${valueText(widget.group, 'full_path')} · ${resource == 'issues' ? '議題' : '合併請求'}',
    onSwitchAccount: endSessionFrom(context),
    empty: resource == 'issues' ? '沒有開啟中的議題' : '沒有開啟中的合併請求',
    emptyIcon: resource == 'issues' ? Icons.adjust : Icons.merge,
    load: (next) => widget.api.records(['groups', '$_id', resource],
      query: {'state': 'opened', 'order_by': 'updated_at', 'sort': 'desc', 'with_labels_details': 'true'}, next: next),
    itemBuilder: (context, value) => workItemCard(context, value, mr: resource == 'merge_requests',
      project: valueText(valueObject(value, 'references'), 'full').split(RegExp('[#!]')).first,
      onTap: () => _open.workItem(context, '${valueInt(value, 'project_id')}', resource, valueInt(value, 'iid'))),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fullPath = valueText(widget.group, 'full_path');
    return DefaultTabController(length: 4, child: Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(valueText(widget.group, 'name'), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 19)),
          Text(fullPath, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
        actions: [
          if (fullPath.isNotEmpty) IconButton(tooltip: '在 GitLab 開啟', icon: const Icon(Icons.open_in_new, size: 20),
            onPressed: () => openExternal(context, widget.account.instance.projectWeb(fullPath))),
        ],
        bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start,
          tabs: [Tab(text: '專案'), Tab(text: '子群組'), Tab(text: '議題'), Tab(text: '合併請求')]),
      ),
      body: gestureSafe(TabBarView(children: [_projects(), _subgroups(), _workItems('issues'), _workItems('merge_requests')])),
    ));
  }
}
