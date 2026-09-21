import 'dart:collection';
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
