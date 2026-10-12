import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/gitlab_api.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../shared/external_link.dart';
import '../../shared/workspace_ui.dart';
import 'navigation.dart';
import 'records_feed.dart';

/// Project names for activity rows that span projects, fetched once per
/// project and client. Bound to the [GitLabApi] instance, so an account switch
/// (which closes the client) never reuses another account's answers. A failed
/// lookup is dropped, so the row asks again the next time it is built.
final _projectNames = Expando<Map<int, Future<String>>>('projectNames');

Future<String> activityProjectName(GitLabApi api, int id) {
  final cache = _projectNames[api] ??= <int, Future<String>>{};
  return cache[id] ??= api.project('$id').then((p) => p.path, onError: (Object _) {
    cache.remove(id);
    return '';
  });
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

String _activitySheetLabel(String type) => switch (type) {
  'Issue' => '議題',
  'MergeRequest' => '合併請求',
  'Commit' => '提交',
  'Milestone' => '里程碑',
  'WikiPage::Meta' || 'WikiPage' => 'Wiki 頁面',
  'Project' => '專案',
  'Snippet' || 'ProjectSnippet' => '程式碼片段',
  'DesignManagement::Design' => '設計',
  _ => '其他 GitLab 動態',
};

/// Accepts only an HTTPS link on this account's instance (host, port and
/// installation subpath) with no credentials, relative or encoded separators.
Uri? _activityWebUri(String text, GitLabInstance instance) {
  final value = text.trim();
  final rawPath = RegExp(r'^https://[^/?#]+([^?#]*)', caseSensitive: false)
      .firstMatch(value)
      ?.group(1);
  if (rawPath == null ||
      rawPath.contains('\\') ||
      rawPath.contains('//') ||
      RegExp(r'%(2f|5c|2e)', caseSensitive: false).hasMatch(rawPath) ||
      rawPath.split('/').any((part) => part == '.' || part == '..')) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !instance.sameOrigin(uri) || !safeExternalUri(uri)) {
    return null;
  }
  final base =
      instance.base.pathSegments.where((part) => part.isNotEmpty).toList();
  final segments =
      uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (segments.length <= base.length) return null;
  for (var i = 0; i < base.length; i++) {
    if (segments[i] != base[i]) return null;
  }
  return uri;
}

enum _ActivityRoute { workItem, commit, explain }

final class _ActivityTarget {
  const _ActivityTarget._(
    this.route,
    this.typeLabel, {
    this.projectId = 0,
    this.resource = '',
    this.iid = 0,
    this.sha = '',
    this.web,
    this.nativeType = false,
  });

  factory _ActivityTarget.of(Json event, GitLabInstance instance) {
    final push = valueObject(event, 'push_data');
    final note = valueObject(event, 'note');
    final projectId = valueInt(event, 'project_id');
    final targetUrlText = valueText(event, 'target_url');
    final web = _activityWebUri(targetUrlText, instance);

    if (push.isNotEmpty) {
      final action = valueText(push, 'action');
      final commitTo = valueText(push, 'commit_to').trim();
      final isFullSha = _fullSha.hasMatch(commitTo);
      if (projectId > 0 && action != 'removed' && isFullSha) {
        return _ActivityTarget._(
          _ActivityRoute.commit,
          '提交',
          projectId: projectId,
          sha: commitTo.toLowerCase(),
          nativeType: true,
        );
      }
      return _ActivityTarget._(
        _ActivityRoute.explain,
        '提交',
        projectId: projectId,
        web: web,
        nativeType: true,
      );
    }

    if (note.isNotEmpty) {
      final noteableType = valueText(note, 'noteable_type');
      final noteableIid = valueInt(note, 'noteable_iid');
      final isWorkItem =
          noteableType == 'Issue' || noteableType == 'MergeRequest';
      if (projectId > 0 && isWorkItem && noteableIid > 0) {
        return _ActivityTarget._(
          _ActivityRoute.workItem,
          _activitySheetLabel(noteableType),
          projectId: projectId,
          resource: noteableType == 'Issue' ? 'issues' : 'merge_requests',
          iid: noteableIid,
          nativeType: true,
        );
      }
      final isNative = isWorkItem || noteableType == 'Commit';
      return _ActivityTarget._(
        _ActivityRoute.explain,
        _activitySheetLabel(noteableType),
        projectId: projectId,
        web: web,
        nativeType: isNative,
      );
    }

    final targetType = valueText(event, 'target_type');
    final targetIid = valueInt(event, 'target_iid');
    final isWorkItem = targetType == 'Issue' || targetType == 'MergeRequest';
    if (projectId > 0 && isWorkItem && targetIid > 0) {
      return _ActivityTarget._(
        _ActivityRoute.workItem,
        _activitySheetLabel(targetType),
        projectId: projectId,
        resource: targetType == 'Issue' ? 'issues' : 'merge_requests',
        iid: targetIid,
        nativeType: true,
      );
    }

    return _ActivityTarget._(
      _ActivityRoute.explain,
      _activitySheetLabel(targetType),
      projectId: projectId,
      web: web,
      nativeType: isWorkItem,
    );
  }

  final _ActivityRoute route;
  final String typeLabel;
  final int projectId;
  final String resource;
  final int iid;
  final String sha;
  final Uri? web;
  final bool nativeType;

  static final _fullSha = RegExp(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$');
}

bool Function() _captureSheetFence(
    BuildContext pageContext, Account account, GitLabApi api) {
  if (!pageContext.mounted || api.isClosed) return () => false;
  final ProviderContainer container;
  try {
    container = ProviderScope.containerOf(pageContext, listen: false);
  } on StateError {
    // Standalone widget test fallback without ProviderScope
    return () => pageContext.mounted && !api.isClosed;
  }
  try {
    final session = container.read(sessionProvider);
    if (session.active?.key != account.key || !identical(session.api, api)) {
      return () => false;
    }
    final capturedGeneration = session.generation;
    return () {
      if (!pageContext.mounted || api.isClosed) return false;
      try {
        final currentSession = container.read(sessionProvider);
        return currentSession.active?.key == account.key &&
            identical(currentSession.api, api) &&
            currentSession.generation == capturedGeneration;
      } catch (_) {
        return false;
      }
    };
  } catch (_) {
    return () => false;
  }
}

void _closeExactRoute(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null) return;
  if (route.isCurrent) {
    Navigator.of(context).pop();
  } else if (route.isActive) {
    Navigator.of(context).removeRoute(route);
  }
}

class _ActivityTargetSheet extends StatelessWidget {
  const _ActivityTargetSheet({
    required this.target,
    required this.title,
    required this.projectPath,
    required this.account,
    required this.api,
    required this.pageContext,
    required this.isCurrent,
  });

  final _ActivityTarget target;
  final String title;
  final String projectPath;
  final Account account;
  final GitLabApi api;
  final BuildContext pageContext;
  final bool Function() isCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final web = target.web;
    final reason = target.nativeType
        ? '這則${target.typeLabel}動態缺少可辨識目標的資料，無法在 App 內開啟。'
        : '「${target.typeLabel}」類型的動態目前沒有 App 內頁面。';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              web == null ? '無法開啟此動態' : '無法在 App 內開啟',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (title.isNotEmpty)
              Text(title, style: theme.textTheme.bodyLarge),
            if (projectPath.isNotEmpty)
              Text(projectPath,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            const SizedBox(height: 12),
            Text(reason),
            const SizedBox(height: 4),
            Text(web == null
                ? '此動態沒有屬於目前 GitLab 實例的有效連結，無法開啟。'
                : '可改在 GitLab 網頁版查看：'),
            if (web != null) ...[
              const SizedBox(height: 4),
              Text(
                web.toString(),
                key: const ValueKey('activity-target-web-url'),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  key: const ValueKey('activity-target-close'),
                  style:
                      TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _closeExactRoute(context),
                  child: const Text('關閉'),
                ),
                if (target.projectId > 0)
                  OutlinedButton.icon(
                    key: const ValueKey('activity-target-view-project'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: () async {
                      if (!isCurrent()) return;
                      _closeExactRoute(context);
                      if (!isCurrent() || !pageContext.mounted) return;
                      await ResourceNavigator(account, api)
                          .project(pageContext, '${target.projectId}');
                    },
                    icon: const Icon(Icons.folder_outlined),
                    label: const Text('查看專案'),
                  ),
                if (web != null)
                  FilledButton.icon(
                    key: const ValueKey('activity-target-open-web'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: () async {
                      if (!isCurrent()) return;
                      _closeExactRoute(context);
                      if (!isCurrent() || !pageContext.mounted) return;
                      await openExternal(pageContext, web);
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('在 GitLab 開啟'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

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
  final sentence = activitySentence(event);
  final when = relativeDate(valueText(event, 'created_at'));
  Widget whenLine(String project) => Text(project.isEmpty ? when : '$when · $project',
    maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted));

  final target = _ActivityTarget.of(event, account.instance);
  final VoidCallback onTap = switch (target.route) {
    _ActivityRoute.workItem => () => ResourceNavigator(account, api)
        .workItem(context, '${target.projectId}', target.resource, target.iid),
    _ActivityRoute.commit => () => ResourceNavigator(account, api)
        .commit(context, '${target.projectId}', target.sha),
    _ActivityRoute.explain => () {
        final isCurrent = _captureSheetFence(context, account, api);
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _ActivityTargetSheet(
            target: target,
            title: detail.isNotEmpty ? detail : sentence,
            projectPath: valueText(
                event, 'project_path', valueText(event, 'project_name')),
            account: account,
            api: api,
            pageContext: context,
            isCurrent: isCurrent,
          ),
        );
      },
  };

  return MergeSemantics(child: Semantics(button: true, child: InkWell(
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
          // One line: the date keeps priority and the project name is cut first.
          if (showProject && projectId > 0) FutureBuilder<String>(
            future: activityProjectName(api, projectId),
            builder: (context, snap) => whenLine(snap.data ?? ''),
          ) else whenLine(''),
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
