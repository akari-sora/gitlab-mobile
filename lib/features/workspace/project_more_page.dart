import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/release_assets.dart';
import '../../core/repository_ref.dart';
import '../../core/work_item_types.dart';
import '../../shared/markdown_view.dart';
import '../../shared/resource_share.dart';
import '../../shared/workspace_ui.dart';
import 'activity_page.dart';
import 'boards_page.dart';
import 'commit_page.dart';
import 'compare_page.dart';
import 'repository_graph_page.dart';
import 'registries_page.dart';
import 'snippets_page.dart';
import 'editor.dart';
import 'graph_work_items_page.dart';
import 'navigation.dart';
import 'project_extras.dart';
import 'project_analytics_page.dart';
import 'records_feed.dart';
import 'release_assets_section.dart';
import 'repository_page.dart';
import 'search_page.dart';
import 'work_item_page.dart';
import '../../shared/theme.dart';
import '../auth/session_controller.dart';

enum MetadataKind { branches, tags, commits, releases, labels, milestones }
String metadataTitle(MetadataKind kind) => switch (kind) {
  MetadataKind.branches => '分支', MetadataKind.tags => '標籤版本', MetadataKind.commits => '提交紀錄',
  MetadataKind.releases => 'Releases', MetadataKind.labels => '議題標籤', MetadataKind.milestones => '里程碑',
};
/// [verb] followed by the kind's title, with the space Chinese text puts
/// before a Latin word: 新增里程碑, but 新增 Releases.
String metadataPhrase(String verb, MetadataKind kind) {
  final title = metadataTitle(kind);
  return RegExp(r'^[A-Za-z]').hasMatch(title) ? '$verb $title' : '$verb$title';
}

final class ProjectStarControl {
  const ProjectStarControl({
    required this.starred,
    required this.checked,
    required this.busy,
    required this.starCount,
    required this.revision,
    required this.recheck,
    required this.setStar,
  });
  final bool? starred;
  final bool checked, busy;
  final int? starCount;
  final int revision;
  final Future<void> Function() recheck;
  final Future<Json?> Function(bool starred) setStar;
}

class ProjectMoreTab extends StatefulWidget {
  const ProjectMoreTab({super.key, required this.account, required this.api, required this.project, required this.onChanged, this.onDeleted,
    this.starControl,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final ValueChanged<Project> onChanged;
  final VoidCallback? onDeleted;
  final ProjectStarControl? starControl;
  @override
  State<ProjectMoreTab> createState() => _ProjectMoreTabState();
}
class _ProjectMoreTabState extends State<ProjectMoreTab> {
  bool _busy = false;
  Json? _details;
  bool? _starred;
  bool _starChecked = false;
  List<(String, double)> _languages = const [];
  int _generation = 0, _overviewEpoch = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  SessionController? _session;
  int? _sessionGeneration;

  bool? get _effectiveStarred =>
      widget.starControl != null ? widget.starControl!.starred : _starred;
  bool get _effectiveStarChecked => widget.starControl?.checked ?? _starChecked;
  bool get _starBusy => _busy || (widget.starControl?.busy ?? false);

  bool _current(int generation) => mounted && generation == _generation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
    if (_session == null) _bindSession();
  }

  void _bindSession() {
    try {
      final candidate = ProviderScope.containerOf(context, listen: false)
          .read(sessionProvider);
      if (candidate.active?.key != widget.account.key ||
          !identical(candidate.api, widget.api)) {
        return;
      }
      if (!identical(_session, candidate)) {
        _session?.removeListener(_sessionChanged);
        _session = candidate;
        candidate.addListener(_sessionChanged);
      }
      _sessionGeneration = candidate.generation;
    } catch (_) {
      // Some isolated widget tests intentionally have no ProviderScope.
    }
  }

  bool _sessionCurrent() => mounted && (_session == null ||
      (_session!.active?.key == widget.account.key &&
       identical(_session!.api, widget.api) &&
       _session!.generation == _sessionGeneration));

  void _sessionChanged() {
    if (_sessionCurrent()) return;
    _generation++;
    _overviewEpoch++;
    _dismissRoutes();
    setState(() {
      _busy = false;
      _details = null;
      _starred = null;
      _starChecked = false;
      _languages = const [];
    });
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
        if (!route.isActive) continue;
        // A detail/editor opened by this page belongs to the same account
        // scope as its root. Removing only the root leaves those routes live.
        navigator.popUntil((candidate) => candidate == route || candidate.isFirst);
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ProjectMoreTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.starControl != null &&
        oldWidget.starControl?.revision != widget.starControl!.revision &&
        oldWidget.account.key == widget.account.key &&
        oldWidget.project.id == widget.project.id &&
        identical(oldWidget.api, widget.api)) {
      unawaited(_loadOverview());
    }
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.project.path != widget.project.path ||
        !identical(oldWidget.api, widget.api)) {
      _generation++;
      _overviewEpoch++;
      _dismissRoutes();
      _busy = false;
      _details = null;
      _starred = null;
      _starChecked = false;
      _languages = const [];
      _bindSession();
      unawaited(_loadOverview());
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    _generation++;
    _overviewEpoch++;
    _dismissRoutes();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadOverview());
  }

  /// Counts, clone URLs and languages are decoration: a failure leaves that
  /// part out. An unknown star state stays unknown instead of reading as
  /// unstarred, so the toggle never sends the wrong direction.
  Future<void> _loadOverview() async {
    final owner = widget;
    final generation = _generation, epoch = ++_overviewEpoch;
    final id = owner.project.id;
    Future<T?> soft<T>(Future<T> Function() read) async {
      try {
        return await read();
      } catch (_) {
        return null;
      }
    }
    final results = await Future.wait<Object?>([
      soft(() => owner.api.record(['projects', '$id'], query: {'license': 'true'})),
      widget.starControl == null
          ? soft(() => owner.api.hasStarred(id, owner.account.user.username))
          : Future<Object?>.value(widget.starControl!.starred),
      soft(() => owner.api.languages(id)),
    ]);
    if (!_current(generation) || epoch != _overviewEpoch) return;
    setState(() {
      _details = results[0] as Json?;
      _starred = results[1] as bool?;
      _starChecked = true;
      _languages = (results[2] as List<(String, double)>?) ?? const [];
    });
  }

  Future<void> _recheckStar() async {
    if (_starBusy) return;
    final shared = widget.starControl;
    if (shared != null) {
      final generation = _generation;
      try {
        await shared.recheck();
      } catch (e) {
        if (mounted && _current(generation) &&
            (e is! ApiFailure || e.kind != FailureKind.cancelled)) {
          showFailure(context, e);
        }
      }
      return;
    }
    final owner = widget, generation = _generation;
    ++_overviewEpoch;
    setState(() => _busy = true);
    try {
      final starred = await owner.api.hasStarred(owner.project.id, owner.account.user.username);
      if (mounted && _current(generation)) setState(() => _starred = starred);
    } catch (e) {
      if (mounted && _current(generation)) showFailure(context, e);
    } finally {
      if (mounted && _current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _fork() async {
    final owner = widget, generation = _generation;
    if (_busy || !await confirmAction(context, 'Fork 這個專案？', '會在你的個人 namespace 建立 ${owner.project.path} 的副本。', onRoute: _ownRoute)) {
      return;
    }
    if (!mounted || !_current(generation)) return;
    setState(() => _busy = true);
    try {
      final fork = await owner.api.forkProject(owner.project.id);
      if (mounted && _current(generation)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已建立 Fork：${valueText(fork, 'path_with_namespace')}，匯入可能需要幾分鐘。')));
      }
    } catch (e) {
      if (mounted && _current(generation)) showFailure(context, e);
    } finally {
      if (mounted && _current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已複製$label')));
  }

  void _push(Widget page) {
    final route = MaterialPageRoute<void>(builder: (_) => page);
    _ownRoute(route);
    unawaited(Navigator.push(context, route));
  }

  Widget _overview(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final details = _details ?? const <String, dynamic>{};
    final stars = widget.starControl?.starCount ?? valueInt(details, 'star_count'), forks = valueInt(details, 'forks_count');
    final issues = valueInt(details, 'open_issues_count');
    final https = valueText(details, 'http_url_to_repo'), ssh = valueText(details, 'ssh_url_to_repo');
    final license = valueText(valueObject(details, 'license'), 'nickname',
      valueText(valueObject(details, 'license'), 'name'));
    Widget stat(IconData icon, String value, String label) => Expanded(child: Column(children: [
      Icon(icon, size: 20, color: muted),
      const SizedBox(height: 4),
      Text(value, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium),
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
    ]));
    return Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 12), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.project.description?.isNotEmpty ?? false) Padding(padding: const EdgeInsets.only(bottom: 12),
          child: MarkdownView(widget.project.description!, base: widget.account.instance.projectWeb(widget.project.path),
            api: widget.api, projectId: widget.project.id, projectWeb: widget.account.instance.projectWeb(widget.project.path),
            projectPath: widget.project.path)),
        if (_details != null) Row(children: [
          stat(_effectiveStarred == true ? Icons.star : Icons.star_border, '$stars', '星標'),
          stat(Icons.call_split, '$forks', 'Fork'),
          stat(Icons.adjust, '$issues', '開啟議題'),
          if (license.isNotEmpty) stat(Icons.gavel_outlined, license, '授權'),
        ]),
        if (_languages.isNotEmpty) ...[
          const SizedBox(height: 14),
          ClipRRect(borderRadius: BorderRadius.circular(4), child: SizedBox(height: 8, child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (index, (_, share)) in _languages.take(6).indexed)
              Expanded(flex: math.max(1, (share * 10).round()), child: ColoredBox(color: _languageColor(index))),
          ]))),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 4, children: [
            for (final (index, (name, share)) in _languages.take(6).indexed)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: _languageColor(index), shape: BoxShape.circle)),
                const SizedBox(width: 4),
                Flexible(child: Text('$name ${share.toStringAsFixed(share < 10 ? 1 : 0)}%', style: theme.textTheme.bodySmall)),
              ]),
          ]),
        ],
        if (https.isNotEmpty || ssh.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final (label, url) in [('HTTPS', https), ('SSH', ssh)])
            if (url.isNotEmpty) InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _copy(' $label 位址', url),
              child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: Row(children: [
                SizedBox(width: 52, child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: muted))),
                Expanded(child: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: codeTextStyle(context, fontSize: 12))),
                Icon(Icons.copy, size: 16, color: muted),
              ])),
            ),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (_effectiveStarred == null)
            FilledButton.tonalIcon(
              key: const ValueKey('project-star-toggle'),
              onPressed: _starBusy || !_effectiveStarChecked
                        ? null : _recheckStar,
              icon: const Icon(Icons.star_half, size: 18),
              label: Text(_effectiveStarChecked ? '重新確認星標' : '確認星標中…'),
            )
          else
            FilledButton.tonalIcon(
              key: const ValueKey('project-star-toggle'),
              onPressed: _starBusy
                        ? null : () => _star(!_effectiveStarred!),
              icon: Icon(_effectiveStarred! ? Icons.star : Icons.star_border, size: 18),
              label: Text(_effectiveStarred! ? '移除星標' : '加入星標'),
            ),
          OutlinedButton.icon(
            onPressed: _busy || widget.project.archived == true ? null : _fork,
            icon: const Icon(Icons.call_split, size: 18),
            label: const Text('Fork'),
          ),
        ]),
      ],
    )));
  }

  Widget _section(BuildContext context, String title, List<(IconData, String, VoidCallback)> entries) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(left: 4, bottom: 6), child: Text(title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
      Card(child: Column(children: [
        for (final (index, (icon, label, onTap)) in entries.indexed) ...[
          if (index > 0) const Divider(height: 1, indent: 56),
          ListTile(leading: Icon(icon), title: Text(label), trailing: const Icon(Icons.chevron_right, size: 18), onTap: onTap),
        ],
      ])),
    ]),
  );

  static Color _languageColor(int index) => const [
    Color(0xFF4763E4), Color(0xFF1B9E77), Color(0xFFE6A100), Color(0xFFD95F02), Color(0xFF7570B3), Color(0xFF66A61E),
  ][index % 6];
  Future<void> _edit() async {
    if (_busy) return;
    final owner = widget, generation = _generation;
    Project? updated;
    final saved = await openEditor(context, account: owner.account, title: '專案設定',
      resource: '${owner.project.id}/settings', subtitle: owner.project.path,
      onRoute: _ownRoute,
      fields: [EditField('name', '顯示名稱', required: true, value: owner.project.name),
        EditField('description', '專案說明', lines: 6, value: owner.project.description ?? '')], save: (values) async {
        if (!_current(generation)) throw const ApiFailure(FailureKind.cancelled);
        updated = await owner.api.editProject(owner.project.id, name: values['name']!.trim(), description: values['description']!);
      });
    if (saved && _current(generation) && updated != null) { owner.onChanged(updated!); }
  }
  Future<void> _star(bool starred) async {
    if (_starBusy) return;
    final shared = widget.starControl;
    if (shared != null) {
      final generation = _generation;
      try {
        final updated = await shared.setStar(starred);
        if (mounted &&
            _current(generation) &&
            _details != null &&
            updated?['star_count'] is int) {
          setState(
            () =>
                _details = {..._details!, 'star_count': updated!['star_count']},
          );
        }
        if (mounted && _current(generation)) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(starred ? '已加入星標' : '已移除星標')));
        }
      } catch (e) {
        if (mounted &&
            _current(generation) &&
            (e is! ApiFailure || e.kind != FailureKind.cancelled)) {
          showFailure(context, e);
        }
      }
      return;
    }
    final owner = widget, generation = _generation;
    ++_overviewEpoch;
    setState(() => _busy = true);
    try {
      final updated = await owner.api.setStar(owner.project.id, starred);
      if (mounted && _current(generation)) {
        setState(() {
          _starred = starred;
          if (_details != null && updated?['star_count'] is int) _details = {..._details!, 'star_count': updated!['star_count']};
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(starred ? '已加入星標' : '已移除星標')));
      }
    } catch (e) { if (mounted && _current(generation)) { showFailure(context, e); } }
    finally { if (mounted && _current(generation)) { setState(() => _busy = false); } }
  }
  Future<void> _delete() async {
    final owner = widget, generation = _generation;
    if (_busy || !await confirmAction(context, '刪除整個專案？',
      '包含 repository、議題、MR 及相關資料。部分實例會先排程刪除；App 不會要求立即永久刪除。',
      requiredText: owner.project.path, onRoute: _ownRoute)) { return; }
    if (!mounted || !_current(generation)) { return; }
    setState(() => _busy = true);
    try {
      await owner.api.deleteProject(owner.project.id);
      if (mounted && _current(generation)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('GitLab 已接受專案刪除要求。')));
        if (owner.onDeleted != null) {
          owner.onDeleted!();
        } else {
          Navigator.pop(context);
        }
      }
    } catch (e) { if (mounted && _current(generation)) { showFailure(context, e); } }
    finally { if (mounted && _current(generation)) { setState(() => _busy = false); } }
  }
  @override
  Widget build(BuildContext context) {
    final account = widget.account, api = widget.api, project = widget.project;
    void metadata(MetadataKind kind) => _push(MetadataPage(account: account, api: api, project: project, kind: kind));
    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
      _overview(context),
      _section(context, '程式碼', [
        (
          Icons.analytics_outlined,
          '專案分析',
          () => _push(
            ProjectAnalyticsPage(
              account: account,
              api: api,
              project: project,
            ),
          ),
        ),
        (Icons.compare_arrows, '比較版本', () => _push(ComparePage(account: account, api: api, project: project))),
        (Icons.alt_route, metadataTitle(MetadataKind.branches), () => metadata(MetadataKind.branches)),
        (Icons.sell_outlined, metadataTitle(MetadataKind.tags), () => metadata(MetadataKind.tags)),
        (Icons.history, metadataTitle(MetadataKind.commits), () => metadata(MetadataKind.commits)),
        (Icons.account_tree_outlined, '儲存庫圖', () => _push(RepositoryGraphPage(account: account, api: api, project: project))),
        (Icons.code_outlined, 'Snippets', () => _push(SnippetsPage(account: account, api: api, project: project))),
        (Icons.manage_search, '搜尋程式碼與內容', () => _push(SearchPage(account: account, api: api, project: project))),
      ]),
      _section(context, '協作', [
        (Icons.view_kanban_outlined, '議題看板', () => _push(BoardsPage(account: account, api: api, project: project))),
        (Icons.workspaces_outline, '工作項目', () => _push(GraphWorkItemsPage(
          account: account, api: api, project: project,
          isCurrent: _sessionCurrent, ownerChanges: _session))),
        (Icons.task_alt, 'Tasks', () => _push(ProjectWorkItemsPage(account: account, api: api, project: project, type: ProjectWorkItemType.task))),
        (Icons.warning_amber_rounded, 'Incidents', () => _push(ProjectWorkItemsPage(account: account, api: api, project: project, type: ProjectWorkItemType.incident))),
        (Icons.timeline, '專案動態', () => _push(ActivityPage(account: account, api: api, project: project))),
        (Icons.group_outlined, '成員', () => _push(MembersPage(account: account, api: api, project: project))),
        (Icons.menu_book_outlined, 'Wiki', () => _push(WikiPagesPage(account: account, api: api, project: project))),
        (Icons.flag_outlined, metadataTitle(MetadataKind.milestones), () => metadata(MetadataKind.milestones)),
        (Icons.label_outline, metadataTitle(MetadataKind.labels), () => metadata(MetadataKind.labels)),
        (Icons.inventory_2_outlined, metadataTitle(MetadataKind.releases), () => metadata(MetadataKind.releases)),
      ]),
      _section(context, '部署', [
        (Icons.layers_outlined, '套件與容器 Registry', () => _push(RegistriesPage(account: account, api: api, project: project))),
        (Icons.dns_outlined, '環境', () => _push(EnvironmentsPage(account: account, api: api, project: project))),
        (Icons.rocket_launch_outlined, '部署紀錄', () => _push(DeploymentsPage(account: account, api: api, project: project))),
        (Icons.event_repeat_outlined, 'Pipeline 排程', () => _push(PipelineSchedulesPage(account: account, api: api, project: project))),
      ]),
      const SizedBox(height: 16),
      Padding(padding: const EdgeInsets.only(left: 4, bottom: 6), child: Text('專案管理',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
      Card(child: ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('名稱與說明'),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: _busy || project.archived == true ? null : _edit)),
      const SizedBox(height: 16), OutlinedButton.icon(onPressed: _busy ? null : _delete,
        icon: const Icon(Icons.delete_outline), label: const Text('刪除專案…')),
      const SizedBox(height: 12), Text('ID ${project.id} · @${account.user.username}', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
class MetadataPage extends StatefulWidget {
  const MetadataPage({super.key, required this.account, required this.api, required this.project, required this.kind});
  final Account account;
  final GitLabApi api;
  final Project project;
  final MetadataKind kind;
  @override
  State<MetadataPage> createState() => _MetadataPageState();
}
class _MetadataPageState extends State<MetadataPage> {
  final _feed = GlobalKey<RecordsFeedState>();
  bool _busy = false;
  int _generation = 0;
  NavigatorState? _navigator;
  Route<void>? _detailRoute;
  SessionController? _session;
  int? _sessionGeneration;

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

  bool _ownerCurrent(({
    String accountKey,
    GitLabApi api,
    int projectId,
    String projectPath,
    MetadataKind kind,
    int generation,
  }) owner) => mounted &&
      owner.generation == _generation &&
      !owner.api.isClosed &&
      widget.account.key == owner.accountKey &&
      identical(widget.api, owner.api) &&
      widget.project.id == owner.projectId &&
      widget.project.path == owner.projectPath &&
      widget.kind == owner.kind &&
      _sessionCurrent();

  void _sessionChanged() {
    if (_sessionCurrent()) return;
    _generation++;
    _dismissDetail();
    if (mounted) setState(() => _busy = false);
  }

  void _dismissDetail() {
    final navigator = _navigator;
    final route = _detailRoute;
    _detailRoute = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator?.mounted == true && route.isActive) {
        // Commits, files, a release and item lists opened from the detail
        // sit above it and share its owner; they leave with it.
        navigator!.popUntil((candidate) => candidate == route || candidate.isFirst);
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  @override
  void didUpdateWidget(covariant MetadataPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.project.path != widget.project.path ||
        oldWidget.kind != widget.kind ||
        widget.api.isClosed) {
      _generation++;
      _dismissDetail();
      _bindSession();
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    _generation++;
    _dismissDetail();
    super.dispose();
  }

  List<String> get path => ['projects', '${widget.project.id}',
    if (const [MetadataKind.branches, MetadataKind.tags, MetadataKind.commits].contains(widget.kind)) 'repository', widget.kind.name];
  String _name(Json value, [MetadataKind? as]) {
    final kind = as ?? widget.kind;
    return valueText(value, kind == MetadataKind.commits || kind == MetadataKind.milestones ? 'title' : 'name',
      valueText(value, 'tag_name'));
  }
  String _detail(Json value) => widget.kind == MetadataKind.commits
    ? valueText(value, 'author_name')
    : valueText(value, 'description', valueText(valueObject(value, 'commit'), 'title'));
  /// Leading mark per kind: label colour swatch, branch/tag/commit glyphs.
  Widget _leading(BuildContext context, Json value) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.kind == MetadataKind.labels) {
      final hex = valueText(value, 'color').replaceFirst('#', '');
      final parsed = int.tryParse(hex.length == 6 ? 'FF$hex' : hex, radix: 16);
      return Container(width: 40, height: 40, alignment: Alignment.center,
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
        child: Container(width: 16, height: 16,
          decoration: BoxDecoration(color: parsed == null ? scheme.outline : Color(parsed), shape: BoxShape.circle)));
    }
    final icon = switch (widget.kind) {
      MetadataKind.branches => Icons.alt_route, MetadataKind.tags => Icons.sell_outlined,
      MetadataKind.commits => Icons.commit, MetadataKind.releases => Icons.inventory_2_outlined,
      MetadataKind.milestones => Icons.flag_outlined, MetadataKind.labels => Icons.label_outline,
    };
    return Container(width: 40, height: 40, alignment: Alignment.center,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, size: 20, color: scheme.onSurfaceVariant));
  }
  List<Widget> _meta(Json value) => switch (widget.kind) {
    MetadataKind.commits => [
      MetaChip(shortSha(valueText(value, 'id')), mono: true),
      MetaChip(relativeDate(valueText(value, 'committed_date', valueText(value, 'created_at'))), icon: Icons.schedule_outlined),
    ],
    MetadataKind.branches => [
      if (value['default'] == true) const MetaChip('預設', icon: Icons.star_outline),
      if (value['protected'] == true) const MetaChip('受保護', icon: Icons.lock_outline),
      MetaChip(shortSha(valueText(valueObject(value, 'commit'), 'id')), mono: true),
    ],
    MetadataKind.tags => [
      MetaChip(shortSha(valueText(valueObject(value, 'commit'), 'id')), mono: true),
      if (valueText(value, 'message').isNotEmpty) const MetaChip('附註標籤', icon: Icons.notes_outlined),
    ],
    MetadataKind.releases => [
      MetaChip(valueText(value, 'tag_name'), icon: Icons.sell_outlined, mono: true),
      MetaChip(relativeDate(valueText(value, 'released_at', valueText(value, 'created_at'))), icon: Icons.schedule_outlined),
      if (ReleaseAssets.fromJson(value['assets']).links case final links when links.isNotEmpty)
        MetaChip('${links.length} 個附件', icon: Icons.attach_file),
    ],
    MetadataKind.milestones => [
      if (valueText(value, 'state').isNotEmpty) StatusBadge(valueText(value, 'state')),
      if (valueText(value, 'due_date').isNotEmpty) MetaChip('到期 ${valueText(value, 'due_date')}', icon: Icons.event_outlined),
    ],
    MetadataKind.labels => [
      if (valueInt(value, 'open_issues_count') > 0) MetaChip('${valueInt(value, 'open_issues_count')} 則開啟議題', icon: Icons.adjust),
    ],
  };
  String _id(Json value) => switch (widget.kind) {
    MetadataKind.branches || MetadataKind.tags => requiredString(value, 'name'),
    MetadataKind.releases => requiredString(value, 'tag_name'),
    MetadataKind.commits => requiredString(value, 'id'),
    _ => '${requiredInt(value, 'id')}',
  };
  bool _canEdit(Json value) => !const [MetadataKind.branches, MetadataKind.tags, MetadataKind.commits].contains(widget.kind);
  bool _canDelete(Json value) => widget.kind != MetadataKind.commits &&
    !(widget.kind == MetadataKind.branches && (value['default'] == true || value['protected'] == true));
  List<EditField> _fields(Json? value) {
    final data = value ?? <String, dynamic>{};
    final ref = widget.project.defaultBranch ?? 'main';
    return switch (widget.kind) {
      MetadataKind.branches => [const EditField('branch', '新分支名稱', required: true),
        EditField('ref', '來源 ref 或 commit SHA', required: true, value: ref)],
      MetadataKind.tags => [const EditField('tag_name', '新標籤名稱', required: true),
        EditField('ref', '來源 ref 或 commit SHA', required: true, value: ref), const EditField('message', '標籤訊息', lines: 3)],
      MetadataKind.releases => [
        if (value == null) const EditField('tag_name', '既有 Git tag', required: true),
        EditField('name', 'Release 名稱', required: true, value: valueText(data, 'name')),
        EditField('description', '發行說明', lines: 9, value: valueText(data, 'description'), hint: '支援 Markdown'),
      ],
      MetadataKind.labels => [EditField('name', '名稱', required: true, value: valueText(data, 'name')),
        EditField('color', '顏色', required: true, value: valueText(data, 'color', '#4763e4'), hint: '#RRGGBB'),
        EditField('description', '說明', lines: 3, value: valueText(data, 'description'))],
      MetadataKind.milestones => [EditField('title', '標題', required: true, value: valueText(data, 'title')),
        EditField('description', '說明', lines: 5, value: valueText(data, 'description')),
        EditField('start_date', '開始日期', value: valueText(data, 'start_date'), hint: 'YYYY-MM-DD；可留白'),
        EditField('due_date', '到期日期', value: valueText(data, 'due_date'), hint: 'YYYY-MM-DD；可留白')],
      MetadataKind.commits => [],
    };
  }
  Future<void> _edit([Json? value]) async {
    if (_busy) { return; }
    final saved = await openEditor(context, account: widget.account,
      title: metadataPhrase(value == null ? '新增' : '編輯', widget.kind),
      resource: '${widget.project.id}/${widget.kind.name}/${value == null ? 'new' : _id(value)}',
      subtitle: widget.project.path, fields: _fields(value), save: (values) async {
        final body = <String, dynamic>{...values};
        if (widget.kind == MetadataKind.labels && !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(values['color'] ?? '')) {
          throw const ApiFailure(FailureKind.validation);
        }
        if (widget.kind == MetadataKind.milestones) {
          for (final key in ['start_date', 'due_date']) {
            final date = values[key]?.trim() ?? '';
            if (date.isNotEmpty && (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) || DateTime.tryParse(date) == null ||
                DateTime.parse(date).toIso8601String().substring(0, 10) != date)) {
              throw const ApiFailure(FailureKind.validation);
            }
            body[key] = date.isEmpty ? null : date;
          }
        }
        if (value == null) { await widget.api.writeRecord('POST', path, body); }
        else { await widget.api.writeRecord('PUT', [...path, _id(value)], body); }
      });
    if (saved && mounted) { await _feed.currentState?.refresh(); }
  }
  Future<void> _delete(Json value) async {
    if (_busy || !await confirmAction(context, '${metadataPhrase('刪除', widget.kind)}？', _name(value), requiredText: _name(value))) { return; }
    if (!mounted) { return; }
    setState(() => _busy = true);
    try {
      await widget.api.removeRecord([...path, _id(value)]);
      if (mounted) { await _feed.currentState?.refresh(); }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  Future<void> _state(Json value) async {
    if (_busy) { return; }
    setState(() => _busy = true);
    try {
      await widget.api.writeRecord('PUT', [...path, _id(value)], {'state_event': value['state'] == 'closed' ? 'activate' : 'close'});
      if (mounted) { await _feed.currentState?.refresh(); }
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() => _busy = false); } }
  }
  static Widget _inset(Widget child) => Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: child);

  /// The branch or tag pinned to its commit, or null without a valid SHA.
  static RepositoryRef? _pinnedRef(Json value, MetadataKind kind) {
    try {
      return switch (kind) {
        MetadataKind.branches => RepositoryRef.fromBranch(value),
        MetadataKind.tags => RepositoryRef.fromTag(value),
        _ => null,
      };
    } on FormatException {
      return null;
    } on ApiFailure {
      return null;
    }
  }

  /// Opens [page] above a detail: [_dismissDetail] removes it with that
  /// detail, and it shows nothing once the detail's owner is stale.
  void _pushFromDetail(bool Function() ownerCurrent, Widget page) {
    final navigator = _navigator;
    if (!ownerCurrent() || navigator == null || !navigator.mounted) return;
    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => _OwnerFence(isCurrent: ownerCurrent, changes: _session, child: page))));
  }

  Future<void> _view(Json value, [MetadataKind? as]) async {
    final kind = as ?? widget.kind;
    if (kind == MetadataKind.commits) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => CommitDetailPage(
            account: widget.account,
            api: widget.api,
            project: widget.project,
            sha: _id(value),
            initialCommit: value,
          ),
        ),
      );
      return;
    }
    final ownerAccount = widget.account;
    final ownerApi = widget.api;
    final ownerProject = widget.project;
    final ownerKind = widget.kind;
    final detailOwner = (
      accountKey: ownerAccount.key,
      api: ownerApi,
      projectId: ownerProject.id,
      projectPath: ownerProject.path,
      kind: ownerKind,
      generation: _generation,
    );
    if (!_ownerCurrent(detailOwner)) return;
    final detailTitle = _name(value, kind);
    final resourceId = switch (kind) {
      MetadataKind.releases => valueText(value, 'tag_name'),
      MetadataKind.milestones => valueInt(value, 'iid'),
      _ => null,
    };
    final Uri? shareUri = switch ((kind, resourceId)) {
      (MetadataKind.releases, final String tag) when tag.trim().isNotEmpty => () {
        final base = ownerAccount.instance.projectWeb(
          '${ownerProject.path}/-/releases',
        );
        return base.replace(pathSegments: [...base.pathSegments, tag]);
      }(),
      (MetadataKind.milestones, final int iid) when iid > 0 =>
        ownerAccount.instance.projectWeb(
          '${ownerProject.path}/-/milestones/$iid',
        ),
      _ => null,
    };
    bool ownerCurrent() => _ownerCurrent(detailOwner);
    final assets = kind == MetadataKind.releases ? ReleaseAssets.fromJson(value['assets']) : null;
    final projectSegments = ['projects', '${ownerProject.id}'];
    final commit = valueObject(value, 'commit');
    final commitSha = valueText(commit, 'id');
    final pinned = _pinnedRef(value, kind);
    final releaseTag = kind == MetadataKind.tags && value['release'] is Json ? valueText(value, 'name') : '';
    final tagMessage = kind == MetadataKind.tags ? valueText(value, 'message').trim() : '';
    final milestoneId = kind == MetadataKind.milestones ? valueInt(value, 'id') : 0;
    final labelName = kind == MetadataKind.labels ? valueText(value, 'name') : '';
    // A milestone lists everything assigned to it; a label lists what is open.
    final List<String> Function(String resource)? itemsPath = switch (kind) {
      MetadataKind.milestones when milestoneId > 0 =>
        (resource) => [...projectSegments, 'milestones', '$milestoneId', resource],
      MetadataKind.labels when labelName.isNotEmpty => (resource) => [...projectSegments, resource],
      _ => null,
    };
    Widget row(String key, IconData icon, String label, VoidCallback onTap, {Widget? subtitle}) => ListTile(
      key: ValueKey('metadata-detail-$key'), leading: Icon(icon),
      title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: subtitle,
      trailing: const Icon(Icons.chevron_right, size: 18), onTap: onTap);
    Widget rows(List<Widget> children) => _inset(Card(child: Column(children: [
      for (final (index, child) in children.indexed) ...[
        if (index > 0) const Divider(height: 1, indent: 56),
        child,
      ],
    ])));
    final codeRows = <Widget>[
      if (commitSha.isNotEmpty) row('commit', Icons.commit, valueText(commit, 'title', shortSha(commitSha)),
        subtitle: Text(shortSha(commitSha), style: codeTextStyle(context, fontSize: 12)),
        () => _pushFromDetail(ownerCurrent, CommitDetailPage(account: ownerAccount, api: ownerApi,
          project: ownerProject, sha: commitSha, initialCommit: commit))),
      if (pinned != null) row('browse', Icons.folder_open_outlined, '瀏覽檔案',
        subtitle: Text('固定於 ${shortSha(pinned.sha)}'),
        () => _pushFromDetail(ownerCurrent, Scaffold(
          appBar: AppBar(title: Text(detailTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          body: gestureSafe(RepositoryTab(account: ownerAccount, api: ownerApi, project: ownerProject,
            initialRef: pinned))))),
      if (releaseTag.isNotEmpty) _ReleaseLink(account: ownerAccount, isCurrent: ownerCurrent,
        target: '${ownerProject.path} · Release $releaseTag',
        load: () => ownerApi.record([...projectSegments, 'releases', releaseTag]),
        open: (release) => _view(release, MetadataKind.releases)),
    ];
    final itemRows = <Widget>[
      if (itemsPath != null)
        for (final (resource, icon, label, empty) in kind == MetadataKind.labels
            ? const [('issues', Icons.adjust, '議題', '沒有開啟中的議題'),
                ('merge_requests', Icons.merge, '合併請求', '沒有開啟中的合併請求')]
            : const [('issues', Icons.adjust, '議題', '這個里程碑沒有議題'),
                ('merge_requests', Icons.merge, '合併請求', '這個里程碑沒有合併請求')])
          row(resource, icon, label, () => _pushFromDetail(ownerCurrent, _MetadataWorkItemsPage(
            account: ownerAccount, api: ownerApi, project: ownerProject, title: '$detailTitle · $label',
            empty: empty, resource: resource, path: itemsPath(resource),
            query: kind == MetadataKind.labels ? {'labels': labelName, 'state': 'opened'} : const {},
            isCurrent: ownerCurrent, ownerChanges: _session))),
    ];
    final route = MaterialPageRoute<void>(builder: (_) => Scaffold(
      appBar: AppBar(title: Text(detailTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (shareUri != null)
                ResourceShareButton(
                  uri: shareUri,
                  ownerKey: (
                    ownerAccount.key,
                    ownerApi,
                    ownerProject.id,
                    ownerProject.path,
                    kind,
                    resourceId,
                  ),
                  isCurrent: ownerCurrent,
                ),
            ],
          ), body: gestureSafe(ListView(padding: const EdgeInsets.symmetric(vertical: 20), children: [
        _inset(Text(ownerProject.path, style: Theme.of(context).textTheme.bodySmall)), const SizedBox(height: 16),
        if (value['state'] is String) _inset(Align(alignment: Alignment.centerLeft, child: StatusBadge(valueText(value, 'state')))),
        if (kind == MetadataKind.branches && (value['default'] == true || value['protected'] == true)) ...[
          _inset(Wrap(spacing: 8, runSpacing: 8, children: [
            if (value['default'] == true) const MetaChip('預設', icon: Icons.star_outline),
            if (value['protected'] == true) const MetaChip('受保護', icon: Icons.lock_outline),
          ])),
          const SizedBox(height: 16),
        ],
        if (kind == MetadataKind.releases) ...[
          _inset(Wrap(spacing: 8, runSpacing: 8, children: [
            MetaChip(valueText(value, 'tag_name'), icon: Icons.sell_outlined, mono: true),
            MetaChip(relativeDate(valueText(value, 'released_at', valueText(value, 'created_at'))), icon: Icons.schedule_outlined),
          ])),
          const SizedBox(height: 16),
        ],
        if (assets != null && !assets.isEmpty) ...[
          ReleaseAssetsSection(account: ownerAccount, api: ownerApi, project: ownerProject, assets: assets,
            isCurrent: ownerCurrent, ownerChanges: _session),
          const SizedBox(height: 16),
        ],
        // A branch has no text of its own; a tag message is plain text.
        if (kind == MetadataKind.tags) ...[
          if (tagMessage.isNotEmpty) _inset(SelectableText(tagMessage)),
        ] else if (kind != MetadataKind.branches)
          _inset(MarkdownView(valueText(value, 'description', valueText(value, 'message', '尚未填寫說明。')),
            base: ownerAccount.instance.projectWeb(ownerProject.path), api: ownerApi, projectId: ownerProject.id,
            projectWeb: ownerAccount.instance.projectWeb(ownerProject.path), projectPath: ownerProject.path)),
        if (codeRows.isNotEmpty) ...[const SizedBox(height: 20), rows(codeRows)],
        if (kind == MetadataKind.milestones) ...[const SizedBox(height: 16),
          _inset(Text('開始：${valueText(value, 'start_date', '未設定')}\n到期：${valueText(value, 'due_date', '未設定')}'))],
        if (itemRows.isNotEmpty) ...[const SizedBox(height: 20), rows(itemRows)],
      ])),
    ));
    // A release opened from its tag stacks on the tag's detail, which stays
    // the route that dismissal removes together with everything above it.
    _detailRoute ??= route;
    try {
      await (_navigator ?? Navigator.of(context)).push<void>(route);
    } finally {
      if (identical(_detailRoute, route)) {
        _detailRoute = null;
      }
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(metadataTitle(widget.kind)), actions: [
    if (!widget.api.isClosed && _sessionCurrent() && widget.kind != MetadataKind.commits) IconButton(tooltip: metadataPhrase('新增', widget.kind),
      onPressed: _busy || widget.project.archived == true ? null : _edit, icon: const Icon(Icons.add)),
  ]), body: widget.api.isClosed || !_sessionCurrent() ? const SizedBox.shrink() : gestureSafe(RecordsFeed(key: _feed, identity: '${widget.account.key}/${widget.project.id}/${widget.kind.name}/$_generation',
    account: widget.account, resourceLabel: '${widget.project.path} · ${metadataTitle(widget.kind)}',
    onSwitchAccount: endSessionFrom(context),
    empty: metadataPhrase('尚無', widget.kind), load: (next) => widget.api.records(path,
      query: {if (widget.kind == MetadataKind.labels) 'include_ancestor_groups': 'false'}, next: next),
    itemBuilder: (context, value) => EntityCard(
      onTap: () => _view(value),
      leading: _leading(context, value),
      title: Text(_name(value)),
      body: _detail(value).isEmpty ? null : Text(_detail(value), maxLines: 2, overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      meta: _meta(value),
      trailing: widget.kind == MetadataKind.commits || widget.project.archived == true ? null
        : PopupMenuButton<String>(tooltip: '項目操作', enabled: !_busy, onSelected: (action) {
          if (action == 'edit') { _edit(value); }
          if (action == 'delete') { _delete(value); }
          if (action == 'state') { _state(value); }
        }, itemBuilder: (_) => [
          if (_canEdit(value)) const PopupMenuItem(value: 'edit', child: Text('編輯')),
          if (widget.kind == MetadataKind.milestones) PopupMenuItem(value: 'state', child: Text(value['state'] == 'closed' ? '重新啟用' : '關閉里程碑')),
          if (_canDelete(value)) const PopupMenuItem(value: 'delete', child: Text('刪除')),
        ]),
    ),
  )));
}

/// Shows [child] only while the owner that opened it is current, so a page
/// still being dismissed after an account switch shows nothing of the old one.
class _OwnerFence extends StatelessWidget {
  const _OwnerFence({
    required this.isCurrent,
    required this.changes,
    required this.child,
  });
  final bool Function() isCurrent;
  final Listenable? changes;
  final Widget child;

  Widget _fenced(Widget child) =>
      isCurrent() ? child : const Scaffold(body: SizedBox.shrink());

  @override
  Widget build(BuildContext context) {
    final changes = this.changes;
    return changes == null
        ? _fenced(child)
        : ListenableBuilder(
            listenable: changes,
            builder: (context, child) => _fenced(child!),
            child: child,
          );
  }
}

/// 查看 Release on a tag: reads that tag's release, then opens its detail. A
/// failure stays on the tag with the account, the target, retry and switch.
class _ReleaseLink extends StatefulWidget {
  const _ReleaseLink({
    required this.account,
    required this.target,
    required this.isCurrent,
    required this.load,
    required this.open,
  });
  final Account account;
  final String target;
  final bool Function() isCurrent;
  final Future<Json> Function() load;
  final Future<void> Function(Json release) open;
  @override
  State<_ReleaseLink> createState() => _ReleaseLinkState();
}

class _ReleaseLinkState extends State<_ReleaseLink> {
  bool _loading = false;
  ApiFailure? _error;
  int _epoch = 0;

  bool _current(int epoch) => mounted && epoch == _epoch && widget.isCurrent();

  Future<void> _open() async {
    if (_loading || !widget.isCurrent()) return;
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    final Json release;
    try {
      release = await widget.load();
    } catch (e) {
      if (!_current(epoch)) return;
      final failure = safeFailure(e);
      setState(() {
        _loading = false;
        _error = failure.kind == FailureKind.cancelled ? null : failure;
      });
      return;
    }
    if (!_current(epoch)) return;
    setState(() => _loading = false);
    await widget.open(release);
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        key: const ValueKey('metadata-detail-release'),
        leading: const Icon(Icons.inventory_2_outlined),
        title: const Text('查看 Release'),
        trailing: _loading
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right, size: 18),
        onTap: _loading ? null : _open,
      ),
      if (_error != null)
        FailureNotice(
          _error!,
          account: widget.account,
          resourceLabel: widget.target,
          onRetry: _open,
          onSwitchAccount: endSessionFrom(context),
        ),
    ],
  );
}

/// Issues or merge requests in one milestone or under one label. Rows open
/// through [ResourceNavigator] under the owner of the detail they came from.
class _MetadataWorkItemsPage extends StatelessWidget {
  const _MetadataWorkItemsPage({
    required this.account,
    required this.api,
    required this.project,
    required this.title,
    required this.empty,
    required this.resource,
    required this.path,
    required this.query,
    required this.isCurrent,
    this.ownerChanges,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final String title, empty, resource;
  final List<String> path;
  final Map<String, String> query;
  final bool Function() isCurrent;
  final Listenable? ownerChanges;

  bool get _mr => resource == 'merge_requests';

  Future<ApiPage<Json>> _load(Uri? next) async {
    if (!isCurrent()) throw const ApiFailure(FailureKind.cancelled);
    final page = await api.records(path, query: query, next: next);
    if (!isCurrent()) throw const ApiFailure(FailureKind.cancelled);
    return page;
  }

  void _open(BuildContext context, Json data) {
    final iid = valueInt(data, 'iid'), projectId = valueInt(data, 'project_id');
    if (iid <= 0) return;
    unawaited(
      ResourceNavigator(
        account,
        api,
        isCurrent: isCurrent,
        ownerChanges: ownerChanges,
      ).workItem(
        context,
        '${projectId > 0 ? projectId : project.id}',
        resource,
        iid,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: gestureSafe(
      RecordsFeed(
        identity:
            '${account.key}/${project.id}/${path.join('/')}?${Uri(queryParameters: query).query}',
        account: account,
        resourceLabel: '${project.path} · $title',
        onSwitchAccount: endSessionFrom(context),
        empty: empty,
        emptyIcon: _mr ? Icons.merge : Icons.adjust,
        load: _load,
        itemBuilder: (context, data) => workItemCard(
          context,
          data,
          mr: _mr,
          onTap: () => _open(context, data),
        ),
      ),
    ),
  );
}
