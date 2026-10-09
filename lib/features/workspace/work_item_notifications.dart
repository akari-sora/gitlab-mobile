import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/workspace_ui.dart';

/// A lazy, account-bound control for the current actor's Work Item
/// notification subscription.
class WorkItemNotificationsControl extends StatefulWidget {
  const WorkItemNotificationsControl({
    super.key,
    required this.account,
    required this.api,
    required this.summary,
    this.isCurrent,
    this.ownerChanges,
  });

  final Account account;
  final GitLabApi api;
  final WorkItemGraphSummary summary;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  State<WorkItemNotificationsControl> createState() =>
      _WorkItemNotificationsControlState();
}

class _WorkItemNotificationsControlState
    extends State<WorkItemNotificationsControl> {
  WorkItemNotificationAccess? _access;
  ApiFailure? _error;
  bool _expanded = false;
  bool _loading = false;
  bool _writing = false;
  bool _uncertain = false;
  bool _lastFailureWasRead = false;
  int _epoch = 0;

  bool _current(int epoch) =>
      mounted && epoch == _epoch && (widget.isCurrent?.call() ?? true);

  String get _resourceLabel {
    final path =
        widget.summary.project?.fullPath ??
        widget.summary.namespace?.fullPath ??
        '位置未知';
    return '$path · 工作項目 #${widget.summary.iid}';
  }

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkItemNotificationsControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    final old = oldWidget.summary;
    final next = widget.summary;
    final ownerOrResourceChanged =
        oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        old.id != next.id ||
        old.iid != next.iid ||
        old.project?.id != next.project?.id ||
        old.project?.fullPath != next.project?.fullPath ||
        old.namespace?.id != next.namespace?.id ||
        old.namespace?.fullPath != next.namespace?.fullPath ||
        old.type.id != next.type.id;
    if (ownerOrResourceChanged) {
      _invalidate();
      if (_expanded) unawaited(_read());
    } else if (old.state != next.state || old.updatedAt != next.updatedAt) {
      _refreshBinding();
      if (_expanded) unawaited(_read());
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
    _access = null;
    _error = null;
    _loading = false;
    _writing = false;
    _uncertain = false;
    _lastFailureWasRead = false;
    if (mounted) setState(() {});
  }

  void _refreshBinding() {
    _epoch++;
    _error = null;
    _loading = false;
    _writing = false;
    _uncertain = _access != null;
    _lastFailureWasRead = false;
    if (mounted) setState(() {});
  }

  ApiFailure get _accountChangedFailure => const ApiFailure(
    FailureKind.cancelled,
    title: 'GitLab 登入帳號已變更',
    detail: '伺服器目前的登入帳號與這個工作項目頁面的帳號不一致。請切換帳號或重新開啟工作項目。',
  );

  Future<void> _read() async {
    if (_loading || _writing || !(widget.isCurrent?.call() ?? true)) return;
    final epoch = _epoch;
    final hadConfirmedState = _access != null;
    setState(() {
      _loading = true;
      _error = null;
      _lastFailureWasRead = false;
    });
    try {
      final access = await widget.api.workItemNotifications(
        widget.summary,
        expectedUserId: widget.account.user.id,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      setState(() {
        _access = access;
        _error = null;
        _uncertain = false;
        _lastFailureWasRead = false;
      });
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      setState(() {
        _lastFailureWasRead = true;
        if (failure.kind == FailureKind.cancelled ||
            failure.kind == FailureKind.unauthenticated) {
          _access = null;
          _error = failure.kind == FailureKind.cancelled
              ? _accountChangedFailure
              : failure;
          _uncertain = true;
          return;
        }
        _error = failure;
        // A failed refresh keeps the last confirmed state visible, but its
        // single-use target is stale and must never remain actionable.
        if (hadConfirmedState) _uncertain = true;
      });
    } finally {
      if (_current(epoch)) setState(() => _loading = false);
    }
  }

  Future<void> _setSubscribed(bool subscribed) async {
    final access = _access;
    final target = access?.target;
    if (access == null ||
        target == null ||
        !access.canAttemptSubscription ||
        _loading ||
        _writing ||
        _uncertain ||
        !(widget.isCurrent?.call() ?? true)) {
      return;
    }
    final epoch = _epoch;
    setState(() {
      _writing = true;
      _error = null;
      _lastFailureWasRead = false;
    });
    try {
      final updated = await widget.api.setWorkItemNotifications(
        target,
        subscribed: subscribed,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch)) return;
      setState(() {
        _access = updated;
        _error = null;
        _uncertain = false;
        _lastFailureWasRead = false;
      });
    } catch (error) {
      if (!_current(epoch)) return;
      final failure = safeFailure(error);
      setState(() {
        if (failure.kind == FailureKind.cancelled ||
            failure.kind == FailureKind.unauthenticated) {
          _access = null;
          _error = failure.kind == FailureKind.cancelled
              ? _accountChangedFailure
              : failure;
          _uncertain = true;
          _lastFailureWasRead = false;
          return;
        }
        _error = failure;
        // Every mutation target is consumed even when GitLab rejects it. A
        // manual read is required before another attempt.
        _uncertain = true;
      });
    } finally {
      if (_current(epoch)) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final access = _access;
    final subscribed = access?.subscribed;
    final stale = _uncertain || _error != null;
    return Card(
      key: const ValueKey('work-item-notifications-control'),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('work-item-notifications-expansion'),
        title: Text('通知訂閱', style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(
          subscribed == null
              ? '依目前帳號讀取 GitLab 通知設定'
              : stale
              ? subscribed
                    ? '上次確認：已訂閱這個工作項目'
                    : '上次確認：尚未訂閱這個工作項目'
              : subscribed
              ? '已訂閱這個工作項目'
              : '尚未訂閱這個工作項目',
        ),
        onExpansionChanged: (expanded) {
          _expanded = expanded;
          if (expanded && _access == null && !_loading && _error == null) {
            unawaited(_read());
          }
        },
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '@${widget.account.user.username} · ${widget.account.instance.key}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  _resourceLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                const Text('這只變更你對此工作項目的訂閱；通知頻率與傳送方式仍由 GitLab 的通知設定決定。'),
                const SizedBox(height: 12),
                if (_loading)
                  const _NotificationProgress(label: '正在確認通知訂閱…')
                else if (access == null && _error != null)
                  FailureNotice(
                    _error!,
                    key: const ValueKey('work-item-notifications-failure'),
                    account: widget.account,
                    resourceLabel: _resourceLabel,
                    onRetry: _read,
                    onSwitchAccount: endSessionFrom(context),
                  )
                else if (access == null)
                  _wideButton(
                    onPressed: _read,
                    icon: Icons.notifications_outlined,
                    label: '讀取通知設定',
                  )
                else ...[
                  _NotificationAvailability(access: access),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!.kind == FailureKind.writeUncertain
                          ? '操作結果尚未確認，已停用再次寫入。'
                          : _lastFailureWasRead
                          ? '重新讀取失敗；仍顯示上次確認的狀態，已停用變更。'
                          : '${_error!.title}；仍顯示上次確認的狀態，已停用變更。請先重新讀取再操作。',
                      key: const ValueKey('work-item-notifications-stale'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(_error!.detail),
                  ],
                  if (access.availability ==
                          WorkItemNotificationAvailability.present &&
                      subscribed != null) ...[
                    const SizedBox(height: 12),
                    _wideButton(
                      onPressed:
                          access.canAttemptSubscription && !stale && !_writing
                          ? () => unawaited(_setSubscribed(!subscribed))
                          : null,
                      icon: _writing
                          ? null
                          : subscribed
                          ? Icons.notifications_off_outlined
                          : Icons.notifications_active_outlined,
                      label: _writing
                          ? '正在更新…'
                          : subscribed
                          ? '取消訂閱通知'
                          : '訂閱通知',
                      progress: _writing,
                    ),
                  ],
                  if (!access.canAttemptSubscription &&
                      access.availability ==
                          WorkItemNotificationAvailability.present) ...[
                    const SizedBox(height: 8),
                    const Text('目前沒有已驗證的登入帳號，因此只能查看通知狀態。'),
                  ],
                  if (stale) ...[
                    const SizedBox(height: 8),
                    _wideButton(
                      onPressed: _writing ? null : _read,
                      icon: Icons.refresh,
                      label: '重新讀取通知設定',
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideButton({
    required VoidCallback? onPressed,
    required IconData? icon,
    required String label,
    bool progress = false,
  }) => SizedBox(
    width: double.infinity,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        child: Row(
          children: [
            if (progress)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon),
            const SizedBox(width: 8),
            Expanded(child: Text(label, textAlign: TextAlign.center)),
            const SizedBox(width: 32),
          ],
        ),
      ),
    ),
  );
}

class _NotificationProgress extends StatelessWidget {
  const _NotificationProgress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(label)),
    ],
  );
}

class _NotificationAvailability extends StatelessWidget {
  const _NotificationAvailability({required this.access});

  final WorkItemNotificationAccess access;

  @override
  Widget build(BuildContext context) => switch (access.availability) {
    WorkItemNotificationAvailability.present => Text(
      access.subscribed == true ? 'GitLab 已確認：目前已訂閱。' : 'GitLab 已確認：目前未訂閱。',
      key: const ValueKey('work-item-notifications-confirmed'),
    ),
    WorkItemNotificationAvailability.absent => const Text(
      '這個工作項目沒有通知訂閱欄位，因此目前只能閱讀。',
      key: ValueKey('work-item-notifications-absent'),
    ),
    WorkItemNotificationAvailability.widgetsUnavailable => const Text(
      'GitLab 未回傳工作項目 widgets，無法判定通知訂閱狀態。',
      key: ValueKey('work-item-notifications-widgets-unavailable'),
    ),
  };
}
