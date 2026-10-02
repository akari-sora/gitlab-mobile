import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/snippet_models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'records_feed.dart';

class SnippetsPage extends StatefulWidget {
  const SnippetsPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
  });

  final Account account;
  final GitLabApi api;
  final Project project;

  @override
  State<SnippetsPage> createState() => _SnippetsPageState();
}

List<EditChoice> _visibilityChoices(Account account) => [
  for (final value in snippetVisibilitiesForHost(account.instance.base.host))
    EditChoice(value, snippetVisibilityLabel(value)),
];

void _dismissOwnedRoutes(
  NavigatorState? navigator,
  Set<Route<dynamic>> ownedRoutes,
) {
  final routes = ownedRoutes.toList(growable: false);
  ownedRoutes.clear();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (navigator == null || !navigator.mounted) return;
    for (final route in routes) {
      if (!route.isActive) continue;
      navigator.popUntil(
        (candidate) => candidate == route || candidate.isFirst,
      );
      if (route.isActive) navigator.removeRoute(route);
    }
  });
}

class _SnippetsPageState extends State<SnippetsPage> {
  final _feed = GlobalKey<RecordsFeedState>();
  final Set<Route<dynamic>> _ownedRoutes = {};
  NavigatorState? _navigator;
  int _generation = 0;

  List<String> get _path => ['projects', '${widget.project.id}', 'snippets'];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissRoutes() => _dismissOwnedRoutes(_navigator, _ownedRoutes);

  bool _currentOwner(
    int generation,
    Account account,
    GitLabApi api,
    Project project,
  ) =>
      mounted &&
      generation == _generation &&
      widget.account.key == account.key &&
      identical(widget.api, api) &&
      widget.project.id == project.id;

  @override
  void didUpdateWidget(covariant SnippetsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        !identical(oldWidget.api, widget.api)) {
      _generation++;
      _dismissRoutes();
    }
  }

  @override
  void dispose() {
    _generation++;
    _dismissRoutes();
    super.dispose();
  }

  Future<void> _create() async {
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final generation = _generation;
    final path = ['projects', '${project.id}', 'snippets'];
    int? createdId;
    final saved = await openEditor(
      context,
      account: account,
      api: api,
      projectId: project.id,
      projectPath: project.path,
      title: '新增 Snippet',
      subtitle: project.path,
      resource: '${project.id}/snippets/new',
      onRoute: _ownRoute,
      fields: [
        const EditField('title', '標題', required: true),
        const EditField('description', '說明', lines: 4, markdown: true),
        EditField.choice(
          'visibility',
          '可見性',
          choices: _visibilityChoices(account),
          value: 'private',
          required: true,
        ),
        const EditField('file_name', '檔名', required: true),
        const EditField('content', '內容', lines: 16, required: true),
      ],
      save: (values) async {
        if (!_currentOwner(generation, account, api, project)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        final payload = createSnippetPayload(
          title: values['title'] ?? '',
          description: values['description'] ?? '',
          visibility: (values['visibility'] ?? '').trim(),
          files: [
            SnippetFileInput(
              path: values['file_name'] ?? '',
              content: values['content'] ?? '',
            ),
          ],
        );
        final created = await api.writeRecord('POST', path, payload);
        if (!_currentOwner(generation, account, api, project)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        final id = requiredInt(created, 'id');
        final readbackJson = await api.record([...path, '$id']);
        final readback = ProjectSnippet.fromJson(readbackJson)
          ..requireProject(project.id);
        if (!readback.canUseLegacyRaw ||
            readback.title != payload['title'] ||
            readback.description != payload['description'] ||
            readback.visibility != payload['visibility'] ||
            readback.fileName != values['file_name']!.trim()) {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        final content = await api.snippetText(project.id, id);
        if (content != values['content']) {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        createdId = id;
      },
    );
    if (!saved || !_currentOwner(generation, account, api, project)) return;
    await _feed.currentState?.refresh();
    final id = createdId;
    if (id != null && mounted) await _open(id);
  }

  Future<void> _open(int id) async {
    final generation = _generation;
    final route = MaterialPageRoute<bool>(
      builder: (_) => _SnippetDetailPage(
        account: widget.account,
        api: widget.api,
        project: widget.project,
        snippetId: id,
      ),
    );
    _ownRoute(route);
    final deleted = await Navigator.push<bool>(context, route);
    if (mounted && generation == _generation && deleted != null) {
      await _feed.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Snippets')),
    floatingActionButton: FloatingActionButton.extended(
      key: const ValueKey('create-snippet'),
      onPressed: _create,
      icon: const Icon(Icons.add),
      label: const Text('新增'),
    ),
    body: RecordsFeed(
      key: _feed,
      identity: '${widget.account.key}/${widget.project.id}/snippets',
      storageId: 'snippets/${widget.account.key}/${widget.project.id}',
      account: widget.account,
      resourceLabel: '${widget.project.path} · Snippets',
      onSwitchAccount: endSessionFrom(context),
      empty: '這個專案沒有 Snippet',
      emptyDetail: '可建立私有 Snippet，集中保存短程式碼與文字片段。',
      emptyIcon: Icons.data_object,
      grouped: true,
      load: (next) => widget.api.records(_path, next: next),
      itemBuilder: (context, json) {
        final snippet = ProjectSnippet.fromJson(json)
          ..requireProject(widget.project.id);
        return ListTile(
          key: ValueKey('snippet-${snippet.id}'),
          leading: const Icon(Icons.code),
          title: Text(
            snippet.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            snippet.fileName.isEmpty
                ? '${snippet.authorName} · 多檔或未提供檔名'
                : '${snippet.fileName} · ${snippet.authorName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_open(snippet.id)),
        );
      },
    ),
  );
}

class _SnippetDetailPage extends StatefulWidget {
  const _SnippetDetailPage({
    required this.account,
    required this.api,
    required this.project,
    required this.snippetId,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final int snippetId;

  @override
  State<_SnippetDetailPage> createState() => _SnippetDetailPageState();
}

class _SnippetDetailPageState extends State<_SnippetDetailPage> {
  ProjectSnippet? _snippet;
  String? _content;
  ApiFailure? _error;
  bool _loading = true;
  bool _busy = false;
  int _generation = 0;
  final Set<Route<dynamic>> _ownedRoutes = {};
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissRoutes() => _dismissOwnedRoutes(_navigator, _ownedRoutes);

  bool _currentOwner(
    int generation,
    Account account,
    GitLabApi api,
    Project project,
    int snippetId,
  ) =>
      mounted &&
      generation == _generation &&
      widget.account.key == account.key &&
      identical(widget.api, api) &&
      widget.project.id == project.id &&
      widget.snippetId == snippetId;

  @override
  void didUpdateWidget(covariant _SnippetDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.snippetId != widget.snippetId ||
        !identical(oldWidget.api, widget.api)) {
      _dismissRoutes();
      _busy = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    _dismissRoutes();
    super.dispose();
  }

  Future<(ProjectSnippet, String)> _freshSingleFor(
    GitLabApi api,
    int projectId,
    int snippetId,
  ) async {
    final path = ['projects', '$projectId', 'snippets', '$snippetId'];
    final json = await api.record(path);
    final snippet = ProjectSnippet.fromJson(json)..requireProject(projectId);
    if (!snippet.canUseLegacyRaw) {
      throw ApiFailure(
        FailureKind.unsupported,
        title: snippet.hasExplicitFiles
            ? '多檔 Snippet 尚無法安全讀取'
            : '無法確認 Snippet 檔案清單',
        detail: snippet.hasExplicitFiles
            ? 'REST API 未提供可驗證的檔案 ref。為避免讀錯版本，這裡不猜測 main 或 master。'
            : 'file_name 不能證明 Snippet 只有一個檔案。伺服器未回傳可驗證的 files 清單，因此不顯示可能不完整的 legacy raw 內容。',
      );
    }
    return (snippet, await api.snippetText(projectId, snippetId));
  }

  Future<(ProjectSnippet, String)> _freshSingle() =>
      _freshSingleFor(widget.api, widget.project.id, widget.snippetId);

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fresh = await _freshSingle();
      if (!mounted || generation != _generation) return;
      setState(() {
        _snippet = fresh.$1;
        _content = fresh.$2;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = safeFailure(error);
        _loading = false;
      });
    }
  }

  Future<void> _edit() async {
    final snippet = _snippet;
    final content = _content;
    if (snippet == null || content == null || _busy) return;
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final snippetId = widget.snippetId;
    final generation = _generation;
    final path = ['projects', '${project.id}', 'snippets', '$snippetId'];
    final saved = await openEditor(
      context,
      account: account,
      api: api,
      projectId: project.id,
      projectPath: project.path,
      title: '編輯 Snippet',
      subtitle: project.path,
      resource: '${project.id}/snippets/${snippet.id}',
      baseRevision: snippet.updatedAt,
      onRoute: _ownRoute,
      fields: [
        EditField('title', '標題', value: snippet.title, required: true),
        EditField(
          'description',
          '說明',
          value: snippet.description,
          lines: 4,
          markdown: true,
        ),
        EditField.choice(
          'visibility',
          '可見性',
          choices: _visibilityChoices(account),
          value: snippet.visibility,
          required: true,
        ),
        EditField('file_name', '檔名', value: snippet.fileName, required: true),
        EditField('content', '內容', value: content, lines: 16, required: true),
      ],
      save: (values) async {
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        final fresh = await _freshSingleFor(api, project.id, snippetId);
        if (fresh.$1.updatedAt != snippet.updatedAt || fresh.$2 != content) {
          throw const ApiFailure(FailureKind.conflict);
        }
        final payload = updateSingleFileSnippetPayload(
          before: fresh.$1,
          title: values['title'] ?? '',
          description: values['description'] ?? '',
          visibility: (values['visibility'] ?? '').trim(),
          fileName: values['file_name'] ?? '',
          content: values['content'] ?? '',
          previousContent: fresh.$2,
        );
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        await api.writeRecord('PUT', path, payload);
        final readback = await _freshSingleFor(api, project.id, snippetId);
        if (readback.$1.title != (values['title'] ?? '').trim() ||
            readback.$1.description != (values['description'] ?? '') ||
            readback.$1.visibility != (values['visibility'] ?? '').trim() ||
            readback.$1.fileName != (values['file_name'] ?? '').trim() ||
            readback.$2 != (values['content'] ?? '')) {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
      },
    );
    if (saved && _currentOwner(generation, account, api, project, snippetId)) {
      await _load();
    }
  }

  Future<void> _delete() async {
    final snippet = _snippet;
    final content = _content;
    if (snippet == null || content == null || _busy) return;
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final snippetId = widget.snippetId;
    final generation = _generation;
    final path = ['projects', '${project.id}', 'snippets', '$snippetId'];
    final confirmed = await confirmAction(
      context,
      '刪除「${snippet.title}」？',
      'Snippet 與所有內容會永久刪除。',
      requiredText: '#${snippet.id}',
      onRoute: _ownRoute,
    );
    if (!confirmed ||
        !_currentOwner(generation, account, api, project, snippetId)) {
      return;
    }
    setState(() => _busy = true);
    try {
      final fresh = await _freshSingleFor(api, project.id, snippetId);
      if (fresh.$1.updatedAt != snippet.updatedAt || fresh.$2 != content) {
        throw const ApiFailure(FailureKind.conflict);
      }
      await api.removeRecord(path);
      if (!_currentOwner(generation, account, api, project, snippetId)) return;
      try {
        await api.record(path);
        throw const ApiFailure(FailureKind.writeUncertain);
      } on ApiFailure catch (failure) {
        if (failure.kind != FailureKind.invisible) rethrow;
      }
      if (mounted &&
          _currentOwner(generation, account, api, project, snippetId)) {
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted &&
          _currentOwner(generation, account, api, project, snippetId)) {
        showFailure(context, error);
      }
    } finally {
      if (_currentOwner(generation, account, api, project, snippetId)) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _body() {
    if (_loading) return const ListSkeleton();
    final error = _error;
    if (error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          FailureNotice(
            error,
            account: widget.account,
            resourceLabel:
                '${widget.project.path} · Snippet #${widget.snippetId}',
            onSwitchAccount: endSessionFrom(context),
            onRetry: error.kind == FailureKind.unsupported ? null : _load,
          ),
        ],
      );
    }
    final snippet = _snippet!;
    final lines = _content!.split('\n');
    final truncatedLineCount = lines.where((line) => line.length > 2000).length;
    final gutter = feedGutter(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        key: PageStorageKey(
          '${widget.account.key}/${widget.project.id}/snippets/${snippet.id}',
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 8),
            sliver: SliverList.list(
              children: [
                Text(
                  snippet.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    Chip(label: Text(snippet.visibility)),
                    Chip(label: Text(snippet.fileName)),
                    Chip(label: Text(snippet.authorName)),
                  ],
                ),
                if (snippet.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  MarkdownView(
                    snippet.description,
                    base: widget.account.instance.projectWeb(
                      widget.project.path,
                    ),
                    api: widget.api,
                    projectId: widget.project.id,
                    projectWeb: widget.account.instance.projectWeb(
                      widget.project.path,
                    ),
                    projectPath: widget.project.path,
                    account: widget.account,
                  ),
                ],
                const SizedBox(height: 12),
                Text('內容', style: Theme.of(context).textTheme.titleMedium),
                if (truncatedLineCount > 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    '$truncatedLineCount 行超過 2,000 字元，預覽已截短；編輯時保留完整內容。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
            sliver: SliverList.builder(
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final raw = lines[index];
                final truncated = raw.length > 2000;
                final shown = truncated ? '${raw.substring(0, 2000)} …' : raw;
                return Container(
                  color: index.isEven
                      ? Theme.of(context).colorScheme.surfaceContainerLow
                      : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${index + 1}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          shown.isEmpty ? ' ' : shown,
                          style: codeTextStyle(context),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Snippet #${widget.snippetId}'),
      actions: [
        IconButton(
          tooltip: '編輯 Snippet',
          onPressed: _snippet == null || _busy ? null : _edit,
          icon: const Icon(Icons.edit_outlined),
        ),
        PopupMenuButton<String>(
          tooltip: '更多操作',
          enabled: _snippet != null && !_busy,
          onSelected: (value) {
            if (value == 'delete') unawaited(_delete());
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'delete', child: Text('刪除')),
          ],
        ),
      ],
    ),
    body: _body(),
  );
}
