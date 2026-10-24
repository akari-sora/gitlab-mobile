import 'dart:math' as math;

import '../instance.dart';
import 'ai_failure.dart';
import 'redaction.dart';
import 'tools/write_ledger.dart' show AiFixedConfirmReason;
import 'tools/write_preview.dart';
import 'write_text.dart' as text;

final class AiExactEdit {
  const AiExactEdit(this.oldText, this.newText);

  final String oldText;
  final String newText;
}

sealed class AiExactEditResult {
  const AiExactEditResult();
}

final class AiExactEditApplied extends AiExactEditResult {
  AiExactEditApplied({
    required this.finalText,
    required List<AiDiffLine> diff,
    required this.scan,
  }) : diff = List.unmodifiable(diff);

  final String finalText;
  final List<AiDiffLine> diff;
  final AiTextScan scan;
}

final class AiExactEditRejected extends AiExactEditResult {
  const AiExactEditRejected(this.reasonCode, {this.editIndex});

  final String reasonCode;
  final int? editIndex;
}

/// Resolve all anchors against the original, including overlapping occurrences.
AiExactEditResult applyExactEdits(
  String original,
  List<AiExactEdit> edits, {
  int maxEdits = 20,
}) {
  if (edits.isEmpty) return const AiExactEditRejected('noEdits');
  if (edits.length > maxEdits) {
    return const AiExactEditRejected('tooManyEdits');
  }
  final located = <_Edit>[];
  for (var i = 0; i < edits.length; i++) {
    final edit = edits[i];
    // An empty anchor cannot identify an insertion point unambiguously.
    if (edit.oldText.isEmpty) {
      return AiExactEditRejected('fragmentNotUnique', editIndex: i);
    }
    final start = original.indexOf(edit.oldText);
    if (start < 0) {
      return AiExactEditRejected('fragmentNotFound', editIndex: i);
    }
    if (original.indexOf(edit.oldText, start + 1) >= 0) {
      return AiExactEditRejected('fragmentNotUnique', editIndex: i);
    }
    located.add(_Edit(start, start + edit.oldText.length, edit.newText, i));
  }
  located.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < located.length; i++) {
    if (located[i].start < located[i - 1].end) {
      return AiExactEditRejected(
        'fragmentsOverlap',
        editIndex: located[i].index,
      );
    }
  }
  final output = StringBuffer();
  var cursor = 0;
  for (final edit in located) {
    output
      ..write(original.substring(cursor, edit.start))
      ..write(edit.replacement);
    cursor = edit.end;
  }
  output.write(original.substring(cursor));
  final finalText = output.toString();
  if (finalText == original) return const AiExactEditRejected('noChange');
  final changed = located.where(
    (edit) => original.substring(edit.start, edit.end) != edit.replacement,
  ).toList();
  return AiExactEditApplied(
    finalText: finalText,
    diff: unifiedDiff(original, finalText),
    scan: AiTextScan(
      original: original,
      newTexts: [for (final edit in changed) edit.replacement],
      windows: _windows(original, finalText, changed),
    ),
  );
}

final class AiFragmentCheck {
  AiFragmentCheck({
    this.blockCode,
    List<AiFixedConfirmReason> confirmReasons = const [],
    this.preexistingSecretHits = 0,
  }) : confirmReasons = List.unmodifiable(confirmReasons);

  final String? blockCode;
  final List<AiFixedConfirmReason> confirmReasons;
  final int preexistingSecretHits;
}

/// New fragments are scanned independently, then paired context windows catch
/// secrets assembled across either boundary, including deletion-only joins.
AiFragmentCheck checkFragments(
  AiTextScan scan, {
  required Set<String> knownSecrets,
  required GitLabInstance instance,
  required text.AiVisibilityContext visibility,
}) {
  final redactor = Redactor(secrets: _Secrets(knownSecrets));
  final reasons = <AiFixedConfirmReason>{
    if (visibility.polluted || visibility.visibilityUnreadable)
      AiFixedConfirmReason.confidentialOrVisibilityMix,
  };
  try {
    var preexisting = redactor.redactSourceRanges(scan.original).length;
    for (final text in scan.newTexts) {
      if (_marker.hasMatch(text)) {
        return AiFragmentCheck(blockCode: 'redactionMarker');
      }
      if (redactor.redactSourceRanges(text).isNotEmpty) {
        return AiFragmentCheck(blockCode: 'secret');
      }
    }
    for (final window in scan.windows) {
      final markerAfter = _marker.allMatches(window.after).toList();
      if (_touchesChange(window, markerAfter.map(
            (hit) => (start: hit.start, end: hit.end),
          )) ||
          _hasNewHits(_markerHits(window.before),
              [for (final hit in markerAfter) hit.group(0)!])) {
        return AiFragmentCheck(blockCode: 'redactionMarker');
      }
      final before = redactor.redactSourceRanges(window.before);
      final after = redactor.redactSourceRanges(window.after);
      if (_touchesChange(window, after) || _hasNewHits(
        [for (final hit in before) window.before.substring(hit.start, hit.end)],
        [for (final hit in after) window.after.substring(hit.start, hit.end)],
      )) {
        return AiFragmentCheck(blockCode: 'secret');
      }
      // Merged windows are disjoint, so removed old hits are counted once.
      preexisting -= before.length - after.length;
      if (scan.markdown) {
        final prepared = text.prepareWriteText(
          textClass: text.AiTextClass.plainContent,
          // Existing upload syntax can make the whole-field writer return
          // before mention/media classification. Neutralize only its reserved
          // syntax in this scan-only copy, retaining URL hosts and markup.
          // The actual payload and the independent secret scans stay exact.
          modelText: window.after.replaceAllMapped(
            _uploadSyntax,
            (match) => match.group(1) == null
                ? 'x' * match.group(0)!.length
                : '${match.group(0)!.substring(0, 8)}${'x' * 32}',
          ),
          field: null,
          placeholders: text.UploadPlaceholderTable(instance: instance),
          knownSecrets: knownSecrets,
          aiAttribution: false,
          visibility: text.AiVisibilityContext(
            polluted: visibility.polluted,
            visibilityUnreadable: visibility.visibilityUnreadable,
            userMessageDomains: visibility.userMessageDomains,
            targetProjectPath: visibility.targetProjectPath,
            renderedMarkdown: true,
            scopeGrants: visibility.scopeGrants,
          ),
          secretFragments: const [],
        );
        for (final reason in prepared.confirmReasons) {
          switch (reason) {
            case text.AiFixedConfirmReason.massMention:
              reasons.add(AiFixedConfirmReason.massMention);
            case text.AiFixedConfirmReason.externalMedia:
              reasons.add(AiFixedConfirmReason.externalMediaInRenderedMarkdown);
            case text.AiFixedConfirmReason.closingOrCrossProject:
            case text.AiFixedConfirmReason.hiddenContentRemoved:
              // File Markdown is not class A or a commit message (§5.9).
              break;
          }
        }
        if (prepared.levelConfirmReasons.isNotEmpty) {
          reasons.add(AiFixedConfirmReason.confidentialOrVisibilityMix);
        }
      }
    }
    for (final file in scan.files) {
      final checked = checkFragments(file,
          knownSecrets: knownSecrets, instance: instance, visibility: visibility);
      if (checked.blockCode != null) return checked;
      reasons.addAll(checked.confirmReasons);
      preexisting += checked.preexistingSecretHits;
    }
    return AiFragmentCheck(
      confirmReasons: reasons.toList(),
      preexistingSecretHits: math.max(0, preexisting),
    );
  } on AiFailure {
    // An unavailable scan never authorizes a write.
    return AiFragmentCheck(blockCode: 'secret');
  }
}

bool isRenderedMarkdownPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.md') || lower.endsWith('.markdown');
}

final _marker = RegExp(r'\[REDACTED|<gitlab_data|</gitlab_data>');
final _uploadSyntax = RegExp(
  r'uploads/([0-9a-f]{32})(?![0-9a-f])|\[\[(?:upload|attachment):',
  caseSensitive: false,
);

List<String> _markerHits(String text) => [
  for (final hit in _marker.allMatches(text)) hit.group(0)!,
];

typedef _Span = ({int start, int end});

// Shared preview windows have no edit coordinates. Keep only immutable offsets
// on their process-local identities, never file content or account data. Copies
// of AiTextScan must retain its window objects; a reconstructed window loses
// provenance and therefore fails closed when it contains an ambiguous hit.
final _changedSpans = Expando<List<_Span>>();

bool _touchesChange(AiTextWindow window, Iterable<_Span> hits) {
  final changes = _changedSpans[window];
  if (changes == null) return hits.isNotEmpty;
  return hits.any((hit) => changes.any((change) => change.start == change.end
      ? hit.start < change.start && change.start < hit.end
      : hit.start < change.end && change.start < hit.end));
}

bool _hasNewHits(List<String> before, List<String> after) {
  final remaining = <String, int>{};
  for (final hit in before) {
    remaining[hit] = (remaining[hit] ?? 0) + 1;
  }
  for (final hit in after) {
    final count = remaining[hit] ?? 0;
    if (count == 0) return true;
    remaining[hit] = count - 1;
  }
  return false;
}

final class _Secrets implements KnownSecretsSource {
  const _Secrets(this.current);

  @override
  final Set<String> current;
}

final class _Edit {
  const _Edit(this.start, this.end, this.replacement, this.index);

  final int start;
  final int end;
  final String replacement;
  final int index;
  int get delta => replacement.length - (end - start);
}

List<AiTextWindow> _windows(String before, String after, List<_Edit> edits) {
  final starts = <int>[0];
  for (final match in _lineBreak.allMatches(before)) {
    starts.add(match.end);
  }
  int lineAt(int offset) {
    var low = 0;
    var high = starts.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (starts[middle] <= offset) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low;
  }

  final ranges = <({int start, int end})>[];
  for (final edit in edits) {
    final start = starts[math.max(0, lineAt(edit.start) - 3)];
    final endLine = lineAt(edit.end - 1) + 4;
    final end = endLine < starts.length ? starts[endLine] : before.length;
    if (ranges.isNotEmpty && start <= ranges.last.end) {
      final previous = ranges.removeLast();
      ranges.add((start: previous.start, end: math.max(previous.end, end)));
    } else {
      ranges.add((start: start, end: end));
    }
  }
  final windows = <AiTextWindow>[];
  for (final range in ranges) {
    final afterStart = range.start + edits.where((e) => e.end <= range.start).fold<int>(
      0,
      (sum, e) => sum + e.delta,
    );
    final afterEnd = range.end + edits.where((e) => e.end <= range.end).fold<int>(
      0,
      (sum, e) => sum + e.delta,
    );
    final window = AiTextWindow(
      before: before.substring(range.start, range.end),
      after: after.substring(afterStart, afterEnd),
    );
    final spans = <_Span>[];
    var delta = 0;
    for (final edit in edits) {
      if (edit.start >= range.start && edit.end <= range.end) {
        final start = edit.start + delta - afterStart;
        spans.add((start: start, end: start + edit.replacement.length));
      }
      delta += edit.delta;
    }
    _changedSpans[window] = List.unmodifiable(spans);
    windows.add(window);
  }
  return windows;
}

final _lineBreak = RegExp(r'\r\n|\r|\n');

List<String> _lines(String text) {
  final result = <String>[];
  var cursor = 0;
  for (final match in _lineBreak.allMatches(text)) {
    result.add(text.substring(cursor, match.end));
    cursor = match.end;
  }
  if (cursor < text.length) result.add(text.substring(cursor));
  return result;
}

/// Unified hunks with independent old/new line numbers and bounded context.
/// Diff text omits LF, retaining CR so line-ending changes remain observable.
/// The standard no-newline marker is represented as hunk metadata.
List<AiDiffLine> unifiedDiff(String before, String after, {int context = 3}) {
  if (context < 0) throw ArgumentError.value(context, 'context');
  if (before == after) return const [];
  final oldLines = _lines(before);
  final newLines = _lines(after);
  final operations = _diff(oldLines, newLines);
  final rows = <_Row>[];
  var oldLine = 1;
  var newLine = 1;
  for (final operation in operations) {
    rows.add(_Row(operation.kind, operation.text, oldLine, newLine));
    if (operation.kind != AiDiffLineKind.addition) oldLine++;
    if (operation.kind != AiDiffLineKind.deletion) newLine++;
  }
  final hunks = <({int start, int end})>[];
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].kind == AiDiffLineKind.context) continue;
    final start = math.max(0, i - context);
    final end = math.min(rows.length, i + context + 1);
    if (hunks.isNotEmpty && start <= hunks.last.end) {
      final previous = hunks.removeLast();
      hunks.add((start: previous.start, end: math.max(previous.end, end)));
    } else {
      hunks.add((start: start, end: end));
    }
  }
  final result = <AiDiffLine>[];
  for (final hunk in hunks) {
    final content = rows.sublist(hunk.start, hunk.end);
    final oldCount = content.where((r) => r.kind != AiDiffLineKind.addition).length;
    final newCount = content.where((r) => r.kind != AiDiffLineKind.deletion).length;
    final oldStart = content.first.oldLine - (oldCount == 0 ? 1 : 0);
    final newStart = content.first.newLine - (newCount == 0 ? 1 : 0);
    result.add(AiDiffLine(
      kind: AiDiffLineKind.hunk,
      text: '@@ -$oldStart,$oldCount +$newStart,$newCount @@',
      oldLine: oldStart,
      newLine: newStart,
    ));
    for (final row in content) {
      result.add(AiDiffLine(
        kind: row.kind,
        text: row.text.endsWith('\n')
            ? row.text.substring(0, row.text.length - 1)
            : row.text,
        oldLine: row.kind == AiDiffLineKind.addition ? null : row.oldLine,
        newLine: row.kind == AiDiffLineKind.deletion ? null : row.newLine,
      ));
      if (!row.text.endsWith('\n') && !row.text.endsWith('\r')) {
        result.add(const AiDiffLine(
          kind: AiDiffLineKind.hunk,
          text: r'\ No newline at end of file',
        ));
      }
    }
  }
  return List.unmodifiable(result);
}

typedef _Operation = ({AiDiffLineKind kind, String text});

final class _Row {
  const _Row(this.kind, this.text, this.oldLine, this.newLine);

  final AiDiffLineKind kind;
  final String text;
  final int oldLine;
  final int newLine;
}

List<_Operation> _diff(List<String> before, List<String> after) {
  var prefix = 0;
  while (prefix < before.length &&
      prefix < after.length &&
      before[prefix] == after[prefix]) {
    prefix++;
  }
  var oldEnd = before.length;
  var newEnd = after.length;
  while (oldEnd > prefix && newEnd > prefix &&
      before[oldEnd - 1] == after[newEnd - 1]) {
    oldEnd--;
    newEnd--;
  }
  return [
    for (var i = 0; i < prefix; i++)
      (kind: AiDiffLineKind.context, text: before[i]),
    ..._myers(before.sublist(prefix, oldEnd), after.sublist(prefix, newEnd)),
    for (var i = oldEnd; i < before.length; i++)
      (kind: AiDiffLineKind.context, text: before[i]),
  ];
}

List<_Operation> _myers(List<String> before, List<String> after) {
  final trace = <Map<int, int>>[];
  var frontier = <int, int>{1: 0};
  // Bound trace memory and work on unrelated 20,000-line files. The fallback
  // is an exact replacement diff, with no invented or omitted content.
  final limit = math.min(before.length + after.length, 256);
  for (var depth = 0; depth <= limit; depth++) {
    final next = <int, int>{};
    for (var k = -depth; k <= depth; k += 2) {
      var x = k == -depth ||
          (k != depth && (frontier[k - 1] ?? -1) < (frontier[k + 1] ?? -1))
          ? frontier[k + 1] ?? 0
          : (frontier[k - 1] ?? 0) + 1;
      var y = x - k;
      while (x < before.length && y < after.length && before[x] == after[y]) {
        x++;
        y++;
      }
      next[k] = x;
      if (x >= before.length && y >= after.length) {
        trace.add(next);
        return _backtrack(before, after, trace);
      }
    }
    trace.add(next);
    frontier = next;
  }
  return [
    for (final text in before) (kind: AiDiffLineKind.deletion, text: text),
    for (final text in after) (kind: AiDiffLineKind.addition, text: text),
  ];
}

List<_Operation> _backtrack(
  List<String> before,
  List<String> after,
  List<Map<int, int>> trace,
) {
  var x = before.length;
  var y = after.length;
  final reversed = <_Operation>[];
  for (var depth = trace.length - 1; depth > 0; depth--) {
    final frontier = trace[depth - 1];
    final k = x - y;
    final previousK = k == -depth ||
        (k != depth && (frontier[k - 1] ?? -1) < (frontier[k + 1] ?? -1))
        ? k + 1 : k - 1;
    final previousX = frontier[previousK] ?? 0;
    final previousY = previousX - previousK;
    while (x > previousX && y > previousY) {
      reversed.add((kind: AiDiffLineKind.context, text: before[--x]));
      y--;
    }
    if (x == previousX) {
      reversed.add((kind: AiDiffLineKind.addition, text: after[--y]));
    } else {
      reversed.add((kind: AiDiffLineKind.deletion, text: before[--x]));
    }
  }
  while (x > 0 && y > 0) {
    reversed.add((kind: AiDiffLineKind.context, text: before[--x]));
    y--;
  }
  return reversed.reversed.toList();
}
