import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_run_notifications.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart' as fx;

const _account = 'https://synthetic.example/gitlab#7';
const _target = AiConflictKey([_account, 'project:9', 'issue:3']);
const _notificationChannel = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);

// A v1 channel peer. It does not model delivery of Android lifecycle callbacks.
final class _Native {
  _Native(this.channel);
  final MethodChannel channel;
  final calls = <MethodCall>[];
  String? permit;
  int starts = 0;
  int tickets = 0;
  Completer<void>? startReply;
  Completer<void>? releaseReply;
  bool releaseUnavailable = false;

  List<MethodCall> named(String name) => calls.where((call) {
    final args = call.arguments as Map<Object?, Object?>;
    return call.method == name && args['permitId'] != 'sequence-probe';
  }).toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'startRuns':
        final issued = permit = 'synthetic-permit-${++starts}';
        await startReply?.future;
        return {
          'version': 1,
          'status': 'active',
          'permitId': issued,
          'startRequestId': args['startRequestId'],
          'opSeq': args['opSeq'],
        };
      case 'releaseRuns':
        final matched = permit != null;
        permit = null;
        await releaseReply?.future;
        if (releaseUnavailable) return null;
        return {'version': 1, 'status': 'released', 'didRelease': matched};
      case 'stopAll':
        permit = null;
        return {'version': 1, 'status': 'stopped'};
      case 'updateProgress':
      case 'acquireContinuation':
        if (permit == null || args['permitId'] != permit) {
          return {
            'version': 1,
            'status': 'rejected',
            'reason': 'permit_inactive',
          };
        }
        if (call.method == 'updateProgress') {
          return {'version': 1, 'status': 'updated', 'permitId': permit};
        }
        return {
          'version': 1,
          'status': 'ticket',
          'permitId': permit,
          'kind': args['kind'],
          'nonce': args['nonce'],
          'ticketId':
              '00000000-0000-4000-8000-${(++tickets).toString().padLeft(12, '0')}',
        };
    }
    throw StateError('Unexpected synthetic method: ${call.method}');
  }
}

final class _TombstoneReadKeys extends MemoryAiJournalKeyStore {
  bool failTombstoneRead = false;

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) {
    if (failTombstoneRead) throw StateError('Synthetic tombstone read failure');
    return super.readTombstone(accountKey);
  }
}

AiJournalDraft _draft(String id, {AiConflictKey target = _target}) =>
    AiJournalDraft(
      executionId: id,
      accountKey: _account,
      conversationId: 'synthetic-conversation',
      runId: 'synthetic-run',
      operationId: 'createNote',
      writeKeys: {target},
      payloadSha256: List.filled(64, 'a').join(),
      releaseName: '#3',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var channelIndex = 0;

  (AiBackgroundExecution, _Native) execution({
    String account = _account,
    int generation = 1,
    Object? api,
    bool Function()? current,
    bool Function()? visible,
  }) {
    final channel = MethodChannel('mr6c-c7-${channelIndex++}');
    final native = _Native(channel);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, native.handle);
    final owner = AiBackgroundExecution(
      accountKey: account,
      generation: generation,
      ownerApi: api ?? Object(),
      isCurrent: current ?? () => true,
      appInForeground: visible ?? () => true,
      channel: channel,
    );
    addTearDown(() async {
      owner.dispose();
      await Future<void>.delayed(Duration.zero);
      messenger.setMockMethodCallHandler(channel, null);
    });
    return (owner, native);
  }

  AccountAiRunRegistry registry(
    fx.StackHarness h,
    AiBackgroundExecution owner,
  ) {
    final result = AccountAiRunRegistry(
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
    addTearDown(result.dispose);
    result.open(h.controller.origin);
    return result;
  }

  for (final kind in AiContinuationKind.values) {
    test(
      'Activity detach burns an issued ${kind.name} ticket without a callback',
      () async {
        final (owner, native) = execution();
        final gate = owner.createGate(
          conversationId: () => 'conversation',
          isCurrent: () => true,
        );
        await gate.beginRun(runId: 'run');
        final ticket = await gate.acquire(kind);
        owner.didChangeAppLifecycleState(AppLifecycleState.detached);
        expect(gate.executionEligible, isFalse);
        expect(gate.requiresExplicitResume, isTrue);
        expect(
          () => ticket.consumeOnce(binding: gate.binding, kind: kind),
          throwsA(isA<AiExecutionPaused>()),
        );
        final acquired = native.named('acquireContinuation').length;
        await expectLater(
          gate.acquire(kind),
          throwsA(isA<AiExecutionPaused>()),
        );
        expect(native.named('acquireContinuation'), hasLength(acquired));
        owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);
        expect(native.starts, 1);
        expect(gate.executionEligible, isFalse);
        expect(gate.binding.runId, 'run');
      },
    );
  }

  test(
    'Activity pause preserves a service permit; detach revokes it',
    () async {
      var visible = true;
      final (owner, _) = execution(visible: () => visible);
      final gate = owner.createGate(
        conversationId: () => 'conversation',
        isCurrent: () => true,
      );
      await gate.beginRun(runId: 'run');
      visible = false;
      owner.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(gate.executionEligible, isTrue);
      owner.didChangeAppLifecycleState(AppLifecycleState.detached);
      expect(gate.executionEligible, isFalse);
    },
  );

  test('Activity detach during start rejects a late active reply', () async {
    final (owner, native) = execution();
    native.startReply = Completer<void>();
    final gate = owner.createGate(
      conversationId: () => 'conversation',
      isCurrent: () => true,
    );
    final starting = gate.beginRun(runId: 'run');
    await fx.waitFor(() => native.named('startRuns').isNotEmpty);
    owner.didChangeAppLifecycleState(AppLifecycleState.detached);
    expect(gate.executionEligible, isFalse);
    native.startReply!.complete();
    final result = await starting;
    expect(result.disposition, AiBackgroundStartDisposition.invalidated);
    expect(gate.binding.permitId, isNull);
    await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
    expect(gate.requiresExplicitResume, isTrue);
    expect(native.starts, 1);
  });

  for (final unavailable in [false, true]) {
    test(
      'reattachment before ${unavailable ? 'unavailable' : 'already-stopped'} cleanup requires no second lifecycle event',
      () async {
        var visible = true;
        final (owner, native) = execution(visible: () => visible);
        final gate = owner.createGate(
          conversationId: () => 'conversation',
          isCurrent: () => true,
        );
        await gate.beginRun(runId: 'run');
        final ticket = await gate.acquire(AiContinuationKind.mutation);
        native.permit = null; // Native destruction, with its callback lost.
        native.releaseReply = Completer<void>();
        native.releaseUnavailable = unavailable;
        visible = false;
        owner.didChangeAppLifecycleState(AppLifecycleState.detached);
        await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
        visible = true;
        owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
        native.releaseReply!.complete();
        await fx.waitFor(() => native.named('stopAll').isNotEmpty);
        await fx.waitFor(
          () => owner.status == AiBackgroundExecutionStatus.invalidated,
        );
        expect(native.starts, 1);
        expect(gate.executionEligible, isFalse);
        expect(
          () => ticket.consumeOnce(
            binding: gate.binding,
            kind: AiContinuationKind.mutation,
          ),
          throwsA(isA<AiExecutionPaused>()),
        );
        final result = await gate.resumeRun();
        expect(result.disposition, AiBackgroundStartDisposition.active);
        expect(gate.binding.runId, 'run');
        expect(native.starts, 2);
      },
    );
  }

  for (final unavailable in [false, true]) {
    test(
      'pending start reattachment cleans a late ${unavailable ? 'unavailable' : 'already-stopped'} request release',
      () async {
        var visible = true;
        final (owner, native) = execution(visible: () => visible);
        native.startReply = Completer<void>();
        final gate = owner.createGate(
          conversationId: () => 'conversation',
          isCurrent: () => true,
        );
        final starting = gate.beginRun(runId: 'run');
        await fx.waitFor(() => native.named('startRuns').isNotEmpty);
        native.permit = null;
        native.releaseReply = Completer<void>();
        native.releaseUnavailable = unavailable;
        visible = false;
        owner.didChangeAppLifecycleState(AppLifecycleState.detached);
        await fx.waitFor(() => native.named('releaseRuns').isNotEmpty);
        visible = true;
        owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
        native.releaseReply!.complete();
        await fx.waitFor(() => native.named('stopAll').isNotEmpty);
        await fx.waitFor(
          () => owner.status == AiBackgroundExecutionStatus.invalidated,
        );
        native.startReply!.complete();
        expect(
          (await starting).disposition,
          AiBackgroundStartDisposition.invalidated,
        );
        expect(native.starts, 1);
        expect(gate.executionEligible, isFalse);
        expect(
          (await gate.resumeRun()).disposition,
          AiBackgroundStartDisposition.active,
        );
        expect(native.starts, 2);
      },
    );
  }

  for (final disposeRegistry in [false, true]) {
    test(
      'accepted write settles after ${disposeRegistry ? 'registry disposal' : 'Activity detach'} without replay',
      () async {
        final h = await fx.StackHarness.create(
          level: AiAutonomyLevel.conversationGrant,
        );
        addTearDown(h.dispose);
        final (owner, native) = execution(
          account: h.account,
          generation: h.session.generation,
          api: h.session.api,
          visible: () => h.foreground,
        );
        final runs = registry(h, owner);
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
            'fields': {'title': 'Synthetic recovery', 'confidential': false},
            'reason': 'The synthetic user requested an issue.',
          }),
        );
        final sending = h.controller.send('Create the synthetic issue');
        await fx.waitFor(() => h.server.mutations.isNotEmpty);
        final accepted = runs.inFlightWrites.single;
        final conversation = h.controller.id;
        final generation = runs.generation;
        if (disposeRegistry) {
          runs.dispose();
          expect(runs.sessionForConversation(conversation, generation), isNull);
          expect(runs.inFlightWrites, contains(same(accepted)));
        } else {
          owner.didChangeAppLifecycleState(AppLifecycleState.detached);
          expect(
            h.controller.executionPause?.reason,
            AiExecutionPauseReason.permitInactive,
          );
        }
        expect(h.session.api!.isClosed, isFalse);
        expect(
          h.journal.entries(h.account).single.state,
          AiJournalState.dispatching,
        );
        response.complete();
        final outcome = await accepted;
        await sending;
        expect(outcome.state, AiJournalState.succeeded);
        await fx.waitFor(() => runs.inFlightWrites.isEmpty);
        expect(
          h.journal.entries(h.account).single.state,
          AiJournalState.succeeded,
        );
        expect(h.server.mutations, hasLength(1));
        expect(h.provider.bodies, hasLength(1));
        expect(native.starts, 1);
      },
    );
  }

  for (final action in ['switch account', 'sign out']) {
    test(
      '$action waits for a stopped accepted write before the session changes',
      () async {
        final h = await fx.StackHarness.create(
          level: AiAutonomyLevel.conversationGrant,
        );
        addTearDown(h.dispose);
        final (owner, _) = execution(
          account: h.account,
          generation: h.session.generation,
          api: h.session.api,
        );
        final runs = registry(h, owner);
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
            'fields': {'title': 'Synthetic waiting', 'confidential': false},
            'reason': 'The synthetic user requested an issue.',
          }),
        );
        final sending = h.controller.send('Create the synthetic issue');
        await fx.waitFor(() => h.server.mutations.isNotEmpty);
        final generation = h.session.generation;
        var settled = false;
        final waiting =
            AiSwitchGuard.settle(
              choice: AiSwitchChoice.proceedAndWait,
              stopAndSnapshotWrites: runs.stopAndSnapshotWrites,
            ).then((allowed) async {
              expect(allowed, isTrue);
              settled = true;
              if (action == 'switch account') {
                await h.session.select(h.session.active!);
              } else {
                await h.session.endSession();
              }
            });
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
        expect(h.session.generation, generation);
        response.complete();
        await waiting;
        await sending;
        expect(
          h.journal.entries(h.account).single.state,
          AiJournalState.succeeded,
        );
        expect(runs.isDisposed, isTrue);
        expect(h.server.mutations, hasLength(1));
      },
    );
  }

  group('next-start recovery (synthetic disk, no old-process finally)', () {
    late Directory root;
    late _TombstoneReadKeys keys;
    late AiWriteJournal old;
    AiWriteJournal restart() => AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      processId: 'next-process',
    );

    setUp(() async {
      root = Directory.systemTemp.createTempSync('mr6c-c7-journal-');
      keys = _TombstoneReadKeys();
      old = AiWriteJournal(
        keys: keys,
        applicationSupport: root,
        processId: 'old-process',
      );
      await old.recoverAfterAccountsLoaded([_account]);
      await old.ensureInitialized(_account);
    });
    tearDown(() {
      root.deleteSync(recursive: true);
    });

    for (final termination in [
      'process death',
      'recents swipe',
      'Task Manager Stop',
    ]) {
      test(
        '$termination leaves dispatching uncertain and isolated on next start',
        () async {
          await old.prepare(draft: _draft('accepted'));
          await old.markDispatching(executionId: 'accepted');
          // No release, stop callback, finally, or completion of the old Future.
          final recovered = restart();
          expect(recovered.recoveryResult(_account).interruptedWrites, isNull);
          expect(
            recovered.recoveryResult(_account).mayNotifyInterruption,
            isFalse,
          );
          await recovered.recoverAfterAccountsLoaded([_account]);
          final summary = recovered.recoveryResult(_account);
          expect(summary.recovered, isTrue);
          expect(summary.keyStatus, AiJournalKeyStatus.found);
          expect(summary.interruptedWrites, 1);
          expect(summary.isolatedWrites, 1);
          expect(summary.mayNotifyInterruption, isTrue);
          expect(
            recovered.entries(_account).single.state,
            AiJournalState.writeUncertain,
          );
          expect(recovered.isolated(_account, {_target}), isTrue);
          final (owner, native) = execution();
          expect(owner.status, AiBackgroundExecutionStatus.foregroundOnly);
          expect(native.calls, isEmpty);
          expect(owner.serviceWorkCount, 0);
          expect(owner.backProtectedCount, 0);
          await expectLater(
            recovered.markDispatching(executionId: 'accepted'),
            throwsA(isA<AiJournalException>()),
          );
          await expectLater(
            recovered.prepare(draft: _draft('replacement')),
            throwsA(isA<AiJournalException>()),
          );
          expect(native.calls, isEmpty);
          await recovered.recoverAfterAccountsLoaded([_account]);
          expect(recovered.recoveryResult(_account).interruptedWrites, 1);
          expect(recovered.acknowledgeRecovery(_account, summary), isTrue);
          expect(recovered.acknowledgeRecovery(_account, summary), isFalse);
          expect(
            recovered.recoveryResult(_account).mayNotifyInterruption,
            isFalse,
          );
          expect(recovered.isolated(_account, {_target}), isTrue);
        },
      );
    }

    test(
      'recovery retires prepared work and preserves every terminal outcome',
      () async {
        await old.prepare(draft: _draft('prepared'));
        var sequence = 0;
        for (final terminal in [
          AiJournalState.succeeded,
          AiJournalState.failedCertain,
          AiJournalState.notExecuted,
          AiJournalState.writeUncertain,
        ]) {
          final id = 'terminal-${sequence++}';
          final target = AiConflictKey([_account, 'terminal', id]);
          await old.prepare(draft: _draft(id, target: target));
          if (terminal != AiJournalState.notExecuted) {
            await old.markDispatching(executionId: id);
          }
          await old.finish(executionId: id, terminal: terminal);
        }
        final recovered = restart();
        await recovered.recoverAfterAccountsLoaded([_account]);
        expect(
          recovered.entries(_account).first.state,
          AiJournalState.notExecuted,
        );
        expect(recovered.recoveryResult(_account).interruptedWrites, 1);
        expect(
          recovered.entries(_account).map((entry) => entry.state).skip(1),
          [
            AiJournalState.succeeded,
            AiJournalState.failedCertain,
            AiJournalState.notExecuted,
            AiJournalState.writeUncertain,
          ],
        );
        for (final entry in recovered.entries(_account)) {
          await expectLater(
            recovered.markDispatching(executionId: entry.executionId),
            throwsA(isA<AiJournalException>()),
          );
        }
      },
    );

    test(
      'successful typed reset clears pending interruption evidence',
      () async {
        await old.prepare(draft: _draft('accepted'));
        await old.markDispatching(executionId: 'accepted');
        final recovered = restart();
        await recovered.recoverAfterAccountsLoaded([_account]);
        final summary = recovered.recoveryResult(_account);
        expect(summary.mayNotifyInterruption, isTrue);
        final reset = await recovered.beginReset(
          _account,
          verifiedUsername: '@synthetic',
        );
        expect(recovered.recoveryResult(_account).interruptedWrites, isNull);
        await recovered.completeReset(reset, typedUsername: '@synthetic');
        expect(recovered.entries(_account), isEmpty);
        expect(recovered.recoveryResult(_account).interruptedWrites, 0);
        expect(
          recovered.recoveryResult(_account).mayNotifyInterruption,
          isFalse,
        );
        expect(recovered.acknowledgeRecovery(_account, summary), isFalse);
      },
    );

    test(
      'orphan removal and re-add discard old interruption evidence',
      () async {
        await old.prepare(draft: _draft('accepted'));
        await old.markDispatching(executionId: 'accepted');
        final recovered = restart();
        await recovered.recoverAfterAccountsLoaded([_account]);
        final summary = recovered.recoveryResult(_account);
        expect(summary.mayNotifyInterruption, isTrue);
        // Each list is an authoritative successful account-list load.
        await recovered.recoverAfterAccountsLoaded([]);
        await recovered.recoverAfterAccountsLoaded([_account]);
        final addedAgain = recovered.recoveryResult(_account);
        expect(addedAgain.recovered, isTrue);
        expect(addedAgain.keyStatus, AiJournalKeyStatus.uninitialized);
        expect(addedAgain.interruptedWrites, 0);
        expect(addedAgain.mayNotifyInterruption, isFalse);
        expect(recovered.acknowledgeRecovery(_account, summary), isFalse);
      },
    );

    test(
      'stale or foreign evidence cannot acknowledge a newer interruption',
      () async {
        await old.prepare(draft: _draft('first'));
        await old.markDispatching(executionId: 'first');
        final recovered = restart();
        await recovered.recoverAfterAccountsLoaded([_account]);
        final first = recovered.recoveryResult(_account);
        expect(recovered.acknowledgeRecovery('other-account', first), isFalse);
        await old.prepare(
          draft: _draft(
            'second',
            target: const AiConflictKey([_account, 'other']),
          ),
        );
        await old.markDispatching(executionId: 'second');
        await recovered.recoverAfterAccountsLoaded([_account]);
        expect(recovered.recoveryResult(_account).interruptedWrites, 2);
        expect(recovered.acknowledgeRecovery(_account, first), isFalse);
        expect(
          recovered.acknowledgeRecovery(
            _account,
            recovered.recoveryResult(_account),
          ),
          isTrue,
        );
      },
    );

    for (final failure in [
      'unavailable',
      'keyMissing',
      'unknownFormat',
      'tombstone',
      'tombstoneReadUnavailable',
    ]) {
      test(
        '$failure exposes unknown counts and retains journal bytes and keys',
        () async {
          await old.prepare(draft: _draft('accepted'));
          await old.markDispatching(executionId: 'accepted');
          final file = root
              .listSync(recursive: true)
              .whereType<File>()
              .singleWhere((f) => f.path.endsWith('journal.v1.enc'));
          final originalKey = keys.keys[_account]!.toList();
          if (failure == 'keyMissing') keys.keys.remove(_account);
          if (failure == 'unknownFormat') file.writeAsBytesSync([1, 2, 3]);
          if (failure == 'unavailable') keys.unavailable = true;
          if (failure == 'tombstone') keys.tombstones.add(_account);
          if (failure == 'tombstoneReadUnavailable') {
            keys.failTombstoneRead = true;
          }
          final before = file.readAsBytesSync();
          final recovered = restart();
          try {
            await recovered.recoverAfterAccountsLoaded([_account]);
          } on Object {
            expect(failure, 'unavailable');
          }
          final result = recovered.recoveryResult(_account);
          expect(result.recovered, isFalse);
          expect(result.interruptedWrites, isNull);
          expect(result.isolatedWrites, isNull);
          expect(result.mayNotifyInterruption, isFalse);
          expect(
            result.removalPending,
            failure == 'tombstoneReadUnavailable'
                ? isNull
                : failure == 'tombstone',
          );
          expect(file.readAsBytesSync(), before);
          expect(
            keys.keys[_account],
            failure == 'keyMissing' ? isNull : orderedEquals(originalKey),
          );
          expect(recovered.isolated(_account, {_target}), isTrue);
          await expectLater(
            recovered.prepare(draft: _draft('refused')),
            throwsA(isA<AiJournalException>()),
          );
          expect(file.readAsBytesSync(), before);
          if (failure == 'unavailable') {
            keys.unavailable = false;
            await recovered.recoverAfterAccountsLoaded([_account]);
            expect(
              recovered.recoveryResult(_account).mayNotifyInterruption,
              isTrue,
            );
            expect(keys.keys[_account], originalKey);
          }
        },
      );
    }

    for (final entryPoint in ['signed-in shell', 'account list']) {
      test(
        '$entryPoint removal holds dispatch and survives UI disposal after confirmation',
        () async {
          AiAccountRemoval.debugReset();
          addTearDown(AiAccountRemoval.debugReset);
          final h = await fx.StackHarness.create();
          addTearDown(h.dispose);
          final account = h.session.active!;
          final journal = h.journal;
          final job = AiAccountRemoval.begin(account.key, journal: journal)!;
          expect(AiAccountRemoval.begin(account.key, journal: journal), isNull);
          final epoch = journal.proposalEpoch(account.key);
          final entered = Completer<void>();
          final finish = Completer<void>();
          final prompts = <AiRemovalPromptKind>[];
          final removing = AiAccountRemoval.run(
            account: account,
            job: job,
            session: h.session,
            confirm: (prompt) async {
              prompts.add(prompt.kind);
              return true;
            },
            waitForInFlightWrites: () async {
              h.controller.stop();
            },
            requestCancelOnDispose: () {},
            runningOrPending: 1,
            journal: journal,
            consultJournal: true,
            clearDrafts: (_) async {},
            clearArtifacts: (_) async {},
            clearRecent: (_) async {},
            clearReadCacheDisk: (_) async {},
            clearAi: (_) async {
              entered.complete();
              await finish.future;
            },
          );
          await entered.future;
          expect(journal.removalHeld(account.key), isTrue);
          expect(journal.proposalEpoch(account.key), greaterThan(epoch));
          h.controller.dispose();
          job.requestCancel();
          final (owner, native) = execution(
            account: account.key,
            generation: h.session.generation,
            api: h.session.api,
          );
          await owner.stopAll();
          expect(journal.removalHeld(account.key), isTrue);
          finish.complete();
          final result = await removing;
          expect(result.status, AiRemovalStatus.removed);
          expect(prompts, [
            AiRemovalPromptKind.stopRuns,
            AiRemovalPromptKind.plainConfirm,
          ]);
          expect(native.named('stopAll'), hasLength(1));
          expect(journal.removalHeld(account.key), isFalse);
          expect(h.session.accounts, isEmpty);
        },
      );
    }
  });

  test(
    'startup reuses C3 cancellation once and keeps FGS and result IDs',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      final cancelled = <int>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_notificationChannel, (call) async {
        switch (call.method) {
          case 'initialize':
            return true;
          case 'getNotificationAppLaunchDetails':
            return {'notificationLaunchedApp': false};
          case 'cancel':
            cancelled.add(
              (call.arguments as Map<Object?, Object?>)['id']! as int,
            );
            return null;
          case 'getActiveNotifications':
            return <Object?>[];
        }
        fail('Unexpected notification method ${call.method}');
      });
      final notifications = AiRunNotifications(
        text: () => const AiRunNotificationText(
          approvalChannelName: 'Generic approval',
          resultChannelName: 'Generic result',
          title: 'Generic work',
          needsApproval: 'Generic approval',
          completed: 'Generic completion',
          failed: 'Generic failure',
          interrupted: 'Generic interruption',
        ),
      );
      addTearDown(() {
        notifications.dispose();
        messenger.setMockMethodCallHandler(_notificationChannel, null);
      });
      expect(await notifications.initialize(), isTrue);
      expect(await notifications.initialize(), isTrue);
      expect(cancelled, [for (var id = 6200; id <= 6299; id++) id]);
      expect(cancelled, isNot(contains(6100)));
      expect(cancelled, isNot(contains(6300)));
    },
  );
}
