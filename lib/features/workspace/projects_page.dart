import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/project_locator.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import 'editor.dart';
import 'project_page.dart';
import 'records_feed.dart';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key, required this.session, this.forCi = false});
  final SessionController session;
  final bool forCi;
  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}
class _ProjectsPageState extends State<ProjectsPage> {
  final _search = TextEditingController();
  final _feed = GlobalKey<RecordsFeedState>();
  Timer? _debounce;
  int _scope = 0;
  String _query = '';
  bool _opening = false;
  Account get account => widget.session.active!;
  GitLabApi get api => widget.session.api!;
  @override
  void dispose() { _debounce?.cancel(); _search.dispose(); super.dispose(); }
  void _searchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () { if (mounted) setState(() => _query = value.trim()); });
  }
  Future<void> _open(Project project) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProjectPage(
      account: account, api: api, project: project, initialTab: widget.forCi ? 3 : 0)));
    if (mounted) unawaited(_feed.currentState?.refresh() ?? Future<void>.value());
  }
  Future<void> _locator() async {
    final input = TextEditingController();
    final locator = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('開啟專案'), content: TextField(controller: input, autofocus: true,
        autocorrect: false, decoration: const InputDecoration(labelText: '專案網址、完整路徑或 ID',
          hintText: 'group/project'), onSubmitted: (value) => Navigator.pop(context, value)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, input.text), child: const Text('開啟'))],
    ));
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), input.dispose));
    if (locator == null || !mounted || _opening) return;
    setState(() => _opening = true);
    try {
      final parsed = ProjectLocator.parse(locator, account.instance);
      final project = await api.project(parsed.idOrPath);
      if (mounted) await _open(project);
    } catch (e) { if (mounted) showFailure(context, e); }
    finally { if (mounted) setState(() => _opening = false); }
  }
  Future<void> _create() async {
    Project? created;
    final saved = await openEditor(context, account: account, title: '新增私有專案',
      resource: 'projects/new', subtitle: '新專案預設為私有，並建立 README。', fields: const [
        EditField('name', '專案名稱', required: true),
        EditField('path', '網址路徑', hint: '可留白，由 GitLab 依名稱產生'),
        EditField('description', '專案說明', lines: 4),
      ], save: (values) async {
        created = await api.createProject(name: values['name']!.trim(),
          path: values['path']!.trim().isEmpty ? null : values['path']!.trim(), description: values['description']!);
      });
    if (!mounted) return;
    if (saved && created != null) await _open(created!);
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.forCi ? 'CI / CD' : '專案'), actions: [
      IconButton(tooltip: '以連結或路徑開啟', onPressed: _opening ? null : _locator, icon: const Icon(Icons.link)),
      if (!widget.forCi) IconButton(tooltip: '新增專案', onPressed: _create, icon: const Icon(Icons.add)),
    ]),
    body: SafeArea(top: false, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: Row(children: [
        Monogram(account.user.name, size: 32), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('@${account.user.username}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall),
          Text(widget.forCi ? '選擇專案，查看流程與工作紀錄' : account.instance.base.host,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ])),
        IconButton(tooltip: '切換帳號', onPressed: widget.session.endSession, icon: const Icon(Icons.swap_horiz, size: 20)),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TextField(
        key: const Key('projectSearch'), controller: _search, onChanged: _searchChanged,
        onSubmitted: (value) { _debounce?.cancel(); setState(() => _query = value.trim()); },
        decoration: InputDecoration(hintText: '搜尋專案', prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(tooltip: '清除搜尋', icon: const Icon(Icons.close, size: 18),
            onPressed: () { _search.clear(); _debounce?.cancel(); setState(() => _query = ''); })),
      )),
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Wrap(spacing: 8, runSpacing: 4,
        children: [for (var i = 0; i < 3; i++) ChoiceChip(
          label: Text(const ['我的專案', '星標', '所有可存取'][i]), selected: _scope == i,
          showCheckmark: false, onSelected: (_) => setState(() => _scope = i))])),
      if (_opening) const LinearProgressIndicator(minHeight: 2),
      Expanded(child: _scope == 2 && _query.isEmpty
        ? const SingleChildScrollView(child: EmptyState('搜尋所有可存取的專案',
            icon: Icons.search, detail: '輸入名稱查找公開與私有專案，不限目前的成員專案。'))
        : RecordsFeed(key: _feed, identity: 'projects/$_scope/$_query',
          account: account, resourceLabel: '專案列表', underShell: true,
          onSwitchAccount: widget.session.endSession,
          empty: _query.isEmpty ? '目前沒有專案' : '找不到符合的專案',
          emptyDetail: '可使用右上角連結，以完整路徑或 ID 開啟。',
          load: (next) => api.records(['projects'], query: {
            'order_by': 'last_activity_at', 'sort': 'desc',
            if (_scope == 0) 'membership': 'true', if (_scope == 1) 'starred': 'true',
            if (_query.isNotEmpty) 'search': _query,
          }, next: next),
          itemBuilder: (context, data) {
            final project = Project.fromJson(data);
            return Card(child: InkWell(borderRadius: BorderRadius.circular(16), onTap: () => _open(project),
              child: Padding(padding: const EdgeInsets.all(16), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Monogram(project.name), const SizedBox(width: 12), Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(project.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 2), Text(project.path.split('/').take(project.path.split('/').length - 1).join('/'),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ])), const SizedBox(width: 6), const Icon(Icons.chevron_right, size: 18),
                  ]),
                  if (project.description?.isNotEmpty ?? false) Padding(padding: const EdgeInsets.only(top: 10),
                    child: Text(project.description!, maxLines: 2, overflow: TextOverflow.ellipsis)),
                  const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
                    children: [StatusBadge(project.visibility ?? ''),
                      if (project.archived == true) const Text('已封存', style: TextStyle(fontSize: 12)),
                      Text(relativeDate(valueText(data, 'last_activity_at')), style: Theme.of(context).textTheme.bodySmall)]),
                ],
              )),
            ));
          },
        )),
    ])),
  );
}
