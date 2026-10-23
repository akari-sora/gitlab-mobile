import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'runner_test.dart' as base;

void main() {
  test('issue13 runner notifies writes only when a new segment starts', () async {
    final h = base.Harness();
    final coordinator = _PendingCoordinator();
    final runner = _runner(h, writeCoordinator: coordinator);
    expect((await runner.run('first')).reason, AiRunEnd.done);
    expect(coordinator.segments, 1);
    final original = runner.segment;
    expect((await runner.run('same segment')).reason, AiRunEnd.done);
    expect(runner.segment, same(original));
    expect(coordinator.segments, 1);
    runner.forceProjection();
    expect((await runner.run('new segment')).reason, AiRunEnd.done);
    expect(runner.segment, isNot(same(original)));
    expect(coordinator.segments, 2);
  });

  test(
    '§15 row12 policy revisions reopen a segment but level changes preserve it',
    () async {
      final h = base.Harness();
      var revision = 1;
      var level = 0;
      var liveTools = <AiToolSpec>[base.spec];
      final runner = _runner(
        h,
        currentTools: () => level >= 0 ? liveTools : const [],
        toolPolicyRevision: () => revision,
      );

      await runner.run('first');
      final original = runner.segment;
      level++;
      await runner.run('level only');
      expect(runner.segment, same(original));

      revision++;
      liveTools = [_writeSpec];
      await runner.run('policy changed');
      expect(runner.segment, isNot(same(original)));
      expect(h.plans.last.tools.map((tool) => tool.name), ['setStar']);
    },
  );

  test(
    '§15 rows 4 and 17 stop keeps write ownership and bypasses read timeout',
    () async {
      final h = base.Harness();
      final coordinator = _PendingCoordinator();
      final results = <AiToolResult>[];
      var modelCalls = 0;
      h.respond = (_, _) async => switch (++modelCalls) {
        1 || 2 => h.turn(calls: [_writeCall('write-$modelCalls')]),
        _ => h.turn(text: 'done'),
      };
      final runner = _runner(
        h,
        writeCoordinator: coordinator,
        currentTools: () => const [],
        toolDeadline: const Duration(milliseconds: 1),
        onToolResult: results.add,
      );

      final first = runner.run('first');
      await coordinator.started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(coordinator.executeCalls, 1);
      runner.stop();
      expect((await first).reason, AiRunEnd.stopped);

      final second = await runner.run('second');
      expect(second.reason, AiRunEnd.done);
      expect(second.toolCalls, 0);
      expect(coordinator.executeCalls, 1);
      expect(results.last.content, contains('write_pending'));
      expect(coordinator.stopReasons, ['stopped']);

      final frozen = List<String>.of(runner.segment!.frozenWireJson);
      coordinator.outcome.complete(
        const AiWriteOutcome(
          state: AiJournalState.succeeded,
          reasonCode: 'lateSuccess',
          mutationCount: 1,
          operationId: 'setStar',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(runner.segment!.frozenWireJson, frozen);
    },
  );

  test(
    '§15 row17 approval pauses active deadline and resumes its remainder',
    () async {
      final h = base.Harness();
      final coordinator = _PendingCoordinator();
      final awaiting = <bool>[];
      var clock = DateTime.utc(2026, 1, 1);
      h.respond = (_, _) async => h.turn(calls: [_writeCall()]);
      final runner = _runner(
        h,
        writeCoordinator: coordinator,
        currentTools: () => [_writeSpec],
        now: () => clock,
        runDeadline: const Duration(minutes: 12),
        onAwaitingApproval: awaiting.add,
      );

      final running = runner.run('write');
      await coordinator.started.future;
      clock = clock.add(const Duration(minutes: 11, seconds: 59));
      coordinator.setAwaiting(true);
      clock = clock.add(const Duration(minutes: 29));
      runner.checkNow();
      expect(coordinator.stopReasons, isEmpty);
      coordinator.setAwaiting(false);
      clock = clock.add(const Duration(seconds: 1));
      runner.checkNow();

      expect((await running).reason, AiRunEnd.failed);
      expect(coordinator.stopReasons, ['timeout']);
      expect(awaiting, [true, false]);
    },
  );

  test(
    '§15 row4 settings invalidation reaches the write coordinator',
    () async {
      final h = base.Harness();
      final coordinator = _PendingCoordinator();
      h.respond = (_, _) async => h.turn(calls: [_writeCall()]);
      final runner = _runner(
        h,
        writeCoordinator: coordinator,
        currentTools: () => [_writeSpec],
      );

      final running = runner.run('write');
      await coordinator.started.future;
      runner.stop(AiRunEnd.stoppedBySettings);

      expect((await running).reason, AiRunEnd.stoppedBySettings);
      expect(coordinator.stopReasons, ['settingsChanged']);
    },
  );

  test('§15 rows 12 and 17 writes pair after the read soft deadline', () async {
    for (final format in AiFormat.values) {
      final h = base.Harness(format: format);
      final coordinator = _PendingCoordinator();
      final results = <AiToolResult>[];
      var modelCalls = 0;
      h.respond = (_, _) async => ++modelCalls == 1
          ? h.turn(calls: [_writeCall()])
          : h.turn(text: 'done');
      final runner = _runner(
        h,
        writeCoordinator: coordinator,
        currentTools: () => [_writeSpec],
        toolDeadline: const Duration(milliseconds: 5),
        onToolResult: results.add,
      );

      final running = runner.run('write');
      await coordinator.started.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.outcome.complete(
        const AiWriteOutcome(
          state: AiJournalState.succeeded,
          reasonCode: 'ok',
          mutationCount: 1,
          operationId: 'setStar',
        ),
      );

      expect((await running).reason, AiRunEnd.done, reason: format.name);
      expect(
        results.single.content,
        'write setStar: succeeded; ok',
        reason: format.name,
      );
    }
  });

  test('§15 row28 write projection and restore keep one summary line', () {
    const outcome = AiWriteOutcome(
      state: AiJournalState.succeeded,
      reasonCode: 'ok',
      mutationCount: 1,
      operationId: 'setStar',
    );
    final result = outcome.toToolResult(_writeCall());

    final live = buildAiProjection(
      context: const [],
      entries: [
        AppToolResultsEntry([result]),
      ],
      budget: 4000,
      redact: (value) => value,
    );
    final restored = buildAiProjection(
      context: const [],
      entries: const [],
      history: const [
        AiToolRunItem(
          name: 'setStar',
          argsPreview: '',
          status: AiToolRunStatus.completed,
          sizeChars: 28,
          provenance: 'write',
          resultExcerpt: 'write setStar: succeeded; ok',
          writeStatus: AiWriteResultStatus.succeeded,
        ),
      ],
      budget: 4000,
      redact: (value) => value,
    );

    expect(_occurrences(live, outcome.summary), 1);
    expect(_occurrences(restored, outcome.summary), 1);
    expect(live, isNot(contains('\nwrite setStar: succeeded; ok\nwrite')));
  });

  test(
    '§15 row18 runner fail-stops later writes in the same model turn',
    () async {
      final h = base.Harness();
      final coordinator = _PendingCoordinator();
      final results = <AiToolResult>[];
      var modelCalls = 0;
      coordinator.outcome.complete(
        const AiWriteOutcome(
          state: AiJournalState.failedCertain,
          reasonCode: 'forbidden',
          operationId: 'setStar',
        ),
      );
      h.respond = (_, _) async => ++modelCalls == 1
          ? h.turn(calls: [_writeCall('first'), _writeCall('later')])
          : h.turn(text: 'done');
      final runner = _runner(
        h,
        writeCoordinator: coordinator,
        currentTools: () => [_writeSpec],
        onToolResult: results.add,
      );

      expect((await runner.run('write')).reason, AiRunEnd.done);
      expect(coordinator.executeCalls, 1);
      expect(results.last.content, contains('previousWriteIncomplete'));
      expect(results.last.notExecuted, isTrue);
    },
  );

  testWidgets('§15 row17 write returns its real result at second 21', (
    tester,
  ) async {
    final h = base.Harness();
    final coordinator = _PendingCoordinator();
    final results = <AiToolResult>[];
    var modelCalls = 0;
    h.respond = (_, _) async => ++modelCalls == 1
        ? h.turn(calls: [_writeCall()])
        : h.turn(text: 'done');
    final runner = _runner(
      h,
      writeCoordinator: coordinator,
      currentTools: () => [_writeSpec],
      toolDeadline: const Duration(seconds: 20),
      onToolResult: results.add,
    );
    final running = runner.run('write');
    await tester.pump();
    expect(coordinator.executeCalls, 1);
    await tester.pump(const Duration(seconds: 21));
    expect(results, isEmpty);
    coordinator.outcome.complete(
      const AiWriteOutcome(
        state: AiJournalState.succeeded,
        reasonCode: 'realResult',
        operationId: 'setStar',
        mutationCount: 1,
      ),
    );
    await tester.pump();
    expect((await running).reason, AiRunEnd.done);
    expect(results.single.content, contains('realResult'));
  });
}

final _writeSpec = AiToolSpec(
  name: 'setStar',
  description: 'Set the project star state.',
  parameters: {'type': 'object', 'properties': <String, Object?>{}},
);

AiToolCall _writeCall([String id = 'write']) => AiToolCall(
  id: id,
  name: 'setStar',
  arguments: const {'projectId': 9, 'starred': true},
);

final class _PendingCoordinator implements AiWriteCoordinator {
  final started = Completer<void>();
  final outcome = Completer<AiWriteOutcome>();
  final stopReasons = <String>[];
  int executeCalls = 0;
  int segments = 0;
  void Function(bool)? _onAwaitingApproval;

  @override
  bool handles(String name) => name == 'setStar';

  @override
  void beginSegment() => segments++;

  @override
  void beginRun(String userUtterance) {}

  @override
  void beginTurn() {}

  @override
  Future<AiWriteOutcome> execute(
    AiToolCall call, {
    void Function(bool)? onAwaitingApproval,
  }) {
    executeCalls++;
    _onAwaitingApproval = onAwaitingApproval;
    if (!started.isCompleted) started.complete();
    return outcome.future;
  }

  @override
  Future<AiWriteProposal?> propose(AiToolCall call) async => null;

  @override
  Future<AiWriteOutcome> approve(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  }) => throw UnimplementedError();

  @override
  Future<void> reject(AiWriteProposal proposal) async {}

  @override
  Future<void> onAppBackground() async {}

  void setAwaiting(bool value) => _onAwaitingApproval?.call(value);

  @override
  void stop([String reason = 'stopped']) => stopReasons.add(reason);

  @override
  void checkNow() {}
}

int _occurrences(String source, String pattern) =>
    pattern.isEmpty ? 0 : pattern.allMatches(source).length;

AiRunner _runner(
  base.Harness h, {
  AiWriteCoordinator? writeCoordinator,
  List<AiToolSpec> Function()? currentTools,
  Object? Function()? toolPolicyRevision,
  void Function(bool)? onAwaitingApproval,
  DateTime Function()? now,
  void Function(AiToolResult)? onToolResult,
  Duration toolDeadline = const Duration(seconds: 20),
  Duration runDeadline = const Duration(minutes: 12),
}) => AiRunner(
  config: h.config(),
  wire: h.wire,
  complete: h.complete,
  secrets: h.secrets,
  refreshSecrets: () async {},
  guard: AiRunGuard(
    expectedGeneration: 1,
    ownerApi: h.owner,
    generation: () => 1,
    api: () => h.owner,
    recipientRevision: () => 1,
    consentValid: () => true,
  ),
  system: 'Synthetic system',
  tools: [base.spec],
  currentTools: currentTools,
  toolPolicyRevision: toolPolicyRevision,
  writeCoordinator: writeCoordinator,
  onAwaitingApproval: onAwaitingApproval,
  onToolResult: onToolResult,
  now: now,
  close: () {},
  cancelActive: () {},
  executeTool: (call) async => AiToolResult(
    callId: call.id,
    name: call.name,
    content: '[source: read]\nread',
  ),
  toolDeadline: toolDeadline,
  runDeadline: runDeadline,
);
