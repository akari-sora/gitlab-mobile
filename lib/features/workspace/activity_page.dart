import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'navigation.dart';
import 'records_feed.dart';

/// Project names for activity rows that span projects, fetched once per
/// project and client. Bound to the [GitLabApi] instance, so an account switch
/// (which closes the client) never reuses another account's answers.
final _projectNames = Expando<Map<int, Future<String>>>('projectNames');

Future<String> _projectName(GitLabApi api, int id) {
  final cache = _projectNames[api] ??= <int, Future<String>>{};
  return cache.putIfAbsent(id, () => api.project('$id').then((p) => p.path, onError: (Object _) => ''));
}

String _targetLabel(String type) => switch (type) {
  'Issue' => '議題',
  'MergeRequest' => '合併請求',
  'Milestone' => '里程碑',
  'WikiPage::Meta' || 'WikiPage' => 'Wiki 頁面',
  'Project' => '專案',
  'Snippet' || 'ProjectSnippet' => '程式碼片段',
  'DesignManagement::Design' => '設計',
  _ => '',
};

/// Human sentence for one GitLab event: who did what to which target.
String activitySentence(Json event) {
  final action = valueText(event, 'action_name');
  final push = valueObject(event, 'push_data');
  final note = valueObject(event, 'note');
  if (push.isNotEmpty) {
    final refKind = valueText(push, 'ref_type') == 'tag' ? '標籤' : '分支';
    final ref = valueText(push, 'ref');
    final count = valueInt(push, 'commit_count');
    return switch (valueText(push, 'action')) {
      'removed' => '刪除了$refKind $ref',
      'created' => '建立了$refKind $ref${count > 0 ? '（$count 個提交）' : ''}',
      _ => '推送到$refKind $ref${count > 1 ? '（$count 個提交）' : ''}',
    };
  }
  final targetType = note.isNotEmpty ? valueText(note, 'noteable_type') : valueText(event, 'target_type');
  final target = _targetLabel(targetType);
  final iid = note.isNotEmpty ? valueInt(note, 'noteable_iid') : valueInt(event, 'target_iid');
  final reference = iid > 0 ? ' ${targetType == 'MergeRequest' ? '!' : '#'}$iid' : '';
  final verb = switch (action) {
    'opened' => '開啟了',
    'closed' => '關閉了',
    'reopened' => '重新開啟了',
    'accepted' => '合併了',
    'merged' => '合併了',
    'commented on' => '留言於',
    'created' => '建立了',
    'updated' => '更新了',
    'approved' => '批准了',
    'destroyed' || 'deleted' => '刪除了',
    'joined' => '加入了專案',
    'left' => '離開了專案',
    'imported' => '匯入了專案',
    'expired' => '成員資格到期',
    _ => action,
  };
  if (action == 'joined' || action == 'left' || action == 'imported' || action == 'expired') return verb;
  return '$verb$target$reference';
}

IconData _activityIcon(Json event) {
  final action = valueText(event, 'action_name');
  if (valueObject(event, 'push_data').isNotEmpty) return Icons.upload_outlined;
  if (valueObject(event, 'note').isNotEmpty || action == 'commented on') return Icons.chat_bubble_outline;
  return switch (action) {
    'opened' || 'reopened' => Icons.adjust,
    'closed' => Icons.check_circle_outline,
    'accepted' || 'merged' => Icons.merge,
    'approved' => Icons.verified_outlined,
    'created' => Icons.add_circle_outline,
    'joined' => Icons.person_add_alt,
    'left' => Icons.person_remove_alt_1_outlined,
    'destroyed' || 'deleted' => Icons.delete_outline,
    _ => Icons.history,
  };
}

/// One activity event as a compact timeline row.
Widget activityRow(BuildContext context, Json event, {required Account account, required GitLabApi api,
    bool showProject = true}) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  final author = valueObject(event, 'author');
  final name = valueText(author, 'name', valueText(event, 'author_username'));
  final username = valueText(author, 'username', valueText(event, 'author_username'));
  final push = valueObject(event, 'push_data');
  final note = valueObject(event, 'note');
  final projectId = valueInt(event, 'project_id');
  final detail = push.isNotEmpty
      ? valueText(push, 'commit_title')
      : note.isNotEmpty
          ? valueText(note, 'body').trim()
          : valueText(event, 'target_title');
  final open = ResourceNavigator(account, api);
  VoidCallback? onTap;
  if (projectId > 0) {
    final targetType = note.isNotEmpty ? valueText(note, 'noteable_type') : valueText(event, 'target_type');
    final iid = note.isNotEmpty ? valueInt(note, 'noteable_iid') : valueInt(event, 'target_iid');
    final commit = valueText(push, 'commit_to');
    if ((targetType == 'Issue' || targetType == 'MergeRequest') && iid > 0) {
      onTap = () => open.workItem(context, '$projectId', targetType == 'Issue' ? 'issues' : 'merge_requests', iid);
    } else if (push.isNotEmpty && commit.isNotEmpty && valueText(push, 'action') != 'removed') {
      onTap = () => open.commit(context, '$projectId', commit);
    } else {
      onTap = () => open.project(context, '$projectId');
    }
  }
  final sentence = activitySentence(event);
  final when = relativeDate(valueText(event, 'created_at'));
  return MergeSemantics(child: Semantics(button: onTap != null, child: InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Stack(clipBehavior: Clip.none, children: [
          Monogram(name.isEmpty ? username : name, size: 34),
          Positioned(right: -4, bottom: -4, child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: theme.colorScheme.surface, shape: BoxShape.circle),
            child: Icon(_activityIcon(event), size: 13, color: theme.colorScheme.primary),
          )),
        ]),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: name.isEmpty ? '@$username' : name, style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: ' $sentence'),
          ]), style: theme.textTheme.bodyMedium?.copyWith(height: 1.35)),
          if (detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(detail, maxLines: 2,
            overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface))),
          const SizedBox(height: 4),
          Row(children: [
            Text(when, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            if (showProject && projectId > 0) Flexible(child: FutureBuilder<String>(
              future: _projectName(api, projectId),
              builder: (context, snap) => (snap.data ?? '').isEmpty ? const SizedBox.shrink() : Text(' · ${snap.data}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            )),
          ]),
        ])),
      ]),
    ),
  )));
}

/// Activity for a project, a user, or (with neither) the signed-in account.
class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key, required this.account, required this.api, this.project, this.title});
  final Account account;
  final GitLabApi api;
  final Project? project;
  final String? title;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title ?? (project == null ? '我的動態' : '專案動態'))),
    body: gestureSafe(ActivityFeed(account: account, api: api, project: project)),
  );
}

class ActivityFeed extends StatelessWidget {
  const ActivityFeed({super.key, required this.account, required this.api, this.project, this.underShell = false});
  final Account account;
  final GitLabApi api;
  final Project? project;
  final bool underShell;
  @override
  Widget build(BuildContext context) => RecordsFeed(
    identity: 'events/${project?.id ?? 'me'}',
    account: account,
    resourceLabel: project == null ? '我的動態' : '${project!.path} · 動態',
    onSwitchAccount: endSessionFrom(context),
    empty: '還沒有動態',
    emptyIcon: Icons.timeline,
    grouped: true,
    underShell: underShell,
    load: (next) => api.events(projectId: project?.id, next: next),
    itemBuilder: (context, value) => activityRow(context, value, account: account, api: api, showProject: project == null),
  );
}
