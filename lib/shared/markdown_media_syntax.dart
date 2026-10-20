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
    final children = getChildren();
    if (!_isMediaDestination(destination) || _containsImage(children)) {
      return super.createNode(destination, title, getChildren: () => children);
    }
    final element = md.Element(markdownMediaElement, children);
    element.attributes
      ..['src'] = destination
      ..['kind'] = 'media';
    if (title != null && title.isNotEmpty) {
      element.attributes['title'] = title;
    }
    return element;
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

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    if (start >= parser.source.length ||
        parser.source.codeUnitAt(start) != 0x3C) {
      return false;
    }
    final parsed = _inlineMedia(parser.source, start);
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

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    if (start >= parser.source.length ||
        parser.source.codeUnitAt(start) != 0x3C) {
      return false;
    }
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
    var end = start + 1;
    while (true) {
      final next = parser.source.indexOf('<', end);
      if (next < 0) {
        end = parser.source.length;
        break;
      }
      if (next + 1 >= parser.source.length ||
          !_isWhitespace(parser.source.codeUnitAt(next + 1))) {
        end = next;
        break;
      }
      end = next + 1;
    }
    parser
      ..writeText()
      ..addNode(md.Text(parser.source.substring(start, end)))
      ..consume(end - start);
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

  @override
  RegExp get pattern => _html.pattern;

  @override
  bool canEndBlock(md.BlockParser parser) => _html.canEndBlock(parser);

  @override
  bool canParse(md.BlockParser parser) {
    if (!super.canParse(parser)) return false;
    return _containsMedia(_htmlBlockChildren(_prospectiveHtml(parser)));
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final source = _html
        .parseChildLines(parser)
        .map((line) => line.content)
        .join('\n')
        .trimRight();
    return md.Element(markdownHtmlBlockElement, _htmlBlockChildren(source));
  }
}

bool _containsMedia(List<md.Node> nodes) => nodes.any(
  (node) =>
      node is md.Element &&
      (node.tag == markdownMediaElement ||
          (node.children != null && _containsMedia(node.children!))),
);

String _prospectiveHtml(md.BlockParser parser) {
  final out = StringBuffer();
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
      if (line == null) return out.toString();
      if (out.isNotEmpty) out.write('\n');
      out.write(line.content);
      offset++;
      if (blankEnded) {
        final next = parser.peek(offset);
        if (next == null || end.hasMatch(next.content)) break;
      } else if (end.hasMatch(line.content)) {
        break;
      }
    }
  }
  return out.toString();
}

List<md.Node> _htmlBlockChildren(String source) {
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
    if (decoded.isNotEmpty) inlines.add(md.Text(decoded));
  }

  while (index < source.length) {
    final next = source.indexOf('<', index);
    if (next < 0) {
      addText(source.substring(index));
      break;
    }
    addText(source.substring(index, next));
    if (source.startsWith('<!--', next)) {
      final end = source.indexOf('-->', next + 4);
      index = end < 0 ? source.length : end + 3;
      continue;
    }
    final tag = _scanTag(source, next);
    if (tag == null) {
      addText('<');
      index = next + 1;
      continue;
    }
    index = tag.end;
    if (!tag.closing && (tag.name == 'script' || tag.name == 'style')) {
      final close = _closingTagEnd(source, tag.name, index);
      index = close ?? source.length;
      continue;
    }
    if (tag.name == 'a') {
      link = tag.closing ? null : tag.attributes['href'];
      continue;
    }
    if (!tag.closing && tag.name == 'img') {
      final media = _mediaElement(tag.attributes, kind: 'image', link: link);
      if (media != null) inlines.add(media);
      continue;
    }
    if (!tag.closing && (tag.name == 'video' || tag.name == 'audio')) {
      final src =
          tag.attributes['src'] ?? _sourceInside(source, index, tag.name);
      if (src != null) {
        inlines.add(
          _mediaElement(
            {...tag.attributes, 'src': src},
            kind: tag.name,
            link: link,
          )!,
        );
      }
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

({md.Element element, int end})? _inlineMedia(String source, int start) {
  final first = _scanTag(source, start);
  if (first == null || first.closing) return null;
  if (first.name == 'img') {
    final element = _mediaElement(first.attributes, kind: 'image');
    return element == null ? null : (element: element, end: first.end);
  }
  if (first.name == 'video' || first.name == 'audio') {
    final close = _closingTagEnd(source, first.name, first.end);
    final src =
        first.attributes['src'] ?? _sourceInside(source, first.end, first.name);
    if (src == null) return null;
    return (
      element: _mediaElement({
        ...first.attributes,
        'src': src,
      }, kind: first.name)!,
      end: close ?? first.end,
    );
  }
  if (first.name != 'a' && first.name != 'picture') return null;
  final close = _closingTagEnd(source, first.name, first.end);
  if (close == null) return null;
  var cursor = first.end;
  while (cursor < close) {
    final candidate = source.indexOf('<', cursor);
    if (candidate < 0 || candidate >= close) break;
    if (source.startsWith('<!--', candidate)) {
      final commentEnd = source.indexOf('-->', candidate + 4);
      if (commentEnd < 0 || commentEnd >= close) return null;
      cursor = commentEnd + 3;
      continue;
    }
    final tag = _scanTag(source, candidate);
    if (tag == null) {
      cursor = candidate + 1;
      continue;
    }
    if (!tag.closing && (tag.name == 'script' || tag.name == 'style')) {
      final inertEnd = _closingTagEnd(source, tag.name, tag.end);
      if (inertEnd == null || inertEnd > close) return null;
      cursor = inertEnd;
      continue;
    }
    if (!tag.closing && tag.name == first.name) return null;
    if (!tag.closing && tag.name == 'img') {
      final element = _mediaElement(
        tag.attributes,
        kind: 'image',
        link: first.name == 'a' ? first.attributes['href'] : null,
      );
      return element == null ? null : (element: element, end: close);
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

String? _sourceInside(String source, int start, String parent) {
  final closeStart = source.toLowerCase().indexOf('</$parent', start);
  final end = closeStart < 0 ? source.length : closeStart;
  var cursor = start;
  while (cursor < end) {
    final next = source.indexOf('<', cursor);
    if (next < 0 || next >= end) return null;
    if (source.startsWith('<!--', next)) {
      final commentEnd = source.indexOf('-->', next + 4);
      if (commentEnd < 0 || commentEnd >= end) return null;
      cursor = commentEnd + 3;
      continue;
    }
    final tag = _scanTag(source, next);
    if (tag == null) {
      cursor = next + 1;
      continue;
    }
    if (!tag.closing && (tag.name == 'script' || tag.name == 'style')) {
      final inertEnd = _closingTagEnd(source, tag.name, tag.end);
      if (inertEnd == null || inertEnd > end) return null;
      cursor = inertEnd;
      continue;
    }
    if (!tag.closing && tag.name == 'source') return tag.attributes['src'];
    cursor = tag.end;
  }
  return null;
}

int? _closingTagEnd(String source, String name, int start) {
  final match = RegExp(
    '</$name\\s*>',
    caseSensitive: false,
  ).firstMatch(source.substring(start));
  return match == null ? null : start + match.end;
}

final class _HtmlTag {
  const _HtmlTag(this.name, this.attributes, this.closing, this.end);

  final String name;
  final Map<String, String> attributes;
  final bool closing;
  final int end;
}

_HtmlTag? _scanTag(String source, int start) {
  if (start >= source.length || source.codeUnitAt(start) != 0x3C) return null;
  var cursor = start + 1;
  var closing = false;
  if (cursor < source.length && source.codeUnitAt(cursor) == 0x2F) {
    closing = true;
    cursor++;
  }
  final nameStart = cursor;
  while (cursor < source.length && _isName(source.codeUnitAt(cursor))) {
    cursor++;
  }
  if (cursor == nameStart) return null;
  final name = source.substring(nameStart, cursor).toLowerCase();
  final attributes = <String, String>{};
  while (cursor < source.length) {
    while (cursor < source.length && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor >= source.length) return null;
    if (source.codeUnitAt(cursor) == 0x3E) {
      return _HtmlTag(name, attributes, closing, cursor + 1);
    }
    if (source.codeUnitAt(cursor) == 0x2F &&
        cursor + 1 < source.length &&
        source.codeUnitAt(cursor + 1) == 0x3E) {
      return _HtmlTag(name, attributes, closing, cursor + 2);
    }
    final attributeStart = cursor;
    while (cursor < source.length &&
        _isAttributeName(source.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor == attributeStart) return null;
    final attribute = source.substring(attributeStart, cursor).toLowerCase();
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
          cursor++;
        }
        value = source.substring(valueStart, cursor);
      }
    }
    attributes.putIfAbsent(attribute, () => value);
  }
  return null;
}

bool _isName(int unit) =>
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A) ||
    (unit >= 0x30 && unit <= 0x39) ||
    unit == 0x2D;

bool _isAttributeName(int unit) =>
    _isName(unit) || unit == 0x5F || unit == 0x3A || unit == 0x2E;

bool _isWhitespace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

String _decodeEntities(String value) => value.replaceAllMapped(
  RegExp(r'&(?:quot|apos|amp|lt|gt|#\d+|#x[0-9a-fA-F]+);'),
  (match) {
    final entity = match[0]!;
    return switch (entity) {
      '&quot;' => '"',
      '&apos;' => "'",
      '&amp;' => '&',
      '&lt;' => '<',
      '&gt;' => '>',
      _ when entity.startsWith('&#x') => _entityCodePoint(
        int.tryParse(entity.substring(3, entity.length - 1), radix: 16),
      ),
      _ => _entityCodePoint(
        int.tryParse(entity.substring(2, entity.length - 1)),
      ),
    };
  },
);

String _entityCodePoint(int? value) => String.fromCharCode(
  value != null && value > 0 && value <= 0x10FFFF ? value : 0xFFFD,
);
