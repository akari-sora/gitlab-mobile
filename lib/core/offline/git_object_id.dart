import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Git object identity, including the type and byte length prefix.
String gitBlobId(List<int> bytes, String objectFormat) {
  final algorithm = switch (objectFormat) {
    'sha1' => crypto.sha1,
    'sha256' => crypto.sha256,
    _ => throw ArgumentError.value(objectFormat),
  };
  final input = BytesBuilder(copy: false)
    ..add(utf8.encode('blob ${bytes.length}\u0000'))
    ..add(bytes);
  return algorithm.convert(input.takeBytes()).toString();
}

enum ArchiveBlobState { saved, tooLarge, binary, mismatch, symlink }

enum ArchiveBlobKind { text, image, lfsPointer }

final class ArchiveBlobResult {
  const ArchiveBlobResult(this.state, {this.kind, this.bytes, this.lines});
  final ArchiveBlobState state;
  final ArchiveBlobKind? kind;
  final Uint8List? bytes;
  final int? lines;
}

const int maxSnapshotTextBytes = 2 * 1024 * 1024;
const int maxSnapshotImageBytes = 10 * 1024 * 1024;
const int maxSnapshotTextLines = 20000;

bool isSnapshotImagePath(String path) => RegExp(
  r'\.(png|jpe?g|gif|webp|bmp|ico)$',
  caseSensitive: false,
).hasMatch(path);

/// Verify the Git blob before accepting it. Normalization is accepted only
/// when the normalized bytes reproduce the tree's cryptographic object ID.
ArchiveBlobResult verifyArchiveBlob({
  required String path,
  required String mode,
  required String id,
  required String objectFormat,
  required int size,
  required Uint8List? bytes,
}) {
  // A symlink must never be treated as an image solely because of its name.
  if (mode == '120000') {
    return const ArchiveBlobResult(ArchiveBlobState.symlink);
  }
  final image = isSnapshotImagePath(path);
  final limit = image ? maxSnapshotImageBytes : maxSnapshotTextBytes;
  if (size > limit) return const ArchiveBlobResult(ArchiveBlobState.tooLarge);
  if (bytes == null || bytes.length != size) {
    return const ArchiveBlobResult(ArchiveBlobState.mismatch);
  }
  var content = bytes;
  var matches = gitBlobId(content, objectFormat) == id;
  if (!matches && !image) {
    for (final (lf, ident) in const <(bool, bool)>[
      (true, false),
      (false, true),
      (true, true),
    ]) {
      final normalized = _normalizeArchiveBytes(bytes, lf: lf, ident: ident);
      if (gitBlobId(normalized, objectFormat) == id) {
        content = normalized;
        matches = true;
        break;
      }
    }
  }
  if (!matches) return const ArchiveBlobResult(ArchiveBlobState.mismatch);
  if (image) {
    return ArchiveBlobResult(
      ArchiveBlobState.saved,
      kind: ArchiveBlobKind.image,
      bytes: content,
    );
  }
  if (content.contains(0)) {
    return const ArchiveBlobResult(ArchiveBlobState.binary);
  }
  String text;
  try {
    text = utf8.decode(content);
  } on FormatException {
    return const ArchiveBlobResult(ArchiveBlobState.binary);
  }
  final newlines = '\n'.allMatches(text).length;
  final lines = newlines + (text.isNotEmpty && !text.endsWith('\n') ? 1 : 0);
  if (lines > maxSnapshotTextLines) {
    return const ArchiveBlobResult(ArchiveBlobState.binary);
  }
  final kind = text.startsWith('version https://git-lfs.github.com/spec/v1\n')
      ? ArchiveBlobKind.lfsPointer
      : ArchiveBlobKind.text;
  return ArchiveBlobResult(
    ArchiveBlobState.saved,
    kind: kind,
    bytes: content,
    lines: lines,
  );
}

// Git's transformations operate on bytes. UTF-8 validation happens only
// after identity verification, so transformed binary candidates stay binary.
Uint8List _normalizeArchiveBytes(
  Uint8List bytes, {
  required bool lf,
  required bool ident,
}) {
  final result = BytesBuilder(copy: false);
  var start = 0;
  var i = 0;
  bool isHex(int byte) =>
      byte >= 48 && byte <= 57 ||
      byte >= 65 && byte <= 70 ||
      byte >= 97 && byte <= 102;
  while (i < bytes.length) {
    if (lf && i + 1 < bytes.length && bytes[i] == 13 && bytes[i + 1] == 10) {
      result.add(Uint8List.sublistView(bytes, start, i));
      result.addByte(10);
      i += 2;
      start = i;
      continue;
    }
    if (ident &&
        i + 5 < bytes.length &&
        bytes[i] == 36 &&
        bytes[i + 1] == 73 &&
        bytes[i + 2] == 100 &&
        bytes[i + 3] == 58 &&
        bytes[i + 4] == 32) {
      var end = i + 5;
      while (end < bytes.length && isHex(bytes[end]) && end - i - 5 < 65) {
        end++;
      }
      final length = end - i - 5;
      if ((length == 40 || length == 64) &&
          end + 1 < bytes.length &&
          bytes[end] == 32 &&
          bytes[end + 1] == 36) {
        result.add(Uint8List.sublistView(bytes, start, i));
        result.add(const <int>[36, 73, 100, 36]);
        i = end + 2;
        start = i;
        continue;
      }
    }
    i++;
  }
  result.add(Uint8List.sublistView(bytes, start));
  return result.takeBytes();
}
