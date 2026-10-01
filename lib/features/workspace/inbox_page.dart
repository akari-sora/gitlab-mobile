import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'records_feed.dart';
import 'search_page.dart';
import 'work_item_page.dart';

class InboxPage extends StatelessWidget {
  const InboxPage({super.key, required this.account, required this.api});
  final Account account;
  final GitLabApi api;
  @override
  Widget build(BuildContext context) => DefaultTabController(length: 4, child: Scaffold(
    appBar: AppBar(title: const Text('收件匣'), actions: [
      IconButton(tooltip: '全域搜尋', icon: const Icon(Icons.manage_search),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => SearchPage(account: account, api: api)))),
    ], bottom: const TabBar(isScrollable: true,
      tabAlignment: TabAlignment.start, tabs: [Tab(text: '待辦'), Tab(text: '指派給我'), Tab(text: '待我審查'), Tab(text: '我建立的')])),
    body: gestureSafe(TabBarView(children: [
      _TodoFeed(account: account, api: api),
      _WorkFeed(account: account, api: api, kind: _WorkKind.assigned),
      RecordsFeed(identity: 'review-requests', empty: '沒有待審查的合併請求', account: account,
        emptyIcon: Icons.rate_review_outlined,
        resourceLabel: '待我審查的合併請求', underShell: true, onSwitchAccount: endSessionFrom(context),
        load: (next) => api.records(['merge_requests'], query: {'scope': 'all', 'reviewer_id': '${account.user.id}',
          'state': 'opened', 'with_labels_details': 'true'}, next: next),
        itemBuilder: (context, data) => inboxWorkItem(context, account, api, data, 'merge_requests')),
      _WorkFeed(account: account, api: api, kind: _WorkKind.created),
    ])),
  ));
}

Widget inboxWorkItem(BuildContext context, Account account, GitLabApi api, Json data, String resource) => workItemCard(context, data,
  mr: resource == 'merge_requests',
  project: valueText(valueObject(data, 'references'), 'full').split(RegExp('[#!]')).first,
  onTap: () async {
    try {
      final project = await api.project('${requiredInt(data, 'project_id')}');
      if (!context.mounted) { return; }
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => WorkItemPage(
        account: account, api: api, project: project, resource: resource, iid: requiredInt(data, 'iid'))));
    } catch (e) { if (context.mounted) { showFailure(context, e); } }
  });

enum _WorkKind { assigned, created }

/// Issues or merge requests assigned to, or created by, the signed-in user
/// across every project, with a switch between the two kinds.
class _WorkFeed extends StatefulWidget {
  const _WorkFeed({required this.account, required this.api, required this.kind});
  final Account account;
  final GitLabApi api;
  final _WorkKind kind;
  @override
  State<_WorkFeed> createState() => _WorkFeedState();
}

class _WorkFeedState extends State<_WorkFeed> {
  late String _resource = widget.kind == _WorkKind.assigned ? 'issues' : 'merge_requests';

  @override
  Widget build(BuildContext context) {
    final assigned = widget.kind == _WorkKind.assigned;
    final mr = _resource == 'merge_requests';
    final scope = assigned ? 'assigned_to_me' : 'created_by_me';
    final label = '${assigned ? '指派給我' : '我建立'}的${mr ? '合併請求' : '議題'}';
    return RecordsFeed(
      identity: '$scope/$_resource', storageId: scope,
      empty: assigned ? (mr ? '沒有指派給你的合併請求' : '沒有指派給你的議題') : (mr ? '你沒有開啟中的合併請求' : '你沒有開啟中的議題'),
      emptyIcon: mr ? Icons.merge : Icons.adjust,
      account: widget.account, resourceLabel: label, underShell: true, onSwitchAccount: endSessionFrom(context),
      leading: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(feedGutter(context), 10, feedGutter(context), 0),
        child: Align(alignment: Alignment.centerLeft, child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'issues', icon: Icon(Icons.adjust, size: 18), label: Text('議題')),
            ButtonSegment(value: 'merge_requests', icon: Icon(Icons.merge, size: 18), label: Text('合併請求')),
          ],
          selected: {_resource},
          onSelectionChanged: (values) => setState(() => _resource = values.first),
        )),
      ),
      load: (next) => widget.api.records([_resource], query: {'scope': scope, 'state': 'opened', 'with_labels_details': 'true'},
        next: next),
      itemBuilder: (context, data) => inboxWorkItem(context, widget.account, widget.api, data, _resource),
    );
  }
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
  bool _clearing = false;

  Future<void> _done(int id, {bool refresh = true}) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await widget.api.markTodoDone(id);
      if (mounted && refresh) await _feed.currentState?.refresh();
    } catch (e) {
      if (mounted) {
        showFailure(context, e);
        await _feed.currentState?.refresh();
      }
    } finally { if (mounted) { setState(() => _busy.remove(id)); } }
  }

  Future<void> _clearAll() async {
    if (_clearing || !await confirmAction(context, '全部標示為完成？', '所有待辦都會從 GitLab 待辦清單移除。')) return;
    if (!mounted) return;
    setState(() => _clearing = true);
    try {
      await widget.api.markAllTodosDone();
      if (mounted) await _feed.currentState?.refresh();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) => RecordsFeed(key: _feed, identity: 'todos',
    empty: '待辦已清空', emptyDetail: 'GitLab 指派、提及與你建立的待辦會出現在這裡。', emptyIcon: Icons.task_alt,
    account: widget.account, resourceLabel: '待辦', underShell: true,
    onSwitchAccount: endSessionFrom(context),
    leading: (context, controller) => controller.items.isEmpty ? const SizedBox(height: 4) : Padding(
      padding: EdgeInsets.fromLTRB(feedGutter(context) + 4, 6, feedGutter(context) - 8, 0),
      child: Row(children: [
        Expanded(child: Text('${controller.items.length}${controller.next == null ? '' : '+'} 則待辦 · 左右滑動可完成',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
        TextButton.icon(
          key: const ValueKey('todos-mark-all-done'),
          onPressed: _clearing ? null : _clearAll,
          icon: const Icon(Icons.done_all, size: 18),
          label: const Text('全部完成'),
        ),
      ]),
    ),
    load: (next) => widget.api.records(['todos'], query: {'state': 'pending'}, next: next), itemBuilder: (context, data) {
      final target = valueObject(data, 'target'), project = valueObject(data, 'project');
      final id = valueInt(data, 'id');
      final resource = data['target_type'] == 'MergeRequest' ? 'merge_requests' : 'issues';
      final supported = const ['Issue', 'MergeRequest'].contains(data['target_type']);
      final action = valueText(data, 'action_name');
      final actionLabel = switch (action) {
        'assigned' => '指派給你', 'mentioned' || 'directly_addressed' => '提及你', 'review_requested' => '請你審查',
        'build_failed' => 'Pipeline 失敗', 'marked' => '你標記的', 'approval_required' => '需要你批准',
        'unmergeable' => '無法合併', 'merge_train_removed' => '已移出合併列車', _ => '',
      };
      final author = valueObject(data, 'author');
      final scheme = Theme.of(context).colorScheme;
      final card = EntityCard(
        titleMaxLines: 3,
        leading: Container(width: 32, height: 32, alignment: Alignment.center,
          decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(10)),
          child: Icon(resource == 'merge_requests' ? Icons.merge : Icons.adjust, size: 18,
            color: scheme.onPrimaryContainer)),
        title: Text(valueText(target, 'title', valueText(data, 'body', 'GitLab 待辦'))),
        subtitle: Text(valueText(project, 'path_with_namespace')),
        meta: [
          if (actionLabel.isNotEmpty) MetaChip(actionLabel, icon: Icons.notifications_none),
          if (valueText(author, 'username').isNotEmpty) MetaChip('@${valueText(author, 'username')}', icon: Icons.person_outline),
          MetaChip(relativeDate(valueText(data, 'updated_at', valueText(data, 'created_at'))), icon: Icons.schedule_outlined),
        ],
        trailing: IconButton(tooltip: '完成此待辦', icon: const Icon(Icons.check_circle_outline),
          onPressed: _busy.contains(id) ? null : () => _done(id)),
        onTap: !supported ? null : () async {
          try {
            final found = await widget.api.project('${requiredInt(project, 'id')}');
            if (!context.mounted) { return; }
            await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => WorkItemPage(
              account: widget.account, api: widget.api, project: found, resource: resource, iid: requiredInt(target, 'iid'))));
          } catch (e) { if (context.mounted) { showFailure(context, e); } }
        },
      );
      Widget background(Alignment alignment) => Container(
        alignment: alignment,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.done, color: scheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Text('完成', style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
        ]),
      );
      return Dismissible(
        key: ValueKey('todo-$id'),
        background: background(Alignment.centerLeft),
        secondaryBackground: background(Alignment.centerRight),
        confirmDismiss: (_) async => !_busy.contains(id),
        // The row leaves the list at once; a failed write reloads it.
        onDismissed: (_) {
          _feed.currentState?.removeItem('$id');
          unawaited(_done(id, refresh: false));
        },
        child: card,
      );
    },
  );
}
