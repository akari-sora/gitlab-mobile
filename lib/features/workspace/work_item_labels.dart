import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_labels_models.dart';
import '../../shared/workspace_ui.dart';

/// Opens a fresh full label read and edits that logical set.
///
/// The parent keeps at most the first 50 labels. This control never asks the
/// parent to paint the editor selection as chips.
class WorkItemLabelsControl extends StatefulWidget {
  const WorkItemLabelsControl({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    this.generation = 0,
    this.isCurrent,
    this.ownerChanges,
    this.onRoute,
    this.onLabelWrite,
    this.onSaved,
    this.writePending = false,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final int generation;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;
  final WorkItemLabelWriteHook? onLabelWrite;
  final ValueChanged<WorkItemLabelSaveResult>? onSaved;
  final bool writePending;

  @override
  State<WorkItemLabelsControl> createState() => _WorkItemLabelsControlState();
}

class _WorkItemLabelsControlState extends State<WorkItemLabelsControl> {
  int _epoch = 0;
  int? _openingEpoch;
  Route<void>? _editorRoute;
  Object? _phaseToken;
  bool _phaseSettled = true;

  bool get _writePending => _phaseToken != null && !_phaseSettled;

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);

  bool _resourceChanged(WorkItemLabelsControl other) {
    final left = widget.detail.summary;
    final right = other.detail.summary;
    return left.id != right.id ||
        left.iid != right.iid ||
        left.type.id != right.type.id ||
        left.project?.id != right.project?.id ||
        left.project?.fullPath != right.project?.fullPath ||
        left.namespace?.id != right.namespace?.id ||
        left.namespace?.fullPath != right.namespace?.fullPath;
  }

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemLabelsControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        _resourceChanged(oldWidget)) {
      _invalidate(dismissRoute: true);
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _epoch++;
    _editorRoute = null;
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    final cleared = _invalidate(dismissRoute: true);
    if (cleared && mounted) setState(() {});
  }

  bool _invalidate({required bool dismissRoute}) {
    final owned = _openingEpoch;
    _epoch++;
    final cleared = owned != null && owned != _epoch;
    if (cleared) _openingEpoch = null;
    if (dismissRoute) _dismissRoute();
    return cleared;
  }

  void _dismissRoute() {
    final route = _editorRoute;
    final navigator = Navigator.maybeOf(context);
    if (route == null || navigator == null) return;
    _editorRoute = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!navigator.mounted || !route.isActive) return;
      navigator.removeRoute(route);
    });
  }

  Future<void> _open() async {
    if (_openingEpoch != null ||
        _editorRoute != null ||
        _writePending ||
        widget.writePending) {
      return;
    }
    final epoch = _epoch;
    final api = widget.api;
    final detail = widget.detail;
    final onLabelWrite = widget.onLabelWrite;
    setState(() => _openingEpoch = epoch);
    try {
      final access = await api.workItemLabels(
        detail,
        expectedUserId: widget.account.user.id,
        generation: widget.generation,
        isCurrent: () => _current(epoch) && identical(api, widget.api),
      );
      if (!mounted || !_current(epoch) || !identical(api, widget.api)) return;
      if (!context.mounted) return;
      final route = MaterialPageRoute<void>(
        builder: (context) => WorkItemLabelsSheet(
          api: api,
          access: access,
          accountKey: widget.account.key,
          isCurrent: () => _current(epoch) && identical(api, widget.api),
          onPhase: (phase, token) {
            if (phase == WorkItemLabelWritePhase.start) {
              if (!_current(epoch)) return;
              _phaseToken = token;
              _phaseSettled = false;
              onLabelWrite?.call(phase, token);
              return;
            }
            if (_phaseSettled || !identical(_phaseToken, token)) return;
            _phaseSettled = true;
            _phaseToken = null;
            if (mounted) setState(() {});
            onLabelWrite?.call(phase, token);
          },
          onSaved: (result) {
            if (!_current(epoch) || !identical(api, widget.api)) return;
            widget.onSaved?.call(result);
          },
        ),
      );
      if (!_current(epoch)) return;
      _editorRoute = route;
      widget.onRoute?.call(route);
      await Navigator.of(context).push(route);
      if (mounted && identical(_editorRoute, route)) _editorRoute = null;
    } catch (error) {
      if (!mounted || !_current(epoch)) return;
      final failure = safeFailure(error);
      if (failure.kind == FailureKind.cancelled) return;
      showFailure(context, failure);
    } finally {
      if (mounted && _openingEpoch == epoch) {
        setState(() => _openingEpoch = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final writePending = _writePending || widget.writePending;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: const ValueKey('work-item-labels-edit'),
        onPressed: _openingEpoch != null || writePending ? null : _open,
        child: Text(
          writePending
              ? '正在更新標籤…'
              : (_openingEpoch != null ? '讀取標籤…' : '變更標籤'),
        ),
      ),
    );
  }
}

/// The bottom sheet or page for modifying a work item's labels.
class WorkItemLabelsSheet extends StatefulWidget {
  const WorkItemLabelsSheet({
    super.key,
    required this.api,
    required this.access,
    required this.accountKey,
    required this.isCurrent,
    required this.onPhase,
    this.onSaved,
  });

  final GitLabApi api;
  final WorkItemLabelAccess access;
  final String accountKey;
  final bool Function() isCurrent;
  final WorkItemLabelWriteHook onPhase;
  final ValueChanged<WorkItemLabelSaveResult>? onSaved;

  @override
  State<WorkItemLabelsSheet> createState() => _WorkItemLabelsSheetState();
}

class _WorkItemLabelsSheetState extends State<WorkItemLabelsSheet> {
  static const _minActionHeight = 48.0;

  final TextEditingController _search = TextEditingController();
  final Set<String> _selected = <String>{};
  final Map<String, WorkItemLabel> _known = <String, WorkItemLabel>{};
  List<WorkItemLabel> _candidates = const <WorkItemLabel>[];
  WorkItemLabelCandidatePage? _candidatePage;
  int _candidatePageIndex = 0;
  String? _candidateTerm;

  bool _searching = false;
  bool _loadingMoreCandidates = false;
  bool _writing = false;
  bool _locked = false;
  int _searchEpoch = 0;

  String? _searchError;
  String? _saveError;
  String? _saveMessage;
  Object? _phaseToken;
  bool _disposed = false;

  WorkItemLabelSnapshot get _snapshot => widget.access.snapshot;

  bool get _canChange =>
      widget.access.canWrite &&
      widget.access.target != null &&
      !widget.access.target!.consumed;

  @override
  void initState() {
    super.initState();
    for (final label in _snapshot.labels) {
      _known[label.id] = label;
      _selected.add(label.id);
    }
    if (!widget.access.canWrite || widget.access.target == null) {
      _locked = true;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchEpoch++;
    _search.dispose();
    super.dispose();
  }

  bool _searchCurrent(int epoch) =>
      mounted && epoch == _searchEpoch && widget.isCurrent();

  void _onSearchEdited(String _) {
    if (!_searching) return;
    _searchEpoch++;
    setState(() => _searching = false);
  }

  Future<void> _submitSearch() async {
    final target = widget.access.target;
    if (_searching ||
        target == null ||
        _writing ||
        _locked ||
        !widget.isCurrent()) {
      return;
    }
    final rawTerm = _search.text;
    final term = rawTerm.trim();
    if (term.isEmpty ||
        term.runes.length > 256 ||
        term.runes.any((rune) => rune < 0x20 || rune == 0x7F)) {
      setState(() {
        _searchError = '搜尋需為 1 到 256 個字，且不能包含控制字元。';
      });
      return;
    }

    final epoch = ++_searchEpoch;
    final accountKey = widget.accountKey;
    setState(() {
      _searching = true;
      _searchError = null;
    });

    try {
      final page = await widget.api.searchWorkItemLabelCandidates(
        target,
        searchTerm: term,
        pageIndex: 0,
        isCurrent: () =>
            _searchCurrent(epoch) &&
            accountKey == widget.accountKey &&
            identical(widget.access.target, target),
      );
      if (!_searchCurrent(epoch) ||
          _search.text != rawTerm ||
          accountKey != widget.accountKey ||
          !identical(widget.access.target, target)) {
        return;
      }
      for (final label in page.labels) {
        _known[label.id] = label;
      }
      setState(() {
        _candidates = page.labels;
        _candidatePage = page;
        _candidatePageIndex = 0;
        _candidateTerm = term;
        _searching = false;
      });
    } catch (error) {
      if (!_searchCurrent(epoch) || _search.text != rawTerm) return;
      final failure = safeFailure(error);
      setState(() {
        _searching = false;
        _searchError = failure.detail.isNotEmpty
            ? failure.detail
            : failure.title;
      });
    }
  }

  Future<void> _loadMoreCandidates() async {
    final target = widget.access.target;
    final page = _candidatePage;
    final term = _candidateTerm;
    if (target == null ||
        page == null ||
        !page.hasNextPage ||
        page.endCursor == null ||
        term == null ||
        _candidatePageIndex >= 4 ||
        _loadingMoreCandidates ||
        _writing ||
        _locked ||
        !widget.isCurrent()) {
      return;
    }

    final epoch = _searchEpoch;
    final accountKey = widget.accountKey;
    final nextIndex = _candidatePageIndex + 1;
    setState(() => _loadingMoreCandidates = true);

    try {
      final nextPage = await widget.api.searchWorkItemLabelCandidates(
        target,
        searchTerm: term,
        after: page.endCursor,
        pageIndex: nextIndex,
        isCurrent: () =>
            _searchCurrent(epoch) &&
            accountKey == widget.accountKey &&
            identical(widget.access.target, target),
      );
      if (!_searchCurrent(epoch) ||
          accountKey != widget.accountKey ||
          !identical(widget.access.target, target)) {
        return;
      }
      for (final label in nextPage.labels) {
        _known[label.id] = label;
      }
      setState(() {
        _candidates = [..._candidates, ...nextPage.labels];
        _candidatePage = nextPage;
        _candidatePageIndex = nextIndex;
        _loadingMoreCandidates = false;
      });
    } catch (error) {
      if (!_searchCurrent(epoch)) return;
      final failure = safeFailure(error);
      setState(() {
        _loadingMoreCandidates = false;
        _searchError = failure.detail.isNotEmpty
            ? failure.detail
            : failure.title;
      });
    }
  }

  void _toggle(String id, bool selected) {
    if (!_canChange || _writing || _locked || !widget.isCurrent()) return;
    setState(() {
      if (selected) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  void _clearAll() {
    if (!_canChange || _writing || _locked || !widget.isCurrent()) return;
    setState(_selected.clear);
  }

  Future<void> _save() async {
    final target = widget.access.target;
    if (target == null ||
        target.consumed ||
        !_canChange ||
        _writing ||
        _locked ||
        !widget.isCurrent()) {
      return;
    }

    final epochToken = Object();
    final api = widget.api;
    final accountKey = widget.accountKey;
    final isCurrent = widget.isCurrent;
    final onPhase = widget.onPhase;
    final onSaved = widget.onSaved;
    var phaseStarted = false;
    var phaseSettled = false;

    bool operationCurrent() => !_disposed && isCurrent();

    void settlePhase() {
      if (!phaseStarted || phaseSettled) return;
      phaseSettled = true;
      onPhase(WorkItemLabelWritePhase.settle, epochToken);
    }

    setState(() {
      _writing = true;
      _locked = true;
      _saveError = null;
      _saveMessage = null;
      _phaseToken = epochToken;
    });

    try {
      final result = await api.updateWorkItemLabels(
        target,
        desiredLabelIds: _selected.toList(growable: false),
        isCurrent: operationCurrent,
        onMutationSent: () {
          phaseStarted = true;
          onPhase(WorkItemLabelWritePhase.start, epochToken);
        },
      );

      if (_disposed ||
          !mounted ||
          !isCurrent() ||
          !identical(api, widget.api)) {
        return;
      }
      if (accountKey != widget.accountKey) return;
      if (!identical(_phaseToken, epochToken)) return;

      if (result.status == WorkItemLabelSaveStatus.success) {
        onSaved?.call(result);
        if (!_disposed && mounted && isCurrent()) {
          Navigator.of(context).pop();
        }
        return;
      }

      if (result.status == WorkItemLabelSaveStatus.noop) {
        if (!_disposed && mounted) {
          setState(() {
            _saveMessage = '標籤沒有變更';
            _writing = false;
          });
        }
        return;
      }

      if (result.status == WorkItemLabelSaveStatus.notApplied) {
        onSaved?.call(result);
        if (!_disposed && mounted) {
          setState(() {
            _saveMessage = '伺服器保留的標籤與所選不同';
            _writing = false;
          });
        }
        return;
      }
    } catch (error) {
      if (_disposed || !mounted || !isCurrent()) return;
      final failure = safeFailure(error);
      String message;
      switch (failure.kind) {
        case FailureKind.forbidden:
          message = '沒有修改標籤的權限';
          break;
        case FailureKind.conflict:
          message = '工作項目已更新，請重新整理';
          break;
        case FailureKind.unsupported:
          message = '無法讀完標籤，不能修改';
          break;
        case FailureKind.validation:
          message = '標籤識別無效';
          break;
        case FailureKind.writeUncertain:
          message = '無法確認寫入結果';
          break;
        case FailureKind.cancelled:
          message = '';
          break;
        default:
          message = '無法確認寫入結果';
          break;
      }
      if (_disposed || !mounted || !isCurrent()) return;
      setState(() {
        _writing = false;
        if (isCurrent() && message.isNotEmpty) {
          _saveError = message;
        }
      });
    } finally {
      if (!_disposed && mounted && isCurrent() && _writing) {
        setState(() => _writing = false);
      }
      settlePhase();
    }
  }

  List<Widget> _buildConflictWarnings(BuildContext context) {
    if (_snapshot.allowsScopedLabels != WorkItemLabelAllowsScoped.allowed) {
      return const <Widget>[];
    }

    final groups = <String, List<WorkItemLabel>>{};
    for (final id in _selected) {
      final label = _known[id];
      if (label == null) continue;
      final key = workItemLabelScopeKey(label.title);
      if (key != null) {
        (groups[key] ??= <WorkItemLabel>[]).add(label);
      }
    }

    final conflicts = groups.entries
        .where((entry) => entry.value.length >= 2)
        .toList(growable: false);
    if (conflicts.isEmpty) return const <Widget>[];

    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;

    return [
      for (final entry in conflicts)
        Container(
          key: ValueKey('work-item-labels-conflict-${entry.key}'),
          margin: const EdgeInsets.only(top: 8, bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: errorColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: errorColor.withValues(alpha: 0.38)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final label in entry.value)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    label.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    softWrap: true,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                '伺服器可能只保留同一範圍的一個標籤',
                style: theme.textTheme.bodySmall?.copyWith(color: errorColor),
                softWrap: true,
              ),
            ],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final conflictWidgets = _buildConflictWarnings(context);

    // Selected labels followed by candidate labels that are not selected.
    final selectedRows = <WorkItemLabel>[
      for (final id in _selected)
        if (_known[id] != null) _known[id]!,
    ];
    final seenCandidate = <String>{};
    final candidateRows = <WorkItemLabel>[
      for (final label in _snapshot.labels)
        if (!_selected.contains(label.id) && seenCandidate.add(label.id)) label,
      for (final label in _candidates)
        if (!_selected.contains(label.id) && seenCandidate.add(label.id)) label,
    ];

    final totalRows = selectedRows.length + candidateRows.length;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('標籤')),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount:
              1 +
              conflictWidgets.length +
              totalRows +
              (_candidatePage?.hasNextPage == true && _candidatePageIndex < 4
                  ? 1
                  : 0),
          itemBuilder: (context, index) {
            if (index == 0) {
              return _buildHeader(context);
            }
            final conflictIndex = index - 1;
            if (conflictIndex < conflictWidgets.length) {
              return conflictWidgets[conflictIndex];
            }
            final rowIndex = conflictIndex - conflictWidgets.length;
            if (rowIndex < selectedRows.length) {
              final label = selectedRows[rowIndex];
              return _buildLabelTile(context, label, isSelected: true);
            }
            final candidateIndex = rowIndex - selectedRows.length;
            if (candidateIndex < candidateRows.length) {
              final label = candidateRows[candidateIndex];
              return _buildLabelTile(context, label, isSelected: false);
            }
            return _buildLoadMoreTile();
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + keyboard),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _minActionHeight),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('work-item-labels-save'),
                onPressed: !_canChange || _writing || _locked ? null : _save,
                child: Text(_writing ? '儲存中…' : '儲存', maxLines: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '已選擇 ${_selected.length} 個標籤',
              key: const ValueKey('work-item-labels-count'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (_selected.isNotEmpty)
              TextButton(
                key: const ValueKey('work-item-labels-clear'),
                onPressed: !_canChange || _writing || _locked
                    ? null
                    : _clearAll,
                child: const Text('清除全部'),
              ),
          ],
        ),
        if (!_canChange)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              '沒有修改標籤的權限',
              key: const ValueKey('work-item-labels-readonly'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_saveMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              _saveMessage!,
              key: const ValueKey('work-item-labels-save-message'),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              _saveError!,
              key: const ValueKey('work-item-labels-save-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            key: const ValueKey('work-item-labels-search'),
            controller: _search,
            enabled: widget.access.target != null && !_writing && !_locked,
            scrollPadding: const EdgeInsets.only(bottom: 96),
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: '搜尋標籤',
              border: OutlineInputBorder(),
            ),
            onChanged: _onSearchEdited,
            onSubmitted: (_) => unawaited(_submitSearch()),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('work-item-labels-search-submit'),
            onPressed:
                _searching ||
                    widget.access.target == null ||
                    _writing ||
                    _locked
                ? null
                : () => unawaited(_submitSearch()),
            child: Text(_searching ? '搜尋中…' : '搜尋'),
          ),
        ),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _searchError!,
              key: const ValueKey('work-item-labels-search-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _buildLabelTile(
    BuildContext context,
    WorkItemLabel label, {
    required bool isSelected,
  }) {
    Color? chipBackground;
    Color? chipTextColor;
    if (label.color != null &&
        label.textColor != null &&
        workItemLabelContrastAccepted(label.color!, label.textColor!)) {
      chipBackground = Color(
        int.parse(label.color!.substring(1), radix: 16) | 0xFF000000,
      );
      chipTextColor = Color(
        int.parse(label.textColor!.substring(1), radix: 16) | 0xFF000000,
      );
    }

    final theme = Theme.of(context);
    final dotColor =
        label.color != null &&
            RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(label.color!)
        ? Color(int.parse(label.color!.substring(1), radix: 16) | 0xFF000000)
        : theme.colorScheme.outline;

    return CheckboxListTile(
      key: ValueKey('work-item-label-row-${label.id}'),
      value: isSelected,
      onChanged: !_canChange || _writing || _locked
          ? null
          : (value) => _toggle(label.id, value ?? false),
      secondary: CircleAvatar(backgroundColor: dotColor, radius: 8),
      title: Container(
        padding: chipBackground != null
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : EdgeInsets.zero,
        decoration: chipBackground != null
            ? BoxDecoration(
                color: chipBackground,
                borderRadius: BorderRadius.circular(4),
              )
            : null,
        child: Text(
          label.title,
          style: theme.textTheme.bodyMedium?.copyWith(color: chipTextColor),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          softWrap: true,
        ),
      ),
      controlAffinity: ListTileControlAffinity.trailing,
      dense: true,
    );
  }

  Widget _buildLoadMoreTile() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextButton(
          key: const ValueKey('work-item-labels-candidates-more'),
          onPressed: _loadingMoreCandidates || _writing || _locked
              ? null
              : () => unawaited(_loadMoreCandidates()),
          child: Text(_loadingMoreCandidates ? '載入中…' : '載入更多候選標籤'),
        ),
      ),
    );
  }
}
