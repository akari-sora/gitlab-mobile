import 'dart:convert';

import 'ai_transcript.dart';
import 'prompts.dart';
import 'redaction.dart';
import 'tools/sensitive_paths.dart';

const aiMaxRedactionInputChars = 2 * 1024 * 1024;

final class AiBuiltContext {
  AiBuiltContext({
    required List<AiContextBlock> blocks,
    required this.pinnedSha,
    required List<String> blockedSensitivePaths,
    required this.redactions,
    required this.withheldPrivateKeyContext,
  }) : blocks = List.unmodifiable(blocks),
       blockedSensitivePaths = List.unmodifiable(blockedSensitivePaths);

  final List<AiContextBlock> blocks;
  final String? pinnedSha;
  final List<String> blockedSensitivePaths;
  final int redactions;
  final bool withheldPrivateKeyContext;
}

final class AiJobContextInput {
  const AiJobContextInput({
    required this.name,
    required this.stage,
    required this.status,
    required this.trace,
    this.failureReason,
    this.ref,
    this.pipelineId,
    this.commitSha,
    this.pipelineSha,
  });

  final String name;
  final String stage;
  final String status;
  final String trace;
  final String? failureReason;
  final String? ref;
  final int? pipelineId;
  final String? commitSha;
  final String? pipelineSha;
}

final class AiDiffFileInput {
  const AiDiffFileInput({
    required this.oldPath,
    required this.newPath,
    required this.diff,
  });

  final String oldPath;
  final String newPath;
  final String diff;
}

final class AiMergeRequestContextInput {
  const AiMergeRequestContextInput({
    required this.iid,
    required this.title,
    required this.description,
    required this.state,
    required this.headSha,
    required this.baseSha,
    required this.diffs,
    this.labels = const [],
    this.allowedSensitivePaths = const {},
  });

  final int iid;
  final String title;
  final String description;
  final String state;
  final String headSha;
  final String baseSha;
  final List<String> labels;
  final List<AiDiffFileInput> diffs;
  final Set<String> allowedSensitivePaths;
}

final class AiFileContextInput {
  const AiFileContextInput({
    required this.path,
    required this.sha,
    required this.text,
    this.allowSensitive = false,
  });

  final String path;
  final String sha;
  final String text;
  final bool allowSensitive;
}

final class AiDiscussionNoteInput {
  const AiDiscussionNoteInput({
    required this.body,
    required this.createdAt,
    this.author,
    this.system = false,
  });

  final String body;
  final DateTime createdAt;
  final String? author;
  final bool system;
}

final class AiDiscussionContextInput {
  const AiDiscussionContextInput({
    required this.kind,
    required this.iid,
    required this.title,
    required this.description,
    required this.state,
    required this.pinnedSha,
    required this.notes,
    this.labels = const [],
  });

  final String kind;
  final int iid;
  final String title;
  final String description;
  final String state;
  final String pinnedSha;
  final List<String> labels;
  final List<AiDiscussionNoteInput> notes;
}

final class AiContextBuilders {
  const AiContextBuilders({required this.redactor});

  final Redactor redactor;

  AiBuiltContext job(AiJobContextInput input, {required String nonce}) {
    final pinned = _firstValidSha([input.commitSha, input.pipelineSha]);
    final traceResult = _redactSource(_stripTrace(input.trace));
    final lines = traceResult.text.split('\n');
    final tail = lines.length > 300
        ? lines.sublist(lines.length - 300).join('\n')
        : traceResult.text;
    final metadata = _redactJson({
      'name': input.name,
      'stage': input.stage,
      'status': input.status,
      'failure_reason': input.failureReason,
      'ref': input.ref,
      'pipeline_id': input.pipelineId,
    });
    return AiBuiltContext(
      blocks: [
        AiContextBlock(
          source: 'job',
          text: wrapUntrustedGitLabData(
            source: 'job',
            nonce: nonce,
            text: '${metadata.text}\n$tail',
          ),
        ),
      ],
      pinnedSha: pinned,
      blockedSensitivePaths: const [],
      redactions: metadata.redactions + traceResult.redactions,
      withheldPrivateKeyContext:
          metadata.withheldPrivateKeyContext ||
          traceResult.withheldPrivateKeyContext,
    );
  }

  AiBuiltContext mergeRequest(
    AiMergeRequestContextInput input, {
    required String nonce,
  }) {
    _requireSha(input.headSha);
    _requireSha(input.baseSha);
    final blocked = <String>[];
    var redactions = 0;
    var withheld = false;
    final diffs = <Map<String, Object?>>[];
    for (final file in input.diffs) {
      final sensitive =
          isSensitiveRepositoryPath(file.oldPath) ||
          isSensitiveRepositoryPath(file.newPath);
      final released =
          input.allowedSensitivePaths.contains(file.oldPath) ||
          input.allowedSensitivePaths.contains(file.newPath);
      if (sensitive && !released) blocked.add(file.newPath);
      final result = sensitive && !released
          ? const RedactionResult('[blocked by policy: sensitive file]', 0)
          : _redactFragment(file.diff);
      redactions += result.redactions;
      withheld |= result.withheldPrivateKeyContext;
      final oldPath = _redactSource(file.oldPath);
      final newPath = _redactSource(file.newPath);
      redactions += oldPath.redactions + newPath.redactions;
      withheld |=
          oldPath.withheldPrivateKeyContext ||
          newPath.withheldPrivateKeyContext;
      diffs.add({
        'old_path': oldPath.text,
        'new_path': newPath.text,
        'diff': result.text,
      });
    }
    final metadata = _redactJson({
      'iid': input.iid,
      'title': input.title,
      'description': input.description,
      'state': input.state,
      'labels': input.labels,
      'head_sha': input.headSha,
      'base_sha': input.baseSha,
    });
    redactions += metadata.redactions;
    withheld |= metadata.withheldPrivateKeyContext;
    final text = '${metadata.text}\n${_encodeSanitized(diffs)}';
    return AiBuiltContext(
      blocks: [
        AiContextBlock(
          source: 'merge_request',
          text: wrapUntrustedGitLabData(
            source: 'merge_request',
            nonce: nonce,
            text: text,
          ),
        ),
      ],
      pinnedSha: input.headSha,
      blockedSensitivePaths: blocked,
      redactions: redactions,
      withheldPrivateKeyContext: withheld,
    );
  }

  AiBuiltContext file(AiFileContextInput input, {required String nonce}) {
    _requireSha(input.sha);
    final sensitive = isSensitiveRepositoryPath(input.path);
    if (sensitive && !input.allowSensitive) {
      return AiBuiltContext(
        blocks: const [],
        pinnedSha: input.sha,
        blockedSensitivePaths: [input.path],
        redactions: 0,
        withheldPrivateKeyContext: false,
      );
    }
    return _sourceContext(
      source: 'file',
      text: 'path: ${input.path}\n${input.text}',
      nonce: nonce,
      pinnedSha: input.sha,
    );
  }

  AiBuiltContext discussion(
    AiDiscussionContextInput input, {
    required String nonce,
  }) {
    _requireSha(input.pinnedSha);
    final latest = input.notes.where((note) => !note.system).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final selected = latest.take(20).toList().reversed;
    final content = _redactJson({
      'title': input.title,
      'description': input.description,
      'state': input.state,
      'labels': input.labels,
      'notes': [
        for (final note in selected)
          {
            'author': note.author,
            'created_at': note.createdAt.toUtc().toIso8601String(),
            'body': note.body,
          },
      ],
    });
    return _builtSourceContext(
      source: '${input.kind} #${input.iid}',
      result: content,
      nonce: nonce,
      pinnedSha: input.pinnedSha,
    );
  }

  AiBuiltContext _sourceContext({
    required String source,
    required String text,
    required String nonce,
    required String? pinnedSha,
  }) {
    final cleanSource = _stripAnsi(source);
    final result = _redactSource(text);
    return _builtSourceContext(
      source: cleanSource,
      result: result,
      nonce: nonce,
      pinnedSha: pinnedSha,
    );
  }

  AiBuiltContext _builtSourceContext({
    required String source,
    required RedactionResult result,
    required String nonce,
    required String? pinnedSha,
  }) {
    return AiBuiltContext(
      blocks: [
        AiContextBlock(
          source: source,
          text: wrapUntrustedGitLabData(
            source: source,
            nonce: nonce,
            text: result.text,
          ),
        ),
      ],
      pinnedSha: pinnedSha,
      blockedSensitivePaths: const [],
      redactions: result.redactions,
      withheldPrivateKeyContext: result.withheldPrivateKeyContext,
    );
  }

  RedactionResult _redactSource(String value) {
    final clean = _stripAnsi(value);
    _checkSize(clean);
    return redactor.redactSource(clean);
  }

  RedactionResult _redactFragment(String value) {
    final clean = _stripAnsi(value);
    _checkSize(clean);
    return redactor.redactFragment(clean);
  }

  RedactionResult _redactJson(Object? value) {
    var redactions = 0;
    var withheld = false;
    Object? visit(Object? current) => switch (current) {
      String text => () {
        final result = _redactSource(text);
        redactions += result.redactions;
        withheld |= result.withheldPrivateKeyContext;
        return result.text;
      }(),
      List<Object?> values => [for (final item in values) visit(item)],
      Map<String, Object?> values => {
        for (final entry in values.entries) entry.key: visit(entry.value),
      },
      _ => current,
    };
    final encoded = _encodeSanitized(visit(value));
    _checkSize(encoded);
    return RedactionResult(
      encoded,
      redactions,
      withheldPrivateKeyContext: withheld,
    );
  }
}

void _checkSize(String value) {
  if (utf8.encode(value).length > aiMaxRedactionInputChars) {
    throw const FormatException('Context exceeds the redaction input limit.');
  }
}

String? _firstValidSha(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && isFullCommitSha(value)) return value;
  }
  return null;
}

void _requireSha(String value) {
  if (!isFullCommitSha(value)) {
    throw const FormatException('Invalid pinned SHA.');
  }
}

String _stripTrace(String text) {
  final marker = RegExp(
    r'section_(?:start|end):\d+:[A-Za-z0-9_.-]+(?:\[collapsed=(?:true|false)\])?\r?',
  );
  final timestamp = RegExp(
    r'^\d{4}-[01]\d-[0-3]\dT[0-2]\d:[0-5]\d:[0-5]\d\.\d{6}Z [0-9a-f]{2}[EO][+ ]',
    multiLine: true,
  );
  return text
      .replaceAll(_ansi, '')
      .replaceAll(marker, '')
      .replaceAll(timestamp, '');
}

final _ansi = RegExp(
  r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-_])',
);

String _stripAnsi(String value) => value.replaceAll(_ansi, '');

Object? _sanitizeJson(Object? value) => switch (value) {
  String text => _stripAnsi(text),
  List<Object?> values => [for (final item in values) _sanitizeJson(item)],
  Map<String, Object?> values => {
    for (final entry in values.entries) entry.key: _sanitizeJson(entry.value),
  },
  _ => value,
};

String _encodeSanitized(Object? value) => jsonEncode(_sanitizeJson(value));
