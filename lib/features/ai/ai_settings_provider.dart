import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_stores.dart';

/// The device-wide AI settings owner. It deliberately lives above the
/// account-keyed authenticated tree so switching accounts keeps provider
/// configuration and provider keys in one process-wide controller.
final aiSettingsProvider = Provider<AiSettingsController>((ref) {
  final settings = AiSettingsController(SecureAiStore());
  ref.onDispose(settings.dispose);
  return settings;
});
