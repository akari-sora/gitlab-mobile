import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/external_link.dart';
import '../../shared/resource_share.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import 'graph_work_items_page.dart';
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
  const GroupPage({super.key, required this.account, required this.api, required this.group,
    this.isCurrent, this.ownerChanges, this.initialTab = 0, this.sessionGeneration})
    : assert(initialTab >= 0 && initialTab < 5);
  final Account account;
  final GitLabApi api;
  final Json group;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final int initialTab;
  /// The `SessionController.generation` captured by an explicit owner.
  final int? sessionGeneration;
  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  final _tabKeys = List<GlobalKey>.generate(5, (_) => GlobalKey());
  SessionController? _session;
  int? _sessionGeneration;
  Listenable? _listenedOwner;
  bool _ownerLookupFailed = false;

  int get _id => valueInt(widget.group, 'id');
  String get _path => valueText(widget.group, 'full_path');
  Listenable? get _ownerChanges => widget.ownerChanges ?? _session;
  bool _ownerCurrent() {
    final explicit = widget.isCurrent;
    if (explicit != null) return explicit();
    final session = _session;
    return session != null &&
      (session.active?.key == widget.account.key && identical(session.api, widget.api) &&
       session.generation == _sessionGeneration);
  }
  int? get _routeGeneration => widget.sessionGeneration ?? _sessionGeneration;
  ResourceNavigator get _open => ResourceNavigator(widget.account, widget.api,
    isCurrent: _ownerCurrent, ownerChanges: _ownerChanges, sessionGeneration: _routeGeneration);

  @override
  void initState() {
    super.initState();
    _listenToOwner(widget.ownerChanges);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.isCurrent != null || _session != null || _ownerLookupFailed) return;
    try {
      final candidate = ProviderScope.containerOf(context, listen: false).read(sessionProvider);
      _session = candidate;
      _sessionGeneration = candidate.generation;
      _listenToOwner(candidate);
    } on StateError {
      _ownerLookupFailed = true;
    }
  }

  @override
  void didUpdateWidget(covariant GroupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      _listenToOwner(widget.ownerChanges ?? _session);
    }
  }

  @override
  void dispose() {
    _listenedOwner?.removeListener(_ownerChanged);
    super.dispose();
  }

  void _listenToOwner(Listenable? owner) {
    if (identical(owner, _listenedOwner)) return;
    _listenedOwner?.removeListener(_ownerChanged);
    _listenedOwner = owner;
    owner?.addListener(_ownerChanged);
  }

  void _ownerChanged() {
    if (mounted) setState(() {});
  }

  void _keepSelectedTabVisible(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !context.mounted || !_ownerCurrent()) return;
      final index = DefaultTabController.of(context).index;
      if (index < 0 || index >= _tabKeys.length) return;
      final target = _tabKeys[index].currentContext;
      if (target == null) return;
      unawaited(Scrollable.ensureVisible(target, alignment: 0.5,
        duration: Duration.zero));
    });
  }

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
      MaterialPageRoute<void>(builder: (_) => GroupPage(account: widget.account, api: widget.api, group: value,
        isCurrent: _ownerCurrent, ownerChanges: _ownerChanges, sessionGeneration: _routeGeneration)))),
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

  Widget _graphWorkItems() => GraphWorkItemsPage.group(account: widget.account, api: widget.api,
    namespacePath: _path, isCurrent: _ownerCurrent, ownerChanges: _ownerChanges,
    sessionGeneration: _routeGeneration);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fullPath = valueText(widget.group, 'full_path');
    if (!_ownerCurrent()) {
      return Scaffold(
        appBar: AppBar(title: Text(valueText(widget.group, 'name'))),
        body: gestureSafe(ListView(children: [
          FailureNotice(const ApiFailure(FailureKind.cancelled),
            account: widget.account, resourceLabel: '$fullPath · 群組',
            onSwitchAccount: endSessionFrom(context)),
        ])),
      );
    }
    return DefaultTabController(length: 5, initialIndex: widget.initialTab, child: Builder(builder: (tabContext) {
      // Re-run this builder when accessibility text metrics change so the
      // selected tab is measured again after its label width changes.
      MediaQuery.textScalerOf(tabContext);
      _keepSelectedTabVisible(tabContext);
      return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(valueText(widget.group, 'name'), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 19)),
          Text(fullPath, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
        actions: [
          if (fullPath.isNotEmpty) ResourceShareButton(
            uri: widget.account.instance.projectWeb(fullPath),
            ownerKey: (widget.account.key, widget.api, _id, fullPath),
            isCurrent: _ownerCurrent,
          ),
          if (fullPath.isNotEmpty) IconButton(tooltip: '在 GitLab 開啟', icon: const Icon(Icons.open_in_new, size: 20),
            onPressed: () => openExternal(context, widget.account.instance.projectWeb(fullPath))),
        ],
        bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start,
          tabs: [
            Tab(key: _tabKeys[0], text: '專案'),
            Tab(key: _tabKeys[1], text: '子群組'),
            Tab(key: _tabKeys[2], text: '議題'),
            Tab(key: _tabKeys[3], text: '合併請求'),
            Tab(key: _tabKeys[4], text: '工作項目'),
          ]),
      ),
      body: gestureSafe(TabBarView(children: [
        _projects(), _subgroups(), _workItems('issues'), _workItems('merge_requests'), _graphWorkItems(),
      ])),
      );
    }));
  }
}
