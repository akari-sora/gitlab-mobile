import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';

import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_reader.dart';
import 'package:gitlab_mobile/core/offline/snapshot_save.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/repository_reader.dart';

import '../support/fake_adapter.dart';
import 'coordinator_regression_test.dart' as support;

const _blob = 'ce013625030ba8dba906f756967f9e9ca394464a';
const _tree = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class SaveHarness {
  SaveHarness({this.oauth = false}) {
    final scratch = Directory('.dart_tool/c3a2/save-tests')
      ..createSync(recursive: true);
    root = scratch.createTempSync('case-');
    archive = File('test/fixtures/offline/synthetic.tar.gz').readAsBytesSync();
    adapter = FakeAdapter((request) {
      final overridden = responseOverride?.call(request);
      if (overridden != null) return overridden;
      final path = request.uri.path;
      if ((path.contains('/branches/') || path.contains('/tags/')) &&
          refGate != null) {
        return refGate!.future;
      }
      if (path.contains('/branches/') || path.contains('/tags/')) {
        if (networkFailures > 0) {
          networkFailures--;
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
          );
        }
        if (rateFailures > 0) {
          rateFailures--;
          return jsonResponse(
            {'message': 'rate limited'},
            status: 429,
            headers: {
              'retry-after': ['0'],
            },
          );
        }
        if (oauth && !rejectedOnce) {
          rejectedOnce = true;
          return jsonResponse({'message': 'expired'}, status: 401);
        }
        return jsonResponse({
          'commit': {
            'id': sha,
            'title': 'fixture',
            'committed_date': now.toIso8601String(),
          },
        });
      }
      if (path.contains('/commits/')) return jsonResponse({'id': sha});
      if (path.endsWith('/tree')) {
        final secondPage = request.uri.queryParameters['page'] == '2';
        return jsonResponse(
          [
            if (!multiPage || !secondPage)
              {'path': 'docs', 'type': 'tree', 'mode': '040000', 'id': _tree},
            if (!multiPage || secondPage)
              {
                'path': 'docs/hello.txt',
                'type': 'blob',
                'mode': '100644',
                'id': _blob,
              },
          ],
          headers: {
            if (noStoreTree) 'cache-control': ['no-store'],
            if (multiPage && !secondPage) 'x-next-page': ['2'],
          },
        );
      }
      if (path.endsWith('/archive.tar.gz')) {
        if (archiveNetworkFailures > 0) {
          archiveNetworkFailures--;
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
          );
        }
        if (stream != null) return ResponseBody(stream!.stream, 200);
        final bytes = Uint8List.fromList(archive);
        if (corrupt) bytes[bytes.length - 8] ^= 1;
        return ResponseBody.fromBytes(
          bytes,
          200,
          headers: noStoreArchive
              ? {
                  'cache-control': ['no-store'],
                }
              : {},
        );
      }
      throw StateError('Unexpected request: $path');
    });
    tokenAdapter = FakeAdapter(
      (_) => jsonResponse({
        'access_token': 'new-access',
        'refresh_token': 'new-refresh',
        'token_type': 'bearer',
      }),
    );
    final instance = GitLabInstance.parse('https://example.test');
    api =
        (oauth
              ? GitLabApi(
                  instance: instance,
                  credential: const OAuthCredential(
                    accessToken: 'old-access',
                    refreshToken: 'old-refresh',
                    clientId: 'synthetic-client',
                  ),
                  dio: Dio()..httpClientAdapter = adapter,
                  oauth: OAuthTokenClient(
                    instance: instance,
                    clientId: 'synthetic-client',
                    dio: Dio()..httpClientAdapter = tokenAdapter,
                  ),
                  rateBudget: GitLabRateBudget(now: () => now),
                )
              : GitLabApi(
                  instance: instance,
                  token: 'synthetic-test-token',
                  dio: Dio()..httpClientAdapter = adapter,
                  cdnAdapter: adapter,
                  rateBudget: GitLabRateBudget(now: () => now),
                ))
          ..bindReadCache(
            support.binding.accountKey,
            support.binding.generation,
          );
    coordinator = OfflineRepositoryCoordinator()
      ..configure(
        keys: support.MemoryKeys(),
        supportRoot: () async => root,
        deleteDirectory: (_) async {
          final namespace = Directory('${root.path}/offline_repo');
          if (namespace.existsSync()) namespace.deleteSync(recursive: true);
        },
      )
      ..bindApi(api, support.binding)
      ..open(support.binding);
    queue = SnapshotSaveQueue(
      api: api,
      coordinator: coordinator,
      binding: support.binding,
      clock: () => now,
      delay: (duration) async {
        delays.add(duration);
        if (duration == const Duration(seconds: 30) && budgetDelay != null) {
          await budgetDelay!.future;
          now = now.add(duration);
        } else {
          now = now.add(duration);
        }
      },
    );
    closeApi = api.close;
  }
  final bool oauth;
  ResponseBody? Function(RequestOptions)? responseOverride;
  bool rejectedOnce = false, multiPage = false;
  int networkFailures = 0, rateFailures = 0, archiveNetworkFailures = 0;
  Completer<void>? budgetDelay;
  late GitLabApi api;
  late FakeAdapter tokenAdapter;
  late Directory root;
  late Uint8List archive;
  late FakeAdapter adapter;
  late OfflineRepositoryCoordinator coordinator;
  late SnapshotSaveQueue queue;
  late void Function() closeApi;
  DateTime now = DateTime.utc(2026, 1, 1);
  String sha = support.sha;
  bool corrupt = false, noStoreTree = false, noStoreArchive = false;
  StreamController<Uint8List>? stream;
  Completer<ResponseBody>? refGate;
  final delays = <Duration>[];
  SnapshotSaveRequest request({
    SnapshotRefKind kind = SnapshotRefKind.branch,
    String? replaces,
    int projectId = 1,
  }) => SnapshotSaveRequest(
    projectId: projectId,
    projectPath: 'group/project',
    projectName: 'project',
    defaultBranch: 'main',
    refKind: kind,
    refName: kind == SnapshotRefKind.branch ? 'main' : 'v1',
    consentAt: now,
    replaces: replaces,
  );
  Future<SnapshotRecord?> run(SnapshotSaveJob job) =>
      job.completion.timeout(const Duration(seconds: 10));
  SnapshotRepositoryReader reader(SnapshotRecord record) =>
      SnapshotRepositoryReader(
        coordinator: coordinator,
        owner: ReaderOwner(
          accountKey: support.binding.accountKey,
          generation: support.binding.generation,
          instanceKey: 'https://example.test',
          projectId: record.projectId,
          sha: record.sha,
          subPath: '',
          snapshotId: record.id,
        ),
      );
  void dispose() {
    closeApi();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  late SaveHarness h;
  setUp(() => h = SaveHarness());
  tearDown(() => h.dispose());

  for (final kind in SnapshotRefKind.values) {
    test(
      '${kind.name} save reads back through the formal reader and counts requests',
      () async {
        final job = h.queue.enqueue(h.request(kind: kind));
        final saved = await h.run(job);
        expect(job.phase, SnapshotJobPhase.complete, reason: '${job.failure}');
        expect(saved, isNotNull);
        expect(job.requests, kind == SnapshotRefKind.branch ? 3 : 4);
        expect(h.adapter.requests.length, job.requests);
        expect(await h.reader(saved!).text('docs/hello.txt'), 'hello\n');
        expect(
          (await h.reader(saved).tree('docs')).items.single['path'],
          'docs/hello.txt',
        );
      },
    );
  }

  for (final target in ['tree', 'archive']) {
    test('$target no-store cannot publish a complete snapshot', () async {
      h.noStoreTree = target == 'tree';
      h.noStoreArchive = target == 'archive';
      final job = h.queue.enqueue(h.request());
      expect(await h.run(job), isNull);
      expect(job.phase, SnapshotJobPhase.failed);
      expect(job.failure, SnapshotFailure.serverForbidsStorage);
      expect(
        (await h.coordinator.snapshots(
          support.binding,
        )).where((s) => s.status == SnapshotStatus.complete),
        isEmpty,
      );
    });
  }

  test('bad gzip trailer cannot publish a complete snapshot', () async {
    h.corrupt = true;
    final job = h.queue.enqueue(h.request());
    expect(await h.run(job), isNull);
    expect(job.phase, SnapshotJobPhase.failed);
    expect(job.failure, SnapshotFailure.corruptArchive);
    expect(
      (await h.coordinator.snapshots(
        support.binding,
      )).where((s) => s.status == SnapshotStatus.complete),
      isEmpty,
    );
  });

  test('failed update keeps the previous complete snapshot readable', () async {
    final old = await h.run(h.queue.enqueue(h.request()));
    expect(old, isNotNull);
    h.sha = 'cccccccccccccccccccccccccccccccccccccccc';
    h.corrupt = true;
    final job = h.queue.enqueue(h.request(replaces: old!.id));
    expect(await h.run(job), isNull);
    expect(job.phase, SnapshotJobPhase.failed);
    expect(await h.reader(old).text('docs/hello.txt'), 'hello\n');
    expect(
      (await h.coordinator.snapshots(
        support.binding,
      )).singleWhere((s) => s.id == old.id).status,
      SnapshotStatus.complete,
    );
    expect(h.delays, contains(const Duration(seconds: 15)));
  });
  test('cancel at finalizing prevents publication', () async {
    Future<void>? cancelled;
    final subscription = h.queue.changes.listen((job) {
      if (job.phase == SnapshotJobPhase.finalizing) {
        cancelled = h.queue.cancel(job);
      }
    });
    final job = h.queue.enqueue(h.request());
    expect(await h.run(job), isNull);
    await cancelled;
    await subscription.cancel();
    expect(job.phase, SnapshotJobPhase.cancelled);
    expect(
      (await h.coordinator.snapshots(
        support.binding,
      )).where((s) => s.status == SnapshotStatus.complete),
      isEmpty,
    );
  });

  test('permission loss at finalizing prevents publication', () async {
    Future<void>? removal;
    final subscription = h.queue.changes.listen((job) {
      if (job.phase == SnapshotJobPhase.finalizing) {
        removal = h.coordinator.permissionRemoval(support.binding, 1);
      }
    });
    final job = h.queue.enqueue(h.request());
    expect(await h.run(job), isNull);
    await removal;
    await subscription.cancel();
    expect(job.phase, SnapshotJobPhase.failed);
    expect(
      (await h.coordinator.snapshots(
        support.binding,
      )).where((s) => s.status == SnapshotStatus.complete),
      isEmpty,
    );
  });

  test('queue permits five pending jobs and rejects the sixth', () async {
    h.refGate = Completer<ResponseBody>();
    final active = h.queue.enqueue(h.request());
    final pending = List.generate(
      5,
      (i) => h.queue.enqueue(h.request(projectId: i + 2)),
    );
    expect(h.queue.queued, hasLength(5));
    expect(
      () => h.queue.enqueue(h.request(projectId: 7)),
      throwsA(isA<SnapshotOperationException>()),
    );
    for (final job in pending) {
      await h.queue.cancel(job);
    }
    final cancellation = h.queue.cancel(active);
    h.refGate!.complete(
      jsonResponse({
        'commit': {
          'id': h.sha,
          'title': 'fixture',
          'committed_date': h.now.toIso8601String(),
        },
      }),
    );
    await cancellation.timeout(const Duration(seconds: 10));
    expect(active.phase, SnapshotJobPhase.cancelled);
  });
  test('paused job resumes from its persisted tree and completes', () async {
    final subscription = h.queue.changes.listen((job) {
      if (job.phase == SnapshotJobPhase.downloading) h.queue.pause(job);
    });
    final pausedJob = h.queue.enqueue(h.request());
    expect(await h.run(pausedJob), isNull);
    await subscription.cancel();
    expect(pausedJob.phase, SnapshotJobPhase.paused);
    expect(pausedJob.snapshot?.status, SnapshotStatus.paused);
    final resumed = h.queue.enqueue(h.request(), resume: pausedJob.snapshot);
    final saved = await h.run(resumed);
    expect(
      resumed.phase,
      SnapshotJobPhase.complete,
      reason: '${resumed.failure}',
    );
    expect(saved?.id, pausedJob.id);
    expect(await h.reader(saved!).text('docs/hello.txt'), 'hello\n');
  });
  test('unknown rate bucket waits 200 ms between tree pages', () async {
    h.multiPage = true;
    final job = h.queue.enqueue(h.request());
    final saved = await h.run(job);
    expect(job.phase, SnapshotJobPhase.complete, reason: '${job.failure}');
    expect(job.page, 2);
    expect(h.delays, contains(const Duration(milliseconds: 200)));
    expect(job.requests, 4);
    expect(await h.reader(saved!).text('docs/hello.txt'), 'hello\n');
  });

  test('tree rechecks normal rate after waiting for a phase lease', () async {
    h.budgetDelay = Completer<void>();
    final reset = h.now.add(const Duration(minutes: 1));
    final held = <RunBudgetLease>[];
    DateTime? sentAt;
    h.responseOverride = (request) {
      if (request.uri.path.endsWith('/tree')) sentAt = h.now;
      return null;
    };
    var blocked = false;
    final subscription = h.queue.changes.listen((job) {
      if (job.phase == SnapshotJobPhase.listing && held.isEmpty && !blocked) {
        held.addAll(List.generate(3, (_) => h.api.runBudget.acquire(40)!));
      }
      if (job.phase == SnapshotJobPhase.waitingBudget && !blocked) {
        blocked = true;
        h.api.rateBudget.noteResponse(
          headers: {
            'date': [HttpDate.format(h.now)],
            'ratelimit-limit': ['100'],
            'ratelimit-remaining': ['10'],
            'ratelimit-reset': ['${reset.millisecondsSinceEpoch ~/ 1000}'],
          },
          statusCode: 200,
          requestClass: RateRequestClass.global,
          sequence: h.api.rateBudget.nextSequence(),
          trusted: true,
        );
        for (final lease in held) {
          lease.release();
        }
      }
    });
    final saved = await h.run(h.queue.enqueue(h.request()));
    expect(saved, isNotNull);
    expect(blocked, isTrue);
    expect(sentAt, isNotNull);
    expect(sentAt!.isBefore(reset), isFalse);
    expect(h.api.runBudget.activeLeases, 0);
    h.budgetDelay!.complete();
    await subscription.cancel();
  });

  test(
    'waits for null and zero-grant leases, then releases its reservations',
    () async {
      for (final zeroGrant in [false, true]) {
        final current = zeroGrant ? SaveHarness() : h;
        try {
          current.budgetDelay = Completer<void>();
          if (zeroGrant) {
            final budget = current.api.rateBudget;
            budget.noteResponse(
              headers: {
                'ratelimit-limit': ['100'],
                'ratelimit-remaining': ['45'],
                'retry-after': ['3600'],
              },
              statusCode: 200,
              requestClass: RateRequestClass.global,
              sequence: budget.nextSequence(),
              trusted: true,
            );
          }
          final allocator = current.api.runBudget;
          final held = [allocator.acquire(40)!, allocator.acquire(40)!];
          if (!zeroGrant) held.add(allocator.acquire(40)!);
          if (zeroGrant) {
            final probe = allocator.acquire(40)!;
            expect(probe.granted, 0);
            probe.release();
          }
          var waited = false;
          int? activeWhileWaiting;
          int? requestsWhileWaiting;
          final subscription = current.queue.changes.listen((job) {
            if (job.phase == SnapshotJobPhase.waitingBudget && !waited) {
              waited = true;
              activeWhileWaiting = allocator.activeLeases;
              requestsWhileWaiting = current.adapter.requests.length;
              for (final lease in held) {
                lease.release();
              }
            }
          });
          final job = current.queue.enqueue(current.request());
          final saved = await current.run(job);
          expect(
            job.phase,
            SnapshotJobPhase.complete,
            reason: '${job.failure}',
          );
          expect(saved, isNotNull);
          expect(waited, isTrue);
          expect(requestsWhileWaiting, 0);
          expect(
            activeWhileWaiting,
            held.length,
            reason: 'zero-grant lease must be released',
          );
          expect(allocator.activeLeases, 0);
          expect(allocator.unconsumedReservations, 0);
          await subscription.cancel();
        } finally {
          if (zeroGrant) current.dispose();
        }
      }
    },
  );

  test('OAuth refresh and replay count all physical sends', () async {
    final oauthHarness = SaveHarness(oauth: true);
    try {
      final job = oauthHarness.queue.enqueue(oauthHarness.request());
      final saved = await oauthHarness.run(job);
      expect(job.phase, SnapshotJobPhase.complete, reason: '${job.failure}');
      expect(saved, isNotNull);
      expect(oauthHarness.adapter.requests, hasLength(4));
      expect(oauthHarness.tokenAdapter.requests, hasLength(1));
      expect(job.requests, 5);
      expect(
        await oauthHarness.reader(saved!).text('docs/hello.txt'),
        'hello\n',
      );
    } finally {
      oauthHarness.dispose();
    }
  });
  test(
    'zero-grant waiting yields to the event loop until capacity is released',
    () async {
      h.budgetDelay = Completer<void>();
      final budget = h.api.rateBudget;
      budget.noteResponse(
        headers: {
          'ratelimit-limit': ['100'],
          'ratelimit-remaining': ['45'],
          'retry-after': ['3600'],
        },
        statusCode: 200,
        requestClass: RateRequestClass.global,
        sequence: budget.nextSequence(),
        trusted: true,
      );
      final allocator = h.api.runBudget;
      final held = [allocator.acquire(40)!, allocator.acquire(40)!];
      final probe = allocator.acquire(40)!;
      expect(probe.granted, 0);
      probe.release();
      var waitingPhases = 0;
      final waiting = Completer<void>();
      final subscription = h.queue.changes.listen((job) {
        if (job.phase == SnapshotJobPhase.waitingBudget) {
          waitingPhases++;
          // Bound a regression that could otherwise starve the test timer.
          if (waitingPhases > 1) h.queue.pause(job);
          if (!waiting.isCompleted) waiting.complete();
        }
      });
      final job = h.queue.enqueue(h.request());
      await waiting.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(waitingPhases, 1);
      expect(h.adapter.requests, isEmpty);
      expect(allocator.activeLeases, held.length);
      for (final lease in held) {
        lease.release();
      }
      expect(await h.run(job), isNotNull, reason: '${job.failure}');
      expect(job.phase, SnapshotJobPhase.complete);
      expect(allocator.activeLeases, 0);
      await subscription.cancel();
    },
  );
  test(
    'network retry waits 30 seconds and foreground and retries only once',
    () async {
      h.networkFailures = 2;
      h.budgetDelay = Completer<void>();
      h.queue.setForeground(false);
      final paused = Completer<void>();
      final subscription = h.queue.changes.listen((job) {
        if (job.phase == SnapshotJobPhase.paused && !paused.isCompleted) {
          paused.complete();
        }
      });
      final job = h.queue.enqueue(h.request());
      await paused.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect(h.adapter.requests, hasLength(1));
      expect(h.delays, contains(const Duration(seconds: 30)));
      final before = h.now;
      h.budgetDelay!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(h.now.difference(before), const Duration(seconds: 30));
      expect(
        h.adapter.requests,
        hasLength(1),
        reason: 'background cannot retry',
      );
      h.queue.setForeground(true);
      expect(await h.run(job), isNull);
      expect(h.adapter.requests, hasLength(2));
      expect(job.phase, SnapshotJobPhase.failed);
      expect(job.failure, SnapshotFailure.network);
      await subscription.cancel();
    },
  );

  test(
    'one transient network failure retries and saves successfully',
    () async {
      h.networkFailures = 1;
      final job = h.queue.enqueue(h.request());
      final saved = await h.run(job);
      expect(job.phase, SnapshotJobPhase.complete, reason: '${job.failure}');
      expect(h.delays, contains(const Duration(seconds: 30)));
      expect(h.adapter.requests, hasLength(4));
      expect(await h.reader(saved!).text('docs/hello.txt'), 'hello\n');
    },
  );

  for (final cancel in [false, true]) {
    test(
      '${cancel ? 'cancel' : 'pause'} during network retry wait stops retry',
      () async {
        h.now = DateTime.now().toUtc();
        h.archiveNetworkFailures = 1;
        h.budgetDelay = Completer<void>();
        final paused = Completer<void>();
        final subscription = h.queue.changes.listen((job) {
          if (job.phase == SnapshotJobPhase.paused && !paused.isCompleted) {
            paused.complete();
          }
        });
        final job = h.queue.enqueue(h.request());
        await paused.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
        if (cancel) {
          await h.queue.cancel(job).timeout(const Duration(seconds: 5));
        } else {
          h.queue.pause(job);
        }
        expect(await h.run(job), isNull);
        expect(h.adapter.requests, hasLength(3));
        expect(
          job.phase,
          cancel ? SnapshotJobPhase.cancelled : SnapshotJobPhase.paused,
        );
        final records = await h.coordinator.snapshots(support.binding);
        if (cancel) {
          expect(records, isEmpty);
        } else {
          expect(records, hasLength(1));
          expect(records.single.status, SnapshotStatus.paused);
          expect(records.single.failure, isNull);
          expect(records.single.interrupted, isFalse);
        }
        await subscription.cancel();
      },
    );
  }

  test('429 automatically resumes after rate cooldown', () async {
    h.now = DateTime.now().toUtc();
    h.rateFailures = 1;
    final job = h.queue.enqueue(h.request());
    final saved = await h.run(job);
    expect(job.phase, SnapshotJobPhase.complete, reason: '${job.failure}');
    expect(saved, isNotNull);
    expect(h.adapter.requests, hasLength(4));
    expect(job.requests, 4);
  });
}
