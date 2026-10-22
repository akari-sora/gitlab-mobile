import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/ai_report.dart';

enum AiReportRoute { mail, share }

Future<AiReportRoute> sendAiReport({
  required String subject,
  required String body,
  Rect? sharePositionOrigin,
  Future<bool> Function(Uri uri)? launch,
  Future<void> Function(String text, String subject, Rect? origin)? share,
}) async {
  final mailto = aiReportMailto(subject, body);
  if (mailto != null) {
    try {
      final launched = await (launch ?? _launchMail)(mailto);
      if (launched) return AiReportRoute.mail;
    } catch (_) {
      // The share sheet below is the fallback for an unavailable mail app.
    }
  }

  await (share ?? _shareText)(body, subject, sharePositionOrigin);
  return AiReportRoute.share;
}

Future<bool> _launchMail(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<void> _shareText(String text, String subject, Rect? origin) async {
  // Text only, so nothing is copied into share_plus's cache. The subject
  // fills in when the user picks a mail app from the sheet.
  await SharePlus.instance.share(
    ShareParams(text: text, subject: subject, sharePositionOrigin: origin),
  );
}
