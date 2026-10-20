import 'dart:convert';

import 'prompts.dart';

/// Application-owned, already redacted values. Encoding is a separate view;
/// secret refreshes always revisit the plain values, never decode that view.
sealed class AiAppText {
  const AiAppText();

  const factory AiAppText.plain(String value) = _PlainText;
  factory AiAppText.json(Object? value) = _JsonText;
  factory AiAppText.join(List<AiAppText> parts, [String separator]) =
      _JoinedText;
  const factory AiAppText.untrusted({
    required String source,
    required String nonce,
    required AiAppText body,
  }) = _UntrustedText;

  Iterable<String> get plainStrings;
  String get plainText => plainStrings.join('\n');
  String encode();
  AiAppText redact(String Function(String) redact);
  AiAppText escaped() => _EscapedText(this);
  AiAppText clipped(int maximum) => _ClippedText(this, maximum);
}

final class _PlainText extends AiAppText {
  const _PlainText(this.value);
  final String value;
  @override
  Iterable<String> get plainStrings => [value];
  @override
  String encode() => value;
  @override
  AiAppText redact(String Function(String) redact) => _PlainText(redact(value));
}

final class _JsonText extends AiAppText {
  _JsonText(Object? value) : value = mapAiJsonStrings(value, (s) => s);
  final Object? value;
  @override
  Iterable<String> get plainStrings => readableAiJsonStrings(value);
  @override
  String encode() => jsonEncode(value);
  @override
  AiAppText redact(String Function(String) redact) =>
      _JsonText(mapAiJsonStrings(value, redact));
}

final class _JoinedText extends AiAppText {
  _JoinedText(List<AiAppText> parts, [this.separator = '\n'])
    : parts = List.unmodifiable(parts);
  final List<AiAppText> parts;
  final String separator;
  @override
  Iterable<String> get plainStrings => parts.expand((p) => p.plainStrings);
  @override
  String get plainText => parts.map((p) => p.plainText).join(separator);
  @override
  String encode() => parts.map((p) => p.encode()).join(separator);
  @override
  AiAppText redact(String Function(String) redact) =>
      _JoinedText(parts.map((p) => p.redact(redact)).toList(), separator);
}

final class _UntrustedText extends AiAppText {
  const _UntrustedText({
    required this.source,
    required this.nonce,
    required this.body,
  });
  final String source;
  final String nonce;
  final AiAppText body;
  @override
  Iterable<String> get plainStrings sync* {
    yield source;
    yield* body.plainStrings;
  }

  @override
  String get plainText => body.plainText;
  @override
  String encode() => wrapUntrustedGitLabData(
    source: source,
    nonce: nonce,
    text: body.encode(),
  );
  @override
  AiAppText redact(String Function(String) redact) => _UntrustedText(
    source: redact(source),
    nonce: nonce,
    body: body.redact(redact),
  );
}

final class _EscapedText extends AiAppText {
  const _EscapedText(this.body);
  final AiAppText body;
  @override
  Iterable<String> get plainStrings => body.plainStrings;
  @override
  String get plainText => body.plainText;
  @override
  String encode() => escapeUntrustedGitLabText(body.encode());
  @override
  AiAppText redact(String Function(String) redact) =>
      _EscapedText(body.redact(redact));
}

final class _ClippedText extends AiAppText {
  const _ClippedText(this.body, this.maximum);
  final AiAppText body;
  final int maximum;
  @override
  Iterable<String> get plainStrings => body.plainStrings;
  @override
  String get plainText => body.plainText;
  @override
  String encode() => clipWrappedUntrustedGitLabData(body.encode(), maximum);
  @override
  AiAppText redact(String Function(String) redact) =>
      _ClippedText(body.redact(redact), maximum);
}

Object? mapAiJsonStrings(Object? value, String Function(String) transform) =>
    switch (value) {
      String text => transform(text),
      List<Object?> values => List<Object?>.unmodifiable([
        for (final item in values) mapAiJsonStrings(item, transform),
      ]),
      Map<String, Object?> values => Map<String, Object?>.unmodifiable({
        for (final entry in values.entries)
          transform(entry.key): mapAiJsonStrings(entry.value, transform),
      }),
      _ => value,
    };

Iterable<String> readableAiJsonStrings(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      yield entry.key;
      yield* readableAiJsonStrings(entry.value);
    }
  } else if (value is List<Object?>) {
    for (final item in value) {
      yield* readableAiJsonStrings(item);
    }
  }
}
