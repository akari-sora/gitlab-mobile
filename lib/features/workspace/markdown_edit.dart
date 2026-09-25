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
  final atLineStart = range.start == 0 || text[range.start - 1] == '\n';
  final atLineEnd = range.end >= text.length || text[range.end] == '\n';
  final lead = atLineStart ? '' : '\n';
  final tail = atLineEnd ? '' : '\n';
  final snippet = selected.isEmpty ? '$lead```\n\n```$tail' : '$lead```\n$selected\n```$tail';
  final next = text.replaceRange(range.start, range.end, snippet);
  final base = range.start + lead.length + 4;
  return MarkupEdit(next, base, selected.isEmpty ? base : base + selected.length);
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
  final snippet = '${needsSpace ? ' ' : ''}@$username ';
  final next = text.replaceRange(range.start, range.end, snippet);
  final caret = range.start + snippet.length;
  return MarkupEdit(next, caret, caret);
}

MarkupEdit insertQuickAction(String text, int rawStart, int rawEnd, String command) {
  final range = _range(text, rawStart, rawEnd);
  final lineStart = range.start == 0 ? 0 : text.lastIndexOf('\n', range.start - 1) + 1;
  final beforeCaretOnLine = text.substring(lineStart, range.start);
  final cmdClean = command.trim();

  // If the user already started typing a slash command on this line, replace that partial prefix
  final partialMatch = RegExp(r'^\s*(/\w*)$').firstMatch(beforeCaretOnLine);
  if (partialMatch != null) {
    final replaceStart = lineStart + partialMatch.start;
    final snippet = '$cmdClean\n';
    final next = text.replaceRange(replaceStart, range.end, snippet);
    final caret = replaceStart + snippet.length;
    return MarkupEdit(next, caret, caret);
  }

  final atLineStart = range.start == 0 || text[range.start - 1] == '\n';
  final lead = atLineStart ? '' : '\n';
  final snippet = '$lead$cmdClean\n';
  final next = text.replaceRange(range.start, range.end, snippet);
  final caret = range.start + snippet.length;
  return MarkupEdit(next, caret, caret);
}

List<String> extractQuickActions(String text) {
  final actions = <String>[];
  final lines = text.split('\n');
  final pattern = RegExp(r'^\s*(/\w+)');
  bool inCodeBlock = false;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      inCodeBlock = !inCodeBlock;
      continue;
    }
    if (inCodeBlock) continue;
    if (trimmed.startsWith('>')) continue;
    final match = pattern.firstMatch(line);
    if (match != null) {
      actions.add(match.group(1)!);
    }
  }
  return actions;
}

class QuickActionDef {
  const QuickActionDef({
    required this.command,
    required this.label,
    required this.description,
    this.category = '一般',
    this.isMergeRequestOnly = false,
  });

  final String command;
  final String label;
  final String description;
  final String category;
  final bool isMergeRequestOnly;
}

const defaultQuickActions = <QuickActionDef>[
  QuickActionDef(
    command: '/close',
    label: '關閉',
    description: '關閉此 Issue 或 MR',
    category: '狀態',
  ),
  QuickActionDef(
    command: '/reopen',
    label: '重新開啟',
    description: '重新開啟已關閉的 Issue 或 MR',
    category: '狀態',
  ),
  QuickActionDef(
    command: '/ready',
    label: '標記就緒',
    description: '移除 Draft/WIP 草稿狀態，標記為可審查',
    category: '狀態',
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/draft',
    label: '標記草稿',
    description: '將 MR 標記為草稿 (Draft)',
    category: '狀態',
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/assign @me',
    label: '指派給我',
    description: '將此項目指派給目前登入帳號',
    category: '指派與審查',
  ),
  QuickActionDef(
    command: '/unassign',
    label: '取消指派',
    description: '移除所有已被指派的成員',
    category: '指派與審查',
  ),
  QuickActionDef(
    command: '/approve',
    label: '核准',
    description: '核准此合併請求 (Approve MR)',
    category: '指派與審查',
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/unapprove',
    label: '撤銷核准',
    description: '撤銷對此合併請求的核准',
    category: '指派與審查',
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/merge',
    label: '自動合併',
    description: '當 CI 成功時自動執行合併 (Merge)',
    category: '指派與審查',
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/label ~',
    label: '加上標籤',
    description: '為此項目新增標籤',
    category: '標籤與里程碑',
  ),
  QuickActionDef(
    command: '/unlabel ~',
    label: '移除標籤',
    description: '從此項目移除標籤',
    category: '標籤與里程碑',
  ),
  QuickActionDef(
    command: '/milestone %',
    label: '里程碑',
    description: '設定目標里程碑',
    category: '標籤與里程碑',
  ),
  QuickActionDef(
    command: '/spend 1h',
    label: '登記耗時',
    description: '登記實際工時（例如 1h, 30m, 2d）',
    category: '工時追蹤',
  ),
  QuickActionDef(
    command: '/estimate 1d',
    label: '預估工時',
    description: '設定預估所需工時（例如 1d, 4h）',
    category: '工時追蹤',
  ),
  QuickActionDef(
    command: '/lock',
    label: '鎖定討論',
    description: '鎖定討論串，僅專案成員可留言',
    category: '討論管理',
  ),
  QuickActionDef(
    command: '/unlock',
    label: '解除鎖定',
    description: '解除討論串鎖定',
    category: '討論管理',
  ),
];

