import '../../l10n/l10n.dart';
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
  // Only the placeholder words are translated; the Markdown syntax and the
  // selection offsets stay in code.
  final url = l10n.url;
  if (selected.isEmpty) {
    final label = l10n.linkText;
    final snippet = '[$label]($url)';
    final next = text.replaceRange(range.start, range.end, snippet);
    final base = range.start + 1;
    return MarkupEdit(next, base, base + label.length);
  }
  final snippet = '[$selected]($url)';
  final next = text.replaceRange(range.start, range.end, snippet);
  final base = range.start + selected.length + 3;
  return MarkupEdit(next, base, base + url.length);
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
    String? category,
    this.isMergeRequestOnly = false,
  }) : _categoryArg = category;

  final String command;
  final String label;
  final String description;
  final String? _categoryArg;
  String get category => _categoryArg ?? l10n.quickActionGeneral;
  final bool isMergeRequestOnly;
}

List<QuickActionDef> get defaultQuickActions => <QuickActionDef>[
  QuickActionDef(
    command: '/close',
    label: l10n.closeAction,
    description: l10n.closeIssueOrMr,
    category: l10n.status,
  ),
  QuickActionDef(
    command: '/reopen',
    label: l10n.reopen,
    description: l10n.reopenClosedIssueOrMr,
    category: l10n.status,
  ),
  QuickActionDef(
    command: '/ready',
    label: l10n.markAsReady,
    description: l10n.removeDraftMarkReady,
    category: l10n.status,
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/draft',
    label: l10n.markAsDraft,
    description: l10n.markMrAsDraft,
    category: l10n.status,
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/assign @me',
    label: l10n.assignToMe,
    description: l10n.assignToCurrentAccount,
    category: l10n.assignAndReview,
  ),
  QuickActionDef(
    command: '/unassign',
    label: l10n.unassign,
    description: l10n.removeAllAssignees,
    category: l10n.assignAndReview,
  ),
  QuickActionDef(
    command: '/approve',
    label: l10n.approve,
    description: l10n.approveMergeRequest,
    category: l10n.assignAndReview,
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/unapprove',
    label: l10n.revokeApproval,
    description: l10n.revokeMrApproval,
    category: l10n.assignAndReview,
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/merge',
    label: l10n.autoMerge,
    description: l10n.autoMergeWhenCiSucceeds,
    category: l10n.assignAndReview,
    isMergeRequestOnly: true,
  ),
  QuickActionDef(
    command: '/label ~',
    label: l10n.addLabel,
    description: l10n.addLabelToItem,
    category: l10n.labelsAndMilestones,
  ),
  QuickActionDef(
    command: '/unlabel ~',
    label: l10n.removeLabel,
    description: l10n.removeLabelFromItem,
    category: l10n.labelsAndMilestones,
  ),
  QuickActionDef(
    command: '/milestone %',
    label: l10n.milestoneLabel,
    description: l10n.setTargetMilestone,
    category: l10n.labelsAndMilestones,
  ),
  QuickActionDef(
    command: '/spend 1h',
    label: l10n.addSpentTime,
    description: l10n.addSpentTimeExample,
    category: l10n.timeTracking,
  ),
  QuickActionDef(
    command: '/estimate 1d',
    label: l10n.timeEstimate,
    description: l10n.setTimeEstimateExample,
    category: l10n.timeTracking,
  ),
  QuickActionDef(
    command: '/lock',
    label: l10n.lockThread,
    description: l10n.lockThreadMembersOnly,
    category: l10n.threadManagement,
  ),
  QuickActionDef(
    command: '/unlock',
    label: l10n.unlock,
    description: l10n.unlockThread,
    category: l10n.threadManagement,
  ),
];

