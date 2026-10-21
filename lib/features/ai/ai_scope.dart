import 'package:flutter/widgets.dart';

import 'ai_history.dart';
import 'ai_stores.dart';

/// The AI controllers that are either injected together or omitted together.
final class AiControllers {
  const AiControllers({required this.settings, required this.history});

  final AiSettingsController settings;
  final AiHistoryCoordinator history;
}

/// Builds the optional controller bundle without consulting the compile-time
/// gate. Only `main.dart` decides which gate value to pass.
AiControllers? buildAiControllers({
  required bool enabled,
  AiSettingsController? settings,
  AiHistoryCoordinator? history,
}) {
  if (!enabled) return null;
  if (settings == null) {
    throw ArgumentError.notNull('settings');
  }
  return AiControllers(
    settings: settings,
    history: history ?? AiHistoryCoordinator.instance,
  );
}

/// Makes device-wide AI controllers and the current account identity available
/// to routes below the authenticated navigator.
class AiScope extends InheritedNotifier<AiSettingsController> {
  AiScope({
    super.key,
    required this.controllers,
    required this.accountKey,
    required super.child,
  }) : super(notifier: controllers.settings);

  final AiControllers controllers;
  final String accountKey;

  AiSettingsController get settings => controllers.settings;
  AiHistoryCoordinator get history => controllers.history;

  static AiScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'No AiScope found in context');
    return scope!;
  }

  static AiScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AiScope>();

  @override
  bool updateShouldNotify(AiScope oldWidget) =>
      accountKey != oldWidget.accountKey ||
      controllers.settings != oldWidget.controllers.settings ||
      controllers.history != oldWidget.controllers.history ||
      super.updateShouldNotify(oldWidget);
}
