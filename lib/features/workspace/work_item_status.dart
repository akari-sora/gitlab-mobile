import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_state_models.dart';
import '../../core/work_item_status_models.dart';
import '../../shared/workspace_ui.dart';

final _hexColor = RegExp(r'^#[0-9A-Fa-f]{6}$');

/// Status-only signal around one save that reached the mutation handoff.
/// [token] is a fresh opaque object per save. [sessionGeneration] is the
/// immutable generation injected by the owner when the editor was opened.
typedef WorkItemStatusWriteListener =
    void Function(
      WorkItemStatusWritePhase phase,
      Object token,
      Account account,
      GitLabApi api,
      WorkItemGraphDetail detail,
      int sessionGeneration,
    );

bool _alwaysCurrent() => true;

/// On-demand status action. Capability comes only from a fresh
/// [GitLabApi.workItemStatus] read, never from data already on screen.
class WorkItemStatusControl extends StatefulWidget {
  const WorkItemStatusControl({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    required this.sessionGeneration,
    required this.onSaved,
    this.isCurrent = _alwaysCurrent,
    this.ownerChanges,
    this.onRoute,
    this.onStatusWrite,
    this.writePending = false,
    this.operationCurrent,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final int sessionGeneration;
  final ValueChanged<WorkItemStatusSaveResult> onSaved;
  final bool Function() isCurrent;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;
  final WorkItemStatusWriteListener? onStatusWrite;
  final bool writePending;
  final bool Function()? operationCurrent;

  @override
  State<WorkItemStatusControl> createState() => _WorkItemStatusControlState();
}

class _WorkItemStatusControlState extends State<WorkItemStatusControl> {
  var _epoch = 0;
  var _opening = false;
  ApiFailure? _error;
  WorkItemStatusSaveResult? _result;
  Route<WorkItemStatusSaveResult>? _route;
  NavigatorState? _navigator;
  Object? _writeToken;

  bool _current(int epoch) => mounted && epoch == _epoch && widget.isCurrent();
  bool get _writePending => widget.writePending || _writeToken != null;

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemStatusControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.sessionGeneration != widget.sessionGeneration ||
        _identityChanged(oldWidget.detail.summary, widget.detail.summary)) {
      _invalidate();
    } else if (oldWidget.detail.summary.updatedAt !=
        widget.detail.summary.updatedAt) {
      _invalidate(keepResult: _resultMatches(widget.detail.summary));
    }
  }

  /// A result line stays only while the parent's revision is the one the
  /// result's authoritative read observed.
  bool _resultMatches(WorkItemGraphSummary summary) {
    final result = _result;
    return result != null &&
        result.snapshot.updatedAt.isAtSameMomentAs(summary.updatedAt);
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _epoch++;
    _dismissRoute();
    super.dispose();
  }

  void _noteStarted(Object token) {
    _writeToken = token;
    if (mounted) setState(() {});
  }

  void _noteSettled(Object token) {
    if (!identical(_writeToken, token)) return;
    _writeToken = null;
    if (mounted) setState(() {});
  }

  void _ownerChanged() {
    if (widget.isCurrent()) return;
    _invalidate();
  }

  void _dismissRoute() {
    final route = _route;
    final navigator = _navigator;
    _route = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route != null &&
          route.isActive &&
          navigator != null &&
          navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
  }

  void _invalidate({bool keepResult = false}) {
    _epoch++;
    _opening = false;
    _error = null;
    if (!keepResult) _result = null;
    _dismissRoute();
    if (mounted) setState(() {});
  }

  bool _identityChanged(WorkItemGraphSummary left, WorkItemGraphSummary right) =>
      left.id != right.id ||
      left.iid != right.iid ||
      left.type.id != right.type.id ||
      left.project?.id != right.project?.id ||
      left.project?.fullPath != right.project?.fullPath ||
      left.namespace?.id != right.namespace?.id ||
      left.namespace?.fullPath != right.namespace?.fullPath;

  Future<void> _open() async {
    final existing = _route;
    if (!mounted ||
        _opening ||
        (existing != null && existing.isActive) ||
        _writePending ||
        !widget.isCurrent()) {
      return;
    }
    final epoch = _epoch;
    final account = widget.account;
    final api = widget.api;
    final detail = widget.detail;
    final generation = widget.sessionGeneration;
    final writeListener = widget.onStatusWrite;
    final operationCurrent = widget.operationCurrent ?? widget.isCurrent;
    setState(() {
      _opening = true;
      _error = null;
      _result = null;
    });
    try {
      final access = await api.workItemStatus(
        detail,
        expectedUserId: account.user.id,
        generation: generation,
        isCurrent: () => _current(epoch),
      );
      if (!mounted) return;
      if (!_current(epoch)) return;
      final navigator = Navigator.of(context);
      final route = MaterialPageRoute<WorkItemStatusSaveResult>(
        builder: (context) => _WorkItemStatusEditor(
          account: account,
          api: api,
          detail: detail,
          sessionGeneration: generation,
          access: access,
          isCurrent: () => _current(epoch),
          operationCurrent: operationCurrent,
          writeListener: writeListener,
          onWriteStarted: _noteStarted,
          onWriteSettled: _noteSettled,
        ),
      );
      _navigator = navigator;
      _route = route;
      setState(() => _opening = false);
      widget.onRoute?.call(route);
      final saved = await navigator.push(route);
      if (identical(_route, route)) _route = null;
      if (!_current(epoch) || saved == null) return;
      setState(() => _result = saved);
      widget.onSaved(saved);
    } on ApiFailure catch (error) {
      if (!_current(epoch) || error.kind == FailureKind.cancelled) return;
      setState(() => _error = error);
    } catch (error) {
      if (!_current(epoch)) return;
      setState(() => _error = safeFailure(error));
    } finally {
      if (_current(epoch) && _opening) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('work-item-status-edit'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _opening || _writePending || !widget.isCurrent()
                ? null
                : () => unawaited(_open()),
            icon: _opening
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.flag_outlined),
            label: Text(
              _writePending
                  ? '變更中…'
                  : _opening
                  ? '讀取狀態權限…'
                  : '變更狀態',
            ),
          ),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              _resultLabel(result),
              key: const ValueKey('work-item-status-result'),
            ),
          ),
        if (_error != null)
          FailureNotice(
            _error!,
            account: widget.account,
            resourceLabel: _statusResourceLabel(widget.detail.summary),
            onRetry: () => unawaited(_open()),
          ),
      ],
    );
  }
}

/// One save attempt's captured owner. START and SETTLE always carry these
/// values, even if the editor, control or route is gone by then.
final class _StatusWrite {
  _StatusWrite({
    required this.account,
    required this.api,
    required this.detail,
    required this.sessionGeneration,
    required this.listener,
    required this.onStarted,
    required this.onSettled,
  });

  final Object token = Object();
  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final int sessionGeneration;
  final WorkItemStatusWriteListener? listener;
  final ValueChanged<Object> onStarted;
  final ValueChanged<Object> onSettled;
  var _started = false;
  var _settled = false;

  bool get started => _started;

  void start() {
    if (_started) return;
    _started = true;
    onStarted(token);
    listener?.call(
      WorkItemStatusWritePhase.start,
      token,
      account,
      api,
      detail,
      sessionGeneration,
    );
  }

  void settle() {
    if (!_started || _settled) return;
    _settled = true;
    try {
      listener?.call(
        WorkItemStatusWritePhase.settle,
        token,
        account,
        api,
        detail,
        sessionGeneration,
      );
    } finally {
      onSettled(token);
    }
  }
}

class _WorkItemStatusEditor extends StatefulWidget {
  const _WorkItemStatusEditor({
    required this.account,
    required this.api,
    required this.detail,
    required this.sessionGeneration,
    required this.access,
    required this.isCurrent,
    required this.operationCurrent,
    required this.writeListener,
    required this.onWriteStarted,
    required this.onWriteSettled,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final int sessionGeneration;
  final WorkItemStatusAccess access;
  final bool Function() isCurrent;
  final bool Function() operationCurrent;
  final WorkItemStatusWriteListener? writeListener;
  final ValueChanged<Object> onWriteStarted;
  final ValueChanged<Object> onWriteSettled;

  @override
  State<_WorkItemStatusEditor> createState() => _WorkItemStatusEditorState();
}

class _WorkItemStatusEditorState extends State<_WorkItemStatusEditor> {
  final _scroll = ScrollController();
  String? _selected;
  var _writing = false;
  var _saveAttempted = false;
  ApiFailure? _saveError;

  WorkItemStatusSnapshot get _snapshot => widget.access.snapshot;

  bool get _capable =>
      widget.access.canWrite &&
      widget.access.target != null &&
      _snapshot.assignment.kind != WorkItemStatusAssignmentKind.unidentified &&
      _snapshot.allowedStatuses.isNotEmpty;

  bool get _editable =>
      _capable && widget.isCurrent() && !_saveAttempted && !_writing;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _choose(String id) {
    if (!_editable || _selected == id) return;
    setState(() => _selected = id);
  }

  Future<void> _save() async {
    final target = widget.access.target;
    final candidate = _selected;
    if (!_editable || target == null || candidate == null) return;
    final api = widget.api;
    final isCurrent = widget.isCurrent;
    final operationCurrent = widget.operationCurrent;
    final write = _StatusWrite(
      account: widget.account,
      api: api,
      detail: widget.detail,
      sessionGeneration: widget.sessionGeneration,
      listener: widget.writeListener,
      onStarted: widget.onWriteStarted,
      onSettled: widget.onWriteSettled,
    );
    setState(() {
      _writing = true;
      _saveAttempted = true;
      _saveError = null;
    });
    try {
      final result = await api.updateWorkItemStatus(
        target,
        candidateId: candidate,
        isCurrent: () =>
            write.started ? operationCurrent() : mounted && isCurrent(),
        onMutationSent: (started) {
          started(write.token);
          write.start();
        },
      );
      if (!mounted || !widget.isCurrent()) return;
      Navigator.of(context).pop(result);
    } on WorkItemStatusWriteFailure catch (failure) {
      _showFailure(_writeFailure(failure));
    } catch (error) {
      _showFailure(safeFailure(error));
    } finally {
      write.settle();
    }
  }

  void _showFailure(ApiFailure failure) {
    if (!mounted || !widget.isCurrent()) return;
    setState(() {
      _writing = false;
      _saveError = failure;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final blocked = _blockedMessage();
    final pending = _pendingLabel();
    final error = _saveError;
    final statuses = snapshot.allowedStatuses;
    // Scaffold lays this bar on the viewport bottom and only shrinks the
    // body. This padding is the keyboard inset; SafeArea applies the
    // uncovered system inset once.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: const Text('變更狀態')),
      body: CustomScrollView(
        key: const ValueKey('work-item-status-scroll'),
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverList.list(
              children: [
                Text(
                  '@${widget.account.user.username} · ${widget.account.instance.key}',
                ),
                const SizedBox(height: 4),
                Text(_statusResourceLabel(widget.detail.summary)),
                const SizedBox(height: 4),
                Text(widget.detail.summary.title),
                const SizedBox(height: 12),
                Text('目前生命週期：${_lifecycleLabel(snapshot.state)}'),
                const SizedBox(height: 4),
                Text('目前狀態：${_assignmentLabel(snapshot.assignment)}'),
                if (blocked != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    blocked,
                    key: const ValueKey('work-item-status-capability'),
                  ),
                ],
                if (_saveAttempted && error != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '請關閉並重新開啟，讀取最新狀態後再變更。',
                    key: ValueKey('work-item-status-reopen-hint'),
                  ),
                  FailureNotice(
                    error,
                    account: widget.account,
                    resourceLabel: _statusResourceLabel(widget.detail.summary),
                  ),
                ],
                const SizedBox(height: 12),
                Card(
                  key: const ValueKey('work-item-status-warning'),
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline, size: 20),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '套用狀態時，GitLab 可能會關閉或重新開啟這個工作項目。'
                            '最終狀態與開啟／關閉以儲存後重新讀取的伺服器結果為準。',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList.builder(
              itemCount: statuses.length,
              itemBuilder: (context, index) =>
                  _statusRow(context, statuses[index]),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (pending != null) ...[
                  Text(
                    pending,
                    key: const ValueKey('work-item-status-pending'),
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton(
                  key: const ValueKey('work-item-status-save'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _editable && _selected != null
                      ? () => unawaited(_save())
                      : null,
                  child: _writing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('儲存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusRow(BuildContext context, WorkItemStatusRecord status) {
    final id = status.id!;
    final selected = _selected == id;
    final editable = _editable;
    final assignment = _snapshot.assignment;
    final isAssigned =
        assignment.kind == WorkItemStatusAssignmentKind.identified &&
        assignment.id == id;
    final name = _statusName(status.name);
    final label = isAssigned ? '$name（目前）' : name;
    final category = '分類：${status.category ?? '未提供'}';
    final description = status.description;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey('work-item-status-choice-$id'),
      excludeSemantics: true,
      label: '$label，$category',
      button: true,
      enabled: editable,
      checked: selected,
      inMutuallyExclusiveGroup: true,
      onTap: () => _choose(id),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        minTileHeight: 48,
        selected: selected,
        enabled: editable,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.circle,
              key: ValueKey('work-item-status-dot-$id'),
              size: 12,
              color: _dotColor(status.color, scheme),
            ),
          ],
        ),
        title: Text(label),
        subtitle: Text(
          description == null ? category : '$category\n$description',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _choose(id),
      ),
    );
  }

  String? _blockedMessage() {
    if (_capable) return null;
    if (_snapshot.assignment.kind ==
        WorkItemStatusAssignmentKind.unidentified) {
      return '目前狀態沒有可識別的伺服器 ID，無法安全變更。';
    }
    if (!widget.access.canWrite || widget.access.target == null) {
      return '目前帳號沒有變更狀態的權限。';
    }
    return '這個工作項目沒有可選擇的狀態。';
  }

  String? _pendingLabel() {
    final id = _selected;
    if (!_editable || id == null) return null;
    final assignment = _snapshot.assignment;
    if (assignment.kind == WorkItemStatusAssignmentKind.identified &&
        assignment.id == id) {
      return '已是目前狀態，儲存不會送出變更。';
    }
    final record = _snapshot.allowedStatuses.firstWhere(
      (status) => status.id == id,
    );
    return '將套用：${_statusName(record.name)}';
  }
}

ApiFailure _writeFailure(WorkItemStatusWriteFailure failure) {
  final error = failure.failure;
  if (error.kind == FailureKind.cancelled && !failure.mutationSent) {
    return ApiFailure(
      FailureKind.cancelled,
      title: '狀態沒有送出',
      detail: failure.handoff == WorkItemStatusHandoff.started
          ? '變更在送出前停止，GitLab 沒有收到這次變更。'
          : '帳號、工作項目或讀取狀態已改變，這次變更沒有送出。',
    );
  }
  if (error.kind == FailureKind.validation && failure.mutationSent) {
    return ApiFailure(
      error.kind,
      status: error.status,
      retryAt: error.retryAt,
      title: error.title,
      detail: 'GitLab 已回覆錯誤，這次變更已用完，沒有重送。',
    );
  }
  return error;
}

String _statusName(String? name) =>
    name == null || name.trim().isEmpty ? '未命名狀態' : name;

String _assignmentLabel(WorkItemStatusAssignment assignment) =>
    switch (assignment.kind) {
      WorkItemStatusAssignmentKind.unassigned => '未設定',
      WorkItemStatusAssignmentKind.identified => _statusName(
        assignment.record?.name,
      ),
      WorkItemStatusAssignmentKind.unidentified =>
        '識別未知（${_statusName(assignment.record?.name)}）',
    };

String _lifecycleLabel(WorkItemState state) => switch (state) {
  WorkItemState.open => '開啟中',
  WorkItemState.closed => '已關閉',
};

String _resultLabel(WorkItemStatusSaveResult result) {
  final current =
      '${_assignmentLabel(result.snapshot.assignment)} · '
      '${_lifecycleLabel(result.snapshot.state)}';
  return switch (result.status) {
    WorkItemStatusSaveStatus.success => '已確認狀態：$current',
    WorkItemStatusSaveStatus.noop => '狀態未變更：$current',
    WorkItemStatusSaveStatus.notApplied => 'GitLab 未套用這次變更，目前狀態：$current',
  };
}

String _statusResourceLabel(WorkItemGraphSummary summary) {
  final scope =
      summary.project?.fullPath ?? summary.namespace?.fullPath ?? '未知範圍';
  return '$scope · 工作項目 #${summary.iid}';
}

Color _dotColor(String? raw, ColorScheme scheme) {
  if (raw == null || !_hexColor.hasMatch(raw)) return scheme.outline;
  return Color(0xFF000000 | int.parse(raw.substring(1), radix: 16));
}
