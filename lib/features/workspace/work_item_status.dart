import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_attribute_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_state_models.dart';
import '../../core/work_item_status_models.dart';
import '../../shared/workspace_ui.dart';

import '../../l10n/l10n.dart';
final _hexColor = RegExp(r'^#[0-9A-Fa-f]{6}$');

/// Human label for a known GitLab status category. Unknown, blank and
/// identifier-shaped values return null; a category never implies lifecycle.
String? workItemStatusCategoryLabel(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty || value.startsWith('gid://')) {
    return null;
  }
  return switch (value.toUpperCase()) {
    'TO_DO' => l10n.toDo,
    'IN_PROGRESS' => l10n.inProgress,
    'DONE' => l10n.done2,
    'CANCELED' => l10n.canceled,
    _ => null,
  };
}

/// Category text for display: the known label, otherwise the neutral raw
/// server value (bounded). Blank and identifier-shaped values return null.
String? workItemStatusCategoryText(String? raw) {
  final known = workItemStatusCategoryLabel(raw);
  if (known != null) return known;
  final value = raw?.trim();
  if (value == null || value.isEmpty || value.startsWith('gid://')) {
    return null;
  }
  return value.length <= 40 ? value : '${value.substring(0, 40)}…';
}

/// STATUS mutations between START and SETTLE, per API client and Work Item.
/// Every control and editor consults it, so two pages showing one item never
/// overlap writes. An entry is removed only by the write's own `finally`.
final class WorkItemStatusWriteRegistry extends ChangeNotifier {
  WorkItemStatusWriteRegistry._();

  static final instance = WorkItemStatusWriteRegistry._();

  final _active = Expando<Set<String>>();
  final _terminals = Expando<Map<String, WorkItemStatusTerminal>>();

  bool isActive(GitLabApi api, String workItemId) =>
      _active[api]?.contains(workItemId) ?? false;

  /// The last settled write on this item through this client that sent a
  /// mutation and was not refused. Null when there has been none.
  WorkItemStatusTerminal? terminal(GitLabApi api, String workItemId) =>
      _terminals[api]?[workItemId];

  void _start(GitLabApi api, String workItemId) {
    (_active[api] ??= <String>{}).add(workItemId);
    notifyListeners();
  }

  void _settle(
    GitLabApi api,
    String workItemId,
    WorkItemStatusSaveResult? confirmed, {
    required bool mutationSent,
  }) {
    final earlier = _terminals[api]?[workItemId]?.revision;
    if (confirmed == null && mutationSent) {
      (_terminals[api] ??= {})[workItemId] = WorkItemStatusTerminal._(
        earlier,
        confirmed: false,
      );
    } else if (confirmed != null &&
        confirmed.status != WorkItemStatusSaveStatus.notApplied) {
      final revision = confirmed.snapshot.updatedAt;
      (_terminals[api] ??= {})[workItemId] = WorkItemStatusTerminal._(
        earlier != null && earlier.isAfter(revision) ? earlier : revision,
        confirmed: true,
      );
    }
    if (_active[api]?.remove(workItemId) ?? false) notifyListeners();
  }
}

/// Server revision floor left by settled STATUS writes. [revision] is the
/// newest confirmed `updatedAt`, null if none was confirmed; [confirmed] is
/// false when the last write's outcome is unknown. A detail at the same
/// instant counts as reaching the floor: revisions carry no finer order than
/// the server's timestamp. Each settle is a distinct instance, so a page can
/// tell whether it has already seen it.
final class WorkItemStatusTerminal {
  WorkItemStatusTerminal._(this.revision, {required this.confirmed});

  final DateTime? revision;
  final bool confirmed;
}

/// Delivered once from a started save's `finally`, immediately before SETTLE.
/// [confirmed] is the API's confirmed result; null means the outcome is not
/// confirmed and must be read again, never replayed.
typedef WorkItemStatusWriteOutcome =
    void Function(
      Object token,
      WorkItemStatusSaveResult? confirmed, {
      required bool mutationSent,
    });

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
    this.dispatchAllowed,
    this.onStatusOutcome,
    this.confirmedInValue = false,
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

  /// Owner lock. False while the owner's own reads or other writes are in
  /// flight; checked before the capability read, on Save and in the final
  /// pre-START check.
  final bool Function()? dispatchAllowed;
  final WorkItemStatusWriteOutcome? onStatusOutcome;

  /// The owner shows the confirmed value itself, so a success line would
  /// repeat it.
  final bool confirmedInValue;

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

  bool get _dispatchAllowed =>
      (widget.dispatchAllowed?.call() ?? true) &&
      !WorkItemStatusWriteRegistry.instance.isActive(
        widget.api,
        widget.detail.summary.id,
      );

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
    WorkItemStatusWriteRegistry.instance.addListener(_registryChanged);
  }

  void _registryChanged() {
    if (mounted) setState(() {});
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
    WorkItemStatusWriteRegistry.instance.removeListener(_registryChanged);
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
        !widget.isCurrent() ||
        !_dispatchAllowed) {
      return;
    }
    final epoch = _epoch;
    final account = widget.account;
    final api = widget.api;
    final detail = widget.detail;
    final generation = widget.sessionGeneration;
    final writeListener = widget.onStatusWrite;
    final outcome = widget.onStatusOutcome;
    final operationCurrent = widget.operationCurrent ?? widget.isCurrent;
    final ownerDispatch = widget.dispatchAllowed;
    final workItemId = detail.summary.id;
    bool dispatchAllowed() =>
        (ownerDispatch?.call() ?? true) &&
        !WorkItemStatusWriteRegistry.instance.isActive(api, workItemId);
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
          dispatchAllowed: dispatchAllowed,
          writeListener: writeListener,
          outcome: outcome,
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
            onPressed:
                _opening ||
                    _writePending ||
                    !widget.isCurrent() ||
                    !_dispatchAllowed
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
                  ? l10n.changingInProgress
                  : _opening
                  ? l10n.loadingStatusPermission
                  : l10n.changeStatus,
            ),
          ),
        ),
        if (result != null && !widget.confirmedInValue)
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
    required this.outcome,
    required this.onStarted,
    required this.onSettled,
  });

  final Object token = Object();
  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final int sessionGeneration;
  final WorkItemStatusWriteListener? listener;
  final WorkItemStatusWriteOutcome? outcome;
  final ValueChanged<Object> onStarted;
  final ValueChanged<Object> onSettled;
  var _started = false;
  var _settled = false;
  var _registered = false;

  /// Set only from a returned API result. Anything else after START is
  /// reported as unconfirmed.
  WorkItemStatusSaveResult? confirmed;
  var mutationSent = true;

  bool get started => _started;

  void start() {
    if (_started) return;
    _started = true;
    WorkItemStatusWriteRegistry.instance._start(api, detail.summary.id);
    _registered = true;
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
      if (_registered) {
        WorkItemStatusWriteRegistry.instance._settle(
          api,
          detail.summary.id,
          confirmed,
          mutationSent: mutationSent,
        );
      }
    } finally {
      try {
        outcome?.call(token, confirmed, mutationSent: mutationSent);
      } finally {
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
    required this.dispatchAllowed,
    required this.writeListener,
    required this.outcome,
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
  final bool Function() dispatchAllowed;
  final WorkItemStatusWriteListener? writeListener;
  final WorkItemStatusWriteOutcome? outcome;
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
    final dispatchAllowed = widget.dispatchAllowed;
    if (!dispatchAllowed()) {
      // The target stays unused, so Save can be pressed again later.
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(l10n.workItemBusySaveLater)));
      return;
    }
    final api = widget.api;
    final isCurrent = widget.isCurrent;
    final operationCurrent = widget.operationCurrent;
    final write = _StatusWrite(
      account: widget.account,
      api: api,
      detail: widget.detail,
      sessionGeneration: widget.sessionGeneration,
      listener: widget.writeListener,
      outcome: widget.outcome,
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
        isCurrent: () => write.started
            ? operationCurrent()
            : mounted && isCurrent() && dispatchAllowed(),
        onMutationSent: (started) {
          started(write.token);
          write.start();
        },
      );
      write.confirmed = result;
      if (!mounted || !widget.isCurrent()) return;
      Navigator.of(context).pop(result);
    } on WorkItemStatusWriteFailure catch (failure) {
      write.mutationSent = failure.mutationSent;
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
      appBar: AppBar(title: Text(l10n.changeStatus)),
      body: CustomScrollView(
        key: const ValueKey('work-item-status-scroll'),
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverList.list(
              children: [
                Text(
                  isolated('@${widget.account.user.username} · ${widget.account.instance.key}'),
                ),
                const SizedBox(height: 4),
                Text(_statusResourceLabel(widget.detail.summary)),
                const SizedBox(height: 4),
                Text(widget.detail.summary.title),
                const SizedBox(height: 12),
                Text(l10n.currentLifecycle(_lifecycleLabel(snapshot.state))),
                const SizedBox(height: 4),
                Text(l10n.currentStatusAssignment(_assignmentLabel(snapshot.assignment))),
                if (blocked != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    blocked,
                    key: const ValueKey('work-item-status-capability'),
                  ),
                ],
                if (_saveAttempted && error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.reopenBeforeChange,
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
                        Expanded(
                          child: Text(
                            l10n.statusMayCloseOrReopen,
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
                      : Text(l10n.saveAction),
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
    final label = isAssigned ? l10n.statusNameCurrent(name) : name;
    final category =
        l10n.statusCategoryValue(workItemStatusCategoryText(status.category) ?? l10n.notProvided);
    final description = status.description;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey('work-item-status-choice-$id'),
      excludeSemantics: true,
      label: l10n.statusLabelCategory(label, category),
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
      return l10n.statusMissingServerId;
    }
    if (!widget.access.canWrite || widget.access.target == null) {
      return l10n.statusPermissionDenied;
    }
    return l10n.noSelectableStatuses;
  }

  String? _pendingLabel() {
    final id = _selected;
    if (!_editable || id == null) return null;
    final assignment = _snapshot.assignment;
    if (assignment.kind == WorkItemStatusAssignmentKind.identified &&
        assignment.id == id) {
      return l10n.statusAlreadyCurrent;
    }
    final record = _snapshot.allowedStatuses.firstWhere(
      (status) => status.id == id,
    );
    return l10n.statusWillApply(_statusName(record.name));
  }
}

ApiFailure _writeFailure(WorkItemStatusWriteFailure failure) {
  final error = failure.failure;
  if (error.kind == FailureKind.cancelled && !failure.mutationSent) {
    return ApiFailure(
      FailureKind.cancelled,
      title: l10n.statusNotSubmitted,
      detail: failure.handoff == WorkItemStatusHandoff.started
          ? l10n.statusChangeStopped
          : l10n.statusContextChanged,
    );
  }
  if (error.kind == FailureKind.validation && failure.mutationSent) {
    return ApiFailure(
      error.kind,
      status: error.status,
      retryAt: error.retryAt,
      title: error.title,
      detail: l10n.statusChangeErrorConsumed,
    );
  }
  return error;
}

String _statusName(String? name) =>
    name == null || name.trim().isEmpty ? l10n.unnamedStatus : name;

String _assignmentLabel(WorkItemStatusAssignment assignment) =>
    switch (assignment.kind) {
      WorkItemStatusAssignmentKind.unassigned => l10n.notSet,
      WorkItemStatusAssignmentKind.identified => _statusName(
        assignment.record?.name,
      ),
      WorkItemStatusAssignmentKind.unidentified =>
        l10n.unknownStatusIdentifier(_statusName(assignment.record?.name)),
    };

String _lifecycleLabel(WorkItemState state) => switch (state) {
  WorkItemState.open => l10n.statusOpen,
  WorkItemState.closed => l10n.statusClosed,
};

String _resultLabel(WorkItemStatusSaveResult result) {
  final current =
      '${_assignmentLabel(result.snapshot.assignment)} · '
      '${_lifecycleLabel(result.snapshot.state)}';
  return switch (result.status) {
    WorkItemStatusSaveStatus.success => l10n.confirmedStatus(current),
    WorkItemStatusSaveStatus.noop => l10n.statusUnchanged(current),
    WorkItemStatusSaveStatus.notApplied => l10n.statusChangeNotApplied(current),
  };
}

String _statusResourceLabel(WorkItemGraphSummary summary) {
  final scope =
      summary.project?.fullPath ?? summary.namespace?.fullPath ?? l10n.unknownScope;
  return l10n.workItemScopeLine(scope, summary.iid);
}

Color _dotColor(String? raw, ColorScheme scheme) {
  if (raw == null || !_hexColor.hasMatch(raw)) return scheme.outline;
  return Color(0xFF000000 | int.parse(raw.substring(1), radix: 16));
}

/// The STATUS attribute row: the confirmed STATUS snapshot when the owner has
/// one for the current revision, otherwise the attribute read, plus the
/// editor entry. The owner decides when reads may run and holds the write.
class WorkItemStatusField extends StatelessWidget {
  const WorkItemStatusField({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    required this.sessionGeneration,
    required this.isCurrent,
    required this.onSaved,
    this.confirmed,
    this.attribute,
    this.loading = false,
    this.error,
    this.onRetry,
    this.writeHeld = false,
    this.unconfirmed = false,
    this.stale = false,
    this.ownerChanges,
    this.onRoute,
    this.onStatusWrite,
    this.onStatusOutcome,
    this.operationCurrent,
    this.dispatchAllowed,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final int sessionGeneration;
  final bool Function() isCurrent;
  final ValueChanged<WorkItemStatusSaveResult> onSaved;
  final WorkItemStatusSnapshot? confirmed;
  final WorkItemAttributeSnapshot? attribute;
  final bool loading;
  final ApiFailure? error;
  final VoidCallback? onRetry;
  final bool writeHeld;
  final bool unconfirmed;

  /// The detail on screen is older than a confirmed STATUS write on this
  /// item, so no STATUS value is current.
  final bool stale;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;
  final WorkItemStatusWriteListener? onStatusWrite;
  final WorkItemStatusWriteOutcome? onStatusOutcome;
  final bool Function()? operationCurrent;
  final bool Function()? dispatchAllowed;

  @override
  Widget build(BuildContext context) {
    final failure = error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (writeHeld)
          Row(
            key: ValueKey('work-item-status-field-pending'),
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Flexible(child: Text(l10n.updatingStatusNoReload)),
            ],
          )
        else if (stale && confirmed == null)
          Text(
            l10n.latestStateUnconfirmed,
            key: ValueKey('work-item-status-field-stale'),
          )
        else if (confirmed == null && loading)
          const LinearProgressIndicator(minHeight: 2)
        else if (confirmed == null && failure != null)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(failure.title),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: Text(l10n.retryAction)),
            ],
          )
        else
          KeyedSubtree(
            key: const ValueKey('work-item-status-field-value'),
            child: _value(context),
          ),
        if (unconfirmed && !writeHeld)
          Padding(
            key: ValueKey('work-item-status-field-unconfirmed'),
            padding: EdgeInsets.only(top: 4),
            child: Text(l10n.statusResultReloaded),
          ),
        WorkItemStatusControl(
          account: account,
          api: api,
          detail: detail,
          sessionGeneration: sessionGeneration,
          onSaved: onSaved,
          isCurrent: isCurrent,
          ownerChanges: ownerChanges,
          onRoute: onRoute,
          onStatusWrite: onStatusWrite,
          onStatusOutcome: onStatusOutcome,
          writePending: writeHeld,
          operationCurrent: operationCurrent,
          dispatchAllowed: dispatchAllowed,
          confirmedInValue: true,
        ),
      ],
    );
  }

  Widget _value(BuildContext context) {
    final String label;
    final String? category;
    final String? color;
    final confirmed = this.confirmed;
    if (confirmed != null) {
      final assignment = confirmed.assignment;
      if (assignment.kind == WorkItemStatusAssignmentKind.unassigned) {
        return Text(l10n.notSet);
      }
      label = _assignmentLabel(assignment);
      category = assignment.record?.category;
      color = assignment.record?.color;
    } else {
      final snapshot = attribute;
      if (snapshot == null) return Text(l10n.waitingToLoad);
      if (snapshot.availability == WorkItemAttributeAvailability.absent) {
        return Text(l10n.notSet);
      }
      if (snapshot.availability ==
          WorkItemAttributeAvailability.widgetsUnavailable) {
        return Text(l10n.widgetsMissing);
      }
      final value = snapshot.value;
      if (value is! WorkItemStatusAttribute) {
        return Text(l10n.fieldValueMissing);
      }
      final status = value.status;
      if (status == null) return Text(l10n.notSet);
      final name = status.name?.trim();
      label = name == null || name.isEmpty ? l10n.unknownName : name;
      category = status.category;
      color = status.color;
    }
    final categoryLabel = workItemStatusCategoryText(category);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(
          Icons.circle,
          size: 10,
          color: _dotColor(color, Theme.of(context).colorScheme),
        ),
        MetaChip(label, icon: Icons.flag_outlined),
        if (categoryLabel != null) MetaChip(l10n.statusCategoryLabel(categoryLabel)),
      ],
    );
  }
}
