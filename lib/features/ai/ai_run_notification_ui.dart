import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../security/app_lock.dart';
import 'ai_chat_session.dart';
import 'ai_run_notifications.dart';

/// The run notifications' text in the current language. Generic work status
/// only: nothing from an account, instance, project, prompt or answer (D10).
/// [AiRunNotifications] reads it again for every notification, so a language
/// change applies to the next one.
AiRunNotificationText aiRunNotificationText() => AiRunNotificationText(
  approvalChannelName: l10n.aiRunNoticeApprovalChannel,
  resultChannelName: l10n.aiRunNoticeResultChannel,
  title: l10n.aiRunNoticeTitle,
  needsApproval: l10n.aiRunNoticeNeedsApproval,
  completed: l10n.aiRunNoticeCompleted,
  failed: l10n.aiRunNoticeFailed,
  interrupted: l10n.aiRunNoticeInterrupted,
);

/// The one gate a tapped run notification passes through, after a cold start
/// and a warm one alike. It lives as long as the process, above the
/// account-keyed tree like the incoming links, so an unlock refused before
/// sign-in still counts.
///
/// The shell asks [take] for a navigation decision and gets one only once the
/// app is resumed and the app lock has loaded and is open (a warm tap can
/// arrive before the lock has decided to lock again). An unlock
/// attempt that ends with the app still locked (cancelled or failed) drops a
/// waiting tap: it never navigates, not even after a later unlock. Nothing
/// here approves a write.
final class AiRunNotificationGate extends ChangeNotifier
    with WidgetsBindingObserver {
  AiRunNotificationGate(this.notifications, {this.lock})
    : _refusals = lock?.refusedUnlocks ?? 0 {
    notifications.addListener(_changed);
    lock?.addListener(_lockChanged);
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
  }

  final AiRunNotifications notifications;
  final AppLockController? lock;
  int _refusals;
  AiRunRegistry? _bound;
  bool _disposed = false;
  AppLifecycleState? _lifecycle;

  /// Whether this process handled the explanation. A failed marker write
  /// allows the next send to retry; the durable request history is C-D8.
  bool permissionAsked = false;
  bool _remindersDisclosed = false;

  /// A tap waits for the shell (and the lock) to take it.
  bool get waiting => !_disposed && notifications.pendingOpen != null;

  bool get _mayNavigate =>
      !_disposed &&
      _lifecycle == AppLifecycleState.resumed &&
      (lock == null || (lock!.loaded && !lock!.locked && !lock!.away));

  /// Recheck after an asynchronous editor exit, immediately before navigation.
  bool canNavigate(AiRunNotificationOpen open) =>
      _mayNavigate && notifications.isCurrentOpen(open);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _changed();
  }

  /// Hands [registry]'s conversations to the notifications. The shell that
  /// created the registry binds it; a later shell may already have bound its
  /// own when the earlier one goes away, so [unbind] only clears its own.
  void bind(AiRunRegistry registry) {
    if (_disposed) return;
    _bound = registry;
    notifications.bindRegistry(registry);
  }

  void unbind(AiRunRegistry registry) {
    if (_disposed || !identical(_bound, registry)) return;
    _bound = null;
    notifications.bindRegistry(null);
  }

  /// The navigation decision for a waiting tap, consumed once. Null while the
  /// lock has not loaded or is closed; the tap then keeps waiting. Call it
  /// synchronously just before navigating.
  AiRunNotificationOpen? take() {
    if (!_mayNavigate) return null;
    final lock = this.lock;
    return notifications.takePendingOpen(
      appLockLoaded: lock?.loaded ?? true,
      appLockUnlocked:
          lock == null || (lock.loaded && !lock.locked && !lock.away),
    );
  }

  void _lockChanged() {
    final refusals = lock!.refusedUnlocks;
    if (refusals != _refusals) {
      _refusals = refusals;
      notifications.discardPendingOpen();
    }
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    notifications.removeListener(_changed);
    lock?.removeListener(_lockChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Makes the [AiRunNotificationGate] reachable from the chat, which asks for
/// the permission. Present only with AI and its notifications.
class AiRunNotificationScope extends InheritedWidget {
  const AiRunNotificationScope({
    super.key,
    required this.gate,
    required super.child,
  });

  final AiRunNotificationGate gate;

  static AiRunNotificationGate? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AiRunNotificationScope>()?.gate;

  @override
  bool updateShouldNotify(AiRunNotificationScope oldWidget) =>
      !identical(gate, oldWidget.gate);
}

/// Before the first run a person starts in this process, which may carry on
/// in the background: explains the run notifications once and asks for the
/// permission. The run starts whatever the answer. Without notifications,
/// [disclose] gets the text saying that no reminder will come and that
/// proposals expire after 30 minutes only when disabled is confirmed; it is
/// called at most once per process. Unknown state never claims reminders off.
/// Does nothing where notifications are not supported (iOS) or not wired.
Future<void> askForAiRunNotifications(
  BuildContext context, {
  required ValueChanged<String> disclose,
}) async {
  final gate = AiRunNotificationScope.maybeOf(context);
  if (gate == null ||
      gate._disposed ||
      gate.permissionAsked ||
      !gate.notifications.supported) {
    return;
  }
  gate.permissionAsked = true;
  void discloseDisabled(AiRunNotificationState state) {
    if (state.approvalRemindersDisabled && !gate._remindersDisclosed) {
      gate._remindersDisclosed = true;
      disclose(l10n.aiRunNoticeDenied);
    }
  }

  final state = await gate.notifications.areNotificationsEnabled();
  if (!context.mounted || gate._disposed) return;
  if (state.appEnabled == true) {
    discloseDisabled(state);
    return;
  }
  final asked = await gate.notifications.wasPermissionAsked();
  if (!context.mounted || gate._disposed) return;
  if (asked) {
    discloseDisabled(state);
    return;
  }
  final proceed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('ai-run-notice-ask'),
      icon: const Icon(Icons.notifications_outlined),
      title: Text(l10n.aiRunNoticeAskTitle),
      content: SingleChildScrollView(child: Text(l10n.aiRunNoticeAskDetail)),
      actions: [
        TextButton(
          key: const ValueKey('ai-run-notice-skip'),
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.aiRunNoticeAskSkip),
        ),
        FilledButton(
          key: const ValueKey('ai-run-notice-continue'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.aiRunNoticeAskContinue),
        ),
      ],
    ),
  );
  if (!context.mounted || gate._disposed) return;
  if (proceed == true) {
    await gate.notifications.requestPermission();
    gate.permissionAsked = await gate.notifications.wasPermissionAsked();
  }
  // Settings can change while the explanation/system prompt is open. Even
  // "not now" must read the actual state before claiming reminders are off.
  final allowed = await gate.notifications.areNotificationsEnabled();
  if (!context.mounted || gate._disposed) return;
  discloseDisabled(allowed);
}
