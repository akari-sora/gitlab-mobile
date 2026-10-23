import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/repository_ref.dart';
import '../../shared/external_link.dart';
import '../../shared/hub_ui.dart';
import '../../shared/markdown_view.dart';
import '../../shared/motion.dart';
import '../../shared/resource_share.dart';
import '../../shared/theme.dart';
import '../../shared/cache_freshness.dart';
import '../../shared/workspace_ui.dart';
import 'activity_page.dart';
import 'project_extras.dart';
import 'project_more_page.dart';
import 'project_page.dart';
import 'repository_page.dart';

import '../../l10n/l10n.dart';
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
  State<ProjectOverview> createState() => ProjectOverviewState();
}

class ProjectOverviewState extends State<ProjectOverview> {
  Json? _details;
  RepositoryRef? _ref;
  RepositoryReadme? _readme;
  ApiFailure? _readmeError;
  String? _readmeDeniedBranch;
  bool _readmeLoading = false;
  bool _readmeMissing = false;
  bool _moreOpen = false;
  bool _forking = false;
  int _epoch = 0;
  bool _started = false;
  ValueListenable<TickerModeData>? _tickerMode;
  CachedRead<Json>? _detailsRead, _branchRead;
  CachedRead<ApiPage<Json>>? _treeRead;

  Json? get details => _details;
  RepositoryRef? get repositoryRef => _ref;
  RepositoryReadme? get readme => _readme;
  ApiFailure? error;
  bool loading = false, revalidating = false;
  bool _readmePending = false;
  bool _resumeWhenVisible = false;
  FailureKind? backgroundFailure;
  DateTime? backgroundRetryAt;
  bool get stale =>
      _detailsRead?.stale == true ||
      _readmeStale;
  // Project details shown from an earlier read: say so while they are
  // refreshed or after that failed. The gate is the details read's own
  // staleness — the README refreshes and reports its state separately and
  // must never raise this strip or set its spinner on its own.
  bool get _detailsStale => _detailsRead?.stale == true;
  DateTime? get _freshnessAt =>
      _details == null || loading || error != null || !_detailsStale
          ? null
          : _detailsRead?.fetchedAt;
  DateTime? get fetchedAt {
    final times = [?_detailsRead?.fetchedAt, ?_branchRead?.fetchedAt];
    if (times.isEmpty) return null;
    return times.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  String get _branch => _details?.containsKey('default_branch') == true
      ? _details!['default_branch'] as String? ?? ''
      : widget.project.defaultBranch ?? '';
  bool get _emptyRepository => _branch.isEmpty;
  bool get _backgroundEnabled => _tickerMode?.value.enabled ?? false;
  bool get _readmeStale => _readmeDeniedBranch != _branch &&
      (_branchRead?.stale == true ||
          _treeRead?.stale == true ||
          _readmePending ||
          _detailsRead != null && _branch != (_ref?.name ?? ''));

  void _updateTickerMode() {
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_tickerModeChanged);
      _tickerMode = mode;
      mode.addListener(_tickerModeChanged);
    }
    _tickerModeChanged();
  }

  void _tickerModeChanged() {
    if (!_backgroundEnabled && revalidating) _resumeWhenVisible = true;
    if (_backgroundEnabled) _startRevalidation(_epoch);
  }

  @override
  void activate() {
    super.activate();
    _updateTickerMode();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateTickerMode();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(covariant ProjectOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ownerChanged =
        oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.project.defaultBranch != widget.project.defaultBranch;
    if (ownerChanged) {
      _epoch++;
      _withdraw();
      _readmeDeniedBranch = null;
      _readmeError = null;
      error = null;
      backgroundFailure = null;
      backgroundRetryAt = null;
      revalidating = false;
      _forking = false;
      unawaited(_load());
    } else if (oldWidget.starControl.revision != widget.starControl.revision) {
      // A star write invalidates project metadata in the API cache.
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _epoch++;
    _tickerMode?.removeListener(_tickerModeChanged);
    super.dispose();
  }

  bool _current(int epoch, GitLabApi api) =>
      mounted &&
      epoch == _epoch &&
      identical(api, widget.api) &&
      !api.isClosed &&
      widget.isCurrent();

  bool _canApplyRead(int epoch, GitLabApi api, {required bool background}) {
    if (!_current(epoch, api)) return false;
    if (background && !_backgroundEnabled) {
      _resumeWhenVisible = true;
      return false;
    }
    return true;
  }

  void _withdraw() {
    _details = null;
    _ref = null;
    _readme = null;
    _detailsRead = null;
    _branchRead = null;
    _treeRead = null;
    _readmeMissing = false;
    _readmeLoading = false;
    _readmePending = false;
  }

  bool _revoked(ApiFailure failure) => switch (failure.kind) {
    FailureKind.unauthenticated ||
    FailureKind.forbidden ||
    FailureKind.invisible => true,
    _ => false,
  };

  void _failed(
    ApiFailure failure, {
    required bool background,
    bool repository = false,
  }) {
    if (failure.kind == FailureKind.unauthenticated ||
        !repository && _revoked(failure)) {
      _withdraw();
      error = failure;
      _readmeError = null;
    } else if (repository && _revoked(failure)) {
      _readmeDeniedBranch = _branch;
      _ref = null;
      _readme = null;
      _branchRead = null;
      _treeRead = null;
      _readmeMissing = false;
      _readmeLoading = false;
      _readmePending = false;
      _readmeError = failure;
    } else if (background) {
      backgroundFailure = failure.kind;
      backgroundRetryAt = failure.retryAt;
    } else if (repository) {
      _readmeError = failure;
    } else {
      error = failure;
      _readmeError = null;
    }
  }

  Future<CachedRead<T>?> _read<T>(
    int epoch,
    GitLabApi api,
    Future<CachedRead<T>> Function(bool fresh) loader, {
    required bool fresh,
    required bool background,
  }) async {
    Future<CachedRead<T>> readPage(bool force, {bool quiet = false}) => CachedRead.run(
      () => loader(force),
      mayStart: () => _current(epoch, api) &&
          (!background || _backgroundEnabled),
      waitForQuiet: quiet,
    );
    var read = await readPage(fresh);
    if (!_canApplyRead(epoch, api, background: background)) return null;
    if (read.superseded) {
      read = await readPage(true);
      if (!_canApplyRead(epoch, api, background: background)) return null;
      if (read.superseded) {
        read = await readPage(true, quiet: true);
        if (!_canApplyRead(epoch, api, background: background)) return null;
      }
      if (read.superseded) throw const ApiFailure(FailureKind.cancelled);
    }
    return read.dropped ? null : read;
  }

  Future<void> refresh() => _load(fresh: true);

  Future<void> _load({bool fresh = false}) async {
    final epoch = ++_epoch, api = widget.api;
    setState(() {
      loading = true;
      revalidating = false;
      backgroundFailure = null;
      backgroundRetryAt = null;
      _resumeWhenVisible = false;
      error = null;
      if (fresh) _readmeDeniedBranch = null;
    });
    try {
      await _loadDetails(epoch, fresh: fresh);
      if (!_current(epoch, api) || error != null) return;
      await _loadReadme(epoch, fresh: fresh);
    } finally {
      if (_current(epoch, api)) {
        setState(() => loading = false);
        _startRevalidation(epoch);
      }
    }
  }

  Future<void> _loadDetails(
    int epoch, {
    bool fresh = false,
    bool background = false,
  }) async {
    final api = widget.api, id = widget.project.id;
    try {
      final read = await _read(
        epoch,
        api,
        (force) => api.cachedRecord(
          ['projects', '$id'],
          query: {'license': 'true'},
          fresh: force,
          background: background,
        ),
        fresh: fresh,
        background: background,
      );
      if (!_canApplyRead(epoch, api, background: background)) return;
      if (read == null) {
        if (!background && _details == null) {
          setState(() => error = const ApiFailure(FailureKind.cancelled));
        }
        return;
      }
      setState(() {
        final previousBranch = _branch;
        _details = read.value;
        _detailsRead = read;
        if (_branch != previousBranch) _readmeDeniedBranch = null;
      });
    } catch (e) {
      if (!_current(epoch, api)) return;
      final failure = safeFailure(e);
      if (!_revoked(failure) && !_canApplyRead(epoch, api, background: background)) return;
      setState(() => _failed(failure, background: background));
    }
  }

  Future<void> _loadReadme(
    int epoch, {
    bool fresh = false,
    bool background = false,
  }) async {
    final api = widget.api, project = widget.project, branch = _branch;
    if (_readmeDeniedBranch == branch) return;
    if (branch.isEmpty) {
      setState(() {
        _ref = null;
        _readme = null;
        _branchRead = null;
        _treeRead = null;
        _readmeMissing = false;
        _readmeLoading = false;
        _readmePending = false;
      });
      return;
    }
    setState(() {
      _readmeLoading = !background && _readme == null;
      if (!background) _readmeError = null;
    });
    try {
      final branchRead = await _read(
        epoch,
        api,
        (force) => api.cachedRecord(
          ['projects', '${project.id}', 'repository', 'branches', branch],
          fresh: force,
          background: background,
        ),
        fresh: fresh || background && _branchRead?.stale == true,
        background: background,
      );
      if (!_canApplyRead(epoch, api, background: background)) return;
      if (branchRead == null) {
        if (!background && _ref == null) {
          setState(() => _readmeError = const ApiFailure(FailureKind.cancelled));
        }
        return;
      }
      setState(() {
        _branchRead = branchRead;
        _readmePending = true;
      });
      if (background && !_backgroundEnabled) return;
      final ref = RepositoryRef.fromBranch(branchRead.value);
      final treeRead = await _read(
        epoch,
        api,
        (force) => api.cachedRecords(
          ['projects', '${project.id}', 'repository', 'tree'],
          query: {'ref': ref.sha, 'path': '', 'per_page': '50'},
          fresh: force,
          background: background,
        ),
        fresh: fresh || background && _treeRead?.stale == true,
        background: background,
      );
      if (!_canApplyRead(epoch, api, background: background)) return;
      if (treeRead == null) {
        if (!background && _ref == null) {
          setState(() => _readmeError = const ApiFailure(FailureKind.cancelled));
        }
        return;
      }
      setState(() => _treeRead = treeRead);
      if (background && !_backgroundEnabled) return;
      final path = findReadmePath(treeRead.value.items);
      RepositoryReadme? readme;
      if (path != null) {
        // textFile already shares the core's immutable SHA-pinned cache with
        // the file viewer, including its bounded HEAD/raw representation.
        final text = await CachedRead.run(
          () => api.textFile(project.id, ref.sha, path, refresh: fresh),
          mayStart: () => _current(epoch, api) &&
              (!background || _backgroundEnabled),
        );
        if (!_canApplyRead(epoch, api, background: background)) return;
        if (utf8.encode(text).length > 256 * 1024) {
          throw const ApiFailure(FailureKind.tooLarge);
        }
        readme = RepositoryReadme(path: path, sha: ref.sha, markdown: text);
      }
      if (!_canApplyRead(epoch, api, background: background)) return;
      setState(() {
        _ref = ref;
        _readme = readme;
        _branchRead = branchRead;
        _treeRead = treeRead;
        _readmePending = false;
        _readmeMissing = path == null;
        _readmeLoading = false;
        _readmeError = null;
      });
    } catch (e) {
      if (!_current(epoch, api)) return;
      final failure = safeFailure(e);
      if (!_revoked(failure) && !_canApplyRead(epoch, api, background: background)) return;
      setState(
        () => _failed(failure, background: background, repository: true),
      );
    } finally {
      if (_current(epoch, api)) setState(() => _readmeLoading = false);
    }
  }

  void _startRevalidation(int epoch) {
    final api = widget.api;
    if (!_current(epoch, api) ||
        !_backgroundEnabled ||
        !stale ||
        loading ||
        revalidating ||
        backgroundFailure != null ||
        error != null) {
      return;
    }
    setState(() { revalidating = true; _resumeWhenVisible = false; });
    unawaited(_revalidate(epoch, api));
  }

  Future<void> _revalidate(int epoch, GitLabApi api) async {
    try {
      if (_detailsRead?.stale == true) {
        await _loadDetails(epoch, fresh: true, background: true);
        if (!_current(epoch, api) || error != null || backgroundFailure != null) return;
      }
      if (_backgroundEnabled && _readmeStale) {
        await _loadReadme(epoch, background: true);
      }
    } finally {
      if (_current(epoch, api)) {
        setState(() => revalidating = false);
        if (_resumeWhenVisible && _backgroundEnabled) _startRevalidation(epoch);
      }
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
      unawaited(Haptics.success());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(desired ? l10n.starredAdded : l10n.starRemoved)));
    } catch (e) {
      if (!mounted || !_current(epoch, api) || e is ApiFailure && e.kind == FailureKind.cancelled) return;
      showFailure(context, e);
    }
  }

  Future<void> _fork() async {
    final epoch = _epoch, api = widget.api, project = widget.project;
    if (_forking || !await confirmAction(context, l10n.forkProjectQuestion, l10n.forkCreatesCopy(project.path))) {
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
        content: Text(l10n.forkCreated(valueText(fork, 'path_with_namespace'))),
        action: created == null ? null : SnackBarAction(label: l10n.open, onPressed: () {
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
    final starLabel = !star.checked ? l10n.checkingStar : star.starred == null ? l10n.recheckStar : star.starred! ? l10n.starredBadge : l10n.star;
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
            if (project.archived == true) MetaChip(l10n.archivedReadOnly, icon: Icons.inventory_2_outlined),
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
          label: l10n.openInGitlab2(web),
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
          stat(Icons.star_border, '$stars', l10n.starsLabel),
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
              tooltip: l10n.shareLink,
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
          title: l10n.issues,
          value: openIssues != null ? '$openIssues' : null,
          onTap: () => widget.onSection(ProjectSection.issues),
        ),
        if (enabled('merge_requests_enabled', 'merge_requests_access_level')) HubRow(
          leading: const IconTile(Icons.merge, color: HubColors.blue),
          title: l10n.mergeRequests,
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
          title: _moreOpen ? l10n.collapse : l10n.moreItems,
          semanticLabel: _moreOpen ? l10n.collapseMoreItems : l10n.expandMoreItems,
          trailing: TurnChevron(open: _moreOpen, color: Theme.of(context).colorScheme.onSurfaceVariant),
          onTap: () => setState(() => _moreOpen = !_moreOpen),
        ),
        ExpandSection(expanded: _moreOpen, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          HubRow(
            leading: const IconTile(Icons.group_outlined, color: HubColors.orange),
            title: l10n.members,
            onTap: () => _push(MembersPage(account: account, api: api, project: project)),
          ),
          HubRow(
            leading: const IconTile(Icons.timeline, color: HubColors.slate),
            title: l10n.projectActivity,
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
            title: l10n.license,
            value: license,
          ),
          HubRow(
            leading: const NeutralTile(Icons.apps),
            title: l10n.allFeatures,
            chevron: true,
            onTap: () => widget.onSection(ProjectSection.more),
          ),
        ])),
      ],
    );
  }

  Widget _code(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final branch = _ref?.name ?? _branch;
    final account = widget.account, api = widget.api, project = widget.project;
    return HubSection(
      padding: EdgeInsets.zero,
      children: [
        if (branch.isNotEmpty) Semantics(
          button: true,
          label: l10n.currentBranchNamed(branch),
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
                  Text(l10n.currentBranch, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                  Text(branch, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: codeTextStyle(context, fontSize: 16)),
                ])),
              ]),
            ),
          ),
        ),
        HubRow(
          leading: const NeutralTile(Icons.code),
          title: l10n.compareFilesSection,
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
        child: Text(l10n.repositoryNotInitializedHint, style: TextStyle(color: muted)));
    } else if (_readmeLoading) {
      body = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    } else if (_readmeError != null) {
      body = FailureNotice(_readmeError!, account: account, resourceLabel: '${project.path} · README',
        onRetry: () => unawaited(refresh()), onSwitchAccount: endSessionFrom(context));
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
        child: Text(l10n.projectNoReadme, style: TextStyle(color: muted)));
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
                child: Text(l10n.viewFiles),
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
        if (error != null) FailureNotice(error!, account: widget.account,
          resourceLabel: widget.project.path, onRetry: () => unawaited(refresh()),
          onSwitchAccount: endSessionFrom(context)),
        if (_freshnessAt case final fetchedAt?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: CacheFreshnessBar(
              fetchedAt: fetchedAt,
              refreshing: revalidating,
              failure: backgroundFailure,
              retryAt: backgroundRetryAt,
              onRetry: () => unawaited(refresh()),
            ),
          ),
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
