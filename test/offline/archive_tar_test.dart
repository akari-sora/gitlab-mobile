import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/snapshot_worker.dart';
import 'package:gitlab_mobile/core/offline/tar_stream.dart';

List<int> tarHeader(List<int> name, int size, int type, {int? signedByte}) {
  final h = Uint8List(512);
  h.setRange(0, min(name.length, 100), name);
  void oct(int at, int width, int value) {
    final data = ascii.encode(value.toRadixString(8).padLeft(width - 1, '0'));
    h.setRange(at, at + data.length, data);
  }

  oct(100, 8, 420);
  oct(108, 8, 0);
  oct(116, 8, 0);
  oct(124, 12, size);
  oct(136, 12, 0);
  h.fillRange(148, 156, 32);
  h[156] = type;
  if (signedByte != null) h[300] = signedByte;
  final checksum = h.fold<int>(
    0,
    (a, b) =>
        a +
        (signedByte == null
            ? b
            : b >= 128
            ? b - 256
            : b),
  );
  oct(148, 8, checksum);
  return h;
}

List<int> item(String path, List<int> data, {int type = 48, int? headerSize}) =>
    <int>[
      ...tarHeader(utf8.encode(path), headerSize ?? data.length, type),
      ...data,
      ...List<int>.filled((512 - data.length % 512) % 512, 0),
    ];
String pax(String key, String value) {
  final tail = ' $key=$value\n';
  var length = tail.length + 1;
  while (length != tail.length + '$length'.length) {
    length = tail.length + '$length'.length;
  }
  return '$length$tail';
}

List<int> archive(List<int> body) => <int>[
  ...body,
  ...List<int>.filled(1024, 0),
];

Future<List<(TarEntry, Uint8List?)>> parse(
  List<int> bytes, {
  int split = 31,
  int max = 1 << 30,
  String expectedSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) async {
  final result = <(TarEntry, Uint8List?)>[];
  final p = TarStreamParser(
    expectedSha: expectedSha,
    maxExpandedBytes: max,
    retainLimit: (_) => 10 * 1024 * 1024,
    onEntry: (entry, data) {
      result.add((entry, data));
    },
  );
  for (var i = 0; i < bytes.length; i += split) {
    await p.add(bytes.sublist(i, min(i + split, bytes.length)));
  }
  p.finish();
  return result;
}

Future<List<(TarEntry, Uint8List?)>> parseGzip(
  List<int> bytes, {
  String expectedSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) async {
  final data = BytesBuilder(copy: false);
  final decoder = StrictGzipStream(
    onData: (bytes) async {
      data.add(bytes);
    },
  );
  await decoder.add(bytes);
  await decoder.finish();
  return parse(data.takeBytes(), expectedSha: expectedSha);
}

void main() {
  test('real git archive contains long paths, symlink and gitlink', () async {
    final out = await parseGzip(
      File('test/fixtures/offline/synthetic.tar.gz').readAsBytesSync(),
    );
    final paths = out.map((v) => v.$1.path).toSet();
    expect(
      paths,
      containsAll(<String>['docs', 'docs/hello.txt', 'docs/link', 'submodule']),
    );
    expect(paths.any((p) => p != null && p.length > 150), isTrue);
    expect(paths, isNot(contains('docs/ignored.txt')));
    expect(
      out.singleWhere((v) => v.$1.path == 'docs/link').$1.type,
      TarEntryType.symlink,
    );
    expect(
      out.singleWhere((v) => v.$1.path == 'submodule').$1.type,
      TarEntryType.directory,
    );
    final docs = await parseGzip(
      File('test/fixtures/offline/synthetic-docs.tar.gz').readAsBytesSync(),
    );
    expect(docs.map((v) => v.$1.path), contains('docs'));
  });
  test(
    'real commit archive validates its pax comment and long pax path',
    () async {
      const sha = 'e0847749dc566a66dea5794715dd16cfe9f39612';
      final bytes = File(
        'test/fixtures/offline/synthetic-commit.tar.gz',
      ).readAsBytesSync();
      final out = await parseGzip(bytes, expectedSha: sha);
      expect(
        out.any(
          (entry) =>
              entry.$1.path?.length != null && entry.$1.path!.length > 300,
        ),
        isTrue,
      );
      expect(out.any((entry) => entry.$1.path == 'docs/ignored.txt'), isFalse);
      final substituted = out.singleWhere(
        (entry) => entry.$1.path == 'docs/subst.txt',
      );
      expect(utf8.decode(substituted.$2!), contains(sha));
      await expectLater(
        () => parseGzip(bytes, expectedSha: 'a' * 40),
        throwsA(
          isA<TarException>().having(
            (e) => e.failure,
            'kind',
            TarFailure.shaMismatch,
          ),
        ),
      );
    },
  );
  test(
    'pax size changes framing, metadata applies once, unknown types skip actual size',
    () async {
      final body = <int>[
        ...item('metadata', utf8.encode(pax('size', '3')), type: 120),
        ...item('wrapper/a', utf8.encode('one'), headerSize: 1),
        ...item('metadata', utf8.encode('wrapper/long\u0000'), type: 76),
        ...item('wrapper/short', utf8.encode('two')),
        ...item('wrapper/other', utf8.encode('skip'), type: 51),
        ...item('wrapper/z', utf8.encode('z')),
      ];
      final out = await parse(archive(body));
      expect(out.map((v) => v.$1.path), <String?>['a', 'long', 'other', 'z']);
      expect(utf8.decode(out.first.$2!), 'one');
      expect(out[2].$1.type, TarEntryType.unsupported);
      expect(utf8.decode(out.last.$2!), 'z');
    },
  );
  test('later local metadata replaces earlier metadata', () async {
    final out = await parse(
      archive(<int>[
        ...item('p1', utf8.encode(pax('path', 'wrapper/first')), type: 120),
        ...item('p2', utf8.encode(pax('path', 'wrapper/second')), type: 120),
        ...item('wrapper/x', <int>[1]),
        ...item('wrapper/next', <int>[2]),
      ]),
    );
    expect(out.map((v) => v.$1.path), <String?>['second', 'next']);
  });
  test(
    'GNU long link is skipped once and all unsupported types use their size',
    () async {
      final body = <int>[
        ...item('longlink', utf8.encode('target\u0000'), type: 75),
        for (final flag in <int>[49, 51, 52, 54, 55])
          ...item('wrapper/type$flag', <int>[1, 2, 3], type: flag),
        ...item('wrapper/after', <int>[4]),
      ];
      final out = await parse(archive(body));
      expect(
        out.take(5).every((entry) => entry.$1.type == TarEntryType.unsupported),
        isTrue,
      );
      expect(out.last.$1.path, 'after');
      expect(out.last.$2, <int>[4]);
    },
  );
  test('global commit comment rejects a different valid SHA', () async {
    final bytes = archive(<int>[
      ...item('global', utf8.encode(pax('comment', 'b' * 40)), type: 103),
      ...item('wrapper/file', <int>[1]),
    ]);
    await expectLater(
      () => parse(bytes),
      throwsA(
        isA<TarException>().having(
          (e) => e.failure,
          'kind',
          TarFailure.shaMismatch,
        ),
      ),
    );
  });
  test(
    'rejects unsafe paths, duplicates, trailing bytes, truncation and bad checksum',
    () async {
      final badChecksum = archive(item('wrapper/a', <int>[1]));
      badChecksum[0] ^= 1;
      final badNumber = tarHeader(utf8.encode('wrapper/a'), 0, 48)
        ..[124] = 0x80;
      final invalid = <List<int>>[
        archive(item('wrapper/../escape', <int>[1])),
        archive(item('/absolute', <int>[1])),
        archive(item('wrapper/a//b', <int>[1])),
        archive(<int>[
          ...item('wrapper/a', <int>[1]),
          ...item('wrapper/a', <int>[2]),
        ]),
        <int>[
          ...archive(item('wrapper/a', <int>[1])),
          1,
        ],
        item('wrapper/a', <int>[1]),
        archive(badNumber),
        badChecksum,
      ];
      for (final bytes in invalid) {
        await expectLater(() => parse(bytes), throwsA(isA<TarException>()));
      }
      final backslash = await parse(archive(item(r'wrapper/a\b', <int>[1])));
      expect(backslash.single.$1.path, r'a\b');
    },
  );
  test('invalid UTF-8 names are unmatched rather than fatal', () async {
    final header = tarHeader(<int>[...ascii.encode('wrapper/'), 255], 1, 48);
    final out = await parse(
      archive(<int>[...header, 1, ...List<int>.filled(511, 0)]),
    );
    expect(out.single.$1.path, isNull);
  });
  test('bounds and malformed pax fail before payload allocation', () async {
    for (final body in <List<int>>[
      item('pax', utf8.encode('9 bad=x\n'), type: 120),
      tarHeader(ascii.encode('pax'), 65537, 120),
      tarHeader(ascii.encode('gnu'), 4098, 76),
      item('pax', utf8.encode(pax('size', '1099511627777')), type: 120),
    ]) {
      await expectLater(
        () => parse(archive(body)),
        throwsA(isA<TarException>()),
      );
    }
    await expectLater(
      () => parse(archive(item('wrapper/a', <int>[1])), max: 100),
      throwsA(
        isA<TarException>().having(
          (e) => e.failure,
          'kind',
          TarFailure.archiveTooLarge,
        ),
      ),
    );
  });
  test('signed checksum accepted', () async {
    final signed = tarHeader(ascii.encode('wrapper/s'), 0, 48, signedByte: 255);
    final out = await parse(archive(signed));
    expect(out.single.$1.path, 's');
  });
}
