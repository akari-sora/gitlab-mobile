import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_save.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/request_meter.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';

import '../read_cache_c3_prereq_test.dart' as c2;
import '../support/fake_adapter.dart';
import 'coordinator_regression_test.dart' as support;
import 'snapshot_save_test.dart' show SaveHarness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('automatic offline namespace binding', () {
    late c2.Harness h;
    late GitLabApi api;

    setUp(() {
      h = c2.Harness();
      api = testApi(
        FakeAdapter((_) => jsonResponse([])),
        host: 'https://synthetic.example/subpath',
      )..bindReadCache(c2.account, c2.binding.generation);
      h.cache.bindOfflineRepository(api, c2.binding);
    });
    tearDown(() async {
      api.close();
      await h.dispose();
    });

    test(
      'unopened empty account clears without marker writes or deletes',
      () async {
        h.storage.failMarker = true;
        final result = await h.cache.clear(
          c2.binding,
          ReadCacheCleanupOperation.signOut,
        );
        expect(result.complete, isTrue);
        expect(
          h.storage.events.where(
            (event) =>
                event.startsWith('write:') || event.startsWith('delete:'),
          ),
          isEmpty,
        );
        h.assertGone(c2.account);
      },
    );

    test('unopened namespace still clears persisted offline data', () async {
      await h.seed(c2.account, c2: false, refusal: true, marker: true);
      final result = await h.cache.clear(
        c2.binding,
        ReadCacheCleanupOperation.signOut,
      );
      expect(result.complete, isTrue);
      h.assertGone(c2.account);
    });

    test(
      'successful disk activation installs the C3 security participant',
      () async {
        expect(await h.recover(), isTrue);
        expect(await h.cache.activate(c2.binding), isTrue);
        final fence = h.cache.invalidateProjectPermission(c2.binding, 42);
        await fence.quiesced;
        expect((await fence.barrier).complete, isTrue);
        expect(
          (await h.cache.clear(
            c2.binding,
            ReadCacheCleanupOperation.signOut,
          )).complete,
          isTrue,
        );
        h.assertGone(c2.account);
      },
    );

    test(
      'read-only admission opens a pending participant before online preparation',
      () async {
        // The process domain uses the same coordinator exposed to production
        // readers, so acquiring a permit proves the namespace was opened.
        final cache = ReadCacheDiskCoordinator(
          keys: h.keys,
          files: h.files,
          settings: ReadCacheSettingsStore(h.storage),
          controlsInstalled: true,
        );
        final owner = Object();
        cache.claimStartupSession(owner);
        cache.bindOfflineRepository(api, c2.binding);
        cache.retainDiskAccount(c2.account, sessionOwner: owner);
        expect(
          await cache.recover(
            const ReadCacheStartupDecision(
              operationTicket: 1,
              accountListRevision: 1,
              accountsReadable: true,
              signOutMarkerReadable: true,
              lastActiveReadable: true,
              signOutPending: false,
              resumeAccountKey: c2.account,
            ),
            accountKeys: {c2.account},
            sessionOwner: owner,
          ),
          isTrue,
        );
        await h.keys.writeOfflineKey(c2.account, Uint8List(32));
        const binding = DiskBinding(accountKey: c2.account, generation: 2);
        expect(
          await cache.enterOfflineReadOnly(binding, sessionOwner: owner),
          isTrue,
        );
        final offline = OfflineRepositoryCoordinator.instance;
        final permit = offline.capture(binding, 0);
        expect(
          offline.state(c2.account),
          OfflineRepositoryState.offlineReadOnly,
        );
        cache.closeOfflineReadOnly(binding, sessionOwner: owner);
        expect(permit.isCurrent, isFalse);
        expect(
          (await cache.clear(
            binding,
            ReadCacheCleanupOperation.signOut,
          )).complete,
          isTrue,
        );
        await cache.quiesced;
        h.assertGone(c2.account);
      },
    );
  });

  test(
    'cancellation during offline admission counts no physical send',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final adapter = FakeAdapter((_) => jsonResponse([]));
      final api = testApi(adapter);
      addTearDown(api.close);
      final meter = RequestMeter(
        beforeRequest: () async {
          entered.complete();
          await release.future;
        },
      );
      final request = meter.runAsync(() => api.record(['projects', '42']));
      final checked = expectLater(
        request,
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      await entered.future;
      expect(meter.count, 0);
      api.close();
      release.complete();
      await checked;
      expect(meter.count, 0);
      expect(adapter.requests, isEmpty);
    },
  );

  test('async offline admission cannot suspend a write permit', () async {
    var admitted = false;
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    final meter = RequestMeter(
      beforeRequest: () async {
        admitted = true;
      },
    );
    await expectLater(
      meter.runAsync(
        () => api.writeRecord('POST', ['projects', '42', 'star'], {}),
      ),
      throwsA(
        isA<ApiFailure>().having(
          (error) => error.kind,
          'kind',
          FailureKind.cancelled,
        ),
      ),
    );
    expect(admitted, isFalse);
    expect(meter.count, 0);
    expect(adapter.requests, isEmpty);
  });

  test(
    'cancel during archive pacing retains its lease without counting a send',
    () async {
      final h = SaveHarness();
      addTearDown(h.dispose);
      final pacing = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      // Queues are canonical per coordinator/binding; use a fresh owner so
      // this queue receives the controlled pacing delay.
      final root = Directory('${h.root.path}/paced')..createSync();
      h.coordinator = OfflineRepositoryCoordinator()
        ..configure(
          keys: support.MemoryKeys(),
          supportRoot: () async => root,
          deleteDirectory: (_) async {
            final directory = Directory('${root.path}/offline_repo');
            if (directory.existsSync()) directory.deleteSync(recursive: true);
          },
        )
        ..bindApi(h.api, support.binding)
        ..open(support.binding);
      h.queue = SnapshotSaveQueue(
        api: h.api,
        coordinator: h.coordinator,
        binding: support.binding,
        clock: () => h.now,
        delay: (duration) async {
          if (duration == const Duration(seconds: 15)) {
            pacing.complete();
            await release.future;
          }
          h.now = h.now.add(duration);
        },
      );
      final previous = await h.run(h.queue.enqueue(h.request()));
      expect(previous, isNotNull);
      final before = h.adapter.requests.length;
      h.sha = 'cccccccccccccccccccccccccccccccccccccccc';
      final job = h.queue.enqueue(h.request(replaces: previous!.id));
      await pacing.future.timeout(const Duration(seconds: 5));
      final sent = h.adapter.requests.length - before;
      expect(sent, 2);
      expect(job.requests, sent);
      expect(h.api.runBudget.activeLeases, 1);
      expect(h.api.runBudget.unconsumedReservations, 1);
      final cancelled = h.queue.cancel(job);
      release.complete();
      await cancelled;
      expect(await h.run(job), isNull);
      expect(job.phase, SnapshotJobPhase.cancelled);
      expect(job.requests, sent);
      expect(h.adapter.requests.length - before, sent);
      expect(h.api.runBudget.activeLeases, 0);
      expect(h.api.runBudget.unconsumedReservations, 0);
      expect(await h.reader(previous).text('docs/hello.txt'), 'hello\n');
    },
  );
}
