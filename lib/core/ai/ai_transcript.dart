import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'ai_failure.dart';
import 'app_text.dart';
import 'ai_provider.dart';
import 'prompts.dart';
import 'redaction.dart';

const aiFinalAnswerNoteMarker = '<mergeline_final_answer>';
const aiFinalAnswerNote =
    '$aiFinalAnswerNoteMarker Tool budget is exhausted. '
    'Answer now using only the information above; do not call tools.';

final class SecretSetId {
  SecretSetId._(this._value);

  factory SecretSetId.fromSecrets(Iterable<String> secrets) {
    final canonical =
        secrets.where((secret) => secret.isNotEmpty).toSet().toList()..sort();
    final bytes = <int>[];
    for (final secret in canonical) {
      final encoded = utf8.encode(secret);
      bytes
        ..addAll(utf8.encode('${encoded.length}:'))
        ..addAll(encoded)
        ..add(0);
    }
    return SecretSetId._(
      Hmac(sha256, _secretSetIdKey).convert(bytes).toString(),
    );
  }

  static final List<int> _secretSetIdKey = _newSecretSetIdKey();

  final String _value;

  @override
  bool operator ==(Object other) =>
      other is SecretSetId && other._value == _value;

  @override
  int get hashCode => _value.hashCode;
}

final class AiContextBlock {
  @visibleForTesting
  AiContextBlock({required this.source, required String text})
    : _text = text,
      data = null {
    assert(!text.contains('<gitlab_data'));
  }
  const AiContextBlock.fromData({required this.source, required AiAppText data})
    : _text = '',
      // ignore: prefer_initializing_formals
      data = data;

  final String source;
  final String _text;
  final AiAppText? data;
  String get text => data?.encode() ?? _text;
  AiAppText get plainData => data ?? AiAppText.plain(_text);

  AiContextBlock redact(Redactor redactor, {String Function(String)? source}) =>
      AiContextBlock.fromData(
        source:
            source?.call(this.source) ??
            redactor.redactSource(this.source).text,
        data: plainData.redact(redactor, source: source),
      );
}

final class AiToolCall {
  AiToolCall({required this.id, required this.name, required Object? arguments})
    : arguments = deepFreezeJson(arguments);

  final String id;
  final String name;
  final Object? arguments;
}

final class AiToolResult {
  @visibleForTesting
  AiToolResult({
    required this.callId,
    required this.name,
    required String content,
    this.isError = false,
    this.withheldPrivateKeyContext = false,
    this.truncated = false,
    this.blockedSensitive = false,
    this.notExecuted = false,
    this.readConfidential = false,
    this.readInternal = false,
    this.uploadPlaceholders = false,
  }) : _content = content,
       data = null {
    assert(!content.contains('<gitlab_data'));
  }

  const AiToolResult.fromData({
    required this.callId,
    required this.name,
    required AiAppText data,
    this.isError = false,
    this.withheldPrivateKeyContext = false,
    this.truncated = false,
    this.blockedSensitive = false,
    this.notExecuted = false,
    this.readConfidential = false,
    this.readInternal = false,
    this.uploadPlaceholders = false,
  }) : _content = '',
       // ignore: prefer_initializing_formals
       data = data;

  final String callId;
  final String name;
  final String _content;
  final AiAppText? data;
  String get content => data?.encode() ?? _content;
  AiAppText get plainData => data ?? AiAppText.plain(_content);
  final bool isError;
  final bool withheldPrivateKeyContext;
  final bool truncated;
  final bool blockedSensitive;
  final bool notExecuted;

  /// Display-only metadata; never encoded in provider requests.
  final bool readConfidential;

  /// Display-only metadata; never encoded in provider requests.
  final bool readInternal;

  /// The producer numbered restorable upload links through the
  /// conversation's placeholder table and already turned every
  /// source-authored `[[upload:` or `[[attachment:` into an ordinary marker,
  /// so later redaction passes keep exact `[[upload:u-<n>]]` tokens. A cut
  /// value still loses them.
  final bool uploadPlaceholders;

  AiToolResult copyWith({required AiAppText data}) => AiToolResult.fromData(
    callId: callId,
    name: name,
    data: data,
    isError: isError,
    withheldPrivateKeyContext: withheldPrivateKeyContext,
    truncated: truncated,
    blockedSensitive: blockedSensitive,
    notExecuted: notExecuted,
    readConfidential: readConfidential,
    readInternal: readInternal,
    uploadPlaceholders: uploadPlaceholders,
  );
}

sealed class AiEntry {
  const AiEntry();
}

final class AppUserEntry extends AiEntry {
  AppUserEntry({required this.text, List<AiContextBlock> context = const []})
    : context = List.unmodifiable(context),
      _finalAnswerNoteInjected = false;

  AppUserEntry._({
    required this.text,
    required this.context,
    required bool finalAnswerNoteInjected,
  }) : _finalAnswerNoteInjected = finalAnswerNoteInjected;

  final String text;
  final List<AiContextBlock> context;
  final bool _finalAnswerNoteInjected;

  AppUserEntry _withText(
    String text, {
    required bool finalAnswerNoteInjected,
  }) => AppUserEntry._(
    text: text,
    context: context,
    finalAnswerNoteInjected: finalAnswerNoteInjected,
  );

  AppUserEntry redactedCopy({
    required String text,
    required List<AiContextBlock> context,
  }) => AppUserEntry._(
    text: text,
    context: List.unmodifiable(context),
    finalAnswerNoteInjected: _finalAnswerNoteInjected,
  );
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
    : results = List.unmodifiable(results),
      _finalAnswerNoteInjected = false;

  AppToolResultsEntry._(
    List<AiToolResult> results, {
    required this.followUpText,
    required bool finalAnswerNoteInjected,
  }) : results = List.unmodifiable(results),
       _finalAnswerNoteInjected = finalAnswerNoteInjected;

  final List<AiToolResult> results;
  final String? followUpText;
  final bool _finalAnswerNoteInjected;

  AppToolResultsEntry copyWith({
    List<AiToolResult>? results,
    String? followUpText,
    bool clearFollowUpText = false,
    bool preserveFinalAnswerNote = false,
  }) => AppToolResultsEntry._(
    results ?? this.results,
    followUpText: clearFollowUpText ? null : followUpText ?? this.followUpText,
    finalAnswerNoteInjected:
        (preserveFinalAnswerNote || followUpText == null) &&
        !clearFollowUpText &&
        _finalAnswerNoteInjected,
  );

  AppToolResultsEntry _withFollowUp(
    String? followUpText, {
    required bool finalAnswerNoteInjected,
  }) => AppToolResultsEntry._(
    results,
    followUpText: followUpText,
    finalAnswerNoteInjected: finalAnswerNoteInjected,
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
  final List<String> _frozenWireJson = [];
  String? _wireConfiguration;
  bool _replayable = true;
  AiEntry? _tail;

  List<AiEntry> get frozen => List.unmodifiable(_frozen);
  List<Object?> get frozenWire => UnmodifiableListView(_frozenWire);
  List<String> get frozenWireJson => UnmodifiableListView(_frozenWireJson);
  bool get replayable => _replayable;

  void invalidateReplay() => _replayable = false;

  void bindWireConfiguration(String configuration) {
    if (!_replayable ||
        (_wireConfiguration != null && _wireConfiguration != configuration)) {
      throw StateError('A new segment is required.');
    }
    _wireConfiguration = configuration;
  }

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
    removeFinalAnswerNote();
    _addFollowUp(redactedText, finalAnswerNote: false);
  }

  void addFinalAnswerNote() {
    _addFollowUp(aiFinalAnswerNote, finalAnswerNote: true);
  }

  void _addFollowUp(String redactedText, {required bool finalAnswerNote}) {
    final current = _tail;
    if (current is AppToolResultsEntry) {
      if (finalAnswerNote && current._finalAnswerNoteInjected) return;
      final previous = current.followUpText;
      _tail = current._withFollowUp(
        previous == null || previous.isEmpty
            ? redactedText
            : '$previous\n\n$redactedText',
        finalAnswerNoteInjected: finalAnswerNote,
      );
      return;
    }
    if (current is AppUserEntry) {
      if (finalAnswerNote && current._finalAnswerNoteInjected) return;
      _tail = current._withText(
        current.text.isEmpty
            ? redactedText
            : '${current.text}\n\n$redactedText',
        finalAnswerNoteInjected: finalAnswerNote,
      );
      return;
    }
    throw StateError('A follow-up requires an app tail.');
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
          : clipWrappedUntrustedGitLabData(result.content, remaining);
      clipped.add(result.copyWith(data: result.plainData.clipped(remaining)));
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
    if (current is AppToolResultsEntry && current._finalAnswerNoteInjected) {
      _tail = current._withFollowUp(
        _removeFinalAnswerNote(current.followUpText!),
        finalAnswerNoteInjected: false,
      );
      return;
    }
    if (current is AppUserEntry && current._finalAnswerNoteInjected) {
      _tail = current._withText(
        _removeFinalAnswerNote(current.text) ?? '',
        finalAnswerNoteInjected: false,
      );
    }
  }

  void freezeWith(
    ProviderOutputEntry output,
    Object? Function(AiEntry entry) encode,
  ) {
    if (output.format != format) {
      throw ArgumentError.value(output.format, 'output.format');
    }
    if (output.format == AiFormat.anthropicMessages &&
        output.raw is List<Object?> &&
        (output.raw as List<Object?>).isEmpty) {
      throw const AiFailure(AiFailureKind.invalidResponse);
    }
    final current = _tail;
    if (current == null) {
      throw StateError('Provider output requires an app tail.');
    }
    final entries = <AiEntry>[current, output];
    final encoded = entries
        .map<Object?>((entry) => deepFreezeJson(encode(entry)))
        .toList(growable: false);
    // Serialize atomically before advancing the watermark. Adapters cache one
    // flatMap list per entry; future requests splice these bytes unchanged.
    final serialized = encoded.map(jsonEncode).toList(growable: false);
    _frozen.addAll(entries);
    _frozenWire.addAll(encoded);
    _frozenWireJson.addAll(serialized);
    _tail = null;
  }
}

List<int> _newSecretSetIdKey() {
  final random = Random.secure();
  return List<int>.unmodifiable(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
}

String? _removeFinalAnswerNote(String text) {
  if (text == aiFinalAnswerNote) return null;
  const suffix = '\n\n$aiFinalAnswerNote';
  if (!text.endsWith(suffix)) {
    throw StateError('Injected final-answer note is missing from the tail.');
  }
  return text.substring(0, text.length - suffix.length);
}

const _maxJsonDepth = 128;

Object? deepFreezeJson(Object? value) => _deepFreezeJson(value, 0);

Object? _deepFreezeJson(Object? value, int depth) => switch (value) {
  Map<Object?, Object?> map => _freezeJsonMap(map, depth),
  List<Object?> list => _freezeJsonList(list, depth),
  String() || num() || bool() || null => value,
  _ => throw ArgumentError.value(value, 'value', 'Expected a JSON value.'),
};

List<Object?> _freezeJsonList(List<Object?> value, int depth) {
  _checkJsonDepth(depth);
  return UnmodifiableListView<Object?>(
    value
        .map<Object?>((entry) => _deepFreezeJson(entry, depth + 1))
        .toList(growable: false),
  );
}

Map<String, Object?> _freezeJsonMap(Map<Object?, Object?> value, int depth) {
  _checkJsonDepth(depth);
  final frozen = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw ArgumentError.value(key, 'key', 'JSON keys must be strings.');
    }
    frozen[key] = _deepFreezeJson(entry.value, depth + 1);
  }
  return UnmodifiableMapView(frozen);
}

void _checkJsonDepth(int depth) {
  if (depth >= _maxJsonDepth) {
    throw const AiFailure(AiFailureKind.invalidResponse);
  }
}
