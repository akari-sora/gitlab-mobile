import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';

import '../../l10n/l10n.dart';
final class _DraftScope {
  const _DraftScope({
    required this.generation,
    required this.account,
    required this.api,
    required this.project,
    required this.iid,
    required this.headSha,
  });

  final int generation;
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final String headSha;

  List<String> get mrPath => [
    'projects',
    '${project.id}',
    'merge_requests',
    '$iid',
  ];
  List<String> get draftPath => [...mrPath, 'draft_notes'];
  String get reviewIdentity =>
      '${account.key}/${project.id}/merge_requests/$iid/$headSha';
}

final class _StaleDraftOperation implements Exception {
  const _StaleDraftOperation();
}

/// The current account's unpublished review comments for one MR version.
///
/// GitLab keeps draft notes private to their author. This page deliberately
/// scopes editor persistence to the account, project, MR and reviewed SHA so a
/// draft can never appear in another review.
class DraftReviewPage extends StatefulWidget {
  const DraftReviewPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.iid,
    required this.headSha,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final String headSha;

  @override
  State<DraftReviewPage> createState() => _DraftReviewPageState();
}

class _DraftReviewPageState extends State<DraftReviewPage> {
  List<Json> _drafts = const [];
  ApiFailure? _error;
  bool _loading = true;
  bool _firstLoadDone = false;
  bool _busy = false;
  bool _readbackRequired = false;
  int _epoch = 0;
  int _generation = 0;
  final Set<Route<dynamic>> _foregroundRoutes = <Route<dynamic>>{};

  _DraftScope _scope() => _DraftScope(
    generation: _generation,
    account: widget.account,
    api: widget.api,
    project: widget.project,
    iid: widget.iid,
    headSha: widget.headSha,
  );

  bool _isCurrent(_DraftScope scope) =>
      mounted && scope.generation == _generation;

  void _requireCurrent(_DraftScope scope) {
    if (!_isCurrent(scope)) throw const _StaleDraftOperation();
  }

  void _dismissOwnedForeground() {
    final navigator = Navigator.of(context);
    final routes = _foregroundRoutes.toList(growable: false);
    _foregroundRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!navigator.mounted) return;
      for (final route in routes) {
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant DraftReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account ||
        oldWidget.account.key != widget.account.key ||
        oldWidget.api != widget.api ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.iid != widget.iid ||
        oldWidget.headSha != widget.headSha) {
      _generation++;
      _epoch++;
      _dismissOwnedForeground();
      _drafts = const [];
      _error = null;
      _loading = true;
      _firstLoadDone = false;
      _busy = false;
      _readbackRequired = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    _foregroundRoutes.clear();
    super.dispose();
  }

  Future<List<Json>> _readAllDrafts(_DraftScope scope) async {
    final drafts = <Json>[];
    final ids = <int>{};
    final seenCursors = <String>{};
    Uri? next;
    for (var page = 0; page < 20; page++) {
      final requestCursor = next?.toString();
      if (requestCursor != null && !seenCursors.add(requestCursor)) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      final result = await scope.api.records(scope.draftPath, next: next);
      _requireCurrent(scope);
      for (final draft in result.items) {
        if (!ids.add(requiredInt(draft, 'id'))) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
        drafts.add(draft);
      }
      final candidate = result.next;
      if (candidate != null &&
          (candidate.toString() == requestCursor ||
              seenCursors.contains(candidate.toString()))) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      next = candidate;
      if (next == null) return List<Json>.unmodifiable(drafts);
    }
    throw ApiFailure(
      FailureKind.tooLarge,
      title: l10n.tooManyReviewDrafts,
      detail: l10n.reviewDraftLoadLimit,
    );
  }

  Future<bool> _load({ApiFailure? readbackFailure}) async {
    final scope = _scope();
    final epoch = ++_epoch;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final drafts = await _readAllDrafts(scope);
      if (!_isCurrent(scope) || epoch != _epoch) return false;
      setState(() {
        _drafts = drafts;
        _readbackRequired = false;
        _firstLoadDone = true;
      });
      return true;
    } on _StaleDraftOperation {
      return false;
    } catch (error) {
      if (!_isCurrent(scope) || epoch != _epoch) return false;
      setState(() => _error = readbackFailure ?? safeFailure(error));
      return false;
    } finally {
      if (_isCurrent(scope) && epoch == _epoch) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Object? _stableValue(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _stableValue(value[key]),
      };
    }
    if (value is List) return value.map(_stableValue).toList(growable: false);
    return value;
  }

  String _snapshot(List<Json> drafts) {
    final stable =
        [
          for (final draft in drafts)
            <String, Object?>{
              'id': requiredInt(draft, 'id'),
              'note': draft['note'],
              'commit_id': draft['commit_id'],
              'position': _stableValue(draft['position']),
              'resolve_discussion': draft['resolve_discussion'],
            },
        ]..sort(
          (left, right) => (left['id']! as int).compareTo(right['id']! as int),
        );
    return jsonEncode(stable);
  }

  Future<bool> _readBackAcceptedWrite(
    _DraftScope scope,
    ApiFailure failure,
  ) async {
    if (!_isCurrent(scope)) return false;
    setState(() => _readbackRequired = true);
    final verified = await _load(readbackFailure: failure);
    if (!mounted || !_isCurrent(scope)) return false;
    if (!verified && _error != null) showFailure(context, _error!);
    return verified;
  }

  Future<void> _verifyHead(_DraftScope scope) async {
    _requireCurrent(scope);
    final current = await scope.api.record(scope.mrPath);
    _requireCurrent(scope);
    final currentSha = valueText(current, 'sha');
    if (currentSha.isEmpty) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    if (currentSha != scope.headSha) {
      throw ApiFailure(
        FailureKind.conflict,
        title: l10n.mergeRequestNewVersion,
        detail: l10n.reloadChangesBeforeDraft,
      );
    }
  }

  Future<T?> _pushOwnedRoute<T>(_DraftScope scope, Route<T> route) async {
    _requireCurrent(scope);
    _foregroundRoutes.add(route);
    try {
      final result = await Navigator.of(context).push<T>(route);
      _requireCurrent(scope);
      return result;
    } finally {
      _foregroundRoutes.remove(route);
    }
  }

  Future<bool> _openEditor(
    _DraftScope scope, {
    required String title,
    required String resource,
    required List<EditField> fields,
    required SaveEditor save,
    String? subtitle,
    String? baseRevision,
  }) async {
    final route = MaterialPageRoute<bool>(
      builder: (_) => ResourceEditor(
        account: scope.account,
        title: title,
        resource: resource,
        fields: fields,
        save: save,
        subtitle: subtitle,
        baseRevision: baseRevision,
        api: scope.api,
        projectId: scope.project.id,
        projectPath: scope.project.path,
      ),
    );
    try {
      return await _pushOwnedRoute(scope, route) ?? false;
    } on _StaleDraftOperation {
      return false;
    }
  }

  Future<bool> _confirm(
    _DraftScope scope,
    String title,
    String detail, {
    String? requiredText,
  }) async {
    final input = TextEditingController();
    final route = DialogRoute<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(detail),
                if (requiredText != null) ...[
                  const SizedBox(height: 16),
                  Text(l10n.typeToConfirm(requiredText)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: input,
                    autocorrect: false,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(labelText: l10n.confirmName),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              onPressed:
                  requiredText == null || input.text.trim() == requiredText
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(l10n.confirmAction),
            ),
          ],
        ),
      ),
    );
    try {
      return await _pushOwnedRoute(scope, route) ?? false;
    } on _StaleDraftOperation {
      return false;
    } finally {
      await route.completed;
      input.dispose();
    }
  }

  Future<void> _create() async {
    if (_busy || _readbackRequired) return;
    final scope = _scope();
    final saved = await _openEditor(
      scope,
      title: l10n.addReviewDraft,
      subtitle:
          '${scope.project.path} · !${scope.iid} · ${shortSha(scope.headSha)}',
      resource: '${scope.reviewIdentity}/draft-notes/new',
      fields: [
        EditField(
          'note',
          l10n.reviewComment,
          required: true,
          lines: 8,
          hint: l10n.reviewDraftMarkdownHint,
          markdown: true,
        ),
      ],
      save: (values) async {
        _requireCurrent(scope);
        await _verifyHead(scope);
        _requireCurrent(scope);
        await scope.api.createDraftNote(
          scope.project.id,
          scope.iid,
          values['note']!.trim(),
          commitId: scope.headSha,
        );
        _requireCurrent(scope);
      },
    );
    if (saved && _isCurrent(scope)) {
      await _readBackAcceptedWrite(
        scope,
        ApiFailure(
          FailureKind.server,
          title: l10n.draftSubmitUnconfirmed,
          detail: l10n.draftCreateAcceptedReadFailed,
        ),
      );
    }
  }

  Future<void> _edit(Json draft) async {
    if (_busy || _readbackRequired) return;
    final scope = _scope();
    final id = requiredInt(draft, 'id');
    final original = valueText(draft, 'note');
    final saved = await _openEditor(
      scope,
      title: l10n.editReviewDraft(id),
      subtitle: '${scope.project.path} · !${scope.iid}',
      resource: '${scope.reviewIdentity}/draft-notes/$id',
      baseRevision: original,
      fields: [
        EditField(
          'note',
          l10n.reviewComment,
          required: true,
          lines: 8,
          hint: l10n.reviewDraftMarkdownHint,
          markdown: true,
          value: original,
        ),
      ],
      save: (values) async {
        _requireCurrent(scope);
        await _verifyHead(scope);
        _requireCurrent(scope);
        final current = await scope.api.record([...scope.draftPath, '$id']);
        _requireCurrent(scope);
        if (valueText(current, 'note') != original) {
          throw const ApiFailure(FailureKind.conflict);
        }
        await scope.api.updateDraftNote(
          scope.project.id,
          scope.iid,
          id,
          values['note']!.trim(),
        );
        _requireCurrent(scope);
      },
    );
    if (saved && _isCurrent(scope)) {
      await _readBackAcceptedWrite(
        scope,
        ApiFailure(
          FailureKind.server,
          title: l10n.draftEditUnconfirmed,
          detail: l10n.draftUpdateAcceptedReadFailed,
        ),
      );
    }
  }

  Future<void> _discard(Json draft) async {
    if (_busy || _readbackRequired) return;
    final scope = _scope();
    final id = requiredInt(draft, 'id');
    if (!await _confirm(
      scope,
      l10n.discardReviewDraftConfirm(id),
      l10n.discardReviewDraftWarning,
      requiredText: '#$id',
    )) {
      return;
    }
    if (!_isCurrent(scope)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _verifyHead(scope);
      _requireCurrent(scope);
      final current = await scope.api.record([...scope.draftPath, '$id']);
      _requireCurrent(scope);
      if (valueText(current, 'note') != valueText(draft, 'note')) {
        throw const ApiFailure(FailureKind.conflict);
      }
      await scope.api.deleteDraftNote(scope.project.id, scope.iid, id);
      _requireCurrent(scope);
      final verified = await _readBackAcceptedWrite(
        scope,
        ApiFailure(
          FailureKind.server,
          title: l10n.draftDiscardUnconfirmed,
          detail: l10n.draftDeleteAcceptedReadFailed,
        ),
      );
      if (verified && mounted && _isCurrent(scope)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.reviewDraftDiscarded)));
      }
    } on _StaleDraftOperation {
      return;
    } catch (error) {
      if (_isCurrent(scope)) _retainWriteFailure(scope, error);
    } finally {
      if (_isCurrent(scope)) setState(() => _busy = false);
    }
  }

  Future<void> _publish() async {
    if (_busy || _readbackRequired || _drafts.isEmpty) return;
    final scope = _scope();
    setState(() {
      _busy = true;
      _error = null;
    });
    late final List<Json> confirmedDrafts;
    try {
      confirmedDrafts = await _readAllDrafts(scope);
      _requireCurrent(scope);
      setState(() => _drafts = confirmedDrafts);
    } on _StaleDraftOperation {
      return;
    } catch (error) {
      if (_isCurrent(scope)) _retainWriteFailure(scope, error);
      return;
    } finally {
      if (_isCurrent(scope)) setState(() => _busy = false);
    }
    if (!_isCurrent(scope) || confirmedDrafts.isEmpty) return;
    final count = confirmedDrafts.length;
    final confirmedSnapshot = _snapshot(confirmedDrafts);
    if (!await _confirm(
      scope,
      l10n.publishServerReviewDraftsConfirm(count),
      l10n.publishAllServerDraftsWarning,
    )) {
      return;
    }
    if (!_isCurrent(scope)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _verifyHead(scope);
      _requireCurrent(scope);
      final currentDrafts = await _readAllDrafts(scope);
      _requireCurrent(scope);
      if (_snapshot(currentDrafts) != confirmedSnapshot) {
        setState(() => _drafts = currentDrafts);
        throw ApiFailure(
          FailureKind.conflict,
          title: l10n.serverReviewDraftsChanged,
          detail: l10n.publishCanceledDraftsChanged,
        );
      }
      await scope.api.publishDraftNotes(scope.project.id, scope.iid);
      _requireCurrent(scope);
      final verified = await _readBackAcceptedWrite(
        scope,
        ApiFailure(
          FailureKind.server,
          title: l10n.publishSubmitUnconfirmed,
          detail: l10n.publishAcceptedReadFailed,
        ),
      );
      if (verified && mounted && _isCurrent(scope)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.publishedReviewDrafts(count))));
      }
    } on _StaleDraftOperation {
      return;
    } catch (error) {
      if (_isCurrent(scope)) _retainWriteFailure(scope, error);
    } finally {
      if (_isCurrent(scope)) setState(() => _busy = false);
    }
  }

  void _retainWriteFailure(_DraftScope scope, Object error) {
    if (!_isCurrent(scope)) return;
    final failure = safeFailure(error);
    setState(() {
      _error = failure;
      if (failure.kind == FailureKind.writeUncertain) {
        _readbackRequired = true;
      }
    });
    showFailure(context, failure);
  }

  String _location(Json draft) {
    final position = valueObject(draft, 'position');
    final path = valueText(
      position,
      'new_path',
      valueText(position, 'old_path'),
    );
    if (path.isEmpty) return l10n.generalComment;
    final line = position['new_line'] ?? position['old_line'];
    return line is int ? l10n.draftFileLine(path, line) : path;
  }

  Widget _draftTile(Json draft) {
    final id = requiredInt(draft, 'id');
    final note = valueText(draft, 'note');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _location(draft),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: l10n.draftActions,
                    enabled: !_busy && !_readbackRequired,
                    onSelected: (action) {
                      if (action == 'edit') unawaited(_edit(draft));
                      if (action == 'discard') unawaited(_discard(draft));
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'edit', child: Text(l10n.editAction)),
                      PopupMenuItem(value: 'discard', child: Text(l10n.discardAction)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SelectionArea(
                child: Text(
                  note,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.draftIdAndSha(id, shortSha(valueText(draft, 'commit_id', widget.headSha))),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasContent = _drafts.isNotEmpty;
    final hasError = _error != null;
    final contentCount = hasContent ? _drafts.length + 1 : 1;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.reviewDrafts),
            Text(
              '${widget.project.path} · !${widget.iid}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l10n.refreshReviewDrafts,
            onPressed: _loading || _busy ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: l10n.addReviewDraft,
            onPressed: _busy || _readbackRequired ? null : _create,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if ((_loading && _firstLoadDone) || _busy)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await _load();
                },
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 8, bottom: 96),
                  itemCount: 1 + (hasError ? 1 : 0) + contentCount,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.visibility_off_outlined,
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(l10n.unpublishedCommentsHint),
                            ),
                          ],
                        ),
                      );
                    }
                    var contentIndex = index - 1;
                    if (hasError) {
                      if (contentIndex == 0) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: FailureNotice(
                            _error!,
                            onRetry: () => _load(),
                            account: widget.account,
                            resourceLabel:
                                l10n.mergeRequestReviewDraftsTitle(widget.project.path, widget.iid),
                            onSwitchAccount: endSessionFrom(context),
                          ),
                        );
                      }
                      contentIndex--;
                    }
                    if (_loading && !_firstLoadDone) return const ListSkeleton();
                    if (!hasContent) {
                      return Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: EmptyState(
                          l10n.noReviewDrafts,
                          icon: Icons.rate_review_outlined,
                          detail: l10n.addDraftsThenPublishHint,
                        ),
                      );
                    }
                    if (contentIndex == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        child: Text(
                          l10n.draftsPendingPublish(_drafts.length),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      );
                    }
                    return _draftTile(_drafts[contentIndex - 1]);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          key: const ValueKey('publish-draft-review'),
          onPressed: _busy || _loading || _readbackRequired || _drafts.isEmpty
              ? null
              : _publish,
          icon: const Icon(Icons.send_outlined),
          label: Text(_drafts.isEmpty ? l10n.noDraftsToPublish : l10n.publishDraftCount(_drafts.length)),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
      ),
    );
  }
}
