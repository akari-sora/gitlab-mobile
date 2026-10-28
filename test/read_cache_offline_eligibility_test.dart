import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';

import 'offline/coordinator_regression_test.dart'
    show completeRecord, jobId, otherId;
import 'read_cache_c3_prereq_test.dart' show Harness, account;

final _now = DateTime.utc(2026, 10, 28);

Future<(SnapshotStore, SnapshotRecord, SnapshotRecord)> _seed(
  Harness h, {
  required bool badFirst,
}) async {
  await h.keys.writeOfflineKey(account, Uint8List(32));
  final store = SnapshotStore(
    supportRoot: h.root,
    accountKey: account,
    rootKey: Uint8List(32),
  );
  final bad = completeRecord(1, jobId, _now);
  final good = completeRecord(2, otherId, _now);
  for (final record in [bad, good]) {
    await store.writeTree(
      SnapshotTree(
        snapshotId: record.id,
        sha: record.sha,
        subPath: record.subPath,
        entries: [],
      ),
      format: record.objectFormat,
      complete: true,
      mayCommit: () => true,
    );
  }
  await store.writeIndex(
    SnapshotIndex(
      accountKey: account,
      lastValidatedAt: _now,
      consentAt: _now,
      snapshots: badFirst ? [bad, good] : [good, bad],
    ),
    expectedRevision: store.revision,
    mayCommit: () => true,
  );
  final owner = Object();
  h.cache.claimStartupSession(owner);
  expect(await h.recover(owner: owner), isTrue);
  return (store, bad, good);
}

Map<String, List<int>> _files(Directory root) => {
  for (final entry in root.listSync(recursive: true, followLinks: false))
    if (FileSystemEntity.typeSync(entry.path, followLinks: false) ==
        FileSystemEntityType.file)
      entry.path: File(entry.path).readAsBytesSync(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final badFirst in [true, false]) {
    for (final damage in ['authentication', 'schema']) {
      test(
        'eligibility skips $damage damage with ${badFirst ? 'bad first' : 'good first'} and writes nothing',
        () async {
          final h = Harness();
          addTearDown(h.dispose);
          final (store, bad, _) = await _seed(h, badFirst: badFirst);
          final badFile = File(
            '${store.accountDirectory}/${SnapshotStore.treeFileName(bad.id)}',
          );
          if (damage == 'authentication') {
            final bytes = badFile.readAsBytesSync();
            bytes[bytes.length - 1] ^= 1;
            badFile.writeAsBytesSync(bytes);
          } else {
            // A valid encrypted tree with the wrong SHA fails tree binding.
            await store.writeTree(
              SnapshotTree(
                snapshotId: bad.id,
                sha: 'b' * 40,
                subPath: bad.subPath,
                entries: [],
              ),
              format: bad.objectFormat,
              complete: true,
              mayCommit: () => true,
            );
          }
          final before = _files(h.root);
          final index = File('${store.accountDirectory}/index.v1.bin');
          final indexModified = index.statSync().modified;
          h.storage.events.clear();

          expect(await h.cache.offlineEligibilityIndex(account), isNotNull);
          expect(_files(h.root), before);
          expect(index.statSync().modified, indexModified);
          expect(
            h.storage.events.where(
              (event) =>
                  event.startsWith('write:') || event.startsWith('delete:'),
            ),
            isEmpty,
          );
        },
      );
    }
  }

  test('untrusted first tree fails closed without deleting anything', () async {
    final h = Harness();
    addTearDown(h.dispose);
    final (store, bad, good) = await _seed(h, badFirst: true);
    final badPath =
        '${store.accountDirectory}/${SnapshotStore.treeFileName(bad.id)}';
    final goodPath =
        '${store.accountDirectory}/${SnapshotStore.treeFileName(good.id)}';
    File(badPath).deleteSync();
    Link(badPath).createSync(goodPath);
    final before = _files(h.root);
    final target = Link(badPath).targetSync();
    h.storage.events.clear();

    expect(await h.cache.offlineEligibilityIndex(account), isNull);
    expect(_files(h.root), before);
    expect(Link(badPath).targetSync(), target);
    expect(
      h.storage.events.where(
        (event) => event.startsWith('write:') || event.startsWith('delete:'),
      ),
      isEmpty,
    );
  });

  test(
    'unavailable offline key fails closed without deleting anything',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await _seed(h, badFirst: true);
      final before = _files(h.root);
      h.storage.events.clear();
      h.storage.failOfflineKeyRead = true;

      expect(await h.cache.offlineEligibilityIndex(account), isNull);
      expect(_files(h.root), before);
      expect(
        h.storage.events.where(
          (event) => event.startsWith('write:') || event.startsWith('delete:'),
        ),
        isEmpty,
      );
    },
  );
}
