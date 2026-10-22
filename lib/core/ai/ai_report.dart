import '../brand.dart';

enum AiReportCategory { harmful, inaccurate, privacy, other }

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
      ..write(_multiline(response));
  }
  return body.toString();
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
    if (keepNewlines && rune == 0x0a) {
      cleaned.writeCharCode(rune);
      continue;
    }
    if (_isControl(rune) || _isBidiControl(rune)) continue;
    cleaned.writeCharCode(rune);
  }
  return cleaned.toString();
}

bool _isControl(int rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f);

bool _isBidiControl(int rune) =>
    rune == 0x061c ||
    rune == 0x200e ||
    rune == 0x200f ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2066 && rune <= 0x206f);
