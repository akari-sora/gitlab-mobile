import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'records_feed.dart';
import 'work_item_page.dart';

class InboxPage extends StatelessWidget {
  const InboxPage({super.key, required this.account, required this.api});
  final Account account;
  final GitLabApi api;
  @override
  Widget build(BuildContext context) => DefaultTabController(length: 3, child: Scaffold(
    appBar: AppBar(title: const Text('收件匣'), bottom: const TabBar(isScrollable: true,
      tabAlignment: TabAlignment.start, tabs: [Tab(text: '待辦'), Tab(text: '指派給我'), Tab(text: '待我審查')])),
    body: gestureSafe(TabBarView(children: [
      _TodoFeed(account: account, api: api),
      RecordsFeed(identity: 'assigned-issues', empty: '沒有指派給你的議題', account: account,
        resourceLabel: '指派給我的議題', underShell: true, onSwitchAccount: endSessionFrom(context),
        load: (next) => api.records(['issues'], query: {'scope': 'assigned_to_me', 'state': 'opened'}, next: next),
        itemBuilder: (context, data) => _item(context, data, 'issues')),
      RecordsFeed(identity: 'review-requests', empty: '沒有待審查的合併請求', account: account,
        resourceLabel: '待我審查的合併請求', underShell: true, onSwitchAccount: endSessionFrom(context),
        load: (next) => api.records(['merge_requests'], query: {'scope': 'all', 'reviewer_id': '${account.user.id}', 'state': 'opened'}, next: next),
        itemBuilder: (context, data) => _item(context, data, 'merge_requests')),
    ])),
  ));
  Widget _item(BuildContext context, Json data, String resource) => Card(child: ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    leading: Icon(resource == 'issues' ? Icons.adjust : Icons.merge),
    title: Text(valueText(data, 'title'), maxLines: 3, overflow: TextOverflow.ellipsis),
    subtitle: Text('${resource == 'issues' ? '#' : '!'}${valueInt(data, 'iid')} · ${relativeDate(valueText(data, 'updated_at'))}'),
    trailing: const Icon(Icons.chevron_right, size: 18), onTap: () async {
      try {
        final project = await api.project('${requiredInt(data, 'project_id')}');
        if (!context.mounted) { return; }
        await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => WorkItemPage(
          account: account, api: api, project: project, resource: resource, iid: requiredInt(data, 'iid'))));
      } catch (e) { if (context.mounted) { showFailure(context, e); } }
    },
  ));
}
class _TodoFeed extends StatefulWidget {
  const _TodoFeed({required this.account, required this.api});
  final Account account;
  final GitLabApi api;
  @override
  State<_TodoFeed> createState() => _TodoFeedState();
}
class _TodoFeedState extends State<_TodoFeed> {
  final _feed = GlobalKey<RecordsFeedState>();
  final _busy = <int>{};
  @override
  Widget build(BuildContext context) => RecordsFeed(key: _feed, identity: 'todos',
    empty: '待辦已清空', emptyDetail: 'GitLab 指派、提及與你建立的待辦會出現在這裡。',
    account: widget.account, resourceLabel: '待辦', underShell: true,
    onSwitchAccount: endSessionFrom(context),
    load: (next) => widget.api.records(['todos'], query: {'state': 'pending'}, next: next), itemBuilder: (context, data) {
      final target = valueObject(data, 'target'), project = valueObject(data, 'project');
      final id = valueInt(data, 'id');
      final resource = data['target_type'] == 'MergeRequest' ? 'merge_requests' : 'issues';
      final supported = const ['Issue', 'MergeRequest'].contains(data['target_type']);
      return Card(child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(valueText(target, 'title', valueText(data, 'body', 'GitLab 待辦')), maxLines: 3, overflow: TextOverflow.ellipsis),
        subtitle: Text(valueText(project, 'path_with_namespace'), maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(tooltip: '完成此待辦', icon: const Icon(Icons.check_circle_outline),
          onPressed: _busy.contains(id) ? null : () async {
            setState(() => _busy.add(id));
            try {
              await widget.api.markTodoDone(id);
              if (mounted) { await _feed.currentState?.refresh(); }
            } catch (e) { if (context.mounted) { showFailure(context, e); } }
            finally { if (mounted) { setState(() => _busy.remove(id)); } }
          }),
        onTap: !supported ? null : () async {
          try {
            final found = await widget.api.project('${requiredInt(project, 'id')}');
            if (!context.mounted) { return; }
            await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => WorkItemPage(
              account: widget.account, api: widget.api, project: found, resource: resource, iid: requiredInt(target, 'iid'))));
          } catch (e) { if (context.mounted) { showFailure(context, e); } }
        },
      ));
    },
  );
}
