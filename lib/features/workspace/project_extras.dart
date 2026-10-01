import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/external_link.dart';
import '../../shared/markdown_view.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'navigation.dart';
import 'records_feed.dart';

String accessLevelLabel(int level) => switch (level) {
  >= 50 => 'Owner',
  >= 40 => 'Maintainer',
  >= 30 => 'Developer',
  >= 20 => 'Reporter',
  >= 15 => 'Planner',
  >= 10 => 'Guest',
  >= 5 => 'Minimal',
  _ => '無存取權',
};

Widget _extraScaffold(BuildContext context, String title, Widget body, {List<Widget>? actions}) => Scaffold(
  appBar: AppBar(title: Text(title), actions: actions),
  body: gestureSafe(body),
);

/// Direct and inherited project members with their role.
class MembersPage extends StatelessWidget {
  const MembersPage({super.key, required this.account, required this.api, required this.project});
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  Widget build(BuildContext context) => _extraScaffold(context, '成員', RecordsFeed(
    identity: '${project.id}/members',
    account: account,
    resourceLabel: '${project.path} · 成員',
    onSwitchAccount: endSessionFrom(context),
    empty: '沒有可顯示的成員',
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
          if (expires.isNotEmpty) '到期 $expires',
          if (valueInt(value, 'id') == account.user.id) '你',
        ].join(' · ')),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
          child: Text(accessLevelLabel(valueInt(value, 'access_level')),
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSecondaryContainer)),
        ),
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
    empty: '這個專案沒有 Wiki 頁面',
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

class _WikiPageViewState extends State<WikiPageView> {
  Json? _page;
  ApiFailure? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final page = await widget.api.wikiPage(widget.project.id, widget.slug);
      if (mounted) setState(() => _page = page);
    } catch (e) {
      if (mounted) setState(() => _error = safeFailure(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
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
      actions: [IconButton(tooltip: '在 GitLab 開啟', icon: const Icon(Icons.open_in_new, size: 20),
        onPressed: () => openExternal(context, web))]);
  }
}

/// Environments with their tier and live URL; each opens its deployments.
class EnvironmentsPage extends StatelessWidget {
  const EnvironmentsPage({super.key, required this.account, required this.api, required this.project});
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  Widget build(BuildContext context) => _extraScaffold(context, '環境', RecordsFeed(
    identity: '${project.id}/environments',
    account: account,
    resourceLabel: '${project.path} · 環境',
    onSwitchAccount: endSessionFrom(context),
    empty: '沒有環境',
    emptyDetail: 'CI 的 environment 設定部署後會出現在這裡。',
    emptyIcon: Icons.dns_outlined,
    grouped: true,
    load: (next) => api.records(['projects', '${project.id}', 'environments'], next: next),
    itemBuilder: (context, value) {
      final name = valueText(value, 'name');
      final url = Uri.tryParse(valueText(value, 'external_url'));
      final state = valueText(value, 'state');
      return ListTile(
        minTileHeight: 56,
        leading: Icon(state == 'available' ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          state == 'available' ? '可用' : state == 'stopped' ? '已停止' : state,
          if (valueText(value, 'tier').isNotEmpty) valueText(value, 'tier'),
          if (url != null && url.host.isNotEmpty) url.host,
        ].join(' · ')),
        trailing: url != null && url.scheme == 'https' && url.host.isNotEmpty
          ? IconButton(tooltip: '開啟 $name', icon: const Icon(Icons.open_in_new, size: 20),
              onPressed: () => openExternal(context, url))
          : const Icon(Icons.chevron_right, size: 18),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
          DeploymentsPage(account: account, api: api, project: project, environment: name))),
      );
    },
  ));
}

/// Deployments, newest first, optionally for one environment.
class DeploymentsPage extends StatelessWidget {
  const DeploymentsPage({super.key, required this.account, required this.api, required this.project, this.environment});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String? environment;
  @override
  Widget build(BuildContext context) => _extraScaffold(context, environment == null ? '部署紀錄' : '部署 · $environment', RecordsFeed(
    identity: '${project.id}/deployments/${environment ?? ''}',
    account: account,
    resourceLabel: '${project.path} · 部署',
    onSwitchAccount: endSessionFrom(context),
    empty: '沒有部署紀錄',
    emptyIcon: Icons.rocket_launch_outlined,
    grouped: true,
    load: (next) => api.records(['projects', '${project.id}', 'deployments'], query: {
      'order_by': 'created_at', 'sort': 'desc', 'environment': ?environment,
    }, next: next),
    itemBuilder: (context, value) {
      final job = valueObject(value, 'deployable');
      final jobId = valueInt(job, 'id');
      final user = valueObject(value, 'user');
      return InkWell(
        onTap: jobId <= 0 ? null : () => ResourceNavigator(account, api).job(context, '${project.id}', jobId),
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
  ));
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

class _PipelineSchedulesPageState extends State<PipelineSchedulesPage> {
  bool _busy = false;

  Future<void> _play(Json schedule) async {
    final description = valueText(schedule, 'description', '排程 #${valueInt(schedule, 'id')}');
    if (_busy || !await confirmAction(context, '立即執行排程？', '$description\n${valueText(schedule, 'ref')}')) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.playPipelineSchedule(widget.project.id, valueInt(schedule, 'id'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已排入執行，Pipeline 稍後會出現在 CI 分頁。')));
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _extraScaffold(context, 'Pipeline 排程', RecordsFeed(
    identity: '${widget.project.id}/pipeline_schedules',
    account: widget.account,
    resourceLabel: '${widget.project.path} · Pipeline 排程',
    onSwitchAccount: endSessionFrom(context),
    empty: '沒有 Pipeline 排程',
    emptyIcon: Icons.event_repeat_outlined,
    grouped: true,
    load: (next) => widget.api.records(['projects', '${widget.project.id}', 'pipeline_schedules'], next: next),
    itemBuilder: (context, value) {
      final active = valueBool(value, 'active');
      final next = valueText(value, 'next_run_at');
      return ListTile(
        minTileHeight: 64,
        leading: Icon(active ? Icons.event_repeat_outlined : Icons.event_busy_outlined),
        title: Text(valueText(value, 'description', '排程 #${valueInt(value, 'id')}'), maxLines: 2,
          overflow: TextOverflow.ellipsis),
        subtitle: Text([
          valueText(value, 'ref'),
          '${valueText(value, 'cron')} (${valueText(value, 'cron_timezone', 'UTC')})',
          if (!active) '已停用',
          if (active && next.isNotEmpty) '下次 ${DateTime.tryParse(next)?.toLocal().toString().substring(0, 16) ?? next}',
        ].join(' · ')),
        trailing: IconButton(
          tooltip: '立即執行',
          icon: const Icon(Icons.play_circle_outline),
          onPressed: _busy || widget.project.archived == true ? null : () => _play(value),
        ),
      );
    },
  ));
}
