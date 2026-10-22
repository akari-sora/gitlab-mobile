import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/request_meter.dart';

import 'support/fake_adapter.dart';

const _path = ['projects', '8', 'issues', '1'];

void main() {
  test(
    'a collection 404 cannot revoke an unrelated project publication',
    () async {
      final project = Completer<ResponseBody>();
      final adapter = FakeAdapter(
        (request) => request.uri.path.endsWith('/projects/8')
            ? project.future
            : jsonResponse({}, status: 404),
      );
      final api = _api(adapter);
      addTearDown(api.close);
      final reading = api.cachedRecord(['projects', '8']);
      await _until(() => adapter.requests.isNotEmpty);
      await expectLater(api.records(['projects']), throwsA(isA<ApiFailure>()));
      project.complete(jsonResponse(projectJson(8)));
      expect((await reading.timeout(_deadline)).value['id'], 8);
      expect(
        (await api.cachedRecord(['projects', '8'])).lineage,
        CacheLineage.memory,
      );
    },
  );

  test(
    'old pre-write response retries and cannot replace patched state',
    () async {
      final old = Completer<ResponseBody>();
      var reads = 0;
      final adapter = FakeAdapter((r) {
        if (r.method != 'GET') return jsonResponse({'id': 1});
        if (++reads == 1) return old.future;
        return jsonResponse({'title': 'new'});
      });
      final api = _api(adapter);
      addTearDown(api.close);
      final pending = api.cachedRecord(_path);
      await _until(() => reads == 1);
      await api.updateIssue(8, 1, {'title': 'new'});
      old.complete(jsonResponse({'title': 'old'}));
      final result = await pending.timeout(_deadline);
      expect(result.value['title'], 'new');
      expect(result.superseded, isFalse);
      expect((await api.cachedRecord(_path)).value['title'], 'new');
      expect(reads, 2);
    },
  );

  test('second read crossing a write is superseded and never stored', () async {
    final gates = [Completer<ResponseBody>(), Completer<ResponseBody>()];
    var reads = 0;
    final adapter = FakeAdapter((r) {
      if (r.method != 'GET') return jsonResponse({'id': 1});
      final index = reads++;
      return index < 2 ? gates[index].future : jsonResponse({'title': 'new'});
    });
    final api = _api(adapter);
    addTearDown(api.close);
    final pending = api.cachedRecord(_path);
    await _until(() => reads == 1);
    await api.updateIssue(8, 1, {'title': 'write 1'});
    gates[0].complete(jsonResponse({'title': 'old 1'}));
    await _until(() => reads == 2);
    await api.updateIssue(8, 1, {'title': 'write 2'});
    gates[1].complete(jsonResponse({'title': 'old 2'}));
    expect((await pending.timeout(_deadline)).superseded, isTrue);
    expect((await api.cachedRecord(_path)).value['title'], 'new');
    expect(reads, 3);
  });

  test(
    'read waits for related write; unrelated project reads proceed',
    () async {
      final writing = Completer<ResponseBody>();
      final adapter = FakeAdapter(
        (r) => r.method == 'PUT' ? writing.future : jsonResponse({'id': 1}),
      );
      final api = _api(adapter);
      addTearDown(api.close);
      final write = api.updateIssue(8, 1, {'title': 'new'});
      await _until(() => adapter.requests.isNotEmpty);
      final related = api.cachedRecord(_path);
      await api.cachedRecord(['projects', '9', 'issues', '1']);
      expect(adapter.requests.where((r) => r.method == 'GET'), hasLength(1));
      writing.complete(jsonResponse({'id': 1}));
      await write;
      expect((await related.timeout(_deadline)).superseded, isFalse);
      expect(adapter.requests.where((r) => r.method == 'GET'), hasLength(2));
    },
  );

  test(
    '30-second write barrier timeout sends stale result without storing',
    () async {
      var sawDeadline = false;
      await runZoned(
        () async {
          final writing = Completer<ResponseBody>();
          var reads = 0;
          final adapter = FakeAdapter((r) {
            if (r.method == 'PUT') return writing.future;
            return jsonResponse({'id': ++reads});
          });
          final api = _api(adapter);
          addTearDown(api.close);
          final write = api.updateIssue(8, 1, {'title': 'new'});
          await _until(() => adapter.requests.isNotEmpty);
          final result = await api.cachedRecord(_path).timeout(_deadline);
          expect(result.stale, isTrue);
          expect(result.superseded, isFalse);
          writing.complete(jsonResponse({'id': 1}));
          await write;
          expect((await api.cachedRecord(_path)).value['id'], 2);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, delay, callback) {
            if (delay > const Duration(seconds: 29) &&
                delay <= const Duration(seconds: 30)) {
              sawDeadline = true;
              return parent.createTimer(
                zone,
                const Duration(milliseconds: 5),
                callback,
              );
            }
            return parent.createTimer(zone, delay, callback);
          },
        ),
      );
      expect(sawDeadline, isTrue);
    },
  );

  test(
    'permission error revokes waiting publication even after successful HTTP',
    () async {
      final old = Completer<ResponseBody>();
      var calls = 0;
      final adapter = FakeAdapter(
        (_) => ++calls == 1 ? old.future : jsonResponse({}, status: 403),
      );
      final api = _api(adapter);
      addTearDown(api.close);
      final waiting = api.cachedRecord(_path);
      final rejected = expectLater(
        waiting,
        throwsA(
          isA<ApiFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      await _until(() => calls == 1);
      await expectLater(api.record(_path), throwsA(isA<ApiFailure>()));
      old.complete(jsonResponse({'title': 'revoked'}));
      await rejected.timeout(_deadline);
    },
  );

  test(
    'fresh bypasses coalescing and writes through to the canonical entry',
    () async {
      final firstGate = Completer<ResponseBody>();
      var calls = 0;
      final adapter = FakeAdapter(
        (_) => ++calls == 1 ? firstGate.future : jsonResponse({'id': calls}),
      );
      final api = _api(adapter);
      addTearDown(api.close);
      final first = api.cachedRecord(_path);
      await _until(() => calls == 1);
      expect((await api.cachedRecord(_path, fresh: true)).value['id'], 2);
      expect(calls, 2);
      firstGate.complete(jsonResponse({'id': 1}));
      await first;
      // A later-started refresh owns publication even when the old HTTP is last.
      expect((await api.cachedRecord(_path)).value['id'], 2);
    },
  );

  test(
    'foreground read 17 queues and preserves each caller meter zone',
    () async {
      final gate = Completer<void>();
      var active = 0, peak = 0;
      final adapter = FakeAdapter((_) async {
        active++;
        if (active > peak) peak = active;
        await gate.future;
        active--;
        return jsonResponse({'id': 1});
      });
      final api = _api(adapter);
      addTearDown(api.close);
      final meters = List.generate(17, (_) => RequestMeter());
      final reads = [
        for (var i = 0; i < 17; i++)
          meters[i].runAsync(
            () => api.cachedRecord(['projects', '8', 'issues', '$i']),
          ),
      ];
      await _until(() => adapter.requests.length == 16);
      expect(meters[16].count, 0);
      gate.complete();
      await Future.wait(reads).timeout(_deadline);
      expect(adapter.requests, hasLength(17));
      expect(peak, 16);
      expect(meters.map((m) => m.count), everyElement(1));
    },
  );

  test(
    'background cap four, queue32, oldest admission explicitly dropped',
    () async {
      final gate = Completer<void>();
      final adapter = FakeAdapter((_) async {
        await gate.future;
        return jsonResponse({'id': 1});
      });
      final api = _api(adapter);
      addTearDown(api.close);
      final reads = [
        for (var i = 0; i < 37; i++)
          api.cachedRecord(
            ['projects', '8', 'issues', '$i'],
            fresh: true,
            background: true,
          ),
      ];
      await _until(() => adapter.requests.length == 4);
      final dropped = await reads[4].timeout(_deadline);
      expect(dropped.dropped, isTrue);
      expect(() => dropped.value, throwsStateError);
      gate.complete();
      final results = await Future.wait(reads).timeout(_deadline);
      expect(results.where((r) => r.dropped), hasLength(1));
      expect(adapter.requests, hasLength(36));
    },
  );

  test(
    'close releases all queued admissions and cancels in-flight publication',
    () async {
      final gate = Completer<void>();
      final adapter = FakeAdapter((_) async {
        await gate.future;
        return jsonResponse({'id': 1});
      });
      final api = _api(adapter);
      final reads = [
        for (var i = 0; i < 18; i++)
          expectLater(
            api.cachedRecord(['projects', '8', 'issues', '$i']),
            throwsA(
              isA<ApiFailure>().having(
                (f) => f.kind,
                'kind',
                FailureKind.cancelled,
              ),
            ),
          ),
      ];
      await _until(() => adapter.requests.length == 16);
      api.close();
      gate.complete();
      await Future.wait(reads).timeout(_deadline);
    },
  );
}

const _deadline = Duration(seconds: 20);
GitLabApi _api(FakeAdapter adapter) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

Future<void> _until(bool Function() done) async {
  final until = DateTime.now().add(_deadline);
  while (!done()) {
    if (!DateTime.now().isBefore(until)) {
      throw TimeoutException('condition', _deadline);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
