import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/workspace_ui.dart';

import '../../l10n/l10n.dart';
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
        l10n.unknownLocation;
    return l10n.notificationWorkItemHeading(path, widget.summary.iid);
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

  ApiFailure get _accountChangedFailure => ApiFailure(
    FailureKind.cancelled,
    title: l10n.gitlabAccountChanged,
    detail: l10n.gitlabAccountMismatch,
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
        title: Text(l10n.notificationSubscription, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(
          subscribed == null
              ? l10n.loadAccountNotificationSettings
              : stale
              ? subscribed
                    ? l10n.lastConfirmedSubscribed
                    : l10n.lastConfirmedUnsubscribed
              : subscribed
              ? l10n.subscribedToWorkItem
              : l10n.notSubscribedToWorkItem,
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
                Text(l10n.subscriptionDoesNotChangeDelivery),
                const SizedBox(height: 12),
                if (_loading)
                  _NotificationProgress(label: l10n.checkingNotificationSubscription)
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
                    label: l10n.loadNotificationSettings,
                  )
                else ...[
                  _NotificationAvailability(access: access),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!.kind == FailureKind.writeUncertain
                          ? l10n.writeDisabledUntilConfirmed
                          : _lastFailureWasRead
                          ? l10n.reloadFailedShowLastState
                          : l10n.errorShowLastConfirmedState(_error!.title),
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
                          ? l10n.updatingNow
                          : subscribed
                          ? l10n.unsubscribeNotifications
                          : l10n.subscribeNotifications,
                      progress: _writing,
                    ),
                  ],
                  if (!access.canAttemptSubscription &&
                      access.availability ==
                          WorkItemNotificationAvailability.present) ...[
                    const SizedBox(height: 8),
                    Text(l10n.unverifiedAccountViewOnly),
                  ],
                  if (stale) ...[
                    const SizedBox(height: 8),
                    _wideButton(
                      onPressed: _writing ? null : _read,
                      icon: Icons.refresh,
                      label: l10n.reloadNotificationSettings,
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
      access.subscribed == true ? l10n.gitlabConfirmedSubscribed : l10n.gitlabConfirmedUnsubscribed,
      key: const ValueKey('work-item-notifications-confirmed'),
    ),
    WorkItemNotificationAvailability.absent => Text(
      l10n.noNotificationSubscriptionField,
      key: ValueKey('work-item-notifications-absent'),
    ),
    WorkItemNotificationAvailability.widgetsUnavailable => Text(
      l10n.notificationWidgetsMissing,
      key: ValueKey('work-item-notifications-widgets-unavailable'),
    ),
  };
}
