import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';

import '../../l10n/l10n.dart';
typedef WorkItemContentSaved = Future<void> Function();

String? validateWorkItemTitleInput(String value) =>
    value.contains('\u0000') ? l10n.titleControlCharacters : null;

String? validateWorkItemDescriptionInput(String value) {
  if (value.contains('\u0000')) return l10n.descriptionControlCharacters;
  if (utf8.encode(value).length > GitLabApi.maxTextBytes) {
    return l10n.descriptionSizeLimit;
  }
  if ('\n'.allMatches(value).length + 1 > GitLabApi.maxTextLines) {
    return l10n.descriptionLineLimit;
  }
  return null;
}

/// Opens a fresh, actor-bound content snapshot only when the user requests an
/// edit. The detail page therefore stays read-only and cheap until this action
/// is used.
class WorkItemContentControl extends StatefulWidget {
  const WorkItemContentControl({
    super.key,
    required this.account,
    required this.api,
    required this.detail,
    required this.onSaved,
    this.project,
    this.isCurrent,
    this.ownerChanges,
    this.onRoute,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphDetail detail;
  final Project? project;
  final WorkItemContentSaved onSaved;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final ValueChanged<Route<dynamic>>? onRoute;

  @override
  State<WorkItemContentControl> createState() => _WorkItemContentControlState();
}

class _WorkItemContentControlState extends State<WorkItemContentControl> {
  ApiFailure? _error;
  bool _opening = false;
  int _epoch = 0;

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemContentControl oldWidget) {
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
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _invalidate();
  }

  void _invalidate() {
    _epoch++;
    _opening = false;
    _error = null;
    if (mounted) setState(() {});
  }

  String get _scopePath =>
      widget.detail.summary.project?.fullPath ??
      widget.detail.summary.namespace?.fullPath ??
      l10n.unknownLocation;

  String get _resourceLabel =>
      l10n.workItemScopeHeading(_scopePath, widget.detail.summary.iid);

  String _subtitle(WorkItemContentSnapshot snapshot) {
    final restriction = switch (snapshot.descriptionAvailability) {
      WorkItemDescriptionAvailability.present => l10n.canEditTitleAndDescription,
      WorkItemDescriptionAvailability.absent => l10n.typeHasNoDescription,
      WorkItemDescriptionAvailability.widgetsUnavailable => l10n.descriptionWidgetMissing,
    };
    return '@${widget.account.user.username} · ${widget.account.instance.key}\n'
        '$_resourceLabel · $restriction';
  }

  Future<void> _open() async {
    if (_opening || !(widget.isCurrent?.call() ?? true)) return;
    final epoch = _epoch;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final access = await widget.api.workItemContent(
        widget.detail,
        expectedUserId: widget.account.user.id,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      final target = access.target;
      if (!access.canUpdate || target == null) {
        throw ApiFailure(
          FailureKind.forbidden,
          title: l10n.cannotEditWorkItem,
          detail: l10n.updatePermissionDenied,
        );
      }
      final snapshot = access.snapshot;
      final descriptionEditable =
          snapshot.descriptionAvailability ==
          WorkItemDescriptionAvailability.present;
      final fields = <EditField>[
        EditField(
          'title',
          l10n.title,
          value: snapshot.summary.title,
          required: true,
          maxLength: 4096,
          validator: validateWorkItemTitleInput,
        ),
        if (descriptionEditable)
          EditField(
            'description',
            l10n.markdownDescription,
            value: snapshot.rawDescription ?? '',
            lines: 10,
            markdown: true,
            hint: l10n.preserveMarkdownWhitespace,
            validator: validateWorkItemDescriptionInput,
          ),
      ];
      if (!mounted || !_current(epoch)) return;
      final saved = await openEditor(
        context,
        account: widget.account,
        title: l10n.editWorkItem,
        subtitle: _subtitle(snapshot),
        resource:
            'work-item-content:${snapshot.summary.project?.id ?? snapshot.summary.namespace?.id}:${snapshot.summary.id}',
        resourceLabel: _resourceLabel,
        baseRevision: snapshot.summary.updatedAt.toUtc().toIso8601String(),
        fields: fields,
        blockRetryOnSaveFailure: true,
        projectToolsEnabled: descriptionEditable && widget.project != null,
        api: widget.api,
        projectId: widget.project?.id,
        projectPath: widget.project?.path,
        isCurrent: () => _current(epoch),
        onRoute: widget.onRoute,
        save: (values) async {
          await widget.api.updateWorkItemContent(
            target,
            title: values['title'] ?? '',
            description: descriptionEditable
                ? values['description'] ?? ''
                : null,
            isCurrent: () => _current(epoch),
          );
        },
      );
      if (!_current(epoch) || !saved) return;
      await widget.onSaved();
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
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectionArea(
              child: Text(
                widget.detail.summary.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('work-item-content-edit'),
            onPressed: _opening ? null : _open,
            tooltip: l10n.editTitleAndDescription,
            icon: _opening
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        FailureNotice(
          _error!,
          key: const ValueKey('work-item-content-failure'),
          account: widget.account,
          resourceLabel: _resourceLabel,
          onRetry: _opening ? null : _open,
          onSwitchAccount: endSessionFrom(context),
        ),
      ],
    ],
  );
}
