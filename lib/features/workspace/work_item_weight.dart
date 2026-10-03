import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_attribute_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_weight_models.dart';
import '../../shared/workspace_ui.dart';

const _graphQlIntMax = 2147483647;
final _wholeWeight = RegExp(r'^[0-9]+$');

enum _WeightChoice { set, remove }

/// Weight-only signal around one validated save. [token] is a fresh opaque
/// object for that save, so a later control cannot collide with an earlier one.
enum WorkItemWeightWritePhase { start, settle }

typedef WorkItemWeightWriteListener =
    void Function(
      WorkItemWeightWritePhase phase,
      Object token,
      Account account,
      GitLabApi api,
      WorkItemGraphDetail detail,
    );

bool _alwaysCurrent() => true;

/// On-demand weight action. Permission comes only from a fresh
/// [GitLabApi.workItemWeight] read, never from the attributes already on screen.
class WorkItemWeightControl extends StatefulWidget {
  const WorkItemWeightControl({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    required this.onSaved,
    this.isCurrent = _alwaysCurrent,
    this.ownerChanges,
    this.onRoute,
    this.onWeightWrite,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final ValueChanged<WorkItemWeightSnapshot> onSaved;
  final bool Function() isCurrent;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;
  final WorkItemWeightWriteListener? onWeightWrite;

  @override
  State<WorkItemWeightControl> createState() => _WorkItemWeightControlState();
}

class _WorkItemWeightControlState extends State<WorkItemWeightControl> {
  var _epoch = 0;
  var _opening = false;
  ApiFailure? _error;
  Route<WorkItemWeightSnapshot>? _route;
  NavigatorState? _navigator;
  Object? _writeToken;
  Account? _writeAccount;
  GitLabApi? _writeApi;
  WorkItemGraphDetail? _writeDetail;

  bool _current(int epoch) => mounted && epoch == _epoch && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemWeightControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        _resourceChanged(oldWidget.detail, widget.detail)) {
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

  void _noteWeightWriteStarted(Object token) {
    _writeToken = token;
    final account = widget.account;
    final api = widget.api;
    final detail = widget.detail;
    _writeAccount = account;
    _writeApi = api;
    _writeDetail = detail;
    widget.onWeightWrite?.call(
      WorkItemWeightWritePhase.start,
      token,
      account,
      api,
      detail,
    );
  }

  void _noteWeightWriteSettled(Object token) {
    final account = _writeAccount;
    final api = _writeApi;
    final detail = _writeDetail;
    if (identical(_writeToken, token)) _writeToken = null;
    if (account == null || api == null || detail == null) return;
    widget.onWeightWrite?.call(
      WorkItemWeightWritePhase.settle,
      token,
      account,
      api,
      detail,
    );
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

  void _invalidate() {
    _epoch++;
    _opening = false;
    _error = null;
    _dismissRoute();
    if (mounted) setState(() {});
  }

  bool _resourceChanged(
    WorkItemGraphDetail previous,
    WorkItemGraphDetail next,
  ) {
    final left = previous.summary;
    final right = next.summary;
    return left.id != right.id ||
        left.iid != right.iid ||
        left.type.id != right.type.id ||
        left.project?.id != right.project?.id ||
        left.project?.fullPath != right.project?.fullPath ||
        left.namespace?.id != right.namespace?.id ||
        left.namespace?.fullPath != right.namespace?.fullPath ||
        left.updatedAt != right.updatedAt;
  }

  Future<void> _open() async {
    if (!mounted || _opening || !widget.isCurrent()) return;
    final epoch = _epoch;
    _opening = true;
    _error = null;
    setState(() {});
    try {
      final access = await widget.api.workItemWeight(
        widget.detail,
        expectedUserId: widget.account.user.id,
        isCurrent: () => _current(epoch),
      );
      if (!mounted) return;
      if (!_current(epoch)) return;
      final navigator = Navigator.of(context);
      final writeToken = Object();
      final route = MaterialPageRoute<WorkItemWeightSnapshot>(
        builder: (context) => WorkItemWeightEditor(
          account: widget.account,
          api: widget.api,
          access: access,
          isCurrent: () => _current(epoch),
          onWriteStarted: () => _noteWeightWriteStarted(writeToken),
          onWriteSettled: () => _noteWeightWriteSettled(writeToken),
        ),
      );
      _navigator = navigator;
      _route = route;
      widget.onRoute?.call(route);
      final saved = await navigator.push(route);
      if (identical(_route, route)) _route = null;
      if (!_current(epoch) || saved == null) return;
      widget.onSaved(saved);
    } on ApiFailure catch (error) {
      if (!_current(epoch) || error.kind == FailureKind.cancelled) return;
      setState(() => _error = error);
    } catch (error) {
      if (!_current(epoch)) return;
      setState(() => _error = safeFailure(error));
    } finally {
      if (_current(epoch)) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('work-item-weight-edit'),
            onPressed: _opening || !widget.isCurrent()
                ? null
                : () => unawaited(_open()),
            icon: _opening
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.scale_outlined),
            label: Text(_opening ? '讀取權重權限…' : '變更權重'),
          ),
        ),
        if (_error != null)
          FailureNotice(
            _error!,
            account: widget.account,
            resourceLabel: _weightResourceLabel(widget.detail.summary),
            onRetry: _open,
          ),
      ],
    );
  }
}

class WorkItemWeightEditor extends StatefulWidget {
  const WorkItemWeightEditor({
    super.key,
    required this.account,
    required this.api,
    required this.access,
    this.isCurrent = _alwaysCurrent,
    this.onWriteStarted,
    this.onWriteSettled,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemWeightAccess access;
  final bool Function() isCurrent;
  final VoidCallback? onWriteStarted;
  final VoidCallback? onWriteSettled;

  @override
  State<WorkItemWeightEditor> createState() => _WorkItemWeightEditorState();
}

class _WorkItemWeightEditorState extends State<WorkItemWeightEditor> {
  late final TextEditingController _input;
  late String _observedInput;
  late _WeightChoice _choice;
  var _writing = false;
  var _saveAttempted = false;
  String? _inputError;
  ApiFailure? _saveError;

  WorkItemWeightAttribute? get _value => widget.access.snapshot.value;

  bool get _canEditCapability =>
      widget.isCurrent() &&
      widget.access.canSetWeight &&
      widget.access.target != null &&
      widget.access.snapshot.availability ==
          WorkItemAttributeAvailability.present;

  bool get _editable => _canEditCapability && !_saveAttempted && !_writing;

  @override
  void initState() {
    super.initState();
    final own = _value?.weight;
    _choice = own == null ? _WeightChoice.remove : _WeightChoice.set;
    _observedInput = own?.toString() ?? '';
    _input = TextEditingController(text: _observedInput);
    _input.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _input.removeListener(_onInputChanged);
    _input.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    if (!mounted || _input.text == _observedInput) return;
    _observedInput = _input.text;
    setState(() => _inputError = null);
  }

  void _choose(_WeightChoice choice) {
    if (!_editable || _choice == choice) return;
    setState(() {
      _choice = choice;
      _inputError = null;
    });
  }

  Future<void> _save() async {
    if (!_editable || _writing) return;
    final target = widget.access.target;
    if (target == null) return;
    final int? desired;
    if (_choice == _WeightChoice.remove) {
      desired = null;
    } else {
      final text = _input.text.trim();
      final parsed = _parseSetWeight(text);
      if (parsed == null) {
        setState(() => _inputError = _setWeightError(text));
        return;
      }
      desired = parsed;
    }
    final notifyStart = widget.onWriteStarted;
    final notifySettle = widget.onWriteSettled;
    setState(() {
      _writing = true;
      _inputError = null;
      _saveError = null;
    });
    notifyStart?.call();
    try {
      final saved = await widget.api.updateWorkItemWeight(
        target,
        weight: desired,
        isCurrent: () => mounted && widget.isCurrent(),
      );
      if (!mounted || !widget.isCurrent()) return;
      Navigator.of(context).pop(saved);
    } on ApiFailure catch (error) {
      if (!mounted || !widget.isCurrent()) return;
      setState(() {
        _writing = false;
        _saveAttempted = true;
        _saveError = _saveFailure(error);
      });
    } catch (error) {
      if (!mounted || !widget.isCurrent()) return;
      setState(() {
        _writing = false;
        _saveAttempted = true;
        _saveError = _saveFailure(safeFailure(error));
      });
    } finally {
      notifySettle?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.access.snapshot;
    final summary = snapshot.summary;
    final blocked = _blockedMessage();
    final pending = _pendingLabel();
    final fieldEnabled = _editable && _choice == _WeightChoice.set;
    // Scaffold lays this bar on the viewport bottom and only shrinks the
    // body. This padding is the keyboard inset; SafeArea applies the
    // uncovered system inset once.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: const Text('變更權重')),
      body: CustomScrollView(
        key: const ValueKey('work-item-weight-scroll'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            sliver: SliverList.list(
              children: [
                Text(
                  '@${widget.account.user.username} · ${widget.account.instance.key}',
                ),
                const SizedBox(height: 4),
                Text(_weightResourceLabel(summary)),
                const SizedBox(height: 4),
                Text(summary.title),
                if (_ownLabel() != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _ownLabel()!,
                    key: const ValueKey('work-item-weight-own'),
                  ),
                ],
                if (blocked != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    blocked,
                    key: const ValueKey('work-item-weight-capability'),
                  ),
                ],
                if (_canEditCapability) ...[
                  const SizedBox(height: 8),
                  _choiceRow(
                    key: const ValueKey('work-item-weight-set'),
                    label: '設定權重',
                    selected: _choice == _WeightChoice.set,
                    onSelect: () => _choose(_WeightChoice.set),
                  ),
                  _choiceRow(
                    key: const ValueKey('work-item-weight-remove'),
                    label: '移除權重',
                    selected: _choice == _WeightChoice.remove,
                    onSelect: () => _choose(_WeightChoice.remove),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('work-item-weight-input'),
                    controller: _input,
                    enabled: fieldEnabled,
                    keyboardType: TextInputType.number,
                    scrollPadding: const EdgeInsets.only(bottom: 96),
                    decoration: InputDecoration(
                      labelText: '權重',
                      helperText: '請輸入 0 或正整數；清除請選「移除權重」。',
                      errorText: _inputError,
                    ),
                  ),
                ],
                if (pending != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    pending,
                    key: const ValueKey('work-item-weight-pending'),
                  ),
                ],
                if (_value != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '彙整權重：${_formatTotal(_value!.rolledUpWeight)}',
                    key: const ValueKey('work-item-weight-rolled'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '已完成彙整權重：${_formatTotal(_value!.rolledUpCompletedWeight)}',
                    key: const ValueKey('work-item-weight-completed'),
                  ),
                ],
                if (_saveAttempted && _saveError != null) ...[
                  const SizedBox(height: 12),
                  const Text('請關閉並重新開啟，讀取最新狀態後再變更。'),
                  FailureNotice(
                    _saveError!,
                    account: widget.account,
                    resourceLabel: _weightResourceLabel(summary),
                  ),
                ],
              ],
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
            child: FilledButton(
              key: const ValueKey('work-item-weight-save'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _editable ? () => unawaited(_save()) : null,
              child: _writing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('儲存'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _choiceRow({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onSelect,
  }) {
    return Semantics(
      key: key,
      excludeSemantics: true,
      label: label,
      button: true,
      enabled: _editable,
      checked: selected,
      inMutuallyExclusiveGroup: true,
      onTap: onSelect,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        minTileHeight: 48,
        selected: selected,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
        ),
        title: Text(label),
        onTap: onSelect,
      ),
    );
  }

  String? _ownLabel() {
    final attribute = _value;
    if (attribute == null) return null;
    final weight = attribute.weight;
    return weight == null ? '目前未設定' : '目前權重：$weight';
  }

  String? _blockedMessage() {
    if (_canEditCapability || _saveAttempted || _writing) return null;
    return switch (widget.access.snapshot.availability) {
      WorkItemAttributeAvailability.absent => '這個工作項目沒有權重欄位。',
      WorkItemAttributeAvailability.widgetsUnavailable => '伺服器未提供這個工作項目的欄位資訊。',
      WorkItemAttributeAvailability.present => '目前帳號沒有變更權重的權限。',
    };
  }

  String? _pendingLabel() {
    if (!_editable) return null;
    final current = _value?.weight;
    if (_choice == _WeightChoice.remove) {
      return current == null ? null : '將移除權重';
    }
    final parsed = _parseSetWeight(_input.text.trim());
    if (parsed == null || parsed == current) return null;
    return '將設定權重：$parsed';
  }

  String _formatTotal(int? value) => value == null ? '未設定' : '$value';
}

int? _parseSetWeight(String text) {
  if (!_wholeWeight.hasMatch(text)) return null;
  final value = BigInt.parse(text);
  if (value > BigInt.from(_graphQlIntMax)) return null;
  return value.toInt();
}

String _setWeightError(String text) {
  if (text.isEmpty) return '請輸入權重。空白不會清除權重。';
  if (_wholeWeight.hasMatch(text)) {
    return '權重必須是 0 到 $_graphQlIntMax 的整數。';
  }
  return '請輸入 0 或正整數。';
}

String _weightResourceLabel(WorkItemGraphSummary summary) {
  final scope =
      summary.project?.fullPath ?? summary.namespace?.fullPath ?? '未知範圍';
  return '$scope · 工作項目 #${summary.iid}';
}

ApiFailure _saveFailure(ApiFailure error) {
  final detail = switch (error.kind) {
    FailureKind.validation => '權重設定未被接受。重新開啟後，請重新輸入。',
    FailureKind.conflict => '工作項目已變更，請重新開啟確認最新的權重。',
    FailureKind.writeUncertain => '連線在寫入時中斷。請重新開啟確認目前權重，避免重複送出。',
    _ => '權重沒有變更。請重新開啟確認目前狀態。',
  };
  return ApiFailure(
    error.kind,
    status: error.status,
    retryAt: error.retryAt,
    title: error.title,
    detail: detail,
  );
}
