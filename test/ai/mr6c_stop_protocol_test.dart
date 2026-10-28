import 'release_policy_support.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/tools/write_levels.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'fx_coord_support.dart' as fx;

const _channel = MethodChannel('io.gitlabmobile/agent_runs');

final class _Service {
  bool active = false;
  bool closed = false;
  int tickets = 0;
  int starts = 0;
  String permit = '';
  final requestByPermit = <String, String>{};
  final _rejectedStarts = <String, String>{};
  String? _pendingStartRequest;
  Completer<void>? holdStartReply;
  Completer<void>? startEntered;
  Completer<void>? holdReleaseReply;
  Completer<void>? releaseEntered;
  Completer<void>? holdStopReply;
  Completer<void>? stopEntered;
  final calls = <MethodCall>[];

  void install() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handle);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    if (closed) throw MissingPluginException();
    final args = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'startRuns':
        if (!active) permit = 'synthetic-permit-${++starts}';
        active = true;
        final issuedPermit = permit;
        requestByPermit[permit] = args['startRequestId']! as String;
        if (startEntered case final entered?) {
          if (!entered.isCompleted) entered.complete();
        }
        if (holdStartReply case final hold?) {
          _pendingStartRequest = args['startRequestId']! as String;
          await hold.future;
          _pendingStartRequest = null;
        }
        final rejection = _rejectedStarts.remove(args['startRequestId']);
        if (rejection != null) {
          return {'version': 1, 'status': 'rejected', 'reason': rejection};
        }
        return {
          'version': 1,
          'status': 'active',
          'permitId': issuedPermit,
          'startRequestId': args['startRequestId'],
          'opSeq': args['opSeq'],
        };
      case 'releaseRuns':
        if (releaseEntered case final entered?) {
          if (!entered.isCompleted) entered.complete();
        }
        if (holdReleaseReply case final hold?) await hold.future;
        final didRelease = active;
        active = false;
        return {'version': 1, 'status': 'released', 'didRelease': didRelease};
      case 'stopAll':
        active = false;
        if (stopEntered case final entered?) {
          if (!entered.isCompleted) entered.complete();
        }
        if (holdStopReply case final hold?) await hold.future;
        return {'version': 1, 'status': 'stopped'};
      case 'updateProgress':
        return active && args['permitId'] == permit
            ? {'version': 1, 'status': 'updated', 'permitId': permit}
            : {'version': 1, 'status': 'rejected', 'reason': 'permit_inactive'};
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
          'kind': args['kind'],
          'nonce': args['nonce'],
          'ticketId':
              '00000000-0000-4000-8000-${tickets.toString().padLeft(12, '0')}',
        };
    }
    throw StateError('Unexpected method ${call.method}');
  }

  Future<void> stop({required String reason, required bool deliver}) async {
    active = false;
    if (_pendingStartRequest case final request?) {
      // Native finishPending rejects the start before permitInvalidated.
      _rejectedStarts[request] = reason;
      holdStartReply!.complete();
      await Future<void>.delayed(Duration.zero);
    }
    if (!deliver) return;
    await callback(reason, permit);
  }

  Future<void> callback(
    String reason,
    String callbackPermit, {
    String? startRequestId,
    bool includeStartRequestId = true,
  }) async {
    final done = Completer<void>();
    final args = <String, Object>{
      'version': 1,
      'permitId': callbackPermit,
      'reason': reason,
    };
    final request = startRequestId ?? requestByPermit[callbackPermit];
    if (includeStartRequestId && request != null) {
      args['startRequestId'] = request;
    }
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('permitInvalidated', args),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }

  void uninstall() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null);
}

AiBackgroundExecution _owner(fx.StackHarness h) => AiBackgroundExecution(
  backgroundEnabled: true,
  accountKey: h.account,
  generation: h.session.generation,
  ownerApi: h.session.api!,
  isCurrent: () => h.session.api != null && !h.session.api!.isClosed,
  appInForeground: () => h.foreground,
  channel: _channel,
);

AccountAiRunRegistry _registry(
  fx.StackHarness h,
  AiBackgroundExecution owner, {
  List<AiChatController> others = const [],
}) => AccountAiRunRegistry(
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
      }) {
        final controller = [
          h.controller,
          ...others,
        ].singleWhere((controller) => controller.origin.key == origin.key);
        return (
          session: controller,
          capacityChanged: controller.notifyCapacityChanged,
          dispose: () {},
        );
      },
);

AiChatController _otherConversation(fx.StackHarness h) => AiChatController(
  releasePolicy: fixtureReleasePolicy,
  origin: AiJobOrigin(
    project: h.server.workspace.project,
    jobId: 501,
    jobName: 'Synthetic job',
  ),
  session: h.session,
  settings: h.settings,
  runningCount: () => 1,
  appInForeground: () => h.foreground,
  clientMayStart: () => true,
  writeJournal: h.journal,
  attachmentPicker: h.picker,
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
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Service native;
  setUp(() {
    native = _Service()..install();
  });
  tearDown(() => native.uninstall());

  test(
    'notification user stop reaches registry and cancels pending approval',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final owner = _owner(h);
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
              dispose: () {},
            ),
      );
      addTearDown(registry.dispose);
      registry.open(h.controller.origin);
      // Keep a second run active while the first waits for approval.
      final other = owner.createGate(
        conversationId: () => 'second',
        isCurrent: () => true,
      );
      await other.beginRun(runId: 'second-run');
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic bug', 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue for the bug');
      await fx.waitFor(
        () => h.controller.phase == AiChatPhase.awaitingApproval,
      );
      final proposal = h.controller.proposals.single;
      expect(proposal.valid, isTrue);
      expect(native.active, isTrue);
      await native.stop(reason: 'user_stop', deliver: true);
      await sending;
      expect(proposal.valid, isFalse);
      expect(h.server.mutations, isEmpty);
      expect(h.session.api!.isClosed, isFalse);
      expect(other.status, AiBackgroundExecutionStatus.invalidated);
      final start = native.calls.firstWhere((c) => c.method == 'startRuns');
      expect(
        (start.arguments as Map)['stopAllLabel'],
        l10n.aiRunServiceStopAll,
      );
    },
  );

  test(
    'user stop during a delayed start stops a released approval and rejects late active',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final owner = _owner(h);
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
              dispose: () {},
            ),
      );
      addTearDown(registry.dispose);
      registry.open(h.controller.origin);
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic approval', 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue for the bug');
      await fx.waitFor(
        () => h.controller.phase == AiChatPhase.awaitingApproval,
      );
      final proposal = h.controller.proposals.single;
      await fx.waitFor(() => !native.active);
      final oldPermit = native.permit;
      final hold = Completer<void>();
      native.holdStartReply = hold;
      native.startEntered = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final pending = owner.createGate(
        conversationId: () => 'pending',
        isCurrent: () => true,
      );
      final start = pending.beginRun(runId: 'pending-run');
      await native.startEntered!.future.timeout(const Duration(seconds: 5));
      expect(native.permit, isNot(oldPermit));
      await native.callback('user_stop', oldPermit);
      expect(
        proposal.valid,
        isTrue,
        reason: 'a stale old-permit callback cannot stop the new start',
      );
      await native.callback(
        'user_stop',
        'unknown-old-permit',
        startRequestId: 'unknown-old-start',
      );
      expect(
        proposal.valid,
        isTrue,
        reason: 'an unseen old permit with another start request is stale',
      );
      expect(pending.status, AiBackgroundExecutionStatus.starting);
      // Deliberately model a callback preceding a late active reply here.
      // The reply-first rejection order is covered separately below.
      native.active = false;
      await native.callback('user_stop', native.permit);
      expect(proposal.valid, isFalse);
      expect(pending.status, AiBackgroundExecutionStatus.invalidated);
      hold.complete();
      await start;
      await sending;
      expect(pending.status, AiBackgroundExecutionStatus.invalidated);
      await expectLater(
        pending.acquire(AiContinuationKind.model),
        throwsA(isA<AiExecutionPaused>()),
      );
      expect(h.session.api!.isClosed, isFalse);
      expect(h.server.mutations, isEmpty);
    },
  );

  for (final deliver in [true, false]) {
    test(
      'rejected user_stop reply first, callback ${deliver ? 'delivered' : 'lost'}, stops approval once and keeps settlement',
      () async {
        final h = await fx.StackHarness.create(
          level: AiAutonomyLevel.conversationGrant,
        );
        addTearDown(h.dispose);
        await h.controller.setAutonomyLevel(AiAutonomyLevel.confirmEach);
        final writer = _otherConversation(h);
        addTearDown(writer.dispose);
        await writer.recheck();
        expect(writer.canSend, isTrue, reason: '${writer.blocker}');
        await writer.setAutonomyLevel(AiAutonomyLevel.conversationGrant);
        final owner = _owner(h);
        final registry = _registry(h, owner, others: [writer]);
        addTearDown(registry.dispose);
        registry.open(h.controller.origin);
        registry.open(writer.origin);
        var stops = 0;
        final subscription = owner.stopEvents.listen((_) => stops++);
        addTearDown(subscription.cancel);

        h.provider.script.add(
          (_) => fx.toolTurn('createIssue', {
            'projectId': 42,
            'fields': {'title': 'Synthetic approval', 'confidential': false},
            'reason': 'The user asked for an issue.',
          }),
        );
        final approvalSending = h.controller.send(
          'Create an issue for the bug',
        );
        await fx.waitFor(
          () => h.controller.phase == AiChatPhase.awaitingApproval,
        );
        final proposal = h.controller.proposals.single;
        await fx.waitFor(() => !native.active);

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
            'fields': {'title': 'Synthetic settlement', 'confidential': false},
            'reason': 'The user asked for an issue.',
          }),
        );
        final writing = writer.send('Create another issue for the bug');
        await fx.waitFor(() => h.server.mutations.isNotEmpty);
        final settling = writer.inFlightWrites.single;
        expect(registry.inFlightWrites, contains(same(settling)));
        // An earlier invalidated lifecycle can still own an accepted write.
        await native.stop(reason: 'timeout', deliver: true);
        expect(stops, 0);
        expect(proposal.valid, isTrue);

        final hold = Completer<void>();
        native.holdStartReply = hold;
        native.startEntered = Completer<void>();
        addTearDown(() {
          if (!hold.isCompleted) hold.complete();
        });
        final pending = owner.createGate(
          conversationId: () => 'pending',
          isCurrent: () => true,
        );
        final start = pending.beginRun(runId: 'pending-run');
        await native.startEntered!.future.timeout(const Duration(seconds: 5));
        // Explicitly await the rejected reply before delivering its callback.
        await native.stop(reason: 'user_stop', deliver: false);
        await start;
        expect(stops, 1);
        expect(proposal.valid, isFalse);
        expect(pending.status, AiBackgroundExecutionStatus.invalidated);
        if (deliver) {
          await native.callback('user_stop', native.permit);
          await native.callback('user_stop', native.permit);
        }
        expect(stops, 1);
        expect(h.session.api!.isClosed, isFalse);
        expect(registry.inFlightWrites, contains(same(settling)));
        response.complete();
        expect((await settling).state, AiJournalState.succeeded);
        await writing;
        await approvalSending;
        expect(h.server.mutations, hasLength(1));
        expect(stops, 1);
      },
    );
  }

  test(
    'delayed user stop callback after permit_inactive still stops the current lifecycle once',
    () async {
      final h = await fx.StackHarness.create();
      addTearDown(h.dispose);
      final owner = _owner(h);
      final registry = _registry(h, owner);
      addTearDown(registry.dispose);
      registry.open(h.controller.origin);
      var stops = 0;
      final subscription = owner.stopEvents.listen((_) => stops++);
      addTearDown(subscription.cancel);
      h.provider.script.add(
        (_) => fx.toolTurn('createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic approval', 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue for the bug');
      await fx.waitFor(
        () => h.controller.phase == AiChatPhase.awaitingApproval,
      );
      final proposal = h.controller.proposals.single;
      await fx.waitFor(() => !native.active);
      final gate = owner.createGate(
        conversationId: () => 'current',
        isCurrent: () => true,
      );
      await gate.beginRun(runId: 'current-run');
      await native.stop(reason: 'user_stop', deliver: false);
      await expectLater(
        gate.acquire(AiContinuationKind.model),
        throwsA(isA<AiExecutionPaused>()),
      );
      expect(gate.status, AiBackgroundExecutionStatus.invalidated);
      expect(stops, 0);
      expect(proposal.valid, isTrue);
      await native.callback('user_stop', native.permit);
      expect(stops, 1);
      expect(proposal.valid, isFalse);
      await native.callback('user_stop', native.permit);
      expect(stops, 1);
      expect(h.session.api!.isClosed, isFalse);
      expect(h.server.mutations, isEmpty);
      await sending;
    },
  );

  test('Dart stop during release consumes the native stop echo', () async {
    final h = await fx.StackHarness.create();
    addTearDown(h.dispose);
    final owner = _owner(h);
    addTearDown(owner.dispose);
    var stops = 0;
    final subscription = owner.stopEvents.listen((_) => stops++);
    addTearDown(subscription.cancel);
    final gate = owner.createGate(
      conversationId: () => 'run',
      isCurrent: () => true,
    );
    await gate.beginRun(runId: 'run');
    final permit = native.permit;
    final release = Completer<void>();
    final stop = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
      if (!stop.isCompleted) stop.complete();
    });
    native.holdReleaseReply = release;
    native.releaseEntered = Completer<void>();
    final releasing = owner.releaseRuns();
    await native.releaseEntered!.future.timeout(const Duration(seconds: 5));
    native.holdStopReply = stop;
    native.stopEntered = Completer<void>();
    final stopping = owner.stopAll();
    await native.stopEntered!.future.timeout(const Duration(seconds: 5));
    expect(stops, 1);
    await native.callback('user_stop', permit);
    await native.callback('user_stop', permit);
    expect(stops, 1);
    stop.complete();
    await stopping;
    release.complete();
    await releasing;
    expect(gate.status, AiBackgroundExecutionStatus.invalidated);
  });

  for (final disposeOldGate in [true, false]) {
    test(
      'cross-owner supersession with old gate ${disposeOldGate ? 'disposed' : 'reused'} preserves a newer foreground approval',
      () async {
        final h = await fx.StackHarness.create();
        addTearDown(h.dispose);
        final first = _owner(h);
        final registry = _registry(h, first);
        addTearDown(registry.dispose);
        registry.open(h.controller.origin);
        final second = _owner(h);
        addTearDown(second.dispose);
        var firstStops = 0;
        var secondStops = 0;
        final firstSubscription = first.stopEvents.listen((_) => firstStops++);
        final secondSubscription = second.stopEvents.listen(
          (_) => secondStops++,
        );
        addTearDown(firstSubscription.cancel);
        addTearDown(secondSubscription.cancel);

        final old = first.createGate(
          conversationId: () => 'old',
          isCurrent: () => true,
        );
        await old.beginRun(runId: 'old-run');
        final oldPermit = native.permit;
        await native.stop(reason: 'user_stop', deliver: false);
        await expectLater(
          old.acquire(AiContinuationKind.model),
          throwsA(isA<AiExecutionPaused>()),
        );
        expect(old.status, AiBackgroundExecutionStatus.invalidated);
        if (disposeOldGate) old.dispose();

        final current = second.createGate(
          conversationId: () => 'current',
          isCurrent: () => true,
        );
        await current.beginRun(runId: 'current-run');
        final currentPermit = native.permit;
        expect(currentPermit, isNot(oldPermit));
        expect(current.binding.permitId, currentPermit);
        if (!disposeOldGate) {
          await old.beginRun(runId: 'new-foreground-run');
          expect(old.binding.permitId, isNull);
          expect(old.executionEligible, isTrue);
        }

        h.provider.script.add(
          (_) => fx.toolTurn('createIssue', {
            'projectId': 42,
            'fields': {'title': 'Newer approval', 'confidential': false},
            'reason': 'The user asked for an issue.',
          }),
        );
        final sending = h.controller.send('Create an issue for the bug');
        await fx.waitFor(
          () => h.controller.phase == AiChatPhase.awaitingApproval,
        );
        final proposal = h.controller.proposals.single;
        expect(proposal.valid, isTrue);
        expect(firstStops, 0);
        expect(secondStops, 0);
        expect(native.starts, 2);

        await native.callback('user_stop', oldPermit);
        await native.callback(
          'user_stop',
          oldPermit,
          includeStartRequestId: false,
        );
        expect(
          proposal.valid,
          isTrue,
          reason:
              'a superseded permit must not cancel a newer foreground approval',
        );
        expect(h.controller.phase, AiChatPhase.awaitingApproval);
        expect(firstStops, 0);
        expect(secondStops, 0);
        expect(current.status, AiBackgroundExecutionStatus.active);
        expect(current.executionEligible, isTrue);
        expect(native.active, isTrue);
        expect(native.permit, currentPermit);
        expect(native.starts, 2);
        expect(h.server.mutations, isEmpty);
        expect(h.session.api!.isClosed, isFalse);

        // The current lifecycle still delivers one global stop to both owners.
        await native.stop(reason: 'user_stop', deliver: false);
        await native.callback(
          'user_stop',
          currentPermit,
          includeStartRequestId: false,
        );
        expect(proposal.valid, isFalse);
        expect(firstStops, 1);
        expect(secondStops, 1);
        expect(current.status, AiBackgroundExecutionStatus.invalidated);
        await native.callback('user_stop', currentPermit);
        expect(firstStops, 1);
        expect(secondStops, 1);
        expect(h.server.mutations, isEmpty);
        expect(h.session.api!.isClosed, isFalse);
        await sending;
      },
    );
  }

  for (final changedIdentity in ['account', 'generation', 'api']) {
    test(
      'stale $changedIdentity lifecycle cannot stop another session foreground approval',
      () async {
        final h = await fx.StackHarness.create();
        addTearDown(h.dispose);
        var oldCurrent = true;
        final oldOwner = AiBackgroundExecution(
          backgroundEnabled: true,
          accountKey: changedIdentity == 'account' ? 'old-account' : h.account,
          generation: changedIdentity == 'generation'
              ? h.session.generation - 1
              : h.session.generation,
          ownerApi: changedIdentity == 'api' ? Object() : h.session.api!,
          isCurrent: () => oldCurrent,
          appInForeground: () => h.foreground,
          channel: _channel,
        );
        addTearDown(() async {
          await oldOwner.stopAll();
          oldOwner.dispose();
        });
        final old = oldOwner.createGate(
          conversationId: () => 'old',
          isCurrent: () => true,
        );
        await old.beginRun(runId: 'old-run');
        final oldPermit = native.permit;
        oldCurrent = false;
        await native.stop(reason: 'user_stop', deliver: false);

        final currentOwner = _owner(h);
        final registry = _registry(h, currentOwner);
        addTearDown(registry.dispose);
        registry.open(h.controller.origin);
        var stops = 0;
        final subscription = currentOwner.stopEvents.listen((_) => stops++);
        addTearDown(subscription.cancel);
        h.provider.script.add(
          (_) => fx.toolTurn('createIssue', {
            'projectId': 42,
            'fields': {'title': 'New session approval', 'confidential': false},
            'reason': 'The user asked for an issue.',
          }),
        );
        final sending = h.controller.send('Create an issue for the bug');
        await fx.waitFor(
          () => h.controller.phase == AiChatPhase.awaitingApproval,
        );
        final proposal = h.controller.proposals.single;
        expect(proposal.valid, isTrue);
        expect(native.starts, 1);
        expect(stops, 0);
        await native.callback('user_stop', oldPermit);
        expect(
          proposal.valid,
          isTrue,
          reason: 'a stale session stop cannot cancel another session approval',
        );
        expect(stops, 0);
        expect(h.controller.phase, AiChatPhase.awaitingApproval);
        expect(native.starts, 1);
        expect(h.server.mutations, isEmpty);
        expect(h.session.api!.isClosed, isFalse);
        await h.controller.rejectWrite(proposal);
        await sending;
      },
    );
  }

  for (final released in [false, true]) {
    test(
      '${released ? 'released' : 'stopped'} permit callback replay preserves a newer pending approval',
      () async {
        final h = await fx.StackHarness.create();
        addTearDown(h.dispose);
        final owner = _owner(h);
        final registry = _registry(h, owner);
        addTearDown(registry.dispose);
        registry.open(h.controller.origin);
        var stops = 0;
        final subscription = owner.stopEvents.listen((_) => stops++);
        addTearDown(subscription.cancel);
        final old = owner.createGate(
          conversationId: () => 'old',
          isCurrent: () => true,
        );
        await old.beginRun(runId: 'old-run');
        final oldPermit = native.permit;
        if (released) {
          await owner.releaseRuns();
          old.release();
        } else {
          await native.stop(reason: 'user_stop', deliver: true);
        }
        final expectedStops = released ? 0 : 1;
        expect(stops, expectedStops);
        expect(
          old.status,
          released
              ? AiBackgroundExecutionStatus.released
              : AiBackgroundExecutionStatus.invalidated,
        );
        expect(old.binding.permitId, oldPermit);
        final current = owner.createGate(
          conversationId: () => 'current',
          isCurrent: () => true,
        );
        await current.beginRun(runId: 'current-run');
        final currentPermit = native.permit;
        expect(currentPermit, isNot(oldPermit));
        h.provider.script.add(
          (_) => fx.toolTurn('createIssue', {
            'projectId': 42,
            'fields': {'title': 'Newer approval', 'confidential': false},
            'reason': 'The user asked for an issue.',
          }),
        );
        final sending = h.controller.send('Create an issue for the bug');
        await fx.waitFor(
          () => h.controller.phase == AiChatPhase.awaitingApproval,
        );
        final proposal = h.controller.proposals.single;
        expect(proposal.valid, isTrue);
        await native.callback('user_stop', oldPermit);
        await native.callback('user_stop', oldPermit);
        expect(stops, expectedStops);
        expect(proposal.valid, isTrue);
        expect(current.status, AiBackgroundExecutionStatus.active);
        expect(native.permit, currentPermit);
        expect(h.server.mutations, isEmpty);
        expect(h.session.api!.isClosed, isFalse);
        await h.controller.rejectWrite(proposal);
        await sending;
      },
    );
  }

  test(
    'user stop preserves an accepted write and its final settlement',
    () async {
      final h = await fx.StackHarness.create(
        level: AiAutonomyLevel.conversationGrant,
      );
      addTearDown(h.dispose);
      final owner = _owner(h);
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
              dispose: () {},
            ),
      );
      addTearDown(registry.dispose);
      registry.open(h.controller.origin);
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
          'fields': {'title': 'Synthetic settlement', 'confidential': false},
          'reason': 'The user asked for an issue.',
        }),
      );
      final sending = h.controller.send('Create an issue for the bug');
      await fx.waitFor(() => h.server.mutations.isNotEmpty);
      final settling = registry.inFlightWrites.single;
      await native.stop(reason: 'user_stop', deliver: true);
      expect(h.session.api!.isClosed, isFalse);
      expect(registry.inFlightWrites, contains(same(settling)));
      response.complete();
      expect((await settling).state, AiJournalState.succeeded);
      await sending;
      expect(h.server.mutations, hasLength(1));
    },
  );

  for (final (deliver, modelFirst) in [
    (true, false),
    (false, false),
    (false, true),
  ]) {
    test(
      'timeout ${deliver ? 'delivered' : 'dropped'} ${modelFirst ? 'model first' : 'mutation first'} blocks later model and mutation while accepted write settles',
      () async {
        final h = await fx.StackHarness.create(
          level: AiAutonomyLevel.conversationGrant,
        );
        addTearDown(h.dispose);
        final owner = _owner(h);
        addTearDown(owner.dispose);
        h.controller.bindBackgroundExecution(owner);
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
            'fields': {'title': 'Synthetic settlement', 'confidential': false},
            'reason': 'The user asked for an issue.',
          }),
        );
        final sending = h.controller.send('Create an issue for the bug');
        await fx.waitFor(() => h.server.mutations.isNotEmpty);
        expect(h.controller.inFlightWrites, isNotEmpty);
        final settling = h.controller.inFlightWrites.single;
        final second = AiChatController(
          releasePolicy: fixtureReleasePolicy,
          origin: h.controller.origin,
          session: h.session,
          settings: h.settings,
          runningCount: () => 1,
          appInForeground: () => h.foreground,
          clientMayStart: () => true,
          writeJournal: h.journal,
          attachmentPicker: h.picker,
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
        );
        addTearDown(second.dispose);
        await second.recheck();
        await second.setAutonomyLevel(AiAutonomyLevel.conversationGrant);
        second.bindBackgroundExecution(owner);
        final entered = Completer<void>();
        final resume = Completer<void>();
        addTearDown(() {
          if (!resume.isCompleted) resume.complete();
        });
        h.provider.script.add((_) {
          h.server.overrides['GET projects/42'] = (request) async {
            if (!entered.isCompleted) entered.complete();
            await resume.future;
            return h.server.workspace.respond(request);
          };
          return fx.toolTurn('setStar', {
            'projectId': 42,
            'starred': true,
            'reason': 'The user asked to star the project.',
          });
        });
        final secondSending = second.send('Create another issue for the bug');
        await entered.future.timeout(const Duration(seconds: 10));
        // Accepted write and any issued ticket are classified before the baseline.
        final modelBaseline = h.provider.bodies.length;
        final mutationBaseline = h.server.mutations.length;
        final ticketBaseline = native.tickets;
        final callBaseline = native.calls.length;
        h.foreground = false;
        expect(native.active, isTrue);
        await native.stop(reason: 'timeout', deliver: deliver);
        expect(native.active, isFalse);
        if (modelFirst) {
          response.complete();
          await sending;
        } else {
          resume.complete();
          await secondSending;
        }
        if (modelFirst) {
          resume.complete();
          await secondSending;
        } else {
          response.complete();
          await sending;
        }
        expect((await settling).state, AiJournalState.succeeded);
        await fx.waitFor(() => h.controller.inFlightWrites.isEmpty);
        expect(h.provider.bodies.length - modelBaseline, 0);
        expect(h.server.mutations.length - mutationBaseline, 0);
        expect(native.tickets, ticketBaseline);
        expect(h.session.api!.isClosed, isFalse);
        expect(second.executionStatus, AiChatExecutionStatus.paused);
        if (!deliver) {
          expect(
            native.calls
                .skip(callBaseline)
                .where(
                  (call) =>
                      call.method == 'acquireContinuation' &&
                      (call.arguments as Map)['kind'] ==
                          (modelFirst ? 'model' : 'mutation'),
                ),
            isNotEmpty,
            reason: native.calls
                .skip(callBaseline)
                .map((call) => '${call.method} ${call.arguments}')
                .join(', '),
          );
        }
      },
    );
  }

  for (final reason in [
    'synthetic_timeout',
    'service_destroyed',
    'activity_destroyed',
  ]) {
    test(
      '$reason invalidates the current run without a foreground fallback',
      () async {
        final h = await fx.StackHarness.create();
        addTearDown(h.dispose);
        final owner = _owner(h);
        addTearDown(owner.dispose);
        final gate = owner.createGate(
          conversationId: () => 'run',
          isCurrent: () => true,
        );
        await gate.beginRun(runId: 'run');
        await native.stop(reason: reason, deliver: true);
        expect(gate.status, AiBackgroundExecutionStatus.invalidated);
        await expectLater(
          gate.acquire(AiContinuationKind.model),
          throwsA(isA<AiExecutionPaused>()),
        );
        expect(h.session.api!.isClosed, isFalse);
      },
    );
  }

  test('closed channel fails closed for both continuation kinds', () async {
    final h = await fx.StackHarness.create();
    addTearDown(h.dispose);
    final owner = _owner(h);
    addTearDown(owner.dispose);
    final gate = owner.createGate(
      conversationId: () => 'run',
      isCurrent: () => true,
    );
    await gate.beginRun(runId: 'run');
    h.foreground = false;
    native.active = false;
    native.closed = true;
    for (final kind in AiContinuationKind.values) {
      await expectLater(gate.acquire(kind), throwsA(isA<AiExecutionPaused>()));
    }
    expect(gate.status, AiBackgroundExecutionStatus.invalidated);
    expect(h.session.api!.isClosed, isFalse);
  });
}
