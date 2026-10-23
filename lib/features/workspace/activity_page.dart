import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/gitlab_api.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../core/project_locator.dart';
import '../../core/providers.dart';
import '../../shared/external_link.dart';
import '../../shared/workspace_ui.dart';
import 'navigation.dart';
import 'records_feed.dart';

import '../../l10n/l10n.dart';
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
  'Issue' => l10n.issueTypeName,
  'MergeRequest' => l10n.mergeRequestLabel,
  'Commit' => l10n.commitLabel,
  'Milestone' => l10n.milestoneLabel,
  'WikiPage::Meta' || 'WikiPage' => l10n.wikiPageLabel,
  'Project' => l10n.projectLabel,
  'Snippet' || 'ProjectSnippet' => l10n.snippetLabel,
  'DesignManagement::Design' => l10n.designLabel,
  _ => '',
};

String _activitySheetLabel(String type) => switch (type) {
  'Issue' => l10n.issueTypeName,
  'MergeRequest' => l10n.mergeRequestLabel,
  'Commit' => l10n.commitLabel,
  'Milestone' => l10n.milestoneLabel,
  'WikiPage::Meta' || 'WikiPage' => l10n.wikiPageLabel,
  'Project' => l10n.projectLabel,
  'Snippet' || 'ProjectSnippet' => l10n.snippetLabel,
  'DesignManagement::Design' => l10n.designLabel,
  _ => l10n.otherGitlabActivity,
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

enum _ActivityRoute { workItem, commit, link, explain }

final class _ActivityTarget {
  const _ActivityTarget._(
    this.route,
    this.typeLabel, {
    this.projectId = 0,
    this.resource = '',
    this.iid = 0,
    this.sha = '',
    this.web,
    this.link,
    this.nativeType = false,
  });

  /// An event type without its own fields-based route (a work item, an epic)
  /// opens in the app when its link names one concrete resource; otherwise it
  /// explains itself.
  factory _ActivityTarget._fallback(
    String typeLabel,
    int projectId,
    Uri? web,
    GitLabInstance instance, {
    required bool nativeType,
  }) {
    final link = web == null || nativeType
        ? null
        : GitLabLink.inApp(web, instance);
    return _ActivityTarget._(
      link == null ? _ActivityRoute.explain : _ActivityRoute.link,
      typeLabel,
      projectId: projectId,
      web: web,
      link: link,
      nativeType: nativeType,
    );
  }

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
          l10n.commitLabel,
          projectId: projectId,
          sha: commitTo.toLowerCase(),
          nativeType: true,
        );
      }
      return _ActivityTarget._(
        _ActivityRoute.explain,
        l10n.commitLabel,
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
      return _ActivityTarget._fallback(
        _activitySheetLabel(noteableType),
        projectId,
        web,
        instance,
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

    return _ActivityTarget._fallback(
      _activitySheetLabel(targetType),
      projectId,
      web,
      instance,
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
  final GitLabLink? link;
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
        ? l10n.activityMissingTargetData(target.typeLabel)
        : l10n.activityTypeNoInAppPage(target.typeLabel);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              web == null ? l10n.cannotOpenThisActivity : l10n.cannotOpenInApp,
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
                ? l10n.activityLinkNotOnInstance
                : l10n.viewOnGitlabWebsiteInstead),
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
                  child: Text(l10n.closeAction),
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
                    label: Text(l10n.viewProject),
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
                    label: Text(l10n.openInGitlab),
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
    final refKind = valueText(push, 'ref_type') == 'tag' ? l10n.gitTagInSentence : l10n.branchInSentence;
    final ref = valueText(push, 'ref');
    final count = valueInt(push, 'commit_count');
    return switch (valueText(push, 'action')) {
      'removed' => l10n.deletedRefKind(refKind, ref),
      'created' => l10n.createdRefKind(refKind, ref, count > 0 ? l10n.commitCountSuffix(count) : ''),
      _ => l10n.pushedToRefKind(refKind, ref, count > 1 ? l10n.commitCountSuffix(count) : ''),
    };
  }
  final targetType = note.isNotEmpty ? valueText(note, 'noteable_type') : valueText(event, 'target_type');
  final target = _targetLabel(targetType);
  final iid = note.isNotEmpty ? valueInt(note, 'noteable_iid') : valueInt(event, 'target_iid');
  // One value, sigil included, so a right-to-left interface isolates it whole.
  final reference = iid > 0
      ? '${targetType == 'MergeRequest' ? '!' : '#'}$iid'
      : targetType == 'Commit' ? _shortSha(valueText(note, 'commit_id')) : '';
  final verb = switch (action) {
    'opened' => l10n.activityOpened,
    'closed' => l10n.activityClosed,
    'reopened' => l10n.activityReopened,
    'accepted' => l10n.activityMerged,
    'merged' => l10n.activityMerged,
    'commented on' => l10n.activityCommentedOn,
    'created' => l10n.activityCreated,
    'updated' => l10n.activityUpdated,
    'approved' => l10n.activityApproved,
    'destroyed' || 'deleted' => l10n.activityDeleted,
    'joined' => l10n.activityJoinedProject,
    'left' => l10n.activityLeftProject,
    'imported' => l10n.activityImportedProject,
    'expired' => l10n.membershipExpired,
    _ => action,
  };
  if (action == 'joined' || action == 'left' || action == 'imported' || action == 'expired') return verb;
  // Word order and spacing are the language's, e.g. 留言於議題 but "Commented on
  // Issue"; the reference sits inside the message so verb-final languages can
  // end with the verb.
  if (target.isEmpty) {
    return [verb, if (reference.isNotEmpty) isolated(reference)]
        .where((part) => part.isNotEmpty).join(' ');
  }
  if (verb.isEmpty) {
    return [target, if (reference.isNotEmpty) isolated(reference)].join(' ');
  }
  return reference.isEmpty
      ? l10n.activityVerbTarget(verb, target)
      : l10n.activityVerbTargetRef(verb, target, reference);
}

String _shortSha(String sha) =>
    RegExp(r'^[0-9a-f]{7,64}$').hasMatch(sha) ? sha.substring(0, 8.clamp(0, sha.length)) : '';

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
    _ActivityRoute.link => () => ResourceNavigator(
      account,
      api,
    ).link(context, target.link!),
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
            TextSpan(text: isolated(name.isEmpty ? '@$username' : name), style: const TextStyle(fontWeight: FontWeight.w600)),
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
    appBar: AppBar(title: Text(title ?? (project == null ? l10n.myActivity : l10n.projectActivity))),
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
    resourceLabel: project == null ? l10n.myActivity : l10n.pathWithActivity(project!.path),
    onSwitchAccount: endSessionFrom(context),
    empty: l10n.noActivityYet,
    emptyIcon: Icons.timeline,
    grouped: true,
    underShell: underShell,
    cached: ({required bool fresh, required bool background}) => api.cachedRecords([
      if (project != null) ...['projects', '${project!.id}', 'events'] else 'events',
    ], fresh: fresh, background: background),
    load: (next) => api.events(projectId: project?.id, next: next),
    itemBuilder: (context, value) => activityRow(context, value, account: account, api: api, showProject: project == null),
  );
}
