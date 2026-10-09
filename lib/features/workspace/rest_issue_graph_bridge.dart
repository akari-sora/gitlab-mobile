import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/work_item_attribute_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../features/auth/session_controller.dart';
import '../../features/workspace/graph_work_items_page.dart';
import '../../features/workspace/work_item_attributes.dart';
import '../../shared/workspace_ui.dart';

/// Standalone metadata bridge widget mounted beneath the REST issue description.
/// Displays workflow status, parent, start date, and deferred lazy health status
/// and iteration without blocking the primary REST issue view.
class RestIssueGraphBridge extends StatefulWidget {
  const RestIssueGraphBridge({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.iid,
    required this.graphEpoch,
    required this.graphReadyEpoch,
    required this.onOpenEditor,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final int graphEpoch;
  final int graphReadyEpoch;
  final VoidCallback onOpenEditor;

  @override
  State<RestIssueGraphBridge> createState() => _RestIssueGraphBridgeState();
}

class _RestIssueGraphBridgeState extends State<RestIssueGraphBridge> {
  // Identity remounting is handled by parent ValueKey with page generation.
  // No bridge-level _generation counter exists.
  int _handledEpoch = -1;
  int _inFlightEpoch = -1; // Dispatch dedupe marker, reset on predicate-gated completion.

  WorkItemGraphDetail? _detail;
  WorkItemAttributeSnapshot? _status;
  ApiFailure? _cardError;
  ApiFailure? _statusError;

  final Map<String, WorkItemAttributeSnapshot> _lazyValues = {};
  final Map<String, ApiFailure> _lazyErrors = {};
  final Set<String> _inFlightLazy = {};
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _evaluateEpoch();
  }

  @override
  void didUpdateWidget(covariant RestIssueGraphBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.graphEpoch != widget.graphEpoch ||
        oldWidget.graphReadyEpoch != widget.graphReadyEpoch) {
      _evaluateEpoch();
    }
  }

  void _evaluateEpoch() {
    if (widget.graphEpoch != _handledEpoch) {
      _handledEpoch = widget.graphEpoch;
      _detail = null;
      _status = null;
      _cardError = null;
      _statusError = null;
      _lazyValues.clear();
      _lazyErrors.clear();
      _inFlightLazy.clear();
      _expanded = false;
    }
    if (widget.graphReadyEpoch == widget.graphEpoch &&
        _detail == null &&
        _cardError == null &&
        _inFlightEpoch != widget.graphEpoch) {
      _dispatchInitial(widget.graphEpoch);
    }
  }

  ({
    String accountKey,
    GitLabApi api,
    int projectId,
    int iid,
    int graphEpoch,
    int? session,
    SessionController? sessionOwner,
  }) _captureContext(int requestEpoch) {
    SessionController? sessionOwner;
    int? capturedSession;
    try {
      sessionOwner = ProviderScope.containerOf(context, listen: false).read(sessionProvider);
      capturedSession = captureRouteSessionGeneration(
        injected: null,
        owner: sessionOwner,
        account: widget.account,
        api: widget.api,
        isCurrent: () => mounted && identical(widget.api, sessionOwner?.api) && !widget.api.isClosed,
      );
    } catch (_) {
      sessionOwner = null;
      capturedSession = null;
    }
    return (
      accountKey: widget.account.key,
      api: widget.api,
      projectId: widget.project.id,
      iid: widget.iid,
      graphEpoch: requestEpoch,
      session: capturedSession,
      sessionOwner: sessionOwner,
    );
  }

  bool _isCurrent(({
    String accountKey,
    GitLabApi api,
    int projectId,
    int iid,
    int graphEpoch,
    int? session,
    SessionController? sessionOwner,
  }) c) {
    return mounted &&
        widget.account.key == c.accountKey &&
        identical(widget.api, c.api) &&
        !c.api.isClosed &&
        widget.project.id == c.projectId &&
        widget.iid == c.iid &&
        widget.graphEpoch == c.graphEpoch &&
        (c.session == null || routeSessionMatches(c.session, c.sessionOwner, widget.account, widget.api));
  }

  Future<void> _dispatchInitial(int requestEpoch) async {
    final c = _captureContext(requestEpoch);
    _inFlightEpoch = requestEpoch;
    try {
      final detail = await widget.api.projectWorkItem(
        widget.project,
        widget.iid,
        isCurrent: () => _isCurrent(c),
      );
      if (!_isCurrent(c)) return;

      WorkItemAttributeSnapshot? status;
      ApiFailure? statusError;
      if (detail.widgetsAvailable && detail.widgetTypes.contains('STATUS')) {
        try {
          status = await widget.api.workItemAttribute(
            detail.summary,
            WorkItemAttributeKind.status,
            isCurrent: () => _isCurrent(c),
          );
        } catch (e) {
          if (!_isCurrent(c)) return;
          statusError = safeFailure(e);
        }
      }

      if (!_isCurrent(c)) return;
      setState(() {
        _detail = detail;
        _status = status;
        _statusError = statusError;
        _cardError = null;
      });
    } catch (e) {
      if (!_isCurrent(c)) return;
      setState(() {
        _cardError = safeFailure(e);
      });
    } finally {
      if (_isCurrent(c)) {
        _inFlightEpoch = -1;
      }
    }
  }

  Future<void> _dispatchLazyRow(String kind, int requestEpoch) async {
    if (_inFlightLazy.contains(kind)) return;
    _inFlightLazy.add(kind);
    final c = _captureContext(requestEpoch);
    try {
      final detail = _detail;
      if (detail == null) return;
      final attrKind = switch (kind) {
        'HEALTH_STATUS' => WorkItemAttributeKind.health,
        'ITERATION' => WorkItemAttributeKind.iteration,
        _ => throw ArgumentError('Unsupported lazy kind: $kind'),
      };
      final val = await widget.api.workItemAttribute(
        detail.summary,
        attrKind,
        isCurrent: () => _isCurrent(c),
      );
      if (!_isCurrent(c)) return;
      setState(() {
        _lazyValues[kind] = val;
        _lazyErrors.remove(kind);
      });
    } catch (e) {
      if (!_isCurrent(c)) return;
      setState(() {
        _lazyErrors[kind] = safeFailure(e);
      });
    } finally {
      if (_isCurrent(c)) {
        _inFlightLazy.remove(kind);
      }
    }
  }

  void _retryInitial() {
    setState(() {
      _cardError = null;
    });
    _dispatchInitial(widget.graphEpoch);
  }

  void _retryLazy(String kind) {
    setState(() {
      _lazyErrors.remove(kind);
    });
    _dispatchLazyRow(kind, widget.graphEpoch);
  }

  void _toggleExpand() {
    setState(() {
      _expanded = !_expanded;
    });
    if (_expanded) {
      final detail = _detail;
      if (detail != null && detail.widgetsAvailable) {
        if (detail.widgetTypes.contains('HEALTH_STATUS') &&
            !_lazyValues.containsKey('HEALTH_STATUS') &&
            !_lazyErrors.containsKey('HEALTH_STATUS') &&
            !_inFlightLazy.contains('HEALTH_STATUS')) {
          _dispatchLazyRow('HEALTH_STATUS', widget.graphEpoch);
        }
        if (detail.widgetTypes.contains('ITERATION') &&
            !_lazyValues.containsKey('ITERATION') &&
            !_lazyErrors.containsKey('ITERATION') &&
            !_inFlightLazy.contains('ITERATION')) {
          _dispatchLazyRow('ITERATION', widget.graphEpoch);
        }
      }
    }
  }

  static String _healthLabel(String status) => switch (status) {
    'onTrack' => '正常',
    'needsAttention' => '需關注',
    'atRisk' => '有風險',
    _ => status,
  };

  Widget _buildStatusValue() {
    if (_statusError != null) {
      return const Text('無法載入狀態');
    }
    final snapshot = _status;
    if (snapshot == null) {
      return const Text('載入中...');
    }
    if (snapshot.value is WorkItemStatusAttribute) {
      final attr = snapshot.value as WorkItemStatusAttribute;
      final name = attr.status?.name;
      return Text(name ?? '未設定');
    }
    return const Text('未設定');
  }

  Widget _buildHealthValue(WorkItemAttributeSnapshot snapshot) {
    if (snapshot.availability == WorkItemAttributeAvailability.widgetsUnavailable) {
      return const Text('未支援');
    }
    if (snapshot.value is WorkItemHealthAttribute) {
      final attr = snapshot.value as WorkItemHealthAttribute;
      final status = attr.healthStatus;
      final label = status == null ? '未設定' : _healthLabel(status);
      return Text('目前：$label');
    }
    return const Text('目前：未設定');
  }

  Widget _buildIterationValue(WorkItemAttributeSnapshot snapshot) {
    if (snapshot.availability == WorkItemAttributeAvailability.widgetsUnavailable) {
      return const Text('未支援');
    }
    if (snapshot.value is WorkItemIterationAttribute) {
      final attr = snapshot.value as WorkItemIterationAttribute;
      final iteration = attr.iteration;
      if (iteration == null) return const Text('未設定');
      return Text(iteration.title ?? '名稱未知');
    }
    return const Text('未設定');
  }

  Widget _buildLazyRow(
    String kind,
    String label,
    Widget Function(WorkItemAttributeSnapshot) builder,
  ) {
    if (_lazyErrors.containsKey(kind)) {
      return Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Expanded(child: Text('無法載入')),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: '重試',
            onPressed: () => _retryLazy(kind),
          ),
        ],
      );
    }
    final snapshot = _lazyValues[kind];
    if (snapshot == null) {
      return Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Expanded(child: Text('載入中...')),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        Expanded(child: builder(snapshot)),
      ],
    );
  }

  Widget _buildRow(String label, Widget content) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        Expanded(child: content),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_cardError != null) {
      return FailureNotice(
        _cardError!,
        onRetry: _retryInitial,
        account: widget.account,
        resourceLabel: '${widget.project.path} · #${widget.iid} · 工作項目欄位',
        onSwitchAccount: endSessionFrom(
          context,
          ResumeTarget(
            projectId: widget.project.id,
            projectPath: widget.project.path,
            resource: 'issues',
            iid: widget.iid,
          ),
        ),
      );
    }

    final detail = _detail;
    if (detail == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text('工作項目欄位', style: theme.textTheme.titleSmall),
                  TextButton.icon(
                    onPressed: widget.onOpenEditor,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('查看與編輯工作項目欄位'),
                  ),
                ],
              ),
            ),
            if (!detail.widgetsAvailable)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '伺服器未回傳 widgets，無法判定',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              )
            else ...[
              if (detail.widgetTypes.contains('STATUS')) ...[
                const SizedBox(height: 8),
                _buildRow(
                  '工作流程狀態',
                  _buildStatusValue(),
                ),
              ],
              if (detail.hierarchy?.parent != null) ...[
                const SizedBox(height: 8),
                _buildRow(
                  '上層項目',
                  Text('#${detail.hierarchy!.parent!.iid} ${detail.hierarchy!.parent!.title}'),
                ),
              ],
              if (detail.dates?.startDate != null) ...[
                const SizedBox(height: 8),
                _buildRow(
                  '開始日期',
                  Text(workItemAttributeCalendarDate(detail.dates!.startDate!)),
                ),
              ],
              if (detail.widgetTypes.contains('HEALTH_STATUS') ||
                  detail.widgetTypes.contains('ITERATION')) ...[
                const SizedBox(height: 8),
                InkWell(
                  onTap: _toggleExpand,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _expanded ? '收起其他欄位' : '展開其他欄位',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_expanded) ...[
                  if (detail.widgetTypes.contains('HEALTH_STATUS')) ...[
                    const SizedBox(height: 8),
                    _buildLazyRow('HEALTH_STATUS', '健康狀態', _buildHealthValue),
                  ],
                  if (detail.widgetTypes.contains('ITERATION')) ...[
                    const SizedBox(height: 8),
                    _buildLazyRow('ITERATION', '迭代', _buildIterationValue),
                  ],
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}
