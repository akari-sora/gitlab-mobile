import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/hub_ui.dart';
import '../../shared/workspace_ui.dart';
import 'inbox_page.dart';
import 'records_feed.dart';

import '../../l10n/l10n.dart';
enum MyWorkKind { issues, mergeRequests }

/// Whose items a [MyWorkPage] lists.
enum MyWorkScope { assigned, created, review }

/// Issues or merge requests across every project the account can see,
/// filtered to the ones assigned to, created by or (for merge requests)
/// awaiting review from the signed-in user. Opened from Home › 我的工作.
class MyWorkPage extends StatefulWidget {
  const MyWorkPage({super.key, required this.account, required this.api, required this.kind,
    this.initialScope = MyWorkScope.assigned});
  final Account account;
  final GitLabApi api;
  final MyWorkKind kind;

  /// The pill selected on open. [MyWorkScope.review] applies to merge
  /// requests only; issues fall back to [MyWorkScope.assigned].
  final MyWorkScope initialScope;
  @override
  State<MyWorkPage> createState() => _MyWorkPageState();
}

class _MyWorkPageState extends State<MyWorkPage> {
  late MyWorkScope _scope;
  String _state = 'opened';

  bool get _mr => widget.kind == MyWorkKind.mergeRequests;

  @override
  void initState() {
    super.initState();
    _scope = widget.initialScope == MyWorkScope.review && !_mr ? MyWorkScope.assigned : widget.initialScope;
  }
  String get _resource => _mr ? 'merge_requests' : 'issues';

  static String _scopeLabel(MyWorkScope scope) => switch (scope) {
    MyWorkScope.assigned => l10n.assignedToMe,
    MyWorkScope.created => l10n.createdByMe,
    MyWorkScope.review => l10n.reviewRequests,
  };

  Map<String, String> get _states => {
    'opened': l10n.statusOpen,
    if (_mr) 'merged': l10n.merged,
    'closed': l10n.statusClosed,
    'all': l10n.filterAll,
  };

  Map<String, String> get _query => {
    if (_scope == MyWorkScope.review) ...{'scope': 'all', 'reviewer_id': '${widget.account.user.id}'}
    else 'scope': _scope == MyWorkScope.assigned ? 'assigned_to_me' : 'created_by_me',
    if (_state != 'all') 'state': _state,
    'with_labels_details': 'true',
  };

  String get _empty {
    final noun = _mr ? l10n.mergeRequestsLabel : l10n.issuesLabel;
    final state = _state == 'all' ? '' : _states[_state]!;
    return switch (_scope) {
      MyWorkScope.assigned => l10n.noAssignedStateNoun(state, noun),
      MyWorkScope.created => state.isEmpty ? l10n.noneCreatedNoun(noun) : l10n.noStateNoun(state, noun),
      MyWorkScope.review => l10n.noReviewStateNoun(state, noun),
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
          tooltip: l10n.status,
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
    final title = _mr ? l10n.mergeRequests : l10n.issues;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: gestureSafe(RecordsFeed(
        identity: '$_resource/${_scope.name}/$_state',
        storageId: 'my-work-$_resource',
        empty: _empty,
        emptyIcon: _mr ? Icons.merge : Icons.adjust,
        account: widget.account,
        resourceLabel: l10n.scopeTitle(_scopeLabel(_scope), title),
        onSwitchAccount: endSessionFrom(context),
        leading: (context, _) => _filters(context),
        load: (next) => widget.api.records([_resource], query: _query, next: next),
        itemBuilder: (context, data) => inboxWorkItem(context, widget.account, widget.api, data, _resource),
      )),
    );
  }
}
