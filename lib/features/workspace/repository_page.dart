import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/repository_ref.dart';
import '../../shared/markdown_view.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'records_feed.dart';

class RepositoryTab extends StatefulWidget {
  const RepositoryTab({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.active = true,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final bool active;
  @override
  State<RepositoryTab> createState() => _RepositoryTabState();
}

class _RepositoryTabState extends State<RepositoryTab> {
  RepositoryRef? _currentRef;
  String _folder = '';
  ApiFailure? _error;
  bool _loading = true;
  int _epoch = 0;
  final _feed = GlobalKey<RecordsFeedState>();

  RepositoryReadme? _readme;
  bool _readmeLoading = false;
  ApiFailure? _readmeError;
  bool _readmeExpanded = false;
  String? _readmeCandidatePath;

  static const _readmeCandidateNames = <String>[
    'readme.md',
    'readme.markdown',
    'readme.mdown',
    'readme.mkdn',
    'readme',
    'index.md',
  ];

  @override
  void initState() {
    super.initState();
    final defaultBranch = widget.project.defaultBranch;
    if (defaultBranch != null && defaultBranch.isNotEmpty) {
      _currentRef = RepositoryRef(
        kind: RepositoryRefKind.branch,
        name: defaultBranch,
        sha: '',
        protected: false,
        isDefault: true,
      );
      unawaited(_resolve());
    } else {
      _loading = false;
    }
  }

  Future<void> _resolve() async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ref = _currentRef ??
          RepositoryRef(
            kind: RepositoryRefKind.branch,
            name: widget.project.defaultBranch ?? 'main',
            sha: '',
            protected: false,
            isDefault: true,
          );

      final Json value;
      final RepositoryRef resolved;
      if (ref.kind == RepositoryRefKind.branch) {
        value = await widget.api.record([
          'projects',
          '${widget.project.id}',
          'repository',
          'branches',
          ref.name,
        ]);
        resolved = RepositoryRef.fromBranch(value);
      } else {
        value = await widget.api.record([
          'projects',
          '${widget.project.id}',
          'repository',
          'tags',
          ref.name,
        ]);
        resolved = RepositoryRef.fromTag(value);
      }

      if (mounted && epoch == _epoch) {
        final shaChanged = _currentRef?.sha != resolved.sha;
        setState(() {
          _currentRef = resolved;
          if (shaChanged) {
            _readme = null;
            _readmeCandidatePath = null;
            _readmeError = null;
          }
        });
      }
    } catch (e) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = safeFailure(e));
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() => _loading = false);
      }
    }
  }

  void _up() {
    final parts = _folder.split('/')..removeLast();
    setState(() => _folder = parts.join('/'));
  }

  Future<void> _pickRef() async {
    final current = _currentRef ??
        RepositoryRef(
          kind: RepositoryRefKind.branch,
          name: widget.project.defaultBranch ?? 'main',
          sha: '',
          protected: false,
        );
    final selected = await Navigator.push<RepositoryRef>(
      context,
      MaterialPageRoute(
        builder: (context) => RepositoryRefPickerPage(
          account: widget.account,
          api: widget.api,
          project: widget.project,
          selected: current,
        ),
      ),
    );
    if (selected != null && mounted && selected != _currentRef) {
      setState(() {
        _epoch++;
        _currentRef = selected;
        _folder = '';
        _readme = null;
        _readmeCandidatePath = null;
        _readmeError = null;
      });
      unawaited(_feed.currentState?.refresh() ?? Future.value());
    }
  }

  void _detectReadmeCandidate(List<Json> items, String sha) {
    if (_readme != null || _readmeLoading || _readmeCandidatePath != null) return;
    for (final candidate in _readmeCandidateNames) {
      for (final item in items) {
        if (item['type'] == 'blob' && item['mode'] != '120000') {
          final name = (item['name'] as String? ?? '').toLowerCase();
          if (name == candidate) {
            final path = item['path'] as String? ?? item['name'] as String;
            _readmeCandidatePath = path;
            unawaited(_fetchReadme(path, sha, _epoch));
            return;
          }
        }
      }
    }
  }

  Future<void> _fetchReadme(String path, String sha, int epoch) async {
    if (!mounted) return;
    setState(() {
      _readmeLoading = true;
      _readmeError = null;
    });
    try {
      final text = await widget.api.textFile(
        widget.project.id,
        sha,
        path,
      );
      if (utf8.encode(text).length > 256 * 1024) {
        throw const ApiFailure(FailureKind.tooLarge);
      }
      if (mounted && _epoch == epoch && _currentRef?.sha == sha) {
        setState(() {
          _readme = RepositoryReadme(path: path, sha: sha, markdown: text);
          _readmeLoading = false;
        });
      }
    } catch (e) {
      if (mounted && _epoch == epoch && _currentRef?.sha == sha) {
        setState(() {
          _readmeError = safeFailure(e);
          _readmeLoading = false;
        });
      }
    }
  }

  Future<void> _newFile() async {
    final ref = _currentRef;
    if (ref == null || !ref.writable) return;
    final branch = ref.name;
    final saved = await openEditor(
      context,
      account: widget.account,
      title: '新增檔案',
      resource: '${widget.project.id}/files/new/$branch/$_folder',
      subtitle: '${widget.project.path} · $branch',
      fields: [
        EditField(
          'path',
          '完整檔案路徑',
          required: true,
          value: _folder.isEmpty ? '' : '$_folder/',
        ),
        const EditField('content', '內容', lines: 10),
        const EditField(
          'message',
          'Commit 訊息',
          required: true,
          value: 'Add file from GitLab Mobile',
        ),
      ],
      save: (values) async {
        await widget.api.saveFile(
          widget.project.id,
          values['path']!.trim(),
          branch: branch,
          content: values['content']!,
          message: values['message']!.trim(),
        );
      },
    );
    if (saved && mounted) {
      await _resolve();
    }
  }

  Future<void> _entry(Json data) async {
    final type = valueText(data, 'type');
    final path = requiredString(data, 'path');
    if (type == 'tree') {
      setState(() => _folder = path);
      return;
    }
    if (type != 'blob' || data['mode'] == '120000') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Submodule 與符號連結不會當成一般檔案開啟。')),
        );
      }
      return;
    }
    final ref = _currentRef;
    if (ref == null || ref.sha.isEmpty) return;

    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => RepositoryFilePage(
          account: widget.account,
          api: widget.api,
          project: widget.project,
          ref: ref,
          branch: ref.name,
          sha: ref.sha,
          filePath: path,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _resolve();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.active || _folder.isEmpty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && widget.active && _folder.isNotEmpty) {
        _up();
      }
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: _loading ? null : _pickRef,
                  icon: Icon(
                    _currentRef?.kind == RepositoryRefKind.tag
                        ? Icons.label_outline
                        : Icons.alt_route,
                    size: 18,
                  ),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _currentRef?.name ?? '選擇版本',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '重新讀取最新版本',
                onPressed: _loading ? null : _resolve,
                icon: const Icon(Icons.refresh, size: 20),
              ),
              if (_currentRef?.writable == true)
                IconButton(
                  tooltip: '新增檔案',
                  onPressed: widget.project.archived == true || _loading
                      ? null
                      : _newFile,
                  icon: const Icon(Icons.note_add_outlined, size: 20),
                ),
            ],
          ),
        ),
        if (_currentRef != null && _currentRef!.sha.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '固定版本 ${RepositoryRef.shortSha(_currentRef!.sha)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_folder.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一層目錄',
                  onPressed: _up,
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                Expanded(
                  child: Text(
                    _folder,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _folder = ''),
                  child: const Text('根目錄'),
                ),
              ],
            ),
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          FailureNotice(
            _error!,
            onRetry: _resolve,
            account: widget.account,
            resourceLabel: '${widget.project.path} · ${_currentRef?.name ?? ""}',
            onSwitchAccount: endSessionFrom(context),
          ),
        Expanded(
          child: _currentRef == null || _currentRef!.sha.isEmpty
              ? (_loading
                    ? const ListSkeleton()
                    : const SingleChildScrollView(
                        child: EmptyState(
                          'Repository 尚未初始化',
                          detail: '新增第一個檔案後就會顯示內容。',
                          icon: Icons.create_new_folder_outlined,
                        ),
                      ))
              : RecordsFeed(
                  key: _feed,
                  identity: '${widget.project.id}/${_currentRef!.sha}/$_folder',
                  empty: '此目錄沒有檔案',
                  account: widget.account,
                  resourceLabel: '${widget.project.path} · $_folder',
                  onSwitchAccount: endSessionFrom(context),
                  load: (next) async {
                    final page = await widget.api.records(
                      ['projects', '${widget.project.id}', 'repository', 'tree'],
                      query: {
                        'ref': _currentRef!.sha,
                        'path': _folder,
                        'per_page': '50',
                      },
                      next: next,
                    );
                    if (_folder.isEmpty) {
                      _detectReadmeCandidate(page.items, _currentRef!.sha);
                    }
                    return page;
                  },
                  itemBuilder: (context, data) => Card(
                    child: ListTile(
                      leading: Icon(
                        data['type'] == 'tree'
                            ? Icons.folder_outlined
                            : data['type'] == 'commit'
                            ? Icons.link
                            : Icons.description_outlined,
                        color: data['type'] == 'tree'
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(
                        valueText(data, 'name'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => _entry(data),
                    ),
                  ),
                  footer: (context, controller) {
                    if (_folder.isNotEmpty) return const SizedBox.shrink();
                    if (_readme == null && !_readmeLoading && _readmeError == null) {
                      return const SizedBox.shrink();
                    }
                    return RepositoryReadmeCard(
                      readme: _readme,
                      loading: _readmeLoading,
                      error: _readmeError,
                      expanded: _readmeExpanded,
                      onToggle: () => setState(() => _readmeExpanded = !_readmeExpanded),
                      onRetry: () {
                        if (_readmeCandidatePath != null && _currentRef != null) {
                          _fetchReadme(_readmeCandidatePath!, _currentRef!.sha, _epoch);
                        }
                      },
                      account: widget.account,
                      project: widget.project,
                      api: widget.api,
                      onSwitchAccount: endSessionFrom(context),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class RepositoryReadmeCard extends StatelessWidget {
  const RepositoryReadmeCard({
    super.key,
    required this.readme,
    required this.loading,
    required this.error,
    required this.expanded,
    required this.onToggle,
    required this.onRetry,
    required this.account,
    required this.project,
    this.api,
    this.onSwitchAccount,
  });

  final RepositoryReadme? readme;
  final bool loading;
  final ApiFailure? error;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onRetry;
  final Account account;
  final Project project;
  final GitLabApi? api;
  final VoidCallback? onSwitchAccount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = readme?.path ?? 'README.md';

    return Card(
      margin: const EdgeInsets.only(top: 16, bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: InkWell(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.menu_book_outlined, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (readme != null)
                            Text(
                              '固定版本 ${RepositoryRef.shortSha(readme!.sha)}',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: expanded ? '收合 README' : '展開 README',
                      onPressed: onToggle,
                      icon: Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: FailureNotice(
                  error!,
                  account: account,
                  resourceLabel: '${project.path} · $title',
                  onRetry: onRetry,
                  onSwitchAccount: onSwitchAccount,
                ),
              )
            else if (readme != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: MarkdownView(
                  readme!.markdown,
                  base: account.instance.projectWeb(
                    '${project.path}/-/blob/${readme!.sha}/${readme!.path}',
                  ),
                  api: api,
                  projectId: project.id,
                  projectWeb: account.instance.projectWeb(project.path),
                  projectPath: project.path,
                  account: account,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class RepositoryRefPickerPage extends StatefulWidget {
  const RepositoryRefPickerPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.selected,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final RepositoryRef selected;

  @override
  State<RepositoryRefPickerPage> createState() => _RepositoryRefPickerPageState();
}

enum RepositoryRefPickerMode { branches, tags }

class _RepositoryRefPickerPageState extends State<RepositoryRefPickerPage> {
  RepositoryRefPickerMode _mode = RepositoryRefPickerMode.branches;
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _mode = widget.selected.kind == RepositoryRefKind.tag
        ? RepositoryRefPickerMode.tags
        : RepositoryRefPickerMode.branches;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('選擇版本'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(110),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: SegmentedButton<RepositoryRefPickerMode>(
                  segments: const [
                    ButtonSegment(
                      value: RepositoryRefPickerMode.branches,
                      label: Text('分支'),
                      icon: Icon(Icons.alt_route),
                    ),
                    ButtonSegment(
                      value: RepositoryRefPickerMode.tags,
                      label: Text('標籤'),
                      icon: Icon(Icons.label_outline),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty && set.first != _mode) {
                      setState(() {
                        _mode = set.first;
                      });
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _search,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: _mode == RepositoryRefPickerMode.branches
                        ? '搜尋分支...'
                        : '搜尋標籤...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _search.clear();
                              _debounce?.cancel();
                              setState(() => _query = '');
                            },
                          )
                        : null,
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: RecordsFeed(
        key: ValueKey('ref-picker-${_mode.name}-$_query'),
        identity: 'ref-picker-${widget.project.id}-${_mode.name}-$_query',
        account: widget.account,
        resourceLabel: '${widget.project.path} · ${_mode == RepositoryRefPickerMode.branches ? "分支" : "標籤"}',
        onSwitchAccount: endSessionFrom(context),
        load: (next) => widget.api.records(
          [
            'projects',
            '${widget.project.id}',
            'repository',
            _mode == RepositoryRefPickerMode.branches ? 'branches' : 'tags',
          ],
          query: {
            if (_query.isNotEmpty) 'search': _query,
            'per_page': '30',
          },
          next: next,
        ),
        itemBuilder: (context, data) {
          final ref = _mode == RepositoryRefPickerMode.branches
              ? RepositoryRef.fromBranch(data)
              : RepositoryRef.fromTag(data);
          final isSelected = ref.name == widget.selected.name &&
              ref.kind == widget.selected.kind;

          return Card(
            child: ListTile(
              leading: Icon(
                ref.kind == RepositoryRefKind.branch
                    ? Icons.alt_route
                    : Icons.label_outline,
                color: isSelected ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      ref.name,
                      style: isSelected
                          ? TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (ref.isDefault)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('預設', style: TextStyle(fontSize: 11)),
                    ),
                  if (ref.protected)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '受保護',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                ],
              ),
              subtitle: Text(
                '固定版本 ${RepositoryRef.shortSha(ref.sha)}',
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: codeFontFamily,
                  fontFamilyFallback: ['Menlo', 'monospace'],
                ),
              ),
              trailing: isSelected
                  ? Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.pop(context, ref),
            ),
          );
        },
      ),
    );
  }
}

class RepositoryFilePage extends StatefulWidget {
  const RepositoryFilePage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.ref,
    this.branch = '',
    this.sha = '',
    required this.filePath,
    this.targetLine,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final RepositoryRef? ref;
  final String branch;
  final String sha;
  final String filePath;
  final int? targetLine;

  RepositoryRef get resolvedRef =>
      ref ??
      RepositoryRef(
        kind: RepositoryRefKind.branch,
        name: branch.isNotEmpty ? branch : (ref?.name ?? ''),
        sha: sha.isNotEmpty ? sha : (ref?.sha ?? ''),
        protected: false,
      );

  @override
  State<RepositoryFilePage> createState() => _RepositoryFilePageState();
}

class _RepositoryFilePageState extends State<RepositoryFilePage> {
  String? _text, _lastCommit;
  ApiFailure? _error;
  bool _loading = true, _busy = false, _preview = false, _wrap = true;
  late final bool _markdown;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  int? _selectedLine;
  List<String> _lines = const [];
  List<String> _searchLines = const [];
  List<int> _visibleIndices = const [];
  int _longestLineLength = 0;

  @override
  void initState() {
    super.initState();
    _markdown = RegExp(
      r'\.(md|markdown)$',
      caseSensitive: false,
    ).hasMatch(widget.filePath);
    _preview = _markdown && widget.targetLine == null;
    unawaited(_load());
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _indexLines(String text) {
    _lines = text.split('\n');
    _searchLines = [for (final line in _lines) line.toLowerCase()];
    _visibleIndices = List<int>.generate(_lines.length, (i) => i);
    _longestLineLength = _lines.fold<int>(0, (n, l) => math.max(n, l.length));
  }

  void _onSearchChanged(String value) {
    final q = value.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _visibleIndices = List<int>.generate(_lines.length, (i) => i);
      } else {
        _visibleIndices = [
          for (var i = 0; i < _searchLines.length; i++)
            if (_searchLines[i].contains(q)) i,
        ];
      }
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resolved = widget.resolvedRef;
      Json? meta;
      if (resolved.writable) {
        meta = await widget.api.fileMetadata(
          widget.project.id,
          widget.filePath,
          resolved.sha,
        );
      }
      final text = await widget.api.textFile(
        widget.project.id,
        resolved.sha,
        widget.filePath,
      );
      if (mounted) {
        _indexLines(text);
        final target = widget.targetLine;
        final hasTarget =
            target != null && target >= 1 && target <= _lines.length;
        setState(() {
          _text = text;
          _lastCommit = meta != null ? requiredString(meta, 'last_commit_id') : null;
          _loading = false;
          if (hasTarget) {
            _selectedLine = target;
          }
        });
        if (hasTarget) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollToLine(target);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = safeFailure(e);
          _loading = false;
        });
      }
    }
  }

  void _scrollToLine(int line) {
    if (!_vertical.hasClients) return;
    final position = _vertical.position;
    if (!position.hasContentDimensions) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToLine(line);
      });
      return;
    }
    final index = _visibleIndices.indexOf(line - 1);
    if (index < 0) return;
    final span = position.maxScrollExtent;
    final rowCount = _visibleIndices.isEmpty ? 1 : _visibleIndices.length;
    final estimatedRowHeight = span > 0
        ? (span + position.viewportDimension) / rowCount
        : 50.0;
    final target = (index * estimatedRowHeight - position.viewportDimension * 0.2)
        .clamp(0.0, span);
    if (target.isFinite) {
      _vertical.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _copyLinePermalink(int lineNumber) async {
    setState(() => _selectedLine = lineNumber);
    final uri = repositoryBlobWebUri(
      instance: widget.account.instance,
      projectPath: widget.project.path,
      sha: widget.resolvedRef.sha,
      filePath: widget.filePath,
      line: lineNumber,
    );
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已複製第 $lineNumber 行永久連結'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  bool get _lfs =>
      _text?.startsWith('version https://git-lfs.github.com/spec/v1') ?? false;

  Future<void> _checkCurrent() async {
    final current = await widget.api.fileMetadata(
      widget.project.id,
      widget.filePath,
      widget.resolvedRef.name,
    );
    if (current['last_commit_id'] != _lastCommit) {
      throw const ApiFailure(FailureKind.conflict);
    }
  }

  Future<void> _edit() async {
    if (!widget.resolvedRef.writable || _busy || _text == null || _lfs) {
      return;
    }
    final branch = widget.resolvedRef.name;
    final saved = await openEditor(
      context,
      account: widget.account,
      title: '編輯檔案',
      resource:
          '${widget.project.id}/files/$branch/${widget.filePath}/${widget.resolvedRef.sha}',
      subtitle: '${widget.filePath} · $branch',
      fields: [
        EditField('content', '內容', lines: 12, value: _text!),
        const EditField(
          'message',
          'Commit 訊息',
          required: true,
          value: 'Update file from GitLab Mobile',
        ),
      ],
      save: (values) async {
        await _checkCurrent();
        await widget.api.saveFile(
          widget.project.id,
          widget.filePath,
          branch: branch,
          content: values['content']!,
          message: values['message']!.trim(),
          lastCommit: _lastCommit,
        );
      },
    );
    if (saved && mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _delete() async {
    if (!widget.resolvedRef.writable || _busy || _lastCommit == null) {
      return;
    }
    final branch = widget.resolvedRef.name;
    if (!await confirmAction(
      context,
      '刪除檔案？',
      '${widget.filePath}\n分支 $branch\n會建立刪除檔案的 commit。',
      requiredText: widget.filePath,
    )) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _checkCurrent();
      await widget.api.deleteFile(
        widget.project.id,
        widget.filePath,
        branch: branch,
        message: 'Delete ${widget.filePath} from GitLab Mobile',
        lastCommit: _lastCommit!,
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        showFailure(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    final resolvedRef = widget.resolvedRef;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.filePath.split('/').last),
        actions: [
          if (_markdown)
            IconButton(
              tooltip: _preview ? '顯示原始文字' : 'Markdown 預覽',
              onPressed: () {
                setState(() => _preview = !_preview);
                if (!_preview && _selectedLine != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _scrollToLine(_selectedLine!);
                  });
                }
              },
              icon: Icon(_preview ? Icons.code : Icons.preview_outlined),
            ),
          PopupMenuButton<String>(
            tooltip: '檔案操作',
            onSelected: (action) {
              if (action == 'edit') {
                unawaited(_edit());
              }
              if (action == 'delete') {
                unawaited(_delete());
              }
              if (action == 'wrap') {
                setState(() => _wrap = !_wrap);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'wrap',
                child: Text(_wrap ? '關閉自動換行' : '開啟自動換行'),
              ),
              if (resolvedRef.writable &&
                  text != null &&
                  !_lfs &&
                  widget.project.archived != true &&
                  !_busy) ...[
                const PopupMenuItem(value: 'edit', child: Text('編輯檔案')),
                const PopupMenuItem(value: 'delete', child: Text('刪除檔案')),
              ],
            ],
          ),
        ],
      ),
      body: gestureSafe(Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              '${widget.filePath}\n${resolvedRef.name} · ${RepositoryRef.shortSha(resolvedRef.sha)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            FailureNotice(
              _error!,
              onRetry: _load,
              account: widget.account,
              resourceLabel: '${widget.project.path} · ${widget.filePath}',
              onSwitchAccount: endSessionFrom(context),
            ),
          if (_lfs)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('這是 Git LFS pointer，不是原始檔案。此版本不會自動下載大型物件。'),
            ),
          if (text != null && !_preview)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜尋目前檔案',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          Expanded(
            child: text == null
                ? const SizedBox()
                : _preview
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: MarkdownView(
                      text,
                      base: widget.account.instance.projectWeb(
                        '${widget.project.path}/-/blob/${resolvedRef.sha}/${widget.filePath}',
                      ),
                      api: widget.api,
                      projectId: widget.project.id,
                      projectWeb: widget.account.instance.projectWeb(widget.project.path),
                      projectPath: widget.project.path,
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final fontSize = MediaQuery.textScalerOf(
                        context,
                      ).scale(13);
                      final contentWidth = _wrap
                          ? constraints.maxWidth
                          : math.max(
                              constraints.maxWidth,
                              math.min(24000.0, _longestLineLength * fontSize * 0.65 + 80),
                            );
                      return Directionality(
                        textDirection: TextDirection.ltr,
                        child: Scrollbar(
                          controller: _horizontal,
                          child: SingleChildScrollView(
                            controller: _horizontal,
                            scrollDirection: Axis.horizontal,
                            physics: _wrap
                                ? const NeverScrollableScrollPhysics()
                                : null,
                            child: SizedBox(
                              width: contentWidth,
                              height: constraints.maxHeight,
                              child: SelectionArea(
                                child: ListView.builder(
                                  controller: _vertical,
                                  itemCount: _visibleIndices.length,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  itemBuilder: (context, index) {
                                    final lineIndex = _visibleIndices[index];
                                    final lineNumber = lineIndex + 1;
                                    final isSelected = _selectedLine == lineNumber;
                                    final lineContent = _lines[lineIndex];

                                    return Container(
                                      color: isSelected
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primaryContainer
                                              .withValues(alpha: 0.35)
                                          : null,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 1,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Semantics(
                                            button: true,
                                            selected: isSelected,
                                            label: '第 $lineNumber 行',
                                            hint: '點擊複製此行永久連結',
                                            child: InkWell(
                                              onTap: () => _copyLinePermalink(lineNumber),
                                              borderRadius: BorderRadius.circular(4),
                                              child: ConstrainedBox(
                                                constraints: const BoxConstraints(
                                                  minWidth: 48,
                                                  minHeight: 48,
                                                ),
                                                child: Align(
                                                  alignment: Alignment.centerLeft,
                                                  child: Text(
                                                    '$lineNumber',
                                                    textScaler:
                                                        MediaQuery.textScalerOf(
                                                          context,
                                                        ).clamp(maxScaleFactor: 1.3),
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.bodySmall?.copyWith(
                                                      color: isSelected
                                                          ? Theme.of(context).colorScheme.primary
                                                          : null,
                                                      fontWeight: isSelected
                                                          ? FontWeight.bold
                                                          : null,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(vertical: 14),
                                              child: Text(
                                                lineContent.isEmpty
                                                    ? ' '
                                                    : lineContent,
                                                style: const TextStyle(
                                                  fontFamily: codeFontFamily,
                                                  fontFamilyFallback: [
                                                    'Menlo',
                                                    'monospace',
                                                  ],
                                                  fontSize: 13,
                                                  height: 1.55,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      )),
    );
  }
}
