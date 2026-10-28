import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart' as fx;
import 'mr6c_support.dart';
import 'runner_test.dart' as base;
import '../support/workspace_fixture.dart';
import '../support/fake_adapter.dart' show jsonResponse;

const _channel = MethodChannel('io.gitlabmobile/c5_pause_test');

AiRunner _runner(
  base.Harness h, {
  required AiExecutionGate gate,
  void Function()? reset,
  void Function()? beginTurn,
  bool Function()? exhausted,
  DateTime Function()? now,
  void Function(AiToolResult)? onResult,
  AiWriteCoordinator? writes,
  List<AiToolSpec>? tools,
}) => AiRunner(
  config: h.config(),
  wire: h.wire,
  complete: h.complete,
  secrets: h.secrets,
  refreshSecrets: () async {
    h.refresh?.call();
  },
  guard: AiRunGuard(
    expectedGeneration: 1,
    ownerApi: h.owner,
    generation: () => h.generation,
    api: () => h.api,
    recipientRevision: () => h.revision,
    consentValid: () => h.consent,
  ),
  system: 'Synthetic C5 continuation.',
  close: () {
    h.closed++;
  },
  cancelActive: () {
    h.cancelled++;
  },
  executionGate: gate,
  tools: tools ?? [base.spec],
  writeCoordinator: writes,
  executeTool: (call) async => h.execute == null
      ? AiToolResult(callId: call.id, name: call.name, content: 'read result')
      : h.execute!(call),
  resetToolBudget: reset,
  beginToolTurn: beginTurn,
  toolBudgetExhausted: exhausted,
  now: now,
  onToolResult: onResult,
);

Mr6cExecutionGate _gate(base.Harness h, {bool permit = false}) =>
    Mr6cExecutionGate(
      binding: AiExecutionRunBinding(
        accountKey: 'synthetic-account',
        generation: 1,
        ownerApi: h.owner,
        conversationId: 'conversation',
        runId: 'logical-run',
        permitId: permit ? 'permit' : null,
      ),
      clock: Mr6cClock(),
    )..foreground = true;

AiToolResult _read(AiToolCall call) => AiToolResult(
  callId: call.id,
  name: call.name,
  content: '[source: pinned file]\nread',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final permit in [false, true]) {
    test(
      'same continuation ${permit ? "progresses with permit" : "pauses without service"}',
      () async {
        final h = base.Harness();
        final gate = _gate(h, permit: permit);
        var models = 0;
        var reads = 0;
        h.respond = (_, _) async => ++models == 1
            ? h.turn(calls: [base.call('read')])
            : h.turn(text: 'done');
        h.execute = (call) async {
          reads++;
          gate.foreground = false;
          return _read(call);
        };
        final runner = _runner(h, gate: gate);
        final first = await runner.run('inspect');
        expect(reads, 1);
        if (permit) {
          expect(first.reason, AiRunEnd.done);
          expect(models, 2);
        } else {
          expect(
            first.pause?.reason,
            AiExecutionPauseReason.foregroundRequired,
          );
          expect(models, 1);
          gate.foreground = true;
          await Future<void>.delayed(Duration.zero);
          expect(models, 1, reason: 'visibility alone does not continue a run');
          final resumed = await runner.resumeRun();
          expect(resumed.reason, AiRunEnd.done);
          expect(resumed.modelCalls, 2);
          expect(resumed.toolCalls, 1);
          expect(reads, 1, reason: 'the settled read Future is not replayed');
        }
      },
    );
  }

  test(
    'sixth accepted model call cannot become a seventh after resume; new send resets',
    () async {
      final h = base.Harness();
      final gate = _gate(h);
      var models = 0;
      var resets = 0;
      late AiRunner runner;
      h.respond = (_, _) async {
        models++;
        if (models == 6) runner.stop();
        return h.turn(calls: [base.call('read-$models')]);
      };
      runner = _runner(
        h,
        gate: gate,
        reset: () {
          resets++;
        },
      );
      final stopped = await runner.run('read');
      expect(stopped.modelCalls, 6);
      expect(stopped.reason, AiRunEnd.stopped);
      final resumed = await runner.resumeRun();
      expect(resumed.reason, AiRunEnd.toolBudget);
      expect(resumed.modelCalls, 6);
      expect(models, 6);
      expect(resets, 1);
      h.respond = (_, _) async {
        models++;
        return h.turn(text: 'new send');
      };
      expect((await runner.run('new user send')).modelCalls, 1);
      expect(models, 7);
      expect(resets, 2);
    },
  );

  test(
    'twelfth tool and its HTTP budget stay exhausted across resume',
    () async {
      final h = base.Harness();
      final gate = _gate(h);
      var models = 0;
      var reads = 0;
      var resets = 0;
      var budget = AiToolBudget();
      h.respond = (_, _) async => h.turn(
        calls: [for (var i = 0; i < 4; i++) base.call('read-${models++}')],
      );
      h.execute = (call) async {
        expect(budget.reserve(requests: 2, search: false), isNull);
        if (++reads == 12) gate.foreground = false;
        return _read(call);
      };
      final runner = _runner(
        h,
        gate: gate,
        reset: () {
          resets++;
          budget = AiToolBudget();
        },
        beginTurn: () => budget.beginTurn(),
        exhausted: () => budget.exhausted,
      );
      final paused = await runner.run('inspect files');
      expect(paused.toolCalls, 12);
      expect(paused.modelCalls, 3);
      expect(paused.pause, isNotNull);
      expect(budget.gitLabRequests, 24);
      gate.foreground = true;
      final resumed = await runner.resumeRun();
      expect(resumed.reason, AiRunEnd.toolBudget);
      expect(resumed.toolCalls, 12);
      expect(reads, 12);
      expect(budget.calls, 12);
      expect(budget.gitLabRequests, 24);
      expect(resets, 1);
      h.respond = (_, _) async => h.turn(text: 'new answer');
      await runner.run('new send');
      expect(budget.calls, 0);
      expect(budget.gitLabRequests, 0);
      expect(resets, 2);
    },
  );

  test(
    'unsent refused ticket uses no model allowance on the same run',
    () async {
      final h = base.Harness();
      final gate = _gate(h)..refuse = AiExecutionPauseReason.unavailable;
      var models = 0;
      var resets = 0;
      h.respond = (_, _) async => ++models < 6
          ? h.turn(calls: [base.call('read-$models')])
          : h.turn(text: 'answer');
      final runner = _runner(
        h,
        gate: gate,
        reset: () {
          resets++;
        },
      );
      final refused = await runner.run('inspect');
      expect(refused.modelCalls, 0);
      expect(h.payloads, isEmpty);
      expect(runner.segment!.frozenLength, 0);
      gate.refuse = null;
      final resumed = await runner.resumeRun();
      expect(resumed.modelCalls, 6);
      expect(models, 6);
      expect(resets, 1);
    },
  );

  test(
    'paused wall time does not consume or reset the remaining active deadline',
    () async {
      final h = base.Harness();
      final gate = _gate(h);
      var clock = DateTime.utc(2026, 10, 28);
      var models = 0;
      h.respond = (_, _) async {
        clock = clock.add(Duration(minutes: ++models == 1 ? 11 : 1));
        return models == 1
            ? h.turn(calls: [base.call()])
            : h.turn(text: 'late');
      };
      h.execute = (call) async {
        gate.foreground = false;
        return _read(call);
      };
      final runner = _runner(h, gate: gate, now: () => clock);
      expect((await runner.run('read')).pause, isNotNull);
      expect(runner.remainingActiveTime, const Duration(minutes: 1));
      clock = clock.add(const Duration(days: 1));
      gate.foreground = true;
      final resumed = await runner.resumeRun();
      expect(resumed.reason, AiRunEnd.failed);
      expect(runner.remainingActiveTime, Duration.zero);
      expect(runner.canResume, isFalse);
      expect(models, 2);
    },
  );

  test(
    'interrupted read stays paired and its dead Future is not revived',
    () async {
      final h = base.Harness();
      final gate = _gate(h);
      final entered = Completer<void>();
      final pending = Completer<AiToolResult>();
      final results = <AiToolResult>[];
      var models = 0;
      var reads = 0;
      h.respond = (_, _) async => ++models <= 2
          ? h.turn(calls: [base.call('read-$models')])
          : h.turn(text: 'done');
      h.execute = (call) {
        reads++;
        entered.complete();
        return pending.future;
      };
      final runner = _runner(h, gate: gate, onResult: results.add);
      final first = runner.run('read');
      await entered.future;
      runner.pause(
        const AiExecutionPause(AiExecutionPauseReason.permitInactive),
      );
      expect((await first).pause, isNotNull);
      expect(results.single.notExecuted, isTrue);
      await runner.resumeRun();
      expect(reads, 1);
      final count = results.length;
      pending.complete(_read(base.call('read-1')));
      await Future<void>.delayed(Duration.zero);
      expect(results, hasLength(count));
    },
  );

  for (final service in [false, true]) {
    test(
      'controller ${service ? "makes background progress" : "requires explicit same-run resume"}',
      () async {
        final h = await fx.StackHarness.create();
        addTearDown(h.dispose);
        final native = _Native(denied: !service)..install();
        addTearDown(native.uninstall);
        final owner = _owner(h);
        addTearDown(owner.dispose);
        h.controller.bindBackgroundExecution(owner);
        h.provider.script.add((_) {
          h.foreground = false;
          return fx.toolTurn('read_file', {
            'path': 'README.md',
            'revision': 'head',
          });
        });
        final id = h.controller.id;
        await h.controller.send('inspect the file');
        if (service) {
          expect(h.controller.lastEnd, AiRunEnd.done);
          expect(h.provider.bodies, hasLength(2));
          expect(native.tickets, greaterThanOrEqualTo(2));
        } else {
          expect(h.controller.executionPause, isNotNull);
          expect(
            h.controller.serviceStartResult?.failure,
            AiBackgroundStartFailure.startDenied,
          );
          expect(h.provider.bodies, hasLength(1));
          h.foreground = true;
          await owner.onForeground();
          await fx.waitFor(() => h.controller.canResumeRun);
          expect(native.starts, 1);
          expect(h.provider.bodies, hasLength(1));
          await h.controller.resumeRun();
          expect(h.controller.id, id);
          expect(h.controller.lastEnd, AiRunEnd.done);
          expect(native.starts, 2);
          expect(h.provider.bodies, hasLength(2));
          expect(h.controller.items.whereType<AiUserItem>(), hasLength(1));
        }
      },
    );
  }

  test(
    'approval wait releases FGS; background approval refuses; explicit approval restarts once',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final native = _Native()..install();
      addTearDown(native.uninstall);
      final owner = _owner(h);
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic issue', 'confidential': false},
          'reason': 'User asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue');
      await fx.waitFor(
        () => h.controller.phase == AiChatPhase.awaitingApproval,
      );
      await fx.waitFor(() => !native.active);
      expect(h.controller.serviceWorkCount, 0);
      expect(h.controller.backProtectedCount, 1);
      final proposal = h.controller.proposals.single;
      final expiry = proposal.expiresAt;
      h.foreground = false;
      final refused = await h.controller.approveWrite(proposal);
      expect(refused.state, AiJournalState.notExecuted);
      expect(native.starts, 1);
      expect(h.server.mutations, isEmpty);
      expect(proposal.valid, isTrue);
      h.foreground = true;
      final accepted = await h.controller.approveWrite(proposal);
      await sending;
      expect(accepted.state, AiJournalState.succeeded);
      expect(proposal.expiresAt, expiry);
      expect(native.starts, 2);
      expect(h.server.mutations, hasLength(1));
      await fx.waitFor(() => !native.active);
    },
  );

  for (final scenario in [
    (boundary: 'secrets', service: false),
    (boundary: 'issue', service: false),
    (boundary: 'notes', service: false),
    (boundary: 'failure', service: false),
    (boundary: 'issue', service: true),
  ]) {
    final (:boundary, :service) = scenario;
    test(
      boundary == 'failure'
          ? 'background read failure preserves the context blocker'
          : service
          ? 'permitted context refresh continues after $boundary in background'
          : 'serviceless context refresh pauses after $boundary until explicit resume',
      () async {
        var offset = Duration.zero;
        var holdSecrets = false;
        final entered = Completer<void>();
        final response = Completer<void>();
        addTearDown(() {
          if (!response.isCompleted) response.complete();
        });
        final h = await fx.StackHarness.create(
          now: () => DateTime.now().add(offset),
          refreshSecrets: () async {
            if (holdSecrets) {
              if (!entered.isCompleted) entered.complete();
              await response.future;
            }
          },
          configure: (server) {
            server.workspace.issues[1] = server.workspace.issue(
              1,
              'Synthetic issue',
            );
            server.overrides['GET projects/42/issues/1/notes'] = (_) =>
                jsonResponse([]);
          },
          origin: AiWorkItemOrigin(
            project: WorkspaceFixture().project,
            kind: AiWorkItemKind.issue,
            iid: 1,
            title: 'Synthetic issue',
          ),
        );
        addTearDown(h.dispose);
        final native = _Native(denied: !service)..install();
        addTearDown(native.uninstall);
        final owner = _owner(h);
        addTearDown(owner.dispose);
        h.controller.bindBackgroundExecution(owner);
        final context = h.controller.contextForTesting;
        final id = h.controller.id;
        h.server.overrides['GET projects/42/issues/1'] = (request) async {
          // The controller sees an expired snapshot, while the fresh response
          // uses the transport's real clock.
          offset = Duration.zero;
          if (boundary == 'issue' || boundary == 'failure') {
            if (!entered.isCompleted) entered.complete();
            await response.future;
          }
          if (boundary == 'failure') return jsonResponse({}, status: 403);
          return h.server.workspace.respond(request);
        };
        if (boundary == 'notes') {
          h.server.overrides['GET projects/42/issues/1/notes'] = (_) async {
            if (!entered.isCompleted) entered.complete();
            await response.future;
            return jsonResponse([]);
          };
        }
        holdSecrets = boundary == 'secrets';
        offset = const Duration(minutes: 2);
        h.session.api!.clearReadCache();
        final requestsBefore = h.server.adapter.requests.length;
        final sending = h.controller.send('inspect the issue');
        await entered.future;
        final requestsAtBoundary = h.server.adapter.requests.length;
        expect(
          requestsAtBoundary - requestsBefore,
          boundary == 'secrets' ? 0 : boundary == 'notes' ? 2 : 1,
        );
        h.foreground = false;
        owner.didChangeAppLifecycleState(AppLifecycleState.hidden);
        holdSecrets = false;
        response.complete();
        await sending;
        if (service) {
          expect(h.controller.lastEnd, AiRunEnd.done);
          expect(h.controller.executionPause, isNull);
          expect(h.server.adapter.requests, hasLength(requestsBefore + 4));
          expect(h.provider.bodies, hasLength(1));
          expect(native.starts, 1);
          expect(h.server.mutations, isEmpty);
          return;
        }
        expect(
          h.server.adapter.requests,
          hasLength(requestsAtBoundary),
          reason: 'settling a read must not dispatch the next context read',
        );
        expect(h.provider.bodies, isEmpty);
        if (boundary == 'failure') {
          expect(h.controller.executionPause, isNull);
          expect(h.controller.lastEnd, AiRunEnd.failed);
          expect(h.controller.blocker, AiChatBlocker.contextUnavailable);
          h.foreground = true;
          await owner.onForeground();
          expect(h.controller.canResumeRun, isFalse);
          return;
        }
        expect(
          h.controller.executionPause?.reason,
          AiExecutionPauseReason.foregroundRequired,
        );
        expect(h.controller.blocker, AiChatBlocker.none);
        expect(h.controller.contextForTesting, same(context));
        expect(h.controller.canResumeRun, isFalse);
        await h.controller.resumeRun();
        expect(h.server.adapter.requests, hasLength(requestsAtBoundary));
        h.foreground = true;
        owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await owner.onForeground();
        await fx.waitFor(() => h.controller.canResumeRun);
        expect(native.starts, 1);
        expect(h.server.adapter.requests, hasLength(requestsAtBoundary));
        expect(h.provider.bodies, isEmpty);

        // Force one complete refresh after the explicit foreground action.
        offset = const Duration(minutes: 2);
        h.session.api!.clearReadCache();
        await h.controller.resumeRun();
        expect(h.controller.id, id);
        expect(h.controller.lastEnd, AiRunEnd.done);
        expect(h.controller.executionPause, isNull);
        expect(native.starts, 2);
        expect(h.provider.bodies, hasLength(1));
        expect(h.provider.bodies.single, contains('inspect the issue'));
        expect(h.controller.items.whereType<AiUserItem>(), hasLength(1));
        expect(h.server.mutations, isEmpty);
        expect(
          h.server.adapter.requests.skip(requestsAtBoundary).map(
            (request) => request.uri.path.split('/api/v4/').last,
          ),
          [
            'projects/42/issues/1',
            'projects/42/issues/1/notes',
            'projects/42',
            'projects/42/repository/branches/main',
          ],
        );
        await h.controller.resumeRun();
        expect(h.server.adapter.requests, hasLength(requestsAtBoundary + 4));
        expect(h.provider.bodies, hasLength(1));
        expect(h.controller.budgetAllocator.activeLeases, 0);
      },
    );
  }

  test(
    'pre-run pause carries spent preparation time into the resumed runner',
    () async {
      var clock = DateTime.now();
      final h = await fx.StackHarness.create(now: () => clock);
      addTearDown(h.dispose);
      final native = _Native(
        denied: true,
        onStart: (count) {
          clock = clock.add(Duration(seconds: count == 1 ? 660 : 30));
          if (count == 1) h.foreground = false;
        },
      )..install();
      addTearDown(native.uninstall);
      final owner = _owner(h);
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      await h.controller.send('inspect the file');
      expect(
        h.controller.executionPause?.reason,
        AiExecutionPauseReason.foregroundRequired,
      );
      expect(h.provider.bodies, isEmpty);
      clock = clock.add(const Duration(hours: 1));
      h.foreground = true;
      await fx.waitFor(() => h.controller.canResumeRun);
      expect(native.starts, 1);
      h.provider.script.add((_) {
        clock = clock.add(const Duration(seconds: 30));
        return fx.toolTurn('read_file', {
          'path': 'README.md',
          'revision': 'head',
        });
      });
      await h.controller.resumeRun();
      expect(h.controller.lastEnd, AiRunEnd.failed);
      expect(h.controller.canResumeRun, isFalse);
      expect(native.starts, 2);
      expect(h.provider.bodies, hasLength(1));
      expect(h.controller.items.whereType<AiUserItem>(), hasLength(1));
      expect(h.server.mutations, isEmpty);
    },
  );

  test(
    'failed pre-run continuation cannot revive an older paused runner',
    () async {
      var clock = DateTime.now();
      final h = await fx.StackHarness.create(now: () => clock);
      addTearDown(h.dispose);
      final native = _Native(
        denied: true,
        onStart: (count) {
          if (count == 2) {
            clock = clock.add(const Duration(minutes: 11));
            h.foreground = false;
          } else if (count == 3) {
            clock = clock.add(const Duration(minutes: 1));
          }
        },
      )..install();
      addTearDown(native.uninstall);
      final owner = _owner(h);
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      h.provider.script.add((_) {
        h.foreground = false;
        return fx.toolTurn('read_file', {
          'path': 'README.md',
          'revision': 'head',
        });
      });
      await h.controller.send('older paused run');
      h.foreground = true;
      await fx.waitFor(() => h.controller.canResumeRun);
      await h.controller.send('new pending turn');
      expect(h.provider.bodies, hasLength(1));
      expect(h.controller.executionPause, isNotNull);
      h.foreground = true;
      await fx.waitFor(() => h.controller.canResumeRun);
      await h.controller.resumeRun();
      expect(h.controller.lastEnd, AiRunEnd.failed);
      expect(h.controller.canResumeRun, isFalse);
      expect(native.starts, 3);
      expect(h.controller.backProtectedCount, 0);
      expect(h.provider.bodies, hasLength(1));
      expect(h.controller.items.whereType<AiUserItem>(), hasLength(2));
      expect(h.server.mutations, isEmpty);
    },
  );

  test(
    'observed permit loss in foreground needs explicit resume, no lifecycle retry',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final native = _Native()..install();
      addTearDown(native.uninstall);
      final owner = _owner(h);
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      h.provider.script.add((_) {
        native.active = false;
        return fx.toolTurn('read_file', {
          'path': 'README.md',
          'revision': 'head',
        });
      });
      await h.controller.send('inspect');
      expect(h.controller.executionPause, isNotNull);
      await owner.onForeground();
      owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await fx.waitFor(() => h.controller.canResumeRun);
      expect(native.starts, 1);
      expect(h.provider.bodies, hasLength(1));
      await h.controller.resumeRun();
      expect(native.starts, 2);
      expect(h.controller.lastEnd, AiRunEnd.done);
      expect(h.provider.bodies, hasLength(2));
    },
  );

  test(
    'service preparation consumes the same active allowance on resume',
    () async {
      var clock = DateTime.now();
      final h = await fx.StackHarness.create(now: () => clock);
      addTearDown(h.dispose);
      final native = _Native(
        denied: true,
        onStart: (count) {
          clock = clock.add(Duration(minutes: count == 1 ? 11 : 1));
        },
      )..install();
      addTearDown(native.uninstall);
      final owner = _owner(h);
      addTearDown(owner.dispose);
      h.controller.bindBackgroundExecution(owner);
      h.provider.script.add((_) {
        h.foreground = false;
        return fx.toolTurn('read_file', {
          'path': 'README.md',
          'revision': 'head',
        });
      });
      await h.controller.send('inspect');
      expect(h.provider.bodies, hasLength(1));
      h.foreground = true;
      await fx.waitFor(() => h.controller.canResumeRun);
      await h.controller.resumeRun();
      expect(h.controller.lastEnd, AiRunEnd.failed);
      expect(h.controller.canResumeRun, isFalse);
      expect(h.provider.bodies, hasLength(1));
      expect(h.controller.items.whereType<AiUserItem>(), hasLength(1));
      expect(native.starts, 2);
    },
  );

  test(
    'continuation refreshes only its interrupted write when a read reused the call ID',
    () async {
      final h = base.Harness();
      final gate = _gate(h);
      final writes = _SettlingWrite();
      var models = 0;
      h.respond = (_, _) async => switch (++models) {
        1 => h.turn(calls: [base.call('reused')]),
        3 => h.turn(
          calls: [AiToolCall(id: 'reused', name: 'setStar', arguments: {})],
        ),
        _ => h.turn(text: 'done'),
      };
      h.execute = (call) async => AiToolResult(
        callId: call.id,
        name: call.name,
        content: 'distinct earlier read',
      );
      final runner = _runner(
        h,
        gate: gate,
        writes: writes,
        tools: [
          base.spec,
          AiToolSpec(
            name: 'setStar',
            description: 'Synthetic write',
            parameters: {
              'type': 'object',
              'properties': {},
              'additionalProperties': false,
            },
          ),
        ],
      );
      await runner.run('first read');
      final running = runner.run('new write');
      await writes.entered.future;
      runner.stop();
      await running;
      writes.recorded = const AiWriteOutcome(
        state: AiJournalState.succeeded,
        reasonCode: 'lateSuccess',
        operationId: 'setStar',
        mutationCount: 1,
      );
      writes.done.complete(writes.recorded);
      await Future<void>.delayed(Duration.zero);
      await runner.resumeRun();
      final projected = h.payloads.last;
      expect(
        projected,
        contains('[tool read_file: [source: tool read_file]; 21 chars; read]'),
      );
      expect('write setStar: succeeded'.allMatches(projected), hasLength(1));
      expect(writes.executions, 1);
    },
  );

  test(
    'late settled write is projected once on resume without dispatch replay',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final response = Completer<void>();
      addTearDown(() {
        if (!response.isCompleted) response.complete();
      });
      h.server.overrides['POST projects/42/issues'] = (request) async {
        await response.future;
        return h.server.workspace.respond(request);
      };
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic late success', 'confidential': false},
          'reason': 'User asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue');
      await fx.waitFor(
        () => h.controller.phase == AiChatPhase.awaitingApproval,
      );
      final approval = h.controller.approveWrite(h.controller.proposals.single);
      await fx.waitFor(() => h.server.mutations.isNotEmpty);
      h.controller.stop();
      await sending;
      expect(
        h.controller.canResumeRun,
        isFalse,
        reason: 'old HTTP still owns its budget',
      );
      response.complete();
      expect((await approval).state, AiJournalState.succeeded);
      await fx.waitFor(() => h.controller.canResumeRun);
      await h.controller.resumeRun();
      expect(h.controller.lastEnd, AiRunEnd.done);
      expect(h.server.mutations, hasLength(1));
      final projected = h.provider.bodies.last;
      expect(projected, contains(': succeeded; succeeded;'));
      expect('[tool createIssue:'.allMatches(projected), hasLength(1));
      expect(projected, isNot(contains('write_pending')));
      expect(h.journal.conversationWriteCount(h.account, h.controller.id), 1);
    },
  );

  testWidgets(
    'expired preparation cannot replace a later context and holds its read lease',
    (tester) async {
      var offset = Duration.zero;
      final h = (await tester.runAsync(
        () => fx.StackHarness.create(
          now: () => DateTime.now().add(offset),
          configure: (server) {
            server.workspace.issues[1] = server.workspace.issue(
              1,
              'Synthetic issue',
            );
            server.overrides['GET projects/42/issues/1/notes'] = (_) =>
                jsonResponse([]);
          },
          origin: AiWorkItemOrigin(
            project: WorkspaceFixture().project,
            kind: AiWorkItemKind.issue,
            iid: 1,
            title: 'Synthetic issue',
          ),
        ),
      ))!;
      addTearDown(h.dispose);
      offset = const Duration(minutes: 2);
      final entered = Completer<void>();
      final response = Completer<void>();
      addTearDown(() {
        if (!response.isCompleted) response.complete();
      });
      h.server.overrides['GET projects/42/issues/1'] = (request) async {
        if (!entered.isCompleted) entered.complete();
        await response.future;
        return h.server.workspace.respond(request);
      };
      final expired = h.controller.send('old attempt');
      for (var i = 0; i < 30 && !entered.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(
        entered.isCompleted,
        isTrue,
        reason:
            '${h.controller.phase} ${h.controller.failure} ${h.controller.blocker}; '
            '${h.server.adapter.requests.map((r) => '${r.method} ${r.uri.path}').toList()}',
      );
      await tester.pump(const Duration(minutes: 12));
      await expired;
      expect(h.controller.lastEnd, AiRunEnd.failed);
      expect(h.controller.budgetAllocator.activeLeases, 1);
      offset = Duration.zero;
      h.server.overrides.remove('GET projects/42/issues/1');
      final next = h.controller.send('new attempt');
      for (var i = 0; i < 30 && h.controller.phase != AiChatPhase.idle; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await next;
      expect(h.controller.lastEnd, AiRunEnd.done);
      final context = h.controller.contextForTesting;
      response.complete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(h.controller.contextForTesting, same(context));
      expect(h.controller.lastEnd, AiRunEnd.done);
      expect(h.controller.budgetAllocator.activeLeases, 0);
    },
  );
}

AiBackgroundExecution _owner(fx.StackHarness h) => AiBackgroundExecution(
  accountKey: h.account,
  generation: h.session.generation,
  ownerApi: h.session.api!,
  isCurrent: () => !h.controller.isDisposed,
  appInForeground: () => h.foreground,
  channel: _channel,
);

final class _SettlingWrite
    implements AiWriteCoordinator, AiWriteRunContinuation, AiWriteStateSource {
  final entered = Completer<void>();
  final done = Completer<AiWriteOutcome>();
  var executions = 0;
  AiWriteOutcome recorded = const AiWriteOutcome(
    state: AiJournalState.writeUncertain,
    reasonCode: 'writePending',
    operationId: 'setStar',
  );
  @override
  bool handles(String name) => name == 'setStar';
  @override
  void beginRun(String userUtterance) {}
  @override
  void resumeRun() {}
  @override
  void beginSegment() {}
  @override
  void beginTurn() {}
  @override
  void checkNow() {}
  @override
  void stop([String reason = 'stopped']) {}
  @override
  AiWriteOutcome? recordedOutcomeFor(String callId) => recorded;
  @override
  Future<AiWriteOutcome> execute(
    AiToolCall call, {
    void Function(bool)? onAwaitingApproval,
  }) {
    executions++;
    entered.complete();
    return done.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Native {
  _Native({this.denied = false, this.onStart});
  final bool denied;
  final void Function(int)? onStart;
  int starts = 0;
  int tickets = 0;
  bool active = false;
  String get permit => 'permit-$starts';
  void install() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        final a = call.arguments as Map<Object?, Object?>;
        switch (call.method) {
          case 'moveTaskToBack':
            return {
              'version': 1,
              'status': 'unsupported',
              'reason': 'not_implemented',
            };
          case 'startRuns':
            starts++;
            onStart?.call(starts);
            if (denied) {
              return {
                'version': 1,
                'status': 'rejected',
                'reason': 'start_denied',
              };
            }
            active = true;
            return {
              'version': 1,
              'status': 'active',
              'permitId': permit,
              'startRequestId': a['startRequestId'],
              'opSeq': a['opSeq'],
            };
          case 'releaseRuns':
            final released = active;
            active = false;
            return {'version': 1, 'status': 'released', 'didRelease': released};
          case 'updateProgress':
            return {'version': 1, 'status': 'updated', 'permitId': permit};
          case 'acquireContinuation':
            if (!active) {
              return {
                'version': 1,
                'status': 'rejected',
                'reason': 'permit_inactive',
              };
            }
            tickets++;
            return {
              'version': 1,
              'status': 'ticket',
              'permitId': permit,
              'kind': a['kind'],
              'nonce': a['nonce'],
              'ticketId':
                  '00000000-0000-4000-8000-${tickets.toString().padLeft(12, '0')}',
            };
          case 'stopAll':
            active = false;
            return {'version': 1, 'status': 'stopped'};
        }
        throw StateError('Unexpected method ${call.method}');
      });
  void uninstall() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null);
}
