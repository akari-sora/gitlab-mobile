import 'dart:collection';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';

final _uploadLimit = isA<ApiFailure>()
    .having((ApiFailure error) => error.kind, 'kind', FailureKind.attachmentTooLarge)
    .having((ApiFailure error) => error.title, 'title', '附件超過 25 MiB 上限')
    .having((ApiFailure error) => error.detail, 'detail', contains('25 MiB'));

void main() {
  test('known oversize rejects before opening the stream', () async {
    var opened = 0;
    await expectLater(
      readLimitedAttachment(
        filename: 'big.bin',
        length: GitLabApi.maxUploadBytes + 1,
        open: () {
          opened++;
          return const Stream<List<int>>.empty();
        },
      ),
      throwsA(_uploadLimit),
    );
    expect(opened, 0);
  });

  test('unknown length aborts the stream past the budget', () async {
    await _expectAbort(null);
  });

  test('understated length aborts the stream past the budget', () async {
    await _expectAbort(1);
  });

  test('unknown length under the budget returns the bytes', () async {
    final picked = await readLimitedAttachment(
      filename: 'note.txt',
      length: null,
      open: () async* {
        yield <int>[1, 2, 3];
      },
    );
    expect(picked.filename, 'note.txt');
    expect(picked.bytes, [1, 2, 3]);
  });

  test('discardPickedCopy deletes a file whose path contains /cache/', () async {
    final root = await _pickedRoot();
    final cached = File('${root.path}/cache/photo.jpg');
    await cached.parent.create(recursive: true);
    await cached.writeAsBytes([1, 2, 3]);
    await discardPickedCopy(cached.path);
    expect(cached.existsSync(), isFalse);
  });

  test('discardPickedCopy keeps a file outside /cache/', () async {
    final root = await _pickedRoot();
    final kept = File('${root.path}/Documents/photo.jpg');
    await kept.parent.create(recursive: true);
    await kept.writeAsBytes([4, 5]);
    await discardPickedCopy(kept.path);
    await discardPickedCopy(null);
    expect(kept.existsSync(), isTrue);
    expect(kept.readAsBytesSync(), [4, 5]);
  });

  test('discardPickedCopy does not throw when the cache file is missing', () async {
    final root = await _pickedRoot();
    await discardPickedCopy('${root.path}/cache/missing.jpg');
  });

  test('discardPickedCopy deletes a file whose path contains /tmp/', () async {
    final root = await _pickedRoot();
    final temporary = File('${root.path}/tmp/photo.jpg');
    await temporary.parent.create(recursive: true);
    await temporary.writeAsBytes([7, 8]);
    await discardPickedCopy(temporary.path);
    expect(temporary.existsSync(), isFalse);
  });

  test('discardPickedCopy deletes a file whose path contains /Library/Caches/', () async {
    final root = await _pickedRoot();
    final cached = File('${root.path}/Library/Caches/photo.jpg');
    await cached.parent.create(recursive: true);
    await cached.writeAsBytes([3]);
    await discardPickedCopy(cached.path);
    expect(cached.existsSync(), isFalse);
  });
}

Future<Directory> _pickedRoot() async {
  // Not under the process temp directory: on Linux that path contains `/tmp/`,
  // which discardPickedCopy treats as an iOS plugin copy.
  final parent = Directory('${Directory.current.path}/build/picked-copy-tests');
  await parent.create(recursive: true);
  final root = await parent.createTemp('picked-');
  addTearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });
  return root;
}

Future<void> _expectAbort(int? length) async {
  var pulls = 0;
  final huge = _UnreadBytes(GitLabApi.maxUploadBytes);
  await expectLater(
    readLimitedAttachment(
      filename: 'big.bin',
      length: length,
      open: () async* {
        pulls++;
        yield <int>[7];
        pulls++;
        yield huge;
        pulls++;
        yield <int>[8];
      },
    ),
    throwsA(_uploadLimit),
  );
  expect(pulls, 2);
  expect(huge.read, isFalse);
}

final class _UnreadBytes extends ListBase<int> {
  _UnreadBytes(this.length);
  @override
  final int length;
  var read = false;
  @override
  set length(int newLength) => throw UnsupportedError('fixed length');
  @override
  int operator [](int index) {
    read = true;
    throw StateError('read');
  }
  @override
  void operator []=(int index, int value) {
    read = true;
    throw StateError('write');
  }
}
