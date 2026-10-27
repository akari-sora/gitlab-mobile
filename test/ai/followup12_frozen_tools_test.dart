import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'runner_test.dart' as base;

void main() {
  test('a write absent from the frozen tools never reaches the gate', () async {
    final h = base.Harness();
    final coordinator = _RecordingCoordinator();
    final results = <AiToolResult>[];
    var modelCalls = 0;
    h.respond = (_, _) async => ++modelCalls == 1
        ? h.turn(calls: [_call('setStar')])
        : h.turn(text: 'done');

    final runner = _runner(
      h,
      coordinator: coordinator,
      tools: [base.spec],
      onToolResult: results.add,
    );

    expect(
      (await runner.run('try an unavailable write')).reason,
      AiRunEnd.done,
    );
    // Not offered in the segment: it never reaches the gate (execute is never
    // called), but the ledger still recognises it as a write, so the turn's
    // writes stop (§7.5) — proven by the next test.
    expect(coordinator.executedNames, isEmpty);
    expect(results.single.notExecuted, isTrue);
    expect(results.single.content, contains('unavailable'));
  });

  test("a refused unavailable write stops the same turn's later writes", () async {
    final h = base.Harness();
    final coordinator = _RecordingCoordinator();
    final results = <AiToolResult>[];
    var modelCalls = 0;
    h.respond = (_, _) async => ++modelCalls == 1
        ? h.turn(calls: [_call('createNote'), _call(_writeSpec.name)])
        : h.turn(text: 'done');

    final runner = _runner(
      h,
      coordinator: coordinator,
      tools: [_writeSpec],
      onToolResult: results.add,
    );

    expect(
      (await runner.run('unavailable write then an offered one')).reason,
      AiRunEnd.done,
    );
    expect(coordinator.executedNames, isEmpty, reason: 'the gate never runs');
    expect(results.length, 2);
    expect(results.first.content, contains('unavailable'));
    expect(results.last.notExecuted, isTrue);
    expect(results.last.content, contains('previousWriteIncomplete'));
  });

  test('an advertised read-only tool still executes normally', () async {
    final h = base.Harness();
    final coordinator = _RecordingCoordinator();
    final executedReads = <String>[];
    var modelCalls = 0;
    h.respond = (_, _) async => ++modelCalls == 1
        ? h.turn(calls: [_call(base.spec.name)])
        : h.turn(text: 'done');

    final runner = _runner(
      h,
      coordinator: coordinator,
      tools: [base.spec],
      onRead: (call) async {
        executedReads.add(call.name);
        return AiToolResult(
          callId: call.id,
          name: call.name,
          content: '[source: synthetic]\nread',
        );
      },
    );

    expect((await runner.run('read')).reason, AiRunEnd.done);
    expect(coordinator.handledNames, [base.spec.name]);
    expect(coordinator.executedNames, isEmpty);
    expect(executedReads, [base.spec.name]);
  });

  test('an advertised write still reaches the current-level gate', () async {
    final h = base.Harness();
    final coordinator = _RecordingCoordinator();
    final results = <AiToolResult>[];
    var modelCalls = 0;
    h.respond = (_, _) async => ++modelCalls == 1
        ? h.turn(calls: [_call(_writeSpec.name)])
        : h.turn(text: 'done');

    final runner = _runner(
      h,
      coordinator: coordinator,
      tools: [_writeSpec],
      onToolResult: results.add,
    );

    expect((await runner.run('write while read-only')).reason, AiRunEnd.done);
    expect(coordinator.handledNames, [_writeSpec.name]);
    expect(coordinator.executedNames, [_writeSpec.name]);
    expect(results.single.notExecuted, isTrue);
    expect(results.single.content, contains('currentLevelReadOnly'));
  });
}

final _writeSpec = AiToolSpec(
  name: 'setStar',
  description: 'Set the project star state.',
  parameters: {'type': 'object', 'properties': <String, Object?>{}},
);

AiToolCall _call(String name) => AiToolCall(
  id: 'call-$name',
  name: name,
  arguments: const <String, Object?>{},
);

AiRunner _runner(
  base.Harness h, {
  required _RecordingCoordinator coordinator,
  required List<AiToolSpec> tools,
  Future<AiToolResult> Function(AiToolCall)? onRead,
  void Function(AiToolResult)? onToolResult,
}) => AiRunner(
  appInForeground: () => true,
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
  tools: tools,
  currentTools: () => tools,
  writeCoordinator: coordinator,
  close: () {},
  cancelActive: () {},
  executeTool:
      onRead ??
      (call) async => AiToolResult(
        callId: call.id,
        name: call.name,
        content: '[source: synthetic]\nread',
      ),
  onToolResult: onToolResult,
);

final class _RecordingCoordinator implements AiWriteCoordinator {
  final handledNames = <String>[];
  final executedNames = <String>[];

  @override
  bool handles(String name) {
    handledNames.add(name);
    return name == _writeSpec.name || name == 'createNote';
  }

  @override
  void beginRun(String userUtterance) {}

  @override
  void beginTurn() {}

  @override
  void beginSegment() {}

  @override
  Future<AiWriteOutcome> execute(
    AiToolCall call, {
    void Function(bool)? onAwaitingApproval,
  }) async {
    executedNames.add(call.name);
    return const AiWriteOutcome(
      state: AiJournalState.notExecuted,
      reasonCode: 'currentLevelReadOnly',
      operationId: 'setStar',
    );
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

  @override
  void stop([String reason = 'stopped']) {}

  @override
  void checkNow() {}
}
