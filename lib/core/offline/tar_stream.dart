import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

enum TarFailure { corruptArchive, shaMismatch, archiveTooLarge }

final class TarException implements Exception {
  const TarException(this.failure);
  final TarFailure failure;
}

enum TarEntryType { file, directory, symlink, unsupported }

final class TarEntry {
  const TarEntry({required this.path, required this.type, required this.size});

  /// Null indicates a path whose bytes are not valid UTF-8. It is unmatched.
  final String? path;
  final TarEntryType type;
  final int size;
}

typedef TarRetainLimit = int? Function(TarEntry entry);
typedef TarEntrySink = FutureOr<void> Function(TarEntry entry, Uint8List? data);

/// Incremental tar parser. Its input is already decompressed, and the caller
/// must finish validating the gzip stream before publishing any entries.
final class TarStreamParser {
  TarStreamParser({
    required this.expectedSha,
    required this.retainLimit,
    required this.onEntry,
    this.maxExpandedBytes = 1024 * 1024 * 1024,
  });

  final String expectedSha;
  final TarRetainLimit retainLimit;
  final TarEntrySink onEntry;
  final int maxExpandedBytes;

  static const int _block = 512;
  static const int _maxNumber = 1 << 40;
  final Uint8List _header = Uint8List(_block);
  int _headerUsed = 0;
  int _expanded = 0;
  int _zeroBlocks = 0;
  bool _ended = false;
  bool _finished = false;
  bool _metadataPending = false;
  int _remaining = 0;
  int _padding = 0;
  int? _metadata;
  TarEntry? _entry;
  BytesBuilder? _data;
  Uint8List? _localPath;
  int? _localSize;
  Uint8List? _longName;
  Uint8List? _wrapper;
  final Set<String> _seen = <String>{};

  Future<void> add(List<int> bytes) async {
    if (_finished) throw const TarException(TarFailure.corruptArchive);
    _expanded += bytes.length;
    if (_expanded > maxExpandedBytes) {
      throw const TarException(TarFailure.archiveTooLarge);
    }
    var offset = 0;
    while (offset < bytes.length) {
      if (_ended) {
        for (; offset < bytes.length; offset++) {
          if (bytes[offset] != 0) {
            throw const TarException(TarFailure.corruptArchive);
          }
        }
        break;
      }
      if (_remaining > 0) {
        final n = _remaining < bytes.length - offset
            ? _remaining
            : bytes.length - offset;
        _data?.add(bytes.sublist(offset, offset + n));
        offset += n;
        _remaining -= n;
        if (_remaining == 0) await _endData();
        continue;
      }
      if (_padding > 0) {
        final n = _padding < bytes.length - offset
            ? _padding
            : bytes.length - offset;
        offset += n;
        _padding -= n;
        continue;
      }
      final n = _block - _headerUsed < bytes.length - offset
          ? _block - _headerUsed
          : bytes.length - offset;
      _header.setRange(_headerUsed, _headerUsed + n, bytes, offset);
      _headerUsed += n;
      offset += n;
      if (_headerUsed == _block) {
        _headerUsed = 0;
        await _readHeader();
      }
    }
  }

  void finish() {
    _finished = true;
    if (!_ended ||
        _headerUsed != 0 ||
        _remaining != 0 ||
        _padding != 0 ||
        _metadata != null ||
        _entry != null ||
        _localPath != null ||
        _localSize != null ||
        _longName != null ||
        _metadataPending) {
      throw const TarException(TarFailure.corruptArchive);
    }
  }

  Future<void> _readHeader() async {
    if (_header.every((byte) => byte == 0)) {
      _zeroBlocks++;
      if (_zeroBlocks == 2) _ended = true;
      return;
    }
    if (_zeroBlocks != 0) throw const TarException(TarFailure.corruptArchive);
    final expected = _octal(148, 8);
    var unsigned = 0;
    var signed = 0;
    for (var i = 0; i < _block; i++) {
      final value = i >= 148 && i < 156 ? 32 : _header[i];
      unsigned += value;
      signed += value >= 128 ? value - 256 : value;
    }
    if (expected != unsigned && expected != signed) {
      throw const TarException(TarFailure.corruptArchive);
    }
    // These numeric header fields are never used as filesystem metadata.
    for (final field in const <(int, int)>[
      (100, 8),
      (108, 8),
      (116, 8),
      (136, 12),
      (329, 8),
      (337, 8),
    ]) {
      _octal(field.$1, field.$2);
    }
    final headerSize = _octal(124, 12);
    if (headerSize > _maxNumber) {
      throw const TarException(TarFailure.corruptArchive);
    }
    final type = _header[156];
    if (type == 120 || type == 103 || type == 76 || type == 75) {
      if ((type == 120 || type == 103) && headerSize > 64 * 1024 ||
          (type == 76 || type == 75) && headerSize > 4097) {
        throw const TarException(TarFailure.corruptArchive);
      }
      if (type != 103) _metadataPending = true;
      _metadata = type;
      _data = BytesBuilder(copy: false);
      _remaining = headerSize;
      _padding = (_block - headerSize % _block) % _block;
      if (_remaining == 0) await _endData();
      return;
    }
    _metadataPending = false;
    final size = _localSize ?? headerSize;
    final path = _localPath ?? _longName ?? _headerPath();
    _localPath = null;
    _localSize = null;
    _longName = null;
    final entryType = switch (type) {
      0 || 48 => TarEntryType.file,
      53 => TarEntryType.directory,
      50 => TarEntryType.symlink,
      _ => TarEntryType.unsupported,
    };
    final relative = _normalize(path, entryType == TarEntryType.directory);
    _remaining = size;
    _padding = (_block - size % _block) % _block;
    if (relative != null) {
      String? decoded;
      try {
        decoded = utf8.decode(relative);
      } on FormatException {
        // The parser preserves structural validation; callers count unmatched.
      }
      _entry = TarEntry(path: decoded, type: entryType, size: size);
      final limit = retainLimit(_entry!);
      if (limit != null && limit >= 0 && size <= limit) {
        _data = BytesBuilder(copy: false);
      }
    }
    if (_remaining == 0) await _endData();
  }

  int _octal(int start, int length) {
    if ((_header[start] & 0x80) != 0) {
      throw const TarException(TarFailure.corruptArchive);
    }
    final raw = _header.sublist(start, start + length);
    var first = 0;
    var last = raw.length;
    bool blank(int b) => b == 0 || b == 32;
    while (first < last && blank(raw[first])) {
      first++;
    }
    while (last > first && blank(raw[last - 1])) {
      last--;
    }
    var value = 0;
    for (var i = first; i < last; i++) {
      final digit = raw[i] - 48;
      if (digit < 0 || digit > 7) {
        throw const TarException(TarFailure.corruptArchive);
      }
      value = value * 8 + digit;
      if (value > _maxNumber && start == 124) {
        throw const TarException(TarFailure.corruptArchive);
      }
    }
    return value;
  }

  Uint8List _cstring(int start, int length) {
    final field = _header.sublist(start, start + length);
    final end = field.indexOf(0);
    if (end < 0) return field;
    // NUL is a terminator, not a path component. Reject embedded garbage.
    if (field.skip(end).any((byte) => byte != 0)) {
      throw const TarException(TarFailure.corruptArchive);
    }
    return Uint8List.sublistView(field, 0, end);
  }

  Uint8List _headerPath() {
    final name = _cstring(0, 100);
    final prefix = _cstring(345, 155);
    if (prefix.isEmpty) return name;
    return (BytesBuilder(copy: false)
          ..add(prefix)
          ..addByte(47)
          ..add(name))
        .takeBytes();
  }

  Uint8List? _normalize(Uint8List path, bool directory) {
    if (path.isEmpty || path.first == 47 || path.contains(0)) {
      throw const TarException(TarFailure.corruptArchive);
    }
    final trimmed = directory && path.last == 47
        ? Uint8List.sublistView(path, 0, path.length - 1)
        : path;
    final parts = <Uint8List>[];
    var start = 0;
    for (var i = 0; i <= trimmed.length; i++) {
      if (i == trimmed.length || trimmed[i] == 47) {
        final part = Uint8List.sublistView(trimmed, start, i);
        if (part.isEmpty ||
            part.length == 1 && part[0] == 46 ||
            part.length == 2 && part[0] == 46 && part[1] == 46) {
          throw const TarException(TarFailure.corruptArchive);
        }
        parts.add(part);
        start = i + 1;
      }
    }
    _wrapper ??= Uint8List.fromList(parts.first);
    if (!_equal(parts.first, _wrapper!)) {
      throw const TarException(TarFailure.corruptArchive);
    }
    if (parts.length == 1) {
      if (!directory) throw const TarException(TarFailure.corruptArchive);
      return null;
    }
    final relative = Uint8List.sublistView(trimmed, parts.first.length + 1);
    if (!_seen.add(base64.encode(relative))) {
      throw const TarException(TarFailure.corruptArchive);
    }
    return relative;
  }

  bool _equal(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  Future<void> _endData() async {
    final bytes = _data?.takeBytes();
    _data = null;
    final metadata = _metadata;
    _metadata = null;
    if (metadata != null) {
      if (metadata == 120 || metadata == 103) {
        _readPax(bytes!, global: metadata == 103);
      } else if (metadata == 76) {
        _longName = _gnuString(bytes!);
      } else {
        _gnuString(bytes!); // Validate but ignore link targets.
      }
    } else if (_entry != null) {
      final entry = _entry!;
      _entry = null;
      await onEntry(entry, bytes);
      await Future<void>.delayed(Duration.zero);
    }
  }

  Uint8List _gnuString(Uint8List value) {
    final end = value.indexOf(0);
    if (end < 0) return value;
    if (value.skip(end).any((byte) => byte != 0)) {
      throw const TarException(TarFailure.corruptArchive);
    }
    return Uint8List.sublistView(value, 0, end);
  }

  void _readPax(Uint8List data, {required bool global}) {
    Uint8List? localPath;
    int? localSize;
    var cursor = 0;
    while (cursor < data.length) {
      var separator = cursor;
      while (separator < data.length && data[separator] != 32) {
        separator++;
      }
      if (separator == cursor || separator == data.length) {
        throw const TarException(TarFailure.corruptArchive);
      }
      final lengthText = ascii.decode(
        data.sublist(cursor, separator),
        allowInvalid: true,
      );
      if (!RegExp(r'^[0-9]+$').hasMatch(lengthText)) {
        throw const TarException(TarFailure.corruptArchive);
      }
      final length = int.tryParse(lengthText);
      if (length == null ||
          length <= separator - cursor + 2 ||
          cursor + length > data.length ||
          data[cursor + length - 1] != 10) {
        throw const TarException(TarFailure.corruptArchive);
      }
      final start = separator + 1;
      var equal = start;
      while (equal < cursor + length - 1 && data[equal] != 61) {
        equal++;
      }
      if (equal == start || equal == cursor + length - 1) {
        throw const TarException(TarFailure.corruptArchive);
      }
      final key = ascii.decode(data.sublist(start, equal), allowInvalid: true);
      final value = Uint8List.sublistView(data, equal + 1, cursor + length - 1);
      if (global && key == 'comment') {
        final comment = ascii.decode(value, allowInvalid: true);
        if (RegExp(
              r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$',
            ).hasMatch(comment) &&
            comment.toLowerCase() != expectedSha.toLowerCase()) {
          throw const TarException(TarFailure.shaMismatch);
        }
      } else if (!global && key == 'path') {
        localPath = Uint8List.fromList(value);
      } else if (!global && key == 'size') {
        final text = ascii.decode(value, allowInvalid: true);
        if (!RegExp(r'^[0-9]+$').hasMatch(text)) {
          throw const TarException(TarFailure.corruptArchive);
        }
        localSize = int.tryParse(text);
        if (localSize == null || localSize > _maxNumber) {
          throw const TarException(TarFailure.corruptArchive);
        }
      }
      cursor += length;
    }
    if (!global) {
      _localPath = localPath;
      _localSize = localSize;
    }
  }
}
