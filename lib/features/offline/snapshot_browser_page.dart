import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/offline/snapshot_reader.dart';
import '../../core/offline/snapshot_schema.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../core/repository_ref.dart';
import '../../core/repository_reader.dart';
import '../../core/syntax_highlighter.dart';
import '../../l10n/l10n.dart';
import '../../shared/code_text_view.dart';
import '../../shared/markdown_media_svg.dart';
import '../../shared/markdown_view.dart';
import '../../shared/network_boundary.dart';
import '../../shared/workspace_ui.dart';
import '../workspace/repository_page.dart' show RepositoryFilePage, findReadmePath;
import 'offline_repositories.dart';
import 'offline_status.dart';
import 'save_sheet.dart';

const _readmeLimit = 256 * 1024;

/// Every entry of the completed snapshot behind [reader], read once.
///
/// [SnapshotRepositoryReader] lists one folder per call and decrypts the whole
/// tree file each time; the browser needs every entry and its saved state
/// (for the unsaved-file reasons and the name filter). It reads the tree once
/// through the coordinator with the reader's own checks: the same permit
/// fences, a complete record and an identical project, SHA and folder.
Future<List<SnapshotTreeEntry>> loadSnapshotEntries(
  OfflineRepositoryCoordinator coordinator,
  SnapshotRepositoryReader reader,
) async {
  final owner = reader.owner;
  final permit = coordinator.capture(
    DiskBinding(accountKey: owner.accountKey, generation: owner.generation),
    owner.projectId,
  );
  final entries = await coordinator.maintain<List<SnapshotTreeEntry>>(permit, (
    store,
    index,
  ) async {
    permit.check();
    SnapshotRecord? record;
    for (final item in index?.snapshots ?? const <SnapshotRecord>[]) {
      if (item.id == owner.snapshotId) record = item;
    }
    if (record == null ||
        record.status != SnapshotStatus.complete ||
        record.projectId != owner.projectId ||
        record.sha != owner.sha ||
        record.subPath != owner.subPath) {
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    }
    final tree = await store.readTree(record);
    permit.check();
    if (tree == null) {
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    }
    return List<SnapshotTreeEntry>.unmodifiable(tree.entries);
  }, allowReadOnly: true);
  permit.check();
  reader.checkCurrent();
  if (entries == null) {
    throw const SnapshotOperationException(SnapshotFailure.storageError);
  }
  return entries;
}

RepositoryEntryState entryStateOf(SnapshotTreeEntry entry) =>
    switch (entry.state) {
      SnapshotEntryState.saved => RepositoryEntryState.available,
      SnapshotEntryState.pending => RepositoryEntryState.pending,
      SnapshotEntryState.tooLarge => RepositoryEntryState.tooLarge,
      SnapshotEntryState.binary => RepositoryEntryState.binary,
      SnapshotEntryState.missing => RepositoryEntryState.missing,
      SnapshotEntryState.mismatch => RepositoryEntryState.mismatch,
      SnapshotEntryState.symlink => RepositoryEntryState.symlink,
      SnapshotEntryState.submodule => RepositoryEntryState.submodule,
      SnapshotEntryState.unsupportedType =>
        RepositoryEntryState.unsupportedType,
    };

/// The route [openSnapshot] pushes carries this as its arguments, so a
/// navigator observer can tell which saved project is being read (the
/// offline shell goes online into that project's files).
final class SnapshotRouteArguments {
  const SnapshotRouteArguments(this.projectId);
  final int projectId;
}

/// Opens the offline version [record]. Failures go to the shared surface.
Future<void> openSnapshot(
  BuildContext context, {
  required OfflineRepositories repositories,
  required SnapshotRecord record,
  required Account account,
  String folder = '',
}) async {
  final SnapshotRepositoryReader reader;
  try {
    reader = repositories.reader(record);
  } on Object catch (error) {
    showSnapshotFailure(context, error);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(
        arguments: SnapshotRouteArguments(record.projectId),
      ),
      builder: (_) => SnapshotBrowserPage(
        repositories: repositories,
        record: record,
        reader: reader,
        account: account,
        initialFolder: folder,
      ),
    ),
  );
}

/// A project for opening the online pages of a snapshot's project.
Project snapshotProject(SnapshotRecord record) => Project(
  id: record.projectId,
  name: record.projectName,
  path: record.projectPath,
  defaultBranch: record.defaultBranch,
);

/// Whether this view may reach GitLab: an online boundary and a live client.
bool snapshotOnline(BuildContext context, OfflineRepositories repositories) {
  final api = repositories.api;
  return !NetworkBoundary.blocks(context) && api != null && !api.isClosed;
}

/// The offline version of one saved project (§6.5): folders, a local name
/// filter, the README and files, all read from the encrypted snapshot.
class SnapshotBrowserPage extends StatefulWidget {
  const SnapshotBrowserPage({
    super.key,
    required this.repositories,
    required this.record,
    required this.reader,
    required this.account,
    this.initialFolder = '',
  });

  final OfflineRepositories repositories;
  final SnapshotRecord record;
  final SnapshotRepositoryReader reader;
  final Account account;
  final String initialFolder;

  @override
  State<SnapshotBrowserPage> createState() => _SnapshotBrowserPageState();
}

class _SnapshotBrowserPageState extends State<SnapshotBrowserPage> {
  late String _folder = _initialFolder();
  List<SnapshotTreeEntry>? _entries;
  Object? _error;
  bool _attributesHint = false;
  final _filter = TextEditingController();
  String _query = '';
  String? _readme;
  String? _readmePath;
  bool _readmeExpanded = true;
  int _epoch = 0;

  SnapshotRecord get _record => widget.record;
  String get _root => _record.subPath;

  String _initialFolder() {
    final folder = widget.initialFolder;
    final root = widget.record.subPath;
    if (folder.isEmpty) return root;
    if (root.isEmpty || folder == root || folder.startsWith('$root/')) {
      return folder;
    }
    return root;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _epoch++;
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    setState(() {
      _error = null;
      _entries = null;
    });
    try {
      final entries = await loadSnapshotEntries(
        widget.repositories.coordinator,
        widget.reader,
      );
      var hint = false;
      try {
        hint = await widget.reader.hasAttributeOmissions();
      } on Object {
        hint = false;
      }
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _entries = entries;
        _attributesHint = hint;
      });
      unawaited(_loadReadme(entries, epoch));
    } on Object catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = error);
    }
  }

  Future<void> _loadReadme(List<SnapshotTreeEntry> entries, int epoch) async {
    final rows = [
      for (final entry in _children(entries, _root))
        if (entry.state == SnapshotEntryState.saved &&
            entry.kind == SnapshotContentKind.text)
          <String, dynamic>{
            'type': entry.type.name,
            'mode': entry.mode,
            'name': entry.path.split('/').last,
            'path': entry.path,
          },
    ];
    final path = findReadmePath(rows);
    if (path == null) return;
    try {
      final text = await widget.reader.text(path);
      if (utf8.encode(text).length > _readmeLimit) return;
      if (mounted && epoch == _epoch) {
        setState(() {
          _readme = text;
          _readmePath = path;
        });
      }
    } on Object {
      // A README that cannot be read is simply not shown; the row remains.
    }
  }

  List<SnapshotTreeEntry> _children(
    List<SnapshotTreeEntry> entries,
    String folder,
  ) {
    final prefix = folder.isEmpty ? '' : '$folder/';
    final rows = [
      for (final entry in entries)
        if (entry.path.startsWith(prefix) &&
            entry.path.length > prefix.length &&
            !entry.path.substring(prefix.length).contains('/'))
          entry,
    ]..sort(_order);
    return rows;
  }

  static int _order(SnapshotTreeEntry a, SnapshotTreeEntry b) {
    final folderA = a.type == SnapshotEntryType.tree ? 0 : 1;
    final folderB = b.type == SnapshotEntryType.tree ? 0 : 1;
    if (folderA != folderB) return folderA - folderB;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  }

  List<SnapshotTreeEntry> _matches(List<SnapshotTreeEntry> entries) {
    final query = _query.trim().toLowerCase();
    final found = [
      for (final entry in entries)
        if (entry.path.split('/').last.toLowerCase().contains(query)) entry,
    ]..sort(_order);
    return found.take(500).toList();
  }

  void _open(SnapshotTreeEntry entry) {
    if (entry.type == SnapshotEntryType.tree) {
      setState(() {
        _folder = entry.path;
        _filter.clear();
        _query = '';
      });
      return;
    }
    if (entry.state != SnapshotEntryState.saved) {
      unawaited(_notSaved(entry));
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SnapshotFilePage(
            repositories: widget.repositories,
            record: _record,
            reader: widget.reader,
            account: widget.account,
            entry: entry,
            onOpenPath: _openPath,
          ),
        ),
      ),
    );
  }

  /// A Markdown link to a path of the same snapshot.
  void _openPath(String path) {
    final entries = _entries;
    if (!mounted || entries == null) return;
    if (path.isEmpty || path == _root) {
      setState(() => _folder = _root);
      return;
    }
    for (final entry in entries) {
      if (entry.path == path) {
        _open(entry);
        return;
      }
    }
  }

  Future<void> _notSaved(SnapshotTreeEntry entry) async {
    final online = snapshotOnline(context, widget.repositories);
    final api = widget.repositories.api;
    final reason = notSavedReason(entryStateOf(entry));
    if (online &&
        api != null &&
        entry.type == SnapshotEntryType.blob &&
        entry.state != SnapshotEntryState.symlink) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RepositoryFilePage(
            account: widget.account,
            api: api,
            project: snapshotProject(_record),
            ref: RepositoryRef(
              kind: _record.refKind == SnapshotRefKind.tag
                  ? RepositoryRefKind.tag
                  : RepositoryRefKind.branch,
              name: _record.refName,
              sha: _record.sha,
              protected: false,
            ),
            branch: _record.refName,
            sha: _record.sha,
            filePath: entry.path,
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            key: const ValueKey('snapshot-not-saved-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.snapshotNotSavedTitle,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                isolated(entry.path),
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(reason)),
                ],
              ),
              const SizedBox(height: 8),
              Text(l10n.snapshotNotSavedOnlineNote),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _resave() async {
    if (widget.repositories.api == null) return;
    await openOfflineSaveSheet(
      context,
      repositories: widget.repositories,
      account: widget.account,
      project: snapshotProject(_record),
      ref: RepositoryRef(
        kind: _record.refKind == SnapshotRefKind.tag
            ? RepositoryRefKind.tag
            : RepositoryRefKind.branch,
        name: _record.refName,
        sha: '',
        protected: false,
      ),
      folder: _record.subPath,
    );
  }

  bool get _atRoot => _folder == _root;

  void _up() {
    if (_atRoot) return;
    final parts = _folder.split('/')..removeLast();
    final parent = parts.join('/');
    setState(() => _folder = parent.length < _root.length ? _root : parent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final toolbarHeight = math.max(
      kToolbarHeight,
      scaler.scale(18) * 1.3 + scaler.scale(12) * 1.5 + 12,
    );
    return PopScope(
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: toolbarHeight,
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isolated(_record.projectName),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 18),
              ),
              Text(
                isolated(_record.projectPath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        body: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final error = _error;
    final entries = _entries;
    final online = snapshotOnline(context, widget.repositories);
    if (error != null) {
      final failure = snapshotFailureOf(error);
      final damaged = failure == SnapshotFailure.storageError;
      return ListView(
        children: [
          _header(context),
          OfflineNotice(
            key: const ValueKey('snapshot-browser-error'),
            icon: damaged ? Icons.broken_image_outlined : Icons.error_outline,
            error: true,
            title: damaged ? l10n.snapshotDamaged : snapshotFailureText(failure),
            actions: [
              TextButton.icon(
                onPressed: () => unawaited(_load()),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.refreshAction),
              ),
              if (damaged && online)
                TextButton.icon(
                  key: const ValueKey('snapshot-resave'),
                  onPressed: () => unawaited(_resave()),
                  icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                  label: Text(l10n.snapshotResave),
                ),
            ],
          ),
        ],
      );
    }
    if (entries == null) {
      return Column(
        children: [
          _header(context),
          const LinearProgressIndicator(minHeight: 2),
        ],
      );
    }
    final filtering = _query.trim().isNotEmpty;
    final rows = filtering ? _matches(entries) : _children(entries, _folder);
    return ListView(
      key: const ValueKey('snapshot-browser-list'),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _header(context),
        if (_attributesHint)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              key: const ValueKey('snapshot-attributes-hint'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.snapshotAttributesHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            key: const ValueKey('snapshot-filter'),
            controller: _filter,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l10n.snapshotFilterHint,
              prefixIcon: const Icon(Icons.filter_list),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (!filtering && !_atRoot) _breadcrumbs(context),
        if (rows.isEmpty)
          EmptyState(
            filtering ? l10n.snapshotFilterNoMatch : l10n.directoryEmpty,
            icon: filtering ? Icons.search_off : Icons.folder_open_outlined,
          )
        else
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 48),
                  _row(context, rows[i], showPath: filtering),
                ],
              ],
            ),
          ),
        if (!filtering && _atRoot && _readme != null) _readmeCard(context),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final saved = _record.savedAt ?? _record.createdAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        key: const ValueKey('snapshot-browser-header'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.offline_pin_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.snapshotBrowserHeader(
                isolated(_record.refName),
                RepositoryRef.shortSha(_record.sha),
                snapshotDate(saved),
              ),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _breadcrumbs(BuildContext context) {
    final theme = Theme.of(context);
    final rootSegments = _root.isEmpty ? 0 : _root.split('/').length;
    final segments = _folder.split('/');
    final style = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.primary,
    );
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 8),
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
              onPressed: () => setState(() => _folder = _root),
              child: Text(
                _root.isEmpty ? l10n.rootDirectory : isolated(_root),
              ),
            ),
            for (var i = rootSegments; i < segments.length; i++) ...[
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
    );
  }

  Widget _row(
    BuildContext context,
    SnapshotTreeEntry entry, {
    required bool showPath,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = entry.path.split('/').last;
    final folder = entry.type == SnapshotEntryType.tree;
    final saved = folder || entry.state == SnapshotEntryState.saved;
    final reason = saved ? '' : notSavedReason(entryStateOf(entry));
    final muted = scheme.onSurfaceVariant;
    final nameStyle = theme.textTheme.bodyLarge?.copyWith(
      fontSize: 15,
      height: 1.3,
      color: saved ? null : muted.withValues(alpha: 0.75),
    );
    return Semantics(
      button: true,
      label: [isolated(name), if (reason.isNotEmpty) reason].join(' · '),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('snapshot-row-${entry.path}'),
        onTap: () => _open(entry),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(
                  folder
                      ? Icons.folder
                      : entry.type == SnapshotEntryType.commit
                      ? Icons.link
                      : fileIconFor(name),
                  size: 20,
                  color: folder
                      ? scheme.primary
                      : saved
                      ? muted
                      : muted.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isolated(name),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: nameStyle,
                      ),
                      if (showPath)
                        Text(
                          isolated(entry.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      if (reason.isNotEmpty)
                        Text(
                          reason,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (folder)
                  Icon(Icons.chevron_right, size: 18, color: muted)
                else if (!saved)
                  Icon(Icons.cloud_off_outlined, size: 16, color: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _readmeCard(BuildContext context) {
    final theme = Theme.of(context);
    final path = _readmePath!;
    return Card(
      key: const ValueKey('snapshot-readme'),
      margin: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () => setState(() => _readmeExpanded = !_readmeExpanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.menu_book_outlined, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isolated(path.split('/').last),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Icon(
                      _readmeExpanded ? Icons.expand_less : Icons.expand_more,
                      semanticLabel: _readmeExpanded
                          ? l10n.collapseReadme
                          : l10n.expandReadme,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_readmeExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SnapshotMarkdown(
                text: _readme!,
                path: path,
                record: _record,
                reader: widget.reader,
                account: widget.account,
                repositories: widget.repositories,
                onOpenPath: _openPath,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Markdown of a snapshot file, bound to the snapshot's reader and policy.
class SnapshotMarkdown extends StatelessWidget {
  const SnapshotMarkdown({
    super.key,
    required this.text,
    required this.path,
    required this.record,
    required this.reader,
    required this.account,
    required this.repositories,
    this.onOpenPath,
  });

  final String text;
  final String path;
  final SnapshotRecord record;
  final SnapshotRepositoryReader reader;
  final Account account;
  final OfflineRepositories repositories;
  final void Function(String path)? onOpenPath;

  @override
  Widget build(BuildContext context) {
    final online = snapshotOnline(context, repositories);
    final GitLabApi? api = online ? repositories.api : null;
    return MarkdownView(
      text,
      account: account,
      // Pinned to the SHA, so relative images resolve to this snapshot.
      base: account.instance.projectWeb(
        '${record.projectPath}/-/blob/${record.sha}/$path',
      ),
      api: api,
      projectId: record.projectId,
      projectWeb: account.instance.projectWeb(record.projectPath),
      projectPath: record.projectPath,
      snapshot: SnapshotMarkdownContext(
        reader: reader,
        projectPath: record.projectPath,
        refName: record.refName,
        openPath: onOpenPath,
      ),
    );
  }
}

/// One saved file of a snapshot: code with line numbers, in-file search and
/// wrap, a Markdown preview, or an image. Nothing here edits, shares, asks
/// the AI or reads GitLab (§6.1: the snapshot reader's capabilities are all
/// false).
class SnapshotFilePage extends StatefulWidget {
  const SnapshotFilePage({
    super.key,
    required this.repositories,
    required this.record,
    required this.reader,
    required this.account,
    required this.entry,
    this.onOpenPath,
  });

  final OfflineRepositories repositories;
  final SnapshotRecord record;
  final SnapshotRepositoryReader reader;
  final Account account;
  final SnapshotTreeEntry entry;
  final void Function(String path)? onOpenPath;

  @override
  State<SnapshotFilePage> createState() => _SnapshotFilePageState();
}

class _SnapshotFilePageState extends State<SnapshotFilePage> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _search = TextEditingController();
  final _syntaxSpans = SyntaxSpanCache();
  CodeTextIndex _index = CodeTextIndex.empty;
  List<int> _visible = const [];
  String? _text;
  Uint8List? _image;
  bool _svg = false;
  Object? _error;
  bool _loading = true, _wrap = true;
  late final bool _markdown = RegExp(
    r'\.(md|markdown)$',
    caseSensitive: false,
  ).hasMatch(widget.entry.path);
  late bool _preview = _markdown;
  int? _selectedLine;
  Timer? _searchTimer;

  String get _path => widget.entry.path;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _vertical.dispose();
    _horizontal.dispose();
    _search.dispose();
    _syntaxSpans.clear();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.entry.kind == SnapshotContentKind.image) {
        final bytes = await widget.reader.bytes(_path);
        final svg = await sanitizeMarkdownSvg(bytes);
        widget.reader.checkCurrent();
        if (!mounted) return;
        setState(() {
          _image = svg ?? bytes;
          _svg = svg != null;
          _loading = false;
        });
        return;
      }
      final text = await widget.reader.text(_path);
      if (!mounted) return;
      setState(() {
        _text = text;
        _index = CodeTextIndex(text);
        _visible = _index.filter(_search.text);
        _loading = false;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  void _onSearch(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _visible = _index.filter(value));
    });
  }

  /// Copies the GitLab permalink of the line; the clipboard only, no share.
  Future<void> _copyLine(int line) async {
    setState(() => _selectedLine = line);
    final uri = repositoryBlobWebUri(
      instance: widget.account.instance,
      projectPath: widget.record.projectPath,
      sha: widget.record.sha,
      filePath: _path,
      line: line,
    );
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.copiedLinePermalink(line)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  bool get _lfs =>
      widget.entry.kind == SnapshotContentKind.lfsPointer ||
      (_text?.startsWith('version https://git-lfs.github.com/spec/v1') ?? false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slash = _path.lastIndexOf('/');
    final scaler = MediaQuery.textScalerOf(context);
    final text = _text;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: (scaler.scale(18) * 1.3 + scaler.scale(12) * 1.5 + 12)
            .clamp(56, double.infinity),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isolated(_path.split('/').last),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 18),
            ),
            Text(
              [
                if (slash > 0) isolated(_path.substring(0, slash)),
                isolated(widget.record.refName),
                RepositoryRef.shortSha(widget.record.sha),
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
          if (_markdown && text != null)
            IconButton(
              tooltip: _preview ? l10n.showRawText : l10n.markdownPreview,
              onPressed: () => setState(() => _preview = !_preview),
              icon: Icon(_preview ? Icons.code : Icons.preview_outlined),
            ),
          if (text != null && !_preview)
            PopupMenuButton<String>(
              key: const ValueKey('snapshot-file-actions'),
              tooltip: l10n.fileActions,
              onSelected: (_) => setState(() => _wrap = !_wrap),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'wrap',
                  child: Text(_wrap ? l10n.wordWrapOff : l10n.wordWrapOn),
                ),
              ],
            ),
        ],
      ),
      body: gestureSafe(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error case final error?)
              OfflineNotice(
                key: const ValueKey('snapshot-file-error'),
                icon: Icons.broken_image_outlined,
                error: true,
                title: snapshotFailureOf(error) == SnapshotFailure.storageError
                    ? l10n.snapshotDamaged
                    : snapshotFailureText(snapshotFailureOf(error)),
                actions: [
                  TextButton.icon(
                    onPressed: () => unawaited(_load()),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(l10n.refreshAction),
                  ),
                ],
              ),
            if (_lfs)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.gitLfsPointer),
              ),
            if (text != null && !_preview)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const ValueKey('snapshot-file-search'),
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: l10n.searchCurrentFile,
                    prefixIcon: const Icon(Icons.search),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  onChanged: _onSearch,
                ),
              ),
            Expanded(child: _content(context, text)),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, String? text) {
    final image = _image;
    if (image != null) {
      return InteractiveViewer(
        child: Center(
          child: _svg
              ? SvgPicture.memory(image, fit: BoxFit.contain)
              : Image.memory(
                  image,
                  fit: BoxFit.contain,
                  semanticLabel: _path.split('/').last,
                  errorBuilder: (_, _, _) => Text(l10n.snapshotDamaged),
                ),
        ),
      );
    }
    if (text == null) return const SizedBox();
    if (_preview) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: SnapshotMarkdown(
          text: text,
          path: _path,
          record: widget.record,
          reader: widget.reader,
          account: widget.account,
          repositories: widget.repositories,
          onOpenPath: widget.onOpenPath == null
              ? null
              : (path) {
                  Navigator.of(context).pop();
                  widget.onOpenPath!(path);
                },
        ),
      );
    }
    return CodeTextView(
      key: const ValueKey('snapshot-code'),
      index: _index,
      visibleIndices: _visible,
      filePath: _path,
      syntaxSpans: _syntaxSpans,
      wrap: _wrap,
      vertical: _vertical,
      horizontal: _horizontal,
      selectedLine: _selectedLine,
      onLineTap: (line) => unawaited(_copyLine(line)),
      lineKeyPrefix: 'snapshot-file-line-',
    );
  }
}
