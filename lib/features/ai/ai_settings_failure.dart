import 'package:flutter/material.dart';

import '../../core/ai/ai_failure.dart';
import '../../core/failure.dart';
import '../../l10n/l10n.dart';
import '../../shared/workspace_ui.dart';
import 'ai_stores.dart';

/// Storage errors belong to AI setup, and never use GitLab response wording.
void showAiSettingsFailure(BuildContext context, Object error) {
  if (error is AiStoreException) {
    showFailure(context, AiSettingsFailure(error.failure.kind));
  } else if (error is UserFacingFailure) {
    showFailure(context, error);
  } else {
    showFailure(context, const AiFailure(AiFailureKind.invalidResponse));
  }
}

final class AiSettingsFailure implements Exception, UserFacingFailure {
  const AiSettingsFailure(this.kind);

  final AiStoreFailureKind kind;

  @override
  String get title => l10n.aiProviderSaveFailure;

  @override
  String get detail => switch (kind) {
    AiStoreFailureKind.cleaning => l10n.aiHistoryCleaning,
    AiStoreFailureKind.unavailable => l10n.aiSettingsReadFailure,
    AiStoreFailureKind.malformed => l10n.aiSettingsReadFailure,
    AiStoreFailureKind.invalidValue => l10n.aiSettingsInvalidValue,
    AiStoreFailureKind.confirmationRequired =>
      l10n.aiSettingsConfirmationRequired,
  };
}
