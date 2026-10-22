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

/// Adds code spans only when reparsing proves that the mentions were removed
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
  var analysis = _analyze(_joinedDraft(existing, result));

  if (!keepNotifications) {
    // Stop collecting at 51: large drafts need only the final analysis below.
    final candidates = _mentionPattern.allMatches(text).take(51).toList();
    if (candidates.length <= 50 && candidates.isNotEmpty) {
      // Most answers can be verified in one reparse. A failed batch may mix
      // safe mentions with code or raw HTML, so retry those individually.
      final batchText = _wrapCandidates(result, candidates.reversed);
      final batch = _analyze(_joinedDraft(existing, batchText));
      if (_verifiesBatch(analysis, batch, candidates)) {
        result = batchText;
        analysis = batch;
        neutralized = candidates.length;
      } else {
        for (final candidate in candidates.reversed) {
          final proposedText = _wrapCandidates(result, [candidate]);
          final proposed = _analyze(_joinedDraft(existing, proposedText));
          // Raw HTML may join a candidate to adjacent text in the local
          // parser. Preserve the single-token fallback's count check while
          // still proving that exactly this token became Markdown code.
          final token = candidate[0]!.replaceFirst(_trailingPunctuation, '');
          if (proposed.mentions.length == analysis.mentions.length - 1 &&
              _addsOnly(analysis.code, proposed.code, [token])) {
            result = proposedText;
            analysis = proposed;
            neutralized++;
          }
        }
      }
    }
  }

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

String _wrapCandidates(String text, Iterable<Match> candidates) {
  for (final candidate in candidates) {
    final token = candidate[0]!.replaceFirst(_trailingPunctuation, '');
    text = text.replaceRange(
      candidate.start,
      candidate.start + token.length,
      '`$token`',
    );
  }
  return text;
}

Map<String, int> _counts(Iterable<String> values) {
  final counts = <String, int>{};
  for (final value in values) {
    counts[value] = (counts[value] ?? 0) + 1;
  }
  return counts;
}

bool _verifiesBatch(
  _Analysis previous,
  _Analysis proposed,
  Iterable<Match> candidates,
) =>
    _addsOnly(
      previous.code,
      proposed.code,
      candidates.map(
        (candidate) => candidate[0]!.replaceFirst(_trailingPunctuation, ''),
      ),
    ) &&
    _addsOnly(
      _counts(proposed.mentions),
      _counts(previous.mentions),
      candidates.map((candidate) => candidate[1]!),
    );

bool _addsOnly(
  Map<String, int> previous,
  Map<String, int> proposed,
  Iterable<String> additions,
) {
  final expected = Map<String, int>.of(previous);
  for (final value in additions) {
    expected[value] = (expected[value] ?? 0) + 1;
  }
  return proposed.length == expected.length &&
      expected.entries.every((entry) => proposed[entry.key] == entry.value);
}

_Analysis _analyze(String text) {
  // GitHub-flavoured Markdown is this package's closest available match to
  // GitLab Flavored Markdown, including fenced code, tables and autolinks.
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
  ).parse(text);
  final analysis = _Analysis();
  final fragmentMentions = <String>[];

  void walkHtml(
    dom.Node node, {
    required List<String> mentions,
    required bool skipReferences,
    bool skipCode = true,
  }) {
    final rawCode =
        node is dom.Element &&
        (node.localName == 'code' || node.localName == 'pre');
    if (skipCode && rawCode) return;
    var skipChildReferences = skipReferences || rawCode;
    if (!skipChildReferences && node is dom.Element && node.localName == 'a') {
      final href = node.attributes['href'];
      if (href != null && _isReferenceUrl(href)) {
        analysis.references++;
        // The anchor is one reference even when its label names another item.
        skipChildReferences = true;
      }
    }
    if (node is dom.Text) {
      mentions.addAll(
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
      walkHtml(
        child,
        mentions: mentions,
        skipReferences: skipChildReferences,
        skipCode: skipCode,
      );
    }
  }

  void walk(md.Node node, {bool insideCode = false}) {
    if (node is md.Element) {
      if (node.tag == 'code') {
        final value = node.textContent;
        analysis.code[value] = (analysis.code[value] ?? 0) + 1;
      }
      final blocked = insideCode || node.tag == 'code' || node.tag == 'pre';
      for (final child in node.children ?? const <md.Node>[]) {
        walk(child, insideCode: blocked);
      }
    } else if (node is md.Text && !insideCode) {
      // Markdown text is already HTML-escaped, while raw HTML is kept intact.
      // One fragment parse decodes once and preserves DOM text boundaries.
      // Plain text needs neither HTML tree construction nor entity decoding.
      final fragment = node.text.contains('&') || node.text.contains('<')
          ? html.parseFragment(node.text)
          : dom.Text(node.text);
      walkHtml(
        fragment,
        mentions: fragmentMentions,
        skipReferences: true,
        skipCode: false,
      );
    }
  }

  for (final node in nodes) {
    walk(node);
  }
  // GitLab 18.11+ uses HTML5, where raw code tags can span Markdown elements.
  // Older libxml2 parsers may close those tags earlier. Keep the larger count
  // per name from the whole HTML5 DOM and the conservative Text-fragment view;
  // only Markdown-generated code is excluded from that second view.
  final wholeMentions = <String>[];
  walkHtml(
    html.parseFragment(md.renderToHtml(nodes)),
    mentions: wholeMentions,
    // Count both raw and Markdown anchors here once, including labels split
    // across Markdown nodes. Attributes never enter the mention scan.
    skipReferences: false,
  );
  // Start in source-fragment order so an early raw-code mention is not moved
  // behind a later prose mention that only the whole-DOM scan already found.
  analysis.mentions.addAll(fragmentMentions);
  final remainingFragments = _counts(fragmentMentions);
  for (final name in wholeMentions) {
    final remaining = remainingFragments[name] ?? 0;
    if (remaining > 0) {
      remainingFragments[name] = remaining - 1;
    } else {
      analysis.mentions.add(name);
    }
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
