import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/instance.dart';
import '../../core/instance_ca.dart';
import '../../shared/hub_ui.dart';
import '../../shared/workspace_ui.dart';
import '../workspace/attachment_picker.dart' show discardPickedCopy;
import 'session_controller.dart';

import '../../l10n/l10n.dart';

/// A certificate file the user picked; the plugin's copy is already gone.
final class PickedCaFile {
  const PickedCaFile({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

abstract interface class CaCertificatePicker {
  /// Null when the user cancelled. Throws [CaCertificateFailure] for a file
  /// over [maxCaCertificateBytes].
  Future<PickedCaFile?> pick();
}

/// file_picker with any file type: Android has no stable MIME type for
/// `.pem`, so the content decides (PEM or DER, see [parseCaCertificate]).
final class PluginCaCertificatePicker implements CaCertificatePicker {
  const PluginCaCertificatePicker();

  @override
  Future<PickedCaFile?> pick() async {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    try {
      final length = file.lengthSync();
      if (length != null && length > maxCaCertificateBytes) {
        throw const CaCertificateFailure(CaCertificateProblem.tooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (bytes.length + chunk.length > maxCaCertificateBytes) {
          throw const CaCertificateFailure(CaCertificateProblem.tooLarge);
        }
        bytes.add(chunk);
      }
      final name = file.name.trim().split(RegExp(r'[\\/]')).last.trim();
      return PickedCaFile(name: name, bytes: bytes.takeBytes());
    } finally {
      await discardPickedCopy(file.path);
    }
  }
}

/// Picks a file, parses it and asks the user to confirm its fingerprint for
/// [untrusted]'s instance. Returns the confirmed certificate, which is not
/// stored yet ([SessionController.importInstanceCa] stores it and retries),
/// or null. Failures are shown here. Never offered for GitLab.com.
Future<InstanceCaCertificate?> pickAndConfirmInstanceCa(
  BuildContext context, {
  required SessionController session,
  required UntrustedInstance untrusted,
  required CaCertificatePicker picker,
}) async {
  if (untrusted.instance.isGitLabCom) return null;
  try {
    final picked = await picker.pick();
    if (picked == null || !context.mounted) return null;
    final certificate = parseCaCertificate(picked.bytes);
    final confirmed = await confirmInstanceCa(
      context,
      instance: untrusted.instance,
      fileName: picked.name,
      certificate: certificate,
      refused: untrusted.certificate,
      current: session.trust.certificateFor(untrusted.instance),
    );
    return confirmed && context.mounted ? certificate : null;
  } on Object catch (error) {
    if (context.mounted) showFailure(context, error);
    return null;
  }
}

/// Shows the file name and the SHA-256 fingerprint of each certificate, and
/// what the server presented when the handshake reported it. When [current]
/// is a different stored CA, warns that it is being replaced and shows its
/// fingerprint: an unexpected replacement can mean interception.
Future<bool> confirmInstanceCa(
  BuildContext context, {
  required GitLabInstance instance,
  required String fileName,
  required InstanceCaCertificate certificate,
  RefusedCertificate? refused,
  InstanceCaCertificate? current,
}) async {
  final replacing = current != null && current != certificate;
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final mono = theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Menlo', 'Roboto Mono', 'Courier'],
      );
      Widget field(String label, Widget value) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(height: 2),
            value,
          ],
        ),
      );
      return AlertDialog(
        title: Text(l10n.caImportConfirmTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.caImportConfirmDetail(instance.base.host)),
              if (replacing) ...[
                const SizedBox(height: 12),
                Row(
                  key: const ValueKey('instance-ca-replace-warning'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.caReplaceWarning,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
                for (final (index, fingerprint) in current.fingerprints.indexed)
                  field(
                    l10n.caCurrentFingerprintLabel,
                    SelectableText(
                      fingerprint,
                      key: ValueKey('instance-ca-current-fingerprint-$index'),
                      style: mono,
                    ),
                  ),
              ],
              if (fileName.isNotEmpty)
                field(l10n.caFileLabel, Text(isolated(fileName))),
              for (final (index, fingerprint)
                  in certificate.fingerprints.indexed)
                field(
                  l10n.caFingerprintLabel,
                  SelectableText(
                    fingerprint,
                    key: ValueKey('instance-ca-fingerprint-$index'),
                    style: mono,
                  ),
                ),
              if (refused != null) ...[
                field(
                  l10n.caServerSubjectLabel,
                  Text(isolated(refused.subject)),
                ),
                field(l10n.caServerIssuerLabel, Text(isolated(refused.issuer))),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            key: const Key('confirmInstanceCa'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.caTrustAndRetry),
          ),
        ],
      );
    },
  );
  return answer ?? false;
}

/// 我的 › 帳號: one row per imported CA, with or without a saved account,
/// showing its fingerprint, with a confirmed remove action.
///
/// Removing the CA of the signed-in instance checks the account again
/// without it ([reselect], or `session.select` when absent), so the removed
/// CA stops being trusted at once rather than at the next sign-in.
class InstanceCaRows extends StatelessWidget {
  const InstanceCaRows({
    super.key,
    required this.session,
    this.locked = false,
    this.reselect,
  });
  final SessionController session;
  final bool locked;

  /// Runs [action] (remove, then check the account again) through the
  /// shell's leave confirmations; the shell passes its `_leave`.
  final Future<void> Function(Future<void> Function() action)? reselect;

  Future<void> _remove(BuildContext context, GitLabInstance instance) async {
    final active = session.active;
    final signedIn = active != null && active.instance.key == instance.key;
    final confirmed = await confirmAction(
      context,
      l10n.removeCustomCaTitle,
      [
        l10n.removeCustomCaDetail(instance.base.host),
        if (signedIn) l10n.removeCustomCaSignInAgain,
      ].join('\n\n'),
      confirmLabel: l10n.removeCustomCaAction,
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Future<void> removeCa() async {
      try {
        await session.trust.remove(instance);
        messenger?.showSnackBar(
          SnackBar(content: LiveText(() => l10n.customCaRemoved)),
        );
      } on Object catch (error) {
        if (context.mounted) showFailure(context, error);
      }
    }

    if (!signedIn) {
      await removeCa();
      return;
    }
    Future<void> removeAndCheckAgain() async {
      await removeCa();
      // A new client for the same account, built without the removed CA.
      if (session.active?.key == active.key) await session.select(active);
    }

    final leave = reselect;
    await (leave == null ? removeAndCheckAgain() : leave(removeAndCheckAgain));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([session, session.trust]),
    builder: (context, _) {
      final instances = <String, GitLabInstance>{
        for (final key in session.trust.instanceKeys.toList()..sort())
          key: ?_parse(key),
      };
      if (instances.isEmpty) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final muted = theme.colorScheme.onSurfaceVariant;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final instance in instances.values)
            ListTile(
              key: ValueKey('instance-ca-${instance.key}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const IconTile(
                Icons.verified_user_outlined,
                color: HubColors.teal,
              ),
              title: Text(l10n.customCaCertificate),
              subtitle: Text(
                '${isolated(instance.base.host)}\n'
                '${session.trust.certificateFor(instance)!.fingerprint}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              isThreeLine: true,
              trailing: IconButton(
                key: ValueKey('remove-instance-ca-${instance.key}'),
                tooltip: l10n.removeCustomCaTooltip,
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: locked || session.busy
                    ? null
                    : () => unawaited(_remove(context, instance)),
              ),
            ),
        ],
      );
    },
  );

  static GitLabInstance? _parse(String key) {
    try {
      return GitLabInstance.parse(key);
    } on FormatException {
      return null;
    }
  }
}
