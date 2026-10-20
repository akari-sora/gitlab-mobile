import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'activity_page.dart';
import 'navigation.dart';
import 'records_feed.dart';
import 'work_item_page.dart';

import '../../l10n/l10n.dart';
/// Search scopes GitLab offers without advanced search. Code, commits,
/// comments and wiki are only searchable inside one project.
Map<String, String> get instanceSearchScopes => {
  'projects': l10n.projects,
  'issues': l10n.issues,
  'merge_requests': l10n.mergeRequests,
  'milestones': l10n.milestones,
  'users': l10n.users,
};
Map<String, String> get projectSearchScopes => {
  'blobs': l10n.code,
  'issues': l10n.issues,
  'merge_requests': l10n.mergeRequests,
  'commits': l10n.commits,
  'notes': l10n.comments,
  'wiki_blobs': 'Wiki',
  'milestones': l10n.milestones,
  'users': l10n.members,
};

String userStateLabel(String state) => switch (state) {
  'blocked' || 'blocked_pending_approval' => l10n.userBlocked,
  'deactivated' => l10n.deactivated,
  'banned' => l10n.userBanned,
  'ldap_blocked' => l10n.ldapBlocked,
  'active' => l10n.userActive,
  _ => state,
};

/// Instance-wide search, or project search when [project] is set. A search
/// runs when submitted or when the scope changes, not on every keystroke:
/// GitLab rate-limits search, and a 429 pauses every request of the client.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.account, required this.api, this.project, this.initialScope});
  final Account account;
  final GitLabApi api;
  final Project? project;
  final String? initialScope;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  String _query = '';
  late String _scope = widget.initialScope ??
      (widget.project == null ? instanceSearchScopes.keys.first : projectSearchScopes.keys.first);

  Map<String, String> get _scopes => widget.project == null ? instanceSearchScopes : projectSearchScopes;
  ResourceNavigator get _open => ResourceNavigator(widget.account, widget.api);

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _projectLabel(Json value) {
    final full = valueText(valueObject(value, 'references'), 'full');
    if (full.isNotEmpty) return full.split(RegExp('[#!%]')).first;
    // Search hits may omit references; the web URL still names the project.
    final web = Uri.tryParse(valueText(value, 'web_url'));
    if (web == null) return '';
    final base = widget.account.instance.base.pathSegments.where((s) => s.isNotEmpty).length;
    final segments = web.pathSegments.skip(base).takeWhile((s) => s != '-').toList();
    return segments.join('/');
  }

  Widget _item(BuildContext context, Json value) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final projectId = valueInt(value, 'project_id');
    final scopedProject = widget.project;
    final projectRef = scopedProject != null ? '${scopedProject.id}' : '$projectId';
    switch (_scope) {
      case 'projects':
        final path = valueText(value, 'path_with_namespace');
        return EntityCard(
          leading: Monogram(valueText(value, 'name'), size: 36),
          title: Text(valueText(value, 'name')),
          subtitle: Text(path),
          body: valueText(value, 'description').trim().isEmpty ? null : Text(valueText(value, 'description').trim(),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          meta: [
            StatusBadge(valueText(value, 'visibility')),
            if (valueInt(value, 'star_count') > 0) MetaChip('${valueInt(value, 'star_count')}', icon: Icons.star_border),
            MetaChip(relativeDate(valueText(value, 'last_activity_at')), icon: Icons.schedule_outlined),
          ],
          onTap: () => _open.project(context, '${valueInt(value, 'id')}'),
        );
      case 'issues' || 'merge_requests':
        final mr = _scope == 'merge_requests';
        return workItemCard(context, value, mr: mr, project: scopedProject == null ? _projectLabel(value) : null,
          onTap: () => _open.workItem(context, projectRef, _scope, valueInt(value, 'iid')));
      case 'milestones':
        return EntityCard(
          leading: Icon(Icons.flag_outlined, color: muted),
          title: Text(valueText(value, 'title')),
          body: valueText(value, 'description').trim().isEmpty ? null : Text(valueText(value, 'description').trim(),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          meta: [
            if (valueText(value, 'state').isNotEmpty) StatusBadge(valueText(value, 'state')),
            if (valueText(value, 'due_date').isNotEmpty) MetaChip(l10n.dueOn(valueText(value, 'due_date')), icon: Icons.event_outlined),
          ],
        );
      case 'users':
        return EntityCard(
          leading: Monogram(valueText(value, 'name', valueText(value, 'username')), size: 36),
          title: Text(valueText(value, 'name', valueText(value, 'username'))),
          subtitle: Text('@${valueText(value, 'username')}'),
          meta: [if (valueText(value, 'state').isNotEmpty && valueText(value, 'state') != 'active')
            MetaChip(userStateLabel(valueText(value, 'state')), icon: Icons.block)],
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => UserPage(
            account: widget.account, api: widget.api, user: value))),
        );
      case 'blobs' || 'wiki_blobs':
        final path = valueText(value, 'path', valueText(value, 'filename'));
        final start = valueInt(value, 'startline');
        final snippet = valueText(value, 'data').trimRight();
        return EntityCard(
          leading: Icon(_scope == 'wiki_blobs' ? Icons.menu_book_outlined : fileIconFor(path), color: muted),
          title: Text(path, style: codeTextStyle(context, fontSize: 13)),
          body: snippet.isEmpty ? null : Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(8)),
            child: Text(snippet, maxLines: 6, overflow: TextOverflow.ellipsis,
              style: codeTextStyle(context, fontSize: 12)),
          ),
          meta: [
            if (valueText(value, 'ref').isNotEmpty) MetaChip(valueText(value, 'ref'), icon: Icons.alt_route, mono: true),
            if (start > 0) MetaChip(l10n.lineStart(start), icon: Icons.format_list_numbered),
          ],
          onTap: _scope == 'blobs' && valueText(value, 'ref').isNotEmpty
              ? () => _open.file(context, projectRef, valueText(value, 'ref'), path, line: start > 0 ? start : null)
              : null,
        );
      case 'commits':
        return EntityCard(
          leading: Icon(Icons.commit, color: muted),
          title: Text(valueText(value, 'title')),
          subtitle: Text(valueText(value, 'author_name')),
          meta: [
            MetaChip(valueText(value, 'short_id', shortSha(valueText(value, 'id'))), mono: true),
            MetaChip(relativeDate(valueText(value, 'committed_date', valueText(value, 'created_at'))), icon: Icons.schedule_outlined),
          ],
          onTap: () => _open.commit(context, projectRef, valueText(value, 'id')),
        );
      case 'notes':
        final type = valueText(value, 'noteable_type');
        final iid = valueInt(value, 'noteable_iid');
        final resource = type == 'MergeRequest' ? 'merge_requests' : type == 'Issue' ? 'issues' : '';
        return EntityCard(
          leading: Monogram(valueText(valueObject(value, 'author'), 'name', '?'), size: 32),
          title: Text(valueText(value, 'body').trim(), maxLines: 4),
          subtitle: Text('@${valueText(valueObject(value, 'author'), 'username')}'),
          meta: [
            if (resource.isNotEmpty && iid > 0) MetaChip('${resource == 'issues' ? '#' : '!'}$iid', mono: true),
            MetaChip(relativeDate(valueText(value, 'created_at')), icon: Icons.schedule_outlined),
          ],
          onTap: resource.isEmpty || iid <= 0 ? null : () => _open.workItem(context, projectRef, resource, iid),
        );
    }
    return EntityCard(title: Text(valueText(value, 'title', valueText(value, 'name'))));
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: const Key('globalSearchField'),
          controller: _input,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) => setState(() => _query = value.trim()),
          decoration: InputDecoration(
            hintText: project == null ? l10n.searchHost(widget.account.instance.base.host) : l10n.searchInName(project.name),
            filled: false,
            border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
            suffixIcon: ValueListenableBuilder<TextEditingValue>(valueListenable: _input, builder: (context, value, _) =>
              value.text.isEmpty ? const SizedBox.shrink() : IconButton(tooltip: l10n.clearSearch, icon: const Icon(Icons.close),
                onPressed: () { _input.clear(); setState(() => _query = ''); _focus.requestFocus(); })),
          ),
        ),
      ),
      body: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(feedGutter(context), 4, feedGutter(context), 8),
          child: Row(children: [
            for (final entry in _scopes.entries) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
              label: Text(entry.value), selected: _scope == entry.key, showCheckmark: false,
              onSelected: (_) => setState(() => _scope = entry.key))),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: _query.isEmpty
          ? SingleChildScrollView(child: EmptyState(
              project == null ? l10n.searchProjectsIssuesMrsUsers : l10n.searchCodeIssuesCommits,
              icon: Icons.manage_search,
              detail: project == null
                ? l10n.searchKeyboardGlobalHint
                : l10n.searchKeyboardCodeHint))
          : RecordsFeed(
              identity: 'search/${project?.id ?? 'all'}/$_scope/$_query',
              account: widget.account,
              resourceLabel: l10n.searchQuery(_query),
              onSwitchAccount: endSessionFrom(context),
              empty: l10n.queryNotFound(_query),
              emptyDetail: l10n.tryAnotherQuery,
              emptyIcon: Icons.search_off,
              load: (next) => widget.api.search(_scope, _query, projectId: project?.id, next: next),
              itemBuilder: _item,
            )),
      ])),
    );
  }
}

/// A user's profile and recent public activity.
class UserPage extends StatelessWidget {
  const UserPage({super.key, required this.account, required this.api, required this.user});
  final Account account;
  final GitLabApi api;
  final Json user;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = valueText(user, 'name', valueText(user, 'username'));
    final id = valueInt(user, 'id');
    return Scaffold(
      appBar: AppBar(title: Text('@${valueText(user, 'username')}')),
      body: gestureSafe(RecordsFeed(
        identity: 'user/$id/events',
        account: account,
        resourceLabel: l10n.userActivity(valueText(user, 'username')),
        onSwitchAccount: endSessionFrom(context),
        empty: l10n.noPublicActivity,
        emptyIcon: Icons.timeline,
        leading: (context, _) => Padding(
          padding: EdgeInsets.fromLTRB(feedGutter(context), 8, feedGutter(context), 8),
          child: Row(children: [
            Monogram(name, size: 56),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: theme.textTheme.titleLarge),
              Text('@${valueText(user, 'username')}', style: theme.textTheme.bodyMedium),
              if (valueText(user, 'web_url').isNotEmpty)
                Text(Uri.tryParse(valueText(user, 'web_url'))?.host ?? '', style: theme.textTheme.bodySmall),
            ])),
          ]),
        ),
        load: (next) => api.events(userId: id, next: next),
        itemBuilder: (context, value) => activityRow(context, value, account: account, api: api),
      )),
    );
  }
}
