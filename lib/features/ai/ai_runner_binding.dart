import '../../core/ai/runner.dart';
import '../auth/session_controller.dart';
import 'ai_stores.dart';

/// Connects feature-layer lifecycle notifications to the plain-Dart runner.
///
/// The runner still validates every checkpoint itself. This binding closes a
/// stalled provider request immediately when settings, consent, account
/// generation, or the active API changes between those checkpoints.
final class AiRunnerBinding {
  AiRunnerBinding({
    required this.runner,
    required this.settings,
    required this.session,
  }) {
    settings.addListener(_check);
    session.addListener(_check);
    _check();
  }

  final AiRunner runner;
  final AiSettingsController settings;
  final SessionController session;
  var _disposed = false;

  void _check() {
    if (!_disposed) runner.checkNow();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    settings.removeListener(_check);
    session.removeListener(_check);
  }
}
