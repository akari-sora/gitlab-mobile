import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';

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
    throw const ApiFailure(
      FailureKind.tooLarge,
      title: '審查草稿太多',
      detail: '目前最多一次載入 600 則草稿。請先在 GitLab 發布或捨棄一部分。',
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
        setState(() => _loading = false);
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
      throw const ApiFailure(
        FailureKind.conflict,
        title: '合併請求已有新版本',
        detail: '請返回變更頁重新載入最新版本，再檢查草稿內容。草稿已保留。',
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
                  Text('輸入「$requiredText」確認'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: input,
                    autocorrect: false,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(labelText: '確認名稱'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  requiredText == null || input.text.trim() == requiredText
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('確認'),
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
      title: '新增審查草稿',
      subtitle:
          '${scope.project.path} · !${scope.iid} · ${shortSha(scope.headSha)}',
      resource: '${scope.reviewIdentity}/draft-notes/new',
      fields: const [
        EditField(
          'note',
          '審查意見',
          required: true,
          lines: 8,
          hint: '支援 Markdown；發布前只有你看得到。',
          markdown: true,
        ),
      ],
      save: (values) async {
        _requireCurrent(scope);
        await _verifyHead(scope);
        _requireCurrent(scope);
        await scope.api.writeRecord('POST', scope.draftPath, {
          'note': values['note']!.trim(),
          'commit_id': scope.headSha,
        });
        _requireCurrent(scope);
      },
    );
    if (saved && _isCurrent(scope)) {
      await _readBackAcceptedWrite(
        scope,
        const ApiFailure(
          FailureKind.server,
          title: '草稿已送出，尚未確認結果',
          detail: 'GitLab 已接受新增要求，但後續讀取失敗。請先重新整理確認伺服器狀態。',
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
      title: '編輯審查草稿 #$id',
      subtitle: '${scope.project.path} · !${scope.iid}',
      resource: '${scope.reviewIdentity}/draft-notes/$id',
      baseRevision: original,
      fields: [
        EditField(
          'note',
          '審查意見',
          required: true,
          lines: 8,
          hint: '支援 Markdown；發布前只有你看得到。',
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
        await scope.api.writeRecord(
          'PUT',
          [...scope.draftPath, '$id'],
          {'note': values['note']!.trim()},
        );
        _requireCurrent(scope);
      },
    );
    if (saved && _isCurrent(scope)) {
      await _readBackAcceptedWrite(
        scope,
        const ApiFailure(
          FailureKind.server,
          title: '修改已送出，尚未確認結果',
          detail: 'GitLab 已接受修改要求，但後續讀取失敗。請先重新整理確認伺服器狀態。',
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
      '捨棄審查草稿 #$id？',
      '這則尚未發布的審查意見會永久刪除。',
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
      await scope.api.removeRecord([...scope.draftPath, '$id']);
      _requireCurrent(scope);
      final verified = await _readBackAcceptedWrite(
        scope,
        const ApiFailure(
          FailureKind.server,
          title: '捨棄已送出，尚未確認結果',
          detail: 'GitLab 已接受刪除要求，但後續讀取失敗。請先重新整理確認伺服器狀態，不要重複捨棄。',
        ),
      );
      if (verified && mounted && _isCurrent(scope)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('審查草稿已捨棄')));
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
      '發布伺服器上的 $count 則審查草稿？',
      'GitLab 會發布這個帳號在伺服器上的全部草稿。送出前會再次檢查；確認後若其他裝置又新增草稿，仍可能一併發布。發布後，其他專案成員將能看到。',
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
        throw const ApiFailure(
          FailureKind.conflict,
          title: '伺服器上的審查草稿已變更',
          detail: '其他裝置新增、修改或刪除了草稿。已取消發布，請重新檢查目前的完整清單。',
        );
      }
      await scope.api.writeEmpty('POST', [...scope.draftPath, 'bulk_publish']);
      _requireCurrent(scope);
      final verified = await _readBackAcceptedWrite(
        scope,
        const ApiFailure(
          FailureKind.server,
          title: '發布已送出，尚未確認結果',
          detail: 'GitLab 已接受發布要求，但後續讀取失敗。請先重新整理確認伺服器狀態，不要再次發布。',
        ),
      );
      if (verified && mounted && _isCurrent(scope)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已發布 $count 則審查草稿')));
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
    if (path.isEmpty) return '一般留言';
    final line = position['new_line'] ?? position['old_line'];
    return line is int ? '$path · 第 $line 行' : path;
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
                    tooltip: '草稿操作',
                    enabled: !_busy && !_readbackRequired,
                    onSelected: (action) {
                      if (action == 'edit') unawaited(_edit(draft));
                      if (action == 'discard') unawaited(_discard(draft));
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('編輯')),
                      PopupMenuItem(value: 'discard', child: Text('捨棄')),
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
                '草稿 #$id · ${shortSha(valueText(draft, 'commit_id', widget.headSha))}',
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
            const Text('審查草稿'),
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
            tooltip: '重新整理審查草稿',
            onPressed: _loading || _busy ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '新增審查草稿',
            onPressed: _busy || _readbackRequired ? null : _create,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
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
                            const Expanded(
                              child: Text('只有你看得到這些尚未發布的留言。請在發布前再次檢查內容與版本。'),
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
                                '${widget.project.path} · !${widget.iid} · 審查草稿',
                            onSwitchAccount: endSessionFrom(context),
                          ),
                        );
                      }
                      contentIndex--;
                    }
                    if (_loading && !hasContent) return const ListSkeleton();
                    if (!hasContent) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: EmptyState(
                          '沒有審查草稿',
                          icon: Icons.rate_review_outlined,
                          detail: '新增草稿後，可以先集中檢查，再一次發布到合併請求。',
                        ),
                      );
                    }
                    if (contentIndex == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        child: Text(
                          '${_drafts.length} 則待發布',
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
          label: Text(_drafts.isEmpty ? '沒有可發布的草稿' : '發布 ${_drafts.length} 則'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
      ),
    );
  }
}
