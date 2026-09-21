import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/auth/account_store.dart';
import '../features/auth/session_controller.dart';
import '../features/auth/system_browser.dart';

final sessionProvider = Provider<SessionController>((ref) {
  final session = SessionController(
    SecureAccountStore(),
    browser: SystemAuthorizationBrowser(),
  );
  ref.onDispose(session.dispose);
  return session;
});
