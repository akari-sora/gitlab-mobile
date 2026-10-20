const _mediaTitle = 'mergeline-media';
const _sizeTitlePrefix = 'mergeline-size:';

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

const _blockHtmlTags = <String>{
  'address',
  'article',
  'aside',
  'blockquote',
  'details',
  'dialog',
  'dl',
  'fieldset',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'main',
  'menu',
  'nav',
  'ol',
  'pre',
  'section',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'ul',
};

const _layoutWrapperTags = <String>{'p', 'div', 'center', 'picture'};

/// Converts the small HTML/media subset accepted by GitLab Markdown into
/// Markdown nodes understood by the app's image builder.
///
/// Fenced code blocks and code spans are copied byte-for-byte. The scanners
/// advance monotonically, including for malformed input, so processing stays
/// linear in the source length.
String preprocessMarkdownMedia(String source) {
  if (source.isEmpty) return source;
  final ranges = _codeBlockRanges(source);
  final visible = StringBuffer();
  var visibleStart = 0;
  for (final range in ranges) {
    visible
      ..write(source.substring(visibleStart, range.start))
      ..write(_blankExceptNewlines(source.substring(range.start, range.end)));
    visibleStart = range.end;
  }
  visible.write(source.substring(visibleStart));
  final references = _mediaReferenceDestinations(visible.toString());
  final out = StringBuffer();
  var copied = 0;
  for (final range in ranges) {
    out
      ..write(
        _transformOutsideCode(
          source.substring(copied, range.start),
          references,
        ),
      )
      ..write(source.substring(range.start, range.end));
    copied = range.end;
  }
  out.write(_transformOutsideCode(source.substring(copied), references));
  return out.toString();
}

/// Converts ordinary Markdown links to known audio/video files into the
/// internal image token used for an in-app media card.
String convertMarkdownMediaLinks(String source) {
  if (source.isEmpty) return source;
  return _convertMarkdownMediaLinks(
    source,
    _mediaReferenceDestinations(source),
  );
}

bool _isMarkdownDestinationAngle(String source, int start) {
  var i = start - 1;
  while (i >= 0) {
    final unit = source.codeUnitAt(i);
    if (unit != 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) {
      if (unit != 0x28) return false;
      i--;
      while (i >= 0 &&
          (source.codeUnitAt(i) == 0x20 || source.codeUnitAt(i) == 0x09)) {
        i--;
      }
      return i >= 0 && source.codeUnitAt(i) == 0x5D;
    }
    i--;
  }
  return false;
}

String _convertMarkdownMediaLinks(
  String source,
  Map<String, _LinkDestination> references,
) {
  final pairs = _delimiterPairs(source);
  final out = StringBuffer();
  var copied = 0;
  var i = 0;
  while (i < source.length) {
    if (source.codeUnitAt(i) == 0x3C) {
      final end = pairs.angles[i];
      if (end != null &&
          end > i + 1 &&
          !_isMarkdownDestinationAngle(source, i)) {
        final destination = source.substring(i + 1, end);
        final uri = Uri.tryParse(destination);
        if (uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            _isMediaDestination(destination)) {
          out
            ..write(source.substring(copied, i))
            ..write('![](<')
            ..write(destination)
            ..write('> "')
            ..write(_mediaTitle)
            ..write('")');
          copied = end + 1;
          i = copied;
          continue;
        }
      }
    }
    if (source.codeUnitAt(i) != 0x5B ||
        (i > 0 && source.codeUnitAt(i - 1) == 0x21)) {
      i++;
      continue;
    }
    final labelEnd = pairs.brackets[i];
    if (labelEnd == null || labelEnd + 1 >= source.length) {
      i++;
      continue;
    }
    if (source.codeUnitAt(labelEnd + 1) == 0x5B) {
      final referenceEnd = pairs.brackets[labelEnd + 1];
      if (referenceEnd != null) {
        final label = source.substring(i + 1, labelEnd);
        final rawReference = source.substring(labelEnd + 2, referenceEnd);
        final reference = _normalizeReference(
          rawReference.isEmpty ? label : rawReference,
        );
        final destination = references[reference];
        if (destination != null && _isMediaDestination(destination.value) &&
            !label.contains('![')) {
          out
            ..write(source.substring(copied, i))
            ..write('![')
            ..write(label)
            ..write('](')
            ..write(destination.markdown)
            ..write(' "')
            ..write(_mediaTitle)
            ..write('")');
          copied = referenceEnd + 1;
          i = copied;
          continue;
        }
        i = referenceEnd + 1;
        continue;
      }
    }
    if (source.codeUnitAt(labelEnd + 1) != 0x28) {
      i++;
      continue;
    }
    final linkEnd = pairs.parentheses[labelEnd + 1];
    if (linkEnd == null) {
      i++;
      continue;
    }
    final label = source.substring(i + 1, labelEnd);
    if (label.contains('![')) {
      i = linkEnd + 1;
      continue;
    }
    final destination = _linkDestination(
      source.substring(labelEnd + 2, linkEnd),
    );
    if (destination == null || !_isMediaDestination(destination.value)) {
      i = linkEnd + 1;
      continue;
    }
    out
      ..write(source.substring(copied, i))
      ..write('![')
      ..write(label)
      ..write('](')
      ..write(destination.markdown)
      ..write(' "')
      ..write(_mediaTitle)
      ..write('")');
    copied = linkEnd + 1;
    i = copied;
  }
  if (copied == 0) return source;
  out.write(source.substring(copied));
  return out.toString();
}

Map<String, _LinkDestination> _mediaReferenceDestinations(String source) {
  final references = <String, _LinkDestination>{};
  var lineStart = 0;
  while (lineStart < source.length) {
    final newline = source.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? source.length : newline;
    var i = lineStart;
    var spaces = 0;
    while (i < lineEnd && source.codeUnitAt(i) == 0x20 && spaces < 4) {
      spaces++;
      i++;
    }
    if (spaces <= 3 && i < lineEnd && source.codeUnitAt(i) == 0x5B) {
      var close = i + 1;
      while (close < lineEnd && source.codeUnitAt(close) != 0x5D) {
        close++;
      }
      if (close > i + 1 &&
          close + 1 < lineEnd &&
          source.codeUnitAt(close + 1) == 0x3A) {
        final destination = _linkDestination(
          source.substring(close + 2, lineEnd),
        );
        if (destination != null && (_isMediaDestination(destination.value) ||
            _unsafeRawImageDestination(destination.value))) {
          references.putIfAbsent(
            _normalizeReference(source.substring(i + 1, close)),
            () => destination,
          );
        }
      }
    }
    lineStart = newline < 0 ? source.length : newline + 1;
  }
  return references;
}

String _normalizeReference(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[ \t\r\n]+'), ' ');

String _transformOutsideCode(
  String source,
  Map<String, _LinkDestination> references,
) {
  final runs = <_TickRun>[];
  var slashes = 0;
  for (var i = 0; i < source.length;) {
    final unit = source.codeUnitAt(i);
    if (unit == 0x5C) {
      slashes++;
      i++;
      continue;
    }
    if (unit != 0x60) {
      slashes = 0;
      i++;
      continue;
    }
    final escaped = slashes.isOdd;
    slashes = 0;
    var end = i + 1;
    while (end < source.length && source.codeUnitAt(end) == 0x60) {
      end++;
    }
    if (!escaped) runs.add(_TickRun(i, end - i));
    i = end;
  }
  if (runs.isEmpty) return _transformPlain(source, references);

  final next = List<int?>.filled(runs.length, null);
  final nextByLength = <int, int>{};
  for (var i = runs.length - 1; i >= 0; i--) {
    next[i] = nextByLength[runs[i].length];
    nextByLength[runs[i].length] = i;
  }
  final out = StringBuffer();
  var copied = 0;
  var run = 0;
  while (run < runs.length) {
    final close = next[run];
    if (close == null) {
      run++;
      continue;
    }
    final start = runs[run].start;
    final end = runs[close].start + runs[close].length;
    out
      ..write(_transformPlain(source.substring(copied, start), references))
      ..write(source.substring(start, end));
    copied = end;
    run = close + 1;
  }
  out.write(_transformPlain(source.substring(copied), references));
  return out.toString();
}

String _transformPlain(
  String source,
  Map<String, _LinkDestination> references,
) => _convertMarkdownMediaLinks(
  _blockUnsafeImageDestinations(_convertHtmlMedia(source), references),
  references,
);

// Uri normalizes dot segments before imageBuilder sees them. Keep unsafe raw
// root-relative destinations blocked before handing Markdown to that parser.
String _blockUnsafeImageDestinations(
  String source, Map<String, _LinkDestination> references,
) {
  final pairs = _delimiterPairs(source);
  final out = StringBuffer();
  var copied = 0;
  var i = 0;
  while (i + 1 < source.length) {
    if (source.codeUnitAt(i) != 0x21 || source.codeUnitAt(i + 1) != 0x5b) {
      i++;
      continue;
    }
    final labelEnd = pairs.brackets[i + 1];
    if (labelEnd == null || labelEnd + 1 >= source.length) {
      i++;
      continue;
    }
    if (source.codeUnitAt(labelEnd + 1) == 0x5b) {
      final end = pairs.brackets[labelEnd + 1];
      if (end != null) {
        final label = source.substring(i + 2, labelEnd);
        final rawReference = source.substring(labelEnd + 2, end);
        final destination = references[_normalizeReference(
          rawReference.isEmpty ? label : rawReference,
        )];
        if (destination != null && _unsafeRawImageDestination(destination.value)) {
          out
            ..write(source.substring(copied, i))
            ..write('![$label](<mergeline-blocked:unsafe>)');
          copied = end + 1;
        }
        i = end + 1;
        continue;
      }
    }
    if (source.codeUnitAt(labelEnd + 1) != 0x28) {
      i++;
      continue;
    }
    final end = pairs.parentheses[labelEnd + 1];
    if (end == null) {
      i++;
      continue;
    }
    final destination = _linkDestination(source.substring(labelEnd + 2, end));
    if (destination != null && _unsafeRawImageDestination(destination.value)) {
      out
        ..write(source.substring(copied, labelEnd + 2))
        ..write('<mergeline-blocked:unsafe>');
      copied = end;
    }
    i = end + 1;
  }
  if (copied == 0) return source;
  out.write(source.substring(copied));
  return out.toString();
}

bool _unsafeRawImageDestination(String value) {
  try {
    final decoded = Uri.decodeComponent(value);
    if (decoded.contains(r'\') ||
        decoded.runes.any(
          (rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f),
        )) {
      return true;
    }
    if (decoded.startsWith('///')) return true;
    if (!decoded.startsWith('/') || decoded.startsWith('//')) return false;
    final path = decoded.split(RegExp(r'[?#]')).first;
    return path.split('/').any((segment) => segment == '.' || segment == '..');
  } on FormatException {
    return true;
  } on ArgumentError {
    return true;
  }
}

String _convertHtmlMedia(String source) {
  final root = StringBuffer();
  final anchors = <_AnchorFrame>[];
  final wrappers = <String, int>{};
  final blockTags = <String, int>{};
  var sawBlockHtml = false;
  _MediaFrame? media;
  StringBuffer target() => anchors.isEmpty ? root : anchors.last.content;
  bool inBlockContext() => blockTags.values.any((depth) => depth > 0);
  void writeMediaToken(String token, {bool forceBlock = false}) {
    if (anchors.isNotEmpty) {
      target().write(token);
      return;
    }
    final block = forceBlock || inBlockContext() || sawBlockHtml;
    target().write(block ? '\n\n$token\n\n' : token);
    sawBlockHtml = false;
  }

  var copied = 0;
  var i = 0;
  var noLaterCommentClose = false;
  while (i < source.length) {
    if (source.codeUnitAt(i) != 0x3C) {
      i++;
      continue;
    }
    if (_startsComment(source, i)) {
      if (noLaterCommentClose) {
        i++;
        continue;
      }
      final commentEnd = source.indexOf('-->', i + 4);
      if (commentEnd < 0) {
        noLaterCommentClose = true;
        i++;
      } else {
        i = commentEnd + 3;
      }
      continue;
    }
    if (!_startsHtmlTag(source, i)) {
      i++;
      continue;
    }
    final tagEnd = _tagEnd(source, i);
    if (tagEnd == null) {
      i++;
      continue;
    }
    final tag = _readTag(source, i, tagEnd);
    if (tag == null) {
      i++;
      continue;
    }
    final current = media;
    if (current != null) {
      current.raw.write(source.substring(copied, tag.end));
      if (!tag.closing && tag.name == 'source' && current.src == null) {
        current.src = tag.attributes['src'];
      }
      if (tag.closing && tag.name == current.name) {
        final replacement = current.src == null
            ? current.raw.toString()
            : _mediaMarkdown(current.src!, current.alt, current.name);
        media = null;
        writeMediaToken(replacement, forceBlock: current.forceBlock);
      }
      copied = tag.end;
      i = tag.end;
      continue;
    }

    target().write(source.substring(copied, i));
    final raw = source.substring(i, tag.end);
    switch (tag.name) {
      case 'img':
        if (!tag.closing) {
          final src = tag.attributes['src'];
          if (src == null) {
            target().write(raw);
          } else {
            writeMediaToken(
              _imageMarkdown(tag.attributes, src),
              forceBlock: _lineIndent(source, i) >= 4,
            );
          }
        } else {
          target().write(raw);
        }
      case 'video':
      case 'audio':
        if (tag.closing) {
          target().write(raw);
        } else if (tag.selfClosing) {
          final src = tag.attributes['src'];
          if (src == null) {
            target().write(raw);
          } else {
            writeMediaToken(
              _mediaMarkdown(src, _mediaAlt(tag.attributes), tag.name),
              forceBlock: _lineIndent(source, i) >= 4,
            );
          }
        } else {
          media = _MediaFrame(
            tag.name,
            tag.attributes['src'],
            _mediaAlt(tag.attributes),
            StringBuffer(raw),
            _lineIndent(source, i) >= 4,
          );
        }
      case 'a':
        if (tag.closing) {
          if (anchors.isEmpty) {
            target().write(raw);
          } else if (anchors.last.nestedDepth > 0) {
            anchors.last.nestedDepth--;
            target().write(raw);
          } else {
            final anchor = anchors.removeLast();
            final content = anchor.content.toString();
            final parent = target();
            if (anchor.href != null && content.contains('![')) {
              final linked =
                  '[$content](${_markdownDestination(anchor.href!)})';
              parent.write(
                anchor.blockContext || inBlockContext() || sawBlockHtml
                    ? '\n\n$linked\n\n'
                    : linked,
              );
              sawBlockHtml = false;
            } else {
              parent
                ..write(anchor.opening)
                ..write(content)
                ..write(raw);
            }
          }
        } else if (tag.selfClosing) {
          target().write(raw);
        } else if (anchors.isNotEmpty) {
          anchors.last.nestedDepth++;
          target().write(raw);
        } else {
          anchors.add(
            _AnchorFrame(
              tag.attributes['href'],
              raw,
              inBlockContext() || sawBlockHtml || _lineIndent(source, i) >= 4,
            ),
          );
        }
      case 'p':
      case 'div':
      case 'center':
      case 'picture':
        if (tag.closing) {
          final depth = wrappers[tag.name] ?? 0;
          if (depth > 0) {
            wrappers[tag.name] = depth - 1;
            if (tag.name == 'p') {
              target().write('\n\n');
            } else if (tag.name != 'picture') {
              target().write('\n');
            }
          } else {
            target().write(raw);
          }
        } else {
          wrappers[tag.name] = (wrappers[tag.name] ?? 0) + 1;
          if (tag.selfClosing) wrappers[tag.name] = wrappers[tag.name]! - 1;
        }
      case 'source':
        if ((wrappers['picture'] ?? 0) == 0) target().write(raw);
      default:
        target().write(raw);
        if (_blockHtmlTags.contains(tag.name) && !tag.selfClosing) {
          sawBlockHtml = true;
          final depth = blockTags[tag.name] ?? 0;
          blockTags[tag.name] = tag.closing
              ? (depth > 0 ? depth - 1 : 0)
              : depth + 1;
        }
    }
    copied = tag.end;
    i = tag.end;
  }

  if (media != null) {
    media.raw.write(source.substring(copied));
    writeMediaToken(
      media.src == null
          ? media.raw.toString()
          : _mediaMarkdown(media.src!, media.alt, media.name),
      forceBlock: media.forceBlock,
    );
    copied = source.length;
  }
  target().write(source.substring(copied));
  while (anchors.isNotEmpty) {
    final anchor = anchors.removeLast();
    final content = anchor.content.toString();
    target()
      ..write(anchor.opening)
      ..write(content);
  }
  return root.toString();
}

bool _startsComment(String source, int start) =>
    start + 3 < source.length && source.startsWith('<!--', start);

bool _startsHtmlTag(String source, int start) {
  var name = start + 1;
  if (name >= source.length) return false;
  if (source.codeUnitAt(name) == 0x2F) name++;
  if (name >= source.length) return false;
  final unit = source.codeUnitAt(name);
  return (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
}

int _lineIndent(String source, int offset) {
  var start = offset;
  while (start > 0 && source.codeUnitAt(start - 1) != 0x0A) {
    start--;
  }
  var spaces = 0;
  while (start < offset) {
    final unit = source.codeUnitAt(start++);
    if (unit == 0x20) {
      spaces++;
    } else if (unit == 0x09) {
      spaces += 4;
    } else if (!_isSpace(unit)) {
      return 0;
    }
  }
  return spaces;
}

String _imageMarkdown(Map<String, String> attributes, String src) {
  final alt = _markdownLabel(attributes['alt'] ?? '');
  final width = _dimension(attributes['width']);
  final height = _dimension(attributes['height']);
  final title = width == null && height == null
      ? null
      : '$_sizeTitlePrefix${width ?? ''}:${height ?? ''}';
  return _imageToken(alt, src, title);
}

String _mediaMarkdown(String src, String? alt, String kind) =>
    _imageToken(_markdownLabel(alt ?? ''), src, '$_mediaTitle:$kind');

String _imageToken(String alt, String src, String? title) {
  final out = StringBuffer('![$alt](${_markdownDestination(src)}');
  if (title != null) out.write(' "${_markdownTitle(title)}"');
  return (out..write(')')).toString();
}

String? _mediaAlt(Map<String, String> attributes) =>
    attributes['aria-label'] ?? attributes['title'];

String? _dimension(String? value) {
  if (value == null || value.isEmpty) return null;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit < 0x30 || unit > 0x39) return null;
  }
  return value;
}

String _markdownLabel(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll('[', '\\[')
    .replaceAll(']', '\\]')
    .replaceAll(RegExp(r'[\r\n]+'), ' ');

String _markdownTitle(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

String _markdownDestination(String value) {
  final escaped = value
      .replaceAll('<', '%3C')
      .replaceAll('>', '%3E')
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A');
  return '<$escaped>';
}

bool _isMediaDestination(String destination) {
  var value = destination.trim().toLowerCase();
  final fragment = value.indexOf('#');
  if (fragment >= 0) value = value.substring(0, fragment);
  final query = value.indexOf('?');
  if (query >= 0) value = value.substring(0, query);
  for (final extension in _mediaExtensions) {
    if (value.endsWith(extension)) return true;
  }
  return false;
}

_LinkDestination? _linkDestination(String body) {
  var start = 0;
  while (start < body.length && _isSpace(body.codeUnitAt(start))) {
    start++;
  }
  if (start == body.length) return null;
  if (body.codeUnitAt(start) == 0x3C) {
    final end = body.indexOf('>', start + 1);
    if (end < 0) return null;
    final value = body.substring(start + 1, end);
    return _LinkDestination(value, body.substring(start, end + 1));
  }
  var end = start;
  var depth = 0;
  while (end < body.length) {
    final unit = body.codeUnitAt(end);
    if (unit == 0x5C && end + 1 < body.length) {
      end += 2;
      continue;
    }
    if (_isSpace(unit) && depth == 0) break;
    if (unit == 0x28) depth++;
    if (unit == 0x29) {
      if (depth == 0) break;
      depth--;
    }
    end++;
  }
  if (end == start) return null;
  return _LinkDestination(
    body
        .substring(start, end)
        .replaceAllMapped(RegExp(r'\\(.)'), (match) => match[1]!),
    body.substring(start, end),
  );
}

({Map<int, int> brackets, Map<int, int> parentheses, Map<int, int> angles})
_delimiterPairs(String source) {
  final brackets = <int, int>{};
  final parentheses = <int, int>{};
  final angles = <int, int>{};
  final bracketStack = <int>[];
  final parenthesisStack = <int>[];
  int? angleStart;
  for (var i = 0; i < source.length; i++) {
    final unit = source.codeUnitAt(i);
    if (unit == 0x5C && i + 1 < source.length) {
      i++;
      continue;
    }
    switch (unit) {
      case 0x5B:
        bracketStack.add(i);
      case 0x5D:
        if (bracketStack.isNotEmpty) {
          brackets[bracketStack.removeLast()] = i;
        }
      case 0x28:
        parenthesisStack.add(i);
      case 0x29:
        if (parenthesisStack.isNotEmpty) {
          parentheses[parenthesisStack.removeLast()] = i;
        }
      case 0x3C:
        angleStart = i;
      case 0x3E:
        if (angleStart != null) {
          angles[angleStart] = i;
          angleStart = null;
        }
    }
  }
  return (brackets: brackets, parentheses: parentheses, angles: angles);
}

int? _tagEnd(String source, int start, [int? limit]) {
  var quote = 0;
  final scanEnd = limit ?? source.length;
  for (var i = start + 1; i < scanEnd; i++) {
    final unit = source.codeUnitAt(i);
    if (unit == 0x3C) return null;
    if (quote != 0) {
      if (unit == quote) quote = 0;
      continue;
    }
    if (unit == 0x22 || unit == 0x27) {
      quote = unit;
    } else if (unit == 0x3E) {
      return i + 1;
    }
  }
  return null;
}

_HtmlTag? _readTag(String source, int start, int end) {
  if (start + 1 >= end) return null;
  final contentEnd = end - 1;
  var i = start + 1;
  var closing = false;
  if (source.codeUnitAt(i) == 0x2F) {
    closing = true;
    i++;
  }
  final nameStart = i;
  while (i < contentEnd && _isName(source.codeUnitAt(i))) {
    i++;
  }
  if (i == nameStart) return null;
  final name = source.substring(nameStart, i).toLowerCase();
  final attributes = <String, String>{};
  var selfClosing = false;
  while (i < contentEnd) {
    while (i < contentEnd && _isSpace(source.codeUnitAt(i))) {
      i++;
    }
    if (i >= contentEnd) break;
    if (source.codeUnitAt(i) == 0x2F && i + 1 == contentEnd) {
      selfClosing = true;
      i++;
      break;
    }
    final attributeStart = i;
    while (i < contentEnd &&
        !_isSpace(source.codeUnitAt(i)) &&
        source.codeUnitAt(i) != 0x3D &&
        source.codeUnitAt(i) != 0x2F) {
      i++;
    }
    if (i == attributeStart) return null;
    final attribute = source.substring(attributeStart, i).toLowerCase();
    while (i < contentEnd && _isSpace(source.codeUnitAt(i))) {
      i++;
    }
    var value = '';
    if (i < contentEnd && source.codeUnitAt(i) == 0x3D) {
      i++;
      while (i < contentEnd && _isSpace(source.codeUnitAt(i))) {
        i++;
      }
      if (i >= contentEnd) return null;
      final quote = source.codeUnitAt(i);
      if (quote == 0x22 || quote == 0x27) {
        final valueStart = ++i;
        while (i < contentEnd && source.codeUnitAt(i) != quote) {
          i++;
        }
        if (i >= contentEnd) return null;
        value = source.substring(valueStart, i++);
      } else {
        final valueStart = i;
        while (i < contentEnd &&
            !_isSpace(source.codeUnitAt(i)) &&
            !(source.codeUnitAt(i) == 0x2F && i + 1 == contentEnd)) {
          i++;
        }
        value = source.substring(valueStart, i);
      }
    }
    attributes.putIfAbsent(attribute, () => _decodeHtml(value));
  }
  return _HtmlTag(name, closing, selfClosing, attributes, end);
}

String _decodeHtml(String value) => value.replaceAllMapped(
  RegExp(r'&(?:#(\d+)|#x([0-9A-Fa-f]+)|amp|quot|apos|lt|gt);'),
  (match) {
    final decimal = match[1];
    if (decimal != null) {
      return _decodeCodePoint(decimal, 10, match[0]!);
    }
    final hex = match[2];
    if (hex != null) return _decodeCodePoint(hex, 16, match[0]!);
    return switch (match[0]) {
      '&amp;' => '&',
      '&quot;' => '"',
      '&apos;' => "'",
      '&lt;' => '<',
      '&gt;' => '>',
      _ => match[0]!,
    };
  },
);

String _decodeCodePoint(String value, int radix, String fallback) {
  final codePoint = int.tryParse(value, radix: radix);
  if (codePoint == null ||
      codePoint == 0 ||
      codePoint > 0x10FFFF ||
      (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
    return fallback;
  }
  return String.fromCharCode(codePoint);
}

_Fence? _fenceAt(String source, int start, int end) {
  var i = _containerPrefixEnd(source, start, end);
  var spaces = 0;
  while (i < end && source.codeUnitAt(i) == 0x20 && spaces < 4) {
    spaces++;
    i++;
  }
  if (spaces > 3) return null;
  final listEnd = _listMarkerEnd(source, i, end);
  if (listEnd != null) {
    i = listEnd;
    spaces = 0;
    while (i < end && source.codeUnitAt(i) == 0x20 && spaces < 4) {
      spaces++;
      i++;
    }
  }
  if (spaces > 3 || i >= end) return null;
  final marker = source.codeUnitAt(i);
  if (marker != 0x60 && marker != 0x7E) return null;
  final runStart = i;
  while (i < end && source.codeUnitAt(i) == marker) {
    i++;
  }
  final length = i - runStart;
  if (length < 3) return null;
  if (marker == 0x60) {
    while (i < end) {
      if (source.codeUnitAt(i++) == 0x60) return null;
    }
  }
  return _Fence(marker, length);
}

int? _listMarkerEnd(String source, int start, int end) {
  if (start >= end) return null;
  var i = start;
  final first = source.codeUnitAt(i);
  if (first == 0x2D || first == 0x2B || first == 0x2A) {
    i++;
  } else if (first >= 0x30 && first <= 0x39) {
    var digits = 0;
    while (i < end &&
        source.codeUnitAt(i) >= 0x30 &&
        source.codeUnitAt(i) <= 0x39 &&
        digits < 9) {
      digits++;
      i++;
    }
    if (i >= end ||
        (source.codeUnitAt(i) != 0x2E && source.codeUnitAt(i) != 0x29)) {
      return null;
    }
    i++;
  } else {
    return null;
  }
  if (i >= end ||
      (source.codeUnitAt(i) != 0x20 && source.codeUnitAt(i) != 0x09)) {
    return null;
  }
  return i + 1;
}

bool _closesFence(String source, int start, int end, _Fence fence) {
  var i = _containerPrefixEnd(source, start, end);
  var spaces = 0;
  while (i < end && source.codeUnitAt(i) == 0x20 && spaces < 4) {
    spaces++;
    i++;
  }
  if (spaces > 3) return false;
  final runStart = i;
  while (i < end && source.codeUnitAt(i) == fence.marker) {
    i++;
  }
  if (i - runStart < fence.length) return false;
  while (i < end) {
    final unit = source.codeUnitAt(i++);
    if (unit != 0x20 && unit != 0x09 && unit != 0x0D) return false;
  }
  return true;
}

bool _isName(int unit) =>
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A) ||
    (unit >= 0x30 && unit <= 0x39) ||
    unit == 0x2D;

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

String _blankExceptNewlines(String source) => String.fromCharCodes(
  source.codeUnits.map((unit) => unit == 0x0A || unit == 0x0D ? unit : 0x20),
);

List<_CodeRange> _codeBlockRanges(String source) {
  final ranges = <_CodeRange>[];
  final wrappers = <String, int>{};
  var inHtmlComment = false;
  var lineStart = 0;
  var previousBlank = true;
  while (lineStart < source.length) {
    final newline = source.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? source.length : newline;
    final nextLine = newline < 0 ? source.length : newline + 1;
    final opening = _fenceAt(source, lineStart, lineEnd);
    if (opening != null) {
      var fenceEnd = nextLine;
      var cursor = nextLine;
      while (cursor < source.length) {
        final nextNewline = source.indexOf('\n', cursor);
        final nextEnd = nextNewline < 0 ? source.length : nextNewline;
        fenceEnd = nextNewline < 0 ? source.length : nextNewline + 1;
        if (_closesFence(source, cursor, nextEnd, opening)) break;
        cursor = fenceEnd;
      }
      ranges.add(_CodeRange(lineStart, fenceEnd));
      lineStart = fenceEnd;
      previousBlank = true;
      continue;
    }
    final insideWrapper = wrappers.values.any((depth) => depth > 0);
    if (!insideWrapper &&
        previousBlank &&
        _isIndentedCodeLine(source, lineStart, lineEnd)) {
      var codeEnd = nextLine;
      var cursor = nextLine;
      while (cursor < source.length) {
        final nextNewline = source.indexOf('\n', cursor);
        final nextEnd = nextNewline < 0 ? source.length : nextNewline;
        if (!_isBlankLine(source, cursor, nextEnd) &&
            !_isIndentedCodeLine(source, cursor, nextEnd)) {
          break;
        }
        codeEnd = nextNewline < 0 ? source.length : nextNewline + 1;
        cursor = codeEnd;
      }
      ranges.add(_CodeRange(lineStart, codeEnd));
      lineStart = codeEnd;
      previousBlank = true;
      continue;
    }
    inHtmlComment = _updateWrapperDepth(
      source,
      lineStart,
      lineEnd,
      wrappers,
      inHtmlComment,
    );
    previousBlank = _isBlankLine(source, lineStart, lineEnd);
    lineStart = nextLine;
  }
  return ranges;
}

bool _updateWrapperDepth(
  String source,
  int start,
  int end,
  Map<String, int> wrappers,
  bool inComment,
) {
  var i = start;
  if (inComment) {
    final close = _commentCloseBefore(source, i, end);
    if (close == null) return true;
    i = close + 3;
    inComment = false;
  }
  while (i < end) {
    while (i < end && source.codeUnitAt(i) != 0x3C) {
      i++;
    }
    if (i >= end) return inComment;
    final next = i;
    if (_startsComment(source, next)) {
      final close = _commentCloseBefore(source, next + 4, end);
      if (close == null) return true;
      i = close + 3;
      continue;
    }
    if (!_startsHtmlTag(source, next)) {
      i = next + 1;
      continue;
    }
    final tagEnd = _tagEnd(source, next, end);
    if (tagEnd == null) {
      i = next + 1;
      continue;
    }
    final tag = _readTag(source, next, tagEnd);
    final wrapperActive = wrappers.values.any((depth) => depth > 0);
    if (tag != null &&
        _layoutWrapperTags.contains(tag.name) &&
        (wrapperActive || _onlySpaceBefore(source, start, next))) {
      final depth = wrappers[tag.name] ?? 0;
      if (tag.closing) {
        wrappers[tag.name] = depth > 0 ? depth - 1 : 0;
      } else if (!tag.selfClosing) {
        wrappers[tag.name] = depth + 1;
      }
    }
    i = tagEnd;
  }
  return inComment;
}

bool _onlySpaceBefore(String source, int start, int end) {
  while (start < end) {
    final unit = source.codeUnitAt(start++);
    if (unit != 0x20 && unit != 0x09 && unit != 0x0D) return false;
  }
  return true;
}

int? _commentCloseBefore(String source, int start, int end) {
  for (var i = start; i + 2 < end; i++) {
    if (source.codeUnitAt(i) == 0x2D &&
        source.codeUnitAt(i + 1) == 0x2D &&
        source.codeUnitAt(i + 2) == 0x3E) {
      return i;
    }
  }
  return null;
}

bool _isBlankLine(String source, int start, int end) {
  start = _containerPrefixEnd(source, start, end);
  while (start < end) {
    final unit = source.codeUnitAt(start++);
    if (unit != 0x20 && unit != 0x09 && unit != 0x0D) return false;
  }
  return true;
}

bool _isIndentedCodeLine(String source, int start, int end) {
  var i = _containerPrefixEnd(source, start, end);
  var columns = 0;
  while (i < end && columns < 4) {
    final unit = source.codeUnitAt(i);
    if (unit == 0x20) {
      columns++;
    } else if (unit == 0x09) {
      columns = 4;
    } else {
      break;
    }
    i++;
  }
  return columns >= 4 && i < end;
}

int _containerPrefixEnd(String source, int start, int end) {
  var i = start;
  while (i < end) {
    var marker = i;
    var leading = 0;
    while (marker < end && source.codeUnitAt(marker) == 0x20 && leading < 3) {
      leading++;
      marker++;
    }
    if (marker >= end || source.codeUnitAt(marker) != 0x3E) break;
    i = marker;
    i++;
    if (i < end &&
        (source.codeUnitAt(i) == 0x20 || source.codeUnitAt(i) == 0x09)) {
      i++;
    }
  }
  return i;
}

class _Fence {
  const _Fence(this.marker, this.length);
  final int marker;
  final int length;
}

class _CodeRange {
  const _CodeRange(this.start, this.end);
  final int start;
  final int end;
}

class _TickRun {
  const _TickRun(this.start, this.length);
  final int start;
  final int length;
}

class _HtmlTag {
  const _HtmlTag(
    this.name,
    this.closing,
    this.selfClosing,
    this.attributes,
    this.end,
  );
  final String name;
  final bool closing;
  final bool selfClosing;
  final Map<String, String> attributes;
  final int end;
}

class _AnchorFrame {
  _AnchorFrame(this.href, this.opening, this.blockContext);
  final String? href;
  final String opening;
  final bool blockContext;
  final content = StringBuffer();
  int nestedDepth = 0;
}

class _MediaFrame {
  _MediaFrame(this.name, this.src, this.alt, this.raw, this.forceBlock);
  final String name;
  String? src;
  final String? alt;
  final StringBuffer raw;
  final bool forceBlock;
}

class _LinkDestination {
  const _LinkDestination(this.value, this.markdown);
  final String value;
  final String markdown;
}
