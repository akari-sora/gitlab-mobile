import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_attribute_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_milestone_models.dart';
import '../../shared/workspace_ui.dart';

enum WorkItemMilestoneWritePhase { start, settle }

typedef WorkItemMilestoneWriteListener =
    void Function(
      WorkItemMilestoneWritePhase phase,
      Object token,
      Account account,
      GitLabApi api,
      WorkItemGraphDetail detail,
    );

/// Editing is requested from the existing lazy attribute row. Displayed
/// attribute data is never used as permission or as a writable target.
class WorkItemMilestoneControl extends StatefulWidget {
  const WorkItemMilestoneControl({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    required this.onSaved,
    this.isCurrent,
    this.ownerChanges,
    this.onRoute,
    this.onMilestoneWrite,
    this.writePending = false,
    this.operationCurrent,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final ValueChanged<WorkItemMilestoneSnapshot> onSaved;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;
  final WorkItemMilestoneWriteListener? onMilestoneWrite;
  final bool writePending;
  final bool Function()? operationCurrent;

  @override
  State<WorkItemMilestoneControl> createState() =>
      _WorkItemMilestoneControlState();
}

class _WorkItemMilestoneControlState extends State<WorkItemMilestoneControl> {
  int _epoch = 0;
  bool _opening = false;
  ApiFailure? _error;
  Route<WorkItemMilestoneSnapshot>? _route;
  NavigatorState? _navigator;
  Object? _writeToken;
  Account? _writeAccount;
  GitLabApi? _writeApi;
  WorkItemGraphDetail? _writeDetail;
  WorkItemMilestoneWriteListener? _writeListener;

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);
  bool get _writePending => widget.writePending || _writeToken != null;

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemMilestoneControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    final old = oldWidget.detail.summary;
    final next = widget.detail.summary;
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        old.id != next.id ||
        old.iid != next.iid ||
        old.project?.id != next.project?.id ||
        old.project?.fullPath != next.project?.fullPath ||
        old.namespace?.id != next.namespace?.id ||
        old.namespace?.fullPath != next.namespace?.fullPath ||
        old.type.id != next.type.id ||
        old.updatedAt != next.updatedAt) {
      _invalidate();
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _epoch++;
    _dismissRoute();
    super.dispose();
  }

  void _noteMilestoneWriteStarted(Object token) {
    _writeToken = token;
    final account = widget.account;
    final api = widget.api;
    final detail = widget.detail;
    _writeAccount = account;
    _writeApi = api;
    _writeDetail = detail;
    _writeListener = widget.onMilestoneWrite;
    _writeListener?.call(
      WorkItemMilestoneWritePhase.start,
      token,
      account,
      api,
      detail,
    );
  }

  void _noteMilestoneWriteSettled(Object token) {
    if (!identical(_writeToken, token)) return;
    final account = _writeAccount;
    final api = _writeApi;
    final detail = _writeDetail;
    final listener = _writeListener;
    _writeToken = null;
    _writeAccount = null;
    _writeApi = null;
    _writeDetail = null;
    _writeListener = null;
    if (account == null || api == null || detail == null) return;
    try {
      listener?.call(
        WorkItemMilestoneWritePhase.settle,
        token,
        account,
        api,
        detail,
      );
    } finally {
      if (mounted) setState(() {});
    }
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
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

  void _invalidate() {
    _epoch++;
    _opening = false;
    _error = null;
    _dismissRoute();
    if (mounted) setState(() {});
  }

  String get _resourceLabel => _milestoneResourceLabel(widget.detail.summary);

  Future<void> _open() async {
    if (_opening ||
        _writePending ||
        !(widget.isCurrent?.call() ?? true)) {
      return;
    }
    final epoch = _epoch;
    final operationCurrent = widget.operationCurrent ?? widget.isCurrent;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final access = await widget.api.workItemMilestone(
        widget.detail,
        expectedUserId: widget.account.user.id,
        isCurrent: () => _current(epoch),
      );
      if (!mounted || !_current(epoch)) return;
      final navigator = Navigator.of(context);
      final writeToken = Object();
      final route = MaterialPageRoute<WorkItemMilestoneSnapshot>(
        builder: (_) => WorkItemMilestonePicker(
          account: widget.account,
          api: widget.api,
          access: access,
          isCurrent: () => _current(epoch),
          operationCurrent: () => operationCurrent?.call() ?? true,
          onWriteStarted: () => _noteMilestoneWriteStarted(writeToken),
          onWriteSettled: () => _noteMilestoneWriteSettled(writeToken),
        ),
      );
      _navigator = navigator;
      _route = route;
      widget.onRoute?.call(route);
      final saved = await navigator.push(route);
      if (identical(_route, route)) _route = null;
      if (!_current(epoch) || saved == null) return;
      widget.onSaved(saved);
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _error = failure);
      }
    } finally {
      if (_current(epoch)) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(
        key: const ValueKey('work-item-milestone-edit'),
        onPressed:
            _opening ||
                _writePending ||
                !(widget.isCurrent?.call() ?? true)
            ? null
            : _open,
        icon: _opening
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.edit_outlined, size: 18),
        label: Text(
          _writePending
              ? '變更中…'
              : _opening
              ? '讀取里程碑權限…'
              : '變更里程碑',
        ),
      ),
      if (_error != null)
        FailureNotice(
          _error!,
          account: widget.account,
          resourceLabel: _resourceLabel,
          onRetry: _open,
        ),
    ],
  );
}

String _milestoneResourceLabel(WorkItemGraphSummary summary) =>
    '${summary.project?.fullPath ?? summary.namespace?.fullPath ?? '位置未知'}'
    ' · 工作項目 #${summary.iid}';

/// A staged selection with an explicit save. Failed candidate reads do not
/// prevent clearing the current assignment; writes require fresh preflight.
class WorkItemMilestonePicker extends StatefulWidget {
  const WorkItemMilestonePicker({
    super.key,
    required this.account,
    required this.api,
    required this.access,
    required this.isCurrent,
    required this.operationCurrent,
    this.onWriteStarted,
    this.onWriteSettled,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemMilestoneAccess access;
  final bool Function() isCurrent;
  final bool Function() operationCurrent;
  final VoidCallback? onWriteStarted;
  final VoidCallback? onWriteSettled;

  @override
  State<WorkItemMilestonePicker> createState() =>
      _WorkItemMilestonePickerState();
}

class _WorkItemMilestonePickerState extends State<WorkItemMilestonePicker> {
  final TextEditingController _search = TextEditingController();
  final List<WorkItemMilestoneChoice> _items = [];
  WorkItemMilestoneSelection? _selection;
  WorkItemMilestonePickerContinuation? _continuation;
  ApiFailure? _choiceError;
  ApiFailure? _saveError;
  String _submittedSearch = '';
  bool _loading = false;
  bool _truncated = false;
  bool _writing = false;
  bool _saveAttempted = false;
  bool _bindingInvalid = false;
  int _searchEpoch = 0;

  bool get _editable =>
      widget.access.canSetMilestone &&
      widget.access.target != null &&
      widget.isCurrent() &&
      !_saveAttempted &&
      !_bindingInvalid;

  @override
  void initState() {
    super.initState();
    _selection = widget.access.target?.currentSelection;
    if (_editable) unawaited(_readChoices());
  }

  @override
  void dispose() {
    _searchEpoch++;
    _search.dispose();
    super.dispose();
  }

  Future<void> _readChoices({bool more = false}) async {
    final target = widget.access.target;
    if (!_editable || target == null || (more && _loading)) return;
    final epoch = more ? _searchEpoch : ++_searchEpoch;
    final next = more ? _continuation : null;
    if (more && next == null) return;
    setState(() {
      _loading = true;
      _choiceError = null;
      if (!more) {
        _items.clear();
        _continuation = null;
        _truncated = false;
        _submittedSearch = _search.text.trim();
      }
    });
    bool current() => mounted && epoch == _searchEpoch && _editable;
    try {
      final page = await widget.api.workItemMilestoneChoices(
        target,
        search: _submittedSearch,
        continuation: next,
        isCurrent: current,
      );
      if (!current()) return;
      setState(() {
        _items.addAll(page.items);
        _continuation = page.continuation;
        _truncated = page.isTruncated;
      });
    } catch (error) {
      if (!current()) return;
      final failure = safeFailure(error);
      setState(() {
        _choiceError = failure;
        _bindingInvalid = switch (failure.kind) {
          FailureKind.cancelled ||
          FailureKind.conflict ||
          FailureKind.unauthenticated ||
          FailureKind.forbidden => true,
          _ => false,
        };
      });
    } finally {
      if (mounted && epoch == _searchEpoch && widget.isCurrent()) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save() async {
    final target = widget.access.target;
    final selection = _selection;
    if (!_editable || target == null || selection == null || _writing) return;
    final notifyStart = widget.onWriteStarted;
    final notifySettle = widget.onWriteSettled;
    var phaseStarted = false;
    setState(() {
      _writing = true;
      _saveAttempted = true;
      _searchEpoch++;
      _loading = false;
      _saveError = null;
    });
    try {
      final saved = await widget.api.updateWorkItemMilestone(
        target,
        selection: selection,
        isCurrent: () =>
            phaseStarted
                ? widget.operationCurrent()
                : mounted && widget.isCurrent(),
        onMutationSent: () {
          phaseStarted = true;
          notifyStart?.call();
        },
      );
      if (!mounted || !widget.isCurrent()) return;
      Navigator.of(context).pop(saved.snapshot);
    } catch (error) {
      if (!mounted || !widget.isCurrent()) return;
      final failure = safeFailure(error);
      // This selection lives only on this page. Closing it does not save a draft.
      final detail = switch (failure.kind) {
        FailureKind.validation => '里程碑設定未被接受。重新開啟後，請重新選擇里程碑。',
        FailureKind.conflict => '工作項目已變更，請重新開啟確認最新的里程碑設定。',
        FailureKind.writeUncertain => '連線在寫入時中斷。請重新開啟確認目前設定，避免重複送出。',
        _ => failure.detail,
      };
      setState(() {
        _saveError = ApiFailure(
          failure.kind,
          status: failure.status,
          retryAt: failure.retryAt,
          title: failure.title,
          detail: detail,
        );
      });
    } finally {
      if (mounted && widget.isCurrent()) setState(() => _writing = false);
      if (phaseStarted) notifySettle?.call();
    }
  }

  Widget _choice({
    required String title,
    required WorkItemMilestoneSelection selection,
    bool? expired,
    Key? key,
  }) {
    final milestone = selection.milestone;
    final onSelect = _editable
        ? () => setState(() => _selection = selection)
        : null;
    return Semantics(
      key: key,
      excludeSemantics: true,
      label: [
        title,
        if (milestone != null) _milestoneDetailsText(milestone, expired),
      ].join('\n'),
      button: true,
      enabled: _editable,
      checked: _selection?.milestone?.id == selection.milestone?.id,
      inMutuallyExclusiveGroup: true,
      onTap: onSelect,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(
          _selection?.milestone?.id == selection.milestone?.id
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
        ),
        title: Text(title),
        subtitle: selection.milestone == null
            ? null
            : _MilestoneDetails(selection.milestone!, expired: expired),
        enabled: _editable,
        onTap: onSelect,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.access.snapshot;
    final target = widget.access.target;
    final current = snapshot.milestone;
    final selected = _selection?.milestone;
    final currentId = current?.id;
    final items = _items
        .where((item) => item.milestone.id != currentId)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('變更里程碑')),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '@${widget.account.user.username} · ${widget.account.instance.key}\n'
                    '${_milestoneResourceLabel(snapshot.summary)}',
                  ),
                ),
                if (target != null) ...[
                  _choice(
                    title: current == null ? '目前未設定' : '目前：${current.title}',
                    selection: target.currentSelection,
                    expired: snapshot.milestoneExpired,
                    key: const ValueKey('work-item-milestone-current'),
                  ),
                  if (current != null)
                    _choice(
                      title: '移除里程碑',
                      selection: target.clearSelection,
                      key: const ValueKey('work-item-milestone-clear'),
                    ),
                  if (_selection?.milestone?.id != currentId)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        selected == null
                            ? '將移除目前里程碑'
                            : '將更新為：${selected.title}\n'
                                  '所屬：${selected.group?.fullPath ?? selected.project?.fullPath ?? '未知'}',
                        key: const ValueKey('work-item-milestone-pending'),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _search,
                      enabled: _editable,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _readChoices(),
                      decoration: InputDecoration(
                        labelText: '搜尋啟用中的里程碑',
                        suffixIcon: IconButton(
                          tooltip: '搜尋里程碑',
                          onPressed: _editable ? () => _readChoices() : null,
                          icon: const Icon(Icons.search),
                        ),
                      ),
                    ),
                  ),
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  if (_choiceError != null)
                    FailureNotice(
                      _choiceError!,
                      account: widget.account,
                      resourceLabel: _milestoneResourceLabel(snapshot.summary),
                      // Retry always starts a new bounded connection. Reusing
                      // a failed nonstable-sort cursor can skip candidates.
                      onRetry: _editable ? () => _readChoices() : null,
                    ),
                  if (!_loading && _choiceError == null && _items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('沒有符合搜尋的啟用中里程碑'),
                    ),
                ] else ...[
                  ListTile(
                    title: Text(current?.title ?? '未設定'),
                    subtitle: current == null
                        ? null
                        : _MilestoneDetails(
                            current,
                            expired: snapshot.milestoneExpired,
                          ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(switch (snapshot.availability) {
                      WorkItemMilestoneAvailability.present =>
                        '目前帳號沒有變更里程碑的權限。',
                      WorkItemMilestoneAvailability.absent => '這個工作項目沒有里程碑欄位。',
                      WorkItemMilestoneAvailability.widgetsUnavailable =>
                        '伺服器未提供這個工作項目的欄位資訊。',
                    }),
                  ),
                ],
                if (_bindingInvalid || (_saveAttempted && !_writing))
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('請關閉並重新開啟，讀取最新狀態後再變更。'),
                  ),
                if (_saveError != null)
                  FailureNotice(
                    _saveError!,
                    account: widget.account,
                    resourceLabel: _milestoneResourceLabel(snapshot.summary),
                  ),
              ],
            ),
          ),
          SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return _choice(
                key: ValueKey(
                  'work-item-milestone-choice-${item.milestone.id}',
                ),
                title: item.milestone.title,
                selection: item.selection,
                expired: item.expired,
              );
            },
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                if (_continuation != null)
                  TextButton(
                    onPressed: _editable && !_loading
                        ? () => _readChoices(more: true)
                        : null,
                    child: const Text('載入更多里程碑'),
                  ),
                if (_truncated)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('已讀取 200 個候選，請用名稱縮小搜尋。'),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            key: const ValueKey('work-item-milestone-save'),
            onPressed: _editable && _selection != null ? _save : null,
            icon: _writing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_writing ? '儲存中…' : '儲存'),
          ),
        ),
      ),
    );
  }
}

class _MilestoneDetails extends StatelessWidget {
  const _MilestoneDetails(this.milestone, {this.expired});

  final WorkItemMilestoneValue milestone;
  final bool? expired;

  @override
  Widget build(BuildContext context) =>
      Text(_milestoneDetailsText(milestone, expired));
}

String _milestoneDetailsText(WorkItemMilestoneValue milestone, bool? expired) =>
    [
      '所屬：${milestone.group?.fullPath ?? milestone.project?.fullPath ?? '未知'}',
      if (milestone.state.toLowerCase() == 'closed') '已關閉',
      if (expired == true) '已到期',
      if (milestone.startDate != null)
        '開始：${_milestoneCalendarDate(milestone.startDate!)}',
      if (milestone.dueDate != null)
        '到期：${_milestoneCalendarDate(milestone.dueDate!)}',
    ].join('\n');

String _milestoneCalendarDate(DateTime value) =>
    '${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')}';
