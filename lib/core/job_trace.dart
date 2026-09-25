import 'dart:ui' show Brightness;
import 'package:flutter/material.dart' show InlineSpan, TextSpan, TextStyle;
import 'ansi.dart';
import 'failure.dart';
import 'gitlab_api.dart';

/// GitLab CI traces, with `section_start` / `section_end` markers removed
/// and ANSI / SGR color styles parsed into styled spans.
final class JobTrace {
  /// Nested `section_start` markers past this depth stay plain text.
  static const maxDepth = 32;

  /// Further markers are ignored so a marker-dense trace cannot explode.
  static const maxSections = 1024;

  const JobTrace({
    required this.ansiStripped,
    required this.lines,
    required this.sections,
  });

  /// ANSI-stripped text before markers are removed. Line budgets use this.
  final String ansiStripped;
  final List<JobTraceLine> lines;
  final List<JobTraceSection> sections;

  static const empty = JobTrace(
    ansiStripped: '',
    lines: <JobTraceLine>[],
    sections: <JobTraceSection>[],
  );

  static final _ansi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _marker = RegExp(
    r'section_(start|end):(\d+):([A-Za-z0-9_.-]+)(?:\[collapsed=(true|false)\])?\r?',
  );

  factory JobTrace.parse(String raw, {int maxLines = GitLabApi.maxTextLines}) {
    final plain = raw.replaceAll(_ansi, '');
    if (plain.isEmpty) return JobTrace.empty;
    // Newlines are a fast lower bound. Inline section markers can still split
    // one physical line into many rows, so each emitted row is counted too.
    var newlines = 0;
    for (var i = 0; i < plain.length; i++) {
      if (plain.codeUnitAt(i) != 0x0A) continue;
      newlines++;
      if (newlines >= maxLines) throw const ApiFailure(FailureKind.tooLarge);
    }
    final lines = <JobTraceLine>[];
    final sections = <JobTraceSection>[];
    final stack = <_OpenSection>[];
    final stateMachine = AnsiStateMachine();
    var start = 0;
    for (var i = 0; i <= raw.length; i++) {
      if (i != raw.length && raw.codeUnitAt(i) != 0x0A) continue;
      var line = raw.substring(start, i);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _takeLine(line, lines, sections, stack, stateMachine, maxLines);
      start = i + 1;
    }
    while (stack.isNotEmpty) {
      _close(stack.removeLast(), null, lines.length, sections);
    }
    return JobTrace(
      ansiStripped: plain,
      lines: List.unmodifiable(lines),
      sections: List.unmodifiable(sections),
    );
  }
}

final class JobTraceLine {
  const JobTraceLine(
    this.text, {
    this.section,
    this.spans = const <AnsiSpan>[],
  });

  /// Plain text with ANSI sequences and section markers removed.
  final String text;

  /// Innermost open section name, when this line is inside one.
  final String? section;

  /// Styled ANSI segments for this line.
  final List<AnsiSpan> spans;

  /// Builds a Flutter InlineSpan (TextSpan) for rendering in Text.rich.
  InlineSpan toInlineSpan({
    required Brightness brightness,
    TextStyle? baseStyle,
  }) {
    if (spans.isEmpty) {
      return TextSpan(text: text.isEmpty ? ' ' : text, style: baseStyle);
    }
    if (spans.length == 1 && spans.first.style.isPlain) {
      final t = spans.first.text;
      return TextSpan(text: t.isEmpty ? ' ' : t, style: baseStyle);
    }
    return TextSpan(
      style: baseStyle,
      children: [
        for (final span in spans)
          span.toTextSpan(brightness: brightness, baseStyle: baseStyle),
      ],
    );
  }
}

final class JobTraceSection {
  const JobTraceSection({
    required this.name,
    required this.start,
    required this.end,
    required this.collapsed,
    required this.startLine,
    required this.endLine,
    required this.depth,
  });

  final String name;
  final int start;
  final int? end;
  final bool collapsed;

  /// Inclusive start and exclusive end into [JobTrace.lines].
  final int startLine;
  final int endLine;
  final int depth;

  String get label => name.replaceAll(RegExp(r'[_-]+'), ' ').trim();

  int? get durationSeconds {
    final finished = end;
    if (finished == null || finished < start) return null;
    return finished - start;
  }
}

final class _OpenSection {
  const _OpenSection({
    required this.name,
    required this.start,
    required this.collapsed,
    required this.startLine,
    required this.depth,
  });
  final String name;
  final int start;
  final bool collapsed;
  final int startLine;
  final int depth;
}

void _takeLine(
  String line,
  List<JobTraceLine> lines,
  List<JobTraceSection> sections,
  List<_OpenSection> stack,
  AnsiStateMachine stateMachine,
  int maxLines,
) {
  var cursor = 0;
  var sawMarker = false;
  for (final match in JobTrace._marker.allMatches(line)) {
    sawMarker = true;
    final before = line.substring(cursor, match.start);
    if (before.isNotEmpty) {
      _emitSegment(before, lines, stack, stateMachine, maxLines, allowEmpty: false);
    }
    _applyMarker(match, lines, sections, stack);
    cursor = match.end;
  }
  final rest = line.substring(cursor);
  if (!sawMarker || rest.isNotEmpty) {
    _emitSegment(rest, lines, stack, stateMachine, maxLines, allowEmpty: !sawMarker);
  }
}

void _emitSegment(
  String rawText,
  List<JobTraceLine> lines,
  List<_OpenSection> stack,
  AnsiStateMachine stateMachine,
  int maxLines, {
  required bool allowEmpty,
}) {
  final spans = stateMachine.parseSpans(rawText);
  final plainText = spans.isEmpty ? '' : spans.map((s) => s.text).join();
  if (plainText.isEmpty) {
    if (!allowEmpty) return;
    if (lines.length >= maxLines) throw const ApiFailure(FailureKind.tooLarge);
    lines.add(JobTraceLine('', section: stack.isEmpty ? null : stack.last.name));
    return;
  }

  final sectionName = stack.isEmpty ? null : stack.last.name;
  if (plainText.length <= stateMachine.maxLineLength) {
    if (lines.length >= maxLines) throw const ApiFailure(FailureKind.tooLarge);
    lines.add(JobTraceLine(plainText, section: sectionName, spans: spans));
  } else {
    _emitChunkedSpans(plainText, spans, sectionName, lines, maxLines, stateMachine.maxLineLength);
  }
}

void _emitChunkedSpans(
  String plainText,
  List<AnsiSpan> spans,
  String? sectionName,
  List<JobTraceLine> lines,
  int maxLines,
  int maxLineLength,
) {
  var charIndex = 0;
  var spanIndex = 0;
  var spanCharOffset = 0;

  while (charIndex < plainText.length) {
    if (lines.length >= maxLines) throw const ApiFailure(FailureKind.tooLarge);
    final chunkEnd = (charIndex + maxLineLength < plainText.length)
        ? charIndex + maxLineLength
        : plainText.length;
    final chunkText = plainText.substring(charIndex, chunkEnd);
    final chunkSpans = <AnsiSpan>[];
    var chunkRemaining = chunkText.length;

    while (spanIndex < spans.length && chunkRemaining > 0) {
      final currentSpan = spans[spanIndex];
      final spanAvail = currentSpan.text.length - spanCharOffset;
      if (spanAvail <= chunkRemaining) {
        final slice = currentSpan.text.substring(spanCharOffset);
        if (slice.isNotEmpty) {
          chunkSpans.add(AnsiSpan(slice, currentSpan.style));
        }
        chunkRemaining -= spanAvail;
        spanIndex++;
        spanCharOffset = 0;
      } else {
        final slice = currentSpan.text.substring(
          spanCharOffset,
          spanCharOffset + chunkRemaining,
        );
        chunkSpans.add(AnsiSpan(slice, currentSpan.style));
        spanCharOffset += chunkRemaining;
        chunkRemaining = 0;
      }
    }

    lines.add(JobTraceLine(chunkText, section: sectionName, spans: chunkSpans));
    charIndex = chunkEnd;
  }
}

void _applyMarker(
  RegExpMatch match,
  List<JobTraceLine> lines,
  List<JobTraceSection> sections,
  List<_OpenSection> stack,
) {
  final kind = match.group(1)!;
  final timestamp = int.parse(match.group(2)!);
  final name = match.group(3)!;
  if (kind == 'start') {
    if (stack.length >= JobTrace.maxDepth ||
        sections.length + stack.length >= JobTrace.maxSections) {
      return;
    }
    stack.add(
      _OpenSection(
        name: name,
        start: timestamp,
        collapsed: match.group(4) == 'true',
        startLine: lines.length,
        depth: stack.length,
      ),
    );
    return;
  }
  final index = stack.lastIndexWhere((section) => section.name == name);
  if (index < 0) return;
  while (stack.length - 1 > index) {
    _close(stack.removeLast(), null, lines.length, sections);
  }
  _close(stack.removeLast(), timestamp, lines.length, sections);
}

void _close(
  _OpenSection open,
  int? end,
  int endLine,
  List<JobTraceSection> sections,
) {
  sections.add(
    JobTraceSection(
      name: open.name,
      start: open.start,
      end: end,
      collapsed: open.collapsed,
      startLine: open.startLine,
      endLine: endLine,
      depth: open.depth,
    ),
  );
}
