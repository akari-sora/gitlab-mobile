import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/snippet_models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/resource_share.dart';
import '../../shared/skeleton.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import 'records_feed.dart';

import '../../l10n/l10n.dart';
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
      widget.project.id == project.id &&
      widget.project.path == project.path;

  @override
  void didUpdateWidget(covariant SnippetsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.project.path != widget.project.path ||
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
    var writePending = false;
    final saved = await openEditor(
      context,
      account: account,
      api: api,
      projectId: project.id,
      projectPath: project.path,
      title: l10n.newSnippet,
      subtitle: project.path,
      resource: '${project.id}/snippets/new',
      onRoute: _ownRoute,
      fields: [
        EditField('title', l10n.title, required: true),
        EditField('description', l10n.descriptionLabel, lines: 4, markdown: true),
        EditField.choice(
          'visibility',
          l10n.visibility,
          choices: _visibilityChoices(account),
          value: 'private',
          required: true,
        ),
        EditField('file_name', l10n.fileName, required: true),
        EditField('content', l10n.content, lines: 16, required: true),
      ],
      save: (values) async {
        if (writePending) {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        if (!_currentOwner(generation, account, api, project)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        writePending = true;
        late final Map<String, dynamic> created;
        try {
          created = await api.createSnippet(
            project.id,
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
        } on ApiFailure catch (failure) {
          if (failure.kind != FailureKind.writeUncertain) writePending = false;
          rethrow;
        }
        if (!_currentOwner(generation, account, api, project)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        try {
          final id = requiredInt(created, 'id');
          final readbackJson = await api.record([...path, '$id']);
          final readback = ProjectSnippet.fromJson(readbackJson)
            ..requireProject(project.id);
          if (!readback.canUseLegacyRaw ||
              readback.title != (values['title'] ?? '').trim() ||
              readback.description != (values['description'] ?? '') ||
              readback.visibility != (values['visibility'] ?? '').trim() ||
              readback.fileName != values['file_name']!.trim()) {
            throw const ApiFailure(FailureKind.writeUncertain);
          }
          final content = await api.snippetText(project.id, id);
          if (content != values['content']) {
            throw const ApiFailure(FailureKind.writeUncertain);
          }
          createdId = id;
        } catch (error) {
          if (error is ApiFailure && error.kind == FailureKind.cancelled) {
            rethrow;
          }
          throw const ApiFailure(FailureKind.writeUncertain);
        }
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
      label: Text(l10n.addAction),
    ),
    body: RecordsFeed(
      key: _feed,
      identity:
          '${widget.account.key}/${widget.project.id}/${widget.project.path}/snippets',
      storageId: 'snippets/${widget.account.key}/${widget.project.id}',
      account: widget.account,
      resourceLabel: '${widget.project.path} · Snippets',
      onSwitchAccount: endSessionFrom(context),
      empty: l10n.projectNoSnippets,
      emptyDetail: l10n.privateSnippetHint,
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
                ? l10n.snippetMultiOrUnnamed(snippet.authorName)
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
  SnippetGraphSnapshot? _snapshot;
  SnippetBlob? _blob;
  String? _selectedPath;
  ApiFailure? _error;
  ApiFailure? _blobError;
  bool _loading = true;
  bool _firstLoadDone = false;
  bool _blobLoading = false;
  bool _busy = false;
  bool _markdownPreview = false;
  int _generation = 0;
  int _blobRequest = 0;
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
      widget.project.path == project.path &&
      widget.snippetId == snippetId;

  @override
  void didUpdateWidget(covariant _SnippetDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.project.path != widget.project.path ||
        oldWidget.snippetId != widget.snippetId ||
        !identical(oldWidget.api, widget.api)) {
      _dismissRoutes();
      _busy = false;
      _firstLoadDone = false;
      _snippet = null;
      _content = null;
      _snapshot = null;
      _blob = null;
      _selectedPath = null;
      _error = null;
      _blobError = null;
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
            ? l10n.multiFileSnippetUnsafe
            : l10n.snippetFileListUnknown,
        detail: snippet.hasExplicitFiles
            ? l10n.snippetRefMissing
            : l10n.snippetFileNameInsufficient,
      );
    }
    return (snippet, await api.snippetText(projectId, snippetId));
  }

  Future<ProjectSnippet> _readSnippet(
    GitLabApi api,
    Project project,
    int snippetId,
  ) async {
    final json = await api.record([
      'projects',
      '${project.id}',
      'snippets',
      '$snippetId',
    ]);
    final snippet = ProjectSnippet.fromJson(json)..requireProject(project.id);
    if (snippet.id != snippetId) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    return snippet;
  }

  bool _samePaths(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    final expected = left.toSet();
    return expected.length == left.length && expected.containsAll(right);
  }

  bool _sameSnapshot(SnippetGraphSnapshot left, SnippetGraphSnapshot right) =>
      left.projectId == right.projectId &&
      left.projectPath == right.projectPath &&
      left.snippetId == right.snippetId &&
      left.graphId == right.graphId &&
      left.restUpdatedAt == right.restUpdatedAt &&
      left.graphUpdatedAt == right.graphUpdatedAt &&
      _samePaths(left.filePaths, right.filePaths);

  Future<SnippetGraphSnapshot> _freshSnapshotFor(
    GitLabApi api,
    Project project,
    SnippetGraphSnapshot expected,
  ) async {
    final fresh = await api.projectSnippetSnapshot(project, expected.snippet);
    if (!_sameSnapshot(fresh, expected)) {
      throw const ApiFailure(FailureKind.conflict);
    }
    return fresh;
  }

  Future<void> _load({String? preferredPath}) async {
    final generation = ++_generation;
    _blobRequest++;
    setState(() {
      _loading = true;
      _error = null;
      _blobError = null;
      _blobLoading = false;
    });
    try {
      final snippet = await _readSnippet(
        widget.api,
        widget.project,
        widget.snippetId,
      );
      if (snippet.canUseLegacyRaw) {
        final content = await widget.api.snippetText(
          widget.project.id,
          widget.snippetId,
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          _snippet = snippet;
          _content = content;
          _snapshot = null;
          _blob = null;
          _selectedPath = null;
          _loading = false;
          _firstLoadDone = true;
        });
        return;
      }
      if (!snippet.hasExplicitFiles || snippet.filePaths.isEmpty) {
        throw ApiFailure(
          FailureKind.unsupported,
          title: l10n.snippetFileListUnknown,
          detail:
              l10n.snippetFileNameInsufficient,
        );
      }
      late final SnippetGraphSnapshot snapshot;
      try {
        snapshot = await widget.api.projectSnippetSnapshot(
          widget.project,
          snippet,
        );
      } on ApiFailure catch (failure) {
        if (failure.kind == FailureKind.unsupported ||
            failure.kind == FailureKind.invisible) {
          throw ApiFailure(
            FailureKind.unsupported,
            title: l10n.multiFileSnippetUnsafe,
            detail: l10n.snippetMultiFileApiMissing,
          );
        }
        rethrow;
      }
      if (!mounted || generation != _generation) return;
      final selected = snapshot.filePaths.contains(preferredPath)
          ? preferredPath!
          : snapshot.filePaths.first;
      setState(() {
        _snippet = snapshot.snippet;
        _content = null;
        _snapshot = snapshot;
        _loading = false;
        _firstLoadDone = true;
      });
      unawaited(_selectFile(selected));
    } catch (error) {
      if (!mounted || generation != _generation) return;
      final failure = safeFailure(error);
      setState(() {
        _error = failure;
        _loading = false;
      });
    } finally {
      if (mounted && generation == _generation && _loading) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _selectFile(String path) async {
    final snapshot = _snapshot;
    if (snapshot == null || !snapshot.filePaths.contains(path)) return;
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final snippetId = widget.snippetId;
    final generation = _generation;
    final request = ++_blobRequest;
    final samePath = _selectedPath == path;
    setState(() {
      if (!samePath) {
        _selectedPath = path;
        _blob = null;
        _markdownPreview = false;
      }
      _blobError = null;
      _blobLoading = true;
    });
    try {
      final blob = await api.snippetBlob(project, snapshot, path: path);
      if (!_currentOwner(generation, account, api, project, snippetId) ||
          request != _blobRequest ||
          _selectedPath != path ||
          !identical(_snapshot, snapshot)) {
        return;
      }
      setState(() {
        _blob = blob;
        _blobLoading = false;
      });
    } catch (error) {
      if (!_currentOwner(generation, account, api, project, snippetId) ||
          request != _blobRequest ||
          _selectedPath != path) {
        return;
      }
      setState(() {
        _blobError = safeFailure(error);
        _blobLoading = false;
      });
    }
  }

  Future<void> _edit() async {
    if (_snapshot != null) {
      await _editMetadata();
      return;
    }
    final snippet = _snippet;
    final content = _content;
    if (snippet == null || content == null || _busy) return;
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final snippetId = widget.snippetId;
    final generation = _generation;
    var writePending = false;
    final saved = await openEditor(
      context,
      account: account,
      api: api,
      projectId: project.id,
      projectPath: project.path,
      title: l10n.editSnippet,
      subtitle: project.path,
      resource: '${project.id}/snippets/${snippet.id}',
      baseRevision: snippet.updatedAt,
      onRoute: _ownRoute,
      fields: [
        EditField('title', l10n.title, value: snippet.title, required: true),
        EditField(
          'description',
          l10n.descriptionLabel,
          value: snippet.description,
          lines: 4,
          markdown: true,
        ),
        EditField.choice(
          'visibility',
          l10n.visibility,
          choices: _visibilityChoices(account),
          value: snippet.visibility,
          required: true,
        ),
        EditField('file_name', l10n.fileName, value: snippet.fileName, required: true),
        EditField('content', l10n.content, value: content, lines: 16, required: true),
      ],
      save: (values) async {
        if (writePending) {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        final fresh = await _freshSingleFor(api, project.id, snippetId);
        if (fresh.$1.updatedAt != snippet.updatedAt || fresh.$2 != content) {
          throw const ApiFailure(FailureKind.conflict);
        }
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        writePending = true;
        try {
          await api.updateSnippet(
            project.id,
            snippetId,
            before: fresh.$1,
            title: values['title'] ?? '',
            description: values['description'] ?? '',
            visibility: (values['visibility'] ?? '').trim(),
            fileName: values['file_name'] ?? '',
            content: values['content'] ?? '',
            previousContent: fresh.$2,
          );
        } on ApiFailure catch (failure) {
          if (failure.kind != FailureKind.writeUncertain) writePending = false;
          rethrow;
        }
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        try {
          final readback = await _freshSingleFor(api, project.id, snippetId);
          if (readback.$1.title != (values['title'] ?? '').trim() ||
              readback.$1.description != (values['description'] ?? '') ||
              readback.$1.visibility != (values['visibility'] ?? '').trim() ||
              readback.$1.fileName != (values['file_name'] ?? '').trim() ||
              readback.$2 != (values['content'] ?? '')) {
            throw const ApiFailure(FailureKind.writeUncertain);
          }
        } catch (error) {
          if (error is ApiFailure && error.kind == FailureKind.cancelled) {
            rethrow;
          }
          throw const ApiFailure(FailureKind.writeUncertain);
        }
      },
    );
    if (saved && _currentOwner(generation, account, api, project, snippetId)) {
      await _load();
    }
  }

  Future<void> _editMetadata() async {
    final snapshot = _snapshot;
    if (snapshot == null || _busy) return;
    final snippet = snapshot.snippet;
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final snippetId = widget.snippetId;
    final generation = _generation;
    final selected = _selectedPath;
    var writePending = false;
    final saved = await openEditor(
      context,
      account: account,
      api: api,
      projectId: project.id,
      projectPath: project.path,
      title: l10n.editSnippetInfo,
      subtitle: project.path,
      resource: '${project.id}/snippets/${snippet.id}/metadata',
      baseRevision:
          '${snapshot.restUpdatedAt}/${snapshot.graphUpdatedAt.toIso8601String()}',
      onRoute: _ownRoute,
      fields: [
        EditField('title', l10n.title, value: snippet.title, required: true),
        EditField(
          'description',
          l10n.descriptionLabel,
          value: snippet.description,
          lines: 4,
          markdown: true,
        ),
        EditField.choice(
          'visibility',
          l10n.visibility,
          choices: _visibilityChoices(account),
          value: snippet.visibility,
          required: true,
        ),
      ],
      save: (values) async {
        if (writePending) {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        final fresh = await _freshSnapshotFor(api, project, snapshot);
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        writePending = true;
        try {
          await api.updateSnippetMetadata(
            project.id,
            snippetId,
            title: values['title'] ?? '',
            description: values['description'] ?? '',
            visibility: (values['visibility'] ?? '').trim(),
            currentPaths: fresh.filePaths,
          );
        } on ApiFailure catch (failure) {
          if (failure.kind != FailureKind.writeUncertain) writePending = false;
          rethrow;
        }
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        try {
          final readbackSnippet = await _readSnippet(api, project, snippetId);
          final readback = await api.projectSnippetSnapshot(
            project,
            readbackSnippet,
          );
          if (readback.snippet.title != (values['title'] ?? '').trim() ||
              readback.snippet.description != (values['description'] ?? '') ||
              readback.snippet.visibility !=
                  (values['visibility'] ?? '').trim() ||
              !_samePaths(readback.filePaths, snapshot.filePaths)) {
            throw const ApiFailure(FailureKind.writeUncertain);
          }
        } catch (error) {
          if (error is ApiFailure && error.kind == FailureKind.cancelled) {
            rethrow;
          }
          throw const ApiFailure(FailureKind.writeUncertain);
        }
      },
    );
    if (saved && _currentOwner(generation, account, api, project, snippetId)) {
      await _load(preferredPath: selected);
    }
  }

  Future<void> _editFile({
    required String title,
    required String resourceSuffix,
    required List<EditField> fields,
    required List<SnippetFileAction> Function(
      Map<String, String> values,
      SnippetGraphSnapshot fresh,
    )
    actions,
    required String? Function(Map<String, String> values) resultingPath,
    String? Function()? expectedContent,
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null || _busy) return;
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final snippetId = widget.snippetId;
    final generation = _generation;
    var writePending = false;
    String? savedPath;
    final saved = await openEditor(
      context,
      account: account,
      api: api,
      projectId: project.id,
      projectPath: project.path,
      title: title,
      subtitle: project.path,
      resource: '${project.id}/snippets/$snippetId/$resourceSuffix',
      baseRevision:
          '${snapshot.restUpdatedAt}/${snapshot.graphUpdatedAt.toIso8601String()}',
      onRoute: _ownRoute,
      fields: fields,
      save: (values) async {
        if (writePending) {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        final fresh = await _freshSnapshotFor(api, project, snapshot);
        final requestedActions = actions(
          values,
          fresh,
        ).map(_canonicalFileAction).toList(growable: false);
        final nextPath = resultingPath(values);
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        writePending = true;
        try {
          await api.updateSnippetFiles(
            project.id,
            snippetId,
            title: fresh.snippet.title,
            description: fresh.snippet.description,
            visibility: fresh.snippet.visibility,
            currentPaths: fresh.filePaths,
            actions: requestedActions,
          );
        } on ApiFailure catch (failure) {
          if (failure.kind != FailureKind.writeUncertain) writePending = false;
          rethrow;
        }
        if (!_currentOwner(generation, account, api, project, snippetId)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        try {
          final readbackSnippet = await _readSnippet(api, project, snippetId);
          final readback = await api.projectSnippetSnapshot(
            project,
            readbackSnippet,
          );
          final expectedPaths = snapshot.filePaths.toSet();
          for (final action in requestedActions) {
            switch (action.type) {
              case SnippetFileActionType.create:
                expectedPaths.add(action.path);
              case SnippetFileActionType.update:
                break;
              case SnippetFileActionType.delete:
                expectedPaths.remove(action.path);
              case SnippetFileActionType.move:
                expectedPaths
                  ..remove(action.previousPath)
                  ..add(action.path);
            }
          }
          if (!_samePaths(readback.filePaths, expectedPaths.toList())) {
            throw const ApiFailure(FailureKind.writeUncertain);
          }
          if (nextPath != null) {
            final blob = await api.snippetBlob(
              project,
              readback,
              path: nextPath,
            );
            if (blob.availability != SnippetBlobAvailability.text ||
                (expectedContent != null &&
                    blob.content != expectedContent())) {
              throw const ApiFailure(FailureKind.writeUncertain);
            }
          }
          savedPath = nextPath;
        } catch (error) {
          if (error is ApiFailure && error.kind == FailureKind.cancelled) {
            rethrow;
          }
          throw const ApiFailure(FailureKind.writeUncertain);
        }
      },
    );
    if (saved && _currentOwner(generation, account, api, project, snippetId)) {
      await _load(preferredPath: savedPath ?? _selectedPath);
    }
  }

  SnippetFileAction _canonicalFileAction(SnippetFileAction action) {
    final path = validatedSnippetPath(action.path);
    return switch (action.type) {
      SnippetFileActionType.create => SnippetFileAction.create(
        path: path,
        content: action.content!,
      ),
      SnippetFileActionType.update => SnippetFileAction.update(
        path: path,
        content: action.content!,
      ),
      SnippetFileActionType.delete => SnippetFileAction.delete(path: path),
      SnippetFileActionType.move => SnippetFileAction.move(
        previousPath: validatedSnippetPath(action.previousPath!),
        path: path,
      ),
    };
  }

  Future<void> _addFile() async {
    var submittedContent = '';
    await _editFile(
      title: l10n.addFile,
      resourceSuffix: 'files/new',
      fields: [
        EditField('file_path', l10n.filePath, required: true),
        EditField('content', l10n.content, lines: 16, required: true),
      ],
      actions: (values, _) {
        submittedContent = values['content'] ?? '';
        return [
          SnippetFileAction.create(
            path: values['file_path'] ?? '',
            content: submittedContent,
          ),
        ];
      },
      resultingPath: (values) =>
          validatedSnippetPath(values['file_path'] ?? ''),
      expectedContent: () => submittedContent,
    );
  }

  Future<void> _updateFile() async {
    final blob = _blob;
    final path = _selectedPath;
    if (blob?.availability != SnippetBlobAvailability.text || path == null) {
      return;
    }
    String submittedContent = blob!.content!;
    await _editFile(
      title: l10n.editFile,
      resourceSuffix: 'files/$path/content',
      fields: [
        EditField(
          'content',
          l10n.content,
          value: blob.content!,
          lines: 16,
          required: true,
        ),
      ],
      actions: (values, _) {
        submittedContent = values['content'] ?? '';
        return [
          SnippetFileAction.update(path: path, content: submittedContent),
        ];
      },
      resultingPath: (_) => path,
      expectedContent: () => submittedContent,
    );
  }

  Future<void> _renameFile() async {
    final blob = _blob;
    final path = _selectedPath;
    if (blob?.availability != SnippetBlobAvailability.text || path == null) {
      return;
    }
    await _editFile(
      title: l10n.renameFile,
      resourceSuffix: 'files/$path/move',
      fields: [EditField('file_path', l10n.newPath, value: path, required: true)],
      actions: (values, _) => [
        SnippetFileAction.move(
          previousPath: path,
          path: values['file_path'] ?? '',
        ),
      ],
      resultingPath: (values) =>
          validatedSnippetPath(values['file_path'] ?? ''),
      expectedContent: () => blob!.content,
    );
  }

  Future<void> _deleteFile() async {
    final snapshot = _snapshot;
    final selected = _selectedPath;
    if (snapshot == null || selected == null || _busy) return;
    if (snapshot.filePaths.length <= 1) {
      showFailure(
        context,
        ApiFailure(
          FailureKind.validation,
          title: l10n.keepOneFile,
          detail: l10n.deleteWholeSnippetHint,
        ),
      );
      return;
    }
    final confirmed = await confirmAction(
      context,
      l10n.deleteSelectedFileQuestion(selected),
      l10n.deleteOnlyThisFile,
      requiredText: selected,
      onRoute: _ownRoute,
    );
    if (!confirmed) return;
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final snippetId = widget.snippetId;
    final generation = _generation;
    setState(() => _busy = true);
    var acknowledged = false;
    try {
      final fresh = await _freshSnapshotFor(api, project, snapshot);
      if (!_currentOwner(generation, account, api, project, snippetId)) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      await api.deleteSnippetFile(
        project.id,
        snippetId,
        title: fresh.snippet.title,
        description: fresh.snippet.description,
        visibility: fresh.snippet.visibility,
        currentPaths: fresh.filePaths,
        path: selected,
      );
      acknowledged = true;
      if (!_currentOwner(generation, account, api, project, snippetId)) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      final readbackSnippet = await _readSnippet(api, project, snippetId);
      final readback = await api.projectSnippetSnapshot(
        project,
        readbackSnippet,
      );
      final expectedPaths = snapshot.filePaths
          .where((path) => path != selected)
          .toList();
      if (!_samePaths(readback.filePaths, expectedPaths)) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      if (_currentOwner(generation, account, api, project, snippetId)) {
        setState(() => _busy = false);
        await _load(preferredPath: expectedPaths.first);
      }
    } catch (error) {
      if (!mounted) return;
      final shown =
          acknowledged &&
              !(error is ApiFailure &&
                  (error.kind == FailureKind.writeUncertain ||
                      error.kind == FailureKind.cancelled))
          ? const ApiFailure(FailureKind.writeUncertain)
          : error;
      if (_currentOwner(generation, account, api, project, snippetId)) {
        showFailure(context, shown);
      }
    } finally {
      if (_currentOwner(generation, account, api, project, snippetId)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete() async {
    final snippet = _snippet;
    final content = _content;
    final snapshot = _snapshot;
    if (snippet == null || (content == null && snapshot == null) || _busy) {
      return;
    }
    final account = widget.account;
    final api = widget.api;
    final project = widget.project;
    final snippetId = widget.snippetId;
    final generation = _generation;
    final path = ['projects', '${project.id}', 'snippets', '$snippetId'];
    final confirmed = await confirmAction(
      context,
      l10n.deleteSnippetTitleQuestion(snippet.title),
      l10n.deleteSnippetPermanent,
      requiredText: '#${snippet.id}',
      onRoute: _ownRoute,
    );
    if (!confirmed ||
        !_currentOwner(generation, account, api, project, snippetId)) {
      return;
    }
    setState(() => _busy = true);
    try {
      if (snapshot != null) {
        await _freshSnapshotFor(api, project, snapshot);
      } else {
        final fresh = await _freshSingleFor(api, project.id, snippetId);
        if (fresh.$1.updatedAt != snippet.updatedAt || fresh.$2 != content) {
          throw const ApiFailure(FailureKind.conflict);
        }
      }
      if (!_currentOwner(generation, account, api, project, snippetId)) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      await api.deleteSnippet(project.id, snippetId);
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

  Future<void> _showMore() async {
    if (_snippet == null || _busy) return;
    final route = DialogRoute<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.moreOptions),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'delete'),
            child: Row(
              children: [
                Icon(Icons.delete_outline),
                SizedBox(width: 12),
                Text(l10n.delete),
              ],
            ),
          ),
        ],
      ),
    );
    _ownRoute(route);
    final selected = await Navigator.of(context).push(route);
    if (selected == 'delete' && mounted) await _delete();
  }

  Widget _body() {
    if (_loading && !_firstLoadDone) {
      final gutter = feedGutter(context);
      return SnippetDetailSkeleton(
        padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 24),
      );
    }
    // A file that is not loaded yet has its own skeleton, so no bar then.
    final showProgress =
        _firstLoadDone && (_loading || (_blobLoading && _blob != null));
    final error = _error;
    if (error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (showProgress) const LinearProgressIndicator(minHeight: 2),
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
    if (_snapshot != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showProgress) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _multiBody()),
        ],
      );
    }
    final snippet = _snippet;
    final content = _content;
    if (snippet == null || content == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showProgress) const LinearProgressIndicator(minHeight: 2),
        ],
      );
    }
    final lines = content.split('\n');
    final truncatedLineCount = lines.where((line) => line.length > 2000).length;
    final gutter = feedGutter(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showProgress) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
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
                          base: null,
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
                      Text(l10n.content, style: Theme.of(context).textTheme.titleMedium),
                      if (truncatedLineCount > 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          l10n.previewLinesTruncated(truncatedLineCount),
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
          ),
        ),
      ],
    );
  }

  bool _isMarkdown(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.mdown') ||
        lower.endsWith('.mkd');
  }

  Widget _metadata(ProjectSnippet snippet) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(snippet.title, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          Chip(label: Text(snippetVisibilityLabel(snippet.visibility))),
          Chip(label: Text(snippet.authorName)),
          if (_snapshot != null)
            Chip(label: Text(l10n.fileCount(_snapshot!.filePaths.length))),
        ],
      ),
      if (snippet.description.isNotEmpty) ...[
        const SizedBox(height: 12),
        ExpansionTile(
          key: PageStorageKey(
            '${widget.account.key}/${widget.project.id}/${widget.project.path}/snippets/${snippet.id}/${snippet.updatedAt}/description',
          ),
          initiallyExpanded: snippet.description.length <= 800,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          title: Text(l10n.descriptionLabel, key: ValueKey('snippet-description-toggle')),
          children: [
            MarkdownView(
              snippet.description,
              base: null,
              api: widget.api,
              projectId: widget.project.id,
              projectWeb: widget.account.instance.projectWeb(
                widget.project.path,
              ),
              projectPath: widget.project.path,
              account: widget.account,
            ),
          ],
        ),
      ],
    ],
  );

  List<Widget> _blobSlivers(double gutter) {
    final error = _blobError;
    if (error != null) {
      return [
        SliverToBoxAdapter(
          child: FailureNotice(
            error,
            account: widget.account,
            resourceLabel:
                '${widget.project.path} · Snippet #${widget.snippetId} · ${_selectedPath ?? ''}',
            onSwitchAccount: endSessionFrom(context),
            onRetry: _selectedPath == null
                ? null
                : () => _selectFile(_selectedPath!),
          ),
        ),
      ];
    }
    final blob = _blob;
    if (blob == null) {
      if (_blobLoading) {
        return [
          SliverToBoxAdapter(
            child: CodeSkeleton(
              padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
              liveRegion: false,
            ),
          ),
        ];
      }
      return const [];
    }
    if (blob.availability != SnippetBlobAvailability.text) {
      final message = switch (blob.availability) {
        SnippetBlobAvailability.nullContent => l10n.fileTextMissing,
        SnippetBlobAvailability.binary => l10n.binaryNoPreview,
        SnippetBlobAvailability.tooLarge => l10n.filePreviewLimit,
        SnippetBlobAvailability.unretrievable => l10n.gitlabCannotReadFile,
        SnippetBlobAvailability.renderError =>
          blob.renderError ?? l10n.gitlabCannotPreviewFile,
        SnippetBlobAvailability.text => '',
      };
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
          sliver: SliverToBoxAdapter(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(message),
              ),
            ),
          ),
        ),
      ];
    }
    final content = blob.content!;
    if (_markdownPreview && _isMarkdown(blob.path)) {
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
          sliver: SliverToBoxAdapter(
            child: MarkdownView(
              content,
              base: null,
              api: widget.api,
              projectId: widget.project.id,
              projectWeb: widget.account.instance.projectWeb(
                widget.project.path,
              ),
              projectPath: widget.project.path,
              account: widget.account,
            ),
          ),
        ),
      ];
    }
    final lines = content.split('\n');
    final truncated = lines.where((line) => line.length > 2000).length;
    return [
      if (truncated > 0)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 4),
          sliver: SliverToBoxAdapter(
            child: Text(
              l10n.previewTruncatedLines(truncated),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
        sliver: SliverList.builder(
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final raw = lines[index];
            final shown = raw.length > 2000
                ? '${raw.substring(0, 2000)} …'
                : raw;
            return Container(
              color: index.isEven
                  ? Theme.of(context).colorScheme.surfaceContainerLow
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
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
    ];
  }

  Widget _multiBody() {
    final snapshot = _snapshot!;
    final snippet = snapshot.snippet;
    final selected = _selectedPath;
    final editable = _blob?.availability == SnippetBlobAvailability.text;
    final gutter = feedGutter(context);
    return RefreshIndicator(
      onRefresh: () => _load(preferredPath: selected),
      child: CustomScrollView(
        key: PageStorageKey(
          '${widget.account.key}/${widget.project.id}/snippets/${snippet.id}/multi',
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 8),
            sliver: SliverToBoxAdapter(child: _metadata(snippet)),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 4),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.compareFilesSection,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('snippet-add-file'),
                    tooltip: l10n.addFile,
                    onPressed: _busy ? null : _addFile,
                    icon: const Icon(Icons.note_add_outlined),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            sliver: SliverList.builder(
              itemCount: snapshot.filePaths.length,
              itemBuilder: (context, index) {
                final path = snapshot.filePaths[index];
                return ListTile(
                  key: ValueKey('snippet-file-$path'),
                  minVerticalPadding: 12,
                  selected: path == selected,
                  leading: Icon(
                    path == selected
                        ? Icons.description
                        : Icons.description_outlined,
                  ),
                  title: Text(path),
                  trailing: path == selected
                      ? const Icon(Icons.check_circle_outline)
                      : null,
                  onTap: _busy ? null : () => unawaited(_selectFile(path)),
                );
              },
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 4),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selected ?? l10n.noFileSelected,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      if (selected != null && _isMarkdown(selected)) ...[
                        ChoiceChip(
                          key: const ValueKey('snippet-source-mode'),
                          label: Text(l10n.sourceCode),
                          selected: !_markdownPreview,
                          onSelected: (_) =>
                              setState(() => _markdownPreview = false),
                        ),
                        ChoiceChip(
                          key: const ValueKey('snippet-markdown-mode'),
                          label: const Text('Markdown'),
                          selected: _markdownPreview,
                          onSelected: (_) =>
                              setState(() => _markdownPreview = true),
                        ),
                      ],
                      TextButton.icon(
                        key: const ValueKey('snippet-edit-file'),
                        onPressed: !_busy && editable ? _updateFile : null,
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(l10n.editAction),
                      ),
                      TextButton.icon(
                        key: const ValueKey('snippet-rename-file'),
                        onPressed: !_busy && editable ? _renameFile : null,
                        icon: const Icon(Icons.drive_file_rename_outline),
                        label: Text(l10n.renameAction),
                      ),
                      TextButton.icon(
                        key: const ValueKey('snippet-delete-file'),
                        onPressed: _busy || selected == null
                            ? null
                            : _deleteFile,
                        icon: const Icon(Icons.delete_outline),
                        label: Text(l10n.deleteFile),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          ..._blobSlivers(gutter),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Snippet #${widget.snippetId}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_snippet != null)
            ResourceShareButton(
              uri: widget.account.instance.projectWeb(
                '${widget.project.path}/-/snippets/${widget.snippetId}',
              ),
              ownerKey: (
                widget.account.key,
                widget.api,
                widget.project.id,
                widget.project.path,
                widget.snippetId,
              ),
              isCurrent: () =>
                  mounted &&
                  !owner.api.isClosed &&
                  widget.account.key == owner.account.key &&
                  identical(widget.api, owner.api) &&
                  widget.project.id == owner.project.id &&
                  widget.project.path == owner.project.path &&
                  widget.snippetId == owner.snippetId,
            ),
          IconButton(
            tooltip: l10n.editSnippet,
            onPressed: _snippet == null || _busy ? null : _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: l10n.moreOptions,
            onPressed: _snippet == null || _busy ? null : _showMore,
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: _body(),
    );
  }
}
