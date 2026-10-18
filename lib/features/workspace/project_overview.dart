import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/repository_ref.dart';
import '../../shared/external_link.dart';
import '../../shared/hub_ui.dart';
import '../../shared/markdown_view.dart';
import '../../shared/resource_share.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'activity_page.dart';
import 'project_extras.dart';
import 'project_more_page.dart';
import 'project_page.dart';
import 'repository_page.dart';

/// Sections of [ProjectPage] the overview hands over to, by tab index.
abstract final class ProjectSection {
  static const files = 0, issues = 1, mergeRequests = 2, ci = 3, more = 4;
}

/// A project's landing page, laid out like a GitHub Mobile repository: owner
/// and name, description, link and counts, the main actions, rows into the
/// project sections and the root README pinned to the default branch head.
///
/// Counts, license and README are decoration: a failed read leaves that part
/// out (README shows its own retry) and never blocks the section rows.
class ProjectOverview extends StatefulWidget {
  const ProjectOverview({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.starControl,
    required this.onSection,
    required this.isCurrent,
    this.controller,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final ProjectStarControl starControl;
  final ValueChanged<int> onSection;
  final bool Function() isCurrent;
  final ScrollController? controller;
  @override
  State<ProjectOverview> createState() => _ProjectOverviewState();
}

class _ProjectOverviewState extends State<ProjectOverview> {
  Json? _details;
  RepositoryRef? _ref;
  RepositoryReadme? _readme;
  ApiFailure? _readmeError;
  bool _readmeLoading = false;
  bool _readmeMissing = false;
  bool _moreOpen = false;
  bool _forking = false;
  int _epoch = 0;

  bool get _emptyRepository => (widget.project.defaultBranch ?? '').isEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ProjectOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ownerChanged = oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.project.defaultBranch != widget.project.defaultBranch;
    if (ownerChanged) {
      _epoch++;
      _details = null;
      _ref = null;
      _readme = null;
      _readmeError = null;
      _readmeMissing = false;
      _readmeLoading = false;
      _forking = false;
      unawaited(_load());
    } else if (oldWidget.starControl.revision != widget.starControl.revision) {
      unawaited(_loadDetails(_epoch));
    }
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  bool _current(int epoch, GitLabApi api) =>
      mounted && epoch == _epoch && identical(api, widget.api) && !api.isClosed && widget.isCurrent();

  Future<void> _load() async {
    final epoch = ++_epoch;
    await Future.wait([_loadDetails(epoch), _loadReadme(epoch)]);
  }

  Future<void> _loadDetails(int epoch) async {
    final api = widget.api, id = widget.project.id;
    try {
      final details = await api.record(['projects', '$id'], query: {'license': 'true'});
      if (_current(epoch, api)) setState(() => _details = details);
    } catch (_) {
      // Counts and license simply stay hidden.
    }
  }

  Future<void> _loadReadme(int epoch) async {
    final api = widget.api, project = widget.project;
    final branch = project.defaultBranch ?? '';
    if (branch.isEmpty) return;
    setState(() {
      _readmeLoading = true;
      _readmeError = null;
      _readmeMissing = false;
    });
    try {
      final ref = RepositoryRef.fromBranch(
        await api.record(['projects', '${project.id}', 'repository', 'branches', branch]),
      );
      if (!_current(epoch, api)) return;
      setState(() => _ref = ref);
      final tree = await api.records(
        ['projects', '${project.id}', 'repository', 'tree'],
        query: {'ref': ref.sha, 'path': '', 'per_page': '50'},
      );
      if (!_current(epoch, api)) return;
      final path = findReadmePath(tree.items);
      if (path == null) {
        setState(() {
          _readmeMissing = true;
          _readmeLoading = false;
        });
        return;
      }
      final text = await api.textFile(project.id, ref.sha, path);
      if (utf8.encode(text).length > 256 * 1024) {
        throw const ApiFailure(FailureKind.tooLarge);
      }
      if (!_current(epoch, api)) return;
      setState(() {
        _readme = RepositoryReadme(path: path, sha: ref.sha, markdown: text);
        _readmeLoading = false;
      });
    } catch (e) {
      if (!_current(epoch, api)) return;
      final failure = safeFailure(e);
      if (failure.kind == FailureKind.cancelled) return;
      setState(() {
        _readmeError = failure;
        _readmeLoading = false;
      });
    }
  }

  void _push(Widget page) =>
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)));

  Future<void> _toggleStar() async {
    final star = widget.starControl;
    if (star.busy) return;
    final epoch = _epoch, api = widget.api;
    try {
      if (star.starred == null) {
        await star.recheck();
        return;
      }
      final desired = !star.starred!;
      await star.setStar(desired);
      if (!mounted || !_current(epoch, api)) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(desired ? '已加入星標' : '已移除星標')));
    } catch (e) {
      if (!mounted || !_current(epoch, api) || e is ApiFailure && e.kind == FailureKind.cancelled) return;
      showFailure(context, e);
    }
  }

  Future<void> _fork() async {
    final epoch = _epoch, api = widget.api, project = widget.project;
    if (_forking || !await confirmAction(context, 'Fork 這個專案？', '會在你的個人 namespace 建立 ${project.path} 的副本。')) {
      return;
    }
    if (!_current(epoch, api)) return;
    setState(() => _forking = true);
    try {
      final fork = await api.forkProject(project.id);
      if (!mounted || !_current(epoch, api)) return;
      final created = forkedProject(fork);
      final account = widget.account;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已建立 Fork：${valueText(fork, 'path_with_namespace')}，匯入可能需要幾分鐘。'),
        action: created == null ? null : SnackBarAction(label: '開啟', onPressed: () {
          if (!mounted || !_current(epoch, api)) return;
          _push(ProjectPage(account: account, api: api, project: created));
        })));
    } catch (e) {
      if (!mounted || !_current(epoch, api)) return;
      showFailure(context, e);
    } finally {
      if (_current(epoch, api)) setState(() => _forking = false);
    }
  }

  Widget _hero(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final project = widget.project;
    final details = _details ?? const <String, dynamic>{};
    final segments = project.path.split('/');
    final namespace = segments.length > 1 ? segments.take(segments.length - 1).join('/') : project.path;
    final owner = valueText(valueObject(details, 'namespace'), 'name', namespace.split('/').last);
    final web = widget.account.instance.projectWeb(project.path);
    final stars = widget.starControl.starCount ?? valueInt(details, 'star_count');
    final forks = valueInt(details, 'forks_count');
    final (visibilityLabel, visibilityIcon) = statusStyle(project.visibility ?? '');
    final marked = project.markedForDeletionOn != null;
    final description = project.description?.trim() ?? '';
    final star = widget.starControl;
    final starLabel = !star.checked ? '確認星標中…' : star.starred == null ? '重新確認星標' : star.starred! ? '已加星標' : '加入星標';
    final statStyle = theme.textTheme.bodyLarge?.copyWith(color: muted);
    final statValue = theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700);
    Widget stat(IconData icon, String value, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: muted),
      const SizedBox(width: 6),
      Text(value, style: statValue),
      const SizedBox(width: 4),
      Text(label, style: statStyle),
    ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Monogram(owner, size: 26, circle: true),
          const SizedBox(width: 8),
          Expanded(child: Text(project.path, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(color: muted))),
        ]),
        const SizedBox(height: 10),
        Text(project.name, key: const ValueKey('project-overview-name'),
          style: theme.textTheme.headlineMedium?.copyWith(fontSize: 28, color: marked ? muted : null)),
        if (marked || project.archived == true) Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            if (marked) const StatusBadge('marked_for_deletion'),
            if (project.archived == true) const MetaChip('已封存 · 唯讀', icon: Icons.inventory_2_outlined),
          ]),
        ),
        if (description.isNotEmpty) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(description, maxLines: 6, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(fontSize: 16.5, height: 1.45,
              color: Color.lerp(scheme.onSurface, muted, .35))),
        ),
        const SizedBox(height: 14),
        Semantics(
          link: true,
          label: '在 GitLab 開啟 $web',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              if (widget.isCurrent()) unawaited(openExternal(context, web));
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(children: [
                Icon(Icons.link, size: 20, color: muted),
                const SizedBox(width: 10),
                Expanded(child: Text(web.toString(), maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600))),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 18, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          stat(Icons.star_border, '$stars', '星標'),
          stat(Icons.call_split, '$forks', 'Fork'),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(visibilityIcon, size: 18, color: muted),
            const SizedBox(width: 6),
            Text(visibilityLabel, style: statStyle),
          ]),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton.tonalIcon(
                key: const ValueKey('project-overview-star'),
                style: FilledButton.styleFrom(
                  backgroundColor: star.starred == true ? scheme.surfaceContainer : scheme.surfaceContainerHighest,
                  foregroundColor: scheme.onSurface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: theme.dividerTheme.color ?? scheme.outlineVariant),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: star.busy || !star.checked ? null : _toggleStar,
                icon: Icon(
                  star.starred == true ? Icons.star : star.starred == null ? Icons.star_half : Icons.star_border,
                  size: 20,
                  color: star.starred == true ? const Color(0xFFE3B341) : null,
                ),
                label: Text(starLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          const SizedBox(width: 10),
          HeaderSquareButton(
            icon: Icons.call_split,
            tooltip: 'Fork',
            onPressed: _forking || project.archived == true ? null : _fork,
          ),
          const SizedBox(width: 10),
          ResourceShareButton(
            uri: web,
            ownerKey: (widget.account.key, widget.api, project.id, project.path),
            isCurrent: widget.isCurrent,
            builder: (context, onPressed) => HeaderSquareButton(
              icon: Icons.share_outlined,
              tooltip: '分享連結',
              onPressed: onPressed,
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _sections(BuildContext context) {
    final details = _details;
    // GitLab reports a switched-off feature through the legacy flag, the
    // access level or both. Until the read lands every row stays.
    bool enabled(String flag, String level) =>
        details == null || (details[flag] != false && details[level] != 'disabled');
    final issuesEnabled = enabled('issues_enabled', 'issues_access_level');
    final openIssues = details == null ? null : valueInt(details, 'open_issues_count');
    final license = valueText(valueObject(details ?? const {}, 'license'), 'nickname',
      valueText(valueObject(details ?? const {}, 'license'), 'name'));
    final account = widget.account, api = widget.api, project = widget.project;
    return HubSection(
      padding: EdgeInsets.zero,
      children: [
        if (issuesEnabled) HubRow(
          leading: const IconTile(Icons.adjust, color: HubColors.green),
          title: '議題',
          value: openIssues != null ? '$openIssues' : null,
          onTap: () => widget.onSection(ProjectSection.issues),
        ),
        if (enabled('merge_requests_enabled', 'merge_requests_access_level')) HubRow(
          leading: const IconTile(Icons.merge, color: HubColors.blue),
          title: '合併請求',
          onTap: () => widget.onSection(ProjectSection.mergeRequests),
        ),
        if (enabled('jobs_enabled', 'builds_access_level')) HubRow(
          leading: const IconTile(Icons.rocket_launch_outlined, color: HubColors.purple),
          title: 'CI/CD',
          onTap: () => widget.onSection(ProjectSection.ci),
        ),
        HubRow(
          key: const ValueKey('project-overview-more'),
          leading: const NeutralTile(Icons.more_horiz),
          title: _moreOpen ? '收合' : '更多',
          semanticLabel: _moreOpen ? '收合更多項目' : '展開更多項目',
          trailing: Icon(_moreOpen ? Icons.expand_less : Icons.expand_more,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
          onTap: () => setState(() => _moreOpen = !_moreOpen),
        ),
        if (_moreOpen) ...[
          HubRow(
            leading: const IconTile(Icons.group_outlined, color: HubColors.orange),
            title: '成員',
            onTap: () => _push(MembersPage(account: account, api: api, project: project)),
          ),
          HubRow(
            leading: const IconTile(Icons.timeline, color: HubColors.slate),
            title: '專案動態',
            onTap: () => _push(ActivityPage(account: account, api: api, project: project)),
          ),
          if (enabled('wiki_enabled', 'wiki_access_level')) HubRow(
            leading: const IconTile(Icons.menu_book_outlined, color: HubColors.teal),
            title: 'Wiki',
            onTap: () => _push(WikiPagesPage(account: account, api: api, project: project)),
          ),
          if (details == null || details['releases_access_level'] != 'disabled') HubRow(
            leading: const IconTile(Icons.inventory_2_outlined, color: HubColors.pink),
            title: metadataTitle(MetadataKind.releases),
            onTap: () => _push(MetadataPage(account: account, api: api, project: project, kind: MetadataKind.releases)),
          ),
          if (license.isNotEmpty) HubRow(
            leading: const IconTile(Icons.balance, color: HubColors.red),
            title: '授權',
            value: license,
          ),
          HubRow(
            leading: const NeutralTile(Icons.apps),
            title: '所有功能',
            chevron: true,
            onTap: () => widget.onSection(ProjectSection.more),
          ),
        ],
      ],
    );
  }

  Widget _code(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final branch = _ref?.name ?? widget.project.defaultBranch ?? '';
    final account = widget.account, api = widget.api, project = widget.project;
    return HubSection(
      padding: EdgeInsets.zero,
      children: [
        if (branch.isNotEmpty) Semantics(
          button: true,
          label: '目前分支 $branch',
          excludeSemantics: true,
          onTap: () => widget.onSection(ProjectSection.files),
          child: InkWell(
            onTap: () => widget.onSection(ProjectSection.files),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(children: [
                SizedBox(width: 32, child: Icon(Icons.alt_route, color: muted)),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('目前分支', style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                  Text(branch, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: codeTextStyle(context, fontSize: 16)),
                ])),
              ]),
            ),
          ),
        ),
        HubRow(
          leading: const NeutralTile(Icons.code),
          title: '檔案',
          onTap: () => widget.onSection(ProjectSection.files),
        ),
        HubRow(
          leading: const NeutralTile(Icons.commit),
          title: metadataTitle(MetadataKind.commits),
          onTap: () => _push(MetadataPage(account: account, api: api, project: project, kind: MetadataKind.commits)),
        ),
      ],
    );
  }

  Widget _readmeSection(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final project = widget.project, account = widget.account;
    final readme = _readme, ref = _ref;
    final Widget body;
    if (_emptyRepository) {
      body = Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Text('Repository 尚未初始化，新增第一個檔案後就會顯示內容。', style: TextStyle(color: muted)));
    } else if (_readmeLoading) {
      body = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    } else if (_readmeError != null) {
      body = FailureNotice(_readmeError!, account: account, resourceLabel: '${project.path} · README',
        onRetry: () => unawaited(_loadReadme(_epoch)), onSwitchAccount: endSessionFrom(context));
    } else if (readme != null) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: MarkdownView(
          readme.markdown,
          base: account.instance.projectWeb('${project.path}/-/blob/${readme.sha}/${readme.path}'),
          api: widget.api,
          projectId: project.id,
          projectWeb: account.instance.projectWeb(project.path),
          projectPath: project.path,
          account: account,
        ),
      );
    } else if (_readmeMissing) {
      body = Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Text('這個專案還沒有 README。', style: TextStyle(color: muted)));
    } else {
      body = const SizedBox(height: 16);
    }
    return Material(
      color: theme.colorScheme.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(children: [
            Icon(Icons.info_outline, color: muted),
            const SizedBox(width: 12),
            Expanded(child: Text(readme?.path ?? 'README', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: codeTextStyle(context, fontSize: 16, color: muted))),
            if (readme != null && ref != null)
              TextButton(
                onPressed: () => _push(RepositoryFilePage(
                  account: account, api: widget.api, project: project,
                  ref: ref, branch: ref.name, sha: ref.sha, filePath: readme.path,
                )),
                child: const Text('檢視檔案'),
              ),
          ]),
        ),
        body,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ListView(
      key: PageStorageKey('project-overview-${widget.project.id}'),
      controller: widget.controller,
      padding: EdgeInsets.zero,
      children: [
        ColoredBox(
          color: dark ? theme.scaffoldBackgroundColor : theme.colorScheme.surface,
          child: _hero(context),
        ),
        Divider(height: 1, color: theme.dividerTheme.color),
        _sections(context),
        _code(context),
        _readmeSection(context),
      ],
    );
  }
}
