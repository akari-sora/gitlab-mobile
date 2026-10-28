import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// The informed-consent explainer before an account's first offline save
/// (§6.3, E19). With [forSave] it asks; the result is the consent time, or
/// null when the user cancelled. Reopened for reading ("詳細說明") it only
/// closes and always returns null.
Future<DateTime?> showOfflineConsent(
  BuildContext context, {
  required String username,
  bool forSave = true,
}) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => OfflineConsentDialog(
      username: username,
      forSave: forSave,
    ),
  );
  return forSave && agreed == true ? DateTime.now().toUtc() : null;
}

class OfflineConsentDialog extends StatelessWidget {
  const OfflineConsentDialog({
    super.key,
    required this.username,
    this.forSave = true,
  });

  final String username;
  final bool forSave;

  @override
  Widget build(BuildContext context) {
    final points = <(IconData, String)>[
      (Icons.lock_outline, l10n.offlineConsentLocalCopy),
      (Icons.person_outline, l10n.offlineConsentAccount(username)),
      (Icons.cloud_off_outlined, l10n.offlineConsentRevocation),
      (Icons.history_toggle_off, l10n.offlineConsentForcePush),
      (Icons.key_outlined, l10n.offlineConsentSecrets),
    ];
    return AlertDialog(
      key: const ValueKey('offline-consent'),
      title: Text(l10n.offlineConsentTitle),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, text) in points)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MergeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: ExcludeSemantics(
                        child: Icon(
                          icon,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(text)),
                  ],
                ),
              ),
            ),
        ],
      ),
      actions: forSave
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancelAction),
              ),
              FilledButton(
                key: const ValueKey('offline-consent-save'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.saveSheetStart),
              ),
            ]
          : [
              FilledButton(
                key: const ValueKey('offline-consent-close'),
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.offlineConsentClose),
              ),
            ],
    );
  }
}
