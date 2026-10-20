import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_health_edit_models.dart';
import '../../shared/workspace_ui.dart';

import '../../l10n/l10n.dart';
/// `start` is emitted only inside the API `onMutationSent` callback; `settle`
/// only after the exact `updateWorkItemHealthStatus` Future has completed.
enum WorkItemHealthWritePhase { start, settle }

/// Status-messaging outcome of one Save attempt. Carries no snapshot: the
/// parent must refresh through its own fresh read.
enum WorkItemHealthSaveOutcome {
  confirmed,
  noop,
  notApplied,
  notSent,
  rejected,
  unknown,
}

typedef WorkItemHealthWriteListener =
    void Function(WorkItemHealthWritePhase phase, Object token);

/// Standalone Health editor entry point.
///
/// The parent owns the write reservation: [reserveWrite] is called
/// synchronously with a fresh opaque token and returns whether the parent
/// accepted it. A token whose write never handed off is returned through
/// [releaseUnsentWrite] exactly once; a handed-off token is returned through
/// [onWritePhase] `settle` exactly once, after the exact update Future
/// completes, even when this control or its editor is already disposed.
/// [isCurrent], [changes], [generation], [account] and [api] are the parent's
/// immutable captured owner binding.
class WorkItemHealthControl extends StatefulWidget {
  const WorkItemHealthControl({
    super.key,
    required this.api,
    required this.account,
    required this.detail,
    required this.generation,
    required this.isCurrent,
    required this.changes,
    required this.enabled,
    required this.reserveWrite,
    required this.releaseUnsentWrite,
    required this.onWritePhase,
    this.onOutcome,
    this.onRoute,
  });

  final GitLabApi api;
  final Account account;
  final WorkItemGraphDetail detail;
  final int generation;
  final bool Function() isCurrent;
  final Listenable changes;
  final bool enabled;
  final bool Function(Object token) reserveWrite;
  final void Function(Object token) releaseUnsentWrite;
  final WorkItemHealthWriteListener onWritePhase;
  final void Function(Object token, WorkItemHealthSaveOutcome outcome)?
  onOutcome;
  final void Function(Route<dynamic>)? onRoute;

  @override
  State<WorkItemHealthControl> createState() => _WorkItemHealthControlState();
}

class _WorkItemHealthControlState extends State<WorkItemHealthControl> {
  int _epoch = 0;
  int? _openingEpoch;
  Route<void>? _editorRoute;
  NavigatorState? _editorNavigator;
  late _HealthOwnerFence _ownerFence;

  bool _current(int epoch) =>
      mounted &&
      epoch == _epoch &&
      _ownerFence.current &&
      identical(widget.api, _ownerFence.api);

  @override
  void initState() {
    super.initState();
    _ownerFence = _HealthOwnerFence(
      api: widget.api,
      currentCheck: widget.isCurrent,
    );
    widget.changes.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemHealthControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.changes, widget.changes)) {
      oldWidget.changes.removeListener(_ownerChanged);
      widget.changes.addListener(_ownerChanged);
    }
    if (_bindingChanged(oldWidget)) {
      _ownerFence.invalidate();
      _ownerFence = _HealthOwnerFence(
        api: widget.api,
        currentCheck: widget.isCurrent,
      );
      _invalidate();
      return;
    }
    _ownerFence.currentCheck = widget.isCurrent;
  }

  @override
  void dispose() {
    widget.changes.removeListener(_ownerChanged);
    _epoch++;
    _ownerFence.invalidate();
    _dismissRoute();
    super.dispose();
  }

  bool _bindingChanged(WorkItemHealthControl oldWidget) {
    final previous = oldWidget.detail.summary;
    final next = widget.detail.summary;
    return oldWidget.account.key != widget.account.key ||
        oldWidget.generation != widget.generation ||
        !identical(oldWidget.api, widget.api) ||
        previous.id != next.id ||
        previous.iid != next.iid ||
        previous.state != next.state ||
        previous.updatedAt != next.updatedAt ||
        previous.type.id != next.type.id ||
        previous.type.name != next.type.name ||
        previous.project?.id != next.project?.id ||
        previous.project?.fullPath != next.project?.fullPath ||
        previous.namespace?.id != next.namespace?.id ||
        previous.namespace?.fullPath != next.namespace?.fullPath;
  }

  void _ownerChanged() {
    if (widget.isCurrent()) {
      if (!_ownerFence.valid) {
        _ownerFence = _HealthOwnerFence(
          api: widget.api,
          currentCheck: widget.isCurrent,
        );
        if (mounted) setState(() {});
      }
      return;
    }
    _ownerFence.invalidate();
    _invalidate();
  }

  void _invalidate() {
    _epoch++;
    _openingEpoch = null;
    _dismissRoute();
    if (mounted) setState(() {});
  }

  void _dismissRoute() {
    final route = _editorRoute;
    final navigator = _editorNavigator;
    _editorRoute = null;
    _editorNavigator = null;
    if (route == null || navigator == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!navigator.mounted || !route.isActive) return;
      navigator.removeRoute(route);
    });
  }

  Future<void> _open() async {
    if (!widget.enabled ||
        _openingEpoch != null ||
        _editorRoute != null ||
        !_ownerFence.current) {
      return;
    }
    final epoch = _epoch;
    final api = widget.api;
    final account = widget.account;
    final detail = widget.detail;
    final generation = widget.generation;
    final fence = _ownerFence;
    final binding = _HealthWriteBinding(
      api: api,
      generation: generation,
      parentCurrent: widget.isCurrent,
      reserve: widget.reserveWrite,
      release: widget.releaseUnsentWrite,
      onPhase: widget.onWritePhase,
      onOutcome: widget.onOutcome,
    );
    setState(() => _openingEpoch = epoch);
    try {
      final access = await api.workItemHealthEdit(
        detail,
        expectedUserId: account.user.id,
        generation: generation,
        isCurrent: () => _current(epoch) && identical(fence, _ownerFence),
      );
      if (!_current(epoch) || !identical(fence, _ownerFence) || !mounted) {
        return;
      }
      final route = MaterialPageRoute<void>(
        builder: (context) => _WorkItemHealthEditor(
          account: account,
          access: access,
          binding: binding,
          controlCurrent: () => fence.current,
        ),
      );
      final navigator = Navigator.of(context);
      _editorRoute = route;
      _editorNavigator = navigator;
      setState(() => _openingEpoch = null);
      widget.onRoute?.call(route);
      await navigator.push(route);
      if (mounted && identical(_editorRoute, route)) {
        setState(() {
          _editorRoute = null;
          _editorNavigator = null;
        });
      }
    } catch (error) {
      if (!_current(epoch) || !identical(fence, _ownerFence)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled && mounted) {
        showFailure(context, failure);
      }
    } finally {
      if (mounted && _openingEpoch == epoch) {
        setState(() => _openingEpoch = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final available =
        widget.enabled &&
        _openingEpoch == null &&
        _editorRoute == null &&
        _ownerFence.current;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: const ValueKey('work-item-health-edit'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: available ? () => unawaited(_open()) : null,
        child: Text(_openingEpoch != null ? l10n.loadingHealthStatus : l10n.changeHealthStatus),
      ),
    );
  }
}

final class _HealthOwnerFence {
  _HealthOwnerFence({required this.api, required this.currentCheck});

  final GitLabApi api;
  bool Function() currentCheck;
  bool valid = true;

  bool get current => valid && !api.isClosed && currentCheck();

  void invalidate() => valid = false;
}

/// Parent binding captured when the editor opens; immune to later rebuilds.
final class _HealthWriteBinding {
  const _HealthWriteBinding({
    required this.api,
    required this.generation,
    required this.parentCurrent,
    required this.reserve,
    required this.release,
    required this.onPhase,
    required this.onOutcome,
  });

  final GitLabApi api;
  final int generation;
  final bool Function() parentCurrent;
  final bool Function(Object token) reserve;
  final void Function(Object token) release;
  final WorkItemHealthWriteListener onPhase;
  final void Function(Object token, WorkItemHealthSaveOutcome outcome)?
  onOutcome;
}

enum _HealthChoice { clear, onTrack, needsAttention, atRisk }

_HealthChoice _choiceFor(WorkItemHealthEditValue? value) => switch (value) {
  null => _HealthChoice.clear,
  WorkItemHealthEditValue.onTrack => _HealthChoice.onTrack,
  WorkItemHealthEditValue.needsAttention => _HealthChoice.needsAttention,
  WorkItemHealthEditValue.atRisk => _HealthChoice.atRisk,
};

WorkItemHealthEditValue? _valueFor(_HealthChoice choice) => switch (choice) {
  _HealthChoice.clear => null,
  _HealthChoice.onTrack => WorkItemHealthEditValue.onTrack,
  _HealthChoice.needsAttention => WorkItemHealthEditValue.needsAttention,
  _HealthChoice.atRisk => WorkItemHealthEditValue.atRisk,
};

String _healthLabel(WorkItemHealthEditValue? value) => switch (value) {
  null => l10n.notSet,
  WorkItemHealthEditValue.onTrack => l10n.healthOnTrack,
  WorkItemHealthEditValue.needsAttention => l10n.healthNeedsAttention,
  WorkItemHealthEditValue.atRisk => l10n.healthAtRisk,
};

IconData _healthIcon(WorkItemHealthEditValue? value) => switch (value) {
  null => Icons.remove_circle_outline,
  WorkItemHealthEditValue.onTrack => Icons.check_circle_outline,
  WorkItemHealthEditValue.needsAttention => Icons.error_outline,
  WorkItemHealthEditValue.atRisk => Icons.warning_amber_outlined,
};

class _WorkItemHealthEditor extends StatefulWidget {
  const _WorkItemHealthEditor({
    required this.account,
    required this.access,
    required this.binding,
    required this.controlCurrent,
  });

  final Account account;
  final WorkItemHealthEditAccess access;
  final _HealthWriteBinding binding;
  final bool Function() controlCurrent;

  @override
  State<_WorkItemHealthEditor> createState() => _WorkItemHealthEditorState();
}

class _WorkItemHealthEditorState extends State<_WorkItemHealthEditor> {
  late _HealthChoice _choice;
  bool _targetUsed = false;
  bool _writing = false;
  String? _feedback;
  bool _feedbackIsError = false;
  WorkItemHealthEditValue? _confirmedValue;
  bool _confirmed = false;
  bool _routeClosed = false;
  ModalRoute<dynamic>? _route;
  _HealthWriteOperation? _operation;

  WorkItemHealthEditSnapshot get _snapshot => widget.access.snapshot;

  bool get _writable => widget.access.canWrite && widget.access.target != null;

  bool get _routeOpen => !_routeClosed && (_route?.isActive ?? false);

  bool get _canSave =>
      !_writing &&
      !_targetUsed &&
      _writable &&
      _routeOpen &&
      widget.controlCurrent() &&
      widget.binding.parentCurrent();

  @override
  void initState() {
    super.initState();
    _choice = _choiceFor(_snapshot.value);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _closeRoute();
    super.dispose();
  }

  void _closeRoute() {
    _routeClosed = true;
    _operation?.disposeRoute();
  }

  void _leave() {
    final route = _route;
    final navigator = route?.navigator;
    if (!_routeOpen || route == null || navigator == null) return;
    _closeRoute();
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  Future<void> _save() async {
    final target = widget.access.target;
    if (!_canSave || target == null || !_routeOpen) return;
    final desired = _valueFor(_choice);
    final binding = widget.binding;
    final operation = _HealthWriteOperation(
      binding: binding,
      controlCurrent: widget.controlCurrent,
    );
    _targetUsed = true;
    if (!operation.reserve()) {
      setState(() {
        _feedback = l10n.healthChangeBlocked;
        _feedbackIsError = true;
      });
      return;
    }
    _operation = operation;
    setState(() {
      _writing = true;
      _feedback = null;
    });
    final report = await operation.run(
      binding.api.updateWorkItemHealthStatus(
        target,
        desired: desired,
        generation: binding.generation,
        isCurrent: () {
          if (!_routeOpen) operation.disposeRoute();
          return operation.current();
        },
        onMutationSent: operation.start,
      ),
    );
    if (identical(_operation, operation)) _operation = null;
    if (!mounted || !_routeOpen) return;
    setState(() {
      _writing = false;
      _confirmed = report.outcome == WorkItemHealthSaveOutcome.confirmed;
      _confirmedValue = report.value;
      _feedback = report.message;
      _feedbackIsError =
          !_confirmed && report.outcome != WorkItemHealthSaveOutcome.noop;
    });
  }

  String? _readOnlyMessage() {
    switch (_snapshot.availability) {
      case WorkItemHealthEditAvailability.widgetsUnavailable:
        return l10n.healthStatusViewOnlyWidgets;
      case WorkItemHealthEditAvailability.absent:
        return l10n.healthStatusFieldMissing;
      case WorkItemHealthEditAvailability.present:
        if (!_writable) return l10n.healthStatusPermissionViewOnly;
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final readOnly = _readOnlyMessage();
    final present =
        _snapshot.availability == WorkItemHealthEditAvailability.present;
    final rollup = _snapshot.rolledUp;
    final error = Theme.of(context).colorScheme.error;
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closeRoute();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(title: Text(l10n.editHealthStatus)),
        body: SafeArea(
          bottom: false,
          child: ListView(
            key: const ValueKey('work-item-health-scroll'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text(
                isolated('@${widget.account.user.username} · ${widget.account.instance.key}'),
              ),
              const SizedBox(height: 4),
              Text(_resourceLabel(_snapshot.summary)),
              const SizedBox(height: 16),
              if (present)
                Row(
                  key: const ValueKey('work-item-health-current'),
                  children: [
                    Icon(_healthIcon(_snapshot.value)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(l10n.healthStatusWhenLoaded(_healthLabel(_snapshot.value))),
                    ),
                  ],
                ),
              if (rollup != null && rollup.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  l10n.childHealthRollup(rollup.map((item) => '${_healthLabel(item.value)} ${item.count}').join(l10n.listSeparator)),
                ),
              ],
              if (readOnly != null) ...[
                const SizedBox(height: 16),
                Text(
                  readOnly,
                  key: const ValueKey('work-item-health-read-only'),
                ),
              ],
              if (present && _writable) ...[
                const SizedBox(height: 16),
                RadioGroup<_HealthChoice>(
                  groupValue: _choice,
                  onChanged: (value) {
                    if (_canSave && value != null) {
                      setState(() => _choice = value);
                    }
                  },
                  child: Column(
                    children: [
                      for (final choice in _HealthChoice.values)
                        RadioListTile<_HealthChoice>(
                          key: ValueKey(
                            'work-item-health-choice-${choice.name}',
                          ),
                          contentPadding: EdgeInsets.zero,
                          value: choice,
                          enabled: _canSave,
                          secondary: Icon(_healthIcon(_valueFor(choice))),
                          title: Text(
                            choice == _HealthChoice.clear
                                ? l10n.clearHealthStatus
                                : _healthLabel(_valueFor(choice)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (_writing) ...[
                const SizedBox(height: 16),
                Row(
                  key: ValueKey('work-item-health-writing'),
                  children: [
                    SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Expanded(child: Text(l10n.updatingHealthStatus)),
                  ],
                ),
              ],
              if (_feedback != null) ...[
                const SizedBox(height: 16),
                Text(
                  _feedback!,
                  key: const ValueKey('work-item-health-feedback'),
                  style: _feedbackIsError ? TextStyle(color: error) : null,
                ),
                if (_confirmed) ...[
                  const SizedBox(height: 4),
                  Row(
                    key: const ValueKey('work-item-health-confirmed'),
                    children: [
                      Icon(_healthIcon(_confirmedValue)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(l10n.healthStatusReadBack(_healthLabel(_confirmedValue))),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Text(l10n.reopenBeforeHealthChange),
              ],
            ],
          ),
        ),
        bottomNavigationBar: Padding(
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('work-item-health-cancel'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _leave,
                      child: Text(_targetUsed ? l10n.closeAction : l10n.cancelAction),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('work-item-health-save'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _canSave ? () => unawaited(_save()) : null,
                      child: Text(_writing ? l10n.savingInProgress : l10n.saveAction),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

typedef _HealthSaveReport = ({
  WorkItemHealthSaveOutcome outcome,
  WorkItemHealthEditValue? value,
  String message,
});

/// Operation-local lifecycle owner. It is reachable from the save
/// continuation only, so editor, control or row disposal cannot drop the
/// terminal forward.
final class _HealthWriteOperation {
  _HealthWriteOperation({required this.binding, required this.controlCurrent});

  final _HealthWriteBinding binding;
  final bool Function() controlCurrent;
  final Object token = Object();
  bool _reserved = false;
  bool _routeCurrent = true;
  bool _started = false;
  bool _released = false;
  bool _terminalForwarded = false;

  bool reserve() {
    bool accepted;
    try {
      accepted = binding.reserve(token);
    } on Object {
      accepted = false;
    }
    _reserved = accepted;
    return accepted;
  }

  bool current() =>
      !binding.api.isClosed &&
      binding.parentCurrent() &&
      (_started || (_routeCurrent && !_released && controlCurrent()));

  void start() {
    if (_started) return;
    if (_released || !_routeCurrent) {
      throw StateError('Health reservation is no longer held');
    }
    _started = true;
    binding.onPhase(WorkItemHealthWritePhase.start, token);
  }

  /// Called from `State.dispose`, where the widget tree is locked: the
  /// pre-handoff fence closes now, but the parent release (which may call
  /// `setState`) is forwarded after the current frame.
  void disposeRoute() {
    if (_started) return;
    _routeCurrent = false;
    if (!_reserved || _released) return;
    scheduleMicrotask(_releaseUnsent);
  }

  void _releaseUnsent() {
    if (!_reserved || _started || _released) return;
    _released = true;
    try {
      binding.release(token);
    } on Object {
      // A release observer cannot make the unsent write sent.
    }
  }

  void _terminal() {
    if (!_started || _terminalForwarded) return;
    _terminalForwarded = true;
    try {
      binding.onPhase(WorkItemHealthWritePhase.settle, token);
    } on Object {
      // A terminal observer cannot make the completed write nonterminal.
    }
  }

  Future<_HealthSaveReport> run(
    Future<WorkItemHealthEditSaveResult> update,
  ) async {
    _HealthSaveReport report;
    try {
      report = _reportFor(await update);
    } on WorkItemHealthEditFailure catch (error) {
      report = _failureReport(error.failure, error.mutationSent);
    } on Object catch (error) {
      report = _failureReport(safeFailure(error), _started);
    } finally {
      if (_started) {
        _terminal();
      } else {
        _releaseUnsent();
      }
    }
    final onOutcome = binding.onOutcome;
    if (onOutcome != null) {
      try {
        onOutcome(token, report.outcome);
      } on Object {
        // Status messaging cannot alter the terminal write.
      }
    }
    return report;
  }

  _HealthSaveReport _reportFor(WorkItemHealthEditSaveResult result) =>
      switch (result.status) {
        WorkItemHealthEditSaveStatus.success => (
          outcome: WorkItemHealthSaveOutcome.confirmed,
          value: result.snapshot.value,
          message: result.snapshot.value == null
              ? l10n.healthStatusClearedConfirmed
              : l10n.healthStatusConfirmed(_healthLabel(result.snapshot.value)),
        ),
        WorkItemHealthEditSaveStatus.noop => (
          outcome: WorkItemHealthSaveOutcome.noop,
          value: result.snapshot.value,
          message: l10n.healthStatusAlreadySet(_healthLabel(result.snapshot.value)),
        ),
        WorkItemHealthEditSaveStatus.notApplied => (
          outcome: WorkItemHealthSaveOutcome.notApplied,
          value: result.snapshot.value,
          message:
              l10n.healthStatusNotApplied(_healthLabel(result.snapshot.value)),
        ),
      };

  _HealthSaveReport _failureReport(ApiFailure failure, bool mutationSent) {
    if (!mutationSent) {
      return (
        outcome: WorkItemHealthSaveOutcome.notSent,
        value: null,
        message: l10n.healthChangeNotSubmitted(failure.detail),
      );
    }
    if (failure.kind == FailureKind.validation) {
      return (
        outcome: WorkItemHealthSaveOutcome.rejected,
        value: null,
        message: l10n.titleThenDetail(failure.title, failure.detail),
      );
    }
    return (
      outcome: WorkItemHealthSaveOutcome.unknown,
      value: null,
      message: l10n.healthUpdateUnconfirmed2,
    );
  }
}

String _resourceLabel(WorkItemGraphSummary summary) {
  final scope =
      summary.project?.fullPath ?? summary.namespace?.fullPath ?? l10n.unknownScope;
  return l10n.workItemScopeLine(scope, summary.iid);
}
