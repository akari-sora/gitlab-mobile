import 'release_policy_support.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_secrets.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart' as fx;
import 'mr6b2_support.dart';
import 'mr6b3_support.dart';
import 'mr6c_support.dart';
import 'runner_test.dart' as runner_base;

const _conversation = 'mr6c-ticket-conversation';
const _newKey = r'new-provider-secret&value\after-acquire';
const _newAccess = r'new-oauth-access&value\after-acquire';
const _newRefresh = 'new-oauth-refresh-after-acquire';

AiExecutionRunBinding _binding(
  Object owner, {
  String run = 'run-1',
  String? permit = 'synthetic-permit',
}) => AiExecutionRunBinding(
  accountKey: mr6b2Account,
  generation: 7,
  ownerApi: owner,
  conversationId: _conversation,
  runId: run,
  permitId: permit,
);

void _consume(
  AiExecutionTicket ticket, {
  AiExecutionRunBinding? binding,
  AiContinuationKind? kind,
}) => ticket.consumeOnce(
  binding: binding ?? ticket.binding,
  kind: kind ?? ticket.kind,
);

void _spent(AiExecutionTicket ticket) =>
    expect(() => _consume(ticket), throwsA(isA<AiExecutionPaused>()));

void main() {
  group('pure Dart ticket', () {
    test('pause metadata is optional and does not expand AiRunEnd', () {
      const old = AiRunResult(
        reason: AiRunEnd.done,
        text: '',
        modelCalls: 0,
        toolCalls: 0,
      );
      const paused = AiRunResult(
        reason: AiRunEnd.stopped,
        text: '',
        modelCalls: 0,
        toolCalls: 0,
        pause: AiExecutionPause(AiExecutionPauseReason.timeout),
      );
      expect(old.pause, isNull);
      expect(paused.pause!.reason, AiExecutionPauseReason.timeout);
      expect(AiRunEnd.values, hasLength(12));
    });

    test('one-shot, run and kind mismatch burn a ticket permanently', () async {
      final gate = Mr6cExecutionGate(
        binding: _binding(Object()),
        clock: Mr6cClock(),
      );
      final once = await gate.acquire(AiContinuationKind.model);
      _consume(once);
      _spent(once);
      final wrongKind = await gate.acquire(AiContinuationKind.model);
      expect(
        () => _consume(wrongKind, kind: AiContinuationKind.mutation),
        throwsA(isA<AiExecutionPaused>()),
      );
      _spent(wrongKind);
      final wrongRun = await gate.acquire(AiContinuationKind.mutation);
      expect(
        () => _consume(
          wrongRun,
          binding: _binding(gate.binding.ownerApi, run: 'different-run'),
        ),
        throwsA(isA<AiExecutionPaused>()),
      );
      _spent(wrongRun);
      expect(gate.tickets.map((t) => t.nonce).toSet(), hasLength(3));
    });

    test(
      'TTL includes acquire wait, expires exactly at 1000ms, never extends',
      () async {
        final clock = Mr6cClock();
        final gate = Mr6cExecutionGate(
          binding: _binding(Object()),
          clock: clock,
        );
        gate.onAcquire = (_) async =>
            clock.advance(const Duration(milliseconds: 999));
        final valid = await gate.acquire(AiContinuationKind.model);
        _consume(valid);
        gate.onAcquire = (_) async => clock.advance(const Duration(seconds: 1));
        final expired = await gate.acquire(AiContinuationKind.mutation);
        expect(
          () => _consume(expired),
          throwsA(
            isA<AiExecutionPaused>().having(
              (e) => e.pause.reason,
              'reason',
              AiExecutionPauseReason.ticketExpired,
            ),
          ),
        );
        _spent(expired);
      },
    );

    test(
      'foreground fallback checks visibility at acquire and consume',
      () async {
        var visible = true;
        final gate = ForegroundAiExecutionGate(appInForeground: () => visible);
        final ticket = await gate.acquire(AiContinuationKind.model);
        visible = false;
        _spent(ticket);
        await expectLater(
          gate.acquire(AiContinuationKind.mutation),
          throwsA(isA<AiExecutionPaused>()),
        );
        visible = true;
        _consume(await gate.acquire(AiContinuationKind.model));
      },
    );

    test('local foreground ticket remains valid after 1000ms', () async {
      final clock = Mr6cClock();
      final gate = ForegroundAiExecutionGate(
        appInForeground: () => true,
        clock: clock.now,
      );
      final ticket = await gate.acquire(AiContinuationKind.mutation);
      clock.advance(const Duration(milliseconds: 1001));
      _consume(ticket);
      _spent(ticket);
    });

    test('foreground consume reports foregroundRequired', () async {
      var visible = true;
      final gate = ForegroundAiExecutionGate(appInForeground: () => visible);
      final ticket = await gate.acquire(AiContinuationKind.model);
      visible = false;
      expect(
        () => _consume(ticket),
        throwsA(
          isA<AiExecutionPaused>().having(
            (e) => e.pause.reason,
            'reason',
            AiExecutionPauseReason.foregroundRequired,
          ),
        ),
      );
      _spent(ticket);
    });
  });

  group('model boundary', () {
    test(
      'refused projection retains the previous conversation for retry',
      () async {
        final h = await _ModelHarness.create();
        addTearDown(h.dispose);
        expect(
          (await h.runner.run('remember prior-user-message')).modelCalls,
          1,
        );
        final previous = h.runner.segment!;
        final frozen = [...previous.frozenWireJson];
        h.runner.forceProjection();
        h.gate.refuse = AiExecutionPauseReason.permitInactive;
        final refused = await h.runner.run('unsent projection');
        expect(refused.modelCalls, 0);
        expect(h.runner.segment, same(previous));
        expect(previous.frozenWireJson, frozen);
        h.gate.refuse = null;
        expect((await h.runner.run('retry projection')).modelCalls, 1);
        expect(h.base.payloads.last, contains('prior-user-message'));
      },
    );

    test('no gate or visibility injection fails closed', () async {
      final h = runner_base.Harness(appInForeground: null);
      final result = await h.runner.run('visibility is unknown');
      expect(result.reason, AiRunEnd.stopped);
      expect(result.pause!.reason, AiExecutionPauseReason.foregroundRequired);
      expect(result.modelCalls, 0);
      expect(h.payloads, isEmpty);
      expect(h.runner.segment!.frozenLength, 0);
    });
    for (final oauth in [false, true]) {
      test(
        '${oauth ? 'same API OAuth rotation' : 'other provider key'} inside acquire redacts user tail',
        () async {
          final h = await _ModelHarness.create();
          addTearDown(h.dispose);
          final barrier = Mr6cBarrier();
          h.gate.onAcquire = (_) => barrier.wait();
          final pending = h.runner.run('user ${oauth ? _newAccess : _newKey}');
          await barrier.entered;
          expect(h.base.payloads, isEmpty);
          await h.inject(oauth);
          barrier.release();
          final result = await pending;
          expect(result.reason, AiRunEnd.done);
          expect(result.pause, isNull);
          expect(result.modelCalls, 1);
          expect(
            h.base.payloads.single,
            isNot(contains(oauth ? _newAccess : _newKey)),
          );
          expect(h.secrets.current, contains(oauth ? _newAccess : _newKey));
          h.expectNoKnownSecret(oauth);
          expect(
            h.gate.events,
            containsAllInOrder([
              'acquire:model',
              'last-refresh',
              'redact/verify',
              'consume:model',
              'send',
            ]),
          );
        },
      );

      test(
        'new ${oauth ? 'OAuth credential' : 'provider key'} in frozen prefix refuses without rewriting replay',
        () async {
          final h = await _ModelHarness.create();
          addTearDown(h.dispose);
          h.base.respond = (_, _) async =>
              h.base.turn(text: oauth ? _newAccess : _newKey);
          expect((await h.runner.run('first')).reason, AiRunEnd.done);
          final old = h.runner.segment!;
          final frozen = [...old.frozenWireJson];
          final barrier = Mr6cBarrier();
          h.gate.onAcquire = (_) => barrier.wait();
          final pending = h.runner.run('follow up');
          await barrier.entered;
          await h.inject(oauth);
          barrier.release();
          final result = await pending;
          expect(result.reason, AiRunEnd.newSecret);
          expect(result.modelCalls, 0);
          expect(h.base.payloads, hasLength(1));
          expect(old.frozenWireJson, frozen);
          _spent(h.gate.tickets.last);
          h.gate.onAcquire = null;
          h.base.respond = (_, _) async => h.base.turn(text: 'safe');
          expect((await h.runner.run('retry')).reason, AiRunEnd.done);
          expect(h.runner.segment, isNot(same(old)));
          expect(
            h.base.payloads.last,
            isNot(contains(oauth ? _newAccess : _newKey)),
          );
          h.expectNoKnownSecret(oauth);
        },
      );

      test(
        'expired tool reread finishes 2s before acquire, then ${oauth ? 'OAuth' : 'provider'} injection is redacted',
        () async {
          final h = await _ModelHarness.create();
          addTearDown(h.dispose);
          final read = _RereadPort(h);
          final catalogue = AiToolCatalogue(
            releasePolicy: fixtureReleasePolicy,
            port: read,
            scope: const AiResourceScope(
              accountKey: mr6b2Account,
              instanceKey: 'https://example.com/gitlab',
              projectId: 9,
              projectPath: 'team/example-9',
              current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
              headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            ),
            redactor: Redactor(secrets: h.secrets),
            refreshSecrets: h.refresh,
            now: h.now,
          );
          final budget = AiToolBudget();
          final call = AiToolCall(
            id: 'expired-read',
            name: 'get_issue',
            arguments: const {'iid': 3},
          );
          h.currentSpecs = catalogue.specs;
          h.base.respond = (_, _) async => h.base.payloads.length == 1
              ? h.base.turn(calls: [call])
              : h.base.turn(text: 'done');
          h.execute = (call) async {
            final result = await catalogue.executeResult(call, budget: budget);
            // Models the waiting-for-approval wall time without a real timer.
            h.clock.advance(const Duration(seconds: 61));
            return result;
          };
          h.prepare = (calls, results, beforeDelivery) async {
            final delivery = await catalogue.prepareDelivery(
              calls,
              results,
              budget: budget,
              beforeDelivery: beforeDelivery,
            );
            h.gate.events.add('delivery-ready');
            return (
              results: delivery.results,
              delivered: (List<AiToolResult> results) {
                h.deliveries++;
                delivery.delivered(results);
              },
            );
          };
          final barrier = Mr6cBarrier();
          h.gate.onAcquire = (_) async {
            if (h.gate.acquisitions.length == 2) await barrier.wait();
          };
          final pending = h.runner.run('read file');
          await barrier.entered;
          expect(read.calls, 2);
          expect(h.clock.elapsed, const Duration(seconds: 63));
          expect(h.gate.tickets.last.requestStartedAt, h.clock.elapsed);
          expect(h.deliveries, 0);
          await h.inject(oauth);
          final before = h.gate.events.length;
          barrier.release();
          final result = await pending;
          expect(result.reason, AiRunEnd.done);
          expect(result.modelCalls, 2);
          expect(read.calls, 2, reason: 'no reread after acquire');
          expect(h.deliveries, 1);
          final payload = h.base.payloads.last;
          expect(payload, contains('reread-body'));
          expect(payload, isNot(contains(_newKey)));
          expect(payload, isNot(contains(_newAccess)));
          h.expectNoKnownSecret(oauth);
          expect(
            h.gate.events,
            containsAllInOrder([
              'reread-finished',
              'delivery-ready',
              'acquire:model',
              'last-refresh',
              'redact/verify',
              'consume:model',
              'send',
            ]),
          );
          expect(
            h.gate.events.skip(before).where((e) => e == 'last-refresh'),
            hasLength(1),
          );
        },
      );
    }

    for (final failure in ['refused', 'channel timeout', 'last refresh TTL']) {
      test(
        '$failure sends zero, does not charge or freeze, retry projects',
        () async {
          final h = await _ModelHarness.create();
          addTearDown(h.dispose);
          final barrier = Mr6cBarrier();
          if (failure == 'refused') {
            h.gate.refuse = AiExecutionPauseReason.permitInactive;
          } else if (failure == 'channel timeout') {
            h.gate.onAcquire = (_) => barrier.wait();
          } else {
            h.lastRefreshDelay = const Duration(seconds: 1);
          }
          final result = await h.runner.run('unsent user tail');
          expect(result.reason, AiRunEnd.stopped);
          expect(result.pause, isNotNull);
          expect(result.modelCalls, 0);
          expect(h.runner.actualInputTokens + h.runner.estimatedInputTokens, 0);
          expect(h.base.payloads, isEmpty);
          expect(h.deliveries, 0);
          expect(h.runner.segment!.frozenLength, 0);
          expect(h.runner.segment!.tail, isNull);
          final old = h.runner.segment;
          barrier.release();
          await Future<void>.delayed(Duration.zero);
          for (final ticket in h.gate.tickets) {
            _spent(ticket);
          }
          h.gate.refuse = null;
          h.gate.onAcquire = null;
          h.lastRefreshDelay = Duration.zero;
          expect(
            (await h.runner.run('retry unsent tail')).reason,
            AiRunEnd.done,
          );
          expect(h.runner.segment, isNot(same(old)));
          expect(h.base.payloads.single, contains('retry unsent tail'));
        },
      );
    }

    test(
      'expired prepared tool delivery is never delivered or frozen',
      () async {
        final h = await _ModelHarness.create();
        addTearDown(h.dispose);
        h.base.respond = (_, _) async =>
            h.base.turn(calls: [runner_base.call()]);
        h.prepare = (_, results, before) async {
          await before();
          h.lastRefreshDelay = const Duration(seconds: 1);
          return (results: results, delivered: (_) => h.deliveries++);
        };
        final result = await h.runner.run('read');
        expect(result.modelCalls, 1);
        expect(result.pause!.reason, AiExecutionPauseReason.ticketExpired);
        expect(h.base.payloads, hasLength(1));
        expect(h.deliveries, 0);
        expect(h.runner.segment!.frozenLength, 2);
        expect(h.runner.segment!.tail, isA<AppToolResultsEntry>());
      },
    );

    test('last refresh through send has no asynchronous gap', () async {
      final h = await _ModelHarness.create();
      addTearDown(h.dispose);
      var armed = false;
      h.observed.onRead = () {
        if (h.finalSnapshot && !armed) {
          armed = true;
          scheduleMicrotask(() => h.gate.invalidated = true);
        }
      };
      final result = await h.runner.run('send synchronously');
      expect(armed, isTrue);
      expect(result.modelCalls, 1);
      expect(result.reason, AiRunEnd.done);
      expect(h.base.payloads, hasLength(1));
    });

    test('last refresh completion sends before a queued lifecycle event', () async {
      final h = await _ModelHarness.create();
      addTearDown(h.dispose);
      var armed = false;
      var invalidated = false;
      h.onGuard = () {
        if (h.finalSnapshot && !armed) {
          armed = true;
          // Queue the event before the final refresh returns. Its required
          // Future continuations finish first; another event-loop await loses.
          Timer.run(() {
            invalidated = true;
            h.gate.invalidated = true;
          });
        }
      };
      final result = await h.runner.run('send before lifecycle event');
      expect(armed, isTrue);
      expect(result.modelCalls, 1);
      expect(result.reason, AiRunEnd.done);
      expect(h.base.payloads, hasLength(1));
      await Future<void>.delayed(Duration.zero);
      expect(invalidated, isTrue);
    });

    test(
      'real background permits one model; native revocation with lost callback blocks the next',
      () async {
        final h = await _ModelHarness.create();
        addTearDown(h.dispose);
        expect(h.gate.foreground, isFalse);
        expect((await h.runner.run('one')).modelCalls, 1);
        h.gate.nativeActive = false;
        final next = await h.runner.run('two');
        expect(next.pause!.reason, AiExecutionPauseReason.permitInactive);
        expect(next.modelCalls, 0);
        expect(h.base.payloads, hasLength(1));
      },
    );

    test(
      'queued valid reply may send once before an undelivered invalidation',
      () async {
        final h = await _ModelHarness.create();
        addTearDown(h.dispose);
        h.gate.onAcquire = (_) async => h.gate.nativeActive = false;
        expect((await h.runner.run('issued before revoke')).modelCalls, 1);
        expect((await h.runner.run('no fresh tickets')).modelCalls, 0);
        expect(h.base.payloads, hasLength(1));
      },
    );

    for (final invalidation in [
      'observed revoke',
      'stop',
      'generation',
      'consent',
      'owner',
    ]) {
      test('$invalidation during acquire prevents model send', () async {
        final h = await _ModelHarness.create();
        addTearDown(h.dispose);
        final barrier = Mr6cBarrier();
        h.gate.onAcquire = (_) => barrier.wait();
        final pending = h.runner.run('guard me');
        await barrier.entered;
        switch (invalidation) {
          case 'observed revoke':
            h.gate.invalidated = true;
          case 'stop':
            h.runner.stop();
          case 'generation':
            h.generation++;
          case 'consent':
            h.consent = false;
          case 'owner':
            h.currentOwner = Object();
        }
        barrier.release();
        final result = await pending;
        expect(result.modelCalls, 0);
        expect(h.base.payloads, isEmpty);
        await Future<void>.delayed(Duration.zero);
        _spent(h.gate.tickets.single);
      });
    }

    test(
      'default gate with actual background visibility refuses the model',
      () async {
        final h = runner_base.Harness();
        final runner = AiRunner(
          config: h.config(),
          wire: h.wire,
          complete: h.complete,
          secrets: h.secrets,
          refreshSecrets: () async {},
          guard: h.runner.guard,
          system: 'system',
          close: () {},
          cancelActive: () {},
          appInForeground: () => false,
        );
        final result = await runner.run('background without a permit');
        expect(result.reason, AiRunEnd.stopped);
        expect(result.pause!.reason, AiExecutionPauseReason.foregroundRequired);
        expect(result.modelCalls, 0);
        expect(h.payloads, isEmpty);
      },
    );

    test('background without a permit starts no new tool read', () async {
      final h = await _ModelHarness.create();
      addTearDown(h.dispose);
      h.gate.binding = _binding(h.api, permit: null);
      h.gate.foreground = true;
      var reads = 0;
      h.execute = (call) async {
        reads++;
        return AiToolResult(callId: call.id, name: call.name, content: 'read');
      };
      h.base.respond = (_, _) async {
        h.gate.foreground = false;
        return h.base.turn(calls: [runner_base.call()]);
      };
      final result = await h.runner.run('read once visible');
      expect(result.reason, AiRunEnd.stopped);
      expect(result.pause?.reason, AiExecutionPauseReason.foregroundRequired);
      expect(result.modelCalls, 1);
      expect(reads, 0);
      expect(result.toolCalls, 0);
    });
  });

  test('last refresh rechecks execution run drift before consume', () async {
    final h = await _WriteHarness.create(graph: false, begin: false);
    addTearDown(h.dispose);
    final b = runner_base.Harness();
    var drifted = false;
    final runner = _runnerWithWrites(
      h,
      b,
      refreshSecrets: () async {
        if (h.gate.acquisitions.isNotEmpty && !drifted) {
          drifted = true;
          h.revision++;
        }
      },
    );
    final result = await runner.run('policy changes in final refresh');
    expect(drifted, isTrue);
    expect(result.reason, AiRunEnd.stopped);
    expect(result.pause?.reason, AiExecutionPauseReason.runChanged);
    expect(result.modelCalls, 0);
    expect(b.payloads, isEmpty);
    expect(h.gate.events, isNot(contains('consume:model')));
  });

  for (final invalidRun in ['', 'reused']) {
    test(
      'coordinator rejects $invalidRun run before a model acquire',
      () async {
        final h = await _WriteHarness.create(graph: false, begin: false);
        addTearDown(h.dispose);
        final b = runner_base.Harness();
        final runner = _runnerWithWrites(h, b);
        if (invalidRun.isNotEmpty) {
          expect((await runner.run('first')).modelCalls, 1);
        } else {
          h.gate.binding = _binding(h.server.api, run: '');
        }
        final acquired = h.gate.acquisitions.length;
        final sent = b.payloads.length;
        final result = await runner.run('rejected binding');
        expect(result.reason, AiRunEnd.stopped);
        expect(result.pause!.reason, AiExecutionPauseReason.runChanged);
        expect(result.modelCalls, 0);
        expect(h.gate.acquisitions, hasLength(acquired));
        expect(b.payloads, hasLength(sent));
        h.gate.binding = _binding(h.server.api, run: 'fresh-run');
        expect((await runner.run('fresh binding')).reason, AiRunEnd.done);
      },
    );
  }

  test('runner rejects a different gate from its write coordinator', () async {
    final h = await _WriteHarness.create(graph: false, begin: false);
    addTearDown(h.dispose);
    final b = runner_base.Harness();
    final other = Mr6cExecutionGate(
      binding: _binding(h.server.api),
      clock: h.clock,
    );
    expect(
      () => AiRunner(
        config: b.config(),
        wire: b.wire,
        complete: b.complete,
        secrets: b.secrets,
        refreshSecrets: () async {},
        guard: b.runner.guard,
        system: 'system',
        close: () {},
        cancelActive: () {},
        writeCoordinator: h.coordinator,
        executionGate: other,
      ),
      throwsArgumentError,
    );
  });

  test('controller model uses real visibility without consulting the client', () async {
    final h = await fx.StackHarness.create(origin: const AiGeneralOrigin());
    addTearDown(h.dispose);
    var visible = true;
    var clientChecks = 0;
    final controller = AiChatController(
      releasePolicy: fixtureReleasePolicy,
      origin: const AiGeneralOrigin(),
      session: h.session,
      settings: h.settings,
      runningCount: () => 0,
      appInForeground: () => visible,
      clientMayStart: () {
        clientChecks++;
        throw StateError('model consulted the write-only client predicate');
      },
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
    );
    addTearDown(controller.dispose);
    await controller.recheck();
    await controller.send('answer without tools');
    expect(clientChecks, 0);
    expect(h.provider.bodies, hasLength(1));
    expect(controller.phase, AiChatPhase.idle);
    expect(controller.items.whereType<AiAssistantItem>().single.text, 'Done');
    visible = false;
    await controller.send('background without a permit');
    expect(h.provider.bodies, hasLength(1));
    expect(clientChecks, 0);
    expect(controller.writeGatesOpen, isFalse);
  });

  for (final permit in [false, true]) {
    test('model never invokes the client predicate (permit=$permit)', () async {
      final h = await _WriteHarness.create(graph: false, begin: false);
      addTearDown(h.dispose);
      if (!permit) {
        h.gate.binding = _binding(h.server.api, permit: null);
        h.gate.foreground = true;
      }
      h.clientMayStartPredicate = () =>
          throw StateError('model consulted the write-only client predicate');
      final b = runner_base.Harness();
      final result = await _runnerWithWrites(h, b).run('answer without tools');
      expect(result.reason, AiRunEnd.done);
      expect(result.modelCalls, 1);
      expect(h.clientChecks, 0);
      expect(h.portCreations, 0);
      expect(h.sends, 0);
      h.clientMayStartPredicate = () => false;
      final write = await h.coordinator.execute(h.call());
      expect(write.state, AiJournalState.notExecuted);
      expect(write.reasonCode, AiWritePause.clientUnavailable);
      expect(h.clientChecks, greaterThan(0));
      expect(h.portCreations, 0);
      expect(h.sends, 0);
    });

    for (final reason in ['policy', 'removal', 'eligibility']) {
      test(
        '$reason during model acquire preserves the coordinator guards (permit=$permit)',
        () async {
          final h = await _WriteHarness.create(graph: false, begin: false);
          addTearDown(h.dispose);
          if (!permit) {
            h.gate.binding = _binding(h.server.api, permit: null);
            h.gate.foreground = true;
          }
          final b = runner_base.Harness();
          final barrier = Mr6cBarrier();
          h.gate.onAcquire = (_) => barrier.wait();
          final pending = _runnerWithWrites(h, b).run('guard the model');
          await barrier.entered;
          switch (reason) {
            case 'policy':
              h.revision++;
            case 'removal':
              h.storage.journal.beginRemoval(mr6b2Account).cancelFinal();
            case 'eligibility':
              h.executionEligible = false;
          }
          barrier.release();
          final result = await pending;
          expect(result.reason, AiRunEnd.stopped);
          expect(result.modelCalls, 0);
          expect(b.payloads, isEmpty);
          expect(h.sends, 0);
          _spent(h.gate.tickets.single);
        },
      );
    }

    test(
      '429 during model acquire blocks only the write and continues with its tool result (permit=$permit)',
      () async {
        final h = await _WriteHarness.create(graph: false, begin: false);
        addTearDown(h.dispose);
        if (!permit) {
          h.gate.binding = _binding(h.server.api, permit: null);
          h.gate.foreground = true;
        }
        final b = runner_base.Harness();
        final call = h.call();
        b.respond = (_, _) async => b.payloads.length == 1
            ? b.turn(calls: [call])
            : b.turn(text: 'write was not executed');
        final barrier = Mr6cBarrier();
        h.gate.onAcquire = (_) => barrier.wait();
        final pending = _runnerWithWrites(h, b).run('Star project');
        await barrier.entered;
        h.server.overrides['GET projects/9'] = (_) => jsonResponse(
          {'message': 'synthetic 429'},
          status: 429,
          headers: {
            'retry-after': ['60'],
          },
        );
        try {
          await h.server.api.project('9', refresh: true);
        } on Object {
          // Retain the real production client's synchronous Retry-After gate.
        }
        expect(h.server.api.mayStartRequest, isFalse);
        barrier.release();
        final result = await pending;
        expect(result.reason, AiRunEnd.done);
        expect(result.pause, isNull);
        expect(result.modelCalls, 2);
        expect(result.toolCalls, 1);
        expect(b.payloads, hasLength(2));
        expect(b.payloads.last, contains('clientUnavailable'));
        expect(h.coordinator.outcomeFor(call.id)!.state, AiJournalState.notExecuted);
        expect(h.portCreations, 0);
        expect(h.sends, 0);
        expect(h.storage.journal.entries(mr6b2Account), isEmpty);
        expect(h.gate.acquisitions, [
          AiContinuationKind.model,
          AiContinuationKind.model,
        ]);
        for (final ticket in h.gate.tickets) {
          _spent(ticket);
        }
      },
    );
  }

  for (final graph in [false, true]) {
    test(
      'refused ${graph ? 'Graph' : 'REST'} ticket pauses the runner before another model',
      () async {
        final h = await _WriteHarness.create(graph: graph, begin: false);
        addTearDown(h.dispose);
        h.foreground = false;
        final b = runner_base.Harness();
        final call = h.call();
        b.respond = (_, _) async => b.payloads.length == 1
            ? b.turn(calls: [call])
            : b.turn(text: 'must not send');
        h.gate.onAcquire = (kind) async {
          if (kind == AiContinuationKind.mutation) {
            throw const AiExecutionPaused(
              AiExecutionPause(
                AiExecutionPauseReason.unavailable,
                kind: AiContinuationKind.mutation,
              ),
            );
          }
        };
        final result = await _runnerWithWrites(
          h,
          b,
        ).run('Star project and close #3 in team/example-9.');
        expect(result.reason, AiRunEnd.stopped);
        expect(result.pause?.reason, AiExecutionPauseReason.unavailable);
        expect(result.pause?.kind, AiContinuationKind.mutation);
        expect(result.modelCalls, 1);
        expect(b.payloads, hasLength(1));
        expect(h.sends, 0);
        final recorded = h.coordinator.recordedOutcomeFor(call.id)!;
        h.expectNotExecuted(recorded);
      },
    );
  }

  for (final graph in [false, true]) {
    group(graph ? 'Graph ticket boundary' : 'REST ticket boundary', () {
      late _WriteHarness h;
      setUp(() async => h = await _WriteHarness.create(graph: graph));
      tearDown(() => h.dispose());

      test('foreground fallback supports direct use before beginRun', () async {
        final direct = h.makeCoordinator(inject: false);
        addTearDown(() => direct.stop('done'));
        final proposal = (await direct.propose(h.call()))!;
        final outcome = await direct.approve(
          proposal,
          typedName: proposal.tier.typedName,
        );
        expect(outcome.state, AiJournalState.succeeded);
        expect(h.sends, 1);
      });

      test('local foreground slow dispatch flush still sends', () async {
        final direct = h.makeCoordinator(inject: false);
        addTearDown(() => direct.stop('done'));
        h.level = AiAutonomyLevel.confirmEach;
        final proposal = (await direct.propose(h.call()))!;
        final entered = h.storage.files.armBarrier(
          writesBeforeBarrier: 1,
          afterPersist: true,
        );
        final pending = direct.approve(proposal);
        await entered;
        expect(h.sends, 0);
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        h.storage.files.releaseBarrier();
        final outcome = await pending;
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.mutationCount, 1);
        expect(h.sends, 1);
      });

      test('no gate or snapshot visibility fails closed', () async {
        final direct = h.makeCoordinator(
          inject: false,
          policySnapshot: () => const AiWritePolicySnapshot(
            scope: mr6b2Scope,
            level: AiAutonomyLevel.bypass,
            ceiling: AiAutonomyLevel.bypass,
            consentHash: 'mr6c-consent',
            writePolicyRevision: 1,
          ),
        );
        addTearDown(() => direct.stop('done'));
        expect(direct.snapshot().appInForeground, isFalse);
        expect(direct.snapshot().executionEligible, isFalse);
        expect(direct.executionGate.executionEligible, isFalse);
        final result = await direct.execute(h.call());
        expect(result.state, AiJournalState.notExecuted);
        expect(result.reasonCode, AiWritePause.backgrounded);
        expect(h.portCreations, 0);
        expect(h.sends, 0);
      });

      test(
        'issued ticket permits one mutation with a lost invalidation callback',
        () async {
          h.foreground = false;
          h.gate.onAcquire = (_) async => h.gate.nativeActive = false;
          expect((await h.coordinator.execute(h.call())).mutationCount, 1);
          h.gate.binding = _binding(h.server.api, run: 'after-issued-ticket');
          h.coordinator.beginRun(
            'Star project and close #3 in team/example-9.',
          );
          h.coordinator.beginTurn();
          expect(
            (await h.coordinator.execute(h.call(second: true))).mutationCount,
            0,
          );
          expect(h.sends, 1);
        },
      );

      test(
        'automatic background write progresses once; revocation blocks the next',
        () async {
          h.foreground = false;
          final result = await h.coordinator.execute(h.call());
          expect(h.coordinator.snapshot().appInForeground, isFalse);
          expect(result.state, AiJournalState.succeeded);
          expect(result.mutationCount, 1);
          expect(h.sends, 1);
          expect(h.gate.acquisitions, [AiContinuationKind.mutation]);
          h.gate.binding = _binding(h.server.api, run: 'run-2');
          h.coordinator.beginRun(
            'Unstar project and reopen #3 in team/example-9.',
          );
          h.coordinator.beginTurn();
          h.gate.nativeActive = false;
          final next = await h.coordinator.execute(h.call(second: true));
          expect(next.state, AiJournalState.notExecuted);
          expect(next.mutationCount, 0);
          expect(h.sends, 1);
        },
      );

      test(
        'approve in background keeps the proposal, including an edit attempt',
        () async {
          h.level = AiAutonomyLevel.confirmEach;
          final proposal = (await h.coordinator.propose(h.call()))!;
          final digest = proposal.payloadDigest;
          h.foreground = false;
          h.coordinator.checkNow();
          expect(proposal.pausedReason, AiWritePause.backgrounded);
          final refused = await h.coordinator.approve(
            proposal,
            editedText: 'must stay unaccepted',
          );
          expect(refused.state, AiJournalState.notExecuted);
          expect(refused.reasonCode, AiWritePause.backgrounded);
          expect(proposal.valid, isTrue);
          expect(proposal.editedText, isNull);
          expect(proposal.payloadDigest, digest);
          expect(h.coordinator.proposals, contains(proposal));
          expect(h.gate.acquisitions, isEmpty);
          expect(h.sends, 0);
          h.foreground = true;
          expect(
            (await h.coordinator.approve(proposal)).state,
            AiJournalState.succeeded,
          );
        },
      );

      test(
        'approval backgrounded during acquire never flushes dispatch',
        () async {
          h.level = AiAutonomyLevel.confirmEach;
          final proposal = (await h.coordinator.propose(h.call()))!;
          final acquire = Mr6cBarrier();
          h.gate.onAcquire = (_) => acquire.wait();
          var dispatchFlushed = false;
          unawaited(
            h.storage.files
                .armBarrier(writesBeforeBarrier: 1, afterPersist: true)
                .then((_) async {
                  final durable = await h.storage.readDurableJournal();
                  dispatchFlushed =
                      ((durable['entries']! as List).last as Map)['state'] ==
                      'dispatching';
                  h.storage.files.releaseBarrier();
                }),
          );
          final pending = h.coordinator.approve(proposal);
          await acquire.entered;
          h.foreground = false;
          acquire.release();
          final outcome = await pending;
          h.expectNotExecuted(outcome);
          expect(dispatchFlushed, isFalse);
        },
      );

      test(
        'approval backgrounded during flush rolls back without sending',
        () async {
          h.level = AiAutonomyLevel.confirmEach;
          final proposal = (await h.coordinator.propose(h.call()))!;
          final entered = h.storage.files.armBarrier(
            writesBeforeBarrier: 1,
            afterPersist: true,
          );
          final pending = h.coordinator.approve(proposal);
          await entered;
          expect(h.gate.acquisitions, [AiContinuationKind.mutation]);
          expect(h.sends, 0);
          h.foreground = false;
          h.storage.files.releaseBarrier();
          final outcome = await pending;
          h.expectNotExecuted(outcome);
          final durable = await h.storage.readDurableJournal();
          expect(
            ((durable['entries']! as List).last as Map)['state'],
            'notExecuted',
          );
        },
      );

      test(
        'refused acquire is durably notExecuted and refunded before dispatching',
        () async {
          h.gate.refuse = AiExecutionPauseReason.permitInactive;
          final result = await h.coordinator.execute(h.call());
          h.expectNotExecuted(result);
          final durable = await h.storage.readDurableJournal();
          expect(
            ((durable['entries']! as List).last as Map)['state'],
            'notExecuted',
          );
        },
      );

      test(
        'acquire timeout discards a late reply without resurrecting a mutation',
        () async {
          final barrier = Mr6cBarrier();
          h.gate.onAcquire = (_) => barrier.wait();
          final result = await h.coordinator.execute(h.call());
          expect(result.reasonCode, 'timeout');
          h.expectNotExecuted(result);
          barrier.release();
          await Future<void>.delayed(Duration.zero);
          _spent(h.gate.tickets.single);
          expect(h.sends, 0);
        },
      );

      test(
        'slow flush exhausts TTL, rolls back atomically, restores confirmation mark',
        () async {
          await h.seedConfirmMark();
          h.level = AiAutonomyLevel.confirmEach;
          final proposal = (await h.coordinator.propose(h.call()))!;
          final entered = h.storage.files.armBarrier(
            writesBeforeBarrier: 1,
            afterPersist: true,
          );
          final pending = h.coordinator.approve(proposal);
          await entered;
          expect(h.gate.acquisitions, [AiContinuationKind.mutation]);
          expect(h.sends, 0);
          final durable = await h.storage.readDurableJournal();
          expect(
            ((durable['entries']! as List).last as Map)['state'],
            'dispatching',
          );
          expect(
            ((durable['entries']! as List).last as Map)['consumedMarks'],
            isNotEmpty,
          );
          h.clock.advance(const Duration(seconds: 1));
          h.storage.files.releaseBarrier();
          final result = await pending;
          expect(result.reasonCode, 'ticketExpired');
          h.expectNotExecuted(result);
          expect(
            h.storage.journal.requiresConfirmation(mr6b2Account, h.keys),
            isTrue,
          );
          _spent(h.gate.tickets.single);
          final again = await h.coordinator.approve(proposal);
          expect(again.state, AiJournalState.notExecuted);
          expect(
            h.sends,
            0,
            reason: 'a flushed approval is terminal, not resumable',
          );
        },
      );

      test(
        'rollback failure retains isolation and never claims a mutation',
        () async {
          final entered = h.storage.files.armBarrier(
            writesBeforeBarrier: 1,
            afterPersist: true,
          );
          final pending = h.coordinator.execute(h.call());
          await entered;
          h.clock.advance(const Duration(seconds: 1));
          h.storage.files.failWriteNumber = h.storage.files.writeCount + 1;
          h.storage.files.releaseBarrier();
          final result = await pending;
          expect(result.state, AiJournalState.writeUncertain);
          expect(result.mutationCount, 0);
          expect(h.sends, 0);
          expect(h.storage.journal.isolated(mr6b2Account, h.keys), isTrue);
        },
      );

      for (final phase in ['acquire', 'flush']) {
        for (final reason in [
          'stop',
          'generation',
          'policy',
          'consent',
          'removal',
          '429',
          'observed revoke',
        ]) {
          test(
            '$reason during $phase prevents a mutation and preserves refund',
            () async {
              final barrier = Mr6cBarrier();
              Future<void> entered;
              if (phase == 'acquire') {
                h.gate.onAcquire = (_) => barrier.wait();
                entered = barrier.entered;
              } else {
                entered = h.storage.files.armBarrier(
                  writesBeforeBarrier: 1,
                  afterPersist: true,
                );
              }
              final pending = h.coordinator.execute(h.call());
              await entered;
              switch (reason) {
                case 'stop':
                  h.coordinator.stop('syntheticStop');
                case 'generation':
                  h.generation++;
                case 'policy':
                  h.revision++;
                case 'consent':
                  h.consent = false;
                case 'removal':
                  h.storage.journal.beginRemoval(mr6b2Account).cancelFinal();
                case '429':
                  h.server.overrides['GET projects/9'] = (_) => jsonResponse(
                    {'message': 'synthetic 429'},
                    status: 429,
                    headers: {
                      'retry-after': ['60'],
                    },
                  );
                  try {
                    await h.server.api.project('9', refresh: true);
                  } on Object {
                    /* remembered gate */
                  }
                case 'observed revoke':
                  h.gate.invalidated = true;
              }
              barrier.release();
              h.storage.files.releaseBarrier();
              final result = await pending;
              h.expectNotExecuted(result);
              for (final ticket in h.gate.tickets) {
                _spent(ticket);
              }
            },
          );
        }
      }

      test('wrong owner binding refuses before any preparation read', () async {
        h.gate.binding = _binding(Object(), run: 'wrong-owner');
        h.coordinator.beginRun('Star project and close #3 in team/example-9.');
        h.foreground = false;
        final before = h.server.adapter.requests.length;
        final result = await h.coordinator.execute(h.call());
        expect(result.state, AiJournalState.notExecuted);
        expect(h.server.adapter.requests.length, before);
        expect(h.graphPort.prepares, 0);
        expect(h.gate.acquisitions, isEmpty);
        expect(h.sends, 0);
      });

      test(
        'no-injection coordinator and inherited model gate refuse background',
        () async {
          final defaultCoordinator = h.makeCoordinator(inject: false);
          defaultCoordinator.beginRun(
            'Star project and close #3 in team/example-9.',
          );
          h.foreground = false;
          final result = await defaultCoordinator.execute(h.call());
          expect(result.state, AiJournalState.notExecuted);
          final b = runner_base.Harness();
          final runner = AiRunner(
            config: b.config(),
            wire: b.wire,
            complete: b.complete,
            secrets: b.secrets,
            refreshSecrets: () async {},
            guard: b.runner.guard,
            system: 'system',
            close: () {},
            cancelActive: () {},
            writeCoordinator: defaultCoordinator,
          );
          final model = await runner.run('background');
          expect(model.modelCalls, 0);
          expect(
            model.pause!.reason,
            AiExecutionPauseReason.foregroundRequired,
          );
          expect(h.sends, 0);
          defaultCoordinator.stop('done');
        },
      );
    });
  }

  for (final reason in [
    'native revoke',
    'stop',
    'generation',
    'policy',
    'consent',
    'removal',
    '429',
  ]) {
    test(
      '$reason in Graph preflight finishes before acquire and sends zero mutations',
      () async {
        final h = await _WriteHarness.create(graph: true);
        addTearDown(h.dispose);
        final barrier = Mr6cBarrier();
        h.graphPort.preflight = barrier.wait;
        final pending = h.coordinator.execute(h.call());
        await barrier.entered;
        expect(h.gate.acquisitions, isEmpty);
        h.clock.advance(const Duration(seconds: 2));
        switch (reason) {
          case 'native revoke':
            h.gate.nativeActive =
                false; // invalidation callback deliberately lost
          case 'stop':
            h.coordinator.stop();
          case 'generation':
            h.generation++;
          case 'policy':
            h.revision++;
          case 'consent':
            h.consent = false;
          case 'removal':
            h.storage.journal.beginRemoval(mr6b2Account).cancelFinal();
          case '429':
            h.server.overrides['GET projects/9'] = (_) => jsonResponse(
              {'message': 'synthetic 429'},
              status: 429,
              headers: {
                'retry-after': ['60'],
              },
            );
            try {
              await h.server.api.project('9', refresh: true);
            } on Object {
              // Keep the production Retry-After predicate closed.
            }
        }
        barrier.release();
        h.expectNotExecuted(await pending);
        expect(h.graphPort.sends, 0);
      },
    );
  }

  for (final graph in [false, true]) {
    test(
      'one background runner send and automatic ${graph ? 'Graph' : 'REST'} share the allocated logical run',
      () async {
        final h = await _WriteHarness.create(graph: graph, begin: false);
        addTearDown(h.dispose);
        h.foreground = false;
        final b = runner_base.Harness();
        b.respond = (_, _) async => b.payloads.length == 1
            ? b.turn(calls: [h.call()])
            : b.turn(text: 'done');
        final runner = AiRunner(
          config: b.config(),
          wire: b.wire,
          complete: b.complete,
          secrets: b.secrets,
          refreshSecrets: () async {},
          guard: AiRunGuard(
            expectedGeneration: 7,
            ownerApi: h.server.api,
            generation: () => h.generation,
            api: () => h.server.api,
            recipientRevision: () => 1,
            consentValid: () => h.consent,
          ),
          system: 'system',
          close: () {},
          cancelActive: () {},
          writeCoordinator: h.coordinator,
          currentTools: () => h.coordinator.specs,
        );
        final result = await runner.run(
          'Star project and close #3 in team/example-9.',
        );
        expect(result.reason, AiRunEnd.done);
        expect(result.modelCalls, 2);
        expect(h.sends, 1);
        expect(
          h.storage.journal.entries(mr6b2Account).single.runId,
          h.gate.binding.runId,
        );
        expect(h.gate.acquisitions, [
          AiContinuationKind.model,
          AiContinuationKind.mutation,
          AiContinuationKind.model,
        ]);
      },
    );
  }
}

AiRunner _runnerWithWrites(
  _WriteHarness h,
  runner_base.Harness b, {
  Future<void> Function()? refreshSecrets,
}) => AiRunner(
  config: b.config(),
  wire: b.wire,
  complete: b.complete,
  secrets: b.secrets,
  refreshSecrets: refreshSecrets ?? () async {},
  guard: AiRunGuard(
    expectedGeneration: 7,
    ownerApi: h.server.api,
    generation: () => h.generation,
    api: () => h.server.api,
    recipientRevision: () => 1,
    consentValid: () => h.consent,
  ),
  system: 'system',
  close: () {},
  cancelActive: () {},
  writeCoordinator: h.coordinator,
  currentTools: () => h.coordinator.specs,
);

final class _ObservedSecrets implements KnownSecretsSource {
  _ObservedSecrets(this.source);
  final KnownSecretsSource source;
  void Function()? onRead;
  @override
  Iterable<String> get current {
    onRead?.call();
    return source.current;
  }
}

final class _ModelHarness {
  _ModelHarness();
  final runner_base.Harness base = runner_base.Harness();
  final clock = Mr6cClock();
  late Mr6cExecutionGate gate;
  late AiRunner runner;
  late KnownSecretsLive secrets;
  late _ObservedSecrets observed;
  late AiSettingsController settings;
  late SessionController session;
  late GitLabApi api;
  Object? currentOwner;
  int generation = 7;
  bool consent = true;
  bool finalSnapshot = false;
  void Function()? onGuard;
  Duration lastRefreshDelay = Duration.zero;
  int deliveries = 0;
  final requestTexts = <List<String>>[];
  AiPrepareToolResults? prepare;
  Future<AiToolResult> Function(AiToolCall)? execute;
  List<AiToolSpec> currentSpecs = [runner_base.spec];
  int _lastAcquisition = 0;

  DateTime now() => DateTime.utc(2026, 10, 27).add(clock.elapsed);

  static Future<_ModelHarness> create() async {
    final h = _ModelHarness();
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final oauthAdapter = FakeAdapter(
      (_) => jsonResponse({
        'access_token': _newAccess,
        'refresh_token': _newRefresh,
        'token_type': 'bearer',
        'expires_in': 7200,
      }),
    );
    var rejectNext = true;
    final apiAdapter = FakeAdapter((_) {
      if (rejectNext) {
        rejectNext = false;
        return jsonResponse({}, status: 401);
      }
      return jsonResponse({'id': 7, 'username': 'synthetic'});
    });
    h.api = GitLabApi(
      instance: instance,
      credential: const OAuthCredential(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        clientId: 'synthetic',
      ),
      dio: Dio()..httpClientAdapter = apiAdapter,
      oauth: OAuthTokenClient(
        instance: instance,
        clientId: 'synthetic',
        dio: Dio()..httpClientAdapter = oauthAdapter,
      ),
    );
    h.currentOwner = h.api;
    h.session = SessionController(_AccountStore());
    h.settings = AiSettingsController(MemoryAiStore());
    await h.settings.initialize();
    await h.settings.saveProvider(
      AiProviderConfig(
        id: 'another-provider',
        name: 'Other synthetic recipient',
        presetId: 'custom',
        baseUrl: 'https://other-provider.example/v1',
        format: h.base.config().format,
        model: 'synthetic',
        authStyle: h.base.config().authStyle,
        caps: h.base.caps,
        allowLanCleartext: false,
        toolsEnabled: true,
        recipientRevision: 1,
      ),
    );
    h.secrets = KnownSecretsLive(
      h.session,
      h.settings,
      readGitLabCredential: () => h.api.credential,
    );
    h.observed = _ObservedSecrets(h.secrets);
    h.gate = Mr6cExecutionGate(binding: _binding(h.api), clock: h.clock);
    var observedAcquisition = 0;
    h.observed.onRead = () {
      if (h.finalSnapshot && observedAcquisition != h._lastAcquisition) {
        observedAcquisition = h._lastAcquisition;
        h.gate.events.add('redact/verify');
      }
    };
    h.runner = AiRunner(
      config: h.base.config(),
      wire: h.base.wire,
      complete: (plan, {onEvent}) {
        h.gate.events.add('send');
        // Snapshot app/plain provider strings before segment mutation. Raw
        // JSON substring checks alone miss a secret containing a backslash.
        h.requestTexts.add([
          plan.system,
          for (final entry in plan.segment.entries) ...readableAiEntry(entry),
        ]);
        return h.base.complete(plan, onEvent: onEvent);
      },
      secrets: h.observed,
      refreshSecrets: h.refresh,
      guard: AiRunGuard(
        expectedGeneration: 7,
        ownerApi: h.api,
        generation: () {
          h.gate.events.add('guard');
          h.onGuard?.call();
          return h.generation;
        },
        api: () => h.currentOwner,
        recipientRevision: () => 1,
        consentValid: () => h.consent,
      ),
      system: 'Safe synthetic system',
      tools: [runner_base.spec],
      currentTools: () => h.currentSpecs,
      executionGate: h.gate,
      close: () {},
      cancelActive: () {},
      now: h.now,
      executeTool: (call) async => h.execute == null
          ? AiToolResult.fromData(
              callId: call.id,
              name: call.name,
              data: const AiAppText.plain('read result'),
            )
          : h.execute!(call),
      prepareToolResults: (calls, results, before) async => h.prepare == null
          ? (results: results, delivered: (_) => h.deliveries++)
          : h.prepare!(calls, results, before),
    );
    return h;
  }

  Future<void> refresh() async {
    await secrets.refresh();
    if (_lastAcquisition != gate.acquisitions.length) {
      _lastAcquisition = gate.acquisitions.length;
      gate.events.add('last-refresh');
      finalSnapshot = true;
      clock.advance(lastRefreshDelay);
    }
  }

  Future<void> inject(bool oauth) async {
    if (oauth) {
      final owner = api;
      await api.currentUser();
      expect(api, same(owner));
      expect(api.credential.accessToken, _newAccess);
    } else {
      await settings.saveProviderKey('another-provider', _newKey);
    }
  }

  void expectNoKnownSecret(bool oauth) {
    for (final secret in oauth ? [_newAccess, _newRefresh] : [_newKey]) {
      expect(requestTexts.last.join('\n'), isNot(contains(secret)));
    }
  }

  void dispose() {
    settings.dispose();
    session.dispose();
    api.close();
  }
}

final class _RereadPort implements AiGitLabReadPort {
  _RereadPort(this.h);
  final _ModelHarness h;
  int calls = 0;
  @override
  Future<AiPortRead<AiJson>> issue(int iid) async {
    calls++;
    if (calls > 1) {
      h.gate.events.add('reread-started');
      h.clock.advance(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      h.gate.events.add('reread-finished');
    }
    return AiPortRead(
      {
        'iid': iid,
        'title': 'Synthetic issue',
        'description': 'reread-body $_newKey $_newAccess $_newRefresh',
      },
      requestCount: 1,
      fetchedAt: h.now(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused read');
}

final class _GraphPort implements port.AiGitLabWritePort {
  _GraphPort(this.gate);
  final Mr6cExecutionGate gate;
  int prepares = 0;
  int sends = 0;
  Future<void> Function()? preflight;
  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    prepares++;
    return port.AiWritePrepared.graph(
      request: request,
      releaseName: '#3',
      writeKeys: {mr6b3WriteKey},
      owner: this,
      bindingDigest: 'stable',
      mutation: (hooks) async {
        await preflight?.call();
        gate.events.add('graph-preflight-finished');
        await hooks.beforeMutation();
        gate.events.add('flush-finished');
        if (!hooks.mayStart()) throw const port.AiWriteRefused('notAccepted');
        gate.events.add('mutation');
        sends++;
        return const GraphWriteResult(
          mutationSent: true,
          acknowledged: true,
          readbackVerified: true,
        );
      },
    );
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => prepared.commitGraph(mayStart: mayStart);
}

final class _Ledger implements AiCapabilityLedger {
  const _Ledger();
  @override
  AiCapability? find(String op) => op == 'setStar'
      ? const VisibleProductionLedger().find(op)
      : const Mr6b3Ledger().find(op);
  @override
  List<AiCapability> get modelVisible => [find('setStar')!, Mr6b3Ledger.state];
}

final class _WriteHarness {
  _WriteHarness(this.graph, this.storage);
  final bool graph;
  final Mr6b3Harness storage;
  final Mr6b2Server server = Mr6b2Server();
  final clock = Mr6cClock();
  late Mr6cExecutionGate gate;
  late _GraphPort graphPort;
  late PolicyAiWriteCoordinator coordinator;
  final budget = AiToolBudget(maxGitLabRequests: 200);
  AiAutonomyLevel level = AiAutonomyLevel.bypass;
  bool foreground = true;
  bool? executionEligible;
  bool Function()? clientMayStartPredicate;
  int clientChecks = 0;
  bool consent = true;
  int generation = 7;
  int revision = 1;
  int _sequence = 0;
  int portCreations = 0;
  int get sends => graph ? graphPort.sends : server.mutationCount();
  Set<AiConflictKey> get keys => graph
      ? {mr6b3WriteKey}
      : {
          const AiConflictKey([mr6b2Account, 'project:9', 'star', '7']),
        };

  static Future<_WriteHarness> create({
    required bool graph,
    bool begin = true,
  }) async {
    final h = _WriteHarness(graph, await Mr6b3Harness.create());
    h.gate = Mr6cExecutionGate(binding: _binding(h.server.api), clock: h.clock);
    h.graphPort = _GraphPort(h.gate);
    h.coordinator = h.makeCoordinator();
    if (begin) {
      h.coordinator.beginRun('Star project and close #3 in team/example-9.');
      h.coordinator.beginTurn();
    }
    return h;
  }

  PolicyAiWriteCoordinator makeCoordinator({
    bool inject = true,
    AiWritePolicySnapshot Function()? policySnapshot,
  }) =>
      PolicyAiWriteCoordinator(
        releasePolicy: fixtureReleasePolicy,
        snapshot: policySnapshot ?? () => AiWritePolicySnapshot(
          scope: mr6b2Scope,
          level: level,
          ceiling: AiAutonomyLevel.bypass,
          consentHash: 'mr6c-consent',
          writePolicyRevision: revision,
          sessionGeneration: generation,
          consentValid: consent,
          appInForeground: foreground,
          executionEligible:
              executionEligible ?? (inject ? gate.executionEligible : foreground),
          ownerApi: server.api,
          clientMayStartPredicate: () {
            clientChecks++;
            return clientMayStartPredicate?.call() ?? server.api.mayStartRequest;
          },
        ),
        createPort: () {
          portCreations++;
          return graph ? graphPort : server.writePort;
        },
        journal: storage.journal,
        conversationId: _conversation,
        budget: () => budget,
        readFreshness: (_) async => const AiWriteFreshness(
          updatedAt: '2026-10-27T00:00:00Z',
          visibilityUnreadable: false,
        ),
        placeholders: text.UploadPlaceholderTable(
          instance: GitLabInstance.parse('https://example.com/gitlab'),
        ),
        knownSecrets: () => const {},
        safeDisplay: (s) => s,
        ledger: const _Ledger(),
        executionGate: inject ? gate : null,
        now: () => DateTime.utc(2026, 10, 27).add(clock.elapsed),
      );

  AiToolCall call({bool second = false}) => AiToolCall(
    id: 'ticket-${++_sequence}',
    name: graph ? 'updateWorkItemState' : 'setStar',
    arguments: {
      'projectId': 9,
      if (graph) ...{
        'iid': 3,
        'stateEvent': second ? 'reopen' : 'close',
      } else
        'starred': !second,
      'reason': 'synthetic boundary test',
    },
  );

  void expectNotExecuted(AiWriteOutcome outcome) {
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.mutationCount, 0);
    expect(sends, 0);
    expect(
      storage.journal.entries(mr6b2Account).last.state,
      AiJournalState.notExecuted,
    );
    expect(
      storage.journal.conversationWriteCount(mr6b2Account, _conversation),
      0,
    );
  }

  Future<void> seedConfirmMark() async {
    const execution = 'mr6c-confirm-seed';
    await storage.journal.prepare(
      draft: AiJournalDraft(
        executionId: execution,
        accountKey: mr6b2Account,
        conversationId: 'seed-conversation',
        runId: 'seed-run',
        operationId: graph ? 'updateWorkItemState' : 'setStar',
        writeKeys: keys,
        payloadSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        releaseName: '#3',
      ),
    );
    await storage.journal.markDispatching(executionId: execution);
    await storage.journal.finish(
      executionId: execution,
      terminal: AiJournalState.writeUncertain,
    );
    await storage.journal.releaseByUser(
      executionId: execution,
      typedName: '#3',
    );
  }

  Future<void> dispose() async {
    storage.files.releaseBarrier();
    coordinator.stop('disposed');
    server.api.close();
    await storage.dispose();
  }
}

final class _AccountStore implements AccountStore {
  @override
  Future<List<Account>> load() async => const [];
  @override
  Future<String?> loadLastActive() async => null;
  @override
  Future<bool> loadSignOutPending() async => false;
  @override
  Future<void> save(List<Account> accounts) async {}
  @override
  Future<void> saveLastActive(String? key) async {}
  @override
  Future<void> saveSignOutPending(bool pending) async {}
}
