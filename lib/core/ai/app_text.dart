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
  // Values are immutable, including const instances. Expando keeps the cached
  // delivery view with the value without retaining discarded conversations.
  static final _encoded = Expando<String>();
  String encode() => _encoded[this] ??= _encode();
  String _encode();
  AiAppText redact(String Function(String) redact);
  AiAppText escaped() => _EscapedText(this);
  AiAppText clipped(int maximum, {int secretMargin = 0}) => _ClippedText(
    _PlainRetention(maximum, secretMargin).retain(this, 0),
    maximum,
  );
}

final class _PlainText extends AiAppText {
  const _PlainText(this.value);
  final String value;
  @override
  Iterable<String> get plainStrings => [value];
  @override
  String _encode() => value;
  @override
  AiAppText redact(String Function(String) redact) => _PlainText(redact(value));
}

final class _JsonText extends AiAppText {
  _JsonText(Object? value) : value = mapAiJsonStrings(value, (s) => s);
  final Object? value;
  @override
  Iterable<String> get plainStrings => readableAiJsonStrings(value);
  @override
  String _encode() => jsonEncode(value);
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
  String _encode() => parts.map((p) => p.encode()).join(separator);
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
  String _encode() => wrapUntrustedGitLabData(
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
  String _encode() => escapeUntrustedGitLabText(body.encode());
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
  String _encode() => clipWrappedUntrustedGitLabData(body.encode(), maximum);
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

// Retain only the deliverable prefix and one overlap margin. Walk plain values
// while accounting for the encodings around them; never decode a wire view.
final class _PlainRetention {
  _PlainRetention(this.remaining, this.margin);
  int remaining;
  int margin;

  void consume(int width) =>
      remaining = remaining > width ? remaining - width : 0;

  String text(String value, int depth, {bool json = false}) {
    final prefix = clipAiPlainForEscapedBudget(
      value,
      remaining,
      escapeDepth: depth,
      json: json,
    );
    consume(_encodedWidth(prefix, depth, json: json));
    if (prefix.length == value.length) return value;
    remaining = 0;
    final end = (prefix.length + margin).clamp(0, value.length);
    margin = 0;
    // A cut must not retain half of a surrogate pair.
    final safeEnd =
        end > 0 &&
            end < value.length &&
            value.codeUnitAt(end - 1) >= 0xD800 &&
            value.codeUnitAt(end - 1) <= 0xDBFF
        ? end - 1
        : end;
    return value.substring(0, safeEnd);
  }

  AiAppText retain(AiAppText value, int depth) => switch (value) {
    _PlainText() => AiAppText.plain(text(value.value, depth)),
    _JsonText() => AiAppText.json(jsonValue(value.value, depth)),
    _EscapedText() => retain(value.body, depth + 1).escaped(),
    _UntrustedText() => untrusted(value, depth),
    _JoinedText() => joined(value, depth),
    _ClippedText() => _ClippedText(retain(value.body, depth), value.maximum),
  };

  AiAppText untrusted(_UntrustedText value, int depth) {
    final labels = wrapUntrustedGitLabData(
      source: value.source,
      nonce: value.nonce,
      text: '',
    );
    consume(_encodedWidth(labels, depth));
    return AiAppText.untrusted(
      source: value.source,
      nonce: value.nonce,
      body: retain(value.body, depth + 1),
    );
  }

  AiAppText joined(_JoinedText value, int depth) {
    final parts = <AiAppText>[];
    for (final part in value.parts) {
      if (parts.isNotEmpty) consume(_encodedWidth(value.separator, depth));
      parts.add(retain(part, depth));
    }
    return AiAppText.join(parts, value.separator);
  }

  Object? jsonValue(Object? value, int depth) {
    if (value is String) {
      consume(2); // JSON string quotes.
      return text(value, depth, json: true);
    }
    if (value is List<Object?>) {
      consume(2); // Brackets.
      final result = <Object?>[];
      for (var i = 0; i < value.length; i++) {
        if (i > 0) consume(1);
        result.add(jsonValue(value[i], depth));
      }
      return result;
    }
    if (value is Map<String, Object?>) {
      consume(2); // Braces. Keys are the catalogue's bounded projected schema.
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        if (result.isNotEmpty) consume(1);
        consume(_encodedWidth(jsonEncode(entry.key), depth) + 1);
        result[entry.key] = jsonValue(entry.value, depth);
      }
      return result;
    }
    consume(jsonEncode(value).length);
    return value;
  }
}

/// Plain prefix whose JSON/XML delivery width fits [maximum].
String clipAiPlainForEscapedBudget(
  String text,
  int maximum, {
  int escapeDepth = 1,
  bool json = false,
}) {
  var used = 0;
  var end = 0;
  for (final rune in text.runes) {
    final width = _runeEncodedWidth(rune, escapeDepth, json: json);
    if (used + width > maximum) break;
    used += width;
    end += rune > 0xffff ? 2 : 1;
  }
  return text.substring(0, end);
}

int _encodedWidth(String text, int depth, {bool json = false}) => text.runes
    .fold(0, (sum, rune) => sum + _runeEncodedWidth(rune, depth, json: json));

int _runeEncodedWidth(int rune, int depth, {required bool json}) {
  if (json) {
    if (rune == 0x22 || rune == 0x5c) return 2;
    if (rune < 0x20) {
      return const [8, 9, 10, 12, 13].contains(rune) ? 2 : 6;
    }
  }
  if (depth > 0) {
    if (rune == 0x26) return 1 + 4 * depth;
    if (rune == 0x3c || rune == 0x3e) return 4 * depth;
  }
  return rune > 0xffff ? 2 : 1;
}
