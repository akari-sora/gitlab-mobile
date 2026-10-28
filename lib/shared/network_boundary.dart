import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Where the content below may reach out to the network.
enum NetworkBoundaryMode {
  /// The ordinary signed-in app.
  online,

  /// An offline repository snapshot without an account API client: nothing
  /// below may open the browser, share, download or fetch media (§5.8).
  offlineSnapshot,
}

/// Declares the network boundary for its subtree. Without one the subtree is
/// [NetworkBoundaryMode.online], so existing screens keep their behaviour.
class NetworkBoundary extends InheritedWidget {
  const NetworkBoundary({
    super.key,
    required this.mode,
    required super.child,
  });

  final NetworkBoundaryMode mode;

  static NetworkBoundaryMode modeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NetworkBoundary>()?.mode ??
      NetworkBoundaryMode.online;

  /// Whether outbound actions are refused here.
  static bool blocks(BuildContext context) =>
      modeOf(context) == NetworkBoundaryMode.offlineSnapshot;

  /// Refuses an outbound action without any side effect and tells the user.
  /// Returns true when the action must not run.
  static bool refuse(BuildContext context) {
    if (!blocks(context)) return false;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(l10n.offlineBlockedAction)),
    );
    return true;
  }

  @override
  bool updateShouldNotify(NetworkBoundary oldWidget) => mode != oldWidget.mode;
}
