import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/project_locator.dart';
import '../../core/repository_ref.dart';
import '../../shared/workspace_ui.dart';
import 'ci_page.dart';
import 'commit_page.dart';
import 'project_page.dart';
import 'repository_page.dart';
import 'work_item_page.dart';

/// Opens resources named by numeric project ID from feeds that span projects
/// (search, activity, groups). The project is resolved with the active account
/// first; failures surface through [showFailure] like any other read.
class ResourceNavigator {
  const ResourceNavigator(this.account, this.api);
  final Account account;
  final GitLabApi api;

  Future<Project?> _project(BuildContext context, String idOrPath) async {
    try {
      return await api.project(idOrPath);
    } catch (e) {
      if (context.mounted) showFailure(context, e);
      return null;
    }
  }

  Future<void> _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Future<void> project(BuildContext context, String idOrPath, {int initialTab = 0}) async {
    final found = await _project(context, idOrPath);
    if (found == null || !context.mounted) return;
    await _push(context, ProjectPage(account: account, api: api, project: found, initialTab: initialTab));
  }

  Future<void> workItem(BuildContext context, String projectIdOrPath, String resource, int iid) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted) return;
    await _push(context, WorkItemPage(account: account, api: api, project: found, resource: resource, iid: iid));
  }

  Future<void> pipeline(BuildContext context, String projectIdOrPath, int id) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted) return;
    await _push(context, PipelinePage(account: account, api: api, project: found, id: id));
  }

  Future<void> job(BuildContext context, String projectIdOrPath, int id) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted) return;
    await _push(context, JobLogPage(account: account, api: api, project: found, id: id));
  }

  Future<void> commit(BuildContext context, String projectIdOrPath, String sha) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted) return;
    await _push(context, CommitDetailPage(account: account, api: api, project: found, sha: sha));
  }

  /// Files open pinned to a commit. A branch ref is resolved to its head
  /// commit before the file is read, never followed as a moving target.
  Future<void> file(BuildContext context, String projectIdOrPath, String ref, String path, {int? line}) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted) return;
    try {
      final commit = await api.commit(found.id, ref);
      final sha = valueText(commit, 'id');
      if (sha.isEmpty || !context.mounted) return;
      await _push(context, RepositoryFilePage(
        account: account, api: api, project: found, filePath: path, targetLine: line,
        ref: RepositoryRef(kind: RepositoryRefKind.commit, name: shortSha(sha), sha: sha, protected: false),
      ));
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }

  Future<void> link(BuildContext context, GitLabLink link) => switch (link.target) {
    LinkTarget.project => project(context, link.project),
    LinkTarget.issue => workItem(context, link.project, 'issues', link.number!),
    LinkTarget.mergeRequest => workItem(context, link.project, 'merge_requests', link.number!),
    LinkTarget.pipeline => pipeline(context, link.project, link.number!),
    LinkTarget.job => job(context, link.project, link.number!),
    LinkTarget.commit => commit(context, link.project, link.sha!),
    LinkTarget.file => file(context, link.project, link.sha!, link.filePath!, line: link.line),
  };
}
