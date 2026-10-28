import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_reader.dart';
import 'package:gitlab_mobile/core/offline/snapshot_save.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/repository_reader.dart';
import 'package:gitlab_mobile/features/cache/offline_repository_namespace.dart';

import '../read_cache_c3_prereq_test.dart' as c2;
import '../support/fake_adapter.dart';
import 'coordinator_regression_test.dart' as support;
import 'snapshot_save_test.dart' show SaveHarness;

final _accessLost = throwsA(
  isA<SnapshotOperationException>().having(
    (error) => error.failure,
    'failure',
    SnapshotFailure.accessLost,
  ),
);

final class _SaveLifecycle {
  _SaveLifecycle() {
    offline = OfflineRepositoryCoordinator(clock: () => save.now);
    disk.cache.register(
      OfflineRepositoryNamespace(
        coordinator: offline,
        keys: disk.keys,
        files: disk.files,
      ),
    );
    disk.cache.bindOfflineRepository(save.api, support.binding);
    save.coordinator = offline;
    save.queue = SnapshotSaveQueue(
      api: save.api,
      coordinator: offline,
      binding: support.binding,
      clock: () => save.now,
      delay: (duration) async => save.now = save.now.add(duration),
    );
  }

  final disk = c2.Harness();
  final save = SaveHarness();
  late final OfflineRepositoryCoordinator offline;

  Future<void> activate() async {
    expect(
      await disk.cache.recover(
        ReadCacheStartupDecision(
          operationTicket: 1,
          accountListRevision: 1,
          accountsReadable: true,
          signOutMarkerReadable: true,
          lastActiveReadable: true,
          signOutPending: false,
          resumeAccountKey: support.binding.accountKey,
        ),
        accountKeys: {support.binding.accountKey},
      ),
      isTrue,
    );
    expect(await disk.cache.activate(support.binding), isTrue);
  }

  Future<void> dispose() async {
    save.closeApi();
    await offline.stopAndWait(support.binding.accountKey);
    await disk.dispose();
    save.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('C2 background and resume preserve an in-progress first save', () async {
    final h = _SaveLifecycle();
    addTearDown(h.dispose);
    await h.activate();
    h.save.stream = StreamController<Uint8List>();
    final job = h.save.queue.enqueue(h.save.request());
    await c2.until(() => h.save.stream!.hasListener);
    final permit = h.offline.capture(support.binding, 1);
    h.disk.cache.background();
    h.save.queue.setForeground(false);
    expect(await h.disk.cache.resume(support.binding), isTrue);
    h.save.queue.setForeground(true);
    expect(permit.isCurrent, isTrue);
    h.save.stream!.add(h.save.archive);
    await h.save.stream!.close();
    final saved = await h.save.run(job);
    expect(job.phase, SnapshotJobPhase.complete, reason: '${job.failure}');
    expect(saved, isNotNull);
    expect(await h.save.reader(saved!).text('docs/hello.txt'), 'hello\n');
    expect(h.save.adapter.requests, hasLength(3));
  });

  test(
    'C2 resume preserves a revocation while worker stop is blocked',
    () async {
      final h = _SaveLifecycle();
      addTearDown(h.dispose);
      await h.activate();
      final saved = await h.save.run(h.save.queue.enqueue(h.save.request()));
      expect(saved, isNotNull);
      final reader = h.save.reader(saved!);
      final stopping = Completer<void>();
      final release = Completer<void>();
      final job = await h.offline.registerJob(
        support.binding,
        1,
        support.otherId,
        cancel: () {},
        stop: () {
          if (!stopping.isCompleted) stopping.complete();
          return release.future;
        },
      );
      final fence = h.disk.cache.invalidateProjectPermission(
        support.binding,
        1,
      );
      await stopping.future;
      try {
        h.disk.cache.background();
        expect(await h.disk.cache.resume(support.binding), isTrue);
        expect(() => h.offline.capture(support.binding, 1), _accessLost);
        expect(() => h.save.reader(saved), _accessLost);
        await expectLater(reader.text('docs/hello.txt'), _accessLost);
      } finally {
        release.complete();
        await fence.quiesced;
        h.offline.finishJob(job);
      }
      expect(await h.offline.snapshots(support.binding), isEmpty);
      final permit = h.offline.capture(support.binding, 0);
      await h.offline.maintain<void>(permit, (store, index) async {
        expect(index!.snapshots, isEmpty);
        expect(await store.readTree(saved), isNull);
      });
      expect(() => h.offline.capture(support.binding, 1), _accessLost);
      await h.offline.projectValidated(support.binding, 1);
      expect(h.offline.capture(support.binding, 1).isCurrent, isTrue);
    },
  );

  test('completed C2 account clear retires prior project fences', () async {
    final h = _SaveLifecycle();
    addTearDown(h.dispose);
    await h.activate();
    await h.save.run(h.save.queue.enqueue(h.save.request()));
    await h.offline.permissionRemoval(support.binding, 1);
    expect(() => h.offline.capture(support.binding, 1), _accessLost);
    expect(
      (await h.disk.cache.clear(
        support.binding,
        ReadCacheCleanupOperation.settingsClear,
      )).complete,
      isTrue,
    );
    final binding = DiskBinding(
      accountKey: support.binding.accountKey,
      generation: 2,
    );
    final api = testApi(
      FakeAdapter((_) => jsonResponse([])),
      host: 'https://example.test',
    )..bindReadCache(binding.accountKey, binding.generation);
    addTearDown(api.close);
    h.disk.cache.bindOfflineRepository(api, binding);
    expect(await h.disk.cache.activate(binding), isTrue);
    expect(h.offline.capture(binding, 1).isCurrent, isTrue);
    expect(await h.offline.snapshots(binding), isEmpty);
  });

  for (final fails in [false, true]) {
    test(
      'directory clear keeps new denials and handles failure=$fails',
      () async {
        final h = c2.Harness();
        addTearDown(h.dispose);
        final deleting = Completer<void>();
        final release = Completer<void>();
        final owner = OfflineRepositoryCoordinator()
          ..configure(
            keys: support.MemoryKeys(),
            supportRoot: () async => h.root,
            deleteDirectory: (_) async {
              deleting.complete();
              await release.future;
              if (fails) throw StateError('synthetic deletion failure');
            },
          )
          ..open(support.binding);
        await owner.snapshots(support.binding);
        final api =
            testApi(
              FakeAdapter((_) => jsonResponse([])),
              host: 'https://example.test',
            )..bindReadCache(
              support.binding.accountKey,
              support.binding.generation,
            );
        addTearDown(api.close);
        owner.bindApi(api, support.binding);
        await owner.permissionRemoval(support.binding, 1);
        owner.fence(support.binding.accountKey);
        final deletion = owner.deleteDirectory(support.binding.accountKey);
        await deleting.future;
        owner.accessLost(
          const OfflineAccessLoss(
            binding: support.binding,
            projectId: 2,
            scope: OfflineAccessScope.project,
            status: 403,
          ),
        );
        release.complete();
        if (fails) {
          await expectLater(deletion, throwsStateError);
        } else {
          await deletion;
        }
        owner.open(support.binding);
        if (fails) {
          expect(() => owner.capture(support.binding, 1), _accessLost);
        } else {
          expect(owner.capture(support.binding, 1).isCurrent, isTrue);
        }
        expect(() => owner.capture(support.binding, 2), _accessLost);
        await owner.permissionRemoval(support.binding, 3);
        await owner.stopAndWait(support.binding.accountKey);
      },
    );
  }

  test('local clear replays denials received during cleanup', () async {
    final h = c2.Harness();
    addTearDown(h.dispose);
    final deleting = Completer<void>();
    final release = Completer<void>();
    final owner = OfflineRepositoryCoordinator()
      ..configure(
        keys: support.MemoryKeys(),
        supportRoot: () async => h.root,
        deleteDirectory: (_) async {
          deleting.complete();
          await release.future;
        },
      )
      ..open(support.binding);
    await owner.snapshots(support.binding);
    final api = testApi(
      FakeAdapter((_) => jsonResponse([])),
      host: 'https://example.test',
    )..bindReadCache(support.binding.accountKey, support.binding.generation);
    addTearDown(api.close);
    owner.bindApi(api, support.binding);
    final clear = owner.clearAll(support.binding);
    await deleting.future;
    owner.accessLost(
      const OfflineAccessLoss(
        binding: support.binding,
        projectId: 2,
        scope: OfflineAccessScope.project,
        status: 403,
      ),
    );
    release.complete();
    await clear;
    expect(() => owner.capture(support.binding, 2), _accessLost);
    await owner.permissionRemoval(support.binding, 3);
    await owner.stopAndWait(support.binding.accountKey);
  });

  for (final rebind in [false, true]) {
    test('early fence blocks readers before cleanup: rebind=$rebind', () async {
      final h = c2.Harness();
      addTearDown(h.dispose);
      final keys = support.MemoryKeys()
        ..readGate = Completer<void>()
        ..readStarted = Completer<void>();
      var reads = 0;
      final owner = OfflineRepositoryCoordinator()
        ..configure(
          keys: keys,
          supportRoot: () async {
            reads++;
            return h.root;
          },
          deleteDirectory: (_) async {},
        );
      final api = testApi(
        FakeAdapter((_) => jsonResponse({'message': 'denied'}, status: 403)),
        host: 'https://example.test',
      )..bindReadCache(support.binding.accountKey, support.binding.generation);
      addTearDown(api.close);
      owner.bindApi(api, support.binding);
      await expectLater(
        api.record(['projects', '1']),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        reads,
        0,
        reason: 'binding a pending refusal must not start disk I/O',
      );
      var binding = support.binding;
      if (rebind) {
        binding = DiskBinding(accountKey: binding.accountKey, generation: 2);
        final replacement = testApi(
          FakeAdapter((_) => jsonResponse([])),
          host: 'https://example.test',
        )..bindReadCache(binding.accountKey, binding.generation);
        addTearDown(replacement.close);
        owner.bindApi(replacement, binding);
        owner.accessLost(
          const OfflineAccessLoss(
            binding: support.binding,
            projectId: 88,
            scope: OfflineAccessScope.project,
            status: 403,
          ),
        );
      }
      owner.open(binding);
      try {
        await keys.readStarted!.future;
        expect(() => owner.capture(binding, 1), _accessLost);
        expect(
          () => SnapshotRepositoryReader(
            coordinator: owner,
            owner: ReaderOwner(
              accountKey: binding.accountKey,
              generation: binding.generation,
              instanceKey: 'https://example.test',
              projectId: 1,
              sha: support.sha,
              subPath: '',
              snapshotId: support.jobId,
            ),
          ),
          _accessLost,
        );
        expect(owner.capture(binding, 88).isCurrent, isTrue);
      } finally {
        keys.readGate!.complete();
        await owner.permissionRemoval(binding, 2);
        await owner.stopAndWait(binding.accountKey);
      }
      expect(() => owner.capture(binding, 1), _accessLost);
    });
  }

  for (final status in [403, 404]) {
    test(
      'definite $status during first disk preparation is replayed',
      () async {
        final h = c2.Harness();
        addTearDown(h.dispose);
        final now = DateTime.now().toUtc();
        final key = Uint8List(32);
        await h.keys.writeOfflineKey(c2.account, key);
        final store = SnapshotStore(
          supportRoot: h.root,
          accountKey: c2.account,
          rootKey: key,
        );
        final old = support.completeRecord(42, support.jobId, now);
        await store.writeTree(
          SnapshotTree(
            snapshotId: old.id,
            sha: old.sha,
            subPath: '',
            entries: [],
          ),
          format: old.objectFormat,
          complete: true,
          mayCommit: () => true,
        );
        await store.writeIndex(
          SnapshotIndex(
            accountKey: c2.account,
            lastValidatedAt: now,
            consentAt: now,
            snapshots: [old],
          ),
          expectedRevision: store.revision,
          mayCommit: () => true,
        );
        expect(await h.recover(), isTrue);
        final api = testApi(
          FakeAdapter(
            (_) => jsonResponse({'message': 'access denied'}, status: status),
          ),
          host: 'https://synthetic.example/subpath',
        )..bindReadCache(c2.account, c2.binding.generation);
        addTearDown(api.close);
        // Production binding installs sinks but leaves the namespace pending.
        h.cache.bindOfflineRepository(api, c2.binding);
        h.storage.keyReadGate = Completer<void>();
        h.storage.keyReadStarted = Completer<void>();
        final activation = h.cache.activate(c2.binding);
        await h.storage.keyReadStarted!.future;
        await expectLater(
          api.record(['projects', '42']),
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.kind,
              'kind',
              status == 403 ? FailureKind.forbidden : FailureKind.invisible,
            ),
          ),
        );
        expect((await store.readIndex())!.snapshots.single.id, old.id);
        h.storage.keyReadGate!.complete();
        expect(await activation, isTrue);
        // A barrier behind open's queued revocation must observe its deletion.
        final fence = h.cache.invalidateProjectPermission(c2.binding, 43);
        await fence.quiesced;
        expect((await store.readIndex())!.snapshots, isEmpty);
        expect(await store.readTree(old), isNull);
      },
    );
  }
}
