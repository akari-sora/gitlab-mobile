import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openExternal(BuildContext context, Uri uri) async {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) return;
  try {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無法啟動系統瀏覽器。')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('無法啟動系統瀏覽器。')));
    }
  }
}
