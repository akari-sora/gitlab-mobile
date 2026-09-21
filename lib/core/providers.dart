import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/auth/account_store.dart';
import '../features/auth/recent_project.dart';
import '../features/auth/session_controller.dart';
import '../features/auth/system_browser.dart';
import '../features/shell/app_shortcuts.dart';
import '../features/shell/appearance.dart';

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

final launcherShortcutsProvider = Provider<LauncherShortcuts>((ref) {
  final shortcuts = LauncherShortcuts(QuickActionsHost(), SecureRecentProjectStore());
  ref.onDispose(shortcuts.dispose);
  return shortcuts;
});
