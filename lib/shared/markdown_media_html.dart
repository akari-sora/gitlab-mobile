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

/// Converts the small HTML/media subset accepted by GitLab Markdown into
/// Markdown nodes understood by the app's image builder.
///
/// Fenced code blocks and code spans are copied byte-for-byte. The scanners
/// advance monotonically, including for malformed input, so processing stays
/// linear in the source length.
String preprocessMarkdownMedia(String source) {
  if (source.isEmpty) return source;
  final out = StringBuffer();
  var plainStart = 0;
  var lineStart = 0;
  while (lineStart < source.length) {
    final newline = source.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? source.length : newline;
    final opening = _fenceAt(source, lineStart, lineEnd);
    if (opening == null) {
      lineStart = newline < 0 ? source.length : newline + 1;
      continue;
    }
    if (plainStart < lineStart) {
      out.write(
        _transformOutsideFences(source.substring(plainStart, lineStart)),
      );
    }
    var fenceEnd = newline < 0 ? source.length : newline + 1;
    var nextLine = fenceEnd;
    while (nextLine < source.length) {
      final nextNewline = source.indexOf('\n', nextLine);
      final nextEnd = nextNewline < 0 ? source.length : nextNewline;
      fenceEnd = nextNewline < 0 ? source.length : nextNewline + 1;
      if (_closesFence(source, nextLine, nextEnd, opening)) break;
      nextLine = fenceEnd;
    }
    out.write(source.substring(lineStart, fenceEnd));
    lineStart = fenceEnd;
    plainStart = fenceEnd;
  }
  if (plainStart < source.length) {
    out.write(_transformOutsideFences(source.substring(plainStart)));
  }
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
      if (end != null && end > i + 1) {
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
        if (destination != null && !label.contains('![')) {
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
        if (destination != null && _isMediaDestination(destination.value)) {
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

String _transformOutsideFences(String source) {
  final references = _mediaReferenceDestinations(source);
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
) => _convertMarkdownMediaLinks(_convertHtmlMedia(source), references);

String _convertHtmlMedia(String source) {
  final root = StringBuffer();
  final anchors = <_AnchorFrame>[];
  final wrappers = <String, int>{};
  _MediaFrame? media;
  StringBuffer target() => anchors.isEmpty ? root : anchors.last.content;
  var copied = 0;
  var i = 0;
  while (i < source.length) {
    if (source.codeUnitAt(i) != 0x3C) {
      i++;
      continue;
    }
    final tagEnd = _tagEnd(source, i);
    if (tagEnd == null) break;
    final tag = _readTag(source, i, tagEnd);
    if (tag == null) {
      i = tagEnd;
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
        target().write(replacement);
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
          target().write(
            src == null ? raw : _imageMarkdown(tag.attributes, src),
          );
        } else {
          target().write(raw);
        }
      case 'video':
      case 'audio':
        if (tag.closing) {
          target().write(raw);
        } else if (tag.selfClosing) {
          final src = tag.attributes['src'];
          target().write(
            src == null
                ? raw
                : _mediaMarkdown(src, _mediaAlt(tag.attributes), tag.name),
          );
        } else {
          media = _MediaFrame(
            tag.name,
            tag.attributes['src'],
            _mediaAlt(tag.attributes),
            StringBuffer(raw),
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
              parent
                ..write('[')
                ..write(content)
                ..write('](')
                ..write(_markdownDestination(anchor.href!))
                ..write(')');
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
          anchors.add(_AnchorFrame(tag.attributes['href'], raw));
        }
      case 'p':
      case 'div':
      case 'center':
      case 'picture':
        if (tag.closing) {
          final depth = wrappers[tag.name] ?? 0;
          if (depth > 0) {
            wrappers[tag.name] = depth - 1;
            if (tag.name != 'picture') target().write('\n');
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
    }
    copied = tag.end;
    i = tag.end;
  }

  if (media != null) {
    media.raw.write(source.substring(copied));
    target().write(
      media.src == null
          ? media.raw.toString()
          : _mediaMarkdown(media.src!, media.alt, media.name),
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

int? _tagEnd(String source, int start) {
  var quote = 0;
  for (var i = start + 1; i < source.length; i++) {
    final unit = source.codeUnitAt(i);
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
  var i = start;
  var spaces = 0;
  while (i < end && source.codeUnitAt(i) == 0x20 && spaces < 4) {
    spaces++;
    i++;
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

bool _closesFence(String source, int start, int end, _Fence fence) {
  var i = start;
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

class _Fence {
  const _Fence(this.marker, this.length);
  final int marker;
  final int length;
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
  _AnchorFrame(this.href, this.opening);
  final String? href;
  final String opening;
  final content = StringBuffer();
  int nestedDepth = 0;
}

class _MediaFrame {
  _MediaFrame(this.name, this.src, this.alt, this.raw);
  final String name;
  String? src;
  final String? alt;
  final StringBuffer raw;
}

class _LinkDestination {
  const _LinkDestination(this.value, this.markdown);
  final String value;
  final String markdown;
}
