import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'ai_provider.dart';

const aiFinalAnswerNoteMarker = '<mergeline_final_answer>';
const aiFinalAnswerNote =
    '$aiFinalAnswerNoteMarker Tool budget is exhausted. '
    'Answer now using only the information above; do not call tools.';

final class SecretSetId {
  SecretSetId(String value) : value = value.toLowerCase() {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(this.value)) {
      throw ArgumentError.value(value, 'value', 'Expected a SHA-256 digest.');
    }
  }

  factory SecretSetId.fromSecrets(Iterable<String> secrets) {
    final canonical = secrets.toSet().toList()..sort();
    final bytes = <int>[];
    for (final secret in canonical) {
      final encoded = utf8.encode(secret);
      bytes
        ..addAll(utf8.encode('${encoded.length}:'))
        ..addAll(encoded)
        ..add(0);
    }
    return SecretSetId(sha256.convert(bytes).toString());
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      other is SecretSetId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class AiContextBlock {
  const AiContextBlock({required this.source, required this.text});

  final String source;
  final String text;
}

final class AiToolCall {
  AiToolCall({required this.id, required this.name, required Object? arguments})
    : arguments = deepFreezeJson(arguments);

  final String id;
  final String name;
  final Object? arguments;
}

final class AiToolResult {
  const AiToolResult({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
  });

  final String callId;
  final String name;
  final String content;
  final bool isError;

  AiToolResult copyWith({String? content}) => AiToolResult(
    callId: callId,
    name: name,
    content: content ?? this.content,
    isError: isError,
  );
}

sealed class AiEntry {
  const AiEntry();
}

final class AppUserEntry extends AiEntry {
  AppUserEntry({required this.text, List<AiContextBlock> context = const []})
    : context = List.unmodifiable(context);

  final String text;
  final List<AiContextBlock> context;
}

final class ProviderOutputEntry extends AiEntry {
  ProviderOutputEntry(
    this.format,
    Object raw, {
    required List<AiToolCall> toolCalls,
  }) : raw = deepFreezeJson(raw)!,
       toolCalls = List.unmodifiable(toolCalls);

  final AiFormat format;
  final Object raw;
  final List<AiToolCall> toolCalls;
}

final class AppToolResultsEntry extends AiEntry {
  AppToolResultsEntry(List<AiToolResult> results, {this.followUpText})
    : results = List.unmodifiable(results);

  final List<AiToolResult> results;
  final String? followUpText;

  AppToolResultsEntry copyWith({
    List<AiToolResult>? results,
    String? followUpText,
    bool clearFollowUpText = false,
  }) => AppToolResultsEntry(
    results ?? this.results,
    followUpText: clearFollowUpText ? null : followUpText ?? this.followUpText,
  );
}

final class AiSegment {
  AiSegment({
    required this.providerId,
    required this.recipientRevision,
    required this.format,
    required this.model,
    required this.secretSetAtStart,
  });

  final String providerId;
  final int recipientRevision;
  final AiFormat format;
  final String model;
  final SecretSetId secretSetAtStart;
  final List<AiEntry> _frozen = [];
  final List<Object?> _frozenWire = [];
  AiEntry? _tail;

  List<AiEntry> get frozen => List.unmodifiable(_frozen);
  List<Object?> get frozenWire => UnmodifiableListView(_frozenWire);
  AiEntry? get tail => _tail;
  List<AiEntry> get entries => List.unmodifiable(<AiEntry>[..._frozen, ?_tail]);

  int get frozenLength => _frozen.length;

  bool get contextDelivered =>
      _frozen.any((entry) => entry is AppUserEntry && entry.context.isNotEmpty);

  void setTail(AiEntry tail) {
    if (tail is ProviderOutputEntry) {
      throw ArgumentError.value(
        tail,
        'tail',
        'Provider output cannot be a tail.',
      );
    }
    _tail = tail;
  }

  void addFollowUp(String redactedText) {
    final current = _tail;
    if (current is! AppToolResultsEntry) {
      throw StateError('A follow-up requires a tool-results tail.');
    }
    final previous = current.followUpText;
    _tail = current.copyWith(
      followUpText: previous == null || previous.isEmpty
          ? redactedText
          : '$previous\n\n$redactedText',
    );
  }

  void clipTailToolResults(int maxChars) {
    if (maxChars < 0) throw RangeError.range(maxChars, 0, null, 'maxChars');
    final current = _tail;
    if (current is! AppToolResultsEntry) {
      throw StateError('Only a tool-results tail can be clipped.');
    }
    var remaining = maxChars;
    final clipped = <AiToolResult>[];
    for (final result in current.results) {
      final keep = result.content.length <= remaining
          ? result.content
          : result.content.substring(0, remaining);
      clipped.add(result.copyWith(content: keep));
      remaining -= keep.length;
    }
    _tail = current.copyWith(results: clipped);
  }

  void restoreTail(AiEntry? previous) {
    if (previous is ProviderOutputEntry) {
      throw ArgumentError.value(previous, 'previous');
    }
    _tail = previous;
  }

  void removeFinalAnswerNote() {
    final current = _tail;
    if (current is! AppToolResultsEntry) return;
    final text = current.followUpText;
    if (text == null) return;
    if (text == aiFinalAnswerNote) {
      _tail = current.copyWith(clearFollowUpText: true);
      return;
    }
    const suffix = '\n\n$aiFinalAnswerNote';
    if (!text.endsWith(suffix)) return;
    final restored = text.substring(0, text.length - suffix.length);
    _tail = current.copyWith(followUpText: restored);
  }

  void freezeWith(
    ProviderOutputEntry output,
    Object? Function(AiEntry entry) encode,
  ) {
    if (output.format != format) {
      throw ArgumentError.value(output.format, 'output.format');
    }
    final current = _tail;
    if (current == null) {
      throw StateError('Provider output requires an app tail.');
    }
    final entries = <AiEntry>[current, output];
    final encoded = entries
        .map<Object?>((entry) => deepFreezeJson(encode(entry)))
        .toList(growable: false);
    _frozen.addAll(entries);
    _frozenWire.addAll(encoded);
    _tail = null;
  }
}

Object? deepFreezeJson(Object? value) => switch (value) {
  Map<Object?, Object?> map => _freezeJsonMap(map),
  List<Object?> list => UnmodifiableListView<Object?>(
    list.map<Object?>(deepFreezeJson).toList(growable: false),
  ),
  String() || num() || bool() || null => value,
  _ => throw ArgumentError.value(value, 'value', 'Expected a JSON value.'),
};

Map<String, Object?> _freezeJsonMap(Map<Object?, Object?> value) {
  final frozen = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw ArgumentError.value(key, 'key', 'JSON keys must be strings.');
    }
    frozen[key] = deepFreezeJson(entry.value);
  }
  return UnmodifiableMapView(frozen);
}
