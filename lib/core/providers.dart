import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/auth/account_store.dart';
import '../features/auth/session_controller.dart';

final sessionProvider = Provider<SessionController>((ref) {
  final session = SessionController(SecureAccountStore());
  ref.onDispose(session.dispose);
  return session;
});
