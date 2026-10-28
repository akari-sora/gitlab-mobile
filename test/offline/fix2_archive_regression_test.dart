import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/snapshot_save.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';

import 'snapshot_save_test.dart' show SaveHarness;

void main() {
  for (final declaredLength in [null, '10']) {
    test(
      'streamed archive over limit with length $declaredLength fails once',
      () async {
        final h = SaveHarness();
        addTearDown(h.dispose);
        h.responseOverride = (request) {
          if (!request.uri.path.endsWith('/archive.tar.gz')) return null;
          return ResponseBody(
            // The API rejects this one in-memory chunk before forwarding bytes.
            // No large archive fixture is written to disk.
            Stream<Uint8List>.value(Uint8List(300 * 1024 * 1024 + 1)),
            200,
            headers: {
              if (declaredLength != null) 'content-length': [declaredLength],
            },
          );
        };
        final job = h.queue.enqueue(h.request());
        expect(await h.run(job), isNull);
        expect(job.phase, SnapshotJobPhase.failed);
        expect(job.failure, SnapshotFailure.archiveTooLarge);
        expect(
          h.adapter.requests.where(
            (r) => r.uri.path.endsWith('/archive.tar.gz'),
          ),
          hasLength(1),
        );
        expect(h.delays, isNot(contains(const Duration(seconds: 30))));
        expect(job.snapshot?.failure, SnapshotFailure.archiveTooLarge);
      },
    );
  }
}
