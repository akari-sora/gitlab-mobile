import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_assignee_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/workspace_ui.dart';

import '../../l10n/l10n.dart';
enum WorkItemAssigneesWritePhase { start, settle }

/// Opens a fresh full assignee read and edits that logical set.
///
/// The parent keeps at most the first 20 people. This control never asks the
/// parent to paint the complete roster as chips.
class WorkItemAssigneesControl extends StatefulWidget {
  const WorkItemAssigneesControl({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    required this.onSaved,
    this.isCurrent,
    this.ownerChanges,
    this.onRoute,
    this.onAssigneesWrite,
    this.writePending = false,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final ValueChanged<WorkItemAssigneeSnapshot> onSaved;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;
  final void Function(WorkItemAssigneesWritePhase phase, Object token)?
  onAssigneesWrite;
  final bool writePending;

  @override
  State<WorkItemAssigneesControl> createState() =>
      _WorkItemAssigneesControlState();
}

class _WorkItemAssigneesControlState extends State<WorkItemAssigneesControl> {
  int _epoch = 0;
  int? _openingEpoch;
  Route<void>? _editorRoute;
  Object? _phaseToken;
  bool _phaseSettled = true;

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);
  bool get _writePending => widget.writePending || !_phaseSettled;

  bool _resourceChanged(WorkItemAssigneesControl other) {
    final left = widget.detail.summary;
    final right = other.detail.summary;
    return left.id != right.id ||
        left.iid != right.iid ||
        left.type.id != right.type.id ||
        left.project?.id != right.project?.id ||
        left.project?.fullPath != right.project?.fullPath ||
        left.namespace?.id != right.namespace?.id ||
        left.namespace?.fullPath != right.namespace?.fullPath ||
        left.updatedAt != right.updatedAt;
  }

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemAssigneesControl oldWidget) {
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

  /// Drops the open attempt that this epoch owned.
  ///
  /// A newer attempt stores its own epoch and must stay busy. Returns whether
  /// the button label has to be rebuilt outside a parent update.
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
    if (_openingEpoch != null || _editorRoute != null || _writePending) return;
    final epoch = _epoch;
    final api = widget.api;
    final detail = widget.detail;
    final onWrite = widget.onAssigneesWrite;
    final operationCurrent = widget.isCurrent;
    setState(() => _openingEpoch = epoch);
    try {
      final access = await api.workItemAssignees(
        detail,
        expectedUserId: widget.account.user.id,
        isCurrent: () => _current(epoch) && identical(api, widget.api),
      );
      if (!mounted || !_current(epoch) || !identical(api, widget.api)) return;
      if (!context.mounted) return;
      final route = MaterialPageRoute<void>(
        builder: (context) => _AssigneeEditor(
          api: api,
          access: access,
          accountKey: widget.account.key,
          isCurrent: () => _current(epoch) && identical(api, widget.api),
          operationCurrent: () => operationCurrent?.call() ?? true,
          onPhase: (phase, token) {
            if (phase == WorkItemAssigneesWritePhase.start) {
              if (!_current(epoch) || !_phaseSettled) return;
              _phaseToken = token;
              _phaseSettled = false;
              onWrite?.call(phase, token);
              if (mounted) setState(() {});
              return;
            }
            if (_phaseSettled || !identical(_phaseToken, token)) return;
            _phaseSettled = true;
            onWrite?.call(phase, token);
            if (mounted) setState(() {});
          },
          onSaved: (snapshot) {
            if (!_current(epoch) || !identical(api, widget.api)) return;
            widget.onSaved(snapshot);
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
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        key: const ValueKey('work-item-assignees-edit'),
        onPressed: _openingEpoch != null || _writePending ? null : _open,
        child: Text(
          _writePending
              ? l10n.changingInProgress
              : _openingEpoch != null
              ? l10n.loadingAssignees
              : l10n.changeAssignees,
        ),
      ),
    );
  }
}

class WorkItemAssigneeRosterPage extends StatelessWidget {
  const WorkItemAssigneeRosterPage({super.key, required this.users});

  final List<WorkItemAssigneeUser> users;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l10n.allAssigneesCount(users.length))),
      body: ListView.builder(
        itemCount: users.length,
        itemBuilder: (context, index) {
          final user = users[index];
          return ListTile(
            key: ValueKey('work-item-assignee-roster-${user.id}'),
            title: Text(isolated(user.name.isEmpty ? '@${user.username}' : user.name)),
            subtitle: Text(isolated('@${user.username}')),
          );
        },
      ),
    );
  }
}

class _AssigneeEditor extends StatefulWidget {
  const _AssigneeEditor({
    required this.api,
    required this.access,
    required this.accountKey,
    required this.isCurrent,
    required this.operationCurrent,
    required this.onPhase,
    required this.onSaved,
  });

  final GitLabApi api;
  final WorkItemAssigneeAccess access;
  final String accountKey;
  final bool Function() isCurrent;
  final bool Function() operationCurrent;
  final void Function(WorkItemAssigneesWritePhase phase, Object token) onPhase;
  final ValueChanged<WorkItemAssigneeSnapshot> onSaved;

  @override
  State<_AssigneeEditor> createState() => _AssigneeEditorState();
}

class _AssigneeEditorState extends State<_AssigneeEditor> {
  static const _actionHeight = 48.0;

  final _search = TextEditingController();
  final _selected = <String>{};
  final _known = <String, WorkItemAssigneeUser>{};
  var _candidates = const <WorkItemAssigneeUser>[];
  var _searching = false;
  var _searchLimited = false;
  var _writing = false;
  var _locked = false;
  var _searchEpoch = 0;
  ApiFailure? _searchError;
  ApiFailure? _saveError;
  Object? _phaseToken;

  WorkItemAssigneeSnapshot get _snapshot => widget.access.snapshot;

  bool get _complete => _snapshot.users.length <= 2000;

  bool get _canChange =>
      widget.access.canWrite && widget.access.target != null && _complete;

  @override
  void initState() {
    super.initState();
    for (final user in _snapshot.users) {
      _known[user.id] = user;
      _selected.add(user.id);
    }
  }

  @override
  void dispose() {
    _searchEpoch++;
    _search.dispose();
    super.dispose();
  }

  bool _searchCurrent(int epoch) =>
      mounted && epoch == _searchEpoch && widget.isCurrent();

  List<WorkItemAssigneeUser> get _selectedUsers => [
    for (final id in _selected)
      if (_known[id] != null) _known[id]!,
  ];

  List<WorkItemAssigneeUser> get _candidateRows => [
    for (final user in _candidates)
      if (!_selected.contains(user.id)) user,
  ];

  void _onSearchEdited(String _) {
    if (!_searching) return;
    _searchEpoch++;
    setState(() => _searching = false);
  }

  Future<void> _submitSearch() async {
    final target = widget.access.target;
    if (target == null || _writing || _locked || !widget.isCurrent()) return;
    final query = _search.text;
    final epoch = ++_searchEpoch;
    final accountKey = widget.accountKey;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final users = await widget.api.searchWorkItemAssigneeCandidates(
        target,
        search: query,
        isCurrent: () =>
            _searchCurrent(epoch) &&
            accountKey == widget.accountKey &&
            identical(widget.access.target, target),
      );
      if (!_searchCurrent(epoch) ||
          _search.text != query ||
          accountKey != widget.accountKey ||
          !identical(widget.access.target, target)) {
        return;
      }
      for (final user in users) {
        _known[user.id] = user;
      }
      setState(() {
        _candidates = users;
        _searchLimited = users.length == 20;
        _searching = false;
      });
    } catch (error) {
      if (!_searchCurrent(epoch) || _search.text != query) return;
      setState(() {
        _searching = false;
        _searchError = safeFailure(error);
      });
    }
  }

  void _toggle(String id, bool selected) {
    if (!_canChange || _writing || _locked || !widget.isCurrent()) return;
    setState(() {
      if (!_snapshot.allowsMultiple) {
        _selected
          ..clear()
          ..add(id);
        return;
      }
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

  bool get _overSingle => !_snapshot.allowsMultiple && _selected.length > 1;

  bool get _unchanged {
    if (_selected.length != _snapshot.users.length) return false;
    return _snapshot.users.every((user) => _selected.contains(user.id));
  }

  Future<void> _save() async {
    final target = widget.access.target;
    if (target == null ||
        !_canChange ||
        _writing ||
        _locked ||
        _overSingle ||
        !widget.isCurrent()) {
      return;
    }
    final epochToken = Object();
    final api = widget.api;
    final accountKey = widget.accountKey;
    var phaseStarted = false;
    setState(() {
      _writing = true;
      _locked = true;
      _saveError = null;
      _phaseToken = epochToken;
    });
    try {
      final saved = await api.updateWorkItemAssignees(
        target,
        assigneeIds: _selected.toList(growable: false),
        isCurrent: () =>
            phaseStarted
                ? widget.operationCurrent()
                : mounted && widget.isCurrent(),
        onMutationSent: () {
          phaseStarted = true;
          widget.onPhase(WorkItemAssigneesWritePhase.start, epochToken);
        },
      );
      if (!mounted || !widget.isCurrent() || !identical(api, widget.api)) {
        return;
      }
      if (accountKey != widget.accountKey) return;
      if (!identical(_phaseToken, epochToken)) return;
      widget.onSaved(saved);
      if (!mounted || !widget.isCurrent()) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      final failure = safeFailure(error);
      setState(() {
        _writing = false;
        _saveError = widget.isCurrent() ? failure : null;
      });
    } finally {
      if (mounted && _writing && widget.isCurrent()) {
        setState(() => _writing = false);
      } else if (mounted && !widget.isCurrent()) {
        setState(() => _writing = false);
      }
      if (phaseStarted && identical(_phaseToken, epochToken)) {
        widget.onPhase(WorkItemAssigneesWritePhase.settle, epochToken);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final multiple = _snapshot.allowsMultiple;
    final rows = <_AssigneeRow>[
      for (final user in _selectedUsers)
        _AssigneeRow(user: user, selected: true, candidate: false),
      for (final user in _candidateRows)
        _AssigneeRow(user: user, selected: false, candidate: true),
    ];
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.assigneesLabel)),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return _header(multiple);
            final row = rows[index - 1];
            return _personRow(row, multiple);
          },
        ),
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              height: _actionHeight,
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('work-item-assignees-save'),
                onPressed: !_canChange || _writing || _locked || _overSingle
                    ? null
                    : _save,
                child: Text(_writing ? l10n.changingInProgress : l10n.saveAction),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(bool multiple) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(multiple ? l10n.multipleAssigneesAllowed : l10n.singleAssigneeOnly),
        if (!_canChange)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              l10n.accountCannotChangeAssignees,
              key: ValueKey('work-item-assignees-readonly'),
            ),
          ),
        if (_overSingle)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(l10n.reduceToOneAssignee),
          ),
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _saveError!.kind == FailureKind.unsupported
                  ? l10n.assigneesChangeUnsupported
                  : l10n.assigneeChangeUnconfirmed,
              key: const ValueKey('work-item-assignees-save-error'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            key: const ValueKey('work-item-assignees-search'),
            controller: _search,
            enabled: widget.access.target != null && !_writing && !_locked,
            scrollPadding: const EdgeInsets.only(bottom: 96),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: l10n.searchPeople,
              border: OutlineInputBorder(),
            ),
            onChanged: _onSearchEdited,
            onSubmitted: (_) => unawaited(_submitSearch()),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('work-item-assignees-search-submit'),
            onPressed: _searching || widget.access.target == null || _locked
                ? null
                : () => unawaited(_submitSearch()),
            child: Text(_searching ? l10n.searching : l10n.search),
          ),
        ),
        if (_searchLimited)
          Text(
            l10n.searchPeopleLimit,
            key: ValueKey('work-item-assignees-search-limit'),
          ),
        if (_searchError != null)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              l10n.assigneeSearchIncomplete,
              key: ValueKey('work-item-assignees-search-failed'),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('work-item-assignees-clear'),
            onPressed: !_canChange || _writing || _locked ? null : _clearAll,
            child: Text(l10n.clearAllAssignees),
          ),
        ),
        Text(_selected.isEmpty ? l10n.noAssigneesSelected : l10n.selectedPeopleCount(_selected.length)),
        if (_unchanged && _searchError != null) Text(l10n.keepAssigneeListAndSave),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _personRow(_AssigneeRow row, bool multiple) {
    final user = row.user;
    final label = user.name.isEmpty
        ? isolated('@${user.username}')
        : isolated('${user.name} · @${user.username}');
    return Semantics(
      key: ValueKey('work-item-assignee-row-${user.id}'),
      button: true,
      enabled: _canChange && !_writing && !_locked,
      checked: row.selected,
      inMutuallyExclusiveGroup: !multiple,
      label: label,
      onTap: !_canChange || _writing || _locked
          ? null
          : () => _toggle(user.id, !row.selected),
      child: ListTile(
        onTap: !_canChange || _writing || _locked
            ? null
            : () => _toggle(user.id, !row.selected),
        title: Text(label),
        subtitle: Text(row.candidate ? l10n.searchResults : l10n.currentAssignees),
        trailing: Icon(
          multiple
              ? row.selected
                    ? Icons.check_box
                    : Icons.check_box_outline_blank
              : row.selected
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
        ),
      ),
    );
  }
}

class _AssigneeRow {
  const _AssigneeRow({
    required this.user,
    required this.selected,
    required this.candidate,
  });

  final WorkItemAssigneeUser user;
  final bool selected;
  final bool candidate;
}
