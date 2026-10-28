import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';

void main() {
  test(
    'missing index recovery removes orphan blobs only when workers are absent',
    () async {
      final root = Directory.systemTemp.createTempSync('c3-missing-index-');
      addTearDown(() => root.deleteSync(recursive: true));
      final store = SnapshotStore(
        supportRoot: root,
        accountKey: 'https://example.test#1',
        rootKey: List<int>.filled(32, 9),
      );
      final bytes = utf8.encode('orphan');
      final id = crypto.sha1.convert([
        ...utf8.encode('blob ${bytes.length}\u0000'),
        ...bytes,
      ]).toString();
      await store.writeBlob(
        SnapshotObjectFormat.sha1,
        id,
        bytes,
        mayCommit: () => true,
      );
      expect(
        await store.recover(
          now: DateTime.now(),
          workersRunning: true,
          mayCommit: () => true,
        ),
        isNull,
      );
      expect(await store.readBlob(SnapshotObjectFormat.sha1, id), bytes);
      expect(
        await store.recover(
          now: DateTime.now(),
          workersRunning: false,
          mayCommit: () => true,
        ),
        isNull,
      );
      expect(await store.readBlob(SnapshotObjectFormat.sha1, id), isNull);
    },
  );
}
