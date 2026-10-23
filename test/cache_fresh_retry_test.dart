import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _path = ['projects', '8', 'issues', '1'];

void main() {
  test(
    'two doubly superseded fresh reads impose a one-second quiet wait',
    () async {
      final responses = List.generate(4, (_) => Completer<ResponseBody>());
      var reads = 0;
      final adapter = FakeAdapter((request) {
        if (request.method != 'GET') return jsonResponse({'id': 1});
        final index = reads++;
        return index < responses.length
            ? responses[index].future
            : jsonResponse({'id': reads, 'title': 'settled'});
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await _produceSupersededFresh(api, responses, 0, () => reads);
      await _produceSupersededFresh(api, responses, 2, () => reads);

      final timerCreated = Completer<void>();
      _ControlledTimer? quietTimer;
      Duration? quietDelay;
      final third = runZoned(
        () async {
          final read = api.cachedRecord(_path, fresh: true);
          await timerCreated.future.timeout(_deadline);
          expect(reads, 4, reason: 'GET must wait for the quiet timer');
          quietTimer!.fire();
          return read.timeout(_deadline);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, delay, callback) {
            if (delay >= const Duration(milliseconds: 900) &&
                delay <= const Duration(seconds: 1)) {
              quietDelay = delay;
              quietTimer = _ControlledTimer(zone, callback);
              if (!timerCreated.isCompleted) timerCreated.complete();
              return quietTimer!;
            }
            return parent.createTimer(zone, delay, callback);
          },
        ),
      );

      final result = await third.timeout(_deadline);
      expect(quietDelay, isNotNull);
      expect(
        quietDelay!,
        greaterThanOrEqualTo(const Duration(milliseconds: 900)),
      );
      expect(result.value['title'], 'settled');
      expect(reads, 5);
    },
  );
}

Future<void> _produceSupersededFresh(
  GitLabApi api,
  List<Completer<ResponseBody>> responses,
  int first,
  int Function() readCount,
) async {
  final read = api.cachedRecord(_path, fresh: true);
  await _until(() => readCount() >= first + 1);
  await api.updateIssue(8, 1, {'title': 'write ${first + 1}'});
  responses[first].complete(jsonResponse({'title': 'old ${first + 1}'}));
  await _until(() => readCount() >= first + 2);
  await api.updateIssue(8, 1, {'title': 'write ${first + 2}'});
  responses[first + 1].complete(jsonResponse({'title': 'old ${first + 2}'}));
  expect((await read.timeout(_deadline)).superseded, isTrue);
}

GitLabApi _boundApi(FakeAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: dio,
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

final class _ControlledTimer implements Timer {
  _ControlledTimer(this.zone, this.callback);

  final Zone zone;
  final void Function() callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    zone.runGuarded(callback);
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}
