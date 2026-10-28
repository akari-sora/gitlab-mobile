import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_probe.dart';
import 'package:gitlab_mobile/core/offline/snapshot_save.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/features/offline/offline_repositories.dart';

import '../support/fake_adapter.dart';
import 'coordinator_regression_test.dart' as support;
import 'snapshot_save_test.dart' show SaveHarness;

void main() {
  late SaveHarness h;
  setUp(() {
    h = SaveHarness();
    SnapshotProber(
      api: h.api,
      coordinator: h.coordinator,
      binding: support.binding,
      clock: () => h.now,
      delay: (duration) async {
        h.now = h.now.add(duration);
      },
    );
  });
  tearDown(() => h.dispose());

  test(
    'generation change clears presentation and rejects the previous client',
    () async {
      await h.run(h.queue.enqueue(h.request()));
      final presentation = OfflineRepositories(
        binding: support.binding,
        coordinator: h.coordinator,
        api: h.api,
      );
      addTearDown(presentation.dispose);
      await presentation.refresh();
      expect(presentation.snapshots, hasLength(1));
      expect(presentation.canSave, isTrue);
      final next = DiskBinding(
        accountKey: support.binding.accountKey,
        generation: 2,
      );
      h.coordinator.open(next);
      expect(presentation.snapshots, isEmpty);
      expect(presentation.canSave, isFalse);
      await presentation.refresh();
      expect(presentation.snapshots, isEmpty);
      final before = h.adapter.requests.length;
      final nextQueue = SnapshotSaveQueue(
        api: h.api,
        coordinator: h.coordinator,
        binding: next,
      );
      expect(
        () => nextQueue.enqueue(h.request()),
        throwsA(
          isA<SnapshotOperationException>().having(
            (e) => e.failure,
            'failure',
            SnapshotFailure.sessionEnded,
          ),
        ),
      );
      await expectLater(
        SnapshotProber(
          api: h.api,
          coordinator: h.coordinator,
          binding: next,
        ).validateProject(1),
        throwsA(isA<SnapshotOperationException>()),
      );
      expect(h.adapter.requests.length, before);
    },
  );

  for (final denied in [false, true]) {
    test(
      'archive 404 probes project before retaining/removing old save: denied=$denied',
      () async {
        final old = (await h.run(h.queue.enqueue(h.request())))!;
        h.sha = 'c' * 40;
        h.responseOverride = (request) {
          if (request.uri.path.endsWith('/archive.tar.gz')) {
            return jsonResponse({'message': 'missing archive'}, status: 404);
          }
          if (request.uri.path.endsWith('/projects/1')) {
            return denied
                ? jsonResponse({'message': 'forbidden'}, status: 403)
                : jsonResponse({'id': 1});
          }
          if (request.uri.queryParameters['per_page'] == '1') {
            return jsonResponse({'message': 'commit gone'}, status: 404);
          }
          return null;
        };
        final job = h.queue.enqueue(h.request(replaces: old.id));
        expect(await h.run(job), isNull);
        expect(
          job.failure,
          denied ? SnapshotFailure.accessLost : SnapshotFailure.versionGone,
        );
        final records = await h.coordinator.snapshots(support.binding);
        expect(
          h.adapter.requests.any(
            (request) => request.uri.path.endsWith('/projects/1'),
          ),
          isTrue,
        );
        if (denied) {
          expect(records, isEmpty);
          expect(
            () => h.reader(old),
            throwsA(isA<SnapshotOperationException>()),
          );
        } else {
          expect(
            records
                .where((record) => record.status == SnapshotStatus.complete)
                .map((record) => record.id),
            [old.id],
          );
          expect(await h.reader(old).text('docs/hello.txt'), 'hello\n');
          expect(
            h.adapter.requests.any(
              (request) => request.uri.queryParameters['per_page'] == '1',
            ),
            isTrue,
          );
        }
      },
    );
  }

  test(
    'alias refusal uses numeric validation and fences without UI subscribers',
    () async {
      final old = (await h.run(h.queue.enqueue(h.request())))!;
      var denied = false;
      final numeric = Completer<void>();
      h.responseOverride = (request) {
        if (request.uri.path.endsWith('/projects/group%2Fproject')) {
          return denied
              ? jsonResponse({'message': 'forbidden'}, status: 403)
              : jsonResponse({'id': 1, 'path_with_namespace': 'group/project'});
        }
        if (request.uri.path.endsWith('/projects/1')) {
          if (!numeric.isCompleted) numeric.complete();
          return jsonResponse({'message': 'forbidden'}, status: 403);
        }
        return null;
      };
      await h.api.cachedRecord(['projects', 'group/project']);
      denied = true;
      await expectLater(
        h.api.record(['projects', 'group/project']),
        throwsA(anything),
      );
      await numeric.future.timeout(const Duration(seconds: 3));
      for (var turn = 0; turn < 100; turn++) {
        if ((await h.coordinator.snapshots(support.binding)).isEmpty) break;
        await Future<void>.delayed(Duration.zero);
      }
      expect(await h.coordinator.snapshots(support.binding), isEmpty);
      expect(() => h.reader(old), throwsA(isA<SnapshotOperationException>()));
    },
  );
}
