import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';

import 'coordinator_regression_test.dart' as support;

final class _Keys implements OfflineRepositoryKeys {
  OfflineKeyRead value = const OfflineKeyRead(OfflineKeyStatus.absent);

  @override
  Future<OfflineKeyRead> read(String accountKey) async => value;
  @override
  Future<void> write(String accountKey, Uint8List bytes) async {
    value = OfflineKeyRead(
      OfflineKeyStatus.found,
      Uint8List.fromList(bytes)..[0] ^= 1,
    );
  }

  @override
  Future<void> delete(String accountKey) async {}
  @override
  Future<bool> hasMarker(String accountKey) async => false;
  @override
  Future<void> writeMarker(String accountKey, String operationId) async {}
  @override
  Future<void> deleteMarker(String accountKey) async {}
}

void main() {
  for (final fault in [
    'key readback mismatch',
    'malformed key',
    'orphaned data',
  ]) {
    test(
      '$fault fences and notifies unavailable without deleting data',
      () async {
        final root = Directory.systemTemp.createTempSync('c3-fix2-key-');
        addTearDown(() => root.deleteSync(recursive: true));
        final keys = _Keys();
        var deletes = 0;
        final owner = OfflineRepositoryCoordinator()
          ..configure(
            keys: keys,
            supportRoot: () async => root,
            deleteDirectory: (_) async => deletes++,
          )
          ..open(support.binding);
        // Drain initial activation before installing the key fault.
        expect(await owner.snapshots(support.binding), isEmpty);
        File? sentinel;
        if (fault == 'malformed key') {
          keys.value = OfflineKeyRead(OfflineKeyStatus.found, Uint8List(31));
        } else if (fault == 'orphaned data') {
          final store = SnapshotStore(
            supportRoot: root,
            accountKey: support.binding.accountKey,
            rootKey: Uint8List(32),
          );
          sentinel = File('${store.accountDirectory}/retained.bin')
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync([1, 2, 3]);
        }
        final states = <OfflineRepositoryState>[];
        final subscription = owner.changes.listen((binding) {
          states.add(owner.state(binding.accountKey));
        });
        addTearDown(subscription.cancel);
        final permit = owner.capture(support.binding, 0);
        await expectLater(
          owner.maintain<void>(
            permit,
            (_, _) async => fail('unavailable key must not reach storage work'),
            consentAt: DateTime.now().toUtc(),
          ),
          throwsA(
            isA<SnapshotOperationException>().having(
              (error) => error.failure,
              'failure',
              SnapshotFailure.keyUnavailable,
            ),
          ),
        );
        expect(
          owner.state(support.binding.accountKey),
          OfflineRepositoryState.unavailable,
        );
        expect(states, [OfflineRepositoryState.unavailable]);
        expect(permit.isCurrent, isFalse);
        expect(deletes, 0);
        if (sentinel != null) expect(sentinel.readAsBytesSync(), [1, 2, 3]);
      },
    );
  }
}
