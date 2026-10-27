import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'fx_coord_support.dart' as fx;
import 'mr6c_support.dart';

const _channel = MethodChannel('io.gitlabmobile/agent_runs');

/// A native protocol peer, not a fake Dart execution gate. The call list is
/// intentionally synthetic and never contains a chat, account, or repository.
final class _Native {
  final calls = <MethodCall>[];
  int floor = 0;
  bool active = false;
  bool releaseMatches = true;
  bool denyMutation = false;
  bool malformedTicket = false;
  bool rejectStart = false;
  Completer<Object?>? delayedStart;
  Completer<Object?>? delayedRelease;
  Completer<Object?>? delayedRequestRelease;
  Completer<Object?>? delayedProgress;
  Completer<Object?>? delayedStop;
  Completer<Object?>? delayedTicket;
  String permit = 'permit-1';
  int _tickets = 0;
  void Function(MethodCall)? onCall;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handle);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  List<MethodCall> named(String method) =>
      calls.where((call) => call.method == method).toList();

  Map<Object?, Object?> args(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    onCall?.call(call);
    final a = args(call);
    final seq = a['opSeq']! as int;
    if (call.method == 'startRuns' && delayedStart != null) {
      return delayedStart!.future;
    }
    if (call.method == 'releaseRuns' &&
        delayedRelease != null &&
        a.containsKey('permitId')) {
      return delayedRelease!.future;
    }
    if (call.method == 'releaseRuns' &&
        a.containsKey('startRequestId') &&
        delayedRequestRelease != null) {
      return delayedRequestRelease!.future;
    }
    if (call.method == 'updateProgress' && delayedProgress != null) {
      return delayedProgress!.future;
    }
    if (call.method == 'stopAll' && delayedStop != null) {
      return delayedStop!.future;
    }
    if (call.method == 'acquireContinuation' && delayedTicket != null) {
      return delayedTicket!.future;
    }
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
      case 'moveTaskToBack':
        return {
          'version': 1,
          'status': 'unsupported',
          'reason': 'not_implemented',
        };
      case 'startRuns':
        if (rejectStart) {
          return {
            'version': 1,
            'status': 'rejected',
            'reason': 'foreground_required',
          };
        }
        active = true;
        return {
          'version': 1,
          'status': 'active',
          'permitId': permit,
          'startRequestId': a['startRequestId'],
          'opSeq': seq,
        };
      case 'releaseRuns':
        final didRelease = active && releaseMatches;
        if (didRelease) active = false;
        return {'version': 1, 'status': 'released', 'didRelease': didRelease};
      case 'stopAll':
        active = false;
        return {'version': 1, 'status': 'stopped'};
      case 'updateProgress':
        if (!active) return _inactive();
        return {'version': 1, 'status': 'updated', 'permitId': permit};
      case 'acquireContinuation':
        if (!active || (denyMutation && a['kind'] == 'mutation')) {
          active = false;
          return _inactive();
        }
        return {
          'version': 1,
          'status': 'ticket',
          'permitId': malformedTicket ? 'different-permit' : a['permitId'],
          'kind': a['kind'],
          'nonce': a['nonce'],
          'ticketId':
              '00000000-0000-4000-8000-${(++_tickets).toString().padLeft(12, '0')}',
        };
    }
    throw StateError('Unexpected native method ${call.method}');
  }

  Map<String, Object> _inactive() => {
    'version': 1,
    'status': 'rejected',
    'reason': 'permit_inactive',
  };
}

AiBackgroundExecution _owner(
  _Native native, {
  bool Function()? foreground,
  Mr6cClock? clock,
  bool Function()? current,
}) => AiBackgroundExecution(
  accountKey: 'synthetic-account',
  generation: 8,
  ownerApi: Object(),
  isCurrent: current ?? () => true,
  appInForeground: foreground ?? () => true,
  channel: _channel,
  clock: clock?.now,
);

AiBackgroundRunGate _gate(AiBackgroundExecution owner, String id) =>
    owner.createGate(conversationId: () => id, isCurrent: () => true);

Future<void> _invalidate(_Native native, String reason) async {
  native.active = false;
  final replied = Completer<void>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('permitInvalidated', {
            'version': 1,
            'permitId': native.permit,
            'reason': reason,
          }),
        ),
        (_) => replied.complete(),
      );
  await replied.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Native native;
  setUp(() {
    native = _Native()..install();
  });
  tearDown(() {
    native.uninstall();
    useLanguage(sourceLanguage);
  });

  test('sequence floor is seeded before the first real start', () async {
    native.floor = 900000;
    final owner = _owner(native);
    addTearDown(owner.dispose);
    final gate = _gate(owner, 'conversation');
    gate.setWork(active: true, backProtected: true);
    await gate.beginRun(runId: 'run-1');
    final call = native.named('startRuns').single;
    expect(native.args(call)['opSeq'] as int, greaterThan(900000));
    expect(gate.binding.permitId, native.permit);
    expect(native.args(call)['title'], l10n.aiRunServiceTitle);
    expect(native.args(call)['text'], l10n.aiRunServiceText);
  });

  test('beginRun notifies the final per-gate active status', () async {
    final owner = _owner(native);
    addTearDown(owner.dispose);
    final gate = _gate(owner, 'conversation');
    final statuses = <AiBackgroundExecutionStatus>[];
    owner.addListener(() => statuses.add(gate.status));
    await gate.beginRun(runId: 'run-1');
    expect(statuses.last, AiBackgroundExecutionStatus.active);
  });

  test(
    'three runs share a permit and a fourth never starts a service',
    () async {
      final owner = _owner(native);
      addTearDown(owner.dispose);
      final gates = [for (var i = 0; i < 4; i++) _gate(owner, 'c$i')];
      for (var i = 0; i < 3; i++) {
        gates[i].setWork(active: true, backProtected: true);
        await gates[i].beginRun(runId: 'run-$i');
      }
      final startsBeforeFourth = native.named('startRuns').length;
      gates[3].setWork(active: true, backProtected: true);
      await expectLater(
        gates[3].beginRun(runId: 'run-3'),
        throwsA(isA<AiExecutionPaused>()),
      );
      expect(native.named('startRuns'), hasLength(startsBeforeFourth));
      expect(gates.take(3).map((g) => g.binding.permitId).toSet(), {
        native.permit,
      });
      expect(gates[3].binding.permitId, isNull);
    },
  );

  test(
    'ticket binds reply, run, kind, nonce and total monotonic TTL',
    () async {
      final clock = Mr6cClock();
      final owner = _owner(native, clock: clock);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      gate.setWork(active: true, backProtected: true);
      await gate.beginRun(runId: 'run-1');
      final ticket = await gate.acquire(AiContinuationKind.model);
      clock.advance(const Duration(milliseconds: 1000));
      expect(
        () => ticket.consumeOnce(
          binding: gate.binding,
          kind: AiContinuationKind.model,
        ),
        throwsA(
          isA<AiExecutionPaused>().having(
            (e) => e.pause.reason,
            'reason',
            AiExecutionPauseReason.ticketExpired,
          ),
        ),
      );
      native.malformedTicket = true;
      await expectLater(
        gate.acquire(AiContinuationKind.mutation),
        throwsA(isA<AiExecutionPaused>()),
      );
    },
  );

  test(
    'lost invalidation callback cannot keep a rejected permit usable',
    () async {
      var visible = true;
      final owner = _owner(native, foreground: () => visible);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      gate.setWork(active: true, backProtected: true);
      await gate.beginRun(runId: 'run-1');
      visible = false;
      native.active =
          false; // Native service died; do not deliver its callback.
      await expectLater(
        gate.acquire(AiContinuationKind.model),
        throwsA(isA<AiExecutionPaused>()),
      );
      expect(gate.executionEligible, isFalse);
      visible = true;
      expect(gate.executionEligible, isFalse);
      await expectLater(
        gate.acquire(AiContinuationKind.model),
        throwsA(isA<AiExecutionPaused>()),
      );
    },
  );

  testWidgets(
    'different owner waits for old permit release before a fresh start',
    (tester) async {
      final a = _owner(native);
      addTearDown(a.dispose);
      final b = _owner(native);
      addTearDown(b.dispose);
      final ga = _gate(a, 'a')..setWork(active: true, backProtected: true);
      final gb = _gate(b, 'b')..setWork(active: true, backProtected: true);
      final first = ga.beginRun(runId: 'a-1');
      await tester.pump();
      await first;
      final blocked = gb.beginRun(runId: 'b-1');
      await tester.pump();
      await blocked;
      expect(gb.binding.permitId, isNull);
      expect(native.named('startRuns'), hasLength(1));
      native.delayedRelease = Completer<Object?>();
      a.dispose();
      await tester.pump();
      final release = native.named('releaseRuns').single;
      final waiting = gb.beginRun(runId: 'b-2');
      await tester.pump();
      expect(native.named('startRuns'), hasLength(1));
      native.active = false;
      native.permit = 'permit-2';
      native.delayedRelease!.complete({
        'version': 1,
        'status': 'released',
        'didRelease': true,
      });
      native.delayedRelease = null;
      await tester.pump();
      await waiting;
      expect(gb.binding.permitId, 'permit-2');
      expect(native.named('startRuns'), hasLength(2));
      expect(
        native.args(native.named('startRuns').last)['opSeq'] as int,
        greaterThan(native.args(release)['opSeq'] as int),
      );
      expect(native.named('releaseRuns'), hasLength(1));
      b.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'disposed pending owner cannot overlap a new owner before cleanup',
    (tester) async {
      native.delayedStart = Completer<Object?>();
      native.delayedRequestRelease = Completer<Object?>();
      final a = _owner(native);
      addTearDown(a.dispose);
      final b = _owner(native);
      addTearDown(b.dispose);
      final ga = _gate(a, 'a')..setWork(active: true, backProtected: true);
      final gb = _gate(b, 'b')..setWork(active: true, backProtected: true);
      final starting = ga.beginRun(runId: 'a-1');
      await tester.pump();
      final start = native.args(native.named('startRuns').single);
      a.dispose();
      await tester.pump();
      final blocked = gb.beginRun(runId: 'b-1');
      await tester.pump();
      expect(native.named('startRuns'), hasLength(1));
      native.delayedStart!.complete({
        'version': 1,
        'status': 'active',
        'permitId': 'permit-1',
        'startRequestId': start['startRequestId'],
        'opSeq': start['opSeq'],
      });
      native.delayedStart = null;
      await tester.pump();
      expect(native.named('startRuns'), hasLength(1));
      expect(gb.binding.permitId, isNull);
      final cleanup = native.named('releaseRuns').single;
      native.active = false;
      native.permit = 'permit-2';
      native.delayedRequestRelease!.complete({
        'version': 1,
        'status': 'released',
        'didRelease': true,
      });
      native.delayedRequestRelease = null;
      await tester.pump();
      await starting;
      await blocked;
      expect(gb.binding.permitId, 'permit-2');
      expect(native.named('startRuns'), hasLength(2));
      expect(
        native.args(native.named('startRuns').last)['opSeq'] as int,
        greaterThan(native.args(cleanup)['opSeq'] as int),
      );
      b.dispose();
      await tester.pump();
    },
  );

  testWidgets('orphan survives owner disposal until foreground stopAll', (
    tester,
  ) async {
    native.delayedStart = Completer<Object?>();
    native.delayedRequestRelease = Completer<Object?>();
    final a = _owner(native);
    addTearDown(a.dispose);
    final ga = _gate(a, 'a')..setWork(active: true, backProtected: true);
    final starting = ga.beginRun(runId: 'a-1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1001));
    await starting;
    await tester.pump(const Duration(milliseconds: 1001));
    a.dispose();
    await tester.pump();
    final b = _owner(native);
    addTearDown(b.dispose);
    final gb = _gate(b, 'b')..setWork(active: true, backProtected: true);
    final blocked = gb.beginRun(runId: 'b-1');
    await tester.pump();
    await blocked;
    expect(native.named('startRuns'), hasLength(1));
    expect(gb.binding.permitId, isNull);
    final clearing = b.onForeground();
    await tester.pump();
    await clearing;
    expect(native.named('stopAll'), hasLength(1));
    native.delayedStart = null;
    native.delayedRequestRelease = null;
    native.permit = 'permit-2';
    final fresh = gb.beginRun(runId: 'b-2');
    await tester.pump();
    await fresh;
    expect(gb.binding.permitId, 'permit-2');
    b.dispose();
    await tester.pump();
  });

  testWidgets('cross-owner stop immediately revokes gate and issued ticket', (
    tester,
  ) async {
    final a = _owner(native);
    addTearDown(a.dispose);
    final b = _owner(native);
    addTearDown(b.dispose);
    final ga = _gate(a, 'a')..setWork(active: true, backProtected: true);
    final start = ga.beginRun(runId: 'a-1');
    await tester.pump();
    await start;
    final ticketFuture = ga.acquire(AiContinuationKind.model);
    await tester.pump();
    final ticket = await ticketFuture;
    native.delayedStop = Completer<Object?>();
    final stopped = b.stopAll();
    expect(ga.executionEligible, isFalse);
    expect(
      () => ticket.consumeOnce(
        binding: ga.binding,
        kind: AiContinuationKind.model,
      ),
      throwsA(isA<AiExecutionPaused>()),
    );
    await tester.pump();
    expect(native.named('stopAll'), hasLength(1));
    native.active = false;
    native.delayedStop!.complete({'version': 1, 'status': 'stopped'});
    native.delayedStop = null;
    await tester.pump();
    await stopped;
    a.dispose();
    b.dispose();
    await tester.pump();
  });

  testWidgets('gate status remains independent across owners and idle gates', (
    tester,
  ) async {
    final a = _owner(native);
    addTearDown(a.dispose);
    final ga = _gate(a, 'a')..setWork(active: true, backProtected: true);
    final first = ga.beginRun(runId: 'a-1');
    await tester.pump();
    await first;
    final stop = a.stopAll();
    await tester.pump();
    await stop;
    final b = _owner(native);
    addTearDown(b.dispose);
    final gb = _gate(b, 'b')..setWork(active: true, backProtected: true);
    final idle = _gate(b, 'idle');
    native.permit = 'permit-2';
    final second = gb.beginRun(runId: 'b-1');
    await tester.pump();
    await second;
    expect(ga.status, AiBackgroundExecutionStatus.invalidated);
    expect(gb.status, AiBackgroundExecutionStatus.active);
    expect(idle.status, AiBackgroundExecutionStatus.foregroundOnly);
    a.dispose();
    b.dispose();
    await tester.pump();
  });

  testWidgets('normal release is ordered before a later visible start', (
    tester,
  ) async {
    final owner = _owner(native);
    addTearDown(owner.dispose);
    final first = _gate(owner, 'first');
    first.setWork(active: true, backProtected: true);
    final initialStart = first.beginRun(runId: 'first-run');
    await tester.pump();
    await initialStart;
    native.delayedRelease = Completer<Object?>();
    first.release();
    await tester.pump();
    final release = native.named('releaseRuns').single;
    final second = _gate(owner, 'second');
    second.setWork(active: true, backProtected: true);
    final secondStart = second.beginRun(runId: 'second-run');
    await tester.pump();
    expect(native.named('startRuns'), hasLength(1));
    native.active = false;
    native.delayedRelease!.complete({
      'version': 1,
      'status': 'released',
      'didRelease': true,
    });
    await tester.pump();
    await secondStart;
    final start = native.named('startRuns').last;
    expect(
      native.args(start)['opSeq'] as int,
      greaterThan(native.args(release)['opSeq'] as int),
    );
    expect(second.binding.permitId, native.permit);
    owner.dispose();
  });

  testWidgets(
    'start timeout sends a newer request cleanup and late active cannot revive it',
    (tester) async {
      native.delayedStart = Completer<Object?>();
      // The native service started; only its active reply is delayed.
      native.active = true;
      final owner = _owner(native);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      gate.setWork(active: true, backProtected: true);
      final starting = gate.beginRun(runId: 'run-1');
      await tester.pump();
      final start = native.named('startRuns').single;
      final startArgs = native.args(start);
      await tester.pump(const Duration(milliseconds: 1001));
      await tester.pump();
      final cleanup = native.named('releaseRuns').single;
      expect(
        native.args(cleanup)['startRequestId'],
        startArgs['startRequestId'],
      );
      expect(
        native.args(cleanup)['opSeq'] as int,
        greaterThan(startArgs['opSeq'] as int),
      );
      native.delayedStart!.complete({
        'version': 1,
        'status': 'active',
        'permitId': native.permit,
        'startRequestId': startArgs['startRequestId'],
        'opSeq': startArgs['opSeq'],
      });
      await tester.pump();
      await starting;
      expect(gate.binding.permitId, isNull);
    },
  );

  testWidgets(
    'cancelling a pending start releases its request and fences late active',
    (tester) async {
      native.delayedStart = Completer<Object?>();
      native.active = true;
      final owner = _owner(native);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      gate.setWork(active: true, backProtected: true);
      final starting = gate.beginRun(runId: 'cancelled');
      await tester.pump();
      final args = native.args(native.named('startRuns').single);
      gate.cancelStart();
      await tester.pump();
      final cleanup = native.named('releaseRuns').single;
      expect(native.args(cleanup)['startRequestId'], args['startRequestId']);
      expect(
        native.args(cleanup)['opSeq'] as int,
        greaterThan(args['opSeq'] as int),
      );
      native.delayedStart!.complete({
        'version': 1,
        'status': 'active',
        'permitId': native.permit,
        'startRequestId': args['startRequestId'],
        'opSeq': args['opSeq'],
      });
      await tester.pump();
      await starting;
      expect(gate.binding.permitId, isNull);
      expect(gate.executionEligible, isFalse);
    },
  );

  test(
    'overlapping owners still deliver invalidation to the bound permit',
    () async {
      final first = _owner(native);
      addTearDown(first.dispose);
      final gate = _gate(first, 'first');
      gate.setWork(active: true, backProtected: true);
      await gate.beginRun(runId: 'run-1');
      final ticket = await gate.acquire(AiContinuationKind.model);
      final second = AiBackgroundExecution(
        accountKey: 'different-owner',
        generation: 9,
        ownerApi: Object(),
        isCurrent: () => true,
        appInForeground: () => true,
        channel: _channel,
      );
      addTearDown(second.dispose);
      final replied = Completer<void>();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('permitInvalidated', {
                'version': 1,
                'permitId': native.permit,
                'reason': 'service_destroyed',
              }),
            ),
            (_) => replied.complete(),
          );
      await replied.future;
      expect(gate.executionEligible, isFalse);
      expect(
        () => ticket.consumeOnce(
          binding: gate.binding,
          kind: AiContinuationKind.model,
        ),
        throwsA(isA<AiExecutionPaused>()),
      );
    },
  );

  test(
    'disposing an overlapping owner keeps the first invalidation handler',
    () async {
      final first = _owner(native);
      addTearDown(first.dispose);
      final gate = _gate(first, 'first');
      gate.setWork(active: true, backProtected: true);
      await gate.beginRun(runId: 'run-1');
      final ticket = await gate.acquire(AiContinuationKind.model);
      final second = AiBackgroundExecution(
        accountKey: 'different-owner',
        generation: 9,
        ownerApi: Object(),
        isCurrent: () => true,
        appInForeground: () => true,
        channel: _channel,
      );
      addTearDown(second.dispose);
      second.dispose();
      final replied = Completer<void>();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('permitInvalidated', {
                'version': 1,
                'permitId': native.permit,
                'reason': 'service_destroyed',
              }),
            ),
            (_) => replied.complete(),
          );
      await replied.future;
      expect(gate.executionEligible, isFalse);
      expect(
        () => ticket.consumeOnce(
          binding: gate.binding,
          kind: AiContinuationKind.model,
        ),
        throwsA(isA<AiExecutionPaused>()),
      );
    },
  );

  test('a delivered invalidation burns a ticket before consumption', () async {
    final owner = _owner(native);
    addTearDown(owner.dispose);
    final gate = _gate(owner, 'conversation');
    gate.setWork(active: true, backProtected: true);
    await gate.beginRun(runId: 'run-1');
    final ticket = await gate.acquire(AiContinuationKind.model);
    final replied = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('permitInvalidated', {
              'version': 1,
              'permitId': native.permit,
              'reason': 'service_destroyed',
            }),
          ),
          (_) => replied.complete(),
        );
    await replied.future;
    expect(gate.executionEligible, isFalse);
    expect(
      () => ticket.consumeOnce(
        binding: gate.binding,
        kind: AiContinuationKind.model,
      ),
      throwsA(isA<AiExecutionPaused>()),
    );
  });

  testWidgets(
    'progress coalesces and stop is immediate while update is throttled',
    (tester) async {
      final clock = Mr6cClock();
      final owner = _owner(native, clock: clock);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      gate.setWork(active: true, backProtected: true);
      final start = gate.beginRun(runId: 'run-1');
      await tester.pump();
      await start;
      gate.setWork(active: true, backProtected: true, step: 1);
      gate.setWork(active: true, backProtected: true, step: 2);
      await tester.pump(const Duration(milliseconds: 999));
      expect(native.named('updateProgress'), isEmpty);
      clock.advance(const Duration(milliseconds: 1000));
      await tester.pump(const Duration(milliseconds: 1));
      expect(native.named('updateProgress'), hasLength(1));
      expect(native.args(native.named('updateProgress').single)['step'], 2);
      gate.setWork(active: true, backProtected: true, step: 3);
      final stop = owner.stopAll();
      await tester.pump();
      await stop;
      expect(native.named('stopAll'), hasLength(1));
      expect(native.named('updateProgress'), hasLength(1));
    },
  );

  testWidgets(
    'language-only change updates generic text after coalescing interval',
    (tester) async {
      final clock = Mr6cClock();
      final owner = _owner(native, clock: clock);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      gate.setWork(active: true, backProtected: true);
      final start = gate.beginRun(runId: 'run-1');
      await tester.pump();
      await start;
      useLanguage(languageForTag('en')!);
      clock.advance(const Duration(milliseconds: 1000));
      await tester.pump(const Duration(milliseconds: 1000));
      final update = native.named('updateProgress').single;
      expect(native.args(update)['title'], l10n.aiRunServiceTitle);
      expect(native.args(update)['text'], l10n.aiRunServiceText);
      owner.dispose();
    },
  );

  for (final revoked in [false, true]) {
    test(
      'real controller to coordinator background mutation, revoked=$revoked',
      () async {
        final h = await fx.StackHarness.create(
          level: AiAutonomyLevel.conversationGrant,
        );
        addTearDown(h.dispose);
        final owner = AiBackgroundExecution(
          accountKey: h.account,
          generation: h.session.generation,
          ownerApi: h.session.api!,
          isCurrent: () => h.session.api != null,
          appInForeground: () => h.foreground,
          channel: _channel,
        );
        addTearDown(owner.dispose);
        h.controller.bindBackgroundExecution(owner);
        native.denyMutation = revoked;
        bool? snapshotForeground;
        bool? snapshotEligible;
        native.onCall = (call) {
          if (call.method == 'acquireContinuation' &&
              native.args(call)['kind'] == 'mutation') {
            final snapshot = h.controller.writePolicySnapshot;
            snapshotForeground = snapshot?.appInForeground;
            snapshotEligible = snapshot?.executionEligible;
          }
        };
        h.provider.script.add((_) {
          h.foreground = false;
          return fx.toolTurn('createIssue', {
            'projectId': 42,
            'fields': {'title': 'Synthetic bug', 'confidential': false},
            'reason': 'The user asked for an issue.',
          });
        });
        await h.controller.send('Create an issue for the bug');
        expect(snapshotForeground, isFalse);
        expect(snapshotEligible, isTrue);
        expect(h.controller.canSend, isFalse);
        if (revoked) {
          expect(h.server.mutations, isEmpty);
        } else {
          expect(h.server.mutations, hasLength(1));
          expect(
            h.server.mutations.single.uri.path,
            endsWith('/projects/42/issues'),
          );
        }
      },
    );
  }

  test(
    'accepted mutation holds service across stop and conversation replacement until settlement',
    () async {
      final h = await fx.StackHarness.create(
        level: AiAutonomyLevel.conversationGrant,
      );
      addTearDown(h.dispose);
      final owner = AiBackgroundExecution(
        accountKey: h.account,
        generation: h.session.generation,
        ownerApi: h.session.api!,
        isCurrent: () => h.session.api != null,
        appInForeground: () => h.foreground,
        channel: _channel,
      );
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      final responseGate = Completer<void>();
      addTearDown(() {
        if (!responseGate.isCompleted) responseGate.complete();
      });
      h.server.overrides['POST projects/42/issues'] = (request) async {
        await responseGate.future;
        return h.server.workspace.respond(request);
      };
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic settlement', 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
      var notifications = 0;
      h.controller.addListener(() => notifications++);
      final sending = h.controller.send('Create an issue for the bug');
      await fx.waitFor(() => h.server.mutations.isNotEmpty);
      expect(h.controller.inFlightWrites, isNotEmpty);
      expect(h.controller.serviceWorkCount, 1);
      final initialReleases = native.named('releaseRuns').length;
      h.controller.stop();
      h.controller.startNewConversation();
      expect(h.controller.serviceWorkCount, 1);
      expect(native.named('releaseRuns'), hasLength(initialReleases));
      final beforeSettlement = notifications;
      responseGate.complete();
      await sending;
      await fx.waitFor(() => h.controller.inFlightWrites.isEmpty);
      await fx.waitFor(() => h.controller.serviceWorkCount == 0);
      await fx.waitFor(
        () => native.named('releaseRuns').length > initialReleases,
      );
      expect(notifications, greaterThan(beforeSettlement));
      expect(
        native.args(native.named('releaseRuns').last)['permitId'],
        native.permit,
      );
    },
  );

  test(
    'registry injects the shared bridge into a wrapped session factory',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final owner = AiBackgroundExecution(
        accountKey: h.account,
        generation: h.session.generation,
        ownerApi: h.session.api!,
        isCurrent: () => h.session.api != null,
        appInForeground: () => h.foreground,
        channel: _channel,
      );
      final registry = AccountAiRunRegistry(
        session: h.session,
        settings: h.settings,
        backgroundExecution: owner,
        sessionFactory:
            ({
              required origin,
              required session,
              required settings,
              required runningCount,
              wireClientFactory,
            }) => (
              session: h.controller,
              capacityChanged: h.controller.notifyCapacityChanged,
              dispose: h.controller.dispose,
            ),
      );
      addTearDown(registry.dispose);
      final opened = registry.open(h.controller.origin);
      expect(opened, same(h.controller));
      await h.controller.send('Produce an answer');
      expect(native.named('startRuns'), hasLength(1));
      expect(native.named('acquireContinuation'), isNotEmpty);
    },
  );

  test(
    'real coordinator holds approval in background despite a permit',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final owner = AiBackgroundExecution(
        accountKey: h.account,
        generation: h.session.generation,
        ownerApi: h.session.api!,
        isCurrent: () => h.session.api != null,
        appInForeground: () => h.foreground,
        channel: _channel,
      );
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic bug', 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue for the bug');
      await fx.waitFor(() => h.controller.proposals.isNotEmpty);
      final proposal = h.controller.proposals.single;
      expect(h.controller.phase, AiChatPhase.awaitingApproval);
      expect(
        h.controller.serviceWorkCount,
        0,
        reason: 'pure approval waits do not hold the service',
      );
      expect(h.controller.backProtectedCount, 1);
      h.foreground = false;
      final outcome = await h.controller.approveWrite(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(h.server.mutations, isEmpty);
      expect(h.controller.canSend, isFalse);
      h.foreground = true;
      await h.controller.rejectWrite(proposal);
      await sending;
      expect(h.server.mutations, isEmpty);
    },
  );

  test(
    'C3 registry routes each typed event once and rejects stale identities',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final created = <_SyntheticSession>[];
      final registry = AccountAiRunRegistry(
        session: h.session,
        settings: h.settings,
        sessionFactory:
            ({
              required origin,
              required session,
              required settings,
              required runningCount,
              wireClientFactory,
            }) {
              final fake = _SyntheticSession(origin);
              created.add(fake);
              return (
                session: fake,
                capacityChanged: () {},
                dispose: fake.dispose,
              );
            },
      );
      addTearDown(registry.dispose);
      addTearDown(() async {
        for (final fake in created) {
          await fake.events.close();
        }
      });
      final session =
          registry.open(const AiGeneralOrigin()) as _SyntheticSession;
      final generation = h.session.generation;
      expect(
        registry.sessionForConversation(session.id, generation),
        same(session),
      );
      expect(
        registry.sessionForConversation(session.id, generation + 1),
        isNull,
      );
      expect(registry.sessionForConversation('stale-id', generation), isNull);
      final seen = <AiRunNotificationEvent>[];
      final sub = registry.notificationEvents.listen(seen.add);
      addTearDown(sub.cancel);
      for (final kind in AiRunNotificationKind.values) {
        final event = AiRunNotificationEvent(
          kind: kind,
          conversationId: session.id,
          generation: generation,
        );
        session.events.add(event);
        session.events.add(event); // A duplicate delivery of the same event.
        session.events.add(
          AiRunNotificationEvent(
            kind: kind,
            conversationId: session.id,
            generation: generation,
          ),
        ); // Distinct object, same transition.
      }
      await Future<void>.delayed(Duration.zero);
      expect(
        seen.map((event) => event.kind).toList(),
        AiRunNotificationKind.values,
      );
      expect(
        seen.every(
          (event) =>
              event.conversationId == session.id &&
              event.generation == generation,
        ),
        isTrue,
      );

      final oldId = session.id;
      session.id = 'new-id';
      expect(registry.sessionForConversation(oldId, generation), isNull);
      expect(
        registry.sessionForConversation(session.id, generation),
        same(session),
      );
      session.events.add(
        AiRunNotificationEvent(
          kind: AiRunNotificationKind.failed,
          conversationId: oldId,
          generation: generation,
        ),
      );
      session.events.add(
        AiRunNotificationEvent(
          kind: AiRunNotificationKind.failed,
          conversationId: session.id,
          generation: generation + 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(4));

      registry.release(session);
      expect(registry.sessionForConversation(session.id, generation), isNull);
      session.events.add(
        AiRunNotificationEvent(
          kind: AiRunNotificationKind.failed,
          conversationId: session.id,
          generation: generation,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(4));

      final afterRelease =
          registry.open(const AiGeneralOrigin()) as _SyntheticSession;
      registry.dispose();
      expect(
        registry.sessionForConversation(afterRelease.id, generation),
        isNull,
      );
      afterRelease.events.add(
        AiRunNotificationEvent(
          kind: AiRunNotificationKind.completed,
          conversationId: afterRelease.id,
          generation: generation,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(4));
    },
  );

  test(
    'work and back-protection counts notify independently of page visits',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      late _SyntheticSession fake;
      final registry = AccountAiRunRegistry(
        session: h.session,
        settings: h.settings,
        sessionFactory:
            ({
              required origin,
              required session,
              required settings,
              required runningCount,
              wireClientFactory,
            }) {
              fake = _SyntheticSession(origin);
              return (
                session: fake,
                capacityChanged: () {},
                dispose: fake.dispose,
              );
            },
      );
      addTearDown(registry.dispose);
      registry.open(const AiGeneralOrigin());
      addTearDown(() => fake.events.close());
      var notifications = 0;
      registry.addListener(() => notifications++);
      fake.serviceWorkCount = 1;
      fake.backProtectedCount = 1;
      fake.notifyListeners();
      expect(registry.serviceWorkCount, 1);
      expect(registry.backProtectedCount, 1);
      expect(notifications, greaterThan(0));
      final afterRunning = notifications;
      fake.serviceWorkCount = 0;
      fake.notifyListeners();
      expect(registry.serviceWorkCount, 0);
      expect(registry.backProtectedCount, 1);
      expect(notifications, greaterThan(afterRunning));
    },
  );

  test('C3 lookup cannot cross an owner change', () async {
    final h = await fx.StackHarness.create();
    addTearDown(h.dispose);
    late _SyntheticSession fake;
    final registry = AccountAiRunRegistry(
      session: h.session,
      settings: h.settings,
      sessionFactory:
          ({
            required origin,
            required session,
            required settings,
            required runningCount,
            wireClientFactory,
          }) {
            fake = _SyntheticSession(origin);
            return (
              session: fake,
              capacityChanged: () {},
              dispose: fake.dispose,
            );
          },
    );
    addTearDown(registry.dispose);
    final oldGeneration = h.session.generation;
    registry.open(const AiGeneralOrigin());
    addTearDown(() => fake.events.close());
    expect(registry.sessionForConversation(fake.id, oldGeneration), same(fake));
    await h.session.connect('https://example.com/gitlab', 'synthetic-token');
    expect(registry.sessionForConversation(fake.id, oldGeneration), isNull);
  });

  for (final kind in AiRunNotificationKind.values) {
    test(
      'real controller emits ${kind.name} exactly once on transition',
      () async {
        final h = await fx.StackHarness.create();
        addTearDown(h.dispose);
        final owner = AiBackgroundExecution(
          accountKey: h.account,
          generation: h.session.generation,
          ownerApi: h.session.api!,
          isCurrent: () => h.session.api != null,
          appInForeground: () => h.foreground,
          channel: _channel,
        );
        addTearDown(owner.dispose);
        h.controller.bindBackgroundExecution(owner);
        final seen = <AiRunNotificationEvent>[];
        final subscription = h.controller.notificationEvents.listen(seen.add);
        addTearDown(subscription.cancel);
        if (kind == AiRunNotificationKind.needsApproval) {
          h.provider.script.add(
            (_) => fx.toolTurn('createIssue', {
              'projectId': 42,
              'fields': {'title': 'Synthetic bug', 'confidential': false},
              'reason': 'The user asked for an issue.',
            }),
          );
          final sending = h.controller.send('Create an issue for the bug');
          await fx.waitFor(() => h.controller.proposals.isNotEmpty);
          await h.controller.rejectWrite(h.controller.proposals.single);
          await sending;
        } else if (kind == AiRunNotificationKind.failed) {
          h.provider.script.add((_) => 'data: malformed-json\n\n');
          await h.controller.send('Produce an answer');
        } else if (kind == AiRunNotificationKind.interrupted) {
          final sending = h.controller.send('Produce an answer');
          h.controller.stop();
          await sending;
        } else {
          await h.controller.send('Produce an answer');
        }
        await Future<void>.delayed(Duration.zero);
        final matching = seen.where((event) => event.kind == kind).toList();
        expect(
          matching,
          hasLength(1),
          reason: 'observed kinds: ${seen.map((e) => e.kind).toList()}',
        );
        expect(matching.single.conversationId, h.controller.id);
        expect(matching.single.generation, h.session.generation);
      },
    );
  }

  test('foreground approval survives normal service release', () async {
    final h = await fx.StackHarness.create();
    addTearDown(h.dispose);
    final owner = AiBackgroundExecution(
      accountKey: h.account,
      generation: h.session.generation,
      ownerApi: h.session.api!,
      isCurrent: () => h.session.api != null,
      appInForeground: () => h.foreground,
      channel: _channel,
    );
    addTearDown(owner.dispose);
    h.controller.bindBackgroundExecution(owner);
    h.provider.script.add(
      (_) => fx.toolTurn('createIssue', {
        'projectId': 42,
        'fields': {'title': 'Synthetic bug', 'confidential': false},
        'reason': 'The user asked for an issue.',
      }),
    );
    final sending = h.controller.send('Create an issue for the bug');
    await fx.waitFor(() => h.controller.proposals.isNotEmpty);
    final proposal = h.controller.proposals.single;
    await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
    expect(
      native.args(native.named('releaseRuns').single)['permitId'],
      native.permit,
    );
    expect(
      proposal.valid,
      isTrue,
      reason: 'normal service release keeps the approval alive',
    );
    final outcome = await h.controller.approveWrite(proposal);
    if (outcome.state != AiJournalState.succeeded) {
      await h.controller.rejectWrite(proposal);
    }
    await sending;
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(h.server.mutations, hasLength(1));
    expect(
      h.provider.bodies,
      hasLength(2),
      reason: 'the same runner continues',
    );
  });

  test('approval waits for the normal release acknowledgement', () async {
    final h = await fx.StackHarness.create();
    addTearDown(h.dispose);
    final owner = AiBackgroundExecution(
      accountKey: h.account,
      generation: h.session.generation,
      ownerApi: h.session.api!,
      isCurrent: () => h.session.api != null,
      appInForeground: () => h.foreground,
      channel: _channel,
    );
    addTearDown(owner.dispose);
    h.controller.bindBackgroundExecution(owner);
    native.delayedRelease = Completer<Object?>();
    h.provider.script.add(
      (_) => fx.toolTurn('createIssue', {
        'projectId': 42,
        'fields': {'title': 'Synthetic bug', 'confidential': false},
        'reason': 'The user asked for an issue.',
      }),
    );
    final sending = h.controller.send('Create an issue for the bug');
    await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
    final proposal = h.controller.proposals.single;
    var settled = false;
    final approving = h.controller.approveWrite(proposal).then((outcome) {
      settled = true;
      return outcome;
    });
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    expect(proposal.valid, isTrue);
    expect(h.controller.phase, AiChatPhase.awaitingApproval);
    expect(h.server.mutations, isEmpty);
    expect(h.provider.bodies, hasLength(1));
    native.active = false;
    native.delayedRelease!.complete({
      'version': 1,
      'status': 'released',
      'didRelease': true,
    });
    native.delayedRelease = null;
    final outcome = await approving;
    if (outcome.state != AiJournalState.succeeded) {
      await h.controller.rejectWrite(proposal);
    }
    await sending;
    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(h.server.mutations, hasLength(1));
    expect(h.provider.bodies, hasLength(2));
  });

  test(
    'background approval cannot wait for release then gain visibility',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final owner = AiBackgroundExecution(
        accountKey: h.account,
        generation: h.session.generation,
        ownerApi: h.session.api!,
        isCurrent: () => h.session.api != null,
        appInForeground: () => h.foreground,
        channel: _channel,
      );
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      native.delayedRelease = Completer<Object?>();
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic bug', 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue for the bug');
      await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
      final proposal = h.controller.proposals.single;
      h.foreground = false;
      final approving = h.controller.approveWrite(proposal);
      h.foreground = true;
      native.active = false;
      native.delayedRelease!.complete({
        'version': 1,
        'status': 'released',
        'didRelease': true,
      });
      native.delayedRelease = null;
      final outcome = await approving;
      final stillValid = proposal.valid;
      final requestsBeforeRejection = h.provider.bodies.length;
      await h.controller.rejectWrite(proposal);
      await sending;
      expect(outcome.state, AiJournalState.notExecuted);
      expect(stillValid, isTrue);
      expect(h.server.mutations, isEmpty);
      expect(requestsBeforeRejection, 1);
    },
  );

  test(
    'rebound controller refuses background approval without another send',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final owner = AiBackgroundExecution(
        accountKey: h.account,
        generation: h.session.generation,
        ownerApi: h.session.api!,
        isCurrent: () => h.session.api != null,
        appInForeground: () => h.foreground,
        channel: _channel,
      );
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic bug', 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue for the bug');
      await fx.waitFor(
        () => h.controller.proposals.isNotEmpty && !native.active,
      );
      final proposal = h.controller.proposals.single;
      h.foreground = false;
      await h.controller.onAppBackground();
      final held = await h.controller.approveWrite(proposal);
      expect(held.state, AiJournalState.notExecuted);
      expect(proposal.valid, isTrue);
      expect(h.server.mutations, isEmpty);
      expect(h.provider.bodies, hasLength(1));
      expect(native.named('startRuns'), hasLength(1));
      h.foreground = true;
      final outcome = await h.controller.approveWrite(proposal);
      if (outcome.state != AiJournalState.succeeded) {
        await h.controller.rejectWrite(proposal);
      }
      await sending;
      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(h.server.mutations, hasLength(1));
      expect(h.provider.bodies, hasLength(2));
    },
  );

  for (final reason in ['user_stop', 'timeout']) {
    for (final duringRelease in [false, true]) {
      test(
        'approval stays refused after $reason, pending release=$duringRelease',
        () async {
          final h = await fx.StackHarness.create();
          addTearDown(h.dispose);
          final owner = AiBackgroundExecution(
            accountKey: h.account,
            generation: h.session.generation,
            ownerApi: h.session.api!,
            isCurrent: () => h.session.api != null,
            appInForeground: () => h.foreground,
            channel: _channel,
          );
          addTearDown(owner.dispose);
          h.controller.bindBackgroundExecution(owner);
          if (duringRelease) {
            native.delayedRelease = Completer<Object?>();
          } else {
            // Keep the service running while the real controller awaits approval.
            await _gate(owner, 'executing').beginRun(runId: 'executing-run');
          }
          h.provider.script.add(
            (_) => fx.toolTurn('createIssue', {
              'projectId': 42,
              'fields': {'title': 'Synthetic bug', 'confidential': false},
              'reason': 'The user asked for an issue.',
            }),
          );
          final sending = h.controller.send('Create an issue for the bug');
          await fx.waitFor(() => h.controller.proposals.isNotEmpty);
          final proposal = h.controller.proposals.single;
          if (duringRelease) {
            await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
          } else {
            expect(native.named('releaseRuns'), isEmpty);
          }
          await _invalidate(native, reason);
          if (duringRelease) {
            // A stale success must not override the delivered invalidation.
            native.delayedRelease!.complete({
              'version': 1,
              'status': 'released',
              'didRelease': true,
            });
            native.delayedRelease = null;
          }
          final outcome = await h.controller.approveWrite(proposal);
          await h.controller.rejectWrite(proposal);
          await sending;
          expect(outcome.state, AiJournalState.notExecuted);
          expect(h.server.mutations, isEmpty);
          expect(h.provider.bodies, hasLength(1));
        },
      );
    }
  }

  test(
    'foreground rebind ignores a different permit and cannot be repeated',
    () async {
      final owner = _owner(native);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      await gate.beginRun(runId: 'run-1');
      final binding = gate.binding;
      expect(
        binding.rebindForForegroundApproval(releasedPermitId: 'another-permit'),
        isFalse,
      );
      expect(binding.permitId, native.permit);
      expect(gate.executionEligible, isTrue);
      gate.setWork(active: false, backProtected: true, awaitingApproval: true);
      await gate.pendingNormalRelease;
      expect(gate.binding, same(binding));
      expect(binding.permitId, isNull);
      expect(binding.accountKey, owner.accountKey);
      expect(binding.generation, owner.generation);
      expect(binding.ownerApi, same(owner.ownerApi));
      expect(binding.conversationId, 'conversation');
      expect(binding.runId, 'run-1');
      expect(
        binding.rebindForForegroundApproval(releasedPermitId: native.permit),
        isFalse,
      );
    },
  );

  test(
    'normal release rebinds all approval waits but no executing run',
    () async {
      final owner = _owner(native);
      addTearDown(owner.dispose);
      final gates = [for (var i = 0; i < 3; i++) _gate(owner, 'c$i')];
      for (var i = 0; i < gates.length; i++) {
        await gates[i].beginRun(runId: 'run-$i');
      }
      for (final gate in gates.take(2)) {
        gate.setWork(
          active: false,
          backProtected: true,
          awaitingApproval: true,
        );
      }
      expect(owner.serviceWorkCount, 1);
      await owner.releaseRuns();
      expect(
        gates.take(2).every((gate) => gate.binding.permitId == null),
        isTrue,
      );
      expect(gates.take(2).every((gate) => gate.executionEligible), isTrue);
      expect(gates.last.binding.permitId, native.permit);
      expect(gates.last.executionEligible, isFalse);
      await expectLater(
        gates.last.acquire(AiContinuationKind.model),
        throwsA(isA<AiExecutionPaused>()),
      );
    },
  );

  test(
    'a run executing before release acknowledgement is not rebound',
    () async {
      final owner = _owner(native);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      await gate.beginRun(runId: 'run-1');
      native.delayedRelease = Completer<Object?>();
      gate.setWork(active: false, backProtected: true, awaitingApproval: true);
      final releasing = gate.pendingNormalRelease!;
      await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
      gate.setWork(active: true, backProtected: true, awaitingApproval: true);
      native.active = false;
      native.delayedRelease!.complete({
        'version': 1,
        'status': 'released',
        'didRelease': true,
      });
      native.delayedRelease = null;
      await releasing;
      expect(gate.binding.permitId, native.permit);
      expect(gate.executionEligible, isFalse);
    },
  );

  test(
    'tickets issued before rebind stay invalid and local tickets have no TTL',
    () async {
      final clock = Mr6cClock();
      var visible = true;
      final owner = _owner(native, clock: clock, foreground: () => visible);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      await gate.beginRun(runId: 'run-1');
      final tickets = [
        for (final kind in AiContinuationKind.values) await gate.acquire(kind),
      ];
      gate.setWork(active: false, backProtected: true, awaitingApproval: true);
      await gate.pendingNormalRelease;
      expect(gate.binding.permitId, isNull);
      for (final ticket in tickets) {
        expect(
          () => ticket.consumeOnce(binding: gate.binding, kind: ticket.kind),
          throwsA(isA<AiExecutionPaused>()),
        );
      }
      final local = await gate.acquire(AiContinuationKind.mutation);
      clock.advance(const Duration(seconds: 2));
      local.consumeOnce(
        binding: gate.binding,
        kind: AiContinuationKind.mutation,
      );
      expect(
        () => local.consumeOnce(
          binding: gate.binding,
          kind: AiContinuationKind.mutation,
        ),
        throwsA(isA<AiExecutionPaused>()),
      );
      final hidden = await gate.acquire(AiContinuationKind.model);
      visible = false;
      expect(
        () => hidden.consumeOnce(binding: gate.binding, kind: hidden.kind),
        throwsA(isA<AiExecutionPaused>()),
      );
    },
  );

  test('a native ticket reply arriving after rebind is refused', () async {
    final owner = _owner(native);
    addTearDown(owner.dispose);
    final gate = _gate(owner, 'conversation');
    await gate.beginRun(runId: 'run-1');
    native.delayedTicket = Completer<Object?>();
    final pending = gate.acquire(AiContinuationKind.model);
    await fx.waitFor(() => native.named('acquireContinuation').isNotEmpty);
    final args = native.args(native.named('acquireContinuation').single);
    gate.setWork(active: false, backProtected: true, awaitingApproval: true);
    await gate.pendingNormalRelease;
    expect(gate.binding.permitId, isNull);
    final refused = expectLater(pending, throwsA(isA<AiExecutionPaused>()));
    native.delayedTicket!.complete({
      'version': 1,
      'status': 'ticket',
      'permitId': args['permitId'],
      'kind': args['kind'],
      'nonce': args['nonce'],
      'ticketId': '00000000-0000-4000-8000-000000000001',
    });
    native.delayedTicket = null;
    await refused;
  });

  test(
    'a stale acquire rejection cannot invalidate a pending normal release',
    () async {
      final owner = _owner(native);
      addTearDown(owner.dispose);
      final gate = _gate(owner, 'conversation');
      await gate.beginRun(runId: 'run-1');
      native.delayedTicket = Completer<Object?>();
      final pending = gate.acquire(AiContinuationKind.model);
      await fx.waitFor(() => native.named('acquireContinuation').isNotEmpty);
      native.delayedRelease = Completer<Object?>();
      gate.setWork(active: false, backProtected: true, awaitingApproval: true);
      final releasing = gate.pendingNormalRelease!;
      await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
      final refused = expectLater(pending, throwsA(isA<AiExecutionPaused>()));
      native.delayedTicket!.complete({
        'version': 1,
        'status': 'rejected',
        'reason': 'permit_inactive',
      });
      native.delayedTicket = null;
      await refused;
      native.active = false;
      native.delayedRelease!.complete({
        'version': 1,
        'status': 'released',
        'didRelease': true,
      });
      native.delayedRelease = null;
      await releasing;
      expect(gate.binding.permitId, isNull);
      expect(gate.executionEligible, isTrue);
    },
  );

  test('a failed normal release never rebinds an approval wait', () async {
    final owner = _owner(native);
    addTearDown(owner.dispose);
    addTearDown(() async {
      native.releaseMatches = true;
      await owner.stopAll();
    });
    final gate = _gate(owner, 'conversation');
    await gate.beginRun(runId: 'run-1');
    native.releaseMatches = false;
    gate.setWork(active: false, backProtected: true, awaitingApproval: true);
    await gate.pendingNormalRelease;
    expect(gate.binding.permitId, native.permit);
    expect(gate.executionEligible, isFalse);
  });

  test('a rebound run needs a new permit for background sends', () async {
    var visible = true;
    final owner = _owner(native, foreground: () => visible);
    addTearDown(owner.dispose);
    final gate = _gate(owner, 'conversation');
    await gate.beginRun(runId: 'run-1');
    gate.setWork(active: false, backProtected: true, awaitingApproval: true);
    await gate.pendingNormalRelease;
    expect(gate.binding.permitId, isNull);
    visible = false;
    final acquisitions = native.named('acquireContinuation').length;
    var sends = 0;
    for (final kind in AiContinuationKind.values) {
      await expectLater(() async {
        final ticket = await gate.acquire(kind);
        ticket.consumeOnce(binding: gate.binding, kind: kind);
        sends++;
      }(), throwsA(isA<AiExecutionPaused>()));
    }
    await owner.onForeground();
    expect(sends, 0);
    expect(native.named('acquireContinuation'), hasLength(acquisitions));
    expect(native.named('startRuns'), hasLength(1));
    visible = true;
    native.permit = 'permit-2';
    // C5 owns same-run resume. This explicit new run demonstrates the required
    // fresh start/permit, without automatically resuming the rebound run.
    await gate.beginRun(runId: 'run-2');
    visible = false;
    final ticket = await gate.acquire(AiContinuationKind.model);
    ticket.consumeOnce(binding: gate.binding, kind: AiContinuationKind.model);
    sends++;
    expect(sends, 1);
    expect(gate.binding.permitId, 'permit-2');
    expect(native.named('startRuns'), hasLength(2));
  });

  test('different approval waits in one run each emit once', () async {
    final h = await fx.StackHarness.create();
    addTearDown(h.dispose);
    native.rejectStart = true;
    final owner = AiBackgroundExecution(
      accountKey: h.account,
      generation: h.session.generation,
      ownerApi: h.session.api!,
      isCurrent: () => h.session.api != null,
      appInForeground: () => h.foreground,
      channel: _channel,
    );
    addTearDown(owner.dispose);
    h.controller.bindBackgroundExecution(owner);
    final seen = <AiRunNotificationEvent>[];
    final subscription = h.controller.notificationEvents.listen(seen.add);
    addTearDown(subscription.cancel);
    for (final title in ['First synthetic issue', 'Second synthetic issue']) {
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': title, 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
    }
    final sending = h.controller.send('Create two issues');
    await fx.waitFor(() => h.controller.proposals.isNotEmpty);
    final first = h.controller.proposals.single;
    expect(
      seen.where((event) => event.kind == AiRunNotificationKind.needsApproval),
      hasLength(1),
    );
    await h.controller.rejectWrite(first);
    await fx.waitFor(
      () =>
          h.controller.proposals.any((proposal) => !identical(proposal, first)),
    );
    final second = h.controller.proposals.firstWhere(
      (proposal) => !identical(proposal, first),
    );
    expect(
      seen.where((event) => event.kind == AiRunNotificationKind.needsApproval),
      hasLength(2),
    );
    await h.controller.rejectWrite(second);
    await sending;
    expect(h.server.mutations, isEmpty);
  });

  test('disposed controller suppresses all late completion events', () async {
    final h = await fx.StackHarness.create();
    addTearDown(h.dispose);
    final owner = AiBackgroundExecution(
      accountKey: h.account,
      generation: h.session.generation,
      ownerApi: h.session.api!,
      isCurrent: () => h.session.api != null,
      appInForeground: () => h.foreground,
      channel: _channel,
    );
    addTearDown(owner.dispose);
    h.controller.bindBackgroundExecution(owner);
    final seen = <AiRunNotificationEvent>[];
    final subscription = h.controller.notificationEvents.listen(seen.add);
    addTearDown(subscription.cancel);
    native.delayedStart = Completer<Object?>();
    native.active = true;
    final sending = h.controller.send('Produce an answer');
    await fx.waitFor(() => native.named('startRuns').isNotEmpty);
    final args = native.args(native.named('startRuns').single);
    h.controller.dispose();
    native.delayedStart!.complete({
      'version': 1,
      'status': 'active',
      'permitId': native.permit,
      'startRequestId': args['startRequestId'],
      'opSeq': args['opSeq'],
    });
    await sending;
    await Future<void>.delayed(Duration.zero);
    expect(seen, isEmpty);
  });

  testWidgets('an orphan cleanup is resolved by stopAll on next foreground', (
    tester,
  ) async {
    native.delayedStart = Completer<Object?>();
    native.active = true;
    native.releaseMatches = false;
    var foreground = true;
    final owner = _owner(native, foreground: () => foreground);
    addTearDown(owner.dispose);
    final gate = _gate(owner, 'conversation');
    gate.setWork(active: true, backProtected: true);
    final starting = gate.beginRun(runId: 'run-1');
    await tester.pump();
    foreground = false;
    await tester.pump(const Duration(milliseconds: 1001));
    await tester.pump();
    await starting;
    expect(native.named('releaseRuns'), hasLength(1));
    expect(native.named('stopAll'), isEmpty);
    foreground = true;
    final cleanup = owner.onForeground();
    await tester.pump();
    await cleanup;
    expect(native.named('stopAll'), hasLength(1));
    expect(native.active, isFalse);
  });
}

final class _SyntheticSession extends ChangeNotifier
    implements AiChatSession, AiRunNotificationSource, AiExecutionChatSession {
  _SyntheticSession(this.origin);

  @override
  final AiChatOrigin origin;
  @override
  String id = 'synthetic-conversation';
  @override
  AiChatPhase get phase => AiChatPhase.idle;
  @override
  List<Never> get items => const [];
  @override
  int serviceWorkCount = 0;
  @override
  int backProtectedCount = 0;
  @override
  AiChatExecutionStatus executionStatus = AiChatExecutionStatus.foregroundOnly;
  final events = StreamController<AiRunNotificationEvent>.broadcast(sync: true);
  @override
  Stream<AiRunNotificationEvent> get notificationEvents => events.stream;

  @override
  void stop() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
