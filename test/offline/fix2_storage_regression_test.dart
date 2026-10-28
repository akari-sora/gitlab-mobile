import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';

import 'coordinator_regression_test.dart' as support;
import 'snapshot_save_test.dart' show SaveHarness;
import 'snapshot_store_test.dart' as fixtures;

void main() {
  test('missing B blob permits A revocation, C read, and B re-save', () async {
    final h = SaveHarness();
    addTearDown(h.dispose);
    final a = await h.run(h.queue.enqueue(h.request(projectId: 1)));
    final c = await h.run(h.queue.enqueue(h.request(projectId: 3)));
    expect(a, isNotNull);
    expect(c, isNotNull);

    final body = utf8.encode('damaged B contents');
    final blob = crypto.sha1.convert([
      ...utf8.encode('blob ${body.length}\u0000'),
      ...body,
    ]).toString();
    final b = support.completeRecord(2, support.otherId, h.now);
    final permit = h.coordinator.capture(support.binding, 0);
    late String blobPath;
    await h.coordinator.maintain<void>(permit, (store, index) async {
      await store.writeBlob(b.objectFormat, blob, body, mayCommit: () => true);
      await store.writeTree(
        SnapshotTree(
          snapshotId: b.id,
          sha: b.sha,
          subPath: b.subPath,
          entries: [
            SnapshotTreeEntry(
              path: 'file.txt',
              type: SnapshotEntryType.blob,
              mode: '100644',
              id: blob,
              state: SnapshotEntryState.saved,
              kind: SnapshotContentKind.text,
              size: body.length,
            ),
          ],
        ),
        format: b.objectFormat,
        complete: true,
        mayCommit: () => true,
      );
      await store.writeIndex(
        index!.copyWith(snapshots: [...index.snapshots, b]),
        expectedRevision: store.revision,
        mayCommit: () => true,
      );
      blobPath =
          '${store.accountDirectory}/${await store.blobFileName(b.objectFormat, blob)}';
    });
    File(blobPath).deleteSync();
    await expectLater(
      h.reader(b).text('file.txt'),
      throwsA(isA<SnapshotOperationException>()),
    );

    // A probe update is metadata, but a changed publication must still be
    // rejected while its referenced blob is absent.
    await h.coordinator.maintain<void>(permit, (store, index) async {
      await store.writeIndex(
        index!.copyWith(
          snapshots: [
            for (final record in index.snapshots)
              if (record.id == b.id)
                record.copyWith(probe: SnapshotProbe.ok, probedAt: h.now)
              else
                record,
          ],
        ),
        expectedRevision: store.revision,
        mayCommit: () => true,
      );
    });
    await expectLater(
      h.coordinator.maintain<void>(permit, (store, index) async {
        await store.writeIndex(
          index!.copyWith(
            snapshots: [
              for (final record in index.snapshots)
                if (record.id == b.id)
                  record.copyWith(
                    savedAt: h.now.add(const Duration(seconds: 1)),
                  )
                else
                  record,
            ],
          ),
          expectedRevision: store.revision,
          mayCommit: () => true,
        );
      }),
      throwsA(isA<SnapshotStoreException>()),
    );

    await h.coordinator.permissionRemoval(support.binding, 1);
    final afterRemoval = await h.coordinator.snapshots(support.binding);
    expect(afterRemoval.map((record) => record.id), containsAll([b.id, c!.id]));
    expect(afterRemoval.map((record) => record.id), isNot(contains(a!.id)));
    expect(await h.reader(c).text('docs/hello.txt'), 'hello\n');

    final repair = h.queue.enqueue(h.request(projectId: 2, replaces: b.id));
    final repaired = await h.run(repair);
    expect(repaired, isNotNull, reason: '${repair.phase}: ${repair.failure}');
    expect(await h.reader(repaired!).text('docs/hello.txt'), 'hello\n');
    expect(await h.reader(c).text('docs/hello.txt'), 'hello\n');
  });

  test(
    'a new complete snapshot with a missing blob cannot be published',
    () async {
      final root = Directory.systemTemp.createTempSync('fix2-publication-');
      addTearDown(() => root.deleteSync(recursive: true));
      final store = SnapshotStore(
        supportRoot: root,
        accountKey: fixtures.account,
        rootKey: List<int>.filled(32, 9),
      );
      final body = utf8.encode('hello\n');
      final hash = fixtures.blobId(body);
      final pending = fixtures.record();
      await store.writeIndex(
        fixtures.index([pending]),
        expectedRevision: store.revision,
        mayCommit: fixtures.allow,
      );
      final tree = fixtures.tree(
        fixtures.id,
        hash,
        state: SnapshotEntryState.saved,
      );
      final completeTree = SnapshotTree(
        snapshotId: fixtures.id,
        sha: fixtures.sha,
        subPath: '',
        entries: [
          tree.entries[0].copyWith(state: SnapshotEntryState.saved),
          tree.entries[1],
        ],
      );
      await store.writeTree(
        completeTree,
        format: SnapshotObjectFormat.sha1,
        complete: true,
        mayCommit: fixtures.allow,
      );
      await expectLater(
        store.writeIndex(
          fixtures.index([fixtures.record(status: SnapshotStatus.complete)]),
          expectedRevision: store.revision,
          mayCommit: fixtures.allow,
        ),
        throwsA(isA<SnapshotStoreException>()),
      );
      expect(
        (await store.readIndex())!.snapshots.single.status,
        SnapshotStatus.saving,
      );
    },
  );

  test('same-version check detects a corrupt authenticated blob', () async {
    final root = Directory.systemTemp.createTempSync('fix2-blob-integrity-');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = SnapshotStore(
      supportRoot: root,
      accountKey: fixtures.account,
      rootKey: List<int>.filled(32, 9),
    );
    final body = utf8.encode('hello\n');
    final hash = fixtures.blobId(body);
    final record = fixtures.record(status: SnapshotStatus.complete);
    final tree = fixtures.tree(
      fixtures.id,
      hash,
      state: SnapshotEntryState.saved,
    );
    await store.writeTree(
      SnapshotTree(
        snapshotId: fixtures.id,
        sha: fixtures.sha,
        subPath: '',
        entries: [
          tree.entries[0].copyWith(state: SnapshotEntryState.saved),
          tree.entries[1],
        ],
      ),
      format: SnapshotObjectFormat.sha1,
      complete: true,
      mayCommit: fixtures.allow,
    );
    await store.writeBlob(
      SnapshotObjectFormat.sha1,
      hash,
      body,
      mayCommit: fixtures.allow,
    );
    expect(await store.hasReadableSnapshot(record), isTrue);
    final file = File(
      '${store.accountDirectory}/${await store.blobFileName(SnapshotObjectFormat.sha1, hash)}',
    );
    final ciphertext = file.readAsBytesSync();
    ciphertext[ciphertext.length - 1] ^= 1;
    file.writeAsBytesSync(ciphertext);
    expect(await store.hasReadableSnapshot(record), isFalse);
  });
}
