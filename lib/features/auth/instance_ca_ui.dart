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

/// Picks a file, parses it, asks the user to confirm the fingerprint and
/// stores it for [untrusted]'s instance. True once stored; the caller then
/// repeats the operation. Failures are shown here.
Future<bool> importInstanceCa(
  BuildContext context, {
  required SessionController session,
  required UntrustedInstance untrusted,
  required CaCertificatePicker picker,
}) async {
  try {
    final picked = await picker.pick();
    if (picked == null || !context.mounted) return false;
    final certificate = parseCaCertificate(picked.bytes);
    final confirmed = await confirmInstanceCa(
      context,
      instance: untrusted.instance,
      fileName: picked.name,
      certificate: certificate,
      refused: untrusted.certificate,
    );
    if (!confirmed || !context.mounted || session.busy) return false;
    await session.importInstanceCa(untrusted.instance, certificate);
    return session.trust.certificateFor(untrusted.instance) == certificate;
  } on Object catch (error) {
    if (context.mounted) showFailure(context, error);
    return false;
  }
}

/// Shows the file name and the SHA-256 fingerprint of each certificate, and
/// what the server presented when the handshake reported it.
Future<bool> confirmInstanceCa(
  BuildContext context, {
  required GitLabInstance instance,
  required String fileName,
  required InstanceCaCertificate certificate,
  RefusedCertificate? refused,
}) async {
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

/// 我的 › 帳號: one row per saved instance with an imported CA, showing its
/// fingerprint, with a confirmed remove action.
class InstanceCaRows extends StatelessWidget {
  const InstanceCaRows({super.key, required this.session, this.locked = false});
  final SessionController session;
  final bool locked;

  Future<void> _remove(BuildContext context, GitLabInstance instance) async {
    final confirmed = await confirmAction(
      context,
      l10n.removeCustomCaTitle,
      l10n.removeCustomCaDetail(instance.base.host),
      confirmLabel: l10n.removeCustomCaAction,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await session.trust.remove(instance);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LiveText(() => l10n.customCaRemoved)));
      }
    } on Object catch (error) {
      if (context.mounted) showFailure(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([session, session.trust]),
    builder: (context, _) {
      final instances = <String, GitLabInstance>{
        for (final saved in session.accounts)
          if (session.trust.certificateFor(saved.instance) != null)
            saved.instance.key: saved.instance,
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
}
