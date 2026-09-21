class MarkupEdit {
  const MarkupEdit(this.text, this.base, this.extent);
  final String text;
  final int base, extent;
}

({int start, int end}) _range(String text, int start, int end) {
  if (start < 0 || end < 0) {
    return (start: text.length, end: text.length);
  }
  if (start > end) {
    final swap = start;
    start = end;
    end = swap;
  }
  if (start > text.length) start = text.length;
  if (end > text.length) end = text.length;
  return (start: start, end: end);
}

MarkupEdit wrapSelection(
  String text,
  int rawStart,
  int rawEnd,
  String before,
  String after, {
  String placeholder = '',
}) {
  final range = _range(text, rawStart, rawEnd);
  final selected = text.substring(range.start, range.end);
  final inner = selected.isEmpty ? placeholder : selected;
  final snippet = '$before$inner$after';
  final next = text.replaceRange(range.start, range.end, snippet);
  final base = range.start + before.length;
  return MarkupEdit(next, base, base + inner.length);
}

MarkupEdit prefixLines(String text, int rawStart, int rawEnd, String prefix) {
  final range = _range(text, rawStart, rawEnd);
  final lineStart = range.start == 0 ? 0 : text.lastIndexOf('\n', range.start - 1) + 1;
  var cursor = range.end;
  if (cursor > range.start && cursor > 0 && text[cursor - 1] == '\n') cursor -= 1;
  final newline = text.indexOf('\n', cursor);
  final blockEnd = newline == -1 ? text.length : newline;
  final block = text.substring(lineStart, blockEnd);
  final lines = block.split('\n');
  final prefixed = lines
      .map((line) => line.startsWith(prefix) ? line : '$prefix$line')
      .join('\n');
  final next = text.replaceRange(lineStart, blockEnd, prefixed);
  if (range.start == range.end) {
    final added = lines.first.startsWith(prefix) ? 0 : prefix.length;
    final caret = range.start + added;
    return MarkupEdit(next, caret, caret);
  }
  final firstAdded = lines.first.startsWith(prefix) ? 0 : prefix.length;
  return MarkupEdit(next, range.start + firstAdded, range.end + prefixed.length - block.length);
}

MarkupEdit insertCodeBlock(String text, int rawStart, int rawEnd) {
  final range = _range(text, rawStart, rawEnd);
  final selected = text.substring(range.start, range.end);
  if (selected.isEmpty) {
    const snippet = '```\n\n```';
    final next = text.replaceRange(range.start, range.end, snippet);
    final caret = range.start + 4;
    return MarkupEdit(next, caret, caret);
  }
  final snippet = '```\n$selected\n```';
  final next = text.replaceRange(range.start, range.end, snippet);
  final base = range.start + 4;
  return MarkupEdit(next, base, base + selected.length);
}

MarkupEdit insertLink(String text, int rawStart, int rawEnd) {
  final range = _range(text, rawStart, rawEnd);
  final selected = text.substring(range.start, range.end);
  if (selected.isEmpty) {
    const label = '文字';
    const snippet = '[$label](網址)';
    final next = text.replaceRange(range.start, range.end, snippet);
    final base = range.start + 1;
    return MarkupEdit(next, base, base + label.length);
  }
  final snippet = '[$selected](網址)';
  final next = text.replaceRange(range.start, range.end, snippet);
  final base = range.start + selected.length + 3;
  return MarkupEdit(next, base, base + '網址'.length);
}

MarkupEdit insertText(
  String text,
  int rawStart,
  int rawEnd,
  String insertion, {
  bool breakBefore = false,
}) {
  final range = _range(text, rawStart, rawEnd);
  final atLineStart = range.start == 0 || text[range.start - 1] == '\n';
  final snippet = breakBefore && !atLineStart ? '\n$insertion' : insertion;
  final next = text.replaceRange(range.start, range.end, snippet);
  final caret = range.start + snippet.length;
  return MarkupEdit(next, caret, caret);
}

MarkupEdit insertMention(String text, int rawStart, int rawEnd, String username) {
  final range = _range(text, rawStart, rawEnd);
  final needsSpace = range.start > 0 && !RegExp(r'\s').hasMatch(text[range.start - 1]);
  final snippet = '${needsSpace ? ' ' : ''}@$username';
  final next = text.replaceRange(range.start, range.end, snippet);
  final caret = range.start + snippet.length;
  return MarkupEdit(next, caret, caret);
}
