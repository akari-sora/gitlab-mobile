import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';

final class _NativeBack {
  _NativeBack(this.channel);

  final MethodChannel channel;
  final calls = <MethodCall>[];
  int floor = 0;
  bool active = false;
  Object? reply = <String, Object>{'version': 1, 'status': 'moved'};
  Future<Object?> Function()? probe;
  Future<Object?> Function()? move;
  static const permit = '11111111-1111-4111-8111-111111111111';

  List<MethodCall> named(String name) =>
      calls.where((call) => call.method == name).toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments! as Map<Object?, Object?>;
    final seq = args['opSeq']! as int;
    expect(seq, inInclusiveRange(1, 9007199254740991));
    if (seq <= floor) {
      return {
        'version': 1,
        'status': 'rejected',
        'reason': 'stale_operation',
        'opSeqFloor': floor,
      };
    }
    floor = seq;
    switch (call.method) {
      case 'updateProgress':
        expect(args.keys.toSet(), {'opSeq', 'permitId', 'workCount', 'step'});
        expect(args['permitId'], 'sequence-probe');
        expect(args['workCount'], 1);
        expect(args['step'], 0);
        return probe != null
            ? probe!()
            : {'version': 1, 'status': 'rejected', 'reason': 'permit_inactive'};
      case 'moveTaskToBack':
        expect(args.keys.toSet(), {'opSeq'});
        return move != null ? move!() : reply;
      case 'startRuns':
        active = true;
        return {
          'version': 1,
          'status': 'active',
          'permitId': permit,
          'startRequestId': args['startRequestId'],
          'opSeq': seq,
        };
      case 'releaseRuns':
        final wasActive = active;
        active = false;
        return {'version': 1, 'status': 'released', 'didRelease': wasActive};
      case 'stopAll':
        active = false;
        return {'version': 1, 'status': 'stopped'};
    }
    throw StateError('Unexpected method ${call.method}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeBack native;
  late AiBackgroundExecution owner;
  var channelNumber = 0;
  var current = true;
  var foreground = true;
  var eligible = true;

  Future<AiTaskBackResult> moveBack() =>
      owner.moveTaskToBack(isBackEligible: () => eligible);

  setUp(() {
    current = true;
    foreground = true;
    eligible = true;
    final channel = MethodChannel('mr6c-c6-back-${channelNumber++}');
    native = _NativeBack(channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, native.handle);
    owner = AiBackgroundExecution(
      backgroundEnabled: true,
      accountKey: 'synthetic-back-account',
      generation: 1,
      ownerApi: Object(),
      isCurrent: () => current,
      appInForeground: () => foreground,
      channel: channel,
    );
  });

  tearDown(() async {
    owner.dispose();
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native.channel, null);
  });

  test('explicit back seeds safely then invokes native exactly once', () async {
    expect(await moveBack(), AiTaskBackResult.moved);
    expect(native.calls.map((call) => call.method), [
      'updateProgress',
      'moveTaskToBack',
    ]);
    final probeArgs = native.calls.first.arguments! as Map<Object?, Object?>;
    final moveArgs = native.calls.last.arguments! as Map<Object?, Object?>;
    expect(moveArgs['opSeq']! as int, greaterThan(probeArgs['opSeq']! as int));
    expect(native.active, isFalse);
    expect(owner.status, AiBackgroundExecutionStatus.foregroundOnly);
  });

  test('ordinary service startup never invokes task back', () async {
    final gate = owner.createGate(
      conversationId: () => 'synthetic-conversation',
      isCurrent: () => true,
    );
    expect(
      (await owner.startRuns(gate)).disposition,
      AiBackgroundStartDisposition.active,
    );
    expect(native.named('moveTaskToBack'), isEmpty);
    expect(native.named('startRuns'), hasLength(1));
    expect(native.active, isTrue);
  });

  test('stale probe seeds the floor without replaying movement', () async {
    native.floor = 7000000000000;
    expect(await moveBack(), AiTaskBackResult.moved);
    expect(native.named('updateProgress'), hasLength(1));
    expect(native.named('moveTaskToBack'), hasLength(1));
    final args =
        native.named('moveTaskToBack').single.arguments!
            as Map<Object?, Object?>;
    expect(args['opSeq']! as int, greaterThan(7000000000000));
  });

  test(
    'each explicit back uses one fresh sequence and no new service',
    () async {
      expect(await moveBack(), AiTaskBackResult.moved);
      expect(await moveBack(), AiTaskBackResult.moved);
      expect(native.named('updateProgress'), hasLength(1));
      final moves = native.named('moveTaskToBack');
      expect(moves, hasLength(2));
      expect(
        (moves.last.arguments! as Map<Object?, Object?>)['opSeq']! as int,
        greaterThan(
          (moves.first.arguments! as Map<Object?, Object?>)['opSeq']! as int,
        ),
      );
      expect(native.named('startRuns'), isEmpty);
    },
  );

  test('moving a task preserves the active run and its permit', () async {
    final gate = owner.createGate(
      conversationId: () => 'synthetic-conversation',
      isCurrent: () => true,
    );
    await owner.startRuns(gate);
    final binding = gate.binding;
    expect(await moveBack(), AiTaskBackResult.moved);
    expect(gate.binding, same(binding));
    expect(gate.binding.permitId, _NativeBack.permit);
    expect(native.active, isTrue);
    expect(owner.status, AiBackgroundExecutionStatus.active);
    expect(native.named('releaseRuns'), isEmpty);
    expect(native.named('stopAll'), isEmpty);
  });

  test(
    'unsupported host returns typed unsupported without a channel',
    () async {
      final unsupported = AiBackgroundExecution(
        backgroundEnabled: true,
        accountKey: 'synthetic-unsupported-account',
        generation: 1,
        ownerApi: Object(),
        isCurrent: () => true,
        appInForeground: () => true,
      );
      addTearDown(unsupported.dispose);
      expect(
        await unsupported.moveTaskToBack(isBackEligible: () => true),
        AiTaskBackResult.unsupported,
      );
      expect(native.calls, isEmpty);
    },
  );

  test('hidden owner sends no probe and no movement', () async {
    foreground = false;
    expect(await moveBack(), AiTaskBackResult.foregroundRequired);
    expect(native.calls, isEmpty);
  });

  test('stale owner sends no probe and no movement', () async {
    current = false;
    expect(await moveBack(), AiTaskBackResult.unavailable);
    expect(native.calls, isEmpty);
  });

  test('ineligible shell sends no probe and no movement', () async {
    eligible = false;
    expect(await moveBack(), AiTaskBackResult.notEligible);
    expect(native.calls, isEmpty);
  });

  for (final change in ['detail opened', 'last work ended', 'app locked']) {
    test('$change during probe prevents native movement', () async {
      native.probe = () async {
        eligible = false;
        return {
          'version': 1,
          'status': 'rejected',
          'reason': 'permit_inactive',
        };
      };
      expect(await moveBack(), AiTaskBackResult.notEligible);
      expect(native.named('moveTaskToBack'), isEmpty);
    });
  }

  test('hidden during probe never sends movement', () async {
    native.probe = () async {
      foreground = false;
      return {'version': 1, 'status': 'rejected', 'reason': 'permit_inactive'};
    };
    expect(await moveBack(), AiTaskBackResult.foregroundRequired);
    expect(native.named('moveTaskToBack'), isEmpty);
  });

  test('owner changed during probe never sends movement', () async {
    native.probe = () async {
      current = false;
      return {'version': 1, 'status': 'rejected', 'reason': 'permit_inactive'};
    };
    expect(await moveBack(), AiTaskBackResult.unavailable);
    expect(native.named('moveTaskToBack'), isEmpty);
  });

  test('queued back rechecks visibility before another native call', () async {
    final pending = Completer<Object?>();
    native.move = () => pending.future;
    final first = moveBack();
    await Future<void>.delayed(Duration.zero);
    final queued = moveBack();
    foreground = false;
    pending.complete({'version': 1, 'status': 'moved'});
    expect(await first, AiTaskBackResult.moved);
    expect(await queued, AiTaskBackResult.foregroundRequired);
    expect(native.named('moveTaskToBack'), hasLength(1));
  });

  test('queued back rechecks shell eligibility before another call', () async {
    final pending = Completer<Object?>();
    native.move = () => pending.future;
    final first = moveBack();
    await Future<void>.delayed(Duration.zero);
    final queued = moveBack();
    eligible = false;
    pending.complete({'version': 1, 'status': 'moved'});
    expect(await first, AiTaskBackResult.moved);
    expect(await queued, AiTaskBackResult.notEligible);
    expect(native.named('moveTaskToBack'), hasLength(1));
  });

  test('unrecognized probe response never sends movement', () async {
    native.probe = () async => {'version': 1, 'status': 'updated'};
    expect(await moveBack(), AiTaskBackResult.unavailable);
    expect(native.named('moveTaskToBack'), isEmpty);
  });

  test(
    'late successful reply cannot report success to a changed owner',
    () async {
      native.move = () async {
        current = false;
        return {'version': 1, 'status': 'moved'};
      };
      expect(await moveBack(), AiTaskBackResult.unavailable);
      expect(native.named('moveTaskToBack'), hasLength(1));
    },
  );

  test('foreground may change after a successful actual movement', () async {
    native.move = () async {
      foreground = false;
      return {'version': 1, 'status': 'moved'};
    };
    expect(await moveBack(), AiTaskBackResult.moved);
  });

  for (final (reply, expected) in <(Map<String, Object?>, AiTaskBackResult)>[
    ({'version': 1, 'status': 'not_moved'}, AiTaskBackResult.notMoved),
    (
      {'version': 1, 'status': 'unsupported', 'reason': 'not_implemented'},
      AiTaskBackResult.unsupported,
    ),
    (
      {'version': 1, 'status': 'rejected', 'reason': 'foreground_required'},
      AiTaskBackResult.foregroundRequired,
    ),
    (
      {'version': 1, 'status': 'rejected', 'reason': 'unavailable'},
      AiTaskBackResult.unavailable,
    ),
    (
      {'version': 1, 'status': 'rejected', 'reason': 'security_exception'},
      AiTaskBackResult.failed,
    ),
    (
      {'version': 1, 'status': 'rejected', 'reason': 'move_failed'},
      AiTaskBackResult.failed,
    ),
    (
      {'version': 1, 'status': 'rejected', 'reason': 'invalid_arguments'},
      AiTaskBackResult.failed,
    ),
    (
      {
        'version': 1,
        'status': 'rejected',
        'reason': 'stale_operation',
        'opSeqFloor': 7000000000001,
      },
      AiTaskBackResult.failed,
    ),
  ]) {
    test('typed native result $reply', () async {
      native.reply = reply;
      expect(await moveBack(), expected);
      expect(native.named('moveTaskToBack'), hasLength(1));
    });
  }

  for (final reply in <Object?>[
    null,
    true,
    <Object?>[],
    {'version': 2, 'status': 'moved'},
    {'version': 1.0, 'status': 'moved'},
    {'version': 1, 'status': true},
    {'version': 1, 'status': 'moved', 'extra': true},
    {'version': 1, 'status': 'not_moved', 'extra': true},
    {'version': 1, 'status': 'active'},
    {'version': 1, 'status': 'rejected', 'reason': 'unknown'},
    {'version': 1, 'status': 'rejected'},
    {'version': 1, 'status': 'unsupported', 'reason': 'unknown'},
    {
      'version': 1,
      'status': 'rejected',
      'reason': 'stale_operation',
      'opSeqFloor': 1.0,
    },
    {
      'version': 1,
      'status': 'rejected',
      'reason': 'stale_operation',
      'opSeqFloor': 0,
    },
  ]) {
    test('malformed reply fails closed: $reply', () async {
      native.reply = reply;
      expect(await moveBack(), AiTaskBackResult.unavailable);
      expect(native.named('moveTaskToBack'), hasLength(1));
    });
  }

  for (final error in <Object>[
    MissingPluginException(),
    PlatformException(
      code: 'synthetic_error',
      message: 'private native detail',
    ),
  ]) {
    test('channel exception is typed and never retried: $error', () async {
      native.move = () async => throw error;
      expect(await moveBack(), AiTaskBackResult.unavailable);
      expect(native.named('moveTaskToBack'), hasLength(1));
    });
  }

  test('movement timeout is typed and a late reply never retries', () async {
    final pending = Completer<Object?>();
    native.move = () => pending.future;
    final future = moveBack();
    expect(await future, AiTaskBackResult.unavailable);
    pending.complete({'version': 1, 'status': 'moved'});
    await Future<void>.delayed(Duration.zero);
    expect(native.named('moveTaskToBack'), hasLength(1));
    expect(native.named('startRuns'), isEmpty);
  });
}
