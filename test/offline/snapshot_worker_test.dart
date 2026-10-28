import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/git_object_id.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/offline/snapshot_worker.dart';

import 'archive_tar_test.dart' as fixture;

const format = SnapshotObjectFormat.sha1;
SnapshotTree tree(List<SnapshotTreeEntry> entries) => SnapshotTree(
  snapshotId: 'a' * 32,
  sha: 'b' * 40,
  subPath: '',
  entries: entries,
);
SnapshotTreeEntry blob(
  String path,
  List<int> bytes, {
  String mode = '100644',
}) => SnapshotTreeEntry(
  path: path,
  type: SnapshotEntryType.blob,
  mode: mode,
  id: gitBlobId(bytes, 'sha1'),
  state: SnapshotEntryState.pending,
);

void main() {
  late Directory dir;
  late SnapshotStore store;
  setUp(() {
    Directory('.dart_tool/c3a/archive').createSync(recursive: true);
    dir = Directory('.dart_tool/c3a/archive').createTempSync('worker.');
    store = SnapshotStore(
      supportRoot: dir,
      accountKey: 'https://example.test#1',
      rootKey: List<int>.filled(32, 3),
    );
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test(
    'isolate verifies and encrypts blob, reports missing and reuses valid content',
    () async {
      final hello = utf8.encode('hello\n');
      final inputTree = tree(<SnapshotTreeEntry>[
        SnapshotTreeEntry(
          path: 'docs',
          type: SnapshotEntryType.tree,
          mode: '040000',
          id: 'c' * 40,
          state: SnapshotEntryState.pending,
        ),
        blob('docs/hello.txt', hello),
        blob('docs/missing.txt', <int>[1]),
        blob('docs/link', utf8.encode('hello.txt'), mode: '120000'),
      ]);
      final archive = File(
        'test/fixtures/offline/synthetic.tar.gz',
      ).readAsBytesSync();
      for (var pass = 0; pass < 2; pass++) {
        final worker = await SnapshotWorker.start(
          store: store,
          tree: inputTree,
          format: format,
          jobEpoch: pass,
        );
        final result = await worker.run(Stream<Uint8List>.value(archive));
        final byPath = <String, SnapshotTreeEntry>{
          for (final e in result.tree.entries) e.path: e,
        };
        expect(byPath['docs']!.state, SnapshotEntryState.saved);
        expect(byPath['docs/hello.txt']!.state, SnapshotEntryState.saved);
        expect(byPath['docs/hello.txt']!.kind, SnapshotContentKind.text);
        expect(byPath['docs/missing.txt']!.state, SnapshotEntryState.missing);
        expect(byPath['docs/link']!.state, SnapshotEntryState.symlink);
        expect(result.reused, pass);
        expect(await store.readBlob(format, gitBlobId(hello, 'sha1')), hello);
      }
    },
  );

  test('malformed trailer fails before publication', () async {
    final inputTree = tree(<SnapshotTreeEntry>[
      blob('hello.txt', utf8.encode('hello\n')),
    ]);
    final archive = File(
      'test/fixtures/offline/synthetic.tar.gz',
    ).readAsBytesSync();
    archive[archive.length - 4] ^= 1;
    final worker = await SnapshotWorker.start(
      store: store,
      tree: inputTree,
      format: format,
      jobEpoch: 1,
    );
    await expectLater(
      () => worker.run(Stream<Uint8List>.value(archive)),
      throwsA(
        isA<SnapshotWorkerException>().having(
          (e) => e.failure,
          'failure',
          SnapshotFailure.corruptArchive,
        ),
      ),
    );
    expect(
      File('${store.accountDirectory}/index.v1.bin').existsSync(),
      isFalse,
    );
  });

  test('reused blob is classified from each current path and mode', () async {
    final bytes = utf8.encode('same bytes\n');
    final paths = <String>['readme.txt', 'picture.png', 'link.png'];
    final modes = <String>['100644', '100644', '120000'];
    final expected = <SnapshotEntryState>[
      SnapshotEntryState.saved,
      SnapshotEntryState.saved,
      SnapshotEntryState.mismatch,
    ];
    for (var i = 0; i < paths.length; i++) {
      final worker = await SnapshotWorker.start(
        store: store,
        tree: tree(<SnapshotTreeEntry>[blob(paths[i], bytes, mode: modes[i])]),
        format: format,
        jobEpoch: i,
      );
      final archive = Uint8List.fromList(
        gzip.encode(
          fixture.archive(fixture.item('wrapper/${paths[i]}', bytes)),
        ),
      );
      final result = await worker.run(Stream<Uint8List>.value(archive));
      expect(result.tree.entries.single.state, expected[i]);
      if (i == 0) {
        expect(result.tree.entries.single.kind, SnapshotContentKind.text);
      } else if (i == 1) {
        expect(result.tree.entries.single.kind, SnapshotContentKind.image);
        expect(result.reused, 1);
      }
    }
  });

  test(
    'credits bound bytes in flight on an incompressible multi-chunk archive',
    () async {
      final random = Random(42);
      final data = Uint8List.fromList(
        List<int>.generate(2 * 1024 * 1024, (_) => random.nextInt(256)),
      );
      final bytes = Uint8List.fromList(
        gzip.encode(fixture.archive(fixture.item('wrapper/image.png', data))),
      );
      final worker = await SnapshotWorker.start(
        store: store,
        tree: tree(<SnapshotTreeEntry>[blob('image.png', data)]),
        format: format,
        jobEpoch: 1,
      );
      var peak = 0;
      final result = await worker.run(
        Stream<Uint8List>.value(bytes),
        onProgress: (p) => peak = max(peak, p.inFlightBytes),
      );
      expect(result.tree.entries.single.kind, SnapshotContentKind.image);
      expect(peak, lessThanOrEqualTo(1024 * 1024));
      expect(peak, greaterThan(0));
    },
  );

  test('idle timeout and stop wait for isolate termination', () async {
    final controller = StreamController<Uint8List>();
    final worker = await SnapshotWorker.start(
      store: store,
      tree: tree(<SnapshotTreeEntry>[]),
      format: format,
      jobEpoch: 1,
      idleTimeout: const Duration(milliseconds: 40),
    );
    await expectLater(
      () => worker.run(controller.stream),
      throwsA(
        isA<SnapshotWorkerException>().having(
          (e) => e.failure,
          'failure',
          SnapshotFailure.network,
        ),
      ),
    );
    await controller.close();

    final other = StreamController<Uint8List>();
    final stopped = await SnapshotWorker.start(
      store: store,
      tree: tree(<SnapshotTreeEntry>[]),
      format: format,
      jobEpoch: 2,
    );
    final run = stopped.run(other.stream);
    final expectation = expectLater(
      run,
      throwsA(isA<SnapshotWorkerException>()),
    );
    await Future<void>.delayed(Duration.zero);
    await stopped.stop();
    await expectation;
    await other.close();
  });
}
