import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_state_models.dart';

typedef WorkItemStateLoader =
    Future<WorkItemStateSnapshot> Function(
      WorkItemGraphSummary expected, {
      bool Function()? isCurrent,
    });

typedef WorkItemStateUpdater =
    Future<WorkItemStateSnapshot> Function(
      WorkItemGraphSummary expected,
      WorkItemStateEvent event, {
      required DateTime expectedUpdatedAt,
      bool Function()? isCurrent,
    });

typedef WorkItemStateConfirmer =
    Future<bool> Function(
      BuildContext context,
      WorkItemStateSnapshot current,
      WorkItemStateEvent event,
    );

class WorkItemStateControl extends StatefulWidget {
  const WorkItemStateControl({
    super.key,
    required this.account,
    required this.api,
    required this.summary,
    this.isCurrent,
    this.ownerChanges,
    this.onChanged,
    this.loadState,
    this.updateState,
    this.confirmChange,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphSummary summary;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final Future<void> Function(WorkItemStateSnapshot state)? onChanged;
  final WorkItemStateLoader? loadState;
  final WorkItemStateUpdater? updateState;
  final WorkItemStateConfirmer? confirmChange;

  @override
  State<WorkItemStateControl> createState() => _WorkItemStateControlState();
}

class _WorkItemStateControlState extends State<WorkItemStateControl> {
  WorkItemStateSnapshot? _snapshot;
  ApiFailure? _error;
  bool _loading = false;
  bool _confirming = false;
  bool _writing = false;
  bool _uncertain = false;
  int _epoch = 0;
  DialogRoute<bool>? _confirmationRoute;

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
    unawaited(_read());
  }

  @override
  void didUpdateWidget(covariant WorkItemStateControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    final old = oldWidget.summary;
    final next = widget.summary;
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        old.id != next.id ||
        old.iid != next.iid ||
        old.state != next.state ||
        old.updatedAt != next.updatedAt ||
        old.project?.id != next.project?.id ||
        old.project?.fullPath != next.project?.fullPath ||
        old.namespace?.id != next.namespace?.id ||
        old.namespace?.fullPath != next.namespace?.fullPath ||
        old.type.id != next.type.id ||
        !identical(oldWidget.loadState, widget.loadState) ||
        !identical(oldWidget.updateState, widget.updateState)) {
      _invalidate();
      unawaited(_read());
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _epoch++;
    _dismissConfirmation();
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _invalidate();
  }

  void _invalidate() {
    _epoch++;
    _dismissConfirmation();
    _snapshot = null;
    _error = null;
    _loading = false;
    _confirming = false;
    _writing = false;
    _uncertain = false;
    if (mounted) setState(() {});
  }

  void _dismissConfirmation() {
    final route = _confirmationRoute;
    _confirmationRoute = null;
    if (route == null || !route.isActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) {
        route.navigator?.removeRoute(route);
      }
    });
  }

  WorkItemGraphSummary _expectedFor(WorkItemStateSnapshot snapshot) =>
      WorkItemGraphSummary(
        id: widget.summary.id,
        iid: widget.summary.iid,
        title: widget.summary.title,
        state: snapshot.state == WorkItemState.open ? 'OPEN' : 'CLOSED',
        createdAt: widget.summary.createdAt,
        updatedAt: snapshot.updatedAt,
        project: widget.summary.project,
        namespace: widget.summary.namespace,
        type: widget.summary.type,
      );

  Future<void> _read() async {
    if (_loading || _writing || !(widget.isCurrent?.call() ?? true)) return;
    final epoch = _epoch;
    final expected = widget.summary;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final load = widget.loadState ?? widget.api.workItemState;
      final result = await load(expected, isCurrent: () => _current(epoch));
      if (!_current(epoch)) return;
      setState(() {
        _snapshot = result;
        _uncertain = false;
      });
      final resultState = result.state == WorkItemState.open
          ? 'OPEN'
          : 'CLOSED';
      if ((resultState != expected.state ||
              !result.updatedAt.isAtSameMomentAs(expected.updatedAt)) &&
          _current(epoch)) {
        await widget.onChanged?.call(result);
      }
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() {
          _snapshot = null;
          _error = failure;
        });
      }
    } finally {
      if (_current(epoch)) setState(() => _loading = false);
    }
  }

  Future<void> _change(WorkItemStateEvent event) async {
    final current = _snapshot;
    if (!(widget.isCurrent?.call() ?? true) ||
        _confirming ||
        _writing ||
        _loading ||
        _uncertain ||
        current?.canUpdate != true) {
      return;
    }
    final epoch = _epoch;
    final confirm = widget.confirmChange ?? _confirmDefault;
    setState(() => _confirming = true);
    bool accepted;
    try {
      accepted = await confirm(context, current!, event);
    } finally {
      if (_current(epoch)) setState(() => _confirming = false);
    }
    if (!_current(epoch) || !accepted || _writing) return;
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      final update = widget.updateState ?? widget.api.updateWorkItemState;
      final result = await update(
        _expectedFor(current),
        event,
        expectedUpdatedAt: current.updatedAt,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      setState(() => _snapshot = result);
      await widget.onChanged?.call(result);
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      if (failure.kind == FailureKind.cancelled) return;
      setState(() {
        _error = failure;
        if (failure.kind == FailureKind.writeUncertain) {
          _uncertain = true;
          _snapshot = null;
        }
      });
    } finally {
      if (_current(epoch)) setState(() => _writing = false);
    }
  }

  Future<bool> _confirmDefault(
    BuildContext context,
    WorkItemStateSnapshot _,
    WorkItemStateEvent event,
  ) async {
    final route = DialogRoute<bool>(
      context: context,
      builder: (dialogContext) => _confirmationDialog(dialogContext, event),
    );
    _confirmationRoute = route;
    final result = await Navigator.of(context).push(route);
    if (identical(_confirmationRoute, route)) {
      _confirmationRoute = null;
    }
    return result == true;
  }

  Widget _confirmationDialog(BuildContext context, WorkItemStateEvent event) {
    final closing = event == WorkItemStateEvent.close;
    final location =
        widget.summary.namespace?.fullPath ??
        widget.summary.project?.fullPath ??
        '位置未知';
    return AlertDialog(
      scrollable: true,
      title: Text(closing ? '關閉工作項目？' : '重新開啟工作項目？'),
      content: Text(
        '@${widget.account.user.username} · ${widget.account.instance.key}\n'
        '$location · #${widget.summary.iid}\n\n'
        '${closing ? '關閉' : '重新開啟'}「${widget.summary.title}」？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(closing ? '確認關閉' : '確認重開'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final event = snapshot?.state == WorkItemState.closed
        ? WorkItemStateEvent.reopen
        : WorkItemStateEvent.close;
    final buttonLabel = event == WorkItemStateEvent.close ? '關閉工作項目' : '重新開啟';
    return Card(
      key: const ValueKey('work-item-state-control'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('工作項目狀態', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_loading)
              const Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Expanded(child: Text('確認最新狀態與更新權限…')),
                ],
              )
            else if (_error != null) ...[
              Text(_uncertain ? '操作結果尚未確認，已停用再次寫入。' : _error!.title),
              const SizedBox(height: 4),
              Text(
                _uncertain ? '請先重新讀取伺服器狀態，再決定是否重試。' : _error!.detail,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _writing ? null : _read,
                icon: const Icon(Icons.refresh),
                label: const Text('重新讀取狀態'),
              ),
            ] else if (snapshot != null) ...[
              Text(snapshot.state == WorkItemState.open ? '目前為開啟' : '目前為已關閉'),
              const SizedBox(height: 8),
              if (!snapshot.canUpdate)
                const Text('目前帳號沒有更新這個工作項目的權限。')
              else
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _confirming || _writing
                        ? null
                        : () => unawaited(_change(event)),
                    icon: _writing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            event == WorkItemStateEvent.close
                                ? Icons.check_circle_outline
                                : Icons.replay,
                          ),
                    label: Text(
                      _writing
                          ? '更新中…'
                          : _confirming
                          ? '等待確認…'
                          : buttonLabel,
                    ),
                  ),
                ),
            ] else
              OutlinedButton.icon(
                onPressed: _read,
                icon: const Icon(Icons.refresh),
                label: const Text('讀取狀態'),
              ),
          ],
        ),
      ),
    );
  }
}
