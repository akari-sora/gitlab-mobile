import 'package:markdown/markdown.dart' as md;

const markdownMediaElement = 'mergeline-media';
const markdownHtmlBlockElement = 'mergeline-html-block';

const _mediaExtensions = <String>{
  '.mp4',
  '.webm',
  '.mov',
  '.m4v',
  '.mp3',
  '.m4a',
  '.ogg',
  '.wav',
};

const _lineBreakTags = <String>{
  'p',
  'div',
  'center',
  'br',
  'tr',
  'li',
  'summary',
};

bool _isMediaDestination(String destination) {
  var value = destination.trim().toLowerCase();
  final fragment = value.indexOf('#');
  if (fragment >= 0) value = value.substring(0, fragment);
  final query = value.indexOf('?');
  if (query >= 0) value = value.substring(0, query);
  return _mediaExtensions.any(value.endsWith);
}

/// Parses ordinary Markdown links first and turns known audio/video
/// destinations into media elements. Reference destinations come from the
/// parser's document-wide link-reference table.
final class MarkdownMediaLinkSyntax extends md.LinkSyntax {
  @override
  md.Node createNode(
    String destination,
    String? title, {
    required List<md.Node> Function() getChildren,
  }) {
    // Let LinkSyntax normalize both inline and reference URLs exactly once.
    final link =
        super.createNode(destination, title, getChildren: getChildren)
            as md.Element;
    final children = link.children!;
    final href = link.attributes['href']!;
    _bindMediaLinks(children, href);
    if (!_isMediaDestination(href) || _containsImage(children)) return link;
    final element = md.Element(markdownMediaElement, children);
    element.attributes
      ..['src'] = href
      ..['kind'] = 'media';
    if (link.attributes.containsKey('title')) {
      element.attributes['title'] = link.attributes['title']!;
    }
    return element;
  }
}

void _bindMediaLinks(List<md.Node> nodes, String href) {
  for (final node in nodes.whereType<md.Element>()) {
    if (node.tag == markdownMediaElement) {
      node.attributes.putIfAbsent('href', () => href);
    }
    if (node.children != null) _bindMediaLinks(node.children!, href);
  }
}

bool _containsImage(List<md.Node> nodes) => nodes.any(
  (node) =>
      node is md.Element &&
      (node.tag == 'img' ||
          node.tag == markdownMediaElement ||
          (node.children != null && _containsImage(node.children!))),
);

/// Parses supported inline HTML media before package:markdown's raw HTML
/// syntax. Code spans and every code block have already been claimed by the
/// Markdown parser before this syntax is considered.
final class MarkdownMediaInlineSyntax extends md.InlineSyntax {
  MarkdownMediaInlineSyntax() : super(r'<', startCharacter: 0x3C);

  final _scanners = Expando<_HtmlMediaScanner>();

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    if (start >= parser.source.length ||
        parser.source.codeUnitAt(start) != 0x3C) {
      return false;
    }
    final scanner = _scanners[parser] ??= _HtmlMediaScanner(parser.source);
    final parsed = _inlineMedia(scanner, start);
    if (parsed == null) return false;
    parser
      ..writeText()
      ..addNode(parsed.element)
      ..consume(parsed.end - start);
    return true;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) => false;
}

/// Preserves raw repository-root traversal evidence until the media resolver
/// can reject it; Uri parsing would otherwise normalize the `..` away first.
final class MarkdownMediaImageSyntax extends md.ImageSyntax {
  @override
  md.Element createNode(
    String destination,
    String? title, {
    required List<md.Node> Function() getChildren,
  }) {
    if (!_unsafeImageDestination(destination)) {
      return super.createNode(destination, title, getChildren: getChildren);
    }
    final element = md.Element.empty('img');
    element.attributes
      ..['src'] = 'mergeline-blocked:'
      ..['alt'] = getChildren().map((node) => node.textContent).join();
    return element;
  }
}

bool _unsafeImageDestination(String destination) {
  final lower = destination.trim().toLowerCase();
  return lower.startsWith('/../') ||
      lower.startsWith('/%2e%2e/') ||
      lower.startsWith('///');
}

/// Keeps the pre-existing media-card behavior for absolute media autolinks.
final class MarkdownMediaAutolinkSyntax extends md.InlineSyntax {
  MarkdownMediaAutolinkSyntax() : super(r'<', startCharacter: 0x3C);

  static final _scheme = RegExp(r'https?://', caseSensitive: false);

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    if (start >= parser.source.length ||
        parser.source.codeUnitAt(start) != 0x3C) {
      return false;
    }
    if (_scheme.matchAsPrefix(parser.source, start + 1) == null) return false;
    final end = parser.source.indexOf('>', start + 1);
    if (end < 0) return false;
    final destination = parser.source.substring(start + 1, end);
    final uri = Uri.tryParse(destination);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        !_isMediaDestination(destination)) {
      return false;
    }
    final element = md.Element.empty(markdownMediaElement);
    element.attributes
      ..['src'] = destination
      ..['kind'] = 'media';
    parser
      ..writeText()
      ..addNode(element)
      ..consume(end + 1 - start);
    return true;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) => false;
}

/// Claims a less-than sign that cannot start HTML or an autolink before the
/// package's general HTML expression scans the rest of a long malformed line.
final class MarkdownLiteralLessThanSyntax extends md.InlineSyntax {
  MarkdownLiteralLessThanSyntax() : super(r'<', startCharacter: 0x3C);

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    if (start >= parser.source.length ||
        parser.source.codeUnitAt(start) != 0x3C ||
        (start + 1 < parser.source.length &&
            !_isWhitespace(parser.source.codeUnitAt(start + 1)))) {
      return false;
    }
    parser
      ..writeText()
      ..addNode(md.Text(parser.source.substring(start, start + 1)))
      ..consume(1);
    return true;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) => false;
}

/// Claims exactly the same blocks as CommonMark's HTML block syntax, but only
/// when the complete block contains media. Blocks without media therefore keep
/// package:markdown's default behavior.
final class MarkdownMediaBlockSyntax extends md.BlockSyntax {
  static final _html = const md.HtmlBlockSyntax();
  final _blocks = Expando<Map<md.Line, List<md.Node>?>>();

  @override
  RegExp get pattern => _html.pattern;

  @override
  bool canEndBlock(md.BlockParser parser) => _html.canEndBlock(parser);

  @override
  bool canParse(md.BlockParser parser) {
    if (!super.canParse(parser)) return false;
    // Type-7 HTML cannot interrupt a paragraph. Avoid scanning its entire
    // remaining suffix on each paragraph continuation line.
    if (parser.currentSyntax is md.ParagraphSyntax && !canEndBlock(parser)) {
      return false;
    }
    final blocks = _blocks[parser] ??= <md.Line, List<md.Node>?>{};
    if (blocks.containsKey(parser.current)) {
      return blocks[parser.current] != null;
    }
    final prospective = _prospectiveHtml(parser);
    final children = _htmlBlockChildren(prospective.source);
    if (!_containsMedia(children)) {
      // A suffix of a block without media also has no media. Keep the negative
      // result for every line, including repeated paragraph-end probes.
      for (final line in prospective.lines) {
        blocks[line] = null;
      }
      return false;
    }
    blocks[parser.current] = children;
    return true;
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final children = _blocks[parser]![parser.current]!;
    _html.parseChildLines(parser);
    return md.Element(markdownHtmlBlockElement, children);
  }
}

bool _containsMedia(List<md.Node> nodes) => nodes.any(
  (node) =>
      node is md.Element &&
      (node.tag == markdownMediaElement ||
          (node.children != null && _containsMedia(node.children!))),
);

({String source, List<md.Line> lines}) _prospectiveHtml(md.BlockParser parser) {
  final out = StringBuffer();
  final lines = <md.Line>[];
  var offset = 0;
  while (true) {
    final first = parser.peek(offset);
    if (first == null) break;
    final match = md.HtmlBlockSyntax().pattern.firstMatch(first.content);
    if (match == null) break;
    var condition = 0;
    for (; condition < match.groupCount; condition++) {
      if (match.group(condition + 1) != null) break;
    }
    final end = switch (condition) {
      0 => RegExp(r'</(?:pre|script|style|textarea)>', caseSensitive: false),
      1 => RegExp(r'-->'),
      2 => RegExp(r'\?>'),
      3 => RegExp(r'>'),
      4 => RegExp(r']]>'),
      _ => RegExp(r'^[ \t]*$'),
    };
    final blankEnded = condition >= 5;
    while (true) {
      final line = parser.peek(offset);
      if (line == null) {
        return (source: out.toString().trimRight(), lines: lines);
      }
      if (out.isNotEmpty) out.write('\n');
      out.write(line.content);
      lines.add(line);
      offset++;
      if (blankEnded) {
        final next = parser.peek(offset);
        if (next == null || end.hasMatch(next.content)) break;
      } else if (end.hasMatch(line.content)) {
        break;
      }
    }
  }
  return (source: out.toString().trimRight(), lines: lines);
}

List<md.Node> _htmlBlockChildren(String source) {
  final scanner = _HtmlMediaScanner(source);
  final blocks = <md.Node>[];
  final inlines = <md.Node>[];
  var blockTag = 'p';
  String? link;
  var index = 0;

  void flush() {
    if (inlines.isEmpty) return;
    while (inlines.isNotEmpty &&
        inlines.last is md.Text &&
        inlines.last.textContent.trim().isEmpty) {
      inlines.removeLast();
    }
    if (inlines.isEmpty) return;
    blocks.add(md.Element(blockTag, List<md.Node>.of(inlines)));
    inlines.clear();
  }

  void addText(String text) {
    final decoded = _decodeEntities(text);
    if (decoded.isEmpty || (link != null && decoded.trim().isEmpty)) return;
    final node = md.Text(decoded);
    if (link == null) {
      inlines.add(node);
    } else {
      inlines.add(
        md.Element('a', [node])..attributes['href'] = _decodeEntities(link),
      );
    }
  }

  while (index < source.length) {
    final next = source.indexOf('<', index);
    if (next < 0) {
      addText(source.substring(index));
      break;
    }
    addText(source.substring(index, next));
    if (source.startsWith('<!--', next)) {
      final end = scanner.commentEnd(next);
      index = end ?? source.length;
      continue;
    }
    final tag = _scanTag(source, next);
    if (tag == null) {
      addText('<');
      index = next + 1;
      continue;
    }
    index = tag.end;
    if (!tag.closing && _textOnlyTags.contains(tag.name)) {
      final close = scanner.closingTag(tag.name, index);
      if (tag.name != 'script' &&
          tag.name != 'style' &&
          tag.name != 'noscript') {
        addText(source.substring(index, close?.start ?? source.length));
      }
      index = close?.end ?? source.length;
      continue;
    }
    if (tag.name == 'a') {
      if (!tag.selfClosing) {
        link = tag.closing ? null : tag.attributes['href'];
      }
      continue;
    }
    if (!tag.closing && tag.name == 'img') {
      final media = _mediaElement(tag.attributes, kind: 'image', link: link);
      if (media != null) inlines.add(media);
      continue;
    }
    if (!tag.closing && (tag.name == 'video' || tag.name == 'audio')) {
      final src =
          tag.attributes['src'] ?? scanner.sourceInside(index, tag.name);
      final media = _mediaElement(
        {...tag.attributes, 'src': ?src},
        kind: tag.name,
        link: link,
      );
      if (media != null) inlines.add(media);
      continue;
    }
    final heading = RegExp(r'^h([1-6])$').firstMatch(tag.name);
    if (heading != null) {
      flush();
      blockTag = tag.closing ? 'p' : tag.name;
      continue;
    }
    if (_lineBreakTags.contains(tag.name)) flush();
  }
  flush();
  return blocks;
}

const _textOnlyTags = {'textarea', 'script', 'style', 'title', 'noscript'};

({md.Node element, int end})? _inlineMedia(
  _HtmlMediaScanner scanner,
  int start,
) {
  final source = scanner.source;
  if (source.startsWith('<!--', start)) {
    final end = scanner.commentEnd(start);
    if (end == null) return null;
    return (element: md.Text(source.substring(start, end)), end: end);
  }
  final first = _scanTag(source, start);
  if (first == null || first.closing) return null;
  if (_textOnlyTags.contains(first.name)) {
    final end = scanner.closingTag(first.name, first.end)?.end;
    if (end == null) return null;
    return (element: md.Text(source.substring(start, end)), end: end);
  }
  if (first.name == 'img') {
    final element = _mediaElement(first.attributes, kind: 'image');
    return element == null ? null : (element: element, end: first.end);
  }
  if (first.name == 'video' || first.name == 'audio') {
    final close = scanner.closingTag(first.name, first.end)?.end;
    final src =
        first.attributes['src'] ?? scanner.sourceInside(first.end, first.name);
    final element = _mediaElement({
      ...first.attributes,
      'src': ?src,
    }, kind: first.name);
    if (element == null) return null;
    return (element: element, end: close ?? first.end);
  }
  if (first.selfClosing || (first.name != 'a' && first.name != 'picture')) {
    return null;
  }
  final href = first.name == 'a' ? first.attributes['href'] : null;
  final children = <md.Node>[];
  var cursor = first.end;
  while (cursor < source.length) {
    if (_isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
      continue;
    }
    // No suffix search or Markdown parse: reject at the first non-tag
    // character or disallowed tag, including nested wrappers.
    final tag = _scanTag(source, cursor);
    if (tag == null) break;
    if (tag.closing) {
      if (tag.name == first.name && _containsMedia(children)) {
        return (element: md.Element('span', children), end: tag.end);
      }
      break;
    }
    if (tag.name == 'img') {
      final image = _mediaElement(tag.attributes, kind: 'image', link: href);
      if (image == null) {
        if (first.name == 'a') break;
      } else {
        children.add(image);
      }
    } else if (first.name == 'a' && tag.name == 'br') {
      children.add(md.Element.empty('br'));
    } else if (first.name != 'picture' || tag.name != 'source') {
      break;
    }
    cursor = tag.end;
  }
  return null;
}

md.Element? _mediaElement(
  Map<String, String> attributes, {
  required String kind,
  String? link,
}) {
  final src = attributes['src'];
  if (src == null || src.trim().isEmpty) return null;
  final element = md.Element.empty(markdownMediaElement);
  element.attributes
    ..['src'] = _decodeEntities(src)
    ..['kind'] = kind;
  for (final name in ['alt', 'width', 'height']) {
    final value = attributes[name];
    if (value != null) element.attributes[name] = _decodeEntities(value);
  }
  if (link != null && link.isNotEmpty) {
    element.attributes['href'] = _decodeEntities(link);
  }
  return element;
}

/// Searches forward in one source without allocating suffixes or repeatedly
/// scanning a tail already known to contain no matching closing/source tag.
final class _HtmlMediaScanner {
  _HtmlMediaScanner(this.source);

  final String source;
  final _closing = <String, ({int from, RegExpMatch? match})>{};
  ({int from, int? end})? _comment;
  final _sources = <String, ({int from, int end, int? at, String? src})>{};
  static final _closingPatterns = <String, RegExp>{};

  int? commentEnd(int start) {
    if (source.startsWith('<!-->', start)) return start + 5;
    if (source.startsWith('<!--->', start)) return start + 6;
    final previous = _comment;
    if (previous != null &&
        start >= previous.from &&
        (previous.end == null || start + 4 <= previous.end! - 3)) {
      return previous.end;
    }
    final at = source.indexOf('-->', start + 4);
    final end = at < 0 ? null : at + 3;
    _comment = (from: start, end: end);
    return end;
  }

  RegExpMatch? closingTag(String name, int start) {
    final previous = _closing[name];
    if (previous != null &&
        start >= previous.from &&
        (previous.match == null || start <= previous.match!.start)) {
      return previous.match;
    }
    final pattern = _closingPatterns.putIfAbsent(
      name,
      () => RegExp('</$name\\s*>', caseSensitive: false),
    );
    final matches = pattern.allMatches(source, start).iterator;
    final match = matches.moveNext() ? matches.current : null;
    _closing[name] = (from: start, match: match);
    return match;
  }

  String? sourceInside(int start, String parent) {
    final previous = _sources[parent];
    if (previous != null &&
        start >= previous.from &&
        start <= (previous.at ?? previous.end)) {
      return previous.src;
    }
    final end = closingTag(parent, start)?.start ?? source.length;
    var cursor = start;
    while (cursor < end) {
      final next = source.indexOf('<', cursor);
      if (next < 0 || next >= end) break;
      if (source.startsWith('<!--', next)) {
        final commentEnd = this.commentEnd(next);
        if (commentEnd == null || commentEnd > end) break;
        cursor = commentEnd;
        continue;
      }
      final tag = _scanTag(source, next);
      if (tag == null) {
        cursor = next + 1;
        continue;
      }
      if (!tag.closing && _textOnlyTags.contains(tag.name)) {
        final inertEnd = closingTag(tag.name, tag.end)?.end;
        if (inertEnd == null || inertEnd > end) break;
        cursor = inertEnd;
        continue;
      }
      if (!tag.closing && tag.name == 'source') {
        final src = tag.attributes['src'];
        _sources[parent] = (from: start, end: end, at: next, src: src);
        return src;
      }
      cursor = tag.end;
    }
    _sources[parent] = (from: start, end: end, at: null, src: null);
    return null;
  }
}

final class _HtmlTag {
  const _HtmlTag(
    this.name,
    this.attributes,
    this.closing,
    this.selfClosing,
    this.end,
  );

  final String name;
  final Map<String, String> attributes;
  final bool closing;
  final bool selfClosing;
  final int end;
}

final _inlineHtmlPattern = md.InlineHtmlSyntax().pattern;

_HtmlTag? _scanTag(String source, int start) {
  if (start >= source.length || source.codeUnitAt(start) != 0x3C) return null;
  var cursor = start + 1;
  var closing = false;
  if (cursor < source.length && source.codeUnitAt(cursor) == 0x2F) {
    closing = true;
    cursor++;
  }
  final nameStart = cursor;
  if (cursor >= source.length || !_isAsciiLetter(source.codeUnitAt(cursor))) {
    return null;
  }
  cursor++;
  while (cursor < source.length && _isName(source.codeUnitAt(cursor))) {
    cursor++;
  }
  final name = source.substring(nameStart, cursor).toLowerCase();
  final attributes = <String, String>{};
  while (cursor < source.length) {
    final beforeWhitespace = cursor;
    while (cursor < source.length && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor >= source.length) return null;
    final unit = source.codeUnitAt(cursor);
    final selfClosing = !closing && unit == 0x2F;
    if (unit == 0x3E ||
        (selfClosing &&
            cursor + 1 < source.length &&
            source.codeUnitAt(cursor + 1) == 0x3E)) {
      final end = cursor + (selfClosing ? 2 : 1);
      // Reuse the package's grammar only on this bounded, lexically valid
      // candidate. Never let its backtracking expression search a malformed
      // suffix at every less-than sign.
      final candidate = source.substring(start, end);
      if (_inlineHtmlPattern.matchAsPrefix(candidate)?.end !=
          candidate.length) {
        return null;
      }
      return _HtmlTag(name, attributes, closing, selfClosing, end);
    }
    if (closing || cursor == beforeWhitespace || !_isAttributeStart(unit)) {
      return null;
    }
    final attributeStart = cursor++;
    while (cursor < source.length &&
        _isAttributeName(source.codeUnitAt(cursor))) {
      cursor++;
    }
    final attribute = source.substring(attributeStart, cursor).toLowerCase();
    final attributeEnd = cursor;
    while (cursor < source.length && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    var value = '';
    if (cursor < source.length && source.codeUnitAt(cursor) == 0x3D) {
      cursor++;
      while (cursor < source.length &&
          _isWhitespace(source.codeUnitAt(cursor))) {
        cursor++;
      }
      if (cursor >= source.length) return null;
      final quote = source.codeUnitAt(cursor);
      if (quote == 0x22 || quote == 0x27) {
        cursor++;
        final valueStart = cursor;
        while (cursor < source.length && source.codeUnitAt(cursor) != quote) {
          cursor++;
        }
        if (cursor >= source.length) return null;
        value = source.substring(valueStart, cursor);
        cursor++;
      } else {
        final valueStart = cursor;
        while (cursor < source.length &&
            !_isWhitespace(source.codeUnitAt(cursor)) &&
            source.codeUnitAt(cursor) != 0x3E) {
          final unit = source.codeUnitAt(cursor);
          if (unit == 0x22 ||
              unit == 0x27 ||
              unit == 0x3D ||
              unit == 0x3C ||
              unit == 0x60) {
            return null;
          }
          cursor++;
        }
        if (cursor == valueStart) return null;
        value = source.substring(valueStart, cursor);
      }
    } else {
      // Leave the separator for the next attribute (or tag end) to consume.
      cursor = attributeEnd;
    }
    attributes.putIfAbsent(attribute, () => value);
  }
  return null;
}

bool _isAsciiLetter(int unit) =>
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);

bool _isName(int unit) =>
    _isAsciiLetter(unit) || (unit >= 0x30 && unit <= 0x39) || unit == 0x2D;

bool _isAttributeStart(int unit) =>
    _isAsciiLetter(unit) || unit == 0x5F || unit == 0x3A;

bool _isAttributeName(int unit) =>
    _isName(unit) || unit == 0x5F || unit == 0x3A || unit == 0x2E;

// ECMAScript \s, as used by package:markdown's named-tag pattern. The ASCII
// range includes both form feed and line tabulation.
bool _isWhitespace(int unit) =>
    unit == 0x20 ||
    (unit >= 0x09 && unit <= 0x0D) ||
    unit == 0xA0 ||
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200A) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x202F ||
    unit == 0x205F ||
    unit == 0x3000 ||
    unit == 0xFEFF;

final _entityDocument = md.Document(
  inlineSyntaxes: [md.DecodeHtmlSyntax()],
  withDefaultInlineSyntaxes: false,
  encodeHtml: false,
);
final _entityPattern = RegExp(
  r'&(?:[a-zA-Z][a-zA-Z0-9]*|#\d+|#[xX][0-9a-fA-F]+);',
);

String _decodeEntities(String value) =>
    value.replaceAllMapped(_entityPattern, (match) {
      final entity = match[0]!;
      if (entity.startsWith('&#')) {
        final hex = entity[2] == 'x' || entity[2] == 'X';
        return _entityCodePoint(
          int.tryParse(
            entity.substring(hex ? 3 : 2, entity.length - 1),
            radix: hex ? 16 : 10,
          ),
        );
      }
      return _entityDocument
          .parseInline(entity)
          .map((node) => node.textContent)
          .join();
    });

String _entityCodePoint(int? value) => String.fromCharCode(
  value != null &&
          value > 0 &&
          value <= 0x10FFFF &&
          (value < 0xD800 || value > 0xDFFF)
      ? value
      : 0xFFFD,
);
