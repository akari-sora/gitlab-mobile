import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';

typedef WorkItemContentSaved = Future<void> Function();

String? validateWorkItemTitleInput(String value) =>
    value.contains('\u0000') ? '標題包含無法儲存的控制字元' : null;

String? validateWorkItemDescriptionInput(String value) {
  if (value.contains('\u0000')) return '說明包含無法儲存的控制字元';
  if (utf8.encode(value).length > GitLabApi.maxTextBytes) {
    return '說明超過 2 MiB 上限';
  }
  if ('\n'.allMatches(value).length + 1 > GitLabApi.maxTextLines) {
    return '說明超過 20,000 行上限';
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
      '位置未知';

  String get _resourceLabel =>
      '$_scopePath · 工作項目 #${widget.detail.summary.iid}';

  String _subtitle(WorkItemContentSnapshot snapshot) {
    final restriction = switch (snapshot.descriptionAvailability) {
      WorkItemDescriptionAvailability.present => '可編輯標題與 Markdown 說明',
      WorkItemDescriptionAvailability.absent => '這個類型沒有說明欄位，只編輯標題',
      WorkItemDescriptionAvailability.widgetsUnavailable => '伺服器未提供說明元件，只編輯標題',
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
        throw const ApiFailure(
          FailureKind.forbidden,
          title: '無法編輯工作項目',
          detail: '目前帳號可以閱讀，但 GitLab 沒有授予更新權限。',
        );
      }
      final snapshot = access.snapshot;
      final descriptionEditable =
          snapshot.descriptionAvailability ==
          WorkItemDescriptionAvailability.present;
      final fields = <EditField>[
        EditField(
          'title',
          '標題',
          value: snapshot.summary.title,
          required: true,
          maxLength: 4096,
          validator: validateWorkItemTitleInput,
        ),
        if (descriptionEditable)
          EditField(
            'description',
            'Markdown 說明',
            value: snapshot.rawDescription ?? '',
            lines: 10,
            markdown: true,
            hint: '保留原始 Markdown 與空白格式',
            validator: validateWorkItemDescriptionInput,
          ),
      ];
      if (!mounted || !_current(epoch)) return;
      final saved = await openEditor(
        context,
        account: widget.account,
        title: '編輯工作項目',
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
            tooltip: '編輯標題與說明',
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
