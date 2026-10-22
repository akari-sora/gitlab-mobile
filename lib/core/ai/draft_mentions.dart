import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;

/// What appending [text] to a GitLab comment would mention or reference.
final class DraftMentions {
  const DraftMentions({
    required this.text,
    required this.mentions,
    required this.neutralized,
    required this.references,
  });

  /// The draft text, with CRs normalized and verified mention code spans added.
  final String text;

  /// Remaining mentions without `@`, unique in order of first appearance.
  final List<String> mentions;

  /// How many mention tokens were wrapped in code spans.
  final int neutralized;

  /// Issue, merge request and work item references outside code.
  final int references;
}

final _mentionPattern = RegExp(
  r'(?<![A-Za-z0-9_])@([A-Za-z0-9_.][A-Za-z0-9_.\-/]*)',
);
final _trailingPunctuation = RegExp(r'[.\-/]+$');
final _referencePattern = RegExp(
  r'((?:https?://|/)[^\s<>]+)'
  r'|(?<![A-Za-z0-9_])(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]*[#!][0-9]+',
);
final _referencePathPattern = RegExp(
  r'/-/(?:issues|merge_requests|work_items)/[0-9]+(?=$|[^A-Za-z0-9_])',
);

/// Adds code spans only when reparsing proves that one mention was removed
/// without changing existing code. Unverified mentions remain for confirmation.
DraftMentions analyzeDraftMentions(
  String text, {
  bool keepNotifications = false,
  String existing = '',
}) {
  // GitLab's quick-action extractor normalizes CRLF and removes every other
  // CR from the whole note. Normalize before collecting answer offsets too.
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '');
  existing = existing.replaceAll('\r\n', '\n').replaceAll('\r', '');
  var result = text;
  var neutralized = 0;

  if (!keepNotifications) {
    // Stop collecting at 51: large drafts need only the final analysis below.
    final candidates = _mentionPattern.allMatches(text).take(51).toList();
    if (candidates.length <= 50 && candidates.isNotEmpty) {
      var previous = _analyze(_joinedDraft(existing, result));
      for (final candidate in candidates.reversed) {
        final token = candidate[0]!.replaceFirst(_trailingPunctuation, '');
        final proposedText = result.replaceRange(
          candidate.start,
          candidate.start + token.length,
          '`$token`',
        );
        final proposed = _analyze(_joinedDraft(existing, proposedText));
        if (proposed.mentions.length == previous.mentions.length - 1 &&
            _addsOnlyCode(previous.code, proposed.code, token)) {
          result = proposedText;
          previous = proposed;
          neutralized++;
        }
      }
    }
  }

  final analysis = _analyze(_joinedDraft(existing, result));
  final existingAnalysis = _analyze(existing);
  final addedReferences = analysis.references - existingAnalysis.references;
  return DraftMentions(
    text: result,
    mentions: List<String>.unmodifiable(
      _subtractMentions(analysis.mentions, existingAnalysis.mentions),
    ),
    neutralized: neutralized,
    references: addedReferences < 0 ? 0 : addedReferences,
  );
}

String _joinedDraft(String existing, String appended) =>
    existing.isEmpty ? appended : '$existing\n\n$appended';

List<String> _subtractMentions(List<String> joined, List<String> existing) {
  final remainingExisting = <String, int>{};
  for (final name in existing) {
    remainingExisting[name] = (remainingExisting[name] ?? 0) + 1;
  }

  final result = <String>[];
  final seen = <String>{};
  for (final name in joined) {
    final remaining = remainingExisting[name] ?? 0;
    if (remaining > 0) {
      remainingExisting[name] = remaining - 1;
    } else if (seen.add(name)) {
      result.add(name);
    }
  }
  return result;
}

bool _addsOnlyCode(
  Map<String, int> previous,
  Map<String, int> proposed,
  String token,
) {
  if (proposed.length !=
      previous.length + (previous.containsKey(token) ? 0 : 1)) {
    return false;
  }
  if (proposed[token] != (previous[token] ?? 0) + 1) return false;
  return previous.entries.every(
    (entry) =>
        proposed[entry.key] == entry.value + (entry.key == token ? 1 : 0),
  );
}

_Analysis _analyze(String text) {
  // GitHub-flavoured Markdown is this package's closest available match to
  // GitLab Flavored Markdown, including fenced code, tables and autolinks.
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
  ).parse(text);
  final analysis = _Analysis();

  void walkHtml(dom.Node node, {required bool skipReferences}) {
    if (node is dom.Element &&
        (node.localName == 'code' || node.localName == 'pre')) {
      return;
    }
    if (node is dom.Text) {
      analysis.mentions.addAll(
        _mentionPattern.allMatches(node.data).map((match) => match[1]!),
      );
      if (!skipReferences) {
        for (final match in _referencePattern.allMatches(node.data)) {
          final url = match[1];
          if (url == null || _isReferenceUrl(url)) analysis.references++;
        }
      }
    }
    for (final child in node.nodes) {
      walkHtml(child, skipReferences: skipReferences);
    }
  }

  void walk(
    md.Node node, {
    bool insideCode = false,
    bool skipReferences = false,
  }) {
    if (node is md.Element) {
      if (node.tag == 'code') {
        final value = node.textContent;
        analysis.code[value] = (analysis.code[value] ?? 0) + 1;
      }
      final blocked = insideCode || node.tag == 'code' || node.tag == 'pre';
      var skipChildReferences = skipReferences;
      if (!blocked && !skipReferences && node.tag == 'a') {
        final href = node.attributes['href'];
        if (href != null && _isReferenceUrl(href)) {
          analysis.references++;
          // A URL label can be split across multiple text nodes. Count the
          // link itself once, including for autolinks with identical labels.
          final label = node.textContent;
          final labelUrl = label.startsWith('www.') ? 'http://$label' : label;
          final destination = Uri.tryParse(href);
          skipChildReferences =
              destination == Uri.tryParse(labelUrl) ||
              // Explicit link labels escape ampersands even when href does not.
              destination == Uri.tryParse(labelUrl.replaceAll('&amp;', '&'));
        }
      }
      for (final child in node.children ?? const <md.Node>[]) {
        walk(child, insideCode: blocked, skipReferences: skipChildReferences);
      }
    } else if (node is md.Text && !insideCode) {
      // Markdown text is already HTML-escaped, while raw HTML is kept intact.
      // One fragment parse decodes once and preserves DOM text boundaries.
      walkHtml(html.parseFragment(node.text), skipReferences: skipReferences);
    }
  }

  for (final node in nodes) {
    walk(node);
  }
  // Nested Markdown can leave adjacent Text nodes separate, and raw tags can
  // span Markdown elements. Reconcile mentions with the rendered DOM so their
  // text boundaries match the whole note, preserving the link reference count.
  analysis.mentions.clear();
  walkHtml(html.parseFragment(md.renderToHtml(nodes)), skipReferences: true);
  return analysis;
}

bool _isReferenceUrl(String text) {
  final uri = Uri.tryParse(text);
  return uri != null && _referencePathPattern.hasMatch(uri.path);
}

final class _Analysis {
  final code = <String, int>{};
  final mentions = <String>[];
  int references = 0;
}
