import '../brand.dart';

enum AiReportCategory { harmful, inaccurate, privacy, other }

/// The developer's Google Form that takes reports inside the app, as Play's
/// generative-AI policy asks: reporting without leaving the app. The entry
/// IDs are the form's own question IDs.
final aiReportFormEndpoint = Uri.parse(
  'https://docs.google.com/forms/d/e/1FAIpQLScaYt4bgLaArUMkzdFW5mBWSCK_ATRYfbLcSbL_3mrD4eKYDg/formResponse',
);
const aiReportReasonEntry = 'entry.383596251';
const aiReportDetailsEntry = 'entry.1990565550';
const aiReportExcerptEntry = 'entry.1603202973';
const aiReportAppEntry = 'entry.441670215';

/// The longest attached response a report carries, in UTF-16 code units.
const aiReportExcerptLimit = 4000;

final class AiReport {
  const AiReport({
    required this.category,
    required this.description,
    required this.appVersion,
    required this.presetId,
    required this.format,
    required this.model,
    required this.time,
    required this.messageIndex,
    this.response,
  });

  final AiReportCategory category;
  final String description;
  final String appVersion;
  final String presetId;
  final String format;
  final String model;
  final DateTime time;
  final int messageIndex;
  final String? response;
}

/// Builds the plain-text payload shown to the user before a report is sent.
String aiReportBody(AiReport report, {required String sendToLine}) {
  final body = StringBuffer()
    ..writeln(sendToLine)
    // The translated line wraps the address in direction isolates in right
    // to left languages; this one copies cleanly into a recipient field.
    ..writeln('to: $aiReportEmail')
    ..writeln('category: ${report.category.name}')
    ..writeln('description: ${_singleLine(report.description)}')
    ..writeln('app: ${_singleLine(report.appVersion)}')
    ..writeln('preset: ${_singleLine(report.presetId)}')
    ..writeln('format: ${_singleLine(report.format)}')
    ..writeln('model: ${_singleLine(report.model)}')
    ..writeln('time: ${report.time.toUtc().toIso8601String()}')
    ..write('message: ${report.messageIndex}');
  final response = report.response;
  if (response != null) {
    body
      ..writeln()
      ..writeln('---')
      ..write(_excerpt(_multiline(response)));
  }
  return body.toString();
}

/// The answers the developer's form receives: what the report preview
/// shows, and nothing else.
final class AiReportFormFields {
  const AiReportFormFields({
    required this.reason,
    required this.details,
    required this.excerpt,
    required this.app,
  });

  /// The category's name, such as `harmful`.
  final String reason;

  /// The user's description, then the preset, format, model, time and
  /// message number, one line each.
  final String details;

  /// The attached response, at most [aiReportExcerptLimit] long; empty when
  /// none is attached.
  final String excerpt;

  /// The app version.
  final String app;

  /// The url-encoded form body, keyed by the form's entry IDs.
  Map<String, String> get form => {
    aiReportReasonEntry: reason,
    aiReportDetailsEntry: details,
    aiReportExcerptEntry: excerpt,
    aiReportAppEntry: app,
  };

  /// Each answer passed through [check] (the live-secret redaction) on its
  /// own. Null when one could not be checked: [check] returns an empty
  /// string for a value it cannot check.
  AiReportFormFields? checked(String Function(String value) check) {
    String? safe(String value) {
      if (value.isEmpty) return value;
      final checked = check(value);
      return checked.isEmpty ? null : checked;
    }

    final reason = safe(this.reason);
    final details = safe(this.details);
    final excerpt = safe(this.excerpt);
    final app = safe(this.app);
    if (reason == null || details == null || excerpt == null || app == null) {
      return null;
    }
    return AiReportFormFields(
      reason: reason,
      details: details,
      excerpt: excerpt,
      app: app,
    );
  }

  /// Whether every answer reads, unchanged, in [text]: the preview the user
  /// confirmed.
  bool shownIn(String text) =>
      [reason, details, excerpt, app].every(text.contains);
}

/// Builds the form's answers with the same clean-up as [aiReportBody]. Only
/// the report's own values go in; the account, the instance and the project
/// are not part of a report.
AiReportFormFields aiReportFormFields(AiReport report) {
  final details = StringBuffer()
    ..writeln('description: ${_singleLine(report.description)}')
    ..writeln('preset: ${_singleLine(report.presetId)}')
    ..writeln('format: ${_singleLine(report.format)}')
    ..writeln('model: ${_singleLine(report.model)}')
    ..writeln('time: ${report.time.toUtc().toIso8601String()}')
    ..write('message: ${report.messageIndex}');
  final response = report.response;
  return AiReportFormFields(
    reason: report.category.name,
    details: details.toString(),
    excerpt: response == null ? '' : _excerpt(_multiline(response)),
    app: _singleLine(report.appVersion),
  );
}

/// The preview of a form report: each answer under its label.
String aiReportFormText(AiReportFormFields fields) {
  final text = StringBuffer()
    ..writeln('category: ${fields.reason}')
    ..writeln('app: ${fields.app}')
    ..write(fields.details);
  if (fields.excerpt.isNotEmpty) {
    text
      ..writeln()
      ..writeln('---')
      ..write(fields.excerpt);
  }
  return text.toString();
}

/// An attached response after the report's own clean-up. The chat page
/// redacts this text whole before it builds a report: the clean-up removes
/// invisible characters, which can join the pieces of a split secret, and
/// the cut to [aiReportExcerptLimit] must only ever see text the redaction
/// has already checked.
String aiReportResponseText(String response) => _multiline(response);

/// [response] cut to [aiReportExcerptLimit], never between the two halves
/// of a surrogate pair. [response] has already been cleaned up
/// ([aiReportResponseText]) and redacted whole, so the cut cannot leave the
/// head of a secret the check would no longer recognise.
String _excerpt(String response) {
  if (response.length <= aiReportExcerptLimit) return response;
  var end = aiReportExcerptLimit;
  final last = response.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end--;
  return response.substring(0, end);
}

/// Builds a mail URI unless its encoded representation is unsafe for common
/// mail applications, which often truncate URIs beyond this limit.
Uri? aiReportMailto(String subject, String body) {
  final uri = Uri(
    scheme: 'mailto',
    path: aiReportEmail,
    query:
        'subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}',
  );
  return uri.toString().length <= 1800 ? uri : null;
}

String _singleLine(String value) => _stripUnsafe(
  value
      .replaceAll('\r\n', ' ')
      .replaceAll('\r', ' ')
      .replaceAll('\n', ' ')
      .replaceAll('\u2028', ' ')
      .replaceAll('\u2029', ' '),
  keepNewlines: false,
);

String _multiline(String value) => _stripUnsafe(
  value.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
  keepNewlines: true,
);

String _stripUnsafe(String value, {required bool keepNewlines}) {
  final cleaned = StringBuffer();
  for (final rune in value.runes) {
    // Multi-line text keeps its line feeds and tabs: tab-indented code
    // (Go, Makefiles) stays readable.
    if (keepNewlines && (rune == 0x0a || rune == 0x09)) {
      cleaned.writeCharCode(rune);
      continue;
    }
    if (_isControl(rune) || _isBidiControl(rune) || _isInvisible(rune)) {
      continue;
    }
    cleaned.writeCharCode(rune);
  }
  return cleaned.toString();
}

bool _isControl(int rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f);

/// Characters that render as nothing: they could hide text in the preview
/// or split a secret so that no redaction pass matches it.
bool _isInvisible(int rune) =>
    rune == 0x00ad ||
    (rune >= 0x200b && rune <= 0x200d) ||
    (rune >= 0x2060 && rune <= 0x2064) ||
    rune == 0xfeff ||
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    (rune >= 0xe0000 && rune <= 0xe007f) ||
    (rune >= 0xe0100 && rune <= 0xe01ef);

bool _isBidiControl(int rune) =>
    rune == 0x061c ||
    rune == 0x200e ||
    rune == 0x200f ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2066 && rune <= 0x206f);
