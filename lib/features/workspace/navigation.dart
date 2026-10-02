import 'package:flutter/material.dart';
import '../../core/failure.dart';
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
/// (search, activity, groups, the inbox, pasted links). The project is
/// resolved with the active account first. A failed lookup, often an
/// ambiguous 404, opens a page naming the account, instance and target with
/// retry and account switch; a successful retry continues to the resource.
class ResourceNavigator {
  const ResourceNavigator(this.account, this.api);
  final Account account;
  final GitLabApi api;

  Future<T?> _resolve<T>(BuildContext context, String target, Future<T> Function() load) async {
    try {
      return await load();
    } catch (e) {
      final failure = safeFailure(e);
      if (!context.mounted || failure.kind == FailureKind.cancelled) return null;
      return Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) =>
        _UnresolvedPage<T>(account: account, target: target, error: failure, load: load)));
    }
  }

  Future<Project?> _project(BuildContext context, String idOrPath) =>
      _resolve(context, '專案 $idOrPath', () => api.project(idOrPath));

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
    final commit = await _resolve(context, '${found.path} · $ref', () => api.commit(found.id, ref));
    final sha = commit == null ? '' : valueText(commit, 'id');
    if (sha.isEmpty || !context.mounted) return;
    await _push(context, RepositoryFilePage(
      account: account, api: api, project: found, filePath: path, targetLine: line,
      ref: RepositoryRef(kind: RepositoryRefKind.commit, name: shortSha(sha), sha: sha, protected: false),
    ));
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

class _UnresolvedPage<T> extends StatefulWidget {
  const _UnresolvedPage({required this.account, required this.target, required this.error, required this.load});
  final Account account;
  final String target;
  final ApiFailure error;
  final Future<T> Function() load;
  @override
  State<_UnresolvedPage<T>> createState() => _UnresolvedPageState<T>();
}

class _UnresolvedPageState<T> extends State<_UnresolvedPage<T>> {
  late ApiFailure _error = widget.error;
  bool _loading = false;

  Future<void> _retry() async {
    setState(() => _loading = true);
    try {
      final value = await widget.load();
      if (mounted) Navigator.of(context).pop(value);
    } catch (e) {
      if (mounted) setState(() { _error = safeFailure(e); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('無法開啟')),
    body: gestureSafe(ListView(children: [
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      FailureNotice(_error, account: widget.account, resourceLabel: widget.target,
        onRetry: _loading ? null : _retry, onSwitchAccount: endSessionFrom(context)),
    ])),
  );
}
