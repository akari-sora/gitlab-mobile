import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/request_meter.dart';

void main() {
  test('zone meter counts physical sends across awaits and failures', () async {
    final meter = RequestMeter();

    await expectLater(
      meter.runAsync(() async {
        expect(RequestMeter.current, same(meter));
        RequestMeter.current?.increment();
        await Future<void>.delayed(Duration.zero);
        RequestMeter.current?.increment();
        throw StateError('sent then failed');
      }),
      throwsStateError,
    );

    expect(meter.count, 2);
    expect(RequestMeter.current, isNull);
  });

  test(
    'nested operations use the innermost meter and restore the outer one',
    () {
      final outer = RequestMeter();
      final inner = RequestMeter();

      outer.run(() {
        RequestMeter.current?.increment();
        inner.run(() => RequestMeter.current?.increment());
        RequestMeter.current?.increment();
      });

      expect(outer.count, 2);
      expect(inner.count, 1);
    },
  );

  test(
    'joined work naturally records zero when no physical send occurs',
    () async {
      final meter = RequestMeter();
      final result = await meter.runAsync(() async => 42);

      expect(result, 42);
      expect(meter.count, 0);
    },
  );
}
