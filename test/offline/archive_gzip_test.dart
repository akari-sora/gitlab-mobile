import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/snapshot_worker.dart';
import 'package:gitlab_mobile/core/offline/tar_stream.dart';

Future<List<int>> decode(List<int> bytes, {int chunkSize = 7}) async {
  final out = <int>[];
  final decoder = StrictGzipStream(
    onData: (b) async {
      out.addAll(b);
    },
  );
  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = min(i + chunkSize, bytes.length);
    await decoder.add(bytes.sublist(i, end));
  }
  await decoder.finish();
  return out;
}

void main() {
  test('valid gzip decompresses across every chunk boundary', () async {
    final random = Random(4);
    for (final input in <List<int>>[
      <int>[],
      List<int>.filled(50000, 97),
      List<int>.generate(100000, (_) => random.nextInt(256)),
    ]) {
      final compressed = gzip.encode(input);
      for (final n in <int>[1, 17, 16384]) {
        expect(await decode(compressed, chunkSize: n), input);
      }
    }
  });
  test('rejects corrupt and truncated trailer and member suffix', () async {
    final bytes = gzip.encode(List<int>.filled(8000, 7));
    final badCrc = List<int>.of(bytes)..[bytes.length - 8] ^= 1;
    final badSize = List<int>.of(bytes)..[bytes.length - 4] ^= 1;
    for (final invalid in <List<int>>[
      bytes.sublist(0, bytes.length - 1),
      badCrc,
      badSize,
      <int>[...bytes.sublist(0, bytes.length - 8), ...List<int>.filled(8, 0)],
      <int>[...bytes, 0],
      <int>[...bytes, ...bytes],
    ]) {
      await expectLater(() => decode(invalid), throwsA(isA<TarException>()));
    }
  });
  test(
    'enforces the compressed byte limit before processing beyond it',
    () async {
      final compressed = gzip.encode(List<int>.filled(8192, 7));
      final decoder = StrictGzipStream(
        onData: (_) async {},
        maxCompressedBytes: compressed.length - 1,
      );
      await expectLater(
        () => decoder.add(compressed),
        throwsA(
          isA<TarException>().having(
            (error) => error.failure,
            'failure',
            TarFailure.archiveTooLarge,
          ),
        ),
      );
    },
  );
  test(
    'decodes deterministic deflate variants at awkward boundaries',
    () async {
      final random = Random(9142);
      for (var sample = 0; sample < 24; sample++) {
        final input = List<int>.generate(
          200 + random.nextInt(12000),
          (index) => sample.isEven ? random.nextInt(256) : index % (sample + 1),
        );
        final bytes = GZipCodec(level: sample % 10).encode(input);
        expect(await decode(bytes, chunkSize: 1 + sample * 3), input);
      }
    },
  );
}
