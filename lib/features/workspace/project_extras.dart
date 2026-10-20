import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../auth/session_controller.dart';
import '../../shared/external_link.dart';
import '../../shared/markdown_view.dart';
import '../../shared/resource_share.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'navigation.dart';
import 'records_feed.dart';
import 'search_page.dart';

import '../../l10n/l10n.dart';
String accessLevelLabel(int level) => switch (level) {
  >= 50 => l10n.roleOwner,
  >= 40 => l10n.roleMaintainer,
  >= 30 => l10n.roleDeveloper,
  >= 20 => l10n.roleReporter,
  >= 15 => l10n.rolePlanner,
  >= 10 => l10n.roleGuest,
  >= 5 => l10n.roleMinimalAccess,
  _ => l10n.roleNoAccess,
};

String environmentTierLabel(String tier) => switch (tier) {
  'production' => l10n.tierProduction,
  'staging' => l10n.tierStaging,
  'testing' => l10n.testing,
  'development' => l10n.tierDevelopment,
  'other' => l10n.pipelineSourceOther,
  _ => tier,
};

String environmentStateLabel(String state) => switch (state) {
  'available' => l10n.envAvailable,
  'stopping' => l10n.envStopping,
  'stopped' => l10n.envStopped,
  _ => state,
};

Widget _extraScaffold(BuildContext context, String title, Widget body,
  {List<Widget>? actions, bool compactTitle = false}) => Scaffold(
  appBar: AppBar(title: Text(title, maxLines: compactTitle ? 1 : null,
    overflow: compactTitle ? TextOverflow.ellipsis : null), actions: actions),
  body: gestureSafe(body),
);

/// Direct and inherited project members with their role.
class MembersPage extends StatelessWidget {
  const MembersPage({super.key, required this.account, required this.api, required this.project});
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  Widget build(BuildContext context) => _extraScaffold(context, l10n.members, RecordsFeed(
    identity: '${project.id}/members',
    account: account,
    resourceLabel: l10n.pathMembers(project.path),
    onSwitchAccount: endSessionFrom(context),
    empty: l10n.noMembersToShow,
    emptyIcon: Icons.group_outlined,
    grouped: true,
    load: (next) => api.records(['projects', '${project.id}', 'members', 'all'], next: next),
    itemBuilder: (context, value) {
      final theme = Theme.of(context);
      final name = valueText(value, 'name', valueText(value, 'username'));
      final expires = valueText(value, 'expires_at');
      return ListTile(
        minTileHeight: 56,
        leading: Monogram(name, size: 36),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          '@${valueText(value, 'username')}',
          if (expires.isNotEmpty) l10n.membershipExpires(expires),
          if (valueInt(value, 'id') == account.user.id) l10n.you,
        ].join(' · ')),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
          child: Text(accessLevelLabel(valueInt(value, 'access_level')),
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
        ),
        onTap: valueInt(value, 'id') <= 0 ? null : () {
          if (api.isClosed) return;
          unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => UserPage(account: account, api: api, user: value))));
        },
      );
    },
  ));
}

/// Wiki page titles; each opens rendered as Markdown.
class WikiPagesPage extends StatelessWidget {
  const WikiPagesPage({super.key, required this.account, required this.api, required this.project});
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  Widget build(BuildContext context) => _extraScaffold(context, 'Wiki', RecordsFeed(
    identity: '${project.id}/wikis',
    account: account,
    resourceLabel: '${project.path} · Wiki',
    onSwitchAccount: endSessionFrom(context),
    empty: l10n.projectHasNoWiki,
    emptyIcon: Icons.menu_book_outlined,
    grouped: true,
    load: (next) => api.records(['projects', '${project.id}', 'wikis'], next: next),
    itemBuilder: (context, value) {
      final slug = valueText(value, 'slug');
      final depth = '/'.allMatches(slug).length;
      return ListTile(
        minTileHeight: 52,
        contentPadding: EdgeInsets.only(left: 16.0 + depth * 16, right: 12),
        leading: const Icon(Icons.article_outlined),
        title: Text(valueText(value, 'title', slug), maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: depth > 0 ? Text(slug, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: slug.isEmpty ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => WikiPageView(account: account, api: api, project: project, slug: slug,
            title: valueText(value, 'title', slug)))),
      );
    },
  ));
}

class WikiPageView extends StatefulWidget {
  const WikiPageView({super.key, required this.account, required this.api, required this.project, required this.slug,
    required this.title});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String slug, title;
  @override
  State<WikiPageView> createState() => _WikiPageViewState();
}

typedef _WikiOwner = ({String accountKey, GitLabApi api, int projectId,
  String projectPath, String slug, int generation});

class _WikiPageViewState extends State<WikiPageView> {
  Json? _page;
  ApiFailure? _error;
  int _generation = 0;
  _WikiOwner get _owner => (accountKey: widget.account.key, api: widget.api,
    projectId: widget.project.id, projectPath: widget.project.path,
    slug: widget.slug, generation: _generation);
  bool _current(_WikiOwner owner) => mounted && !owner.api.isClosed &&
    owner.generation == _generation && owner.accountKey == widget.account.key &&
    identical(owner.api, widget.api) && owner.projectId == widget.project.id &&
    owner.projectPath == widget.project.path && owner.slug == widget.slug;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant WikiPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key == widget.account.key && identical(oldWidget.api, widget.api) &&
        oldWidget.project.id == widget.project.id && oldWidget.project.path == widget.project.path &&
        oldWidget.slug == widget.slug) {
      return;
    }
    _generation++;
    _page = null;
    _error = null;
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final owner = _owner;
    if (!_current(owner)) return;
    setState(() => _error = null);
    try {
      final page = await owner.api.wikiPage(owner.projectId, owner.slug);
      if (_current(owner)) setState(() => _page = page);
    } catch (e) {
      if (_current(owner)) setState(() => _error = safeFailure(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final owner = _owner;
    final web = widget.account.instance.projectWeb('${widget.project.path}/-/wikis/${widget.slug}');
    return _extraScaffold(context, widget.title, page == null
      ? (_error == null ? const ListSkeleton() : SingleChildScrollView(child: FailureNotice(_error!, onRetry: _load,
          account: widget.account, resourceLabel: '${widget.project.path} · Wiki ${widget.slug}')))
      : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (valueText(page, 'format') == 'markdown' || valueText(page, 'format').isEmpty)
            MarkdownView(valueText(page, 'content'), base: web, api: widget.api, projectId: widget.project.id,
              projectWeb: widget.account.instance.projectWeb(widget.project.path), projectPath: widget.project.path)
          else
            SelectableText(valueText(page, 'content'), style: codeTextStyle(context)),
        ])),
      compactTitle: true,
      actions: [
        ResourceShareButton(uri: web,
          ownerKey: (owner.accountKey, owner.api, owner.projectId, owner.projectPath, owner.slug, owner.generation),
          isCurrent: () => _current(owner)),
        IconButton(tooltip: l10n.openInGitlab, icon: const Icon(Icons.open_in_new, size: 20), onPressed: () {
          if (_current(owner)) unawaited(openExternal(context, web));
        }),
      ]);
  }
}

/// Environments with their tier and live URL; each opens its deployments.
class EnvironmentsPage extends StatefulWidget {
  const EnvironmentsPage({super.key, required this.account, required this.api, required this.project});
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  State<EnvironmentsPage> createState() => _EnvironmentsPageState();
}

typedef _EnvironmentOwner = ({String accountKey, GitLabApi api, int projectId,
  String projectPath, int generation});

class _EnvironmentsPageState extends State<EnvironmentsPage> {
  int _generation = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  SessionController? _session;
  int? _sessionGeneration;

  _EnvironmentOwner get _owner => (accountKey: widget.account.key, api: widget.api,
    projectId: widget.project.id, projectPath: widget.project.path, generation: _generation);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
    _bindSession();
  }

  void _bindSession() {
    try {
      final candidate = ProviderScope.containerOf(context, listen: false).read(sessionProvider);
      if (!identical(_session, candidate)) {
        _session?.removeListener(_sessionChanged);
        _session = candidate;
        candidate.addListener(_sessionChanged);
      }
      _sessionGeneration = candidate.generation;
    } on StateError {
      // Some isolated widget tests intentionally have no ProviderScope.
    }
  }

  bool _sessionCurrent() => _session == null ||
    (_session!.active?.key == widget.account.key && identical(_session!.api, widget.api) &&
      _session!.generation == _sessionGeneration);
  bool _current(_EnvironmentOwner owner) => mounted && !owner.api.isClosed &&
    owner.generation == _generation && owner.accountKey == widget.account.key &&
    identical(owner.api, widget.api) && owner.projectId == widget.project.id &&
    owner.projectPath == widget.project.path && _sessionCurrent();

  void _sessionChanged() {
    if (_sessionCurrent()) return;
    _generation++;
    _dismissRoutes();
    if (mounted) setState(() {});
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissRoutes() {
    final navigator = _navigator;
    final routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator?.mounted != true) return;
      for (final route in routes) {
        if (!route.isActive) continue;
        navigator!.popUntil((candidate) => candidate == route || candidate.isFirst);
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  @override
  void didUpdateWidget(covariant EnvironmentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key || !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id || oldWidget.project.path != widget.project.path ||
        widget.api.isClosed) {
      _generation++;
      _dismissRoutes();
      _bindSession();
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    _generation++;
    _dismissRoutes();
    super.dispose();
  }

  void _openDeployments(_EnvironmentOwner owner, int environmentId, String name) {
    if (!_current(owner)) return;
    final account = widget.account;
    final project = widget.project;
    final route = MaterialPageRoute<void>(builder: (_) => DeploymentsPage(
      account: account, api: owner.api, project: project,
      environment: name, environmentId: environmentId));
    _ownRoute(route);
    unawaited((_navigator ?? Navigator.of(context)).push<void>(route));
  }

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    final account = widget.account;
    final project = widget.project;
    return _extraScaffold(context, l10n.environments, !_current(owner) ? const SizedBox.shrink() : RecordsFeed(
    identity: '${account.key}/${project.id}/${project.path}/environments/$_generation',
    account: account,
    resourceLabel: l10n.pathEnvironments(project.path),
    onSwitchAccount: endSessionFrom(context),
    empty: l10n.noEnvironments,
    emptyDetail: l10n.environmentsAfterCiDeploy,
    emptyIcon: Icons.dns_outlined,
    grouped: true,
    load: (next) => owner.api.records(['projects', '${owner.projectId}', 'environments'], next: next),
    itemBuilder: (context, value) {
      final environmentId = valueInt(value, 'id');
      final name = valueText(value, 'name');
      final url = Uri.tryParse(valueText(value, 'external_url'));
      final state = valueText(value, 'state');
      return ListTile(
        minTileHeight: 56,
        leading: Icon(state == 'available' ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          environmentStateLabel(state),
          if (valueText(value, 'tier').isNotEmpty) environmentTierLabel(valueText(value, 'tier')),
          if (url != null && url.host.isNotEmpty) url.host,
        ].join(' · ')),
        trailing: url != null && url.host.isNotEmpty && safeExternalUri(url)
          ? IconButton(tooltip: l10n.openDeployTarget(name), icon: const Icon(Icons.open_in_new, size: 20),
              onPressed: () { if (_current(owner)) unawaited(openExternal(context, url)); })
          : const Icon(Icons.chevron_right, size: 18),
        onTap: () => _openDeployments(owner, environmentId, name),
      );
    },
  ));
  }
}

/// Deployments, newest first, optionally for one environment.
class DeploymentsPage extends StatefulWidget {
  const DeploymentsPage({super.key, required this.account, required this.api, required this.project,
    this.environment, this.environmentId});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String? environment;
  final int? environmentId;
  @override
  State<DeploymentsPage> createState() => _DeploymentsPageState();
}

class _DeploymentsPageState extends State<DeploymentsPage> {
  int _generation = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  SessionController? _session;
  int? _sessionGeneration;

  _EnvironmentOwner get _owner => (accountKey: widget.account.key, api: widget.api,
    projectId: widget.project.id, projectPath: widget.project.path, generation: _generation);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
    _bindSession();
  }

  void _bindSession() {
    try {
      final candidate = ProviderScope.containerOf(context, listen: false).read(sessionProvider);
      if (!identical(_session, candidate)) {
        _session?.removeListener(_sessionChanged);
        _session = candidate;
        candidate.addListener(_sessionChanged);
      }
      _sessionGeneration = candidate.generation;
    } on StateError {
      // Some isolated widget tests intentionally have no ProviderScope.
    }
  }

  bool _sessionCurrent() => _session == null ||
    (_session!.active?.key == widget.account.key && identical(_session!.api, widget.api) &&
      _session!.generation == _sessionGeneration);
  bool _current(_EnvironmentOwner owner) => mounted && !owner.api.isClosed &&
    owner.generation == _generation && owner.accountKey == widget.account.key &&
    identical(owner.api, widget.api) && owner.projectId == widget.project.id &&
    owner.projectPath == widget.project.path && _sessionCurrent();

  void _sessionChanged() {
    if (_sessionCurrent()) return;
    _generation++;
    _dismissRoutes();
    if (mounted) setState(() {});
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissRoutes() {
    final navigator = _navigator;
    final routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator?.mounted != true) return;
      for (final route in routes) {
        if (!route.isActive) continue;
        navigator!.popUntil((candidate) => candidate == route || candidate.isFirst);
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  @override
  void didUpdateWidget(covariant DeploymentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key || !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id || oldWidget.project.path != widget.project.path ||
        oldWidget.environment != widget.environment || oldWidget.environmentId != widget.environmentId ||
        widget.api.isClosed) {
      _generation++;
      _dismissRoutes();
      _bindSession();
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    _generation++;
    _dismissRoutes();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    final account = widget.account;
    final project = widget.project;
    final environment = widget.environment;
    final environmentId = widget.environmentId ?? 0;
    final ownerCurrent = _current(owner);
    final web = environmentId > 0
      ? account.instance.projectWeb('${project.path}/-/environments/$environmentId') : null;
    return _extraScaffold(context, !ownerCurrent || environment == null ? l10n.deployments : l10n.deploymentsForEnv(environment),
      !ownerCurrent ? const SizedBox.shrink() : RecordsFeed(
    identity: '${account.key}/${project.id}/${project.path}/deployments/'
      '${environment ?? ''}/$environmentId/$_generation',
    account: account,
    resourceLabel: l10n.pathDeployments(project.path),
    onSwitchAccount: endSessionFrom(context),
    empty: l10n.noDeployments,
    emptyIcon: Icons.rocket_launch_outlined,
    grouped: true,
    load: (next) => owner.api.records(['projects', '${owner.projectId}', 'deployments'], query: {
      'order_by': 'created_at', 'sort': 'desc', 'environment': ?environment,
    }, next: next),
    itemBuilder: (context, value) {
      final job = valueObject(value, 'deployable');
      final jobId = valueInt(job, 'id');
      final user = valueObject(value, 'user');
      return InkWell(
        onTap: jobId <= 0 ? null : () {
          if (_current(owner)) {
            unawaited(ResourceNavigator(account, owner.api,
              isCurrent: () => _current(owner), ownerChanges: _session,
              onRoute: _ownRoute)
                .job(context, '${owner.projectId}', jobId));
          }
        },
        child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 12, 12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: StatusBadge(valueText(value, 'status'))),
              const SizedBox(width: 8),
              Expanded(child: Text(valueText(valueObject(value, 'environment'), 'name', environment ?? ''),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall)),
              Text('#${valueInt(value, 'iid')}', style: codeTextStyle(context, fontSize: 12)),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 10, runSpacing: 4, children: [
              MetaChip(valueText(value, 'ref'), icon: Icons.alt_route, mono: true),
              MetaChip(shortSha(valueText(value, 'sha')), icon: Icons.commit, mono: true),
              if (valueText(user, 'username').isNotEmpty) MetaChip('@${valueText(user, 'username')}', icon: Icons.person_outline),
              MetaChip(relativeDate(valueText(value, 'created_at')), icon: Icons.schedule_outlined),
            ]),
          ],
        )),
      );
    },
  ), compactTitle: ownerCurrent && web != null, actions: !ownerCurrent || web == null ? null : [
    ResourceShareButton(uri: web,
      ownerKey: (owner.accountKey, owner.api, owner.projectId, owner.projectPath, environmentId, owner.generation),
      isCurrent: () => _current(owner)),
    IconButton(tooltip: l10n.openInGitlab, icon: const Icon(Icons.open_in_new, size: 20),
      onPressed: () { if (_current(owner)) unawaited(openExternal(context, web)); }),
  ]);
  }
}

/// Scheduled pipelines with their cadence and next run; each can run now.
class PipelineSchedulesPage extends StatefulWidget {
  const PipelineSchedulesPage({super.key, required this.account, required this.api, required this.project});
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  State<PipelineSchedulesPage> createState() => _PipelineSchedulesPageState();
}

typedef _ScheduleOwner = ({
  String accountKey,
  GitLabApi api,
  int projectId,
  String projectPath,
  int generation,
});

class _PipelineSchedulesPageState extends State<PipelineSchedulesPage> {
  bool _busy = false;
  int _generation = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  SessionController? _session;
  int? _sessionGeneration;

  _ScheduleOwner get _owner => (
    accountKey: widget.account.key,
    api: widget.api,
    projectId: widget.project.id,
    projectPath: widget.project.path,
    generation: _generation,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
    _bindSession();
  }

  void _bindSession() {
    try {
      final candidate = ProviderScope.containerOf(context, listen: false)
          .read(sessionProvider);
      if (!identical(_session, candidate)) {
        _session?.removeListener(_sessionChanged);
        _session = candidate;
        candidate.addListener(_sessionChanged);
      }
      _sessionGeneration = candidate.generation;
    } on StateError {
      // Some isolated widget tests intentionally have no ProviderScope.
    }
  }

  bool _sessionCurrent() => _session == null ||
      (_session!.active?.key == widget.account.key &&
       identical(_session!.api, widget.api) &&
       _session!.generation == _sessionGeneration);

  bool _current(_ScheduleOwner owner) => mounted &&
      owner.generation == _generation &&
      !owner.api.isClosed &&
      owner.accountKey == widget.account.key &&
      identical(owner.api, widget.api) &&
      owner.projectId == widget.project.id &&
      owner.projectPath == widget.project.path &&
      _sessionCurrent();

  void _sessionChanged() {
    if (_sessionCurrent()) return;
    _generation++;
    _dismissRoutes();
    if (mounted) setState(() => _busy = false);
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissRoutes() {
    final navigator = _navigator;
    final routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator == null || !navigator.mounted) return;
      for (final route in routes) {
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  @override
  void didUpdateWidget(covariant PipelineSchedulesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.project.path != widget.project.path ||
        widget.api.isClosed) {
      _generation++;
      _dismissRoutes();
      _busy = false;
      _bindSession();
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    _generation++;
    _dismissRoutes();
    super.dispose();
  }

  Future<void> _play(Json schedule) async {
    final owner = _owner;
    final scheduleId = valueInt(schedule, 'id');
    final description = valueText(schedule, 'description', l10n.scheduleNumber(scheduleId));
    final ref = valueText(schedule, 'ref');
    if (_busy || scheduleId <= 0 || !_current(owner)) return;
    setState(() => _busy = true);
    try {
      final confirmed = await confirmAction(
        context, l10n.runScheduleNowQuestion, '$description\n$ref',
        onRoute: (route) {
          _ownRoute(route);
          // The owner may expire before the dialog's first builder runs.
          if (!_current(owner)) _dismissRoutes();
        },
      );
      if (!confirmed || !_current(owner)) return;
      await owner.api.playPipelineSchedule(owner.projectId, scheduleId);
      if (mounted && _current(owner)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.scheduleQueued)));
      }
    } catch (e) {
      if (mounted && _current(owner)) showFailure(context, e);
    } finally {
      if (_current(owner)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    if (!_current(owner)) {
      return _extraScaffold(context, l10n.pipelineSchedules, const SizedBox.shrink());
    }
    return _extraScaffold(context, l10n.pipelineSchedules, RecordsFeed(
    identity: '${owner.accountKey}/${owner.projectId}/${owner.projectPath}/pipeline_schedules/${owner.generation}',
    account: widget.account,
    resourceLabel: l10n.pathPipelineSchedules(widget.project.path),
    onSwitchAccount: endSessionFrom(context),
    empty: l10n.noPipelineSchedules,
    emptyIcon: Icons.event_repeat_outlined,
    grouped: true,
    load: (next) => owner.api.records(['projects', '${owner.projectId}', 'pipeline_schedules'], next: next),
    itemBuilder: (context, value) {
      final active = valueBool(value, 'active');
      final next = valueText(value, 'next_run_at');
      final scheduleId = valueInt(value, 'id');
      return ListTile(
        minTileHeight: 64,
        leading: Icon(active ? Icons.event_repeat_outlined : Icons.event_busy_outlined),
        title: Text(valueText(value, 'description', l10n.scheduleNumberValue(valueInt(value, 'id'))), maxLines: 2,
          overflow: TextOverflow.ellipsis),
        subtitle: Text([
          valueText(value, 'ref'),
          '${valueText(value, 'cron')} (${valueText(value, 'cron_timezone', 'UTC')})',
          if (!active) l10n.disabled,
          if (active && next.isNotEmpty) l10n.nextRun(DateTime.tryParse(next)?.toLocal().toString().substring(0, 16) ?? next),
        ].join(' · ')),
        trailing: IconButton(
          tooltip: l10n.runNow,
          icon: const Icon(Icons.play_circle_outline),
          onPressed: _busy || scheduleId <= 0 || widget.project.archived == true ? null : () => _play(value),
        ),
      );
    },
  ));
  }
}
