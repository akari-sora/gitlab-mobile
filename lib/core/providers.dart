import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/auth/account_store.dart';
import '../features/auth/recent_project.dart';
import '../features/auth/session_controller.dart';
import '../features/auth/system_browser.dart';
import '../features/shell/app_shortcuts.dart';
import '../features/shell/appearance.dart';
import '../features/update/app_update.dart';
import '../features/update/update_controller.dart';
import 'anonymous_api.dart';

final sessionProvider = Provider<SessionController>((ref) {
  final session = SessionController(
    SecureAccountStore(),
    browser: SystemAuthorizationBrowser(),
  );
  ref.onDispose(session.dispose);
  return session;
});

final appearanceProvider = Provider<AppearanceController>((ref) {
  final appearance = AppearanceController(SecureAppearanceStore());
  ref.onDispose(appearance.dispose);
  return appearance;
});

/// Device-wide, like the appearance: it outlives account switches.
final appUpdateProvider = Provider<AppUpdateController>((ref) {
  final updates = AppUpdateController(
    channel: currentUpdateChannel,
    store: SecureUpdatePreferenceStore(),
    api: () => anonymousGitLabApi(updateInstance),
  );
  ref.onDispose(updates.dispose);
  return updates;
});

final launcherShortcutsProvider = Provider<LauncherShortcuts>((ref) {
  final shortcuts = LauncherShortcuts(QuickActionsHost(), SecureRecentProjectStore());
  ref.onDispose(shortcuts.dispose);
  return shortcuts;
});
