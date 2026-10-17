import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/hub_ui.dart';
import '../../shared/workspace_ui.dart';
import 'inbox_page.dart';
import 'records_feed.dart';

enum MyWorkKind { issues, mergeRequests }

/// Whose items a [MyWorkPage] lists.
enum MyWorkScope { assigned, created, review }

/// Issues or merge requests across every project the account can see,
/// filtered to the ones assigned to, created by or (for merge requests)
/// awaiting review from the signed-in user. Opened from Home › 我的工作.
class MyWorkPage extends StatefulWidget {
  const MyWorkPage({super.key, required this.account, required this.api, required this.kind});
  final Account account;
  final GitLabApi api;
  final MyWorkKind kind;
  @override
  State<MyWorkPage> createState() => _MyWorkPageState();
}

class _MyWorkPageState extends State<MyWorkPage> {
  MyWorkScope _scope = MyWorkScope.assigned;
  String _state = 'opened';

  bool get _mr => widget.kind == MyWorkKind.mergeRequests;
  String get _resource => _mr ? 'merge_requests' : 'issues';

  static String _scopeLabel(MyWorkScope scope) => switch (scope) {
    MyWorkScope.assigned => '指派給我',
    MyWorkScope.created => '我建立的',
    MyWorkScope.review => '待我審查',
  };

  Map<String, String> get _states => {
    'opened': '開啟中',
    if (_mr) 'merged': '已合併',
    'closed': '已關閉',
    'all': '全部',
  };

  Map<String, String> get _query => {
    if (_scope == MyWorkScope.review) ...{'scope': 'all', 'reviewer_id': '${widget.account.user.id}'}
    else 'scope': _scope == MyWorkScope.assigned ? 'assigned_to_me' : 'created_by_me',
    if (_state != 'all') 'state': _state,
    'with_labels_details': 'true',
  };

  String get _empty {
    final noun = _mr ? '合併請求' : '議題';
    final state = _state == 'all' ? '' : _states[_state]!;
    return switch (_scope) {
      MyWorkScope.assigned => '沒有指派給你的$state$noun',
      MyWorkScope.created => state.isEmpty ? '你還沒有建立$noun' : '你沒有$state的$noun',
      MyWorkScope.review => '沒有待你審查的$state$noun',
    };
  }

  Widget _filters(BuildContext context) {
    final gutter = feedGutter(context);
    final scopes = [MyWorkScope.assigned, MyWorkScope.created, if (_mr) MyWorkScope.review];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 0),
      child: Row(children: [
        PopupMenuButton<String>(
          key: const ValueKey('my-work-state'),
          tooltip: '狀態',
          initialValue: _state,
          onSelected: (value) => setState(() => _state = value),
          itemBuilder: (_) => [
            for (final entry in _states.entries)
              CheckedPopupMenuItem(value: entry.key, checked: _state == entry.key, child: Text(entry.value)),
          ],
          child: FilterPill(label: _states[_state]!, dropdown: true, selected: true),
        ),
        const SizedBox(width: 8),
        for (final scope in scopes) Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilterPill(
            label: _scopeLabel(scope),
            selected: _scope == scope,
            onTap: () => setState(() => _scope = scope),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _mr ? '合併請求' : '議題';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: gestureSafe(RecordsFeed(
        identity: '$_resource/${_scope.name}/$_state',
        storageId: 'my-work-$_resource',
        empty: _empty,
        emptyIcon: _mr ? Icons.merge : Icons.adjust,
        account: widget.account,
        resourceLabel: '${_scopeLabel(_scope)}的$title',
        onSwitchAccount: endSessionFrom(context),
        leading: (context, _) => _filters(context),
        load: (next) => widget.api.records([_resource], query: _query, next: next),
        itemBuilder: (context, data) => inboxWorkItem(context, widget.account, widget.api, data, _resource),
      )),
    );
  }
}
