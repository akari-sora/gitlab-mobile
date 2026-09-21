/// GitLab CI traces, with `section_start` / `section_end` markers removed.
final class JobTrace {
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

  factory JobTrace.parse(String raw) {
    final plain = raw.replaceAll(_ansi, '');
    if (plain.isEmpty) return JobTrace.empty;
    final lines = <JobTraceLine>[];
    final sections = <JobTraceSection>[];
    final stack = <_OpenSection>[];
    for (final line in plain.split('\n')) {
      _takeLine(line, lines, sections, stack);
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
  const JobTraceLine(this.text, {this.section});
  final String text;

  /// Innermost open section name, when this line is inside one.
  final String? section;
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
) {
  var cursor = 0;
  var sawMarker = false;
  for (final match in JobTrace._marker.allMatches(line)) {
    sawMarker = true;
    final before = line.substring(cursor, match.start);
    if (before.isNotEmpty) _emit(before, lines, stack);
    _applyMarker(match, lines, sections, stack);
    cursor = match.end;
  }
  final rest = line.substring(cursor);
  if (!sawMarker || rest.isNotEmpty) _emit(rest, lines, stack);
}

void _emit(String text, List<JobTraceLine> lines, List<_OpenSection> stack) {
  lines.add(JobTraceLine(text, section: stack.isEmpty ? null : stack.last.name));
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
