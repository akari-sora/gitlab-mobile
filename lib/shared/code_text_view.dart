import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/syntax_highlighter.dart';
import '../l10n/l10n.dart';
import 'theme.dart';

/// The lines of one text file, prepared for [CodeTextView]: lower-case copies
/// for the in-file search and the longest line for the no-wrap width.
final class CodeTextIndex {
  CodeTextIndex(String text)
    : lines = text.split('\n'),
      searchLines = const [],
      longestLineLength = 0 {
    searchLines = [for (final line in lines) line.toLowerCase()];
    longestLineLength = lines.fold<int>(0, (n, l) => math.max(n, l.length));
  }

  static final empty = CodeTextIndex('');

  final List<String> lines;
  List<String> searchLines;
  int longestLineLength;

  /// The line indices that contain [query], ignoring case; all for a blank one.
  List<int> filter(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return List<int>.generate(lines.length, (i) => i);
    return [
      for (var i = 0; i < searchLines.length; i++)
        if (searchLines[i].contains(q)) i,
    ];
  }
}

/// Presentation only: line numbers, syntax colours, wrap and the rows that a
/// search left visible. It never reads files or the network; the page that
/// owns it loads the text, keeps the search and handles a line tap.
class CodeTextView extends StatelessWidget {
  const CodeTextView({
    super.key,
    required this.index,
    required this.visibleIndices,
    required this.filePath,
    required this.syntaxSpans,
    required this.wrap,
    required this.vertical,
    required this.horizontal,
    this.selectedLine,
    this.onLineTap,
    this.lineKeyPrefix = 'repository-file-line-',
  });

  static const codeStyle = TextStyle(
    fontFamily: codeFontFamily,
    fontFamilyFallback: ['Menlo', 'monospace'],
    fontSize: 13,
    height: 1.55,
  );

  /// Shared code padding matched by [CodeSkeleton].
  static const EdgeInsets padding = EdgeInsets.all(12);

  /// Width reserved for the line-number gutter.
  static const double gutterWidth = 48;

  /// Gap between the line-number gutter and code text.
  static const double gutterGap = 8;

  /// Vertical pitch of each code row (24dp minimum target + 2dp vertical padding).
  static const double linePitch = 26;

  final CodeTextIndex index;
  final List<int> visibleIndices;
  final String filePath;
  final SyntaxSpanCache syntaxSpans;
  final bool wrap;
  final ScrollController vertical;
  final ScrollController horizontal;
  final int? selectedLine;

  /// A tap on a line number; it copies the line's permalink where one exists.
  final ValueChanged<int>? onLineTap;
  final String lineKeyPrefix;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fontSize = MediaQuery.textScalerOf(context).scale(13);
      final contentWidth = wrap
          ? constraints.maxWidth
          : math.max(
              constraints.maxWidth,
              math.min(24000.0, index.longestLineLength * fontSize * 0.65 + 80),
            );
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Scrollbar(
          controller: horizontal,
          child: SingleChildScrollView(
            controller: horizontal,
            scrollDirection: Axis.horizontal,
            physics: wrap ? const NeverScrollableScrollPhysics() : null,
            child: SizedBox(
              width: contentWidth,
              height: constraints.maxHeight,
              child: SelectionArea(
                child: ListView.builder(
                  controller: vertical,
                  itemCount: visibleIndices.length,
                  padding: EdgeInsets.symmetric(
                    vertical: padding.top,
                  ),
                  itemBuilder: (context, row) => _line(context, row),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _line(BuildContext context, int row) {
    final theme = Theme.of(context);
    final lineIndex = visibleIndices[row];
    final lineNumber = lineIndex + 1;
    final isSelected = selectedLine == lineNumber;
    final lineContent = index.lines[lineIndex];
    final tap = onLineTap == null ? null : () => onLineTap!(lineNumber);
    return Container(
      key: ValueKey('$lineKeyPrefix$lineNumber'),
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : null,
      padding: EdgeInsets.symmetric(
        horizontal: padding.left,
        vertical: 1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: tap != null,
            selected: isSelected,
            label: l10n.lineNumber(lineNumber),
            hint: tap == null ? null : l10n.tapCopyLinePermalink,
            excludeSemantics: true,
            onTap: tap,
            child: InkWell(
              onTap: tap,
              borderRadius: BorderRadius.circular(4),
              // Code reads line by line: rows stay at text height and the
              // number keeps the 24dp WCAG 2.5.8 minimum in a 48dp-wide column.
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: gutterWidth,
                  minHeight: 24,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '$lineNumber',
                    textScaler: MediaQuery.textScalerOf(
                      context,
                    ).clamp(maxScaleFactor: 1.3),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isSelected ? theme.colorScheme.primary : null,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: gutterGap),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text.rich(
                lineContent.isEmpty
                    ? const TextSpan(text: ' ')
                    : syntaxSpans.highlight(
                        lineIndex,
                        lineContent,
                        extension: filePath,
                        isDark: theme.brightness == Brightness.dark,
                        baseStyle: codeStyle,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
