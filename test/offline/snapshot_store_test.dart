import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';

const account = 'https://example.test#1';
const id = '0123456789abcdef0123456789abcdef';
const otherId = 'abcdef0123456789abcdef0123456789';
const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final now = DateTime.utc(2026, 10, 28);
String blobId(List<int> body) => crypto.sha1.convert([
  ...utf8.encode('blob ${body.length}\u0000'),
  ...body,
]).toString();
SnapshotRecord record({
  String snapshotId = id,
  SnapshotStatus status = SnapshotStatus.saving,
}) => SnapshotRecord(
  id: snapshotId,
  projectId: 1,
  projectPath: 'group/project',
  projectName: 'project',
  defaultBranch: 'main',
  refKind: SnapshotRefKind.branch,
  refName: 'main',
  sha: sha,
  objectFormat: SnapshotObjectFormat.sha1,
  subPath: '',
  commitTitle: 'title',
  committedAt: now,
  status: status,
  createdAt: now,
  savedAt: status == SnapshotStatus.complete ? now : null,
);
SnapshotTree tree(
  String snapshotId,
  String blob, {
  SnapshotEntryState state = SnapshotEntryState.pending,
}) => SnapshotTree(
  snapshotId: snapshotId,
  sha: sha,
  subPath: '',
  entries: [
    SnapshotTreeEntry(
      path: 'dir',
      type: SnapshotEntryType.tree,
      mode: '040000',
      id: sha,
      state: SnapshotEntryState.pending,
    ),
    SnapshotTreeEntry(
      path: 'dir/file.txt',
      type: SnapshotEntryType.blob,
      mode: '100644',
      id: blob,
      state: state,
      kind: state == SnapshotEntryState.saved ? SnapshotContentKind.text : null,
      size: state == SnapshotEntryState.saved ? 6 : null,
    ),
  ],
);
SnapshotIndex index(List<SnapshotRecord> records, {bool gc = false}) =>
    SnapshotIndex(
      accountKey: account,
      lastValidatedAt: now,
      consentAt: now,
      gcPending: gc,
      snapshots: records,
    );
bool allow() => true;

void main() {
  late Directory root;
  late SnapshotStore store;
  setUp(() {
    root = Directory.systemTemp.createTempSync('snapshot-store-');
    store = SnapshotStore(
      supportRoot: root,
      accountKey: account,
      rootKey: List<int>.generate(32, (i) => i),
    );
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('HKDF uses the specified salt and separate info values', () async {
    final keys = await store.workerKeys;
    String hex(List<int> bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(
      hex(keys.data),
      'c06f96c12f9420743d90879412a62cfa5c4e9097871beb493a0ce3bbc813100f',
    );
    expect(
      hex(keys.names),
      '07af911e8b8c6d57058a93cc92f5e15d55047f1c4353406177eb3237c78016a8',
    );
  });

  test(
    'ciphertext, readback, fresh nonce, AAD and blob reuse/repair',
    () async {
      final body = utf8.encode('hello\n');
      final hash = blobId(body);
      expect(
        await store.writeBlob(
          SnapshotObjectFormat.sha1,
          hash,
          body,
          mayCommit: allow,
        ),
        isFalse,
      );
      expect(await store.readBlob(SnapshotObjectFormat.sha1, hash), body);
      final blobName = await store.blobFileName(
        SnapshotObjectFormat.sha1,
        hash,
      );
      final blobFile = File('${store.accountDirectory}/$blobName');
      final first = blobFile.readAsBytesSync();
      expect(first.length, body.length + snapshotEnvelopeOverhead);
      expect(
        utf8.decode(first, allowMalformed: true),
        isNot(contains('hello')),
      );
      expect(
        await store.writeBlob(
          SnapshotObjectFormat.sha1,
          hash,
          body,
          mayCommit: allow,
        ),
        isTrue,
      );
      expect(blobFile.readAsBytesSync(), first);
      first[first.length - 1] ^= 1;
      blobFile.writeAsBytesSync(first);
      expect(
        await store.writeBlob(
          SnapshotObjectFormat.sha1,
          hash,
          body,
          mayCommit: allow,
        ),
        isFalse,
      );
      expect(await store.readBlob(SnapshotObjectFormat.sha1, hash), body);
      expect(blobFile.readAsBytesSync(), isNot(first));
      await store.writeTree(
        tree(id, hash),
        format: SnapshotObjectFormat.sha1,
        complete: false,
        mayCommit: allow,
      );
      final t = File(
        '${store.accountDirectory}/${SnapshotStore.treeFileName(id)}',
      );
      t.writeAsBytesSync(blobFile.readAsBytesSync());
      expect(
        () => store.readTree(record()),
        throwsA(isA<SnapshotStoreException>()),
      );
    },
  );

  test(
    'index CAS and revocation guard preserve prior committed data',
    () async {
      await store.writeIndex(
        index([record()]),
        expectedRevision: 0,
        mayCommit: allow,
      );
      final revision = store.revision;
      final before = File(
        '${store.accountDirectory}/index.v1.bin',
      ).readAsBytesSync();
      await expectLater(
        store.writeIndex(
          index([]),
          expectedRevision: revision - 1,
          mayCommit: allow,
        ),
        throwsA(
          isA<SnapshotStoreException>().having(
            (e) => e.code,
            'code',
            SnapshotStoreError.revisionConflict,
          ),
        ),
      );
      await expectLater(
        store.writeIndex(
          index([]),
          expectedRevision: revision,
          mayCommit: () => false,
        ),
        throwsA(
          isA<SnapshotStoreException>().having(
            (e) => e.code,
            'code',
            SnapshotStoreError.revoked,
          ),
        ),
      );
      expect((await store.readIndex())!.snapshots.single.id, id);
      expect(
        File('${store.accountDirectory}/index.v1.bin').readAsBytesSync(),
        before,
      );
    },
  );

  test(
    'pending roots keep blobs during GC, orphan blobs are removed',
    () async {
      final data = utf8.encode('hello\n');
      final hash = blobId(data);
      final orphan = utf8.encode('orphan');
      final orphanHash = blobId(orphan);
      await store.writeBlob(
        SnapshotObjectFormat.sha1,
        hash,
        data,
        mayCommit: allow,
      );
      await store.writeBlob(
        SnapshotObjectFormat.sha1,
        orphanHash,
        orphan,
        mayCommit: allow,
      );
      await store.writeTree(
        tree(id, hash),
        format: SnapshotObjectFormat.sha1,
        complete: false,
        mayCommit: allow,
      );
      final original = index([record()], gc: true);
      await store.writeIndex(original, expectedRevision: 0, mayCommit: allow);
      final recovered = await store.recover(
        now: now,
        workersRunning: false,
        mayCommit: allow,
      );
      expect(recovered!.snapshots.single.status, SnapshotStatus.paused);
      expect(recovered.snapshots.single.interrupted, isTrue);
      expect(recovered.gcPending, isFalse);
      expect(await store.readBlob(SnapshotObjectFormat.sha1, hash), data);
      expect(
        await store.readBlob(SnapshotObjectFormat.sha1, orphanHash),
        isNull,
      );
    },
  );

  test(
    'tree validates ids, types, parent, duplicate, scope and complete pending',
    () {
      final valid = tree(id, blobId(utf8.encode('hello\n')));
      expect(
        () => valid.encode(format: SnapshotObjectFormat.sha1),
        returnsNormally,
      );
      expect(
        () => valid.encode(format: SnapshotObjectFormat.sha1, complete: true),
        throwsA(isA<SnapshotSchemaException>()),
      );
      for (final bad in [
        SnapshotTreeEntry(
          path: '../x',
          type: SnapshotEntryType.blob,
          mode: '100644',
          id: sha,
          state: SnapshotEntryState.pending,
        ),
        SnapshotTreeEntry(
          path: 'x',
          type: SnapshotEntryType.blob,
          mode: '040000',
          id: sha,
          state: SnapshotEntryState.pending,
        ),
        SnapshotTreeEntry(
          path: 'dir/missing',
          type: SnapshotEntryType.blob,
          mode: '100644',
          id: sha,
          state: SnapshotEntryState.pending,
        ),
        SnapshotTreeEntry(
          path: 'x',
          type: SnapshotEntryType.blob,
          mode: '100644',
          id: 'bad',
          state: SnapshotEntryState.pending,
        ),
      ]) {
        final invalid = SnapshotTree(
          snapshotId: id,
          sha: sha,
          subPath: '',
          entries: [bad],
        );
        expect(
          () => invalid.encode(format: SnapshotObjectFormat.sha1),
          throwsA(isA<SnapshotSchemaException>()),
        );
      }
      final duplicate = SnapshotTree(
        snapshotId: id,
        sha: sha,
        subPath: '',
        entries: [valid.entries.first, valid.entries.first],
      );
      expect(
        () => duplicate.encode(format: SnapshotObjectFormat.sha1),
        throwsA(isA<SnapshotSchemaException>()),
      );
    },
  );

  test(
    'newer schema is preserved and rejected before ordinary recovery',
    () async {
      final json = index([record()]).toJson()..['schema'] = 2;
      expect(
        () => SnapshotIndex.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
          accountKey: account,
        ),
        throwsA(
          isA<SnapshotSchemaException>().having(
            (e) => e.code,
            'code',
            SnapshotSchemaError.newerSchema,
          ),
        ),
      );
    },
  );

  test('recovery preserves an authenticated newer index', () async {
    await store.writeIndex(
      index([record()]),
      expectedRevision: 0,
      mayCommit: allow,
    );
    final newer = index([record()]).toJson()..['schema'] = 2;
    final keys = await store.workerKeys;
    const name = 'index.v1.bin';
    final box = await DartAesGcm(secretKeyLength: 32).encrypt(
      utf8.encode(jsonEncode(newer)),
      secretKey: SecretKey(keys.data),
      nonce: List<int>.filled(12, 7),
      aad: utf8.encode(jsonEncode(['offline_repo', 1, account, name])),
    );
    final envelope = <int>[1, ...box.concatenation()];
    final file = File('${store.accountDirectory}/$name')
      ..writeAsBytesSync(envelope);
    await expectLater(
      store.recover(now: now, workersRunning: false, mayCommit: allow),
      throwsA(
        isA<SnapshotSchemaException>().having(
          (e) => e.code,
          'code',
          SnapshotSchemaError.newerSchema,
        ),
      ),
    );
    expect(file.readAsBytesSync(), envelope);
  });

  test('newer tree blocks recovery before any temp or tree deletion', () async {
    final hash = blobId(utf8.encode('hello\n'));
    await store.writeTree(
      tree(id, hash),
      format: SnapshotObjectFormat.sha1,
      complete: false,
      mayCommit: allow,
    );
    await store.writeTree(
      tree(otherId, hash),
      format: SnapshotObjectFormat.sha1,
      complete: false,
      mayCommit: allow,
    );
    await store.writeIndex(
      index([
        record(status: SnapshotStatus.superseded),
        record(snapshotId: otherId),
      ]),
      expectedRevision: 0,
      mayCommit: allow,
    );
    final futureFile = File(
      '${store.accountDirectory}/${SnapshotStore.treeFileName(otherId)}',
    );
    final futureBytes = futureFile.readAsBytesSync()..[0] = 2;
    futureFile.writeAsBytesSync(futureBytes);
    final job = Directory('${store.accountDirectory}/tmp/$id')
      ..createSync(recursive: true);
    File('${job.path}/data').writeAsBytesSync([1]);
    await expectLater(
      store.recover(now: now, workersRunning: false, mayCommit: allow),
      throwsA(
        isA<SnapshotStoreException>().having(
          (e) => e.code,
          'code',
          SnapshotStoreError.newerSchema,
        ),
      ),
    );
    expect(job.existsSync(), isTrue);
    expect(
      File(
        '${store.accountDirectory}/${SnapshotStore.treeFileName(id)}',
      ).existsSync(),
      isTrue,
    );
  });

  test(
    'complete index cannot commit without final tree and saved blobs',
    () async {
      final body = utf8.encode('hello\n');
      final hash = blobId(body);
      final complete = record(status: SnapshotStatus.complete);
      await store.writeIndex(
        index([record()]),
        expectedRevision: 0,
        mayCommit: allow,
      );
      await expectLater(
        store.writeIndex(
          index([complete]),
          expectedRevision: 1,
          mayCommit: allow,
        ),
        throwsA(isA<SnapshotStoreException>()),
      );
      final raw = tree(id, hash, state: SnapshotEntryState.saved);
      final finalTree = SnapshotTree(
        snapshotId: id,
        sha: sha,
        subPath: '',
        entries: [
          raw.entries[0].copyWith(state: SnapshotEntryState.saved),
          raw.entries[1],
        ],
      );
      await store.writeTree(
        finalTree,
        format: SnapshotObjectFormat.sha1,
        complete: true,
        mayCommit: allow,
      );
      await expectLater(
        store.writeIndex(
          index([complete]),
          expectedRevision: 1,
          mayCommit: allow,
        ),
        throwsA(isA<SnapshotStoreException>()),
      );
      await store.writeBlob(
        SnapshotObjectFormat.sha1,
        hash,
        body,
        mayCommit: allow,
      );
      await store.writeIndex(
        index([complete]),
        expectedRevision: 1,
        mayCommit: allow,
      );
      expect(
        (await store.readIndex())!.snapshots.single.status,
        SnapshotStatus.complete,
      );
    },
  );

  test(
    'interruption before rename keeps prior index and cleans temp',
    () async {
      var fail = false;
      final faultStore = SnapshotStore(
        supportRoot: root,
        accountKey: account,
        rootKey: List<int>.generate(32, (i) => i),
        checkpoint: (point) {
          if (fail && point == SnapshotStoreCheckpoint.beforeRename) {
            throw StateError('injected');
          }
        },
      );
      await faultStore.writeIndex(
        index([record()]),
        expectedRevision: 0,
        mayCommit: allow,
      );
      fail = true;
      await expectLater(
        faultStore.writeIndex(index([]), expectedRevision: 1, mayCommit: allow),
        throwsA(isA<StateError>()),
      );
      expect((await faultStore.readIndex())!.snapshots.single.id, id);
      final temp = Directory('${faultStore.accountDirectory}/tmp');
      expect(temp.listSync(), isEmpty);
    },
  );

  test(
    'recovery removes abandoned ciphertext temporaries only with no worker',
    () async {
      await store.writeIndex(index([]), expectedRevision: 0, mayCommit: allow);
      final job = Directory('${store.accountDirectory}/tmp/$otherId')
        ..createSync(recursive: true);
      File('${job.path}/data').writeAsBytesSync([1, 2, 3]);
      await store.recover(now: now, workersRunning: true, mayCommit: allow);
      expect(job.existsSync(), isTrue);
      await store.recover(now: now, workersRunning: false, mayCommit: allow);
      expect(job.existsSync(), isFalse);
    },
  );

  test('a symlinked namespace cannot write through to the target', () async {
    final target = Directory('${root.path}/outside')..createSync();
    Link('${root.path}/offline_repo').createSync(target.path);
    await expectLater(
      store.writeIndex(index([]), expectedRevision: 0, mayCommit: allow),
      throwsA(
        isA<SnapshotStoreException>().having(
          (e) => e.code,
          'code',
          SnapshotStoreError.untrustedPath,
        ),
      ),
    );
    expect(target.listSync(), isEmpty);
  });
}
