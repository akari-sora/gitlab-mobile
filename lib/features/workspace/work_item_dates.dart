import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_dates_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/workspace_ui.dart';

enum WorkItemDatesWritePhase { start, settle }

typedef WorkItemDatesWriteListener =
    void Function(WorkItemDatesWritePhase phase, Object token);

class WorkItemDatesControl extends StatefulWidget {
  const WorkItemDatesControl({
    super.key,
    required this.api,
    required this.account,
    required this.detail,
    required this.generation,
    required this.onSaved,
    this.isCurrent,
    this.onDatesWrite,
    this.ownerChanges,
    this.onRoute,
    this.enabled = true,
  });

  final GitLabApi api;
  final Account account;
  final WorkItemGraphDetail detail;
  final int generation;
  final ValueChanged<WorkItemDatesSnapshot> onSaved;
  final bool Function()? isCurrent;
  final WorkItemDatesWriteListener? onDatesWrite;
  final Listenable? ownerChanges;
  final void Function(Route<dynamic>)? onRoute;
  final bool enabled;

  @override
  State<WorkItemDatesControl> createState() => _WorkItemDatesControlState();
}

class _WorkItemDatesControlState extends State<WorkItemDatesControl> {
  int _epoch = 0;
  int? _openingEpoch;
  Route<void>? _editorRoute;
  NavigatorState? _editorNavigator;
  Object? _writeToken;
  late _DatesOwnerFence _ownerFence;

  bool get _writePending => _writeToken != null;

  bool _current(int epoch) =>
      mounted &&
      epoch == _epoch &&
      _ownerFence.current &&
      identical(widget.api, _ownerFence.api);

  @override
  void initState() {
    super.initState();
    _ownerFence = _DatesOwnerFence(
      api: widget.api,
      currentCheck: widget.isCurrent,
    );
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemDatesControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    if (_bindingChanged(oldWidget)) {
      _ownerFence.invalidate();
      _ownerFence = _DatesOwnerFence(
        api: widget.api,
        currentCheck: widget.isCurrent,
      );
      _invalidate(dismissRoute: true);
      return;
    }
    _ownerFence.currentCheck = widget.isCurrent;
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _epoch++;
    if (!_writePending) _ownerFence.invalidate();
    _dismissRoute();
    super.dispose();
  }

  bool _bindingChanged(WorkItemDatesControl oldWidget) {
    final previous = oldWidget.detail.summary;
    final next = widget.detail.summary;
    return oldWidget.account.key != widget.account.key ||
        oldWidget.generation != widget.generation ||
        !identical(oldWidget.api, widget.api) ||
        previous.id != next.id ||
        previous.iid != next.iid ||
        previous.state != next.state ||
        previous.type.id != next.type.id ||
        previous.type.name != next.type.name ||
        previous.project?.id != next.project?.id ||
        previous.project?.fullPath != next.project?.fullPath ||
        previous.namespace?.id != next.namespace?.id ||
        previous.namespace?.fullPath != next.namespace?.fullPath;
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) {
      if (!_ownerFence.valid && !_writePending) {
        _ownerFence = _DatesOwnerFence(
          api: widget.api,
          currentCheck: widget.isCurrent,
        );
      }
      return;
    }
    _ownerFence.invalidate();
    _invalidate(dismissRoute: true);
  }

  void _invalidate({required bool dismissRoute}) {
    _epoch++;
    _openingEpoch = null;
    if (dismissRoute) _dismissRoute();
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
        _writePending ||
        !_ownerFence.current) {
      return;
    }
    final epoch = _epoch;
    final api = widget.api;
    final account = widget.account;
    final detail = widget.detail;
    final generation = widget.generation;
    final fence = _ownerFence;
    final phaseListener = widget.onDatesWrite;
    setState(() => _openingEpoch = epoch);
    try {
      final access = await api.workItemDates(
        detail,
        expectedUserId: account.user.id,
        generation: generation,
        isCurrent: () => _current(epoch) && identical(fence, _ownerFence),
      );
      if (!_current(epoch) ||
          !identical(fence, _ownerFence) ||
          !context.mounted) {
        return;
      }
      void forwardPhase(WorkItemDatesWritePhase phase, Object token) {
        if (phase == WorkItemDatesWritePhase.start) {
          _writeToken = token;
          if (mounted) setState(() {});
          phaseListener?.call(phase, token);
          return;
        }
        if (identical(_writeToken, token)) {
          _writeToken = null;
          if (mounted) setState(() {});
        }
        phaseListener?.call(phase, token);
      }

      final route = MaterialPageRoute<void>(
        builder: (context) => _WorkItemDatesEditor(
          account: account,
          api: api,
          access: access,
          ownerCurrent: () => fence.current,
          onPhase: forwardPhase,
          onSaved: (snapshot) {
            if (!mounted ||
                epoch != _epoch ||
                !identical(fence, _ownerFence) ||
                !fence.current ||
                !identical(api, widget.api) ||
                account.key != widget.account.key ||
                generation != widget.generation) {
              return;
            }
            widget.onSaved(snapshot);
          },
        ),
      );
      if (!mounted || !_current(epoch) || !identical(fence, _ownerFence)) {
        return;
      }
      final navigator = Navigator.of(context);
      _editorRoute = route;
      _editorNavigator = navigator;
      widget.onRoute?.call(route);
      await navigator.push(route);
      if (mounted && identical(_editorRoute, route)) {
        _editorRoute = null;
        _editorNavigator = null;
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
        !_writePending &&
        _ownerFence.current;
    final label = _writePending
        ? '正在更新日期…'
        : _openingEpoch != null
        ? '讀取日期…'
        : '變更日期';
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: const ValueKey('work-item-dates-edit'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: available ? () => unawaited(_open()) : null,
        child: Text(label),
      ),
    );
  }
}

final class _DatesOwnerFence {
  _DatesOwnerFence({required this.api, required this.currentCheck});

  final GitLabApi api;
  bool Function()? currentCheck;
  bool valid = true;

  bool get current => valid && !api.isClosed && (currentCheck?.call() ?? true);

  void invalidate() => valid = false;
}

class _WorkItemDatesEditor extends StatefulWidget {
  const _WorkItemDatesEditor({
    required this.account,
    required this.api,
    required this.access,
    required this.ownerCurrent,
    required this.onPhase,
    required this.onSaved,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemDatesAccess access;
  final bool Function() ownerCurrent;
  final WorkItemDatesWriteListener onPhase;
  final ValueChanged<WorkItemDatesSnapshot> onSaved;

  @override
  State<_WorkItemDatesEditor> createState() => _WorkItemDatesEditorState();
}

class _WorkItemDatesEditorState extends State<_WorkItemDatesEditor> {
  late final TextEditingController _start;
  late final TextEditingController _due;
  late WorkItemDatesMode _mode;
  bool _writing = false;
  String? _validationError;
  String? _saveFeedback;
  _DatesWriteOperation? _operation;

  WorkItemDatesSnapshot get _snapshot => widget.access.snapshot;

  bool get _manual => _mode == WorkItemDatesMode.manual;

  bool get _canSave =>
      !_writing &&
      widget.ownerCurrent() &&
      widget.access.canWrite &&
      widget.access.target != null &&
      !widget.access.target!.consumed &&
      _mode != WorkItemDatesMode.unknown;

  @override
  void initState() {
    super.initState();
    _mode = _snapshot.mode;
    _start = TextEditingController(text: _snapshot.startDate ?? '');
    _due = TextEditingController(text: _snapshot.dueDate ?? '');
    _start.addListener(_clearValidation);
    _due.addListener(_clearValidation);
  }

  @override
  void dispose() {
    _operation?.disposeRoute();
    _start
      ..removeListener(_clearValidation)
      ..dispose();
    _due
      ..removeListener(_clearValidation)
      ..dispose();
    super.dispose();
  }

  void _clearValidation() {
    if (!mounted || _validationError == null) return;
    setState(() => _validationError = null);
  }

  void _selectMode(WorkItemDatesMode? mode) {
    if (mode == null ||
        !_canSave ||
        _snapshot.edition != WorkItemDatesEdition.ee) {
      return;
    }
    setState(() {
      _mode = mode;
      _validationError = null;
    });
  }

  Future<void> _pickDate(TextEditingController controller) async {
    if (!_canSave || !_manual) return;
    final parsed = _parseCalendarDate(controller.text.trim());
    final selected = await showDatePicker(
      context: context,
      initialDate: parsed ?? DateTime.now(),
      firstDate: DateTime(1000),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!mounted || selected == null || !widget.ownerCurrent()) return;
    controller.text = _formatCalendarDate(selected);
  }

  void _clearDate(TextEditingController controller) {
    if (!_canSave || !_manual) return;
    controller.clear();
  }

  String? _validate() {
    if (_mode == WorkItemDatesMode.unknown) return '日期模式不明';
    if (_mode == WorkItemDatesMode.inherited) return null;
    final start = _nullableDate(_start.text);
    final due = _nullableDate(_due.text);
    if (start.invalid || due.invalid) {
      return '請輸入完整日期，例如 2026-10-04';
    }
    if (start.value != null &&
        due.value != null &&
        start.value!.compareTo(due.value!) > 0) {
      return '開始日期必須早於或等於到期日期';
    }
    return null;
  }

  Future<void> _save() async {
    final target = widget.access.target;
    if (!_canSave || target == null) return;
    final validation = _validate();
    if (validation != null) {
      setState(() => _validationError = validation);
      return;
    }
    final operation = _DatesWriteOperation(
      ownerCurrent: widget.ownerCurrent,
      onPhase: widget.onPhase,
    );
    _operation = operation;
    setState(() {
      _writing = true;
      _validationError = null;
      _saveFeedback = null;
    });
    try {
      final result = await widget.api.updateWorkItemDates(
        target,
        mode: _mode,
        startDate: _mode == WorkItemDatesMode.manual
            ? _emptyToNull(_start.text)
            : null,
        dueDate: _mode == WorkItemDatesMode.manual
            ? _emptyToNull(_due.text)
            : null,
        onMutationSent: operation.start,
        isCurrent: operation.current,
      );
      if (!mounted || !widget.ownerCurrent()) return;
      if (result.outcome == WorkItemDatesWriteOutcome.applied &&
          result.snapshot != null) {
        widget.onSaved(result.snapshot!);
        if (mounted && widget.ownerCurrent()) Navigator.of(context).pop();
        return;
      }
      final feedback =
          result.outcome == WorkItemDatesWriteOutcome.writeUncertain
          ? _unconfirmedFeedback
          : result.message ??
                (result.mutationSent
                    ? '伺服器未套用變更，請確認權限或重新整理'
                    : _notSentFeedback);
      setState(() => _saveFeedback = feedback);
    } catch (error) {
      if (!mounted || !widget.ownerCurrent()) return;
      final failure = safeFailure(error);
      setState(() {
        // onMutationSent runs immediately before the only send, so a failure
        // before START proves nothing was sent.
        _saveFeedback = operation.started
            ? _unconfirmedFeedback
            : failure.kind == FailureKind.writeUncertain
            ? _notSentFeedback
            : failure.detail;
      });
    } finally {
      operation.terminal();
      if (identical(_operation, operation)) _operation = null;
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final blocked = _blockedMessage();
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('編輯日期')),
      body: SafeArea(
        bottom: false,
        child: ListView(
          key: const ValueKey('work-item-dates-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text(
              '@${widget.account.user.username} · ${widget.account.instance.key}',
            ),
            const SizedBox(height: 4),
            Text(_resourceLabel(_snapshot.summary)),
            const SizedBox(height: 16),
            if (_snapshot.edition == WorkItemDatesEdition.ee) ...[
              RadioGroup<WorkItemDatesMode>(
                groupValue: _mode,
                onChanged: (value) {
                  if (_canSave && value != null) _selectMode(value);
                },
                child: Column(
                  children: [
                    RadioListTile<WorkItemDatesMode>(
                      key: const ValueKey('work-item-dates-mode-manual'),
                      contentPadding: EdgeInsets.zero,
                      value: WorkItemDatesMode.manual,
                      enabled: _canSave,
                      title: const Text('手動日期'),
                    ),
                    RadioListTile<WorkItemDatesMode>(
                      key: const ValueKey('work-item-dates-mode-inherited'),
                      contentPadding: EdgeInsets.zero,
                      value: WorkItemDatesMode.inherited,
                      enabled: _canSave,
                      title: const Text('由子項目繼承'),
                    ),
                  ],
                ),
              ),
            ] else if (_snapshot.mode == WorkItemDatesMode.manual) ...[
              const Text('手動日期'),
            ] else ...[
              const Text('日期模式不明'),
            ],
            if (_snapshot.rollUp) ...[
              const SizedBox(height: 8),
              const Text('此類型可以彙整子項目日期'),
            ],
            const SizedBox(height: 16),
            _dateField(
              controller: _start,
              inputKey: const ValueKey('work-item-dates-start-input'),
              pickerKey: const ValueKey('work-item-dates-start-picker'),
              clearKey: const ValueKey('work-item-dates-start-clear'),
              label: '開始日期 YYYY-MM-DD',
              source: _sourceHint(
                _snapshot.startDateSourcingWorkItemId,
                _snapshot.startDateSourcingMilestoneId,
              ),
            ),
            const SizedBox(height: 16),
            _dateField(
              controller: _due,
              inputKey: const ValueKey('work-item-dates-due-input'),
              pickerKey: const ValueKey('work-item-dates-due-picker'),
              clearKey: const ValueKey('work-item-dates-due-clear'),
              label: '到期日期 YYYY-MM-DD',
              source: _sourceHint(
                _snapshot.dueDateSourcingWorkItemId,
                _snapshot.dueDateSourcingMilestoneId,
              ),
            ),
            if (blocked != null) ...[
              const SizedBox(height: 16),
              Text(blocked, key: const ValueKey('work-item-dates-blocked')),
            ],
            if (_validationError != null) ...[
              const SizedBox(height: 16),
              Text(
                _validationError!,
                key: const ValueKey('work-item-dates-validation-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_saveFeedback != null) ...[
              const SizedBox(height: 16),
              Text(
                _saveFeedback!,
                key: const ValueKey('work-item-dates-save-feedback'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
              const Text('請關閉並重新開啟，讀取最新日期後再變更。'),
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
                    key: const ValueKey('work-item-dates-cancel'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('work-item-dates-save'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _canSave ? () => unawaited(_save()) : null,
                    child: Text(_writing ? '正在儲存…' : '儲存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dateField({
    required TextEditingController controller,
    required Key inputKey,
    required Key pickerKey,
    required Key clearKey,
    required String label,
    required String? source,
  }) {
    final editable = _canSave && _manual;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: inputKey,
          controller: controller,
          enabled: editable,
          keyboardType: TextInputType.datetime,
          textInputAction: TextInputAction.next,
          scrollPadding: const EdgeInsets.only(bottom: 112),
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: pickerKey,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: editable
                  ? () => unawaited(_pickDate(controller))
                  : null,
              icon: const Icon(Icons.calendar_today_outlined),
              label: const Text('選擇日期'),
            ),
            TextButton.icon(
              key: clearKey,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: editable ? () => _clearDate(controller) : null,
              icon: const Icon(Icons.clear),
              label: const Text('清除'),
            ),
          ],
        ),
        if (!_manual && source != null) ...[
          const SizedBox(height: 4),
          Text(source),
        ],
      ],
    );
  }

  String? _blockedMessage() {
    if (_snapshot.mode == WorkItemDatesMode.unknown) return '日期模式不明';
    if (!_snapshot.widgetPresent) return '這個工作項目沒有日期欄位';
    if (!widget.access.canWrite || widget.access.target == null) {
      return '目前帳號不能變更日期';
    }
    return null;
  }
}

final class _DatesWriteOperation {
  _DatesWriteOperation({required this.ownerCurrent, required this.onPhase});

  final bool Function() ownerCurrent;
  final WorkItemDatesWriteListener onPhase;
  final Object token = Object();
  bool routeCurrent = true;
  bool started = false;
  bool settled = false;

  bool current() => ownerCurrent() && (started || routeCurrent);

  void start() {
    if (started) return;
    started = true;
    onPhase(WorkItemDatesWritePhase.start, token);
  }

  void disposeRoute() {
    if (!started) routeCurrent = false;
  }

  void terminal() {
    if (!started || settled) return;
    settled = true;
    try {
      onPhase(WorkItemDatesWritePhase.settle, token);
    } on Object {
      // A terminal observer cannot make the completed write nonterminal.
    }
  }
}

const _notSentFeedback = '沒有送出日期變更。';
const _unconfirmedFeedback = '尚未確認日期是否已更新。請重新整理後再查看，不要重複送出同一次變更。';

typedef _ParsedDate = ({DateTime? value, bool invalid});

_ParsedDate _nullableDate(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return (value: null, invalid: false);
  final value = _parseCalendarDate(trimmed);
  return (value: value, invalid: value == null);
}

DateTime? _parseCalendarDate(String raw) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (year < 1000 || year > 9999) return null;
  final value = DateTime.utc(year, month, day);
  if (value.year != year || value.month != month || value.day != day) {
    return null;
  }
  return value;
}

String _formatCalendarDate(DateTime value) {
  final utc = DateTime.utc(value.year, value.month, value.day);
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

String? _emptyToNull(String raw) {
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _sourceHint(String? workItemId, String? milestoneId) {
  final sources = <String>[
    if (workItemId != null) '來源工作項目 ${_gidTail(workItemId)}',
    if (milestoneId != null) '來源里程碑 ${_gidTail(milestoneId)}',
  ];
  return sources.isEmpty ? null : sources.join(' · ');
}

String _gidTail(String id) => id.split('/').last;

String _resourceLabel(WorkItemGraphSummary summary) {
  final scope =
      summary.project?.fullPath ?? summary.namespace?.fullPath ?? '未知範圍';
  return '$scope · 工作項目 #${summary.iid}';
}
