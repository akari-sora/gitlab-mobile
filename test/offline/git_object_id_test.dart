import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/git_object_id.dart';

ArchiveBlobResult check(
  String path,
  String mode,
  List<int> bytes, {
  String? id,
}) => verifyArchiveBlob(
  path: path,
  mode: mode,
  objectFormat: 'sha1',
  id: id ?? gitBlobId(bytes, 'sha1'),
  size: bytes.length,
  bytes: Uint8List.fromList(bytes),
);

void main() {
  test('Git SHA-1 and SHA-256 known vectors', () {
    expect(
      gitBlobId(<int>[], 'sha1'),
      'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391',
    );
    expect(
      gitBlobId(utf8.encode('hello\n'), 'sha1'),
      'ce013625030ba8dba906f756967f9e9ca394464a',
    );
    expect(
      gitBlobId(utf8.encode('hello\n'), 'sha256'),
      '2cf8d83d9ee29543b34a87727421fdecb7e3f3a183d337639025de576db9ebb4',
    );
  });
  test('accepts only normalization verified against tree blob ID', () {
    final original = utf8.encode('hello\n\$Id\$\n');
    final transformed = utf8.encode('hello\r\n\$Id: ${'a' * 40} \$\r\n');
    final result = check(
      'x.txt',
      '100644',
      transformed,
      id: gitBlobId(original, 'sha1'),
    );
    expect(result.state, ArchiveBlobState.saved);
    expect(result.bytes, original);
    expect(
      check('x.txt', '100644', transformed, id: 'a' * 40).state,
      ArchiveBlobState.mismatch,
    );
  });
  test('normalizes bytes before classifying invalid UTF-8 as binary', () {
    final original = <int>[255, ...utf8.encode('\n\$Id\$\n')];
    final transformed = <int>[
      255,
      ...utf8.encode('\r\n\$Id: ${'a' * 40} \$\r\n'),
    ];
    final result = check(
      'x.txt',
      '100644',
      transformed,
      id: gitBlobId(original, 'sha1'),
    );
    expect(result.state, ArchiveBlobState.binary);
  });
  test('content classification, bounds and mode are recomputed', () {
    expect(
      check('x.txt', '100644', utf8.encode('x\n' * 20000)).state,
      ArchiveBlobState.saved,
    );
    expect(
      check('x.txt', '100644', utf8.encode('x\n' * 20001)).state,
      ArchiveBlobState.binary,
    );
    expect(check('x.txt', '100644', <int>[0]).state, ArchiveBlobState.binary);
    expect(check('x.txt', '100644', <int>[255]).state, ArchiveBlobState.binary);
    expect(
      check(
        'x.txt',
        '100644',
        utf8.encode('version https://git-lfs.github.com/spec/v1\n'),
      ).kind,
      ArchiveBlobKind.lfsPointer,
    );
    expect(check('x.jpg', '120000', <int>[1]).state, ArchiveBlobState.symlink);
    expect(check('x.jpg', '100644', <int>[255]).kind, ArchiveBlobKind.image);
    expect(
      check(
        'x.txt',
        '100644',
        List<int>.filled(maxSnapshotTextBytes, 97),
      ).state,
      ArchiveBlobState.saved,
    );
    final tooBig = verifyArchiveBlob(
      path: 'x.txt',
      mode: '100644',
      id: 'a' * 40,
      objectFormat: 'sha1',
      size: maxSnapshotTextBytes + 1,
      bytes: null,
    );
    expect(tooBig.state, ArchiveBlobState.tooLarge);
    expect(
      check(
        'x.jpg',
        '100644',
        List<int>.filled(maxSnapshotImageBytes, 0),
      ).state,
      ArchiveBlobState.saved,
    );
    expect(
      verifyArchiveBlob(
        path: 'x.jpg',
        mode: '100644',
        id: 'a' * 40,
        objectFormat: 'sha1',
        size: maxSnapshotImageBytes + 1,
        bytes: null,
      ).state,
      ArchiveBlobState.tooLarge,
    );
  });
}
