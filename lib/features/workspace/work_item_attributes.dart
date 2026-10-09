import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_attribute_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_milestone_models.dart';
import '../../core/work_item_status_models.dart';
import '../../core/work_item_weight_models.dart';
import '../../shared/workspace_ui.dart';
import 'work_item_milestone.dart';
import 'work_item_status.dart';
import 'work_item_weight.dart';

const _widgetKinds = <String, WorkItemAttributeKind>{
  'STATUS': WorkItemAttributeKind.status,
  'MILESTONE': WorkItemAttributeKind.milestone,
  'WEIGHT': WorkItemAttributeKind.weight,
  'ITERATION': WorkItemAttributeKind.iteration,
  'HEALTH_STATUS': WorkItemAttributeKind.health,
  'TIME_TRACKING': WorkItemAttributeKind.timeTracking,
  'DEVELOPMENT': WorkItemAttributeKind.development,
};

const _kindTitles = <WorkItemAttributeKind, String>{
  WorkItemAttributeKind.status: '狀態',
  WorkItemAttributeKind.milestone: '里程碑',
  WorkItemAttributeKind.weight: '權重',
  WorkItemAttributeKind.iteration: '迭代',
  WorkItemAttributeKind.health: '健康狀態',
  WorkItemAttributeKind.timeTracking: '時間追蹤',
  WorkItemAttributeKind.development: '開發',
};

String workItemAttributeCalendarDate(DateTime value) =>
    '${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')}';

typedef WorkItemAttributeLoader =
    Future<WorkItemAttributeSnapshot> Function(
      WorkItemGraphSummary expected,
      WorkItemAttributeKind kind, {
      bool Function()? isCurrent,
    });

/// Lazily reads the heavier work-item widgets. Expanding starts at most two
/// reads at once; loaded rows remain cached while the section is collapsed.
class WorkItemAttributesPanel extends StatefulWidget {
  const WorkItemAttributesPanel({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    this.isCurrent,
    this.ownerChanges,
    this.loadAttribute,
    this.onRoute,
    this.milestoneWritePending = false,
    this.weightWritePending = false,
    this.onMilestoneWrite,
    this.onWeightWrite,
    this.statusSessionGeneration,
    this.statusWriteHeld = false,
    this.statusConfirmed,
    this.statusUnconfirmed = false,
    this.statusStale = false,
    this.onStatusWrite,
    this.onStatusOutcome,
    this.onStatusSaved,
    this.statusDispatchAllowed,
    this.statusOperationCurrent,
    this.datesWriteHeld = false,
    this.healthWriteHeld = false,
    this.healthStale = false,
    this.healthUnconfirmed = false,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final WorkItemAttributeLoader? loadAttribute;
  final ValueChanged<Route<dynamic>>? onRoute;
  final bool milestoneWritePending;
  final bool weightWritePending;
  final WorkItemMilestoneWriteListener? onMilestoneWrite;
  final WorkItemWeightWriteListener? onWeightWrite;

  /// The session generation captured when the owning route opened. Without
  /// it the STATUS row stays read-only.
  final int? statusSessionGeneration;

  /// The owner holds a STATUS write from START to SETTLE. No STATUS read is
  /// issued or published and the other editors cannot dispatch meanwhile.
  final bool statusWriteHeld;

  /// The owner's confirmed STATUS snapshot for the current revision.
  final WorkItemStatusSnapshot? statusConfirmed;
  final bool statusUnconfirmed;

  /// The detail is older than a confirmed STATUS write on this item: no
  /// STATUS read is issued or published until a newer detail arrives.
  final bool statusStale;
  final WorkItemStatusWriteListener? onStatusWrite;
  final WorkItemStatusWriteOutcome? onStatusOutcome;
  final ValueChanged<WorkItemStatusSaveResult>? onStatusSaved;
  final bool Function()? statusDispatchAllowed;
  final bool Function()? statusOperationCurrent;

  /// The owner holds a Dates write from START to SETTLE; milestone and weight
  /// cannot dispatch meanwhile.
  final bool datesWriteHeld;

  /// The owner holds a Health write from START to SETTLE; milestone and weight
  /// cannot dispatch meanwhile.
  final bool healthWriteHeld;
  final bool healthStale;
  final bool healthUnconfirmed;

  @override
  State<WorkItemAttributesPanel> createState() =>
      _WorkItemAttributesPanelState();
}

class _WorkItemAttributesPanelState extends State<WorkItemAttributesPanel> {
  final Queue<WorkItemAttributeKind> _queue = Queue();
  final Map<WorkItemAttributeKind, WorkItemAttributeSnapshot> _loaded = {};
  final Map<WorkItemAttributeKind, ApiFailure> _errors = {};
  final Set<WorkItemAttributeKind> _loading = {};
  int _epoch = 0;
  int _activeReads = 0;
  int _milestoneSerial = 0;
  Object? _milestoneWriteToken;
  String? _milestoneWriteAccount;
  GitLabApi? _milestoneWriteApi;
  WorkItemGraphSummary? _milestoneWriteSummary;
  WorkItemMilestoneWriteListener? _milestoneWriteListener;
  bool _ignoreMilestoneParentPending = false;
  int _weightSerial = 0;
  Object? _weightWriteToken;
  String? _weightWriteAccount;
  GitLabApi? _weightWriteApi;
  WorkItemGraphSummary? _weightWriteSummary;
  WorkItemWeightWriteListener? _weightWriteListener;
  bool _ignoreWeightParentPending = false;
  int _statusSerial = 0;
  int _healthSerial = 0;
  bool _expanded = false;

  bool get _statusBlocksRead =>
      widget.statusWriteHeld ||
      widget.statusStale ||
      widget.statusConfirmed != null;

  bool get _healthBlocksRead =>
      widget.healthWriteHeld || widget.healthStale || widget.healthUnconfirmed;

  List<WorkItemAttributeKind> get _kinds => [
    for (final kind in WorkItemAttributeKind.values)
      if (widget.detail.widgetTypes.any(
        (type) => _widgetKinds[type.toUpperCase()] == kind,
      ))
        kind,
  ];

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemAttributesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    final identityChanged =
        oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        !_sameWeightResource(oldWidget.detail.summary, widget.detail.summary);
    if (identityChanged) {
      _clearMilestoneWrite();
      _clearWeightWrite();
    }
    final milestoneSettled =
        oldWidget.milestoneWritePending && !widget.milestoneWritePending;
    final weightSettled =
        oldWidget.weightWritePending && !widget.weightWritePending;
    if (milestoneSettled) _ignoreMilestoneParentPending = false;
    if (weightSettled) _ignoreWeightParentPending = false;
    final statusHeldNow = !oldWidget.statusWriteHeld && widget.statusWriteHeld;
    final statusStaleNow = !oldWidget.statusStale && widget.statusStale;
    final statusSettled =
        (oldWidget.statusWriteHeld && !widget.statusWriteHeld) ||
        (oldWidget.statusStale && !widget.statusStale);
    if (statusHeldNow || statusStaleNow) {
      // A value read before another write began is never current again.
      _loaded.remove(WorkItemAttributeKind.status);
      _errors.remove(WorkItemAttributeKind.status);
    }
    if (statusHeldNow || statusStaleNow || widget.statusConfirmed != null) {
      _statusSerial++;
      _queue.removeWhere((kind) => kind == WorkItemAttributeKind.status);
    }
    final healthHeldNow = !oldWidget.healthWriteHeld && widget.healthWriteHeld;
    final healthStaleNow = !oldWidget.healthStale && widget.healthStale;
    final healthUnconfirmedNow =
        !oldWidget.healthUnconfirmed && widget.healthUnconfirmed;
    final healthSettled =
        (oldWidget.healthWriteHeld && !widget.healthWriteHeld) ||
        (oldWidget.healthStale && !widget.healthStale) ||
        (oldWidget.healthUnconfirmed && !widget.healthUnconfirmed);
    if (healthHeldNow || healthStaleNow || healthUnconfirmedNow) {
      _loaded.remove(WorkItemAttributeKind.health);
      _errors.remove(WorkItemAttributeKind.health);
      _healthSerial++;
      _queue.removeWhere((kind) => kind == WorkItemAttributeKind.health);
    }
    if (identityChanged ||
        !identical(oldWidget.loadAttribute, widget.loadAttribute) ||
        !identical(oldWidget.detail, widget.detail)) {
      _reset();
      if (_expanded) _enqueueMissing();
    } else if (_expanded &&
        (milestoneSettled ||
            weightSettled ||
            statusSettled ||
            healthSettled) &&
        (widget.isCurrent?.call() ?? true)) {
      // A panel recreated while another panel's write was pending skipped
      // that row; the parent's settle is the only signal to read it now.
      _enqueueMissing();
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _epoch++;
    _queue.clear();
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _reset();
  }

  void _reset() {
    _epoch++;
    _queue.clear();
    _loaded.clear();
    _errors.clear();
    _loading.clear();
    if (mounted) setState(() {});
  }

  void _enqueueMissing() {
    for (final kind in _kinds) {
      if (kind == WorkItemAttributeKind.milestone &&
          _milestoneWriteBlocksCurrent) {
        continue;
      }
      if (kind == WorkItemAttributeKind.weight && _weightWriteBlocksCurrent) {
        continue;
      }
      if (kind == WorkItemAttributeKind.status && _statusBlocksRead) continue;
      if (kind == WorkItemAttributeKind.health && _healthBlocksRead) continue;
      if (_loaded.containsKey(kind) ||
          _errors.containsKey(kind) ||
          _loading.contains(kind) ||
          _queue.contains(kind)) {
        continue;
      }
      _queue.add(kind);
    }
    _pump();
  }

  void _retry(WorkItemAttributeKind kind) {
    if (kind == WorkItemAttributeKind.milestone &&
        _milestoneWriteBlocksCurrent) {
      return;
    }
    if (kind == WorkItemAttributeKind.weight && _weightWriteBlocksCurrent) {
      return;
    }
    if (kind == WorkItemAttributeKind.status && _statusBlocksRead) return;
    if (kind == WorkItemAttributeKind.health && _healthBlocksRead) return;
    _errors.remove(kind);
    if (!_queue.contains(kind) && !_loading.contains(kind)) {
      _queue.addFirst(kind);
    }
    setState(() {});
    _pump();
  }

  void _pump() {
    while (_activeReads < 2 && _queue.isNotEmpty) {
      final kind = _queue.removeFirst();
      final epoch = _epoch;
      final expected = widget.detail.summary;
      _activeReads++;
      _loading.add(kind);
      unawaited(_read(expected, kind, epoch));
    }
    if (mounted) setState(() {});
  }

  Future<void> _read(
    WorkItemGraphSummary expected,
    WorkItemAttributeKind kind,
    int epoch,
  ) async {
    final milestoneSerial = _milestoneSerial;
    final weightSerial = _weightSerial;
    final statusSerial = _statusSerial;
    final healthSerial = _healthSerial;
    try {
      final load = widget.loadAttribute ?? widget.api.workItemAttribute;
      final snapshot = await load(
        expected,
        kind,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      if (snapshot.kind != kind) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (kind == WorkItemAttributeKind.milestone &&
          (milestoneSerial != _milestoneSerial ||
              _milestoneWriteBlocksCurrent)) {
        return;
      }
      if (kind == WorkItemAttributeKind.weight &&
          (weightSerial != _weightSerial || _weightWriteBlocksCurrent)) {
        return;
      }
      if (kind == WorkItemAttributeKind.status &&
          (statusSerial != _statusSerial || _statusBlocksRead)) {
        return;
      }
      if (kind == WorkItemAttributeKind.health &&
          (healthSerial != _healthSerial || _healthBlocksRead)) {
        return;
      }
      _loaded[kind] = snapshot;
      _errors.remove(kind);
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) _errors[kind] = failure;
    } finally {
      _activeReads--;
      if (_current(epoch)) {
        _loading.remove(kind);
        setState(() {});
      }
      _pump();
    }
  }

  void _applyMilestone(WorkItemMilestoneSnapshot snapshot, int epoch) {
    if (!_current(epoch)) return;
    final expected = widget.detail.summary;
    final actual = snapshot.summary;
    if (actual.id != expected.id ||
        actual.iid != expected.iid ||
        actual.type.id != expected.type.id ||
        actual.project?.id != expected.project?.id ||
        actual.project?.fullPath != expected.project?.fullPath ||
        actual.namespace?.id != expected.namespace?.id ||
        actual.namespace?.fullPath != expected.namespace?.fullPath ||
        snapshot.availability != WorkItemMilestoneAvailability.present) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    _milestoneSerial++;
    setState(() {
      _loaded[WorkItemAttributeKind.milestone] = WorkItemAttributeSnapshot(
        workItemId: actual.id,
        iid: actual.iid,
        project: actual.project,
        namespace: actual.namespace,
        kind: WorkItemAttributeKind.milestone,
        availability: WorkItemAttributeAvailability.present,
        value: WorkItemMilestoneAttribute(milestone: snapshot.milestone),
      );
      _errors.remove(WorkItemAttributeKind.milestone);
    });
  }

  bool get _milestoneWriteBlocksCurrent {
    if (widget.milestoneWritePending && !_ignoreMilestoneParentPending) {
      return true;
    }
    final summary = _milestoneWriteSummary;
    final api = _milestoneWriteApi;
    if (_milestoneWriteToken == null ||
        summary == null ||
        api == null ||
        _milestoneWriteAccount == null) {
      return false;
    }
    return _milestoneWriteAccount == widget.account.key &&
        identical(api, widget.api) &&
        _sameWeightResource(summary, widget.detail.summary) &&
        (widget.isCurrent?.call() ?? true);
  }

  bool _acceptsMilestoneWrite(
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
  ) {
    return mounted &&
        account.key == widget.account.key &&
        identical(api, widget.api) &&
        _sameWeightResource(detail.summary, widget.detail.summary) &&
        (widget.isCurrent?.call() ?? true);
  }

  void _clearMilestoneWrite({bool parentSettled = false}) {
    _milestoneWriteToken = null;
    _milestoneWriteAccount = null;
    _milestoneWriteApi = null;
    _milestoneWriteSummary = null;
    _milestoneWriteListener = null;
    _ignoreMilestoneParentPending = parentSettled;
  }

  void _onMilestoneWrite(
    WorkItemMilestoneWritePhase phase,
    Object token,
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
  ) {
    if (phase == WorkItemMilestoneWritePhase.start) {
      if (!_acceptsMilestoneWrite(account, api, detail)) return;
      _milestoneWriteToken = token;
      _milestoneWriteAccount = account.key;
      _milestoneWriteApi = api;
      _milestoneWriteSummary = detail.summary;
      _milestoneWriteListener = widget.onMilestoneWrite;
      _ignoreMilestoneParentPending = false;
      _milestoneSerial++;
      _queue.removeWhere((kind) => kind == WorkItemAttributeKind.milestone);
      setState(() {});
      _milestoneWriteListener?.call(phase, token, account, api, detail);
      return;
    }
    if (!identical(_milestoneWriteToken, token)) return;
    final listener = _milestoneWriteListener;
    _clearMilestoneWrite(parentSettled: true);
    listener?.call(phase, token, account, api, detail);
    if (!_acceptsMilestoneWrite(account, api, detail)) return;
    _milestoneSerial++;
    _loaded.remove(WorkItemAttributeKind.milestone);
    _errors.remove(WorkItemAttributeKind.milestone);
    _queue.removeWhere((kind) => kind == WorkItemAttributeKind.milestone);
    if (!_expanded || !_kinds.contains(WorkItemAttributeKind.milestone)) {
      setState(() {});
      return;
    }
    if (!_loading.contains(WorkItemAttributeKind.milestone)) {
      _queue.addFirst(WorkItemAttributeKind.milestone);
    } else {
      _queue.add(WorkItemAttributeKind.milestone);
    }
    _pump();
  }

  void _applyWeight(WorkItemWeightSnapshot snapshot, int epoch) {
    if (!_current(epoch)) return;
    final expected = widget.detail.summary;
    final actual = snapshot.summary;
    if (actual.id != expected.id ||
        actual.iid != expected.iid ||
        actual.type.id != expected.type.id ||
        actual.project?.id != expected.project?.id ||
        actual.project?.fullPath != expected.project?.fullPath ||
        actual.namespace?.id != expected.namespace?.id ||
        actual.namespace?.fullPath != expected.namespace?.fullPath ||
        snapshot.availability != WorkItemAttributeAvailability.present ||
        snapshot.value == null) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    _weightSerial++;
    setState(() {
      _loaded[WorkItemAttributeKind.weight] = WorkItemAttributeSnapshot(
        workItemId: actual.id,
        iid: actual.iid,
        project: actual.project,
        namespace: actual.namespace,
        kind: WorkItemAttributeKind.weight,
        availability: snapshot.availability,
        value: snapshot.value,
      );
      _errors.remove(WorkItemAttributeKind.weight);
    });
  }

  bool get _weightWriteBlocksCurrent {
    if (widget.weightWritePending && !_ignoreWeightParentPending) return true;
    final summary = _weightWriteSummary;
    final api = _weightWriteApi;
    if (_weightWriteToken == null ||
        summary == null ||
        api == null ||
        _weightWriteAccount == null) {
      return false;
    }
    return _weightWriteAccount == widget.account.key &&
        identical(api, widget.api) &&
        _sameWeightResource(summary, widget.detail.summary) &&
        (widget.isCurrent?.call() ?? true);
  }

  bool _sameWeightResource(
    WorkItemGraphSummary left,
    WorkItemGraphSummary right,
  ) {
    return left.id == right.id &&
        left.iid == right.iid &&
        left.type.id == right.type.id &&
        left.project?.id == right.project?.id &&
        left.project?.fullPath == right.project?.fullPath &&
        left.namespace?.id == right.namespace?.id &&
        left.namespace?.fullPath == right.namespace?.fullPath;
  }

  bool _acceptsWeightWrite(
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
  ) {
    return mounted &&
        account.key == widget.account.key &&
        identical(api, widget.api) &&
        _sameWeightResource(detail.summary, widget.detail.summary) &&
        (widget.isCurrent?.call() ?? true);
  }

  void _clearWeightWrite({bool parentSettled = false}) {
    _weightWriteToken = null;
    _weightWriteAccount = null;
    _weightWriteApi = null;
    _weightWriteSummary = null;
    _weightWriteListener = null;
    _ignoreWeightParentPending = parentSettled;
  }

  void _onWeightWrite(
    WorkItemWeightWritePhase phase,
    Object token,
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
  ) {
    if (phase == WorkItemWeightWritePhase.start) {
      if (!_acceptsWeightWrite(account, api, detail)) return;
      _weightWriteToken = token;
      _weightWriteAccount = account.key;
      _weightWriteApi = api;
      _weightWriteSummary = detail.summary;
      _weightWriteListener = widget.onWeightWrite;
      _ignoreWeightParentPending = false;
      _weightSerial++;
      setState(() {});
      _weightWriteListener?.call(phase, token, account, api, detail);
      return;
    }
    if (!identical(_weightWriteToken, token)) return;
    final listener = _weightWriteListener;
    _clearWeightWrite(parentSettled: true);
    listener?.call(phase, token, account, api, detail);
    if (!_acceptsWeightWrite(account, api, detail)) return;
    _weightSerial++;
    _loaded.remove(WorkItemAttributeKind.weight);
    _errors.remove(WorkItemAttributeKind.weight);
    _queue.removeWhere((kind) => kind == WorkItemAttributeKind.weight);
    if (!_expanded || !_kinds.contains(WorkItemAttributeKind.weight)) {
      if (mounted) setState(() {});
      return;
    }
    if (!_loading.contains(WorkItemAttributeKind.weight)) {
      _queue.addFirst(WorkItemAttributeKind.weight);
    } else {
      _queue.add(WorkItemAttributeKind.weight);
    }
    _pump();
  }

  Widget? _attributeAction(WorkItemAttributeKind kind, int epoch) {
    final snapshot = _loaded[kind];
    final account = widget.account;
    final api = widget.api;
    final detail = widget.detail;
    bool operationCurrent() =>
        mounted &&
        account.key == widget.account.key &&
        identical(api, widget.api) &&
        _sameWeightResource(detail.summary, widget.detail.summary) &&
        (widget.isCurrent?.call() ?? true);
    final matchingWritePending = switch (kind) {
      WorkItemAttributeKind.milestone => _milestoneWriteBlocksCurrent,
      WorkItemAttributeKind.weight => _weightWriteBlocksCurrent,
      _ => false,
    };
    final weightReadInFlight =
        kind == WorkItemAttributeKind.weight &&
        _loading.contains(kind) &&
        !_errors.containsKey(kind) &&
        (snapshot == null ||
            snapshot.availability == WorkItemAttributeAvailability.present);
    if (!matchingWritePending &&
        !weightReadInFlight &&
        (_loading.contains(kind) ||
            _errors.containsKey(kind) ||
            snapshot?.availability != WorkItemAttributeAvailability.present)) {
      return null;
    }
    return switch (kind) {
      WorkItemAttributeKind.milestone => WorkItemMilestoneControl(
        account: widget.account,
        api: widget.api,
        detail: widget.detail,
        isCurrent: () =>
            _current(epoch) &&
            !widget.statusWriteHeld &&
            !widget.datesWriteHeld &&
            !widget.healthWriteHeld,
        operationCurrent: operationCurrent,
        ownerChanges: widget.ownerChanges,
        onRoute: widget.onRoute,
        writePending: _milestoneWriteBlocksCurrent,
        onMilestoneWrite: _onMilestoneWrite,
        onSaved: (snapshot) => _applyMilestone(snapshot, epoch),
      ),
      WorkItemAttributeKind.weight => WorkItemWeightControl(
        account: widget.account,
        api: widget.api,
        detail: widget.detail,
        isCurrent: () =>
            _current(epoch) &&
            !widget.statusWriteHeld &&
            !widget.datesWriteHeld &&
            !widget.healthWriteHeld,
        operationCurrent: operationCurrent,
        ownerChanges: widget.ownerChanges,
        onRoute: widget.onRoute,
        onWeightWrite: _onWeightWrite,
        writePending: _weightWriteBlocksCurrent,
        onSaved: (snapshot) => _applyWeight(snapshot, epoch),
      ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final kinds = _kinds;
    final epoch = _epoch;
    if (kinds.isEmpty) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('work-item-attributes'),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: Text('屬性', style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text('伺服器提供 ${kinds.length} 個欄位'),
        onExpansionChanged: (expanded) {
          _expanded = expanded;
          if (expanded) _enqueueMissing();
        },
        children: [
          for (final kind in kinds)
            if (kind == WorkItemAttributeKind.status &&
                widget.statusSessionGeneration != null)
              _statusRow(epoch, widget.statusSessionGeneration!)
            else
              _AttributeRow(
                key: ValueKey('work-item-attribute-${kind.name}'),
                title: _kindTitles[kind]!,
                loading: _loading.contains(kind) || _queue.contains(kind),
                snapshot:
                    kind == WorkItemAttributeKind.health && _healthBlocksRead
                    ? null
                    : _loaded[kind],
                error:
                    kind == WorkItemAttributeKind.health && _healthBlocksRead
                    ? null
                    : _errors[kind],
                onRetry: () => _retry(kind),
                action:
                    kind == WorkItemAttributeKind.status && widget.statusStale
                    ? const Text(
                        '尚未確認最新狀態。請重新整理後再查看。',
                        key: ValueKey('work-item-status-field-stale'),
                      )
                    : (kind == WorkItemAttributeKind.health &&
                        _healthBlocksRead)
                    ? (widget.healthWriteHeld
                        ? const Text(
                            '健康狀態更新中：完成前不會重新整理、變更開啟狀態或其他欄位。',
                          )
                        : (widget.healthStale
                            ? const Text(
                                '尚未確認最新健康狀態。請重新整理後再查看。',
                              )
                            : const Text(
                                '尚未確認健康狀態是否已更新。請重新整理後再查看。',
                              )))
                    : _attributeAction(kind, epoch),
              ),
        ],
      ),
    );
  }

  Widget _statusRow(int epoch, int sessionGeneration) {
    const kind = WorkItemAttributeKind.status;
    final ownerDispatch = widget.statusDispatchAllowed;
    return Padding(
      key: const ValueKey('work-item-attribute-status'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _kindTitles[kind]!,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          WorkItemStatusField(
            account: widget.account,
            api: widget.api,
            detail: widget.detail,
            sessionGeneration: sessionGeneration,
            isCurrent: () => _current(epoch),
            ownerChanges: widget.ownerChanges,
            onRoute: widget.onRoute,
            confirmed: widget.statusConfirmed,
            attribute: _loaded[kind],
            loading: _loading.contains(kind) || _queue.contains(kind),
            error: _errors[kind],
            onRetry: () => _retry(kind),
            writeHeld: widget.statusWriteHeld,
            unconfirmed: widget.statusUnconfirmed,
            stale: widget.statusStale,
            onStatusWrite: widget.onStatusWrite,
            onStatusOutcome: widget.onStatusOutcome,
            operationCurrent: widget.statusOperationCurrent,
            dispatchAllowed: () =>
                (ownerDispatch?.call() ?? true) && !_loading.contains(kind),
            onSaved: widget.onStatusSaved ?? (_) {},
          ),
          const Divider(height: 18),
        ],
      ),
    );
  }
}

class _AttributeRow extends StatelessWidget {
  const _AttributeRow({
    super.key,
    required this.title,
    required this.loading,
    required this.snapshot,
    required this.error,
    required this.onRetry,
    this.action,
  });

  final String title;
  final bool loading;
  final WorkItemAttributeSnapshot? snapshot;
  final ApiFailure? error;
  final VoidCallback onRetry;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        if (loading)
          const LinearProgressIndicator(minHeight: 2)
        else if (error != null)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(error!.title),
              TextButton(onPressed: onRetry, child: const Text('重試')),
            ],
          )
        else if (snapshot != null)
          _AttributeValue(snapshot!)
        else
          const Text('等待讀取'),
        ?action,
        const Divider(height: 18),
      ],
    ),
  );
}

class _AttributeValue extends StatelessWidget {
  const _AttributeValue(this.snapshot);

  final WorkItemAttributeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    if (snapshot.availability == WorkItemAttributeAvailability.absent) {
      return const Text('未設定');
    }
    if (snapshot.availability ==
        WorkItemAttributeAvailability.widgetsUnavailable) {
      return const Text('伺服器未回傳 widgets，無法判定');
    }
    final value = snapshot.value;
    return switch (value) {
      WorkItemStatusAttribute() => _status(value),
      WorkItemMilestoneAttribute() => _milestone(value),
      WorkItemWeightAttribute() => _weight(value),
      WorkItemIterationAttribute() => _iteration(value),
      WorkItemHealthAttribute() => _health(value),
      WorkItemTimeTrackingAttribute() => _time(value),
      WorkItemDevelopmentAttribute() => _development(value),
      null => const Text('伺服器未回傳欄位值'),
    };
  }

  Widget _status(WorkItemStatusAttribute value) {
    final status = value.status;
    if (status == null) return const Text('未設定');
    final category = workItemStatusCategoryText(status.category);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        MetaChip(status.name ?? '名稱未知', icon: Icons.flag_outlined),
        if (category != null) MetaChip('分類：$category'),
      ],
    );
  }

  Widget _milestone(WorkItemMilestoneAttribute value) {
    final milestone = value.milestone;
    if (milestone == null) return const Text('未設定');
    final owner = milestone.group ?? milestone.project;
    return _lines([
      milestone.title,
      if (owner != null) '所屬：${owner.fullPath}',
      if (milestone.startDate != null)
        '開始：${workItemAttributeCalendarDate(milestone.startDate!)}',
      if (milestone.dueDate != null)
        '到期：${workItemAttributeCalendarDate(milestone.dueDate!)}',
    ]);
  }

  Widget _weight(WorkItemWeightAttribute value) => _lines([
    '權重：${_number(value.weight)}',
    '彙整權重：${_number(value.rolledUpWeight)}',
    '已完成彙整權重：${_number(value.rolledUpCompletedWeight)}',
  ]);

  Widget _iteration(WorkItemIterationAttribute value) {
    final iteration = value.iteration;
    if (iteration == null) return const Text('未設定');
    return _lines([
      iteration.title ?? '名稱未知',
      '群組：${iteration.group.fullPath}',
      if (iteration.cadence.title != null) '迭代週期：${iteration.cadence.title}',
      if (iteration.startDate != null)
        '開始：${workItemAttributeCalendarDate(iteration.startDate!)}',
      if (iteration.dueDate != null)
        '到期：${workItemAttributeCalendarDate(iteration.dueDate!)}',
    ]);
  }

  Widget _health(WorkItemHealthAttribute value) {
    final rollup = value.rolledUpHealthStatus;
    return _lines([
      '目前：${value.healthStatus == null ? '未設定' : _healthLabel(value.healthStatus!)}',
      if (rollup == null)
        '彙整：未知'
      else if (rollup.isEmpty)
        '彙整：沒有資料'
      else
        '彙整：${rollup.map((item) => '${_healthLabel(item.healthStatus)} ${item.count}').join('、')}',
    ]);
  }

  Widget _time(WorkItemTimeTrackingAttribute value) => _lines([
    '預估：${_duration(value.timeEstimate, value.humanReadable?.timeEstimate)}',
    '已花費：${_duration(value.totalTimeSpent, value.humanReadable?.totalTimeSpent)}',
  ]);

  Widget _development(WorkItemDevelopmentAttribute value) => _lines([
    '可關閉此項目的 Merge Request：${value.closingMergeRequestsCount}',
    '合併時自動關閉：${value.willAutoCloseByMergeRequest ? '是' : '否'}',
  ]);

  String _healthLabel(String status) => switch (status) {
    'onTrack' => '正常',
    'needsAttention' => '需關注',
    'atRisk' => '有風險',
    _ => status,
  };

  String _number(int? value) => value?.toString() ?? '未知';

  String _duration(int? seconds, String? human) {
    if (seconds == null) return '未知';
    if (human != null && human.trim().isNotEmpty) {
      return '$human（$seconds 秒）';
    }
    return '$seconds 秒';
  }

  Widget _lines(List<String> values) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final value in values)
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(value)),
    ],
  );
}
