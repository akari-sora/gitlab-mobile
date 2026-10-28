import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_probe.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';

import '../support/fake_adapter.dart';
import 'coordinator_regression_test.dart'
    show MemoryKeys, binding, completeRecord, jobId, otherId, sha;

const thirdId = '11111111111111111111111111111111';

void main() {
  late Directory root;
  late OfflineRepositoryCoordinator owner;
  late DateTime now;
  late GitLabApi api;
  late SnapshotProber prober;

  Future<void> setup(
    FakeAdapter adapter,
    List<SnapshotRecord> records, {
    DateTime? lastProbeAt,
    Future<void> Function(Duration)? delay,
  }) async {
    root = Directory.systemTemp.createTempSync('c3-probe-');
    now = DateTime.utc(2026, 10, 28);
    owner = OfflineRepositoryCoordinator(clock: () => now);
    owner.configure(
      keys: MemoryKeys(),
      supportRoot: () async => root,
      deleteDirectory: (_) async {},
    );
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.test'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      rateBudget: GitLabRateBudget(now: () => now),
    );
    api.bindReadCache(binding.accountKey, binding.generation);
    owner.open(binding);
    await owner.maintain<void>(owner.capture(binding, 0), (_, _) async {});
    await Future<void>.delayed(Duration.zero);
    owner.bindApi(api, binding);
    prober = SnapshotProber(
      api: api,
      coordinator: owner,
      binding: binding,
      clock: () => now,
      delay:
          delay ??
          (d) async {
            now = now.add(d);
          },
    );
    final permit = owner.capture(binding, 0);
    await owner.maintain<void>(permit, (store, _) async {
      for (final r in records) {
        await store.writeTree(
          SnapshotTree(snapshotId: r.id, sha: sha, subPath: '', entries: []),
          format: SnapshotObjectFormat.sha1,
          complete: true,
          mayCommit: () => permit.isCurrent,
        );
      }
      await store.writeIndex(
        SnapshotIndex(
          accountKey: binding.accountKey,
          lastValidatedAt: now,
          consentAt: now,
          snapshots: records,
          lastProbeAt: lastProbeAt,
        ),
        expectedRevision: store.revision,
        mayCommit: () => permit.isCurrent,
      );
    });
  }

  Future<SnapshotIndex> index() async => (await owner.maintain<SnapshotIndex>(
    owner.capture(binding, 0),
    (_, value) async => value!,
  ))!;

  tearDown(() {
    api.close();
    root.deleteSync(recursive: true);
  });

  test('nonzero 429 cooldown resumes the same probe automatically', () async {
    var sends = 0;
    final adapter = FakeAdapter((_) {
      sends++;
      if (sends == 1) {
        return jsonResponse(
          {'message': 'rate limited'},
          status: 429,
          headers: {
            'retry-after': ['3'],
          },
        );
      }
      return jsonResponse({
        'commit': {'id': sha},
      });
    });
    await setup(adapter, [
      completeRecord(1, jobId, DateTime.utc(2026, 10, 28)),
    ]);
    final started = now;
    await prober.probeAll();
    expect(sends, 2);
    expect(
      now.difference(started),
      greaterThanOrEqualTo(const Duration(seconds: 3)),
    );
    expect((await index()).snapshots.single.probe, SnapshotProbe.ok);
    expect(api.runBudget.activeLeases, 0);
  });

  test(
    'proxy SHA tree 404 preserves snapshot and prior probe metadata',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/branches/main')) {
          return jsonResponse({'message': 'ref gone'}, status: 404);
        }
        if (request.uri.path.endsWith('/projects/1')) {
          return jsonResponse({'id': 1});
        }
        return ResponseBody.fromString(
          '<html>proxy</html>',
          404,
          headers: {
            'content-type': ['text/html'],
          },
        );
      });
      await setup(adapter, [
        completeRecord(
          1,
          jobId,
          DateTime.utc(2026, 10, 28),
        ).copyWith(probe: SnapshotProbe.ok),
      ]);
      final before = (await index()).snapshots.single.toJson();
      await expectLater(
        prober.probeAll(),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.invalidResponse,
          ),
        ),
      );
      expect((await index()).snapshots.single.toJson(), before);
      expect((await index()).lastProbeAt, isNull);
    },
  );

  test(
    'revoked projects do not prevent later projects or mark full success',
    () async {
      final adapter = FakeAdapter((r) {
        if (r.path.contains('/projects/1/') ||
            r.path.contains('/projects/2/')) {
          return jsonResponse({'message': 'forbidden'}, status: 403);
        }
        return jsonResponse({
          'commit': {'id': sha},
        });
      });
      final t = DateTime.utc(2026, 10, 28);
      await setup(adapter, [
        completeRecord(1, jobId, t),
        completeRecord(2, otherId, t),
        completeRecord(3, thirdId, t),
      ]);
      await prober.probeAll();
      final result = await index();
      expect(
        adapter.requests.map((r) => r.path),
        containsAll([
          contains('/projects/1/'),
          contains('/projects/2/'),
          contains('/projects/3/'),
        ]),
      );
      expect(result.snapshots.single.id, thirdId);
      expect(result.snapshots.single.probe, SnapshotProbe.ok);
      expect(result.lastProbeAt, isNull);
    },
  );

  test('different scopes queue while the same scope coalesces', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final adapter = FakeAdapter((r) async {
      if (r.path.contains('/projects/1/')) {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }
      return jsonResponse({
        'commit': {'id': sha},
      });
    });
    final t = DateTime.utc(2026, 10, 28);
    await setup(adapter, [
      completeRecord(1, jobId, t),
      completeRecord(2, otherId, t),
    ]);
    final first = prober.probeAll(projectId: 1);
    await entered.future;
    expect(identical(first, prober.probeAll(projectId: 1)), isTrue);
    final second = prober.probeAll(projectId: 2);
    release.complete();
    await Future.wait([first, second]);
    expect(adapter.requests.length, 2);
    expect(adapter.requests.last.path, contains('/projects/2/'));
  });

  test('preserves a concurrently updated live record', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final adapter = FakeAdapter((_) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return jsonResponse({
        'commit': {'id': sha},
      });
    });
    final t = DateTime.utc(2026, 10, 28);
    await setup(adapter, [completeRecord(1, jobId, t)]);
    final pending = prober.probeAll();
    await entered.future;
    final permit = owner.capture(binding, 0);
    await owner.maintain<void>(permit, (store, current) async {
      await store.writeIndex(
        current!.copyWith(
          snapshots: [current.snapshots.single.copyWith(interrupted: true)],
        ),
        expectedRevision: store.revision,
        mayCommit: () => permit.isCurrent,
      );
    });
    release.complete();
    await pending;
    expect((await index()).snapshots.single.interrupted, isTrue);
  });

  test(
    '24-hour debounce and branch missing with saved commit missing',
    () async {
      final adapter = FakeAdapter((r) {
        if (r.path.endsWith('/projects/1')) return jsonResponse({'id': 1});
        return jsonResponse({'message': 'not found'}, status: 404);
      });
      final t = DateTime.utc(2026, 10, 28);
      await setup(adapter, [completeRecord(1, jobId, t)], lastProbeAt: t);
      await prober.probeAll(ifDue: true);
      expect(adapter.requests, isEmpty);
      await prober.probeAll();
      expect(adapter.requests.length, 3);
      expect((await index()).snapshots.single.probe, SnapshotProbe.commitGone);
    },
  );

  test('concurrent sends recheck rate after pacing delay', () async {
    final waits = <Completer<void>>[];
    final durations = <Duration>[];
    final entered = Completer<void>();
    final release = Completer<void>();
    final adapter = FakeAdapter((r) async {
      if (r.path.endsWith('/1')) {
        entered.complete();
        await release.future;
      }
      return jsonResponse({'id': int.parse(r.path.split('/').last)});
    });
    await setup(
      adapter,
      [],
      delay: (d) {
        durations.add(d);
        final c = Completer<void>();
        waits.add(c);
        return c.future;
      },
    );
    final first = prober.validateProject(1);
    await entered.future;
    final second = prober.validateProject(2);
    while (waits.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(adapter.requests.length, 1);
    api.rateBudget.noteResponse(
      headers: {
        'retry-after': ['10'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.global,
      sequence: api.rateBudget.nextSequence(),
      trusted: true,
    );
    now = now.add(durations.first);
    waits.first.complete();
    while (waits.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(adapter.requests.length, 1);
    now = now.add(durations[1]);
    waits[1].complete();
    release.complete();
    await Future.wait([first, second]);
    expect(adapter.requests.length, 2);
    expect(
      now.difference(DateTime.utc(2026, 10, 28)),
      greaterThanOrEqualTo(const Duration(seconds: 10)),
    );
  });

  test('budget exhaustion waits until a lease is released', () async {
    final timer = Completer<void>();
    var delayCalls = 0;
    final adapter = FakeAdapter((_) => jsonResponse({'id': 1}));
    await setup(
      adapter,
      [],
      delay: (_) {
        delayCalls++;
        return timer.future;
      },
    );
    final leases = List.generate(3, (_) => api.runBudget.acquire(1)!);
    final pending = prober.validateProject(1);
    while (delayCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(delayCalls, 1);
    expect(adapter.requests, isEmpty);
    leases.first.release();
    await pending;
    expect(adapter.requests.length, 1);
    for (final lease in leases.skip(1)) {
      lease.release();
    }
    timer.complete();
  });

  test('zero-grant lease does not wake itself in a retry loop', () async {
    final timer = Completer<void>();
    var delayCalls = 0;
    final adapter = FakeAdapter((_) => jsonResponse({'id': 1}));
    await setup(
      adapter,
      [],
      delay: (_) {
        delayCalls++;
        return timer.future;
      },
    );
    api.rateBudget.noteResponse(
      headers: {
        'date': [HttpDate.format(now)],
        'ratelimit-reset': [
          '${now.add(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000}',
        ],
        'ratelimit-limit': ['100'],
        'ratelimit-remaining': ['45'],
      },
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: api.rateBudget.nextSequence(),
      trusted: true,
    );
    final first = api.runBudget.acquire(40)!;
    final second = api.runBudget.acquire(40)!;
    expect(second.granted, 1);
    final pending = prober.validateProject(1);
    while (delayCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(delayCalls, 1);
    expect(api.runBudget.activeLeases, 2);
    expect(adapter.requests, isEmpty);
    second.release();
    await pending;
    expect(adapter.requests.length, 1);
    first.release();
    timer.complete();
  });
}
