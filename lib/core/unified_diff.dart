/// An anchor comes from validated unified-diff hunks, never from widget indices.
final class DiffLine {
  const DiffLine(this.text, this.kind, {this.oldLine, this.newLine});
  final String text;
  final String kind;
  final int? oldLine;
  final int? newLine;
  bool get commentable => oldLine != null || newLine != null;
}

List<DiffLine> parseUnifiedDiff(String source) {
  if (source.length > 2 * 1024 * 1024) {
    throw const FormatException('Diff exceeds rendering budget');
  }
  final output = <DiffLine>[];
  final header = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');
  int? oldLine, newLine;
  var oldRemaining = 0, newRemaining = 0;
  var foundHunk = false;
  for (final line in source.split('\n')) {
    final match = header.firstMatch(line);
    if (match != null) {
      if (oldRemaining != 0 || newRemaining != 0) {
        throw const FormatException('Incomplete diff hunk');
      }
      oldLine = int.parse(match.group(1)!);
      oldRemaining = int.parse(match.group(2) ?? '1');
      newLine = int.parse(match.group(3)!);
      newRemaining = int.parse(match.group(4) ?? '1');
      foundHunk = true;
      output.add(DiffLine(line, 'hunk'));
      continue;
    }
    if (line.startsWith(r'\ No newline at end of file')) {
      output.add(DiffLine(line, 'meta'));
      continue;
    }
    if (line.isEmpty && oldRemaining == 0 && newRemaining == 0) {
      continue;
    }
    if (!foundHunk || oldLine == null || newLine == null || line.isEmpty) {
      throw const FormatException('Unrecognized diff content');
    }
    switch (line[0]) {
      case ' ':
        if (oldRemaining < 1 || newRemaining < 1) {
          throw const FormatException('Context outside hunk');
        }
        output.add(DiffLine(line.substring(1), 'context', oldLine: oldLine++, newLine: newLine++));
        oldRemaining--; newRemaining--;
      case '-':
        if (oldRemaining < 1) { throw const FormatException('Removal outside hunk'); }
        output.add(DiffLine(line.substring(1), 'remove', oldLine: oldLine++));
        oldRemaining--;
      case '+':
        if (newRemaining < 1) { throw const FormatException('Addition outside hunk'); }
        output.add(DiffLine(line.substring(1), 'add', newLine: newLine++));
        newRemaining--;
      default:
        throw const FormatException('Unrecognized diff line');
    }
    if (output.length > 20000) { throw const FormatException('Diff line budget exceeded'); }
  }
  if (oldRemaining != 0 || newRemaining != 0) {
    throw const FormatException('Truncated diff');
  }
  return List.unmodifiable(output);
}
