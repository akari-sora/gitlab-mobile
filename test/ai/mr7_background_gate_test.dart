import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_gate.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';

import '../../tool/mr6c_qa_protocol.dart';
import 'fx_coord_support.dart' as fx;
import 'release_policy_support.dart';

const _channel = MethodChannel('mr7-background-gate');

Matcher _paused(AiExecutionPauseReason reason) => isA<AiExecutionPaused>()
    .having((error) => error.pause.reason, 'reason', reason);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late bool visible;
  late Duration now;
  late AiBackgroundExecution owner;
  late AiBackgroundRunGate gate;

  AiBackgroundExecution makeOwner({
    bool backgroundEnabled = false,
    String account = 'synthetic-account',
    int generation = 1,
    Object? api,
  }) {
    final result = AiBackgroundExecution(
      backgroundEnabled: backgroundEnabled,
      accountKey: account,
      generation: generation,
      ownerApi: api ?? Object(),
      isCurrent: () => true,
      appInForeground: () => visible,
      channel: _channel,
      clock: () => now,
    );
    addTearDown(result.dispose);
    return result;
  }

  setUp(() {
    calls = [];
    visible = true;
    now = Duration.zero;
    // A willing native peer makes any accidental start/permit acquisition
    // observable; the disabled flag must stop before reaching this handler.
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map<Object?, Object?>;
      return switch (call.method) {
        'startRuns' => {
          'version': 1,
          'status': 'active',
          'permitId': 'synthetic-permit',
          'startRequestId': args['startRequestId'],
          'opSeq': args['opSeq'],
        },
        'acquireContinuation' => {
          'version': 1,
          'status': 'ticket',
          'permitId': args['permitId'],
          'kind': args['kind'],
          'nonce': args['nonce'],
          'ticketId': '00000000-0000-4000-8000-000000000001',
        },
        'releaseRuns' => {
          'version': 1,
          'status': 'released',
          'didRelease': true,
        },
        _ => {'version': 1, 'status': 'rejected', 'reason': 'permit_inactive'},
      };
    });
    owner = makeOwner();
    gate = owner.createGate(
      conversationId: () => 'synthetic-conversation',
      isCurrent: () => true,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test(
    'production registry passes the compile-time background value',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final registry = AccountAiRunRegistry(
        session: h.session,
        settings: h.settings,
      );
      addTearDown(registry.dispose);
      expect(
        registry.backgroundExecution.backgroundEnabled,
        aiBackgroundEnabled,
      );
    },
  );

  test('every production constructor uses the const without runtime input', () {
    const wiring = {
      'lib/features/ai/ai_chat_controller.dart',
      'lib/features/ai/ai_run_registry.dart',
      'lib/features/shell/authenticated_app.dart',
    };
    final constructors = RegExp(r'\bAiBackgroundExecution\s*\(');
    final constWiring = RegExp(
      r'\bAiBackgroundExecution\s*\(\s*backgroundEnabled:\s*aiBackgroundEnabled\s*,',
    );
    final found = <String>{};
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final path = file.path.replaceAll('\\', '/');
      final source = file.readAsStringSync();
      expect(source, isNot(contains('testBackgroundEnabled')), reason: path);
      if (path == 'lib/features/ai/ai_background_execution.dart') {
        expect(source, contains('required this.backgroundEnabled,'));
        expect(source, contains('final bool backgroundEnabled;'));
        expect(source, isNot(contains('fromEnvironment')));
        expect(source, isNot(contains('Platform.environment')));
        expect(source, isNot(contains('aiBackgroundEnabled')));
        continue;
      }
      final count = constructors.allMatches(source).length;
      if (count > 0) {
        found.add(path);
        expect(constWiring.allMatches(source), hasLength(count), reason: path);
      }
      if (path != 'lib/features/ai/ai_gate.dart') {
        expect(
          RegExp(r'\baiBackgroundEnabled\b').allMatches(source),
          hasLength(count),
          reason:
              'The compile-time value is read only in production wiring: $path',
        );
      }
    }
    expect(found, unorderedEquals(wiring));
  });

  test('QA commands cannot supply the test constructor value', () {
    const command = <String, Object>{
      'schema': 1,
      'session': 'mr7-background',
      'case': 'V9',
      'variant': 'task_manager_stop',
      'phase': 'prepare',
      'sequence': 1,
    };
    for (final key in [
      'backgroundEnabled',
      'testBackgroundEnabled',
      'MERGELINE_AI_BACKGROUND',
      '--background-enabled',
    ]) {
      expect(
        () => QaCommand.parse({...command, key: true}),
        throwsA(isA<QaProtocolException>()),
      );
    }
  });

  test(
    'explicit injection runs native background with the compile flag off',
    () async {
      expect(aiBackgroundEnabled, isFalse);
      final enabledOwner = makeOwner(backgroundEnabled: true);
      final enabledGate = enabledOwner.createGate(
        conversationId: () => 'synthetic-enabled-conversation',
        isCurrent: () => true,
      );
      final result = await enabledGate.beginRun(runId: 'synthetic-enabled-run');
      expect(result.disposition, AiBackgroundStartDisposition.active);
      expect(enabledGate.binding.permitId, 'synthetic-permit');
      visible = false;
      enabledOwner.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(enabledGate.executionEligible, isTrue);
      final ticket = await enabledGate.acquire(AiContinuationKind.model);
      now += AiExecutionTicket.ttl;
      expect(
        () => ticket.consumeOnce(
          binding: enabledGate.binding,
          kind: AiContinuationKind.model,
        ),
        throwsA(_paused(AiExecutionPauseReason.ticketExpired)),
      );
      expect(calls.where((call) => call.method == 'startRuns'), hasLength(1));
      expect(
        calls.where((call) => call.method == 'acquireContinuation'),
        hasLength(1),
      );
    },
  );

  group('disabled background', () {
    tearDown(() {
      expect(calls.where((call) => call.method == 'startRuns'), isEmpty);
      expect(
        calls.where((call) => call.method == 'acquireContinuation'),
        isEmpty,
      );
      expect(
        calls,
        isEmpty,
        reason: 'disabled background needs no native permit',
      );
    });

    test(
      'background defaults off and assistant keeps its compile-time default',
      () {
        // Using these values in a const expression also locks out runtime setters.
        const flags = <bool>[aiBackgroundEnabled, aiAssistantEnabled];
        expect(flags.first, isFalse);
        expect(
          flags.last,
          const bool.fromEnvironment('MERGELINE_AI_ASSISTANT'),
        );
      },
    );

    test(
      'disabled background degrades start without service or permit',
      () async {
        final result = await gate.beginRun(runId: 'synthetic-run');
        expect(result.disposition, AiBackgroundStartDisposition.foregroundOnly);
        expect(result.failure, AiBackgroundStartFailure.unsupported);
        expect(gate.status, AiBackgroundExecutionStatus.foregroundOnly);
        expect(
          owner.cleanupConfirmation,
          AiBackgroundCleanupConfirmation.confirmed,
        );
        expect(gate.binding.permitId, isNull);
        expect(gate.executionEligible, isTrue);
        await owner.releaseRuns();
        expect(gate.binding.permitId, isNull);
      },
    );

    for (final kind in AiContinuationKind.values) {
      test(
        'foreground $kind works without a native ticket or local TTL',
        () async {
          await gate.beginRun(runId: 'synthetic-run');
          final ticket = await gate.acquire(kind);
          expect(ticket.binding.permitId, isNull);
          now += const Duration(minutes: 2);
          ticket.consumeOnce(binding: gate.binding, kind: kind);
          expect(
            () => ticket.consumeOnce(binding: gate.binding, kind: kind),
            throwsA(_paused(AiExecutionPauseReason.invalidTicket)),
          );
        },
      );

      test('hidden $kind is refused before acquiring any ticket', () async {
        await gate.beginRun(runId: 'synthetic-run');
        visible = false;
        expect(gate.executionEligible, isFalse);
        await expectLater(
          gate.acquire(kind),
          throwsA(_paused(AiExecutionPauseReason.foregroundRequired)),
        );
      });

      test('foreground $kind rechecks visibility at final consume', () async {
        await gate.beginRun(runId: 'synthetic-run');
        final ticket = await gate.acquire(kind);
        visible = false;
        expect(
          () => ticket.consumeOnce(binding: gate.binding, kind: kind),
          throwsA(_paused(AiExecutionPauseReason.foregroundRequired)),
        );
        visible = true;
        expect(
          () => ticket.consumeOnce(binding: gate.binding, kind: kind),
          throwsA(_paused(AiExecutionPauseReason.invalidTicket)),
        );
      });
    }

    test(
      'background pause requires explicit same-run foreground resume',
      () async {
        await gate.beginRun(runId: 'synthetic-run');
        final beforePause = gate.binding;
        final ticket = await gate.acquire(AiContinuationKind.model);
        visible = false;
        owner.didChangeAppLifecycleState(AppLifecycleState.hidden);
        expect(gate.requiresExplicitResume, isTrue);
        expect(
          (await gate.resumeRun()).failure,
          AiBackgroundStartFailure.foregroundRequired,
        );
        visible = true;
        owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
        expect(gate.executionEligible, isFalse);
        await expectLater(
          gate.acquire(AiContinuationKind.model),
          throwsA(_paused(AiExecutionPauseReason.foregroundRequired)),
        );
        final result = await gate.resumeRun();
        expect(result.disposition, AiBackgroundStartDisposition.foregroundOnly);
        expect(result.failure, AiBackgroundStartFailure.unsupported);
        expect(gate.binding.runId, 'synthetic-run');
        expect(gate.binding, isNot(same(beforePause)));
        expect(gate.binding.permitId, isNull);
        expect(gate.executionEligible, isTrue);
        expect(
          () => ticket.consumeOnce(
            binding: gate.binding,
            kind: AiContinuationKind.model,
          ),
          throwsA(_paused(AiExecutionPauseReason.invalidTicket)),
        );
      },
    );

    test(
      'runtime approval and forged binding cannot enable background',
      () async {
        await gate.beginRun(runId: 'synthetic-run');
        gate.setWork(
          active: false,
          backProtected: true,
          awaitingApproval: true,
        );
        await gate.pendingNormalRelease;
        final result = await gate.restartForApproval();
        expect(result.disposition, AiBackgroundStartDisposition.foregroundOnly);
        expect(gate.binding.permitId, isNull);
        expect(
          gate.binding.rebindForExplicitContinuation(
            runId: 'synthetic-run',
            permitId: 'forged-native-permit',
          ),
          isTrue,
        );
        expect(gate.executionEligible, isFalse);
        for (final kind in AiContinuationKind.values) {
          await expectLater(
            gate.acquire(kind),
            throwsA(_paused(AiExecutionPauseReason.permitInactive)),
          );
        }
        await gate.resumeRun();
        expect(gate.binding.permitId, isNull);
        expect(aiBackgroundEnabled, isFalse);
      },
    );

    test(
      'real controller sends in foreground and stops while hidden',
      () async {
        final h = await fx.StackHarness.create(origin: const AiGeneralOrigin());
        addTearDown(h.dispose);
        final execution = makeOwner(
          account: h.account,
          generation: h.session.generation,
          api: h.session.api!,
        );
        final controller = AiChatController(
          releasePolicy: fixtureReleasePolicy,
          origin: const AiGeneralOrigin(),
          session: h.session,
          settings: h.settings,
          runningCount: () => 0,
          appInForeground: () => visible,
          writeJournal: h.journal,
          wireClientFactory:
              ({required config, required apiKey, required conversationId}) =>
                  AiWireClient(
                    transport: AiTransport(
                      endpoint: AiEndpoint.parse(
                        config.baseUrl,
                        allowLanCleartext: false,
                      ),
                      apiKey: apiKey ?? '',
                      authStyle: config.authStyle,
                      adapter: h.provider.adapter,
                    ),
                    wire: const ResponsesFormat(),
                    config: config,
                    conversationId: conversationId,
                    appVersion: 'test',
                  ),
        )..bindBackgroundExecution(execution);
        addTearDown(controller.dispose);
        await controller.recheck();
        await controller.send('answer without tools');
        expect(h.provider.bodies, hasLength(1));
        expect(
          controller.items.whereType<AiAssistantItem>().single.text,
          'Done',
        );
        visible = false;
        execution.didChangeAppLifecycleState(AppLifecycleState.hidden);
        await controller.send('background execution must pause');
        expect(h.provider.bodies, hasLength(1));
        expect(controller.writeGatesOpen, isFalse);
      },
    );
  });
}
