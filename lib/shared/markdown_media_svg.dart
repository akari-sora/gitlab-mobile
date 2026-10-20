import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../core/failure.dart';

const _maxSvgBytes = 10 * 1024 * 1024;
const _maxEmbeddedRasterBytes = 5 * 1024 * 1024;
const _maxRasterPixels = 24000000;
const _maxSvgMarkup = 100000;
const _isolateThreshold = 64 * 1024;

/// Detects and sanitises SVG image bytes. Raster input returns null. Unsafe or
/// malformed SVG throws an [ApiFailure] and large inputs run outside the UI
/// isolate.
Future<Uint8List?> sanitizeMarkdownSvg(
  Uint8List bytes, {
  String? contentType,
}) async {
  if (bytes.length > _maxSvgBytes) {
    throw const ApiFailure(FailureKind.tooLarge);
  }
  final type = (contentType ?? '').split(';').first.trim().toLowerCase();
  if (bytes.length <= _isolateThreshold) {
    return _sanitizeSvgBytes(bytes, type);
  }
  return Isolate.run(() => _sanitizeSvgBytes(bytes, type));
}

Uint8List? _sanitizeSvgBytes(Uint8List bytes, String contentType) {
  final loose = utf8.decode(bytes, allowMalformed: true);
  if (contentType != 'image/svg+xml' && !_looksLikeSvg(loose)) return null;
  var markup = 0;
  for (final byte in bytes) {
    if (byte == 0) throw const ApiFailure(FailureKind.redirectBlocked);
    if (byte == 0x3c && ++markup > _maxSvgMarkup) {
      throw const ApiFailure(FailureKind.tooLarge);
    }
  }

  late final XmlDocument document;
  try {
    document = XmlDocument.parse(utf8.decode(bytes));
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  } on XmlException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }

  if (document.rootElement.name.local.toLowerCase() != 'svg') {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  if (document.doctypeElement?.internalSubset != null) {
    throw const ApiFailure(FailureKind.redirectBlocked);
  }

  final removable = <XmlNode>[];
  for (final node in document.descendants) {
    if (node is XmlComment || node is XmlDoctype) {
      removable.add(node);
      continue;
    }
    if (node is XmlProcessing) {
      throw const ApiFailure(FailureKind.redirectBlocked);
    }
    if (node is! XmlElement) continue;
    final name = node.name.local.toLowerCase();
    if (name == 'script' || name == 'foreignobject') {
      throw const ApiFailure(FailureKind.redirectBlocked);
    }
    if (name == 'style') {
      removable.add(node);
      continue;
    }
    for (final attribute in node.attributes) {
      final attributeName = attribute.name.local.toLowerCase();
      final value = attribute.value.trim();
      if (attributeName.startsWith('on')) {
        throw const ApiFailure(FailureKind.redirectBlocked);
      }
      if (attributeName == 'href') {
        if (value.startsWith('data:') && name == 'image') {
          _validateEmbeddedRaster(value);
        } else if (!value.startsWith('#')) {
          throw const ApiFailure(FailureKind.redirectBlocked);
        }
      }
      if (!_urlsAreLocal(value) ||
          (attributeName == 'style' && !_styleReferencesAreLocal(value))) {
        throw const ApiFailure(FailureKind.redirectBlocked);
      }
    }
  }
  for (final node in removable.reversed) {
    node.parent?.children.remove(node);
  }
  return Uint8List.fromList(utf8.encode(document.toXmlString()));
}

bool _looksLikeSvg(String text) {
  try {
    for (final event in parseEvents(text)) {
      if (event is XmlStartElementEvent) {
        return event.localName.toLowerCase() == 'svg';
      }
    }
    return false;
  } on XmlException {
    return false;
  }
}

void _validateEmbeddedRaster(String uri) {
  final separator = uri.indexOf(',');
  if (separator < 0) throw const ApiFailure(FailureKind.redirectBlocked);
  final metadata = uri.substring(5, separator).toLowerCase();
  if (!metadata.endsWith(';base64')) {
    throw const ApiFailure(FailureKind.redirectBlocked);
  }
  final mediaType = metadata.substring(0, metadata.length - 7);
  if (mediaType != 'image/png' &&
      mediaType != 'image/jpeg' &&
      mediaType != 'image/gif' &&
      mediaType != 'image/webp') {
    throw const ApiFailure(FailureKind.redirectBlocked);
  }
  late final Uint8List data;
  try {
    data = base64Decode(uri.substring(separator + 1));
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  if (data.length > _maxEmbeddedRasterBytes) {
    throw const ApiFailure(FailureKind.tooLarge);
  }
  final dimensions = _rasterDimensions(data, mediaType);
  if (dimensions == null || dimensions.$1 <= 0 || dimensions.$2 <= 0) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  if (dimensions.$1 * dimensions.$2 > _maxRasterPixels) {
    throw const ApiFailure(FailureKind.tooLarge);
  }
}

(int, int)? _rasterDimensions(Uint8List data, String mediaType) =>
    switch (mediaType) {
      'image/png' => _pngDimensions(data),
      'image/gif' => _gifDimensions(data),
      'image/jpeg' => _jpegDimensions(data),
      'image/webp' => _webpDimensions(data),
      _ => null,
    };

(int, int)? _pngDimensions(Uint8List data) {
  if (data.length < 24 ||
      data[0] != 0x89 ||
      data[1] != 0x50 ||
      data[2] != 0x4e ||
      data[3] != 0x47 ||
      data[12] != 0x49 ||
      data[13] != 0x48 ||
      data[14] != 0x44 ||
      data[15] != 0x52) {
    return null;
  }
  final view = ByteData.sublistView(data);
  return (view.getUint32(16), view.getUint32(20));
}

(int, int)? _gifDimensions(Uint8List data) {
  if (data.length < 10 ||
      data[0] != 0x47 ||
      data[1] != 0x49 ||
      data[2] != 0x46) {
    return null;
  }
  final view = ByteData.sublistView(data);
  return (view.getUint16(6, Endian.little), view.getUint16(8, Endian.little));
}

(int, int)? _jpegDimensions(Uint8List data) {
  if (data.length < 4 || data[0] != 0xff || data[1] != 0xd8) return null;
  var offset = 2;
  while (offset + 3 < data.length) {
    if (data[offset++] != 0xff) continue;
    while (offset < data.length && data[offset] == 0xff) {
      offset++;
    }
    if (offset >= data.length) return null;
    final marker = data[offset++];
    if (marker == 0xd8 || marker == 0xd9 || marker == 0x01) continue;
    if (offset + 1 >= data.length) return null;
    final length = (data[offset] << 8) | data[offset + 1];
    if (length < 2 || offset + length > data.length) return null;
    if (_jpegStartOfFrame(marker) && length >= 7) {
      final height = (data[offset + 3] << 8) | data[offset + 4];
      final width = (data[offset + 5] << 8) | data[offset + 6];
      return (width, height);
    }
    offset += length;
  }
  return null;
}

bool _jpegStartOfFrame(int marker) =>
    marker >= 0xc0 &&
    marker <= 0xcf &&
    marker != 0xc4 &&
    marker != 0xc8 &&
    marker != 0xcc;

(int, int)? _webpDimensions(Uint8List data) {
  if (data.length < 30 ||
      ascii.decode(data.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(data.sublist(8, 12), allowInvalid: true) != 'WEBP') {
    return null;
  }
  final kind = ascii.decode(data.sublist(12, 16), allowInvalid: true);
  if (kind == 'VP8X') {
    return (_uint24(data, 24) + 1, _uint24(data, 27) + 1);
  }
  if (kind == 'VP8L' && data.length >= 25 && data[20] == 0x2f) {
    final bits =
        data[21] | (data[22] << 8) | (data[23] << 16) | (data[24] << 24);
    return ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
  }
  if (kind == 'VP8 ' &&
      data.length >= 30 &&
      data[23] == 0x9d &&
      data[24] == 0x01 &&
      data[25] == 0x2a) {
    final width = (data[26] | (data[27] << 8)) & 0x3fff;
    final height = (data[28] | (data[29] << 8)) & 0x3fff;
    return (width, height);
  }
  return null;
}

int _uint24(Uint8List data, int offset) =>
    data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);

bool _styleReferencesAreLocal(String style) {
  var start = 0;
  while (start < style.length) {
    final end = style.indexOf(';', start);
    final declaration = style.substring(start, end < 0 ? style.length : end);
    final separator = declaration.indexOf(':');
    if (separator >= 0 &&
        declaration.substring(0, separator).trim().toLowerCase() == 'href' &&
        !declaration.substring(separator + 1).trim().startsWith('#')) {
      return false;
    }
    if (end < 0) return true;
    start = end + 1;
  }
  return true;
}

bool _urlsAreLocal(String text) {
  var i = 0;
  while (true) {
    i = _indexOfAsciiCaseInsensitive(text, 'url', i);
    if (i < 0) return true;
    var cursor = _skipWhitespace(text, i + 3);
    if (cursor >= text.length || text.codeUnitAt(cursor) != 0x28) {
      i += 3;
      continue;
    }
    final end = text.indexOf(')', cursor + 1);
    if (end < 0) return false;
    var value = text.substring(cursor + 1, end).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    if (!value.startsWith('#')) return false;
    i = end + 1;
  }
}

int _skipWhitespace(String text, int start) {
  var i = start;
  while (i < text.length && _isWhitespace(text.codeUnitAt(i))) {
    i++;
  }
  return i;
}

bool _isWhitespace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;

int _indexOfAsciiCaseInsensitive(String text, String pattern, int start) {
  for (var i = start; i + pattern.length <= text.length; i++) {
    var matches = true;
    for (var j = 0; j < pattern.length; j++) {
      if (_asciiLower(text.codeUnitAt(i + j)) !=
          _asciiLower(pattern.codeUnitAt(j))) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

int _asciiLower(int unit) => unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit;
