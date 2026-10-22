import 'package:markdown/markdown.dart' as md;

/// What appending [text] to a GitLab comment would mention or reference.
final class DraftMentions {
  const DraftMentions({
    required this.text,
    required this.mentions,
    required this.neutralized,
    required this.references,
  });

  /// The draft text, with only verified mention code spans added.
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
}) {
  var result = text;
  var neutralized = 0;

  if (!keepNotifications) {
    // Stop collecting at 51: large drafts need only the final analysis below.
    final candidates = _mentionPattern.allMatches(text).take(51).toList();
    if (candidates.length <= 50 && candidates.isNotEmpty) {
      var previous = _analyze(result);
      for (final candidate in candidates.reversed) {
        final token = candidate[0]!.replaceFirst(_trailingPunctuation, '');
        final proposedText = result.replaceRange(
          candidate.start,
          candidate.start + token.length,
          '`$token`',
        );
        final proposed = _analyze(proposedText);
        if (proposed.mentions.length == previous.mentions.length - 1 &&
            _addsOnlyCode(previous.code, proposed.code, token)) {
          result = proposedText;
          previous = proposed;
          neutralized++;
        }
      }
    }
  }

  final analysis = _analyze(result);
  return DraftMentions(
    text: result,
    mentions: List<String>.unmodifiable(analysis.mentions.toSet()),
    neutralized: neutralized,
    references: analysis.references,
  );
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
      analysis.mentions.addAll(
        _mentionPattern.allMatches(node.text).map((match) => match[1]!),
      );
      if (!skipReferences) {
        for (final match in _referencePattern.allMatches(node.text)) {
          final url = match[1];
          if (url == null || _isReferenceUrl(url)) analysis.references++;
        }
      }
    }
  }

  for (final node in nodes) {
    walk(node);
  }
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
