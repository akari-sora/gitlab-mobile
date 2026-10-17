import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/project_locator.dart';
import '../../core/repository_ref.dart';
import '../../shared/workspace_ui.dart';
import 'ci_page.dart';
import 'commit_page.dart';
import 'graph_work_items_page.dart';
import 'groups_page.dart';
import 'project_page.dart';
import 'repository_page.dart';
import 'work_item_page.dart';

/// Opens resources named by numeric project ID from feeds that span projects
/// (search, activity, groups, the inbox, pasted links). The project is
/// resolved with the active account first. An ambiguous 404 or a 403 opens a
/// page naming the account, instance and target with retry and account
/// switch, and a successful retry continues to the resource; transient
/// failures (network, rate limit) stay a snack bar.
class ResourceNavigator {
  const ResourceNavigator(this.account, this.api,
    {this.isCurrent, this.ownerChanges, this.onRoute, this.sessionGeneration});
  final Account account;
  final GitLabApi api;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;
  /// The `SessionController.generation` the explicit owner captured.
  final int? sessionGeneration;

  bool _active() => isCurrent?.call() ?? true;

  _NavigationOwner _owner(BuildContext context) {
    if (isCurrent != null || ownerChanges != null) {
      return _NavigationOwner(_active, ownerChanges, sessionGeneration);
    }
    try {
      final session = ProviderScope.containerOf(context, listen: false)
          .read(sessionProvider);
      final generation = session.generation;
      return _NavigationOwner(
        () => session.active?.key == account.key &&
            session.generation == generation &&
            identical(session.api, api),
        session,
        session.active?.key == account.key && identical(session.api, api)
            ? generation
            : null,
      );
    } catch (_) {
      return _NavigationOwner(_active, null, null);
    }
  }

  Future<T?> _resolve<T>(BuildContext context, String target, Future<T> Function() load,
      {_NavigationOwner? owner}) async {
    final fence = owner ?? _owner(context);
    if (!context.mounted || !fence.current()) return null;
    try {
      final value = await load();
      if (!context.mounted || !fence.current()) return null;
      return value;
    } catch (e) {
      final failure = safeFailure(e);
      if (!context.mounted || !fence.current() || failure.kind == FailureKind.cancelled) return null;
      if (failure.kind != FailureKind.invisible && failure.kind != FailureKind.forbidden) {
        showFailure(context, failure);
        return null;
      }
      final route = MaterialPageRoute<T>(builder: (_) =>
        _UnresolvedPage<T>(account: account, target: target, error: failure, load: load,
          isCurrent: fence.current, ownerChanges: fence.changes));
      if (!context.mounted || !fence.current()) return null;
      onRoute?.call(route);
      if (!context.mounted || !fence.current()) return null;
      return Navigator.of(context).push<T>(route);
    }
  }

  Future<Project?> _project(BuildContext context, String idOrPath) =>
      _resolve(context, '專案 $idOrPath', () => api.project(idOrPath));

  Future<Json?> _group(BuildContext context, String fullPath, _NavigationOwner owner) =>
      _resolve(context, '群組 $fullPath',
        () => api.groupByPath(fullPath, isCurrent: owner.current), owner: owner);

  Future<void> _push(BuildContext context, Widget page) {
    if (!context.mounted || !_active()) return Future.value();
    final route = MaterialPageRoute<void>(builder: (_) => page);
    onRoute?.call(route);
    if (!context.mounted || !_active()) return Future.value();
    return Navigator.of(context).push(route);
  }

  /// Opens the project overview, or the [initialTab] section when given.
  Future<void> project(BuildContext context, String idOrPath, {int? initialTab}) async {
    final found = await _project(context, idOrPath);
    if (found == null || !context.mounted || !_active()) return;
    await _push(context, ProjectPage(account: account, api: api, project: found, initialTab: initialTab));
  }

  Future<void> group(BuildContext context, String fullPath, {int initialTab = 0}) async {
    final owner = _owner(context);
    final found = await _group(context, fullPath, owner);
    if (found == null || !context.mounted || !owner.current()) return;
    await _push(context, GroupPage(account: account, api: api, group: found,
      initialTab: initialTab, isCurrent: owner.current, ownerChanges: owner.changes,
      sessionGeneration: owner.generation));
  }

  Future<void> groupWorkItems(BuildContext context, String fullPath) =>
      group(context, fullPath, initialTab: 4);

  Future<void> workItem(BuildContext context, String projectIdOrPath, String resource, int iid) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted || !_active()) return;
    await _push(context, WorkItemPage(account: account, api: api, project: found, resource: resource, iid: iid));
  }

  Future<void> graphWorkItem(BuildContext context, GitLabLink link) async {
    final owner = _owner(context);
    if (!context.mounted || !owner.current()) return;
    if (link.workItemScope == WorkItemLinkScope.group) {
      await _push(context, GraphWorkItemDetailPage.namespace(
        account: account, api: api, namespacePath: link.project, iid: link.number!,
        isCurrent: owner.current, ownerChanges: owner.changes,
        sessionGeneration: owner.generation));
      return;
    }
    final found = await _resolve(context, '專案 ${link.project}',
      () => api.project(link.project), owner: owner);
    if (found == null || !context.mounted || !owner.current()) return;
    await _push(context, GraphWorkItemDetailPage.project(
      account: account, api: api, project: found, iid: link.number!,
      isCurrent: owner.current, ownerChanges: owner.changes,
      sessionGeneration: owner.generation));
  }

  Future<void> pipeline(BuildContext context, String projectIdOrPath, int id) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted || !_active()) return;
    await _push(context, PipelinePage(account: account, api: api, project: found, id: id));
  }

  Future<void> job(BuildContext context, String projectIdOrPath, int id) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted || !_active()) return;
    await _push(context, JobLogPage(account: account, api: api, project: found, id: id));
  }

  Future<void> commit(BuildContext context, String projectIdOrPath, String sha) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted || !_active()) return;
    await _push(context, CommitDetailPage(account: account, api: api, project: found, sha: sha));
  }

  /// Files open pinned to a commit. A branch ref is resolved to its head
  /// commit before the file is read, never followed as a moving target.
  Future<void> file(BuildContext context, String projectIdOrPath, String ref, String path, {int? line}) async {
    final found = await _project(context, projectIdOrPath);
    if (found == null || !context.mounted || !_active()) return;
    final commit = await _resolve(context, '${found.path} · $ref', () => api.commit(found.id, ref));
    if (commit == null || !context.mounted || !_active()) return;
    final sha = valueText(commit, 'id');
    if (sha.isEmpty) {
      showFailure(context, const ApiFailure(FailureKind.invalidResponse));
      return;
    }
    await _push(context, RepositoryFilePage(
      account: account, api: api, project: found, filePath: path, targetLine: line,
      ref: RepositoryRef(kind: RepositoryRefKind.commit, name: shortSha(sha), sha: sha, protected: false),
    ));
  }

  Future<void> link(BuildContext context, GitLabLink link) => switch (link.target) {
    LinkTarget.project => project(context, link.project),
    LinkTarget.group => group(context, link.project),
    LinkTarget.groupWorkItems => groupWorkItems(context, link.project),
    LinkTarget.issue => workItem(context, link.project, 'issues', link.number!),
    LinkTarget.workItem => graphWorkItem(context, link),
    LinkTarget.mergeRequest => workItem(context, link.project, 'merge_requests', link.number!),
    LinkTarget.pipeline => pipeline(context, link.project, link.number!),
    LinkTarget.job => job(context, link.project, link.number!),
    LinkTarget.commit => commit(context, link.project, link.sha!),
    LinkTarget.file => file(context, link.project, link.sha!, link.filePath!, line: link.line),
  };
}

final class _NavigationOwner {
  const _NavigationOwner(this.current, this.changes, this.generation);
  final bool Function() current;
  final Listenable? changes;
  final int? generation;
}

class _UnresolvedPage<T> extends StatefulWidget {
  const _UnresolvedPage({required this.account, required this.target, required this.error,
    required this.load, this.isCurrent, this.ownerChanges});
  final Account account;
  final String target;
  final ApiFailure error;
  final Future<T> Function() load;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  @override
  State<_UnresolvedPage<T>> createState() => _UnresolvedPageState<T>();
}

class _UnresolvedPageState<T> extends State<_UnresolvedPage<T>> {
  late ApiFailure _error = widget.error;
  bool _loading = false;
  ModalRoute<dynamic>? _route;
  bool _ownerInvalid = false;

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(covariant _UnresolvedPage<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    final route = _route;
    setState(() {
      _loading = false;
      _ownerInvalid = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      if (!route.isFirst) navigator.removeRoute(route);
    });
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    super.dispose();
  }

  Future<void> _retry() async {
    if (!(widget.isCurrent?.call() ?? true)) return;
    setState(() => _loading = true);
    try {
      final value = await widget.load();
      if (!mounted || !(widget.isCurrent?.call() ?? true)) return;
      Navigator.of(context).pop(value);
    } catch (e) {
      if (!mounted || !(widget.isCurrent?.call() ?? true)) return;
      final failure = safeFailure(e);
      if (failure.kind != FailureKind.cancelled) {
        setState(() { _error = failure; _loading = false; });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _ownerInvalid
    ? const Scaffold(body: SafeArea(child: Center(child: Text('帳號已切換，這個頁面已關閉。'))))
    : Scaffold(
    appBar: AppBar(title: const Text('無法開啟')),
    body: gestureSafe(ListView(children: [
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      FailureNotice(_error, account: widget.account, resourceLabel: widget.target,
        onRetry: _loading ? null : _retry, onSwitchAccount: endSessionFrom(context)),
    ])),
  );
}
