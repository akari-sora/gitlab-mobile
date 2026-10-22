import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../ai_failure.dart';
import '../redaction.dart';

enum AiScheduleParamsState { explicitEmpty, nonEmpty, unreadable }

/// Parameter values are consumed only by HMAC, never retained in this model.
final class AiScheduleParams {
  AiScheduleParams({
    required this.state,
    required this.ref,
    required List<String> variableNames,
    required List<String> inputNames,
    required Uint8List? hmac,
  }) : variableNames = List.unmodifiable(variableNames),
       inputNames = List.unmodifiable(inputNames),
       hmac = hmac == null
           ? null
           : Uint8List.fromList(hmac).asUnmodifiableView();

  final AiScheduleParamsState state;
  final String ref;
  final List<String> variableNames;
  final List<String> inputNames;
  final Uint8List? hmac;
}

/// Completeness metadata comes from the caller's bounded read. Omitted counts
/// mean the endpoint supplied no count, not that a partial read is complete.
AiScheduleParams evaluateScheduleParams(
  Map<String, dynamic> schedule, {
  required List<int> key,
  bool hasMorePages = false,
  bool truncated = false,
  Object? variablesCount,
  Object? inputsCount,
}) {
  final rawRef = schedule['ref'];
  final ref = rawRef is String ? rawRef : '';
  AiScheduleParams unreadable() => AiScheduleParams(
    state: AiScheduleParamsState.unreadable,
    ref: ref,
    variableNames: const [],
    inputNames: const [],
    hmac: null,
  );
  if (ref.isEmpty ||
      hasMorePages ||
      truncated ||
      key.length != 32 ||
      key.any((byte) => byte < 0 || byte > 255)) {
    return unreadable();
  }
  final variables = schedule['variables'];
  final inputs = schedule['inputs'];
  if (variables is! List || (inputs is! List && inputs is! Map)) {
    return unreadable();
  }
  try {
    final variableNames = <String>{};
    final variableRecords = <Map<String, Object?>>[];
    for (final variable in variables) {
      if (variable is! Map ||
          variable['key'] is! String ||
          (variable['key']! as String).isEmpty ||
          variable['value'] is! String ||
          variable['variable_type'] is! String ||
          (variable['variable_type']! as String).isEmpty) {
        return unreadable();
      }
      final name = variable['key']! as String;
      if (!variableNames.add(name)) return unreadable();
      variableRecords.add(_canonicalJson(variable)! as Map<String, Object?>);
    }
    variableRecords.sort(
      (a, b) => (a['key']! as String).compareTo(b['key']! as String),
    );
    final inputRecords = <String, Object?>{};
    if (inputs is Map) {
      for (final entry in inputs.entries) {
        if (entry.key is! String || (entry.key! as String).isEmpty) {
          return unreadable();
        }
        inputRecords[entry.key! as String] = _canonicalJson(entry.value);
      }
    } else {
      for (final input in inputs as List) {
        if (input is! Map ||
            input['name'] is! String ||
            (input['name']! as String).isEmpty ||
            !input.containsKey('value')) {
          return unreadable();
        }
        final name = input['name']! as String;
        if (inputRecords.containsKey(name)) return unreadable();
        // Keep any API type metadata along with the typed JSON value.
        inputRecords[name] = _canonicalJson(input);
      }
    }
    if (!_countMatches(variablesCount, variableRecords.length) ||
        !_countMatches(inputsCount, inputRecords.length)) {
      return unreadable();
    }
    final names = variableNames.toList()..sort();
    final inputNames = inputRecords.keys.toList()..sort();
    final payload = _canonicalJson({
      'variables': variableRecords,
      'inputs': inputRecords,
      'ref': ref,
    });
    final digest = Hmac(sha256, key).convert(utf8.encode(jsonEncode(payload)));
    return AiScheduleParams(
      state: names.isEmpty && inputNames.isEmpty
          ? AiScheduleParamsState.explicitEmpty
          : AiScheduleParamsState.nonEmpty,
      ref: ref,
      variableNames: names,
      inputNames: inputNames,
      hmac: Uint8List.fromList(digest.bytes),
    );
  } on FormatException {
    return unreadable();
  }
}

bool _countMatches(Object? count, int length) =>
    count == null ||
    (count is int && count >= 0 && count == length) ||
    (count is String &&
        RegExp(r'^[0-9]+$').hasMatch(count) &&
        int.tryParse(count) == length);

Object? _canonicalJson(Object? value) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List) return value.map(_canonicalJson).toList();
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('invalidJson');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  throw const FormatException('invalidJson');
}

sealed class AiPipelineVariables {
  const AiPipelineVariables();
}

final class AiPipelineVariablesAccepted extends AiPipelineVariables {
  AiPipelineVariablesAccepted(List<Map<String, String>> variables)
    : variables = List.unmodifiable(
        variables.map((variable) => Map<String, String>.unmodifiable(variable)),
      );
  final List<Map<String, String>> variables;
}

final class AiPipelineVariablesRejected extends AiPipelineVariables {
  const AiPipelineVariablesRejected(this.reasonCode);
  final String reasonCode;
}

AiPipelineVariables validatePipelineVariables(
  Object? raw, {
  required Set<String> knownSecrets,
}) {
  if (raw == null) return AiPipelineVariablesAccepted(const []);
  if (raw is! List) {
    return const AiPipelineVariablesRejected('pipelineVariablesInvalid');
  }
  final variables = <Map<String, String>>[];
  final names = <String>{};
  for (final item in raw) {
    if (item is! Map ||
        item.keys.any(
          (key) => key != 'key' && key != 'value' && key != 'variable_type',
        ) ||
        item['key'] is! String ||
        item['value'] is! String ||
        (item.containsKey('variable_type') &&
            item['variable_type'] != 'env_var' &&
            item['variable_type'] != 'file')) {
      return const AiPipelineVariablesRejected('pipelineVariablesInvalid');
    }
    final name = item['key']! as String;
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(name) || !names.add(name)) {
      return const AiPipelineVariablesRejected('pipelineVariablesInvalid');
    }
    final upper = name.toUpperCase();
    if (upper.startsWith('CI_') ||
        upper.startsWith('GITLAB_') ||
        upper.contains('_DEBUG_')) {
      return const AiPipelineVariablesRejected('pipelineVariableNameBlocked');
    }
    variables.add({
      'key': name,
      'value': item['value']! as String,
      if (item.containsKey('variable_type'))
        'variable_type': item['variable_type']! as String,
    });
  }
  final payload = jsonEncode(variables);
  if (payload.contains('[REDACTED') ||
      payload.contains('<gitlab_data') ||
      payload.contains('</gitlab_data>')) {
    return const AiPipelineVariablesRejected('redactionMarker');
  }
  try {
    final redactor = Redactor(secrets: _PipelineSecrets(knownSecrets));
    // Scan the final payload and each literal, so JSON escaping cannot hide
    // a known credential or a secret assignment split by a newline.
    for (final text in [
      payload,
      for (final variable in variables) ...variable.values,
    ]) {
      final result = redactor.redactSource(text);
      if (result.redactions > 0 || result.text != text) {
        return const AiPipelineVariablesRejected('secret');
      }
    }
  } on AiFailure {
    return const AiPipelineVariablesRejected('secret');
  }
  return AiPipelineVariablesAccepted(variables);
}

final class _PipelineSecrets implements KnownSecretsSource {
  const _PipelineSecrets(this.current);
  @override
  final Set<String> current;
}
