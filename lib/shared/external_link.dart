import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import 'network_boundary.dart';
/// Whether [uri] may be handed to the system browser: HTTPS, no user info and
/// no credential-looking query keys.
bool safeExternalUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    !uri.queryParameters.keys.any((key) => const ['private_token', 'access_token', 'token', 'job_token'].contains(key.toLowerCase()));

Future<void> openExternal(BuildContext context, Uri uri) async {
  if (!safeExternalUri(uri)) return;
  // An offline snapshot never hands an address to the browser (§5.8).
  if (NetworkBoundary.refuse(context)) return;
  try {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.cannotOpenSystemBrowser)));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.cannotOpenSystemBrowser)));
    }
  }
}
