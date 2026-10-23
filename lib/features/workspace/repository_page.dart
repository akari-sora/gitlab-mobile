import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ai/ai_chat_page.dart';
import '../ai/ai_chat_session.dart';
import '../../core/ai/tools/sensitive_paths.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/repository_ref.dart';
import '../../core/syntax_highlighter.dart';
import '../../shared/external_link.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/markdown_view.dart';
import '../../shared/motion.dart';
import '../../shared/resource_share.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/skeleton.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'file_history.dart';
import 'records_feed.dart';
import '../../core/brand.dart';

import '../../l10n/l10n.dart';
const _readmeCandidateNames = <String>[
  'readme.md',
  'readme.markdown',
  'readme.mdown',
  'readme.mkdn',
  'readme',
  'index.md',
];

/// The root README among tree [items], by name preference. Symbolic links
/// and non-blobs are never read as a README.
String? findReadmePath(Iterable<Json> items) {
  for (final candidate in _readmeCandidateNames) {
    for (final item in items) {
      if (item['type'] == 'blob' && item['mode'] != '120000') {
        final name = (item['name'] as String? ?? '').toLowerCase();
        if (name == candidate) {
          return item['path'] as String? ?? item['name'] as String;
        }
      }
    }
  }
  return null;
}

class RepositoryTab extends StatefulWidget {
  const RepositoryTab({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.active = true,
    this.initialRef,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final bool active;

  /// A resolved branch or tag to open pinned to its commit instead of the
  /// default branch's current head.
  final RepositoryRef? initialRef;
  @override
  State<RepositoryTab> createState() => RepositoryTabState();
}

class RepositoryTabState extends State<RepositoryTab> {
  RepositoryRef? _currentRef;
  String _folder = '';
  ApiFailure? _error;
  bool _loading = true;
  int _epoch = 0, _readEpoch = 0;
  final _feed = GlobalKey<RecordsFeedState>();
  ValueListenable<TickerModeData>? _tickerMode;
  bool _backgroundEnabled = true, _resumeWhenVisible = false;
  bool _stale = false, _revalidating = false;
  FailureKind? _backgroundFailure;
  DateTime? _backgroundRetryAt;
  CachedRead<Json>? _branchRead;

  RepositoryReadme? _readme;
  bool _readmeLoading = false;
  ApiFailure? _readmeError;
  bool _readmeExpanded = true;
  String? _readmeCandidatePath;
  String? _readmeFetchSha;
  int _readmeEpoch = 0;

  RepositoryRef? get currentRef => _currentRef;
  ApiFailure? get loadError => _error;
  DateTime? get fetchedAt => _branchRead?.fetchedAt;
  bool get stale => _stale;
  bool get revalidating => _revalidating;
  FailureKind? get backgroundFailure => _backgroundFailure;
  DateTime? get backgroundRetryAt => _backgroundRetryAt;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRef;
    final defaultBranch = widget.project.defaultBranch;
    if (initial != null &&
        initial.sha.isNotEmpty &&
        initial.kind != RepositoryRefKind.commit) {
      _currentRef = initial;
      _loading = false;
    } else if (defaultBranch != null && defaultBranch.isNotEmpty) {
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateTickerMode();
  }

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
    _backgroundEnabled = _tickerMode!.value.enabled;
    if (!_backgroundEnabled && _revalidating) _resumeWhenVisible = true;
    if (_backgroundEnabled) _startRevalidation(_epoch);
  }

  bool _readCurrent(int generation, int readEpoch) =>
      mounted && generation == _epoch && readEpoch == _readEpoch && !widget.api.isClosed;

  bool _canApplyRead(int generation, int readEpoch, {required bool background}) {
    if (!_readCurrent(generation, readEpoch)) return false;
    if (background && !_backgroundEnabled) {
      _stale = true;
      _resumeWhenVisible = true;
      return false;
    }
    return true;
  }

  bool _revoked(ApiFailure failure) => switch (failure.kind) {
    FailureKind.unauthenticated ||
    FailureKind.forbidden ||
    FailureKind.invisible => true,
    _ => false,
  };

  Future<CachedRead<Json>?> _readBranch(
    List<String> refPath, {
    required int generation,
    required int readEpoch,
    required bool fresh,
    required bool background,
  }) async {
    Future<CachedRead<Json>> readPage(bool force, {bool quiet = false}) => CachedRead.run(
      () => widget.api.cachedRecord(refPath, fresh: force, background: background),
      mayStart: () => _readCurrent(generation, readEpoch) &&
          (!background || _backgroundEnabled),
      waitForQuiet: quiet,
    );
    var read = await readPage(fresh);
    if (!_canApplyRead(generation, readEpoch, background: background)) return null;
    if (read.superseded) {
      read = await readPage(true);
      if (!_canApplyRead(generation, readEpoch, background: background)) return null;
      if (read.superseded) {
        read = await readPage(true, quiet: true);
        if (!_canApplyRead(generation, readEpoch, background: background)) return null;
      }
      if (read.superseded) throw const ApiFailure(FailureKind.cancelled);
    }
    return read.dropped ? null : read;
  }

  void _withdrawBranch() {
    // A revoked branch keeps its name so the retry resolves the same ref
    // instead of falling back to the default branch; only the SHA and the
    // content derived from it are cleared.
    final ref = _currentRef;
    _currentRef = ref == null
        ? null
        : RepositoryRef(kind: ref.kind, name: ref.name, sha: '', protected: ref.protected, isDefault: ref.isDefault);
    _branchRead = null;
    _stale = false;
  }

  /// Ends any in-flight README request and drops its result: the completion
  /// only applies when its generation is still current, so an old request
  /// can never clear a newer SHA's loading flag.
  void _resetReadme() {
    _readme = null;
    _readmeCandidatePath = null;
    _readmeFetchSha = null;
    _readmeError = null;
    _readmeExpanded = true;
    _readmeLoading = false;
    _readmeEpoch++;
  }

  Future<void> _resolve({bool fresh = false}) async {
    final generation = ++_epoch;
    final readEpoch = ++_readEpoch;
    setState(() {
      _loading = true;
      _error = null;
      _revalidating = false;
      _backgroundFailure = null;
      _backgroundRetryAt = null;
      _resumeWhenVisible = false;
    });
    try {
      final ref =
          _currentRef ??
          RepositoryRef(
            kind: RepositoryRefKind.branch,
            name: widget.project.defaultBranch ?? 'main',
            sha: '',
            protected: false,
            isDefault: true,
          );

      final List<String> refPath;
      final bool isBranch = ref.kind == RepositoryRefKind.branch;
      if (isBranch) {
        refPath = [
          'projects',
          '${widget.project.id}',
          'repository',
          'branches',
          ref.name,
        ];
      } else {
        refPath = [
          'projects',
          '${widget.project.id}',
          'repository',
          'tags',
          ref.name,
        ];
      }
      final read = await _readBranch(
        refPath,
        generation: generation,
        readEpoch: readEpoch,
        fresh: fresh,
        background: false,
      );
      if (!_readCurrent(generation, readEpoch)) return;
      if (read == null) {
        if (_currentRef?.sha.isEmpty != false) {
          setState(() => _error = const ApiFailure(FailureKind.cancelled));
        }
        return;
      }
      final RepositoryRef resolved = isBranch
          ? RepositoryRef.fromBranch(read.value)
          : RepositoryRef.fromTag(read.value);
      if (!_readCurrent(generation, readEpoch)) return;
      final shaChanged = _currentRef?.sha != resolved.sha;
      setState(() {
        _currentRef = resolved;
        _branchRead = read;
        _stale = read.stale;
        _loading = false;
        if (shaChanged) _resetReadme();
      });
      _startRevalidation(generation, readEpoch: readEpoch);
    } catch (e) {
      if (_readCurrent(generation, readEpoch)) {
        final failure = safeFailure(e);
        setState(() {
          _error = failure;
          if (_revoked(failure)) _withdrawBranch();
        });
      }
    } finally {
      if (_readCurrent(generation, readEpoch) && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  void _startRevalidation(int generation, {int? readEpoch}) {
    final epoch = readEpoch ?? _readEpoch;
    if (!_readCurrent(generation, epoch) ||
        !_backgroundEnabled ||
        !_stale ||
        _loading ||
        _revalidating ||
        _backgroundFailure != null ||
        _error != null) {
      return;
    }
    setState(() {
      _revalidating = true;
      _resumeWhenVisible = false;
    });
    unawaited(_revalidate(generation, epoch));
  }

  Future<void> _revalidate(int generation, int readEpoch) async {
    try {
      final ref = _currentRef;
      if (ref == null) return;
      final List<String> refPath = ref.kind == RepositoryRefKind.branch
          ? ['projects', '${widget.project.id}', 'repository', 'branches', ref.name]
          : ['projects', '${widget.project.id}', 'repository', 'tags', ref.name];
      final read = await _readBranch(
        refPath,
        generation: generation,
        readEpoch: readEpoch,
        fresh: true,
        background: true,
      );
      if (_canApplyRead(generation, readEpoch, background: true) && read != null) {
        final resolved = ref.kind == RepositoryRefKind.branch
            ? RepositoryRef.fromBranch(read.value)
            : RepositoryRef.fromTag(read.value);
        setState(() {
          final shaChanged = _currentRef?.sha != resolved.sha;
          _currentRef = resolved;
          _branchRead = read;
          _stale = read.stale;
          if (shaChanged) _resetReadme();
        });
      }
    } catch (e) {
      if (!_readCurrent(generation, readEpoch)) return;
      final failure = safeFailure(e);
      if (!_revoked(failure) && !_canApplyRead(generation, readEpoch, background: true)) return;
      setState(() {
        if (_revoked(failure)) {
          _withdrawBranch();
          _error = failure;
        } else {
          _backgroundFailure = failure.kind;
          _backgroundRetryAt = failure.retryAt;
        }
      });
    } finally {
      if (_readCurrent(generation, readEpoch)) {
        setState(() => _revalidating = false);
        if (_resumeWhenVisible && _backgroundEnabled) {
          _startRevalidation(generation, readEpoch: readEpoch);
        }
      }
    }
  }

  void _up() {
    final parts = _folder.split('/')..removeLast();
    setState(() => _folder = parts.join('/'));
  }

  Future<void> _pickRef() async {
    final current =
        _currentRef ??
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
        _readEpoch++;
        _currentRef = selected;
        _folder = '';
        _resetReadme();
        _branchRead = null;
        _stale = false;
        _revalidating = false;
        _resumeWhenVisible = false;
        _backgroundFailure = null;
        _backgroundRetryAt = null;
      });
      unawaited(_feed.currentState?.refresh() ?? Future.value());
    }
  }

  @override
  void didUpdateWidget(covariant RepositoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        !identical(oldWidget.api, widget.api)) {
      _epoch++;
      _readEpoch++;
      _currentRef = null;
      _folder = '';
      _error = null;
      _branchRead = null;
      _stale = false;
      _revalidating = false;
      _backgroundFailure = null;
      _backgroundRetryAt = null;
      _resumeWhenVisible = false;
      _resetReadme();
      _loading = true;
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
  }

  @override
  void dispose() {
    _epoch++;
    _readEpoch++;
    _tickerMode?.removeListener(_tickerModeChanged);
    super.dispose();
  }

  void _detectReadmeCandidate(List<Json> items, String sha) {
    if (_readme != null && _readme!.sha == sha) return;
    if (_readmeLoading && _readmeFetchSha == sha) return;
    final path = findReadmePath(items);
    if (path != null) {
      _readmeCandidatePath = path;
      _readmeFetchSha = sha;
      unawaited(_fetchReadme(path, sha, _epoch, ++_readmeEpoch));
    }
  }

  Future<void> _fetchReadme(String path, String sha, int epoch, int readmeEpoch) async {
    if (!mounted) return;
    setState(() {
      _readmeLoading = true;
      _readmeError = null;
    });
    try {
      // A foreground explicit read of SHA-pinned content (never stale). The
      // fence covers the page epoch so a stale page never applies the result;
      // visibility is intentionally not gated here because the tree that
      // triggered this read already passed the feed's own visibility fence.
      final text = await CachedRead.run(
        () => widget.api.textFile(widget.project.id, sha, path),
        mayStart: () => mounted && _epoch == epoch && !widget.api.isClosed,
      );
      if (utf8.encode(text).length > 256 * 1024) {
        throw const ApiFailure(FailureKind.tooLarge);
      }
      if (mounted && _epoch == epoch && _readmeEpoch == readmeEpoch) {
        setState(() {
          if (_currentRef?.sha == sha) {
            _readme = RepositoryReadme(path: path, sha: sha, markdown: text);
          }
          _readmeLoading = false;
        });
      }
    } catch (e) {
      if (mounted && _epoch == epoch && _readmeEpoch == readmeEpoch) {
        setState(() {
          if (_currentRef?.sha == sha) {
            _readmeError = safeFailure(e);
          }
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
      title: l10n.addFile,
      resource: '${widget.project.id}/files/new/$branch/$_folder',
      subtitle: '${widget.project.path} · $branch',
      fields: [
        EditField(
          'path',
          l10n.fullFilePath,
          required: true,
          value: _folder.isEmpty ? '' : '$_folder/',
        ),
        EditField('content', l10n.content, lines: 10),
        EditField(
          'message',
          l10n.commitMessage,
          required: true,
          value: 'Add file from $appName',
        ),
      ],
      save: (values) async {
        await widget.api.createRepositoryFile(
          widget.project.id,
          values['path']!.trim(),
          branch: branch,
          content: values['content']!,
          message: values['message']!.trim(),
        );
      },
    );
    if (saved && mounted) {
      await _resolve(fresh: true);
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
          SnackBar(content: Text(l10n.submoduleSymlinkNote)),
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
      await _resolve(fresh: true);
    }
  }

  Widget _refBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ref = _currentRef;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: TextButton(
                    onPressed: _loading ? null : _pickRef,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          ref?.kind == RepositoryRefKind.tag
                              ? Icons.label_outline
                              : Icons.alt_route,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            ref?.name ?? l10n.selectRevision,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 20),
                      ],
                    ),
                  ),
                ),
                if (ref != null && ref.sha.isNotEmpty)
                  Flexible(
                    child: Tooltip(
                      message: l10n.pinnedRevision(ref.sha),
                      child: Text(
                        RepositoryRef.shortSha(ref.sha),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: codeTextStyle(
                          context,
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (ref != null && ref.sha.isNotEmpty)
            IconButton(
              tooltip: l10n.findFile,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FindFilePage(
                    account: widget.account,
                    api: widget.api,
                    project: widget.project,
                    ref: ref,
                  ),
                ),
              ),
              icon: const Icon(Icons.search, size: 20),
            ),
          IconButton(
            tooltip: l10n.reloadLatestRevision,
            onPressed: _loading ? null : () => _resolve(fresh: true),
            icon: const Icon(Icons.refresh, size: 20),
          ),
          if (ref?.writable == true)
            IconButton(
              tooltip: l10n.addFile,
              onPressed: widget.project.archived == true || _loading
                  ? null
                  : _newFile,
              icon: const Icon(Icons.note_add_outlined, size: 20),
            ),
        ],
      ),
    );
  }

  /// Tappable path segments; the first one returns to the repository root.
  Widget _breadcrumbs(BuildContext context) {
    final theme = Theme.of(context);
    final segments = _folder.split('/');
    final style = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.primary,
    );
    return SizedBox(
      height: 40,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // Starts at the end so the current folder is visible on deep paths.
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: math.max(0, constraints.maxWidth - 16),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: l10n.parentDirectory,
                  visualDensity: VisualDensity.compact,
                  onPressed: _up,
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () => setState(() => _folder = ''),
                  child: Text(l10n.rootDirectory),
                ),
                for (var i = 0; i < segments.length; i++) ...[
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  if (i == segments.length - 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        isolated(segments[i]),
                        style: theme.textTheme.labelLarge,
                      ),
                    )
                  else
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () => setState(
                        () => _folder = segments.take(i + 1).join('/'),
                      ),
                      child: Text(isolated(segments[i]), style: style),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _treeRow(BuildContext context, Json data) {
    final scheme = Theme.of(context).colorScheme;
    final type = valueText(data, 'type');
    final name = valueText(data, 'name');
    final folder = type == 'tree';
    return InkWell(
      onTap: () => _entry(data),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                folder
                    ? Icons.folder
                    : type == 'commit'
                    ? Icons.link
                    : fileIconFor(name),
                size: 20,
                color: folder ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  isolated(name),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.3),
                ),
              ),
              if (folder)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Going up a folder also outranks the project overview and the shell,
  /// which take back from the dispatcher chain rather than from this scope.
  @override
  Widget build(BuildContext context) => DetailBackHold(
    holding: widget.active && _folder.isNotEmpty,
    child: _folderScope(context),
  );

  Widget _folderScope(BuildContext context) => PopScope(
    canPop: !widget.active || _folder.isEmpty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && widget.active && _folder.isNotEmpty) {
        _up();
      }
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_currentRef == null || _currentRef!.sha.isEmpty) _refBar(context),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          FailureNotice(
            _error!,
            onRetry: () => _resolve(fresh: true),
            account: widget.account,
            resourceLabel:
                '${widget.project.path} · ${_currentRef?.name ?? ""}',
            onSwitchAccount: endSessionFrom(context),
          ),
        Expanded(
          child: _currentRef == null || _currentRef!.sha.isEmpty
              ? (_loading
                    ? const RowsSkeleton()
                    : SingleChildScrollView(
                        child: EmptyState(
                          l10n.repositoryNotInitialized,
                          detail: l10n.contentAfterFirstFile,
                          icon: Icons.create_new_folder_outlined,
                        ),
                      ))
              : RecordsFeed(
                  key: _feed,
                  identity: '${widget.project.id}/${_currentRef!.sha}/$_folder',
                  empty: l10n.directoryEmpty,
                  emptyIcon: Icons.folder_open_outlined,
                  grouped: true,
                  account: widget.account,
                  resourceLabel: '${widget.project.path} · $_folder',
                  onSwitchAccount: endSessionFrom(context),
                  leading: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _refBar(context),
                      if (_folder.isNotEmpty) _breadcrumbs(context),
                    ],
                  ),
                  cached: ({required bool fresh, required bool background}) async {
                    final ref = _currentRef;
                    if (ref == null || ref.sha.isEmpty) {
                      throw const ApiFailure(FailureKind.cancelled);
                    }
                    final sha = ref.sha;
                    final folder = _folder;
                    final read = await widget.api.cachedRecords(
                      [
                        'projects',
                        '${widget.project.id}',
                        'repository',
                        'tree',
                      ],
                      query: {
                        'ref': sha,
                        'path': folder,
                        'per_page': '50',
                      },
                      fresh: fresh,
                      background: background,
                    );
                    if (folder.isEmpty && !read.dropped && !read.superseded) {
                      _detectReadmeCandidate(read.value.items, sha);
                    }
                    return read;
                  },
                  load: (next) async {
                    final ref = _currentRef;
                    if (ref == null || ref.sha.isEmpty) {
                      throw const ApiFailure(FailureKind.cancelled);
                    }
                    final sha = ref.sha;
                    final folder = _folder;
                    final page = await widget.api.records(
                      [
                        'projects',
                        '${widget.project.id}',
                        'repository',
                        'tree',
                      ],
                      query: {
                        'ref': sha,
                        'path': folder,
                        'per_page': '50',
                      },
                      next: next,
                    );
                    if (folder.isEmpty) {
                      _detectReadmeCandidate(page.items, sha);
                    }
                    return page;
                  },
                  itemBuilder: _treeRow,
                  footer: (context, controller) {
                    if (_folder.isNotEmpty) return const SizedBox.shrink();
                    if (_readme == null &&
                        !_readmeLoading &&
                        _readmeError == null) {
                      return const SizedBox.shrink();
                    }
                    return RepositoryReadmeCard(
                      readme: _readme,
                      loading: _readmeLoading,
                      error: _readmeError,
                      expanded: _readmeExpanded,
                      onToggle: () =>
                          setState(() => _readmeExpanded = !_readmeExpanded),
                      onRetry: () {
                        if (_readmeCandidatePath != null &&
                            _currentRef != null) {
                          _fetchReadme(
                            _readmeCandidatePath!,
                            _currentRef!.sha,
                            _epoch,
                            ++_readmeEpoch,
                          );
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
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
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
                              l10n.pinnedDiffVersion(RepositoryRef.shortSha(readme!.sha)),
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: expanded ? l10n.collapseReadme : l10n.expandReadme,
                      onPressed: onToggle,
                      icon: TurnChevron(open: expanded),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ExpandSection(expanded: expanded, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
          ])),
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
  State<RepositoryRefPickerPage> createState() =>
      _RepositoryRefPickerPageState();
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
        title: Text(l10n.selectRevision),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(110),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: SegmentedButton<RepositoryRefPickerMode>(
                  segments: [
                    ButtonSegment(
                      value: RepositoryRefPickerMode.branches,
                      label: Text(l10n.branchNoun),
                      icon: Icon(Icons.alt_route),
                    ),
                    ButtonSegment(
                      value: RepositoryRefPickerMode.tags,
                      label: Text(l10n.gitTags),
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
                        ? l10n.searchBranches
                        : l10n.searchTags,
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
        resourceLabel:
            '${widget.project.path} · ${_mode == RepositoryRefPickerMode.branches ? l10n.branchNoun : l10n.gitTags}',
        onSwitchAccount: endSessionFrom(context),
        load: (next) => widget.api.records(
          [
            'projects',
            '${widget.project.id}',
            'repository',
            _mode == RepositoryRefPickerMode.branches ? 'branches' : 'tags',
          ],
          query: {if (_query.isNotEmpty) 'search': _query, 'per_page': '30'},
          next: next,
        ),
        itemBuilder: (context, data) {
          final ref = _mode == RepositoryRefPickerMode.branches
              ? RepositoryRef.fromBranch(data)
              : RepositoryRef.fromTag(data);
          final isSelected =
              ref.name == widget.selected.name &&
              ref.kind == widget.selected.kind;

          return Card(
            child: ListTile(
              leading: Icon(
                ref.kind == RepositoryRefKind.branch
                    ? Icons.alt_route
                    : Icons.label_outline,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : null,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(l10n.defaultLabel, style: TextStyle(fontSize: 11)),
                    ),
                  if (ref.protected)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        l10n.protected,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                ],
              ),
              subtitle: Text(
                l10n.pinnedDiffVersion(RepositoryRef.shortSha(ref.sha)),
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
  static const _codeStyle = TextStyle(
    fontFamily: codeFontFamily,
    fontFamilyFallback: ['Menlo', 'monospace'],
    fontSize: 13,
    height: 1.55,
  );

  String? _text, _lastCommit;
  ApiFailure? _error;
  bool _loading = true, _busy = false, _preview = false, _wrap = true;
  bool _markdown = false;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _chrome = ScrollChromeController();
  final _searchFocus = FocusNode();
  final _searchController = TextEditingController();
  final _syntaxSpans = SyntaxSpanCache();

  int? _selectedLine;
  List<String> _lines = const [];
  List<String> _searchLines = const [];
  List<int> _visibleIndices = const [];
  int _longestLineLength = 0;

  Timer? _searchTimer;
  int _searchEpoch = 0;
  int _fileEpoch = 0;
  String _pendingQuery = '';
  bool _searchPending = false;

  @override
  void initState() {
    super.initState();
    _markdown = _isMarkdownPath(widget.filePath);
    _preview = _markdown && widget.targetLine == null;
    unawaited(_load());
  }

  bool _isMarkdownPath(String path) =>
      RegExp(r'\.(md|markdown)$', caseSensitive: false).hasMatch(path);

  bool _sameFileOwner(RepositoryFilePage other) =>
      other.filePath == widget.filePath &&
      other.project.id == widget.project.id &&
      other.account.key == widget.account.key &&
      identical(other.api, widget.api) &&
      other.resolvedRef.identity == widget.resolvedRef.identity;

  void _clearForOwnerChange() {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchEpoch++;
    _fileEpoch++;
    _searchController.clear();
    _pendingQuery = '';
    _searchPending = false;
    _text = null;
    _lastCommit = null;
    _error = null;
    _selectedLine = null;
    _markdown = _isMarkdownPath(widget.filePath);
    _preview = _markdown && widget.targetLine == null;
    _indexLines('');
    if (_vertical.hasClients) _vertical.jumpTo(0);
    if (_horizontal.hasClients) _horizontal.jumpTo(0);
  }

  @override
  void didUpdateWidget(RepositoryFilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameFileOwner(oldWidget)) {
      _clearForOwnerChange();
      unawaited(_load());
    } else if (widget.targetLine != null &&
        widget.targetLine != oldWidget.targetLine) {
      final target = widget.targetLine!;
      if (target >= 1 && target <= _lines.length) {
        setState(() => _selectedLine = target);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.targetLine == target) _scrollToLine(target);
        });
      }
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchEpoch++;
    _fileEpoch++;
    _vertical.dispose();
    _horizontal.dispose();
    _chrome.dispose();
    _searchFocus.dispose();
    _searchController.dispose();
    _syntaxSpans.clear();
    super.dispose();
  }

  void _indexLines(String text) {
    _syntaxSpans.clear();
    _lines = text.split('\n');
    _searchLines = [for (final line in _lines) line.toLowerCase()];
    _visibleIndices = List<int>.generate(_lines.length, (i) => i);
    _longestLineLength = _lines.fold<int>(0, (n, l) => math.max(n, l.length));
  }

  void _filterVisible(String value) {
    final q = value.trim().toLowerCase();
    if (q.isEmpty) {
      _visibleIndices = List<int>.generate(_lines.length, (i) => i);
    } else {
      _visibleIndices = [
        for (var i = 0; i < _searchLines.length; i++)
          if (_searchLines[i].contains(q)) i,
      ];
    }
  }

  void _onSearchChanged(String value) {
    _pendingQuery = value;
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      _searchTimer?.cancel();
      _searchTimer = null;
      final epoch = ++_searchEpoch;
      final fileEpoch = _fileEpoch;
      _applySearch('', epoch: epoch, fileEpoch: fileEpoch);
      return;
    }

    _searchTimer?.cancel();
    final epoch = ++_searchEpoch;
    final fileEpoch = _fileEpoch;
    setState(() => _searchPending = true);
    _searchTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      if (epoch != _searchEpoch) return;
      if (fileEpoch != _fileEpoch) return;
      _searchTimer = null;
      _applySearch(value, epoch: epoch, fileEpoch: fileEpoch);
    });
  }

  void _onSearchSubmitted(String value) {
    _pendingQuery = value;
    _searchTimer?.cancel();
    _searchTimer = null;
    final epoch = ++_searchEpoch;
    final fileEpoch = _fileEpoch;
    _applySearch(value, epoch: epoch, fileEpoch: fileEpoch);
  }

  void _flushPendingSearch() {
    if (_searchTimer != null && _searchTimer!.isActive) {
      _searchTimer!.cancel();
      _searchTimer = null;
      final epoch = ++_searchEpoch;
      final fileEpoch = _fileEpoch;
      _applySearch(_pendingQuery, epoch: epoch, fileEpoch: fileEpoch);
    }
  }

  void _applySearch(
    String value, {
    required int epoch,
    required int fileEpoch,
  }) {
    if (!mounted || epoch != _searchEpoch || fileEpoch != _fileEpoch) return;
    setState(() {
      _searchPending = false;
      _filterVisible(value);
    });
  }

  Future<void> _load({bool refresh = false}) async {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchEpoch++;
    final fileEpoch = ++_fileEpoch;
    final api = widget.api;
    final accountKey = widget.account.key;
    final projectId = widget.project.id;
    final filePath = widget.filePath;
    final resolved = widget.resolvedRef;
    final query = _searchController.text;
    final targetBeforeLoad = widget.targetLine;
    final revealTargetAfterLoad =
        targetBeforeLoad != null && _selectedLine != targetBeforeLoad;
    _pendingQuery = query;
    setState(() {
      _loading = true;
      _error = null;
      _searchPending = false;
      _filterVisible(query);
    });
    bool current() =>
        mounted &&
        fileEpoch == _fileEpoch &&
        identical(api, widget.api) &&
        accountKey == widget.account.key &&
        projectId == widget.project.id &&
        filePath == widget.filePath &&
        resolved.identity == widget.resolvedRef.identity;
    try {
      Json? meta;
      if (resolved.writable) {
        meta = await api.fileMetadata(projectId, filePath, resolved.sha);
        if (!current()) return;
      }
      final text = await api.textFile(
        projectId,
        resolved.sha,
        filePath,
        refresh: refresh,
      );
      if (current()) {
        _indexLines(text);
        final activeQuery = _searchController.text;
        _searchTimer?.cancel();
        _searchTimer = null;
        _searchEpoch++;
        _pendingQuery = activeQuery;
        _filterVisible(activeQuery);
        final target = widget.targetLine;
        final hasTarget =
            target != null && target >= 1 && target <= _lines.length;
        setState(() {
          _text = text;
          _lastCommit = meta != null
              ? requiredString(meta, 'last_commit_id')
              : null;
          _loading = false;
          _searchPending = false;
          if (hasTarget) {
            _selectedLine = target;
          } else if (_selectedLine != null && _selectedLine! > _lines.length) {
            _selectedLine = null;
          }
        });
        if (hasTarget && revealTargetAfterLoad) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (current()) _scrollToLine(target);
          });
        }
      }
    } catch (e) {
      if (current()) {
        final failure = safeFailure(e);
        setState(() {
          _error = failure;
          _loading = false;
          if (const {
            FailureKind.unauthenticated,
            FailureKind.forbidden,
            FailureKind.invisible,
          }.contains(failure.kind)) {
            _text = null;
            _lastCommit = null;
            _selectedLine = null;
            _indexLines('');
          }
        });
      }
    }
  }

  void _scrollToLine(int line) {
    _flushPendingSearch();
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
    final target =
        (index * estimatedRowHeight - position.viewportDimension * 0.2).clamp(
          0.0,
          span,
        );
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
          content: Text(l10n.copiedLinePermalink(lineNumber)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  bool get _lfs =>
      _text?.startsWith('version https://git-lfs.github.com/spec/v1') ?? false;

  /// GitLab's blob page at the pinned commit, for a file this viewer cannot
  /// show: binary content such as an image, or text over the preview limit.
  Uri? get _webFallback {
    final error = _error, sha = widget.resolvedRef.sha;
    if (error == null ||
        sha.isEmpty ||
        (error.kind != FailureKind.unsupported &&
            error.kind != FailureKind.tooLarge)) {
      return null;
    }
    try {
      return repositoryBlobWebUri(
        instance: widget.account.instance,
        projectPath: widget.project.path,
        sha: sha,
        filePath: widget.filePath,
      );
    } on FormatException {
      return null;
    } on ApiFailure {
      return null;
    }
  }

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
      title: l10n.editFile,
      resource:
          '${widget.project.id}/files/$branch/${widget.filePath}/${widget.resolvedRef.sha}',
      subtitle: '${widget.filePath} · $branch',
      fields: [
        EditField('content', l10n.content, lines: 12, value: _text!),
        EditField(
          'message',
          l10n.commitMessage,
          required: true,
          value: 'Update file from $appName',
        ),
      ],
      save: (values) async {
        final lastCommit = _lastCommit;
        if (lastCommit == null) {
          throw const ApiFailure(FailureKind.conflict);
        }
        await _checkCurrent();
        await widget.api.updateRepositoryFile(
          widget.project.id,
          widget.filePath,
          branch: branch,
          content: values['content']!,
          message: values['message']!.trim(),
          lastCommit: lastCommit,
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
      l10n.deleteFileQuestion,
      l10n.deleteFileCommitWarning(widget.filePath, branch),
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
        message: 'Delete ${widget.filePath} from $appName',
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

    final theme = Theme.of(context);
    final slash = widget.filePath.lastIndexOf('/');
    final appBar = AppBar(
      primary: false,
      toolbarHeight:
          (MediaQuery.textScalerOf(context).scale(18) * 1.3 +
                  MediaQuery.textScalerOf(context).scale(12) * 1.5 +
                  12)
              .clamp(56, double.infinity),
      titleSpacing: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isolated(widget.filePath.split('/').last),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 18),
          ),
          Text(
            [
              if (slash > 0) isolated(widget.filePath.substring(0, slash)),
              isolated(resolvedRef.name),
              if (resolvedRef.sha.isNotEmpty)
                RepositoryRef.shortSha(resolvedRef.sha),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        if (resolvedRef.sha.isNotEmpty)
          ResourceShareButton(
            uri: repositoryBlobWebUri(
              instance: widget.account.instance,
              projectPath: widget.project.path,
              sha: resolvedRef.sha,
              filePath: widget.filePath,
              line: _selectedLine,
            ),
            ownerKey: (
              widget.account.key,
              widget.api,
              widget.project.id,
              resolvedRef.sha,
              widget.filePath,
            ),
            isCurrent: () => mounted && !widget.api.isClosed,
          ),
        if (_markdown)
          IconButton(
            tooltip: _preview ? l10n.showRawText : l10n.markdownPreview,
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
          tooltip: l10n.fileActions,
          onSelected: (action) {
            if (action == 'ai') {
              unawaited(
                openAiChat(
                  context,
                  AiFileOrigin(
                    project: widget.project,
                    path: widget.filePath,
                    sha: resolvedRef.sha,
                  ),
                ),
              );
            }
            if (action == 'refresh') {
              unawaited(_load(refresh: true));
            }
            if (action == 'edit') {
              unawaited(_edit());
            }
            if (action == 'delete') {
              unawaited(_delete());
            }
            if (action == 'wrap') {
              setState(() => _wrap = !_wrap);
            }
            if (action == 'history') {
              unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => FileHistoryPage(
                      account: widget.account,
                      api: widget.api,
                      project: widget.project,
                      path: widget.filePath,
                      ref: resolvedRef.sha.isNotEmpty
                          ? resolvedRef.sha
                          : resolvedRef.name,
                    ),
                  ),
                ),
              );
            }
            if (action == 'blame' && resolvedRef.sha.isNotEmpty) {
              unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BlamePage(
                      account: widget.account,
                      api: widget.api,
                      project: widget.project,
                      path: widget.filePath,
                      sha: resolvedRef.sha,
                    ),
                  ),
                ),
              );
            }
          },
          itemBuilder: (_) => [
            // AI reads a text file at a pinned commit, where the app has AI.
            // A sensitive path would send nothing, so it gets no entry.
            if (AiRunRegistry.maybeOf(context) != null &&
                text != null &&
                !_lfs &&
                isFullCommitSha(resolvedRef.sha) &&
                !isSensitiveRepositoryPath(widget.filePath)) ...[
              PopupMenuItem(value: 'ai', child: Text(l10n.aiExplainFile)),
              const PopupMenuDivider(),
            ],
            PopupMenuItem(
              value: 'refresh',
              enabled: !_loading && !_busy,
              child: Text(l10n.reload),
            ),
            PopupMenuItem(
              value: 'wrap',
              child: Text(_wrap ? l10n.wordWrapOff : l10n.wordWrapOn),
            ),
            PopupMenuItem(value: 'history', child: Text(l10n.fileHistory)),
            if (resolvedRef.sha.isNotEmpty)
              PopupMenuItem(value: 'blame', child: Text(l10n.blame)),
            if (resolvedRef.writable &&
                text != null &&
                !_lfs &&
                widget.project.archived != true &&
                !_busy) ...[
              PopupMenuItem(value: 'edit', child: Text(l10n.editFile)),
              PopupMenuItem(value: 'delete', child: Text(l10n.deleteFile)),
            ],
          ],
        ),
      ],
    );
    return Scaffold(
      // The search field lives in the collapsing header; it stays while focused.
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) => !_searchFocus.hasFocus && _chrome.handle(n),
        child: StatusBarInset(
          child: gestureSafe(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CollapsingChrome(
                  visible: _chrome,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      appBar,
                      if (text != null && !_preview)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocus,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              hintText: l10n.searchCurrentFile,
                              prefixIcon: Icon(Icons.search),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                            ),
                            onChanged: _onSearchChanged,
                            onSubmitted: _onSearchSubmitted,
                          ),
                        ),
                      if (_searchPending)
                        const LinearProgressIndicator(
                          key: ValueKey('repository-file-search-pending'),
                          minHeight: 2,
                        ),
                    ],
                  ),
                ),
                if (_loading || _busy)
                  const LinearProgressIndicator(minHeight: 2),
                if (_error != null)
                  FailureNotice(
                    _error!,
                    onRetry: () => _load(refresh: true),
                    account: widget.account,
                    resourceLabel:
                        '${widget.project.path} · ${widget.filePath}',
                    onSwitchAccount: endSessionFrom(context),
                  ),
                if (_webFallback case final web?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        key: const ValueKey('repository-file-open-web'),
                        onPressed: () {
                          if (mounted && !widget.api.isClosed) {
                            unawaited(openExternal(context, web));
                          }
                        },
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(l10n.openInGitlab),
                      ),
                    ),
                  ),
                if (_lfs)
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(l10n.gitLfsPointer),
                  ),
                Expanded(
                  child: text == null
                      ? const SizedBox()
                      : _preview
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: MarkdownView(
                            text,
                            account: widget.account,
                            base: widget.account.instance.projectWeb(
                              '${widget.project.path}/-/blob/${resolvedRef.sha}/${widget.filePath}',
                            ),
                            api: widget.api,
                            projectId: widget.project.id,
                            projectWeb: widget.account.instance.projectWeb(
                              widget.project.path,
                            ),
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
                                    math.min(
                                      24000.0,
                                      _longestLineLength * fontSize * 0.65 + 80,
                                    ),
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
                                          final lineIndex =
                                              _visibleIndices[index];
                                          final lineNumber = lineIndex + 1;
                                          final isSelected =
                                              _selectedLine == lineNumber;
                                          final lineContent = _lines[lineIndex];

                                          return Container(
                                            key: ValueKey(
                                              'repository-file-line-$lineNumber',
                                            ),
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
                                                  label: l10n.lineNumber(lineNumber),
                                                  hint: l10n.tapCopyLinePermalink,
                                                  excludeSemantics: true,
                                                  onTap: () =>
                                                      _copyLinePermalink(
                                                        lineNumber,
                                                      ),
                                                  child: InkWell(
                                                    onTap: () =>
                                                        _copyLinePermalink(
                                                          lineNumber,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          4,
                                                        ),
                                                    // Code reads line by line: rows stay at text height and the
                                                    // number keeps the 24dp WCAG 2.5.8 minimum in a 48dp-wide column.
                                                    child: ConstrainedBox(
                                                      constraints:
                                                          const BoxConstraints(
                                                            minWidth: 48,
                                                            minHeight: 24,
                                                          ),
                                                      child: Align(
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: Text(
                                                          '$lineNumber',
                                                          textScaler:
                                                              MediaQuery.textScalerOf(
                                                                context,
                                                              ).clamp(
                                                                maxScaleFactor:
                                                                    1.3,
                                                              ),
                                                          style: Theme.of(context)
                                                              .textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                color:
                                                                    isSelected
                                                                    ? Theme.of(
                                                                        context,
                                                                      ).colorScheme.primary
                                                                    : null,
                                                                fontWeight:
                                                                    isSelected
                                                                    ? FontWeight
                                                                          .bold
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
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          vertical: 2,
                                                        ),
                                                    child: Text.rich(
                                                      lineContent.isEmpty
                                                          ? const TextSpan(
                                                              text: ' ',
                                                            )
                                                          : _syntaxSpans.highlight(
                                                              lineIndex,
                                                              lineContent,
                                                              extension: widget
                                                                  .filePath,
                                                              isDark:
                                                                  Theme.of(
                                                                    context,
                                                                  ).brightness ==
                                                                  Brightness
                                                                      .dark,
                                                              baseStyle:
                                                                  _codeStyle,
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
            ),
          ),
        ),
      ),
    );
  }
}
