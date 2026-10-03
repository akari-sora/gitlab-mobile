import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_attribute_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_milestone_models.dart';
import '../../shared/workspace_ui.dart';
import 'work_item_milestone.dart';

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
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final WorkItemAttributeLoader? loadAttribute;
  final ValueChanged<Route<dynamic>>? onRoute;

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
  bool _expanded = false;

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
    final oldSummary = oldWidget.detail.summary;
    final summary = widget.detail.summary;
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldSummary.id != summary.id ||
        oldSummary.iid != summary.iid ||
        oldSummary.project?.id != summary.project?.id ||
        oldSummary.project?.fullPath != summary.project?.fullPath ||
        oldSummary.namespace?.id != summary.namespace?.id ||
        oldSummary.namespace?.fullPath != summary.namespace?.fullPath ||
        !identical(oldWidget.loadAttribute, widget.loadAttribute) ||
        !identical(oldWidget.detail, widget.detail)) {
      _reset();
      if (_expanded) _enqueueMissing();
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
            _AttributeRow(
              key: ValueKey('work-item-attribute-${kind.name}'),
              title: _kindTitles[kind]!,
              loading: _loading.contains(kind) || _queue.contains(kind),
              snapshot: _loaded[kind],
              error: _errors[kind],
              onRetry: () => _retry(kind),
              action:
                  kind == WorkItemAttributeKind.milestone &&
                      !_loading.contains(kind) &&
                      !_errors.containsKey(kind) &&
                      _loaded[kind]?.availability ==
                          WorkItemAttributeAvailability.present
                  ? WorkItemMilestoneControl(
                      account: widget.account,
                      api: widget.api,
                      detail: widget.detail,
                      isCurrent: () => _current(epoch),
                      ownerChanges: widget.ownerChanges,
                      onRoute: widget.onRoute,
                      onSaved: (snapshot) => _applyMilestone(snapshot, epoch),
                    )
                  : null,
            ),
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
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        MetaChip(status.name ?? '名稱未知', icon: Icons.flag_outlined),
        if (status.category != null) MetaChip(status.category!),
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
